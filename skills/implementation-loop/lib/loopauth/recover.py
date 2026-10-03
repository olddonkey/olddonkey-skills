"""Verification and recovery of the authority store (A1.2, A1.3, A1.6, A2.3,
A2.4; task-graph-v1 Phase A, sub-unit 0a.2).

observe() classifies the current state without changing anything: a
genesis.intent first (A2.3 bootstrap, local state before the remote), then a
regenesis.intent (A1.3 step 1 of recovery), then the active store: its
lineage and log to the last valid frame L, its tail against the write intent
(A1.6), its published key files, and only then the remote anchor R, checked
by content, signature, and chain before any row of the A1.2 table applies.
It returns a Plan naming the state and, when a row applies, that row.

recover() runs plans until the state is stable, minting each row's token
only after observing and validating the state that triggers it (A1.5), so
status, verify, and the ceremonies share one classification. A token is
minted from nothing but an issued plan, once: the store spends it through
redeem(), which requires the local state the plan observed and a fresh
observation of the files and the remote deciding the same plan.
"""

from __future__ import annotations

import base64
import os

from . import anchor, canonical, frame, keys, records, registry, store, tools

TERMINAL_STATES = ("genesis-invalid", "anchor-mismatch", "genesis-quarantined")
INTENT_KEYS = ("seq", "offset", "length", "digest", "expected_parent", "anchor_json",
               "anchor_commit", "frame_length", "frame_b64")
GENESIS_INTENT_KEYS = INTENT_KEYS + ("store_id", "key_dir", "remote")
REGENESIS_INTENT_KEYS = INTENT_KEYS + ("old", "old_commit", "new_store_id", "key_dir", "archive",
                                       "remote")


class Invalid(Exception):
    def __init__(self, rule: str, detail: str) -> None:
        super().__init__(detail)
        self.rule = rule
        self.detail = detail


# ---------------------------------------------------------------------------
# Store views: a log verified to its last valid frame
# ---------------------------------------------------------------------------

class Epoch:
    __slots__ = ("n", "root_pub", "root_key_id", "key_dir", "subkeys", "state", "seq",
                 "registry_version", "protocols")

    def __init__(self, n: int, body: dict, seq: int) -> None:
        self.n = n
        self.root_pub = body["root_pub"]
        self.root_key_id = body["root_key_id"]
        self.key_dir = body["key_dir"]
        self.subkeys = body["subkeys"]
        self.state = "active"
        self.seq = seq
        self.registry_version = body["registry_version"]
        self.protocols = tuple(body["admitted_protocols"])


class Record:
    __slots__ = ("frame", "payload", "sig", "digest", "pointer_epoch")


class View:
    """A store's log verified record by record. records[k-1] is record k;
    L = len(records). error names the first complete frame that failed."""

    def __init__(self, store_id: str, generation: int, directory: str, archived: bool) -> None:
        self.store_id = store_id
        self.generation = generation
        self.directory = directory
        self.archived = archived
        self.data = b""
        self.records: list[Record] = []
        self.epochs: dict[int, Epoch] = {}
        self.active_epoch: int | None = None
        self.revoked_active = False
        self.remote: str | None = None
        self.anchor_class: str | None = None
        self.error: tuple[int, str, str] | None = None
        self.tail = b""
        self.tail_offset = 0
        self.tail_error: str | None = None
        self.ancestors: list[View] = []

    @property
    def L(self) -> int:
        return len(self.records)

    @property
    def genesis_digest(self) -> str | None:
        return self.records[0].digest if self.records else None

    def ptr(self, k: int) -> dict:
        record = self.records[k - 1]
        epoch = self.epochs[record.pointer_epoch]
        return {
            "store_id": self.store_id,
            "generation": self.generation,
            "genesis_digest": self.records[0].digest,
            "seq": k,
            "record_digest": record.digest,
            "epoch": record.pointer_epoch,
            "key_id": epoch.root_key_id,
        }

    def clone(self) -> "View":
        other = View(self.store_id, self.generation, self.directory, self.archived)
        other.data = self.data
        other.records = list(self.records)
        other.epochs = {n: _copy_epoch(e) for n, e in self.epochs.items()}
        other.active_epoch = self.active_epoch
        other.revoked_active = self.revoked_active
        other.remote = self.remote
        other.anchor_class = self.anchor_class
        other.ancestors = self.ancestors
        return other


def _copy_epoch(epoch: Epoch) -> Epoch:
    copy = Epoch.__new__(Epoch)
    for name in Epoch.__slots__:
        setattr(copy, name, getattr(epoch, name))
    return copy


# The rules of the activation boundary (A2.1, A2.6), reported as themselves.
BOUNDARY_RULES = ("type-not-admitted", "introducer-version", "introducer-protocols",
                  "introducer-types")


def _boundary(error: records.RecordError) -> Invalid:
    rule = error.code if error.code in BOUNDARY_RULES + ("anchor-class",) else "record-schema"
    return Invalid(rule, error.message)


def _predecessor(view: View) -> tuple | None:
    """(registry_version, protocols) of the epoch a store.regenesis follows:
    the latest epoch of the archived generation it links to."""
    if view.generation == 1 or not view.ancestors or not view.ancestors[0].epochs:
        return None
    ancestor = view.ancestors[0]
    epoch = ancestor.epochs[max(ancestor.epochs)]
    return epoch.registry_version, epoch.protocols


def apply_frame(view: View, fr: frame.Frame, lineage_remote: str | None) -> Record:
    """Validate one complete frame as record L + 1 of view (digest was
    checked by the parser): content and envelope; chain; type admission by
    the epoch introducer's registry version -- before any body schema --
    then the body, the introducer's activation boundary, seal, key_id, and
    the body's semantics; then apply it."""
    try:
        payload, sig = records.parse_content(fr.content)
        records.check_envelope(payload)
    except records.RecordError as error:
        raise Invalid("record-schema", error.message) from error
    seq = view.L + 1
    kind = payload["type"]
    body = payload["body"]
    if kind != fr.type or payload["seq"] != seq or fr.seq != seq:
        raise Invalid("record-header", "frame header and payload disagree")
    if payload["store_id"] != view.store_id or payload["generation"] != view.generation:
        raise Invalid("record-store", "record names another store or generation")
    if payload["prev"] != (view.records[-1].digest if view.records else None):
        raise Invalid("record-chain", "prev is not the previous record's digest")
    first_type = "store.genesis" if view.generation == 1 else "store.regenesis"
    if seq == 1:
        if kind != first_type:
            raise Invalid("record-admission", f"record 1 of generation {view.generation} must be "
                          f"{first_type}")
    else:
        introducer = view.epochs.get(payload["epoch"])
        if introducer is None:
            raise Invalid("record-epoch", f"epoch {payload['epoch']} was never introduced")
        if not records.type_admitted(introducer.registry_version, kind):
            raise Invalid("type-not-admitted", f"{kind} is not admitted by epoch "
                          f"{introducer.n}'s registry version {introducer.registry_version}")
    try:
        records.check_body(kind, body, remote_check=tools.anchor_class_of)
    except records.RecordError as error:
        raise _boundary(error) from error
    except tools.ToolError as error:
        raise Invalid("record-schema", error.message) from error
    if view.revoked_active:
        raise Invalid("record-after-quarantine", "a record follows the active epoch's revocation")
    if seq == 1:
        if payload["epoch"] != 1:
            raise Invalid("record-epoch", "record 1 is sealed by epoch 1")
        if not records.type_admitted(body["registry_version"], kind):
            raise Invalid("type-not-admitted", f"{kind} is not admitted by its own registry "
                          f"version {body['registry_version']}")
        try:
            records.check_succession(body["registry_version"], tuple(body["admitted_protocols"]),
                                     _predecessor(view), same_generation=False)
        except records.RecordError as error:
            raise _boundary(error) from error
        if view.generation == 1:
            lineage_remote = body["remote"]
        elif body["remote"] != lineage_remote:
            raise Invalid("record-remote", "store.regenesis names another remote")
        epoch_info = Epoch(1, body, 1)
        root_pub = body["root_pub"]
        subkeys = body["subkeys"]
    else:
        if kind not in ("epoch.rotated", "epoch.revoked"):
            raise Invalid("record-admission", f"{kind} is not admissible after record 1")
        if view.active_epoch is None or payload["epoch"] != view.active_epoch:
            raise Invalid("record-epoch", "record is not sealed by the active epoch")
        epoch_info = None
        current = view.epochs[view.active_epoch]
        root_pub = current.root_pub
        subkeys = current.subkeys
        if kind == "epoch.rotated":
            try:
                records.check_succession(body["registry_version"],
                                         tuple(body["admitted_protocols"]),
                                         (current.registry_version, current.protocols),
                                         same_generation=True)
            except records.RecordError as error:
                raise _boundary(error) from error
    try:
        key_id = keys.verify_seal(record_type=kind, epoch=payload["epoch"], root_pub=root_pub,
                                  payload=records.payload_bytes(payload), sig=sig)
    except keys.KeyFileError as error:
        raise Invalid("record-seal", error.message) from error
    if key_id != payload["key_id"]:
        raise Invalid("record-key-id", "payload key_id is not the certificate that verified it")
    if subkeys[kind] != key_id:
        raise Invalid("record-key-id", "the sealing subkey is not the epoch's subkey for the type")
    new = view
    if seq == 1:
        new.epochs[1] = epoch_info  # type: ignore[assignment]
        new.active_epoch = 1
        new.remote = lineage_remote
        new.anchor_class = tools.anchor_class_of(lineage_remote)  # type: ignore[arg-type]
        pointer_epoch = 1
    elif kind == "epoch.rotated":
        if body["remote"] != view.remote:
            raise Invalid("record-remote", "rotation names another remote")
        if body["from_epoch"] != view.active_epoch or body["epoch"] != max(view.epochs) + 1:
            raise Invalid("record-epoch", "rotation must go from the active epoch to the next")
        if any(e.key_dir == body["key_dir"] for e in view.epochs.values()):
            raise Invalid("record-schema", "rotation reuses a key directory")
        old = view.epochs[view.active_epoch]  # type: ignore[index]
        old.state = registry.epoch_transition(old.state, "verify-only")
        new.epochs[body["epoch"]] = Epoch(body["epoch"], body, seq)
        new.active_epoch = body["epoch"]
        pointer_epoch = body["epoch"]
    else:
        target = view.epochs.get(body["epoch"])
        if target is None or target.state != body["prior_state"]:
            raise Invalid("record-epoch", "revocation names an epoch not in its prior state")
        try:
            target.state = registry.epoch_transition(target.state, "revoked")
        except registry.RowRefused as error:
            raise Invalid("record-epoch", error.message) from error
        pointer_epoch = view.active_epoch  # type: ignore[assignment]
        if body["epoch"] == view.active_epoch:
            new.active_epoch = None
            new.revoked_active = True
    record = Record()
    record.frame = fr
    record.payload = payload
    record.sig = sig
    record.digest = fr.digest
    record.pointer_epoch = pointer_epoch
    new.records.append(record)
    return record


