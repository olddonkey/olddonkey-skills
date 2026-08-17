#!/usr/bin/env bash
# Local, opt-in integration gate for the real codex, grok, and cursor backends.
#
# This script makes authenticated API calls. It is syntax-checked in CI but is
# never run there. Model prompts are deliberately exact; failure to follow one
# is a real not-ok that an operator may re-run, not a reason to weaken a check.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
GROK_DISPATCH="$SCRIPT_DIR/../backends/grok/dispatch.sh"
CURSOR_DISPATCH="$SCRIPT_DIR/../backends/cursor/dispatch.sh"
CODEX_DISPATCH="$SCRIPT_DIR/../backends/codex/dispatch.sh"
CODEX_CASES="$SCRIPT_DIR/codex-cases.tsv"
CODEX_CASES_SHA256="60f4fb18faead53b5ddaa83c731a711ec64d89a8909a73099be19d432986bd7f"
TOML_PYTHON=""
TOML_CANDIDATES_TRIED="python3 python3.13 python3.12 python3.11"
SELECT_GROK=0
SELECT_CURSOR=0
SELECT_CODEX=0
SELECTOR_SEEN=0
REQUIRE_CODEX=0

usage() {
  cat <<'EOF'
Usage: integration-test.sh [--backend grok|cursor|codex|all]... [--require codex]

Run the local, authenticated integration gate for one or more real backends.
Backend selectors are repeatable and deduplicated; all selects all three.
--require codex implies selecting codex and fails on any non-managed skip,
missing/duplicate case, wrong outcome, or missing provenance.
Unavailable or logged-out backends are reported as skips.
EOF
}

select_backend() {
  case "$1" in
    grok) SELECT_GROK=1 ;;
    cursor) SELECT_CURSOR=1 ;;
    codex) SELECT_CODEX=1 ;;
    all) SELECT_GROK=1; SELECT_CURSOR=1; SELECT_CODEX=1 ;;
    *)
      echo "error: --backend must be grok, cursor, codex, or all" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      select_backend "${2:?--backend needs grok, cursor, codex, or all}"
      SELECTOR_SEEN=1
      shift 2
      ;;
    --require)
      [[ "${2:?--require needs codex}" == "codex" ]] || {
        echo "error: --require currently accepts only codex" >&2
        exit 2
      }
      REQUIRE_CODEX=1
      SELECT_CODEX=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $SELECTOR_SEEN -eq 0 && $REQUIRE_CODEX -eq 0 ]]; then
  select_backend all
fi

ORIGINAL_HOME_RAW="${HOME:?HOME is required}"
[[ -d "$ORIGINAL_HOME_RAW" ]] || {
  echo "error: HOME is not an existing directory: $ORIGINAL_HOME_RAW" >&2
  exit 2
}
ORIGINAL_HOME="$(CDPATH= cd -- "$ORIGINAL_HOME_RAW" && pwd -P)"
TMP_ROOT_RAW="$(mktemp -d "$ORIGINAL_HOME/.olddonkey-loop-integration.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
chmod 700 "$TMP_ROOT"
CODEX_SERVER_PID=""

cleanup() {
  if [[ -n "$CODEX_SERVER_PID" ]]; then
    kill "$CODEX_SERVER_PID" 2>/dev/null || true
  fi
  case "${TMP_ROOT:-}" in
    "$ORIGINAL_HOME"/.olddonkey-loop-integration.*)
      [[ ! -d "$TMP_ROOT" ]] || rm -rf -- "$TMP_ROOT"
      ;;
    "") ;;
    *) echo "warning: refusing unexpected integration cleanup path: $TMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

RESULTS=0
OK=0
SKIPPED=0
FAILURES=0
CODEX_RESULTS="$TMP_ROOT/codex-case-results.tsv"
CODEX_PROVENANCE="$TMP_ROOT/codex-provenance.tsv"
: > "$CODEX_RESULTS"

pass() {
  RESULTS=$((RESULTS + 1))
  OK=$((OK + 1))
  printf 'ok %d - %s\n' "$RESULTS" "$1"
}

