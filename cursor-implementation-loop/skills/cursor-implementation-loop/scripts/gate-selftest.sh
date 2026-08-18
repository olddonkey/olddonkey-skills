#!/usr/bin/env bash
# Canonical fast, dependency-free regression checks for run-gate.sh. Unit 2
# byte-locks this file to the Cursor package copy until generated-tree checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/run-gate.sh" ]]; then
  GATE="$SCRIPT_DIR/run-gate.sh"
elif [[ -f "$SCRIPT_DIR/../scripts/run-gate.sh" ]]; then
  GATE="$SCRIPT_DIR/../scripts/run-gate.sh"
else
  echo "error: cannot find run-gate.sh beside gate-selftest.sh or under ../scripts" >&2
  exit 2
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-loop-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

if [[ -x "$SCRIPT_DIR/../../engineering-mode/scripts/tree-oid.sh" ]]; then
  TREE_OID="$SCRIPT_DIR/../../engineering-mode/scripts/tree-oid.sh"
elif [[ -x "$SCRIPT_DIR/../../cursor-engineering-mode/scripts/tree-oid.sh" ]]; then
  TREE_OID="$SCRIPT_DIR/../../cursor-engineering-mode/scripts/tree-oid.sh"
else
  TREE_OID=""
fi
if [[ -x "$SCRIPT_DIR/../scripts/loop-journal" ]]; then
  JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
elif [[ -x "$SCRIPT_DIR/../../../../skills/implementation-loop/scripts/loop-journal" ]]; then
  JOURNAL="$SCRIPT_DIR/../../../../skills/implementation-loop/scripts/loop-journal"
else
  JOURNAL=""
fi

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_OUTPUT=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_OUTPUT" && -f "$CASE_OUTPUT" ]]; then
    sed 's/^/  | /' "$CASE_OUTPUT" >&2
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

expect_nonzero() { # $1=description
  if [[ $CASE_STATUS -ne 0 ]]; then
    pass "$1"
  else
    fail "$1 (expected nonzero status)"
  fi
}

expect_output() { # $1=fixed string $2=description
  if grep -Fq -- "$1" "$CASE_OUTPUT"; then
    pass "$2"
  else
    fail "$2 (missing: $1)"
  fi
}

expect_no_output() { # $1=fixed string $2=description
  if grep -Fq -- "$1" "$CASE_OUTPUT"; then
    fail "$2 (unexpected: $1)"
  else
    pass "$2"
  fi
}

expect_first_line() { # $1=file $2=expected $3=description
  local actual=""
  [[ -f "$1" ]] && IFS= read -r actual < "$1"
  if [[ "$actual" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected '$2', got '$actual')"
  fi
}

expect_file_line() { # $1=file $2=exact line $3=description
  if [[ -f "$1" ]] && LC_ALL=C grep -qxF -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3 (no exact line '$2' in $1)"
  fi
}

expect_no_file_line() { # $1=file $2=exact line $3=description
  if [[ -f "$1" ]] && LC_ALL=C grep -qxF -- "$2" "$1"; then
    fail "$3 (unexpected exact line '$2' in $1)"
  else
    pass "$3"
  fi
}

expect_missing_file() { # $1=file $2=description
  if [[ -e "$1" ]]; then
    fail "$2 (unexpected file: $1)"
  else
    pass "$2"
  fi
}

skip_checks() { # $@=descriptions; marked skipped so counts stay stable
  local description
  for description in "$@"; do
    CHECKS=$((CHECKS + 1))
    printf 'ok %d - %s # SKIP no tomllib python3 available\n' "$CHECKS" "$description"
  done
}

run_case() { # $1=name, remaining args=command
  local name="$1"
  shift
  CASE_OUTPUT="$TMP_ROOT/$name.out"
  if "$@" > "$CASE_OUTPUT" 2>&1; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

run_case_in_dir() { # $1=name $2=working directory, remaining args=command
  local name="$1" directory="$2"
  shift 2
  run_case "$name" bash -c 'cd "$1" && shift && exec "$@"' _ "$directory" "$@"
}

write_lines() { # $1=path, remaining args=lines
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

init_git_repo() { # $1=dir
  mkdir -p "$1"
  rm -rf "$1.gitadmin"
  git init -q --template= --separate-git-dir="$1.gitadmin" "$1"
  git -C "$1" config user.email gate-selftest@example.invalid
  git -C "$1" config user.name gate-selftest
  printf 'base\n' > "$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -qm base
}

journal_store() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key))
PY
}

expect_gate_result() { # $1=workspace $2=policy $3=purpose $4=binding $5=description
  local store
  store="$(journal_store "$1")"
  if python3 - "$store" "$2" "$3" "$4" <<'PY'
import json, os, sys

store, policy, purpose, binding = sys.argv[1:]
events = []
runs = os.path.join(store, "runs")
if os.path.isdir(runs):
    for name in sorted(os.listdir(runs)):
        if name.endswith(".jsonl"):
            for line in open(os.path.join(runs, name), encoding="utf-8"):
                line = line.strip()
                if line:
                    events.append(json.loads(line))
results = [event for event in events if event.get("event") == "gate.result"]
if not results:
    raise SystemExit(1)
event = results[-1]
if event.get("policy") != policy or event.get("purpose") != purpose:
    raise SystemExit(1)
if event.get("binding") != binding:
    raise SystemExit(1)
PY
  then
    pass "$5"
  else
    fail "$5"
  fi
}

