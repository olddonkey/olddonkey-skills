#!/usr/bin/env bash
# Assemble the committed Cursor plugin from shared skills and its host overlay.

set -euo pipefail

export LC_ALL=C
umask 022

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMMITTED_TREE="$ROOT/cursor-implementation-loop"
OVERLAY_ROOT="$ROOT/hosts/cursor"
INVENTORY_TOOL="$ROOT/tests/build-inventory.py"
WORK_ROOT=""

cleanup() { # $1=status to preserve
  local status="$1"
  trap - EXIT HUP INT TERM
  if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT"
  fi
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

usage() {
  cat <<'USAGE'
Usage:
  bash build.sh
  bash build.sh --check
  bash build.sh --out DIR

Modes:
  (default)  Rebuild cursor-implementation-loop/ from a fresh staging tree.
  --check    Build in a temporary directory and compare external inventories.
  --out DIR  Build into DIR, which must be absent or empty.
USAGE
}

fail() {
  printf 'build: %s\n' "$1" >&2
  exit 1
}

write_mapping() { # $1=unsorted mapping path
  cat > "$1" <<'EOF'
.cursor-plugin/plugin.json	hosts/cursor/.cursor-plugin/plugin.json	0644	copy
README.md	hosts/cursor/README.md	0644	copy
agents/loop-implementer.md	hosts/cursor/agents/loop-implementer.md	0644	copy
agents/loop-independent-reviewer.md	hosts/cursor/agents/loop-independent-reviewer.md	0644	copy
skills/cursor-engineering-mode/SKILL.md	hosts/cursor/skills/cursor-engineering-mode/SKILL.md	0644	copy
skills/cursor-engineering-mode/references/adapter.md	hosts/cursor/skills/cursor-engineering-mode/references/adapter.md	0644	copy
skills/cursor-engineering-mode/references/handoff.md	skills/engineering-mode/references/handoff.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/bug-fix.md	skills/engineering-mode/references/playbooks/bug-fix.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/feature.md	skills/engineering-mode/references/playbooks/feature.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/investigation.md	skills/engineering-mode/references/playbooks/investigation.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/performance.md	skills/engineering-mode/references/playbooks/performance.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/prototype.md	skills/engineering-mode/references/playbooks/prototype.md	0644	copy
skills/cursor-engineering-mode/references/playbooks/refactor.md	skills/engineering-mode/references/playbooks/refactor.md	0644	copy
skills/cursor-engineering-mode/references/verification-contract.md	skills/engineering-mode/references/verification-contract.md	0644	copy
skills/cursor-engineering-mode/scripts/tree-oid-selftest.sh	skills/engineering-mode/scripts/tree-oid-selftest.sh	0755	copy
skills/cursor-engineering-mode/scripts/tree-oid.sh	skills/engineering-mode/scripts/tree-oid.sh	0755	copy
skills/cursor-implementation-loop/SKILL.md	hosts/cursor/skills/cursor-implementation-loop/SKILL.md	0644	copy
skills/cursor-implementation-loop/references/cursor-runtime.md	hosts/cursor/skills/cursor-implementation-loop/references/cursor-runtime.md	0644	copy
skills/cursor-implementation-loop/references/dials.md	hosts/cursor/skills/cursor-implementation-loop/references/dials.md	0644	copy
skills/cursor-implementation-loop/references/gate.md	hosts/cursor/skills/cursor-implementation-loop/references/gate.md	0644	copy
skills/cursor-implementation-loop/references/review-checklist.md	skills/implementation-loop/references/review-checklist.md	0644	copy
skills/cursor-implementation-loop/references/unit-contract.md	hosts/cursor/skills/cursor-implementation-loop/references/unit-contract.md	0644	copy
skills/cursor-implementation-loop/scripts/gate-selftest.sh	skills/implementation-loop/tests/gate-selftest.sh	0755	copy
skills/cursor-implementation-loop/scripts/run-gate.sh	skills/implementation-loop/scripts/run-gate.sh	0755	copy
GENERATED.md	build.sh	0644	literal
build-manifest.tsv	build.sh	0644	manifest
EOF
}

check_no_symlink_components() { # $1=absolute input path
  local path="$1" parent
  parent="$path"
  while [[ "$parent" != "$ROOT" ]]; do
    [[ ! -L "$parent" ]] || fail "input path contains a symlink: $parent"
    parent="${parent%/*}"
    [[ -n "$parent" ]] || fail "input is outside the repository: $path"
  done
}

validate_mapping() { # $1=sorted mapping path
  local mapping="$1" source source_path

  if ! awk -F '\t' '
      NF != 4 { exit 1 }
      $1 == "" || $2 == "" { exit 1 }
      $1 ~ /^\// || $2 ~ /^\// { exit 1 }
      $1 ~ /(^|\/)\.\.?(\/|$)/ || $2 ~ /(^|\/)\.\.?(\/|$)/ { exit 1 }
      $1 ~ /\/\// || $2 ~ /\/\// { exit 1 }
      $3 != "0644" && $3 != "0755" { exit 1 }
      $4 != "copy" && $4 != "literal" && $4 != "manifest" { exit 1 }
      previous == $1 { exit 1 }
      { previous = $1 }
      END { if (NR == 0) exit 1 }
    ' "$mapping"; then
    fail 'invalid or duplicate build mapping row'
  fi

  awk -F '\t' '$3 == "0755" { print $1 }' "$mapping" \
    > "$WORK_ROOT/executables.actual"
  cat > "$WORK_ROOT/executables.expected" <<'EOF'
skills/cursor-engineering-mode/scripts/tree-oid-selftest.sh
skills/cursor-engineering-mode/scripts/tree-oid.sh
skills/cursor-implementation-loop/scripts/gate-selftest.sh
skills/cursor-implementation-loop/scripts/run-gate.sh
EOF
  if ! cmp -s "$WORK_ROOT/executables.expected" \
      "$WORK_ROOT/executables.actual"; then
    diff -u "$WORK_ROOT/executables.expected" \
      "$WORK_ROOT/executables.actual" >&2 || true
    fail 'the executable set must contain exactly the four declared scripts'
  fi

  cut -f2 "$mapping" | LC_ALL=C sort -u > "$WORK_ROOT/inputs.declared"
  printf '%s\n' \
    'hosts/cursor/version-decision.tsv' \
    'tests/build-inventory.py' \
    >> "$WORK_ROOT/inputs.declared"
  LC_ALL=C sort -u "$WORK_ROOT/inputs.declared" \
    > "$WORK_ROOT/inputs.declared.sorted"
  mv "$WORK_ROOT/inputs.declared.sorted" "$WORK_ROOT/inputs.declared"

  while IFS= read -r source; do
    source_path="$ROOT/$source"
    check_no_symlink_components "$source_path"
    [[ -f "$source_path" ]] || fail "declared input is not a regular file: $source"
  done < "$WORK_ROOT/inputs.declared"
}

derive_parent_directories() { # $1=path list $2=boundary $3=output
  local path_list="$1" boundary="$2" output="$3"
  local path parent
  : > "$output.unsorted"
  while IFS= read -r path; do
    parent="${path%/*}"
    while [[ "$parent" != "$path" && "$parent" != "$boundary" ]]; do
      printf '%s\n' "$parent" >> "$output.unsorted"
      path="$parent"
      parent="${path%/*}"
    done
  done < "$path_list"
  LC_ALL=C sort -u "$output.unsorted" > "$output"
}

validate_overlay_inventory() {
  [[ -d "$OVERLAY_ROOT" && ! -L "$OVERLAY_ROOT" ]] || \
    fail 'hosts/cursor must be a real directory, not a symlink'

  (
    cd "$ROOT"
    find hosts/cursor -type l -print | LC_ALL=C sort
  ) > "$WORK_ROOT/overlay.symlinks"
  [[ ! -s "$WORK_ROOT/overlay.symlinks" ]] || {
    sed 's/^/build: symlink input: /' "$WORK_ROOT/overlay.symlinks" >&2
    fail 'symlinks are forbidden in hosts/cursor'
  }

  (
    cd "$ROOT"
    find hosts/cursor ! -type d ! -type f ! -type l -print | LC_ALL=C sort
  ) > "$WORK_ROOT/overlay.other"
  [[ ! -s "$WORK_ROOT/overlay.other" ]] || {
    sed 's/^/build: unsupported input: /' "$WORK_ROOT/overlay.other" >&2
    fail 'hosts/cursor contains a non-file input'
  }

  (
    cd "$ROOT"
    find hosts/cursor -type f -print | LC_ALL=C sort
  ) > "$WORK_ROOT/overlay.actual"
  awk '/^hosts\/cursor\//' "$WORK_ROOT/inputs.declared" \
    > "$WORK_ROOT/overlay.expected"
  if ! cmp -s "$WORK_ROOT/overlay.expected" "$WORK_ROOT/overlay.actual"; then
    diff -u "$WORK_ROOT/overlay.expected" "$WORK_ROOT/overlay.actual" >&2 || true
    fail 'hosts/cursor contains a missing or undeclared input'
  fi

  derive_parent_directories "$WORK_ROOT/overlay.expected" \
    'hosts/cursor' "$WORK_ROOT/overlay-directories.expected"
  (
    cd "$ROOT"
    find hosts/cursor -type d ! -path hosts/cursor -print | LC_ALL=C sort
  ) > "$WORK_ROOT/overlay-directories.actual"
  if ! cmp -s "$WORK_ROOT/overlay-directories.expected" \
      "$WORK_ROOT/overlay-directories.actual"; then
    diff -u "$WORK_ROOT/overlay-directories.expected" \
      "$WORK_ROOT/overlay-directories.actual" >&2 || true
    fail 'hosts/cursor contains a missing or undeclared directory'
  fi
}

write_generated_notice() { # $1=output path
  cat > "$1" <<'EOF'
# Generated Cursor package

This tree is generated by the repository-root `build.sh`; do not edit it directly.
Edit shared files under `skills/` or Cursor-only files under `hosts/cursor/`, then
run `bash build.sh`. Use `bash build.sh --check` to verify committed output.
EOF
}

validate_output() { # $1=assembled tree $2=sorted mapping
  local tree="$1" mapping="$2"

  (
    cd "$tree"
    find . -type l -print | sed 's#^\./##' | LC_ALL=C sort
  ) > "$WORK_ROOT/output.symlinks"
  [[ ! -s "$WORK_ROOT/output.symlinks" ]] || \
    fail 'generated output contains a symlink'

  (
    cd "$tree"
    find . ! -type d ! -type f ! -type l -print | sed 's#^\./##' | \
      LC_ALL=C sort
  ) > "$WORK_ROOT/output.other"
  [[ ! -s "$WORK_ROOT/output.other" ]] || \
    fail 'generated output contains an unsupported entry type'

  cut -f1 "$mapping" > "$WORK_ROOT/outputs.expected"
  (
    cd "$tree"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
  ) > "$WORK_ROOT/outputs.actual"
  if ! cmp -s "$WORK_ROOT/outputs.expected" "$WORK_ROOT/outputs.actual"; then
    diff -u "$WORK_ROOT/outputs.expected" "$WORK_ROOT/outputs.actual" >&2 || true
    fail 'generated output contains a missing or undeclared file'
  fi

  derive_parent_directories "$WORK_ROOT/outputs.expected" '' \
    "$WORK_ROOT/output-directories.expected"
  (
    cd "$tree"
    find . -type d ! -path . -print | sed 's#^\./##' | LC_ALL=C sort
  ) > "$WORK_ROOT/output-directories.actual"
  if ! cmp -s "$WORK_ROOT/output-directories.expected" \
      "$WORK_ROOT/output-directories.actual"; then
    diff -u "$WORK_ROOT/output-directories.expected" \
      "$WORK_ROOT/output-directories.actual" >&2 || true
    fail 'generated output contains a missing or undeclared directory'
  fi

  python3 "$INVENTORY_TOOL" "$tree" > "$WORK_ROOT/output.inventory"
  awk -F '\t' '$2 == "file" { print $1 "\t" $3 }' \
    "$WORK_ROOT/output.inventory" > "$WORK_ROOT/output-modes.actual"
  awk -F '\t' '{ print $1 "\t" $3 }' "$mapping" \
    > "$WORK_ROOT/output-modes.expected"
  if ! cmp -s "$WORK_ROOT/output-modes.expected" \
      "$WORK_ROOT/output-modes.actual"; then
    diff -u "$WORK_ROOT/output-modes.expected" \
      "$WORK_ROOT/output-modes.actual" >&2 || true
    fail 'generated output mode mismatch'
  fi
  if awk -F '\t' '$2 == "directory" && $3 != "0755" { exit 1 }' \
      "$WORK_ROOT/output.inventory"; then
    :
  else
    fail 'generated directories must have mode 0755'
  fi
}

assemble() { # $1=new empty destination $2=sorted mapping
  local destination="$1" mapping="$2"
  local output source mode transform target parent directory

  [[ ! -e "$destination" && ! -L "$destination" ]] || \
    fail "internal destination already exists: $destination"
  mkdir "$destination"
  chmod 0755 "$destination"

  while IFS=$'\t' read -r output source mode transform; do
    target="$destination/$output"
    parent="${target%/*}"
    mkdir -p "$parent"
    case "$transform" in
      copy)
        cp "$ROOT/$source" "$target"
        ;;
      literal)
        write_generated_notice "$target"
        ;;
      manifest)
        {
          printf '%s\n' '#schema=1'
          cat "$mapping"
        } > "$target"
        ;;
      *)
        fail "unsupported transform after validation: $transform"
        ;;
    esac
    chmod "$mode" "$target"
  done < "$mapping"

  while IFS= read -r directory; do
    chmod 0755 "$directory"
  done < <(find "$destination" -type d -print | LC_ALL=C sort)

  validate_output "$destination" "$mapping"
}