def peek_first_record(directory: str) -> dict | None:
    data = store.read_file(store.log_path(directory), missing_ok=True)
    if not data:
        return None
    parsed = frame.parse_log(data)
    if not parsed.frames:
        return None
    try:
        payload, _sig = records.parse_content(parsed.frames[0].content)
    except records.RecordError:
        return None
    return payload if type(payload) is dict else None


def load_view(store_id: str, generation: int, *, archived: bool = False,
              depth: int = 0) -> View:
    """Load and verify a store and, for generation > 1, its archived
    ancestors down to generation 1 (the lineage's pinned remote)."""
    if depth > 64:
        raise Invalid("lineage", "lineage too deep")
    directory = store.archive_dir(store_id) if archived else store.store_dir(store_id)
    if not store.check_dir(directory, missing_ok=True):
        raise Invalid("store-missing", f"store directory missing: {directory}")
    view = View(store_id, generation, directory, archived)
    lineage_remote = None
    if generation > 1:
        first = peek_first_record(directory)
        body = first.get("body") if first else None
        prev = body.get("prev_generation") if type(body) is dict else None
        if type(prev) is not dict or type(prev.get("store_id")) is not str:
            raise Invalid("lineage", "the re-genesis record does not name its previous store")
        try:
            records.check_prev_generation(prev)
        except records.RecordError as error:
            raise Invalid("lineage", error.message) from error
        if prev["generation"] != generation - 1:
            raise Invalid("lineage", "the previous generation is not generation - 1")
        ancestor = load_view(prev["store_id"], generation - 1, archived=True, depth=depth + 1)
        check_archived_ancestor(ancestor)
        view.ancestors = [ancestor] + ancestor.ancestors
        lineage_remote = ancestor.remote
    data = store.read_file(store.log_path(directory))
    assert data is not None
    view.data = data
    parsed = frame.parse_log(data)
    for fr in parsed.frames:
        try:
            apply_frame(view, fr, lineage_remote)
        except Invalid as error:
            view.error = (fr.seq, error.rule, error.detail)
            view.tail_offset = fr.offset
            view.tail = data[fr.offset:]
            return view
        except tools.ToolError as error:
            raise store.AuthorityError("environment", error.message, store.EXIT_ENV) from error
    view.tail_offset = parsed.tail_offset
    view.tail = parsed.tail
    view.tail_error = parsed.tail_error
    if generation > 1 and view.records:
        _check_link(view)
    return view


def check_archived_ancestor(ancestor: View) -> None:
    """An archived generation is history. Its valid prefix -- every record
    up to the first complete-but-invalid frame or nonconforming tail, which
    is what quarantined it -- must verify; that discarded tail need not. It
    must carry the quarantine marker linked re-genesis relied on (the
    evidence). The re-genesis record's link and its `quarantined` field are
    then checked against this prefix (_check_link)."""
    if ancestor.L == 0:
        raise Invalid("lineage", "an archived ancestor has no valid record")
    if _marker(ancestor) is None:
        raise Invalid("lineage", "an archived ancestor carries no quarantine marker")


def _check_link(view: View) -> None:
    """A store.regenesis record links to exactly its archived ancestor: the
    pointer it names is a record of the ancestor's valid prefix, and its
    quarantine evidence names that prefix's last record."""
    body = view.records[0].payload["body"]
    ancestor = view.ancestors[0]
    prev = body["prev_generation"]
    if prev["store_id"] != ancestor.store_id or prev["generation"] != ancestor.generation:
        view.error = (1, "lineage", "the re-genesis record names another store")
        return
    if not 1 <= prev["last_seq"] <= ancestor.L or \
            ancestor.records[prev["last_seq"] - 1].digest != prev["last_record_digest"]:
        view.error = (1, "lineage", "the re-genesis record's link is not the ancestor's record")
        return
    if body["quarantined"] != {"last_seq": ancestor.L,
                               "last_record_digest": ancestor.records[-1].digest}:
        view.error = (1, "lineage", "the re-genesis record's quarantine evidence is not the "
                      "ancestor's valid prefix")
        return
    if body["remote"] != ancestor.remote:
        view.error = (1, "record-remote", "re-genesis changed the remote")


def epoch_key_files(view: View) -> dict[int, dict[str, bytes]]:
    result = {}
    for n, epoch in view.epochs.items():
        directory = os.path.join(view.directory, "keys", epoch.key_dir)
        if not store.check_dir(directory, missing_ok=True):
            raise Invalid("key-file", f"published key directory missing: {epoch.key_dir}")
        files = {}
        for name in store.list_dir(directory):
            if name.startswith(".tmp-"):
                continue
            data = store.read_file(os.path.join(directory, name))
            files[name] = data
        result[n] = files  # type: ignore[assignment]
    return result


def check_key_files(view: View) -> None:
    """A1.7: every key directory an epoch record names holds exactly the
    root and one certified subkey per type, matching the record."""
    expected = {"root", "root.pub"}
    for name in records.TYPES:
        expected |= {name, f"{name}.pub", f"{name}-cert.pub"}
    for n, files in epoch_key_files(view).items():
        epoch = view.epochs[n]
        extra = set(files) - expected
        if extra:
            raise Invalid("key-file", f"unexpected files in {epoch.key_dir}: {sorted(extra)}")
        try:
            keys.check_epoch_files(files, epoch=n, root_pub=epoch.root_pub, subkeys=epoch.subkeys)
        except keys.KeyFileError as error:
            raise Invalid("key-file", f"{epoch.key_dir}: {error.message}") from error
        except records.RecordError as error:
            raise Invalid("key-file", f"{epoch.key_dir}: {error.message}") from error


