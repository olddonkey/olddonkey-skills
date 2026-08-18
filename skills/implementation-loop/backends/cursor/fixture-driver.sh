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
DRIVER_SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REAL_JOURNAL="$(CDPATH= cd -- "$DRIVER_SELF/../.." && pwd -P)/scripts/loop-journal"

journal_context_path() { # $1=workspace
  python3 - "$HOME_DIR" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key, "context"))
PY
}

setup_loop_journal_fixture() {
  unset LOOP_CONTEXT
  printf '%s\n' "$HOME_DIR" > "$TMPDIR_ABS/$CASE_NAME.home"
  printf '%s\n' "$WORKSPACE" > "$TMPDIR_ABS/$CASE_NAME.workspace"
  case "$CASE_NAME" in
    journal-missing)
      export LOOP_JOURNAL="$TMPDIR_ABS/no-such-loop-journal"
      ;;
    journal-start-refusal)
      export LOOP_JOURNAL="$BIN_DIR/loop-journal-refuse"
      printf '%s\n' '#!/usr/bin/env bash' 'exit 6' > "$LOOP_JOURNAL"
      chmod 755 "$LOOP_JOURNAL"
      ;;
    journal-events|journal-readonly-mode|signal-status)
      export LOOP_JOURNAL="$REAL_JOURNAL"
      env HOME="$HOME_DIR" "$REAL_JOURNAL" begin-run --workspace "$WORKSPACE" \
        > "$TMPDIR_ABS/$CASE_NAME.begin-run"
      ;;
    journal-unattributed)
      export LOOP_JOURNAL="$REAL_JOURNAL"
      ;;
    journal-stale)
      export LOOP_JOURNAL="$REAL_JOURNAL"
      env HOME="$HOME_DIR" "$REAL_JOURNAL" begin-run --workspace "$WORKSPACE" \
        > "$TMPDIR_ABS/$CASE_NAME.begin-run"
      cp "$(journal_context_path "$WORKSPACE")" "$CASE_ROOT/saved-context"
      env HOME="$HOME_DIR" "$REAL_JOURNAL" end-run --status completed --workspace "$WORKSPACE" \
        > "$TMPDIR_ABS/$CASE_NAME.end-run"
      cp "$CASE_ROOT/saved-context" "$(journal_context_path "$WORKSPACE")"
      chmod 600 "$(journal_context_path "$WORKSPACE")"
      ;;
    journal-malformed)
      export LOOP_JOURNAL="$REAL_JOURNAL"
      env HOME="$HOME_DIR" "$REAL_JOURNAL" begin-run --workspace "$WORKSPACE" \
        > "$TMPDIR_ABS/$CASE_NAME.begin-run"
      printf '%s\n' 'not-json{{{{' > "$(journal_context_path "$WORKSPACE")"
      chmod 600 "$(journal_context_path "$WORKSPACE")"
      ;;
    journal-wrong-workspace)
      export LOOP_JOURNAL="$REAL_JOURNAL"
      mkdir -p "$CASE_ROOT/other-ws"
      env HOME="$HOME_DIR" "$REAL_JOURNAL" begin-run --workspace "$CASE_ROOT/other-ws" \
        > "$TMPDIR_ABS/$CASE_NAME.begin-run"
      export LOOP_CONTEXT="$(journal_context_path "$CASE_ROOT/other-ws")"
      ;;
  esac
}

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

git init -q --template= --separate-git-dir="$CASE_ROOT/workspace.gitadmin" "$WORKSPACE"
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

setup_loop_journal_fixture
cd "$WORKSPACE"
exec env \
  HOME="$HOME_DIR" \
  GIT_CEILING_DIRECTORIES="$CASE_ROOT" \
  PATH="$BIN_DIR:$PATH" \
  CURSOR_STUB_LOG="$TMPDIR_ABS/$CASE_NAME.cli.log" \
  "$ADAPTER" "$@"
