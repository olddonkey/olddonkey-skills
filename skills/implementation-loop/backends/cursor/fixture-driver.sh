#!/usr/bin/env bash
# Contract-suite execution wrapper for the cursor-agent adapter.

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
  env-own) export CURSOR_LOOP_MODEL="cursor-contract-xhigh" ;;
  env-foreign)
    export CODEX_LOOP_MODEL="foreign-poison-model"
    export CODEX_LOOP_EXTRA_ARGS="--foreign-poison"
    export GROK_LOOP_MODEL="foreign-poison-model"
    export GROK_LOOP_EXTRA_ARGS="--foreign-poison"
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
mkdir -p "$BIN_DIR" "$HOME_DIR"

git init -q "$WORKSPACE"
git -C "$WORKSPACE" config user.email contract@example.invalid
git -C "$WORKSPACE" config user.name contract
printf 'contract fixture\n' > "$WORKSPACE/tracked.txt"
git -C "$WORKSPACE" add tracked.txt
git -C "$WORKSPACE" commit -qm base

CURSOR_STUB="$BIN_DIR/cursor-agent"
cat > "$CURSOR_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf 'cursor-agent contract-1.0.0\n'
  exit 0
fi

: "${CURSOR_STUB_LOG:?}"
: "${CONTRACT_TMPDIR:?}"
: "${CONTRACT_CASE:?}"
printf '%s\0' "$@" > "$CURSOR_STUB_LOG"

model="<none>"
mode="implement"
previous=""
last=""
for argument in "$@"; do
  [[ "$previous" != "--model" ]] || model="$argument"
  [[ "$previous" != "--mode" ]] || mode="$argument"
  previous="$argument"
  last="$argument"
done
[[ "$mode" != "plan" ]] || mode="read-only"
case "$last" in
  *$'\n\n'*) last="${last#*$'\n\n'}" ;;
esac

printf '%s' "$last" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-prompt"
printf '%s\n' "$model" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-model"
printf '%s\n' "$mode" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-mode"

case "$CONTRACT_CASE" in
  exit-status) exit 7 ;;
  signal-status) kill -TERM "$$" ;;
esac

printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"duration_api_ms":1,"result":"contract final message","session_id":"session-contract-123","request_id":"request-contract-123","usage":{}}'
exit 0
STUB
chmod 755 "$CURSOR_STUB"

cd "$WORKSPACE"
exec env \
  HOME="$HOME_DIR" \
  GIT_CEILING_DIRECTORIES="$CASE_ROOT" \
  PATH="$BIN_DIR:$PATH" \
  CURSOR_STUB_LOG="$TMPDIR_ABS/$CASE_NAME.cli.log" \
  "$ADAPTER" "$@"
