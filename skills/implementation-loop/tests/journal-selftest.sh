#!/usr/bin/env bash
# Hermetic regression checks for loop-journal and loop-run. HOME is a
# scratch directory so the real ~/.config tree is never touched.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
RUN="$SCRIPT_DIR/../scripts/loop-run"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/journal-selftest.XXXXXX")" || exit 1

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  if [[ -n "${LOCK_HOLDER_PID:-}" ]]; then
    kill "$LOCK_HOLDER_PID" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    LOCK_HOLDER_PID=""
  fi
  if [[ -n "${ADAPTER_PID:-}" ]]; then
    kill -KILL "$ADAPTER_PID" 2>/dev/null || true
    wait "$ADAPTER_PID" 2>/dev/null || true
    ADAPTER_PID=""
  fi
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME" || exit 1
export LC_ALL=C

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""
LOCK_HOLDER_PID=""
ADAPTER_PID=""

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

expect_output() { # $1=stream stdout|stderr $2=fixed string $3=description
  local stream="$1" needle="$2" description="$3" path=""
  if [[ "$stream" == stdout ]]; then path="$CASE_STDOUT"; else path="$CASE_STDERR"; fi
  if grep -Fq -- "$needle" "$path"; then
    pass "$description"
  else
    fail "$description (missing: $needle)"
  fi
}

expect_no_output() { # $1=stream $2=fixed string $3=description
  local stream="$1" needle="$2" description="$3" path=""
  if [[ "$stream" == stdout ]]; then path="$CASE_STDOUT"; else path="$CASE_STDERR"; fi
  if grep -Fq -- "$needle" "$path"; then
    fail "$description (unexpected: $needle)"
  else
    pass "$description"
  fi
}

field_from() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" | head -n 1
}

D2A='Supplying --acknowledge <dispatch-id> asserts that the dispatch and its descendants have terminated or otherwise cannot produce further side effects. Mere notice that the event is missing is insufficient and must not retire the run.'

# --- 1. Lock contention ---
WS_LOCK="$(workspace lock)"
run_cmd lock-begin "$RUN" begin --workspace "$WS_LOCK"
expect_status 0 "lock-contention: begin succeeds"
STORE_LOCK="$(store_dir "$WS_LOCK")"
LOCK_FILE="$STORE_LOCK/meta.lock"
RUN_LOCK="$(field_from "$CASE_STDOUT" run)"

run_cmd lock-a "$JOURNAL" append --workspace "$WS_LOCK" --event checkpoint --field note=alpha &
PID_A=$!
run_cmd lock-b "$JOURNAL" append --workspace "$WS_LOCK" --event checkpoint --field note=beta &
PID_B=$!
wait "$PID_A"
STATUS_A=$?
wait "$PID_B"
STATUS_B=$?
CASE_STDOUT="$TMP_ROOT/lock-concurrent.stdout"
CASE_STDERR="$TMP_ROOT/lock-concurrent.stderr"
: >"$CASE_STDOUT"
: >"$CASE_STDERR"
if [[ $STATUS_A -eq 0 && $STATUS_B -eq 0 ]]; then
  pass "lock-contention: concurrent appends both exit 0"
else
  fail "lock-contention: concurrent appends both exit 0 (got $STATUS_A $STATUS_B)"
fi

SEGMENT_LOCK="$STORE_LOCK/runs/${RUN_LOCK}.jsonl"
if python3 - "$SEGMENT_LOCK" <<'PY'
import json, sys
path = sys.argv[1]
raw = open(path, "rb").read()
if not raw.endswith(b"\n"):
    raise SystemExit(1)
lines = raw.decode("utf-8").splitlines()
events = [json.loads(line) for line in lines]
seqs = [event.get("seq") for event in events]
if seqs != list(range(1, len(events) + 1)):
    raise SystemExit(2)
if len({event.get("seq") for event in events}) != len(events):
    raise SystemExit(3)
notes = {event.get("note") for event in events if event.get("event") == "checkpoint"}
if notes != {"alpha", "beta"}:
    raise SystemExit(4)
if len(lines) != 3:
    raise SystemExit(5)
raise SystemExit(0)
PY
then
  pass "lock-contention: distinct seqs and no interleaved/corrupt lines"
else
  fail "lock-contention: distinct seqs and no interleaved/corrupt lines"
fi

