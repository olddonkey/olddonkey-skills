#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
echo "deprecated: scripts/codex-dispatch.sh forwards to backends/codex/dispatch.sh and will be removed in release 0.5.0" >&2
exec "$SCRIPT_DIR/../backends/codex/dispatch.sh" "$@"
