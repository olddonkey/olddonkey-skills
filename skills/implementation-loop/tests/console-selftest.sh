#!/usr/bin/env bash
# Hermetic regression checks for loop-console (D7 handshake and read-only
# local web console). HOME is a scratch directory so the real ~/.config
# tree is never touched. The server is driven with python3 http.client.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CONSOLE="$SCRIPT_DIR/../scripts/loop-console"
JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
RUN="$SCRIPT_DIR/../scripts/loop-run"
INDEX="$SCRIPT_DIR/../scripts/loop-index"
ASSETS="$SCRIPT_DIR/../scripts/console-assets"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/console-selftest.XXXXXX")" || exit 1
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"

CONSOLE_PID=""
EXTRA_PIDS=""

cleanup() {
  local status="$1" pid
  trap - EXIT HUP INT TERM
  if [[ -n "$CONSOLE_PID" ]]; then
    kill -TERM "$CONSOLE_PID" 2>/dev/null || true
    wait "$CONSOLE_PID" 2>/dev/null || true
    CONSOLE_PID=""
  fi
  if [[ -n "$EXTRA_PIDS" ]]; then
    for pid in $EXTRA_PIDS; do
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    EXTRA_PIDS=""
  fi
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME/.config/olddonkey-loop" || exit 1
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop" || exit 1
export LC_ALL=C
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export XDG_CONFIG_HOME="$TMP_ROOT/xdg"
mkdir -p "$XDG_CONFIG_HOME"

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$CASE_STDERR" >&2
  fi
}

workspace() { # $1=name
  local path="$TMP_ROOT/ws-$1"
  mkdir -p "$path"
  printf '%s\n' "$path"
}

field_from() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" | head -n 1
}

run_cmd() { # $1=name, remaining=command
  local name="$1"
  shift
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if "$@" >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

workspace_key() { # $1=workspace
  python3 - "$1" <<'PY'
import hashlib, os, sys
print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode("utf-8")).hexdigest())
PY
}

tree_manifest() { # $1=root $2=output-file [skip-rel...]
  python3 - "$@" <<'PY'
import hashlib, os, sys
root, dest = sys.argv[1], sys.argv[2]
skips = [item for item in sys.argv[3:] if item]

def skipped_dir(rel):
    for skip in skips:
        if rel == skip or rel.startswith(skip + os.sep):
            return True
    return False

def skipped_file(rel_file):
    for skip in skips:
        if rel_file == skip or rel_file.startswith(skip + os.sep):
            return True
    return False

rows = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    rel = os.path.relpath(dirpath, root)
    if rel == ".":
        rel = ""
    if skipped_dir(rel):
        dirnames[:] = []
        continue
    dirnames.sort()
    filenames.sort()
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel_file = os.path.relpath(path, root)
        if skipped_file(rel_file):
            continue
        digest = hashlib.sha256()
        if os.path.islink(path):
            digest.update(b"link:")
            digest.update(os.readlink(path).encode("utf-8", "replace"))
        elif os.path.isfile(path):
            with open(path, "rb") as handle:
                digest.update(handle.read())
        rows.append("%s %s" % (digest.hexdigest(), rel_file))
rows.sort()
text = "\n".join(rows) + ("\n" if rows else "")
open(dest, "w", encoding="utf-8").write(text)
print(hashlib.sha256(text.encode("utf-8")).hexdigest())
PY
}

home_manifest() { # $1=output-file
  if [[ -n "${CAL_REL:-}" ]]; then
    tree_manifest "$HOME" "$1" \
      ".config/olddonkey-loop/console" \
      "$CAL_REL"
  else
    tree_manifest "$HOME" "$1" ".config/olddonkey-loop/console"
  fi
}

workspace_manifest() { # $1=workspace $2=output-file
  tree_manifest "$1" "$2"
}

lock_meta() { # $1=lock-path $2=output-file
  python3 - "$1" "$2" <<'PY'
import os, stat, sys
path, dest = sys.argv[1], sys.argv[2]
info = os.lstat(path)
open(dest, "w", encoding="utf-8").write(
    "%d %d %o\n" % (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode))
)
PY
}

init_git_repo() { # $1=dir
  mkdir -p "$1"
  rm -rf "$1.gitadmin"
  git init -q --template= --separate-git-dir="$1.gitadmin" "$1"
}

wait_for_url() { # $1=stdout-file [$2=pid]
  local stdout="$1" pid="${2:-$CONSOLE_PID}" i
  for i in $(seq 1 50); do
    if grep -Eq '^http://127\.0\.0\.1:[0-9]+/#.+$' "$stdout" 2>/dev/null; then
      return 0
    fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

parse_url() { # $1=stdout-file -> prints port\ttoken
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
hits = [line for line in text if line.startswith("http://127.0.0.1:")]
if len(hits) != 1:
    raise SystemExit("expected exactly one URL line, got %d" % len(hits))
match = re.fullmatch(r"http://127\.0\.0\.1:(\d+)/#([A-Za-z0-9_-]+)", hits[0])
if match is None:
    raise SystemExit("URL line did not match the required form")
print("%s\t%s" % (match.group(1), match.group(2)))
PY
}

# ---------------------------------------------------------------------------
# 11. Asset discipline (no server required)
# ---------------------------------------------------------------------------
if python3 - "$ASSETS" <<'PY'
import os, re, sys
root = sys.argv[1]
js = open(os.path.join(root, "console.js"), encoding="utf-8").read()
html = open(os.path.join(root, "index.html"), encoding="utf-8").read()
css = open(os.path.join(root, "console.css"), encoding="utf-8").read()
forbidden = (
    "innerHTML",
    "outerHTML",
    "insertAdjacentHTML",
    "document.write",
    "eval",
    "setHTML",
    "srcdoc",
    "createContextualFragment",
    "new Function",
    "setTimeout",
    "document.writeln",
    "javascript:",
    "element.style",
)
missing = [name for name in forbidden if name in js]
if missing:
    raise SystemExit("js tokens: " + ",".join(missing))
if re.search(r"\.style\.", js):
    raise SystemExit("js .style. assignment")
if re.search(r"""\bstyle\s*=\s*["']""", js):
    raise SystemExit("js inline style string")
if re.search(r"<script(?![^>]*\bsrc=)", html, re.I):
    raise SystemExit("inline script")
if re.search(r"\son[a-z]+=", html, re.I):
    raise SystemExit("inline handler")
if re.search(r"\sstyle=", html, re.I):
    raise SystemExit("inline style")
if "@import" in css or re.search(r"https?://", css):
    raise SystemExit("css remote")
if re.search(r"""(?:src|href)\s*=\s*["']?https?://""", html, re.I):
    raise SystemExit("html remote")
names = sorted(
    name for name in os.listdir(root)
    if os.path.isfile(os.path.join(root, name))
)
if names != ["console.css", "console.js", "index.html"]:
    raise SystemExit("asset set: %s" % names)
PY
then
  pass "assets: console.js forbids unsafe DOM / eval tokens"
  pass "assets: index.html has no inline script, handlers, or style="
  pass "assets: console.css has no @import or remote url"
  pass "assets: index.html has no remote src/href"
  pass "assets: exactly the three committed files"
else
  fail "assets: console.js forbids unsafe DOM / eval tokens"
  fail "assets: index.html has no inline script, handlers, or style="
  fail "assets: console.css has no @import or remote url"
  fail "assets: index.html has no remote src/href"
  fail "assets: exactly the three committed files"
fi

if python3 - "$ASSETS" <<'PY'
import os, re, sys
root = sys.argv[1]
css = open(os.path.join(root, "console.css"), encoding="utf-8").read()
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
media = re.search(
    r"@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)",
    css,
)
if media is None:
    raise SystemExit("missing prefers-color-scheme: dark")


def brace_block(text, open_at):
    if open_at >= len(text) or text[open_at] != "{":
        raise SystemExit("expected '{' at %d" % open_at)
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at + 1 : index]
    raise SystemExit("unbalanced braces")


def first_rule(text, selector):
    match = re.search(r"(?<![\w-])" + selector + r"\s*\{", text)
    if match is None:
        return None
    return brace_block(text, match.end() - 1)


def props(block):
    found = {}
    for name, value in re.findall(r"--([a-z0-9-]+)\s*:\s*([^;]+);", block):
        found[name] = value.strip()
    return found


prefix = css[: media.start()]
light = first_rule(prefix, r":root")
if light is None:
    raise SystemExit("bare :root missing before dark media")
dark_media = brace_block(css, media.end() + css[media.end() :].find("{"))
dark = first_rule(dark_media, r":root")
if dark is None:
    raise SystemExit("dark media has no :root override")
stripped = re.sub(r":root\s*\{.*\}\s*", "", dark_media, count=1, flags=re.S).strip()
if stripped:
    raise SystemExit("dark media defines more than :root tokens: %r" % stripped[:80])
light_props = props(light)
dark_props = props(dark)
required = (
    "bg",
    "surface",
    "surface-raised",
    "border",
    "border-control",
    "text",
    "muted",
    "accent",
    "ok",
    "caution",
    "danger",
    "neutral",
)
missing_light = [name for name in required if name not in light_props]
if missing_light:
    raise SystemExit("bare :root missing --%s" % ",".join(missing_light))
missing_dark = [name for name in required if name not in dark_props]
if missing_dark:
    raise SystemExit("dark :root missing --%s" % ",".join(missing_dark))
only_dark = sorted(name for name in dark_props if name not in light_props)
if only_dark:
    raise SystemExit("tokens only in dark media: %s" % ",".join(only_dark))
PY
then
  pass "assets: console.css defines light tokens on :root and overrides them in dark"
else
  fail "assets: console.css defines light tokens on :root and overrides them in dark"
fi

if python3 - "$ASSETS" <<'PY'
import os, re, sys
root = sys.argv[1]
js = open(os.path.join(root, "console.js"), encoding="utf-8").read()
html = open(os.path.join(root, "index.html"), encoding="utf-8").read()
if re.search(r"<script(?![^>]*\bsrc=)", html, re.I):
    raise SystemExit("inline script")
if re.search(r"\son[a-z]+=", html, re.I):
    raise SystemExit("inline handler")
if re.search(r"\sstyle=", html, re.I):
    raise SystemExit("inline style")
if "aria-pressed" not in js:
    raise SystemExit("missing aria-pressed")
if 'setAttribute("role", "status")' not in js:
    raise SystemExit("missing role=status")
if 'el("label")' not in js:
    raise SystemExit("missing label factory")
PY
then
  pass "assets: index.html stays an inert shell"
  pass "assets: console.js exposes aria-pressed, role=status, and dial labels"
else
  fail "assets: index.html stays an inert shell"
  fail "assets: console.js exposes aria-pressed, role=status, and dial labels"
fi

if python3 - "$ASSETS/console.js" <<'PY'
import re, sys
js = open(sys.argv[1], encoding="utf-8").read()
if js.count("X-Console-CSRF") < 1:
    raise SystemExit("missing X-Console-CSRF")
if "apiHeaders" not in js:
    raise SystemExit("missing apiHeaders helper")
if "/api/dials" not in js or "/api/dials/reset" not in js:
    raise SystemExit("missing dials API surface")
if re.search(r"txt\(\s*link\s*,\s*href\s*\)", js):
    raise SystemExit("link text is still the raw href")
if 'setAttribute("href", href)' not in js:
    raise SystemExit("link href is not the parsed href")
if 'setAttribute("title", href)' not in js:
    raise SystemExit("link title is not the parsed href")
if "linkLabel" not in js or "parseHttpUrl" not in js:
    raise SystemExit("missing parsed-URL link helpers")
PY
then
  pass "assets: console.js sends X-Console-CSRF and labels publish links from the parsed URL"
else
  fail "assets: console.js sends X-Console-CSRF and labels publish links from the parsed URL"
fi

if python3 - "$ASSETS/console.js" <<'PY'
import sys
js = open(sys.argv[1], encoding="utf-8").read()
if "Setting one here grants standing authorization for this workspace." in js:
    raise SystemExit("stale unconditional permission-group copy")
if "when set beyond their default" not in js:
    raise SystemExit("group note missing the conditional grant")
if "carry no authority" not in js:
    raise SystemExit("group note missing the default-has-no-authority clause")
if 'record.scope === "permission"' not in js:
    raise SystemExit("grant chip is not gated on the API scope field")
if 'chip("grants authority", "caution")' not in js:
    raise SystemExit("missing grants-authority caution chip")
if "derived_scope" in js or "deriveScope" in js or "scopeForValue" in js:
    raise SystemExit("reimplemented scope derivation")
PY
then
  pass "assets: permission group copy is conditional; grant chip uses record.scope"
else
  fail "assets: permission group copy is conditional; grant chip uses record.scope"
fi

if python3 - "$ASSETS/console.js" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()


def extract_function(name):
    match = re.search(r"function " + re.escape(name) + r"\s*\(", src)
    if match is None:
        raise SystemExit("missing function %s" % name)
    brace = src.find("{", match.start())
    if brace < 0:
        raise SystemExit("no body for %s" % name)
    depth = 0
    for index in range(brace, len(src)):
        if src[index] == "{":
            depth += 1
        elif src[index] == "}":
            depth -= 1
            if depth == 0:
                return src[match.start() : index + 1]
    raise SystemExit("unbalanced function %s" % name)


for name in (
    "renderVitals",
    "renderNow",
    "renderThisRun",
    "renderAll",
    "renderDials",
    "pullState",
    "pullDials",
):
    body = extract_function(name)
    if re.search(r"\bclear\s*\(", body):
        raise SystemExit("%s still calls clear(" % name)

item = extract_function("itemById")
if "parent._byId" not in item:
    raise SystemExit("itemById does not look items up on parent._byId")
keyed = extract_function("syncKeyed")
if "itemById(" not in keyed:
    raise SystemExit("syncKeyed does not look items up by id")
if "insertBefore(" not in keyed:
    raise SystemExit("syncKeyed does not reorder with insertBefore")
PY
then
  pass "poll path: renderVitals/renderNow/renderThisRun do not call clear(); syncKeyed looks items up by id (source-level; no browser MutationObserver)"
else
  fail "poll path: renderVitals/renderNow/renderThisRun do not call clear(); syncKeyed looks items up by id (source-level; no browser MutationObserver)"
fi

if python3 - "$ASSETS/console.js" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()


def extract_function(name):
    match = re.search(r"function " + re.escape(name) + r"\s*\(", src)
    if match is None:
        raise SystemExit("missing function %s" % name)
    brace = src.find("{", match.start())
    if brace < 0:
        raise SystemExit("no body for %s" % name)
    depth = 0
    for index in range(brace, len(src)):
        if src[index] == "{":
            depth += 1
        elif src[index] == "}":
            depth -= 1
            if depth == 0:
                return src[match.start() : index + 1]
    raise SystemExit("unbalanced function %s" % name)


txt = extract_function("txt")
if "node.textContent !== next" not in txt and "child.nodeValue !== next" not in txt:
    raise SystemExit("txt is missing the compare-current-text step")
if "node.textContent = next" not in txt and "child.nodeValue = next" not in txt:
    raise SystemExit("txt is missing the assign-only-when-different step")
if "textContent !==" not in txt and "nodeValue !==" not in txt:
    raise SystemExit("txt does not compare before assigning")

stamp = extract_function("stampUpdated")
if 'getElementById("updated-at")' not in stamp:
    raise SystemExit("stampUpdated does not target #updated-at")
if "txt(" not in stamp:
    raise SystemExit("header timestamp is not updated through txt")

families = (
    ("updateUnit", "unit"),
    ("updateOpenDispatch", "dispatch card"),
    ("updateDispatchRow", "dispatch table"),
    ("updateGate", "gate"),
    ("updateTile", "vitals"),
    ("updateDial", "dial"),
)
for name, label in families:
    body = extract_function(name)
    if "txt(" not in body:
        raise SystemExit("%s (%s) does not use txt(" % (name, label))

creates = (
    ("createUnit", "updateUnit"),
    ("createOpenDispatch", "updateOpenDispatch"),
    ("createDispatchRow", "updateDispatchRow"),
    ("createGate", "updateGate"),
    ("createDial", "updateDial"),
)
for creator, updater in creates:
    body = extract_function(creator)
    if updater + "(" not in body:
        raise SystemExit("%s reaches fields only at create-time; missing %s(" % (creator, updater))

dials = extract_function("renderDials")
if "syncKeyed(" not in dials:
    raise SystemExit("renderDials does not reuse dial cards via syncKeyed")
if "updateDial" not in dials:
    raise SystemExit("renderDials never routes existing dials through updateDial")
if re.search(r"\bclear\s*\(", dials):
    raise SystemExit("renderDials still rebuilds with clear(")
if "createDial" not in dials:
    raise SystemExit("renderDials lost the keyed createDial path")
PY
then
  pass "update path: txt compares current text and assigns only when different; every render family uses it (source-level; no browser MutationObserver)"
  pass "update path: header #updated-at is written through txt (source-level; frozen-timestamp field)"
  pass "update path: unit/dispatch/gate/vitals/dial updates are not create-time-only (source-level)"
else
  fail "update path: txt compares current text and assigns only when different; every render family uses it (source-level; no browser MutationObserver)"
  fail "update path: header #updated-at is written through txt (source-level; frozen-timestamp field)"
  fail "update path: unit/dispatch/gate/vitals/dial updates are not create-time-only (source-level)"
fi

if python3 - "$ASSETS" <<'PY'
import os, re, sys
root = sys.argv[1]
js = open(os.path.join(root, "console.js"), encoding="utf-8").read()
html = open(os.path.join(root, "index.html"), encoding="utf-8").read()


def extract_function(name):
    match = re.search(r"function " + re.escape(name) + r"\s*\(", js)
    if match is None:
        raise SystemExit("missing function %s" % name)
    brace = js.find("{", match.start())
    depth = 0
    for index in range(brace, len(js)):
        if js[index] == "{":
            depth += 1
        elif js[index] == "}":
            depth -= 1
            if depth == 0:
                return js[match.start() : index + 1]
    raise SystemExit("unbalanced function %s" % name)


order = [html.find('id="section-now"'), html.find('id="section-flow"'), html.find('id="section-run"')]
if -1 in order or order != sorted(order):
    raise SystemExit("Flow section is not between Now and This run: %s" % order)
if '<div id="flow-root"></div>' not in html:
    raise SystemExit("missing #flow-root")
render_all = extract_function("renderAll")
if not re.search(r"renderNow\(state\);\s*renderFlow\(state\);\s*renderThisRun\(state\);", render_all):
    raise SystemExit("renderAll does not draw Flow between Now and This run")
if js.count("createElementNS(") != 1 or "createElementNS(" not in extract_function("svgEl"):
    raise SystemExit("an SVG element is created outside svgEl")
names = re.findall(r"function (\w*[Ff]low\w*|svgEl|svgAttr|clearPackets|launchPacket)\s*\(", js)
if len(names) < 30:
    raise SystemExit("flow functions not found: %s" % names)
