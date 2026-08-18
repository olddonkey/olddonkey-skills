#!/usr/bin/env bash
# Dispatch an implementation or investigation task to grok 1.0.4.
#
# Usage:
#   grok-dispatch.sh --prompt-file PATH [--read-only|--investigate]
#                    [--model MODEL] [--effort LEVEL] [--resume]
#   grok-dispatch.sh --prompt "short inline prompt" [...]
#
# Run from the target repository root. Implement mode additionally requires a
# linked worktree whose git dir and common dir resolve outside that root. The
# adapter runs strictly in the foreground; --background is unsupported and
# is deliberately not accepted here. Background this script at the harness
# level when needed.
#
# Model and effort are not invented by the adapter. Explicit flags win, then
# GROK_LOOP_MODEL / GROK_LOOP_EFFORT; otherwise the fresh dispatch home leaves
# the choice to grok's default. Effort is forwarded verbatim as
# --reasoning-effort and is not enum-validated.
#
# Every dispatch uses a fresh GROK_HOME, a fail-closed custom sandbox profile,
# disabled web search, verbatim prompt handling, an empty loaded-MCP graph, and
# a tuple approval from ~/.config/olddonkey-loop/grok-backend.toml. On macOS,
# child network restriction is a no-op, so only a matching per-repo carve-out
# entry can authorize either mode; it never authorizes publication.

set -euo pipefail

ADAPTER_VERSION="1"
SMOKE_SCHEMA="1"
IMPLEMENT_PROFILE="olddonkey-loop-implement"
READONLY_PROFILE="olddonkey-loop-readonly"
MODEL="${GROK_LOOP_MODEL:-}"
EFFORT="${GROK_LOOP_EFFORT:-}"
MODEL_SOURCE="${MODEL:+GROK_LOOP_MODEL}"
EFFORT_SOURCE="${EFFORT:+GROK_LOOP_EFFORT}"
PROMPT_FILE=""
PROMPT=""
READ_ONLY=0
RESUME=0

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
    --resume) RESUME=1; shift ;;
    --read-only|--investigate) READ_ONLY=1; shift ;;
    --background)
      echo "error: --background is unsupported; background this foreground adapter at the harness level" >&2
      exit 2
      ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 2; }

for REQUIRED in git grok pgrep; do
  command -v "$REQUIRED" >/dev/null 2>&1 || {
    echo "error: required command not found: $REQUIRED" >&2
    exit 3
  }
done
TOML_PYTHON=""
for TOML_CANDIDATE in python3 python3.13 python3.12 python3.11; do
  if command -v "$TOML_CANDIDATE" >/dev/null 2>&1 && \
     "$TOML_CANDIDATE" -c 'import tomllib' >/dev/null 2>&1; then
    TOML_PYTHON="$TOML_CANDIDATE"
    break
  fi
done
[[ -n "$TOML_PYTHON" ]] || {
  echo "error: python3 3.11+ with tomllib is required; TOML is never regex-parsed" >&2
  exit 3
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ -n "${LOOP_JOURNAL:-}" ]]; then
  JOURNAL_HELPER="$LOOP_JOURNAL"
else
  JOURNAL_HELPER="$SCRIPT_DIR/../../scripts/loop-journal"
fi
VERIFIER="$SCRIPT_DIR/verify-worktree.sh"
[[ -x "$VERIFIER" ]] || { echo "error: verifier is missing or not executable: $VERIFIER" >&2; exit 3; }

canonical_existing_dir() {
  "$TOML_PYTHON" - "$1" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1])
if not os.path.isdir(path):
    raise SystemExit(1)
print(path)
PY
}

canonical_future_path() {
  "$TOML_PYTHON" - "$1" <<'PY'
import os, sys
path = os.path.abspath(sys.argv[1])
parent = os.path.realpath(os.path.dirname(path))
print(os.path.join(parent, os.path.basename(path)))
PY
}

sha256_text() {
  "$TOML_PYTHON" -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

WORKSPACE="$(canonical_existing_dir "$PWD")" || {
  echo "error: target workspace is not a directory: $PWD" >&2
  exit 3
}
GIT_TOP="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_TOP" ]] || { echo "error: target workspace is not a git repository" >&2; exit 3; }
GIT_TOP="$(canonical_existing_dir "$GIT_TOP")"
[[ "$GIT_TOP" == "$WORKSPACE" ]] || {
  echo "error: run from the target repository root: $GIT_TOP" >&2
  exit 3
}

GROK_VERSION_RAW="$(grok --version 2>&1)" || {
  echo "error: could not determine grok version" >&2
  exit 3
}
GROK_VERSION="$("$TOML_PYTHON" - "$GROK_VERSION_RAW" <<'PY'
import re, sys
match = re.search(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", sys.argv[1])
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
)" || { echo "error: unparseable grok version: $GROK_VERSION_RAW" >&2; exit 3; }
OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
KERNEL="$(uname -r)"

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
PROFILE_HASH="$(printf '%s\n' "$PROFILE_CONTENT" | sha256_text)"
POLICY_HASH="$(printf '%s\n' "$POLICY_CONTENT" | sha256_text)"

DISPATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
HOME_ROOT="$HOME/.config/olddonkey-loop/grok-homes"
FRESH_HOME="$HOME_ROOT/$DISPATCH_ID"
ALLOWLIST="$HOME/.config/olddonkey-loop/grok-backend.toml"

TEMP_ROOTS=()
while IFS= read -r ROOT; do
  [[ -z "$ROOT" ]] || TEMP_ROOTS+=("$ROOT")
done < <("$TOML_PYTHON" - <<'PY'
import os, tempfile
roots = {os.path.realpath(tempfile.gettempdir())}
for value in (os.environ.get("TMPDIR"), "/tmp", "/private/tmp", "/var/tmp"):
    if value and os.path.isdir(value):
        roots.add(os.path.realpath(value))
for root in sorted(roots):
    print(root)
PY
)

# A repository may not shadow either loop-owned custom profile. Parse the
# project file with tomllib even when it contains no matching name: malformed
# TOML is not delegated to grok's startup diagnostics.
PROJECT_SANDBOX="$WORKSPACE/.grok/sandbox.toml"
if [[ -e "$PROJECT_SANDBOX" ]]; then
  "$TOML_PYTHON" - "$PROJECT_SANDBOX" "$IMPLEMENT_PROFILE" "$READONLY_PROFILE" <<'PY'
