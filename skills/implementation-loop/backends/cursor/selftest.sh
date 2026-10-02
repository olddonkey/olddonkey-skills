#!/usr/bin/env bash
# PATH-stub regression harness for the cursor backend.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
TMP_ROOT_RAW="$(mktemp -d)"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
# One case leaves an unreadable directory behind if its dispatch dies early.
trap 'chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

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

run_case() { # $1=name, remaining args=command
  local name="$1"
  shift
  CASE_OUTPUT="$TMP_ROOT/$name.out"
  set +e
  "$@" > "$CASE_OUTPUT" 2>&1
  CASE_STATUS=$?
  set -e
}

summary_value() { # $1=label
  sed -n "s/^$1: //p" "$CASE_OUTPUT" | tail -1
}

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
apply_patch_stub="$BIN_DIR/cursor-agent"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "--version" ]]; then printf "cursor-agent 2026.08.11-stub\n"; exit 0; fi' \
  ': "${CURSOR_STUB_LOG:?}"' \
  'python3 - "$CURSOR_STUB_LOG" "$PWD" "$@" <<'"'"'PY'"'"'' \
  'import json, os, subprocess, sys' \
  'path, cwd, *argv = sys.argv[1:]' \
  'probe = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], text=True, capture_output=True)' \
  'entries = []' \
  'for directory, dirnames, filenames in os.walk(cwd, followlinks=False):' \
  '    if ".git" in dirnames or ".git" in filenames:' \
  '        entries.append(os.path.join(directory, ".git"))' \
  'with open(path, "a", encoding="utf-8") as handle:' \
  '    handle.write(json.dumps({' \
  '        "cwd": os.path.realpath(cwd),' \
  '        "argv": argv,' \
  '        "git_top": probe.stdout.strip() if probe.returncode == 0 else "",' \
  '        "git_entries": entries,' \
  '    }, sort_keys=True) + "\n")' \
  'PY' \
  'case "${CURSOR_STUB_ACTION:-none}" in' \
  '  none) ;;' \
  '  edit)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    printf "nested-cursor-change\n" > work/nested.txt' \
  '    printf "added-by-cursor\n" > added.txt' \
  '    rm -f delete-me.txt' \
  '    ;;' \
  '  paths)' \
  '    mv rename-old.txt rename-new.txt' \
  '    printf "nested-work-changed\n" > lib/a/work/f.txt' \
  '    mkdir -p lib/work' \
  '    printf "new-under-lib-work\n" > lib/work/new.txt' \
  '    printf "top-work-changed\n" > work/nested.txt' \
  '    printf "top-pristine-changed\n" > pristine/nested.txt' \
  '    printf "space-changed\n" > "a space.txt"' \
  '    printf "%s\n" "++ see b/work/notes" > hunk.txt' \
  '    printf "\000\377\021\022\000" > binary.bin' \
  '    chmod 755 mode.sh' \
  '    ;;' \
  '  ignored-new)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    printf "secret\n" > .env' \
  '    mkdir -p __pycache__' \
  '    printf "cache" > __pycache__/x.pyc' \
  '    ;;' \
  '  ignored-existing)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    printf "agent-ignored-content\n" > ignored.txt' \
  '    ;;' \
  '  symlink-to-dir)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    rm dirlink' \
  '    mkdir dirlink' \
  '    printf "beyond-the-real-symlink\n" > dirlink/new.txt' \
  '    ;;' \
  '  ignored-symlink)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    mkdir -p cache/deep' \
  '    printf "built\n" > cache/deep/out.o' \
  '    ;;' \
  '  unreadable)' \
  '    printf "base\ncursor-change\n" > tracked.txt' \
  '    mkdir locked' \
  '    printf "hidden\n" > locked/file.txt' \
  '    chmod 000 locked' \
  '    ;;' \
  '  plan-edit) printf "plan-copy-only\n" > tracked.txt ;;' \
  '  git-entry) mkdir -p .git; printf "forbidden\n" > .git/config ;;' \
  '  *) printf "unknown stub action\n" >&2; exit 90 ;;' \
  'esac' \
  'if [[ "${CURSOR_STUB_OUTPUT:-json}" == "bad" ]]; then printf "not-json\n"; exit "${CURSOR_STUB_EXIT:-0}"; fi' \
  'python3 - <<'"'"'PY'"'"'' \
  'import json, os' \
  'value = os.environ.get("CURSOR_STUB_IS_ERROR", "false").lower() == "true"' \
  'print(json.dumps({' \
  '    "type": "result", "subtype": "success", "is_error": value,' \
  '    "duration_ms": 10, "duration_api_ms": 5, "result": "stub complete",' \
  '    "session_id": "session-123", "request_id": "request-1", "usage": {},' \
  '}))' \
  'PY' \
  'exit "${CURSOR_STUB_EXIT:-0}"' \
  > "$apply_patch_stub"
