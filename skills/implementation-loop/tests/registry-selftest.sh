#!/usr/bin/env bash
# Hermetic checks for the admission registry and the reachability invariants
# of the authority store (task-graph-v1 Phase A, sub-unit 0a.2; A1.4, A1.5).
#
# - the registry holds every row of tg:809-829 and A1.3 with its six columns
#   and exclusion ids, compared with a frozen oracle written below;
# - an AST scan of lib/loopauth proves that every write to a sink goes
#   through a token-checked function in store.py (the frozen sink-function
#   list), that every subprocess goes through tools.run, and that keys.py and
#   anchor.py reach only read and scratch commands; planted-bypass copies
#   make the scan fail (negative controls);
# - the closed command table equals a frozen copy; unlisted variants cannot
#   be built;
# - every sink refuses no token, a spent token, another row's token, a stage
#   not yet bound, a re-bind, and -- with an otherwise valid same-row token --
#   any differing parameter, including when the low-level sink is called
#   directly; recovery-derived rows refuse a token bound to another state;
# - recovery and finish tokens are minted from nothing but an issued plan,
#   once, re-proved by a fresh observation (forged, altered, and replayed
#   plans and caller-built bindings mint nothing; a forged quarantine on a
#   committed store writes nothing), and abandonment removes only the
#   intent; a revocation's quarantine child exists only for the active
#   epoch it observed;
# - every dormant row and approval.consume is refused with its distinct
#   error; every admissible row's validator, exclusion, and transition is
#   driven positively and negatively;
# - every ceremony refuses with exit 11 naming the failed read, never a
#   traceback, when os.ttyname, a start-token read, or the challenge's
#   terminal I/O raises OSError, and mutates nothing (the terminal simulated
#   in-process);
# - 0a.3: the read-only verification modules (refs.py, eligibility.py,
#   journal_read.py) pass direct read-only rules, which refuse any module
#   alias outright, and reach no sink through a transitive call graph, with
#   planted negative controls; and the full
#   request-kind x source-state cross-product is refused as a dormant row by
#   every request row, with no store or anchor mutation.
#
# Fixture stores are made in-process by the ceremony core with the TTY
# challenge stubbed (this suite tests the registry and tokens, not the
# operator-TTY ceremony, which authority-selftest.sh drives through a pty).
# HOME is a scratch directory; the remote is a file:// bare repository.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LIB="$SCRIPT_DIR/../lib"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/registry-selftest.XXXXXX")" || exit 1
# A normalized, symlink-free path (macOS TMPDIR ends in '/' and /var is a
# symlink): the file:// remotes built from it must pass the writer's
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
unset LOOP_AUTHORITY_CRASH_AT LOOP_AUTHORITY_TEST_BIN_DIR SSH_AUTH_SOCK

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

cat > "$TMP_ROOT/rs.py" <<'PY'
"""registry-selftest driver: rs.py <mode> <lib> <tmp> [args]"""

from __future__ import annotations

import ast
import hashlib
import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import traceback

MODE, LIB = sys.argv[1], sys.argv[2]
TMP = os.path.realpath(sys.argv[3])  # normalized: remote paths are built from it
ARGS = sys.argv[4:]
PRINCIPAL = {"kind": "operator-tty", "tty": "/dev/ttys000",
             "start_token": {"boot_id": "TESTBOOT-0000", "pid": 1, "start_time": 1}}
ANCHOR_REF = "refs/olddonkey-loop/anchor"
VERIFY = os.path.join(os.path.dirname(os.path.realpath(LIB)), "scripts", "loop-authority-verify")


def emit(description, ok, detail=""):
    if ok:
        print(f"ok\t{description}", flush=True)
    else:
        print(f"not ok\t{description}\t{' '.join(str(detail).split())[:900]}", flush=True)


def git(*args, stdin=b"", check=True, extra_env=None):
    env = {"PATH": os.environ.get("PATH", "/usr/bin"), "HOME": TMP, "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    env.update(extra_env or {})
    result = subprocess.run([shutil.which("git"), "-c", "core.hooksPath=/dev/null", *args], input=stdin,
                            capture_output=True, env=env, cwd=TMP)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {args}: {result.stderr.decode()}")
    return result


def D(value):
    return "sha256:" + hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


# ===========================================================================
# The frozen oracle: every row of tg:809-829 and A1.3 with its six columns
# ===========================================================================

X = {
    # tg:874-880, the Exclusions paragraph, numbered X1-X7 in the order written (A1.10).
    "X1": "a session may not answer its own request",
    "X2": "the implementing session may not close its own mechanism",
    "X3": "the builder, coordinator, and writer sessions are mechanically excluded from release acceptance",
    "X4": "an execution root may not mint scope its repository lacks",
    "X5": "an inheritance-changing rebind requires a fresh gesture",
    "X6": "the writer may not rotate its own key without the operator",
    "X7": "derived operations may never be requested directly",
}

# id: (operation, trigger, principal / source, required evidence, validator, exclusions, transition,
#      admissible from, entry, record type). The six columns are tg:809-829 and A1.3's table with
#      only their Markdown emphasis removed; exclusions per tg:874-880 (X7 on every derived row) and
#      A1.3's exclusion column as written.
REQ = "A2.1 (by request kind: unit 8, 9, or 12)"
ORACLE = {
    "request-opening": (
        "request opening", "reducer, from the request kind's source state (below)", "derived",
        "source state, request kind, schema-derived scope, target eligibility", "V-request-open", ("X7",),
        "T-request-opened", REQ, "derived", "request.opened"),
    "request-cancellation": (
        "request cancellation", "console gesture, or the source state becoming invalid",
        "authenticated human, or derived", "request id, open state, reason", "V-request-cancel", ("X7",),
        "T-request-cancelled", REQ, "external", "request.cancelled"),
    "request-expiry": (
        "request expiry", "the expiry passing", "derived, not decided", "request id, expiry",
        "V-request-expire", ("X7",), "T-request-expired", REQ, "derived", "request.expired"),
    "capability-issuance": (
        "capability issuance", "a request is opened", "derived from that request",
        "request id, target session + start token, scope, expiry, mode", "V-cap-issue", ("X7",),
        "T-cap-issued", REQ, "compound", "request.opened"),
    "capability-redemption": (
        "capability redemption", "the target answers", "the bound target session",
        "the secret + the answer, in one append (§6b)", "V-cap-redeem", ("X1",),
        "compound, by request kind (below)", REQ, "external", "request.redeemed"),
    "enrollment": (
        "enrollment", "console gesture", "authenticated human",
        "canonical entry, executor profile, policy version, gesture nonce", "V-enroll", (), "T-entry-active",
        "unit 4", "external", "entry.enrolled"),
    "enrollment-revocation": (
        "enrollment revocation", "console gesture", "authenticated human", "entry digest, prior generation",
        "V-revoke-entry", (), "T-entry-revoked", "unit 4", "external", "entry.revoked"),
    "repository-registration": (
        "repository registration", "console gesture", "authenticated human",
        "common dir, incarnation id, generation", "V-repo-register", (), "T-repo-active", "unit 2", "external",
        "repo.registered"),
    "repository-rebind": (
        "repository rebind", "console gesture", "authenticated human", "prior + proposed incarnation, grant delta",
        "V-repo-rebind", ("X5",), "T-repo-rebound", "unit 2", "external", "repo.rebound"),
    "execution-root-registration": (
        "execution-root registration", "coordinator selects a root", "derived from the registered repository",
        "logical repo id, root path, incarnation", "V-exec-root", ("X4", "X7"), "T-exec-root-active", "unit 2",
        "derived", "exec-root.registered"),
    "standing-authorization": (
        "standing authorization", "console gesture", "authenticated human", "dial, scope, policy version",
        "V-standing", (), "T-standing-active", "unit 3", "external", "standing.granted"),
    "standing-revocation": (
        "standing revocation", "console gesture", "authenticated human", "prior sealed grant",
        "V-revoke-standing", (), "T-standing-revoked", "unit 3", "external", "standing.revoked"),
    "segment-discharge": (
        "segment discharge", "derived — redemption of a segment-discharge request",
        "derived from that redeemed request", "complete accumulator digest (§4c)", "V-segment", ("X7",),
        "T-segment-reset", "unit 8 (A2.1)", "compound", None),
    "mechanism-closure": (
        "mechanism closure (P1–P5)", "derived — redemption of a mechanism-closure request",
        "derived from that redeemed request", "mechanism id, conformance evidence, verifier identity",
        "V-closure", ("X2", "X7"), "T-mechanism-closed", "unit 12", "compound", None),
    "acceptance-platform-designation": (
        "acceptance-platform designation", "ceremony", "authenticated local operator",
        "platform set, confinement mechanism + version", "V-platform", (), "T-platform-policy-active",
        "unit 12", "ceremony", "platform.designated"),
    "release-acceptance": (
        "release acceptance", "derived — redemption of a release-acceptance request",
        "derived from that redeemed request",
        "exact release tree, acceptance evidence, decision chain, platform identity + confinement "
        "mechanism/version + platform-policy digest", "V-accept", ("X3", "X7"), "T-release-accepted",
        "unit 12", "compound", None),
    "authority-head-advance": (
        "authority-head advance", "an admitted append", "derived, not decided", "the append it follows",
        "V-head", ("X7",), "T-head-advanced", "0a.2", "compound", None),
    "epoch-rotation": (
        "epoch rotation", "ceremony", "authenticated local operator",
        "current epoch, proposed key identity + new epoch, anchor position", "V-epoch-rotate", ("X6",),
        "T-epoch-rotated (atomically: old → verify-only, new → active)", "0a.2", "ceremony", "epoch.rotated"),
    "epoch-revocation": (
        "epoch revocation", "incident", "authenticated local operator", "current epoch, anchor position",
        "V-epoch-revoke", (), "T-epoch-revoked", "0a.2", "ceremony", "epoch.revoked"),
    # --- A1.3's seven rows (A1.10 ids; A1.3's exclusion column as written)
    "authority-genesis": (
        "authority genesis", "operator ceremony on an absent store and a remote whose anchor ref is absent",
        "operator-TTY (A1.1)",
        "store id, remote URL, first epoch root public key, per-type subkey certificates (A1.7)", "V-genesis",
        ("X6",), "T-store-created + anchor generation 1", "0a.2", "ceremony", "store.genesis"),
    "gesture-nonce-issuance": (
        "gesture-nonce issuance", "the console asks to display an artifact for a gesture",
        "console session (external; one typed display API)", "artifact digest, session id, expiry",
        "V-nonce-issue", (), "T-nonce-issued (only the hash is stored)", "unit 4 (A2.6)", "external",
        "nonce.issued"),
    "torn-frame-truncation": (
        "torn-frame truncation", "recovery observes a torn final frame (A1.6)", "derived — recovery source",
        "the write intent and the frame's byte range", "V-torn", ("X7",),
        "T-torn-truncated — the only discard (tg:945)", "0a.2", "recovery", None),
    "anchor-replay-forward": (
        "anchor replay-forward",
        "recovery observes R.active = ptr(L − 1) and a durable write intent matching frame L (A1.2)",
        "derived — recovery source", "the validated frame L and its intent", "V-replay", ("X7",),
        "T-anchor-advanced; compound T-delimiter-completed + T-anchor-advanced when frame L was complete but "
        "unterminated (A1.6)", "0a.2", "recovery", None),
    "recovery-tidy": (
        "recovery tidy",
        "recovery observes R.active = ptr(L) with any of: a residual intent for L matching frame L exactly, an "
        "intent for L + 1 at exactly the end of the log with no bytes after it, or a cursor that disagrees "
        "with L", "derived — recovery source", "the observed intent (if any), cursor, L, R", "V-tidy", ("X7",),
        "T-intent-cleared (when an intent is present) and/or T-cursor-reset", "0a.2", "recovery", None),
    "store-quarantine": (
        "store quarantine",
        "recovery observes a complete-but-invalid frame, a record naming a missing key file, or any "
        "quarantine row of the A1.2 table; or revocation of the active epoch (compound with T-epoch-revoked)",
        "derived — recovery source, or the revocation transaction", "the offending position and the rule it "
        "failed", "V-quarantine", ("X7",), "T-quarantined", "0a.2", "recovery", None),
    "linked-regenesis": (
        "linked re-genesis", "operator ceremony on a quarantined store", "operator-TTY",
        "the quarantined store's id, generation, last valid seq and digest, archive location, new genesis "
        "evidence", "V-regenesis", ("X6",), "the crash protocol below", "0a.2", "ceremony", "store.regenesis"),
}
ADMISSIBLE = ("epoch-rotation", "epoch-revocation", "authority-head-advance", "authority-genesis",
              "torn-frame-truncation", "anchor-replay-forward", "recovery-tidy", "store-quarantine",
              "linked-regenesis")
# 0a.2 section 1 and section 24: the dormant rows, each named explicitly.
DORMANT_ROWS = ("request-opening", "capability-issuance", "request-cancellation", "request-expiry",
                "capability-redemption", "gesture-nonce-issuance", "repository-registration",
                "repository-rebind", "execution-root-registration", "standing-authorization",
                "standing-revocation", "segment-discharge", "enrollment", "enrollment-revocation",
                "mechanism-closure", "acceptance-platform-designation", "release-acceptance")
# tg:855-868 and tg:844-849.
SOURCE_STATE = {"review": "node state", "triage": "node state", "scope-change": "node state",
                "approval": "node state", "attestation": "node state", "observation": "node state",
                "design-decision": "node state", "ceiling": "node state", "safety-boundary": "node state",
                "mechanism-closure": "mechanism state", "segment-discharge": "accumulator state",
                "release-acceptance": "candidate-release state"}
COMPOUND_BY_KIND = {kind: ("T-request-answered",) for kind in SOURCE_STATE}
COMPOUND_BY_KIND.update({"segment-discharge": ("T-request-answered", "T-segment-reset"),
                         "mechanism-closure": ("T-request-answered", "T-mechanism-closed"),
                         "release-acceptance": ("T-request-answered", "T-release-accepted")})

# The frozen closed command table (0a.2 section 3).
COMMANDS = {
    "git.init": ("git", ("<git-prefix>", "-C", "<scratch>", "init", "--bare", "--template=",
                         "--object-format=sha1", "."), "scratch"),
    "git.hash-object": ("git", ("<git-prefix>", "-C", "<scratch>", "hash-object", "-w", "--stdin"), "scratch"),
    "git.mktree": ("git", ("<git-prefix>", "-C", "<scratch>", "mktree"), "scratch"),
    "git.commit-tree": ("git", ("<git-prefix>", "-C", "<scratch>", "commit-tree", "<tree>", "<parent-opt>",
                                "-m", "<message>"), "scratch"),
    "git.fetch-anchor": ("git", ("<git-prefix>", "<transport>", "-C", "<scratch>", "fetch", "--no-tags",
                                 "--no-write-fetch-head", "<remote>",
                                 "+refs/olddonkey-loop/*:refs/readback/*"), "scratch"),
    "git.ls-remote": ("git", ("<git-prefix>", "<transport>", "-C", "<scratch>", "ls-remote", "<remote>",
                              "refs/olddonkey-loop/anchor"), "read"),
    "git.cat-file": ("git", ("<git-prefix>", "-C", "<scratch>", "cat-file", "<cat-mode>", "<oid>"), "read"),
    "git.update-anchor": ("git", ("<git-prefix>", "-C", "<scratch>", "update-ref",
                                  "refs/olddonkey-loop/anchor", "<commit>"), "scratch"),
    "git.anchor-refs": ("git", ("<git-prefix>", "-C", "<scratch>", "for-each-ref",
                                "--format=%(objectname) %(refname)", "refs/olddonkey-loop/"), "read"),
    "git.push-anchor": ("git", ("<git-prefix>", "<transport>", "-C", "<scratch>", "push", "<remote>",
                                "refs/olddonkey-loop/*:refs/olddonkey-loop/*"), "sink"),
    "ssh-keygen.generate": ("ssh-keygen", ("-q", "-t", "ed25519", "-N", "", "-C", "<comment>", "-f",
                                           "<key-temp>"), "sink"),
    "ssh-keygen.certify": ("ssh-keygen", ("-q", "-s", "<root>", "-I", "<type>@e<epoch>", "-n", "<type>", "-V",
                                          "always:forever", "<subkey-pub>"), "sink"),
    "ssh-keygen.sign": ("ssh-keygen", ("-Y", "sign", "-f", "<subkey>", "-n",
                                       "olddonkey-loop.authority.<type>.v1"), "sink"),
    "ssh-keygen.verify": ("ssh-keygen", ("-Y", "verify", "-f", "<allowed-signers>", "-I", "<type>", "-n",
                                         "olddonkey-loop.authority.<type>.v1", "-s", "<sig>"), "read"),
    "ssh-keygen.sign-pointer": ("ssh-keygen", ("-Y", "sign", "-f", "<root>", "-n",
                                               "olddonkey-loop.anchor.pointer.v1"), "sink"),
    "ssh-keygen.verify-pointer": ("ssh-keygen", ("-Y", "verify", "-f", "<allowed-signers>", "-I", "anchor-root",
                                                 "-n", "olddonkey-loop.anchor.pointer.v1", "-s", "<sig>"), "read"),
    "ssh-keygen.fingerprint": ("ssh-keygen", ("-l", "-E", "sha256", "-f", "<pub>"), "read"),
}

# The frozen sink-function list (0a.2 section 3, "Sink ownership").
SINK_FUNCTIONS = (
    "create_store_dir", "create_key_dir", "create_key", "certify_key", "seal", "seal_pointer",
    "write_intent", "write_genesis_intent", "write_regenesis_intent", "append_frame", "complete_delimiter",
    "truncate_frame", "remove_intent", "remove_genesis_intent", "remove_regenesis_intent", "write_cursor",
    "write_quarantine", "write_active", "archive_store", "push_anchor",
)
# Private helpers only the sinks call; each grants itself a one-shot permit.
SINK_HELPERS = ("_publish", "_remove", "_write_intent_file", "_run_sink")
# Each sink command, and the one sink function that may run it.
SINK_COMMAND_OWNER = {"git.push-anchor": "push_anchor", "ssh-keygen.generate": "create_key",
                      "ssh-keygen.certify": "certify_key", "ssh-keygen.sign": "seal",
                      "ssh-keygen.sign-pointer": "seal_pointer"}

# ===========================================================================
# The reachability scan
# ===========================================================================

# Functions allowed to use raw write or process primitives, with why.
RAW_WRITE_ALLOWED = {
    # the low-level store writes: each consumes its sink's one-shot permit
    "store._fs_mkdir", "store._fs_create", "store._fs_replace", "store._fs_append", "store._fs_truncate",
    "store._fs_unlink", "store._fs_rename_dir", "store._fs_read_only_tree",
    "store._fs_link_published", "store._fs_unlink_temp",
    # the full-write loop over an fd those low-level writes opened
    "store._write_all",
    # infrastructure A1.5 does not list: the authority directories and the lock
    "store.ensure_layout", "store.WriterLock.__enter__",
    # scratch space under $HOME/.cache/olddonkey-loop, runtime-checked never under authority
    "tools._open_dir_chain", "tools.scratch_tmp", "tools._remove_tree", "tools.write_scratch_file",
    "tools.new_scratch_repo",
    # the ceremony's terminal output (fd 1)
    "ceremony._write",
}
PROCESS_ALLOWED = {"tools.run"}
CTYPES_ALLOWED = {"ceremony._libc", "ceremony.read_boot_id", "ceremony.read_start_time"}
PASS_THROUGH = {"tools.run", "store._run_sink", "anchor._git"}
# Who may mint a token: ceremony tokens and compound children in ceremony.py;
# recovery and finish tokens only in recover._mint, from an issued plan.
TOKEN_MINTERS = {"begin": ("ceremony",), "begin_recovery": ("recover._mint",),
                 "begin_finish": ("recover._mint",), "child": ("ceremony",)}

WRITE_OS = {"write", "pwrite", "writev", "pwritev", "ftruncate", "truncate", "rename", "replace", "renames",
            "link", "symlink", "unlink", "remove", "rmdir", "removedirs", "mkdir", "makedirs", "chmod",
            "fchmod", "lchmod", "chown", "fchown", "lchown", "chflags", "lchflags", "utime", "mkfifo", "mknod",
            "dup2", "sendfile", "copy_file_range", "splice", "setxattr", "removexattr"}
PROCESS_OS = {"system", "popen", "fork", "forkpty", "execv", "execve", "execl", "execle", "execlp", "execlpe",
              "execvp", "execvpe", "spawnv", "spawnve", "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnvp",
              "spawnvpe", "posix_spawn", "posix_spawnp", "kill", "killpg"}
READ_FLAGS = {"O_RDONLY", "O_NOFOLLOW", "O_DIRECTORY", "O_CLOEXEC", "O_NONBLOCK", "O_NOCTTY"}
PROCESS_MODULES = {"subprocess", "pty", "multiprocessing", "asyncio", "concurrent"}
WRITE_MODULES = {"shutil", "pathlib", "io", "tempfile"}
MODULE_NAMES = {"os", "subprocess", "shutil", "tools", "store", "sys", "io", "pty", "ctypes", "builtins",
                "importlib", "pathlib", "tempfile"}


class Scanner(ast.NodeVisitor):
    def __init__(self, module):
        self.module = module
        self.stack = []
        self.findings = []

    def where(self):
        return ".".join([self.module] + self.stack)

    def flag(self, node, what):
        self.findings.append((self.where(), node.lineno, what))

    def visit_FunctionDef(self, node):
        self.stack.append(node.name)
        self.generic_visit(node)
        self.stack.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ClassDef(self, node):
        self.stack.append(node.name)
        self.generic_visit(node)
        self.stack.pop()

    def visit_Import(self, node):
        for alias in node.names:
            root = alias.name.split(".")[0]
            if root in PROCESS_MODULES and self.module != "tools":
                self.flag(node, f"import {alias.name}")
            if root == "shutil" and self.module != "tools":
                self.flag(node, "import shutil")
            if root == "ctypes" and self.module != "ceremony":
                self.flag(node, "import ctypes")
            if root in ("importlib", "pathlib", "io"):
                self.flag(node, f"import {alias.name}")
        self.generic_visit(node)

    def visit_ImportFrom(self, node):
        root = (node.module or "").split(".")[0]
        if root in ("os", "subprocess", "shutil", "pty", "ctypes", "io", "pathlib", "tempfile", "importlib",
                    "builtins"):
            self.flag(node, f"from {node.module} import ...")
        if node.level and node.module in ("store", "tools"):
            names = {alias.name for alias in node.names}
            if names & set(SINK_FUNCTIONS + SINK_HELPERS + ("run", "begin", "begin_recovery", "begin_finish",
                                                           "child", "authorize_command")):
                self.flag(node, f"from .{node.module} import a sink or token function")
        self.generic_visit(node)

    def visit_Assign(self, node):
        for value in ast.walk(node.value):
            if isinstance(value, ast.Name) and value.id in MODULE_NAMES - {"tools", "store"} \
                    and isinstance(node.value, (ast.Name, ast.Tuple, ast.List, ast.Dict)):
                self.flag(node, f"module {value.id} bound to another name")
        self.generic_visit(node)

    def visit_Attribute(self, node):
        if isinstance(node.value, ast.Name):
            base, attr = node.value.id, node.attr
            here = self.where()
            if base == "os" and attr in WRITE_OS and here not in RAW_WRITE_ALLOWED:
                self.flag(node, f"os.{attr}")
            if base == "os" and attr in PROCESS_OS and here not in PROCESS_ALLOWED:
                self.flag(node, f"os.{attr}")
            if base in PROCESS_MODULES and here not in PROCESS_ALLOWED:
                self.flag(node, f"{base}.{attr}")
            if base == "shutil" and here not in RAW_WRITE_ALLOWED:
                self.flag(node, f"shutil.{attr}")
            if base == "tempfile" and attr != "tempdir":
                self.flag(node, f"tempfile.{attr}")
            if base in ("pathlib", "io", "importlib"):
                self.flag(node, f"{base}.{attr}")
            if base == "ctypes" and here not in CTYPES_ALLOWED:
                self.flag(node, f"ctypes.{attr}")
            if attr == "permit" and isinstance(node.ctx, ast.Store) and here not in (
                    "store._grant", "store._consume", "store._run_sink", "store.spend", "store.Token.__init__"):
                self.flag(node, "assignment to a token permit")
        self.generic_visit(node)

    def visit_Call(self, node):
        here = self.where()
        func = node.func
        name = func.id if isinstance(func, ast.Name) else None
        dotted = (f"{func.value.id}.{func.attr}" if isinstance(func, ast.Attribute)
                  and isinstance(func.value, ast.Name) else None)
        if name == "open" and here not in RAW_WRITE_ALLOWED:
            mode = node.args[1] if len(node.args) > 1 else next(
                (kw.value for kw in node.keywords if kw.arg == "mode"), None)
            if mode is not None and not (isinstance(mode, ast.Constant) and isinstance(mode.value, str)
                                         and not set(mode.value) & set("wax+")):
                self.flag(node, "open() for writing")
        if dotted == "os.open" and here not in RAW_WRITE_ALLOWED:
            flags = node.args[1] if len(node.args) > 1 else None
            names = {n.attr for n in ast.walk(flags) if isinstance(n, ast.Attribute)} if flags else set()
            literal_other = [n for n in ast.walk(flags) if isinstance(n, (ast.Constant, ast.Name))
                             and not (isinstance(n, ast.Name) and n.id == "os")] if flags else []
            if not names or names - READ_FLAGS or literal_other:
                self.flag(node, "os.open for writing")
        if name in ("eval", "exec", "compile", "__import__", "globals", "vars"):
            self.flag(node, f"{name}()")
        if name in ("getattr", "setattr", "delattr") and node.args:
            target = node.args[0]
            if isinstance(target, ast.Name) and target.id in MODULE_NAMES | {"__builtins__"}:
                self.flag(node, f"{name}() on a module (an aliased primitive)")
        # command calls: tools.run, store._run_sink, anchor._git, run inside tools
        is_command = (dotted == "tools.run" or (self.module == "tools" and name == "run")
                      or (self.module == "store" and name == "_run_sink")
                      or (self.module == "anchor" and name == "_git"))
        if is_command:
            index = 1 if (self.module == "store" and name == "_run_sink") else 0
            argument = node.args[index] if len(node.args) > index else None
            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                command = argument.value
                effect = COMMANDS.get(command, (None, None, "unlisted"))[2]
                function = here.split(".")[-1]
                if effect == "unlisted":
                    self.flag(node, f"command outside the table: {command}")
                elif effect == "sink" and not (self.module == "store"
                                               and function == SINK_COMMAND_OWNER[command]):
                    self.flag(node, f"sink command {command} outside its sink function")
                if self.module in ("keys", "anchor") and effect not in ("read", "scratch"):
                    self.flag(node, f"{self.module}.py reaches a {effect} command: {command}")
            elif here not in PASS_THROUGH:
                self.flag(node, "a command id that is not a literal")
        # low-level sink helpers only from sinks
        if self.module == "store" and name and (name.startswith("_fs_") or name in SINK_HELPERS
                                                or name == "_grant"):
            function = here.split(".")[1] if "." in here else here
            if function not in SINK_FUNCTIONS + SINK_HELPERS:
                self.flag(node, f"{name} called outside a sink")
        if dotted and dotted.startswith("store._"):
            attr = dotted.split(".", 1)[1]
            if attr.startswith("_fs_") or attr in SINK_HELPERS + ("_grant", "_consume"):
                self.flag(node, f"{dotted} called outside store.py")
        # token minting
        if dotted and dotted.split(".")[0] == "store" and dotted.split(".")[1] in TOKEN_MINTERS:
            allowed = TOKEN_MINTERS[dotted.split(".")[1]]
            if not any(here == where or here.startswith(where + ".") for where in allowed):
                self.flag(node, f"{dotted} called from {here}")
        self.generic_visit(node)


def scan(lib):
    package = os.path.join(lib, "loopauth")
    findings = []
    for filename in sorted(os.listdir(package)):
        if not filename.endswith(".py"):
            continue
        module = filename[:-3]
        with open(os.path.join(package, filename), encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), filename)
        scanner = Scanner(module)
        scanner.visit(tree)
        findings += scanner.findings
    return findings


