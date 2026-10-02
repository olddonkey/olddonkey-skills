#!/usr/bin/env bash
# Dispatch an implementation or investigation task to Claude Code.
#
# Usage:
#   claude/dispatch.sh --prompt-file PATH [--read-only|--investigate]
#                      [--model MODEL] [--effort LEVEL]
#   claude/dispatch.sh --prompt "short inline prompt" [...]
#
# Run from the target git worktree root. The adapter snapshots tracked plus
# untracked-non-ignored project files into two git-less copies outside the real
# repository. Claude runs only in the work copy under --restricted with a fixed
# tool list and an OS sandbox. After the run, the adapter freezes the work copy
# and applies a checked pristine-vs-frozen patch. It never stages or commits.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ -n "${LOOP_JOURNAL:-}" ]]; then
  JOURNAL_HELPER="$LOOP_JOURNAL"
else
  JOURNAL_HELPER="$SCRIPT_DIR/../../scripts/loop-journal"
fi

MODEL="${CLAUDE_LOOP_MODEL:-}"
MODEL_SOURCE="${MODEL:+CLAUDE_LOOP_MODEL}"
EFFORT="${CLAUDE_LOOP_EFFORT:-}"
EFFORT_SOURCE="${EFFORT:+CLAUDE_LOOP_EFFORT}"
PROMPT_FILE=""
PROMPT=""
READ_ONLY=0

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:?--prompt-file needs a path}"; shift 2 ;;
    --prompt) PROMPT="${2:?--prompt needs text}"; shift 2 ;;
    --model) MODEL="${2:?--model needs a value}"; MODEL_SOURCE="explicit"; shift 2 ;;
    --effort) EFFORT="${2:?--effort needs a value}"; EFFORT_SOURCE="explicit"; shift 2 ;;
    --read-only|--investigate) READ_ONLY=1; shift ;;
    --resume)
      echo "error: claude --resume is unsupported; iterate with a fresh dispatch on the edited copy and put review feedback in the new prompt" >&2
      exit 2
      ;;
    --background)
      echo "error: --background is companion-only; background this foreground adapter at the harness level" >&2
      exit 2
      ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

if [[ -n "${CLAUDE_LOOP_EXTRA_ARGS:-}" ]]; then
  echo "error: CLAUDE_LOOP_EXTRA_ARGS is unsupported; claude control flags are fixed by the adapter" >&2
  exit 2
fi

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 2; }

for REQUIRED in git claude python3; do
  command -v "$REQUIRED" >/dev/null 2>&1 || {
    echo "error: required command not found: $REQUIRED" >&2
    exit 3
  }
done

case "$MODEL" in
  -*)
    echo "error: claude model must be an id, not a CLI option" >&2
    exit 2
    ;;
esac

if [[ -n "$EFFORT" ]]; then
  case "$EFFORT" in
    low|medium|high|xhigh|max) ;;
    *)
      echo "error: claude effort must be low, medium, high, xhigh, or max" >&2
      exit 2
      ;;
  esac
fi

canonical_existing_dir() {
  python3 - "$1" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1])
if not os.path.isdir(path):
    raise SystemExit(1)
print(path)
PY
}

canonical_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
}

WORKSPACE="$(canonical_existing_dir "$PWD")" || {
  echo "error: target workspace is not a directory: $PWD" >&2
  exit 3
}
GIT_TOP="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_TOP" ]] || { echo "error: target workspace is not a git worktree" >&2; exit 3; }
GIT_TOP="$(canonical_existing_dir "$GIT_TOP")"
[[ "$GIT_TOP" == "$WORKSPACE" ]] || {
  echo "error: run from the target git worktree root: $GIT_TOP" >&2
  exit 3
}
[[ "$(git -C "$WORKSPACE" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || {
  echo "error: target workspace is not a non-bare git worktree" >&2
  exit 3
}

COMMON_RAW="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
COMMON_DIR="$(python3 - "$WORKSPACE" "$COMMON_RAW" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
)"