def unpublished(view: View | None) -> dict:
    """Key directories no epoch record names, and store directories no
    marker or intent names: reported, never read."""
    result: dict = {"key_dirs": [], "stores": []}
    if view is not None and not view.archived:
        named = {e.key_dir for e in view.epochs.values()}
        keys_dir = os.path.join(view.directory, "keys")
        if store.check_dir(keys_dir, missing_ok=True):
            result["key_dirs"] = [name for name in store.list_dir(keys_dir) if name not in named]
    return result


# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------

def parse_json(data: bytes, keys_expected: tuple, what: str) -> dict:
    try:
        value = canonical.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, canonical.CanonicalError) as error:
        raise Invalid(f"{what}-unparsable", f"{what} is not canonical JSON: {error}") from error
    if type(value) is not dict or set(value) != set(keys_expected):
        raise Invalid(f"{what}-schema", f"{what} fields are not exactly {sorted(keys_expected)}")
    if canonical.canonical(value) != data:
        raise Invalid(f"{what}-schema", f"{what} is not in canonical form")
    return value


def check_intent_fields(intent: dict) -> tuple[frame.Frame, bytes, dict, dict | None, str]:
    """Schema and A1.6 internal consistency of an intent. Returns the frame,
    its bytes, and the parsed anchor_json."""
    for name in ("seq", "offset", "length", "frame_length"):
        if type(intent[name]) is not int or intent[name] < 0:
            raise Invalid("intent-schema", f"intent {name} must be a non-negative integer")
    if intent["seq"] < 1 or not canonical.is_digest(intent["digest"]):
        raise Invalid("intent-schema", "intent seq or digest malformed")
    if intent["expected_parent"] is not None and (
            type(intent["expected_parent"]) is not str
            or not tools.OID_RE.fullmatch(intent["expected_parent"])):
        raise Invalid("intent-schema", "intent expected_parent malformed")
    if type(intent["anchor_commit"]) is not str or not tools.OID_RE.fullmatch(intent["anchor_commit"]):
        raise Invalid("intent-schema", "intent anchor_commit malformed")
    if type(intent["anchor_json"]) is not str or type(intent["frame_b64"]) is not str:
        raise Invalid("intent-schema", "intent anchor_json and frame_b64 are strings")
    try:
        parsed = store.check_intent_consistency(intent)
    except store.AuthorityError as error:
        raise Invalid("intent-inconsistent", error.message) from error
    frame_bytes = base64.b64decode(intent["frame_b64"])
    active, prev, sig = records.parse_anchor_json(intent["anchor_json"].encode("utf-8"))
    return parsed, frame_bytes, active, prev, sig


def validate_candidate(view: View, frame_bytes: bytes) -> tuple[View, Record]:
    """Validate intent frame bytes as record L + 1 of view (digest,
    signature, chain, admission) on a copy of the view."""
    try:
        fr = frame.split_frame(frame_bytes, view.L + 1)
    except frame.FrameError as error:
        raise Invalid("candidate", error.message) from error
    extended = view.clone()
    record = apply_frame(extended, fr, view.remote)
    return extended, record


def classify_tail(tail: bytes, tail_error: str | None, tail_offset: int, L: int,
                  intent: dict | None, intent_frame: bytes | None) -> str | None:
    """A1.6's tail cases, tested in order, for the bytes after the last
    complete valid frame L. None: no tail. "unterminated": exactly the
    intent's frame for L + 1 minus its final newline. "torn": the intent is
    for exactly L + 1 at exactly this offset and the file ends strictly
    before the end of the header and payload -- and the bytes are a prefix
    of the intent's frame. Everything else is "nonconforming"."""
    if not tail:
        return None
    if tail_error is not None or intent is None or intent_frame is None \
            or intent.get("seq") != L + 1 or intent.get("offset") != tail_offset:
        return "nonconforming"
    if tail == intent_frame[:-1]:
        return "unterminated"
    if len(tail) < len(intent_frame) - 1 and intent_frame.startswith(tail):
        return "torn"
    return "nonconforming"


def verify_pointer_for(view: View, active: dict, prev: dict | None, sig: str) -> None:
    epoch = view.epochs.get(active["epoch"])
    if epoch is None or epoch.root_key_id != active["key_id"]:
        raise Invalid("anchor-signature", "the pointer names an epoch root this store never had")
    try:
        keys.verify_pointer(root_pub=epoch.root_pub, pointer=records.pointer_bytes(active, prev),
                            sig=sig)
    except keys.KeyFileError as error:
        raise Invalid("anchor-signature", error.message) from error


# ---------------------------------------------------------------------------
# Plans
# ---------------------------------------------------------------------------

class Plan:
    def __init__(self, state: str, *, row: str | None = None, table: str = "", detail: str = "",
                 view: View | None = None, **params: object) -> None:
        self.state = state
        self.row = row
        self.table = table
        self.detail = detail
        self.view = view
        self.params = params
        self.remote_tip: str | None = None
        # True once the remote was read and verified by content (the tip, or
        # an absent ref); a plan decided before reading it binds nothing
        # remote.
        self.remote_read = False
        self.anchor_class: str | None = None
        self.lineage_remote: str | None = None
        self.named: set[str] = set()
        self.steps: list | None = None

    def summary(self) -> dict:
        view = self.view
        test_only = self.anchor_class == "test" or tools.test_binaries_in_use()
        # A cursor never decides anything (A1.2): a cursor-only tidy leaves
        # a committed store's authorization unchanged.
        cursor_only = self.row == "recovery-tidy" and self.params.get("intent") is None
        # authorizing_state: the state would authorize if the lineage were
        # production; a test lineage (or test binaries) never does.
        authorizing = self.state == "committed" and (self.row is None or cursor_only)
        out = {
            "state": self.state,
            "row": self.row,
            "table": self.table,
            "detail": self.detail,
            "anchor_class": self.anchor_class,
            "test_only": test_only,
            "authorizing_state": authorizing,
            "current_authorization": authorizing and not test_only,
            "remote_tip": self.remote_tip,
        }
        leftovers = unpublished(view)
        named = set(self.named) | ({view.store_id} if view is not None else set())
        try:
            if store.check_dir(store.path("stores"), missing_ok=True):
                leftovers["stores"] = [name for name in store.list_dir(store.path("stores"))
                                       if name not in named]
        except store.AuthorityError:
            leftovers["stores"] = ["<unreadable>"]
        out["unpublished"] = leftovers
        if view is not None:
            out.update({
                "store_id": view.store_id,
                "generation": view.generation,
                "seq": view.L,
                "active_epoch": view.active_epoch,
                "epochs": {str(n): e.state for n, e in sorted(view.epochs.items())},
            })
        evidence = self.params.get("evidence")
        if evidence is not None:
            out["evidence"] = evidence
        rule = self.params.get("rule")
        if rule is None and type(evidence) is dict:
            rule = evidence.get("rule")
        out["rule"] = rule
        if self.steps is not None:
            # recover: each row it ran, first the classification of the state
            # it found.
            out["steps"] = self.steps
        return out


def _quarantine(view: View, rule: str, detail: str, table: str, position: dict | None) -> Plan:
    return Plan("quarantined", row="store-quarantine", table=table, detail=detail, view=view,
                store_id=view.store_id, rule=rule, position=position)


def _pin(url: str) -> tools.Remote:
    """Pin the lineage's remote. Classification may read a production
    lineage with test binaries (it then reports test_only and nothing
    authorizes); every mutation refuses that combination
    (tools.refuse_test_binaries, in recover() and the ceremonies)."""
    remote = tools.parse_remote(url, allow_test=True)
    tools.pin_remote(remote)
    return remote


def _read_remote(scratch: str, remote: tools.Remote) -> tuple[str | None, list | None]:
    """(tip, chain) with the chain verified by content and structure; raises
    anchor.Unreachable, or Invalid for a chain that fails."""
    tip = anchor.ls_remote(scratch, remote.url)
    if tip is None:
        return None, None
    fetched = anchor.fetch(scratch, remote.url)
    if fetched != tip:
        raise anchor.Unreachable("the remote anchor moved while it was read")
    try:
        chain = anchor.walk_chain(scratch, tip)
    except anchor.AnchorError as error:
        raise Invalid("anchor-chain", error.message) from error
    return tip, chain