chmod +x "$apply_patch_stub"
TEST_PATH="$BIN_DIR:$PATH"

init_fixture() { # $1=name
  FIX_HOME="$TMP_ROOT/$1-home"
  FIX_REPO="$TMP_ROOT/$1-repo"
  mkdir -p "$FIX_HOME"
  git init -q "$FIX_REPO"
  git -C "$FIX_REPO" config user.email selftest@example.invalid
  git -C "$FIX_REPO" config user.name selftest
  printf 'base\n' > "$FIX_REPO/tracked.txt"
  printf 'delete-me\n' > "$FIX_REPO/delete-me.txt"
  printf 'ignored.txt\n__pycache__/\n.env\n' > "$FIX_REPO/.gitignore"
  mkdir -p "$FIX_REPO/work"
  printf 'nested-base\n' > "$FIX_REPO/work/nested.txt"
  git -C "$FIX_REPO" add tracked.txt delete-me.txt .gitignore work/nested.txt
  git -C "$FIX_REPO" commit -qm base
  printf 'untracked-project-file\n' > "$FIX_REPO/untracked.txt"
  printf 'ignored-content\n' > "$FIX_REPO/ignored.txt"
}

dispatch() { # $1=name $2=home $3=repo; remaining args=dispatcher flags
  local name="$1" home="$2" repo="$3"
  shift 3
  : > "$TMP_ROOT/$name.cursor.log"
  run_case "$name" env HOME="$home" PATH="$TEST_PATH" \
    CURSOR_STUB_LOG="$TMP_ROOT/$name.cursor.log" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$repo" "$DISPATCH" \
    --prompt 'make the bounded fixture change' "$@"
}

expect_log_arg() { # $1=log $2=arg $3=description
  if python3 - "$1" "$2" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
raise SystemExit(0 if records and sys.argv[2] in records[-1]["argv"] else 1)
PY
  then pass "$3"; else fail "$3"; fi
}

expect_log_no_arg() { # $1=log $2=arg $3=description
  if python3 - "$1" "$2" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
raise SystemExit(0 if records and sys.argv[2] not in records[-1]["argv"] else 1)
PY
  then pass "$3"; else fail "$3"; fi
}

expect_log_sequence() { # $1=log $2=description, remaining=sequence
  local log="$1" description="$2"
  shift 2
  if python3 - "$log" "$@" <<'PY'
import json, sys
path, *needle = sys.argv[1:]
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
if not records:
    raise SystemExit(1)
argv = records[-1]["argv"]
found = any(argv[index:index + len(needle)] == needle for index in range(len(argv) - len(needle) + 1))
raise SystemExit(0 if found else 1)
PY
  then pass "$description"; else fail "$description"; fi
}

# Interface and explicit Run Everything refusals.
run_case help "$DISPATCH" --help
expect_status 0 "help succeeds"
expect_contains "git-less copies" "help names the git-less-copy architecture"
expect_contains "never receives --force" "help documents the Run Everything ban"

run_case resume "$DISPATCH" --prompt x --resume
expect_status 2 "--resume is refused"
expect_contains "fresh dispatch" "resume refusal points to fresh-dispatch iterate"

run_case background "$DISPATCH" --prompt x --background
expect_status 2 "--background is refused"
expect_contains "foreground adapter" "background refusal explains lifecycle"

for forbidden in --force --yolo -f; do
  run_case "forbidden-${forbidden#-}" "$DISPATCH" --prompt x "$forbidden"
  expect_status 2 "$forbidden is refused"
  expect_contains "bypass the sandbox" "$forbidden refusal explains the breach"
done

run_case extra-env env CURSOR_LOOP_EXTRA_ARGS=--yolo "$DISPATCH" --prompt x
expect_status 2 "environment extra args are refused"
expect_contains "control flags are fixed" "extra-args refusal is explicit"

# Successful implement dispatch with retained copies for structural inspection.
init_fixture implement
IMPLEMENT_HEAD="$(git -C "$FIX_REPO" rev-parse HEAD)"
: > "$TMP_ROOT/implement.cursor.log"
run_case implement env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/implement.cursor.log" CURSOR_STUB_ACTION=edit \
  CURSOR_LOOP_KEEP_COPIES=1 \
  bash -c 'cd "$1" && exec "$2" --prompt "make the bounded fixture change" --effort xhigh' \
  _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "implement dispatch succeeds"
