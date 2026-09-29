"""Read-only access to one run's journal segment (task-graph-v1 Phase A,
sub-unit 0a.3).

The segment is located exactly as scripts/loop-journal locates it:
$HOME/.config/olddonkey-loop/journal/<workspace_key_for(workspace)>/runs/
<run>.jsonl, where the workspace is its realpath and workspace_key_for is
the hex SHA-256 of that path. The managed root, the journal root, the
workspace store, and runs/ must be real 0700 directories owned by this uid
with no symlink on the way down; the segment must be a regular 0600 file
owned by this uid with one link, opened with O_NOFOLLOW. Lines split as
loop-journal's parser splits them: an invalid unterminated last line is a
torn tail and is left out (loop-journal would repair it on its next write);
an invalid newline-terminated line is mid-file corruption and is refused.

Nothing is created, repaired, locked, or written: loop-journal's meta.lock
is never taken, so a concurrent journal writer is never blocked.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat

from .vocabulary import RUN_ID_RE

OWNER = os.getuid()


class JournalReadError(Exception):
    """usage is true for a caller's mistake (a bad workspace or run id, a
    run with no segment), false for a journal that cannot be trusted."""

    def __init__(self, code: str, message: str, usage: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.usage = usage


def _has_newline(value: str) -> bool:
    return "\n" in value or "\r" in value


def resolve_workspace(raw: object) -> str:
    """loop-journal's canonical workspace: an existing directory's realpath."""
    if type(raw) is not str or not raw or _has_newline(raw) or not os.path.isdir(raw):
        raise JournalReadError("workspace", f"workspace is not a directory: {raw!r}", usage=True)
    canonical = os.path.realpath(raw)
    if not os.path.isdir(canonical) or _has_newline(canonical):
        raise JournalReadError("workspace", f"workspace is not a directory: {raw!r}", usage=True)
    return canonical


def workspace_key_for(canonical: str) -> str:
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def managed_loop_root() -> str:
    home = os.environ.get("HOME")
    if not home:
        raise JournalReadError("home", "HOME is not set")
    return os.path.join(os.path.abspath(home), ".config", "olddonkey-loop")


def segment_path(canonical: str, run_id: str) -> str:
    return os.path.join(managed_loop_root(), "journal", workspace_key_for(canonical), "runs",
                        f"{run_id}.jsonl")


def _check_directory(path: str) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError as error:
        raise JournalReadError("no-run", f"the journal has no directory {path}", usage=True) from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise JournalReadError("journal-unsafe", f"not a real directory: {path}")
    if info.st_uid != OWNER:
        raise JournalReadError("journal-unsafe", f"directory is foreign-owned: {path}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise JournalReadError("journal-unsafe", f"directory mode must be 0700: {path}")


def _check_regular(info: os.stat_result, path: str) -> None:
    if not stat.S_ISREG(info.st_mode):
        raise JournalReadError("journal-unsafe", f"not a regular file: {path}")
    if info.st_uid != OWNER:
        raise JournalReadError("journal-unsafe", f"file is foreign-owned: {path}")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise JournalReadError("journal-unsafe", f"file mode must be 0600: {path}")
    if info.st_nlink != 1:
        raise JournalReadError("journal-unsafe", f"file has multiple hard links: {path}")


def parse_segment(data: bytes) -> tuple[list[dict], int]:
    """(events, torn tail bytes) with loop-journal's rules; a mid-file
    invalid line is refused."""
    if not data:
        return [], 0
    parts = data.split(b"\n")
    ended = data.endswith(b"\n")
    if ended:
        parts = parts[:-1]
    events: list[dict] = []
    for index, line in enumerate(parts):
        try:
            obj = json.loads(line.decode("utf-8"))
            if not isinstance(obj, dict):
                raise ValueError("event is not an object")
        except (UnicodeDecodeError, ValueError, RecursionError) as error:
            if index == len(parts) - 1 and not ended:
                return events, len(line)
            raise JournalReadError("journal-corrupt",
                                   f"line {index + 1} is not a JSON object: mid-file corruption") from error
        events.append(obj)
    return events, 0


def read_run(workspace: object, run_id: object) -> dict:
    """The run's parsed lines, in file order, and where they came from."""
    canonical = resolve_workspace(workspace)
    if type(run_id) is not str or not RUN_ID_RE.fullmatch(run_id):
        raise JournalReadError("run-id", f"invalid run id: {run_id!r}", usage=True)
    path = segment_path(canonical, run_id)
    managed = managed_loop_root()
    current = managed
    _check_directory(current)
    for part in os.path.relpath(os.path.dirname(path), managed).split(os.sep):
        current = os.path.join(current, part)
        _check_directory(current)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError as error:
        raise JournalReadError("no-run", f"no segment for run {run_id} in this workspace's journal",
                               usage=True) from error
    except OSError as error:
        raise JournalReadError("journal-unsafe", f"cannot open {path}: {error}") from error
    try:
        _check_regular(os.fstat(fd), path)
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(fd)
    events, torn = parse_segment(b"".join(chunks))
    return {
        "workspace": canonical,
        "workspace_key": workspace_key_for(canonical),
        "run": run_id,
        "events": events,
        "torn_tail_bytes": torn,
    }