for name in names:
    body = extract_function(name)
    for token in ("fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "pullState", "pullTranscript", "pullDials"):
        if token in body:
            raise SystemExit("%s issues a request (%s)" % (name, token))
PY
then
  pass "flow: index.html places the Flow section between Now and This run; renderAll draws it in that order (source-level)"
  pass "flow: every SVG element is created through svgEl, and no flow function issues a request (source-level)"
else
  fail "flow: index.html places the Flow section between Now and This run; renderAll draws it in that order (source-level)"
  fail "flow: every SVG element is created through svgEl, and no flow function issues a request (source-level)"
fi

if node - "$ASSETS/console.js" >"$TMP_ROOT/render.tap" 2>"$TMP_ROOT/render.err" <<'JS'
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8");

function extractBlock(headerRe) {
  const match = headerRe.exec(src);
  if (!match) {
    throw new Error("missing " + headerRe);
  }
  const brace = src.indexOf("{", match.index);
  if (brace < 0) {
    throw new Error("no brace for " + headerRe);
  }
  let depth = 0;
  for (let i = brace; i < src.length; i += 1) {
    if (src[i] === "{") {
      depth += 1;
    } else if (src[i] === "}") {
      depth -= 1;
      if (depth === 0) {
        return src.slice(match.index, i + 1);
      }
    }
  }
  throw new Error("unbalanced " + headerRe);
}

function makeNode(name) {
  return {
    nodeName: name,
    className: "",
    textContent: "",
    attrs: {},
    children: [],
    setAttribute: function (key, value) {
      this.attrs[key] = String(value);
    },
    getAttribute: function (key) {
      return this.attrs[key];
    },
    appendChild: function (child) {
      this.children.push(child);
      return child;
    },
    addEventListener: function () {},
  };
}

function walk(node, visit) {
  visit(node);
  (node.children || []).forEach(function (child) {
    walk(child, visit);
  });
}

const SVG_NS = "http://www.w3.org/2000/svg";
const SVG_TAGS = ["svg", "g", "path", "circle", "rect", "line", "text", "title", "desc"];
const SVG_ATTRS = [
  "viewBox", "d", "cx", "cy", "r", "x", "y", "x1", "y1", "x2", "y2", "width",
  "height", "rx", "class", "role", "aria-label", "aria-hidden", "focusable",
  "text-anchor",
];
const FLOW_HELPERS = [
  "wipe",
  "keyedMap",
  "itemById",
  "syncKeyed",
  "showHint",
  "placeBefore",
  "updateOptional",
  "pickRun",
  "svgEl",
  "svgAttr",
  "flowOwn",
  "flowNum",
  "flowSeq",
  "flowKey",
  "flowReady",
  "flowReducedMotion",
  "flowMemory",
  "flowToken",
  "flowFilterFor",
  "flowUnits",
  "flowBackends",
  "flowBackendName",
  "flowCounts",
  "flowParts",
  "flowEdgeLabel",
  "flowAriaLabel",
  "flowRoute",
  "flowVariant",
  "flowOwner",
  "flowMatches",
  "flowEventText",
  "flowEdge",
  "flowLayout",
  "createFlowEdge",
  "updateFlowEdge",
  "createFlowNode",
  "updateFlowNode",
  "createFlowOption",
  "updateFlowOption",
  "createFlowItem",
  "updateFlowItem",
  "flowRecent",
  "flowFresh",
  "clearPackets",
  "launchPacket",
  "syncFlowFilter",
  "ensureFlowSkeleton",
  "drawFlow",
  "renderFlow",
];
const svgCreated = [];

const sandbox = {
  document: {
    activeElement: null,
    createElement: function (name) {
      return makeNode(name);
    },
    createElementNS: function (ns, name) {
      svgCreated.push(name);
      const node = makeNode(name);
      node.namespaceURI = ns;
      return node;
    },
    getElementById: function () {
      return null;
    },
  },
  matchMedia: function () {
    return { matches: false };
  },
  URL: URL,
  postDial: function () {},
  resetDial: function () {},
  selectedDispatch: null,
  lastState: null,
  renderAll: function () {},
};
vm.createContext(sandbox);
vm.runInContext(extractBlock(/var DIAL_OPTIONS =/), sandbox);
vm.runInContext(extractBlock(/var SVG_ALLOW =/), sandbox);
vm.runInContext(extractBlock(/var FLOW =/), sandbox);
[
  "el",
  "txt",
  "setClass",
  "setAttr",
  "setChip",
  "chip",
  "wordVariant",
  "livenessVariant",
  "bindingVariant",
  "verdictVariant",
  "reviewLabel",
  "publishSignature",
  "fillPublishFacts",
  "renderPublish",
  "parseHttpUrl",
  "linkLabel",
  "appendLinkOrText",
  "dialMetaText",
  "applySelectValue",
  "syncDialSelect",
  "setDisabled",
  "createDial",
  "updateDial",
  "renderDialRow",
  "createUnit",
  "updateUnit",
  "createOpenDispatch",
  "updateOpenDispatch",
  "appendCell",
  "createDispatchRow",
  "updateDispatchRow",
  "createGate",
  "updateGate",
  "tile",
  "updateTile",
  "pad2",
  "stampUpdated",
].concat(FLOW_HELPERS).forEach(function (name) {
  vm.runInContext(
    "this." + name + " = " + extractBlock(new RegExp("function " + name + "\\(")),
    sandbox
  );
});

function check(name, fn) {
  try {
    fn();
    console.log("ok - %s", name);
  } catch (error) {
    console.log("not ok - %s: %s", name, error && error.message ? error.message : error);
  }
}

check("render: permission-scope dial shows grants-authority chip; default does not", function () {
  const granted = makeNode("div");
  sandbox.renderDialRow(
    granted,
    "stop",
    { value: "merge", scope: "permission", source: "store" },
    false
  );
  const grantChips = [];
  walk(granted, function (node) {
    if (
      typeof node.className === "string" &&
      /\bchip\b/.test(node.className) &&
      node.textContent === "grants authority"
    ) {
      grantChips.push(node);
    }
  });
  if (grantChips.length !== 1) {
    throw new Error("permission dial chip count " + grantChips.length);
  }
  if (!/\bis-caution\b/.test(grantChips[0].className)) {
    throw new Error("grant chip class " + grantChips[0].className);
  }

  const def = makeNode("div");
  sandbox.renderDialRow(
    def,
    "stop",
    { value: "worktree", scope: "policy", source: "default" },
    false
  );
  const defaultChips = [];
  walk(def, function (node) {
    if (
      typeof node.className === "string" &&
      /\bchip\b/.test(node.className) &&
      node.textContent === "grants authority"
    ) {
      defaultChips.push(node);
    }
  });
  if (defaultChips.length !== 0) {
    throw new Error("default dial unexpectedly rendered a grant chip");
  }
});

check("render: publish link text is host-plus-path; href stays the parsed URL", function () {
  const href = "https://github.com/olddonkey/olddonkey-skills/pull/50";
  const parent = makeNode("p");
  sandbox.appendLinkOrText(parent, href);
  const link = parent.children[0];
  if (!link || link.nodeName !== "a") {
    throw new Error("expected an anchor");
  }
  if (link.attrs.href !== href) {
    throw new Error("href " + link.attrs.href);
  }
  if (link.attrs.title !== href) {
    throw new Error("title " + link.attrs.title);
  }
  if (link.attrs.rel !== "noopener noreferrer") {
    throw new Error("rel " + link.attrs.rel);
  }
  if (link.textContent !== "github.com · pull/50") {
    throw new Error("label " + link.textContent);
  }
  if (sandbox.linkLabel(new URL("https://example.com/")) !== "example.com") {
    throw new Error("host-only label " + sandbox.linkLabel(new URL("https://example.com/")));
  }
  if (sandbox.linkLabel(new URL("http://127.0.0.1:8080/a/b/c")) !== "127.0.0.1:8080 · b/c") {
    throw new Error("host+port label");
  }
  const plain = makeNode("p");
  sandbox.appendLinkOrText(plain, "javascript:alert(1)");
  if (!plain.children[0] || plain.children[0].nodeName !== "span") {
    throw new Error("non-http should be plain text");
  }
  if (plain.children[0].textContent !== "javascript:alert(1)") {
    throw new Error("non-http text changed");
  }
});

function refuses(fn) {
  try {
    fn();
  } catch (error) {
    return true;
  }
  return false;
}

check("flow: svgEl creates each allowlisted tag in the SVG namespace and refuses every other tag", function () {
  SVG_TAGS.forEach(function (tag) {
    const node = sandbox.svgEl(tag);
    if (node.nodeName !== tag || node.namespaceURI !== SVG_NS) {
      throw new Error("svgEl(" + tag + ") made " + node.nodeName + " in " + node.namespaceURI);
    }
  });
  const others = [
    "script", "foreignObject", "a", "image", "use", "animate", "set", "style",
    "iframe", "object", "embed", "animateMotion", "animateTransform", "feImage",
    "filter", "pattern", "mask", "clipPath", "marker", "symbol", "defs", "switch",
    "tspan", "textPath", "linearGradient", "stop", "view", "div", "img", "SVG",
    "Path", "svg ", " g", "",
  ];
  if (others.length < 20) {
    throw new Error("refusal list too short");
  }
  const before = svgCreated.length;
  others.concat([null, undefined, 1, ["svg"], { toString: function () { return "g"; } }]).forEach(function (tag) {
    if (!refuses(function () { sandbox.svgEl(tag); })) {
      throw new Error("svgEl accepted " + JSON.stringify(tag));
    }
  });
  if (svgCreated.length !== before) {
    throw new Error("a refused tag still reached createElementNS: " + svgCreated.slice(before).join(","));
  }
});

check("flow: svgAttr sets each allowlisted attribute and refuses every other name and any url( / javascript: / < value", function () {
  SVG_ATTRS.forEach(function (name) {
    const node = makeNode("rect");
    sandbox.svgAttr(node, name, "12");
    if (node.attrs[name] !== "12") {
      throw new Error("svgAttr did not set " + name);
    }
  });
  const others = [
    "href", "xlink:href", "onload", "onclick", "onerror", "onmouseover", "onbegin",
    "onfocus", "style", "src", "fill", "stroke", "filter", "mask", "clip-path",
    "marker-start", "transform", "id", "xmlns", "xml:base", "attributeName",
    "values", "from", "to", "begin", "data-x", "tabindex", "VIEWBOX", "Class",
    "pathLength", "",
  ];
  if (others.length < 20) {
    throw new Error("refusal list too short");
  }
  others.forEach(function (name) {
    const node = makeNode("rect");
    if (!refuses(function () { sandbox.svgAttr(node, name, "1"); })) {
      throw new Error("svgAttr accepted " + JSON.stringify(name));
    }
    if (Object.keys(node.attrs).length) {
      throw new Error("refused " + name + " still wrote " + JSON.stringify(node.attrs));
    }
  });
  [["fill", "url(#x)"], ["style", "fill: url(#x)"], ["href", "javascript:alert(1)"]].forEach(function (pair) {
    if (!refuses(function () { sandbox.svgAttr(makeNode("rect"), pair[0], pair[1]); })) {
      throw new Error("svgAttr accepted " + pair.join("="));
    }
  });
  const values = [
    "url(#x)", "URL(#x)", "url (#x)", "javascript:alert(1)", "JavaScript:alert(1)",
    "java\tscript:alert(1)", "java\nscript:alert(1)", " javascript :x", "<script>",
    "a<b", "<",
  ];
  ["class", "aria-label", "d", "x", "viewBox"].forEach(function (name) {
    values.forEach(function (value) {
      const node = makeNode("rect");
      if (!refuses(function () { sandbox.svgAttr(node, name, value); })) {
        throw new Error("svgAttr accepted " + name + "=" + JSON.stringify(value));
      }
      if (Object.keys(node.attrs).length) {
        throw new Error("refused value still wrote " + JSON.stringify(node.attrs));
      }
    });
  });
});

function makeLiveText(value) {
  return {
    nodeType: 3,
    nodeName: "#text",
    parentNode: null,
    nextSibling: null,
    writes: { nodeValue: 0 },
    _nodeValue: value == null ? "" : String(value),
    get nodeValue() {
      return this._nodeValue;
    },
    set nodeValue(next) {
      this.writes.nodeValue += 1;
      this._nodeValue = String(next);
    },
    get textContent() {
      return this._nodeValue;
    },
    set textContent(next) {
      this.nodeValue = next;
    },
  };
}

function relink(parent) {
  parent._childList.forEach(function (child, index) {
    child.nextSibling = parent._childList[index + 1] || null;
    child.parentNode = parent;
  });
}

function makeLiveNode(name) {
  const node = {
    nodeName: name,
    nodeType: 1,
    attrs: {},
    listeners: {},
    parentNode: null,
    nextSibling: null,
    _childList: [],
    writes: { text: 0, className: 0, value: 0 },
    _className: "",
    _value: "",
    setAttribute: function (key, value) {
      this.attrs[key] = String(value);
    },
    getAttribute: function (key) {
      return Object.prototype.hasOwnProperty.call(this.attrs, key) ? this.attrs[key] : null;
    },
    removeAttribute: function (key) {
      delete this.attrs[key];
    },
    appendChild: function (child) {
      if (child.parentNode && child.parentNode.removeChild) {
        child.parentNode.removeChild(child);
      }
      this._childList.push(child);
      relink(this);
      return child;
    },
    removeChild: function (child) {
      const index = this._childList.indexOf(child);
      if (index < 0) {
        throw new Error("removeChild: not a child");
      }
      this._childList.splice(index, 1);
      child.parentNode = null;
      relink(this);
      return child;
    },
    insertBefore: function (child, want) {
      if (child.parentNode && child.parentNode.removeChild) {
        child.parentNode.removeChild(child);
      }
      if (!want) {
        this._childList.push(child);
      } else {
        const index = this._childList.indexOf(want);
        this._childList.splice(index < 0 ? this._childList.length : index, 0, child);
      }
      relink(this);
      return child;
    },
    addEventListener: function (type, fn) {
      if (!this.listeners[type]) {
        this.listeners[type] = [];
      }
      this.listeners[type].push(fn);
    },
    blur: function () {
      (this.listeners.focusout || []).forEach(function (fn) {
        fn();
      });
    },
    get firstChild() {
      return this._childList[0] || null;
    },
    get lastChild() {
      return this._childList[this._childList.length - 1] || null;
    },
    get childNodes() {
      return this._childList.slice();
    },
    get children() {
      return this._childList.filter(function (child) {
        return child.nodeType === 1;
      });
    },
    get textContent() {
      return this._childList
        .map(function (child) {
          return child.textContent || "";
        })
        .join("");
    },
    set textContent(next) {
      this.writes.text += 1;
      const text = makeLiveText(next);
      text.parentNode = this;
      this._childList = [text];
      relink(this);
    },
    get className() {
      return this._className;
    },
    set className(next) {
      this.writes.className += 1;
      this._className = String(next);
    },
    get value() {
      return this._value;
    },
    set value(next) {
      this.writes.value += 1;
      this._value = String(next);
    },
  };
  return node;
}

function countWrites(node) {
  const acc = {
    text: node.writes ? node.writes.text || 0 : 0,
    nodeValue: node.writes ? node.writes.nodeValue || 0 : 0,
    className: node.writes ? node.writes.className || 0 : 0,
    value: node.writes ? node.writes.value || 0 : 0,
  };
  (node._childList || node.children || []).forEach(function (child) {
    const inner = countWrites(child);
    acc.text += inner.text;
    acc.nodeValue += inner.nodeValue;
    acc.className += inner.className;
    acc.value += inner.value;
  });
  acc.total = acc.text + acc.nodeValue;
  return acc;
}

function deltaWrites(before, after) {
  return {
    text: after.text - before.text,
    nodeValue: after.nodeValue - before.nodeValue,
    className: after.className - before.className,
    value: after.value - before.value,
    total: after.total - before.total,
  };
}

// A real SVG element's className is a read-only SVGAnimatedString (assigning
// it throws under "use strict"), so the fake refuses it, and it refuses any
// setAttribute outside the allowlist even if a caller bypasses svgAttr.
function makeLiveSvgNode(ns, name) {
  if (ns !== SVG_NS) {
    throw new Error("createElementNS namespace " + ns);
  }
  const node = makeLiveNode(name);
  node.namespaceURI = ns;
  const plainSet = node.setAttribute;
  node.setAttribute = function (key, value) {
    if (SVG_ATTRS.indexOf(key) === -1) {
      throw new Error("SVG setAttribute outside the allowlist: " + key);
    }
    plainSet.call(this, key, value);
  };
  Object.defineProperty(node, "className", {
    get: function () {
      return { baseVal: this.getAttribute("class") || "" };
    },
    set: function () {
      throw new TypeError("SVG className is read-only");
    },
  });
  return node;
}

let flowReduce = false;
const mediaQueries = [];
const fetchCalls = [];

const liveSandbox = {
  document: {
    activeElement: null,
    createElement: function (name) {
      return makeLiveNode(name);
    },
    createElementNS: function (ns, name) {
      return makeLiveSvgNode(ns, name);
    },
    getElementById: function () {
      return null;
    },
  },
  matchMedia: function (query) {
    mediaQueries.push(query);
    return { matches: flowReduce && query === "(prefers-reduced-motion: reduce)" };
  },
  fetch: function () {
    fetchCalls.push(Array.prototype.slice.call(arguments));
    return new Promise(function () {});
  },
  URL: URL,
  postDial: function () {},
  resetDial: function () {},
  selectedDispatch: "d-open",
  lastState: null,
  renderAll: function () {},
};
vm.createContext(liveSandbox);
vm.runInContext(extractBlock(/var DIAL_OPTIONS =/), liveSandbox);
vm.runInContext(extractBlock(/var SVG_ALLOW =/), liveSandbox);
vm.runInContext(extractBlock(/var FLOW =/), liveSandbox);
[
  "el",
  "txt",
  "setClass",
  "setAttr",
  "setChip",
  "chip",
  "wordVariant",
  "livenessVariant",
  "bindingVariant",
  "verdictVariant",
  "reviewLabel",
  "publishSignature",
  "fillPublishFacts",
  "renderPublish",
  "parseHttpUrl",
  "linkLabel",
  "appendLinkOrText",
  "dialMetaText",
  "applySelectValue",
  "syncDialSelect",
  "setDisabled",
  "createDial",
  "updateDial",
  "createUnit",
  "updateUnit",
  "createOpenDispatch",
  "updateOpenDispatch",
  "appendCell",
  "createDispatchRow",
  "updateDispatchRow",
  "createGate",
  "updateGate",
  "tile",
  "updateTile",
  "pad2",
  "stampUpdated",
].concat(FLOW_HELPERS).forEach(function (name) {
  vm.runInContext(
    "this." + name + " = " + extractBlock(new RegExp("function " + name + "\\(")),
    liveSandbox
  );
});

const GATE_CAVEAT = "Recorded gate result — not proof of what ships.";

check("update: txt assigns only when the shown text differs (headless; no browser DOM)", function () {
  const node = makeLiveNode("p");
  liveSandbox.txt(node, "hello");
  const afterCreate = countWrites(node);
  if (node.textContent !== "hello") {
    throw new Error("initial text " + node.textContent);
  }
  liveSandbox.txt(node, "hello");
  const quiet = deltaWrites(afterCreate, countWrites(node));
  if (quiet.total !== 0) {
    throw new Error("identical txt wrote " + JSON.stringify(quiet));
  }
  liveSandbox.txt(node, "world");
  if (node.textContent !== "world") {
    throw new Error("changed text " + node.textContent);
  }
  const changed = deltaWrites(afterCreate, countWrites(node));
  if (changed.total < 1) {
    throw new Error("changed txt did not write");
  }
});

check("update: updateUnit applies a changed review and is quiet when unchanged (headless)", function () {
  const unit = {
    unit: "u-two",
    status: "open",
    rounds: 1,
    review: "not recorded",
    publish: "not recorded",
  };
  const box = liveSandbox.createUnit(unit);
  if (box._review.textContent !== "Review not recorded") {
    throw new Error("create review " + box._review.textContent);
  }
  const before = countWrites(box);
  liveSandbox.updateUnit(box, unit);
  const quiet = deltaWrites(before, countWrites(box));
  if (quiet.total !== 0 || quiet.className !== 0) {
    throw new Error("unchanged unit wrote " + JSON.stringify(quiet));
  }
  const nameBefore = countWrites(box._name);
  const reviewBefore = countWrites(box._review);
  liveSandbox.updateUnit(box, {
    unit: "u-two",
    status: "open",
    rounds: 1,
    review: { verdict: "iterate", round: 1 },
    publish: "not recorded",
  });
  if (box._review.textContent !== "Review iterate") {
    throw new Error("review stayed " + box._review.textContent);
  }
  if (deltaWrites(nameBefore, countWrites(box._name)).total !== 0) {
    throw new Error("unrelated unit name mutated");
  }
  if (deltaWrites(reviewBefore, countWrites(box._review)).total < 1) {
    throw new Error("review node did not mutate");
  }
});

check("update: vitals/dispatch/gate/table apply changed fields only (headless)", function () {
  const card = liveSandbox.tile("Journal", "ok", "same", "ok");
  let snap = countWrites(card);
  liveSandbox.updateTile(card, "ok", "same", "ok");
  if (deltaWrites(snap, countWrites(card)).total !== 0) {
    throw new Error("unchanged tile wrote");
  }
  liveSandbox.updateTile(card, "dirty", "note", "caution");
  if (card._value.textContent !== "dirty" || card._qualifier.textContent !== "note") {
    throw new Error("tile values " + card._value.textContent + "/" + card._qualifier.textContent);
  }

  const pick = liveSandbox.createOpenDispatch({
    dispatch_id: "d-open",
    backend: "codex",
    mode: "implement",
    liveness: { state: "idle", idle_minutes: 3, source: "/tmp/a" },
  });
  snap = countWrites(pick);
  liveSandbox.updateOpenDispatch(pick, {
    dispatch_id: "d-open",
    backend: "codex",
    mode: "implement",
    liveness: { state: "idle", idle_minutes: 3, source: "/tmp/a" },
  });
  if (deltaWrites(snap, countWrites(pick)).total !== 0) {
    throw new Error("unchanged dispatch card wrote");
  }
  liveSandbox.updateOpenDispatch(pick, {
    dispatch_id: "d-open",
    backend: "grok",
    mode: "read-only",
    liveness: { state: "recent activity", idle_minutes: 1, source: "/tmp/b" },
  });
  if (pick._chip.textContent !== "recent activity") {
    throw new Error("liveness " + pick._chip.textContent);
  }
  if (pick._meta.textContent !== "grok · read-only") {
    throw new Error("meta " + pick._meta.textContent);
  }
  if (pick._path.textContent !== "/tmp/b") {
    throw new Error("path " + pick._path.textContent);
  }

  const row = liveSandbox.createDispatchRow({
    dispatch_id: "d-1",
    backend: "codex",
    mode: "implement",
    state: "open",
    exit: null,
  });
  snap = countWrites(row);
  liveSandbox.updateDispatchRow(row, {
    dispatch_id: "d-1",
    backend: "codex",
    mode: "implement",
    state: "open",
    exit: null,
  });
  if (deltaWrites(snap, countWrites(row)).total !== 0) {
    throw new Error("unchanged table row wrote");
  }
  liveSandbox.updateDispatchRow(row, {
    dispatch_id: "d-1",
    backend: "codex",
    mode: "read-only",
    state: "closed",
    exit: 0,
  });
  if (row.children[2].textContent !== "read-only" || row.children[3].textContent !== "closed") {
    throw new Error("table cells were not updated");
  }

  const gate = liveSandbox.createGate({
    binding: "dirty",
    policy: "baseline",
    purpose: "unit",
  });
  snap = countWrites(gate);
  liveSandbox.updateGate(gate, { binding: "dirty", policy: "baseline", purpose: "unit" });
  if (deltaWrites(snap, countWrites(gate)).total !== 0) {
    throw new Error("unchanged gate wrote");
  }
  liveSandbox.updateGate(gate, {
    binding: "clean",
    policy: "strict",
    purpose: "publish",
    verdict: "green",
  });
  if (gate._badge.textContent !== "clean") {
    throw new Error("binding " + gate._badge.textContent);
  }
  if (gate._meta.textContent !== "strict · publish") {
    throw new Error("gate meta " + gate._meta.textContent);
  }
  if (gate._verdict.textContent !== "green" || !/\bis-ok\b/.test(gate._verdict.className)) {
    throw new Error("verdict " + gate._verdict.textContent + " " + gate._verdict.className);
  }
  if (gate._note.textContent !== GATE_CAVEAT) {
    throw new Error("caveat " + gate._note.textContent);
  }
  liveSandbox.updateGate(gate, {
    binding: "clean",
    policy: "strict",
    purpose: "publish",
    verdict: "red",
  });
  if (gate._verdict.textContent !== "red" || !/\bis-danger\b/.test(gate._verdict.className)) {
    throw new Error("verdict update " + gate._verdict.textContent + " " + gate._verdict.className);
  }
  liveSandbox.updateGate(gate, { binding: "clean", policy: "strict", purpose: "publish" });
  if (gate._verdict.textContent !== "unknown" || !/\bis-neutral\b/.test(gate._verdict.className)) {
    throw new Error("absent verdict " + gate._verdict.textContent + " " + gate._verdict.className);
  }
  if (gate._note.textContent !== GATE_CAVEAT) {
    throw new Error("caveat after update " + gate._note.textContent);
  }
});

function liveChips(card, marker) {
  const found = [];
  (function visit(node) {
    if (/\bchip\b/.test(node.className || "") && new RegExp("\\b" + marker + "\\b").test(node.className)) {
      found.push(node);
    }
    (node.children || []).forEach(visit);
  })(card);
  return found;
}

function expectCleanGateCard(gate, word, variant) {
  const card = liveSandbox.createGate(gate);
  const verdicts = liveChips(card, "gate-verdict");
  if (verdicts.length !== 1) {
    throw new Error("verdict chip count " + verdicts.length);
  }
  if (verdicts[0].textContent !== word) {
    throw new Error("verdict text " + verdicts[0].textContent);
  }
  ["ok", "caution", "danger", "neutral"].forEach(function (name) {
    if (new RegExp("\\bis-" + name + "\\b").test(verdicts[0].className) !== (name === variant)) {
      throw new Error("verdict class " + verdicts[0].className);
    }
  });
  const bindings = liveChips(card, "gate-binding");
  if (bindings.length !== 1 || bindings[0].textContent !== "clean") {
    throw new Error("binding chip lost");
  }
  if (card._meta.textContent !== "strict · unit-final") {
    throw new Error("gate meta " + card._meta.textContent);
  }
  if (card._note.textContent !== GATE_CAVEAT) {
    throw new Error("caveat " + card._note.textContent);
  }
  if (card.textContent.indexOf(GATE_CAVEAT) === -1) {
    throw new Error("card text lacks the caveat: " + card.textContent);
  }
  if (/publication evidence/i.test(card.textContent)) {
    throw new Error("card claims publication evidence: " + card.textContent);
  }
}

check("render: clean green gate shows verdict chip 'green' (is-ok), the fixed caveat, no 'Publication evidence' (headless)", function () {
  expectCleanGateCard(
    { binding: "clean", policy: "strict", purpose: "unit-final", verdict: "green", gate_exit: 0 },
    "green",
    "ok"
  );
});

check("render: clean red gate shows verdict chip 'red' (is-danger), the fixed caveat, no 'Publication evidence' (headless)", function () {
  expectCleanGateCard(
    { binding: "clean", policy: "strict", purpose: "unit-final", verdict: "red", gate_exit: 1 },
    "red",
    "danger"
  );
});

check("render: clean unknown gate shows verdict chip 'unknown' (is-neutral), the fixed caveat, no 'Publication evidence' (headless)", function () {
  [
    { binding: "clean", policy: "strict", purpose: "unit-final", verdict: "unknown" },
    { binding: "clean", policy: "strict", purpose: "unit-final", totals: "exit=0" },
    { binding: "clean", policy: "strict", purpose: "unit-final", verdict: "maybe", gate_exit: 0 },
  ].forEach(function (gate) {
    expectCleanGateCard(gate, "unknown", "neutral");
  });
});

check("update: updateDial writes changed fields; focused select is skipped until blur (headless)", function () {
  const box = liveSandbox.createDial({
    key: "stop",
    record: { value: "worktree", scope: "policy", source: "default" },
    locked: false,
  });
  const snap = countWrites(box);
  liveSandbox.updateDial(box, {
    key: "stop",
    record: { value: "worktree", scope: "policy", source: "default" },
    locked: false,
  });
  const quiet = deltaWrites(snap, countWrites(box));
  if (quiet.total !== 0 || quiet.value !== 0) {
    throw new Error("unchanged dial wrote " + JSON.stringify(quiet));
  }
  liveSandbox.document.activeElement = box._select;
  liveSandbox.updateDial(box, {
    key: "stop",
    record: {
      value: "merge",
      scope: "permission",
      source: "store",
      set_by: "console",
      set_at: "2026-08-18T00:00:00Z",
      provenance: "selftest",
    },
    locked: false,
  });
  if (box._select.value !== "worktree") {
    throw new Error("focused select was clobbered to " + box._select.value);
  }
  if (box._value.textContent !== "merge") {
    throw new Error("dial current value stayed " + box._value.textContent);
  }
  if (box._meta.textContent.indexOf("permission") === -1 || box._meta.textContent.indexOf("selftest") === -1) {
    throw new Error("dial meta " + box._meta.textContent);
  }
  if (!box._grant || box._grant.textContent !== "grants authority") {
    throw new Error("grants-authority chip was not applied");
  }
  liveSandbox.document.activeElement = null;
  box._select.blur();
  if (box._select.value !== "merge") {
    throw new Error("select was not reapplied after blur: " + box._select.value);
  }
});

check("update: stampUpdated writes #updated-at through txt and is quiet on the same second (headless)", function () {
  const updated = makeLiveNode("p");
  let hours = 14;
  let minutes = 54;
  let seconds = 41;
  liveSandbox.document.getElementById = function (id) {
    return id === "updated-at" ? updated : null;
  };
  liveSandbox.Date = function () {
    return {
      getHours: function () {
        return hours;
      },
      getMinutes: function () {
        return minutes;
      },
      getSeconds: function () {
        return seconds;
      },
    };
  };
  vm.runInContext(
    "this.stampUpdated = " + extractBlock(/function stampUpdated\(/),
    liveSandbox
  );
  liveSandbox.stampUpdated();
  if (updated.textContent !== "Updated 14:54:41") {
    throw new Error("first stamp " + updated.textContent);
  }
  const before = countWrites(updated);
  liveSandbox.stampUpdated();
  if (deltaWrites(before, countWrites(updated)).total !== 0) {
    throw new Error("same-second stamp wrote");
  }
  seconds = 42;
  liveSandbox.stampUpdated();
  if (updated.textContent !== "Updated 14:54:42") {
    throw new Error("later stamp " + updated.textContent);
  }
});

// Flow view fixtures: run objects shaped like loop-index output (counts,
// counts_complete, timeline, timeline_truncated).
function bucket(extra) {
  return Object.assign(
    {
      dispatches: {},
      reviews: { iterate: 0, pass: 0 },
      gates: { green: 0, red: 0, unknown: 0 },
      publishes: 0,
    },
    extra || {}
  );
}

function tally(ok, failed, open, abandoned) {
  return { ok: ok || 0, failed: failed || 0, open: open || 0, abandoned: abandoned || 0 };
}

function flowRun(id, timeline, extra) {
  return Object.assign(
    {
      run_id: id,
      status: "active",
      counts_complete: true,
      counts: {
        all: bucket({ dispatches: { codex: tally(1) } }),
        units: { u1: bucket() },
        unattributed: bucket(),
      },
      timeline: timeline,
      timeline_truncated: false,
    },
    extra || {}
  );
}

function flowState(active) {
  return {
    context: { state: "active", run: active },
    runs: Array.prototype.slice.call(arguments, 1),
  };
}

function ev(seq, event, extra) {
  return Object.assign({ seq: seq, ts: "2026-09-28T00:00:00Z", event: event }, extra || {});
}

function dispatchEv(seq, event, backend, extra) {
  return ev(
    seq,
    event,
    Object.assign({ dispatch_id: "d-" + seq, backend: backend, attribution: "none" }, extra || {})
  );
}

function evs(from, to, make) {
  const out = [];
  for (let seq = from; seq <= to; seq += 1) {
    out.push(make(seq));
  }
  return out;
}

// Packet-bearing traffic, so a first render has something it must not replay.
function busy(from, to) {
  return evs(from, to, function (seq) {
    switch (seq % 4) {
      case 0:
        return dispatchEv(seq, "dispatch.start", "codex");
      case 1:
        return ev(seq, "gate.result", { gate_verdict: "red", attribution: "none" });
      case 2:
        return ev(seq, "review.recorded", { review_verdict: "pass", attribution: "none" });
      default:
        return ev(seq, "publish.recorded", { attribution: "none" });
    }
  });
}

function flowRoot() {
  return makeLiveNode("div");
}

function packetsOf(root) {
  return root._parts.packets._childList.slice();
}

function classOf(node) {
  if (typeof node.className === "string") {
    return node.className;
  }
  if (node.className && typeof node.className.baseVal === "string") {
    return node.className.baseVal;
  }
  return "";
}

function variantOf(node) {
  const found = classOf(node).match(/\bis-(ok|neutral|caution|danger)\b/g) || [];
  if (found.length !== 1) {
    throw new Error("packet variant classes " + classOf(node));
  }
  return found[0].slice(3);
}

function edgeLabel(root, key) {
  const group = root._parts.edges._byId[key];
  if (!group) {
    throw new Error("no edge " + key);
  }
  return group._label.textContent;
}

function edgePath(backends, key, back) {
  const edge = liveSandbox.flowLayout(backends).edges.filter(function (item) {
    return item.key === key;
  })[0];
  if (!edge) {
    throw new Error("layout has no edge " + key);
  }
  return back ? edge.back : edge.out;
}

function fire(node, type) {
  (node.listeners[type] || []).slice().forEach(function (fn) {
    fn({ type: type, target: node });
  });
}

function chooseFilter(root, label) {
  const select = root._parts.filter;
  const option = select.children.filter(function (child) {
    return child.textContent === label;
  })[0];
  if (!option) {
    throw new Error("no filter option " + label);
  }
  select.value = option.getAttribute("value");
  fire(select, "change");
}

function liveWalk(node, visit) {
  visit(node);
  (node._childList || []).forEach(function (child) {
    liveWalk(child, visit);
  });
}

function nodeLabels(root) {
  return root._parts.nodes.children.map(function (group) {
    return group._name.textContent;
  });
}

check("flow: implementer nodes exist only for backends present in counts, in the order claude, codex, cursor, grok, then unknown backend (headless)", function () {
  const root = flowRoot();
  const run = flowRun("A", busy(1, 4));
  run.counts.all.dispatches = { grok: tally(1), unknown: tally(2), codex: tally(0, 1), claude: tally(1) };
  liveSandbox.drawFlow(root, flowState("A", run));
  const labels = nodeLabels(root).join(",");
  if (labels !== "Judge,claude,codex,grok,unknown backend,Review,Gate,Publication") {
    throw new Error("nodes " + labels);
  }
  const edges = Object.keys(root._parts.edges._byId).sort().join(",");
  if (edges !== "gate,impl-claude,impl-codex,impl-grok,impl-unknown,publish,review") {
    throw new Error("edges " + edges);
  }
  const bare = flowRoot();
  const none = flowRun("B", []);
  none.counts.all.dispatches = {};
  liveSandbox.drawFlow(bare, flowState("B", none));
  if (nodeLabels(bare).join(",") !== "Judge,Review,Gate,Publication") {
    throw new Error("dispatch-free nodes " + nodeLabels(bare).join(","));
  }
  const all = flowRoot();
  const four = flowRun("C", []);
  four.counts.all.dispatches = { grok: tally(1), cursor: tally(1), codex: tally(1), claude: tally(1) };
  liveSandbox.drawFlow(all, flowState("C", four));
  if (nodeLabels(all).join(",") !== "Judge,claude,codex,cursor,grok,Review,Gate,Publication") {
    throw new Error("four-backend nodes " + nodeLabels(all).join(","));
  }
});

check("flow: the first render animates nothing; two new events make exactly two packets with their recorded classes; a repeat makes none (headless)", function () {
  const root = flowRoot();
  const base = busy(1, 8);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", base)));
  if (packetsOf(root).length !== 0) {
    throw new Error("first render made " + packetsOf(root).length + " packets");
  }
  const next = flowRun(
    "A",
    base.concat([
      dispatchEv(9, "dispatch.end", "codex", { exit: 3 }),
      ev(10, "review.recorded", { review_verdict: "iterate", unit: "u1", attribution: "declared" }),
    ])
  );
  liveSandbox.drawFlow(root, flowState("A", next));
  const made = packetsOf(root);
  if (made.length !== 2) {
    throw new Error("update made " + made.length + " packets");
  }
  if (!/\bflow-packet\b/.test(classOf(made[0])) || variantOf(made[0]) !== "danger") {
    throw new Error("nonzero-exit packet " + classOf(made[0]));
  }
  if (made[0].getAttribute("d") !== edgePath(["codex"], "impl-codex", true)) {
    throw new Error("dispatch.end did not travel codex → Judge: " + made[0].getAttribute("d"));
  }
  if (variantOf(made[1]) !== "caution" || made[1].getAttribute("d") !== edgePath(["codex"], "review", false)) {
    throw new Error("iterate packet " + classOf(made[1]) + " " + made[1].getAttribute("d"));
  }
  liveSandbox.drawFlow(root, flowState("A", next));
  liveSandbox.drawFlow(root, flowState("A", JSON.parse(JSON.stringify(next))));
  if (packetsOf(root).length !== 2) {
    throw new Error("a repeated update animated again: " + packetsOf(root).length);
  }
  fire(made[0], "animationend");
  if (packetsOf(root).length !== 1 || packetsOf(root)[0] !== made[1]) {
    throw new Error("animationend did not remove its packet");
  }
});

check("flow: packet variants are recorded outcomes: exit 0, pass, green, and unknown are neutral; nonzero exit, red, and abandoned are danger; iterate is caution; nothing is is-ok (headless)", function () {
  const root = flowRoot();
  const base = busy(1, 4);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", base)));
  const unit = { unit: "u1", attribution: "declared" };
  const added = [
    [dispatchEv(5, "dispatch.start", "codex"), "neutral"],
    [dispatchEv(6, "dispatch.end", "codex", { exit: 0 }), "neutral"],
    [ev(7, "review.recorded", Object.assign({ review_verdict: "pass" }, unit)), "neutral"],
    [ev(8, "gate.result", Object.assign({ gate_verdict: "green", binding: "clean" }, unit)), "neutral"],
    [ev(9, "publish.recorded", unit), "neutral"],
    [dispatchEv(10, "dispatch.end", "codex", { exit: 2 }), "danger"],
    [dispatchEv(11, "dispatch.abandoned", "codex"), "danger"],
    [ev(12, "gate.result", Object.assign({ gate_verdict: "red" }, unit)), "danger"],
    [ev(13, "review.recorded", Object.assign({ review_verdict: "iterate" }, unit)), "caution"],
    [ev(14, "gate.result", { gate_verdict: "unknown", attribution: "none" }), "neutral"],
    [dispatchEv(15, "dispatch.end", "codex"), "neutral"],
    [ev(16, "review.recorded", { review_verdict: "unknown", attribution: "none" }), "neutral"],
  ];
  const run = flowRun(
    "A",
    base.concat(added.map(function (pair) {
      return pair[0];
    }))
  );
  run.counts.all = bucket({
    dispatches: { codex: tally(1, 2, 1, 1) },
    reviews: { pass: 1, iterate: 1 },
    gates: { green: 1, red: 1, unknown: 1 },
    publishes: 1,
  });
  liveSandbox.drawFlow(root, flowState("A", run));
  const made = packetsOf(root);
  if (made.length !== added.length) {
    throw new Error("packets " + made.length);
  }
  made.forEach(function (packet, index) {
    if (variantOf(packet) !== added[index][1]) {
      throw new Error(added[index][0].event + " packet is " + classOf(packet));
    }
  });
  liveWalk(root, function (node) {
    if (/\bis-ok\b/.test(classOf(node))) {
      throw new Error(node.nodeName + " carries is-ok: " + classOf(node));
    }
  });
  if (root.textContent.indexOf("recorded events — not verified") === -1) {
    throw new Error("legend missing: " + root.textContent);
  }
});

check("flow: run.*, unit.*, round.begin, checkpoint, journal.repaired, and unknown-backend dispatches make no packet (headless)", function () {
  const root = flowRoot();
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", busy(1, 4))));
  const quiet = busy(1, 4).concat([
    ev(5, "run.begin"),
    ev(6, "unit.begin", { unit: "u1" }),
    ev(7, "round.begin", { unit: "u1" }),
    ev(8, "checkpoint"),
    ev(9, "journal.repaired"),
    ev(10, "unit.end", { unit: "u1" }),
    ev(11, "run.end"),
    dispatchEv(12, "dispatch.start", "unknown"),
    dispatchEv(13, "dispatch.end", "unknown", { exit: 1 }),
    ev(14, "dispatch.end", { exit: 1, attribution: "none" }),
    ev(15, "dispatch.start", { dispatch_id: "d-x", backend: "nonesuch", attribution: "none" }),
  ]);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", quiet)));
  if (packetsOf(root).length !== 0) {
    throw new Error("packets " + packetsOf(root).map(function (p) {
      return p.getAttribute("d");
    }).join(" | "));
  }
});

check("flow: a run switch clears packets without replaying and keeps a separate high-water mark per run (headless)", function () {
  const root = flowRoot();
  const a = busy(1, 50);
  const a2 = a.concat(busy(51, 52));
  const b = busy(1, 3);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", a), flowRun("B", b)));
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", a2), flowRun("B", b)));
  if (packetsOf(root).length !== 2) {
    throw new Error("A's update made " + packetsOf(root).length);
  }
  liveSandbox.drawFlow(root, flowState("B", flowRun("A", a2), flowRun("B", b)));
  if (packetsOf(root).length !== 0) {
    throw new Error("run switch left or replayed " + packetsOf(root).length + " packets");
  }
  const marks = root._flow.marks;
  if (marks["r:B"] !== 3 || marks["r:A"] !== 52) {
    throw new Error("marks " + JSON.stringify(marks));
  }
  liveSandbox.drawFlow(root, flowState("B", flowRun("A", a2), flowRun("B", busy(1, 4))));
  if (packetsOf(root).length !== 1) {
    throw new Error("B's next event made " + packetsOf(root).length + " packets; its mark is not its own");
  }
});

check("flow: A → B → A animates exactly the events A gained while B was shown (headless)", function () {
  const root = flowRoot();
  const a = busy(1, 6);
  const b = busy(1, 3);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", a), flowRun("B", b)));
  liveSandbox.drawFlow(root, flowState("B", flowRun("A", a), flowRun("B", b)));
  const gained = a.concat([
    ev(7, "gate.result", { gate_verdict: "red", attribution: "none" }),
    ev(8, "checkpoint"),
    ev(9, "publish.recorded", { attribution: "none" }),
  ]);
  liveSandbox.drawFlow(root, flowState("B", flowRun("A", gained), flowRun("B", b)));
  if (packetsOf(root).length !== 0) {
    throw new Error("B animated A's events");
  }
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", gained), flowRun("B", b)));
  const made = packetsOf(root);
  if (made.length !== 2) {
    throw new Error("return to A made " + made.length + " packets");
  }
  if (made[0].getAttribute("d") !== edgePath(["codex"], "gate", false) || variantOf(made[0]) !== "danger") {
    throw new Error("first packet " + made[0].getAttribute("d") + " " + classOf(made[0]));
  }
  if (made[1].getAttribute("d") !== edgePath(["codex"], "publish", false) || variantOf(made[1]) !== "neutral") {
    throw new Error("second packet " + made[1].getAttribute("d") + " " + classOf(made[1]));
  }
});

check("flow: 21 new events in one update leave at most 20 packet elements, oldest removed first (headless)", function () {
  const root = flowRoot();
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", [])));
  const burst = [ev(1, "gate.result", { gate_verdict: "red", attribution: "none" })].concat(
    evs(2, 21, function (seq) {
      return dispatchEv(seq, "dispatch.start", "codex");
    })
  );
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", burst)));
  const made = packetsOf(root);
  if (made.length !== 20) {
    throw new Error("packet elements " + made.length);
  }
  if (made.some(function (packet) {
    return variantOf(packet) === "danger";
  })) {
    throw new Error("the oldest packet was not the one removed");
  }
});

check("flow: reduced motion creates no packet while edge labels still update (headless)", function () {
  flowReduce = true;
  const created = [];
  const plainCreate = liveSandbox.document.createElementNS;
  try {
    const root = flowRoot();
    liveSandbox.drawFlow(root, flowState("A", flowRun("A", busy(1, 4))));
    if (edgeLabel(root, "impl-codex") !== "1 exit 0") {
      throw new Error("first label " + edgeLabel(root, "impl-codex"));
    }
    liveSandbox.document.createElementNS = function (ns, name) {
      created.push(name);
      return plainCreate(ns, name);
    };
    const next = flowRun("A", busy(1, 12));
    next.counts.all.dispatches.codex = tally(5, 2);
    liveSandbox.drawFlow(root, flowState("A", next));
    if (packetsOf(root).length !== 0 || created.length !== 0) {
      throw new Error("reduced motion made packets: " + packetsOf(root).length + " / created " + created.join(","));
    }
    if (edgeLabel(root, "impl-codex") !== "5 exit 0 · 2 failed") {
      throw new Error("label did not update: " + edgeLabel(root, "impl-codex"));
    }
    if (mediaQueries.indexOf("(prefers-reduced-motion: reduce)") === -1) {
      throw new Error("matchMedia was not asked about reduced motion");
    }
  } finally {
    flowReduce = false;
    liveSandbox.document.createElementNS = plainCreate;
  }
});

check("flow: a dispatch.end whose start fell outside the window routes back from its resolved backend (headless)", function () {
  const root = flowRoot();
  const counts = {
    all: bucket({ dispatches: { codex: tally(300), grok: tally(200) } }),
    units: {},
    unattributed: bucket({ dispatches: { codex: tally(300), grok: tally(200) } }),
  };
  const win = busy(600, 601);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", win, { counts: counts, timeline_truncated: true })));
  const next = win.concat([
    ev(602, "dispatch.end", { dispatch_id: "d-early", backend: "grok", exit: 0, attribution: "none" }),
  ]);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", next, { counts: counts, timeline_truncated: true })));
  const made = packetsOf(root);
  if (made.length !== 1) {
    throw new Error("packets " + made.length);
  }
  if (made[0].getAttribute("d") !== edgePath(["codex", "grok"], "impl-grok", true) || variantOf(made[0]) !== "neutral") {
    throw new Error("packet " + made[0].getAttribute("d") + " " + classOf(made[0]));
  }
});

check("flow: a conflicted dispatch lands under All and Unattributed and under no unit, for every filter value (headless)", function () {
  const base = busy(1, 4);
  const counts = {
    all: bucket({ dispatches: { codex: tally(1, 1) } }),
    units: { u1: bucket({ dispatches: { codex: tally(1) } }), u2: bucket() },
    unattributed: bucket({ dispatches: { codex: tally(0, 1) } }),
  };
  const conflicted = [
    ev(5, "dispatch.start", { dispatch_id: "d-c", backend: "codex", attribution: "conflict" }),
    ev(6, "dispatch.end", { dispatch_id: "d-c", backend: "codex", exit: 1, attribution: "conflict" }),
  ];
  const expected = { All: 2, u1: 0, u2: 0, Unattributed: 2 };
  const labels = { All: "1 exit 0 · 1 failed", u1: "1 exit 0", u2: "0 dispatches", Unattributed: "1 failed" };
  Object.keys(expected).forEach(function (label) {
    const root = flowRoot();
    liveSandbox.drawFlow(root, flowState("A", flowRun("A", base, { counts: counts })));
    chooseFilter(root, label);
    if (packetsOf(root).length !== 0) {
      throw new Error("filter change to " + label + " replayed packets");
    }
    liveSandbox.drawFlow(root, flowState("A", flowRun("A", base.concat(conflicted), { counts: counts })));
    if (packetsOf(root).length !== expected[label]) {
      throw new Error(label + ": " + packetsOf(root).length + " packets");
    }
    const listed = root._parts.recent.textContent.indexOf("conflicting labels") !== -1;
    if (listed !== expected[label] > 0) {
      throw new Error(label + ": event list " + root._parts.recent.textContent);
    }
    if (edgeLabel(root, "impl-codex") !== labels[label]) {
      throw new Error(label + ": label " + edgeLabel(root, "impl-codex"));
    }
  });
});

check("flow: each packet-bearing event lands under All and its unit, not under Unattributed; a unit-less gate and a partial dispatch that still names a unit land under Unattributed only (headless)", function () {
  const declared = { unit: "u1", attribution: "declared" };
  const owned = { All: 1, u1: 1, Unattributed: 0 };
  const cases = [
    [ev(5, "dispatch.start", Object.assign({ dispatch_id: "d-x", backend: "codex", round: 1 }, declared)), owned],
    [ev(5, "dispatch.end", Object.assign({ dispatch_id: "d-x", backend: "codex", exit: 0 }, declared)), owned],
    [ev(5, "dispatch.abandoned", Object.assign({ dispatch_id: "d-x", backend: "codex" }, declared)), owned],
    [ev(5, "review.recorded", Object.assign({ review_verdict: "pass" }, declared)), owned],
    [ev(5, "gate.result", Object.assign({ gate_verdict: "green", purpose: "unit-final" }, declared)), owned],
    [ev(5, "publish.recorded", declared), owned],
    [ev(5, "gate.result", { gate_verdict: "unknown", attribution: "none" }), { All: 1, u1: 0, Unattributed: 1 }],
    [
      ev(5, "dispatch.end", { dispatch_id: "d-p", backend: "codex", exit: 0, unit: "u1", round: 1, attribution: "partial" }),
      { All: 1, u1: 0, Unattributed: 1 },
    ],
  ];
  cases.forEach(function (entry) {
    Object.keys(entry[1]).forEach(function (label) {
      const root = flowRoot();
      const base = busy(1, 4);
      liveSandbox.drawFlow(root, flowState("A", flowRun("A", base)));
      chooseFilter(root, label);
      liveSandbox.drawFlow(root, flowState("A", flowRun("A", base.concat([entry[0]]))));
      if (packetsOf(root).length !== entry[1][label]) {
        throw new Error(entry[0].event + " (" + entry[0].attribution + ") under " + label + ": " + packetsOf(root).length);
      }
    });
  });
});

check("flow: counts_complete false prefixes every edge label with partial and says the record is damaged (headless)", function () {
  [false, undefined].forEach(function (flag) {
    const root = flowRoot();
    const run = flowRun("A", busy(1, 4));
    if (flag === undefined) {
      delete run.counts_complete;
    } else {
      run.counts_complete = flag;
    }
    liveSandbox.drawFlow(root, flowState("A", run));
    const keys = Object.keys(root._parts.edges._byId);
    if (keys.length !== 4) {
      throw new Error("edges " + keys.join(","));
    }
    keys.forEach(function (key) {
      if (edgeLabel(root, key).indexOf("partial: ") !== 0) {
        throw new Error(key + " label " + edgeLabel(root, key));
      }
      if (!/\bis-partial\b/.test(classOf(root._parts.edges._byId[key]._label))) {
        throw new Error(key + " label class " + classOf(root._parts.edges._byId[key]._label));
      }
    });
    const damaged = root._parts.damaged;
    if (!damaged || damaged.parentNode !== root || !/record is damaged/.test(damaged.textContent)) {
      throw new Error("damaged notice missing");
    }
    if (!/counts partial/.test(root._parts.svg.getAttribute("aria-label"))) {
      throw new Error("aria-label " + root._parts.svg.getAttribute("aria-label"));
    }
  });
  const whole = flowRoot();
  liveSandbox.drawFlow(whole, flowState("A", flowRun("A", busy(1, 4))));
  Object.keys(whole._parts.edges._byId).forEach(function (key) {
    if (/partial/.test(edgeLabel(whole, key))) {
      throw new Error("complete run labelled partial: " + edgeLabel(whole, key));
    }
  });
  if (whole._parts.damaged && whole._parts.damaged.parentNode === whole) {
    throw new Error("complete run says the record is damaged");
  }
});

check("flow: a publication routes Judge → Publication with no gate and after a red gate; no Gate → Publication path is drawn (headless)", function () {
  const judgeLeft = liveSandbox.FLOW.center - liveSandbox.FLOW.nodeW / 2;
  const judgeRight = liveSandbox.FLOW.center + liveSandbox.FLOW.nodeW / 2;
  const publishOut = edgePath(["codex"], "publish", false);
  const declared = { unit: "u1", attribution: "declared" };
  [
    [ev(5, "publish.recorded", declared)],
    [
      ev(5, "gate.result", Object.assign({ gate_verdict: "red", purpose: "unit-final" }, declared)),
      ev(6, "publish.recorded", declared),
    ],
  ].forEach(function (added) {
    const root = flowRoot();
    const base = [ev(1, "run.begin"), ev(2, "unit.begin", { unit: "u1" }), ev(3, "round.begin"), ev(4, "checkpoint")];
    liveSandbox.drawFlow(root, flowState("A", flowRun("A", base)));
    liveSandbox.drawFlow(root, flowState("A", flowRun("A", base.concat(added))));
    const made = packetsOf(root);
    if (made.length !== added.length || made[made.length - 1].getAttribute("d") !== publishOut) {
      throw new Error("publication packet " + made.map(function (p) {
        return p.getAttribute("d");
      }).join(" | "));
    }
    const paths = [];
    liveWalk(root._parts.svg, function (node) {
      if (node.nodeName === "path") {
        paths.push(node.getAttribute("d"));
      }
    });
    if (paths.length < 5) {
      throw new Error("paths " + paths.length);
    }
    paths.forEach(function (d) {
      const nums = (d.match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
      if (nums.length !== 4) {
        throw new Error("unexpected path " + d);
      }
      if ([nums[0], nums[2]].indexOf(judgeLeft) === -1 && [nums[0], nums[2]].indexOf(judgeRight) === -1) {
        throw new Error("path not anchored on Judge: " + d);
      }
    });
    Object.keys(root._parts.edges._byId).forEach(function (key) {
      if (/gate/.test(key) && /publish/.test(key)) {
        throw new Error("gate-publication edge " + key);
      }
    });
  });
});

check("flow: a truncated timeline shows the notice, and edge labels equal the run's counts, not the window (headless)", function () {
  const root = flowRoot();
  const counts = {
    all: bucket({
      dispatches: { codex: tally(412, 7, 1, 2) },
      reviews: { pass: 30, iterate: 12 },
      gates: { green: 40, red: 3, unknown: 1 },
      publishes: 9,
    }),
    units: {},
    unattributed: bucket(),
  };
  const win = busy(1101, 1103);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", win, { counts: counts, timeline_truncated: true })));
  const want = {
    "impl-codex": "412 exit 0 · 7 failed · 1 open · 2 abandoned",
    review: "30 pass · 12 iterate",
    gate: "40 green · 3 red · 1 unknown",
    publish: "9 publications",
  };
  Object.keys(want).forEach(function (key) {
    if (edgeLabel(root, key) !== want[key]) {
      throw new Error(key + " label " + edgeLabel(root, key));
    }
  });
  const notice = root._parts.truncated;
  if (!notice || notice.parentNode !== root || notice.textContent !== "packets show the last 500 events; totals cover the whole run") {
    throw new Error("truncation notice missing");
  }
  const whole = JSON.parse(JSON.stringify(counts));
  whole.all.publishes = 1;
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", win, { counts: whole, timeline_truncated: false })));
  if (notice.parentNode === root) {
    throw new Error("notice stayed after the window stopped truncating");
  }
  if (edgeLabel(root, "publish") !== "1 publication") {
    throw new Error("singular publication label " + edgeLabel(root, "publish"));
  }
});

check("flow: a truncated, damaged run shows one notice that calls counts partial and never claims whole-run totals; each flag alone keeps its own notice (headless)", function () {
  const both = "packets show the last 500 events; counts are partial because the record is damaged";
  const cut = "packets show the last 500 events; totals cover the whole run";
  const damaged = "The run's record is damaged: every count here is partial.";
  function notices(root) {
    return root.children
      .filter(function (child) {
        return /\bflow-notice\b/.test(classOf(child));
      })
      .map(function (child) {
        return child.textContent;
      });
  }
  // [timeline_truncated, counts_complete, notices shown]
  const cases = [
    [true, false, [both]],
    [true, true, [cut]],
    [false, false, [damaged]],
    [false, true, []],
  ];
  // Each state on a fresh root, then one root walked through every state and
  // back, so no notice from an earlier state survives a transition.
  const walked = flowRoot();
  cases.concat(cases.slice().reverse()).forEach(function (entry) {
    [flowRoot(), walked].forEach(function (root) {
      const run = flowRun("A", busy(1, 4), {
        timeline_truncated: entry[0],
        counts_complete: entry[1],
      });
      liveSandbox.drawFlow(root, flowState("A", run));
      const shown = notices(root);
      const state = "truncated " + entry[0] + ", complete " + entry[1];
      if (JSON.stringify(shown) !== JSON.stringify(entry[2])) {
        throw new Error(state + ": notices " + JSON.stringify(shown));
      }
      const claims = root.textContent.indexOf("totals cover the whole run") !== -1;
      if (claims !== (entry[0] && entry[1])) {
        throw new Error(state + ": whole-run claim " + claims);
      }
      if (!entry[1]) {
        if (edgeLabel(root, "impl-codex").indexOf("partial: ") !== 0) {
          throw new Error(state + ": label " + edgeLabel(root, "impl-codex"));
        }
        if (!/\bis-damaged\b/.test(root._parts.damaged.className)) {
          throw new Error(state + ": notice class " + root._parts.damaged.className);
        }
      }
    });
  });
});

check("flow: a dispatch with no usable start draws an unknown backend node after grok with its count label, makes no packet, and leaves when the filter excludes it (headless)", function () {
  const root = flowRoot();
  const base = busy(1, 4);
  const plain = {
    all: bucket({ dispatches: { codex: tally(1), grok: tally(1) } }),
    units: { u1: bucket({ dispatches: { codex: tally(1) } }) },
    unattributed: bucket({ dispatches: { grok: tally(1) } }),
  };
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", base, { counts: plain })));
  if (nodeLabels(root).join(",") !== "Judge,codex,grok,Review,Gate,Publication") {
    throw new Error("no unknown entry, nodes " + nodeLabels(root).join(","));
  }
  // loop-index output for an orphan dispatch.end: backend unknown,
  // attribution partial, counted under all and unattributed only.
  const counts = JSON.parse(JSON.stringify(plain));
  counts.all.dispatches.unknown = tally(0, 1);
  counts.unattributed.dispatches.unknown = tally(0, 1);
  const orphan = ev(5, "dispatch.end", {
    dispatch_id: "d-orphan",
    backend: "unknown",
    exit: 1,
    attribution: "partial",
  });
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", base.concat([orphan]), { counts: counts })));
  function expectUnknown(where, shown, label) {
    const nodes = nodeLabels(root).join(",");
    const want = shown
      ? "Judge,codex,grok,unknown backend,Review,Gate,Publication"
      : "Judge,codex,grok,Review,Gate,Publication";
    if (nodes !== want) {
      throw new Error(where + ": nodes " + nodes);
    }
    const edge = root._parts.edges._byId["impl-unknown"];
    if (shown ? !edge || edgeLabel(root, "impl-unknown") !== label : edge) {
      throw new Error(where + ": unknown edge " + (edge ? edge._label.textContent : "absent"));
    }
    if (packetsOf(root).length !== 0) {
      throw new Error(where + ": packets " + packetsOf(root).map(function (p) {
        return p.getAttribute("d");
      }).join(" | "));
    }
    const aria = root._parts.svg.getAttribute("aria-label");
    if (/plus dispatches with an unknown backend/.test(aria) !== shown) {
      throw new Error(where + ": aria-label " + aria);
    }
  }
  expectUnknown("All", true, "1 failed");
  if (!/2 implementers, plus dispatches with an unknown backend, 3 dispatches/.test(root._parts.svg.getAttribute("aria-label"))) {
    throw new Error("aria-label " + root._parts.svg.getAttribute("aria-label"));
  }
  if (root._parts.recent.textContent.indexOf("#5 dispatch.end: unknown backend → Judge · exit 1") === -1) {
    throw new Error("event list " + root._parts.recent.textContent);
  }
  chooseFilter(root, "u1");
  expectUnknown("u1", false);
  chooseFilter(root, "Unattributed");
  expectUnknown("Unattributed", true, "1 failed");
  chooseFilter(root, "All");
  expectUnknown("All again", true, "1 failed");
  const more = base.concat([
    orphan,
    ev(6, "dispatch.abandoned", { dispatch_id: "d-lost", backend: "unknown", attribution: "partial" }),
  ]);
  counts.all.dispatches.unknown = tally(0, 1, 0, 1);
  counts.unattributed.dispatches.unknown = tally(0, 1, 0, 1);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", more, { counts: counts, counts_complete: false })));
  expectUnknown("partial", true, "partial: 1 failed · 1 abandoned");

  // Four backends and unknown: five rows, all inside the viewBox, none overlapping.
  const four = flowRoot();
  const wide = flowRun("B", []);
  wide.counts.all.dispatches = { unknown: tally(1), grok: tally(1), cursor: tally(1), codex: tally(1), claude: tally(1) };
  liveSandbox.drawFlow(four, flowState("B", wide));
  if (nodeLabels(four).join(",") !== "Judge,claude,codex,cursor,grok,unknown backend,Review,Gate,Publication") {
    throw new Error("four-row nodes " + nodeLabels(four).join(","));
  }
  let floor = -Infinity;
  ["claude", "codex", "cursor", "grok", "unknown"].forEach(function (name) {
    const box = four._parts.nodes._byId["impl-" + name]._box;
    const top = Number(box.getAttribute("y"));
    const bottom = top + Number(box.getAttribute("height"));
    if (top < 0 || bottom > liveSandbox.FLOW.height || top < floor) {
      throw new Error(name + " node spans " + top + ".." + bottom);
    }
    floor = bottom;
  });
});

check("flow: the hidden list holds the last ten timeline events of every type; unit-less types show under All only (headless)", function () {
  const root = flowRoot();
  const declared = { unit: "u1", attribution: "declared" };
  const timeline = busy(1, 18).concat([
    ev(19, "gate.result", { gate_verdict: "red", attribution: "none" }),
    ev(20, "publish.recorded", { attribution: "none" }),
    // A unit field on a unit-less type must not move it under that unit.
    ev(21, "round.begin", declared),
    ev(22, "unit.begin", declared),
    ev(23, "dispatch.start", Object.assign({ dispatch_id: "d-u", backend: "codex" }, declared)),
    ev(24, "dispatch.end", Object.assign({ dispatch_id: "d-u", backend: "codex", exit: 0 }, declared)),
    ev(25, "checkpoint"),
    ev(26, "review.recorded", Object.assign({ review_verdict: "pass" }, declared)),
    ev(27, "gate.result", Object.assign({ gate_verdict: "green" }, declared)),
    ev(28, "unit.end", declared),
    ev(29, "journal.repaired"),
    ev(30, "checkpoint"),
  ]);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", timeline)));
  function listed() {
    return root._parts.recent.children.map(function (row) {
      return row.textContent;
    });
  }
  function expectList(where, want) {
    const got = listed();
    if (got.length > 10 || JSON.stringify(got) !== JSON.stringify(want)) {
      throw new Error(where + ": list " + JSON.stringify(got));
    }
  }
  if (root._parts.recentHead.textContent !== "Last ten recorded events") {
    throw new Error("heading " + root._parts.recentHead.textContent);
  }
  const owned = [
    "#23 dispatch.start: Judge → codex · unit u1",
    "#24 dispatch.end: codex → Judge · exit 0 · unit u1",
    "#26 review.recorded: Judge → Review · pass · unit u1",
    "#27 gate.result: Judge → Gate · green · unit u1",
  ];
  expectList("All", [
    "#21 round.begin",
    "#22 unit.begin",
    owned[0],
    owned[1],
    "#25 checkpoint",
    owned[2],
    owned[3],
    "#28 unit.end",
    "#29 journal.repaired",
    "#30 checkpoint",
  ]);
  chooseFilter(root, "u1");
  expectList("u1", owned);
  chooseFilter(root, "Unattributed");
  const unattributed = listed();
  if (unattributed.length !== 10 || unattributed[9] !== "#20 publish.recorded: Judge → Publication · unattributed") {
    throw new Error("Unattributed: list " + JSON.stringify(unattributed));
  }
  if (/checkpoint|unit\.|round\.begin|journal\.repaired/.test(unattributed.join(" | "))) {
    throw new Error("Unattributed lists a unit-less type: " + JSON.stringify(unattributed));
  }
  chooseFilter(root, "All");
  const quiet = evs(31, 70, function (seq) {
    return ev(seq, ["checkpoint", "round.begin", "unit.begin", "unit.end"][seq % 4], declared);
  });
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", timeline.concat(quiet))));
  const tail = listed();
  if (tail.length !== 10 || tail[0].indexOf("#61 ") !== 0 || tail[9].indexOf("#70 ") !== 0) {
    throw new Error("All after 40 unit-less events: " + JSON.stringify(tail));
  }
  chooseFilter(root, "u1");
  expectList("u1 after 40 unit-less events", owned);
});

check("flow: a hostile unit name reaches the DOM only as text (headless)", function () {
  const hostile = "<img src=x onerror=1>";
  const root = flowRoot();
  const counts = {
    all: bucket({ dispatches: { codex: tally(1) }, publishes: 1 }),
    units: {},
    unattributed: bucket(),
  };
  counts.units[hostile] = bucket({ dispatches: { codex: tally(1) }, publishes: 1 });
  const declared = { unit: hostile, attribution: "declared" };
  const base = [ev(1, "publish.recorded", declared)];
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", base, { counts: counts })));
  chooseFilter(root, hostile);
  liveSandbox.drawFlow(
    root,
    flowState(
      "A",
      flowRun(
        "A",
        base.concat([
          ev(2, "dispatch.start", Object.assign({ dispatch_id: "d-h", backend: "codex" }, declared)),
          ev(3, "review.recorded", Object.assign({ review_verdict: "pass" }, declared)),
        ]),
        { counts: counts }
      )
    )
  );
  if (packetsOf(root).length !== 2) {
    throw new Error("hostile-unit filter packets " + packetsOf(root).length);
  }
  if (root._parts.svg.getAttribute("role") !== "img" || !root._parts.svg.getAttribute("aria-label")) {
    throw new Error("svg role/aria-label missing");
  }
  let textHits = 0;
  liveWalk(root, function (node) {
    if (node.nodeName === "img") {
      throw new Error("an img element exists");
    }
    Object.keys(node.attrs || {}).forEach(function (key) {
      if (node.attrs[key].indexOf(hostile) !== -1 || node.attrs[key].indexOf("<") !== -1) {
        throw new Error("attribute " + key + " carries journal text: " + node.attrs[key]);
      }
    });
    if (node.nodeType === 3 && node.nodeValue.indexOf(hostile) !== -1) {
      textHits += 1;
      const host = node.parentNode;
      if (!host || (host.nodeName !== "option" && host.nodeName !== "li")) {
        throw new Error("journal text under " + (host && host.nodeName));
      }
    }
  });
  if (textHits < 2) {
    throw new Error("hostile name was not shown as text (" + textHits + ")");
  }
});

check("flow: render, filter change, and run switch make no request (headless)", function () {
  fetchCalls.length = 0;
  const root = flowRoot();
  const saved = liveSandbox.document.getElementById;
  liveSandbox.document.getElementById = function (id) {
    return id === "flow-root" ? root : null;
  };
  try {
    liveSandbox.renderFlow(flowState("A", flowRun("A", busy(1, 4)), flowRun("B", busy(1, 2))));
    liveSandbox.renderFlow(flowState("A", flowRun("A", busy(1, 8)), flowRun("B", busy(1, 2))));
    chooseFilter(root, "u1");
    chooseFilter(root, "Unattributed");
    chooseFilter(root, "All");
    liveSandbox.renderFlow(flowState("B", flowRun("A", busy(1, 8)), flowRun("B", busy(1, 3))));
    chooseFilter(root, "u1");
    liveSandbox.renderFlow(flowState("A", flowRun("A", busy(1, 9)), flowRun("B", busy(1, 3))));
  } finally {
    liveSandbox.document.getElementById = saved;
  }
  if (!root._parts || !root._parts.svg) {
    throw new Error("renderFlow did not draw into #flow-root");
  }
  if (fetchCalls.length !== 0) {
    throw new Error("flow code made " + fetchCalls.length + " requests: " + JSON.stringify(fetchCalls));
  }
  liveSandbox.fetch("/probe");
  if (fetchCalls.length !== 1) {
    throw new Error("the fake fetch does not record calls");
  }
  fetchCalls.length = 0;
});

check("flow: a poll updates the SVG in place; nodes, edges, and filter options keep their identity (headless)", function () {
  const root = flowRoot();
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", busy(1, 4))));
  const svg = root._parts.svg;
  const edges = root._parts.edges.children.slice();
  const nodes = root._parts.nodes.children.slice();
  const options = root._parts.filter.children.slice();
  const codex = root._parts.nodes._byId["impl-codex"];
  const codexY = codex._box.getAttribute("y");
  const next = flowRun("A", busy(1, 9));
  next.counts.all.dispatches.codex = tally(4, 1);
  next.counts.all.dispatches.grok = tally(2);
  next.counts.units.u2 = bucket();
  liveSandbox.drawFlow(root, flowState("A", next));
  if (root._parts.svg !== svg || root._parts.figure.children[0] !== svg) {
    throw new Error("the SVG was rebuilt");
  }
  [
    [edges, root._parts.edges],
    [nodes, root._parts.nodes],
    [options, root._parts.filter],
  ].forEach(function (pair) {
    pair[0].forEach(function (node) {
      if (pair[1].children.indexOf(node) === -1) {
        throw new Error("a " + node.nodeName + " was replaced");
      }
    });
  });
  if (root._parts.nodes._byId["impl-codex"] !== codex || codex._box.getAttribute("y") === codexY) {
    throw new Error("codex node was replaced or not moved for grok");
  }
  if (edgeLabel(root, "impl-codex") !== "4 exit 0 · 1 failed" || edgeLabel(root, "impl-grok") !== "2 exit 0") {
    throw new Error("labels " + edgeLabel(root, "impl-codex") + " / " + edgeLabel(root, "impl-grok"));
  }
  const snap = countWrites(root);
  liveSandbox.drawFlow(root, flowState("A", JSON.parse(JSON.stringify(next))));
  const delta = deltaWrites(snap, countWrites(root));
  if (delta.total !== 0 || delta.className !== 0 || delta.value !== 0) {
    throw new Error("an unchanged poll wrote " + JSON.stringify(delta));
  }
});

check("flow: index output without counts or timeline, or with no runs, shows an empty-state hint (headless)", function () {
  const root = flowRoot();
  function hasSvg() {
    let found = false;
    liveWalk(root, function (node) {
      if (node.nodeName === "svg") {
        found = true;
      }
    });
    return found;
  }
  function expectHint(pattern) {
    if (root._mode !== "hint" || !root.firstChild || root.firstChild.className !== "empty-hint") {
      throw new Error("no empty-state hint (mode " + root._mode + ")");
    }
    if (!pattern.test(root.firstChild.textContent) || hasSvg()) {
      throw new Error("hint " + root.firstChild.textContent);
    }
  }
  liveSandbox.drawFlow(root, { context: { state: "none" }, runs: [] });
  expectHint(/No runs recorded yet/);
  const old = { run_id: "A", status: "active", units: [], dispatches: [], gates: [] };
  liveSandbox.drawFlow(root, flowState("A", old));
  expectHint(/no run totals or timeline/);
  liveSandbox.drawFlow(root, flowState("A", Object.assign({}, old, { counts: { all: bucket() } })));
  expectHint(/no run totals or timeline/);
  liveSandbox.drawFlow(root, flowState("A", Object.assign({}, old, { timeline: [] })));
  expectHint(/no run totals or timeline/);
  liveSandbox.drawFlow(root, flowState("A", flowRun("A", busy(1, 4))));
  if (root._mode !== "flow" || !hasSvg()) {
    throw new Error("flow did not draw once counts and timeline arrived");
  }
  liveSandbox.drawFlow(root, flowState("A", old));
  expectHint(/no run totals or timeline/);
});

// Dial picks run the page's own chain: renderDials -> createDial/updateDial
// for a poll, and the Apply/Reset click handlers -> postDial/resetDial ->
// fetch. Only the DOM and fetch are fakes.
function extractList(name) {
  const match = new RegExp("var " + name + " = \\[[^\\]]*\\];").exec(src);
  if (!match) {
    throw new Error("missing list " + name);
  }
  return match[0];
}

const dialNodes = {};
const dialRequests = [];
const dialSandbox = {
  document: {
    activeElement: null,
    createElement: function (name) {
      return makeLiveNode(name);
    },
    getElementById: function (id) {
      return Object.prototype.hasOwnProperty.call(dialNodes, id) ? dialNodes[id] : null;
    },
  },
  fetch: function (url, init) {
    const request = { url: String(url), init: init || {} };
    const reply = new Promise(function (resolve) {
      request.respond = function (status, payload) {
        resolve({
          ok: status >= 200 && status < 300,
          status: status,
          json: function () {
            return Promise.resolve(payload);
          },
        });
      };
    });
    dialRequests.push(request);
    return reply;
  },
  lastDials: null,
  dialsBusy: false,
  sessionCsrf: "csrf-selftest",
};
vm.createContext(dialSandbox);
vm.runInContext(extractList("DIAL_ORDER"), dialSandbox);
vm.runInContext(extractBlock(/var DIAL_OPTIONS =/), dialSandbox);
vm.runInContext(extractList("PERMISSION_KEYS"), dialSandbox);
[
  "el",
  "txt",
  "setClass",
  "wipe",
  "keyedMap",
  "itemById",
  "syncKeyed",
  "placeBefore",
  "updateOptional",
  "chip",
  "bindLiveRegions",
  "isPermissionKey",
  "setDisabled",
  "dialMetaText",
  "syncDialSelect",
  "createDial",
  "updateDial",
  "dialItems",
  "policyKeys",
  "noticeText",
  "noticeClass",
  "ensureDialsSkeleton",
  "showDialsInert",
  "renderDials",
  "setDialError",
  "apiHeaders",
  "postDial",
  "resetDial",
].forEach(function (name) {
  vm.runInContext(
    "this." + name + " = " + extractBlock(new RegExp("function " + name + "\\(")),
    dialSandbox
  );
});

function dialDoc(stored) {
  const dials = {};
  dialSandbox.DIAL_ORDER.forEach(function (key) {
    dials[key] = { value: dialSandbox.DIAL_OPTIONS[key][0], scope: "policy", source: "default" };
  });
  Object.keys(stored || {}).forEach(function (key) {
    dials[key] = {
      value: stored[key],
      scope: "policy",
      source: "store",
      set_by: "console",
      set_at: "2026-10-05T00:00:00Z",
    };
  });
  return { schema: 1, store: "present", dials: dials };
}

// A fresh page showing the given stored values; returns one dial's card.
function dialPage(key, stored) {
  dialRequests.length = 0;
  dialSandbox.lastDials = null;
  dialSandbox.dialsBusy = false;
  dialSandbox.document.activeElement = null;
  dialNodes["dials-root"] = makeLiveNode("div");
  dialNodes["dials-error"] = makeLiveNode("p");
  dialSandbox.renderDials(dialDoc(stored));
  let box = null;
  liveWalk(dialNodes["dials-root"], function (node) {
    if (node.nodeName === "select" && node.getAttribute("data-dial") === key) {
      box = node.parentNode.parentNode;
    }
  });
  if (!box || !box._select || !box._apply || !box._reset) {
    throw new Error("renderDials drew no card for " + key);
  }
  return box;
}

// What pullDials does with each poll response.
function dialPoll(stored) {
  dialSandbox.renderDials(dialDoc(stored));
}

// Chromium 152 on the real page: when focus moves, document.activeElement is
// already off the old element (it is <body>) while that element's focusout
// handler runs. "late" is the other order, where it still names the old
// element during focusout.
function dialFocus(node, late) {
  const doc = dialSandbox.document;
  const from = doc.activeElement;
  if (from === node) {
    return;
  }
  if (!late) {
    doc.activeElement = null;
  }
  if (from) {
    (from.listeners.focusout || []).forEach(function (fn) {
      fn();
    });
  }
  doc.activeElement = node;
}

function dialEnabled(node) {
  if (node.getAttribute("disabled") !== null) {
    throw new Error(node.nodeName + " " + node.className + " is disabled");
  }
}

function dialPick(select, value) {
  dialEnabled(select);
  dialFocus(select);
  select.value = value;
}

// A mouse click or Tab + Enter: focus reaches the button first, then click.
function dialPress(button, late) {
  dialEnabled(button);
  dialFocus(button, late);
  (button.listeners.click || []).forEach(function (fn) {
    fn();
  });
}

function dialSent(index) {
  const request = dialRequests[index];
  if (!request) {
    throw new Error("no request " + index + " (" + dialRequests.length + " made)");
  }
  return request.init.method + " " + request.url + " " + request.init.body;
}

function expectSelect(box, want, when) {
  if (box._select.value !== want) {
    throw new Error(when + ": select shows " + box._select.value + ", want " + want);
  }
}

function expectSent(index, want, when) {
  if (dialSent(index) !== want) {
    throw new Error(when + ": sent " + dialSent(index) + ", want " + want);
  }
  if (dialRequests.length !== index + 1) {
    throw new Error(when + ": " + dialRequests.length + " requests made");
  }
}

check("dials: a pick survives focus moving to Apply, and Apply posts the pick (headless)", function () {
  [false, true].forEach(function (late) {
    const when = late ? "activeElement still the select in focusout" : "activeElement off the select in focusout";
    const box = dialPage("gate", { gate: "strict" });
    expectSelect(box, "strict", when + ", first render");
    dialPick(box._select, "skip");
    dialPress(box._apply, late);
    expectSent(0, 'POST /api/dials {"key":"gate","value":"skip"}', when);
    if (dialRequests[0].init.headers["X-Console-CSRF"] !== "csrf-selftest") {
      throw new Error(when + ": the request lost its CSRF header");
    }
    expectSelect(box, "skip", when + ", request in flight");
    if (box._value.textContent !== "strict") {
      throw new Error(when + ": stored value shows " + box._value.textContent + " before the reply");
    }
  });
});

check("dials: an unchanged poll leaves an unapplied pick alone, focused or not, and Apply still posts it (headless)", function () {
  const box = dialPage("gate", { gate: "strict" });
  dialPick(box._select, "skip");
  dialPoll({ gate: "strict" });
  expectSelect(box, "skip", "poll while focused");
  dialFocus(null);
  expectSelect(box, "skip", "focus left for the page");
  dialPoll({ gate: "strict" });
  expectSelect(box, "skip", "poll while unfocused");
  dialFocus(box._apply);
  dialPoll({ gate: "strict" });
  expectSelect(box, "skip", "poll between Tab and Enter");
  dialPress(box._apply);
  expectSent(0, 'POST /api/dials {"key":"gate","value":"skip"}', "Apply after three polls");
});

check("dials: a stored value that changes while the select has focus is applied when focus leaves (headless)", function () {
  let box = dialPage("gate", { gate: "strict" });
  dialFocus(box._select);
  dialPoll({ gate: "baseline" });
  expectSelect(box, "strict", "changed poll while focused");
  if (box._value.textContent !== "baseline") {
    throw new Error("stored value text stayed " + box._value.textContent);
  }
  dialPoll({ gate: "baseline" });
  expectSelect(box, "strict", "second poll while focused");
  dialFocus(box._apply);
  expectSelect(box, "baseline", "focus left after a deferred change");

  box = dialPage("gate", { gate: "strict" });
  dialPick(box._select, "skip");
  dialPoll({ gate: "baseline" });
  expectSelect(box, "skip", "changed poll while a pick is focused");
  dialFocus(null);
  expectSelect(box, "baseline", "focus left with a pick and a deferred change");

  box = dialPage("gate", { gate: "strict" });
  dialPick(box._select, "skip");
  dialFocus(null);
  dialPoll({ gate: "baseline" });
  expectSelect(box, "baseline", "changed poll while unfocused");

  box = dialPage("gate", { gate: "strict" });
  dialFocus(box._select);
  dialPoll({ gate: "baseline" });
  dialFocus(null, true);
  dialPoll({ gate: "baseline" });
  expectSelect(box, "baseline", "next poll when activeElement still named the select in focusout");
});

const unsettledChecks = [];
process.on("exit", function () {
  unsettledChecks.forEach(function (name) {
    console.log("not ok - %s: never settled", name);
  });
});

function checkLater(name, fn) {
  unsettledChecks.push(name);
  function settle(error) {
    unsettledChecks.splice(unsettledChecks.indexOf(name), 1);
    if (error) {
      console.log("not ok - %s: %s", name, error.message ? error.message : error);
    } else {
      console.log("ok - %s", name);
    }
  }
  return Promise.resolve()
    .then(fn)
    .then(
      function () {
        settle(null);
      },
      function (error) {
        settle(error || new Error("rejected"));
      }
    );
}

// The reply handlers in postDial/resetDial run as promise jobs.
function dialReply(index, status, payload) {
  dialRequests[index].respond(status, payload);
  return new Promise(function (resolve) {
    setImmediate(resolve);
  });
}

checkLater("dials: a failed Apply keeps the pick for a retry, a successful one shows the stored value, and Reset drops an unapplied pick (headless)", async function () {
  const box = dialPage("gate", { gate: "strict" });
  dialPick(box._select, "skip");
  dialPress(box._apply);
  expectSent(0, 'POST /api/dials {"key":"gate","value":"skip"}', "first Apply");
  if (box._apply.getAttribute("disabled") !== "disabled") {
    throw new Error("Apply stayed enabled while its request was in flight");
  }
  await dialReply(0, 502, { error: "loop-calibration failed" });
  if (dialNodes["dials-error"].textContent !== "loop-calibration failed") {
    throw new Error("error text " + dialNodes["dials-error"].textContent);
  }
  expectSelect(box, "skip", "after a failed Apply");
  if (box._value.textContent !== "strict") {
    throw new Error("a failed Apply changed the stored value text to " + box._value.textContent);
  }
  dialPress(box._apply);
  expectSent(1, 'POST /api/dials {"key":"gate","value":"skip"}', "retry");
  await dialReply(1, 200, dialDoc({ gate: "skip" }));
  expectSelect(box, "skip", "after a successful Apply");
  if (box._value.textContent !== "skip") {
    throw new Error("stored value text " + box._value.textContent + " after a successful Apply");
  }
  dialPoll({ gate: "skip" });
  expectSelect(box, "skip", "poll after a successful Apply");

  dialPick(box._select, "strict");
  dialPress(box._reset);
  expectSent(2, 'POST /api/dials/reset {"key":"gate"}', "Reset");
  expectSelect(box, "skip", "Reset pressed over an unapplied pick");
  await dialReply(2, 200, dialDoc({}));
  expectSelect(box, "baseline", "after Reset");

  dialPick(box._select, "skip");
  dialPress(box._reset);
  expectSent(3, 'POST /api/dials/reset {"key":"gate"}', "Reset at the default");
  expectSelect(box, "baseline", "Reset pressed at the default over an unapplied pick");
  await dialReply(3, 200, dialDoc({}));
  expectSelect(box, "baseline", "after Reset at the default");
  dialPick(box._select, "strict");
  dialPress(box._apply);
  expectSent(4, 'POST /api/dials {"key":"gate","value":"strict"}', "Apply after Reset");
});
JS
then
  :
else
  printf 'not ok - render driver crashed\n' >>"$TMP_ROOT/render.tap"
fi
if [[ -f "$TMP_ROOT/render.tap" ]]; then
  while IFS= read -r line; do
    case "$line" in
      "ok - "*) pass "${line#ok - }" ;;
      "not ok - "*)
        CASE_STDOUT="$TMP_ROOT/render.tap"
        CASE_STDERR="$TMP_ROOT/render.err"
        fail "${line#not ok - }"
        CASE_STDOUT=""
        CASE_STDERR=""
        ;;
    esac
  done < "$TMP_ROOT/render.tap"
else
  fail "render: permission-scope dial shows grants-authority chip; default does not"
  fail "render: publish link text is host-plus-path; href stays the parsed URL"
  fail "update: txt assigns only when the shown text differs (headless; no browser DOM)"
  fail "update: updateUnit applies a changed review and is quiet when unchanged (headless)"
  fail "update: vitals/dispatch/gate/table apply changed fields only (headless)"
  fail "render: clean green gate shows verdict chip 'green' (is-ok), the fixed caveat, no 'Publication evidence' (headless)"
  fail "render: clean red gate shows verdict chip 'red' (is-danger), the fixed caveat, no 'Publication evidence' (headless)"
  fail "render: clean unknown gate shows verdict chip 'unknown' (is-neutral), the fixed caveat, no 'Publication evidence' (headless)"
  fail "update: updateDial writes changed fields; focused select is skipped until blur (headless)"
  fail "update: stampUpdated writes #updated-at through txt and is quiet on the same second (headless)"
  fail "flow: svgEl creates each allowlisted tag in the SVG namespace and refuses every other tag"
  fail "flow: svgAttr sets each allowlisted attribute and refuses every other name and any url( / javascript: / < value"
  fail "flow: implementer nodes exist only for backends present in counts, in the order claude, codex, cursor, grok, then unknown backend (headless)"
  fail "flow: the first render animates nothing; two new events make exactly two packets with their recorded classes; a repeat makes none (headless)"
  fail "flow: packet variants are recorded outcomes: exit 0, pass, green, and unknown are neutral; nonzero exit, red, and abandoned are danger; iterate is caution; nothing is is-ok (headless)"
  fail "flow: run.*, unit.*, round.begin, checkpoint, journal.repaired, and unknown-backend dispatches make no packet (headless)"
  fail "flow: a run switch clears packets without replaying and keeps a separate high-water mark per run (headless)"
  fail "flow: A → B → A animates exactly the events A gained while B was shown (headless)"
  fail "flow: 21 new events in one update leave at most 20 packet elements, oldest removed first (headless)"
  fail "flow: reduced motion creates no packet while edge labels still update (headless)"
  fail "flow: a dispatch.end whose start fell outside the window routes back from its resolved backend (headless)"
  fail "flow: a conflicted dispatch lands under All and Unattributed and under no unit, for every filter value (headless)"
  fail "flow: each packet-bearing event lands under All and its unit, not under Unattributed; a unit-less gate and a partial dispatch that still names a unit land under Unattributed only (headless)"
  fail "flow: counts_complete false prefixes every edge label with partial and says the record is damaged (headless)"
  fail "flow: a publication routes Judge → Publication with no gate and after a red gate; no Gate → Publication path is drawn (headless)"
  fail "flow: a truncated timeline shows the notice, and edge labels equal the run's counts, not the window (headless)"
  fail "flow: a truncated, damaged run shows one notice that calls counts partial and never claims whole-run totals; each flag alone keeps its own notice (headless)"
  fail "flow: a dispatch with no usable start draws an unknown backend node after grok with its count label, makes no packet, and leaves when the filter excludes it (headless)"
  fail "flow: the hidden list holds the last ten timeline events of every type; unit-less types show under All only (headless)"
  fail "flow: a hostile unit name reaches the DOM only as text (headless)"
  fail "flow: render, filter change, and run switch make no request (headless)"
  fail "flow: a poll updates the SVG in place; nodes, edges, and filter options keep their identity (headless)"
  fail "flow: index output without counts or timeline, or with no runs, shows an empty-state hint (headless)"
  fail "dials: a pick survives focus moving to Apply, and Apply posts the pick (headless)"
  fail "dials: an unchanged poll leaves an unapplied pick alone, focused or not, and Apply still posts it (headless)"
  fail "dials: a stored value that changes while the select has focus is applied when focus leaves (headless)"
  fail "dials: a failed Apply keeps the pick for a retry, a successful one shows the stored value, and Reset drops an unapplied pick (headless)"
fi

# ---------------------------------------------------------------------------
# Fixture store: one run, one open codex dispatch, hostile transcript
# ---------------------------------------------------------------------------
WS="$(workspace console)"
WS_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WS")"
init_git_repo "$WS"
COMMON="$(python3 - "$WS" <<'PY'
import os, subprocess, sys
ws = sys.argv[1]
raw = subprocess.check_output(
    ["git", "-C", ws, "rev-parse", "--git-common-dir"], text=True
).strip()
print(os.path.realpath(raw if os.path.isabs(raw) else os.path.join(ws, raw)))
PY
)"
run_cmd begin "$RUN" begin --workspace "$WS"
expect_status 0 "fixture: loop-run begin"
RUN_ID="$(field_from "$CASE_STDOUT" run)"
run_cmd unit "$RUN" unit-begin --unit u4 --workspace "$WS"
expect_status 0 "fixture: unit-begin"
run_cmd checkpt "$RUN" checkpoint --note fixture-note --workspace "$WS"
expect_status 0 "fixture: checkpoint"

