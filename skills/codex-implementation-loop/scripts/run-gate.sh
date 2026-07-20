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
# Exit: without --baseline, the suite's exit code unless an exit-zero runner
# reports failures in its own summary. With --baseline, 0 when the suite passes
# or all parsed failures match the baseline and tests ran.

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

resolve_symlink_path() { # $1=normalized path; resolves dangling link targets too
  local path="$1"
  local target directory
  local links=0

  while [[ -L "$path" ]]; do
    links=$((links + 1))
    [[ $links -le 40 ]] || break
    target="$(readlink "$path" 2>/dev/null)" || break
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      directory="${path%/*}"
      [[ -n "$directory" ]] || directory="/"
      path="$directory/$target"
    fi
    path="$(normalize_path "$path")"
  done

  printf '%s\n' "$path"
}

# Never overwrite the evidence before reading it. Normalized strings catch
# equal paths even when the log does not exist yet; resolved strings also catch
# dangling symlinks, while -ef catches existing hardlink and filesystem aliases.
if [[ -n "$BASELINE" ]]; then
  NORMALIZED_LOG="$(normalize_path "$LOG")"
  NORMALIZED_BASELINE="$(normalize_path "$BASELINE")"
  RESOLVED_LOG="$(resolve_symlink_path "$NORMALIZED_LOG")"
  RESOLVED_BASELINE="$(resolve_symlink_path "$NORMALIZED_BASELINE")"
  if [[ "$NORMALIZED_LOG" == "$NORMALIZED_BASELINE" ]] ||
     [[ "$RESOLVED_LOG" == "$RESOLVED_BASELINE" ]] ||
     [[ -e "$LOG" && "$LOG" -ef "$BASELINE" ]]; then
    echo "error: --log and --baseline refer to the same file; use separate paths" >&2
    exit 2
  fi
fi

echo "gate: $*" >&2
echo "log:  $LOG" >&2

# pytest emits its formal summary either fenced (`=== 1 failed in 0.1s ===`)
# or, under -q, as a bare bottom line (`1 failed in 0.1s`). pytest_summary
# returns the lowercased summary content for either shape and "" otherwise.
# The bare form must match the full official shape — count list (native
# subtests add `N subtests passed/failed` terms) plus an `in <duration>s`
# tail — so ordinary log lines never qualify as a summary.
#
# Callers must treat only the LAST summary-shaped line as the run's verdict:
# the real runner always prints its summary at the very end, so anything
# earlier (an inner pytest run captured in test output, an application log
# line that happens to match) is not evidence about THIS run.
PYTEST_SUMMARY_AWK='
  function pytest_summary(line,    content) {
    content = tolower(line)
    if (content ~ /^=+ .* =+$/) {
      sub(/^=+[[:space:]]+/, "", content)
      sub(/[[:space:]]+=+$/, "", content)
      return content
    }
    if (content ~ /^(no tests ran|[0-9]+ (subtests )?(passed|failed|error|errors|skipped|deselected|xfailed|xpassed|warning|warnings)(, [0-9]+ (subtests )?(passed|failed|error|errors|skipped|deselected|xfailed|xpassed|warning|warnings))*) in [0-9]+(\.[0-9]+)?s( \([0-9:]+\))?$/) {
      return content
    }
    return ""
  }
'

