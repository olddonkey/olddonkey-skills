#!/usr/bin/env bash
# Dispatch an implementation or investigation task through plain `codex exec`.
#
# Usage:
#   codex-dispatch.sh --prompt-file PATH [--read-only|--investigate]
#                     [--model MODEL] [--effort LEVEL]
#                     [--resume [SESSION_ID]|--resume-unmanaged SESSION_ID]
#   codex-dispatch.sh --prompt "short inline prompt" [...]
#   codex-dispatch.sh --recover-stale | --recover-stale-unverified
#
# Run from the ROOT of the target repository. Fresh turns pin the workspace
# with `-C`; resumed turns cannot accept `-C`, so the adapter changes directory
# before launching them. Every path pins sandbox, approval, nested writable
# roots, network, and permissions instead of inheriting those controls.
#
# `--read-only` and `--investigate` select Codex's read-only sandbox. The
# default is workspace-write. The adapter itself never stages or commits.
#
# Resume is exact-id only and never falls back to `--last`. The required matrix
# passed for the calibrated tuple on 2026-08-17. Reset
# RESUME_RELEASE_ENABLED to 0 if this adapter's argv, the state schema, or the
# pinned config keys change, and leave it reset until that matrix is re-run.
# `--resume-unmanaged ID` is the explicit migration path for a legacy app-server
# session; a successful turn adopts the id into loop-owned state.
#
# This adapter is strictly foreground. `--background` is rejected; background
# the adapter at the harness level, where its exit remains authoritative.
# SIGTERM, SIGINT, and SIGHUP stop the Codex process group, record the
# generation as failed, and exit 128 plus the signal number.
#
# `--recover-stale` never dispatches. It is for a generation left `running` or
# `initializing` by a wrapper that died without a handler (SIGKILL, host
# crash): it records that generation as failed once the workspace lock is free
# and the recorded Codex process group has no members, and refuses while that
# group is alive. `--recover-stale-unverified` is the operator's assertion for
# a generation whose process group cannot be checked; it is still refused while
# the recorded Codex process is verifiably running. Neither takes other
# arguments. Resume after recovery stays an explicit exact-id action.
#
# Model and effort have no adapter defaults. Explicit effort is forwarded as a
# quoted TOML `model_reasoning_effort` override, including `ultra` and `max`.
# Omitted values are left to the Codex CLI's normal config resolution.

set -euo pipefail
# The adapter's own state is private (0600/0700), but the files a Codex
# implementer creates in the real workspace belong to the engineer. The CLI
# child therefore starts with the mask that was in force when this adapter was
# invoked, and the private mask covers only what the adapter itself creates.
CALLER_UMASK="$(umask)"
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ -n "${LOOP_JOURNAL:-}" ]]; then
  JOURNAL_HELPER="$LOOP_JOURNAL"
else
  JOURNAL_HELPER="$SCRIPT_DIR/../../scripts/loop-journal"
fi

MODEL="${CODEX_LOOP_MODEL:-}"
EFFORT="${CODEX_LOOP_EFFORT:-}"
PROMPT_FILE=""
PROMPT=""
ACTION="fresh"
RESUME_ID=""
READ_ONLY=0
RECOVER=""
ARGUMENT_COUNT=$#
ADAPTER_VERSION="2"

# This is intentionally a source constant, not an environment toggle.
RESUME_RELEASE_ENABLED=1

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
    --recover-stale) RECOVER="recover-stale"; shift ;;
    --recover-stale-unverified) RECOVER="recover-stale-unverified"; shift ;;
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

# Recovery is a state-only action: it launches no CLI, so it takes no dispatch
# argument and needs neither a prompt nor the codex binary.
REQUIRED_COMMANDS=(codex python3)
if [[ -n "$RECOVER" ]]; then
  if [[ $ARGUMENT_COUNT -ne 1 ]]; then
    echo "error: --$RECOVER takes no other arguments; it records a dead generation as failed and never dispatches" >&2
    exit 2
  fi
  ACTION="$RECOVER"
  REQUIRED_COMMANDS=(python3)
else
  [[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 2; }
fi

for REQUIRED in "${REQUIRED_COMMANDS[@]}"; do
  command -v "$REQUIRED" >/dev/null 2>&1 || {
    echo "error: required command not found: $REQUIRED" >&2
    exit 3
  }
done

if [[ "$ACTION" == resume* && $RESUME_RELEASE_ENABLED -ne 1 ]]; then
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
    for name in sorted(table):
        entry = table[name]
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
  # Recovery launches no CLI, so there is no exposure to disclose or block.
  [[ -z "$RECOVER" ]] || break
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
    | env LC_ALL=C tr -d '[]' | env LC_ALL=C paste -sd, - | env LC_ALL=C sed 's/,/, /g')"
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
  env LC_ALL=C awk -v key="$2" '
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