def _views_by_generation(view: View) -> dict:
    return {v.generation: v for v in [view] + view.ancestors}


def _check_history(view: View, chain: list, *, skip_tip: bool) -> None:
    """Every anchored pointer below the tip matches the local record it
    names in the lineage, and every pointer signature verifies under the
    root that store's history designates for it."""
    by_gen = _views_by_generation(view)
    for index, entry in enumerate(chain):
        active = entry.active
        owner = by_gen.get(active["generation"])
        if owner is None or owner.store_id != active["store_id"]:
            if index == 0 and skip_tip:
                continue
            raise Invalid("anchor-history", "an anchored pointer names a store not in the lineage")
        if index == 0 and skip_tip:
            continue
        if active["seq"] > owner.L or owner.ptr(active["seq"]) != active:
            raise Invalid("anchor-history", f"anchored pointer g{active['generation']} "
                          f"s{active['seq']} differs from the local record")
        verify_pointer_for(owner, active, entry.prev_generation, entry.sig)


def observe(scratch_factory) -> Plan:
    """Classify the current state. scratch_factory() returns a fresh scratch
    repository; nothing is written to the authority directory. The plan is
    issued: only an issued, unaltered plan can mint a token (_mint)."""
    return _issue(_observe(scratch_factory))


def _observe(scratch_factory) -> Plan:
    if not store.exists(store.root()):
        return Plan("none", table="no authority directory")
    genesis_intent = store.read_file(store.path(store.GENESIS_INTENT), missing_ok=True)
    if genesis_intent is not None:
        return observe_bootstrap(genesis_intent, scratch_factory)
    regenesis_intent = store.read_file(store.path(store.REGENESIS_INTENT), missing_ok=True)
    if regenesis_intent is not None:
        return observe_regenesis(regenesis_intent, scratch_factory)
    active_bytes = store.read_file(store.path(store.ACTIVE), missing_ok=True)
    if active_bytes is None:
        return Plan("none", table="no active store")
    try:
        active = parse_json(active_bytes, ("store_id", "generation"), "active")
        if not records.STORE_ID_RE.fullmatch(str(active["store_id"])) or \
                type(active["generation"]) is not int or active["generation"] < 1:
            raise Invalid("active-schema", "active marker malformed")
    except Invalid as error:
        return Plan("active-invalid", table="active marker", detail=error.detail)
    return observe_store(active["store_id"], active["generation"], scratch_factory)


def observe_store(store_id: str, generation: int, scratch_factory) -> Plan:
    try:
        view = load_view(store_id, generation)
    except Invalid as error:
        plan = Plan("active-invalid", table="lineage", detail=error.detail)
        return plan
    plan = _observe_view(view, scratch_factory)
    plan.view = view
    plan.anchor_class = view.anchor_class
    plan.lineage_remote = view.remote
    return plan


def _marker(view: View) -> dict | None:
    data = store.read_file(os.path.join(view.directory, "quarantine"), missing_ok=True)
    if data is None:
        return None
    try:
        value = canonical.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, canonical.CanonicalError):
        value = {"rule": "unreadable"}
    return value if type(value) is dict else {"rule": "unreadable"}


def _observe_view(view: View, scratch_factory) -> Plan:
    marker = _marker(view)
    if marker is not None:
        return Plan("quarantined", table="quarantine marker", detail=str(marker.get("rule")),
                    view=view, evidence=marker)
    if view.error is not None:
        seq, rule, detail = view.error
        return _quarantine(view, rule, detail, "A1.6 complete-but-invalid frame",
                           {"seq": seq, "offset": view.tail_offset})
    if view.L == 0:
        return _quarantine(view, "empty-log", "the active store has no valid record 1", "A1.6",
                           {"seq": 1, "offset": 0})
    try:
        check_key_files(view)
    except Invalid as error:
        return _quarantine(view, error.rule, error.detail, "A1.7 key file", None)
    L = view.L
    intent_bytes = store.read_file(os.path.join(view.directory, "intent"), missing_ok=True)
    intent_digest = store.sha256(intent_bytes) if intent_bytes is not None else None
    intent = None
    intent_frame = None
    if intent_bytes is not None:
        try:
            intent = parse_json(intent_bytes, INTENT_KEYS, "intent")
            fr, intent_frame, i_active, i_prev, i_sig = check_intent_fields(intent)
        except Invalid as error:
            return _quarantine(view, error.rule, error.detail, "A1.6 intent", None)
        if intent["seq"] not in (L, L + 1):
            return _quarantine(view, "intent-sequence", f"intent for seq {intent['seq']} with L = {L}",
                               "A1.2 stray intent", {"seq": intent["seq"]})
    # --- the tail (A1.6), local only
    tail_kind = classify_tail(view.tail, view.tail_error, view.tail_offset, L, intent,
                              intent_frame)
    extended = None
    if tail_kind == "nonconforming":
        return _quarantine(view, "tail-nonconforming", view.tail_error or "a short tail without "
                           "a matching intent, or not a prefix of the intent's frame",
                           "A1.6 everything else", {"seq": L + 1, "offset": view.tail_offset})
    if tail_kind is not None:
        try:
            extended, _record = validate_candidate(view, intent_frame)  # type: ignore[arg-type]
        except Invalid as error:
            return _quarantine(view, error.rule, error.detail, f"A1.6 {tail_kind}, intent frame "
                               "invalid", {"seq": L + 1, "offset": view.tail_offset})
    elif intent is not None:
        if intent["seq"] == L + 1:
            if intent["offset"] != len(view.data):
                return _quarantine(view, "intent-offset", "an intent for L + 1 not at the end of "
                                   "the log", "A1.2 stray intent", {"seq": L + 1})
            try:
                extended, _record = validate_candidate(view, intent_frame)  # type: ignore[arg-type]
            except Invalid as error:
                return _quarantine(view, error.rule, error.detail, "A1.6 intent frame invalid",
                                   {"seq": L + 1})
        else:
            record = view.records[L - 1]
            if (intent["offset"] != record.frame.offset or intent["length"] != record.frame.length
                    or intent["digest"] != record.digest
                    or intent_frame != view.data[record.frame.offset:record.frame.end]):
                return _quarantine(view, "intent-mismatch", "an intent for L that is not frame L "
                                   "exactly", "A1.2 intent for L", {"seq": L})
            extended = view
    if intent is not None:
        owner = extended if extended is not None else view
        try:
            if i_active["seq"] <= owner.L and owner.ptr(i_active["seq"]) != i_active:  # type: ignore[has-type]
                raise Invalid("intent-pointer", "the intent's pointer is not ptr(seq)")
            verify_pointer_for(owner, i_active, i_prev, i_sig)  # type: ignore[has-type]
            if i_prev is not None:  # type: ignore[has-type]
                raise Invalid("intent-pointer", "only a generation's first pointer links back")
        except Invalid as error:
            return _quarantine(view, error.rule, error.detail, "A1.6 intent pointer", None)
    # --- the remote
    remote = _pin(view.remote)  # type: ignore[arg-type]
    scratch = scratch_factory()
    try:
        tip, chain = _read_remote(scratch, remote)
    except anchor.Unreachable as error:
        plan = Plan("pending", table="A1.2 remote unreachable", detail=str(error)[:300], view=view)
        return plan
    except Invalid as error:
        return _quarantine(view, error.rule, error.detail, "A1.2 step 3", None)
    except anchor.AnchorError as error:
        return _quarantine(view, "anchor-chain", error.message, "A1.2 step 3", None)
    if tip is None:
        plan = _quarantine(view, "anchor-absent", "the anchor ref is absent after genesis",
                           "A2.3 absent ref once active exists", None)
        plan.remote_read = True
        return plan
    assert chain is not None
    R = chain[0]
    if R.active["store_id"] != view.store_id or R.active["generation"] != view.generation:
        plan = _quarantine(view, "anchor-foreign", "R names another store or generation",
                           "A1.2 other store_id or generation", None)
        plan.remote_tip, plan.remote_read = tip, True
        return plan
    try:
        _check_history(view, chain, skip_tip=True)
        verify_pointer_for(view if R.active["seq"] <= L else (extended or view), R.active,
                           R.prev_generation, R.sig)
    except Invalid as error:
        plan = _quarantine(view, error.rule, error.detail, "A1.2 step 3", None)
        plan.remote_tip, plan.remote_read = tip, True
        return plan
    plan = _table(view, extended, intent, tail_kind, R, tip)
    plan.params.setdefault("intent_digest", intent_digest)
    plan.remote_tip, plan.remote_read = tip, True
    return plan


