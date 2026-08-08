#!/usr/bin/env bash
# Compute a content-complete, non-ignored worktree tree identity without a commit.
#
# Interface:
# - Run from the target worktree root. No arguments.
# - Success: print exactly one tree OID to stdout and exit 0. Nothing else ever
#   goes to stdout.
# - Operational failure (any Git step fails, not in a Git worktree, and so on):
#   exit 1 with no stdout output; diagnostics go to stderr.
# - Binding unavailable (any submodule modification): exit 3 with no stdout
#   output and a one-line stderr explanation. Exit 3 is distinct so callers
#   never confuse "cannot bind" with "the operation broke."

set -euo pipefail

TEMP_ROOT=""

cleanup() { # $1=status to preserve
  local status="$1"
  trap - EXIT HUP INT TERM
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT" || true
  fi
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

error() {
  printf 'tree-oid: %s\n' "$1" >&2
  exit 1
}

binding_unavailable() {
  printf 'tree-oid: binding unavailable: a submodule has modifications\n' >&2
  exit 3
}

[[ $# -eq 0 ]] || error "no arguments accepted"

umask 077
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tree-oid.XXXXXX")" || \
  error "could not create temporary directory"
INDEX_FILE="$TEMP_ROOT/index"
STATUS_FILE="$TEMP_ROOT/status"
INDEX_ENTRIES="$TEMP_ROOT/index-entries"
HEAD_ENTRIES="$TEMP_ROOT/head-entries"
HEAD_REF_FILE="$TEMP_ROOT/head-ref"
OID_FILE="$TEMP_ROOT/tree-oid"

# Ignore an inherited alternate-index setting. Read-only discovery uses the
# worktree's real index; all mutating index commands below name the throwaway.
unset GIT_INDEX_FILE
export GIT_OPTIONAL_LOCKS=0
export LC_ALL=C

TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || \
  error "not in a Git worktree"
CURRENT_ROOT="$(pwd -P)" || error "cannot resolve the current directory"
TOPLEVEL_ROOT="$(cd "$TOPLEVEL" && pwd -P)" || \
  error "cannot resolve the Git worktree root"
[[ "$CURRENT_ROOT" == "$TOPLEVEL_ROOT" ]] || \
  error "run from the target worktree root"

# A failed HEAD verification is an unborn branch only when HEAD is symbolic
# and its target ref does not exist. Other broken/detached states fail closed.
HAS_HEAD=0
if git rev-parse --verify --quiet HEAD > "$TEMP_ROOT/head-oid"; then
  HAS_HEAD=1
else
  head_status=$?
  [[ $head_status -eq 1 ]] || error "could not verify HEAD"
  if ! git symbolic-ref -q HEAD > "$HEAD_REF_FILE"; then
    error "HEAD is neither a commit nor an unborn branch"
  fi
  IFS= read -r HEAD_REF < "$HEAD_REF_FILE" || \
    error "could not read the unborn HEAD ref"
  if git show-ref --verify --quiet "$HEAD_REF"; then
    error "HEAD ref exists but HEAD cannot be verified"
  else
    ref_status=$?
    [[ $ref_status -eq 1 ]] || error "could not inspect the unborn HEAD ref"
  fi
fi

# Status is captured before hashing and parsed as NUL-delimited porcelain.
# Explicit ignore/untracked flags make submodule dirtiness independent of user
# or repository status configuration.
git status --porcelain -z --ignore-submodules=none --untracked-files=all \
  > "$STATUS_FILE" || error "git status failed"
git ls-files --stage -z > "$INDEX_ENTRIES" || \
  error "could not inspect the real index"
if [[ $HAS_HEAD -eq 1 ]]; then
  git ls-tree -r -z HEAD > "$HEAD_ENTRIES" || error "could not inspect HEAD"
else
  : > "$HEAD_ENTRIES"
fi

path_is_submodule() { # $1=exact worktree-relative path
  local candidate="$1"
  local record path

  while IFS= read -r -d '' record; do
    if [[ "$record" == 160000\ * && "$record" == *$'\t'* ]]; then
      path="${record#*$'\t'}"
      [[ "$path" == "$candidate" ]] && return 0
    fi
  done < "$INDEX_ENTRIES"

  while IFS= read -r -d '' record; do
    if [[ "$record" == 160000\ * && "$record" == *$'\t'* ]]; then
      path="${record#*$'\t'}"
      [[ "$path" == "$candidate" ]] && return 0
    fi
  done < "$HEAD_ENTRIES"

  return 1
}

exec 3< "$STATUS_FILE"
while :; do
  status_record=""
  if ! IFS= read -r -d '' status_record <&3; then
    [[ -z "$status_record" ]] || error "malformed Git status output"
    break
  fi
  [[ ${#status_record} -ge 3 && "${status_record:2:1}" == " " ]] || \
    error "malformed Git status record"

  xy="${status_record:0:2}"
  path="${status_record:3}"
  if path_is_submodule "$path"; then
    binding_unavailable
  fi

  # In -z porcelain, a rename/copy record is followed by its second path as a
  # separate NUL-delimited field. Check both sides against HEAD and the index.
  if [[ "${xy:0:1}" == "R" || "${xy:0:1}" == "C" ||
        "${xy:1:1}" == "R" || "${xy:1:1}" == "C" ]]; then
    second_path=""
    IFS= read -r -d '' second_path <&3 || \
      error "malformed Git rename/copy status record"
    if path_is_submodule "$second_path"; then
      binding_unavailable
    fi
  fi
done
exec 3<&-

if [[ $HAS_HEAD -eq 1 ]]; then
  GIT_INDEX_FILE="$INDEX_FILE" git read-tree HEAD > "$TEMP_ROOT/read-tree.out" || \
    error "git read-tree failed"
fi
GIT_INDEX_FILE="$INDEX_FILE" git add -A > "$TEMP_ROOT/add.out" || \
  error "git add -A failed"
GIT_INDEX_FILE="$INDEX_FILE" git write-tree > "$OID_FILE" || \
  error "git write-tree failed"

TREE_OID=""
IFS= read -r TREE_OID < "$OID_FILE" || error "git write-tree returned no OID"
if [[ ! "$TREE_OID" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  error "git write-tree returned an invalid OID"
fi
printf '%s\n' "$TREE_OID" > "$TEMP_ROOT/expected-oid" || \
  error "could not validate the tree OID"
cmp -s "$OID_FILE" "$TEMP_ROOT/expected-oid" || \
  error "git write-tree returned output other than one OID"
git cat-file -e "$TREE_OID^{tree}" > /dev/null || \
  error "git write-tree returned an unreadable tree"

printf '%s\n' "$TREE_OID"
