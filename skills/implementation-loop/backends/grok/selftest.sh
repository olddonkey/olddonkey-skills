#!/usr/bin/env bash
# Regression harness for the grok backend.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
VERIFIER="$SCRIPT_DIR/verify-worktree.sh"
TMP_ROOT_RAW="$(mktemp -d)"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CHECKS=0
FAILURES=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1"
}

expect_status() { # $1=expected $2=description
  if [[ "$CASE_STATUS" -eq "$1" ]]; then pass "$2"; else fail "$2 (status $CASE_STATUS, expected $1)"; fi
}

expect_nonzero() { # $1=description
  if [[ "$CASE_STATUS" -ne 0 ]]; then pass "$1"; else fail "$1 (unexpected success)"; fi
}

expect_contains() { # $1=text $2=description
  if LC_ALL=C grep -qF -- "$1" "$CASE_OUTPUT"; then pass "$2"; else fail "$2 (missing '$1')"; fi
}

expect_not_contains() { # $1=text $2=description
  if LC_ALL=C grep -qF -- "$1" "$CASE_OUTPUT"; then fail "$2 (found '$1')"; else pass "$2"; fi
}

expect_file_contains() { # $1=file $2=text $3=description
  if [[ -f "$1" ]] && LC_ALL=C grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

expect_file_mode() { # $1=file $2=octal $3=description
  local actual
  if [[ ! -e "$1" ]]; then
    fail "$3 (missing file: $1)"
    return
  fi
  actual="$(python3 - "$1" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
PY
)"
  if [[ "$actual" == "$2" ]]; then pass "$3"; else fail "$3 (mode $actual)"; fi
}

run_case() { # $1=name, remaining args=command
  local name="$1"
  shift
  CASE_OUTPUT="$TMP_ROOT/$name.out"
  set +e
  "$@" >"$CASE_OUTPUT" 2>&1
  CASE_STATUS=$?
  set -e
}

write_lines() { # $1=path, remaining args=lines
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
write_lines "$BIN_DIR/uname" \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  -s) printf "%s\n" "${GROK_STUB_OS:-Darwin}" ;;' \
  '  -m) printf "%s\n" "${GROK_STUB_ARCH:-arm64}" ;;' \
  '  -r) printf "%s\n" "${GROK_STUB_KERNEL:-25.6.0}" ;;' \
  '  *) printf "%s %s %s\n" "${GROK_STUB_OS:-Darwin}" "${GROK_STUB_KERNEL:-25.6.0}" "${GROK_STUB_ARCH:-arm64}" ;;' \
  'esac'
write_lines "$BIN_DIR/sw_vers" \
  '#!/usr/bin/env bash' \
  '[[ "${1:-}" == "-productVersion" ]] && printf "15.6\n" || printf "ProductVersion: 15.6\n"'
write_lines "$BIN_DIR/grok" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${GROK_STUB_LOG:?}"' \
  'if [[ "${1:-}" == "--version" ]]; then printf "grok %s\n" "${GROK_STUB_VERSION:-1.0.4}"; exit 0; fi' \
  'if [[ "${1:-}" == "mcp" && "${2:-}" == "list" ]]; then' \
  '  printf "mcp|%s|%s|%s\n" "$PWD" "${GROK_HOME:-}" "$*" >> "$GROK_STUB_LOG"' \
  '  case "${GROK_STUB_MCP:-zero}" in' \
  '    zero) printf "{\"servers\":[]}\n" ;;' \
  '    nonzero) printf "{\"servers\":[{\"name\":\"github\"}]}\n" ;;' \
  '    bad) printf "not-json\n" ;;' \
  '    fail) exit 12 ;;' \
  '  esac' \
  '  exit 0' \
  'fi' \
  'printf "dispatch|%s|%s|%s\n" "$PWD" "${GROK_HOME:-}" "$*" >> "$GROK_STUB_LOG"' \
  'case "${GROK_STUB_ACTION:-none}" in' \
  '  edit) printf "changed\n" >> tracked.txt ;;' \
  '  old-symlink) ln -s "$PWD/tracked.txt" survivor-link ;;' \
  '  home-symlink) ln -s "$GROK_HOME/config.toml" survivor-link ;;' \
  '  ledger-symlink) ln -s "${GROK_STUB_LEDGER_TARGET:?}" survivor-link ;;' \
  '  special) mkfifo unsafe-fifo ;;' \
  'esac' \
  'printf "{\"text\":\"stub complete\",\"stopReason\":\"end\",\"sessionId\":\"session-123\",\"requestId\":\"request-1\",\"thought\":\"\",\"usage\":{}}\n"'
chmod +x "$BIN_DIR/grok" "$BIN_DIR/uname" "$BIN_DIR/sw_vers"
TEST_PATH="$BIN_DIR:$PATH"