DISPATCH_ID="20260818T010000Z-c0ffee00"
HOSTILE=$'<script>alert(1)</script>\n]\n"\n'
run_cmd start-disp "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$DISPATCH_ID" --field backend=codex --field mode=implement
expect_status 0 "fixture: open codex dispatch"

KEY="$(workspace_key "$WS")"
CAL_REL=".config/olddonkey-loop/calibration/${KEY}.tsv"
CAL_FILE="$HOME/$CAL_REL"
CODEX_DIR="$HOME/.config/olddonkey-loop/codex/$KEY/$DISPATCH_ID"
mkdir -p "$CODEX_DIR"
python3 - "$CODEX_DIR/transcript.log" "$HOSTILE" <<'PY'
import sys
path, hostile = sys.argv[1], sys.argv[2]
marker = b"START-MARKER\n"
end = hostile.encode("utf-8")
body = marker + (b"B" * (65536 - len(end))) + end
with open(path, "wb") as handle:
    handle.write(body)
PY
TRANSCRIPT_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CODEX_DIR/transcript.log")"

HOSTILE_ID="${DISPATCH_ID}/../${DISPATCH_ID}"
run_cmd start-hostile "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$HOSTILE_ID" --field backend=codex --field mode=implement
expect_status 0 "fixture: hostile dispatch_id is in the journal"

