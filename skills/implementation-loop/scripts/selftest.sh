#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
echo "deprecated: scripts/selftest.sh forwards to the Codex and gate suites and will be removed in release 0.5.0" >&2
"$SCRIPT_DIR/../backends/codex/selftest.sh" "$@"
STATUS=$?
[[ $STATUS -eq 0 ]] || exit "$STATUS"
exec "$SCRIPT_DIR/../tests/gate-selftest.sh" "$@"
