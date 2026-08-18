#!/usr/bin/env bash
# Hermetic regression checks for loop-index and references/state-schema.md.
# HOME is a scratch directory so the real ~/.config tree is never touched.
# Fixture state is synthetic; adapters are never launched.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
INDEX="$SCRIPT_DIR/../scripts/loop-index"
JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
RUN="$SCRIPT_DIR/../scripts/loop-run"
SCHEMA="$SCRIPT_DIR/../references/state-schema.md"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/index-selftest.XXXXXX")" || exit 1
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.config/olddonkey-loop" || exit 1
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop" || exit 1
export LC_ALL=C

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

INVENTORY_PY='
INVENTORY = {
    "codex": {
        "early failure": ["meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"],
        "parse failure": ["meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"],
        "read-only": ["meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"],
        "implement": ["meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"],
        "successful terminal": ["meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"],
    },
    "grok": {
        "early failure": ["state.json", "transition.jsonl", "baseline.json"],
        "parse failure": ["state.json", "transition.jsonl", "baseline.json", "output.json", "pgid"],
        "read-only": ["state.json", "transition.jsonl", "output.json", "pgid", "session.json"],
        "implement": [
            "state.json", "transition.jsonl", "baseline.json", "output.json", "pgid",
            "snapshot-baseline.json", "authoritative-baseline.json", "authoritative-path",
        ],
        "successful terminal": [
            "state.json", "transition.jsonl", "baseline.json", "output.json", "pgid",
            "snapshot-baseline.json", "authoritative-baseline.json", "authoritative-path",
            "session.json",
        ],
    },
    "cursor": {
        "early failure": ["project-files.zlist", "prompt.txt"],
        "parse failure": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "changes.raw.patch", "changes.patch",
        ],
        "read-only": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt",
        ],
        "implement": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt", "changes.raw.patch", "changes.patch",
        ],
        "successful terminal": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt", "changes.raw.patch", "changes.patch",
            "apply-check.log", "apply.log",
        ],
    },
}
CLASSES = (
    "early failure",
    "parse failure",
    "read-only",
    "implement",
    "successful terminal",
)
BACKENDS = ("codex", "grok", "cursor")
'

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

init_git_repo() { # $1=dir
  mkdir -p "$1"
  rm -rf "$1.gitadmin"
  git init -q --template= --separate-git-dir="$1.gitadmin" "$1"
}

store_dir() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key))
PY
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

field_from() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" | head -n 1
}

inventory_list() { # $1=backend $2=class
  python3 - "$1" "$2" <<PY
import sys
$INVENTORY_PY
backend, klass = sys.argv[1], sys.argv[2]
print("\\n".join(INVENTORY[backend][klass]))
PY
}

build_fixture() { # $1=backend $2=class $3=dest
  local backend="$1" klass="$2" dest="$3" name
  mkdir -p "$dest"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf 'fixture\n' > "$dest/$name"
  done < <(inventory_list "$backend" "$klass")
}

codex_root() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "codex", key))
PY
}

# ---------------------------------------------------------------------------
# 1. Fixture inventories × doc artifact tables
# ---------------------------------------------------------------------------
WS_FIX="$(workspace fixtures)"
init_git_repo "$WS_FIX"
CODEX_FIX="$(codex_root "$WS_FIX")"
COMMON_FIX="$(python3 - "$WS_FIX" <<'PY'
import os, subprocess, sys
ws = sys.argv[1]
raw = subprocess.check_output(["git", "-C", ws, "rev-parse", "--git-common-dir"], text=True).strip()
print(os.path.realpath(raw if os.path.isabs(raw) else os.path.join(ws, raw)))
PY
)"
mkdir -p "$CODEX_FIX" "$COMMON_FIX/olddonkey-loop/grok" "$COMMON_FIX/olddonkey-loop/cursor"
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop"