# Without a baseline, run-gate keeps the suite's pass-through behavior.
run_case gate-pass bash "$GATE" --log "$TMP_ROOT/gate-pass.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "gate passes a successful command"
expect_output "RESULT: gate green" "gate prints its normal green result"

# Without --baseline, an exit-zero command with no output remains a pass-through
# success even though no supported-runner summary is present.
run_case gate-plain-empty bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-empty.log" -- bash -c ':'
expect_status 0 "plain gate preserves exit-zero empty-output pass-through"
expect_output "RESULT: gate green" "plain gate keeps its empty-output green result"

# A runner-owned failed summary contradicts exit zero even without --baseline.
run_case gate-plain-masked-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-masked-summary.log" -- \
  bash -c 'printf '\''=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "plain gate rejects an exit-zero pytest failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a pytest summary/exit contradiction"

# Individual failure-looking lines may be application logs, so plain mode still
# passes them through when no formal runner summary reports a failure.
run_case gate-plain-failure-line bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-failure-line.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n'\'''
expect_status 0 "plain gate preserves an exit-zero individual failure-line pass-through"
expect_output "RESULT: gate green" \
  "plain gate tolerates an individual failure line without a summary"

run_case gate-plain-unittest-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-unittest-summary.log" -- \
  bash -c 'printf '\''FAILED (failures=1)\n'\'''
expect_status 1 "plain gate rejects an exit-zero unittest failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a unittest summary/exit contradiction"

# pytest -q emits its summary without fences; a failing quiet summary must
# contradict a masked exit-zero even without --baseline.
run_case gate-plain-quiet-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-quiet-masked.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n1 failed in 0.01s\n'\'''
expect_status 1 "plain gate rejects an exit-zero quiet-mode failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a quiet-mode summary/exit contradiction"

# Positive error counts (collection errors) are failure evidence too.
run_case gate-plain-error-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-error-masked.log" -- \
  bash -c 'printf '\''ERROR test_collect.py - RuntimeError: boom\n=========================== 1 error in 0.04s ===========================\n'\'''
expect_status 1 "plain gate rejects an exit-zero errors summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate treats positive error counts as failure evidence"

# The quiet form only counts when it matches the full official pytest shape,
# so application log lines mentioning failure counts stay out of the check.
run_case gate-plain-quiet-lookalike bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-quiet-lookalike.log" -- \
  bash -c 'printf '\''deploy: 3 failed in the last hour\n2 failed in staging\n'\'''
expect_status 0 "plain gate ignores failure-count words outside a formal summary shape"
expect_output "RESULT: gate green" \
  "plain gate keeps lookalike log lines out of the consistency check"

EMPTY_BASELINE="$TMP_ROOT/empty-baseline.log"
: > "$EMPTY_BASELINE"
run_case gate-baseline-masked-new bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-masked-new.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n'\'''
expect_status 1 "baseline gate rejects an exit-zero run with a new parsed failure"
expect_output "RESULT: gate RED — exit 0 but failure lines present (is the runner masking its exit code?)" \
  "baseline gate retains its stricter line-only masking check"

# Quiet-mode summaries are first-class execution evidence under --baseline:
# a passing -q run is green, a baseline-matched -q failure is green, and a
# quiet no-tests run still fails closed.
run_case gate-quiet-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''.\n2 passed in 0.03s\n'\'''
expect_status 0 "baseline gate accepts a passing pytest -q run"
expect_output "RESULT: gate green" \
  "baseline gate recognizes the quiet-mode passed summary as executed tests"

QUIET_BASELINE="$TMP_ROOT/pytest-quiet-baseline.log"
write_lines "$QUIET_BASELINE" \
  'FAILED tests/test_widget.py::test_flaky - AssertionError: detail' \
  '1 failed in 0.01s'
run_case gate-quiet-known bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-known.log" --baseline "$QUIET_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_flaky - AssertionError: detail\n1 failed in 0.01s\n'\''; exit 1'
expect_status 0 "baseline gate matches a known failure reported by a quiet-mode summary"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "baseline gate counts quiet-mode failed summaries as executed tests"

run_case gate-quiet-no-tests bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-no-tests.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''no tests ran in 0.01s\n'\'''
expect_nonzero "baseline gate fails closed on a quiet-mode no-tests run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "baseline gate reads the quiet-mode no-tests summary"

# A shared log/baseline target must be rejected before the command can truncate
# it. The first case exercises normalized string equality before either exists;
# the second exercises filesystem identity through a symlink alias.
SAME_PATH="$TMP_ROOT/gate-same-path.log"
run_case gate-same-path bash "$GATE" \
  --log "$SAME_PATH" --baseline "$SAME_PATH" -- bash -c 'exit 99'
expect_status 2 "gate rejects identical --log and --baseline strings"
expect_output "--log and --baseline refer to the same file" \
  "gate explains the identical-path configuration error"