python3 - "$LOCK_FILE" "$TMP_ROOT/lock-held.ready" <<'PY' &
import fcntl, os, sys, time
lock_path, ready_path = sys.argv[1], sys.argv[2]
fd = os.open(lock_path, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(ready_path, "w", encoding="utf-8") as handle:
    handle.write("ready\n")
time.sleep(20)
PY
LOCK_HOLDER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$TMP_ROOT/lock-held.ready" ]] && break
  sleep 0.05
done
run_cmd lock-busy env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=0.3 \
  "$JOURNAL" append --workspace "$WS_LOCK" --event checkpoint --field note=busy
expect_status 3 "lock-contention: held lock yields lock-busy exit 3"
expect_output stderr "lock busy" "lock-contention: lock-busy message is distinct"
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""

# --- 2. Tail repair ---
WS_TAIL="$(workspace tail)"
run_cmd tail-begin "$RUN" begin --workspace "$WS_TAIL"
expect_status 0 "tail-repair: begin succeeds"
RUN_TAIL="$(field_from "$CASE_STDOUT" run)"
STORE_TAIL="$(store_dir "$WS_TAIL")"
SEG_TAIL="$STORE_TAIL/runs/${RUN_TAIL}.jsonl"
printf '%s' '{"partial"' >> "$SEG_TAIL"
TRUNCATED_TAIL=10
run_cmd tail-append "$JOURNAL" append --workspace "$WS_TAIL" --event checkpoint --field note=after-repair
expect_status 0 "tail-repair: append after truncated tail succeeds"
if python3 - "$SEG_TAIL" "$TRUNCATED_TAIL" <<'PY'
import json, sys
path, expected = sys.argv[1], int(sys.argv[2])
events = [json.loads(line) for line in open(path, encoding="utf-8")]
if events[0]["event"] != "run.begin" or events[0]["seq"] != 1:
    raise SystemExit(1)
if events[1]["event"] != "journal.repaired":
    raise SystemExit(2)
if events[1]["truncated_bytes"] != expected:
    raise SystemExit(3)
if events[2]["event"] != "checkpoint" or events[2]["note"] != "after-repair":
    raise SystemExit(4)
if [event["seq"] for event in events] != [1, 2, 3]:
    raise SystemExit(5)
raise SystemExit(0)
PY
then
  pass "tail-repair: truncated_bytes recorded and earlier events intact"
else
  fail "tail-repair: truncated_bytes recorded and earlier events intact"
fi

# --- 3. Mid-file corruption ---
WS_MID="$(workspace mid)"
run_cmd mid-begin "$RUN" begin --workspace "$WS_MID"
expect_status 0 "mid-file: begin succeeds"
RUN_MID="$(field_from "$CASE_STDOUT" run)"
STORE_MID="$(store_dir "$WS_MID")"
SEG_MID="$STORE_MID/runs/${RUN_MID}.jsonl"
python3 - "$SEG_MID" "$RUN_MID" <<'PY'
import sys
path, run = sys.argv[1], sys.argv[2]
extra = (
    '{"schema":1,"seq":2,"ts":"2026-01-01T00:00:00Z","event":"checkpoint","run":"%s","note":"ok"}\n'
    "this is not json\n"
    '{"schema":1,"seq":3,"ts":"2026-01-01T00:00:01Z","event":"checkpoint","run":"%s","note":"later"}\n'
) % (run, run)
with open(path, "ab") as handle:
    handle.write(extra.encode("utf-8"))
PY
SUM_BEFORE="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SEG_MID")"
run_cmd mid-append "$JOURNAL" append --workspace "$WS_MID" --event checkpoint --field note=should-fail
expect_status 4 "mid-file: append refuses with distinct exit 4"
SUM_AFTER="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SEG_MID")"
if [[ "$SUM_BEFORE" == "$SUM_AFTER" ]]; then
  pass "mid-file: segment unmodified after refused append"
else
  fail "mid-file: segment unmodified after refused append"
fi
run_cmd mid-rebuild "$JOURNAL" rebuild --workspace "$WS_MID"
expect_status 0 "mid-file: rebuild treats the run as readable-degraded"
if grep -Fq $'\t'"$RUN_MID"$'\tdegraded\t' "$STORE_MID/runs.tsv"; then
  pass "mid-file: rebuild marks the run degraded"
else
  fail "mid-file: rebuild marks the run degraded"
fi
run_cmd mid-gc env LOOP_JOURNAL_GC_CAP_BYTES=1 "$JOURNAL" gc --workspace "$WS_MID"
expect_status 0 "mid-file: gc of a mid-corrupt run stays exit 0"
expect_output stderr "soft-cap overage" "mid-file: gc reports soft-cap rather than deleting protected"
if [[ -f "$SEG_MID" ]]; then
  pass "mid-file: gc leaves the protected corrupted run in place"
else
  fail "mid-file: gc leaves the protected corrupted run in place"
fi

