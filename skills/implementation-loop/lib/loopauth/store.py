"""The authority store: layout, the writer lock, transaction tokens, every
token-checked sink, the crash seam, and the write-protocol driver
(task-graph-v1 Phase A, sub-unit 0a.2, sections 2-3 and 6; A1.2, A1.5-A1.7,
A2.3-A2.4).

Layout, under $HOME/.config/olddonkey-loop/authority/ (0700; files 0600,
owned by the current uid, nlink 1, opened with O_NOFOLLOW):

  lock  active  genesis.intent  regenesis.intent
  stores/<store_id>/log/segment-000001.olf  keys/epoch-<n>-<16 hex>/...
                   intent  cursor  quarantine
  archive/<store_id>/   (moved here read-only: dirs 0500, files 0400)

Tokens. A token is created only by begin() (ceremony rows, from the
authenticated operator-TTY principal), begin_recovery() (the four recovery
rows) and begin_finish() (A2.4: completion or abandonment of a ceremony) --
each of which takes nothing but a plan object recover.observe() issued --
or child() (a compound transition's child row). Its binding is
append-only, in stages: keys and record (stage 1), frame (stage 2), anchor
(stage 3). Each sink requires the stage its input depends on and compares
its parameters with it. A sink never trusts a caller: it grants itself a
one-shot permit for exactly the low-level operation it is about to perform,
and the low-level helpers (and tools.run, through authorize_command) consume
that permit, so calling them directly -- even with a valid token -- is
refused.

Plan-only minting. No path accepts a caller-built binding: minting spends
the issued, unaltered plan (once), requires the local state it observed,
and observes the files and the remote afresh -- the fresh observation must
decide exactly the same row, parameters, and remote evidence -- and only
then derives the binding: the row, the observed local state (its snapshot
digest), the remote evidence (the tip commit, or that the remote was not
read, which only a quarantine decided from local files alone may carry),
and the row's exact sink parameters. Every destructive sink proves it
again from the files and the remote; a quarantine marker is written only
after one more fresh observation names its offending position and rule. A
finish token's targets (the active marker, the archive) are derived here
from the validated intent's bytes, never taken from a caller. Abandonment
deletes nothing: its only sink removes the intent, and the intent-named
directory stays, unpublished.

The revocation of an epoch binds that epoch's prior state as observed in
the store's own log, and the sequence and offset of its record; only when
that state was active may its quarantine child be opened, and it writes
exactly one marker, re-proved against the durable revocation record.

Every function that writes authority state is listed in SINK_FUNCTIONS; the
registry selftest proves by an AST scan that no other code in lib/loopauth
can write to the store, run a sink command, or spawn a process.
"""

from __future__ import annotations

import base64
import fcntl
import hashlib
import os
import re
import secrets
import stat
import sys
import time

from . import anchor, canonical, frame, keys, records, registry, tools

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_LOCK = 3
EXIT_REFUSED = 4
EXIT_PENDING = 5
EXIT_QUARANTINED = 6
EXIT_TERMINAL = 7
EXIT_DORMANT = 8
EXIT_ENV = 9
EXIT_CONSUME = 10
EXIT_TTY = 11
EXIT_INVALID = 12
EXIT_CRASH = 137

LOG_DIR = "log"
LOG_NAME = "segment-000001.olf"
ACTIVE = "active"
GENESIS_INTENT = "genesis.intent"
REGENESIS_INTENT = "regenesis.intent"
LOCK = "lock"
LOCK_TIMEOUT = 5.0
OWNER = os.getuid()

# The token-checked sink functions (section 3, "Sink ownership"). Frozen in
# registry-selftest.sh; nothing outside this list may write authority state.
SINK_FUNCTIONS = (
    "create_store_dir",
    "create_key_dir",
    "create_key",
    "certify_key",
    "seal",
    "seal_pointer",
    "write_intent",
    "write_genesis_intent",
    "write_regenesis_intent",
    "append_frame",
    "complete_delimiter",
    "truncate_frame",
    "remove_intent",
    "remove_genesis_intent",
    "remove_regenesis_intent",
    "write_cursor",
    "write_quarantine",
    "write_active",
    "archive_store",
    "push_anchor",
)


class AuthorityError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = EXIT_REFUSED,
                 evidence: object = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code
        self.evidence = evidence


def refuse(code: str, message: str, exit_code: int = EXIT_REFUSED) -> None:
    raise AuthorityError(code, message, exit_code)


def sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# Layout and safe reads
# ---------------------------------------------------------------------------

def root() -> str:
    return tools.authority_root()


def path(*parts: str) -> str:
    return os.path.join(root(), *parts)


def store_dir(store_id: str) -> str:
    if not records.STORE_ID_RE.fullmatch(store_id):
        refuse("layout", f"malformed store id: {store_id!r}")
    return path("stores", store_id)


def archive_dir(store_id: str) -> str:
    if not records.STORE_ID_RE.fullmatch(store_id):
        refuse("layout", f"malformed store id: {store_id!r}")
    return path("archive", store_id)


def log_path(directory: str) -> str:
    return os.path.join(directory, LOG_DIR, LOG_NAME)


def _check_chain(target: str) -> None:
    """No component from $HOME down to target may be a symlink."""
    base = tools.home()
    target = os.path.abspath(target)
    if not tools.under(target, base):
        refuse("layout", f"path outside HOME: {target}")
    current = base
    for part in [piece for piece in target[len(base):].split(os.sep) if piece]:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            refuse("layout", f"symlink in the authority path: {current}")


def _is_archived(target: str) -> bool:
    return tools.under(os.path.abspath(target), path("archive"))


def _check_file_info(info: os.stat_result, target: str, archived: bool) -> None:
    if not stat.S_ISREG(info.st_mode):
        refuse("layout", f"not a regular file: {target}")
    if info.st_uid != OWNER:
        refuse("layout", f"foreign-owned file: {target}")
    # An archived store is read-only (0400); between the archive move and its
    # read-only change (one sink, two durable cuts) it may still be 0600.
    wanted = (0o400, 0o600) if archived else (0o600,)
    if stat.S_IMODE(info.st_mode) not in wanted:
        refuse("layout", f"file mode must be {wanted[0]:04o}: {target}")
    if info.st_nlink != 1:
        refuse("layout", f"file has more than one link: {target}")


def check_dir(target: str, *, missing_ok: bool = False) -> bool:
    _check_chain(target)
    try:
        info = os.lstat(target)
    except FileNotFoundError:
        if missing_ok:
            return False
        refuse("layout", f"directory missing: {target}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        refuse("layout", f"not a real directory: {target}")
    if info.st_uid != OWNER:
        refuse("layout", f"foreign-owned directory: {target}")
    archived = _is_archived(target) and target != path("archive")
    wanted = (0o500, 0o700) if archived else (0o700,)
    if stat.S_IMODE(info.st_mode) not in wanted:
        refuse("layout", f"directory mode must be {wanted[0]:04o}: {target}")
    return True


def read_file(target: str, *, missing_ok: bool = False) -> bytes | None:
    _check_chain(target)
    archived = _is_archived(target)
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if missing_ok:
            return None
        refuse("layout", f"file missing: {target}")
    except OSError as error:
        refuse("layout", f"cannot open {target}: {error}")
    try:
        _check_file_info(os.fstat(fd), target, archived)
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def exists(target: str) -> bool:
    _check_chain(target)
    return os.path.lexists(target)


def list_dir(target: str) -> list[str]:
    check_dir(target)
    return sorted(os.listdir(target))


def _durable_fsync(fd: int) -> None:
    """Flush the device cache on Darwin before publishing durable state."""
    if sys.platform == "darwin":
        fcntl.fcntl(fd, getattr(fcntl, "F_FULLFSYNC", 51))
    else:
        os.fsync(fd)


def _fsync_dir(target: str) -> None:
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _durable_fsync(fd)
    finally:
        os.close(fd)


def ensure_layout() -> None:
    """Infrastructure, not a sink (A1.5 lists none of it): the authority
    directory, stores/, archive/, and the lock file."""
    base = tools.home()
    for relative in (".config", os.path.join(".config", "olddonkey-loop"),
                     os.path.join(".config", "olddonkey-loop", "authority"),
                     os.path.join(".config", "olddonkey-loop", "authority", "stores"),
                     os.path.join(".config", "olddonkey-loop", "authority", "archive")):
        target = os.path.join(base, relative)
        _check_chain(target)
        try:
            os.mkdir(target, 0o700)
        except FileExistsError:
            pass
        info = os.lstat(target)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != OWNER:
            refuse("layout", f"not an owned directory: {target}")
    for relative in ("", "stores", "archive"):
        check_dir(path(relative) if relative else root())
    lock = path(LOCK)
    try:
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    except FileExistsError:
        pass
    read_file(lock)


class WriterLock:
    """The writer's exclusive flock on authority/lock."""

    def __init__(self, timeout: float = LOCK_TIMEOUT) -> None:
        self.timeout = timeout
        self.fd = -1

    def __enter__(self) -> "WriterLock":
        ensure_layout()
        fd = os.open(path(LOCK), os.O_RDWR | os.O_NOFOLLOW)
        os.set_inheritable(fd, False)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(fd)
                    refuse("lock", "the authority writer lock is busy", EXIT_LOCK)
                time.sleep(0.05)
        self.fd = fd
        return self

    def __exit__(self, *exc: object) -> None:
        if self.fd >= 0:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
            self.fd = -1


class ReaderLock:
    """A shared flock for read-only commands; absent directory, absent lock,
    or a read-only tree simply proceed without it."""

    def __init__(self) -> None:
        self.fd = -1

    def __enter__(self) -> "ReaderLock":
        try:
            _check_chain(path(LOCK))
            fd = os.open(path(LOCK), os.O_RDONLY | os.O_NOFOLLOW)
        except (OSError, AuthorityError):
            return self
        deadline = time.monotonic() + LOCK_TIMEOUT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(fd)
                    refuse("lock", "the authority writer lock is busy", EXIT_LOCK)
                time.sleep(0.05)
        self.fd = fd
        return self

    def __exit__(self, *exc: object) -> None:
        if self.fd >= 0:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
            self.fd = -1


def snapshot_digest() -> str:
    """The digest of the observed local authority state: every entry under
    the authority directory except the lock (names, kinds, modes, sizes,
    content digests; a file this process cannot open by its name, mode, and
    size). Recovery and finish tokens bind it."""
    base = root()
    if not os.path.lexists(base):
        return canonical.digest({"absent": True})
    entries = []
    for current, dirs, files in os.walk(base, followlinks=False):
        dirs.sort()
        rel = os.path.relpath(current, base)
        info = os.lstat(current)
        entries.append([rel, "d", stat.S_IMODE(info.st_mode), 0, ""])
        for name in sorted(files):
            full = os.path.join(current, name)
            if full == os.path.join(base, LOCK):
                continue
            info = os.lstat(full)
            if stat.S_ISREG(info.st_mode):
                try:
                    fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW)
                except OSError:
                    entries.append([os.path.join(rel, name), "unreadable", stat.S_IMODE(info.st_mode),
                                    info.st_size, ""])
                    continue
                try:
                    digest = hashlib.sha256()
                    while True:
                        chunk = os.read(fd, 1 << 16)
                        if not chunk:
                            break
                        digest.update(chunk)
                finally:
                    os.close(fd)
                entries.append([os.path.join(rel, name), "f", stat.S_IMODE(info.st_mode),
                                info.st_size, digest.hexdigest()])
            else:
                entries.append([os.path.join(rel, name), "other", stat.S_IMODE(info.st_mode), 0, ""])
    return canonical.digest(entries)


