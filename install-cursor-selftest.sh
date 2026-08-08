#!/usr/bin/env bash
# Sandboxed regression checks for install-cursor.sh. Every installer run uses
# a fresh HOME and a local-path clone source, so no network access is possible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-cursor.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/install-cursor-selftest.XXXXXX")" || \
  exit 1

cleanup() { # $1=status to preserve
  local status="$1"
  trap - EXIT HUP INT TERM
  rm -rf "$TMP_ROOT" || true
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export GIT_AUTHOR_NAME="Cursor Installer Selftest"
export GIT_AUTHOR_EMAIL="cursor-installer-selftest@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_ALLOW_PROTOCOL=file
export LC_ALL=C

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

abort() {
  printf 'selftest: FAIL (setup error: %s)\n' "$1" >&2
  exit 1
}

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$CASE_STDERR" >&2
  fi
}

new_home() { # $1=case slug
  mktemp -d "$TMP_ROOT/$1.home.XXXXXX" || \
    abort "cannot create HOME sandbox for $1"
}

run_installer() { # $1=name $2=HOME $3=checkout, remaining args=installer args
  local name="$1" case_home="$2" checkout="$3"
  shift 3
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if HOME="$case_home" \
      OLDDONKEY_SKILLS_DIR="$checkout" \
      OLDDONKEY_SKILLS_REPO="$SCRIPT_DIR" \
      bash "$INSTALLER" "$@" > "$CASE_STDOUT" 2> "$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
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

expect_output() { # $1=file $2=fixed text $3=description
  if grep -Fq -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3 (missing expected text: $2)"
  fi
}

expect_empty() { # $1=file $2=description
  if [[ ! -s "$1" ]]; then
    pass "$2"
  else
    fail "$2 (expected empty output)"
  fi
}

expect_file() { # $1=path $2=description
  if [[ -f "$1" ]]; then
    pass "$2"
  else
    fail "$2 (missing file: $1)"
  fi
}

expect_directory() { # $1=path $2=description
  if [[ -d "$1" && ! -L "$1" ]]; then
    pass "$2"
  else
    fail "$2 (missing real directory: $1)"
  fi
}

expect_missing() { # $1=path $2=description
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    pass "$2"
  else
    fail "$2 (unexpected path: $1)"
  fi
}

expect_symlink_target() { # $1=link $2=target $3=description
  local actual=""
  if [[ -L "$1" ]]; then
    actual="$(readlink "$1")" || actual=""
  fi
  if [[ -L "$1" && "$actual" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected target $2, got ${actual:-<not-a-symlink>})"
  fi
}

assert_no_installer_temps() { # $1=HOME $2=description prefix
  local case_home="$1" description="$2" leaked=""
  if [[ -d "$case_home/.cursor" ]]; then
    leaked="$(find "$case_home/.cursor" \
      \( -name '.cursor-implementation-loop.install.*' -o \
         -name '.cursor-implementation-loop.backup.*' -o \
         -name '.cursor-agents.install.*' -o \
         -name 'codex-loop-selftest.*' \) -print -quit)" || \
      abort "cannot inspect temporary paths for $description"
  fi
  if [[ -z "$leaked" ]]; then
    pass "$description cleans installer and gate temporary directories"
  else
    fail "$description leaked temporary path: $leaked"
  fi
}

cleanup_case_home() { # $1=HOME $2=description prefix
  local case_home="$1" description="$2"
  case "$case_home" in
    "$TMP_ROOT"/*) ;;
    *) abort "refusing to clean unexpected case HOME: $case_home" ;;
  esac
  if rm -rf "$case_home" && [[ ! -e "$case_home" ]]; then
    pass "$description removes its HOME sandbox"
  else
    fail "$description could not remove its HOME sandbox"
  fi
}

[[ -f "$INSTALLER" ]] || abort "installer not found: $INSTALLER"
git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  abort "selftest source is not a Git worktree: $SCRIPT_DIR"

# 1. Fresh default install copies the skill and agents, without a plugin link.
CASE_HOME="$(new_home fresh)"
CHECKOUT="$CASE_HOME/checkout"
COPY_SKILL="$CASE_HOME/.cursor/skills/cursor-implementation-loop"
run_installer fresh "$CASE_HOME" "$CHECKOUT"
expect_status 0 "fresh default install succeeds"
expect_directory "$COPY_SKILL" \
  "default mode installs the skill directory"
expect_file "$COPY_SKILL/scripts/gate-selftest.sh" \
  "default mode installs the gate selftest"
expect_file "$CASE_HOME/.cursor/agents/loop-implementer.md" \
  "default mode installs loop-implementer.md"
expect_file "$CASE_HOME/.cursor/agents/loop-independent-reviewer.md" \
  "default mode installs loop-independent-reviewer.md"
expect_missing "$CASE_HOME/.cursor/plugins/local/cursor-implementation-loop" \
  "default mode does not create a plugin symlink"
expect_output "$CASE_STDOUT" "Install mode: bare copy" \
  "fresh default install reports bare-copy mode"
expect_output "$CASE_STDOUT" "selftest: PASS" \
  "fresh install prints the installed gate selftest PASS line"
expect_output "$CASE_STDOUT" 'Developer: Reload Window' \
  "fresh install prints the Cursor reload next step"
expect_output "$CASE_STDOUT" '/cursor-implementation-loop' \
  "fresh install prints the slash-command next step"
expect_output "$CASE_STDOUT" 'model: inherit' \
  "fresh install recommends replacing the inherited implementer model"
expect_output "$CASE_STDOUT" 'Want true plugin form?' \
  "default install offers the true-plugin UI flow"
expect_output "$CASE_STDOUT" 'Customize → Plugins' \
  "default install names the Cursor Plugins page"
expect_output "$CASE_STDOUT" "    $CHECKOUT" \
  "default install prints the checkout root to select"
expect_output "$CASE_STDOUT" '.cursor-plugin/marketplace.json' \
  "default install identifies the bundled marketplace manifest"
expect_output "$CASE_STDOUT" \
  'rm -rf "$HOME/.cursor/skills/cursor-implementation-loop"' \
  "default install prints the standalone-skill removal command"
expect_output "$CASE_STDOUT" \
  'rm -f "$HOME/.cursor/agents/loop-implementer.md" "$HOME/.cursor/agents/loop-independent-reviewer.md"' \
  "default install prints the standalone-agent removal command"
assert_no_installer_temps "$CASE_HOME" "fresh install"
cleanup_case_home "$CASE_HOME" "fresh install"

# 2. --link retains the local-plugin symlink behavior, including idempotency.
CASE_HOME="$(new_home idempotent)"
CHECKOUT="$CASE_HOME/checkout"
PLUGIN_LINK="$CASE_HOME/.cursor/plugins/local/cursor-implementation-loop"
run_installer idempotent-setup "$CASE_HOME" "$CHECKOUT" --link
expect_status 0 "--link fixture's initial install succeeds"
expect_symlink_target "$PLUGIN_LINK" \
  "$CHECKOUT/cursor-implementation-loop" \
  "--link installs the plugin from its managed checkout"
expect_output "$CASE_STDOUT" "Install mode: symlink" \
  "--link install reports symlink mode"
expect_output "$CASE_STDOUT" "selftest: PASS" \
  "--link install verifies the installed plugin"
expect_output "$CASE_STDOUT" \
  'Warning: current Cursor builds may not scan plugins/local.' \
  "--link warns about current Cursor discovery behavior"
expect_output "$CASE_STDOUT" "and select $CHECKOUT." \
  "--link points the current Cursor UI alternative at the checkout root"
FIRST_LINK_TARGET="$(readlink "$PLUGIN_LINK" 2>/dev/null || true)"
FIRST_LINK_INODE="$(ls -di "$PLUGIN_LINK" 2>/dev/null | awk '{print $1}')"
run_installer idempotent-rerun "$CASE_HOME" "$CHECKOUT" --link
expect_status 0 "idempotent rerun succeeds"
SECOND_LINK_TARGET="$(readlink "$PLUGIN_LINK" 2>/dev/null || true)"
SECOND_LINK_INODE="$(ls -di "$PLUGIN_LINK" 2>/dev/null | awk '{print $1}')"
if [[ -n "$FIRST_LINK_TARGET" && "$FIRST_LINK_TARGET" == "$SECOND_LINK_TARGET" ]]; then
  pass "idempotent rerun leaves the symlink target unchanged"
else
  fail "idempotent rerun changed the symlink target"
fi
if [[ -n "$FIRST_LINK_INODE" && "$FIRST_LINK_INODE" == "$SECOND_LINK_INODE" ]]; then
  pass "idempotent rerun keeps the existing symlink instead of recreating it"
else
  fail "idempotent rerun recreated or lost the symlink"
fi
expect_output "$CASE_STDOUT" 'Updating checkout with git pull --ff-only' \
  "idempotent rerun exercises the fast-forward pull path"
expect_output "$CASE_STDOUT" 'selftest: PASS' \
  "idempotent rerun verifies the installed plugin"
assert_no_installer_temps "$CASE_HOME" "idempotent rerun"
cleanup_case_home "$CASE_HOME" "idempotent rerun"

# 3. --copy remains an explicit alias for the default bare-copy mode.
CASE_HOME="$(new_home copy)"
CHECKOUT="$CASE_HOME/checkout"
COPY_SKILL="$CASE_HOME/.cursor/skills/cursor-implementation-loop"
run_installer copy "$CASE_HOME" "$CHECKOUT" --copy
expect_status 0 "explicit --copy install succeeds"
expect_directory "$COPY_SKILL" "--copy installs the skill directory"
expect_file "$COPY_SKILL/scripts/gate-selftest.sh" \
  "--copy installs the gate selftest"
expect_file "$CASE_HOME/.cursor/agents/loop-implementer.md" \
  "--copy installs loop-implementer.md"
expect_file "$CASE_HOME/.cursor/agents/loop-independent-reviewer.md" \
  "--copy installs loop-independent-reviewer.md"
expect_missing "$CASE_HOME/.cursor/plugins/local/cursor-implementation-loop" \
  "--copy does not create a plugin symlink"
expect_output "$CASE_STDOUT" 'Install mode: bare copy' \
  "--copy reports bare-copy mode"
expect_output "$CASE_STDOUT" 'selftest: PASS' \
  "--copy verifies the installed skill"
expect_output "$CASE_STDOUT" 'Want true plugin form?' \
  "--copy prints the same plugin-form hint as the default"
assert_no_installer_temps "$CASE_HOME" "--copy install"
cleanup_case_home "$CASE_HOME" "--copy install"

# 4. A real directory at the plugin name is a conflict and must survive.
CASE_HOME="$(new_home conflict)"
CHECKOUT="$CASE_HOME/checkout"
CONFLICT="$CASE_HOME/.cursor/plugins/local/cursor-implementation-loop"
mkdir -p "$CONFLICT" || abort "cannot create conflict fixture"
printf 'keep me\n' > "$CONFLICT/sentinel.txt" || \
  abort "cannot create conflict sentinel"
run_installer conflict "$CASE_HOME" "$CHECKOUT" --link
expect_nonzero "plugin-name conflict fails closed"
expect_directory "$CONFLICT" "plugin-name conflict remains a real directory"
expect_file "$CONFLICT/sentinel.txt" "plugin-name conflict keeps its contents"
expect_output "$CASE_STDERR" \
  "$CONFLICT already exists and is not the expected symlink" \
  "plugin-name conflict reports the exact path and cause"
expect_missing "$CASE_HOME/.cursor/skills/cursor-implementation-loop" \
  "plugin-name conflict does not fall back by silently copying"
assert_no_installer_temps "$CASE_HOME" "plugin-name conflict"
cleanup_case_home "$CASE_HOME" "plugin-name conflict"

# 5. An unrelated checkout, including its worktree and Git state, is untouched.
CASE_HOME="$(new_home wrong-repo)"
CHECKOUT="$CASE_HOME/checkout"
git init -q "$CHECKOUT" || abort "cannot initialize wrong-repo fixture"
printf 'unrelated\n' > "$CHECKOUT/sentinel.txt" || \
  abort "cannot create wrong-repo sentinel"
git -C "$CHECKOUT" add sentinel.txt || abort "cannot stage wrong-repo fixture"
git -C "$CHECKOUT" -c commit.gpgsign=false commit -qm 'unrelated repo' || \
  abort "cannot commit wrong-repo fixture"
git -C "$CHECKOUT" remote add origin "$CASE_HOME/not-the-source" || \
  abort "cannot add wrong origin"
WRONG_BEFORE="$({
  git -C "$CHECKOUT" rev-parse HEAD
  git -C "$CHECKOUT" status --porcelain=v1
  git -C "$CHECKOUT" remote get-url origin
  cksum "$CHECKOUT/sentinel.txt"
})" || abort "cannot snapshot wrong-repo fixture"
run_installer wrong-repo "$CASE_HOME" "$CHECKOUT"
expect_nonzero "wrong-repo checkout fails closed"
expect_output "$CASE_STDERR" 'refusing to modify the wrong repository' \
  "wrong-repo checkout reports its origin mismatch"
WRONG_AFTER="$({
  git -C "$CHECKOUT" rev-parse HEAD
  git -C "$CHECKOUT" status --porcelain=v1
  git -C "$CHECKOUT" remote get-url origin
  cksum "$CHECKOUT/sentinel.txt"
})" || abort "cannot re-snapshot wrong-repo fixture"
if [[ "$WRONG_BEFORE" == "$WRONG_AFTER" ]]; then
  pass "wrong-repo checkout remains byte/state equivalent at its protected evidence"
else
  fail "wrong-repo checkout changed"
fi
expect_missing "$CASE_HOME/.cursor" \
  "wrong-repo failure does not begin Cursor installation"
assert_no_installer_temps "$CASE_HOME" "wrong-repo failure"
cleanup_case_home "$CASE_HOME" "wrong-repo failure"

# 6. Unknown arguments are usage errors before any checkout or Cursor write.
CASE_HOME="$(new_home unknown-flag)"
CHECKOUT="$CASE_HOME/checkout"
run_installer unknown-flag "$CASE_HOME" "$CHECKOUT" --not-a-real-flag
expect_status 2 "unknown flag exits with status 2"
expect_output "$CASE_STDERR" 'Usage:' \
  "unknown flag prints usage on stderr"
expect_output "$CASE_STDERR" 'unknown option: --not-a-real-flag' \
  "unknown flag names the rejected option"
expect_empty "$CASE_STDOUT" "unknown flag prints no stdout"
expect_missing "$CHECKOUT" "unknown flag does not create a checkout"
assert_no_installer_temps "$CASE_HOME" "unknown flag"
cleanup_case_home "$CASE_HOME" "unknown flag"

# The total assertion counts itself, matching the repository's selftest style.
EXPECTED_FINAL_CHECKS=64
CASE_STDOUT=""
CASE_STDERR=""
if [[ $((CHECKS + 1)) -eq $EXPECTED_FINAL_CHECKS ]]; then
  pass "selftest ran its expected final total of $EXPECTED_FINAL_CHECKS checks"
else
  fail "selftest expected $EXPECTED_FINAL_CHECKS final checks, got $((CHECKS + 1))"
fi

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' \
    "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