STATE_ROOT="$HOME/.config/olddonkey-loop/codex"
CODEX_BIN=""

if [[ -n "$RECOVER" ]]; then
  echo "codex stale-generation recovery (no dispatch):" >&2
  echo "workspace: $WORKSPACE" >&2
  echo "adapter version: $ADAPTER_VERSION" >&2
else
  CODEX_BIN="$(command -v codex)"
  CODEX_VERSION="$("$CODEX_BIN" --version 2>/dev/null || echo '?')"

  echo "codex exec dispatch summary:" >&2
  echo "workspace: $WORKSPACE" >&2
  echo "codex version: $CODEX_VERSION" >&2
  echo "adapter version: $ADAPTER_VERSION" >&2
  describe "model" "$MODEL" "model" >&2
  describe "effort" "$EFFORT" "model_reasoning_effort" >&2
  describe "tier" "" "service_tier" >&2
  echo "mode: $MODE_LABEL" >&2
  echo "sandbox (requested): $SANDBOX_MODE" >&2
  echo "worktree umask: $CALLER_UMASK (caller's; the CLI child inherits it)" >&2
  case "$ACTION" in
    fresh) echo "resume: no (fresh dispatch)" >&2 ;;
    resume) echo "resume: managed exact id${RESUME_ID:+ $RESUME_ID}" >&2 ;;
    resume-unmanaged) echo "resume: unmanaged exact id $RESUME_ID (migration/adoption)" >&2 ;;
  esac
fi

# The Python supervisor is the state-directory module. It owns secure
# bootstrap, the non-blocking descriptor lock, authoritative record scans,
# the single parameterized argv builder, process-group lifecycle, transcript
# capture, banner verification, atomic state transitions, stop-signal
# handling, and stale-generation recovery.
exec python3 - \
  "$STATE_ROOT" "$WORKSPACE" "$SANDBOX_MODE" "$ACTION" "$RESUME_ID" \
  "$CODEX_BIN" "$MODEL" "$EFFORT" "$PROMPT" "$JOURNAL_HELPER" "$CALLER_UMASK" <<'PY'
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
    journal_helper,
    caller_umask_text,
) = sys.argv[1:]
# The mask the adapter's caller had; this process keeps 0o077 for its own
# state and hands the caller's mask only to the CLI child.
CALLER_UMASK = int(caller_umask_text, 8)

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
RECOVERING = action in {"recover-stale", "recover-stale-unverified"}
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
PID_RE = re.compile(r"^[1-9][0-9]{0,9}$")
START_RE = re.compile(r"^(?:proc|ps):[A-Za-z0-9:. -]{1,96}$")


class StateError(Exception):
    pass


class Interrupted(BaseException):
    """A stop signal delivered while waiting on the Codex child."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


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
        for child in sorted(os.scandir(entry.path), key=lambda item: item.name):
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
    # Do not add sandbox_permissions=[] from `codex exec --help`: in codex-cli
    # 0.147.0 that example is stale and the key is absent from the real config
    # schema. --strict-config makes an unknown -c key fatal before startup, and
    # the same schema rejects it in user config, so there is no ambient value to
    # pin away. Validate every new fixed -c key with the real-CLI integration
    # schema probe before shipping it.
    argv.extend(
        [
            "-c",
            'approval_policy="never"',
            "--strict-config",
            "-c",
            "sandbox_workspace_write.writable_roots=[]",
            "-c",
            "sandbox_workspace_write.network_access=false",
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


def group_alive(pgid):
    """True while any process is still a member of the process group."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_group(child):
    """TERM the child's process group, then KILL whatever outlives the grace."""
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        # A reaped leader whose group still has members cannot have had its
        # id reused, so the group id keeps naming this dispatch's processes.
        if child.poll() is not None and not group_alive(child.pid):
            return
        time.sleep(0.05)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def fail_generation(workspace_root, record):
    """Move a non-terminal record to failed; a terminal record is left alone."""
    if record["state"] in {"initializing", "running"}:
        record["state"] = "failed"
        write_meta(record)
        repair_current(workspace_root, record)