SAME_TARGET="$TMP_ROOT/gate-same-target.log"
SAME_ALIAS="$TMP_ROOT/gate-same-alias.log"
write_lines "$SAME_TARGET" 'existing baseline evidence'
ln -s "$SAME_TARGET" "$SAME_ALIAS"
run_case gate-same-alias bash "$GATE" \
  --log "$SAME_ALIAS" --baseline "$SAME_TARGET" -- bash -c 'exit 99'
expect_status 2 "gate rejects a symlink alias of the baseline"
expect_output "--log and --baseline refer to the same file" \
  "gate explains the filesystem-alias configuration error"

DANGLING_BASELINE="$TMP_ROOT/gate-dangling-baseline.log"
DANGLING_LOG="$TMP_ROOT/gate-dangling-log.log"
ln -s "$DANGLING_BASELINE" "$DANGLING_LOG"
run_case gate-dangling-alias bash "$GATE" \
  --log "$DANGLING_LOG" --baseline "$DANGLING_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - RuntimeError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_nonzero "gate rejects or fails closed for a dangling log symlink to the baseline"
expect_no_output "gate green" \
  "gate never reports green for a dangling log symlink to the baseline"

UNIT_BASELINE="$TMP_ROOT/unittest-baseline.log"
write_lines "$UNIT_BASELINE" \
  'FAIL: test_known (tests.Case.test_known)' \
  'Ran 1 test in 0.001s' \
  'FAILED (failures=1)'

run_case gate-unittest-new bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-new.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_new (tests.Case.test_new)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 7'
expect_status 7 "gate stays nonzero for a new unittest failure"
expect_output "FAIL: test_new (tests.Case.test_new)" \
  "gate lists the new unittest failure"

run_case gate-unittest-match bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-match.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 1'
expect_status 0 "gate exits zero when unittest failures match baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate reports baseline-clean unittest failures"

run_case gate-unittest-mixed bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-mixed.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 3 tests in 0.001s\nFAILED (failures=1, skipped=2)\n'\''; exit 1'
expect_status 0 "gate accepts a known unittest failure when one test executed and two skipped"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate counts only non-skipped unittest tests as executed"

UNIT_SUBSET_BASELINE="$TMP_ROOT/unittest-subset-baseline.log"
write_lines "$UNIT_SUBSET_BASELINE" \
  'FAIL: test_known (tests.Case.test_known)' \
  'FAIL: test_other (tests.Case.test_other)' \
  'Ran 2 tests in 0.001s' \
  'FAILED (failures=2)'
run_case gate-unittest-subset bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-subset.log" --baseline "$UNIT_SUBSET_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 1'
expect_status 0 "gate exits zero when unittest failures are a subset of baseline"

PYTEST_BASELINE="$TMP_ROOT/pytest-baseline.log"
write_lines "$PYTEST_BASELINE" \
  'FAILED tests/test_widget.py::test_value - AssertionError: old detail' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-baseline-masked-known bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-masked-known.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: old detail\n=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "baseline gate rejects exit-zero failures even when they match baseline"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "baseline gate applies the shared summary/exit consistency check"

# The log is created fresh for THIS run: an uncreatable log aborts before
# the command starts (stale content must never match a baseline on behalf
# of a command that never ran).
UNWRITABLE_DIR="$TMP_ROOT/gate-readonly-dir"
mkdir -p "$UNWRITABLE_DIR"
write_lines "$UNWRITABLE_DIR/stale.log" \
  'FAILED tests/test_widget.py::test_value - AssertionError: old detail' \
  '=========================== 1 failed in 0.01s ==========================='
chmod 555 "$UNWRITABLE_DIR"
run_case gate-unwritable-log bash "$GATE" \
  --log "$UNWRITABLE_DIR/stale.log" --baseline "$PYTEST_BASELINE" -- bash -c 'exit 1'
expect_status 2 "gate refuses an uncreatable log instead of parsing its stale content"
expect_output "cannot exclusively create log" "gate explains the uncreatable log"
chmod 755 "$UNWRITABLE_DIR"

# Symlinked logs are refused, and the exclusive create means the link's
# TARGET is never truncated — a plain redirect would have emptied it.
SYMLINK_TARGET="$TMP_ROOT/gate-symlink-target.log"
SYMLINK_LOG="$TMP_ROOT/gate-symlink.log"
write_lines "$SYMLINK_TARGET" 'precious pre-existing content'
ln -s "$SYMLINK_TARGET" "$SYMLINK_LOG"
run_case gate-symlink-log bash "$GATE" --log "$SYMLINK_LOG" -- bash -c ':'
expect_status 2 "gate refuses a symlinked log"
expect_output "must not be a symlink" "gate explains the symlink rejection"
expect_file_line "$SYMLINK_TARGET" "precious pre-existing content" \
  "gate leaves a symlink target untruncated"

# Only the runner's own tests-failed status (1) may be offset by a baseline;
# signals, crashes, and interrupts never baseline away.
run_case gate-signal-exit bash "$GATE" \
  --log "$TMP_ROOT/gate-signal.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: old detail\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 137'
