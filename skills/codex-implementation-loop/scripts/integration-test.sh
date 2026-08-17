#!/usr/bin/env bash
# Local, opt-in integration gate for the real grok and cursor-agent backends.
#
# This script makes authenticated API calls. It is syntax-checked in CI but is
# never run there. Model prompts are deliberately exact; failure to follow one
# is a real not-ok that an operator may re-run, not a reason to weaken a check.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
GROK_DISPATCH="$SCRIPT_DIR/grok-dispatch.sh"
CURSOR_DISPATCH="$SCRIPT_DIR/cursor-dispatch.sh"
BACKEND="all"

usage() {
  cat <<'EOF'
Usage: integration-test.sh [--backend grok|cursor|all]

Run the local, authenticated integration gate for one or both real backends.
Unavailable or logged-out backends are reported as skips.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="${2:?--backend needs grok, cursor, or all}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$BACKEND" in
  grok|cursor|all) ;;
  *)
    echo "error: --backend must be grok, cursor, or all" >&2
    exit 2
    ;;
esac

ORIGINAL_HOME="${HOME:?HOME is required}"
TMP_ROOT_RAW="$(mktemp -d "$ORIGINAL_HOME/.olddonkey-loop-integration.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
chmod 700 "$TMP_ROOT"

cleanup() {
  case "${TMP_ROOT:-}" in
    "$ORIGINAL_HOME"/.olddonkey-loop-integration.*)
      [[ ! -d "$TMP_ROOT" ]] || rm -rf -- "$TMP_ROOT"
      ;;
    "") ;;
    *) echo "warning: refusing unexpected integration cleanup path: $TMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

RESULTS=0
OK=0
SKIPPED=0
FAILURES=0

pass() {
  RESULTS=$((RESULTS + 1))
  OK=$((OK + 1))
  printf 'ok %d - %s\n' "$RESULTS" "$1"
}

