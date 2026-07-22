#!/usr/bin/env bash
# Dispatch an implementation task to Codex via the codex-companion runtime.
#
# Locates the active installed companion (with cache fallbacks) so you don't
# rediscover the path when plugin versions change, and validates effort
# choices against either the companion or a top-level config-only assertion.
#
# Usage:
#   codex-dispatch.sh --prompt-file PATH [--read-only|--investigate] [--background]
#                     [--model MODEL] [--effort LEVEL] [--resume]
#   codex-dispatch.sh --prompt "short inline prompt" [...]
#
# The prompt is always passed to the companion behind a `--` argument
# terminator: the companion re-splits a lone trailing argument shell-style,
# so without the terminator a prompt merely MENTIONING --write would become
# a real write flag. For the same reason there is deliberately no
# passthrough for extra companion arguments — privilege, workspace, and
# resume flags must come from this script's own interface.
#
# Run from the ROOT of the target repo: the companion operates on the
# invoking directory, so a dispatch from the wrong place silently points
# Codex at the wrong workspace. Check the "workspace:" line it prints.
#
# --read-only runs Codex without file-write access: use it to diagnose,
# read code, or get a proposal. It changes the shape of the work — there
# is no diff to review, no gate, nothing to publish — so treat it as a
# different mode rather than a safer version of implementing.
#
# Model and effort are deliberately NOT defaulted here. When neither flag
# is passed, nothing is forwarded and the Codex CLI falls back to the
# user's own config layers. Config-only efforts (currently ultra and max)
# can instead be named as assertions: the script checks the project-local,
# then global, top-level config value and inherits it without forwarding an
# unsupported --effort flag. Set CODEX_LOOP_MODEL / CODEX_LOOP_EFFORT to give
# one project a standing preference without editing this script or the user's
# config; config-only effort values still assert rather than override it.
#
# Prefer --prompt-file: dispatch prompts are long, and shell-escaping a
# multi-paragraph prompt is a reliable way to corrupt it.
#
# Run this as a background job — Codex tasks take a while and you should
# not be blocked while it works.

set -euo pipefail

MODEL="${CODEX_LOOP_MODEL:-}"
EFFORT="${CODEX_LOOP_EFFORT:-}"
PROMPT_FILE=""
PROMPT=""
RESUME=0
READ_ONLY=0
BACKGROUND=0

# Fallback snapshot (companion 1.0.6). The live list is read from the
# installed companion below — the wrapper is the authority, not this file.
VALID_EFFORTS="none minimal low medium high xhigh"

# Snapshot of real Codex levels that companion 1.0.6 cannot accept as flags.
# There is no runtime source for this list, so it may rot as the companion
# evolves. The detected companion enum below takes precedence when they overlap.
CONFIG_ONLY_EFFORTS="ultra max"

usage() {
  # Print the whole header comment block, however long it grows.
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:?--prompt-file needs a path}"; shift 2 ;;
    --prompt)      PROMPT="${2:?--prompt needs text}"; shift 2 ;;
    --model)       MODEL="${2:?--model needs a value}"; shift 2 ;;
    --effort)      EFFORT="${2:?--effort needs a value}"; shift 2 ;;
    --resume)      RESUME=1; shift ;;
    --read-only|--investigate) READ_ONLY=1; shift ;;
    --background)  BACKGROUND=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 1; }

# Prefer an explicit override, then Claude's active plugin view, then its
# installed-plugin manifest. Cache scans are fallbacks only: stale cached
# versions can be newer than the version the plugin manager has activated.
COMPANION=""
COMPANION_SOURCE=""
COMPANION_OVERRIDE="${CODEX_LOOP_COMPANION:-}"

if [[ -n "$COMPANION_OVERRIDE" && -f "$COMPANION_OVERRIDE" ]]; then
  COMPANION="$COMPANION_OVERRIDE"
  COMPANION_SOURCE="explicit override"
fi

