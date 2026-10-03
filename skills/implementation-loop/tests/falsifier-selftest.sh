#!/usr/bin/env bash
# The named falsifier of task-graph-v1 Phase A (sub-unit 0a.4): unit 0a must
# show that every authority-store and anchor mutation is structurally
# reachable only through the admission registry, and that crash injection
# across a compound transition never yields one part without the other. This
# suite states each claim as its own executable check over the final 0a tree
# (0a.1 + 0a.2 + 0a.3) and fails if any claim fails:
#
# F1 every mutation sink is reachable only through an admitted row: the p2 s7
#    AST scan re-run (registry-selftest.sh's own static mode and scanner,
#    unmodified), plus an exact sink -> transaction-driver map over every
#    lib/loopauth module and scripts/loop-authority's Python
#    (loop-authority.py), token minting, and the entry's process and write
#    primitives; the independent verifier's argv forms (AST, its transport
#    plan for file://, SSH, and HTTPS remotes -- the complete fetch argv and
#    environment frozen for each -- and wrapper fixtures recording every git
#    and ssh-keygen it runs with its environment), its writes, and a run
#    against a read-only store and remote; the journal scripts' imports and a
#    run with the authority directory unreadable; and six planted bypasses
#    (p2 s7's four, one in loop-authority.py, one in refs.py), each making F1
#    fail. The entry's and the verifier's scans are alias-proof: every import
#    and attribute chain is resolved against the real modules (o.system,
#    os.path.os.system, and posix.system are all os.system), a primitive is
#    refused wherever referenced (an indirect call through a value too), and
#    import renames, modules used as values, dynamic attribute access, and
#    namespace lookups are refused outright; planted aliases (`import os as
#    o; o.system(...)` in loop-authority.py, `import subprocess as sp;
#    sp.run(...)` in the verifier, and their indirect forms) each fail F1.
#    The entry's loopauth accesses are frozen: every attribute of every
#    loopauth module it reads, followed through each alias (mods["store"], a
#    local name, a local function's parameter), equals a frozen table
#    naming no private helper, token constructor, sink, or validator, and
#    whatever the receiver it names no private attribute, no loopauth module,
#    and nothing else a loopauth module defines outside that table; planted
#    bypasses fail F1 -- the complete one (a forged open token through
#    s._new(s.Token(...)), s._grant, and s._fs_create) also shown live, run
#    through the planted entry. The verifier's runner is its frozen timeout
#    handler with one subprocess call, and an extra process start planted inside it fails F1.
# F2 every external entry point maps to exactly one row: a frozen table equal
#    to the real argument parser's enumeration; each ceremony run through the
#    real entry mints one ceremony token of its row; `recover` takes no
#    option and its ordered token trace -- recorded by an in-test fixture
#    wrapped around the real loop-authority.py -- equals a frozen expected
#    trace for every case of the crash matrix; the read-only entry points
#    leave the authority directory, the journal store, and the remote
#    byte-identical in every state.
# F3 derived-only rows have no external entry point; each compound child
#    (the revocation's quarantine, replay-forward's delimiter completion, the
#    head advance) refuses no token, its parent's own row token, another
#    parent's token, and a spent parent token.
# F4 no generic sealing or append hatch: seal, seal_pointer, and the frame
#    append only from the transaction driver, the record type fixed by the
#    row (a frozen map), validated first -- the row validator dominates
#    prepare_record: it runs unconditionally, its refusal propagating, on every
#    path to the record; three planted hatches, four planted dead or
#    swallowed validators (under `if False:`, in a try that swallows its
#    refusal, in a with that may suppress it, in a nested function never
#    called), and a stand-in bound to the name `registry` -- in lib/loopauth,
#    or from the entry through any alias (mods["registry"].validate = ...) --
#    make it fail;
#    every dormant row, approval.consume, and an unknown name are refused;
#    records of every type tg-v1.0a does not admit, sealed with the store's
#    own subkeys, are refused with type-not-admitted by the writer and the
#    verifier. It prints `escape-hatch: none` only when no F4 check needs an
#    exception (the frozen maps allow none).
# F5 no recovery invents authority: across the crash matrix every record and
#    pointer after recovery is byte-equal to one durable before it, no key
#    file changes, and recovery never signs (the tools.run recording fixture).
# F6 compound transitions never come apart: every cut of epoch revocation +
#    quarantine, delimiter completion + replay-forward (with the
#    recovery-after-delimiter crash point and a failed push there), genesis
#    completion, and re-genesis completion with its archive move is both
#    parts, neither, or pending (no current authorization, asserted through
#    status, the verifier, and refs' store state) -- "both" for the active
#    epoch's revocation is its record anchored (A1.2: the compound commits
#    then) with the writer, the verifier, and refs classifying the store
#    quarantined by its exact rule and position, and once recovery has run
#    to completion from the cut the quarantine marker exists with its exact
#    bytes and no residual intent. A marker with residual intent is an
#    explicit quarantined case, never "both"; "abandoned" for re-genesis requires the remote tip to be the
#    recorded old pointer, each with planted half-transitions it must refuse;
#    every byte of
#    the revocation, rotation, and genesis frames; the every-byte crash matrix
#    enumerates genesis, rotation, and active-epoch revocation frames (checked
#    structurally, from its enumerator); the request compounds are refused in
#    0a.
#
# Ceremonies run in-process with the TTY challenge stubbed (the operator-TTY
# path itself is authority-selftest.sh's, through a pty); HOME is a scratch
# directory per case; remotes are file:// bare repositories (a test lineage).
# Nothing here re-runs the every-byte crash matrix (authority-selftest.sh
# --crash-matrix, which needs a pty): the cuts are the named protocol crash
# points (every key step included), sampled frame bytes, and an offline
# sweep, by the writer's own classifiers, of every byte of each frame a
# compound is cut in; the matrix's enumerator is loaded from that suite and
# checked to cover all three frame kinds.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
SKILL="$(CDPATH= cd -P -- "$SCRIPT_DIR/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/falsifier-selftest.XXXXXX")" || exit 1
# A normalized, symlink-free path (macOS TMPDIR ends in '/' and /var is a
# symlink): the file:// remotes built from it must pass the writer's
# remote-path check.
TMP_ROOT="$(CDPATH= cd -P -- "$TMP_ROOT" && pwd -P)" || exit 1

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  chmod -R u+rwx -- "$TMP_ROOT" 2>/dev/null || true
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
CLAIM_NAMES=(""
  "every mutation sink is reachable only through an admitted row"
  "every external entry point maps to exactly one row"
  "derived-only rows have no external entry point"
  "no generic sealing or append hatch"
  "no recovery invents authority"
  "compound transitions never come apart")
CLAIM_CHECKS=(0 0 0 0 0 0 0)
CLAIM_FAILED=(0 0 0 0 0 0 0)
ESCAPE_HATCH="not reported"

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
}

count() { # $1=claim index $2=0 passed, 1 failed
  CLAIM_CHECKS[$1]=$((CLAIM_CHECKS[$1] + 1))
  if [[ "$2" -ne 0 ]]; then
    CLAIM_FAILED[$1]=$((CLAIM_FAILED[$1] + 1))
  fi
}

# The python driver prints "ok<TAB>F<n><TAB>description" or
# "not ok<TAB>F<n><TAB>description<TAB>detail" per check, naming its claim,
# and static prints "escape-hatch<TAB>none" or "escape-hatch<TAB>found<TAB>why".
tally() { # $1=results file $2=stderr file $3=python exit status $4=label $5=claim of a crashed program
  local verdict claim description detail index
  while IFS=$'\t' read -r verdict claim description detail; do
    if [[ "$verdict" == escape-hatch ]]; then
      ESCAPE_HATCH="$claim${description:+ ($description)}"
      continue
    fi
    [[ "$verdict" == ok || "$verdict" == "not ok" ]] || continue
    index=0
    if [[ "$claim" =~ ^F([1-6])$ ]]; then
      index="${BASH_REMATCH[1]}"
    fi
    if [[ "$index" -eq 0 ]]; then
      fail "a check names no claim ('$claim'): $description"
      continue
    fi
    if [[ "$verdict" == ok ]]; then
      pass "$claim: $description"
      count "$index" 0
    else
      fail "$claim: $description${detail:+ -- $detail}"
      count "$index" 1
    fi
  done < "$1"
  if [[ "$3" -ne 0 ]]; then
    fail "F$5: $4: the check program exited $3"
    count "$5" 1
    sed 's/^/  | /' "$2" >&2
  fi
}

cat > "$TMP_ROOT/fz.py" <<'PY'
"""falsifier-selftest driver (task-graph-v1 Phase A, sub-unit 0a.4).

fz.py <mode> <skill root> <tmp> [args]. Every check prints
  ok<TAB>F<n><TAB>description   or   not ok<TAB>F<n><TAB>description<TAB>detail
naming the claim (F1-F6) it belongs to.

  static    F1-F4 over the tree's source and planted copies
  entry     F2-F4, F6: the real entry points (parser, ceremonies, submit, recover)
  verifier  F1: the independent verifier's argv, a recorded run, a read-only run
  journal   F1: loop-journal and loop-index with the authority directory unreadable
  compound  F3, F6: compound-child tokens against real stores (in-process)
  types     F4: planted records of every type tg-v1.0a does not admit
  sweep     F6: every byte of the frames a compound is cut in
  matrix    F2, F5, F6: the crash matrix, recovered through the recorded entry
  child     (internal) one ceremony core, crashing at a point
  cli       (internal) the real loop-authority.py with the recording fixture
"""

from __future__ import annotations

import ast
import base64
import concurrent.futures
import hashlib
import importlib
import itertools
import json
import os
import re
import runpy
import shutil
import stat
import subprocess
import sys
import threading
import traceback
import types

MODE = sys.argv[1]
SKILL = os.path.realpath(sys.argv[2])
TMP = sys.argv[3]
ARGS = sys.argv[4:]
LIB = os.path.join(SKILL, "lib")
SCRIPTS = os.path.join(SKILL, "scripts")
TESTS = os.path.join(SKILL, "tests")
AUTH = os.path.join(SCRIPTS, "loop-authority")
AUTH_PY = os.path.join(SCRIPTS, "loop-authority.py")
VERIFY = os.path.join(SCRIPTS, "loop-authority-verify")
VERIFY_PY = os.path.join(SCRIPTS, "loop-authority-verify.py")
JOURNAL = os.path.join(SCRIPTS, "loop-journal")
INDEX = os.path.join(SCRIPTS, "loop-index")
REGISTRY_SUITE = os.path.join(TESTS, "registry-selftest.sh")
AUTHORITY_SUITE = os.path.join(TESTS, "authority-selftest.sh")
# The CI workflow that runs the sharded crash matrix (in a checkout only).
WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(SKILL)), ".github", "workflows", "selftest.yml")
FZ = os.path.realpath(__file__)
if MODE not in ("child", "cli"):
    os.makedirs(TMP, exist_ok=True)
TMP = os.path.realpath(TMP)  # normalized: the file:// remotes are built from it
BIN_DIRS = ("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin")
BASH = shutil.which("bash") or "/bin/bash"
ANCHOR_REF = "refs/olddonkey-loop/anchor"
PRINCIPAL = {"kind": "operator-tty", "tty": "/dev/ttys000",
             "start_token": {"boot_id": "TESTBOOT-0000", "pid": 1, "start_time": 1}}
WORKERS = max(2, min(8, os.cpu_count() or 2))

# ===========================================================================
# The frozen tables: the claims written down. None of them has an exception
# list; an addition to the tree that they do not name fails its check.
# ===========================================================================

# F2: every external entry point, and the one row it maps to (None: no row,
# read-only or refusing).
ENTRY_POINTS = {
    "loop-authority status": None,
    "loop-authority verify": None,
    "loop-authority refs": None,
    "loop-authority recover": "the recovery routine",
    "loop-authority ceremony genesis": "authority-genesis",
    "loop-authority ceremony rotate": "epoch-rotation",
    "loop-authority ceremony revoke": "epoch-revocation",
    "loop-authority ceremony regenesis": "linked-regenesis",
    # the typed-row entry: every row it could admit is dormant through 0a,
    # every ceremony row is refused X6, every derived row X7
    "loop-authority submit": None,
    "loop-authority-verify": None,
    "loop-authority-verify transport-plan": None,  # LOOP_AUTHORITY_TEST=1: prints argv
}
# The real parser's subcommands, and each one's arguments (help aside).
PARSER = {
    "status": (),
    "verify": (),
    "recover": (),
    "ceremony": (("kind", ("genesis", "rotate", "revoke", "regenesis")), ("--remote", None), ("--epoch", None)),
    "submit": (("row", None),),
    "refs": (("--workspace", None), ("--run", None)),
}
CEREMONY_ROWS = {"genesis": "authority-genesis", "rotate": "epoch-rotation", "revoke": "epoch-revocation",
                 "regenesis": "linked-regenesis"}
# The recovery routine is not a row: an observation-driven dispatcher whose
# branches are exactly these (A2.4's completion and abandonment included).
RECOVERY_BRANCHES = ("store-quarantine", "torn-frame-truncation", "recovery-tidy", "anchor-replay-forward",
                     "complete", "abandon")
RECOVERY_EXECUTORS = ("recover.execute", "recover._replay", "recover._finish_ceremony")
# F3: the derived rows 0a admits.
DERIVED_ROWS = ("authority-head-advance", "torn-frame-truncation", "anchor-replay-forward", "recovery-tidy",
                "store-quarantine")
# F4: the one record type each row seals (ALLOWED["tg-v1.0a"]).
ROW_TYPE = {"authority-genesis": "store.genesis", "epoch-rotation": "epoch.rotated",
            "epoch-revocation": "epoch.revoked", "linked-regenesis": "store.regenesis"}
CEREMONY_DRIVERS = ("ceremony.genesis", "ceremony.rotate", "ceremony.revoke", "ceremony.regenesis")
# F1: every token-checked sink, and the only functions that may call it --
# each the transaction driver of a registry row, or a helper taking that
# driver's token.
SINK_FUNCTIONS = (
    "create_store_dir", "create_key_dir", "create_key", "certify_key", "seal", "seal_pointer",
    "write_intent", "write_genesis_intent", "write_regenesis_intent", "append_frame", "complete_delimiter",
    "truncate_frame", "remove_intent", "remove_genesis_intent", "remove_regenesis_intent", "write_cursor",
    "write_quarantine", "write_active", "archive_store", "push_anchor",
)
SINK_DRIVERS = {
    "create_store_dir": {"ceremony.genesis", "ceremony.regenesis"},
    "create_key_dir": {"ceremony.rotate"},
    "create_key": {"ceremony._create_keys"},
    "certify_key": {"ceremony._create_keys"},
    "seal": {"store.prepare_record"},
    "seal_pointer": {"store.prepare_record"},
    "write_intent": {"ceremony.rotate", "ceremony.revoke"},
    "write_genesis_intent": {"ceremony.genesis"},
    "write_regenesis_intent": {"ceremony.regenesis"},
    "append_frame": {"ceremony.genesis", "ceremony.rotate", "ceremony.revoke", "ceremony.regenesis"},
    "complete_delimiter": {"recover._replay"},
    "truncate_frame": {"recover.execute"},
    "remove_intent": {"ceremony.rotate", "ceremony.revoke", "recover.execute"},
    "remove_genesis_intent": {"ceremony.genesis", "recover._finish_ceremony"},
    "remove_regenesis_intent": {"ceremony.regenesis", "recover._finish_ceremony"},
    "write_cursor": {"ceremony.genesis", "ceremony.rotate", "ceremony.revoke", "ceremony.regenesis",
                     "recover.execute"},
    "write_quarantine": {"ceremony.revoke", "recover.execute"},
    "write_active": {"ceremony.genesis", "ceremony.regenesis", "recover._finish_ceremony"},
    "archive_store": {"ceremony.regenesis", "recover._finish_ceremony"},
    "push_anchor": {"ceremony._finish_record", "ceremony.genesis", "recover._replay"},
}
# F1: every attribute of a loopauth module the writer entry (loop-authority.py)
# reads, by module ("loopauth": the package itself), through whatever alias:
# nothing else -- no token constructor or minter (Token, _new, begin, child),
# no permit or file helper (_grant, _fs_*), no sink, no validator.
ENTRY_MODULE_ACCESS = {
    "loopauth": {"__file__"},
    "canonical": {"canonical", "CanonicalError"},
    "tools": {"establish_scratch", "test_mode", "cleanup", "ToolError"},
    "store": {"EXIT_OK", "EXIT_REFUSED", "EXIT_DORMANT", "EXIT_CONSUME", "EXIT_PENDING", "EXIT_QUARANTINED",
              "EXIT_TERMINAL", "EXIT_INVALID", "configure_crash", "WriterLock", "ReaderLock", "AuthorityError",
              "anchor.Unreachable", "anchor.AnchorError"},
    "registry": {"admit", "RowRefused"},
    "recover": {"recover", "classify", "TERMINAL_STATES"},
    "ceremony": {"run"},
    "refs": {"prepare_report", "observe_report", "RefsError"},
}
# The modules load_loopauth() loads, in its order: its one dict of modules.
ENTRY_LOADED = ("canonical", "tools", "store", "registry", "recover", "ceremony", "refs")
# The names the entry reads under a receiver no loopauth module is that a
# loopauth module also defines: os.path and os.DirEntry.path (store.path),
# and the caught errors' .message.
ENTRY_SHARED_NAMES = {"path", "message"}
# The loopauth modules of the authority store (0a.2) and its read path (0a.3).
STORE_MODULES = {"store", "tools", "ceremony", "registry", "anchor", "keys", "records", "frame", "recover",
                 "refs"}
DORMANT_ROWS = ("request-opening", "capability-issuance", "request-cancellation", "request-expiry",
                "capability-redemption", "gesture-nonce-issuance", "repository-registration",
                "repository-rebind", "execution-root-registration", "standing-authorization",
                "standing-revocation", "segment-discharge", "enrollment", "enrollment-revocation",
                "mechanism-closure", "acceptance-platform-designation", "release-acceptance")
# A2.1's request compounds (activating units 8, 9, 12): refused in 0a.
REQUEST_COMPOUND_ROWS = ("request-opening", "capability-issuance", "capability-redemption",
                         "segment-discharge", "mechanism-closure", "release-acceptance")
NOT_ADMITTED = ("request.opened", "request.cancelled", "request.expired", "request.redeemed", "nonce.issued",
                "repo.registered", "repo.rebound", "exec-root.registered", "standing.granted",
                "standing.revoked", "entry.enrolled", "entry.revoked", "platform.designated")
SIGNING_COMMANDS = ("ssh-keygen.sign", "ssh-keygen.sign-pointer", "ssh-keygen.certify", "ssh-keygen.generate")
SINK_COMMANDS = SIGNING_COMMANDS + ("git.push-anchor",)
PENDING_STATES = ("pending", "needs-recovery", "genesis-pending", "regenesis-pending")

# The ordered token-trace vocabulary: one label per token the recovery
# routine mints (a delimiter completion is the replay-forward token's own
# compound part, bound when the frame was unterminated).
T_TR = "recovery: torn-frame truncation"
T_RP = "recovery: anchor replay-forward"
T_DRP = "recovery: delimiter completion + anchor replay-forward"
T_TD = "recovery: recovery tidy"
T_QT = "recovery: store quarantine"
T_GC = "ceremony(genesis): completion"
T_GA = "ceremony(genesis): abandonment"
T_RC = "ceremony(regenesis): completion"
T_RA = "ceremony(regenesis): abandonment"
STEP_OF = {T_TR: "torn-frame-truncation", T_RP: "anchor-replay-forward", T_DRP: "anchor-replay-forward",
           T_TD: "recovery-tidy", T_QT: "store-quarantine", T_GC: "complete", T_GA: "abandon", T_RC: "complete",
           T_RA: "abandon"}

# The crash matrix: each kind's fixture before its interrupted transaction,
# the transaction, and for every crash point p2 s6 lists for it (key steps
# and sampled frame bytes included) the frozen expected recovery trace and
# the outcome recovery must reach.
KEY_STEPS = 53
FRAME_SAMPLES = ("frame-byte-first", "frame-byte-mid", "frame-byte-penult", "frame-byte-last")
TORN_SAMPLES = FRAME_SAMPLES[:3]
BASE_STEPS = {
    "genesis": [],
    "rotation": [("genesis", "-")],
    "revocation": [("genesis", "-"), ("rotate", "-")],  # revoking verify-only epoch 1
    "revocation-active": [("genesis", "-")],            # revoking active epoch 1
    "regenesis": [("genesis", "-"), ("revoke", "-", "1")],
}
TRANSACTION = {"genesis": ("genesis",), "rotation": ("rotate",), "revocation": ("revoke", "1"),
               "revocation-active": ("revoke", "1"), "regenesis": ("regenesis",)}
# The two whole outcomes of each kind (the third safe one is pending).
WHOLE = {"genesis": ("none", "committed"), "rotation": ("neither", "both"), "revocation": ("neither", "both"),
         "revocation-active": ("neither", "both"), "regenesis": ("abandoned", "completed")}
EXPECTED = {
    "genesis": dict(
        {"key-step-*": ([], "none"), "after-store-dir": ([], "none"), "genesis-step-1": ([], "none"),
         "after-intent-fsync": ([T_GA], "none"), "genesis-step-2": ([T_GA], "none"),
         "frame-byte-last": ([T_DRP, T_GC, T_TD], "committed"),
         "after-frame-fsync": ([T_RP, T_GC, T_TD], "committed"), "genesis-step-3": ([T_RP, T_GC, T_TD], "committed"),
         "after-push": ([T_GC, T_TD], "committed"), "genesis-step-4": ([T_GC, T_TD], "committed"),
         "after-readback": ([T_GC, T_TD], "committed"), "genesis-step-5": ([T_GC, T_TD], "committed"),
         "genesis-step-6a": ([T_GC, T_TD], "committed"),
         "after-intent-remove": ([T_TD], "committed"), "genesis-step-6b": ([T_TD], "committed")},
        **{point: ([T_GA], "none") for point in TORN_SAMPLES}),
    "rotation": dict(
        {"key-step-*": ([], "neither"), "after-store-dir": ([], "neither"),
         "after-intent-fsync": ([T_TD], "neither"),
         "frame-byte-last": ([T_DRP, T_TD], "both"), "after-frame-fsync": ([T_RP, T_TD], "both"),
         "after-push": ([T_TD], "both"), "after-readback": ([T_TD], "both"), "after-intent-remove": ([T_TD], "both")},
        **{point: ([T_TR, T_TD], "neither") for point in TORN_SAMPLES}),
    "revocation": dict(
        {"after-intent-fsync": ([T_TD], "neither"),
         "frame-byte-last": ([T_DRP, T_TD], "both"), "after-frame-fsync": ([T_RP, T_TD], "both"),
         "after-push": ([T_TD], "both"), "after-readback": ([T_TD], "both"), "after-intent-remove": ([T_TD], "both")},
        **{point: ([T_TR, T_TD], "neither") for point in TORN_SAMPLES}),
    "revocation-active": dict(
        {"after-intent-fsync": ([T_TD], "neither"),
         "frame-byte-last": ([T_DRP, T_TD, T_QT], "both"), "after-frame-fsync": ([T_RP, T_TD, T_QT], "both"),
         "after-push": ([T_TD, T_QT], "both"), "after-readback": ([T_TD, T_QT], "both"),
         # the ceremony's own quarantine child wrote the marker before this cut
         "after-intent-remove": ([], "both")},
        **{point: ([T_TR, T_TD], "neither") for point in TORN_SAMPLES}),
    "regenesis": dict(
        {"regenesis-step-1": ([T_RA], "abandoned"), "after-frame-fsync": ([T_RA], "abandoned"),
         "regenesis-step-2": ([T_RA], "abandoned"),
         "after-push": ([T_RC, T_TD], "completed"), "after-readback": ([T_RC, T_TD], "completed"),
         "regenesis-step-3": ([T_RC, T_TD], "completed"), "regenesis-step-4": ([T_RC, T_TD], "completed"),
         "regenesis-step-5": ([T_TD], "completed")},
        **{point: ([T_RA], "abandoned") for point in FRAME_SAMPLES}),
}
# Intra-primitive cuts stop at the FIRST matching primitive. Genesis and
# re-genesis first create the empty log; rotation first creates a public key,
# all before intent publication. Revocation's first create is its intent.
# Rotation/revocation replace the cursor after removing intent: only an
# unpublished cursor needs tidy. Active revocation already has its marker,
# so its quarantined classifier needs no cursor recovery at either cut.
# Genesis/re-genesis first replace active while their intents still exist.
EXPECTED["genesis"].update({"fs-create-after-temp-fsync": ([], "none"),
    "fs-create-after-rename": ([], "none"),
    "fs-replace-after-temp-fsync": ([T_GC, T_TD], "committed"), "fs-replace-after-rename": ([T_GC, T_TD], "committed")})
for _kind in ("rotation", "revocation", "revocation-active"):
    EXPECTED[_kind].update({"fs-create-after-temp-fsync": ([], "neither"),
        "fs-create-after-rename": ([] if _kind == "rotation" else [T_TD], "neither"),
        "fs-replace-after-temp-fsync": ([] if _kind == "revocation-active" else [T_TD], "both"),
        "fs-replace-after-rename": ([], "both")})
EXPECTED["regenesis"].update({"fs-create-after-temp-fsync": ([], "abandoned"),
    "fs-create-after-rename": ([], "abandoned"),
    "fs-replace-after-temp-fsync": ([T_RC, T_TD], "completed"), "fs-replace-after-rename": ([T_RC, T_TD], "completed"),
    "archive-after-rename": ([T_RC, T_TD], "completed"), "archive-after-readonly": ([T_RC, T_TD], "completed")})

RC_OF = {("genesis", "none"): 0, ("genesis", "committed"): 0, ("rotation", "neither"): 0, ("rotation", "both"): 0,
         ("revocation", "neither"): 0, ("revocation", "both"): 0, ("revocation-active", "neither"): 0,
         ("revocation-active", "both"): 6, ("regenesis", "abandoned"): 6, ("regenesis", "completed"): 0}


def run_spec(trace, rc, **extra):
    return dict(extra, trace=trace, rc=rc)


# Recovery's own crash points, a failed push at the recovery-after-delimiter
# cut, and recovery against an unreachable remote (pending: no token at all).
EXTRA_SPECS = [
    dict(label="recover crashed after its replay-forward push", kind="rotation", point="after-frame-fsync",
         runs=[run_spec([T_RP], 137, crash="after-push"), run_spec([T_TD], 0)], outcome="both"),
    dict(label="recover crashed after its replay-forward readback", kind="rotation", point="after-frame-fsync",
         runs=[run_spec([T_RP], 137, crash="after-readback"), run_spec([T_TD], 0)], outcome="both"),
    dict(label="recover crashed after tidy removed the residual intent", kind="rotation", point="after-push",
         runs=[run_spec([T_TD], 137, crash="after-intent-remove"), run_spec([T_TD], 0)], outcome="both"),
    dict(label="recover crashed after tidy removed the active epoch's revocation intent (the record anchored: both, "
               "its marker not yet materialized, the quarantine row due)", kind="revocation-active",
         point="after-readback",
         runs=[run_spec([T_TD], 137, crash="after-intent-remove"), run_spec([T_QT], 6)], outcome="both"),
    dict(label="recover crashed after genesis completion removed genesis.intent", kind="genesis",
         point="after-readback",
         runs=[run_spec([T_GC], 137, crash="after-intent-remove"), run_spec([T_TD], 0)], outcome="committed"),
    dict(label="recover crashed after the bootstrap replay-forward push (A2.3 row 8, then row 9)",
         kind="genesis", point="after-frame-fsync",
         runs=[run_spec([T_RP], 137, crash="after-push"), run_spec([T_GC, T_TD], 0)], outcome="committed"),
    dict(label="recovery-after-delimiter: a rotation frame", kind="rotation", point="frame-byte-last",
         runs=[run_spec([T_DRP], 137, crash="recovery-after-delimiter"), run_spec([T_RP, T_TD], 0)],
         outcome="both"),
    dict(label="recovery-after-delimiter: a verify-only revocation frame", kind="revocation",
         point="frame-byte-last",
         runs=[run_spec([T_DRP], 137, crash="recovery-after-delimiter"), run_spec([T_RP, T_TD], 0)],
         outcome="both"),
    dict(label="recovery-after-delimiter: the active epoch's revocation frame", kind="revocation-active",
         point="frame-byte-last",
         runs=[run_spec([T_DRP], 137, crash="recovery-after-delimiter"), run_spec([T_RP, T_TD, T_QT], 6)],
         outcome="both"),
    dict(label="recovery-after-delimiter: genesis frame 1 (A2.3 row 7, then row 8)", kind="genesis",
         point="frame-byte-last",
         runs=[run_spec([T_DRP], 137, crash="recovery-after-delimiter"), run_spec([T_RP, T_GC, T_TD], 0)],
         outcome="committed"),
    dict(label="a failed push after the completed delimiter (remote made unreachable at the cut): rotation",
         kind="rotation", point="frame-byte-last",
         runs=[run_spec([T_DRP], 5, away_at="recovery-after-delimiter"),
               run_spec([T_RP, T_TD], 0, restore=True)], outcome="both"),
    dict(label="a failed push after the completed delimiter: the active epoch's revocation",
         kind="revocation-active", point="frame-byte-last",
         runs=[run_spec([T_DRP], 5, away_at="recovery-after-delimiter"),
               run_spec([T_RP, T_TD, T_QT], 6, restore=True)], outcome="both"),
    dict(label="a failed push after the completed delimiter: genesis frame 1", kind="genesis",
         point="frame-byte-last",
         runs=[run_spec([T_DRP], 5, away_at="recovery-after-delimiter"),
               run_spec([T_RP, T_GC, T_TD], 0, restore=True)], outcome="committed"),
    dict(label="pending: an unterminated rotation frame with the remote unreachable", kind="rotation",
         point="frame-byte-last",
         runs=[run_spec([], 5, away=True), run_spec([T_DRP, T_TD], 0, restore=True)], outcome="both"),
    dict(label="pending: a torn rotation frame with the remote unreachable", kind="rotation", point="frame-byte-mid",
         runs=[run_spec([], 5, away=True), run_spec([T_TR, T_TD], 0, restore=True)], outcome="neither"),
    dict(label="pending: the active epoch's durable revocation with the remote unreachable",
         kind="revocation-active", point="after-frame-fsync",
         runs=[run_spec([], 5, away=True), run_spec([T_RP, T_TD, T_QT], 6, restore=True)], outcome="both"),
    dict(label="pending: A2.3 row 6 with the remote unreachable (row 4)", kind="genesis", point="genesis-step-2",
         runs=[run_spec([], 5, away=True), run_spec([T_GA], 0, restore=True)], outcome="none"),
    dict(label="pending: A2.3 row 9 with the remote unreachable (row 4)", kind="genesis", point="genesis-step-5",
         runs=[run_spec([], 5, away=True), run_spec([T_GC, T_TD], 0, restore=True)], outcome="committed"),
    dict(label="pending: re-genesis before its push with the remote unreachable", kind="regenesis",
         point="regenesis-step-1",
         runs=[run_spec([], 5, away=True), run_spec([T_RA], 6, restore=True)], outcome="abandoned"),
    dict(label="pending: re-genesis after its push with the remote unreachable", kind="regenesis",
         point="after-push",
         runs=[run_spec([], 5, away=True), run_spec([T_RC, T_TD], 0, restore=True)], outcome="completed"),
    dict(label="pending: a committed store with the remote unreachable", kind="rotation", point=None,
         runs=[run_spec([], 5, away=True), run_spec([], 0, restore=True)], outcome="neither"),
]
EXTRA_SPECS += [
    dict(label="recover marker temp before publication", kind="revocation-active", point="after-readback",
         runs=[run_spec([T_TD, T_QT], 137, crash="fs-create-after-temp-fsync"), run_spec([T_QT], 6)], outcome="both"),
    dict(label="recover marker after publication", kind="revocation-active", point="after-readback",
         runs=[run_spec([T_TD, T_QT], 137, crash="fs-create-after-rename"), run_spec([], 6)], outcome="both"),
]
for _point in ("fs-replace-after-temp-fsync", "fs-replace-after-rename"):
    EXTRA_SPECS.append(dict(label="recover cursor " + _point, kind="rotation", point="after-frame-fsync",
        runs=[run_spec([T_RP, T_TD], 137, crash=_point),
              run_spec([T_TD] if _point == "fs-replace-after-temp-fsync" else [], 0)], outcome="both"))
