#!/usr/bin/env bash
# Dispatch an implementation or investigation task to cursor-agent.
#
# Usage:
#   cursor-dispatch.sh --prompt-file PATH [--read-only|--investigate]
#                      [--model MODEL] [--effort LEVEL]
#   cursor-dispatch.sh --prompt "short inline prompt" [...]
#
# Run from the target git worktree root. The adapter snapshots tracked plus
# untracked-non-ignored project files into two git-less copies outside the real
# repository. cursor-agent runs only in the work copy with --trust and
# --sandbox enabled; it never receives --force, -f, or --yolo. Implement mode
# turns pristine-vs-work into a normalized patch, checks it, and applies it to
# the invoking worktree. The adapter never stages, commits, pushes, or resumes.
#
# The default model is cursor-grok-4.6-xhigh. CURSOR_LOOP_MODEL may override it.
# CURSOR_LOOP_EFFORT or --effort is an assertion against the effort embedded in
# that model id; cursor-agent has no separate effort flag.

set -euo pipefail

DEFAULT_MODEL="cursor-grok-4.6-xhigh"
if [[ -n "${CURSOR_LOOP_MODEL:-}" ]]; then
  MODEL="$CURSOR_LOOP_MODEL"
  MODEL_SOURCE="CURSOR_LOOP_MODEL"
else
  MODEL="$DEFAULT_MODEL"
  MODEL_SOURCE="adapter default"
fi
EFFORT="${CURSOR_LOOP_EFFORT:-}"
EFFORT_SOURCE="${EFFORT:+CURSOR_LOOP_EFFORT}"
PROMPT_FILE=""
PROMPT=""
READ_ONLY=0

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit "${1:-0}"
}

refuse_run_everything() {
  echo "error: cursor-agent Run Everything flags (--force, -f, --yolo) are forbidden; they bypass the sandbox" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:?--prompt-file needs a path}"; shift 2 ;;
    --prompt) PROMPT="${2:?--prompt needs text}"; shift 2 ;;
    --model) MODEL="${2:?--model needs a value}"; MODEL_SOURCE="explicit"; shift 2 ;;
    --effort) EFFORT="${2:?--effort needs a value}"; EFFORT_SOURCE="explicit"; shift 2 ;;
    --read-only|--investigate) READ_ONLY=1; shift ;;
    --resume)
      echo "error: cursor-agent --resume is unsupported; iterate with a fresh dispatch on the edited copy and put review feedback in the new prompt" >&2
      exit 2
      ;;
    --background)
      echo "error: --background is companion-only; background this foreground adapter at the harness level" >&2
      exit 2
      ;;
    --force|-f|--yolo) refuse_run_everything ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

if [[ -n "${CURSOR_LOOP_EXTRA_ARGS:-}" ]]; then
  echo "error: CURSOR_LOOP_EXTRA_ARGS is unsupported; cursor-agent control flags are fixed by the adapter" >&2
  exit 2
fi

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 2; }

for REQUIRED in git cursor-agent python3; do
  command -v "$REQUIRED" >/dev/null 2>&1 || {
    echo "error: required command not found: $REQUIRED" >&2
    exit 3
  }
done

case "$MODEL" in
  --force|-f|--yolo) refuse_run_everything ;;
esac

if [[ -n "$EFFORT" ]]; then
  case "$EFFORT" in
    low|medium|high|xhigh) ;;
    *)
      echo "error: cursor-agent effort must be low, medium, high, or xhigh and is embedded in the model id" >&2
      exit 2
      ;;
  esac
  case "$MODEL" in
    *-"$EFFORT"|*-"$EFFORT"-fast) ;;
    *)
      echo "error: --effort $EFFORT is an assertion, but model '$MODEL' does not embed that effort; choose a matching cursor model id" >&2
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