def sink_functions_in(lib):
    with open(os.path.join(lib, "loopauth", "store.py"), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    names = {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}
    return names


def plant(name, filename, code):
    copy = os.path.join(TMP, f"planted-{name}", "lib")
    shutil.copytree(LIB, copy)
    with open(os.path.join(copy, "loopauth", filename), "a", encoding="utf-8") as handle:
        handle.write("\n\n" + code)
    return copy


PLANTS = {
    "an extra unchecked Python file write into the store": (
        "recover.py", "def _bypass_write(path):\n    with open(path, \"w\") as handle:\n        handle.write(\"x\")\n"),
    "a direct subprocess.run of git in the authority directory": (
        "anchor.py", "import subprocess\n\n\ndef _bypass_git(root):\n"
                     "    return subprocess.run([\"git\", \"status\"], cwd=root)\n"),
    "an unchecked key-file write in keys.py": (
        "keys.py", "import os\n\n\ndef _bypass_key(path, data):\n"
                   "    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)\n    os.write(fd, data)\n"),
    "a direct tools.run of git.push-anchor from a non-sink function": (
        "recover.py", "def _bypass_push(scratch, url, commit):\n"
                      "    return tools.run(\"git.push-anchor\", scratch=scratch, remote=url, commit=commit)\n"),
}


# ===========================================================================
# 0a.3: the read-only verification modules reach no sink
# ===========================================================================

READ_ONLY_MODULES = ("refs", "eligibility", "journal_read")
# The only imports each may make (eligibility.py is pure).
READ_ONLY_IMPORTS = {
    "refs": {"__future__", "eligibility", "journal_read", "recover", "reduce", "vocabulary"},
    "eligibility": {"__future__"},
    "journal_read": {"__future__", "hashlib", "json", "os", "stat", "vocabulary"},
}
# The authority store's modules, and the one name of them a read-only module
# may use: 0a.2's read-only classification (what `loop-authority status` runs).
STORE_MODULES = {"store", "tools", "ceremony", "registry", "anchor", "keys", "records", "frame", "recover"}
READ_ONLY_STORE_NAMES = {"recover": {"classify"}}
# The os names a read-only module may use: reads only (os.open's flags are
# the general scan's READ_FLAGS rule).
READ_ONLY_OS = {"path", "environ", "getuid", "lstat", "fstat", "stat_result", "open", "read", "close", "sep",
                "O_RDONLY", "O_NOFOLLOW"}
LOCK_NAMES = {"fcntl", "flock", "lockf", "WriterLock", "ReaderLock"}
# Module aliases are refused outright (fail closed), so the rules above and
# the call graph only ever see a module by its own name: a name an import
# binds to a module may appear only as the receiver of a read `module.name`,
# never as a value (assigned, passed -- getattr included -- stored in a
# container or an attribute, returned); no import renames (`as`) or star
# import; `from .sibling import name` must resolve to a name the sibling
# defines, not one it imports; no absolute from-import (it binds a library
# name bare); no attribute chain through a module may yield a module (os.path
# excepted, and os.path, a module, is itself receiver-only like a module
# name); for a sibling `module.name` is a name it defines; no route to a
# module namespace (globals() and the like, a dunder attribute, a frame); and
# no dynamic attribute access at all (getattr and its kin, any arguments).
NAMESPACE_NAMES = {"globals", "locals", "vars", "eval", "exec", "compile"}
FRAME_ATTRIBUTES = {"f_globals", "f_locals", "f_builtins", "f_back", "gi_frame", "cr_frame", "ag_frame",
                    "tb_frame"}
DYNAMIC_ATTRIBUTE = {"getattr", "setattr", "delattr", "hasattr", "attrgetter", "methodcaller", "__getattribute__"}
SUBMODULES_ALLOWED = {"os.path"}
MISSING = object()


def namespaces(lib):
    """Per lib/loopauth module: (the names it defines at top level, the names
    it binds by an import anywhere)."""
    package = os.path.join(lib, "loopauth")
    spaces = {}
    for filename in sorted(os.listdir(package)):
        if not filename.endswith(".py"):
            continue
        with open(os.path.join(package, filename), encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), filename)
        defined, imported = set(), set()
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                defined.add(node.name)
            elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                for target in node.targets if isinstance(node, ast.Assign) else [node.target]:
                    defined |= {n.id for n in ast.walk(target) if isinstance(n, ast.Name)
                                and isinstance(n.ctx, ast.Store)}
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                imported |= {alias.asname or alias.name.split(".")[0] for alias in node.names}
        spaces[filename[:-3]] = (defined, imported)
    return spaces


def dunder(name):
    return name.startswith("__") and name.endswith("__")


