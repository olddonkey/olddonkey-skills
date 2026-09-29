"""Deterministic anchor objects and remote reads (A1.2, A1.6; 0a.2 section 4).

An anchor commit is a function of anchor_json, its parent, and the pointer's
store_id, generation, and seq alone: blob = the exact anchor_json bytes;
tree = one entry "100644 anchor.json"; commit with that parent, author and
committer "olddonkey-loop <anchor@olddonkey-loop.invalid>" dated "<seq>
+0000", message "anchor <store_id> g<generation> s<seq>". expected_*()
computes those object ids in Python; build_objects() creates them in a
scratch repository with git and requires the same ids.

Reads of the remote go through git.ls-remote and git.fetch-anchor into the
scratch repository; read_anchor_commit() then verifies a fetched commit by
content -- type, id, one-entry tree, blob, and the commit bytes rebuilt from
the blob -- never by its object id alone.

Pure helpers: only read and scratch commands; the push is store.push_anchor.
"""

from __future__ import annotations

import hashlib
import os
import re

from . import records, tools

ENTRY_MODE = "100644"
ENTRY_NAME = "anchor.json"
IDENTITY = "olddonkey-loop <anchor@olddonkey-loop.invalid>"


class AnchorError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class Unreachable(Exception):
    """The remote could not be read; the state is pending, never decided."""


def _fail(code: str, message: str) -> None:
    raise AnchorError(code, message)


def message(store_id: str, generation: int, seq: int) -> str:
    return f"anchor {store_id} g{generation} s{seq}"


def _object_id(kind: str, data: bytes) -> str:
    return hashlib.sha1(f"{kind} {len(data)}\0".encode("ascii") + data).hexdigest()


def expected_blob(anchor_json: bytes) -> str:
    return _object_id("blob", anchor_json)


def tree_bytes(blob_id: str) -> bytes:
    return f"{ENTRY_MODE} {ENTRY_NAME}\0".encode("ascii") + bytes.fromhex(blob_id)


def expected_tree(anchor_json: bytes) -> str:
    return _object_id("tree", tree_bytes(expected_blob(anchor_json)))


def commit_bytes(tree: str, parent: str | None, store_id: str, generation: int, seq: int) -> bytes:
    lines = [f"tree {tree}"]
    if parent is not None:
        lines.append(f"parent {parent}")
    lines.append(f"author {IDENTITY} {seq} +0000")
    lines.append(f"committer {IDENTITY} {seq} +0000")
    text = "\n".join(lines) + "\n\n" + message(store_id, generation, seq) + "\n"
    return text.encode("ascii")


def pointer_fields(anchor_json: bytes) -> tuple[dict, dict | None, str]:
    try:
        return records.parse_anchor_json(anchor_json)
    except records.RecordError as error:
        raise AnchorError("anchor-json", error.message) from error


def expected_commit_bytes(anchor_json: bytes, parent: str | None) -> bytes:
    active, _prev, _sig = pointer_fields(anchor_json)
    return commit_bytes(expected_tree(anchor_json), parent, active["store_id"],
                        active["generation"], active["seq"])


def expected_commit(anchor_json: bytes, parent: str | None) -> str:
    return _object_id("commit", expected_commit_bytes(anchor_json, parent))


def _git(command_id: str, **params: object) -> tools.Result:
    return tools.run(command_id, **params)  # type: ignore[arg-type]


def _oid_output(result: tools.Result, what: str) -> str:
    if result.returncode != 0:
        _fail("git", f"{what} failed: " + result.stderr.decode("utf-8", "replace").strip()[:200])
    text = result.stdout.decode("ascii", "replace").strip()
    if not tools.OID_RE.fullmatch(text):
        _fail("git", f"{what} printed no object id")
    return text


