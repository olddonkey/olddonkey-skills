#!/usr/bin/env bash
# Isolated compatibility checks for the one-release forwarding shims.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LOOP_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
LEGACY_SCRIPTS="$LOOP_ROOT/scripts"
TMP_ROOT_RAW="$(mktemp -d "$SCRIPT_DIR/.shim-selftest.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf 'ok %d - %s\n' "$CHECKS" "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2; }

write_target() { # $1=path
  mkdir -p "$(dirname -- "$1")"
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
set -u
: "${SHIM_TARGET_LOG:?}"
printf '%s\0' "$@" > "$SHIM_TARGET_LOG"
case "${SHIM_TARGET_ACTION:-ok}" in
  ok) exit 0 ;;
  exit) exit 23 ;;
  signal) kill -TERM "$$" ;;
esac
exit 90
STUB
  chmod 755 "$1"
}

expect_args() { # $1=log $2=description; remaining=expected argv
  local log="$1" description="$2"
  shift 2
  if python3 - "$log" "$@" <<'PY'
import sys
path, *expected = sys.argv[1:]
actual = [item.decode("utf-8") for item in open(path, "rb").read().split(b"\0") if item]
raise SystemExit(0 if actual == expected else 1)
PY
  then pass "$description"; else fail "$description"; fi
}

expect_deprecation_lines() { # $1=stderr $2=count $3=description
  local count
  count="$(LC_ALL=C grep -c '^deprecated: ' "$1" || true)"
  if [[ "$count" == "$2" ]] && LC_ALL=C grep -q 'release 0.5.0' "$1"; then
    pass "$3"
  else
    fail "$3"
  fi
}

test_regular_shim() { # $1=old basename $2=target relative path
  local basename="$1" target_relative="$2"
  local root="$TMP_ROOT/${basename%.sh}"
  local shim="$root/scripts/$basename"
  local target="$root/$target_relative"
  local log="$root/target.log" stderr="$root/stderr"
  mkdir -p "$root/scripts"
  cp "$LEGACY_SCRIPTS/$basename" "$shim"
  chmod 755 "$shim"
  write_target "$target"

  SHIM_TARGET_LOG="$log" "$shim" alpha 'two words' 2> "$stderr"
  expect_args "$log" "$basename preserves argv" alpha 'two words'
  expect_deprecation_lines "$stderr" 1 "$basename emits exactly one removal-release deprecation"

  set +e
  SHIM_TARGET_ACTION=exit SHIM_TARGET_LOG="$log" "$shim" alpha 2> "$stderr"
  local status=$?
  set -e
  if [[ $status -eq 23 ]]; then pass "$basename preserves target exit status"; else fail "$basename preserves target exit status (got $status)"; fi

  set +e
  SHIM_TARGET_ACTION=signal SHIM_TARGET_LOG="$log" "$shim" alpha 2> "$stderr"
  status=$?
  set -e
  if [[ $status -eq 143 ]]; then pass "$basename preserves target signal status"; else fail "$basename preserves target signal status (got $status)"; fi
}

test_regular_shim codex-dispatch.sh backends/codex/dispatch.sh
test_regular_shim grok-dispatch.sh backends/grok/dispatch.sh
test_regular_shim cursor-dispatch.sh backends/cursor/dispatch.sh
test_regular_shim grok-verify-worktree.sh backends/grok/verify-worktree.sh
test_regular_shim grok-selftest.sh backends/grok/selftest.sh
test_regular_shim cursor-selftest.sh backends/cursor/selftest.sh

# The integration shim has the only intentional argv translation.
INTEGRATION_ROOT="$TMP_ROOT/integration"
mkdir -p "$INTEGRATION_ROOT/scripts"
cp "$LEGACY_SCRIPTS/integration-test.sh" "$INTEGRATION_ROOT/scripts/integration-test.sh"
chmod 755 "$INTEGRATION_ROOT/scripts/integration-test.sh"
write_target "$INTEGRATION_ROOT/tests/integration-test.sh"
INTEGRATION_LOG="$INTEGRATION_ROOT/target.log"
INTEGRATION_STDERR="$INTEGRATION_ROOT/stderr"

SHIM_TARGET_LOG="$INTEGRATION_LOG" "$INTEGRATION_ROOT/scripts/integration-test.sh" --backend grok --require codex 2> "$INTEGRATION_STDERR"
expect_args "$INTEGRATION_LOG" "integration shim preserves non-all selectors" --backend grok --require codex
expect_deprecation_lines "$INTEGRATION_STDERR" 1 "integration shim emits one deprecation without translation"

SHIM_TARGET_LOG="$INTEGRATION_LOG" "$INTEGRATION_ROOT/scripts/integration-test.sh" 2> "$INTEGRATION_STDERR"
expect_args "$INTEGRATION_LOG" "bare legacy integration call selects only grok and cursor" --backend grok --backend cursor
if [[ "$(LC_ALL=C grep -c '^compatibility: translated ' "$INTEGRATION_STDERR" || true)" == 1 ]]; then pass "bare integration translation emits one compatibility line"; else fail "bare integration translation emits one compatibility line"; fi