# Production correctly treats /tmp as sandbox-writable, while a selftest must
# build disposable success fixtures there. Patch only the disposable adapter
# copy's temp-root discovery; refusal cases that exercise real /tmp use a
# second copy with only the allowlist-source temp comparison removed.
ADAPTER_DIR="$TMP_ROOT/adapter"
mkdir -p "$ADAPTER_DIR"
cp "$DISPATCH" "$ADAPTER_DIR/dispatch.sh"
cp "$VERIFIER" "$ADAPTER_DIR/verify-worktree.sh"
python3 - "$ADAPTER_DIR/dispatch.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'roots = {os.path.realpath(tempfile.gettempdir())}',
    'roots = {"/__grok_loop_selftest_temp__"}',
)
text = text.replace(
    'for value in (os.environ.get("TMPDIR"), "/tmp", "/private/tmp", "/var/tmp"):',
    'for value in ():',
)
path.write_text(text)
PY
chmod +x "$ADAPTER_DIR"/*.sh
TEST_DISPATCH="$ADAPTER_DIR/dispatch.sh"

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
PROFILE_HASH="$(printf '%s\n' "$PROFILE_CONTENT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
POLICY_HASH="$(printf '%s\n' "$POLICY_CONTENT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"

init_repo() { # $1=path
  git init -q "$1"
  git -C "$1" config user.email selftest@example.invalid
  git -C "$1" config user.name selftest
  printf 'base\n' > "$1/tracked.txt"
  git -C "$1" add tracked.txt
  git -C "$1" commit -qm base
}

common_dir_abs() { # $1=repo/worktree
  local raw
  raw="$(git -C "$1" rev-parse --git-common-dir)"
  python3 - "$1" "$raw" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
}

write_allowlist() { # $1=home $2=repo; optional version/kernel/repo/kind
  local home="$1" repo="$2" version="${3:-1.0.4}" kernel="${4:-25.6.0}"
  local recorded_repo="${5:-$repo}" kind="${6:-carve_out}"
  local file="$home/.config/olddonkey-loop/grok-backend.toml"
  mkdir -p "$(dirname "$file")"
  if [[ "$kind" == "carve_out" ]]; then
    cat > "$file" <<EOF
[[carve_out]]
os = "darwin"
arch = "arm64"
grok_version = "$version"
kernel = "$kernel"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$PROFILE_HASH"
policy_hash = "$POLICY_HASH"
repo = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$recorded_repo")"
granted = "2026-08-16"
EOF
  else
    cat > "$file" <<EOF
[[enforced]]
os = "darwin"
arch = "arm64"
grok_version = "$version"
kernel = "$kernel"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$PROFILE_HASH"
policy_hash = "$POLICY_HASH"
EOF
  fi
  chmod 600 "$file"
}

dispatch_case() { # $1=name $2=home $3=repo; remaining flags
  local name="$1" home="$2" repo="$3"
  shift 3
  mkdir -p "$home"
  : > "$TMP_ROOT/$name.grok.log"
  run_case "$name" env HOME="$home" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/$name.grok.log" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$repo" "$TEST_DISPATCH" \
    --prompt 'do the bounded task' "$@"
}

new_readonly_fixture() { # $1=name
  FIX_HOME="$TMP_ROOT/$1-home"
  FIX_REPO="$TMP_ROOT/$1-repo"
  mkdir -p "$FIX_HOME"
  init_repo "$FIX_REPO"
  write_allowlist "$FIX_HOME" "$FIX_REPO"
}

new_linked_fixture() { # $1=name
  FIX_HOME="$TMP_ROOT/$1-home"
  FIX_MAIN="$TMP_ROOT/$1-main"
  FIX_REPO="$TMP_ROOT/$1-unit"
  mkdir -p "$FIX_HOME"
  init_repo "$FIX_MAIN"
  git -C "$FIX_MAIN" worktree add -q -b "$1-branch" "$FIX_REPO"
  write_allowlist "$FIX_HOME" "$FIX_REPO"
}

# Interface and source invariants.
run_case help "$TEST_DISPATCH" --help
expect_status 0 "help succeeds"
expect_contains "--background is unsupported" "help documents foreground-only operation"
expect_contains "--reasoning-effort" "help documents verbatim effort forwarding"
run_case background "$TEST_DISPATCH" --prompt x --background
expect_status 2 "--background is refused"
expect_contains "unsupported" "--background refusal explains lifecycle owner"
if grep -q 'ADAPTER_VERSION="1"' "$DISPATCH"; then pass "adapter version is pinned"; else fail "adapter version is pinned"; fi
if grep -q 'SMOKE_SCHEMA="1"' "$DISPATCH"; then pass "smoke schema is pinned"; else fail "smoke schema is pinned"; fi
if grep -q 'info.st_uid != os.getuid()' "$DISPATCH"; then pass "wrong-owner allowlist check is present"; else fail "wrong-owner allowlist check is present"; fi
if ! grep -qE 'grep.*toml|sed.*toml|awk.*toml' "$DISPATCH"; then pass "dispatcher has no regex TOML parser"; else fail "dispatcher has no regex TOML parser"; fi
if ! grep -Eq '^[[:space:]]*(command[[:space:]]+)?git[[:space:]]' "$VERIFIER"; then pass "verifier source invokes no git command"; else fail "verifier source invokes no git command"; fi

# Verifier: pass, missing/stale/wrong-worktree, and every marker mutation class.
VERIFY_ROOT="$TMP_ROOT/verifier-worktree"
mkdir -p "$VERIFY_ROOT"
printf 'gitdir: /protected/gitdir\n' > "$VERIFY_ROOT/.git"
make_baseline() {
  python3 - "$VERIFY_ROOT" "$TMP_ROOT/verifier-baseline.json" <<'PY'
import hashlib, json, os, stat, sys
root, output = sys.argv[1:]
path = os.path.join(root, ".git")
info = os.lstat(path)
entry = {"path": ".git", "type": "file", "dev": info.st_dev, "inode": info.st_ino,
         "nlink": info.st_nlink, "size": info.st_size,
         "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns,
         "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}
json.dump({"schema": "1", "status": "active", "worktree": os.path.realpath(root), "markers": [entry]}, open(output, "w"))
PY
}
make_baseline
run_case verifier-pass "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 0 "verifier accepts matching baseline"
expect_contains "verified:" "verifier reports the recorded worktree"
run_case verifier-missing "$VERIFIER" --baseline "$TMP_ROOT/no-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 3 "verifier refuses missing baseline"
cp "$TMP_ROOT/verifier-baseline.json" "$TMP_ROOT/stale.json"
python3 - "$TMP_ROOT/stale.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["status"] = "retired"
json.dump(data, open(path, "w"))
PY
run_case verifier-stale "$VERIFIER" --baseline "$TMP_ROOT/stale.json" --worktree "$VERIFY_ROOT"
expect_status 3 "verifier refuses stale baseline"
mkdir "$TMP_ROOT/wrong-worktree"
printf 'gitdir: /protected/gitdir\n' > "$TMP_ROOT/wrong-worktree/.git"
run_case verifier-wrong "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$TMP_ROOT/wrong-worktree"
expect_status 3 "verifier refuses wrong worktree"

make_baseline
printf X >> "$VERIFY_ROOT/.git"
run_case verifier-bytes "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 2 "verifier catches byte change"
printf 'gitdir: /protected/gitdir\n' > "$VERIFY_ROOT/.git"
make_baseline
rm "$VERIFY_ROOT/.git"
printf 'gitdir: /protected/gitdir\n' > "$VERIFY_ROOT/.git"
run_case verifier-recreate "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 2 "verifier catches delete-recreate with identical bytes"
make_baseline
mv "$VERIFY_ROOT/.git" "$TMP_ROOT/marker-target"
ln -s "$TMP_ROOT/marker-target" "$VERIFY_ROOT/.git"
run_case verifier-symlink "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 2 "verifier catches symlink swap"
rm "$VERIFY_ROOT/.git"
printf 'gitdir: /protected/gitdir\n' > "$VERIFY_ROOT/.git"
make_baseline
cp "$VERIFY_ROOT/.git" "$TMP_ROOT/hard-target"
rm "$VERIFY_ROOT/.git"
ln "$TMP_ROOT/hard-target" "$VERIFY_ROOT/.git"
run_case verifier-hardlink "$VERIFIER" --baseline "$TMP_ROOT/verifier-baseline.json" --worktree "$VERIFY_ROOT"
expect_status 2 "verifier catches hardlink swap"
rm "$VERIFY_ROOT/.git"
printf 'gitdir: /protected/gitdir\n' > "$VERIFY_ROOT/.git"

# One clean read-only dispatch pins home preparation, empty MCP, JSON/session,
# summary fields, auth copy, and required argv.
new_readonly_fixture clean
mkdir -p "$FIX_HOME/.grok"
printf '{"token":"fixture"}\n' > "$FIX_HOME/.grok/auth.json"
chmod 600 "$FIX_HOME/.grok/auth.json"
dispatch_case clean "$FIX_HOME" "$FIX_REPO" --read-only --model model-x --effort strange-effort
expect_status 0 "clean read-only dispatch succeeds"
expect_contains "grok dispatch summary:" "summary header is present"
expect_contains "workspace: $FIX_REPO" "summary names workspace"
expect_contains "grok version: 1.0.4" "summary names grok version"
expect_contains "model: model-x (explicit)" "summary names model provenance"
expect_contains "effort: strange-effort (explicit)" "summary names effort provenance"
expect_contains "mode: read-only" "summary names read-only mode"
expect_contains "profile: olddonkey-loop-readonly" "summary names custom profile"
expect_contains "allowlist: carve-out (repo: $FIX_REPO)" "summary names per-repo carve-out"
expect_contains "session id: session-123" "summary captures session id"
expect_contains "authoritative path: $FIX_REPO" "read-only authority remains in place"
expect_contains "publication remains prohibited" "summary discloses macOS network carve-out"
expect_file_contains "$TMP_ROOT/clean.grok.log" "--disable-web-search" "dispatch always disables web search"
expect_file_contains "$TMP_ROOT/clean.grok.log" "--permission-mode bypassPermissions" "read-only always bypasses headless app approval"
expect_file_contains "$TMP_ROOT/clean.grok.log" "--verbatim" "dispatch always uses verbatim prompt"
expect_file_contains "$TMP_ROOT/clean.grok.log" "--sandbox olddonkey-loop-readonly" "read-only uses custom sandbox"
expect_file_contains "$TMP_ROOT/clean.grok.log" "--reasoning-effort strange-effort" "effort forwards verbatim"
expect_file_contains "$TMP_ROOT/clean.grok.log" "-m model-x" "model forwards with -m"
expect_file_contains "$TMP_ROOT/clean.grok.log" "mcp|$FIX_REPO|$FIX_HOME/.config/olddonkey-loop/grok-homes/" "MCP query uses target cwd and dispatch home"
CLEAN_HOME="$(awk -F'|' '/^dispatch\|/ {print $3; exit}' "$TMP_ROOT/clean.grok.log")"
if [[ "$CLEAN_HOME" == "$FIX_HOME/.config/olddonkey-loop/grok-homes/"* ]]; then pass "fresh GROK_HOME uses fixed root"; else fail "fresh GROK_HOME uses fixed root"; fi
expect_file_mode "$CLEAN_HOME/auth.json" 600 "auth.json copy is mode 0600"
expect_file_contains "$CLEAN_HOME/config.toml" 'inherit = "core"' "fresh policy uses core inheritance"
expect_file_contains "$CLEAN_HOME/config.toml" 'ignore_default_excludes = false' "fresh policy enables secret-name exclusions"
expect_file_contains "$CLEAN_HOME/config.toml" 'mcps = false' "fresh policy disables compat MCP ingestion"
expect_file_contains "$CLEAN_HOME/sandbox.toml" 'extends = "read-only"' "fresh home defines read-only custom profile"

# Profile and policy fail-closed matrix.
for variant in absent malformed wrong-base broadened network-override unknown-field; do
  new_readonly_fixture "profile-$variant"
  : > "$TMP_ROOT/profile-$variant.grok.log"
  run_case "profile-$variant" env HOME="$FIX_HOME" PATH="$TEST_PATH" \
    GROK_STUB_LOG="$TMP_ROOT/profile-$variant.grok.log" GROK_LOOP_SELFTEST_PROFILE_VARIANT="$variant" \
    bash -c 'cd "$1" && exec "$2" --prompt x --read-only' _ "$FIX_REPO" "$TEST_DISPATCH"
  expect_nonzero "profile validation refuses $variant"
  expect_contains "generated grok control validation failed" "profile $variant fails before launch"
  expect_not_contains "dispatch|" "profile $variant never dispatches grok"
done
new_readonly_fixture policy-drift
run_case policy-drift env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/policy-drift.log" \
  GROK_LOOP_SELFTEST_POLICY_VARIANT=unfiltered bash -c 'cd "$1" && exec "$2" --prompt x --read-only' _ "$FIX_REPO" "$TEST_DISPATCH"
expect_nonzero "shell-policy drift refuses dispatch"
expect_contains "shell_environment_policy" "shell-policy refusal is explicit"

new_readonly_fixture project-shadow
mkdir -p "$FIX_REPO/.grok"
printf '[profiles.olddonkey-loop-readonly]\nextends="strict"\n' > "$FIX_REPO/.grok/sandbox.toml"
dispatch_case project-shadow "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "project profile shadow is refused"
expect_contains "shadows loop-owned" "project shadow refusal names the conflict"
printf '[profiles.broken\n' > "$FIX_REPO/.grok/sandbox.toml"
dispatch_case project-malformed "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "malformed project sandbox TOML is refused"
expect_contains "malformed project sandbox" "malformed project sandbox refusal is explicit"

# Generated GROK_HOME resolution and symlink refusal.
new_readonly_fixture symlink-home
mkdir -p "$FIX_HOME/.config/olddonkey-loop"
mkdir "$TMP_ROOT/home-target"
ln -s "$TMP_ROOT/home-target" "$FIX_HOME/.config/olddonkey-loop/grok-homes"
dispatch_case symlink-home "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "symlinked GROK_HOME root is refused"
expect_contains "symlinked GROK_HOME root" "symlinked-home refusal is explicit"

# Allowlist source integrity. Every malformed source is exercised in both
# modes; implement reaches the same trust gate before worktree checks.
allowlist_both_modes() { # $1=case stem $2=home $3=repo
  local stem="$1" home="$2" repo="$3" mode suffix
  for mode in read-only implement; do
    suffix="$stem-$mode"
    if [[ "$mode" == read-only ]]; then
      dispatch_case "$suffix" "$home" "$repo" --read-only
    else
      dispatch_case "$suffix" "$home" "$repo"
    fi
    expect_nonzero "$stem refuses $mode mode"
    expect_contains "allowlist refused" "$stem refusal comes from allowlist integrity"
  done
}

new_readonly_fixture allow-symlink
ALLOW="$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
mv "$ALLOW" "$ALLOW.real"
ln -s "$ALLOW.real" "$ALLOW"
allowlist_both_modes allowlist-symlink "$FIX_HOME" "$FIX_REPO"

new_readonly_fixture allow-loose
chmod 666 "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
allowlist_both_modes allowlist-loose-perms "$FIX_HOME" "$FIX_REPO"

new_readonly_fixture allow-malformed
printf '[[carve_out]\n' > "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
chmod 600 "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
allowlist_both_modes allowlist-malformed "$FIX_HOME" "$FIX_REPO"

new_readonly_fixture allow-duplicate
cat >> "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml" <<'EOF'
os = "duplicate"
EOF
allowlist_both_modes allowlist-duplicate-key "$FIX_HOME" "$FIX_REPO"

new_readonly_fixture allow-conflict
ALLOW="$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
cat >> "$ALLOW" <<EOF
[[enforced]]
os = "darwin"
arch = "arm64"
grok_version = "1.0.4"
kernel = "25.6.0"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$PROFILE_HASH"
policy_hash = "$POLICY_HASH"
EOF
allowlist_both_modes allowlist-conflicting-types "$FIX_HOME" "$FIX_REPO"

REPO_REACHABLE="$TMP_ROOT/allow-repo-reachable"
init_repo "$REPO_REACHABLE"
REPO_HOME="$REPO_REACHABLE/selftest-home"
mkdir -p "$REPO_HOME"
write_allowlist "$REPO_HOME" "$REPO_REACHABLE"
allowlist_both_modes allowlist-repo-reachable "$REPO_HOME" "$REPO_REACHABLE"

# Exercise the wrong-owner predicate with real python3 plus a selftest-only
# sitecustomize that makes the invoking uid differ from the fixture's st_uid.
new_readonly_fixture allow-wrong-owner
UID_HOOK="$TMP_ROOT/wrong-owner-python"
mkdir "$UID_HOOK"
write_lines "$UID_HOOK/sitecustomize.py" \
  'import os' \
  '_real_getuid = os.getuid' \
  'os.getuid = lambda: _real_getuid() + 1'
for mode in read-only implement; do
  flags=()
  [[ "$mode" == read-only ]] && flags+=(--read-only)
  run_case "allow-wrong-owner-$mode" env HOME="$FIX_HOME" PATH="$TEST_PATH" \
    PYTHONPATH="$UID_HOOK" GROK_STUB_LOG="$TMP_ROOT/allow-wrong-owner-$mode.log" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$FIX_REPO" "$TEST_DISPATCH" --prompt x ${flags[@]+"${flags[@]}"}
  expect_nonzero "wrong-owner allowlist refuses $mode mode"
  expect_contains "source owner uid" "wrong-owner refusal is explicit in $mode mode"
done

# Tuple and carve-out record matrix.
new_readonly_fixture tuple-absent
: > "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
dispatch_case tuple-absent "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "absent tuple entry refuses"
expect_contains "tuple is unlisted" "absent tuple refusal names unlisted tuple"

new_readonly_fixture tuple-wrong-repo
write_allowlist "$FIX_HOME" "$FIX_REPO" 1.0.4 25.6.0 "$TMP_ROOT/not-this-repo"
dispatch_case tuple-wrong-repo "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "wrong-repo carve-out refuses"

new_readonly_fixture tuple-wrong
write_allowlist "$FIX_HOME" "$FIX_REPO" 1.0.4 wrong-kernel
dispatch_case tuple-wrong "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "wrong mechanism tuple refuses"

new_readonly_fixture tuple-stale
dispatch_case tuple-stale "$FIX_HOME" "$FIX_REPO" --read-only
expect_status 0 "matching tuple version passes"
: > "$TMP_ROOT/tuple-stale-version.grok.log"
run_case tuple-stale-version env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/tuple-stale-version.grok.log" \
  GROK_STUB_VERSION=1.0.5 bash -c 'cd "$1" && exec "$2" --prompt x --read-only' _ "$FIX_REPO" "$TEST_DISPATCH"
expect_nonzero "grok upgrade expires tuple approval"
expect_contains "tuple is unlisted" "stale-version refusal is tuple-gated"

new_readonly_fixture tuple-env-only
: > "$FIX_HOME/.config/olddonkey-loop/grok-backend.toml"
run_case tuple-env-only env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/tuple-env-only.log" \
  GROK_LOOP_ALLOW_UNENFORCED=1 GROK_ALLOW_NETWORK_CARVE_OUT=1 \
  bash -c 'cd "$1" && exec "$2" --prompt x --read-only' _ "$FIX_REPO" "$TEST_DISPATCH"
expect_nonzero "ambient env-only carve-out is ignored"
expect_contains "tuple is unlisted" "env-only case still requires allowlist entry"

new_readonly_fixture darwin-enforced
write_allowlist "$FIX_HOME" "$FIX_REPO" 1.0.4 25.6.0 "$FIX_REPO" enforced
dispatch_case darwin-enforced "$FIX_HOME" "$FIX_REPO" --read-only
expect_nonzero "darwin enforced entry is refused"
expect_contains "network restriction is a no-op" "darwin cannot claim enforced containment"

new_readonly_fixture linux-unlisted
run_case linux-unlisted env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/linux-unlisted.log" \
  GROK_STUB_OS=Linux GROK_STUB_KERNEL=6.8.0 bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$TEST_DISPATCH"
expect_nonzero "unprobed Linux tuple refuses implement mode"
expect_contains "tuple is unlisted" "Linux refusal uses the tuple gate"

# Independent per-repo grant and revocation.
MULTI_HOME="$TMP_ROOT/multi-home"
REPO_A="$TMP_ROOT/multi-a"
REPO_B="$TMP_ROOT/multi-b"
mkdir -p "$MULTI_HOME"
init_repo "$REPO_A"
init_repo "$REPO_B"
write_allowlist "$MULTI_HOME" "$REPO_A"
ALLOW="$MULTI_HOME/.config/olddonkey-loop/grok-backend.toml"
python3 - "$ALLOW" "$REPO_B" <<'PY'
from pathlib import Path
import sys
path, repo = sys.argv[1:]
text = Path(path).read_text()
block = text.replace("[[carve_out]]", "\n[[carve_out]]", 1).replace(
    next(line for line in text.splitlines() if line.startswith('repo = ')),
    f'repo = "{repo}"',
)
Path(path).write_text(text + block)
PY
dispatch_case multi-a "$MULTI_HOME" "$REPO_A" --read-only
expect_status 0 "repo A independent carve-out passes"
dispatch_case multi-b "$MULTI_HOME" "$REPO_B" --read-only
expect_status 0 "repo B independent carve-out passes"
python3 - "$ALLOW" "$REPO_A" <<'PY'
from pathlib import Path
import sys
path, repo = sys.argv[1:]
blocks = Path(path).read_text().split("[[carve_out]]")
kept = [block for block in blocks[1:] if f'repo = "{repo}"' not in block]
Path(path).write_text("".join("[[carve_out]]" + block for block in kept))
PY
dispatch_case multi-a-revoked "$MULTI_HOME" "$REPO_A" --read-only
expect_nonzero "revoking repo A does not inherit repo B grant"
dispatch_case multi-b-retained "$MULTI_HOME" "$REPO_B" --read-only
expect_status 0 "repo B grant survives repo A revocation"

# Loaded-tool graph: zero passes; nonzero, invalid JSON, and command failure
# refuse both modes before launch.
for graph in nonzero bad fail; do
  new_readonly_fixture "mcp-$graph"
  for mode in read-only implement; do
    : > "$TMP_ROOT/mcp-$graph-$mode.log"
    flags=()
    [[ "$mode" == read-only ]] && flags+=(--read-only)
    run_case "mcp-$graph-$mode" env HOME="$FIX_HOME" PATH="$TEST_PATH" \
      GROK_STUB_LOG="$TMP_ROOT/mcp-$graph-$mode.log" GROK_STUB_MCP="$graph" \
      bash -c 'cd "$1" && shift && exec "$@"' _ "$FIX_REPO" "$TEST_DISPATCH" --prompt x ${flags[@]+"${flags[@]}"}
    expect_nonzero "MCP $graph refuses $mode mode"
    expect_contains "MCP graph" "MCP $graph refusal is explicit in $mode mode"
    expect_not_contains "dispatch|" "MCP $graph refuses before agent launch in $mode mode"
  done
done

# Worktree preconditions.
new_readonly_fixture normal-implement
dispatch_case normal-implement "$FIX_HOME" "$FIX_REPO"
expect_nonzero "normal checkout refuses implement mode"
expect_contains "linked-worktree git dir outside CWD" "normal checkout refusal names external git-dir requirement"

new_linked_fixture submodule-inside
mkdir -p "$FIX_REPO/nested"
printf 'gitdir: %s\n' "$FIX_REPO/nested/internal-git" > "$FIX_REPO/nested/.git"
mkdir "$FIX_REPO/nested/internal-git"
dispatch_case submodule-inside "$FIX_HOME" "$FIX_REPO"
expect_nonzero "submodule git dir inside CWD is refused"
expect_contains "marker resolves to git state inside CWD" "submodule refusal names marker target"

new_linked_fixture dotgit-directory
mkdir -p "$FIX_REPO/nested/.git"
dispatch_case dotgit-directory "$FIX_HOME" "$FIX_REPO"
expect_nonzero "in-CWD .git directory is refused"
expect_contains "in-CWD .git directory is forbidden" "in-CWD .git-directory refusal is explicit"

if grep -q 'in-CWD .git directory is forbidden' "$DISPATCH"; then pass "in-CWD .git directory precondition is pinned"; else fail "in-CWD .git directory precondition is pinned"; fi
if grep -q '"git common dir"' "$DISPATCH"; then pass "git common-dir outside-CWD precondition is pinned"; else fail "git common-dir outside-CWD precondition is pinned"; fi

# Every protected path under temp and the fresh GROK_HOME refuses both modes.
# The test-only layouts only move a path into danger and therefore cannot
# weaken or bypass the production overlap boundary.
for writable_root in temp home; do
  for protected in workspace git-dir common-dir baseline snapshot; do
    for mode in read-only implement; do
      flags=()
      if [[ "$mode" == read-only ]]; then
        new_readonly_fixture "overlap-$writable_root-$protected-$mode"
        flags+=(--read-only)
      else
        new_linked_fixture "overlap-$writable_root-$protected-$mode"
      fi
      : > "$TMP_ROOT/overlap-$writable_root-$protected-$mode.log"
      run_case "overlap-$writable_root-$protected-$mode" env HOME="$FIX_HOME" PATH="$TEST_PATH" \
        GROK_STUB_LOG="$TMP_ROOT/overlap-$writable_root-$protected-$mode.log" \
        GROK_LOOP_SELFTEST_PATH_LAYOUT="$writable_root:$protected" \
        bash -c 'cd "$1" && shift && exec "$@"' _ "$FIX_REPO" "$TEST_DISPATCH" --prompt x ${flags[@]+"${flags[@]}"}
      expect_nonzero "$protected under $writable_root refuses $mode mode"
      expect_contains "overlaps sandbox-writable root" "$protected/$writable_root overlap is identified in $mode mode"
    done
  done
done

# Successful implement transition: edit, PGID teardown, copy, marker verify,
# independent registration, repair, fresh baseline, journal, ledger, authority,
# and no resume.
new_linked_fixture implement-ok
ORIGINAL_ADMIN_BEFORE="$(git -C "$FIX_REPO" rev-parse --absolute-git-dir)"
ORIGINAL_HEAD_BEFORE="$(git -C "$FIX_REPO" rev-parse HEAD)"
ORIGINAL_BRANCH_BEFORE="$(git -C "$FIX_REPO" branch --show-current)"
: > "$TMP_ROOT/implement-ok.grok.log"
run_case implement-ok env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/implement-ok.grok.log" \
  GROK_STUB_ACTION=edit bash -c 'cd "$1" && exec "$2" --prompt x --effort any-value' _ "$FIX_REPO" "$TEST_DISPATCH"
expect_status 0 "linked-worktree implement dispatch succeeds"
expect_contains "mode: implement" "implement summary names mode"
expect_contains "profile: olddonkey-loop-implement" "implement summary names custom profile"
expect_contains "session id: session-123" "implement summary captures session"
expect_not_contains "repair: gitdir incorrect" "independent registration needs no hijack repair"
expect_file_contains "$TMP_ROOT/implement-ok.grok.log" "--permission-mode bypassPermissions" "implement always bypasses headless app approval"
AUTH_PATH="$(sed -n 's/^authoritative path: //p' "$CASE_OUTPUT")"
if [[ -d "$AUTH_PATH" && "$AUTH_PATH" != "$FIX_REPO" ]]; then pass "implement transition changes authoritative path"; else fail "implement transition changes authoritative path"; fi
expect_file_contains "$AUTH_PATH/tracked.txt" changed "snapshot contains implementer diff"
AUTH_ADMIN="$(git -C "$AUTH_PATH" rev-parse --absolute-git-dir)"
ORIGINAL_ADMIN_AFTER="$(git -C "$FIX_REPO" rev-parse --absolute-git-dir)"
if [[ "$AUTH_ADMIN" != "$ORIGINAL_ADMIN_AFTER" ]]; then pass "snapshot and source use independent admin directories"; else fail "snapshot and source use independent admin directories"; fi
if [[ "$ORIGINAL_ADMIN_AFTER" == "$ORIGINAL_ADMIN_BEFORE" ]]; then pass "original unit keeps its own admin registration"; else fail "original unit keeps its own admin registration"; fi
run_case original-unit-status git -C "$FIX_REPO" status --porcelain=v1
expect_status 0 "original unit status still works after transition"
WORKTREE_LIST="$(git -C "$FIX_MAIN" worktree list --porcelain)"
if printf '%s\n' "$WORKTREE_LIST" | grep -qxF "worktree $AUTH_PATH"; then pass "worktree list registers the snapshot path"; else fail "worktree list registers the snapshot path"; fi
if printf '%s\n' "$WORKTREE_LIST" | grep -qxF "worktree $FIX_REPO"; then pass "worktree list preserves the original unit path"; else fail "worktree list preserves the original unit path"; fi
expect_file_contains "$AUTH_PATH/.git" "$AUTH_ADMIN" "snapshot marker points at its independent admin directory"
AUTH_BRANCH="$(git -C "$AUTH_PATH" branch --show-current)"
ORIGINAL_BRANCH_AFTER="$(git -C "$FIX_REPO" branch --show-current)"
if [[ "$AUTH_BRANCH" == "$ORIGINAL_BRANCH_BEFORE" ]]; then pass "authoritative snapshot keeps the unit branch"; else fail "authoritative snapshot keeps the unit branch"; fi
if [[ -z "$ORIGINAL_BRANCH_AFTER" ]]; then pass "retired original is detached from the unit branch"; else fail "retired original is detached from the unit branch"; fi
AUTH_HEAD_BEFORE="$(git -C "$AUTH_PATH" rev-parse HEAD)"
run_case snapshot-commit git -C "$AUTH_PATH" commit -am "snapshot topology selftest" -q
expect_status 0 "snapshot can commit through its independent registration"
ORIGINAL_HEAD_AFTER="$(git -C "$FIX_REPO" rev-parse HEAD)"
AUTH_HEAD_AFTER="$(git -C "$AUTH_PATH" rev-parse HEAD)"
if [[ "$ORIGINAL_HEAD_AFTER" == "$ORIGINAL_HEAD_BEFORE" ]]; then pass "snapshot commit does not move original unit HEAD"; else fail "snapshot commit does not move original unit HEAD"; fi
if [[ "$AUTH_HEAD_AFTER" != "$AUTH_HEAD_BEFORE" ]]; then pass "snapshot commit advances only authoritative HEAD"; else fail "snapshot commit advances only authoritative HEAD"; fi
STATE_ROOT="$(common_dir_abs "$AUTH_PATH")/olddonkey-loop/grok"
STATE_DIR="$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
for event in prepared transition-required grok-exited group-killed copied markers-verified closure-validated independent-registration worktree-repaired fresh-baseline authoritative-recorded; do
  expect_file_contains "$STATE_DIR/transition.jsonl" "\"event\": \"$event\"" "journal records $event"
done
expect_file_contains "$STATE_ROOT/writable-ledger.tsv" terminated "ledger records retired writable generation"
if ! pgrep -g "$(cat "$STATE_DIR/pgid")" >/dev/null 2>&1; then pass "recorded process group is empty before authority transition"; else fail "recorded process group is empty before authority transition"; fi
for call_site in pre-review pre-commit pre-gate pre-publish; do
  run_case "authoritative-verify-$call_site" "$VERIFIER" \
    --baseline "$STATE_DIR/authoritative-baseline.json" --worktree "$AUTH_PATH"
  expect_status 0 "authoritative baseline passes no-git verifier at $call_site"
done

: > "$TMP_ROOT/resume-after-transition.log"
run_case resume-after-transition env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/resume-after-transition.log" \
  bash -c 'cd "$1" && exec "$2" --prompt iterate --resume' _ "$AUTH_PATH" "$TEST_DISPATCH"
expect_nonzero "resume after implement transition is refused"
expect_contains "authoritative path is unchanged" "resume refusal explains workspace stickiness"
expect_not_contains "--resume session-123" "resume refusal never launches sticky session"

# Read-only exact-ID resume stays in place and forwards the captured handle.
new_readonly_fixture resume-readonly
dispatch_case resume-readonly-first "$FIX_HOME" "$FIX_REPO" --read-only
expect_status 0 "initial read-only session succeeds"
dispatch_case resume-readonly-second "$FIX_HOME" "$FIX_REPO" --read-only --resume
expect_status 0 "read-only exact-ID resume succeeds on unchanged path"
expect_file_contains "$TMP_ROOT/resume-readonly-second.grok.log" "--resume session-123" "resume forwards exact session id"
expect_contains "resume: exact session-123" "summary names exact resume handle"

# Snapshot closure refusals.
for action in old-symlink home-symlink ledger-symlink special; do
  new_linked_fixture "closure-$action"
  if [[ "$action" == ledger-symlink ]]; then
    HISTORICAL="$TMP_ROOT/historical-writable"
    mkdir -p "$HISTORICAL"
    printf 'historical\n' > "$HISTORICAL/target"
    CLOSURE_COMMON="$(common_dir_abs "$FIX_REPO")"
    mkdir -p "$CLOSURE_COMMON/olddonkey-loop/grok"
    printf '%s\told-generation\tterminated\n' "$HISTORICAL" > "$CLOSURE_COMMON/olddonkey-loop/grok/writable-ledger.tsv"
  else
    HISTORICAL=""
  fi
  : > "$TMP_ROOT/closure-$action.grok.log"
  run_case "closure-$action" env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/closure-$action.grok.log" \
    GROK_STUB_ACTION="$action" GROK_STUB_LEDGER_TARGET="${HISTORICAL:+$HISTORICAL/target}" \
    bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$TEST_DISPATCH"
  expect_nonzero "snapshot closure refuses $action"
  if [[ "$action" == special ]]; then
    expect_contains "unsafe special file" "special-file closure refusal is explicit"
  else
    expect_contains "historical writable root" "$action closure refusal is explicit"
  fi
done
if grep -q 'hard link escapes closure' "$DISPATCH"; then pass "closure validation covers escaping hard links"; else fail "closure validation covers escaping hard links"; fi

# Transition journal interruption after every ordered transition step. Each
# injected exit leaves a protected incomplete journal, satisfying the
# complete-forward-or-refuse crash rule without silently trusting a half-state.
for step in transition-required grok-exited group-killed copied markers-verified closure-validated independent-registration worktree-repaired fresh-baseline authoritative-recorded; do
  new_linked_fixture "interrupt-$step"
  : > "$TMP_ROOT/interrupt-$step.grok.log"
  run_case "interrupt-$step" env HOME="$FIX_HOME" PATH="$TEST_PATH" GROK_STUB_LOG="$TMP_ROOT/interrupt-$step.grok.log" \
    GROK_LOOP_SELFTEST_INTERRUPT_AFTER="$step" bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$TEST_DISPATCH"
  expect_status 86 "journal interruption fires after $step"
  INTERRUPT_ROOT="$(common_dir_abs "$FIX_MAIN")/olddonkey-loop/grok"
  INTERRUPT_STATE="$(find "$INTERRUPT_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
  expect_file_contains "$INTERRUPT_STATE/transition.jsonl" "\"event\": \"$step\"" "journal durably records interrupted $step"
  if [[ "$step" != authoritative-recorded ]]; then
    write_allowlist "$FIX_HOME" "$FIX_REPO"
    dispatch_case "interrupt-retry-$step" "$FIX_HOME" "$FIX_REPO"
    expect_nonzero "startup refuses incomplete transition after $step"
    expect_contains "completed forward or refused" "incomplete $step transition is never half-trusted"
  fi
done
if grep -q 'interrupted grok transition must be completed forward or refused' "$DISPATCH"; then pass "startup pins complete-forward-or-refuse behavior"; else fail "startup pins complete-forward-or-refuse behavior"; fi

# Fresh homes are per dispatch and carry no session state across generations.
new_readonly_fixture fresh-homes
dispatch_case fresh-one "$FIX_HOME" "$FIX_REPO" --read-only
expect_status 0 "first fresh-home dispatch succeeds"
dispatch_case fresh-two "$FIX_HOME" "$FIX_REPO" --read-only
expect_status 0 "second fresh-home dispatch succeeds"
HOME_ONE="$(awk -F'|' '/^dispatch\|/ {print $3; exit}' "$TMP_ROOT/fresh-one.grok.log")"
HOME_TWO="$(awk -F'|' '/^dispatch\|/ {print $3; exit}' "$TMP_ROOT/fresh-two.grok.log")"
if [[ "$HOME_ONE" != "$HOME_TWO" ]]; then pass "dispatches use distinct fresh GROK_HOME paths"; else fail "dispatches use distinct fresh GROK_HOME paths"; fi
if [[ ! -e "$HOME_TWO/sessions" ]]; then pass "fresh home does not copy session state"; else fail "fresh home does not copy session state"; fi

EXPECTED_CHECKS=276
if [[ $CHECKS -ne $EXPECTED_CHECKS ]]; then
  printf 'selftest: FAIL (count drift: got %d, expected %d)\n' "$CHECKS" "$EXPECTED_CHECKS" >&2
  exit 1
fi
if [[ $FAILURES -ne 0 ]]; then
  printf 'selftest: FAIL (%d/%d checks failed)\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