class ReadOnlyScanner(ast.NodeVisitor):
    """The direct rules for refs.py, eligibility.py, and journal_read.py."""

    def __init__(self, module, tree, spaces):
        self.module = module
        self.findings = []
        self.spaces = spaces
        # every name an import binds to a module, resolved: a sibling's name,
        # or an allowed library module imported here to walk its attributes
        self.modules, self.siblings, self.libraries, self.receivers = set(), {}, {}, set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    root = alias.name.split(".")[0]
                    name, target = (alias.asname, alias.name) if alias.asname else (root, root)
                    self.modules.add(name)
                    if root in READ_ONLY_IMPORTS[module] and root != "__future__" and root not in spaces:
                        try:
                            self.libraries[name] = (target, importlib.import_module(target))
                        except ImportError:
                            self.libraries[name] = (target, MISSING)
            elif isinstance(node, ast.ImportFrom) and node.level and node.module is None:
                for alias in node.names:
                    self.modules.add(alias.asname or alias.name)
                    if node.level == 1 and alias.name in spaces:
                        self.siblings[alias.asname or alias.name] = alias.name

    def flag(self, node, what):
        self.findings.append((self.module, node.lineno, what))

    def visit_Import(self, node):
        for alias in node.names:
            if alias.name.split(".")[0] not in READ_ONLY_IMPORTS[self.module]:
                self.flag(node, f"import {alias.name}")
            if alias.asname:
                self.flag(node, f"module alias: import {alias.name} as {alias.asname}")
        self.generic_visit(node)

    def visit_ImportFrom(self, node):
        if node.level and node.module is None:
            names = [alias.name for alias in node.names]
        else:
            names = [(node.module or "").split(".")[0]]
        for name in names:
            if name not in READ_ONLY_IMPORTS[self.module]:
                self.flag(node, f"import of {name}")
        source = "." * node.level + (node.module or "")
        for alias in node.names:
            if alias.asname or alias.name == "*":
                self.flag(node, f"module alias: from {source} import {alias.name}"
                                + (f" as {alias.asname}" if alias.asname else ""))
        if node.level and node.module is not None:
            space = self.spaces.get(node.module) if node.level == 1 else None
            for alias in node.names:
                if space is None or alias.name in space[1] or alias.name not in space[0]:
                    self.flag(node, f"module alias: from {source} import {alias.name} does not resolve to a name "
                                    f"{node.module}.py defines")
                elif node.module in STORE_MODULES and alias.name not in READ_ONLY_STORE_NAMES.get(node.module, ()):
                    self.flag(node, f"{node.module}.{alias.name}")
        elif not node.level and node.module != "__future__":
            self.flag(node, f"module alias: from {source} import binds a library name bare")
        self.generic_visit(node)

    def module_attribute(self, node, root, chain):
        name = root.id
        if root is node.value:
            self.receivers.add(id(root))
            if not isinstance(node.ctx, ast.Load):
                self.flag(node, f"module alias: a store into module {name}")
            sibling = self.siblings.get(name)
            if sibling is not None:
                defined, imported = self.spaces[sibling]
                if node.attr in imported or node.attr not in defined:
                    self.flag(node, f"module alias: {name}.{node.attr} is not a name {sibling}.py defines")
        if name in self.libraries:
            dotted, value = self.libraries[name]
            for attr in chain:
                dotted = f"{dotted}.{attr}"
                value = MISSING if value is MISSING else getattr(value, attr, MISSING)
            if value is MISSING:
                self.flag(node, f"module alias: {dotted} does not resolve")
            elif isinstance(value, type(os)) and dotted not in SUBMODULES_ALLOWED:
                self.flag(node, f"module alias: {dotted} is a module reached through another module")
            elif isinstance(value, type(os)) and id(node) not in self.receivers:
                self.flag(node, f"module alias: module {dotted} used as a value, not as {dotted}.<name>")

    def visit_Attribute(self, node):
        self.receivers.add(id(node.value))
        chain, root = [node.attr], node.value
        while isinstance(root, ast.Attribute):
            chain.insert(0, root.attr)
            root = root.value
        if isinstance(root, ast.Name) and root.id in self.modules:
            self.module_attribute(node, root, chain)
        if isinstance(node.value, ast.Name):
            base = node.value.id
            if base in STORE_MODULES and node.attr not in READ_ONLY_STORE_NAMES.get(base, set()):
                self.flag(node, f"{base}.{node.attr}")
            if base == "os" and node.attr not in READ_ONLY_OS:
                self.flag(node, f"os.{node.attr}")
        if node.attr in LOCK_NAMES:
            self.flag(node, f"a lock: {node.attr}")
        if (dunder(node.attr) and node.attr != "__init__") or node.attr in FRAME_ATTRIBUTES:
            self.flag(node, f"module alias: .{node.attr} reaches a namespace")
        if node.attr in DYNAMIC_ATTRIBUTE:
            self.flag(node, f"dynamic attribute access: .{node.attr}")
        self.generic_visit(node)

    def visit_Name(self, node):
        if node.id in LOCK_NAMES:
            self.flag(node, f"a lock: {node.id}")
        if node.id in DYNAMIC_ATTRIBUTE:
            self.flag(node, f"dynamic attribute access: {node.id}")
        if node.id in self.modules and id(node) not in self.receivers:
            self.flag(node, f"module alias: module {node.id} used as a value, not as {node.id}.<name>")
        if node.id in NAMESPACE_NAMES or dunder(node.id):
            self.flag(node, f"module alias: {node.id} reaches a namespace")
        self.generic_visit(node)


def call_graph(lib):
    """A conservative call graph of lib/loopauth: an edge for every
    reference (called or passed as a value) that resolves by name -- a bare
    name defined in the same module or imported from a sibling, a sibling
    module's attribute, and, for any other attribute (the receiver's type is
    unknown), every method of that name on any class. A reference to a class
    reaches all its methods (constructor, context manager, __call__)."""
    package = os.path.join(lib, "loopauth")
    trees = {}
    for filename in sorted(os.listdir(package)):
        if filename.endswith(".py"):
            with open(os.path.join(package, filename), encoding="utf-8") as handle:
                trees[filename[:-3]] = ast.parse(handle.read(), filename)
    functions, classes, methods = {}, {}, {}
    for module, tree in trees.items():
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                functions.setdefault(f"{module}.{node.name}", []).append(node)
            elif isinstance(node, ast.ClassDef):
                owner = classes.setdefault(f"{module}.{node.name}", [])
                for item in node.body:
                    if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        qual = f"{module}.{node.name}.{item.name}"
                        functions.setdefault(qual, []).append(item)
                        owner.append(qual)
                        methods.setdefault(item.name, set()).add(qual)

    def resolve(qual):
        return {qual} if qual in functions else set(classes.get(qual, ()))

    edges = {}
    for module, tree in trees.items():
        siblings, imported = {}, {}
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.level:
                for alias in node.names:
                    if node.module is None:
                        siblings[alias.asname or alias.name] = alias.name
                    else:
                        imported[alias.asname or alias.name] = f"{node.module}.{alias.name}"
        for qual, nodes in functions.items():
            if qual.split(".")[0] != module:
                continue
            targets = set()
            for function in nodes:
                for node in ast.walk(function):
                    if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                        targets |= resolve(f"{module}.{node.id}") | resolve(imported.get(node.id, ""))
                    elif isinstance(node, ast.Attribute):
                        if isinstance(node.value, ast.Name) and node.value.id in siblings:
                            targets |= resolve(f"{siblings[node.value.id]}.{node.attr}")
                        else:
                            targets |= methods.get(node.attr, set())
            edges[qual] = targets
    return functions, edges


def sink_targets(functions):
    """Every function that writes authority state or can reach the remote
    with a write: the sinks and their helpers, the token minters, the
    low-level writes, the layout and writer lock, and every function that
    runs a sink command."""
    targets = {f"store.{name}" for name in SINK_FUNCTIONS + SINK_HELPERS + tuple(TOKEN_MINTERS)}
    targets |= {"store._grant", "store.ensure_layout", "store.WriterLock.__enter__"}
    targets |= {qual for qual in functions if qual.startswith("store._fs_")}
    for qual, nodes in functions.items():
        module = qual.split(".")[0]
        for function in nodes:
            for node in ast.walk(function):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                name = func.id if isinstance(func, ast.Name) else None
                dotted = (f"{func.value.id}.{func.attr}" if isinstance(func, ast.Attribute)
                          and isinstance(func.value, ast.Name) else None)
                if not (dotted == "tools.run" or (module == "tools" and name == "run")
                        or (module == "store" and name == "_run_sink") or (module == "anchor" and name == "_git")):
                    continue
                index = 1 if (module == "store" and name == "_run_sink") else 0
                argument = node.args[index] if len(node.args) > index else None
                if isinstance(argument, ast.Constant) and COMMANDS.get(argument.value, (None, None, None))[2] == "sink":
                    targets.add(qual)
    return targets


def read_only_scan(lib):
    """(direct findings, call paths from a read-only module to a sink target,
    every function reached)."""
    direct = []
    package = os.path.join(lib, "loopauth")
    spaces = namespaces(lib)
    for module in READ_ONLY_MODULES:
        path = os.path.join(package, f"{module}.py")
        if not os.path.exists(path):
            direct.append((module, 0, "missing"))
            continue
        with open(path, encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), path)
        scanner = ReadOnlyScanner(module, tree, spaces)
        scanner.visit(tree)
        direct += scanner.findings
    functions, edges = call_graph(lib)
    targets = sink_targets(functions)
    parent = {qual: None for qual in functions if qual.split(".")[0] in READ_ONLY_MODULES}
    queue = sorted(parent)
    paths = []
    while queue:
        qual = queue.pop(0)
        if qual in targets:
            path, step = [], qual
            while step is not None:
                path.append(step)
                step = parent[step]
            paths.append(" <- ".join(path))
            continue
        for following in sorted(edges.get(qual, ())):
            if following not in parent:
                parent[following] = qual
                queue.append(following)
    return direct, paths, set(parent)


READ_ONLY_PLANTS = {
    "refs.py calls a store sink (write_quarantine)": (
        "refs.py", "def _bypass_marker(token, store_id):\n"
                   "    return store.write_quarantine(token, store_id=store_id, data=b\"x\")\n"),
    "refs.py runs recovery (recover.recover)": (
        "refs.py", "def _bypass_recover():\n    return recover.recover()\n"),
    "refs.py takes the authority reader lock": (
        "refs.py", "def _bypass_lock():\n    with store.ReaderLock():\n        return recover.classify()\n"),
    "journal_read.py runs the anchor push": (
        "journal_read.py", "def _bypass_push(scratch, url, commit):\n"
                           "    return tools.run(\"git.push-anchor\", scratch=scratch, remote=url, commit=commit)\n"),
    "journal_read.py flocks the journal's meta.lock": (
        "journal_read.py", "import fcntl\n\n\ndef _bypass_flock(fd):\n    fcntl.flock(fd, fcntl.LOCK_SH)\n"),
    "journal_read.py truncates the segment (a repair)": (
        "journal_read.py", "def _bypass_repair(fd, size):\n    os.ftruncate(fd, size)\n"),
    "eligibility.py mints a recovery token": (
        "eligibility.py", "from . import store\n\n\ndef _bypass_mint(plan):\n    return store.begin_recovery(plan)\n"),
}
# Each hides a module under another name; the direct rules refuse the alias
# itself, whatever the call graph can follow.
ALIAS_PLANTS = {
    "refs.py assigns a module to another name (alias = recover; alias.recover())": (
        "refs.py", "def _bypass_alias():\n    alias = recover\n    return alias.recover()\n"),
    "refs.py imports a module under another name (from . import recover as r)": (
        "refs.py", "from . import recover as r\n\n\ndef _bypass_as():\n    return r.recover()\n"),
    "journal_read.py imports os under another name (import os as o)": (
        "journal_read.py", "import os as o\n\n\ndef _bypass_as(fd, size):\n    o.ftruncate(fd, size)\n"),
    "refs.py takes a module's attribute with getattr (getattr(recover, \"recover\"))": (
        "refs.py", "def _bypass_getattr():\n    return getattr(recover, \"recover\")()\n"),
    "refs.py stores a module in a dict": (
        "refs.py", "_MODULES = {\"r\": recover}\n\n\ndef _bypass_dict():\n    return _MODULES[\"r\"].recover()\n"),
    "journal_read.py stores os in a list": (
        "journal_read.py", "_MODULES = [os]\n\n\ndef _bypass_list(fd, size):\n    _MODULES[0].ftruncate(fd, size)\n"),
    "refs.py stores a module in an attribute": (
        "refs.py", "class _Holder:\n    pass\n\n\n_Holder.module = recover\n\n\n"
                   "def _bypass_attribute():\n    return _Holder.module.recover()\n"),
    "refs.py reaches a module through a sibling's attribute (journal_read.os)": (
        "refs.py", "def _bypass_sibling(fd, size):\n    journal_read.os.ftruncate(fd, size)\n"),
    "refs.py from-imports a module a sibling imports (from .reduce import v)": (
        "refs.py", "from .reduce import v\n\n\ndef _bypass_reexport():\n    return v.select_row(None, None)\n"),
    "journal_read.py reaches a module through a library module's attribute (json.codecs)": (
        "journal_read.py", "def _bypass_codecs(path):\n    return json.codecs.open(path, \"w\")\n"),
    "refs.py reads a module out of globals()": (
        "refs.py", "def _bypass_globals():\n    return globals()[\"recover\"].recover()\n"),
    "refs.py reads a module out of a function's __globals__": (
        "refs.py", "def _bypass_dunder():\n    return classify_field.__globals__[\"recover\"].recover()\n"),
    "refs.py reads a module out of a frame (gi_frame.f_globals)": (
        "refs.py", "def _bypass_frame():\n    caller = (lambda: (yield))().gi_frame\n"
                   "    return caller.f_globals[\"recover\"].recover()\n"),
    "eligibility.py imports a module with __import__": (
        "eligibility.py", "def _bypass_import(plan):\n"
                          "    return __import__(\"loopauth.store\").store.begin_recovery(plan)\n"),
}
# Each reaches an attribute no static rule sees (os.path.os is os): refused
# outright by the finding named, whatever the arguments.
DYNAMIC_PLANTS = {
    "journal_read.py reaches os.unlink through getattr (getattr(os.path, \"os\").unlink(p))": (
        "journal_read.py", "def _bypass_getattr(path):\n    getattr(os.path, \"os\").unlink(path)\n",
        "dynamic attribute access"),
    "journal_read.py reaches os.unlink through os.path (os.path.os.unlink(p))": (
        "journal_read.py", "def _bypass_chain(path):\n    os.path.os.unlink(path)\n",
        "module alias: os.path.os is a module reached through another module"),
    "journal_read.py holds os.path as a value (p = os.path; p.os.unlink(path))": (
        "journal_read.py", "def _bypass_value(path):\n    p = os.path\n    p.os.unlink(path)\n",
        "module alias: module os.path used as a value"),
    "eligibility.py calls setattr on its own arguments (setattr(target, name, value))": (
        "eligibility.py", "def _bypass_setattr(target, name, value):\n    setattr(target, name, value)\n",
        "dynamic attribute access"),
    "journal_read.py reaches os.unlink through operator.attrgetter (operator.attrgetter(\"unlink\")(os))": (
        "journal_read.py", "import operator\n\n\ndef _bypass_attrgetter(path):\n"
                           "    operator.attrgetter(\"unlink\")(os)(path)\n",
        "dynamic attribute access"),
    "journal_read.py probes os with hasattr (hasattr(os, \"unlink\"))": (
        "journal_read.py", "def _bypass_hasattr():\n    return hasattr(os, \"unlink\")\n",
        "dynamic attribute access"),
}