fail() {
  RESULTS=$((RESULTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$RESULTS" "$1"
}

skip() { # $1=description $2=reason
  RESULTS=$((RESULTS + 1))
  SKIPPED=$((SKIPPED + 1))
  printf 'ok %d - %s # SKIP %s\n' "$RESULTS" "$1" "$2"
}

diagnose_file() { # $1=label $2=path
  local label="$1" path="$2"
  [[ -s "$path" ]] || return 0
  printf '# %s output follows\n' "$label"
  sed 's/^/# /' "$path"
}

summary_value() { # $1=summary path $2=label
  awk -v prefix="$2: " '
    index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }
  ' "$1"
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb", buffering=0) as handle:
    while chunk := handle.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

sha256_text() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

canonical_existing_dir() {
  python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
if not os.path.isdir(path):
    raise SystemExit(1)
print(path)
PY
}

run_grok_backend() {
  local test_home="$TMP_ROOT/grok-home"
  local main="$TMP_ROOT/grok-main"
  local unit="$TMP_ROOT/grok-unit"
  local output="$TMP_ROOT/grok-dispatch.out"
  local allowlist profile_hash policy_hash version_raw version
  local os_name arch kernel git_dir index_before index_after main_head_before
  local authoritative authoritative_admin source_admin main_head_after
  local tracked_quoted index_quoted prompt_file status
  local PROFILE_CONTENT POLICY_CONTENT

  mkdir -m 700 "$test_home" || { fail "grok isolated HOME is prepared"; return; }
  mkdir -p "$test_home/.grok"
  cp "$ORIGINAL_HOME/.grok/auth.json" "$test_home/.grok/auth.json"
  chmod 600 "$test_home/.grok/auth.json"

  git init -q "$main" || { fail "grok disposable repository is initialized"; return; }
  git -C "$main" config user.email integration@example.invalid
  git -C "$main" config user.name integration-test
  printf 'before\n' > "$main/tracked.txt"
  git -C "$main" add tracked.txt
  git -C "$main" commit -qm base || { fail "grok disposable base commit is created"; return; }
  git -C "$main" worktree add -q -b integration/grok "$unit" || {
    fail "grok disposable linked worktree is created"
    return
  }
  unit="$(canonical_existing_dir "$unit")"
  main_head_before="$(git -C "$main" rev-parse HEAD)"
  git_dir="$(git -C "$unit" rev-parse --absolute-git-dir)"
  [[ -f "$git_dir/index" ]] || { fail "grok source worktree index exists"; return; }
  index_before="$(sha256_file "$git_dir/index")"

  # Keep these byte-for-byte equivalent to grok-dispatch.sh. The hashes are
  # part of the allowlist mechanism tuple, not locally invented test values.
  PROFILE_CONTENT=$(cat <<'EOF'
[profiles.olddonkey-loop-implement]
extends = "workspace"
restrict_network = true

[profiles.olddonkey-loop-readonly]
extends = "read-only"
restrict_network = true
EOF
)
  POLICY_CONTENT=$(cat <<'EOF'
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
)
  profile_hash="$(printf '%s\n' "$PROFILE_CONTENT" | sha256_text)"
  policy_hash="$(printf '%s\n' "$POLICY_CONTENT" | sha256_text)"
  version_raw="$(HOME="$test_home" grok --version 2>&1)" || {
    fail "grok version is readable"
    return
  }
  version="$(python3 - "$version_raw" <<'PY'
import re
import sys

match = re.search(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", sys.argv[1])
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
)" || { fail "grok version is parseable"; return; }
  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  kernel="$(uname -r)"

  allowlist="$test_home/.config/olddonkey-loop/grok-backend.toml"
  mkdir -p "$(dirname "$allowlist")"
  chmod 700 "$test_home/.config" "$test_home/.config/olddonkey-loop"
  cat > "$allowlist" <<EOF
[[carve_out]]
os = "$os_name"
arch = "$arch"
grok_version = "$version"
kernel = "$kernel"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$profile_hash"
policy_hash = "$policy_hash"
repo = "$unit"
granted = "$(date -u +%Y-%m-%d)"
EOF
  chmod 600 "$allowlist"

  printf -v tracked_quoted '%q' "$unit/tracked.txt"
  printf -v index_quoted '%q' "$git_dir/index"
  # A here-document written to a file, then passed with --prompt-file. Do NOT
  # use prompt=$(cat <<EOF ...); a here-document inside command substitution is
  # mis-parsed at runtime by bash 3.2 (the macOS default), and bash -n does not
  # catch it because it never expands the substitution.
  prompt_file="$TMP_ROOT/grok-prompt.txt"
  cat > "$prompt_file" <<EOF
Use the shell tool once to run exactly the command below. Do not run any other command. After it finishes, report the printed GROK_INTEGRATION_RESULTS line verbatim and report the command's final exit status.

printf '%s\n' 'grok-integration-benign' >> $tracked_quoted; edit_status=\$?; printf X >> $index_quoted; protected_status=\$?; printf 'GROK_INTEGRATION_RESULTS GROK_EDIT_EXIT=%s GROK_PROTECTED_EXIT=%s\n' "\$edit_status" "\$protected_status"; exit 0
EOF

  set +e
  (
    cd "$unit"
    HOME="$test_home" "$GROK_DISPATCH" \
      --prompt-file "$prompt_file" --model grok-4.6 --effort xhigh
  ) > "$output" 2>&1
  status=$?
  set -e

  if [[ $status -eq 0 ]] &&
     LC_ALL=C grep -qF 'grok dispatch summary:' "$output" &&
     LC_ALL=C grep -qF 'mode: implement' "$output" &&
     LC_ALL=C grep -qF 'model: grok-4.6 (explicit)' "$output" &&
     LC_ALL=C grep -qF 'effort: xhigh (explicit)' "$output"; then
    pass "grok adapter exits 0 with the implement/model summary"
  else
    fail "grok adapter exits 0 with the implement/model summary (status $status)"
    diagnose_file grok "$output"
  fi

  authoritative="$(summary_value "$output" 'authoritative path')"
  if [[ "$authoritative" == "$TMP_ROOT"/* && -f "$authoritative/tracked.txt" ]] &&
     LC_ALL=C grep -qxF 'grok-integration-benign' "$authoritative/tracked.txt" &&
     LC_ALL=C grep -Eq 'GROK_EDIT_EXIT=0([[:space:]]|$)' "$output"; then
    pass "grok benign edit lands in the authoritative snapshot"
  else
    fail "grok benign edit lands in the authoritative snapshot"
  fi

  index_after=""
  [[ ! -f "$git_dir/index" ]] || index_after="$(sha256_file "$git_dir/index")"
  if [[ -n "$index_after" && "$index_before" == "$index_after" ]] &&
     LC_ALL=C grep -Eq 'GROK_PROTECTED_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "grok seatbelt denies the git-dir index write and preserves its bytes"
  else
    fail "grok seatbelt denies the git-dir index write and preserves its bytes"
  fi

  authoritative_admin=""
  source_admin=""
  if [[ -n "$authoritative" && -d "$authoritative" ]]; then
    authoritative_admin="$(git -C "$authoritative" rev-parse --absolute-git-dir 2>/dev/null || true)"
  fi
  source_admin="$(git -C "$unit" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -n "$authoritative_admin" && -n "$source_admin" &&
        "$authoritative_admin" != "$source_admin" ]]; then
    pass "grok authoritative snapshot has an independent worktree registration"
  else
    fail "grok authoritative snapshot has an independent worktree registration"
  fi

  main_head_after="$(git -C "$main" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$main_head_after" && "$main_head_before" == "$main_head_after" ]]; then
    pass "grok dispatch leaves the original main HEAD unmoved"
  else
    fail "grok dispatch leaves the original main HEAD unmoved"
  fi

  # macOS grok child-network restriction is a tuple-level no-op. This harness
  # therefore asserts only the filesystem and attribution properties that the
  # macOS kernel actually enforces; it does not claim a network-blocking pass.
}

copy_has_no_forbidden_entries() { # $1=copy $2=ignored relative path
  python3 - "$1" "$2" <<'PY'
import os
import sys

root, ignored = sys.argv[1:]
if not os.path.isdir(root):
    raise SystemExit(1)
for directory, dirnames, filenames in os.walk(root, followlinks=False):
    for name in [*dirnames, *filenames]:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root)
        if name == ".git" or relative == ignored:
            raise SystemExit(1)
raise SystemExit(0)
PY
}

pristine_matches_manifest() { # $1=repo $2=pristine $3=ignored relative path
  python3 - "$1" "$2" "$3" <<'PY'
import os
import subprocess
import sys

repo, pristine, ignored = sys.argv[1:]
if not os.path.isdir(pristine):
    raise SystemExit(1)
expected_raw = subprocess.check_output(
    ["git", "-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
expected = {os.fsdecode(value) for value in expected_raw.split(b"\0") if value}
actual = set()
for directory, dirnames, filenames in os.walk(pristine, followlinks=False):
    for name in list(dirnames):
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, pristine)
        if name == ".git":
            raise SystemExit(1)
        if os.path.islink(path):
            actual.add(relative)
            dirnames.remove(name)
    for name in filenames:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, pristine)
        if name == ".git":
            raise SystemExit(1)
        actual.add(relative)
if ignored in actual or actual != expected:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

run_cursor_backend() {
  local repo="$TMP_ROOT/cursor-repo"
  local outside="$TMP_ROOT/cursor-outside.txt"
  local output="$TMP_ROOT/cursor-dispatch.out"
  local outside_quoted prompt_file status
  local work_copy pristine_copy
  local -a cursor_env

  # cursor-agent's login is NOT a copyable file — on macOS it lives in the
  # system keychain (referenced from cli-config.json's authInfo), and an
  # isolated HOME reads as "Not logged in". So the real HOME is used for
  # credential resolution. Work isolation does not depend on HOME: the
  # disposable repo lives under TMP_ROOT and CURSOR_LOOP_WORK_ROOT points the
  # git-less copies there too; the sandbox/git-less-copy boundary (which the
  # assertions below exercise) is what actually confines cursor-agent.

  git init -q "$repo" || { fail "cursor disposable repository is initialized"; return; }
  git -C "$repo" config user.email integration@example.invalid
  git -C "$repo" config user.name integration-test
  printf 'ignored.txt\n' > "$repo/.gitignore"
  printf 'before\n' > "$repo/tracked.txt"
  git -C "$repo" add .gitignore tracked.txt
  git -C "$repo" commit -qm base || { fail "cursor disposable base commit is created"; return; }
  printf 'non-ignored project file\n' > "$repo/visible.txt"
  printf 'must stay outside copies\n' > "$repo/ignored.txt"

  printf -v outside_quoted '%q' "$outside"
  # See the grok note above: a here-document to a file + --prompt-file, never
  # prompt=$(cat <<EOF ...), which bash 3.2 mis-parses at runtime.
  prompt_file="$TMP_ROOT/cursor-prompt.txt"
  cat > "$prompt_file" <<EOF
Use the shell tool once to run exactly the command below. Do not run any other command. After it finishes, report the printed CURSOR_INTEGRATION_RESULTS line verbatim and report the command's final exit status.

printf '%s\n' 'cursor-integration-benign' >> tracked.txt; edit_status=\$?; printf '%s\n' 'cursor-confinement-breach' > $outside_quoted; outside_status=\$?; curl --max-time 5 --silent --show-error https://api.github.com >/dev/null; network_status=\$?; printf 'CURSOR_INTEGRATION_RESULTS CURSOR_EDIT_EXIT=%s CURSOR_OUTSIDE_EXIT=%s CURSOR_NETWORK_EXIT=%s\n' "\$edit_status" "\$outside_status" "\$network_status"; exit 0
EOF

  # Real HOME (for keychain auth); only the loop's work root and copy-retention
  # are overridden, keeping the git-less copies under TMP_ROOT.
  cursor_env=(
    "CURSOR_LOOP_WORK_ROOT=$TMP_ROOT/cursor-work"
    "CURSOR_LOOP_KEEP_COPIES=1"
  )

  set +e
  (
    cd "$repo"
    env "${cursor_env[@]}" "$CURSOR_DISPATCH" \
      --prompt-file "$prompt_file" --model cursor-grok-4.6-xhigh --effort xhigh
  ) > "$output" 2>&1
  status=$?
  set -e

  if [[ $status -eq 0 ]] &&
     LC_ALL=C grep -qF 'cursor-agent dispatch summary:' "$output" &&
     LC_ALL=C grep -qF 'mode: implement' "$output" &&
     LC_ALL=C grep -qF 'model: cursor-grok-4.6-xhigh (explicit)' "$output" &&
     LC_ALL=C grep -qF 'effort: xhigh (explicit assertion in model id)' "$output" &&
     LC_ALL=C grep -qF 'is_error: false' "$output"; then
    pass "cursor adapter exits 0 with is_error false and the implement/model summary"
  else
    fail "cursor adapter exits 0 with is_error false and the implement/model summary (status $status)"
    diagnose_file cursor "$output"
  fi

  if LC_ALL=C grep -qxF 'cursor-integration-benign' "$repo/tracked.txt" &&
     ! git -C "$repo" diff --quiet -- tracked.txt &&
     LC_ALL=C grep -Eq 'CURSOR_EDIT_EXIT=0([[:space:]]|$)' "$output"; then
    pass "cursor benign edit lands in the real worktree as a Git modification"
  else
    fail "cursor benign edit lands in the real worktree as a Git modification"
  fi

  if [[ ! -e "$outside" && ! -L "$outside" ]] &&
     LC_ALL=C grep -Eq 'CURSOR_OUTSIDE_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "cursor sandbox denies and does not create the out-of-copy sibling"
  else
    fail "cursor sandbox denies and does not create the out-of-copy sibling"
  fi

  if LC_ALL=C grep -Eq 'CURSOR_NETWORK_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "cursor reports that the network target was not reachable"
  else
    fail "cursor reports that the network target was not reachable"
  fi

  work_copy="$(summary_value "$output" 'work copy')"
  if [[ "$work_copy" == "$TMP_ROOT"/* ]] &&
     copy_has_no_forbidden_entries "$work_copy" ignored.txt; then
    pass "cursor work copy contains no .git entry or ignored file"
  else
    fail "cursor work copy contains no .git entry or ignored file"
  fi

  pristine_copy="$(summary_value "$output" 'pristine copy')"
  if [[ "$pristine_copy" == "$TMP_ROOT"/* ]] &&
     pristine_matches_manifest "$repo" "$pristine_copy" ignored.txt; then
    pass "cursor pristine copy exactly matches the tracked plus non-ignored fileset"
  else
    fail "cursor pristine copy exactly matches the tracked plus non-ignored fileset"
  fi
}

if [[ "$BACKEND" == "grok" || "$BACKEND" == "all" ]]; then
  if ! command -v grok >/dev/null 2>&1; then
    skip "grok real-backend integration" "grok is not on PATH"
  elif [[ ! -f "$ORIGINAL_HOME/.grok/auth.json" ]]; then
    skip "grok real-backend integration" "$ORIGINAL_HOME/.grok/auth.json is missing"
  else
    run_grok_backend
  fi
fi

if [[ "$BACKEND" == "cursor" || "$BACKEND" == "all" ]]; then
  if ! command -v cursor-agent >/dev/null 2>&1; then
    skip "cursor real-backend integration" "cursor-agent is not on PATH"
  else
    CURSOR_STATUS_OUTPUT=""
    set +e
    CURSOR_STATUS_OUTPUT="$(HOME="$ORIGINAL_HOME" cursor-agent status 2>&1)"
    CURSOR_STATUS=$?
    set -e
    if [[ $CURSOR_STATUS -ne 0 ]] ||
       ! LC_ALL=C grep -Eq 'Logged in|Login successful' <<<"$CURSOR_STATUS_OUTPUT"; then
      skip "cursor real-backend integration" "cursor-agent status did not report logged in"
    elif ! command -v curl >/dev/null 2>&1; then
      fail "cursor live network-denial probe requires curl"
    else
      run_cursor_backend
    fi
  fi
fi

if [[ $FAILURES -eq 0 ]]; then
  printf 'integration-test: PASS (%d ok, %d skipped)\n' "$OK" "$SKIPPED"
  exit 0
fi

printf 'integration-test: FAIL (%d ok, %d skipped, %d failed)\n' \
  "$OK" "$SKIPPED" "$FAILURES"
exit 1