import os, sys, tomllib
path, *reserved = sys.argv[1:]
if not os.path.isfile(path):
    print(f"error: project sandbox config is not a regular file: {path}", file=sys.stderr)
    raise SystemExit(1)
try:
    with open(path, "rb") as handle:
        data = tomllib.load(handle)
except Exception as exc:
    print(f"error: malformed project sandbox config {path}: {exc}", file=sys.stderr)
    raise SystemExit(1)
profiles = data.get("profiles", {})
if not isinstance(profiles, dict):
    print(f"error: project sandbox profiles table has the wrong type: {path}", file=sys.stderr)
    raise SystemExit(1)
shadowed = sorted(set(reserved).intersection(profiles))
if shadowed:
    print(
        "error: project sandbox config shadows loop-owned profile(s): "
        + ", ".join(shadowed),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
fi

# A completed snapshot remains the same logical repository for a per-repo
# carve-out even though its authoritative absolute worktree path changed.
# Recover that identity only from protected common-dir state whose journal
# reached authoritative-recorded; otherwise the current canonical path wins.
PRE_COMMON_RAW="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
PRE_COMMON_DIR="$("$TOML_PYTHON" - "$WORKSPACE" "$PRE_COMMON_RAW" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
)"
PRE_STATE_ROOT="$PRE_COMMON_DIR/olddonkey-loop/grok"
REPO_KEY="$WORKSPACE"
if [[ -d "$PRE_STATE_ROOT" ]]; then
  REPO_KEY="$("$TOML_PYTHON" - "$PRE_STATE_ROOT" "$WORKSPACE" <<'PY'
import json, os, sys
root, workspace = sys.argv[1:]
workspace = os.path.realpath(workspace)
matches = set()
for name in os.listdir(root):
    state_path = os.path.join(root, name, "state.json")
    journal_path = os.path.join(root, name, "transition.jsonl")
    if not os.path.isfile(state_path) or not os.path.isfile(journal_path):
        continue
    try:
        state = json.load(open(state_path, encoding="utf-8"))
        events = [json.loads(line) for line in open(journal_path, encoding="utf-8") if line.strip()]
    except Exception:
        continue
    if not any(event.get("event") == "authoritative-recorded" for event in events if isinstance(event, dict)):
        continue
    snapshot = state.get("snapshot")
    if not isinstance(snapshot, str) or os.path.realpath(snapshot) != workspace:
        continue
    key = state.get("grant_repo", state.get("workspace"))
    if isinstance(key, str) and os.path.isabs(key):
        matches.add(os.path.realpath(key))
if len(matches) > 1:
    print("error: conflicting protected repo identities for authoritative snapshot", file=sys.stderr)
    raise SystemExit(1)
print(next(iter(matches), workspace))
PY
)" || exit 4
fi

# The allowlist is a trust root. Validate its source, complete schema, entry
# uniqueness, mechanism tuple, and per-repo carve-out before creating a home or
# run state. Ambient variables never grant an unenforced tuple.
ALLOWLIST_RESULT="$("$TOML_PYTHON" - "$ALLOWLIST" "$WORKSPACE" "$REPO_KEY" "$FRESH_HOME" \
  "$OS_NAME" "$ARCH" "$GROK_VERSION" "$KERNEL" "$ADAPTER_VERSION" \
  "$SMOKE_SCHEMA" "$PROFILE_HASH" "$POLICY_HASH" "${TEMP_ROOTS[@]}" <<'PY'
import datetime
import os
import stat
import sys
import tomllib

(
    path, workspace, repo, fresh_home, os_name, arch, grok_version, kernel,
    adapter_version, smoke_schema, profile_hash, policy_hash, *temp_roots
) = sys.argv[1:]


def fail(message):
    print(f"error: grok allowlist refused: {message}", file=sys.stderr)
    raise SystemExit(1)


def real_future(value):
    absolute = os.path.abspath(value)
    return os.path.join(os.path.realpath(os.path.dirname(absolute)), os.path.basename(absolute))


def overlap(left, right):
    try:
        return os.path.commonpath((left, right)) in (left, right)
    except ValueError:
        return False


canonical = os.path.abspath(path)
if os.path.realpath(path) != canonical:
    fail("resolved path differs from the fixed canonical location (symlinked source)")
try:
    info = os.lstat(path)
except OSError:
    fail(f"missing fixed file {path}")
if not stat.S_ISREG(info.st_mode):
    fail("source is not a regular file")
if info.st_uid != os.getuid():
    fail(f"source owner uid {info.st_uid} is not current uid {os.getuid()}")
if stat.S_IMODE(info.st_mode) & 0o022:
    fail("source is group/world-writable")

parent = os.path.dirname(canonical)
cursor = parent
while True:
    if os.path.lexists(os.path.join(cursor, ".git")):
        fail(f"source is reachable from repository {cursor}")
    next_cursor = os.path.dirname(cursor)
    if next_cursor == cursor:
        break
    cursor = next_cursor

workspace = os.path.realpath(workspace)
repo = os.path.realpath(repo)
roots = [workspace, real_future(fresh_home), *(os.path.realpath(root) for root in temp_roots)]
for root in roots:
    if overlap(canonical, root):
        fail(f"source overlaps sandbox-writable or repository root {root}")

try:
    with open(path, "rb") as handle:
        data = tomllib.load(handle)
except Exception as exc:
    fail(f"malformed TOML: {exc}")
if not isinstance(data, dict) or set(data).difference({"enforced", "carve_out"}):
    fail("top-level schema contains unknown keys")

common_keys = {
    "os", "arch", "grok_version", "kernel", "adapter_version",
    "smoke_schema", "profile_hash", "policy_hash",
}
tuple_values = {
    "os": os_name,
    "arch": arch,
    "grok_version": grok_version,
    "kernel": kernel,
    "adapter_version": adapter_version,
    "smoke_schema": smoke_schema,
    "profile_hash": profile_hash,
    "policy_hash": policy_hash,
}
seen_enforced = set()
seen_carve = set()
enforced_entries = []
carve_entries = []
for kind in ("enforced", "carve_out"):
    entries = data.get(kind, [])
    if not isinstance(entries, list):
        fail(f"[[{kind}]] must be an array of tables")
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail(f"{kind}[{index}] is not a table")
        expected_keys = common_keys if kind == "enforced" else common_keys | {"repo", "granted"}
        if set(entry) != expected_keys:
            fail(f"{kind}[{index}] has missing or unknown keys")
        if any(not isinstance(entry[key], str) for key in expected_keys):
            fail(f"{kind}[{index}] values must all be strings")
        mechanism = tuple(entry[key] for key in sorted(common_keys))
        if kind == "enforced":
            if mechanism in seen_enforced:
                fail("duplicate enforced mechanism tuple")
            seen_enforced.add(mechanism)
            enforced_entries.append(entry)
        else:
            if not os.path.isabs(entry["repo"]) or os.path.realpath(entry["repo"]) != entry["repo"]:
                fail(f"carve_out[{index}].repo is not a canonical absolute path")
            try:
                datetime.date.fromisoformat(entry["granted"])
            except ValueError:
                fail(f"carve_out[{index}].granted is not an ISO date")
            key = mechanism + (entry["repo"],)
            if key in seen_carve:
                fail("duplicate carve_out mechanism tuple and repo")
            seen_carve.add(key)
            carve_entries.append(entry)