python3 - "$TMP_ROOT/expected-inventory.json" <<PY
import json, sys
$INVENTORY_PY
json.dump(INVENTORY, open(sys.argv[1], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY

python3 - "$SCHEMA" "$TMP_ROOT/doc-inventory.json" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
backends = ("codex", "grok", "cursor")
classes = (
    "early failure",
    "parse failure",
    "read-only",
    "implement",
    "successful terminal",
)
parsed = {backend: {klass: [] for klass in classes} for backend in backends}
current = None
for raw_line in text.splitlines():
    heading = re.match(r"^### (Codex|Grok|Cursor)\s*$", raw_line)
    if heading:
        current = heading.group(1).lower()
        continue
    if current is None or not raw_line.startswith("|"):
        continue
    cells = [cell.strip() for cell in raw_line.strip().strip("|").split("|")]
    if len(cells) < 8:
        continue
    if cells[0] == "artifact":
        continue
    if set(cells) <= {"---", ""} or all(cell.replace("-", "") == "" for cell in cells):
        continue
    artifact = cells[0].strip("`")
    mapping = {
        "early failure": cells[2],
        "parse failure": cells[3],
        "read-only": cells[4],
        "implement": cells[5],
        "successful terminal": cells[6],
    }
    for klass, cell in mapping.items():
        if cell not in {"present", "absent"}:
            raise SystemExit(
                "unparseable lifecycle cell %r %r %r: %r"
                % (current, artifact, klass, cell)
            )
        if cell == "present":
            parsed[current][klass].append(artifact)
json.dump(parsed, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY

if python3 - "$TMP_ROOT/doc-inventory.json" "$TMP_ROOT/expected-inventory.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
expected = json.load(open(sys.argv[2], encoding="utf-8"))
for backend, classes in expected.items():
    for klass, names in classes.items():
        got = doc.get(backend, {}).get(klass, [])
        if got != names:
            print(f"{backend}/{klass}: doc={got} fixture={names}", file=sys.stderr)
            raise SystemExit(1)
PY
then
  pass "fixtures: state-schema.md artifact tables match fixture inventories"
else
  fail "fixtures: state-schema.md artifact tables match fixture inventories"
fi

python3 - "$CODEX_FIX" "$COMMON_FIX" <<PY
import os, sys
$INVENTORY_PY
codex_root, common = sys.argv[1], sys.argv[2]
roots = {
    "codex": codex_root,
    "grok": os.path.join(common, "olddonkey-loop", "grok"),
    "cursor": os.path.join(common, "olddonkey-loop", "cursor"),
}
for backend in BACKENDS:
    for klass in CLASSES:
        digest = __import__("hashlib").sha256(f"{backend}:{klass}".encode("utf-8")).hexdigest()
        suffix = digest[:8] if backend == "codex" else digest[:6]
        dispatch_id = f"20260817T010000Z-{suffix}"
        dest = os.path.join(roots[backend], dispatch_id)
        os.makedirs(dest, exist_ok=True)
        for name in INVENTORY[backend][klass]:
            with open(os.path.join(dest, name), "w", encoding="utf-8") as handle:
                handle.write("fixture\\n")
PY

if python3 - "$CODEX_FIX" "$COMMON_FIX" <<PY
import os, sys
$INVENTORY_PY
codex_root, common = sys.argv[1], sys.argv[2]
roots = {
    "codex": codex_root,
    "grok": os.path.join(common, "olddonkey-loop", "grok"),
    "cursor": os.path.join(common, "olddonkey-loop", "cursor"),
}
for backend in BACKENDS:
    for klass in CLASSES:
        digest = __import__("hashlib").sha256(f"{backend}:{klass}".encode("utf-8")).hexdigest()
        suffix = digest[:8] if backend == "codex" else digest[:6]
        dest = os.path.join(roots[backend], f"20260817T010000Z-{suffix}")
        found = sorted(name for name in os.listdir(dest) if not name.startswith("."))
        expected = sorted(INVENTORY[backend][klass])
        if found != expected:
            print(f"{backend}/{klass}: disk={found} expected={expected}", file=sys.stderr)
            raise SystemExit(1)
PY
then
  pass "fixtures: five lifecycle classes × three backends built on disk"
else
  fail "fixtures: five lifecycle classes × three backends built on disk"
fi

run_cmd fix-index "$INDEX" --workspace "$WS_FIX"
expect_status 0 "fixtures: loop-index exits 0 over synthetic state"
if python3 - "$CASE_STDOUT" "$CODEX_FIX" "$COMMON_FIX" <<PY
import hashlib, json, os, sys
$INVENTORY_PY
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if doc["journal"]["status"] != "missing":
    raise SystemExit("journal should be missing")
if doc["runs"] != []:
    raise SystemExit("runs should be empty")
for backend in BACKENDS:
    ids = []
    for klass in CLASSES:
        digest = hashlib.sha256(f"{backend}:{klass}".encode("utf-8")).hexdigest()
        suffix = digest[:8] if backend == "codex" else digest[:6]
        ids.append(f"20260817T010000Z-{suffix}")
    got = doc["unattributed_state"][backend]
    if sorted(got) != sorted(ids):
        print(backend, got, ids, file=sys.stderr)
        raise SystemExit(1)
PY
then
  pass "fixtures: fifteen unattributed state dirs indexed by exact basename"
else
  fail "fixtures: fifteen unattributed state dirs indexed by exact basename"
fi

# ---------------------------------------------------------------------------
# 2. Full pipeline (real journal writers + synthetic state)
# ---------------------------------------------------------------------------
WS_PIPE="$(workspace pipeline)"
init_git_repo "$WS_PIPE"
CODEX_PIPE="$(codex_root "$WS_PIPE")"
COMMON_PIPE="$(python3 - "$WS_PIPE" <<'PY'
import os, subprocess, sys
ws = sys.argv[1]
raw = subprocess.check_output(["git", "-C", ws, "rev-parse", "--git-common-dir"], text=True).strip()
print(os.path.realpath(raw if os.path.isabs(raw) else os.path.join(ws, raw)))
PY
)"

run_cmd pipe-begin-old "$RUN" begin --workspace "$WS_PIPE" --plan older
expect_status 0 "pipeline: first begin succeeds"
GEN_OLD="$(field_from "$CASE_STDOUT" generation)"
RUN_OLD="$(field_from "$CASE_STDOUT" run)"
run_cmd pipe-end-old "$RUN" end --status completed --workspace "$WS_PIPE"
expect_status 0 "pipeline: first run ends completed"

run_cmd pipe-begin "$RUN" begin --workspace "$WS_PIPE" --plan unit3
expect_status 0 "pipeline: second begin succeeds"
GEN_NEW="$(field_from "$CASE_STDOUT" generation)"
RUN_NEW="$(field_from "$CASE_STDOUT" run)"
run_cmd pipe-unit "$RUN" unit-begin --unit unit-3 --workspace "$WS_PIPE"
expect_status 0 "pipeline: unit-begin"
run_cmd pipe-round "$RUN" round-begin --unit unit-3 --round 1 --workspace "$WS_PIPE"
expect_status 0 "pipeline: round-begin"

PIPE_CODEX="20260817T120000Z-c0de0001"
PIPE_GROK="20260817T120000Z-aa11bb"
PIPE_CURSOR="20260817T120000Z-cc22dd"
run_cmd pipe-ds-c "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.start \
  --field "dispatch_id=$PIPE_CODEX" --field backend=codex --field mode=implement
expect_status 0 "pipeline: dispatch.start codex"
run_cmd pipe-ds-g "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.start \
  --field "dispatch_id=$PIPE_GROK" --field backend=grok --field mode=implement
expect_status 0 "pipeline: dispatch.start grok"
run_cmd pipe-ds-u "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.start \
  --field "dispatch_id=$PIPE_CURSOR" --field backend=cursor --field mode=read-only
expect_status 0 "pipeline: dispatch.start cursor"

mkdir -p "$CODEX_PIPE/$PIPE_CODEX" \
  "$COMMON_PIPE/olddonkey-loop/grok/$PIPE_GROK" \
  "$COMMON_PIPE/olddonkey-loop/cursor/$PIPE_CURSOR"
build_fixture "codex" "successful terminal" "$CODEX_PIPE/$PIPE_CODEX"
build_fixture "grok" "successful terminal" "$COMMON_PIPE/olddonkey-loop/grok/$PIPE_GROK"
build_fixture "cursor" "read-only" "$COMMON_PIPE/olddonkey-loop/cursor/$PIPE_CURSOR"

run_cmd pipe-de-c "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.end \
  --field "dispatch_id=$PIPE_CODEX" --field exit=0 --field session=sess-codex
expect_status 0 "pipeline: dispatch.end codex"
run_cmd pipe-de-g "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.end \
  --field "dispatch_id=$PIPE_GROK" --field exit=0 --field session=sess-grok
expect_status 0 "pipeline: dispatch.end grok"
run_cmd pipe-de-u "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.end \
  --field "dispatch_id=$PIPE_CURSOR" --field exit=0 --field session=sess-cursor
expect_status 0 "pipeline: dispatch.end cursor"
run_cmd pipe-gate "$JOURNAL" append --workspace "$WS_PIPE" --event gate.result \
  --field policy=strict --field purpose=unit-final --field binding=clean \
  --field totals=exit=0 --field pre_head=abc123 --field post_head=def456
expect_status 0 "pipeline: gate.result"
run_cmd pipe-review "$RUN" review --unit unit-3 --round 1 --verdict pass --workspace "$WS_PIPE"
expect_status 0 "pipeline: review"
run_cmd pipe-pub "$RUN" publish --unit unit-3 --branch topic \
  --pr https://example.invalid/p/1 --sha abc --workspace "$WS_PIPE"
expect_status 0 "pipeline: publish"
run_cmd pipe-end "$RUN" end --status completed --workspace "$WS_PIPE"
expect_status 0 "pipeline: second run ends completed"
run_cmd pipe-unattr "$JOURNAL" append --workspace "$WS_PIPE" --event checkpoint --field note=loose
expect_status 0 "pipeline: post-end append is unattributed"

run_cmd pipe-index "$INDEX" --workspace "$WS_PIPE"
expect_status 0 "pipeline: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$RUN_NEW" "$RUN_OLD" "$GEN_NEW" "$GEN_OLD" \
  "$PIPE_CODEX" "$PIPE_GROK" "$PIPE_CURSOR" "$CODEX_PIPE" "$COMMON_PIPE" <<'PY'
import json, os, sys
(
    path, run_new, run_old, gen_new, gen_old, d_codex, d_grok, d_cursor,
    codex_root, common,
) = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
if doc["schema"] != 1:
    raise SystemExit("schema")
if doc["journal"]["status"] != "ok":
    raise SystemExit("journal")
if doc["context"]["state"] != "none":
    raise SystemExit("context should be none after end")
if len(doc["runs"]) != 2:
    raise SystemExit("two runs")
if doc["runs"][0]["generation"] != int(gen_new):
    raise SystemExit(f"newest first: {doc['runs'][0]['generation']} != {gen_new}")
if doc["runs"][1]["generation"] != int(gen_old):
    raise SystemExit("older second")
if doc["runs"][0]["run_id"] != run_new or doc["runs"][1]["run_id"] != run_old:
    raise SystemExit("run ids")
if doc["runs"][0]["status"] != "completed" or doc["runs"][1]["status"] != "completed":
    raise SystemExit("completed")
unit = doc["runs"][0]["units"][0]
if unit["unit"] != "unit-3" or unit["review"] != {"verdict": "pass", "round": 1}:
    raise SystemExit(f"review {unit}")
if unit["rounds"] != 1 or unit["publish"].get("branch") != "topic":
    raise SystemExit(f"publish {unit}")
if unit["publish"].get("pr") != "https://example.invalid/p/1":
    raise SystemExit("pr")
dispatches = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
for dispatch_id, backend, session in (
    (d_codex, "codex", "sess-codex"),
    (d_grok, "grok", "sess-grok"),
    (d_cursor, "cursor", "sess-cursor"),
):
    item = dispatches[dispatch_id]
    if item["state"] != "ended" or item["exit"] != 0 or item["session"] != session:
        raise SystemExit(f"dispatch {item}")
    if item["backend"] != backend:
        raise SystemExit("backend")
    if "liveness" in item:
        raise SystemExit("closed dispatch must omit liveness")
    if item["state_dir"] == "missing":
        raise SystemExit("state_dir missing")
    if not os.path.isdir(item["state_dir"]):
        raise SystemExit("state_dir path")
gate = doc["runs"][0]["gates"][0]
if gate["policy"] != "strict" or gate["purpose"] != "unit-final" or gate["binding"] != "clean":
    raise SystemExit(f"gate {gate}")
if gate.get("pre_head") != "abc123" or gate.get("post_head") != "def456":
    raise SystemExit("heads")
if doc["unattributed_events"] < 1:
    raise SystemExit("unattributed_events")
PY
then
  pass "pipeline: JSON has run status, review, dispatch, gate, newest-first"
else
  fail "pipeline: JSON has run status, review, dispatch, gate, newest-first"
fi

# ---------------------------------------------------------------------------
# 3. Open dispatch + liveness
# ---------------------------------------------------------------------------
WS_LIVE="$(workspace liveness)"
run_cmd live-begin "$RUN" begin --workspace "$WS_LIVE"
expect_status 0 "liveness: begin succeeds"
CODEX_LIVE="$(codex_root "$WS_LIVE")"
LIVE_RECENT="20260817T130000Z-aa000001"
LIVE_IDLE="20260817T130000Z-aa000002"
LIVE_STALL="20260817T130000Z-aa000003"
LIVE_MISS="20260817T130000Z-aa000004"
LIVE_CLOSED="20260817T130000Z-aa000005"
LIVE_TRANSCRIPT="20260817T130000Z-aa000006"
for DID in "$LIVE_RECENT" "$LIVE_IDLE" "$LIVE_STALL" "$LIVE_MISS" "$LIVE_CLOSED" "$LIVE_TRANSCRIPT"; do
  run_cmd "live-start-$DID" "$JOURNAL" append --workspace "$WS_LIVE" --event dispatch.start \
    --field "dispatch_id=$DID" --field backend=codex --field mode=implement
  expect_status 0 "liveness: start $DID"
done
run_cmd live-end-closed "$JOURNAL" append --workspace "$WS_LIVE" --event dispatch.end \
  --field "dispatch_id=$LIVE_CLOSED" --field exit=0
expect_status 0 "liveness: close one dispatch"

mkdir -p "$CODEX_LIVE/$LIVE_RECENT" "$CODEX_LIVE/$LIVE_IDLE" \
  "$CODEX_LIVE/$LIVE_STALL" "$CODEX_LIVE/$LIVE_CLOSED" "$CODEX_LIVE/$LIVE_TRANSCRIPT"
for DID in "$LIVE_RECENT" "$LIVE_IDLE" "$LIVE_STALL" "$LIVE_CLOSED" "$LIVE_TRANSCRIPT"; do
  build_fixture "codex" "implement" "$CODEX_LIVE/$DID"
done

python3 - "$CODEX_LIVE" "$LIVE_RECENT" "$LIVE_IDLE" "$LIVE_STALL" "$LIVE_TRANSCRIPT" <<'PY'
import os, sys, time
root, recent, idle, stall, trans = sys.argv[1:]
now = time.time()

def touch_t(path, when):
    import shlex
    stamp = time.strftime("%Y%m%d%H%M.%S", time.localtime(when))
    os.system("touch -t %s %s" % (stamp, shlex.quote(path)))
    os.utime(path, (when, when))

for name in ("meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"):
    touch_t(os.path.join(root, recent, name), now)
    touch_t(os.path.join(root, idle, name), now - 600)
    touch_t(os.path.join(root, stall, name), now - 1500)
touch_t(os.path.join(root, trans, "transcript.log"), now - 1500)
touch_t(os.path.join(root, trans, "meta.tsv"), now)
PY

run_cmd live-index "$INDEX" --workspace "$WS_LIVE"
expect_status 0 "liveness: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$LIVE_RECENT" "$LIVE_IDLE" "$LIVE_STALL" \
  "$LIVE_MISS" "$LIVE_CLOSED" "$LIVE_TRANSCRIPT" <<'PY'
import json, sys
path, recent, idle, stall, missing, closed, trans = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
items = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
if items[recent]["state"] != "open":
    raise SystemExit("recent open")
if items[recent]["liveness"]["state"] != "recent activity":
    raise SystemExit(items[recent]["liveness"])
if items[idle]["liveness"]["state"] != "idle":
    raise SystemExit(items[idle]["liveness"])
if items[idle]["liveness"].get("idle_minutes") != 10:
    raise SystemExit(f"idle_minutes {items[idle]['liveness']}")
if items[stall]["liveness"]["state"] != "suspected stall":
    raise SystemExit(items[stall]["liveness"])
if items[missing]["state_dir"] != "missing":
    raise SystemExit("missing state_dir")
if items[missing]["liveness"]["state"] != "unknown":
    raise SystemExit("missing liveness")
if "liveness" in items[closed]:
    raise SystemExit("closed liveness")
if items[trans]["liveness"]["state"] != "suspected stall":
    raise SystemExit("codex must follow transcript.log, not meta.tsv")
if not items[recent]["liveness"].get("source", "").endswith("transcript.log"):
    raise SystemExit("source")
PY
then
  pass "liveness: recent / idle 10 / stall / unknown / no key when closed"
else
  fail "liveness: recent / idle 10 / stall / unknown / no key when closed"
fi

run_cmd live-override env LOOP_INDEX_ACTIVITY_SEC=10 LOOP_INDEX_STALL_SEC=20 \
  "$INDEX" --workspace "$WS_LIVE"
expect_status 0 "liveness: overridden thresholds exit 0"
if python3 - "$CASE_STDOUT" "$LIVE_IDLE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
idle = sys.argv[2]
items = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
if items[idle]["liveness"]["state"] != "suspected stall":
    raise SystemExit(items[idle]["liveness"])
PY
then
  pass "liveness: LOOP_INDEX_STALL_SEC override marks idle dispatch as stall"
else
  fail "liveness: LOOP_INDEX_STALL_SEC override marks idle dispatch as stall"
fi

# ---------------------------------------------------------------------------
# 4. Correlation (exact id only; timestamps must not match)
# ---------------------------------------------------------------------------
WS_CORR="$(workspace corr)"
run_cmd corr-begin "$RUN" begin --workspace "$WS_CORR"
expect_status 0 "correlation: begin succeeds"
CODEX_CORR="$(codex_root "$WS_CORR")"
CORR_MATCH="20260817T140000Z-ab000001"
CORR_JOURNAL="20260817T140000Z-bb000002"
CORR_ORPHAN="20260817T140000Z-cc000003"
CORR_TRAP_JOURNAL="20260817T140000Z-dd000004"
CORR_TRAP_STATE="20260817T140000Z-ee000005"
run_cmd corr-s1 "$JOURNAL" append --workspace "$WS_CORR" --event dispatch.start \
  --field "dispatch_id=$CORR_MATCH" --field backend=codex --field mode=implement
run_cmd corr-s2 "$JOURNAL" append --workspace "$WS_CORR" --event dispatch.start \
  --field "dispatch_id=$CORR_JOURNAL" --field backend=codex --field mode=implement
run_cmd corr-s3 "$JOURNAL" append --workspace "$WS_CORR" --event dispatch.start \
  --field "dispatch_id=$CORR_TRAP_JOURNAL" --field backend=codex --field mode=implement
mkdir -p "$CODEX_CORR/$CORR_MATCH" "$CODEX_CORR/$CORR_ORPHAN" "$CODEX_CORR/$CORR_TRAP_STATE"
build_fixture "codex" "implement" "$CODEX_CORR/$CORR_MATCH"
build_fixture "codex" "implement" "$CODEX_CORR/$CORR_ORPHAN"
build_fixture "codex" "implement" "$CODEX_CORR/$CORR_TRAP_STATE"
# Same mtime on the trap pair so a timestamp heuristic would wrongly join them.
python3 - "$CODEX_CORR/$CORR_TRAP_STATE/transcript.log" "$CODEX_CORR/$CORR_MATCH/transcript.log" <<'PY'
import os, sys, time
when = time.time()
for path in sys.argv[1:]:
    os.utime(path, (when, when))
PY

run_cmd corr-index "$INDEX" --workspace "$WS_CORR"
expect_status 0 "correlation: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$CORR_MATCH" "$CORR_JOURNAL" "$CORR_ORPHAN" \
  "$CORR_TRAP_JOURNAL" "$CORR_TRAP_STATE" "$CODEX_CORR" <<'PY'
import json, os, sys
path, match, journal_only, orphan, trap_j, trap_s, root = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
items = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
if items[match]["state_dir"] != os.path.join(root, match):
    raise SystemExit("matched path")
if items[journal_only]["state_dir"] != "missing":
    raise SystemExit("journal-only must be missing")
if items[trap_j]["state_dir"] != "missing":
    raise SystemExit("timestamp-aligned different id must not match")
unattr = doc["unattributed_state"]["codex"]
if orphan not in unattr or trap_s not in unattr:
    raise SystemExit(f"unattributed {unattr}")
if match in unattr or journal_only in unattr or trap_j in unattr:
    raise SystemExit("matched ids leaked into unattributed")
PY
then
  pass "correlation: exact id only; timestamp alignment does not join"
else
  fail "correlation: exact id only; timestamp alignment does not join"
fi

# ---------------------------------------------------------------------------
# 5. Degraded journal
# ---------------------------------------------------------------------------
WS_DEG="$(workspace degraded)"
run_cmd deg-begin "$RUN" begin --workspace "$WS_DEG"
expect_status 0 "degraded: begin succeeds"
RUN_DEG="$(field_from "$CASE_STDOUT" run)"
STORE_DEG="$(store_dir "$WS_DEG")"
run_cmd deg-unit "$RUN" unit-begin --unit u-deg --workspace "$WS_DEG"
run_cmd deg-ds "$JOURNAL" append --workspace "$WS_DEG" --event dispatch.start \
  --field dispatch_id=20260817T150000Z-ff000001 --field backend=codex --field mode=implement
SEG_DEG="$STORE_DEG/runs/${RUN_DEG}.jsonl"
python3 - "$SEG_DEG" <<'PY'
import sys
path = sys.argv[1]
with open(path, "ab") as handle:
    handle.write(b"this is not json\n")
    handle.write(b'{"schema":1,"seq":99,"event":"review.recorded"}\n')
PY
run_cmd deg-index "$INDEX" --workspace "$WS_DEG"
expect_status 0 "degraded: loop-index still exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if doc["journal"]["status"] != "degraded":
    raise SystemExit("journal status")
run = doc["runs"][0]
if run["status"] != "degraded":
    raise SystemExit("run status")
if run["units"][0]["status"] != "unknown":
    raise SystemExit("unit axis")
if run["units"][0]["review"] != "not recorded":
    raise SystemExit("review after corrupt line must not be fabricated")
if run["dispatches"][0]["state"] != "unknown":
    raise SystemExit("dispatch axis")
if run["checkpoint"] != {"state": "unknown"}:
    raise SystemExit("checkpoint axis")
PY
then
  pass "degraded: journal/run degraded, unproven axes unknown, exit 0"
else
  fail "degraded: journal/run degraded, unproven axes unknown, exit 0"
fi

# ---------------------------------------------------------------------------
# 6. Empty store
# ---------------------------------------------------------------------------
WS_EMPTY="$(workspace empty)"
run_cmd empty-index "$INDEX" --workspace "$WS_EMPTY"
expect_status 0 "empty: loop-index exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if doc["runs"] != []:
    raise SystemExit("runs")
if doc["journal"]["status"] != "missing":
    raise SystemExit("journal")
if doc["unattributed_events"] != 0:
    raise SystemExit("unattributed_events")
if doc["context"]["state"] != "none":
    raise SystemExit("context")
PY
then
  pass "empty: runs=[], journal missing, exit 0"
else
  fail "empty: runs=[], journal missing, exit 0"
fi

# ---------------------------------------------------------------------------
# 7. Read-only proof
# ---------------------------------------------------------------------------
WS_RO="$(workspace readonly)"
run_cmd ro-begin "$RUN" begin --workspace "$WS_RO"
expect_status 0 "readonly: begin succeeds"
STORE_RO="$(store_dir "$WS_RO")"
run_cmd ro-check "$RUN" checkpoint --note stay --workspace "$WS_RO"
SNAP_BEFORE="$TMP_ROOT/store-before.txt"
SNAP_AFTER="$TMP_ROOT/store-after.txt"
python3 - "$STORE_RO" "$SNAP_BEFORE" <<'PY'
import hashlib, os, sys
root, out = sys.argv[1], sys.argv[2]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        info = os.lstat(path)
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        rows.append(f"{os.path.relpath(path, root)}\t{info.st_mtime_ns}\t{info.st_size}\t{digest}")
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
LOCK_BEFORE="$(python3 -c 'import os,sys; print(os.lstat(sys.argv[1]).st_mtime_ns)' "$STORE_RO/meta.lock")"
TSV_BEFORE="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$STORE_RO/runs.tsv")"
run_cmd ro-index "$INDEX" --workspace "$WS_RO"
expect_status 0 "readonly: loop-index exits 0"
python3 - "$STORE_RO" "$SNAP_AFTER" <<'PY'
import hashlib, os, sys
root, out = sys.argv[1], sys.argv[2]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        info = os.lstat(path)
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        rows.append(f"{os.path.relpath(path, root)}\t{info.st_mtime_ns}\t{info.st_size}\t{digest}")
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
LOCK_AFTER="$(python3 -c 'import os,sys; print(os.lstat(sys.argv[1]).st_mtime_ns)' "$STORE_RO/meta.lock")"
TSV_AFTER="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$STORE_RO/runs.tsv")"
if cmp -s "$SNAP_BEFORE" "$SNAP_AFTER"; then
  pass "readonly: store bytes+mtimes unchanged after loop-index"