UNKNOWN_ID="20260818T010000Z-deadbeef"
run_cmd start-unknown "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$UNKNOWN_ID" --field backend=codex --field mode=implement
expect_status 0 "fixture: unknown dispatch_id is in the journal"

HL_ID="20260818T010000Z-hard01"
run_cmd start-hard "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$HL_ID" --field backend=codex --field mode=implement
expect_status 0 "fixture: hardlink dispatch is in the journal"
mkdir -p "$HOME/.config/olddonkey-loop/codex/$KEY/$HL_ID"
printf 'outside-hardlink\n' >"$TMP_ROOT/outside-hard.txt"
ln "$TMP_ROOT/outside-hard.txt" "$HOME/.config/olddonkey-loop/codex/$KEY/$HL_ID/transcript.log"

SL_ID="20260818T010000Z-syml01"
run_cmd start-sym "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$SL_ID" --field backend=codex --field mode=implement
expect_status 0 "fixture: symlink-leaf dispatch is in the journal"
mkdir -p "$HOME/.config/olddonkey-loop/codex/$KEY/$SL_ID"
printf 'outside-symlink-leaf\n' >"$TMP_ROOT/outside-leaf.txt"
ln -s "$TMP_ROOT/outside-leaf.txt" "$HOME/.config/olddonkey-loop/codex/$KEY/$SL_ID/transcript.log"

