#!/usr/bin/env bash
# Dispatch an implementation or investigation task through plain `codex exec`.
#
# Usage:
#   codex-dispatch.sh --prompt-file PATH [--read-only|--investigate]
#                     [--model MODEL] [--effort LEVEL]
#                     [--resume [SESSION_ID]|--resume-unmanaged SESSION_ID]
#   codex-dispatch.sh --prompt "short inline prompt" [...]
#
# Run from the ROOT of the target repository. Fresh turns pin the workspace
# with `-C`; resumed turns cannot accept `-C`, so the adapter changes directory
# before launching them. Every path pins sandbox, approval, nested writable
# roots, network, and permissions instead of inheriting those controls.
#
# `--read-only` and `--investigate` select Codex's read-only sandbox. The
# default is workspace-write. The adapter itself never stages or commits.
#
# Resume is exact-id only and never falls back to `--last`. Managed resume is
# release-disabled until the real `integration-test.sh --require codex` matrix
# passes. `--resume-unmanaged ID` is the explicit migration path for a legacy
# app-server session; a successful turn adopts the id into loop-owned state.
#
# This adapter is strictly foreground. `--background` is rejected; background
# the adapter at the harness level, where its exit remains authoritative.
#
# Model and effort have no adapter defaults. Explicit effort is forwarded as a
# quoted TOML `model_reasoning_effort` override, including `ultra` and `max`.
# Omitted values are left to the Codex CLI's normal config resolution.

set -euo pipefail
umask 077

MODEL="${CODEX_LOOP_MODEL:-}"
EFFORT="${CODEX_LOOP_EFFORT:-}"
PROMPT_FILE=""
PROMPT=""
ACTION="fresh"
RESUME_ID=""
READ_ONLY=0
ADAPTER_VERSION="2"

# This is intentionally a source constant, not an environment toggle. Flip it
# only in the release change that records a full `--require codex` pass.
RESUME_RELEASE_ENABLED=0

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit "${1:-0}"
}

refuse_policy_broadener() {
  echo "error: Codex policy-broadening flags are forbidden; sandbox and approval controls are fixed by this adapter" >&2
  exit 2
}

is_policy_broadener() { # $1=value; exact flags and assignment forms
  case "$1" in
    --dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust|\
    --add-dir|--add-dir=*|--approve-for-me|--approve-for-me=*|\
    -p|--profile|--profile=*|--ignore-user-config|--ignore-rules|\
    --enable|--enable=*|--disable|--disable=*) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:?--prompt-file needs a path}"; shift 2 ;;
    --prompt) PROMPT="${2:?--prompt needs text}"; shift 2 ;;
    --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
    --effort) EFFORT="${2:?--effort needs a value}"; shift 2 ;;
    --resume)
      ACTION="resume"
      if [[ $# -gt 1 && "$2" != -* ]]; then
        RESUME_ID="$2"
        shift 2
      else
        shift
      fi
      ;;
    --resume=*) ACTION="resume"; RESUME_ID="${1#--resume=}"; shift ;;
    --resume-unmanaged)
      ACTION="resume-unmanaged"
      RESUME_ID="${2:?--resume-unmanaged needs a session id}"
      shift 2
      ;;
    --read-only|--investigate) READ_ONLY=1; shift ;;
    --background)
      echo "error: --background is unsupported; background this foreground adapter at the harness level" >&2
      exit 2
      ;;
    --dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust|\
    --add-dir|--add-dir=*|--approve-for-me|--approve-for-me=*|\
    -p|--profile|--profile=*|--ignore-user-config|--ignore-rules|\
    --enable|--enable=*|--disable|--disable=*) refuse_policy_broadener ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

if [[ -n "${CODEX_LOOP_EXTRA_ARGS:-}" ]]; then
  echo "error: CODEX_LOOP_EXTRA_ARGS is unsupported; Codex control flags are fixed by the adapter" >&2
  exit 2
fi

# Second guard: a would-be flag cannot be smuggled through a value-bearing
# adapter option. The final constructed argv receives an independent guard in
# the supervising module below.
is_policy_broadener "$MODEL" && refuse_policy_broadener
is_policy_broadener "$EFFORT" && refuse_policy_broadener

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 2; }

