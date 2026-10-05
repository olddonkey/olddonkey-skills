"""The one subprocess wrapper of lib/loopauth and its closed command table
(task-graph-v1 Phase A, sub-unit 0a.2, sections 3-4).

Every subprocess in lib/loopauth runs through run(command_id, ...). There is
no free-form argv: run() builds the argv itself from COMMAND_TABLE, whose
templates are plain data, so an unlisted command, subcommand, or option
cannot be expressed. Parameters are validated by kind before substitution.

- Binaries (ssh-keygen, git, ssh, gh) resolve only from BINARY_DIRS.
- The environment of every child is built from an allowlist, never copied:
  a fixed PATH, HOME, LANG=C, LC_ALL=C, TMPDIR set to this process's own
  scratch directory, and for git also SSH_AUTH_SOCK and the three isolation
  settings. ssh-keygen never sees SSH_AUTH_SOCK, so it cannot sign with an
  agent key.
- A sink entry (effect "sink") runs only with an open transaction token that
  store.authorize_command accepts for exactly these parameters.
- Independently of the table, a parameter under the authority directory is
  refused without an open token.
- <remote> is only the pinned remote (pin_remote), <scratch> only a scratch
  repository this process created (new_scratch_repo), <type> only a member of
  records.TYPES.

This module also owns the process scratch directory and the fresh scratch
repositories: neither is authority state, and nothing in them is evidence.

Test seam (LOOP_AUTHORITY_TEST=1 only): LOOP_AUTHORITY_TEST_BIN_DIR names one
directory searched before BINARY_DIRS, for wrapper fixtures that record their
environment. While it is honoured, test_binaries_in_use() is true and no
reader reports current authorization, and refuse_test_binaries() stops every
mutation of a production lineage -- genesis included, before it creates a key
or an intent -- so no lineage a test seam touched can ever authorize.
"""

from __future__ import annotations

import os
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit

from . import records

BINARY_DIRS = ("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin")
TEST_BIN_ENV = "LOOP_AUTHORITY_TEST_BIN_DIR"
ANCHOR_REF = "refs/olddonkey-loop/anchor"
READBACK_REF = "refs/readback/anchor"
POINTER_NAMESPACE = "olddonkey-loop.anchor.pointer.v1"
POINTER_PRINCIPAL = "anchor-root"
COMMIT_NAME = "olddonkey-loop"
COMMIT_EMAIL = "anchor@olddonkey-loop.invalid"
GIT_PREFIX = ("-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false")
LOCAL_TIMEOUT = 60
REMOTE_TIMEOUT = 120

OID_RE = re.compile(r"^[0-9a-f]{40}$")
HEX16_RE = re.compile(r"^[0-9a-f]{16}$")
STORE_ID_RE = re.compile(r"^[0-9a-f]{32}$")
MESSAGE_RE = re.compile(r"^anchor [0-9a-f]{32} g[1-9][0-9]* s[1-9][0-9]*$")
COMMENT_RE = re.compile(r"^olddonkey-loop [0-9a-f]{32} e[1-9][0-9]* [a-z][a-z0-9.-]{0,40}$")
KEY_DIR_RE = re.compile(r"^epoch-([1-9][0-9]*)-([0-9a-f]{16})$")
SCRATCH_RE = re.compile(r"^[1-9][0-9]*-[0-9a-f]{16}\.git$")