# Terminated invalid final line is mid-corruption, not a repairable tail.
WS_BADEND="$(workspace badend)"
run_cmd badend-begin "$RUN" begin --workspace "$WS_BADEND"
expect_status 0 "term-invalid: begin succeeds"
RUN_BADEND="$(field_from "$CASE_STDOUT" run)"
STORE_BADEND="$(store_dir "$WS_BADEND")"
SEG_BADEND="$STORE_BADEND/runs/${RUN_BADEND}.jsonl"
printf 'not json\n' >> "$SEG_BADEND"
SUM_BADEND_BEFORE="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SEG_BADEND")"
run_cmd badend-append "$JOURNAL" append --workspace "$WS_BADEND" --event checkpoint --field note=should-fail
expect_status 4 "term-invalid: append refuses with exit 4"
SUM_BADEND_AFTER="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SEG_BADEND")"
if [[ "$SUM_BADEND_BEFORE" == "$SUM_BADEND_AFTER" ]]; then
  pass "term-invalid: segment sha256 unchanged after refused append"
else
  fail "term-invalid: segment sha256 unchanged after refused append"
fi
run_cmd badend-rebuild "$JOURNAL" rebuild --workspace "$WS_BADEND"
expect_status 0 "term-invalid: rebuild treats the run as readable-degraded"
if grep -Fq $'\t'"$RUN_BADEND"$'\tdegraded\t' "$STORE_BADEND/runs.tsv"; then
  pass "term-invalid: rebuild marks the run degraded"
else
  fail "term-invalid: rebuild marks the run degraded"
fi

# --- 4. GC ---
WS_GC_BELOW="$(workspace gc-below)"
for i in 1 2 3; do
  run_cmd "gc-below-begin-$i" "$RUN" begin --workspace "$WS_GC_BELOW"
  run_cmd "gc-below-end-$i" "$RUN" end --status completed --workspace "$WS_GC_BELOW"
done
STORE_GC_BELOW="$(store_dir "$WS_GC_BELOW")"
COUNT_BEFORE="$(find "$STORE_GC_BELOW/runs" -name '*.jsonl' | wc -l | tr -d ' ')"
run_cmd gc-below "$JOURNAL" gc --workspace "$WS_GC_BELOW"
expect_status 0 "gc: below-cap invocation succeeds"
COUNT_AFTER="$(find "$STORE_GC_BELOW/runs" -name '*.jsonl' | wc -l | tr -d ' ')"
if [[ "$COUNT_BEFORE" == "$COUNT_AFTER" && "$COUNT_AFTER" == 3 ]]; then
  pass "gc: below-cap deletes nothing"
else
  fail "gc: below-cap deletes nothing (before=$COUNT_BEFORE after=$COUNT_AFTER)"
fi
if grep -Eq '^deleted ' "$CASE_STDOUT"; then
  fail "gc: below-cap prints no deleted lines"
else
  pass "gc: below-cap prints no deleted lines"
fi

WS_GC="$(workspace gc-above)"
GC_RUNS=()
GC_GENS=()
for i in $(seq 1 25); do
  run_cmd "gc-above-begin-$i" "$RUN" begin --workspace "$WS_GC"
  GC_RUNS+=("$(field_from "$CASE_STDOUT" run)")
  GC_GENS+=("$(field_from "$CASE_STDOUT" generation)")
  run_cmd "gc-above-pad-$i" "$JOURNAL" append --workspace "$WS_GC" --event checkpoint --field note="$(python3 -c 'print("x"*800)')"
  run_cmd "gc-above-end-$i" "$RUN" end --status completed --workspace "$WS_GC"
done
run_cmd gc-above-active "$RUN" begin --workspace "$WS_GC"
ACTIVE_RUN="$(field_from "$CASE_STDOUT" run)"
STORE_GC="$(store_dir "$WS_GC")"
run_cmd gc-above env LOOP_JOURNAL_GC_CAP_BYTES=12000 "$JOURNAL" gc --workspace "$WS_GC"
expect_status 0 "gc: above-cap invocation succeeds"
if python3 - "$STORE_GC" "$ACTIVE_RUN" "${GC_RUNS[@]}" <<'PY'
import os, sys
store = sys.argv[1]
active = sys.argv[2]
runs = sys.argv[3:]
oldest = runs[:5]
newest20 = runs[-20:]
present = set(
    name[:-6]
    for name in os.listdir(os.path.join(store, "runs"))
    if name.endswith(".jsonl")
)
assert all(run_id not in present for run_id in oldest)
assert all(run_id in present for run_id in newest20)
assert active in present
tsv_ids = [
    line.split("\t")[1]
    for line in open(os.path.join(store, "runs.tsv"), encoding="utf-8")
    if line.strip()
]
assert set(tsv_ids) == present
PY
then
  pass "gc: above-cap deletes only unprotected oldest-generation-first; survivors and tsv match"
else
  fail "gc: above-cap deletes only unprotected oldest-generation-first; survivors and tsv match"
fi