for REQUIRED in codex python3; do
  command -v "$REQUIRED" >/dev/null 2>&1 || {
    echo "error: required command not found: $REQUIRED" >&2
    exit 3
  }
done

if [[ "$ACTION" != "fresh" && $RESUME_RELEASE_ENABLED -ne 1 ]]; then
  echo "error: Codex resume is release-disabled until integration-test.sh --require codex passes without non-managed skips" >&2
  echo "iterate with a fresh dispatch and put the prior session context in the new prompt" >&2
  exit 2
fi

WORKSPACE="$(pwd -P)"
SANDBOX_MODE="workspace-write"
MODE_LABEL="implement"
if [[ $READ_ONLY -eq 1 ]]; then
  SANDBOX_MODE="read-only"
  MODE_LABEL="READ-ONLY (no file writes; nothing to review/gate/publish)"
fi

CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
PROJECT_CONFIG="$WORKSPACE/.codex/config.toml"

# The disclosure scan requires a real TOML parser. A missing parser warns by
# default and refuses only under the pre-existing block mode.
TOML_PYTHON=""
for TOML_CANDIDATE in python3 python3.13 python3.12 python3.11; do
  if command -v "$TOML_CANDIDATE" >/dev/null 2>&1 && \
     "$TOML_CANDIDATE" -c 'import tomllib' 2>/dev/null; then
    TOML_PYTHON="$TOML_CANDIDATE"
    break
  fi
done

# MCP servers, Apps, notify hooks, and plugins run in the host agent process,
# outside both Codex shell sandboxes. This is disclosure, not containment.
scan_config_tools() { # $1=config path; prints identities; rc 3 = cannot verify
  [[ -f "$1" ]] || return 0
  [[ -n "$TOML_PYTHON" ]] || return 3
  local scanned=""
  if ! scanned="$("$TOML_PYTHON" -c '
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        data = tomllib.load(handle)
except Exception:
    print("(unparseable Codex config - treated as exposure)")
    raise SystemExit(0)

for family in ("mcp_servers", "apps", "plugins"):
    table = data.get(family)
    if not isinstance(table, dict):
        continue
    for name, entry in table.items():
        if isinstance(entry, dict) and entry.get("enabled") is False:
            continue
        print(f"[{family}.{name}]")

notify = data.get("notify")
if notify not in (None, False, "", [], {}):
    print("[notify]")
' "$1" 2>/dev/null)"; then
    return 3
  fi
  [[ -z "$scanned" ]] || printf '%s\n' "$scanned"
  return 0
}

EXTERNAL_TOOLS=""
TOOL_SCAN_FAILED=0
NEWLINE=$'\n'
for TOOL_CONFIG in "$CONFIG" "$PROJECT_CONFIG"; do
  if TOOL_SCAN_OUTPUT="$(scan_config_tools "$TOOL_CONFIG")"; then
    [[ -z "$TOOL_SCAN_OUTPUT" ]] || \
      EXTERNAL_TOOLS="${EXTERNAL_TOOLS}${EXTERNAL_TOOLS:+$NEWLINE}$TOOL_SCAN_OUTPUT"
  else
    TOOL_SCAN_FAILED=1
  fi
done
BLOCK_EXTERNAL_TOOLS="${CODEX_LOOP_BLOCK_EXTERNAL_TOOLS:-0}"
if [[ $TOOL_SCAN_FAILED -eq 1 ]]; then
  if [[ "$BLOCK_EXTERNAL_TOOLS" == "1" ]]; then
    echo "error: dispatch blocked (CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1) — cannot verify the Codex config." >&2
    echo "The scan needs python3 with tomllib (3.11+); regex scanning of TOML is unsound." >&2
    exit 4
  fi
  echo "warn  : Codex config not verified (needs python3 with tomllib) — external tools unchecked" >&2