GROK_ID="20260818T010000Z-g0ffee00"
run_cmd start-grok "$JOURNAL" append --workspace "$WS" --event dispatch.start \
  --field "dispatch_id=$GROK_ID" --field backend=grok --field mode=implement
expect_status 0 "fixture: grok dispatch is in the journal"
mkdir -p "$TMP_ROOT/outside-grok-root/$GROK_ID"
printf 'stolen-from-outside\n' >"$TMP_ROOT/outside-grok-root/$GROK_ID/transcript.log"
mkdir -p "$COMMON/olddonkey-loop"
ln -s "$TMP_ROOT/outside-grok-root" "$COMMON/olddonkey-loop/grok"

WS_AUX="$(workspace aux)"
run_cmd begin-aux "$RUN" begin --workspace "$WS_AUX"
expect_status 0 "fixture: aux workspace begin"

run_cmd warm-index "$INDEX" --workspace "$WS"
expect_status 0 "fixture: loop-index is readable before the console starts"

# HASH_BEFORE is taken before the console starts so the proof covers
# workspace trees (including .git / separate-git-dir) and HOME.
HASH_BEFORE="$(home_manifest "$TMP_ROOT/home-before.txt")"
WS_HASH_BEFORE="$(workspace_manifest "$WS" "$TMP_ROOT/ws-before.txt")"
GIT_HASH_BEFORE="$(workspace_manifest "$WS.gitadmin" "$TMP_ROOT/git-before.txt")"