expect_contains "cursor-agent dispatch summary:" "summary header is present"
expect_contains "workspace: $FIX_REPO" "summary names the real workspace"
expect_contains "cursor-agent version: cursor-agent 2026.08.11-stub" "summary names cursor-agent version"
expect_contains "model: cursor-grok-4.6-xhigh (adapter default)" "summary names default model and provenance"
expect_contains "effort: xhigh (explicit assertion in model id)" "summary names embedded effort assertion"
expect_contains "mode: implement" "summary names implement mode"
expect_contains "is_error: false" "summary reports calibrated is_error"
expect_contains "session id: session-123" "summary captures session_id"
expect_contains "resume: no (fresh dispatch only)" "summary rejects thread-continuity implications"
expect_contains "files changed: 4" "summary reports changed-file count"
expect_contains "ignored paths dropped: 0" "summary reports no dropped ignored paths"
expect_contains "sandbox-confined to a git-less copy; network denied" "summary states enforcement posture"
expect_contains "orchestrator owns commit, gate, and publish" "summary states git ownership"
expect_contains "stub complete" "result text is emitted"

IMPLEMENT_LOG="$TMP_ROOT/implement.cursor.log"
expect_log_arg "$IMPLEMENT_LOG" -p "dispatch uses print mode"
expect_log_arg "$IMPLEMENT_LOG" --trust "dispatch always trusts its throwaway copy"
expect_log_sequence "$IMPLEMENT_LOG" "dispatch pins sandbox enabled" --sandbox enabled
expect_log_sequence "$IMPLEMENT_LOG" "dispatch pins the selected model" --model cursor-grok-4.6-xhigh
expect_log_sequence "$IMPLEMENT_LOG" "dispatch pins JSON output" --output-format json
expect_log_no_arg "$IMPLEMENT_LOG" --force "dispatch argv omits --force"
expect_log_no_arg "$IMPLEMENT_LOG" --yolo "dispatch argv omits --yolo"
expect_log_no_arg "$IMPLEMENT_LOG" -f "dispatch argv omits -f"
expect_log_no_arg "$IMPLEMENT_LOG" --mode "implement argv omits plan mode"
if python3 - "$IMPLEMENT_LOG" <<'PY'
import json, sys
record = json.loads(open(sys.argv[1], encoding="utf-8").readline())
prompt = record["argv"][-1]
ok = prompt.startswith("You are in an isolated, network-less sandbox") and prompt.endswith("make the bounded fixture change")
raise SystemExit(0 if ok else 1)
PY
then pass "prompt is the final single positional with the safety preamble"; else fail "prompt is the final single positional with the safety preamble"; fi
if python3 - "$IMPLEMENT_LOG" <<'PY'
import json, sys
record = json.loads(open(sys.argv[1], encoding="utf-8").readline())
raise SystemExit(0 if not record["git_top"] and not record["git_entries"] else 1)
PY
then pass "cursor-agent starts in a git-less directory"; else fail "cursor-agent starts in a git-less directory"; fi

PRISTINE="$(summary_value "pristine copy")"
WORK_COPY="$(summary_value "work copy")"
STATE_DIR="$(summary_value "run state")"
PATCH_PATH="$(summary_value "patch")"
if [[ -d "$PRISTINE" && -d "$WORK_COPY" ]]; then pass "retention override preserves both copies"; else fail "retention override preserves both copies"; fi
if [[ -f "$PRISTINE/tracked.txt" && -f "$PRISTINE/untracked.txt" ]]; then pass "pristine contains tracked and untracked-non-ignored files"; else fail "pristine contains tracked and untracked-non-ignored files"; fi
if [[ ! -e "$PRISTINE/ignored.txt" ]]; then pass "pristine excludes ignored files"; else fail "pristine excludes ignored files"; fi
if ! find "$PRISTINE" "$WORK_COPY" -name .git -print -quit | grep -q .; then pass "neither retained copy contains a .git entry"; else fail "neither retained copy contains a .git entry"; fi
expect_file_contains "$PRISTINE/tracked.txt" base "pristine remains the untouched baseline"
expect_file_contains "$WORK_COPY/tracked.txt" cursor-change "work copy contains cursor edit"
if [[ -f "$WORK_COPY/added.txt" && ! -e "$WORK_COPY/delete-me.txt" ]]; then pass "work copy contains add and delete operations"; else fail "work copy contains add and delete operations"; fi
if python3 - "$FIX_REPO" "$PRISTINE" "$WORK_COPY" <<'PY'
import os, sys
repo, pristine, work = map(os.path.realpath, sys.argv[1:])
def inside(path, root):
    try: return os.path.commonpath((path, root)) == root
    except ValueError: return False