if seen_enforced.intersection({entry[:-1] for entry in seen_carve}):
    fail("conflicting enforced and carve_out entry types for one mechanism tuple")

matching_enforced = [entry for entry in enforced_entries if all(entry[k] == v for k, v in tuple_values.items())]
matching_carve = [
    entry for entry in carve_entries
    if all(entry[k] == v for k, v in tuple_values.items()) and entry["repo"] == repo
]
if len(matching_enforced) > 1 or len(matching_carve) > 1:
    fail("ambiguous matching entries")
if os_name == "darwin" and matching_enforced:
    fail("darwin child-process network restriction is a no-op; enforced entries are invalid")
if matching_enforced:
    print("enforced|")
elif matching_carve:
    print(f"carve-out|{repo}")
else:
    fail(
        "tuple is unlisted for this repo: "
        f"os={os_name} arch={arch} grok={grok_version} kernel={kernel} "
        f"adapter={adapter_version} smoke={smoke_schema} "
        f"profile={profile_hash} policy={policy_hash}"
    )
PY
)" || exit 4
ALLOWLIST_TYPE="${ALLOWLIST_RESULT%%|*}"
ALLOWLIST_REPO="${ALLOWLIST_RESULT#*|}"

# Resolve git metadata before home preparation so every protected destination
# can be checked against the effective writable roots. rev-parse is host-side;
# after the snapshot copy, no git command runs until marker verification and
# closure validation have both passed.
GIT_DIR_RAW="$(git -C "$WORKSPACE" rev-parse --git-dir)"
COMMON_DIR_RAW="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
GIT_DIR="$("$TOML_PYTHON" - "$WORKSPACE" "$GIT_DIR_RAW" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
)"
COMMON_DIR="$("$TOML_PYTHON" - "$WORKSPACE" "$COMMON_DIR_RAW" <<'PY'
import os, sys
root, value = sys.argv[1:]
print(os.path.realpath(value if os.path.isabs(value) else os.path.join(root, value)))
PY
)"
STATE_ROOT="$COMMON_DIR/olddonkey-loop/grok"
STATE_DIR="$STATE_ROOT/$DISPATCH_ID"
LEDGER="$STATE_ROOT/writable-ledger.tsv"
BASELINE="$STATE_DIR/baseline.json"
SNAPSHOT_PARENT="$(dirname "$WORKSPACE")"
SNAPSHOT="$SNAPSHOT_PARENT/.$(basename "$WORKSPACE").grok-$DISPATCH_ID"
SNAPSHOT_ADMIN="$COMMON_DIR/worktrees/$DISPATCH_ID"
SOURCE_HEAD_OID=""
if [[ $READ_ONLY -eq 0 ]]; then
  SOURCE_HEAD_OID="$(git -C "$WORKSPACE" rev-parse --verify 'HEAD^{commit}')" || {
    echo "error: implement mode requires a committed source HEAD" >&2
    exit 5
  }
fi

# Selftest path layouts only move protected values into a writable root, so
# every variant must refuse. They cannot grant a tuple or relax an overlap.
if [[ -n "${GROK_LOOP_SELFTEST_PATH_LAYOUT:-}" ]]; then
  SELFTEST_ROOT_KIND="${GROK_LOOP_SELFTEST_PATH_LAYOUT%%:*}"
  SELFTEST_PATH_KIND="${GROK_LOOP_SELFTEST_PATH_LAYOUT#*:}"
  case "$SELFTEST_ROOT_KIND" in
    temp) SELFTEST_ROOT="${TEMP_ROOTS[0]}" ;;
    home) SELFTEST_ROOT="$FRESH_HOME" ;;
    *) echo "error: unknown selftest writable-root layout" >&2; exit 5 ;;
  esac
  case "$SELFTEST_PATH_KIND" in
    workspace)
      if [[ "$SELFTEST_ROOT_KIND" == temp ]]; then
        TEMP_ROOTS=("$WORKSPACE")
      else
        FRESH_HOME="$WORKSPACE/.grok-selftest-home"
      fi
      ;;
    git-dir) GIT_DIR="$SELFTEST_ROOT/protected-git-dir" ;;
    common-dir) COMMON_DIR="$SELFTEST_ROOT/protected-common-dir" ;;
    baseline) BASELINE="$SELFTEST_ROOT/protected-baseline.json" ;;
    snapshot) SNAPSHOT="$SELFTEST_ROOT/protected-snapshot" ;;
    *) echo "error: unknown selftest protected-path layout" >&2; exit 5 ;;
  esac
fi