def build_objects(scratch: str, anchor_json: bytes, parent: str | None) -> str:
    """Create blob, tree, and commit in the scratch repository with git and
    require the ids the Python construction predicts. Returns the commit.
    A parent is first fetched from the pinned remote into the fresh scratch
    repository and must be exactly the remote's tip."""
    active, _prev, _sig = pointer_fields(anchor_json)
    if parent is not None:
        remote = tools.pinned_remote()
        if remote is None:
            _fail("remote", "no pinned remote to fetch the parent from")
        try:
            fetched = fetch(scratch, remote.url)  # type: ignore[union-attr]
        except Unreachable as error:
            _fail("anchor-parent", f"cannot fetch the parent commit: {error}")
        if fetched != parent:
            _fail("anchor-parent", "the remote tip is not the expected parent")
    blob = _oid_output(_git("git.hash-object", scratch=scratch, stdin=anchor_json),
                       "git hash-object")
    if blob != expected_blob(anchor_json):
        _fail("anchor-objects", "git hash-object disagrees with the deterministic blob")
    line = f"{ENTRY_MODE} blob {blob}\t{ENTRY_NAME}\n".encode("ascii")
    tree = _oid_output(_git("git.mktree", scratch=scratch, stdin=line), "git mktree")
    if tree != expected_tree(anchor_json):
        _fail("anchor-objects", "git mktree disagrees with the deterministic tree")
    commit = _oid_output(
        _git("git.commit-tree", scratch=scratch, tree=tree, parent=parent,
             message=message(active["store_id"], active["generation"], active["seq"]),
             seq=active["seq"]),
        "git commit-tree",
    )
    if commit != expected_commit(anchor_json, parent):
        _fail("anchor-objects", "git commit-tree disagrees with the deterministic commit")
    check_objects(scratch, commit, anchor_json, parent)
    return commit


def _cat(scratch: str, mode: str, oid: str) -> bytes:
    result = _git("git.cat-file", scratch=scratch, cat_mode=mode, oid=oid)
    if result.returncode != 0:
        _fail("anchor-objects", f"object {oid} is missing or unreadable")
    return result.stdout


# Commits this process has already verified by content: an object id names
# its content, so once verified the (anchor_json, parent) pair is fixed.
_READ: dict[str, tuple[bytes, str | None]] = {}


def read_anchor_commit(scratch: str, oid: str) -> tuple[bytes, str | None]:
    """Verify a commit in the scratch repository by content and return
    (anchor_json bytes, parent id or None)."""
    if oid in _READ:
        return _READ[oid]
    value = _read_anchor_commit(scratch, oid)
    _READ[oid] = value
    return value


def _read_anchor_commit(scratch: str, oid: str) -> tuple[bytes, str | None]:
    if _cat(scratch, "-t", oid).strip() != b"commit":
        _fail("anchor-objects", f"{oid} is not a commit")
    raw = _cat(scratch, "-p", oid)
    if _object_id("commit", raw) != oid:
        _fail("anchor-objects", "commit bytes do not hash to the commit id")
    header, _sep, _msg = raw.partition(b"\n\n")
    tree = None
    parents = []
    for line in header.split(b"\n"):
        if line.startswith(b"tree ") and tree is None:
            tree = line[5:].decode("ascii", "replace")
        elif line.startswith(b"parent "):
            parents.append(line[7:].decode("ascii", "replace"))
    if tree is None or not tools.OID_RE.fullmatch(tree) or len(parents) > 1:
        _fail("anchor-objects", "commit must have one tree and at most one parent")
    if parents and not tools.OID_RE.fullmatch(parents[0]):
        _fail("anchor-objects", "commit parent is malformed")
    if _cat(scratch, "-t", tree).strip() != b"tree":
        _fail("anchor-objects", "commit tree is not a tree")
    listing = _cat(scratch, "-p", tree)
    match = re.fullmatch(rb"100644 blob ([0-9a-f]{40})\tanchor\.json\n", listing)
    if match is None:
        _fail("anchor-tree", "anchor tree must hold exactly one entry, 100644 anchor.json")
    blob = match.group(1).decode("ascii")
    if _cat(scratch, "-t", blob).strip() != b"blob":
        _fail("anchor-objects", "anchor.json is not a blob")
    data = _cat(scratch, "-p", blob)
    if _object_id("blob", data) != blob:
        _fail("anchor-objects", "blob bytes do not hash to the blob id")
    parent = parents[0] if parents else None
    if expected_commit_bytes(data, parent) != raw:
        _fail("anchor-commit", "commit is not the deterministic commit for its anchor.json")
    return data, parent


def check_objects(scratch: str, commit: str, anchor_json: bytes, parent: str | None) -> None:
    """The commit in the scratch repository carries exactly anchor_json, has
    exactly this parent, and is the deterministic commit (A1.6)."""
    data, actual_parent = read_anchor_commit(scratch, commit)
    if data != anchor_json:
        _fail("anchor-blob", "anchor.json blob differs from anchor_json")
    if actual_parent != parent:
        _fail("anchor-parent", "anchor commit parent is not the expected parent")