# ---------------------------------------------------------------------------
# The crash seam (section 6)
# ---------------------------------------------------------------------------

KEY_STEPS = 2 + 3 * len(records.TYPES)
FRAME_POINTS = {"after-intent-fsync", "after-frame-fsync", "after-push", "after-readback",
                "after-intent-remove"}
CRASH_APPLICABLE = {
    "genesis": FRAME_POINTS | {"after-store-dir", "genesis-step-6a", "genesis-step-6b"}
    | {f"genesis-step-{n}" for n in range(1, 6)},
    "rotate": FRAME_POINTS | {"after-store-dir"},
    "revoke": set(FRAME_POINTS),
    "regenesis": {"after-frame-fsync", "after-push", "after-readback"}
    | {f"regenesis-step-{n}" for n in range(1, 6)},
    # recovery-after-delimiter: after the completed delimiter is durable and
    # before the replay-forward push.
    "recover": {"after-push", "after-readback", "after-intent-remove",
                "recovery-after-delimiter"},
}
PRIMITIVE_POINTS = {"fs-create-after-temp-fsync", "fs-create-after-rename",
                    "fs-replace-after-temp-fsync", "fs-replace-after-rename"}
for _command in CRASH_APPLICABLE:
    CRASH_APPLICABLE[_command] |= PRIMITIVE_POINTS
INTENT_POINTS = {"fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename"}
MARKER_POINTS = {"fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename"}
for _command in ("genesis", "rotate", "revoke", "regenesis"):
    CRASH_APPLICABLE[_command] |= INTENT_POINTS
for _command in ("revoke", "recover"):
    CRASH_APPLICABLE[_command] |= MARKER_POINTS
for _command in ("regenesis", "recover"):
    CRASH_APPLICABLE[_command] |= {"archive-after-rename", "archive-after-readonly"}
KEY_STEP_COMMANDS = ("genesis", "rotate")
FRAME_BYTE_COMMANDS = ("genesis", "rotate", "revoke", "regenesis")
_CRASH: dict[str, object] = {"point": None, "frame_byte": None}


def configure_crash(command: str) -> None:
    """Validate LOOP_AUTHORITY_CRASH_AT for this command. Honoured only with
    LOOP_AUTHORITY_TEST=1; an unknown or inapplicable point refuses."""
    _CRASH["point"] = None
    _CRASH["frame_byte"] = None
    raw = os.environ.get("LOOP_AUTHORITY_CRASH_AT")
    if raw is None or not tools.test_mode():
        return
    match = re.fullmatch(r"key-step-([1-9][0-9]{0,3})", raw)
    if match:
        if command not in KEY_STEP_COMMANDS or int(match.group(1)) > KEY_STEPS:
            refuse("crash-point", f"key step beyond this ceremony's {KEY_STEPS} key steps: {raw}")
        _CRASH["point"] = raw
        return
    match = re.fullmatch(r"frame-byte-([1-9][0-9]{0,7})", raw)
    if match:
        if command not in FRAME_BYTE_COMMANDS:
            refuse("crash-point", f"{command} writes no frame: {raw}")
        _CRASH["point"] = raw
        _CRASH["frame_byte"] = int(match.group(1))
        return
    if raw not in CRASH_APPLICABLE.get(command, set()):
        refuse("crash-point", f"unknown crash point for {command}: {raw!r}")
    _CRASH["point"] = raw


def crash(point: str) -> None:
    if _CRASH["point"] == point:
        os._exit(EXIT_CRASH)


def check_frame_byte(frame_length: int) -> None:
    """A frame-byte-<n> must fall strictly inside the frame being written."""
    n = _CRASH["frame_byte"]
    if n is not None and not 1 <= n < frame_length:  # type: ignore[operator]
        refuse("crash-point", f"frame-byte-{n} is not strictly inside a {frame_length}-byte frame")


# ---------------------------------------------------------------------------
# Tokens (A1.5, A2.4)
# ---------------------------------------------------------------------------

class Token:
    __slots__ = ("id", "row", "kind", "action", "source_digest", "parent", "state", "stages",
                 "trail", "permit", "flags", "children", "scratch", "facts")

    def __init__(self, row: str, kind: str, source_digest: str, parent: "Token | None" = None,
                 action: str | None = None) -> None:
        self.id = secrets.token_hex(16)
        self.row = row
        self.kind = kind
        self.action = action
        self.source_digest = source_digest
        self.parent = parent
        self.state = "open"
        self.stages: dict[str, dict] = {} if parent is None else parent.stages
        self.trail: list[str] = []
        self.permit: tuple | None = None
        self.flags: set[str] = set() if parent is None else parent.flags
        self.children: list[Token] = []
        self.scratch: str | None = None
        self.facts: dict = {}

    def __repr__(self) -> str:
        return f"<Token {self.row} {self.kind} {self.state}>"


_OPEN: dict[str, Token] = {}


def token_is_open(token: object) -> bool:
    return (type(token) is Token and token.state == "open"  # type: ignore[union-attr]
            and _OPEN.get(token.id) is token)  # type: ignore[union-attr]


def _new(token: Token) -> Token:
    _OPEN[token.id] = token
    return token


def begin(row: str, source: object) -> Token:
    """A token for an external (ceremony) row, from its authenticated
    principal. Not exported: ceremony.py is its only caller."""
    spec = registry.admit(row)
    if spec["entry"] != "ceremony":
        refuse("exclusion-X7", f"{row} has no external entry point")
    try:
        records.check_principal(source)
    except records.RecordError as error:
        refuse("exclusion-X6", f"{row} needs an operator-TTY principal: {error.message}")
    registry.check_exclusions(row, source)  # type: ignore[arg-type]
    return _new(Token(row, "ceremony", canonical.digest(source)))


# --- recovery and finish bindings --------------------------------------------
# The keys each row's binding must carry besides row, table, local, remote.
RECOVERY_BINDING_KEYS = {
    "torn-frame-truncation": ("store_id", "offset", "intent_digest", "tail_digest"),
    "anchor-replay-forward": ("store_id", "intent", "intent_digest", "unterminated",
                              "anchor_commit", "expected_parent"),
    "recovery-tidy": ("store_id", "intent_digest", "cursor_digest"),
    "store-quarantine": ("store_id", "rule", "position", "marker_digest"),
}
FINISH_BINDING_KEYS = ("intent_digest",)
# The only row whose predicate may be decided without reading the remote: a
# quarantine that local files alone establish (A1.6, A1.7, a bad intent).
LOCAL_ONLY_ROWS = ("store-quarantine",)


def _plan_refused(message: str) -> None:
    refuse("recovery-plan", message)


def _redeem(plan: object, *, finish: bool) -> dict:
    """The binding of a plan recover.observe() issued, unaltered and
    unspent (it is spent here, whatever follows), whose local state is the
    current one and whose row a fresh observation of the files and the
    remote decides again. recover owns the classifier; it is imported here,
    at call time, because it imports this module."""
    from . import recover
    return recover.redeem(plan, finish=finish)


def _reobserve() -> object:
    from . import recover
    return recover.reobserve()


def _binding_shape(binding: object, keys: tuple, row: str) -> dict:
    if type(binding) is not dict or binding.get("row") != row:
        _plan_refused(f"{row}: the binding does not name this row")
    assert type(binding) is dict
    wanted = {"row", "table", "local", "remote"} | set(keys)
    if binding.get("action") is not None:
        wanted.add("action")
    if set(binding) != wanted:
        _plan_refused(f"{row}: binding fields {sorted(binding)} are not {sorted(wanted)}")
    remote = binding["remote"]
    if type(remote) is not dict or set(remote) != {"read", "tip"} \
            or type(remote["read"]) is not bool \
            or (remote["tip"] is not None and not tools.OID_RE.fullmatch(str(remote["tip"]))) \
            or (not remote["read"] and remote["tip"] is not None):
        _plan_refused(f"{row}: malformed remote evidence")
    return binding


def _read_bound_json(target: str, digest: object, what: str) -> dict:
    """The file's bytes must be exactly the ones the plan validated."""
    data = read_file(target, missing_ok=True)
    if data is None or sha256(data) != digest:
        _plan_refused(f"{what} is not the one the plan validated")
    try:
        value = canonical.loads(data.decode("utf-8"))  # type: ignore[union-attr]
    except (UnicodeDecodeError, canonical.CanonicalError) as error:
        raise AuthorityError("recovery-plan", f"{what} is unreadable") from error
    if type(value) is not dict:
        _plan_refused(f"{what} is malformed")
    return value  # type: ignore[return-value]


