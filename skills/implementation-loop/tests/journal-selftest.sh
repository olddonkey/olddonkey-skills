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
# A caller's declared attribution must not leak into fixture events.
unset LOOP_UNIT LOOP_ROUND

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

file_sums() { # remaining=paths; one sha256 (or "missing") per path
  python3 - "$@" <<'PY'
import hashlib, sys
for path in sys.argv[1:]:
    try:
        print(hashlib.sha256(open(path, "rb").read()).hexdigest())
    except FileNotFoundError:
        print("missing")
PY
}

# Every event of $2 in segment $1 must carry exactly the given label; "-"
# means the key must be absent.
expect_labels() { # $1=segment $2=event $3=unit $4=round $5=description
  if python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, kind, unit, round_n = sys.argv[1:]
events = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
matching = [event for event in events if event.get("event") == kind]
if not matching:
    raise SystemExit(f"no {kind} event")
for event in matching:
    if unit == "-":
        if "unit" in event:
            raise SystemExit(f"unexpected unit {event}")
    elif event.get("unit") != unit:
        raise SystemExit(f"unit {event}")
    if round_n == "-":
        if "round" in event:
            raise SystemExit(f"unexpected round {event}")
    elif type(event.get("round")) is not int or event["round"] != int(round_n):
        raise SystemExit(f"round {event}")
PY
  then
    pass "$5"
  else
    fail "$5"
  fi
}

D2A='Supplying --acknowledge <dispatch-id> asserts that the dispatch and its descendants have terminated or otherwise cannot produce further side effects. Mere notice that the event is missing is insufficient and must not retire the run.'

# Backend enum accepts Claude and still rejects an unregistered name.
WS_BACKEND="$(workspace backend-enum)"
run_cmd backend-begin "$RUN" begin --workspace "$WS_BACKEND"
expect_status 0 "backend enum: begin succeeds"
run_cmd backend-claude "$JOURNAL" append --workspace "$WS_BACKEND" --event dispatch.start \
  --field dispatch_id=d-claude --field backend=claude --field mode=implement
expect_status 0 "backend enum: claude dispatch.start accepted"
run_cmd backend-unknown "$JOURNAL" append --workspace "$WS_BACKEND" --event dispatch.start \
  --field dispatch_id=d-nonesuch --field backend=nonesuch --field mode=implement
expect_status 2 "backend enum: unknown dispatch.start rejected"

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

# --- 11. gate.result verdict fields ---
WS_GATE="$(workspace gate-result)"
run_cmd gate-begin "$RUN" begin --workspace "$WS_GATE"
RUN_GATE="$(field_from "$CASE_STDOUT" run)"
GATE_FIELDS=(--field policy=strict --field purpose=unit-final --field binding=clean
  --field totals=exit=0)
run_cmd gate-green "$JOURNAL" append --workspace "$WS_GATE" --event gate.result \
  "${GATE_FIELDS[@]}" --field verdict=green --field gate_exit=0
expect_status 0 "gate.result: verdict=green gate_exit=0 is accepted"
run_cmd gate-bad-verdict "$JOURNAL" append --workspace "$WS_GATE" --event gate.result \
  "${GATE_FIELDS[@]}" --field verdict=maybe --field gate_exit=0
expect_status 2 "gate.result: verdict=maybe is rejected (exit 2)"
expect_output stderr "invalid verdict: maybe" "gate.result: verdict rejection names the value"
run_cmd gate-bad-exit "$JOURNAL" append --workspace "$WS_GATE" --event gate.result \
  "${GATE_FIELDS[@]}" --field verdict=red --field gate_exit=abc
expect_status 2 "gate.result: gate_exit=abc is rejected (exit 2)"
expect_output stderr "gate_exit must be an int" "gate.result: gate_exit rejection names the field"
run_cmd gate-unknown-key "$JOURNAL" append --workspace "$WS_GATE" --event gate.result \
  "${GATE_FIELDS[@]}" --field verdict=green --field gate_exit=0 --field outcome=green
expect_status 2 "gate.result: an unknown key is still rejected (exit 2)"
expect_output stderr "unknown payload key(s): outcome" "gate.result: unknown-key rejection names the key"
if python3 - "$(store_dir "$WS_GATE")/runs/${RUN_GATE}.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
gates = [event for event in events if event["event"] == "gate.result"]
assert len(gates) == 1, gates
assert gates[0]["verdict"] == "green"
assert type(gates[0]["gate_exit"]) is int and gates[0]["gate_exit"] == 0
assert gates[0]["totals"] == "exit=0"
PY
then
  pass "gate.result: only the valid append lands, with gate_exit stored as an int"
else
  fail "gate.result: only the valid append lands, with gate_exit stored as an int"
fi

# --- 12. Declared attribution from LOOP_UNIT / LOOP_ROUND ---
WS_ENV="$(workspace attr-env)"
run_cmd env-begin "$RUN" begin --workspace "$WS_ENV"
RUN_ENV="$(field_from "$CASE_STDOUT" run)"
SEG_ENV="$(store_dir "$WS_ENV")/runs/${RUN_ENV}.jsonl"
ENV_STATUSES=""
run_cmd env-start env LOOP_UNIT=uX LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_ENV" \
  --event dispatch.start --field dispatch_id=d-env --field backend=codex --field mode=implement
ENV_STATUSES+="$CASE_STATUS"
run_cmd env-end env LOOP_UNIT=uX LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_ENV" \
  --event dispatch.end --field dispatch_id=d-env --field exit=0
ENV_STATUSES+="$CASE_STATUS"
run_cmd env-abandoned env LOOP_UNIT=uX LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_ENV" \
  --event dispatch.abandoned --field dispatch_id=d-env-2 --field attested_by=user
ENV_STATUSES+="$CASE_STATUS"
run_cmd env-gate env LOOP_UNIT=uX LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_ENV" \
  --event gate.result "${GATE_FIELDS[@]}" --field verdict=green --field gate_exit=0
ENV_STATUSES+="$CASE_STATUS"
if [[ "$ENV_STATUSES" == 0000 ]]; then
  pass "attribution/env: the four attributed events append with LOOP_UNIT/LOOP_ROUND set"
else
  fail "attribution/env: the four attributed events append with LOOP_UNIT/LOOP_ROUND set (statuses $ENV_STATUSES)"
fi
expect_labels "$SEG_ENV" dispatch.start uX 2 "attribution/env: dispatch.start carries unit=uX round=2"
expect_labels "$SEG_ENV" dispatch.end uX 2 "attribution/env: dispatch.end carries unit=uX round=2"
expect_labels "$SEG_ENV" dispatch.abandoned uX 2 "attribution/env: dispatch.abandoned carries unit=uX round=2"
expect_labels "$SEG_ENV" gate.result uX 2 "attribution/env: gate.result carries unit=uX round=2"

WS_EXPL="$(workspace attr-explicit)"
run_cmd expl-begin "$RUN" begin --workspace "$WS_EXPL"
RUN_EXPL="$(field_from "$CASE_STDOUT" run)"
SEG_EXPL="$(store_dir "$WS_EXPL")/runs/${RUN_EXPL}.jsonl"
run_cmd expl-start env LOOP_UNIT=env-unit LOOP_ROUND=3 "$JOURNAL" append --workspace "$WS_EXPL" \
  --event dispatch.start --field dispatch_id=d-expl --field backend=grok --field mode=read-only \
  --field unit=explicit --field round=5