CLAUDE_VERSION="$(claude --version 2>&1)" || {
  echo "error: could not determine claude version" >&2
  exit 3
}
CLAUDE_VERSION="${CLAUDE_VERSION%%$'\n'*}"
[[ -n "$CLAUDE_VERSION" ]] || { echo "error: claude returned an empty version" >&2; exit 3; }

DISPATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
STATE_ROOT="$COMMON_DIR/olddonkey-loop/claude"
STATE_DIR="$STATE_ROOT/$DISPATCH_ID"
WORK_ROOT="${CLAUDE_LOOP_WORK_ROOT:-${HOME:?HOME is required}/.config/olddonkey-loop/claude-work}"
COPY_ROOT="$WORK_ROOT/$DISPATCH_ID"
PRISTINE="$COPY_ROOT/pristine"
WORK_COPY="$COPY_ROOT/work"
FROZEN="$COPY_ROOT/frozen"

STATE_CANON="$(canonical_path "$STATE_DIR")"
COPY_CANON="$(canonical_path "$COPY_ROOT")"
PRISTINE_CANON="$(canonical_path "$PRISTINE")"
WORK_COPY_CANON="$(canonical_path "$WORK_COPY")"

python3 - "$WORKSPACE" "$STATE_CANON" "$COPY_CANON" "$PRISTINE_CANON" "$WORK_COPY_CANON" <<'PY'
import os, sys
workspace, state, copy_root, pristine, work = map(os.path.realpath, sys.argv[1:])

def overlap(left, right):
    try:
        return os.path.commonpath((left, right)) in (left, right)
    except ValueError:
        return False

if overlap(workspace, copy_root):
    print(f"error: claude copy root must be outside the real repository: {copy_root}", file=sys.stderr)
    raise SystemExit(1)
if overlap(state, pristine) or overlap(state, work):
    print("error: protected run state must be outside both claude copies", file=sys.stderr)
    raise SystemExit(1)
if overlap(pristine, work):
    print("error: pristine and work copies must be disjoint", file=sys.stderr)
    raise SystemExit(1)
PY