fi
if [[ -n "$EXTERNAL_TOOLS" ]]; then
  EXTERNAL_TOOL_LIST="$(printf '%s\n' "$EXTERNAL_TOOLS" \
    | LC_ALL=C tr -d '[]' | LC_ALL=C paste -sd, - | LC_ALL=C sed 's/,/, /g')"
  if [[ "$BLOCK_EXTERNAL_TOOLS" == "1" ]]; then
    echo "error: dispatch blocked (CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1) — Codex config enables external tools:" >&2
    echo "        $EXTERNAL_TOOL_LIST" >&2
    echo "Disable them in the Codex config, or unset the variable to dispatch with a warning." >&2
    exit 4
  fi
  echo "warn  : external tools outside the sandbox: $EXTERNAL_TOOL_LIST" >&2
  echo "        (prompt says not to use them; set CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1 to refuse instead)" >&2
fi

top_level_value() { # $1=config path $2=key
  [[ -f "$1" ]] || return 0
  LC_ALL=C awk -v key="$2" '
    /^[[:space:]]*\[/ { exit }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/["[:space:]]/, "")
      print
      exit
    }
  ' "$1" 2>/dev/null || true
}

describe() { # $1=label $2=chosen value $3=config key
  local project_value="" global_value=""
  if [[ -n "$2" ]]; then
    echo "$1: $2 (explicit)"
    return
  fi
  project_value="$(top_level_value "$PROJECT_CONFIG" "$3")"
  global_value="$(top_level_value "$CONFIG" "$3")"
  if [[ -n "$project_value" ]]; then
    echo "$1: $project_value (project .codex/config.toml top-level; other config layers not resolved)"
  elif [[ -n "$global_value" ]]; then
    echo "$1: $global_value (config.toml top-level; other config layers not resolved)"
  else
    echo "$1: <Codex CLI default>"
  fi
}

CODEX_BIN="$(command -v codex)"
CODEX_VERSION="$("$CODEX_BIN" --version 2>/dev/null || echo '?')"
STATE_ROOT="$HOME/.config/olddonkey-loop/codex"

echo "codex exec dispatch summary:" >&2
echo "workspace: $WORKSPACE" >&2
echo "codex version: $CODEX_VERSION" >&2
echo "adapter version: $ADAPTER_VERSION" >&2
describe "model" "$MODEL" "model" >&2
describe "effort" "$EFFORT" "model_reasoning_effort" >&2
describe "tier" "" "service_tier" >&2
echo "mode: $MODE_LABEL" >&2
echo "sandbox (requested): $SANDBOX_MODE" >&2
case "$ACTION" in
  fresh) echo "resume: no (fresh dispatch)" >&2 ;;
  resume) echo "resume: managed exact id${RESUME_ID:+ $RESUME_ID}" >&2 ;;
  resume-unmanaged) echo "resume: unmanaged exact id $RESUME_ID (migration/adoption)" >&2 ;;
esac

# The Python supervisor is the state-directory module. It owns secure
# bootstrap, the non-blocking descriptor lock, authoritative record scans,
# the single parameterized argv builder, process-group lifecycle, transcript
# capture, banner verification, and atomic state transitions.
exec python3 - \
  "$STATE_ROOT" "$WORKSPACE" "$SANDBOX_MODE" "$ACTION" "$RESUME_ID" \
  "$CODEX_BIN" "$MODEL" "$EFFORT" "$PROMPT" <<'PY'
import datetime
import fcntl
import hashlib
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

(
    state_root,
    workspace,
    sandbox_mode,
    action,
    requested_session,
    codex_bin,
    model,
    effort,
    prompt,
) = sys.argv[1:]

OWNER = os.getuid()
FORBIDDEN = {
    "--dangerously-bypass-approvals-and-sandbox",
    "--dangerously-bypass-hook-trust",
    "--add-dir",
    "--approve-for-me",
    "-p",
    "--profile",
    "--ignore-user-config",
    "--ignore-rules",
    "--enable",
    "--disable",
}
DISPATCH_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
SESSION_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
META_KEYS = (
    "schema",
    "state",
    "generation",
    "session_id",
    "workspace",
    "created",
    "updated",
)
VALID_STATES = {"initializing", "running", "ready", "failed"}