expect_status 0 "attribution/explicit: --field unit/round on dispatch.start is accepted"
expect_labels "$SEG_EXPL" dispatch.start explicit 5 "attribution/explicit: --field values win over both variables"
run_cmd expl-end env LOOP_UNIT=env-unit LOOP_ROUND=3 "$JOURNAL" append --workspace "$WS_EXPL" \
  --event dispatch.end --json '{"dispatch_id":"d-expl","exit":0,"unit":"explicit"}'
expect_status 0 "attribution/explicit: --json unit on dispatch.end is accepted"
expect_labels "$SEG_EXPL" dispatch.end explicit 3 \
  "attribution/explicit: an explicit unit wins while the absent round still comes from LOOP_ROUND"
run_cmd expl-gate env LOOP_UNIT=env-unit LOOP_ROUND=3 "$JOURNAL" append --workspace "$WS_EXPL" \
  --event gate.result "${GATE_FIELDS[@]}" --field round=7
expect_status 0 "attribution/explicit: --field round on gate.result is accepted"
expect_labels "$SEG_EXPL" gate.result env-unit 7 \
  "attribution/explicit: an explicit round wins while the absent unit still comes from LOOP_UNIT"

WS_OTHER="$(workspace attr-other)"
run_cmd other-begin "$RUN" begin --workspace "$WS_OTHER"
RUN_OTHER="$(field_from "$CASE_STDOUT" run)"
SEG_OTHER="$(store_dir "$WS_OTHER")/runs/${RUN_OTHER}.jsonl"
OTHER_STATUSES=""
run_cmd other-check env LOOP_UNIT=env-unit LOOP_ROUND=9 "$JOURNAL" append --workspace "$WS_OTHER" \
  --event checkpoint --field note=ignores-env
OTHER_STATUSES+="$CASE_STATUS"
run_cmd other-unit env LOOP_UNIT=env-unit LOOP_ROUND=9 "$RUN" unit-begin --unit u1 --workspace "$WS_OTHER"
OTHER_STATUSES+="$CASE_STATUS"
run_cmd other-round env LOOP_UNIT=env-unit LOOP_ROUND=9 "$RUN" round-begin --unit u1 --round 1 --workspace "$WS_OTHER"
OTHER_STATUSES+="$CASE_STATUS"
run_cmd other-review env LOOP_UNIT=env-unit LOOP_ROUND=9 "$RUN" review --unit u1 --round 1 \
  --verdict pass --workspace "$WS_OTHER"
OTHER_STATUSES+="$CASE_STATUS"
run_cmd other-publish env LOOP_UNIT=env-unit LOOP_ROUND=9 "$RUN" publish --unit u1 --workspace "$WS_OTHER"
OTHER_STATUSES+="$CASE_STATUS"
run_cmd other-invalid env LOOP_UNIT= LOOP_ROUND=abc "$RUN" unit-end --unit u1 --status done --workspace "$WS_OTHER"
OTHER_STATUSES+="$CASE_STATUS"
if [[ "$OTHER_STATUSES" == 000000 ]]; then
  pass "attribution/other-events: appends succeed and invalid variables are ignored"
else
  fail "attribution/other-events: appends succeed and invalid variables are ignored (statuses $OTHER_STATUSES)"
fi
if python3 - "$SEG_OTHER" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
by_kind = {event["event"]: event for event in events}
assert "unit" not in by_kind["checkpoint"] and "round" not in by_kind["checkpoint"], by_kind["checkpoint"]
assert by_kind["unit.begin"]["unit"] == "u1" and "round" not in by_kind["unit.begin"]
assert by_kind["round.begin"]["unit"] == "u1" and by_kind["round.begin"]["round"] == 1
assert by_kind["review.recorded"]["unit"] == "u1" and by_kind["review.recorded"]["round"] == 1
assert by_kind["publish.recorded"]["unit"] == "u1" and "round" not in by_kind["publish.recorded"]
assert by_kind["unit.end"]["unit"] == "u1" and "round" not in by_kind["unit.end"]
assert all("env-unit" not in json.dumps(event) for event in events)
PY
then
  pass "attribution/other-events: no other event reads LOOP_UNIT or LOOP_ROUND"
else
  fail "attribution/other-events: no other event reads LOOP_UNIT or LOOP_ROUND"
fi

WS_BADENV="$(workspace attr-invalid)"
run_cmd badenv-begin "$RUN" begin --workspace "$WS_BADENV"
RUN_BADENV="$(field_from "$CASE_STDOUT" run)"
SEG_BADENV="$(store_dir "$WS_BADENV")/runs/${RUN_BADENV}.jsonl"
SUM_BADENV_BEFORE="$(file_sums "$SEG_BADENV")"
BAD_START=(--event dispatch.start --field dispatch_id=d-bad --field backend=cursor --field mode=implement)
run_cmd badenv-unit-empty env LOOP_UNIT= "$JOURNAL" append --workspace "$WS_BADENV" "${BAD_START[@]}"
expect_status 2 "attribution/invalid: empty LOOP_UNIT exits 2"
expect_output stderr "LOOP_UNIT must be a non-empty single-line string" \
  "attribution/invalid: empty LOOP_UNIT names the variable"
run_cmd badenv-unit-newline env "LOOP_UNIT=u1"$'\n'"u2" "$JOURNAL" append --workspace "$WS_BADENV" "${BAD_START[@]}"
expect_status 2 "attribution/invalid: LOOP_UNIT with a newline exits 2"
run_cmd badenv-unit-cr env "LOOP_UNIT=u1"$'\r' "$JOURNAL" append --workspace "$WS_BADENV" "${BAD_START[@]}"
expect_status 2 "attribution/invalid: LOOP_UNIT with a carriage return exits 2"
BAD_ROUND_CASE=0
for BAD_ROUND in 0 -1 abc 1.5 " 2" ""; do
  BAD_ROUND_CASE=$((BAD_ROUND_CASE + 1))
  run_cmd "badenv-round-$BAD_ROUND_CASE" env "LOOP_ROUND=$BAD_ROUND" "$JOURNAL" append \
    --workspace "$WS_BADENV" "${BAD_START[@]}"
  expect_status 2 "attribution/invalid: LOOP_ROUND='$BAD_ROUND' exits 2"
done
expect_output stderr "LOOP_ROUND must be a positive integer" \
  "attribution/invalid: an invalid LOOP_ROUND names the variable"
run_cmd badenv-gate env LOOP_ROUND=0 "$JOURNAL" append --workspace "$WS_BADENV" \
  --event gate.result "${GATE_FIELDS[@]}"
expect_status 2 "attribution/invalid: gate.result with LOOP_ROUND=0 exits 2"
run_cmd badenv-end env LOOP_UNIT= "$JOURNAL" append --workspace "$WS_BADENV" \
  --event dispatch.end --field dispatch_id=d-bad --field exit=0
expect_status 2 "attribution/invalid: dispatch.end with an empty LOOP_UNIT exits 2"
run_cmd badenv-explicit-empty "$JOURNAL" append --workspace "$WS_BADENV" \
  --event dispatch.abandoned --field dispatch_id=d-bad --field attested_by=user --field unit=