fail() {
  RESULTS=$((RESULTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$RESULTS" "$1"
}

skip() { # $1=description $2=reason
  RESULTS=$((RESULTS + 1))
  SKIPPED=$((SKIPPED + 1))
  printf 'ok %d - %s # SKIP %s\n' "$RESULTS" "$1" "$2"
}

write_lines() { # $1=path, remaining args=lines
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

select_toml_python() {
  local candidate
  TOML_PYTHON=""
  for candidate in python3 python3.13 python3.12 python3.11; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import tomllib' 2>/dev/null; then
      TOML_PYTHON="$candidate"
      return 0
    fi
  done
  return 1
}

CODEX_MANIFEST_COUNTS="$TMP_ROOT/codex-manifest-counts.tsv"
if ! python3 - "$CODEX_CASES" "$CODEX_CASES_SHA256" > "$CODEX_MANIFEST_COUNTS" <<'PY'
import hashlib
import re
import sys

path, expected_digest = sys.argv[1:]
try:
    raw = open(path, "rb").read()
    lines = raw.decode("utf-8").splitlines()
except OSError as error:
    print(f"codex case manifest unreadable: {error}", file=sys.stderr)
    raise SystemExit(1)
if hashlib.sha256(raw).hexdigest() != expected_digest:
    print("codex case manifest does not match its frozen schema-1 digest", file=sys.stderr)
    raise SystemExit(1)
if not lines or lines[0] != "#schema=1":
    print("codex case manifest must start with #schema=1", file=sys.stderr)
    raise SystemExit(1)
rows = [line.split("\t") for line in lines[1:] if line and not line.startswith("#")]
if not rows or any(len(row) != 4 for row in rows):
    print("codex case manifest rows must have four columns", file=sys.stderr)
    raise SystemExit(1)
ids = [row[0] for row in rows]
valid = (
    len(ids) == len(set(ids))
    and all(re.fullmatch(r"[a-z][a-z0-9-]*", row[0]) for row in rows)
    and all(row[1] in {"always", "managed-only"} for row in rows)
    and all(row[2] in {"allow", "deny", "pass"} for row in rows)
    and sum(row[1] == "managed-only" for row in rows) == 1
)
if not valid:
    print("codex case manifest has invalid or duplicate values", file=sys.stderr)
    raise SystemExit(1)
print(sum(row[1] == "always" for row in rows), sum(row[1] == "managed-only" for row in rows), sep="\t")
PY
then
  echo "error: invalid codex case manifest: $CODEX_CASES" >&2
  exit 2
fi
IFS=$'\t' read -r CODEX_EXPECTED_ALWAYS CODEX_EXPECTED_MANAGED < "$CODEX_MANIFEST_COUNTS"

codex_expected() { # $1=id
  LC_ALL=C awk -F '\t' -v wanted="$1" '
    $0 !~ /^#/ && $1 == wanted { print $3; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$CODEX_CASES"
}

codex_recorded() { # $1=id
  LC_ALL=C grep -q "^$1"$'\t' "$CODEX_RESULTS"
}

record_codex_case() { # $1=id $2=actual outcome|skip $3=detail
  local id="$1" actual="$2" detail="$3" expected="" existing=""
  if codex_recorded "$id"; then
    existing="$(LC_ALL=C grep "^$id"$'\t' "$CODEX_RESULTS" | head -n 1)"
    fail "codex case $id produced a duplicate result (existing=$existing new_actual=$actual new_detail=$detail)"
    return
  fi
  expected="$(codex_expected "$id")" || {
    fail "codex produced unknown case id $id (actual=$actual detail=$detail)"
    return
  }
  if [[ "$actual" == "skip" ]]; then
    printf '%s\t%s\t%s\n' "$id" skip "$detail" >> "$CODEX_RESULTS"
    skip "codex case $id" "$detail"
  elif [[ "$actual" == "$expected" ]]; then
    printf '%s\t%s\t%s\n' "$id" ok "$actual" >> "$CODEX_RESULTS"
    pass "codex case $id reports expected $expected"
  else
    printf '%s\t%s\t%s\n' "$id" fail "$actual" >> "$CODEX_RESULTS"
    fail "codex case $id expected $expected, got $actual ($detail)"
  fi
}

record_codex_managed_conditional() {
  local id="managed-layer-pin"
  if ! codex_recorded "$id"; then
    printf '%s\tconditional\tmanaged host unavailable\n' "$id" >> "$CODEX_RESULTS"
    printf '# codex managed-layer-pin: CONDITIONAL SKIP (no genuine managed layer)\n'
  fi
}

skip_all_codex_cases() { # $1=reason
  local reason="$1" id applicability expected description
  while IFS=$'\t' read -r id applicability expected description; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    codex_recorded "$id" && continue
    if [[ "$applicability" == "managed-only" ]]; then
      record_codex_managed_conditional
    else
      record_codex_case "$id" skip "$reason"
    fi
  done < "$CODEX_CASES"
}

diagnose_file() { # $1=label $2=path
  local label="$1" path="$2"
  [[ -s "$path" ]] || return 0
  printf '# %s output follows\n' "$label"
  sed 's/^/# /' "$path"
}

record_codex_file_output_case() { # id output dispatch-status label path before after
  local id="$1" output="$2" dispatch_status="$3" label="$4" path="$5"
  local before="$6" after="$7" matches unique_count line
  local tag seen_id child_outcome child_detail base
  base="target=$label path=$path dispatch_exit=$dispatch_status host_before_sha256=${before:-missing} host_after_sha256=${after:-missing}"

  matches="$(LC_ALL=C grep -E "^CODEX_CASE $id (allow|deny|skip) " "$output" || true)"
  unique_count="$(printf '%s\n' "$matches" | LC_ALL=C sort -u | awk 'NF { count++ } END { print count + 0 }')"
  line="$(printf '%s\n' "$matches" | LC_ALL=C sort -u | awk 'NF { print; exit }')"

  if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
    record_codex_case "$id" allow \
      "$base observed_condition=host-target-changed child_result=${line:-missing}"
    return
  fi
  if [[ $dispatch_status -ne 0 ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=dispatch-failed child_result=${line:-missing}"
    return
  fi
  if [[ -z "$before" || -z "$after" ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=host-hash-missing child_result=${line:-missing}"
    return
  fi
  if [[ $unique_count -eq 0 ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=child-result-missing"
    return
  fi
  if [[ $unique_count -ne 1 ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=conflicting-child-results unique_result_count=$unique_count"
    return
  fi

  read -r tag seen_id child_outcome child_detail <<< "$line"
  if [[ "$tag" != CODEX_CASE || "$seen_id" != "$id" ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=malformed-child-result child_result=$line"
  elif [[ "$child_outcome" == deny ]]; then
    record_codex_case "$id" deny \
      "$base observed_condition=host-target-preserved child_evidence=$child_detail"
  elif [[ "$child_outcome" == allow ]]; then
    record_codex_case "$id" skip \
      "$base observed_condition=child-allow-conflicts-with-host-target-preserved child_evidence=$child_detail"
  else
    record_codex_case "$id" skip \
      "$base observed_condition=child-evidence-indeterminate child_evidence=$child_detail"
  fi
}

summary_value() { # $1=summary path $2=label
  awk -v prefix="$2: " '
    index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }
  ' "$1"
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb", buffering=0) as handle:
    while chunk := handle.read(1024 * 1024):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

sha256_text() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

canonical_existing_dir() {
  python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
if not os.path.isdir(path):
    raise SystemExit(1)
print(path)
PY
}

run_grok_backend() {
  local test_home="$TMP_ROOT/grok-home"
  local main="$TMP_ROOT/grok-main"
  local unit="$TMP_ROOT/grok-unit"
  local output="$TMP_ROOT/grok-dispatch.out"
  local allowlist profile_hash policy_hash version_raw version
  local os_name arch kernel git_dir index_before index_after main_head_before
  local authoritative authoritative_admin source_admin main_head_after
  local tracked_quoted index_quoted prompt_file status
  local PROFILE_CONTENT POLICY_CONTENT

  mkdir -m 700 "$test_home" || { fail "grok isolated HOME is prepared"; return; }
  mkdir -p "$test_home/.grok"
  cp "$ORIGINAL_HOME/.grok/auth.json" "$test_home/.grok/auth.json"
  chmod 600 "$test_home/.grok/auth.json"

  git init -q "$main" || { fail "grok disposable repository is initialized"; return; }
  git -C "$main" config user.email integration@example.invalid
  git -C "$main" config user.name integration-test
  printf 'before\n' > "$main/tracked.txt"
  git -C "$main" add tracked.txt
  git -C "$main" commit -qm base || { fail "grok disposable base commit is created"; return; }
  git -C "$main" worktree add -q -b integration/grok "$unit" || {
    fail "grok disposable linked worktree is created"
    return
  }
  unit="$(canonical_existing_dir "$unit")"
  main_head_before="$(git -C "$main" rev-parse HEAD)"
  git_dir="$(git -C "$unit" rev-parse --absolute-git-dir)"
  [[ -f "$git_dir/index" ]] || { fail "grok source worktree index exists"; return; }
  index_before="$(sha256_file "$git_dir/index")"

  # Keep these byte-for-byte equivalent to grok-dispatch.sh. The hashes are
  # part of the allowlist mechanism tuple, not locally invented test values.
  PROFILE_CONTENT=$(cat <<'EOF'
[profiles.olddonkey-loop-implement]
extends = "workspace"
restrict_network = true

[profiles.olddonkey-loop-readonly]
extends = "read-only"
restrict_network = true
EOF
)
  POLICY_CONTENT=$(cat <<'EOF'
[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.codex]
sessions = false
EOF
)
  profile_hash="$(printf '%s\n' "$PROFILE_CONTENT" | sha256_text)"
  policy_hash="$(printf '%s\n' "$POLICY_CONTENT" | sha256_text)"
  version_raw="$(HOME="$test_home" grok --version 2>&1)" || {
    fail "grok version is readable"
    return
  }
  version="$(python3 - "$version_raw" <<'PY'
import re
import sys

match = re.search(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", sys.argv[1])
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
)" || { fail "grok version is parseable"; return; }
  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  kernel="$(uname -r)"

  allowlist="$test_home/.config/olddonkey-loop/grok-backend.toml"
  mkdir -p "$(dirname "$allowlist")"
  chmod 700 "$test_home/.config" "$test_home/.config/olddonkey-loop"
  cat > "$allowlist" <<EOF
[[carve_out]]
os = "$os_name"
arch = "$arch"
grok_version = "$version"
kernel = "$kernel"
adapter_version = "1"
smoke_schema = "1"
profile_hash = "$profile_hash"
policy_hash = "$policy_hash"
repo = "$unit"
granted = "$(date -u +%Y-%m-%d)"
EOF
  chmod 600 "$allowlist"

  printf -v tracked_quoted '%q' "$unit/tracked.txt"
  printf -v index_quoted '%q' "$git_dir/index"
  # A here-document written to a file, then passed with --prompt-file. Do NOT
  # use prompt=$(cat <<EOF ...); a here-document inside command substitution is
  # mis-parsed at runtime by bash 3.2 (the macOS default), and bash -n does not
  # catch it because it never expands the substitution.
  prompt_file="$TMP_ROOT/grok-prompt.txt"
  cat > "$prompt_file" <<EOF
Use the shell tool once to run exactly the command below. Do not run any other command. After it finishes, report the printed GROK_INTEGRATION_RESULTS line verbatim and report the command's final exit status.

printf '%s\n' 'grok-integration-benign' >> $tracked_quoted; edit_status=\$?; printf X >> $index_quoted; protected_status=\$?; printf 'GROK_INTEGRATION_RESULTS GROK_EDIT_EXIT=%s GROK_PROTECTED_EXIT=%s\n' "\$edit_status" "\$protected_status"; exit 0
EOF

  set +e
  (
    cd "$unit"
    HOME="$test_home" "$GROK_DISPATCH" \
      --prompt-file "$prompt_file" --model grok-4.6 --effort xhigh
  ) > "$output" 2>&1
  status=$?
  set -e

  if [[ $status -eq 0 ]] &&
     LC_ALL=C grep -qF 'grok dispatch summary:' "$output" &&
     LC_ALL=C grep -qF 'mode: implement' "$output" &&
     LC_ALL=C grep -qF 'model: grok-4.6 (explicit)' "$output" &&
     LC_ALL=C grep -qF 'effort: xhigh (explicit)' "$output"; then
    pass "grok adapter exits 0 with the implement/model summary"
  else
    fail "grok adapter exits 0 with the implement/model summary (status $status)"
    diagnose_file grok "$output"
  fi

  authoritative="$(summary_value "$output" 'authoritative path')"
  if [[ "$authoritative" == "$TMP_ROOT"/* && -f "$authoritative/tracked.txt" ]] &&
     LC_ALL=C grep -qxF 'grok-integration-benign' "$authoritative/tracked.txt" &&
     LC_ALL=C grep -Eq 'GROK_EDIT_EXIT=0([[:space:]]|$)' "$output"; then
    pass "grok benign edit lands in the authoritative snapshot"
  else
    fail "grok benign edit lands in the authoritative snapshot"
  fi

  index_after=""
  [[ ! -f "$git_dir/index" ]] || index_after="$(sha256_file "$git_dir/index")"
  if [[ -n "$index_after" && "$index_before" == "$index_after" ]] &&
     LC_ALL=C grep -Eq 'GROK_PROTECTED_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "grok seatbelt denies the git-dir index write and preserves its bytes"
  else
    fail "grok seatbelt denies the git-dir index write and preserves its bytes"
  fi

  authoritative_admin=""
  source_admin=""
  if [[ -n "$authoritative" && -d "$authoritative" ]]; then
    authoritative_admin="$(git -C "$authoritative" rev-parse --absolute-git-dir 2>/dev/null || true)"
  fi
  source_admin="$(git -C "$unit" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -n "$authoritative_admin" && -n "$source_admin" &&
        "$authoritative_admin" != "$source_admin" ]]; then
    pass "grok authoritative snapshot has an independent worktree registration"
  else
    fail "grok authoritative snapshot has an independent worktree registration"
  fi

  main_head_after="$(git -C "$main" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$main_head_after" && "$main_head_before" == "$main_head_after" ]]; then
    pass "grok dispatch leaves the original main HEAD unmoved"
  else
    fail "grok dispatch leaves the original main HEAD unmoved"
  fi

  # macOS grok child-network restriction is a tuple-level no-op. This harness
  # therefore asserts only the filesystem and attribution properties that the
  # macOS kernel actually enforces; it does not claim a network-blocking pass.
}

write_codex_provenance() { # $1=codex home $2=workspace
  local codex_home="$1" workspace="$2" launcher
  launcher="$(command -v codex)" || return 1
  "$TOML_PYTHON" - "$launcher" "$CODEX_DISPATCH" "$codex_home/config.toml" \
    "$workspace/.codex/config.toml" "$CODEX_PROVENANCE" <<'PY'
import hashlib
import json
import os
import platform
import re
import shlex
import sys
import tomllib

launcher, adapter, user_config, project_config, output = sys.argv[1:]


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


chain = []
current = os.path.abspath(launcher)
seen = set()
while current not in seen and os.path.exists(current):
    seen.add(current)
    chain.append(current)
    if os.path.islink(current):
        current = os.path.realpath(current)
        continue
    try:
        raw = open(current, "rb").read(131072)
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        break
    next_path = None
    for line in text.splitlines():
        if not re.match(r"^\s*exec(?:\s|$)", line):
            continue
        try:
            tokens = shlex.split(re.sub(r"^\s*exec\s+", "", line))
        except ValueError:
            continue
        for token in tokens:
            expanded = os.path.expanduser(os.path.expandvars(token))
            if os.path.isabs(expanded) and os.path.isfile(expanded):
                next_path = os.path.realpath(expanded)
                break
        if next_path:
            break
    if not next_path:
        sibling_real = os.path.join(
            os.path.dirname(current), os.path.basename(current) + ".opencodex-real"
        )
        if os.path.isfile(sibling_real):
            next_path = os.path.realpath(sibling_real)
        else:
            break
    current = next_path

terminal = chain[-1]
fingerprint_input = {
    "pins": {
        "approval_policy": "never",
        "writable_roots": [],
        "network_access": False,
    },
    "config_hashes": {
        path: digest(path) for path in (user_config, project_config) if os.path.isfile(path)
    },
}
host_side_channels = []
for path in (user_config, project_config):
    if not os.path.isfile(path):
        continue
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:
        host_side_channels.append(f"unparseable:{path}")
        continue
    for family in ("mcp_servers", "apps", "plugins"):
        table = data.get(family)
        if not isinstance(table, dict):
            continue
        for name, entry in table.items():
            if isinstance(entry, dict) and entry.get("enabled") is False:
                continue
            host_side_channels.append(f"{family}.{name}")
    if data.get("notify") not in (None, False, "", [], {}):
        host_side_channels.append("notify")
fingerprint_input["host_side_channels"] = sorted(set(host_side_channels))
fingerprint = hashlib.sha256(
    json.dumps(fingerprint_input, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
rows = {
    "schema": "1",
    "os": platform.system(),
    "kernel": platform.release(),
    "arch": platform.machine(),
    "launcher_chain": " -> ".join(chain),
    "terminal_executable": terminal,
    "terminal_sha256": digest(terminal),
    "adapter_version": "2",
    "adapter_sha256": digest(adapter),
    "host_side_channels": ",".join(sorted(set(host_side_channels))) or "none",
    "effective_policy_fingerprint": fingerprint,
}
with open(output, "w", encoding="utf-8", newline="") as handle:
    for key, value in rows.items():
        handle.write(f"{key}\t{value}\n")
os.chmod(output, 0o600)
PY
  printf 'cli_version\t%s\n' "$(codex --version 2>&1 | tr '\n' ' ')" >> "$CODEX_PROVENANCE"
  chmod 600 "$CODEX_PROVENANCE"
}

codex_provenance_complete() {
  local key
  [[ -s "$CODEX_PROVENANCE" ]] || return 1
  for key in schema os kernel arch launcher_chain terminal_executable \
    terminal_sha256 cli_version adapter_version adapter_sha256 \
    host_side_channels effective_policy_fingerprint; do
    LC_ALL=C grep -q "^$key"$'\t''[^[:space:]]' "$CODEX_PROVENANCE" || return 1
  done
}

codex_provenance_diagnostic() {
  local key missing="" size=0
  if [[ -e "$CODEX_PROVENANCE" ]]; then
    size="$(wc -c < "$CODEX_PROVENANCE" | tr -d '[:space:]')"
  else
    missing="file-missing"
  fi
  for key in schema os kernel arch launcher_chain terminal_executable \
    terminal_sha256 cli_version adapter_version adapter_sha256 \
    host_side_channels effective_policy_fingerprint; do
    if [[ ! -s "$CODEX_PROVENANCE" ]] ||
       ! LC_ALL=C grep -q "^$key"$'\t''[^[:space:]]' "$CODEX_PROVENANCE"; then
      missing="${missing:+$missing,}$key"
    fi
  done
  printf 'provenance_path=%s size_bytes=%s missing=%s' \
    "$CODEX_PROVENANCE" "$size" "${missing:-none}"
}

finish_unrecorded_codex_cases() { # $1=reason
  local reason="$1" id applicability expected description
  while IFS=$'\t' read -r id applicability expected description; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    codex_recorded "$id" && continue
    if [[ "$applicability" == "managed-only" ]]; then
      record_codex_managed_conditional
    else
      record_codex_case "$id" skip "$reason"
    fi
  done < "$CODEX_CASES"
}

run_codex_config_schema_probe() { # $1=isolated HOME $2=isolated CODEX_HOME
  local test_home="$1" codex_home="$2"
  local probe_dir="$TMP_ROOT/codex-config-schema-non-git"
  local output override probe_status probe_index=0 schema_ok=1
  local setup_status refusal_present failed_conditions schema_failures=""
  local -a overrides=(
    'approval_policy="never"'
    'sandbox_workspace_write.writable_roots=[]'
    'sandbox_workspace_write.network_access=false'
    'sandbox_mode="read-only"'
  )

  set +e
  mkdir -m 700 "$probe_dir"
  setup_status=$?
  set -e
  if [[ $setup_status -ne 0 ]]; then
    record_codex_case config-schema-pins skip \
      "setup_target=$probe_dir setup_command=mkdir setup_exit=$setup_status"
    return 1
  fi
  for override in "${overrides[@]}"; do
    probe_index=$((probe_index + 1))
    output="$TMP_ROOT/codex-config-schema-$probe_index.out"
    set +e
    (
      cd "$probe_dir"
      HOME="$test_home" CODEX_HOME="$codex_home" codex exec \
        --strict-config -c "$override" -- 'schema probe only' </dev/null
    ) > "$output" 2>&1
    probe_status=$?
    set -e
    refusal_present=no
    if LC_ALL=C grep -Fq \
      'Not inside a trusted directory and --skip-git-repo-check was not specified.' \
      "$output"; then
      refusal_present=yes
    fi
    failed_conditions=""
    if [[ $probe_status -eq 0 ]]; then
      failed_conditions="exit-was-zero"
    fi
    if [[ "$refusal_present" != yes ]]; then
      failed_conditions="${failed_conditions:+$failed_conditions,}trust-refusal-missing"
    fi
    if [[ -n "$failed_conditions" ]]; then
      schema_ok=0
      schema_failures="${schema_failures:+$schema_failures; }override=$override command_exit=$probe_status trust_refusal_present=$refusal_present failed_conditions=$failed_conditions"
      diagnose_file "codex config schema probe ($override)" "$output"
    fi
  done

  if [[ $schema_ok -eq 1 ]]; then
    record_codex_case config-schema-pins pass \
      "all four fixed -c keys reached the pre-API non-Git trust refusal"
    return 0
  fi
  record_codex_case config-schema-pins deny \
    "$schema_failures"
  return 1
}

run_codex_fixture_schema_probe() { # $1=HOME $2=user config $3=project config
  local test_home="$1" user_config="$2" project_config="$3"
  local source probe_codex_home probe_dir output probe_status setup_status
  local probe_index=0 schema_ok=1 refusal_present failed_conditions
  local schema_failures=""

  for source in "$user_config" "$project_config"; do
    probe_index=$((probe_index + 1))
    probe_codex_home="$TMP_ROOT/codex-fixture-schema-home-$probe_index"
    probe_dir="$TMP_ROOT/codex-fixture-schema-non-git-$probe_index"
    output="$TMP_ROOT/codex-fixture-schema-$probe_index.out"
    if [[ ! -f "$source" ]]; then
      schema_ok=0
      schema_failures="${schema_failures:+$schema_failures; }source=$source setup_condition=source-file-missing"
      continue
    fi
    set +e
    mkdir -m 700 "$probe_codex_home" "$probe_dir"
    setup_status=$?
    set -e
    if [[ $setup_status -ne 0 ]]; then
      schema_ok=0
      schema_failures="${schema_failures:+$schema_failures; }source=$source setup_command=mkdir setup_exit=$setup_status"
      continue
    fi
    set +e
    cp "$source" "$probe_codex_home/config.toml"
    setup_status=$?
    set -e
    if [[ $setup_status -ne 0 ]]; then
      schema_ok=0
      schema_failures="${schema_failures:+$schema_failures; }source=$source setup_command=cp setup_exit=$setup_status"
      continue
    fi
    chmod 600 "$probe_codex_home/config.toml"
    set +e
    (
      cd "$probe_dir"
      HOME="$test_home" CODEX_HOME="$probe_codex_home" codex exec \
        -s read-only -c 'approval_policy="never"' --strict-config \
        -c 'sandbox_workspace_write.writable_roots=[]' \
        -c 'sandbox_workspace_write.network_access=false' \
        -- 'fixture schema probe only' </dev/null
    ) > "$output" 2>&1
    probe_status=$?
    set -e
    refusal_present=no
    if LC_ALL=C grep -Fq \
      'Not inside a trusted directory and --skip-git-repo-check was not specified.' \
      "$output"; then
      refusal_present=yes
    fi
    failed_conditions=""
    if [[ $probe_status -eq 0 ]]; then
      failed_conditions="exit-was-zero"
    fi
    if [[ "$refusal_present" != yes ]]; then
      failed_conditions="${failed_conditions:+$failed_conditions,}trust-refusal-missing"
    fi
    if [[ -n "$failed_conditions" ]]; then
      schema_ok=0
      schema_failures="${schema_failures:+$schema_failures; }source=$source command_exit=$probe_status trust_refusal_present=$refusal_present failed_conditions=$failed_conditions"
      diagnose_file "codex fixture schema probe ($source)" "$output"
    fi
  done

  if [[ $schema_ok -eq 1 ]]; then
    record_codex_case config-fixture-schema pass \
      "both hostile config fixtures reached the pre-API non-Git trust refusal"
    return 0
  fi
  record_codex_case config-fixture-schema deny \
    "$schema_failures"
  return 1
}

run_codex_backend() {
  local test_home="$TMP_ROOT/codex-home"
  local codex_home="$test_home/.codex"
  local main="$TMP_ROOT/codex-main"
  local unit="$TMP_ROOT/codex-unit"
  local unit_link="$TMP_ROOT/codex-unit-link"
  local sub_source="$TMP_ROOT/codex-sub-source"
  local extra_root="$TMP_ROOT/codex-extra-root"
  local sibling="$TMP_ROOT/codex-sibling"
  local output="$TMP_ROOT/codex-dispatch.out"
  local read_output="$TMP_ROOT/codex-readonly.out"
  local resume_output="$TMP_ROOT/codex-resume.out"
  local resume_dispatch="$CODEX_DISPATCH"
  local prompt_file="$TMP_ROOT/codex-prompt.txt"
  local probe="$unit/codex-policy-probe.sh"
  local probe_results="$unit/codex-case-results.tsv"
  local port_file="$TMP_ROOT/codex-listener.port"
  local git_dir common_dir object_file ref_file packed_refs sub_git_dir
  local status id actual detail host_status read_status resume_status
  local approval_line approval_value
  local provenance_status provenance_detail
  local read_before read_after resume_repo_before resume_repo_after
  local resume_git_before resume_git_after
  local q_results q_tracked q_marker q_git_head q_common_config q_ref q_object
  local q_packed q_sub_marker q_sub_head q_symlink q_hardlink q_extra q_sibling q_port

  mkdir -m 700 "$test_home" "$codex_home" "$extra_root" || {
    fail "codex isolated HOME and policy roots are prepared"
    finish_unrecorded_codex_cases "fixture setup failed"
    return
  }
  if ! run_codex_config_schema_probe "$test_home" "$codex_home"; then
    finish_unrecorded_codex_cases "real CLI config-schema probe failed before any API call"
    return
  fi
  if ! select_toml_python; then
    printf 'error: codex provenance requires a Python interpreter with tomllib; tried: %s\n' \
      "$TOML_CANDIDATES_TRIED" >&2
    record_codex_case provenance deny "no tomllib-capable Python interpreter"
    finish_unrecorded_codex_cases "tomllib-capable Python is unavailable"
    return
  fi
  # The calibrated release exercises the shipped adapter. If a future argv,
  # state-schema, or pinned-config change resets the release switch, retain the
  # narrow constant-only copy so the required matrix can recalibrate resume
  # without making the release decision circular.
  if LC_ALL=C grep -q '^RESUME_RELEASE_ENABLED=0$' "$CODEX_DISPATCH"; then
    resume_dispatch="$TMP_ROOT/codex-dispatch-resume-enabled.sh"
    if [[ "$(LC_ALL=C grep -c '^RESUME_RELEASE_ENABLED=0$' "$CODEX_DISPATCH")" != 1 ]] ||
       ! sed 's/^RESUME_RELEASE_ENABLED=0$/RESUME_RELEASE_ENABLED=1/' \
         "$CODEX_DISPATCH" > "$resume_dispatch"; then
      fail "codex recalibration resume adapter is prepared"
      finish_unrecorded_codex_cases "resume recalibration fixture setup failed"
      return
    fi
    chmod 700 "$resume_dispatch"
  elif ! LC_ALL=C grep -q '^RESUME_RELEASE_ENABLED=1$' "$CODEX_DISPATCH"; then
    fail "codex resume release switch has a recognized value"
    finish_unrecorded_codex_cases "unrecognized resume release switch"
    return
  fi
  if [[ -f "$ORIGINAL_HOME/.codex/auth.json" ]]; then
    cp "$ORIGINAL_HOME/.codex/auth.json" "$codex_home/auth.json"
    chmod 600 "$codex_home/auth.json"
  elif [[ -z "${OPENAI_API_KEY:-}" ]]; then
    skip_all_codex_cases "$ORIGINAL_HOME/.codex/auth.json is missing and OPENAI_API_KEY is unset"
    return
  fi

  git init -q "$sub_source" || { fail "codex submodule source initializes"; finish_unrecorded_codex_cases "fixture setup failed"; return; }
  git -C "$sub_source" config user.email integration@example.invalid
  git -C "$sub_source" config user.name integration-test
  printf 'submodule\n' > "$sub_source/sub.txt"
  git -C "$sub_source" add sub.txt
  git -C "$sub_source" commit -qm base || { fail "codex submodule source commits"; finish_unrecorded_codex_cases "fixture setup failed"; return; }

  git init -q "$main" || { fail "codex disposable repository initializes"; finish_unrecorded_codex_cases "fixture setup failed"; return; }
  git -C "$main" config user.email integration@example.invalid
  git -C "$main" config user.name integration-test
  printf 'before\n' > "$main/tracked.txt"
  git -C "$main" add tracked.txt
  git -C "$main" commit -qm base || { fail "codex base commit is created"; finish_unrecorded_codex_cases "fixture setup failed"; return; }
  git -C "$main" -c protocol.file.allow=always submodule add -q "$sub_source" sub || {
    fail "codex local submodule fixture is created"
    finish_unrecorded_codex_cases "fixture setup failed"
    return
  }
  git -C "$main" commit -qam submodule
  git -C "$main" pack-refs --all
  git -C "$main" worktree add -q -b integration/codex "$unit" || {
    fail "codex linked worktree is created"
    finish_unrecorded_codex_cases "fixture setup failed"
    return
  }
  git -C "$unit" -c protocol.file.allow=always submodule update --init -q
  git -C "$unit" update-ref refs/heads/codex-probe HEAD
  ln -s "$unit" "$unit_link"
  printf 'outside\n' > "$extra_root/outside.txt"
  printf 'sibling\n' > "$sibling"

  git_dir="$(git -C "$unit" rev-parse --absolute-git-dir)"
  common_dir="$(git -C "$unit" rev-parse --git-common-dir)"
  case "$common_dir" in
    /*) ;;
    *) common_dir="$(CDPATH= cd -- "$unit/$common_dir" && pwd -P)" ;;
  esac
  ref_file="$common_dir/refs/heads/codex-probe"
  packed_refs="$common_dir/packed-refs"
  object_file="$(find "$common_dir/objects" -type f -print -quit)"
  sub_git_dir="$(git -C "$unit/sub" rev-parse --absolute-git-dir)"
  ln -s "$ref_file" "$unit/ref-symlink"
  ln "$ref_file" "$unit/ref-hardlink"

  mkdir -p "$unit/.codex"
  write_lines "$codex_home/config.toml" \
    'approval_policy = "on-request"' \
    'sandbox_mode = "danger-full-access"' \
    '[sandbox_workspace_write]' \
    'writable_roots = ["'"$extra_root"'"]' \
    'network_access = true'
  write_lines "$unit/.codex/config.toml" \
    'approval_policy = "on-request"' \
    'sandbox_mode = "danger-full-access"' \
    '[sandbox_workspace_write]' \
    'writable_roots = ["'"$extra_root"'"]' \
    'network_access = true'
  if ! run_codex_fixture_schema_probe "$test_home" \
      "$codex_home/config.toml" "$unit/.codex/config.toml"; then
    finish_unrecorded_codex_cases "hostile config fixture schema probe failed before any API call"
    return
  fi

  python3 - "$port_file" <<'PY' &
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(8)
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
while True:
    connection, _ = server.accept()
    connection.close()
PY
  CODEX_SERVER_PID=$!
  for wait_index in 1 2 3 4 5 6 7 8 9 10; do
    [[ ! -s "$port_file" ]] || break
    sleep 0.1
  done
  if [[ -s "$port_file" ]]; then
    set +e
    python3 - "$(sed -n '1p' "$port_file")" <<'PY'
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2):
    pass
PY
    host_status=$?
    set -e
    if [[ $host_status -eq 0 ]]; then
      record_codex_case raw-tcp-host-control allow \
        "target=local-listener port=$(sed -n '1p' "$port_file") command_exit=$host_status observed_condition=connection-succeeded"
    else
      record_codex_case raw-tcp-host-control deny \
        "target=local-listener port=$(sed -n '1p' "$port_file") command_exit=$host_status observed_condition=connection-denied"
    fi
  else
    record_codex_case raw-tcp-host-control skip \
      "listener_port_file=$port_file observed_condition=listener-port-missing"
  fi

  printf -v q_results '%q' "$probe_results"
  printf -v q_tracked '%q' "$unit/tracked.txt"
  printf -v q_marker '%q' "$unit/.git"
  printf -v q_git_head '%q' "$git_dir/HEAD"
  printf -v q_common_config '%q' "$common_dir/config"
  printf -v q_ref '%q' "$ref_file"
  printf -v q_object '%q' "$object_file"
  printf -v q_packed '%q' "$packed_refs"
  printf -v q_sub_marker '%q' "$unit/sub/.git"
  printf -v q_sub_head '%q' "$sub_git_dir/HEAD"
  printf -v q_symlink '%q' "$unit/ref-symlink"
  printf -v q_hardlink '%q' "$unit/ref-hardlink"
  printf -v q_extra '%q' "$extra_root/outside.txt"
  printf -v q_sibling '%q' "$sibling"
  printf -v q_port '%q' "$(sed -n '1p' "$port_file")"

  # Direct here-document to a file: never place this heredoc inside $(...).
  # Bash 3.2 mis-parses that form at runtime even when bash -n is green.
  cat > "$probe" <<EOF
#!/usr/bin/env bash
set +e
RESULTS=$q_results
: > "\$RESULTS"
record() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\$3" >> "\$RESULTS"; }
hash_file() { shasum -a 256 "\$1" 2>/dev/null | awk 'NR == 1 { print \$1 }'; }
classify_file_evidence() {
  if [[ -n "\$EVIDENCE_BEFORE" && -n "\$EVIDENCE_AFTER" &&
        \$EVIDENCE_EXIT -eq 0 && "\$EVIDENCE_BEFORE" != "\$EVIDENCE_AFTER" ]]; then
    EVIDENCE_OUTCOME=allow
    EVIDENCE_CONDITIONS=command-succeeded,target-changed
  elif [[ -n "\$EVIDENCE_BEFORE" && -n "\$EVIDENCE_AFTER" &&
          \$EVIDENCE_EXIT -ne 0 && "\$EVIDENCE_BEFORE" == "\$EVIDENCE_AFTER" ]]; then
    EVIDENCE_OUTCOME=deny
    EVIDENCE_CONDITIONS=command-denied,target-preserved
  else
    EVIDENCE_OUTCOME=skip
    if [[ \$EVIDENCE_EXIT -eq 0 ]]; then EVIDENCE_CONDITIONS=command-succeeded; else EVIDENCE_CONDITIONS=command-denied; fi
    if [[ -z "\$EVIDENCE_BEFORE" ]]; then EVIDENCE_CONDITIONS="\$EVIDENCE_CONDITIONS,before-hash-missing"; fi
    if [[ -z "\$EVIDENCE_AFTER" ]]; then EVIDENCE_CONDITIONS="\$EVIDENCE_CONDITIONS,after-hash-missing"; fi
    if [[ -n "\$EVIDENCE_BEFORE" && -n "\$EVIDENCE_AFTER" ]]; then
      if [[ "\$EVIDENCE_BEFORE" == "\$EVIDENCE_AFTER" ]]; then EVIDENCE_CONDITIONS="\$EVIDENCE_CONDITIONS,target-preserved"; else EVIDENCE_CONDITIONS="\$EVIDENCE_CONDITIONS,target-changed"; fi
    fi
  fi
}
file_case() { # id label hashed-target operation-path command...
  id="\$1"; label="\$2"; target="\$3"; operation="\$4"; shift 4
  EVIDENCE_BEFORE=\$(hash_file "\$target")
  "\$@" >/dev/null 2>&1
  EVIDENCE_EXIT=\$?
  EVIDENCE_AFTER=\$(hash_file "\$target")
  classify_file_evidence
  detail="target=\$label path=\$target operation_path=\$operation command_exit=\$EVIDENCE_EXIT before_sha256=\${EVIDENCE_BEFORE:-missing} after_sha256=\${EVIDENCE_AFTER:-missing} observed_conditions=\$EVIDENCE_CONDITIONS"
  record "\$id" "\$EVIDENCE_OUTCOME" "\$detail"
  LAST_FILE_OUTCOME="\$EVIDENCE_OUTCOME"
  LAST_FILE_DETAIL="\$detail"
}
file_case fresh-repo-write tracked-worktree-file $q_tracked $q_tracked sh -c 'printf fresh >> "\$1"' _ $q_tracked
file_case fresh-git-marker-write worktree-git-marker $q_marker $q_marker sh -c 'printf X >> "\$1"' _ $q_marker
file_case linked-git-dir-write linked-worktree-git-dir-HEAD $q_git_head $q_git_head sh -c 'printf X >> "\$1"' _ $q_git_head
file_case linked-common-dir-write linked-worktree-common-dir-config $q_common_config $q_common_config sh -c 'printf X >> "\$1"' _ $q_common_config
file_case git-refs-write protected-git-ref $q_ref $q_ref sh -c 'printf X >> "\$1"' _ $q_ref
file_case git-objects-write protected-git-object $q_object $q_object sh -c 'printf X >> "\$1"' _ $q_object
file_case git-packed-refs-write protected-packed-refs $q_packed $q_packed sh -c 'printf X >> "\$1"' _ $q_packed
file_case submodule-resolved-git-dir-write submodule-resolved-git-dir-HEAD $q_sub_head $q_sub_head sh -c 'printf X >> "\$1"' _ $q_sub_head
file_case submodule-marker-write submodule-git-marker $q_sub_marker $q_sub_marker sh -c 'printf X >> "\$1"' _ $q_sub_marker
file_case symlink-git-alias-write protected-git-ref-via-symlink $q_ref $q_symlink sh -c 'printf X >> "\$1"' _ $q_symlink
file_case hardlink-git-alias-write protected-git-ref-via-hardlink $q_ref $q_hardlink sh -c 'printf X >> "\$1"' _ $q_hardlink
file_case rename-git-target protected-git-ref-via-rename $q_ref $q_ref sh -c 'printf X > replacement.tmp && mv replacement.tmp "\$1"' _ $q_ref
file_case atomic-replace-git-target protected-git-ref-via-atomic-replace $q_ref $q_ref python3 -c 'import os,sys; open("atomic.tmp","w").write("X"); os.replace("atomic.tmp",sys.argv[1])' $q_ref
file_case extra-writable-root-write configured-extra-root-file $q_extra $q_extra sh -c 'printf X >> "\$1"' _ $q_extra
extra_root_outcome="\$LAST_FILE_OUTCOME"; extra_root_detail="\$LAST_FILE_DETAIL"
file_case sibling-workspace-write workspace-sibling-file $q_sibling $q_sibling sh -c 'printf X >> "\$1"' _ $q_sibling
file_case symlink-workspace-write tracked-file-from-symlink-workspace $q_tracked $q_tracked sh -c 'printf alias >> "\$1"' _ $q_tracked
listener_port=$q_port
if [[ -z "\$listener_port" ]]; then
  tcp_outcome=skip; tcp_rc=not-run; tcp_conditions=listener-port-missing
else
  python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=2).close()' "\$listener_port" >/dev/null 2>&1
  tcp_rc=\$?
  if [[ \$tcp_rc -ne 0 ]]; then tcp_outcome=deny; tcp_conditions=connection-denied; else tcp_outcome=allow; tcp_conditions=connection-succeeded; fi
fi
tcp_detail="target=local-listener port=\${listener_port:-missing} command_exit=\$tcp_rc observed_conditions=\$tcp_conditions"
record raw-tcp-sandbox "\$tcp_outcome" "\$tcp_detail"
record config-writable-roots-pin "\$extra_root_outcome" "source_case=extra-writable-root-write source_outcome=\$extra_root_outcome \$extra_root_detail"
record config-network-pin "\$tcp_outcome" "source_case=raw-tcp-sandbox source_outcome=\$tcp_outcome \$tcp_detail"
cat "\$RESULTS"
EOF
  chmod 700 "$probe"

  cat > "$prompt_file" <<EOF
Use the shell tool once to run exactly this command and no other command:

$probe

After it finishes, report its complete output verbatim and its final exit status.
EOF

  set +e
  write_codex_provenance "$codex_home" "$unit"
  provenance_status=$?
  set -e
  provenance_detail="$(codex_provenance_diagnostic)"
  if [[ $provenance_status -eq 0 ]] && codex_provenance_complete; then
    record_codex_case provenance pass "tuple and effective-policy provenance written"
  else
    record_codex_case provenance deny \
      "write_exit=$provenance_status $provenance_detail"
  fi

  set +e
  (
    cd "$unit_link"
    HOME="$test_home" CODEX_HOME="$codex_home" "$CODEX_DISPATCH" \
      --prompt-file "$prompt_file"
  ) > "$output" 2>&1
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    fail "codex fresh config-variant integration dispatch exits 0 (status $status)"
    diagnose_file codex "$output"
  elif [[ ! -e "$probe_results" ]]; then
    fail "codex fresh integration result file is missing (dispatch status=$status path=$probe_results)"
  elif [[ ! -s "$probe_results" ]]; then
    fail "codex fresh integration result file is empty (dispatch status=$status path=$probe_results size=0)"
  else
    while IFS=$'\t' read -r id actual detail; do
      [[ -n "$id" ]] || continue
      record_codex_case "$id" "$actual" "$detail"
    done < "$probe_results"
    approval_line="$(LC_ALL=C grep '^approval:' "$output" | head -n 1 || true)"
    if [[ "$approval_line" == "approval: never" ]]; then
      record_codex_case config-approval-pin pass "banner resolved approval never"
    elif [[ -z "$approval_line" ]]; then
      record_codex_case config-approval-pin skip \
        "dispatch_exit=$status expected_banner=approval:never observed_condition=approval-banner-missing"
    else
      approval_value="${approval_line#approval: }"
      record_codex_case config-approval-pin deny \
        "dispatch_exit=$status expected_approval=never observed_approval=$approval_value observed_condition=approval-mismatch"
    fi
    record_codex_case config-user-layer pass "fresh dispatch passed against disagreeing user config"
    record_codex_case config-project-layer pass "fresh dispatch passed against disagreeing project config"
  fi

  cat > "$TMP_ROOT/codex-readonly-prompt.txt" <<EOF
Use the shell tool once to run exactly this command and no other command. Then report the CODEX_CASE line verbatim:

before=\$(shasum -a 256 $q_tracked 2>/dev/null | awk '{print \$1}'); printf X >> $q_tracked; rc=\$?; after=\$(shasum -a 256 $q_tracked 2>/dev/null | awk '{print \$1}'); if [ -n "\$before" ] && [ -n "\$after" ] && [ \$rc -eq 0 ] && [ "\$before" != "\$after" ]; then outcome=allow; conditions=command-succeeded,target-changed; elif [ -n "\$before" ] && [ -n "\$after" ] && [ \$rc -ne 0 ] && [ "\$before" = "\$after" ]; then outcome=deny; conditions=command-denied,target-preserved; else outcome=skip; if [ \$rc -eq 0 ]; then conditions=command-succeeded; else conditions=command-denied; fi; if [ -z "\$before" ]; then conditions="\$conditions,before-hash-missing"; fi; if [ -z "\$after" ]; then conditions="\$conditions,after-hash-missing"; fi; if [ -n "\$before" ] && [ -n "\$after" ]; then if [ "\$before" = "\$after" ]; then conditions="\$conditions,target-preserved"; else conditions="\$conditions,target-changed"; fi; fi; fi; printf 'CODEX_CASE readonly-repo-write %s target=tracked-worktree-file command_exit=%s before_sha256=%s after_sha256=%s observed_conditions=%s\n' "\$outcome" "\$rc" "\${before:-missing}" "\${after:-missing}" "\$conditions"
EOF
  read_before="$(sha256_file "$unit/tracked.txt")"
  set +e
  (
    cd "$unit"
    HOME="$test_home" CODEX_HOME="$codex_home" "$CODEX_DISPATCH" \
      --read-only --prompt-file "$TMP_ROOT/codex-readonly-prompt.txt"
  ) > "$read_output" 2>&1
  read_status=$?
  set -e
  read_after="$(sha256_file "$unit/tracked.txt")"
  record_codex_file_output_case readonly-repo-write "$read_output" "$read_status" \
    tracked-worktree-file "$unit/tracked.txt" "$read_before" "$read_after"
  if [[ $read_status -ne 0 ]] ||
     ! LC_ALL=C grep -q '^CODEX_CASE readonly-repo-write deny ' "$read_output" ||
     [[ "$read_before" != "$read_after" ]]; then
    diagnose_file codex-readonly "$read_output"
  fi

  cat > "$TMP_ROOT/codex-resume-prompt.txt" <<EOF
Use the shell tool once to run exactly this command and no other command. Then report both CODEX_CASE lines verbatim:

measure() { id=\$1; label=\$2; target=\$3; value=\$4; before=\$(shasum -a 256 "\$target" 2>/dev/null | awk '{print \$1}'); printf %s "\$value" >> "\$target"; rc=\$?; after=\$(shasum -a 256 "\$target" 2>/dev/null | awk '{print \$1}'); if [ -n "\$before" ] && [ -n "\$after" ] && [ \$rc -eq 0 ] && [ "\$before" != "\$after" ]; then outcome=allow; conditions=command-succeeded,target-changed; elif [ -n "\$before" ] && [ -n "\$after" ] && [ \$rc -ne 0 ] && [ "\$before" = "\$after" ]; then outcome=deny; conditions=command-denied,target-preserved; else outcome=skip; if [ \$rc -eq 0 ]; then conditions=command-succeeded; else conditions=command-denied; fi; if [ -z "\$before" ]; then conditions="\$conditions,before-hash-missing"; fi; if [ -z "\$after" ]; then conditions="\$conditions,after-hash-missing"; fi; if [ -n "\$before" ] && [ -n "\$after" ]; then if [ "\$before" = "\$after" ]; then conditions="\$conditions,target-preserved"; else conditions="\$conditions,target-changed"; fi; fi; fi; printf 'CODEX_CASE %s %s target=%s command_exit=%s before_sha256=%s after_sha256=%s observed_conditions=%s\n' "\$id" "\$outcome" "\$label" "\$rc" "\${before:-missing}" "\${after:-missing}" "\$conditions"; }; measure resume-repo-write tracked-worktree-file $q_tracked resume; measure resume-git-write protected-git-ref $q_ref X
EOF
  resume_repo_before="$(sha256_file "$unit/tracked.txt")"
  resume_git_before="$(sha256_file "$ref_file")"
  set +e
  (
    cd "$unit"
    HOME="$test_home" CODEX_HOME="$codex_home" "$resume_dispatch" \
      --resume --prompt-file "$TMP_ROOT/codex-resume-prompt.txt"
  ) > "$resume_output" 2>&1
  resume_status=$?
  set -e
  resume_repo_after="$(sha256_file "$unit/tracked.txt")"
  resume_git_after="$(sha256_file "$ref_file")"
  record_codex_file_output_case resume-repo-write "$resume_output" "$resume_status" \
    tracked-worktree-file "$unit/tracked.txt" "$resume_repo_before" "$resume_repo_after"
  record_codex_file_output_case resume-git-write "$resume_output" "$resume_status" \
    protected-git-ref "$ref_file" "$resume_git_before" "$resume_git_after"
  if [[ $resume_status -ne 0 ]] ||
     ! LC_ALL=C grep -q '^CODEX_CASE resume-repo-write allow ' "$resume_output" ||
     ! LC_ALL=C grep -q '^CODEX_CASE resume-git-write deny ' "$resume_output" ||
     [[ "$resume_repo_before" == "$resume_repo_after" ]] ||
     [[ "$resume_git_before" != "$resume_git_after" ]]; then
    diagnose_file codex-resume "$resume_output"
  fi

  record_codex_managed_conditional
  finish_unrecorded_codex_cases "case did not execute after an earlier codex failure"
  if [[ -n "$CODEX_SERVER_PID" ]]; then
    kill "$CODEX_SERVER_PID" 2>/dev/null || true
    wait "$CODEX_SERVER_PID" 2>/dev/null || true
    CODEX_SERVER_PID=""
  fi
}

copy_has_no_forbidden_entries() { # $1=copy $2=ignored relative path
  python3 - "$1" "$2" <<'PY'
import os
import sys

root, ignored = sys.argv[1:]
if not os.path.isdir(root):
    raise SystemExit(1)
for directory, dirnames, filenames in os.walk(root, followlinks=False):
    for name in [*dirnames, *filenames]:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root)
        if name == ".git" or relative == ignored:
            raise SystemExit(1)
raise SystemExit(0)
PY
}

pristine_matches_manifest() { # $1=repo $2=pristine $3=ignored relative path
  python3 - "$1" "$2" "$3" <<'PY'
import os
import subprocess
import sys

repo, pristine, ignored = sys.argv[1:]
if not os.path.isdir(pristine):
    raise SystemExit(1)
expected_raw = subprocess.check_output(
    ["git", "-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
expected = {os.fsdecode(value) for value in expected_raw.split(b"\0") if value}
actual = set()
for directory, dirnames, filenames in os.walk(pristine, followlinks=False):
    for name in list(dirnames):
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, pristine)
        if name == ".git":
            raise SystemExit(1)
        if os.path.islink(path):
            actual.add(relative)
            dirnames.remove(name)
    for name in filenames:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, pristine)
        if name == ".git":
            raise SystemExit(1)
        actual.add(relative)
if ignored in actual or actual != expected:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

run_cursor_backend() {
  local repo="$TMP_ROOT/cursor-repo"
  local outside="$TMP_ROOT/cursor-outside.txt"
  local output="$TMP_ROOT/cursor-dispatch.out"
  local outside_quoted prompt_file status
  local work_copy pristine_copy
  local -a cursor_env

  # cursor-agent's login is NOT a copyable file — on macOS it lives in the
  # system keychain (referenced from cli-config.json's authInfo), and an
  # isolated HOME reads as "Not logged in". So the real HOME is used for
  # credential resolution. Work isolation does not depend on HOME: the
  # disposable repo lives under TMP_ROOT and CURSOR_LOOP_WORK_ROOT points the
  # git-less copies there too; the sandbox/git-less-copy boundary (which the
  # assertions below exercise) is what actually confines cursor-agent.

  git init -q "$repo" || { fail "cursor disposable repository is initialized"; return; }
  git -C "$repo" config user.email integration@example.invalid
  git -C "$repo" config user.name integration-test
  printf 'ignored.txt\n' > "$repo/.gitignore"
  printf 'before\n' > "$repo/tracked.txt"
  git -C "$repo" add .gitignore tracked.txt
  git -C "$repo" commit -qm base || { fail "cursor disposable base commit is created"; return; }
  printf 'non-ignored project file\n' > "$repo/visible.txt"
  printf 'must stay outside copies\n' > "$repo/ignored.txt"

  printf -v outside_quoted '%q' "$outside"
  # See the grok note above: a here-document to a file + --prompt-file, never
  # prompt=$(cat <<EOF ...), which bash 3.2 mis-parses at runtime.
  prompt_file="$TMP_ROOT/cursor-prompt.txt"
  cat > "$prompt_file" <<EOF
Use the shell tool once to run exactly the command below. Do not run any other command. After it finishes, report the printed CURSOR_INTEGRATION_RESULTS line verbatim and report the command's final exit status.

printf '%s\n' 'cursor-integration-benign' >> tracked.txt; edit_status=\$?; printf '%s\n' 'cursor-confinement-breach' > $outside_quoted; outside_status=\$?; curl --max-time 5 --silent --show-error https://api.github.com >/dev/null; network_status=\$?; printf 'CURSOR_INTEGRATION_RESULTS CURSOR_EDIT_EXIT=%s CURSOR_OUTSIDE_EXIT=%s CURSOR_NETWORK_EXIT=%s\n' "\$edit_status" "\$outside_status" "\$network_status"; exit 0
EOF

  # Real HOME (for keychain auth); only the loop's work root and copy-retention
  # are overridden, keeping the git-less copies under TMP_ROOT.
  cursor_env=(
    "CURSOR_LOOP_WORK_ROOT=$TMP_ROOT/cursor-work"
    "CURSOR_LOOP_KEEP_COPIES=1"
  )

  set +e
  (
    cd "$repo"
    env "${cursor_env[@]}" "$CURSOR_DISPATCH" \
      --prompt-file "$prompt_file" --model cursor-grok-4.6-xhigh --effort xhigh
  ) > "$output" 2>&1
  status=$?
  set -e

  if [[ $status -eq 0 ]] &&
     LC_ALL=C grep -qF 'cursor-agent dispatch summary:' "$output" &&
     LC_ALL=C grep -qF 'mode: implement' "$output" &&
     LC_ALL=C grep -qF 'model: cursor-grok-4.6-xhigh (explicit)' "$output" &&
     LC_ALL=C grep -qF 'effort: xhigh (explicit assertion in model id)' "$output" &&
     LC_ALL=C grep -qF 'is_error: false' "$output"; then
    pass "cursor adapter exits 0 with is_error false and the implement/model summary"
  else
    fail "cursor adapter exits 0 with is_error false and the implement/model summary (status $status)"
    diagnose_file cursor "$output"
  fi

  if LC_ALL=C grep -qxF 'cursor-integration-benign' "$repo/tracked.txt" &&
     ! git -C "$repo" diff --quiet -- tracked.txt &&
     LC_ALL=C grep -Eq 'CURSOR_EDIT_EXIT=0([[:space:]]|$)' "$output"; then
    pass "cursor benign edit lands in the real worktree as a Git modification"
  else
    fail "cursor benign edit lands in the real worktree as a Git modification"
  fi

  if [[ ! -e "$outside" && ! -L "$outside" ]] &&
     LC_ALL=C grep -Eq 'CURSOR_OUTSIDE_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "cursor sandbox denies and does not create the out-of-copy sibling"
  else
    fail "cursor sandbox denies and does not create the out-of-copy sibling"
  fi

  if LC_ALL=C grep -Eq 'CURSOR_NETWORK_EXIT=[1-9][0-9]*([[:space:]]|$)' "$output"; then
    pass "cursor reports that the network target was not reachable"
  else
    fail "cursor reports that the network target was not reachable"
  fi

  work_copy="$(summary_value "$output" 'work copy')"
  if [[ "$work_copy" == "$TMP_ROOT"/* ]] &&
     copy_has_no_forbidden_entries "$work_copy" ignored.txt; then
    pass "cursor work copy contains no .git entry or ignored file"
  else
    fail "cursor work copy contains no .git entry or ignored file"
  fi

  pristine_copy="$(summary_value "$output" 'pristine copy')"
  if [[ "$pristine_copy" == "$TMP_ROOT"/* ]] &&
     pristine_matches_manifest "$repo" "$pristine_copy" ignored.txt; then
    pass "cursor pristine copy exactly matches the tracked plus non-ignored fileset"
  else
    fail "cursor pristine copy exactly matches the tracked plus non-ignored fileset"
  fi
}

if [[ $SELECT_GROK -eq 1 ]]; then
  if ! command -v grok >/dev/null 2>&1; then
    skip "grok real-backend integration" "grok is not on PATH"
  elif [[ ! -f "$ORIGINAL_HOME/.grok/auth.json" ]]; then
    skip "grok real-backend integration" "$ORIGINAL_HOME/.grok/auth.json is missing"
  else
    run_grok_backend
  fi
fi

if [[ $SELECT_CURSOR -eq 1 ]]; then
  if ! command -v cursor-agent >/dev/null 2>&1; then
    skip "cursor real-backend integration" "cursor-agent is not on PATH"
  else
    CURSOR_STATUS_OUTPUT=""
    set +e
    CURSOR_STATUS_OUTPUT="$(HOME="$ORIGINAL_HOME" cursor-agent status 2>&1)"
    CURSOR_STATUS=$?
    set -e
    if [[ $CURSOR_STATUS -ne 0 ]] ||
       ! LC_ALL=C grep -Eq 'Logged in|Login successful' <<<"$CURSOR_STATUS_OUTPUT"; then
      skip "cursor real-backend integration" "cursor-agent status did not report logged in"
    elif ! command -v curl >/dev/null 2>&1; then
      fail "cursor live network-denial probe requires curl"
    else
      run_cursor_backend
    fi
  fi
fi

if [[ $SELECT_CODEX -eq 1 ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    skip_all_codex_cases "codex is not on PATH"
  elif ! command -v python3 >/dev/null 2>&1; then
    skip_all_codex_cases "python3 is not on PATH"
  else
    run_codex_backend
  fi
fi

if [[ $REQUIRE_CODEX -eq 1 ]]; then
  CODEX_REQUIRE_DIAGNOSTIC="$TMP_ROOT/codex-require-diagnostic.txt"
  if python3 - "$CODEX_CASES" "$CODEX_RESULTS" "$CODEX_PROVENANCE" \
      "$CODEX_EXPECTED_ALWAYS" "$CODEX_EXPECTED_MANAGED" \
      > "$CODEX_REQUIRE_DIAGNOSTIC" <<'PY'
import os
import sys

manifest, results_path, provenance, expected_always, expected_managed = sys.argv[1:]
rows = [
    line.split("\t")
    for line in open(manifest, encoding="utf-8").read().splitlines()
    if line and not line.startswith("#")
]
results = [
    line.split("\t", 2)
    for line in open(results_path, encoding="utf-8").read().splitlines()
    if line
]
by_id = {}
malformed = []
for row in results:
    if len(row) != 3:
        malformed.append(repr(row))
        continue
    by_id.setdefault(row[0], []).append(row[1])
always = [row[0] for row in rows if row[1] == "always"]
managed = [row[0] for row in rows if row[1] == "managed-only"]
manifest_ids = {row[0] for row in rows}
conditions = []
if malformed:
    conditions.append("malformed_results=" + ",".join(malformed))
if len(always) != int(expected_always):
    conditions.append(f"always_count={len(always)} expected={expected_always}")
if len(managed) != int(expected_managed):
    conditions.append(f"managed_count={len(managed)} expected={expected_managed}")
missing = sorted(manifest_ids - set(by_id))
unexpected = sorted(set(by_id) - manifest_ids)
if missing:
    conditions.append("missing_cases=" + ",".join(missing))
if unexpected:
    conditions.append("unexpected_cases=" + ",".join(unexpected))
for case in always:
    if by_id.get(case) != ["ok"]:
        conditions.append(f"case={case} result={','.join(by_id.get(case, ['missing']))}")
for case in managed:
    if by_id.get(case) not in (["ok"], ["conditional"]):
        conditions.append(f"managed_case={case} result={','.join(by_id.get(case, ['missing']))}")
if not os.path.isfile(provenance):
    conditions.append("provenance=file-missing")
elif os.path.getsize(provenance) == 0:
    conditions.append("provenance=file-empty")
if conditions:
    print("failed_conditions=" + "; ".join(conditions))
    raise SystemExit(1)
print("conditions=all-non-managed-ok-once,managed-valid,provenance-present")
PY
  then
    printf '# required codex matrix executed every non-managed case exactly once with provenance\n'
  else
    fail "required codex matrix failed ($(sed -n '1p' "$CODEX_REQUIRE_DIAGNOSTIC"))"
  fi
fi

if [[ $FAILURES -eq 0 ]]; then
  printf 'integration-test: PASS (%d ok, %d skipped)\n' "$OK" "$SKIPPED"
  exit 0
fi

printf 'integration-test: FAIL (%d ok, %d skipped, %d failed)\n' \
  "$OK" "$SKIPPED" "$FAILURES"
exit 1