# ---------------------------------------------------------------------------
# Start the console
# ---------------------------------------------------------------------------
CASE_STDOUT="$TMP_ROOT/console.stdout"
CASE_STDERR="$TMP_ROOT/console.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
"$CONSOLE" --workspace "$WS" >"$CASE_STDOUT" 2>"$CASE_STDERR" &
CONSOLE_PID=$!
if wait_for_url "$CASE_STDOUT"; then
  pass "startup: printed a loopback URL"
else
  fail "startup: printed a loopback URL"
fi

URL_FIELDS="$(parse_url "$CASE_STDOUT" 2>"$TMP_ROOT/parse.err" || true)"
PORT="${URL_FIELDS%%	*}"
TOKEN="${URL_FIELDS#*	}"
if [[ -n "$PORT" && -n "$TOKEN" && "$PORT" != "$URL_FIELDS" ]]; then
  pass "startup: URL is http://127.0.0.1:<port>/#token"
else
  fail "startup: URL is http://127.0.0.1:<port>/#token"
  PORT=""
  TOKEN=""
fi

CONSOLE_STORE="$HOME/.config/olddonkey-loop/console/$KEY"
if [[ -f "$CONSOLE_STORE/console.lock" ]]; then
  lock_meta "$CONSOLE_STORE/console.lock" "$TMP_ROOT/lock-before.txt"
  pass "startup: console.lock exists for later mode/owner comparison"
else
  fail "startup: console.lock exists for later mode/owner comparison"
fi

# ---------------------------------------------------------------------------
# HTTP checks (python3 http.client). First assertions are a browser-realistic
# navigation profile: a real browser must be able to open the inert shell.
# ---------------------------------------------------------------------------
if [[ -n "$PORT" && -n "$TOKEN" ]]; then
  HTTP_TAP="$TMP_ROOT/http.tap"
  if python3 - "$PORT" "$TOKEN" "$RUN_ID" "$DISPATCH_ID" "$HOSTILE" "$WS_REAL" \
    "$HOSTILE_ID" "$UNKNOWN_ID" "$HL_ID" "$SL_ID" "$GROK_ID" "$TRANSCRIPT_REAL" \
    "$CAL_FILE" \
    >"$HTTP_TAP" 2>"$TMP_ROOT/http.err" <<'PY'
import http.client
import json
import os
import sys
from urllib.parse import quote

port = int(sys.argv[1])
token = sys.argv[2]
run_id = sys.argv[3]
dispatch_id = sys.argv[4]
hostile = sys.argv[5]
workspace = sys.argv[6]
hostile_id = sys.argv[7]
unknown_id = sys.argv[8]
hardlink_id = sys.argv[9]
symlink_id = sys.argv[10]
grok_id = sys.argv[11]
transcript_real = sys.argv[12]
cal_path = sys.argv[13]
host_ok = "127.0.0.1:%d" % port
origin_ok = "http://127.0.0.1:%d" % port
csp = (
    "default-src 'none'; script-src 'self'; style-src 'self'; "
    "connect-src 'self'; frame-ancestors 'none'; form-action 'none'; "
    "base-uri 'none'"
)
cookie = None
csrf = None


def check(name, fn):
    try:
        fn()
        print("ok - %s" % name)
    except Exception as error:
        print("not ok - %s: %s" % (name, error))


def request(method, path, body=None, headers=None):
    hdrs = {}
    if headers:
        hdrs.update(headers)
    payload = None
    if body is not None:
        if isinstance(body, bytes):
            payload = body
        else:
            payload = body.encode("utf-8")
        hdrs.setdefault("Content-Length", str(len(payload)))
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request(method, path, body=payload, headers=hdrs)
        response = conn.getresponse()
        raw = response.read()
        collected = {key.lower(): value for key, value in response.getheaders()}
        return response.status, raw, collected, response.getheaders()
    finally:
        conn.close()


def require_security(headers, where):
    if headers.get("content-security-policy") != csp:
        raise RuntimeError("csp %r at %s" % (headers.get("content-security-policy"), where))
    if headers.get("x-content-type-options") != "nosniff":
        raise RuntimeError("nosniff missing at %s" % where)
    if headers.get("cache-control") != "no-store":
        raise RuntimeError("no-store missing at %s" % where)
    if headers.get("referrer-policy") != "no-referrer":
        raise RuntimeError("no-referrer missing at %s" % where)
    for key in headers:
        if key.startswith("access-control-allow-"):
            raise RuntimeError("CORS header %s at %s" % (key, where))


def no_csrf(body, where):
    text = body.decode("utf-8", "replace")
    if "csrf" in text.lower():
        raise RuntimeError("csrf leaked at %s" % where)


captured = []


def capture(method, path, body=None, headers=None):
    status, raw, headers_map, pairs = request(method, path, body, headers)
    captured.append((method, path, status, headers_map))
    return status, raw, headers_map


def inert_root():
    status, raw, headers = capture("GET", "/", headers={"Host": host_ok})
    if status != 200:
        raise RuntimeError("GET / status %s" % status)
    require_security(headers, "GET /")
    no_csrf(raw, "GET /")
    text = raw.decode("utf-8")
    if run_id in text or dispatch_id in text:
        raise RuntimeError("run data in inert shell")
    if "fixture-note" in text:
        raise RuntimeError("checkpoint note in inert shell")


def asset_headers():
    status, raw, headers = capture("GET", "/console.js", headers={"Host": host_ok})
    if status != 200:
        raise RuntimeError("GET /console.js status %s" % status)
    require_security(headers, "GET /console.js")
    if b"innerHTML" in raw:
        raise RuntimeError("served console.js contains innerHTML")


def served_a11y_hooks():
    status, raw, headers = capture("GET", "/console.js", headers={"Host": host_ok})
    if status != 200:
        raise RuntimeError("GET /console.js status %s" % status)
    require_security(headers, "served console.js")
    if b"aria-pressed" not in raw:
        raise RuntimeError("served console.js missing aria-pressed")
    if b'setAttribute("role", "status")' not in raw:
        raise RuntimeError("served console.js missing role=status")
    if b'el("label")' not in raw:
        raise RuntimeError("served console.js missing label factory")
    if b"element.style" in raw or b".style." in raw:
        raise RuntimeError("served console.js assigns element.style")


def css_ok():
    status, raw, headers = capture("GET", "/console.css", headers={"Host": host_ok})
    if status != 200:
        raise RuntimeError("GET /console.css status %s" % status)
    require_security(headers, "GET /console.css")


def browser_navigation_shell():
    status, raw, headers = capture(
        "GET",
        "/",
        headers={
            "Host": host_ok,
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/126.0.0.0 Safari/537.36"
            ),
        },
    )
    if status != 200:
        raise RuntimeError("browser navigation GET / status %s" % status)
    require_security(headers, "browser navigation GET /")
    if not raw.startswith(b"<!DOCTYPE html>"):
        raise RuntimeError("browser navigation body %r" % raw[:64])
    no_csrf(raw, "browser navigation GET /")


def _inert_fetch_sites(path):
    for site in ("none", "same-origin", "cross-site"):
        status, raw, headers = capture(
            "GET",
            path,
            headers={"Host": host_ok, "Sec-Fetch-Site": site},
        )
        if status != 200:
            raise RuntimeError(
                "GET %s Sec-Fetch-Site=%s status %s" % (path, site, status)
            )
        require_security(headers, "GET %s Sec-Fetch-Site=%s" % (path, site))
        if path == "/":
            no_csrf(raw, "GET %s Sec-Fetch-Site=%s" % (path, site))


def inert_root_fetch_sites():
    _inert_fetch_sites("/")


def inert_css_fetch_sites():
    _inert_fetch_sites("/console.css")


def inert_js_fetch_sites():
    _inert_fetch_sites("/console.js")


def _api_browser_headers(path):
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "GET",
        path,
        headers=auth_headers(extra={"Sec-Fetch-Site": "same-origin"}),
    )
    if status != 200:
        raise RuntimeError(
            "GET %s Sec-Fetch-Site=same-origin status %s body %r"
            % (path, status, raw)
        )
    require_security(headers, "GET %s same-origin" % path)
    for site in ("cross-site", "none"):
        status, raw, headers = capture(
            "GET",
            path,
            headers=auth_headers(extra={"Sec-Fetch-Site": site}),
        )
        if status != 403:
            raise RuntimeError(
                "GET %s Sec-Fetch-Site=%s status %s want 403"
                % (path, site, status)
            )
        require_security(headers, "GET %s Sec-Fetch-Site=%s" % (path, site))
    status, raw, headers = capture(
        "GET",
        path,
        headers=auth_headers(extra={"Origin": "https://evil.example"}),
    )
    if status != 403:
        raise RuntimeError("GET %s evil Origin status %s" % (path, status))
    require_security(headers, "GET %s evil Origin" % path)


def api_state_browser_headers():
    _api_browser_headers("/api/state")


def api_dials_browser_headers():
    _api_browser_headers("/api/dials")


def wrong_token():
    status, raw, headers = capture(
        "POST",
        "/api/session",
        body=json.dumps({"token": "wrong-token-value-not-the-bootstrap"}),
        headers={
            "Host": host_ok,
            "Origin": origin_ok,
            "Content-Type": "application/json",
        },
    )
    if status != 403:
        raise RuntimeError("wrong token status %s" % status)
    no_csrf(raw, "wrong token")
    require_security(headers, "wrong token")
    text = raw.decode("utf-8", "replace")
    if token in text:
        raise RuntimeError("token hinted on wrong-token 403")


def remember_session(raw, headers):
    global cookie, csrf
    payload = json.loads(raw.decode("utf-8"))
    value = payload.get("csrf")
    if not isinstance(value, str) or len(value) < 16:
        raise RuntimeError("session body csrf is not a real token: %r" % value)
    csrf = value
    set_cookie = headers.get("set-cookie") or ""
    if "HttpOnly" not in set_cookie:
        raise RuntimeError("HttpOnly missing: %s" % set_cookie)
    if "SameSite=Strict" not in set_cookie:
        raise RuntimeError("SameSite missing: %s" % set_cookie)
    if "Path=/" not in set_cookie:
        raise RuntimeError("Path missing: %s" % set_cookie)
    if "session=" not in set_cookie:
        raise RuntimeError("session cookie missing")
    cookie = set_cookie.split(";", 1)[0]


def auth_headers(extra=None, *, with_csrf=True, cookie_value=None, csrf_value=None):
    hdrs = {"Host": host_ok}
    if cookie_value is not None:
        hdrs["Cookie"] = cookie_value
    elif cookie:
        hdrs["Cookie"] = cookie
    if with_csrf:
        value = csrf if csrf_value is None else csrf_value
        if value:
            hdrs["X-Console-CSRF"] = value
    if extra:
        hdrs.update(extra)
    return hdrs


def good_session():
    status, raw, headers = capture(
        "POST",
        "/api/session",
        body=json.dumps({"token": token}),
        headers={
            "Host": host_ok,
            "Origin": origin_ok,
            "Content-Type": "application/json",
        },
    )
    if status != 200:
        raise RuntimeError("session status %s body %r" % (status, raw))
    require_security(headers, "session")
    remember_session(raw, headers)


def reuse_token():
    status, raw, headers = capture(
        "POST",
        "/api/session",
        body=json.dumps({"token": token}),
        headers={
            "Host": host_ok,
            "Origin": origin_ok,
            "Content-Type": "application/json",
        },
    )
    if status != 403:
        raise RuntimeError("reuse status %s" % status)
    no_csrf(raw, "reuse")
    require_security(headers, "reuse")


def state_unauth():
    status, raw, headers = capture("GET", "/api/state", headers={"Host": host_ok})
    if status != 401:
        raise RuntimeError("unauth state status %s" % status)
    no_csrf(raw, "unauth state")
    require_security(headers, "unauth state")


def state_auth():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/state",
        headers=auth_headers(),
    )
    if status != 200:
        raise RuntimeError("auth state status %s body %r" % (status, raw))
    require_security(headers, "auth state")
    ctype = headers.get("content-type") or ""
    if "application/json" not in ctype:
        raise RuntimeError("state content-type %s" % ctype)
    payload = json.loads(raw.decode("utf-8"))
    if payload.get("workspace") != workspace:
        raise RuntimeError("workspace %r" % payload.get("workspace"))
    if not payload.get("runs"):
        raise RuntimeError("no runs")
    run = payload["runs"][0]
    if run.get("run_id") != run_id:
        raise RuntimeError("run_id %r" % run.get("run_id"))
    items = run.get("dispatches") or []
    if not items or items[0].get("dispatch_id") != dispatch_id:
        raise RuntimeError("dispatch %r" % items)
    if items[0].get("backend") != "codex" or items[0].get("state") != "open":
        raise RuntimeError("dispatch fields %r" % items[0])


def host_localhost():
    status, raw, headers = capture(
        "GET", "/", headers={"Host": "localhost:%d" % port}
    )
    if status != 400:
        raise RuntimeError("localhost host status %s" % status)
    no_csrf(raw, "localhost host")
    require_security(headers, "localhost host")


def host_other_port():
    status, raw, headers = capture(
        "GET", "/", headers={"Host": "127.0.0.1:%d" % (port + 1)}
    )
    if status != 400:
        raise RuntimeError("other-port host status %s" % status)
    require_security(headers, "other-port host")


def origin_mismatch():
    status, raw, headers = capture(
        "POST",
        "/api/session",
        body=json.dumps({"token": "x"}),
        headers={
            "Host": host_ok,
            "Origin": "http://127.0.0.1:%d" % (port + 1),
            "Content-Type": "application/json",
        },
    )
    if status != 403:
        raise RuntimeError("origin mismatch status %s" % status)
    no_csrf(raw, "origin mismatch")
    require_security(headers, "origin mismatch")


def missing_origin():
    status, raw, headers = capture(
        "POST",
        "/api/session",
        body=json.dumps({"token": "x"}),
        headers={"Host": host_ok, "Content-Type": "application/json"},
    )
    if status != 403:
        raise RuntimeError("missing origin status %s" % status)


def transcript_ok():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(dispatch_id, safe=""),
        headers=auth_headers(),
    )
    if status != 200:
        raise RuntimeError("transcript status %s body %r" % (status, raw))
    require_security(headers, "transcript")
    ctype = headers.get("content-type") or ""
    if "application/json" not in ctype:
        raise RuntimeError("transcript content-type %s" % ctype)
    payload = json.loads(raw.decode("utf-8"))
    if payload.get("dispatch") != dispatch_id:
        raise RuntimeError("transcript dispatch %r" % payload.get("dispatch"))
    if payload.get("path") != transcript_real:
        raise RuntimeError("transcript path %r != %r" % (payload.get("path"), transcript_real))
    tail = payload.get("tail")
    if not isinstance(tail, str):
        raise RuntimeError("tail is not a string")
    encoded = tail.encode("utf-8")
    if len(encoded) != 65536:
        raise RuntimeError("tail length %d, want 65536" % len(encoded))
    if not tail.endswith(hostile):
        raise RuntimeError("tail is not the end of the file")
    if tail.startswith("START-MARKER"):
        raise RuntimeError("tail is the start of the file")
    if hostile not in tail:
        raise RuntimeError("hostile bytes missing from tail: %r" % tail)
    if "<script>alert(1)</script>" not in tail:
        raise RuntimeError("script bytes missing")
    if "]" not in tail or '"' not in tail:
        raise RuntimeError("quote/bracket missing")


def transcript_unauth():
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % dispatch_id,
        headers={"Host": host_ok},
    )
    if status != 401:
        raise RuntimeError("unauth transcript status %s" % status)
    no_csrf(raw, "unauth transcript")


def transcript_traversal():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(hostile_id, safe=""),
        headers=auth_headers(),
    )
    if status != 404:
        raise RuntimeError("hostile journal id status %s body %r" % (status, raw))
    json.loads(raw.decode("utf-8"))
    require_security(headers, "traversal")


def transcript_unknown():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(unknown_id, safe=""),
        headers=auth_headers(),
    )
    if status != 404:
        raise RuntimeError("unknown dispatch status %s" % status)
    json.loads(raw.decode("utf-8"))


def transcript_symlink_root():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(grok_id, safe=""),
        headers=auth_headers(),
    )
    if status != 404:
        raise RuntimeError("symlinked backend root status %s body %r" % (status, raw))
    require_security(headers, "symlink root")


def transcript_hardlink():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(hardlink_id, safe=""),
        headers=auth_headers(),
    )
    if status != 404:
        raise RuntimeError("hardlinked transcript status %s body %r" % (status, raw))
    require_security(headers, "hardlink")


def transcript_symlink_leaf():
    if not cookie or not csrf:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(symlink_id, safe=""),
        headers=auth_headers(),
    )
    if status != 404:
        raise RuntimeError("symlinked transcript leaf status %s body %r" % (status, raw))
    require_security(headers, "symlink leaf")


def csrf_missing_state():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET", "/api/state", headers=auth_headers(with_csrf=False)
    )
    if status != 403:
        raise RuntimeError("state without csrf status %s" % status)
    require_security(headers, "state missing csrf")


def csrf_missing_transcript():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(dispatch_id, safe=""),
        headers=auth_headers(with_csrf=False),
    )
    if status != 403:
        raise RuntimeError("transcript without csrf status %s" % status)
    require_security(headers, "transcript missing csrf")


def csrf_wrong():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/state",
        headers=auth_headers(csrf_value="wrong-csrf-token-value-xxx"),
    )
    if status != 403:
        raise RuntimeError("wrong csrf status %s" % status)
    require_security(headers, "wrong csrf")


def csrf_good_state():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture("GET", "/api/state", headers=auth_headers())
    if status != 200:
        raise RuntimeError("correct csrf state status %s" % status)