def stop_child(child):
    """Abnormal-exit cleanup for a CLI this wrapper has not yet reaped."""
    if child is None or child.returncode is not None:
        return
    terminate_group(child)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


_PENDING_STOP = []
_STOP_DEFERRED = True


def handle_stop_signal(signum, _frame):
    """Stop signals raise only inside interruptible(); elsewhere they wait."""
    global _STOP_DEFERRED
    if _STOP_DEFERRED:
        if not _PENDING_STOP:
            _PENDING_STOP.append(signum)
        return
    _STOP_DEFERRED = True
    raise Interrupted(signum)


def install_stop_handlers():
    # A disposition inherited as ignored (nohup, a shell's background job) is
    # the launcher's decision and is left alone.
    for signum in STOP_SIGNALS:
        if signal.getsignal(signum) != signal.SIG_IGN:
            signal.signal(signum, handle_stop_signal)


def interruptible(call):
    """Run one blocking wait on the child with stop signals deliverable.

    State transitions, the spawn, and journal writes run with stop signals
    deferred, so an interrupt can never lose the child handle or tear a
    record; the deferred signal is raised at the next wait.
    """
    global _STOP_DEFERRED
    _STOP_DEFERRED = False
    try:
        if _PENDING_STOP:
            raise Interrupted(_PENDING_STOP[0])
        return call()
    finally:
        _STOP_DEFERRED = True