else
  fail "readonly: store bytes+mtimes unchanged after loop-index"
fi
if [[ "$LOCK_BEFORE" == "$LOCK_AFTER" ]]; then
  pass "readonly: meta.lock mtime did not advance"
else
  fail "readonly: meta.lock mtime did not advance"
fi
if [[ "$TSV_BEFORE" == "$TSV_AFTER" ]]; then
  pass "readonly: runs.tsv was not rewritten"
else
  fail "readonly: runs.tsv was not rewritten"
fi

# ---------------------------------------------------------------------------
# 8. review "not recorded"
# ---------------------------------------------------------------------------
WS_REV="$(workspace noreview)"
run_cmd rev-begin "$RUN" begin --workspace "$WS_REV"
run_cmd rev-unit "$RUN" unit-begin --unit u-plain --workspace "$WS_REV"
run_cmd rev-index "$INDEX" --workspace "$WS_REV"
expect_status 0 "review: loop-index exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
unit = doc["runs"][0]["units"][0]
if unit["review"] != "not recorded":
    raise SystemExit(unit)
if unit["publish"] != "not recorded":
    raise SystemExit(unit)
if doc["context"]["state"] != "active":
    raise SystemExit("context")
PY
then
  pass "review: absent review.recorded renders not recorded"
else
  fail "review: absent review.recorded renders not recorded"
