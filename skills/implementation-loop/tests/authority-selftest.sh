#!/usr/bin/env bash
# Hermetic checks for the authority store (task-graph-v1 Phase A, sub-unit
# 0a.2): framing and canonical payloads, per-type subkeys and seals, the write
# protocol and every A1.2 / A1.6 recovery row, the anchor and its pointer,
# epochs, linked re-genesis and genesis at every crash cut (A2.3 rows), the
# operator-TTY ceremonies (driven through Python's pty), key staging, the
# independent verifier, remote forms and git isolation (SSH and HTTPS
# fixtures), temporary files, the crash seam, and the dormant rows.
#
# Every case runs the real scripts/loop-authority writer as a subprocess under
# a scratch HOME, with a file:// bare repository in a temporary directory as
# the remote (LOOP_AUTHORITY_TEST=1). Keys and certificates are real Ed25519
# keys made by the host ssh-keygen; nothing is mocked. No network: the SSH and
# HTTPS fixtures are 127.0.0.1 only. The HTTPS fixture mints a throwaway
# self-signed certificate with openssl.
#
# --review-only runs the changed review, named scenario cuts, frozen
# inventory/transport, and coverage controls. Its optional "inventory"
# argument runs only the inventory/transport and coverage controls, pinned
# at selftest: PASS (94 checks). The default suite still includes every
# existing section and case.
#
# --crash-matrix runs every frame-byte cut of genesis frame 1 and of an
# epoch-rotation frame. The cut list is enumerated from the two frames'
# planned sizes N (probed, or given by --sizes G,R so that separate runs
# agree): <kind>:frame-byte-n for n from 1 to N - 2 (the torn prefixes),
# then <kind>:frame-byte-last (the final byte). --shard K/N runs its
# deterministic partition (the i-th cut, from 0, to shard i mod N + 1) and
# prints that partition's digest and count beside the full list's. A run's
# frame length follows its pid, tty, and start-time digits, so it need not
# equal the plan's. Byte n proves a torn prefix: it is credited only to a
# real crash at exactly offset n (measured on disk) of a frame of at least
# n + 2 bytes, so n is never the final byte; a run whose frame is too short,
# or exactly n + 1 bytes (n its final byte), is discarded and retried, up to
# 50 runs, and no other offset is ever tried or credited. "last" is credited
# only to a real crash at its own frame's final byte, whatever its length.
# A run that refused on a principal read (exit 11 naming ttyname(0) or the
# start token, nothing written) is an environment failure: discarded and
# retried within the same 50, never credited; any other exit fails the cut.
# Every distinct real frame the runs wrote (by length, per kind) is then
# swept by the offline classifier over every prefix 1 .. length - 1, and the
# run prints each kind's planned range, "last", and the lengths swept.
# --cut-ids-out FILE records each credited cut's id and actual (kind, frame
# length, crash offset); --plan only probes and prints the sizes;
# --check-shards DIR (with --sizes) checks that DIR's cut-ids-<K>-of-<N>.txt
# lists are exactly the N partitions of the full list, which the same
# enumerator recomputes, each cut's evidence crediting it by that rule. The
# unsharded run checks its own list the same way.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LIB="$SCRIPT_DIR/../lib"
SCRIPTS="$SCRIPT_DIR/../scripts"
usage() {
  printf 'usage: authority-selftest.sh [--review-only [inventory] | --crash-matrix [--shard K/N] [--sizes G,R] [--cut-ids-out FILE] [--plan | --check-shards DIR]]\n' >&2
  exit 2
}
MODE_ARG="${1:-}"
MATRIX_ARGS=()
case "$MODE_ARG" in
  "") [[ $# -le 1 ]] || usage ;;
  --review-only)
    [[ $# -eq 1 || ( $# -eq 2 && "$2" == inventory ) ]] || usage
    if [[ $# -eq 2 ]]; then MATRIX_ARGS+=(inventory); fi
    ;;
  --crash-matrix)
    shift
    shard="" sizes="" plan="" check=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shard)
          [[ "${2:-}" =~ ^([1-9][0-9]{0,2})/([1-9][0-9]{0,2})$ ]] || usage
          (( BASH_REMATCH[1] <= BASH_REMATCH[2] )) || usage
          shard="$2" ;;
        --sizes) [[ "${2:-}" =~ ^[1-9][0-9]{0,6},[1-9][0-9]{0,6}$ ]] || usage; sizes="$2" ;;
        --cut-ids-out) [[ -n "${2:-}" ]] || usage ;;
        --check-shards) [[ -d "${2:-}" ]] || usage; check="$2" ;;
        --plan) plan=1; MATRIX_ARGS+=(--plan); shift; continue ;;
        *) usage ;;
      esac
      MATRIX_ARGS+=("$1" "$2")
      shift 2
    done
    if [[ -n "$plan" && ( -n "$shard" || -n "$sizes" || -n "$check" ) ]]; then usage; fi
    if [[ -n "$check" && ( -z "$sizes" || -n "$shard" ) ]]; then usage; fi
    ;;
  *) usage ;;
esac
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/authority-selftest.XXXXXX")" || exit 1
# A normalized, symlink-free path (macOS TMPDIR ends in '/' and /var is a
# symlink): every file:// remote is built from it and must pass the writer's
# remote-path check.
TMP_ROOT="$(CDPATH= cd -P -- "$TMP_ROOT" && pwd -P)" || exit 1

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  chmod -R u+w -- "$TMP_ROOT" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME" || exit 1
export LC_ALL=C
export LANG=C
export PYTHONDONTWRITEBYTECODE=1
unset LOOP_AUTHORITY_TEST LOOP_AUTHORITY_CRASH_AT LOOP_AUTHORITY_TEST_BIN_DIR SSH_AUTH_SOCK
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_COUNT GIT_SSH_COMMAND GIT_PROXY_COMMAND GIT_SSL_NO_VERIFY

CHECKS=0
FAILED_CHECKS=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
}

# The python driver prints one "ok<TAB>description" or
# "not ok<TAB>description<TAB>detail" line per check.
tally() { # $1=results file $2=stderr file $3=python exit status $4=label
  local verdict description detail
  while IFS=$'\t' read -r verdict description detail; do
    if [[ "$verdict" == ok ]]; then
      pass "$description"
    else
      fail "$description${detail:+ -- $detail}"
    fi
  done < "$1"
  if [[ "$3" -ne 0 ]]; then
    fail "$4: the check program exited $3"
    sed 's/^/  | /' "$2" >&2
  fi
}

cat > "$TMP_ROOT/at.py" <<'PY'
"""authority-selftest driver. Modes:
  main <scripts> <lib> <tmp>         the subprocess and pty checks
  inproc <group> <scripts> <lib> <tmp>  in-process checks importing lib/loopauth
"""

from __future__ import annotations

import base64
import concurrent.futures
import glob
import hashlib
import itertools
import json
import os
import pty
import re
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback

MODE = sys.argv[1]
if MODE == "inproc":
    GROUP = sys.argv[2]
    SCRIPTS, LIB, TMP = sys.argv[3], sys.argv[4], sys.argv[5]
else:
    GROUP = ""
    SCRIPTS, LIB, TMP = sys.argv[2], sys.argv[3], sys.argv[4]
TMP = os.path.realpath(TMP)  # normalized: every file:// remote is built from it
AUTH = os.path.join(SCRIPTS, "loop-authority")
VERIFY = os.path.join(SCRIPTS, "loop-authority-verify")
BASH = shutil.which("bash") or "/bin/bash"
GIT = shutil.which("git") or "/usr/bin/git"
BIN_DIRS = ("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin")
POINTER_NS = "olddonkey-loop.anchor.pointer.v1"
ANCHOR_REF = "refs/olddonkey-loop/anchor"
IDENTITY = "olddonkey-loop <anchor@olddonkey-loop.invalid>"
TYPES = (
    "store.genesis", "epoch.rotated", "epoch.revoked", "store.regenesis", "request.opened",
    "request.cancelled", "request.expired", "request.redeemed", "nonce.issued",
    "repo.registered", "repo.rebound", "exec-root.registered", "standing.granted",
    "standing.revoked", "entry.enrolled", "entry.revoked", "platform.designated",
)
KEY_STEPS = 2 + 3 * len(TYPES)
WORKERS = max(2, min(8, os.cpu_count() or 2))
# The crash matrix is thousands of short-lived process trees: use every core.
MATRIX_WORKERS = max(2, min(16, os.cpu_count() or 2))
PRINCIPAL = {"kind": "operator-tty", "tty": "/dev/ttys000",
             "start_token": {"boot_id": "TESTBOOT-0000", "pid": 1, "start_time": 1}}
_emit_lock = threading.Lock()


def resolve_bin(name):
    for directory in BIN_DIRS:
        path = os.path.join(directory, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


SSH_KEYGEN = resolve_bin("ssh-keygen")
SSH = resolve_bin("ssh")


def emit(description, ok, detail=""):
    with _emit_lock:
        if ok:
            print(f"ok\t{description}", flush=True)
        else:
            print(f"not ok\t{description}\t{' '.join(str(detail).split())[:900]}", flush=True)


class Checks:
    def __init__(self):
        self.items = []

    def __call__(self, description, ok, detail=""):
        self.items.append((description, bool(ok), detail))
        return bool(ok)


def run_job(label, function):
    checks = Checks()
    try:
        function(checks)
    except Exception:  # noqa: BLE001 - a crashed case is a failed check
        checks(f"{label}: completes without an exception", False, traceback.format_exc()[-1500:])
    return checks.items


def parallel(jobs):
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        futures = [pool.submit(run_job, label, function) for label, function in jobs]
        for future in futures:
            for item in future.result():
                emit(*item)


def serial(label, function):
    for item in run_job(label, function):
        emit(*item)


# ---------------------------------------------------------------------------
# Test-side encodings (independent of lib/loopauth)
# ---------------------------------------------------------------------------

def canon(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def D(value):
    return "sha256:" + hashlib.sha256(canon(value)).hexdigest()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fdigest(seq, kind, content):
    return "sha256:" + hashlib.sha256(f"OLF1 {seq} {kind} {len(content)}".encode() + content).hexdigest()


def mkframe(seq, kind, content):
    return (f"OLF1 {seq} {kind} {len(content)} {fdigest(seq, kind, content)}\n").encode() + content + b"\n"


def parse_frames(data):
    frames, offset = [], 0
    while offset < len(data):
        newline = data.find(b"\n", offset)
        if newline < 0:
            break
        match = re.fullmatch(rb"OLF1 ([0-9]+) (\S+) ([0-9]+) (sha256:[0-9a-f]{64})", data[offset:newline])
        if not match:
            break
        length = int(match.group(3))
        end = newline + 1 + length
        if end + 1 > len(data) or data[end:end + 1] != b"\n":
            break
        frames.append({"seq": int(match.group(1)), "type": match.group(2).decode(), "length": length,
                       "digest": match.group(4).decode(), "offset": offset, "end": end + 1,
                       "header": newline + 1 - offset, "content": data[newline + 1:end],
                       "raw": data[offset:end + 1]})
        offset = end + 1
    return frames, offset


def git_id(kind, data):
    return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).hexdigest()


def commit_text(anchor_json, parent):
    active = json.loads(anchor_json)["active"]
    blob = git_id("blob", anchor_json)
    tree = git_id("tree", b"100644 anchor.json\0" + bytes.fromhex(blob))
    lines = [f"tree {tree}"] + ([f"parent {parent}"] if parent else [])
    lines += [f"author {IDENTITY} {active['seq']} +0000", f"committer {IDENTITY} {active['seq']} +0000"]
    return ("\n".join(lines) + f"\n\nanchor {active['store_id']} g{active['generation']} "
            f"s{active['seq']}\n").encode()


def expected_commit(anchor_json, parent):
    return git_id("commit", commit_text(anchor_json, parent))


def fingerprint_pub(line):
    blob = base64.b64decode(line.split()[1])
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def keygen_env():
    return {"PATH": ":".join(BIN_DIRS), "HOME": TMP, "LANG": "C", "LC_ALL": "C", "TMPDIR": TMP}


def ssh_keygen(*args, stdin=b"", check=True):
    result = subprocess.run([SSH_KEYGEN, *args], input=stdin, capture_output=True, env=keygen_env())
    if check and result.returncode != 0:
        raise RuntimeError(f"ssh-keygen {args}: {result.stderr.decode()}")
    return result


def git_env(extra=None):
    env = {"PATH": os.environ.get("PATH", ":".join(BIN_DIRS)), "HOME": TMP, "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    env.update(extra or {})
    return env


def git(*args, stdin=b"", check=True, extra=None, cwd=None):
    result = subprocess.run([GIT, "-c", "core.hooksPath=/dev/null", *args], input=stdin,
                            capture_output=True, env=git_env(extra), cwd=cwd or TMP)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {args}: {result.stderr.decode()}")
    return result


def last_json(text):
    for line in reversed(text.replace("\r\n", "\n").split("\n")):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {}


def run_on_pty(argv, env, cwd, answer="echo", timeout=600):
    """Run argv with stdin, stdout, and stderr on a pseudo terminal (Python's
    pty); when the ceremony prompts, type the printed challenge back
    ("echo"), a different one ("wrong"), or nothing (None)."""
    master, slave = pty.openpty()
    proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, cwd=cwd,
                            close_fds=True, start_new_session=True)
    os.close(slave)
    out = b""
    answered = False
    deadline = time.monotonic() + timeout
    while True:
        if time.monotonic() > deadline:
            proc.kill()
            break
        ready, _w, _x = select.select([master], [], [], 0.2)
        if master in ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
            if answer and not answered and b"type the challenge to proceed: " in out:
                match = re.search(rb"challenge: ([0-9a-f]{12})", out)
                code = match.group(1) if match else b""
                reply = code if answer == "echo" else (b"f" * 12 if code != b"f" * 12 else b"e" * 12)
                os.write(master, reply + b"\n")
                answered = True
        elif proc.poll() is not None:
            try:
                while True:
                    ready, _w, _x = select.select([master], [], [], 0.1)
                    if master not in ready:
                        break
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    out += chunk
            except OSError:
                pass
            break
    proc.wait()
    os.close(master)
    return Res(proc.returncode, out.decode("utf-8", "replace").replace("\r\n", "\n"), "")


class Res:
    def __init__(self, rc, out, err):
        self.rc = rc
        self.out = out
        self.err = err
        self.json = last_json(out)

    def __repr__(self):
        return f"rc={self.rc} json={json.dumps(self.json)[:400]} err={self.err[-400:]!r} out={self.out[-300:]!r}"


# ---------------------------------------------------------------------------
# Cases: a scratch HOME, a bare file:// remote, and the real scripts
# ---------------------------------------------------------------------------

CASE_ROOT = os.path.join(TMP, "cases")
_serial = itertools.count(1)
_serial_lock = threading.Lock()


def base_env(home, test=True):
    env = {"HOME": home, "PATH": os.environ.get("PATH", ":".join(BIN_DIRS)), "LANG": "C",
           "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    if test:
        env["LOOP_AUTHORITY_TEST"] = "1"
    return env


class Case:
    def __init__(self, label, test=True, remote=True, share=None):
        with _serial_lock:
            number = next(_serial)
        os.makedirs(CASE_ROOT, exist_ok=True)
        self.label = label
        self.dir = tempfile.mkdtemp(prefix=f"c{number:04d}", dir=CASE_ROOT)
        self.home = os.path.join(self.dir, "home")
        os.mkdir(self.home, 0o700)
        if share is not None:
            self.remote = share.remote
        else:
            self.remote = os.path.join(self.dir, "remote.git")
            if remote:
                git("init", "--bare", "-q", self.remote)
        self.url = "file://" + self.remote
        self.env = base_env(self.home, test)

    # -- running the scripts
    def run(self, argv, env=None, cwd=None, stdin=subprocess.DEVNULL, timeout=600):
        full = dict(self.env)
        full.update(env or {})
        for key in [k for k, v in full.items() if v is None]:
            del full[key]
        result = subprocess.run(argv, env=full, cwd=cwd or self.dir, stdin=stdin,
                                capture_output=True, timeout=timeout)
        return Res(result.returncode, result.stdout.decode("utf-8", "replace"),
                   result.stderr.decode("utf-8", "replace"))

    def writer(self, *args, env=None, cwd=None):
        return self.run([BASH, AUTH, *args], env=env, cwd=cwd)

    def verifier(self, env=None, cwd=None):
        return self.run([BASH, VERIFY], env=env, cwd=cwd)

    # --- pty driver begin
    def ceremony(self, *args, env=None, answer="echo", cwd=None, timeout=600):
        """Run `loop-authority ceremony ...` with stdin and stdout on a pseudo
        terminal (Python's pty) and type the printed challenge back."""
        full = dict(self.env)
        full.update(env or {})
        for key in [k for k, v in full.items() if v is None]:
            del full[key]
        return run_on_pty([BASH, AUTH, "ceremony", *args], full, cwd or self.dir, answer, timeout)
    # --- pty driver end

    def genesis(self, env=None, **kw):
        return self.ceremony("genesis", "--remote", self.url, env=env, **kw)

    # -- the store on disk
    def auth(self, *parts):
        return os.path.join(self.home, ".config", "olddonkey-loop", "authority", *parts)

    def active(self):
        with open(self.auth("active"), "rb") as handle:
            return json.loads(handle.read())

    def store_dir(self, store_id=None):
        return self.auth("stores", store_id or self.active()["store_id"])

    def log_path(self, store_id=None):
        return os.path.join(self.store_dir(store_id), "log", "segment-000001.olf")

    def read(self, path):
        with open(path, "rb") as handle:
            return handle.read()

    def write(self, path, data, mode=0o600):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.chmod(path, mode)

    def intent(self, store_id=None):
        path = os.path.join(self.store_dir(store_id), "intent")
        return json.loads(self.read(path)) if os.path.exists(path) else None

    def genesis_intent(self):
        path = self.auth("genesis.intent")
        return json.loads(self.read(path)) if os.path.exists(path) else None

    def snapshot(self, root=None):
        root = root or self.auth()
        result = {}
        if not os.path.lexists(root):
            return result
        for current, dirs, files in os.walk(root):
            dirs.sort()
            for name in sorted(dirs):
                full = os.path.join(current, name)
                result[os.path.relpath(full, root) + "/"] = ("d", stat.S_IMODE(os.lstat(full).st_mode), "")
            for name in sorted(files):
                full = os.path.join(current, name)
                info = os.lstat(full)
                data = b""
                if stat.S_ISREG(info.st_mode) and info.st_mode & 0o400:
                    data = self.read(full)
                result[os.path.relpath(full, root)] = ("f", stat.S_IMODE(info.st_mode), sha(data))
        return result

    def remote_snapshot(self):
        return git("--git-dir", self.remote, "for-each-ref", "--format=%(objectname) %(refname)").stdout

    def tip(self):
        result = git("--git-dir", self.remote, "rev-parse", "--verify", "-q", ANCHOR_REF, check=False)
        text = result.stdout.decode().strip()
        return text or None

    def set_tip(self, oid):
        if oid is None:
            git("--git-dir", self.remote, "update-ref", "-d", ANCHOR_REF)
        else:
            git("--git-dir", self.remote, "update-ref", ANCHOR_REF, oid)

    def cat(self, oid):
        return git("--git-dir", self.remote, "cat-file", "-p", oid).stdout

    def anchor_json_at(self, oid):
        tree = re.search(rb"^tree ([0-9a-f]{40})", self.cat(oid), re.M).group(1).decode()
        blob = re.search(rb"blob ([0-9a-f]{40})\tanchor\.json", self.cat(tree)).group(1).decode()
        return self.cat(blob)

    def parent_of(self, oid):
        match = re.search(rb"^parent ([0-9a-f]{40})", self.cat(oid), re.M)
        return match.group(1).decode() if match else None

    def fork(self, label):
        """A copy of HOME sharing this case's remote (read-only use)."""
        other = Case(label, test="LOOP_AUTHORITY_TEST" in self.env, share=self)
        shutil.rmtree(other.home)
        shutil.copytree(self.home, other.home, symlinks=True)
        return other

    def status(self, env=None):
        return self.writer("status", env=env)

    def agree(self, checks, label, expect_state=None, expect_row="any", env=None):
        """The writer's verify and the independent verifier classify alike."""
        writer = self.writer("verify", env=env)
        independent = self.verifier(env=env)
        same = (writer.json.get("state") == independent.json.get("state")
                and writer.json.get("authorizing_state") == independent.json.get("authorizing_state")
                and writer.json.get("current_authorization") == independent.json.get("current_authorization"))
        checks(f"verifier agrees with the writer: {label}", same and writer.json.get("state"),
               f"writer {writer} | verifier {independent}")
        if expect_state is not None:
            checks(f"{label}: state is {expect_state}", writer.json.get("state") == expect_state
                   and independent.json.get("state") == expect_state, f"writer {writer} | verifier {independent}")
        if expect_row != "any":
            checks(f"{label}: row is {expect_row}", writer.json.get("row") == expect_row, writer)
        return writer, independent


# ---------------------------------------------------------------------------
# The forger: records, pointers, and commits built by the test itself
# ---------------------------------------------------------------------------

class Lineage:
    """A test-side reading of a store (unverified) and signing with its keys."""

    def __init__(self, case, store_id=None, archived=False):
        self.case = case
        active = case.active() if store_id is None else None
        self.store_id = store_id or active["store_id"]
        self.dir = case.auth("archive" if archived else "stores", self.store_id)
        self.data = case.read(os.path.join(self.dir, "log", "segment-000001.olf"))
        self.frames, self.end = parse_frames(self.data)
        self.payloads = [json.loads(fr["content"])["payload"] for fr in self.frames]
        self.generation = self.payloads[0]["generation"]
        self.epochs = {}
        self.active_epoch = None
        self.pointer_epochs = []
        for payload in self.payloads:
            body = payload["body"]
            if payload["type"] in ("store.genesis", "store.regenesis"):
                self.epochs[1] = dict(body, state="active")
                self.active_epoch = 1
                self.pointer_epochs.append(1)
            elif payload["type"] == "epoch.rotated":
                self.epochs[self.active_epoch]["state"] = "verify-only"
                self.epochs[body["epoch"]] = dict(body, state="active")
                self.active_epoch = body["epoch"]
                self.pointer_epochs.append(body["epoch"])
            elif payload["type"] == "epoch.revoked":
                self.pointer_epochs.append(self.active_epoch)
                self.epochs[body["epoch"]]["state"] = "revoked"
                if body["epoch"] == self.active_epoch:
                    self.active_epoch = None

    @property
    def L(self):
        return len(self.frames)

    def keydir(self, epoch):
        return os.path.join(self.dir, "keys", self.epochs[epoch]["key_dir"])

    def ptr(self, k):
        epoch = self.pointer_epochs[k - 1]
        return {"store_id": self.store_id, "generation": self.generation,
                "genesis_digest": self.frames[0]["digest"], "seq": k,
                "record_digest": self.frames[k - 1]["digest"], "epoch": epoch,
                "key_id": self.epochs[epoch]["root_key_id"]}

    def sign(self, key_path, namespace, data):
        return ssh_keygen("-Y", "sign", "-f", key_path, "-n", namespace, stdin=data).stdout.decode()

    def forge(self, kind, body, *, epoch=None, seq=None, prev="auto", key_id=None, cert=None,
              namespace=None, store_id=None, generation=None):
        epoch = epoch or self.active_epoch
        seq = seq or self.L + 1
        cert = cert or os.path.join(self.keydir(epoch), f"{kind}-cert.pub")
        if key_id is None:
            pub = self.case.read(cert.replace("-cert.pub", ".pub")).decode()
            key_id = fingerprint_pub(pub)
        payload = {"type": kind, "v": 1, "store_id": store_id or self.store_id,
                   "generation": generation or self.generation, "seq": seq, "epoch": epoch,
                   "key_id": key_id,
                   "prev": (self.frames[seq - 2]["digest"] if seq > 1 else None) if prev == "auto" else prev,
                   "body": body}
        sig = self.sign(cert, namespace or f"olddonkey-loop.authority.{kind}.v1", canon(payload))
        content = canon({"payload": payload, "sig": sig})
        return mkframe(seq, kind, content), fdigest(seq, kind, content), payload

    def revoke_body(self, epoch, prior):
        return {"ceremony": "revoke", "envelope_digest": D({"x": 1}), "principal": PRINCIPAL,
                "epoch": epoch, "prior_state": prior}

    def pointer(self, active, prev_generation=None, *, epoch=None, key_path=None,
                namespace=POINTER_NS):
        epoch = epoch or active["epoch"]
        key_path = key_path or os.path.join(self.keydir(epoch), "root")
        signed = canon({"active": active, "prev_generation": prev_generation})
        sig = self.sign(key_path, namespace, signed)
        return canon({"active": active, "prev_generation": prev_generation, "sig": sig})


def remote_commit(case, anchor_json, parent, *, extra_entry=False, blob_data=None, set_tip=True):
    """Build an anchor commit directly in the bare remote (deterministic
    identity and dates), optionally malformed, and point the ref at it."""
    active = json.loads(anchor_json)["active"]
    data = anchor_json if blob_data is None else blob_data
    blob = git("--git-dir", case.remote, "hash-object", "-w", "--stdin", stdin=data).stdout.decode().strip()
    lines = f"100644 blob {blob}\tanchor.json\n"
    if extra_entry:
        other = git("--git-dir", case.remote, "hash-object", "-w", "--stdin", stdin=b"x").stdout.decode().strip()
        lines += f"100644 blob {other}\textra.txt\n"
    tree = git("--git-dir", case.remote, "mktree", stdin=lines.encode()).stdout.decode().strip()
    date = f"@{active['seq']} +0000"
    extra = {"GIT_AUTHOR_NAME": "olddonkey-loop", "GIT_AUTHOR_EMAIL": "anchor@olddonkey-loop.invalid",
             "GIT_COMMITTER_NAME": "olddonkey-loop", "GIT_COMMITTER_EMAIL": "anchor@olddonkey-loop.invalid",
             "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
    args = ["--git-dir", case.remote, "commit-tree", tree]
    if parent:
        args += ["-p", parent]
    args += ["-m", f"anchor {active['store_id']} g{active['generation']} s{active['seq']}"]
    oid = git(*args, extra=extra).stdout.decode().strip()
    if set_tip:
        case.set_tip(oid)
    return oid


def forge_intent(lineage, frame_bytes, seq, offset, anchor_json, parent, extra=None):
    frames, _end = parse_frames(frame_bytes)
    intent = {"seq": seq, "offset": offset, "length": frames[0]["length"], "digest": frames[0]["digest"],
              "expected_parent": parent, "anchor_json": anchor_json.decode(),
              "anchor_commit": expected_commit(anchor_json, parent), "frame_length": len(frame_bytes),
              "frame_b64": base64.b64encode(frame_bytes).decode()}
    intent.update(extra or {})
    return canon(intent)


def committed_case(label, rotate=False, revoke_epoch=None):
    """A fresh case after a real genesis (and optionally a rotation and a
    revocation) through the pty ceremonies."""
    case = Case(label)
    result = case.genesis()
    if result.rc != 0:
        raise RuntimeError(f"{label}: genesis failed: {result}")
    if rotate:
        result = case.ceremony("rotate")
        if result.rc != 0:
            raise RuntimeError(f"{label}: rotate failed: {result}")
    if revoke_epoch is not None:
        result = case.ceremony("revoke", "--epoch", str(revoke_epoch))
        if result.rc != 0:
            raise RuntimeError(f"{label}: revoke failed: {result}")
    return case


def unchanged(checks, label, case, before, remote_before=None):
    after = case.snapshot()
    ok = after == before
    diff = sorted(set(after.items()) ^ set(before.items()))[:6]
    checks(f"{label}: the authority directory is unchanged", ok, diff)
    if remote_before is not None:
        checks(f"{label}: the remote is unchanged", case.remote_snapshot() == remote_before)


# The driver continues below.
PY

cat >> "$TMP_ROOT/at.py" <<'PY'
# ===========================================================================
# In-process groups (they import lib/loopauth; run as their own process)
# ===========================================================================

def load_lib(home):
    os.environ["HOME"] = home
    os.makedirs(home, exist_ok=True)
    sys.dont_write_bytecode = True
    sys.path.insert(0, LIB)
    import importlib
    return {name: importlib.import_module(f"loopauth.{name}")
            for name in ("canonical", "records", "frame", "keys", "anchor", "tools", "store",
                         "recover", "registry", "ceremony")}


def refused(function, *codes):
    """(refused?, code) for a call expected to raise one of the library's
    errors; codes, when given, must include the error's code."""
    try:
        function()
    except Exception as error:  # noqa: BLE001
        code = getattr(error, "code", type(error).__name__)
        return (not codes or code in codes), code
    return False, "not refused"


SIG_FIXTURE = "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n"


def g_vectors(argv):
    m = load_lib(os.path.join(TMP, f"inproc-vectors-{os.getpid()}"))
    records, frame, canonical, recover = m["records"], m["frame"], m["canonical"], m["recover"]
    payload = {
        "type": "epoch.revoked", "v": 1, "store_id": "0123456789abcdef0123456789abcdef",
        "generation": 1, "seq": 2, "epoch": 1, "key_id": "SHA256:" + "A" * 43,
        "prev": "sha256:" + "ab" * 32,
        "body": {"ceremony": "revoke", "envelope_digest": "sha256:" + "cd" * 32,
                 "principal": {"kind": "operator-tty", "tty": "/dev/ttys000",
                               "start_token": {"boot_id": "TESTBOOT-0000", "pid": 1, "start_time": 1}},
                 "epoch": 1, "prior_state": "verify-only"},
    }
    frozen = ('{"body":{"ceremony":"revoke","envelope_digest":"sha256:' + "cd" * 32 + '","epoch":1,'
              '"principal":{"kind":"operator-tty","start_token":{"boot_id":"TESTBOOT-0000","pid":1,'
              '"start_time":1},"tty":"/dev/ttys000"},"prior_state":"verify-only"},"epoch":1,'
              '"generation":1,"key_id":"SHA256:' + "A" * 43 + '","prev":"sha256:' + "ab" * 32 + '",'
              '"seq":2,"store_id":"0123456789abcdef0123456789abcdef","type":"epoch.revoked","v":1}').encode()
    emit("vectors: the canonical payload bytes are frozen", records.payload_bytes(payload) == frozen,
         records.payload_bytes(payload))
    emit("vectors: the payload digest is sha256 over those bytes",
         canonical.digest(payload) == "sha256:" + sha(frozen))
    ok, code = refused(lambda: records.check_payload(payload, remote_check=m["tools"].anchor_class_of))
    emit("vectors: the frozen payload passes the epoch.revoked schema", not ok and code == "not refused", code)
    content = canon({"payload": payload, "sig": SIG_FIXTURE})
    prefix = f"OLF1 2 epoch.revoked {len(content)}".encode()
    digest = "sha256:" + sha(prefix + content)
    encoded = frame.encode(2, "epoch.revoked", content)
    emit("vectors: a frame is 'OLF1 <seq> <type> <length> <digest>\\n' + payload + '\\n'",
         encoded == prefix + b" " + digest.encode() + b"\n" + content + b"\n", encoded[:120])
    emit("vectors: the frame digest is over the header without its digest, then the payload",
         frame.frame_digest(2, "epoch.revoked", content) == digest)
    parsed = frame.parse_log(encoded, 2)
    emit("vectors: the frame parses back to one frame", len(parsed.frames) == 1 and not parsed.tail
         and parsed.frames[0].digest == digest)
    header_end = encoded.index(b"\n")
    mutations = {
        "magic": b"OLF2" + encoded[4:],
        "seq": encoded.replace(b"OLF1 2 ", b"OLF1 3 ", 1),
        "type": encoded.replace(b"epoch.revoked", b"epoch.rotated", 1),
        "length+1": encoded.replace(f" {len(content)} ".encode(), f" {len(content) + 1} ".encode(), 1),
        "length-1": encoded.replace(f" {len(content)} ".encode(), f" {len(content) - 1} ".encode(), 1),
        "digest": encoded[:header_end - 1] + (b"0" if encoded[header_end - 1:header_end] != b"0" else b"1")
        + encoded[header_end:],
    }
    for label, data in mutations.items():
        result = frame.parse_log(data, 2)
        emit(f"vectors: a frame with a mutated {label} is not a complete valid frame",
             result.frames == [] and bool(result.tail))
    # every byte boundary of a frame write: A1.6's tail classification
    intent = {"seq": 2, "offset": 0}
    kinds = [recover.classify_tail(encoded[:n], None, 0, 1, intent, encoded)
             for n in range(1, len(encoded))]
    emit(f"vectors: every one of the {len(encoded) - 1} byte cuts of a frame is torn, the last "
         "is unterminated", kinds[:-1] == ["torn"] * (len(encoded) - 2) and kinds[-1] == "unterminated",
         [k for k in kinds if k != "torn"][:3])
    altered = bytearray(encoded[:40])
    altered[20] ^= 0x01
    emit("vectors: an altered prefix of the same length is nonconforming, never torn",
         recover.classify_tail(bytes(altered), None, 0, 1, intent, encoded) == "nonconforming")
    emit("vectors: a short tail without a matching intent is nonconforming",
         recover.classify_tail(encoded[:40], None, 0, 1, None, None) == "nonconforming"
         and recover.classify_tail(encoded[:40], None, 0, 1, {"seq": 3, "offset": 0}, encoded)
         == "nonconforming")
    kinds1 = [recover.classify_frame1_bytes(encoded[:n], encoded) for n in range(0, len(encoded) + 1)]
    emit("vectors: A2.3 frame-1 classes over every byte cut: none, torn..., unterminated, valid",
         kinds1[0] == "none" and kinds1[-1] == "valid" and kinds1[-2] == "unterminated"
         and set(kinds1[1:-2]) == {"torn"})
    emit("vectors: trailing bytes after a valid frame 1 are nonconforming",
         recover.classify_frame1_bytes(encoded + b"x", encoded) == "nonconforming")
    for name in ("segment_reset", "mechanism_closed", "release_accepted", "segment.reset",
                 "mechanism-closed", "release.accepted"):
        ok, code = refused(lambda name=name: records.check_type(name), "nested-only")
        emit(f"records: {name} has no standalone type (nested only)", ok, code)
        ok, _code = refused(lambda name=name: records.namespace(name))
        emit(f"records: {name} has no signing namespace", ok)
    emit("records: the closed type list is frozen", records.TYPES == TYPES, records.TYPES)


def make_keys(directory):
    """root1, root2, and subkeys certified in several ways, by ssh-keygen."""
    os.makedirs(directory, exist_ok=True)

    def gen(name):
        path = os.path.join(directory, name)
        ssh_keygen("-q", "-t", "ed25519", "-N", "", "-C", name, "-f", path)
        return path

    def cert(subkey, root, identity, principal, validity="always:forever"):
        ssh_keygen("-q", "-s", root, "-I", identity, "-n", principal, "-V", validity, subkey + ".pub")
        return subkey + "-cert.pub"

    out = {"root1": gen("root1"), "root2": gen("root2")}
    specs = {
        "A": ("epoch.revoked@e1", "epoch.revoked", "root1", "always:forever"),
        "B": ("epoch.rotated@e1", "epoch.rotated", "root1", "always:forever"),
        "A_principal": ("epoch.revoked@e1", "epoch.rotated", "root1", "always:forever"),
        "A_epoch": ("epoch.revoked@e2", "epoch.revoked", "root1", "always:forever"),
        "A_root2": ("epoch.revoked@e1", "epoch.revoked", "root2", "always:forever"),
        "A_bounded": ("epoch.revoked@e1", "epoch.revoked", "root1", "+52w"),
    }
    for name, (identity, principal, root, validity) in specs.items():
        out[name] = cert(gen(name), out[root], identity, principal, validity)
    return out


def g_keys(argv):
    m = load_lib(os.path.join(TMP, f"inproc-keys-{os.getpid()}"))
    keys, records = m["keys"], m["records"]
    k = make_keys(os.path.join(TMP, f"keys-{os.getpid()}"))
    root1 = " ".join(open(k["root1"] + ".pub").read().split()[:2])
    root2 = " ".join(open(k["root2"] + ".pub").read().split()[:2])
    data = b"payload bytes"

    def sign(cert, namespace, payload=data):
        return ssh_keygen("-Y", "sign", "-f", cert, "-n", namespace, stdin=payload).stdout.decode()

    ns_a, ns_b = "olddonkey-loop.authority.epoch.revoked.v1", "olddonkey-loop.authority.epoch.rotated.v1"
    good = sign(k["A"], ns_a)
    key_id = keys.verify_seal(record_type="epoch.revoked", epoch=1, root_pub=root1, payload=data, sig=good)
    emit("seals: a type's subkey seal verifies under its epoch root, returning the subkey's key_id",
         key_id == fingerprint_pub(open(os.path.join(os.path.dirname(k["A"]), "A.pub")).read()))
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.rotated", epoch=1, root_pub=root1,
                                                 payload=data, sig=good))
    emit("seals: a signature for type A never verifies as type B", ok, code)
    key_alone = sign(k["A"], ns_b)
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.rotated", epoch=1, root_pub=root1,
                                                 payload=data, sig=key_alone), "cert-identity")
    emit("seals: type A's key under type B's namespace is refused as B (key alone)", ok, code)
    signers_b = os.path.join(TMP, f"signers-b-{os.getpid()}")
    with open(signers_b, "w") as handle:
        handle.write(f'epoch.rotated cert-authority,namespaces="{ns_b}" {root1}\n')
    sig_path = os.path.join(TMP, f"sig-{os.getpid()}")

    def raw_verify(sig, principal, namespace, signers):
        with open(sig_path, "w") as handle:
            handle.write(sig)
        return ssh_keygen("-Y", "verify", "-f", signers, "-I", principal, "-n", namespace, "-s", sig_path,
                          stdin=data, check=False).returncode

    emit("seals: ssh-keygen itself refuses type A's key for principal B",
         raw_verify(key_alone, "epoch.rotated", ns_b, signers_b) != 0)
    ns_alone = sign(k["B"], ns_a)
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.rotated", epoch=1, root_pub=root1,
                                                 payload=data, sig=ns_alone), "sig-namespace")
    emit("seals: type B's key under type A's namespace is refused as B (namespace alone)", ok, code)
    emit("seals: ssh-keygen itself refuses a namespace the allowed_signers line does not permit",
         raw_verify(ns_alone, "epoch.rotated", ns_a, signers_b) != 0)
    for label, name, code_wanted in (("a wrong principal", "A_principal", "cert-principal"),
                                     ("a key identity naming another epoch", "A_epoch", "cert-identity"),
                                     ("another root", "A_root2", "cert-root"),
                                     ("bounded validity", "A_bounded", "cert-validity")):
        sig = sign(k[name], ns_a)
        ok, code = refused(lambda sig=sig: keys.verify_seal(record_type="epoch.revoked", epoch=1,
                                                             root_pub=root1, payload=data, sig=sig),
                           code_wanted)
        emit(f"seals: a subkey certificate with {label} is refused", ok, code)
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.revoked", epoch=2, root_pub=root1,
                                                 payload=data, sig=good), "cert-identity")
    emit("seals: an epoch-1 certificate is refused for an epoch-2 record", ok, code)
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.revoked", epoch=1, root_pub=root2,
                                                 payload=data, sig=good), "cert-root")
    emit("seals: a certificate from another epoch's root is refused", ok, code)
    ok, code = refused(lambda: keys.verify_seal(record_type="epoch.revoked", epoch=1, root_pub=root1,
                                                 payload=data + b"x", sig=good))
    emit("seals: an altered payload is refused", ok, code)
    # pointers
    pointer = canon({"active": {"seq": 1}, "prev_generation": None})
    by_root = sign(k["root1"], POINTER_NS, pointer)
    ok, code = refused(lambda: keys.verify_pointer(root_pub=root1, pointer=pointer, sig=by_root))
    emit("pointer: a pointer signed by the active root verifies", not ok and code == "not refused", code)
    for label, sig, root, payload in (
        ("another epoch's root", sign(k["root2"], POINTER_NS, pointer), root1, pointer),
        ("a subkey", sign(k["A"], POINTER_NS, pointer), root1, pointer),
        ("a record namespace", sign(k["root1"], ns_a, pointer), root1, pointer),
        ("altered bytes after signing", by_root, root1, canon({"active": {"seq": 2}, "prev_generation": None})),
    ):
        ok, code = refused(lambda sig=sig, root=root, payload=payload:
                           keys.verify_pointer(root_pub=root, pointer=payload, sig=sig))
        emit(f"pointer: a pointer signed by {label} is refused" if "bytes" not in label
             else f"pointer: a pointer with {label} is refused", ok, code)


