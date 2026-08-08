#!/usr/bin/env bash
# Isolated regression checks for tree-oid.sh. Every fixture lives below a
# throwaway sandbox; no test initializes or commits in the host repository.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE_OID="$SCRIPT_DIR/tree-oid.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tree-oid-selftest.XXXXXX")" || exit 1
LOCKED_OBJECTS_DIR=""

cleanup() { # $1=status to preserve
  local status="$1"
  trap - EXIT HUP INT TERM
  if [[ -n "$LOCKED_OBJECTS_DIR" ]]; then
    chmod u+w "$LOCKED_OBJECTS_DIR" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" || true
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export GIT_AUTHOR_NAME="Tree OID Selftest"
export GIT_AUTHOR_EMAIL="tree-oid-selftest@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export LC_ALL=C

CHECKS=0
FAILED_CHECKS=0
RUN_STATUS=0
RUN_STDOUT=""
RUN_STDERR=""
RUN_OID=""

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
  if [[ -n "$RUN_STDOUT" && -s "$RUN_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$RUN_STDOUT" >&2
  fi
  if [[ -n "$RUN_STDERR" && -s "$RUN_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$RUN_STDERR" >&2
  fi
}

init_repo() { # $1=path
  mkdir -p "$1" || abort "cannot create repo directory: $1"
  git init -q "$1" || abort "git init failed: $1"
}

commit_all() { # $1=repo $2=message
  git -C "$1" add -A || abort "git add failed in $1"
  git -C "$1" -c commit.gpgsign=false commit -qm "$2" || \
    abort "git commit failed in $1"
}

worktree_manifest() { # $1=repo; main .git directory is administrative state
  local repo="$1"
  (
    cd "$repo" || exit 1
    LC_ALL=C find . -path './.git' -prune -o -print | LC_ALL=C sort |
      while IFS= read -r path; do
        if [[ -L "$path" ]]; then
          printf 'link\t%s\t%s\n' "$path" "$(readlink "$path")" || exit 1
        elif [[ -f "$path" ]]; then
          if [[ -x "$path" ]]; then executable=x; else executable=-; fi
          printf 'file\t%s\t%s\t' "$executable" "$path" || exit 1
          cksum < "$path" || exit 1
        elif [[ -d "$path" ]]; then
          printf 'dir\t%s\n' "$path" || exit 1
        else
          printf 'other\t%s\n' "$path" || exit 1
        fi
      done
  )
}

snapshot_repo() { # $1=repo $2=output prefix
  local repo="$1" prefix="$2"
  mkdir -p "$(dirname "$prefix")" || abort "cannot create snapshot directory"
  (
    cd "$repo" || exit 1
    GIT_OPTIONAL_LOCKS=0 git status --porcelain -z \
      --ignore-submodules=none --untracked-files=all
  ) > "$prefix.status" || abort "cannot snapshot status for $repo"
  (
    cd "$repo" || exit 1
    git for-each-ref --format='%(refname) %(objectname)'
  ) | LC_ALL=C sort > "$prefix.refs" || abort "cannot snapshot refs for $repo"
  cp "$repo/.git/HEAD" "$prefix.HEAD" || abort "cannot snapshot HEAD for $repo"
  if [[ -f "$repo/.git/index" ]]; then
    printf 'present\n' > "$prefix.index-state"
    cp "$repo/.git/index" "$prefix.index" || abort "cannot snapshot index for $repo"
  else
    printf 'missing\n' > "$prefix.index-state"
    : > "$prefix.index"
  fi
  worktree_manifest "$repo" > "$prefix.worktree" || \
    abort "cannot snapshot worktree for $repo"
}

assert_repo_unchanged() { # $1=before prefix $2=after prefix $3=description prefix
  local before="$1" after="$2" description="$3"
  if cmp -s "$before.index-state" "$after.index-state" &&
     cmp -s "$before.index" "$after.index"; then
    pass "$description leaves the real index unchanged (presence and bytes)"
  else
    fail "$description changed the real index"
  fi
  if cmp -s "$before.refs" "$after.refs" && cmp -s "$before.HEAD" "$after.HEAD"; then
    pass "$description leaves refs unchanged (refs listing and HEAD content)"
  else
    fail "$description changed refs"
  fi
  if cmp -s "$before.status" "$after.status" &&
     cmp -s "$before.worktree" "$after.worktree"; then
    pass "$description leaves status/worktree unchanged (status bytes and content-checksum manifest)"
  else
    fail "$description changed the status/worktree snapshot"
  fi
}

assert_temp_clean() { # $1=temp base $2=description prefix
  local temp_base="$1" description="$2"
  if [[ -z "$(find "$temp_base" -mindepth 1 -print -quit)" ]]; then
    pass "$description removes its temporary directory"
  else
    fail "$description leaked its temporary directory"
  fi
}

run_tree() { # $1=name $2=execution dir $3=repo to protect $4=temp base
  local name="$1" execution_dir="$2" repo="$3" temp_base="$4"
  local result_dir="$TMP_ROOT/results/$name"
  local before="$result_dir/before" after="$result_dir/after"

  mkdir -p "$result_dir" "$temp_base" || abort "cannot create run directories"
  [[ -z "$(find "$temp_base" -mindepth 1 -print -quit)" ]] || \
    abort "temp base was not empty before $name"
  RUN_STDOUT="$result_dir/stdout"
  RUN_STDERR="$result_dir/stderr"
  snapshot_repo "$repo" "$before"
  if (cd "$execution_dir" && TMPDIR="$temp_base" bash "$TREE_OID") \
      > "$RUN_STDOUT" 2> "$RUN_STDERR"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  snapshot_repo "$repo" "$after"
  assert_repo_unchanged "$before" "$after" "$name"
  assert_temp_clean "$temp_base" "$name"
}

expect_status() { # $1=expected $2=description
  if [[ $RUN_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $RUN_STATUS)"
  fi
}

expect_oid_output() { # $1=description; sets RUN_OID
  local description="$1" expected
  RUN_OID=""
  IFS= read -r RUN_OID < "$RUN_STDOUT" || true
  expected="$RUN_STDOUT.expected"
  printf '%s\n' "$RUN_OID" > "$expected"
  if [[ "$RUN_OID" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] &&
     cmp -s "$RUN_STDOUT" "$expected"; then
    pass "$description prints exactly one tree OID"
  else
    fail "$description did not print exactly one tree OID"
  fi
}

expect_empty_stdout() { # $1=description
  if [[ ! -s "$RUN_STDOUT" ]]; then
    pass "$1 prints no stdout"
  else
    fail "$1 printed stdout"
  fi
}

expect_one_line_stderr() { # $1=fixed text $2=description
  local lines
  lines="$(wc -l < "$RUN_STDERR" | tr -d '[:space:]')"
  if [[ "$lines" == "1" ]] && grep -Fq -- "$1" "$RUN_STDERR"; then
    pass "$2 prints one explanatory stderr line"
  else
    fail "$2 did not print the expected one-line explanation"
  fi
}

expect_stderr_contains() { # $1=fixed text $2=description
  if grep -Fq -- "$1" "$RUN_STDERR"; then
    pass "$2"
  else
    fail "$2 (missing expected stderr text: $1)"
  fi
}

expect_oid_changed() { # $1=old $2=new $3=description
  if [[ -n "$1" && -n "$2" && "$1" != "$2" ]]; then
    pass "$3"
  else
    fail "$3 (tree OIDs were equal)"
  fi
}

expect_oid_equal() { # $1=expected $2=actual $3=description
  if [[ -n "$1" && "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected $1, got $2)"
  fi
}

# 1. Normal HEAD: success, with tracked content affecting the identity.
CASE_ROOT="$TMP_ROOT/case-1-normal"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'before\n' > "$REPO/tracked.txt"
commit_all "$REPO" "initial"
ORACLE_REPO="$CASE_ROOT/oracle"
git clone -q "$REPO" "$ORACLE_REPO" || abort "cannot clone normal-HEAD oracle"
run_tree "normal-head-before" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "normal HEAD succeeds"
expect_oid_output "normal HEAD"
NORMAL_BEFORE="$RUN_OID"
printf 'after\n' > "$REPO/tracked.txt"
printf 'after\n' > "$ORACLE_REPO/tracked.txt"
git -C "$ORACLE_REPO" add -A || abort "oracle git add -A failed"
EXPECTED_NORMAL_AFTER="$(git -C "$ORACLE_REPO" write-tree)" || \
  abort "oracle git write-tree failed"
run_tree "normal-head-after" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "normal HEAD with a tracked edit succeeds"
expect_oid_output "normal HEAD after a tracked edit"
NORMAL_AFTER="$RUN_OID"
expect_oid_equal "$EXPECTED_NORMAL_AFTER" "$NORMAL_AFTER" \
  "normal HEAD matches an independent git add -A/write-tree oracle"
expect_oid_changed "$NORMAL_BEFORE" "$NORMAL_AFTER" \
  "changing a tracked file changes the tree OID"

# 2. Unborn HEAD: build the throwaway index from worktree files alone.
CASE_ROOT="$TMP_ROOT/case-2-unborn"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
mkdir -p "$REPO/dir" || abort "cannot create unborn fixture directory"
printf 'one\n' > "$REPO/one.txt"
printf 'two\n' > "$REPO/dir/two.txt"
run_tree "unborn-head" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "unborn HEAD succeeds"
expect_oid_output "unborn HEAD"

# 3. Injected operational failure: run outside a Git worktree.
CASE_ROOT="$TMP_ROOT/case-3-failure"
REPO="$CASE_ROOT/repo"
OUTSIDE="$CASE_ROOT/outside"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'protected\n' > "$REPO/tracked.txt"
commit_all "$REPO" "protected state"
mkdir -p "$OUTSIDE" || abort "cannot create non-worktree directory"
run_tree "outside-worktree" "$OUTSIDE" "$REPO" "$TEMP_BASE"
expect_status 1 "outside-worktree failure exits 1"
expect_empty_stdout "outside-worktree failure"

# 4. A failure after discovery succeeds exits 1 without publishing an OID.
CASE_ROOT="$TMP_ROOT/case-4-post-discovery-failure"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'tracked\n' > "$REPO/tracked.txt"
commit_all "$REPO" "initial"
attempt=0
while :; do
  printf 'unwritable object database fixture %d\n' "$attempt" \
    > "$REPO/post-discovery.txt"
  FAILURE_OID="$(git -C "$REPO" hash-object post-discovery.txt)" || \
    abort "cannot hash the post-discovery failure fixture"
  FAILURE_PREFIX="${FAILURE_OID:0:2}"
  if [[ ! -e "$REPO/.git/objects/$FAILURE_PREFIX" ]] &&
     ! git -C "$REPO" cat-file -e "$FAILURE_OID" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  [[ $attempt -lt 1024 ]] || abort "cannot find a fresh loose-object prefix"
done
LOCKED_OBJECTS_DIR="$REPO/.git/objects"
chmod u-w "$LOCKED_OBJECTS_DIR" || abort "cannot make object database unwritable"
run_tree "post-discovery-failure" "$REPO" "$REPO" "$TEMP_BASE"
chmod u+w "$LOCKED_OBJECTS_DIR" || abort "cannot restore object database permissions"
LOCKED_OBJECTS_DIR=""
expect_status 1 "post-discovery git add failure exits 1"
expect_empty_stdout "post-discovery git add failure"
expect_stderr_contains "tree-oid: git add -A failed" \
  "post-discovery failure reaches git add -A"

# 5. Untracked files: both addition and same-name content edits are bound.
CASE_ROOT="$TMP_ROOT/case-5-untracked"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'tracked\n' > "$REPO/tracked.txt"
commit_all "$REPO" "initial"
run_tree "untracked-absent" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "baseline before an untracked file succeeds"
expect_oid_output "baseline before an untracked file"
UNTRACKED_ABSENT="$RUN_OID"
printf 'untracked version one\n' > "$REPO/untracked.txt"
run_tree "untracked-added" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "adding an untracked file succeeds"
expect_oid_output "tree with an untracked file"
UNTRACKED_ONE="$RUN_OID"
printf 'untracked version two\n' > "$REPO/untracked.txt"
run_tree "untracked-edited" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "editing an untracked file succeeds"
expect_oid_output "tree with edited untracked content"
UNTRACKED_TWO="$RUN_OID"
expect_oid_changed "$UNTRACKED_ABSENT" "$UNTRACKED_ONE" \
  "adding an untracked file changes the tree OID"
expect_oid_changed "$UNTRACKED_ONE" "$UNTRACKED_TWO" \
  "editing the same untracked path changes the tree OID"

# 6. A tracked file remains bound even after a matching ignore rule is added.
CASE_ROOT="$TMP_ROOT/case-6-tracked-ignored"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'ignored.txt\n' > "$REPO/.gitignore"
printf 'tracked ignored version one\n' > "$REPO/ignored.txt"
git -C "$REPO" add .gitignore || abort "cannot add ignore rule"
git -C "$REPO" add -f ignored.txt || abort "cannot force-add ignored fixture"
git -C "$REPO" -c commit.gpgsign=false commit -qm "tracked ignored file" || \
  abort "cannot commit tracked ignored fixture"
run_tree "tracked-ignored-before" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "tracked-but-ignored baseline succeeds"
expect_oid_output "tracked-but-ignored baseline"
IGNORED_BEFORE="$RUN_OID"
printf 'tracked ignored version two\n' > "$REPO/ignored.txt"
run_tree "tracked-ignored-after" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "modified tracked-but-ignored file succeeds"
expect_oid_output "modified tracked-but-ignored file"
IGNORED_AFTER="$RUN_OID"
expect_oid_changed "$IGNORED_BEFORE" "$IGNORED_AFTER" \
  "a tracked-but-ignored edit changes the tree OID"

# 7. A force-added ignored file present only in the real index stays bound.
CASE_ROOT="$TMP_ROOT/case-7-force-added-ignored"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'secret.txt\n' > "$REPO/.gitignore"
commit_all "$REPO" "ignore secret"
printf 'v1\n' > "$REPO/secret.txt"
git -C "$REPO" add -f secret.txt || abort "cannot force-add ignored fixture"
run_tree "force-added-ignored-before" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "force-added ignored baseline succeeds"
expect_oid_output "force-added ignored baseline"
FORCE_IGNORED_BEFORE="$RUN_OID"
printf 'v2\n' > "$REPO/secret.txt"
run_tree "force-added-ignored-after" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "modified force-added ignored file succeeds"
expect_oid_output "modified force-added ignored file"
FORCE_IGNORED_AFTER="$RUN_OID"
expect_oid_changed "$FORCE_IGNORED_BEFORE" "$FORCE_IGNORED_AFTER" \
  "editing a force-added ignored file changes the tree OID"

# 8. Registered submodules stay allowed when clean and unavailable when dirty.
CASE_ROOT="$TMP_ROOT/case-8-submodule"
INNER="$CASE_ROOT/inner-source"
MIDDLE="$CASE_ROOT/middle-source"
REPO="$CASE_ROOT/repo"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$INNER"
printf 'inner clean\n' > "$INNER/payload.txt"
commit_all "$INNER" "inner initial"
init_repo "$MIDDLE"
printf 'middle\n' > "$MIDDLE/middle.txt"
commit_all "$MIDDLE" "middle initial"
git -C "$MIDDLE" -c protocol.file.allow=always submodule add -q \
  "$INNER" "nested module" || abort "cannot add nested submodule"
commit_all "$MIDDLE" "add nested submodule"
init_repo "$REPO"
printf 'top\n' > "$REPO/top.txt"
commit_all "$REPO" "top initial"
git -C "$REPO" -c protocol.file.allow=always submodule add -q \
  "$MIDDLE" "outer module" || abort "cannot add space-containing submodule"
commit_all "$REPO" "add outer submodule"
git -C "$REPO" -c protocol.file.allow=always submodule update -q \
  --init --recursive || abort "cannot initialize nested submodules"
run_tree "clean-registered-submodule" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 0 "clean registered submodule succeeds"
expect_oid_output "clean registered submodule"
printf 'inner dirty\n' > "$REPO/outer module/nested module/payload.txt"
run_tree "dirty-nested-submodule" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 3 "dirty nested submodule exits with binding-unavailable status 3"
expect_empty_stdout "dirty nested submodule"
expect_one_line_stderr "binding unavailable: a submodule has modifications" \
  "dirty nested submodule"

# 9. A newly discovered embedded repository cannot be content-completely bound.
CASE_ROOT="$TMP_ROOT/case-9-embedded-repository"
REPO="$CASE_ROOT/repo"
EMBEDDED="$REPO/embedded"
TEMP_BASE="$CASE_ROOT/script-tmp"
init_repo "$REPO"
printf 'outer\n' > "$REPO/outer.txt"
commit_all "$REPO" "outer initial"
init_repo "$EMBEDDED"
printf 'v1\n' > "$EMBEDDED/x.txt"
commit_all "$EMBEDDED" "embedded initial"
run_tree "untracked-embedded-repository" "$REPO" "$REPO" "$TEMP_BASE"
expect_status 3 "untracked embedded repository exits with binding-unavailable status 3"
expect_empty_stdout "untracked embedded repository"
expect_one_line_stderr \
  "binding unavailable: a submodule has modifications or an unregistered embedded repository may be present" \
  "untracked embedded repository"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' \
    "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