fi

# ---------------------------------------------------------------------------
# 9. Git-unavailable workspace
# ---------------------------------------------------------------------------
WS_NOGIT="$(workspace nogit)"
run_cmd ng-begin "$RUN" begin --workspace "$WS_NOGIT"
expect_status 0 "gitless: begin succeeds"
NG_CODEX="20260817T160000Z-c0de0009"
NG_GROK="20260817T160000Z-aa9900"
NG_CURSOR="20260817T160000Z-cc9900"
run_cmd ng-c "$JOURNAL" append --workspace "$WS_NOGIT" --event dispatch.start \
  --field "dispatch_id=$NG_CODEX" --field backend=codex --field mode=implement
run_cmd ng-g "$JOURNAL" append --workspace "$WS_NOGIT" --event dispatch.start \
  --field "dispatch_id=$NG_GROK" --field backend=grok --field mode=read-only
run_cmd ng-u "$JOURNAL" append --workspace "$WS_NOGIT" --event dispatch.start \
  --field "dispatch_id=$NG_CURSOR" --field backend=cursor --field mode=read-only
CODEX_NG="$(codex_root "$WS_NOGIT")"
mkdir -p "$CODEX_NG/$NG_CODEX"
build_fixture "codex" "implement" "$CODEX_NG/$NG_CODEX"
run_cmd ng-index "$INDEX" --workspace "$WS_NOGIT"
expect_status 0 "gitless: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$NG_CODEX" "$NG_GROK" "$NG_CURSOR" "$CODEX_NG" <<'PY'
import json, os, sys
path, d_codex, d_grok, d_cursor, root = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
items = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
if items[d_codex]["state_dir"] != os.path.join(root, d_codex):
    raise SystemExit("codex should still index")
