#!/usr/bin/env bash
# Fast, dependency-free regression checks for codex-dispatch.sh and run-gate.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/codex-dispatch.sh"
GATE="$SCRIPT_DIR/run-gate.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-loop-selftest.XXXXXX")" || exit 1
STATE_PARENT="$(mktemp -d "$SCRIPT_DIR/.codex-loop-selftest.XXXXXX")" || exit 1
SLASH_TMP_PARENT="$(mktemp -d /tmp/codex-loop-selftest-home.XXXXXX)" || exit 1
CRASH_CHILD_PID=""
cleanup() {
  if [[ -n "$CRASH_CHILD_PID" ]]; then
    kill -TERM "-$CRASH_CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" "$STATE_PARENT" "$SLASH_TMP_PARENT"
}
trap cleanup EXIT HUP INT TERM

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_OUTPUT=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_OUTPUT" && -f "$CASE_OUTPUT" ]]; then
    sed 's/^/  | /' "$CASE_OUTPUT" >&2
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

expect_nonzero() { # $1=description
  if [[ $CASE_STATUS -ne 0 ]]; then
    pass "$1"
  else
    fail "$1 (expected nonzero status)"
  fi
}

expect_output() { # $1=fixed string $2=description
  if grep -Fq -- "$1" "$CASE_OUTPUT"; then
    pass "$2"
  else
    fail "$2 (missing: $1)"
  fi
}

expect_no_output() { # $1=fixed string $2=description
  if grep -Fq -- "$1" "$CASE_OUTPUT"; then
    fail "$2 (unexpected: $1)"
  else
    pass "$2"
  fi
}

