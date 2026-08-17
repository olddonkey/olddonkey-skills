#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
echo "deprecated: scripts/grok-selftest.sh forwards to backends/grok/selftest.sh and will be removed in release 0.5.0" >&2
exec "$SCRIPT_DIR/../backends/grok/selftest.sh" "$@"