def _table(view: View, extended: View | None, intent: dict | None, tail_kind: str | None,
           R: anchor.ChainEntry, tip: str) -> Plan:
    L = view.L
    rseq = R.active["seq"]
    if tail_kind == "torn":
        if rseq == L + 1:
            return _quarantine(view, "remote-names-torn", "the remote names a frame that is torn "
                               "locally", "A1.6 torn with remote naming seq", {"seq": L + 1})
        return Plan("needs-recovery", row="torn-frame-truncation", table="A1.6 torn", view=view,
                    store_id=view.store_id, offset=intent["offset"], intent=intent,  # type: ignore[index]
                    remote_seq=rseq)
    if tail_kind == "unterminated":
        assert extended is not None and intent is not None
        if R.active == view.ptr(L) and tip == intent["expected_parent"]:
            return Plan("pending", row="anchor-replay-forward", table="A1.6 unterminated, remote "
                        "old", view=view, store_id=view.store_id, intent=intent,
                        unterminated=True, remote_seq=rseq)
        if rseq == L + 1:
            return _quarantine(view, "remote-new-unterminated", "the remote names a frame that is "
                               "not complete locally", "A1.6 unterminated, remote new",
                               {"seq": L + 1})
        return _quarantine(view, "rollback", "the remote is not the previous pointer",
                           "A1.2 rollback", {"seq": L + 1})
    if rseq == L and R.active != view.ptr(L):
        return _quarantine(view, "fork", "a different pointer at the same sequence",
                           "A1.2 same-sequence fork", {"seq": L})
    if R.active == view.ptr(L):
        if intent is not None:
            if intent["seq"] == L:
                if tip != intent["anchor_commit"] or R.parent != intent["expected_parent"]:
                    return _quarantine(view, "intent-commit", "the anchored commit is not the "
                                       "intent's", "A1.6 tip neither parent nor stored commit",
                                       {"seq": L})
            elif tip != intent["expected_parent"]:
                return _quarantine(view, "intent-parent", "an intent for L + 1 whose parent is "
                                   "not the tip", "A1.6 tip neither parent nor stored commit",
                                   {"seq": L + 1})
            return Plan("needs-recovery", row="recovery-tidy", table="A1.2 committed, residual "
                        "intent", view=view, store_id=view.store_id, intent=intent, tip=tip,
                        remote_seq=rseq)
        if view.revoked_active:
            return Plan("quarantined", row="store-quarantine", table="A1.3 active epoch revoked",
                        view=view, store_id=view.store_id, rule="active-epoch-revoked",
                        position={"seq": L}, detail="the active epoch is revoked")
        cursor = _cursor(view)
        if cursor != _cursor_value(view, tip):
            return Plan("committed", row="recovery-tidy", table="A1.2 committed, cursor "
                        "disagrees", view=view, store_id=view.store_id, intent=None, tip=tip,
                        remote_seq=rseq)
        return Plan("committed", table="A1.2 committed", view=view)
    if L >= 2 and R.active == view.ptr(L - 1):
        if intent is not None and intent["seq"] == L and tip == intent["expected_parent"]:
            return Plan("pending", row="anchor-replay-forward", table="A1.2 R = ptr(L - 1) with "
                        "intent", view=view, store_id=view.store_id, intent=intent,
                        unterminated=False, remote_seq=rseq)
        return _quarantine(view, "rollback-one", "R = ptr(L - 1) without a matching intent",
                           "A1.2 one-step rollback or planted frame", {"seq": L})
    return _quarantine(view, "rollback", f"R names seq {rseq} with L = {L}",
                       "A1.2 rollback of the log or the remote", {"seq": rseq})


def _cursor(view: View) -> bytes | None:
    return store.read_file(os.path.join(view.directory, "cursor"), missing_ok=True)


def _cursor_value(view: View, tip: str) -> bytes:
    return store.cursor_bytes(view.store_id, view.L, view.records[-1].digest, tip)


# ---------------------------------------------------------------------------
# A2.3 bootstrap
# ---------------------------------------------------------------------------

def validate_genesis_intent(data: bytes) -> tuple[dict, bytes, View]:
    """A2.3's intent validity: exact schema; the frame is one complete
    store.genesis record for the intent's store and key_dir, sealed under the
    root it introduces; anchor_json is exactly that record's pointer, signed
    by that root; the commit rebuilt with no parent is anchor_commit."""
    intent = parse_json(data, GENESIS_INTENT_KEYS, "genesis.intent")
    fr, frame_bytes, active, prev, sig = check_intent_fields(intent)
    if intent["seq"] != 1 or intent["offset"] != 0 or intent["expected_parent"] is not None:
        raise Invalid("intent-schema", "genesis.intent is for frame 1 at offset 0 with no parent")
    if type(intent["store_id"]) is not str or not records.STORE_ID_RE.fullmatch(intent["store_id"]):
        raise Invalid("intent-schema", "genesis.intent store_id malformed")
    try:
        tools.parse_remote(intent["remote"], allow_test=True)
    except tools.ToolError as error:
        raise Invalid("intent-schema", error.message) from error
    view = View(intent["store_id"], 1, store.store_dir(intent["store_id"]), False)
    apply_frame(view, fr, None)
    body = view.records[0].payload["body"]
    if body["key_dir"] != intent["key_dir"] or body["remote"] != intent["remote"]:
        raise Invalid("intent-schema", "genesis.intent key_dir or remote is not the record's")
    if active != view.ptr(1) or prev is not None:
        raise Invalid("intent-pointer", "anchor_json is not the genesis record's pointer")
    verify_pointer_for(view, active, prev, sig)
    return intent, frame_bytes, view


def classify_frame1_bytes(data: bytes, frame_bytes: bytes) -> str:
    """none / torn / unterminated / valid / nonconforming (A2.3), comparing
    the log with the intent's exact frame bytes (the intent itself was
    validated as a whole: header, digest, seal, pointer)."""
    if data == b"":
        return "none"
    if data == frame_bytes:
        return "valid"
    if data == frame_bytes[:-1]:
        return "unterminated"
    if len(data) < len(frame_bytes) - 1 and frame_bytes.startswith(data):
        return "torn"
    return "nonconforming"


def classify_frame1(directory: str, frame_bytes: bytes) -> str:
    """Frame 1 of the intent-named store, whose directory the caller found
    present (the ceremony creates it before its intent, and nothing ever
    removes it, abandonment included: a missing one is never "none" but a
    failed intent, A2.3 row 1). A directory without a readable log is
    nonconforming."""
    try:
        data = store.read_file(store.log_path(directory))
    except store.AuthorityError:
        return "nonconforming"
    assert data is not None
    return classify_frame1_bytes(data, frame_bytes)