class StateError(Exception):
    pass


def refuse(message, code=5):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def no_symlink_components(path):
    absolute = os.path.abspath(path)
    current = os.path.sep
    for part in [value for value in absolute.split(os.path.sep) if value]:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise StateError(f"state path contains a symlink: {current}")


def validate_directory(path, mode=0o700):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise StateError(f"state directory is not a real directory: {path}")
    if info.st_uid != OWNER:
        raise StateError(f"state directory is foreign-owned: {path}")
    if stat.S_IMODE(info.st_mode) != mode:
        raise StateError(f"state directory mode must be {mode:04o}: {path}")


def ensure_directory(path):
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    validate_directory(path)


def validate_regular(path, *, meta=False, allow_empty=True):
    try:
        info = os.lstat(path)
    except FileNotFoundError as error:
        raise StateError(f"state file is not a regular file: {path}") from error
    expected_owner = OWNER
    # Behavioral foreign-owner negative control without requiring root/chown.
    if meta and os.environ.get("CODEX_LOOP_SELFTEST_FOREIGN_META") == "1":
        expected_owner = OWNER + 1
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise StateError(f"state file is not a regular file: {path}")
    if info.st_uid != expected_owner:
        raise StateError(f"state file is foreign-owned: {path}")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise StateError(f"state file mode must be 0600: {path}")
    if info.st_nlink != 1:
        raise StateError(f"state file has multiple hard links: {path}")
    if not allow_empty and info.st_size == 0:
        raise StateError(f"state file is empty: {path}")