# Confirm deleted generations are the five oldest and in generation order.
if python3 - "$TMP_ROOT/gc-above.stdout" "${GC_GENS[@]:0:5}" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
deleted_gens = []
for line in text:
    if line.startswith("deleted "):
        parts = dict(item.split("=", 1) for item in line.split()[1:] if "=" in item)
        deleted_gens.append(int(parts["generation"]))
expected = [int(value) for value in sys.argv[2:]]
if deleted_gens != expected:
    raise SystemExit(1)
PY
then
  pass "gc: deletions are oldest-generation-first"
else
  fail "gc: deletions are oldest-generation-first"
fi

WS_SOFT="$(workspace gc-soft)"
run_cmd gc-soft-begin "$RUN" begin --workspace "$WS_SOFT"
run_cmd gc-soft-pad "$JOURNAL" append --workspace "$WS_SOFT" --event checkpoint \
  --field note="$(python3 -c 'print("y"*4000)')"
STORE_SOFT="$(store_dir "$WS_SOFT")"
SEG_SOFT="$(find "$STORE_SOFT/runs" -name '*.jsonl' | head -n 1)"
run_cmd gc-soft env LOOP_JOURNAL_GC_CAP_BYTES=200 "$JOURNAL" gc --workspace "$WS_SOFT"
expect_status 0 "gc: protected-only overage stays exit 0"
expect_output stderr "soft-cap overage" "gc: protected-only overage reports soft-cap"
if [[ -f "$SEG_SOFT" ]]; then
  pass "gc: protected-only overage deletes nothing"
else
  fail "gc: protected-only overage deletes nothing"
fi

# --- 5. Context schema + lifecycle ---
WS_CTX="$(workspace ctx)"
run_cmd ctx-begin "$RUN" begin --workspace "$WS_CTX"
expect_status 0 "context: begin succeeds"
RUN_CTX="$(field_from "$CASE_STDOUT" run)"
GEN_CTX="$(field_from "$CASE_STDOUT" generation)"
STORE_CTX="$(store_dir "$WS_CTX")"
if python3 - "$STORE_CTX/context" "$WS_CTX" "$RUN_CTX" "$GEN_CTX" <<'PY'
import hashlib, json, os, sys
path, workspace, run, gen = sys.argv[1:]
obj = json.loads(open(path, encoding="utf-8").read())
canon = os.path.realpath(workspace)
key = hashlib.sha256(canon.encode("utf-8")).hexdigest()
assert obj["schema"] == 1
assert obj["workspace"] == canon
assert obj["workspace_key"] == key
assert obj["run"] == run
assert obj["generation"] == int(gen)
assert "created_at" in obj
PY
then
  pass "context: begin writes a valid schema-1 context"
else
  fail "context: begin writes a valid schema-1 context"
fi
run_cmd ctx-second "$RUN" begin --workspace "$WS_CTX"
expect_status 8 "context: second begin while fresh context exists refuses"
run_cmd ctx-end "$RUN" end --status completed --workspace "$WS_CTX"
expect_status 0 "context: end succeeds"
if [[ ! -e "$STORE_CTX/context" && -f "$STORE_CTX/context.retired-$RUN_CTX" ]]; then
  pass "context: run.end retires context atomically to context.retired-<run-id>"
else
  fail "context: run.end retires context atomically to context.retired-<run-id>"
fi

cp "$STORE_CTX/context.retired-$RUN_CTX" "$STORE_CTX/context"
chmod 600 "$STORE_CTX/context"
run_cmd ctx-stale-end "$JOURNAL" append --workspace "$WS_CTX" --event checkpoint --field note=stale-end
expect_status 0 "context: append against terminal-run context is unattributed (exit 0)"
expect_output stderr "context stale" "context: terminal run.end is detected as stale"
if python3 - "$STORE_CTX/unattributed.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert events[-1]["attribution_failure"] == "context stale"
assert "seq" not in events[-1]
PY
then
  pass "context: stale (terminal run.end) lands in unattributed.jsonl without seq"
else
  fail "context: stale (terminal run.end) lands in unattributed.jsonl without seq"
fi

WS_MISS="$(workspace ctx-missing-seg)"
run_cmd ctx-miss-begin "$RUN" begin --workspace "$WS_MISS"
RUN_MISS="$(field_from "$CASE_STDOUT" run)"
STORE_MISS="$(store_dir "$WS_MISS")"
rm -f "$STORE_MISS/runs/${RUN_MISS}.jsonl"
run_cmd ctx-miss-append "$JOURNAL" append --workspace "$WS_MISS" --event checkpoint --field note=missing-seg
expect_status 0 "context: missing segment is stale (exit 0)"
expect_output stderr "context stale" "context: missing segment is detected as stale"

