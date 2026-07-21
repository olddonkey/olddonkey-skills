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
#   run-gate.sh [--strict] [--log PATH] [--baseline PATH] -- <test command...>
#
# Modes (--strict and --baseline are mutually exclusive):
#   (default)   pass-through — works with ANY runner. The suite's exit code is
#               the verdict, with one override: a recognized unittest/pytest
#               summary reporting failures against exit 0 forces red. This is
#               the WEAKEST mode (empty output and zero-test runs pass); use
#               it only for runners the parser does not understand.
#   --strict    zero failures, enforced — unittest/pytest only. Requires a
#               recognized runner verdict, executed tests (skipped-only and
#               zero-test runs are red), and no parsed failure lines at all.
#   --baseline  no NEW failures vs the baseline log — unittest/pytest only;
#               skipped-only, empty, or unparseable runs fail closed.
#
# Example:
#   run-gate.sh --strict --log /tmp/gate.log -- python -m unittest discover -s tests
#
# Run it as a background job for long suites; read the log when it lands.

set -uo pipefail

LOG=""
BASELINE=""
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)      LOG="${2:?--log needs a path}"; shift 2 ;;
    --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
    --strict)   STRICT=1; shift ;;
    -h|--help)  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    --)         shift; break ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ $STRICT -eq 1 && -n "$BASELINE" ]]; then
  echo "error: --strict and --baseline are mutually exclusive; pick one policy" >&2
  exit 2
fi

