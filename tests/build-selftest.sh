#!/usr/bin/env bash
# Regression checks for the deterministic Cursor package builder.

set -uo pipefail

export LC_ALL=C
umask 022

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILDER="$ROOT/build.sh"
INVENTORY="$ROOT/tests/build-inventory.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/build-selftest.XXXXXX")" || exit 1
CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""
FIXTURE=""

cleanup() { # $1=status to preserve
  local status="$1"
  trap - EXIT HUP INT TERM
  rm -rf "$TMP_ROOT"
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

abort() {
  printf 'selftest: FAIL (setup error: %s)\n' "$1" >&2
  exit 1
}

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    sed 's/^/  stdout | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    sed 's/^/  stderr | /' "$CASE_STDERR" >&2
  fi
}

run_builder() { # $1=case name $2=repository root, remaining=args
  local name="$1" repository="$2"
  shift 2
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if (cd "$repository" && bash build.sh "$@") \
      > "$CASE_STDOUT" 2> "$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_zero() { # $1=description
  if [[ "$CASE_STATUS" -eq 0 ]]; then
    pass "$1"
  else
    fail "$1 (expected status 0, got $CASE_STATUS)"
  fi
}

expect_nonzero() { # $1=description
  if [[ "$CASE_STATUS" -ne 0 ]]; then
    pass "$1"
  else
    fail "$1 (expected nonzero status)"
  fi
}

expect_stderr() { # $1=fixed text $2=description
  if grep -Fq -- "$1" "$CASE_STDERR"; then
    pass "$2"
  else
    fail "$2 (missing stderr text: $1)"
  fi
}

make_fixture() { # $1=case name; sets FIXTURE
  local name="$1"
  FIXTURE="$TMP_ROOT/$name.repo"
  mkdir -p "$FIXTURE/tests" || abort "cannot create fixture for $name"
  cp "$ROOT/build.sh" "$FIXTURE/build.sh" || abort "cannot copy build.sh"
  cp "$INVENTORY" "$FIXTURE/tests/build-inventory.py" || \
    abort "cannot copy inventory helper"
  cp -R "$ROOT/skills" "$FIXTURE/skills" || abort "cannot copy skills"
  cp -R "$ROOT/hosts" "$FIXTURE/hosts" || abort "cannot copy hosts"
  cp -R "$ROOT/cursor-implementation-loop" \
    "$FIXTURE/cursor-implementation-loop" || abort "cannot copy generated tree"
}

run_builder check "$ROOT" --check
expect_zero 'build --check accepts the committed generated tree'

FIRST_PARENT="$TMP_ROOT/first"
SECOND_PARENT="$TMP_ROOT/second"
mkdir "$FIRST_PARENT" "$SECOND_PARENT" || abort 'cannot create build parents'
run_builder first "$ROOT" --out "$FIRST_PARENT/package"
expect_zero 'first isolated build succeeds'
run_builder second "$ROOT" --out "$SECOND_PARENT/package"
expect_zero 'second isolated build succeeds'

python3 "$INVENTORY" "$FIRST_PARENT/package" > "$FIRST_PARENT/inventory.tsv" || \
  abort 'cannot inventory first build'
python3 "$INVENTORY" "$SECOND_PARENT/package" > "$SECOND_PARENT/inventory.tsv" || \
  abort 'cannot inventory second build'
if cmp -s "$FIRST_PARENT/inventory.tsv" "$SECOND_PARENT/inventory.tsv"; then
  pass 'two builds have identical external inventories'
else
  CASE_STDOUT="$FIRST_PARENT/inventory.tsv"
  CASE_STDERR="$SECOND_PARENT/inventory.tsv"
  fail 'two builds have identical external inventories'
fi

find "$FIRST_PARENT/package" -type l -print | LC_ALL=C sort \
  > "$TMP_ROOT/output-symlinks"
if [[ ! -s "$TMP_ROOT/output-symlinks" ]]; then
  pass 'generated tree emits no symlinks'
else
  CASE_STDERR="$TMP_ROOT/output-symlinks"
  fail 'generated tree emits no symlinks'
fi

awk -F '\t' '$2 == "file" && $3 == "0755" { print $1 }' \
  "$FIRST_PARENT/inventory.tsv" > "$TMP_ROOT/executables.actual"