def _intent_frame(intent: dict) -> tuple[bytes, int]:
    try:
        frame_bytes = base64.b64decode(str(intent.get("frame_b64")), validate=True)
    except (ValueError, TypeError) as error:
        raise AuthorityError("recovery-plan", "the intent's frame bytes are unreadable") from error
    offset = intent.get("offset")
    if not frame_bytes.endswith(b"\n") or type(offset) is not int or offset < 0:
        _plan_refused("the intent's frame or offset is malformed")
    return frame_bytes, offset  # type: ignore[return-value]


def _log_bytes(store_id: str) -> bytes | None:
    """The store's log, or None when its directory does not exist."""
    directory = store_dir(store_id)
    if not check_dir(directory, missing_ok=True):
        return None
    return read_file(log_path(directory), missing_ok=True)


def _remote_now(token: Token) -> str | None:
    remote = tools.pinned_remote()
    if remote is None:
        refuse("remote", "no pinned remote")
    if token.scratch is None:
        token.scratch = tools.new_scratch_repo()
    try:
        return anchor.ls_remote(token.scratch, remote.url)  # type: ignore[union-attr]
    except anchor.Unreachable as error:
        raise AuthorityError("pending", f"remote unreachable: {error}", EXIT_PENDING) from error


def _check_remote(token: Token, evidence: dict) -> None:
    """The remote still shows exactly the commit the plan verified by
    content (a commit id names its content), or the absent ref it saw."""
    if evidence["read"] and _remote_now(token) != evidence["tip"]:
        refuse("remote-state", f"{token.row}: the remote anchor is not the one the plan verified")


def _recovery_facts(token: Token, sink: str | None) -> None:
    """Re-prove, from the files themselves, that the bound row applies to
    the current state for this sink (sink None: at minting). Remote evidence
    is re-proved by every destructive sink."""
    bound = token.stages["recovery"]
    row = token.row
    store_id = bound["store_id"]
    if type(store_id) is not str or not records.STORE_ID_RE.fullmatch(store_id):
        _plan_refused(f"{row}: malformed store id")
    facts: dict = {}
    if row == "torn-frame-truncation":
        intent = _read_bound_json(os.path.join(store_dir(store_id), "intent"),
                                  bound["intent_digest"], "the write intent")
        frame_bytes, offset = _intent_frame(intent)
        data = _log_bytes(store_id) or b""
        tail = data[offset:]
        if offset != bound["offset"] or len(data) <= offset \
                or not (len(tail) < len(frame_bytes) - 1 and frame_bytes.startswith(tail)) \
                or sha256(tail) != bound["tail_digest"]:
            _plan_refused("truncation: the log does not end with the torn frame the plan observed")
        facts = {"offset": offset}
    elif row == "anchor-replay-forward":
        kind = bound["intent"]
        if kind == "genesis":
            intent = _read_bound_json(path(GENESIS_INTENT), bound["intent_digest"],
                                      "genesis.intent")
            if intent.get("store_id") != store_id or exists(path(ACTIVE)):
                _plan_refused("bootstrap replay: the intent names another store, or active exists")
        elif kind == "store":
            intent = _read_bound_json(os.path.join(store_dir(store_id), "intent"),
                                      bound["intent_digest"], "the write intent")
        else:
            _plan_refused(f"replay: unknown intent kind {kind!r}")
        if intent.get("anchor_commit") != bound["anchor_commit"] \
                or intent.get("expected_parent") != bound["expected_parent"]:
            _plan_refused("replay: the commit or parent is not the intent's")
        frame_bytes, offset = _intent_frame(intent)
        data = _log_bytes(store_id)
        after = data[offset:] if data is not None and len(data) >= offset else None
        complete = after == frame_bytes
        unterminated = after == frame_bytes[:-1]
        if sink in (None, "delimiter-completion") and bound["unterminated"] \
                and "delimiter" not in token.flags:
            if not unterminated:
                _plan_refused("replay: the log does not end with the intent's unterminated frame")
        elif not complete:
            _plan_refused("replay: the log does not end with the intent's complete frame")
        facts = {"frame": frame_bytes, "offset": offset}
    elif row == "recovery-tidy":
        if bound["intent_digest"] is not None and sink in (None, "intent-remove"):
            intent = _read_bound_json(os.path.join(store_dir(store_id), "intent"),
                                      bound["intent_digest"], "the write intent")
            frame_bytes, offset = _intent_frame(intent)
            data = _log_bytes(store_id) or b""
            if not (data[offset:] == frame_bytes or offset == len(data)):
                _plan_refused("tidy: the intent is neither exactly frame L nor a clean L + 1")
    elif row == "store-quarantine":
        if not check_dir(store_dir(store_id), missing_ok=True):
            _plan_refused("quarantine: the store directory does not exist")
        if exists(os.path.join(store_dir(store_id), "quarantine")):
            refuse("exists", "the store is already quarantined")
        if sink is not None:
            # The marker is written only if a fresh observation of the files
            # and the remote -- not the binding -- names this store's
            # offending position and the A1.2 / A1.6 / A1.7 / A2.3 rule it
            # failed.
            fresh = _reobserve()
            params = fresh.params  # type: ignore[attr-defined]
            if fresh.row != "store-quarantine" or params.get("store_id") != store_id \
                    or params.get("rule") != bound["rule"] \
                    or params.get("position") != bound["position"]:
                _plan_refused("quarantine: a fresh observation does not name this offending "
                              "position and rule")
    token.facts = facts


def begin_recovery(plan: object) -> Token:
    """A token for one of the four recovery rows, from nothing but a plan
    recover.observe() issued (spent here, once): the binding -- the row,
    the observed state, the remote evidence, and the exact sink parameters
    -- is derived after a fresh observation decided the same plan, and
    re-proved against the files and the remote, so a plan that does not
    describe this state -- a truncation or a quarantine on a committed
    store -- mints nothing."""
    binding = _redeem(plan, finish=False)
    row = binding.get("row")
    if row not in RECOVERY_BINDING_KEYS:
        _plan_refused(f"{row!r} is not a recovery row")
    spec = registry.admit(row)
    if spec["entry"] != "recovery":
        refuse("exclusion-X7", f"{row} is not a recovery row")
    registry.check_exclusions(row, {"kind": "recovery"})
    binding = _binding_shape(binding, RECOVERY_BINDING_KEYS[row], row)
    if not binding["remote"]["read"] and row not in LOCAL_ONLY_ROWS:
        _plan_refused(f"{row}: its predicate needs the remote, and the plan did not read it")
    if binding.get("local") != snapshot_digest():
        refuse("recovery-state", f"{row}: the observed state is not the current state")
    token = Token(row, "recovery", canonical.digest(binding))
    token.stages["recovery"] = dict(binding)
    token.trail.append(binding["local"])
    try:
        _recovery_facts(token, None)
        _check_remote(token, binding["remote"])
    except BaseException:
        spend(token)
        raise
    return _new(token)


def _finish_targets(row: str, intent: dict) -> dict:
    """What an A2.4 token may touch, derived from the validated intent."""
    def store_id(value: object) -> str:
        if type(value) is not str or not records.STORE_ID_RE.fullmatch(value):
            _plan_refused("the ceremony intent names a malformed store")
        return value  # type: ignore[return-value]

    if row == "authority-genesis":
        new_id = store_id(intent.get("store_id"))
        return {"new_store": new_id, "active_target": {"store_id": new_id, "generation": 1},
                "archive_store": None, "old_target": None}
    old = intent.get("old")
    if type(old) is not dict or type(old.get("generation")) is not int or old["generation"] < 1:
        _plan_refused("the re-genesis intent names a malformed old generation")
    old_id = store_id(old.get("store_id"))
    new_id = store_id(intent.get("new_store_id"))
    return {"new_store": new_id,
            "active_target": {"store_id": new_id, "generation": old["generation"] + 1},
            "archive_store": old_id,
            "old_target": {"store_id": old_id, "generation": old["generation"]}}


def _finish_facts(token: Token) -> None:
    """A2.4's exact states, re-proved at minting and at every sink:
    completion only with the intent's exact new commit on the remote and
    its frame durable and complete; abandonment only on the pre-ceremony
    state (genesis: ref absent, active absent, the intent-named directory
    present with frame 1 none or torn; re-genesis: the recorded
    old-generation commit, the old store active and not archived, the new
    directory present). A missing intent-named directory is never
    abandoned: nothing proves the loop itself never published it."""
    finish = token.stages["finish"]
    bound = finish["binding"]
    targets = finish["targets"]
    intent = _read_bound_json(finish["intent_path"], bound["intent_digest"], "the ceremony intent")
    frame_bytes, _offset = _intent_frame(intent)
    tip = bound["remote"]["tip"]
    active = read_file(path(ACTIVE), missing_ok=True)
    new_log = _log_bytes(targets["new_store"])
    if token.row == "authority-genesis":
        if token.action == "complete":
            if tip is None or tip != intent.get("anchor_commit") or new_log != frame_bytes \
                    or active not in (None, canonical.canonical(targets["active_target"])):
                _plan_refused("genesis completion needs the intent's commit, a valid frame 1, "
                              "and active absent or exact")
        elif tip is not None or active is not None or new_log is None or not (
                new_log == b""
                or (len(new_log) < len(frame_bytes) - 1 and frame_bytes.startswith(new_log))):
            _plan_refused("genesis abandonment needs an absent ref, no active marker, and the "
                          "intent-named directory with frame 1 none or torn")
    else:
        old_target = canonical.canonical(targets["old_target"])
        old_live = check_dir(store_dir(targets["archive_store"]), missing_ok=True)
        if token.action == "complete":
            if tip is None or tip != intent.get("anchor_commit") or new_log != frame_bytes \
                    or active not in (old_target, canonical.canonical(targets["active_target"])) \
                    or not (old_live or check_dir(archive_dir(targets["archive_store"]),
                                                  missing_ok=True)):
                _plan_refused("re-genesis completion needs the intent's commit, its frame, and "
                              "the old or new store active")
        elif tip is None or tip != intent.get("old_commit") or active != old_target \
                or not old_live or new_log is None:
            _plan_refused("re-genesis abandonment needs the recorded old-generation commit, "
                          "the old store active, not archived, and the new directory present")
    _check_remote(token, bound["remote"])


