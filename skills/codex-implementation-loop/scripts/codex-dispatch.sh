#!/usr/bin/env bash
# Dispatch an implementation task to Codex via the codex-companion runtime.
#
# Locates the newest installed companion so you don't rediscover the path
# (it moves with every plugin version bump), and rejects the invalid
# --effort value that the wrapper silently refuses.
#
# Usage:
#   codex-dispatch.sh --prompt-file PATH [--read-only|--investigate] [--background]
#                     [--model MODEL] [--effort LEVEL] [--resume] [-- EXTRA...]
#   codex-dispatch.sh --prompt "short inline prompt" [...]
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
EXTRA=()

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
    --)            shift; EXTRA=("$@"); break ;;
    *)             echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[[ -n "$PROMPT" ]] || { echo "need --prompt-file or --prompt" >&2; usage 1; }

# Companion lives in the plugin cache and moves with each version bump.
COMPANION="$(find "$HOME/.claude/plugins/cache" \
                  -name codex-companion.mjs -type f 2>/dev/null \
             | sort -V | tail -1)"
if [[ -z "$COMPANION" ]]; then
  COMPANION="$(find "$HOME/.claude/plugins/marketplaces" \
                    -name codex-companion.mjs -type f 2>/dev/null | tail -1)"
fi
[[ -n "$COMPANION" ]] || {
  echo "codex-companion.mjs not found; is the Codex plugin installed?" >&2
  exit 3
}

# Ask the INSTALLED companion which efforts it accepts — the list changes
# across plugin versions, so read it at runtime instead of freezing a copy
# here. Falls back to the snapshot above if the usage string moves.
DETECTED_EFFORTS="$(grep -oE -- '--effort <[a-z|]+>' "$COMPANION" 2>/dev/null \
                    | head -1 | sed -E 's/.*<([a-z|]+)>.*/\1/' | tr '|' ' ')"
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
[[ ${#EXTRA[@]} -gt 0 ]] && ARGS+=("${EXTRA[@]}")

CONFIG="$HOME/.codex/config.toml"
describe() { # $1=label $2=chosen value $3=config key
  if [[ -n "$2" ]]; then
    echo "$1: $2 (explicit)"
  elif [[ -f "$CONFIG" ]] && grep -qE "^[[:space:]]*$3[[:space:]]*=" "$CONFIG"; then
    echo "$1: $(grep -E "^[[:space:]]*$3[[:space:]]*=" "$CONFIG" | head -1 | cut -d= -f2- | tr -d ' \"') (inherited from config.toml)"
  else
    echo "$1: <Codex CLI default>"
  fi
}

echo "companion: $COMPANION" >&2
echo "workspace: $(pwd)" >&2
# Surface the CLI version on every dispatch: a stale codex is the usual
# reason a newly released model "doesn't exist", and skew between multiple
# installs is invisible unless someone prints what's actually running.
command -v codex >/dev/null 2>&1 && echo "codex  : $(codex --version 2>/dev/null || echo '?')" >&2
describe "model " "$MODEL"  "model" >&2
describe "effort" "$EFFORT" "model_reasoning_effort" >&2
# Tier has no per-task flag — always inherited — so show what will apply.
describe "tier  " ""        "service_tier" >&2
if [[ $READ_ONLY -eq 1 ]]; then
  echo "mode  : READ-ONLY (no file writes; nothing to review/gate/publish)" >&2
else
  echo "mode  : implement (--write)" >&2
fi
echo "resume: $RESUME  background: $BACKGROUND" >&2

exec node "$COMPANION" "${ARGS[@]}" "$PROMPT"
