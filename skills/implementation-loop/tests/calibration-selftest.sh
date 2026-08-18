#!/usr/bin/env bash
# Hermetic regression checks for loop-calibration (D9 store). HOME is a
# scratch directory so the real ~/.config tree is never touched.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CAL="$SCRIPT_DIR/../scripts/loop-calibration"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/calibration-selftest.XXXXXX")" || exit 1
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.config/olddonkey-loop" || exit 1
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop" || exit 1
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$CASE_STDERR" >&2
  fi
}

workspace() { # $1=name
  local path="$TMP_ROOT/ws-$1"
  mkdir -p "$path"
  printf '%s\n' "$path"
}

run_cmd() { # $1=name, remaining=command
  local name="$1"
  shift
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if "$@" >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

expect_output() { # $1=stream stdout|stderr $2=fixed string $3=description
  local stream="$1" needle="$2" description="$3" path=""
  if [[ "$stream" == stdout ]]; then path="$CASE_STDOUT"; else path="$CASE_STDERR"; fi
  if grep -Fq -- "$needle" "$path"; then
    pass "$description"
  else
    fail "$description (missing: $needle)"
  fi
}

workspace_key() { # $1=workspace
  python3 - "$1" <<'PY'
import hashlib, os, sys
print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode("utf-8")).hexdigest())
PY
}

canonical() { # $1=path
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

store_file() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "calibration", key + ".tsv"))
PY
}

ensure_cal_dir() {
  local dir="$HOME/.config/olddonkey-loop/calibration"
  mkdir -p "$dir"
  chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop" "$dir"
}

write_store() { # $1=workspace $2=body-after-headers (may be empty) [$3=schema-line]
  python3 - "$HOME" "$1" "${2:-}" "${3:-#schema=1}" <<'PY'
import hashlib, os, sys
home, workspace, body, schema = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
canonical = os.path.realpath(workspace)
key = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
directory = os.path.join(home, ".config", "olddonkey-loop", "calibration")
os.makedirs(directory, mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
path = os.path.join(directory, key + ".tsv")
lines = [schema, "#workspace=" + canonical, "#workspace_key=" + key]
if body:
    lines.extend(body.split("\n"))
text = "\n".join(lines) + "\n"
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags, 0o600)
try:
    os.fchmod(fd, 0o600)
    os.write(fd, text.encode("utf-8"))
finally:
    os.close(fd)
PY
}

write_raw_store() { # $1=path $2=contents
  python3 - "$1" "$2" <<'PY'
import os, sys
path, contents = sys.argv[1], sys.argv[2]
directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags, 0o600)
try:
    os.fchmod(fd, 0o600)
    os.write(fd, contents.encode("utf-8"))
finally:
    os.close(fd)
PY
}

# ---------------------------------------------------------------------------
# Help documents exit codes
# ---------------------------------------------------------------------------
run_cmd help "$CAL" --help
expect_status 0 "help: --help exits 0"
expect_output stdout "Exit codes:" "help: documents exit codes"
expect_output stdout "2  usage" "help: documents usage exit 2"
expect_output stdout "5  D4a" "help: documents D4a exit 5"
expect_output stdout "6  store rejected" "help: documents store-rejected exit 6"

# ---------------------------------------------------------------------------
# 1. Absent store → defaults, store absent, exit 0
# ---------------------------------------------------------------------------
WS_ABSENT="$(workspace absent)"
run_cmd absent-show "$CAL" show --workspace "$WS_ABSENT" --json
expect_status 0 "absent: show exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
defaults = {
    "backend": "codex",
    "stop": "worktree",
    "cadence": "confirm",
    "dispatch-mode": "implement",
    "gate": "baseline",
    "on-red": "stop",
    "depth": "standard",
    "fix-lane": "codex",
}
if doc.get("schema") != 1:
    raise SystemExit("schema")
if doc.get("store") != "absent":
    raise SystemExit("store %r" % doc.get("store"))
if "reason" in doc:
    raise SystemExit("unexpected reason")