# The closed command table (section 3). Template tokens in angle brackets are
# validated parameters or fixed expansions; everything else is literal.
#   <git-prefix>  GIT_PREFIX
#   <transport>   the transport options of the pinned remote (section 4)
#   <parent-opt>  nothing, or "-p <parent>"
COMMAND_TABLE: dict[str, dict] = {
    "git.init": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "init", "--bare", "--template=",
                 "--object-format=sha1", "."),
        "effect": "scratch",
    },
    "git.hash-object": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "hash-object", "-w", "--stdin"),
        "effect": "scratch",
    },
    "git.mktree": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "mktree"),
        "effect": "scratch",
    },
    "git.commit-tree": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "commit-tree", "<tree>", "<parent-opt>",
                 "-m", "<message>"),
        "effect": "scratch",
    },
    "git.fetch-anchor": {
        "binary": "git",
        "argv": ("<git-prefix>", "<transport>", "-C", "<scratch>", "fetch", "--no-tags",
                 "--no-write-fetch-head", "<remote>",
                 "+refs/olddonkey-loop/*:refs/readback/*"),
        "effect": "scratch",
    },
    "git.ls-remote": {
        "binary": "git",
        "argv": ("<git-prefix>", "<transport>", "-C", "<scratch>", "ls-remote", "<remote>",
                 "refs/olddonkey-loop/anchor"),
        "effect": "read",
    },
    "git.cat-file": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "cat-file", "<cat-mode>", "<oid>"),
        "effect": "read",
    },
    "git.update-anchor": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "update-ref",
                 "refs/olddonkey-loop/anchor", "<commit>"),
        "effect": "scratch",
    },
    "git.anchor-refs": {
        "binary": "git",
        "argv": ("<git-prefix>", "-C", "<scratch>", "for-each-ref",
                 "--format=%(objectname) %(refname)", "refs/olddonkey-loop/"),
        "effect": "read",
    },
    "git.push-anchor": {
        "binary": "git",
        "argv": ("<git-prefix>", "<transport>", "-C", "<scratch>", "push", "<remote>",
                 "refs/olddonkey-loop/*:refs/olddonkey-loop/*"),
        "effect": "sink",
    },
    "ssh-keygen.generate": {
        "binary": "ssh-keygen",
        "argv": ("-q", "-t", "ed25519", "-N", "", "-C", "<comment>", "-f", "<key-temp>"),
        "effect": "sink",
    },
    "ssh-keygen.certify": {
        "binary": "ssh-keygen",
        "argv": ("-q", "-s", "<root>", "-I", "<type>@e<epoch>", "-n", "<type>", "-V",
                 "always:forever", "<subkey-pub>"),
        "effect": "sink",
    },
    "ssh-keygen.sign": {
        "binary": "ssh-keygen",
        "argv": ("-Y", "sign", "-f", "<subkey>", "-n", "olddonkey-loop.authority.<type>.v1"),
        "effect": "sink",
    },
    "ssh-keygen.verify": {
        "binary": "ssh-keygen",
        "argv": ("-Y", "verify", "-f", "<allowed-signers>", "-I", "<type>", "-n",
                 "olddonkey-loop.authority.<type>.v1", "-s", "<sig>"),
        "effect": "read",
    },
    "ssh-keygen.sign-pointer": {
        "binary": "ssh-keygen",
        "argv": ("-Y", "sign", "-f", "<root>", "-n", "olddonkey-loop.anchor.pointer.v1"),
        "effect": "sink",
    },
    "ssh-keygen.verify-pointer": {
        "binary": "ssh-keygen",
        "argv": ("-Y", "verify", "-f", "<allowed-signers>", "-I", "anchor-root", "-n",
                 "olddonkey-loop.anchor.pointer.v1", "-s", "<sig>"),
        "effect": "read",
    },
    "ssh-keygen.fingerprint": {
        "binary": "ssh-keygen",
        "argv": ("-l", "-E", "sha256", "-f", "<pub>"),
        "effect": "read",
    },
}

# Which parameters each command takes (besides token and stdin).
COMMAND_PARAMS: dict[str, frozenset] = {
    "git.init": frozenset({"scratch"}),
    "git.hash-object": frozenset({"scratch"}),
    "git.mktree": frozenset({"scratch"}),
    "git.commit-tree": frozenset({"scratch", "tree", "parent", "message", "seq"}),
    "git.fetch-anchor": frozenset({"scratch", "remote"}),
    "git.ls-remote": frozenset({"scratch", "remote"}),
    "git.cat-file": frozenset({"scratch", "cat_mode", "oid"}),
    "git.update-anchor": frozenset({"scratch", "commit"}),
    "git.anchor-refs": frozenset({"scratch"}),
    "git.push-anchor": frozenset({"scratch", "remote", "commit"}),
    "ssh-keygen.generate": frozenset({"comment", "key_temp"}),
    "ssh-keygen.certify": frozenset({"root", "type", "epoch", "subkey_pub"}),
    "ssh-keygen.sign": frozenset({"subkey", "type"}),
    "ssh-keygen.verify": frozenset({"allowed_signers", "type", "sig"}),
    "ssh-keygen.sign-pointer": frozenset({"root"}),
    "ssh-keygen.verify-pointer": frozenset({"allowed_signers", "sig"}),
    "ssh-keygen.fingerprint": frozenset({"pub"}),
}
PATH_PARAMS = ("scratch", "key_temp", "root", "subkey_pub", "subkey", "allowed_signers", "sig",
               "pub")