def state_bodies_stable():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status1, raw1, headers1 = capture("GET", "/api/state", headers=auth_headers())
    status2, raw2, headers2 = capture("GET", "/api/state", headers=auth_headers())
    if status1 != 200 or status2 != 200:
        raise RuntimeError(
            "consecutive /api/state status %s then %s" % (status1, status2)
        )
    require_security(headers1, "state stability first")
    require_security(headers2, "state stability second")
    if raw1 != raw2:
        raise RuntimeError("consecutive /api/state bodies differ")


def csrf_good_transcript():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "GET",
        "/api/transcript?dispatch=%s" % quote(dispatch_id, safe=""),
        headers=auth_headers(),
    )
    if status != 200:
        raise RuntimeError("correct csrf transcript status %s" % status)


def get_origin_mismatch():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "GET",
        "/api/state",
        headers=auth_headers(extra={"Origin": "http://127.0.0.1:%d" % (port + 1)}),
    )
    if status != 403:
        raise RuntimeError("cross-origin GET status %s" % status)
    require_security(headers, "cross-origin GET")


def get_sec_fetch_site():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "GET",
        "/api/state",
        headers=auth_headers(extra={"Sec-Fetch-Site": "cross-site"}),
    )
    if status != 403:
        raise RuntimeError("Sec-Fetch-Site rejection status %s" % status)
    require_security(headers, "sec-fetch-site")


def forged_session():
    status, raw, headers = capture(
        "GET",
        "/api/state",
        headers=auth_headers(
            cookie_value="session=forged-unknown-session-value",
            csrf_value="also-forged",
        ),
    )
    if status != 401:
        raise RuntimeError("forged session status %s body %r" % (status, raw))
    require_security(headers, "forged session")
    no_csrf(raw, "forged session")


def routes():
    if not cookie:
        raise RuntimeError("no session cookie")
    pairs = (
        ("GET", "/console-assets/index.html", 404),
        ("GET", "/../", 404),
        ("GET", "/api/session", 404),
        ("POST", "/api/state", 404),
        ("GET", "/nope", 404),
    )
    for method, path, expected in pairs:
        headers = {"Host": host_ok}
        body = None
        if method == "POST":
            headers["Origin"] = origin_ok
            headers["Content-Type"] = "application/json"
            body = "{}"
        if path.startswith("/api/") and method == "GET":
            headers["Cookie"] = cookie
            if csrf:
                headers["X-Console-CSRF"] = csrf
        status, raw, hdrs = capture(method, path, body=body, headers=headers)
        if status != expected:
            raise RuntimeError("%s %s status %s want %s" % (method, path, status, expected))
        require_security(hdrs, "%s %s" % (method, path))


def no_cors_anywhere():
    for method, path, status, headers in captured:
        for key in headers:
            if key.startswith("access-control-allow-"):
                raise RuntimeError("CORS on %s %s" % (method, path))


def store_bytes():
    if not os.path.lexists(cal_path):
        return b""
    with open(cal_path, "rb") as handle:
        return handle.read()


def write_rejected_store():
    directory = os.path.dirname(cal_path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    content = (
        b"#schema=0\n"
        b"#workspace=rejected-fixture\n"
        b"#workspace_key=not-the-real-key\n"
        b"stop\tmerge\tpermission\tconsole\t2026-08-18T00:00:00Z\tx\n"
    )
    fd = os.open(cal_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, content)
    finally:
        os.close(fd)
    return content


def dials_unauth():
    status, raw, headers = capture("GET", "/api/dials", headers={"Host": host_ok})
    if status != 401:
        raise RuntimeError("unauth dials status %s" % status)
    no_csrf(raw, "unauth dials")
    require_security(headers, "unauth dials")


def dials_missing_csrf():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET", "/api/dials", headers=auth_headers(with_csrf=False)
    )
    if status != 403:
        raise RuntimeError("dials without csrf status %s" % status)
    require_security(headers, "dials missing csrf")


def dials_wrong_csrf():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "GET",
        "/api/dials",
        headers=auth_headers(csrf_value="wrong-csrf-token-value-xxx"),
    )
    if status != 403:
        raise RuntimeError("dials wrong csrf status %s" % status)
    require_security(headers, "dials wrong csrf")


def dials_ok():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture("GET", "/api/dials", headers=auth_headers())
    if status != 200:
        raise RuntimeError("dials status %s body %r" % (status, raw))
    require_security(headers, "dials ok")
    payload = json.loads(raw.decode("utf-8"))
    if payload.get("schema") != 1:
        raise RuntimeError("dials schema %r" % payload.get("schema"))
    if payload.get("store") != "absent":
        raise RuntimeError("dials store %r" % payload.get("store"))
    if payload.get("workspace") != workspace:
        raise RuntimeError("dials workspace %r" % payload.get("workspace"))
    dials = payload.get("dials") or {}
    if dials.get("backend", {}).get("value") != "codex":
        raise RuntimeError("default backend %r" % dials.get("backend"))
    if dials.get("backend", {}).get("source") != "default":
        raise RuntimeError("default source %r" % dials.get("backend"))


def dials_post_unauth():
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps({"key": "backend", "value": "grok"}),
        headers={
            "Host": host_ok,
            "Origin": origin_ok,
            "Content-Type": "application/json",
        },
    )
    if status != 401:
        raise RuntimeError("unauth post dials status %s" % status)
    no_csrf(raw, "unauth post dials")
    require_security(headers, "unauth post dials")


def dials_post_missing_csrf():
    if not cookie:
        raise RuntimeError("no session cookie")
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps({"key": "backend", "value": "grok"}),
        headers=auth_headers(
            extra={"Origin": origin_ok, "Content-Type": "application/json"},
            with_csrf=False,
        ),
    )
    if status != 403:
        raise RuntimeError("post dials without csrf status %s" % status)
    require_security(headers, "post dials missing csrf")


def dials_post_foreign_origin():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps({"key": "backend", "value": "grok"}),
        headers=auth_headers(
            extra={
                "Origin": "http://127.0.0.1:%d" % (port + 1),
                "Content-Type": "application/json",
            }
        ),
    )
    if status != 403:
        raise RuntimeError("post dials foreign origin status %s" % status)
    require_security(headers, "post dials foreign origin")


def dials_post_ok():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps(
            {"key": "backend", "value": "grok", "provenance": "console-selftest"}
        ),
        headers=auth_headers(
            extra={"Origin": origin_ok, "Content-Type": "application/json"}
        ),
    )
    if status != 200:
        raise RuntimeError("post dials status %s body %r" % (status, raw))
    require_security(headers, "post dials ok")
    payload = json.loads(raw.decode("utf-8"))
    row = (payload.get("dials") or {}).get("backend") or {}
    if row.get("value") != "grok" or row.get("source") != "store":
        raise RuntimeError("post dials body %r" % row)
    if not os.path.isfile(cal_path):
        raise RuntimeError("calibration file was not written")
    text = open(cal_path, encoding="utf-8").read()
    if "backend\tgrok\tpolicy\tconsole\t" not in text:
        raise RuntimeError("store file missing console-written backend row: %r" % text)
    if "\timport-confirmed\t" in text:
        raise RuntimeError("store file has import-confirmed: %r" % text)


def dials_post_invalid():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    before = store_bytes()
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps({"key": "backend", "value": "nope"}),
        headers=auth_headers(
            extra={"Origin": origin_ok, "Content-Type": "application/json"}
        ),
    )
    if status != 400:
        raise RuntimeError("invalid post dials status %s body %r" % (status, raw))
    require_security(headers, "invalid post dials")
    if store_bytes() != before:
        raise RuntimeError("invalid post mutated the store")


def dials_reset():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    status, raw, headers = capture(
        "POST",
        "/api/dials/reset",
        body=json.dumps({"key": "backend"}),
        headers=auth_headers(
            extra={"Origin": origin_ok, "Content-Type": "application/json"}
        ),
    )
    if status != 200:
        raise RuntimeError("reset dials status %s body %r" % (status, raw))
    require_security(headers, "reset dials")
    payload = json.loads(raw.decode("utf-8"))
    row = (payload.get("dials") or {}).get("backend") or {}
    if row.get("value") != "codex" or row.get("source") != "default":
        raise RuntimeError("reset body %r" % row)
    text = open(cal_path, encoding="utf-8").read()
    if "backend\t" in text:
        raise RuntimeError("backend row still in file: %r" % text)


def dials_rejected():
    if not cookie or not csrf:
        raise RuntimeError("no session")
    rejected = write_rejected_store()
    status, raw, headers = capture("GET", "/api/dials", headers=auth_headers())
    if status != 200:
        raise RuntimeError("rejected get status %s body %r" % (status, raw))
    require_security(headers, "rejected get")
    payload = json.loads(raw.decode("utf-8"))
    if payload.get("store") != "rejected":
        raise RuntimeError("rejected store %r" % payload.get("store"))
    if not payload.get("reason"):
        raise RuntimeError("rejected reason missing")
    before = store_bytes()
    if before != rejected:
        raise RuntimeError("rejected fixture was rewritten on GET")
    status, raw, headers = capture(
        "POST",
        "/api/dials",
        body=json.dumps({"key": "gate", "value": "strict"}),
        headers=auth_headers(
            extra={"Origin": origin_ok, "Content-Type": "application/json"}
        ),
    )
    if status != 409:
        raise RuntimeError("rejected post status %s body %r" % (status, raw))
    require_security(headers, "rejected post")
    if store_bytes() != before:
        raise RuntimeError("rejected post mutated the store")
    err = json.loads(raw.decode("utf-8")).get("error") or ""
    if "repair or remove" not in err:
        raise RuntimeError("409 message %r" % err)


check("browser: GET / with a realistic navigation header set is 200 HTML", browser_navigation_shell)
check("browser: GET / accepts Sec-Fetch-Site none, same-origin, and cross-site", inert_root_fetch_sites)
check("browser: GET /console.css accepts Sec-Fetch-Site none, same-origin, and cross-site", inert_css_fetch_sites)
check("browser: GET /console.js accepts Sec-Fetch-Site none, same-origin, and cross-site", inert_js_fetch_sites)
check("inert shell: GET / has no CSRF or run data and exact security headers", inert_root)
check("headers: GET /console.js carries the same security headers", asset_headers)
check("assets: served console.js exposes aria-pressed, role=status, and dial labels", served_a11y_hooks)
check("headers: GET /console.css is served", css_ok)
check("handshake: wrong token is 403", wrong_token)
check("handshake: correct token sets HttpOnly SameSite=Strict session + csrf", good_session)
check("handshake: bootstrap token reuse is 403", reuse_token)
check("auth: /api/state without cookie is 401", state_unauth)
check("auth: forged session cookie is 401", forged_session)
check("csrf: /api/state without header is 403", csrf_missing_state)
check("csrf: /api/transcript without header is 403", csrf_missing_transcript)
check("csrf: wrong header is 403", csrf_wrong)
check("csrf: /api/state with correct header is 200", csrf_good_state)
check("csrf: /api/transcript with correct header is 200", csrf_good_transcript)
check("origin: cross-origin GET is 403", get_origin_mismatch)
check("origin: Sec-Fetch-Site not same-origin is 403", get_sec_fetch_site)
check("browser: GET /api/state same-origin is 200; none, cross-site, evil Origin are 403", api_state_browser_headers)
check("browser: GET /api/dials same-origin is 200; none, cross-site, evil Origin are 403", api_dials_browser_headers)
check("auth: /api/state with cookie matches the fixture", state_auth)
check("two consecutive /api/state bodies are byte-identical on the unchanged fixture (JSON stability; DOM not observed)", state_bodies_stable)
check("host: localhost is 400", host_localhost)
check("host: 127.0.0.1 with the wrong port is 400", host_other_port)
check("origin: mismatched POST Origin is 403", origin_mismatch)
check("origin: missing POST Origin is 403", missing_origin)
check("transcript: unauthenticated is 401", transcript_unauth)
check("transcript: open dispatch tail keeps hostile bytes as JSON string data", transcript_ok)
check("transcript: hostile journal id with .. and separator is 404", transcript_traversal)
check("transcript: journal-known id without state is 404", transcript_unknown)
check("transcript: symlinked backend root is 404", transcript_symlink_root)
check("transcript: hard-linked transcript.log is 404", transcript_hardlink)
check("transcript: symlinked transcript.log leaf is 404", transcript_symlink_leaf)
check("routes: unknown paths return the exact expected status", routes)
check("cors: no Access-Control-Allow-* header on captured responses", no_cors_anywhere)
check("dials: GET /api/dials without session is 401", dials_unauth)
check("dials: GET /api/dials without CSRF is 403", dials_missing_csrf)
check("dials: GET /api/dials with wrong CSRF is 403", dials_wrong_csrf)
check("dials: GET /api/dials with session+CSRF is 200", dials_ok)
check("dials: POST /api/dials unauthenticated is 401", dials_post_unauth)
check("dials: POST /api/dials without CSRF is 403", dials_post_missing_csrf)
check("dials: POST /api/dials with foreign Origin is 403", dials_post_foreign_origin)
check("dials: POST /api/dials writes set_by=console on disk", dials_post_ok)
check("dials: POST /api/dials invalid key/value is 400 and unchanged", dials_post_invalid)
check("dials: POST /api/dials/reset removes the row", dials_reset)
check("dials: rejected store GET is rejected; POST is 409 and unchanged", dials_rejected)
PY
  then
    :
  else
    printf 'not ok - http driver crashed\n' >>"$HTTP_TAP"
  fi
  while IFS= read -r line; do
    case "$line" in
      "ok - "*) pass "${line#ok - }" ;;
      "not ok - "*)
        CASE_STDOUT="$TMP_ROOT/http.tap"
        CASE_STDERR="$TMP_ROOT/http.err"
        fail "${line#not ok - }"
        CASE_STDOUT=""
        CASE_STDERR=""
        ;;
    esac
  done < "$HTTP_TAP"
else
  fail "http: skipped because the console URL could not be parsed"
fi

# ---------------------------------------------------------------------------
# 9. Singleton
# ---------------------------------------------------------------------------
CASE_STDOUT="$TMP_ROOT/second.stdout"
CASE_STDERR="$TMP_ROOT/second.stderr"
if "$CONSOLE" --workspace "$WS" >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
  CASE_STATUS=0
else
  CASE_STATUS=$?
fi
if [[ $CASE_STATUS -ne 0 ]]; then
  pass "singleton: second console exits nonzero"
else
  fail "singleton: second console exits nonzero"
fi
if grep -Fq -- "$WS_REAL" "$CASE_STDERR"; then
  pass "singleton: refusal names the workspace"
else
  fail "singleton: refusal names the workspace"
fi
if grep -Eqi 'already running|console already' "$CASE_STDERR"; then
  pass "singleton: refusal is explicit"
else
  fail "singleton: refusal is explicit"
fi

# ---------------------------------------------------------------------------
# 10. Read-only proof
# ---------------------------------------------------------------------------
CASE_STDOUT=""
CASE_STDERR=""
HASH_AFTER="$(home_manifest "$TMP_ROOT/home-after.txt")"
if [[ "$HASH_BEFORE" == "$HASH_AFTER" ]]; then
  pass "readonly: HOME hash excluding console/ is unchanged"
else
  CASE_STDOUT="$TMP_ROOT/home-diff.txt"
  diff -u "$TMP_ROOT/home-before.txt" "$TMP_ROOT/home-after.txt" >"$CASE_STDOUT" || true
  fail "readonly: HOME hash excluding console/ is unchanged"
  CASE_STDOUT=""
fi

if [[ -f "$CAL_FILE" ]]; then
  if python3 - "$CAL_FILE" <<'PY'
import os, stat, sys
path = sys.argv[1]
info = os.lstat(path)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
    raise SystemExit("not a regular file")
if stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit("mode %04o" % stat.S_IMODE(info.st_mode))
text = open(path, encoding="utf-8").read()
if not text.startswith("#schema=0\n"):
    raise SystemExit("expected rejected fixture, got %r" % text[:80])
if "stop\tmerge\t" not in text:
    raise SystemExit("rejected fixture lost the planted row")
PY
  then
    pass "readonly: only the calibration file changed, and it is the rejected fixture"
  else
    fail "readonly: only the calibration file changed, and it is the rejected fixture"
  fi
  cal_dir="$(dirname "$CAL_FILE")"
  extras="$(find "$cal_dir" -mindepth 1 ! -name "$(basename "$CAL_FILE")" | wc -l | tr -d ' ')"
  if [[ "$extras" == "0" ]]; then
    pass "readonly: calibration dir contains only the helper store file"
  else
    fail "readonly: calibration dir contains only the helper store file"
  fi
else
  fail "readonly: only the calibration file changed, and it is the rejected fixture"
  fail "readonly: calibration dir contains only the helper store file"
fi

WS_HASH_AFTER="$(workspace_manifest "$WS" "$TMP_ROOT/ws-after.txt")"
if [[ "$WS_HASH_BEFORE" == "$WS_HASH_AFTER" ]]; then
  pass "readonly: workspace tree hash is unchanged"
else
  CASE_STDOUT="$TMP_ROOT/ws-diff.txt"
  diff -u "$TMP_ROOT/ws-before.txt" "$TMP_ROOT/ws-after.txt" >"$CASE_STDOUT" || true
  fail "readonly: workspace tree hash is unchanged"
  CASE_STDOUT=""
fi

GIT_HASH_AFTER="$(workspace_manifest "$WS.gitadmin" "$TMP_ROOT/git-after.txt")"
if [[ "$GIT_HASH_BEFORE" == "$GIT_HASH_AFTER" ]]; then
  pass "readonly: git common dir hash is unchanged"
else
  CASE_STDOUT="$TMP_ROOT/git-diff.txt"
  diff -u "$TMP_ROOT/git-before.txt" "$TMP_ROOT/git-after.txt" >"$CASE_STDOUT" || true
  fail "readonly: git common dir hash is unchanged"
  CASE_STDOUT=""
fi

CONSOLE_STORE="$HOME/.config/olddonkey-loop/console/$KEY"
if [[ -d "$CONSOLE_STORE" ]]; then
  extras="$(find "$CONSOLE_STORE" -mindepth 1 ! -name console.lock | wc -l | tr -d ' ')"
  if [[ -f "$CONSOLE_STORE/console.lock" && "$extras" == "0" ]]; then
    pass "readonly: console dir contains only console.lock"
  else
    fail "readonly: console dir contains only console.lock"
  fi
else
  fail "readonly: console dir contains only console.lock"
fi

if [[ -f "$CONSOLE_STORE/console.lock" && -f "$TMP_ROOT/lock-before.txt" ]]; then
  lock_meta "$CONSOLE_STORE/console.lock" "$TMP_ROOT/lock-after.txt"
  if cmp -s "$TMP_ROOT/lock-before.txt" "$TMP_ROOT/lock-after.txt"; then
    pass "readonly: console.lock mode and ownership are unchanged"
  else
    CASE_STDOUT="$TMP_ROOT/lock-after.txt"
    CASE_STDERR="$TMP_ROOT/lock-before.txt"
    fail "readonly: console.lock mode and ownership are unchanged"
    CASE_STDOUT=""
    CASE_STDERR=""
  fi
else
  fail "readonly: console.lock mode and ownership are unchanged"
fi

# ---------------------------------------------------------------------------
# 13. Clean shutdown, then lock released
# ---------------------------------------------------------------------------
if [[ -n "$CONSOLE_PID" ]]; then
  kill -TERM "$CONSOLE_PID" 2>/dev/null || true
  wait "$CONSOLE_PID"
  TERM_STATUS=$?
  CONSOLE_PID=""
  if [[ $TERM_STATUS -eq 0 ]]; then
    pass "shutdown: SIGTERM exits 0"
  else
    fail "shutdown: SIGTERM exits 0 (got $TERM_STATUS)"
  fi
else
  fail "shutdown: SIGTERM exits 0"
fi

CASE_STDOUT="$TMP_ROOT/third.stdout"
CASE_STDERR="$TMP_ROOT/third.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
"$CONSOLE" --workspace "$WS" >"$CASE_STDOUT" 2>"$CASE_STDERR" &
CONSOLE_PID=$!
if wait_for_url "$CASE_STDOUT"; then
  pass "singleton: a new console starts after the lock is released"
else
  fail "singleton: a new console starts after the lock is released"
fi

# ---------------------------------------------------------------------------
# F3 concurrent bootstrap (dedicated console so the main session stays intact)
# ---------------------------------------------------------------------------
WS_RACE="$(workspace race)"
CASE_STDOUT="$TMP_ROOT/race.stdout"
CASE_STDERR="$TMP_ROOT/race.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
"$CONSOLE" --workspace "$WS_RACE" >"$CASE_STDOUT" 2>"$CASE_STDERR" &
RACE_PID=$!
EXTRA_PIDS="$EXTRA_PIDS $RACE_PID"
if wait_for_url "$CASE_STDOUT" "$RACE_PID"; then
  pass "race: printed a loopback URL"
else
  fail "race: printed a loopback URL"
fi
if python3 - "$CASE_STDOUT" <<'PY'
import http.client
import json
import re
import sys
import threading
import time

text = open(sys.argv[1], encoding="utf-8").read().splitlines()
hits = [line for line in text if line.startswith("http://127.0.0.1:")]
match = re.fullmatch(r"http://127\.0\.0\.1:(\d+)/#([A-Za-z0-9_-]+)", hits[0])
if match is None:
    raise SystemExit("could not parse race URL")
port = int(match.group(1))
token = match.group(2)
host = "127.0.0.1:%d" % port
origin = "http://127.0.0.1:%d" % port
n = 12
body = json.dumps({"token": token}).encode("utf-8")
headers = {
    "Host": host,
    "Origin": origin,
    "Content-Type": "application/json",
    "Content-Length": str(len(body)),
}
results = []
barrier = threading.Barrier(n)
lock = threading.Lock()


