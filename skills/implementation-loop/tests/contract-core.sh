#!/usr/bin/env bash
# A stub cannot show that a real CLI's sandbox enforces anything; that is
# tests/integration-test.sh's job. This suite checks only the shared observable
# adapter contract through each backend's execution-wrapper fixture driver.

set -uo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LOOP_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST="$LOOP_ROOT/backends/backends.tsv"
SELECTED_BACKEND=""
ADAPTER_OVERRIDE=""
ONLY_RULES=""

usage() {
  cat <<'EOF'
Usage: contract-core.sh [--backend NAME] [--adapter PATH] [--only RULE]...

With no filters, discover and test every registered backend. --adapter requires
one --backend and is used by contract-negative.sh to prove a named rule fails.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) SELECTED_BACKEND="${2:?--backend needs a name}"; shift 2 ;;
    --adapter) ADAPTER_OVERRIDE="${2:?--adapter needs a path}"; shift 2 ;;
    --only)
      [[ -n "${2:-}" ]] || { echo "error: --only needs a rule" >&2; exit 2; }
      ONLY_RULES="${ONLY_RULES:+$ONLY_RULES,}$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$ADAPTER_OVERRIDE" && -z "$SELECTED_BACKEND" ]]; then
  echo "error: --adapter requires --backend" >&2
  exit 2
fi

TMP_ROOT_RAW="$(mktemp -d "$SCRIPT_DIR/.contract-core.XXXXXX")" || exit 1
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
cleanup() {
  local marker runtime_root
  for marker in "$TMP_ROOT"/*/*.runtime-root; do
    [[ -f "$marker" ]] || continue
    IFS= read -r runtime_root < "$marker"
    case "$runtime_root" in
      /tmp/implementation-loop-contract-grok.*|/private/tmp/implementation-loop-contract-grok.*)
        [[ ! -d "$runtime_root" ]] || rm -rf -- "$runtime_root"
        ;;
      *) echo "warning: refusing unexpected contract runtime cleanup path: $runtime_root" >&2 ;;
    esac
  done
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM
NORMALIZED="$TMP_ROOT/backends.tsv"

if ! python3 - "$LOOP_ROOT" "$MANIFEST" > "$NORMALIZED" <<'PY'
import os
import re
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
manifest = Path(sys.argv[2])
try:
    lines = manifest.read_text(encoding="utf-8").splitlines()
except OSError as exc:
    print(f"manifest: unreadable: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not lines or lines[0] != "#schema=1":
    print("manifest: first line must be #schema=1", file=sys.stderr)
    raise SystemExit(1)
rows = [line.split("\t") for line in lines[1:] if line]
if not rows or any(len(row) != 7 for row in rows):
    print("manifest: every non-schema row must have exactly seven tab-separated columns", file=sys.stderr)
    raise SystemExit(1)

names = [row[0] for row in rows]
namespaces = [row[2] for row in rows]
errors = []
if len(names) != len(set(names)):
    errors.append("backend names must be unique")
if len(namespaces) != len(set(namespaces)):
    errors.append("environment namespaces must be unique")
for row in rows:
    name, cli, namespace, resume, effort, output_schema, driver_text = row
    if re.fullmatch(r"[a-z][a-z0-9-]*", name) is None:
        errors.append(f"invalid backend name: {name!r}")
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", cli) is None:
        errors.append(f"invalid CLI name for {name}: {cli!r}")
    if re.fullmatch(r"[A-Z][A-Z0-9_]*_LOOP_", namespace) is None:
        errors.append(f"invalid environment namespace for {name}: {namespace!r}")
    if resume not in {"exact-id", "refuses"}:
        errors.append(f"invalid resume capability for {name}: {resume!r}")
    if effort not in {"flag", "embedded-in-model"}:
        errors.append(f"invalid effort capability for {name}: {effort!r}")
    if output_schema not in {"json", "text"}:
        errors.append(f"invalid output schema for {name}: {output_schema!r}")
    driver_path = PurePosixPath(driver_text)
    if driver_path.is_absolute() or ".." in driver_path.parts:
        errors.append(f"invalid fixture driver path for {name}: {driver_text!r}")
    else:
        driver = root / driver_path
        if not driver.is_file() or not os.access(driver, os.X_OK):
            errors.append(f"fixture driver for {name} is missing or not executable: {driver_text}")

discovered = sorted(
    path.parent.name
    for path in (root / "backends").glob("*/dispatch.sh")
    if path.is_file()
)
registered = sorted(names)
if discovered != registered:
    errors.append(
        "discovered dispatch modules do not match manifest: "
        f"discovered={discovered}, registered={registered}"
    )
