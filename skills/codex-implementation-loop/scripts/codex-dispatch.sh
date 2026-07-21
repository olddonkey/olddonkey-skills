#!/usr/bin/env bash
# Dispatch an implementation task to Codex via the codex-companion runtime.
#
# Locates the active installed companion (with cache fallbacks) so you don't
# rediscover the path when plugin versions change, and rejects the invalid
# --effort value that the wrapper silently refuses.
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
# user's own ~/.codex/config.toml — which is both the most respectful
# default and the only way to reach efforts the wrapper flag rejects
# (ultra, max). Set CODEX_LOOP_MODEL / CODEX_LOOP_EFFORT to give one
# project a standing preference without editing this script or the
# user's global config.
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

# `ultra` and `max` are real Codex efforts but (as of 1.0.6) reachable only
# via model_reasoning_effort in config.toml — passing either as a flag fails
# the whole dispatch. Omit --effort to inherit whatever the user configured.
if [[ -n "$EFFORT" && " $VALID_EFFORTS " != *" $EFFORT "* ]]; then
  echo "invalid --effort '$EFFORT'; this companion accepts: $VALID_EFFORTS" >&2
  if [[ "$EFFORT" == "max" || "$EFFORT" == "ultra" ]]; then
    echo "note: '$EFFORT' exists, but only as model_reasoning_effort in ~/.codex/config.toml." >&2
    echo "      To use it, omit --effort so the CLI inherits the user's config." >&2
    echo "      Don't edit their global config to force it — that changes their own Codex use." >&2
  fi
  exit 2
fi

CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"

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
# Prefer a real TOML parser (tomllib, python 3.11+): a regex scan misses
# legal TOML shapes — indented table headers, top-level dotted keys, inline
# tables. When tomllib is unavailable the awk fallback covers those shapes
# line-wise; either way an unparseable or ambiguous config counts as
# exposure, never as silence. `enabled = false` is honored only at the
# server/connector root: the schema also allows per-tool `enabled`, and one
# disabled tool must not hide a connector whose other tools stay callable.
external_tool_sections() { # $1=config path
  [[ -f "$1" ]] || return 0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    python3 - "$1" 2>/dev/null <<'PY' || true
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
    return 0
  fi
  LC_ALL=C awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
    }
    line ~ /^\[(mcp_servers|apps)[].]/ {
      section = line
      sub(/^\[/, "", section)
      sub(/\].*$/, "", section)
      depth = split(section, segments, ".")
      identity = segments[1]
      if (segments[2] != "") identity = segments[1] "." segments[2]
      current = identity
      current_is_root = (depth == 2) ? 1 : 0
      if (!(identity in seen)) { seen[identity] = 1; order[++count] = identity }
      next
    }
    line ~ /^\[/ { current = ""; current_is_root = 0; next }
    line ~ /^(mcp_servers|apps)\.[^[:space:]=.]+/ && line ~ /=/ {
      keypath = line
      sub(/[[:space:]]*=.*$/, "", keypath)
      depth = split(keypath, segments, ".")
      identity = segments[1] "." segments[2]
      if (!(identity in seen)) { seen[identity] = 1; order[++count] = identity }
      if (depth == 3 && segments[3] == "enabled" &&
          line ~ /=[[:space:]]*false[[:space:]]*$/) disabled[identity] = 1
      next
    }
    line ~ /^(mcp_servers|apps)[[:space:]]*=/ {
      family = line
      sub(/[[:space:]]*=.*$/, "", family)
      if (!(family in seen)) { seen[family] = 1; order[++count] = family }
      next
    }
    current != "" && current_is_root &&
      line ~ /^enabled[[:space:]]*=[[:space:]]*false/ {
      disabled[current] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        if (!(order[i] in disabled)) print "[" order[i] "]"
      }
    }
  ' "$1" 2>/dev/null || true
}
EXTERNAL_TOOLS="$(external_tool_sections "$CONFIG"; external_tool_sections "$PWD/.codex/config.toml")"
if [[ -n "$EXTERNAL_TOOLS" ]]; then
  if [[ "${CODEX_LOOP_ALLOW_EXTERNAL_TOOLS:-0}" != "1" ]]; then
    echo "error: dispatch blocked — Codex config enables external tools that the exec sandbox does NOT cover (in any mode, including read-only):" >&2
    printf '%s\n' "$EXTERNAL_TOOLS" | LC_ALL=C sed 's/^/  /' >&2
    echo "Tool calls reach external services regardless of the filesystem sandbox." >&2
    echo "This scan covers local config layers only — server-side-enabled Apps are invisible" >&2
    echo "to it, so passing this check is not proof of isolation." >&2
    echo "Export CODEX_LOOP_ALLOW_EXTERNAL_TOOLS=1 to acknowledge the exposure once for this" >&2
    echo "environment, or disable those tools in the Codex config while running the loop." >&2
    exit 4
  fi
  echo "note  : external tools enabled in Codex config (outside the sandbox, all modes)" >&2
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
[[ -n "$EFFORT" ]] && ARGS+=(--effort "$EFFORT")
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
describe "effort" "$EFFORT" "model_reasoning_effort" >&2
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