dials = doc.get("dials") or {}
if set(dials) != set(defaults):
    raise SystemExit("keys %r" % sorted(dials))
for key, value in defaults.items():
    row = dials[key]
    if row.get("value") != value:
        raise SystemExit("%s value %r" % (key, row.get("value")))
    if row.get("source") != "default":
        raise SystemExit("%s source %r" % (key, row.get("source")))
    if row.get("scope") != "policy":
        raise SystemExit("%s scope %r" % (key, row.get("scope")))
PY
then
  pass "absent: every dial is the safe default with source default"
else
  fail "absent: every dial is the safe default with source default"
fi

# ---------------------------------------------------------------------------
# 2. set/show round trip — policy (both set_by) and permission (console)
# ---------------------------------------------------------------------------
WS_RT="$(workspace roundtrip)"
run_cmd set-policy-import "$CAL" set --workspace "$WS_RT" \
  --key backend --value grok --set-by import-confirmed --provenance "from-memory"
expect_status 0 "roundtrip: policy set_by=import-confirmed is accepted"
run_cmd show-policy-import "$CAL" show --workspace "$WS_RT" --json
expect_status 0 "roundtrip: show after policy import"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
row = doc["dials"]["backend"]
if doc.get("store") != "present":
    raise SystemExit("store")
if row["value"] != "grok" or row["source"] != "store":
    raise SystemExit("value/source")
if row["set_by"] != "import-confirmed" or row["scope"] != "policy":
    raise SystemExit("set_by/scope")
if row["provenance"] != "from-memory":
    raise SystemExit("provenance")
if not row.get("set_at"):
    raise SystemExit("set_at")
PY
then
  pass "roundtrip: policy import-confirmed is stored"
else
  fail "roundtrip: policy import-confirmed is stored"
fi

run_cmd set-policy-console "$CAL" set --workspace "$WS_RT" \
  --key gate --value strict --set-by console --provenance "console-policy"
expect_status 0 "roundtrip: policy set_by=console is accepted"
run_cmd show-policy-console "$CAL" show --workspace "$WS_RT" --json
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
row = doc["dials"]["gate"]
if row["value"] != "strict" or row["set_by"] != "console" or row["source"] != "store":
    raise SystemExit(row)
PY
then
  pass "roundtrip: policy console write is stored"
else
  fail "roundtrip: policy console write is stored"
fi

run_cmd set-perm-console "$CAL" set --workspace "$WS_RT" \
  --key stop --value merge --set-by console --provenance "granted"
expect_status 0 "roundtrip: permission set_by=console is accepted"
run_cmd show-perm-console "$CAL" show --workspace "$WS_RT" --json
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
row = doc["dials"]["stop"]
if row["value"] != "merge" or row["scope"] != "permission":
    raise SystemExit(row)
if row["set_by"] != "console" or row["source"] != "store":
    raise SystemExit(row)
PY
then
  pass "roundtrip: permission console write is stored as permission"
else
  fail "roundtrip: permission console write is stored as permission"
fi

# ---------------------------------------------------------------------------
# 3. import-confirmed on a permission key is REFUSED; store unchanged
# ---------------------------------------------------------------------------
STORE_RT="$(store_file "$WS_RT")"
cp "$STORE_RT" "$TMP_ROOT/rt-before.tsv"
run_cmd set-perm-import "$CAL" set --workspace "$WS_RT" \
  --key cadence --value continuous --set-by import-confirmed
if [[ $CASE_STATUS -ne 0 ]]; then
  pass "authority: import-confirmed on a permission key is refused (nonzero)"
else
  fail "authority: import-confirmed on a permission key is refused (nonzero)"
fi
expect_output stderr "authenticated console" \
  "authority: refusal names the console requirement"
if cmp -s "$STORE_RT" "$TMP_ROOT/rt-before.tsv"; then
  pass "authority: refused permission import leaves the store unchanged"
else
  fail "authority: refused permission import leaves the store unchanged"