if items[d_grok]["state_dir"] != "unavailable":
    raise SystemExit(items[d_grok])
if items[d_cursor]["state_dir"] != "unavailable":
    raise SystemExit(items[d_cursor])
if doc["unattributed_state"]["grok"] != "unavailable":
    raise SystemExit(doc["unattributed_state"])
if doc["unattributed_state"]["cursor"] != "unavailable":
    raise SystemExit(doc["unattributed_state"])
if not isinstance(doc["unattributed_state"]["codex"], list):
    raise SystemExit("codex unattributed")
PY
then
  pass "gitless: grok/cursor unavailable, codex still indexed, exit 0"
else
  fail "gitless: grok/cursor unavailable, codex still indexed, exit 0"
fi

# ---------------------------------------------------------------------------
# 10. Checkpoint axis
# ---------------------------------------------------------------------------
WS_CP="$(workspace checkpoint)"
CP_FRESH="20260817T180001Z-c0ff01"
CP_STALE="20260817T180002Z-c0ff02"
CP_NONE="20260817T180003Z-c0ff03"
CP_NOTE="20260817T180004Z-c0ff04"
CP_MECH="20260817T180005Z-c0ff05"
CP_META="$TMP_ROOT/checkpoint-meta.json"
python3 - "$WS_CP" "$HOME" "$CP_META" "$CP_FRESH" "$CP_STALE" "$CP_NONE" \
  "$CP_NOTE" "$CP_MECH" <<'PY'