claude_plugin_install_path() {
  command -v claude >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local plugin_json=""
  plugin_json="$(claude plugin list --json 2>/dev/null)" || return 0
  [[ -n "$plugin_json" ]] || return 0

  # The CLI view already incorporates settings precedence. Filter to enabled
  # Codex entries, retain that precedence explicitly, and ignore stale paths.
  python3 -c '
import json
import os
import sys

try:
    entries = json.load(sys.stdin)
except (ValueError, TypeError):
    raise SystemExit(0)

if not isinstance(entries, list):
    raise SystemExit(0)

scope_order = {"managed": 0, "local": 1, "project": 2, "user": 3}
candidates = []
for index, entry in enumerate(entries):
    if not isinstance(entry, dict):
        continue
    if entry.get("id") != "codex@openai-codex" or entry.get("enabled") is not True:
        continue
    install_path = entry.get("installPath")
    if not isinstance(install_path, str):
        continue
    companion = os.path.join(install_path, "scripts", "codex-companion.mjs")
    if os.path.isfile(companion):
        candidates.append((scope_order.get(entry.get("scope"), 4), index, install_path))

if candidates:
    print(min(candidates)[2])
' <<< "$plugin_json" 2>/dev/null || true
}

active_install_path() {
  local manifest="$HOME/.claude/plugins/installed_plugins.json"
  [[ -f "$manifest" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$manifest" 2>/dev/null <<'PY' || true
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError, TypeError):
    raise SystemExit(0)

if not isinstance(data, dict):
    raise SystemExit(0)
entries = data.get("plugins", {}).get("codex@openai-codex", [])
if isinstance(entries, dict):
    entries = [entries]
if not isinstance(entries, list):
    raise SystemExit(0)

entries = [
    entry for entry in entries
    if (
        isinstance(entry, dict)
        and isinstance(entry.get("installPath"), str)
        and entry.get("enabled") is not False
        and os.path.isfile(
            os.path.join(entry["installPath"], "scripts", "codex-companion.mjs")
        )
    )
]
if entries:
    scope_order = {"managed": 0, "local": 1, "project": 2, "user": 3}
    chosen = min(
        enumerate(entries),
        key=lambda item: (scope_order.get(item[1].get("scope"), 4), item[0]),
    )[1]
    print(chosen["installPath"])
PY
}

if [[ -z "$COMPANION" ]]; then
  CLAUDE_INSTALL_PATH="$(claude_plugin_install_path)"
  if [[ -n "$CLAUDE_INSTALL_PATH" && -f "$CLAUDE_INSTALL_PATH/scripts/codex-companion.mjs" ]]; then
    COMPANION="$CLAUDE_INSTALL_PATH/scripts/codex-companion.mjs"
    COMPANION_SOURCE="claude plugin list"
  fi
fi

if [[ -z "$COMPANION" ]]; then
  ACTIVE_INSTALL_PATH="$(active_install_path)"
  if [[ -n "$ACTIVE_INSTALL_PATH" && -f "$ACTIVE_INSTALL_PATH/scripts/codex-companion.mjs" ]]; then
    COMPANION="$ACTIVE_INSTALL_PATH/scripts/codex-companion.mjs"
    COMPANION_SOURCE="active install"
  fi
fi

if [[ -z "$COMPANION" ]]; then
  COMPANION="$(find "$HOME/.claude/plugins/cache" \
                    -name codex-companion.mjs -type f 2>/dev/null \
               | sort -V | tail -1 || true)"
  [[ -z "$COMPANION" ]] || COMPANION_SOURCE="cache scan"
fi
if [[ -z "$COMPANION" ]]; then
  COMPANION="$(find "$HOME/.claude/plugins/marketplaces" \
                    -name codex-companion.mjs -type f 2>/dev/null \
               | tail -1 || true)"
  [[ -z "$COMPANION" ]] || COMPANION_SOURCE="marketplace fallback"
fi
[[ -n "$COMPANION" ]] || {
  echo "codex-companion.mjs not found; is the Codex plugin installed?" >&2
  exit 3
}

# Ask the INSTALLED companion which efforts it accepts — the list changes
# across plugin versions, so read it at runtime instead of freezing a copy
# here. Falls back to the snapshot above if the usage string moves.
DETECTED_EFFORTS="$(grep -oE -- '--effort <[a-z|]+>' "$COMPANION" 2>/dev/null \
                    | head -1 | sed -E 's/.*<([a-z|]+)>.*/\1/' | tr '|' ' ' \
                    || true)"
[[ -n "$DETECTED_EFFORTS" ]] && VALID_EFFORTS="$DETECTED_EFFORTS"

# A live companion-accepted value remains a normal forwarded override. Only a
# value outside that enum may resolve through the config-only snapshot. Trim and
# fold case for those assertions so `Max` and `  MAX  ` mean the same thing.
CONFIG_ONLY_EFFORT=""
if [[ -n "$EFFORT" && " $VALID_EFFORTS " != *" $EFFORT "* ]]; then
  NORMALIZED_EFFORT="$(printf '%s\n' "$EFFORT" \
    | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ " $CONFIG_ONLY_EFFORTS " == *" $NORMALIZED_EFFORT "* ]]; then
    CONFIG_ONLY_EFFORT="$NORMALIZED_EFFORT"
  else
    echo "invalid --effort '$EFFORT'; this companion accepts: $VALID_EFFORTS" >&2
    exit 2
  fi
fi

CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
PROJECT_CONFIG="$PWD/.codex/config.toml"

# Both config-only effort assertions and the external-tools scan below require
# a real TOML parser. Find a versioned interpreter when the default python3 is
# older than 3.11; neither check falls back to regex scanning.
TOML_PYTHON=""
for TOML_CANDIDATE in python3 python3.13 python3.12 python3.11; do
  if command -v "$TOML_CANDIDATE" >/dev/null 2>&1 && \
     "$TOML_CANDIDATE" -c 'import tomllib' 2>/dev/null; then
    TOML_PYTHON="$TOML_CANDIDATE"
    break
  fi
done

config_effort_failure() { # $1=what was found, or why it could not be determined
  echo "error: requested config-only effort '$CONFIG_ONLY_EFFORT', but $1." >&2
  echo "remedy: ensure python3 with tomllib (3.11+) is available, then inspect the" >&2
  echo "        top-level config layers in precedence order:" >&2
  echo "        project: $PROJECT_CONFIG" >&2
  echo "        global : $CONFIG" >&2
  echo "        The first model_reasoning_effort found must be:" >&2
  echo "        model_reasoning_effort = \"$CONFIG_ONLY_EFFORT\"" >&2
  echo "        Retry after editing it yourself; this wrapper will not change your config." >&2
  exit 2
}

CONFIG_EFFORT_LAYER=""
if [[ -n "$CONFIG_ONLY_EFFORT" ]]; then
  # An absent project file is normal and falls through to the global config.
  # Preserve the specific missing-file failure even when no TOML parser exists.
  if [[ ! -e "$PROJECT_CONFIG" && ! -e "$CONFIG" ]]; then
    config_effort_failure "the configured effort could not be determined: $CONFIG does not exist"
  fi
  if [[ -e "$PROJECT_CONFIG" && ! -f "$PROJECT_CONFIG" ]]; then
    config_effort_failure "the configured effort could not be determined: $PROJECT_CONFIG is not a regular file"
  fi
  if [[ ! -e "$PROJECT_CONFIG" && -e "$CONFIG" && ! -f "$CONFIG" ]]; then
    config_effort_failure "the configured effort could not be determined: $CONFIG is not a regular file"
  fi
  if [[ -z "$TOML_PYTHON" ]]; then
    config_effort_failure "the configured effort could not be determined: python3 with tomllib (3.11+) is unavailable"
  fi

  CONFIG_EFFORT_DETAIL=""
  if ! CONFIG_EFFORT_DETAIL="$("$TOML_PYTHON" - \
      "$PROJECT_CONFIG" "$CONFIG" "$CONFIG_ONLY_EFFORT" 2>/dev/null <<'PY'
import os
import sys
import tomllib

project_path, global_path, requested = sys.argv[1:]
key = "model_reasoning_effort"


def fail(message):
    print(message)
    raise SystemExit(1)


def load_config(path, *, required):
    if not os.path.exists(path):
        if required:
            fail(f"the configured effort could not be determined: {path} does not exist")
        return None
    if not os.path.isfile(path):
        fail(f"the configured effort could not be determined: {path} is not a regular file")
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except tomllib.TOMLDecodeError:
        fail(f"the configured effort could not be determined: {path} is not valid TOML")
    except OSError:
        fail(f"the configured effort could not be determined: {path} could not be read")
    except Exception:
        fail(
            "the configured effort could not be determined: "
            f"the TOML parser failed while reading {path}"
        )


def assert_value(data, path):
    actual = data[key]
    if not isinstance(actual, str) or actual.strip().lower() != requested:
        fail(f"{path} has top-level {key} = {actual!r}")


project_data = load_config(project_path, required=False)
if project_data is not None and key in project_data:
    assert_value(project_data, project_path)
    # The project key wins, but an existing lower-precedence file must still be
    # readable, valid TOML before this fail-closed assertion can pass.
    load_config(global_path, required=False)
    print("project")
    raise SystemExit(0)

global_data = load_config(global_path, required=True)
if key in global_data:
    assert_value(global_data, global_path)
    print("global")
    raise SystemExit(0)

if project_data is None:
    missing_detail = global_path
else:
    missing_detail = f"both {project_path} and {global_path}"
fail(
    "the configured effort could not be determined: "
    f"top-level {key} is absent in {missing_detail}"
)
PY
)"; then
    [[ -n "$CONFIG_EFFORT_DETAIL" ]] || \
      CONFIG_EFFORT_DETAIL="the configured effort could not be determined: the TOML parser failed while resolving $PROJECT_CONFIG before $CONFIG"
    config_effort_failure "$CONFIG_EFFORT_DETAIL"
  fi
  case "$CONFIG_EFFORT_DETAIL" in
    project|global) CONFIG_EFFORT_LAYER="$CONFIG_EFFORT_DETAIL" ;;
    *) config_effort_failure "the configured effort could not be determined: the TOML parser returned an unknown config layer" ;;
  esac