expect_status 2 "attribution/invalid: an explicit empty unit exits 2"
run_cmd badenv-explicit-round "$JOURNAL" append --workspace "$WS_BADENV" \
  --event dispatch.start --field dispatch_id=d-bad --field backend=cursor --field mode=implement \
  --field round=0
expect_status 2 "attribution/invalid: an explicit round=0 exits 2"
if [[ "$(file_sums "$SEG_BADENV")" == "$SUM_BADENV_BEFORE" ]]; then
  pass "attribution/invalid: no refused append reached the segment"
else
  fail "attribution/invalid: no refused append reached the segment"
fi
WS_BADENV_NOCTX="$(workspace attr-invalid-noctx)"
run_cmd badenv-noctx env LOOP_UNIT= "$JOURNAL" append --workspace "$WS_BADENV_NOCTX" "${BAD_START[@]}"
expect_status 2 "attribution/invalid: an invalid variable exits 2 even without a context"
if [[ ! -e "$(store_dir "$WS_BADENV_NOCTX")/unattributed.jsonl" ]]; then
  pass "attribution/invalid: the refused event is not written to unattributed.jsonl"
else
  fail "attribution/invalid: the refused event is not written to unattributed.jsonl"
fi

run_cmd attr-unknown-key env LOOP_UNIT=uX LOOP_ROUND=2 "$JOURNAL" append --workspace "$WS_BADENV" \
  "${BAD_START[@]}" --field outcome=green
expect_status 2 "attribution/unknown-key: an unknown key still exits 2 with the variables set"
expect_output stderr "unknown payload key(s): outcome" \
  "attribution/unknown-key: the rejection names the key"
run_cmd attr-unit-on-checkpoint "$JOURNAL" append --workspace "$WS_BADENV" \
  --event checkpoint --field unit=u1
expect_status 2 "attribution/unknown-key: unit is still unknown on events outside the four"
expect_output stderr "unknown payload key(s): unit" \
  "attribution/unknown-key: checkpoint rejection names unit"

# --- 13. Recover: declared attribution and duplicate dispatch ids ---
WS_RCOPY="$(workspace recover-copy)"
run_cmd rcopy-begin "$RUN" begin --workspace "$WS_RCOPY"
RUN_RCOPY="$(field_from "$CASE_STDOUT" run)"
SEG_RCOPY="$(store_dir "$WS_RCOPY")/runs/${RUN_RCOPY}.jsonl"
run_cmd rcopy-labelled env LOOP_UNIT=u-rec LOOP_ROUND=4 "$JOURNAL" append --workspace "$WS_RCOPY" \
  --event dispatch.start --field dispatch_id=d-labelled --field backend=codex --field mode=implement
run_cmd rcopy-plain "$JOURNAL" append --workspace "$WS_RCOPY" \
  --event dispatch.start --field dispatch_id=d-plain --field backend=grok --field mode=implement
run_cmd rcopy-recover env -u LOOP_UNIT -u LOOP_ROUND "$RUN" recover --workspace "$WS_RCOPY" \
  --acknowledge d-labelled --acknowledge d-plain
expect_status 0 "recover/attribution: acknowledge succeeds with no LOOP_UNIT/LOOP_ROUND set"
if python3 - "$SEG_RCOPY" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
abandoned = {e["dispatch_id"]: e for e in events if e["event"] == "dispatch.abandoned"}
assert abandoned["d-labelled"]["unit"] == "u-rec", abandoned
assert type(abandoned["d-labelled"]["round"]) is int and abandoned["d-labelled"]["round"] == 4
assert abandoned["d-labelled"]["attested_by"] == "user"
assert "unit" not in abandoned["d-plain"] and "round" not in abandoned["d-plain"], abandoned
PY
then
  pass "recover/attribution: abandonment copies the start's unit/round, and writes neither when it had none"
else
  fail "recover/attribution: abandonment copies the start's unit/round, and writes neither when it had none"
fi

WS_RDECOY="$(workspace recover-decoy)"
run_cmd rdecoy-begin "$RUN" begin --workspace "$WS_RDECOY"
RUN_RDECOY="$(field_from "$CASE_STDOUT" run)"
SEG_RDECOY="$(store_dir "$WS_RDECOY")/runs/${RUN_RDECOY}.jsonl"
run_cmd rdecoy-start "$JOURNAL" append --workspace "$WS_RDECOY" \
  --event dispatch.start --field dispatch_id=d-plain --field backend=cursor --field mode=implement
run_cmd rdecoy-recover env LOOP_UNIT=decoy LOOP_ROUND=9 "$RUN" recover --workspace "$WS_RDECOY" \
  --acknowledge d-plain
expect_status 0 "recover/attribution: acknowledge succeeds with decoy variables set"
expect_labels "$SEG_RDECOY" dispatch.abandoned - - \
  "recover/attribution: recovery never reads LOOP_UNIT/LOOP_ROUND"

# Each fixture ends with a torn tail, so a refusal that repaired, appended, or
# retired anything would change a checksum.
expect_recover_refused() { # $1=name $2=workspace $3=dispatch id
  local name="$1" ws="$2" did="$3" store run seg before after
  store="$(store_dir "$ws")"
  run="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["run"])' "$store/context")"
  seg="$store/runs/${run}.jsonl"
  printf '%s' '{"torn"' >> "$seg"
  before="$(file_sums "$seg" "$store/context" "$store/context.retired-$run")"
  run_cmd "$name-plain" "$RUN" recover --workspace "$ws"
  expect_status 2 "recover/$name: refused with exit 2 without --acknowledge"
  expect_output stderr "more than one dispatch.start or more than one dispatch.end/dispatch.abandoned: $did" \
    "recover/$name: refusal without --acknowledge names the duplicated id"
  run_cmd "$name-ack" "$RUN" recover --workspace "$ws" --acknowledge "$did"
  expect_status 2 "recover/$name: refused with exit 2 with --acknowledge"
  expect_output stderr "more than one dispatch.start or more than one dispatch.end/dispatch.abandoned: $did" \
    "recover/$name: refusal with --acknowledge names the duplicated id"
  after="$(file_sums "$seg" "$store/context" "$store/context.retired-$run")"
  if [[ "$before" == "$after" ]]; then
    pass "recover/$name: segment and context byte-identical; context not retired"
  else
    fail "recover/$name: segment and context byte-identical; context not retired"
  fi
}

dup_start() { # $1=workspace, remaining=env arguments
  local ws="$1"
  shift
  run_cmd dup-start env "$@" "$JOURNAL" append --workspace "$ws" \
    --event dispatch.start --field dispatch_id=d-dup --field backend=codex --field mode=implement
}

WS_DUP1="$(workspace dup-starts-equal)"
run_cmd dup1-begin "$RUN" begin --workspace "$WS_DUP1"
dup_start "$WS_DUP1" LOOP_UNIT=u1 LOOP_ROUND=1
dup_start "$WS_DUP1" LOOP_UNIT=u1 LOOP_ROUND=1
expect_recover_refused dup-starts-equal "$WS_DUP1" d-dup