def g_transport(argv):
    m = load_lib(argv[0])
    tools = m["tools"]
    os.environ["SSH_AUTH_SOCK"] = "/nonexistent/agent.sock"
    for name in ("GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_CONFIG_COUNT", "GIT_SSL_NO_VERIFY"):
        os.environ[name] = "injected"
    git_path, ssh_path, gh_path = resolve_bin("git"), resolve_bin("ssh"), resolve_bin("gh")
    prefix = [git_path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    frozen_transport = {
        "ssh": ["-c", "protocol.allow=never", "-c", "protocol.ssh.allow=always", "-c",
                f"core.sshCommand={ssh_path} -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes"
                " -o UpdateHostKeys=no"],
        "https": ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c",
                  "http.sslVerify=true", "-c", "http.followRedirects=false"]
        + (["-c", "credential.helper=", "-c", f"credential.helper=!{gh_path} auth git-credential"]
           if gh_path else []),
        "file": ["-c", "protocol.allow=never", "-c", "protocol.file.allow=always"],
    }
    urls = {"ssh": "git@example.invalid:owner/anchor.git",
            "https": "https://example.invalid:8443/owner/anchor.git",
            "file": "file:///tmp/authority-selftest/anchor.git"}
    home = os.path.realpath(os.environ["HOME"])
    for kind, url in urls.items():
        tools._PINNED.clear()
        tools.pin_remote(tools.parse_remote(url, allow_test=True))
        scratch = tools.new_scratch_repo()
        env_frozen = {"PATH": "/usr/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home, "LANG": "C",
                      "LC_ALL": "C", "TMPDIR": tools.scratch_tmp(), "SSH_AUTH_SOCK": "/nonexistent/agent.sock",
                      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                      "GIT_TERMINAL_PROMPT": "0"}
        wanted = {
            "git.ls-remote": prefix + frozen_transport[kind] + ["-C", scratch, "ls-remote", url, ANCHOR_REF],
            "git.fetch-anchor": prefix + frozen_transport[kind] + [
                "-C", scratch, "fetch", "--no-tags", "--no-write-fetch-head", url,
                "+refs/olddonkey-loop/anchor:refs/readback/anchor"],
            "git.push-anchor": prefix + frozen_transport[kind] + [
                "-C", scratch, "push", url, "refs/olddonkey-loop/*:refs/olddonkey-loop/*"],
        }
        for command, argv_wanted in wanted.items():
            params = {"scratch": scratch, "remote": url}
            if command == "git.push-anchor":
                params["commit"] = "0" * 40
            built = tools.build_argv(command, params)
            env = tools.command_env(command, params)
            emit(f"transport: the writer's {command} argv for a {kind} remote is the frozen one",
                 built == argv_wanted, built)
            emit(f"transport: the writer's {command} environment for a {kind} remote is the frozen one",
                 env == env_frozen, env)
        keygen_env_built = tools.command_env("ssh-keygen.verify", {})
        emit(f"transport: ssh-keygen never receives SSH_AUTH_SOCK ({kind})",
             "SSH_AUTH_SOCK" not in keygen_env_built and set(keygen_env_built) ==
             {"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"}, keygen_env_built)
        tools.remove_scratch_repo(scratch)
        verifier = subprocess.run([BASH, VERIFY, "transport-plan", url], capture_output=True,
                                  env={"HOME": home, "PATH": os.environ["PATH"], "LOOP_AUTHORITY_TEST": "1",
                                       "SSH_AUTH_SOCK": "/nonexistent/agent.sock",
                                       "GIT_SSH_COMMAND": "injected"})
        plan = last_json(verifier.stdout.decode())
        emit(f"transport: the verifier's fetch argv for a {kind} remote is the frozen one",
             plan.get("fetch") == prefix + frozen_transport[kind] + [
                 "-C", "<temp>/anchor.git", "fetch", "--no-tags", "--no-write-fetch-head", url,
                 "+refs/olddonkey-loop/anchor:refs/readback/anchor"], plan.get("fetch"))
        emit(f"transport: the verifier's ls-remote, init and cat-file argv are the frozen ones ({kind})",
             plan.get("ls-remote") == prefix + frozen_transport[kind] + [
                 "-C", "<temp>/anchor.git", "ls-remote", url, ANCHOR_REF]
             and plan.get("init") == prefix + ["-C", "<temp>/anchor.git", "init", "--bare", "--template=",
                                           "--object-format=sha1", "."]
             and plan.get("cat-file") == prefix + ["-C", "<temp>/anchor.git", "cat-file", "-p", "0" * 40],
             plan)
        emit(f"transport: the verifier's environment is the frozen allowlist ({kind})",
             plan.get("env") == dict(env_frozen, TMPDIR="<temp>"), plan.get("env"))
    # remote forms
    for label, url in (("ext::", "ext::sh -c touch% /tmp/x"), ("fd::", "fd::3"),
                       ("another <x>:: form", "foo::https://example.invalid/x.git"),
                       ("whitespace", "https://example.invalid/a b.git"),
                       ("a leading -", "-uhttps://example.invalid/x.git"),
                       ("credentials", "https://user:secret@example.invalid/x.git"),
                       ("a user in an https URL", "https://user@example.invalid/x.git"),
                       ("an ssh:// URL", "ssh://git@example.invalid/x.git"),
                       ("a query", "https://example.invalid/x.git?a=1"),
                       ("a dot-dot path", "git@example.invalid:../x.git")):
        ok, code = refused(lambda url=url: tools.parse_remote(url, allow_test=True), "remote")
        emit(f"remote: {label} is refused", ok, code)
    ok, code = refused(lambda: tools.parse_remote("file:///tmp/x.git", allow_test=False), "remote-test-only")
    emit("remote: file:// is refused without LOOP_AUTHORITY_TEST=1", ok, code)
    emit("remote: a file:// remote is a test lineage; SSH and HTTPS are production",
         tools.parse_remote("file:///tmp/x.git", allow_test=True).anchor_class == "test"
         and tools.parse_remote(urls["ssh"], allow_test=False).anchor_class == "production"
         and tools.parse_remote(urls["https"], allow_test=False).anchor_class == "production")
    # scratch config
    for label, text, good in (("[core] only", "[core]\n\tbare = true\n", True),
                              ("a [remote] section", "[core]\n[remote \"o\"]\n\turl = x\n", False),
                              ("url.insteadOf", "[core]\n[url \"file:///decoy\"]\n\tinsteadOf = x\n", False),
                              ("pushInsteadOf", "[core]\n[url \"d\"]\n\tpushInsteadOf = x\n", False),
                              ("a credential helper", "[core]\n[credential]\n\thelper = x\n", False),
                              ("an include", "[core]\n[include]\n\tpath = x\n", False)):
        directory = tempfile.mkdtemp(dir=TMP)
        with open(os.path.join(directory, "config"), "w") as handle:
            handle.write(text)
        ok, code = refused(lambda directory=directory: tools.check_scratch_config(directory), "scratch-config")
        emit(f"scratch config: {label} is {'accepted' if good else 'refused'}", (not ok) if good else ok, code)
    ok, code = refused(lambda: tools.run("git.fetch", scratch="x"), "unlisted")
    emit("tools: a command outside the closed table is refused", ok, code)
    # Frozen argv alone cannot prove commit binding: the pattern contains no
    # <commit>. Exercise the authorized sink with real Git and a local remote.
    remote = os.path.join(home, "transport-push.git")
    git("init", "--bare", "-q", remote)
    tools._PINNED.clear()
    url = "file://" + remote
    tools.pin_remote(tools.parse_remote(url, allow_test=True))
    scratch = tools.new_scratch_repo()
    blob = tools.run("git.hash-object", scratch=scratch, stdin=b"transport binding\n").stdout.decode().strip()
    tree = tools.run("git.mktree", scratch=scratch, stdin=f"100644 blob {blob}\tanchor.json\n".encode()).stdout.decode().strip()
    commits = [tools.run("git.commit-tree", scratch=scratch, tree=tree, parent=None,
                        message=f"anchor {'a' * 32} g1 s{seq}", seq=seq).stdout.decode().strip()
               for seq in (1, 2)]
    tools.run("git.update-anchor", scratch=scratch, commit=commits[1])
    store = m["store"]
    token = store.begin("authority-genesis", PRINCIPAL)
    try:
        for label, params in (("missing", {"scratch": scratch, "remote": url}),
                              ("malformed", {"scratch": scratch, "remote": url, "commit": "bad"})):
            ok, code = refused(lambda params=params: tools.build_argv("git.push-anchor", params), "params")
            emit(f"transport: {label} push commit is refused", ok, code)
        ok, code = refused(lambda: store._run_sink(token, "git.push-anchor", scratch=scratch,
                                                  remote=url, commit=commits[0]), "anchor-scratch")
        emit("transport: the pattern push sink checks the commit its permit covers", ok, code)
        emit("transport: the refused sink publishes no remote ref",
             not git("--git-dir", remote, "for-each-ref").stdout)
        tools.run("git.update-anchor", scratch=scratch, commit=commits[0])
        result = store._run_sink(token, "git.push-anchor", scratch=scratch, remote=url, commit=commits[0])
        emit("transport: the same sink accepts the bound commit with real Git", result.returncode == 0,
             result.stderr.decode())
    finally:
        store.spend(token)


def g_starttoken(argv):
    m = load_lib(os.path.join(TMP, f"inproc-start-{os.getpid()}"))
    ceremony = m["ceremony"]
    a = {"boot_id": "BOOT-AAAA-0001", "pid": 4242, "start_time": 1_700_000_000_000_001}
    b = dict(a, start_time=1_700_000_000_000_002)
    emit("start tokens: equal boot_id, pid, and whole second but different microseconds are different "
         "processes", ceremony.same_process(a, b) is False and ceremony.same_process(a, dict(a)) is True)
    emit("start tokens: a different boot_id is a different process",
         ceremony.same_process(a, dict(a, boot_id="BOOT-AAAA-0002")) is False)
    try:
        first = ceremony.read_start_time(os.getpid())
        second = ceremony.read_start_time(os.getpid())
        boot = ceremony.read_boot_id()
        live_ok = type(first) is int and first == second and bool(re.fullmatch(r"[A-Za-z0-9-]{8,64}", boot))
        if sys.platform == "darwin":
            live_ok = live_ok and first % 1_000_000 != 0 and first > 1_000_000_000_000_000
        detail = (first, boot)
    except Exception as error:  # noqa: BLE001
        live_ok, detail = False, repr(error)
    emit(f"start tokens: the host reader returns this process's start time "
         f"({'microseconds' if sys.platform == 'darwin' else 'clock ticks'}) and boot id", live_ok, detail)
    try:
        own = ceremony.start_token()
        emit("start tokens: this process's own token is not stale, an altered one is",
             ceremony.is_stale(own) is False and ceremony.is_stale(dict(own, start_time=own["start_time"] + 1)))
    except Exception as error:  # noqa: BLE001
        emit("start tokens: this process's own token is not stale, an altered one is", False, repr(error))
    ok, code = refused(lambda: ceremony.read_start_time(2**22 + 12345))
    emit("start tokens: an unreadable start time raises (no coarser fallback)", ok, code)


def g_seam(argv):
    m = load_lib(os.path.join(TMP, f"inproc-seam-{os.getpid()}"))
    store = m["store"]
    os.environ.pop("LOOP_AUTHORITY_TEST", None)
    os.environ["LOOP_AUTHORITY_CRASH_AT"] = "after-push"
    store.configure_crash("recover")
    emit("seam: without LOOP_AUTHORITY_TEST=1 a crash point is not honoured", store._CRASH["point"] is None)
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    store.configure_crash("recover")
    emit("seam: with LOOP_AUTHORITY_TEST=1 a crash point is honoured", store._CRASH["point"] == "after-push")
    for label, command, point in (("an unknown point", "genesis", "after-lunch"),
                                  ("a key step beyond the ceremony's", "genesis", f"key-step-{KEY_STEPS + 1}"),
                                  ("a key step in a ceremony without keys", "revoke", "key-step-1"),
                                  ("a frame byte in a command writing no frame", "recover", "frame-byte-3"),
                                  ("a genesis step outside genesis", "rotate", "genesis-step-2"),
                                  ("recovery-after-delimiter outside recovery", "rotate",
                                   "recovery-after-delimiter"),
                                  ("frame-byte-0", "revoke", "frame-byte-0"),
                                  ("abandon-after-discard (abandonment has one sink; no such cut)", "recover",
                                   "abandon-after-discard")):
        os.environ["LOOP_AUTHORITY_CRASH_AT"] = point
        ok, code = refused(lambda command=command: store.configure_crash(command), "crash-point")
        emit(f"seam: {label} makes the writer refuse to start", ok, code)
    os.environ["LOOP_AUTHORITY_CRASH_AT"] = "recovery-after-delimiter"
    store.configure_crash("recover")
    emit("seam: recovery-after-delimiter is in the closed list for recovery",
         store._CRASH["point"] == "recovery-after-delimiter")
    emit("seam: recovery's crash points are exactly the independently frozen list",
         store.CRASH_APPLICABLE["recover"] == FROZEN_CRASH_POINTS["recover"], store.CRASH_APPLICABLE["recover"])
    emit("seam: all five commands equal the independently frozen crash inventory",
         store.CRASH_APPLICABLE == FROZEN_CRASH_POINTS, store.CRASH_APPLICABLE)
    emit("seam: every named revocation cut has its active-epoch scenario",
         set(REVOCATION_POINTS) == FROZEN_CRASH_POINTS["revoke"])
    emit("seam: every applicable verify-only revocation cut has its scenario",
         set(VERIFY_ONLY_REVOCATION_POINTS) == FROZEN_CRASH_POINTS["revoke"] -
         {"fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename"})
    emit("seam: every re-genesis transaction cut has normal and bad-signature scenarios",
         set(REGENESIS_CUTS) - {"frame-byte-first", "frame-byte-last"} ==
         FROZEN_CRASH_POINTS["regenesis"] - FROZEN_MARKER_POINTS)
    emit("seam: every recovery-prelude marker cut has rotate and re-genesis scenarios",
         set(MARKER_PRELUDE_CUTS) == FROZEN_MARKER_POINTS and all(
             set(MARKER_PRELUDE_CUTS) <= FROZEN_CRASH_POINTS[c] for c in ("rotate", "regenesis")))
    emit("seam: review_named_points exercises exactly the independently frozen command/point inventory",
         {c: set(p) for c, p in review_named_points().items()} == FROZEN_CRASH_POINTS)
    os.environ["LOOP_AUTHORITY_CRASH_AT"] = "frame-byte-500"
    store.configure_crash("revoke")
    ok, code = refused(lambda: store.check_frame_byte(500), "crash-point")
    ok2, _ = refused(lambda: store.check_frame_byte(400), "crash-point")
    ok3, code3 = refused(lambda: store.check_frame_byte(501))
    emit("seam: a frame-byte-<n> not strictly inside the frame is refused", ok and ok2 and not ok3,
         (code, code3))
    emit(f"seam: genesis and rotation have {KEY_STEPS} key steps", store.KEY_STEPS == KEY_STEPS)


def g_finish(argv):
    """A2.4 tokens against real crash states prepared by the main driver:
    minted from nothing but an issued plan, which a fresh observation of the
    files and the remote must decide again."""
    home, url, scenario = argv[0], argv[1], argv[2]
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    m = load_lib(home)
    store, tools, recover = m["store"], m["tools"], m["recover"]
    tools.pin_remote(tools.parse_remote(url, allow_test=True))
    intent_bytes = open(store.path("genesis.intent"), "rb").read()
    intent = json.loads(intent_bytes)
    store_id = intent["store_id"]
    target = {"store_id": store_id, "generation": 1}

    def observe():
        scratch = recover.Scratch()
        try:
            return recover.observe(scratch)
        finally:
            scratch.close()

    def forged(action, tip):
        """A finish plan observe() never decided, entered as issued."""
        plan = observe()
        fake = recover.Plan("genesis-pending", row=action, table=plan.table, view=plan.view, store_id=store_id,
                            target=target, active_state="absent", intent_digest=store.sha256(intent_bytes))
        fake.remote_read, fake.remote_tip = True, tip
        fake.anchor_class, fake.lineage_remote = plan.anchor_class, plan.lineage_remote
        return recover._issue(fake)

    def finish():
        """What recovery mints: the token of the plan observe() issued."""
        return recover._mint(observe())

    before = store.snapshot_digest()
    if scenario == "pre-ceremony":
        ok, code = refused(lambda: store.begin_finish(forged("complete", None)), "recovery-plan")
        emit("finish: a forged completion plan on the pre-ceremony (absent) ref mints nothing", ok, code)
        ok, code = refused(lambda: store.begin_finish(forged("complete", intent["anchor_commit"])), "recovery-plan")
        emit("finish: a forged completion plan naming a tip the remote does not show mints nothing", ok, code)
        binding = {"row": "authority-genesis", "action": "complete", "table": "test",
                   "local": store.snapshot_digest(), "remote": {"read": True, "tip": intent["anchor_commit"]},
                   "intent_digest": store.sha256(intent_bytes)}
        ok, code = refused(lambda: store.begin_finish(binding), "recovery-plan")
        emit("finish: a caller-built completion binding mints nothing (plan-only minting)", ok, code)
    elif scenario == "committed-point":
        for tip, label in ((intent["anchor_commit"], "after the commit point"),
                           (None, "naming an absent ref the remote does not show")):
            ok, code = refused(lambda tip=tip: store.begin_finish(forged("abandon", tip)), "recovery-plan")
            emit(f"finish: a forged abandonment plan {label} mints nothing", ok, code)
        plan = observe()
        token = recover._mint(plan)
        ok, code = refused(lambda: recover._mint(plan), "recovery-plan")
        emit("finish: a replayed completion plan is refused", ok, code)
        ok, code = refused(lambda: store.write_active(token, target={"store_id": "f" * 32, "generation": 1}),
                           "stage-mismatch")
        emit("finish: the active sink given another target is refused", ok, code)
        for label, call in (
            ("seal", lambda: store.seal(token, record_type="store.genesis", payload=b"x", key_dir="/x")),
            ("seal_pointer", lambda: store.seal_pointer(token, pointer=b"x", key_dir="/x")),
            ("append_frame", lambda: store.append_frame(token, store_id=store_id, data=b"x")),
            ("push_anchor", lambda: store.push_anchor(token, scratch="/x", commit="0" * 40,
                                                      ref=ANCHOR_REF)),
            ("create_key", lambda: store.create_key(token, store_id=store_id, key_dir="epoch-1-" + "0" * 16,
                                                    name="root")),
            ("write_quarantine", lambda: store.write_quarantine(token, store_id=store_id, data=b"{}")),
            ("truncate_frame", lambda: store.truncate_frame(token, store_id=store_id, offset=0)),
            ("write_cursor", lambda: store.write_cursor(token, store_id=store_id, data=b"{}")),
        ):
            ok, code = refused(call, "token-row", "token")
            emit(f"finish: a ceremony-completion token is refused on {label}", ok, code)
        store.spend(token)
        token = finish()
        cursor = os.path.join(store.store_dir(store_id), "cursor")
        with open(cursor, "wb") as handle:
            handle.write(b"{}")
        os.chmod(cursor, 0o600)
        ok, code = refused(lambda: store.write_active(token, target=target), "recovery-state")
        emit("finish: a token bound to another observed state is refused", ok, code)
        os.unlink(cursor)
        store.spend(token)
    elif scenario == "abandonable":
        token = finish()
        ok, code = refused(lambda: store.write_active(token, target=target), "token-row")
        emit("finish: an abandonment token is refused on the active sink", ok, code)
        ok, code = refused(lambda: store.archive_store(token, store_id=store_id), "token-row")
        emit("finish: an abandonment token is refused on the archive sink", ok, code)
        emit("finish: abandonment has no discard sink -- removing the intent is all it does",
             not hasattr(store, "discard_store_dir")
             and store.FINISH_SINKS["abandon"] == ("genesis-intent-remove", "regenesis-intent-remove"))
        store.spend(token)
    elif scenario == "keysinks":
        token = store.begin("authority-genesis", PRINCIPAL)
        new_id, key_dir = "9" * 32, "epoch-1-" + "9" * 16
        store.bind_keys(token, store_id=new_id, epoch=1, key_dir=key_dir,
                        active_target={"store_id": new_id, "generation": 1}, intent_path="genesis.intent")
        store.create_store_dir(token, store_id=new_id, key_dir=key_dir)
        ok, code = refused(lambda: store.create_key(token, store_id=new_id, key_dir="epoch-1-" + "8" * 16,
                                                    name="root"), "stage-mismatch")
        emit("key sinks: with a valid same-row token, another key_dir is refused", ok, code)
        store.create_key(token, store_id=new_id, key_dir=key_dir, name="root")
        ok, code = refused(lambda: store.create_key(token, store_id=new_id, key_dir=key_dir, name="root"),
                           "exists")
        emit("key sinks: with a valid same-row token, an existing key file is refused", ok, code)
        ok, code = refused(lambda: store.certify_key(token, store_id=new_id, key_dir="epoch-1-" + "8" * 16,
                                                     name="store.genesis"), "stage-mismatch")
        emit("key sinks: certification into another key_dir is refused", ok, code)
        ok, code = refused(lambda: store.create_key(token, store_id=new_id, key_dir=key_dir,
                                                    name="segment_reset"), "stage-mismatch")
        emit("key sinks: no key can be created for a nested-only part", ok, code)
        ok, code = refused(lambda: store.write_active(token, target={"store_id": new_id, "generation": 1}),
                           "protocol-order")
        emit("key sinks: the active sink before the readback is refused", ok, code)
        store.spend(token)
    after = store.snapshot_digest()
    if scenario != "keysinks":
        emit(f"finish ({scenario}): no refused sink mutated the store", before == after)
    tools.cleanup()


def g_tzcommit(argv):
    """Rebuild an anchored commit from its anchor.json in a fresh scratch
    repository under the TZ this process was started with."""
    home, url, anchor_hex, expected = argv[0], argv[1], argv[2], argv[3]
    m = load_lib(home)
    tools, anchor = m["tools"], m["anchor"]
    tools.pin_remote(tools.parse_remote(url, allow_test=True))
    scratch = tools.new_scratch_repo()
    commit = anchor.build_objects(scratch, bytes.fromhex(anchor_hex), None)
    emit(f"anchor objects: under TZ={os.environ.get('TZ')} the rebuilt commit id is the anchored one",
         commit == expected, commit)
    tools.cleanup()