def main_static():
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, registry, store, tools  # noqa: E402

    # --- the registry oracle
    emit("registry: the exclusions X1-X7 are tg:874-880 in the order written", registry.EXCLUSIONS == X,
         [k for k in X if registry.EXCLUSIONS.get(k) != X[k]])
    emit("registry: every row of tg:809-829 and A1.3 is registered, and nothing else",
         set(registry.ROW_BY_ID) == set(ORACLE) and len(registry.ROWS) == len(ORACLE) == 26,
         sorted(set(registry.ROW_BY_ID) ^ set(ORACLE)))
    for row_id, want in ORACLE.items():
        row = registry.ROW_BY_ID.get(row_id)
        if row is None:
            emit(f"registry: {row_id} is registered", False)
            continue
        got = (row["operation"], row["trigger"], row["principal"], row["evidence"], row["validator"],
               row["exclusions"], row["transition"], row["admissible_from"], row["entry"], row["record_type"])
        emit(f"registry: {row_id} has its six columns, exclusion ids, admissibility, and entry", got == want,
             [f"{i}: {a!r} != {b!r}" for i, (a, b) in enumerate(zip(got, want)) if a != b])
        emit(f"registry: {row_id} is {'admissible' if row_id in ADMISSIBLE else 'dormant'} in 0a.2",
             row["admissible"] == (row_id in ADMISSIBLE))
    emit("registry: every exclusion id a row names is defined",
         all(x in X for row in registry.ROWS for x in row["exclusions"]))
    emit("registry: the dormant rows are exactly the ones 0a.2 section 1 names (gesture-nonce issuance "
         "until unit 4)", set(registry.DORMANT) == set(DORMANT_ROWS) and len(DORMANT_ROWS) == 17,
         sorted(set(registry.DORMANT) ^ set(DORMANT_ROWS)))
    emit("registry: 0a.2 admits exactly genesis, rotation, revocation, head advance, truncation, "
         "replay-forward, tidy, quarantine, and re-genesis", set(registry.ADMISSIBLE) == set(ADMISSIBLE))
    emit("registry: the request kinds and their source states are tg:855-868",
         registry.REQUEST_SOURCE_STATES == SOURCE_STATE)
    emit("registry: capability redemption's compound transition by kind is tg:844-849",
         registry.REDEMPTION_COMPOUND == COMPOUND_BY_KIND)
    emit("registry: segment discharge, mechanism closure, and release acceptance are compound children of "
         "capability redemption only (never a separate external entry)",
         registry.ROW_BY_ID["capability-redemption"]["children"]
         == ("segment-discharge", "mechanism-closure", "release-acceptance")
         and all(registry.ROW_BY_ID[r]["parent"] == "capability-redemption"
                 and registry.ROW_BY_ID[r]["entry"] == "compound"
                 for r in ("segment-discharge", "mechanism-closure", "release-acceptance")))
    emit("registry: capability issuance is request opening's compound child (A1.9, one transaction)",
         registry.ROW_BY_ID["request-opening"]["children"] == ("capability-issuance",)
         and registry.ROW_BY_ID["capability-issuance"]["parent"] == "request-opening")
    emit("registry: request cancellation has its two branches, the gesture and the source invalidation",
         registry.ROW_BY_ID["request-cancellation"]["branches"]
         == {"gesture": "external", "source-invalidated": "derived"})
    derived = [r["id"] for r in registry.ROWS if r["entry"] in ("derived", "recovery", "compound")]
    emit("registry: every derived row (no external entry point) carries X7",
         all("X7" in registry.ROW_BY_ID[r]["exclusions"] for r in derived), derived)
    # --- external entry points (A1.5 reachability): each maps to exactly one row
    emit("entry points: each ceremony is the one external entry point of exactly one row, and every "
         "admissible ceremony row has one", sorted(ceremony.CEREMONY_ROWS.values())
         == sorted(r["id"] for r in registry.ROWS if r["entry"] == "ceremony" and r["admissible"])
         and len(set(ceremony.CEREMONY_ROWS.values())) == len(ceremony.CEREMONY_ROWS), ceremony.CEREMONY_ROWS)
    emit("entry points: no ceremony reaches a derived row",
         not set(ceremony.CEREMONY_ROWS.values()) & set(derived))
    # --- the command table
    table = {cid: (spec["binary"], spec["argv"], spec["effect"]) for cid, spec in tools.COMMAND_TABLE.items()}
    emit("tools: the closed command table equals the frozen copy", table == COMMANDS,
         sorted(set(table.items()) ^ set(COMMANDS.items()))[:4])
    emit("tools: every command that contacts the remote carries the transport options",
         all("<transport>" in COMMANDS[c][1] for c in ("git.fetch-anchor", "git.ls-remote", "git.push-anchor")))
    emit("tools: every git command starts with the hooksPath/fsmonitor prefix",
         all(argv[0] == "<git-prefix>" for binary, argv, _e in COMMANDS.values() if binary == "git")
         and tools.GIT_PREFIX == ("-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"))
    # --- the sink-function list
    emit("store: the sink-function list is the frozen one", tuple(store.SINK_FUNCTIONS) == SINK_FUNCTIONS,
         store.SINK_FUNCTIONS)
    defined = sink_functions_in(LIB)
    emit("store: every frozen sink function is defined in store.py", set(SINK_FUNCTIONS) <= defined,
         sorted(set(SINK_FUNCTIONS) - defined))
    # --- reachability
    findings = scan(LIB)
    emit("reachability: no write, process, or sink command in lib/loopauth escapes the token-checked sinks "
         "(AST scan)", not findings, findings[:8])
    for label, (filename, code) in PLANTS.items():
        copy = plant(re.sub(r"[^a-z]+", "-", label)[:30], filename, code)
        planted = scan(copy)
        emit(f"reachability negative control: {label} makes the scan fail", bool(planted), planted[:3])
    # --- 0a.3: refs.py, eligibility.py, and journal_read.py are read-only
    direct, paths, reached = read_only_scan(LIB)
    emit("reachability (0a.3): refs.py, eligibility.py, and journal_read.py exist and pass the direct read-only "
         "rules (import allowlists; of the store's code only recover.classify; os reads only; no lock; no module "
         "alias; no dynamic attribute access)", not direct, direct[:6])
    emit("reachability (0a.3): no call path from refs.py, eligibility.py, or journal_read.py reaches a store sink, a "
         "sink helper, a token minter, a low-level write, the layout or writer lock, or a sink command (transitive "
         "AST call graph)", not paths, paths[:3])
    traced = {"recover.classify", "recover.observe", "recover._read_remote", "anchor.ls_remote", "tools.run"}
    emit("reachability (0a.3): the call graph is not vacuous -- it follows refs into 0a.2's read-only classification "
         "and the read commands it runs", traced <= reached, sorted(traced - reached))
    for label, (filename, code) in READ_ONLY_PLANTS.items():
        copy = plant("ro-" + re.sub(r"[^a-z]+", "-", label)[:30], filename, code)
        planted_direct, planted_paths, _reached = read_only_scan(copy)
        emit(f"reachability negative control (0a.3): {label} makes the read-only scan fail",
             bool(planted_direct or planted_paths), (planted_direct[:2], planted_paths[:1]))
    for index, (label, (filename, code)) in enumerate(ALIAS_PLANTS.items()):
        copy = plant(f"ro-alias-{index}", filename, code)
        planted_direct, _paths, _reached = read_only_scan(copy)
        aliases = [finding for finding in planted_direct if finding[2].startswith("module alias")]
        emit(f"reachability negative control (0a.3): {label} makes the read-only scan fail (a module alias, "
             "refused outright)", bool(aliases), planted_direct[:3])
    for index, (label, (filename, code, finding)) in enumerate(DYNAMIC_PLANTS.items()):
        copy = plant(f"ro-dynamic-{index}", filename, code)
        planted_direct, _paths, _reached = read_only_scan(copy)
        emit(f"reachability negative control (0a.3): {label} makes the read-only scan fail ({finding}, refused "
             "outright)", any(what.startswith(finding) for _m, _l, what in planted_direct), planted_direct[:3])
    copy = plant("ro-classify-recovers", "recover.py", "def classify() -> Plan:\n    return recover()\n")
    planted_direct, planted_paths, _reached = read_only_scan(copy)
    emit("reachability negative control (0a.3): a recover.classify that runs recovery is caught by the transitive "
         "scan alone (the direct rules still pass)", not planted_direct and bool(planted_paths),
         (planted_direct[:2], planted_paths[:1]))


# ===========================================================================
# Tokens and sinks against a real store (in-process)
# ===========================================================================

def refused(function, *codes):
    try:
        function()
    except Exception as error:  # noqa: BLE001
        code = getattr(error, "code", type(error).__name__)
        return (not codes or code in codes), code
    return False, "not refused"


def fresh_store(label, lib=None):
    """HOME, a bare remote, and a committed genesis made by the ceremony core
    with the challenge stubbed. Returns the loaded modules and paths."""
    base = os.path.join(TMP, label)
    home = os.path.join(base, "home")
    os.makedirs(home)
    remote = os.path.join(base, "remote.git")
    git("init", "--bare", "-q", remote)
    os.environ["HOME"] = home
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    sys.path.insert(0, lib or LIB)
    sys.dont_write_bytecode = True
    import importlib
    mods = {name: importlib.import_module(f"loopauth.{name}")
            for name in ("canonical", "records", "frame", "keys", "anchor", "tools", "store", "recover",
                         "registry", "ceremony")}
    mods["ceremony"].challenge = lambda envelope: None
    url = "file://" + remote
    with mods["store"].WriterLock():
        mods["ceremony"].genesis(PRINCIPAL, url)
    return mods, remote, url


def remote_ref(remote):
    return git("--git-dir", remote, "rev-parse", "--verify", "-q", ANCHOR_REF, check=False).stdout