REMOTE_COMMANDS = frozenset({"git.fetch-anchor", "git.ls-remote", "git.push-anchor"})
STDIN_COMMANDS = frozenset({"git.hash-object", "git.mktree", "ssh-keygen.sign",
                            "ssh-keygen.verify", "ssh-keygen.sign-pointer",
                            "ssh-keygen.verify-pointer"})


class ToolError(Exception):
    """A command could not be built or run. code is a stable identifier."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class Result:
    __slots__ = ("returncode", "stdout", "stderr", "argv")

    def __init__(self, returncode: int, stdout: bytes, stderr: bytes, argv: list[str]) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.argv = argv


def test_mode() -> bool:
    return os.environ.get("LOOP_AUTHORITY_TEST") == "1"


def home() -> str:
    value = os.environ.get("HOME", "")
    if not value or not os.path.isabs(value):
        raise ToolError("home", "HOME must be an absolute path")
    return os.path.realpath(value)


def authority_root() -> str:
    return os.path.join(home(), ".config", "olddonkey-loop", "authority")


def cache_root() -> str:
    return os.path.join(home(), ".cache", "olddonkey-loop")


def under(path: str, root: str) -> bool:
    return path == root or path.startswith(root + os.sep)


def is_authority_path(path: str) -> bool:
    return under(os.path.realpath(path), os.path.realpath(authority_root()))


# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

_RESOLVED: dict[str, str] = {}
_TEST_BIN: list[str] = []


def _test_bin_dir() -> str | None:
    if not test_mode():
        return None
    value = os.environ.get(TEST_BIN_ENV, "")
    if not value:
        return None
    if not os.path.isabs(value) or not os.path.isdir(value):
        raise ToolError("binary", f"{TEST_BIN_ENV} must name an existing absolute directory")
    return value


def test_binaries_in_use() -> bool:
    return _test_bin_dir() is not None


def refuse_test_binaries(anchor_class: str | None) -> None:
    """The binary override may take part only in a test lineage's
    mutations; a production remote with it is refused before anything is
    created. (Read-only classification may still run: it reports test_only
    and no current authorization.)"""
    if test_binaries_in_use() and anchor_class != "test":
        raise ToolError("test-binaries", f"{TEST_BIN_ENV} is honoured only for a test lineage; "
                        "refusing to mutate a production lineage with it")


def resolve(name: str) -> str:
    if name not in ("ssh-keygen", "git", "ssh", "gh"):
        raise ToolError("binary", f"binary outside the allowlist: {name}")
    if name in _RESOLVED:
        return _RESOLVED[name]
    directories = list(BINARY_DIRS)
    override = _test_bin_dir()
    if override is not None:
        directories.insert(0, override)
    for directory in directories:
        candidate = os.path.join(directory, name)
        try:
            info = os.stat(candidate)
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode) and os.access(candidate, os.X_OK):
            _RESOLVED[name] = candidate
            return candidate
    raise ToolError("binary", f"{name} not found in {', '.join(directories)}")


def optional(name: str) -> str | None:
    try:
        return resolve(name)
    except ToolError:
        return None


# ---------------------------------------------------------------------------
# The remote and its transport options (section 4)
# ---------------------------------------------------------------------------

SSH_REMOTE_RE = re.compile(
    r"^git@([A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?):"
    r"([A-Za-z0-9._][A-Za-z0-9._/-]{0,254})\.git$"
)
HTTPS_REMOTE_RE = re.compile(
    r"^https://([A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)(:[1-9][0-9]{0,4})?"
    r"/([A-Za-z0-9._][A-Za-z0-9._/-]{0,254})\.git$"
)
FILE_REMOTE_RE = re.compile(r"^file:///([A-Za-z0-9._/+@-]{1,4000})$")


class Remote:
    __slots__ = ("url", "transport", "anchor_class")

    def __init__(self, url: str, transport: str, anchor_class: str) -> None:
        self.url = url
        self.transport = transport
        self.anchor_class = anchor_class


def _path_ok(path: str) -> bool:
    parts = path.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def parse_remote(url: object, *, allow_test: bool) -> Remote:
    """Accept exactly the two production forms, and file:///<absolute path>
    only when allow_test. Everything else (any <transport>:: form,
    whitespace, a leading "-", credentials, query, fragment) is refused."""
    if type(url) is not str or not url or len(url) > 4096:
        raise ToolError("remote", "remote must be a non-empty string")
    if url.startswith("-") or any(ch.isspace() for ch in url) or "::" in url:
        raise ToolError("remote", f"remote form refused: {url!r}")
    if any(ord(ch) < 0x21 or ord(ch) > 0x7E for ch in url):
        raise ToolError("remote", "remote must be printable ASCII")
    match = SSH_REMOTE_RE.fullmatch(url)
    if match:
        if not _path_ok(match.group(2) + ".git"):
            raise ToolError("remote", "remote path refused")
        return Remote(url, "ssh", "production")
    match = HTTPS_REMOTE_RE.fullmatch(url)
    if match:
        if match.group(2) and int(match.group(2)[1:]) > 65535:
            raise ToolError("remote", "remote port out of range")
        if not _path_ok(match.group(3) + ".git"):
            raise ToolError("remote", "remote path refused")
        split = urlsplit(url)
        if split.username or split.password or split.query or split.fragment:
            raise ToolError("remote", "credentials, query, or fragment in remote")
        return Remote(url, "https", "production")
    match = FILE_REMOTE_RE.fullmatch(url)
    if match:
        if not allow_test:
            raise ToolError("remote-test-only", "file:// remotes need LOOP_AUTHORITY_TEST=1")
        if not _path_ok(match.group(1)):
            raise ToolError("remote", "remote path refused")
        return Remote(url, "file", "test")
    raise ToolError("remote", f"remote form refused: {url!r}")


def anchor_class_of(url: str) -> str:
    """The lineage class derived from a pinned remote (no test flag needed:
    the class is a property of the remote, not of the caller)."""
    return parse_remote(url, allow_test=True).anchor_class


_PINNED: list[Remote] = []


def pin_remote(remote: Remote) -> None:
    if _PINNED:
        if _PINNED[0].url != remote.url:
            raise ToolError("remote", "a different remote is already pinned in this process")
        return
    _PINNED.append(remote)


def pinned_remote() -> Remote | None:
    return _PINNED[0] if _PINNED else None


def transport_options(remote: Remote) -> list[str]:
    options = ["-c", "protocol.allow=never", "-c", f"protocol.{remote.transport}.allow=always"]
    if remote.transport == "ssh":
        ssh = resolve("ssh")
        options += [
            "-c",
            f"core.sshCommand={ssh} -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes"
            " -o UpdateHostKeys=no",
        ]
    elif remote.transport == "https":
        options += ["-c", "http.sslVerify=true", "-c", "http.followRedirects=false"]
        gh = optional("gh")
        if gh is not None:
            options += ["-c", "credential.helper=", "-c", f"credential.helper=!{gh} auth git-credential"]
    return options


# ---------------------------------------------------------------------------
# Scratch space: the process temporary directory and scratch repositories
# ---------------------------------------------------------------------------

_SCRATCH_TMP: list[str] = []
_SCRATCH_REPOS: set[str] = set()


def _open_dir_chain(base: str, parts: list[str], *, create: bool) -> str:
    """Walk base/parts one component at a time with O_NOFOLLOW, creating
    missing components (0700) when asked. Returns the real path."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(base, flags)
    try:
        path = base
        for part in parts:
            try:
                child = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(part, 0o700, dir_fd=fd)
                child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
            path = os.path.join(path, part)
            info = os.fstat(fd)
            if info.st_uid != os.getuid():
                raise ToolError("scratch", f"foreign-owned directory: {path}")
        return path
    except OSError as error:
        raise ToolError("scratch", f"cannot open {base}/{'/'.join(parts)}: {error}") from error
    finally:
        os.close(fd)