WS_DUP2="$(workspace dup-starts-conflict)"
run_cmd dup2-begin "$RUN" begin --workspace "$WS_DUP2"
dup_start "$WS_DUP2" LOOP_UNIT=u1 LOOP_ROUND=1
dup_start "$WS_DUP2" LOOP_UNIT=u2 LOOP_ROUND=1
expect_recover_refused dup-starts-conflict "$WS_DUP2" d-dup

WS_DUP3="$(workspace dup-starts-one-end)"
run_cmd dup3-begin "$RUN" begin --workspace "$WS_DUP3"
dup_start "$WS_DUP3"
dup_start "$WS_DUP3"
run_cmd dup3-end "$JOURNAL" append --workspace "$WS_DUP3" \
  --event dispatch.end --field dispatch_id=d-dup --field exit=0
expect_recover_refused dup-starts-one-end "$WS_DUP3" d-dup

WS_DUP4="$(workspace dup-ends)"
run_cmd dup4-begin "$RUN" begin --workspace "$WS_DUP4"
dup_start "$WS_DUP4"
run_cmd dup4-end-a "$JOURNAL" append --workspace "$WS_DUP4" \
  --event dispatch.end --field dispatch_id=d-dup --field exit=0
run_cmd dup4-end-b "$JOURNAL" append --workspace "$WS_DUP4" \
  --event dispatch.end --field dispatch_id=d-dup --field exit=1
expect_recover_refused dup-ends "$WS_DUP4" d-dup

WS_DUP5="$(workspace dup-end-abandoned)"
run_cmd dup5-begin "$RUN" begin --workspace "$WS_DUP5"
dup_start "$WS_DUP5"
run_cmd dup5-end "$JOURNAL" append --workspace "$WS_DUP5" \
  --event dispatch.end --field dispatch_id=d-dup --field exit=0
run_cmd dup5-abandoned "$JOURNAL" append --workspace "$WS_DUP5" \
  --event dispatch.abandoned --field dispatch_id=d-dup --field attested_by=user
expect_recover_refused dup-end-abandoned "$WS_DUP5" d-dup

# --- Exact read interface and reviewer field ---
store_snapshot() { # $1=store; path and SHA-256 of every file
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for parent, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(parent, name)
        rel = os.path.relpath(path, root)
        print(rel, hashlib.sha256(open(path, "rb").read()).hexdigest())
PY
}

WS_READ="$(workspace read-interface)"
STORE_READ="$(store_dir "$WS_READ")"
ABSENT_RUN="20200101T000000Z-abcdef"
run_cmd reader-no-store "$JOURNAL" read-run --workspace "$WS_READ" --run "$ABSENT_RUN"
expect_status 2 "read-run: no store exits 2"
if [[ ! -s "$CASE_STDOUT" && ! -e "$STORE_READ" ]]; then
  pass "read-run: no store prints nothing and creates nothing"
else
  fail "read-run: no store prints nothing and creates nothing"
fi
run_cmd finder-no-store "$JOURNAL" find-run --workspace "$WS_READ" --plan alpha
expect_status 0 "find-run: no store exits 0"
if [[ "$(cat "$CASE_STDOUT")" == '{"schema":1,"runs":[],"ambiguous":[]}' && ! -e "$STORE_READ" ]]; then
  pass "find-run: no store prints empty lists and creates nothing"
else
  fail "find-run: no store prints empty lists and creates nothing"
fi
run_cmd finder-empty-plan "$JOURNAL" find-run --workspace "$WS_READ" --plan ''
expect_status 2 "find-run: empty plan exits 2"
run_cmd finder-newline-plan "$JOURNAL" find-run --workspace "$WS_READ" --plan $'one\ntwo'
expect_status 2 "find-run: multiline plan exits 2"
WS_NOLOCK="$(workspace read-no-lock)"
STORE_NOLOCK="$(store_dir "$WS_NOLOCK")"
mkdir -p "$STORE_NOLOCK"
run_cmd reader-no-lock "$JOURNAL" read-run --workspace "$WS_NOLOCK" --run "$ABSENT_RUN"
expect_status 2 "read-run: store root without meta.lock counts as no store"
run_cmd finder-no-lock "$JOURNAL" find-run --workspace "$WS_NOLOCK" --plan alpha
expect_status 0 "find-run: store root without meta.lock counts as no store"
if [[ "$(cat "$CASE_STDOUT")" == '{"schema":1,"runs":[],"ambiguous":[]}' && ! -e "$STORE_NOLOCK/meta.lock" ]]; then
  pass "find-run: absent meta.lock is not created"
else
  fail "find-run: absent meta.lock is not created"
fi

run_cmd reader-begin "$RUN" begin --workspace "$WS_READ" --plan alpha
RUN_READ="$(field_from "$CASE_STDOUT" run)"
READ_BEFORE="$(store_snapshot "$STORE_READ")"
run_cmd reader-active "$JOURNAL" read-run --workspace "$WS_READ" --run "$RUN_READ"
expect_status 0 "read-run: active run exits 0"
if python3 - "$CASE_STDOUT" "$RUN_READ" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(doc) == {"schema", "run", "ended", "end_status", "tail", "complete", "events"}
assert doc["schema"] == 1 and doc["run"] == sys.argv[2]
assert doc["ended"] is False and doc["end_status"] is None
assert doc["tail"] == "clean" and doc["complete"] is True
assert len(doc["events"]) == 1 and doc["events"][0]["event"] == "run.begin"
assert doc["events"][0]["plan"] == "alpha"
PY
then pass "read-run: active run prints its exact clean events"; else fail "read-run: active run prints its exact clean events"; fi
if [[ "$READ_BEFORE" == "$(store_snapshot "$STORE_READ")" ]]; then
  pass "read-run: every store file remains byte-identical"
else
  fail "read-run: every store file remains byte-identical"
fi
run_cmd reader-absent "$JOURNAL" read-run --workspace "$WS_READ" --run "$ABSENT_RUN"
expect_status 2 "read-run: valid id without a segment exits 2"
if [[ ! -s "$CASE_STDOUT" ]]; then pass "read-run: absent segment prints nothing"; else fail "read-run: absent segment prints nothing"; fi
run_cmd reader-invalid "$JOURNAL" read-run --workspace "$WS_READ" --run invalid
expect_status 2 "read-run: invalid run id exits 2"

python3 - "$STORE_READ/meta.lock" "$TMP_ROOT/read-lock.ready" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w", encoding="utf-8").close()
time.sleep(20)
PY
LOCK_HOLDER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$TMP_ROOT/read-lock.ready" ]] && break
  sleep 0.05
done
run_cmd reader-locked env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=0.1 "$JOURNAL" read-run \
  --workspace "$WS_READ" --run "$RUN_READ"
expect_status 3 "read-run: held lock exits 3"
run_cmd finder-locked env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=0.1 "$JOURNAL" find-run \
  --workspace "$WS_READ" --plan alpha
expect_status 3 "find-run: held lock exits 3"
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""

run_cmd reader-end "$RUN" end --workspace "$WS_READ" --status failed
expect_status 0 "read-run: terminal fixture ended"
if [[ ! -e "$STORE_READ/context" && -f "$STORE_READ/context.retired-$RUN_READ" ]]; then
  pass "read-run: ended context was retired"
else
  fail "read-run: ended context was retired"