def begin_finish(plan: object) -> Token:
    """A2.4: a token to complete or abandon a ceremony whose intent recovery
    validated, from nothing but a plan recover.observe() issued (spent
    here, once) and a fresh observation deciding it again. The binding names
    the observed state, the content-verified remote tip, and the digest of
    the intent's bytes; what the sinks may touch is derived here from those
    bytes."""
    binding = _redeem(plan, finish=True)
    row, action = binding.get("row"), binding.get("action")
    spec = registry.admit(row)  # type: ignore[arg-type]
    if row not in ("authority-genesis", "linked-regenesis") or spec["entry"] != "ceremony":
        refuse("finish", f"{row} has no ceremony to finish")
    if action not in ("complete", "abandon"):
        refuse("finish", f"unknown finish action {action!r}")
    binding = _binding_shape(binding, FINISH_BINDING_KEYS, row)  # type: ignore[arg-type]
    if binding.get("action") != action or not binding["remote"]["read"]:
        _plan_refused(f"{row}: the binding is not for {action} on a remote the plan read")
    if binding.get("local") != snapshot_digest():
        refuse("recovery-state", f"{row}: the observed state is not the current state")
    intent_path = path(GENESIS_INTENT if row == "authority-genesis" else REGENESIS_INTENT)
    intent = _read_bound_json(intent_path, binding["intent_digest"], "the ceremony intent")
    token = Token(row, "finish", canonical.digest(binding), action=action)
    token.stages["finish"] = {"binding": dict(binding), "targets": _finish_targets(row, intent),
                              "intent_path": intent_path}
    token.trail.append(binding["local"])
    try:
        _finish_facts(token)
    except BaseException:
        spend(token)
        raise
    return _new(token)


def child(parent: Token, row: str) -> Token:
    """A compound transition's parent token authorizes exactly the child rows
    its transition names."""
    if not token_is_open(parent):
        refuse("token", "parent token is not open")
    spec = registry.admit(row)
    if row not in registry.ROW_BY_ID[parent.row]["children"]:
        refuse("compound", f"{parent.row} does not name {row} in its compound transition")
    if not registry.compound_entry(spec["id"]):
        refuse("compound", f"{row} is not a compound child row")
    registry.check_exclusions(row, {"kind": "compound-parent"})
    if row == "store-quarantine":
        _active_revocation(parent)
    token = _new(Token(row, "child", parent.source_digest, parent=parent))
    parent.children.append(token)
    return token


def _active_revocation(parent: Token) -> dict:
    """The revocation's quarantine child exists only when the parent bound
    the revocation of the epoch that was active (and seals the record)."""
    bound = parent.stages.get("revocation") if parent.row == "epoch-revocation" else None
    if bound is None or bound["prior_state"] != "active" or bound["epoch"] != bound["active_epoch"]:
        refuse("compound", "the quarantine child follows only the revocation of the active epoch")
    return bound  # type: ignore[return-value]


def active_revocation_marker(store_id: str, seq: int) -> bytes:
    """The one marker the revocation of the active epoch writes."""
    return quarantine_bytes(store_id, "active-epoch-revoked", {"seq": seq},
                            "the active epoch was revoked")


def bind_revocation(token: Token, *, store_id: str, generation: int, epoch: int,
                    prior_state: str) -> None:
    """Before the revocation record is bound: the revoked epoch's prior
    state, the active epoch, and the record's sequence and offset, observed
    here in the store's own verified log -- the caller's prior_state must
    be that observation. Bound once; a second attempt spends the token."""
    if not token_is_open(token) or token.kind != "ceremony" or token.row != "epoch-revocation":
        refuse("token", "only an open epoch-revocation token binds a revocation")
    if "revocation" in token.stages or "record" in token.stages:
        spend(token)
        refuse("rebind", "the revocation is bound once, before its record; the token is spent")
    from . import recover
    try:
        view = recover.load_view(store_id, generation)
    except recover.Invalid as error:
        raise AuthorityError("revoke-refused", f"the store does not load: {error.detail}") from error
    target = view.epochs.get(epoch)  # type: ignore[call-overload]
    if view.error is not None or view.tail or target is None or view.active_epoch is None:
        refuse("revoke-refused", "the store's log does not verify to an active epoch")
    observed = target.state  # type: ignore[union-attr]
    if observed not in ("active", "verify-only") or prior_state != observed:
        refuse("revoke-refused", f"epoch {epoch} is {observed} in the store's log, not {prior_state}")
    token.stages["revocation"] = {"store_id": store_id, "generation": generation, "epoch": epoch,
                                  "prior_state": observed, "active_epoch": view.active_epoch,
                                  "seq": view.L + 1, "offset": len(view.data)}


def _check_revocation_payload(token: Token, payload: bytes) -> None:
    """seal() of an epoch.revoked record: exactly the bound revocation."""
    bound = token.stages.get("revocation")
    try:
        value = canonical.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, canonical.CanonicalError) as error:
        raise AuthorityError("stage-mismatch", "seal: the revocation payload is unreadable") from error
    body = value.get("body") if type(value) is dict else None
    if bound is None or type(body) is not dict or value.get("store_id") != bound["store_id"] \
            or value.get("generation") != bound["generation"] or value.get("seq") != bound["seq"] \
            or value.get("epoch") != bound["active_epoch"] or body.get("epoch") != bound["epoch"] \
            or body.get("prior_state") != bound["prior_state"]:
        refuse("stage-mismatch", "seal: the revocation payload is not the bound revocation")


def spend(token: Token) -> None:
    for item in token.children:
        spend(item)
    token.state = "spent"
    token.permit = None
    _OPEN.pop(token.id, None)
    if token.scratch is not None:
        tools.remove_scratch_repo(token.scratch)
        token.scratch = None


def _bind(token: Token, stage: str, values: dict) -> None:
    if not token_is_open(token) or token.kind not in ("ceremony",):
        refuse("token", f"stage {stage} can be bound only on an open ceremony token")
    if stage in token.stages:
        # A binding is never replaced, and an attempt to replace one ends the
        # transaction: every later sink call with this token refuses.
        spend(token)
        refuse("rebind", f"stage {stage} is already bound; the token is spent")
    order = ("keys", "record", "frame", "anchor")
    for earlier in order[:order.index(stage)]:
        if earlier == "keys" and not registry.ROW_BY_ID[token.row]["keys"]:
            continue
        if earlier not in token.stages:
            refuse("stage-order", f"stage {stage} before stage {earlier}")
    token.stages[stage] = dict(values)


def bind_keys(token: Token, *, store_id: str, epoch: int, key_dir: str,
              active_target: dict | None, intent_path: str | None) -> None:
    """Stage 1 for key rows: bound before any key sink runs."""
    if not registry.ROW_BY_ID[token.row]["keys"]:
        refuse("stage", f"{token.row} creates no keys")
    if not records.KEY_DIR_RE.fullmatch(key_dir) or int(
            records.KEY_DIR_RE.fullmatch(key_dir).group(1)) != epoch:  # type: ignore[union-attr]
        refuse("stage", "key_dir must be epoch-<epoch>-<16 hex>")
    _bind(token, "keys", {"store_id": store_id, "epoch": epoch, "types": records.TYPES,
                          "key_dir": key_dir, "active_target": active_target,
                          "intent_path": intent_path})


def bind_record(token: Token, *, store_id: str, record_type: str, payload_digest: str,
                key_id: str, signing_key_dir: str, pointer_key_dir: str) -> None:
    """Stage 1 for the record: type, payload digest, and signing key_id. A
    revocation binds its observed epoch state first (bind_revocation)."""
    if record_type != registry.ROW_BY_ID[token.row]["record_type"]:
        refuse("stage", f"{token.row} does not seal {record_type}")
    if token.row == "epoch-revocation" and "revocation" not in token.stages:
        refuse("stage-order", "the revocation's observed epoch state is bound before its record")
    _bind(token, "record", {"store_id": store_id, "type": record_type,
                            "payload_digest": payload_digest, "key_id": key_id,
                            "signing_key_dir": signing_key_dir,
                            "pointer_key_dir": pointer_key_dir})


def bind_frame(token: Token, *, frame_digest: str, record_digest: str,
               pointer_digest: str) -> None:
    """Stage 2, after store.seal returned."""
    _bind(token, "frame", {"frame_digest": frame_digest, "record_digest": record_digest,
                           "pointer_digest": pointer_digest})


def bind_anchor(token: Token, *, anchor_json_digest: str, anchor_commit: str, ref: str,
                intent_digest: str, expected_parent: str | None, offset: int) -> None:
    """Stage 3, after store.seal_pointer returned and the commit was built."""
    _bind(token, "anchor", {"anchor_json_digest": anchor_json_digest,
                            "anchor_commit": anchor_commit, "ref": ref,
                            "intent_digest": intent_digest,
                            "expected_parent": expected_parent, "offset": offset})


def _root_token(token: Token) -> Token:
    return token.parent if token.parent is not None else token


def _require(token: object, sink: str, *, stage: str | None = None,
             flags: tuple = ()) -> Token:
    if not token_is_open(token):
        refuse("token", f"{sink}: no open token")
    assert type(token) is Token
    spec = registry.ROW_BY_ID[token.row]
    if sink not in spec["sinks"]:
        refuse("token-row", f"{sink}: row {token.row} may not use this sink")
    if token.kind == "finish":
        allowed = FINISH_SINKS[token.action]  # type: ignore[index]
        if sink not in allowed:
            refuse("token-row", f"{sink}: a ceremony {token.action} token may not use it")
    elif token.kind in ("recovery",):
        pass
    else:
        if stage is not None and stage not in token.stages:
            refuse("stage-unbound", f"{sink}: stage {stage} is not bound")
        for flag in flags:
            if flag not in token.flags:
                refuse("protocol-order", f"{sink}: requires {flag} first")
    if token.kind in ("recovery", "finish"):
        if snapshot_digest() != token.trail[-1]:
            refuse("recovery-state", f"{sink}: the current state is not the one the token bound")
    if token.kind == "finish":
        _finish_facts(token)
    elif token.kind == "recovery":
        _recovery_facts(token, sink)
        if sink in DESTRUCTIVE_RECOVERY_SINKS:
            _check_remote(token, token.stages["recovery"]["remote"])
    return token