fi

# ---------------------------------------------------------------------------
# 4. Rejection matrix — one case each, store=rejected, never partial apply
# ---------------------------------------------------------------------------
reject_case() { # $1=name $2=workspace $3=reason-needle $4=writer
  local name="$1" ws="$2" needle="$3"
  shift 3
  "$@"
  run_cmd "rej-$name" "$CAL" show --workspace "$ws" --json
  expect_status 0 "reject $name: show exits 0"
  if python3 - "$CASE_STDOUT" "$needle" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
needle = sys.argv[2]
if doc.get("store") != "rejected":
    raise SystemExit("store %r" % doc.get("store"))
reason = doc.get("reason") or ""
if needle not in reason:
    raise SystemExit("reason %r missing %r" % (reason, needle))
defaults = {
    "backend": "codex",
    "stop": "worktree",
    "cadence": "confirm",
    "dispatch-mode": "implement",
    "gate": "baseline",
    "on-red": "stop",
    "depth": "standard",
    "fix-lane": "codex",
}
for key, value in defaults.items():
    row = doc["dials"][key]
    if row["value"] != value or row["source"] != "default":
        raise SystemExit("%s applied broken value %r" % (key, row))
PY
  then
    pass "reject $name: store=rejected with reason and defaults only"
  else
    fail "reject $name: store=rejected with reason and defaults only"
  fi
}

WS_SCHEMA="$(workspace schema)"
reject_case schema "$WS_SCHEMA" "schema" \
  write_store "$WS_SCHEMA" "" "#schema=2"

WS_A="$(workspace cross-a)"
WS_B="$(workspace cross-b)"
run_cmd set-a "$CAL" set --workspace "$WS_A" --key backend --value grok --set-by console
expect_status 0 "reject workspace-mismatch: seed workspace A"
STORE_A="$(store_file "$WS_A")"
STORE_B="$(store_file "$WS_B")"
ensure_cal_dir
cp "$STORE_A" "$STORE_B"
chmod 600 "$STORE_B"
reject_case workspace-mismatch "$WS_B" "workspace header" \
  true

WS_KEYMIS="$(workspace keymis)"
CAN_KEYMIS="$(canonical "$WS_KEYMIS")"
KEY_KEYMIS="$(workspace_key "$WS_KEYMIS")"
write_raw_store "$(store_file "$WS_KEYMIS")" \
  "#schema=1
#workspace=${CAN_KEYMIS}
#workspace_key=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
"
reject_case key-mismatch "$WS_KEYMIS" "workspace_key" true

WS_DUP="$(workspace dup)"
write_store "$WS_DUP" \
  $'backend\tcodex\tpolicy\tconsole\t2026-08-18T00:00:00Z\tx\nbackend\tgrok\tpolicy\tconsole\t2026-08-18T00:00:01Z\ty'
reject_case duplicate "$WS_DUP" "duplicate" true

WS_UNKKEY="$(workspace unkkey)"
write_store "$WS_UNKKEY" \
  $'not-a-dial\tcodex\tpolicy\tconsole\t2026-08-18T00:00:00Z\tx'
reject_case unknown-key "$WS_UNKKEY" "unknown key" true

WS_UNKVAL="$(workspace unkval)"
write_store "$WS_UNKVAL" \
  $'backend\tnope\tpolicy\tconsole\t2026-08-18T00:00:00Z\tx'
reject_case unknown-value "$WS_UNKVAL" "unknown value" true

WS_UNKSCOPE="$(workspace unkscope)"
write_store "$WS_UNKSCOPE" \
  $'backend\tcodex\tadmin\tconsole\t2026-08-18T00:00:00Z\tx'
reject_case unknown-scope "$WS_UNKSCOPE" "unknown scope" true

WS_UNKSETBY="$(workspace unksetby)"
write_store "$WS_UNKSETBY" \
  $'backend\tcodex\tpolicy\tagent\t2026-08-18T00:00:00Z\tx'