def observe_bootstrap(data: bytes, scratch_factory) -> Plan:
    try:
        intent, frame_bytes, view = validate_genesis_intent(data)
    except (Invalid, records.RecordError) as error:
        detail = getattr(error, "detail", None) or getattr(error, "message", str(error))
        return Plan("genesis-invalid", table="A2.3 row 1", detail=detail,
                    evidence={"genesis_intent_digest": store.sha256(data), "reason": detail})
    except tools.ToolError as error:
        raise store.AuthorityError("environment", error.message, store.EXIT_ENV) from error
    store_id = intent["store_id"]
    directory = store.store_dir(store_id)
    if not store.check_dir(directory, missing_ok=True):
        # Genesis creates the directory before its intent and nothing removes
        # it; without it nothing shows that frame 1 never became durable (it
        # may have been pushed and then deleted with the ref): row 1, fail
        # closed, nothing mutated.
        detail = "the intent-named store directory does not exist"
        return Plan("genesis-invalid", table="A2.3 row 1", detail=detail,
                    evidence={"genesis_intent_digest": store.sha256(data), "reason": detail})
    target = {"store_id": store_id, "generation": 1}
    active_bytes = None
    active_state = "absent"
    try:
        active_bytes = store.read_file(store.path(store.ACTIVE), missing_ok=True)
    except store.AuthorityError:
        active_state = "unreadable"
    if active_bytes is not None:
        active_state = "exact" if active_bytes == canonical.canonical(target) else "other"
    if active_state in ("unreadable", "other"):
        return Plan("anchor-mismatch", table="A2.3 row 2", detail="active is not the intent's store",
                    evidence={"active": active_state, "intent_store": store_id,
                              "active_digest": store.sha256(active_bytes) if active_bytes else None})
    plan_view = view
    marker = _marker(view)
    if marker is not None:
        state = "genesis-quarantined" if active_state == "absent" else "quarantined"
        return _finish(Plan(state, table="A2.3 quarantine marker", detail=str(marker.get("rule")),
                            view=plan_view, evidence=marker), view)
    kind = classify_frame1(directory, frame_bytes)
    position = {"seq": 1, "offset": 0}
    if kind == "nonconforming":
        state = "genesis-quarantined" if active_state == "absent" else "quarantined"
        return _finish(Plan(state, row="store-quarantine", table="A2.3 row 3", view=plan_view,
                            store_id=store_id, rule="frame1-nonconforming", position=position,
                            detail="frame 1 does not conform to genesis.intent"), view)
    remote = _pin(intent["remote"])
    scratch = scratch_factory()
    try:
        tip = anchor.ls_remote(scratch, remote.url)
    except anchor.Unreachable as error:
        return _finish(Plan("genesis-pending", table="A2.3 row 4", detail=str(error)[:300],
                            view=plan_view), view)
    digest = store.sha256(data)
    if tip is None:
        if active_state == "exact":
            return _finish(Plan("quarantined", row="store-quarantine", table="A2.3 row 5",
                                view=plan_view, store_id=store_id, rule="anchor-absent-after-active",
                                position=None, detail="the ref is absent after active was written"),
                           view, read=True)
        if kind in ("none", "torn"):
            # abandonment removes the intent and nothing else
            return _finish(Plan("genesis-pending", row="abandon", table="A2.3 row 6",
                                view=plan_view, store_id=store_id, intent_digest=digest),
                           view, read=True)
        # rows 7-8: the absent ref plays ptr(L - 1) for L = 1, and only here
        return _finish(Plan("genesis-pending", row="anchor-replay-forward",
                            table="A2.3 row 7" if kind == "unterminated" else "A2.3 row 8",
                            view=plan_view, store_id=store_id, intent=intent,
                            unterminated=kind == "unterminated", bootstrap=True, remote_seq=0,
                            intent_digest=digest), view, read=True)
    ok = False
    detail = "the remote holds another commit"
    if tip == intent["anchor_commit"]:
        try:
            fetched = anchor.fetch(scratch, remote.url)
            if fetched == tip:
                content, parent = anchor.read_anchor_commit(scratch, tip)
                if content == intent["anchor_json"].encode("utf-8") and parent is None:
                    a_active, a_prev, a_sig = records.parse_anchor_json(content)
                    verify_pointer_for(view, a_active, a_prev, a_sig)
                    ok = True
                else:
                    detail = "the remote commit's anchor.json differs from the intent's"
        except anchor.Unreachable as error:
            return _finish(Plan("genesis-pending", table="A2.3 row 4", detail=str(error)[:300],
                                view=plan_view), view)
        except (anchor.AnchorError, Invalid, records.RecordError) as error:
            detail = str(error)
    state_q = "genesis-quarantined" if active_state == "absent" else "quarantined"
    if ok and kind == "valid":
        return _finish(Plan("genesis-pending", row="complete", table="A2.3 row 9", view=plan_view,
                            store_id=store_id, target=target, active_state=active_state,
                            intent_digest=digest), view, tip, read=True)
    if ok:
        return _finish(Plan(state_q, row="store-quarantine", table="A2.3 row 10", view=plan_view,
                            store_id=store_id, rule="remote-new-frame-incomplete",
                            position=position, detail="the remote holds the intent's commit for "
                            "a frame that is not durable and complete"), view, tip, read=True)
    return _finish(Plan(state_q, row="store-quarantine", table="A2.3 row 11", view=plan_view,
                        store_id=store_id, rule="anchor-mismatch", position=None, detail=detail),
                   view, tip, read=True)


def _finish(plan: Plan, view: View, tip: str | None = None, named: tuple = (),
            read: bool = False) -> Plan:
    plan.anchor_class = view.anchor_class
    plan.lineage_remote = view.remote
    plan.remote_tip = tip
    plan.remote_read = read
    plan.named = set(named)
    return plan


# ---------------------------------------------------------------------------
# A1.3 linked re-genesis resolution
# ---------------------------------------------------------------------------

def validate_regenesis_intent(data: bytes) -> tuple[dict, bytes, View, View]:
    """The regenesis.intent is valid only when its new frame is a
    store.regenesis record for new_store_id, sealed under the root it
    introduces, linked to the old store's history; its pointer is that
    record's, links back to the old generation, and verifies under the new
    root; and the commit rebuilt on old_commit is anchor_commit."""
    intent = parse_json(data, REGENESIS_INTENT_KEYS, "regenesis.intent")
    fr, frame_bytes, active, prev, sig = check_intent_fields(intent)
    if intent["seq"] != 1 or intent["offset"] != 0 or intent["expected_parent"] != intent["old_commit"]:
        raise Invalid("intent-schema", "regenesis.intent is for frame 1 on the old commit")
    old = intent["old"]
    try:
        records.check_prev_generation(old, "old")
    except records.RecordError as error:
        raise Invalid("intent-schema", error.message) from error
    if intent["archive"] != "archive/" + old["store_id"]:
        raise Invalid("intent-schema", "archive must be archive/<old store>")
    new_id = intent["new_store_id"]
    if type(new_id) is not str or not records.STORE_ID_RE.fullmatch(new_id) or new_id == old["store_id"]:
        raise Invalid("intent-schema", "new_store_id malformed")
    archived = not store.check_dir(store.store_dir(old["store_id"]), missing_ok=True)
    try:
        old_view = load_view(old["store_id"], old["generation"], archived=archived)
    except store.AuthorityError as error:
        raise Invalid("old-store", error.message) from error
    new_view = View(new_id, old["generation"] + 1, store.store_dir(new_id), False)
    new_view.ancestors = [old_view] + old_view.ancestors
    apply_frame(new_view, fr, old_view.remote)
    body = new_view.records[0].payload["body"]
    if body["key_dir"] != intent["key_dir"] or body["remote"] != intent["remote"] \
            or intent["remote"] != old_view.remote:
        raise Invalid("intent-schema", "regenesis.intent key_dir or remote is not the record's")
    if body["prev_generation"] != old or body["prev_commit"] != intent["old_commit"]:
        raise Invalid("intent-link", "the record does not link to the intent's old generation")
    if not 1 <= old["last_seq"] <= old_view.L or \
            old_view.records[old["last_seq"] - 1].digest != old["last_record_digest"]:
        raise Invalid("intent-link", "the old generation link is not the old store's record")
    if active != new_view.ptr(1) or prev != old:
        raise Invalid("intent-pointer", "anchor_json is not the re-genesis record's pointer")
    verify_pointer_for(new_view, active, prev, sig)
    return intent, frame_bytes, old_view, new_view