INPROC = {"vectors": g_vectors, "keys": g_keys, "transport": g_transport,
          "starttoken": g_starttoken, "seam": g_seam, "finish": g_finish, "tzcommit": g_tzcommit}


def inproc(group, *args, env=None):
    """Run an in-process group as its own interpreter; returns its lines."""
    full = {"PATH": os.environ.get("PATH", ":".join(BIN_DIRS)), "LANG": "C", "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1", "HOME": os.path.join(TMP, "inproc-home"),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    full.update(env or {})
    result = subprocess.run([sys.executable, __file__, "inproc", group, SCRIPTS, LIB, TMP, *args],
                            capture_output=True, env=full, timeout=900)
    items = []
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split("\t")
        if parts[0] == "ok":
            items.append((parts[1], True, ""))
        elif parts[0] == "not ok":
            items.append((parts[1], False, parts[2] if len(parts) > 2 else ""))
    if result.returncode != 0:
        items.append((f"in-process group {group} exits 0", False,
                      result.stderr.decode("utf-8", "replace")[-1500:]))
    return items
PY

cat >> "$TMP_ROOT/at.py" <<'PY'
# ===========================================================================
# Main sections (subprocess writer, pty ceremonies, independent verifier)
# ===========================================================================

def crashed(case, point, *args, expect=137):
    """Run a ceremony with LOOP_AUTHORITY_CRASH_AT=point; returns the Res."""
    result = case.ceremony(*args, env={"LOOP_AUTHORITY_CRASH_AT": point})
    if result.rc != expect:
        raise RuntimeError(f"{case.label}: {args} at {point} exited {result.rc}, expected {expect}: {result}")
    return result


def frame_of_intent(intent):
    return base64.b64decode(intent["frame_b64"])


SAMPLE_ATTEMPTS = 8


def sampled_torn_crash(requested, run, tries=SAMPLE_ATTEMPTS):
    """run(n, attempt) returns a fresh (case, result, intent) for byte n.
    Credit only a real crash whose own intent frame has at least n + 2
    bytes. Discard shorter runs without classifying or recovering them;
    aim the next cut at their own last torn byte. No per-attempt checks.
    Unlike matrix numeric ids, default samples may retarget after a miss.
    """
    n, lengths = requested, []
    for attempt in range(tries):
        case, result, intent = run(n, attempt)
        if result.rc == 137 and intent is not None:
            length = len(frame_of_intent(intent))
            if length >= n + 2:
                return case, result, intent, n
        elif result.rc == 11 and intent is None and MATRIX_PRINCIPAL_READ.fullmatch(result.out.strip()):
            continue
        else:
            outside = MATRIX_OUTSIDE.search(result.out) if result.rc == 4 and intent is None else None
            if outside is None or int(outside.group(1)) != n or int(outside.group(2)) > n:
                raise RuntimeError(f"{case.label}: sampled frame-byte-{n} exited {result.rc}: {result}")
            # The seam refuses before publishing intent when n is outside
            # the frame; its diagnostic gives that run's actual frame size.
            length = int(outside.group(2))
        lengths.append(length)
        n = max(1, min(n, length - 2))
    raise RuntimeError(f"sampled frame-byte-{requested}: retry bound exhausted after {tries} runs; "
                       f"no sample credited (discarded frame lengths: {lengths})")


def sampled_case_crash(base, args, n, intent_kind="intent"):
    """Fork pristine HOME for every attempt; discarded runs never mutate
    the base or get recovered (an unterminated run could replay a push)."""
    def run(cut, attempt):
        case = base.fork(f"{base.label}-sample-{n}-{attempt}")
        result = case.ceremony(*args, env={"LOOP_AUTHORITY_CRASH_AT": f"frame-byte-{cut}"})
        if intent_kind == "regenesis":
            path = case.auth("regenesis.intent")
            intent = json.loads(case.read(path)) if os.path.exists(path) else None
        else:
            intent = case.intent()
        return case, result, intent
    return sampled_torn_crash(n, run)


def sampled_genesis_crash(label, n):
    def run(cut, attempt):
        case = Case(f"{label}-sample-{attempt}")
        result = case.ceremony("genesis", "--remote", case.url,
                               env={"LOOP_AUTHORITY_CRASH_AT": f"frame-byte-{cut}"})
        return case, result, case.genesis_intent()
    return sampled_torn_crash(n, run)


def last_byte_crash(case, args, probe, intent_of, tries=8):
    """Crash `ceremony *args` after every byte but the frame's final newline.
    The frame's length follows the ceremony process's pid digits (its start
    token), which can change between a probe and the run (pids wrap in a
    busy parallel run), so check the crash landed on the last byte; after a
    miss, recover the case to its pre-crash state and try again."""
    for _attempt in range(tries):
        size = probe()
        result = case.ceremony(*args, env={"LOOP_AUTHORITY_CRASH_AT": f"frame-byte-{size - 1}"})
        intent = intent_of()
        if result.rc == 137 and intent is not None and len(frame_of_intent(intent)) == size:
            return result, intent
        case.writer("recover")
    raise RuntimeError(f"{case.label}: no crash landed on the last byte of {args}")


def genesis_last_byte(label, tries=8):
    """A fresh case whose genesis crashed after every byte but frame 1's
    final newline (a fresh case per attempt; see last_byte_crash)."""
    for attempt in range(tries):
        size, _header = genesis_frame_size(f"{label}-size-{attempt}")
        case = Case(f"{label}-{attempt}")
        result = case.ceremony("genesis", "--remote", case.url,
                               env={"LOOP_AUTHORITY_CRASH_AT": f"frame-byte-{size - 1}"})
        intent = case.genesis_intent()
        if result.rc == 137 and intent is not None and len(frame_of_intent(intent)) == size:
            return case, result, intent
    raise RuntimeError(f"{label}: no genesis crash landed on the last byte")


def s_inproc_pure():
    for group in ("vectors", "keys", "starttoken", "seam"):
        for item in inproc(group):
            emit(*item)
    home = os.path.join(TMP, "transport-home")
    os.makedirs(home, exist_ok=True)
    for item in inproc("transport", home):
        emit(*item)


def s_genesis_basic():
    def job(checks):
        case = Case("basic")
        result = case.genesis()
        checks("genesis: the ceremony succeeds through a pty with the typed challenge", result.rc == 0
               and result.json.get("result") == "genesis", result)
        checks("genesis: the ceremony printed the envelope and a 12-hex challenge and called itself an "
               "operator-TTY session, not human approval",
               re.search(r"challenge: [0-9a-f]{12}\n", result.out) is not None and "envelope: {" in result.out
               and "not human approval" in result.out, result.out[:300])
        tip = case.tip()
        checks("genesis: an actual anchor commit exists on the remote ref", tip is not None
               and git("--git-dir", case.remote, "cat-file", "-t", tip).stdout.strip() == b"commit")
        anchor_json = case.anchor_json_at(tip)
        pointer = json.loads(anchor_json)
        checks("genesis: the anchor commit is at seq 1, generation 1, with no parent and no prev_generation",
               pointer["active"]["seq"] == 1 and pointer["active"]["generation"] == 1
               and case.parent_of(tip) is None and pointer["prev_generation"] is None, pointer)
        raw = case.cat(tip).decode()
        checks("genesis: the commit is the deterministic one (identity, '1 +0000' dates, message)",
               f"author {IDENTITY} 1 +0000" in raw and f"committer {IDENTITY} 1 +0000" in raw
               and f"anchor {pointer['active']['store_id']} g1 s1" in raw
               and expected_commit(anchor_json, None) == tip, raw)
        status = case.status()
        checks("genesis: status reports a committed, test-only store with no current authorization",
               status.json.get("state") == "committed" and status.json.get("test_only") is True
               and status.json.get("anchor_class") == "test"
               and status.json.get("current_authorization") is False
               and status.json.get("authorizing_state") is True, status)
        case.agree(checks, "genesis committed", "committed")
        independent = case.verifier()
        checks("verifier: a test-anchored store gives no current authorization",
               independent.json.get("test_only") is True and independent.json.get("current_authorization")
               is False, independent)
        store = case.store_dir()
        key_dirs = os.listdir(os.path.join(store, "keys"))
        kdir = os.path.join(store, "keys", key_dirs[0])
        names = set(os.listdir(kdir))
        expected = {"root", "root.pub"} | {f"{t}{s}" for t in TYPES for s in ("", ".pub", "-cert.pub")}
        checks("genesis: one key directory holds the root and one certified subkey per type",
               len(key_dirs) == 1 and names == expected, sorted(names ^ expected))
        good = 0
        for kind in TYPES:
            listing = ssh_keygen("-L", "-f", os.path.join(kdir, f"{kind}-cert.pub")).stdout.decode()
            if (f'Key ID: "{kind}@e1"' in listing and re.search(rf"Principals:\s*\n\s*{re.escape(kind)}\s*\n",
                                                               listing) and "Valid: forever" in listing):
                good += 1
        checks("genesis: the host ssh-keygen made every per-type certificate (identity <type>@e1, "
               "principal <type>, valid forever)", good == len(TYPES), good)
        checks("genesis: no key exists for segment reset, mechanism closure, or release acceptance",
               not any(n.startswith(("segment", "mechanism", "release")) for n in names))
        modes = {stat.S_IMODE(os.lstat(os.path.join(root, n)).st_mode)
                 for root, _d, files in os.walk(case.auth()) for n in files}
        dmodes = {stat.S_IMODE(os.lstat(os.path.join(root, n)).st_mode)
                  for root, dirs, _f in os.walk(case.auth()) for n in dirs}
        checks("layout: every authority file is 0600 and every directory 0700", modes == {0o600}
               and dmodes == {0o700} and stat.S_IMODE(os.lstat(case.auth()).st_mode) == 0o700,
               (modes, dmodes))
        for zone in ("UTC", "Asia/Shanghai"):
            for item in inproc("tzcommit", case.home, case.url, anchor_json.hex(), tip,
                               env={"TZ": zone, "LOOP_AUTHORITY_TEST": "1"}):
                checks(*item)
        second = case.genesis()
        checks("genesis: refused when active exists", second.rc == 4 and "active exists" in second.out,
               second)
    serial("genesis basics", job)


# --- the write protocol and A1.2 -------------------------------------------

def j_five_steps(point):
    def job(checks):
        case = committed_case(f"five-{point}")
        before_tip = case.tip()
        base_log = case.read(case.log_path())
        crashed(case, point, "rotate")
        intent = case.intent()
        log = case.read(case.log_path())
        label = f"write protocol, crash {point}"
        if point == "after-intent-fsync":
            checks(f"{label}: step 1 durable -- an intent for seq 2 at the end of the log, nothing else",
                   intent is not None and intent["seq"] == 2 and intent["offset"] == len(base_log)
                   and log == base_log and case.tip() == before_tip, intent)
            case.agree(checks, label, "needs-recovery", "recovery-tidy")
            final_seq = 1
        elif point == "after-frame-fsync":
            checks(f"{label}: step 2 durable -- frame 2 appended exactly, remote not advanced",
                   intent is not None and log == base_log + frame_of_intent(intent)
                   and case.tip() == before_tip)
            case.agree(checks, label, "pending", "anchor-replay-forward")
            final_seq = 2
        elif point in ("after-push", "after-readback"):
            checks(f"{label}: step 3 durable -- the remote names the intent's exact commit, whose parent "
                   "is the previous anchor", intent is not None and case.tip() == intent["anchor_commit"]
                   and case.parent_of(case.tip()) == before_tip)
            case.agree(checks, label, "needs-recovery", "recovery-tidy")
            final_seq = 2
        else:
            checks(f"{label}: step 5 -- the intent is removed; only the cursor hint is stale",
                   intent is None and case.tip() != before_tip)
            status = case.status()
            checks(f"{label}: a stale cursor alone is tidied and never decides anything",
                   status.json.get("state") == "committed" and status.json.get("row") == "recovery-tidy"
                   and status.json.get("authorizing_state") is True, status)
            final_seq = 2
        stored = intent["anchor_commit"] if intent else None
        result = case.writer("recover")
        checks(f"{label}: recovery ends committed at seq {final_seq}", result.rc == 0
               and result.json.get("state") == "committed" and result.json.get("seq") == final_seq
               and case.intent() is None, result)
        if point == "after-frame-fsync":
            checks(f"{label}: replay-forward pushed the stored commit (same object id)", case.tip() == stored)
        cursor = json.loads(case.read(os.path.join(case.store_dir(), "cursor")))
        checks(f"{label}: the cursor is reset to the committed pointer", cursor.get("seq") == final_seq
               and cursor.get("anchor_commit") == case.tip(), cursor)
        case.agree(checks, f"{label}, recovered", "committed")
        if point == "after-intent-fsync":
            status = case.status()
            checks(f"{label}: the staged key directory stays unpublished",
                   len(status.json.get("unpublished", {}).get("key_dirs", [])) == 1, status)
    return job


def j_row(name):
    def job(checks):
        if name == "rollback-one":
            case = committed_case(name, rotate=True)
            case.set_tip(case.parent_of(case.tip()))
            case.agree(checks, "A1.2 R = ptr(L - 1) without an intent (remote rolled back one step)",
                       "quarantined")
            result = case.writer("recover")
            checks("A1.2 rollback-one: recovery writes the quarantine marker", result.json.get("state") ==
                   "quarantined" and os.path.exists(os.path.join(case.store_dir(), "quarantine")), result)
            return
        if name == "fork":
            case = committed_case(name, rotate=True)
            lineage = Lineage(case)
            forged = dict(lineage.ptr(2), record_digest=D({"forked": True}))
            anchor_json = lineage.pointer(forged)
            remote_commit(case, anchor_json, case.parent_of(case.tip()))
            writer, _v = case.agree(checks, "A1.2 same-sequence fork (validly signed)", "quarantined")
            checks("A1.2 fork: the table row is the same-sequence fork", "fork" in writer.json.get("table", ""),
                   writer)
            return
        if name == "log-rollback":
            case = committed_case(name, rotate=True)
            lineage = Lineage(case)
            case.write(case.log_path(), lineage.data[:lineage.frames[0]["end"]])
            case.agree(checks, "A1.2 R.seq > L (the log rolled back)", "quarantined")
            return
        if name == "remote-two-back":
            case = committed_case(name, rotate=True, revoke_epoch=1)
            case.set_tip(case.parent_of(case.parent_of(case.tip())))
            case.agree(checks, "A1.2 R.seq < L - 1 (the remote rolled back two steps)", "quarantined")
            return
        if name == "stray-intent":
            case = committed_case(name, rotate=True)
            lineage = Lineage(case)
            frame_bytes, digest, _payload = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"),
                                                          seq=5, prev=D({"p": 1}))
            active = dict(lineage.ptr(2), seq=5, record_digest=digest)
            anchor_json = lineage.pointer(active)
            data = forge_intent(lineage, frame_bytes, 5, len(lineage.data), anchor_json, case.tip())
            case.write(os.path.join(case.store_dir(), "intent"), data)
            writer, _v = case.agree(checks, "A1.2 an intent naming a sequence other than L or L + 1",
                                    "quarantined")
            checks("A1.2 stray intent: named as an intent no protocol step leaves",
                   "stray intent" in writer.json.get("table", ""), writer)
            return
        if name == "garbage-after":
            case = committed_case(name)
            crashed(case, "after-intent-fsync", "rotate")
            case.write(case.log_path(), case.read(case.log_path()) + b"garbage, not a frame prefix")
            case.agree(checks, "A1.2 an intent for L + 1 with bytes after L that are not torn or "
                       "unterminated", "quarantined")
            return
        if name == "foreign":
            case = committed_case(name)
            other = committed_case(name + "-other")
            git("--git-dir", case.remote, "fetch", "-q", other.remote, f"{ANCHOR_REF}:refs/foreign")
            case.set_tip(other.tip())
            case.agree(checks, "A1.2 R names another store_id (a foreign store)", "quarantined")
            return
        if name == "unreachable":
            case = committed_case(name)
            moved = case.remote + ".away"
            os.rename(case.remote, moved)
            writer, independent = case.agree(checks, "A1.2 remote unreachable", "pending")
            checks("A1.2 unreachable: no current authorization reported by status and the verifier",
                   writer.json.get("authorizing_state") is False and independent.json.get("authorizing_state")
                   is False and case.status().json.get("current_authorization") is False)
            result = case.writer("recover")
            checks("A1.2 unreachable: recovery leaves the store pending with no mutation",
                   result.rc == 5 and result.json.get("state") == "pending", result)
            os.rename(moved, case.remote)
            case.agree(checks, "A1.2 remote reachable again", "committed")
            return
        if name == "absent-ref":
            case = committed_case(name)
            case.set_tip(None)
            case.agree(checks, "A2.3 once active exists, an absent ref is quarantine", "quarantined")
            return
        if name == "cursor-only":
            case = committed_case(name)
            path = os.path.join(case.store_dir(), "cursor")
            case.write(path, canon({"store_id": case.active()["store_id"], "seq": 9,
                                    "record_digest": D({"c": 1}), "anchor_commit": "0" * 40}))
            status = case.status()
            checks("A1.6 cursor-only disagreement: committed, tidy, authorization unchanged",
                   status.json.get("state") == "committed" and status.json.get("row") == "recovery-tidy"
                   and status.json.get("authorizing_state") is True, status)
            case.writer("recover")
            cursor = json.loads(case.read(path))
            checks("A1.6 cursor-only disagreement: tidied", cursor.get("seq") == 1
                   and cursor.get("anchor_commit") == case.tip(), cursor)
            return
        raise AssertionError(name)
    return job


def j_byte_cuts(checks):
    """A1.6: crashes inside the frame write of an epoch revocation (L = 2):
    torn cuts truncate back to L; the last-byte cut (remote old) is
    completed and replayed; every cut is classified by the real tail
    classifier, and real crash states equal the intent's prefix."""
    case = committed_case("byte-cuts", rotate=True)
    probe = case.fork("byte-cuts-probe")
    crashed(probe, "after-intent-fsync", "revoke", "--epoch", "1")
    frame_bytes = frame_of_intent(probe.intent())
    size = len(frame_bytes)
    header = frame_bytes.index(b"\n") + 1
    for item in inproc("tailcuts", probe.home, probe.url):
        checks(*item)
    # Seven planned samples; the helper credits only an actual torn prefix,
    # retargeting discarded runs without adding checks or changing this count.
    samples = sorted({1, 2, header - 1, header, header + 1, size // 2, size - 3})
    base_log = case.read(case.log_path())
    for n in samples:
        before_tip = case.tip()
        case, _result, intent, n = sampled_case_crash(case, ("revoke", "--epoch", "1"), n)
        written = case.read(case.log_path())[len(base_log):]
        checks(f"A1.6 frame-byte-{n}: exactly the first {n} bytes of the intent's frame are on disk",
               written == frame_of_intent(intent)[:n] and case.tip() == before_tip)
        writer, _v = case.agree(checks, f"A1.6 frame-byte-{n} (torn)", "needs-recovery",
                                "torn-frame-truncation")
        checks(f"A1.6 frame-byte-{n}: no authorization while torn", writer.json.get("authorizing_state") is False)
        result = case.writer("recover")
        checks(f"A1.6 frame-byte-{n}: truncated to the intent's offset and tidied, still committed at L",
               result.json.get("state") == "committed" and case.read(case.log_path()) == base_log
               and case.intent() is None and result.json.get("seq") == 2, result)
    # the last-byte crash, remote old: delimiter completion + replay-forward
    probes = itertools.count()

    def probe_size():
        other = case.fork(f"byte-cuts-probe-{next(probes)}")
        crashed(other, "after-intent-fsync", "revoke", "--epoch", "1")
        return len(frame_of_intent(other.intent()))

    result, intent = last_byte_crash(case, ("revoke", "--epoch", "1"), probe_size, case.intent)
    full = frame_of_intent(intent)
    checks("A1.6 last-byte crash: every byte but the final newline is on disk",
           result.rc == 137 and case.read(case.log_path()) == base_log + full[:-1], result)
    writer, _v = case.agree(checks, "A1.6 last-byte crash, remote old", "pending", "anchor-replay-forward")
    checks("A1.6 last-byte crash: the table row is unterminated, remote old",
           "unterminated, remote old" in writer.json.get("table", ""), writer)
    recovered = case.writer("recover")
    checks("A1.6 last-byte crash, remote old: delimiter completed and anchor replayed (compound)",
           recovered.json.get("state") == "committed" and recovered.json.get("seq") == 3
           and case.read(case.log_path()) == base_log + full and case.tip() == intent["anchor_commit"],
           recovered)


def j_last_byte_remote_new(checks):
    case = committed_case("last-byte-remote-new", rotate=True)
    probes = itertools.count()

    def probe_size():
        probe = case.fork(f"last-byte-probe-{next(probes)}")
        crashed(probe, "after-intent-fsync", "revoke", "--epoch", "1")
        return len(frame_of_intent(probe.intent()))

    _result, intent = last_byte_crash(case, ("revoke", "--epoch", "1"), probe_size, case.intent)
    anchor_json = intent["anchor_json"].encode()
    oid = remote_commit(case, anchor_json, intent["expected_parent"])
    checks("A1.6 remote-new fixture: the test builds exactly the intent's commit", oid == intent["anchor_commit"])
    writer, _v = case.agree(checks, "A1.6 last-byte crash, remote new", "quarantined")
    checks("A1.6 last-byte crash, remote new: named as no protocol step produces it",
           "remote new" in writer.json.get("table", ""), writer)


def j_stale_intent(checks):
    case = committed_case("stale-intent", rotate=True)
    crashed(case, "after-push", "revoke", "--epoch", "1")
    intent = case.intent()
    for field, value in (("length", intent["length"] + 1), ("digest", D({"stale": 1}))):
        fork = case.fork(f"stale-{field}")
        fork.write(os.path.join(fork.store_dir(), "intent"), canon(dict(intent, **{field: value})))
        fork.agree(checks, f"A1.6 an intent for L whose {field} differs from frame L", "quarantined")
        result = fork.writer("recover")
        checks(f"A1.6 stale intent ({field}): quarantined, never tidied",
               result.json.get("state") == "quarantined" and fork.intent() is not None, result)


def s_protocol():
    jobs = [(f"five steps {p}", j_five_steps(p)) for p in
            ("after-intent-fsync", "after-frame-fsync", "after-push", "after-readback", "after-intent-remove")]
    jobs += [(f"row {n}", j_row(n)) for n in
             ("rollback-one", "fork", "log-rollback", "remote-two-back", "stray-intent", "garbage-after",
              "foreign", "unreachable", "absent-ref", "cursor-only")]
    jobs += [("byte cuts", j_byte_cuts), ("remote new", j_last_byte_remote_new), ("stale intent", j_stale_intent)]
    parallel(jobs)


def frame_prefix_classes(recover, intent, frame1):
    """The real offline classifier's class for every prefix 1 .. N - 1 of
    the intent's N-byte frame: A2.3's frame-1 classes for a frame 1, else
    A1.6's tail classes after the intent's L = seq - 1 complete frames."""
    frame_bytes = base64.b64decode(intent["frame_b64"])
    if frame1:
        return [recover.classify_frame1_bytes(frame_bytes[:n], frame_bytes) for n in range(1, len(frame_bytes))]
    return [recover.classify_tail(frame_bytes[:n], None, intent["offset"], intent["seq"] - 1, intent, frame_bytes)
            for n in range(1, len(frame_bytes))]


def torn_then_unterminated(kinds):
    """The classes prefixes 1 .. N - 1 must have: torn, then unterminated."""
    return bool(kinds) and kinds[:-1] == ["torn"] * (len(kinds) - 1) and kinds[-1] == "unterminated"


def g_tailcuts(argv):
    """The real tail classifier over every byte cut of a real frame."""
    home, url = argv[0], argv[1]
    m = load_lib(home)
    recover, store = m["recover"], m["store"]
    active = json.loads(open(store.path("active"), "rb").read())
    intent = json.loads(open(os.path.join(store.store_dir(active["store_id"]), "intent"), "rb").read())
    kinds = frame_prefix_classes(recover, intent, False)
    emit(f"A1.6 every byte boundary: all {len(kinds)} cuts of a real revocation frame are torn "
         "except the last-byte cut, which is unterminated", torn_then_unterminated(kinds),
         [k for k in kinds if k != "torn"][:3])


INPROC["tailcuts"] = g_tailcuts


def g_anchorchecks(argv):
    """Anchor objects that differ in exactly one respect are refused before
    the frame (check_objects), and a readback that matches the ref id but
    not the content or signature fails."""
    home, url = argv[0], argv[1]
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    m = load_lib(home)
    tools, anchor, store, records = m["tools"], m["anchor"], m["store"], m["records"]
    tools.pin_remote(tools.parse_remote(url, allow_test=True))
    scratch = tools.new_scratch_repo()
    remote_path = url[len("file://"):]
    tip = git("--git-dir", remote_path, "rev-parse", ANCHOR_REF).stdout.decode().strip()
    anchor_json = anchor_json_of(remote_path, tip)
    fetched = anchor.fetch(scratch, url)
    emit("anchor objects: the anchored commit passes the content checks",
         refused(lambda: anchor.check_objects(scratch, fetched, anchor_json, None))[1] == "not refused")

    def build(parent, extra_entry=False, blob=None):
        data = anchor_json if blob is None else blob
        blob_id = git("--git-dir", scratch, "hash-object", "-w", "--stdin", stdin=data).stdout.decode().strip()
        lines = f"100644 blob {blob_id}\tanchor.json\n"
        if extra_entry:
            other = git("--git-dir", scratch, "hash-object", "-w", "--stdin", stdin=b"x").stdout.decode().strip()
            lines += f"100644 blob {other}\textra\n"
        tree = git("--git-dir", scratch, "mktree", stdin=lines.encode()).stdout.decode().strip()
        date = "@1 +0000"
        extra = {"GIT_AUTHOR_NAME": "olddonkey-loop", "GIT_AUTHOR_EMAIL": "anchor@olddonkey-loop.invalid",
                 "GIT_COMMITTER_NAME": "olddonkey-loop", "GIT_COMMITTER_EMAIL": "anchor@olddonkey-loop.invalid",
                 "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
        active = json.loads(anchor_json)["active"]
        args = ["--git-dir", scratch, "commit-tree", tree] + (["-p", parent] if parent else [])
        args += ["-m", f"anchor {active['store_id']} g1 s1"]
        return git(*args, extra=extra).stdout.decode().strip()

    variants = {
        "a wrong parent": (build(fetched), None),
        "an extra tree entry": (build(None, extra_entry=True), None),
        "a blob differing from anchor_json": (build(None, blob=anchor_json.replace(b'"seq":1', b'"seq":2')), None),
    }
    for label, (commit, parent) in variants.items():
        ok, code = refused(lambda commit=commit, parent=parent:
                           anchor.check_objects(scratch, commit, anchor_json, parent))
        emit(f"anchor objects: a commit with {label} (every other byte identical) is refused before the frame",
             ok, code)
    token = store.begin("authority-genesis", PRINCIPAL)
    active = json.loads(open(store.path("active"), "rb").read())
    data = open(store.log_path(store.store_dir(active["store_id"])), "rb").read()
    payload = json.loads(parse_frames(data)[0][0]["content"])["payload"]
    pointer_root = payload["body"]["root_pub"]
    altered = anchor_json.replace(b'"sig":"-----BEGIN SSH SIGNATURE-----\\n', b'"sig":"-----BEGIN SSH SIGNATURE-----\\nAAAA', 1)
    ok, code = refused(lambda: store.readback(token, scratch=scratch, commit=tip, anchor_json=altered,
                                              expected_parent=None, root_pub=pointer_root), "readback")
    emit("anchor readback: the ref id matches but anchor.json differs -- refused", ok, code)
    bad_sig = json.loads(anchor_json)
    sig = bad_sig["sig"]
    lines = sig.split("\n")
    lines[3] = ("B" if lines[3][0] != "B" else "C") + lines[3][1:]
    bad_sig["sig"] = "\n".join(lines)
    bad_bytes = canon(bad_sig)
    bad_commit = build(None, blob=bad_bytes)
    git("--git-dir", scratch, "push", "-q", "--force", remote_path, f"{bad_commit}:{ANCHOR_REF}")
    ok, code = refused(lambda: store.readback(token, scratch=tools.new_scratch_repo(), commit=bad_commit,
                                              anchor_json=bad_bytes, expected_parent=None,
                                              root_pub=pointer_root), "readback")
    emit("anchor readback: the ref id matches and the content is equal but the signature is bad -- refused",
         ok, code)
    git("--git-dir", scratch, "push", "-q", "--force", remote_path, f"{tip}:{ANCHOR_REF}")
    # non-fast-forward: a push whose parent is not the remote tip is refused
    token2 = store.begin("epoch-rotation", PRINCIPAL)
    store.bind_keys(token2, store_id=active["store_id"], epoch=2, key_dir="epoch-2-" + "a" * 16,
                    active_target=None, intent_path=None)
    store.bind_record(token2, store_id=active["store_id"], record_type="epoch.rotated",
                      payload_digest=D({"p": 1}), key_id="SHA256:" + "A" * 43, signing_key_dir="/x",
                      pointer_key_dir="/y")
    store.bind_frame(token2, frame_digest=D({"f": 1}), record_digest=D({"r": 1}), pointer_digest=D({"q": 1}))
    unrelated = bad_commit
    store.bind_anchor(token2, anchor_json_digest=D({"a": 1}), anchor_commit=unrelated, ref=ANCHOR_REF,
                      intent_digest=D({"i": 1}), expected_parent="1" * 40, offset=0)
    token2.flags.update({"intent", "frame"})
    head = store.child(token2, "authority-head-advance")
    before = git("--git-dir", remote_path, "rev-parse", ANCHOR_REF).stdout
    ok, code = refused(lambda: store.push_anchor(head, scratch=scratch, commit=unrelated, ref=ANCHOR_REF),
                       "non-fast-forward")
    emit("anchor push: a push from a parent that is not the remote tip is refused (non-fast-forward)", ok, code)
    token3 = store.begin("epoch-rotation", PRINCIPAL)
    store.bind_keys(token3, store_id=active["store_id"], epoch=2, key_dir="epoch-2-" + "b" * 16,
                    active_target=None, intent_path=None)
    store.bind_record(token3, store_id=active["store_id"], record_type="epoch.rotated",
                      payload_digest=D({"p": 2}), key_id="SHA256:" + "A" * 43, signing_key_dir="/x",
                      pointer_key_dir="/y")
    store.bind_frame(token3, frame_digest=D({"f": 2}), record_digest=D({"r": 2}), pointer_digest=D({"q": 2}))
    store.bind_anchor(token3, anchor_json_digest=D({"a": 2}), anchor_commit=bad_commit, ref=ANCHOR_REF,
                      intent_digest=D({"i": 2}), expected_parent=tip, offset=0)
    token3.flags.update({"intent", "frame"})
    head3 = store.child(token3, "authority-head-advance")
    ok, code = refused(lambda: store.push_anchor(head3, scratch=scratch, commit=bad_commit, ref=ANCHOR_REF),
                       "pending")
    emit("anchor push: git itself refuses a commit that does not fast-forward the tip", ok, code)
    emit("anchor push: the refused pushes left the remote ref unchanged",
         git("--git-dir", remote_path, "rev-parse", ANCHOR_REF).stdout == before)
    tools.cleanup()


def anchor_json_of(remote_path, oid):
    raw = git("--git-dir", remote_path, "cat-file", "-p", oid).stdout
    tree = re.search(rb"^tree ([0-9a-f]{40})", raw, re.M).group(1).decode()
    listing = git("--git-dir", remote_path, "cat-file", "-p", tree).stdout
    blob = re.search(rb"blob ([0-9a-f]{40})\tanchor\.json", listing).group(1).decode()
    return git("--git-dir", remote_path, "cat-file", "-p", blob).stdout


INPROC["anchorchecks"] = g_anchorchecks


def j_anchor_objects(checks):
    case = committed_case("anchor-objects")
    for item in inproc("anchorchecks", case.home, case.url):
        checks(*item)
    anchor_json = case.anchor_json_at(case.tip())
    tip = case.tip()
    lineage = Lineage(case)
    variants = (("an extra tree entry", {"extra_entry": True}),
                ("a blob differing from its pointer", {"blob_data": anchor_json.replace(b"}", b" }", 1)}))
    for label, options in variants:
        remote_commit(case, anchor_json, None, **options)
        case.agree(checks, f"anchor: a remote commit with {label} is quarantined on recovery", "quarantined")
    remote_commit(case, anchor_json, tip)
    case.agree(checks, "anchor: a remote commit with the wrong parent is quarantined on recovery", "quarantined")
    case.set_tip(tip)
    case.agree(checks, "anchor: the genuine commit restored", "committed")
    crash_case = committed_case("anchor-intent")
    crashed(crash_case, "after-frame-fsync", "rotate")
    intent = crash_case.intent()
    fork = crash_case.fork("anchor-intent-parent")
    fork.write(os.path.join(fork.store_dir(), "intent"),
               canon(dict(intent, anchor_commit=expected_commit(intent["anchor_json"].encode(), None))))
    fork.agree(checks, "anchor: an intent whose anchor_commit has another parent is quarantined on recovery",
               "quarantined")
    fork = crash_case.fork("anchor-intent-missing")
    fork.write(os.path.join(fork.store_dir(), "intent"),
               canon({k: v for k, v in intent.items() if k != "anchor_json"}))
    fork.agree(checks, "anchor: an intent missing anchor_json is quarantined", "quarantined")
    fork = crash_case.fork("anchor-intent-other-seq")
    other = json.loads(intent["anchor_json"])
    other["active"]["seq"] = 7
    fork.write(os.path.join(fork.store_dir(), "intent"), canon(dict(intent, anchor_json=canon(other).decode())))
    fork.agree(checks, "anchor: an intent whose anchor_json names another sequence is quarantined", "quarantined")
    del lineage


# --- epochs -----------------------------------------------------------------

def j_epochs(checks):
    case = committed_case("epochs", rotate=True)
    status = case.status()
    checks("epochs: rotation moves the old root to verify-only", status.json.get("epochs") ==
           {"1": "verify-only", "2": "active"}, status)
    kdir = Lineage(case).keydir(2)
    good = sum(1 for kind in TYPES
               if f'Key ID: "{kind}@e2"' in ssh_keygen("-L", "-f", os.path.join(kdir, f"{kind}-cert.pub")).stdout.decode())
    checks("epochs: rotation made one certificate per type with the host ssh-keygen (identity <type>@e2)",
           good == len(TYPES), good)
    fork = case.fork("epochs-old-seal")
    lineage = Lineage(fork)
    frame_bytes, _digest, _payload = lineage.forge("epoch.revoked", lineage.revoke_body(2, "active"), epoch=1)
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    fork.agree(checks, "epochs: a record sealed with the verify-only epoch is refused (quarantine)",
               "quarantined")
    fork = case.fork("epochs-unpinned-root")
    lineage = Lineage(fork)
    rogue = os.path.join(fork.dir, "rogue")
    os.mkdir(rogue)
    ssh_keygen("-q", "-t", "ed25519", "-N", "", "-C", "r", "-f", os.path.join(rogue, "root"))
    ssh_keygen("-q", "-t", "ed25519", "-N", "", "-C", "s", "-f", os.path.join(rogue, "epoch.revoked"))
    ssh_keygen("-q", "-s", os.path.join(rogue, "root"), "-I", "epoch.revoked@e2", "-n", "epoch.revoked",
               "-V", "always:forever", os.path.join(rogue, "epoch.revoked.pub"))
    frame_bytes, _d, _p = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"),
                                        cert=os.path.join(rogue, "epoch.revoked-cert.pub"))
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    fork.agree(checks, "epochs: a seal whose certificate chains to an unpinned root is refused "
               "(the verifier pins roots from the genesis and rotation records)", "quarantined")
    fork = case.fork("epochs-key-id")
    lineage = Lineage(fork)
    other_id = lineage.epochs[2]["subkeys"]["epoch.rotated"]
    frame_bytes, _d, _p = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"), key_id=other_id)
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    fork.agree(checks, "key_id: a valid signature whose payload key_id differs from the verifying certificate "
               "is refused", "quarantined")
    fork = case.fork("epochs-other-epoch-cert")
    lineage = Lineage(fork)
    frame_bytes, _d, _p = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"), epoch=2,
                                        cert=os.path.join(lineage.keydir(1), "epoch.revoked-cert.pub"))
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    fork.agree(checks, "key_id: a certificate from another epoch's root is refused", "quarantined")
    fork = case.fork("epochs-identity")
    lineage = Lineage(fork)
    mis = os.path.join(fork.dir, "mis")
    os.mkdir(mis)
    shutil.copy(os.path.join(lineage.keydir(2), "epoch.revoked"), os.path.join(mis, "epoch.revoked"))
    shutil.copy(os.path.join(lineage.keydir(2), "epoch.revoked.pub"), os.path.join(mis, "epoch.revoked.pub"))
    ssh_keygen("-q", "-s", os.path.join(lineage.keydir(2), "root"), "-I", "epoch.revoked@e1", "-n",
               "epoch.revoked", "-V", "always:forever", os.path.join(mis, "epoch.revoked.pub"))
    frame_bytes, _d, _p = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"),
                                        cert=os.path.join(mis, "epoch.revoked-cert.pub"))
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    fork.agree(checks, "key_id: a certificate from the right root whose key identity names another epoch "
               "is refused", "quarantined")
    result = case.ceremony("revoke", "--epoch", "1")
    checks("epochs: revocation of a verify-only epoch commits", result.rc == 0
           and result.json.get("quarantined") is False, result)
    status = case.status()
    checks("epochs: the verify-only epoch is revoked, the active one untouched",
           status.json.get("epochs") == {"1": "revoked", "2": "active"} and status.json.get("state") == "committed",
           status)
    case.agree(checks, "epochs: after revoking a verify-only epoch", "committed")
    again = case.ceremony("revoke", "--epoch", "1")
    checks("epochs: nothing leaves revoked (a second revocation is refused)", again.rc == 4, again)


