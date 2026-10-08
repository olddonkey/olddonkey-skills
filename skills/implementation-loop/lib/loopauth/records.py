"""Authority records: the closed type list, payload and body schemas, and the
anchor pointer (task-graph-v1 Phase A, sub-unit 0a.2, section 3; A1.2).

A record payload is the canonical JSON of
  {type, v: 1, store_id, generation, seq, epoch, key_id, prev, body}
where prev is the previous record's digest (null at seq 1), epoch the epoch
whose subkey sealed the record, and key_id that subkey's SHA256 fingerprint.
A frame (frame.py) carries canonical({payload, sig}).

TYPES is closed and fixed here, so genesis and rotation certify one subkey
per type up front. Segment reset, mechanism closure, and release acceptance
are not types: they exist only nested in a request.redeemed body, so no key
can seal them directly.

The activation boundary (A2.1, A2.6). Every epoch introducer
(store.genesis, epoch.rotated, store.regenesis) carries registry_version and
admitted_protocols. ALLOWED[registry_version] names the record types and
request protocols that version admits; 0a knows one version, "tg-v1.0a",
admitting exactly the four ADMISSIBLE_TYPES and no protocol. A record is
valid only if its type is admitted by its epoch introducer's version --
decided from the envelope, before any body schema (type-not-admitted) -- so
only ADMISSIBLE_TYPES have a body schema in 0a.2.

Pure: no I/O, no subprocess.
"""

from __future__ import annotations

import base64
import re

from . import canonical

TYPES = (
    "store.genesis",
    "epoch.rotated",
    "epoch.revoked",
    "store.regenesis",
    "request.opened",
    "request.cancelled",
    "request.expired",
    "request.redeemed",
    "nonce.issued",
    "repo.registered",
    "repo.rebound",
    "exec-root.registered",
    "standing.granted",
    "standing.revoked",
    "entry.enrolled",
    "entry.revoked",
    "platform.designated",
)
ADMISSIBLE_TYPES = ("store.genesis", "epoch.rotated", "epoch.revoked", "store.regenesis")
INTRODUCER_TYPES = ("store.genesis", "epoch.rotated", "store.regenesis")
# Compound parts nested in request.redeemed. They are never a type, never a
# frame, and never a signing namespace.
NESTED_ONLY = ("segment_reset", "mechanism_closed", "release_accepted")
KEY_TYPES = ("root",) + TYPES

# The activation boundary: registry versions in order, and what each admits.
REGISTRY_VERSION = "tg-v1.0a"
REGISTRY_VERSIONS = (REGISTRY_VERSION,)
ALLOWED = {
    "tg-v1.0a": {"types": ADMISSIBLE_TYPES, "protocols": ()},
}

PAYLOAD_KEYS = ("type", "v", "store_id", "generation", "seq", "epoch", "key_id", "prev", "body")
ANCHOR_REF = "refs/olddonkey-loop/anchor"
COMMIT_IDENTITY = {"name": "olddonkey-loop", "email": "anchor@olddonkey-loop.invalid"}
POINTER_NAMESPACE = "olddonkey-loop.anchor.pointer.v1"

STORE_ID_RE = re.compile(r"^[0-9a-f]{32}$")
KEY_ID_RE = re.compile(r"^SHA256:[A-Za-z0-9+/]{43}$")
KEY_DIR_RE = re.compile(r"^epoch-([1-9][0-9]*)-([0-9a-f]{16})$")
OID_RE = re.compile(r"^[0-9a-f]{40}$")
HEX12_RE = re.compile(r"^[0-9a-f]{12}$")
ED25519_PREFIX = "ssh-ed25519 "
SIG_RE = re.compile(
    r"^-----BEGIN SSH SIGNATURE-----\n(?:[A-Za-z0-9+/=]{1,76}\n)+-----END SSH SIGNATURE-----\n?$"
)
TTY_RE = re.compile(r"^/dev/[A-Za-z0-9/._-]{1,64}$")
MAX_INT = canonical.MAX_INT


