"""The independent verifier (scripts/loop-authority-verify; task-graph-v1
Phase A, 0a.2). Run only by that wrapper as `python3 -I -B <this file>`.
Shares no code with the writer's library: every parser, encoder, and check
below is this file's own. Its first act is to create its temporary directory
with O_NOFOLLOW on every component; it writes nothing else.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys

BINARY_DIRS = ("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin")
ANCHOR_REF = "refs/olddonkey-loop/anchor"
VERIFY_REF = "refs/readback/anchor"
POINTER_NS = "olddonkey-loop.anchor.pointer.v1"
IDENTITY = "olddonkey-loop <anchor@olddonkey-loop.invalid>"
TYPES = (
    "store.genesis", "epoch.rotated", "epoch.revoked", "store.regenesis", "request.opened",
    "request.cancelled", "request.expired", "request.redeemed", "nonce.issued",
    "repo.registered", "repo.rebound", "exec-root.registered", "standing.granted",
    "standing.revoked", "entry.enrolled", "entry.revoked", "platform.designated",
)
STORE_ID = re.compile(r"^[0-9a-f]{32}$")
KEY_ID = re.compile(r"^SHA256:[A-Za-z0-9+/]{43}$")
KEY_DIR = re.compile(r"^epoch-([1-9][0-9]*)-[0-9a-f]{16}$")
OID = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
SIG = re.compile(r"^-----BEGIN SSH SIGNATURE-----\n(?:[A-Za-z0-9+/=]{1,76}\n)+"
                 r"-----END SSH SIGNATURE-----\n?$")
HEADER = re.compile(rb"^OLF1 ([1-9][0-9]{0,15}) ([a-z][a-z0-9.-]{0,63}) (0|[1-9][0-9]{0,7}) "
                    rb"(sha256:[0-9a-f]{64})$")
MAX_INT = 2**53 - 1
FOREVER = 0xFFFFFFFFFFFFFFFF
EXIT = {"committed": 0, "pending": 5, "quarantined": 6, "terminal": 7, "env": 9,
        "invalid": 12}
TERMINAL = ("genesis-invalid", "anchor-mismatch", "genesis-quarantined")
# The activation boundary (A2.1, A2.6): registry versions in order, and the
# record types and request protocols each admits.
VERSIONS = ("tg-v1.0a",)
ALLOWED = {"tg-v1.0a": {"types": ("store.genesis", "epoch.rotated", "epoch.revoked",
                                  "store.regenesis"), "protocols": ()}}
BOUNDARY_RULES = ("type-not-admitted", "introducer-version", "introducer-protocols",
                  "introducer-types")
os.umask(0o077)


class Bad(Exception):
    """The evidence fails a rule; rule is a stable name."""

    def __init__(self, rule: str, detail: str = "") -> None:
        super().__init__(detail or rule)
        self.rule = rule
        self.detail = detail or rule


class Unreachable(Exception):
    pass


class EnvError(Exception):
    pass


def test_mode() -> bool:
    return os.environ.get("LOOP_AUTHORITY_TEST") == "1"


# ---------------------------------------------------------------------------
# Canonical JSON (own encoder)
# ---------------------------------------------------------------------------

def _canon_check(value: object, depth: int = 0) -> None:
    if depth > 64:
        raise Bad("canonical", "nesting too deep")
    if value is None or value is True or value is False:
        return
    if type(value) is int:
        if not -MAX_INT <= value <= MAX_INT:
            raise Bad("canonical", "integer out of range")
        return
    if type(value) is str:
        return
    if type(value) is list:
        for item in value:
            _canon_check(item, depth + 1)
        return
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise Bad("canonical", "non-string key")
            _canon_check(item, depth + 1)
        return
    raise Bad("canonical", f"unsupported value {type(value).__name__}")


def canon(value: object) -> bytes:
    _canon_check(value)
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                          allow_nan=False).encode("utf-8")
    except UnicodeEncodeError as error:
        raise Bad("canonical", "string is not encodable as UTF-8") from error


def load_canonical(data: bytes, what: str) -> object:
    def no_float(raw: str) -> object:
        raise Bad("canonical", f"{what}: float")

    def pairs(items: list) -> dict:
        out: dict = {}
        for key, item in items:
            if key in out:
                raise Bad("canonical", f"{what}: duplicate key")
            out[key] = item
        return out

    try:
        value = json.loads(data.decode("utf-8"), parse_float=no_float, parse_constant=no_float,
                           object_pairs_hook=pairs)
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise Bad("canonical", f"{what}: not JSON ({error})") from error
    if canon(value) != data:
        raise Bad("canonical", f"{what}: not in canonical form")
    return value


def exact(value: object, keys: tuple, what: str) -> dict:
    if type(value) is not dict or set(value) != set(keys):
        raise Bad("schema", f"{what}: fields are not exactly {sorted(keys)}")
    return value


def need(condition: bool, rule: str, detail: str) -> None:
    if not condition:
        raise Bad(rule, detail)


def pos_int(value: object, minimum: int = 1) -> bool:
    return type(value) is int and minimum <= value <= MAX_INT


# ---------------------------------------------------------------------------
# SSH wire format: keys, certificates, signatures
# ---------------------------------------------------------------------------

class Wire:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def take(self, n: int) -> bytes:
        if n < 0 or self.pos + n > len(self.data):
            raise Bad("ssh-wire", "truncated")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u32(self) -> int:
        return struct.unpack(">I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack(">Q", self.take(8))[0]

    def s(self) -> bytes:
        return self.take(self.u32())

    def end(self) -> bool:
        return self.pos == len(self.data)


def sstr(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + data


def ed_blob(pk: bytes) -> bytes:
    need(len(pk) == 32, "ssh-key", "Ed25519 key must be 32 bytes")
    return sstr(b"ssh-ed25519") + sstr(pk)


def pub_blob(line: str) -> bytes:
    need(type(line) is str and line.startswith("ssh-ed25519 ") and line.count(" ") == 1,
         "ssh-key", "public key must be 'ssh-ed25519 <base64>'")
    try:
        blob = base64.b64decode(line[12:], validate=True)
    except ValueError as error:
        raise Bad("ssh-key", "public key is not base64") from error
    need(base64.b64encode(blob).decode() == line[12:], "ssh-key", "non-canonical base64")
    wire = Wire(blob)
    need(wire.s() == b"ssh-ed25519", "ssh-key", "not an Ed25519 key")
    ed_blob(wire.s())
    need(wire.end(), "ssh-key", "trailing key bytes")
    return blob


def fingerprint(blob: bytes) -> str:
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def parse_cert(blob: bytes) -> dict:
    wire = Wire(blob)
    need(wire.s() == b"ssh-ed25519-cert-v01@openssh.com", "cert", "not an Ed25519 certificate")
    wire.s()
    subject = ed_blob(wire.s())
    wire.u64()
    kind = wire.u32()
    key_identity = wire.s().decode("utf-8", "replace")
    principals_wire = Wire(wire.s())
    principals = []
    while not principals_wire.end():
        principals.append(principals_wire.s().decode("utf-8", "replace"))
    after, before = wire.u64(), wire.u64()
    critical = wire.s()
    wire.s()
    wire.s()
    ca = wire.s()
    wire.s()
    need(wire.end(), "cert", "trailing certificate bytes")
    return {"subject": subject, "type": kind, "identity": key_identity, "principals": principals,
            "after": after, "before": before, "critical": critical, "ca": ca}


def parse_sig(armored: str) -> dict:
    lines = armored.strip("\n").split("\n")
    need(len(lines) >= 3 and lines[0] == "-----BEGIN SSH SIGNATURE-----"
         and lines[-1] == "-----END SSH SIGNATURE-----", "sig", "not an armored SSH signature")
    try:
        raw = base64.b64decode("".join(lines[1:-1]), validate=True)
    except ValueError as error:
        raise Bad("sig", "signature is not base64") from error
    need(raw.startswith(b"SSHSIG"), "sig", "bad signature magic")
    wire = Wire(raw[6:])
    need(wire.u32() == 1, "sig", "signature version")
    public = wire.s()
    namespace = wire.s().decode("utf-8", "replace")
    wire.s()
    wire.s()
    wire.s()
    need(wire.end(), "sig", "trailing signature bytes")
    return {"public": public, "namespace": namespace}


def parse_private(data: bytes) -> bytes:
    lines = data.decode("ascii", "replace").strip("\n").split("\n")
    need(len(lines) >= 3 and lines[0] == "-----BEGIN OPENSSH PRIVATE KEY-----"
         and lines[-1] == "-----END OPENSSH PRIVATE KEY-----", "key-file", "not a private key")
    try:
        raw = base64.b64decode("".join(lines[1:-1]), validate=True)
    except ValueError as error:
        raise Bad("key-file", "private key is not base64") from error
    need(raw.startswith(b"openssh-key-v1\x00"), "key-file", "private key magic")
    wire = Wire(raw[15:])
    need(wire.s() == b"none" and wire.s() == b"none" and wire.s() == b"", "key-file",
         "private key must be unencrypted")
    need(wire.u32() == 1, "key-file", "one key per file")
    public = wire.s()
    private = Wire(wire.s())
    need(private.u32() == private.u32(), "key-file", "check integers")
    need(private.s() == b"ssh-ed25519", "key-file", "not Ed25519")
    pk, sk = private.s(), private.s()
    need(len(sk) == 64 and sk[32:] == pk and ed_blob(pk) == public, "key-file",
         "private key halves disagree")
    return public


def pub_file(data: bytes) -> str:
    text = data.decode("ascii", "replace")
    need(text.endswith("\n") and text.count("\n") == 1, "key-file", "one-line public key file")
    fields = text[:-1].split(" ")
    need(len(fields) >= 2, "key-file", "public key file fields")
    line = f"{fields[0]} {fields[1]}"
    pub_blob(line)
    return line


def cert_file(data: bytes) -> dict:
    text = data.decode("ascii", "replace")
    need(text.endswith("\n") and text.count("\n") == 1, "key-file", "one-line certificate file")
    fields = text[:-1].split(" ")
    need(len(fields) >= 2 and fields[0] == "ssh-ed25519-cert-v01@openssh.com", "key-file",
         "certificate file type")
    try:
        return parse_cert(base64.b64decode(fields[1], validate=True))
    except ValueError as error:
        raise Bad("key-file", "certificate is not base64") from error


def cert_rules(cert: dict, record_type: str, epoch: int, root_pub: str) -> str:
    need(cert["type"] == 1, "cert", "not a user certificate")
    need(cert["ca"] == pub_blob(root_pub), "cert-root", "certificate does not chain to the pinned root")
    need(cert["identity"] == f"{record_type}@e{epoch}", "cert-identity",
         f"certificate identity {cert['identity']!r} is not {record_type}@e{epoch}")
    need(cert["principals"] == [record_type], "cert-principal", "certificate principal mismatch")
    need(cert["after"] == 0 and cert["before"] == FOREVER, "cert-validity",
         "certificate is not always:forever")
    need(cert["critical"] == b"", "cert", "certificate has critical options")
    return fingerprint(cert["subject"])


# ---------------------------------------------------------------------------
# The runner: allowlisted environment, four git forms, ssh-keygen
# ---------------------------------------------------------------------------

class Runner:
    def __init__(self) -> None:
        home = os.environ.get("HOME", "")
        if not home or not os.path.isabs(home):
            raise EnvError("HOME must be an absolute path")
        self.home = os.path.realpath(home)
        self.authority = os.path.join(self.home, ".config", "olddonkey-loop", "authority")
        self.temp = ""
        self.repo = ""
        self.remote: dict | None = None
        self.test_bins = False
        self.cache: dict = {}

    def binary(self, name: str) -> str:
        if name in self.cache:
            return self.cache[name]
        dirs = list(BINARY_DIRS)
        override = os.environ.get("LOOP_AUTHORITY_TEST_BIN_DIR", "")
        if test_mode() and override:
            if not os.path.isabs(override) or not os.path.isdir(override):
                raise EnvError("LOOP_AUTHORITY_TEST_BIN_DIR must be an absolute directory")
            dirs.insert(0, override)
            self.test_bins = True
        for directory in dirs:
            path = os.path.join(directory, name)
            try:
                info = os.stat(path)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode) and os.access(path, os.X_OK):
                self.cache[name] = path
                return path
        if name == "gh":
            self.cache[name] = ""
            return ""
        raise EnvError(f"{name} not found in {', '.join(dirs)}")

    def make_temp(self) -> None:
        """A fresh directory under $HOME/.cache/olddonkey-loop/verify, each
        component opened without following symlinks."""
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        try:
            fd = os.open(self.home, flags)
        except OSError as error:
            raise EnvError(f"cannot open HOME: {error}") from error
        try:
            for part in (".cache", "olddonkey-loop", "verify"):
                try:
                    child = os.open(part, flags, dir_fd=fd)
                except FileNotFoundError:
                    os.mkdir(part, 0o700, dir_fd=fd)
                    child = os.open(part, flags, dir_fd=fd)
                os.close(fd)
                fd = child
                if os.fstat(fd).st_uid != os.getuid():
                    raise EnvError(f"foreign-owned temporary path component: {part}")
            name = f"{os.getpid()}-{secrets.token_hex(8)}"
            os.mkdir(name, 0o700, dir_fd=fd)
        except OSError as error:
            raise EnvError(f"cannot create the temporary directory (a symlinked or unusable "
                           f"path component?): {error}") from error
        finally:
            os.close(fd)
        self.temp = os.path.join(self.home, ".cache", "olddonkey-loop", "verify", name)
        real = os.path.realpath(self.temp)
        if real == self.authority or real.startswith(self.authority + os.sep):
            raise EnvError("temporary directory resolves under the authority directory")

    def cleanup(self) -> None:
        if self.temp and os.path.isdir(self.temp):
            shutil.rmtree(self.temp, ignore_errors=True)

    def env(self, git: bool) -> dict:
        env = {"PATH": ":".join(BINARY_DIRS), "HOME": self.home, "LANG": "C", "LC_ALL": "C",
               "TMPDIR": self.temp}
        if git:
            if os.environ.get("SSH_AUTH_SOCK"):
                env["SSH_AUTH_SOCK"] = os.environ["SSH_AUTH_SOCK"]
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_TERMINAL_PROMPT"] = "0"
        return env

    def transport(self) -> list[str]:
        remote = self.remote
        assert remote is not None
        options = ["-c", "protocol.allow=never", "-c", f"protocol.{remote['transport']}.allow=always"]
        if remote["transport"] == "ssh":
            options += ["-c", f"core.sshCommand={self.binary('ssh')} -F /dev/null -o BatchMode=yes"
                              " -o StrictHostKeyChecking=yes -o UpdateHostKeys=no"]
        elif remote["transport"] == "https":
            options += ["-c", "http.sslVerify=true", "-c", "http.followRedirects=false"]
            gh = self.binary("gh")
            if gh:
                options += ["-c", "credential.helper=", "-c",
                            f"credential.helper=!{gh} auth git-credential"]
        return options

    def git_argv(self, form: str, arg: str = "", oid: str = "") -> list[str]:
        prefix = [self.binary("git"), "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        if form == "init":
            return prefix + ["-C", self.repo, "init", "--bare", "--template=",
                             "--object-format=sha1", "."]
        if form == "fetch":
            assert self.remote is not None
            return prefix + self.transport() + ["-C", self.repo, "fetch", "--no-tags",
                                                "--no-write-fetch-head", self.remote["url"],
                                                "+refs/olddonkey-loop/*:refs/readback/*"]
        if form == "ls-remote":
            assert self.remote is not None
            return prefix + self.transport() + ["-C", self.repo, "ls-remote",
                                                self.remote["url"], ANCHOR_REF]
        if form == "cat-file":
            if arg not in ("-t", "-p") or not OID.fullmatch(oid):
                raise EnvError("cat-file form refused")
            return prefix + ["-C", self.repo, "cat-file", arg, oid]
        raise EnvError(f"git form outside the four allowed: {form}")

    def run(self, argv: list[str], *, git: bool, stdin: bytes = b"", form: str = "") -> subprocess.CompletedProcess:
        try:
            return subprocess.run(argv, input=stdin, capture_output=True, env=self.env(git),
                                  cwd=self.temp, timeout=120 if form in ("fetch", "ls-remote") else 60,
                                  check=False, close_fds=True)
        except subprocess.TimeoutExpired as error:
            if form in ("fetch", "ls-remote"):
                raise Unreachable(f"git {form} timed out") from error
            raise EnvError("local command timed out") from error

    def init_repo(self) -> None:
        self.repo = os.path.join(self.temp, "anchor.git")
        os.mkdir(self.repo, 0o700)
        result = self.run(self.git_argv("init"), git=True)
        if result.returncode != 0:
            raise EnvError("git init of the scratch repository failed")
        with open(os.path.join(self.repo, "config"), "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
        sections = [line.strip() for line in text.splitlines()
                    if line.strip().startswith("[")]
        if not sections or any(section.lower() != "[core]" for section in sections):
            raise EnvError(f"scratch config holds sections other than [core]: {sections}")

    def fetch(self) -> str | None:
        """The fetched anchor tip, None when the ref is absent; Unreachable
        when the remote cannot be read."""
        observed = self.run(self.git_argv("ls-remote"), git=True, form="ls-remote")
        if observed.returncode != 0:
            raise Unreachable(observed.stderr.decode("utf-8", "replace").strip()[:300])
        matches = []
        for line in observed.stdout.decode("ascii", "replace").splitlines():
            if not line:
                continue
            oid, tab, ref = line.partition("\t")
            if not tab or not ref.startswith("refs/") or not OID.fullmatch(oid):
                raise Unreachable("ls-remote returned a malformed ref line")
            if ref == ANCHOR_REF:
                matches.append(oid)
        if len(matches) > 1:
            raise Unreachable("ls-remote returned more than one exact anchor ref")
        if not matches:
            return None
        result = self.run(self.git_argv("fetch"), git=True, form="fetch")
        if result.returncode != 0:
            text = result.stderr.decode("utf-8", "replace")
            raise Unreachable(text.strip()[:300])
        path = os.path.join(self.repo, *VERIFY_REF.split("/"))
        try:
            with open(path, "rb") as handle:
                oid = handle.read(128).decode("ascii", "replace").strip()
        except OSError:
            oid = ""
            try:
                with open(os.path.join(self.repo, "packed-refs"), "rb") as handle:
                    for line in handle.read().decode("ascii", "replace").splitlines():
                        value, _sp, ref = line.partition(" ")
                        if ref == VERIFY_REF:
                            oid = value
            except OSError:
                pass
        if not OID.fullmatch(oid):
            raise Unreachable("fetched ref is missing or malformed")
        return oid

    def cat(self, mode: str, oid: str) -> bytes:
        result = self.run(self.git_argv("cat-file", mode, oid), git=True)
        need(result.returncode == 0, "anchor-objects", f"object {oid} missing")
        return result.stdout

    def write_temp(self, name: str, data: bytes) -> str:
        path = os.path.join(self.temp, f"{secrets.token_hex(4)}-{name}")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise EnvError(f"short write to {path}")
                view = view[written:]
        finally:
            os.close(fd)
        return path

    def ssh_verify(self, line: bytes, principal: str, namespace: str, data: bytes, sig: str) -> bool:
        signers = self.write_temp("allowed_signers", line)
        sig_path = self.write_temp("sig", sig.encode("ascii"))
        result = self.run([self.binary("ssh-keygen"), "-Y", "verify", "-f", signers, "-I",
                           principal, "-n", namespace, "-s", sig_path], git=False, stdin=data)
        return result.returncode == 0

    def ssh_fingerprints(self, data: bytes) -> list[str]:
        """One ssh-keygen -l run over one or more keys, one per line (for a
        certificate it checks the CA signature). A line ssh-keygen rejects
        is silently missing from the output: callers compare the list."""
        path = self.write_temp("certs.pub", data)
        result = self.run([self.binary("ssh-keygen"), "-l", "-E", "sha256", "-f", path], git=False)
        need(result.returncode == 0, "key-file", "ssh-keygen refused the certificate")
        prints = []
        for line in result.stdout.decode("ascii", "replace").splitlines():
            fields = line.split(" ")
            need(len(fields) > 1 and bool(KEY_ID.fullmatch(fields[1])), "key-file",
                 "fingerprint output")
            prints.append(fields[1])
        return prints


RUN: Runner


# ---------------------------------------------------------------------------
# Remote forms
# ---------------------------------------------------------------------------

HOST = r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?"
PATH = r"[A-Za-z0-9._][A-Za-z0-9._/-]{0,254}"


def parse_remote(url: object) -> dict:
    need(type(url) is str and 0 < len(url) <= 4096, "remote", "remote must be a string")
    assert type(url) is str
    need(not url.startswith("-") and "::" not in url and not any(c.isspace() for c in url)
         and all(0x21 <= ord(c) <= 0x7E for c in url), "remote", "remote form refused")

    def clean(path: str) -> bool:
        return all(part not in ("", ".", "..") for part in path.split("/"))

    match = re.fullmatch(rf"git@({HOST}):({PATH})\.git", url)
    if match and clean(match.group(2) + ".git"):
        return {"url": url, "transport": "ssh", "class": "production"}
    match = re.fullmatch(rf"https://({HOST})(:[1-9][0-9]{{0,4}})?/({PATH})\.git", url)
    if match and clean(match.group(3) + ".git") and "@" not in url and "?" not in url \
            and "#" not in url and (not match.group(2) or int(match.group(2)[1:]) <= 65535):
        return {"url": url, "transport": "https", "class": "production"}
    match = re.fullmatch(r"file:///([A-Za-z0-9._/+@-]{1,4000})", url)
    if match and clean(match.group(1)):
        return {"url": url, "transport": "file", "class": "test"}
    raise Bad("remote", f"remote form refused: {url!r}")


# ---------------------------------------------------------------------------
# Reading the authority directory (read-only, no symlinks)
# ---------------------------------------------------------------------------

def auth(*parts: str) -> str:
    return os.path.join(RUN.authority, *parts)


def no_links(path: str) -> None:
    current = RUN.home
    for part in [p for p in path[len(RUN.home):].split(os.sep) if p]:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            return
        need(not stat.S_ISLNK(info.st_mode), "layout", f"symlink: {current}")


def read(path: str, missing_ok: bool = False) -> bytes | None:
    no_links(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if missing_ok:
            return None
        raise Bad("layout", f"missing: {path}")
    except OSError as error:
        raise Bad("layout", f"cannot open {path}: {error}") from error
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
             "layout", f"not a single-link owned regular file: {path}")
        need(stat.S_IMODE(info.st_mode) & 0o077 == 0, "layout", f"group/other access: {path}")
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def is_dir(path: str) -> bool:
    no_links(path)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "layout",
         f"not an owned directory: {path}")
    return True


# ---------------------------------------------------------------------------
# Frames and records
# ---------------------------------------------------------------------------

def frame_digest(seq: int, kind: str, content: bytes) -> str:
    return "sha256:" + hashlib.sha256(f"OLF1 {seq} {kind} {len(content)}".encode() + content).hexdigest()


def parse_frames(data: bytes, first: int = 1) -> tuple[list, int, str | None]:
    """(complete frames, offset after them, error at a complete-but-bad frame)."""
    frames = []
    offset = 0
    while offset < len(data):
        newline = data.find(b"\n", offset, offset + 161)
        if newline < 0:
            return frames, offset, ("header too long" if len(data) - offset > 160 else None)
        match = HEADER.fullmatch(data[offset:newline])
        if match is None:
            return frames, offset, "header does not parse"
        seq, kind, length = int(match.group(1)), match.group(2).decode(), int(match.group(3))
        digest = match.group(4).decode()
        end = newline + 1 + length
        if end + 1 > len(data):
            return frames, offset, None
        content = data[newline + 1:end]
        if data[end:end + 1] != b"\n":
            return frames, offset, "not terminated"
        if frame_digest(seq, kind, content) != digest or seq != first + len(frames):
            return frames, offset, "digest or sequence"
        frames.append({"seq": seq, "type": kind, "length": length, "digest": digest,
                       "offset": offset, "end": end + 1, "content": content})
        offset = end + 1
    return frames, offset, None


def check_principal(value: object) -> None:
    principal = exact(value, ("kind", "tty", "start_token"), "principal")
    need(principal["kind"] == "operator-tty", "principal", "principal kind")
    need(type(principal["tty"]) is str and bool(re.fullmatch(r"/dev/[A-Za-z0-9/._-]{1,64}",
                                                              principal["tty"])), "principal", "tty")
    token = exact(principal["start_token"], ("boot_id", "pid", "start_time"), "start_token")
    need(type(token["boot_id"]) is str and bool(re.fullmatch(r"[A-Za-z0-9-]{8,64}",
                                                             token["boot_id"])), "principal", "boot")
    need(pos_int(token["pid"]) and pos_int(token["start_time"], 0), "principal", "pid/start")


GENESIS_BODY = ("ceremony", "envelope_digest", "principal", "remote", "anchor_ref", "anchor_class",
                "commit_identity", "epoch", "key_dir", "root_pub", "root_key_id", "subkeys",
                "registry_version", "admitted_protocols")
REGENESIS_BODY = GENESIS_BODY + ("prev_generation", "prev_commit", "quarantined", "archive")
ROTATED_BODY = ("ceremony", "envelope_digest", "principal", "remote", "from_epoch", "epoch",
                "key_dir", "root_pub", "root_key_id", "subkeys", "registry_version",
                "admitted_protocols")
REVOKED_BODY = ("ceremony", "envelope_digest", "principal", "epoch", "prior_state")
PREV_KEYS = ("store_id", "generation", "last_seq", "last_record_digest")
ACTIVE_KEYS = ("store_id", "generation", "genesis_digest", "seq", "record_digest", "epoch", "key_id")


def check_prev(value: object) -> dict:
    prev = exact(value, PREV_KEYS, "prev_generation")
    need(type(prev["store_id"]) is str and bool(STORE_ID.fullmatch(prev["store_id"]))
         and pos_int(prev["generation"]) and pos_int(prev["last_seq"])
         and type(prev["last_record_digest"]) is str
         and bool(DIGEST.fullmatch(prev["last_record_digest"])), "schema", "prev_generation")
    return prev


def check_keys_body(body: dict, epoch: int) -> None:
    match = KEY_DIR.fullmatch(str(body["key_dir"]))
    need(match is not None and int(match.group(1)) == epoch, "schema", "key_dir")
    need(fingerprint(pub_blob(body["root_pub"])) == body["root_key_id"], "schema", "root_key_id")
    subkeys = exact(body["subkeys"], TYPES, "subkeys")
    need(all(type(v) is str and KEY_ID.fullmatch(v) for v in subkeys.values())
         and len(set(subkeys.values())) == len(TYPES)
         and body["root_key_id"] not in subkeys.values(), "schema", "subkeys")


def introducer(body: dict) -> tuple[str, tuple]:
    """registry_version known here; admitted_protocols a subset of what that
    version allows."""
    version = body["registry_version"]
    need(type(version) is str and version in ALLOWED, "introducer-version",
         f"unknown registry_version {version!r}")
    protocols = body["admitted_protocols"]
    need(type(protocols) is list and all(type(p) is str for p in protocols)
         and len(set(protocols)) == len(protocols), "schema", "admitted_protocols")
    need(set(protocols) <= set(ALLOWED[version]["protocols"]), "introducer-protocols",
         f"{version} does not allow {sorted(set(protocols) - set(ALLOWED[version]['protocols']))}")
    return version, tuple(protocols)


def succession(version: str, protocols: tuple, before: tuple | None, same_generation: bool) -> None:
    """Not lower than the predecessor epoch's version; within a generation
    the protocols and the admitted type set only grow."""
    if before is None:
        return
    old_version, old_protocols = before
    need(VERSIONS.index(version) >= VERSIONS.index(old_version), "introducer-version",
         "registry_version is lower than the predecessor epoch's")
    if same_generation:
        need(set(old_protocols) <= set(protocols), "introducer-protocols",
             "an introducer dropped a protocol")
        need(set(ALLOWED[old_version]["types"]) <= set(ALLOWED[version]["types"]),
             "introducer-types", "an introducer's admitted type set shrank")


def check_body(kind: str, body: object) -> dict:
    if kind in ("store.genesis", "store.regenesis"):
        value = exact(body, GENESIS_BODY if kind == "store.genesis" else REGENESIS_BODY, "body")
        introducer(value)
        need(value["ceremony"] == ("genesis" if kind == "store.genesis" else "regenesis"),
             "schema", "ceremony")
        need(type(value["envelope_digest"]) is str and bool(DIGEST.fullmatch(value["envelope_digest"])),
             "schema", "envelope_digest")
        check_principal(value["principal"])
        remote = parse_remote(value["remote"])
        need(value["anchor_class"] == remote["class"], "anchor-class",
             "anchor_class disagrees with the pinned remote")
        need(value["anchor_ref"] == ANCHOR_REF and value["epoch"] == 1 and value["commit_identity"]
             == {"name": "olddonkey-loop", "email": "anchor@olddonkey-loop.invalid"}, "schema",
             "genesis constants")
        check_keys_body(value, 1)
        if kind == "store.regenesis":
            check_prev(value["prev_generation"])
            need(type(value["prev_commit"]) is str and bool(OID.fullmatch(value["prev_commit"])),
                 "schema", "prev_commit")
            quarantined = exact(value["quarantined"], ("last_seq", "last_record_digest"),
                                "quarantined")
            need(pos_int(quarantined["last_seq"]) and type(quarantined["last_record_digest"]) is str
                 and bool(DIGEST.fullmatch(quarantined["last_record_digest"])), "schema",
                 "quarantined")
            need(value["archive"] == "archive/" + value["prev_generation"]["store_id"], "schema",
                 "archive")
        return value
    if kind == "epoch.rotated":
        value = exact(body, ROTATED_BODY, "body")
        introducer(value)
        need(value["ceremony"] == "rotate", "schema", "ceremony")
        need(type(value["envelope_digest"]) is str and bool(DIGEST.fullmatch(value["envelope_digest"])),
             "schema", "envelope_digest")
        check_principal(value["principal"])
        parse_remote(value["remote"])
        need(pos_int(value["from_epoch"]) and value["epoch"] == value["from_epoch"] + 1, "schema",
             "rotation epochs")
        check_keys_body(value, value["epoch"])
        return value
    if kind == "epoch.revoked":
        value = exact(body, REVOKED_BODY, "body")
        need(value["ceremony"] == "revoke" and pos_int(value["epoch"])
             and value["prior_state"] in ("active", "verify-only"), "schema", "revocation body")
        need(type(value["envelope_digest"]) is str and bool(DIGEST.fullmatch(value["envelope_digest"])),
             "schema", "envelope_digest")
        check_principal(value["principal"])
        return value
    raise Bad("type-not-admitted", f"{kind} has no body schema: no known version admits it")


class Store:
    def __init__(self, store_id: str, generation: int, directory: str, archived: bool) -> None:
        self.store_id = store_id
        self.generation = generation
        self.directory = directory
        self.archived = archived
        self.data = b""
        self.records: list[dict] = []
        self.epochs: dict = {}
        self.active: int | None = None
        self.revoked_active = False
        self.remote: str | None = None
        self.klass: str | None = None
        self.error: tuple | None = None
        self.tail = b""
        self.tail_offset = 0
        self.tail_error: str | None = None
        self.ancestors: list = []

    @property
    def L(self) -> int:
        return len(self.records)

    def ptr(self, k: int) -> dict:
        record = self.records[k - 1]
        epoch = self.epochs[record["pointer_epoch"]]
        return {"store_id": self.store_id, "generation": self.generation,
                "genesis_digest": self.records[0]["digest"], "seq": k,
                "record_digest": record["digest"], "epoch": record["pointer_epoch"],
                "key_id": epoch["root_key_id"]}

    def copy(self) -> "Store":
        other = Store(self.store_id, self.generation, self.directory, self.archived)
        other.data = self.data
        other.records = list(self.records)
        other.epochs = {n: dict(e) for n, e in self.epochs.items()}
        other.active = self.active
        other.revoked_active = self.revoked_active
        other.remote = self.remote
        other.klass = self.klass
        other.ancestors = self.ancestors
        return other


def verify_seal(kind: str, epoch: int, root_pub: str, payload: bytes, sig: str) -> str:
    parsed = parse_sig(sig)
    need(parsed["namespace"] == f"olddonkey-loop.authority.{kind}.v1", "record-seal",
         "seal namespace")
    key_id = cert_rules(parse_cert(parsed["public"]), kind, epoch, root_pub)
    line = (f'{kind} cert-authority,namespaces="olddonkey-loop.authority.{kind}.v1" '
            f"{root_pub}\n").encode()
    need(RUN.ssh_verify(line, kind, f"olddonkey-loop.authority.{kind}.v1", payload, sig),
         "record-seal", "ssh-keygen refused the seal")
    return key_id


def verify_pointer(owner: Store, active: dict, prev: dict | None, sig: str) -> None:
    epoch = owner.epochs.get(active["epoch"])
    need(epoch is not None and epoch["root_key_id"] == active["key_id"], "anchor-signature",
         "the pointer names an unknown epoch root")
    parsed = parse_sig(sig)
    need(parsed["namespace"] == POINTER_NS and parsed["public"] == pub_blob(epoch["root_pub"]),
         "anchor-signature", "the pointer is not signed by the epoch root")
    line = f'anchor-root namespaces="{POINTER_NS}" {epoch["root_pub"]}\n'.encode()
    need(RUN.ssh_verify(line, "anchor-root", POINTER_NS, canon({"active": active,
                                                                "prev_generation": prev}), sig),
         "anchor-signature", "ssh-keygen refused the pointer signature")


def apply(store: Store, fr: dict, lineage_remote: str | None) -> None:
    """Record L + 1: content and envelope, chain, then type admission by
    its epoch introducer's registry version -- decided before any body
    schema -- then the body, the introducer's boundary, seal, and
    semantics."""
    content = exact(load_canonical(fr["content"], "frame content"), ("payload", "sig"), "content")
    payload = exact(content["payload"], ("type", "v", "store_id", "generation", "seq", "epoch",
                                         "key_id", "prev", "body"), "payload")
    sig = content["sig"]
    need(type(sig) is str and bool(SIG.fullmatch(sig)), "record-schema", "sig")
    kind = payload["type"]
    need(kind in TYPES, "record-schema", "type outside the closed list")
    seq = store.L + 1
    need(payload["v"] == 1 and type(payload["v"]) is int, "record-schema", "v")
    need(type(payload["key_id"]) is str and bool(KEY_ID.fullmatch(payload["key_id"]))
         and pos_int(payload["epoch"]), "record-schema", "key_id or epoch")
    need(type(payload["store_id"]) is str and bool(STORE_ID.fullmatch(payload["store_id"]))
         and pos_int(payload["generation"]), "record-schema", "store_id or generation")
    need(kind == fr["type"] and payload["seq"] == seq == fr["seq"], "record-header",
         "header and payload disagree")
    need(payload["store_id"] == store.store_id and payload["generation"] == store.generation,
         "record-store", "record names another store or generation")
    need(payload["prev"] == (store.records[-1]["digest"] if store.records else None),
         "record-chain", "prev chain")
    if seq == 1:
        need(kind == ("store.genesis" if store.generation == 1 else "store.regenesis"),
             "record-admission", "record 1 type")
    else:
        epoch = store.epochs.get(payload["epoch"])
        need(epoch is not None, "record-epoch", "an epoch never introduced")
        need(kind in ALLOWED[epoch["version"]]["types"], "type-not-admitted",
             f"{kind} is not admitted by epoch {payload['epoch']}'s {epoch['version']}")
    body = check_body(kind, payload["body"])
    need(not store.revoked_active, "record-after-quarantine", "record after active revocation")
    if seq == 1:
        need(payload["epoch"] == 1, "record-epoch", "record 1 epoch")
        need(kind in ALLOWED[body["registry_version"]]["types"], "type-not-admitted",
             f"{kind} is not admitted by its own registry version")
        before = None
        if store.generation > 1 and store.ancestors and store.ancestors[0].epochs:
            last = store.ancestors[0].epochs[max(store.ancestors[0].epochs)]
            before = (last["version"], last["protocols"])
        succession(body["registry_version"], tuple(body["admitted_protocols"]), before, False)
        if store.generation == 1:
            lineage_remote = body["remote"]
        need(body["remote"] == lineage_remote, "record-remote", "re-genesis changed the remote")
        root_pub, subkeys = body["root_pub"], body["subkeys"]
    else:
        need(kind in ("epoch.rotated", "epoch.revoked"), "record-admission", f"{kind} after 1")
        need(store.active is not None and payload["epoch"] == store.active, "record-epoch",
             "not sealed by the active epoch")
        root_pub = store.epochs[store.active]["root_pub"]
        subkeys = store.epochs[store.active]["subkeys"]
        if kind == "epoch.rotated":
            current = store.epochs[store.active]
            succession(body["registry_version"], tuple(body["admitted_protocols"]),
                       (current["version"], current["protocols"]), True)
    key_id = verify_seal(kind, payload["epoch"], root_pub, canon(payload), sig)
    need(key_id == payload["key_id"], "record-key-id", "payload key_id is not the verifying cert")
    need(subkeys[kind] == key_id, "record-key-id", "not the epoch's subkey for the type")
    if seq == 1:
        store.epochs[1] = {"root_pub": body["root_pub"], "root_key_id": body["root_key_id"],
                           "key_dir": body["key_dir"], "subkeys": body["subkeys"],
                           "state": "active", "version": body["registry_version"],
                           "protocols": tuple(body["admitted_protocols"])}
        store.active = 1
        store.remote = lineage_remote
        store.klass = parse_remote(lineage_remote)["class"]
        pointer_epoch = 1
    elif kind == "epoch.rotated":
        need(body["remote"] == store.remote, "record-remote", "rotation names another remote")
        need(body["from_epoch"] == store.active and body["epoch"] == max(store.epochs) + 1,
             "record-epoch", "rotation epochs")
        need(all(e["key_dir"] != body["key_dir"] for e in store.epochs.values()), "record-schema",
             "reused key dir")
        store.epochs[store.active]["state"] = "verify-only"
        store.epochs[body["epoch"]] = {"root_pub": body["root_pub"],
                                       "root_key_id": body["root_key_id"],
                                       "key_dir": body["key_dir"], "subkeys": body["subkeys"],
                                       "state": "active", "version": body["registry_version"],
                                       "protocols": tuple(body["admitted_protocols"])}
        store.active = body["epoch"]
        pointer_epoch = body["epoch"]
    else:
        target = store.epochs.get(body["epoch"])
        need(target is not None and target["state"] == body["prior_state"], "record-epoch",
             "revocation prior state")
        target["state"] = "revoked"
        pointer_epoch = store.active
        if body["epoch"] == store.active:
            store.active = None
            store.revoked_active = True
    store.records.append({"payload": payload, "digest": fr["digest"], "frame": fr,
                          "pointer_epoch": pointer_epoch})


def load(store_id: str, generation: int, archived: bool = False, depth: int = 0) -> Store:
    need(depth < 64, "lineage", "lineage too deep")
    directory = auth("archive" if archived else "stores", store_id)
    need(is_dir(directory), "store-missing", f"store directory missing: {directory}")
    store = Store(store_id, generation, directory, archived)
    lineage_remote = None
    data = read(os.path.join(directory, "log", "segment-000001.olf"))
    assert data is not None
    if generation > 1:
        frames, _off, _err = parse_frames(data)
        need(bool(frames), "lineage", "no re-genesis record")
        try:
            first = load_canonical(frames[0]["content"], "record 1")
            prev = check_prev(first["payload"]["body"]["prev_generation"])  # type: ignore[index]
        except (Bad, KeyError, TypeError) as error:
            raise Bad("lineage", "the re-genesis record does not name its previous store") from error
        need(prev["generation"] == generation - 1, "lineage", "previous generation")
        ancestor = load(prev["store_id"], generation - 1, archived=True, depth=depth + 1)
        # An archived generation is history: its valid prefix must verify, and
        # it must carry its quarantine marker; the invalid frame or tail that
        # quarantined it is discarded evidence and need not verify.
        need(ancestor.L >= 1, "lineage", "an archived ancestor has no valid record")
        need(marker(ancestor.directory), "lineage", "an archived ancestor has no quarantine marker")
        store.ancestors = [ancestor] + ancestor.ancestors
        lineage_remote = ancestor.remote
    store.data = data
    frames, offset, error = parse_frames(data)
    for fr in frames:
        try:
            apply(store, fr, lineage_remote)
        except Bad as bad:
            store.error = (fr["seq"], bad.rule, bad.detail)
            store.tail_offset = fr["offset"]
            store.tail = data[fr["offset"]:]
            return store
    store.tail_offset = offset
    store.tail = data[offset:]
    store.tail_error = error
    if generation > 1 and store.records:
        body = store.records[0]["payload"]["body"]
        prev = body["prev_generation"]
        ancestor = store.ancestors[0]
        if prev["store_id"] != ancestor.store_id or not 1 <= prev["last_seq"] <= ancestor.L or \
                ancestor.records[prev["last_seq"] - 1]["digest"] != prev["last_record_digest"]:
            store.error = (1, "lineage", "the re-genesis link is not the ancestor's record")
        elif body["quarantined"] != {"last_seq": ancestor.L,
                                     "last_record_digest": ancestor.records[-1]["digest"]}:
            store.error = (1, "lineage", "the quarantine evidence is not the ancestor's prefix")
        elif body["remote"] != ancestor.remote:
            store.error = (1, "record-remote", "re-genesis changed the remote")
    return store


def check_key_files(store: Store) -> None:
    expected = {"root", "root.pub"} | {f"{t}{s}" for t in TYPES for s in ("", ".pub", "-cert.pub")}
    for n, epoch in store.epochs.items():
        directory = os.path.join(store.directory, "keys", epoch["key_dir"])
        need(is_dir(directory), "key-file", f"published key directory missing: {epoch['key_dir']}")
        names = {name for name in os.listdir(directory) if not name.startswith(".tmp-")}
        need(names == expected, "key-file", f"{epoch['key_dir']}: files {sorted(names ^ expected)}")
        files = {name: read(os.path.join(directory, name)) for name in names}
        root_blob = pub_blob(epoch["root_pub"])
        need(pub_file(files["root.pub"]) == epoch["root_pub"]  # type: ignore[arg-type]
             and parse_private(files["root"]) == root_blob, "key-file",  # type: ignore[arg-type]
             "root key files disagree with the record")
        prints = []
        for kind in TYPES:
            pub = pub_file(files[f"{kind}.pub"])  # type: ignore[arg-type]
            need(fingerprint(pub_blob(pub)) == epoch["subkeys"][kind]
                 and parse_private(files[kind]) == pub_blob(pub), "key-file",  # type: ignore[arg-type]
                 f"{kind} key files disagree with the record")
            cert = cert_file(files[f"{kind}-cert.pub"])  # type: ignore[arg-type]
            key_id = cert_rules(cert, kind, n, epoch["root_pub"])
            need(cert["subject"] == pub_blob(pub), "key-file", f"{kind} certificate subject")
            prints.append(key_id)
        certs = b"".join(files[f"{kind}-cert.pub"] for kind in TYPES)  # type: ignore[misc]
        need(RUN.ssh_fingerprints(certs) == prints, "key-file",
             f"{epoch['key_dir']}: ssh-keygen did not verify every certificate")


# ---------------------------------------------------------------------------
# The anchor chain
# ---------------------------------------------------------------------------

def git_id(kind: str, data: bytes) -> str:
    return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).hexdigest()


def parse_anchor(data: bytes) -> tuple[dict, dict | None, str]:
    body = exact(load_canonical(data, "anchor.json"), ("active", "prev_generation", "sig"),
                 "anchor.json")
    active = exact(body["active"], ACTIVE_KEYS, "active")
    need(type(active["store_id"]) is str and bool(STORE_ID.fullmatch(active["store_id"]))
         and pos_int(active["generation"]) and pos_int(active["seq"]) and pos_int(active["epoch"])
         and all(type(active[k]) is str and DIGEST.fullmatch(active[k])
                 for k in ("genesis_digest", "record_digest"))
         and type(active["key_id"]) is str and bool(KEY_ID.fullmatch(active["key_id"])),
         "anchor-json", "active pointer schema")
    prev = body["prev_generation"]
    if prev is not None:
        check_prev(prev)
    need(type(body["sig"]) is str and bool(SIG.fullmatch(body["sig"])), "anchor-json", "sig")
    return active, prev, body["sig"]


def commit_text(anchor_json: bytes, parent: str | None) -> bytes:
    active, _prev, _sig = parse_anchor(anchor_json)
    blob = git_id("blob", anchor_json)
    tree = git_id("tree", b"100644 anchor.json\0" + bytes.fromhex(blob))
    lines = [f"tree {tree}"] + ([f"parent {parent}"] if parent else [])
    seq = active["seq"]
    lines += [f"author {IDENTITY} {seq} +0000", f"committer {IDENTITY} {seq} +0000"]
    return ("\n".join(lines) + f"\n\nanchor {active['store_id']} g{active['generation']} "
            f"s{seq}\n").encode()


def read_commit(oid: str) -> tuple[bytes, str | None]:
    need(RUN.cat("-t", oid).strip() == b"commit", "anchor-objects", "not a commit")
    raw = RUN.cat("-p", oid)
    need(git_id("commit", raw) == oid, "anchor-objects", "commit bytes")
    header = raw.partition(b"\n\n")[0].split(b"\n")
    trees = [line[5:].decode() for line in header if line.startswith(b"tree ")]
    parents = [line[7:].decode() for line in header if line.startswith(b"parent ")]
    need(len(trees) == 1 and bool(OID.fullmatch(trees[0])) and len(parents) <= 1
         and all(OID.fullmatch(p) for p in parents), "anchor-objects", "commit shape")
    need(RUN.cat("-t", trees[0]).strip() == b"tree", "anchor-objects", "tree")
    match = re.fullmatch(rb"100644 blob ([0-9a-f]{40})\tanchor\.json\n", RUN.cat("-p", trees[0]))
    need(match is not None, "anchor-tree", "anchor tree must hold exactly anchor.json")
    blob = match.group(1).decode()  # type: ignore[union-attr]
    need(RUN.cat("-t", blob).strip() == b"blob", "anchor-objects", "blob")
    data = RUN.cat("-p", blob)
    need(git_id("blob", data) == blob, "anchor-objects", "blob bytes")
    parent = parents[0] if parents else None
    need(commit_text(data, parent) == raw, "anchor-commit", "not the deterministic commit")
    return data, parent


def chain(tip: str) -> list[dict]:
    entries = []
    current: str | None = tip
    while current is not None:
        need(len(entries) < 100000, "anchor-chain", "chain too long")
        data, parent = read_commit(current)
        active, prev, sig = parse_anchor(data)
        entries.append({"commit": current, "parent": parent, "data": data, "active": active,
                        "prev": prev, "sig": sig})
        current = parent
    for index, entry in enumerate(entries):
        a = entry["active"]
        if index + 1 == len(entries):
            need(a["generation"] == 1 and a["seq"] == 1 and entry["prev"] is None
                 and a["genesis_digest"] == a["record_digest"], "anchor-chain", "root commit")
            continue
        up = entries[index + 1]["active"]
        if a["generation"] == up["generation"]:
            need(a["store_id"] == up["store_id"] and a["seq"] == up["seq"] + 1
                 and a["genesis_digest"] == up["genesis_digest"] and entry["prev"] is None,
                 "anchor-chain", "seq must increase by one")
        else:
            need(a["generation"] == up["generation"] + 1 and a["seq"] == 1
                 and a["store_id"] != up["store_id"] and a["genesis_digest"] == a["record_digest"]
                 and entry["prev"] == {"store_id": up["store_id"], "generation": up["generation"],
                                       "last_seq": up["seq"],
                                       "last_record_digest": up["record_digest"]},
                 "anchor-chain", "generation link")
    return entries


def history(store: Store, entries: list, skip_tip: bool) -> None:
    owners = {s.generation: s for s in [store] + store.ancestors}
    for index, entry in enumerate(entries):
        if index == 0 and skip_tip:
            continue
        a = entry["active"]
        owner = owners.get(a["generation"])
        need(owner is not None and owner.store_id == a["store_id"], "anchor-history",
             "a pointer names a store outside the lineage")
        need(a["seq"] <= owner.L and owner.ptr(a["seq"]) == a, "anchor-history",
             "an anchored pointer differs from the local record")
        verify_pointer(owner, a, entry["prev"], entry["sig"])


def read_remote(url: str) -> tuple[str | None, list | None]:
    RUN.remote = parse_remote(url)
    if not RUN.repo:
        RUN.init_repo()
    tip = RUN.fetch()
    if tip is None:
        return None, None
    return tip, chain(tip)


# ---------------------------------------------------------------------------
# Classification (the writer's states)
# ---------------------------------------------------------------------------

def result(state: str, table: str, detail: str = "", store: Store | None = None,
           klass: str | None = None, row: str | None = None, rule: str | None = None) -> dict:
    klass = klass if klass is not None else (store.klass if store else None)
    test_only = klass == "test" or RUN.test_bins
    authorizing = state == "committed" and row is None
    out = {"state": state, "table": table, "detail": detail[:300], "row": row, "rule": rule,
           "anchor_class": klass, "test_only": test_only, "authorizing_state": authorizing,
           "current_authorization": authorizing and not test_only,
           "verifier": "independent"}
    if store is not None:
        out.update({"store_id": store.store_id, "generation": store.generation, "seq": store.L,
                    "epochs": {str(n): e["state"] for n, e in sorted(store.epochs.items())}})
    return out


INTENT = ("seq", "offset", "length", "digest", "expected_parent", "anchor_json", "anchor_commit",
          "frame_length", "frame_b64")


def parse_intent(data: bytes, extra: tuple) -> tuple[dict, bytes, dict, dict | None, str]:
    intent = exact(load_canonical(data, "intent"), INTENT + extra, "intent")
    need(all(pos_int(intent[k], 0) for k in ("seq", "offset", "length", "frame_length"))
         and intent["seq"] >= 1 and type(intent["digest"]) is str
         and bool(DIGEST.fullmatch(intent["digest"])), "intent-schema", "intent integers")
    need(intent["expected_parent"] is None or (type(intent["expected_parent"]) is str
                                               and bool(OID.fullmatch(intent["expected_parent"]))),
         "intent-schema", "expected_parent")
    need(type(intent["anchor_commit"]) is str and bool(OID.fullmatch(intent["anchor_commit"])),
         "intent-schema", "anchor_commit")
    need(type(intent["frame_b64"]) is str and type(intent["anchor_json"]) is str,
         "intent-schema", "strings")
    try:
        frame_bytes = base64.b64decode(intent["frame_b64"], validate=True)
    except ValueError as error:
        raise Bad("intent-inconsistent", "frame_b64") from error
    need(len(frame_bytes) == intent["frame_length"], "intent-inconsistent", "frame_length")
    frames, offset, error = parse_frames(frame_bytes, intent["seq"])
    need(len(frames) == 1 and offset == len(frame_bytes) and error is None, "intent-inconsistent",
         "intent frame is not one frame")
    need(frames[0]["length"] == intent["length"] and frames[0]["digest"] == intent["digest"],
         "intent-inconsistent", "intent length or digest")
    anchor_json = intent["anchor_json"].encode("utf-8")
    active, prev, sig = parse_anchor(anchor_json)
    need(active["seq"] == intent["seq"] and active["record_digest"] == intent["digest"],
         "intent-inconsistent", "anchor_json does not name the frame")
    need(git_id("commit", commit_text(anchor_json, intent["expected_parent"]))
         == intent["anchor_commit"], "intent-inconsistent", "anchor_commit is not the rebuilt commit")
    return intent, frame_bytes, active, prev, sig


def candidate(store: Store, frame_bytes: bytes) -> Store:
    frames, offset, error = parse_frames(frame_bytes, store.L + 1)
    need(len(frames) == 1 and offset == len(frame_bytes) and error is None, "candidate", "frame")
    extended = store.copy()
    apply(extended, frames[0], store.remote)
    return extended


def frame1_kind(directory: str, frame_bytes: bytes) -> str:
    """A2.3's frame-1 class of the intent-named directory, which the caller
    found present: nothing ever removes it (abandonment only removes the
    intent), so a missing one is a failed intent, never frame 1 "none"."""
    try:
        data = read(os.path.join(directory, "log", "segment-000001.olf"))
    except Bad:
        return "nonconforming"
    if data == b"":
        return "none"
    if data == frame_bytes:
        return "valid"
    if data == frame_bytes[:-1]:
        return "unterminated"
    if len(data) < len(frame_bytes) - 1 and frame_bytes.startswith(data):  # type: ignore[arg-type]
        return "torn"
    return "nonconforming"


def marker(directory: str) -> bool:
    return read(os.path.join(directory, "quarantine"), missing_ok=True) is not None


def marker_rule(directory: str) -> str | None:
    data = read(os.path.join(directory, "quarantine"), missing_ok=True)
    if data is None:
        return None
    try:
        value = load_canonical(data, "quarantine marker")
    except Bad:
        return "unreadable"
    return str(value.get("rule")) if type(value) is dict else "unreadable"


def bootstrap(data: bytes) -> dict:
    try:
        intent, frame_bytes, active, prev, sig = parse_intent(data, ("store_id", "key_dir", "remote"))
        need(intent["seq"] == 1 and intent["offset"] == 0 and intent["expected_parent"] is None,
             "intent-schema", "frame 1")
        need(type(intent["store_id"]) is str and bool(STORE_ID.fullmatch(intent["store_id"])),
             "intent-schema", "store_id")
        parse_remote(intent["remote"])
        store = Store(intent["store_id"], 1, auth("stores", intent["store_id"]), False)
        frames, _o, _e = parse_frames(frame_bytes)
        apply(store, frames[0], None)
        body = store.records[0]["payload"]["body"]
        need(body["key_dir"] == intent["key_dir"] and body["remote"] == intent["remote"],
             "intent-schema", "key_dir or remote")
        need(active == store.ptr(1) and prev is None, "intent-pointer", "not the record's pointer")
        verify_pointer(store, active, prev, sig)
        # created before the intent, never removed: without it nothing shows
        # frame 1 was never durable (pushed, then deleted with the ref)
        need(is_dir(store.directory), "intent-store-missing",
             "the intent-named store directory does not exist")
    except Bad as bad:
        return result("genesis-invalid", "A2.3 row 1", bad.detail)
    target = canon({"store_id": intent["store_id"], "generation": 1})
    try:
        active_bytes = read(auth("active"), missing_ok=True)
        active_state = "absent" if active_bytes is None else (
            "exact" if active_bytes == target else "other")
    except Bad:
        active_state = "other"
    if active_state == "other":
        return result("anchor-mismatch", "A2.3 row 2", "active is not the intent's store")
    q_state = "genesis-quarantined" if active_state == "absent" else "quarantined"
    directory = store.directory
    if marker(directory):
        return result(q_state, "A2.3 quarantine marker", store=store,
                      rule=marker_rule(directory))
    kind = frame1_kind(directory, frame_bytes)
    quarantine_row = "store-quarantine"
    if kind == "nonconforming":
        return result(q_state, "A2.3 row 3", store=store, row=quarantine_row)
    try:
        tip, entries = read_remote(intent["remote"])
    except Unreachable as error:
        return result("genesis-pending", "A2.3 row 4", str(error), store=store)
    except Bad as bad:
        return result(q_state, "A2.3 row 11", bad.detail, store=store, row=quarantine_row)
    if tip is None:
        if active_state == "exact":
            return result("quarantined", "A2.3 row 5", store=store, row=quarantine_row)
        if kind in ("none", "torn"):
            return result("genesis-pending", "A2.3 row 6", store=store, row="abandon")
        return result("genesis-pending", "A2.3 row 7" if kind == "unterminated" else "A2.3 row 8",
                      store=store, row="anchor-replay-forward")
    ok = False
    if tip == intent["anchor_commit"] and entries is not None and len(entries) == 1 \
            and entries[0]["data"] == intent["anchor_json"].encode("utf-8"):
        try:
            verify_pointer(store, entries[0]["active"], entries[0]["prev"], entries[0]["sig"])
            ok = True
        except Bad:
            ok = False
    if ok and kind == "valid":
        return result("genesis-pending", "A2.3 row 9", store=store, row="complete")
    if ok:
        return result(q_state, "A2.3 row 10", store=store, row=quarantine_row)
    return result(q_state, "A2.3 row 11", store=store, row=quarantine_row)


def regenesis(data: bytes) -> dict:
    try:
        intent, frame_bytes, active, prev, sig = parse_intent(
            data, ("old", "old_commit", "new_store_id", "key_dir", "archive", "remote"))
        old = check_prev(intent["old"])
        need(intent["seq"] == 1 and intent["offset"] == 0
             and intent["expected_parent"] == intent["old_commit"]
             and intent["archive"] == "archive/" + old["store_id"], "intent-schema", "regenesis")
        new_id = intent["new_store_id"]
        need(type(new_id) is str and bool(STORE_ID.fullmatch(new_id)) and new_id != old["store_id"],
             "intent-schema", "new_store_id")
        archived = not is_dir(auth("stores", old["store_id"]))
        old_store = load(old["store_id"], old["generation"], archived=archived)
        new = Store(new_id, old["generation"] + 1, auth("stores", new_id), False)
        new.ancestors = [old_store] + old_store.ancestors
        frames, _o, _e = parse_frames(frame_bytes)
        apply(new, frames[0], old_store.remote)
        body = new.records[0]["payload"]["body"]
        need(body["key_dir"] == intent["key_dir"] and body["remote"] == intent["remote"]
             == old_store.remote and body["prev_generation"] == old
             and body["prev_commit"] == intent["old_commit"], "intent-link", "link")
        need(1 <= old["last_seq"] <= old_store.L and
             old_store.records[old["last_seq"] - 1]["digest"] == old["last_record_digest"],
             "intent-link", "old record")
        need(active == new.ptr(1) and prev == old, "intent-pointer", "pointer")
        verify_pointer(new, active, prev, sig)
        need(is_dir(new.directory), "intent-store-missing",
             "the intent-named new store directory does not exist")
    except Bad as bad:
        return result("regenesis-invalid", "A1.3 intent", bad.detail)
    active_bytes = read(auth("active"), missing_ok=True)
    new_target = canon({"store_id": new_id, "generation": new.generation})
    old_target = canon({"store_id": old["store_id"], "generation": old_store.generation})
    if active_bytes not in (new_target, old_target):
        return result("regenesis-invalid", "A1.3 active", store=old_store)
    try:
        tip, entries = read_remote(old_store.remote)  # type: ignore[arg-type]
    except Unreachable as error:
        return result("regenesis-pending", "A1.3 remote unreachable", str(error), store=old_store)
    except Bad as bad:
        return result("regenesis-quarantined", "A1.3 anchor fails", bad.detail, store=old_store)
    kind = frame1_kind(new.directory, frame_bytes)
    # Every commit was read by content (chain()); each pointer must also
    # verify against the roots it requires before any row applies.
    if tip is not None and entries and tip == intent["old_commit"]:
        R = entries[0]["active"]
        try:
            need(R["store_id"] == old["store_id"] and R["generation"] == old_store.generation
                 and {"store_id": R["store_id"], "generation": R["generation"],
                      "last_seq": R["seq"], "last_record_digest": R["record_digest"]} == old,
                 "anchor-history", "the recorded old commit is not the linked pointer")
            history(old_store, entries, skip_tip=False)
        except Bad as bad:
            return result("regenesis-quarantined", "A1.3 anchor fails", bad.detail,
                          store=old_store)
        if active_bytes == old_target and not archived:
            return result("regenesis-pending", "A1.3 remote names the old generation",
                          store=old_store, row="abandon")
    if tip is not None and entries and tip == intent["anchor_commit"] and \
            entries[0]["data"] == intent["anchor_json"].encode("utf-8") \
            and entries[0]["parent"] == intent["old_commit"]:
        try:
            verify_pointer(new, entries[0]["active"], entries[0]["prev"], entries[0]["sig"])
            history(old_store, entries[1:], skip_tip=False)
            if kind == "valid":
                return result("regenesis-pending", "A1.3 remote names the new generation",
                              store=old_store, row="complete")
        except Bad:
            pass
    return result("regenesis-quarantined", "A1.3 anchor fails", store=old_store)


def tail_kind(store: Store, intent: dict | None, frame_bytes: bytes | None) -> str | None:
    if not store.tail:
        return None
    if store.tail_error is not None or intent is None or frame_bytes is None \
            or intent["seq"] != store.L + 1 or intent["offset"] != store.tail_offset:
        return "nonconforming"
    if store.tail == frame_bytes[:-1]:
        return "unterminated"
    if len(store.tail) < len(frame_bytes) - 1 and frame_bytes.startswith(store.tail):
        return "torn"
    return "nonconforming"


def active_store(store_id: str, generation: int) -> dict:
    try:
        store = load(store_id, generation)
    except Bad as bad:
        return result("active-invalid", "lineage", bad.detail)
    q = lambda table, detail="", rule=None: result(  # noqa: E731
        "quarantined", table, detail, store=store, row="store-quarantine", rule=rule)
    if marker(store.directory):
        return result("quarantined", "quarantine marker", store=store,
                      rule=marker_rule(store.directory))
    if store.error is not None:
        return q("A1.6 complete-but-invalid frame", f"{store.error[1]}: {store.error[2]}",
                 store.error[1])
    if store.L == 0:
        return q("A1.6", "empty log")
    try:
        check_key_files(store)
    except Bad as bad:
        return q("A1.7 key file", bad.detail)
    L = store.L
    intent = None
    frame_bytes = None
    extended = None
    data = read(os.path.join(store.directory, "intent"), missing_ok=True)
    if data is not None:
        try:
            intent, frame_bytes, i_active, i_prev, i_sig = parse_intent(data, ())
        except Bad as bad:
            return q("A1.6 intent", bad.detail)
        if intent["seq"] not in (L, L + 1):
            return q("A1.2 stray intent")
    kind = tail_kind(store, intent, frame_bytes)
    if kind == "nonconforming":
        return q("A1.6 everything else")
    try:
        if kind is not None:
            extended = candidate(store, frame_bytes)  # type: ignore[arg-type]
        elif intent is not None and intent["seq"] == L + 1:
            need(intent["offset"] == len(store.data), "intent-offset", "L + 1 intent offset")
            extended = candidate(store, frame_bytes)  # type: ignore[arg-type]
        elif intent is not None:
            record = store.records[L - 1]
            fr = record["frame"]
            need(intent["offset"] == fr["offset"] and intent["length"] == fr["length"]
                 and intent["digest"] == record["digest"]
                 and frame_bytes == store.data[fr["offset"]:fr["end"]], "intent-mismatch",
                 "intent for L is not frame L")
            extended = store
        if intent is not None:
            owner = extended or store
            if i_active["seq"] <= owner.L:
                need(owner.ptr(i_active["seq"]) == i_active, "intent-pointer", "not ptr(seq)")
            verify_pointer(owner, i_active, i_prev, i_sig)
            need(i_prev is None, "intent-pointer", "prev_generation")
    except Bad as bad:
        return q("A1.6 intent", bad.detail)
    try:
        tip, entries = read_remote(store.remote)  # type: ignore[arg-type]
    except Unreachable as error:
        return result("pending", "A1.2 remote unreachable", str(error), store=store)
    except Bad as bad:
        return q("A1.2 step 3", bad.detail)
    if tip is None:
        return q("A2.3 absent ref once active exists")
    R = entries[0]  # type: ignore[index]
    if R["active"]["store_id"] != store.store_id or R["active"]["generation"] != store.generation:
        return q("A1.2 other store_id or generation")
    try:
        history(store, entries, skip_tip=True)  # type: ignore[arg-type]
        verify_pointer(store if R["active"]["seq"] <= L else (extended or store), R["active"],
                       R["prev"], R["sig"])
    except Bad as bad:
        return q("A1.2 step 3", bad.detail)
    rseq = R["active"]["seq"]
    if kind == "torn":
        if rseq == L + 1:
            return q("A1.6 torn with remote naming seq")
        return result("needs-recovery", "A1.6 torn", store=store, row="torn-frame-truncation")
    if kind == "unterminated":
        if R["active"] == store.ptr(L) and tip == intent["expected_parent"]:  # type: ignore[index]
            return result("pending", "A1.6 unterminated, remote old", store=store,
                          row="anchor-replay-forward")
        if rseq == L + 1:
            return q("A1.6 unterminated, remote new")
        return q("A1.2 rollback")
    if rseq == L and R["active"] != store.ptr(L):
        return q("A1.2 same-sequence fork")
    if R["active"] == store.ptr(L):
        if intent is not None:
            if intent["seq"] == L and (tip != intent["anchor_commit"]
                                       or R["parent"] != intent["expected_parent"]):
                return q("A1.6 tip neither parent nor stored commit")
            if intent["seq"] == L + 1 and tip != intent["expected_parent"]:
                return q("A1.6 tip neither parent nor stored commit")
            return result("needs-recovery", "A1.2 committed, residual intent", store=store,
                          row="recovery-tidy")
        if store.revoked_active:
            return result("quarantined", "A1.3 active epoch revoked", store=store,
                          row="store-quarantine")
        return result("committed", "A1.2 committed", store=store)
    if L >= 2 and R["active"] == store.ptr(L - 1):
        if intent is not None and intent["seq"] == L and tip == intent["expected_parent"]:
            return result("pending", "A1.2 R = ptr(L - 1) with intent", store=store,
                          row="anchor-replay-forward")
        return q("A1.2 one-step rollback or planted frame")
    return q("A1.2 rollback of the log or the remote")


def verify() -> dict:
    if not is_dir(RUN.authority):
        return result("none", "no authority directory")
    data = read(auth("genesis.intent"), missing_ok=True)
    if data is not None:
        return bootstrap(data)
    data = read(auth("regenesis.intent"), missing_ok=True)
    if data is not None:
        return regenesis(data)
    data = read(auth("active"), missing_ok=True)
    if data is None:
        return result("none", "no active store")
    try:
        active = exact(load_canonical(data, "active"), ("store_id", "generation"), "active")
        need(type(active["store_id"]) is str and bool(STORE_ID.fullmatch(active["store_id"]))
             and pos_int(active["generation"]), "active-schema", "active marker")
    except Bad as bad:
        return result("active-invalid", "active marker", bad.detail)
    return active_store(active["store_id"], active["generation"])


def exit_code(out: dict) -> int:
    state = out["state"]
    if state == "committed":
        return EXIT["committed"]
    if state in TERMINAL:
        return EXIT["terminal"]
    if "pending" in state or state == "needs-recovery":
        return EXIT["pending"]
    if "quarantined" in state:
        return EXIT["quarantined"]
    return EXIT["invalid"]


def main(argv: list[str]) -> int:
    global RUN
    try:
        RUN = Runner()
    except EnvError as error:
        print(f"error: environment: {error}", file=sys.stderr)
        return EXIT["env"]
    if argv[:1] == ["transport-plan"]:
        if not test_mode() or len(argv) != 2:
            print("error: usage: transport-plan <remote> (LOOP_AUTHORITY_TEST=1)", file=sys.stderr)
            return 2
        try:
            RUN.remote = parse_remote(argv[1])
        except Bad as bad:
            print(f"error: remote: {bad.detail}", file=sys.stderr)
            return 2
        RUN.temp = "<temp>"
        RUN.repo = "<temp>/anchor.git"
        print(json.dumps({"ls-remote": RUN.git_argv("ls-remote"), "fetch": RUN.git_argv("fetch"), "init": RUN.git_argv("init"),
                          "cat-file": RUN.git_argv("cat-file", "-p", "0" * 40),
                          "env": RUN.env(True)}, sort_keys=True))
        return 0
    if argv:
        print("error: usage: loop-authority-verify [transport-plan <remote>]", file=sys.stderr)
        return 2
    try:
        # First act: the temporary directory, O_NOFOLLOW on every component,
        # refused anywhere under the authority directory. It is this
        # process's only TMPDIR (the inherited one is never used).
        RUN.make_temp()
        for name in ("TMPDIR", "TMP", "TEMP"):
            os.environ.pop(name, None)
        os.environ["TMPDIR"] = RUN.temp
        out = verify()
    except EnvError as error:
        print(f"error: environment: {error}", file=sys.stderr)
        return EXIT["env"]
    except OSError as error:
        print(f"error: environment: {error}", file=sys.stderr)
        return EXIT["env"]
    except Unreachable as error:
        out = result("pending", "remote unreachable", str(error))
    except Bad as bad:
        out = result("invalid", "layout", bad.detail)
    finally:
        RUN.cleanup()
    print(json.dumps(out, sort_keys=True, separators=(",", ":")))
    return exit_code(out)


sys.exit(main(sys.argv[1:]))