reject_case unknown-set_by "$WS_UNKSETBY" "unknown set_by" true

WS_COLS="$(workspace cols)"
write_store "$WS_COLS" \
  $'backend\tcodex\tpolicy\tconsole\t2026-08-18T00:00:00Z'
reject_case columns "$WS_COLS" "wrong column count" true

WS_TAB="$(workspace tab)"
write_store "$WS_TAB" \
  $'backend\tcodex\tpolicy\tconsole\t2026-08-18T00:00:00Z\thello\tworld'
reject_case tab-in-value "$WS_TAB" "tab" true

WS_SCOPE="$(workspace scopedrift)"
write_store "$WS_SCOPE" \
  $'stop\tmerge\tpolicy\tconsole\t2026-08-18T00:00:00Z\tx'
reject_case scope-mismatch "$WS_SCOPE" "scope/key mismatch" true

# ---------------------------------------------------------------------------
# 5. Fail-closed authority: rejected store cannot resurrect a grant
# ---------------------------------------------------------------------------
WS_CLOSED="$(workspace failclosed)"
write_store "$WS_CLOSED" \
  $'stop\tmerge\tpermission\tconsole\t2026-08-18T00:00:00Z\tgrant\ncadence\tcontinuous\tpermission\tconsole\t2026-08-18T00:00:00Z\tgrant\nfix-lane\tclaude-trivial-ok\tpermission\tconsole\t2026-08-18T00:00:00Z\tgrant' \
  "#schema=0"
run_cmd closed-show "$CAL" show --workspace "$WS_CLOSED" --json
expect_status 0 "fail-closed: show exits 0 on rejected store"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
if doc.get("store") != "rejected":
    raise SystemExit("store")
for key, value in (("stop", "worktree"), ("cadence", "confirm"), ("fix-lane", "codex")):
    row = doc["dials"][key]
    if row["value"] != value or row["source"] != "default":
        raise SystemExit("resurrected %s %r" % (key, row))
    if row["scope"] != "policy":
        raise SystemExit("scope %s" % key)
PY
then
  pass "fail-closed: permission dials read as safe defaults, not the broken file"
else
  fail "fail-closed: permission dials read as safe defaults, not the broken file"
fi

# ---------------------------------------------------------------------------
# 6. set against a rejected store is refused; file untouched
# ---------------------------------------------------------------------------
STORE_CLOSED="$(store_file "$WS_CLOSED")"
cp "$STORE_CLOSED" "$TMP_ROOT/closed-before.tsv"
run_cmd closed-set "$CAL" set --workspace "$WS_CLOSED" \
  --key backend --value grok --set-by console
expect_status 6 "rejected-set: exits 6"
if cmp -s "$STORE_CLOSED" "$TMP_ROOT/closed-before.tsv"; then
  pass "rejected-set: store file is byte-identical"
else
  fail "rejected-set: store file is byte-identical"
fi

# ---------------------------------------------------------------------------
# 7. unset removes the row; show returns to default
# ---------------------------------------------------------------------------
run_cmd unset-stop "$CAL" unset --workspace "$WS_RT" --key stop --set-by console
expect_status 0 "unset: exits 0"
run_cmd show-unset "$CAL" show --workspace "$WS_RT" --json
expect_status 0 "unset: show exits 0"
if python3 - "$CASE_STDOUT" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
row = doc["dials"]["stop"]
if row["value"] != "worktree" or row["source"] != "default":
    raise SystemExit(row)
if "stop\t" in open(sys.argv[1], encoding="utf-8").read():
    pass
PY
then
  pass "unset: stop returns to the safe default"
else
  fail "unset: stop returns to the safe default"
fi
if grep -Fq $'stop\tmerge' "$STORE_RT"; then
  fail "unset: stop row is gone from the file"
else
  pass "unset: stop row is gone from the file"
fi

# ---------------------------------------------------------------------------
# 8. D4a refusals leave the file unchanged
# ---------------------------------------------------------------------------
WS_D4A="$(workspace d4a)"
run_cmd d4a-seed "$CAL" set --workspace "$WS_D4A" \
  --key backend --value grok --set-by console