import hashlib, json, os, sys
from datetime import datetime, timedelta, timezone

ws, home, meta_path, fresh_id, stale_id, none_id, note_id, mech_id = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
now = datetime.now(timezone.utc).replace(microsecond=0)

def iso(delta):
    return (now + delta).strftime("%Y-%m-%dT%H:%M:%SZ")

fresh_ts = iso(timedelta(seconds=-20))
stale_ts = iso(timedelta(hours=-2))
note_ts = iso(timedelta(seconds=-120))
review_ts = iso(timedelta(seconds=-15))
mech_ts = iso(timedelta(seconds=-5))
bad_agent_ts = iso(timedelta(hours=-3))

def write(run_id, events):
    path = os.path.join(runs_dir, run_id + ".jsonl")
    with open(path, "w", encoding="utf-8") as handle:
        for index, event in enumerate(events, 1):
            row = {"schema": 1, "seq": index, "run": run_id}
            row.update(event)
            handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")

write(fresh_id, [
    {"ts": fresh_ts, "event": "run.begin", "generation": 1, "workspace": ws, "workspace_key": key},
    {"ts": fresh_ts, "event": "unit.begin", "unit": "u-fresh"},
])
write(stale_id, [
    {"ts": stale_ts, "event": "run.begin", "generation": 2, "workspace": ws, "workspace_key": key},
    {"ts": stale_ts, "event": "run.end", "status": "completed"},
])
write(none_id, [
    {
        "ts": mech_ts, "event": "dispatch.start", "dispatch_id": "20260817T180000Z-c0de01",
        "backend": "codex", "mode": "implement",
    },
    {
        "ts": mech_ts, "event": "gate.result", "policy": "strict",
        "purpose": "unit-final", "binding": "clean",
    },
])
write(note_id, [
    {"ts": note_ts, "event": "run.begin", "generation": 3, "workspace": ws, "workspace_key": key},
    {"ts": note_ts, "event": "checkpoint", "note": "held"},
    {
        "ts": review_ts, "event": "review.recorded", "unit": "u-note",
        "round": 1, "verdict": "pass",
    },
])
write(mech_id, [
    {"ts": bad_agent_ts, "event": "run.begin", "generation": 4, "workspace": ws, "workspace_key": key},
    {
        "ts": mech_ts, "event": "dispatch.start", "dispatch_id": "20260817T180000Z-c0de02",
        "backend": "codex", "mode": "implement",
    },
    {
        "ts": mech_ts, "event": "gate.result", "policy": "passthrough",
        "purpose": "focused", "binding": "dirty",
    },
])
json.dump(
    {
        "fresh_ts": fresh_ts,
        "stale_ts": stale_ts,
        "note_ts": note_ts,
        "review_ts": review_ts,
        "mech_ts": mech_ts,
        "bad_agent_ts": bad_agent_ts,
    },
    open(meta_path, "w", encoding="utf-8"),
)
PY