def process_start(pid):
    """Opaque start-time identity of a running pid; "" if unknown or a zombie."""
    value = ""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            fields = handle.read().rsplit(b")", 1)[1].split()
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            boot = handle.read().strip()
        if fields[0] != b"Z":
            value = f"proc:{boot}:{int(fields[19])}"
    except (OSError, IndexError, ValueError):
        # No procfs (macOS, BSD). `lstart` is rendered local time, so the zone
        # and locale are pinned; unpinned, it would change across a DST shift.
        try:
            listed = subprocess.run(
                ["ps", "-o", "state=", "-o", "lstart=", "-p", str(pid)],
                env=dict(os.environ, LC_ALL="C", TZ="UTC0"),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return ""
        words = listed.stdout.decode("ascii", "replace").split()
        if listed.returncode == 0 and len(words) > 1 and not words[0].startswith("Z"):
            value = "ps:" + " ".join(words[1:])
    return value if START_RE.fullmatch(value) else ""


def read_holder(lock_fd):
    """Parse the lock file's holder line; malformed fields read as absent.

    `<holder-id> TAB wrapper_pid=N [TAB child_dispatch=ID TAB child_pgid=N
    [TAB child_start=S]]`. The first two fields name whoever holds the lock
    now. The child fields name the last CLI this workspace spawned.
    """
    holder = {
        "raw": "",
        "dispatch_id": "",
        "wrapper_pid": None,
        "child_dispatch": "",
        "child_pgid": None,
        "child_start": "",
    }
    try:
        text = os.pread(lock_fd, 1024, 0).decode("ascii", "replace")
    except OSError:
        return holder
    line = text.split("\n", 1)[0]
    holder["raw"] = " ".join(line.split())
    fields = line.split("\t")
    if not DISPATCH_RE.fullmatch(fields[0]):
        return holder
    holder["dispatch_id"] = fields[0]
    values = dict(field.split("=", 1) for field in fields[1:] if "=" in field)
    if PID_RE.fullmatch(values.get("wrapper_pid", "")):
        holder["wrapper_pid"] = int(values["wrapper_pid"])
    child_pgid = values.get("child_pgid", "")
    # Group ids 0 and 1 would address this wrapper's own group or init.
    if (
        DISPATCH_RE.fullmatch(values.get("child_dispatch", ""))
        and PID_RE.fullmatch(child_pgid)
        and int(child_pgid) > 1
    ):
        holder["child_dispatch"] = values["child_dispatch"]
        holder["child_pgid"] = int(child_pgid)
        if START_RE.fullmatch(values.get("child_start", "")):
            holder["child_start"] = values["child_start"]
    return holder


def write_holder(lock_fd, holder_id, child):
    """Rewrite the holder line in place: the lock is on this inode."""
    fields = [holder_id, f"wrapper_pid={os.getpid()}"]
    if child["child_pgid"] is not None:
        fields.append(f"child_dispatch={child['child_dispatch']}")
        fields.append(f"child_pgid={child['child_pgid']}")
        if child["child_start"]:
            fields.append(f"child_start={child['child_start']}")
    data = ("\t".join(fields) + "\n").encode("ascii")
    # Write before truncating so a reader never finds the file empty; only
    # the first line is ever parsed.
    os.pwrite(lock_fd, data, 0)
    os.ftruncate(lock_fd, len(data))
    os.fsync(lock_fd)


def lock_held_message(holder):
    if not holder["dispatch_id"]:
        return "workspace lock is held" + (f" by {holder['raw']}" if holder["raw"] else "")
    message = f"workspace lock is held by {holder['dispatch_id']}"
    if holder["wrapper_pid"] is not None:
        message += (
            f" (wrapper pid {holder['wrapper_pid']}); to cancel an in-flight dispatch"
            " send that wrapper SIGTERM"
        )
    return message


def stale_child_verdict(stale, last_child):
    """Classify the CLI of a non-terminal generation whose wrapper is gone.

    Returns (verdict, evidence, pgid). Only two findings prove the CLI dead:
    the generation never reached `running`, or its recorded process group has
    no members. A start-time match proves it alive. Anything else is
    `unverified` and left to the operator; a start-time mismatch is never
    taken as proof of death.
    """
    if stale["state"] == "initializing":
        return "dead", "it never reached running, so no Codex process was started", None
    if last_child["child_dispatch"] != stale["dispatch_id"]:
        return (
            "unverified",
            "no Codex process group is recorded for it (it predates process "
            "recording, or its wrapper died while starting the CLI)",
            None,
        )
    pgid = last_child["child_pgid"]
    if not group_alive(pgid):
        return "dead", f"its recorded Codex process group {pgid} has no members", pgid
    recorded = last_child["child_start"]
    if recorded and process_start(pgid) == recorded:
        return "alive", f"its Codex process (pid and process group {pgid}) is still running", pgid
    return (
        "unverified",
        f"process group {pgid} has live members that cannot be tied to it (the "
        "recorded Codex process itself is gone, or another process now has its id)",
        pgid,
    )


def recover_stale(workspace_root, records, last_child):
    """Record a dead non-terminal highest generation as failed.

    Runs under the workspace lock, which is the proof that the wrapper that
    owned the generation is gone. It never signals a process.
    """
    highest = records[-1] if records else None
    if highest is None or highest["state"] not in {"initializing", "running"}:
        found = (
            "this workspace has no generations"
            if highest is None
            else f"highest generation {highest['dispatch_id']} is {highest['state']}"
        )
        print(f"recover-stale: nothing to recover ({found})", file=sys.stderr)
        raise SystemExit(0)
    stale_id = highest["dispatch_id"]
    previous_state = highest["state"]
    verdict, evidence, pgid = stale_child_verdict(highest, last_child)
    listing = f"ps -axww -o pid=,pgid=,command= | awk '$2 == {pgid}'"
    if verdict == "alive":
        refuse(
            f"generation {stale_id} is not dead: {evidence}\n"
            "Stop it, then run --recover-stale again:\n"
            f"  kill -TERM -- -{pgid}\n"
            f"  {listing}    # members still listed after a few seconds? then:\n"
            f"  kill -KILL -- -{pgid}\n"
            "--recover-stale-unverified does not override a verified live process."
        )
    if verdict == "unverified" and action != "recover-stale-unverified":
        if pgid is None:
            check = (
                "Look for a surviving `codex exec` of this generation:\n"
                f"  ps -axww -o pid=,pgid=,command= | grep '{stale_id}/last-message[.]txt'\n"
                "If that prints nothing, run --recover-stale-unverified to record the "
                "generation as failed on your assertion."
            )
        else:
            check = (
                f"List them:\n  {listing}\n"
                f"Leftovers of this dispatch: stop them (kill -TERM -- -{pgid}) and run "
                "--recover-stale again.\n"
                "Unrelated processes that reused the id: run --recover-stale-unverified "
                "to record the generation as failed on your assertion."
            )
        refuse(f"generation {stale_id} cannot be verified dead: {evidence}\n{check}")

    highest["state"] = "failed"
    write_meta(highest)
    repair_current(workspace_root, highest)
    print(
        f"recover-stale: generation {stale_id} recorded as failed (was {previous_state})",
        file=sys.stderr,
    )
    print(
        f"evidence: the workspace lock was free, so its wrapper is gone; {evidence}",
        file=sys.stderr,
    )
    if verdict == "unverified":
        print(
            "warning: child liveness was NOT verified; recorded on operator "
            "assertion (--recover-stale-unverified)",
            file=sys.stderr,
        )
    print(f"session id: {highest['session_id'] or '<none captured>'}", file=sys.stderr)
    ready = [item for item in records if item["state"] == "ready"]
    if ready:
        print(
            f"newest ready generation: {ready[-1]['dispatch_id']} "
            f"session {ready[-1]['session_id']}",
            file=sys.stderr,
        )
    print(
        "resume: plain --resume stays refused until a turn reaches ready; start a "
        "fresh dispatch, or name the exact session with --resume-unmanaged <session id>",
        file=sys.stderr,
    )
    print(
        "journal: a loop run that recorded this dispatch still shows it open; "
        f"`loop-journal recover --acknowledge {stale_id}` closes it",
        file=sys.stderr,
    )
    raise SystemExit(0)


def journal_helper_ok():
    return bool(journal_helper) and os.path.isfile(journal_helper) and os.access(
        journal_helper, os.X_OK
    )


def journal_mode():
    return "read-only" if sandbox_mode == "read-only" else "implement"


def journal_append(event, fields):
    if not journal_helper_ok():
        return 0
    command = [
        journal_helper,
        "append",
        "--workspace",
        workspace,
        "--event",
        event,
    ]
    for key, value in fields:
        command.extend(["--field", f"{key}={value}"])
    completed = subprocess.run(command, check=False)
    return completed.returncode


def journal_dispatch_start(dispatch_id):
    status = journal_append(
        "dispatch.start",
        (
            ("dispatch_id", dispatch_id),
            ("backend", "codex"),
            ("mode", journal_mode()),
        ),
    )
    if status != 0:
        raise StateError(f"loop-journal dispatch.start failed (exit {status})")


_JOURNAL_END_WRITTEN = False


def journal_dispatch_end(dispatch_id, exit_code, session=""):
    global _JOURNAL_END_WRITTEN
    if _JOURNAL_END_WRITTEN:
        return
    _JOURNAL_END_WRITTEN = True
    fields = [("dispatch_id", dispatch_id), ("exit", str(exit_code))]
    if session:
        fields.append(("session", session))
    status = journal_append("dispatch.end", fields)
    if status != 0:
        print("warning: loop-journal dispatch.end failed", file=sys.stderr)


try:
    record = None
    workspace_root = None
    if workspace != os.path.realpath(workspace) or not os.path.isdir(workspace):
        raise StateError("workspace must be an existing canonical directory")
    # Canonical overlap is checked before rejecting path aliases so HOME under
    # macOS's symlinked /tmp still receives the containment verdict.
    verify_containment()
    no_symlink_components(state_root)
    workspace_key = hashlib.sha256(workspace.encode("utf-8")).hexdigest()
    workspace_root = os.path.join(state_root, workspace_key)
    if RECOVERING and not os.path.lexists(workspace_root):
        # Recovery of a never-dispatched workspace creates no state.
        recover_stale(workspace_root, [], None)
    config_root = os.path.dirname(os.path.dirname(state_root))
    loop_root = os.path.dirname(state_root)
    os.makedirs(config_root, mode=0o700, exist_ok=True)
    no_symlink_components(config_root)
    ensure_directory(loop_root)
    ensure_directory(state_root)
    verify_containment()

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
        raise StateError(lock_held_message(read_holder(lock_fd)))

    # The lock is held until this process exits, so holding it proves that no
    # earlier wrapper for this workspace is alive. The holder line's child
    # fields are carried forward until the next spawn: they are how
    # --recover-stale finds the process group of a generation whose wrapper
    # died, even after later invocations have taken and released the lock.
    last_child = read_holder(lock_fd)
    dispatch_id = f"{utc_now()}-{secrets.token_hex(4)}"
    write_holder(lock_fd, dispatch_id, last_child)

    records = scan_records(workspace_root)
    highest = records[-1] if records else None
    repair_current(workspace_root, highest)
    if RECOVERING:
        recover_stale(workspace_root, records, last_child)
    if highest is not None and highest["state"] in {"initializing", "running"}:
        raise StateError(
            f"highest generation is still {highest['state']}: {highest['dispatch_id']}; "
            "the workspace lock was free, so its wrapper is gone. Run this adapter "
            "with --recover-stale from the workspace root to check for a surviving "
            "Codex process and record the generation as failed"
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

    # From here a record exists, so a stop signal must leave it terminal.
    install_stop_handlers()
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

    last_message = os.path.join(dispatch_directory, "last-message.txt")
    transcript_path = os.path.join(dispatch_directory, "transcript.log")
    argv = build_codex_argv(
        "fresh" if action == "fresh" else "resume",
        sandbox_mode,
        session_id,
        last_message,
    )
    journal_dispatch_start(dispatch_id)

    end_exit = 5
    child = None
    try:
        # A stop signal that arrived during setup ends the dispatch here.
        interruptible(lambda: None)
        # `initializing` means no CLI was ever started. `running` is written
        # immediately before the spawn and the child's process group
        # immediately after it, so a `running` record without a recorded
        # group is the only state in which a CLI may exist unrecorded.
        record["state"] = "running"
        write_meta(record)
        # preexec_fn runs in the child between fork and exec, so the CLI and
        # everything it writes into the workspace see the caller's umask while
        # this process keeps its private one. This interpreter has no threads,
        # which is the condition under which preexec_fn is safe.
        child = subprocess.Popen(
            argv,
            cwd=workspace,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
            preexec_fn=lambda: os.umask(CALLER_UMASK),
        )
        # start_new_session makes the child the leader of its own session and
        # process group, so its pid is also the group id. The group is
        # recorded first; the start time may need a `ps` run and follows.
        spawned = {"child_dispatch": dispatch_id, "child_pgid": child.pid, "child_start": ""}
        write_holder(lock_fd, dispatch_id, spawned)
        spawned["child_start"] = process_start(child.pid)
        if spawned["child_start"]:
            write_holder(lock_fd, dispatch_id, spawned)
        reported_sandbox = None
        reported_approval = None
        reported_session = None
        banner_started = False
        banner_closed = False
        banner_discovery_closed = False
        banner_error = None
        with open(transcript_path, "ab", buffering=0) as transcript:
            assert child.stdout is not None
            for raw in iter(lambda: interruptible(child.stdout.readline), b""):
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
        child_status = interruptible(child.wait)

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
            end_exit = 5
            refuse(f"Codex banner mismatch; child process group terminated: {banner_error}")
        if child_status < 0:
            record["state"] = "failed"
            write_meta(record)
            repair_current(workspace_root, record)
            end_exit = 128 + (-child_status)
            refuse(f"Codex terminated by signal {-child_status}", end_exit)
        if child_status != 0:
            record["state"] = "failed"
            write_meta(record)
            repair_current(workspace_root, record)
            end_exit = child_status
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
            end_exit = 5
            refuse("Codex policy banner was absent or incomplete")
        if reported_sandbox != sandbox_mode or reported_approval != "never":
            record["state"] = "failed"
            write_meta(record)
            repair_current(workspace_root, record)
            end_exit = 5
            refuse("Codex policy banner did not match the requested policy")
        if not session_id or session_id != reported_session:
            record["state"] = "failed"
            write_meta(record)
            repair_current(workspace_root, record)
            end_exit = 5
            refuse("Codex banner did not report a valid session id")
        validate_regular(last_message, allow_empty=False)

        record["session_id"] = session_id
        record["state"] = "ready"
        write_meta(record)
        repair_current(workspace_root, record)
        with open(last_message, "rb") as handle:
            sys.stdout.buffer.write(handle.read())
            sys.stdout.buffer.flush()
        end_exit = 0
    except Interrupted as stop:
        end_exit = 128 + stop.signum
        stop_child(child)
        fail_generation(workspace_root, record)
        print(f"run state: {dispatch_directory}", file=sys.stderr)
        stopped = "before the CLI started" if child is None else "Codex process group stopped"
        refuse(
            f"dispatch interrupted by {signal.Signals(stop.signum).name}; {stopped}; "
            f"generation {dispatch_id} recorded as failed",
            end_exit,
        )
    except BrokenPipeError:
        # The reader of this wrapper's output is gone, which is how a parent
        # session that ended without signalling it appears. Reported like
        # SIGPIPE; the streams are parked so interpreter exit cannot fail.
        end_exit = 128 + signal.SIGPIPE
        stop_child(child)
        fail_generation(workspace_root, record)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        raise SystemExit(end_exit)
    except StateError:
        # The handler below records the failure; a CLI must not outlive it.
        stop_child(child)
        raise
    except SystemExit:
        raise
    except BaseException:
        # Nothing unexpected may leave a live CLI behind a non-terminal record.
        end_exit = 1
        stop_child(child)
        fail_generation(workspace_root, record)
        raise
    finally:
        journal_dispatch_end(dispatch_id, end_exit, session_id)
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