expect_first_line() { # $1=file $2=expected $3=description
  local actual=""
  [[ -f "$1" ]] && IFS= read -r actual < "$1"
  if [[ "$actual" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected '$2', got '$actual')"
  fi
}

expect_file_line() { # $1=file $2=exact line $3=description
  if [[ -f "$1" ]] && LC_ALL=C grep -qxF -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3 (no exact line '$2' in $1)"
  fi
}

expect_no_file_line() { # $1=file $2=exact line $3=description
  if [[ -f "$1" ]] && LC_ALL=C grep -qxF -- "$2" "$1"; then
    fail "$3 (unexpected exact line '$2' in $1)"
  else
    pass "$3"
  fi
}

expect_missing_file() { # $1=file $2=description
  if [[ -e "$1" ]]; then
    fail "$2 (unexpected file: $1)"
  else
    pass "$2"
  fi
}

skip_checks() { # $@=descriptions; marked skipped so counts stay stable
  local description
  for description in "$@"; do
    CHECKS=$((CHECKS + 1))
    printf 'ok %d - %s # SKIP no tomllib python3 available\n' "$CHECKS" "$description"
  done
}

run_case() { # $1=name, remaining args=command
  local name="$1"
  shift
  CASE_OUTPUT="$TMP_ROOT/$name.out"
  if "$@" > "$CASE_OUTPUT" 2>&1; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

run_case_in_dir() { # $1=name $2=working directory, remaining args=command
  local name="$1" directory="$2"
  shift 2
  run_case "$name" bash -c 'cd "$1" && shift && exec "$@"' _ "$directory" "$@"
}

write_lines() { # $1=path, remaining args=lines
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

run_split_case_in_dir() { # $1=name $2=working directory, remaining args=command
  local name="$1" directory="$2"
  shift 2
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  CASE_OUTPUT="$CASE_STDERR"
  if (cd "$directory" && exec "$@") > "$CASE_STDOUT" 2> "$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_stdout_exact() { # $1=expected $2=description
  local expected_file="$TMP_ROOT/expected-stdout"
  printf '%s' "$1" > "$expected_file"
  if cmp -s "$expected_file" "$CASE_STDOUT"; then
    pass "$2"
  else
    fail "$2 (stdout differed)"
  fi
}

expect_file_mode() { # $1=path $2=octal mode $3=description
  if python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

path, expected = sys.argv[1:]
info = os.lstat(path)
ok = not stat.S_ISLNK(info.st_mode) and stat.S_IMODE(info.st_mode) == int(expected, 8)
raise SystemExit(0 if ok else 1)
PY
  then
    pass "$3"
  else
    fail "$3"
  fi
}

expect_argv_count() { # $1=log $2=value $3=count $4=description
  if python3 - "$1" "$2" "$3" <<'PY'
import sys

path, value, expected = sys.argv[1:]
raw = open(path, "rb").read().split(b"\0")
argv = [item.decode("utf-8") for item in raw if item]
raise SystemExit(0 if argv.count(value) == int(expected) else 1)
PY
  then
    pass "$4"
  else
    fail "$4"
  fi
}

expect_argv_sequence() { # $1=log $2=description, remaining=sequence
  local log="$1" description="$2"
  shift 2
  if python3 - "$log" "$@" <<'PY'
import sys

path, *needle = sys.argv[1:]
raw = open(path, "rb").read().split(b"\0")
argv = [item.decode("utf-8") for item in raw if item]
found = any(argv[index:index + len(needle)] == needle for index in range(len(argv) - len(needle) + 1))
raise SystemExit(0 if found else 1)
PY
  then
    pass "$description"
  else
    fail "$description"
  fi
}

expect_argv_sandbox() { # $1=log $2=fresh|resume $3=mode $4=description
  if python3 - "$1" "$2" "$3" <<'PY'
import sys

path, kind, mode = sys.argv[1:]
raw = open(path, "rb").read().split(b"\0")
argv = [item.decode("utf-8") for item in raw if item]
fresh = sum(1 for index, value in enumerate(argv[:-1]) if value == "-s" and argv[index + 1] == mode)
resume = sum(
    1
    for index, value in enumerate(argv[:-1])
    if value == "-c" and argv[index + 1] == f'sandbox_mode="{mode}"'
)
wrong = sum(
    1
    for index, value in enumerate(argv[:-1])
    if value == "-s" or (value == "-c" and argv[index + 1].startswith("sandbox_mode="))
)
ok = wrong == 1 and ((kind == "fresh" and fresh == 1 and resume == 0) or (kind == "resume" and resume == 1 and fresh == 0))
raise SystemExit(0 if ok else 1)
PY
  then
    pass "$4"
  else
    fail "$4"
  fi
}

expect_argv_no_forbidden() { # $1=log $2=description
  if python3 - "$1" <<'PY'
import sys

forbidden = {
    "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
    "--add-dir", "--approve-for-me", "-p", "--profile", "--ignore-user-config",
    "--ignore-rules", "--enable", "--disable",
}
raw = open(sys.argv[1], "rb").read().split(b"\0")
argv = [item.decode("utf-8") for item in raw if item][:-1]
bad = any(value in forbidden or any(value.startswith(prefix) for prefix in (
    "--add-dir=", "--approve-for-me=", "--profile=", "--enable=", "--disable="
)) for value in argv)
raise SystemExit(1 if bad else 0)
PY
  then
    pass "$2"
  else
    fail "$2"
  fi
}

latest_run_state() { # $1=stderr path
  LC_ALL=C sed -n 's/^run state: //p' "$1" | tail -1
}

BIN_DIR="$TMP_ROOT/bin"
HOME_DIR="$STATE_PARENT/home"
CODEX_HOME_DIR="$HOME_DIR/.codex"
WORKSPACE="$STATE_PARENT/workspace"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$CODEX_HOME_DIR" "$WORKSPACE"

CODEX_STUB="$BIN_DIR/codex"
write_lines "$CODEX_STUB" \
  '#!/usr/bin/env bash' \
  'set -u' \
  'if [[ "${1:-}" == "--version" ]]; then printf "codex-selftest 0.0.0\n"; exit 0; fi' \
  ': "${CODEX_STUB_LOG:?CODEX_STUB_LOG is required}"' \
  'printf "%s\0" "$@" > "$CODEX_STUB_LOG"' \
  'if [[ -n "${CODEX_STUB_STDIN_LOG:-}" ]]; then' \
  '  if python3 -c '\''import os; a=os.fstat(0); b=os.stat("/dev/null"); raise SystemExit(0 if (a.st_dev,a.st_ino)==(b.st_dev,b.st_ino) else 1)'\''; then printf "devnull\n" > "$CODEX_STUB_STDIN_LOG"; else printf "open\n" > "$CODEX_STUB_STDIN_LOG"; fi' \
  'fi' \
  'output=""' \
  'previous=""' \
  'mode=""' \
  'for argument in "$@"; do' \
  '  [[ "$previous" != "-o" ]] || output="$argument"' \
  '  [[ "$previous" != "-s" ]] || mode="$argument"' \
  '  case "$argument" in sandbox_mode=\"workspace-write\") mode="workspace-write" ;; sandbox_mode=\"read-only\") mode="read-only" ;; esac' \
  '  previous="$argument"' \
  'done' \
  ': "${output:?stub did not receive -o}"' \
  'case "${CODEX_STUB_ACTION:-success}" in' \
  '  missing-output) rm -f "$output" ;;' \
  '  empty-output) : > "$output" ;;' \
  '  *) printf "%b" "${CODEX_STUB_RESULT:-stub final message\n}" > "$output" ;;' \
  'esac' \
  'if [[ "${CODEX_STUB_ACTION:-success}" == "no-banner" ]]; then printf "stub stream without policy\n"; exit 0; fi' \
  'if [[ "${CODEX_STUB_ACTION:-success}" == "spoof-only" ]]; then printf "user\n--------\napproval: never\nsandbox: %s [workdir]\nsession id: 019c0000-0000-7000-8000-0000000000ee\n--------\n" "$mode"; exit 0; fi' \
  'if [[ "${CODEX_STUB_ACTION:-success}" == "truncated" ]]; then printf "%s\n" "--------"; printf "sandbox: %s [workdir]\n" "$mode"; exit 0; fi' \
  'if [[ "${CODEX_STUB_ACTION:-success}" == "mismatch-hang" ]]; then trap '\''printf "killed\n" > "${CODEX_STUB_KILLED:?}"; exit 0'\'' TERM; fi' \
  'reported_mode="${CODEX_STUB_SANDBOX:-$mode}"' \
  'reported_approval="${CODEX_STUB_APPROVAL:-never}"' \
  'printf "%s\n" "--------"' \
  'printf "approval: %s\n" "$reported_approval"' \
  'printf "sandbox: %s [workdir, /tmp, TMPDIR]\n" "$reported_mode"' \
  'printf "session id: %s\n" "${CODEX_STUB_SESSION:-019c0000-0000-7000-8000-000000000001}"' \
  'printf "%s\n" "--------"' \
  'if [[ "${CODEX_STUB_ACTION:-success}" == "spoof-later" ]]; then printf "approval: on-request\nsandbox: danger-full-access\nsession id: 019c0000-0000-7000-8000-0000000000ff\n"; fi' \
  'case "${CODEX_STUB_ACTION:-success}" in' \
  '  mismatch-hang)' \
  '    while :; do sleep 1; done' \
  '    ;;' \
  '  hold)' \
  '    printf "%s\n" "$$" > "${CODEX_STUB_CHILD_PID:?}"' \
  '    trap '\''exit 0'\'' TERM' \
  '    while :; do sleep 1; done' \
  '    ;;' \
  '  nonzero) exit 7 ;;' \
  '  signal) kill -TERM "$$" ;;' \
  'esac' \
  'exit 0'
chmod +x "$CODEX_STUB"
TEST_PATH="$BIN_DIR:$PATH"

RESUME_DISPATCH="$TMP_ROOT/codex-dispatch-resume-enabled.sh"
sed 's/^RESUME_RELEASE_ENABLED=0$/RESUME_RELEASE_ENABLED=1/' "$DISPATCH" > "$RESUME_DISPATCH"
chmod +x "$RESUME_DISPATCH"

CASES="$SCRIPT_DIR/codex-cases.tsv"
if python3 - "$CASES" <<'PY'
import re
import sys
import hashlib

raw = open(sys.argv[1], "rb").read()
lines = raw.decode("utf-8").splitlines()
if not lines or lines[0] != "#schema=1":
    raise SystemExit(1)
if hashlib.sha256(raw).hexdigest() != "a4ed463a92fc9f46854c069290b117cd714ed4fe0ad2b7918cda0571a701970c":
    raise SystemExit(1)
rows = [line.split("\t") for line in lines[1:] if line and not line.startswith("#")]
ids = [row[0] for row in rows if len(row) == 4]
required = {
    "fresh-repo-write", "linked-git-dir-write", "submodule-git-dir-write",
    "raw-tcp-host-control", "raw-tcp-sandbox", "resume-repo-write",
    "config-approval-pin", "managed-layer-pin",
}
ok = (
    rows
    and all(len(row) == 4 for row in rows)
    and all(re.fullmatch(r"[a-z][a-z0-9-]*", row[0]) for row in rows)
    and len(ids) == len(set(ids))
    and all(row[1] in {"always", "managed-only"} for row in rows)
    and all(row[2] in {"allow", "deny", "pass"} for row in rows)
    and sum(row[1] == "managed-only" for row in rows) == 1
    and required.issubset(ids)
)
raise SystemExit(0 if ok else 1)
PY
then
  pass "codex case manifest is frozen, unique, typed, and has one managed-only row"
else
  fail "codex case manifest is frozen, unique, typed, and has one managed-only row"
fi

# Fresh implement dispatch: output channels, state, and every pinned control.
FRESH_LOG="$TMP_ROOT/fresh.argv"
FRESH_STDIN="$TMP_ROOT/fresh.stdin"
run_split_case_in_dir dispatch-fresh "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$FRESH_LOG" CODEX_STUB_STDIN_LOG="$FRESH_STDIN" \
  "$DISPATCH" --prompt 'implement the bounded fixture' --model gpt-test --effort max
expect_status 0 "fresh codex exec dispatch succeeds"
expect_stdout_exact $'stub final message\n' "stdout contains the final message exactly once and nothing else"
expect_output "codex exec dispatch summary:" "stderr contains the dispatch summary"
expect_output "sandbox (requested): workspace-write" "summary separates requested sandbox"
expect_output "sandbox (CLI reported): workspace-write" "summary reports the CLI banner sandbox"
expect_output "session id: 019c0000-0000-7000-8000-000000000001" "summary captures the banner session id"
expect_argv_sequence "$FRESH_LOG" "fresh argv starts with codex exec" exec -s workspace-write
expect_argv_sandbox "$FRESH_LOG" fresh workspace-write "fresh argv carries exactly one allowed sandbox specification"
expect_argv_sequence "$FRESH_LOG" "fresh argv pins quoted approval never" -c 'approval_policy="never"'
expect_argv_count "$FRESH_LOG" --strict-config 1 "fresh argv carries --strict-config exactly once"
expect_argv_sequence "$FRESH_LOG" "fresh argv clears inherited writable roots" -c 'sandbox_workspace_write.writable_roots=[]'
expect_argv_sequence "$FRESH_LOG" "fresh argv pins network access false" -c 'sandbox_workspace_write.network_access=false'
expect_argv_sequence "$FRESH_LOG" "fresh argv clears sandbox permissions" -c 'sandbox_permissions=[]'
expect_argv_sequence "$FRESH_LOG" "fresh argv pins the canonical workspace" -C "$WORKSPACE"
expect_argv_sequence "$FRESH_LOG" "fresh argv forwards explicit model" -m gpt-test
expect_argv_sequence "$FRESH_LOG" "max effort is a quoted TOML override" -c 'model_reasoning_effort="max"'
expect_argv_count "$FRESH_LOG" --json 0 "fresh argv omits --json so the policy banner remains visible"
expect_argv_no_forbidden "$FRESH_LOG" "fresh constructed argv contains no policy broadener"
expect_first_line "$FRESH_STDIN" devnull "fresh codex exec stdin is /dev/null"
FRESH_STDERR="$CASE_STDERR"
FRESH_STATE="$(latest_run_state "$FRESH_STDERR")"
FRESH_CURRENT=""
[[ ! -f "$(dirname "$FRESH_STATE")/current" ]] || IFS= read -r FRESH_CURRENT < "$(dirname "$FRESH_STATE")/current"

LITERAL_PROMPT_LOG="$TMP_ROOT/literal-prompt.argv"
run_split_case_in_dir dispatch-literal-prompt "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$LITERAL_PROMPT_LOG" "$DISPATCH" --prompt '--literal prompt, not a flag'
expect_status 0 "prompt beginning with -- remains literal"
expect_argv_sequence "$LITERAL_PROMPT_LOG" "argv terminator protects a leading-dash prompt" -- '--literal prompt, not a flag'

expect_file_mode "$FRESH_STATE" 700 "dispatch state directory is mode 0700"
for state_file in prompt.txt transcript.log last-message.txt meta.tsv; do
  expect_file_mode "$FRESH_STATE/$state_file" 600 "$state_file is a regular mode-0600 state file"
done
if LC_ALL=C grep -qx $'state\tready' "$FRESH_STATE/meta.tsv" &&
   LC_ALL=C grep -qx $'generation\t1' "$FRESH_STATE/meta.tsv" &&
   LC_ALL=C grep -qx $'workspace\t'"$WORKSPACE" "$FRESH_STATE/meta.tsv"; then
  pass "fresh dispatch atomically reaches ready generation 1 bound to its workspace"
else
  fail "fresh dispatch atomically reaches ready generation 1 bound to its workspace"
fi
if [[ "$FRESH_CURRENT" == "$(basename "$FRESH_STATE")" ]]; then
  pass "current cache points at the authoritative ready record"
else
  fail "current cache points at the authoritative ready record"
fi

# Read-only is the same builder with a different mode, not a second argv path.
READONLY_LOG="$TMP_ROOT/readonly.argv"
READONLY_STDIN="$TMP_ROOT/readonly.stdin"
run_split_case_in_dir dispatch-readonly "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$READONLY_LOG" CODEX_STUB_STDIN_LOG="$READONLY_STDIN" \
  "$DISPATCH" --prompt investigate --read-only --effort ultra
expect_status 0 "fresh read-only codex exec dispatch succeeds"
expect_argv_sandbox "$READONLY_LOG" fresh read-only "read-only argv carries exactly one read-only sandbox specification"
expect_argv_sequence "$READONLY_LOG" "ultra effort is a quoted TOML override" -c 'model_reasoning_effort="ultra"'
expect_argv_sequence "$READONLY_LOG" "read-only argv still pins approval" -c 'approval_policy="never"'
expect_argv_count "$READONLY_LOG" --strict-config 1 "read-only argv carries --strict-config"
expect_argv_sequence "$READONLY_LOG" "read-only argv still pins nested writable roots" -c 'sandbox_workspace_write.writable_roots=[]'
expect_argv_sequence "$READONLY_LOG" "read-only argv still pins nested network" -c 'sandbox_workspace_write.network_access=false'
expect_argv_sequence "$READONLY_LOG" "read-only argv still pins nested permissions" -c 'sandbox_permissions=[]'
expect_argv_count "$READONLY_LOG" --json 0 "read-only argv omits --json"
expect_argv_no_forbidden "$READONLY_LOG" "read-only constructed argv contains no policy broadener"
expect_first_line "$READONLY_STDIN" devnull "read-only codex exec stdin is /dev/null"

# Resume remains release-disabled in the shipped adapter.
rm -f "$TMP_ROOT/release-disabled.argv"
run_split_case_in_dir resume-release-disabled "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/release-disabled.argv" \
  "$DISPATCH" --prompt iterate --resume
expect_status 2 "shipped --resume refuses before the required real-backend pass"
expect_output "release-disabled" "resume refusal names the unmet release evidence"
expect_missing_file "$TMP_ROOT/release-disabled.argv" "release-disabled resume never launches Codex"

# The dormant resume builder is exercised from an exact source copy whose
# release constant alone is enabled. It must never use --last, -s, or -C.
RESUME_LOG="$TMP_ROOT/resume.argv"
RESUME_STDIN="$TMP_ROOT/resume.stdin"
run_split_case_in_dir dispatch-resume "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$RESUME_LOG" CODEX_STUB_STDIN_LOG="$RESUME_STDIN" \
  "$RESUME_DISPATCH" --prompt iterate --resume 019c0000-0000-7000-8000-000000000001 --effort max
expect_status 0 "dormant exact-id resume builder succeeds against the stub"
expect_argv_sequence "$RESUME_LOG" "resume argv binds the exact recorded id" exec resume 019c0000-0000-7000-8000-000000000001
expect_argv_sandbox "$RESUME_LOG" resume workspace-write "resume argv carries exactly one quoted sandbox_mode specification"
expect_argv_count "$RESUME_LOG" -s 0 "resume argv never emits rejected -s"
expect_argv_count "$RESUME_LOG" -C 0 "resume argv never emits rejected -C"
expect_argv_count "$RESUME_LOG" --last 0 "resume argv never falls back to --last"
expect_argv_sequence "$RESUME_LOG" "resume argv pins quoted approval never" -c 'approval_policy="never"'
expect_argv_count "$RESUME_LOG" --strict-config 1 "resume argv carries --strict-config exactly once"
expect_argv_sequence "$RESUME_LOG" "resume argv clears inherited writable roots" -c 'sandbox_workspace_write.writable_roots=[]'
expect_argv_sequence "$RESUME_LOG" "resume argv pins network access false" -c 'sandbox_workspace_write.network_access=false'
expect_argv_sequence "$RESUME_LOG" "resume argv clears sandbox permissions" -c 'sandbox_permissions=[]'
expect_argv_sequence "$RESUME_LOG" "resume forwards max as a quoted TOML override" -c 'model_reasoning_effort="max"'
expect_argv_count "$RESUME_LOG" --json 0 "resume argv omits --json"
expect_argv_no_forbidden "$RESUME_LOG" "resume constructed argv contains no policy broadener"
expect_first_line "$RESUME_STDIN" devnull "resume codex exec stdin is /dev/null"

if [[ "$(LC_ALL=C grep -c '^def build_codex_argv(' "$DISPATCH")" == "1" ]] &&
   LC_ALL=C grep -q 'Build both calibrated forms from one mode-parameterized function' "$DISPATCH"; then
  pass "fresh and resume argv are produced by one mode-parameterized function"
else
  fail "fresh and resume argv are produced by one mode-parameterized function"
fi

# Triple guard: direct parser, value-bearing environment options, and final
# constructed argv. Every known policy broadener is explicitly refused.
for forbidden in \
  --dangerously-bypass-approvals-and-sandbox \
  --dangerously-bypass-hook-trust \
  --add-dir \
  --approve-for-me \
  -p \
  --profile \
  --ignore-user-config \
  --ignore-rules \
  --enable \
  --disable; do
  rm -f "$TMP_ROOT/forbidden.argv"
  run_split_case_in_dir "forbidden-${forbidden#-}" "$WORKSPACE" env \
    HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
    CODEX_STUB_LOG="$TMP_ROOT/forbidden.argv" \
    "$DISPATCH" --prompt x "$forbidden"
  expect_status 2 "$forbidden is refused by the direct parser guard"
  expect_output "policy-broadening flags are forbidden" "$forbidden refusal explains the fixed policy"
  expect_missing_file "$TMP_ROOT/forbidden.argv" "$forbidden never reaches Codex argv"
done

rm -f "$TMP_ROOT/model-smuggle.argv"
run_split_case_in_dir forbidden-model-value "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_LOOP_MODEL=--profile=unsafe CODEX_STUB_LOG="$TMP_ROOT/model-smuggle.argv" \
  "$DISPATCH" --prompt x
expect_status 2 "policy broadener smuggled as model is refused"
expect_missing_file "$TMP_ROOT/model-smuggle.argv" "smuggled model value never reaches Codex argv"

rm -f "$TMP_ROOT/extra-args.argv"
run_split_case_in_dir forbidden-extra-env "$WORKSPACE" env \
  HOME="$HOME_DIR" CODEX_HOME="$CODEX_HOME_DIR" PATH="$TEST_PATH" \
  CODEX_LOOP_EXTRA_ARGS=--ignore-rules CODEX_STUB_LOG="$TMP_ROOT/extra-args.argv" \
  "$DISPATCH" --prompt x
expect_status 2 "environment extra args are refused"
expect_output "control flags are fixed" "extra-args refusal explains the fixed argv"
expect_missing_file "$TMP_ROOT/extra-args.argv" "environment extra args never launch Codex"

run_case background-refused "$DISPATCH" --prompt x --background
expect_status 2 "--background is rejected"
expect_output "harness level" "background refusal points to foreground harness lifecycle"

# External host-side channels keep the original warn/block shape and now also
# disclose notify hooks and plugins.
TOOLS_HOME="$STATE_PARENT/tools-home"
TOOLS_CODEX_HOME="$TOOLS_HOME/.codex"
TOOLS_WORKSPACE="$STATE_PARENT/tools-workspace"
mkdir -p "$TOOLS_CODEX_HOME" "$TOOLS_WORKSPACE"
write_lines "$TOOLS_CODEX_HOME/config.toml" \
  'notify = ["/example/turn-ended"]' \
  '[mcp_servers.demo]' \
  'command = "example"' \
  '[apps.connector_a]' \
  'enabled = true' \
  '[plugins.enabled_plugin]' \
  'enabled = true' \
  '[plugins.disabled_plugin]' \
  'enabled = false'
rm -f "$TMP_ROOT/tools-block.argv"
run_split_case_in_dir external-tools-block "$TOOLS_WORKSPACE" env \
  HOME="$TOOLS_HOME" CODEX_HOME="$TOOLS_CODEX_HOME" PATH="$TEST_PATH" \
  CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1 CODEX_STUB_LOG="$TMP_ROOT/tools-block.argv" \
  "$DISPATCH" --prompt x
expect_status 4 "external-tools refusal mode remains fail-closed when requested"
expect_output "mcp_servers.demo, apps.connector_a, plugins.enabled_plugin, notify" \
  "external-tools scan discloses MCP, Apps, plugins, and notify"
expect_no_output "disabled_plugin" "external-tools scan honors plugin enabled=false"
expect_missing_file "$TMP_ROOT/tools-block.argv" "blocked external tools never launch Codex"

TOOLS_WARN_LOG="$TMP_ROOT/tools-warn.argv"
run_split_case_in_dir external-tools-warn "$TOOLS_WORKSPACE" env \
  HOME="$TOOLS_HOME" CODEX_HOME="$TOOLS_CODEX_HOME" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TOOLS_WARN_LOG" "$DISPATCH" --prompt x
expect_status 0 "external tools warn but do not stop by default"
expect_output "warn  : external tools outside the sandbox" "external-tools default remains warn-not-stop"

# Banner mismatch is post-start detection: it must fail nonzero and kill only
# the process group created for the child.
MISMATCH_HOME="$STATE_PARENT/mismatch-home"
MISMATCH_WORKSPACE="$STATE_PARENT/mismatch-workspace"
mkdir -p "$MISMATCH_HOME/.codex" "$MISMATCH_WORKSPACE"
MISMATCH_KILLED="$TMP_ROOT/mismatch.killed"
run_split_case_in_dir banner-mismatch "$MISMATCH_WORKSPACE" env \
  HOME="$MISMATCH_HOME" CODEX_HOME="$MISMATCH_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/mismatch.argv" CODEX_STUB_ACTION=mismatch-hang \
  CODEX_STUB_SANDBOX=danger-full-access CODEX_STUB_KILLED="$MISMATCH_KILLED" \
  "$DISPATCH" --prompt x
expect_status 5 "banner sandbox mismatch fails nonzero"
expect_output "child process group terminated" "banner mismatch reports the bounded kill"
expect_first_line "$MISMATCH_KILLED" killed "banner mismatch kills the Codex child process group"

APPROVAL_HOME="$STATE_PARENT/approval-home"
APPROVAL_WORKSPACE="$STATE_PARENT/approval-workspace"
mkdir -p "$APPROVAL_HOME/.codex" "$APPROVAL_WORKSPACE"
APPROVAL_KILLED="$TMP_ROOT/approval.killed"
run_split_case_in_dir approval-mismatch "$APPROVAL_WORKSPACE" env \
  HOME="$APPROVAL_HOME" CODEX_HOME="$APPROVAL_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/approval.argv" CODEX_STUB_ACTION=mismatch-hang \
  CODEX_STUB_APPROVAL=on-request CODEX_STUB_KILLED="$APPROVAL_KILLED" \
  "$DISPATCH" --prompt x
expect_status 5 "banner approval mismatch fails nonzero"
expect_output "reported approval on-request, requested never" "approval mismatch names resolved and requested policy"
expect_first_line "$APPROVAL_KILLED" killed "approval mismatch kills the Codex child process group"

ABSENT_HOME="$STATE_PARENT/absent-home"
ABSENT_WORKSPACE="$STATE_PARENT/absent-workspace"
mkdir -p "$ABSENT_HOME/.codex" "$ABSENT_WORKSPACE"
run_split_case_in_dir banner-absent "$ABSENT_WORKSPACE" env \
  HOME="$ABSENT_HOME" CODEX_HOME="$ABSENT_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/absent.argv" CODEX_STUB_ACTION=no-banner \
  "$DISPATCH" --prompt x
expect_status 5 "absent policy banner fails closed"
expect_output "policy banner was absent or incomplete" "absent-banner refusal is explicit"
expect_stdout_exact "" "absent banner never emits the final message"

SPOOF_ONLY_HOME="$STATE_PARENT/spoof-only-home"
SPOOF_ONLY_WORKSPACE="$STATE_PARENT/spoof-only-workspace"
mkdir -p "$SPOOF_ONLY_HOME/.codex" "$SPOOF_ONLY_WORKSPACE"
run_split_case_in_dir banner-spoof-only "$SPOOF_ONLY_WORKSPACE" env \
  HOME="$SPOOF_ONLY_HOME" CODEX_HOME="$SPOOF_ONLY_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/spoof-only.argv" CODEX_STUB_ACTION=spoof-only \
  "$DISPATCH" --prompt x
expect_status 5 "turn output cannot synthesize a missing policy banner"
expect_output "policy banner was absent or incomplete" "spoof-only stream remains an absent-banner failure"
expect_stdout_exact "" "spoof-only absent banner emits no final message"

TRUNCATED_HOME="$STATE_PARENT/truncated-home"
TRUNCATED_WORKSPACE="$STATE_PARENT/truncated-workspace"
mkdir -p "$TRUNCATED_HOME/.codex" "$TRUNCATED_WORKSPACE"
run_split_case_in_dir banner-truncated "$TRUNCATED_WORKSPACE" env \
  HOME="$TRUNCATED_HOME" CODEX_HOME="$TRUNCATED_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/truncated.argv" CODEX_STUB_ACTION=truncated \
  "$DISPATCH" --prompt x
expect_status 5 "stream ending mid-banner fails closed"
expect_output "policy banner was absent or incomplete" "truncated stream is diagnosed as incomplete"

SPOOF_HOME="$STATE_PARENT/spoof-home"
SPOOF_WORKSPACE="$STATE_PARENT/spoof-workspace"
mkdir -p "$SPOOF_HOME/.codex" "$SPOOF_WORKSPACE"
run_split_case_in_dir banner-spoof-later "$SPOOF_WORKSPACE" env \
  HOME="$SPOOF_HOME" CODEX_HOME="$SPOOF_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/spoof.argv" CODEX_STUB_ACTION=spoof-later \
  "$DISPATCH" --prompt x
expect_status 0 "model-controlled policy-looking lines after the banner are ignored"
expect_output "sandbox (CLI reported): workspace-write" "later spoof cannot overwrite reported sandbox"
SPOOF_STATE="$(latest_run_state "$CASE_STDERR")"
if LC_ALL=C grep -qx $'session_id\t019c0000-0000-7000-8000-000000000001' "$SPOOF_STATE/meta.tsv"; then
  pass "later spoof cannot replace the banner session id"
else
  fail "later spoof cannot replace the banner session id"
fi

EMPTY_HOME="$STATE_PARENT/empty-home"
EMPTY_WORKSPACE="$STATE_PARENT/empty-workspace"
mkdir -p "$EMPTY_HOME/.codex" "$EMPTY_WORKSPACE"
run_split_case_in_dir output-empty "$EMPTY_WORKSPACE" env \
  HOME="$EMPTY_HOME" CODEX_HOME="$EMPTY_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/output-empty.argv" CODEX_STUB_ACTION=empty-output \
  "$DISPATCH" --prompt x
expect_status 5 "empty -o result fails closed"
expect_output "state file is empty" "empty -o refusal identifies the result file"
expect_stdout_exact "" "empty -o result emits nothing on stdout"

MISSING_HOME="$STATE_PARENT/missing-home"
MISSING_WORKSPACE="$STATE_PARENT/missing-workspace"
mkdir -p "$MISSING_HOME/.codex" "$MISSING_WORKSPACE"
run_split_case_in_dir output-missing "$MISSING_WORKSPACE" env \
  HOME="$MISSING_HOME" CODEX_HOME="$MISSING_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/output-missing.argv" CODEX_STUB_ACTION=missing-output \
  "$DISPATCH" --prompt x
expect_status 5 "missing -o result fails closed"
expect_output "state file is not a regular file" "missing -o refusal identifies the result file"

NONZERO_HOME="$STATE_PARENT/nonzero-home"
NONZERO_WORKSPACE="$STATE_PARENT/nonzero-workspace"
mkdir -p "$NONZERO_HOME/.codex" "$NONZERO_WORKSPACE"
run_split_case_in_dir cli-nonzero "$NONZERO_WORKSPACE" env \
  HOME="$NONZERO_HOME" CODEX_HOME="$NONZERO_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/nonzero.argv" CODEX_STUB_ACTION=nonzero \
  "$DISPATCH" --prompt x
expect_status 7 "Codex real nonzero exit propagates unmodified"
expect_stdout_exact "" "nonzero Codex exit never emits a final message"

SIGNAL_HOME="$STATE_PARENT/signal-home"
SIGNAL_WORKSPACE="$STATE_PARENT/signal-workspace"
mkdir -p "$SIGNAL_HOME/.codex" "$SIGNAL_WORKSPACE"
run_split_case_in_dir cli-signal "$SIGNAL_WORKSPACE" env \
  HOME="$SIGNAL_HOME" CODEX_HOME="$SIGNAL_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/signal.argv" CODEX_STUB_ACTION=signal \
  "$DISPATCH" --prompt x
expect_status 143 "signal-terminated Codex is reported as 128 plus signal"
expect_output "terminated by signal 15" "signal termination is diagnosed"

# A failed/no-record workspace cannot resume and never falls back to --last.
NO_READY_HOME="$STATE_PARENT/no-ready-home"
NO_READY_WORKSPACE="$STATE_PARENT/no-ready-workspace"
mkdir -p "$NO_READY_HOME/.codex" "$NO_READY_WORKSPACE"
rm -f "$TMP_ROOT/no-ready.argv"
run_split_case_in_dir resume-no-ready "$NO_READY_WORKSPACE" env \
  HOME="$NO_READY_HOME" CODEX_HOME="$NO_READY_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/no-ready.argv" "$RESUME_DISPATCH" --prompt x --resume
expect_status 5 "--resume with no ready record fails closed"
expect_output "no ready loop-owned record" "no-ready resume points to a fresh dispatch"
expect_missing_file "$TMP_ROOT/no-ready.argv" "no-ready resume never launches Codex or --last"

# Explicit unmanaged migration adopts the exact id, after which ordinary
# managed resume selects that loop-owned ready record.
ADOPT_HOME="$STATE_PARENT/adopt-home"
ADOPT_WORKSPACE="$STATE_PARENT/adopt-workspace"
mkdir -p "$ADOPT_HOME/.codex" "$ADOPT_WORKSPACE"
ADOPT_ID="019c0000-0000-7000-8000-0000000000aa"
run_split_case_in_dir resume-unmanaged "$ADOPT_WORKSPACE" env \
  HOME="$ADOPT_HOME" CODEX_HOME="$ADOPT_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/adopt-unmanaged.argv" CODEX_STUB_SESSION="$ADOPT_ID" \
  "$RESUME_DISPATCH" --prompt migrate --resume-unmanaged "$ADOPT_ID"
expect_status 0 "successful unmanaged exact-id resume is adopted"
expect_argv_sequence "$TMP_ROOT/adopt-unmanaged.argv" "unmanaged migration binds its exact id" exec resume "$ADOPT_ID"
run_split_case_in_dir resume-adopted "$ADOPT_WORKSPACE" env \
  HOME="$ADOPT_HOME" CODEX_HOME="$ADOPT_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/adopt-managed.argv" CODEX_STUB_SESSION="$ADOPT_ID" \
  "$RESUME_DISPATCH" --prompt iterate --resume
expect_status 0 "ordinary --resume uses the adopted loop-owned id"
expect_argv_sequence "$TMP_ROOT/adopt-managed.argv" "adopted managed resume binds the same exact id" exec resume "$ADOPT_ID"

create_ready_fixture() { # $1=name; sets FIX_HOME FIX_WORKSPACE FIX_STATE
  local name="$1"
  FIX_HOME="$STATE_PARENT/$name-home"
  FIX_WORKSPACE="$STATE_PARENT/$name-workspace"
  mkdir -p "$FIX_HOME/.codex" "$FIX_WORKSPACE"
  run_split_case_in_dir "$name-ready" "$FIX_WORKSPACE" env \
    HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
    CODEX_STUB_LOG="$TMP_ROOT/$name-ready.argv" "$DISPATCH" --prompt ready
  if [[ $CASE_STATUS -eq 0 ]]; then
    FIX_STATE="$(latest_run_state "$CASE_STDERR")"
  else
    FIX_STATE=""
  fi
}

create_ready_fixture tampered
if [[ -n "$FIX_STATE" ]]; then
  sed $'s/^state\tready$/state\tcorrupt/' "$FIX_STATE/meta.tsv" > "$TMP_ROOT/tampered-meta.tsv"
  chmod 600 "$TMP_ROOT/tampered-meta.tsv"
  mv "$TMP_ROOT/tampered-meta.tsv" "$FIX_STATE/meta.tsv"
fi
rm -f "$TMP_ROOT/tampered-next.argv"
run_split_case_in_dir state-tampered "$FIX_WORKSPACE" env \
  HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/tampered-next.argv" "$DISPATCH" --prompt next
expect_status 5 "tampered state record refuses dispatch"
expect_output "invalid schema or lifecycle" "tampered record refusal names invalid state"
expect_missing_file "$TMP_ROOT/tampered-next.argv" "tampered state refuses before Codex launch"

create_ready_fixture foreign
rm -f "$TMP_ROOT/foreign-next.argv"
run_split_case_in_dir state-foreign "$FIX_WORKSPACE" env \
  HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_LOOP_SELFTEST_FOREIGN_META=1 CODEX_STUB_LOG="$TMP_ROOT/foreign-next.argv" \
  "$DISPATCH" --prompt next
expect_status 5 "foreign-owned state record refuses dispatch"
expect_output "state file is foreign-owned" "foreign-owner refusal is explicit"
expect_missing_file "$TMP_ROOT/foreign-next.argv" "foreign-owned record refuses before Codex launch"

create_ready_fixture symlinked
if [[ -n "$FIX_STATE" ]]; then
  mv "$FIX_STATE/meta.tsv" "$FIX_STATE/meta.real"
  ln -s meta.real "$FIX_STATE/meta.tsv"
fi
rm -f "$TMP_ROOT/symlinked-next.argv"
run_split_case_in_dir state-symlinked "$FIX_WORKSPACE" env \
  HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/symlinked-next.argv" "$DISPATCH" --prompt next
expect_status 5 "symlinked state record refuses dispatch"
expect_output "unexpected entry in dispatch state" "symlinked record cannot hide its target file"
expect_missing_file "$TMP_ROOT/symlinked-next.argv" "symlinked record refuses before Codex launch"

create_ready_fixture hardlinked
if [[ -n "$FIX_STATE" ]]; then
  ln "$FIX_STATE/meta.tsv" "$TMP_ROOT/meta-hardlink"
fi
rm -f "$TMP_ROOT/hardlinked-next.argv"
run_split_case_in_dir state-hardlinked "$FIX_WORKSPACE" env \
  HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/hardlinked-next.argv" "$DISPATCH" --prompt next
expect_status 5 "hard-linked state record refuses dispatch"
expect_output "multiple hard links" "hard-link refusal is explicit"
expect_missing_file "$TMP_ROOT/hardlinked-next.argv" "hard-linked record refuses before Codex launch"

# `current` is only a cache: an authoritative scan repairs a bad pointer.
create_ready_fixture current-cache
if [[ -n "$FIX_STATE" ]]; then
  printf 'not-a-dispatch\n' > "$(dirname "$FIX_STATE")/current"
fi
run_split_case_in_dir current-repair "$FIX_WORKSPACE" env \
  HOME="$FIX_HOME" CODEX_HOME="$FIX_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/current-repair.argv" "$DISPATCH" --prompt next
expect_status 0 "authoritative scan ignores and repairs a stale current cache"
REPAIRED_STATE="$(latest_run_state "$CASE_STDERR")"
expect_first_line "$(dirname "$REPAIRED_STATE")/current" "$(basename "$REPAIRED_STATE")" \
  "current cache is atomically repaired to the promoted record"

# Containment is canonical and symmetric across workdir, /tmp, and TMPDIR.
HOME_WORKSPACE="$STATE_PARENT/home-is-workspace"
mkdir -p "$HOME_WORKSPACE/.codex"
rm -f "$TMP_ROOT/home-workspace.argv"
run_split_case_in_dir containment-home "$HOME_WORKSPACE" env \
  HOME="$HOME_WORKSPACE" CODEX_HOME="$HOME_WORKSPACE/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/home-workspace.argv" "$DISPATCH" --prompt x
expect_status 5 "workspace equal to HOME refuses overlapping state"
expect_output "state root overlaps a sandbox writable root" "workspace-HOME overlap names containment"
expect_missing_file "$TMP_ROOT/home-workspace.argv" "workspace-HOME overlap refuses before Codex launch"

TMP_HOME="$SLASH_TMP_PARENT/home-under-tmp"
TMP_HOME_WORKSPACE="$STATE_PARENT/tmp-home-workspace"
mkdir -p "$TMP_HOME/.codex" "$TMP_HOME_WORKSPACE"
rm -f "$TMP_ROOT/tmp-home.argv"
run_split_case_in_dir containment-tmp-home "$TMP_HOME_WORKSPACE" env \
  HOME="$TMP_HOME" CODEX_HOME="$TMP_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/tmp-home.argv" "$DISPATCH" --prompt x
expect_status 5 "HOME under /tmp refuses overlapping state"
expect_output "state root overlaps a sandbox writable root" "HOME-under-tmp overlap names containment"
expect_missing_file "$TMP_ROOT/tmp-home.argv" "HOME-under-tmp overlap refuses before Codex launch"

ALIAS_HOME="$STATE_PARENT/alias-home"
ALIAS_WORKSPACE="$STATE_PARENT/alias-workspace"
TMP_ALIAS="$STATE_PARENT/tmp-alias"
mkdir -p "$ALIAS_HOME/.codex" "$ALIAS_WORKSPACE"
ln -s "$ALIAS_HOME" "$TMP_ALIAS"
rm -f "$TMP_ROOT/alias.argv"
run_split_case_in_dir containment-symlink-alias "$ALIAS_WORKSPACE" env \
  HOME="$ALIAS_HOME" CODEX_HOME="$ALIAS_HOME/.codex" TMPDIR="$TMP_ALIAS" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/alias.argv" "$DISPATCH" --prompt x
expect_status 5 "canonical containment refuses a TMPDIR symlink alias"
expect_output "state root overlaps a sandbox writable root" "symlink alias collision is detected after canonicalization"
expect_missing_file "$TMP_ROOT/alias.argv" "symlink-alias overlap refuses before Codex launch"

# A killed wrapper leaves a decisive running generation. Once the descriptor
# lock is released, neither fresh nor resume may fall back to the older ready
# generation while the Codex child remains alive.
CRASH_HOME="$STATE_PARENT/crash-home"
CRASH_WORKSPACE="$STATE_PARENT/crash-workspace"
mkdir -p "$CRASH_HOME/.codex" "$CRASH_WORKSPACE"
run_split_case_in_dir crash-ready "$CRASH_WORKSPACE" env \
  HOME="$CRASH_HOME" CODEX_HOME="$CRASH_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/crash-ready.argv" "$DISPATCH" --prompt ready
expect_status 0 "wrapper-crash fixture first records an older ready generation"

CRASH_WRAPPER_OUT="$TMP_ROOT/crash-wrapper.out"
CRASH_CHILD_FILE="$TMP_ROOT/crash-child.pid"
(
  cd "$CRASH_WORKSPACE" || exit 1
  exec env HOME="$CRASH_HOME" CODEX_HOME="$CRASH_HOME/.codex" PATH="$TEST_PATH" \
    CODEX_STUB_LOG="$TMP_ROOT/crash-running.argv" CODEX_STUB_ACTION=hold \
    CODEX_STUB_CHILD_PID="$CRASH_CHILD_FILE" "$DISPATCH" --prompt running
) > "$CRASH_WRAPPER_OUT" 2>&1 &
CRASH_WRAPPER_PID=$!
for wait_index in 1 2 3 4 5 6 7 8 9 10; do
  [[ ! -s "$CRASH_CHILD_FILE" ]] || break
  sleep 0.1
done
if [[ -s "$CRASH_CHILD_FILE" ]]; then
  CRASH_CHILD_PID="$(sed -n '1p' "$CRASH_CHILD_FILE")"
  pass "wrapper-crash fixture leaves a live Codex child"
else
  fail "wrapper-crash fixture leaves a live Codex child"
fi
kill -KILL "$CRASH_WRAPPER_PID" 2>/dev/null || true
wait "$CRASH_WRAPPER_PID" 2>/dev/null || true

rm -f "$TMP_ROOT/crash-next.argv"
run_split_case_in_dir crash-next-fresh "$CRASH_WORKSPACE" env \
  HOME="$CRASH_HOME" CODEX_HOME="$CRASH_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/crash-next.argv" "$DISPATCH" --prompt next
expect_status 5 "next fresh dispatch refuses the highest running generation"
expect_output "highest generation is still running" "fresh refusal names the running record"
expect_missing_file "$TMP_ROOT/crash-next.argv" "fresh dispatch does not fall back past the running record"

rm -f "$TMP_ROOT/crash-resume.argv"
run_split_case_in_dir crash-next-resume "$CRASH_WORKSPACE" env \
  HOME="$CRASH_HOME" CODEX_HOME="$CRASH_HOME/.codex" PATH="$TEST_PATH" \
  CODEX_STUB_LOG="$TMP_ROOT/crash-resume.argv" "$RESUME_DISPATCH" --prompt next --resume
expect_status 5 "next resume refuses the highest running generation"
expect_output "highest generation is still running" "resume refusal names the running record"
expect_missing_file "$TMP_ROOT/crash-resume.argv" "resume does not fall back to the older ready record or --last"
if [[ -n "$CRASH_CHILD_PID" ]]; then
  kill -TERM "-$CRASH_CHILD_PID" 2>/dev/null || true
  CRASH_CHILD_PID=""
fi

# Without a baseline, run-gate keeps the suite's pass-through behavior.
run_case gate-pass bash "$GATE" --log "$TMP_ROOT/gate-pass.log" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK\n'\'''
expect_status 0 "gate passes a successful command"
expect_output "RESULT: gate green" "gate prints its normal green result"

# Without --baseline, an exit-zero command with no output remains a pass-through
# success even though no supported-runner summary is present.
run_case gate-plain-empty bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-empty.log" -- bash -c ':'
expect_status 0 "plain gate preserves exit-zero empty-output pass-through"
expect_output "RESULT: gate green" "plain gate keeps its empty-output green result"

# A runner-owned failed summary contradicts exit zero even without --baseline.
run_case gate-plain-masked-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-masked-summary.log" -- \
  bash -c 'printf '\''=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "plain gate rejects an exit-zero pytest failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a pytest summary/exit contradiction"

# Individual failure-looking lines may be application logs, so plain mode still
# passes them through when no formal runner summary reports a failure.
run_case gate-plain-failure-line bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-failure-line.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n'\'''
expect_status 0 "plain gate preserves an exit-zero individual failure-line pass-through"
expect_output "RESULT: gate green" \
  "plain gate tolerates an individual failure line without a summary"

run_case gate-plain-unittest-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-unittest-summary.log" -- \
  bash -c 'printf '\''FAILED (failures=1)\n'\'''
expect_status 1 "plain gate rejects an exit-zero unittest failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a unittest summary/exit contradiction"

# pytest -q emits its summary without fences; a failing quiet summary must
# contradict a masked exit-zero even without --baseline.
run_case gate-plain-quiet-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-quiet-masked.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n1 failed in 0.01s\n'\'''
expect_status 1 "plain gate rejects an exit-zero quiet-mode failed summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate diagnoses a quiet-mode summary/exit contradiction"

# Positive error counts (collection errors) are failure evidence too.
run_case gate-plain-error-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-error-masked.log" -- \
  bash -c 'printf '\''ERROR test_collect.py - RuntimeError: boom\n=========================== 1 error in 0.04s ===========================\n'\'''
expect_status 1 "plain gate rejects an exit-zero errors summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate treats positive error counts as failure evidence"

# The quiet form only counts when it matches the full official pytest shape,
# so application log lines mentioning failure counts stay out of the check.
run_case gate-plain-quiet-lookalike bash "$GATE" \
  --log "$TMP_ROOT/gate-plain-quiet-lookalike.log" -- \
  bash -c 'printf '\''deploy: 3 failed in the last hour\n2 failed in staging\n'\'''
expect_status 0 "plain gate ignores failure-count words outside a formal summary shape"
expect_output "RESULT: gate green" \
  "plain gate keeps lookalike log lines out of the consistency check"

EMPTY_BASELINE="$TMP_ROOT/empty-baseline.log"
: > "$EMPTY_BASELINE"
run_case gate-baseline-masked-new bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-masked-new.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n'\'''
expect_status 1 "baseline gate rejects an exit-zero run with a new parsed failure"
expect_output "RESULT: gate RED — exit 0 but failure lines present (is the runner masking its exit code?)" \
  "baseline gate retains its stricter line-only masking check"

# Quiet-mode summaries are first-class execution evidence under --baseline:
# a passing -q run is green, a baseline-matched -q failure is green, and a
# quiet no-tests run still fails closed.
run_case gate-quiet-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''.\n2 passed in 0.03s\n'\'''
expect_status 0 "baseline gate accepts a passing pytest -q run"
expect_output "RESULT: gate green" \
  "baseline gate recognizes the quiet-mode passed summary as executed tests"

QUIET_BASELINE="$TMP_ROOT/pytest-quiet-baseline.log"
write_lines "$QUIET_BASELINE" \
  'FAILED tests/test_widget.py::test_flaky - AssertionError: detail' \
  '1 failed in 0.01s'
run_case gate-quiet-known bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-known.log" --baseline "$QUIET_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_flaky - AssertionError: detail\n1 failed in 0.01s\n'\''; exit 1'
expect_status 0 "baseline gate matches a known failure reported by a quiet-mode summary"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "baseline gate counts quiet-mode failed summaries as executed tests"

run_case gate-quiet-no-tests bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-no-tests.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''no tests ran in 0.01s\n'\'''
expect_nonzero "baseline gate fails closed on a quiet-mode no-tests run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "baseline gate reads the quiet-mode no-tests summary"

# A shared log/baseline target must be rejected before the command can truncate
# it. The first case exercises normalized string equality before either exists;
# the second exercises filesystem identity through a symlink alias.
SAME_PATH="$TMP_ROOT/gate-same-path.log"
run_case gate-same-path bash "$GATE" \
  --log "$SAME_PATH" --baseline "$SAME_PATH" -- bash -c 'exit 99'
expect_status 2 "gate rejects identical --log and --baseline strings"
expect_output "--log and --baseline refer to the same file" \
  "gate explains the identical-path configuration error"

SAME_TARGET="$TMP_ROOT/gate-same-target.log"
SAME_ALIAS="$TMP_ROOT/gate-same-alias.log"
write_lines "$SAME_TARGET" 'existing baseline evidence'
ln -s "$SAME_TARGET" "$SAME_ALIAS"
run_case gate-same-alias bash "$GATE" \
  --log "$SAME_ALIAS" --baseline "$SAME_TARGET" -- bash -c 'exit 99'
expect_status 2 "gate rejects a symlink alias of the baseline"
expect_output "--log and --baseline refer to the same file" \
  "gate explains the filesystem-alias configuration error"

DANGLING_BASELINE="$TMP_ROOT/gate-dangling-baseline.log"
DANGLING_LOG="$TMP_ROOT/gate-dangling-log.log"
ln -s "$DANGLING_BASELINE" "$DANGLING_LOG"
run_case gate-dangling-alias bash "$GATE" \
  --log "$DANGLING_LOG" --baseline "$DANGLING_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - RuntimeError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_nonzero "gate rejects or fails closed for a dangling log symlink to the baseline"
expect_no_output "gate green" \
  "gate never reports green for a dangling log symlink to the baseline"

UNIT_BASELINE="$TMP_ROOT/unittest-baseline.log"
write_lines "$UNIT_BASELINE" \
  'FAIL: test_known (tests.Case.test_known)' \
  'Ran 1 test in 0.001s' \
  'FAILED (failures=1)'

run_case gate-unittest-new bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-new.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_new (tests.Case.test_new)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 7'
expect_status 7 "gate stays nonzero for a new unittest failure"
expect_output "FAIL: test_new (tests.Case.test_new)" \
  "gate lists the new unittest failure"

run_case gate-unittest-match bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-match.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 1'
expect_status 0 "gate exits zero when unittest failures match baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate reports baseline-clean unittest failures"

run_case gate-unittest-mixed bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-mixed.log" --baseline "$UNIT_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 3 tests in 0.001s\nFAILED (failures=1, skipped=2)\n'\''; exit 1'
expect_status 0 "gate accepts a known unittest failure when one test executed and two skipped"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate counts only non-skipped unittest tests as executed"

UNIT_SUBSET_BASELINE="$TMP_ROOT/unittest-subset-baseline.log"
write_lines "$UNIT_SUBSET_BASELINE" \
  'FAIL: test_known (tests.Case.test_known)' \
  'FAIL: test_other (tests.Case.test_other)' \
  'Ran 2 tests in 0.001s' \
  'FAILED (failures=2)'
run_case gate-unittest-subset bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-subset.log" --baseline "$UNIT_SUBSET_BASELINE" -- \
  bash -c 'printf '\''FAIL: test_known (tests.Case.test_known)\nRan 1 test in 0.001s\nFAILED (failures=1)\n'\''; exit 1'
expect_status 0 "gate exits zero when unittest failures are a subset of baseline"

PYTEST_BASELINE="$TMP_ROOT/pytest-baseline.log"
write_lines "$PYTEST_BASELINE" \
  'FAILED tests/test_widget.py::test_value - AssertionError: old detail' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-baseline-masked-known bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-masked-known.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: old detail\n=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "baseline gate rejects exit-zero failures even when they match baseline"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "baseline gate applies the shared summary/exit consistency check"

# The log is created fresh for THIS run: an uncreatable log aborts before
# the command starts (stale content must never match a baseline on behalf
# of a command that never ran).
UNWRITABLE_DIR="$TMP_ROOT/gate-readonly-dir"
mkdir -p "$UNWRITABLE_DIR"
write_lines "$UNWRITABLE_DIR/stale.log" \
  'FAILED tests/test_widget.py::test_value - AssertionError: old detail' \
  '=========================== 1 failed in 0.01s ==========================='
chmod 555 "$UNWRITABLE_DIR"
run_case gate-unwritable-log bash "$GATE" \
  --log "$UNWRITABLE_DIR/stale.log" --baseline "$PYTEST_BASELINE" -- bash -c 'exit 1'
expect_status 2 "gate refuses an uncreatable log instead of parsing its stale content"
expect_output "cannot exclusively create log" "gate explains the uncreatable log"
chmod 755 "$UNWRITABLE_DIR"

# Symlinked logs are refused, and the exclusive create means the link's
# TARGET is never truncated — a plain redirect would have emptied it.
SYMLINK_TARGET="$TMP_ROOT/gate-symlink-target.log"
SYMLINK_LOG="$TMP_ROOT/gate-symlink.log"
write_lines "$SYMLINK_TARGET" 'precious pre-existing content'
ln -s "$SYMLINK_TARGET" "$SYMLINK_LOG"
run_case gate-symlink-log bash "$GATE" --log "$SYMLINK_LOG" -- bash -c ':'
expect_status 2 "gate refuses a symlinked log"
expect_output "must not be a symlink" "gate explains the symlink rejection"
expect_file_line "$SYMLINK_TARGET" "precious pre-existing content" \
  "gate leaves a symlink target untruncated"

# Only the runner's own tests-failed status (1) may be offset by a baseline;
# signals, crashes, and interrupts never baseline away.
run_case gate-signal-exit bash "$GATE" \
  --log "$TMP_ROOT/gate-signal.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: old detail\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 137'
expect_status 137 "gate keeps an abnormal exit code even when failures match baseline"
expect_output "abnormal runner exit (137)" "gate explains the abnormal-exit rejection"

# The verdict reads through the descriptor the command wrote: a log path
# swapped mid-run — even for green-looking content — is not judged.
SWAP_LOG="$TMP_ROOT/gate-swap.log"
run_case gate-log-swap bash "$GATE" --log "$SWAP_LOG" -- \
  bash -c "rm -f '$SWAP_LOG'; printf '=========================== 1 passed in 0.01s ===========================\n' > '$SWAP_LOG'"
expect_status 1 "gate rejects a log replaced during the run"
expect_output "log file was replaced during the run" \
  "gate explains the mid-run log swap"

run_case gate-pytest-message-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-message-change.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - AssertionError: new detail\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate baselines a pytest message-only change with the same exception class"
expect_output "--- 1 failure/error header(s) ---" \
  "gate extracts the pytest FAILED short-summary line"
expect_output "FAILED tests/test_widget.py::test_value [AssertionError]" \
  "gate retains the pytest exception class in its stable identifier"

run_case gate-pytest-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-class-change.log" --baseline "$PYTEST_BASELINE" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_value - RuntimeError: deterministic regression\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects the same pytest test ID with a different exception class"
expect_output "FAILED tests/test_widget.py::test_value [RuntimeError]" \
  "gate reports the changed pytest exception class as a new failure"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate marks a pytest exception-class change red"

PYTEST_AMBIGUOUS_BASELINE="$TMP_ROOT/pytest-ambiguous-baseline.log"
write_lines "$PYTEST_AMBIGUOUS_BASELINE" \
  'FAILED t.py::test_value[a] - b] - AssertionError: x' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-pytest-ambiguous-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-ambiguous-class-change.log" \
  --baseline "$PYTEST_AMBIGUOUS_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[a] - b] - RuntimeError: x\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change for an ambiguous pytest parameter ID"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate fails closed instead of guessing how to split an ambiguous pytest line"

run_case gate-pytest-ambiguous-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-ambiguous-identical.log" \
  --baseline "$PYTEST_AMBIGUOUS_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[a] - b] - AssertionError: x\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical whole-line ambiguous pytest failure"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps stable whole-line identifiers green when truly unchanged"

PYTEST_PARAM_BASELINE="$TMP_ROOT/pytest-param-baseline.log"
write_lines "$PYTEST_PARAM_BASELINE" \
  'FAILED t.py::test_v[a - b] - AssertionError: msg' \
  '=========================== 1 failed in 0.01s ==========================='
# The raw-separator rule deliberately keeps these whole-line identifiers: the
# parameter ID contributes a second " - ", so even message-only changes are red.
run_case gate-pytest-param-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-param-class-change.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - RuntimeError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change when a pytest parameter ID contains a raw separator"
expect_output "FAILED t.py::test_v[a - b] - RuntimeError: msg" \
  "gate keeps the raw-separator class-change line whole"

run_case gate-pytest-raw-separator-message-change-red bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-raw-separator-message-change-red.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - AssertionError: changed message\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate intentionally rejects a message-only change when two raw separators are present"
expect_output "FAILED t.py::test_v[a - b] - AssertionError: changed message" \
  "gate keeps the raw-separator message-change line whole"

run_case gate-pytest-param-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-param-identical.log" \
  --baseline "$PYTEST_PARAM_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_v[a - b] - AssertionError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches identical whole-line pytest parameter failures"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps identical raw-separator lines green"

PYTEST_ADVERSARIAL_BASELINE="$TMP_ROOT/pytest-adversarial-baseline.log"
write_lines "$PYTEST_ADVERSARIAL_BASELINE" \
  'FAILED t.py::test_value[x] - RuntimeError y[[] - AssertionError: msg' \
  '=========================== 1 failed in 0.01s ==========================='
run_case gate-pytest-adversarial-class-change bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-adversarial-class-change.log" \
  --baseline "$PYTEST_ADVERSARIAL_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[x] - RuntimeError y[[] - ValueError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a class change hidden behind an adversarial pytest parameter ID"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "gate fails closed for an adversarial parameter-ID class change"

run_case gate-pytest-adversarial-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-pytest-adversarial-identical.log" \
  --baseline "$PYTEST_ADVERSARIAL_BASELINE" -- \
  bash -c 'printf '\''FAILED t.py::test_value[x] - RuntimeError y[[] - AssertionError: msg\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical adversarial pytest failure line"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps an unchanged adversarial whole-line identifier green"

# pytest 9 native subtests: the parent FAILED line is constant, the specific
# failing subtest lives in the SUBFAILED line — a shifted subtest is new.
PYTEST_SUBTEST_BASELINE="$TMP_ROOT/pytest-subtest-baseline.log"
write_lines "$PYTEST_SUBTEST_BASELINE" \
  'SUBFAILED(value=0) t.py::test_contains - AssertionError: value 0 broke' \
  'FAILED t.py::test_contains - contains 1 failed subtest' \
  '=========================== 2 failed in 0.01s ==========================='
run_case gate-subtest-shift bash "$GATE" \
  --log "$TMP_ROOT/gate-subtest-shift.log" --baseline "$PYTEST_SUBTEST_BASELINE" -- \
  bash -c 'printf '\''SUBFAILED(value=1) t.py::test_contains - AssertionError: value 1 broke\nFAILED t.py::test_contains - contains 1 failed subtest\n=========================== 2 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "gate rejects a shifted failing subtest behind an unchanged parent FAILED line"
expect_output "SUBFAILED(value=1) t.py::test_contains [AssertionError]" \
  "gate fingerprints the specific SUBFAILED identity"

run_case gate-subtest-identical bash "$GATE" \
  --log "$TMP_ROOT/gate-subtest-identical.log" --baseline "$PYTEST_SUBTEST_BASELINE" -- \
  bash -c 'printf '\''SUBFAILED(value=0) t.py::test_contains - AssertionError: value 0 broke\nFAILED t.py::test_contains - contains 1 failed subtest\n=========================== 2 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 0 "gate matches an identical failing subtest against baseline"
expect_output "RESULT: gate green (failures match baseline — no new failures)" \
  "gate keeps a baseline-matched subtest failure green"

# Execution evidence is the LAST formal summary. A summary-shaped line printed
# earlier (application output, an inner pytest run) must not vouch for a run
# whose real final summary shows no executed tests — and conversely an inner
# failed summary must not red a run whose final summary is clean.
FAKE_SUMMARY_BASELINE="$TMP_ROOT/fake-summary-baseline.log"
write_lines "$FAKE_SUMMARY_BASELINE" \
  'ERROR t.py - RuntimeError: collection failed'
run_case gate-early-fake-summary bash "$GATE" \
  --log "$TMP_ROOT/gate-early-fake-summary.log" --baseline "$FAKE_SUMMARY_BASELINE" -- \
  bash -c 'printf '\''1 passed in 0.01s\nERROR t.py - RuntimeError: collection failed\n=========================== 1 error in 0.04s ===========================\n'\''; exit 2'
expect_status 2 "gate ignores a summary-shaped line printed before the real final summary"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate takes execution evidence only from the final formal summary"

run_case gate-nested-runner bash "$GATE" \
  --log "$TMP_ROOT/gate-nested-runner.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''1 failed in 0.10s\n=========================== 3 passed in 1.20s ===========================\n'\'''
expect_status 0 "gate trusts the outer runner final summary over an inner run captured mid-log"
expect_output "RESULT: gate green" \
  "gate stays green when an inner failed summary precedes a passing final summary"

# Native-subtests quiet summaries add `N subtests passed/failed` terms.
run_case gate-quiet-subtests-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-subtests-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''uu.\n1 passed, 2 subtests passed in 0.00s\n'\'''
expect_status 0 "baseline gate accepts a passing quiet run with native subtests counts"
expect_output "RESULT: gate green" \
  "baseline gate parses the subtests quiet summary as executed tests"
expect_output "1 passed, 2 subtests passed in 0.00s" \
  "gate surfaces the subtests quiet summary in its preview"

run_case gate-quiet-subtests-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-quiet-subtests-masked.log" -- \
  bash -c 'printf '\''SUBFAILED(value=1) t.py::test_contains - AssertionError: boom\nFAILED t.py::test_contains - contains 1 failed subtest\n2 failed, 1 subtests passed in 0.01s\n'\'''
expect_status 1 "plain gate rejects a masked exit-zero subtests failed quiet summary"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "plain gate reads failed counts from the subtests quiet summary"

# The verdict is the LAST runner block of either kind: unittest output from an
# inner child must not vouch for an outer pytest run, and an inner unittest
# failure must not red a clean outer pytest run.
CROSS_RUNNER_BASELINE="$TMP_ROOT/cross-runner-baseline.log"
write_lines "$CROSS_RUNNER_BASELINE" \
  'ERROR t.py - RuntimeError: collection failed'
run_case gate-cross-runner-inner-unittest bash "$GATE" \
  --log "$TMP_ROOT/gate-cross-runner-inner-unittest.log" \
  --baseline "$CROSS_RUNNER_BASELINE" -- \
  bash -c 'printf '\''Ran 3 tests in 0.001s\nOK\nERROR t.py - RuntimeError: collection failed\n=========================== 1 error in 0.04s ===========================\n'\''; exit 2'
expect_status 2 "gate ignores inner unittest output when the final verdict is a pytest collection error"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate refuses cross-runner execution evidence"

run_case gate-cross-runner-inner-unittest-failed bash "$GATE" \
  --log "$TMP_ROOT/gate-cross-runner-inner-unittest-failed.log" -- \
  bash -c 'printf '\''FAILED (failures=1)\n=========================== 3 passed in 1.20s ===========================\n'\'''
expect_status 0 "plain gate trusts the final pytest verdict over an inner unittest failed line"
expect_output "RESULT: gate green" \
  "plain gate stays green when an inner unittest failure precedes a passing final summary"

# Forced-color output (--color=yes) is parsed through an ANSI-stripped view.
run_case gate-ansi-pass bash "$GATE" \
  --log "$TMP_ROOT/gate-ansi-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''\033[32m\033[1m========== 1 passed\033[0m\033[32m in 0.01s ==========\033[0m\n'\'''
expect_status 0 "baseline gate recognizes a color-wrapped passing summary"
expect_output "RESULT: gate green" \
  "baseline gate parses ANSI-colored fenced summaries"

run_case gate-ansi-masked bash "$GATE" \
  --log "$TMP_ROOT/gate-ansi-masked.log" -- \
  bash -c 'printf '\''\033[31mFAILED t.py::test_x - AssertionError: boom\033[0m\n\033[31m========== 1 failed in 0.01s ==========\033[0m\n'\'''
expect_status 1 "plain gate sees a color-wrapped failed summary through the ANSI stripping"
expect_output "FAILED t.py::test_x [AssertionError]" \
  "gate extracts fingerprints from color-wrapped failure lines"

# Logs are arbitrary bytes. In a UTF-8 locale an invalid byte used to abort
# sed with an empty parse view, hiding a masked failure — parsing must be
# bytewise regardless of the ambient locale. Force a UTF-8 locale when the
# host offers one so the regression actually exercises that environment.
UTF8_LOCALE="$(locale -a 2>/dev/null | LC_ALL=C grep -i -m1 -E '^(en_US|C)\.utf-?8$' || true)"
[[ -n "$UTF8_LOCALE" ]] || UTF8_LOCALE=C
run_case gate-invalid-byte-masked env LC_ALL="$UTF8_LOCALE" bash "$GATE" \
  --log "$TMP_ROOT/gate-invalid-byte-masked.log" -- \
  bash -c 'printf '\''\377\nFAILED t.py::test_x - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\'''
expect_status 1 "gate parses a log containing invalid UTF-8 bytes bytewise ($UTF8_LOCALE)"
expect_output "RESULT: gate RED — runner summary reports failures but exit code is 0" \
  "gate stays fail-closed on a masked failure in a byte-poisoned log"

run_case gate-invalid-byte-pass env LC_ALL="$UTF8_LOCALE" bash "$GATE" \
  --log "$TMP_ROOT/gate-invalid-byte-pass.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''\377 binary noise\n=========================== 1 passed in 0.01s ===========================\n'\'''
expect_status 0 "baseline gate still recognizes a passing summary in a byte-poisoned log"
expect_output "RESULT: gate green" \
  "gate does not false-red on invalid bytes in a passing run"

# --strict is the real zero-failure mode: recognized verdict, executed tests,
# and no failure lines. Plain no-flag mode stays a documented pass-through.
run_case gate-strict-baseline-conflict bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-conflict.log" --baseline "$EMPTY_BASELINE" -- bash -c ':'
expect_status 2 "gate rejects --strict combined with --baseline"
expect_output "mutually exclusive" "gate explains the strict/baseline conflict"

run_case gate-strict-pass bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-pass.log" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\nOK\n'\'''
expect_status 0 "strict gate passes a real unittest success"
expect_output "RESULT: gate green" "strict gate reports green for executed passing tests"

run_case gate-strict-pytest-pass bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-pytest-pass.log" -- \
  bash -c 'printf '\''=========================== 2 passed in 0.10s ===========================\n'\'''
expect_status 0 "strict gate passes a fenced pytest success"

run_case gate-strict-empty bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-empty.log" -- bash -c ':'
expect_status 1 "strict gate rejects exit-zero empty output"
expect_output "strict needs a recognized unittest/pytest verdict" \
  "strict gate explains the missing runner verdict"

run_case gate-strict-zero-tests bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-zero.log" -- \
  bash -c 'printf '\''Ran 0 tests in 0.000s\nOK\n'\'''
expect_status 1 "strict gate rejects a zero-test OK run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or zero-test run" \
  "strict gate explains the zero-test rejection"

run_case gate-strict-failure-line bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-failure-line.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 2 passed in 0.10s ===========================\n'\'''
expect_status 1 "strict gate rejects stray failure lines even when the final summary is clean"
expect_output "RESULT: gate RED — failure lines present despite exit 0" \
  "strict gate explains the failure-line rejection"

run_case gate-strict-red bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-red.log" -- \
  bash -c 'printf '\''FAILED tests/test_widget.py::test_new - AssertionError: boom\n=========================== 1 failed in 0.01s ===========================\n'\''; exit 1'
expect_status 1 "strict gate passes the failing exit code through"
expect_output "RESULT: gate RED — do not publish until resolved or explained" \
  "strict gate reports red for a failing suite"

# A bare `Ran N tests` line with no paired OK/FAILED result is a truncated
# or masked run, not a complete unittest verdict.
run_case gate-strict-truncated-unittest bash "$GATE" --strict \
  --log "$TMP_ROOT/gate-strict-truncated.log" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\n'\'''
expect_status 1 "strict gate rejects a unittest count line without its result line"
expect_output "strict needs a recognized unittest/pytest verdict" \
  "strict gate treats a truncated unittest verdict as unrecognized"

run_case gate-baseline-truncated-unittest bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-truncated.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 2 tests in 0.001s\n'\'''
expect_nonzero "baseline gate rejects a unittest count line without its result line"
expect_output "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only" \
  "baseline gate treats a truncated unittest verdict as unrecognized"

CRASH_BASELINE="$TMP_ROOT/crash-baseline.log"
write_lines "$CRASH_BASELINE" 'ImportError: same crash text'
run_case gate-crash bash "$GATE" \
  --log "$TMP_ROOT/gate-crash.log" --baseline "$CRASH_BASELINE" -- \
  bash -c 'printf '\''ImportError: same crash text\n'\''; exit 9'
expect_status 9 "gate stays nonzero when no failure identifier is parseable"
expect_output "RESULT: gate RED — nonzero exit with no parseable failures (crash/collection error?)" \
  "gate explains an unparseable nonzero exit"

COLLECTION_BASELINE="$TMP_ROOT/collection-baseline.log"
write_lines "$COLLECTION_BASELINE" \
  'ERROR collecting t.py - RuntimeError: expected 1 passed check'
run_case gate-collection-count-words bash "$GATE" \
  --log "$TMP_ROOT/gate-collection-count-words.log" \
  --baseline "$COLLECTION_BASELINE" -- \
  bash -c 'printf '\''ERROR collecting t.py - RuntimeError: expected 1 passed check\n'\''; exit 2'
expect_status 2 "gate rejects collection-error count words without a formal pytest summary"
expect_output "RESULT: gate RED — failures parsed but no completed tests were reported" \
  "gate does not treat count words in an error message as test execution"

run_case gate-zero-tests bash "$GATE" \
  --log "$TMP_ROOT/gate-zero-tests.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 0 tests in 0.000s\nOK\n'\'''
expect_nonzero "baseline gate fails closed when unittest reports zero tests"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate reports that zero tests were executed"

run_case gate-unittest-skipped-only bash "$GATE" \
  --log "$TMP_ROOT/gate-unittest-skipped-only.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''Ran 1 test in 0.001s\nOK (skipped=1)\n'\'''
expect_nonzero "baseline gate rejects an exit-zero skipped-only unittest run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate subtracts unittest result-line skips from the reported test count"

run_case gate-skipped-only bash "$GATE" \
  --log "$TMP_ROOT/gate-skipped-only.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c 'printf '\''============================= 1 skipped in 0.10s =============================\n'\'''
expect_nonzero "baseline gate rejects an exit-zero skipped-only pytest run"
expect_output "RESULT: gate RED — no executed tests — skipped-only or unrecognized runner output" \
  "gate explains the skipped-only baseline failure"

run_case gate-baseline-empty bash "$GATE" \
  --log "$TMP_ROOT/gate-baseline-empty.log" --baseline "$EMPTY_BASELINE" -- \
  bash -c ':'
expect_nonzero "baseline gate rejects exit-zero empty output"
expect_output "RESULT: gate RED — unrecognized runner output; --baseline supports unittest/pytest only" \
  "gate fails closed on an unrecognized baseline runner"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