expect_status 0 "d4a: seed a valid store"
STORE_D4A="$(store_file "$WS_D4A")"
CAL_DIR="$(dirname "$STORE_D4A")"

# symlink
mv "$STORE_D4A" "$TMP_ROOT/d4a-real.tsv"
ln -s "$TMP_ROOT/d4a-real.tsv" "$STORE_D4A"
run_cmd d4a-sym-show "$CAL" show --workspace "$WS_D4A" --json
expect_status 5 "d4a: symlinked store is refused (show)"
run_cmd d4a-sym-set "$CAL" set --workspace "$WS_D4A" \
  --key gate --value strict --set-by console
expect_status 5 "d4a: symlinked store is refused (set)"
if [[ -L "$STORE_D4A" ]]; then
  pass "d4a: symlink is unchanged after refusal"
else
  fail "d4a: symlink is unchanged after refusal"
fi
rm -f "$STORE_D4A"
mv "$TMP_ROOT/d4a-real.tsv" "$STORE_D4A"
chmod 600 "$STORE_D4A"

# hard link
cp "$STORE_D4A" "$TMP_ROOT/d4a-hard-before.tsv"
ln "$STORE_D4A" "$TMP_ROOT/d4a-hard-other.tsv"
run_cmd d4a-hard-show "$CAL" show --workspace "$WS_D4A" --json
expect_status 5 "d4a: hard-linked store is refused (show)"
run_cmd d4a-hard-set "$CAL" set --workspace "$WS_D4A" \
  --key gate --value strict --set-by console
expect_status 5 "d4a: hard-linked store is refused (set)"
if cmp -s "$STORE_D4A" "$TMP_ROOT/d4a-hard-before.tsv"; then
  pass "d4a: hard-linked store is unchanged after refusal"
else
  fail "d4a: hard-linked store is unchanged after refusal"
fi
rm -f "$TMP_ROOT/d4a-hard-other.tsv"

# 0644
chmod 644 "$STORE_D4A"
cp "$STORE_D4A" "$TMP_ROOT/d4a-mode-before.tsv"
run_cmd d4a-mode-show "$CAL" show --workspace "$WS_D4A" --json
expect_status 5 "d4a: 0644 store is refused (show)"
run_cmd d4a-mode-set "$CAL" set --workspace "$WS_D4A" \
  --key gate --value strict --set-by console
expect_status 5 "d4a: 0644 store is refused (set)"
if cmp -s "$STORE_D4A" "$TMP_ROOT/d4a-mode-before.tsv"; then
  pass "d4a: 0644 store is unchanged after refusal"
else
  fail "d4a: 0644 store is unchanged after refusal"
fi
mode="$(python3 -c 'import os,stat,sys; print("%04o" % stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))' "$STORE_D4A")"
if [[ "$mode" == "0644" ]]; then
  pass "d4a: 0644 mode is unchanged after refusal"
else
  fail "d4a: 0644 mode is unchanged after refusal (got $mode)"
fi
chmod 600 "$STORE_D4A"

# ---------------------------------------------------------------------------
# 9. Atomic replace: no temp remains; mode 0600
# ---------------------------------------------------------------------------
run_cmd atomic-set "$CAL" set --workspace "$WS_D4A" \
  --key depth --value deep --set-by console
expect_status 0 "atomic: set succeeds"
temps="$(find "$CAL_DIR" -name '.tmp-*' | wc -l | tr -d ' ')"
if [[ "$temps" == "0" ]]; then
  pass "atomic: no temp file remains after a successful set"
else
  fail "atomic: no temp file remains after a successful set"
fi
mode="$(python3 -c 'import os,stat,sys; print("%04o" % stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))' "$STORE_D4A")"
if [[ "$mode" == "0600" ]]; then
  pass "atomic: store keeps mode 0600"
else
  fail "atomic: store keeps mode 0600 (got $mode)"
fi

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
