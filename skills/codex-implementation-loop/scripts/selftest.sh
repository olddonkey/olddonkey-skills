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

# Resolution fallbacks must be testable without discovering a real Claude CLI
# from the developer machine. Populate an isolated PATH with only the commands
# the dispatcher needs, deliberately omitting `claude`.
NO_CLAUDE_BIN="$TMP_ROOT/no-claude-bin"
mkdir -p "$NO_CLAUDE_BIN"
for required_tool in awk bash cat cut find grep head python3 sed sort tail tr; do
  REQUIRED_TOOL_PATH="$(command -v "$required_tool" 2>/dev/null || true)"
  [[ -n "$REQUIRED_TOOL_PATH" ]] || {
    printf 'selftest: required tool not found: %s\n' "$required_tool" >&2
    exit 1
  }
  ln -s "$REQUIRED_TOOL_PATH" "$NO_CLAUDE_BIN/$required_tool" || exit 1
done
ln -s "$BIN_DIR/node" "$NO_CLAUDE_BIN/node" || exit 1
ln -s "$BIN_DIR/codex" "$NO_CLAUDE_BIN/codex" || exit 1
NO_CLAUDE_PATH="$NO_CLAUDE_BIN"

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
expect_output "model : config-model (config.toml top-level; active profile overrides not resolved)" \
  "dispatch reads and qualifies the CODEX_HOME config display"

# Keys inside [profiles.*] tables are not top-level config and must not be
# displayed as the effective value; the active profile is disclosed instead.
PROFILE_CONFIG_DIR="$TMP_ROOT/codex-home-profile"
mkdir -p "$PROFILE_CONFIG_DIR"
write_lines "$PROFILE_CONFIG_DIR/config.toml" \
  'profile = "speedy"' \
  '[profiles.speedy]' \
  'model = "profile-model"'
run_case dispatch-profile-table env \
  HOME="$HOME_DIR" CODEX_HOME="$PROFILE_CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/profile-table.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort high
expect_status 0 "dispatch runs with a profile-only config"
expect_output "model : <Codex CLI default>" \
  "dispatch does not display a profile-table key as effective config"
expect_output "profile: speedy active in config.toml" \
  "dispatch discloses the active profile"

# MCP servers / app connectors run outside the workspace-write sandbox, so an
# implement dispatch fails closed until the exposure is acknowledged once.
TOOLS_CONFIG_DIR="$TMP_ROOT/codex-home-tools"
mkdir -p "$TOOLS_CONFIG_DIR"
write_lines "$TOOLS_CONFIG_DIR/config.toml" \
  'model = "config-model"' \
  '[mcp_servers.filewriter]' \
  'command = "definitely-not-run"'
run_case dispatch-external-tools-blocked env \
  HOME="$HOME_DIR" CODEX_HOME="$TOOLS_CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/tools-blocked.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort high
expect_status 4 "dispatch fails closed when Codex config enables external tools"
expect_output "[mcp_servers.filewriter]" \
  "dispatch names the enabled external tool section"

run_case dispatch-external-tools-acknowledged env \
  HOME="$HOME_DIR" CODEX_HOME="$TOOLS_CONFIG_DIR" \
  CODEX_LOOP_ALLOW_EXTERNAL_TOOLS=1 \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/tools-ack.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort high
expect_status 0 "dispatch proceeds after explicit external-tools acknowledgment"
expect_output "note  : external tools enabled in Codex config" \
  "dispatch still discloses acknowledged external tools"

run_case dispatch-external-tools-readonly env \
  HOME="$HOME_DIR" CODEX_HOME="$TOOLS_CONFIG_DIR" \
  CODEX_LOOP_COMPANION="$LIMITED_COMPANION" \
  SELFTEST_NODE_LOG="$TMP_ROOT/tools-ro.node" PATH="$TEST_PATH" \
  bash "$DISPATCH" --prompt selftest --effort high --read-only
expect_status 0 "read-only dispatch is not blocked by external tools"

# The Claude CLI view is preferred and resolves enabled entries with
# managed > local > project > user precedence, independent of JSON list order.
CLAUDE_BIN="$TMP_ROOT/claude-bin"
CLAUDE_DISABLED_ROOT="$TMP_ROOT/claude-disabled"
CLAUDE_USER_ROOT="$TMP_ROOT/claude-user"
CLAUDE_PROJECT_ROOT="$TMP_ROOT/claude-project"
CLAUDE_LOCAL_ROOT="$TMP_ROOT/claude-local"
CLAUDE_MANAGED_ROOT="$TMP_ROOT/claude-managed"
mkdir -p "$CLAUDE_BIN" \
  "$CLAUDE_DISABLED_ROOT/scripts" "$CLAUDE_USER_ROOT/scripts" \
  "$CLAUDE_PROJECT_ROOT/scripts" "$CLAUDE_LOCAL_ROOT/scripts" \
  "$CLAUDE_MANAGED_ROOT/scripts"
