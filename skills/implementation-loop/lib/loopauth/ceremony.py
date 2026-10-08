"""Operator-TTY ceremonies (A1.1, A1.8; task-graph-v1 Phase A, sub-unit 0a.2
section 5): genesis, rotate, revoke, regenesis.

A ceremony refuses unless stdin and stdout are terminals; prints the
canonical envelope and a 12-hex-character challenge from secrets; proceeds
only on an exact echo; and records principal = {kind: operator-tty, tty:
ttyname(0), start_token}. What this proves is stated plainly by A1.1: a
session with a terminal performed the ceremony -- not that a human approved
it. Nothing sealed here may be described as human approval.

start_token = {boot_id, pid, start_time} (A1.8): on macOS boot_id from
sysctl kern.bootsessionuuid and start_time the process's p_starttime in
microseconds (sysctl CTL_KERN, KERN_PROC, KERN_PROC_PID via ctypes); on
Linux /proc/sys/kernel/random/boot_id and field 22 of /proc/<pid>/stat
(clock ticks since boot). Either unreadable refuses the ceremony; there is
no coarser fallback, and no environment variable skips the TTY check. An
unreadable ttyname(0), or a terminal read or write that fails during the
challenge, refuses the same way (exit 11, naming the failed read or write).
"""

from __future__ import annotations

import ctypes
import os
import re
import secrets
import struct
import sys

from . import canonical, records, recover, registry, store, tools

CTL_KERN = 1
KERN_PROC = 14
KERN_PROC_PID = 1
KINFO_PROC_SIZE = 648
KINFO_PID_OFFSET = 40
CHALLENGE_HEX = 12


class StartTokenError(Exception):
    pass


# ---------------------------------------------------------------------------
# Start tokens (A1.8)
# ---------------------------------------------------------------------------

def _libc() -> ctypes.CDLL:
    return ctypes.CDLL(None, use_errno=True)


def read_boot_id() -> str:
    if sys.platform == "darwin":
        libc = _libc()
        size = ctypes.c_size_t(0)
        if libc.sysctlbyname(b"kern.bootsessionuuid", None, ctypes.byref(size), None, 0) != 0 \
                or not 0 < size.value <= 256:
            raise StartTokenError("sysctl kern.bootsessionuuid is unreadable")
        buf = ctypes.create_string_buffer(size.value)
        if libc.sysctlbyname(b"kern.bootsessionuuid", buf, ctypes.byref(size), None, 0) != 0:
            raise StartTokenError("sysctl kern.bootsessionuuid is unreadable")
        value = buf.value.decode("ascii", "replace")
    elif sys.platform.startswith("linux"):
        try:
            with open("/proc/sys/kernel/random/boot_id", "rb") as handle:
                value = handle.read(128).decode("ascii", "replace").strip()
        except OSError as error:
            raise StartTokenError(f"boot_id is unreadable: {error}") from error
    else:
        raise StartTokenError(f"no boot id source on {sys.platform}")
    if not re.fullmatch(r"[A-Za-z0-9-]{8,64}", value):
        raise StartTokenError("boot id is malformed")
    return value


def read_start_time(pid: int) -> int:
    if type(pid) is not int or pid < 1:
        raise StartTokenError("pid must be a positive integer")
    if sys.platform == "darwin":
        libc = _libc()
        mib = (ctypes.c_int * 4)(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)
        buf = ctypes.create_string_buffer(KINFO_PROC_SIZE)
        size = ctypes.c_size_t(KINFO_PROC_SIZE)
        if libc.sysctl(mib, 4, buf, ctypes.byref(size), None, 0) != 0:
            raise StartTokenError("sysctl KERN_PROC_PID failed")
        if size.value != KINFO_PROC_SIZE:
            raise StartTokenError(f"no such process: {pid}")
        seconds, micros = struct.unpack_from("=qi", buf.raw, 0)
        (found,) = struct.unpack_from("=i", buf.raw, KINFO_PID_OFFSET)
        if found != pid or seconds <= 0 or not 0 <= micros < 1_000_000:
            raise StartTokenError("kinfo_proc layout not recognised")
        return seconds * 1_000_000 + micros
    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/stat", "rb") as handle:
                data = handle.read(4096).decode("ascii", "replace")
        except OSError as error:
            raise StartTokenError(f"/proc/{pid}/stat is unreadable: {error}") from error
        fields = data[data.rfind(")") + 2:].split()
        # fields[0] is field 3 (state); field 22 is fields[19].
        if len(fields) < 20 or not fields[19].isdigit():
            raise StartTokenError("/proc stat field 22 is unreadable")
        return int(fields[19])
    raise StartTokenError(f"no start-time source on {sys.platform}")