expect_status 137 "gate keeps an abnormal exit code even when failures match baseline"
expect_output "abnormal runner exit (137)" "gate explains the abnormal-exit rejection"

# The verdict reads through the descriptor the command wrote: a log path
# swapped mid-run — even for green-looking content — is not judged.
SWAP_LOG="$TMP_ROOT/gate-swap.log"
run_case gate-log-swap bash "$GATE" --log "$SWAP_LOG" -- \
  bash -c "rm -f '$SWAP_LOG'; printf '=========================== 1 passed in 0.01s ===========================\n' > '$SWAP_LOG'"
expect_status 1 "gate rejects a log replaced during the run"
expect_output "log file was replaced during the run" \
  "gate explains the mid-run log swap"

run_case gate-pytest-message-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-message-change.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: new detail\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate baselines a pytest message-only change with the same exception class"
expect_output "--- 1 failure/error header(s) ---" \
  "gate extracts the pytest FAILED short-summary line"
expect_output "FAILED tests/test_widget.py::test_value [AssertionError]" \
  "gate retains the pytest exception class in its stable identifier"

run_case gate-pytest-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-class-change.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - RuntimeError: deterministic regression\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects the same pytest test ID with a different exception class"
expect_output "FAILED tests/test_widget.py::test_value [RuntimeError]" \
  "gate reports the changed pytest exception class as a new failure"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate marks a pytest exception-class change red"

PYTEST_AMBIGUOUS_BASELINE="$TMP_ROOT/pytest-ambiguous-baseline.log"
write_lines "$PYTEST_AMBIGUOUS_BASELINE" \
  'FAILED t.py::test_value[a] - b] - AssertionError: x' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-pytest-ambiguous-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-ambiguous-class-change.log" \
  --baseline "$PYTEST_AMBIGUOUS_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[a] - b] - RuntimeError: x\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change for an ambiguous pytest parameter ID"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate fails closed instead of guessing how to split an ambiguous pytest line"

run_case gate-pytest-ambiguous-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-ambiguous-identical.log" \
  --baseline "$PYTEST_AMBIGUOUS_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[a] - b] - AssertionError: x\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical whole-line ambiguous pytest failure"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps stable whole-line identifiers green when truly unchanged"

PYTEST_PARAM_BASELINE="$TMP_ROOT/pytest-param-baseline.log"
write_lines "$PYTEST_PARAM_BASELINE" \
  'FAILED t.py::test_v[a - b] - AssertionError: msg' \
  '=========================== 1 failed in 0.01s ==========================='
# The raw-separator rule deliberately keeps these whole-line identifiers: the
# parameter ID contributes a second " - ", so even message-only changes are red.
run_case gate-pytest-param-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-param-class-change.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - RuntimeError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change when a pytest parameter ID contains a raw separator"
expect_output "FAILED t.py::test_v[a - b] - RuntimeError: msg" \
  "gate keeps the raw-separator class-change line whole"

run_case gate-pytest-raw-separator-message-change-red bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-raw-separator-message-change-red.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - AssertionError: changed message\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate intentionally rejects a message-only change when two raw separators are present"
expect_output "FAILED t.py::test_v[a - b] - AssertionError: changed message" \
  "gate keeps the raw-separator message-change line whole"

run_case gate-pytest-param-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-param-identical.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - AssertionError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches identical whole-line pytest parameter failures"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps identical raw-separator lines green"