def scratch_tmp() -> str:
    """This process's scratch directory, created once: $HOME/.cache/
    olddonkey-loop/tmp/<pid>-<16 hex>, 0700, never under the authority
    directory. tempfile.tempdir points at it; children get it as TMPDIR."""
    if _SCRATCH_TMP:
        return _SCRATCH_TMP[0]
    parent = _open_dir_chain(home(), [".cache", "olddonkey-loop", "tmp"], create=True)
    name = f"{os.getpid()}-{secrets.token_hex(8)}"
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    path = os.path.join(parent, name)
    if is_authority_path(path):
        raise ToolError("scratch", "scratch directory resolves under the authority directory")
    _SCRATCH_TMP.append(path)
    tempfile.tempdir = path
    return path


def establish_scratch() -> str:
    """The entry point's first act (after refusing what needs no file):
    create the process scratch directory with O_NOFOLLOW on every component
    and make it this process's only TMPDIR, so the inherited value is never
    used by this process or a child."""
    path = scratch_tmp()
    for name in ("TMPDIR", "TMP", "TEMP"):
        os.environ.pop(name, None)
    os.environ["TMPDIR"] = path
    return path


def _remove_tree(path: str, root: str) -> None:
    if not under(os.path.realpath(path), os.path.realpath(root)) or is_authority_path(path):
        raise ToolError("scratch", f"refusing to remove outside scratch space: {path}")
    shutil.rmtree(path, ignore_errors=True)