[[ $# -gt 0 ]] || { echo "need a test command after --" >&2; exit 2; }
# The file mktemp creates IS the log — appending a suffix would orphan it.
[[ -n "$LOG" ]] || LOG="$(mktemp -t gate.XXXXXX)"

# All parsing reads an ANSI-stripped view of the raw bytes: forced-color
# runners (`pytest --color=yes`) wrap their summary lines in CSI sequences
# that would otherwise defeat every anchored pattern. The log on disk keeps
# the original bytes.
#
# Every parser runs under LC_ALL=C: test logs are arbitrary bytes, and in a
# UTF-8 locale one invalid byte makes sed/awk/grep abort or misread — an
# empty parse view would then hide a failed summary behind a masked exit
# code. Bytewise processing is the only locale that can't be poisoned by
# log content. strip_ansi failures are checked by callers and fail closed.
PARSE_LOG="$(mktemp -t gate-parse.XXXXXX)" || exit 2
BASELINE_PARSE="$(mktemp -t gate-parse.XXXXXX)" || exit 2
trap 'rm -f "$PARSE_LOG" "$BASELINE_PARSE"' EXIT
ANSI_ESC="$(printf '\033')"
strip_ansi() { # $1=source path, $2=destination path
  LC_ALL=C sed "s/${ANSI_ESC}\\[[0-9;]*[A-Za-z]//g" "$1" > "$2"
}

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

# The log must be THIS run's output. Refuse symlinked logs, and create or
# truncate the file before running the command: if that fails, the command
# would never start yet a previous run's content would still be parsed —
# and a stale log matching the baseline would report green for a run that
# never happened.
if [[ -L "$LOG" ]]; then
  echo "error: --log must not be a symlink: $LOG" >&2
  exit 2
fi
if ! { : > "$LOG"; } 2>/dev/null; then
  echo "error: cannot create or truncate log: $LOG" >&2
  exit 2
fi

echo "gate: $*" >&2
echo "log:  $LOG" >&2
if [[ $STRICT -eq 1 ]]; then
  echo "mode: strict" >&2
elif [[ -n "$BASELINE" ]]; then
  echo "mode: baseline" >&2
else
  echo "mode: pass-through (exit code only — weakest; use --strict for unittest/pytest)" >&2
fi

# pytest emits its formal summary either fenced (`=== 1 failed in 0.1s ===`)
# or, under -q, as a bare bottom line (`1 failed in 0.1s`). pytest_summary
# returns the lowercased summary content for either shape and "" otherwise.
# The bare form must match the full official shape — count list (native
# subtests add `N subtests passed/failed` terms) plus an `in <duration>s`
# tail — so ordinary log lines never qualify as a summary.
#
# The shared rules below track the LAST runner verdict of EITHER kind by log
# position: a pytest summary line, or a unittest block (`Ran N tests` plus its
# OK/FAILED result line). The real runner always reports at the very end, so
# whichever runner printed last owns the verdict — anything earlier (an inner
# runner invoked by a test, application output that happens to match) is not
# evidence about THIS run, in either direction.
RUNNER_VERDICT_AWK='
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
  /^Ran [0-9]+ tests?/ {
    last_runner = "unittest"
    unit_total = $2 + 0
    unit_skipped = 0
    unit_result = ""
  }
  /^OK([[:space:]]|$)/ || /^FAILED[[:space:]]+\(/ || /^ERROR[[:space:]]+\(/ {
    if (last_runner != "unittest") unit_total = 0
    last_runner = "unittest"
    unit_result = $0
    unit_skipped = 0
    if (match(unit_result, /skipped=[0-9]+/)) {
      unit_skip_field = substr(unit_result, RSTART, RLENGTH)
      sub(/^skipped=/, "", unit_skip_field)
      unit_skipped = unit_skip_field + 0
    }
  }
  {
    runner_line = pytest_summary($0)
    if (runner_line != "") {
      last_runner = "pytest"
      last_summary = runner_line
    }
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
  LC_ALL=C awk '
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

# A unittest verdict is complete only when the `Ran N tests` line has its
# paired OK/FAILED result line — a bare count line is a truncated or masked
# run and must not count as evidence.
tests_ran() { # $1=stripped log path
  LC_ALL=C awk "$RUNNER_VERDICT_AWK"'
    END {
      if (last_runner == "pytest" &&
          last_summary !~ /^no tests ran([^[:alpha:]]|$)/ &&
          last_summary ~ /[1-9][0-9]*[[:space:]]+(subtests[[:space:]]+)?(passed|failed|xfailed|xpassed)([^[:alpha:]]|$)/) {
        ran = 1
      }
      if (last_runner == "unittest" && unit_result != "" &&
          (unit_total - unit_skipped) > 0) ran = 1
      exit(ran ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

zero_tests_reported() { # $1=stripped log path
  LC_ALL=C awk "$RUNNER_VERDICT_AWK"'
    END {
      if (last_runner == "unittest" && unit_total == 0) zero = 1
      if (last_runner == "pytest" &&
          last_summary ~ /^no tests ran([^[:alpha:]]|$)/) zero = 1
      exit(zero ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

supported_runner_summary() { # $1=stripped log path
  LC_ALL=C awk "$RUNNER_VERDICT_AWK"'
    END {
      if (last_runner == "unittest" && unit_result != "") recognized = 1
      if (last_runner == "pytest" &&
          (last_summary ~ /^no tests ran([^[:alpha:]]|$)/ ||
           last_summary ~ /[0-9]+[[:space:]]+(subtests[[:space:]]+)?(passed|failed|skipped|deselected|xfailed|xpassed|error|errors|warning|warnings)([^[:alpha:]]|$)/)) {
        recognized = 1
      }
      exit(recognized ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

# Positive failed/error counts (including subtest terms) in the FINAL runner
# verdict contradict an exit-zero run. Earlier blocks belong to inner runs or
# application output, never to this run's verdict.
failed_summary_present() { # $1=stripped log path
  LC_ALL=C awk "$RUNNER_VERDICT_AWK"'
    END {
      if (last_runner == "unittest" &&
          unit_result ~ /^(FAILED|ERROR)[[:space:]]+\(/) failed = 1
      if (last_runner == "pytest") {
        while (match(last_summary, /[0-9]+[[:space:]]+(subtests[[:space:]]+)?(failed|error|errors)([^[:alpha:]]|$)/)) {
          count = substr(last_summary, RSTART, RLENGTH)
          sub(/[[:space:]].*$/, "", count)
          if ((count + 0) > 0) failed = 1
          last_summary = substr(last_summary, RSTART + RLENGTH)
        }
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
  if ! strip_ansi "$BASELINE" "$BASELINE_PARSE"; then
    echo "error: could not normalize baseline for parsing: $BASELINE" >&2
    exit 2
  fi
  BASELINE_FAILURES_AT_START="$(extract_failures "$BASELINE_PARSE" | LC_ALL=C sort -u || true)"
fi

START=$SECONDS
# Output goes to a file, never through a pipe, so $? is the suite's own.
"$@" > "$LOG" 2>&1
STATUS=$?
ELAPSED=$((SECONDS - START))

echo "=== gate finished in ${ELAPSED}s with exit code ${STATUS} ==="

# An unparsed log must never be judged: an empty parse view would hide a
# failed summary behind a masked exit code, so normalization failure is red.
if ! strip_ansi "$LOG" "$PARSE_LOG"; then
  echo "RESULT: gate RED — log normalization failed; refusing to judge unparsed output"
  exit 1
fi

# Surface the shapes most runners use for their summary line.
LC_ALL=C grep -aE '^(Ran [0-9]+ |OK\b|FAILED\b|ERROR\b|SUBFAILED\b|=+ .*(passed|failed|no tests ran).* =+|(no tests ran|[0-9]+ [a-z]+( [a-z]+)?(, [0-9]+ [a-z]+( [a-z]+)?)*) in [0-9]+(\.[0-9]+)?s)' "$PARSE_LOG" | tail -5

CURRENT_FAILURES="$(extract_failures "$PARSE_LOG" || true)"
FAILED_SUMMARY=0
if failed_summary_present "$PARSE_LOG"; then
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
  LC_ALL=C awk 'NR <= 40' <<< "$CURRENT_FAILURES"
fi

# A gate is only meaningful against a baseline: the bar is "no NEW
# non-flake failures", not "zero failures", on suites with known
# environment flakes. Compare rather than eyeballing when possible.
NEW_FAILURES=""
if [[ -n "$BASELINE" && $BASELINE_EXISTS_AT_START -eq 1 ]]; then
  echo "--- failures not present in baseline ($BASELINE) ---"
  NEW_FAILURES="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "$BASELINE_FAILURES_AT_START" | LC_ALL=C sort -u) \
    <(printf '%s\n' "$CURRENT_FAILURES"           | LC_ALL=C sort -u) \
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

# --strict: zero tolerance on a recognized runner. Everything baseline mode
# fails closed on, strict fails closed on too — plus any parsed failure line
# at all, even when the final summary is clean.
if [[ $STRICT -eq 1 ]]; then
  if [[ $STATUS -ne 0 ]]; then
    echo "RESULT: gate RED — do not publish until resolved or explained"
    exit "$STATUS"
  fi
  if ! supported_runner_summary "$PARSE_LOG"; then
    echo "RESULT: gate RED — strict needs a recognized unittest/pytest verdict; use pass-through for other runners"
    exit 1
  fi
  if zero_tests_reported "$PARSE_LOG" || ! tests_ran "$PARSE_LOG"; then
    echo "RESULT: gate RED — no executed tests — skipped-only or zero-test run"
    exit 1
  fi
  if [[ $FAILURES -gt 0 ]]; then
    echo "RESULT: gate RED — failure lines present despite exit 0"
    exit 1
  fi
  echo "RESULT: gate green"
  exit 0
fi

# With no policy flag, retain the suite's pass-through status.
if [[ -z "$BASELINE" ]]; then
  if [[ $STATUS -eq 0 ]]; then
    echo "RESULT: gate green (pass-through: exit code only)"
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
  if ! supported_runner_summary "$PARSE_LOG"; then
    echo "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only"
    exit 1
  fi
  if zero_tests_reported "$PARSE_LOG" || ! tests_ran "$PARSE_LOG"; then
    echo "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output"
    exit 1
  fi
  echo "RESULT: gate green"
  exit 0
fi

# Keep the explicit diagnostic for nonzero zero-test runs. A zero-exit run was
# already checked above with the stricter executed-test requirement.
if zero_tests_reported "$PARSE_LOG"; then
  echo "RESULT: gate RED — no tests ran"
  exit 1
fi

if ! tests_ran "$PARSE_LOG"; then
  echo "RESULT: gate RED — failures parsed but no completed tests were reported"
elif [[ $BASELINE_EXISTS_AT_START -eq 0 || -n "$NEW_FAILURES" ]]; then
  echo "RESULT: gate RED — do not publish until resolved or explained"
elif [[ $STATUS -ne 1 ]]; then
  # Only the runner's own "tests failed" status (1 for pytest and unittest)
  # may be offset by a baseline. Signals (137), not-executable (126/127),
  # and pytest's interrupt/usage/no-tests codes (2-5) mean the run itself
  # broke — a matching failure list proves nothing about it.
  echo "RESULT: gate RED — abnormal runner exit ($STATUS); signals, crashes, and interrupts never baseline away"
else
  echo "RESULT: gate green (failures match baseline — no new failures)"
  exit 0
fi

exit "$STATUS"
