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

tree_manifest() { # $1=root $2=output-file [$3=skip-rel]
  python3 - "$1" "$2" "${3:-}" <<'PY'
import hashlib, os, sys
root, dest, skip = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    rel = os.path.relpath(dirpath, root)
    if skip and (rel == skip or rel.startswith(skip + os.sep)):
        dirnames[:] = []
        continue
    dirnames.sort()
    filenames.sort()
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel_file = os.path.relpath(path, root)
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
  tree_manifest "$HOME" "$1" "$(printf '%s' ".config/olddonkey-loop/console")"
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
)
missing = [name for name in forbidden if name in js]
if missing:
    raise SystemExit("js tokens: " + ",".join(missing))
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

if python3 - "$ASSETS/console.js" <<'PY'
import re, sys
js = open(sys.argv[1], encoding="utf-8").read()
if js.count("X-Console-CSRF") < 1:
    raise SystemExit("missing X-Console-CSRF")
if "apiHeaders" not in js:
    raise SystemExit("missing apiHeaders helper")
if not re.search(r"txt\(\s*link\s*,\s*href\s*\)", js):
    raise SystemExit("link text is not the parsed href")
PY
then
  pass "assets: console.js sends X-Console-CSRF and displays parsed href"
else
  fail "assets: console.js sends X-Console-CSRF and displays parsed href"
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
# HTTP checks 1-8, 12 (python3 http.client)
# ---------------------------------------------------------------------------
if [[ -n "$PORT" && -n "$TOKEN" ]]; then
  HTTP_TAP="$TMP_ROOT/http.tap"
  if python3 - "$PORT" "$TOKEN" "$RUN_ID" "$DISPATCH_ID" "$HOSTILE" "$WS_REAL" \
    "$HOSTILE_ID" "$UNKNOWN_ID" "$HL_ID" "$SL_ID" "$GROK_ID" "$TRANSCRIPT_REAL" \
    >"$HTTP_TAP" 2>"$TMP_ROOT/http.err" <<'PY'
import http.client
import json
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


def css_ok():
    status, raw, headers = capture("GET", "/console.css", headers={"Host": host_ok})
    if status != 200:
        raise RuntimeError("GET /console.css status %s" % status)
    require_security(headers, "GET /console.css")


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


check("inert shell: GET / has no CSRF or run data and exact security headers", inert_root)
check("headers: GET /console.js carries the same security headers", asset_headers)
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
check("auth: /api/state with cookie matches the fixture", state_auth)
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

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
