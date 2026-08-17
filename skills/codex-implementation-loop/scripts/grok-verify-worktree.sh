#!/usr/bin/env bash
# Verify a grok worktree marker baseline without invoking git.
#
# Usage:
#   grok-verify-worktree.sh --baseline /absolute/baseline.json
#   grok-verify-worktree.sh --baseline /absolute/baseline.json --worktree /absolute/worktree
#
# Exit status:
#   0  baseline and every .git marker match
#   2  marker set, bytes, or lstat identity mismatch
#   3  missing/stale baseline, wrong worktree, or invalid invocation

set -euo pipefail

BASELINE=""
WORKTREE=""

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="${2:?--baseline needs an absolute path}"; shift 2 ;;
    --worktree) WORKTREE="${2:?--worktree needs an absolute path}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 3 ;;
  esac
done

[[ "$BASELINE" == /* ]] || { echo "error: --baseline must be absolute" >&2; exit 3; }
[[ -z "$WORKTREE" || "$WORKTREE" == /* ]] || {
  echo "error: --worktree must be absolute" >&2
  exit 3
}
TOML_PYTHON=""
for TOML_CANDIDATE in python3 python3.13 python3.12 python3.11; do
  if command -v "$TOML_CANDIDATE" >/dev/null 2>&1 && \
     "$TOML_CANDIDATE" -c 'import tomllib' >/dev/null 2>&1; then
    TOML_PYTHON="$TOML_CANDIDATE"
    break
  fi
done
[[ -n "$TOML_PYTHON" ]] || {
  echo "error: python3 3.11+ with tomllib is required" >&2
  exit 3
}

"$TOML_PYTHON" - "$BASELINE" "$WORKTREE" <<'PY'
import hashlib
import json
import os
import stat
import sys

baseline_path, requested_worktree = sys.argv[1:]


def refuse(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(3)


def mismatch(message):
    print(f"mismatch: {message}", file=sys.stderr)
    raise SystemExit(2)


if not os.path.isfile(baseline_path):
    refuse(f"baseline is missing or not a regular file: {baseline_path}")
try:
    with open(baseline_path, encoding="utf-8") as handle:
        baseline = json.load(handle)
except (OSError, ValueError, TypeError):
    refuse(f"baseline is unreadable or invalid JSON: {baseline_path}")

if not isinstance(baseline, dict) or baseline.get("schema") != "1":
    refuse("baseline schema is missing or stale")
if baseline.get("status") != "active":
    refuse("baseline is stale")
recorded_worktree = baseline.get("worktree")
markers = baseline.get("markers")
if not isinstance(recorded_worktree, str) or not os.path.isabs(recorded_worktree):
    refuse("baseline has no absolute worktree identity")
if not isinstance(markers, list):
    refuse("baseline marker list is invalid")

worktree = requested_worktree or recorded_worktree
if not os.path.isabs(worktree):
    refuse("worktree identity is not absolute")
worktree = os.path.realpath(worktree)
if worktree != recorded_worktree:
    refuse(
        "baseline belongs to a different worktree: "
        f"recorded={recorded_worktree} requested={worktree}"
    )
if not os.path.isdir(worktree):
    refuse(f"recorded worktree is missing: {worktree}")


def marker_paths(root):
    found = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        if ".git" in dirnames:
            candidate = os.path.join(directory, ".git")
            mismatch(f"in-worktree .git directory found: {candidate}")
        if ".git" in filenames:
            candidate = os.path.join(directory, ".git")
            found.append(os.path.relpath(candidate, root))
    return sorted(found)


expected_paths = []
expected = {}
required_keys = {
    "path", "type", "dev", "inode", "nlink", "size", "mtime_ns", "ctime_ns", "sha256"
}
for entry in markers:
    if not isinstance(entry, dict) or set(entry) != required_keys:
        refuse("baseline marker entry has an invalid schema")
    relative = entry.get("path")
    if (
        not isinstance(relative, str)
        or relative == "."
        or os.path.isabs(relative)
        or relative.startswith("../")
    ):
        refuse("baseline marker path is not a safe relative path")
    if relative in expected:
        refuse(f"baseline contains duplicate marker path: {relative}")
    expected_paths.append(relative)
    expected[relative] = entry

actual_paths = marker_paths(worktree)
if sorted(expected_paths) != actual_paths:
    mismatch(
        "marker path set changed: "
        f"expected={sorted(expected_paths)!r} actual={actual_paths!r}"
    )

for relative in actual_paths:
    path = os.path.join(worktree, relative)
    try:
        info = os.lstat(path)
    except OSError as exc:
        mismatch(f"cannot lstat marker {relative}: {exc}")
    actual_type = "file" if stat.S_ISREG(info.st_mode) else (
        "symlink" if stat.S_ISLNK(info.st_mode) else "other"
    )
    entry = expected[relative]
    identity = {
        "type": actual_type,
        "dev": info.st_dev,
        "inode": info.st_ino,
        "nlink": info.st_nlink,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns,
    }
    for key, actual in identity.items():
        if entry[key] != actual:
            mismatch(
                f"marker {relative} {key} changed: "
                f"expected={entry[key]!r} actual={actual!r}"
            )
    if actual_type != "file":
        mismatch(f"marker {relative} is not a regular file")
    digest = hashlib.sha256()
    try:
        with open(path, "rb", buffering=0) as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as exc:
        mismatch(f"cannot hash marker {relative}: {exc}")
    if digest.hexdigest() != entry["sha256"]:
        mismatch(f"marker {relative} content hash changed")

print(f"verified: {worktree} ({len(actual_paths)} markers)")
PY