CURSOR_VERSION="$(cursor-agent --version 2>&1)" || {
  echo "error: could not determine cursor-agent version" >&2
  exit 3
}
CURSOR_VERSION="${CURSOR_VERSION%%$'\n'*}"
[[ -n "$CURSOR_VERSION" ]] || { echo "error: cursor-agent returned an empty version" >&2; exit 3; }

DISPATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
STATE_ROOT="$COMMON_DIR/olddonkey-loop/cursor"
STATE_DIR="$STATE_ROOT/$DISPATCH_ID"
WORK_ROOT="${CURSOR_LOOP_WORK_ROOT:-${HOME:?HOME is required}/.config/olddonkey-loop/cursor-work}"
COPY_ROOT="$WORK_ROOT/$DISPATCH_ID"
PRISTINE="$COPY_ROOT/pristine"
WORK_COPY="$COPY_ROOT/work"

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
    print(f"error: cursor copy root must be outside the real repository: {copy_root}", file=sys.stderr)
    raise SystemExit(1)
if overlap(state, pristine) or overlap(state, work):
    print("error: protected run state must be outside both cursor copies", file=sys.stderr)
    raise SystemExit(1)
if overlap(pristine, work):
    print("error: pristine and work copies must be disjoint", file=sys.stderr)
    raise SystemExit(1)
PY

[[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
  echo "error: cursor run state already exists: $STATE_DIR" >&2
  exit 4
}
[[ ! -e "$COPY_ROOT" && ! -L "$COPY_ROOT" ]] || {
  echo "error: cursor copy root already exists: $COPY_ROOT" >&2
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
        or ".git" in parts
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
        os.symlink(os.readlink(source), destination)
    elif stat.S_ISDIR(info.st_mode):
        # git ls-files reports a gitlink as one path. Preserve the path without
        # recursing into nested git metadata that is not in the manifest.
        os.makedirs(destination, exist_ok=True)
    else:
        print(f"error: unsupported project file type: {relative!r}", file=sys.stderr)
        raise SystemExit(1)

shutil.copytree(pristine, work, symlinks=True, copy_function=shutil.copy2)

for label, root in (("pristine", pristine), ("work", work)):
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        if ".git" in dirnames or ".git" in filenames:
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
    echo "error: cursor copy is inside a git repository and is not git-less: $root" >&2
    return 1
  fi
}
gitless_check "$PRISTINE" || exit 5
gitless_check "$WORK_COPY" || exit 5

PREAMBLE="You are in an isolated, network-less sandbox containing a copy of the project files. There is no git here. Implement the change by editing files in this directory only. Do not attempt network access or to reach any path outside this directory."
if [[ $READ_ONLY -eq 1 ]]; then
  PREAMBLE="$PREAMBLE Investigate and return an argument or plan only; do not edit files."
fi
FULL_PROMPT="$PREAMBLE

$PROMPT"
PROMPT_RECORD="$STATE_DIR/prompt.txt"
printf '%s' "$FULL_PROMPT" > "$PROMPT_RECORD"
chmod 600 "$PROMPT_RECORD"

OUTPUT_JSON="$STATE_DIR/output.json"
STDERR_LOG="$STATE_DIR/stderr.log"
CONTROL_ARGS=(cursor-agent -p --trust --sandbox enabled)
[[ $READ_ONLY -eq 0 ]] || CONTROL_ARGS+=(--mode plan)
CONTROL_ARGS+=(--model "$MODEL" --output-format json)

for ARG in "${CONTROL_ARGS[@]}"; do
  case "$ARG" in
    --force|-f|--yolo) refuse_run_everything ;;
  esac
done

set +e
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  cd "$WORK_COPY"
  "${CONTROL_ARGS[@]}" "$FULL_PROMPT"
) > "$OUTPUT_JSON" 2> "$STDERR_LOG"
CURSOR_STATUS=$?
set -e
chmod 600 "$OUTPUT_JSON" "$STDERR_LOG"