fi

# MCP servers and app connectors run OUTSIDE the exec sandbox in EVERY mode:
# `workspace-write` and `read-only` bound files and shell, not tool calls
# that reach external services — a read-only investigation can still mutate
# remote state through an auto-approved tool. The companion (checked against
# 1.0.6) has no per-dispatch switch to disable them, so any dispatch stops
# until the user acknowledges the exposure once for this environment.
#
# Detection is a best-effort tripwire over the LOCAL config layers, not a
# boundary: it dedupes nested tables to one entry per server/connector and
# honors `enabled = false`, but it cannot see Apps enabled server-side or
# tools injected by other config layers. Its silence is NOT proof of
# isolation, and prompt-level prohibitions are a second layer, never the
# boundary.
# The scan uses a REAL TOML parser (tomllib, python 3.11+) and nothing
# else: regex scanning of TOML is unsound — legal shapes like indented
# headers, dotted keys with whitespace around the dots, and inline tables
# all evade line patterns. When no parser is available, or the parser
# itself fails, the config is UNVERIFIABLE and the dispatch fails closed;
# a config that parses but doesn't type-check (unparseable content) is
# reported as exposure. `enabled = false` is honored only at the
# server/connector root: the schema also allows per-tool `enabled`, and
# one disabled tool must not hide a connector whose other tools stay
# callable.
scan_config_tools() { # $1=config path; prints identities; rc 3 = cannot verify
  [[ -f "$1" ]] || return 0
  [[ -n "$TOML_PYTHON" ]] || return 3
  local scanned=""
  if ! scanned="$("$TOML_PYTHON" - "$1" 2>/dev/null <<'PY'
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        data = tomllib.load(handle)
except Exception:
    print("(unparseable Codex config - treated as exposure)")
    raise SystemExit(0)

for family in ("mcp_servers", "apps"):
    table = data.get(family)
    if not isinstance(table, dict):
        continue
    for name, entry in table.items():
        if isinstance(entry, dict) and entry.get("enabled") is False:
            continue
        print(f"[{family}.{name}]")
PY
)"; then
    return 3
  fi
  [[ -z "$scanned" ]] || printf '%s\n' "$scanned"
  return 0
}