for _point in ("archive-after-rename", "archive-after-readonly"):
    EXTRA_SPECS.append(dict(label="recover archive " + _point, kind="regenesis", point="after-readback",
        runs=[run_spec([T_RC], 137, crash=_point), run_spec([T_RC, T_TD], 0)], outcome="completed"))

# Fail-closed and quarantine outcomes, by the state recovery must leave.
SPECIALS = [
    dict(label="residual intent: marker written before intent removal", steps=[("genesis", "-"), ("revoke", "after-readback", "1")],
         mutate="materialize-revocation-marker", runs=[run_spec([], 6), run_spec([], 6)],
         state="quarantined", rule="active-epoch-revoked", residual_intent=True),
    dict(label="fail-closed: A2.3 row 1 (a corrupted genesis.intent)", steps=[("genesis", "genesis-step-2")],
         mutate="corrupt-genesis-intent", runs=[run_spec([], 7)], state="genesis-invalid"),
    dict(label="fail-closed: A2.3 row 1 (the intent-named directory missing)",
         steps=[("genesis", "genesis-step-3")], mutate="rm-intent-store", runs=[run_spec([], 7)],
         state="genesis-invalid"),
    dict(label="fail-closed: A2.3 row 2 (active names another store)", steps=[("genesis", "genesis-step-2")],
         mutate="active-other", runs=[run_spec([], 7)], state="anchor-mismatch"),
    dict(label="fail-closed: re-genesis with its new store directory missing",
         steps=BASE_STEPS["regenesis"] + [("regenesis", "regenesis-step-1")], mutate="rm-new-store",
         runs=[run_spec([], 12)], state="regenesis-invalid"),
    dict(label="fail-closed: re-genesis with the remote neither the old commit nor the intent's",
         steps=BASE_STEPS["regenesis"] + [("regenesis", "regenesis-step-1")], mutate="decoy-ref",
         runs=[run_spec([], 6)], state="regenesis-quarantined"),
    dict(label="fail-closed: a malformed active marker", steps=[("genesis", "-")], mutate="active-malformed",
         runs=[run_spec([], 12)], state="active-invalid"),
    dict(label="quarantine: a nonconforming tail", steps=[("genesis", "-")], mutate="garbage-tail",
         runs=[run_spec([T_QT], 6)], state="quarantined"),
    dict(label="quarantine: the remote one pointer behind with no intent", steps=[("genesis", "-"), ("rotate", "-")],
         mutate="ref-parent", runs=[run_spec([T_QT], 6)], state="quarantined"),
    dict(label="quarantine: A2.3 row 3 (frame 1 nonconforming)", steps=[("genesis", "genesis-step-2")],
         mutate="frame1-nonconforming", runs=[run_spec([T_QT], 7)], state="genesis-quarantined"),
    dict(label="quarantine: A2.3 row 5 (the ref deleted after active)", steps=[("genesis", "genesis-step-6a")],
         mutate="delete-ref", runs=[run_spec([T_QT], 6)], state="quarantined"),
    dict(label="quarantine: A2.3 row 10 (the remote holds the commit, frame 1 not durable)",
         steps=[("genesis", "after-push")], mutate="truncate-frame1", runs=[run_spec([T_QT], 7)],
         state="genesis-quarantined"),
    dict(label="quarantine: A2.3 row 11 (the remote holds another commit)", steps=[("genesis", "genesis-step-3")],
         mutate="decoy-ref", runs=[run_spec([T_QT], 7)], state="genesis-quarantined"),
    dict(label="quarantine: a record of a type tg-v1.0a does not admit", steps=[("genesis", "-")],
         mutate="plant-nonce", runs=[run_spec([T_QT], 6)], state="quarantined", rule="type-not-admitted"),
    dict(label="quarantine: a key file the store's records name is missing (A1.7)", steps=[("genesis", "-")],
         mutate="delete-key-file", runs=[run_spec([T_QT], 6)], state="quarantined"),
]

# ===========================================================================
# Output
# ===========================================================================

_emit_lock = threading.Lock()


def emit(claim, description, ok, detail=""):
    with _emit_lock:
        if ok:
            print(f"ok\t{claim}\t{description}", flush=True)
        else:
            print(f"not ok\t{claim}\t{description}\t{' '.join(str(detail).split())[:1500]}", flush=True)


class Checks:
    """Checks gathered by a parallel job, emitted in job order."""

    def __init__(self):
        self.items = []

    def __call__(self, claim, description, ok, detail=""):
        self.items.append((claim, description, bool(ok), detail))
        return bool(ok)


def run_job(claim, label, function):
    checks = Checks()
    try:
        function(checks)
    except Exception:  # noqa: BLE001 - a crashed case is a failed check
        checks(claim, f"{label}: completes without an exception", False, traceback.format_exc()[-1500:])
    return checks.items


def parallel(jobs):
    """jobs: (claim, label, function(checks)); every job's checks are emitted in order."""
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        futures = [pool.submit(run_job, claim, label, function) for claim, label, function in jobs]
        for future in futures:
            for item in future.result():
                emit(*item)


def guarded(claim, function):
    try:
        function()
    except Exception:  # noqa: BLE001
        emit(claim, f"{function.__name__} completes without an exception", False, traceback.format_exc()[-1500:])


def refused(function, *codes):
    """(refused with one of codes?, the error's code)."""
    try:
        function()
    except Exception as error:  # noqa: BLE001
        code = getattr(error, "code", type(error).__name__)
        return (not codes or code in codes), code
    return False, "not refused"


# ===========================================================================
# Test-side encodings, files, and the remote (independent of lib/loopauth)
# ===========================================================================