POST_COPY_OK=1
if ! python3 - "$WORK_COPY" <<'PY'
import os, sys
root = sys.argv[1]
for directory, dirnames, filenames in os.walk(root, followlinks=False):
    if ".git" in dirnames or ".git" in filenames:
        print(f"error: cursor-agent created a forbidden .git entry under {directory}", file=sys.stderr)
        raise SystemExit(1)
PY
then
  POST_COPY_OK=0
fi

PARSE_OK=1
IS_ERROR="<unparseable>"
SESSION_ID=""
RESULT_FILE="$STATE_DIR/result.txt"
if ! python3 - "$OUTPUT_JSON" "$STATE_DIR/parsed.json" "$RESULT_FILE" <<'PY'
import json, sys
source, parsed_path, result_path = sys.argv[1:]
try:
    with open(source, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"error: cursor-agent output is not valid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(data, dict):
    print("error: cursor-agent JSON output is not an object", file=sys.stderr)
    raise SystemExit(1)
is_error = data.get("is_error")
result = data.get("result")
session_id = data.get("session_id")
if not isinstance(is_error, bool) or not isinstance(result, str) or not isinstance(session_id, str):
    print("error: cursor-agent JSON lacks calibrated is_error/result/session_id fields", file=sys.stderr)
    raise SystemExit(1)
with open(parsed_path, "w", encoding="utf-8") as handle:
    json.dump({"is_error": is_error, "session_id": session_id}, handle, sort_keys=True)
    handle.write("\n")
with open(result_path, "w", encoding="utf-8") as handle:
    handle.write(result)
PY
then
  PARSE_OK=0
else
  chmod 600 "$STATE_DIR/parsed.json" "$RESULT_FILE"
  IS_ERROR="$(python3 - "$STATE_DIR/parsed.json" <<'PY'
import json, sys
print(str(json.load(open(sys.argv[1], encoding="utf-8"))["is_error"]).lower())
PY
)"
  SESSION_ID="$(python3 - "$STATE_DIR/parsed.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["session_id"])
PY
)"
fi

FINAL_STATUS=0
if [[ $CURSOR_STATUS -ne 0 ]]; then
  FINAL_STATUS=$CURSOR_STATUS
elif [[ $POST_COPY_OK -ne 1 ]]; then
  FINAL_STATUS=10
elif [[ $PARSE_OK -ne 1 ]]; then
  FINAL_STATUS=10
elif [[ "$IS_ERROR" == "true" ]]; then
  FINAL_STATUS=10
fi

PATCH_PATH="$STATE_DIR/changes.patch"
FILES_CHANGED=0
if [[ $READ_ONLY -eq 1 ]]; then
  PATCH_DESCRIPTION="<none; read-only mode>"
else
  PATCH_DESCRIPTION="<not generated>"
fi
if [[ $READ_ONLY -eq 0 && $POST_COPY_OK -eq 1 ]]; then
  RAW_PATCH="$STATE_DIR/changes.raw.patch"
  set +e
  (cd "$COPY_ROOT" && git diff --no-index --binary \
    --src-prefix=a/ --dst-prefix=b/ -- pristine work) > "$RAW_PATCH"
  DIFF_STATUS=$?
  set -e
  if [[ $DIFF_STATUS -gt 1 ]]; then
    echo "error: could not compute pristine-vs-work patch" >&2
    [[ $FINAL_STATUS -ne 0 ]] || FINAL_STATUS=11
  else
    python3 - "$RAW_PATCH" "$PATCH_PATH" <<'PY'
import re
import sys
source, destination = sys.argv[1:]
metadata_prefixes = (
    b"diff --git ", b"--- ", b"+++ ", b"Binary files ",
    b"rename from ", b"rename to ", b"copy from ", b"copy to ",
)
with open(source, "rb") as handle:
    lines = handle.readlines()