def j_active_revocation(point):
    def job(checks):
        case = committed_case(f"revoke-active-{point}")
        probes = itertools.count()

        def probe_size():
            probe = case.fork(f"revoke-active-probe-{point}-{next(probes)}")
            crashed(probe, "after-intent-fsync", "revoke", "--epoch", "1")
            return len(frame_of_intent(probe.intent()))

        if point == "frame-byte-last":
            last_byte_crash(case, ("revoke", "--epoch", "1"), probe_size, case.intent)
        elif point.startswith("frame-byte-"):
            size = probe_size()
            case, _result, _intent, _n = sampled_case_crash(
                case, ("revoke", "--epoch", "1"), 1 if point == "frame-byte-first" else size // 2)
        else:
            crashed(case, point, "revoke", "--epoch", "1")
        intent = case.intent()
        stored = intent["anchor_commit"] if intent else None
        status = case.status()
        independent = case.verifier()
        # Independent of production constants: these cuts precede the intent rename.
        pre_intent_points = {"fs-create-after-temp-fsync", "fs-create-intent-after-temp-fsync"}
        if point in pre_intent_points:
            checks(f"active revocation, crash {point}: the cut precedes the intent; the store is unchanged and still authorizing",
                   all(observed.json.get("state") == "committed"
                       and observed.json.get("authorizing_state") is True
                       and observed.json.get("current_authorization") is False
                       and observed.json.get("epochs") == {"1": "active"}
                       for observed in (status, independent))
                   and intent is None and not os.path.lexists(os.path.join(case.store_dir(), "intent")),
                   (status, independent))
        else:
            checks(f"active revocation, crash {point}: no current authorization at the cut",
                   status.json.get("authorizing_state") is False and status.json.get("current_authorization") is False
                   and independent.json.get("authorizing_state") is False, (status, independent))
        case.agree(checks, f"active revocation, crash {point}")
        result = case.writer("recover")
        durable = point in ("after-frame-fsync", "after-push", "after-readback", "after-intent-remove",
                            "frame-byte-last", "fs-replace-after-temp-fsync", "fs-replace-after-rename",
                            "fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename")
        if durable:
            checks(f"active revocation, crash {point}: recovery ends quarantined with the revocation anchored",
                   result.json.get("state") == "quarantined"
                   and os.path.exists(os.path.join(case.store_dir(), "quarantine")), result)
            if stored is not None:
                checks(f"active revocation, crash {point}: the anchored commit is the one stored in the intent "
                       "before the crash", case.tip() == stored)
        else:
            checks(f"active revocation, crash {point}: the revocation never became durable; the store is "
                   "committed as before", result.json.get("state") == "committed" and result.json.get("seq") == 1,
                   result)
        case.agree(checks, f"active revocation, crash {point}, recovered")
    return job


def j_verify_only_revocation(point):
    """A revocation of a verify-only epoch crashed at each named point:
    recovery never quarantines it (no quarantine child exists for it) and
    ends committed, with the epoch revoked once the frame is durable."""
    def job(checks):
        case = committed_case(f"revoke-verify-only-{point}", rotate=True)
        crashed(case, point, "revoke", "--epoch", "1")
        case.agree(checks, f"verify-only revocation, crash {point}")
        result = case.writer("recover")
        durable = point in ("after-frame-fsync", "after-push", "after-readback", "after-intent-remove",
                            "fs-replace-after-temp-fsync", "fs-replace-after-rename")
        checks(f"verify-only revocation, crash {point}: recovery ends committed with no quarantine marker"
               + (", epoch 1 revoked" if durable else ", the revocation never durable"),
               result.json.get("state") == "committed" and result.json.get("seq") == (3 if durable else 2)
               and result.json.get("epochs") == ({"1": "revoked", "2": "active"} if durable
                                                 else {"1": "verify-only", "2": "active"})
               and not os.path.exists(os.path.join(case.store_dir(), "quarantine")), result)
        case.agree(checks, f"verify-only revocation, crash {point}, recovered", "committed")
    return job


# --- linked re-genesis --------------------------------------------------------

# Every named crash point of the revoke command (store.CRASH_APPLICABLE)
# Independent inventory: never derived from the production point sets.
# Legacy first-call primitive cuts remain alongside the target-qualified cuts.
FROZEN_PRIMITIVE_POINTS = {"fs-create-after-temp-fsync", "fs-create-after-rename",
                           "fs-replace-after-temp-fsync", "fs-replace-after-rename"}
FROZEN_INTENT_POINTS = {"fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename"}
FROZEN_MARKER_POINTS = {"fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename"}
FROZEN_FRAME_POINTS = {"after-intent-fsync", "after-frame-fsync", "after-push",
                       "after-readback", "after-intent-remove"}
FROZEN_CRASH_POINTS = {
    "genesis": FROZEN_FRAME_POINTS | FROZEN_PRIMITIVE_POINTS | FROZEN_INTENT_POINTS |
        {"after-store-dir", "genesis-step-1", "genesis-step-2", "genesis-step-3", "genesis-step-4",
         "genesis-step-5", "genesis-step-6a", "genesis-step-6b"},
    "rotate": FROZEN_FRAME_POINTS | FROZEN_PRIMITIVE_POINTS | FROZEN_INTENT_POINTS |
        FROZEN_MARKER_POINTS | {"after-store-dir"},
    "revoke": FROZEN_FRAME_POINTS | FROZEN_PRIMITIVE_POINTS | FROZEN_INTENT_POINTS | FROZEN_MARKER_POINTS,
    "regenesis": FROZEN_PRIMITIVE_POINTS | FROZEN_INTENT_POINTS | FROZEN_MARKER_POINTS |
        {"regenesis-step-1", "regenesis-step-2", "regenesis-step-3", "regenesis-step-4", "regenesis-step-5",
         "after-frame-fsync", "after-push", "after-readback", "archive-after-rename", "archive-after-readonly"},
    "recover": FROZEN_PRIMITIVE_POINTS | FROZEN_MARKER_POINTS |
        {"after-push", "after-readback", "after-intent-remove", "recovery-after-delimiter",
         "archive-after-rename", "archive-after-readonly"},
}
# These cuts run before a re-genesis transaction exists. They require an
# absent remote anchor and no previously published quarantine marker.
MARKER_PRELUDE_CUTS = ("fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename")
REVOCATION_POINTS = ("after-intent-fsync", "after-frame-fsync", "after-push", "after-readback",
                     "after-intent-remove", "fs-create-after-temp-fsync", "fs-create-after-rename",
                     "fs-replace-after-temp-fsync", "fs-replace-after-rename",
                     "fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename",
                     "fs-create-marker-after-temp-fsync", "fs-create-marker-after-rename")
VERIFY_ONLY_REVOCATION_POINTS = ("after-intent-fsync", "after-frame-fsync", "after-push", "after-readback",
                               "after-intent-remove", "fs-create-after-temp-fsync", "fs-create-after-rename",
                               "fs-replace-after-temp-fsync", "fs-replace-after-rename",
                               "fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename")
REGENESIS_CUTS = ("regenesis-step-1", "frame-byte-first", "frame-byte-last", "after-frame-fsync",
                  "regenesis-step-2", "after-push", "after-readback", "regenesis-step-3", "regenesis-step-4",
                  "regenesis-step-5", "fs-create-after-temp-fsync", "fs-create-after-rename",
                  "fs-replace-after-temp-fsync", "fs-replace-after-rename",
                  "archive-after-rename", "archive-after-readonly",
                  "fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename")
REGENESIS_BEFORE_PUSH = ("regenesis-step-1", "frame-byte-first", "frame-byte-last", "after-frame-fsync",
                         "regenesis-step-2", "fs-create-after-temp-fsync", "fs-create-after-rename",
                         "fs-create-intent-after-temp-fsync", "fs-create-intent-after-rename")


def quarantined_case(label):
    case = committed_case(label, revoke_epoch=1)
    status = case.status()
    if status.json.get("state") != "quarantined":
        raise RuntimeError(f"{label}: revoking the active epoch did not quarantine: {status}")
    return case


def regenesis_crash(case, point):
    probes = itertools.count()

    def probe_size():
        probe = case.fork(f"{case.label}-probe-{next(probes)}")
        crashed(probe, "regenesis-step-1", "regenesis")
        return len(frame_of_intent(json.loads(probe.read(probe.auth("regenesis.intent")))))

    def intent_of():
        path = case.auth("regenesis.intent")
        return json.loads(case.read(path)) if os.path.exists(path) else None

    if point == "frame-byte-last":
        last_byte_crash(case, ("regenesis",), probe_size, intent_of)
        return case
    if point == "frame-byte-first":
        return sampled_case_crash(case, ("regenesis",), 1, "regenesis")[0]
    crashed(case, point, "regenesis")
    return case


def j_regenesis(point):
    def job(checks):
        case = quarantined_case(f"regen-{point}")
        old = case.active()
        case = regenesis_crash(case, point)
        status = case.status()
        checks(f"re-genesis, crash {point}: nothing authorizes at the cut",
               status.json.get("authorizing_state") is False or point == "regenesis-step-5", status)
        path = case.auth("regenesis.intent")
        if os.path.exists(path):
            content = parse_frames(frame_of_intent(json.loads(case.read(path))))[0][0]["content"]
            body = json.loads(content)["payload"]["body"]
        elif point in REGENESIS_BEFORE_PUSH:
            new_dirs = set(os.listdir(case.auth("stores"))) - {old["store_id"]}
            logs = [os.path.join(case.auth("stores", sid), "log", "segment-000001.olf") for sid in new_dirs]
            checks(f"re-genesis, crash {point}: no introducer is published before the intent",
                   len(logs) == 1 and (not os.path.exists(logs[0]) or not case.read(logs[0])))
            body = None
        else:
            body = Lineage(case).payloads[0]["body"]
        if body is not None:
            checks(f"re-genesis, crash {point}: the introducer carries registry_version tg-v1.0a and "
                   "admitted_protocols []", body.get("registry_version") == "tg-v1.0a"
                   and body.get("admitted_protocols") == [], {k: body.get(k) for k in ("registry_version",
                                                                                      "admitted_protocols")})
        case.agree(checks, f"re-genesis, crash {point}")
        unpublished = sorted(set(os.listdir(case.auth("stores"))) - {old["store_id"]})
        new_id = json.loads(case.read(path))["new_store_id"] if os.path.exists(path) else (
            unpublished[0] if point in REGENESIS_BEFORE_PUSH else None)
        kept = case.snapshot(case.auth("stores", new_id)) if new_id else None
        result = case.writer("recover")
        active = case.active()
        if point in REGENESIS_BEFORE_PUSH:
            status = case.status()
            checks(f"re-genesis, crash {point}: abandoned -- the old store stays quarantined and active, the intent "
                   "is removed, and the new directory stays byte-identical and unpublished",
                   result.json.get("state") == "quarantined" and active == old
                   and sorted(os.listdir(case.auth("stores"))) == sorted([old["store_id"], new_id])
                   and case.snapshot(case.auth("stores", new_id)) == kept
                   and status.json.get("unpublished", {}).get("stores") == [new_id]
                   and not os.path.exists(case.auth("regenesis.intent")), (result, status))
        else:
            archived = case.auth("archive", old["store_id"])
            modes = {stat.S_IMODE(os.lstat(os.path.join(r, n)).st_mode)
                     for r, _d, files in os.walk(archived) for n in files}
            checks(f"re-genesis, crash {point}: completed -- generation 2 active, the old store archived "
                   "read-only", result.json.get("state") == "committed" and active["generation"] == 2
                   and active["store_id"] != old["store_id"] and os.path.isdir(archived) and modes == {0o400}
                   and not os.path.exists(case.auth("regenesis.intent")), (result, modes))
            checks(f"re-genesis, crash {point}: a test lineage stays test with no current authorization",
                   result.json.get("anchor_class") == "test" and result.json.get("current_authorization") is False)
        case.agree(checks, f"re-genesis, crash {point}, recovered")
    return job


def j_regenesis_bad_sig(point):
    def job(checks):
        case = quarantined_case(f"regen-badsig-{point}")
        case = regenesis_crash(case, point)
        path = case.auth("regenesis.intent")
        if os.path.exists(path):
            intent = json.loads(case.read(path))
            pointer = json.loads(intent["anchor_json"])
            parent = intent["old_commit"]
        else:
            pointer = json.loads(case.anchor_json_at(case.tip()))
            parent = case.parent_of(case.tip())
        lines = pointer["sig"].split("\n")
        lines[3] = ("B" if lines[3][0] != "B" else "C") + lines[3][1:]
        pointer["sig"] = "\n".join(lines)
        remote_commit(case, canon(pointer), parent)
        before = case.snapshot()
        result = case.writer("recover")
        if os.path.exists(path):
            checks(f"re-genesis, crash {point}, invalid anchor signature: quarantine, both stores untouched",
                   result.json.get("state") == "regenesis-quarantined", result)
            unchanged(checks, f"re-genesis, crash {point}, invalid anchor signature", case, before)
            case.agree(checks, f"re-genesis, crash {point}, invalid anchor signature", "regenesis-quarantined")
        else:
            checks(f"re-genesis, crash {point} (intent already removed), invalid anchor signature: quarantine",
                   result.json.get("state") == "quarantined", result)
    return job


def j_regenesis_links(checks):
    case = quarantined_case("regen-links")
    result = case.ceremony("regenesis")
    checks("re-genesis: the ceremony completes", result.rc == 0 and result.json.get("generation") == 2, result)
    case.agree(checks, "re-genesis completed", "committed")
    display_matches(checks, "re-genesis", result, Lineage(case).payloads[0]["body"])
    tip = case.tip()
    old_commit = case.parent_of(tip)
    anchor_json = case.anchor_json_at(tip)
    # a valid new-root signature over the pointer, but the ceremony record is invalid
    fork = case.fork("regen-invalid-record")
    first = parse_frames(fork.read(fork.log_path()))[0][0]
    content = first["content"].replace(b'"ceremony":"regenesis"', b'"ceremony":"rEgenesis"', 1)
    fork.write(fork.log_path(), mkframe(1, "store.regenesis", content))
    fork.agree(checks, "re-genesis: a generation-changing pointer with a valid new-root signature but an "
               "invalid ceremony record is quarantine", "quarantined")
    # the ceremony record is validly sealed but not linked to the archive
    fork = case.fork("regen-unlinked")
    lineage = Lineage(fork)
    body = dict(lineage.payloads[0]["body"])
    body["prev_generation"] = dict(body["prev_generation"], last_record_digest=D({"unlinked": 1}))
    frame_bytes, digest, _p = lineage.forge("store.regenesis", body, seq=1, prev=None, epoch=1)
    fork.write(fork.log_path(), frame_bytes)
    fork.agree(checks, "re-genesis: a validly sealed but unlinked ceremony record is quarantine",
               "quarantined")
    # the reverse: a valid ceremony record, but the pointer is badly signed
    pointer = json.loads(anchor_json)
    lines = pointer["sig"].split("\n")
    lines[3] = ("B" if lines[3][0] != "B" else "C") + lines[3][1:]
    pointer["sig"] = "\n".join(lines)
    remote_commit(case, canon(pointer), old_commit)
    case.agree(checks, "re-genesis: a valid ceremony record under a badly signed generation-changing pointer "
               "is quarantine", "quarantined")
    case.set_tip(tip)
    case.agree(checks, "re-genesis: the genuine pointer restored", "committed")
    # a store.regenesis record naming another remote
    fork = case.fork("regen-remote")
    lineage = Lineage(fork)
    body = dict(lineage.payloads[0]["body"], remote="file:///elsewhere/anchor.git")
    frame_bytes, _digest, _p = lineage.forge("store.regenesis", body, seq=1, prev=None, epoch=1)
    fork.write(fork.log_path(), frame_bytes)
    fork.agree(checks, "test class: a store.regenesis record naming a remote other than the pinned one is "
               "refused by the writer and the verifier", "quarantined")
    # the pending-intent variant: remote names the new generation, the new frame is invalid
    case2 = quarantined_case("regen-pending-invalid")
    crashed(case2, "after-push", "regenesis")
    intent = json.loads(case2.read(case2.auth("regenesis.intent")))
    log = case2.auth("stores", intent["new_store_id"], "log", "segment-000001.olf")
    data = bytearray(case2.read(log))
    data[len(data) // 2] ^= 0x01
    case2.write(log, bytes(data))
    before = case2.snapshot()
    result = case2.writer("recover")
    checks("re-genesis: with the intent, a valid new-generation pointer over a frame that is not durable is "
           "quarantine, both stores untouched", result.json.get("state") == "regenesis-quarantined", result)
    unchanged(checks, "re-genesis pending, invalid new frame", case2, before)


def j_regenesis_test_flag(checks):
    case = quarantined_case("regen-test-flag")
    before = case.snapshot()
    result = case.ceremony("regenesis", env={"LOOP_AUTHORITY_TEST": None})
    checks("test class: linked re-genesis of a test lineage without LOOP_AUTHORITY_TEST=1 is refused",
           result.rc == 4 and "test-lineage" in result.out, result)
    unchanged(checks, "re-genesis refused without the test flag", case, before)


def j_regenesis_unrelated(checks):
    case = quarantined_case("regen-unrelated")
    crashed(case, "regenesis-step-1", "regenesis")
    intent = json.loads(case.read(case.auth("regenesis.intent")))
    other = committed_case("regen-unrelated-other")
    git("--git-dir", case.remote, "fetch", "-q", other.remote, f"{ANCHOR_REF}:refs/foreign")
    case.set_tip(other.tip())
    before = case.snapshot()
    result = case.writer("recover")
    checks("A2.4: a valid but unrelated pointer mints nothing and fails closed",
           result.json.get("state") == "regenesis-quarantined" and result.json.get("row") is None, result)
    unchanged(checks, "A2.4 unrelated pointer", case, before)
    lineage = Lineage(case, store_id=intent["old"]["store_id"])
    advanced = dict(lineage.ptr(lineage.L), seq=lineage.L + 1, record_digest=D({"advanced": 1}))
    remote_commit(case, lineage.pointer(advanced, epoch=1), intent["old_commit"])
    result = case.writer("recover")
    checks("A2.4: an old-generation pointer advanced past the recorded one mints nothing and fails closed",
           result.json.get("state") == "regenesis-quarantined", result)
    unchanged(checks, "A2.4 advanced old-generation pointer", case, before)
    case.set_tip(intent["old_commit"])
    result = case.writer("recover")
    checks("A2.4: back on the recorded old-generation commit, the re-genesis is abandoned",
           result.json.get("state") == "quarantined" and not os.path.exists(case.auth("regenesis.intent")), result)


def s_epochs_regenesis():
    jobs = [("anchor objects", j_anchor_objects), ("epochs", j_epochs)]
    jobs += [(f"active revocation {p}", j_active_revocation(p)) for p in
             REVOCATION_POINTS + ("frame-byte-first", "frame-byte-mid", "frame-byte-last")]
    jobs += [(f"verify-only revocation {p}", j_verify_only_revocation(p)) for p in VERIFY_ONLY_REVOCATION_POINTS]
    jobs += [(f"marker prelude {c}/{p}", j_review_crash(c, p))
             for c in ("rotate", "regenesis") for p in MARKER_PRELUDE_CUTS]
    jobs += [(f"re-genesis {p}", j_regenesis(p)) for p in REGENESIS_CUTS]
    jobs += [(f"re-genesis bad signature {p}", j_regenesis_bad_sig(p)) for p in REGENESIS_CUTS]
    jobs += [("re-genesis links", j_regenesis_links), ("re-genesis test flag", j_regenesis_test_flag),
             ("re-genesis unrelated", j_regenesis_unrelated)]
    parallel(jobs)


# --- ceremonies ----------------------------------------------------------------

def j_ceremonies(checks):
    case = Case("no-tty")
    result = case.writer("ceremony", "genesis", "--remote", case.url)
    checks("ceremonies: genesis without a TTY is refused", result.rc == 11 and "no-tty" in result.err, result)
    checks("ceremonies: a refused ceremony created nothing", not os.path.exists(case.auth()))
    result = case.genesis(answer="wrong")
    checks("ceremonies: a wrong challenge is refused", result.rc == 11 and "challenge" in result.out, result)
    stores = case.auth("stores")
    checks("ceremonies: a wrong challenge created no store",
           (not os.path.isdir(stores) or not os.listdir(stores)) and case.tip() is None)
    committed = committed_case("tty-committed")
    before, remote_before = committed.snapshot(), committed.remote_snapshot()
    result = committed.writer("ceremony", "rotate")
    checks("ceremonies: rotate without a TTY is refused", result.rc == 11, result)
    result = committed.ceremony("rotate", answer="wrong")
    checks("ceremonies: rotate with a wrong challenge is refused", result.rc == 11, result)
    unchanged(checks, "ceremonies: refused rotations", committed, before, remote_before)
    for label, name, data in (("active exists (garbage)", "active", b"garbage"),
                              ("active exists (a well-formed marker naming no store)", "active",
                               canon({"store_id": "a" * 32, "generation": 1})),
                              ("genesis.intent exists", "genesis.intent", b"{}"),
                              ("regenesis.intent exists", "regenesis.intent", b"{}")):
        case = Case(f"genesis-refused-{name}")
        os.makedirs(case.auth("stores"), mode=0o700)
        os.makedirs(case.auth("archive"), mode=0o700)
        for path in (os.path.dirname(case.auth()), case.auth()):
            os.chmod(path, 0o700)
        case.write(case.auth(name), data)
        before = case.snapshot()
        result = case.genesis()
        checks(f"ceremonies: genesis is refused when {label}", result.rc == 4 and "genesis-refused" in result.out,
               result)
        after = {k: v for k, v in case.snapshot().items() if k != "lock"}
        checks(f"ceremonies: the refused genesis ({label}) changed nothing",
               after == {k: v for k, v in before.items() if k != "lock"} and case.tip() is None)
    case = Case("genesis-refused-ref")
    other = committed_case("genesis-refused-ref-other")
    git("--git-dir", case.remote, "fetch", "-q", other.remote, f"{ANCHOR_REF}:{ANCHOR_REF}")
    result = case.genesis()
    checks("ceremonies: genesis is refused when the remote anchor ref exists",
           result.rc == 4 and "ref exists" in result.out, result)
    checks("ceremonies: the refused genesis created no store", not os.listdir(case.auth("stores")))


def j_remote_forms(checks):
    case = Case("remote-forms")
    for label, url in (("ext::", "ext::sh -c touch% x"), ("fd::", "fd::3"),
                       ("another <x>:: form", "foo::https://example.invalid/x.git"),
                       ("whitespace", "https://example.invalid/a b.git"),
                       ("a leading -", "-uhttps://example.invalid/x.git"),
                       ("credentials in the URL", "https://user:pw@example.invalid/x.git")):
        # --remote=<url> hands even a leading '-' to the writer's own URL
        # validator (argparse would refuse `--remote -x` as a usage error first)
        result = case.ceremony("genesis", f"--remote={url}")
        checks(f"remote: genesis with {label} is refused by the remote validator (error: remote:, exit 4)",
               result.rc == 4 and "error: remote: remote form refused" in result.out, result)
    checks("remote: the refused geneses created no store", not os.listdir(case.auth("stores")))
    result = case.ceremony("genesis", "--remote", case.url, env={"LOOP_AUTHORITY_TEST": None})
    checks("remote: file:// is refused at genesis without LOOP_AUTHORITY_TEST=1",
           result.rc == 4 and "remote-test-only" in result.out, result)


# --- key staging -------------------------------------------------------------------

def j_key_staging(base, point, next_rotation):
    def job(checks):
        case = committed_case(f"staging-{point}") if next_rotation else base.fork(f"staging-{point}")
        crashed(case, point, "rotate")
        status = case.status()
        leftovers = status.json.get("unpublished", {}).get("key_dirs", [])
        checks(f"key staging, rotation crash {point}: the old epoch stays active and the store committed",
               status.json.get("state") == "committed" and status.json.get("epochs") == {"1": "active"}
               and len(leftovers) == 1, status)
        independent = case.verifier()
        checks(f"key staging, rotation crash {point}: the verifier passes", independent.rc == 0
               and independent.json.get("state") == "committed", independent)
        leftover = os.path.join(case.store_dir(), "keys", leftovers[0]) if leftovers else None
        planted = 0
        for name in sorted(os.listdir(leftover)) if leftover else []:
            if name == "root" or name.endswith("-cert.pub") or name in TYPES:
                path = os.path.join(leftover, name)
                data = bytearray(case.read(path))
                data[len(data) // 2] ^= 0x01
                case.write(path, bytes(data))
                planted += 1
        again = case.status()
        checks(f"key staging, rotation crash {point}: a planted change to the unpublished key files changes "
               f"nothing ({planted} files)", again.json.get("state") == "committed"
               and again.json.get("epochs") == {"1": "active"}, again)
        if next_rotation:
            result = case.ceremony("rotate")
            status = case.status()
            new_dirs = set(os.listdir(os.path.join(case.store_dir(), "keys"))) - set(leftovers)
            checks(f"key staging, rotation crash {point}: the next rotation succeeds with a fresh directory",
                   result.rc == 0 and status.json.get("epochs") == {"1": "verify-only", "2": "active"}
                   and len(new_dirs) == 2 and status.json.get("unpublished", {}).get("key_dirs") == leftovers,
                   (result, status))
    return job


def s_ceremonies_staging():
    base = committed_case("staging-base")
    points = ["after-store-dir"] + [f"key-step-{n}" for n in range(1, KEY_STEPS + 1)]
    jobs = [("ceremonies", j_ceremonies), ("remote forms", j_remote_forms)]
    jobs += [(f"staging {p}", j_key_staging(base, p, False)) for p in points]
    jobs += [(f"staging next {p}", j_key_staging(base, p, True))
             for p in ("key-step-1", "key-step-2", f"key-step-{KEY_STEPS // 2}", f"key-step-{KEY_STEPS}")]
    parallel(jobs)


# --- genesis at every cut (A2.3, A2.4) ------------------------------------------------

def gcrash(label, point):
    byte = re.fullmatch(r"frame-byte-([1-9][0-9]*)", point)
    if byte:
        return sampled_genesis_crash(label, int(byte.group(1)))[0]
    case = Case(label)
    crashed(case, point, "genesis", "--remote", case.url)
    return case


def genesis_frame_size(label):
    probe = gcrash(label, "genesis-step-2")
    frame_bytes = frame_of_intent(probe.genesis_intent())
    return len(frame_bytes), frame_bytes.index(b"\n") + 1


def expect_row(checks, case, label, state, row_number):
    writer, _v = case.agree(checks, label, state)
    checks(f"{label}: lands on A2.3 row {row_number}", writer.json.get("table") == f"A2.3 row {row_number}",
           writer)
    return writer


def j_genesis_pre_intent(point, new_genesis):
    def job(checks):
        case = gcrash(f"g-pre-{point}", point)
        status = case.status()
        checks(f"genesis crash {point}: before genesis.intent is durable only an inert directory remains",
               status.json.get("state") == "none" and len(status.json.get("unpublished", {}).get("stores", [])) == 1
               and not os.path.exists(case.auth("genesis.intent")) and case.tip() is None, status)
        independent = case.verifier()
        checks(f"genesis crash {point}: the verifier agrees (none)", independent.json.get("state") == "none",
               independent)
        if new_genesis:
            result = case.genesis()
            checks(f"genesis crash {point}: a new genesis succeeds beside the inert directory", result.rc == 0, result)
            case.agree(checks, f"genesis crash {point}, new genesis", "committed")
    return job


def j_genesis_abandon(point):
    def job(checks):
        case = gcrash(f"g-abandon-{point}", point)
        expect_row(checks, case, f"genesis crash {point}", "genesis-pending", 6)
        intent = case.genesis_intent()
        kept = case.snapshot(case.store_dir(intent["store_id"]))
        result = case.writer("recover")
        status = case.status()
        checks(f"genesis crash {point}: recovery abandons -- only the intent is removed; the intent-named "
               "directory stays byte-identical, reported unpublished", result.json.get("state") == "none"
               and case.snapshot(case.store_dir(intent["store_id"])) == kept
               and status.json.get("unpublished", {}).get("stores") == [intent["store_id"]]
               and not os.path.exists(case.auth("genesis.intent")) and case.tip() is None, (result, status))
        case.agree(checks, f"genesis crash {point}, abandoned", "none")
        again = case.genesis()
        checks(f"genesis crash {point}: a new genesis succeeds after the abandonment, with a fresh store id",
               again.rc == 0 and again.json.get("store_id") not in (None, intent["store_id"]), again)
        checks(f"genesis crash {point}: the abandoned directory is still byte-identical and unpublished",
               case.snapshot(case.store_dir(intent["store_id"])) == kept
               and case.status().json.get("unpublished", {}).get("stores") == [intent["store_id"]])
    return job


def j_genesis_torn_samples(checks):
    size, header = genesis_frame_size("g-size")
    for n in sorted({1, 2, header - 1, header, header + 1, size // 2, size - 3}):
        case, _result, intent, n = sampled_genesis_crash(f"g-torn-{n}", n)
        checks(f"genesis frame-byte-{n}: exactly the first {n} bytes of frame 1 are on disk",
               case.read(case.log_path(intent["store_id"])) == frame_of_intent(intent)[:n])
        expect_row(checks, case, f"genesis frame-byte-{n} (torn, ref absent)", "genesis-pending", 6)
        result = case.writer("recover")
        checks(f"genesis frame-byte-{n}: abandoned", result.json.get("state") == "none", result)


def j_genesis_last_byte(with_ref):
    def job(checks):
        case, _result, intent = genesis_last_byte(f"g-last-{with_ref}")
        frame_bytes = frame_of_intent(intent)
        checks("genesis last-byte crash: every byte but the final newline is on disk",
               case.read(case.log_path(intent["store_id"])) == frame_bytes[:-1])
        if with_ref:
            remote_commit(case, intent["anchor_json"].encode(), None)
            checks("genesis last-byte crash: the test pushed exactly the intent's commit",
                   case.tip() == intent["anchor_commit"])
            expect_row(checks, case, "genesis last-byte crash with the exact ref", "genesis-quarantined", 10)
            result = case.writer("recover")
            checks("genesis last-byte crash with the exact ref: quarantined (terminal genesis-quarantined)",
                   result.json.get("state") == "genesis-quarantined"
                   and os.path.exists(os.path.join(case.store_dir(intent["store_id"]), "quarantine")), result)
        else:
            expect_row(checks, case, "genesis last-byte crash, ref absent", "genesis-pending", 7)
            result = case.writer("recover")
            checks("genesis last-byte crash, ref absent: delimiter completion + replay-forward of the exact "
                   "commit, then completion", result.json.get("state") == "committed"
                   and case.tip() == intent["anchor_commit"]
                   and case.read(case.log_path(intent["store_id"])) == frame_bytes, result)
    return job


def j_genesis_valid(point, variant):
    def job(checks):
        case = gcrash(f"g-valid-{point}-{variant}", point)
        intent = case.genesis_intent()
        stored = intent["anchor_commit"]
        if variant == "push-exact":
            remote_commit(case, intent["anchor_json"].encode(), None)
        elif variant == "delete-ref":
            case.set_tip(None)
        pushed = case.tip() == stored
        active = os.path.exists(case.auth("active"))
        if active and not pushed:
            expect_row(checks, case, f"genesis crash {point}, ref deleted after 6a", "quarantined", 5)
            result = case.writer("recover")
            checks(f"genesis crash {point}, ref deleted after 6a: quarantine", result.json.get("state") ==
                   "quarantined" and os.path.exists(os.path.join(case.store_dir(intent["store_id"]),
                                                                 "quarantine")), result)
            return
        row = 9 if pushed else 8
        expect_row(checks, case, f"genesis crash {point} ({variant})", "genesis-pending", row)
        result = case.writer("recover")
        checks(f"genesis crash {point} ({variant}): completed with the intent's exact commit (identical bytes)",
               result.json.get("state") == "committed" and case.tip() == stored
               and case.active() == {"store_id": intent["store_id"], "generation": 1}
               and case.genesis_intent() is None, result)
    return job


def j_genesis_6b(point):
    def job(checks):
        case = gcrash(f"g-6b-{point}", point)
        status = case.status()
        checks(f"genesis crash {point}: committed; only the cursor is stale",
               status.json.get("state") == "committed" and status.json.get("row") == "recovery-tidy", status)
        result = case.writer("recover")
        checks(f"genesis crash {point}: the cursor is tidied", result.json.get("state") == "committed"
               and os.path.exists(os.path.join(case.store_dir(), "cursor")), result)
    return job


def resign_intent(case, intent, frame_bytes):
    """Recompute everything an intent derives from its frame (digest,
    lengths, a pointer signed by the intent's root, the commit), so that only
    the defect the caller planted remains."""
    frames, _end = parse_frames(frame_bytes)
    digest = frames[0]["digest"]
    root_path = os.path.join(case.store_dir(intent["store_id"]), "keys", intent["key_dir"], "root")
    root_pub = case.read(root_path + ".pub").decode()
    active = {"store_id": intent["store_id"], "generation": 1, "genesis_digest": digest, "seq": 1,
              "record_digest": digest, "epoch": 1, "key_id": fingerprint_pub(root_pub)}
    sig = ssh_keygen("-Y", "sign", "-f", root_path, "-n", POINTER_NS,
                     stdin=canon({"active": active, "prev_generation": None})).stdout.decode()
    anchor_json = canon({"active": active, "prev_generation": None, "sig": sig})
    return dict(intent, length=frames[0]["length"], digest=digest, frame_length=len(frame_bytes),
                frame_b64=base64.b64encode(frame_bytes).decode(), anchor_json=anchor_json.decode(),
                anchor_commit=expected_commit(anchor_json, None))


def flip_sig(armored, line_index=3):
    lines = armored.split("\n")
    lines[line_index] = ("B" if lines[line_index][0] != "B" else "C") + lines[line_index][1:]
    return "\n".join(lines)


def j_a24_variants(checks):
    none_case = gcrash("a24-none", "genesis-step-2")
    intent = none_case.genesis_intent()
    frame_bytes = frame_of_intent(intent)
    content = parse_frames(frame_bytes)[0][0]["content"]
    payload = json.loads(content)["payload"]
    sig = json.loads(content)["sig"]
    keydir = os.path.join(none_case.store_dir(intent["store_id"]), "keys", intent["key_dir"])
    revoked = {"type": "epoch.revoked", "v": 1, "store_id": intent["store_id"], "generation": 1, "seq": 1,
               "epoch": 1, "key_id": fingerprint_pub(none_case.read(os.path.join(keydir, "epoch.revoked.pub")).decode()),
               "prev": None, "body": {"ceremony": "revoke", "envelope_digest": D({"x": 1}), "principal": PRINCIPAL,
                                      "epoch": 1, "prior_state": "active"}}
    revoked_sig = ssh_keygen("-Y", "sign", "-f", os.path.join(keydir, "epoch.revoked-cert.pub"), "-n",
                             "olddonkey-loop.authority.epoch.revoked.v1", stdin=canon(revoked)).stdout.decode()
    altered_payload = dict(payload, body=dict(payload["body"], envelope_digest=D({"altered": 1})))
    raw_sig = base64.b64decode("".join(sig.strip().split("\n")[1:-1]))
    cert_flip = bytearray(raw_sig)
    cert_flip[120] ^= 0x01
    body = base64.b64encode(bytes(cert_flip)).decode()
    bad_cert_sig = ("-----BEGIN SSH SIGNATURE-----\n" + "\n".join(body[i:i + 70] for i in range(0, len(body), 70))
                    + "\n-----END SSH SIGNATURE-----\n")
    pointer = json.loads(intent["anchor_json"])
    other_active = dict(pointer["active"], record_digest=D({"other": 1}))
    other_sig = ssh_keygen("-Y", "sign", "-f", os.path.join(keydir, "root"), "-n", POINTER_NS,
                           stdin=canon({"active": other_active, "prev_generation": None})).stdout.decode()
    other_anchor = canon({"active": other_active, "prev_generation": None, "sig": other_sig})
    badsig_anchor = canon(dict(pointer, sig=flip_sig(pointer["sig"])))
    defects = {
        "a wrong digest": dict(intent, digest=D({"wrong": 1})),
        "frame bytes that are not a genesis record": resign_intent(
            none_case, intent, mkframe(1, "epoch.revoked", canon({"payload": revoked, "sig": revoked_sig}))),
        "a bad seal": resign_intent(none_case, intent,
                                    mkframe(1, "store.genesis", canon({"payload": altered_payload, "sig": sig}))),
        "a bad certificate": resign_intent(none_case, intent,
                                           mkframe(1, "store.genesis", canon({"payload": payload, "sig": bad_cert_sig}))),
        "a pointer that is not that record's": dict(intent, anchor_json=other_anchor.decode(),
                                                   anchor_commit=expected_commit(other_anchor, None)),
        "a badly signed pointer": dict(intent, anchor_json=badsig_anchor.decode(),
                                       anchor_commit=expected_commit(badsig_anchor, None)),
        "a rebuilt commit that differs": dict(intent, anchor_commit="0" * 40),
    }
    for label, value in defects.items():
        fork = none_case.fork(f"a24-defect-{label}")
        fork.write(fork.auth("genesis.intent"), canon(value))
        expect_row(checks, fork, f"A2.4 a parseable intent with {label}, no frame, ref absent (never row 6)",
                   "genesis-invalid", 1)
    fork = none_case.fork("a24-unparsable")
    fork.write(fork.auth("genesis.intent"), b"{unparsable")
    expect_row(checks, fork, "A2.4 an unparsable intent", "genesis-invalid", 1)
    wrong_actives = {"another store": canon({"store_id": "f" * 32, "generation": 1}),
                     "a malformed marker": b"not json"}
    for label, data in wrong_actives.items():
        fork = none_case.fork(f"a24-active-{label}")
        fork.write(fork.auth("active"), data)
        expect_row(checks, fork, f"A2.4 active naming {label}", "anchor-mismatch", 2)
    fork = none_case.fork("a24-active-unreadable")
    fork.write(fork.auth("active"), canon({"store_id": intent["store_id"], "generation": 1}), mode=0o000)
    expect_row(checks, fork, "A2.4 an unreadable active", "anchor-mismatch", 2)
    os.chmod(fork.auth("active"), 0o600)
    # the torn prefix versus an altered prefix of the same length
    torn = gcrash("a24-torn", "frame-byte-100")
    expect_row(checks, torn, "A2.4 a genuine crash prefix of frame 1", "genesis-pending", 6)
    fork = torn.fork("a24-altered-prefix")
    t_intent = fork.genesis_intent()
    log = fork.log_path(t_intent["store_id"])
    data = bytearray(fork.read(log))
    data[50] ^= 0x01
    fork.write(log, bytes(data))
    expect_row(checks, fork, "A2.4 an altered prefix of the same length", "genesis-quarantined", 3)
    # nonconforming tails over a valid frame
    valid = gcrash("a24-valid", "after-frame-fsync")
    v_intent = valid.genesis_intent()
    v_frame = frame_of_intent(v_intent)
    header_end = v_frame.index(b"\n")
    content_len = len(v_frame) - header_end - 2
    nonconforming = {
        "a complete frame that differs from the intent": v_frame[:200] + bytes([v_frame[200] ^ 1]) + v_frame[201:],
        "a short tail that is not a prefix": v_frame[:60] + b"X" + v_frame[61:120],
        "a wrong length": v_frame.replace(f" {content_len} ".encode(), f" {content_len + 1} ".encode(), 1),
        "trailing bytes after a valid frame": v_frame + b"trailing",
    }
    for label, data in nonconforming.items():
        fork = valid.fork(f"a24-nc-{label}")
        fork.write(fork.log_path(v_intent["store_id"]), data)
        expect_row(checks, fork, f"A2.3 {label}", "genesis-quarantined", 3)
        fork2 = valid.fork(f"a24-nc-active-{label}")
        fork2.write(fork2.log_path(v_intent["store_id"]), data)
        fork2.write(fork2.auth("active"), canon({"store_id": v_intent["store_id"], "generation": 1}))
        expect_row(checks, fork2, f"A2.3 {label}, active exact and the ref absent", "quarantined", 3)
    # the unreachable variants of rows 1-3 (the shared remote is moved away)
    moved = valid.remote + ".away"
    variants = []
    for label, data in nonconforming.items():
        fork = valid.fork(f"a24-unreach-{label}")
        fork.write(fork.log_path(v_intent["store_id"]), data)
        variants.append((fork, f"A2.3 {label}, remote unreachable", "genesis-quarantined", 3))
    fork = valid.fork("a24-unreach-unparsable")
    fork.write(fork.auth("genesis.intent"), b"{unparsable")
    variants.append((fork, "A2.4 an unparsable intent, remote unreachable", "genesis-invalid", 1))
    for label, data in wrong_actives.items():
        fork = valid.fork(f"a24-unreach-active-{label}")
        fork.write(fork.auth("active"), data)
        variants.append((fork, f"A2.4 active naming {label}, remote unreachable", "anchor-mismatch", 2))
    unreadable = valid.fork("a24-unreach-active-unreadable")
    unreadable.write(unreadable.auth("active"), canon({"store_id": v_intent["store_id"], "generation": 1}),
                     mode=0o000)
    variants.append((unreadable, "A2.4 an unreadable active, remote unreachable", "anchor-mismatch", 2))
    os.rename(valid.remote, moved)
    try:
        for fork, label, state, row in variants:
            expect_row(checks, fork, label, state, row)
    finally:
        os.rename(moved, valid.remote)
        os.chmod(unreadable.auth("active"), 0o600)
    # a complete frame whose digest is valid but whose record is not the intent's (and fails validation)
    content = parse_frames(v_frame)[0][0]["content"].replace(b'"ceremony":"genesis"', b'"ceremony":"gEnesis"', 1)
    fork = valid.fork("a24-complete-invalid")
    fork.write(fork.log_path(v_intent["store_id"]), mkframe(1, "store.genesis", content))
    expect_row(checks, fork, "A2.3 a complete, digest-valid frame 1 that fails validation", "genesis-quarantined", 3)


def j_unreachable_cuts(checks):
    for point, label in (("genesis-step-2", "none"), ("frame-byte-100", "torn"),
                         ("last-byte", "unterminated"), ("after-frame-fsync", "valid"),
                         ("after-push", "valid with the ref")):
        if point == "last-byte":
            case, result, _intent = genesis_last_byte("unreach-unterminated")
        elif point == "frame-byte-100":
            case, result, _intent, _n = sampled_genesis_crash(f"unreach-{label}", 100)
        else:
            case = Case(f"unreach-{label}")
            result = case.ceremony("genesis", "--remote", case.url, env={"LOOP_AUTHORITY_CRASH_AT": point})
        if result.rc != 137:
            checks(f"A2.3 row 4 fixture {label}: the crash happened", False, result)
            continue
        moved = case.remote + ".away"
        os.rename(case.remote, moved)
        expect_row(checks, case, f"A2.3 frame 1 {label}, remote unreachable (writer and verifier)",
                   "genesis-pending", 4)
        before = case.snapshot()
        case.writer("recover")
        unchanged(checks, f"A2.3 row 4 ({label}): pending, no mutation and no token", case, before)
        os.rename(moved, case.remote)


def j_finish_tokens(checks):
    case = gcrash("finish-commit-point", "genesis-step-4")
    for item in inproc("finish", case.home, case.url, "committed-point"):
        checks(*item)
    pre = gcrash("finish-pre-ceremony", "genesis-step-4")
    pre.set_tip(None)
    for item in inproc("finish", pre.home, pre.url, "pre-ceremony"):
        checks(*item)
    abandonable = gcrash("finish-abandonable", "genesis-step-2")
    for item in inproc("finish", abandonable.home, abandonable.url, "abandonable"):
        checks(*item)
    keysinks = gcrash("finish-keysinks", "genesis-step-2")
    for item in inproc("finish", keysinks.home, keysinks.url, "keysinks"):
        checks(*item)


def s_genesis_cuts():
    pre = ["after-store-dir"] + [f"key-step-{n}" for n in range(1, KEY_STEPS + 1)] + ["genesis-step-1"]
    sample = {"after-store-dir", "key-step-1", f"key-step-{KEY_STEPS}", "genesis-step-1"}
    jobs = [(f"genesis pre-intent {p}", j_genesis_pre_intent(p, p in sample)) for p in pre]
    jobs += [(f"genesis abandon {p}", j_genesis_abandon(p)) for p in ("genesis-step-2", "after-intent-fsync")]
    jobs += [("genesis torn samples", j_genesis_torn_samples),
             ("genesis last byte", j_genesis_last_byte(False)), ("genesis last byte ref", j_genesis_last_byte(True))]
    jobs += [(f"genesis valid {p} {v}", j_genesis_valid(p, v)) for p, v in (
        ("after-frame-fsync", "plain"), ("genesis-step-3", "plain"), ("after-frame-fsync", "push-exact"),
        ("after-push", "plain"), ("genesis-step-4", "plain"), ("after-readback", "plain"),
        ("genesis-step-5", "plain"), ("genesis-step-4", "delete-ref"), ("genesis-step-6a", "plain"),
        ("genesis-step-6a", "delete-ref"))]
    jobs += [(f"genesis 6b {p}", j_genesis_6b(p)) for p in ("genesis-step-6b", "after-intent-remove")]
    jobs += [("A2.4 variants", j_a24_variants), ("A2.3 row 4 cuts", j_unreachable_cuts),
             ("A2.4 tokens", j_finish_tokens)]
    parallel(jobs)


# --- bootstrap terminal states -------------------------------------------------------

def j_terminal(state):
    def job(checks):
        case = gcrash(f"terminal-{state}", "genesis-step-2")
        intent = case.genesis_intent()
        if state == "genesis-invalid":
            case.write(case.auth("genesis.intent"), b"{corrupted after a successful push?")
        elif state == "anchor-mismatch":
            case.write(case.auth("active"), canon({"store_id": "f" * 32, "generation": 1}))
        else:
            log = case.log_path(intent["store_id"])
            case.write(log, b"nonconforming bytes")
            case.writer("recover")
        status = case.status()
        evidence = status.json.get("evidence")
        checks(f"terminal {state}: status names the state and its evidence",
               status.json.get("state") == state and isinstance(evidence, dict) and evidence, status)
        independent = case.verifier()
        checks(f"terminal {state}: read-only verification still runs and agrees",
               independent.json.get("state") == state, independent)
        before, remote_before = case.snapshot(), case.remote_snapshot()
        for args in (("genesis", "--remote", case.url), ("rotate",), ("revoke", "--epoch", "1"), ("regenesis",)):
            result = case.ceremony(*args)
            checks(f"terminal {state}: ceremony {args[0]} is refused", result.rc not in (0, 137), result)
        result = case.writer("recover")
        checks(f"terminal {state}: recovery is refused (no row resets it)", result.rc == 7
               and result.json.get("state") == state, result)
        result = case.writer("submit", "request-opening")
        checks(f"terminal {state}: a row submission is refused", result.rc == 8, result)
        unchanged(checks, f"terminal {state}: every refusal", case, before, remote_before)
    return job


def s_terminal():
    parallel([(f"terminal {s}", j_terminal(s)) for s in ("genesis-invalid", "anchor-mismatch", "genesis-quarantined")])


# --- the independent verifier --------------------------------------------------------

def tree_digest(root):
    items = []
    for current, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(current, name)
            with open(full, "rb") as handle:
                items.append((os.path.relpath(full, root), sha(handle.read())))
    return items


def j_verifier(checks):
    with open(VERIFY, encoding="utf-8") as handle:
        wrapper = handle.read()
    with open(VERIFY + ".py", encoding="utf-8") as handle:
        code = handle.read()
    wrapper_code = "\n".join(line for line in wrapper.splitlines() if not line.lstrip().startswith("#"))
    checks("verifier: imports nothing from lib/loopauth (source check of loop-authority-verify.py)",
           re.search(r"^\s*(from|import)\s+loopauth", code, re.M) is None and "sys.path" not in code
           and "importlib" not in code and "loopauth" not in code and "lib/" not in code)
    checks("verifier: its wrapper runs only loop-authority-verify.py, isolated (-I), and writes nothing",
           re.search(r'exec python3 -I -B "\$here/loop-authority-verify\.py" "\$@"', wrapper_code) is not None
           and "loopauth" not in wrapper_code and "mkdir" not in wrapper_code and "<<" not in wrapper_code)
    case = committed_case("verifier-ro", rotate=True)
    before, remote_before = case.snapshot(), tree_digest(case.remote)
    subprocess.run(["chmod", "-R", "a-w", case.auth(), case.remote], check=True)
    try:
        result = case.verifier()
        checks("verifier: runs against a read-only authority directory and remote",
               result.rc == 0 and result.json.get("state") == "committed", result)
    finally:
        subprocess.run(["chmod", "-R", "u+w", case.auth(), case.remote], check=True)
    checks("verifier: the authority directory is byte-identical afterwards", case.snapshot() == before)
    checks("verifier: the remote is byte-identical afterwards", tree_digest(case.remote) == remote_before)
    verify_tmp = os.path.join(case.home, ".cache", "olddonkey-loop", "verify")
    checks("verifier: its temporary directory is gone", os.path.isdir(verify_tmp) and not os.listdir(verify_tmp))


# --- injected variables and wrapper fixtures -------------------------------------------

INJECTED = ("GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0",
            "GIT_CONFIG_VALUE_0", "GIT_CONFIG_KEY_1", "GIT_CONFIG_VALUE_1", "GIT_SSL_NO_VERIFY",
            "GIT_ASKPASS", "SSH_ASKPASS", "GIT_EXEC_PATH")


class Fixtures:
    """Marker-writing scripts, a decoy remote, and wrapper binaries that record
    their environment (LOOP_AUTHORITY_TEST_BIN_DIR)."""

    def __init__(self, case):
        self.case = case
        self.root = os.path.join(case.dir, "fixtures")
        self.markers = os.path.join(self.root, "markers")
        self.logs = os.path.join(self.root, "logs")
        self.bin = os.path.join(self.root, "bin")
        for path in (self.markers, self.logs, self.bin):
            os.makedirs(path)
        self.marker = os.path.join(self.root, "marker.sh")
        with open(self.marker, "w") as handle:
            handle.write(f"#!/bin/bash\necho \"$*\" > '{self.markers}'/\"${{1:-marker}}\"\nexit 1\n")
        os.chmod(self.marker, 0o755)
        self.decoy = os.path.join(self.root, "decoy.git")
        git("init", "--bare", "-q", self.decoy)
        for name in ("git", "ssh-keygen", "ssh"):
            real = resolve_bin(name)
            path = os.path.join(self.bin, name)
            with open(path, "w") as handle:
                handle.write("#!/bin/bash\n"
                             f"log='{self.logs}'/{name}.$$.$RANDOM\n"
                             "{ printf 'argv=%s\\n' \"$*\"; /usr/bin/env; } > \"$log\"\n"
                             f"exec '{real}' \"$@\"\n")
            os.chmod(path, 0o755)
        config = (f"[url \"file://{self.decoy}\"]\n\tinsteadOf = {case.url}\n\tpushInsteadOf = {case.url}\n"
                  f"[core]\n\tsshCommand = {self.marker} global-ssh\n\thooksPath = {self.root}/hooks\n"
                  f"[credential]\n\thelper = !{self.marker} global-credential\n"
                  "[http]\n\tsslVerify = false\n")
        self.global_config = os.path.join(self.root, "global.gitconfig")
        with open(self.global_config, "w") as handle:
            handle.write(config)
        with open(os.path.join(case.home, ".gitconfig"), "w") as handle:
            handle.write(config)
        os.makedirs(os.path.join(case.home, ".config", "git"), exist_ok=True)
        with open(os.path.join(case.home, ".config", "git", "config"), "w") as handle:
            handle.write(config)

    def env(self, bins=True):
        env = {
            "GIT_SSH_COMMAND": f"{self.marker} git-ssh-command",
            "GIT_PROXY_COMMAND": f"{self.marker} git-proxy-command",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "core.sshCommand",
            "GIT_CONFIG_VALUE_0": f"{self.marker} config-count",
            "GIT_CONFIG_KEY_1": f"url.file://{self.decoy}.insteadOf",
            "GIT_CONFIG_VALUE_1": self.case.url,
            "GIT_SSL_NO_VERIFY": "1",
            "GIT_CONFIG_GLOBAL": self.global_config,
            "GIT_ASKPASS": f"{self.marker} askpass",
            "SSH_ASKPASS": f"{self.marker} ssh-askpass",
            "GIT_EXEC_PATH": self.root,
        }
        if bins:
            env["LOOP_AUTHORITY_TEST_BIN_DIR"] = self.bin
        return env

    def records(self, name):
        out = []
        for path in sorted(glob.glob(os.path.join(self.logs, f"{name}.*"))):
            with open(path) as handle:
                lines = handle.read().splitlines()
            env = {}
            for line in lines[1:]:
                key, _sep, value = line.partition("=")
                env[key] = value
            out.append(env)
        return out

    def check(self, checks, label, names=("git", "ssh-keygen")):
        checks(f"{label}: no marker was written", not os.listdir(self.markers), os.listdir(self.markers))
        checks(f"{label}: the decoy remote was never touched",
               git("--git-dir", self.decoy, "for-each-ref").stdout == b"")
        for name in names:
            records = self.records(name)
            leaked = sorted({key for env in records for key in INJECTED if key in env})
            checks(f"{label}: the {name} wrapper ran and recorded none of the injected variables",
                   records and not leaked, (len(records), leaked))
            if name == "git":
                checks(f"{label}: git always ran with GIT_CONFIG_GLOBAL=/dev/null and GIT_CONFIG_NOSYSTEM=1",
                       all(env.get("GIT_CONFIG_GLOBAL") == "/dev/null" and env.get("GIT_CONFIG_NOSYSTEM") == "1"
                           for env in records))


def j_injected(checks):
    case = Case("injected")
    fixtures = Fixtures(case)
    result = case.genesis(env=fixtures.env())
    checks("injected: genesis (push and fetch) succeeds under the injected variables", result.rc == 0, result)
    result = case.ceremony("rotate", env=fixtures.env())
    checks("injected: rotation (push and fetch) succeeds under the injected variables", result.rc == 0, result)
    checks("injected: the pinned remote holds the anchor", case.tip() is not None)
    fixtures.check(checks, "injected (writer)")
    shutil.rmtree(fixtures.logs)
    os.makedirs(fixtures.logs)
    result = case.verifier(env=fixtures.env())
    checks("injected: the verifier fetches only the pinned remote and verifies it", result.rc == 0
           and result.json.get("state") == "committed", result)
    checks("injected: with test binaries the verifier reports test-only", result.json.get("test_only") is True)
    fixtures.check(checks, "injected (verifier)")
    records = fixtures.records("git")
    temps = {env.get("TMPDIR") for env in records}
    checks("injected: the verifier's git runs used its own temporary directory, now gone",
           temps and all(re.fullmatch(re.escape(os.path.realpath(case.home)) +
                                      r"/\.cache/olddonkey-loop/verify/[0-9]+-[0-9a-f]{16}", t or "")
                         and not os.path.exists(t) for t in temps), temps)
    # A lineage a test seam touched stays non-authorizing once every seam is
    # cleared: its class comes from the pinned file:// remote, forever.
    cleared = {"LOOP_AUTHORITY_TEST": None, "LOOP_AUTHORITY_TEST_BIN_DIR": None}
    status = case.status(env=cleared)
    independent = case.verifier(env=cleared)
    checks("test seams: with LOOP_AUTHORITY_TEST and the binary override cleared, the lineage made under them "
           "is still test-only with no current authorization (writer and verifier)",
           status.json.get("state") == "committed" and status.json.get("test_only") is True
           and status.json.get("current_authorization") is False
           and independent.json.get("test_only") is True
           and independent.json.get("current_authorization") is False, (status, independent))


def j_decoys(checks):
    case = Case("decoys")
    fixtures = Fixtures(case)
    scratch_parent = os.path.join(case.home, ".cache", "olddonkey-loop", "anchor-scratch")
    os.makedirs(scratch_parent)
    siblings = []
    for name in ("1-0000000000000000.git", "99999-aaaaaaaaaaaaaaaa.git", f"{os.getpid()}-bbbbbbbbbbbbbbbb.git"):
        path = os.path.join(scratch_parent, name)
        git("init", "--bare", "-q", path)
        with open(os.path.join(path, "config"), "a") as handle:
            handle.write(f"[url \"file://{fixtures.decoy}\"]\n\tinsteadOf = {case.url}\n"
                         f"\tpushInsteadOf = {case.url}\n[credential]\n\thelper = !{fixtures.marker} sibling\n")
        siblings.append(path)
    sibling_before = [tree_digest(path) for path in siblings]
    repo = os.path.join(case.dir, "workdir")
    git("init", "-q", repo)
    with open(os.path.join(repo, ".git", "config"), "a") as handle:
        handle.write(f"[url \"file://{fixtures.decoy}\"]\n\tinsteadOf = {case.url}\n\tpushInsteadOf = {case.url}\n")
    result = case.genesis(cwd=repo)
    checks("decoys: genesis from inside a repository that rewrites the pinned URL succeeds", result.rc == 0, result)
    result = case.ceremony("rotate", cwd=repo)
    checks("decoys: rotation from inside that repository succeeds", result.rc == 0, result)
    result = case.verifier(cwd=repo)
    checks("decoys: the verifier from inside that repository verifies the pinned remote",
           result.rc == 0 and result.json.get("state") == "committed", result)
    checks("decoys: the push and fetches reached only the pinned remote (the decoy is untouched)",
           git("--git-dir", fixtures.decoy, "for-each-ref").stdout == b"" and case.tip() is not None)
    checks("decoys: the pre-existing sibling scratch repositories were never used",
           [tree_digest(path) for path in siblings] == sibling_before and not os.listdir(fixtures.markers))


def j_test_class(checks):
    case = committed_case("test-class")
    fork = case.fork("test-class-rotation-remote")
    lineage = Lineage(fork)
    body = rotation_body(lineage, remote="file:///elsewhere/anchor.git")
    frame_bytes, _d, _p = lineage.forge("epoch.rotated", body)
    fork.write(fork.log_path(), lineage.data + frame_bytes)
    writer, independent = fork.agree(checks, "test class: a rotation record naming a remote other than the "
                                     "pinned one is refused by the writer and the verifier", "quarantined")
    checks("test class: the refusal is the remote rule (record-remote) for both",
           writer.json.get("rule") == "record-remote" and independent.json.get("rule") == "record-remote",
           (writer, independent))
    lineage = Lineage(case)
    body = dict(lineage.payloads[0]["body"], anchor_class="production")
    frame_bytes, digest, _p = lineage.forge("store.genesis", body, seq=1, prev=None, epoch=1)
    case.write(case.log_path(), frame_bytes)
    active = {"store_id": lineage.store_id, "generation": 1, "genesis_digest": digest, "seq": 1,
              "record_digest": digest, "epoch": 1, "key_id": lineage.epochs[1]["root_key_id"]}
    remote_commit(case, lineage.pointer(active), None)
    independent = case.verifier()
    checks("test class: a record claiming anchor_class production with a file:// remote is refused by the verifier",
           independent.json.get("state") == "quarantined", independent)
    case.agree(checks, "test class: the writer refuses it too", "quarantined")


def j_ssh(checks):
    case = Case("ssh")
    fixtures = Fixtures(case)
    control_markers = os.path.join(case.dir, "control-markers")
    os.makedirs(control_markers)
    control_marker = os.path.join(case.dir, "control-marker.sh")
    with open(control_marker, "w") as handle:
        handle.write(f"#!/bin/bash\necho \"$*\" > '{control_markers}'/\"$1\"\nexit 0\n")
    os.chmod(control_marker, 0o755)

    def config(marker):
        return (f"Match exec \"{marker} match-exec\"\n  User matched-by-exec\n"
                f"Host *\n  ProxyCommand {marker} proxy-command %h\n")

    control = os.path.join(case.dir, "control_ssh_config")
    with open(control, "w") as handle:
        handle.write(config(control_marker))
    os.makedirs(os.path.join(case.home, ".ssh"), mode=0o700)
    with open(os.path.join(case.home, ".ssh", "config"), "w") as handle:
        handle.write(config(fixtures.marker.replace("marker.sh", "marker-ok.sh")))
    shutil.copy(fixtures.marker, fixtures.marker.replace("marker.sh", "marker-ok.sh"))
    with open(fixtures.marker.replace("marker.sh", "marker-ok.sh"), "w") as handle:
        handle.write(f"#!/bin/bash\necho \"$*\" > '{fixtures.markers}'/\"$1\"\nexit 0\n")
    result = subprocess.run([SSH, "-G", "-F", control, "x"], capture_output=True,
                            env={"HOME": case.home, "PATH": ":".join(BIN_DIRS)})
    shown = result.stdout.decode().lower()
    checks("ssh: positive control -- ssh -G with that config shows the ProxyCommand and the Match exec effect",
           "proxycommand" in shown and "user matched-by-exec" in shown
           and os.path.exists(os.path.join(control_markers, "match-exec")), shown[:300])
    url = "git@127.0.0.1:x.git"
    env = fixtures.env()
    result = case.ceremony("genesis", "--remote", url, env=env)
    checks("test seams: with LOOP_AUTHORITY_TEST_BIN_DIR a genesis of a production (SSH) remote is refused "
           "before any key, intent, or remote contact", result.rc == 9 and "test-binaries" in result.out
           and not os.path.exists(case.auth("genesis.intent"))
           and not (os.path.isdir(case.auth("stores")) and os.listdir(case.auth("stores")))
           and not fixtures.records("ssh-keygen") and not fixtures.records("git"), result)
    result = case.ceremony("genesis", "--remote", url, env=fixtures.env(bins=False))
    checks("ssh: a genesis pinned to git@127.0.0.1:x.git fails to push and leaves the store pending",
           result.rc == 5, result)
    status = case.status(env=env)
    checks("ssh: status reports the pending genesis (A2.3 row 4) with no current authorization",
           status.json.get("state") == "genesis-pending" and status.json.get("table") == "A2.3 row 4"
           and status.json.get("current_authorization") is False and status.json.get("test_only") is True,
           status)
    result = case.writer("recover", env=env)
    checks("test seams: recovery of a production lineage with LOOP_AUTHORITY_TEST_BIN_DIR is refused",
           result.rc == 9 and "test-binaries" in result.err, result)
    independent = case.verifier(env=env)
    checks("ssh: the verifier's fetch fails and it reports pending", independent.json.get("state") ==
           "genesis-pending", independent)
    checks("ssh: the ProxyCommand and Match exec markers were never written", not os.listdir(fixtures.markers),
           os.listdir(fixtures.markers))
    ssh_records = [r for r in fixtures.records("ssh")
                   if "/.cache/olddonkey-loop/tmp/" in (r.get("TMPDIR") or "")]
    temps = {env.get("TMPDIR") for env in ssh_records}
    checks("temporary files: the ssh wrapper recorded TMPDIR equal to the writer's scratch directory, now gone",
           ssh_records and all(re.fullmatch(re.escape(os.path.realpath(case.home)) +
                                            r"/\.cache/olddonkey-loop/tmp/[0-9]+-[0-9a-f]{16}", t or "")
                               and not os.path.exists(t) for t in temps), temps)
    injected = fixtures.env()
    leaked = sorted({key for env in ssh_records for key in INJECTED if key in env and env[key] == injected[key]})
    checks("ssh: the ssh wrapper (a child of git) recorded none of the injected values", not leaked, leaked)


def j_https(checks):
    import http.server
    import ssl

    case = Case("https")
    fixtures = Fixtures(case)
    cert, key = os.path.join(case.dir, "tls.crt"), os.path.join(case.dir, "tls.key")
    made = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                           "-days", "2", "-subj", "/CN=127.0.0.1"], capture_output=True)
    checks("https: the fixture minted a self-signed certificate (openssl)", made.returncode == 0, made.stderr[-300:])
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            requests.append(self.path)
            self.send_response(404)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"https://127.0.0.1:{server.server_address[1]}/x.git"
        for label, env in (("plain", {}), ("with GIT_SSL_NO_VERIFY=1 and http.sslVerify=false injected",
                                           fixtures.env(bins=False))):
            sub = Case(f"https-{label[:5]}")
            if env:
                shutil.copy(os.path.join(case.home, ".gitconfig"), os.path.join(sub.home, ".gitconfig"))
            result = sub.ceremony("genesis", "--remote", url, env=env)
            checks(f"https ({label}): genesis fails certificate verification and the store stays pending",
                   result.rc == 5, result)
            independent = sub.verifier(env=env)
            checks(f"https ({label}): the verifier's fetch fails certificate verification (pending)",
                   independent.json.get("state") == "genesis-pending", independent)
        checks("https: no HTTP request ever got past the TLS handshake", not requests, requests)
    finally:
        server.shutdown()


def j_tempfiles(checks):
    case = Case("tempfiles")
    fixtures = Fixtures(case)
    env = {"TMPDIR": case.auth(), "LOOP_AUTHORITY_TEST_BIN_DIR": fixtures.bin}

    def listing():
        return sorted(os.path.relpath(os.path.join(r, n), case.auth()) for r, _d, files in os.walk(case.auth())
                      for n in files)

    result = case.genesis(env=env)
    checks("temporary files: genesis with TMPDIR inside the authority directory succeeds", result.rc == 0, result)
    store_id = case.active()["store_id"]
    kd1 = os.listdir(os.path.join(case.store_dir(), "keys"))[0]
    keys1 = sorted(f"stores/{store_id}/keys/{kd1}/{n}" for n in
                   ["root", "root.pub"] + [f"{t}{s}" for t in TYPES for s in ("", ".pub", "-cert.pub")])
    expected = sorted(["active", "lock", f"stores/{store_id}/cursor",
                       f"stores/{store_id}/log/segment-000001.olf"] + keys1)
    checks("temporary files: after genesis the authority directory holds exactly the files the sinks wrote",
           listing() == expected, sorted(set(listing()) ^ set(expected))[:8])
    result = case.ceremony("rotate", env=env)
    checks("temporary files: rotation with TMPDIR inside the authority directory succeeds", result.rc == 0, result)
    kd2 = [d for d in os.listdir(os.path.join(case.store_dir(), "keys")) if d != kd1][0]
    expected2 = sorted(expected + [k.replace(kd1, kd2) for k in keys1])
    checks("temporary files: after rotation the authority directory holds exactly the files the sinks wrote",
           listing() == expected2, sorted(set(listing()) ^ set(expected2))[:8])
    crashed(case, "after-frame-fsync", "revoke", "--epoch", "1")
    result = case.writer("recover", env=env)
    checks("temporary files: recovery with TMPDIR inside the authority directory succeeds",
           result.json.get("state") == "committed", result)
    checks("temporary files: after recovery the authority directory holds exactly the files the sinks wrote",
           listing() == expected2, sorted(set(listing()) ^ set(expected2))[:8])
    pattern = re.escape(os.path.realpath(case.home)) + r"/\.cache/olddonkey-loop/tmp/[0-9]+-[0-9a-f]{16}"
    for name in ("git", "ssh-keygen"):
        temps = {r.get("TMPDIR") for r in fixtures.records(name)}
        checks(f"temporary files: the {name} wrapper recorded TMPDIR equal to the writer's scratch directory, "
               "which is gone afterwards", temps and all(re.fullmatch(pattern, t or "") and not os.path.exists(t)
                                                        for t in temps), temps)


def j_seam(checks):
    for label, env, expect in (("without LOOP_AUTHORITY_TEST=1 the crash point is not honoured",
                                {"LOOP_AUTHORITY_CRASH_AT": "after-push", "LOOP_AUTHORITY_TEST": None}, 0),
                               ("with LOOP_AUTHORITY_TEST=1 the crash point is honoured",
                                {"LOOP_AUTHORITY_CRASH_AT": "after-push"}, 137)):
        case = committed_case(f"seam-{expect}", rotate=True)
        crashed(case, "after-frame-fsync", "revoke", "--epoch", "1")
        result = case.writer("recover", env=env)
        checks(f"seam: {label}", result.rc == expect, result)
    case = committed_case("seam-refusals")
    before, remote_before = case.snapshot(), case.remote_snapshot()
    result = case.ceremony("revoke", "--epoch", "1", env={"LOOP_AUTHORITY_CRASH_AT": "frame-byte-999999"})
    checks("seam: a frame-byte-<n> outside the frame being written is refused", result.rc == 4
           and "crash-point" in result.out, result)
    result = case.ceremony("rotate", env={"LOOP_AUTHORITY_CRASH_AT": "not-a-point"})
    checks("seam: an unknown crash point is refused", result.rc == 4 and "crash-point" in result.out, result)
    result = case.ceremony("revoke", "--epoch", "1", env={"LOOP_AUTHORITY_CRASH_AT": "key-step-1"})
    checks("seam: a key step beyond the ceremony's key steps is refused", result.rc == 4, result)
    result = case.writer("ceremony", "revoke", "--epoch", "1", env={"LOOP_AUTHORITY_CRASH_AT": "after-intent-fsync"})
    checks("seam: with LOOP_AUTHORITY_TEST=1 and a crash point, a ceremony without a TTY is still refused",
           result.rc == 11, result)
    unchanged(checks, "seam refusals", case, before, remote_before)


DORMANT_ROWS = ("request-opening", "capability-issuance", "request-cancellation", "request-expiry",
                "capability-redemption", "repository-registration", "repository-rebind",
                "execution-root-registration", "standing-authorization", "standing-revocation",
                "segment-discharge", "enrollment", "enrollment-revocation", "mechanism-closure",
                "acceptance-platform-designation", "release-acceptance", "gesture-nonce-issuance")


def j_dormant(checks):
    fresh = Case("dormant-fresh")
    result = fresh.writer("submit", "request-opening")
    checks("dormant: a dormant row is refused before the authority directory is even created",
           result.rc == 8 and not os.path.exists(fresh.auth()), result)
    case = committed_case("dormant")
    before, remote_before = case.snapshot(), case.remote_snapshot()
    errors = set()
    for row in DORMANT_ROWS:
        result = case.writer("submit", row)
        match = re.search(r"error: (dormant-row:[a-z-]+):", result.err)
        errors.add(match.group(1) if match else None)
        checks(f"dormant: {row} is refused with its distinct error", result.rc == 8 and match
               and match.group(1) == f"dormant-row:{row}", result)
    checks("dormant: every dormant row has a different error", len(errors) == len(DORMANT_ROWS))
    result = case.writer("submit", "approval.consume")
    checks("dormant: approval.consume is refused with its own error", result.rc == 10
           and "approval-consume-refused" in result.err, result)
    for row in ("torn-frame-truncation", "anchor-replay-forward", "recovery-tidy", "store-quarantine",
                "authority-head-advance"):
        result = case.writer("submit", row)
        checks(f"dormant: derived row {row} has no external entry point (X7)", result.rc == 4
               and "exclusion-X7" in result.err, result)
    for row in ("authority-genesis", "epoch-rotation", "epoch-revocation", "linked-regenesis"):
        result = case.writer("submit", row)
        checks(f"dormant: ceremony row {row} is admitted only by the operator ceremony (X6)", result.rc == 4
               and "exclusion-X6" in result.err, result)
    unchanged(checks, "dormant rows and approval.consume", case, before, remote_before)


def g_pointerreadback(argv):
    home, url, path = argv[0], argv[1], argv[2]
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    m = load_lib(home)
    store, tools = m["store"], m["tools"]
    tools.pin_remote(tools.parse_remote(url, allow_test=True))
    spec = json.loads(open(path).read())
    remote_path = url[len("file://"):]
    token = store.begin("epoch-revocation", PRINCIPAL)
    for item in spec["items"]:
        git("--git-dir", remote_path, "update-ref", ANCHOR_REF, item["commit"])
        scratch = tools.new_scratch_repo()
        ok, code = refused(lambda item=item, scratch=scratch: store.readback(
            token, scratch=scratch, commit=item["commit"], anchor_json=bytes.fromhex(item["anchor"]),
            expected_parent=item["parent"], root_pub=spec["root_pub"]), "readback")
        emit(f"pointer: the writer's readback refuses a pointer {item['label']}", ok, code)
    git("--git-dir", remote_path, "update-ref", ANCHOR_REF, spec["tip"])
    tools.cleanup()


def g_starttimerefusal(argv):
    """Run under a pty: the TTY check passes, the start time is unreadable."""
    home, url = argv[0], argv[1]
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    m = load_lib(home)
    ceremony, store = m["ceremony"], m["store"]

    def unreadable(pid):
        raise ceremony.StartTokenError("start time unreadable (test fixture)")

    ceremony.read_start_time = unreadable
    ok, code = refused(lambda: ceremony.run("genesis", {"remote": url, "epoch": None}), "start-token")
    emit("start tokens: an unreadable start time refuses the ceremony (stdin and stdout on a pty)",
         ok and os.isatty(0) and os.isatty(1), code)
    emit("start tokens: the refused ceremony created nothing", not os.path.exists(store.root()))


INPROC["pointerreadback"] = g_pointerreadback
INPROC["starttimerefusal"] = g_starttimerefusal


def j_pointer_variants(checks):
    case = committed_case("pointer-variants", rotate=True)
    lineage = Lineage(case)
    tip = case.tip()
    parent = case.parent_of(tip)
    active = lineage.ptr(2)
    signed = canon({"active": active, "prev_generation": None})
    root1, root2 = os.path.join(lineage.keydir(1), "root"), os.path.join(lineage.keydir(2), "root")

    def anchor_with(sig, shown=None):
        return canon({"active": shown or active, "prev_generation": None, "sig": sig})

    variants = {
        "signed by another epoch's root": anchor_with(lineage.sign(root1, POINTER_NS, signed)),
        "signed by a subkey": anchor_with(lineage.sign(os.path.join(lineage.keydir(2), "epoch.rotated-cert.pub"),
                                                       POINTER_NS, signed)),
        "signed under a record namespace": anchor_with(lineage.sign(
            root2, "olddonkey-loop.authority.epoch.rotated.v1", signed)),
        "whose {active, prev_generation} bytes were altered after signing": anchor_with(
            lineage.sign(root2, POINTER_NS, signed), dict(active, record_digest=D({"altered": 1}))),
    }
    items = []
    for label, anchor_json in variants.items():
        oid = remote_commit(case, anchor_json, parent)
        writer, _v = case.agree(checks, f"pointer: a pointer {label} is refused on recovery", "quarantined")
        checks(f"pointer ({label}): refused at the signature check (A1.2 step 3), not as a fork",
               writer.json.get("table") == "A1.2 step 3", writer)
        items.append({"label": label, "commit": oid, "anchor": anchor_json.hex(), "parent": parent})
    case.set_tip(tip)
    case.agree(checks, "pointer: a pointer signed by the active root verifies (genuine tip restored)", "committed")
    path = os.path.join(case.dir, "variants.json")
    with open(path, "w") as handle:
        json.dump({"items": items, "root_pub": lineage.epochs[2]["root_pub"], "tip": tip}, handle)
    for item in inproc("pointerreadback", case.home, case.url, path):
        checks(*item)


def j_start_time_refusal(checks):
    case = Case("start-time-refusal")
    env = dict(case.env, PATH=os.environ.get("PATH", ":".join(BIN_DIRS)), TMPDIR=os.environ.get("TMPDIR", "/tmp"))
    result = run_on_pty([sys.executable, __file__, "inproc", "starttimerefusal", SCRIPTS, LIB, TMP, case.home,
                         case.url], env, case.dir, answer=None)
    lines = [line.split("\t") for line in result.out.split("\n")]
    items = [(parts[1], parts[0] == "ok", parts[2] if len(parts) > 2 else "") for parts in lines
             if parts[0] in ("ok", "not ok") and len(parts) > 1]
    checks("start tokens: the pty harness reported its checks", len(items) == 2, result)
    for item in items:
        checks(*item)


# --- the activation boundary (A2.1, A2.6) ----------------------------------------------

NOT_ADMITTED = ("request.opened", "request.cancelled", "request.expired", "request.redeemed", "nonce.issued",
                "repo.registered", "repo.rebound", "exec-root.registered", "standing.granted", "standing.revoked",
                "entry.enrolled", "entry.revoked", "platform.designated")


def displayed_envelope(result):
    match = re.search(r"^envelope: (\{.*\})$", result.out, re.M)
    try:
        return json.loads(match.group(1)) if match else None
    except ValueError:
        return None


def display_matches(checks, label, result, body):
    """The PTY-captured display shows the activation boundary, equal to the
    sealed introducer's, and is exactly the envelope the record seals."""
    shown = displayed_envelope(result)
    params = (shown or {}).get("parameters", {})
    sealed = {k: body.get(k) for k in ("registry_version", "admitted_protocols")}
    checks(f"{label}: the ceremony display shows registry_version tg-v1.0a and admitted_protocols [], equal to "
           "the sealed introducer's", shown is not None and params.get("registry_version") == "tg-v1.0a"
           and params.get("admitted_protocols") == [] and sealed == {"registry_version": "tg-v1.0a",
                                                                      "admitted_protocols": []}, (params, sealed))
    checks(f"{label}: the displayed envelope is the one sealed (its digest is the record's envelope_digest)",
           shown is not None and D(shown) == body.get("envelope_digest"))


def j_display(checks):
    case = Case("display")
    result = case.genesis()
    checks("display: genesis succeeds", result.rc == 0, result)
    display_matches(checks, "genesis", result, Lineage(case).payloads[0]["body"])
    result = case.ceremony("rotate")
    checks("display: rotation succeeds", result.rc == 0, result)
    display_matches(checks, "rotation", result, Lineage(case).payloads[1]["body"])


def rotation_body(lineage, **changes):
    """A schema-valid epoch.rotated body for the next epoch (reusing the
    current epoch's keys, which only later rules refuse), with changes."""
    current = lineage.epochs[lineage.active_epoch]
    epoch = max(lineage.epochs) + 1
    body = {"ceremony": "rotate", "envelope_digest": D({"x": 1}), "principal": PRINCIPAL,
            "remote": lineage.payloads[0]["body"]["remote"], "from_epoch": lineage.active_epoch, "epoch": epoch,
            "key_dir": f"epoch-{epoch}-" + "c" * 16, "root_pub": current["root_pub"],
            "root_key_id": current["root_key_id"], "subkeys": current["subkeys"],
            "registry_version": "tg-v1.0a", "admitted_protocols": []}
    body.update(changes)
    return body


def j_boundary(checks):
    case = committed_case("boundary")
    for label, changes, rule in (
            ("a nonempty admitted_protocols (a premature future protocol)", {"admitted_protocols": ["request-v1"]},
             "introducer-protocols"),
            ("an unknown registry_version", {"registry_version": "tg-v9"}, "introducer-version")):
        fork = case.fork(f"boundary-{rule}")
        lineage = Lineage(fork)
        frame_bytes, _d, _p = lineage.forge("epoch.rotated", rotation_body(lineage, **changes))
        fork.write(fork.log_path(), lineage.data + frame_bytes)
        writer, independent = fork.agree(checks, f"activation boundary: a validly sealed rotation with {label} is "
                                         "refused by the writer and the verifier", "quarantined")
        checks(f"activation boundary: the rotation with {label} is refused as {rule} by both",
               writer.json.get("rule") == rule and independent.json.get("rule") == rule, (writer, independent))
        fork = case.fork(f"boundary-genesis-{rule}")
        lineage = Lineage(fork)
        body = dict(lineage.payloads[0]["body"], **changes)
        frame_bytes, _d, _p = lineage.forge("store.genesis", body, seq=1, prev=None, epoch=1)
        fork.write(fork.log_path(), frame_bytes)
        writer, independent = fork.agree(checks, f"activation boundary: a validly sealed genesis record with {label} "
                                         "is refused by the writer and the verifier", "quarantined")
        checks(f"activation boundary: the genesis record with {label} is refused as {rule} by both",
               writer.json.get("rule") == rule and independent.json.get("rule") == rule, (writer, independent))


def j_type_admission(kind):
    def job(checks):
        case = committed_case(f"admission-{kind}")
        lineage = Lineage(case)
        # sealed with the store's own certified subkey for the type; a body that
        # would fail every body schema too
        frame_bytes, _d, _p = lineage.forge(kind, {"not": "a schema-valid body"})
        case.write(case.log_path(), lineage.data + frame_bytes)
        writer, independent = case.agree(checks, f"type admission: a validly sealed {kind} record is refused by the "
                                         "writer and the verifier", "quarantined")
        checks(f"type admission: {kind} is refused as type-not-admitted (decided before the body schema) by both",
               writer.json.get("rule") == "type-not-admitted"
               and independent.json.get("rule") == "type-not-admitted", (writer, independent))
        if kind == "nonce.issued":
            result = case.writer("recover")
            status = case.status()
            checks("type admission: a store holding a non-admitted record is quarantined (marker rule "
                   "type-not-admitted)", result.json.get("state") == "quarantined"
                   and status.json.get("rule") == "type-not-admitted", (result, status))
    return job


def j_recovery_after_delimiter(variant):
    def job(checks):
        if variant == "rotation":
            case = committed_case("after-delimiter")
            base_log = case.read(case.log_path())
            probes = itertools.count()

            def probe_size():
                probe = case.fork(f"after-delimiter-probe-{next(probes)}")
                crashed(probe, "after-intent-fsync", "rotate")
                return len(frame_of_intent(probe.intent()))

            result, intent = last_byte_crash(case, ("rotate",), probe_size, case.intent)
            full = frame_of_intent(intent)

            def log_of():
                return case.log_path()
        else:
            case, result, intent = genesis_last_byte("after-delimiter-g")
            full = frame_of_intent(intent)
            base_log = b""

            def log_of():
                return case.log_path(intent["store_id"])
        label = f"recovery-after-delimiter ({variant})"
        checks(f"{label}: the last-byte crash left every byte but the final newline",
               result.rc == 137 and case.read(log_of()) == base_log + full[:-1], result)
        tip = case.tip()
        result = case.writer("recover", env={"LOOP_AUTHORITY_CRASH_AT": "recovery-after-delimiter"})
        checks(f"{label}: recovery crashed after the completed delimiter was durable and before the push",
               result.rc == 137 and case.read(log_of()) == base_log + full and case.tip() == tip, result)
        writer, _v = case.agree(checks, f"{label}, crashed", "pending" if variant == "rotation" else "genesis-pending",
                                "anchor-replay-forward")
        wanted = "A1.2 R = ptr(L - 1) with intent" if variant == "rotation" else "A2.3 row 8"
        checks(f"{label}: now the frame is complete and the replay-forward is plain ({wanted})",
               writer.json.get("table") == wanted, writer)
        result = case.writer("recover")
        checks(f"{label}: recovery then pushes the intent's exact commit and commits",
               result.json.get("state") == "committed" and case.tip() == intent["anchor_commit"], result)
    return job


def j_missing_dir(kind):
    """A missing intent-named directory never reads as frame 1 "none" (A2.3
    row 1): nothing ever removes it -- abandonment only removes the intent
    -- so without it nothing shows frame 1 was never durable. Writer and
    verifier fail closed; recovery mutates nothing."""
    def job(checks):
        if kind in ("genesis-none", "genesis-valid", "genesis-pushed"):
            point = {"genesis-none": "genesis-step-2", "genesis-valid": "genesis-step-3",
                     "genesis-pushed": "genesis-step-4"}[kind]
            case = gcrash(f"missing-{kind}", point)
            if kind == "genesis-pushed":
                case.set_tip(None)  # the pushed genesis commit, deleted with the ref
            shutil.rmtree(case.store_dir(case.genesis_intent()["store_id"]))
            state, table = "genesis-invalid", "A2.3 row 1"
        else:
            case = quarantined_case("missing-regen")
            crashed(case, "regenesis-step-1", "regenesis")
            new_id = json.loads(case.read(case.auth("regenesis.intent")))["new_store_id"]
            shutil.rmtree(case.auth("stores", new_id))
            state, table = "regenesis-invalid", "A1.3 intent"
        before, remote_before = case.snapshot(), case.remote_snapshot()
        writer, independent = case.agree(checks, f"missing intent-named directory ({kind})", state)
        checks(f"missing intent-named directory ({kind}): {table} for the writer and the verifier, no row",
               writer.json.get("table") == table and independent.json.get("table") == table
               and writer.json.get("row") is None and independent.json.get("row") is None, (writer, independent))
        result = case.writer("recover")
        checks(f"missing intent-named directory ({kind}): recovery fails closed ({state})",
               result.json.get("state") == state, result)
        unchanged(checks, f"missing intent-named directory ({kind})", case, before, remote_before)
    return job


def j_envelope_digest(kind):
    """A validly sealed epoch.rotated / epoch.revoked record whose
    envelope_digest is not a sha256: digest is refused by the writer and the
    independent verifier alike -- even anchored, with its key directory
    published -- while the same forged record with a well-formed digest is
    accepted by both (the control that makes each vector discriminate)."""
    def job(checks):
        case = committed_case(f"envelope-{kind}", rotate=kind == "revocation")
        lineage = Lineage(case)
        base_log, base_tip = lineage.data, case.tip()
        if kind == "rotation":
            # epoch 2 reuses epoch 1's keys, re-certified as <type>@e2 by the same root
            old = lineage.keydir(1)
            new = os.path.join(lineage.dir, "keys", "epoch-2-" + "c" * 16)
            os.mkdir(new, 0o700)
            for name in ["root", "root.pub"] + [f"{t}{s}" for t in TYPES for s in ("", ".pub")]:
                shutil.copyfile(os.path.join(old, name), os.path.join(new, name))
                os.chmod(os.path.join(new, name), 0o600)
            for kind_name in TYPES:
                ssh_keygen("-q", "-s", os.path.join(old, "root"), "-I", f"{kind_name}@e2", "-n", kind_name,
                           "-V", "always:forever", os.path.join(new, f"{kind_name}.pub"))
                os.chmod(os.path.join(new, f"{kind_name}-cert.pub"), 0o600)
            record, root, key_id = "epoch.rotated", os.path.join(old, "root"), lineage.epochs[1]["root_key_id"]
        else:
            record, root, key_id = ("epoch.revoked", os.path.join(lineage.keydir(2), "root"),
                                    lineage.epochs[2]["root_key_id"])

        def anchored(digest):
            if kind == "rotation":
                body = rotation_body(lineage, envelope_digest=digest)
            else:
                body = dict(lineage.revoke_body(1, "verify-only"), envelope_digest=digest)
            frame_bytes, record_digest, _p = lineage.forge(record, body)
            case.write(case.log_path(), base_log + frame_bytes)
            active = {"store_id": lineage.store_id, "generation": 1, "genesis_digest": lineage.frames[0]["digest"],
                      "seq": lineage.L + 1, "record_digest": record_digest, "epoch": 2, "key_id": key_id}
            remote_commit(case, lineage.pointer(active, key_path=root), base_tip)

        anchored(D({"well": "formed"}))
        case.agree(checks, f"envelope_digest ({kind}): the forged record with a well-formed digest, anchored, is "
                   "accepted by both (control)", "committed")
        for label, value in (("not hex", "sha256:" + "g" * 64), ("too short", "sha256:" + "ab" * 31),
                             ("an upper-case prefix", "SHA256:" + "ab" * 32), ("an integer", 12345)):
            anchored(value)
            writer, independent = case.agree(checks, f"envelope_digest ({kind}): a validly sealed, anchored record "
                                             f"whose envelope_digest is {label}", "quarantined")
            checks(f"envelope_digest ({kind}, {label}): both refuse the record itself (A1.6 complete-but-invalid "
                   "frame, a schema rule)", writer.json.get("table") == independent.json.get("table")
                   == "A1.6 complete-but-invalid frame" and writer.json.get("rule") == "record-schema"
                   and independent.json.get("rule") == "schema", (writer, independent))
        case.write(case.log_path(), base_log)
        case.set_tip(base_tip)
        case.agree(checks, f"envelope_digest ({kind}): the original log and tip restored", "committed")
    return job


def j_regenesis_from(variant):
    """Linked re-genesis from a store quarantined for a complete invalid
    frame or a nonconforming tail: the new generation classifies committed
    with the archived ancestor's valid prefix verified and its discarded
    tail kept as evidence."""
    def job(checks):
        case = committed_case(f"regen-from-{variant}", rotate=True)
        lineage = Lineage(case)
        if variant == "invalid-frame":
            frame_bytes, _d, _p = lineage.forge("epoch.revoked", lineage.revoke_body(1, "verify-only"))
            content = parse_frames(frame_bytes)[0][0]["content"].replace(b'"prior_state":"verify-only"',
                                                                          b'"prior_state":"verify-onlx"', 1)
            tail = mkframe(3, "epoch.revoked", content)
        else:
            tail = b"a nonconforming tail, not a frame"
        case.write(case.log_path(), lineage.data + tail)
        old_id = case.active()["store_id"]
        case.agree(checks, f"re-genesis from {variant}: the store is quarantined", "quarantined")
        case.writer("recover")
        result = case.ceremony("regenesis")
        checks(f"re-genesis from {variant}: the ceremony succeeds", result.rc == 0, result)
        case.agree(checks, f"re-genesis from {variant}: the new generation is committed (writer and verifier), not "
                   "active-invalid", "committed")
        archived = case.read(os.path.join(case.auth("archive", old_id), "log", "segment-000001.olf"))
        checks(f"re-genesis from {variant}: the archive keeps the discarded tail as evidence",
               archived == lineage.data + tail)
        new_body = Lineage(case).payloads[0]["body"]
        checks(f"re-genesis from {variant}: the record's quarantine evidence names the ancestor's valid prefix",
               new_body["quarantined"] == {"last_seq": 2, "last_record_digest": lineage.frames[1]["digest"]},
               new_body["quarantined"])
        fork = case.fork(f"regen-from-{variant}-no-marker")
        marker = os.path.join(fork.auth("archive", old_id), "quarantine")
        os.chmod(fork.auth("archive", old_id), 0o700)
        os.unlink(marker)
        os.chmod(fork.auth("archive", old_id), 0o500)
        fork.agree(checks, f"re-genesis from {variant}: an archived ancestor without its quarantine marker does not "
                   "verify", "active-invalid")
    return job


def j_regenesis_forged_old(checks):
    """A re-genesis intent (validly sealed with the new store's keys) whose
    recorded old commit carries the old store's pointer bytes but is not a
    valid chain: abandonment is decided only after fetching and verifying
    that commit and its chain, so nothing is minted and both stores stay."""
    case = quarantined_case("regen-forged-old")
    crashed(case, "regenesis-step-1", "regenesis")
    path = case.auth("regenesis.intent")
    intent = json.loads(case.read(path))
    old_commit = intent["old_commit"]
    forged_old = remote_commit(case, case.anchor_json_at(old_commit), None, set_tip=False)
    payload = json.loads(parse_frames(frame_of_intent(intent))[0][0]["content"])["payload"]
    payload["body"]["prev_commit"] = forged_old
    keydir = os.path.join(case.auth("stores", intent["new_store_id"]), "keys", intent["key_dir"])
    sig = ssh_keygen("-Y", "sign", "-f", os.path.join(keydir, "store.regenesis-cert.pub"), "-n",
                     "olddonkey-loop.authority.store.regenesis.v1", stdin=canon(payload)).stdout.decode()
    frame_bytes = mkframe(1, "store.regenesis", canon({"payload": payload, "sig": sig}))
    digest = fdigest(1, "store.regenesis", canon({"payload": payload, "sig": sig}))
    pointer = json.loads(intent["anchor_json"])
    active = dict(pointer["active"], genesis_digest=digest, record_digest=digest)
    psig = ssh_keygen("-Y", "sign", "-f", os.path.join(keydir, "root"), "-n", POINTER_NS,
                      stdin=canon({"active": active, "prev_generation": pointer["prev_generation"]})).stdout.decode()
    anchor_json = canon({"active": active, "prev_generation": pointer["prev_generation"], "sig": psig})
    forged = dict(intent, old_commit=forged_old, expected_parent=forged_old, digest=digest,
                  length=len(canon({"payload": payload, "sig": sig})), frame_length=len(frame_bytes),
                  frame_b64=base64.b64encode(frame_bytes).decode(), anchor_json=anchor_json.decode(),
                  anchor_commit=expected_commit(anchor_json, forged_old))
    case.write(path, canon(forged))
    case.set_tip(forged_old)
    before = case.snapshot()
    writer, _v = case.agree(checks, "A1.3: a recorded old commit whose chain does not verify", "regenesis-quarantined")
    checks("A1.3: the intent itself validates; it is the recorded old commit that fails content verification",
           "anchor" in writer.json.get("detail", "") or "chain" in writer.json.get("detail", ""), writer)
    result = case.writer("recover")
    checks("A1.3: no abandonment token is minted on the old ref's object id alone (fail closed)",
           result.json.get("state") == "regenesis-quarantined" and result.json.get("row") is None, result)
    unchanged(checks, "A1.3 forged old commit: both stores and the intent", case, before)


def j_cache_symlink(checks):
    """Nothing writes through a symlinked $HOME/.cache component: every
    entry point establishes its scratch path with O_NOFOLLOW first."""
    case = committed_case("cache-symlink")
    cache = os.path.join(case.home, ".cache")
    for label, link in ((".cache", cache), (".cache/olddonkey-loop", os.path.join(cache, "olddonkey-loop"))):
        shutil.rmtree(cache, ignore_errors=True)
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(case.auth(), link)
        before = case.snapshot()
        results = {"status": case.writer("status"), "verify": case.writer("verify"),
                   "recover": case.writer("recover"), "verifier": case.verifier(), "ceremony": case.ceremony("rotate")}
        checks(f"scratch path: with {label} a symlink to the authority directory, every entry point refuses "
               "(exit 9)", all(r.rc == 9 for r in results.values()),
               {k: (r.rc, (r.err or r.out)[-160:]) for k, r in results.items()})
        unchanged(checks, f"scratch path: {label} symlinked", case, before)
        checks(f"scratch path: with {label} symlinked, nothing was created through it",
               not any(os.path.lexists(case.auth(n)) for n in ("tmp", "verify", "anchor-scratch", "olddonkey-loop")))
        os.unlink(link)
    shutil.rmtree(cache, ignore_errors=True)
    case.agree(checks, "scratch path: with a real cache directory again", "committed")


def g_regencuts(argv):
    """A2.3's frame-1 classifier over every byte cut of a real re-genesis frame."""
    m = load_lib(argv[0])
    recover, store = m["recover"], m["store"]
    intent = json.loads(open(store.path("regenesis.intent"), "rb").read())
    frame_bytes = base64.b64decode(intent["frame_b64"])
    kinds = [recover.classify_frame1_bytes(frame_bytes[:n], frame_bytes) for n in range(0, len(frame_bytes) + 1)]
    emit(f"re-genesis every byte boundary (classifier sweep): all {len(frame_bytes) + 1} prefixes of a real re-genesis "
         "frame are none, torn, unterminated, valid in order", kinds[0] == "none" and kinds[-1] == "valid"
         and kinds[-2] == "unterminated" and set(kinds[1:-2]) == {"torn"}, [k for k in kinds[1:-2] if k != "torn"][:3])


INPROC["regencuts"] = g_regencuts


def j_regen_sweep(checks):
    case = quarantined_case("regen-sweep")
    crashed(case, "regenesis-step-1", "regenesis")
    for item in inproc("regencuts", case.home):
        checks(*item)


def s_boundary_and_findings():
    jobs = [("display", j_display), ("boundary", j_boundary), ("forged old", j_regenesis_forged_old),
            ("cache symlink", j_cache_symlink), ("regen sweep", j_regen_sweep)]
    jobs += [(f"admission {k}", j_type_admission(k)) for k in NOT_ADMITTED]
    jobs += [(f"after delimiter {v}", j_recovery_after_delimiter(v)) for v in ("rotation", "genesis")]
    jobs += [(f"missing dir {k}", j_missing_dir(k))
             for k in ("genesis-none", "genesis-valid", "genesis-pushed", "regenesis")]
    jobs += [(f"envelope digest {k}", j_envelope_digest(k)) for k in ("rotation", "revocation")]
    jobs += [(f"regenesis from {v}", j_regenesis_from(v)) for v in ("invalid-frame", "nonconforming-tail")]
    parallel(jobs)


def s_remaining():
    parallel([("verifier", j_verifier), ("injected", j_injected), ("decoys", j_decoys),
              ("test class", j_test_class), ("ssh", j_ssh), ("https", j_https), ("temporary files", j_tempfiles),
              ("seam", j_seam), ("dormant", j_dormant), ("pointer variants", j_pointer_variants),
              ("start time refusal", j_start_time_refusal)])


# --- the crash matrix (--crash-matrix): every frame-byte cut, real writer ------------

class Slot:
    """One worker's fixed HOME and bare remote (the pinned URL names this
    path, so a cut must run here), restored from a prebuilt template before
    every cut instead of re-running genesis."""

    def __init__(self, kind, index):
        root = os.path.join(TMP, "matrix", f"{kind}-{index:02d}")
        self.live = os.path.join(root, "live")
        self.template = os.path.join(root, "template")
        os.makedirs(self.live)
        case = Case.__new__(Case)
        case.label, case.dir = f"matrix-{kind}-{index:02d}", self.live
        case.home = os.path.join(self.live, "home")
        case.remote = os.path.join(self.live, "remote.git")
        case.url = "file://" + case.remote
        case.env = base_env(case.home)
        self.case = case
        os.mkdir(case.home, 0o700)
        git("init", "--bare", "-q", case.remote)

    def save(self):
        shutil.copytree(self.live, self.template, symlinks=True)

    def restore(self):
        try:
            shutil.rmtree(self.live)
        except PermissionError:
            subprocess.run(["chmod", "-R", "u+w", self.live], check=False)
            shutil.rmtree(self.live)
        shutil.copytree(self.template, self.live, symlinks=True)


def frame_principal(frame_bytes):
    """The principal's variable-width fields of a whole frame (their digits
    set its length), for the probe's note; None if unreadable."""
    try:
        principal = json.loads(parse_frames(frame_bytes)[0][0]["content"])["payload"]["body"]["principal"]
        return {"tty": principal["tty"], "pid": principal["start_token"]["pid"],
                "start_time": principal["start_token"]["start_time"]}
    except (IndexError, KeyError, TypeError, ValueError):
        return None


def matrix_cut(slot, kind, cut, size, base_log, base_tip, produced):
    """Crash the real writer inside the frame, then check the bytes on disk,
    the independent verifier, and the writer's recovery (its first step is
    its own classification of the crash state; then the A1.2 / A2.3
    outcome). The frame's length follows the ceremony's pid, tty, and
    start-time digits, so a run's length need not equal the plan's size.
    Cut n (an int) proves a torn prefix: every run crashes at exactly byte
    n, and only a run whose frame has at least n + 2 bytes is checked. A
    run whose frame is too short for byte n (the seam refuses before
    writing), or exactly n + 1 bytes long (byte n is its final byte, the
    unterminated state, not a torn one), is discarded unchecked and retried
    with a fresh ceremony process, up to MATRIX_ATTEMPTS; no other offset is
    ever tried. Cut "last" is checked only on a run that crashed at its own
    frame's final byte: each run aims at the final byte of the last length
    seen (the plan's size first), and a run whose frame had another length
    is discarded unchecked and the next aims at its length, up to
    MATRIX_ATTEMPTS. A run that ended in the TTY-class refusal of a
    principal read (rc 11, MATRIX_PRINCIPAL_READ, no intent) is an
    environment failure: discarded unchecked and retried within the same
    MATRIX_ATTEMPTS, never credited; any other exit fails the cut at once.
    produced(intent) is called with every crashed run's intent, checked or
    discarded, for the classifier sweep.
    Returns (ok, detail, the checked run's evidence (kind, frame length,
    crash offset measured on disk), or None when no run was checked)."""
    case = slot.case
    args = ("genesis", "--remote", case.url) if kind == "genesis" else ("rotate",)
    n = size - 1 if cut == "last" else cut
    seen = {}
    refusals = 0
    for _attempt in range(MATRIX_ATTEMPTS):
        slot.restore()
        result = case.ceremony(*args, env={"LOOP_AUTHORITY_CRASH_AT": f"frame-byte-{n}"})
        intent = case.genesis_intent() if kind == "genesis" else case.intent()
        if result.rc == 137 and intent is not None:
            produced(intent)
            frame_bytes = frame_of_intent(intent)
            length = len(frame_bytes)  # more than n: the seam refuses a byte not strictly inside
            if cut == "last" and length == n + 1:
                break
            if cut != "last" and length >= n + 2:
                break
            # "last": byte n of a longer frame, not its final byte; byte n: this
            # run's final byte (unterminated), not a torn prefix
        elif result.rc == 11 and intent is None and MATRIX_PRINCIPAL_READ.fullmatch(result.out.strip()):
            # the ceremony could not read its terminal's name or start token
            # (macOS's ttyname returns ERANGE under heavy pty allocation) and
            # refused before writing: an environment failure of this run,
            # discarded unchecked and retried, never credited
            refusals += 1
            continue
        else:
            outside = MATRIX_OUTSIDE.search(result.out) if result.rc == 4 else None
            if outside is None or int(outside.group(1)) != n:
                return False, f"the crashed ceremony exited {result.rc}: {result}", None
            length = int(outside.group(2))  # byte n is not strictly inside this run's shorter frame
        seen[length] = seen.get(length, 0) + 1
        if cut == "last":
            n = length - 1
    else:
        if cut == "last":
            return False, (f"not credited: no run in {MATRIX_ATTEMPTS} crashed at its own frame's final byte "
                           f"(other frame lengths seen: {seen}; runs refused on a principal read: "
                           f"{refusals})"), None
        return False, (f"not credited: no run in {MATRIX_ATTEMPTS} had a frame long enough for a torn byte {n} "
                       f"(at least {n + 2} bytes; frame lengths seen: {seen}; runs refused on a principal read: "
                       f"{refusals})"), None
    last = n == len(frame_bytes) - 1
    frames, _end = parse_frames(frame_bytes)
    frame_type = frames[0]["type"] if frames else None
    log = case.log_path(intent["store_id"]) if kind == "genesis" else case.log_path()
    on_disk = case.read(log)
    evidence = (MATRIX_KIND_OF.get(frame_type, str(frame_type)), len(frame_bytes), len(on_disk) - len(base_log))
    problems = []
    if frame_type != MATRIX_FRAME_TYPES[kind]:
        problems.append(f"the frame's type is {frame_type}, not {MATRIX_FRAME_TYPES[kind]}")
    if on_disk != base_log + frame_bytes[:n] or case.tip() != base_tip:
        problems.append(f"on disk: not exactly the first {n} bytes of the frame, or the remote moved")
    if kind == "genesis":
        want = ("genesis-pending", "A2.3 row 7", "anchor-replay-forward") if last else \
            ("genesis-pending", "A2.3 row 6", "abandon")
    else:
        want = ("pending", "A1.6 unterminated, remote old", "anchor-replay-forward") if last else \
            ("needs-recovery", "A1.6 torn", "torn-frame-truncation")
    independent = case.verifier()
    got = (independent.json.get("state"), independent.json.get("table"), independent.json.get("row"))
    if got != want or independent.json.get("authorizing_state") is not False:
        problems.append(f"verifier {got} != {want}")
    recovered = case.writer("recover")
    steps = recovered.json.get("steps") or [{}]
    first = (steps[0].get("state"), steps[0].get("table"), steps[0].get("row"))
    if first != want:
        problems.append(f"writer classified the crash state {first} != {want}")
    final = recovered.json
    if kind == "genesis" and not last:
        # abandonment removes only the intent: the torn frame 1 stays, unpublished
        ok = final.get("state") == "none" and case.genesis_intent() is None \
            and case.read(log) == frame_bytes[:n] and case.tip() is None \
            and final.get("unpublished", {}).get("stores") == [intent["store_id"]]
    elif kind == "genesis":
        ok = final.get("state") == "committed" and final.get("seq") == 1 \
            and case.tip() == intent["anchor_commit"] and case.read(log) == frame_bytes
    elif not last:
        ok = final.get("state") == "committed" and final.get("seq") == 1 and case.read(log) == base_log \
            and case.intent() is None and case.tip() == base_tip
    else:
        ok = final.get("state") == "committed" and final.get("seq") == 2 \
            and case.read(log) == base_log + frame_bytes and case.tip() == intent["anchor_commit"]
    if not ok:
        problems.append(f"recovery outcome {final.get('state')} seq {final.get('seq')}: {recovered}"[:400])
    return not problems, "; ".join(problems), evidence


MATRIX_KINDS = ("genesis", "rotation")
MATRIX_LABELS = {"genesis": "genesis frame 1", "rotation": "an epoch-rotation frame"}
MATRIX_FRAME_TYPES = {"genesis": "store.genesis", "rotation": "epoch.rotated"}
MATRIX_KIND_OF = {frame_type: kind for kind, frame_type in MATRIX_FRAME_TYPES.items()}
# Runs per cut before it fails: each is a fresh ceremony process, so fresh
# pid, tty, and start-time digits.
MATRIX_ATTEMPTS = 50
# The seam's refusal of a frame-byte-<n> not strictly inside the frame (rc 4).
MATRIX_OUTSIDE = re.compile(r"frame-byte-([0-9]+) is not strictly inside a ([0-9]+)-byte frame")
# The ceremony's TTY-class refusal (rc 11) naming a principal read that failed,
# as the whole of a run's output: an environment failure of that run.
MATRIX_PRINCIPAL_READ = re.compile(r"error: (?:tty-name: cannot read the terminal's name \(ttyname\(0\)\)"
                                   r"|start-token: cannot read the session start token): [^\n]*")
SHARD_FILE = re.compile(r"cut-ids-([1-9][0-9]*)-of-([1-9][0-9]*)\.txt")
# One credited cut per line of a cut-ids file: the planned id, then the
# checked run's actual frame kind, frame length, and crash offset.
EVIDENCE_LINE = re.compile(r"((" + "|".join(MATRIX_KINDS) + r"):frame-byte-([1-9][0-9]*|last))"
                           r"\t(\S+)\t([0-9]+)\t([0-9]+)")


def matrix_options(argv):
    """--crash-matrix [--shard K/N] [--sizes G,R] [--cut-ids-out FILE] [--plan | --check-shards DIR]
    (the wrapper validated the shapes and combinations)."""
    options = {"shard": None, "sizes": None, "out": None, "plan": False, "check": None}
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag == "--plan":
            options["plan"] = True
            index += 1
            continue
        value = argv[index + 1]
        if flag == "--shard":
            shard, count = (int(part) for part in value.split("/"))
            options["shard"] = (shard, count)
        elif flag == "--sizes":
            genesis, rotation = (int(part) for part in value.split(","))
            options["sizes"] = {"genesis": genesis, "rotation": rotation}
        elif flag == "--cut-ids-out":
            options["out"] = os.path.abspath(value)
        elif flag == "--check-shards":
            options["check"] = os.path.abspath(value)
        index += 2
    return options


def matrix_cut_ids(sizes):
    """The enumerated crash-matrix cuts, in order: for genesis frame 1, then
    for an epoch-rotation frame, byte n for every n from 1 to the planned
    size - 2 (a torn prefix), then "last" (a run's own final byte, whatever
    its length). The planned final byte is "last", never a numeric id."""
    return [f"{kind}:frame-byte-{n}" for kind in MATRIX_KINDS for n in (*range(1, sizes[kind] - 1), "last")]


def matrix_shard(ids, shard, count):
    """The deterministic partition: the i-th enumerated cut (from 0) belongs
    to shard i mod count + 1, so every shard gets both frames' cuts."""
    return [cut for index, cut in enumerate(ids) if index % count == shard - 1]


def ids_digest(ids):
    return "sha256:" + hashlib.sha256("".join(cut + "\n" for cut in ids).encode()).hexdigest()


def matrix_note(line):
    print(f"crash matrix {line}", file=sys.stderr, flush=True)


def matrix_slots(kind, count):
    """count slots for one frame, each with its template saved (rotation:
    after a real genesis, scratch-free)."""
    slots = [Slot(kind, index) for index in range(count)]

    def prepare(slot):
        if kind == "rotation":
            result = slot.case.genesis()
            if result.rc != 0:
                raise RuntimeError(f"template genesis failed: {result}")
            for name in ("tmp", "anchor-scratch", "verify"):
                path = os.path.join(slot.case.home, ".cache", "olddonkey-loop", name)
                if os.path.isdir(path) and os.listdir(path):
                    raise RuntimeError(f"template holds scratch leftovers: {path}")
        slot.save()

    with concurrent.futures.ThreadPoolExecutor(MATRIX_WORKERS) as pool:
        list(pool.map(prepare, slots))
    return slots


def matrix_probe(kind, slot):
    """The frame's length as probed in this slot (it follows the ceremony's
    pid, tty, and start-time digits, and the slot's remote path)."""
    slot.restore()
    if kind == "genesis":
        crashed(slot.case, "genesis-step-2", "genesis", "--remote", slot.case.url)
        frame_bytes = frame_of_intent(slot.case.genesis_intent())
    else:
        crashed(slot.case, "after-intent-fsync", "rotate")
        frame_bytes = frame_of_intent(slot.case.intent())
    slot.restore()
    matrix_note(f"{kind} probe: a {len(frame_bytes)}-byte frame, principal {frame_principal(frame_bytes)}")
    return len(frame_bytes)


def matrix_run(kind, slots, cuts, size):
    """Run this run's cuts of one frame (byte n, or "last") over the slots;
    ({cut: outcome}, {frame length: the intent of one crashed run whose
    frame had that length})."""
    import queue

    started = time.monotonic()
    bases = {}
    for slot in slots:
        slot.restore()
        if kind == "genesis":
            bases[id(slot)] = (b"", None)
        else:
            bases[id(slot)] = (slot.case.read(slot.case.log_path()), slot.case.tip())
    pending = queue.Queue()
    for cut in cuts:
        pending.put(cut)
    results = {}
    frames = {}
    lock = threading.Lock()

    def produced(intent):
        with lock:
            frames.setdefault(len(frame_of_intent(intent)), intent)

    def worker(slot):
        base_log, base_tip = bases[id(slot)]
        while True:
            try:
                cut = pending.get_nowait()
            except queue.Empty:
                return
            try:
                outcome = matrix_cut(slot, kind, cut, size, base_log, base_tip, produced)
            except Exception:  # noqa: BLE001
                outcome = (False, traceback.format_exc()[-600:], None)
            with lock:
                results[cut] = outcome

    threads = [threading.Thread(target=worker, args=(slot,)) for slot in slots]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    matrix_note(f"{kind}: {len(cuts)} cuts in {time.monotonic() - started:.0f}s with {len(slots)} workers")
    return results, frames


def matrix_sweep(kind, size, cuts, frames):
    """The offline classifier over every prefix 1 .. N - 1 of each distinct
    real frame (by length N) this run's crashes wrote, as a separate
    interpreter (g_matrixsweep), after printing the kind's report: the
    planned numeric range, the "last" cut, and the lengths swept."""
    lengths = sorted(frames)
    numeric = sum(1 for cut in cuts if cut != "last")
    last = "in this run" if "last" in cuts else "in another shard"
    matrix_note(f"{kind} classifier sweep: planned frame-byte-1 .. frame-byte-{size - 2} (torn prefixes of the "
                f"{size}-byte plan; {numeric} in this run), frame-byte-last (each run's own final byte, "
                f"unterminated; {last}); swept every prefix of the real frames of lengths {lengths}")
    directory = os.path.join(TMP, "matrix")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"sweep-{kind}.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"kind": kind, "intents": [frames[length] for length in lengths]}, handle)
    for item in inproc("matrixsweep", path):
        emit(*item)


def g_matrixsweep(argv):
    """The real offline classifier (frame_prefix_classes: A2.3's frame-1
    classes for genesis frame 1, A1.6's tail classes for an epoch-rotation
    frame) over every prefix 1 .. N - 1 of each frame in argv[0]: 1 .. N - 2
    torn, N - 1 unterminated."""
    m = load_lib(os.path.join(TMP, f"inproc-matrixsweep-{os.getpid()}"))
    with open(argv[0], encoding="utf-8") as handle:
        sweep = json.load(handle)
    kind = sweep["kind"]
    lengths, wrong = [], {}
    for intent in sweep["intents"]:
        kinds = frame_prefix_classes(m["recover"], intent, kind == "genesis")
        lengths.append(len(kinds) + 1)
        if not torn_then_unterminated(kinds):
            wrong[len(kinds) + 1] = [(n, got) for n, got in enumerate(kinds, 1)
                                     if got != ("unterminated" if n == len(kinds) else "torn")][:3]
    classifier = "A2.3 frame-1" if kind == "genesis" else "A1.6 tail"
    emit(f"crash matrix classifier sweep, {MATRIX_LABELS[kind]}: of every real frame a run wrote (lengths N "
         f"{lengths}), prefixes 1 .. N - 2 classify torn and prefix N - 1 unterminated ({classifier} classifier)",
         bool(lengths) and not wrong, wrong)


INPROC["matrixsweep"] = g_matrixsweep


def evidence_problem(cut, evidence):
    """Why a cut id's evidence (kind, frame length, crash offset) does not
    credit it, or None: the kind is the cut's; byte n (a torn prefix) was
    crashed at offset n of a frame of at least n + 2 bytes, so n is not its
    final byte; "last" was crashed at offset length - 1 of its own frame.
    Neither needs the frame to be the planned length."""
    kind, _sep, n = cut.partition(":frame-byte-")
    got_kind, length, offset = evidence
    if got_kind != kind:
        return f"a {got_kind} frame, not {kind}"
    if n == "last":
        if not 1 <= offset == length - 1:
            return f"offset {offset} is not the final byte of its {length}-byte frame"
    elif offset != int(n) or length < int(n) + 2:
        return f"offset {offset} of a {length}-byte frame is not a torn byte {n} (a frame of at least {int(n) + 2})"
    return None


def evidence_line(cut, evidence):
    kind, length, offset = evidence
    return f"{cut}\t{kind}\t{length}\t{offset}"


def matrix_list_checks(lines, ids, shard, count, note=lambda line: None):
    """One shard's cut-ids list against the plan: exactly its partition of
    the full list, in order, and every credited cut's evidence crediting it
    (evidence_problem). Returns (checks, the ids)."""
    parsed = [(line, EVIDENCE_LINE.fullmatch(line)) for line in lines]
    malformed = [line for line, match in parsed if match is None]
    got = [match.group(1) for _line, match in parsed if match is not None]
    want = matrix_shard(ids, shard, count)
    note(f"shard {shard}/{count}: {len(got)} cuts, digest {ids_digest(got)}")
    mismatched = []
    for _line, match in parsed:
        if match is not None:
            evidence = (match.group(4), int(match.group(5)), int(match.group(6)))
            problem = evidence_problem(match.group(1), evidence)
            if problem is not None:
                mismatched.append(f"{match.group(1)} checked {evidence}: {problem}")
    checks = [
        (f"crash matrix shards: shard {shard}/{count} credited exactly its partition ({len(want)} cuts, digest "
         f"{ids_digest(want)})", not malformed and got == want,
         f"{len(got)} cuts, digest {ids_digest(got)}; malformed lines {malformed[:3]}"),
        (f"crash matrix shards: shard {shard}/{count}: every credited cut's evidence (frame kind, frame length, "
         "crash offset) credits it: its kind, byte n at offset n of a frame of at least n + 2 bytes (torn), last "
         "at its frame's final byte", not mismatched, f"{len(mismatched)} mismatched: {mismatched[:5]}"),
    ]
    return checks, got


def matrix_coverage(lists, sizes, note=lambda line: None):
    """The coverage verdict over cut-ids lists ({(shard, count): lines}):
    one list per shard of a single shard count, each exactly its partition
    with evidence crediting every cut, and together every planned cut
    exactly once. Returns [(description, ok, detail)]."""
    ids = matrix_cut_ids(sizes)
    note(f"cut list: {len(ids)} cuts, digest {ids_digest(ids)} (genesis frame {sizes['genesis']} bytes, "
         f"rotation frame {sizes['rotation']} bytes)")
    counts = {count for _shard, count in lists}
    count = counts.pop() if len(counts) == 1 else None
    complete = count is not None and sorted(lists) == [(shard, count) for shard in range(1, count + 1)]
    checks = [(f"crash matrix shards: one cut-id list per shard of a single shard count ({sorted(lists)})",
               complete, sorted(lists))]
    if not complete:
        return checks
    union = []
    for shard in range(1, count + 1):
        shard_checks, got = matrix_list_checks(lists[(shard, count)], ids, shard, count, note)
        checks += shard_checks
        union += got
    position = {cut: index for index, cut in enumerate(ids)}
    combined = sorted(union, key=lambda cut: position.get(cut, len(ids)))
    checks.append((f"crash matrix shards: the {count} shards' credited cuts combine to the full list's digest "
                   f"{ids_digest(ids)} ({len(ids)} cuts, each exactly once)",
                   combined == ids and len(set(union)) == len(union),
                   f"{len(union)} cuts, digest {ids_digest(combined)}; missing {sorted(set(ids) - set(union))[:5]}"))
    return checks


def matrix_check_shards(directory, sizes):
    """The CI follow-up: the shards' cut-ids lists, checked by matrix_coverage
    against the full list the same enumerator gives for the planned sizes."""
    lists = {}
    for name in sorted(os.listdir(directory)):
        match = SHARD_FILE.fullmatch(name)
        if match:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                lists[(int(match.group(1)), int(match.group(2)))] = \
                    [line for line in handle.read().splitlines() if line]
    for item in matrix_coverage(lists, sizes, matrix_note):
        emit(*item)


def s_crash_matrix():
    """Every frame-byte cut of (a) genesis frame 1 and (b) an epoch rotation
    frame, each a real writer crash plus recovery -- all of them, or one
    shard's deterministic partition -- then the classifier sweep over every
    prefix of each distinct real frame those crashes wrote. Revocation and
    re-genesis frames keep every named crash point as a real crash plus
    sampled real frame-byte cuts and the full classifier sweep (the default
    run)."""
    options = MATRIX
    sizes = options["sizes"]
    if options["check"] is not None:
        matrix_check_shards(options["check"], sizes)
        return
    shard, count = options["shard"] or (1, 1)
    slots = {}
    if sizes is None:
        sizes = {}
        for kind in MATRIX_KINDS:
            slots[kind] = matrix_slots(kind, 1 if options["plan"] else MATRIX_WORKERS)
            sizes[kind] = matrix_probe(kind, slots[kind][0])
    ids = matrix_cut_ids(sizes)
    matrix_note(f"cut list: {len(ids)} cuts, digest {ids_digest(ids)} (genesis frame {sizes['genesis']} bytes, "
                f"rotation frame {sizes['rotation']} bytes)")
    if options["plan"]:
        matrix_note(f"sizes={sizes['genesis']},{sizes['rotation']}")
        for kind in MATRIX_KINDS:
            emit(f"crash matrix plan: {MATRIX_LABELS[kind]} probed at {sizes[kind]} bytes (a real crashed ceremony)",
                 sizes[kind] > 1)
        return
    mine = matrix_shard(ids, shard, count)
    if options["shard"] is not None:
        matrix_note(f"shard {shard}/{count}: {len(mine)} cuts, digest {ids_digest(mine)}")
    credited = []
    for kind in MATRIX_KINDS:
        size = sizes[kind]
        prefix = f"{kind}:frame-byte-"
        cuts = [cut[len(prefix):] for cut in mine if cut.startswith(prefix)]
        cuts = [cut if cut == "last" else int(cut) for cut in cuts]
        if not cuts:
            continue
        if kind not in slots:
            slots[kind] = matrix_slots(kind, MATRIX_WORKERS)
        results, frames = matrix_run(kind, slots[kind], cuts, size)
        label = MATRIX_LABELS[kind]
        for cut in cuts:
            ok, detail, evidence = results.get(cut, (False, "not run", None))
            exercised = "not exercised" if evidence is None else \
                f"byte {evidence[2]} of a {evidence[1]}-byte frame, " + (
                    "the last-byte (unterminated) cut" if evidence[2] == evidence[1] - 1 else "torn")
            emit(f"crash matrix, {label}, frame-byte-{cut} ({exercised}): real writer crash, on-disk bytes, "
                 "verifier, writer classification, and recovery outcome", ok, detail)
            if ok:
                credited.append(evidence_line(f"{prefix}{cut}", evidence))
        matrix_sweep(kind, size, cuts, frames)
    # the same check the CI coverage job makes over the shards' files
    if options["shard"] is None:
        checks = matrix_coverage({(1, 1): credited}, sizes)
    else:
        checks, _ids = matrix_list_checks(credited, ids, shard, count)
    for item in checks:
        emit(*item)
    if options["out"] is not None:
        with open(options["out"], "w", encoding="utf-8") as handle:
            handle.write("".join(line + "\n" for line in credited))


def s_matrix_coverage_selftest():
    """The crash matrix's coverage check itself, on made-up cut-ids lists
    (fast; no ceremony): the enumerator plans bytes 1 .. N - 2 and "last";
    complete lists whose evidence credits every cut pass, whether the runs'
    frames are the planned length or longer; one cut credited with evidence
    that does not credit it (a numeric id at its frame's final byte
    included), one cut missing, or a numeric id for the planned final byte,
    fails. A scripted run that exits 11 refusing a principal read is retried
    within the bound and never credited; any other exit fails the cut."""
    sizes = {"genesis": 6, "rotation": 5}
    ids = matrix_cut_ids(sizes)
    emit("crash matrix coverage check: the enumerator plans bytes 1 .. N - 2 of each frame (torn prefixes), then "
         "last, and no numeric id for the final byte N - 1",
         ids == [f"genesis:frame-byte-{n}" for n in (1, 2, 3, 4, "last")]
         + [f"rotation:frame-byte-{n}" for n in (1, 2, 3, "last")], ids)

    def run_evidence(cut, longer):
        """What a real run of this cut would record, its frame `longer`
        bytes longer than planned."""
        kind, _sep, n = cut.partition(":frame-byte-")
        length = sizes[kind] + longer
        return kind, length, length - 1 if n == "last" else int(n)

    def verdict(count=3, evidence=None, drop=None, longer=0, extra=None):
        lists = {(shard, count): [evidence_line(cut, (evidence or {}).get(cut, run_evidence(cut, longer)))
                                  for cut in matrix_shard(ids, shard, count) if cut != drop]
                 for shard in range(1, count + 1)}
        if extra is not None:
            lists[(1, count)].append(evidence_line(*extra))
        return [description for description, ok, _detail in matrix_coverage(lists, sizes) if not ok]

    failed = verdict()
    emit("crash matrix coverage check: 3 shard lists crediting every planned cut once, each from a frame of the "
         "planned length, pass", not failed, failed)
    for label, cut, evidence in (
            ("another crash offset", "rotation:frame-byte-2", ("rotation", 5, 3)),
            ("another frame kind", "rotation:frame-byte-3", ("genesis", 5, 3)),
            ("a frame not longer than n", "genesis:frame-byte-4", ("genesis", 4, 4)),
            ("a frame of exactly n + 1 bytes (n its final byte: unterminated, not torn)",
             "genesis:frame-byte-4", ("genesis", 5, 4)),
            ("an offset that is not its frame's final byte (the planned final byte of a longer frame)",
             "genesis:frame-byte-last", ("genesis", 7, 5))):
        failed = verdict(evidence={cut: evidence})
        emit(f"crash matrix coverage check: {cut} credited with {label} {evidence} fails, on its evidence",
             failed and all("evidence" in description for description in failed), failed)
    failed = verdict(extra=("genesis:frame-byte-5", ("genesis", 7, 5)))
    emit("crash matrix coverage check: shard lists also crediting genesis:frame-byte-5 (the planned final byte as a "
         "numeric id, even with torn evidence) fail, on the partition and the union",
         failed and any("partition" in description for description in failed)
         and any("combine" in description for description in failed), failed)
    failed = verdict(drop="rotation:frame-byte-last")
    emit("crash matrix coverage check: shard lists missing one planned cut (rotation:frame-byte-last) fail, on the "
         "partition and the union", failed and any("partition" in description for description in failed)
         and any("combine" in description for description in failed), failed)
    failed = verdict(count=1)
    emit("crash matrix coverage check: the unsharded run's single list, complete and matching, passes",
         not failed, failed)
    failed = verdict(longer=2)
    emit("crash matrix coverage check: 3 shard lists whose every run had a frame 2 bytes longer than planned (byte "
         "n at offset n, last at the longer frame's final byte) pass", not failed, failed)

    class Scripted:
        """A matrix slot whose ceremony runs return scripted results in turn,
        cycling (no process, nothing written: no intent)."""

        def __init__(self, *results):
            self.results, self.calls = results, 0
            self.case, self.url = self, "file:///matrix-coverage-check.git"

        def restore(self):
            pass

        def ceremony(self, *_args, env=None):
            self.calls += 1
            return self.results[(self.calls - 1) % len(self.results)]

        def genesis_intent(self):
            return None

        def intent(self):
            return None

    tty_name = Res(11, "error: tty-name: cannot read the terminal's name (ttyname(0)): [Errno 34] Result too large\n",
                   "")
    start = Res(11, "error: start-token: cannot read the session start token: sysctl KERN_PROC_PID failed\n", "")
    traceback_run = Res(1, "Traceback (most recent call last):\nOSError: [Errno 5] Input/output error\n", "")
    challenge = Res(11, "error: challenge: the challenge was not echoed exactly\n", "")
    for kind, cut in (("rotation", "last"), ("genesis", 3)):
        slot = Scripted(tty_name, start)
        ok, detail, evidence = matrix_cut(slot, kind, cut, sizes[kind], b"", None, lambda intent: None)
        emit(f"crash matrix retry: {kind} frame-byte-{cut} runs that each exit 11 refusing a principal read (the "
             f"terminal's name, the start token) are discarded and retried up to {MATRIX_ATTEMPTS} runs, never "
             "credited", not ok and evidence is None and slot.calls == MATRIX_ATTEMPTS
             and detail.startswith("not credited") and f"principal read: {MATRIX_ATTEMPTS})" in detail,
             (slot.calls, detail))
    for label, results, calls in (
            ("an exit-11 terminal-name refusal, then a traceback (exit 1): retried once, then the traceback fails "
             "the cut", (tty_name, traceback_run), 2),
            ("an exit-11 refusal that names no principal read (the challenge): fails the cut at once",
             (challenge,), 1),
            ("an exit-11 terminal-name refusal followed by a traceback in the same run: fails the cut at once",
             (Res(11, tty_name.out + traceback_run.out, ""),), 1)):
        slot = Scripted(*results)
        ok, detail, evidence = matrix_cut(slot, "rotation", "last", sizes["rotation"], b"", None, lambda intent: None)
        emit(f"crash matrix retry: {label}", not ok and evidence is None and slot.calls == calls
             and detail.startswith("the crashed ceremony exited"), (slot.calls, detail))
    s_sample_retry_selftest()


def s_sample_retry_selftest():
    # No process, pid, filesystem or production classifier: feed actual frame
    # bytes through the same intent reader that real default samples use.
    class ScriptedSample:
        label = "scripted-sample"

        def __init__(self, lengths):
            self.lengths, self.cuts = lengths, []

        def run(self, n, attempt):
            self.cuts.append(n)
            length = self.lengths[attempt % len(self.lengths)]
            if n >= length:
                return self, Res(4, f"error: crash-point: frame-byte-{n} is not strictly inside a "
                                f"{length}-byte frame\n", ""), None
            frame = b"x" * (length - 1) + b"\n"
            intent = {"frame_b64": base64.b64encode(frame).decode()}
            # Returning this attempt id lets the test prove no discarded run
            # is ever returned to the caller's torn/classification checks.
            return attempt, Res(137, "", ""), intent

    slot = ScriptedSample([30])  # Probe length 32; planned size - 3 is byte 29.
    case, result, intent, n = sampled_torn_crash(32 - 3, slot.run)
    emit("default sample retry: a frame two bytes shorter than the probe is discarded as unterminated, "
         "then only a torn retry is credited", case == 1 and slot.cuts == [29, 28]
         and result.rc == 137 and len(frame_of_intent(intent)) >= n + 2 and n == 28, slot.cuts)

    slot = ScriptedSample([8])  # Short enough that the seam refuses before intent.
    case, result, intent, n = sampled_torn_crash(32 - 3, slot.run)
    emit("default sample retry: an outside-frame refusal is discarded, then retargeted to that run's length",
         case == 1 and slot.cuts == [29, 6] and result.rc == 137
         and len(frame_of_intent(intent)) >= n + 2 and n == 6, slot.cuts)

    cuts = []
    def always_unterminated(n, attempt):
        cuts.append(n)
        return attempt, Res(137, "", ""), {"frame_b64": base64.b64encode(b"x" * n + b"\n").decode()}
    detail = ""
    try:
        sampled_torn_crash(29, always_unterminated)
    except RuntimeError as error:
        detail = str(error)
    emit("default sample retry: exhausting the small bound fails explicitly, with no sample credited",
         len(cuts) == SAMPLE_ATTEMPTS and f"retry bound exhausted after {SAMPLE_ATTEMPTS} runs" in detail
         and "no sample credited" in detail, (cuts, detail))

    refused = []
    for result in (Res(1, "Traceback: synthetic failure", ""),
                   Res(4, "error: unrelated refusal", ""),
                   Res(4, "error: frame-byte-28 is not strictly inside a 10-byte frame", "")):
        calls = []
        def bad_run(n, attempt):
            calls.append(n)
            return ScriptedSample([]), result, None
        try:
            sampled_torn_crash(29, bad_run)
            refused.append(False)
        except RuntimeError:
            refused.append(calls == [29])
    emit("default sample retry: unexpected exits and mismatched seam refusals fail immediately, never credited",
         all(refused), refused)


def review_named_points():
    # These cases actually crash and recover every registered command/point.
    # Adding a registered point without implementing it must fail the suite.
    sys.path.insert(0, LIB)
    from loopauth.store import CRASH_APPLICABLE
    observed = {command: set(points) for command, points in CRASH_APPLICABLE.items()}
    if observed != FROZEN_CRASH_POINTS:
        raise AssertionError("registered review crash points differ from the frozen inventory")
    return {command: tuple(sorted(points)) for command, points in FROZEN_CRASH_POINTS.items()}


def j_review_crash(command, point):
    def job(checks):
        label = f"review crash {command}/{point}"
        if command == "genesis":
            case = Case(label)
            result = case.genesis(env={"LOOP_AUTHORITY_CRASH_AT": point})
        elif command in ("rotate", "regenesis") and point in MARKER_PRELUDE_CUTS:
            case = committed_case(label)
            git("--git-dir", case.remote, "update-ref", "-d", ANCHOR_REF)
            result = case.ceremony(command, env={"LOOP_AUTHORITY_CRASH_AT": point})
        elif command == "regenesis":
            case = quarantined_case(label)
            result = case.ceremony("regenesis", env={"LOOP_AUTHORITY_CRASH_AT": point})
        elif command in ("rotate", "revoke"):
            case = committed_case(label)
            args = (command,) if command == "rotate" else (command, "--epoch", "1")
            result = case.ceremony(*args, env={"LOOP_AUTHORITY_CRASH_AT": point})
        else:
            if point.startswith("archive-"):
                case = quarantined_case(label)
                crashed(case, "after-readback", "regenesis")
            elif point.startswith("fs-create-"):
                case = committed_case(label, rotate=True)
                data = case.read(case.log_path())
                frames, _ = parse_frames(data)
                case.write(case.log_path(), data[:frames[0]["end"]])
            else:
                case = committed_case(label)
                crashed(case, "after-frame-fsync", "rotate")
                if point == "recovery-after-delimiter":
                    case.write(case.log_path(), case.read(case.log_path())[:-1])
            result = case.writer("recover", env={"LOOP_AUTHORITY_CRASH_AT": point})
        checks(label + ": cut is reached", result.rc == 137, result)
        if point.startswith("fs-create-intent-"):
            target = case.auth("genesis.intent") if command == "genesis" else (
                case.auth("regenesis.intent") if command == "regenesis" else os.path.join(case.store_dir(), "intent"))
            checks(label + ": the cut selects the intent publication",
                   os.path.exists(target) == point.endswith("after-rename"), target)
        elif point.startswith("fs-create-marker-"):
            target = os.path.join(case.store_dir(), "quarantine")
            checks(label + ": the cut selects the quarantine marker publication",
                   os.path.exists(target) == point.endswith("after-rename"), target)
        checks(label + ": published files have one link", all(
            os.stat(os.path.join(directory, name)).st_nlink == 1
            for directory, _, files in os.walk(case.auth()) for name in files))
        first = case.writer("recover")
        second = case.writer("recover")
        checks(label + ": second recovery converges", first.rc in (0, 6) and second.rc == first.rc
               and first.json.get("state") == second.json.get("state")
               and second.json.get("state") in ("committed", "quarantined", "none"), (first, second))
        case.agree(checks, label + ": writer and verifier agree after recovery", second.json.get("state"))
    return job


def j_review_prefix_siblings(kind):
    def job(checks):
        case = committed_case("review-prefix-" + kind)
        original, other = case.tip(), None
        if kind == "case-variant":
            siblings = {"refs/olddonkey-loop/ANCHOR": original}
        elif kind == "fifty":
            siblings = {f"refs/olddonkey-loop/s{i:02}": original for i in range(50)}
        else:
            blob = git("--git-dir", case.remote, "hash-object", "-w", "--stdin", stdin=b"unrelated\n").stdout.decode().strip()
            tree = git("--git-dir", case.remote, "mktree", stdin=f"100644 blob {blob}\tother\n".encode()).stdout.decode().strip()
            other = git("--git-dir", case.remote, "commit-tree", tree, "-m", "unrelated",
                        extra={"GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                               "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}).stdout.decode().strip()
            siblings = {"refs/olddonkey-loop/other": other}
        git("--git-dir", case.remote, "pack-refs", "--all")
        path = os.path.join(case.remote, "packed-refs")
        with open(path) as handle:
            lines = [line for line in handle.read().splitlines() if line and not line.startswith(("#", "^"))]
        lines += [f"{oid} {ref}" for ref, oid in siblings.items()]
        lines.sort(key=lambda line: line.split(" ", 1)[1].encode())
        with open(path, "w") as handle:
            handle.write("# pack-refs with: peeled fully-peeled sorted \n" + "\n".join(lines) + "\n")
        bins, trace = os.path.join(case.dir, "bins"), os.path.join(case.dir, "fetches.jsonl")
        os.mkdir(bins)
        wrapper = os.path.join(bins, "git")
        with open(wrapper, "w") as handle:
            handle.write("#!" + sys.executable + "\nimport json, os, subprocess, sys\nREAL=" + repr(GIT)
                         + "\na=sys.argv[1:]\nif 'fetch' in a:\n"
                         "    done=subprocess.run([REAL]+a)\n    root=a[a.index('-C')+1]\n"
                         "    refs=subprocess.check_output([REAL,'-C',root,'for-each-ref','--format=%(refname)']).decode().splitlines()\n"
                         + "    other=" + repr(other) + "\n"
                         "    missing=other is None or subprocess.run([REAL,'-C',root,'cat-file','-e',other],capture_output=True).returncode != 0\n"
                         + "    with open(" + repr(trace) + ", 'a') as f: f.write(json.dumps([refs,missing])+'\\n')\n"
                         "    sys.exit(done.returncode)\nos.execv(REAL,[REAL]+a)\n")
        os.chmod(wrapper, 0o700)
        env = {"LOOP_AUTHORITY_TEST_BIN_DIR": bins}
        for args in (None, ("rotate",), ("revoke", "--epoch", "1")):
            if args:
                result = case.ceremony(*args)
                checks(f"prefix {kind}: {args[0]} succeeds", result.rc == 0, result)
            w, v = case.agree(checks, f"prefix {kind}: committed {args}", "committed", env=env)
            checks(f"prefix {kind}: both verifiers succeed {args}", w.rc == v.rc == 0, (w, v))
            present = dict(line.split(" ", 1)[::-1] for line in git("--git-dir", case.remote,
                           "for-each-ref", "--format=%(objectname) %(refname)", "refs/olddonkey-loop/").stdout.decode().splitlines())
            checks(f"prefix {kind}: siblings stay untouched {args}",
                   {ref: present.get(ref) for ref in siblings} == siblings, present)
        with open(trace) as handle:
            samples = [json.loads(line) for line in handle]
        checks(f"prefix {kind}: both readers fetch only the anchor, no sibling refs or unrelated objects",
               len(samples) >= 6 and all(refs == ["refs/readback/anchor"] and missing for refs, missing in samples), samples)
    return job


def j_review_stray_refs(checks):
    case = committed_case("review-stray")
    git("--git-dir", case.remote, "update-ref", "refs/heads/" + ANCHOR_REF, case.tip())
    case.agree(checks, "a tail-matched unrelated branch does not quarantine", "committed")
    result = case.writer("recover")
    checks("stray branch: recover succeeds without quarantine marker", result.rc == 0 and
           not os.path.exists(os.path.join(case.store_dir(), "quarantine")), result)


def j_review_rotate_revoke_stray(checks):
    case = committed_case("review-stray-ceremonies")
    stray = "refs/heads/" + ANCHOR_REF
    original = case.tip()
    git("--git-dir", case.remote, "update-ref", stray, original)
    for args in (("rotate",), ("revoke", "--epoch", "1")):
        result = case.ceremony(*args)
        checks(f"stray branch: {args[0]} ceremony succeeds", result.rc == 0, result)
        writer, independent = case.agree(checks, f"stray branch after {args[0]}", "committed")
        checks(f"stray branch: {args[0]} verifies at exit 0", writer.rc == independent.rc == 0)
        checks(f"stray branch: {args[0]} updates only the exact anchor",
               case.tip() != original and git("--git-dir", case.remote, "rev-parse", stray).stdout.strip().decode() == original)


def j_review_stray_only_genesis(checks):
    seed = committed_case("review-stray-only-seed")
    git("--git-dir", seed.remote, "update-ref", "refs/heads/" + ANCHOR_REF, seed.tip())
    seed.set_tip(None)
    case = Case("review-stray-only-genesis", share=seed)
    crashed(case, "after-frame-fsync", "genesis", "--remote", case.url)
    writer, independent = case.agree(checks, "stray-only remote before genesis push", "genesis-pending")
    checks("stray-only genesis: both verifiers exit pending", writer.rc == independent.rc == 5)
    result = case.writer("recover")
    checks("stray-only genesis: recovery publishes the exact anchor", result.rc == 0 and case.tip() is not None, result)
    case.agree(checks, "stray-only genesis recovered", "committed")
    fresh = Case("review-stray-only-direct-genesis", share=seed)
    case.set_tip(None)
    result = fresh.genesis()
    checks("stray-only genesis: ceremony succeeds directly", result.rc == 0, result)
    fresh.agree(checks, "stray-only direct genesis", "committed")


def j_review_absent_anchor_stray(checks):
    case = committed_case("review-absent-anchor-stray")
    git("--git-dir", case.remote, "update-ref", "refs/heads/" + ANCHOR_REF, case.tip())
    case.set_tip(None)
    writer, independent = case.agree(checks, "absent exact anchor with same-commit stray", "quarantined")
    checks("absent anchor with stray: both verifiers exit quarantine", writer.rc == independent.rc == 6)
    checks("absent anchor with stray: both classify the absent-anchor rule",
           writer.json.get("rule") == "anchor-absent" and independent.json.get("table") == "A2.3 absent ref once active exists",
           (writer, independent))


def j_review_fetch_without_ref(checks):
    case = committed_case("review-fetch-no-ref")
    bins = os.path.join(case.dir, "bins")
    os.mkdir(bins)
    for malformed in (False, True):
        wrapper = os.path.join(bins, "git")
        with open(wrapper, "w") as handle:
            handle.write("#!" + sys.executable + "\nimport os, sys\na = sys.argv[1:]\n")
            handle.write("if 'fetch' in a:\n")
            if malformed:
                handle.write("    root = a[a.index('-C') + 1]\n    path = os.path.join(root, 'refs/readback/anchor')\n    os.makedirs(os.path.dirname(path), exist_ok=True)\n    open(path, 'w').write('malformed\\n')\n")
            handle.write("    sys.exit(0)\nos.execv(" + repr(GIT) + ", [" + repr(GIT) + "] + a)\n")
        os.chmod(wrapper, 0o700)
        writer, independent = case.agree(checks, "successful fetch with " + ("malformed" if malformed else "missing") + " readback ref",
                                         "pending", env={"LOOP_AUTHORITY_TEST_BIN_DIR": bins})
        checks("successful fetch without valid ref: both exit pending", writer.rc == independent.rc == 5)


def j_review_local_timeouts(checks):
    case = committed_case("review-local-timeouts")
    # Shorten only the scratch copies' deadlines; real CLI classification and
    # a genuinely hanging executable are exercised without a 60-second wait.
    package = os.path.join(case.dir, "package")
    shutil.copytree(LIB, os.path.join(package, "lib"))
    shutil.copytree(SCRIPTS, os.path.join(package, "scripts"))
    tool_path = os.path.join(package, "lib/loopauth/tools.py")
    text = read_text(tool_path).replace("LOCAL_TIMEOUT = 60", "LOCAL_TIMEOUT = 0.5")
    with open(tool_path, "w") as handle:
        handle.write(text)
    verify_path = os.path.join(package, "scripts/loop-authority-verify.py")
    text = read_text(verify_path).replace('else 60,', 'else 0.5,')
    with open(verify_path, "w") as handle:
        handle.write(text)
    bins = os.path.join(case.dir, "bins")
    os.mkdir(bins)
    for form, binary in (("init", "git"), ("cat-file", "git"), ("verify", "ssh-keygen")):
        for leaf in os.listdir(bins):
            os.unlink(os.path.join(bins, leaf))
        wrapper = os.path.join(bins, binary)
        actual = GIT if binary == "git" else SSH_KEYGEN
        with open(wrapper, "w") as handle:
            handle.write("#!" + sys.executable + "\nimport os, sys, time\na = sys.argv[1:]\n")
            handle.write("if " + repr(form) + " in a: time.sleep(2)\n")
            handle.write("os.execv(" + repr(actual) + ", [" + repr(actual) + "] + a)\n")
        os.chmod(wrapper, 0o700)
        env = {"LOOP_AUTHORITY_TEST_BIN_DIR": bins}
        writer = case.run([BASH, os.path.join(package, "scripts/loop-authority"), "verify"], env=env)
        independent = case.run([BASH, os.path.join(package, "scripts/loop-authority-verify")], env=env)
        checks(f"local {binary} {form} timeout: writer and verifier exit environment",
               writer.rc == independent.rc == 9 and "timed out" in writer.err and "timed out" in independent.err,
               (writer, independent))
        case.agree(checks, f"local {form} timeout leaves the store committed", "committed")


def read_text(path):
    with open(path) as handle:
        return handle.read()


def j_review_unlinkable(checks):
    case = committed_case("review-unlinkable", rotate=True)
    lineage = Lineage(case)
    case.write(case.log_path(), lineage.data[:lineage.frames[0]["end"]])
    result = case.writer("recover")
    checks("unlinkable: rollback remains quarantined", result.rc == 6 and result.json.get("state") == "quarantined", result)
    before, remote_before = case.snapshot(), case.remote_snapshot()
    result = case.ceremony("regenesis")
    checks("unlinkable: current lineage-preserving refusal is documented and pinned", result.rc == 4 and "regenesis-unlinkable" in result.out, result)
    unchanged(checks, "unlinkable refusal", case, before, remote_before)


def j_review_none(checks):
    case = Case("review-none")
    status, verification, independent = case.status(), case.writer("verify"), case.verifier()
    checks("none: status remains informational success", status.rc == 0 and status.json.get("state") == "none", status)
    checks("none: both verify commands refuse absent authority", verification.rc == 12 and independent.rc == 12
           and verification.json.get("state") == independent.json.get("state") == "none", (verification, independent))


def j_review_surrogates(checks):
    case = committed_case("review-surrogate")
    original = case.read(case.log_path())
    for value in ({"payload": "\ud800", "sig": "x"}, {"\ud800": "x"}):
        frame = mkframe(2, "epoch.rotated", json.dumps(value).encode())
        case.write(case.log_path(), original + frame)
        writer, independent = case.agree(checks, "complete surrogate frame is quarantined", "quarantined")
        checks("surrogate frame: verifier emits JSON, no traceback", independent.rc == 6 and
               "Traceback" not in independent.err and "UTF-8" in independent.json.get("detail", ""), independent)


def s_review_regressions():
    jobs = [(f"review crash {command}/{point}", j_review_crash(command, point))
            for command, points in review_named_points().items() for point in points]
    jobs += [(f"review prefix siblings {kind}", j_review_prefix_siblings(kind))
             for kind in ("case-variant", "fifty", "unrelated")]
    jobs += [("review stray ref", j_review_stray_refs),
             ("review rotate and revoke with stray", j_review_rotate_revoke_stray),
             ("review stray-only genesis", j_review_stray_only_genesis),
             ("review absent anchor with stray", j_review_absent_anchor_stray),
             ("review fetch without ref", j_review_fetch_without_ref),
             ("review local timeouts", j_review_local_timeouts), ("review unlinkable", j_review_unlinkable),
             ("review no authority", j_review_none), ("review surrogate", j_review_surrogates)]
    parallel(jobs)


def s_review_point_inventory():
    for item in inproc("seam"):
        emit(*item)
    home = os.path.join(TMP, "review-transport-home")
    os.makedirs(home, exist_ok=True)
    for item in inproc("transport", home):
        emit(*item)


def s_review_scenarios():
    jobs = [(f"active revocation {p}", j_active_revocation(p)) for p in REVOCATION_POINTS]
    jobs += [(f"verify-only revocation {p}", j_verify_only_revocation(p)) for p in VERIFY_ONLY_REVOCATION_POINTS]
    jobs += [(f"marker prelude {c}/{p}", j_review_crash(c, p))
             for c in ("rotate", "regenesis") for p in MARKER_PRELUDE_CUTS]
    jobs += [(f"re-genesis {p}", j_regenesis(p)) for p in REGENESIS_CUTS if not p.startswith("frame-byte-")]
    jobs += [(f"re-genesis bad signature {p}", j_regenesis_bad_sig(p)) for p in REGENESIS_CUTS if not p.startswith("frame-byte-")]
    parallel(jobs)


MATRIX = {}


def main():
    if len(sys.argv) > 5 and sys.argv[5] == "--crash-matrix":
        MATRIX.update(matrix_options(sys.argv[6:]))
        sections = (("crash matrix", s_crash_matrix),)
    elif len(sys.argv) > 6 and sys.argv[5:7] == ["--review-only", "inventory"]:
        sections = (("review point inventory and transport", s_review_point_inventory),
                    ("crash matrix coverage check", s_matrix_coverage_selftest))
    elif len(sys.argv) > 5 and sys.argv[5] == "--review-only":
        sections = (("review regressions", s_review_regressions),
                    ("review point inventory and transport", s_review_point_inventory),
                    ("review scenario cuts", s_review_scenarios),
                    ("crash matrix coverage check", s_matrix_coverage_selftest))
    else:
        sections = (("review regressions", s_review_regressions),
                    ("crash matrix coverage check", s_matrix_coverage_selftest),
                    ("in-process", s_inproc_pure), ("genesis basics", s_genesis_basic),
                    ("write protocol", s_protocol), ("epochs and re-genesis", s_epochs_regenesis),
                    ("ceremonies and key staging", s_ceremonies_staging),
                    ("genesis cuts", s_genesis_cuts), ("terminal states", s_terminal),
                    ("boundary and review findings", s_boundary_and_findings),
                    ("verifier, remote, fixtures", s_remaining))
    for label, section in sections:
        started = time.monotonic()
        try:
            section()
        except Exception:  # noqa: BLE001
            emit(f"section {label} completes", False, traceback.format_exc()[-1500:])
        print(f"section {label}: {time.monotonic() - started:.0f}s", file=sys.stderr)


if MODE == "inproc":
    INPROC[GROUP](sys.argv[6:])
else:
    main()
PY

if [[ "$MODE_ARG" == --crash-matrix ]]; then
  printf 'note: the crash matrix -- the real writer crashed at every frame-byte cut of genesis frame 1 and of an epoch-rotation frame (bytes 1 .. N - 2 as torn prefixes, then the final byte; all of them, or one shard'"'"'s deterministic partition), each followed by the verifier and recovery, then the offline classifier over every prefix of each real frame the crashes wrote\n'
elif [[ "$MODE_ARG" == --review-only ]]; then
  printf 'note: review regressions, frozen point/transport inventory, named scenario cuts, and coverage negative controls only; no frame-byte crash matrix\n'
else
  printf 'note: genesis and rotation frames get every-byte real crashes in --crash-matrix (sharded CI jobs); here, revocation and re-genesis frames get every named crash point as a real crash, sampled real frame-byte cuts, and the full classifier sweep over every byte\n'
fi
python3 "$TMP_ROOT/at.py" main "$SCRIPTS" "$LIB" "$TMP_ROOT" "$MODE_ARG" ${MATRIX_ARGS[@]+"${MATRIX_ARGS[@]}"} \
  > "$TMP_ROOT/at.tsv" 2> "$TMP_ROOT/at.stderr"
AT_STATUS=$?
sed -n -e 's/^section /# section /p' -e 's/^crash matrix /# crash matrix /p' "$TMP_ROOT/at.stderr"
tally "$TMP_ROOT/at.tsv" "$TMP_ROOT/at.stderr" "$AT_STATUS" "authority checks"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