def atomic_write(path, content):
    directory = os.path.dirname(path)
    temporary = os.path.join(directory, f".tmp-{os.getpid()}-{secrets.token_hex(4)}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    validate_regular(path)


def create_regular(path, content=b""):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        if content:
            os.write(descriptor, content)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    validate_regular(path)


def contained(left, right):
    try:
        return os.path.commonpath([left, right]) == left
    except ValueError:
        return False


def verify_containment():
    canonical_state = os.path.realpath(state_root)
    roots = [workspace, "/tmp"]
    tmpdir = os.environ.get("TMPDIR")
    if tmpdir:
        roots.append(tmpdir)
    seen = set()
    for root in roots:
        canonical_root = os.path.realpath(root)
        if canonical_root in seen:
            continue
        seen.add(canonical_root)
        if contained(canonical_root, canonical_state) or contained(canonical_state, canonical_root):
            raise StateError(
                "state root overlaps a sandbox writable root: "
                f"state={canonical_state} writable={canonical_root}"
            )


def meta_text(record):
    for key in META_KEYS:
        value = str(record[key])
        if "\t" in value or "\n" in value or "\r" in value:
            raise StateError(f"state value for {key} is not TSV-safe")
    return "".join(f"{key}\t{record[key]}\n" for key in META_KEYS)


def write_meta(record):
    record["updated"] = utc_now()
    atomic_write(os.path.join(record["directory"], "meta.tsv"), meta_text(record))


def read_meta(directory):
    path = os.path.join(directory, "meta.tsv")
    validate_regular(path, meta=True, allow_empty=False)
    values = {}
    with open(path, encoding="utf-8", newline="") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.endswith("\r") or line.count("\t") != 1:
                raise StateError(f"malformed state record: {path}")
            key, value = line.split("\t", 1)
            if key in values:
                raise StateError(f"duplicate state key {key}: {path}")
            values[key] = value
    if tuple(values) != META_KEYS:
        raise StateError(f"state record has the wrong schema keys: {path}")
    if values["schema"] != "1" or values["state"] not in VALID_STATES:
        raise StateError(f"state record has invalid schema or lifecycle: {path}")
    try:
        generation = int(values["generation"])
    except ValueError as error:
        raise StateError(f"state record has invalid generation: {path}") from error
    if generation < 1 or values["workspace"] != workspace:
        raise StateError(f"state record has invalid generation or workspace: {path}")
    if values["session_id"] and not SESSION_RE.fullmatch(values["session_id"]):
        raise StateError(f"state record has invalid session id: {path}")
    if values["state"] == "ready" and not values["session_id"]:
        raise StateError(f"ready state record has no session id: {path}")
    for timestamp_key in ("created", "updated"):
        if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", values[timestamp_key]):
            raise StateError(f"state record has invalid {timestamp_key}: {path}")
    values["generation"] = generation
    values["directory"] = directory
    values["dispatch_id"] = os.path.basename(directory)
    return values


def scan_records(workspace_root):
    records = []
    generations = set()
    for entry in sorted(os.scandir(workspace_root), key=lambda item: item.name):
        if entry.name in {".lock", "current"}:
            continue
        if entry.name.startswith(".tmp-"):
            validate_regular(entry.path)
            continue
        if not DISPATCH_RE.fullmatch(entry.name):
            raise StateError(f"unexpected entry in state directory: {entry.path}")
        validate_directory(entry.path)
        allowed = {"meta.tsv", "prompt.txt", "transcript.log", "last-message.txt"}
        for child in os.scandir(entry.path):
            if child.name.startswith(".tmp-"):
                validate_regular(child.path)
                continue
            if child.name not in allowed:
                raise StateError(f"unexpected entry in dispatch state: {child.path}")
            validate_regular(child.path, meta=(child.name == "meta.tsv"))
        record = read_meta(entry.path)
        if record["generation"] in generations:
            raise StateError("duplicate state generation")
        generations.add(record["generation"])
        records.append(record)
    records.sort(key=lambda value: value["generation"])
    return records


def repair_current(workspace_root, highest):
    path = os.path.join(workspace_root, "current")
    expected = ""
    if highest is not None and highest["state"] == "ready":
        expected = highest["dispatch_id"] + "\n"
    actual = None
    if os.path.lexists(path):
        validate_regular(path)
        with open(path, encoding="utf-8") as handle:
            actual = handle.read()
    if actual != expected:
        atomic_write(path, expected)


def toml_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return f'"{escaped}"'


def is_forbidden_argument(value):
    return value in FORBIDDEN or any(
        value.startswith(prefix)
        for prefix in ("--add-dir=", "--approve-for-me=", "--profile=", "--enable=", "--disable=")
    )


def build_codex_argv(kind, mode, session_id, output_path):
    """Build both calibrated forms from one mode-parameterized function."""
    if mode not in {"workspace-write", "read-only"}:
        raise StateError(f"invalid sandbox mode: {mode}")
    argv = [codex_bin, "exec"]
    if kind == "fresh":
        argv.extend(["-s", mode])
    else:
        if not SESSION_RE.fullmatch(session_id):
            raise StateError("resume requires an exact UUID session id")
        argv.extend(["resume", session_id, "-c", f'sandbox_mode={toml_string(mode)}'])
    argv.extend(
        [
            "-c",
            'approval_policy="never"',
            "--strict-config",
            "-c",
            "sandbox_workspace_write.writable_roots=[]",
            "-c",
            "sandbox_workspace_write.network_access=false",
            "-c",
            "sandbox_permissions=[]",
        ]
    )
    if kind == "fresh":
        argv.extend(["-C", workspace])
    if model:
        argv.extend(["-m", model])
    if effort:
        argv.extend(["-c", f"model_reasoning_effort={toml_string(effort)}"])
    # The terminator keeps a prompt beginning with `--` positional. It is not
    # a passthrough escape hatch: the adapter still constructs every control.
    argv.extend(["-o", output_path, "--", prompt])

    control = argv[:-1]
    if any(is_forbidden_argument(value) for value in control):
        raise StateError("constructed Codex argv contains a forbidden policy broadener")
    if "--json" in control:
        raise StateError("constructed Codex argv must not contain --json")
    sandbox_specs = sum(
        1
        for index, value in enumerate(control)
        if value == "-s"
        or (value == "-c" and index + 1 < len(control) and control[index + 1].startswith("sandbox_mode="))
    )
    if sandbox_specs != 1:
        raise StateError("constructed Codex argv must contain exactly one sandbox specification")
    return argv


def terminate_group(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if child.poll() is not None:
            return
        time.sleep(0.05)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


try:
    record = None
    workspace_root = None
    if workspace != os.path.realpath(workspace) or not os.path.isdir(workspace):
        raise StateError("workspace must be an existing canonical directory")
    # Canonical overlap is checked before rejecting path aliases so HOME under
    # macOS's symlinked /tmp still receives the containment verdict.
    verify_containment()
    no_symlink_components(state_root)
    config_root = os.path.dirname(os.path.dirname(state_root))
    loop_root = os.path.dirname(state_root)
    os.makedirs(config_root, mode=0o700, exist_ok=True)
    no_symlink_components(config_root)
    ensure_directory(loop_root)
    ensure_directory(state_root)
    verify_containment()

    workspace_key = hashlib.sha256(workspace.encode("utf-8")).hexdigest()
    workspace_root = os.path.join(state_root, workspace_key)
    ensure_directory(workspace_root)

    lock_path = os.path.join(workspace_root, ".lock")
    lock_flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        lock_flags |= os.O_NOFOLLOW
    lock_fd = os.open(lock_path, lock_flags, 0o600)
    os.set_inheritable(lock_fd, False)
    validate_regular(lock_path)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            holder = os.read(lock_fd, 256).decode("utf-8", "replace").strip()
        except OSError:
            holder = ""
        raise StateError(f"workspace lock is held{f' by {holder}' if holder else ''}")

    dispatch_id = f"{utc_now()}-{secrets.token_hex(4)}"
    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, (dispatch_id + "\n").encode("ascii"))
    os.fsync(lock_fd)

    records = scan_records(workspace_root)
    highest = records[-1] if records else None
    repair_current(workspace_root, highest)
    if highest is not None and highest["state"] in {"initializing", "running"}:
        raise StateError(
            f"highest generation is still {highest['state']}: {highest['dispatch_id']}"
        )

    session_id = ""
    if action == "resume":
        if highest is None or highest["state"] != "ready" or not highest["session_id"]:
            raise StateError("--resume has no ready loop-owned record; use a fresh dispatch")
        if requested_session and requested_session.lower() != highest["session_id"].lower():
            raise StateError("requested session id does not match the highest ready loop record")
        session_id = highest["session_id"]
    elif action == "resume-unmanaged":
        if not SESSION_RE.fullmatch(requested_session):
            raise StateError("--resume-unmanaged requires an exact UUID session id")
        session_id = requested_session.lower()
    elif action != "fresh":
        raise StateError(f"unknown dispatch action: {action}")

    generation = (highest["generation"] if highest else 0) + 1
    dispatch_directory = os.path.join(workspace_root, dispatch_id)
    os.mkdir(dispatch_directory, 0o700)
    validate_directory(dispatch_directory)
    created = utc_now()
    record = {
        "schema": "1",
        "state": "initializing",
        "generation": generation,
        "session_id": session_id,
        "workspace": workspace,
        "created": created,
        "updated": created,
        "directory": dispatch_directory,
        "dispatch_id": dispatch_id,
    }
    create_regular(os.path.join(dispatch_directory, "prompt.txt"), prompt.encode("utf-8"))
    create_regular(os.path.join(dispatch_directory, "transcript.log"))
    create_regular(os.path.join(dispatch_directory, "last-message.txt"))
    write_meta(record)
    record["state"] = "running"
    write_meta(record)

    last_message = os.path.join(dispatch_directory, "last-message.txt")
    transcript_path = os.path.join(dispatch_directory, "transcript.log")
    argv = build_codex_argv(
        "fresh" if action == "fresh" else "resume",
        sandbox_mode,
        session_id,
        last_message,
    )

    child = subprocess.Popen(
        argv,
        cwd=workspace,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    reported_sandbox = None
    reported_approval = None
    reported_session = None
    banner_started = False
    banner_closed = False
    banner_discovery_closed = False
    banner_error = None
    with open(transcript_path, "ab", buffering=0) as transcript:
        assert child.stdout is not None
        for raw in iter(child.stdout.readline, b""):
            transcript.write(raw)
            sys.stderr.buffer.write(raw)
            sys.stderr.buffer.flush()
            line = raw.decode("utf-8", "replace").strip()
            if line in {"user", "assistant", "analysis", "codex", "tool"}:
                if not banner_closed:
                    banner_discovery_closed = True
                    if banner_started and banner_error is None:
                        banner_error = "initial CLI policy banner ended without its delimiter"
                        terminate_group(child)
                continue
            if line == "--------":
                if banner_discovery_closed:
                    continue
                if not banner_started:
                    banner_started = True
                elif not banner_closed:
                    banner_closed = True
                    if (
                        banner_error is None
                        and (
                            reported_sandbox is None
                            or reported_approval is None
                            or reported_session is None
                        )
                    ):
                        banner_error = "initial CLI policy banner was incomplete"
                        terminate_group(child)
                continue
            if banner_discovery_closed or not banner_started or banner_closed:
                continue
            match = re.match(r"^sandbox:\s*([a-z-]+)(?:\s|$)", line)
            if match:
                if reported_sandbox is not None and banner_error is None:
                    banner_error = "initial CLI banner repeated sandbox"
                    terminate_group(child)
                    continue
                reported_sandbox = match.group(1)
                if reported_sandbox != sandbox_mode and banner_error is None:
                    banner_error = (
                        f"CLI reported sandbox {reported_sandbox}, requested {sandbox_mode}"
                    )
                    terminate_group(child)
            match = re.match(r"^approval:\s*(\S+)(?:\s|$)", line)
            if match:
                if reported_approval is not None and banner_error is None:
                    banner_error = "initial CLI banner repeated approval"
                    terminate_group(child)
                    continue
                reported_approval = match.group(1)
                if reported_approval != "never" and banner_error is None:
                    banner_error = (
                        f"CLI reported approval {reported_approval}, requested never"
                    )
                    terminate_group(child)
            match = re.match(r"^session id:\s*([0-9a-fA-F-]+)\s*$", line)
            if match and SESSION_RE.fullmatch(match.group(1)):
                if reported_session is not None and banner_error is None:
                    banner_error = "initial CLI banner repeated session id"
                    terminate_group(child)
                    continue
                observed = match.group(1).lower()
                if session_id and observed != session_id.lower() and banner_error is None:
                    banner_error = "CLI reported a session id different from the exact resume id"
                    terminate_group(child)
                reported_session = observed
                session_id = reported_session
                record["session_id"] = session_id
                write_meta(record)
    child_status = child.wait()

    print(
        f"sandbox (CLI reported): {reported_sandbox or '<not reported>'}",
        file=sys.stderr,
    )
    print(f"session id: {session_id or '<not reported>'}", file=sys.stderr)
    print(f"run state: {dispatch_directory}", file=sys.stderr)

    if banner_error is not None:
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        refuse(f"Codex banner mismatch; child process group terminated: {banner_error}")
    if child_status < 0:
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        refuse(f"Codex terminated by signal {-child_status}", 128 + (-child_status))
    if child_status != 0:
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        raise SystemExit(child_status)
    if (
        not banner_started
        or not banner_closed
        or reported_sandbox is None
        or reported_approval is None
        or reported_session is None
    ):
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        refuse("Codex policy banner was absent or incomplete")
    if reported_sandbox != sandbox_mode or reported_approval != "never":
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        refuse("Codex policy banner did not match the requested policy")
    if not session_id or session_id != reported_session:
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)
        refuse("Codex banner did not report a valid session id")
    validate_regular(last_message, allow_empty=False)

    record["session_id"] = session_id
    record["state"] = "ready"
    write_meta(record)
    repair_current(workspace_root, record)
    with open(last_message, "rb") as handle:
        sys.stdout.buffer.write(handle.read())
        sys.stdout.buffer.flush()
except StateError as error:
    if record is not None and record.get("state") in {"initializing", "running"}:
        try:
            record["state"] = "failed"
            write_meta(record)
            if workspace_root is not None:
                repair_current(workspace_root, record)
        except Exception as transition_error:
            print(
                f"error: additionally failed to record terminal state: {transition_error}",
                file=sys.stderr,
            )
    refuse(str(error))
PY