if errors:
    print("\n".join(f"manifest: {error}" for error in errors), file=sys.stderr)
    raise SystemExit(1)
for row in sorted(rows, key=lambda item: item[0]):
    print("\t".join(row))
PY
then
  exit 2
fi

if [[ -n "$SELECTED_BACKEND" ]] && ! LC_ALL=C awk -F '\t' -v name="$SELECTED_BACKEND" '$1 == name { found = 1 } END { exit !found }' "$NORMALIZED"; then
  echo "error: backend is not registered: $SELECTED_BACKEND" >&2
  exit 2
fi

VALID_RULES="help,prompt-file,prompt-inline,prompt-precedence,prompt-required,dash-prompt,missing-values,repeated-flags,unknown-flags,readonly-alias,background,exit-status,signal-status,env-namespace,summary-fields,journal-missing,journal-start-refusal,journal-events,journal-unattributed,journal-readonly-mode"
if [[ -n "$ONLY_RULES" ]]; then
  OLD_IFS="$IFS"
  IFS=,
  for RULE_NAME in $ONLY_RULES; do
    case ",$VALID_RULES," in
      *",$RULE_NAME,"*) ;;
      *) echo "error: unknown contract rule: $RULE_NAME" >&2; exit 2 ;;
    esac
  done
  IFS="$OLD_IFS"
fi

rule_enabled() { # $1=rule
  [[ -z "$ONLY_RULES" ]] || [[ ",$ONLY_RULES," == *",$1,"* ]]
}

CHECKS=0
FAILURES=0
BACKENDS_TESTED=0
CURRENT_RULE=""
BACKEND=""
CASE_STATUS=0
CASE_OUTPUT=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - backend=%s rule=%s %s\n' "$CHECKS" "$BACKEND" "$CURRENT_RULE" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - backend=%s rule=%s %s\n' "$CHECKS" "$BACKEND" "$CURRENT_RULE" "$1" >&2
  if [[ -n "$CASE_OUTPUT" && -f "$CASE_OUTPUT" ]]; then
    sed 's/^/  | /' "$CASE_OUTPUT" >&2
  fi
}

run_case() { # $1=case; remaining args=adapter args
  local case_name="$1"
  shift
  CASE_OUTPUT="$TMP_ROOT/$BACKEND/$case_name.output"
  mkdir -p "$TMP_ROOT/$BACKEND"
  if "$DRIVER" run "$TMP_ROOT/$BACKEND" "$case_name" "$ADAPTER" -- "$@" > "$CASE_OUTPUT" 2>&1; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then pass "$2"; else fail "$2 (status $CASE_STATUS, expected $1)"; fi
}

expect_nonzero() { # $1=description
  if [[ $CASE_STATUS -ne 0 ]]; then pass "$1"; else fail "$1 (unexpected success)"; fi
}

expect_contains() { # $1=fixed string $2=description
  if LC_ALL=C grep -qF -- "$1" "$CASE_OUTPUT"; then pass "$2"; else fail "$2 (missing '$1')"; fi
}

expect_pattern() { # $1=extended regex $2=description
  if LC_ALL=C grep -qE -- "$1" "$CASE_OUTPUT"; then pass "$2"; else fail "$2 (pattern '$1' did not match)"; fi
}