cat > "$TMP_ROOT/executables.expected" <<'EOF'
skills/cursor-engineering-mode/scripts/tree-oid-selftest.sh
skills/cursor-engineering-mode/scripts/tree-oid.sh
skills/cursor-implementation-loop/scripts/gate-selftest.sh
skills/cursor-implementation-loop/scripts/run-gate.sh
EOF
if cmp -s "$TMP_ROOT/executables.expected" "$TMP_ROOT/executables.actual"; then
  pass 'generated tree has exactly four executable files'
else
  CASE_STDOUT="$TMP_ROOT/executables.expected"
  CASE_STDERR="$TMP_ROOT/executables.actual"
  fail 'generated tree has exactly four executable files'
fi

if awk -F '\t' '$2 == "file" && $3 != "0644" && $3 != "0755" { exit 1 }' \
    "$FIRST_PARENT/inventory.tsv"; then
  pass 'every generated file has an explicit supported mode'
else
  fail 'every generated file has an explicit supported mode'
fi
if awk -F '\t' '$2 == "directory" && $3 != "0755" { exit 1 }' \
    "$FIRST_PARENT/inventory.tsv"; then
  pass 'every generated directory is mode 0755'
else
  fail 'every generated directory is mode 0755'
fi

make_fixture symlink
ln -s README.md "$FIXTURE/hosts/cursor/undeclared-link" || \
  abort 'cannot create symlink fixture'
run_builder symlink "$FIXTURE" --out "$TMP_ROOT/symlink-output"
expect_nonzero 'builder refuses symlink inputs'
expect_stderr 'symlinks are forbidden' 'symlink refusal identifies the cause'

make_fixture undeclared
printf '%s\n' 'undeclared' > "$FIXTURE/hosts/cursor/undeclared.txt"
run_builder undeclared "$FIXTURE" --out "$TMP_ROOT/undeclared-output"
expect_nonzero 'builder refuses undeclared overlay inputs'
expect_stderr 'missing or undeclared input' 'undeclared-input refusal identifies the cause'

NONEMPTY="$TMP_ROOT/nonempty-output"
mkdir "$NONEMPTY" || abort 'cannot create non-empty destination'
printf '%s\n' 'preserve me' > "$NONEMPTY/sentinel"
run_builder nonempty "$ROOT" --out "$NONEMPTY"
expect_nonzero 'builder refuses a non-empty --out destination'
expect_stderr 'destination is not empty' 'non-empty destination refusal identifies the cause'
if grep -Fqx 'preserve me' "$NONEMPTY/sentinel"; then
  pass 'non-empty destination remains untouched'
else
  fail 'non-empty destination remains untouched'
fi

make_fixture version
printf '\n' >> "$FIXTURE/hosts/cursor/README.md"
run_builder version-rebuild "$FIXTURE"
expect_zero 'fixture rebuild succeeds without rewriting the version decision'
run_builder version-stale "$FIXTURE" --check
expect_nonzero 'version gate rejects a stale generated-tree hash'
expect_stderr 'version decision is stale' 'stale version decision identifies the cause'

TREE_HASH="$(python3 "$FIXTURE/tests/build-inventory.py" --hash \
  "$FIXTURE/cursor-implementation-loop")" || abort 'cannot hash version fixture'
PLUGIN_VERSION="$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
  "$FIXTURE/cursor-implementation-loop/.cursor-plugin/plugin.json")" || \
  abort 'cannot read fixture plugin version'
printf '#schema=1\ntree-sha256\t%s\ndecision\tbump=9.9.9\n' "$TREE_HASH" \
  > "$FIXTURE/hosts/cursor/version-decision.tsv"
run_builder version-wrong-bump "$FIXTURE" --check
expect_nonzero 'version gate rejects a mismatched bump version'
expect_stderr 'does not match generated plugin version' \
  'mismatched bump identifies the cause'

printf '#schema=1\ntree-sha256\t%s\ndecision\tbump=%s\n' \
  "$TREE_HASH" "$PLUGIN_VERSION" \
  > "$FIXTURE/hosts/cursor/version-decision.tsv"
run_builder version-matching-bump "$FIXTURE" --check
expect_zero 'version gate accepts bump=<generated plugin version>'

if [[ "$FAILED_CHECKS" -ne 0 ]]; then
  printf 'selftest: FAIL (%d failed of %d checks)\n' \
    "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi

printf 'selftest: PASS (%d checks)\n' "$CHECKS"