fi
run_cmd reader-ended "$JOURNAL" read-run --workspace "$WS_READ" --run "$RUN_READ"
expect_status 0 "read-run: retired run can still be read by id"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["ended"] is True and doc["end_status"] == "failed"
assert doc["tail"] == "clean" and doc["complete"] is True
assert [event["event"] for event in doc["events"]] == ["run.begin", "run.end"]
PY
then pass "read-run: retired run reports run.end and failed status"; else fail "read-run: retired run reports run.end and failed status"; fi

run_cmd finder-none "$JOURNAL" find-run --workspace "$WS_READ" --plan other
if [[ $CASE_STATUS -eq 0 && "$(cat "$CASE_STDOUT")" == '{"schema":1,"runs":[],"ambiguous":[]}' ]]; then
  pass "find-run: a plan with no match returns empty lists"
else
  fail "find-run: a plan with no match returns empty lists"
fi
run_cmd finder-one "$JOURNAL" find-run --workspace "$WS_READ" --plan alpha
if python3 - "$CASE_STDOUT" "$RUN_READ" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == {"schema": 1, "runs": [sys.argv[2]], "ambiguous": []}
PY
then pass "find-run: one exact plan match survives context retirement"; else fail "find-run: one exact plan match survives context retirement"; fi
run_cmd finder-second-begin "$RUN" begin --workspace "$WS_READ" --plan alpha
RUN_READ_2="$(field_from "$CASE_STDOUT" run)"
run_cmd finder-second-end "$RUN" end --workspace "$WS_READ" --status completed
run_cmd finder-two "$JOURNAL" find-run --workspace "$WS_READ" --plan alpha
if python3 - "$CASE_STDOUT" "$RUN_READ" "$RUN_READ_2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc == {"schema": 1, "runs": sorted(sys.argv[2:]), "ambiguous": []}
PY
then pass "find-run: two runs with the same plan are sorted"; else fail "find-run: two runs with the same plan are sorted"; fi
run_cmd finder-planless-begin "$RUN" begin --workspace "$WS_READ"
RUN_PLANLESS="$(field_from "$CASE_STDOUT" run)"
run_cmd finder-planless-end "$RUN" end --workspace "$WS_READ" --status completed

SYNTHETIC_IDS=(20200101T000000Z-000001 20200101T000000Z-000002 \
  20200101T000000Z-000003 20200101T000000Z-000004 \
  20200101T000000Z-000005)
python3 - "$STORE_READ/runs" "$RUN_READ" "${SYNTHETIC_IDS[@]}" <<'PY'
import json, os, sys
runs_dir, source_id, found_id, short_id, empty_id, other_id, unterminated_id = sys.argv[1:]
with open(os.path.join(runs_dir, source_id + ".jsonl"), encoding="utf-8") as stream:
    begin = json.loads(stream.readline())
def create(run_id, data):
    path = os.path.join(runs_dir, run_id + ".jsonl")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
begin["run"] = found_id
create(found_id, (json.dumps(begin) + "\nnot json\n").encode())
create(short_id, b'{"schema":1,"event":"run.begin"')
create(empty_id, b"")
create(other_id, (json.dumps(dict(begin, run=other_id, event="checkpoint")) + "\n").encode())
create(unterminated_id, json.dumps(dict(begin, run=unterminated_id)).encode())
PY
run_cmd finder-ambiguous "$JOURNAL" find-run --workspace "$WS_READ" --plan alpha
if python3 - "$CASE_STDOUT" "$RUN_READ" "$RUN_READ_2" "$RUN_PLANLESS" "${SYNTHETIC_IDS[@]}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
first, second, planless, found, short, empty, other, unterminated = sys.argv[2:]
assert doc == {"schema": 1, "runs": sorted([first, second, found, unterminated]),
               "ambiguous": sorted([short, empty, other])}
assert planless not in doc["runs"] + doc["ambiguous"]
PY
then
  pass "find-run: no-context, later-corrupt, and unterminated matches; short, empty, non-begin ambiguous; no-plan omitted"
else
  fail "find-run: no-context, later-corrupt, and unterminated matches; short, empty, non-begin ambiguous; no-plan omitted"
fi
if python3 - "$CASE_STDOUT" "${SYNTHETIC_IDS[4]}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert sys.argv[2] in doc["runs"] and sys.argv[2] not in doc["ambiguous"]
PY
then pass "find-run: valid unterminated run.begin matches its plan"; else fail "find-run: valid unterminated run.begin matches its plan"; fi
if python3 - "$CASE_STDOUT" "${SYNTHETIC_IDS[1]}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert sys.argv[2] in doc["ambiguous"] and sys.argv[2] not in doc["runs"]
PY
then pass "find-run: half-written run.begin remains ambiguous"; else fail "find-run: half-written run.begin remains ambiguous"; fi
WS_BAD_RUNS="$(workspace bad-runs-directory)"
run_cmd bad-runs-begin "$RUN" begin --workspace "$WS_BAD_RUNS"
STORE_BAD_RUNS="$(store_dir "$WS_BAD_RUNS")"
printf '%s' x > "$STORE_BAD_RUNS/runs/unexpected"
chmod 600 "$STORE_BAD_RUNS/runs/unexpected"
run_cmd finder-bad-runs "$JOURNAL" find-run --workspace "$WS_BAD_RUNS" --plan alpha
expect_status 5 "find-run: malformed runs directory exits 5"
if [[ ! -s "$CASE_STDOUT" ]]; then pass "find-run: malformed runs directory prints no object"; else fail "find-run: malformed runs directory prints no object"; fi