def start_token(pid: int | None = None) -> dict:
    pid = os.getpid() if pid is None else pid
    return {"boot_id": read_boot_id(), "pid": pid, "start_time": read_start_time(pid)}


def same_process(first: dict, second: dict) -> bool:
    """Two start tokens name the same process only when boot_id, pid, and the
    full-resolution start_time are all equal (microseconds on macOS)."""
    return (first.get("boot_id") == second.get("boot_id") and first.get("pid") == second.get("pid")
            and first.get("start_time") == second.get("start_time")
            and type(first.get("start_time")) is int)


def is_stale(token: dict) -> bool:
    try:
        return not same_process(token, start_token(token.get("pid")))  # type: ignore[arg-type]
    except StartTokenError:
        return True


# ---------------------------------------------------------------------------
# The TTY session and the challenge
# ---------------------------------------------------------------------------

def require_tty() -> None:
    if not (os.isatty(0) and os.isatty(1)):
        raise store.AuthorityError("no-tty", "a ceremony needs stdin and stdout to be terminals",
                                   store.EXIT_TTY)


def _write(text: str) -> None:
    data = text.encode("utf-8")
    while data:
        written = os.write(1, data)
        data = data[written:]


def _read_line(limit: int = 256) -> bytes:
    line = b""
    while len(line) <= limit:
        chunk = os.read(0, 1)
        if not chunk:
            break
        line += chunk
        if chunk == b"\n":
            break
    return line