def main_tokens():
    m, remote, url = fresh_store("tokens")
    store, tools, registry, keys, records, recover = (m["store"], m["tools"], m["registry"], m["keys"],
                                                      m["records"], m["recover"])
    active = json.loads(open(store.path("active"), "rb").read())
    store_id = active["store_id"]
    key_dir_name = sorted(os.listdir(os.path.join(store.store_dir(store_id), "keys")))[0]
    key_dir = os.path.join(store.store_dir(store_id), "keys", key_dir_name)
    scratch = tools.new_scratch_repo()
    tip = remote_ref(remote).decode().strip()
    before, ref_before = store.snapshot_digest(), remote_ref(remote)

    def unchanged(label):
        emit(f"{label}: no store or anchor mutation",
             store.snapshot_digest() == before and remote_ref(remote) == ref_before)

    # --- dormant rows and approval.consume, each named explicitly (0a.2 section 1)
    errors = set()
    for row in DORMANT_ROWS:
        ok, code = refused(lambda row=row: store.begin(row, PRINCIPAL), f"dormant-row:{row}")
        errors.add(code)
        emit(f"dormant: {row} is refused at store.begin with its distinct error", ok, code)
        ok, code = refused(lambda row=row: registry.admit(row), f"dormant-row:{row}")
        emit(f"dormant: {row} is refused at admission with its distinct error", ok, code)
        ok, code = refused(lambda row=row: registry.validate(row, {}, {}), f"dormant-row:{row}")
        ok2, _ = refused(lambda row=row: registry.transition(row, {}, {}), f"dormant-row:{row}")
        emit(f"dormant: {row}'s validator and transition are refused", ok and ok2, code)
    emit("dormant: every dormant row's error is distinct", len(errors) == len(DORMANT_ROWS))
    for branch in ("gesture", "source-invalidated"):
        ok, code = refused(lambda branch=branch: registry.admit("request-cancellation", branch=branch),
                           "dormant-row:request-cancellation")
        emit(f"dormant: request cancellation's {branch} branch is refused with the row's error", ok, code)
    for kind, source in SOURCE_STATE.items():
        codes = set()
        for state in ("node state", "mechanism state", "accumulator state", "candidate-release state"):
            codes.add(refused(lambda kind=kind, state=state: registry.admit(
                "request-opening", request_kind=kind, source_state=state), "dormant-row:request-opening")[1])
        emit(f"dormant: request opening of kind {kind} is refused from every source state (kind x source "
             "state cross-product, negative while dormant)", codes == {"dormant-row:request-opening"}, codes)
    # A2.1 / 0a.3: the full request-kind x source-state cross-product (tg:862-869), one check per combination,
    # each refused as a dormant row -- naming the kind and the source it was offered -- by every request row;
    # the positive half arrives with each kind's activating unit.
    request_rows = (("request-opening", None), ("capability-issuance", None), ("request-cancellation", "gesture"),
                    ("request-cancellation", "source-invalidated"), ("request-expiry", None),
                    ("capability-redemption", None))
    for kind, own in SOURCE_STATE.items():
        for state in ("node state", "mechanism state", "accumulator state", "candidate-release state"):
            outcomes = []
            for row, branch in request_rows:
                try:
                    registry.admit(row, branch=branch, request_kind=kind, source_state=state)
                    outcomes.append((row, branch, "admitted"))
                except registry.RowRefused as error:
                    named = f"(kind {kind})" in error.message and f"(source {state})" in error.message
                    outcomes.append((row, branch, error.code if error.dormant and named else f"other:{error.code}"))
            emit(f"cross-product: {kind} x {state}{' (its own source state)' if state == own else ''} is refused as a "
                 "dormant row by request opening, capability issuance, both cancellation branches, expiry, and "
                 "redemption", all(code == f"dormant-row:{row}" for row, _branch, code in outcomes),
                 [item for item in outcomes if item[2] != f"dormant-row:{item[0]}"])
    unchanged("the request-kind x source-state cross-product")
    ok, code = refused(lambda: store.begin("approval.consume", PRINCIPAL), "approval-consume-refused")
    emit("dormant: approval.consume is refused with its own error", ok, code)
    ok, code = refused(lambda: registry.admit("approval.consume"), "approval-consume-refused")
    emit("dormant: approval.consume is refused at admission", ok, code)
    unchanged("dormant rows")

    # --- no token, a spent token, another row's token
    def spent(row):
        entry = registry.ROW_BY_ID[row]["entry"]
        if entry == "recovery":
            # a recovery token of this row, spent (minting one needs the row's own state)
            token = store.Token(row, "recovery", D({"row": row}))
        elif entry == "compound":
            parent = store.begin("epoch-revocation", PRINCIPAL)
            token = store.child(parent, row)
            store.spend(parent)
            return token
        else:
            token = store.begin(row, PRINCIPAL)
        store.spend(token)
        return token

    def other(row_sinks):
        # an open token of a row that may not use the sink: the head-advance
        # child (its only sink is the anchor push), else a rotation
        if "anchor-push" not in row_sinks:
            return store.child(store.begin("epoch-rotation", PRINCIPAL), "authority-head-advance")
        return store.begin("epoch-rotation", PRINCIPAL)

    calls = {
        "create_store_dir": ("authority-genesis", ("store-dir-create",),
                             lambda t: store.create_store_dir(t, store_id="a" * 32, key_dir="epoch-1-" + "a" * 16)),
        "create_key_dir": ("epoch-rotation", ("key-dir-create",),
                           lambda t: store.create_key_dir(t, store_id=store_id, key_dir="epoch-2-" + "a" * 16)),
        "create_key": ("epoch-rotation", ("key-create",),
                       lambda t: store.create_key(t, store_id=store_id, key_dir=key_dir_name, name="root")),
        "certify_key": ("epoch-rotation", ("key-create",),
                        lambda t: store.certify_key(t, store_id=store_id, key_dir=key_dir_name, name="store.genesis")),
        "seal": ("epoch-revocation", ("seal",),
                 lambda t: store.seal(t, record_type="epoch.revoked", payload=b"x", key_dir=key_dir)),
        "seal_pointer": ("epoch-revocation", ("pointer-seal",),
                         lambda t: store.seal_pointer(t, pointer=b"x", key_dir=key_dir)),
        "write_intent": ("epoch-revocation", ("intent-write",),
                         lambda t: store.write_intent(t, store_id=store_id, data=b"{}")),
        "write_genesis_intent": ("authority-genesis", ("genesis-intent-write",),
                                 lambda t: store.write_genesis_intent(t, data=b"{}")),
        "write_regenesis_intent": ("linked-regenesis", ("regenesis-intent-write",),
                                   lambda t: store.write_regenesis_intent(t, data=b"{}")),
        "append_frame": ("epoch-revocation", ("frame-append",),
                         lambda t: store.append_frame(t, store_id=store_id, data=b"x")),
        "complete_delimiter": ("anchor-replay-forward", ("delimiter-completion",),
                               lambda t: store.complete_delimiter(t, store_id=store_id, frame_bytes=b"x\n")),
        "truncate_frame": ("torn-frame-truncation", ("truncation",),
                           lambda t: store.truncate_frame(t, store_id=store_id, offset=0)),
        "remove_intent": ("recovery-tidy", ("intent-remove",), lambda t: store.remove_intent(t, store_id=store_id)),
        "remove_genesis_intent": ("authority-genesis", ("genesis-intent-remove",),
                                  lambda t: store.remove_genesis_intent(t)),
        "remove_regenesis_intent": ("linked-regenesis", ("regenesis-intent-remove",),
                                    lambda t: store.remove_regenesis_intent(t)),
        "write_cursor": ("recovery-tidy", ("cursor-write",),
                         lambda t: store.write_cursor(t, store_id=store_id, data=b'{"store_id":"x"}')),
        "write_quarantine": ("store-quarantine", ("quarantine-marker",),
                             lambda t: store.write_quarantine(t, store_id=store_id, data=b'{"rule":"x"}')),
        "write_active": ("authority-genesis", ("active-marker",),
                         lambda t: store.write_active(t, target={"store_id": store_id, "generation": 1})),
        "archive_store": ("linked-regenesis", ("archive-move",), lambda t: store.archive_store(t, store_id=store_id)),
        "push_anchor": ("authority-head-advance", ("anchor-push",),
                        lambda t: store.push_anchor(t, scratch=scratch, commit=tip, ref=ANCHOR_REF)),
    }
    emit("tokens: the checks below cover every frozen sink function", set(calls) == set(SINK_FUNCTIONS))
    for name, (row, sinks, call) in calls.items():
        ok, code = refused(lambda call=call: call(None), "token")
        emit(f"tokens: {name} with no token is refused", ok, code)
        ok, code = refused(lambda call=call, row=row: call(spent(row)), "token")
        emit(f"tokens: {name} with a spent {row} token is refused", ok, code)
        token = other(sinks)
        ok, code = refused(lambda call=call, token=token: call(token), "token-row")
        emit(f"tokens: {name} with another row's ({token.row}) token is refused", ok, code)
        store.spend(token.parent if token.parent is not None else token)
    unchanged("no, spent, and other-row tokens (local files and the remote push)")

    # --- recovery-derived rows (real crash states: main_recovery below)
    for row, call, ceremony_row in (("torn-frame-truncation", calls["truncate_frame"][2], "epoch-revocation"),
                                    ("store-quarantine", calls["write_quarantine"][2], "epoch-revocation"),
                                    ("recovery-tidy", calls["remove_intent"][2], "authority-genesis")):
        ceremony_token = store.begin(ceremony_row, PRINCIPAL)
        ok, code = refused(lambda call=call: call(ceremony_token), "token-row")
        emit(f"recovery rows: {row} without a recovery token (a {ceremony_row} token) is refused", ok, code)
        store.spend(ceremony_token)
    # plan-only minting: a caller-built binding, in any shape, mints nothing
    marker = store.quarantine_bytes(store_id, "forged", {"seq": 1}, "forged")
    forged = {"row": "store-quarantine", "table": "forged", "local": store.snapshot_digest(),
              "remote": {"read": False, "tip": None}, "store_id": store_id, "rule": "forged",
              "position": {"seq": 1}, "marker_digest": store.sha256(marker)}
    for label, value in (("a caller-built binding", forged),
                         ("a caller-built binding naming the row", ("store-quarantine", forged)),
                         ("nothing", None)):
        ok, code = refused(lambda value=value: store.begin_recovery(value), "recovery-plan")
        emit(f"recovery rows: begin_recovery given {label} (not an issued plan) mints nothing", ok, code)
        ok, code = refused(lambda value=value: store.begin_finish(value), "recovery-plan")
        emit(f"recovery rows: begin_finish given {label} (not an issued plan) mints nothing", ok, code)
    ok, code = refused(lambda: store.begin_recovery("store-quarantine", forged), "TypeError")
    emit("recovery rows: the old (row, binding) call shape no longer exists", ok, code)
    ok, code = refused(lambda: store.begin("recovery-tidy", PRINCIPAL), "exclusion-X7")
    emit("recovery rows: a recovery row cannot be begun as an external row (X7)", ok, code)
    ok, code = refused(lambda: store.begin("authority-head-advance", PRINCIPAL), "exclusion-X7")
    emit("compound rows: authority-head advance cannot be begun on its own (X7)", ok, code)
    genesis_token = store.begin("authority-genesis", PRINCIPAL)
    ok, code = refused(lambda: store.child(genesis_token, "store-quarantine"), "compound")
    emit("compound rows: a parent whose transition does not name the child cannot open it", ok, code)
    store.spend(genesis_token)
    revocation_token = store.begin("epoch-revocation", PRINCIPAL)
    ok, code = refused(lambda: store.child(revocation_token, "store-quarantine"), "compound")
    emit("compound rows: a revocation that bound no observed active epoch cannot open its quarantine child",
         ok, code)
    store.spend(revocation_token)
    emit("compound rows: nothing was written by the refused children",
         not os.path.exists(os.path.join(store.store_dir(store_id), "quarantine")))
    ok, code = refused(lambda: store.begin("epoch-rotation", {"kind": "console-session"}), "exclusion-X6")
    emit("exclusions: an operator row refuses a principal that is not an operator-TTY session (X6)", ok, code)
    unchanged("recovery and compound rows")

    # --- stages, with an otherwise valid same-row token
    token = store.begin("epoch-revocation", PRINCIPAL)
    ok, code = refused(lambda: store.seal(token, record_type="epoch.revoked", payload=b"x", key_dir=key_dir),
                       "stage-unbound")
    emit("stages: store.seal before stage 1 is bound is refused", ok, code)
    cert = keys.parse_cert_file(open(os.path.join(key_dir, "epoch.revoked-cert.pub"), "rb").read())
    key_id = keys.fingerprint(cert.subject_blob)

    def revocation_payload(**body):
        return records.payload_bytes({"type": "epoch.revoked", "store_id": store_id, "generation": 1, "seq": 2,
                                      "epoch": 1, "body": dict({"epoch": 1, "prior_state": "active"}, **body)})

    payload = revocation_payload()
    ok, code = refused(lambda: store.bind_record(token, store_id=store_id, record_type="epoch.revoked",
                                                 payload_digest=store.sha256(payload), key_id=key_id,
                                                 signing_key_dir=key_dir, pointer_key_dir=key_dir), "stage-order")
    emit("stages: a revocation record bound before the revoked epoch's observed state is refused", ok, code)
    for label, kwargs in (("a prior state the store's log does not show", {"epoch": 1, "prior_state": "verify-only"}),
                          ("an epoch the store never had", {"epoch": 5, "prior_state": "active"})):
        probe = store.begin("epoch-revocation", PRINCIPAL)
        ok, code = refused(lambda probe=probe, kwargs=kwargs: store.bind_revocation(
            probe, store_id=store_id, generation=1, **kwargs), "revoke-refused")
        emit(f"stages: a revocation binding claiming {label} is refused (observed from the log)", ok, code)
        store.spend(probe)
    store.bind_revocation(token, store_id=store_id, generation=1, epoch=1, prior_state="active")
    emit("stages: the revocation binds the observed prior state, the active epoch, and the record's seq",
         {k: token.stages["revocation"][k] for k in ("prior_state", "active_epoch", "seq")}
         == {"prior_state": "active", "active_epoch": 1, "seq": 2}, token.stages.get("revocation"))
    twice = store.begin("epoch-revocation", PRINCIPAL)
    store.bind_revocation(twice, store_id=store_id, generation=1, epoch=1, prior_state="active")
    ok, code = refused(lambda: store.bind_revocation(twice, store_id=store_id, generation=1, epoch=1,
                                                     prior_state="active"), "rebind")
    emit("stages: the revocation is bound once; a second attempt spends the token", ok and not store.token_is_open(twice),
         code)
    other_payload = revocation_payload(prior_state="verify-only")
    wrong = store.begin("epoch-revocation", PRINCIPAL)
    store.bind_revocation(wrong, store_id=store_id, generation=1, epoch=1, prior_state="active")
    store.bind_record(wrong, store_id=store_id, record_type="epoch.revoked", payload_digest=store.sha256(other_payload),
                      key_id=key_id, signing_key_dir=key_dir, pointer_key_dir=key_dir)
    ok, code = refused(lambda: store.seal(wrong, record_type="epoch.revoked", payload=other_payload, key_dir=key_dir),
                       "stage-mismatch")
    emit("stages: sealing a revocation payload that is not the bound, observed revocation is refused", ok, code)
    store.spend(wrong)
    poisoned = store.begin("epoch-revocation", PRINCIPAL)
    store.bind_revocation(poisoned, store_id=store_id, generation=1, epoch=1, prior_state="active")
    store.bind_record(poisoned, store_id=store_id, record_type="epoch.revoked",
                      payload_digest=store.sha256(payload), key_id=key_id, signing_key_dir=key_dir,
                      pointer_key_dir=key_dir)
    ok, code = refused(lambda: store.bind_record(poisoned, store_id=store_id, record_type="epoch.revoked",
                                                 payload_digest=store.sha256(b"other"), key_id=key_id,
                                                 signing_key_dir=key_dir, pointer_key_dir=key_dir), "rebind")
    emit("stages: an attempt to re-bind a bound stage is refused", ok, code)
    ok, code = refused(lambda: store.seal(poisoned, record_type="epoch.revoked", payload=payload, key_dir=key_dir),
                       "token")
    emit("stages: after an attempt to re-bind, even the exactly bound seal refuses", ok, code)
    store.bind_record(token, store_id=store_id, record_type="epoch.revoked", payload_digest=store.sha256(payload),
                      key_id=key_id, signing_key_dir=key_dir, pointer_key_dir=key_dir)
    for label, kwargs in (("another type", {"record_type": "epoch.rotated", "payload": payload, "key_dir": key_dir}),
                          ("another payload", {"record_type": "epoch.revoked", "payload": b"other", "key_dir": key_dir}),
                          ("another subkey", {"record_type": "epoch.revoked", "payload": payload,
                                              "key_dir": key_dir + "x"})):
        ok, code = refused(lambda kwargs=kwargs: store.seal(token, **kwargs), "stage-mismatch")
        emit(f"stages: store.seal given {label} is refused", ok, code)
    for name in ("segment_reset", "mechanism_closed", "release_accepted"):
        ok, code = refused(lambda name=name: store.seal(token, record_type=name, payload=payload, key_dir=key_dir),
                           "nested-only")
        emit(f"stages: sealing a record named {name} is refused (no standalone type)", ok, code)
    ok, code = refused(lambda: tools.run("ssh-keygen.sign", token=token, stdin=payload,
                                         subkey=os.path.join(key_dir, "epoch.revoked-cert.pub"),
                                         type="epoch.revoked"), "permit")
    emit("stages: the low-level seal (tools.run ssh-keygen.sign) with the valid token but no sink permit is refused",
         ok, code)
    ok, code = refused(lambda: tools.run("ssh-keygen.sign", stdin=payload,
                                         subkey=os.path.join(key_dir, "epoch.revoked-cert.pub"),
                                         type="epoch.revoked"), "permit")
    emit("tools: ssh-keygen.sign (signature on stdout) with no token is refused", ok, code)
    sig = store.seal(token, record_type="epoch.revoked", payload=payload, key_dir=key_dir)
    emit("stages: store.seal with exactly the bound type, payload, and subkey signs", sig.startswith("-----BEGIN"))
    pointer = b'{"a":"pointer"}'
    ok, code = refused(lambda: store.seal_pointer(token, pointer=pointer, key_dir=key_dir), "stage-unbound")
    emit("stages: store.seal_pointer before stage 2 is bound is refused", ok, code)
    frame_bytes = b"OLF1 frame bytes\n"
    store.bind_frame(token, frame_digest=store.sha256(frame_bytes), record_digest=D({"r": 1}),
                     pointer_digest=store.sha256(pointer))
    ok, code = refused(lambda: store.seal_pointer(token, pointer=b"other", key_dir=key_dir), "stage-mismatch")
    emit("stages: store.seal_pointer given other pointer bytes is refused", ok, code)
    ok, code = refused(lambda: store.write_intent(token, store_id=store_id, data=b"{}"), "stage-unbound")
    emit("stages: the intent write before stage 3 is bound is refused", ok, code)
    ok, code = refused(lambda: store.append_frame(token, store_id=store_id, data=frame_bytes), "stage-unbound")
    emit("stages: the frame append before stage 3 is bound is refused", ok, code)
    store.seal_pointer(token, pointer=pointer, key_dir=key_dir)
    intent_bytes = b'{"an":"intent"}'
    commit = tip
    store.bind_anchor(token, anchor_json_digest=D({"a": 1}), anchor_commit=commit, ref=ANCHOR_REF,
                      intent_digest=store.sha256(intent_bytes), expected_parent=tip, offset=0)
    intent_path = os.path.join(store.store_dir(store_id), "intent")
    ok, code = refused(lambda: store.write_intent(token, store_id=store_id, data=b"other"), "stage-mismatch")
    emit("stages: the intent write given other bytes is refused", ok, code)
    ok, code = refused(lambda: store._fs_create(token, intent_path, b"other"), "permit")
    emit("stages: the low-level intent write called directly with the valid token is refused", ok, code)
    ok, code = refused(lambda: store.append_frame(token, store_id=store_id, data=frame_bytes), "protocol-order")
    emit("stages: the frame append before the intent is durable is refused", ok, code)
    head = store.child(token, "authority-head-advance")
    ok, code = refused(lambda: store.push_anchor(head, scratch=scratch, commit=commit, ref=ANCHOR_REF),
                       "protocol-order")
    emit("stages: the anchor push before the frame is durable is refused", ok, code)
    token.flags.add("intent")
    ok, code = refused(lambda: store.append_frame(token, store_id=store_id, data=b"other"), "stage-mismatch")
    emit("stages: the frame append given other bytes is refused", ok, code)
    log = store.log_path(store.store_dir(store_id))
    ok, code = refused(lambda: store._fs_append(token, log, os.path.getsize(log), b"other"), "permit")
    emit("stages: the low-level frame append called directly with the valid token is refused", ok, code)
    token.flags.add("frame")
    ok, code = refused(lambda: store.push_anchor(head, scratch=scratch, commit="0" * 40, ref=ANCHOR_REF),
                       "stage-mismatch")
    emit("stages: store.push_anchor given another commit is refused", ok, code)
    ok, code = refused(lambda: store.push_anchor(head, scratch=scratch, commit=commit, ref="refs/heads/main"),
                       "stage-mismatch")
    emit("stages: store.push_anchor given another ref is refused", ok, code)
    ok, code = refused(lambda: tools.run("git.push-anchor", token=head, scratch=scratch, remote=url, commit=commit),
                       "permit")
    emit("stages: the low-level push (tools.run git.push-anchor) with the valid token but no permit is refused",
         ok, code)
    ok, code = refused(lambda: tools.run("git.push-anchor", scratch=scratch, remote=url, commit=commit), "permit")
    emit("tools: git.push-anchor with no token is refused", ok, code)
    ok, code = refused(lambda: store.bind_anchor(token, anchor_json_digest=D({"a": 2}), anchor_commit=commit,
                                                 ref=ANCHOR_REF, intent_digest=store.sha256(b"x"),
                                                 expected_parent=tip, offset=0), "rebind")
    emit("stages: stage 3 cannot be re-bound", ok, code)
    ok, code = refused(lambda: store.write_intent(token, store_id=store_id, data=intent_bytes), "token")
    emit("stages: after an attempt to re-bind stage 3, even the exactly bound intent write refuses", ok, code)
    store.spend(token)
    unchanged("stage refusals")

    # --- unlisted variants
    for label, command, params in (
        ("fetch without --no-write-fetch-head", "git.fetch", {"scratch": scratch}),
        ("push --force", "git.push-anchor", {"scratch": scratch, "remote": url, "commit": tip, "force": True}),
        ("fetch with another refspec", "git.fetch-anchor", {"scratch": scratch, "remote": url, "refspec": "+x:y"}),
        ("a push to another remote", "git.push-anchor", {"scratch": scratch, "remote": "file:///elsewhere.git",
                                                         "commit": tip}),
        ("a git command outside a scratch repository", "git.cat-file", {"scratch": store.root(), "cat_mode": "-p",
                                                                         "oid": tip}),
        ("ssh-keygen.sign for a nested-only part", "ssh-keygen.sign",
         {"subkey": os.path.join(key_dir, "epoch.revoked-cert.pub"), "type": "segment_reset"}),
    ):
        ok, code = refused(lambda command=command, params=params: tools.build_argv(command, params),
                           "unlisted", "params")
        emit(f"tools: {label} cannot be built", ok, code)
    argv = tools.build_argv("git.push-anchor", {"scratch": scratch, "remote": url, "commit": tip})
    emit("tools: the only push that can be built carries the transport options and no --force",
         "protocol.allow=never" in argv and "--force" not in argv and not any(a.startswith("+") for a in argv)
         and argv[-1] == "refs/olddonkey-loop/*:refs/olddonkey-loop/*", argv)
    ok, code = refused(lambda: tools.run("ssh-keygen.fingerprint", pub=os.path.join(key_dir, "root.pub")), "refused")
    emit("tools: a parameter under the authority directory is refused without a token", ok, code)
    unchanged("tools refusals")

    # --- atomic replacement (active, cursor) never publishes a short write
    probe = os.path.join(os.environ["HOME"], "replace-probe")
    with open(probe, "wb") as handle:
        handle.write(b"old contents")
    token = store.begin("epoch-rotation", PRINCIPAL)
    data = bytes(range(256)) * 20
    real_write = os.write
    try:
        os.write = lambda fd, view: real_write(fd, bytes(view[:7]))  # every write short but successful
        store._grant(token, "replace", probe, store.sha256(data))
        store._fs_replace(token, probe, data)
    finally:
        os.write = real_write
    emit("atomic replace: short successful writes are completed before the replacement",
         open(probe, "rb").read() == data)
    try:
        os.write = lambda fd, view: 0  # a write that makes no progress
        store._grant(token, "replace", probe, store.sha256(b"new contents"))
        ok, code = refused(lambda: store._fs_replace(token, probe, b"new contents"), "short-write")
    finally:
        os.write = real_write
    leftovers = [name for name in os.listdir(os.path.dirname(probe)) if name.startswith(".tmp-")]
    emit("atomic replace: a write that cannot finish fails before the replacement (target unchanged, no "
         "temporary left)", ok and open(probe, "rb").read() == data and not leftovers, (code, leftovers))
    store.spend(token)
    tools.cleanup()