class RecordError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _fail(code: str, message: str) -> None:
    raise RecordError(code, message)


def namespace(record_type: str) -> str:
    if record_type not in TYPES:
        _fail("type", f"no signing namespace outside the closed type list: {record_type!r}")
    return f"olddonkey-loop.authority.{record_type}.v1"


def check_type(record_type: object) -> str:
    """Refuse anything outside TYPES, naming the nested-only parts explicitly."""
    if type(record_type) is not str:
        _fail("type", "record type must be a string")
    normalized = record_type.replace("-", "_").replace(".", "_")
    if record_type in NESTED_ONLY or normalized in NESTED_ONLY:
        _fail("nested-only", f"{record_type} exists only nested in request.redeemed; it has no type")
    if record_type not in TYPES:
        _fail("type", f"record type outside the closed list: {record_type!r}")
    return record_type


# ---------------------------------------------------------------------------
# Field checks
# ---------------------------------------------------------------------------

def _exact_keys(value: object, keys: tuple, where: str) -> dict:
    if type(value) is not dict:
        _fail("schema", f"{where} must be an object")
    if set(value) != set(keys):  # type: ignore[arg-type]
        _fail("schema", f"{where} keys {sorted(value)} != {sorted(keys)}")  # type: ignore[arg-type]
    return value  # type: ignore[return-value]


def _int(value: object, where: str, minimum: int = 1) -> int:
    if type(value) is not int or not minimum <= value <= MAX_INT:
        _fail("schema", f"{where} must be an integer >= {minimum}")
    return value  # type: ignore[return-value]


def _str(value: object, where: str, pattern: re.Pattern | None = None) -> str:
    if type(value) is not str:
        _fail("schema", f"{where} must be a string")
    if pattern is not None and not pattern.fullmatch(value):  # type: ignore[arg-type]
        _fail("schema", f"{where} is malformed")
    return value  # type: ignore[return-value]


def _digest(value: object, where: str) -> str:
    if not canonical.is_digest(value):
        _fail("schema", f"{where} must be a sha256: digest")
    return value  # type: ignore[return-value]


def ed25519_blob(pub: str) -> bytes:
    """The wire blob of an "ssh-ed25519 <base64>" public key (no comment)."""
    if type(pub) is not str or not pub.startswith(ED25519_PREFIX) or pub.count(" ") != 1:
        _fail("key", "public key must be exactly 'ssh-ed25519 <base64>'")
    try:
        blob = base64.b64decode(pub[len(ED25519_PREFIX):], validate=True)
    except (ValueError, TypeError):
        _fail("key", "public key is not base64")
    if base64.b64encode(blob).decode("ascii") != pub[len(ED25519_PREFIX):]:
        _fail("key", "public key base64 is not canonical")
    expected = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    if len(blob) != len(expected) + 32 or not blob.startswith(expected):
        _fail("key", "public key is not an Ed25519 key")
    return blob


def fingerprint_of_blob(blob: bytes) -> str:
    import hashlib

    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode("ascii").rstrip("=")


def key_id_of_pub(pub: str) -> str:
    return fingerprint_of_blob(ed25519_blob(pub))


def check_principal(value: object) -> dict:
    principal = _exact_keys(value, ("kind", "tty", "start_token"), "principal")
    if principal["kind"] != "operator-tty":
        _fail("principal", "principal kind must be operator-tty")
    _str(principal["tty"], "principal.tty", TTY_RE)
    token = _exact_keys(principal["start_token"], ("boot_id", "pid", "start_time"),
                        "principal.start_token")
    _str(token["boot_id"], "start_token.boot_id", re.compile(r"^[A-Za-z0-9-]{8,64}$"))
    _int(token["pid"], "start_token.pid")
    _int(token["start_time"], "start_token.start_time", 0)
    return principal