check_overlap_matrix() {
  "$TOML_PYTHON" - "$READ_ONLY" "$WORKSPACE" "$GIT_DIR" "$COMMON_DIR" "$STATE_DIR" \
    "$BASELINE" "$SNAPSHOT" "$FRESH_HOME" "${TEMP_ROOTS[@]}" <<'PY'
import os, sys
read_only = sys.argv[1] == "1"
workspace, git_dir, common_dir, state_dir, baseline, snapshot, fresh_home, *temp_roots = sys.argv[2:]


def future(path):
    absolute = os.path.abspath(path)
    return os.path.join(os.path.realpath(os.path.dirname(absolute)), os.path.basename(absolute))


def overlap(left, right):
    try:
        return os.path.commonpath((left, right)) in (left, right)
    except ValueError:
        return False


workspace = os.path.realpath(workspace)
writable_without_workspace = [future(fresh_home), *(os.path.realpath(x) for x in temp_roots)]
for writable in writable_without_workspace:
    if overlap(workspace, writable):
        print(f"error: workspace overlaps sandbox-writable root: {writable}", file=sys.stderr)
        raise SystemExit(1)
protected = [git_dir, common_dir, state_dir, baseline, snapshot]
writable = writable_without_workspace if read_only else [workspace, *writable_without_workspace]
for item in protected:
    item = future(item)
    for root in writable:
        if overlap(item, root):
            print(f"error: protected path {item} overlaps sandbox-writable root {root}", file=sys.stderr)
            raise SystemExit(1)
PY
}
check_worktree_preconditions() {
if [[ $READ_ONLY -eq 0 ]]; then
  "$TOML_PYTHON" - "$WORKSPACE" "$GIT_DIR" "$COMMON_DIR" <<'PY'
import os, stat, sys
workspace, git_dir, common_dir = map(os.path.realpath, sys.argv[1:])


def inside(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


for label, path in (("git dir", git_dir), ("git common dir", common_dir)):
    if inside(path, workspace):
        print(f"error: implement mode requires linked-worktree {label} outside CWD: {path}", file=sys.stderr)
        raise SystemExit(1)
markers = []
for directory, dirnames, filenames in os.walk(workspace, followlinks=False):
    if ".git" in dirnames:
        print(f"error: in-CWD .git directory is forbidden: {os.path.join(directory, '.git')}", file=sys.stderr)
        raise SystemExit(1)
    if ".git" in filenames:
        marker = os.path.join(directory, ".git")
        info = os.lstat(marker)
        if not stat.S_ISREG(info.st_mode):
            print(f"error: .git marker is not a regular file: {marker}", file=sys.stderr)
            raise SystemExit(1)
        try:
            content = open(marker, encoding="utf-8").read().strip()
        except OSError as exc:
            print(f"error: cannot read .git marker {marker}: {exc}", file=sys.stderr)
            raise SystemExit(1)
        if not content.startswith("gitdir: "):
            print(f"error: malformed .git marker: {marker}", file=sys.stderr)
            raise SystemExit(1)
        target = content[8:]
        resolved = os.path.realpath(target if os.path.isabs(target) else os.path.join(directory, target))
        if inside(resolved, workspace):
            print(f"error: marker resolves to git state inside CWD: {marker} -> {resolved}", file=sys.stderr)
            raise SystemExit(1)
        markers.append(marker)
root_marker = os.path.join(workspace, ".git")
if root_marker not in markers:
    print("error: implement mode requires a linked-worktree .git marker file", file=sys.stderr)
    raise SystemExit(1)
PY
fi
}

# Refuse startup if this repository already has an interrupted transition.
# The journal is append-only; operators either complete the recorded transition
# from runtime.md's procedure or abandon that run explicitly. Never infer a
# half-trusted authoritative path.
check_interrupted_transitions() {
if [[ -d "$STATE_ROOT" ]]; then
  "$TOML_PYTHON" - "$STATE_ROOT" "$WORKSPACE" <<'PY'
import json, os, sys
root, workspace = sys.argv[1:]
workspace = os.path.realpath(workspace)
for name in os.listdir(root):
    state_dir = os.path.join(root, name)
    state_path = os.path.join(state_dir, "state.json")
    journal_path = os.path.join(state_dir, "transition.jsonl")
    if not os.path.isfile(state_path) or not os.path.isfile(journal_path):
        continue
    try:
        state = json.load(open(state_path, encoding="utf-8"))
        events = [json.loads(line) for line in open(journal_path, encoding="utf-8") if line.strip()]
    except Exception:
        print(f"error: unverifiable prior grok transition state: {state_dir}", file=sys.stderr)
        raise SystemExit(1)
    paths = {state.get("workspace"), state.get("snapshot"), state.get("authoritative")}
    paths = {os.path.realpath(path) for path in paths if isinstance(path, str)}
    if workspace not in paths:
        continue
    names = [event.get("event") for event in events if isinstance(event, dict)]
    if "transition-required" in names and "authoritative-recorded" not in names:
        print(f"error: interrupted grok transition must be completed forward or refused: {state_dir}", file=sys.stderr)
        raise SystemExit(1)
PY
fi
}

# The dispatch-home path itself and its parent chain must not be symlinked.
"$TOML_PYTHON" - "$HOME_ROOT" "$FRESH_HOME" <<'PY'
import os, stat, sys
root, home = map(os.path.abspath, sys.argv[1:])
for path in (root,):
    if os.path.lexists(path) and os.path.realpath(path) != path:
        print(f"error: symlinked GROK_HOME root is refused: {path}", file=sys.stderr)
        raise SystemExit(1)
if os.path.lexists(home):
    print(f"error: fresh GROK_HOME already exists: {home}", file=sys.stderr)
    raise SystemExit(1)
PY
mkdir -p "$HOME_ROOT"
chmod 700 "$HOME_ROOT"
mkdir "$FRESH_HOME"
chmod 700 "$FRESH_HOME"

# Selftest-only variants can only make generated controls stricter or invalid;
# they cannot relax a production check or grant a tuple.
PROFILE_TO_WRITE="$PROFILE_CONTENT"
case "${GROK_LOOP_SELFTEST_PROFILE_VARIANT:-}" in
  "") ;;
  absent) PROFILE_TO_WRITE=$'[profiles.unrelated]\nextends = "strict"' ;;
  malformed) PROFILE_TO_WRITE='[profiles.broken' ;;
  wrong-base) PROFILE_TO_WRITE="${PROFILE_CONTENT/workspace/devbox}" ;;
  broadened) PROFILE_TO_WRITE="$PROFILE_CONTENT"$'\nread_write = ["/"]' ;;
  network-override) PROFILE_TO_WRITE="${PROFILE_CONTENT//restrict_network = true/restrict_network = false}" ;;
  unknown-field) PROFILE_TO_WRITE="$PROFILE_CONTENT"$'\nunknown = true' ;;
  *) echo "error: unknown selftest profile variant" >&2; exit 6 ;;
esac
POLICY_TO_WRITE="$POLICY_CONTENT"
case "${GROK_LOOP_SELFTEST_POLICY_VARIANT:-}" in
  "") ;;
  unfiltered) POLICY_TO_WRITE="${POLICY_CONTENT/core/all}" ;;
  *) echo "error: unknown selftest policy variant" >&2; exit 6 ;;