def canon(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def D(value):
    return "sha256:" + hashlib.sha256(canon(value)).hexdigest()


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def read_bytes(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except (FileNotFoundError, NotADirectoryError):
        return None


def read_json(path):
    data = read_bytes(path)
    if data is None:
        return None
    try:
        return json.loads(data)
    except ValueError:
        return {"<unparsable>": data[:60].decode("utf-8", "replace")}


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def tree_digest(root):
    """Every entry below root: kind, mode, size, mtime, and content digest."""
    if not os.path.lexists(root):
        return "absent"
    entries = []
    for current, dirs, files in os.walk(root):
        dirs.sort()
        info = os.lstat(current)
        entries.append((os.path.relpath(current, root), "d", stat.S_IMODE(info.st_mode), info.st_mtime_ns))
        for name in sorted(files):
            full = os.path.join(current, name)
            info = os.lstat(full)
            data = b""
            if stat.S_ISREG(info.st_mode) and info.st_mode & 0o400:
                data = read_bytes(full) or b""
            entries.append((os.path.relpath(full, root), "f", stat.S_IMODE(info.st_mode), info.st_size,
                            info.st_mtime_ns, hashlib.sha256(data).hexdigest()))
    return hashlib.sha256(repr(entries).encode()).hexdigest()


def fdigest(seq, kind, content):
    return "sha256:" + hashlib.sha256(f"OLF1 {seq} {kind} {len(content)}".encode() + content).hexdigest()


def mkframe(seq, kind, content):
    return (f"OLF1 {seq} {kind} {len(content)} {fdigest(seq, kind, content)}\n").encode() + content + b"\n"


def parse_frames(data):
    """The leading complete frames of a log (test-side parser): dicts with raw bytes."""
    frames, offset = [], 0
    while offset < len(data):
        newline = data.find(b"\n", offset)
        if newline < 0:
            break
        match = re.fullmatch(rb"OLF1 ([0-9]+) (\S+) ([0-9]+) (sha256:[0-9a-f]{64})", data[offset:newline])
        if not match:
            break
        end = newline + 1 + int(match.group(3))
        if end + 1 > len(data) or data[end:end + 1] != b"\n":
            break
        frames.append({"seq": int(match.group(1)), "type": match.group(2).decode(), "digest": match.group(4).decode(),
                       "header": newline + 1 - offset, "content": data[newline + 1:end], "raw": data[offset:end + 1]})
        offset = end + 1
    return frames, offset


def resolve_bin(name):
    for directory in BIN_DIRS:
        path = os.path.join(directory, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


GIT = resolve_bin("git") or shutil.which("git") or "git"
SSH_KEYGEN = resolve_bin("ssh-keygen")


def git(*args, stdin=b"", check=True, extra=None):
    env = {"PATH": os.environ.get("PATH", ":".join(BIN_DIRS)), "HOME": TMP, "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    env.update(extra or {})
    result = subprocess.run([GIT, "-c", "core.hooksPath=/dev/null", *args], input=stdin, capture_output=True,
                            env=env, cwd=TMP)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {args}: {result.stderr.decode()}")
    return result


def ssh_keygen(*args, stdin=b""):
    env = {"PATH": ":".join(BIN_DIRS), "HOME": TMP, "LANG": "C", "LC_ALL": "C", "TMPDIR": TMP}
    return subprocess.run([SSH_KEYGEN, *args], input=stdin, capture_output=True, env=env)


def remote_tip(remote):
    text = git("--git-dir", remote, "rev-parse", "--verify", "-q", ANCHOR_REF, check=False).stdout.decode().strip()
    return text or None


def remote_commits(remote):
    if remote_tip(remote) is None:
        return set()
    return set(git("--git-dir", remote, "rev-list", ANCHOR_REF, check=False).stdout.decode().split())


def parent_of(remote, oid):
    match = re.search(rb"^parent ([0-9a-f]{40})", git("--git-dir", remote, "cat-file", "-p", oid).stdout, re.M)
    return match.group(1).decode() if match else None


def anchor_active(remote):
    """The remote tip's pointer (active), None when the ref is absent or is no anchor."""
    tip = remote_tip(remote)
    if tip is None:
        return None
    try:
        commit = git("--git-dir", remote, "cat-file", "-p", tip).stdout
        tree = re.search(rb"^tree ([0-9a-f]{40})", commit, re.M).group(1).decode()
        blob = re.search(rb"blob ([0-9a-f]{40})\tanchor\.json", git("--git-dir", remote, "cat-file", "-p",
                                                                     tree).stdout).group(1).decode()
        return json.loads(git("--git-dir", remote, "cat-file", "-p", blob).stdout)["active"]
    except (AttributeError, ValueError, KeyError, RuntimeError):
        return None


def set_ref(remote, oid):
    if oid is None:
        git("--git-dir", remote, "update-ref", "-d", ANCHOR_REF)
    else:
        git("--git-dir", remote, "update-ref", ANCHOR_REF, oid)


def decoy_commit(remote):
    blob = git("--git-dir", remote, "hash-object", "-w", "--stdin", stdin=b"not an anchor").stdout.decode().strip()
    tree = git("--git-dir", remote, "mktree", stdin=f"100644 blob {blob}\tx\n".encode()).stdout.decode().strip()
    return git("--git-dir", remote, "commit-tree", tree, "-m", "decoy",
               extra={"GIT_AUTHOR_NAME": "d", "GIT_AUTHOR_EMAIL": "d@d", "GIT_COMMITTER_NAME": "d",
                      "GIT_COMMITTER_EMAIL": "d@d"}).stdout.decode().strip()


def auth(home, *parts):
    return os.path.join(home, ".config", "olddonkey-loop", "authority", *parts)


def journal_root(home):
    return os.path.join(home, ".config", "olddonkey-loop", "journal")


def logs_of(home):
    """{(place, store_id): log bytes} of every store, live (stores/) and archived."""
    result = {}
    for place in ("stores", "archive"):
        base = auth(home, place)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            data = read_bytes(os.path.join(base, name, "log", "segment-000001.olf"))
            if data is not None:
                result[(place, name)] = data
    return result


def frames_of(home):
    found = set()
    for data in logs_of(home).values():
        found |= {frame["raw"] for frame in parse_frames(data)[0]}
    return found


def intents_of(home):
    """Every durable write intent: its frame bytes and anchor commit."""
    paths = [auth(home, "genesis.intent"), auth(home, "regenesis.intent")]
    base = auth(home, "stores")
    if os.path.isdir(base):
        paths += [os.path.join(base, name, "intent") for name in sorted(os.listdir(base))]
    result = []
    for path in paths:
        value = read_json(path)
        if isinstance(value, dict) and "frame_b64" in value:
            try:
                frame = base64.b64decode(value["frame_b64"])
            except (ValueError, TypeError):
                frame = None
            result.append({"path": path, "frame": frame, "commit": value.get("anchor_commit")})
    return result


def key_files_of(home):
    """{(store_id, path under keys/): content digest}, wherever the store lives."""
    result = {}
    for place in ("stores", "archive"):
        base = auth(home, place)
        if not os.path.isdir(base):
            continue
        for store_id in sorted(os.listdir(base)):
            keys = os.path.join(base, store_id, "keys")
            for current, _dirs, files in os.walk(keys):
                for name in files:
                    full = os.path.join(current, name)
                    result[(store_id, os.path.relpath(full, keys))] = hashlib.sha256(read_bytes(full) or b"").hexdigest()
    return result


def lineage(home):
    """The active store read test-side: id, generation, L, epoch states, active epoch."""
    active = read_json(auth(home, "active"))
    info = {"active": active, "store_id": None, "generation": None, "L": 0, "epochs": {}, "active_epoch": None,
            "frames": [], "payloads": []}
    if not isinstance(active, dict) or "store_id" not in active:
        return info
    data = read_bytes(auth(home, "stores", active["store_id"], "log", "segment-000001.olf")) or b""
    frames = parse_frames(data)[0]
    epochs, current, payloads = {}, None, []
    for frame in frames:
        payload = json.loads(frame["content"])["payload"]
        payloads.append(payload)
        body = payload["body"]
        if payload["type"] in ("store.genesis", "store.regenesis"):
            epochs, current = {"1": "active"}, 1
        elif payload["type"] == "epoch.rotated":
            epochs[str(current)] = "verify-only"
            epochs[str(body["epoch"])] = "active"
            current = body["epoch"]
        elif payload["type"] == "epoch.revoked":
            epochs[str(body["epoch"])] = "revoked"
            if body["epoch"] == current:
                current = None
    info.update(store_id=active["store_id"], generation=active["generation"], L=len(frames), epochs=epochs,
                active_epoch=current, frames=frames, payloads=payloads)
    return info


def key_dir_of(info, epoch):
    for payload in info["payloads"]:
        body = payload["body"]
        if payload["type"] in ("store.genesis", "store.regenesis") and epoch == 1:
            return body["key_dir"]
        if payload["type"] == "epoch.rotated" and body["epoch"] == epoch:
            return body["key_dir"]
    raise RuntimeError(f"no key directory for epoch {epoch}")


def fingerprint_pub(line):
    blob = base64.b64decode(line.split()[1])
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def forge_frame(home, info, kind, body, *, seq, epoch):
    """A record of kind sealed with the store's own certified subkey for it
    (the epoch's), chained after the log's last record."""
    key_dir = auth(home, "stores", info["store_id"], "keys", key_dir_of(info, epoch))
    cert = os.path.join(key_dir, f"{kind}-cert.pub")
    payload = {"type": kind, "v": 1, "store_id": info["store_id"], "generation": info["generation"], "seq": seq,
               "epoch": epoch, "key_id": fingerprint_pub(read_bytes(os.path.join(key_dir, f"{kind}.pub")).decode()),
               "prev": info["frames"][seq - 2]["digest"], "body": body}
    signed = ssh_keygen("-Y", "sign", "-f", cert, "-n", f"olddonkey-loop.authority.{kind}.v1", stdin=canon(payload))
    if signed.returncode != 0:
        raise RuntimeError(f"ssh-keygen -Y sign: {signed.stderr.decode()}")
    content = canon({"payload": payload, "sig": signed.stdout.decode()})
    return mkframe(seq, kind, content), payload, signed.stdout.decode(), key_dir


def seal_verifies(key_dir, kind, payload, sig):
    """ssh-keygen -Y verify the seal against the epoch root as the certificate
    authority for the type's principal (what the writer and verifier check)."""
    root_pub = read_bytes(os.path.join(key_dir, "root.pub")).decode().split()
    signers = os.path.join(TMP, f"signers-{kind}")
    sig_path = os.path.join(TMP, f"sig-{kind}")
    with open(signers, "w") as handle:
        handle.write(f"{kind} cert-authority {root_pub[0]} {root_pub[1]}\n")
    with open(sig_path, "w") as handle:
        handle.write(sig)
    result = ssh_keygen("-Y", "verify", "-f", signers, "-I", kind, "-n", f"olddonkey-loop.authority.{kind}.v1",
                        "-s", sig_path, stdin=canon(payload))
    return result.returncode == 0


def read_only_tree(root):
    """Every directory 0500 and every file 0400 (an archived store)."""
    for current, _dirs, files in os.walk(root):
        if stat.S_IMODE(os.lstat(current).st_mode) != 0o500:
            return False
        for name in files:
            if stat.S_IMODE(os.lstat(os.path.join(current, name)).st_mode) != 0o400:
                return False
    return True


# ===========================================================================
# Commands, journals, and cases
# ===========================================================================

class Res:
    def __init__(self, rc, out, err):
        self.rc = rc
        self.out = out
        self.err = err
        self.json = last_json(out)

    def __repr__(self):
        return f"rc={self.rc} json={json.dumps(self.json)[:500]} err={self.err[-400:]!r}"


def last_json(text):
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {}


def cli_env(home, test=True, **extra):
    env = {"HOME": home, "PATH": os.environ.get("PATH", ":".join(BIN_DIRS)), "LANG": "C", "LC_ALL": "C",
           "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    if test:
        env["LOOP_AUTHORITY_TEST"] = "1"
    for key, value in extra.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def run_cmd(argv, env, timeout=600):
    result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout, cwd=TMP)
    return Res(result.returncode, result.stdout.decode("utf-8", "replace"), result.stderr.decode("utf-8", "replace"))


def writer(home, *args, **extra):
    return run_cmd([BASH, AUTH, *args], cli_env(home, **extra))


def verifier(home, **extra):
    return run_cmd([BASH, VERIFY], cli_env(home, **extra))


class Journal:
    """One run written by the real loop-journal, installed byte for byte into
    each case's HOME so `loop-authority refs` has a run to report on."""

    def __init__(self, base):
        self.source = os.path.join(base, "journal-source")
        self.ws = os.path.join(base, "workspace")
        os.makedirs(self.source, 0o700)
        os.makedirs(self.ws)
        res = run_cmd([BASH, JOURNAL, "begin-run", "--workspace", self.ws], cli_env(self.source, test=False))
        match = re.search(r"^run=(\S+)$", res.out, re.M)
        if res.rc != 0 or not match:
            raise RuntimeError(f"loop-journal begin-run failed: {res}")
        self.run_id = match.group(1)

    def install(self, home):
        root = os.path.join(home, ".config", "olddonkey-loop")
        for path in (os.path.join(home, ".config"), root):
            os.makedirs(path, exist_ok=True)
            os.chmod(path, 0o700)
        shutil.copytree(journal_root(self.source), journal_root(home), symlinks=True)

    def refs(self, home, **extra):
        return writer(home, "refs", "--workspace", self.ws, "--run", self.run_id, **extra)


_case_lock = threading.Lock()
_case_numbers = itertools.count(1)
_trace_numbers = itertools.count(1)


def trace_sink_problems(tokens):
    """Completed calls must fit their own frozen row, even on a failed run."""
    key_work = {"create_key", "certify_key", "seal", "seal_pointer", "append_frame", "write_cursor"}
    allowed = {
        "ceremony: authority-genesis": key_work | {"create_store_dir", "write_genesis_intent", "write_active", "remove_genesis_intent"},
        "ceremony: epoch-rotation": key_work | {"create_key_dir", "write_intent", "remove_intent"},
        "ceremony: epoch-revocation": {"seal", "seal_pointer", "write_intent", "append_frame", "write_cursor", "remove_intent"},
        "ceremony: linked-regenesis": key_work | {"create_store_dir", "write_regenesis_intent", "archive_store", "write_active", "remove_regenesis_intent"},
        T_TR: {"truncate_frame"}, T_RP: {"push_anchor"}, T_DRP: {"complete_delimiter", "push_anchor"},
        T_TD: {"write_cursor", "remove_intent"}, T_QT: {"write_quarantine"},
        T_GA: {"remove_genesis_intent"}, T_GC: {"write_active", "remove_genesis_intent"},
        T_RA: {"remove_regenesis_intent"}, T_RC: {"archive_store", "write_active", "remove_regenesis_intent"},
    }
    for row in CEREMONY_ROWS.values():
        allowed[f"child({row}): authority-head-advance"] = {"push_anchor"}
    allowed["child(epoch-revocation): store-quarantine"] = {"write_quarantine"}
    problems = []
    for token in tokens:
        label = token_label(token)
        unexpected = set(token["sinks"]) - allowed.get(label, set())
        if label not in allowed or unexpected:
            problems.append((label, sorted(unexpected)))
    return problems


class Trace:
    """What the recording fixture saw in one run of the real entry point: the
    tokens minted, in order, each with completed sinks checked against its frozen
    row (not a claim about calls interrupted before returning); every
    tools.run command; and the crash seam's events."""

    def __init__(self, path):
        tokens, order = {}, []
        self.commands, self.events = [], []
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    event = json.loads(line)
                    if event["e"] == "mint":
                        tokens[event["id"]] = dict(event, sinks=[])
                        order.append(event["id"])
                    elif event["e"] == "sink" and event.get("id") in tokens:
                        tokens[event["id"]]["sinks"].append(event["fn"])
                    elif event["e"] == "run":
                        self.commands.append(event["cmd"])
                    else:
                        self.events.append(event)
        self.tokens = [tokens[token_id] for token_id in order]
        problems = trace_sink_problems(self.tokens)
        if problems:
            raise ValueError(f"trace-sink: {problems}")

    @property
    def labels(self):
        return [token_label(token) for token in self.tokens]

    @property
    def sinks(self):
        return [token["sinks"] for token in self.tokens]


def token_label(token):
    kind, row = token["kind"], token["row"]
    if kind == "recovery":
        if row == "anchor-replay-forward":
            return T_DRP if token.get("unterminated") else T_RP
        return {"torn-frame-truncation": T_TR, "recovery-tidy": T_TD, "store-quarantine": T_QT}.get(
            row, f"recovery: {row}")
    if kind == "finish":
        which = {"authority-genesis": "genesis", "linked-regenesis": "regenesis"}.get(row, row)
        return f"ceremony({which}): {'completion' if token['action'] == 'complete' else 'abandonment'}"
    if kind == "child":
        return f"child({token['parent']}): {row}"
    return f"{kind}: {row}"


class Case:
    """A scratch HOME and a file:// bare remote (paths of one length for
    every case under a root), with the journal installed."""

    def __init__(self, root, label, journal=None):
        with _case_lock:
            number = next(_case_numbers)
        self.label = label
        self.dir = os.path.join(root, f"{number:04d}")
        os.makedirs(self.dir)
        self.home = os.path.join(self.dir, "home")
        os.mkdir(self.home, 0o700)
        self.remote_path = os.path.join(self.dir, "remote.git")
        git("init", "--bare", "-q", self.remote_path)
        self.url = "file://" + self.remote_path
        self.away = False
        self.journal = journal
        if journal is not None:
            journal.install(self.home)

    @property
    def remote(self):
        return self.remote_path + ".away" if self.away else self.remote_path

    def go_away(self):
        os.rename(self.remote_path, self.remote_path + ".away")
        self.away = True

    def come_back(self):
        os.rename(self.remote_path + ".away", self.remote_path)
        self.away = False

    def child(self, command, point="-", *extra):
        """One ceremony core in its own process (the TTY challenge stubbed)."""
        result = subprocess.run([sys.executable, FZ, "child", SKILL, TMP, self.home, self.url, command, point,
                                 *extra], capture_output=True, timeout=600, env=cli_env(self.home))
        return result.returncode, result.stderr.decode("utf-8", "replace")[-800:]

    def steps(self, steps):
        for command, point, *extra in steps:
            rc, err = self.child(command, point, *extra)
            want = 137 if point != "-" else 0
            if rc != want:
                raise RuntimeError(f"{self.label}: {command} at {point} exited {rc}, not {want}: {err}")

    def cli(self, *args, crash=None, away_at=None, tty=False):
        """The real loop-authority.py with the recording fixture: (Res, Trace)."""
        with _case_lock:
            number = next(_trace_numbers)
        trace = os.path.join(self.dir, f"trace-{number}.jsonl")
        hooks = {"tty": tty}
        if away_at:
            hooks.update(away_at=away_at, remote=self.remote_path)
        res = run_cmd([sys.executable, FZ, "cli", SKILL, TMP, trace, json.dumps(hooks), *args],
                      cli_env(self.home, LOOP_AUTHORITY_CRASH_AT=crash))
        if away_at and os.path.lexists(self.remote_path + ".away"):
            self.away = True
        return res, Trace(trace)

    def writer(self, *args, **extra):
        return writer(self.home, *args, **extra)

    def verifier(self, **extra):
        return verifier(self.home, **extra)

    def roots(self):
        return (auth(self.home), journal_root(self.home), self.remote)

    def durable(self):
        return {"frames": frames_of(self.home), "commits": remote_commits(self.remote),
                "intents": intents_of(self.home), "keys": key_files_of(self.home)}

    def observe(self, writer_result=None, read_only_checks=False, previous=None):
        """The store classified by status (or, after a recovery that printed
        one, that recovery's own final classification) and the independent
        verifier -- whose earlier answer is reused when the authority
        directory and the remote are byte-identical to what it read -- and
        refs' store state whenever the state is pending, names a quarantine
        row still due, or is the active epoch's revocation (F6's "both" for
        it is asserted through all three), and when asked, with the three
        trees digested around them; verify and two submit refusals added when
        asked."""
        roots = self.roots()
        before = [tree_digest(root) for root in roots]
        w = writer_result if writer_result is not None and writer_result.json else self.writer("status")
        state = (w.json or {}).get("state")
        if previous is not None and previous.digests[0] == before[0] and previous.digests[2] == before[2] \
                and previous.remote == self.remote:
            v = previous.v
        else:
            v = self.verifier()
        due = (w.json or {}).get("row") == "store-quarantine" or (w.json or {}).get("rule") == "active-epoch-revoked"
        r = self.journal.refs(self.home) if read_only_checks or state in PENDING_STATES or due else None
        observation = Observation(w, v, r)
        if read_only_checks:
            observation.extra = {"verify": self.writer("verify"),
                                 "submit dormant": self.writer("submit", "request-opening"),
                                 "submit derived": self.writer("submit", "store-quarantine")}
        after = [tree_digest(root) for root in roots]
        observation.digests = after
        observation.remote = self.remote
        observation.unchanged = before == after
        observation.changed = [name for name, b, a in zip(("authority", "journal", "remote"), before, after)
                               if b != a]
        return observation


class Observation:
    def __init__(self, w, v, r):
        self.w, self.v, self.r = w, v, r
        self.extra = {}
        self.unchanged = True
        self.changed = []
        self.digests = []
        self.remote = None

    @property
    def state(self):
        return (self.w.json or {}).get("state")

    @property
    def table(self):
        return (self.w.json or {}).get("table")

    @property
    def store(self):
        return (self.r.json or {}).get("store") or {} if self.r is not None else None

    def problems(self):
        """Disagreement among the writer, the verifier, and refs' store state
        (when read), or a pending state that authorizes anything."""
        w, v, s = self.w.json or {}, self.v.json or {}, self.store
        problems = []
        if not w or not v or s == {}:
            problems.append(f"missing output: writer {self.w} | verifier {self.v} | refs {self.r}")
            return problems
        if w.get("state") != v.get("state") or w.get("authorizing_state") != v.get("authorizing_state"):
            problems.append(f"the verifier ({v.get('state')}, {v.get('authorizing_state')}) disagrees with the writer "
                            f"({w.get('state')}, {w.get('authorizing_state')})")
        if any(x.get("current_authorization") for x in (w, v, s or {})):
            problems.append("a test lineage reported current authorization")
        if w.get("state") in PENDING_STATES and (w.get("authorizing_state") or v.get("authorizing_state")):
            problems.append("a pending state authorizes")
        if s is not None:
            if (s.get("state") == "current") != (w.get("authorizing_state") is True):
                problems.append(f"refs reports {s.get('state')} ({s.get('reason')}) for a store whose "
                                f"authorizing_state is {w.get('authorizing_state')}")
            if s.get("classification") != w.get("state"):
                problems.append(f"refs classified {s.get('classification')}, the writer {w.get('state')}")
            if w.get("state") in PENDING_STATES and (s.get("state") != "unavailable"
                                                     or s.get("reason") not in ("pending", "remote-unreachable")):
                problems.append(f"refs reports a pending store as {s.get('state')} ({s.get('reason')})")
        return problems

    def read_only_problems(self):
        problems = [] if self.unchanged else [f"changed: {self.changed}"]
        verify = self.extra.get("verify")
        if verify is not None and (verify.json or {}).get("state") != self.state:
            problems.append(f"verify says {(verify.json or {}).get('state')}, status {self.state}")
        dormant, derived = self.extra.get("submit dormant"), self.extra.get("submit derived")
        if dormant is not None and not (dormant.rc == 8 and "dormant-row:request-opening" in dormant.err):
            problems.append(f"submit request-opening: {dormant}")
        if derived is not None and not (derived.rc == 4 and "exclusion-X7" in derived.err):
            problems.append(f"submit store-quarantine: {derived}")
        return problems


# The classified states (state, table) whose verify and submit runs have been
# checked read-only: every state once, by the first case that reaches it.
_read_only_states = set()


def first_of_state(observation):
    with _case_lock:
        key = (observation.state, observation.table)
        first = key not in _read_only_states
        _read_only_states.add(key)
    return first
PY

cat >> "$TMP_ROOT/fz.py" <<'PY'
# ===========================================================================
# static: F1-F4 over the source of the final tree, and planted copies
# ===========================================================================

HEREDOC_RE = re.compile(r"<<-?\s*['\"]?([A-Za-z_]+)['\"]?[^\n]*\n(.*?)\n\1(?:\n|\Z)", re.S)


def heredocs(text):
    return [match.group(2) for match in HEREDOC_RE.finditer(text)]


def load_registry_scanner():
    """registry-selftest.sh's own driver (rs.py), extracted unmodified from
    its heredoc: written out to run its static mode (p2 s7's scan and its
    planted controls), and loaded without its mode dispatch so the same
    scanner also judges this suite's planted copies."""
    text = read_text(REGISTRY_SUITE)
    match = re.search(r"cat > \"\$TMP_ROOT/rs\.py\" <<'PY'\n(.*?)\nPY\n", text, re.S)
    if match is None:
        raise RuntimeError("registry-selftest.sh no longer embeds rs.py where expected")
    source = match.group(1) + "\n"
    path = os.path.join(TMP, "rs.py")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(source)
    tree = ast.parse(source, path)
    last = tree.body[-1]
    if not (isinstance(last, ast.Expr) and isinstance(last.value, ast.Call)
            and isinstance(last.value.func, ast.Subscript)):
        raise RuntimeError("rs.py's last statement is not its mode dispatch")
    tree.body.pop()
    namespace = {"__name__": "registry_selftest_rs", "__file__": path}
    saved = sys.argv
    sys.argv = [path, "none", LIB, os.path.join(TMP, "rs-namespace")]
    try:
        exec(compile(tree, path, "exec"), namespace)  # noqa: S102 - the sibling suite's own driver
    finally:
        sys.argv = saved
    return path, namespace


AUTHORITY_IMPORTERS = {
    "lib/loopauth/store.py", "lib/loopauth/tools.py", "scripts/loop-authority-verify",
    "scripts/loop-authority.py", "scripts/loop-calibration", "scripts/loop-index", "scripts/loop-journal",
}


def authority_importers(root):
    found = set()
    for folder in ("scripts", "backends", "lib"):
        base = os.path.join(root, folder)
        if not os.path.isdir(base):
            continue
        for directory, dirs, files in os.walk(base, followlinks=False):
            dirs[:] = [name for name in dirs if name != "__pycache__"]
            for filename in files:
                path = os.path.join(directory, filename)
                if os.path.islink(path):
                    found.add("symlink:" + os.path.relpath(path, root))
                    continue
                text = read_bytes(path).decode("utf-8", "replace")
                if re.search(r"\bloopauth\b|\bimportlib\b|\b__import__\b", text):
                    found.add(os.path.relpath(path, root))
    return found


def writer_sources(root):
    """{module: (path, source)}: every lib/loopauth module, the Python of
    scripts/loop-authority (its heredocs, if any), and loop-authority.py,
    which that wrapper runs."""
    package = os.path.join(root, "lib", "loopauth")
    sources = {}
    for filename in sorted(os.listdir(package)):
        if filename.endswith(".py"):
            path = os.path.join(package, filename)
            sources[filename[:-3]] = (path, read_text(path))
    wrapper = os.path.join(root, "scripts", "loop-authority")
    for number, body in enumerate(heredocs(read_text(wrapper)), 1):
        sources[f"loop-authority-heredoc-{number}"] = (wrapper, body)
    entry = os.path.join(root, "scripts", "loop-authority.py")
    sources["loop-authority"] = (entry, read_text(entry))
    return sources


def parse_modules(sources):
    trees, errors = {}, []
    for module, (path, source) in sources.items():
        try:
            trees[module] = ast.parse(source, path)
        except SyntaxError as error:
            errors.append(f"{module}: {error}")
    return trees, errors


class Index:
    """Every node of a set of modules with the qualified name of the function
    or method enclosing it (the module name at module level)."""

    def __init__(self, trees):
        self.functions = {}
        self.nodes = []
        self.calls = []
        for module, tree in trees.items():
            self._visit(module, tree, module)
        self.call_funcs = {id(call.func) for _m, _s, call in self.calls}

    def _visit(self, module, node, scope):
        for child in ast.iter_child_nodes(node):
            inner = scope
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                inner = f"{scope}.{child.name}"
                if not isinstance(child, ast.ClassDef):
                    self.functions[inner] = child
            self.nodes.append((module, scope, child))
            if isinstance(child, ast.Call):
                self.calls.append((module, scope, child))
            self._visit(module, child, inner)


def callee(call):
    func = call.func
    if isinstance(func, ast.Name):
        return None, func.id
    if isinstance(func, ast.Attribute):
        return (func.value.id if isinstance(func.value, ast.Name) else "<expr>"), func.attr
    return None, None


def keyword(call, name):
    return next((kw.value for kw in call.keywords if kw.arg == name), None)


def constant(node):
    return node.value if isinstance(node, ast.Constant) else None


def store_call(module, call, name):
    owner, attr = callee(call)
    return attr == name


def sink_uses(index):
    """(sink -> the functions calling it, sinks used as values)."""
    pairs, values = {}, []
    for module, scope, node in index.nodes:
        name = None
        if isinstance(node, ast.Attribute) and node.attr in SINK_FUNCTIONS and isinstance(node.ctx, ast.Load):
            name = node.attr
        elif isinstance(node, ast.Name) and node.id in SINK_FUNCTIONS and module == "store" \
                and isinstance(node.ctx, ast.Load):
            name = node.id
        if name is None:
            continue
        if id(node) in index.call_funcs:
            pairs.setdefault(name, set()).add(scope)
        else:
            values.append(f"{name} used as a value (not called) in {scope}:{node.lineno}")
    return pairs, values


def sink_problems(index):
    pairs, values = sink_uses(index)
    problems = list(values)
    for sink in SINK_FUNCTIONS:
        got = pairs.get(sink, set())
        for caller in sorted(got - SINK_DRIVERS[sink]):
            problems.append(f"{sink} is called from {caller}, not from the transaction driver of a row")
    declarations = [node for module, scope, node in index.nodes if module == "store" and scope == "store"
                    and isinstance(node, (ast.Assign, ast.AugAssign)) and any(
                        isinstance(target, ast.Name) and target.id == "SINK_FUNCTIONS"
                        for target in (node.targets if isinstance(node, ast.Assign) else [node.target]))]
    try:
        actual = ast.literal_eval(declarations[0].value) if len(declarations) == 1 and isinstance(declarations[0], ast.Assign) else None
    except (ValueError, TypeError):
        actual = None
    if actual != SINK_FUNCTIONS:
        problems.append(f"an unfrozen sink declaration: {actual}")
    return problems, pairs


def begun_rows(node):
    return {constant(call.args[0]) for call in ast.walk(node) if isinstance(call, ast.Call)
            and store_call("", call, "begin") and call.args and constant(call.args[0]) is not None}


def mints(node):
    """The function mints its own token: a ceremony row's store.begin, or the
    recovery routine's _mint (recovery and finish tokens)."""
    for call in ast.walk(node):
        if isinstance(call, ast.Call) and (store_call("", call, "begin") or callee(call)[1] == "_mint"):
            return True
    return False


def callers_of(index, qual):
    module, _dot, name = qual.partition(".")
    scopes = set()
    for caller_module, scope, call in index.calls:
        owner, attr = callee(call)
        if attr == name and ((caller_module == module and owner is None) or owner == module):
            scopes.add(scope)
    return scopes


def is_token_helper(index, qual, seen=()):
    """A helper taking its driver's token: first parameter `token`, and every
    caller mints that token or is such a helper itself."""
    node = index.functions.get(qual)
    if node is None or not node.args.args or node.args.args[0].arg != "token":
        return False
    callers = callers_of(index, qual)
    if not callers:
        return False
    for caller in callers:
        caller_node = index.functions.get(caller)
        if caller_node is None or caller in seen:
            return False
        if not mints(caller_node) and not is_token_helper(index, caller, seen + (qual,)):
            return False
    return True


def driver_problems(index, qualities):
    problems = []
    for qual in sorted(qualities):
        node = index.functions.get(qual)
        if node is None:
            problems.append(f"{qual} does not exist")
        elif not mints(node) and not is_token_helper(index, qual):
            problems.append(f"{qual} is neither a row's transaction driver (it mints no token) nor a helper taking "
                            "such a driver's token")
    return problems


def rows_reaching(index, qual, seen=()):
    node = index.functions.get(qual)
    rows = begun_rows(node) if node is not None else set()
    if rows or node is None:
        return rows
    for caller in callers_of(index, qual):
        if caller not in seen:
            rows |= rows_reaching(index, caller, seen + (qual,))
    return rows


def minter_problems(index, registry):
    problems = []
    for module, scope, call in index.calls:
        owner, attr = callee(call)
        at = f"{scope}:{call.lineno}"
        in_store = owner == "store" or (module == "store" and owner is None)
        if in_store and attr == "begin":
            row = constant(call.args[0]) if call.args else None
            kind = scope.rsplit(".", 1)[-1]
            if not (module == "ceremony" and scope == f"ceremony.{kind}" and CEREMONY_ROWS.get(kind) == row):
                problems.append(f"store.begin({row!r}) at {at}: only each ceremony's driver begins its own row")
        elif in_store and attr == "child":
            row = constant(call.args[1]) if len(call.args) > 1 else None
            parents = rows_reaching(index, scope)
            if row is None or not parents or any(row not in registry.ROW_BY_ID[parent]["children"]
                                                 for parent in parents):
                problems.append(f"store.child(..., {row!r}) at {at} under rows {sorted(parents)}")
        elif in_store and attr in ("begin_recovery", "begin_finish") and scope != "recover._mint":
            problems.append(f"store.{attr} at {at}: only recover._mint mints recovery and finish tokens")
        elif attr == "_mint" and (owner in (None, "recover")) and scope not in RECOVERY_EXECUTORS \
                and not (module == "recover" and scope == "recover._mint"):
            problems.append(f"_mint at {at}: only the recovery routine's executors mint")
        elif attr in ("Token", "_new") \
                and scope not in ("store.begin", "store.begin_recovery", "store.begin_finish", "store.child"):
            # under any receiver (s._new, mods["store"].Token) or a bare name
            problems.append(f"{attr}(...) at {at}: a token built outside the four minting functions")
    return problems


# ---------------------------------------------------------------------------
# F1's alias-proof scan of the writer entry's and the verifier's own Python
# (neither is under lib/loopauth, so p2 s7's scan does not reach them). Every
# name an import binds is resolved to what it names, and every attribute
# chain rooted at one is resolved against the real module objects, so a
# primitive is known by what it is, however it is spelled: `import os as o;
# o.system`, `os.path.os.system`, and `posix.system` are all os.system. A
# primitive is refused wherever it is referenced outside the scopes allowed
# it -- called, or taken as a value for an indirect call -- and every route a
# static resolution cannot follow is refused outright: an import outside the
# frozen list, an import rename, a from-import of a library (it binds a name
# bare), an import-bound name rebound or used as a value (assigned, passed,
# stored, returned), a module reached through another module (os.path
# excepted), a chain that does not resolve, dynamic attribute access
# (getattr and its kin), and a namespace lookup (globals(), vars(), a dunder,
# a frame, sys.modules, eval and its kin); and, receiver-independent, any
# attribute named like a process or write primitive or a primitive module
# under a receiver no import binds (tools.subprocess, reached through a
# loopauth module, included).
# ---------------------------------------------------------------------------

# The only modules each may import.
ENTRY_IMPORTS = {"__future__", "argparse", "importlib", "json", "os", "stat", "sys"}
VERIFIER_IMPORTS = {"__future__", "base64", "hashlib", "json", "os", "re", "secrets", "shutil", "stat", "struct",
                    "subprocess", "sys"}
# A module every attribute of which is a primitive of its rule (reached as
# <module>.<anything>, by whatever name the module is bound to).
PRIMITIVE_MODULES = {"subprocess": "process", "pty": "process", "multiprocessing": "process", "asyncio": "process",
                     "concurrent": "process", "_posixsubprocess": "process", "ctypes": "process", "socket": "process",
                     "signal": "process", "shutil": "writes", "tempfile": "writes", "pathlib": "writes", "io": "writes",
                     "_io": "writes", "fcntl": "writes", "mmap": "writes", "builtins": "aliases",
                     "importlib": "imports", "runpy": "imports"}
# Modules a chain is resolved against even when the file may not import them
# (the import itself is refused): os's own implementation module included.
RESOLVABLE = {"os", "posix", "nt", "sys"} | set(PRIMITIVE_MODULES)
DUNDERS_ALLOWED = {"__file__", "__name__", "__init__"}
MISSING = object()


def primitive_objects(rs, extra=()):
    """{id(object): (canonical name, rule)} of every single primitive a
    resolution can land on (the modules above are primitives whole)."""
    import argparse
    import builtins
    table = {}
    for name in sorted(rs["PROCESS_OS"]):
        if hasattr(os, name):
            table[id(getattr(os, name))] = (f"os.{name}", "process")
    for name in sorted(rs["WRITE_OS"] | {"open", "fdopen"}):
        if hasattr(os, name):
            table.setdefault(id(getattr(os, name)), (f"os.{name}", "writes"))
    table[id(builtins.open)] = ("open", "writes")
    for name in ("eval", "exec", "compile", "__import__", "getattr", "setattr", "delattr", "globals", "locals",
                 "vars", "breakpoint"):
        table[id(getattr(builtins, name))] = (name, "aliases")
    table[id(argparse.FileType)] = ("argparse.FileType", "writes")
    table[id(sys.modules)] = ("sys.modules", "aliases")
    table[id(sys._getframe)] = ("sys._getframe", "aliases")
    for name, value, rule in extra:
        table[id(value)] = (name, rule)
    return table


def import_bindings(tree):
    """{name: the dotted module path or name it binds} for every import in
    the file, at any depth."""
    bound = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.asname:
                    bound[alias.asname] = alias.name
                else:
                    bound[alias.name.split(".")[0]] = alias.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom) and not node.level and node.module and node.module != "__future__":
            for alias in node.names:
                if alias.name != "*":
                    bound[alias.asname or alias.name] = f"{node.module}.{alias.name}"
    return bound


def attribute_chain(node):
    """(the expression under an attribute chain, its attribute names)."""
    chain = []
    while isinstance(node, ast.Attribute):
        chain.insert(0, node.attr)
        node = node.value
    return node, chain


def dunder(name):
    return name.startswith("__") and name.endswith("__")


class AliasScan(ast.NodeVisitor):
    """One file's alias-proof primitive scan. findings: (rule, what) with rule
    process, writes, imports, or aliases. allowed: {scope: canonical names
    that scope may reference}; entry: the writer entry's own allowances
    (os.write to fd 1 or 2, importlib.import_module of loopauth)."""

    def __init__(self, tree, rs, imports, allowed, entry=False, extra=()):
        self.imports, self.allowed, self.entry = imports, allowed, entry
        self.read_flags = set(rs["READ_FLAGS"])
        self.bound = import_bindings(tree)
        self.primitives = primitive_objects(rs, extra)
        self.dynamic = set(rs["DYNAMIC_ATTRIBUTE"])
        self.namespace = set(rs["NAMESPACE_NAMES"]) | {"__import__", "breakpoint"}
        self.frames = set(rs["FRAME_ATTRIBUTES"])
        self.process_names = set(rs["PROCESS_OS"]) | {"Popen", "check_output", "check_call", "getoutput",
                                                      "getstatusoutput"}
        self.write_names = set(rs["WRITE_OS"]) | {"fdopen", "FileType", "rmtree"}
        self.module_names = set(PRIMITIVE_MODULES) | {"os", "posix", "nt", "sys", "modules", "_getframe"}
        self.receivers = {id(n.value) for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
        self.calls = {id(n.func): n for n in ast.walk(tree) if isinstance(n, ast.Call)}
        self.stack, self.findings = [], []

    def where(self):
        return ".".join(self.stack) or "<module>"

    def flag(self, rule, node, what):
        self.findings.append((rule, f"{what} at {self.where()}:{getattr(node, 'lineno', 0)}"))

    def visit_FunctionDef(self, node):
        self.stack.append(node.name)
        self.generic_visit(node)
        self.stack.pop()

    visit_AsyncFunctionDef = visit_FunctionDef
    visit_ClassDef = visit_FunctionDef

    def visit_Import(self, node):
        for alias in node.names:
            if alias.name.split(".")[0] not in self.imports:
                self.flag("imports", node, f"import {alias.name} (outside the frozen imports "
                                           f"{sorted(self.imports - {'__future__'})})")
            if alias.asname:
                self.flag("aliases", node, f"module alias: import {alias.name} as {alias.asname}")
        self.generic_visit(node)

    def visit_ImportFrom(self, node):
        names = ", ".join(a.name + (f" as {a.asname}" if a.asname else "") for a in node.names)
        if node.level:
            self.flag("imports", node, f"a relative import: from {'.' * node.level}{node.module or ''} import {names}")
        elif node.module != "__future__":
            if (node.module or "").split(".")[0] not in self.imports:
                self.flag("imports", node, f"from {node.module} import {names} (outside the frozen imports)")
            self.flag("aliases", node, f"module alias: from {node.module} import {names} binds a library name bare")
        self.generic_visit(node)

    def visit_Name(self, node):
        if isinstance(node.ctx, ast.Load):
            if node.id in self.dynamic:
                self.flag("aliases", node, f"dynamic attribute access: {node.id}")
            elif node.id in self.namespace or (dunder(node.id) and node.id not in DUNDERS_ALLOWED):
                self.flag("aliases", node, f"a namespace lookup: {node.id}")
            elif node.id == "open" and node.id not in self.bound:
                self.primitive(node, "open", "writes", "open")
            if node.id in self.bound and id(node) not in self.receivers:
                self.resolve(node, node, [])
        elif node.id in self.bound:
            self.flag("aliases", node, f"module alias: the import-bound name {node.id} rebound")
        self.generic_visit(node)

    def visit_Call(self, node):
        if isinstance(node.func, (ast.Call, ast.Lambda, ast.Subscript)):
            self.flag("aliases", node, "dynamic callable construction")
        self.generic_visit(node)

    def visit_arg(self, node):
        if node.arg in self.bound:
            self.flag("aliases", node, f"module alias: a parameter shadows the import-bound name {node.arg}")
        self.generic_visit(node)

    def visit_Attribute(self, node):
        if node.attr in self.dynamic:
            self.flag("aliases", node, f"dynamic attribute access: .{node.attr}")
        if (dunder(node.attr) and node.attr not in DUNDERS_ALLOWED) or node.attr in self.frames:
            self.flag("aliases", node, f"a namespace lookup: .{node.attr}")
        if id(node) not in self.receivers:  # the outermost attribute of its chain
            base, chain = attribute_chain(node)
            if isinstance(base, ast.Name) and base.id in self.bound:
                self.resolve(node, base, chain)
            else:
                for attr in chain:
                    rule = "process" if attr in self.process_names or PRIMITIVE_MODULES.get(attr) == "process" else \
                        "writes" if attr in self.write_names or PRIMITIVE_MODULES.get(attr) == "writes" else \
                        "aliases" if attr in self.module_names else None
                    if rule is not None:
                        self.flag(rule, node, f".{attr} reached through {ast.unparse(base)[:60]} (a primitive or "
                                              "a module under a receiver no import binds)")
        self.generic_visit(node)

    def resolve(self, node, base, chain):
        """Resolve base.chain (base an import-bound name) against the real
        modules, and judge what it lands on."""
        target = self.bound[base.id]
        parts = target.split(".") + chain
        imported = len(target.split("."))  # the parts the import statement itself names
        written = ".".join([base.id] + chain)
        if parts[0] not in RESOLVABLE | self.imports:
            return  # an import outside the frozen list: refused where it is imported
        try:
            value = importlib.import_module(parts[0])
        except ImportError:
            self.flag("aliases", node, f"{written} does not resolve (no module {parts[0]})")
            return
        dotted = parts[0]
        for index in range(1, len(parts) + 1):
            if isinstance(value, types.ModuleType):
                root = value.__name__.split(".")[0]
                if root in PRIMITIVE_MODULES:
                    if index == len(parts) and id(node) not in self.receivers:
                        self.flag("aliases", node, f"module alias: module {root} used as a value, not as "
                                                   f"{root}.<name> (written {written})")
                    self.primitive(node, ".".join([root] + parts[index:]), PRIMITIVE_MODULES[root], written)
                    return
            if index == len(parts):
                break
            part = parts[index]
            following = getattr(value, part, MISSING)
            if following is MISSING and index < imported:
                try:
                    following = importlib.import_module(".".join(parts[:index + 1]))
                except ImportError:
                    following = MISSING
            dotted = f"{dotted}.{part}"
            if following is MISSING:
                self.flag("aliases", node, f"{written} does not resolve ({dotted})")
                return
            if isinstance(following, types.ModuleType) and index >= imported and dotted != "os.path":
                self.flag("aliases", node, f"module alias: {dotted} is a module reached through another module "
                                           f"(written {written})")
            hit = self.primitives.get(id(following))
            if hit is not None:
                # a primitive, at the end of the chain or on the way (sys.modules.get, os.write.__call__)
                self.primitive(node, hit[0], hit[1], written, direct=index == len(parts) - 1)
                return
            value = following
        if isinstance(value, types.ModuleType) and id(node) not in self.receivers:
            self.flag("aliases", node, f"module alias: module {dotted} used as a value, not as {dotted}.<name>"
                                       + ("" if written == dotted else f" (written {written})"))

    def primitive(self, node, canonical, rule, written, direct=True):
        """A reference to a primitive: allowed in its scope, or in its one
        allowed call form, or refused (named by what it is)."""
        if canonical in self.allowed.get(self.where(), ()):
            return
        call = self.calls.get(id(node)) if direct else None
        spelled = "" if written == canonical else f" (written {written})"
        if call is not None:
            if canonical == "os.write" and self.entry and call.args and constant(call.args[0]) in (1, 2):
                return
            if canonical == "os.open":
                flags = call.args[1] if len(call.args) > 1 else keyword(call, "flags")
                names = {n.attr for n in ast.walk(flags) if isinstance(n, ast.Attribute)} if flags else set()
                other = [n for n in ast.walk(flags) if isinstance(n, (ast.Constant, ast.Name))
                         and not (isinstance(n, ast.Name) and self.bound.get(n.id) == "os")] if flags else []
                if names and not names - self.read_flags and not other:
                    return
                self.flag("writes", node, f"os.open for writing{spelled}")
                return
            if canonical == "open":
                if any(isinstance(arg, ast.Starred) for arg in call.args) or any(kw.arg is None for kw in call.keywords):
                    self.flag("writes", node, f"open() with indirect arguments{spelled}")
                    return
                mode = call.args[1] if len(call.args) > 1 else keyword(call, "mode")
                if mode is None or (isinstance(constant(mode), str) and not set(constant(mode)) & set("wax+")):
                    return
                self.flag("writes", node, f"open() for writing{spelled}")
                return
            if canonical == "importlib.import_module" and self.entry:
                target = call.args[0] if call.args else None
                text = constant(target) if isinstance(target, ast.Constant) else (
                    constant(target.values[0]) if isinstance(target, ast.JoinedStr) and target.values else None)
                if isinstance(text, str) and (text == "loopauth" or text.startswith("loopauth.")):
                    return
        self.flag(rule, node, f"{canonical}{spelled}" + ("" if call is not None else
                                                         " taken as a value (an indirect call)"))


def entry_problems(trees, rs):
    """scripts/loop-authority's Python (loop-authority.py, and any heredoc
    the wrapper embeds): the alias-proof scan, allowing its frozen imports,
    os.write to fd 1 or 2, and importlib.import_module of loopauth only."""
    problems = []
    for module, tree in trees.items():
        if module.startswith("loop-authority"):
            scan = AliasScan(tree, rs, ENTRY_IMPORTS, {}, entry=True)
            scan.visit(tree)
            problems += [f"{rule}: {what}" for rule, what in scan.findings]
    return problems


# ---------------------------------------------------------------------------
# F1's freeze of the writer entry's loopauth accesses (ENTRY_MODULE_ACCESS).
# The entry holds the store, the registry, and every other loopauth module
# only as module values: load_loopauth()'s dict, a constant subscript naming
# a loopauth module (mods["store"], under any receiver at all),
# importlib.import_module of loopauth, and every name, local function
# parameter, and local function return bound to one of those. Each value is
# followed through those aliases, and every use of one is judged: an
# attribute read the table lists for its module, or a binding the scan
# follows; anything else is refused -- an attribute outside the table, one
# assigned or deleted, a chain through a module attribute, the module passed
# to any other callable, stored, iterated, compared, or called, the dict
# used other than by a constant subscript, a name or parameter bound to a
# module bound to anything else, a local function taking one used as a
# value. And, whatever the receiver (a value no static reading can follow
# included), the entry names no private attribute (_new, _grant,
# _fs_create, ...), no attribute named like a loopauth module
# (mods["recover"].store), and nothing any loopauth module defines that the
# table does not list (ENTRY_SHARED_NAMES aside).
# ---------------------------------------------------------------------------

MODULE_DICT = "the dict of loopauth modules"
SCOPE_NODES = (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef, ast.ListComp,
               ast.SetComp, ast.DictComp, ast.GeneratorExp)


def loopauth_names():
    return {name[:-3] for name in os.listdir(os.path.join(LIB, "loopauth"))
            if name.endswith(".py") and name != "__init__.py"}


def entry_refused_names():
    """Every non-dunder name a loopauth module binds (its functions, classes,
    constants, and the modules it imports) that the table lists for no
    module, the shared names aside."""
    names = set()
    for name in sorted(loopauth_names()):
        names |= {key for key in vars(importlib.import_module(f"loopauth.{name}")) if not dunder(key)}
    return names - set().union(*ENTRY_MODULE_ACCESS.values()) - ENTRY_SHARED_NAMES


class EntryModules:
    """One entry file's loopauth module values, followed, and every use of
    one judged. findings: [(module or None, what)]; accesses: {module:
    {attribute read}}; loaded: the names of load_loopauth()'s dict."""

    def __init__(self, tree, modules, refused):
        self.tree, self.modules, self.refused = tree, set(modules), set(refused)
        self.parent = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        self.functions = {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
        self.bound, self.declared = {}, {}
        for node in ast.walk(tree):
            for name, scope in self.binds(node):
                self.bound.setdefault(id(scope), set()).add(name)
            if isinstance(node, (ast.Global, ast.Nonlocal)):
                for name in node.names:
                    self.declared.setdefault(name, []).append(node)
        self.kinds, self.returns, self.flows, self.target_kind = {}, {}, set(), {}
        self.findings, self.accesses, self.loaded = [], {}, None
        self.propagate()
        self.judge()

    # -- scopes and names
    def scope_of(self, node):
        current = self.parent.get(node)
        while current is not None and not isinstance(current, SCOPE_NODES):
            current = self.parent.get(current)
        return current

    def binds(self, node):
        """(name, scope) for every name the node binds."""
        if isinstance(node, ast.Name) and not isinstance(node.ctx, ast.Load):
            return [(node.id, self.scope_of(node))]
        if isinstance(node, ast.arg):
            return [(node.arg, self.scope_of(node))]
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            return [(node.name, self.scope_of(node))]
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            return [((a.asname or a.name).split(".")[0], self.scope_of(node)) for a in node.names]
        if isinstance(node, ast.ExceptHandler) and node.name:
            return [(node.name, self.scope_of(node))]
        name = getattr(node, "name", None) if isinstance(node, (ast.MatchAs, ast.MatchStar)) else \
            getattr(node, "rest", None) if isinstance(node, ast.MatchMapping) else None
        return [(name, self.scope_of(node))] if name else []

    def resolve(self, node):
        """The scope a loaded name resolves to (None: a builtin)."""
        if node.id in self.declared:
            return self.tree
        scope = self.scope_of(node)
        while scope is not None:
            if node.id in self.bound.get(id(scope), ()):
                return scope
            scope = self.scope_of(scope)
        return None

    def where(self, node):
        names, scope = [], self.scope_of(node)
        while scope is not None and scope is not self.tree:
            names.insert(0, getattr(scope, "name", type(scope).__name__.lower()))
            scope = self.scope_of(scope)
        return f"{'.'.join(names) or '<module>'}:{getattr(node, 'lineno', 0)}"

    def flag(self, module, node, what):
        finding = (module, f"{what} at {self.where(node)}")
        if finding not in self.findings:
            self.findings.append(finding)

    # -- module values
    def import_target(self, call):
        if ast.unparse(call.func) != "importlib.import_module" or len(call.args) != 1 or call.keywords:
            return None
        text = constant(call.args[0])
        if text == "loopauth":
            return "loopauth"
        if isinstance(text, str) and text.startswith("loopauth.") and text[len("loopauth."):] in self.modules:
            return text[len("loopauth."):]
        return None

    def loader(self, node):
        """load_loopauth()'s one form -- {name: importlib.import_module(
        f"loopauth.{name}") for name in (<constant module names>)} -- its
        names, or None."""
        if not isinstance(node, ast.DictComp) or len(node.generators) != 1 or not isinstance(node.key, ast.Name):
            return None
        loop = node.generators[0]
        if loop.ifs or loop.is_async or not isinstance(loop.target, ast.Name) or loop.target.id != node.key.id \
                or not isinstance(loop.iter, ast.Tuple) \
                or ast.unparse(node.value) != f"importlib.import_module(f'loopauth.{{{node.key.id}}}')":
            return None
        names = tuple(constant(e) for e in loop.iter.elts)
        return names if all(isinstance(n, str) and n in self.modules for n in names) else None

    def local_call(self, call):
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id in self.functions \
                and self.resolve(call.func) is self.tree:
            return self.functions[call.func.id]
        return None

    def kind(self, node):
        """The loopauth module (or MODULE_DICT) an expression is, or None."""
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load):
            key = constant(node.slice)
            return key if isinstance(key, str) and key in self.modules else None
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            scope = self.resolve(node)
            return self.kinds.get((id(scope), node.id)) if scope is not None else None
        if isinstance(node, ast.Call):
            target = self.import_target(node)
            if target is not None:
                return target
            function = self.local_call(node)
            return self.returns.get(function.name) if function is not None else None
        if self.loader(node) is not None:
            return MODULE_DICT
        return None

    def pairs(self, node):
        """(binding key, the target node or None, the value bound) for every
        binding the scan follows: an assignment to a name (a tuple unpacked
        element by element), and a local function's parameter from each
        call."""
        def match(target, value):
            if isinstance(target, ast.Name):
                scope = self.tree if target.id in self.declared else self.scope_of(target)
                yield (id(scope), target.id), target, value
            elif isinstance(target, (ast.Tuple, ast.List)) and isinstance(value, (ast.Tuple, ast.List)) \
                    and len(target.elts) == len(value.elts) \
                    and not any(isinstance(e, ast.Starred) for e in target.elts + value.elts):
                for inner, element in zip(target.elts, value.elts):
                    yield from match(inner, element)

        if isinstance(node, ast.Assign):
            for target in node.targets:
                yield from match(target, node.value)
        elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and node.value is not None:
            yield from match(node.target, node.value)
        function = self.local_call(node)
        if function is not None:
            params = function.args.posonlyargs + function.args.args
            for position, value in enumerate(node.args):
                if not isinstance(value, ast.Starred) and position < len(params):
                    yield (id(function), params[position].arg), None, value
            named = {a.arg for a in params + function.args.kwonlyargs}
            for item in node.keywords:
                if item.arg in named:
                    yield (id(function), item.arg), None, item.value

    def propagate(self):
        changed = True
        while changed:
            changed = False
            for node in ast.walk(self.tree):
                bindings = list(self.pairs(node))
                if isinstance(node, ast.Return) and node.value is not None:
                    function = self.scope_of(node)
                    if isinstance(function, ast.FunctionDef) and self.functions.get(function.name) is function:
                        bindings.append((("return", function.name), None, node.value))
                for key, target, value in bindings:
                    kind = self.kind(value)
                    if kind is None:
                        continue
                    self.flows.add(id(value))
                    if target is not None:
                        self.target_kind[id(target)] = kind
                    table = self.returns if key[0] == "return" else self.kinds
                    name = key[1] if key[0] == "return" else key
                    if name not in table:
                        table[name] = kind
                        changed = True
                    elif table[name] != kind:
                        self.flag(None, value, f"{key[1]} is bound to loopauth module {table[name]} and to {kind}")

    # -- every use judged
    def judge(self):
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Call) and ast.unparse(node.func).endswith("import_module") \
                    and self.import_target(node) is None \
                    and not (self.loader(self.parent.get(node)) is not None and self.parent[node].value is node):
                self.flag(None, node, f"a module loaded in a form the scan cannot follow: {ast.unparse(node)[:80]}")
            if isinstance(node, ast.DictComp) and self.loader(node) is not None:
                self.loaded = self.loader(node) if self.loaded is None else self.loaded + self.loader(node)
            kind = self.kind(node) if isinstance(node, ast.expr) else None
            if kind is not None:
                self.use(node, kind)
            elif isinstance(node, ast.Attribute) and self.kind(node.value) is None:
                self.any_receiver(node)  # a module receiver is judged by its table instead
        self.bindings()

    def exception_type(self, node):
        parent = self.parent.get(node)
        return (isinstance(parent, ast.ExceptHandler) and parent.type is node and
                ast.unparse(node) in {"store.anchor.Unreachable", "store.anchor.AnchorError"})

    def use(self, node, kind):
        parent = self.parent.get(node)
        written = ast.unparse(parent)[:80] if parent is not None else ""
        if id(node) in self.flows:
            return  # bound to a name, a local function's parameter, or its return: followed
        if isinstance(parent, ast.Attribute) and parent.value is node:
            if kind == MODULE_DICT:
                self.flag(None, parent, f"{MODULE_DICT} used other than by a constant subscript: {written}")
                return
            above = self.parent.get(parent)
            if kind == "store" and parent.attr == "anchor" and isinstance(above, ast.Attribute) and self.exception_type(above):
                self.accesses.setdefault(kind, set()).add("anchor." + above.attr)
                return
            module = None if kind == "loopauth" else kind
            spelled = "" if written == f"{kind}.{parent.attr}" else f" (written {written})"
            if not isinstance(parent.ctx, ast.Load):
                self.flag(module, parent, f"{kind}.{parent.attr} assigned or deleted{spelled}")
            else:
                self.accesses.setdefault(kind, set()).add(parent.attr)
                if parent.attr not in ENTRY_MODULE_ACCESS.get(kind, ()):
                    self.flag(module, parent, f"{kind}.{parent.attr}{spelled}: not among the entry's frozen {kind} "
                                              "accesses")
                above = self.parent.get(parent)
                if isinstance(above, ast.Attribute) and above.value is parent:
                    self.flag(module, above, f"a chain through {kind}.{parent.attr}: {ast.unparse(above)[:80]}")
            return
        if isinstance(parent, ast.Subscript) and parent.value is node and kind == MODULE_DICT \
                and isinstance(parent.ctx, ast.Load) and constant(parent.slice) in self.modules:
            return  # mods["store"]: itself the module, judged as one
        module = None if kind in (MODULE_DICT, "loopauth") else kind
        self.flag(module, node, f"{'the ' + kind if kind == MODULE_DICT else 'loopauth module ' + kind} used as a "
                                f"value the scan cannot follow ({type(parent).__name__}: {written})")

    def any_receiver(self, node):
        if self.exception_type(node):
            return
        receiver = ast.unparse(node.value)[:60]
        if node.attr.startswith("_") and not dunder(node.attr):
            self.flag(None, node, f".{node.attr} under {receiver}: a private attribute, whatever the receiver")
        elif node.attr in self.modules:
            self.flag(node.attr, node, f".{node.attr} under {receiver}: a loopauth module reached through "
                                       "another value")
        elif node.attr in self.refused:
            self.flag(None, node, f".{node.attr} under {receiver}: named like something a loopauth module defines "
                                  "that the entry's frozen table lists for no module, whatever the receiver")

    def bindings(self):
        """A name or parameter bound to a module is bound to nothing else,
        and a local function taking a module is only ever called."""
        tracked = {key: kind for key, kind in self.kinds.items()}
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Name) and not isinstance(node.ctx, ast.Load):
                scope = self.tree if node.id in self.declared else self.scope_of(node)
                kind = tracked.get((id(scope), node.id))
                if kind is not None and self.target_kind.get(id(node)) != kind:
                    self.flag(None if kind == MODULE_DICT else kind, node,
                              f"{node.id}, bound to {kind}, rebound or deleted")
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                for name in node.names:
                    if any(key[1] == name for key in tracked):
                        self.flag(None, node, f"{name}, a name bound to a loopauth module, declared "
                                              f"{type(node).__name__.lower()}")
            else:
                for name, scope in self.binds(node) if not isinstance(node, ast.arg) else ():
                    kind = tracked.get((id(scope), name))
                    if kind is not None:
                        self.flag(None if kind == MODULE_DICT else kind, node,
                                  f"{name}, bound to {kind}, rebound by a {type(node).__name__}")
        for name, function in self.functions.items():
            params = function.args.posonlyargs + function.args.args + function.args.kwonlyargs
            taking = {p.arg: self.kinds[(id(function), p.arg)] for p in params if (id(function), p.arg) in self.kinds}
            if not taking:
                continue
            for node in ast.walk(self.tree):
                if isinstance(node, ast.Name) and node.id == name and self.resolve(node) is self.tree \
                        and not (isinstance(self.parent.get(node), ast.Call) and self.parent[node].func is node):
                    self.flag(None, node, f"{name}, a local function taking a loopauth module, used as a value")
                elif self.local_call(node) is function:
                    given = {key[1]: self.kind(value) for key, _t, value in self.pairs(node)}
                    for param, kind in taking.items():
                        if given.get(param) != kind:
                            self.flag(None if kind == MODULE_DICT else kind, node,
                                      f"{name}'s parameter {param} (bound to {kind}) given something else")


def entry_modules(trees):
    """{module: EntryModules} for loop-authority.py and any heredoc the
    wrapper embeds."""
    modules, refused = loopauth_names(), entry_refused_names()
    return {module: EntryModules(tree, modules, refused) for module, tree in trees.items()
            if module.startswith("loop-authority")}


def entry_module_problems(trees):
    return [what for scan in entry_modules(trees).values() for _module, what in scan.findings]


def f1_findings(root, rs, registry):
    """Every F1 structural finding for a tree (the live one or a planted copy)."""
    lib = os.path.join(root, "lib")
    trees, errors = parse_modules(writer_sources(root))
    index = Index(trees)
    found = [("parse", error) for error in errors]
    importers = authority_importers(root)
    if importers != AUTHORITY_IMPORTERS:
        found.append(("entry importer inventory", sorted(importers ^ AUTHORITY_IMPORTERS)))
    found += [("p2 s7 scan", f"{where}:{line}: {what}") for where, line, what in rs["scan"](lib)]
    direct, paths, _reached = rs["read_only_scan"](lib)
    found += [("0a.3 read-only rules", f"{m}:{line}: {what}") for m, line, what in direct]
    found += [("0a.3 call graph", path) for path in paths]
    problems, _pairs = sink_problems(index)
    found += [("sink -> transaction driver map", problem) for problem in problems]
    found += [("token minting", problem) for problem in minter_problems(index, registry)]
    found += [("entry point", problem) for problem in entry_problems(trees, rs)]
    found += [("entry loopauth access", problem) for problem in entry_module_problems(trees)]
    return found


def planted_copy(name, edits):
    """A copy of lib/ and scripts/loop-authority(.py) with code appended to
    (or, given a pair, replaced in) the named files."""
    root = os.path.join(TMP, "plant", name)
    for folder in ("lib", "scripts", "backends"):
        shutil.copytree(os.path.join(SKILL, folder), os.path.join(root, folder), ignore=shutil.ignore_patterns("__pycache__"))
    for relative, code in edits:
        path = os.path.join(root, relative)
        if isinstance(code, tuple):
            text = read_text(path)
            if code[0] not in text:
                raise RuntimeError(f"{relative}: the text to replace is gone: {code[0]!r}")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text.replace(code[0], code[1], 1))
        else:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("\n\n" + code)
    return root


ENTRY_PLANT = ("def _bypass_marker(mods, store_id):\n"
               "    return mods[\"store\"].write_quarantine(None, store_id=store_id, data=b\"x\")\n")
# Primitives planted in loop-authority.py under another spelling: (label,
# code, the text the entry-point finding must name).
ENTRY_ALIAS_PLANTS = (
    ("import os as o; o.system(...) (an import rename)",
     "import os as o\n\n\ndef _bypass_alias(command):\n    return o.system(command)\n", "os.system (written o.system)"),
    ("_SYSTEM = os.system, called later (an indirect call through a value)",
     "_SYSTEM = os.system\n\n\ndef _bypass_indirect(command):\n    return _SYSTEM(command)\n",
     "os.system taken as a value"),
    ("os.path.os.system(...) (a module reached through another module)",
     "def _bypass_chain(command):\n    return os.path.os.system(command)\n", "os.system (written os.path.os.system)"),
    ("import posix; posix.system(...) (os.system under its implementation module's name)",
     "import posix\n\n\ndef _bypass_posix(command):\n    return posix.system(command)\n",
     "os.system (written posix.system)"),
    ("getattr(os, \"sys\" + \"tem\")(...) (dynamic attribute access)",
     "def _bypass_getattr(command):\n    return getattr(os, \"sys\" + \"tem\")(command)\n",
     "dynamic attribute access: getattr"),
    ("(lambda m: m.system(...))(os) (a module passed as a value)",
     "def _bypass_value(command):\n    return (lambda m: m.system(command))(os)\n", "module os used as a value"),
    ("mods[\"tools\"].subprocess.run(...) (a process module reached through a loopauth module)",
     "def _bypass_through(mods, argv):\n    return mods[\"tools\"].subprocess.run(argv)\n", ".subprocess reached"),
    ("write = os.write; write(3, ...) (a write to another fd through a value)",
     "def _bypass_write(data):\n    write = os.write\n    return write(3, data)\n", "os.write taken as a value"),
)
# The same in the independent verifier: (label, the rule that must fire, code).
VERIFIER_ALIAS_PLANTS = (
    ("import subprocess as sp; sp.run(...) (an import rename)", "process",
     "import subprocess as sp\n\n\ndef _bypass_alias(remote):\n    return sp.run([\"git\", \"push\", remote])\n"),
    ("_RUN = subprocess.run outside the runner, called later (an indirect call)", "process",
     "_RUN = subprocess.run\n\n\ndef _bypass_indirect(remote):\n    return _RUN([\"git\", \"push\", remote])\n"),
    ("getattr(subprocess, \"run\")(...) (dynamic attribute access)", "aliases",
     "def _bypass_getattr(remote):\n    return getattr(subprocess, \"run\")([\"git\", \"push\", remote])\n"),
    ("runner = RUN.run; runner([... \"push\" ...]) (the runner taken as a value)", "argv",
     "def _bypass_runner(remote):\n    runner = RUN.run\n    return runner([RUN.binary(\"git\"), \"push\", remote], git=True)\n"),
    ("Runner.run(RUN, [... \"push\" ...]) (the runner through its class)", "argv",
     "def _bypass_class(remote):\n    return Runner.run(RUN, [RUN.binary(\"git\"), \"push\", remote], git=True)\n"),
    ("runner = RUN; runner.run([... \"push\" ...]) (the runner under another name)", "argv",
     "def _bypass_rebind(remote):\n    runner = RUN\n    return runner.run([runner.binary(\"git\"), \"push\", remote], "
     "git=True)\n"),
    ("os.path.os.unlink(...) (a write through a module reached through another module)", "writes",
     "def _bypass_chain(path):\n    os.path.os.unlink(path)\n"),
    ("tree = shutil; tree.rmtree(...) (a module held as a value)", "aliases",
     "def _bypass_value(path):\n    tree = shutil\n    tree.rmtree(path)\n"),
)
REVIEW_OPEN_PLANTS = (
    ("starred open arguments", 'def _b(path):\n    print("x", file=open(*[path, "w"]))\n'),
    ("double-starred open mode", 'def _b(path):\n    print("x", file=open(path, **{"mode": "w"}))\n'),
    ("dynamic stream type construction", 'def _b(path):\n    type(sys.stdout)(type(sys.stdout.buffer.raw)(path, "w"))\n'),
)
ENTRY_ALIAS_PLANTS += tuple((label, code, "dynamic" if "type" in label else "open") for label, code in REVIEW_OPEN_PLANTS)
VERIFIER_ALIAS_PLANTS += tuple((label, "aliases" if "type" in label else "writes", code) for label, code in REVIEW_OPEN_PLANTS)

# Unlisted commands planted inside the runner itself, the one scope the alias
# scan allows subprocess.run in: (label, the rules that must fire, (the text
# replaced, its replacement)).
RUNNER_DEF = '    def run(self, argv: list[str], *, git: bool, stdin: bytes = b"") -> subprocess.CompletedProcess:\n'
RUNNER_RETURN = "            return subprocess.run(argv, input=stdin,"
RUNNER_PLANTS = (
    ("an extra subprocess.run of git push inside Runner.run, guarded by an SSH or HTTPS remote (the transports "
     "whose commands no wrapper fixture records)", ("runner", "argv"),
     (RUNNER_DEF, RUNNER_DEF
      + '        if git and self.remote is not None and self.remote["transport"] in ("ssh", "https"):\n'
        '            subprocess.run([self.binary("git"), "-C", self.repo, "push", "--force", self.remote["url"],\n'
        '                            "HEAD:refs/olddonkey-loop/anchor"], env=self.env(git), cwd=self.temp,\n'
        '                           check=False)\n')),
    ("a second process start folded into Runner.run's own return statement", ("runner", "argv"),
     (RUNNER_RETURN, '            return (self.remote is not None and self.remote["transport"] == "ssh"\n'
                     '                    and subprocess.run([self.binary("git"), "push", self.remote["url"]], check=False)) \\\n'
                     '                or subprocess.run(argv, input=stdin,')),
)
# Bypasses of the entry's frozen loopauth accesses, planted in
# loop-authority.py: (label, edits, the texts the entry-loopauth-access
# findings must each name). The first is the complete bypass -- a forged open
# token, a permit granted by hand, and the file helper consuming it --
# wired into main, and run through the planted entry (mode_static).
FORGED_ACTIVE = b'{"forged":"a token no row minted"}\n'
LOAD_LINE = "    mods = load_loopauth()\n"
EXIT_LINE = "\n\nsys.exit(main(sys.argv[1:]))"
FORGE_ACTIVE = '''def _forge_active(mods, data):
    """Authority/active written through a forged open token: the store's own
    constructor and registration, a permit granted by hand, and the file
    helper consuming it."""
    s = mods["store"]
    s.ensure_layout()
    token = s._new(s.Token("store-quarantine", "recovery", s.sha256(data)))
    target = s.path(s.ACTIVE)
    s._grant(token, "create", target, s.sha256(data))
    s._fs_create(token, target, data)
'''
FORGE_NEEDLES = ("store._new", "store.Token", "store._grant", "store._fs_create")


def wired(call, definition):
    """Edits of loop-authority.py: a function defined before the entry runs
    main, and called by main right after it loads the loopauth modules."""
    return [("scripts/loop-authority.py", (LOAD_LINE, LOAD_LINE + f"    {call}\n")),
            ("scripts/loop-authority.py", (EXIT_LINE, "\n\n" + definition + EXIT_LINE))]


ENTRY_MODULE_PLANTS = (
    ("the complete bypass, wired into main: s = mods[\"store\"]; s._fs_create(s._new(s.Token(...)), ...) after "
     "s._grant(...)", wired(f"_forge_active(mods, {FORGED_ACTIVE!r})", FORGE_ACTIVE), FORGE_NEEDLES),
    ("the same on mods[\"store\"] itself, no local name, in a function nothing calls",
     [("scripts/loop-authority.py",
       "def _forge_direct(mods, data):\n"
       "    token = mods[\"store\"]._new(mods[\"store\"].Token(\"store-quarantine\", \"recovery\", \"x\"))\n"
       "    mods[\"store\"]._grant(token, \"create\", mods[\"store\"].path(\"active\"), mods[\"store\"].sha256(data))\n"
       "    mods[\"store\"]._fs_create(token, mods[\"store\"].path(\"active\"), data)\n")], FORGE_NEEDLES),
    ("the same through a local function's parameter: _forge_with(mods[\"store\"], data)",
     [("scripts/loop-authority.py",
       "def _forge_with(s, data):\n"
       "    token = s._new(s.Token(\"store-quarantine\", \"recovery\", \"x\"))\n"
       "    s._grant(token, \"create\", s.path(\"active\"), s.sha256(data))\n"
       "    s._fs_create(token, s.path(\"active\"), data)\n\n\n"
       "def _forge_param(mods, data):\n    return _forge_with(mods[\"store\"], data)\n")], FORGE_NEEDLES),
    ("the store module reached through another loopauth module: s = mods[\"recover\"].store",
     [("scripts/loop-authority.py",
       "def _forge_through(mods, data):\n"
       "    s = mods[\"recover\"].store\n"
       "    token = s._new(s.Token(\"store-quarantine\", \"recovery\", \"x\"))\n"
       "    s._fs_create(token, s.path(\"active\"), data)\n")],
     ("recover.store", "._new under s", ".Token under s", "._fs_create under s")),
    ("a module taken from the dict other than by a constant subscript (mods.get), wired into main",
     wired("_forge_get(mods)", "def _forge_get(mods):\n    s = mods.get(\"store\")\n    s.ensure_layout()\n"
                               "    return s.begin(\"epoch-rotation\", {\"kind\": \"operator-tty\"})\n"),
     ("the dict of loopauth modules used other than by a constant subscript", ".ensure_layout under s",
      ".begin under s")),
    ("the store module held in a container and used from it: box = [mods[\"store\"]]; box[0].ensure_layout()",
     [("scripts/loop-authority.py", "def _forge_box(mods):\n    box = [mods[\"store\"]]\n"
                                    "    return box[0].ensure_layout()\n")],
     ("loopauth module store used as a value", ".ensure_layout under box[0]")),
    ("the registry's validator replaced: mods[\"registry\"].validate = ...",
     [("scripts/loop-authority.py", "def _admit_all(mods):\n    mods[\"registry\"].validate = lambda *args: None\n")],
     ("registry.validate assigned or deleted",)),
)

# F4's planted generic hatch: seal and append whatever (allowed) type its
# caller names, with no row validator.
HATCH_PLANT = '''def seal_and_append(principal, record_type, body):
    """A generic hatch: seal and append a record of the caller's type."""
    plan = recover.recover()
    view = plan.view
    active = view.epochs[view.active_epoch]
    key_dir = _key_path(view.store_id, active.key_dir)
    scratch_pool = recover.Scratch()
    token = store.begin("epoch-rotation", principal)
    try:
        prepared = store.prepare_record(
            token, scratch=scratch_pool(), record_type=record_type, store_id=view.store_id,
            generation=view.generation, seq=view.L + 1, prev=view.records[-1].digest, body=body,
            signing_epoch=active.n, signing_key_dir=key_dir, signing_root_pub=active.root_pub,
            pointer_epoch=active.n, pointer_key_dir=key_dir, pointer_root_pub=active.root_pub,
            genesis_digest=view.genesis_digest, prev_generation=None,
            expected_parent=plan.remote_tip, offset=len(view.data), intent_extra={})
        store.write_intent(token, store_id=view.store_id, data=prepared.intent_bytes)
        store.append_frame(token, store_id=view.store_id, data=prepared.frame)
    finally:
        store.spend(token)
        scratch_pool.close()


def rotate_quietly(principal, body):
    return seal_and_append(principal, "epoch.rotated", body)
'''
SEAL_HELPER_PLANT = '''def seal_record(token, *, record_type, payload, key_dir):
    """A generic sealing helper: the caller names the type."""
    return seal(token, record_type=record_type, payload=payload, key_dir=key_dir)
'''
VALIDATE_ROTATION = 'registry.validate("epoch-rotation", _abstract(view, plan),'
UNVALIDATED_PLANT = (VALIDATE_ROTATION, 'print("epoch-rotation", _abstract(view, plan),')
# Each keeps the rotation driver's validator call, textually before the
# record, where it does not dominate the record: dead, swallowed, possibly
# suppressed, or never run.
DEAD_VALIDATOR_PLANTS = (
    ("the rotation driver's validator dead under `if False:`",
     [("lib/loopauth/ceremony.py", (VALIDATE_ROTATION, "if False:\n        " + VALIDATE_ROTATION))]),
    ("the rotation driver's validator in a try whose handler swallows its refusal",
     [("lib/loopauth/ceremony.py", (VALIDATE_ROTATION, "try:\n        " + VALIDATE_ROTATION)),
      ("lib/loopauth/ceremony.py", ('"anchor_position": view.L})\n    challenge(envelope)',
                                    '"anchor_position": view.L})\n    except registry.RowRefused:\n        pass\n'
                                    '    challenge(envelope)'))]),
    ("the rotation driver's validator under a with that may suppress its refusal",
     [("lib/loopauth/ceremony.py", (VALIDATE_ROTATION,
                                    "with contextlib.suppress(registry.RowRefused):\n        " + VALIDATE_ROTATION))]),
    ("the rotation driver's validator in a nested function never called",
     [("lib/loopauth/ceremony.py", (VALIDATE_ROTATION, "def _validate_later():\n        " + VALIDATE_ROTATION))]),
)
REBOUND_PLANT = '''class _Permissive:
    """A stand-in validator that admits anything."""

    @staticmethod
    def validate(*_args):
        return None


registry = _Permissive()
'''
# The same stand-ins planted in the entry: the registry's validate replaced,
# directly and through a local name, and another module's registry rebound.
ENTRY_VALIDATOR_PLANTS = (
    ("loop-authority.py replacing mods[\"registry\"].validate with a function admitting anything",
     [("scripts/loop-authority.py", "def _admit_all(mods):\n    mods[\"registry\"].validate = lambda *args: None\n")]),
    ("the same through a local name (r = mods[\"registry\"]; r.validate = ...), wired into main",
     wired("_admit_all(mods)", "def _admit_all(mods):\n    r = mods[\"registry\"]\n"
                               "    r.validate = lambda *args: None\n")),
    ("loop-authority.py rebinding ceremony's registry (mods[\"ceremony\"].registry = ...) to an object whose "
     "validate admits anything",
     [("scripts/loop-authority.py", REBOUND_PLANT.replace("\n\nregistry = _Permissive()\n", "") + "\n\n"
       "def _rebind(mods):\n    mods[\"ceremony\"].registry = _Permissive()\n")]),
)


def has_param(node, name):
    args = node.args
    return any(a.arg == name for a in args.posonlyargs + args.args + args.kwonlyargs)


def token_from_begin(node, call):
    token = call.args[0] if call.args else None
    if not isinstance(token, ast.Name):
        return False
    for assign in ast.walk(node):
        if isinstance(assign, ast.Assign) and isinstance(assign.value, ast.Call) \
                and callee(assign.value) == ("store", "begin") \
                and any(isinstance(t, ast.Name) and t.id == token.id for t in assign.targets):
            return True
    return False


def contains(node, target):
    return any(inner is target for inner in ast.walk(node))


def sub_blocks(statement):
    """(field, statement list) of every block directly inside a statement."""
    blocks = [(name, getattr(statement, name)) for name in ("body", "orelse", "finalbody")
              if isinstance(getattr(statement, name, None), list) and getattr(statement, name)
              and isinstance(getattr(statement, name)[0], ast.stmt)]
    blocks += [("handler", handler.body) for handler in getattr(statement, "handlers", None) or []]
    blocks += [("case", case.body) for case in getattr(statement, "cases", None) or []]
    return blocks


def validates(statement, rows):
    """The statement, completing normally, has run registry.validate of one of
    the rows, and a refusal by it would have left the statement: the call is
    the statement itself (an expression or an assignment's value); an if
    validates in both branches; a try validates in a body no handler can
    swallow, or in its finally. Nothing else counts -- a loop may run no
    iteration, a with's context manager may suppress the refusal, a nested
    def or class runs nothing, and a short-circuit or conditional expression
    may skip the call."""
    if isinstance(statement, (ast.Expr, ast.Assign, ast.AnnAssign)) and isinstance(statement.value, ast.Call):
        call = statement.value
        return callee(call) == ("registry", "validate") and bool(call.args) and constant(call.args[0]) in rows
    if isinstance(statement, ast.If):
        return block_validates(statement.body, rows) and block_validates(statement.orelse, rows)
    if isinstance(statement, ast.Try) or type(statement).__name__ == "TryStar":
        return (not statement.handlers and block_validates(statement.body, rows)) \
            or block_validates(statement.finalbody, rows)
    return False


def block_validates(block, rows):
    return any(validates(statement, rows) for statement in block)


def validator_dominates(function, call, rows):
    """registry.validate of the row dominates the call: on the chain of
    blocks from the driver's body down to the statement holding the call,
    some statement before it validates (validates()) -- in the call's own
    block or an enclosing one; a try's else block also counts its try body
    (the else runs only when that body completed without an exception); a
    handler or finally block does not."""
    block = function.body
    while True:
        index = next((i for i, statement in enumerate(block) if contains(statement, call)), None)
        if index is None:
            return False
        if block_validates(block[:index], rows):
            return True
        statement = block[index]
        inner = [(name, body) for name, body in sub_blocks(statement) if any(contains(s, call) for s in body)]
        if not inner:
            return False  # the call is in this statement's own expressions
        name, block = inner[0]
        if name == "orelse" and isinstance(statement, ast.Try) and block_validates(statement.body, rows):
            return True


def f4_findings(root):
    """F4's structural check: sealing, pointer sealing, and the frame append
    only from the transaction driver, the record type fixed by the row and
    validated first; no caller-supplied record type reaches a seal."""
    trees, errors = parse_modules(writer_sources(root))
    index = Index(trees)
    found = [("parse", error) for error in errors]
    primitives = {"prepare_record", "bind_record", "begin", "child"}
    for module, scope, node in index.nodes:
        name = node.attr if isinstance(node, ast.Attribute) else (node.id if module == "store" and isinstance(node, ast.Name) else None)
        if name in primitives and isinstance(getattr(node, "ctx", None), ast.Load) and id(node) not in index.call_funcs:
            found.append(("record primitive used as a value", f"{name} at {scope}:{node.lineno}"))
        if isinstance(node, ast.ImportFrom) and any(alias.name in primitives for alias in node.names):
            found.append(("record primitive used as a value", f"imported primitive at {scope}:{node.lineno}"))
    for driver in CEREMONY_DRIVERS:
        calls = [call for module, scope, call in index.calls if scope == driver and store_call(module, call, "prepare_record")]
        if len(calls) != 1:
            found.append(("missing or duplicate preparation", f"{driver}: {len(calls)} recognized prepare_record calls"))
    _problems, pairs = sink_problems(index)
    for sink in ("seal", "seal_pointer"):
        for caller in sorted(pairs.get(sink, set()) - {"store.prepare_record"}):
            found.append(("seal outside the write-protocol driver", f"{sink} called from {caller}"))
    for module, scope, call in index.calls:
        if not store_call(module, call, "prepare_record"):
            continue
        node = index.functions.get(scope)
        rows = begun_rows(node) if node is not None else set()
        record_type = keyword(call, "record_type")
        where = f"{scope}:{call.lineno}"
        if scope not in CEREMONY_DRIVERS:
            found.append(("a record prepared outside a ceremony row's driver", where))
        if not isinstance(constant(record_type), str):
            found.append(("a caller-supplied record type",
                          f"{where} passes record_type={ast.unparse(record_type) if record_type else None}"))
        elif len(rows) != 1 or ROW_TYPE.get(next(iter(rows))) != constant(record_type):
            found.append(("a record type not fixed by the row", f"{where} seals {constant(record_type)} under "
                                                                 f"{sorted(rows)}"))
        if node is None or not validator_dominates(node, call, rows):
            found.append(("no row validator before the record", f"{where} prepares a record on a path that has "
                                                                "not run registry.validate of its row, unconditionally "
                                                                "and with its refusal propagating"))
    for module, scope, call in index.calls:
        if store_call(module, call, "append_frame"):
            node = index.functions.get(scope)
            if scope not in CEREMONY_DRIVERS:
                found.append(("a frame append outside a ceremony row's driver", f"{scope}:{call.lineno}"))
            elif not token_from_begin(node, call):
                found.append(("a frame append with a token its driver did not begin", f"{scope}:{call.lineno}"))
        if store_call(module, call, "complete_delimiter") and scope != "recover._replay":
            found.append(("a delimiter completion outside replay-forward", f"{scope}:{call.lineno}"))
    typed = {qual for qual, node in index.functions.items() if qual.startswith("store.")
             and has_param(node, "record_type")}
    if typed != {"store.bind_record", "store.seal", "store.prepare_record"}:
        found.append(("store functions taking a record type", sorted(typed)))
    for module, scope, call in index.calls:
        owner, attr = callee(call)
        if module != "store" and attr in ("bind_record", "seal", "prepare_record") \
                and not isinstance(constant(keyword(call, "record_type")), str):
            found.append(("a caller's record type reaches a seal", f"store.{attr} at {scope}:{call.lineno}"))
    registry_names = {name for name in vars(importlib.import_module("loopauth.registry")) if not dunder(name)}
    for module, scan in entry_modules(trees).items():
        # The entry binds `registry` from load_loopauth()'s dict: the same
        # rule followed through every alias of the registry module (a
        # refusal the entry scan names for that module), and, whatever the
        # receiver, no `registry`, `validate`, or other registry name
        # assigned or deleted (mods["ceremony"].registry = ... included).
        found += [("the row validator rebound", f"the entry's registry module: {what}")
                  for kind, what in scan.findings if kind == "registry"]
        for node in ast.walk(trees[module]):
            at = f"{module}:{getattr(node, 'lineno', 0)}"
            if isinstance(node, ast.Attribute) and not isinstance(node.ctx, ast.Load) \
                    and node.attr in registry_names | {"registry"}:
                found.append(("the row validator rebound", f"{ast.unparse(node)[:60]} assigned or deleted at {at}"))
            elif isinstance(node, ast.Name) and node.id == "registry" and not isinstance(node.ctx, ast.Load) \
                    and scan.target_kind.get(id(node)) != "registry":
                found.append(("the row validator rebound", f"the name registry bound to something else at {at}"))
            elif isinstance(node, ast.arg) and node.arg == "registry" \
                    and scan.kinds.get((id(scan.scope_of(node)), "registry")) != "registry":
                found.append(("the row validator rebound", f"a parameter named registry at {at}"))
    for module, tree in trees.items():
        if module.startswith("loop-authority"):
            continue  # judged above
        aliases = {"registry"}
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    if alias.name == "registry" or alias.name.endswith(".registry"):
                        aliases.add(alias.asname or alias.name.split(".")[0])
                        if alias.asname or isinstance(node, ast.Import):
                            found.append(("the row validator rebound", f"registry imported under another name at {module}:{node.lineno}"))
        changed = True
        while changed:
            before = set(aliases)
            for node in ast.walk(tree):
                if isinstance(node, ast.Assign) and isinstance(node.value, ast.Name) and node.value.id in aliases:
                    aliases.update(t.id for t in node.targets if isinstance(t, ast.Name))
            changed = before != aliases
        for node in ast.walk(tree):
            at = f"{module}:{getattr(node, 'lineno', 0)}"
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("setattr", "delattr", "vars", "getattr") and node.args and isinstance(node.args[0], ast.Name) and node.args[0].id in aliases:
                found.append(("the row validator rebound", f"registry reflection at {at}"))
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in aliases and (node.attr == "__dict__" or not isinstance(node.ctx, ast.Load)):
                found.append(("the row validator rebound", f"registry alias attribute changed/exposed at {at}"))
            if isinstance(node, ast.Name) and node.id == "registry" and not isinstance(node.ctx, ast.Load):
                found.append(("the row validator rebound", f"the name registry assigned at {at}"))
            elif isinstance(node, ast.arg) and node.arg == "registry":
                found.append(("the row validator rebound", f"a parameter named registry at {at}"))
            elif isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "registry" \
                    and not isinstance(node.ctx, ast.Load):
                found.append(("the row validator rebound", f"registry.{node.attr} replaced at {at}"))
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    bound = alias.asname or alias.name.split(".")[0]
                    legit = isinstance(node, ast.ImportFrom) and node.level == 1 and node.module is None \
                        and alias.name == "registry" and alias.asname is None
                    if bound == "registry" and not legit:
                        found.append(("the row validator rebound", f"an import binding registry at {at}"))
    bind, seal = index.functions.get("store.bind_record"), index.functions.get("store.seal")
    if bind is None or "record_type != registry.ROW_BY_ID[token.row]['record_type']" not in ast.unparse(bind):
        found.append(("the stage bind no longer fixes the type by the row", "store.bind_record"))
    if seal is None or "record_type != bound['type']" not in ast.unparse(seal):
        found.append(("seal no longer requires the bound type", "store.seal"))
    return found


F4_RULES = (
    ("record primitive used as a value", "record/token primitives cannot escape as values or bare imports"),
    ("missing or duplicate preparation", "each ceremony driver contains exactly one recognized preparation"),
    ("seal outside the write-protocol driver",
     "store.seal and store.seal_pointer are called only from the write-protocol driver (store.prepare_record)"),
    ("a record prepared outside a ceremony row's driver",
     "a record is prepared only by the four ceremony rows' transaction drivers"),
    ("a caller-supplied record type", "every record type reaching a seal is a literal at its driver"),
    ("a record type not fixed by the row", "that literal is the frozen type of the row the driver began"),
    ("no row validator before the record",
     "each driver's row validator dominates its record: registry.validate of the row runs on every path to "
     "prepare_record, unconditionally and with its refusal propagating (not under an if, a loop, a with, a try "
     "that could swallow it, or a nested function)"),
    ("the row validator rebound", "and that validator is the registry module's: `registry` in lib/loopauth is never "
                                  "assigned, a parameter, imported as anything else, or its validate replaced; the "
                                  "writer entry binds `registry` only to the registry module and, through any alias "
                                  "(mods[\"registry\"], a local name, a parameter) or under any receiver, replaces or "
                                  "deletes no attribute of it and rebinds no module's registry"),
    ("a frame append outside a ceremony row's driver", "the frame append sink is called only from those drivers"),
    ("a frame append with a token its driver did not begin", "with the token that driver began"),
    ("a delimiter completion outside replay-forward", "the delimiter completion only from replay-forward"),
    ("store functions taking a record type",
     "the only functions taking a record type are store.bind_record, store.seal, and store.prepare_record"),
    ("a caller's record type reaches a seal", "no caller outside store.py passes any of them a variable type"),
    ("the stage bind no longer fixes the type by the row",
     "the stage bind refuses a type other than the row's (registry.ROW_BY_ID[token.row]['record_type'])"),
    ("seal no longer requires the bound type", "and seal refuses a type other than the bound one"),
)


def enumerate_parser():
    """The real argument parser of loop-authority.py: run the file until it
    parses its arguments, and capture the parser there (nothing is run)."""
    import argparse

    class Captured(Exception):
        pass

    captured = {}
    original = argparse.ArgumentParser.parse_args

    def capture(self, args=None, namespace=None):
        captured["parser"] = self
        raise Captured()

    argparse.ArgumentParser.parse_args = capture
    saved_argv, saved_mask = sys.argv, os.umask(0o077)
    os.umask(saved_mask)
    sys.argv = [AUTH_PY, "status"]
    try:
        runpy.run_path(AUTH_PY, run_name="__main__")
    except Captured:
        pass
    finally:
        argparse.ArgumentParser.parse_args = original
        sys.argv = saved_argv
        os.umask(saved_mask)
    parser = captured["parser"]
    groups = [a for a in parser._actions if isinstance(a, argparse._SubParsersAction)]
    top = [a.dest for a in parser._actions if not isinstance(a, (argparse._HelpAction,
                                                                   argparse._SubParsersAction))]
    table = {}
    for name, sub in (groups[0].choices.items() if groups else ()):
        items = []
        for action in sub._actions:
            if isinstance(action, argparse._HelpAction):
                continue
            items.append((action.option_strings[0] if action.option_strings else action.dest,
                          tuple(action.choices) if action.choices else None))
        table[name] = tuple(items)
    return table, top, len(groups)


def verifier_grammar():
    """loop-authority-verify's argv forms from its main(): the subcommands it
    compares argv[:1] with, and the refusal of anything else."""
    tree = ast.parse(read_text(VERIFY_PY), VERIFY_PY)
    main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main")
    subcommands = set()
    for node in ast.walk(main):
        if isinstance(node, ast.Compare) and isinstance(node.left, ast.Subscript) \
                and ast.unparse(node.left) == "argv[:1]":
            for comparator in node.comparators:
                if isinstance(comparator, ast.List):
                    subcommands |= {constant(e) for e in comparator.elts}
    refuses_rest = "if argv:" in ast.unparse(main)
    return {"loop-authority-verify"} | {f"loop-authority-verify {s}" for s in subcommands}, refuses_rest


VERIFIER_KEYGEN_FORMS = (("-Y", "verify", "-f", None, "-I", None, "-n", None, "-s", None),
                         ("-l", "-E", "sha256", "-f", None))
VERIFIER_GIT_FORMS = ("init", "fetch", "cat-file")
# The only primitives the verifier may reference, and where: its one runner
# starts processes, and its temporary-directory functions write.
VERIFIER_ALLOWED = {"Runner.run": {"subprocess.run", "subprocess.CompletedProcess", "subprocess.TimeoutExpired"},
                    "Runner.write_temp": {"os.open", "os.write"}, "Runner.make_temp": {"os.open", "os.mkdir"},
                    "Runner.init_repo": {"os.mkdir"}, "Runner.cleanup": {"shutil.rmtree"}}
# That runner, whole: one subprocess.run with fixed argv/env/timeout and the
# explicit F2 TimeoutExpired-to-Unreachable mapping; no other process start.
RUNNER_RUN = "def run(self, argv: list[str], *, git: bool, stdin: bytes=b'') -> subprocess.CompletedProcess:\n    try:\n        return subprocess.run(argv, input=stdin, capture_output=True, env=self.env(git), cwd=self.temp, timeout=120, check=False, close_fds=True)\n    except subprocess.TimeoutExpired as error:\n        raise Unreachable('remote command timed out') from error"


def verifier_findings(path, rs):
    """The independent verifier imports nothing from lib/loopauth, runs only
    its frozen argv forms through one runner, and writes only in its own
    temporary directory under $HOME/.cache/olddonkey-loop/verify -- judged by
    the alias-proof scan (every primitive resolved, whatever its spelling) and
    the runner rule: Runner.run is exactly its frozen body (one subprocess.run and the
    explicit timeout mapping), and every other `.run` it references is
    a direct self.run / RUN.run call with a frozen argv."""
    tree = ast.parse(read_text(path), path)
    index = Index({"verify": tree})
    scan = AliasScan(tree, rs, VERIFIER_IMPORTS, VERIFIER_ALLOWED, extra=(("sys.path", sys.path, "imports"),))
    scan.visit(tree)
    found = list(scan.findings)
    runner = index.functions.get("verify.Runner.run")
    start = None  # the one subprocess.run the runner may make: its statement's own call
    if runner is None or ast.unparse(runner) != RUNNER_RUN:
        found.append(("runner", "Runner.run differs from its frozen one-process body and timeout mapping: "
                                + (ast.unparse(runner)[:240] if runner is not None else "missing")))
    else:
        start = runner.body[0].body[0].value.func
    calls = {id(n.func): n for n in ast.walk(tree) if isinstance(n, ast.Call)}
    for _module, scope, node in index.nodes:
        where = scope.split(".", 1)[1] if "." in scope else scope
        at = f"{where}:{getattr(node, 'lineno', 0)}"
        if not (isinstance(node, ast.Attribute) and node.attr == "run"):
            continue
        base, call = node.value, calls.get(id(node))
        if node is start:
            continue  # the runner's own process start, and only that one call
        if not (isinstance(base, ast.Name) and base.id in ("self", "RUN")) or call is None:
            found.append(("argv", f"the runner reached other than as a direct self.run or RUN.run call at {at}: "
                                  f"{ast.unparse(node)}"))
            continue
        argv = call.args[0] if call.args else None
        form = None
        if isinstance(argv, ast.Call) and ast.unparse(argv.func) in ("self.git_argv", "RUN.git_argv") \
                and argv.args and constant(argv.args[0]) in VERIFIER_GIT_FORMS:
            form = constant(argv.args[0])
        elif isinstance(argv, ast.List) and argv.elts \
                and ast.unparse(argv.elts[0]) in ("self.binary('ssh-keygen')", "RUN.binary('ssh-keygen')"):
            rest = tuple(e.value if isinstance(e, ast.Constant) else None for e in argv.elts[1:])
            form = rest if rest in VERIFIER_KEYGEN_FORMS else None
        if form is None:
            found.append(("argv", f"a command outside the frozen forms at {at}: "
                                  f"{ast.unparse(argv) if argv else None}"))
    functions = index.functions
    for qual, needle in (("verify.Runner.write_temp", "self.temp"), ("verify.Runner.init_repo", "self.temp"),
                         ("verify.Runner.cleanup", "self.temp"), ("verify.Runner.make_temp", "'verify'"),
                         ("verify.Runner.make_temp", "self.authority")):
        if qual not in functions or needle not in ast.unparse(functions[qual]):
            found.append(("writes", f"{qual} no longer confines its write to the temporary directory ({needle})"))
    git_argv = functions.get("verify.Runner.git_argv")
    forms = {constant(c) for n in ast.walk(git_argv) if isinstance(n, ast.Compare) for c in n.comparators
             if isinstance(constant(c), str)} if git_argv else set()
    if forms != set(VERIFIER_GIT_FORMS) or not (git_argv and isinstance(git_argv.body[-1], ast.Raise)):
        found.append(("argv", f"git_argv builds forms {sorted(forms)} (frozen: {list(VERIFIER_GIT_FORMS)}) or no "
                              "longer refuses any other"))
    return found


MATRIX_NAMES = ("MATRIX_KINDS", "MATRIX_LABELS", "MATRIX_FRAME_TYPES", "MATRIX_KIND_OF", "MATRIX_CEREMONY",
                "matrix_cut_ids", "matrix_sizes_text", "matrix_options", "matrix_shard", "evidence_problem")


def matrix_marker_probe(nodes):
    """Execute the real matrix_cut with valid scripted states, varying only markers."""
    names = ("MATRIX_KINDS", "MATRIX_FRAME_TYPES", "MATRIX_KIND_OF", "MATRIX_CEREMONY",
             "MATRIX_ATTEMPTS", "MATRIX_OUTSIDE", "MATRIX_PRINCIPAL_READ", "canon", "sha", "fdigest",
             "mkframe", "parse_frames", "frame_of_intent", "revocation_marker", "matrix_cut")
    space = {"os": os, "re": re, "json": json, "hashlib": hashlib, "base64": base64}
    exec(compile(ast.Module(body=[nodes[name] for name in names], type_ignores=[]), AUTHORITY_SUITE, "exec"), space)
    frame = space["mkframe"](2, "epoch.revoked", b"{}")
    base = space["mkframe"](1, "store.genesis", b"{}")
    sid, old_tip, new_tip = "0" * 32, "1" * 40, "2" * 40
    results = []
    import tempfile
    for cut in (1, "last"):
        for wrong in (None, "before", "after"):
            with tempfile.TemporaryDirectory(dir=TMP) as directory:
                marker_path = os.path.join(directory, "quarantine")
                class Scripted:
                    case = None
                    url = "file:///scripted-matrix.git"
                    def __init__(self):
                        self.case = self
                        self.recovered = False
                        self.n = len(frame) - 1 if cut == "last" else cut
                    def restore(self):
                        self.recovered = False
                        if os.path.exists(marker_path): os.unlink(marker_path)
                        if wrong == "before":
                            with open(marker_path, "wb") as handle: handle.write(b"wrong marker")
                    def ceremony(self, *args, **kwargs):
                        return types.SimpleNamespace(rc=137, out="")
                    def intent(self):
                        return None if self.recovered else {"store_id": sid, "frame_b64": base64.b64encode(frame).decode(), "anchor_commit": new_tip}
                    def log_path(self, *args): return "log"
                    def store_dir(self, *args): return directory
                    def active(self): return {"store_id": sid}
                    def tip(self): return new_tip if self.recovered and cut == "last" else old_tip
                    def read(self, path):
                        if path == marker_path:
                            with open(path, "rb") as handle: return handle.read()
                        return base + (frame if self.recovered and cut == "last" else b"" if self.recovered else frame[:self.n])
                    def verifier(self):
                        state, table, row = (("pending", "A1.6 unterminated, remote old", "anchor-replay-forward") if cut == "last" else
                                             ("needs-recovery", "A1.6 torn", "torn-frame-truncation"))
                        return types.SimpleNamespace(json={"state": state, "table": table, "row": row, "authorizing_state": False, "current_authorization": False})
                    def writer(self, *args):
                        first = self.verifier().json
                        self.recovered = True
                        if os.path.exists(marker_path): os.unlink(marker_path)
                        marker = b"wrong marker" if wrong == "after" else space["revocation_marker"](sid, 2) if cut == "last" else None
                        if marker is not None:
                            with open(marker_path, "wb") as handle: handle.write(marker)
                        rows = [first, {"row": "recovery-tidy"}] + ([{"row": "store-quarantine"}] if cut == "last" else [])
                        return types.SimpleNamespace(rc=6 if cut == "last" else 0, json={"steps": rows,
                            "state": "quarantined" if cut == "last" else "committed", "seq": 2 if cut == "last" else 1,
                            "epochs": {"1": "revoked" if cut == "last" else "active"}, "active_epoch": None if cut == "last" else 1,
                            "authorizing_state": cut != "last", "rule": "active-epoch-revoked" if cut == "last" else None})
                ok, detail, evidence = space["matrix_cut"](Scripted(), "revocation", cut, len(frame), base, old_tip, lambda intent: None)
                results.append((cut, wrong, ok, detail, evidence is not None))
    return all(ok == (wrong is None) and credited for _cut, wrong, ok, _detail, credited in results), results


def crash_matrix_checks(suite_text, workflow_text):
    """F6's structural check of the every-byte crash matrix, from its own
    enumerator: authority-selftest.sh's driver (at.py, from its heredocs)
    parsed, and its enumerator, tables, and option parser run alone. Returns
    [(description, ok, detail)]."""
    bodies = re.findall(r"cat >>? \"\$TMP_ROOT/at\.py\" <<'PY'\n(.*?)\nPY\n", suite_text, re.S)
    tree = ast.parse("\n".join(bodies))
    nodes = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            nodes[node.name] = node
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            nodes[node.targets[0].id] = node
    missing = [name for name in MATRIX_NAMES if name not in nodes]
    space = {"re": re, "os": os, "hashlib": hashlib}
    exec(compile(ast.Module(body=[nodes[name] for name in MATRIX_NAMES if name in nodes], type_ignores=[]),
                 AUTHORITY_SUITE, "exec"), space)  # noqa: S102 - the sibling suite's own enumerator
    kinds, types_, ceremony = space.get("MATRIX_KINDS"), space.get("MATRIX_FRAME_TYPES"), space.get("MATRIX_CEREMONY")
    sizes = {"genesis": 7, "rotation": 6, "revocation": 5}
    want = [f"{kind}:frame-byte-{n}" for kind in ("genesis", "rotation", "revocation")
            for n in (*range(1, sizes[kind] - 1), "last")]
    try:
        ids = space["matrix_cut_ids"](sizes)
    except Exception as error:  # noqa: BLE001 - an enumerator that fails is a failed check
        ids = f"{type(error).__name__}: {error}"
    try:
        parsed = space["matrix_options"](["--sizes", "7,6,5"])["sizes"]
    except Exception as error:  # noqa: BLE001
        parsed = f"{type(error).__name__}: {error}"
    slots = ast.unparse(nodes["matrix_slots"]) if "matrix_slots" in nodes else ""
    cut = ast.unparse(nodes["matrix_cut"]) if "matrix_cut" in nodes else ""
    wrapper = re.search(r"--sizes\) \[\[ \"\$\{2:-\}\" =~ (\S+) \]\]", suite_text)
    checks = [
        ("the crash matrix's driver (authority-selftest.sh's at.py) defines its enumerator and tables",
         not missing, missing),
        ("it enumerates exactly three frame kinds: genesis frame 1 (store.genesis), an epoch-rotation frame "
         "(epoch.rotated), and the active epoch's revocation frame (epoch.revoked)",
         kinds == ("genesis", "rotation", "revocation")
         and types_ == {"genesis": "store.genesis", "rotation": "epoch.rotated", "revocation": "epoch.revoked"},
         (kinds, types_)),
        ("its revocation kind crashes `ceremony revoke --epoch 1` on a template holding one real genesis (every "
         "non-genesis kind's template runs genesis first), so the revoked epoch is the active one",
         isinstance(ceremony, dict) and ceremony.get("revocation") == ("revoke", "--epoch", "1")
         and "if kind != 'genesis':" in slots and "slot.case.genesis()" in slots, ceremony),
        ("for planned sizes G, R, V its cut list is every torn byte 1 .. N - 2 of each kind, then last: all three "
         "kinds, nothing sampled", ids == want, ids if not isinstance(ids, list) else sorted(set(ids) ^ set(want))[:6]),
        ("--sizes takes exactly three sizes, G,R,V, in the kinds' order (the wrapper's pattern and the option parser)",
         wrapper is not None and re.fullmatch(wrapper.group(1), "7,6,5") is not None
         and re.fullmatch(wrapper.group(1), "7,6") is None and parsed == sizes, (wrapper and wrapper.group(1), parsed)),
        ("each cut of the revocation is checked as the compound: no quarantine marker after a torn cut's recovery, "
         "and after the last byte's the marker's exact bytes (matrix_cut against the test-side revocation_marker)",
         *matrix_marker_probe(nodes)),
    ]
    if workflow_text is not None:
        plan = re.search(r"\[\[ \"\$sizes\" =~ (\S+) \]\]", workflow_text)
        checks.append(
            ("the CI crash-matrix jobs agree: the plan job accepts exactly three sizes, and eight shards run "
             "--shard K/8 --sizes \"$SIZES\" before the coverage job's --check-shards with the same sizes",
             plan is not None and re.fullmatch(plan.group(1), "7,6,5") is not None
             and re.fullmatch(plan.group(1), "7,6") is None and "shard: [1, 2, 3, 4, 5, 6, 7, 8]" in workflow_text
             and '--shard "$SHARD/8" --sizes "$SIZES"' in workflow_text
             and '--check-shards cut-ids --sizes "$SIZES"' in workflow_text, plan and plan.group(1)))
    return checks


def lib_import_graph(lib):
    graph = {}
    package = os.path.join(lib, "loopauth")
    for filename in os.listdir(package):
        if not filename.endswith(".py"):
            continue
        tree = ast.parse(read_text(os.path.join(package, filename)))
        edges = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.level:
                if node.module:
                    edges.add(node.module.split(".")[0])
                else:
                    edges |= {alias.name for alias in node.names}
        graph[filename[:-3]] = edges
    return graph


def journal_findings(paths, lib):
    """loop-journal and loop-index: their Python imports no authority-store
    module (transitively) and names no authority path."""
    graph = lib_import_graph(lib)
    found = []
    for path in paths:
        name = os.path.basename(path)
        bodies = heredocs(read_text(path))
        if not bodies:
            found.append((name, "no embedded Python found"))
        for body in bodies:
            tree = ast.parse(body, path)
            imported = set()
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported |= {a.name.split(".", 1)[1] for a in node.names if a.name.startswith("loopauth.")}
                elif isinstance(node, ast.ImportFrom) and (node.module or "").startswith("loopauth"):
                    if node.module == "loopauth":
                        imported |= {a.name for a in node.names}
                    else:
                        imported.add(node.module.split(".")[1])
                elif isinstance(node, ast.Call) and callee(node)[1] == "import_module":
                    target = constant(node.args[0]) if node.args else None
                    if not isinstance(target, str):
                        found.append((name, f"a dynamic import at line {node.lineno}"))
                    elif target.startswith("loopauth."):
                        imported.add(target.split(".")[1])
                elif isinstance(node, ast.Constant) and isinstance(node.value, str) and (
                        node.value == "authority" or "/authority" in node.value or "authority/" in node.value):
                    found.append((name, f"an authority path component {node.value!r} at line {node.lineno}"))
            reach, queue = set(), list(imported)
            while queue:
                module = queue.pop()
                if module not in reach:
                    reach.add(module)
                    queue += sorted(graph.get(module, ()))
            if reach & STORE_MODULES:
                found.append((name, f"imports authority-store modules {sorted(reach & STORE_MODULES)} "
                                    f"(through {sorted(imported)})"))
    return found


def mode_static():
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, records, registry, store  # noqa: E402

    rs_path, rs = load_registry_scanner()
    live_index = Index(parse_modules(writer_sources(SKILL))[0])

    # ---------------------------------------------------------------- F1
    rs_tmp = os.path.join(TMP, "rs-static")
    os.makedirs(rs_tmp)
    result = subprocess.run([sys.executable, rs_path, "static", LIB, rs_tmp], capture_output=True, timeout=1200,
                            env=dict(os.environ, HOME=os.path.join(TMP, "home")))
    lines = [line.split("\t") for line in result.stdout.decode("utf-8", "replace").splitlines()]
    passed = [line[1] for line in lines if line[0] == "ok"]
    failed = [line for line in lines if line[0] != "ok"]
    emit("F1", f"p2 s7's AST scan re-run: registry-selftest.sh's own static mode passes all {len(lines)} of its "
         "checks (the reachability scan of lib/loopauth, its four planted-bypass controls, the closed command table, "
         "and 0a.3's read-only scan with its planted controls)",
         result.returncode == 0 and lines and not failed, (result.returncode, failed[:3],
                                                           result.stderr.decode("utf-8", "replace")[-600:]))
    named = ["reachability: no write, process, or sink command in lib/loopauth escapes the token-checked sinks "
             "(AST scan)"] + [f"reachability negative control: {label} makes the scan fail" for label in rs["PLANTS"]]
    emit("F1", "the re-run includes the scan itself and p2 s7's four planted-bypass controls, by name",
         all(name in passed for name in named), [name for name in named if name not in passed])
    emit("F1", "scripts/loop-authority embeds no Python of its own (no heredoc) and runs loop-authority.py beside it, "
         "so that file is the entry's Python the scan covers",
         not heredocs(read_text(AUTH)) and 'exec python3 -I -B "$here/loop-authority.py" "$@"' in read_text(AUTH))
    live = f1_findings(SKILL, rs, registry)
    for rule in ("p2 s7 scan", "0a.3 read-only rules", "0a.3 call graph", "sink -> transaction driver map",
                 "token minting", "entry point", "entry loopauth access", "entry importer inventory", "parse"):
        hits = [what for name, what in live if name == rule]
        emit("F1", f"the live tree passes F1's rule [{rule}] (every lib/loopauth module and loop-authority.py)",
             not hits, hits[:6])
    _problems, pairs = sink_problems(live_index)
    stale = [f"{caller} -> {sink}" for sink in SINK_FUNCTIONS for caller in sorted(SINK_DRIVERS[sink] - pairs.get(sink, set()))]
    emit("F1", "the frozen sink -> driver map is exact: every frozen sink (store.SINK_FUNCTIONS) is called by exactly "
         "the drivers it names", tuple(store.SINK_FUNCTIONS) == SINK_FUNCTIONS and not stale,
         (store.SINK_FUNCTIONS, stale))
    drivers = set().union(*SINK_DRIVERS.values())
    problems = driver_problems(live_index, drivers)
    emit("F1", f"every one of the {len(drivers)} functions allowed to call a sink is the transaction driver of a registry "
         "row (it mints the row's token: a ceremony's store.begin, the recovery routine's _mint) or a helper taking "
         "such a driver's token", not problems, problems)
    allowed = {q for q in rs["RAW_WRITE_ALLOWED"] if not q.startswith("store.")}
    want = {"tools._open_dir_chain", "tools.scratch_tmp", "tools._remove_tree", "tools.write_scratch_file",
            "tools.new_scratch_repo", "ceremony._write"}
    guard = []
    for qual in sorted(want):
        node = live_index.functions.get(qual)
        if node is None:
            guard.append(f"{qual} is missing")
        elif qual == "ceremony._write":
            writes = [c for c in ast.walk(node) if isinstance(c, ast.Call) and callee(c) == ("os", "write")]
            if not writes or any(constant(c.args[0]) != 1 for c in writes):
                guard.append("ceremony._write writes somewhere other than fd 1")
        elif qual == "tools._open_dir_chain":
            for _m, _s, call in live_index.calls:
                if callee(call)[1] == "_open_dir_chain":
                    parts = call.args[1] if len(call.args) > 1 else None
                    if not (isinstance(parts, ast.List) and parts.elts and constant(parts.elts[0]) == ".cache"):
                        guard.append(f"_open_dir_chain called with {ast.unparse(parts) if parts else None}")
        elif "is_authority_path" not in ast.unparse(node):
            guard.append(f"{qual} writes without refusing a path under the authority directory")
    emit("F1", "no module but store.py opens a path under the authority directory for writing: the only other writers "
         "the scan allows are the scratch functions of tools.py (each refusing an authority path, or walking "
         "$HOME/.cache) and the ceremony's terminal output (fd 1)",
         allowed == want and rs["PROCESS_ALLOWED"] == {"tools.run"} and not guard, (sorted(allowed ^ want), guard))
    plants = {f"p2 s7: {label}": [(f"lib/loopauth/{filename}", code)]
              for label, (filename, code) in rs["PLANTS"].items()}
    plants["0a.4: a sink call planted in scripts/loop-authority's Python (loop-authority.py)"] = [
        ("scripts/loop-authority.py", ENTRY_PLANT)]
    refs_label = "refs.py calls a store sink (write_quarantine)"
    plants["0a.4: a sink call planted in refs.py (0a.3's read-only module)"] = [
        ("lib/loopauth/refs.py", rs["READ_ONLY_PLANTS"][refs_label][1])]
    for number, (label, edits) in enumerate(plants.items(), 1):
        copy = planted_copy(f"f1-{number}", edits)
        found = f1_findings(copy, rs, registry)
        emit("F1", f"planted bypass: {label} makes F1 fail (rules fired: {sorted({name for name, _w in found})})",
             bool(found), found[:3])
    for number, (label, code, needle) in enumerate(ENTRY_ALIAS_PLANTS, 1):
        copy = planted_copy(f"f1-alias-{number}", [("scripts/loop-authority.py", code)])
        found = f1_findings(copy, rs, registry)
        named = [what for name, what in found if name == "entry point" and needle in what]
        emit("F1", f"planted alias in scripts/loop-authority's Python: {label} makes F1 fail, the entry-point scan "
             f"naming it ({needle})", bool(named), found[:3])

    live_entry = entry_modules(parse_modules(writer_sources(SKILL))[0]).get("loop-authority")
    accesses = live_entry.accesses if live_entry else {}
    emit("F1", "the writer entry's loopauth accesses are exactly the frozen table: every attribute of every loopauth "
         "module loop-authority.py reads, by module, through whatever alias (mods[...], the names main unpacks them "
         "into, exit_for's parameters), and load_loopauth() loads exactly the frozen modules",
         live_entry is not None and accesses == ENTRY_MODULE_ACCESS and live_entry.loaded == ENTRY_LOADED,
         (sorted((m, a) for m in set(accesses) | set(ENTRY_MODULE_ACCESS)
                 for a in set(accesses.get(m, ())) ^ set(ENTRY_MODULE_ACCESS.get(m, ()))),
          live_entry and live_entry.loaded))
    forbidden = {"Token", "begin", "begin_recovery", "begin_finish", "child", "spend", "validate",
                 "check_exclusions"} | set(SINK_FUNCTIONS)
    listed = []
    for module, names in sorted(ENTRY_MODULE_ACCESS.items()):
        real = importlib.import_module("loopauth" if module == "loopauth" else f"loopauth.{module}")
        for name in sorted(names):
            value = real
            valid = True
            for part in name.split("."):
                if not hasattr(value, part) or (part.startswith("_") and not dunder(part)) or part in forbidden:
                    valid = False
                    break
                value = getattr(value, part)
            if "." in name and not (isinstance(value, type) and issubclass(value, Exception)):
                valid = False
            if not valid:
                listed.append(f"{module}.{name}")
    emit("F1", "the frozen table names only real attributes, and no private helper, token constructor or minter "
         "(Token, _new, begin, begin_recovery, begin_finish, child), permit or file helper (_grant, _fs_*), sink "
         "(store.SINK_FUNCTIONS), or validator (registry.validate)", not listed, listed)
    home = os.path.join(TMP, "forge-live-home")
    os.mkdir(home, 0o700)
    control = writer(home, "status")
    emit("F1", "control: the live entry's `status` in a fresh HOME writes no authority/active",
         read_bytes(auth(home, "active")) is None, control)
    for number, (label, edits, needles) in enumerate(ENTRY_MODULE_PLANTS, 1):
        copy = planted_copy(f"f1-module-{number}", edits)
        found = f1_findings(copy, rs, registry)
        accessed = [what for name, what in found if name == "entry loopauth access"]
        missing = [needle for needle in needles if not any(needle in what for what in accessed)]
        emit("F1", f"planted bypass of the entry's frozen loopauth accesses: {label} makes F1 fail, the entry's "
             f"loopauth-access scan naming each of {list(needles)}", bool(found) and not missing,
             (missing, accessed[:4]))
        if number == 1:
            home = os.path.join(TMP, "forge-plant-home")
            os.mkdir(home, 0o700)
            res = run_cmd([BASH, os.path.join(copy, "scripts", "loop-authority"), "status"], cli_env(home))
            emit("F1", "and it is a complete bypass: run through the planted entry (`loop-authority status`), it "
                 "writes authority/active with its forged bytes through a token no row minted -- what the scan "
                 "refuses is live", read_bytes(auth(home, "active")) == FORGED_ACTIVE,
                 (read_bytes(auth(home, "active")), res))

    verifier_found = verifier_findings(VERIFY_PY, rs)
    for rule, text in (("imports", "imports only its frozen modules -- nothing from lib/loopauth -- and never touches "
                                   "sys.path"),
                       ("process", "starts processes only in its one runner (Runner.run), however a primitive is "
                                   "spelled"),
                       ("runner", "has exactly its frozen runner body: one process and explicit timeout mapping -- `return "
                                  "subprocess.run(argv, input=stdin, capture_output=True, env=self.env(git), "
                                  "cwd=self.temp, timeout=120, check=False, close_fds=True)` with argv its own "
                                  "parameter, and nothing else: no other call, command, or statement inside it"),
                       ("argv", "runs only its frozen argv forms -- git init, fetch, cat-file (-t|-p) through "
                                "git_argv, which refuses any other, and ssh-keygen -Y verify and -l -- through direct "
                                "self.run / RUN.run calls only"),
                       ("writes", "writes only its own temporary directory under $HOME/.cache/olddonkey-loop/verify "
                                  "(never the authority directory or the remote)"),
                       ("aliases", "binds no module under another name, uses no module or primitive as a value, "
                                   "reaches no module through another, and makes no dynamic attribute access or "
                                   "namespace lookup (every primitive reference resolved to what it is)")):
        hits = [what for name, what in verifier_found if name == rule]
        emit("F1", f"the independent verifier {text}", not hits, hits[:6])
    for number, (label, rule, code) in enumerate((
            ("a subprocess of git push outside the runner", "process",
             "def _bypass_push(remote):\n    return subprocess.run([\"git\", \"push\", remote])\n"),
            ("a runner call with an unlisted argv", "argv",
             "def _bypass_argv():\n    return RUN.run([RUN.binary(\"git\"), \"push\"], git=True)\n"),
            ("a file opened for writing", "writes",
             "def _bypass_write(path):\n    with open(path, \"w\") as handle:\n        handle.write(\"x\")\n"),
            ("an import from lib/loopauth", "imports", "from loopauth import store\n"),
            *VERIFIER_ALIAS_PLANTS,
            *RUNNER_PLANTS), 1):
        copy = os.path.join(TMP, "plant", f"verifier-{number}.py")
        os.makedirs(os.path.dirname(copy), exist_ok=True)
        text = read_text(VERIFY_PY)
        if isinstance(code, tuple):
            if code[0] not in text:
                raise RuntimeError(f"the verifier text to replace is gone: {code[0]!r}")
            text = text.replace(code[0], code[1], 1)
        else:
            text += "\n\n" + code
        with open(copy, "w", encoding="utf-8") as handle:
            handle.write(text)
        found = verifier_findings(copy, rs)
        rules = (rule,) if isinstance(rule, str) else rule
        emit("F1", f"planted control: the verifier with {label} fails the verifier check ({' and '.join(rules)})",
             set(rules) <= {name for name, _what in found}, found[:3])

    journal_found = journal_findings((JOURNAL, INDEX), LIB)
    emit("F1", "loop-journal and loop-index import no authority-store module (their loopauth imports' closure is "
         "canonical and vocabulary) and name no path under the authority directory", not journal_found, journal_found)
    for number, (label, (needle, replacement)) in enumerate((
            ("an import of loopauth.store", ("import fcntl\n", "import fcntl\nimport loopauth.store\n")),
            ("a path under the authority directory",
             ("import fcntl\n", "import fcntl\nAUTHORITY = (\".config\", \"olddonkey-loop\", \"authority\")\n"))), 1):
        copy = os.path.join(TMP, "plant", f"loop-journal-{number}")
        text = read_text(JOURNAL)
        with open(copy, "w", encoding="utf-8") as handle:
            handle.write(text.replace(needle, replacement, 1))
        emit("F1", f"planted control: loop-journal with {label} fails the journal check",
             needle in text and bool(journal_findings((copy,), LIB)))

    sidecar = planted_copy("review-new-importer", [("scripts/loop-sidecar.py", "from loopauth import store\n" + FORGE_ACTIVE)])
    sidecar_findings = f1_findings(sidecar, rs, registry)
    emit("F1", "planted fifth importer: a new sidecar forging a token is visible to the inventory guard",
         any(rule == "entry importer inventory" for rule, _detail in sidecar_findings), sidecar_findings[:3])

    unknown_sink = planted_copy("review-new-sink", [("lib/loopauth/store.py", ('SINK_FUNCTIONS = (', 'SINK_FUNCTIONS = ("unlisted_sink",'))])
    unknown_problems, _ = sink_problems(Index(parse_modules(writer_sources(unknown_sink))[0]))
    emit("F1", "planted unfrozen sink: a new declared sink with no caller is still refused",
         any("unfrozen sink" in problem for problem in unknown_problems), unknown_problems)
    trace_path = os.path.join(TMP, "review-trace.jsonl")
    events = [{"e": "mint", "id": "t", "kind": "recovery", "row": "recovery-tidy"},
              {"e": "sink", "id": "t", "fn": "write_cursor"}]
    with open(trace_path, "w", encoding="utf-8") as handle:
        handle.write("".join(json.dumps(event) + "\n" for event in events))
    trace_control = Trace(trace_path)
    events[-1]["fn"] = "append_frame"
    with open(trace_path, "w", encoding="utf-8") as handle:
        handle.write("".join(json.dumps(event) + "\n" for event in events))
    try:
        Trace(trace_path)
        rejected_trace = False
    except ValueError as error:
        rejected_trace = "trace-sink" in str(error)
    emit("F3", "planted wrong-token sink: completed sinks are checked, not only recorded",
         trace_control.sinks == [["write_cursor"]] and rejected_trace)

    # ---------------------------------------------------------------- F2
    table, top, groups = enumerate_parser()
    emit("F2", "the real argument parser (captured from loop-authority.py as it runs) has exactly the frozen "
         "subcommands and arguments, and no top-level option", table == PARSER and not top and groups == 1,
         (table, top, groups))
    enumerated = set()
    for name, items in table.items():
        if name == "ceremony":
            kinds = dict(items).get("kind") or ()
            enumerated |= {f"loop-authority ceremony {kind}" for kind in kinds}
        else:
            enumerated.add(f"loop-authority {name}")
    grammar, refuses_rest = verifier_grammar()
    enumerated |= grammar
    emit("F2", "the enumerated entry points (every subcommand, every ceremony name, the verifier's argv forms) equal "
         "the frozen entry-point table, each mapped to exactly one row or to none",
         enumerated == set(ENTRY_POINTS) and refuses_rest, sorted(enumerated ^ set(ENTRY_POINTS)))
    ceremony_rows = {kind: ENTRY_POINTS[f"loop-authority ceremony {kind}"] for kind in CEREMONY_ROWS}
    admissible = {r["id"] for r in registry.ROWS if r["entry"] == "ceremony" and r["admissible"]}
    emit("F2", "each ceremony is the entry point of exactly one admissible ceremony row, and every admissible "
         "ceremony row has one (ceremony.CEREMONY_ROWS is the table's)",
         ceremony.CEREMONY_ROWS == ceremony_rows == CEREMONY_ROWS and set(ceremony_rows.values()) == admissible
         and len(set(ceremony_rows.values())) == len(ceremony_rows), (ceremony.CEREMONY_ROWS, admissible))
    execute = live_index.functions["recover.execute"]
    branches = {constant(c) for n in ast.walk(execute) if isinstance(n, ast.Compare)
                and isinstance(n.left, ast.Name) and n.left.id == "row"
                for comparator in n.comparators
                for c in (comparator.elts if isinstance(comparator, ast.Tuple) else [comparator])}
    recovery_rows = {r["id"] for r in registry.ROWS if r["entry"] == "recovery"}
    emit("F2", "`recover` maps to the recovery routine, whose branches are exactly torn-frame truncation, anchor "
         "replay-forward (with delimiter completion), recovery tidy, store quarantine, and A2.4's completion and "
         "abandonment",
         branches == set(RECOVERY_BRANCHES) and recovery_rows == set(RECOVERY_BRANCHES[:4])
         and set(store.FINISH_SINKS) == {"complete", "abandon"}, (sorted(branches), sorted(recovery_rows)))
    replay = ast.unparse(live_index.functions["recover._replay"])
    emit("F2", "the delimiter completion runs only inside replay-forward's transaction, only for an unterminated frame, "
         "before the push under the same token",
         "if params.get('unterminated'):\n            store.complete_delimiter(token" in replay
         and replay.index("complete_delimiter") < replay.index("store.push_anchor(token"))

    # ---------------------------------------------------------------- F3
    derived = {r["id"] for r in registry.ROWS if r["admissible"] and r["entry"] in ("recovery", "compound")}
    emit("F3", "the derived rows 0a admits are exactly authority-head advance, torn-frame truncation, anchor "
         "replay-forward, recovery tidy, and store quarantine, each carrying X7",
         derived == set(DERIVED_ROWS) and all("X7" in registry.ROW_BY_ID[r]["exclusions"] for r in DERIVED_ROWS),
         sorted(derived))
    mapped = {row for row in ENTRY_POINTS.values() if row not in (None, "the recovery routine")}
    emit("F3", "no derived row and no compound child appears in any entry point's row list; every row an entry point "
         "names is an admissible ceremony row",
         not mapped & (set(DERIVED_ROWS) | {"delimiter-completion"}) and all(
             registry.ROW_BY_ID[r]["entry"] == "ceremony" and registry.ROW_BY_ID[r]["admissible"] for r in mapped),
         sorted(mapped))
    emit("F3", "no argument of `recover` selects a row or supplies evidence: its parser takes no argument at all (no "
         "row, sequence, digest, path, or evidence option)", table.get("recover") == () and PARSER["recover"] == ())
    record_rows = ("authority-genesis", "epoch-rotation", "epoch-revocation", "linked-regenesis")
    emit("F3", "the compound children are the revocation's store quarantine, replay-forward's delimiter completion "
         "(its own sink, no row), and the head advance of each record row -- none with an entry of its own",
         "store-quarantine" in registry.ROW_BY_ID["epoch-revocation"]["children"]
         and registry.ROW_BY_ID["store-quarantine"]["parent"] == "epoch-revocation"
         and [r["id"] for r in registry.ROWS if "delimiter-completion" in r["sinks"]] == ["anchor-replay-forward"]
         and all("authority-head-advance" in registry.ROW_BY_ID[r]["children"] for r in record_rows)
         and registry.ROW_BY_ID["authority-head-advance"]["entry"] == "compound")

    # ---------------------------------------------------------------- F4
    emit("F4", "the frozen row -> record type map is the registry's record_type column for the four record rows and "
         "exactly ALLOWED[\"tg-v1.0a\"]'s types (one type per row)",
         ROW_TYPE == {row: registry.ROW_BY_ID[row]["record_type"] for row in ROW_TYPE}
         and set(ROW_TYPE.values()) == set(records.ALLOWED["tg-v1.0a"]["types"]) == set(records.ADMISSIBLE_TYPES)
         and len(set(ROW_TYPE.values())) == len(ROW_TYPE) and set(ROW_TYPE) == set(CEREMONY_ROWS.values()))
    emit("F4", "the frozen not-admitted types are every type of the closed list that ALLOWED[\"tg-v1.0a\"] does not "
         "admit", set(NOT_ADMITTED) == set(records.TYPES) - set(records.ALLOWED["tg-v1.0a"]["types"]))
    f4_live = f4_findings(SKILL)
    for rule, text in F4_RULES:
        hits = [what for name, what in f4_live if name == rule]
        emit("F4", f"no generic sealing or append hatch: {text}", not hits, hits[:4])
    emit("F4", "every F4 finding on the live tree is one of the rules above (nothing unparsed or unclassified)",
         all(name in dict(F4_RULES) for name, _what in f4_live), f4_live[:4])
    f4_plants = [
        ("planted generic hatch", "a ceremony function taking a record type and payload from its caller that seals "
         "and appends an allowed type (epoch.rotated) without the row's validator",
         [("lib/loopauth/ceremony.py", HATCH_PLANT)],
         {"a caller-supplied record type", "no row validator before the record",
          "a record prepared outside a ceremony row's driver", "a frame append outside a ceremony row's driver"}),
        ("planted generic hatch", "a store.py helper sealing a record type its caller names",
         [("lib/loopauth/store.py", SEAL_HELPER_PLANT)],
         {"seal outside the write-protocol driver", "store functions taking a record type"}),
        ("planted generic hatch", "the rotation driver with its row validator removed",
         [("lib/loopauth/ceremony.py", UNVALIDATED_PLANT)], {"no row validator before the record"})]
    alias_seal = HATCH_PLANT.replace("seal_and_append", "seal_anything").replace("    plan = recover.recover()", "    s = store\n    plan = recover.recover()")
    alias_seal = alias_seal.replace("        store.write_intent(token, store_id=view.store_id, data=prepared.intent_bytes)\n        store.append_frame(token, store_id=view.store_id, data=prepared.frame)", "        return prepared.frame").replace("store.", "s.")
    revoke_source = read_text(os.path.join(LIB, "loopauth", "ceremony.py"))
    revoke_start = revoke_source.index("def revoke(")
    revoke_end = revoke_source.index("\ndef regenesis(", revoke_start)
    revoke = revoke_source[revoke_start:revoke_end]
    alias_revoke = revoke.replace('registry.validate("epoch-revocation",', 'print("epoch-revocation",').replace(
        "prepared = store.prepare_record(", "prepare = store.prepare_record\n        prepared = prepare(")
    f4_plants += [
        ("planted alias hatch", "seal-only hatch through a local store alias", [("lib/loopauth/ceremony.py", alias_seal)],
         {"a record prepared outside a ceremony row's driver", "a caller-supplied record type"}),
        ("planted alias hatch", "revocation validator removed and preparation aliased", [("lib/loopauth/ceremony.py", (revoke, alias_revoke))],
         {"record primitive used as a value", "missing or duplicate preparation"}),
        ("planted registry mutation", "setattr replaces the validator", [("lib/loopauth/ceremony.py", 'setattr(registry, "validate", lambda *args: None)')],
         {"the row validator rebound"}),
        ("planted registry mutation", "import alias replaces the validator", [("lib/loopauth/ceremony.py", 'from . import registry as _reg\n_reg.validate = lambda *args: None')],
         {"the row validator rebound"}),
        ("planted registry mutation", "dictionary access replaces the validator", [("lib/loopauth/recover.py", 'registry.__dict__["validate"] = lambda *args: None')],
         {"the row validator rebound"}),
    ]
    f4_plants += [("planted dead validator", label, edits, {"no row validator before the record"})
                  for label, edits in DEAD_VALIDATOR_PLANTS]
    f4_plants.append(("planted stand-in validator", "ceremony.py rebinding registry to an object whose validate "
                      "admits anything", [("lib/loopauth/ceremony.py", REBOUND_PLANT)], {"the row validator rebound"}))
    f4_plants += [("planted stand-in validator", label, edits, {"the row validator rebound"})
                  for label, edits in ENTRY_VALIDATOR_PLANTS]
    for number, (kind, label, edits, expect) in enumerate(f4_plants, 1):
        copy = planted_copy(f"f4-{number}", edits)
        found = f4_findings(copy)
        fired = {name for name, _what in found}
        textual = True
        if kind == "planted dead validator":
            # the plant keeps a validate call of the row on a line before the
            # record: a textual-order rule would pass it
            tree = ast.parse(read_text(os.path.join(copy, "lib", "loopauth", "ceremony.py")))
            rotate = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "rotate")
            prepare = next(c for c in ast.walk(rotate) if isinstance(c, ast.Call)
                           and callee(c) == ("store", "prepare_record"))
            textual = any(isinstance(c, ast.Call) and callee(c) == ("registry", "validate") and c.args
                          and constant(c.args[0]) == "epoch-rotation" and c.lineno < prepare.lineno
                          for c in ast.walk(rotate))
        emit("F4", f"{kind}: {label} makes the structural check fail ({sorted(expect)})"
             + (", though the call still precedes the record textually" if kind == "planted dead validator" else ""),
             expect <= fired and textual, found[:4])
    escape = []
    if f4_live:
        escape.append(f"{len(f4_live)} F4 findings on the live tree")
    escape += driver_problems(live_index, {"store.prepare_record"} | set(CEREMONY_DRIVERS))
    emit("F4", "the real frozen maps allow no exceptions: every function they allow to "
         "seal or append mints its row's token", not escape, escape)
    print("escape-hatch\tnone" if not escape else f"escape-hatch\tfound\t{'; '.join(escape)[:400]}", flush=True)

    parent_guard = 'if commit != bound["anchor_commit"] or ref != tools.ANCHOR_REF or ref != bound_ref:'
    parent_plant = planted_copy("review-parent-binding", [("lib/loopauth/store.py", (parent_guard, 'if False:'))])
    parent_result = subprocess.run([sys.executable, FZ, "parent-control", parent_plant, os.path.join(TMP, "parent-probe")],
                                   capture_output=True, timeout=300)
    parent_output = parent_result.stdout.decode("utf-8", "replace")
    emit("F3", "planted control: removing anchor ownership fails the durable-parent probe",
         any(line.startswith("not ok") and "durable parent's child refuses" in line for line in parent_output.splitlines()),
         (parent_result.returncode, parent_output[-600:], parent_result.stderr[-300:]))

    # ---------------------------------------------------------------- F6 (the seam)
    saved = os.environ.pop("LOOP_AUTHORITY_TEST", None)
    os.environ["LOOP_AUTHORITY_CRASH_AT"] = "recovery-after-delimiter"
    try:
        store.configure_crash("recover")
        unset = store._CRASH["point"]
        os.environ["LOOP_AUTHORITY_TEST"] = "1"
        store.configure_crash("recover")
        honoured = store._CRASH["point"]
    finally:
        os.environ.pop("LOOP_AUTHORITY_CRASH_AT", None)
        os.environ.pop("LOOP_AUTHORITY_TEST", None)
        if saved is not None:
            os.environ["LOOP_AUTHORITY_TEST"] = saved
        store._CRASH.update(point=None, frame_byte=None)
    emit("F6", "the cut between recovery's delimiter completion and its push is the closed-list crash point "
         "recovery-after-delimiter, honoured only with LOOP_AUTHORITY_TEST=1",
         "recovery-after-delimiter" in store.CRASH_APPLICABLE["recover"] and unset is None
         and honoured == "recovery-after-delimiter", (unset, honoured))

    # ---------------------------------------------------------------- F6 (the every-byte crash matrix)
    suite_text = read_text(AUTHORITY_SUITE)
    workflow_text = read_text(WORKFLOW) if os.path.isfile(WORKFLOW) else None
    for description, ok, detail in crash_matrix_checks(suite_text, workflow_text):
        emit("F6", f"every-byte crash matrix (authority-selftest.sh --crash-matrix): {description}", ok, detail)
    weak_marker = suite_text.replace("ok = recovered.rc ==", "ok = True or recovered.rc ==")
    weak_marker = weak_marker.replace('    if kind == "revocation" and os.path.lexists(os.path.join(case.store_dir(), "quarantine")):\n        problems.append("a quarantine marker exists while the revocation frame is incomplete")\n', '')
    weak_checks = crash_matrix_checks(weak_marker, workflow_text)
    emit("F6", "planted compound bypass: wrong-marker cuts must make the matrix check fail",
         any(not ok for _description, ok, _detail in weak_checks), [description for description, ok, _detail in weak_checks if not ok])
    kinds_line = 'MATRIX_KINDS = ("genesis", "rotation", "revocation")'
    enumerator = 'for n in (*range(1, sizes[kind] - 1), "last")]'
    for label, (needle, replacement), text in (
            ("without the revocation kind", (kinds_line, 'MATRIX_KINDS = ("genesis", "rotation")'), suite_text),
            ("sampling the revocation frame's bytes",
             (enumerator, 'for n in ((*range(1, sizes[kind] - 1), "last") if kind != "revocation" else '
                          '(1, sizes[kind] // 2, "last"))]'), suite_text),
            ("revoking an epoch that is not the template's active one",
             ('"revocation": ("revoke", "--epoch", "1")', '"revocation": ("revoke", "--epoch", "2")'), suite_text),
            ("whose CI plan job accepts two sizes",
             ("^[1-9][0-9]*,[1-9][0-9]*,[1-9][0-9]*$", "^[1-9][0-9]*,[1-9][0-9]*$"), workflow_text)):
        if text is None:
            continue
        planted = text.replace(needle, replacement, 1)
        checks = crash_matrix_checks(planted if text is suite_text else suite_text,
                                     planted if text is workflow_text else workflow_text)
        failed = [description for description, ok, _detail in checks if not ok]
        emit("F6", f"planted control: a crash matrix {label} fails the structural check", needle in text and failed,
             failed[:3])