def check_subkeys(value: object) -> dict:
    subkeys = _exact_keys(value, TYPES, "subkeys")
    for name in TYPES:
        _str(subkeys[name], f"subkeys.{name}", KEY_ID_RE)
    if len(set(subkeys.values())) != len(TYPES):
        _fail("schema", "subkeys must be distinct per type")
    return subkeys


def _check_epoch_keys(body: dict, epoch: int) -> None:
    match = KEY_DIR_RE.fullmatch(_str(body["key_dir"], "key_dir"))
    if match is None or int(match.group(1)) != epoch:
        _fail("schema", f"key_dir must be epoch-{epoch}-<16 hex>")
    key_id = key_id_of_pub(body["root_pub"])
    if body["root_key_id"] != key_id:
        _fail("schema", "root_key_id is not the fingerprint of root_pub")
    subkeys = check_subkeys(body["subkeys"])
    if key_id in subkeys.values():
        _fail("schema", "a subkey equals the root")


INTRODUCER_KEYS = ("registry_version", "admitted_protocols")
GENESIS_KEYS = ("ceremony", "envelope_digest", "principal", "remote", "anchor_ref",
                "anchor_class", "commit_identity", "epoch", "key_dir", "root_pub",
                "root_key_id", "subkeys") + INTRODUCER_KEYS
REGENESIS_KEYS = GENESIS_KEYS + ("prev_generation", "prev_commit", "quarantined", "archive")
ROTATED_KEYS = ("ceremony", "envelope_digest", "principal", "remote", "from_epoch", "epoch",
                "key_dir", "root_pub", "root_key_id", "subkeys") + INTRODUCER_KEYS
REVOKED_KEYS = ("ceremony", "envelope_digest", "principal", "epoch", "prior_state")
PREV_GENERATION_KEYS = ("store_id", "generation", "last_seq", "last_record_digest")
ACTIVE_KEYS = ("store_id", "generation", "genesis_digest", "seq", "record_digest", "epoch",
               "key_id")


def check_prev_generation(value: object, where: str = "prev_generation") -> dict:
    prev = _exact_keys(value, PREV_GENERATION_KEYS, where)
    _str(prev["store_id"], f"{where}.store_id", STORE_ID_RE)
    _int(prev["generation"], f"{where}.generation")
    _int(prev["last_seq"], f"{where}.last_seq")
    _digest(prev["last_record_digest"], f"{where}.last_record_digest")
    return prev


def check_introducer(body: dict) -> tuple[str, tuple]:
    """An epoch introducer's registry_version must be a version this code
    knows, and its admitted_protocols a subset of ALLOWED[version]. Returns
    (version, protocols)."""
    version = body["registry_version"]
    if type(version) is not str or version not in ALLOWED:
        _fail("introducer-version", f"unknown registry_version {version!r}")
    protocols = body["admitted_protocols"]
    if type(protocols) is not list or any(type(item) is not str for item in protocols) \
            or len(set(protocols)) != len(protocols):
        _fail("schema", "admitted_protocols must be a list of distinct strings")
    extra = sorted(set(protocols) - set(ALLOWED[version]["protocols"]))
    if extra:
        _fail("introducer-protocols", f"{version} does not allow the protocols {extra}")
    return version, tuple(protocols)


def version_index(version: str) -> int:
    return REGISTRY_VERSIONS.index(version)


def type_admitted(version: str, record_type: str) -> bool:
    return record_type in ALLOWED[version]["types"]


def check_succession(version: str, protocols: tuple, predecessor: tuple | None, *,
                     same_generation: bool) -> None:
    """A2.1/A2.6 on an introducer against its predecessor epoch
    (predecessor = (version, protocols) or None at generation 1's genesis):
    the version is not lower; within a generation the admitted protocols
    and the admitted type set only grow."""
    if predecessor is None:
        return
    old_version, old_protocols = predecessor
    if version_index(version) < version_index(old_version):
        _fail("introducer-version", f"registry_version {version} is lower than the "
              f"predecessor epoch's {old_version}")
    if same_generation:
        if not set(old_protocols) <= set(protocols):
            _fail("introducer-protocols", "an introducer dropped a protocol its predecessor "
                  "listed")
        if not set(ALLOWED[old_version]["types"]) <= set(ALLOWED[version]["types"]):
            _fail("introducer-types", "an introducer's admitted type set shrank")