WS_BAD_READ="$(workspace bad-read)"
run_cmd bad-read-begin "$RUN" begin --workspace "$WS_BAD_READ"
RUN_BAD_READ="$(field_from "$CASE_STDOUT" run)"
SEG_BAD_READ="$(store_dir "$WS_BAD_READ")/runs/${RUN_BAD_READ}.jsonl"
write_bad_read() { # $1=kind
  python3 - "$SEG_BAD_READ" "$RUN_BAD_READ" "$1" <<'PY'
import json, sys
path, run_id, kind = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    begin = json.loads(stream.readline())
event = {"schema": 1, "seq": 2, "ts": "2026-10-01T00:00:00Z",
         "event": "checkpoint", "run": run_id}
lines = [json.dumps(begin)]
if kind == "mid":
    lines.append("not json")
elif kind == "non-object":
    lines.append("42")
elif kind == "non-object-tail":
    lines.append("42")
elif kind == "wrong-run":
    event["run"] = "20200101T000000Z-eeeeee"
    lines.append(json.dumps(event))
elif kind == "repeat":
    event["seq"] = 1
    lines.append(json.dumps(event))
elif kind == "decrease":
    lines.append(json.dumps(dict(event, seq=3)))
    lines.append(json.dumps(event))
elif kind == "missing-seq":
    del event["seq"]
    lines.append(json.dumps(event))
elif kind == "noninteger-seq":
    event["seq"] = 2.0
    lines.append(json.dumps(event))
with open(path, "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + ("" if kind == "non-object-tail" else "\n"))
PY
}
for BAD_KIND in mid non-object wrong-run repeat decrease missing-seq noninteger-seq; do
  write_bad_read "$BAD_KIND"
  run_cmd "bad-read-$BAD_KIND" "$JOURNAL" read-run --workspace "$WS_BAD_READ" --run "$RUN_BAD_READ"
  if [[ "$BAD_KIND" == mid || "$BAD_KIND" == non-object ]]; then EXPECTED_BAD_STATUS=4; else EXPECTED_BAD_STATUS=6; fi
  expect_status "$EXPECTED_BAD_STATUS" "read-run: $BAD_KIND has its specified exit"
  if [[ ! -s "$CASE_STDOUT" ]]; then pass "read-run: $BAD_KIND prints no object"; else fail "read-run: $BAD_KIND prints no object"; fi
  if [[ "$BAD_KIND" == non-object ]]; then
    run_cmd bad-read-non-object-recover-mid "$RUN" recover --workspace "$WS_BAD_READ"
    expect_status 4 "recover: newline-terminated non-object agrees on mid-file corruption"
  fi
done
write_bad_read non-object-tail
run_cmd bad-read-non-object-tail "$JOURNAL" read-run --workspace "$WS_BAD_READ" --run "$RUN_BAD_READ"
expect_status 0 "read-run: unterminated non-object tail returns an object"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["tail"] == "torn" and doc["complete"] is False
assert [event["event"] for event in doc["events"]] == ["run.begin"]
PY
then pass "read-run: unterminated non-object is omitted as a torn tail"; else fail "read-run: unterminated non-object is omitted as a torn tail"; fi
run_cmd bad-read-non-object-recover "$RUN" recover --workspace "$WS_BAD_READ"
expect_status 0 "recover: unterminated non-object tail agrees that no dispatch is open"

for TEXT_KIND in utf8 surrogate; do
  WS_TEXT="$(workspace "read-$TEXT_KIND")"
  run_cmd "read-$TEXT_KIND-begin" "$RUN" begin --workspace "$WS_TEXT"
  RUN_TEXT="$(field_from "$CASE_STDOUT" run)"
  SEG_TEXT="$(store_dir "$WS_TEXT")/runs/${RUN_TEXT}.jsonl"
  python3 - "$SEG_TEXT" "$RUN_TEXT" "$TEXT_KIND" <<'PY'
import json, sys
path, run_id, kind = sys.argv[1:]
note = "caf" + chr(0xE9) if kind == "utf8" else chr(0xD800)
event = {"schema": 1, "seq": 2, "ts": "2026-10-01T00:00:00Z",
         "event": "checkpoint", "run": run_id, "note": note}
with open(path, "ab") as stream:
    stream.write((json.dumps(event, ensure_ascii=kind != "utf8") + "\n").encode("utf-8"))
PY
  run_cmd "read-$TEXT_KIND-ascii" env PYTHONIOENCODING=ascii:strict "$JOURNAL" read-run \
    --workspace "$WS_TEXT" --run "$RUN_TEXT"
  expect_status 0 "read-run: $TEXT_KIND stored string prints under ASCII stdout"
  if python3 - "$CASE_STDOUT" "$SEG_TEXT" "$TEXT_KIND" <<'PY'
import json, pathlib, sys
output, segment, kind = sys.argv[1:]
raw_output = pathlib.Path(output).read_bytes()
raw_segment = pathlib.Path(segment).read_bytes()
assert raw_output.isascii() and raw_output.endswith(b"\n")
if kind == "utf8":
    assert bytes([0xC3, 0xA9]) in raw_segment
else:
    assert bytes([92]) + b"ud800" in raw_segment
stored = [json.loads(line) for line in raw_segment.decode("utf-8").splitlines()]
assert json.loads(raw_output)["events"] == stored
PY
  then pass "read-run: $TEXT_KIND output is ASCII and round-trips every stored event"; else fail "read-run: $TEXT_KIND output is ASCII and round-trips every stored event"; fi
done

for TAIL_KIND in torn unterminated; do
  WS_TAIL_READ="$(workspace "read-tail-$TAIL_KIND")"
  run_cmd "tail-$TAIL_KIND-begin" "$RUN" begin --workspace "$WS_TAIL_READ"
  RUN_TAIL_READ="$(field_from "$CASE_STDOUT" run)"
  run_cmd "tail-$TAIL_KIND-start" "$JOURNAL" append --workspace "$WS_TAIL_READ" \
    --event dispatch.start --field dispatch_id=d-tail --field backend=codex --field mode=implement
  SEG_TAIL_READ="$(store_dir "$WS_TAIL_READ")/runs/${RUN_TAIL_READ}.jsonl"
  if [[ "$TAIL_KIND" == torn ]]; then
    printf '%s' '{"event":"dispatch.end","dispatch_id":"d-tail"' >> "$SEG_TAIL_READ"
  else
    python3 - "$SEG_TAIL_READ" "$RUN_TAIL_READ" <<'PY'
import json, sys
event = {"schema": 1, "seq": 3, "ts": "2026-10-01T00:00:00Z",
         "event": "dispatch.end", "run": sys.argv[2], "dispatch_id": "d-tail", "exit": 0}
with open(sys.argv[1], "ab") as stream:
    stream.write(json.dumps(event).encode("utf-8"))
PY
  fi
  run_cmd "tail-$TAIL_KIND-read" "$JOURNAL" read-run --workspace "$WS_TAIL_READ" --run "$RUN_TAIL_READ"
  expect_status 0 "read-run: $TAIL_KIND tail returns an object"
  READ_TAIL_OUTPUT="$CASE_STDOUT"
  if python3 - "$READ_TAIL_OUTPUT" "$TAIL_KIND" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
kind = sys.argv[2]
events = doc["events"]
assert doc["tail"] == kind and doc["complete"] is False
assert [e["event"] for e in events] == (["run.begin", "dispatch.start"] if kind == "torn"
                                         else ["run.begin", "dispatch.start", "dispatch.end"])
PY
  then pass "read-run: $TAIL_KIND tail preserves exactly the parsed events"; else fail "read-run: $TAIL_KIND tail preserves exactly the parsed events"; fi
  run_cmd "tail-$TAIL_KIND-recover" "$RUN" recover --workspace "$WS_TAIL_READ"
  if python3 - "$READ_TAIL_OUTPUT" "$CASE_STDERR" "$CASE_STATUS" "$TAIL_KIND" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))["events"]
closed = {e.get("dispatch_id") for e in events if e.get("event") in ("dispatch.end", "dispatch.abandoned")}
unmatched = {e.get("dispatch_id") for e in events if e.get("event") == "dispatch.start"} - closed
status = int(sys.argv[3])
error = open(sys.argv[2], encoding="utf-8").read()
assert bool(unmatched) == (status == 7)
assert (unmatched == {"d-tail"}) == (sys.argv[4] == "torn")
if unmatched:
    assert "unmatched dispatch_id(s): d-tail" in error
else:
    assert status == 0
PY
  then pass "read-run/recover: $TAIL_KIND unmatched starts agree with recover refusal"; else fail "read-run/recover: $TAIL_KIND unmatched starts agree with recover refusal"; fi
done

