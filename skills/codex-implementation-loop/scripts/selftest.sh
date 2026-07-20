#!/usr/bin/env bash
# Fast, dependency-free regression checks for codex-dispatch.sh and run-gate.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/codex-dispatch.sh"
GATE="$SCRIPT_DIR/run-gate.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-loop-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

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

expect_first_line() { # $1=file $2=expected $3=description
  local actual=""
  [[ -f "$1" ]] && IFS= read -r actual < "$1"
  if [[ "$actual" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected '$2', got '$actual')"
  fi
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

write_lines() { # $1=path, remaining args=lines
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

BIN_DIR="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
CONFIG_DIR="$TMP_ROOT/codex-home"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$CONFIG_DIR"

write_lines "$BIN_DIR/node" \
  '#!/usr/bin/env bash' \
  ': "${SELFTEST_NODE_LOG:?SELFTEST_NODE_LOG is required}"' \
  'printf '\''%s\n'\'' "$@" > "$SELFTEST_NODE_LOG"'
write_lines "$BIN_DIR/codex" \
  '#!/usr/bin/env bash' \
  'printf '\''codex-selftest 0.0.0\n'\'''
chmod +x "$BIN_DIR/node" "$BIN_DIR/codex"
TEST_PATH="$BIN_DIR:$PATH"

NO_USAGE_COMPANION="$TMP_ROOT/no-usage/codex-companion.mjs"
LIMITED_COMPANION="$TMP_ROOT/override/codex-companion.mjs"
mkdir -p "$(dirname "$NO_USAGE_COMPANION")" "$(dirname "$LIMITED_COMPANION")"
write_lines "$NO_USAGE_COMPANION" '// companion fixture without an effort usage string'
write_lines "$LIMITED_COMPANION" '// usage: --effort <low|high>'

# A grep miss must use the built-in effort snapshot, not terminate under -e.
run_case dispatch-snapshot env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$NO_USAGE_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/snapshot.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort definitely-invalid
expect_status 2 "dispatch grep miss reaches effort validation"
expect_output "this companion accepts: none minimal low medium high xhigh" \
  "dispatch grep miss uses fallback effort snapshot"

# The explicit override wins, rejects values outside its live list, and runs
# through the selected file for a valid value.
run_case dispatch-override-invalid env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/override-invalid.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort medium
expect_status 2 "dispatch override rejects an invalid live effort"
expect_output "this companion accepts: low high" \
  "dispatch override reads its companion's effort list"

write_lines "$CONFIG_DIR/config.toml" \
  'model = "config-model"' \
  'service_tier = "fast"'
OVERRIDE_NODE_LOG="$TMP_ROOT/override-valid.node"
run_case dispatch-override-valid env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$OVERRIDE_NODE_LOG" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort high
expect_status 0 "dispatch override accepts a valid effort"
expect_first_line "$OVERRIDE_NODE_LOG" "$LIMITED_COMPANION" \
  "dispatch sends the explicit override to node"
expect_output "companion: $LIMITED_COMPANION (explicit override)" \
  "dispatch reports explicit override resolution"
expect_output "model : config-model (from config.toml; profiles/overrides not resolved)" \
  "dispatch reads and qualifies the CODEX_HOME config display"

# installed_plugins.json is authoritative over a newer cache path, and a user
# entry wins over an earlier non-user entry when multiple installs are listed.
ACTIVE_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/1.0.6"
STALE_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/9.9.9"
mkdir -p "$ACTIVE_ROOT/scripts" "$STALE_ROOT/scripts" "$HOME_DIR/.claude/plugins"
write_lines "$ACTIVE_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
write_lines "$STALE_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
printf '{"plugins":{"codex@openai-codex":[{"scope":"project","installPath":"%s"},{"scope":"user","installPath":"%s"}]}}\n' \
  "$STALE_ROOT" "$ACTIVE_ROOT" > "$HOME_DIR/.claude/plugins/installed_plugins.json"
ACTIVE_NODE_LOG="$TMP_ROOT/active.node"
run_case dispatch-active env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" CODEX_LOOP_COMPANION="" \
  SELFTEST_NODE_LOG="$ACTIVE_NODE_LOG" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort low
expect_status 0 "dispatch accepts the active installed companion"
expect_first_line "$ACTIVE_NODE_LOG" "$ACTIVE_ROOT/scripts/codex-companion.mjs" \
  "dispatch prefers the active user install over a newer cache entry"
expect_output "(active install)" "dispatch reports active-install resolution"

# A missing cache plus malformed plugin manifest must still reach marketplaces.
MARKET_HOME="$TMP_ROOT/market-home"
MARKET_COMPANION="$MARKET_HOME/.claude/plugins/marketplaces/codex/scripts/codex-companion.mjs"
mkdir -p "$(dirname "$MARKET_COMPANION")" "$MARKET_HOME/.claude/plugins"
write_lines "$MARKET_COMPANION" '// --effort <low|high>'
write_lines "$MARKET_HOME/.claude/plugins/installed_plugins.json" '{not valid json'
MARKET_NODE_LOG="$TMP_ROOT/market.node"
run_case dispatch-marketplace env \
  HOME="$MARKET_HOME" CODEX_HOME="$CONFIG_DIR" CODEX_LOOP_COMPANION="" \
  SELFTEST_NODE_LOG="$MARKET_NODE_LOG" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort low
expect_status 0 "dispatch reaches marketplace fallback when cache is missing"
expect_first_line "$MARKET_NODE_LOG" "$MARKET_COMPANION" \
  "dispatch sends the marketplace companion to node"
expect_output "(marketplace fallback)" "dispatch reports marketplace resolution"

# Without a baseline, run-gate keeps the suite's pass-through behavior.
run_case gate-pass bash "$GATE" --log "$TMP_ROOT/gate-pass.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "gate passes a successful command"
expect_output "RESULT: gate green" "gate prints its normal green result"

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
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 7'
expect_status 0 "gate exits zero when unittest failures match baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate reports baseline-clean unittest failures"

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
run_case gate-pytest-match bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-match.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: new detail\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate recognizes and baselines a pytest FAILED identifier"
expect_output "--- 1 failure/error header(s) ---" \
  "gate extracts the pytest FAILED short-summary line"

CRASH_BASELINE="$TMP_ROOT/crash-baseline.log"
write_lines "$CRASH_BASELINE" 'ImportError: same crash text'
run_case gate-crash bash "$GATE" \
  --log "$TMP_ROOT/gate-crash.log" --baseline "$CRASH_BASELINE" -- \
  bash -c 'printf '\''ImportError: same crash text\n'\''; exit 9'
expect_status 9 "gate stays nonzero when no failure identifier is parseable"
expect_output "RESULT: gate RED — nonzero exit with no parseable failures (crash/collection error?)" \
  "gate explains an unparseable nonzero exit"

EMPTY_BASELINE="$TMP_ROOT/empty-baseline.log"
: > "$EMPTY_BASELINE"
run_case gate-zero-tests bash "$GATE" \
  --log "$TMP_ROOT/gate-zero-tests.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 0 tests in 0.000s\nOK\n'\'''
expect_nonzero "baseline gate fails closed when unittest reports zero tests"
expect_output "RESULT: gate RED — no tests ran" \
  "gate reports the zero-test failure"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