PY

cat >> "$TMP_ROOT/fz.py" <<'PY'
# ===========================================================================
# entry: the real entry points
# ===========================================================================

def mode_entry():
    journal = Journal(TMP)
    root = os.path.join(TMP, "c")
    registry = live_registry()

    def fresh_store(checks):
        """recover takes no option; an absent store stays absent under every
        read-only entry point."""
        fresh = Case(root, "fresh", journal)
        for args in (("recover", "--row", "torn-frame-truncation"), ("recover", "torn-frame-truncation"),
                     ("recover", "--seq", "2"), ("recover", "--digest", "sha256:" + "0" * 64),
                     ("recover", "--path", "/tmp/x"), ("recover", "--evidence", "{}"), ("recover", "--intent", "x"),
                     ("recover", "--row=anchor-replay-forward")):
            res = fresh.writer(*args)
            checks("F3", f"`loop-authority {' '.join(args)}` is a usage error (exit 2): recover accepts no row, "
                   "sequence, digest, path, or evidence", res.rc == 2 and not os.path.exists(auth(fresh.home)), res)
        for row in DERIVED_ROWS + ("delimiter-completion",):
            res = fresh.writer("ceremony", row)
            checks("F3", f"`loop-authority ceremony {row}` is a usage error (exit 2): no ceremony reaches a derived row",
                   res.rc == 2 and not os.path.exists(auth(fresh.home)), res)
        res = fresh.writer("ceremony", "acceptance-platform-designation")
        checks("F4", "the one dormant ceremony row (acceptance-platform designation) has no ceremony entry (exit 2)",
               res.rc == 2, res)
        observation = fresh.observe(read_only_checks=True)
        checks("F2", "with no authority directory, status, verify, refs, the verifier, and submit leave everything "
               "byte-identical and create no authority directory",
               not observation.read_only_problems() and not os.path.exists(auth(fresh.home))
               and observation.state == "none", (observation.read_only_problems(), observation.state))

    def ceremonies(checks):
        """Each ceremony through the real entry point mints one ceremony token
        of its row."""
        case = Case(root, "ceremonies", journal)
        head = "authority-head-advance"
        runs = (("genesis", ("ceremony", "genesis", "--remote", case.url), "authority-genesis", [head]),
                ("rotate", ("ceremony", "rotate"), "epoch-rotation", [head]),
                ("revoke --epoch 1 (the verify-only epoch)", ("ceremony", "revoke", "--epoch", "1"),
                 "epoch-revocation", [head]),
                ("revoke --epoch 2 (the active epoch)", ("ceremony", "revoke", "--epoch", "2"), "epoch-revocation",
                 [head, "store-quarantine"]),
                ("regenesis", ("ceremony", "regenesis"), "linked-regenesis", [head]))
        genesis_commands = []
        for name, args, row, children in runs:
            res, trace = case.cli(*args, tty=True)
            want = [f"ceremony: {row}"] + [f"child({row}): {child}" for child in children]
            checks("F2", f"`loop-authority ceremony {name}` (the real entry, TTY stubbed) mints exactly one ceremony "
                   f"token, of row {row}, and only the compound children its row names",
                   res.rc == 0 and trace.labels == want
                   and all(child in registry.ROW_BY_ID[row]["children"] for child in children), (res, trace.labels))
            if name == "genesis":
                genesis_commands = trace.commands
        checks("F5", "the recording fixture is not vacuous: during genesis it saw ssh-keygen sign, sign the pointer, "
               "generate, and certify through tools.run", all(command in genesis_commands for command in SIGNING_COMMANDS),
               sorted(set(genesis_commands)))

    def read_only(checks):
        """The read-only entry points mint nothing, even where a row applies."""
        pending = Case(root, "pending", journal)
        pending.steps([("genesis", "-"), ("rotate", "after-frame-fsync")])
        before = [tree_digest(r) for r in pending.roots()]
        for args, rc in ((("status",), 0), (("verify",), 5),
                         (("refs", "--workspace", journal.ws, "--run", journal.run_id), 0)):
            res, trace = pending.cli(*args)
            checks("F2", f"`loop-authority {args[0]}` maps to no row: on a store whose replay-forward is due it mints no "
                   "token, completes no sink, and runs no sink command",
                   res.rc == rc and not trace.tokens and not set(trace.commands) & set(SINK_COMMANDS)
                   and not trace.events, (res, trace.labels, sorted(set(trace.commands))))
        checks("F2", "and leaves the authority directory, the journal store, and the remote byte-identical",
               before == [tree_digest(r) for r in pending.roots()])

    def submit(checks):
        """submit, the typed-row entry, refuses every row."""
        committed = Case(root, "submit", journal)
        committed.steps([("genesis", "-")])
        before = [tree_digest(r) for r in committed.roots()]
        errors = set()
        for row in DORMANT_ROWS:
            res = committed.writer("submit", row)
            match = re.search(r"error: (dormant-row:[a-z-]+):", res.err)
            errors.add(match.group(1) if match else None)
            checks("F4", f"dormant row {row} is refused through `loop-authority submit` with its distinct error "
                   "(exit 8)", res.rc == 8 and match and match.group(1) == f"dormant-row:{row}", res)
            if row in REQUEST_COMPOUND_ROWS:
                checks("F6", f"the request compound row {row} (A2.1's units 8, 9, 12) is refused in 0a", res.rc == 8,
                       res)
        checks("F4", "every dormant row's error is distinct", len(errors) == len(DORMANT_ROWS) and None not in errors)
        res = committed.writer("submit", "approval.consume")
        checks("F4", "approval.consume is refused with its own error (exit 10)",
               res.rc == 10 and "approval-consume-refused" in res.err, res)
        for name in ("no-such-row", "seal", "append", "epoch.rotated", "delimiter-completion"):
            res = committed.writer("submit", name)
            checks("F4", f"an unknown row name ({name}) is refused (exit 4, unknown-row): no generic entry exists",
                   res.rc == 4 and "unknown-row" in res.err, res)
        for row in CEREMONY_ROWS.values():
            res = committed.writer("submit", row)
            checks("F2", f"ceremony row {row} is admitted only by its ceremony: submit refuses it (X6)",
                   res.rc == 4 and "exclusion-X6" in res.err, res)
        for row in DERIVED_ROWS:
            res = committed.writer("submit", row)
            checks("F3", f"derived row {row} has no external entry point: submit refuses it (X7)",
                   res.rc == 4 and "exclusion-X7" in res.err, res)
        checks("F4", "every refusal left the authority directory, the journal store, and the remote byte-identical",
               before == [tree_digest(r) for r in committed.roots()])

    parallel([("F3", "recover's options and the absent store", fresh_store),
              ("F2", "the ceremonies through the real entry", ceremonies),
              ("F2", "the read-only entry points", read_only),
              ("F4", "submit", submit)])


