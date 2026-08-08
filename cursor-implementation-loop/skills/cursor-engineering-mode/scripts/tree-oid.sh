#!/usr/bin/env bash
# Compute a content-complete, non-ignored worktree tree identity without a commit.
#
# Interface:
# - Run from the target worktree root. No arguments.
# - Success: print exactly one tree OID to stdout and exit 0. Nothing else ever
#   goes to stdout.
# - Operational failure (any Git step fails, not in a Git worktree, and so on):
#   exit 1 with no stdout output; diagnostics go to stderr.
# - Binding unavailable (any submodule modification, change-suppression flags
#   in a populated registered submodule, an unregistered embedded repository,
#   a skip-worktree entry, or an assume-unchanged gitlink): exit 3 with no
#   stdout output and a one-line stderr explanation. Exit 3 is distinct so
#   callers never confuse "cannot bind" with "the operation broke."

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
  printf '%s\n' \
    'tree-oid: binding unavailable: a submodule has modifications or an unregistered embedded repository may be present' >&2
  exit 3
}

binding_unavailable_skip_worktree() {
  printf '%s\n' \
    'tree-oid: binding unavailable: an index entry carries skip-worktree (sparse checkout or manual suppression); worktree binding is unavailable' >&2
  exit 3
}

binding_unavailable_suppressed_gitlink() {
  printf '%s\n' \
    'tree-oid: binding unavailable: an index gitlink carries assume-unchanged; worktree binding is unavailable' >&2
  exit 3
}