def check_body(record_type: str, body: object, *, remote_check) -> dict:
    """Validate the body of an admissible type. remote_check(url) returns
    the anchor class of a pinned-form remote or raises."""
    if record_type in ("store.genesis", "store.regenesis"):
        keys = GENESIS_KEYS if record_type == "store.genesis" else REGENESIS_KEYS
        value = _exact_keys(body, keys, "body")
        check_introducer(value)
        if value["ceremony"] != ("genesis" if record_type == "store.genesis" else "regenesis"):
            _fail("schema", "body.ceremony does not match the type")
        _digest(value["envelope_digest"], "envelope_digest")
        check_principal(value["principal"])
        anchor_class = remote_check(_str(value["remote"], "remote"))
        if value["anchor_class"] != anchor_class:
            _fail("anchor-class", "anchor_class disagrees with the pinned remote")
        if value["anchor_ref"] != ANCHOR_REF:
            _fail("schema", "anchor_ref must be refs/olddonkey-loop/anchor")
        if value["commit_identity"] != COMMIT_IDENTITY:
            _fail("schema", "commit_identity is not the deterministic identity")
        if value["epoch"] != 1:
            _fail("schema", "a store's first epoch is 1")
        _check_epoch_keys(value, 1)
        if record_type == "store.regenesis":
            check_prev_generation(value["prev_generation"])
            _str(value["prev_commit"], "prev_commit", OID_RE)
            quarantined = _exact_keys(value["quarantined"], ("last_seq", "last_record_digest"),
                                      "quarantined")
            _int(quarantined["last_seq"], "quarantined.last_seq")
            _digest(quarantined["last_record_digest"], "quarantined.last_record_digest")
            if value["archive"] != "archive/" + value["prev_generation"]["store_id"]:
                _fail("schema", "archive must be archive/<previous store_id>")
        return value
    if record_type == "epoch.rotated":
        value = _exact_keys(body, ROTATED_KEYS, "body")
        check_introducer(value)
        if value["ceremony"] != "rotate":
            _fail("schema", "body.ceremony does not match the type")
        _digest(value["envelope_digest"], "envelope_digest")
        check_principal(value["principal"])
        remote_check(_str(value["remote"], "remote"))
        _int(value["from_epoch"], "from_epoch")
        _int(value["epoch"], "epoch")
        if value["epoch"] != value["from_epoch"] + 1:
            _fail("schema", "a rotation introduces from_epoch + 1")
        _check_epoch_keys(value, value["epoch"])
        return value
    if record_type == "epoch.revoked":
        value = _exact_keys(body, REVOKED_KEYS, "body")
        if value["ceremony"] != "revoke":
            _fail("schema", "body.ceremony does not match the type")
        _digest(value["envelope_digest"], "envelope_digest")
        check_principal(value["principal"])
        _int(value["epoch"], "epoch")
        if value["prior_state"] not in ("active", "verify-only"):
            _fail("schema", "prior_state must be active or verify-only")
        return value
    check_type(record_type)
    _fail("type-not-admitted", f"{record_type} is admitted by no registry version this code "
          "knows; it has no body schema")
    raise AssertionError  # unreachable


def check_envelope(payload: object) -> dict:
    """Everything but the body: exact keys, a type from the closed list, v,
    store_id, generation, seq, epoch, key_id, prev. Type admission (by the
    epoch introducer's registry version) is decided on this alone, before
    the body schema."""
    value = _exact_keys(payload, PAYLOAD_KEYS, "payload")
    check_type(value["type"])
    if value["v"] != 1 or type(value["v"]) is not int:
        _fail("schema", "payload v must be 1")
    _str(value["store_id"], "store_id", STORE_ID_RE)
    _int(value["generation"], "generation")
    _int(value["seq"], "seq")
    _int(value["epoch"], "epoch")
    _str(value["key_id"], "key_id", KEY_ID_RE)
    if value["seq"] == 1:
        if value["prev"] is not None:
            _fail("schema", "prev must be null at seq 1")
    else:
        _digest(value["prev"], "prev")
    return value