WS_REVIEW_FIELD="$(workspace review-field)"
run_cmd review-field-begin "$RUN" begin --workspace "$WS_REVIEW_FIELD"
RUN_REVIEW_FIELD="$(field_from "$CASE_STDOUT" run)"
for REVIEWER in claude codex cursor grok session; do
  run_cmd "review-field-$REVIEWER" "$JOURNAL" append --workspace "$WS_REVIEW_FIELD" \
    --event review.recorded --field unit=u1 --field round=1 --field verdict=pass \
    --field "reviewer=$REVIEWER"
  expect_status 0 "reviewer: $REVIEWER is accepted"
done
run_cmd review-field-invalid "$JOURNAL" append --workspace "$WS_REVIEW_FIELD" \
  --event review.recorded --field unit=u1 --field round=1 --field verdict=pass \
  --field reviewer=unknown
expect_status 2 "reviewer: unknown value exits 2"
expect_output stderr "invalid reviewer" "reviewer: unknown value names invalid reviewer"
run_cmd review-field-run "$RUN" review --workspace "$WS_REVIEW_FIELD" --unit u1 \
  --round 2 --verdict iterate --reviewer codex
expect_status 0 "reviewer: loop-run --reviewer codex succeeds"
run_cmd review-field-legacy "$RUN" review --workspace "$WS_REVIEW_FIELD" --unit u1 \
  --round 3 --verdict pass
expect_status 0 "reviewer: review without --reviewer succeeds"
run_cmd review-field-read "$JOURNAL" read-run --workspace "$WS_REVIEW_FIELD" --run "$RUN_REVIEW_FIELD"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))["events"]
reviews = [event for event in events if event["event"] == "review.recorded"]
assert [event.get("reviewer") for event in reviews] == [
    "claude", "codex", "cursor", "grok", "session", "codex", None]
assert "reviewer" not in reviews[-1]
assert reviews[-2]["round"] == 2 and reviews[-2]["verdict"] == "iterate"
PY
then pass "reviewer: enum, loop-run round-trip, and absent key are stored exactly"; else fail "reviewer: enum, loop-run round-trip, and absent key are stored exactly"; fi

WS_READ_CONTEXT="$(workspace read-context)"
STORE_READ_CONTEXT="$(store_dir "$WS_READ_CONTEXT")"
run_cmd read-context-no-store "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
expect_status 0 "read-context: missing store prints a document"
if python3 - "$CASE_STDOUT" "$STORE_READ_CONTEXT" <<'PY'
import json, os, sys
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "none", "run": None}
assert not os.path.lexists(sys.argv[2])
PY
then pass "read-context: missing store is not created"; else fail "read-context: missing store is not created"; fi
run_cmd read-context-begin "$RUN" begin --workspace "$WS_READ_CONTEXT"
RUN_READ_CONTEXT="$(field_from "$CASE_STDOUT" run)"
expect_status 0 "read-context: begin fixture succeeds"
run_cmd read-context-active "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
expect_status 0 "read-context: active read succeeds"
if python3 - "$CASE_STDOUT" "$RUN_READ_CONTEXT" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "active", "run": sys.argv[2]}
PY
then pass "read-context: active run id is exact"; else fail "read-context: active run id is exact"; fi
mv "$STORE_READ_CONTEXT/meta.lock" "$TMP_ROOT/read-context-saved-lock"
run_cmd read-context-missing-lock "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$CASE_STDOUT" "$CASE_STATUS" "$RUN_READ_CONTEXT" "$STORE_READ_CONTEXT/meta.lock" <<'PY'
import json, os, sys
assert int(sys.argv[2]) == 0
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "active", "run": sys.argv[3]}
assert not os.path.lexists(sys.argv[4])
PY
then pass "read-context: present context is active without meta.lock and read creates none"; else fail "read-context: missing-lock read failed (status $CASE_STATUS)"; fi
mv "$TMP_ROOT/read-context-saved-lock" "$STORE_READ_CONTEXT/meta.lock"
chmod 644 "$STORE_READ_CONTEXT/context"
run_cmd read-context-mode "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
expect_status 5 "read-context: unsafe context mode exits 5"
chmod 600 "$STORE_READ_CONTEXT/context"
CONTEXT_READ_CONTEXT="$STORE_READ_CONTEXT/context"
cp "$CONTEXT_READ_CONTEXT" "$TMP_ROOT/read-context-saved"
run_cmd read-context-end "$RUN" end --workspace "$WS_READ_CONTEXT" --status completed
expect_status 0 "read-context: end fixture succeeds"
run_cmd read-context-no-file "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$CASE_STDOUT" "$CASE_STATUS" <<'PY'
import json, sys
assert int(sys.argv[2]) == 0
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "none", "run": None}
PY
then pass "read-context: missing context prints none"; else fail "read-context: missing context (status $CASE_STATUS)"; fi
cp "$TMP_ROOT/read-context-saved" "$CONTEXT_READ_CONTEXT"
run_cmd read-context-stale "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$CASE_STDOUT" "$CASE_STATUS" "$RUN_READ_CONTEXT" <<'PY'
import json, sys
assert int(sys.argv[2]) == 0
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "stale", "run": sys.argv[3]}
PY
then pass "read-context: ended run is stale"; else fail "read-context: ended run is stale (status $CASE_STATUS)"; fi
printf 'invalid{\n' > "$CONTEXT_READ_CONTEXT"
run_cmd read-context-malformed "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$CASE_STDOUT" "$CASE_STATUS" <<'PY'
import json, sys
assert int(sys.argv[2]) == 0
assert json.load(open(sys.argv[1])) == {"schema": 1, "state": "malformed", "run": None}
PY
then pass "read-context: malformed file"; else fail "read-context: malformed file (status $CASE_STATUS)"; fi
WS_OTHER_CONTEXT="$(workspace read-context-other)"
run_cmd read-context-other-begin "$RUN" begin --workspace "$WS_OTHER_CONTEXT"
OTHER_CONTEXT="$(store_dir "$WS_OTHER_CONTEXT")/context"
cp "$OTHER_CONTEXT" "$CONTEXT_READ_CONTEXT"
run_cmd read-context-wrong "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$CASE_STDOUT" "$CASE_STATUS" <<'PY'
import json, sys
assert int(sys.argv[2]) == 0
doc = json.load(open(sys.argv[1]))
assert doc["state"] == "malformed" and isinstance(doc["run"], str)
PY
then pass "read-context: wrong workspace is malformed with readable run"; else fail "read-context: wrong workspace is malformed (status $CASE_STATUS)"; fi
cp "$TMP_ROOT/read-context-saved" "$CONTEXT_READ_CONTEXT"
python3 - "$STORE_READ_CONTEXT/meta.lock" "$TMP_ROOT/read-context-lock-ready" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], 'rb') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(10)
PY
LOCK_HOLDER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "$TMP_ROOT/read-context-lock-ready" ]] && break; sleep 0.1; done
run_cmd read-context-busy env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=0 "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
expect_status 3 "read-context: busy lock exits 3"
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""
python3 - "$STORE_READ_CONTEXT" "$TMP_ROOT/read-context-before.json" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
json.dump({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in root.rglob('*') if p.is_file()}, open(sys.argv[2], 'w'))
PY
run_cmd read-context-unchanged "$JOURNAL" read-context --workspace "$WS_READ_CONTEXT"
if python3 - "$STORE_READ_CONTEXT" "$TMP_ROOT/read-context-before.json" "$CASE_STATUS" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in root.rglob('*') if p.is_file()}
assert int(sys.argv[3]) == 0 and after == json.load(open(sys.argv[2]))
PY
then pass "read-context: all store bytes unchanged"; else fail "read-context: store changed (status $CASE_STATUS)"; fi