esac
printf '%s\n' "$PROFILE_TO_WRITE" > "$FRESH_HOME/sandbox.toml"
printf '%s\n' "$POLICY_TO_WRITE" > "$FRESH_HOME/config.toml"
chmod 600 "$FRESH_HOME/sandbox.toml" "$FRESH_HOME/config.toml"
if [[ -e "$HOME/.grok/auth.json" ]]; then
  [[ -f "$HOME/.grok/auth.json" && ! -L "$HOME/.grok/auth.json" ]] || {
    echo "error: canonical grok auth.json is not a regular non-symlink file" >&2
    exit 6
  }
  cp "$HOME/.grok/auth.json" "$FRESH_HOME/auth.json"
  chmod 600 "$FRESH_HOME/auth.json"
fi

"$TOML_PYTHON" - "$FRESH_HOME/sandbox.toml" "$FRESH_HOME/config.toml" \
  "$PROFILE_HASH" "$POLICY_HASH" <<'PY'
import hashlib, sys, tomllib
sandbox_path, config_path, expected_profile_hash, expected_policy_hash = sys.argv[1:]


def fail(message):
    print(f"error: generated grok control validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path):
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except Exception as exc:
        fail(f"{path} is malformed: {exc}")


sandbox = load(sandbox_path)
if set(sandbox) != {"profiles"} or not isinstance(sandbox["profiles"], dict):
    fail("sandbox.toml top-level schema is not exactly [profiles]")
profiles = sandbox["profiles"]
expected = {
    "olddonkey-loop-implement": {"extends": "workspace", "restrict_network": True},
    "olddonkey-loop-readonly": {"extends": "read-only", "restrict_network": True},
}
if profiles != expected:
    fail("profile is absent, uses the wrong base, broadens read_write, weakens network, or has unknown fields")

config = load(config_path)
expected_policy = {"inherit": "core", "ignore_default_excludes": False}
compat_cells = {"skills", "rules", "agents", "mcps", "hooks", "sessions"}
if set(config) != {"shell_environment_policy", "compat"}:
    fail("config.toml contains unknown top-level controls")
if config["shell_environment_policy"] != expected_policy:
    fail("shell_environment_policy does not match the calibrated policy")
compat = config.get("compat")
if not isinstance(compat, dict) or set(compat) != {"cursor", "claude", "codex"}:
    fail("compat tables are incomplete")
for family in ("cursor", "claude"):
    if set(compat[family]) != compat_cells or any(value is not False for value in compat[family].values()):
        fail(f"compat.{family} is not fully disabled")
if compat["codex"] != {"sessions": False}:
    fail("compat.codex.sessions is not disabled exactly")

for path, expected_hash in ((sandbox_path, expected_profile_hash), (config_path, expected_policy_hash)):
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != expected_hash:
        fail(f"content hash drifted for {path}")
PY

# Query grok's effective loaded graph from the target cwd and the exact fresh
# home. No warning posture exists: nonzero, command failure, or unknown JSON is
# refusal in both modes.
MCP_JSON=""
if ! MCP_JSON="$(cd "$WORKSPACE" && GROK_HOME="$FRESH_HOME" grok mcp list --json 2>/dev/null)"; then
  echo "error: grok MCP graph is unverifiable (list command failed)" >&2
  exit 7
fi
"$TOML_PYTHON" - "$MCP_JSON" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except (ValueError, TypeError):
    print("error: grok MCP graph is unverifiable (invalid JSON)", file=sys.stderr)
    raise SystemExit(1)
if isinstance(data, list):
    empty = len(data) == 0
elif isinstance(data, dict) and not data:
    empty = True
elif isinstance(data, dict) and len(data) == 1 and next(iter(data)) in {"servers", "mcpServers"}:
    servers = next(iter(data.values()))
    empty = isinstance(servers, (list, dict)) and len(servers) == 0
else:
    empty = False
if not empty:
    print("error: grok MCP graph is nonempty or has an unknown schema", file=sys.stderr)
    raise SystemExit(1)
PY

check_worktree_preconditions || exit 5
check_overlap_matrix || exit 5
check_interrupted_transitions || exit 5

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_ROOT" "$STATE_DIR"

journal() {
  "$TOML_PYTHON" - "$STATE_DIR/transition.jsonl" "$1" <<'PY'
import datetime, json, os, sys
path, event = sys.argv[1:]
record = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "event": event}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
  if [[ "${GROK_LOOP_SELFTEST_INTERRUPT_AFTER:-}" == "$1" ]]; then
    echo "selftest: interrupted after $1" >&2
    exit 86
  fi
}