# --- 6. Seven-case attribution ladder ---
WS_ATTR="$(workspace attr)"
run_cmd attr-begin "$RUN" begin --workspace "$WS_ATTR"
expect_status 0 "attribution/attributed: begin succeeds"
run_cmd attr-ok "$JOURNAL" append --workspace "$WS_ATTR" --event checkpoint --field note=attributed
expect_status 0 "attribution/attributed: append exits 0"
STORE_ATTR="$(store_dir "$WS_ATTR")"
RUN_ATTR="$(python3 - "$STORE_ATTR/context" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["run"])
PY
)"
if python3 - "$STORE_ATTR/runs/${RUN_ATTR}.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert events[-1]["event"] == "checkpoint"
assert events[-1]["note"] == "attributed"
assert events[-1]["seq"] == 2
assert "attribution_failure" not in events[-1]
PY
then
  pass "attribution/attributed: event lands on the active run with a seq"
else
  fail "attribution/attributed: event lands on the active run with a seq"
fi

WS_MISSING="$(workspace attr-missing)"
run_cmd attr-missing "$JOURNAL" append --workspace "$WS_MISSING" --event checkpoint --field note=no-context
expect_status 0 "attribution/context-missing: exit 0"
expect_output stderr "context missing" "attribution/context-missing: stderr names the reason"
STORE_MISSING="$(store_dir "$WS_MISSING")"
if python3 - "$STORE_MISSING/unattributed.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert events[-1]["attribution_failure"] == "context missing"
assert "seq" not in events[-1]
PY
then
  pass "attribution/context-missing: event written to unattributed.jsonl"
else
  fail "attribution/context-missing: event written to unattributed.jsonl"
fi

# Torn tail in unattributed.jsonl must not merge the next event onto it.
printf '%s' '{"partial"' >> "$STORE_MISSING/unattributed.jsonl"
run_cmd attr-missing-torn "$JOURNAL" append --workspace "$WS_MISSING" --event checkpoint --field note=after-torn
expect_status 0 "unattributed-torn: append after partial line succeeds"
if python3 - "$STORE_MISSING/unattributed.jsonl" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
lines = raw.split(b"\n")
if lines and lines[-1] == b"":
    lines = lines[:-1]
if len(lines) != 3:
    raise SystemExit(1)
if lines[1] != b'{"partial"':
    raise SystemExit(2)
first = json.loads(lines[0])
new = json.loads(lines[2])
if first.get("note") != "no-context":
    raise SystemExit(3)
if new.get("note") != "after-torn":
    raise SystemExit(4)
if new.get("attribution_failure") != "context missing":
    raise SystemExit(5)
if first.get("event") == "journal.repaired" or new.get("event") == "journal.repaired":
    raise SystemExit(6)
raise SystemExit(0)
PY
then
  pass "unattributed-torn: new event parses and partial line stays separate"
else
  fail "unattributed-torn: new event parses and partial line stays separate"
fi

# context stale is covered above; name it in the ladder too
pass "attribution/context-stale: covered by context lifecycle (terminal + missing segment)"

WS_MALFORMED="$(workspace attr-malformed)"
run_cmd attr-malformed-begin "$RUN" begin --workspace "$WS_MALFORMED"
STORE_MALFORMED="$(store_dir "$WS_MALFORMED")"
printf 'not-json\n' > "$STORE_MALFORMED/context"
chmod 600 "$STORE_MALFORMED/context"
run_cmd attr-malformed "$JOURNAL" append --workspace "$WS_MALFORMED" --event checkpoint --field note=bad-ctx
expect_status 0 "attribution/context-malformed: exit 0"
expect_output stderr "context malformed" "attribution/context-malformed: stderr names the reason"
printf 'also-not-json\n' > "$TMP_ROOT/override.ctx"
run_cmd attr-malformed-override env LOOP_CONTEXT="$TMP_ROOT/override.ctx" \
  "$JOURNAL" append --workspace "$WS_MALFORMED" --event checkpoint --field note=bad-override
expect_status 0 "attribution/context-malformed: invalid LOOP_CONTEXT is malformed, not ignored"
expect_output stderr "context malformed" "attribution/context-malformed: LOOP_CONTEXT override names malformed"

WS_WRONG_A="$(workspace attr-wrong-a)"
WS_WRONG_B="$(workspace attr-wrong-b)"
run_cmd attr-wrong-begin "$RUN" begin --workspace "$WS_WRONG_A"
STORE_WRONG_A="$(store_dir "$WS_WRONG_A")"
run_cmd attr-wrong env LOOP_CONTEXT="$STORE_WRONG_A/context" \
  "$JOURNAL" append --workspace "$WS_WRONG_B" --event checkpoint --field note=cross