def challenge(envelope: dict) -> None:
    """Print the canonical envelope and a fresh challenge; proceed only on an
    exact echo."""
    require_tty()
    code = secrets.token_hex(CHALLENGE_HEX // 2)
    # The terminal can fail mid-exchange (EIO on a hung-up pty): the TTY-class
    # refusal naming the failed read or write, never a traceback. Nothing has
    # been begun yet.
    try:
        _write("olddonkey-loop authority ceremony (operator-TTY session; this is not human "
               "approval)\n")
        _write("envelope: " + canonical.canonical(envelope).decode("utf-8") + "\n")
        _write(f"challenge: {code}\n")
        _write("type the challenge to proceed: ")
    except OSError as error:
        raise store.AuthorityError("tty-write", f"cannot write the challenge to the terminal "
                                   f"(fd 1): {error}", store.EXIT_TTY) from error
    try:
        answer = _read_line()
    except OSError as error:
        raise store.AuthorityError("tty-read", f"cannot read the challenge echo from the terminal "
                                   f"(fd 0): {error}", store.EXIT_TTY) from error
    if answer.rstrip(b"\r\n") != code.encode("ascii") or not answer.endswith(b"\n"):
        raise store.AuthorityError("challenge", "the challenge was not echoed exactly",
                                   store.EXIT_TTY)


def principal_for(tty: str, token: dict) -> dict:
    principal = {"kind": "operator-tty", "tty": tty, "start_token": token}
    records.check_principal(principal)
    return principal


# ---------------------------------------------------------------------------
# Ceremonies
# ---------------------------------------------------------------------------

# Each ceremony is the one external entry point of exactly one row.
CEREMONY_ROWS = {"genesis": "authority-genesis", "rotate": "epoch-rotation",
                 "revoke": "epoch-revocation", "regenesis": "linked-regenesis"}


def activation_boundary() -> dict:
    """What every epoch introducer carries and its ceremony displays (A2.1):
    the registry version sealing it and the protocols its epoch admits --
    for 0a, tg-v1.0a and none."""
    return {"registry_version": records.REGISTRY_VERSION, "admitted_protocols": []}


def _guard_test_binaries(anchor_class: str | None) -> None:
    try:
        tools.refuse_test_binaries(anchor_class)
    except tools.ToolError as error:
        raise store.AuthorityError(error.code, error.message, store.EXIT_ENV) from error


def run(kind: str, options: dict) -> dict:
    """The ceremony entry point: TTY first, then the crash seam, the start
    token, the lock, recovery, preconditions, the challenge, the
    transaction."""
    if kind not in CEREMONY_ROWS:
        raise store.AuthorityError("usage", f"unknown ceremony {kind!r}", store.EXIT_USAGE)
    require_tty()
    store.configure_crash(kind)
    # Either principal read failing (an OSError included: macOS's ttyname
    # returns ERANGE under heavy pty allocation) is the TTY-class refusal
    # naming the failed read, before the lock, any key, intent, frame, or
    # push.
    try:
        token = start_token()
    except (StartTokenError, OSError) as error:
        raise store.AuthorityError("start-token", f"cannot read the session start token: {error}",
                                   store.EXIT_TTY) from error
    try:
        tty = os.ttyname(0)
    except OSError as error:
        raise store.AuthorityError("tty-name", f"cannot read the terminal's name (ttyname(0)): "
                                   f"{error}", store.EXIT_TTY) from error
    principal = principal_for(tty, token)
    with store.WriterLock():
        if kind == "genesis":
            return genesis(principal, options.get("remote"))
        if kind == "rotate":
            return rotate(principal)
        if kind == "revoke":
            return revoke(principal, options.get("epoch"))
        return regenesis(principal)


def _envelope(kind: str, principal: dict, parameters: dict) -> dict:
    return {"ceremony": kind, "principal": principal, "parameters": parameters}


def _refuse_intents() -> None:
    for name in (store.ACTIVE, store.GENESIS_INTENT, store.REGENESIS_INTENT):
        if store.exists(store.path(name)):
            raise store.AuthorityError("genesis-refused", f"genesis refuses: {name} exists")


def _create_keys(token: store.Token, store_id: str, key_dir: str) -> tuple[str, dict]:
    root_pub = store.create_key(token, store_id=store_id, key_dir=key_dir, name="root")
    subkeys = {}
    for name in records.TYPES:
        store.create_key(token, store_id=store_id, key_dir=key_dir, name=name)
        subkeys[name] = store.certify_key(token, store_id=store_id, key_dir=key_dir, name=name)
    return root_pub, subkeys


def _key_path(store_id: str, key_dir: str) -> str:
    return os.path.join(store.store_dir(store_id), "keys", key_dir)


def _finish_record(token: store.Token, prepared: store.Prepared, scratch: str,
                   pointer_root_pub: str) -> None:
    head = store.child(token, "authority-head-advance")
    store.push_anchor(head, scratch=scratch, commit=prepared.anchor_commit, ref=tools.ANCHOR_REF)
    store.readback(token, scratch=scratch, commit=prepared.anchor_commit,
                   anchor_json=prepared.anchor_json,
                   expected_parent=prepared.intent["expected_parent"], root_pub=pointer_root_pub)


def genesis(principal: dict, url: object) -> dict:
    _refuse_intents()
    try:
        remote = tools.parse_remote(url, allow_test=tools.test_mode())
    except tools.ToolError as error:
        raise store.AuthorityError(error.code, error.message) from error
    # Before any key, intent, or remote read: test binaries never take part
    # in a production lineage (a lineage is production or test forever).
    _guard_test_binaries(remote.anchor_class)
    tools.pin_remote(remote)
    scratch_pool = recover.Scratch()
    try:
        scratch = scratch_pool()
        try:
            tip = recover.anchor.ls_remote(scratch, remote.url)
            remote_ref = "present" if tip is not None else "absent"
        except recover.anchor.Unreachable:
            remote_ref = "unreachable"
        if remote_ref == "present":
            raise store.AuthorityError("genesis-refused", "genesis refuses: the remote anchor "
                                       "ref exists")
        store_id = secrets.token_hex(16)
        key_dir = f"epoch-1-{secrets.token_hex(8)}"
        boundary = activation_boundary()
        envelope = _envelope("genesis", principal, dict(boundary, remote=remote.url,
                                                        store_id=store_id,
                                                        anchor_class=remote.anchor_class))
        challenge(envelope)
        token = store.begin("authority-genesis", principal)
        try:
            target = {"store_id": store_id, "generation": 1}
            store.bind_keys(token, store_id=store_id, epoch=1, key_dir=key_dir,
                            active_target=target, intent_path=store.GENESIS_INTENT)
            store.create_store_dir(token, store_id=store_id, key_dir=key_dir)
            store.crash("after-store-dir")
            root_pub, subkeys = _create_keys(token, store_id, key_dir)
            store.crash("genesis-step-1")
            body = {
                "ceremony": "genesis",
                "envelope_digest": canonical.digest(envelope),
                "principal": principal,
                "remote": remote.url,
                "anchor_ref": tools.ANCHOR_REF,
                "anchor_class": remote.anchor_class,
                "commit_identity": dict(records.COMMIT_IDENTITY),
                "epoch": 1,
                "key_dir": key_dir,
                "root_pub": root_pub,
                "root_key_id": records.key_id_of_pub(root_pub),
                "subkeys": subkeys,
                "registry_version": envelope["parameters"]["registry_version"],
                "admitted_protocols": envelope["parameters"]["admitted_protocols"],
            }
            registry.validate("authority-genesis", {"store": "absent", "intents": False},
                              {"remote_ref": remote_ref, "store_id": store_id,
                               "remote": remote.url, "root_pub": root_pub,
                               "subkey_types": sorted(subkeys), "types": sorted(records.TYPES)})
            kdir = _key_path(store_id, key_dir)
            prepared = store.prepare_record(
                token, scratch=scratch, record_type="store.genesis", store_id=store_id,
                generation=1, seq=1, prev=None, body=body, signing_epoch=1,
                signing_key_dir=kdir, signing_root_pub=root_pub, pointer_epoch=1,
                pointer_key_dir=kdir, pointer_root_pub=root_pub, genesis_digest=None,
                prev_generation=None, expected_parent=None, offset=0,
                intent_extra={"store_id": store_id, "key_dir": key_dir, "remote": remote.url})
            store.write_genesis_intent(token, data=prepared.intent_bytes)
            store.crash("genesis-step-2")
            store.append_frame(token, store_id=store_id, data=prepared.frame)
            store.crash("genesis-step-3")
            head = store.child(token, "authority-head-advance")
            store.push_anchor(head, scratch=scratch, commit=prepared.anchor_commit,
                              ref=tools.ANCHOR_REF)
            store.crash("genesis-step-4")
            store.readback(token, scratch=scratch, commit=prepared.anchor_commit,
                           anchor_json=prepared.anchor_json, expected_parent=None,
                           root_pub=root_pub)
            store.crash("genesis-step-5")
            store.write_active(token, target=target)
            store.remove_genesis_intent(token)
            store.write_cursor(token, store_id=store_id,
                               data=store.cursor_bytes(store_id, 1, prepared.record_digest,
                                                       prepared.anchor_commit))
        finally:
            store.spend(token)
        return {"result": "genesis", "store_id": store_id, "generation": 1,
                "anchor_commit": prepared.anchor_commit, "anchor_class": remote.anchor_class}
    finally:
        scratch_pool.close()


def _committed_plan(ceremony: str) -> recover.Plan:
    plan = recover.recover()
    if plan.state != "committed" or (plan.row is not None and plan.row != "recovery-tidy"):
        raise store.AuthorityError(f"{ceremony}-refused", f"{ceremony} needs a committed store; "
                                   f"the store is {plan.state}", _exit_for(plan.state))
    if plan.anchor_class == "test" and not tools.test_mode():
        raise store.AuthorityError("test-lineage", "a test lineage needs LOOP_AUTHORITY_TEST=1")
    _guard_test_binaries(plan.anchor_class)
    return plan


def _exit_for(state: str) -> int:
    if state in recover.TERMINAL_STATES:
        return store.EXIT_TERMINAL
    if "pending" in state:
        return store.EXIT_PENDING
    if "quarantined" in state:
        return store.EXIT_QUARANTINED
    return store.EXIT_REFUSED


def _abstract(view: recover.View, plan: recover.Plan) -> dict:
    return {"store": "active", "generation": view.generation,
            "epochs": {str(n): e.state for n, e in view.epochs.items()},
            "active_epoch": view.active_epoch, "quarantined": False, "pending": False,
            "log_seq": view.L, "anchor_seq": view.L, "intent": None, "cursor": view.L}


def rotate(principal: dict) -> dict:
    plan = _committed_plan("rotate")
    view = plan.view
    assert view is not None and view.active_epoch is not None
    old = view.epochs[view.active_epoch]
    new_epoch = max(view.epochs) + 1
    key_dir = f"epoch-{new_epoch}-{secrets.token_hex(8)}"
    envelope = _envelope("rotate", principal, dict(activation_boundary(), store_id=view.store_id,
                                                   generation=view.generation,
                                                   from_epoch=old.n, epoch=new_epoch))
    registry.validate("epoch-rotation", _abstract(view, plan),
                      {"current_epoch": old.n, "epoch": new_epoch, "key_dir_fresh": True,
                       "subkey_types": sorted(records.TYPES), "types": sorted(records.TYPES),
                       "anchor_position": view.L})
    challenge(envelope)
    scratch_pool = recover.Scratch()
    token = store.begin("epoch-rotation", principal)
    try:
        scratch = scratch_pool()
        store.bind_keys(token, store_id=view.store_id, epoch=new_epoch, key_dir=key_dir,
                        active_target=None, intent_path=None)
        store.create_key_dir(token, store_id=view.store_id, key_dir=key_dir)
        store.crash("after-store-dir")
        root_pub, subkeys = _create_keys(token, view.store_id, key_dir)
        body = {
            "ceremony": "rotate",
            "envelope_digest": canonical.digest(envelope),
            "principal": principal,
            "remote": view.remote,
            "from_epoch": old.n,
            "epoch": new_epoch,
            "key_dir": key_dir,
            "root_pub": root_pub,
            "root_key_id": records.key_id_of_pub(root_pub),
            "subkeys": subkeys,
            "registry_version": envelope["parameters"]["registry_version"],
            "admitted_protocols": envelope["parameters"]["admitted_protocols"],
        }
        prepared = store.prepare_record(
            token, scratch=scratch, record_type="epoch.rotated", store_id=view.store_id,
            generation=view.generation, seq=view.L + 1, prev=view.records[-1].digest, body=body,
            signing_epoch=old.n, signing_key_dir=_key_path(view.store_id, old.key_dir),
            signing_root_pub=old.root_pub, pointer_epoch=new_epoch,
            pointer_key_dir=_key_path(view.store_id, key_dir), pointer_root_pub=root_pub,
            genesis_digest=view.genesis_digest, prev_generation=None,
            expected_parent=plan.remote_tip, offset=len(view.data), intent_extra={})
        store.write_intent(token, store_id=view.store_id, data=prepared.intent_bytes)
        store.append_frame(token, store_id=view.store_id, data=prepared.frame)
        _finish_record(token, prepared, scratch, root_pub)
        store.remove_intent(token, store_id=view.store_id)
        store.write_cursor(token, store_id=view.store_id,
                           data=store.cursor_bytes(view.store_id, prepared.seq,
                                                   prepared.record_digest, prepared.anchor_commit))
    finally:
        store.spend(token)
        scratch_pool.close()
    return {"result": "rotated", "store_id": view.store_id, "from_epoch": old.n,
            "epoch": new_epoch, "seq": prepared.seq}


def revoke(principal: dict, epoch: object) -> dict:
    if type(epoch) is not int or epoch < 1:
        raise store.AuthorityError("usage", "revoke needs --epoch <n>", store.EXIT_USAGE)
    plan = _committed_plan("revoke")
    view = plan.view
    assert view is not None and view.active_epoch is not None
    target = view.epochs.get(epoch)
    if target is None or target.state not in ("active", "verify-only"):
        raise store.AuthorityError("revoke-refused", f"epoch {epoch} is not active or verify-only")
    prior = target.state
    registry.validate("epoch-revocation", _abstract(view, plan),
                      {"epoch": epoch, "prior_state": prior, "current_epoch": view.active_epoch,
                       "anchor_position": view.L})
    active = view.epochs[view.active_epoch]
    envelope = _envelope("revoke", principal, {"store_id": view.store_id,
                                               "generation": view.generation, "epoch": epoch,
                                               "prior_state": prior})
    challenge(envelope)
    body = {"ceremony": "revoke", "envelope_digest": canonical.digest(envelope),
            "principal": principal, "epoch": epoch, "prior_state": prior}
    active_dir = _key_path(view.store_id, active.key_dir)
    scratch_pool = recover.Scratch()
    token = store.begin("epoch-revocation", principal)
    try:
        scratch = scratch_pool()
        store.bind_revocation(token, store_id=view.store_id, generation=view.generation,
                              epoch=epoch, prior_state=prior)
        prepared = store.prepare_record(
            token, scratch=scratch, record_type="epoch.revoked", store_id=view.store_id,
            generation=view.generation, seq=view.L + 1, prev=view.records[-1].digest, body=body,
            signing_epoch=active.n, signing_key_dir=active_dir, signing_root_pub=active.root_pub,
            pointer_epoch=active.n, pointer_key_dir=active_dir, pointer_root_pub=active.root_pub,
            genesis_digest=view.genesis_digest, prev_generation=None,
            expected_parent=plan.remote_tip, offset=len(view.data), intent_extra={})
        store.write_intent(token, store_id=view.store_id, data=prepared.intent_bytes)
        store.append_frame(token, store_id=view.store_id, data=prepared.frame)
        _finish_record(token, prepared, scratch, active.root_pub)
        if epoch == active.n:
            # opened only because the bound, observed prior state is active
            quarantine = store.child(token, "store-quarantine")
            store.write_quarantine(quarantine, store_id=view.store_id,
                                   data=store.active_revocation_marker(view.store_id,
                                                                       prepared.seq))
        store.remove_intent(token, store_id=view.store_id)
        store.write_cursor(token, store_id=view.store_id,
                           data=store.cursor_bytes(view.store_id, prepared.seq,
                                                   prepared.record_digest, prepared.anchor_commit))
    finally:
        store.spend(token)
        scratch_pool.close()
    return {"result": "revoked", "store_id": view.store_id, "epoch": epoch,
            "quarantined": epoch == active.n, "seq": prepared.seq}


def regenesis(principal: dict) -> dict:
    for name in (store.GENESIS_INTENT, store.REGENESIS_INTENT):
        if store.exists(store.path(name)):
            raise store.AuthorityError("regenesis-refused", f"re-genesis refuses: {name} exists")
    plan = recover.recover()
    if plan.state != "quarantined" or plan.row is not None or plan.view is None:
        raise store.AuthorityError("regenesis-refused", "linked re-genesis needs a quarantined "
                                   f"store; the store is {plan.state}", _exit_for(plan.state))
    old = plan.view
    if old.anchor_class == "test" and not tools.test_mode():
        raise store.AuthorityError("test-lineage", "re-genesis of a test lineage needs "
                                   "LOOP_AUTHORITY_TEST=1")
    _guard_test_binaries(old.anchor_class)
    remote = recover._pin(old.remote)  # type: ignore[arg-type]
    scratch_pool = recover.Scratch()
    try:
        scratch = scratch_pool()
        try:
            tip, chain = recover._read_remote(scratch, remote)
        except recover.anchor.Unreachable as error:
            raise store.AuthorityError("pending", f"the remote is unreachable: {error}",
                                       store.EXIT_PENDING) from error
        except recover.Invalid as error:
            raise store.AuthorityError("regenesis-unlinkable", error.detail) from error
        if tip is None or chain is None:
            raise store.AuthorityError("regenesis-unlinkable", "the remote anchor ref is absent")
        R = chain[0]
        try:
            if R.active["store_id"] != old.store_id or R.active["generation"] != old.generation:
                raise recover.Invalid("regenesis-unlinkable", "the remote names another store")
            recover._check_history(old, chain, skip_tip=False)
        except recover.Invalid as error:
            raise store.AuthorityError("regenesis-unlinkable", "the remote tip is not a valid "
                                       f"pointer of the quarantined store: {error.detail}") from error
        registry.validate("linked-regenesis",
                          {"store": "active", "quarantined": True, "intents": False},
                          {"remote_tip_valid": True, "lineage": old.anchor_class,
                           "test_mode": tools.test_mode()})
        prev_generation = records.prev_generation_of(R.active)
        new_id = secrets.token_hex(16)
        key_dir = f"epoch-1-{secrets.token_hex(8)}"
        generation = old.generation + 1
        envelope = _envelope("regenesis", principal, dict(activation_boundary(),
                                                          old_store_id=old.store_id,
                                                          old_generation=old.generation,
                                                          new_store_id=new_id,
                                                          generation=generation))
        challenge(envelope)
        target = {"store_id": new_id, "generation": generation}
        token = store.begin("linked-regenesis", principal)
        try:
            store.bind_keys(token, store_id=new_id, epoch=1, key_dir=key_dir,
                            active_target=target, intent_path=store.REGENESIS_INTENT)
            store.bind_regenesis(token, old_store_id=old.store_id)
            store.create_store_dir(token, store_id=new_id, key_dir=key_dir)
            root_pub, subkeys = _create_keys(token, new_id, key_dir)
            body = {
                "ceremony": "regenesis",
                "envelope_digest": canonical.digest(envelope),
                "principal": principal,
                "remote": old.remote,
                "anchor_ref": tools.ANCHOR_REF,
                "anchor_class": old.anchor_class,
                "commit_identity": dict(records.COMMIT_IDENTITY),
                "epoch": 1,
                "key_dir": key_dir,
                "root_pub": root_pub,
                "root_key_id": records.key_id_of_pub(root_pub),
                "subkeys": subkeys,
                "prev_generation": prev_generation,
                "prev_commit": tip,
                "quarantined": {"last_seq": old.L,
                                "last_record_digest": old.records[-1].digest},
                "archive": "archive/" + old.store_id,
                "registry_version": envelope["parameters"]["registry_version"],
                "admitted_protocols": envelope["parameters"]["admitted_protocols"],
            }
            kdir = _key_path(new_id, key_dir)
            prepared = store.prepare_record(
                token, scratch=scratch, record_type="store.regenesis", store_id=new_id,
                generation=generation, seq=1, prev=None, body=body, signing_epoch=1,
                signing_key_dir=kdir, signing_root_pub=root_pub, pointer_epoch=1,
                pointer_key_dir=kdir, pointer_root_pub=root_pub, genesis_digest=None,
                prev_generation=prev_generation, expected_parent=tip, offset=0,
                intent_extra={"old": prev_generation, "old_commit": tip, "new_store_id": new_id,
                              "key_dir": key_dir, "archive": "archive/" + old.store_id,
                              "remote": old.remote})
            store.write_regenesis_intent(token, data=prepared.intent_bytes)
            store.crash("regenesis-step-1")
            store.append_frame(token, store_id=new_id, data=prepared.frame)
            store.crash("regenesis-step-2")
            _finish_record(token, prepared, scratch, root_pub)
            store.crash("regenesis-step-3")
            store.archive_store(token, store_id=old.store_id)
            store.crash("regenesis-step-4")
            store.write_active(token, target=target)
            store.remove_regenesis_intent(token)
            store.crash("regenesis-step-5")
            store.write_cursor(token, store_id=new_id,
                               data=store.cursor_bytes(new_id, 1, prepared.record_digest,
                                                       prepared.anchor_commit))
        finally:
            store.spend(token)
        return {"result": "regenesis", "store_id": new_id, "generation": generation,
                "archived": old.store_id, "anchor_class": old.anchor_class}
    finally:
        scratch_pool.close()