run_cmd cp-index env LOOP_INDEX_CHECKPOINT_FRESH_SEC=60 "$INDEX" --workspace "$WS_CP"
expect_status 0 "checkpoint: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$CP_META" "$CP_FRESH" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
run_id = sys.argv[3]
run = next(item for item in doc["runs"] if item["run_id"] == run_id)
cp = run["checkpoint"]
if cp.get("state") != "fresh":
    raise SystemExit(cp)
if cp.get("ts") != meta["fresh_ts"]:
    raise SystemExit(f"ts {cp}")
if "age_minutes" in cp:
    raise SystemExit("fresh must omit age_minutes")
PY
then
  pass "checkpoint: recent agent event is fresh under small override"
else
  fail "checkpoint: recent agent event is fresh under small override"
fi

if python3 - "$CASE_STDOUT" "$CP_META" "$CP_STALE" <<'PY'
import json, sys
from datetime import datetime, timezone
doc = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
run_id = sys.argv[3]
run = next(item for item in doc["runs"] if item["run_id"] == run_id)
cp = run["checkpoint"]
if cp.get("state") != "stale":
    raise SystemExit(cp)
if cp.get("ts") != meta["stale_ts"]:
    raise SystemExit(f"ts {cp}")
epoch = datetime.strptime(meta["stale_ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
    tzinfo=timezone.utc
).timestamp()
expected = int((datetime.now(timezone.utc).timestamp() - epoch) // 60)
if abs(cp.get("age_minutes") - expected) > 1:
    raise SystemExit(f"age_minutes {cp} expected {expected}")
if run["status"] != "completed":
    raise SystemExit("terminal run must still compute checkpoint")
PY
then
  pass "checkpoint: stale carries ts and age_minutes; terminal still computed"
else
  fail "checkpoint: stale carries ts and age_minutes; terminal still computed"
fi

if python3 - "$CASE_STDOUT" "$CP_NONE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run_id = sys.argv[2]
run = next(item for item in doc["runs"] if item["run_id"] == run_id)
if run["checkpoint"] != {"state": "unknown"}:
    raise SystemExit(run["checkpoint"])
PY
then
  pass "checkpoint: mechanical-events-only run is unknown"
else
  fail "checkpoint: mechanical-events-only run is unknown"
fi

if python3 - "$CASE_STDOUT" "$CP_META" "$CP_NOTE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
run_id = sys.argv[3]
cp = next(item for item in doc["runs"] if item["run_id"] == run_id)["checkpoint"]
if cp.get("state") != "fresh":
    raise SystemExit(cp)
if cp.get("ts") != meta["review_ts"]:
    raise SystemExit(f"freshness ts must be the later review: {cp}")
if cp.get("note") != "held":
    raise SystemExit(f"note {cp}")
PY
then
  pass "checkpoint: note from older checkpoint; later review is freshness"
else
  fail "checkpoint: note from older checkpoint; later review is freshness"
fi

if python3 - "$CASE_STDOUT" "$CP_META" "$CP_MECH" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
run_id = sys.argv[3]
cp = next(item for item in doc["runs"] if item["run_id"] == run_id)["checkpoint"]
if cp.get("state") == "fresh":
    raise SystemExit("recent mechanical events must not count as fresh")
if cp.get("state") != "stale":
    raise SystemExit(cp)
if cp.get("ts") != meta["bad_agent_ts"]:
    raise SystemExit(f"ts must be the old agent event: {cp}")
if cp.get("ts") == meta["mech_ts"]:
    raise SystemExit("mechanical ts leaked")
PY
then
  pass "checkpoint: recent dispatch/gate events do not make the axis fresh"
else
  fail "checkpoint: recent dispatch/gate events do not make the axis fresh"
fi

# ---------------------------------------------------------------------------
# CLI / contract extras
# ---------------------------------------------------------------------------
run_cmd help-index "$INDEX" --help
expect_status 0 "help: exits 0"
if grep -Fq "LOOP_INDEX_ACTIVITY_SEC" "$CASE_STDOUT" && \
   grep -Fq "LOOP_INDEX_STALL_SEC" "$CASE_STDOUT" && \
   grep -Fq "LOOP_INDEX_CHECKPOINT_FRESH_SEC" "$CASE_STDOUT" && \
   grep -Fq "Exit codes" "$CASE_STDOUT"
then
  pass "help: documents env overrides and exit codes"
else
  fail "help: documents env overrides and exit codes"
fi
if grep -Fq "checkpoint" "$CASE_STDOUT" && \
   grep -Fq "age_minutes" "$CASE_STDOUT"
then
  pass "help: documents the checkpoint key"
else
  fail "help: documents the checkpoint key"
fi
if grep -Eq '[[:space:]]alive[[:space:]]' "$CASE_STDOUT"; then
  fail "help: must not present alive as a state"
else
  pass "help: must not present alive as a state"
fi
if grep -Eq '[[:space:]]disconnected[[:space:]]' "$CASE_STDOUT"; then
  fail "help: must not present disconnected as a state"
else
  pass "help: must not present disconnected as a state"
fi

run_cmd usage-bad "$INDEX" --nope
expect_status 2 "usage: unknown flag exits 2"
run_cmd usage-ws "$INDEX" --workspace "$TMP_ROOT/missing-ws"
expect_status 2 "usage: missing workspace exits 2"

run_cmd home-unset env -u HOME "$INDEX" --workspace "$WS_EMPTY"
if [[ $CASE_STATUS -ne 0 && $CASE_STATUS -ne 2 ]]; then
  pass "store: unset HOME is an operational failure"
else
  fail "store: unset HOME is an operational failure (got $CASE_STATUS)"
fi

run_cmd pretty-index "$INDEX" --pretty --workspace "$WS_EMPTY"
expect_status 0 "pretty: exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
doc = json.loads(raw)
if doc["schema"] != 1 or "\n" not in raw:
    raise SystemExit(1)
PY
then
  pass "pretty: still one JSON document"
else
  fail "pretty: still one JSON document"
fi

if python3 - "$SCHEMA" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# The word may appear only as a prohibition, never as a listed state cell.
for word in ("alive", "disconnected"):
    for line in text.splitlines():
        if re.search(r"\|\s*%s\s*\|" % word, line, re.I):
            raise SystemExit(1)
        if re.search(r"`%s`" % word, line) and not re.search(
            r"\b(not|never|forbidden)\b", line, re.I
        ):
            raise SystemExit(1)
PY
then
  pass "schema: alive is not a listed state"
else
  fail "schema: alive is not a listed state"
fi

if python3 - "$SCHEMA" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needed = (
    "fresh",
    "stale",
    "unknown",
    "agent-invoked",
    "LOOP_INDEX_CHECKPOINT_FRESH_SEC",
    "age_minutes",
)
missing = [word for word in needed if word not in text]
if missing:
    raise SystemExit("missing " + ",".join(missing))
if "dispatch.start" not in text or "gate.result" not in text:
    raise SystemExit("mechanical events unnamed")
PY
then
  pass "schema: checkpoint axis documents words, evidence, and classification"
else
  fail "schema: checkpoint axis documents words, evidence, and classification"
fi

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