ledger() {
  "$TOML_PYTHON" - "$LEDGER" "$1" "$DISPATCH_ID" "$2" <<'PY'
import os, stat, sys
path, value, generation, status = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.lexists(path):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
        print(f"error: writable ledger is not a protected regular user-owned file: {path}", file=sys.stderr)
        raise SystemExit(1)
flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    handle.write(f"{os.path.realpath(value)}\t{generation}\t{status}\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
}

write_baseline() {
  "$TOML_PYTHON" - "$1" "$2" <<'PY'
import hashlib, json, os, stat, sys, tempfile
worktree, output = sys.argv[1:]
worktree = os.path.realpath(worktree)
markers = []
for directory, dirnames, filenames in os.walk(worktree, followlinks=False):
    if ".git" in dirnames:
        print(f"error: cannot baseline in-worktree .git directory: {os.path.join(directory, '.git')}", file=sys.stderr)
        raise SystemExit(1)
    if ".git" not in filenames:
        continue
    path = os.path.join(directory, ".git")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode):
        print(f"error: cannot baseline non-file .git marker: {path}", file=sys.stderr)
        raise SystemExit(1)
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    markers.append({
        "path": os.path.relpath(path, worktree), "type": "file",
        "dev": info.st_dev, "inode": info.st_ino, "nlink": info.st_nlink,
        "size": info.st_size, "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns, "sha256": digest.hexdigest(),
    })
markers.sort(key=lambda item: item["path"])
data = {"schema": "1", "status": "active", "worktree": worktree, "markers": markers}
os.makedirs(os.path.dirname(output), exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".baseline-", dir=os.path.dirname(output))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

if [[ $READ_ONLY -eq 0 ]]; then
  write_baseline "$WORKSPACE" "$BASELINE"
  "$VERIFIER" --baseline "$BASELINE" --worktree "$WORKSPACE" >/dev/null
fi

"$TOML_PYTHON" - "$STATE_DIR/state.json" "$DISPATCH_ID" "$WORKSPACE" "$SNAPSHOT" \
  "$BASELINE" "$FRESH_HOME" "$READ_ONLY" "$REPO_KEY" <<'PY'
import json, os, sys, tempfile
path, dispatch_id, workspace, snapshot, baseline, home, read_only, grant_repo = sys.argv[1:]
data = {
    "schema": "1", "dispatch_id": dispatch_id, "workspace": workspace,
    "snapshot": snapshot, "baseline": baseline, "grok_home": home,
    "mode": "read-only" if read_only == "1" else "implement",
    "grant_repo": grant_repo,
}
fd, temporary = tempfile.mkstemp(prefix=".state-", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY

for ROOT in "$FRESH_HOME" "${TEMP_ROOTS[@]}"; do ledger "$ROOT" active; done
[[ $READ_ONLY -eq 1 ]] || ledger "$WORKSPACE" active
journal prepared

RESUME_ID=""
if [[ $RESUME -eq 1 ]]; then
  RESUME_ID="$("$TOML_PYTHON" - "$STATE_ROOT" "$WORKSPACE" <<'PY'
import json, os, sys
root, workspace = sys.argv[1:]
workspace = os.path.realpath(workspace)
candidates = []
for name in os.listdir(root):
    path = os.path.join(root, name, "session.json")
    if not os.path.isfile(path):
        continue
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        continue
    if data.get("workspace") != workspace or not data.get("resume_allowed"):
        continue
    session_id = data.get("session_id")
    if isinstance(session_id, str) and session_id:
        candidates.append((name, session_id))
if not candidates:
    print("error: --resume has no exact-id session whose authoritative path is unchanged", file=sys.stderr)
    raise SystemExit(1)
print(max(candidates)[1])
PY
)" || exit 8
fi

DISPATCH_PROMPT="$FRESH_HOME/prompt.txt"
printf '%s' "$PROMPT" > "$DISPATCH_PROMPT"
chmod 600 "$DISPATCH_PROMPT"
OUTPUT_JSON="$STATE_DIR/output.json"
PGID_FILE="$STATE_DIR/pgid"
ARGS=(grok --sandbox "$([[ $READ_ONLY -eq 1 ]] && echo "$READONLY_PROFILE" || echo "$IMPLEMENT_PROFILE")")
ARGS+=(--permission-mode bypassPermissions --disable-web-search --verbatim \
  --prompt-file "$DISPATCH_PROMPT" --output-format json)
[[ -n "$MODEL" ]] && ARGS+=(-m "$MODEL")
[[ -n "$EFFORT" ]] && ARGS+=(--reasoning-effort "$EFFORT")
[[ -z "$RESUME_ID" ]] || ARGS+=(--resume "$RESUME_ID")

LOOP_JOURNAL_END_DONE=0
LOOP_JOURNAL_STARTED=0
journal_helper_ok() {
  [[ -n "${JOURNAL_HELPER:-}" && -f "$JOURNAL_HELPER" && -x "$JOURNAL_HELPER" ]]
}

journal_dispatch_start() {
  journal_helper_ok || return 0
  local loop_home mode
  # mkdir -p of grok-homes can create this directory at 0755; loop-journal
  # requires 0700 and treats a mismatch as a failed dispatch.start.
  loop_home="${HOME:?}/.config/olddonkey-loop"
  mkdir -p "$loop_home" || return $?
  chmod 700 "$loop_home" || return $?
  mode="$([[ $READ_ONLY -eq 1 ]] && echo read-only || echo implement)"
  "$JOURNAL_HELPER" append --workspace "$WORKSPACE" --event dispatch.start \
    --field "dispatch_id=$DISPATCH_ID" --field backend=grok --field "mode=$mode"
}

journal_dispatch_end() { # $1=exit [ $2=session ]
  local exit_code="$1" session="${2:-}"
  [[ "$LOOP_JOURNAL_STARTED" -eq 1 ]] || return 0
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

cleanup_recorded_group() {
  [[ -s "$PGID_FILE" ]] || return 0
  local cleanup_pgid
  cleanup_pgid="$(tr -d '[:space:]' < "$PGID_FILE")"
  [[ "$cleanup_pgid" =~ ^[0-9]+$ ]] || return 0
  "$TOML_PYTHON" - "$cleanup_pgid" <<'PY'
import os, signal, sys, time
pgid = int(sys.argv[1])
try:
    os.killpg(pgid, signal.SIGTERM)
except ProcessLookupError:
    raise SystemExit(0)
for _ in range(10):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    time.sleep(0.05)
try:
    os.killpg(pgid, signal.SIGKILL)
except ProcessLookupError:
    pass
PY
}
trap cleanup_recorded_group EXIT
trap 'cleanup_recorded_group; exit 130' INT
trap 'cleanup_recorded_group; exit 143' TERM

journal_dispatch_start || {
  start_rc=$?
  echo "error: loop-journal dispatch.start failed; refusing to launch" >&2
  exit "$start_rc"
}
LOOP_JOURNAL_STARTED=1
trap 'rc=$?; cleanup_recorded_group; journal_dispatch_end "$rc" "${SESSION_ID:-}"' EXIT
trap 'cleanup_recorded_group; journal_dispatch_end 130; exit 130' INT
trap 'cleanup_recorded_group; journal_dispatch_end 143; exit 143' TERM

journal transition-required
set +e
(cd "$WORKSPACE" && GROK_HOME="$FRESH_HOME" "$TOML_PYTHON" - "$PGID_FILE" "$OUTPUT_JSON" "${ARGS[@]}" <<'PY'
import os, subprocess, sys
pgid_path, output_path, *command = sys.argv[1:]
with open(output_path, "wb", buffering=0) as output:
    process = subprocess.Popen(command, stdout=output, preexec_fn=os.setsid)
    pgid = os.getpgid(process.pid)
    with open(pgid_path, "w", encoding="ascii") as handle:
        handle.write(f"{pgid}\n")
        handle.flush()
        os.fsync(handle.fileno())
    raise SystemExit(process.wait())
PY
)
GROK_STATUS=$?
set -e
journal grok-exited

[[ -s "$PGID_FILE" ]] || { echo "error: grok launch did not record a process group" >&2; journal_dispatch_end 9; exit 9; }
PGID="$(tr -d '[:space:]' < "$PGID_FILE")"
[[ "$PGID" =~ ^[0-9]+$ ]] || { echo "error: invalid recorded grok process group" >&2; journal_dispatch_end 9; exit 9; }
"$TOML_PYTHON" - "$PGID" <<'PY'
import errno, os, signal, sys, time
pgid = int(sys.argv[1])
try:
    os.killpg(pgid, signal.SIGTERM)
except ProcessLookupError:
    pass
for _ in range(20):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.05)
else:
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
PY
if pgrep -g "$PGID" >/dev/null 2>&1; then
  echo "error: grok process group still has members after termination: $PGID" >&2
  journal_dispatch_end 9
  exit 9
fi
trap - EXIT INT TERM
trap 'rc=$?; journal_dispatch_end "$rc" "${SESSION_ID:-}"' EXIT
for ROOT in "$FRESH_HOME" "${TEMP_ROOTS[@]}"; do ledger "$ROOT" terminated; done
[[ $READ_ONLY -eq 1 ]] || ledger "$WORKSPACE" terminated
journal group-killed

SESSION_ID=""
OUTPUT_TEXT=""
if [[ -s "$OUTPUT_JSON" ]]; then
  PARSED_OUTPUT="$("$TOML_PYTHON" - "$OUTPUT_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
session = data.get("sessionId", "")
text = data.get("text", "")
if not isinstance(session, str) or not isinstance(text, str):
    raise SystemExit(1)
print(session)
print(text, end="")
PY
)" || {
    [[ $GROK_STATUS -ne 0 ]] || GROK_STATUS=10
    echo "error: grok output was not the calibrated JSON object" >&2
    PARSED_OUTPUT=""
  }
  SESSION_ID="${PARSED_OUTPUT%%$'\n'*}"
  if [[ "$PARSED_OUTPUT" == *$'\n'* ]]; then OUTPUT_TEXT="${PARSED_OUTPUT#*$'\n'}"; fi
