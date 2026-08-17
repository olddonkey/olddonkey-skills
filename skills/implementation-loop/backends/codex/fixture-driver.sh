#!/usr/bin/env bash
# Contract-suite execution wrapper for the Codex adapter.

set -euo pipefail
umask 077

[[ "${1:-}" == "run" && $# -ge 5 ]] || {
  echo "usage: fixture-driver.sh run <tmpdir> <case> <adapter> -- <args...>" >&2
  exit 2
}

TMPDIR_ARG="$2"
CASE_NAME="$3"
ADAPTER_ARG="$4"
[[ "$5" == "--" ]] || {
  echo "error: fixture driver requires -- before adapter arguments" >&2
  exit 2
}
shift 5

TMPDIR_ABS="$(CDPATH= cd -- "$TMPDIR_ARG" && pwd -P)"
ADAPTER_DIR="$(CDPATH= cd -- "$(dirname -- "$ADAPTER_ARG")" && pwd -P)"
ADAPTER="$ADAPTER_DIR/$(basename -- "$ADAPTER_ARG")"
[[ -x "$ADAPTER" ]] || { echo "error: adapter is not executable: $ADAPTER" >&2; exit 2; }

export CONTRACT_TMPDIR="$TMPDIR_ABS"
export CONTRACT_CASE="$CASE_NAME"
unset CODEX_LOOP_MODEL CODEX_LOOP_EFFORT CODEX_LOOP_EXTRA_ARGS
unset GROK_LOOP_MODEL GROK_LOOP_EFFORT GROK_LOOP_EXTRA_ARGS
unset CURSOR_LOOP_MODEL CURSOR_LOOP_EFFORT CURSOR_LOOP_EXTRA_ARGS

case "$CASE_NAME" in
  env-own) export CODEX_LOOP_MODEL="contract-own-model" ;;
  env-foreign)
    export GROK_LOOP_MODEL="foreign-poison-model"
    export GROK_LOOP_EXTRA_ARGS="--foreign-poison"
    export CURSOR_LOOP_MODEL="foreign-poison-model"
    export CURSOR_LOOP_EXTRA_ARGS="--foreign-poison"
    ;;
esac

case "$CASE_NAME" in
  help|prompt-required|missing-*|unknown-flags|background)
    cd "$TMPDIR_ABS"
    exec "$ADAPTER" "$@"
    ;;
esac

CASE_ROOT="$TMPDIR_ABS/$CASE_NAME"
BIN_DIR="$CASE_ROOT/bin"
HOME_DIR="$CASE_ROOT/home"
WORKSPACE="$CASE_ROOT/workspace"
mkdir -p "$BIN_DIR" "$HOME_DIR/.codex" "$WORKSPACE"

CODEX_STUB="$BIN_DIR/codex"
cat > "$CODEX_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-contract 1.0.0\n'
  exit 0
fi

: "${CODEX_STUB_LOG:?}"
: "${CONTRACT_TMPDIR:?}"
: "${CONTRACT_CASE:?}"
printf '%s\0' "$@" > "$CODEX_STUB_LOG"

output=""
mode=""
model="<none>"
effort="<none>"
previous=""
last=""
for argument in "$@"; do
  [[ "$previous" != "-o" ]] || output="$argument"
  [[ "$previous" != "-s" ]] || mode="$argument"
  [[ "$previous" != "-m" ]] || model="$argument"
  case "$argument" in
    sandbox_mode=\"workspace-write\") mode="workspace-write" ;;
    sandbox_mode=\"read-only\") mode="read-only" ;;
    model_reasoning_effort=*) effort="${argument#model_reasoning_effort=}" ;;
  esac
  previous="$argument"
  last="$argument"
done

printf '%s' "$last" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-prompt"
printf '%s\n' "$model" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-model"
printf '%s\n' "$mode" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-mode"
: "${output:?Codex stub did not receive -o}"
printf 'contract final message\n' > "$output"
printf '%s\n' '--------'
printf 'approval: never\n'
printf 'sandbox: %s [workdir, /tmp, TMPDIR]\n' "$mode"
printf 'session id: 019c0000-0000-7000-8000-000000000123\n'
printf '%s\n' '--------'

case "$CONTRACT_CASE" in
  exit-status) exit 7 ;;
  signal-status) kill -TERM "$$" ;;
esac
exit 0
STUB
chmod 755 "$CODEX_STUB"

cd "$WORKSPACE"
exec env \
  HOME="$HOME_DIR" \
  CODEX_HOME="$HOME_DIR/.codex" \
  PATH="$BIN_DIR:$PATH" \
  CODEX_STUB_LOG="$TMPDIR_ABS/$CASE_NAME.cli.log" \
  "$ADAPTER" "$@"