def observe_regenesis(data: bytes, scratch_factory) -> Plan:
    try:
        intent, frame_bytes, old_view, new_view = validate_regenesis_intent(data)
    except (Invalid, records.RecordError) as error:
        detail = getattr(error, "detail", None) or getattr(error, "message", str(error))
        return Plan("regenesis-invalid", table="A1.3 intent", detail=detail,
                    evidence={"regenesis_intent_digest": store.sha256(data), "reason": detail})
    old_id = intent["old"]["store_id"]
    new_id = intent["new_store_id"]
    if not store.check_dir(store.store_dir(new_id), missing_ok=True):
        # created before the intent and never removed: fail closed, both
        # stores untouched
        detail = "the intent-named new store directory does not exist"
        return Plan("regenesis-invalid", table="A1.3 intent", detail=detail,
                    evidence={"regenesis_intent_digest": store.sha256(data), "reason": detail})
    new_target = {"store_id": new_id, "generation": new_view.generation}
    old_target = {"store_id": old_id, "generation": old_view.generation}
    active_bytes = store.read_file(store.path(store.ACTIVE), missing_ok=True)
    if active_bytes == canonical.canonical(new_target):
        active_state = "new"
    elif active_bytes == canonical.canonical(old_target):
        active_state = "old"
    else:
        return _finish(Plan("regenesis-invalid", table="A1.3 active", view=old_view,
                            detail="active names neither the old nor the new store"), old_view, named=(new_id,))
    remote = _pin(old_view.remote)  # type: ignore[arg-type]
    scratch = scratch_factory()
    unreachable = "A1.3 remote unreachable"
    try:
        # A1.2 step 1: the remote passes step 3's prerequisites -- every
        # commit read by content, the chain's structure, and (below) every
        # pointer's signature against the roots it requires -- before any
        # recovery decision, abandonment included.
        tip, chain = _read_remote(scratch, remote)
    except anchor.Unreachable as error:
        return _finish(Plan("regenesis-pending", table=unreachable, view=old_view,
                            detail=str(error)[:300]), old_view, named=(new_id,))
    except (Invalid, anchor.AnchorError) as error:
        return _finish(Plan("regenesis-quarantined", table="A1.3 anchor fails", view=old_view,
                            detail=str(error)[:300]), old_view, named=(new_id,), read=True)
    kind = classify_frame1(store.store_dir(new_id), frame_bytes)
    archived = not store.check_dir(store.store_dir(old_id), missing_ok=True)
    digest = store.sha256(data)
    detail = "the remote anchor is neither the recorded old commit nor the intent's"
    if tip is None or chain is None:
        detail = "the remote anchor ref is absent"
    elif tip == intent["old_commit"]:
        R = chain[0]
        try:
            if R.active["store_id"] != old_id or R.active["generation"] != old_view.generation \
                    or records.prev_generation_of(R.active) != intent["old"]:
                raise Invalid("anchor-history", "the recorded old commit is not the pointer the "
                              "re-genesis links to")
            _check_history(old_view, chain, skip_tip=False)
        except Invalid as error:
            detail = f"the recorded old commit does not verify: {error.detail}"
        else:
            if active_state == "old" and not archived:
                # abandonment removes the intent; the new directory stays,
                # unpublished
                return _finish(Plan("regenesis-pending", row="abandon",
                                    table="A1.3 remote names the old generation", view=old_view,
                                    store_id=new_id, intent_digest=digest), old_view, tip,
                               named=(new_id,), read=True)
            detail = "the remote names the old generation but the local state is past it"
    elif tip == intent["anchor_commit"]:
        R = chain[0]
        try:
            if R.anchor_json != intent["anchor_json"].encode("utf-8") \
                    or R.parent != intent["old_commit"]:
                raise Invalid("anchor-history", "the remote's new-generation commit differs from "
                              "the intent's")
            verify_pointer_for(new_view, R.active, R.prev_generation, R.sig)
            _check_history(old_view, chain[1:], skip_tip=False)
        except Invalid as error:
            detail = error.detail
        else:
            if kind == "valid":
                return _finish(Plan("regenesis-pending", row="complete",
                                    table="A1.3 remote names the new generation",
                                    view=old_view, store_id=new_id,
                                    target={"active_target": new_target, "archive_store": old_id},
                                    active_state=active_state, intent_digest=digest),
                               old_view, tip, named=(new_id,), read=True)
            detail = "the remote names the new generation but its frame is not durable"
    return _finish(Plan("regenesis-quarantined", table="A1.3 anchor fails", view=old_view,
                        detail=detail), old_view, tip, named=(new_id,), read=True)


# ---------------------------------------------------------------------------
# Executing plans
# ---------------------------------------------------------------------------

# Plans observe() issued, each with the digest of what it decided and the
# local state it observed; a plan mints at most one token, and only while
# unaltered.
_ISSUED: dict[int, tuple[Plan, str, str]] = {}
FINISH_ROWS = ("complete", "abandon")


def _decision(plan: Plan) -> dict:
    """What a plan decided: its state, row, table, parameters, remote
    evidence, and the log it read (not its free-text detail)."""
    view = plan.view
    return {
        "state": plan.state, "row": plan.row, "table": plan.table, "params": plan.params,
        "remote_tip": plan.remote_tip, "remote_read": plan.remote_read,
        "view": None if view is None else [view.store_id, view.generation, view.L,
                                           store.sha256(view.data), store.sha256(view.tail)],
    }


def _plan_seal(plan: Plan) -> str:
    return canonical.digest(dict(_decision(plan), detail=plan.detail))


def _issue(plan: Plan) -> Plan:
    """Register the plan with what it decided and, when it names a row (only
    such a plan can mint), the local state it observed."""
    local = store.snapshot_digest() if plan.row is not None else ""
    _ISSUED[id(plan)] = (plan, _plan_seal(plan), local)
    return plan


def reobserve() -> Plan:
    """A fresh, unissued classification of the files and the remote: the
    store's re-proof of a row's predicate (it mints nothing)."""
    scratch = Scratch()
    try:
        return _observe(scratch)
    finally:
        scratch.close()


def redeem(plan: object, *, finish: bool) -> dict:
    """Called by store.begin_recovery / store.begin_finish, and only on
    their own argument: spend the plan -- it must be one observe() issued,
    unaltered and unspent -- then require the local state it observed and a
    fresh observation of the files and the remote that decides exactly the
    same plan, and derive the binding from that. A caller-built binding, a
    forged or altered plan, a replayed plan, or a plan the files and the
    remote no longer bear out mints nothing."""
    issued = _ISSUED.pop(id(plan), None)
    if type(plan) is not Plan or issued is None or issued[0] is not plan \
            or issued[1] != _plan_seal(plan):
        raise store.AuthorityError("recovery-plan", "a token is minted only from a plan "
                                   "observe() issued, unaltered and unspent")
    if plan.row is None or (plan.row in FINISH_ROWS) != finish:
        raise store.AuthorityError("recovery-plan", f"the plan's row {plan.row!r} is not a "
                                   f"{'finish' if finish else 'recovery'} row")
    local = store.snapshot_digest()
    if local != issued[2]:
        raise store.AuthorityError("recovery-state", "the observed state is not the current state")
    fresh = reobserve()
    if canonical.digest(_decision(fresh)) != canonical.digest(_decision(plan)) \
            or store.snapshot_digest() != local:
        raise store.AuthorityError("recovery-plan", "a fresh observation of the files and the "
                                   "remote does not decide this plan")
    return _binding(plan, local)


def _marker_bytes(plan: Plan) -> bytes:
    params = plan.params
    return store.quarantine_bytes(params["store_id"], params["rule"],  # type: ignore[arg-type]
                                  params["position"], plan.detail or plan.table)  # type: ignore[arg-type]


def _binding(plan: Plan, local: str) -> dict:
    """The plan's exact sink parameters and the evidence they rest on (local
    is the snapshot digest of the state it observed)."""
    params = plan.params
    binding = {"row": plan.row, "table": plan.table, "local": local,
               "remote": {"read": plan.remote_read,
                          "tip": plan.remote_tip if plan.remote_read else None}}
    row = plan.row
    if row == "store-quarantine":
        binding.update(store_id=params["store_id"], rule=params["rule"], position=params["position"],
                       marker_digest=store.sha256(_marker_bytes(plan)))
    elif row == "torn-frame-truncation":
        assert plan.view is not None
        binding.update(store_id=params["store_id"], offset=params["offset"],
                       intent_digest=params["intent_digest"],
                       tail_digest=store.sha256(plan.view.tail))
    elif row == "recovery-tidy":
        assert plan.view is not None
        binding.update(store_id=params["store_id"],
                       intent_digest=params["intent_digest"] if params.get("intent") else None,
                       cursor_digest=store.sha256(_cursor_value(plan.view, params["tip"])))  # type: ignore[arg-type]
    elif row == "anchor-replay-forward":
        intent = params["intent"]
        binding.update(store_id=params["store_id"],
                       intent="genesis" if params.get("bootstrap") else "store",
                       intent_digest=params["intent_digest"],
                       unterminated=bool(params.get("unterminated")),
                       anchor_commit=intent["anchor_commit"],  # type: ignore[index]
                       expected_parent=intent["expected_parent"])  # type: ignore[index]
    elif row in ("complete", "abandon"):
        binding.update(row=_ceremony_row(plan), action=row, intent_digest=params["intent_digest"])
    return binding