fi

AUTHORITATIVE="$WORKSPACE"
if [[ $READ_ONLY -eq 0 ]]; then
  [[ ! -e "$SNAPSHOT" ]] || { echo "error: snapshot destination already exists: $SNAPSHOT" >&2; journal_dispatch_end 11; exit 11; }
  if cp -cR "$WORKSPACE" "$SNAPSHOT" 2>/dev/null; then
    :
  else
    cp -R "$WORKSPACE" "$SNAPSHOT"
  fi
  journal copied

  SNAPSHOT_BASELINE="$STATE_DIR/snapshot-baseline.json"
  "$TOML_PYTHON" - "$BASELINE" "$SNAPSHOT" "$SNAPSHOT_BASELINE" <<'PY'
import hashlib, json, os, stat, sys, tempfile
old_path, snapshot, output = sys.argv[1:]
old = json.load(open(old_path, encoding="utf-8"))
old_by_path = {entry["path"]: entry for entry in old["markers"]}
markers = []
for directory, dirnames, filenames in os.walk(snapshot, followlinks=False):
    if ".git" in dirnames:
        print(f"error: snapshot contains .git directory: {os.path.join(directory, '.git')}", file=sys.stderr)
        raise SystemExit(1)
    if ".git" not in filenames:
        continue
    path = os.path.join(directory, ".git")
    relative = os.path.relpath(path, snapshot)
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode):
        print(f"error: snapshot marker is not a regular file: {relative}", file=sys.stderr)
        raise SystemExit(1)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    source = old_by_path.get(relative)
    if source is None or source["sha256"] != digest or source["size"] != info.st_size:
        print(f"error: snapshot marker differs from pre-dispatch baseline: {relative}", file=sys.stderr)
        raise SystemExit(1)
    if source["dev"] == info.st_dev and source["inode"] == info.st_ino:
        print(f"error: snapshot marker did not receive a fresh inode: {relative}", file=sys.stderr)
        raise SystemExit(1)
    markers.append({
        "path": relative, "type": "file", "dev": info.st_dev, "inode": info.st_ino,
        "nlink": info.st_nlink, "size": info.st_size, "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns, "sha256": digest,
    })
if sorted(old_by_path) != sorted(entry["path"] for entry in markers):
    print("error: snapshot marker path set differs from pre-dispatch baseline", file=sys.stderr)
    raise SystemExit(1)
data = {"schema": "1", "status": "active", "worktree": os.path.realpath(snapshot), "markers": sorted(markers, key=lambda x: x["path"])}
fd, temporary = tempfile.mkstemp(prefix=".snapshot-baseline-", dir=os.path.dirname(output))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, output)
PY
  "$VERIFIER" --baseline "$SNAPSHOT_BASELINE" --worktree "$SNAPSHOT" >/dev/null
  journal markers-verified

  "$TOML_PYTHON" - "$SNAPSHOT" "$LEDGER" <<'PY'
import os, stat, sys
snapshot, ledger = map(os.path.realpath, sys.argv[1:])
ledgered = []
if os.path.isfile(ledger):
    for line in open(ledger, encoding="utf-8"):
        value = line.rstrip("\n").split("\t", 1)[0]
        if value:
            ledgered.append(os.path.realpath(value))