[[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
  echo "error: claude run state already exists: $STATE_DIR" >&2
  exit 4
}
[[ ! -e "$COPY_ROOT" && ! -L "$COPY_ROOT" ]] || {
  echo "error: claude copy root already exists: $COPY_ROOT" >&2
  exit 4
}
mkdir -p "$STATE_ROOT" "$WORK_ROOT"
chmod 700 "$STATE_ROOT" "$WORK_ROOT"
mkdir "$STATE_DIR" "$COPY_ROOT"
chmod 700 "$STATE_DIR" "$COPY_ROOT"

MANIFEST="$STATE_DIR/project-files.zlist"
git -C "$WORKSPACE" ls-files -z --cached --others --exclude-standard > "$MANIFEST"
chmod 600 "$MANIFEST"

python3 - "$WORKSPACE" "$PRISTINE" "$WORK_COPY" "$MANIFEST" <<'PY'
import os
import shutil
import stat
import sys

workspace, pristine, work, manifest = sys.argv[1:]
workspace = os.path.realpath(workspace)
entries = [entry for entry in open(manifest, "rb").read().split(b"\0") if entry]
os.mkdir(pristine, 0o700)

for raw in entries:
    relative = os.fsdecode(raw)
    normalized = os.path.normpath(relative)
    parts = normalized.split(os.sep)
    if (
        os.path.isabs(relative)
        or normalized in {"", ".", ".."}
        or normalized.startswith(".." + os.sep)
        or any(part.casefold() == ".git" for part in parts)
    ):
        print(f"error: unsafe or git-bearing project path in manifest: {relative!r}", file=sys.stderr)
        raise SystemExit(1)
    source = os.path.join(workspace, normalized)
    if not os.path.lexists(source):
        # A tracked deletion is part of the working-tree snapshot by absence.
        continue
    destination = os.path.join(pristine, normalized)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    info = os.lstat(source)
    if stat.S_ISREG(info.st_mode):
        shutil.copy2(source, destination, follow_symlinks=False)
    elif stat.S_ISLNK(info.st_mode):
        if os.path.basename(normalized).casefold() == ".claude":
            print(f"error: symlink named .claude has an unsupported layout: {relative!r}", file=sys.stderr)
            raise SystemExit(5)
        os.symlink(os.readlink(source), destination)
    elif stat.S_ISDIR(info.st_mode):
        # git ls-files reports a gitlink as one path. Preserve the path without
        # recursing into nested git metadata that is not in the manifest.
        os.makedirs(destination, exist_ok=True)
    else:
        print(f"error: unsupported project file type: {relative!r}", file=sys.stderr)
        raise SystemExit(1)

shutil.copytree(pristine, work, symlinks=True, copy_function=shutil.copy2)

def walk_error(error):
    raise error

for label, root in (("pristine", pristine), ("work", work)):
    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        if any(name.casefold() == ".git" for name in dirnames + filenames):
            print(f"error: {label} copy contains a forbidden .git entry", file=sys.stderr)
            raise SystemExit(1)
PY
chmod 700 "$PRISTINE" "$WORK_COPY"

gitless_check() {
  local root="$1"
  if (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1
  ); then
    echo "error: claude copy is inside a git repository and is not git-less: $root" >&2
    return 1
  fi
}
gitless_check "$PRISTINE" || exit 5
gitless_check "$WORK_COPY" || exit 5

PREAMBLE="You are in a git-less copy of the project. Edit files in this work copy only. Do not create a .git entry or run git."
if [[ $READ_ONLY -eq 1 ]]; then
  PREAMBLE="$PREAMBLE Investigate and return an argument or plan only; do not edit files."
fi
FULL_PROMPT="$PREAMBLE

$PROMPT"
PROMPT_RECORD="$STATE_DIR/prompt.txt"
printf '%s' "$FULL_PROMPT" > "$PROMPT_RECORD"
chmod 600 "$PROMPT_RECORD"

STREAM_JSONL="$STATE_DIR/stream.jsonl"
STDERR_LOG="$STATE_DIR/stderr.log"
SETTINGS='{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false},"permissions":{"deny":["WebFetch","WebSearch"]}}'
TOOLS=(Bash Read Edit Write Glob Grep)
PMODE=acceptEdits
if [[ $READ_ONLY -eq 1 ]]; then
  TOOLS=(Read Glob Grep)
  PMODE=default
fi
CONTROL_ARGS=(claude -p)
[[ -z "$MODEL" ]] || CONTROL_ARGS+=(--model "$MODEL")
[[ -z "$EFFORT" ]] || CONTROL_ARGS+=(--effort "$EFFORT")
CONTROL_ARGS+=(--restricted --tools "${TOOLS[@]}"
  --permission-mode "$PMODE" --permission-prompts none --no-chrome
  --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  --settings "$SETTINGS" --disallowedTools WebFetch WebSearch Task Agent
  --no-session-persistence --output-format stream-json --verbose)

LOOP_JOURNAL_END_DONE=0
journal_helper_ok() {
  [[ -n "${JOURNAL_HELPER:-}" && -f "$JOURNAL_HELPER" && -x "$JOURNAL_HELPER" ]]
}

journal_dispatch_start() {
  journal_helper_ok || return 0
  local loop_home mode
  # mkdir -p of claude-work can create this directory at 0755; loop-journal
  # requires 0700 and treats a mismatch as a failed dispatch.start.
  loop_home="${HOME:?}/.config/olddonkey-loop"
  mkdir -p "$loop_home" || return $?
  chmod 700 "$loop_home" || return $?
  mode="$([[ $READ_ONLY -eq 1 ]] && echo read-only || echo implement)"
  "$JOURNAL_HELPER" append --workspace "$WORKSPACE" --event dispatch.start \
    --field "dispatch_id=$DISPATCH_ID" --field backend=claude --field "mode=$mode"
}

journal_dispatch_end() { # $1=exit [ $2=session ]
  local exit_code="$1" session="${2:-}"
  [[ "$LOOP_JOURNAL_END_DONE" -eq 0 ]] || return 0
  LOOP_JOURNAL_END_DONE=1
  journal_helper_ok || return 0
  local -a args
  args=(append --workspace "$WORKSPACE" --event dispatch.end
    --field "dispatch_id=$DISPATCH_ID" --field "exit=$exit_code")
  [[ -z "$session" ]] || args+=(--field "session=$session")
  if ! "$JOURNAL_HELPER" "${args[@]}"; then
    echo "warning: loop-journal dispatch.end failed" >&2
  fi
  return 0
}

journal_dispatch_start || {
  start_rc=$?
  echo "error: loop-journal dispatch.start failed; refusing to launch" >&2
  exit "$start_rc"
}
trap 'journal_dispatch_end "$?" "${SESSION_ID:-}"' EXIT

set +e
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  cd "$WORK_COPY"
  "${CONTROL_ARGS[@]}" "$FULL_PROMPT" < /dev/null
) > "$STREAM_JSONL" 2> "$STDERR_LOG"
CLAUDE_STATUS=$?
set -e
chmod 600 "$STREAM_JSONL" "$STDERR_LOG"