EXTERNAL_TOOLS=""
TOOL_SCAN_FAILED=0
NEWLINE=$'\n'
for TOOL_CONFIG in "$CONFIG" "$PWD/.codex/config.toml"; do
  if TOOL_SCAN_OUTPUT="$(scan_config_tools "$TOOL_CONFIG")"; then
    [[ -z "$TOOL_SCAN_OUTPUT" ]] || \
      EXTERNAL_TOOLS="${EXTERNAL_TOOLS}${EXTERNAL_TOOLS:+$NEWLINE}$TOOL_SCAN_OUTPUT"
  else
    TOOL_SCAN_FAILED=1
  fi
done
# Disclose by default, refuse only on request. A check that blocks every
# dispatch on a normal developer machine gets silenced wholesale, which
# costs more than it protects — so the finding is surfaced every run and
# `CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1` is there for repos where an external
# side effect is genuinely unacceptable.
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

ARGS=(task)
# Write access is what makes this an implementation run. Withholding it is
# an explicit mode, not a fallback — say which one is in effect so a
# read-only run is never mistaken for an implementation that changed nothing.
[[ $READ_ONLY -eq 1 ]] || ARGS+=(--write)
[[ $BACKGROUND -eq 1 ]] && ARGS+=(--background)
# Forward only what was actually chosen; anything omitted is left to the
# Codex CLI so it resolves from the user's config rather than a default
# invented here.
[[ -n "$MODEL"  ]] && ARGS+=(--model "$MODEL")
[[ -n "$EFFORT" && -z "$CONFIG_ONLY_EFFORT" ]] && ARGS+=(--effort "$EFFORT")
[[ $RESUME -eq 1 ]] && ARGS+=(--resume-last)

