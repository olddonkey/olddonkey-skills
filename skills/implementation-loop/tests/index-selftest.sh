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
# A caller's declared attribution must not leak into fixture events.
unset LOOP_UNIT LOOP_ROUND

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

INVENTORY_PY='
INVENTORY = {
    "claude": {
        "early failure": ["project-files.zlist", "prompt.txt"],
        "parse failure": ["project-files.zlist", "prompt.txt", "stream.jsonl", "stderr.log"],
        "read-only": ["project-files.zlist", "prompt.txt", "stream.jsonl", "stderr.log", "last-message.txt"],
        "implement": ["project-files.zlist", "prompt.txt", "stream.jsonl", "stderr.log", "last-message.txt", "changes.patch"],
        "successful terminal": ["project-files.zlist", "prompt.txt", "stream.jsonl", "stderr.log", "last-message.txt", "changes.patch", "apply-check.log", "apply.log"],
    },
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
            "changes.patch",
        ],
        "read-only": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt",
        ],
        "implement": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt", "changes.patch",
        ],
        "successful terminal": [
            "project-files.zlist", "prompt.txt", "output.json", "stderr.log",
            "parsed.json", "result.txt", "changes.patch",
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
BACKENDS = ("claude", "codex", "grok", "cursor")
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

# Compare the gates loop-index printed (CASE_STDOUT) for one run against the
# expected verdict/gate_exit of one group of cases, matched by position.
expect_gate_verdicts() { # $1=run id $2=cases json $3=case group $4=description
  if python3 - "$CASE_STDOUT" "$1" "$2" "$3" <<'PY'
import json, sys
path, run_id, cases_path, wanted = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == run_id)
cases = json.load(open(cases_path, encoding="utf-8"))
gates = run["gates"]
if len(gates) != len(cases):
    raise SystemExit(f"{len(gates)} gates for {len(cases)} cases")
for gate, (group, label, verdict, gate_exit) in zip(gates, cases):
    if group != wanted:
        continue
    if gate.get("verdict") != verdict:
        raise SystemExit(f"{label}: verdict {gate.get('verdict')!r}, expected {verdict!r}")
    if gate_exit is None:
        if "gate_exit" in gate:
            raise SystemExit(f"{label}: non-int gate_exit passed through: {gate}")
    elif type(gate.get("gate_exit")) is not int or gate["gate_exit"] != gate_exit:
        raise SystemExit(f"{label}: gate_exit {gate.get('gate_exit')!r}, expected {gate_exit}")
    if gate.get("totals") != "exit=0":
        raise SystemExit(f"{label}: totals {gate}")
PY
  then
    pass "$4"
  else
    fail "$4"
  fi
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
mkdir -p "$CODEX_FIX" "$COMMON_FIX/olddonkey-loop/claude" "$COMMON_FIX/olddonkey-loop/grok" "$COMMON_FIX/olddonkey-loop/cursor"
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop"

python3 - "$TMP_ROOT/expected-inventory.json" <<PY
import json, sys
$INVENTORY_PY
json.dump(INVENTORY, open(sys.argv[1], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY

python3 - "$SCHEMA" "$TMP_ROOT/doc-inventory.json" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
backends = ("claude", "codex", "grok", "cursor")
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
    heading = re.match(r"^### (Claude|Codex|Grok|Cursor)\s*$", raw_line)
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
    "claude": os.path.join(common, "olddonkey-loop", "claude"),
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
    "claude": os.path.join(common, "olddonkey-loop", "claude"),
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
  pass "fixtures: five lifecycle classes × four backends built on disk"
else
  fail "fixtures: five lifecycle classes × four backends built on disk"
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
  pass "fixtures: twenty unattributed state dirs indexed by exact basename"
else
  fail "fixtures: twenty unattributed state dirs indexed by exact basename"
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

PIPE_CLAUDE="20260817T120000Z-a1a2a3"
PIPE_CODEX="20260817T120000Z-c0de0001"
PIPE_GROK="20260817T120000Z-aa11bb"
PIPE_CURSOR="20260817T120000Z-cc22dd"
run_cmd pipe-ds-a "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.start \
  --field "dispatch_id=$PIPE_CLAUDE" --field backend=claude --field mode=implement
expect_status 0 "pipeline: dispatch.start claude"
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
  "$COMMON_PIPE/olddonkey-loop/claude/$PIPE_CLAUDE" \
  "$COMMON_PIPE/olddonkey-loop/grok/$PIPE_GROK" \
  "$COMMON_PIPE/olddonkey-loop/cursor/$PIPE_CURSOR"
build_fixture "claude" "successful terminal" "$COMMON_PIPE/olddonkey-loop/claude/$PIPE_CLAUDE"
build_fixture "codex" "successful terminal" "$CODEX_PIPE/$PIPE_CODEX"
build_fixture "grok" "successful terminal" "$COMMON_PIPE/olddonkey-loop/grok/$PIPE_GROK"
build_fixture "cursor" "read-only" "$COMMON_PIPE/olddonkey-loop/cursor/$PIPE_CURSOR"

run_cmd pipe-de-a "$JOURNAL" append --workspace "$WS_PIPE" --event dispatch.end \
  --field "dispatch_id=$PIPE_CLAUDE" --field exit=0 --field session=sess-claude
expect_status 0 "pipeline: dispatch.end claude"
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
  "$PIPE_CLAUDE" "$PIPE_CODEX" "$PIPE_GROK" "$PIPE_CURSOR" "$CODEX_PIPE" "$COMMON_PIPE" <<'PY'
import json, os, sys
(
    path, run_new, run_old, gen_new, gen_old, d_claude, d_codex, d_grok, d_cursor,
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
    (d_claude, "claude", "sess-claude"),
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
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
gate = doc["runs"][0]["gates"][0]
if gate.get("totals") != "exit=0":
    raise SystemExit(f"totals {gate}")
if gate.get("verdict") != "unknown" or "gate_exit" in gate:
    raise SystemExit(f"legacy gate {gate}")
PY
then
  pass "pipeline: legacy gate.result without verdict reads unknown despite totals=exit=0"
else
  fail "pipeline: legacy gate.result without verdict reads unknown despite totals=exit=0"
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
NG_CLAUDE="20260817T160000Z-aa8800"
NG_CODEX="20260817T160000Z-c0de0009"
NG_GROK="20260817T160000Z-aa9900"
NG_CURSOR="20260817T160000Z-cc9900"
run_cmd ng-a "$JOURNAL" append --workspace "$WS_NOGIT" --event dispatch.start \
  --field "dispatch_id=$NG_CLAUDE" --field backend=claude --field mode=read-only
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
if python3 - "$CASE_STDOUT" "$NG_CLAUDE" "$NG_CODEX" "$NG_GROK" "$NG_CURSOR" "$CODEX_NG" <<'PY'
import json, os, sys
path, d_claude, d_codex, d_grok, d_cursor, root = sys.argv[1:]
doc = json.load(open(path, encoding="utf-8"))
items = {item["dispatch_id"]: item for item in doc["runs"][0]["dispatches"]}
if items[d_codex]["state_dir"] != os.path.join(root, d_codex):
    raise SystemExit("codex should still index")
if items[d_claude]["state_dir"] != "unavailable":
    raise SystemExit(items[d_claude])
if items[d_grok]["state_dir"] != "unavailable":
    raise SystemExit(items[d_grok])
if items[d_cursor]["state_dir"] != "unavailable":
    raise SystemExit(items[d_cursor])
if doc["unattributed_state"]["claude"] != "unavailable":
    raise SystemExit(doc["unattributed_state"])
if doc["unattributed_state"]["grok"] != "unavailable":
    raise SystemExit(doc["unattributed_state"])
if doc["unattributed_state"]["cursor"] != "unavailable":
    raise SystemExit(doc["unattributed_state"])
if not isinstance(doc["unattributed_state"]["codex"], list):
    raise SystemExit("codex unattributed")
PY
then
  pass "gitless: claude/grok/cursor unavailable, codex still indexed, exit 0"
else
  fail "gitless: claude/grok/cursor unavailable, codex still indexed, exit 0"
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
# 11. Gate verdict normalization
# ---------------------------------------------------------------------------
# Raw lines, not loop-journal appends: the append validator would refuse most
# of these, but the index reads stored JSON without payload validation.
WS_VERDICT="$(workspace gate-verdict)"
RUN_VERDICT="20260817T190000Z-9a7e01"
GATE_CASES="$TMP_ROOT/gate-verdict-cases.json"
python3 - "$WS_VERDICT" "$HOME" "$RUN_VERDICT" "$GATE_CASES" <<'PY'
import hashlib, json, os, sys

ws, home, run_id, cases_path = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
absent = object()
# (group, label, journaled verdict, journaled gate_exit, expected verdict,
#  expected gate_exit or None when it must not be passed through)
cases = [
    ("exact", "green/0", "green", 0, "green", 0),
    ("exact", "red/1", "red", 1, "red", 1),
    ("exact", "red/137", "red", 137, "red", 137),
    ("inconsistent", "green/1", "green", 1, "unknown", 1),
    ("inconsistent", "red/0", "red", 0, "unknown", 0),
    ("inconsistent", "green without gate_exit", "green", absent, "unknown", None),
    ("inconsistent", "green with gate_exit false", "green", False, "unknown", None),
    ("inconsistent", "red with gate_exit true", "red", True, "unknown", None),
    ("inconsistent", "green with gate_exit 0.0", "green", 0.0, "unknown", None),
    ("inconsistent", "red with gate_exit 1.0", "red", 1.0, "unknown", None),
    ("inconsistent", 'green with gate_exit "0"', "green", "0", "unknown", None),
    ("malformed", "verdict maybe/0", "maybe", 0, "unknown", 0),
    ("malformed", "verdict GREEN/0", "GREEN", 0, "unknown", 0),
    ("malformed", "verdict list/0", ["green"], 0, "unknown", 0),
    ("malformed", "no verdict, totals exit=0", absent, absent, "unknown", None),
]
with open(os.path.join(runs_dir, run_id + ".jsonl"), "w", encoding="utf-8") as handle:
    for index, (_, label, verdict, gate_exit, _, _) in enumerate(cases, 1):
        row = {
            "schema": 1, "seq": index, "run": run_id, "ts": "2026-08-17T19:00:00Z",
            "event": "gate.result", "policy": "strict", "purpose": "unit-final",
            "binding": "clean", "totals": "exit=0",
        }
        if verdict is not absent:
            row["verdict"] = verdict
        if gate_exit is not absent:
            row["gate_exit"] = gate_exit
        handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
json.dump(
    [[group, label, verdict, gate_exit] for group, label, _, _, verdict, gate_exit in cases],
    open(cases_path, "w", encoding="utf-8"),
)
PY

run_cmd verdict-index "$INDEX" --workspace "$WS_VERDICT"
expect_status 0 "gate verdict: loop-index exits 0"
expect_gate_verdicts "$RUN_VERDICT" "$GATE_CASES" exact \
  "gate verdict: green/0 reads green and red/1, red/137 read red, gate_exit passed through"
expect_gate_verdicts "$RUN_VERDICT" "$GATE_CASES" inconsistent \
  "gate verdict: green/1, red/0, missing gate_exit, and bool/float/string gate_exit read unknown"
expect_gate_verdicts "$RUN_VERDICT" "$GATE_CASES" malformed \
  "gate verdict: malformed or absent verdict reads unknown; never inferred from totals=exit=0"

# ---------------------------------------------------------------------------
# 12. Declared attribution, run totals, and the timeline
# ---------------------------------------------------------------------------
# Free text must never reach the timeline or the totals. The marker sits in
# every free-text field the fixtures can carry.
MARKER="FREE-TEXT-MARKER-5c1e"
WS_ATTR="$(workspace attribution)"
run_cmd attr-begin "$RUN" begin --workspace "$WS_ATTR" --plan "plan $MARKER"
RUN_ATTR="$(field_from "$CASE_STDOUT" run)"
SEG_ATTR="$(store_dir "$WS_ATTR")/runs/${RUN_ATTR}.jsonl"
ATTR_STATUSES="$CASE_STATUS"
attr_step() { # $1=case name, remaining=command
  local name="$1"
  shift
  run_cmd "attr-$name" "$@"
  ATTR_STATUSES+="$CASE_STATUS"
}
attr_step unit "$RUN" unit-begin --unit u-a --workspace "$WS_ATTR"
attr_step ds-a env LOOP_UNIT=u-a LOOP_ROUND=1 "$JOURNAL" append --workspace "$WS_ATTR" \
  --event dispatch.start --field dispatch_id=d-a --field backend=codex --field mode=implement
attr_step de-a env LOOP_UNIT=u-a LOOP_ROUND=1 "$JOURNAL" append --workspace "$WS_ATTR" \
  --event dispatch.end --field dispatch_id=d-a --field exit=0 --field "session=session $MARKER"
attr_step ds-b "$JOURNAL" append --workspace "$WS_ATTR" \
  --event dispatch.start --field dispatch_id=d-b --field backend=grok --field mode=implement
attr_step de-b "$JOURNAL" append --workspace "$WS_ATTR" \
  --event dispatch.end --field dispatch_id=d-b --field exit=3
attr_step gate-a env LOOP_UNIT=u-a LOOP_ROUND=1 "$JOURNAL" append --workspace "$WS_ATTR" \
  --event gate.result --field policy=strict --field purpose=unit-final --field binding=unavailable \
  --field "reason=reason $MARKER" --field totals=exit=0 --field verdict=green --field gate_exit=0
attr_step gate-b "$JOURNAL" append --workspace "$WS_ATTR" \
  --event gate.result --field policy=passthrough --field purpose=focused --field binding=clean \
  --field totals=exit=1 --field verdict=red --field gate_exit=1
attr_step review "$RUN" review --unit u-a --round 1 --verdict iterate \
  --findings "findings $MARKER" --workspace "$WS_ATTR"
attr_step publish "$RUN" publish --unit u-a --branch "branch-$MARKER" \
  --pr "https://example.invalid/$MARKER" --sha "sha-$MARKER" --note "note $MARKER" \
  --workspace "$WS_ATTR"
attr_step checkpoint "$RUN" checkpoint --note "note $MARKER" --workspace "$WS_ATTR"
attr_step ds-c env LOOP_UNIT=u-a LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_ATTR" \
  --event dispatch.start --field dispatch_id=d-c --field backend=cursor --field mode=read-only
attr_step recover "$RUN" recover --acknowledge d-c --workspace "$WS_ATTR"
if [[ "$ATTR_STATUSES" =~ ^0+$ && ${#ATTR_STATUSES} -eq 13 ]]; then
  pass "attribution: writer fixture with labelled and unlabelled dispatches and gates appends"
else
  fail "attribution: writer fixture with labelled and unlabelled dispatches and gates appends (statuses $ATTR_STATUSES)"
fi
run_cmd attr-index "$INDEX" --workspace "$WS_ATTR"
expect_status 0 "attribution: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$RUN_ATTR" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
items = {item["dispatch_id"]: item for item in run["dispatches"]}
a, b, c = items["d-a"], items["d-b"], items["d-c"]
if (a.get("unit"), a.get("round"), a.get("attribution")) != ("u-a", 1, "declared"):
    raise SystemExit(f"labelled dispatch {a}")
if "unit" in b or "round" in b or b.get("attribution") != "none":
    raise SystemExit(f"unlabelled dispatch {b}")
if (c.get("unit"), c.get("round"), c.get("attribution"), c.get("state")) != ("u-a", 2, "declared", "abandoned"):
    raise SystemExit(f"recovered dispatch {c}")
gates = run["gates"]
if (gates[0].get("unit"), gates[0].get("round"), gates[0].get("attribution")) != ("u-a", 1, "declared"):
    raise SystemExit(f"labelled gate {gates[0]}")
if "unit" in gates[1] or "round" in gates[1] or gates[1].get("attribution") != "none":
    raise SystemExit(f"unlabelled gate {gates[1]}")
if [unit["unit"] for unit in run["units"]] != ["u-a"]:
    raise SystemExit(f"units {run['units']}")
PY
then
  pass "attribution: dispatch and gate objects carry declared unit/round, or attribution none"
else
  fail "attribution: dispatch and gate objects carry declared unit/round, or attribution none"
fi
if python3 - "$CASE_STDOUT" "$RUN_ATTR" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
expected = {
    "d-a": {"backend": "codex", "unit": "u-a", "round": 1, "attribution": "declared"},
    "d-b": {"backend": "grok", "attribution": "none"},
    "d-c": {"backend": "cursor", "unit": "u-a", "round": 2, "attribution": "declared"},
}
seen = set()
for item in run["timeline"]:
    kind = item["event"]
    if kind.startswith("dispatch."):
        want = expected[item["dispatch_id"]]
        got = {key: item[key] for key in ("backend", "unit", "round", "attribution") if key in item}
        if got != want:
            raise SystemExit(f"{kind} {item}")
    elif kind == "gate.result":
        got = {key: item[key] for key in ("unit", "round", "attribution") if key in item}
        want = (
            {"unit": "u-a", "round": 1, "attribution": "declared"}
            if item["gate_verdict"] == "green"
            else {"attribution": "none"}
        )
        if got != want:
            raise SystemExit(f"gate {item}")
    elif kind in ("review.recorded", "publish.recorded"):
        if item.get("unit") != "u-a" or item.get("attribution") != "declared":
            raise SystemExit(f"{kind} {item}")
    else:
        continue
    seen.add(kind)
wanted = {
    "dispatch.start", "dispatch.end", "dispatch.abandoned",
    "gate.result", "review.recorded", "publish.recorded",
}
if seen != wanted:
    raise SystemExit(f"packet-bearing kinds {sorted(seen)}")
PY
then
  pass "timeline: every packet-bearing event type carries unit and attribution as specified"
else
  fail "timeline: every packet-bearing event type carries unit and attribution as specified"
fi
if python3 - "$CASE_STDOUT" "$RUN_ATTR" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])

def bucket(ok=0, failed=0, open_=0, abandoned=0):
    return {"ok": ok, "failed": failed, "open": open_, "abandoned": abandoned}

def counts(dispatches=None, reviews=(0, 0), gates=(0, 0, 0), publishes=0):
    return {
        "dispatches": dispatches or {},
        "reviews": {"iterate": reviews[0], "pass": reviews[1]},
        "gates": {"green": gates[0], "red": gates[1], "unknown": gates[2]},
        "publishes": publishes,
    }

expected = {
    "all": counts(
        {"codex": bucket(ok=1), "grok": bucket(failed=1), "cursor": bucket(abandoned=1)},
        reviews=(1, 0), gates=(1, 1, 0), publishes=1,
    ),
    "units": {
        "u-a": counts(
            {"codex": bucket(ok=1), "cursor": bucket(abandoned=1)},
            reviews=(1, 0), gates=(1, 0, 0), publishes=1,
        ),
    },
    "unattributed": counts({"grok": bucket(failed=1)}, gates=(0, 1, 0)),
}
if run["counts"] != expected:
    raise SystemExit(json.dumps(run["counts"], indent=1))
if run["counts_complete"] is not True or run["timeline_truncated"] is not False:
    raise SystemExit("flags")
seqs = [item["seq"] for item in run["timeline"]]
if seqs != list(range(1, 15)):
    raise SystemExit(f"seqs {seqs}")
PY
then
  pass "counts: writer fixture totals split by declared unit and unattributed"
else
  fail "counts: writer fixture totals split by declared unit and unattributed"
fi

# Raw lines carry free text the writer's enums refuse (attested_by) as well.
WS_FREE="$(workspace free-text)"
RUN_FREE="20260817T200000Z-f7ee01"
python3 - "$WS_FREE" "$HOME" "$RUN_FREE" "$MARKER" <<'PY'
import hashlib, json, os, sys
ws, home, run_id, marker = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
text = f"text {marker}"
events = [
    {"event": "run.begin", "generation": 1, "workspace": ws, "workspace_key": key, "plan": text},
    {"event": "unit.begin", "unit": "u-m"},
    {"event": "dispatch.start", "dispatch_id": "d-m", "backend": "codex", "mode": "implement",
     "unit": "u-m", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-m", "exit": 0, "session": text, "unit": "u-m", "round": 1},
    {"event": "dispatch.start", "dispatch_id": "d-n", "backend": "grok", "mode": "read-only"},
    {"event": "dispatch.abandoned", "dispatch_id": "d-n", "attested_by": text},
    {"event": "gate.result", "policy": "strict", "purpose": "unit-final", "binding": "unavailable",
     "reason": text, "totals": text, "pre_head": text, "pre_tree": text, "post_head": text,
     "post_tree": text, "verdict": "green", "gate_exit": 0, "unit": "u-m"},
    {"event": "review.recorded", "unit": "u-m", "round": 1, "verdict": "pass", "findings": text},
    {"event": "publish.recorded", "unit": "u-m", "branch": f"branch-{marker}",
     "pr": f"https://example.invalid/{marker}", "sha": f"sha-{marker}", "note": text},
    {"event": "checkpoint", "note": text},
    {"event": "unit.end", "unit": "u-m", "status": "done"},
    {"event": "run.end", "status": "completed"},
]
with open(os.path.join(runs_dir, run_id + ".jsonl"), "w", encoding="utf-8") as handle:
    for seq, event in enumerate(events, 1):
        row = {"schema": 1, "seq": seq, "ts": "2026-08-17T20:00:00Z", "run": run_id}
        row.update(event)
        handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
PY
SEG_FREE="$(store_dir "$WS_FREE")/runs/${RUN_FREE}.jsonl"
run_cmd free-index "$INDEX" --workspace "$WS_FREE"
expect_status 0 "timeline: free-text fixture indexes with exit 0"
if python3 - "$MARKER" "$TMP_ROOT/attr-index.stdout" "$RUN_ATTR" "$SEG_ATTR" \
  "$CASE_STDOUT" "$RUN_FREE" "$SEG_FREE" <<'PY'
import json, sys
marker = sys.argv[1]
for output, run_id, segment in (sys.argv[2:5], sys.argv[5:8]):
    raw = open(segment, encoding="utf-8").read()
    if raw.count(marker) < 8:
        raise SystemExit(f"fixture too weak: {raw.count(marker)} markers in {segment}")
    doc = json.load(open(output, encoding="utf-8"))
    run = next(item for item in doc["runs"] if item["run_id"] == run_id)
    projected = json.dumps({"timeline": run["timeline"], "counts": run["counts"]})
    if marker in projected:
        raise SystemExit(f"free text leaked into timeline/counts of {run_id}")
    if len(run["timeline"]) < 10:
        raise SystemExit("timeline unexpectedly short")
free_raw = open(sys.argv[7], encoding="utf-8").read()
if f'"attested_by":"text {marker}"' not in free_raw or f'"pr":"https://example.invalid/{marker}"' not in free_raw:
    raise SystemExit("fixture lacks attested_by/pr markers")
PY
then
  pass "timeline: free-text fields (findings, note, plan, reason, attested_by, branch, pr, sha) appear nowhere in timeline or counts"
else
  fail "timeline: free-text fields (findings, note, plan, reason, attested_by, branch, pr, sha) appear nowhere in timeline or counts"
fi
if python3 - "$TMP_ROOT/attr-index.stdout" "$RUN_ATTR" "$CASE_STDOUT" "$RUN_FREE" <<'PY'
import json, sys
allowed = {
    "seq", "ts", "event", "dispatch_id", "mode", "exit", "binding", "purpose",
    "gate_verdict", "review_verdict", "reviewer", "backend", "unit", "round", "attribution",
}
for output, run_id in (sys.argv[1:3], sys.argv[3:5]):
    doc = json.load(open(output, encoding="utf-8"))
    run = next(item for item in doc["runs"] if item["run_id"] == run_id)
    for item in run["timeline"]:
        extra = set(item) - allowed
        if extra:
            raise SystemExit(f"non-whitelisted keys {sorted(extra)} in {item}")
        if not {"seq", "ts", "event"} <= set(item):
            raise SystemExit(f"missing envelope {item}")
PY
then
  pass "timeline: every event is projected to the closed whitelist"
else
  fail "timeline: every event is projected to the closed whitelist"
fi

# 600 events, file order shuffled: totals cover all of them, the timeline the
# last 500 by seq.
WS_WINDOW="$(workspace timeline-window)"
RUN_WINDOW="20260817T200000Z-a11b01"
python3 - "$WS_WINDOW" "$HOME" "$RUN_WINDOW" <<'PY'
import hashlib, json, os, random, sys
ws, home, run_id = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
events = [
    {"event": "run.begin", "generation": 1, "workspace": ws, "workspace_key": key},
    # seq 2: its end (seq 595) is in the window, the start is not.
    {"event": "dispatch.start", "dispatch_id": "d-early", "backend": "grok", "mode": "implement",
     "unit": "u-w", "round": 1},
]
for index in range(100):  # seq 3-102: 60 green, 30 red, 10 unknown, all u-w
    gate = {"event": "gate.result", "policy": "strict", "purpose": "unit-final", "binding": "clean",
            "unit": "u-w", "round": 1}
    if index % 10 < 6:
        gate.update(verdict="green", gate_exit=0)
    elif index % 10 < 9:
        gate.update(verdict="red", gate_exit=1)
    events.append(gate)
# seq 103: start of a dispatch whose end (seq 594) declares a different unit.
events.append({"event": "dispatch.start", "dispatch_id": "d-conf", "backend": "codex",
               "mode": "implement", "unit": "u-1", "round": 1})
for index in range(100):  # seq 104-203: 50 pass, 50 iterate
    events.append({"event": "review.recorded", "unit": "u-w", "round": 1,
                   "verdict": "pass" if index % 2 == 0 else "iterate"})
for _ in range(50):  # seq 204-253
    events.append({"event": "publish.recorded", "unit": "u-x"})
for _ in range(50):  # seq 254-303: unattributed red gates
    events.append({"event": "gate.result", "policy": "passthrough", "purpose": "focused",
                   "binding": "dirty", "verdict": "red", "gate_exit": 2})
while len(events) < 593:  # seq 304-593
    events.append({"event": "checkpoint", "note": "filler"})
events += [
    {"event": "dispatch.end", "dispatch_id": "d-conf", "exit": 0, "unit": "u-2", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-early", "exit": 0, "unit": "u-w", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-partial", "exit": 1, "unit": "u-p", "round": 2},
    {"event": "dispatch.start", "dispatch_id": "d-open", "backend": "cursor", "mode": "read-only"},
    {"event": "dispatch.start", "dispatch_id": "d-ab", "backend": "codex", "mode": "implement",
     "unit": "u-w", "round": 2},
    {"event": "dispatch.abandoned", "dispatch_id": "d-ab", "attested_by": "user",
     "unit": "u-w", "round": 2},
    {"event": "review.recorded", "unit": "u-w", "round": 2, "verdict": "maybe"},
]
assert len(events) == 600
lines = []
for seq, event in enumerate(events, 1):
    row = {"schema": 1, "seq": seq, "ts": "2026-08-17T20:00:00Z", "run": run_id}
    row.update(event)
    lines.append(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
random.Random(20260817).shuffle(lines)
with open(os.path.join(runs_dir, run_id + ".jsonl"), "w", encoding="utf-8") as handle:
    handle.writelines(lines)
PY
run_cmd window-index "$INDEX" --workspace "$WS_WINDOW"
expect_status 0 "timeline: 600-event run indexes with exit 0"
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
if len(run["timeline"]) != 500 or run["timeline_truncated"] is not True:
    raise SystemExit(f"{len(run['timeline'])} events, truncated={run['timeline_truncated']}")
seqs = [item["seq"] for item in run["timeline"]]
if seqs != list(range(101, 601)):
    raise SystemExit(f"not the last 500 in seq order: {seqs[:5]}...{seqs[-5:]}")
PY
then
  pass "timeline: a 600-event run keeps the last 500 in seq order despite shuffled file order, and sets timeline_truncated"
else
  fail "timeline: a 600-event run keeps the last 500 in seq order despite shuffled file order, and sets timeline_truncated"
fi
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])

def bucket(ok=0, failed=0, open_=0, abandoned=0):
    return {"ok": ok, "failed": failed, "open": open_, "abandoned": abandoned}

def counts(dispatches=None, reviews=(0, 0), gates=(0, 0, 0), publishes=0):
    return {
        "dispatches": dispatches or {},
        "reviews": {"iterate": reviews[0], "pass": reviews[1]},
        "gates": {"green": gates[0], "red": gates[1], "unknown": gates[2]},
        "publishes": publishes,
    }

expected = {
    "all": counts(
        {
            "grok": bucket(ok=1),
            "codex": bucket(ok=1, abandoned=1),
            "unknown": bucket(failed=1),
            "cursor": bucket(open_=1),
        },
        reviews=(50, 50), gates=(60, 80, 10), publishes=50,
    ),
    "units": {
        "u-w": counts(
            {"grok": bucket(ok=1), "codex": bucket(abandoned=1)},
            reviews=(50, 50), gates=(60, 30, 10),
        ),
        "u-x": counts(publishes=50),
    },
    "unattributed": counts(
        {"codex": bucket(ok=1), "cursor": bucket(open_=1), "unknown": bucket(failed=1)},
        gates=(0, 50, 0),
    ),
}
if run["counts"] != expected:
    raise SystemExit(json.dumps(run["counts"], indent=1))
if run["counts_complete"] is not True:
    raise SystemExit("counts_complete")
PY
then
  pass "counts: totals over all 600 events equal the true totals, not the 500-event window"
else
  fail "counts: totals over all 600 events equal the true totals, not the 500-event window"
fi
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
record = next(item for item in run["dispatches"] if item["dispatch_id"] == "d-conf")
if record.get("attribution") != "conflict" or "unit" in record or "round" in record:
    raise SystemExit(f"dispatch {record}")
events = [item for item in run["timeline"] if item.get("dispatch_id") == "d-conf"]
if [item["event"] for item in events] != ["dispatch.start", "dispatch.end"]:
    raise SystemExit(f"events {events}")
for item in events:
    if item.get("attribution") != "conflict" or "unit" in item or "round" in item:
        raise SystemExit(f"timeline {item}")
    if item.get("backend") != "codex":
        raise SystemExit(f"backend {item}")
if {"u-1", "u-2", "u-p"} & {unit["unit"] for unit in run["units"]}:
    raise SystemExit(f"a dispatch label created a unit row: {run['units']}")
PY
then
  pass "attribution: conflicting start/end is conflict, with no unit or round on the dispatch or any of its timeline events"
else
  fail "attribution: conflicting start/end is conflict, with no unit or round on the dispatch or any of its timeline events"
fi
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
record = next(item for item in run["dispatches"] if item["dispatch_id"] == "d-partial")
want = {"backend": "unknown", "unit": "u-p", "round": 2, "attribution": "partial"}
if {key: record.get(key) for key in want} != want:
    raise SystemExit(f"dispatch {record}")
item = next(item for item in run["timeline"] if item.get("dispatch_id") == "d-partial")
if {key: item.get(key) for key in want} != want:
    raise SystemExit(f"timeline {item}")
PY
then
  pass "attribution: an end without a start is partial and keeps what its events declare"
else
  fail "attribution: an end without a start is partial and keeps what its events declare"
fi
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
if any(item.get("dispatch_id") == "d-early" and item["event"] == "dispatch.start" for item in run["timeline"]):
    raise SystemExit("start should be outside the window")
item = next(item for item in run["timeline"] if item.get("dispatch_id") == "d-early")
want = {"seq": 595, "event": "dispatch.end", "backend": "grok", "unit": "u-w", "round": 1,
        "attribution": "declared", "exit": 0}
if {key: item.get(key) for key in want} != want:
    raise SystemExit(f"timeline {item}")
PY
then
  pass "timeline: an end whose start fell outside the window still names its resolved backend"
else
  fail "timeline: an end whose start fell outside the window still names its resolved backend"
fi
if python3 - "$CASE_STDOUT" "$RUN_WINDOW" "$TMP_ROOT/attr-index.stdout" "$RUN_ATTR" <<'PY'
import json, sys
seen = {"gate.result": set(), "review.recorded": set()}
for output, run_id in (sys.argv[1:3], sys.argv[3:5]):
    doc = json.load(open(output, encoding="utf-8"))
    run = next(item for item in doc["runs"] if item["run_id"] == run_id)
    for item in run["timeline"]:
        kind = item["event"]
        if "verdict" in item:
            raise SystemExit(f"raw verdict projected: {item}")
        if ("gate_verdict" in item) != (kind == "gate.result"):
            raise SystemExit(f"gate_verdict placement: {item}")
        if ("review_verdict" in item) != (kind == "review.recorded"):
            raise SystemExit(f"review_verdict placement: {item}")
        if kind == "gate.result":
            seen[kind].add(item["gate_verdict"])
        if kind == "review.recorded":
            seen[kind].add(item["review_verdict"])
if seen["gate.result"] != {"green", "red", "unknown"}:
    raise SystemExit(f"gate verdicts {seen}")
if seen["review.recorded"] != {"pass", "iterate", "unknown"}:
    raise SystemExit(f"review verdicts {seen}")
PY
then
  pass "timeline: review events carry review_verdict and gate events gate_verdict, never each other's"
else
  fail "timeline: review events carry review_verdict and gate events gate_verdict, never each other's"
fi

# A unit owns a count only through a declared attribution: a partial dispatch
# that still carries uA, and a conflicted one whose start says uA, are both
# unattributed. Distinct backends keep each dispatch's bucket identifiable.
WS_OWN="$(workspace count-ownership)"
RUN_OWN="20260817T200000Z-0c0a01"
python3 - "$WS_OWN" "$HOME" "$RUN_OWN" <<'PY'
import hashlib, json, os, sys
ws, home, run_id = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
events = [
    {"event": "run.begin", "generation": 1, "workspace": ws, "workspace_key": key},
    {"event": "unit.begin", "unit": "uA"},
    # (a) declared: start and end agree on uA.
    {"event": "dispatch.start", "dispatch_id": "d-own-decl", "backend": "codex",
     "mode": "implement", "unit": "uA", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-own-decl", "exit": 0, "unit": "uA", "round": 1},
    # (b) partial: an end with no start, declaring uA.
    {"event": "dispatch.end", "dispatch_id": "d-own-part", "exit": 1, "unit": "uA", "round": 1},
    # (c) conflict: start declares uA, end declares uB.
    {"event": "dispatch.start", "dispatch_id": "d-own-conf", "backend": "grok",
     "mode": "implement", "unit": "uA", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-own-conf", "exit": 0, "unit": "uB", "round": 1},
]
with open(os.path.join(runs_dir, run_id + ".jsonl"), "w", encoding="utf-8") as handle:
    for seq, event in enumerate(events, 1):
        row = {"schema": 1, "seq": seq, "ts": "2026-08-17T20:00:00Z", "run": run_id}
        row.update(event)
        handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
PY
run_cmd own-index "$INDEX" --workspace "$WS_OWN"
expect_status 0 "counts: count-ownership fixture indexes with exit 0"
if python3 - "$CASE_STDOUT" "$RUN_OWN" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
records = {item["dispatch_id"]: item for item in run["dispatches"]}
fixture = {
    "d-own-decl": ("declared", "uA"),
    "d-own-part": ("partial", "uA"),
    "d-own-conf": ("conflict", None),
}
for dispatch_id, (attribution, unit) in fixture.items():
    record = records[dispatch_id]
    if (record.get("attribution"), record.get("unit")) != (attribution, unit):
        raise SystemExit(f"fixture premise: {record}")

def bucket(ok=0, failed=0, open_=0, abandoned=0):
    return {"ok": ok, "failed": failed, "open": open_, "abandoned": abandoned}

counts = run["counts"]
if sorted(counts["units"]) != ["uA"]:
    raise SystemExit(f"unit keys {sorted(counts['units'])}")
if counts["units"]["uA"]["dispatches"] != {"codex": bucket(ok=1)}:
    raise SystemExit(f"uA dispatches {counts['units']['uA']['dispatches']}")
want_unattributed = {"unknown": bucket(failed=1), "grok": bucket(ok=1)}
if counts["unattributed"]["dispatches"] != want_unattributed:
    raise SystemExit(f"unattributed dispatches {counts['unattributed']['dispatches']}")
want_all = {"codex": bucket(ok=1), "unknown": bucket(failed=1), "grok": bucket(ok=1)}
if counts["all"]["dispatches"] != want_all:
    raise SystemExit(f"all dispatches {counts['all']['dispatches']}")
PY
then
  pass "counts: only a declared dispatch counts under its unit; partial and conflicted ones are unattributed, and all counts every one"
else
  fail "counts: only a declared dispatch counts under its unit; partial and conflicted ones are unattributed, and all counts every one"
fi

# counts_complete: a discarded torn tail, a kept valid tail, a corrupt middle.
WS_COMPLETE="$(workspace counts-complete)"
RUN_TORN="20260817T210000Z-7a0001"
RUN_VALID_TAIL="20260817T210000Z-7a0002"
RUN_MIDBAD="20260817T210000Z-7a0003"
python3 - "$WS_COMPLETE" "$HOME" "$RUN_TORN" "$RUN_VALID_TAIL" "$RUN_MIDBAD" <<'PY'
import hashlib, json, os, sys
ws, home, torn, valid_tail, midbad = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)

def line(run_id, seq, event):
    row = {"schema": 1, "seq": seq, "ts": "2026-08-17T21:00:00Z", "run": run_id}
    row.update(event)
    return json.dumps(row, ensure_ascii=True, separators=(",", ":"))

def gate(verdict, gate_exit):
    return {"event": "gate.result", "policy": "strict", "purpose": "unit-final",
            "binding": "clean", "verdict": verdict, "gate_exit": gate_exit}

def begin(generation):
    return {"event": "run.begin", "generation": generation, "workspace": ws, "workspace_key": key}

def write(run_id, data):
    with open(os.path.join(runs_dir, run_id + ".jsonl"), "wb") as handle:
        handle.write(data.encode("utf-8"))

write(torn, line(torn, 1, begin(1)) + "\n" + line(torn, 2, gate("green", 0)) + "\n"
      + line(torn, 3, gate("red", 1))[:40])
write(valid_tail, line(valid_tail, 1, begin(2)) + "\n" + line(valid_tail, 2, gate("green", 0))
      + "\n" + line(valid_tail, 3, gate("red", 1)))
write(midbad, line(midbad, 1, begin(3)) + "\n" + line(midbad, 2, gate("green", 0)) + "\n"
      + "this is not json\n" + line(midbad, 4, gate("red", 1)) + "\n"
      + line(midbad, 5, {"event": "review.recorded", "unit": "u", "round": 1, "verdict": "pass"})
      + "\n" + line(midbad, 6, {"event": "publish.recorded", "unit": "u"}) + "\n")
PY
run_cmd complete-index "$INDEX" --workspace "$WS_COMPLETE"
expect_status 0 "counts_complete: loop-index exits 0"
if python3 - "$CASE_STDOUT" "$RUN_TORN" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
if run["counts_complete"] is not False:
    raise SystemExit("torn tail must make counts partial")
if run["status"] != "active":
    raise SystemExit(f"a torn tail is not corruption: {run['status']}")
if run["counts"]["all"]["gates"] != {"green": 1, "red": 0, "unknown": 0}:
    raise SystemExit(run["counts"])
PY
then
  pass "counts_complete: a discarded torn tail reads false while the run stays active"
else
  fail "counts_complete: a discarded torn tail reads false while the run stays active"
fi
if python3 - "$CASE_STDOUT" "$RUN_VALID_TAIL" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
if run["counts_complete"] is not True:
    raise SystemExit("a valid unterminated tail is kept, not discarded")
if run["counts"]["all"]["gates"] != {"green": 1, "red": 1, "unknown": 0}:
    raise SystemExit(run["counts"])
PY
then
  pass "counts_complete: a valid unterminated tail is counted and complete"
else
  fail "counts_complete: a valid unterminated tail is counted and complete"
fi
if python3 - "$CASE_STDOUT" "$RUN_MIDBAD" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
if run["status"] != "degraded" or run["counts_complete"] is not False:
    raise SystemExit(f"status={run['status']} counts_complete={run['counts_complete']}")
totals = run["counts"]["all"]
if totals["gates"] != {"green": 1, "red": 0, "unknown": 0}:
    raise SystemExit(totals)
if totals["reviews"] != {"iterate": 0, "pass": 0} or totals["publishes"] != 0:
    raise SystemExit(totals)
if [item["seq"] for item in run["timeline"]] != [1, 2]:
    raise SystemExit(run["timeline"])
PY
then
  pass "counts_complete: a corrupt middle reads false and events after the damaged line are uncounted"
else
  fail "counts_complete: a corrupt middle reads false and events after the damaged line are uncounted"
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

if python3 - "$SCHEMA" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needed = (
    "LOOP_UNIT",
    "LOOP_ROUND",
    "declaration, not proof",
    "`declared`",
    "`partial`",
    "`conflict`",
    "counts_complete",
    "timeline_truncated",
    "`attested_by`",
)
missing = [word for word in needed if word not in text]
if missing:
    raise SystemExit("missing " + ",".join(missing))
PY
then
  pass "schema: declared attribution, run totals, and timeline are documented"
else
  fail "schema: declared attribution, run totals, and timeline are documented"
fi

# The schema cites source by name. `path:name` must be defined in `path`, a
# bare `:name` in the file of the nearest `path:name` before it, and an
# artifact's file name must appear in the file its writer cell names. A
# line-number citation is refused: nothing can check that it still points at
# the code it meant.
cat > "$TMP_ROOT/citecheck.py" <<'PY'
import os, re, sys

schema, root = sys.argv[1:]
text = open(schema, encoding="utf-8").read()
PATH = r"(?:scripts|backends|tests)/[A-Za-z0-9_./-]+"
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
problems = []
sources = {}


def source(path):
    if path not in sources:
        full = os.path.join(root, path)
        if os.path.isfile(full):
            sources[path] = open(full, encoding="utf-8").read()
        else:
            sources[path] = None
            problems.append("%s: no such file" % path)
    return sources[path]


def defined(name, body):
    # A Python def or class, a shell function, or an assignment in either.
    name = re.escape(name)
    pattern = r"^[ \t]*(?:(?:def|class)[ \t]+%s\b|%s\(\)[ \t]*\{|%s[ \t]*=(?!=))" % (
        name,
        name,
        name,
    )
    return re.search(pattern, body, re.M) is not None


for match in re.finditer(r"%s:\d+|(?<![\w\"]):\d+(?:-\d+)?\b" % PATH, text):
    problems.append("line-number citation %r" % match.group(0))

if text.count("`") % 2:
    problems.append("unbalanced backticks: code spans cannot be paired")
named = 0
current = None
for span in re.findall(r"`([^`]+)`", text):
    if re.fullmatch(PATH, span):
        source(span)
        continue
    if not re.match(r"(?:%s)?:" % PATH, span):
        continue
    match = re.fullmatch(r"(%s)?:(%s)" % (PATH, NAME), span)
    if match is None:
        problems.append("citation %r is not path:name or :name" % span)
        continue
    current = match.group(1) or current
    if current is None:
        problems.append("citation %r follows no path:name" % span)
        continue
    body = source(current)
    if body is not None and not defined(match.group(2), body):
        problems.append("%s does not define %s" % (current, match.group(2)))
    named += 1
if named == 0:
    problems.append("no path:name citation found")

rows = 0
backend = None
for line in text.splitlines():
    heading = re.match(r"^### (Claude|Codex|Grok|Cursor)\s*$", line)
    if heading:
        backend = heading.group(1).lower()
        continue
    if line.startswith("## "):
        backend = None
    if backend is None or not line.startswith("|"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) < 8 or cells[0] == "artifact":
        continue
    if all(cell.replace("-", "") == "" for cell in cells):
        continue
    artifact = cells[0].strip("`")
    writer = re.fullmatch(r"`(%s)(?::%s)?`" % (PATH, NAME), cells[1])
    if writer is None:
        problems.append("%s %s: writer cell %r" % (backend, artifact, cells[1]))
        continue
    body = source(writer.group(1))
    if body is not None and artifact not in body:
        problems.append("%s does not name %s" % (writer.group(1), artifact))
    rows += 1
if rows == 0:
    problems.append("no artifact table row found")

if problems:
    raise SystemExit("\n".join(problems))
PY
CASE_STDOUT=""
CASE_STDERR="$TMP_ROOT/citecheck.stderr"
if python3 "$TMP_ROOT/citecheck.py" "$SCHEMA" "$SCRIPT_DIR/.." 2>"$CASE_STDERR"; then
  pass "schema: every citation names something its file defines, and none is a line number"
else
  fail "schema: every citation names something its file defines, and none is a line number"
fi
sed 's|`scripts/loop-journal:parse_segment`|`scripts/loop-journal:452-477`|' \
  "$SCHEMA" > "$TMP_ROOT/schema-line-cite.md"
if ! cmp -s "$SCHEMA" "$TMP_ROOT/schema-line-cite.md" \
  && ! python3 "$TMP_ROOT/citecheck.py" "$TMP_ROOT/schema-line-cite.md" "$SCRIPT_DIR/.." \
    2>"$CASE_STDERR" \
  && grep -q "line-number citation" "$CASE_STDERR"; then
  pass "schema: the citation check refuses a line-number citation"
else
  fail "schema: the citation check refuses a line-number citation"
fi
sed 's|`scripts/loop-journal:parse_segment`|`scripts/loop-journal:parse_segments`|' \
  "$SCHEMA" > "$TMP_ROOT/schema-stale-name.md"
if ! cmp -s "$SCHEMA" "$TMP_ROOT/schema-stale-name.md" \
  && ! python3 "$TMP_ROOT/citecheck.py" "$TMP_ROOT/schema-stale-name.md" "$SCRIPT_DIR/.." \
    2>"$CASE_STDERR" \
  && grep -q "scripts/loop-journal does not define parse_segments" "$CASE_STDERR"; then
  pass "schema: the citation check refuses a name the cited file does not define"
else
  fail "schema: the citation check refuses a name the cited file does not define"
fi
CASE_STDERR=""

WS_REVIEWER="$(workspace reviewer)"
run_cmd reviewer-begin "$RUN" begin --workspace "$WS_REVIEWER"
RUN_REVIEWER="$(field_from "$CASE_STDOUT" run)"
run_cmd reviewer-record "$RUN" review --workspace "$WS_REVIEWER" --unit u-reviewer \
  --round 1 --verdict pass --reviewer codex
expect_status 0 "reviewer: loop-run records a closed-enum reviewer"
run_cmd reviewer-index "$INDEX" --workspace "$WS_REVIEWER"
if python3 - "$CASE_STDOUT" "$RUN_REVIEWER" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
assert run["units"][0]["review"] == {"verdict": "pass", "round": 1, "reviewer": "codex"}
reviews = [item for item in run["timeline"] if item["event"] == "review.recorded"]
assert len(reviews) == 1 and reviews[0]["reviewer"] == "codex"
PY
then
  pass "reviewer: unit review and timeline project the reviewer"
else
  fail "reviewer: unit review and timeline project the reviewer"
fi
SEG_REVIEWER="$(store_dir "$WS_REVIEWER")/runs/${RUN_REVIEWER}.jsonl"
python3 - "$SEG_REVIEWER" <<'PY'
import json, sys
path = sys.argv[1]
events = [json.loads(line) for line in open(path, encoding="utf-8")]
event = dict(events[-1], seq=3, round=2, verdict="iterate", reviewer="unregistered")
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event) + "\n")
PY
run_cmd reviewer-unknown-string-index "$INDEX" --workspace "$WS_REVIEWER"
if python3 - "$CASE_STDOUT" "$RUN_REVIEWER" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
assert run["units"][0]["review"] == {"verdict": "iterate", "round": 2}
reviews = [item for item in run["timeline"] if item["event"] == "review.recorded"]
assert len(reviews) == 2 and reviews[0]["reviewer"] == "codex"
assert "reviewer" not in reviews[1]
PY
then
  pass "reviewer: unknown stored string is omitted from unit review and timeline"
else
  fail "reviewer: unknown stored string is omitted from unit review and timeline"
fi
python3 - "$SEG_REVIEWER" <<'PY'
import json, sys
path = sys.argv[1]
events = [json.loads(line) for line in open(path, encoding="utf-8")]
event = dict(events[-1], seq=4, reviewer={"unknown": True})
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(event) + "\n")
PY
run_cmd reviewer-unknown-index "$INDEX" --workspace "$WS_REVIEWER"
if python3 - "$CASE_STDOUT" "$RUN_REVIEWER" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
run = next(item for item in doc["runs"] if item["run_id"] == sys.argv[2])
assert run["units"][0]["review"] == {"verdict": "iterate", "round": 2}
reviews = [item for item in run["timeline"] if item["event"] == "review.recorded"]
assert len(reviews) == 3 and reviews[0]["reviewer"] == "codex"
assert all("reviewer" not in item for item in reviews[1:])
PY
then
  pass "reviewer: unknown stored string and object values are not projected"
else
  fail "reviewer: unknown stored string and object values are not projected"
fi

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