def main_planted_run():
    """Run the planted tools.run("git.push-anchor") bypass against a real
    store: it is refused at tools.run and the bare remote's ref is unchanged."""
    copy = plant("run", "recover.py", PLANTS["a direct tools.run of git.push-anchor from a non-sink function"][1])
    m, remote, url = fresh_store("planted-run", lib=copy)
    tools, anchor, recover = m["tools"], m["anchor"], m["recover"]
    emit("planted bypass: the planted copy is the one imported",
         os.path.realpath(recover.__file__).startswith(os.path.realpath(copy)))
    scratch = tools.new_scratch_repo()
    tip = anchor.fetch(scratch, url)
    anchor_json = anchor.read_anchor_commit(scratch, tip)[0]
    pointer = json.loads(anchor_json)
    pointer["active"]["seq"] = 2
    child = json.dumps(pointer, sort_keys=True, separators=(",", ":")).encode()
    commit = anchor.build_objects(scratch, child, tip)
    before = remote_ref(remote)
    ok, code = refused(lambda: recover._bypass_push(scratch, url, commit), "permit")
    emit("planted bypass: the direct tools.run(\"git.push-anchor\") is refused at tools.run", ok, code)
    emit("planted bypass: the bare remote's ref is unchanged", remote_ref(remote) == before)
    tools.cleanup()


# ===========================================================================
# Recovery and finish tokens against real crash states (A1.5, A2.4)
# ===========================================================================

def child_ceremony():
    """rs.py child <lib> <tmp> <home> <url> <command> <point|-> [epoch]: run one
    ceremony core (the TTY challenge stubbed; the operator-TTY path is the
    authority suite's) or `recover` in this process, crashing at <point>."""
    home, url, command, point = ARGS[0], ARGS[1], ARGS[2], ARGS[3]
    os.environ["HOME"] = home
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    if point != "-":
        os.environ["LOOP_AUTHORITY_CRASH_AT"] = point
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, recover, store, tools  # noqa: E402
    ceremony.challenge = lambda envelope: None
    store.configure_crash(command)
    try:
        with store.WriterLock():
            if command == "genesis":
                ceremony.genesis(PRINCIPAL, url)
            elif command == "rotate":
                ceremony.rotate(PRINCIPAL)
            elif command == "revoke":
                ceremony.revoke(PRINCIPAL, int(ARGS[4]))
            elif command == "regenesis":
                ceremony.regenesis(PRINCIPAL)
            else:
                recover.recover()
    finally:
        tools.cleanup()


def run_child(home, url, command, point="-", *extra):
    result = subprocess.run([sys.executable, __file__, "child", LIB, TMP, home, url, command, point, *extra],
                            capture_output=True)
    return result.returncode, result.stderr.decode("utf-8", "replace")[-600:]


def crash_state(label, steps):
    """A scratch HOME and bare remote after steps [(command, point, extra...)];
    every step but the last must succeed, the last must crash (137)."""
    home = os.path.join(TMP, "rec", label, "home")
    os.makedirs(home)
    remote = os.path.join(TMP, "rec", label, "remote.git")
    git("init", "--bare", "-q", remote)
    url = "file://" + remote
    for index, (command, point, *extra) in enumerate(steps):
        code, err = run_child(home, url, command, point, *extra)
        want = 137 if point != "-" else 0
        if code != want:
            raise RuntimeError(f"{label}: {command} at {point} exited {code}, not {want}: {err}")
    return home, remote, url