def cleanup() -> None:
    for repo in sorted(_SCRATCH_REPOS):
        _remove_tree(repo, cache_root())
    _SCRATCH_REPOS.clear()
    for path in _SCRATCH_TMP:
        _remove_tree(path, cache_root())
    _SCRATCH_TMP.clear()
    tempfile.tempdir = None


def write_scratch_file(name: str, data: bytes) -> str:
    """Create a new file in the process scratch directory (never elsewhere)."""
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name) or name.startswith("."):
        raise ToolError("scratch", f"bad scratch file name: {name}")
    directory = scratch_tmp()
    path = os.path.join(directory, f"{secrets.token_hex(4)}-{name}")
    if is_authority_path(path):
        raise ToolError("scratch", "scratch file resolves under the authority directory")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise ToolError("scratch", f"short write to {path}")
            view = view[written:]
    finally:
        os.close(fd)
    return path


def check_scratch_config(repo: str) -> None:
    """Refuse a scratch config holding any section other than [core]."""
    try:
        fd = os.open(os.path.join(repo, "config"), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ToolError("scratch-config", f"cannot read scratch config: {error}") from error
    try:
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ToolError("scratch-config", "scratch config is not UTF-8") from error
    sections = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("["):
            sections.append(line)
            continue
        if not sections:
            raise ToolError("scratch-config", "scratch config has a key outside any section")
        key = line.split("=", 1)[0].strip().lower()
        if key.startswith("include") or key.startswith("url") or key.startswith("credential"):
            raise ToolError("scratch-config", f"scratch config sets {key}")
    if not sections or any(section.lower() != "[core]" for section in sections):
        raise ToolError("scratch-config", f"scratch config sections refused: {sections}")


def new_scratch_repo() -> str:
    """A fresh bare repository $HOME/.cache/olddonkey-loop/anchor-scratch/
    <pid>-<16 hex>.git: exclusive mkdir, git init, then the [core]-only
    config check. Never authority state."""
    parent = _open_dir_chain(home(), [".cache", "olddonkey-loop", "anchor-scratch"], create=True)
    name = f"{os.getpid()}-{secrets.token_hex(8)}.git"
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    path = os.path.join(parent, name)
    if is_authority_path(path):
        raise ToolError("scratch", "scratch repository resolves under the authority directory")
    _SCRATCH_REPOS.add(path)
    result = run("git.init", scratch=path)
    if result.returncode != 0:
        raise ToolError("scratch", "git init of the scratch repository failed: "
                        + result.stderr.decode("utf-8", "replace").strip())
    check_scratch_config(path)
    return path


def remove_scratch_repo(path: str) -> None:
    if path in _SCRATCH_REPOS:
        _SCRATCH_REPOS.discard(path)
        _remove_tree(path, cache_root())


# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------

def base_env() -> dict[str, str]:
    return {
        "PATH": ":".join(BINARY_DIRS),
        "HOME": home(),
        "LANG": "C",
        "LC_ALL": "C",
        "TMPDIR": scratch_tmp(),
    }


def git_env() -> dict[str, str]:
    env = base_env()
    sock = os.environ.get("SSH_AUTH_SOCK")
    if sock:
        env["SSH_AUTH_SOCK"] = sock
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def command_env(command_id: str, params: dict) -> dict[str, str]:
    spec = COMMAND_TABLE[command_id]
    if spec["binary"] != "git":
        return base_env()
    env = git_env()
    if command_id == "git.commit-tree":
        date = f"@{params['seq']} +0000"
        env.update({
            "GIT_AUTHOR_NAME": COMMIT_NAME,
            "GIT_AUTHOR_EMAIL": COMMIT_EMAIL,
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_NAME": COMMIT_NAME,
            "GIT_COMMITTER_EMAIL": COMMIT_EMAIL,
            "GIT_COMMITTER_DATE": date,
        })
    return env


# ---------------------------------------------------------------------------
# Building and running
# ---------------------------------------------------------------------------

def _key_path_ok(path: str, leaf_re: str) -> bool:
    """<authority>/stores/<store_id>/keys/epoch-<n>-<hex>/<leaf>."""
    root = os.path.realpath(authority_root())
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        return False
    if not path.startswith(root + os.sep):
        return False
    parts = path[len(root) + 1:].split(os.sep)
    return (
        len(parts) == 5
        and parts[0] == "stores"
        and STORE_ID_RE.fullmatch(parts[1]) is not None
        and parts[2] == "keys"
        and KEY_DIR_RE.fullmatch(parts[3]) is not None
        and re.fullmatch(leaf_re, parts[4]) is not None
    )


def _scratch_file_ok(path: str) -> bool:
    if not _SCRATCH_TMP or not os.path.isabs(path) or os.path.normpath(path) != path:
        return False
    return os.path.dirname(path) == _SCRATCH_TMP[0]


TYPE_LEAF = "(?:" + "|".join(re.escape(name) for name in records.TYPES) + ")"


def validate_params(command_id: str, params: dict) -> None:
    allowed = COMMAND_PARAMS[command_id]
    extra = set(params) - allowed
    missing = {name for name in allowed if name not in params and name != "parent"}
    if extra or missing:
        raise ToolError("params", f"{command_id}: unexpected {sorted(extra)} missing {sorted(missing)}")
    for name, value in params.items():
        if name == "parent":
            if value is not None and (type(value) is not str or not OID_RE.fullmatch(value)):
                raise ToolError("params", "parent must be a commit id or None")
            continue
        if name == "seq" or name == "epoch":
            if type(value) is not int or value < 1:
                raise ToolError("params", f"{name} must be a positive integer")
            continue
        if type(value) is not str:
            raise ToolError("params", f"{name} must be a string")
        if name == "scratch":
            if value not in _SCRATCH_REPOS or not SCRATCH_RE.fullmatch(os.path.basename(value)):
                raise ToolError("params", "scratch must be a scratch repository of this process")
        elif name == "remote":
            pinned = pinned_remote()
            if pinned is None or value != pinned.url:
                raise ToolError("params", "remote must be the pinned remote")
        elif name in ("oid", "tree", "commit"):
            if not OID_RE.fullmatch(value):
                raise ToolError("params", f"{name} must be a 40-hex object id")
        elif name == "cat_mode":
            if value not in ("-t", "-p"):
                raise ToolError("params", "cat-file mode must be -t or -p")
        elif name == "message":
            if not MESSAGE_RE.fullmatch(value):
                raise ToolError("params", "commit message is not the deterministic anchor message")
        elif name == "comment":
            if not COMMENT_RE.fullmatch(value):
                raise ToolError("params", "key comment refused")
        elif name == "type":
            if value not in records.TYPES:
                raise ToolError("params", f"type outside the closed type list: {value}")
        elif name == "key_temp":
            if not _key_path_ok(value, r"\.tmp-[0-9a-f]{16}") or os.path.lexists(value):
                raise ToolError("params", "key temp path refused")
        elif name == "root":
            if not _key_path_ok(value, r"root"):
                raise ToolError("params", "root key path refused")
        elif name == "subkey_pub":
            if not _key_path_ok(value, r"\.tmp-[0-9a-f]{16}\.pub"):
                raise ToolError("params", "subkey public key path refused")
        elif name == "subkey":
            if not _key_path_ok(value, TYPE_LEAF + r"-cert\.pub"):
                raise ToolError("params", "subkey certificate path refused")
        elif name in ("allowed_signers", "sig"):
            if not _scratch_file_ok(value):
                raise ToolError("params", f"{name} must be a file in the scratch directory")
        elif name == "pub":
            if not os.path.isabs(value) or os.path.normpath(value) != value:
                raise ToolError("params", "public key path must be absolute and normal")
        else:
            raise ToolError("params", f"unknown parameter {name}")
    if command_id == "ssh-keygen.sign" and not params["subkey"].endswith(
        os.sep + params["type"] + "-cert.pub"
    ):
        raise ToolError("params", "signing subkey does not belong to the signed type")


def build_argv(command_id: str, params: dict) -> list[str]:
    """The exact argv for a table entry. Raises ToolError for an unlisted id
    or an invalid parameter."""
    spec = COMMAND_TABLE.get(command_id)
    if spec is None:
        raise ToolError("unlisted", f"command outside the closed table: {command_id!r}")
    validate_params(command_id, params)
    argv = [resolve(spec["binary"])]
    for item in spec["argv"]:
        if item == "<git-prefix>":
            argv.extend(GIT_PREFIX)
        elif item == "<transport>":
            argv.extend(transport_options(pinned_remote()))  # type: ignore[arg-type]
        elif item == "<parent-opt>":
            if params.get("parent") is not None:
                argv.extend(["-p", params["parent"]])
        else:
            argv.append(_substitute(item, params))
    return argv


def _substitute(item: str, params: dict) -> str:
    def replace(match: re.Match) -> str:
        key = match.group(1).replace("-", "_")
        if key not in params:
            raise ToolError("params", f"template parameter missing: {match.group(1)}")
        return str(params[key])

    return re.sub(r"<([a-z][a-z-]*)>", replace, item)


def run(command_id: str, *, token: object = None, stdin: bytes = b"", **params: object) -> Result:
    """Run one table entry. Sink entries need an open token that the store
    accepts for exactly these parameters and stdin; any parameter under the
    authority directory needs an open token."""
    spec = COMMAND_TABLE.get(command_id)
    if spec is None:
        raise ToolError("unlisted", f"command outside the closed table: {command_id!r}")
    if type(stdin) is not bytes:
        raise ToolError("params", "stdin must be bytes")
    if stdin and command_id not in STDIN_COMMANDS:
        raise ToolError("params", f"{command_id} takes no stdin")
    argv = build_argv(command_id, params)
    from . import store  # the token authority; imported late to avoid a cycle

    if spec["effect"] == "sink":
        store.authorize_command(token, command_id, params, stdin)
    for name in PATH_PARAMS:
        value = params.get(name)
        if type(value) is str and is_authority_path(value):
            if not store.token_is_open(token):
                raise ToolError("refused", f"{command_id}: authority path without a token")
    env = command_env(command_id, params)
    timeout = REMOTE_TIMEOUT if command_id in REMOTE_COMMANDS else LOCAL_TIMEOUT
    try:
        completed = subprocess.run(
            argv,
            input=stdin,
            capture_output=True,
            env=env,
            cwd=scratch_tmp(),
            timeout=timeout,
            close_fds=True,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise ToolError("timeout", f"{command_id} timed out") from error
    except OSError as error:
        raise ToolError("exec", f"{command_id} could not run: {error}") from error
    return Result(completed.returncode, completed.stdout, completed.stderr, argv)