validate_destination() { # $1=destination $2=allow replacement (0/1)
  local destination="$1" allow_replacement="$2"
  local parent entries

  [[ -n "$destination" && "$destination" != / ]] || \
    fail 'refusing an empty or filesystem-root destination'
  [[ ! -L "$destination" ]] || fail "destination is a symlink: $destination"
  parent="${destination%/*}"
  [[ "$parent" != "$destination" ]] || parent=.
  [[ -d "$parent" ]] || fail "destination parent is not a directory: $parent"

  if [[ -e "$destination" ]]; then
    [[ -d "$destination" ]] || fail "destination exists and is not a directory: $destination"
    if [[ "$allow_replacement" -eq 0 ]]; then
      find "$destination" -mindepth 1 -print | LC_ALL=C sort \
        > "$WORK_ROOT/destination.entries"
      [[ ! -s "$WORK_ROOT/destination.entries" ]] || \
        fail "destination is not empty: $destination"
    fi
  fi
}

publish() { # $1=staged tree $2=destination $3=allow replacement (0/1)
  local staged="$1" destination="$2" allow_replacement="$3"

  if [[ -e "$destination" ]]; then
    if [[ "$allow_replacement" -eq 1 ]]; then
      rm -rf "$destination"
    else
      rmdir "$destination"
    fi
  fi
  mv "$staged" "$destination"
}