binding_unavailable_suppressed_submodule_index() {
  printf '%s\n' \
    "tree-oid: binding unavailable: a registered submodule's index carries change-suppression flags; worktree binding is unavailable" >&2
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
THROWAWAY_ENTRIES="$TEMP_ROOT/throwaway-index-entries"
SEEDED_ENTRIES="$TEMP_ROOT/seeded-index-entries"
INDEX_FLAGS="$TEMP_ROOT/index-flags"
ASSUME_UNCHANGED_PATHS="$TEMP_ROOT/assume-unchanged-paths"
HEAD_REF_FILE="$TEMP_ROOT/head-ref"
OID_FILE="$TEMP_ROOT/tree-oid"
SUBMODULE_AUDIT_DIR="$TEMP_ROOT/submodule-audit"
SUBMODULE_AUDITOR="$TEMP_ROOT/audit-submodule.sh"

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

REAL_INDEX_PATH="$(git rev-parse --git-path index 2>/dev/null)" || \
  error "could not locate the real index"
[[ -n "$REAL_INDEX_PATH" ]] || error "Git returned an empty real-index path"
if [[ "$REAL_INDEX_PATH" != /* ]]; then
  REAL_INDEX_PATH="$TOPLEVEL_ROOT/$REAL_INDEX_PATH"
fi

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

# `git submodule foreach --recursive` changes into each populated registered
# submodule itself. No pathname output is parsed here, so spaces (and other
# shell-sensitive path content) remain opaque; unpopulated registrations are
# skipped by Git. Run one complete flag pass before any dirtiness decisions so
# suppression in a nested child always receives its distinct fail-closed cause.
mkdir "$SUBMODULE_AUDIT_DIR" || \
  error "could not create the registered-submodule audit directory"
if ! command cat > "$SUBMODULE_AUDITOR" <<'SUBMODULE_AUDITOR_EOF'
#!/usr/bin/env bash
set -uo pipefail

mode="${1-}"
audit_dir="${TREE_OID_SUBMODULE_AUDIT_DIR-}"
[[ -n "$audit_dir" ]] || exit 1

operational_failure() {
  : > "$audit_dir/operational-failure" 2>/dev/null || true
  exit 1
}

case "$mode" in
  flags)
    output="$audit_dir/child-index-flags"
    git ls-files -v -z > "$output" || operational_failure
    while IFS= read -r -d '' record; do
      [[ ${#record} -ge 3 && "${record:1:1}" == " " ]] || \
        operational_failure
      tag="${record:0:1}"
      if [[ "$tag" == "S" || "$tag" == "s" ||
            "$tag" == [[:lower:]] ]]; then
        : > "$audit_dir/suppressed-index" || operational_failure
        exit 1
      fi
    done < "$output"
    ;;
  status)
    output="$audit_dir/child-status"
    git -c core.fsmonitor=false -c core.untrackedcache=false \
      status --porcelain -z --ignore-submodules=none \
      --untracked-files=all > "$output" || \
      operational_failure
    if [[ -s "$output" ]]; then
      : > "$audit_dir/dirty-submodule" || operational_failure
      exit 1
    fi
    ;;
  *)
    operational_failure
    ;;
esac
SUBMODULE_AUDITOR_EOF
then
  error "could not create the registered-submodule auditor"
fi

export TREE_OID_SUBMODULE_AUDIT_DIR="$SUBMODULE_AUDIT_DIR"
export TREE_OID_SUBMODULE_AUDITOR="$SUBMODULE_AUDITOR"

if ! git submodule foreach --quiet --recursive \
    'bash "$TREE_OID_SUBMODULE_AUDITOR" flags' \
    > "$TEMP_ROOT/submodule-flags.out" \
    2> "$TEMP_ROOT/submodule-flags.err"; then
  if [[ -e "$SUBMODULE_AUDIT_DIR/suppressed-index" ]]; then
    binding_unavailable_suppressed_submodule_index
  fi
  error "could not audit registered-submodule index flags"
fi
[[ ! -e "$SUBMODULE_AUDIT_DIR/operational-failure" ]] || \
  error "could not audit registered-submodule index flags"

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

seeded_path_is_gitlink() { # $1=exact worktree-relative path
  local candidate="$1"
  local record path

  while IFS= read -r -d '' record; do
    [[ "$record" == *$'\t'* ]] || error "malformed seeded index output"
    if [[ "$record" == 160000\ * ]]; then
      path="${record#*$'\t'}"
      [[ "$path" == "$candidate" ]] && return 0
    fi
  done < "$SEEDED_ENTRIES"

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

if [[ -e "$REAL_INDEX_PATH" ]]; then
  cp "$REAL_INDEX_PATH" "$INDEX_FILE" || error "could not copy the real index"
elif [[ -L "$REAL_INDEX_PATH" ]]; then
  error "the real index path is a broken symbolic link"
fi

# A copied index may carry change-suppression bits. Skip-worktree entries cannot
# be rebound safely because their worktree paths may intentionally be absent.
# Assume-unchanged gitlinks are likewise unavailable; clear the bit for every
# other assume-unchanged path in the throwaway index only so add sees reality.
GIT_INDEX_FILE="$INDEX_FILE" git ls-files --stage -z > "$SEEDED_ENTRIES" || \
  error "could not inspect the seeded throwaway index"
GIT_INDEX_FILE="$INDEX_FILE" git ls-files -v -z > "$INDEX_FLAGS" || \
  error "could not inspect throwaway index flags"
: > "$ASSUME_UNCHANGED_PATHS"
while IFS= read -r -d '' record; do
  [[ ${#record} -ge 3 && "${record:1:1}" == " " ]] || \
    error "malformed throwaway index flag output"
  tag="${record:0:1}"
  path="${record:2}"
  case "$tag" in
    S|s)
      binding_unavailable_skip_worktree
      ;;
  esac
  if [[ "$tag" == [[:lower:]] ]]; then
    if seeded_path_is_gitlink "$path"; then
      binding_unavailable_suppressed_gitlink
    fi
    printf '%s\0' "$path" >> "$ASSUME_UNCHANGED_PATHS" || \
      error "could not record assume-unchanged paths"
  fi
done < "$INDEX_FLAGS"

# Preserve the existing, more specific top-level suppressed-gitlink cause by
# running this child dirtiness pass after the real-index flag audit. Child
# suppression was already audited recursively above and therefore still takes
# precedence over every status-based dirtiness decision.
if ! git submodule foreach --quiet --recursive \
    'bash "$TREE_OID_SUBMODULE_AUDITOR" status' \
    > "$TEMP_ROOT/submodule-status.out" \
    2> "$TEMP_ROOT/submodule-status.err"; then
  if [[ -e "$SUBMODULE_AUDIT_DIR/dirty-submodule" ]]; then
    binding_unavailable
  fi
  error "could not re-check registered-submodule dirtiness"
fi
[[ ! -e "$SUBMODULE_AUDIT_DIR/operational-failure" ]] || \
  error "could not re-check registered-submodule dirtiness"

if [[ -s "$ASSUME_UNCHANGED_PATHS" ]]; then
  # --stdin consumes path records, not options, and must be the final argument.
  if ! GIT_INDEX_FILE="$INDEX_FILE" \
      git -c core.fsmonitor=false -c core.untrackedcache=false \
      -c core.splitIndex=false \
      update-index --no-assume-unchanged -z --stdin \
      < "$ASSUME_UNCHANGED_PATHS" > "$TEMP_ROOT/update-index.out" \
      2> "$TEMP_ROOT/update-index.err"; then
    if [[ -s "$TEMP_ROOT/update-index.err" ]]; then
      cat "$TEMP_ROOT/update-index.err" >&2 || true
    fi
    error "could not clear assume-unchanged in the throwaway index"
  fi
fi

if ! GIT_INDEX_FILE="$INDEX_FILE" \
    git -c core.fsmonitor=false -c core.untrackedcache=false \
    -c core.splitIndex=false -c advice.addEmbeddedRepo=false add -A \
    > "$TEMP_ROOT/add.out" 2> "$TEMP_ROOT/add.err"; then
  if [[ -s "$TEMP_ROOT/add.err" ]]; then
    cat "$TEMP_ROOT/add.err" >&2 || true
  fi
  error "git add -A failed"
fi
GIT_INDEX_FILE="$INDEX_FILE" git ls-files --stage -z \
  > "$THROWAWAY_ENTRIES" || error "could not inspect the throwaway index"
while IFS= read -r -d '' record; do
  [[ "$record" == *$'\t'* ]] || error "malformed throwaway index output"
  if [[ "$record" == 160000\ * ]]; then
    path="${record#*$'\t'}"
    if ! path_is_submodule "$path"; then
      binding_unavailable
    fi
  fi
done < "$THROWAWAY_ENTRIES"
GIT_INDEX_FILE="$INDEX_FILE" \
  git -c core.fsmonitor=false -c core.untrackedcache=false \
  -c core.splitIndex=false write-tree \
  > "$OID_FILE" || \
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