# --- generation and runs.tsv are written only under meta.lock ---
# A store holding nothing but the lock: a writer that cannot take the lock
# must leave it that way, and the first writer that does take it completes it.
WS_FIRST="$(workspace first-writer)"
STORE_FIRST="$(store_dir "$WS_FIRST")"
mkdir -p "$STORE_FIRST/runs"
chmod 700 "$STORE_FIRST" "$STORE_FIRST/runs"
: >"$STORE_FIRST/meta.lock"
chmod 600 "$STORE_FIRST/meta.lock"
python3 - "$STORE_FIRST/meta.lock" "$TMP_ROOT/first-lock.ready" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(20)
PY
LOCK_HOLDER_PID=$!
for _ in $(seq 1 100); do [[ -e "$TMP_ROOT/first-lock.ready" ]] && break; sleep 0.05; done
run_cmd first-busy env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=0 "$JOURNAL" begin-run --workspace "$WS_FIRST"
expect_status 3 "first writer: a held lock yields lock-busy exit 3"
if [[ ! -e "$STORE_FIRST/generation" && ! -e "$STORE_FIRST/runs.tsv" ]]; then
  pass "first writer: without the lock neither generation nor runs.tsv is created"
else
  fail "first writer: without the lock neither generation nor runs.tsv is created"
fi
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""
run_cmd first-rebuild "$JOURNAL" rebuild --workspace "$WS_FIRST"
expect_status 0 "first writer: the first command to take the lock succeeds"
if python3 - "$STORE_FIRST" <<'PY'
import os, stat, sys
root = sys.argv[1]
expected = {"generation": b"0\n", "runs.tsv": b""}
for name, content in expected.items():
    path = os.path.join(root, name)
    info = os.lstat(path)
    assert stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600, name
    assert open(path, "rb").read() == content, name
PY
then
  pass "first writer: generation starts at 0 and runs.tsv empty, both 0600"
else
  fail "first writer: generation starts at 0 and runs.tsv empty, both 0600"
fi

# The hard-link refusal is unchanged: a second link to generation is exit 5.
ln "$STORE_FIRST/generation" "$TMP_ROOT/first-generation.alias"
run_cmd first-hard-link "$JOURNAL" begin-run --workspace "$WS_FIRST"
expect_status 5 "hard link: a second link to generation is refused"
expect_output stderr "file has multiple hard links" "hard link: the refusal names the hard link"
rm -f "$TMP_ROOT/first-generation.alias"
run_cmd first-begin "$JOURNAL" begin-run --workspace "$WS_FIRST"
expect_status 0 "hard link: begin-run succeeds once the second link is gone"
if [[ "$(field_from "$CASE_STDOUT" generation)" == "1" && "$(cat "$STORE_FIRST/generation")" == "1" ]]; then
  pass "first writer: the first run is generation 1"
else
  fail "first writer: the first run is generation 1"
fi

# Three first-ever writers started together on a fresh store, one of them
# begin-run. All must succeed, and generation must end at 1: a first writer
# that initialised generation outside the lock could put 0 back.
RACE_ROUNDS=20
RACE_LOG="$TMP_ROOT/first-race.log"
: >"$RACE_LOG"
race_exit_bad=0
race_state_bad=0
for round in $(seq 1 "$RACE_ROUNDS"); do
  WS_RACE="$(workspace "first-race-$round")"
  STORE_RACE="$(store_dir "$WS_RACE")"
  printf '== round %s ==\n' "$round" >>"$RACE_LOG"
  race_pids=()
  env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=60 "$JOURNAL" rebuild --workspace "$WS_RACE" \
    >>"$RACE_LOG" 2>&1 &
  race_pids+=("$!")
  env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=60 "$JOURNAL" begin-run --workspace "$WS_RACE" \
    >"$TMP_ROOT/first-race-begin.stdout" 2>>"$RACE_LOG" &
  race_pids+=("$!")
  env LOOP_JOURNAL_LOCK_TIMEOUT_SEC=60 "$JOURNAL" rebuild --workspace "$WS_RACE" \
    >>"$RACE_LOG" 2>&1 &
  race_pids+=("$!")
  for pid in "${race_pids[@]}"; do
    if ! wait "$pid"; then
      race_exit_bad=$((race_exit_bad + 1))
      printf 'round %s: a writer exited nonzero\n' "$round" >>"$RACE_LOG"
    fi
  done
  if ! python3 - "$STORE_RACE" "$TMP_ROOT/first-race-begin.stdout" >>"$RACE_LOG" 2>&1 <<'PY'
import os, sys
root, begin_stdout = sys.argv[1], sys.argv[2]
printed = dict(
    line.split("=", 1) for line in open(begin_stdout, encoding="utf-8").read().splitlines()
)
generation = open(os.path.join(root, "generation"), encoding="utf-8").read()
rows = open(os.path.join(root, "runs.tsv"), encoding="utf-8").read().splitlines()
leftovers = [name for name in os.listdir(root) if name.startswith(".tmp-")]
problems = []
if printed.get("generation") != "1":
    problems.append("begin-run printed generation %r" % printed.get("generation"))
if generation != "1\n":
    problems.append("generation file holds %r" % generation)
if len(rows) != 1 or rows[0].split("\t")[:3] != ["1", printed.get("run"), "active"]:
    problems.append("runs.tsv rows %r" % rows)
if leftovers:
    problems.append("temp files left: %r" % leftovers)
if problems:
    raise SystemExit("; ".join(problems))
PY
  then
    race_state_bad=$((race_state_bad + 1))
  fi
done
CASE_STDOUT=""
CASE_STDERR="$RACE_LOG"
if [[ $race_exit_bad -eq 0 ]]; then
  pass "first writers: three started together all exit 0 in each of $RACE_ROUNDS rounds"
else
  fail "first writers: three started together all exit 0 in each of $RACE_ROUNDS rounds ($race_exit_bad nonzero)"
fi
if [[ $race_state_bad -eq 0 ]]; then
  pass "first writers: generation ends at 1 with one run row and no temp file in each of $RACE_ROUNDS rounds"
else
  fail "first writers: generation ends at 1 with one run row and no temp file in each of $RACE_ROUNDS rounds ($race_state_bad wrong)"
fi

# --- A link count of 0 is a file being replaced, not a hard link ---
link_count_case() { # $1=case $2=description
  run_cmd "link-count-$1" env TMPDIR="$TMP_ROOT" \
    python3 "$SCRIPT_DIR/link-count-cases.py" "$JOURNAL" "$1"
  expect_status 0 "link count: $2"
}
link_count_case replaced-once "0 on the first look is read again and the file accepted"
link_count_case replaced-repeatedly "0 on five looks in a row is still accepted"
link_count_case never-settles "0 on every look is refused after a bounded number of looks, not as a hard link"
link_count_case hard-link "a second link is refused as a hard link"
link_count_case hard-link-after-replace "0 and then a second link is refused as a hard link"
link_count_case removed-after-replace "0 and then no file is reported missing"
link_count_case live-replace "a file being replaced in a tight loop is never refused"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