SHIM_TARGET_LOG="$INTEGRATION_LOG" "$INTEGRATION_ROOT/scripts/integration-test.sh" --backend all --require codex 2> "$INTEGRATION_STDERR"
expect_args "$INTEGRATION_LOG" "explicit legacy all expands to two repeatable selectors" --backend grok --backend cursor --require codex
if [[ "$(LC_ALL=C grep -c '^compatibility: translated ' "$INTEGRATION_STDERR" || true)" == 1 ]]; then pass "explicit all translation emits one compatibility line"; else fail "explicit all translation emits one compatibility line"; fi

set +e
SHIM_TARGET_ACTION=exit SHIM_TARGET_LOG="$INTEGRATION_LOG" "$INTEGRATION_ROOT/scripts/integration-test.sh" --backend grok 2> "$INTEGRATION_STDERR"
STATUS=$?
set -e
if [[ $STATUS -eq 23 ]]; then pass "integration shim preserves target exit status"; else fail "integration shim preserves target exit status (got $STATUS)"; fi
set +e
SHIM_TARGET_ACTION=signal SHIM_TARGET_LOG="$INTEGRATION_LOG" "$INTEGRATION_ROOT/scripts/integration-test.sh" --backend grok 2> "$INTEGRATION_STDERR"
STATUS=$?
set -e
if [[ $STATUS -eq 143 ]]; then pass "integration shim preserves target signal status"; else fail "integration shim preserves target signal status (got $STATUS)"; fi

# The legacy aggregate must execute both split suites and stop on either red.
COMPOSITE_ROOT="$TMP_ROOT/composite"
mkdir -p "$COMPOSITE_ROOT/scripts" "$COMPOSITE_ROOT/backends/codex" "$COMPOSITE_ROOT/tests"
COMPOSITE_SHIM="$COMPOSITE_ROOT/scripts"/selftest.sh
cp "$LEGACY_SCRIPTS/selftest.sh" "$COMPOSITE_SHIM"
chmod 755 "$COMPOSITE_SHIM"
cat > "$COMPOSITE_ROOT/backends/codex/selftest.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${COMPOSITE_CODEX_LOG:?}"
case "${COMPOSITE_FAIL:-}" in codex-exit) exit 23 ;; codex-signal) kill -TERM "$$" ;; esac
STUB
cat > "$COMPOSITE_ROOT/tests/gate-selftest.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${COMPOSITE_GATE_LOG:?}"
case "${COMPOSITE_FAIL:-}" in gate-exit) exit 23 ;; gate-signal) kill -TERM "$$" ;; esac
STUB
chmod 755 "$COMPOSITE_ROOT/backends/codex/selftest.sh" "$COMPOSITE_ROOT/tests/gate-selftest.sh"
COMPOSITE_CODEX_LOG="$COMPOSITE_ROOT/codex.log" COMPOSITE_GATE_LOG="$COMPOSITE_ROOT/gate.log" \
  "$COMPOSITE_SHIM" alpha 'two words' 2> "$COMPOSITE_ROOT/stderr"
expect_args "$COMPOSITE_ROOT/codex.log" "composite passes argv to Codex suite" alpha 'two words'
expect_args "$COMPOSITE_ROOT/gate.log" "composite passes argv to gate suite" alpha 'two words'
expect_deprecation_lines "$COMPOSITE_ROOT/stderr" 1 "composite emits exactly one removal-release deprecation"

set +e
COMPOSITE_FAIL=codex-exit COMPOSITE_CODEX_LOG="$COMPOSITE_ROOT/codex.log" COMPOSITE_GATE_LOG="$COMPOSITE_ROOT/gate.log" \
  "$COMPOSITE_SHIM" 2> "$COMPOSITE_ROOT/stderr"
STATUS=$?
set -e
if [[ $STATUS -eq 23 ]]; then pass "composite fails with the Codex suite status"; else fail "composite fails with the Codex suite status (got $STATUS)"; fi
set +e
COMPOSITE_FAIL=gate-signal COMPOSITE_CODEX_LOG="$COMPOSITE_ROOT/codex.log" COMPOSITE_GATE_LOG="$COMPOSITE_ROOT/gate.log" \
  "$COMPOSITE_SHIM" 2> "$COMPOSITE_ROOT/stderr"
STATUS=$?
set -e
if [[ $STATUS -eq 143 ]]; then pass "composite preserves the gate suite signal status"; else fail "composite preserves the gate suite signal status (got $STATUS)"; fi

if [[ $FAILURES -gt 0 ]]; then
  printf 'shim-selftest: FAIL (%d of %d checks failed)\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi
printf 'shim-selftest: PASS (%d checks)\n' "$CHECKS"