def inside(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


hardlinks = {}
for directory, dirnames, filenames in os.walk(snapshot, followlinks=False):
    for name in [*dirnames, *filenames]:
        path = os.path.join(directory, name)
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            target = os.path.realpath(path)
            for root in ledgered:
                if inside(target, root):
                    print(f"error: snapshot symlink resolves into historical writable root: {path} -> {target}", file=sys.stderr)
                    raise SystemExit(1)
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink > 1:
                hardlinks.setdefault((info.st_dev, info.st_ino), []).append(path)
        elif not stat.S_ISDIR(info.st_mode):
            print(f"error: unsafe special file in snapshot: {path}", file=sys.stderr)
            raise SystemExit(1)
for paths in hardlinks.values():
    info = os.lstat(paths[0])
    if len(paths) != info.st_nlink:
        print(f"error: snapshot hard link escapes closure: {paths[0]}", file=sys.stderr)
        raise SystemExit(1)
PY
  journal closure-validated

  # A copied linked worktree is not a moved worktree. Give the snapshot its own
  # admin directory; never point the source admin directory at two markers.
  [[ -d "$GIT_DIR" && ! -L "$GIT_DIR" ]] || {
    echo "error: source worktree admin directory is not a real directory: $GIT_DIR" >&2
    journal_dispatch_end 11
    exit 11
  }
  [[ -d "$COMMON_DIR/worktrees" && ! -L "$COMMON_DIR/worktrees" ]] || {
    echo "error: git common worktrees directory is not a real directory" >&2
    journal_dispatch_end 11
    exit 11
  }
  [[ ! -e "$SNAPSHOT_ADMIN" && ! -L "$SNAPSHOT_ADMIN" ]] || {
    echo "error: fresh snapshot admin directory already exists: $SNAPSHOT_ADMIN" >&2
    journal_dispatch_end 11
    exit 11
  }
  SOURCE_HEAD_CONTENT="$(cat "$GIT_DIR/HEAD")"
  mkdir -m 700 "$SNAPSHOT_ADMIN"
  cp -R "$GIT_DIR/." "$SNAPSHOT_ADMIN/"

  printf '%s\n' "$SNAPSHOT/.git" > "$SNAPSHOT_ADMIN/.gitdir.tmp"
  chmod 600 "$SNAPSHOT_ADMIN/.gitdir.tmp"
  mv "$SNAPSHOT_ADMIN/.gitdir.tmp" "$SNAPSHOT_ADMIN/gitdir"
  printf '../..\n' > "$SNAPSHOT_ADMIN/.commondir.tmp"
  chmod 600 "$SNAPSHOT_ADMIN/.commondir.tmp"
  mv "$SNAPSHOT_ADMIN/.commondir.tmp" "$SNAPSHOT_ADMIN/commondir"
  printf 'gitdir: %s\n' "$SNAPSHOT_ADMIN" > "$SNAPSHOT/.git.tmp"
  chmod 600 "$SNAPSHOT/.git.tmp"
  mv "$SNAPSHOT/.git.tmp" "$SNAPSHOT/.git"

  # Transfer the checked-out branch to the authoritative snapshot without
  # sharing it: the retired source keeps its registration but becomes detached
  # at the exact commit from which the snapshot registration was copied.
  if [[ "$SOURCE_HEAD_CONTENT" == "ref: "* ]]; then
    printf '%s\n' "$SOURCE_HEAD_OID" > "$GIT_DIR/.HEAD.grok-$DISPATCH_ID.tmp"
    chmod 600 "$GIT_DIR/.HEAD.grok-$DISPATCH_ID.tmp"
    mv "$GIT_DIR/.HEAD.grok-$DISPATCH_ID.tmp" "$GIT_DIR/HEAD"
  fi
  journal independent-registration

  git -C "$SNAPSHOT" worktree repair
  git -C "$SNAPSHOT" status --porcelain=v1 >/dev/null
  git -C "$WORKSPACE" status --porcelain=v1 >/dev/null
  SNAPSHOT_ADMIN_ACTUAL="$(git -C "$SNAPSHOT" rev-parse --absolute-git-dir)"
  SOURCE_ADMIN_ACTUAL="$(git -C "$WORKSPACE" rev-parse --absolute-git-dir)"
  [[ "$SNAPSHOT_ADMIN_ACTUAL" == "$SNAPSHOT_ADMIN" ]] || {
    echo "error: snapshot resolved the wrong worktree admin directory: $SNAPSHOT_ADMIN_ACTUAL" >&2
    journal_dispatch_end 11
    exit 11
  }
  [[ "$SOURCE_ADMIN_ACTUAL" == "$GIT_DIR" && "$SOURCE_ADMIN_ACTUAL" != "$SNAPSHOT_ADMIN_ACTUAL" ]] || {
    echo "error: source and snapshot do not have independent worktree registrations" >&2
    journal_dispatch_end 11
    exit 11
  }
  journal worktree-repaired
  write_baseline "$SNAPSHOT" "$STATE_DIR/authoritative-baseline.json"
  "$VERIFIER" --baseline "$STATE_DIR/authoritative-baseline.json" --worktree "$SNAPSHOT" >/dev/null
  journal fresh-baseline
  AUTHORITATIVE="$(canonical_existing_dir "$SNAPSHOT")"
  printf '%s\n' "$AUTHORITATIVE" > "$STATE_DIR/.authoritative-path.tmp"
  mv "$STATE_DIR/.authoritative-path.tmp" "$STATE_DIR/authoritative-path"
  ledger "$AUTHORITATIVE" authoritative
fi

"$TOML_PYTHON" - "$STATE_DIR/session.json" "$WORKSPACE" "$AUTHORITATIVE" "$SESSION_ID" \
  "$READ_ONLY" "$DISPATCH_ID" <<'PY'
import json, os, sys, tempfile
path, workspace, authoritative, session_id, read_only, dispatch_id = sys.argv[1:]
data = {
    "schema": "1", "dispatch_id": dispatch_id, "workspace": authoritative,
    "dispatched_from": workspace, "authoritative": authoritative,
    "session_id": session_id, "resume_allowed": read_only == "1" and workspace == authoritative,
    "transition_after_session": read_only != "1",
}
fd, temporary = tempfile.mkstemp(prefix=".session-", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
journal authoritative-recorded

PROFILE="$([[ $READ_ONLY -eq 1 ]] && echo "$READONLY_PROFILE" || echo "$IMPLEMENT_PROFILE")"
MODE="$([[ $READ_ONLY -eq 1 ]] && echo read-only || echo implement)"
MODEL_DESCRIPTION="${MODEL:-<grok default in fresh home>} (${MODEL_SOURCE:-not overridden})"
EFFORT_DESCRIPTION="${EFFORT:-<grok default in fresh home>} (${EFFORT_SOURCE:-not overridden})"
echo "grok dispatch summary:"
echo "workspace: $WORKSPACE"
echo "grok version: $GROK_VERSION"
echo "model: $MODEL_DESCRIPTION"
echo "effort: $EFFORT_DESCRIPTION"
echo "mode: $MODE"
echo "profile: $PROFILE (sha256:$PROFILE_HASH)"
echo "tuple: ($OS_NAME, $ARCH, grok $GROK_VERSION, kernel $KERNEL; adapter $ADAPTER_VERSION, smoke $SMOKE_SCHEMA)"
if [[ "$ALLOWLIST_TYPE" == "carve-out" ]]; then
  echo "allowlist: carve-out (repo: $ALLOWLIST_REPO)"
else
  echo "allowlist: enforced"
fi
echo "fresh home: $FRESH_HOME"
echo "resume: $([[ -n "$RESUME_ID" ]] && echo "exact $RESUME_ID" || echo no)"
echo "session id: ${SESSION_ID:-<not reported>}"
echo "authoritative path: $AUTHORITATIVE"
if [[ "$ALLOWLIST_TYPE" == "carve-out" ]]; then
  echo "carve-out: child-process network blocking is not enforced on this tuple; publication remains prohibited"
fi
[[ -z "$OUTPUT_TEXT" ]] || printf '%s\n' "$OUTPUT_TEXT"
journal_dispatch_end "$GROK_STATUS" "${SESSION_ID:-}"
exit "$GROK_STATUS"
