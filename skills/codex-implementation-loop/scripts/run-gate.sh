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
# Exit: without --baseline, the suite's exit code. With --baseline, 0 when
# the suite passes or all parsed failures match the baseline and tests ran.

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

normalize_path() { # $1=path; the file itself need not exist
  local path="$1"
  local directory filename

  if [[ "$path" == */* ]]; then
    directory="${path%/*}"
    filename="${path##*/}"
    [[ -n "$directory" ]] || directory="/"
  else
    directory="."
    filename="$path"
  fi

  if directory="$(cd "$directory" 2>/dev/null && pwd -P)"; then
    [[ "$directory" == "/" ]] && directory=""
    printf '%s/%s\n' "$directory" "$filename"
  elif [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

# Never overwrite the evidence before reading it. Normalized strings catch
# equal paths even when the log does not exist yet; -ef also catches existing
# symlink, hardlink, and alternate-relative-path aliases.
if [[ -n "$BASELINE" ]]; then
  NORMALIZED_LOG="$(normalize_path "$LOG")"
  NORMALIZED_BASELINE="$(normalize_path "$BASELINE")"
  if [[ "$NORMALIZED_LOG" == "$NORMALIZED_BASELINE" ]] ||
     [[ -e "$LOG" && "$LOG" -ef "$BASELINE" ]]; then
    echo "error: --log and --baseline refer to the same file; use separate paths" >&2
    exit 2
  fi
fi

echo "gate: $*" >&2
echo "log:  $LOG" >&2

# Emit stable failure identifiers from unittest headers and pytest's short
# summary. unittest FAIL:/ERROR: headers contain no exception information, so
# those remain ID-only. For pytest, retain the exception class but discard its
# message so message-only changes still match while changed failure types do not.
extract_failures() { # $1=log path
  awk '
    /^FAIL: / || /^ERROR: / { print; next }
    /^FAILED \(/ || /^ERROR \(/ { next }
    /^FAILED / || /^ERROR / {
      line = $0
      if (match(line, /[[:space:]]+-[[:space:]]+/)) {
        identifier = substr(line, 1, RSTART - 1)
        exception = substr(line, RSTART + RLENGTH)
        sub(/[[:space:]:].*$/, "", exception)
        line = identifier
        if (exception != "") line = line " [" exception "]"
      }
      print line
    }
  ' "$1" 2>/dev/null
}

tests_ran() { # $1=log path
  awk '
    /^Ran [0-9]+ tests?/ {
      if (($2 + 0) > 0) ran = 1
    }
    {
      line = tolower($0)
      if (line !~ /no tests ran/ &&
          line ~ /[1-9][0-9]*[[:space:]]+(passed|failed|xfailed|xpassed)([^[:alpha:]]|$)/) {
        ran = 1
      }
    }
    END { exit(ran ? 0 : 1) }
  ' "$1" 2>/dev/null
}

zero_tests_reported() { # $1=log path
  grep -Eqi '(^Ran 0 tests?([[:space:]]|$)|no tests ran)' "$1" 2>/dev/null
}

supported_runner_summary() { # $1=log path
  awk '
    /^Ran [0-9]+ tests?/ { recognized = 1 }
    {
      line = tolower($0)
      sub(/^[[:space:]]*=+[[:space:]]*/, "", line)
      if (line ~ /^no tests ran([^[:alpha:]]|$)/ ||
          line ~ /^[0-9]+[[:space:]]+(passed|failed|skipped|deselected|xfailed|xpassed|error|errors|warning|warnings)([^[:alpha:]]|$)/) {
        recognized = 1
      }
    }
    END { exit(recognized ? 0 : 1) }
  ' "$1" 2>/dev/null
}

START=$SECONDS
# Output goes to a file, never through a pipe, so $? is the suite's own.
"$@" > "$LOG" 2>&1
STATUS=$?
ELAPSED=$((SECONDS - START))

echo "=== gate finished in ${ELAPSED}s with exit code ${STATUS} ==="

# Surface the shapes most runners use for their summary line.
grep -E '^(Ran [0-9]+ |OK\b|FAILED\b|ERROR\b|=+ .*(passed|failed|no tests ran).* =+)' "$LOG" | tail -5

CURRENT_FAILURES="$(extract_failures "$LOG" || true)"
FAILURES=0
if [[ -n "$CURRENT_FAILURES" ]]; then
  while IFS= read -r _failure; do
    FAILURES=$((FAILURES + 1))
  done <<< "$CURRENT_FAILURES"
fi
if [[ $FAILURES -gt 0 ]]; then
  echo "--- ${FAILURES} failure/error header(s) ---"
  awk 'NR <= 40' <<< "$CURRENT_FAILURES"
fi

# A gate is only meaningful against a baseline: the bar is "no NEW
# non-flake failures", not "zero failures", on suites with known
# environment flakes. Compare rather than eyeballing when possible.
NEW_FAILURES=""
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  echo "--- failures not present in baseline ($BASELINE) ---"
  NEW_FAILURES="$(comm -13 \
    <(extract_failures "$BASELINE" | sort -u) \
    <(extract_failures "$LOG"      | sort -u) \
    || true)"
  [[ -z "$NEW_FAILURES" ]] || printf '%s\n' "$NEW_FAILURES"
elif [[ -n "$BASELINE" ]]; then
  echo "--- baseline not found ($BASELINE) ---"
fi

# With no baseline, retain the original pass-through behavior exactly.
if [[ -z "$BASELINE" ]]; then
  if [[ $STATUS -eq 0 ]]; then
    echo "RESULT: gate green"
  else
    echo "RESULT: gate RED — do not publish until resolved or explained"
  fi
  exit "$STATUS"
fi

# A nonzero run with no recognizable failures is never baseline-clean. Check
# this before the explicit zero-test case so pytest's exit-5/no-tests result
# also gets the more diagnostic crash/collection-error message.
if [[ $STATUS -ne 0 && $FAILURES -eq 0 ]]; then
  echo "RESULT: gate RED — nonzero exit with no parseable failures (crash/collection error?)"
  exit "$STATUS"
fi

if [[ $STATUS -eq 0 ]]; then
  if ! supported_runner_summary "$LOG"; then
    echo "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only"
    exit 1
  fi
  if zero_tests_reported "$LOG" || ! tests_ran "$LOG"; then
    echo "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output"
    exit 1
  fi
  echo "RESULT: gate green"
  exit 0
fi

# Keep the explicit diagnostic for nonzero zero-test runs. A zero-exit run was
# already checked above with the stricter executed-test requirement.
if zero_tests_reported "$LOG"; then
  echo "RESULT: gate RED — no tests ran"
  exit 1
fi

if ! tests_ran "$LOG"; then
  echo "RESULT: gate RED — failures parsed but no completed tests were reported"
elif [[ ! -f "$BASELINE" || -n "$NEW_FAILURES" ]]; then
  echo "RESULT: gate RED — do not publish until resolved or explained"
else
  echo "RESULT: gate green (failures match baseline — no new failures)"
  exit 0
fi

exit "$STATUS"