# Validate both stream milestones before considering the child status. The
# granted tool list is reported by Claude after launch: this is detection,
# while containment is provided by the CLI's restriction and OS sandbox.
PARSE_OK=1
SESSION_ID=""
TOOLS_GRANTED="<not reported>"
RESULT_FILE="$STATE_DIR/last-message.txt"
PARSE_META=""
if ! PARSE_META="$(python3 - "$STREAM_JSONL" "$RESULT_FILE" "${TOOLS[@]}" <<'PY_VALIDATE'
import json
import re
import sys

stream_path, result_path, *wanted = sys.argv[1:]
events = []
try:
    with open(stream_path, encoding="utf-8") as stream:
        for line in stream:
            events.append(json.loads(line))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    print(f"boundary: invalid Claude stream: {exc}", file=sys.stderr)
    raise SystemExit(1)

init_indexes = [i for i, e in enumerate(events) if isinstance(e, dict) and e.get("type") == "system" and e.get("subtype") == "init"]
result_indexes = [i for i, e in enumerate(events) if isinstance(e, dict) and e.get("type") == "result"]
if len(init_indexes) != 1:
    print(f"boundary: expected exactly one system/init event, found {len(init_indexes)}", file=sys.stderr)
    raise SystemExit(1)
init = events[init_indexes[0]]
tools = init.get("tools")
session_id = init.get("session_id")
if (not isinstance(tools, list)
        or not all(isinstance(t, str) and re.fullmatch(r"[A-Za-z0-9_]{1,64}", t) for t in tools)
        or sorted(tools) != sorted(wanted) or init.get("mcp_servers") != []):
    print("boundary: granted tools or MCP servers differ from the fixed allowlist", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", session_id):
    print("boundary: init event has an invalid session_id", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({"session": session_id, "tools": tools}), flush=True)

if len(result_indexes) != 1:
    print(f"boundary: expected exactly one result event, found {len(result_indexes)}", file=sys.stderr)
    raise SystemExit(1)
if init_indexes[0] >= result_indexes[0]:
    print("boundary: init event must precede result event", file=sys.stderr)
    raise SystemExit(1)
result = events[result_indexes[0]]
if (result.get("subtype") != "success" or result.get("is_error") is not False
        or not isinstance(result.get("result"), str)
        or result.get("session_id") != session_id):
    print("boundary: result event failed success, result, or session contract", file=sys.stderr)
    raise SystemExit(1)
try:
    encoded = result["result"].encode("utf-8")
    with open(result_path, "wb") as handle:
        handle.write(encoded)
except (OSError, UnicodeError) as exc:
    import os
    try:
        os.unlink(result_path)
    except FileNotFoundError:
        pass
    print(f"boundary: cannot write UTF-8 result: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_VALIDATE
)"; then
  PARSE_OK=0
else
  chmod 600 "$RESULT_FILE"
fi
if [[ -n "$PARSE_META" ]]; then
  SESSION_ID="$(python3 -c 'import json,sys; value=json.loads(sys.argv[1])["session"]; print(value if isinstance(value,str) else "",end="")' "$PARSE_META")"
  TOOLS_GRANTED="$(python3 -c 'import json,sys; value=json.loads(sys.argv[1])["tools"]; print(" ".join(value) if isinstance(value,list) and all(isinstance(v,str) for v in value) else "<not reported>",end="")' "$PARSE_META")"
fi

FINAL_STATUS=0
if [[ $CLAUDE_STATUS -ne 0 ]]; then
  FINAL_STATUS=$CLAUDE_STATUS
elif [[ $PARSE_OK -ne 1 ]]; then
  FINAL_STATUS=10
fi

if [[ $FINAL_STATUS -eq 0 ]]; then
  if ! python3 - "$WORK_COPY" "$FROZEN" <<'PY_FREEZE'
import os
import shutil
import stat
import sys

work, frozen = sys.argv[1:]

def walk_error(error):
    raise error

def copy_file(source, destination):
    info = os.lstat(source)
    if stat.S_ISFIFO(info.st_mode):
        os.mkfifo(destination, stat.S_IMODE(info.st_mode))
        return destination
    return shutil.copy2(source, destination, follow_symlinks=False)

try:
    if os.path.islink(work):
        raise OSError("work root became a symlink")
    for directory, _, _ in os.walk(work, followlinks=False, onerror=walk_error):
        if stat.S_IMODE(os.lstat(directory).st_mode) & 0o444 == 0:
            raise PermissionError(f"unreadable directory: {directory}")
    shutil.copytree(work, frozen, symlinks=True, copy_function=copy_file)
except Exception as exc:
    print(f"boundary: could not freeze work copy: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_FREEZE
  then
    FINAL_STATUS=10
  fi
fi
if [[ $FINAL_STATUS -eq 0 ]]; then
  if ! : > "$COPY_ROOT/frozen.ok"; then
    echo "boundary: could not record completed frozen copy" >&2
    FINAL_STATUS=10
  fi
fi

IGNORED_DROPPED=0
if [[ $FINAL_STATUS -eq 0 ]]; then
  if ! IGNORED_DROPPED="$(python3 - "$WORKSPACE" "$PRISTINE" "$FROZEN" <<'PY_IGNORE'
import os
import shutil
import subprocess
import sys

workspace, pristine, frozen = sys.argv[1:]

def walk_error(error):
    raise error

def paths(root):
    found = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirnames + filenames:
            found.append(os.path.relpath(os.path.join(directory, name), root))
    return found

def beyond_symlink(path):
    # git check-ignore dies on a path whose parent is a symlink in the real
    # worktree. The symlink itself is still asked about, and dropping it
    # drops everything the agent put beneath that name.
    parent = os.path.dirname(path)
    while parent:
        if os.path.islink(os.path.join(workspace, parent)):
            return True
        parent = os.path.dirname(parent)
    return False

def shown(path):
    return path.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

try:
    baseline = set(paths(pristine))
    new_paths = [path for path in paths(frozen) if path not in baseline]
    askable = {path for path in new_paths if not beyond_symlink(path)}
    ignored = set()
    if askable:
        payload = b"\0".join(os.fsencode(path) for path in sorted(askable)) + b"\0"
        checked = subprocess.run(
            ["git", "-C", workspace, "check-ignore", "-z", "--stdin"],
            input=payload, capture_output=True,
        )
        if checked.returncode not in (0, 1):
            raise OSError(f"git check-ignore failed ({checked.returncode}): {checked.stderr.decode(errors='replace')}")
        ignored = {os.fsdecode(path) for path in checked.stdout.split(b"\0") if path}
        if not ignored.issubset(askable):
            raise OSError("git check-ignore returned an unexpected path")
    for path in sorted(ignored, key=lambda value: (value.count(os.sep), value)):
        target = os.path.join(frozen, path)
        if os.path.islink(target) or not os.path.isdir(target):
            if os.path.lexists(target):
                os.unlink(target)
        elif os.path.lexists(target):
            shutil.rmtree(target)
    for path in sorted(ignored)[:20]:
        print(f"note: ignored path not applied: {shown(path)}", file=sys.stderr)
    if len(ignored) > 20:
        print(f"note: ignored paths not applied: {len(ignored) - 20} more (total {len(ignored)})", file=sys.stderr)
    unchecked = sorted(
        path for path in new_paths
        if path not in askable and os.path.lexists(os.path.join(frozen, path))
    )
    for path in unchecked[:20]:
        print(f"note: ignore rules not checked beyond a real-worktree symlink: {shown(path)}", file=sys.stderr)
    if len(unchecked) > 20:
        print(f"note: ignore rules not checked beyond a real-worktree symlink: {len(unchecked) - 20} more (total {len(unchecked)})", file=sys.stderr)
    print(len(ignored))
except Exception as exc:
    print(f"boundary: could not filter ignored paths: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_IGNORE
)"; then
    IGNORED_DROPPED=0
    FINAL_STATUS=10
  fi
fi

CLAUDE_DIR_DROPPED=0
if [[ $FINAL_STATUS -eq 0 ]]; then
  if ! CLAUDE_DIR_DROPPED="$(python3 - "$PRISTINE" "$FROZEN" <<'PY_CLAUDE_DROP'
import os
import shutil
import stat
import sys

pristine, frozen = sys.argv[1:]

def walk_error(error):
    raise error

def under_claude(path):
    return any(part.casefold() == ".claude" for part in path.split(os.sep))

def entries(root):
    found = {}
    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirnames + filenames:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            is_directory = stat.S_ISDIR(os.lstat(path).st_mode)
            is_empty = is_directory and not os.listdir(path)
            found[relative] = (is_directory, is_empty)
    return found

def has_parent(path, directories):
    parent = os.path.dirname(path)
    while parent and parent != ".":
        if parent in directories:
            return True
        parent = os.path.dirname(parent)
    return False

try:
    baseline = entries(pristine)
    new = {
        path: value for path, value in entries(frozen).items()
        if under_claude(path) and path not in baseline
    }
    directories = {path for path, (is_dir, _) in new.items() if is_dir}
    root_directories = {path for path in directories if not has_parent(path, directories)}
    files = {path for path, (is_dir, _) in new.items() if not is_dir}
    count = sum(not is_dir or is_empty for is_dir, is_empty in new.values())
    notes = sorted(files | root_directories)
    targets = sorted(root_directories | {path for path in files if not has_parent(path, root_directories)})
    for path in targets:
        target = os.path.join(frozen, path)
        if path in root_directories:
            shutil.rmtree(target)
        else:
            os.unlink(target)
    for path in notes[:20]:
        shown = path.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        print(f"note: new path under .claude/ not applied: {shown}", file=sys.stderr)
    if len(notes) > 20:
        print(f"note: new paths under .claude/ not applied: {len(notes) - 20} more (total {len(notes)})", file=sys.stderr)
    print(count)
except Exception as exc:
    print(f"boundary: could not drop new .claude paths: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_CLAUDE_DROP
)"; then
    CLAUDE_DIR_DROPPED=0
    FINAL_STATUS=10
  fi
fi

if [[ $FINAL_STATUS -eq 0 ]]; then
  if ! python3 - "$PRISTINE" "$FROZEN" <<'PY_BOUNDARY'
import hashlib
import os
import stat
import sys

pristine, frozen = sys.argv[1:]

def walk_error(error):
    raise error

def under_claude(path):
    return any(part.casefold() == ".claude" for part in path.split(os.sep))

def inventory(root, check_git):
    found = {}
    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        if stat.S_IMODE(os.lstat(directory).st_mode) & 0o444 == 0:
            raise PermissionError(f"unreadable directory: {directory}")
        for name in dirnames + filenames:
            if check_git and name.casefold() == ".git":
                raise ValueError(f"forbidden .git entry: {os.path.join(directory, name)}")
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            info = os.lstat(path)
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                found[relative] = ("link", mode, os.readlink(path))
            elif stat.S_ISREG(info.st_mode):
                digest = None
                if under_claude(relative):
                    with open(path, "rb") as handle:
                        digest = hashlib.file_digest(handle, "sha256").hexdigest()
                found[relative] = ("file", mode, digest)
            elif stat.S_ISDIR(info.st_mode):
                found[relative] = ("dir", mode)
            else:
                found[relative] = ("special", mode)
    return found

try:
    original = inventory(pristine, False)
    captured = inventory(frozen, True)
    changed = sorted(
        path for path in original.keys() | captured.keys()
        if under_claude(path) and original.get(path) != captured.get(path)
    )
    if changed:
        for path in changed[:20]:
            print(f"boundary: change under .claude/ refused: {path}", file=sys.stderr)
        if len(changed) > 20:
            print(f"boundary: change under .claude/ refused: {len(changed) - 20} more paths", file=sys.stderr)
        raise SystemExit(1)
    for path, value in captured.items():
        if value[0] == "link" and (path not in original or original[path][0] != "link" or original[path][2] != value[2]):
            raise ValueError(f"new or changed symlink: {path}")
except (OSError, ValueError) as exc:
    print(f"boundary: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_BOUNDARY
  then
    FINAL_STATUS=10
  fi
fi

# git diff --no-index cannot represent a FIFO or other special file safely.
if [[ $FINAL_STATUS -eq 0 && $READ_ONLY -eq 0 ]]; then
  if ! python3 - "$FROZEN" <<'PY_TYPES'
import os
import stat
import sys

def walk_error(error):
    raise error

try:
    root = sys.argv[1]
    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirnames + filenames:
            path = os.path.join(directory, name)
            mode = os.lstat(path).st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                print(f"error: cannot diff unsupported file type: {os.path.relpath(path, root)}", file=sys.stderr)
                raise SystemExit(1)
except OSError as exc:
    print(f"boundary: frozen copy walk failed: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY_TYPES
  then
    FINAL_STATUS=11
  fi
fi

PATCH_PATH="$STATE_DIR/changes.patch"
FILES_CHANGED=0
if [[ $READ_ONLY -eq 1 ]]; then
  PATCH_DESCRIPTION="<none; read-only mode>"
else
  PATCH_DESCRIPTION="<not generated>"
fi
APPLIED=no
if [[ $READ_ONLY -eq 0 && $FINAL_STATUS -eq 0 ]]; then
  set +e
  (cd "$COPY_ROOT" && git diff --no-index --binary --no-renames \
    --no-ext-diff --no-textconv --no-color \
    --src-prefix=a/ --dst-prefix=b/ -- pristine frozen) > "$PATCH_PATH"
  DIFF_STATUS=$?
  set -e
  if [[ $DIFF_STATUS -gt 1 ]]; then
    echo "error: could not compute pristine-vs-work patch" >&2
    FINAL_STATUS=11
  else
    chmod 600 "$PATCH_PATH"
    PATCH_DESCRIPTION="$PATCH_PATH"
    FILES_CHANGED="$(LC_ALL=C grep -c '^diff --git ' "$PATCH_PATH" || true)"
    if [[ -s "$PATCH_PATH" ]]; then
      # --whitespace=nowarn overrides a configured apply.whitespace, which
      # would otherwise rewrite (fix) or refuse (error) the agent's lines.
      if ! (umask 022; cd "$WORKSPACE" && git apply -p2 --check --binary --whitespace=nowarn "$PATCH_PATH") \
        > "$STATE_DIR/apply-check.log" 2>&1; then
        echo "error: captured claude patch does not apply cleanly; real worktree was not changed" >&2
        FINAL_STATUS=12
      else
        APPLIED=yes
        if ! (umask 022; cd "$WORKSPACE" && git apply -p2 --binary --whitespace=nowarn "$PATCH_PATH") \
          > "$STATE_DIR/apply.log" 2>&1; then
          echo "error: captured claude patch failed during apply after a successful check" >&2
          FINAL_STATUS=13
        fi
      fi
    fi
  fi
fi

MODE="$([[ $READ_ONLY -eq 1 ]] && echo read-only || echo implement)"
MODEL_DESCRIPTION="${MODEL:-<claude CLI configuration>} (${MODEL_SOURCE:-not overridden})"
EFFORT_DESCRIPTION="${EFFORT:-<claude CLI configuration>} (${EFFORT_SOURCE:-not overridden})"

COPIES_RETAINED="yes"
if [[ $FINAL_STATUS -eq 0 && "${CLAUDE_LOOP_KEEP_COPIES:-0}" != "1" ]]; then
  if python3 - "$COPY_ROOT" "$WORK_ROOT" "$DISPATCH_ID" <<'PY'
import os, shutil, sys
target = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])
dispatch_id = sys.argv[3]
expected = os.path.join(root, dispatch_id)
if target != expected or not dispatch_id:
    print(f"error: refusing unsafe claude-copy cleanup target: {target}", file=sys.stderr)
    raise SystemExit(1)
shutil.rmtree(target)
PY
  then
    COPIES_RETAINED="no"
  else
    FINAL_STATUS=14
    echo "error: successful dispatch could not safely clean its isolated copies" >&2
  fi
fi

echo "claude dispatch summary:"
echo "workspace: $WORKSPACE"
echo "claude version: $CLAUDE_VERSION"
echo "model: $MODEL_DESCRIPTION"
echo "effort: $EFFORT_DESCRIPTION"
echo "mode: $MODE"
echo "tools granted: $TOOLS_GRANTED"
echo "session id: ${SESSION_ID:-<not reported>}"
echo "resume: no (fresh dispatch only)"
echo "run state: $STATE_DIR"
echo "pristine copy: $PRISTINE"
echo "work copy: $WORK_COPY"
echo "copies retained: $COPIES_RETAINED"
echo "patch: $PATCH_DESCRIPTION"
echo "files changed: $FILES_CHANGED"
echo "applied: $APPLIED"
echo "ignored paths dropped: $IGNORED_DROPPED"
echo "claude-dir paths dropped: $CLAUDE_DIR_DROPPED"
echo "enforcement: git-less copy; --restricted with a closed tool list; Bash only inside the CLI's OS sandbox (failIfUnavailable); no setting sources; no MCP; the tool-list check after the run is detection, not containment"
echo "git ownership: orchestrator owns commit, gate, and publish; dispatcher only applies the captured patch"
[[ ! -s "$RESULT_FILE" ]] || cat "$RESULT_FILE"

if [[ $FINAL_STATUS -ne 0 ]]; then
  echo "forensics: copies and run state retained; claude stderr: $STDERR_LOG" >&2
fi
exit "$FINAL_STATUS"