def live_registry():
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import registry  # noqa: E402
    return registry


# ===========================================================================
# verifier: the independent verifier's commands, recorded, and a read-only run
# ===========================================================================

FROZEN_PATH = "/usr/bin:/opt/homebrew/bin:/usr/local/bin"
ANCHOR_REFSPEC = "+refs/olddonkey-loop/anchor:refs/verify/anchor"
# The environment every git run gets (an allowlist; SSH_AUTH_SOCK is the one
# variable passed through, when set), and every ssh-keygen run.
FROZEN_GIT_ENV = {"PATH": FROZEN_PATH, "LANG": "C", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                  "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
FROZEN_KEYGEN_ENV = {"PATH": FROZEN_PATH, "LANG": "C", "LC_ALL": "C"}
# Variables that would steer git if inherited: set around the verifier, never
# passed to git.
GIT_DECOYS = {"GIT_SSH_COMMAND": "false", "GIT_SSH": "false", "GIT_ASKPASS": "false", "GIT_PROXY_COMMAND": "false",
              "GIT_CONFIG_COUNT": "0", "https_proxy": "http://127.0.0.1:9", "HTTPS_PROXY": "http://127.0.0.1:9",
              "GIT_EXEC_PATH": "/nonexistent"}


def frozen_transport_plan(url, transport, bins, home, ssh_auth_sock=None):
    """The verifier's transport plan, frozen test-side: its three git argv
    forms, the fetch with the complete transport options of a file://, SSH,
    or HTTPS remote, and the git environment -- given the binaries it
    resolves ({git, ssh, gh: path or None})."""
    prefix = [bins["git"], "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    options = ["-c", "protocol.allow=never", "-c", f"protocol.{transport}.allow=always"]
    if transport == "ssh":
        options += ["-c", f"core.sshCommand={bins['ssh']} -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes"
                          " -o UpdateHostKeys=no"]
    elif transport == "https":
        options += ["-c", "http.sslVerify=true", "-c", "http.followRedirects=false"]
        if bins.get("gh"):
            options += ["-c", "credential.helper=", "-c", f"credential.helper=!{bins['gh']} auth git-credential"]
    env = dict(FROZEN_GIT_ENV, HOME=home, TMPDIR="<temp>")
    if ssh_auth_sock is not None:
        env["SSH_AUTH_SOCK"] = ssh_auth_sock
    repo = ["-C", "<temp>/anchor.git"]
    return {"init": prefix + repo + ["init", "--bare", "--template=", "--object-format=sha1", "."],
            "fetch": prefix + options + repo + ["fetch", "--no-tags", "--no-write-fetch-head", url, ANCHOR_REFSPEC],
            "cat-file": prefix + repo + ["cat-file", "-p", "0" * 40], "env": env}


def verifier_form(argv, home, url):
    """Which frozen form an argv the wrapper fixture recorded is, or None."""
    temp = re.escape(os.path.join(home, ".cache", "olddonkey-loop", "verify")) + r"/[1-9][0-9]*-[0-9a-f]{16}"
    name, args = argv[0], argv[1:]
    prefix = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    repo = temp + "/anchor.git"
    if name == "git" and args[:4] == prefix:
        rest = args[4:]
        if rest[:4] == ["-c", "protocol.allow=never", "-c", "protocol.file.allow=always"]:
            rest = rest[4:]
            if len(rest) == 7 and rest[0] == "-C" and re.fullmatch(repo, rest[1]) \
                    and rest[2:] == ["fetch", "--no-tags", "--no-write-fetch-head", url,
                                     "+refs/olddonkey-loop/anchor:refs/verify/anchor"]:
                return "git fetch"
            return None
        if len(rest) == 7 and rest[0] == "-C" and re.fullmatch(repo, rest[1]) \
                and rest[2:] == ["init", "--bare", "--template=", "--object-format=sha1", "."]:
            return "git init"
        if len(rest) == 5 and rest[0] == "-C" and re.fullmatch(repo, rest[1]) and rest[2] == "cat-file" \
                and rest[3] in ("-t", "-p") and re.fullmatch(r"[0-9a-f]{40}", rest[4]):
            return "git cat-file"
    if name == "ssh-keygen":
        if len(args) == 10 and args[:3] == ["-Y", "verify", "-f"] and re.fullmatch(temp + r"/\S+", args[3]) \
                and args[4] == "-I" and args[6] == "-n" and args[8] == "-s" and re.fullmatch(temp + r"/\S+", args[9]):
            return "ssh-keygen -Y verify"
        if len(args) == 5 and args[:4] == ["-l", "-E", "sha256", "-f"] and re.fullmatch(temp + r"/\S+", args[4]):
            return "ssh-keygen -l"
    return None


def chmod_tree(root, directory_mode, file_mode):
    saved = {}
    for current, _dirs, files in os.walk(root, topdown=False):
        for name in files:
            full = os.path.join(current, name)
            saved[full] = stat.S_IMODE(os.lstat(full).st_mode)
            os.chmod(full, file_mode(saved[full]))
        saved[current] = stat.S_IMODE(os.lstat(current).st_mode)
        os.chmod(current, directory_mode(saved[current]))
    return saved


def restore_modes(saved):
    for path in sorted(saved, key=len):
        os.chmod(path, saved[path])


def mode_verifier():
    journal = Journal(TMP)
    case = Case(os.path.join(TMP, "c"), "verifier", journal)
    case.steps([("genesis", "-"), ("rotate", "-")])
    before = [tree_digest(auth(case.home)), tree_digest(case.remote)]
    # --- the transport plan, for each remote form: the verifier's own git
    # argv and environment (LOOP_AUTHORITY_TEST=1; nothing is run, so the SSH
    # and HTTPS remotes need no network), against the frozen forms: with the
    # host's binaries, and with fixture binaries (LOOP_AUTHORITY_TEST_BIN_DIR,
    # gh included, never run) while SSH_AUTH_SOCK and variables that would
    # steer git are set around it.
    plan_bin = os.path.join(TMP, "plan-bin")
    os.makedirs(plan_bin)
    for name in ("git", "ssh", "gh"):
        write_private(os.path.join(plan_bin, name), b"#!/bin/sh\nexit 97\n")
        os.chmod(os.path.join(plan_bin, name), 0o755)
    host = {name: resolve_bin(name) for name in ("git", "ssh", "gh")}
    fixture = {name: os.path.join(plan_bin, name) for name in ("git", "ssh", "gh")}
    sock = os.path.join(TMP, "agent.sock")
    for transport, url in (("file", case.url), ("ssh", "git@anchor.example.invalid:olddonkey/anchor.git"),
                           ("https", "https://anchor.example.invalid/olddonkey/anchor.git")):
        for label, extra, bins, passed in (
                ("the host's binaries" + (", gh among them" if host["gh"] else ", no gh") if transport == "https"
                 else "the host's binaries", {}, host, None),
                ("fixture binaries (gh included) and SSH_AUTH_SOCK, GIT_SSH_COMMAND, GIT_ASKPASS, a proxy, and "
                 "GIT_EXEC_PATH set around it", dict(GIT_DECOYS, SSH_AUTH_SOCK=sock, LOOP_AUTHORITY_TEST_BIN_DIR=plan_bin),
                 fixture, sock)):
            res = run_cmd([BASH, VERIFY, "transport-plan", url], cli_env(case.home, **extra))
            want = frozen_transport_plan(url, transport, bins, case.home, passed)
            got = res.json or {}
            options = " ".join(want["fetch"][5:-7])
            emit("F1", f"the verifier's transport plan for a {transport} remote, with {label}: the complete fetch argv "
                 f"(transport options: {options}), the init and cat-file forms, and the git environment (an allowlist: "
                 "nothing inherited but SSH_AUTH_SOCK) are exactly the frozen forms",
                 res.rc == 0 and got == want,
                 (res.rc, {key: (got.get(key), want[key]) for key in want if got.get(key) != want[key]}, res.err[-200:]))
    for args, label in ((("transport-plan", case.url), "transport-plan without LOOP_AUTHORITY_TEST=1"),
                        (("anything",), "any other argument")):
        res = run_cmd([BASH, VERIFY, *args], cli_env(case.home, test=args[0] != "transport-plan"))
        emit("F2", f"loop-authority-verify refuses {label} (exit 2): its only forms are the table's", res.rc == 2, res)

    # --- the wrapper fixture: every git and ssh-keygen the verifier runs,
    # recorded with the environment it was given (the exported variables the
    # wrapper shell received; PWD, SHLVL, OLDPWD, and _ are that shell's own)
    bin_dir = os.path.join(TMP, "verifier-bin")
    log = os.path.join(TMP, "verifier-argv.log")
    os.makedirs(bin_dir)
    for name in ("git", "ssh-keygen"):
        path = os.path.join(bin_dir, name)
        with open(path, "w") as handle:
            handle.write("#!/bin/bash\n"
                         f"{{ printf '%s' '{name}'; for a in \"$@\"; do printf '\\037%s' \"$a\"; done; "
                         "printf '\\036'; for v in $(compgen -e); do printf '%s=%s\\035' \"$v\" \"${!v}\"; done; "
                         f"printf '\\n'; }} >> '{log}'\n"
                         f"exec '{resolve_bin(name)}' \"$@\"\n")
        os.chmod(path, 0o755)
    plain = case.verifier()
    recorded = case.verifier(LOOP_AUTHORITY_TEST_BIN_DIR=bin_dir, **GIT_DECOYS)
    # (split on "\n" only: str.splitlines would also split on the separators)
    lines = [line.split("\x1e") for line in (read_bytes(log) or b"").decode().split("\n") if line]
    argvs = [parts[0].split("\x1f") for parts in lines]
    envs = [dict(item.split("=", 1) for item in (parts[1] if len(parts) > 1 else "").split("\x1d") if "=" in item)
            for parts in lines]
    forms = [verifier_form(argv, case.home, case.url) for argv in argvs]
    emit("F1", f"the verifier's {len(argvs)} recorded commands (wrapper fixtures for git and ssh-keygen) are each one of "
         "its five frozen argv forms, and every form was seen",
         argvs and None not in forms and set(forms) == {"git init", "git fetch", "git cat-file",
                                                        "ssh-keygen -Y verify", "ssh-keygen -l"},
         [argv for argv, form in zip(argvs, forms) if form is None][:3])
    temp = re.escape(os.path.join(case.home, ".cache", "olddonkey-loop", "verify")) + r"/[1-9][0-9]*-[0-9a-f]{16}"
    wrong_env = []
    for argv, env in zip(argvs, envs):
        env = {key: value for key, value in env.items() if key not in ("PWD", "SHLVL", "OLDPWD", "_")}
        want = dict(FROZEN_GIT_ENV if argv[0] == "git" else FROZEN_KEYGEN_ENV, HOME=case.home)
        if env.get("TMPDIR") is None or not re.fullmatch(temp, env["TMPDIR"]) \
                or {key: value for key, value in env.items() if key != "TMPDIR"} != want:
            wrong_env.append((argv[:6], sorted(set(env.items()) ^ set(want.items()))[:6]))
    emit("F1", "and each ran with exactly its frozen environment (git: PATH, HOME, LANG, LC_ALL, the temporary TMPDIR, "
         "GIT_CONFIG_NOSYSTEM, GIT_CONFIG_GLOBAL=/dev/null, GIT_TERMINAL_PROMPT=0; ssh-keygen: PATH, HOME, LANG, LC_ALL, "
         "TMPDIR), though GIT_SSH_COMMAND, GIT_ASKPASS, a proxy, and GIT_EXEC_PATH were set around the verifier",
         len(envs) == len(argvs) and envs and not wrong_env, wrong_env[:3])
    emit("F1", "the recorded run classified the store as the plain run did (committed; test_only under the fixture)",
         plain.json.get("state") == recorded.json.get("state") == "committed"
         and recorded.json.get("test_only") is True, (plain, recorded))

    # --- a read-only store and remote
    saved = chmod_tree(auth(case.home), lambda m: m & 0o555, lambda m: m & 0o444)
    saved.update(chmod_tree(case.remote, lambda m: m & 0o555, lambda m: m & 0o444))
    try:
        read_only_before = [tree_digest(auth(case.home)), tree_digest(case.remote)]
        read_only = case.verifier()
        read_only_after = [tree_digest(auth(case.home)), tree_digest(case.remote)]
    finally:
        restore_modes(saved)
    same = {k: plain.json.get(k) for k in ("state", "table", "seq", "epochs", "authorizing_state")} == \
        {k: read_only.json.get(k) for k in ("state", "table", "seq", "epochs", "authorizing_state")}
    emit("F1", "run against a read-only store and remote, the verifier classifies exactly as before and leaves both "
         "byte-identical (content, modes, mtimes)", same and read_only_before == read_only_after, (read_only, plain))
    emit("F1", "and none of its runs changed the authority directory or the remote",
         before == [tree_digest(auth(case.home)), tree_digest(case.remote)])


# ===========================================================================
# journal: loop-journal and loop-index never open the authority directory
# ===========================================================================

def mode_journal():
    journal = Journal(TMP)
    case = Case(os.path.join(TMP, "c"), "journal", journal)
    case.steps([("genesis", "-")])
    workspace = os.path.join(TMP, "workspace-2")
    os.makedirs(workspace)
    env = cli_env(case.home, test=False)
    before = tree_digest(auth(case.home))
    os.chmod(auth(case.home), 0)
    try:
        control = case.writer("status")
        results = [run_cmd([BASH, JOURNAL, "begin-run", "--workspace", workspace], env),
                   run_cmd([BASH, JOURNAL, "append", "--workspace", workspace, "--event", "checkpoint", "--field",
                            "note=falsifier"], env),
                   run_cmd([BASH, INDEX, "--workspace", workspace], env),
                   run_cmd([BASH, JOURNAL, "end-run", "--workspace", workspace, "--status", "completed"], env)]
    finally:
        os.chmod(auth(case.home), 0o700)
    emit("F1", "control: with the authority directory unreadable (mode 0000) the authority writer cannot classify "
         "the store (so the directory really is closed)", control.rc != 0, control)
    emit("F1", "loop-journal begin-run, append, and end-run, and loop-index, all succeed with the authority directory "
         "unreadable: none opens anything under it", all(r.rc == 0 for r in results), results)
    emit("F1", "and the authority directory is byte-identical afterwards", tree_digest(auth(case.home)) == before)
PY

cat >> "$TMP_ROOT/fz.py" <<'PY'
# ===========================================================================
# compound: every compound child refuses no token, its parent's own row
# token, another parent's token, and a spent parent token (A1.5)
# ===========================================================================

def parent_binding_probe(case):
    sys.path.insert(0, LIB)
    from loopauth import ceremony, store, tools
    tools.cleanup()
    os.environ["HOME"] = case.home
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    tools._PINNED.clear()
    tools.pin_remote(tools.parse_remote(case.url, allow_test=True))
    ceremony.challenge = lambda envelope: None
    original = store.push_anchor
    observed = []
    def inspect_child(token, **params):
        # The real ceremony has already bound its anchor and made its frame
        # durable. Only ownership of this different anchor can refuse here.
        observed.append(refused(lambda: original(token, **dict(params, commit="f" * 40)), "stage-mismatch"))
        return original(token, **params)
    store.push_anchor = inspect_child
    try:
        with store.WriterLock():
            ceremony.rotate(PRINCIPAL)
    finally:
        store.push_anchor = original
        tools.cleanup()
    return observed


def mode_parent_control():
    case = Case(os.path.join(TMP, "parent-control"), "durable parent")
    case.steps([("genesis", "-")])
    observed = parent_binding_probe(case)
    emit("F3", "durable parent's child refuses another anchor exactly at stage-mismatch",
         observed == [(True, "stage-mismatch")], observed)


def mode_compound():
    root = os.path.join(TMP, "c")
    fixtures = {"committed": [("genesis", "-"), ("rotate", "-")],
                "unterm": [("genesis", "-"), ("rotate", "frame-byte-last")],
                "complete": [("genesis", "-"), ("rotate", "after-frame-fsync")],
                "torn": [("genesis", "-"), ("rotate", "frame-byte-mid")],
                "row9": [("genesis", "genesis-step-5")],
                "tail": [("genesis", "-")], "other-parent": [("genesis", "-")]}

    def build(label):
        case = Case(root, label)
        case.steps(fixtures[label])
        return case

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        made = dict(zip(fixtures, pool.map(build, fixtures)))
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, recover, store, tools  # noqa: E402
    ceremony.challenge = lambda envelope: None

    def use(label):
        """Switch this process to a fixture: its HOME and its pinned remote
        (the scratch space of the previous one is removed under its own HOME)."""
        tools.cleanup()
        case = made[label]
        os.environ["HOME"] = case.home
        tools._PINNED.clear()
        tools.pin_remote(tools.parse_remote(case.url, allow_test=True))
        return case

    def plan_of():
        scratch = recover.Scratch()
        try:
            return recover.observe(scratch)
        finally:
            scratch.close()

    def snap(case):
        return store.snapshot_digest(), remote_tip(case.remote)

    def check(description, function, *codes):
        ok, code = refused(function, *codes)
        emit("F3", description, ok, code)

    # --- the head advance (the child of every record row), with the anchor push
    case = use("committed")
    before = snap(case)
    scratch = tools.new_scratch_repo()
    tip = remote_tip(case.remote)
    push = dict(scratch=scratch, commit=tip, ref=ANCHOR_REF)
    check("head advance: the anchor push with no token is refused", lambda: store.push_anchor(None, **push), "token")
    rotation = store.begin("epoch-rotation", PRINCIPAL)
    check("head advance: the anchor push with its parent's own row token (epoch-rotation) is refused",
          lambda: store.push_anchor(rotation, **push), "token-row")
    head = store.child(rotation, "authority-head-advance")
    check("head advance: a child used outside its parent's transaction (the parent's frame not durable) is refused",
          lambda: store.push_anchor(head, **push), "protocol-order")
    other = use("other-parent")
    observed = parent_binding_probe(other)
    emit("F3", "head advance: another parent's durable, bound child cannot push this anchor (stage-mismatch only)",
         observed == [(True, "stage-mismatch")], observed)
    case = use("committed")
    spent_parent = store.begin("epoch-rotation", PRINCIPAL)
    spent_head = store.child(spent_parent, "authority-head-advance")
    store.spend(spent_parent)
    check("head advance: a child of a spent parent is refused", lambda: store.push_anchor(spent_head, **push), "token")
    check("head advance: a spent parent opens no child", lambda: store.child(spent_parent, "authority-head-advance"),
          "token")
    check("head advance: it cannot be begun on its own (X7)", lambda: store.begin("authority-head-advance", PRINCIPAL),
          "exclusion-X7")

    # --- the revocation's quarantine child
    sid = json.loads(read_bytes(auth(case.home, "active")))["store_id"]
    marker = store.active_revocation_marker(sid, 3)
    write = dict(store_id=sid, data=marker)
    check("revocation quarantine: the marker with no token is refused", lambda: store.write_quarantine(None, **write),
          "token")
    parent = store.begin("epoch-revocation", PRINCIPAL)
    store.bind_revocation(parent, store_id=sid, generation=1, epoch=2, prior_state="active")
    check("revocation quarantine: the parent's own row token (epoch-revocation) cannot write the marker",
          lambda: store.write_quarantine(parent, **write), "token-row")
    child = store.child(parent, "store-quarantine")
    check("revocation quarantine: its child, outside the parent's transaction (no durable, read-back revocation "
          "record), is refused", lambda: store.write_quarantine(child, **write), "protocol-order")
    store.spend(parent)
    check("revocation quarantine: the child of a spent parent is refused", lambda: store.write_quarantine(child, **write),
          "token")
    check("revocation quarantine: a spent parent opens no child", lambda: store.child(parent, "store-quarantine"), "token")
    check("revocation quarantine: another parent (an epoch-rotation token) cannot open it",
          lambda: store.child(rotation, "store-quarantine"), "compound")
    unbound = store.begin("epoch-revocation", PRINCIPAL)
    check("revocation quarantine: a revocation that bound no active epoch cannot open it",
          lambda: store.child(unbound, "store-quarantine"), "compound")
    store.spend(unbound)
    verify_only = store.begin("epoch-revocation", PRINCIPAL)
    store.bind_revocation(verify_only, store_id=sid, generation=1, epoch=1, prior_state="verify-only")
    check("revocation quarantine: another parent -- the revocation of a verify-only epoch -- cannot open it",
          lambda: store.child(verify_only, "store-quarantine"), "compound")
    store.spend(verify_only)
    check("revocation quarantine: another parent's child (the rotation's head advance) cannot write the marker",
          lambda: store.write_quarantine(head, **write), "token-row")
    for row in ("segment-discharge", "mechanism-closure", "release-acceptance", "capability-issuance"):
        ok, code = refused(lambda row=row: store.child(rotation, row), f"dormant-row:{row}")
        emit("F6", f"the request compound child {row} cannot be opened in 0a (refused as dormant)", ok, code)
    for row in ("capability-redemption", "request-opening"):
        ok, code = refused(lambda row=row: store.begin(row, PRINCIPAL), f"dormant-row:{row}")
        emit("F6", f"the request compound parent {row} cannot be begun in 0a (refused as dormant)", ok, code)
    store.spend(rotation)
    emit("F3", "every refused head advance and quarantine child left the store and the remote unchanged",
         snap(case) == before and not os.path.exists(auth(case.home, "stores", sid, "quarantine")))
    captured = []
    real_child = store.child
    store.child = lambda token, row: captured.append(real_child(token, row)) or captured[-1]
    try:
        with store.WriterLock():
            ceremony.revoke(PRINCIPAL, 2)
    finally:
        store.child = real_child
    quarantine = [token for token in captured if token.row == "store-quarantine"]
    check("revocation quarantine: after the real revocation of the active epoch, its child (spent with the parent at "
          "commit) is refused", lambda: store.write_quarantine(quarantine[0], **dict(write, data=b"{}")), "token")
    emit("F3", "control: that revocation wrote exactly its one marker through the child",
         len(quarantine) == 1 and read_bytes(auth(case.home, "stores", sid, "quarantine"))
         == store.active_revocation_marker(sid, 3))

    # --- replay-forward's delimiter completion
    case = use("unterm")
    plan = plan_of()
    intent = plan.params.get("intent") or {}
    frame = base64.b64decode(intent.get("frame_b64", ""))
    sid = plan.params.get("store_id")
    emit("F3", "the unterminated fixture observes replay-forward with a delimiter completion due",
         plan.row == "anchor-replay-forward" and plan.params.get("unterminated") is True, plan.summary())
    before = snap(case)
    complete = dict(store_id=sid, frame_bytes=frame)
    check("delimiter completion: with no token it is refused", lambda: store.complete_delimiter(None, **complete),
          "token")
    rotation = store.begin("epoch-rotation", PRINCIPAL)
    check("delimiter completion: another parent's token (an epoch-rotation ceremony token) is refused",
          lambda: store.complete_delimiter(rotation, **complete), "token-row")
    check("delimiter completion: another parent's child (the rotation's head advance) is refused",
          lambda: store.complete_delimiter(store.child(rotation, "authority-head-advance"), **complete), "token-row")
    store.spend(rotation)
    token = recover._mint(plan)
    store.spend(token)
    check("delimiter completion: a spent parent (replay-forward) token is refused",
          lambda: store.complete_delimiter(token, **complete), "token")
    emit("F3", "those refusals left the log unterminated and the remote unchanged", snap(case) == before)
    case = use("torn")
    torn_plan = plan_of()
    truncation = recover._mint(torn_plan)
    check("delimiter completion: another recovery row's token (torn-frame truncation) is refused",
          lambda: store.complete_delimiter(truncation, store_id=torn_plan.params["store_id"], frame_bytes=frame),
          "token-row")
    check("head advance: a recovery row's token (torn-frame truncation) opens no child",
          lambda: store.child(truncation, "authority-head-advance"), "compound")
    store.spend(truncation)
    case = use("row9")
    finish_plan = plan_of()
    finish = recover._mint(finish_plan)
    check("delimiter completion: a ceremony-completion (finish) token is refused",
          lambda: store.complete_delimiter(finish, store_id=finish_plan.params["store_id"], frame_bytes=frame),
          "token-row")
    store.spend(finish)
    case = use("complete")
    complete_plan = plan_of()
    replay = recover._mint(complete_plan)
    complete_frame = base64.b64decode(complete_plan.params["intent"]["frame_b64"])
    check("delimiter completion: its parent row's token outside a transaction that names it (replay-forward of a "
          "complete frame) is refused", lambda: store.complete_delimiter(
              replay, store_id=complete_plan.params["store_id"], frame_bytes=complete_frame),
          "recovery-plan", "stage-mismatch")
    store.spend(replay)
    case = use("unterm")
    token = recover._mint(plan_of())
    store.complete_delimiter(token, **complete)
    log = read_bytes(auth(case.home, "stores", sid, "log", "segment-000001.olf"))
    emit("F3", "control: with its own open replay-forward token the delimiter completes (the log ends with the "
         "intent's whole frame)", log is not None and log.endswith(frame))
    check("delimiter completion: the same token after its delimiter step is refused (the step is done)",
          lambda: store.complete_delimiter(token, **complete), "stage-mismatch")
    store.spend(token)
    after = recover.classify()
    emit("F6", "a delimiter completed but not pushed is pending (A1.2 R = ptr(L - 1) with intent), never current",
         after.state == "pending" and after.row == "anchor-replay-forward" and not after.summary()["authorizing_state"],
         after.summary())

    # --- a recovery-derived quarantine token is another parent for the revocation's marker
    case = use("tail")
    sid = json.loads(read_bytes(auth(case.home, "active")))["store_id"]
    with open(auth(case.home, "stores", sid, "log", "segment-000001.olf"), "ab") as handle:
        handle.write(b"a nonconforming tail, not a frame")
    quarantine_plan = plan_of()
    recovery_quarantine = recover._mint(quarantine_plan)
    check("revocation quarantine: a recovery-derived quarantine token cannot write the revocation's marker",
          lambda: store.write_quarantine(recovery_quarantine, store_id=sid,
                                         data=store.active_revocation_marker(sid, 2)), "stage-mismatch")
    store.spend(recovery_quarantine)
    emit("F3", "and wrote nothing", not os.path.exists(auth(case.home, "stores", sid, "quarantine")))
    tools.cleanup()


# ===========================================================================
# types: a validly sealed record of every type tg-v1.0a does not admit
# ===========================================================================

def mode_types():
    case = Case(os.path.join(TMP, "c"), "types")
    case.steps([("genesis", "-"), ("rotate", "-")])
    info = lineage(case.home)
    log = auth(case.home, "stores", info["store_id"], "log", "segment-000001.olf")
    base = read_bytes(log)
    for kind in NOT_ADMITTED:
        frame, payload, sig, key_dir = forge_frame(case.home, info, kind, {"planted": kind}, seq=3, epoch=2)
        write_private(log, base + frame)
        w, v = case.writer("status"), case.verifier()
        emit("F4", f"a validly sealed {kind} record (the store's own certified {kind} subkey, epoch 2) is refused by "
             "the writer's log validation and by the independent verifier as type-not-admitted",
             seal_verifies(key_dir, kind, payload, sig)
             and w.json.get("state") == v.json.get("state") == "quarantined"
             and w.json.get("rule") == v.json.get("rule") == "type-not-admitted"
             and w.json.get("seq") == v.json.get("seq") == 2, (w, v))
    frame, payload, sig, key_dir = forge_frame(case.home, info, "epoch.revoked",
                                               {"ceremony": "revoke", "envelope_digest": D({"x": 1}),
                                                "principal": PRINCIPAL, "epoch": 1, "prior_state": "verify-only"},
                                               seq=3, epoch=2)
    write_private(log, base + frame)
    w = case.writer("status")
    emit("F4", "control: the same forger's admitted record (epoch.revoked) passes type admission and every seal check -- "
         "the log verifies to it (L = 3) and only the missing anchor quarantines it (rollback-one)",
         seal_verifies(key_dir, "epoch.revoked", payload, sig) and w.json.get("seq") == 3
         and w.json.get("rule") == "rollback-one", w)
    frame, _payload, _sig, _key_dir = forge_frame(case.home, info, "nonce.issued", {"planted": "nonce"}, seq=3, epoch=2)
    write_private(log, base + frame)
    res = case.writer("recover")
    marker = read_json(auth(case.home, "stores", info["store_id"], "quarantine")) or {}
    status = case.writer("status")
    emit("F4", "recovery quarantines a store holding a nonce.issued record (marker rule type-not-admitted) and "
         "never admits it", res.rc == 6 and marker.get("rule") == "type-not-admitted"
         and status.json.get("state") == "quarantined", (res, marker, status))


# ===========================================================================
# sweep: every byte of the frames a compound can be cut in
# ===========================================================================

def mode_sweep():
    """Every byte of each frame a compound can be cut in: its intent is made
    durable (the ceremony crashed right after it), then every prefix of its
    exact frame is classified offline by the writer's own tail classifier
    (A1.6; A2.3's frame-1 classifier for genesis); the active epoch's
    revocation is also classified in full, on the real store, at sampled
    byte counts."""
    root = os.path.join(TMP, "c")
    fixtures = {"revocation-active": [("genesis", "-"), ("revoke", "after-intent-fsync", "1")],
                "revocation": [("genesis", "-"), ("rotate", "-"), ("revoke", "after-intent-fsync", "1")],
                "rotation": [("genesis", "-"), ("rotate", "after-intent-fsync")],
                "genesis": [("genesis", "genesis-step-2")]}

    def build(kind):
        case = Case(root, f"sweep {kind}")
        case.steps(fixtures[kind])
        return case

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        made = dict(zip(fixtures, pool.map(build, fixtures)))
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import frame as frame_module  # noqa: E402
    from loopauth import recover, tools  # noqa: E402
    outcomes = {"revocation-active": ("recovery truncates it: neither part",
                                      "recovery completes the delimiter, anchors, then quarantines: both parts"),
                "revocation": ("recovery truncates it: neither part",
                               "recovery completes the delimiter and anchors: both parts"),
                "rotation": ("recovery truncates it: neither part",
                             "recovery completes the delimiter and anchors: both parts"),
                "genesis": ("A2.3 row 6: abandonment, nothing published",
                            "A2.3 row 7: delimiter completion, replay-forward, then completion")}
    for kind, case in made.items():
        if kind == "genesis":
            intent = json.loads(read_bytes(auth(case.home, "genesis.intent")))
            frame = base64.b64decode(intent["frame_b64"])
            classes = [recover.classify_frame1_bytes(frame[:n], frame) for n in range(1, len(frame))]
        else:
            info = lineage(case.home)
            intent = json.loads(read_bytes(auth(case.home, "stores", info["store_id"], "intent")))
            frame = base64.b64decode(intent["frame_b64"])
            base = read_bytes(auth(case.home, "stores", info["store_id"], "log", "segment-000001.olf"))
            classes = []
            for n in range(1, len(frame)):
                parsed = frame_module.parse_log(base + frame[:n])
                classes.append(recover.classify_tail(parsed.tail, parsed.tail_error, parsed.tail_offset,
                                                     len(parsed.frames), intent, frame))
        size = len(frame)
        torn, whole = outcomes[kind]
        emit("F6", f"{kind} at every frame byte: each of the {size - 2} torn prefixes of the {size}-byte frame "
             f"classifies torn ({torn}) and the {size - 1}-byte prefix unterminated ({whole})",
             classes[:-1] == ["torn"] * (size - 2) and classes[-1] == "unterminated",
             [(n + 1, got) for n, got in enumerate(classes) if got != ("torn" if n < size - 2 else "unterminated")][:5])

    case = made["revocation-active"]
    os.environ["HOME"] = case.home
    tools.pin_remote(tools.parse_remote(case.url, allow_test=True))
    info = lineage(case.home)
    intent = json.loads(read_bytes(auth(case.home, "stores", info["store_id"], "intent")))
    frame = base64.b64decode(intent["frame_b64"])
    log = auth(case.home, "stores", info["store_id"], "log", "segment-000001.olf")
    base = read_bytes(log)
    size = len(frame)
    header = frame.index(b"\n") + 1
    samples = sorted({1, 2, header - 1, header, header + 1, size // 4, size // 2, 3 * size // 4, size - 3, size - 2,
                      size - 1, size})
    wrong = []
    for n in samples:
        write_private(log, base + frame[:n])
        scratch = recover.Scratch()
        try:
            plan = recover.observe(scratch)
        finally:
            scratch.close()
        summary = plan.summary()
        want = ("needs-recovery", "torn-frame-truncation", None) if n <= size - 2 else (
            "pending", "anchor-replay-forward", n == size - 1)
        got = (plan.state, plan.row, plan.params.get("unterminated") if plan.row == "anchor-replay-forward" else None)
        records = info["L"] + (1 if n == size else 0)
        if got != want or summary["authorizing_state"] or summary["seq"] != records \
                or (n < size and summary["epochs"] != info["epochs"]):
            wrong.append((n, got, summary["seq"], summary["epochs"], summary["authorizing_state"]))
    write_private(log, base)
    emit("F6", f"revocation + quarantine, the writer's full classification of the real store at {len(samples)} sampled "
         "byte counts (header edges, quarters, the last torn prefix, the unterminated frame, and the complete frame "
         "not yet anchored): a torn tail needs truncation (the old epoch still active), an unterminated or "
         "complete-but-unanchored revocation is pending replay-forward, and none authorizes", not wrong, wrong)
    tools.cleanup()
PY

cat >> "$TMP_ROOT/fz.py" <<'PY'
# ===========================================================================
# matrix: the crash matrix, recovered through the recorded real entry point
# ===========================================================================

def after_epochs(kind, base):
    epochs = dict(base["epochs"])
    if kind == "rotation":
        epochs[str(base["active_epoch"])] = "verify-only"
        epochs[str(max(int(n) for n in epochs) + 1)] = "active"
    elif kind == "revocation":
        epochs["1"] = "revoked"
    return epochs


# The quarantine marker of the active epoch's revocation has one writer per
# path, each with its own exact bytes: the ceremony's quarantine child, and
# recovery's store-quarantine row (A1.3) when it completes the compound after
# a crash (its plan's detail words it in the present tense).
MARKER_DETAIL = {"ceremony": "the active epoch was revoked", "recovery": "the active epoch is revoked"}


def revocation_marker(store_id, seq, writer="ceremony"):
    """That marker, encoded test-side (canonical JSON: store id, rule,
    position, detail)."""
    return canon({"store_id": store_id, "rule": "active-epoch-revoked", "position": {"seq": seq},
                  "detail": MARKER_DETAIL[writer]})


def marker_of(home, store_id):
    """The store's quarantine marker bytes, None when it has none."""
    return read_bytes(auth(home, "stores", store_id, "quarantine")) if store_id else None


def revocation_both(base, observation, tip, marker, intent):
    """The active epoch's revocation is both parts once its record is
    anchored: A1.2's compound T-epoch-revoked + T-quarantined commits when
    that pointer is anchored, so the quarantine is authority state from then
    on, and the local marker only recovery's materialization of it (matrix_job
    asserts its exact bytes once recovery has run to completion). Both: the
    log holds the record (seq L + 1, the epoch revoked, no active epoch, for
    the writer and the verifier alike), the remote tip names it, and the
    writer, the verifier, and refs classify the store quarantined by the
    revocation's exact rule at its position -- active-epoch-revoked at seq L +
    1 (the writer's rule and seq, and the marker's rule and position when its
    evidence is one; the verifier's rule, or its A1.3 table when no marker
    names one; refs' rule) -- with no current authorization anywhere. A marker
    present is exactly one of its two writers' bytes: any other is not the
    revocation's quarantine."""
    w, v, s = observation.w.json or {}, observation.v.json or {}, observation.store
    sid, position, revoked = base["store_id"], base["L"] + 1, str(base["active_epoch"])
    record = all(x.get("store_id") == sid and x.get("seq") == position
                 and (x.get("epochs") or {}).get(revoked) == "revoked" for x in (w, v)) and w.get("active_epoch") is None
    anchored = bool(tip) and tip["seq"] == position and tip["store_id"] == sid
    evidence = w.get("evidence")
    writer = w.get("state") == "quarantined" and w.get("rule") == "active-epoch-revoked" and (
        evidence is None or (type(evidence) is dict and (evidence.get("store_id"), evidence.get("rule"),
                                                          evidence.get("position"))
                             == (sid, "active-epoch-revoked", {"seq": position})))
    verifier = v.get("state") == "quarantined" and (
        v.get("rule") == "active-epoch-revoked"
        or (v.get("rule") is None and v.get("table") == "A1.3 active epoch revoked"))
    refs = s is not None and s.get("classification") == "quarantined" and s.get("state") == "unavailable" \
        and s.get("rule") == "active-epoch-revoked"
    unauthorized = not any(x.get("authorizing_state") or x.get("current_authorization") for x in (w, v, s or {}))
    materialized = marker is None or marker in {revocation_marker(sid, position, who) for who in MARKER_DETAIL}
    return record and anchored and writer and verifier and refs and unauthorized and materialized and intent is None


def outcome_of(kind, base, observation, case):
    """both / neither (or the kind's names for them), pending, or unsafe.
    Pending: the writer itself classifies a pending state and nothing
    authorizes (status, the verifier, and refs, which observe() reads then).
    The active epoch's revocation is both once its record is anchored
    (revocation_both: quarantined by its exact rule and position everywhere,
    marker or not) and neither only with no marker, no revocation anchored,
    and the old epoch still active; re-genesis is abandoned only with the
    remote tip still the recorded old pointer, and completed only with the
    new generation's commit on top of it."""
    w = observation.w.json or {}
    state, authorizing = w.get("state"), w.get("authorizing_state") is True
    if state in PENDING_STATES and not authorizing:
        return "pending"
    active = read_json(auth(case.home, "active"))
    tip = anchor_active(case.remote)
    seq, epochs = w.get("seq"), w.get("epochs")
    if kind == "genesis":
        intent = read_bytes(auth(case.home, "genesis.intent"))
        if state == "none" and active is None and intent is None and tip is None:
            return "none"
        if authorizing and state == "committed" and intent is None and isinstance(active, dict) and seq == 1 \
                and tip and tip["seq"] == 1 and tip["store_id"] == active.get("store_id"):
            return "committed"
    elif kind in ("rotation", "revocation"):
        if authorizing and state == "committed" and w.get("store_id") == base["store_id"] and tip \
                and tip["seq"] == seq and marker_of(case.home, base["store_id"]) is None:
            if seq == base["L"] and epochs == base["epochs"]:
                return "neither"
            if seq == base["L"] + 1 and epochs == after_epochs(kind, base) and read_bytes(auth(case.home, "stores", base["store_id"], "intent")) is None:
                return "both"
    elif kind == "revocation-active":
        marker = marker_of(case.home, base["store_id"])
        if authorizing and state == "committed" and seq == base["L"] and epochs == base["epochs"] \
                and w.get("active_epoch") == base["active_epoch"] and marker is None and tip \
                and tip["seq"] == base["L"]:
            return "neither"
        intent = read_bytes(auth(case.home, "stores", base["store_id"], "intent"))
        if revocation_both(base, observation, tip, marker, intent):
            return "both"
        if intent is not None and revocation_both(base, observation, tip, marker, None):
            return "pending" if marker is None else "residual-intent"
    elif kind == "regenesis":
        old = base["store_id"]
        intent = read_bytes(auth(case.home, "regenesis.intent"))
        live_old, archived_old = os.path.isdir(auth(case.home, "stores", old)), os.path.isdir(auth(case.home,
                                                                                                  "archive", old))
        tip_oid = remote_tip(case.remote)
        if state == "quarantined" and not authorizing and active == base["active"] and intent is None and live_old \
                and not archived_old and tip_oid is not None and tip_oid == base["tip"]:
            return "abandoned"
        if authorizing and state == "committed" and isinstance(active, dict) \
                and active.get("generation") == base["generation"] + 1 and intent is None and not live_old \
                and archived_old and read_only_tree(auth(case.home, "archive", old)) and tip \
                and tip["store_id"] == active.get("store_id") and tip["seq"] == 1 \
                and parent_of(case.remote, tip_oid) == base["tip"]:
            return "completed"
    return (f"unsafe: state {state}, authorizing {authorizing}, seq {seq}, epochs {epochs}, "
            f"tip {(tip or {}).get('store_id', '')[:8]}/{(tip or {}).get('seq')}")


def is_safe(kind, outcome):
    return outcome in ("pending",) + WHOLE[kind]


def judge(checks, spec, case, base, observation, when, final=False):
    """F6 over one observation: the writer and the independent verifier agree
    (refs too, where read: whenever the state is pending), nothing pending
    authorizes, and the outcome is safe -- or, after the last run, the
    expected one."""
    label, kind = spec["label"], spec["kind"]
    problems = observation.problems()
    agree = "the writer, the independent verifier, and refs agree" if observation.r is not None else \
        "the writer and the independent verifier agree"
    if kind == "state":
        if final:
            w = observation.w.json or {}
            ok = observation.state == spec["state"] and (spec.get("rule") is None or w.get("rule") == spec["rule"])
            checks("F6", f"{label}: {when} the store is {spec['state']}"
                   + (f" (rule {spec['rule']})" if spec.get("rule") else "") + f", and {agree}", ok and not problems,
                   (problems, observation.w))
        else:
            checks("F6", f"{label}: {when} {agree}, and a pending state authorizes nothing", not problems, problems)
        return
    outcome = outcome_of(kind, base, observation, case)
    if final:
        checks("F6", f"{label}: {when} the outcome is {spec['outcome']} (observed: {outcome})",
               outcome == spec["outcome"] and not problems, problems)
    else:
        checks("F6", f"{label}: {when} the cut is a safe outcome -- both parts, neither, or pending with no current "
               f"authorization (observed: {outcome})", is_safe(kind, outcome) and not problems, problems)


def mutate(case, name):
    home, remote = case.home, case.remote
    if name == "corrupt-genesis-intent":
        write_private(auth(home, "genesis.intent"), b"{corrupted after the intent was written")
    elif name == "rm-intent-store":
        shutil.rmtree(auth(home, "stores", read_json(auth(home, "genesis.intent"))["store_id"]))
    elif name == "active-other":
        write_private(auth(home, "active"), canon({"store_id": "f" * 32, "generation": 1}))
    elif name == "rm-new-store":
        shutil.rmtree(auth(home, "stores", read_json(auth(home, "regenesis.intent"))["new_store_id"]))
    elif name == "decoy-ref":
        set_ref(remote, decoy_commit(remote))
    elif name == "active-malformed":
        write_private(auth(home, "active"), b'{"store_id":"not a store"}')
    elif name == "garbage-tail":
        with open(auth(home, "stores", lineage(home)["store_id"], "log", "segment-000001.olf"), "ab") as handle:
            handle.write(b"a nonconforming tail, not a frame")
    elif name == "ref-parent":
        set_ref(remote, parent_of(remote, remote_tip(remote)))
    elif name == "frame1-nonconforming":
        store_id = read_json(auth(home, "genesis.intent"))["store_id"]
        write_private(auth(home, "stores", store_id, "log", "segment-000001.olf"), b"nonconforming bytes")
    elif name == "truncate-frame1":
        store_id = read_json(auth(home, "genesis.intent"))["store_id"]
        write_private(auth(home, "stores", store_id, "log", "segment-000001.olf"), b"")
    elif name == "delete-ref":
        set_ref(remote, None)
    elif name == "plant-nonce":
        info = lineage(home)
        frame, _p, _s, _k = forge_frame(home, info, "nonce.issued", {"planted": "nonce"}, seq=info["L"] + 1, epoch=1)
        with open(auth(home, "stores", info["store_id"], "log", "segment-000001.olf"), "ab") as handle:
            handle.write(frame)
    elif name == "materialize-revocation-marker":
        info = lineage(home)
        write_private(auth(home, "stores", info["store_id"], "quarantine"), revocation_marker(info["store_id"], info["L"]))
    elif name == "delete-key-file":
        info = lineage(home)
        os.unlink(auth(home, "stores", info["store_id"], "keys", key_dir_of(info, 1), "epoch.revoked-cert.pub"))
    else:
        raise RuntimeError(f"unknown mutation {name}")


def matrix_job(spec, journal):
    def job(checks):
        label, kind = spec["label"], spec["kind"]
        case = Case(os.path.join(TMP, "c"), label, journal)
        steps = list(spec["steps"])
        crashed = steps.pop() if steps and steps[-1][1] != "-" and spec.get("mutate") is None else None
        case.steps(steps)
        base = lineage(case.home)
        base["tip"] = remote_tip(case.remote)  # the recorded old pointer
        if crashed is not None:
            command, point, *extra = crashed
            rc, err = case.child(command, point, *extra)
            checks("F6", f"{label}: the cut is injected ({command} crashed at {point}, exit 137)", rc == 137, err)
        if spec.get("mutate"):
            mutate(case, spec["mutate"])
        pre = case.durable()
        observation = case.observe()
        ran = "status, loop-authority-verify, and refs" if observation.r is not None else \
            "status and loop-authority-verify"
        checks("F2", f"{label}: {ran} leave the authority directory, the journal store, and the remote byte-identical "
               f"(state {observation.state})", observation.unchanged, observation.changed)
        if first_of_state(observation):
            extra = case.observe(read_only_checks=True, previous=observation)
            checks("F2", f"every read-only entry point in state {observation.state} ({observation.table}) -- status, "
                   "verify, refs, loop-authority-verify, and submit -- leaves all three byte-identical",
                   not extra.read_only_problems() and extra.state == observation.state
                   and not extra.problems(), (label, extra.read_only_problems(), extra.problems()))
        judge(checks, spec, case, base, observation, "before recovery")
        signed, minted = [], []
        for number, run in enumerate(spec["runs"], 1):
            if run.get("away"):
                case.go_away()
            if run.get("restore"):
                case.come_back()
                observation = case.observe()
                judge(checks, spec, case, base, observation, f"with the remote restored before run {number}")
            where = f"recover run {number}" + (f" (crashing at {run['crash']})" if run.get("crash") else "") + (
                " (remote unreachable)" if case.away else "") + (
                f" (remote made unreachable at {run['away_at']})" if run.get("away_at") else "")
            res, trace = case.cli("recover", crash=run.get("crash"), away_at=run.get("away_at"))
            checks("F2", f"{label}: {where} mints exactly the ordered tokens {run['trace']} and exits {run['rc']}",
                   trace.labels == run["trace"] and res.rc == run["rc"],
                   f"got {trace.labels} sinks {trace.sinks} rc {res.rc} {res.err[-300:]}")
            if res.json.get("steps") is not None:
                steps_rows = [step.get("row") for step in res.json["steps"]]
                checks("F2", f"{label}: {where}'s reported steps are the rows of its token trace, in order",
                       steps_rows == [STEP_OF.get(item, item) for item in trace.labels], (steps_rows, trace.labels))
            signed += [command for command in trace.commands if command in SIGNING_COMMANDS]
            minted += trace.labels
            final = number == len(spec["runs"])
            # After the last run, the recovery's own final classification (a
            # fresh observation) stands in for status; after any other run the
            # store is observed afresh by status and the verifier (and refs
            # when pending).
            observation = case.observe(writer_result=res if final else None, previous=observation)
            judge(checks, spec, case, base, observation, f"after {where}", final=final)
        if kind == "revocation-active" and spec["outcome"] == "both":
            # the anchored quarantine, materialized: once recovery has run to
            # completion from this cut, the marker exists with its exact bytes
            writer = "recovery" if T_QT in minted else "ceremony"
            marker = marker_of(case.home, base["store_id"])
            checks("F6", f"{label}: once recovery has run to completion, the quarantine marker exists and is byte for "
                   "byte its writer's ("
                   + ("recovery's store-quarantine row, which ran" if writer == "recovery" else
                      "the ceremony's quarantine child: recovery ran no quarantine row")
                   + f"), naming seq {base['L'] + 1}",
                   marker == revocation_marker(base["store_id"], base["L"] + 1, writer), marker)
        elif kind == "revocation-active":
            marker = marker_of(case.home, base["store_id"])
            checks("F6", f"{label}: once recovery has run to completion, no quarantine marker exists (no revocation "
                   "was anchored)", marker is None, marker)
        if spec.get("residual_intent"):
            sid = read_json(auth(case.home, "active"))["store_id"]
            checks("F6", f"{label}: the untouched residual intent is explicit, not a both outcome",
                   read_bytes(auth(case.home, "stores", sid, "intent")) is not None and
                   marker_of(case.home, sid) == revocation_marker(sid, 2), sid)
        post = case.durable()
        allowed_frames = pre["frames"] | {i["frame"] for i in pre["intents"] if i["frame"]}
        allowed_commits = pre["commits"] | {i["commit"] for i in pre["intents"] if i["commit"]}
        checks("F5", f"{label}: every record after recovery is byte-equal to one durable before it (in the log, or the "
               "interrupted transaction's intent frame)", post["frames"] <= allowed_frames,
               [frame[:80] for frame in post["frames"] - allowed_frames])
        checks("F5", f"{label}: every anchor pointer after recovery is one durable before it (anchored, or the "
               "intent's exact commit)", post["commits"] <= allowed_commits, sorted(post["commits"] - allowed_commits))
        checks("F5", f"{label}: recovery created, removed, or changed no key file, and never signed, certified, or "
               "generated a key (the tools.run recording fixture)", post["keys"] == pre["keys"] and not signed,
               (sorted(set(post["keys"].items()) ^ set(pre["keys"].items()))[:4], signed))
    return job


def fidelity_job(spec, journal):
    """The recording fixture changes nothing: the real wrapper's recover runs
    the frozen trace's rows in the same order."""
    def job(checks):
        case = Case(os.path.join(TMP, "c"), "fidelity " + spec["label"], journal)
        case.steps(spec["steps"])
        run = spec["runs"][0]
        res = case.writer("recover")
        rows = [step.get("row") for step in res.json.get("steps", [])]
        checks("F2", f"{spec['label']}: the real `bash scripts/loop-authority recover` (no fixture) runs the rows "
               f"{[STEP_OF[item] for item in run['trace']]} in order and exits {run['rc']}, as the recorded run does",
               rows == [STEP_OF[item] for item in run["trace"]] and res.rc == run["rc"], res)
    return job


def remove_tree(path):
    for current, _dirs, _files in os.walk(path):
        os.chmod(current, 0o700)
    shutil.rmtree(path)


def outcome_controls_job(journal):
    """F6's outcome predicates against planted half-transitions of the two
    compounds whose predicates read more than the writer's classification:
    the active epoch's revocation (a marker of other bytes, a record and
    marker the anchor does not name, a marker without its record) and
    re-genesis (the remote moved on -- to the new generation's pointer, or
    back to an older one -- while the local side looks abandoned). The writer
    classifies each quarantined, which the predicates took as both or
    abandoned before they read the marker and the remote tip; none is both or
    abandoned now. An anchored record with residual intent is pending until
    tidy and marker materialization; an already written marker with residual
    intent is the explicitly pinned residual-intent quarantine case."""
    def job(checks):
        root = os.path.join(TMP, "c")

        # --- the revocation of the active epoch
        case = Case(root, "control: the active epoch's revocation", journal)
        case.steps(BASE_STEPS["revocation-active"])
        base = lineage(case.home)
        base["tip"] = remote_tip(case.remote)
        case.steps([("revoke", "-", "1")])
        sid, seq = base["store_id"], base["L"] + 1
        marker_path = auth(case.home, "stores", sid, "quarantine")
        exact = read_bytes(marker_path)
        anchored = remote_tip(case.remote)

        def seen():
            observation = case.observe()
            w = observation.w.json or {}
            tip = anchor_active(case.remote) or {}
            # what the "both" predicate read before it read the marker
            old_both = w.get("state") == "quarantined" and w.get("authorizing_state") is False \
                and w.get("seq") == seq and (w.get("epochs") or {}).get(str(base["active_epoch"])) == "revoked" \
                and w.get("active_epoch") is None and tip.get("seq") == seq
            return observation, outcome_of("revocation-active", base, observation, case), old_both

        observation, outcome, _old = seen()
        checks("F6", "control: the whole revocation of the active epoch is both -- the record anchored and the "
               "exact bytes of the marker its ceremony's quarantine child writes, encoded test-side (observed: "
               f"{outcome})", outcome == "both" and exact == revocation_marker(sid, seq, "ceremony")
               and not observation.problems(), (exact, observation.problems()))
        os.unlink(marker_path)
        observation, outcome, _old = seen()
        w, v, s = observation.w.json or {}, observation.v.json or {}, observation.store or {}
        checks("F6", "the revocation record anchored without its quarantine marker is both, never pending (A1.2: the "
               "compound commits when the pointer is anchored; the marker only materializes it): the writer, the "
               f"verifier, and refs classify the store quarantined by active-epoch-revoked at seq {seq}, the "
               f"store-quarantine row due, nothing authorizing (observed: {outcome})",
               outcome == "both" and w.get("row") == v.get("row") == "store-quarantine"
               and s.get("rule") == "active-epoch-revoked" and not observation.problems(),
               (observation.problems(), w, v, s))
        res = case.writer("recover")
        observation, outcome, _old = seen()
        checks("F6", "and recovery materializes it: its store-quarantine row writes exactly the marker recovery's row "
               f"encodes, and the compound is still both (observed: {outcome})",
               res.rc == 6 and [s.get("row") for s in res.json.get("steps", [])] == ["store-quarantine"]
               and read_bytes(marker_path) == revocation_marker(sid, seq, "recovery") and outcome == "both",
               (res, read_bytes(marker_path)))
        for label, data in (("a marker of other bytes (the position one record on)", revocation_marker(sid, seq + 1)),
                            ("a marker naming another rule",
                             canon({"store_id": sid, "rule": "fork", "position": {"seq": seq},
                                    "detail": "the active epoch was revoked"})),
                            ("a marker of neither writer's detail",
                             canon({"store_id": sid, "rule": "active-epoch-revoked", "position": {"seq": seq},
                                    "detail": "edited"}))):
            write_private(marker_path, data)
            observation, outcome, old_both = seen()
            checks("F6", f"half-transition: the revocation record with {label} is never both, nor pending (the "
                   f"writer still classifies it quarantined, which the predicate once took as both; observed: "
                   f"{outcome})", old_both and not is_safe("revocation-active", outcome), outcome)
        write_private(marker_path, exact)
        set_ref(case.remote, base["tip"])
        observation, outcome, _old = seen()
        checks("F6", "half-transition: the record and its exact marker with the remote tip one pointer behind (the "
               f"anchor never advanced) is never both (observed: {outcome})",
               not is_safe("revocation-active", outcome), outcome)
        set_ref(case.remote, anchored)
        lone = Case(root, "control: a marker without its revocation", journal)
        lone.steps(BASE_STEPS["revocation-active"])
        lone_base = lineage(lone.home)
        lone_base["tip"] = remote_tip(lone.remote)
        write_private(auth(lone.home, "stores", lone_base["store_id"], "quarantine"),
                      revocation_marker(lone_base["store_id"], lone_base["L"] + 1))
        observation = lone.observe()
        outcome = outcome_of("revocation-active", lone_base, observation, lone)
        checks("F6", "half-transition: the quarantine marker's exact bytes with no revocation record (epoch 1 still "
               f"active in the log) is never neither, nor both (observed: {outcome})",
               observation.state == "quarantined" and not is_safe("revocation-active", outcome), outcome)

        residual = Case(root, "residual-intent-control", journal)
        residual.steps([("genesis", "-")])
        residual_base = lineage(residual.home)
        residual.steps([("revoke", "after-readback", "1")])
        mutate(residual, "materialize-revocation-marker")
        seen = residual.observe()
        got = outcome_of("revocation-active", residual_base, seen, residual)
        checks("F6", "marker-before-intent-removal is reported as residual-intent, never both", got == "residual-intent", got)
        original_both = globals()["revocation_both"]
        globals()["revocation_both"] = lambda b, o, t, m, i: original_both(b, o, t, m, None)
        try:
            mutated = outcome_of("revocation-active", residual_base, seen, residual)
        finally:
            globals()["revocation_both"] = original_both
        checks("F6", "planted both-predicate omission is detected by the residual-intent control",
               got == "residual-intent" and mutated == "both", (got, mutated))

        # --- re-genesis
        case = Case(root, "control: re-genesis", journal)
        case.steps(BASE_STEPS["regenesis"])
        base = lineage(case.home)
        base["tip"] = remote_tip(case.remote)
        case.steps([("regenesis", "after-push")])
        intent = read_json(auth(case.home, "regenesis.intent")) or {}
        pushed = remote_tip(case.remote)
        os.unlink(auth(case.home, "regenesis.intent"))
        remove_tree(auth(case.home, "stores", intent["new_store_id"]))

        def seen_regenesis():
            observation = case.observe()
            w = observation.w.json or {}
            old = base["store_id"]
            # what the "abandoned" predicate read before it read the remote tip
            old_abandoned = w.get("state") == "quarantined" and w.get("authorizing_state") is False \
                and read_json(auth(case.home, "active")) == base["active"] \
                and read_bytes(auth(case.home, "regenesis.intent")) is None \
                and os.path.isdir(auth(case.home, "stores", old)) and not os.path.isdir(auth(case.home, "archive", old))
            return observation, outcome_of("regenesis", base, observation, case), old_abandoned

        observation, outcome, old_abandoned = seen_regenesis()
        checks("F6", "half-transition: re-genesis pushed (the remote tip is the new generation's pointer) while the "
               "local side looks abandoned (its intent and new store gone, the old store live and active) is never "
               "abandoned, nor completed (the writer classifies it quarantined, which the predicate once took as "
               f"abandoned; observed: {outcome})",
               pushed == intent.get("anchor_commit") and pushed != base["tip"] and old_abandoned
               and not is_safe("regenesis", outcome), (pushed, intent.get("anchor_commit"), outcome))
        set_ref(case.remote, parent_of(case.remote, base["tip"]))
        observation, outcome, old_abandoned = seen_regenesis()
        checks("F6", "half-transition: the same local side with the remote tip moved back to the old pointer's "
               f"parent is never abandoned (observed: {outcome})",
               old_abandoned and not is_safe("regenesis", outcome), outcome)
        set_ref(case.remote, base["tip"])
        observation, outcome, _old = seen_regenesis()
        checks("F6", "control: with the remote tip the recorded old pointer again, the same local side is abandoned "
               f"(observed: {outcome})", outcome == "abandoned" and not observation.problems(),
               observation.problems())
    return job


def matrix_specs(store):
    specs, coverage = [], []
    for kind, (command, *extra) in TRANSACTION.items():
        live = sorted(store.CRASH_APPLICABLE[command])
        if command in store.KEY_STEP_COMMANDS:
            live += [f"key-step-{n}" for n in range(1, store.KEY_STEPS + 1)]
        if command in store.FRAME_BYTE_COMMANDS:
            live += list(FRAME_SAMPLES)
        frozen = set(EXPECTED[kind]) - {"key-step-*"}
        if "key-step-*" in EXPECTED[kind]:
            frozen |= {f"key-step-{n}" for n in range(1, KEY_STEPS + 1)}
        coverage.append((kind, set(live), frozen))
        for point in live:
            trace, outcome = EXPECTED[kind].get("key-step-*" if point.startswith("key-step-") else point,
                                                (None, None))
            if trace is None:
                continue
            specs.append(dict(label=f"{kind} crashed at {point}", kind=kind,
                              steps=BASE_STEPS[kind] + [(command, point, *extra)],
                              runs=[run_spec(trace, RC_OF[(kind, outcome)])], outcome=outcome))
    for spec in EXTRA_SPECS:
        command, *extra = TRANSACTION[spec["kind"]]
        steps = BASE_STEPS[spec["kind"]] + ([(command, spec["point"], *extra)] if spec["point"] else [])
        specs.append(dict(spec, steps=steps))
    for spec in SPECIALS:
        specs.append(dict(spec, kind="state"))
    return specs, coverage


def mode_matrix():
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import store  # noqa: E402
    journal = Journal(TMP)
    specs, coverage = matrix_specs(store)
    for kind, live, frozen in coverage:
        emit("F2", f"every crash point of the {kind} matrix (p2 s6's closed list, the key steps, the sampled frame "
             "bytes) has a frozen expected trace, and nothing else does", live == frozen,
             (sorted(live - frozen), sorted(frozen - live)))
    emit("F2", f"the ceremonies have the frozen {KEY_STEPS} key steps", store.KEY_STEPS == KEY_STEPS, store.KEY_STEPS)
    used = {run["crash"] for spec in EXTRA_SPECS for run in spec["runs"] if run.get("crash")}
    emit("F2", "every crash point of recovery itself is run with a frozen expected trace",
         used == set(store.CRASH_APPLICABLE["recover"]), (sorted(used), sorted(store.CRASH_APPLICABLE["recover"])))
    by_label = {spec["label"]: spec for spec in specs}
    fidelity = [by_label[label] for label in ("rotation crashed at frame-byte-last",
                                              "revocation-active crashed at after-frame-fsync",
                                              "genesis crashed at frame-byte-last",
                                              "regenesis crashed at regenesis-step-4")]
    jobs = [("F6", "outcome predicates against planted half-transitions", outcome_controls_job(journal))]
    jobs += [("F6", spec["label"], matrix_job(spec, journal)) for spec in specs]
    jobs += [("F2", "fidelity " + spec["label"], fidelity_job(spec, journal)) for spec in fidelity]
    parallel(jobs)


# ===========================================================================
# child and cli (internal)
# ===========================================================================

def mode_child():
    """child <home> <url> <command> <point|-> [epoch]: one ceremony core in
    this process (the TTY challenge stubbed), crashing at <point>. A sampled
    frame byte (frame-byte-first|mid|penult|last) is resolved to its offset
    in the frame this run writes, then honoured by the real crash seam."""
    home, url, command, point = ARGS[0], ARGS[1], ARGS[2], ARGS[3]
    extra = ARGS[4:]
    os.environ["HOME"] = home
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    sample = None
    if point != "-":
        match = re.fullmatch(r"frame-byte-(first|mid|penult|last)", point)
        sample = match.group(1) if match else None
        os.environ["LOOP_AUTHORITY_CRASH_AT"] = "frame-byte-1" if sample else point
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, store, tools  # noqa: E402
    ceremony.challenge = lambda envelope: None
    if sample is not None:
        real_check = store.check_frame_byte

        def check_frame_byte(frame_length):
            n = {"first": 1, "mid": frame_length // 2, "penult": frame_length - 2, "last": frame_length - 1}[sample]
            store._CRASH.update(point=f"frame-byte-{n}", frame_byte=n)
            return real_check(frame_length)

        store.check_frame_byte = check_frame_byte
    store.configure_crash(command)
    try:
        with store.WriterLock():
            if command == "genesis":
                ceremony.genesis(PRINCIPAL, url)
            elif command == "rotate":
                ceremony.rotate(PRINCIPAL)
            elif command == "revoke":
                ceremony.revoke(PRINCIPAL, int(extra[0]))
            elif command == "regenesis":
                ceremony.regenesis(PRINCIPAL)
            else:
                raise SystemExit(f"unknown command {command}")
    finally:
        tools.cleanup()


def mode_cli():
    """cli <trace> <hooks json> <args...>: the real scripts/loop-authority.py,
    run in this process after the recording fixture is installed: every token
    minted (store._new), every sink completed (store.SINK_FUNCTIONS), every
    tools.run command, and the crash seam's cuts, appended to <trace> as they
    happen (a crash loses nothing). Hooks: tty (stub the terminal, the start
    token, and the challenge for a ceremony), away_at (rename the remote away
    when the seam reaches that point)."""
    trace_path, hooks = ARGS[0], json.loads(ARGS[1])
    argv = ARGS[2:]
    sys.path.insert(0, LIB)
    sys.dont_write_bytecode = True
    from loopauth import ceremony, store, tools  # noqa: E402
    fd = os.open(trace_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)

    def record(event):
        os.write(fd, (json.dumps(event, sort_keys=True) + "\n").encode())

    real_new = store._new

    def new(token):
        bound = token.stages.get("recovery") or {}
        record({"e": "mint", "id": token.id, "kind": token.kind, "row": token.row, "action": token.action,
                "parent": token.parent.row if token.parent is not None else None,
                "unterminated": bound.get("unterminated") if token.kind == "recovery" else None})
        return real_new(token)

    store._new = new

    def wrap(name, real):
        def sink(*args, **kwargs):
            result = real(*args, **kwargs)
            token = args[0] if args else kwargs.get("token")
            record({"e": "sink", "fn": name, "id": getattr(token, "id", None)})
            return result
        return sink

    for name in store.SINK_FUNCTIONS:
        setattr(store, name, wrap(name, getattr(store, name)))
    real_run = tools.run

    def run(command_id, **kwargs):
        record({"e": "run", "cmd": command_id, "token": getattr(kwargs.get("token"), "id", None)})
        return real_run(command_id, **kwargs)

    tools.run = run
    real_crash = store.crash

    def crash(point):
        if hooks.get("away_at") == point:
            os.rename(hooks["remote"], hooks["remote"] + ".away")
            record({"e": "away", "point": point})
        if store._CRASH["point"] == point:
            record({"e": "crash", "point": point})
        return real_crash(point)

    store.crash = crash
    if hooks.get("tty"):
        real_isatty = os.isatty
        os.isatty = lambda fd_: fd_ in (0, 1) or real_isatty(fd_)
        os.ttyname = lambda fd_: "/dev/ttys000"
        ceremony.read_boot_id = lambda: "TESTBOOT-0000"
        ceremony.read_start_time = lambda pid: 1
        ceremony.challenge = lambda envelope: record({"e": "challenge", "ceremony": envelope["ceremony"]})
    sys.argv = [AUTH_PY, *argv]
    try:
        runpy.run_path(AUTH_PY, run_name="__main__")
        code = 0
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else (0 if error.code is None else 1)
    sys.stdout.flush()
    sys.stderr.flush()
    raise SystemExit(code)


MODES = {"parent-control": ("F3", mode_parent_control), "static": ("F1", mode_static), "entry": ("F2", mode_entry), "verifier": ("F1", mode_verifier),
         "journal": ("F1", mode_journal), "compound": ("F3", mode_compound), "types": ("F4", mode_types),
         "sweep": ("F6", mode_sweep), "matrix": ("F6", mode_matrix)}
if MODE == "child":
    mode_child()
elif MODE == "cli":
    mode_cli()
else:
    claim, function = MODES[MODE]
    guarded(claim, function)
PY

run_mode() { # $1=mode: its checks to $TMP_ROOT/<mode>.tsv, its exit status to <mode>.status
  python3 "$TMP_ROOT/fz.py" "$1" "$SKILL" "$TMP_ROOT/$1" > "$TMP_ROOT/$1.tsv" 2> "$TMP_ROOT/$1.stderr"
  printf '%d\n' "$?" > "$TMP_ROOT/$1.status"
}

# The crash matrix (the long pole, its own worker pool) runs beside the other
# modes; every mode is then tallied in this fixed order, each with the claim
# a crash of its program counts against.
run_mode matrix &
MATRIX_PID=$!
for mode in static entry verifier journal compound types sweep; do
  run_mode "$mode"
done
wait "$MATRIX_PID"
for pair in static:1 entry:2 verifier:1 journal:1 compound:3 types:4 sweep:6 matrix:6; do
  mode="${pair%%:*}"
  status="$(cat "$TMP_ROOT/$mode.status" 2>/dev/null || printf '1')"
  tally "$TMP_ROOT/$mode.tsv" "$TMP_ROOT/$mode.stderr" "$status" "falsifier $mode checks" "${pair##*:}"
done

ALL_CLAIMS=1
for index in 1 2 3 4 5 6; do
  if [[ ${CLAIM_CHECKS[$index]} -gt 0 && ${CLAIM_FAILED[$index]} -eq 0 ]]; then
    printf 'F%d: PASS (%d checks) -- %s\n' "$index" "${CLAIM_CHECKS[$index]}" "${CLAIM_NAMES[$index]}"
  else
    ALL_CLAIMS=0
    printf 'F%d: FAIL (%d of %d checks failed) -- %s\n' "$index" "${CLAIM_FAILED[$index]}" \
      "${CLAIM_CHECKS[$index]}" "${CLAIM_NAMES[$index]}"
  fi
done
if [[ "$ESCAPE_HATCH" == none && ${CLAIM_FAILED[4]} -eq 0 ]]; then
  printf 'escape-hatch: none\n'
else
  ALL_CLAIMS=0
  printf 'escape-hatch: FOUND (%s)\n' "$ESCAPE_HATCH"
fi

if [[ $FAILED_CHECKS -gt 0 || $ALL_CLAIMS -eq 0 ]]; then
  printf 'falsifier: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'falsifier: PASS (%d checks)\n' "$CHECKS"
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