check_version_decision() { # $1=built tree
  local tree="$1" decision_file recorded_hash decision actual_hash
  local plugin_version line_count
  decision_file="$OVERLAY_ROOT/version-decision.tsv"

  line_count="$(wc -l < "$decision_file" | tr -d '[:space:]')"
  [[ "$line_count" == 3 ]] || \
    fail 'version-decision.tsv must contain exactly three lines'
  [[ "$(sed -n '1p' "$decision_file")" == '#schema=1' ]] || \
    fail 'version-decision.tsv has an unsupported schema'
  recorded_hash="$(awk -F '\t' 'NR == 2 && NF == 2 && $1 == "tree-sha256" { print $2 }' "$decision_file")"
  decision="$(awk -F '\t' 'NR == 3 && NF == 2 && $1 == "decision" { print $2 }' "$decision_file")"
  printf '%s\n' "$recorded_hash" | grep -Eq '^[0-9a-f]{64}$' || \
    fail 'version-decision.tsv has an invalid tree SHA-256'

  actual_hash="$(python3 "$INVENTORY_TOOL" --hash "$tree")"
  [[ "$recorded_hash" == "$actual_hash" ]] || \
    fail "version decision is stale: recorded $recorded_hash, built $actual_hash"

  case "$decision" in
    keep)
      ;;
    bump=*)
      plugin_version="$(python3 -c \
        'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
        "$tree/.cursor-plugin/plugin.json")"
      [[ "${decision#bump=}" == "$plugin_version" ]] || \
        fail "version decision $decision does not match generated plugin version $plugin_version"
      ;;
    *)
      fail 'version decision must be keep or bump=<version>'
      ;;
  esac
}

