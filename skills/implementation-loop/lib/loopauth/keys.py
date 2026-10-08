"""Key helpers for the authority store (A1.7; 0a.2 section 3). Pure helpers:
parsing public keys, private keys, OpenSSH certificates, and SSHSIG
signatures; fingerprints; allowed_signers lines; and seal and pointer
verification. They run only read commands (ssh-keygen.verify,
ssh-keygen.verify-pointer, ssh-keygen.fingerprint) and write only scratch
files. Every key-file and signature sink lives in store.py.

A seal is valid only when, in addition to ssh-keygen accepting it under the
line  <type> cert-authority,namespaces="olddonkey-loop.authority.<type>.v1"
<root.pub>:  the embedded certificate is a user certificate signed by exactly
the pinned root, its key identity is exactly <type>@e<epoch>, its only
principal is <type>, it is valid always:forever with no critical options,
and its subject key's fingerprint is the record's key_id.
"""

from __future__ import annotations

import base64
import hashlib
import struct

from . import records, tools

# Successful verifications in this process, keyed by the digest of every
# input: ssh-keygen's answer is a pure function of them, so recovery's
# repeated observations need not ask again. Failures are never cached.
_VERIFIED: dict[str, object] = {}


def _memo_key(*parts: object) -> str:
    digest = hashlib.sha256()
    for part in parts:
        data = part if type(part) is bytes else str(part).encode("utf-8")
        digest.update(len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()

CERT_TYPE = b"ssh-ed25519-cert-v01@openssh.com"
KEY_TYPE = b"ssh-ed25519"
FOREVER = 0xFFFFFFFFFFFFFFFF
SIG_BEGIN = "-----BEGIN SSH SIGNATURE-----"
SIG_END = "-----END SSH SIGNATURE-----"
PRIV_BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----"
PRIV_END = "-----END OPENSSH PRIVATE KEY-----"


class KeyFileError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _fail(code: str, message: str) -> None:
    raise KeyFileError(code, message)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def take(self, count: int) -> bytes:
        if count < 0 or self.pos + count > len(self.data):
            _fail("wire", "truncated SSH wire data")
        chunk = self.data[self.pos:self.pos + count]
        self.pos += count
        return chunk

    def u32(self) -> int:
        return struct.unpack(">I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack(">Q", self.take(8))[0]

    def string(self) -> bytes:
        return self.take(self.u32())

    def done(self) -> bool:
        return self.pos == len(self.data)


def _ssh_string(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + data


def ed25519_blob_from_pk(pk: bytes) -> bytes:
    if len(pk) != 32:
        _fail("key", "Ed25519 public key must be 32 bytes")
    return _ssh_string(KEY_TYPE) + _ssh_string(pk)


def fingerprint(blob: bytes) -> str:
    return records.fingerprint_of_blob(blob)


def parse_pub_file(data: bytes) -> str:
    """A .pub file is 'ssh-ed25519 <base64> <comment>\\n'; returns the
    comment-free 'ssh-ed25519 <base64>' after checking it."""
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        _fail("key", "public key file is not ASCII")
    lines = text.split("\n")
    if len(lines) != 2 or lines[1] != "":
        _fail("key", "public key file must be one line")
    fields = lines[0].split(" ")
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        _fail("key", "public key file is not an Ed25519 key")
    line = f"{fields[0]} {fields[1]}"
    records.ed25519_blob(line)
    return line


def parse_private_key(data: bytes) -> bytes:
    """The public blob inside an unencrypted openssh-key-v1 Ed25519 private
    key, after checking the private half carries the same public key."""
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        _fail("key", "private key file is not ASCII")
    lines = text.strip("\n").split("\n")
    if len(lines) < 3 or lines[0] != PRIV_BEGIN or lines[-1] != PRIV_END:
        _fail("key", "not an OpenSSH private key")
    try:
        raw = base64.b64decode("".join(lines[1:-1]), validate=True)
    except ValueError:
        _fail("key", "private key is not base64")
    magic = b"openssh-key-v1\x00"
    if not raw.startswith(magic):
        _fail("key", "private key magic mismatch")
    reader = _Reader(raw[len(magic):])
    if reader.string() != b"none" or reader.string() != b"none" or reader.string() != b"":
        _fail("key", "private key must be unencrypted")
    if reader.u32() != 1:
        _fail("key", "private key must hold exactly one key")
    public_blob = reader.string()
    private = _Reader(reader.string())
    if not reader.done():
        _fail("key", "trailing bytes after the private section")
    if private.u32() != private.u32():
        _fail("key", "private key check integers differ")
    if private.string() != KEY_TYPE:
        _fail("key", "private key is not Ed25519")
    pk = private.string()
    sk = private.string()
    private.string()  # comment
    if len(pk) != 32 or len(sk) != 64 or sk[32:] != pk:
        _fail("key", "private key halves do not match")
    if ed25519_blob_from_pk(pk) != public_blob:
        _fail("key", "private key does not match its public blob")
    return public_blob


class Certificate:
    __slots__ = ("subject_blob", "serial", "cert_type", "key_identity", "principals",
                 "valid_after", "valid_before", "critical_options", "extensions", "ca_blob")


def parse_certificate(blob: bytes) -> Certificate:
    reader = _Reader(blob)
    if reader.string() != CERT_TYPE:
        _fail("cert", "not an Ed25519 certificate")
    reader.string()  # nonce
    cert = Certificate()
    cert.subject_blob = ed25519_blob_from_pk(reader.string())
    cert.serial = reader.u64()
    cert.cert_type = reader.u32()
    try:
        cert.key_identity = reader.string().decode("utf-8")
    except UnicodeDecodeError:
        _fail("cert", "certificate key identity is not UTF-8")
    principals = _Reader(reader.string())
    names = []
    while not principals.done():
        try:
            names.append(principals.string().decode("utf-8"))
        except UnicodeDecodeError:
            _fail("cert", "certificate principal is not UTF-8")
    cert.principals = names
    cert.valid_after = reader.u64()
    cert.valid_before = reader.u64()
    cert.critical_options = reader.string()
    cert.extensions = reader.string()
    reader.string()  # reserved
    cert.ca_blob = reader.string()
    reader.string()  # signature (checked by ssh-keygen)
    if not reader.done():
        _fail("cert", "trailing bytes after the certificate")
    return cert


def parse_cert_file(data: bytes) -> Certificate:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        _fail("cert", "certificate file is not ASCII")
    lines = text.split("\n")
    if len(lines) != 2 or lines[1] != "":
        _fail("cert", "certificate file must be one line")
    fields = lines[0].split(" ")
    if len(fields) < 2 or fields[0] != CERT_TYPE.decode("ascii"):
        _fail("cert", "not an Ed25519 certificate file")
    try:
        blob = base64.b64decode(fields[1], validate=True)
    except ValueError:
        _fail("cert", "certificate is not base64")
    return parse_certificate(blob)


def check_certificate(cert: Certificate, *, record_type: str, epoch: int, root_pub: str) -> str:
    """The certificate rules of 0a.2 section 3; returns the subject key_id."""
    if cert.cert_type != 1:
        _fail("cert", "certificate must be a user certificate")
    if cert.ca_blob != records.ed25519_blob(root_pub):
        _fail("cert-root", "certificate does not chain to the pinned epoch root")
    if cert.key_identity != f"{record_type}@e{epoch}":
        _fail("cert-identity", f"certificate key identity {cert.key_identity!r} is not "
              f"{record_type}@e{epoch}")
    if cert.principals != [record_type]:
        _fail("cert-principal", f"certificate principals {cert.principals} are not [{record_type}]")
    if cert.valid_after != 0 or cert.valid_before != FOREVER:
        _fail("cert-validity", "certificate validity must be always:forever")
    if cert.critical_options != b"":
        _fail("cert", "certificate carries critical options")
    return fingerprint(cert.subject_blob)


class Signature:
    __slots__ = ("public_blob", "namespace", "hash_alg")


def parse_signature(armored: str) -> Signature:
    lines = armored.strip("\n").split("\n")
    if len(lines) < 3 or lines[0] != SIG_BEGIN or lines[-1] != SIG_END:
        _fail("sig", "not an armored SSH signature")
    try:
        raw = base64.b64decode("".join(lines[1:-1]), validate=True)
    except ValueError:
        _fail("sig", "signature is not base64")
    if not raw.startswith(b"SSHSIG"):
        _fail("sig", "signature magic mismatch")
    reader = _Reader(raw[6:])
    if reader.u32() != 1:
        _fail("sig", "signature version must be 1")
    sig = Signature()
    sig.public_blob = reader.string()
    try:
        sig.namespace = reader.string().decode("utf-8")
    except UnicodeDecodeError:
        _fail("sig", "signature namespace is not UTF-8")
    reader.string()  # reserved
    sig.hash_alg = reader.string().decode("ascii", "replace")
    reader.string()  # signature blob
    if not reader.done():
        _fail("sig", "trailing bytes after the signature")
    return sig


def seal_signers_line(record_type: str, root_pub: str) -> bytes:
    return (f'{record_type} cert-authority,namespaces="{records.namespace(record_type)}" '
            f"{root_pub}\n").encode("ascii")


def pointer_signers_line(root_pub: str) -> bytes:
    return f'anchor-root namespaces="{records.POINTER_NAMESPACE}" {root_pub}\n'.encode("ascii")


def _yverify_failed(result: tools.Result) -> None:
    text = result.stderr.decode("utf-8", "replace")
    if "illegal option" in text or "unknown option" in text or "usage:" in text:
        raise tools.ToolError("ssh-keygen", "ssh-keygen does not accept -Y (OpenSSH >= 8.2)")


def verify_seal(*, record_type: str, epoch: int, root_pub: str, payload: bytes, sig: str) -> str:
    """Verify a record seal; returns the fingerprint of the certified subkey
    that made it. Raises KeyFileError on any failure."""
    records.check_type(record_type)
    parsed = parse_signature(sig)
    if parsed.namespace != records.namespace(record_type):
        _fail("sig-namespace", "seal namespace is not the record type's")
    cert = parse_certificate(parsed.public_blob)
    key_id = check_certificate(cert, record_type=record_type, epoch=epoch, root_pub=root_pub)
    memo = _memo_key("seal", record_type, epoch, root_pub, payload, sig)
    if _VERIFIED.get(memo) == key_id:
        return key_id
    signers = tools.write_scratch_file("allowed_signers", seal_signers_line(record_type, root_pub))
    sig_path = tools.write_scratch_file("seal.sig", sig.encode("ascii"))
    result = tools.run("ssh-keygen.verify", stdin=payload, allowed_signers=signers,
                       type=record_type, sig=sig_path)
    if result.returncode != 0:
        _yverify_failed(result)
        _fail("sig-verify", "ssh-keygen refused the seal: "
              + result.stderr.decode("utf-8", "replace").strip()[:200])
    _VERIFIED[memo] = key_id
    return key_id


def verify_pointer(*, root_pub: str, pointer: bytes, sig: str) -> None:
    """Verify an anchor pointer signature by the epoch root itself."""
    parsed = parse_signature(sig)
    if parsed.namespace != records.POINTER_NAMESPACE:
        _fail("pointer-namespace", "pointer signature namespace is wrong")
    if parsed.public_blob != records.ed25519_blob(root_pub):
        _fail("pointer-key", "pointer is not signed by the epoch root")
    memo = _memo_key("pointer", root_pub, pointer, sig)
    if _VERIFIED.get(memo) is True:
        return
    signers = tools.write_scratch_file("allowed_signers", pointer_signers_line(root_pub))
    sig_path = tools.write_scratch_file("pointer.sig", sig.encode("ascii"))
    result = tools.run("ssh-keygen.verify-pointer", stdin=pointer, allowed_signers=signers,
                       sig=sig_path)
    if result.returncode != 0:
        _yverify_failed(result)
        _fail("pointer-verify", "ssh-keygen refused the pointer signature: "
              + result.stderr.decode("utf-8", "replace").strip()[:200])
    _VERIFIED[memo] = True


def ssh_keygen_fingerprints(path: str, *, token: object = None) -> list[str]:
    """ssh-keygen -l -E sha256 over a file of one or more keys, one per
    line; for a certificate this also makes ssh-keygen check its CA
    signature. ssh-keygen silently skips a line it rejects, so callers
    compare the whole list, in order, with what they expect."""
    result = tools.run("ssh-keygen.fingerprint", token=token, pub=path)
    if result.returncode != 0:
        _fail("fingerprint", "ssh-keygen could not read the key: "
              + result.stderr.decode("utf-8", "replace").strip()[:200])
    out = []
    for line in result.stdout.decode("ascii", "replace").splitlines():
        fields = line.split(" ")
        if len(fields) < 2 or not records.KEY_ID_RE.fullmatch(fields[1]):
            _fail("fingerprint", "unexpected ssh-keygen fingerprint output")
        out.append(fields[1])
    return out


def ssh_keygen_fingerprint(path: str, *, token: object = None) -> str:
    """The fingerprint of a file holding exactly one key. Returns
    'SHA256:...'."""
    prints = ssh_keygen_fingerprints(path, token=token)
    if len(prints) != 1:
        _fail("fingerprint", "ssh-keygen did not accept exactly one key")
    return prints[0]


def check_cert_bytes(data: bytes, *, record_type: str, epoch: int, root_pub: str,
                     subject_pub: str) -> str:
    """Check a certificate file's content: structure and rules in Python, and
    its CA signature by ssh-keygen on a scratch copy. Returns the key_id."""
    cert = parse_cert_file(data)
    key_id = check_certificate(cert, record_type=record_type, epoch=epoch, root_pub=root_pub)
    if cert.subject_blob != records.ed25519_blob(subject_pub):
        _fail("cert-subject", "certificate subject is not the subkey")
    memo = _memo_key("cert", data, record_type, epoch, root_pub, subject_pub)
    if _VERIFIED.get(memo) == key_id:
        return key_id
    copy = tools.write_scratch_file("cert.pub", data)
    if ssh_keygen_fingerprint(copy) != key_id:
        _fail("cert", "ssh-keygen fingerprint disagrees with the certificate subject")
    _VERIFIED[memo] = key_id
    return key_id


def check_epoch_files(files: dict[str, bytes], *, epoch: int, root_pub: str,
                      subkeys: dict[str, str]) -> None:
    """files maps a published name (root, root.pub, <type>, <type>.pub,
    <type>-cert.pub) to its bytes. Any absent or mismatching file raises."""
    needed = ["root", "root.pub"]
    for name in records.TYPES:
        needed += [name, f"{name}.pub", f"{name}-cert.pub"]
    for name in needed:
        if name not in files:
            _fail("key-missing", f"published key file missing: {name}")
    root_blob = records.ed25519_blob(root_pub)
    if parse_pub_file(files["root.pub"]) != root_pub:
        _fail("key-mismatch", "root.pub is not the epoch root the record names")
    if parse_private_key(files["root"]) != root_blob:
        _fail("key-mismatch", "root private key does not match root.pub")
    pending = []
    for name in records.TYPES:
        pub = parse_pub_file(files[f"{name}.pub"])
        if records.key_id_of_pub(pub) != subkeys[name]:
            _fail("key-mismatch", f"{name}.pub is not the subkey the record names")
        if parse_private_key(files[name]) != records.ed25519_blob(pub):
            _fail("key-mismatch", f"{name} private key does not match {name}.pub")
        data = files[f"{name}-cert.pub"]
        cert = parse_cert_file(data)
        key_id = check_certificate(cert, record_type=name, epoch=epoch, root_pub=root_pub)
        if cert.subject_blob != records.ed25519_blob(pub):
            _fail("cert-subject", f"{name} certificate subject is not the subkey")
        memo = _memo_key("cert", data, name, epoch, root_pub, pub)
        if _VERIFIED.get(memo) != key_id:
            pending.append((memo, data, key_id))
    if pending:
        # One ssh-keygen run checks every certificate's CA signature; one it
        # rejects is missing from the output, so the list must match exactly.
        copy = tools.write_scratch_file("certs.pub", b"".join(data for _m, data, _k in pending))
        if ssh_keygen_fingerprints(copy) != [key_id for _m, _d, key_id in pending]:
            _fail("cert", "ssh-keygen did not verify every certificate of the epoch")
        for memo, _data, key_id in pending:
            _VERIFIED[memo] = key_id