FINISH_SINKS = {
    "complete": ("active-marker", "archive-move", "genesis-intent-remove",
                 "regenesis-intent-remove"),
    # Abandonment deletes nothing: the intent-named directory stays, never
    # named by active or an intent again, and is reported as unpublished.
    "abandon": ("genesis-intent-remove", "regenesis-intent-remove"),
}
# The recovery sinks that re-prove the remote before acting (the anchor push
# proves it itself: it pushes only onto the bound parent).
DESTRUCTIVE_RECOVERY_SINKS = ("truncation", "delimiter-completion", "intent-remove",
                              "quarantine-marker")


def _after(token: Token) -> None:
    if token.kind in ("recovery", "finish"):
        token.trail.append(snapshot_digest())


def _grant(token: Token, *permit: object) -> None:
    token.permit = permit


def _consume(token: object, *permit: object) -> None:
    if not token_is_open(token) or token.permit != permit:  # type: ignore[union-attr]
        refuse("permit", "low-level sink called without its sink's permit")
    token.permit = None  # type: ignore[union-attr]


def authorize_command(token: object, command_id: str, params: dict, stdin: bytes) -> None:
    """tools.run's check for a sink entry: only the permit a store.py sink
    granted for exactly this command, parameters, and stdin."""
    frozen = canonical.canonical({key: params[key] for key in sorted(params)})
    _consume(token, "cmd", command_id, frozen, sha256(stdin))


def _run_sink(token: Token, command_id: str, stdin: bytes = b"", **params: object) -> tools.Result:
    frozen = canonical.canonical({key: params[key] for key in sorted(params)})
    _grant(token, "cmd", command_id, frozen, sha256(stdin))
    try:
        return tools.run(command_id, token=token, stdin=stdin, **params)
    finally:
        token.permit = None


# ---------------------------------------------------------------------------
# Low-level writes: each consumes its sink's permit
# ---------------------------------------------------------------------------

def _write_all(fd: int, data: bytes, target: str) -> None:
    """Write every byte or fail: a short write never leaves a caller
    believing the file is complete."""
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            refuse("short-write", f"could not write all of {target}", EXIT_ENV)
        view = view[written:]


def _fs_mkdir(token: Token, target: str) -> None:
    _consume(token, "mkdir", target)
    _check_chain(target)
    os.mkdir(target, 0o700)
    _fsync_dir(os.path.dirname(target))