MODE=default
OUTPUT_ARGUMENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      [[ "$MODE" == default && -z "$OUTPUT_ARGUMENT" ]] || {
        usage >&2
        exit 2
      }
      MODE=check
      shift
      ;;
    --out)
      [[ "$MODE" == default && -z "$OUTPUT_ARGUMENT" && $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      MODE=out
      OUTPUT_ARGUMENT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf 'build: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
[[ -f "$INVENTORY_TOOL" && ! -L "$INVENTORY_TOOL" ]] || \
  fail 'tests/build-inventory.py is missing or is a symlink'

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cursor-package-build.XXXXXX")" || \
  fail 'cannot create temporary build directory'
write_mapping "$WORK_ROOT/mapping.unsorted"
LC_ALL=C sort "$WORK_ROOT/mapping.unsorted" > "$WORK_ROOT/mapping.tsv"
validate_mapping "$WORK_ROOT/mapping.tsv"
validate_overlay_inventory

if [[ "$MODE" == out ]]; then
  validate_destination "$OUTPUT_ARGUMENT" 0
fi

STAGED_TREE="$WORK_ROOT/package"
assemble "$STAGED_TREE" "$WORK_ROOT/mapping.tsv"

case "$MODE" in
  check)
    [[ -d "$COMMITTED_TREE" && ! -L "$COMMITTED_TREE" ]] || \
      fail 'committed cursor-implementation-loop tree is missing or is a symlink'
    python3 "$INVENTORY_TOOL" "$STAGED_TREE" > "$WORK_ROOT/built.inventory"
    python3 "$INVENTORY_TOOL" "$COMMITTED_TREE" > "$WORK_ROOT/committed.inventory"
    if ! cmp -s "$WORK_ROOT/built.inventory" "$WORK_ROOT/committed.inventory"; then
      diff -u "$WORK_ROOT/committed.inventory" "$WORK_ROOT/built.inventory" >&2 || true
      fail 'committed Cursor package does not match a fresh build'
    fi
    check_version_decision "$STAGED_TREE"
    printf 'build: PASS (committed Cursor package is current)\n'
    ;;
  out)
    publish "$STAGED_TREE" "$OUTPUT_ARGUMENT" 0
    printf 'build: wrote %s\n' "$OUTPUT_ARGUMENT"
    ;;
  default)
    validate_destination "$COMMITTED_TREE" 1
    publish "$STAGED_TREE" "$COMMITTED_TREE" 1
    printf 'build: wrote %s\n' "$COMMITTED_TREE"
    ;;
esac