def main_recovery():
    states = {
        "committed": [("genesis", "-")],
        "torn": [("genesis", "-"), ("rotate", "frame-byte-60")],
        "replay": [("genesis", "-"), ("rotate", "after-frame-fsync")],
        "tidy": [("genesis", "-"), ("rotate", "after-push")],
        "abandon": [("genesis", "genesis-step-2")],
        "complete": [("genesis", "genesis-step-5")],
        "regen-abandon": [("genesis", "-"), ("revoke", "-", "1"), ("regenesis", "regenesis-step-1")],
        "regen-complete": [("genesis", "-"), ("revoke", "-", "1"), ("regenesis", "regenesis-step-3")],
        "quarantinable": [("genesis", "-")],
        "rollback": [("genesis", "-"), ("rotate", "-")],
        "missing-none": [("genesis", "genesis-step-2")],
        "missing-valid": [("genesis", "genesis-step-3")],
        "missing-pushed": [("genesis", "genesis-step-4")],
        "regen-missing": [("genesis", "-"), ("revoke", "-", "1"), ("regenesis", "regenesis-step-1")],
    }
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        futures = {label: pool.submit(crash_state, label, steps) for label, steps in states.items()}
        made = {label: future.result() for label, future in futures.items()}
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import recover, registry, store, tools  # noqa: E402

    def use(label):
        home, remote, url = made[label]
        os.environ["HOME"] = home
        os.environ["LOOP_AUTHORITY_TEST"] = "1"
        tools._PINNED.clear()
        tools.pin_remote(tools.parse_remote(url, allow_test=True))
        return remote

    def plan_of():
        scratch = recover.Scratch()
        try:
            return recover.observe(scratch)
        finally:
            scratch.close()

    def snap(remote):
        return store.snapshot_digest(), remote_ref(remote)

    def forge(plan, *, row="keep", state=None, remote_read=None, remote_tip="keep", **params):
        """A plan observe() never decided, entered into the issuance registry
        as a forger with in-process access could: only the fresh observation
        at minting stands between it and a token."""
        fake = recover.Plan(state or plan.state, row=plan.row if row == "keep" else row, table=plan.table,
                            detail=plan.detail, view=plan.view, **dict(plan.params, **params))
        fake.remote_read = plan.remote_read if remote_read is None else remote_read
        fake.remote_tip = plan.remote_tip if remote_tip == "keep" else remote_tip
        fake.anchor_class, fake.lineage_remote = plan.anchor_class, plan.lineage_remote
        return recover._issue(fake)

    def tree(root):
        """Every entry below root: path, mode, and content digest."""
        entries = []
        for current, dirs, files in os.walk(root):
            dirs.sort()
            for name in sorted(dirs + files):
                full = os.path.join(current, name)
                info = os.lstat(full)
                data = open(full, "rb").read() if os.path.isfile(full) and info.st_mode & 0o400 else b""
                entries.append((os.path.relpath(full, root), oct(info.st_mode), hashlib.sha256(data).hexdigest()))
        return entries

    def verifier():
        env = {"HOME": os.environ["HOME"], "PATH": os.environ.get("PATH", "/usr/bin"), "LANG": "C", "LC_ALL": "C",
               "LOOP_AUTHORITY_TEST": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run(["bash", VERIFY], env=env, capture_output=True)
        try:
            return json.loads(result.stdout.decode().strip().splitlines()[-1])
        except (ValueError, IndexError):
            return {"rc": result.returncode, "err": result.stderr.decode("utf-8", "replace")[-300:]}

    def other_commit(remote):
        blob = git("--git-dir", remote, "hash-object", "-w", "--stdin", stdin=b"not an anchor").stdout.decode().strip()
        tree_oid = git("--git-dir", remote, "mktree", stdin=f"100644 blob {blob}\tx\n".encode()).stdout.decode().strip()
        return git("--git-dir", remote, "commit-tree", tree_oid, "-m", "decoy",
                   extra_env={"GIT_AUTHOR_NAME": "d", "GIT_AUTHOR_EMAIL": "d@d", "GIT_COMMITTER_NAME": "d",
                              "GIT_COMMITTER_EMAIL": "d@d"}).stdout.decode().strip()

    def set_ref(remote, oid):
        if oid is None:
            git("--git-dir", remote, "update-ref", "-d", ANCHOR_REF)
        else:
            git("--git-dir", remote, "update-ref", ANCHOR_REF, oid)

    # --- a committed store: no recovery or finish token for any row, from any
    # --- forged plan (plan-only minting, re-proved by a fresh observation)
    remote = use("committed")
    before = snap(remote)
    plan = plan_of()
    emit("recovery tokens: the committed fixture observes committed with no row",
         plan.state == "committed" and plan.row is None, plan.summary())
    sid = json.loads(open(store.path("active"), "rb").read())["store_id"]
    marker_path = os.path.join(store.store_dir(sid), "quarantine")
    for row, state in (("torn-frame-truncation", "needs-recovery"), ("anchor-replay-forward", "pending"),
                       ("recovery-tidy", "needs-recovery")):
        fake = forge(plan, row=row, state=state, store_id=sid)
        ok, code = refused(lambda fake=fake: store.begin_recovery(fake), "recovery-plan")
        emit(f"recovery tokens: on a committed store a forged {row} plan, even entered as issued, mints nothing "
             "(re-observed)", ok, code)
    for label, fake in (
            ("with the remote not read (the local-only escape)",
             forge(plan, row="store-quarantine", state="quarantined", store_id=sid, rule="forged",
                   position={"seq": 1}, remote_read=False, remote_tip=None)),
            ("on the remote tip it read",
             forge(plan, row="store-quarantine", state="quarantined", store_id=sid, rule="fork",
                   position={"seq": 1}))):
        ok, code = refused(lambda fake=fake: store.begin_recovery(fake), "recovery-plan")
        emit(f"quarantine tokens: on a committed store a forged quarantine plan {label}, even entered as issued, "
             "mints nothing (the offending position and rule are re-observed)", ok, code)
    forged_marker = store.quarantine_bytes(sid, "forged", {"seq": 1}, "forged")
    revocation = store.begin("epoch-revocation", PRINCIPAL)
    for label, call, codes in (
            ("no token", lambda: store.write_quarantine(None, store_id=sid, data=forged_marker), ("token",)),
            ("a ceremony (revocation) token",
             lambda: store.write_quarantine(revocation, store_id=sid, data=forged_marker), ("token-row",)),
            ("a quarantine child of a revocation that bound no active epoch",
             lambda: store.write_quarantine(store.child(revocation, "store-quarantine"), store_id=sid,
                                            data=forged_marker), ("compound",))):
        ok, code = refused(call, *codes)
        emit(f"quarantine tokens: on a committed store a forged marker with {label} is refused", ok, code)
    store.spend(revocation)
    for action in ("complete", "abandon"):
        fake = forge(plan, row=action, state="genesis-pending", store_id=sid, intent_digest=D({"i": 1}))
        ok, code = refused(lambda fake=fake: store.begin_finish(fake), "recovery-plan")
        emit(f"finish tokens: on a committed store a forged genesis {action} plan mints nothing", ok, code)
    plan.row = "torn-frame-truncation"
    ok, code = refused(lambda: recover._mint(plan), "recovery-plan")
    emit("recovery tokens: an issued plan altered to name another row mints nothing", ok, code)
    ok, code = refused(lambda: recover._mint(recover.Plan("needs-recovery", row="torn-frame-truncation",
                                                          store_id=sid, offset=0)), "recovery-plan")
    emit("recovery tokens: a plan observe() never issued mints nothing", ok, code)
    emit("recovery tokens: the refusals on the committed store wrote nothing (no marker, same state and remote)",
         snap(remote) == before and not os.path.exists(marker_path))
    tools.cleanup()

    # --- a torn tail: wrong row, wrong target, remote change
    remote = use("torn")
    plan = plan_of()
    emit("recovery tokens: the torn fixture observes torn-frame-truncation", plan.row == "torn-frame-truncation",
         plan.summary())
    before = snap(remote)
    log = store.log_path(store.store_dir(plan.params["store_id"]))
    base_log = open(log, "rb").read()
    intent = plan.params["intent"]
    for row, state in (("anchor-replay-forward", "pending"), ("recovery-tidy", "needs-recovery"),
                       ("store-quarantine", "quarantined")):
        fake = forge(plan, row=row, state=state, rule="forged", position=None)
        ok, code = refused(lambda fake=fake: store.begin_recovery(fake), "recovery-plan")
        emit(f"recovery tokens: on a torn tail a forged {row} plan mints nothing", ok, code)
    escape = dict(recover._binding(plan, store.snapshot_digest()), remote={"read": False, "tip": None})
    real_redeem = store._redeem
    store._redeem = lambda _plan, finish: dict(escape)  # a remote-less binding that got past redemption
    try:
        ok, code = refused(lambda: store.begin_recovery(plan), "recovery-plan")
    finally:
        store._redeem = real_redeem
    emit("recovery tokens: a binding that skips the remote is refused for a row whose predicate needs it (only a "
         "quarantine decided from local files may carry remote.read = false)", ok, code)
    token = recover._mint(plan)
    ok, code = refused(lambda: recover._mint(plan), "recovery-plan")
    emit("recovery tokens: a replayed plan is refused (a plan mints one token only)", ok, code)
    ok, code = refused(lambda: store.truncate_frame(token, store_id="0" * 32, offset=intent["offset"]),
                       "stage-mismatch")
    emit("recovery tokens: truncation given another store is refused", ok, code)
    ok, code = refused(lambda: store.truncate_frame(token, store_id=plan.params["store_id"], offset=0),
                       "stage-mismatch")
    emit("recovery tokens: truncation given another offset (to zero) is refused", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, other_commit(remote))
    ok, code = refused(lambda: store.truncate_frame(token, store_id=plan.params["store_id"],
                                                    offset=intent["offset"]), "remote-state")
    emit("recovery tokens: truncation after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("recovery tokens: the refused truncations left the log and the remote unchanged",
         open(log, "rb").read() == base_log and snap(remote) == before)
    store.truncate_frame(token, store_id=plan.params["store_id"], offset=intent["offset"])
    emit("recovery tokens: with the remote restored, the bound truncation succeeds (positive control)",
         open(log, "rb").read() == base_log[:intent["offset"]])
    store.spend(token)
    tools.cleanup()

    # --- a complete frame with the remote one behind: replay-forward
    remote = use("replay")
    plan = plan_of()
    emit("recovery tokens: the replay fixture observes anchor-replay-forward", plan.row == "anchor-replay-forward",
         plan.summary())
    before = snap(remote)
    fake = forge(plan, row="torn-frame-truncation", state="needs-recovery", offset=plan.params["intent"]["offset"])
    ok, code = refused(lambda: store.begin_recovery(fake), "recovery-plan")
    emit("recovery tokens: on a complete frame a forged truncation plan mints nothing", ok, code)
    token = recover._mint(plan)
    scratch = tools.new_scratch_repo()
    intent = plan.params["intent"]
    ok, code = refused(lambda: store.complete_delimiter(token, store_id=plan.params["store_id"],
                                                        frame_bytes=base64_frame(intent)), "recovery-plan",
                       "stage-mismatch")
    emit("recovery tokens: replay of a complete frame may not append a delimiter", ok, code)
    ok, code = refused(lambda: store.push_anchor(token, scratch=scratch, commit="1" * 40, ref=ANCHOR_REF),
                       "stage-mismatch")
    emit("recovery tokens: replay given another commit is refused", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, None)
    ok, code = refused(lambda: store.push_anchor(token, scratch=scratch, commit=intent["anchor_commit"],
                                                 ref=ANCHOR_REF), "non-fast-forward")
    emit("recovery tokens: replay after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("recovery tokens: the refused replays mutated nothing", snap(remote) == before)
    store.spend(token)
    tools.cleanup()

    # --- a residual intent after the push: tidy
    remote = use("tidy")
    plan = plan_of()
    emit("recovery tokens: the tidy fixture observes recovery-tidy with an intent",
         plan.row == "recovery-tidy" and plan.params.get("intent") is not None, plan.summary())
    before = snap(remote)
    token = recover._mint(plan)
    ok, code = refused(lambda: store.remove_intent(token, store_id="0" * 32), "stage-mismatch")
    emit("recovery tokens: tidy's intent removal given another store is refused", ok, code)
    ok, code = refused(lambda: store.write_cursor(token, store_id=plan.params["store_id"],
                                                  data=b'{"store_id":"' + plan.params["store_id"].encode() + b'"}'),
                       "stage-mismatch")
    emit("recovery tokens: tidy's cursor write given other bytes is refused", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, plan.params["intent"]["expected_parent"])
    ok, code = refused(lambda: store.remove_intent(token, store_id=plan.params["store_id"]), "remote-state")
    emit("recovery tokens: tidy's intent removal after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("recovery tokens: the refused tidy mutated nothing", snap(remote) == before)
    store.spend(token)
    tools.cleanup()

    # --- a quarantine decided from local files alone (a nonconforming tail)
    remote = use("quarantinable")
    sid = json.loads(open(store.path("active"), "rb").read())["store_id"]
    marker_path = os.path.join(store.store_dir(sid), "quarantine")
    with open(store.log_path(store.store_dir(sid)), "ab") as handle:
        handle.write(b"a nonconforming tail, not a frame")
    plan = plan_of()
    emit("quarantine tokens: a nonconforming tail is a quarantine decided from local files alone (remote not read)",
         plan.row == "store-quarantine" and plan.remote_read is False, plan.summary())
    before = snap(remote)
    token = recover._mint(plan)
    ok, code = refused(lambda: recover._mint(plan), "recovery-plan")
    emit("quarantine tokens: a replayed quarantine plan is refused", ok, code)
    ok, code = refused(lambda: store.begin_recovery(plan), "recovery-plan")
    emit("quarantine tokens: the spent plan handed to the store directly is refused too", ok, code)
    ok, code = refused(lambda: store.write_quarantine(token, store_id=sid, data=store.quarantine_bytes(
        sid, "forged", plan.params["position"], "forged")), "stage-mismatch")
    emit("quarantine tokens: a marker naming another rule is refused", ok, code)
    cursor = os.path.join(store.store_dir(sid), "cursor")
    saved = open(cursor, "rb").read()
    with open(cursor, "wb") as handle:
        handle.write(saved + b" ")
    ok, code = refused(lambda: store.write_quarantine(token, store_id=sid, data=recover._marker_bytes(plan)),
                       "recovery-state")
    emit("quarantine tokens: a token bound to a different observed state is refused", ok, code)
    with open(cursor, "wb") as handle:
        handle.write(saved)
    log_path = store.log_path(store.store_dir(sid))
    tainted = open(log_path, "rb").read()
    with open(log_path, "wb") as handle:
        handle.write(tainted[:tainted.rindex(b"a nonconforming tail")])
    token.trail.append(store.snapshot_digest())  # as if the observed-state check were fooled
    ok, code = refused(lambda: store.write_quarantine(token, store_id=sid, data=recover._marker_bytes(plan)),
                       "recovery-plan")
    emit("quarantine tokens: with the offending tail gone the marker is refused by the sink's own fresh "
         "observation, even past the observed-state check", ok, code)
    with open(log_path, "wb") as handle:
        handle.write(tainted)
    token.trail.pop()
    emit("quarantine tokens: the refused markers wrote nothing",
         snap(remote) == before and not os.path.exists(marker_path))
    store.write_quarantine(token, store_id=sid, data=recover._marker_bytes(plan))
    store.spend(token)
    after = plan_of()
    emit("quarantine tokens: with the exact re-observed marker the quarantine is written (positive control)",
         open(marker_path, "rb").read() == recover._marker_bytes(plan) and after.state == "quarantined"
         and after.row is None, after.summary())
    tools.cleanup()

    # --- a quarantine decided after reading the remote (R = ptr(L - 1), no intent)
    remote = use("rollback")
    sid = json.loads(open(store.path("active"), "rb").read())["store_id"]
    marker_path = os.path.join(store.store_dir(sid), "quarantine")
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, json_parent(remote, tip))
    plan = plan_of()
    emit("quarantine tokens: R = ptr(L - 1) without an intent is a quarantine decided after reading the remote",
         plan.row == "store-quarantine" and plan.remote_read is True and plan.params.get("rule") == "rollback-one",
         plan.summary())
    before = snap(remote)
    for label, fake in (("claiming the remote was not read (the escape)",
                         forge(plan, remote_read=False, remote_tip=None)),
                        ("naming another rule", forge(plan, rule="forged")),
                        ("naming another position", forge(plan, position={"seq": 1}))):
        ok, code = refused(lambda fake=fake: store.begin_recovery(fake), "recovery-plan")
        emit(f"quarantine tokens: a forged quarantine plan {label} mints nothing", ok, code)
    token = recover._mint(plan)
    set_ref(remote, tip)
    ok, code = refused(lambda: store.write_quarantine(token, store_id=sid, data=recover._marker_bytes(plan)),
                       "recovery-plan", "remote-state")
    emit("quarantine tokens: with the remote back on the tip the marker is refused (re-observed at the sink)",
         ok, code)
    set_ref(remote, json_parent(remote, tip))
    emit("quarantine tokens: the refused remote-read quarantine wrote nothing",
         snap(remote) == before and not os.path.exists(marker_path))
    store.write_quarantine(token, store_id=sid, data=recover._marker_bytes(plan))
    store.spend(token)
    emit("quarantine tokens: on the observed rollback the marker is written (positive control)",
         os.path.exists(marker_path) and json.loads(open(marker_path, "rb").read())["rule"] == "rollback-one")
    tools.cleanup()

    # --- genesis abandonment (A2.3 row 6): removes the intent, deletes nothing
    home, _remote, url = made["abandon"]
    remote = use("abandon")
    plan = plan_of()
    emit("finish tokens: the abandonment fixture observes A2.3 row 6", plan.table == "A2.3 row 6", plan.summary())
    before = snap(remote)
    intent_store = plan.params["store_id"]
    directory = store.store_dir(intent_store)
    kept = tree(directory)
    fake = forge(plan, row="complete", target={"store_id": intent_store, "generation": 1}, active_state="absent")
    ok, code = refused(lambda: store.begin_finish(fake), "recovery-plan")
    emit("finish tokens: a forged completion with the pre-ceremony (absent) ref mints nothing", ok, code)
    token = recover._mint(plan)
    sinks = set(registry.SINKS) | {sink for row in registry.ROWS for sink in row["sinks"]}
    emit("finish tokens: an abandonment token's only sinks are the intent removals (no discard sink exists)",
         store.FINISH_SINKS["abandon"] == ("genesis-intent-remove", "regenesis-intent-remove")
         and "store-discard" not in sinks and not hasattr(store, "discard_store_dir"))
    ok, code = refused(lambda: store.write_active(token, target={"store_id": intent_store, "generation": 1}),
                       "token-row")
    emit("finish tokens: an abandonment token is refused on the active sink", ok, code)
    set_ref(remote, other_commit(remote))
    ok, code = refused(lambda: store.remove_genesis_intent(token), "remote-state")
    emit("finish tokens: abandonment after the remote changed is refused", ok, code)
    set_ref(remote, None)
    emit("finish tokens: the refused abandonment sinks mutated nothing", snap(remote) == before)
    store.remove_genesis_intent(token)
    store.spend(token)
    after = plan_of()
    emit("abandonment: the intent is removed and nothing else -- the intent-named directory is byte-identical",
         not os.path.exists(store.path("genesis.intent")) and tree(directory) == kept)
    emit("abandonment: the state is none and the directory is reported unpublished, never read as authority",
         after.state == "none" and after.summary()["unpublished"]["stores"] == [intent_store], after.summary())
    code, err = run_child(home, url, "genesis")
    new_id = json.loads(open(store.path("active"), "rb").read())["store_id"] if code == 0 else None
    after = plan_of()
    emit("abandonment: a new genesis then succeeds with a fresh store id",
         code == 0 and new_id != intent_store and after.state == "committed", (code, err, after.summary()))
    emit("abandonment: after the new genesis the abandoned directory is still byte-identical and unpublished",
         tree(directory) == kept and after.summary()["unpublished"]["stores"] == [intent_store], after.summary())
    tools.cleanup()

    # --- a missing intent-named directory is A2.3 row 1, never frame 1 "none"
    for label, what in (("missing-none", "frame 1 none"), ("missing-valid", "after a valid frame 1, ref absent"),
                        ("missing-pushed", "after the push, the ref deleted too")):
        home, _remote, url = made[label]
        remote = use(label)
        intent = json.loads(open(store.path("genesis.intent"), "rb").read())
        if label == "missing-pushed":
            set_ref(remote, None)
        shutil.rmtree(store.store_dir(intent["store_id"]))
        before = snap(remote)
        plan = plan_of()
        emit(f"missing directory ({what}): the writer classifies genesis-invalid, A2.3 row 1, with no row",
             plan.state == "genesis-invalid" and plan.table == "A2.3 row 1" and plan.row is None, plan.summary())
        independent = verifier()
        emit(f"missing directory ({what}): the independent verifier agrees (genesis-invalid, A2.3 row 1)",
             independent.get("state") == "genesis-invalid" and independent.get("table") == "A2.3 row 1", independent)
        fake = forge(plan, row="abandon", state="genesis-pending", store_id=intent["store_id"],
                     intent_digest=store.sha256(open(store.path("genesis.intent"), "rb").read()))
        ok, code = refused(lambda fake=fake: store.begin_finish(fake), "recovery-plan")
        emit(f"missing directory ({what}): a forged abandonment plan mints nothing", ok, code)
        code, err = run_child(home, url, "recover")
        emit(f"missing directory ({what}): recovery mutates nothing -- the intent stays, the ref stays absent",
             code == 0 and snap(remote) == before and plan_of().state == "genesis-invalid", (code, err))
        tools.cleanup()

    # --- genesis completion (A2.3 row 9)
    remote = use("complete")
    plan = plan_of()
    emit("finish tokens: the completion fixture observes A2.3 row 9", plan.table == "A2.3 row 9", plan.summary())
    before = snap(remote)
    fake = forge(plan, row="abandon")
    ok, code = refused(lambda: store.begin_finish(fake), "recovery-plan")
    emit("finish tokens: a forged abandonment after the commit point mints nothing", ok, code)
    token = recover._mint(plan)
    target = token.stages["finish"]["targets"]["active_target"]
    emit("finish tokens: the active target is derived from the validated intent",
         target == {"store_id": plan.params["store_id"], "generation": 1})
    ok, code = refused(lambda: store.write_active(token, target={"store_id": "f" * 32, "generation": 1}),
                       "stage-mismatch")
    emit("finish tokens: the active sink given another target is refused", ok, code)
    ok, code = refused(lambda: store.remove_genesis_intent(token), "protocol-order")
    emit("finish tokens: the intent is not removed before the active marker", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, None)
    ok, code = refused(lambda: store.write_active(token, target=target), "remote-state")
    emit("finish tokens: completion after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("finish tokens: the refused completion sinks mutated nothing", snap(remote) == before)
    store.write_active(token, target=target)
    store.remove_genesis_intent(token)
    store.spend(token)
    emit("finish tokens: with exactly the derived target, completion succeeds (positive control)",
         plan_of().state == "committed")
    tools.cleanup()

    # --- linked re-genesis abandonment (removes the intent only) and completion
    remote = use("regen-abandon")
    plan = plan_of()
    emit("finish tokens: the re-genesis abandonment fixture observes the old generation",
         plan.row == "abandon" and plan.state == "regenesis-pending", plan.summary())
    before = snap(remote)
    new_id = plan.params["store_id"]
    kept = tree(store.store_dir(new_id))
    old_active = open(store.path("active"), "rb").read()
    old_id = json.loads(old_active)["store_id"]
    token = recover._mint(plan)
    ok, code = refused(lambda: store.archive_store(token, store_id=old_id), "token-row")
    emit("finish tokens: a re-genesis abandonment token is refused on the archive sink", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, other_commit(remote))
    ok, code = refused(lambda: store.remove_regenesis_intent(token), "remote-state")
    emit("finish tokens: re-genesis abandonment after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("finish tokens: the refused re-genesis abandonment mutated nothing", snap(remote) == before)
    store.remove_regenesis_intent(token)
    store.spend(token)
    after = plan_of()
    emit("re-genesis abandonment: the intent is removed and nothing else -- the new directory byte-identical and "
         "unpublished, the old store still active and quarantined",
         not os.path.exists(store.path("regenesis.intent")) and tree(store.store_dir(new_id)) == kept
         and open(store.path("active"), "rb").read() == old_active and after.state == "quarantined"
         and os.path.exists(os.path.join(store.store_dir(old_id), "quarantine"))
         and after.summary()["unpublished"]["stores"] == [new_id], after.summary())
    tools.cleanup()

    home, _remote, url = made["regen-missing"]
    remote = use("regen-missing")
    intent = json.loads(open(store.path("regenesis.intent"), "rb").read())
    shutil.rmtree(store.store_dir(intent["new_store_id"]))
    before = snap(remote)
    plan = plan_of()
    emit("missing directory (re-genesis): the writer classifies regenesis-invalid with no row",
         plan.state == "regenesis-invalid" and plan.row is None, plan.summary())
    independent = verifier()
    emit("missing directory (re-genesis): the independent verifier agrees (regenesis-invalid)",
         independent.get("state") == "regenesis-invalid", independent)
    code, err = run_child(home, url, "recover")
    emit("missing directory (re-genesis): recovery mutates nothing -- both stores and the intent stay",
         code == 0 and snap(remote) == before and plan_of().state == "regenesis-invalid", (code, err))
    tools.cleanup()

    remote = use("regen-complete")
    plan = plan_of()
    emit("finish tokens: the re-genesis completion fixture observes the new generation",
         plan.row == "complete" and plan.state == "regenesis-pending", plan.summary())
    before = snap(remote)
    token = recover._mint(plan)
    targets = token.stages["finish"]["targets"]
    ok, code = refused(lambda: store.archive_store(token, store_id="c" * 32), "stage-mismatch")
    emit("finish tokens: the archive sink given another store is refused", ok, code)
    ok, code = refused(lambda: store.write_active(token, target=targets["active_target"]), "protocol-order")
    emit("finish tokens: re-genesis marks the new store active only after the archive move", ok, code)
    tip = remote_ref(remote).decode().strip()
    set_ref(remote, json_parent(remote, tip))
    ok, code = refused(lambda: store.archive_store(token, store_id=targets["archive_store"]), "remote-state")
    emit("finish tokens: re-genesis completion after the remote changed is refused", ok, code)
    set_ref(remote, tip)
    emit("finish tokens: the refused re-genesis completion mutated nothing", snap(remote) == before)
    store.spend(token)
    tools.cleanup()


def main_revocation():
    """The revocation's quarantine child (A1.3): only for the revocation of
    the epoch the parent observed active, with exactly its one marker,
    re-proved against the durable revocation record -- never after a
    verify-only revocation, whatever its binding claims."""
    m, remote, url = fresh_store("revocation")
    store, ceremony, recover, tools = m["store"], m["ceremony"], m["recover"], m["tools"]
    with store.WriterLock():
        ceremony.rotate(PRINCIPAL)
    sid = json.loads(open(store.path("active"), "rb").read())["store_id"]
    marker_path = os.path.join(store.store_dir(sid), "quarantine")
    real_remove_intent, real_write_quarantine = store.remove_intent, store.write_quarantine
    seen = {}

    def status():
        scratch = recover.Scratch()
        try:
            return recover.observe(scratch)
        finally:
            scratch.close()

    def verify_only_hook(token, *, store_id):
        # the verify-only revocation's frame is durable and read back: try its
        # quarantine child before the ceremony removes the intent
        bound = dict(token.stages.get("revocation") or {})
        seen["bound"] = bound
        seen["child"] = refused(lambda: store.child(token, "store-quarantine"), "compound")
        seen["parent"] = refused(lambda: real_write_quarantine(
            token, store_id=store_id, data=store.active_revocation_marker(store_id, bound.get("seq", 0))), "token-row")
        # a binding altered to claim the active epoch: the child opens on it, and
        # the sink refuses against the durable record (prior_state verify-only)
        token.stages["revocation"].update(prior_state="active", active_epoch=bound["epoch"])
        try:
            child = store.child(token, "store-quarantine")
            seen["altered"] = refused(lambda: real_write_quarantine(
                child, store_id=store_id, data=store.active_revocation_marker(store_id, bound["seq"])), "compound")
        finally:
            token.stages["revocation"].update(prior_state=bound["prior_state"], active_epoch=bound["active_epoch"])
        return real_remove_intent(token, store_id=store_id)

    store.remove_intent = verify_only_hook
    try:
        with store.WriterLock():
            result = ceremony.revoke(PRINCIPAL, 1)
    finally:
        store.remove_intent = real_remove_intent
    bound = seen.get("bound", {})
    emit("revocation child: a verify-only revocation binds its prior state as observed in the log (verify-only, "
         "the active epoch 2, seq 3)", {k: bound.get(k) for k in ("epoch", "prior_state", "active_epoch", "seq")}
         == {"epoch": 1, "prior_state": "verify-only", "active_epoch": 2, "seq": 3}, bound)
    ok, code = seen.get("child", (False, "not run"))
    emit("revocation child: after a verify-only revocation's readback its quarantine child is refused", ok, code)
    ok, code = seen.get("parent", (False, "not run"))
    emit("revocation child: the revocation token itself cannot write a quarantine marker", ok, code)
    ok, code = seen.get("altered", (False, "not run"))
    emit("revocation child: with the binding altered to claim the active epoch, the marker is refused against the "
         "durable verify-only record", ok, code)
    plan = status()
    emit("revocation child: the verify-only revocation committed and wrote no marker",
         result.get("quarantined") is False and not os.path.exists(marker_path) and plan.state == "committed"
         and plan.view is not None and plan.view.epochs[1].state == "revoked", (result, plan.summary()))

    def active_hook(token, *, store_id, data):
        seq = token.parent.stages["revocation"]["seq"]
        seen["exact"] = data == store.active_revocation_marker(store_id, seq)
        seen["other-seq"] = refused(lambda: real_write_quarantine(
            token, store_id=store_id, data=store.active_revocation_marker(store_id, seq + 1)), "stage-mismatch")
        seen["other-rule"] = refused(lambda: real_write_quarantine(
            token, store_id=store_id, data=store.quarantine_bytes(store_id, "forged", {"seq": seq}, "forged")),
            "stage-mismatch")
        seen["marker-before"] = os.path.exists(marker_path)
        return real_write_quarantine(token, store_id=store_id, data=data)

    store.write_quarantine = active_hook
    try:
        with store.WriterLock():
            result = ceremony.revoke(PRINCIPAL, 2)
    finally:
        store.write_quarantine = real_write_quarantine
    for key, label in (("other-seq", "a marker for another sequence"), ("other-rule", "a marker naming another rule")):
        ok, code = seen.get(key, (False, "not run"))
        emit(f"revocation child: the active revocation's child refuses {label}", ok, code)
    emit("revocation child: the refused markers wrote nothing", seen.get("marker-before") is False)
    plan = status()
    emit("revocation child: revoking the active epoch writes exactly its one marker and quarantines the store",
         seen.get("exact") is True and result.get("quarantined") is True and plan.state == "quarantined"
         and open(marker_path, "rb").read() == store.active_revocation_marker(sid, 4), (result, plan.summary()))
    tools.cleanup()


def main_principal_reads():
    """Every ceremony fails closed when a principal field or the terminal
    cannot be read: an OSError from os.ttyname (macOS returns ERANGE under
    heavy pty allocation), from a start-token read, or from the challenge's
    terminal read or write is the TTY-class refusal (exit 11) naming the
    failed read, never a traceback, before any key, intent, frame, or push:
    the store, the remote, and the authority directory stay byte-identical.
    The terminal is simulated in this process only (isatty, the start-token
    reads, ttyname, and fd 0 / fd 1 I/O replaced here); the real ceremony.run
    and challenge run."""
    import errno
    import importlib

    m, remote, url = fresh_store("principal-reads")
    store, tools = m["store"], m["tools"]
    ceremony = importlib.reload(m["ceremony"])  # the real challenge (fresh_store stubs it)
    real = {"isatty": os.isatty, "ttyname": os.ttyname, "read": os.read, "write": os.write}
    fixture_home = os.environ["HOME"]
    begun = []
    real_begin = store.begin

    def tree(root):
        """Every entry below root (and root itself): path, mode, and bytes."""
        if not os.path.lexists(root):
            return None
        entries = []
        for current, dirs, files in os.walk(root):
            dirs.sort()
            for name in sorted(dirs + files):
                full = os.path.join(current, name)
                info = os.lstat(full)
                data = open(full, "rb").read() if os.path.isfile(full) and info.st_mode & 0o400 else b""
                entries.append((os.path.relpath(full, root), oct(info.st_mode), hashlib.sha256(data).hexdigest()))
        return oct(os.lstat(root).st_mode), entries

    def state(remote_path):
        return tree(store.root()), tree(remote_path), remote_ref(remote_path)

    def attempt(kind, options):
        """ceremony.run as the entry point sees it: (code, exit, message) of
        its refusal, or the class of anything else (a traceback there)."""
        try:
            ceremony.run(kind, options)
        except store.AuthorityError as error:
            return error.code, error.exit_code, error.message
        except Exception as error:  # noqa: BLE001
            return type(error).__name__, None, str(error)
        return "not refused", None, ""

    def failing(number):
        def fail(*_args):
            raise OSError(number, os.strerror(number))
        return fail

    def on_fd(fd, replacement, original):
        return lambda target, *args: replacement(target, *args) if target == fd else original(target, *args)

    os.isatty = lambda fd: fd in (0, 1) or real["isatty"](fd)
    ceremony.read_boot_id = lambda: "TESTBOOT-0000"
    ceremony.read_start_time = lambda pid: 1
    store.begin = lambda *args, **kw: begun.append(args[0]) or real_begin(*args, **kw)
    options = {"genesis": {"remote": url, "epoch": None}, "rotate": {"remote": None, "epoch": None},
               "revoke": {"remote": None, "epoch": 1}, "regenesis": {"remote": None, "epoch": None}}
    try:
        before = state(remote)
        emit("principal reads: the committed fixture has an authority directory and a remote anchor",
             before[0] is not None and before[2].strip() != b"", before[2])
        os.ttyname = failing(errno.ERANGE)
        for kind in ceremony.CEREMONY_ROWS:
            got = attempt(kind, options[kind])
            emit(f"principal reads: {kind} refuses with exit 11 naming the failed read when os.ttyname raises "
                 "OSError(ERANGE), not a traceback",
                 got[:2] == ("tty-name", 11) and "cannot read the terminal's name (ttyname(0))" in got[2]
                 and os.strerror(errno.ERANGE) in got[2], got)
            emit(f"principal reads: the refused {kind} began no ceremony token, and the store, the remote, and the "
                 "authority directory are byte-identical", not begun and state(remote) == before, begun)
        os.ttyname = lambda fd: "/dev/ttys000"
        for label, name in (("boot id", "read_boot_id"), ("start time", "read_start_time")):
            stub = getattr(ceremony, name)
            setattr(ceremony, name, failing(errno.EIO))
            try:
                got = attempt("rotate", options["rotate"])
            finally:
                setattr(ceremony, name, stub)
            emit(f"principal reads: an OSError from the {label} read refuses with exit 11 naming the failed read, not "
                 "a traceback", got[:2] == ("start-token", 11) and "cannot read the session start token" in got[2],
                 got)
            emit(f"principal reads: the {label} refusal began nothing and changed nothing",
                 not begun and state(remote) == before, begun)
        shown = []
        for label, code, read, write in (
                ("read of the echo", "tty-read", on_fd(0, failing(errno.EIO), real["read"]),
                 on_fd(1, lambda fd, data: shown.append(bytes(data)) or len(data), real["write"])),
                ("write of the challenge", "tty-write", real["read"], on_fd(1, failing(errno.EIO), real["write"]))):
            os.read, os.write = read, write
            try:
                got = attempt("rotate", options["rotate"])
            finally:
                os.read, os.write = real["read"], real["write"]
            emit(f"terminal I/O: an OSError on the challenge's {label} refuses with exit 11 naming it, not a traceback",
                 got[:2] == (code, 11) and os.strerror(errno.EIO) in got[2], got)
            emit(f"terminal I/O: the refused {label} began nothing and changed nothing",
                 not begun and state(remote) == before, begun)
        emit("terminal I/O: the read failure came after the challenge was shown",
             any(b"challenge: " in chunk for chunk in shown), shown[-2:])
        # genesis in a HOME with no authority directory yet: the principal
        # refusal comes before the writer lock creates the layout
        base = os.path.join(TMP, "principal-reads-empty")
        os.makedirs(os.path.join(base, "home"))
        empty = os.path.join(base, "remote.git")
        git("init", "--bare", "-q", empty)
        os.environ["HOME"] = os.path.join(base, "home")
        before_empty = state(empty)
        os.ttyname = failing(errno.ERANGE)
        got = attempt("genesis", {"remote": "file://" + empty, "epoch": None})
        emit("principal reads: genesis into an empty HOME refuses with exit 11 when os.ttyname raises OSError(ERANGE)",
             got[:2] == ("tty-name", 11), got)
        emit("principal reads: the refused genesis created no authority directory and left the remote unchanged",
             not begun and before_empty[0] is None and state(empty) == before_empty, (begun, state(empty)[0]))
    finally:
        os.isatty, os.ttyname, os.read, os.write = real["isatty"], real["ttyname"], real["read"], real["write"]
        store.begin = real_begin
        os.environ["HOME"] = fixture_home  # the scratch space cleanup() removes is the fixture's
    tools.cleanup()


def base64_frame(intent):
    import base64
    return base64.b64decode(intent["frame_b64"])


def json_parent(remote, oid):
    raw = git("--git-dir", remote, "cat-file", "-p", oid).stdout
    match = re.search(rb"^parent ([0-9a-f]{40})", raw, re.M)
    return match.group(1).decode() if match else None


def main_validators():
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import registry, records  # noqa: E402

    committed = {"store": "active", "generation": 1, "epochs": {"1": "verify-only", "2": "active"},
                 "active_epoch": 2, "quarantined": False, "pending": False, "log_seq": 2, "anchor_seq": 2,
                 "intent": None, "cursor": 2, "tail": None}
    types = sorted(records.TYPES)
    cases = {
        "authority-genesis": (
            ({"store": "absent", "intents": False},
             {"remote_ref": "absent", "store_id": "a" * 32, "remote": "file:///x.git", "root_pub": "k",
              "subkey_types": types, "types": types}),
            [({"store": "active", "intents": False}, None), ({"store": "absent", "intents": True}, None),
             (None, {"remote_ref": "present"}), (None, {"store_id": "short"}),
             (None, {"subkey_types": types[:-1]})]),
        "epoch-rotation": (
            (committed, {"current_epoch": 2, "epoch": 3, "key_dir_fresh": True, "subkey_types": types,
                         "types": types, "anchor_position": 2}),
            [(dict(committed, quarantined=True), None), (dict(committed, pending=True), None),
             (dict(committed, anchor_seq=1), None), (None, {"current_epoch": 1}), (None, {"epoch": 2}),
             (None, {"key_dir_fresh": False}), (None, {"subkey_types": types[:-1]}),
             (None, {"anchor_position": 1})]),
        "epoch-revocation": (
            (committed, {"epoch": 1, "prior_state": "verify-only", "current_epoch": 2, "anchor_position": 2}),
            [(dict(committed, epochs={"1": "revoked", "2": "active"}), {"epoch": 1, "prior_state": "revoked"}),
             (None, {"epoch": 9, "prior_state": "active"}), (None, {"epoch": 1, "prior_state": "active"}),
             (dict(committed, quarantined=True), None), (None, {"current_epoch": 1}),
             (None, {"anchor_position": 3})]),
        "authority-head-advance": (
            (committed, {"frame_durable": True, "parent": "p", "remote_tip": "p", "seq": 2}),
            [(None, {"frame_durable": False}), (None, {"remote_tip": "q"}), (None, {"seq": 3})]),
        "torn-frame-truncation": (
            (dict(committed, tail="torn", intent={"seq": 3, "offset": 100}), {"tail_offset": 100, "remote_seq": 2}),
            [(dict(committed, tail="unterminated", intent={"seq": 3, "offset": 100}), None),
             (dict(committed, tail="torn", intent={"seq": 4, "offset": 100}), None),
             (None, {"tail_offset": 99}), (None, {"remote_seq": 3})]),
        "anchor-replay-forward": (
            (dict(committed, intent={"seq": 2}), {"remote_seq": 1, "intent_matches": True, "frame_valid": True}),
            [(None, {"remote_seq": 2}), (None, {"intent_matches": False}), (None, {"frame_valid": False}),
             (dict(committed, intent={"seq": 3}), None)]),
        "recovery-tidy": (
            (dict(committed, intent={"seq": 2}), {"remote_seq": 2, "remote_matches": True, "intent_matches": True}),
            [(None, {"remote_seq": 1}), (None, {"intent_matches": False}), (dict(committed, intent=None), None),
             (dict(committed, intent={"seq": 3}), {"no_tail": False})]),
        "store-quarantine": (
            ({"quarantined": False}, {"rule": "fork", "position": {"seq": 2}}),
            [(None, {"rule": ""}), (None, {"rule": "x", "drop": "position"}), ({"quarantined": True}, None)]),
        "linked-regenesis": (
            ({"store": "active", "quarantined": True, "intents": False},
             {"remote_tip_valid": True, "lineage": "test", "test_mode": True}),
            [({"store": "active", "quarantined": False, "intents": False}, None),
             ({"store": "active", "quarantined": True, "intents": True}, None), (None, {"remote_tip_valid": False}),
             (None, {"test_mode": False})]),
    }
    emit("validators: every admissible row is driven below", set(cases) == set(ADMISSIBLE))
    for row, ((state, evidence), negatives) in cases.items():
        ok, code = refused(lambda: registry.validate(row, state, evidence))
        emit(f"validators: {row}'s validator admits its trigger", not ok and code == "not refused", code)
        for index, (bad_state, bad_evidence) in enumerate(negatives):
            use_state = state if bad_state is None else bad_state
            use_evidence = dict(evidence)
            if bad_evidence:
                use_evidence.update(bad_evidence)
                if bad_evidence.get("drop"):
                    use_evidence.pop(bad_evidence["drop"])
            ok, code = refused(lambda: registry.validate(row, use_state, use_evidence))
            emit(f"validators: {row}'s validator refuses negative case {index + 1}", ok, code)
        spec = registry.ROW_BY_ID[row]
        if not spec["exclusions"]:
            ok, code = refused(lambda: registry.check_exclusions(row, {"kind": "operator-tty"}))
            emit(f"exclusions: {row} lists none (tg:874-880 names no exclusion for it)",
                 not ok and spec["exclusions"] == (), code)
            continue
        if "X6" in spec["exclusions"]:
            good, bad = {"kind": "operator-tty"}, {"kind": "console-session"}
        else:
            good, bad = {"kind": "recovery"}, {"kind": "operator-tty"}
        ok, code = refused(lambda: registry.check_exclusions(row, good))
        ok2, code2 = refused(lambda: registry.check_exclusions(row, bad), "exclusion-X6", "exclusion-X7")
        emit(f"exclusions: {row} admits {good['kind']} and refuses {bad['kind']} ({spec['exclusions']})",
             not ok and ok2, (code, code2))
    t = registry.transition
    s = t("authority-genesis", {"store": "absent"}, {})
    emit("transitions: T-store-created makes epoch 1 active at generation 1, seq 1",
         s["store"] == "active" and s["epochs"] == {"1": "active"} and s["generation"] == 1 and s["log_seq"] == 1)
    s2 = t("epoch-rotation", s, {"epoch": 2})
    emit("transitions: T-epoch-rotated moves the old root to verify-only and the new one to active",
         s2["epochs"] == {"1": "verify-only", "2": "active"} and s2["active_epoch"] == 2 and s2["log_seq"] == 2)
    s3 = t("epoch-revocation", s2, {"epoch": 1})
    emit("transitions: revoking a verify-only epoch does not quarantine",
         s3["epochs"]["1"] == "revoked" and not s3.get("quarantined"))
    s4 = t("epoch-revocation", s3, {"epoch": 2})
    emit("transitions: revoking the active epoch is compound with T-quarantined",
         s4["epochs"]["2"] == "revoked" and s4["quarantined"] is True and s4["active_epoch"] is None)
    ok, code = refused(lambda: t("epoch-revocation", s4, {"epoch": 1}), "epoch-transition")
    emit("transitions: nothing leaves revoked", ok, code)
    ok, code = refused(lambda: registry.epoch_transition("verify-only", "active"), "epoch-transition")
    emit("transitions: verify-only never returns to active", ok, code)
    emit("transitions: T-head-advanced anchors the durable seq",
         t("authority-head-advance", dict(s2, anchor_seq=1), {})["anchor_seq"] == 2)
    emit("transitions: T-torn-truncated clears the torn tail", t("torn-frame-truncation", dict(s2, tail="torn"), {})["tail"] is None)
    r = t("anchor-replay-forward", dict(s2, tail="unterminated", anchor_seq=2, pending=True), {})
    emit("transitions: T-delimiter-completed + T-anchor-advanced completes and anchors the frame",
         r["log_seq"] == 3 and r["anchor_seq"] == 3 and r["pending"] is False and r["tail"] is None)
    emit("transitions: T-intent-cleared / T-cursor-reset", t("recovery-tidy", dict(s2, intent={"seq": 2}, cursor=1), {})
         == dict(s2, intent=None, cursor=2))
    emit("transitions: T-quarantined", t("store-quarantine", s2, {})["quarantined"] is True)
    g = t("linked-regenesis", dict(s4), {})
    emit("transitions: linked re-genesis advances the generation with a fresh epoch 1",
         g["generation"] == 2 and g["epochs"] == {"1": "active"} and g["quarantined"] is False)


def run(function):
    try:
        function()
    except Exception:  # noqa: BLE001
        emit(f"{function.__name__} completes", False, traceback.format_exc()[-1500:])


{"static": lambda: run(main_static), "tokens": lambda: run(main_tokens),
 "planted-run": lambda: run(main_planted_run), "validators": lambda: run(main_validators),
 "recovery": lambda: run(main_recovery), "revocation": lambda: run(main_revocation),
 "principal-reads": lambda: run(main_principal_reads), "child": child_ceremony}[MODE]()
PY

for mode in static validators tokens planted-run recovery revocation principal-reads; do
  python3 "$TMP_ROOT/rs.py" "$mode" "$LIB" "$TMP_ROOT" > "$TMP_ROOT/$mode.tsv" 2> "$TMP_ROOT/$mode.stderr"
  status=$?
  tally "$TMP_ROOT/$mode.tsv" "$TMP_ROOT/$mode.stderr" "$status" "registry $mode checks"
done

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