# Emit stable failure identifiers from unittest headers and pytest's short
# summary. unittest FAIL:/ERROR: headers contain no exception information, so
# those remain ID-only. For unambiguous pytest lines, retain the exception class
# but discard its message so message-only changes still match. pytest 9 native
# subtests report the specific failing subtest as SUBFAILED(param)/SUBFAILED[msg]
# while the parent FAILED line stays constant, so SUBFAILED lines carry the
# real identity and must be fingerprinted too.
extract_failures() { # $1=log path
  awk '
    /^FAIL: / || /^ERROR: / { print; next }
    /^FAILED \(/ || /^ERROR \(/ { next }
    /^FAILED / || /^ERROR / || /^SUBFAILED/ {
      line = $0
      separator = 0
      separator_length = 0
      separator_count = 0
      for (i = 1; i <= length(line); i++) {
        if (match(substr(line, i), /^[[:space:]]+-[[:space:]]+/)) {
          separator_count++
          if (separator_count == 1) {
            separator = i
            separator_length = RLENGTH
          }
          i += RLENGTH - 1
        }
      }

      # IDs or messages containing " - " get whole-line identity. Message-only
      # changes in those lines therefore read as new failures: intentional fail-closed.
      if (separator_count == 1) {
        identifier = substr(line, 1, separator - 1)
        exception = substr(line, separator + separator_length)
        sub(/^[[:space:]]+/, "", exception)
        sub(/[[:space:]].*$/, "", exception)
        sub(/:$/, "", exception)
        if (exception ~ /^[A-Za-z_][A-Za-z0-9_.]*$/) {
          line = identifier " [" exception "]"
        }
      }
      print line
    }
  ' "$1" 2>/dev/null
}

tests_ran() { # $1=log path
  awk "$PYTEST_SUMMARY_AWK"'
    /^Ran [0-9]+ tests?/ {
      unittest_total += ($2 + 0)
    }
    /^OK([[:space:]]|$)/ || /^FAILED[[:space:]]+\(/ {
      result = $0
      if (match(result, /skipped=[0-9]+/)) {
        skipped = substr(result, RSTART, RLENGTH)
        sub(/^skipped=/, "", skipped)
        unittest_skipped += (skipped + 0)
      }
    }
    {
      summary = pytest_summary($0)
      if (summary != "") last_summary = summary
    }
    END {
      if (last_summary != "" &&
          last_summary !~ /^no tests ran([^[:alpha:]]|$)/ &&
          last_summary ~ /[1-9][0-9]*[[:space:]]+(subtests[[:space:]]+)?(passed|failed|xfailed|xpassed)([^[:alpha:]]|$)/) {
        ran = 1
      }
      if ((unittest_total - unittest_skipped) > 0) ran = 1
      exit(ran ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

zero_tests_reported() { # $1=log path
  awk "$PYTEST_SUMMARY_AWK"'
    /^Ran 0 tests?([[:space:]]|$)/ { zero = 1 }
    {
      summary = pytest_summary($0)
      if (summary != "") last_summary = summary
    }
    END {
      if (last_summary ~ /^no tests ran([^[:alpha:]]|$)/) zero = 1
      exit(zero ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

supported_runner_summary() { # $1=log path
  awk "$PYTEST_SUMMARY_AWK"'
    /^Ran [0-9]+ tests?/ { recognized = 1 }
    {
      summary = pytest_summary($0)
      if (summary != "") last_summary = summary
    }
    END {
      if (last_summary != "" &&
          (last_summary ~ /^no tests ran([^[:alpha:]]|$)/ ||
           last_summary ~ /[0-9]+[[:space:]]+(subtests[[:space:]]+)?(passed|failed|skipped|deselected|xfailed|xpassed|error|errors|warning|warnings)([^[:alpha:]]|$)/)) {
        recognized = 1
      }
      exit(recognized ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

# Positive failed/error counts (including subtest terms) in the FINAL summary
# contradict an exit-zero run. Earlier summary-shaped lines belong to inner
# runs or application output, never to this run's verdict.
failed_summary_present() { # $1=log path
  awk "$PYTEST_SUMMARY_AWK"'
    /^FAILED \(/ { failed = 1 }
    {
      summary = pytest_summary($0)
      if (summary != "") last_summary = summary
    }
    END {
      while (match(last_summary, /[0-9]+[[:space:]]+(subtests[[:space:]]+)?(failed|error|errors)([^[:alpha:]]|$)/)) {
        count = substr(last_summary, RSTART, RLENGTH)
        sub(/[[:space:]].*$/, "", count)
        if ((count + 0) > 0) failed = 1
        last_summary = substr(last_summary, RSTART + RLENGTH)
      }
      exit(failed ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

# Freeze the comparison evidence before the command can mutate either path.
# Every post-run baseline decision uses these values, never the live file.
BASELINE_EXISTS_AT_START=0
BASELINE_FAILURES_AT_START=""
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  BASELINE_EXISTS_AT_START=1
  BASELINE_FAILURES_AT_START="$(extract_failures "$BASELINE" | sort -u || true)"
fi

START=$SECONDS
# Output goes to a file, never through a pipe, so $? is the suite's own.
"$@" > "$LOG" 2>&1
STATUS=$?
ELAPSED=$((SECONDS - START))

echo "=== gate finished in ${ELAPSED}s with exit code ${STATUS} ==="

# Surface the shapes most runners use for their summary line.
grep -E '^(Ran [0-9]+ |OK\b|FAILED\b|ERROR\b|SUBFAILED\b|=+ .*(passed|failed|no tests ran).* =+|(no tests ran|[0-9]+ [a-z]+(, [0-9]+ [a-z]+)*) in [0-9]+(\.[0-9]+)?s)' "$LOG" | tail -5

CURRENT_FAILURES="$(extract_failures "$LOG" || true)"
FAILED_SUMMARY=0
if failed_summary_present "$LOG"; then
  FAILED_SUMMARY=1
fi
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
if [[ -n "$BASELINE" && $BASELINE_EXISTS_AT_START -eq 1 ]]; then
  echo "--- failures not present in baseline ($BASELINE) ---"
  NEW_FAILURES="$(comm -13 \
    <(printf '%s\n' "$BASELINE_FAILURES_AT_START" | sort -u) \
    <(printf '%s\n' "$CURRENT_FAILURES"           | sort -u) \
    || true)"
  [[ -z "$NEW_FAILURES" ]] || printf '%s\n' "$NEW_FAILURES"
elif [[ -n "$BASELINE" ]]; then
  echo "--- baseline not found ($BASELINE) ---"
fi

# A runner summary and its exit status must agree in every mode.
if [[ $STATUS -eq 0 && $FAILED_SUMMARY -eq 1 ]]; then
  echo "RESULT: gate RED — runner summary reports failures but exit code is 0"
  exit 1
fi

# With no baseline, otherwise retain the suite's pass-through status.
if [[ -z "$BASELINE" ]]; then
  if [[ $STATUS -eq 0 ]]; then
    echo "RESULT: gate green"
  else
    echo "RESULT: gate RED — do not publish until resolved or explained"
  fi
  exit "$STATUS"
fi

# Baseline mode additionally distrusts any parsed failure line paired with a
# successful process status, even when the runner emitted no failed summary.
if [[ $STATUS -eq 0 && $FAILURES -gt 0 ]]; then
  echo "RESULT: gate RED — exit 0 but failure lines present (is the runner masking its exit code?)"
  exit 1
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
elif [[ $BASELINE_EXISTS_AT_START -eq 0 || -n "$NEW_FAILURES" ]]; then
  echo "RESULT: gate RED — do not publish until resolved or explained"
else
  echo "RESULT: gate green (failures match baseline — no new failures)"
  exit 0
fi

exit "$STATUS"
