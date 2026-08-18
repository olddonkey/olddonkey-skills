#!/usr/bin/env bash
# A stub cannot show that a real CLI's sandbox enforces anything; that is
# tests/integration-test.sh's job. These deliberately broken adapters prove
# that each shared assertion in contract-core.sh is live and fails by name.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CORE="$SCRIPT_DIR/contract-core.sh"
TMP_ROOT_RAW="$(mktemp -d "$SCRIPT_DIR/.contract-negative.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

RULES="help prompt-file prompt-inline prompt-precedence prompt-required dash-prompt missing-values repeated-flags unknown-flags readonly-alias background exit-status signal-status env-namespace summary-fields journal-missing journal-start-refusal journal-events journal-unattributed journal-readonly-mode"
CHECKS=0
FAILURES=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
}

write_broken_stub() { # $1=rule $2=path
  local rule="$1" path="$2"
  printf '%s\n' '#!/usr/bin/env bash' "BROKEN_RULE='$rule'" > "$path"
  cat >> "$path" <<'STUB'
set -u
: "${CONTRACT_TMPDIR:?}"
: "${CONTRACT_CASE:?}"

if [[ "$BROKEN_RULE" == "help" ]]; then
  printf '%s\n' '--prompt'
  exit 0
fi
if [[ "$BROKEN_RULE" == "prompt-file" || "$BROKEN_RULE" == "prompt-inline" ]]; then
  exit 2
fi
if [[ "$BROKEN_RULE" == "prompt-required" ]]; then
  exit 0
fi
if [[ "$BROKEN_RULE" == "dash-prompt" ]]; then
  exit 2
fi
if [[ "$BROKEN_RULE" == "missing-values" ]]; then
  exit 0
fi
if [[ "$BROKEN_RULE" == "unknown-flags" ]]; then
  exit 0
fi
if [[ "$BROKEN_RULE" == "background" ]]; then
  exit 0
fi
if [[ "$BROKEN_RULE" == "exit-status" || "$BROKEN_RULE" == "signal-status" ]]; then
  exit 0
fi
if [[ "$BROKEN_RULE" == "journal-missing" ]]; then
  mkdir -p "${HOME:?}/.config/olddonkey-loop/journal/created-by-stub"
fi
if [[ "$BROKEN_RULE" == "journal-start-refusal" ]]; then
  : "${CONTRACT_TMPDIR:?}"
  : "${CONTRACT_CASE:?}"
  printf '%s' 'journal' > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-prompt"
  exit 0
fi

prompt=""
model="<none>"
mode="implement"
first_prompt=""
first_model=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--prompt" ]]; then
    [[ -n "$first_prompt" ]] || first_prompt="$argument"
    prompt="$argument"
  elif [[ "$previous" == "--prompt-file" ]]; then
    prompt="$(cat "$argument")"
  elif [[ "$previous" == "--model" ]]; then
    [[ -n "$first_model" ]] || first_model="$argument"
    model="$argument"
  fi
  case "$argument" in
    --read-only) mode="read-only" ;;
    --investigate)
      if [[ "$BROKEN_RULE" == "readonly-alias" ]]; then mode="implement"; else mode="read-only"; fi
      ;;
  esac
  previous="$argument"
done

case "$BROKEN_RULE" in
  prompt-precedence) prompt="losing inline prompt" ;;
  repeated-flags) prompt="$first_prompt"; model="$first_model" ;;
  env-namespace)
    if [[ "$CONTRACT_CASE" == "env-own" ]]; then
      model="contract-own-model"
    else
      model="foreign-poison-model"
    fi
    ;;
esac

printf '%s' "$prompt" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-prompt"
printf '%s\n' "$model" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-model"
printf '%s\n' "$mode" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-mode"

if [[ "$BROKEN_RULE" == "summary-fields" ]]; then
  printf '%s\n' 'workspace: deliberately-incomplete'
  exit 0
fi

printf '%s\n' \
  'workspace: contract-negative' \
  'codex version: broken-stub' \
  'model: broken (stub)' \
  'effort: broken (stub)' \
  "mode: $mode" \
  'resume: no' \
  'session id: broken-session' \
  'sandbox (requested): workspace-write' \
  'sandbox (CLI reported): workspace-write'
exit 0
STUB
  chmod 755 "$path"
}

for RULE in $RULES; do
  STUB_PATH="$TMP_ROOT/broken-$RULE-adapter.sh"
  OUTPUT="$TMP_ROOT/$RULE.output"
  write_broken_stub "$RULE" "$STUB_PATH"
  set +e
  "$CORE" --backend codex --adapter "$STUB_PATH" --only "$RULE" > "$OUTPUT" 2>&1
  STATUS=$?
  set -e
  if [[ $STATUS -eq 1 ]]; then
    pass "broken $RULE adapter is rejected by contract-core"
  else
    fail "broken $RULE adapter exits through contract-core with status 1 (got $STATUS)"
  fi
  if LC_ALL=C grep -qE "^not ok [0-9]+ - backend=codex rule=$RULE " "$OUTPUT" && \
     ! LC_ALL=C grep '^not ok ' "$OUTPUT" | grep -qv " rule=$RULE "; then
    pass "broken $RULE adapter fails for rule=$RULE and no other rule"
  else
    fail "broken $RULE adapter did not fail for the named rule"
    sed 's/^/  | /' "$OUTPUT" >&2
  fi
done

if [[ $FAILURES -gt 0 ]]; then
  printf 'contract-negative: FAIL (%d of %d checks failed)\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi

printf 'contract-negative: PASS (%d checks; 20 broken adapters rejected)\n' "$CHECKS"