raise SystemExit(0 if not inside(pristine, repo) and not inside(work, repo) else 1)
PY
then pass "both copies are outside the real repository"; else fail "both copies are outside the real repository"; fi
if python3 - "$STATE_DIR" "$PRISTINE" "$WORK_COPY" <<'PY'
import os, sys
state, pristine, work = map(os.path.realpath, sys.argv[1:])
def overlap(left, right):
    try: return os.path.commonpath((left, right)) in (left, right)
    except ValueError: return False
raise SystemExit(0 if not overlap(state, pristine) and not overlap(state, work) else 1)
PY
then pass "run state and baseline copies are disjoint"; else fail "run state and baseline copies are disjoint"; fi
COMMON_RAW="$(git -C "$FIX_REPO" rev-parse --git-common-dir)"
COMMON_DIR="$(python3 - "$FIX_REPO" "$COMMON_RAW" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
)"
if [[ "$STATE_DIR" == "$COMMON_DIR/olddonkey-loop/cursor/"* ]]; then pass "run state uses the git common-dir cursor namespace"; else fail "run state uses the git common-dir cursor namespace"; fi
if [[ -f "$STATE_DIR/project-files.zlist" ]]; then pass "run state records the exact project manifest"; else fail "run state records the exact project manifest"; fi

if [[ -s "$PATCH_PATH" ]]; then pass "pristine-vs-work patch is captured"; else fail "pristine-vs-work patch is captured"; fi
expect_file_contains "$PATCH_PATH" "diff --git a/pristine/tracked.txt b/work/tracked.txt" "patch keeps the raw copy-root prefixes that -p2 strips"
expect_file_contains "$PATCH_PATH" "diff --git a/work/added.txt b/work/added.txt" "patch captures added files"
expect_file_contains "$PATCH_PATH" "diff --git a/pristine/delete-me.txt b/pristine/delete-me.txt" "patch captures deleted files"
expect_file_contains "$PATCH_PATH" "diff --git a/pristine/work/nested.txt b/work/work/nested.txt" "raw patch preserves a project directory named work"
if [[ ! -e "$STATE_DIR/changes.raw.patch" ]]; then pass "single raw patch has no rewritten companion"; else fail "single raw patch has no rewritten companion"; fi
expect_file_contains "$FIX_REPO/tracked.txt" cursor-change "patch applies the edit to the real worktree"
expect_file_contains "$FIX_REPO/added.txt" added-by-cursor "patch applies the added file to the real worktree"
if [[ ! -e "$FIX_REPO/delete-me.txt" ]]; then pass "patch applies the deletion to the real worktree"; else fail "patch applies the deletion to the real worktree"; fi
if git -C "$FIX_REPO" diff -- tracked.txt | grep -q cursor-change; then pass "git diff shows the cursor edit"; else fail "git diff shows the cursor edit"; fi
if [[ "$(git -C "$FIX_REPO" rev-parse HEAD)" == "$IMPLEMENT_HEAD" ]]; then pass "dispatcher does not commit"; else fail "dispatcher does not commit"; fi

# The raw patch is applied with -p2 and never rewritten: a rename, project
# paths that contain a/work/ or b/work/, and hunk content that looks like a
# patch header all reach the real worktree exactly as the agent left them.
init_fixture paths
mkdir -p "$FIX_REPO/lib/a/work" "$FIX_REPO/pristine"
printf 'rename-base\n' > "$FIX_REPO/rename-old.txt"
printf 'nested-work-base\n' > "$FIX_REPO/lib/a/work/f.txt"
printf 'sibling-base\n' > "$FIX_REPO/lib/a/f.txt"
printf 'top-pristine-base\n' > "$FIX_REPO/pristine/nested.txt"
printf 'space-base\n' > "$FIX_REPO/a space.txt"
printf '%s\n' '-- a/work/x' > "$FIX_REPO/hunk.txt"
printf '\000\377\020\000' > "$FIX_REPO/binary.bin"
printf '#!/bin/sh\n' > "$FIX_REPO/mode.sh"
chmod 644 "$FIX_REPO/mode.sh"
git -C "$FIX_REPO" add rename-old.txt lib pristine 'a space.txt' hunk.txt binary.bin mode.sh
git -C "$FIX_REPO" commit -qm paths-base
: > "$TMP_ROOT/paths.cursor.log"
run_case paths env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/paths.cursor.log" CURSOR_STUB_ACTION=paths \
  CURSOR_LOOP_KEEP_COPIES=1 \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "rename and work-named path dispatch succeeds"
