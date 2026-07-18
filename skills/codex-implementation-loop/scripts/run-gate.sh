#!/usr/bin/env bash
# Run a test suite as a merge gate and report the REAL exit code.
#
# Why this exists: piping a test run through `tail`/`head` makes the
# pipeline's exit status that of the pager, so a failing suite reports
# success. That mistake is easy to make and expensive to catch — it can
# let a red suite through the gate entirely.
#
# This runs the command with output going to a log file (never a pipe),
# captures the true status, and prints a summary plus any failure headers.
#
# Usage:
#   run-gate.sh [--log PATH] [--baseline PATH] -- <test command...>
#
# Example:
#   run-gate.sh --log /tmp/gate.log -- python -m unittest discover -s tests
#
# Run it as a background job for long suites; read the log when it lands.
#
# Exit: 0 if the suite passed, otherwise the suite's own exit code.

set -uo pipefail

LOG=""
BASELINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)      LOG="${2:?--log needs a path}"; shift 2 ;;
    --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)         shift; break ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $# -gt 0 ]] || { echo "need a test command after --" >&2; exit 2; }
# The file mktemp creates IS the log — appending a suffix would orphan it.
[[ -n "$LOG" ]] || LOG="$(mktemp -t gate.XXXXXX)"

echo "gate: $*" >&2
echo "log:  $LOG" >&2

START=$SECONDS
# Output goes to a file, never through a pipe, so $? is the suite's own.
"$@" > "$LOG" 2>&1
STATUS=$?
ELAPSED=$((SECONDS - START))

echo "=== gate finished in ${ELAPSED}s with exit code ${STATUS} ==="

# Surface the shapes most runners use for their summary line.
grep -E '^(Ran [0-9]+ |OK\b|FAILED\b|=+ .*(passed|failed).* =+)' "$LOG" | tail -5

FAILURES="$(grep -cE '^(FAIL|ERROR):' "$LOG" 2>/dev/null || true)"
if [[ "${FAILURES:-0}" -gt 0 ]]; then
  echo "--- ${FAILURES} failure/error header(s) ---"
  grep -E '^(FAIL|ERROR):' "$LOG" | head -40
fi

# A gate is only meaningful against a baseline: the bar is "no NEW
# non-flake failures", not "zero failures", on suites with known
# environment flakes. Compare rather than eyeballing when possible.
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  echo "--- failures not present in baseline ($BASELINE) ---"
  comm -13 \
    <(grep -E '^(FAIL|ERROR):' "$BASELINE" | sort -u) \
    <(grep -E '^(FAIL|ERROR):' "$LOG"      | sort -u) \
    || true
fi

if [[ $STATUS -eq 0 ]]; then
  echo "RESULT: gate green"
else
  echo "RESULT: gate RED — do not publish until resolved or explained"
fi

exit $STATUS