write_lines "$CLAUDE_BIN/claude" \
  '#!/usr/bin/env bash' \
  '[[ "$*" == "plugin list --json" ]] || exit 64' \
  'printf '\''%s\n'\'' "${SELFTEST_CLAUDE_JSON:-}"'
chmod +x "$CLAUDE_BIN/claude"
for companion_root in \
  "$CLAUDE_DISABLED_ROOT" "$CLAUDE_USER_ROOT" \
  "$CLAUDE_PROJECT_ROOT" "$CLAUDE_LOCAL_ROOT" \
  "$CLAUDE_MANAGED_ROOT"; do
  write_lines "$companion_root/scripts/codex-companion.mjs" '// --effort <low|high>'
done
CLAUDE_PLUGIN_JSON="$(printf \
  '[{"id":"codex@openai-codex","scope":"local","enabled":false,"installPath":"%s"},{"id":"codex@openai-codex","scope":"user","enabled":true,"installPath":"%s"},{"id":"codex@openai-codex","scope":"project","enabled":true,"installPath":"%s"},{"id":"codex@openai-codex","scope":"local","enabled":true,"installPath":"%s"},{"id":"codex@openai-codex","scope":"managed","enabled":true,"installPath":"%s"}]' \
  "$CLAUDE_DISABLED_ROOT" "$CLAUDE_USER_ROOT" "$CLAUDE_PROJECT_ROOT" \
  "$CLAUDE_LOCAL_ROOT" "$CLAUDE_MANAGED_ROOT")"
CLAUDE_NODE_LOG="$TMP_ROOT/claude-list.node"
run_case dispatch-claude-list env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" CODEX_LOOP_COMPANION="" \
  SELFTEST_CLAUDE_JSON="$CLAUDE_PLUGIN_JSON" SELFTEST_NODE_LOG="$CLAUDE_NODE_LOG" \
  PATH="$CLAUDE_BIN:$NO_CLAUDE_PATH" \
  bash "$DISPATCH" --prompt selftest --effort low
expect_status 0 "dispatch accepts the enabled managed install from the Claude CLI"
expect_first_line "$CLAUDE_NODE_LOG" "$CLAUDE_MANAGED_ROOT/scripts/codex-companion.mjs" \
  "dispatch applies managed > local > project > user precedence to the Claude CLI list"
expect_output "(claude plugin list)" "dispatch reports Claude-CLI resolution"

# With `claude` absent, installed_plugins.json remains authoritative over a
# newer cache entry. Disabled entries are skipped and managed beats user.
ACTIVE_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/1.0.6"
STALE_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/9.9.9"
DISABLED_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/0.0.1"
MANAGED_ROOT="$HOME_DIR/.claude/plugins/cache/openai-codex/codex/managed"
mkdir -p \
  "$ACTIVE_ROOT/scripts" "$STALE_ROOT/scripts" "$DISABLED_ROOT/scripts" \
  "$MANAGED_ROOT/scripts" "$HOME_DIR/.claude/plugins"
write_lines "$ACTIVE_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
write_lines "$STALE_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
write_lines "$DISABLED_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
write_lines "$MANAGED_ROOT/scripts/codex-companion.mjs" '// --effort <low|high>'
printf '{"plugins":{"codex@openai-codex":[{"scope":"user","enabled":true,"installPath":"%s"},{"scope":"local","enabled":false,"installPath":"%s"},{"scope":"project","installPath":"%s"},{"scope":"managed","enabled":true,"installPath":"%s"}]}}\n' \
  "$STALE_ROOT" "$DISABLED_ROOT" "$ACTIVE_ROOT" "$MANAGED_ROOT" \
  > "$HOME_DIR/.claude/plugins/installed_plugins.json"
ACTIVE_NODE_LOG="$TMP_ROOT/active.node"
run_case dispatch-active env \
  HOME="$HOME_DIR" CODEX_HOME="$CONFIG_DIR" CODEX_LOOP_COMPANION="" \
  SELFTEST_NODE_LOG="$ACTIVE_NODE_LOG" PATH="$NO_CLAUDE_PATH" \
  bash "$DISPATCH" --prompt selftest --effort low
expect_status 0 "dispatch falls through cleanly when the Claude CLI is absent"
expect_first_line "$ACTIVE_NODE_LOG" "$MANAGED_ROOT/scripts/codex-companion.mjs" \
  "dispatch applies managed-over-user precedence and skips a disabled local install"
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
  SELFTEST_NODE_LOG="$MARKET_NODE_LOG" PATH="$NO_CLAUDE_PATH" \
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
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 7'
expect_status 0 "gate exits zero when unittest failures match baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate reports baseline-clean unittest failures"

run_case gate-unittest-mixed bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-mixed.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 3 tests in 0.001s\nFAILED (failures=1, skipped=2)\n'\''; exit 7'
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

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