# Read a key only from the TOP-LEVEL region of a TOML config (above the
# first [section]). A plain grep would happily return a key that lives
# inside some [section] table (a profile or server block) and display a
# value that is not in effect.
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
  project_value="$(top_level_value "$PWD/.codex/config.toml" "$3")"
  global_value="$(top_level_value "$CONFIG" "$3")"
  if [[ -n "$project_value" ]]; then
    echo "$1: $project_value (project .codex/config.toml top-level; other config layers not resolved)"
  elif [[ -n "$global_value" ]]; then
    echo "$1: $global_value (config.toml top-level; other config layers not resolved)"
  else
    echo "$1: <Codex CLI default>"
  fi
}

echo "companion: $COMPANION ($COMPANION_SOURCE)" >&2
echo "workspace: $(pwd)" >&2
# Surface the CLI version on every dispatch: a stale codex is the usual
# reason a newly released model "doesn't exist", and skew between multiple
# installs is invisible unless someone prints what's actually running.
command -v codex >/dev/null 2>&1 && echo "codex  : $(codex --version 2>/dev/null || echo '?')" >&2
describe "model " "$MODEL"  "model" >&2
if [[ -n "$CONFIG_ONLY_EFFORT" ]]; then
  if [[ "$CONFIG_EFFORT_LAYER" == "project" ]]; then
    CONFIG_EFFORT_LABEL="project .codex/config.toml"
  else
    CONFIG_EFFORT_LABEL="config.toml"
  fi
  echo "effort: $CONFIG_ONLY_EFFORT (assertion matched $CONFIG_EFFORT_LABEL top-level; other config layers not resolved)" >&2
else
  describe "effort" "$EFFORT" "model_reasoning_effort" >&2
fi
# Tier has no per-task flag — always inherited — so show what will apply.
# Profile/overlay mechanics have changed across Codex CLI versions; rather
# than guess which scheme is installed, the labels above say plainly that
# only top-level keys are read and the CLI's own resolution is authoritative.
describe "tier  " ""        "service_tier" >&2
if [[ $READ_ONLY -eq 1 ]]; then
  echo "mode  : READ-ONLY (no file writes; nothing to review/gate/publish)" >&2
else
  echo "mode  : implement (--write)" >&2
fi
echo "resume: $RESUME  background: $BACKGROUND" >&2

# The `--` terminator is load-bearing: it guarantees the companion sees at
# least two trailing arguments and treats everything after it as literal
# positional text, so tokens inside the prompt can never parse as flags.
exec node "$COMPANION" "${ARGS[@]}" -- "$PROMPT"