def check_payload(payload: object, *, remote_check) -> dict:
    value = check_envelope(payload)
    check_body(value["type"], value["body"], remote_check=remote_check)
    return value


def build_payload(record_type: str, *, store_id: str, generation: int, seq: int, epoch: int,
                  key_id: str, prev: str | None, body: dict) -> dict:
    return {
        "type": check_type(record_type),
        "v": 1,
        "store_id": store_id,
        "generation": generation,
        "seq": seq,
        "epoch": epoch,
        "key_id": key_id,
        "prev": prev,
        "body": body,
    }


def payload_bytes(payload: dict) -> bytes:
    return canonical.canonical(payload)


def content_bytes(payload: dict, sig: str) -> bytes:
    """The bytes a frame carries: canonical({payload, sig})."""
    return canonical.canonical({"payload": payload, "sig": sig})


def parse_content(data: bytes) -> tuple[dict, str]:
    """Parse a frame's content; it must be exactly canonical({payload, sig})."""
    try:
        text = data.decode("utf-8")
        value = canonical.loads(text)
    except (UnicodeDecodeError, canonical.CanonicalError) as error:
        _fail("content", f"frame content is not canonical JSON: {error}")
    content = _exact_keys(value, ("payload", "sig"), "content")
    if canonical.canonical(content) != data:
        _fail("content", "frame content is not in canonical form")
    sig = _str(content["sig"], "sig", SIG_RE)
    return content["payload"], sig


# ---------------------------------------------------------------------------
# The anchor pointer (A1.2)
# ---------------------------------------------------------------------------

def pointer(active: dict, prev_generation: dict | None) -> dict:
    return {"active": active, "prev_generation": prev_generation}


def pointer_bytes(active: dict, prev_generation: dict | None) -> bytes:
    return canonical.canonical(pointer(active, prev_generation))


def anchor_json_bytes(active: dict, prev_generation: dict | None, sig: str) -> bytes:
    return canonical.canonical({"active": active, "prev_generation": prev_generation, "sig": sig})


def check_active(value: object) -> dict:
    active = _exact_keys(value, ACTIVE_KEYS, "active")
    _str(active["store_id"], "active.store_id", STORE_ID_RE)
    _int(active["generation"], "active.generation")
    _digest(active["genesis_digest"], "active.genesis_digest")
    _int(active["seq"], "active.seq")
    _digest(active["record_digest"], "active.record_digest")
    _int(active["epoch"], "active.epoch")
    _str(active["key_id"], "active.key_id", KEY_ID_RE)
    return active


def parse_anchor_json(data: bytes) -> tuple[dict, dict | None, str]:
    """Parse anchor.json; it must be exactly canonical({active,
    prev_generation, sig})."""
    try:
        value = canonical.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, canonical.CanonicalError) as error:
        _fail("anchor-json", f"anchor.json is not canonical JSON: {error}")
    body = _exact_keys(value, ("active", "prev_generation", "sig"), "anchor.json")
    if canonical.canonical(body) != data:
        _fail("anchor-json", "anchor.json is not in canonical form")
    active = check_active(body["active"])
    prev = body["prev_generation"]
    if prev is not None:
        check_prev_generation(prev)
    sig = _str(body["sig"], "anchor.sig", SIG_RE)
    return active, prev, sig


def prev_generation_of(active: dict) -> dict:
    """A generation change sets prev_generation to exactly its parent's
    active pointer, in the prev_generation shape."""
    return {
        "store_id": active["store_id"],
        "generation": active["generation"],
        "last_seq": active["seq"],
        "last_record_digest": active["record_digest"],
    }