def ls_remote(scratch: str, remote: str) -> str | None:
    """The remote anchor tip, or None when the ref is absent. Raises
    Unreachable when the remote cannot be read."""
    try:
        result = _git("git.ls-remote", scratch=scratch, remote=remote)
    except tools.ToolError as error:
        if error.code in ("timeout", "exec"):
            raise Unreachable(error.message) from error
        raise
    if result.returncode != 0:
        raise Unreachable(result.stderr.decode("utf-8", "replace").strip()[:300])
    text = result.stdout.decode("ascii", "replace")
    lines = [line for line in text.split("\n") if line]
    if not lines:
        return None
    if len(lines) != 1:
        _fail("remote", "ls-remote returned more than one ref")
    oid, _tab, ref = lines[0].partition("\t")
    if ref != tools.ANCHOR_REF or not tools.OID_RE.fullmatch(oid):
        _fail("remote", "ls-remote returned an unexpected ref line")
    return oid


def fetch(scratch: str, remote: str) -> str:
    """Fetch the anchor ref into refs/readback/anchor; returns the fetched
    commit id. Raises Unreachable when the fetch fails."""
    try:
        result = _git("git.fetch-anchor", scratch=scratch, remote=remote)
    except tools.ToolError as error:
        if error.code in ("timeout", "exec"):
            raise Unreachable(error.message) from error
        raise
    if result.returncode != 0:
        raise Unreachable(result.stderr.decode("utf-8", "replace").strip()[:300])
    path = os.path.join(scratch, *tools.READBACK_REF.split("/"))
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return _packed_ref(scratch)
    try:
        data = os.read(fd, 256)
    finally:
        os.close(fd)
    oid = data.decode("ascii", "replace").strip()
    if not tools.OID_RE.fullmatch(oid):
        _fail("remote", "fetched ref is malformed")
    return oid


def _packed_ref(scratch: str) -> str:
    try:
        fd = os.open(os.path.join(scratch, "packed-refs"), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise AnchorError("remote", "fetched ref is missing") from error
    try:
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    for line in data.decode("ascii", "replace").split("\n"):
        oid, _sp, ref = line.partition(" ")
        if ref == tools.READBACK_REF and tools.OID_RE.fullmatch(oid):
            return oid
    raise AnchorError("remote", "fetched ref is missing")


class ChainEntry:
    __slots__ = ("commit", "parent", "anchor_json", "active", "prev_generation", "sig")

    def __init__(self, commit: str, parent: str | None, anchor_json: bytes) -> None:
        self.commit = commit
        self.parent = parent
        self.anchor_json = anchor_json
        self.active, self.prev_generation, self.sig = pointer_fields(anchor_json)


def walk_chain(scratch: str, tip: str, limit: int = 100000) -> list[ChainEntry]:
    """Every commit from tip to the root, each verified by content, and the
    chain rules of A1.2 step 3: within a generation seq increases by one
    from the parent's with the same store; a generation change sets
    prev_generation to exactly its parent's active; the root commit is
    generation 1, seq 1. Returns entries tip first."""
    entries: list[ChainEntry] = []
    current: str | None = tip
    while current is not None:
        if len(entries) >= limit:
            _fail("anchor-chain", "anchor chain too long")
        data, parent = read_anchor_commit(scratch, current)
        entries.append(ChainEntry(current, parent, data))
        current = parent
    for index, entry in enumerate(entries):
        parent_entry = entries[index + 1] if index + 1 < len(entries) else None
        active = entry.active
        if parent_entry is None:
            if active["generation"] != 1 or active["seq"] != 1 or entry.prev_generation is not None:
                _fail("anchor-chain", "the first anchor commit must be generation 1, seq 1")
            if active["genesis_digest"] != active["record_digest"]:
                _fail("anchor-chain", "a seq-1 pointer names its own genesis digest")
            continue
        up = parent_entry.active
        if active["generation"] == up["generation"]:
            if (active["store_id"] != up["store_id"] or active["seq"] != up["seq"] + 1
                    or active["genesis_digest"] != up["genesis_digest"]
                    or entry.prev_generation is not None):
                _fail("anchor-chain", "within a generation seq must increase by one")
        elif active["generation"] == up["generation"] + 1:
            if (active["seq"] != 1 or active["store_id"] == up["store_id"]
                    or entry.prev_generation != records.prev_generation_of(up)
                    or active["genesis_digest"] != active["record_digest"]):
                _fail("anchor-chain", "a generation change must link to its parent's active")
        else:
            _fail("anchor-chain", "generation must stay or advance by one")
    return entries