expect_observed() { # $1=case $2=field $3=expected $4=description
  local path="$TMP_ROOT/$BACKEND/$1.observed-$2"
  local actual=""
  [[ ! -f "$path" ]] || actual="$(cat "$path")"
  if [[ "$actual" == "$3" ]]; then pass "$4"; else fail "$4 (got '$actual', expected '$3')"; fi
}

expect_observed_not() { # $1=case $2=field $3=forbidden $4=description
  local path="$TMP_ROOT/$BACKEND/$1.observed-$2"
  local actual=""
  [[ ! -f "$path" ]] || actual="$(cat "$path")"
  if [[ -f "$path" && "$actual" != "$3" ]]; then pass "$4"; else fail "$4 (observed forbidden '$actual')"; fi
}

expect_missing_path() { # $1=path $2=description
  if [[ -e "$1" ]]; then fail "$2 (unexpected path: $1)"; else pass "$2"; fi
}

case_home() { # $1=case
  cat "$TMP_ROOT/$BACKEND/$1.home"
}

case_workspace() { # $1=case
  cat "$TMP_ROOT/$BACKEND/$1.workspace"
}

journal_store() { # $1=home $2=workspace
  python3 - "$1" "$2" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key))
PY
}

expect_dispatch_pair() { # $1=case $2=backend $3=mode $4=end_exit $5=description
  local case_name="$1" backend_name="$2" mode="$3" end_exit="$4" description="$5"
  local home workspace store
  home="$(case_home "$case_name")"
  workspace="$(case_workspace "$case_name")"
  store="$(journal_store "$home" "$workspace")"
  if python3 - "$store" "$backend_name" "$mode" "$end_exit" <<'PY'
import json, os, sys

store, backend, mode, end_exit = sys.argv[1:]
end_exit = int(end_exit)
runs = os.path.join(store, "runs")
events = []
if os.path.isdir(runs):
    for name in sorted(os.listdir(runs)):
        if name.endswith(".jsonl"):
            for line in open(os.path.join(runs, name), encoding="utf-8"):
                line = line.strip()
                if line:
                    events.append(json.loads(line))
starts = [event for event in events if event.get("event") == "dispatch.start"]
ends = [event for event in events if event.get("event") == "dispatch.end"]
if len(starts) != 1 or len(ends) != 1:
    raise SystemExit(1)
start, end = starts[0], ends[0]
if start.get("backend") != backend or start.get("mode") != mode:
    raise SystemExit(1)
if start.get("dispatch_id") != end.get("dispatch_id"):
    raise SystemExit(1)
if end.get("exit") != end_exit:
    raise SystemExit(1)
if not start.get("dispatch_id"):
    raise SystemExit(1)
PY
  then
    pass "$description"
  else
    fail "$description"
  fi
}

expect_unattributed() { # $1=case $2=reason $3=description
  local case_name="$1" reason="$2" description="$3"
  local home workspace store
  home="$(case_home "$case_name")"
  workspace="$(case_workspace "$case_name")"
  store="$(journal_store "$home" "$workspace")"
  if python3 - "$store" "$reason" <<'PY'
import json, os, sys

store, reason = sys.argv[1:]
path = os.path.join(store, "unattributed.jsonl")
if not os.path.isfile(path):
    raise SystemExit(1)
events = []
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if line:
        events.append(json.loads(line))
starts = [event for event in events if event.get("event") == "dispatch.start"]
if not starts:
    raise SystemExit(1)
if any(event.get("attribution_failure") != reason for event in starts):
    raise SystemExit(1)
PY
  then
    pass "$description"
  else
    fail "$description"
  fi
}