def _ceremony_row(plan: Plan) -> str:
    return "authority-genesis" if plan.state.startswith("genesis") else "linked-regenesis"


def _mint(plan: Plan) -> store.Token:
    """The only caller of store.begin_recovery and store.begin_finish, which
    take nothing but the plan: the store spends it (redeem), re-observes,
    and derives the token's binding itself."""
    if getattr(plan, "row", None) in FINISH_ROWS:
        return store.begin_finish(plan)
    return store.begin_recovery(plan)


def execute(plan: Plan, scratch_factory) -> None:
    """Run the plan's row under its own freshly minted token."""
    row = plan.row
    params = plan.params
    if row == "store-quarantine":
        registry.validate(row, {"quarantined": False}, {"rule": params["rule"],
                                                        "position": params["position"]})
        token = _mint(plan)
        try:
            store.write_quarantine(token, store_id=params["store_id"],  # type: ignore[arg-type]
                                   data=_marker_bytes(plan))
        finally:
            store.spend(token)
        return
    if row == "torn-frame-truncation":
        view = plan.view
        assert view is not None
        intent = params["intent"]
        registry.validate(row, {"tail": "torn", "log_seq": view.L,
                                "intent": {"seq": intent["seq"], "offset": intent["offset"]}},  # type: ignore[index]
                          {"tail_offset": view.tail_offset, "remote_seq": params["remote_seq"]})
        token = _mint(plan)
        try:
            store.truncate_frame(token, store_id=params["store_id"],  # type: ignore[arg-type]
                                 offset=params["offset"])  # type: ignore[arg-type]
        finally:
            store.spend(token)
        return
    if row == "recovery-tidy":
        view = plan.view
        assert view is not None
        intent = params.get("intent")
        cursor_agrees = _cursor(view) == _cursor_value(view, params["tip"])  # type: ignore[arg-type]
        registry.validate(row, {"log_seq": view.L,
                                "intent": {"seq": intent["seq"]} if intent else None,  # type: ignore[index]
                                "cursor": view.L if cursor_agrees else None},
                          {"remote_seq": params["remote_seq"], "remote_matches": True,
                           "intent_matches": True, "no_tail": not view.tail})
        token = _mint(plan)
        try:
            if params.get("intent") is not None:
                store.remove_intent(token, store_id=view.store_id)
            store.write_cursor(token, store_id=view.store_id,
                               data=_cursor_value(view, params["tip"]))  # type: ignore[arg-type]
        finally:
            store.spend(token)
        return
    if row == "anchor-replay-forward":
        _replay(plan, scratch_factory)
        return
    if row in ("complete", "abandon"):
        _finish_ceremony(plan)
        return
    raise store.AuthorityError("recover", f"no executor for row {row!r}")


def _replay(plan: Plan, scratch_factory) -> None:
    """Anchor replay-forward: re-validate, then push the intent's stored
    commit -- the same bytes, never re-signed -- and read it back."""
    params = plan.params
    intent = params["intent"]
    assert type(intent) is dict
    unterminated = bool(params.get("unterminated"))
    if params.get("bootstrap"):
        log_seq = 0 if unterminated else 1
    else:
        assert plan.view is not None
        log_seq = plan.view.L
    registry.validate("anchor-replay-forward",
                      {"tail": "unterminated" if unterminated else None, "log_seq": log_seq,
                       "intent": {"seq": intent["seq"]}},
                      {"remote_seq": params["remote_seq"], "intent_matches": True, "frame_valid": True})
    scratch = scratch_factory()
    anchor_json = intent["anchor_json"].encode("utf-8")
    try:
        commit = anchor.build_objects(scratch, anchor_json, intent["expected_parent"])
    except anchor.AnchorError as error:
        if error.code == "anchor-parent-pending":
            raise store.AuthorityError("pending", error.message, store.EXIT_PENDING) from error
        raise
    if commit != intent["anchor_commit"]:
        raise store.AuthorityError("replay", "the rebuilt commit differs from the stored one")
    active, prev, _sig = records.parse_anchor_json(anchor_json)
    view = plan.view
    assert view is not None
    if params.get("bootstrap"):
        root_pub = view.epochs[1].root_pub
    else:
        owner = view
        if intent["seq"] > view.L:
            owner, _record = validate_candidate(view, base64.b64decode(intent["frame_b64"]))
        root_pub = owner.epochs[active["epoch"]].root_pub
    token = _mint(plan)
    try:
        if params.get("unterminated"):
            store.complete_delimiter(token, store_id=params["store_id"],  # type: ignore[arg-type]
                                     frame_bytes=base64.b64decode(intent["frame_b64"]))
            store.crash("recovery-after-delimiter")
        store.push_anchor(token, scratch=scratch, commit=commit, ref=tools.ANCHOR_REF)
        store.readback(token, scratch=scratch, commit=commit, anchor_json=anchor_json,
                       expected_parent=intent["expected_parent"], root_pub=root_pub)
    finally:
        store.spend(token)


def _finish_ceremony(plan: Plan) -> None:
    """A2.4: complete or abandon genesis / linked re-genesis on exact state.
    What the sinks may touch the store derives from the validated intent;
    the targets here are only what this routine asks for, and a sink
    refuses any that differ. Abandonment removes the intent and nothing
    else: the intent-named directory stays, unpublished."""
    params = plan.params
    row = _ceremony_row(plan)
    action = "complete" if plan.row == "complete" else "abandon"
    target = params.get("target")
    token = _mint(plan)
    try:
        if action == "complete":
            assert type(target) is dict
            if row == "linked-regenesis":
                store.archive_store(token, store_id=target["archive_store"])
                if params.get("active_state") != "new":
                    store.write_active(token, target=target["active_target"])
            elif params.get("active_state") == "absent":
                store.write_active(token, target=target)
        if row == "authority-genesis":
            store.remove_genesis_intent(token)
        else:
            store.remove_regenesis_intent(token)
    finally:
        store.spend(token)


class Scratch:
    """Fresh scratch repositories for one recovery pass, removed after."""

    def __init__(self) -> None:
        self.repos: list[str] = []

    def __call__(self) -> str:
        repo = tools.new_scratch_repo()
        self.repos.append(repo)
        return repo

    def close(self) -> None:
        for repo in self.repos:
            tools.remove_scratch_repo(repo)
        self.repos = []


def recover(max_steps: int = 12) -> Plan:
    """Under the writer lock: run rows until the state is stable. The
    returned plan's steps name each row run, in order, with the state and
    table that triggered it (the first is the state recovery found)."""
    steps: list = []
    for _ in range(max_steps):
        scratch = Scratch()
        try:
            plan = observe(scratch)
            if plan.anchor_class is not None or plan.row is not None:
                # recovery never runs with test binaries on a lineage that is
                # not a test lineage, whether or not a row would apply
                try:
                    tools.refuse_test_binaries(plan.anchor_class)
                except tools.ToolError as error:
                    raise store.AuthorityError(error.code, error.message, store.EXIT_ENV) from error
            if plan.row is None:
                plan.steps = steps
                return plan
            steps.append({"state": plan.state, "table": plan.table, "row": plan.row,
                          "rule": plan.params.get("rule")})
            execute(plan, scratch)
        finally:
            scratch.close()
    raise store.AuthorityError("recover", "recovery did not reach a stable state")


def classify_stable() -> Plan | None:
    """Observe without a lock, accepting only an unchanged local snapshot.

    A ceremony may replace or remove files between reads. Bound the retries;
    callers must report unavailable/changing rather than a transient verdict.
    """
    for _ in range(3):
        try:
            before = store.snapshot_digest()
            plan = classify()
            after = store.snapshot_digest()
        except OSError:
            continue
        if before == after:
            return plan
    return None


def classify() -> Plan:
    """Read-only classification (status, verify)."""
    scratch = Scratch()
    try:
        return observe(scratch)
    finally:
        scratch.close()