expect_status 0 "attribution/wrong-workspace: exit 0"
expect_output stderr "wrong-workspace" "attribution/wrong-workspace: stderr names the reason"
STORE_WRONG_B="$(store_dir "$WS_WRONG_B")"
if python3 - "$STORE_WRONG_B/unattributed.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert events[-1]["attribution_failure"] == "wrong-workspace"
PY
then
  pass "attribution/wrong-workspace: event stays in the caller workspace unattributed store"
else
  fail "attribution/wrong-workspace: event stays in the caller workspace unattributed store"
fi

HELPER_MISSING="$TMP_ROOT/no-such-loop-journal"
HELPER_WRITER="$TMP_ROOT/adapter-writer.sh"
cat > "$HELPER_WRITER" <<'EOF'
#!/usr/bin/env bash
set -u
helper=$1
shift
if [[ ! -x "$helper" ]]; then
  exit 0
fi
exec "$helper" "$@"
EOF
chmod 755 "$HELPER_WRITER"
run_cmd attr-helper-missing "$HELPER_WRITER" "$HELPER_MISSING" append \
  --workspace "$WS_ATTR" --event checkpoint --field note=should-not-write
expect_status 0 "attribution/helper-missing: writer is a silent no-op"
if python3 - "$STORE_ATTR/runs/${RUN_ATTR}.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert all(event.get("note") != "should-not-write" for event in events)
PY
then
  pass "attribution/helper-missing: no journal event is written"
else
  fail "attribution/helper-missing: no journal event is written"
fi

HELPER_FAIL="$TMP_ROOT/failing-loop-journal"
cat > "$HELPER_FAIL" <<'EOF'
#!/usr/bin/env bash
printf 'error: helper present but failing\n' >&2
exit 5
EOF
chmod 755 "$HELPER_FAIL"
run_cmd attr-helper-fail "$HELPER_WRITER" "$HELPER_FAIL" append \
  --workspace "$WS_ATTR" --event checkpoint --field note=fail-path
expect_status 5 "attribution/helper-failing: caller sees the helper's nonzero exit"
expect_output stderr "helper present but failing" "attribution/helper-failing: caller surfaces helper stderr"

# --- 7. A/B same-HOME isolation ---
WS_A="$(workspace ab-a)"
WS_B="$(workspace ab-b)"
run_cmd ab-begin-a "$RUN" begin --workspace "$WS_A"
RUN_A="$(field_from "$CASE_STDOUT" run)"
KEY_A="$(field_from "$CASE_STDOUT" workspace_key)"
run_cmd ab-begin-b "$RUN" begin --workspace "$WS_B"
RUN_B="$(field_from "$CASE_STDOUT" run)"
KEY_B="$(field_from "$CASE_STDOUT" workspace_key)"
run_cmd ab-append-a "$JOURNAL" append --workspace "$WS_A" --event checkpoint --field note=from-a
run_cmd ab-append-b "$JOURNAL" append --workspace "$WS_B" --event checkpoint --field note=from-b
STORE_A="$(store_dir "$WS_A")"
STORE_B="$(store_dir "$WS_B")"
if [[ "$KEY_A" != "$KEY_B" && "$STORE_A" != "$STORE_B" ]]; then
  pass "isolation: same HOME yields distinct workspace_keys and stores"
else
  fail "isolation: same HOME yields distinct workspace_keys and stores"
fi
if python3 - "$STORE_A" "$STORE_B" "$RUN_A" "$RUN_B" <<'PY'
import json, os, sys
store_a, store_b, run_a, run_b = sys.argv[1:]
events_a = [json.loads(line) for line in open(os.path.join(store_a, "runs", run_a + ".jsonl"), encoding="utf-8")]
events_b = [json.loads(line) for line in open(os.path.join(store_b, "runs", run_b + ".jsonl"), encoding="utf-8")]
notes_a = [event.get("note") for event in events_a]
notes_b = [event.get("note") for event in events_b]
assert "from-a" in notes_a and "from-b" not in notes_a
assert "from-b" in notes_b and "from-a" not in notes_b
ctx_a = json.load(open(os.path.join(store_a, "context"), encoding="utf-8"))
ctx_b = json.load(open(os.path.join(store_b, "context"), encoding="utf-8"))
assert ctx_a["run"] == run_a and ctx_b["run"] == run_b
assert ctx_a["workspace_key"] != ctx_b["workspace_key"]
PY
then
  pass "isolation: appends and contexts stay in disjoint stores"
else
  fail "isolation: appends and contexts stay in disjoint stores"
fi

# --- 8. Recover ---
run_cmd recover-help "$RUN" recover --help
expect_status 0 "recover: --help exits 0"
expect_output stdout "$D2A" "recover: help contains the verbatim D2A sentence"
run_cmd journal-recover-help "$JOURNAL" recover --help
expect_status 0 "recover: loop-journal recover --help exits 0"
expect_output stdout "$D2A" "recover: loop-journal recover --help contains the verbatim D2A sentence"