PYTEST_ADVERSARIAL_BASELINE="$TMP_ROOT/pytest-adversarial-baseline.log"
write_lines "$PYTEST_ADVERSARIAL_BASELINE" \
  'FAILED t.py::test_value[x] - RuntimeError y[[] - AssertionError: msg' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-pytest-adversarial-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-adversarial-class-change.log" \
  --baseline "$PYTEST_ADVERSARIAL_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[x] - RuntimeError y[[] - ValueError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change hidden behind an adversarial pytest parameter ID"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate fails closed for an adversarial parameter-ID class change"

run_case gate-pytest-adversarial-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-adversarial-identical.log" \
  --baseline "$PYTEST_ADVERSARIAL_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[x] - RuntimeError y[[] - AssertionError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical adversarial pytest failure line"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps an unchanged adversarial whole-line identifier green"

# pytest 9 native subtests: the parent FAILED line is constant, the specific
# failing subtest lives in the SUBFAILED line — a shifted subtest is new.
PYTEST_SUBTEST_BASELINE="$TMP_ROOT/pytest-subtest-baseline.log"
write_lines "$PYTEST_SUBTEST_BASELINE" \
  'SUBFAILED(value=0) t.py::test_contains - AssertionError: value 0 broke' \
  'FAILED t.py::test_contains - contains 1 failed subtest' \
  '=========================== 2 failed in 0.01s ==========================='
run_case gate-subtest-shift bash "$GATE" \
  --log "$TMP_ROOT/gate-subtest-shift.log" --baseline "$PYTEST_SUBTEST_BASELINE" -- \
  bash -c 'printf '\''SUBFAILED(value=1) t.py::test_contains - AssertionError: value 1 broke\nFAILED t.py::test_contains - contains 1 failed subtest\n=========================== 2 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a shifted failing subtest behind an unchanged parent FAILED line"
expect_output "SUBFAILED(value=1) t.py::test_contains [AssertionError]" \
  "gate fingerprints the specific SUBFAILED identity"

run_case gate-subtest-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-subtest-identical.log" --baseline "$PYTEST_SUBTEST_BASELINE" -- \
  bash -c 'printf '\''SUBFAILED(value=0) t.py::test_contains - AssertionError: value 0 broke\nFAILED t.py::test_contains - contains 1 failed subtest\n=========================== 2 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical failing subtest against baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps a baseline-matched subtest failure green"

# Execution evidence is the LAST formal summary. A summary-shaped line printed
# earlier (application output, an inner pytest run) must not vouch for a run
# whose real final summary shows no executed tests — and conversely an inner
# failed summary must not red a run whose final summary is clean.
FAKE_SUMMARY_BASELINE="$TMP_ROOT/fake-summary-baseline.log"
write_lines "$FAKE_SUMMARY_BASELINE" \
  'ERROR t.py - RuntimeError: collection failed'
run_case gate-early-fake-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-early-fake-summary.log" --baseline "$FAKE_SUMMARY_BASELINE" -- \
  bash -c 'printf '\''1 passed in 0.01s\nERROR t.py - RuntimeError: collection failed\n=========================== 1 error in 0.04s ===========================\n'\''; exit 2'
expect_status 2 "gate ignores a summary-shaped line printed before the real final summary"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate takes execution evidence only from the final formal summary"

run_case gate-nested-runner bash "$GATE" \
  --log "$TMP_ROOT/gate-nested-runner.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''1 failed in 0.10s\n=========================== 3 passed in 1.20s ===========================\n'\'''
expect_status 0 "gate trusts the outer runner final summary over an inner run captured mid-log"
expect_output "RESULT: gate green" \
  "gate stays green when an inner failed summary precedes a passing final summary"

# Native-subtests quiet summaries add `N subtests passed/failed` terms.
run_case gate-quiet-subtests-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-subtests-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''uu.\n1 passed, 2 subtests passed in 0.00s\n'\'''
expect_status 0 "baseline gate accepts a passing quiet run with native subtests counts"
expect_output "RESULT: gate green" \
  "baseline gate parses the subtests quiet summary as executed tests"
expect_output "1 passed, 2 subtests passed in 0.00s" \
  "gate surfaces the subtests quiet summary in its preview"

run_case gate-quiet-subtests-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-subtests-masked.log" -- \
  bash -c 'printf '\''SUBFAILED(value=1) t.py::test_contains - AssertionError: boom\nFAILED t.py::test_contains - contains 1 failed subtest\n2 failed, 1 subtests passed in 0.01s\n'\'''
expect_status 1 "plain gate rejects a masked exit-zero subtests failed quiet summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate reads failed counts from the subtests quiet summary"

# The verdict is the LAST runner block of either kind: unittest output from an
# inner child must not vouch for an outer pytest run, and an inner unittest
# failure must not red a clean outer pytest run.
CROSS_RUNNER_BASELINE="$TMP_ROOT/cross-runner-baseline.log"
write_lines "$CROSS_RUNNER_BASELINE" \
  'ERROR t.py - RuntimeError: collection failed'
run_case gate-cross-runner-inner-unittest bash "$GATE" \
  --log "$TMP_ROOT/gate-cross-runner-inner-unittest.log" \
  --baseline "$CROSS_RUNNER_BASELINE" -- \
  bash -c 'printf '\''Ran 3 tests in 0.001s\nOK\nERROR t.py - RuntimeError: collection failed\n=========================== 1 error in 0.04s ===========================\n'\''; exit 2'
expect_status 2 "gate ignores inner unittest output when the final verdict is a pytest collection error"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate refuses cross-runner execution evidence"

run_case gate-cross-runner-inner-unittest-failed bash "$GATE" \
  --log "$TMP_ROOT/gate-cross-runner-inner-unittest-failed.log" -- \
  bash -c 'printf '\''FAILED (failures=1)\n=========================== 3 passed in 1.20s ===========================\n'\'''
expect_status 0 "plain gate trusts the final pytest verdict over an inner unittest failed line"
expect_output "RESULT: gate green" \
  "plain gate stays green when an inner unittest failure precedes a passing final summary"

# Forced-color output (--color=yes) is parsed through an ANSI-stripped view.
run_case gate-ansi-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-ansi-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''\033[32m\033[1m========== 1 passed\033[0m\033[32m in 0.01s ==========\033[0m\n'\'''
expect_status 0 "baseline gate recognizes a color-wrapped passing summary"
expect_output "RESULT: gate green" \
  "baseline gate parses ANSI-colored fenced summaries"

run_case gate-ansi-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-ansi-masked.log" -- \
  bash -c 'printf '\''\033[31mFAILED t.py::test_x - AssertionError: boom\033[0m\n\033[31m========== 1 failed in 0.01s ==========\033[0m\n'\'''
expect_status 1 "plain gate sees a color-wrapped failed summary through the ANSI stripping"
expect_output "FAILED t.py::test_x [AssertionError]" \
  "gate extracts fingerprints from color-wrapped failure lines"

# Logs are arbitrary bytes. In a UTF-8 locale an invalid byte used to abort
# sed with an empty parse view, hiding a masked failure — parsing must be
# bytewise regardless of the ambient locale. Force a UTF-8 locale when the
# host offers one so the regression actually exercises that environment.
UTF8_LOCALE="$(locale -a 2>/dev/null | LC_ALL=C grep -i -m1 -E '^(en_US|C)\.utf-?8$' || true)"
[[ -n "$UTF8_LOCALE" ]] || UTF8_LOCALE=C
run_case gate-invalid-byte-masked env LC_ALL="$UTF8_LOCALE" bash "$GATE" \
  --log "$TMP_ROOT/gate-invalid-byte-masked.log" -- \
  bash -c 'printf '\''\377\nFAILED t.py::test_x - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "gate parses a log containing invalid UTF-8 bytes bytewise ($UTF8_LOCALE)"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "gate stays fail-closed on a masked failure in a byte-poisoned log"

run_case gate-invalid-byte-pass env LC_ALL="$UTF8_LOCALE" bash "$GATE" \
  --log "$TMP_ROOT/gate-invalid-byte-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''\377 binary noise\n=========================== 1 passed in 0.01s ===========================\n'\'''
expect_status 0 "baseline gate still recognizes a passing summary in a byte-poisoned log"
expect_output "RESULT: gate green" \
  "gate does not false-red on invalid bytes in a passing run"

# --strict is the real zero-failure mode: recognized verdict, executed tests,
# and no failure lines. Plain no-flag mode stays a documented pass-through.
run_case gate-strict-baseline-conflict bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-conflict.log" --baseline "$EMPTY_BASELINE" -- bash -c ':'
expect_status 2 "gate rejects --strict combined with --baseline"
expect_output "mutually exclusive" "gate explains the strict/baseline conflict"

run_case gate-strict-pass bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-pass.log" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\nOK\n'\'''
expect_status 0 "strict gate passes a real unittest success"
expect_output "RESULT: gate green" "strict gate reports green for executed passing tests"

run_case gate-strict-pytest-pass bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-pytest-pass.log" -- \
  bash -c 'printf '\''=========================== 2 passed in 0.10s ===========================\n'\'''
expect_status 0 "strict gate passes a fenced pytest success"

run_case gate-strict-empty bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-empty.log" -- bash -c ':'
expect_status 1 "strict gate rejects exit-zero empty output"
expect_output "strict needs a recognized unittest/pytest verdict" \
  "strict gate explains the missing runner verdict"

run_case gate-strict-zero-tests bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-zero.log" -- \
  bash -c 'printf '\''Ran 0 tests in 0.000s\nOK\n'\'''
expect_status 1 "strict gate rejects a zero-test OK run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or zero-test run" \
  "strict gate explains the zero-test rejection"

run_case gate-strict-failure-line bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-failure-line.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 2 passed in 0.10s ===========================\n'\'''
expect_status 1 "strict gate rejects stray failure lines even when the final summary is clean"
expect_output "RESULT: gate RED — failure lines present despite exit 0" \
  "strict gate explains the failure-line rejection"

run_case gate-strict-red bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-red.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "strict gate passes the failing exit code through"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "strict gate reports red for a failing suite"

# A bare `Ran N tests` line with no paired OK/FAILED result is a truncated
# or masked run, not a complete unittest verdict.
run_case gate-strict-truncated-unittest bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-truncated.log" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\n'\'''
expect_status 1 "strict gate rejects a unittest count line without its result line"
expect_output "strict needs a recognized unittest/pytest verdict" \
  "strict gate treats a truncated unittest verdict as unrecognized"

run_case gate-baseline-truncated-unittest bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-truncated.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\n'\'''
expect_nonzero "baseline gate rejects a unittest count line without its result line"
expect_output "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only" \
  "baseline gate treats a truncated unittest verdict as unrecognized"

CRASH_BASELINE="$TMP_ROOT/crash-baseline.log"
write_lines "$CRASH_BASELINE" 'ImportError: same crash text'
run_case gate-crash bash "$GATE" \
  --log "$TMP_ROOT/gate-crash.log" --baseline "$CRASH_BASELINE" -- \
  bash -c 'printf '\''ImportError: same crash text\n'\''; exit 9'
expect_status 9 "gate stays nonzero when no failure identifier is parseable"
expect_output "RESULT: gate RED — nonzero exit with no parseable failures (crash/collection error?)" \
  "gate explains an unparseable nonzero exit"

COLLECTION_BASELINE="$TMP_ROOT/collection-baseline.log"
write_lines "$COLLECTION_BASELINE" \
  'ERROR collecting t.py - RuntimeError: expected 1 passed check'
run_case gate-collection-count-words bash "$GATE" \
  --log "$TMP_ROOT/gate-collection-count-words.log" \
  --baseline "$COLLECTION_BASELINE" -- \
  bash -c 'printf '\''ERROR collecting t.py - RuntimeError: expected 1 passed check\n'\''; exit 2'
expect_status 2 "gate rejects collection-error count words without a formal pytest summary"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate does not treat count words in an error message as test execution"

run_case gate-zero-tests bash "$GATE" \
  --log "$TMP_ROOT/gate-zero-tests.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 0 tests in 0.000s\nOK\n'\'''
expect_nonzero "baseline gate fails closed when unittest reports zero tests"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate reports that zero tests were executed"

run_case gate-unittest-skipped-only bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-skipped-only.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK (skipped=1)\n'\'''
expect_nonzero "baseline gate rejects an exit-zero skipped-only unittest run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate subtracts unittest result-line skips from the reported test count"

run_case gate-skipped-only bash "$GATE" \
  --log "$TMP_ROOT/gate-skipped-only.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''============================= 1 skipped in 0.10s =============================\n'\'''
expect_nonzero "baseline gate rejects an exit-zero skipped-only pytest run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate explains the skipped-only baseline failure"

run_case gate-baseline-empty bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-empty.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c ':'
expect_nonzero "baseline gate rejects exit-zero empty output"
expect_output "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only" \
  "gate fails closed on an unrecognized baseline runner"

run_case purpose-default bash "$GATE" \
  --log "$TMP_ROOT/purpose-default.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "default --purpose is accepted"
expect_output "purpose: unspecified" "default purpose is unspecified"

run_case purpose-unit-final bash "$GATE" --purpose unit-final \
  --log "$TMP_ROOT/purpose-unit-final.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "--purpose unit-final is accepted"
expect_output "purpose: unit-final" "unit-final purpose is printed in the banner"

run_case purpose-baseline-generation bash "$GATE" --purpose baseline-generation \
  --log "$TMP_ROOT/purpose-baseline-generation.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "--purpose baseline-generation is accepted"
expect_output "purpose: baseline-generation" "baseline-generation purpose is printed in the banner"

run_case purpose-focused bash "$GATE" --purpose focused \
  --log "$TMP_ROOT/purpose-focused.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "--purpose focused is accepted"
expect_output "purpose: focused" "focused purpose is printed in the banner"

run_case purpose-unspecified bash "$GATE" --purpose unspecified \
  --log "$TMP_ROOT/purpose-unspecified.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "--purpose unspecified is accepted"
expect_output "purpose: unspecified" "explicit unspecified purpose is printed in the banner"

run_case purpose-invalid bash "$GATE" --purpose nope \
  --log "$TMP_ROOT/purpose-invalid.log" -- bash -c ':'
expect_status 2 "invalid --purpose is a usage error"
expect_output "--purpose must be" "invalid --purpose explains the enum"

BIND_CLEAN="$TMP_ROOT/bind-clean"
init_git_repo "$BIND_CLEAN"
run_case_in_dir bind-clean "$BIND_CLEAN" env LOOP_TREE_OID="$TREE_OID" bash "$GATE" \
  --log "$TMP_ROOT/bind-clean.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "clean binding keeps a green pass-through verdict"
expect_output "binding: clean" "committed unchanged tree is binding=clean"

BIND_DIRTY="$TMP_ROOT/bind-dirty"
init_git_repo "$BIND_DIRTY"
printf 'dirty\n' > "$BIND_DIRTY/file.txt"
run_case_in_dir bind-dirty "$BIND_DIRTY" env LOOP_TREE_OID="$TREE_OID" bash "$GATE" \
  --log "$TMP_ROOT/bind-dirty.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "dirty binding does not change the verdict"
expect_output "binding: dirty" "uncommitted tracked change is binding=dirty"

BIND_CHANGED="$TMP_ROOT/bind-changed"
init_git_repo "$BIND_CHANGED"
run_case_in_dir bind-changed "$BIND_CHANGED" env LOOP_TREE_OID="$TREE_OID" bash "$GATE" \
  --log "$TMP_ROOT/bind-changed.log" -- \
  bash -c 'printf '\''changed\n'\'' > file.txt; printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "changed binding does not change the verdict"
expect_output "binding: changed" "a suite that mutates the tree is binding=changed"

BIND_NONGIT="$TMP_ROOT/bind-nongit"
mkdir -p "$BIND_NONGIT"
run_case_in_dir bind-nongit "$BIND_NONGIT" env LOOP_TREE_OID="$TREE_OID" bash "$GATE" \
  --log "$TMP_ROOT/bind-nongit.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "unavailable binding does not change the verdict"
expect_output "binding: unavailable" "a non-git cwd is binding=unavailable"
expect_output "binding reason:" "unavailable binding records a reason"

TREE_OID_STUB="$TMP_ROOT/tree-oid-exit3"
printf '%s\n' '#!/usr/bin/env bash' 'echo "tree-oid: binding unavailable" >&2' 'exit 3' \
  > "$TREE_OID_STUB"
chmod 755 "$TREE_OID_STUB"
BIND_TREE3="$TMP_ROOT/bind-tree3"
init_git_repo "$BIND_TREE3"
run_case_in_dir bind-tree3 "$BIND_TREE3" env LOOP_TREE_OID="$TREE_OID_STUB" bash "$GATE" \
  --log "$TMP_ROOT/bind-tree3.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "tree-oid exit 3 does not change the verdict"
expect_output "binding: unavailable" "tree-oid exit 3 is binding=unavailable"
expect_output "binding reason: tree-oid: binding unavailable" \
  "tree-oid exit 3 records the designed unavailable reason"

if [[ -n "$JOURNAL" ]]; then
  JOURNAL_WS="$TMP_ROOT/journal-ws"
  init_git_repo "$JOURNAL_WS"
  env HOME="$HOME" "$JOURNAL" begin-run --workspace "$JOURNAL_WS" \
    > "$TMP_ROOT/journal-ws.begin-run"

  run_case_in_dir journal-strict-green "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --strict --purpose unit-final \
    --log "$TMP_ROOT/journal-strict-green.log" -- \
    bash -c 'printf '\''Ran 2 tests in 0.001s\nOK\n'\'''
  expect_status 0 "strict green journal case stays green"
  expect_output "RESULT: gate green" "strict green RESULT line is unchanged"
  expect_gate_result "$JOURNAL_WS" strict unit-final clean \
    "strict green emits gate.result policy=strict purpose=unit-final binding=clean"

  run_case_in_dir journal-strict-red "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --strict --purpose focused \
    --log "$TMP_ROOT/journal-strict-red.log" -- \
    bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
  expect_status 1 "strict red journal case stays red"
  expect_output "RESULT: gate RED — do not publish until resolved or explained" \
    "strict red RESULT line is unchanged"
  expect_gate_result "$JOURNAL_WS" strict focused clean \
    "strict red emits gate.result policy=strict purpose=focused binding=clean"

  run_case_in_dir journal-baseline-green "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --baseline "$EMPTY_BASELINE" --purpose baseline-generation \
    --log "$TMP_ROOT/journal-baseline-green.log" -- \
    bash -c 'printf '\''=========================== 2 passed in 0.10s ===========================\n'\'''
  expect_status 0 "baseline green journal case stays green"
  expect_output "RESULT: gate green" "baseline green RESULT line is unchanged"
  expect_gate_result "$JOURNAL_WS" baseline baseline-generation clean \
    "baseline green emits gate.result policy=baseline purpose=baseline-generation binding=clean"

  run_case_in_dir journal-plain-green "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --purpose unspecified \
    --log "$TMP_ROOT/journal-plain-green.log" -- \
    bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
  expect_status 0 "pass-through green journal case stays green"
  expect_output "RESULT: gate green (pass-through: exit code only)" \
    "pass-through green RESULT line is unchanged"
  expect_gate_result "$JOURNAL_WS" passthrough unspecified clean \
    "pass-through green emits gate.result policy=passthrough binding=clean"

  run_case_in_dir journal-plain-red "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --purpose unspecified \
    --log "$TMP_ROOT/journal-plain-red.log" -- \
    bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
  expect_status 1 "pass-through red journal case stays red"
  expect_output "RESULT: gate RED — do not publish until resolved or explained" \
    "pass-through red RESULT line is unchanged"
  expect_gate_result "$JOURNAL_WS" passthrough unspecified clean \
    "pass-through red emits gate.result policy=passthrough binding=clean"

  FAIL_JOURNAL="$TMP_ROOT/fail-journal"
  printf '%s\n' '#!/usr/bin/env bash' 'echo journal-stub-failed >&2' 'exit 6' \
    > "$FAIL_JOURNAL"
  chmod 755 "$FAIL_JOURNAL"
  run_case_in_dir journal-failing-helper "$JOURNAL_WS" \
    env HOME="$HOME" LOOP_JOURNAL="$FAIL_JOURNAL" LOOP_TREE_OID="$TREE_OID" \
    bash "$GATE" --strict \
    --log "$TMP_ROOT/journal-failing-helper.log" -- \
    bash -c 'printf '\''Ran 2 tests in 0.001s\nOK\n'\'''
  expect_status 0 "a failing journal helper does not change a green verdict"
  expect_output "RESULT: gate green" "failing helper keeps the RESULT line"
  expect_output "warning: loop-journal gate.result failed" \
    "a failing journal helper prints one warning"
else
  skip_checks \
    "strict green emits gate.result policy=strict purpose=unit-final binding=clean" \
    "strict red emits gate.result policy=strict purpose=focused binding=clean" \
    "baseline green emits gate.result policy=baseline purpose=baseline-generation binding=clean" \
    "pass-through green emits gate.result policy=passthrough binding=clean" \
    "pass-through red emits gate.result policy=passthrough binding=clean" \
    "a failing journal helper prints one warning"
fi

SCRATCH_GATE_DIR="$TMP_ROOT/scratch-gate"
mkdir -p "$SCRATCH_GATE_DIR"
cp "$GATE" "$SCRATCH_GATE_DIR/run-gate.sh"
chmod 755 "$SCRATCH_GATE_DIR/run-gate.sh"
run_case helper-missing env -u LOOP_JOURNAL bash "$SCRATCH_GATE_DIR/run-gate.sh" \
  --strict --log "$TMP_ROOT/helper-missing.log" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\nOK\n'\'''
expect_status 0 "helper-missing copy behaves like today"
expect_output "RESULT: gate green" "helper-missing copy keeps the green RESULT line"
expect_no_output "warning: loop-journal" "helper-missing copy is a silent journal no-op"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