PATHS_PATCH="$(summary_value "patch")"
PATHS_WORK="$(summary_value "work copy")"
if [[ ! -e "$FIX_REPO/rename-old.txt" ]]; then pass "rename removes the old path"; else fail "rename removes the old path"; fi
expect_file_contains "$FIX_REPO/rename-new.txt" rename-base "rename creates the new path"
if ! grep -Eq '^rename (from|to) ' "$PATHS_PATCH"; then pass "patch records a rename as delete plus add"; else fail "patch records a rename as delete plus add"; fi
expect_file_contains "$FIX_REPO/lib/a/work/f.txt" nested-work-changed "nested lib/a/work path receives its own change"
expect_file_contains "$FIX_REPO/lib/a/f.txt" sibling-base "sibling lib/a/f.txt is left untouched"
expect_file_contains "$FIX_REPO/lib/work/new.txt" new-under-lib-work "new lib/work file lands at its own path"
if [[ ! -e "$FIX_REPO/lib/new.txt" ]]; then pass "new lib/work file is not created one directory up"; else fail "new lib/work file is not created one directory up"; fi
expect_file_contains "$FIX_REPO/work/nested.txt" top-work-changed "top-level work directory change applies"
expect_file_contains "$FIX_REPO/pristine/nested.txt" top-pristine-changed "top-level pristine directory change applies"
expect_file_contains "$PATHS_PATCH" "--- a/work/x" "patch keeps deleted hunk content that resembles a header"
if [[ "$(cat "$FIX_REPO/hunk.txt")" == '++ see b/work/notes' ]]; then pass "added hunk content that resembles a header arrives unaltered"; else fail "added hunk content that resembles a header arrives unaltered"; fi
if python3 - "$FIX_REPO" "$PATHS_WORK" <<'PY'
import os, stat, subprocess, sys
repo, work = sys.argv[1:]

def describe(path):
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        return ("link", os.readlink(path))
    with open(path, "rb") as handle:
        return ("file", bool(info.st_mode & 0o111), handle.read())