expect_signal_journal() { # $1=case $2=description
  local case_name="$1" description="$2"
  local home workspace store
  home="$(case_home "$case_name")"
  workspace="$(case_workspace "$case_name")"
  store="$(journal_store "$home" "$workspace")"
  if python3 - "$store" <<'PY'
import json, os, sys

store = sys.argv[1]
runs = os.path.join(store, "runs")
events = []
if os.path.isdir(runs):
    for name in sorted(os.listdir(runs)):
        if name.endswith(".jsonl"):
            for line in open(os.path.join(runs, name), encoding="utf-8"):
                line = line.strip()
                if line:
                    events.append(json.loads(line))
starts = [event for event in events if event.get("event") == "dispatch.start"]
ends = [event for event in events if event.get("event") == "dispatch.end"]
if len(starts) != 1:
    raise SystemExit(1)
if ends and ends[0].get("exit") != 143:
    raise SystemExit(1)
if ends and ends[0].get("dispatch_id") != starts[0].get("dispatch_id"):
    raise SystemExit(1)
PY
  then
    pass "$description"
  else
    fail "$description"
  fi
}

run_backend() {
  BACKENDS_TESTED=$((BACKENDS_TESTED + 1))

  if rule_enabled help; then
    CURRENT_RULE="help"
    run_case help -h
    expect_status 0 "-h exits successfully"
    for CONTRACT_FLAG in --prompt-file --prompt --model --effort --read-only --investigate; do
      expect_contains "$CONTRACT_FLAG" "help names $CONTRACT_FLAG"
    done
  fi

  if rule_enabled prompt-file; then
    CURRENT_RULE="prompt-file"
    printf '%s' 'prompt from file' > "$TMP_ROOT/$BACKEND/prompt.txt"
    run_case prompt-file --prompt-file "$TMP_ROOT/$BACKEND/prompt.txt"
    expect_status 0 "--prompt-file is accepted"
    expect_observed prompt-file prompt 'prompt from file' "file prompt reaches the CLI verbatim"
  fi

  if rule_enabled prompt-inline; then
    CURRENT_RULE="prompt-inline"
    run_case prompt-inline --prompt 'inline prompt'
    expect_status 0 "--prompt is accepted"
    expect_observed prompt-inline prompt 'inline prompt' "inline prompt reaches the CLI verbatim"
  fi

  if rule_enabled prompt-precedence; then
    CURRENT_RULE="prompt-precedence"
    printf '%s' 'winning file prompt' > "$TMP_ROOT/$BACKEND/precedence.txt"
    run_case prompt-precedence --prompt-file "$TMP_ROOT/$BACKEND/precedence.txt" --prompt 'losing inline prompt'
    expect_status 0 "both prompt forms are accepted together"
    expect_observed prompt-precedence prompt 'winning file prompt' "--prompt-file wins over --prompt"
  fi

  if rule_enabled prompt-required; then
    CURRENT_RULE="prompt-required"
    run_case prompt-required
    expect_nonzero "an absent prompt fails closed"
  fi

  if rule_enabled dash-prompt; then
    CURRENT_RULE="dash-prompt"
    run_case dash-prompt --prompt '--literal-leading-dash'
    expect_status 0 "a prompt beginning with -- is accepted as data"
    expect_observed dash-prompt prompt '--literal-leading-dash' "a leading -- prompt reaches the CLI verbatim"
  fi

  if rule_enabled missing-values; then
    CURRENT_RULE="missing-values"
    run_case missing-prompt-file --prompt-file
    expect_nonzero "missing --prompt-file value is rejected"
    run_case missing-prompt --prompt
    expect_nonzero "missing --prompt value is rejected"
    run_case missing-model --prompt ok --model
    expect_nonzero "missing --model value is rejected"
    run_case missing-effort --prompt ok --effort
    expect_nonzero "missing --effort value is rejected"
  fi

  if rule_enabled repeated-flags; then
    CURRENT_RULE="repeated-flags"
    if [[ "$EFFORT_CAPABILITY" == "embedded-in-model" ]]; then
      run_case repeated-flags --prompt first --prompt last \
        --model first-model --model cursor-contract-high --effort low --effort high
    else
      run_case repeated-flags --prompt first --prompt last \
        --model first-model --model last-model --effort low --effort high
    fi
    expect_status 0 "repeated value flags are accepted"
    expect_observed repeated-flags prompt last "the last repeated prompt wins"
    local last_model="last-model"
    [[ "$EFFORT_CAPABILITY" != "embedded-in-model" ]] || last_model="cursor-contract-high"
    expect_observed repeated-flags model "$last_model" "the last repeated model wins"
    expect_pattern '^effort: high ' "the last repeated effort wins"
  fi

  if rule_enabled unknown-flags; then
    CURRENT_RULE="unknown-flags"
    run_case unknown-flags --prompt ok --contract-unknown
    expect_nonzero "an unknown flag fails closed"
  fi

  if rule_enabled readonly-alias; then
    CURRENT_RULE="readonly-alias"
    run_case readonly-alias-read --prompt inspect --read-only
    local read_status="$CASE_STATUS"
    run_case readonly-alias-investigate --prompt inspect --investigate
    local investigate_status="$CASE_STATUS"
    if [[ $read_status -eq 0 && $investigate_status -eq 0 ]]; then pass "both read-only spellings succeed"; else fail "both read-only spellings succeed (statuses $read_status/$investigate_status)"; fi
    expect_observed readonly-alias-read mode read-only "--read-only selects read-only mode"
    expect_observed readonly-alias-investigate mode read-only "--investigate selects the same mode"
  fi

  if rule_enabled background; then
    CURRENT_RULE="background"
    run_case background --prompt ok --background
    expect_nonzero "--background is rejected"
  fi

  if rule_enabled exit-status; then
    CURRENT_RULE="exit-status"
    run_case exit-status --prompt status
    expect_status 7 "the CLI's real non-zero exit status propagates"
  fi

  if rule_enabled signal-status; then
    CURRENT_RULE="signal-status"
    run_case signal-status --prompt signal
    expect_status 143 "signal termination propagates as 128+signal"
    expect_signal_journal signal-status \
      "TERM'd dispatch leaves dispatch.start and, where the trap runs, dispatch.end exit=143"
  fi

  if rule_enabled env-namespace; then
    CURRENT_RULE="env-namespace"
    run_case env-own --prompt env
    expect_status 0 "the declared namespace override is accepted"
    local own_model="contract-own-model"
    [[ "$BACKEND" != "cursor" ]] || own_model="cursor-contract-xhigh"
    expect_observed env-own model "$own_model" "the declared namespace reaches its adapter"
    run_case env-foreign --prompt env
    expect_status 0 "foreign namespace overrides do not control this adapter"
    expect_observed_not env-foreign model foreign-poison-model "the adapter does not read another backend's namespace"
  fi

  if rule_enabled summary-fields; then
    CURRENT_RULE="summary-fields"
    if [[ "$EFFORT_CAPABILITY" == "embedded-in-model" ]]; then
      run_case summary-fields --prompt summary --model cursor-contract-xhigh --effort xhigh
    else
      run_case summary-fields --prompt summary --model contract-model --effort high
    fi
    expect_status 0 "a summary-producing dispatch succeeds"
    expect_pattern '^workspace: .+' "summary contains workspace"
    expect_pattern "^${CLI_NAME} version: .+" "summary contains ${CLI_NAME} version"
    expect_pattern '^model: .+\(.+\)' "summary contains model with provenance"
    expect_pattern '^effort: .+\(.+\)' "summary contains effort with provenance"
    expect_pattern '^mode: (implement|read-only)$' "summary contains mode"
    expect_pattern '^resume: .+' "summary contains resume"
    expect_pattern '^session id: [^<].+' "summary contains a runtime-reported session id"
    if [[ "$BACKEND" == "codex" ]]; then
      expect_pattern '^sandbox \(requested\): .+' "Codex summary contains requested sandbox"
      expect_pattern '^sandbox \(CLI reported\): .+' "Codex summary contains CLI-reported sandbox"
    fi
  fi

  if rule_enabled journal-missing; then
    CURRENT_RULE="journal-missing"
    run_case journal-missing --prompt journal
    expect_status 0 "missing journal helper does not change a successful dispatch"
    local missing_home
    missing_home="$(case_home journal-missing)"
    expect_missing_path "$missing_home/.config/olddonkey-loop/journal" \
      "missing helper creates no journal store"
  fi

  if rule_enabled journal-start-refusal; then
    CURRENT_RULE="journal-start-refusal"
    run_case journal-start-refusal --prompt journal
    expect_nonzero "a failing dispatch.start append refuses the dispatch"
    expect_contains "loop-journal dispatch.start failed" "start-refusal names the journal failure"
    expect_missing_path "$TMP_ROOT/$BACKEND/journal-start-refusal.observed-prompt" \
      "start-refusal never launches the fixture child"
  fi

  if rule_enabled journal-events; then
    CURRENT_RULE="journal-events"
    run_case journal-events --prompt journal
    expect_status 0 "attributed journal dispatch succeeds"
    expect_dispatch_pair journal-events "$BACKEND" implement 0 \
      "run segment records matching dispatch.start then dispatch.end exit=0"
  fi

  if rule_enabled journal-unattributed; then
    CURRENT_RULE="journal-unattributed"
    run_case journal-unattributed --prompt journal
    expect_status 0 "missing context does not change dispatch exit"
    expect_unattributed journal-unattributed "context missing" \
      "unattributed events record attribution_failure=context missing"
    if [[ "$BACKEND" == "cursor" ]]; then
      run_case journal-stale --prompt journal
      expect_status 0 "stale context does not change dispatch exit"
      expect_unattributed journal-stale "context stale" \
        "stale context records attribution_failure=context stale"
      run_case journal-malformed --prompt journal
      expect_status 0 "malformed context does not change dispatch exit"
      expect_unattributed journal-malformed "context malformed" \
        "malformed context records attribution_failure=context malformed"
      run_case journal-wrong-workspace --prompt journal
      expect_status 0 "wrong-workspace context does not change dispatch exit"
      expect_unattributed journal-wrong-workspace "wrong-workspace" \
        "wrong-workspace context records attribution_failure=wrong-workspace"
    fi
    if [[ "$BACKEND" == "grok" ]]; then
      run_case journal-post-disarm-abort --prompt journal
      expect_status 86 "post-disarm journal abort still exits 86"
      expect_dispatch_pair journal-post-disarm-abort grok implement 86 \
        "post-disarm abort records dispatch.end exit=86"
    fi
  fi

  if rule_enabled journal-readonly-mode; then
    CURRENT_RULE="journal-readonly-mode"
    run_case journal-readonly-mode --prompt journal --read-only
    expect_status 0 "read-only journal dispatch succeeds"
    expect_dispatch_pair journal-readonly-mode "$BACKEND" read-only 0 \
      "read-only dispatch.start records mode=read-only"
  fi
}

while IFS=$'\t' read -r BACKEND CLI_NAME ENV_NAMESPACE RESUME_CAPABILITY EFFORT_CAPABILITY OUTPUT_SCHEMA DRIVER_RELATIVE; do
  [[ -z "$SELECTED_BACKEND" || "$BACKEND" == "$SELECTED_BACKEND" ]] || continue
  DRIVER="$LOOP_ROOT/$DRIVER_RELATIVE"
  ADAPTER="$LOOP_ROOT/backends/$BACKEND/dispatch.sh"
  [[ -z "$ADAPTER_OVERRIDE" ]] || ADAPTER="$ADAPTER_OVERRIDE"
  run_backend
done < "$NORMALIZED"

if [[ $FAILURES -gt 0 ]]; then
  printf 'contract-core: FAIL (%d of %d checks failed; %d backends)\n' "$FAILURES" "$CHECKS" "$BACKENDS_TESTED" >&2
  exit 1
fi

printf 'contract-core: PASS (%d checks; %d backends)\n' "$CHECKS" "$BACKENDS_TESTED"