with open(destination, "wb") as handle:
    for line in lines:
        if line.startswith(metadata_prefixes):
            # Strip exactly one copy-root component from every a/ or b/ path.
            # A project may itself contain a top-level directory named
            # pristine or work; a sequence of replace() calls would strip it.
            line = re.sub(rb"([ab])/(?:pristine|work)/", rb"\1/", line)
        handle.write(line)
PY
    chmod 600 "$PATCH_PATH"
    PATCH_DESCRIPTION="$PATCH_PATH"
    FILES_CHANGED="$(LC_ALL=C grep -c '^diff --git ' "$PATCH_PATH" || true)"
    if [[ $FINAL_STATUS -eq 0 && -s "$PATCH_PATH" ]]; then
      if ! (cd "$WORKSPACE" && git apply --check --binary "$PATCH_PATH") \
        > "$STATE_DIR/apply-check.log" 2>&1; then
        echo "error: captured cursor patch does not apply cleanly; real worktree was not changed" >&2
        FINAL_STATUS=12
      elif ! (cd "$WORKSPACE" && git apply --binary "$PATCH_PATH") \
        > "$STATE_DIR/apply.log" 2>&1; then
        echo "error: captured cursor patch failed during apply after a successful check" >&2
        FINAL_STATUS=13
      fi
    fi
  fi
fi

MODE="$([[ $READ_ONLY -eq 1 ]] && echo read-only || echo implement)"
if [[ -n "$EFFORT" ]]; then
  EFFORT_DESCRIPTION="$EFFORT ($EFFORT_SOURCE assertion in model id)"
else
  EFFORT_DESCRIPTION="$(python3 - "$MODEL" <<'PY'
import re, sys
match = re.search(r"-(low|medium|high|xhigh)(?:-fast)?$", sys.argv[1])
print(match.group(1) if match else "<embedded in model id>")
PY
) (derived from model)"
fi

COPIES_RETAINED="yes"
if [[ $FINAL_STATUS -eq 0 && "${CURSOR_LOOP_KEEP_COPIES:-0}" != "1" ]]; then
  if python3 - "$COPY_ROOT" "$WORK_ROOT" "$DISPATCH_ID" <<'PY'
import os, shutil, sys
target = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])
dispatch_id = sys.argv[3]
expected = os.path.join(root, dispatch_id)
if target != expected or not dispatch_id:
    print(f"error: refusing unsafe cursor-copy cleanup target: {target}", file=sys.stderr)
    raise SystemExit(1)
shutil.rmtree(target)
PY
  then
    COPIES_RETAINED="no (cleaned after successful dispatch)"
  else
    FINAL_STATUS=14
    echo "error: successful dispatch could not safely clean its isolated copies" >&2
  fi
fi

echo "cursor-agent dispatch summary:"
echo "workspace: $WORKSPACE"
echo "cursor-agent version: $CURSOR_VERSION"
echo "model: $MODEL ($MODEL_SOURCE)"
echo "effort: $EFFORT_DESCRIPTION"
echo "mode: $MODE"
echo "is_error: $IS_ERROR"
echo "session id: ${SESSION_ID:-<not reported>}"
echo "resume: no (fresh dispatch only)"
echo "run state: $STATE_DIR"
echo "pristine copy: $PRISTINE"
echo "work copy: $WORK_COPY"
echo "copies retained: $COPIES_RETAINED"
echo "patch: $PATCH_DESCRIPTION"
echo "files changed: $FILES_CHANGED"
echo "enforcement: sandbox-confined to a git-less copy; network denied; NEVER --force/-f/--yolo"
echo "git ownership: orchestrator owns commit, gate, and publish; dispatcher only applies the captured patch"
[[ ! -s "$RESULT_FILE" ]] || cat "$RESULT_FILE"

if [[ $FINAL_STATUS -ne 0 ]]; then
  echo "forensics: copies and run state retained; cursor stderr: $STDERR_LOG" >&2
fi
exit "$FINAL_STATUS"