def worker():
    last_error = None
    try:
        barrier.wait(timeout=5)
        for _ in range(30):
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("POST", "/api/session", body=body, headers=headers)
                response = conn.getresponse()
                raw = response.read()
                status = response.status
                conn.close()
                with lock:
                    results.append(status)
                return
            except Exception as error:
                last_error = error
                time.sleep(0.02)
        with lock:
            results.append("err:%s" % last_error)
    except Exception as error:
        with lock:
            results.append("err:%s" % error)


threads = [threading.Thread(target=worker) for _ in range(n)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join(timeout=15)
oks = [item for item in results if item == 200]
bads = [item for item in results if item == 403]
if len(results) != n or len(oks) != 1 or len(bads) != n - 1:
    raise SystemExit("expected exactly one 200 and the rest 403, got %r" % results)
PY
then
  pass "handshake: concurrent identical bootstrap tokens yield exactly one 200"
else
  CASE_STDOUT="$TMP_ROOT/race.stdout"
  CASE_STDERR="$TMP_ROOT/race.stderr"
  fail "handshake: concurrent identical bootstrap tokens yield exactly one 200"
  CASE_STDOUT=""
  CASE_STDERR=""
fi
if [[ -n "$RACE_PID" ]]; then
  kill -TERM "$RACE_PID" 2>/dev/null || true
  wait "$RACE_PID" 2>/dev/null || true
  RACE_PID=""
fi

# ---------------------------------------------------------------------------
# F5 token expiry, F7 LOOP_INDEX gate, F2 index timeout
# ---------------------------------------------------------------------------
STUB="$TMP_ROOT/slow-index"
printf '%s\n' '#!/usr/bin/env bash' 'exec sleep 30' >"$STUB"
chmod +x "$STUB"

stop_extra() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

WS_TTL="$(workspace ttl)"
CASE_STDOUT="$TMP_ROOT/ttl.stdout"
CASE_STDERR="$TMP_ROOT/ttl.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
LOOP_CONSOLE_TOKEN_TTL_SEC=1 "$CONSOLE" --workspace "$WS_TTL" \
  >"$CASE_STDOUT" 2>"$CASE_STDERR" &
TTL_PID=$!
EXTRA_PIDS="$EXTRA_PIDS $TTL_PID"
if wait_for_url "$CASE_STDOUT" "$TTL_PID"; then
  pass "ttl: printed a loopback URL"
else
  fail "ttl: printed a loopback URL"
fi
TTL_FIELDS="$(parse_url "$CASE_STDOUT" 2>"$TMP_ROOT/ttl-parse.err" || true)"
TTL_PORT="${TTL_FIELDS%%	*}"
TTL_TOKEN="${TTL_FIELDS#*	}"
sleep 1.6
if [[ -n "$TTL_PORT" && -n "$TTL_TOKEN" && "$TTL_PORT" != "$TTL_FIELDS" ]]; then
  if python3 - "$TTL_PORT" "$TTL_TOKEN" <<'PY'
import http.client, json, sys
port = int(sys.argv[1])
token = sys.argv[2]
host = "127.0.0.1:%d" % port
origin = "http://127.0.0.1:%d" % port
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
body = json.dumps({"token": token}).encode("utf-8")
conn.request(
    "POST",
    "/api/session",
    body=body,
    headers={
        "Host": host,
        "Origin": origin,
        "Content-Type": "application/json",
        "Content-Length": str(len(body)),
    },
)
response = conn.getresponse()
raw = response.read()
status = response.status
conn.close()
if status != 403:
    raise SystemExit("expired token status %s body %r" % (status, raw))
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
conn.request("GET", "/", headers={"Host": host})
page = conn.getresponse()
page.read()
if page.status != 200:
    raise SystemExit("GET / after expiry status %s" % page.status)
conn.close()
PY
  then
    pass "ttl: expired bootstrap token is 403 and GET / still serves"
  else
    CASE_STDOUT="$TMP_ROOT/ttl.stdout"
    CASE_STDERR="$TMP_ROOT/ttl.stderr"
    fail "ttl: expired bootstrap token is 403 and GET / still serves"
    CASE_STDOUT=""
    CASE_STDERR=""
  fi
else
  fail "ttl: expired bootstrap token is 403 and GET / still serves"
fi
if grep -Fq "bootstrap token expired" "$TMP_ROOT/ttl.stderr"; then
  pass "ttl: expiry is logged on stderr"
else
  CASE_STDERR="$TMP_ROOT/ttl.stderr"
  fail "ttl: expiry is logged on stderr"
  CASE_STDERR=""
fi
stop_extra "$TTL_PID"
TTL_PID=""

LAST_EXTRA_PID=""
aux_console() { # $1=stem  remaining=env for the console process
  local stem="$1"
  shift
  local stdout="$TMP_ROOT/${stem}.stdout"
  local stderr="$TMP_ROOT/${stem}.stderr"
  : >"$stdout"
  : >"$stderr"
  LAST_EXTRA_PID=""
  env "$@" "$CONSOLE" --workspace "$WS_AUX" >"$stdout" 2>"$stderr" &
  LAST_EXTRA_PID=$!
  EXTRA_PIDS="$EXTRA_PIDS $LAST_EXTRA_PID"
  if ! wait_for_url "$stdout" "$LAST_EXTRA_PID"; then
    stop_extra "$LAST_EXTRA_PID"
    LAST_EXTRA_PID=""
    return 1
  fi
}

aux_state_status() { # $1=stdout-file $2=client-timeout -> prints status
  python3 - "$1" "$2" <<'PY'
import http.client, json, re, sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
hits = [line for line in text if line.startswith("http://127.0.0.1:")]
match = re.fullmatch(r"http://127\.0\.0\.1:(\d+)/#([A-Za-z0-9_-]+)", hits[0])
port = int(match.group(1))
token = match.group(2)
timeout = float(sys.argv[2])
host = "127.0.0.1:%d" % port
origin = "http://127.0.0.1:%d" % port
body = json.dumps({"token": token}).encode("utf-8")
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
conn.request(
    "POST",
    "/api/session",
    body=body,
    headers={
        "Host": host,
        "Origin": origin,
        "Content-Type": "application/json",
        "Content-Length": str(len(body)),
    },
)
response = conn.getresponse()
payload = json.loads(response.read().decode("utf-8"))
csrf = payload["csrf"]
cookie = response.getheader("Set-Cookie").split(";", 1)[0]
conn.close()
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
conn.request(
    "GET",
    "/api/state",
    headers={"Host": host, "Cookie": cookie, "X-Console-CSRF": csrf},
)
print(conn.getresponse().status)
conn.close()
PY
}

CASE_STDOUT="$TMP_ROOT/f7.stdout"
CASE_STDERR="$TMP_ROOT/f7.stderr"
F7_PID=""
if aux_console f7 LOOP_INDEX="$STUB"; then
  F7_PID="$LAST_EXTRA_PID"
  pass "index-override: console starts without LOOP_CONSOLE_TEST"
  F7_STATUS="$(aux_state_status "$TMP_ROOT/f7.stdout" 5 2>"$TMP_ROOT/f7-http.err" || true)"
  if [[ "$F7_STATUS" == "200" ]]; then
    pass "index-override: LOOP_INDEX is ignored without LOOP_CONSOLE_TEST=1"
  else
    CASE_STDERR="$TMP_ROOT/f7-http.err"
    fail "index-override: LOOP_INDEX is ignored without LOOP_CONSOLE_TEST=1 (status ${F7_STATUS:-err})"
    CASE_STDERR=""
  fi
  stop_extra "$F7_PID"
else
  fail "index-override: console starts without LOOP_CONSOLE_TEST"
  fail "index-override: LOOP_INDEX is ignored without LOOP_CONSOLE_TEST=1"
fi

CASE_STDOUT="$TMP_ROOT/f2.stdout"
CASE_STDERR="$TMP_ROOT/f2.stderr"
F2_PID=""
if aux_console f2 LOOP_CONSOLE_TEST=1 LOOP_INDEX="$STUB"; then
  F2_PID="$LAST_EXTRA_PID"
  pass "index-timeout: console starts with LOOP_CONSOLE_TEST=1 LOOP_INDEX"
  F2_STATUS="$(aux_state_status "$TMP_ROOT/f2.stdout" 8 2>"$TMP_ROOT/f2-http.err" || true)"
  if [[ "$F2_STATUS" == "504" ]]; then
    pass "index-timeout: loop-index timeout returns 504"
  else
    CASE_STDERR="$TMP_ROOT/f2-http.err"
    fail "index-timeout: loop-index timeout returns 504 (status ${F2_STATUS:-err})"
    CASE_STDERR=""
  fi
  if python3 - "$TMP_ROOT/f2.stdout" <<'PY'
import http.client, re, sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
hits = [line for line in text if line.startswith("http://127.0.0.1:")]
match = re.fullmatch(r"http://127\.0\.0\.1:(\d+)/#([A-Za-z0-9_-]+)", hits[0])
port = int(match.group(1))
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
conn.request("GET", "/", headers={"Host": "127.0.0.1:%d" % port})
status = conn.getresponse().status
conn.close()
if status != 200:
    raise SystemExit("GET / after 504 status %s" % status)
PY
  then
    pass "index-timeout: GET / still serves after 504"
  else
    fail "index-timeout: GET / still serves after 504"
  fi
  stop_extra "$F2_PID"
else
  fail "index-timeout: console starts with LOOP_CONSOLE_TEST=1 LOOP_INDEX"
  fail "index-timeout: loop-index timeout returns 504"
  fail "index-timeout: GET / still serves after 504"
fi

# ---------------------------------------------------------------------------
# Transcript source is chosen per backend, not "newest file"
# ---------------------------------------------------------------------------
WS_SRC="$(workspace srcsel)"
init_git_repo "$WS_SRC"
SRC_COMMON="$(python3 - "$WS_SRC" <<'PY'
import os, subprocess, sys
ws = sys.argv[1]
raw = subprocess.check_output(
    ["git", "-C", ws, "rev-parse", "--git-common-dir"], text=True
).strip()
print(os.path.realpath(raw if os.path.isabs(raw) else os.path.join(ws, raw)))
PY
)"
run_cmd begin-src "$RUN" begin --workspace "$WS_SRC"
expect_status 0 "srcsel: loop-run begin"
SRC_KEY="$(workspace_key "$WS_SRC")"
SRC_CLAUDE="20260818T120000Z-srclaud"
SRC_CODEX="20260818T120000Z-srcodex"
SRC_CURSOR="20260818T120000Z-srcursor"
SRC_GROK="20260818T120000Z-srgrok"
run_cmd src-claude "$JOURNAL" append --workspace "$WS_SRC" --event dispatch.start \
  --field "dispatch_id=$SRC_CLAUDE" --field backend=claude --field mode=implement
expect_status 0 "srcsel: claude dispatch is in the journal"
run_cmd src-codex "$JOURNAL" append --workspace "$WS_SRC" --event dispatch.start \
  --field "dispatch_id=$SRC_CODEX" --field backend=codex --field mode=implement
expect_status 0 "srcsel: codex dispatch is in the journal"
run_cmd src-cursor "$JOURNAL" append --workspace "$WS_SRC" --event dispatch.start \
  --field "dispatch_id=$SRC_CURSOR" --field backend=cursor --field mode=implement
expect_status 0 "srcsel: cursor dispatch is in the journal"
run_cmd src-grok "$JOURNAL" append --workspace "$WS_SRC" --event dispatch.start \
  --field "dispatch_id=$SRC_GROK" --field backend=grok --field mode=implement
expect_status 0 "srcsel: grok dispatch is in the journal"

SRC_CLAUDE_DIR="$SRC_COMMON/olddonkey-loop/claude/$SRC_CLAUDE"
SRC_CODEX_DIR="$HOME/.config/olddonkey-loop/codex/$SRC_KEY/$SRC_CODEX"
SRC_CURSOR_DIR="$SRC_COMMON/olddonkey-loop/cursor/$SRC_CURSOR"
SRC_GROK_DIR="$SRC_COMMON/olddonkey-loop/grok/$SRC_GROK"
mkdir -p "$SRC_CLAUDE_DIR" "$SRC_CODEX_DIR" "$SRC_CURSOR_DIR" "$SRC_GROK_DIR"
if python3 - "$SRC_CLAUDE_DIR" "$SRC_CODEX_DIR" "$SRC_CURSOR_DIR" "$SRC_GROK_DIR" <<'PY'
import os, sys

base = 1700000000


def plant(directory, rows):
    os.makedirs(directory, exist_ok=True)
    for name, offset, text in rows:
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.utime(path, (base + offset, base + offset))


plant(
    sys.argv[1],
    (
        ("stream.jsonl", 0, "claude-preferred\n"),
        ("stderr.log", 100, "claude-fallback\n"),
        ("prompt.txt", 200, "claude-decoy-prompt\n"),
    ),
)
plant(
    sys.argv[2],
    (
        ("transcript.log", 0, "codex-preferred\n"),
        ("prompt.txt", 200, "codex-decoy-prompt\n"),
        ("last-message.txt", 300, "codex-newest-decoy\n"),
        ("meta.tsv", 100, "codex-decoy-meta\n"),
    ),
)
plant(
    sys.argv[3],
    (
        ("stderr.log", 0, "cursor-preferred\n"),
        ("output.json", 100, "cursor-fallback\n"),
        ("prompt.txt", 200, "cursor-decoy-prompt\n"),
        ("project-files.zlist", 300, "cursor-newest-decoy\n"),
    ),
)
plant(
    sys.argv[4],
    (
        ("transition.jsonl", 0, "grok-preferred\n"),
        ("output.json", 100, "grok-fallback\n"),
        ("state.json", 200, "grok-decoy-state\n"),
        ("session.json", 300, "grok-newest-decoy\n"),
    ),
)
PY
then
  pass "srcsel: planted decoy-newest files around each preferred source"
else
  fail "srcsel: planted decoy-newest files around each preferred source"
fi

CASE_STDOUT="$TMP_ROOT/srcsel.stdout"
CASE_STDERR="$TMP_ROOT/srcsel.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
"$CONSOLE" --workspace "$WS_SRC" >"$CASE_STDOUT" 2>"$CASE_STDERR" &
SRC_PID=$!
EXTRA_PIDS="$EXTRA_PIDS $SRC_PID"
if wait_for_url "$CASE_STDOUT" "$SRC_PID"; then
  pass "srcsel: printed a loopback URL"
else
  fail "srcsel: printed a loopback URL"
fi
SRC_FIELDS="$(parse_url "$CASE_STDOUT" 2>"$TMP_ROOT/srcsel-parse.err" || true)"
SRC_PORT="${SRC_FIELDS%%	*}"
SRC_TOKEN="${SRC_FIELDS#*	}"
if [[ -n "$SRC_PORT" && -n "$SRC_TOKEN" && "$SRC_PORT" != "$SRC_FIELDS" ]]; then
  SRC_TAP="$TMP_ROOT/srcsel.tap"
  if python3 - "$SRC_PORT" "$SRC_TOKEN" \
    "$SRC_CLAUDE" "$SRC_CODEX" "$SRC_CURSOR" "$SRC_GROK" \
    "$SRC_CLAUDE_DIR" "$SRC_CODEX_DIR" "$SRC_CURSOR_DIR" "$SRC_GROK_DIR" \
    >"$SRC_TAP" 2>"$TMP_ROOT/srcsel-http.err" <<'PY'
import http.client
import json
import os
import sys
from urllib.parse import quote

port = int(sys.argv[1])
token = sys.argv[2]
claude_id, codex_id, cursor_id, grok_id = sys.argv[3:7]
claude_dir, codex_dir, cursor_dir, grok_dir = sys.argv[7:11]
host = "127.0.0.1:%d" % port
origin = "http://127.0.0.1:%d" % port


def check(name, fn):
    try:
        fn()
        print("ok - %s" % name)
    except Exception as error:
        print("not ok - %s: %s" % (name, error))


def request(method, path, body=None, headers=None):
    hdrs = {}
    if headers:
        hdrs.update(headers)
    payload = None
    if body is not None:
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        hdrs.setdefault("Content-Length", str(len(payload)))
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request(method, path, body=payload, headers=hdrs)
        response = conn.getresponse()
        return response.status, response.read(), {
            key.lower(): value for key, value in response.getheaders()
        }
    finally:
        conn.close()


status, raw, headers = request(
    "POST",
    "/api/session",
    body=json.dumps({"token": token}),
    headers={
        "Host": host,
        "Origin": origin,
        "Content-Type": "application/json",
    },
)
if status != 200:
    raise SystemExit("srcsel session status %s body %r" % (status, raw))
csrf = json.loads(raw.decode("utf-8"))["csrf"]
cookie = headers.get("set-cookie", "").split(";", 1)[0]


def transcript(dispatch_id):
    status, raw, _headers = request(
        "GET",
        "/api/transcript?dispatch=%s" % quote(dispatch_id, safe=""),
        headers={"Host": host, "Cookie": cookie, "X-Console-CSRF": csrf},
    )
    payload = None
    if raw:
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            payload = raw
    return status, payload


def expect_path(dispatch_id, directory, name):
    status, payload = transcript(dispatch_id)
    if status != 200:
        raise RuntimeError("status %s payload %r" % (status, payload))
    wanted = os.path.realpath(os.path.join(directory, name))
    got = payload.get("path")
    if got != wanted:
        raise RuntimeError("path %r want %r" % (got, wanted))
    if os.path.basename(got) != name:
        raise RuntimeError("basename %r" % os.path.basename(got))


def expect_404(dispatch_id):
    status, payload = transcript(dispatch_id)
    if status != 404:
        raise RuntimeError("status %s payload %r" % (status, payload))


check(
    "transcript source: claude prefers stream.jsonl over a newer decoy",
    lambda: expect_path(claude_id, claude_dir, "stream.jsonl"),
)
check(
    "transcript source: codex prefers transcript.log over a newer decoy",
    lambda: expect_path(codex_id, codex_dir, "transcript.log"),
)
check(
    "transcript source: cursor prefers stderr.log over a newer decoy",
    lambda: expect_path(cursor_id, cursor_dir, "stderr.log"),
)
check(
    "transcript source: grok prefers transition.jsonl over a newer decoy",
    lambda: expect_path(grok_id, grok_dir, "transition.jsonl"),
)

os.remove(os.path.join(claude_dir, "stream.jsonl"))
os.remove(os.path.join(cursor_dir, "stderr.log"))
os.remove(os.path.join(grok_dir, "transition.jsonl"))

check(
    "transcript source: claude falls back to stderr.log when stream.jsonl is gone",
    lambda: expect_path(claude_id, claude_dir, "stderr.log"),
)
check(
    "transcript source: cursor falls back to output.json when stderr.log is gone",
    lambda: expect_path(cursor_id, cursor_dir, "output.json"),
)
check(
    "transcript source: grok falls back to output.json when transition.jsonl is gone",
    lambda: expect_path(grok_id, grok_dir, "output.json"),
)

os.remove(os.path.join(claude_dir, "stderr.log"))
os.remove(os.path.join(codex_dir, "transcript.log"))
os.remove(os.path.join(cursor_dir, "output.json"))
os.remove(os.path.join(grok_dir, "output.json"))

check(
    "transcript source: 404 when no claude candidate remains (decoys ignored)",
    lambda: expect_404(claude_id),
)
check(
    "transcript source: 404 when no codex candidate remains (decoys ignored)",
    lambda: expect_404(codex_id),
)
check(
    "transcript source: 404 when no cursor candidate remains (decoys ignored)",
    lambda: expect_404(cursor_id),
)
check(
    "transcript source: 404 when no grok candidate remains (decoys ignored)",
    lambda: expect_404(grok_id),
)
PY
  then
    :
  else
    printf 'not ok - srcsel driver crashed\n' >>"$SRC_TAP"
  fi
  if [[ -f "$SRC_TAP" ]]; then
    while IFS= read -r line; do
      case "$line" in
        "ok - "*) pass "${line#ok - }" ;;
        "not ok - "*)
          CASE_STDOUT="$TMP_ROOT/srcsel.tap"
          CASE_STDERR="$TMP_ROOT/srcsel-http.err"
          fail "${line#not ok - }"
          CASE_STDOUT=""
          CASE_STDERR=""
          ;;
      esac
    done < "$SRC_TAP"
  else
    fail "transcript source: claude prefers stream.jsonl over a newer decoy"
    fail "transcript source: codex prefers transcript.log over a newer decoy"
    fail "transcript source: cursor prefers stderr.log over a newer decoy"
    fail "transcript source: grok prefers transition.jsonl over a newer decoy"
    fail "transcript source: claude falls back to stderr.log when stream.jsonl is gone"
    fail "transcript source: cursor falls back to output.json when stderr.log is gone"
    fail "transcript source: grok falls back to output.json when transition.jsonl is gone"
    fail "transcript source: 404 when no claude candidate remains (decoys ignored)"
    fail "transcript source: 404 when no codex candidate remains (decoys ignored)"
    fail "transcript source: 404 when no cursor candidate remains (decoys ignored)"
    fail "transcript source: 404 when no grok candidate remains (decoys ignored)"
  fi
else
  fail "srcsel: URL is http://127.0.0.1:<port>/#token"
  fail "transcript source: claude prefers stream.jsonl over a newer decoy"
  fail "transcript source: codex prefers transcript.log over a newer decoy"
  fail "transcript source: cursor prefers stderr.log over a newer decoy"
  fail "transcript source: grok prefers transition.jsonl over a newer decoy"
  fail "transcript source: claude falls back to stderr.log when stream.jsonl is gone"
  fail "transcript source: cursor falls back to output.json when stderr.log is gone"
  fail "transcript source: grok falls back to output.json when transition.jsonl is gone"
  fail "transcript source: 404 when no claude candidate remains (decoys ignored)"
  fail "transcript source: 404 when no codex candidate remains (decoys ignored)"
  fail "transcript source: 404 when no cursor candidate remains (decoys ignored)"
  fail "transcript source: 404 when no grok candidate remains (decoys ignored)"
fi
stop_extra "$SRC_PID"
SRC_PID=""

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