WS_REC="$(workspace recover)"
run_cmd rec-begin "$RUN" begin --workspace "$WS_REC"
RUN_REC="$(field_from "$CASE_STDOUT" run)"
STORE_REC="$(store_dir "$WS_REC")"
run_cmd rec-start "$JOURNAL" append --workspace "$WS_REC" --event dispatch.start \
  --field dispatch_id=disp-open --field backend=codex --field mode=implement
expect_status 0 "recover: dispatch.start appends"
run_cmd rec-refuse "$RUN" recover --workspace "$WS_REC"
expect_status 7 "recover: unmatched start refuses (exit 7)"
expect_output stderr "$D2A" "recover: refusal diagnostic contains the verbatim D2A sentence"
expect_output stderr "disp-open" "recover: refusal lists the unmatched dispatch_id"
if [[ -f "$STORE_REC/context" ]]; then
  pass "recover: refusal leaves the context in place"
else
  fail "recover: refusal leaves the context in place"
fi

run_cmd rec-end-start "$JOURNAL" append --workspace "$WS_REC" --event dispatch.end \
  --field dispatch_id=disp-open --field exit=0
expect_status 0 "recover: matching dispatch.end appends"
run_cmd rec-success "$RUN" recover --workspace "$WS_REC"
expect_status 0 "recover: success when every start is matched"
if [[ ! -e "$STORE_REC/context" && -f "$STORE_REC/context.retired-$RUN_REC" ]]; then
  pass "recover: success retires the context"
else
  fail "recover: success retires the context"
fi
if python3 - "$STORE_REC/runs/${RUN_REC}.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
kinds = [event["event"] for event in events]
assert kinds[-1] == "run.end"
assert events[-1]["status"] == "abandoned"
assert "dispatch.end" in kinds
PY
then
  pass "recover: matched path appends run.end(status=abandoned)"
else
  fail "recover: matched path appends run.end(status=abandoned)"
fi

WS_ACK="$(workspace recover-ack)"
run_cmd ack-begin "$RUN" begin --workspace "$WS_ACK"
RUN_ACK="$(field_from "$CASE_STDOUT" run)"
STORE_ACK="$(store_dir "$WS_ACK")"
run_cmd ack-start "$JOURNAL" append --workspace "$WS_ACK" --event dispatch.start \
  --field dispatch_id=disp-ack --field backend=grok --field mode=read-only
run_cmd ack-recover "$RUN" recover --workspace "$WS_ACK" --acknowledge disp-ack
expect_status 0 "recover: --acknowledge path succeeds"
if [[ ! -e "$STORE_ACK/context" && -f "$STORE_ACK/context.retired-$RUN_ACK" ]]; then
  pass "recover: acknowledge retires the context together with attestation"
else
  fail "recover: acknowledge retires the context together with attestation"
fi
if python3 - "$STORE_ACK/runs/${RUN_ACK}.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
kinds = [event["event"] for event in events]
assert "dispatch.abandoned" in kinds
assert kinds.index("dispatch.abandoned") < kinds.index("run.end")
abandoned = [event for event in events if event["event"] == "dispatch.abandoned"]
assert abandoned[-1]["attested_by"] == "user"
assert abandoned[-1]["dispatch_id"] == "disp-ack"
assert events[-1]["event"] == "run.end"
assert events[-1]["status"] == "abandoned"
assert all(event["event"] != "dispatch.end" for event in events)
PY
then
  pass "recover: acknowledge appends dispatch.abandoned(attested_by=user) then run.end(abandoned)"
else
  fail "recover: acknowledge appends dispatch.abandoned(attested_by=user) then run.end(abandoned)"
fi

if python3 - "$HOME/.config/olddonkey-loop/journal" <<'PY'
import json, os, sys
root = sys.argv[1]
for dirpath, _, files in os.walk(root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(dirpath, name)
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") == "dispatch.end" and event.get("dispatch_id") in {
                "disp-ack",
                "disp-kill",
                "disp-end-fail",
            }:
                raise SystemExit(1)
# recover invocations under test must not mint synthetic dispatch.end for
# acknowledge / kill / end-writer cases. The matched-success case above
# wrote a real dispatch.end (disp-open) on purpose.
raise SystemExit(0)
PY
then
  pass "recover: no synthetic dispatch.end for acknowledge-only recoveries"
else
  fail "recover: no synthetic dispatch.end for acknowledge-only recoveries"
fi

# --- 9. End-writer failure ---
WS_ENDFAIL="$(workspace end-fail)"
run_cmd endfail-begin "$RUN" begin --workspace "$WS_ENDFAIL"
run_cmd endfail-start "$JOURNAL" append --workspace "$WS_ENDFAIL" --event dispatch.start \
  --field dispatch_id=disp-end-fail --field backend=cursor --field mode=implement
