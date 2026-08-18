#!/usr/bin/env bash
# Contract-suite execution wrapper for the grok adapter.

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
    journal-events|journal-readonly-mode|signal-status|journal-post-disarm-abort)
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
unset GROK_LOOP_MODEL GROK_LOOP_EFFORT GROK_LOOP_EXTRA_ARGS GROK_LOOP_SELFTEST_INTERRUPT_AFTER
unset CURSOR_LOOP_MODEL CURSOR_LOOP_EFFORT CURSOR_LOOP_EXTRA_ARGS

case "$CASE_NAME" in
  env-own) export GROK_LOOP_MODEL="contract-own-model" ;;
  env-foreign)
    export CODEX_LOOP_MODEL="foreign-poison-model"
    export CODEX_LOOP_EXTRA_ARGS="--foreign-poison"
    export CURSOR_LOOP_MODEL="foreign-poison-model"
    export CURSOR_LOOP_EXTRA_ARGS="--foreign-poison"
    ;;
  journal-post-disarm-abort)
    # copied is the first implement-path journal() after trap disarm.
    export GROK_LOOP_SELFTEST_INTERRUPT_AFTER=copied
    ;;
esac

case "$CASE_NAME" in
  help|prompt-required|missing-*|unknown-flags|background)
    cd "$TMPDIR_ABS"
    exec "$ADAPTER" "$@"
    ;;
esac

CASE_ROOT_RAW="$(mktemp -d /tmp/implementation-loop-contract-grok.XXXXXX)"
CASE_ROOT="$(CDPATH= cd -- "$CASE_ROOT_RAW" && pwd -P)"
printf '%s\n' "$CASE_ROOT" > "$TMPDIR_ABS/$CASE_NAME.runtime-root"
BIN_DIR="$CASE_ROOT/bin"
HOME_DIR="$CASE_ROOT/home"
MAIN_REPO="$CASE_ROOT/main"
WORKSPACE="$CASE_ROOT/workspace"
mkdir -p "$BIN_DIR" "$HOME_DIR"

git init -q --template= --separate-git-dir="$CASE_ROOT/main.gitadmin" "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email contract@example.invalid
git -C "$MAIN_REPO" config user.name contract
printf 'contract fixture\n' > "$MAIN_REPO/tracked.txt"
git -C "$MAIN_REPO" add tracked.txt
git -C "$MAIN_REPO" commit -qm base
git -C "$MAIN_REPO" worktree add -q -b "contract-$CASE_NAME" "$WORKSPACE"

PROFILE_FILE="$CASE_ROOT/profile.txt"
POLICY_FILE="$CASE_ROOT/policy.txt"
cat > "$PROFILE_FILE" <<'EOF'
[profiles.olddonkey-loop-implement]
extends = "workspace"
restrict_network = true

[profiles.olddonkey-loop-readonly]
extends = "read-only"
restrict_network = true
EOF
cat > "$POLICY_FILE" <<'EOF'
[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.codex]
sessions = false
EOF
PROFILE_HASH="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$PROFILE_FILE")"
POLICY_HASH="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$POLICY_FILE")"

ALLOWLIST="$HOME_DIR/.config/olddonkey-loop/grok-backend.toml"
mkdir -p "$(dirname -- "$ALLOWLIST")"
cat > "$ALLOWLIST" <<EOF
[[carve_out]]
os = "darwin"
arch = "arm64"
grok_version = "1.0.4"
kernel = "25.6.0"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$PROFILE_HASH"
policy_hash = "$POLICY_HASH"
repo = "$WORKSPACE"
granted = "2026-08-17"
EOF
chmod 600 "$ALLOWLIST"

cat > "$BIN_DIR/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'arm64\n' ;;
  -r) printf '25.6.0\n' ;;
  *) printf 'Darwin 25.6.0 arm64\n' ;;
esac
STUB
cat > "$BIN_DIR/sw_vers" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-productVersion" ]] && printf '15.6\n' || printf 'ProductVersion: 15.6\n'
STUB
cat > "$BIN_DIR/grok" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf 'grok 1.0.4\n'
  exit 0
fi
if [[ "${1:-}" == "mcp" && "${2:-}" == "list" ]]; then
  printf '{"servers":[]}\n'
  exit 0
fi

: "${GROK_STUB_LOG:?}"
: "${CONTRACT_TMPDIR:?}"
: "${CONTRACT_CASE:?}"
printf '%s\0' "$@" > "$GROK_STUB_LOG"

prompt_file=""
model="<none>"
mode="implement"
previous=""
for argument in "$@"; do
  [[ "$previous" != "--prompt-file" ]] || prompt_file="$argument"
  [[ "$previous" != "-m" ]] || model="$argument"
  [[ "$previous" != "--sandbox" ]] || {
    [[ "$argument" != "olddonkey-loop-readonly" ]] || mode="read-only"
  }
  previous="$argument"
done
: "${prompt_file:?grok stub did not receive --prompt-file}"
cat "$prompt_file" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-prompt"
printf '%s\n' "$model" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-model"
printf '%s\n' "$mode" > "$CONTRACT_TMPDIR/$CONTRACT_CASE.observed-mode"

case "$CONTRACT_CASE" in
  exit-status) exit 7 ;;
  signal-status)
    kill -TERM "$PPID"
    while :; do sleep 1; done
    ;;
esac

printf '%s\n' '{"text":"contract final message","stopReason":"end","sessionId":"session-contract-123","requestId":"request-contract-123","thought":"","usage":{}}'
exit 0
STUB
chmod 755 "$BIN_DIR/uname" "$BIN_DIR/sw_vers" "$BIN_DIR/grok"

# The production adapter correctly treats every system temp root as writable.
# Contract fixtures are disposable and must live in a writable test location,
# so use the same narrowly patched adapter copy as the backend selftest: only
# temp-root discovery changes; parser, argv, summary, and status logic do not.
ADAPTER_COPY_DIR="$CASE_ROOT/adapter"
mkdir -p "$ADAPTER_COPY_DIR"
cp "$ADAPTER" "$ADAPTER_COPY_DIR/dispatch.sh"
if [[ -f "$ADAPTER_DIR/verify-worktree.sh" ]]; then
  cp "$ADAPTER_DIR/verify-worktree.sh" "$ADAPTER_COPY_DIR/verify-worktree.sh"
  chmod 755 "$ADAPTER_COPY_DIR/verify-worktree.sh"
fi
python3 - "$ADAPTER_COPY_DIR/dispatch.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    'roots = {os.path.realpath(tempfile.gettempdir())}',
    'roots = {"/__implementation_loop_contract_temp__"}',
)
text = text.replace(
    'for value in (os.environ.get("TMPDIR"), "/tmp", "/private/tmp", "/var/tmp"):',
    'for value in ():',
)
path.write_text(text, encoding="utf-8")
PY
chmod 755 "$ADAPTER_COPY_DIR/dispatch.sh"

setup_loop_journal_fixture
cd "$WORKSPACE"
exec env \
  HOME="$HOME_DIR" \
  GIT_CEILING_DIRECTORIES="$CASE_ROOT" \
  PATH="$BIN_DIR:$PATH" \
  GROK_STUB_LOG="$TMPDIR_ABS/$CASE_NAME.cli.log" \
  "$ADAPTER_COPY_DIR/dispatch.sh" "$@"
