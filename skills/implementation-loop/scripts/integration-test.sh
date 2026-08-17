#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
echo "deprecated: scripts/integration-test.sh forwards to tests/integration-test.sh and will be removed in release 0.5.0" >&2

TRANSLATED=0
SELECTOR_SEEN=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      SELECTOR_SEEN=1
      ARGS+=("$1")
      shift
      if [[ $# -gt 0 ]]; then
        if [[ "$1" == "all" ]]; then
          ARGS+=(grok --backend cursor)
          TRANSLATED=1
        else
          ARGS+=("$1")
        fi
        shift
      fi
      ;;
    --require)
      SELECTOR_SEEN=1
      ARGS+=("$1")
      shift
      if [[ $# -gt 0 ]]; then ARGS+=("$1"); shift; fi
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ $SELECTOR_SEEN -eq 0 ]]; then
  if [[ ${#ARGS[@]} -gt 0 ]]; then
    ARGS=(--backend grok --backend cursor "${ARGS[@]}")
  else
    ARGS=(--backend grok --backend cursor)
  fi
  TRANSLATED=1
fi
if [[ $TRANSLATED -eq 1 ]]; then
  echo "compatibility: translated legacy backend selection to grok+cursor" >&2
fi
exec "$SCRIPT_DIR/../tests/integration-test.sh" "${ARGS[@]}"