expect_status 0 "end-writer: dispatch.start lands"
run_cmd endfail-end "$HELPER_WRITER" "$HELPER_FAIL" append --workspace "$WS_ENDFAIL" \
  --event dispatch.end --field dispatch_id=disp-end-fail --field exit=0
expect_status 5 "end-writer: failing helper does not write dispatch.end"
run_cmd endfail-recover "$RUN" recover --workspace "$WS_ENDFAIL"
expect_status 7 "end-writer: recover refuses while the dispatch is still open"
expect_output stderr "disp-end-fail" "end-writer: refusal names the open dispatch"
run_cmd endfail-ack "$RUN" recover --workspace "$WS_ENDFAIL" --acknowledge disp-end-fail
expect_status 0 "end-writer: recover proceeds after acknowledge"

# --- 10. Adapter SIGKILL ---
WS_KILL="$(workspace sigkill)"
run_cmd kill-begin "$RUN" begin --workspace "$WS_KILL"
ADAPTER="$TMP_ROOT/adapter.sh"
MARKER="$TMP_ROOT/adapter.started"
cat > "$ADAPTER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
journal=$1
workspace=$2
dispatch_id=$3
marker=$4
"$journal" append --workspace "$workspace" --event dispatch.start \
  --field dispatch_id="$dispatch_id" --field backend=codex --field mode=implement
printf 'started\n' > "$marker"
sleep 60
"$journal" append --workspace "$workspace" --event dispatch.end \
  --field dispatch_id="$dispatch_id" --field exit=0
EOF
chmod 755 "$ADAPTER"
"$ADAPTER" "$JOURNAL" "$WS_KILL" disp-kill "$MARKER" >/dev/null 2>&1 &
ADAPTER_PID=$!
for _ in $(seq 1 50); do
  [[ -f "$MARKER" ]] && break
  sleep 0.05
done
if [[ -f "$MARKER" ]]; then
  pass "sigkill: fixture adapter wrote dispatch.start"
else
  fail "sigkill: fixture adapter wrote dispatch.start"
fi
kill -KILL "$ADAPTER_PID" 2>/dev/null || true
wait "$ADAPTER_PID" 2>/dev/null || true
ADAPTER_PID=""
run_cmd kill-recover "$RUN" recover --workspace "$WS_KILL"
expect_status 7 "sigkill: recover refuses after adapter SIGKILL"
expect_output stderr "disp-kill" "sigkill: refusal lists the unmatched dispatch_id"
run_cmd kill-ack "$RUN" recover --workspace "$WS_KILL" --acknowledge disp-kill
expect_status 0 "sigkill: acknowledge after SIGKILL proceeds"
if python3 - "$(store_dir "$WS_KILL")" <<'PY'
import json, os, sys
store = sys.argv[1]
found_end = False
found_abandoned = False
for dirpath, _, files in os.walk(store):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        for line in open(os.path.join(dirpath, name), encoding="utf-8"):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") == "dispatch.end" and event.get("dispatch_id") == "disp-kill":
                found_end = True
            if event.get("event") == "dispatch.abandoned" and event.get("dispatch_id") == "disp-kill":
                found_abandoned = True
if found_end or not found_abandoned:
    raise SystemExit(1)
PY
then
  pass "sigkill: store has dispatch.abandoned and no synthetic dispatch.end"
else
  fail "sigkill: store has dispatch.abandoned and no synthetic dispatch.end"
fi

# Extra coverage used by later writers: unit/round/review/publish round-trip
WS_EXTRA="$(workspace extra)"
run_cmd extra-begin "$RUN" begin --workspace "$WS_EXTRA"
run_cmd extra-unit "$RUN" unit-begin --unit u1 --workspace "$WS_EXTRA"
expect_status 0 "loop-run: unit-begin"
run_cmd extra-round "$RUN" round-begin --unit u1 --round 1 --workspace "$WS_EXTRA"
expect_status 0 "loop-run: round-begin"
run_cmd extra-review "$RUN" review --unit u1 --round 1 --verdict iterate --findings refs/f1 --workspace "$WS_EXTRA"
expect_status 0 "loop-run: review"
run_cmd extra-pub "$RUN" publish --unit u1 --branch topic --pr https://example.invalid/p/1 --sha abc --note shipped --workspace "$WS_EXTRA"
expect_status 0 "loop-run: publish"
run_cmd extra-unit-end "$RUN" unit-end --unit u1 --status parked --workspace "$WS_EXTRA"
expect_status 0 "loop-run: unit-end"
run_cmd extra-check "$RUN" checkpoint --note pause --workspace "$WS_EXTRA"
expect_status 0 "loop-run: checkpoint"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