def _fs_create(token: Token, target: str, data: bytes) -> None:
    """Publish a fsynced temp by rename under the exclusive writer lock."""
    _consume(token, "create", target, sha256(data))
    _check_chain(target)
    directory = os.path.dirname(target)
    temporary = os.path.join(directory, f".tmp-{secrets.token_hex(8)}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        _write_all(fd, data, target)
        _durable_fsync(fd)
    except BaseException:
        os.close(fd)
        os.unlink(temporary)
        raise
    os.close(fd)
    crash("fs-create-after-temp-fsync")
    leaf = os.path.basename(target)
    kind = "intent" if leaf in ("intent", "genesis.intent", "regenesis.intent") else (
        "marker" if leaf == "quarantine" else None)
    if kind is not None:
        crash(f"fs-create-{kind}-after-temp-fsync")
    if os.path.lexists(target):
        os.unlink(temporary)
        refuse("exists", f"refusing to replace {target}")
    os.rename(temporary, target)
    crash("fs-create-after-rename")
    if kind is not None:
        crash(f"fs-create-{kind}-after-rename")
    _fsync_dir(directory)


def _fs_replace(token: Token, target: str, data: bytes) -> None:
    """Atomic replacement: the whole of data is written and fsynced to a
    temporary before it replaces target; a write that cannot finish fails
    before the replacement, leaving target as it was."""
    _consume(token, "replace", target, sha256(data))
    _check_chain(target)
    directory = os.path.dirname(target)
    temporary = os.path.join(directory, f".tmp-{secrets.token_hex(8)}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        _write_all(fd, data, target)
        _durable_fsync(fd)
    except BaseException:
        os.close(fd)
        os.unlink(temporary)
        raise
    os.close(fd)
    crash("fs-replace-after-temp-fsync")
    os.replace(temporary, target)
    crash("fs-replace-after-rename")
    _fsync_dir(directory)


def _fs_append(token: Token, target: str, offset: int, data: bytes) -> None:
    """Append data at exactly offset (the current end). frame-byte-<n>
    crashes after the first n bytes are written."""
    _consume(token, "append", target, offset, sha256(data))
    _check_chain(target)
    fd = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        _check_file_info(info, target, False)
        if info.st_size != offset:
            refuse("offset", f"log ends at {info.st_size}, not at the intent's offset {offset}")
        n = _CRASH["frame_byte"]
        if n is not None and len(data) > 1 and 1 <= n < len(data):  # type: ignore[operator]
            _write_all(fd, data[:n], target)  # type: ignore[index]
            crash(f"frame-byte-{n}")
            _write_all(fd, data[n:], target)  # type: ignore[index]
        else:
            _write_all(fd, data, target)
        _durable_fsync(fd)
    finally:
        os.close(fd)


def _fs_truncate(token: Token, target: str, size: int) -> None:
    _consume(token, "truncate", target, size)
    _check_chain(target)
    fd = os.open(target, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        _check_file_info(os.fstat(fd), target, False)
        os.ftruncate(fd, size)
        _durable_fsync(fd)
    finally:
        os.close(fd)


def _fs_unlink(token: Token, target: str) -> None:
    _consume(token, "unlink", target)
    _check_chain(target)
    os.unlink(target)
    _fsync_dir(os.path.dirname(target))


def _fs_rename_dir(token: Token, source: str, target: str) -> None:
    _consume(token, "rename", source, target)
    _check_chain(source)
    _check_chain(target)
    if os.path.lexists(target):
        refuse("exists", f"refusing to replace {target}")
    os.rename(source, target)
    _fsync_dir(os.path.dirname(source))
    _fsync_dir(os.path.dirname(target))


def _fs_read_only_tree(token: Token, target: str) -> None:
    _consume(token, "read-only", target)
    _check_chain(target)
    for current, dirs, files in os.walk(target, topdown=False, followlinks=False):
        for name in files:
            full = os.path.join(current, name)
            if os.path.islink(full):
                refuse("layout", f"symlink in archived store: {full}")
            os.chmod(full, 0o400, follow_symlinks=False)
        for name in dirs:
            full = os.path.join(current, name)
            os.chmod(full, 0o500, follow_symlinks=False)
    os.chmod(target, 0o500, follow_symlinks=False)
    _fsync_dir(os.path.dirname(target))


def _fs_link_published(token: Token, temporary: str, target: str) -> None:
    """Publish a key file without replacement: fsync the temp, link it to
    its final name (fails if it exists), dir fsync; the caller then unlinks
    the temp."""
    _consume(token, "link", temporary, target)
    fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != OWNER:
            refuse("layout", f"temporary key file refused: {temporary}")
        _durable_fsync(fd)
    finally:
        os.close(fd)
    os.chmod(temporary, 0o600, follow_symlinks=False)
    try:
        os.link(temporary, target, follow_symlinks=False)
    except FileExistsError:
        refuse("exists", f"refusing to replace published key file {target}")
    _fsync_dir(os.path.dirname(target))


def _fs_unlink_temp(token: Token, temporary: str) -> None:
    _consume(token, "unlink-temp", temporary)
    if not os.path.basename(temporary).startswith(".tmp-"):
        refuse("layout", "only temporary key files are unlinked here")
    os.unlink(temporary)
    _fsync_dir(os.path.dirname(temporary))


# ---------------------------------------------------------------------------
# Sinks
# ---------------------------------------------------------------------------

def _keys_stage(token: Token) -> dict:
    return _root_token(token).stages["keys"]


def create_store_dir(token: object, *, store_id: str, key_dir: str) -> None:
    """New store directory creation (genesis, linked re-genesis): stores/<id>/
    with log/ and an empty segment, keys/, and the bound key directory."""
    token = _require(token, "store-dir-create", stage="keys")
    bound = _keys_stage(token)
    if store_id != bound["store_id"] or key_dir != bound["key_dir"]:
        refuse("stage-mismatch", "store-dir-create: store or key_dir differs from stage 1")
    base = store_dir(store_id)
    for target in (base, os.path.join(base, LOG_DIR), os.path.join(base, "keys"),
                   os.path.join(base, "keys", key_dir)):
        _grant(token, "mkdir", target)
        _fs_mkdir(token, target)
    _grant(token, "create", log_path(base), sha256(b""))
    _fs_create(token, log_path(base), b"")


def create_key_dir(token: object, *, store_id: str, key_dir: str) -> None:
    """Rotation: the bound, freshly allocated key directory of the store."""
    token = _require(token, "key-dir-create", stage="keys")
    bound = _keys_stage(token)
    if store_id != bound["store_id"] or key_dir != bound["key_dir"]:
        refuse("stage-mismatch", "key-dir-create: store or key_dir differs from stage 1")
    target = os.path.join(store_dir(store_id), "keys", key_dir)
    _grant(token, "mkdir", target)
    _fs_mkdir(token, target)


def _key_dir_path(bound: dict) -> str:
    return os.path.join(store_dir(bound["store_id"]), "keys", bound["key_dir"])


_KEY_STEP = [0]


def _publish(token: Token, temporary: str, target: str) -> None:
    _grant(token, "link", temporary, target)
    _fs_link_published(token, temporary, target)
    _KEY_STEP[0] += 1
    crash(f"key-step-{_KEY_STEP[0]}")
    _grant(token, "unlink-temp", temporary)
    _fs_unlink_temp(token, temporary)


def create_key(token: object, *, store_id: str, key_dir: str, name: str) -> str:
    """Create one Ed25519 key (the root or a type's subkey) in the bound key
    directory and publish <name> and <name>.pub without replacement.
    Returns the public key line."""
    token = _require(token, "key-create", stage="keys")
    bound = _keys_stage(token)
    if store_id != bound["store_id"] or key_dir != bound["key_dir"]:
        refuse("stage-mismatch", "key-create: store or key_dir differs from stage 1")
    if name != "root" and name not in bound["types"]:
        refuse("stage-mismatch", f"key-create: {name} is not in the bound type set")
    directory = _key_dir_path(bound)
    check_dir(directory)
    for existing in (name, f"{name}.pub"):
        if os.path.lexists(os.path.join(directory, existing)):
            refuse("exists", f"key-create: {existing} already exists")
    temporary = os.path.join(directory, f".tmp-{secrets.token_hex(8)}")
    comment = f"olddonkey-loop {store_id} e{bound['epoch']} {name}"
    result = _run_sink(token, "ssh-keygen.generate", comment=comment, key_temp=temporary)
    if result.returncode != 0 or not os.path.isfile(temporary) or not os.path.isfile(temporary + ".pub"):
        refuse("ssh-keygen", "ssh-keygen could not create an Ed25519 key", EXIT_ENV)
    pub = keys.parse_pub_file(read_file_raw(temporary + ".pub"))
    if keys.parse_private_key(read_file_raw(temporary)) != records.ed25519_blob(pub):
        refuse("ssh-keygen", "generated key halves disagree", EXIT_ENV)
    _publish(token, temporary, os.path.join(directory, name))
    _publish(token, temporary + ".pub", os.path.join(directory, f"{name}.pub"))
    return pub


def read_file_raw(target: str) -> bytes:
    """Read a just-created temporary key file (0600 or ssh-keygen's 0644)."""
    fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != OWNER or info.st_nlink != 1:
            refuse("layout", f"temporary key file refused: {target}")
        data = b""
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            data += chunk
        return data
    finally:
        os.close(fd)


def certify_key(token: object, *, store_id: str, key_dir: str, name: str) -> str:
    """Certify a type's subkey with the bound epoch's root: key identity
    <type>@e<epoch>, principal <type>, always:forever; publish
    <type>-cert.pub without replacement. Returns the subkey's key_id."""
    token = _require(token, "key-create", stage="keys")
    bound = _keys_stage(token)
    if store_id != bound["store_id"] or key_dir != bound["key_dir"]:
        refuse("stage-mismatch", "certify: store or key_dir differs from stage 1")
    if name not in bound["types"]:
        refuse("stage-mismatch", f"certify: {name} is not in the bound type set")
    directory = _key_dir_path(bound)
    final = os.path.join(directory, f"{name}-cert.pub")
    if os.path.lexists(final):
        refuse("exists", f"certify: {name}-cert.pub already exists")
    pub_bytes = read_file(os.path.join(directory, f"{name}.pub"))
    root_pub = keys.parse_pub_file(read_file(os.path.join(directory, "root.pub")))  # type: ignore[arg-type]
    subject = keys.parse_pub_file(pub_bytes)  # type: ignore[arg-type]
    stem = os.path.join(directory, f".tmp-{secrets.token_hex(8)}")
    _grant(token, "create", stem + ".pub", sha256(pub_bytes))  # type: ignore[arg-type]
    _fs_create(token, stem + ".pub", pub_bytes)  # type: ignore[arg-type]
    result = _run_sink(token, "ssh-keygen.certify", root=os.path.join(directory, "root"),
                       type=name, epoch=bound["epoch"], subkey_pub=stem + ".pub")
    cert_temp = stem + "-cert.pub"
    if result.returncode != 0 or not os.path.isfile(cert_temp):
        refuse("ssh-keygen", "ssh-keygen could not certify the subkey", EXIT_ENV)
    data = read_file_raw(cert_temp)
    try:
        cert = keys.parse_cert_file(data)
        key_id = keys.check_certificate(cert, record_type=name, epoch=bound["epoch"],
                                        root_pub=root_pub)
        if cert.subject_blob != records.ed25519_blob(subject):
            refuse("ssh-keygen", "certificate subject is not the subkey", EXIT_ENV)
        if keys.ssh_keygen_fingerprint(cert_temp, token=token) != key_id:
            refuse("ssh-keygen", "ssh-keygen cannot verify the new certificate", EXIT_ENV)
    except keys.KeyFileError as error:
        refuse("ssh-keygen", f"certificate refused: {error.message}", EXIT_ENV)
    _publish(token, cert_temp, final)
    _grant(token, "unlink-temp", stem + ".pub")
    _fs_unlink_temp(token, stem + ".pub")
    return key_id


def seal(token: object, *, record_type: str, payload: bytes, key_dir: str) -> str:
    """Seal the bound payload with the bound type's subkey (stage 1)."""
    token = _require(token, "seal", stage="record")
    bound = token.stages["record"]
    records.check_type(record_type)
    if record_type != bound["type"]:
        refuse("stage-mismatch", "seal: type differs from stage 1")
    if sha256(payload) != bound["payload_digest"]:
        refuse("stage-mismatch", "seal: payload differs from stage 1")
    if key_dir != bound["signing_key_dir"]:
        refuse("stage-mismatch", "seal: subkey differs from stage 1")
    if token.row == "epoch-revocation":
        _check_revocation_payload(token, payload)
    cert_path = os.path.join(key_dir, f"{record_type}-cert.pub")
    cert = keys.parse_cert_file(read_file(cert_path))  # type: ignore[arg-type]
    if keys.fingerprint(cert.subject_blob) != bound["key_id"]:
        refuse("stage-mismatch", "seal: the subkey's key_id differs from stage 1")
    result = _run_sink(token, "ssh-keygen.sign", stdin=payload, subkey=cert_path,
                       type=record_type)
    text = result.stdout.decode("ascii", "replace")
    if result.returncode != 0 or not records.SIG_RE.fullmatch(text):
        refuse("ssh-keygen", "ssh-keygen -Y sign failed (OpenSSH >= 8.2 with -Y is required)",
               EXIT_ENV)
    return text


def seal_pointer(token: object, *, pointer: bytes, key_dir: str) -> str:
    """Sign the bound pointer bytes with the bound epoch root (stage 2)."""
    token = _require(token, "pointer-seal", stage="frame")
    if sha256(pointer) != token.stages["frame"]["pointer_digest"]:
        refuse("stage-mismatch", "seal_pointer: pointer bytes differ from stage 2")
    if key_dir != token.stages["record"]["pointer_key_dir"]:
        refuse("stage-mismatch", "seal_pointer: root differs from stage 1")
    result = _run_sink(token, "ssh-keygen.sign-pointer", stdin=pointer,
                       root=os.path.join(key_dir, "root"))
    text = result.stdout.decode("ascii", "replace")
    if result.returncode != 0 or not records.SIG_RE.fullmatch(text):
        refuse("ssh-keygen", "ssh-keygen -Y sign of the pointer failed", EXIT_ENV)
    return text


def _write_intent_file(token: Token, target: str, data: bytes) -> None:
    if sha256(data) != token.stages["anchor"]["intent_digest"]:
        refuse("stage-mismatch", "intent bytes differ from stage 3")
    if os.path.lexists(target):
        refuse("exists", f"an intent already exists: {target}")
    _grant(token, "create", target, sha256(data))
    _fs_create(token, target, data)
    token.flags.add("intent")
    crash("after-intent-fsync")


def write_intent(token: object, *, store_id: str, data: bytes) -> None:
    """The store's durable write intent (A1.6), from frame 2 on (stage 3)."""
    token = _require(token, "intent-write", stage="anchor")
    if store_id != token.stages["record"]["store_id"]:
        refuse("stage-mismatch", "write_intent: store differs from stage 1")
    _write_intent_file(token, os.path.join(store_dir(store_id), "intent"), data)


def write_genesis_intent(token: object, *, data: bytes) -> None:
    """genesis.intent (A2.3 step 2): the only intent for frame 1."""
    token = _require(token, "genesis-intent-write", stage="anchor")
    if _keys_stage(token)["intent_path"] != GENESIS_INTENT:
        refuse("stage-mismatch", "write_genesis_intent: intent path differs from stage 1")
    _write_intent_file(token, path(GENESIS_INTENT), data)


def write_regenesis_intent(token: object, *, data: bytes) -> None:
    """regenesis.intent (A1.3 step 1)."""
    token = _require(token, "regenesis-intent-write", stage="anchor")
    if _keys_stage(token)["intent_path"] != REGENESIS_INTENT:
        refuse("stage-mismatch", "write_regenesis_intent: intent path differs from stage 1")
    _write_intent_file(token, path(REGENESIS_INTENT), data)


def append_frame(token: object, *, store_id: str, data: bytes) -> None:
    """Append the bound frame at the bound offset, after the intent is
    durable (stage 2 bytes, stage 3 offset)."""
    token = _require(token, "frame-append", stage="anchor", flags=("intent",))
    if store_id != token.stages["record"]["store_id"]:
        refuse("stage-mismatch", "append_frame: store differs from stage 1")
    if sha256(data) != token.stages["frame"]["frame_digest"]:
        refuse("stage-mismatch", "append_frame: frame bytes differ from stage 2")
    target = log_path(store_dir(store_id))
    offset = token.stages["anchor"]["offset"]
    _grant(token, "append", target, offset, sha256(data))
    _fs_append(token, target, offset, data)
    token.flags.add("frame")
    crash("after-frame-fsync")


def _recovery_bound(token: Token, store_id: str, sink: str) -> dict:
    bound = token.stages["recovery"]
    if store_id != bound["store_id"]:
        refuse("stage-mismatch", f"{sink}: store differs from the recovery binding")
    return bound


def complete_delimiter(token: object, *, store_id: str, frame_bytes: bytes) -> None:
    """Delimiter completion (A1.6), part of replay-forward's compound: the
    log must end with exactly the bound intent's frame minus its final
    newline, and the remote must still be the frame's parent."""
    token = _require(token, "delimiter-completion")
    _recovery_bound(token, store_id, "complete_delimiter")
    if frame_bytes != token.facts["frame"] or not bound_unterminated(token):
        refuse("stage-mismatch", "complete_delimiter: frame differs from the bound intent's")
    target = log_path(store_dir(store_id))
    size = token.facts["offset"] + len(frame_bytes) - 1
    _grant(token, "append", target, size, sha256(b"\n"))
    _fs_append(token, target, size, b"\n")
    token.flags.add("delimiter")
    _after(token)


def bound_unterminated(token: Token) -> bool:
    return bool(token.stages["recovery"]["unterminated"]) and "delimiter" not in token.flags


def truncate_frame(token: object, *, store_id: str, offset: int) -> None:
    """Torn-frame truncation (A1.3): the only discard, to exactly the bound
    intent's offset, after re-proving the torn tail and the remote."""
    token = _require(token, "truncation")
    bound = _recovery_bound(token, store_id, "truncate_frame")
    if offset != bound["offset"] or offset != token.facts["offset"]:
        refuse("stage-mismatch", "truncate_frame: offset differs from the recovery binding")
    target = log_path(store_dir(store_id))
    _grant(token, "truncate", target, offset)
    _fs_truncate(token, target, offset)
    _after(token)


def _remove(token: Token, target: str) -> None:
    if not os.path.lexists(target):
        refuse("missing", f"nothing to remove: {target}")
    read_file(target)
    _grant(token, "unlink", target)
    _fs_unlink(token, target)
    _after(token)


def remove_intent(token: object, *, store_id: str) -> None:
    """Remove the store's write intent: after the readback (ceremony), or
    by recovery tidy (the bound intent, re-proved with the remote)."""
    token = _require(token, "intent-remove", flags=("readback",))
    if token.kind == "recovery":
        bound = _recovery_bound(token, store_id, "remove_intent")
        if bound["intent_digest"] is None:
            refuse("stage-mismatch", "remove_intent: the recovery binding names no intent")
    elif store_id != token.stages["record"]["store_id"]:
        refuse("stage-mismatch", "remove_intent: store differs from stage 1")
    _remove(token, os.path.join(store_dir(store_id), "intent"))
    crash("after-intent-remove")


def _finish_done(token: Token) -> None:
    """Before an A2.4 completion token removes the intent, its other sinks
    are done: the target active (and, for re-genesis, the old store
    archived). Abandonment has no other sink: removing the intent is all it
    does, and the intent-named directory stays."""
    targets = token.stages["finish"]["targets"]
    if token.action == "complete":
        if read_file(path(ACTIVE), missing_ok=True) != canonical.canonical(targets["active_target"]):
            refuse("protocol-order", "the intent is removed only after the active marker")
        if targets["archive_store"] is not None and check_dir(
                store_dir(targets["archive_store"]), missing_ok=True):
            refuse("protocol-order", "the intent is removed only after the archive move")


def remove_genesis_intent(token: object) -> None:
    token = _require(token, "genesis-intent-remove", flags=("readback", "active"))
    if token.kind == "finish":
        _finish_done(token)
    _remove(token, path(GENESIS_INTENT))
    crash("genesis-step-6b")
    crash("after-intent-remove")


def remove_regenesis_intent(token: object) -> None:
    token = _require(token, "regenesis-intent-remove", flags=("readback", "active"))
    if token.kind == "finish":
        _finish_done(token)
    _remove(token, path(REGENESIS_INTENT))


def write_cursor(token: object, *, store_id: str, data: bytes) -> None:
    """The local cursor: a recovery hint, never authority."""
    token = _require(token, "cursor-write", flags=("readback",))
    if token.kind == "recovery":
        bound = _recovery_bound(token, store_id, "write_cursor")
        if sha256(data) != bound["cursor_digest"]:
            refuse("stage-mismatch", "write_cursor: bytes differ from the recovery binding")
    elif store_id != _bound_store(token):
        refuse("stage-mismatch", "write_cursor: store differs from stage 1")
    records_value = canonical.loads(data.decode("utf-8"))
    if type(records_value) is not dict or records_value.get("store_id") != store_id:
        refuse("cursor", "cursor must name its store")
    target = os.path.join(store_dir(store_id), "cursor")
    _grant(token, "replace", target, sha256(data))
    _fs_replace(token, target, data)
    _after(token)


def _bound_store(token: Token) -> str:
    if "keys" in token.stages:
        return token.stages["keys"]["store_id"]
    return token.stages["record"]["store_id"]


def _revocation_durable(token: Token, store_id: str, data: bytes) -> None:
    """The revocation's quarantine child: its parent bound the revocation of
    the active epoch; the marker is exactly that revocation's one marker;
    and the log holds, at the bound offset, exactly the bound frame -- a
    record that revokes its own sealing epoch from active."""
    root = _root_token(token)
    bound = _active_revocation(root)
    if store_id != bound["store_id"]:
        refuse("stage-mismatch", "write_quarantine: store differs from the revoked store")
    if data != active_revocation_marker(store_id, bound["seq"]):
        refuse("stage-mismatch", "write_quarantine: not the marker of this active-epoch revocation")
    frame_stage, record_stage = root.stages.get("frame"), root.stages.get("record")
    log = _log_bytes(store_id)
    written = log[bound["offset"]:] if log is not None else b""
    if frame_stage is None or record_stage is None or sha256(written) != frame_stage["frame_digest"]:
        refuse("protocol-order", "the log does not end with the bound, durable revocation frame")
    try:
        payload, _sig = records.parse_content(frame.split_frame(written, bound["seq"]).content)
    except (frame.FrameError, records.RecordError) as error:
        raise AuthorityError("protocol-order", "the durable revocation frame does not parse") from error
    body = payload.get("body")
    if type(body) is not dict or payload.get("type") != "epoch.revoked" \
            or body.get("prior_state") != "active" or body.get("epoch") != bound["epoch"] \
            or payload.get("epoch") != bound["epoch"] \
            or sha256(records.payload_bytes(payload)) != record_stage["payload_digest"]:
        refuse("compound", "the durable record does not revoke its own sealing epoch from active")


def write_quarantine(token: object, *, store_id: str, data: bytes) -> None:
    """The store quarantine marker (A1.3): recovery-derived (its offending
    position and rule re-observed by _require), or the child of the
    revocation of the active epoch -- exactly its one marker, after the
    readback, re-proved against the durable revocation record. Never
    overwritten."""
    token = _require(token, "quarantine-marker")
    if token.kind == "child":
        if "readback" not in token.flags:
            refuse("protocol-order", "the revocation's quarantine follows its readback")
        _revocation_durable(token, store_id, data)
    elif token.kind == "recovery":
        bound = _recovery_bound(token, store_id, "write_quarantine")
        if sha256(data) != bound["marker_digest"]:
            refuse("stage-mismatch", "write_quarantine: marker differs from the recovery binding")
    value = canonical.loads(data.decode("utf-8"))
    if type(value) is not dict or value.get("store_id") != store_id or not value.get("rule"):
        refuse("quarantine", "a quarantine marker names its store and rule")
    if token.kind == "recovery" and (value.get("rule") != bound["rule"]
                                     or value.get("position") != bound["position"]):
        refuse("stage-mismatch", "write_quarantine: the marker does not name the re-observed rule "
               "and position")
    target = os.path.join(store_dir(store_id), "quarantine")
    if os.path.lexists(target):
        refuse("exists", "the store is already quarantined")
    _grant(token, "create", target, sha256(data))
    _fs_create(token, target, data)
    _after(token)


def write_active(token: object, *, target: dict) -> None:
    """The active marker, only for the bound target: stage 1 of genesis or
    linked re-genesis, or an A2.4 completion token."""
    if token_is_open(token) and token.kind == "finish":  # type: ignore[union-attr]
        token = _require(token, "active-marker")
        bound = token.stages["finish"]["targets"]["active_target"]
        if token.row == "linked-regenesis" and check_dir(
                store_dir(token.stages["finish"]["targets"]["archive_store"]), missing_ok=True):
            refuse("protocol-order", "re-genesis marks the new store active after the archive move")
    else:
        needed = ("readback", "archived") if token_is_open(token) and \
            token.row == "linked-regenesis" else ("readback",)  # type: ignore[union-attr]
        token = _require(token, "active-marker", stage="keys", flags=needed)
        bound = _keys_stage(token)["active_target"]
    if bound is None or target != bound:
        refuse("stage-mismatch", "write_active: target differs from the bound target")
    data = canonical.canonical(target)
    active_path = path(ACTIVE)
    if token.row == "authority-genesis" and os.path.lexists(active_path):
        refuse("exists", "genesis never replaces an active marker")
    _grant(token, "replace", active_path, sha256(data))
    _fs_replace(token, active_path, data)
    token.flags.add("active")
    _after(token)
    crash("genesis-step-6a")


def archive_store(token: object, *, store_id: str) -> None:
    """Linked re-genesis step 4: move the old store to archive/, read-only."""
    if token_is_open(token) and token.kind == "finish":  # type: ignore[union-attr]
        token = _require(token, "archive-move")
        bound = token.stages["finish"]["targets"]["archive_store"]
    else:
        token = _require(token, "archive-move", stage="keys", flags=("readback",))
        bound = token.stages.get("regenesis", {}).get("old_store_id")
    if bound is None or store_id != bound:
        refuse("stage-mismatch", "archive_store: store differs from the bound old store")
    source = store_dir(store_id)
    destination = archive_dir(store_id)
    if os.path.lexists(source):
        _grant(token, "rename", source, destination)
        _fs_rename_dir(token, source, destination)
    elif not os.path.lexists(destination):
        refuse("missing", "the old store is neither in stores/ nor in archive/")
    crash("archive-after-rename")
    _grant(token, "read-only", destination)
    _fs_read_only_tree(token, destination)
    crash("archive-after-readonly")
    token.flags.add("archived")
    _after(token)


def push_anchor(token: object, *, scratch: str, commit: str, ref: str) -> None:
    """The anchor push (A1.2 step 3): only the bound commit to the bound ref,
    fast-forward from the bound expected parent. The authority-head advance
    child of a record row (stage 3), or anchor replay-forward (recovery:
    the commit and parent of the bound intent, its frame re-proved
    complete)."""
    token = _require(token, "anchor-push")
    if token.kind == "child":
        bound = _root_token(token).stages.get("anchor")
        if bound is None or "frame" not in token.flags:
            refuse("protocol-order", "push_anchor: the frame is not durable yet")
        expected_parent = bound["expected_parent"]
        bound_ref = bound["ref"]
    else:
        bound = token.stages["recovery"]
        expected_parent = bound["expected_parent"]
        bound_ref = tools.ANCHOR_REF
    if commit != bound["anchor_commit"] or ref != tools.ANCHOR_REF or ref != bound_ref:
        refuse("stage-mismatch", "push_anchor: commit or ref differs from the bound anchor")
    remote = tools.pinned_remote()
    if remote is None:
        refuse("remote", "no pinned remote")
    try:
        tip = anchor.ls_remote(scratch, remote.url)  # type: ignore[union-attr]
    except anchor.Unreachable as error:
        refuse("pending", f"remote unreachable before push: {error}", EXIT_PENDING)
    if tip != expected_parent:
        refuse("non-fast-forward", "the remote anchor is not the expected parent; refusing to push")
    anchor.prepare_push(scratch, commit)
    try:
        result = _run_sink(token, "git.push-anchor", scratch=scratch, remote=remote.url,  # type: ignore[union-attr]
                           commit=commit)
    except tools.ToolError as error:
        if error.code in ("timeout", "exec"):
            refuse("pending", f"anchor push unavailable: {error.message}", EXIT_PENDING)
        raise
    if result.returncode != 0:
        refuse("pending", "anchor push failed: "
               + result.stderr.decode("utf-8", "replace").strip()[:300], EXIT_PENDING)
    token.flags.add("pushed")
    crash("after-push")


def bind_regenesis(token: Token, *, old_store_id: str) -> None:
    if token.row != "linked-regenesis" or "regenesis" in token.stages:
        spend(token)
        refuse("rebind", "the re-genesis old store is bound once; the token is spent")
    token.stages["regenesis"] = {"old_store_id": old_store_id}


# ---------------------------------------------------------------------------
# The write-protocol driver (never a sink)
# ---------------------------------------------------------------------------

class Prepared:
    __slots__ = ("payload", "payload_bytes", "sig", "content", "frame", "record_digest",
                 "active", "prev_generation", "pointer", "pointer_sig", "anchor_json",
                 "anchor_commit", "intent", "intent_bytes", "offset", "seq", "record_type")


def intent_fields(*, seq: int, offset: int, content: bytes, record_digest: str,
                  expected_parent: str | None, anchor_json: bytes, anchor_commit: str,
                  frame_bytes: bytes) -> dict:
    return {
        "seq": seq,
        "offset": offset,
        "length": len(content),
        "digest": record_digest,
        "expected_parent": expected_parent,
        "anchor_json": anchor_json.decode("utf-8"),
        "anchor_commit": anchor_commit,
        "frame_length": len(frame_bytes),
        "frame_b64": base64.b64encode(frame_bytes).decode("ascii"),
    }


def check_intent_consistency(intent: dict) -> frame.Frame:
    """A1.6: anchor_json names this seq and this frame's record digest, and
    anchor_commit is exactly the commit git builds from anchor_json and
    expected_parent. Returns the parsed frame."""
    try:
        frame_bytes = base64.b64decode(intent["frame_b64"], validate=True)
    except (ValueError, TypeError, KeyError) as error:
        raise AuthorityError("intent", f"intent frame bytes unreadable: {error}") from error
    if len(frame_bytes) != intent.get("frame_length"):
        refuse("intent", "intent frame_length disagrees with its bytes")
    try:
        parsed = frame.split_frame(frame_bytes, intent["seq"])
    except frame.FrameError as error:
        raise AuthorityError("intent", f"intent frame is not one frame: {error.message}") from error
    if (parsed.length != intent["length"] or parsed.digest != intent["digest"]
            or parsed.offset != 0):
        refuse("intent", "intent length or digest disagrees with its frame")
    try:
        active, _prev, _sig = records.parse_anchor_json(intent["anchor_json"].encode("utf-8"))
    except (records.RecordError, AttributeError) as error:
        raise AuthorityError("intent", "intent anchor_json unreadable") from error
    if active["seq"] != intent["seq"] or active["record_digest"] != intent["digest"]:
        refuse("intent", "anchor_json does not name this seq and record digest")
    rebuilt = anchor.expected_commit(intent["anchor_json"].encode("utf-8"),
                                     intent["expected_parent"])
    if rebuilt != intent["anchor_commit"]:
        refuse("intent", "anchor_commit is not the commit rebuilt from anchor_json")
    return parsed


def prepare_record(token: Token, *, scratch: str, record_type: str, store_id: str,
                   generation: int, seq: int, prev: str | None, body: dict,
                   signing_epoch: int, signing_key_dir: str, signing_root_pub: str,
                   pointer_epoch: int, pointer_key_dir: str, pointer_root_pub: str,
                   genesis_digest: str | None, prev_generation: dict | None,
                   expected_parent: str | None, offset: int, intent_extra: dict) -> Prepared:
    """Seal the record and its pointer, build the deterministic commit, and
    bind stages 1 (record), 2, and 3, checking everything A1.6 requires
    before any intent is written."""
    if not records.type_admitted(records.REGISTRY_VERSION, record_type):
        refuse("type-not-admitted", f"{record_type} is not admitted by this writer's registry "
               f"version {records.REGISTRY_VERSION}")
    cert = keys.parse_cert_file(read_file(os.path.join(signing_key_dir,  # type: ignore[arg-type]
                                                       f"{record_type}-cert.pub")))
    key_id = keys.fingerprint(cert.subject_blob)
    payload = records.build_payload(record_type, store_id=store_id, generation=generation,
                                    seq=seq, epoch=signing_epoch, key_id=key_id, prev=prev,
                                    body=body)
    records.check_payload(payload, remote_check=tools.anchor_class_of)
    payload_bytes = records.payload_bytes(payload)
    bind_record(token, store_id=store_id, record_type=record_type,
                payload_digest=sha256(payload_bytes), key_id=key_id,
                signing_key_dir=signing_key_dir, pointer_key_dir=pointer_key_dir)
    sig = seal(token, record_type=record_type, payload=payload_bytes, key_dir=signing_key_dir)
    content = records.content_bytes(payload, sig)
    frame_bytes = frame.encode(seq, record_type, content)
    record_digest = frame.frame_digest(seq, record_type, content)
    active = {
        "store_id": store_id,
        "generation": generation,
        "genesis_digest": genesis_digest if genesis_digest is not None else record_digest,
        "seq": seq,
        "record_digest": record_digest,
        "epoch": pointer_epoch,
        "key_id": records.key_id_of_pub(pointer_root_pub),
    }
    pointer = records.pointer_bytes(active, prev_generation)
    bind_frame(token, frame_digest=sha256(frame_bytes), record_digest=record_digest,
               pointer_digest=sha256(pointer))
    check_frame_byte(len(frame_bytes))
    pointer_sig = seal_pointer(token, pointer=pointer, key_dir=pointer_key_dir)
    anchor_json = records.anchor_json_bytes(active, prev_generation, pointer_sig)
    try:
        verified = keys.verify_seal(record_type=record_type, epoch=signing_epoch,
                                    root_pub=signing_root_pub, payload=payload_bytes, sig=sig)
        keys.verify_pointer(root_pub=pointer_root_pub, pointer=pointer, sig=pointer_sig)
    except keys.KeyFileError as error:
        refuse("ssh-keygen", f"the host ssh-keygen cannot verify its own seal: {error.message}",
               EXIT_ENV)
    if verified != key_id:
        refuse("key-id", "the seal's certificate is not the bound subkey")
    try:
        commit = anchor.build_objects(scratch, anchor_json, expected_parent)
    except anchor.AnchorError as error:
        refuse("anchor-objects", f"anchor commit refused before the frame: {error.message}")
    intent = intent_fields(seq=seq, offset=offset, content=content, record_digest=record_digest,
                           expected_parent=expected_parent, anchor_json=anchor_json,
                           anchor_commit=commit, frame_bytes=frame_bytes)
    intent.update(intent_extra)
    check_intent_consistency(intent)
    intent_bytes = canonical.canonical(intent)
    bind_anchor(token, anchor_json_digest=sha256(anchor_json), anchor_commit=commit,
                ref=tools.ANCHOR_REF, intent_digest=sha256(intent_bytes),
                expected_parent=expected_parent, offset=offset)
    prepared = Prepared()
    prepared.payload = payload
    prepared.payload_bytes = payload_bytes
    prepared.sig = sig
    prepared.content = content
    prepared.frame = frame_bytes
    prepared.record_digest = record_digest
    prepared.active = active
    prepared.prev_generation = prev_generation
    prepared.pointer = pointer
    prepared.pointer_sig = pointer_sig
    prepared.anchor_json = anchor_json
    prepared.anchor_commit = commit
    prepared.intent = intent
    prepared.intent_bytes = intent_bytes
    prepared.offset = offset
    prepared.seq = seq
    prepared.record_type = record_type
    return prepared


def readback(token: Token, *, scratch: str, commit: str, anchor_json: bytes,
             expected_parent: str | None, root_pub: str) -> None:
    """A1.2 step 4: fetch the ref, require the pushed commit, and verify it by
    content -- parent, anchor.json bytes, and the pointer signature."""
    remote = tools.pinned_remote()
    assert remote is not None
    try:
        fetched = anchor.fetch(scratch, remote.url)
    except anchor.Unreachable as error:
        refuse("pending", f"readback failed; the store is pending: {error}", EXIT_PENDING)
    if fetched != commit:
        refuse("readback", "the remote anchor is not the pushed commit")
    try:
        data, parent = anchor.read_anchor_commit(scratch, fetched)
        if data != anchor_json or parent != expected_parent:
            refuse("readback", "the remote anchor's content differs from what was pushed")
        active, prev, sig = records.parse_anchor_json(data)
        keys.verify_pointer(root_pub=root_pub,
                            pointer=records.pointer_bytes(active, prev), sig=sig)
    except (anchor.AnchorError, keys.KeyFileError, records.RecordError) as error:
        refuse("readback", f"readback verification failed: {error}")
    _root_token(token).flags.add("readback")
    crash("after-readback")


def cursor_bytes(store_id: str, seq: int, record_digest: str, anchor_commit: str) -> bytes:
    return canonical.canonical({"store_id": store_id, "seq": seq, "record_digest": record_digest,
                                "anchor_commit": anchor_commit})


def quarantine_bytes(store_id: str, rule: str, position: dict | None, detail: str) -> bytes:
    return canonical.canonical({"store_id": store_id, "rule": rule, "position": position,
                                "detail": detail[:500]})
