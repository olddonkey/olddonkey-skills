#!/usr/bin/env python3
"""Emit a deterministic path/type/mode/SHA-256 inventory for a directory tree."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys


def fail(message: str) -> "None":
    print(f"build-inventory: {message}", file=sys.stderr)
    raise SystemExit(1)


def sorted_tree_paths(root: Path) -> list[Path]:
    paths: list[Path] = []

    def visit(directory: Path) -> None:
        entries = sorted(os.scandir(directory), key=lambda entry: os.fsencode(entry.name))
        for entry in entries:
            path = Path(entry.path)
            paths.append(path)
            if stat.S_ISDIR(entry.stat(follow_symlinks=False).st_mode):
                visit(path)

    visit(root)
    return paths


def inventory(root: Path) -> bytes:
    if root.is_symlink():
        fail(f"tree root is a symlink: {root}")
    if not root.is_dir():
        fail(f"tree root is not a directory: {root}")

    rows: list[bytes] = []
    for path in sorted_tree_paths(root):
        relative = path.relative_to(root).as_posix()
        if "\t" in relative or "\n" in relative or "\r" in relative:
            fail(f"unsupported control character in path: {relative!r}")

        metadata = path.lstat()
        mode = f"{stat.S_IMODE(metadata.st_mode):04o}"
        if stat.S_ISREG(metadata.st_mode):
            entry_type = "file"
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISDIR(metadata.st_mode):
            entry_type = "directory"
            digest = "-"
        elif stat.S_ISLNK(metadata.st_mode):
            entry_type = "symlink"
            digest = hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
        else:
            entry_type = "other"
            digest = "-"

        rows.append(
            f"{relative}\t{entry_type}\t{mode}\t{digest}\n".encode("utf-8")
        )
    return b"".join(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--hash",
        action="store_true",
        help="print the SHA-256 of the inventory instead of the inventory",
    )
    parser.add_argument("tree", type=Path)
    arguments = parser.parse_args()

    rendered = inventory(arguments.tree)
    if arguments.hash:
        print(hashlib.sha256(rendered).hexdigest())
    else:
        sys.stdout.buffer.write(rendered)


if __name__ == "__main__":
    main()