listed = subprocess.run(
    ["git", "-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    capture_output=True, check=True,
).stdout
real = {os.fsdecode(entry) for entry in listed.split(b"\0") if entry}
real = {name for name in real if os.path.lexists(os.path.join(repo, name))}
copied = set()
for directory, dirnames, filenames in os.walk(work, followlinks=False):
    for name in filenames:
        copied.add(os.path.relpath(os.path.join(directory, name), work))
same = real == copied and all(
    describe(os.path.join(repo, name)) == describe(os.path.join(work, name)) for name in real
)
raise SystemExit(0 if same else 1)
PY
then pass "real worktree matches the work copy in names, bytes, and exec bits"; else fail "real worktree matches the work copy in names, bytes, and exec bits"; fi

# A new path the real repository ignores is dropped from the work copy before
# the diff, so it never lands where git status cannot show it.
init_fixture ignored-new
IGNORED_NEW_STATUS="$(git -C "$FIX_REPO" status --porcelain --ignored)"
: > "$TMP_ROOT/ignored-new.cursor.log"
run_case ignored-new env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/ignored-new.cursor.log" CURSOR_STUB_ACTION=ignored-new \
  CURSOR_LOOP_KEEP_COPIES=1 \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "new ignored paths do not fail the dispatch"
expect_file_contains "$FIX_REPO/tracked.txt" cursor-change "ordinary edit applies beside new ignored paths"
if [[ ! -e "$FIX_REPO/.env" ]]; then pass "new ignored file never reaches the real worktree"; else fail "new ignored file never reaches the real worktree"; fi
if [[ ! -e "$FIX_REPO/__pycache__" ]]; then pass "new ignored directory never reaches the real worktree"; else fail "new ignored directory never reaches the real worktree"; fi
if [[ "$(git -C "$FIX_REPO" status --porcelain --ignored | grep -v ' tracked.txt$')" == "$IGNORED_NEW_STATUS" ]]; then pass "real worktree gains no path hidden from git status"; else fail "real worktree gains no path hidden from git status"; fi
expect_contains "note: ignored path not applied: .env" "dropped ignored file is named in a note"
expect_contains "note: ignored path not applied: __pycache__/x.pyc" "dropped file under an ignored directory is named in a note"
expect_contains "ignored paths dropped: 2" "summary counts the dropped ignored paths"
expect_contains "files changed: 1" "dropped ignored paths are not counted as changed files"
IGNORED_NEW_PATCH="$(summary_value "patch")"
if [[ -s "$IGNORED_NEW_PATCH" ]] && ! grep -Eq '\.env|__pycache__' "$IGNORED_NEW_PATCH"; then pass "patch omits the dropped ignored paths"; else fail "patch omits the dropped ignored paths"; fi

# An ignored path that already exists in the real worktree is outside the
# snapshot; the agent's version must not collide with it and strand the rest.
init_fixture ignored-existing
: > "$TMP_ROOT/ignored-existing.cursor.log"
run_case ignored-existing env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/ignored-existing.cursor.log" CURSOR_STUB_ACTION=ignored-existing \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "agent write to an existing ignored path does not fail the dispatch"
expect_file_contains "$FIX_REPO/tracked.txt" cursor-change "ordinary edit is not stranded by the ignored collision"
if [[ "$(cat "$FIX_REPO/ignored.txt")" == 'ignored-content' ]]; then pass "existing ignored file keeps its real content"; else fail "existing ignored file keeps its real content"; fi
expect_contains "note: ignored path not applied: ignored.txt" "colliding ignored path is named in a note"
expect_contains "ignored paths dropped: 1" "summary counts the colliding ignored path"

# A failed dispatch applies nothing, so its work copy stays whole for forensics.
init_fixture ignored-error
: > "$TMP_ROOT/ignored-error.cursor.log"
run_case ignored-error env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/ignored-error.cursor.log" CURSOR_STUB_ACTION=ignored-new \
  CURSOR_STUB_IS_ERROR=true \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 10 "is_error with new ignored paths is still a hard failure"
if [[ -f "$(summary_value "work copy")/.env" ]]; then pass "failed dispatch keeps ignored paths in the forensic work copy"; else fail "failed dispatch keeps ignored paths in the forensic work copy"; fi
if [[ ! -e "$FIX_REPO/.env" && ! -e "$FIX_REPO/__pycache__" ]]; then pass "failed dispatch applies no ignored path"; else fail "failed dispatch applies no ignored path"; fi

# git check-ignore dies on a path beyond a symlink in the real worktree, so
# those paths are never sent to it. An ignored symlink the agent shadows with
# a directory is dropped whole, and the real symlink's target stays untouched.
init_fixture ignored-symlink
printf 'cache\n' >> "$FIX_REPO/.gitignore"
git -C "$FIX_REPO" commit -qam ignore-cache
mkdir "$TMP_ROOT/ignored-symlink-target"
ln -s "$TMP_ROOT/ignored-symlink-target" "$FIX_REPO/cache"
: > "$TMP_ROOT/ignored-symlink.cursor.log"
run_case ignored-symlink env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/ignored-symlink.cursor.log" CURSOR_STUB_ACTION=ignored-symlink \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "directory shadowing an ignored real symlink does not fail the dispatch"
expect_file_contains "$FIX_REPO/tracked.txt" cursor-change "ordinary edit applies beside the shadowed symlink"
if [[ -L "$FIX_REPO/cache" && -z "$(ls -A "$TMP_ROOT/ignored-symlink-target")" ]]; then pass "ignored real symlink and its target are untouched"; else fail "ignored real symlink and its target are untouched"; fi
expect_contains "note: ignored path not applied: cache" "shadowing directory is named in a note"
expect_contains "ignored paths dropped: 1" "summary counts the shadowing directory once"

# A tracked symlink the agent replaces with a directory still applies. Ignore
# rules cannot be asked about the paths beneath it, and a note says so.
init_fixture symlink-to-dir
mkdir "$FIX_REPO/realdir"
printf 'real\n' > "$FIX_REPO/realdir/f.txt"
ln -s realdir "$FIX_REPO/dirlink"
git -C "$FIX_REPO" add realdir dirlink
git -C "$FIX_REPO" commit -qm symlink-base
: > "$TMP_ROOT/symlink-to-dir.cursor.log"
run_case symlink-to-dir env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/symlink-to-dir.cursor.log" CURSOR_STUB_ACTION=symlink-to-dir \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "tracked symlink replaced by a directory still applies"
if [[ ! -L "$FIX_REPO/dirlink" && "$(cat "$FIX_REPO/dirlink/new.txt")" == 'beyond-the-real-symlink' ]]; then pass "replacement directory and its file reach the real worktree"; else fail "replacement directory and its file reach the real worktree"; fi
if [[ "$(ls -A "$FIX_REPO/realdir")" == 'f.txt' ]]; then pass "former symlink target gains no file"; else fail "former symlink target gains no file"; fi
expect_contains "note: ignore rules not checked beyond a real-worktree symlink: dirlink/new.txt" "unchecked path beyond a real symlink is named in a note"

# A filter that cannot walk the work copy fails closed: nothing is applied and
# the copies are retained.
init_fixture unreadable
: > "$TMP_ROOT/unreadable.cursor.log"
run_case unreadable env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/unreadable.cursor.log" CURSOR_STUB_ACTION=unreadable \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
UNREADABLE_WORK="$(summary_value "work copy")"
[[ ! -d "$UNREADABLE_WORK/locked" ]] || chmod 700 "$UNREADABLE_WORK/locked"
expect_status 11 "ignore-filter failure is a hard dispatch failure"
expect_contains "error: could not filter ignored paths; real worktree was not changed" "ignore-filter failure is explicit"
if git -C "$FIX_REPO" diff --quiet -- tracked.txt && [[ ! -e "$FIX_REPO/locked" ]]; then pass "ignore-filter failure leaves the real worktree unchanged"; else fail "ignore-filter failure leaves the real worktree unchanged"; fi
if [[ -f "$UNREADABLE_WORK/locked/file.txt" ]]; then pass "ignore-filter failure retains the work copy"; else fail "ignore-filter failure retains the work copy"; fi

# Read-only uses plan mode in an isolated copy, emits no patch, and applies no
# edits even when the stub violates the app-level plan instruction.
init_fixture plan
: > "$TMP_ROOT/plan.cursor.log"
run_case plan env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/plan.cursor.log" CURSOR_STUB_ACTION=plan-edit \
  bash -c 'cd "$1" && exec "$2" --prompt investigate --read-only --model cursor-grok-4.6-high-fast --effort high' \
  _ "$FIX_REPO" "$DISPATCH"
expect_status 0 "read-only dispatch succeeds"
expect_contains "mode: read-only" "read-only summary names mode"
expect_contains "model: cursor-grok-4.6-high-fast (explicit)" "read-only summary names explicit model"
expect_contains "patch: <none; read-only mode>" "read-only summary has no patch"
expect_contains "files changed: 0" "read-only reports no applicable changes"
expect_log_sequence "$TMP_ROOT/plan.cursor.log" "read-only selects plan mode" --mode plan
expect_log_sequence "$TMP_ROOT/plan.cursor.log" "read-only still pins sandbox enabled" --sandbox enabled
if git -C "$FIX_REPO" diff --quiet -- tracked.txt; then pass "read-only never changes the real tracked file"; else fail "read-only never changes the real tracked file"; fi
PLAN_STATE="$(summary_value "run state")"
if [[ ! -e "$PLAN_STATE/changes.patch" ]]; then pass "read-only creates no patch artifact"; else fail "read-only creates no patch artifact"; fi
PLAN_PRISTINE="$(summary_value "pristine copy")"
PLAN_WORK="$(summary_value "work copy")"
if [[ ! -e "$PLAN_PRISTINE" && ! -e "$PLAN_WORK" ]]; then pass "successful read-only copies are cleaned"; else fail "successful read-only copies are cleaned"; fi

# is_error is a hard failure: preserve forensics and never apply the edit.
init_fixture agent-error
: > "$TMP_ROOT/agent-error.cursor.log"
run_case agent-error env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/agent-error.cursor.log" CURSOR_STUB_ACTION=edit \
  CURSOR_STUB_IS_ERROR=true \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 10 "is_error true is a hard dispatch failure"
expect_contains "is_error: true" "failure summary reports is_error"
expect_contains "forensics: copies and run state retained" "failure reports retained forensics"
if git -C "$FIX_REPO" diff --quiet -- tracked.txt; then pass "is_error edit is not applied to the real worktree"; else fail "is_error edit is not applied to the real worktree"; fi
if [[ ! -e "$FIX_REPO/added.txt" && -e "$FIX_REPO/delete-me.txt" ]]; then pass "is_error add/delete operations are not applied"; else fail "is_error add/delete operations are not applied"; fi
ERROR_PATCH="$(summary_value "patch")"
if [[ -s "$ERROR_PATCH" ]]; then pass "is_error retains the forensic patch"; else fail "is_error retains the forensic patch"; fi
ERROR_PRISTINE="$(summary_value "pristine copy")"
ERROR_WORK="$(summary_value "work copy")"
if [[ -d "$ERROR_PRISTINE" && -d "$ERROR_WORK" ]]; then pass "is_error retains both copies"; else fail "is_error retains both copies"; fi

# Invalid output is also fail-closed and does not apply work-copy changes.
init_fixture bad-json
: > "$TMP_ROOT/bad-json.cursor.log"
run_case bad-json env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/bad-json.cursor.log" CURSOR_STUB_ACTION=edit \
  CURSOR_STUB_OUTPUT=bad \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 10 "invalid cursor JSON fails closed"
expect_contains "is_error: <unparseable>" "invalid JSON is disclosed in the summary"
if git -C "$FIX_REPO" diff --quiet -- tracked.txt; then pass "invalid-JSON edit is not applied"; else fail "invalid-JSON edit is not applied"; fi

# Model/effort and path-boundary refusals happen before agent launch.
init_fixture model-force
: > "$TMP_ROOT/model-force.cursor.log"
run_case model-force env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/model-force.cursor.log" CURSOR_LOOP_MODEL=--force \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 2 "forbidden flag injected as model is refused"
expect_contains "bypass the sandbox" "injected model refusal names sandbox bypass"
if [[ ! -s "$TMP_ROOT/model-force.cursor.log" ]]; then pass "forbidden injected model never launches the agent"; else fail "forbidden injected model never launches the agent"; fi

init_fixture effort-mismatch
: > "$TMP_ROOT/effort-mismatch.cursor.log"
run_case effort-mismatch env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/effort-mismatch.cursor.log" \
  bash -c 'cd "$1" && exec "$2" --prompt x --effort high' _ "$FIX_REPO" "$DISPATCH"
expect_status 2 "mismatched effort assertion is refused"
expect_contains "does not embed that effort" "effort mismatch explains model-id semantics"
if [[ ! -s "$TMP_ROOT/effort-mismatch.cursor.log" ]]; then pass "effort mismatch never launches the agent"; else fail "effort mismatch never launches the agent"; fi

init_fixture inside-copy
: > "$TMP_ROOT/inside-copy.cursor.log"
run_case inside-copy env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/inside-copy.cursor.log" CURSOR_LOOP_WORK_ROOT="$FIX_REPO/cursor-copies" \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_nonzero "copy root inside the real repository is refused"
expect_contains "must be outside the real repository" "inside-copy refusal names the boundary"
if [[ ! -s "$TMP_ROOT/inside-copy.cursor.log" ]]; then pass "inside-copy refusal happens before launch"; else fail "inside-copy refusal happens before launch"; fi

# A .git entry created by the agent fails closed and is never patched back.
init_fixture agent-git
: > "$TMP_ROOT/agent-git.cursor.log"
run_case agent-git env HOME="$FIX_HOME" PATH="$TEST_PATH" \
  CURSOR_STUB_LOG="$TMP_ROOT/agent-git.cursor.log" CURSOR_STUB_ACTION=git-entry \
  bash -c 'cd "$1" && exec "$2" --prompt x' _ "$FIX_REPO" "$DISPATCH"
expect_status 10 "post-dispatch .git creation is refused"
expect_contains "copies and run state retained" "post-dispatch .git failure retains forensics"
GIT_STATE="$(summary_value "run state")"
if [[ ! -e "$GIT_STATE/changes.patch" ]]; then pass ".git-bearing work copy never produces an applicable patch"; else fail ".git-bearing work copy never produces an applicable patch"; fi
if git -C "$FIX_REPO" diff --quiet -- tracked.txt; then pass ".git-bearing work copy cannot change the real worktree"; else fail ".git-bearing work copy cannot change the real worktree"; fi

if grep -q 'git apply -p2 --check --binary' "$DISPATCH"; then pass "source pins pre-apply validation"; else fail "source pins pre-apply validation"; fi
if ! grep -Eq 'git (add|commit|push)|git -C .* (add|commit|push)' "$DISPATCH"; then pass "source contains no stage, commit, or push command"; else fail "source contains no stage, commit, or push command"; fi

EXPECTED_CHECKS=142
if [[ $CHECKS -ne $EXPECTED_CHECKS ]]; then
  printf 'selftest: FAIL (count drift: got %d, expected %d)\n' "$CHECKS" "$EXPECTED_CHECKS" >&2
  exit 1
fi
if [[ $FAILURES -ne 0 ]]; then
  printf 'selftest: FAIL (%d/%d checks failed)\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
