#!/usr/bin/env bash
# Hermetic checks for the verification of claimed authority references
# (task-graph-v1 Phase A, sub-unit 0a.3: lib/loopauth/refs.py,
# eligibility.py, journal_read.py, and `loop-authority refs`).
#
# - static: the closed reference map equals a frozen oracle written out
#   below; every kind of 0a.1's REFERENCE_KINDS and every evidence field of
#   its rows and matrices appears in it exactly once; an unlisted kind,
#   field, event, or store classification fails closed; eligibility is an
#   explicit constant gate;
# - claims: a run carrying every reference kind 0a.1 accepts and every
#   evidence field, reduced in-process: each request, answer (every claimed
#   outcome), and expiry reference and each review.recorded request_id is
#   rejected (rows-dormant) and refutes its node; everything else stays
#   claimed; no node is completion-eligible; a kind or field 0a.1's
#   vocabulary gains but the map does not list is an error;
# - command: that run and a schema-1-only run written through the real
#   `loop-journal append` (`--schema 2` for the first), then the real
#   `loop-authority refs` against a store that is current, absent, pending
#   (remote unreachable, and replay-forward), quarantined, and in each
#   bootstrap terminal state: the store state is reported each time, the
#   claims are identical each time, and the journal store, the authority
#   directory, and the remote are byte-identical afterwards; refs takes
#   neither the authority lock nor the journal's lock; bad input fails
#   closed without repairing anything.
#
# Fixture stores are made by the ceremony core in a child process with the
# TTY challenge stubbed (as registry-selftest.sh makes them; the
# operator-TTY ceremony is authority-selftest.sh's). HOME is a scratch
# directory; each remote is a file:// bare repository (a test lineage).

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LIB="$SCRIPT_DIR/../lib"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/refs-selftest.XXXXXX")" || exit 1
# A normalized, symlink-free path: the file:// remotes built from it must
# pass the writer's remote-path check.
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
unset LOOP_UNIT LOOP_ROUND LOOP_CONTEXT LOOP_JOURNAL_LOCK_TIMEOUT_SEC

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

cat > "$TMP_ROOT/rf.py" <<'PY'
"""refs-selftest driver: rf.py <mode> <lib> <tmp> [args]"""

from __future__ import annotations

import ast
import concurrent.futures
import copy
import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
import traceback

MODE = sys.argv[1]
LIB = os.path.realpath(sys.argv[2])
TMP = os.path.realpath(sys.argv[3])  # normalized: remote paths are built from it
ARGS = sys.argv[4:]
SCRIPTS = os.path.join(os.path.dirname(LIB), "scripts")
AUTHORITY = os.path.join(SCRIPTS, "loop-authority")
JOURNAL = os.path.join(SCRIPTS, "loop-journal")
PRINCIPAL = {"kind": "operator-tty", "tty": "/dev/ttys000",
             "start_token": {"boot_id": "TESTBOOT-0000", "pid": 1, "start_time": 1}}
ANCHOR_REF = "refs/olddonkey-loop/anchor"

sys.path.insert(0, LIB)
sys.dont_write_bytecode = True
from loopauth import eligibility, reduce, refs, vocabulary  # noqa: E402


def emit(description, ok, detail=""):
    description = " ".join(str(description).split())
    if ok:
        print(f"ok\t{description}", flush=True)
    else:
        print(f"not ok\t{description}\t{' '.join(str(detail).split())[:900]}", flush=True)


def refused(function, *codes):
    try:
        function()
    except Exception as error:  # noqa: BLE001
        code = getattr(error, "code", type(error).__name__)
        return (not codes or code in codes), code
    return False, "not refused"


def D(value):
    return "sha256:" + hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def canon(value):
    """An independent canonical encoder (sorted keys, no whitespace, UTF-8)."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


# ===========================================================================
# The frozen oracle (0a.3 section 2), written out literally
# ===========================================================================

CLAIMED = {"authority": False, "validity": "claimed", "reason": None}
DORMANT = {"authority": True, "validity": "rejected", "reason": "rows-dormant"}
JOURNAL_RECORD = "a journal record (units 6, 9)"
PROCESS_GUARD = "a process guard (unit 9, P5)"
ORACLE_REFERENCE_MAP = {
    "selection": dict(CLAIMED, names="a coordinator decision (unit 10)", fields=["selection_ref"]),
    "authorization": dict(CLAIMED, names="an effect authorization (units 3, 7, 8)", fields=["authorization_ref"]),
    "request": dict(DORMANT, names="a request.opened record", fields=["request_ref"]),
    "answer": dict(DORMANT, names="a request.redeemed record", fields=["answer_ref"]),
    "expiry": dict(DORMANT, names="a request.expired record", fields=["expiry_ref"]),
    "cancel": dict(CLAIMED, names="a node cancellation (tg:296); no record type in Phase A", fields=["cancel_ref"]),
    "quiescence": dict(CLAIMED, names=PROCESS_GUARD, fields=["quiescence_ref"]),
    "drift": dict(CLAIMED, names="a coordinator decision (unit 10)", fields=["drift_ref"]),
    "operation-reserve": dict(CLAIMED, names=PROCESS_GUARD, fields=["barrier_closed_ref"]),
    "operation-spawned": dict(CLAIMED, names=PROCESS_GUARD, fields=["observation_ref"]),
    "operation-result": dict(CLAIMED, names=JOURNAL_RECORD, fields=["operation_result_ref", "failing_ref"]),
    "review": dict(CLAIMED, names=JOURNAL_RECORD, fields=["review_ref", "failing_ref"]),
    "gate": dict(CLAIMED, names=JOURNAL_RECORD, fields=["gate_ref", "pre_merge_gate_ref", "failing_ref"]),
    "publish": dict(CLAIMED, names=JOURNAL_RECORD, fields=["publish_ref", "failing_ref"]),
    "provider-receipt": dict(CLAIMED, names=JOURNAL_RECORD,
                             fields=["provider_receipt_ref", "failing_ref", "receipt_ref"]),
    "dispatch": dict(CLAIMED, names=JOURNAL_RECORD, fields=["dispatch_ref"]),
    "dispatch-end": dict(CLAIMED, names=JOURNAL_RECORD, fields=["failing_ref"]),
    "dispatch-abandoned": dict(CLAIMED, names=JOURNAL_RECORD, fields=["failing_ref"]),
    "reconciliation": dict(CLAIMED, names="a journal record (unit 9)", fields=["reconciliation_ref"]),
    "receipt-lookup": dict(CLAIMED, names="a journal record (unit 9)", fields=["reconciliation_ref"]),
    "attestation": dict(CLAIMED, names="a journal record (unit 9); 0a.1 refuses it as a reconciliation_ref kind "
                                       "(tg:294), so no field carries it", fields=[]),
}
ORACLE_FIELD_MAP = {
    "request_id": dict(DORMANT, source="review.recorded", names="the request.redeemed that answered it"),
    "node_type": dict(CLAIMED, source="attempt.begin", names="the pinned node type (node spec, unit 5)"),
    "stop_point": dict(CLAIMED, source="attempt.begin", names="the pinned stop point (node spec, unit 5)"),
    "identity": dict(CLAIMED, source="evidence",
                     names="a process identity {adapter, effect_child} (process guard; unit 9, P5)"),
    "target_containment": dict(CLAIMED, source="evidence", names="the target's containment {target_ref, contains}"),
    "integration_content": dict(CLAIMED, source="evidence", names="the integration content"),
    "receipt_object": dict(CLAIMED, source="evidence", names="the object the provider receipt names"),
    "branch": dict(CLAIMED, source="evidence", names="the published branch"),
    "sha": dict(CLAIMED, source="evidence", names="the candidate commit"),
    "no_permitted_actor": dict(CLAIMED, source="evidence", names="that no actor may answer the request"),
    "phase": dict(CLAIMED, source="evidence", names="the failing phase"),
    "preconditions_digest": dict(CLAIMED, source="evidence", names="a digest"),
    "revalidation_digest": dict(CLAIMED, source="evidence", names="a digest"),
    "transcript_digest": dict(CLAIMED, source="evidence", names="a digest"),
    "report_digest": dict(CLAIMED, source="evidence", names="a digest"),
    "spawn_error": dict(CLAIMED, source="evidence", names="a text"),
    "effect": dict(CLAIMED, source="evidence", names="that the failed spawn had no effect"),
    "lost_child": dict(CLAIMED, source="evidence", names="that the effect child was lost"),
    "park_reason": dict(CLAIMED, source="evidence", names="a text"),
    "unresolvable_reason": dict(CLAIMED, source="evidence", names="a text"),
    "reason": dict(CLAIMED, source="evidence", names="a text"),
}
ORACLE_CONTAINERS = ("terminal_evidence", "failure_evidence")
ORACLE_CLAIMLESS = ("operation.reserve", "operation.spawned", "operation.released", "operation.result",
                    "gate.result", "publish.recorded", "graph.diverged")
# 0a.2's classifier states -> the reason the store is unavailable (None: current).
ORACLE_CLASSIFICATIONS = {
    "committed": None, "none": "absent", "pending": "pending", "needs-recovery": "pending",
    "genesis-pending": "pending", "regenesis-pending": "pending", "quarantined": "quarantined",
    "regenesis-quarantined": "quarantined", "genesis-invalid": "genesis-invalid",
    "anchor-mismatch": "anchor-mismatch", "genesis-quarantined": "genesis-quarantined",
    "active-invalid": "active-invalid", "regenesis-invalid": "regenesis-invalid",
}
AUTHORITY_KINDS = {"request", "answer", "expiry"}
AUTHORITY_FIELDS = {"request_id"}


def literal_keys(name):
    """The keys of refs.py's dict literal `name`, as written (a key written
    twice would silently keep the last value in the live dict)."""
    with open(os.path.join(LIB, "loopauth", "refs.py"), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Dict) \
                and any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            return [key.value if isinstance(key, ast.Constant) else None for key in node.value.keys]
    return None


def live_evidence():
    """From 0a.1's live vocabulary: every (kind, field) a reference field may
    carry, every non-reference evidence field, and the containers."""
    pairs, fields, containers = set(), set(), set()

    def take(name, spec):
        if spec["type"] == "ref":
            pairs.update((kind, name) for kind in spec["kinds"])
        elif spec["type"] in ("terminal_evidence", "failure_evidence"):
            containers.add(name)
        else:
            fields.add(name)

    for row in vocabulary.ROWS:
        for name, spec in row["evidence"].items():
            take(name, spec)
    for entry in vocabulary.TERMINAL_EVIDENCE.values():
        for name, spec in entry["fields"].items():
            take(name, spec)
    for phases in vocabulary.FAILURE_EVIDENCE.values():
        for alternatives in phases.values():
            for alternative in alternatives:
                take("failing_ref", alternative)
                for name, spec in alternative.get("fields", {}).items():
                    take(name, spec)
    # failure_evidence = {phase, failing_ref, reason} (0a.1 section 3.3), and
    # reconciliation.result's own reference receipt_ref (kind provider-receipt).
    fields.update({"phase", "reason"})
    pairs.add(("provider-receipt", "receipt_ref"))
    return pairs, fields, containers


def main_static():
    # --- the frozen oracle
    emit("map: REFERENCE_MAP equals the frozen oracle (every kind: what it names, the 0a.1 fields that carry it, "
         "authority, validity, reason)", refs.REFERENCE_MAP == ORACLE_REFERENCE_MAP,
         sorted(k for k in set(refs.REFERENCE_MAP) | set(ORACLE_REFERENCE_MAP)
                if refs.REFERENCE_MAP.get(k) != ORACLE_REFERENCE_MAP.get(k)))
    emit("map: FIELD_MAP equals the frozen oracle (request_id, the pins, every non-reference evidence field)",
         refs.FIELD_MAP == ORACLE_FIELD_MAP,
         sorted(k for k in set(refs.FIELD_MAP) | set(ORACLE_FIELD_MAP)
                if refs.FIELD_MAP.get(k) != ORACLE_FIELD_MAP.get(k)))
    emit("map: the containers walked (never classified themselves) are terminal_evidence and failure_evidence",
         tuple(refs.CONTAINERS) == ORACLE_CONTAINERS, refs.CONTAINERS)
    emit("map: the records that carry no reference and no authority claim are the frozen list",
         tuple(refs.CLAIMLESS_EVENTS) == ORACLE_CLAIMLESS, refs.CLAIMLESS_EVENTS)
    emit("map: every 0a.2 classifier state maps to current or its unavailable reason (frozen)",
         refs.CLASSIFICATIONS == ORACLE_CLASSIFICATIONS, refs.CLASSIFICATIONS)
    # --- exactly once, against the live 0a.1 vocabulary
    for name in ("REFERENCE_MAP", "FIELD_MAP"):
        keys = literal_keys(name)
        emit(f"map: refs.py writes each {name} key exactly once (no key repeated in the literal)",
             keys is not None and None not in keys and len(keys) == len(set(keys)), keys)
    keys = literal_keys("REFERENCE_MAP") or []
    emit("map: every kind of 0a.1's vocabulary.REFERENCE_KINDS appears exactly once, and nothing else",
         sorted(keys) == sorted(vocabulary.REFERENCE_KINDS) and len(keys) == len(vocabulary.REFERENCE_KINDS),
         sorted(set(keys) ^ set(vocabulary.REFERENCE_KINDS)))
    pairs, fields, containers = live_evidence()
    listed = [(kind, field) for kind, entry in refs.REFERENCE_MAP.items() for field in entry["fields"]]
    emit("map: every reference field of 0a.1's rows and matrices is listed exactly once under each kind it may "
         "carry, and under no other", sorted(listed) == sorted(pairs) and len(listed) == len(set(listed)),
         sorted(set(listed) ^ pairs))
    evidence = [field for field, entry in refs.FIELD_MAP.items() if entry["source"] == "evidence"]
    emit("map: every non-reference evidence field of 0a.1's rows and matrices appears exactly once, and nothing "
         "else", sorted(evidence) == sorted(fields), sorted(set(evidence) ^ fields))
    emit("map: the pins are attempt.begin's node_type and stop_point, and the one non-reference authority claim "
         "is review.recorded's request_id",
         {f: e["source"] for f, e in refs.FIELD_MAP.items() if e["source"] != "evidence"}
         == {"node_type": "attempt.begin", "stop_point": "attempt.begin", "request_id": "review.recorded"})
    emit("map: the containers are exactly 0a.1's container fields",
         containers == set(refs.CONTAINERS), sorted(containers))
    reference_fields = {field for _kind, field in listed}
    emit("map: no field is both a reference field and a non-reference claim",
         not reference_fields & set(refs.FIELD_MAP), sorted(reference_fields & set(refs.FIELD_MAP)))
    # --- the two outcomes of 0a
    rejected = sorted(k for k, e in refs.REFERENCE_MAP.items() if e["validity"] == "rejected") + \
        sorted(f for f, e in refs.FIELD_MAP.items() if e["validity"] == "rejected")
    emit("validity: exactly request, answer, expiry, and request_id are rejected, reason rows-dormant, and are "
         "the only authority claims", rejected == ["answer", "expiry", "request", "request_id"]
         and all(e["reason"] == "rows-dormant" and e["authority"]
                 for e in list(refs.REFERENCE_MAP.values()) + list(refs.FIELD_MAP.values())
                 if e["validity"] == "rejected")
         and all(not e["authority"] and e["reason"] is None
                 for e in list(refs.REFERENCE_MAP.values()) + list(refs.FIELD_MAP.values())
                 if e["validity"] == "claimed"), rejected)
    emit("validity: every entry is rejected or claimed; nothing in the map reads verified",
         {e["validity"] for e in list(refs.REFERENCE_MAP.values()) + list(refs.FIELD_MAP.values())}
         == {"rejected", "claimed"})
    # --- fail closed
    for label, call, code in (
            ("a kind the map does not list", lambda: refs.classify_reference("request-v2", "request_ref"),
             "unlisted-kind"),
            ("a kind that is not a string", lambda: refs.classify_reference(["request"], "request_ref"),
             "unlisted-kind"),
            ("a listed kind in a field the map does not list for it",
             lambda: refs.classify_reference("request", "answer_ref"), "unlisted-field"),
            ("attestation in reconciliation_ref (0a.1 refuses the kind there)",
             lambda: refs.classify_reference("attestation", "reconciliation_ref"), "unlisted-field"),
            ("a field the map does not list", lambda: refs.classify_field("park_digest", "evidence"),
             "unlisted-field"),
            ("a listed field from another source (request_id as evidence)",
             lambda: refs.classify_field("request_id", "evidence"), "unlisted-field"),
            ("an event the map does not list", lambda: refs.record_claims("approval.consume", {}), "unlisted-event"),
            ("a store classification the map does not list",
             lambda: refs.describe_store({"state": "novel"}, True), "unclassified-store")):
        ok, got = refused(call, code)
        emit(f"fail closed: {label} is an error ({code}), never a silent claim", ok, got)
    # --- store state from every classification
    problems = []
    for state, reason in ORACLE_CLASSIFICATIONS.items():
        for remote_read in (True, False):
            summary = {"state": state, "authorizing_state": state == "committed", "table": "t", "rule": None,
                       "anchor_class": "test", "test_only": True, "current_authorization": False}
            got = refs.describe_store(summary, remote_read)
            want_reason = "remote-unreachable" if reason == "pending" and not remote_read else reason
            want = "current" if want_reason is None else "unavailable"
            if (got["state"], got["reason"], got["classification"], got["lineage"]) != (want, want_reason, state,
                                                                                         "test"):
                problems.append((state, remote_read, got))
    emit("store state: committed is current; every other classification is unavailable with its reason, and a "
         "pending state whose remote was never read is remote-unreachable; the lineage is reported", not problems,
         problems)
    got = refs.describe_store({"state": "committed", "authorizing_state": False}, True)
    emit("store state: a committed classification that would not authorize is not current (pending)",
         (got["state"], got["reason"]) == ("unavailable", "pending"), got)
    # --- eligibility: an explicit gate
    emit("eligibility: COMPLETION_ELIGIBLE is the constant False", eligibility.COMPLETION_ELIGIBLE is False)

    def outcome(i, guard, validity="claimed", authority=False, node="n", attempt="a"):
        return {"id": i, "node_id": node, "attempt_id": attempt, "guard": guard, "validity": validity,
                "reason": None if validity == "claimed" else "rows-dormant", "authority": authority}

    verified = {"nodes": {"n": {"node_type": "unit", "attempt_id": "a", "state": "succeeded",
                                "guards": {"g1": "verified", "g2": "verified"}}}}
    result = eligibility.apply(verified, [outcome(0, "g1"), outcome(1, "g2")])
    emit("eligibility: a hand-built succeeded node whose every guard reads verified is still ineligible (the gate "
         "is not derived from the guard set)", result["nodes"]["n"]["completion_eligible"] is False
         and result["completion_eligible"] is False, result)
    bare = {"nodes": {"n": {"node_type": "unit", "attempt_id": "a", "state": "ready", "guards": {}}}}
    result = eligibility.apply(bare, [])
    emit("eligibility: a node with no reference and no guard is ineligible and not refuted",
         result["nodes"]["n"]["completion_eligible"] is False and result["nodes"]["n"]["refuted"] is False, result)
    result = eligibility.apply(bare, [outcome(0, None, "rejected", True, attempt="older")])
    emit("eligibility: a rejected authority claim of the node (any attempt, no guard) refutes it",
         result["nodes"]["n"]["refuted"] is True and result["nodes"]["n"]["refuted_by"] == [0], result)
    for label, run, outcomes, code in (
            ("an outcome that reads verified", verified, [outcome(0, "g1", "verified"), outcome(1, "g2")],
             "unknown-validity"),
            ("a guard with no classified claim", verified, [outcome(0, "g1")], "unclassified-guard"),
            ("a classified guard the reducer does not list", bare, [outcome(0, "g9")], "unknown-guard")):
        ok, got = refused(lambda run=run, outcomes=outcomes: eligibility.apply(run, outcomes), code)
        emit(f"eligibility fails closed on {label} ({code})", ok, got)
    before = copy.deepcopy(verified)
    eligibility.apply(verified, [outcome(0, "g1"), outcome(1, "g2")])
    emit("eligibility: apply is pure (its input is unchanged)", verified == before)


# ===========================================================================
# The fixture run: every reference kind 0a.1 accepts and every evidence field
# ===========================================================================

TS = "2026-09-29T12:00:00Z"
FIXED_RUN = "20260929T120000Z-0a3a3a"


def git_content(head, tree):
    return {"kind": "git", "head": head * 40, "tree_oid": tree * 40}


INPUT = git_content("a", "b")
COMMIT = git_content("c", "d")
COMMIT_SHA = "c" * 40
INTEGRATION = git_content("e", "d")
RECEIPT_OBJECT = git_content("f", "d")
PR_URL = "https://example.invalid/pr/1"
INVOCATION = {"argv": ["/usr/bin/env", "true"], "cwd": "/work", "env_digest": D("environment"),
              "executor_version": "executor-1"}
IDENTITY = {
    "adapter": {"boot_id": "boot-1", "pid": 100, "pgid": 100, "start_time": "2026-09-29T11:59:00Z"},
    "effect_child": {"boot_id": "boot-1", "pid": 101, "pgid": 100, "start_time": "2026-09-29T11:59:01Z"},
}
PRODUCER = {"tool": "fixture-writer", "tool_digest": D("fixture-writer")}
DISPATCH = {"backend": "codex", "model": "model-1", "effort": "high", "prompt_digest": D("prompt")}


def publish_result(stop_point, outcome):
    result = {"stop_point": stop_point, "branch": "topic", "content": COMMIT, "outcome": outcome}
    if outcome == "published":
        result.update(sha=COMMIT_SHA, pr=PR_URL, head_sha=COMMIT_SHA)
    else:
        result["error_code"] = "push-rejected"
    return result


class Run:
    def __init__(self, run_id):
        self.run_id = run_id
        self.records = []
        self.pins = {}
        self.reserves = {}
        self.spawned = {}
        self.recons = {}

    def lines(self):
        out = []
        for index, (event, payload) in enumerate(self.records, 1):
            line = {"schema": 2, "seq": index, "ts": TS, "event": event, "run": self.run_id}
            line.update(payload)
            out.append(line)
        return out

    def add(self, event, payload):
        payload = vocabulary.seal(event, payload)
        self.records.append((event, payload))
        return payload

    def base(self, attempt):
        node = self.pins[attempt][0]
        return {"vocabulary": "tg-v1.0a1", "run_id": self.run_id, "run_snapshot_digest": D("run-snapshot"),
                "node_id": node, "node_spec_digest": D(["spec", node]), "attempt_id": attempt}

    def begin(self, node, attempt, node_type, stop_point=None, parent=None):
        self.pins[attempt] = (node, node_type, stop_point)
        payload = self.base(attempt)
        payload.update({"node_type": node_type, "input_content": INPUT})
        if node_type == "unit":
            payload["stop_point"] = stop_point
        if node_type in ("unit", "investigation"):
            payload["dispatch"] = DISPATCH
        if node_type == "operation":
            payload.update(invocation=INVOCATION, catalog_entry_digest=D("catalog-entry"))
        if node_type == "approval":
            payload["envelope_digest"] = D("approval-envelope")
        if parent is not None:
            payload["parent_attempt_id"] = parent
        return self.add("attempt.begin", payload)

    def transition(self, attempt, frm, to, evidence, **extra):
        _node, node_type, stop_point = self.pins[attempt]
        payload = self.base(attempt)
        payload.update({"content": INPUT, "from": frm, "to": to, "node_type": node_type, "evidence": evidence})
        if node_type == "unit":
            payload["stop_point"] = stop_point
        payload.update(extra)
        return self.add("node.transition", payload)

    def operation(self, event, attempt):
        payload = self.base(attempt)
        payload.update({"invocation": INVOCATION, "expected_preconditions": {"branch": "main"},
                        "retry_class": "reconcilable"})
        if event == "operation.spawned":
            payload["identity"] = IDENTITY
        if event == "operation.result":
            payload.update({"content": COMMIT, "outcome": "succeeded", "producer": PRODUCER,
                            "log_digest": D("operation-log"), "identity": IDENTITY, "output_content": COMMIT})
        payload = self.add(event, payload)
        if event == "operation.reserve":
            self.reserves[attempt] = payload
        if event == "operation.spawned":
            self.spawned[attempt] = payload
        return payload

    def review(self, attempt, request_id):
        payload = self.base(attempt)
        payload.update({"content": COMMIT, "reviewer": "reviewer-1", "request_id": request_id,
                        "reviewed_content_digest": D(["reviewed", attempt]), "verdict": "pass",
                        "findings_digest": D("findings")})
        return self.add("review.recorded", payload)

    def ref(self, kind, attempt, content=None, **claims):
        node = self.pins[attempt][0]
        reference = {"kind": kind, "digest": D(["claimed", kind, node, attempt]), "node_id": node,
                     "attempt_id": attempt, "content": content}
        reference.update(claims)
        return reference

    def record_ref(self, kind, event, payload, content=None, **claims):
        reference = {"kind": kind, "digest": vocabulary.record_digest(event, payload), "node_id": payload["node_id"],
                     "attempt_id": payload["attempt_id"], "content": content}
        reference.update(claims)
        return reference

    def starting(self, attempt):
        self.transition(attempt, "ready", "starting", {
            "selection_ref": self.ref("selection", attempt), "authorization_ref": self.ref("authorization", attempt),
            "preconditions_digest": D("preconditions")})

    def run(self, attempt):
        self.starting(attempt)
        self.operation("operation.reserve", attempt)
        self.operation("operation.spawned", attempt)
        self.transition(attempt, "starting", "running", {"identity": IDENTITY, "observation_ref": self.record_ref(
            "operation-spawned", "operation.spawned", self.spawned[attempt])})

    def lose(self, attempt):
        self.run(attempt)
        self.transition(attempt, "running", "unknown-outcome", {"lost_child": True})

    def block(self, attempt):
        self.transition(attempt, "ready", "blocked", {"request_ref": self.ref("request", attempt)})

    def reconciliation(self, attempt, outcome, substitutes, method):
        payload = self.base(attempt)
        payload.update({"reconciliation_outcome": outcome, "method": method, "substitutes": substitutes,
                        "producer": PRODUCER})
        if method == "receipt-lookup":
            payload["receipt_ref"] = self.ref("provider-receipt", attempt)
        if substitutes == "operation-result":
            payload.update(request_digest=self.reserves[attempt]["request_digest"], observed_content=COMMIT,
                           substituted_result={"outcome": outcome, "output_content": COMMIT, "identity": IDENTITY})
        else:
            result = publish_result(self.pins[attempt][2], "published" if outcome == "succeeded" else "failed")
            payload.update(request_digest=D({f: result.get(f) for f in ("stop_point", "branch", "content")}),
                           observed_content=result["content"], substituted_result=result)
        self.recons[attempt] = self.add("reconciliation.result", payload)

    def recon_ref(self, attempt):
        record = self.recons[attempt]
        return self.record_ref(record["method"], "reconciliation.result", record, record["observed_content"])

    def commit_evidence(self, attempt):
        return {"review_ref": self.ref("review", attempt, COMMIT, verdict="pass", reviewer="reviewer-1"),
                "gate_ref": self.ref("gate", attempt, COMMIT, verdict="green", input_content=COMMIT),
                "branch": "topic", "sha": COMMIT_SHA}


# Nodes whose run carries an authority claim, and so must be refuted.
REFUTED = {"blocked-answers", "denied", "expired", "no-actor", "running-blocked", "approval", "reviewed", "retry"}


def build_run(run_id):
    r = Run(run_id)
    # --- authority claims: request_ref, answer_ref (granted, answered, denied; the approval row), expiry_ref,
    # --- and review.recorded's request_id
    r.begin("blocked-answers", "a1", "unit", "commit")
    r.block("a1")
    r.transition("a1", "blocked", "ready", {"answer_ref": r.ref("answer", "a1", answer="granted"),
                                           "revalidation_digest": D("revalidation-1")})
    r.block("a1")
    r.transition("a1", "blocked", "ready", {"answer_ref": r.ref("answer", "a1", answer="answered"),
                                           "revalidation_digest": D("revalidation-2")})
    r.begin("denied", "b1", "investigation")
    r.block("b1")
    r.transition("b1", "blocked", "failed", {"answer_ref": r.ref("answer", "b1", answer="denied")})
    r.begin("expired", "c1", "operation")
    r.block("c1")
    r.transition("c1", "blocked", "parked", {"expiry_ref": r.ref("expiry", "c1")})
    r.begin("no-actor", "d1", "unit", "worktree")
    r.block("d1")
    r.transition("d1", "blocked", "parked", {"no_permitted_actor": True})
    r.begin("running-blocked", "e1", "unit", "pr")
    r.run("e1")
    r.transition("e1", "running", "blocked", {"quiescence_ref": r.ref("quiescence", "e1"),
                                             "request_ref": r.ref("request", "e1")})
    r.begin("approval", "f1", "approval")
    r.run("f1")
    r.transition("f1", "running", "succeeded",
                 {"terminal_evidence": {"answer_ref": r.ref("answer", "f1", answer="granted")}})
    r.begin("reviewed", "g1", "unit", "worktree")
    r.review("g1", "request-g1")
    r.begin("retry", "s1", "unit", "worktree")
    r.block("s1")
    r.transition("s1", "blocked", "failed", {"answer_ref": r.ref("answer", "s1", answer="denied")})
    r.begin("retry", "s2", "unit", "worktree", parent="s1")
    r.transition("s2", "ready", "parked", {"park_reason": "retried later"})
    # --- no authority claim: every other kind and field
    r.begin("clean-success", "h1", "unit", "commit")
    r.run("h1")
    r.transition("h1", "running", "succeeded", {"terminal_evidence": r.commit_evidence("h1")},
                 stop_point_result="gated-commit")
    r.begin("bare", "i1", "unit", "merge")
    r.begin("parked", "j1", "investigation")
    r.transition("j1", "ready", "parked", {"park_reason": "not needed"})
    r.begin("spawn-fail", "k1", "operation")
    r.starting("k1")
    r.transition("k1", "starting", "failed", {"spawn_error": "exec failed", "effect": "none"})
    r.begin("drift", "l1", "unit", "commit")
    r.starting("l1")
    reserve = r.operation("operation.reserve", "l1")
    r.transition("l1", "starting", "blocked", {
        "drift_ref": r.ref("drift", "l1"),
        "barrier_closed_ref": r.record_ref("operation-reserve", "operation.reserve", reserve)})
    r.begin("cancelled", "m1", "unit", "worktree")
    r.transition("m1", "ready", "cancelled", {"cancel_ref": r.ref("cancel", "m1"),
                                             "quiescence_ref": r.ref("quiescence", "m1")})
    r.begin("merged", "n1", "unit", "merge")
    r.run("n1")
    evidence = r.commit_evidence("n1")
    evidence.update({
        "publish_ref": r.ref("publish", "n1", COMMIT, outcome="published", pr=PR_URL, head_sha=COMMIT_SHA),
        "pre_merge_gate_ref": r.ref("gate", "n1", INTEGRATION, verdict="green", input_content=INTEGRATION),
        "integration_content": INTEGRATION,
        "provider_receipt_ref": r.ref("provider-receipt", "n1", None, receipt_object=RECEIPT_OBJECT, outcome="merged"),
        "receipt_object": RECEIPT_OBJECT,
        "target_containment": {"target_ref": "refs/heads/main", "contains": True},
    })
    r.transition("n1", "running", "succeeded", {"terminal_evidence": evidence}, stop_point_result="integrated")
    r.begin("investigated", "o1", "investigation")
    r.run("o1")
    r.transition("o1", "running", "succeeded", {"terminal_evidence": {
        "dispatch_ref": r.ref("dispatch", "o1"), "transcript_digest": D("transcript"),
        "report_digest": D("report")}}, stop_point_result="informational")
    r.begin("op-ok", "p1", "operation")
    r.run("p1")
    result = r.operation("operation.result", "p1")
    r.transition("p1", "running", "succeeded", {"terminal_evidence": {"operation_result_ref": r.record_ref(
        "operation-result", "operation.result", result, COMMIT, outcome="succeeded")}})
    for node, attempt, node_type, stop_point, phase, failing, extra in (
            ("fail-dispatch-end", "q1", "unit", "commit", "dispatch", ("dispatch-end", None, {"exit": 1}), {}),
            ("fail-abandoned", "q2", "investigation", None, "dispatch", ("dispatch-abandoned", None, {}), {}),
            ("fail-review", "q3", "unit", "commit", "review",
             ("review", COMMIT, {"verdict": "iterate", "iteration_limit_reached": True}), {}),
            ("fail-gate", "q4", "unit", "commit", "gate", ("gate", COMMIT, {"verdict": "red"}), {}),
            ("fail-publish", "q5", "unit", "pr", "publish", ("publish", COMMIT, {"outcome": "failed"}), {}),
            ("fail-receipt", "q6", "unit", "merge", "integrate", ("provider-receipt", None, {"outcome": "refused"}),
             {}),
            ("fail-premerge", "q7", "unit", "merge", "integrate",
             ("gate", INTEGRATION, {"verdict": "red", "input_content": INTEGRATION}),
             {"integration_content": INTEGRATION}),
            ("fail-op", "q8", "operation", None, "operation", ("operation-result", COMMIT, {"outcome": "failed"}),
             {})):
        r.begin(node, attempt, node_type, stop_point)
        r.run(attempt)
        kind, content, claims = failing
        failure = {"phase": phase, "reason": f"{phase} failed", "failing_ref": r.ref(kind, attempt, content, **claims)}
        failure.update(extra)
        r.transition(attempt, "running", "failed", {"failure_evidence": failure})
    r.begin("recon-op", "r1", "operation")
    r.lose("r1")
    r.reconciliation("r1", "succeeded", "operation-result", "receipt-lookup")
    r.transition("r1", "unknown-outcome", "succeeded", {"reconciliation_ref": r.recon_ref("r1"),
                                                        "terminal_evidence": {}})
    r.begin("recon-pub-failed", "r2", "unit", "pr")
    r.lose("r2")
    r.reconciliation("r2", "failed", "publish", "reconciliation")
    r.transition("r2", "unknown-outcome", "failed", {
        "reconciliation_ref": r.recon_ref("r2"),
        "failure_evidence": {"phase": "publish", "reason": "the push was rejected"}})
    r.begin("recon-pub", "r3", "unit", "pr")
    r.lose("r3")
    r.reconciliation("r3", "succeeded", "publish", "reconciliation")
    r.transition("r3", "unknown-outcome", "succeeded", {"reconciliation_ref": r.recon_ref("r3"),
                                                        "terminal_evidence": r.commit_evidence("r3")},
                 stop_point_result="pr-open")
    r.begin("unresolved", "r4", "unit", "commit")
    r.lose("r4")
    r.transition("r4", "unknown-outcome", "parked", {"unresolvable_reason": "no receipt"})
    return r


def claim_problems(claims, nodes):
    """Every departure of a report's claims and nodes from 0a's two
    outcomes on the fixture run (an empty list is a pass)."""
    problems = []
    for claim in claims:
        authority = claim["kind"] in AUTHORITY_KINDS or (claim["kind"] is None and claim["field"] in AUTHORITY_FIELDS)
        want = ("rejected", "rows-dormant", True) if authority else ("claimed", None, False)
        if (claim["validity"], claim["reason"], claim["authority"]) != want:
            problems.append(("claim", claim["id"], claim["path"], claim["validity"]))
    seen_pairs = {(c["kind"], c["field"]) for c in claims if c["kind"] is not None}
    want_pairs = {(kind, field) for kind, entry in ORACLE_REFERENCE_MAP.items() for field in entry["fields"]}
    if seen_pairs != want_pairs:
        problems.append(("reference coverage", sorted(want_pairs ^ seen_pairs)))
    seen_fields = {c["field"] for c in claims if c["kind"] is None}
    if seen_fields != set(ORACLE_FIELD_MAP):
        problems.append(("field coverage", sorted(set(ORACLE_FIELD_MAP) ^ seen_fields)))
    refuted = {node_id for node_id, node in nodes.items() if node["refuted"]}
    if refuted != REFUTED:
        problems.append(("refuted", sorted(refuted ^ REFUTED)))
    by_id = {claim["id"]: claim for claim in claims}
    for node_id, node in nodes.items():
        if node["completion_eligible"] is not False:
            problems.append(("eligible", node_id))
        for claim_id in node["refuted_by"]:
            claim = by_id.get(claim_id, {})
            if claim.get("node_id") != node_id or claim.get("validity") != "rejected":
                problems.append(("refuted_by", node_id, claim_id))
        for guard, status in node["guards"].items():
            behind = [c for c in claims if c["attempt_id"] == node["attempt_id"] and c["guard"] == guard]
            want = {"status": "rejected", "reason": "rows-dormant"} if any(c["authority"] for c in behind) \
                else {"status": "claimed", "reason": None}
            if not behind or status != want:
                problems.append(("guard", node_id, guard, status))
    return problems


def main_claims():
    run = build_run(FIXED_RUN)
    events = run.lines()
    reduced = reduce.reduce_run(events)
    emit("fixture: the reducer accepts every record of the run (nothing rejected, not degraded)",
         reduced["rejected"] == [] and not reduced["degraded"], reduced["rejected"][:3])
    before = copy.deepcopy(reduced)
    claims = refs.claims_of(events, reduced)
    applied = eligibility.apply(reduced, claims)
    nodes = applied["nodes"]
    emit("purity: classifying the claims and applying eligibility leave the reduced run unchanged", reduced == before)
    emit("fixture: the run exercises every (kind, field) of the map (attestation excepted: 0a.1 refuses it) and "
         "every non-reference claim", not [p for p in claim_problems(claims, nodes) if "coverage" in p[0]],
         [p for p in claim_problems(claims, nodes) if "coverage" in p[0]])

    def find(field, **match):
        return [c for c in claims if c["field"] == field
                and all(c.get(k) == v if k != "answer" else c["claims"].get("answer") == v for k, v in match.items())]

    for label, found in (
            ("request_ref (ready -> blocked)", find("request_ref", guard="ready->blocked:request_ref")),
            ("request_ref (running -> blocked)", find("request_ref", guard="running->blocked:request_ref")),
            ("answer_ref claiming granted (blocked -> ready)", find("answer_ref", answer="granted",
                                                                   guard="blocked->ready:answer_ref")),
            ("answer_ref claiming answered (blocked -> ready)", find("answer_ref", answer="answered")),
            ("answer_ref claiming denied (blocked -> failed)", find("answer_ref", answer="denied")),
            ("answer_ref claiming granted (the approval row's terminal evidence)",
             find("answer_ref", path="evidence.terminal_evidence.answer_ref")),
            ("expiry_ref (blocked -> parked)", find("expiry_ref")),
            ("review.recorded's request_id", find("request_id", event="review.recorded"))):
        emit(f"rejected: {label} is rejected, reason rows-dormant", found and all(
            (c["validity"], c["reason"], c["authority"]) == ("rejected", "rows-dormant", True) for c in found),
            found)
    others = [c for c in claims if c["kind"] not in AUTHORITY_KINDS and c["field"] not in AUTHORITY_FIELDS]
    emit(f"claimed: every other reference and evidence field ({len(others)} claims) stays claimed with no reason",
         others and all((c["validity"], c["reason"], c["authority"]) == ("claimed", None, False) for c in others),
         [c["path"] for c in others if c["validity"] != "claimed"][:5])
    for node_id in sorted(REFUTED):
        node = nodes.get(node_id, {})
        emit(f"refuted: {node_id} is refuted by its rejected authority claim(s)",
             node.get("refuted") is True and node.get("refuted_by"), node)
    refuted = {n for n, node in nodes.items() if node["refuted"]}
    emit("refuted: no node without an authority claim is refuted", refuted == REFUTED, sorted(refuted ^ REFUTED))
    emit("refuted: a node whose earlier attempt made the rejected claim stays refuted (retry: latest attempt all "
         "claimed)", nodes["retry"]["refuted"] and all(g["status"] == "claimed" for g in nodes["retry"]["guards"].values()),
         nodes["retry"])
    emit("refuted: a node refuted only by review.recorded's request_id has no guard (reviewed)",
         nodes["reviewed"]["refuted"] and nodes["reviewed"]["guards"] == {}, nodes["reviewed"])
    emit("guards: the rejected guards carry reason rows-dormant (blocked-answers)",
         nodes["blocked-answers"]["guards"] == {
             "ready->blocked:request_ref": {"status": "rejected", "reason": "rows-dormant"},
             "blocked->ready:answer_ref": {"status": "rejected", "reason": "rows-dormant"},
             "blocked->ready:revalidation_digest": {"status": "claimed", "reason": None}},
         nodes["blocked-answers"]["guards"])
    emit("guards: every node's guards are exactly the reducer's, each rejected iff an authority claim is behind it",
         all(set(nodes[n]["guards"]) == set(reduced["nodes"][n]["guards"]) for n in nodes)
         and not [p for p in claim_problems(claims, nodes) if p[0] == "guard"],
         [p for p in claim_problems(claims, nodes) if p[0] == "guard"][:4])
    substituted = sorted((c["attempt_id"], c["path"], c["kind"]) for c in claims if c["substituted_by"])
    emit("substitution: the one reference each reconciliation replaced is a claim of the substituted kind behind "
         "the reducer's guard", substituted == [
             ("r1", "evidence.terminal_evidence.operation_result_ref", "operation-result"),
             ("r2", "evidence.failure_evidence.failing_ref", "publish"),
             ("r3", "evidence.terminal_evidence.publish_ref", "publish")]
         and all(c["guard"] in reduced["nodes"][c["node_id"]]["guards"] for c in claims if c["substituted_by"]),
         substituted)
    clean = nodes["clean-success"]
    emit("eligibility: a succeeded unit whose every guard is claimed (none rejected) is not completion-eligible",
         clean["state"] == "succeeded" and not clean["refuted"] and clean["guards"]
         and all(g["status"] == "claimed" for g in clean["guards"].values()) and clean["completion_eligible"] is False,
         clean)
    bare = nodes["bare"]
    emit("eligibility: a node with no reference at all is not completion-eligible",
         bare["guards"] == {} and not bare["refuted"] and bare["completion_eligible"] is False
         and all(c["kind"] is None for c in claims if c["node_id"] == "bare"), bare)
    emit("eligibility: no node of the run is completion-eligible, nor the run",
         all(n["completion_eligible"] is False for n in nodes.values()) and applied["completion_eligible"] is False)
    emit("eligibility: the reducer's own completion_eligible is false too (unchanged 0a.1 behaviour)",
         reduced["completion_eligible"] is False)
    problems = claim_problems(claims, nodes)
    emit("claims: the whole report agrees with 0a's two outcomes", not problems, problems[:5])
    # --- fail closed against vocabulary drift
    row = vocabulary.select_row("ready", "blocked")
    vocabulary.REFERENCE_KINDS["request-v2"] = {"content": "null", "claims": {}}
    row["evidence"]["request_ref"]["kinds"].append("request-v2")
    try:
        drift = Run(FIXED_RUN)
        drift.begin("drifted", "x1", "unit", "worktree")
        drift.transition("x1", "ready", "blocked", {"request_ref": drift.ref("request-v2", "x1")})
        red = reduce.reduce_run(drift.lines())
        ok, code = refused(lambda: refs.claims_of(drift.lines(), red), "unlisted-kind")
        emit("fail closed: a reference kind 0a.1's vocabulary gains, accepted by the reducer but not in the map, is "
             "an error (unlisted-kind), never a claim", red["rejected"] == [] and ok, (red["rejected"], code))
    finally:
        row["evidence"]["request_ref"]["kinds"].remove("request-v2")
        del vocabulary.REFERENCE_KINDS["request-v2"]
    row = vocabulary.select_row("ready", "parked")
    row["evidence"]["park_digest"] = {"type": "digest"}
    try:
        drift = Run(FIXED_RUN)
        drift.begin("drifted", "x1", "unit", "worktree")
        drift.transition("x1", "ready", "parked", {"park_reason": "x", "park_digest": D("park")})
        red = reduce.reduce_run(drift.lines())
        ok, code = refused(lambda: refs.claims_of(drift.lines(), red), "unlisted-field")
        emit("fail closed: an evidence field 0a.1's vocabulary gains, accepted by the reducer but not in the map, is "
             "an error (unlisted-field)", red["rejected"] == [] and ok, (red["rejected"], code))
    finally:
        del row["evidence"]["park_digest"]
    emit("fail closed: the vocabulary is restored", "request-v2" not in vocabulary.REFERENCE_KINDS
         and vocabulary.select_row("ready", "parked")["evidence"] == {"park_reason": {"type": "text"}})


# ===========================================================================
# The real command against real journals and fixture stores
# ===========================================================================

def git(*args, check=True):
    env = {"PATH": os.environ.get("PATH", "/usr/bin"), "HOME": TMP, "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    result = subprocess.run([shutil.which("git"), "-c", "core.hooksPath=/dev/null", *args], capture_output=True,
                            env=env, cwd=TMP)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {args}: {result.stderr.decode()}")
    return result


def base_env(home, **extra):
    env = {"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C", "LC_ALL": "C",
           "PYTHONDONTWRITEBYTECODE": "1"}
    env.update(extra)
    return env


def journal(home, *args, **extra):
    result = subprocess.run(["bash", JOURNAL, *args], env=base_env(home, **extra), capture_output=True, cwd=TMP,
                            timeout=300)
    return result.returncode, result.stdout.decode(), result.stderr.decode("utf-8", "replace")


def authority(home, *args, **extra):
    """The real wrapper; a hang (a lock waited on forever) fails the check
    through the timeout instead of stalling the suite."""
    started = time.monotonic()
    result = subprocess.run(["bash", AUTHORITY, *args], env=base_env(home, **extra), capture_output=True, cwd=TMP,
                            timeout=300)
    elapsed = time.monotonic() - started
    try:
        parsed = json.loads(result.stdout.decode().strip().splitlines()[-1])
    except (ValueError, IndexError):
        parsed = None
    return {"rc": result.returncode, "json": parsed, "stdout": result.stdout,
            "stderr": result.stderr.decode("utf-8", "replace")[-600:], "elapsed": elapsed}


def child_ceremony():
    """rf.py child <lib> <tmp> <home> <url> <command> <point|-> [epoch]: one
    ceremony core (the TTY challenge stubbed) or recovery, in this process,
    crashing at <point>."""
    home, url, command, point = ARGS[0], ARGS[1], ARGS[2], ARGS[3]
    os.environ["HOME"] = home
    os.environ["LOOP_AUTHORITY_TEST"] = "1"
    if point != "-":
        os.environ["LOOP_AUTHORITY_CRASH_AT"] = point
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
            else:
                recover.recover()
    finally:
        tools.cleanup()


def run_child(home, url, command, point="-", *extra):
    result = subprocess.run([sys.executable, os.path.realpath(__file__), "child", LIB, TMP, home, url, command, point,
                             *extra], capture_output=True, timeout=600)
    return result.returncode, result.stderr.decode("utf-8", "replace")[-600:]


def auth_path(home, *parts):
    return os.path.join(home, ".config", "olddonkey-loop", "authority", *parts)


def journal_path(home, *parts):
    return os.path.join(home, ".config", "olddonkey-loop", "journal", *parts)


def write_private(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def tree(root):
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
                with open(full, "rb") as handle:
                    data = handle.read()
            entries.append((os.path.relpath(full, root), "f", stat.S_IMODE(info.st_mode), info.st_size,
                            info.st_mtime_ns, hashlib.sha256(data).hexdigest()))
    return hashlib.sha256(repr(entries).encode()).hexdigest()


FIXTURES = {
    "absent": [],
    "current": [("genesis", "-")],
    "unreachable": [("genesis", "-")],
    "replay": [("genesis", "-"), ("rotate", "after-frame-fsync")],
    "quarantined": [("genesis", "-"), ("revoke", "-", "1")],
    "genesis-invalid": [("genesis", "genesis-step-2")],
    "anchor-mismatch": [("genesis", "genesis-step-2")],
    "genesis-quarantined": [("genesis", "genesis-step-2")],
}
# label -> (store state, reason, classification, lineage)
EXPECT = {
    "absent": ("unavailable", "absent", "none", None),
    "current": ("current", None, "committed", "test"),
    "unreachable": ("unavailable", "remote-unreachable", "pending", "test"),
    "replay": ("unavailable", "pending", "pending", "test"),
    "quarantined": ("unavailable", "quarantined", "quarantined", "test"),
    "genesis-invalid": ("unavailable", "genesis-invalid", "genesis-invalid", None),
    "anchor-mismatch": ("unavailable", "anchor-mismatch", "anchor-mismatch", None),
    "genesis-quarantined": ("unavailable", "genesis-quarantined", "genesis-quarantined", "test"),
}


def make_fixture(label):
    base = os.path.join(TMP, "st", label)
    home = os.path.join(base, "home")
    os.makedirs(home)
    remote = os.path.join(base, "remote.git")
    git("init", "--bare", "-q", remote)
    url = "file://" + remote
    for command, point, *extra in FIXTURES[label]:
        code, err = run_child(home, url, command, point, *extra)
        want = 137 if point != "-" else 0
        if code != want:
            raise RuntimeError(f"{label}: {command} at {point} exited {code}, not {want}: {err}")
    if label == "genesis-invalid":
        write_private(auth_path(home, "genesis.intent"), b"{corrupted after the intent was written")
    elif label == "anchor-mismatch":
        write_private(auth_path(home, "active"), canon({"store_id": "f" * 32, "generation": 1}))
    elif label == "genesis-quarantined":
        with open(auth_path(home, "genesis.intent"), "rb") as handle:
            intent = json.loads(handle.read())
        write_private(auth_path(home, "stores", intent["store_id"], "log", "segment-000001.olf"),
                      b"nonconforming bytes")
        code, err = run_child(home, url, "recover")
        if code != 0:
            raise RuntimeError(f"{label}: recover exited {code}: {err}")
    return home, remote, url


def scratch_entries(home):
    """What lies inside the scratch directories (tmp/, anchor-scratch/): a
    crashed fixture ceremony leaves its own; refs must leave nothing new."""
    cache = os.path.join(home, ".cache", "olddonkey-loop")
    found = []
    for dirpath, dirs, files in os.walk(cache):
        dirs.sort()
        for name in dirs + files:
            relative = os.path.relpath(os.path.join(dirpath, name), cache)
            if os.sep in relative:
                found.append(relative)
    return found


def install_journal(source_home, home):
    """The journal written once through the CLI, copied byte for byte (modes
    kept) into a fixture HOME."""
    loop_root = os.path.join(home, ".config", "olddonkey-loop")
    for path in (os.path.join(home, ".config"), loop_root):
        os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o700)
    shutil.copytree(journal_path(source_home), journal_path(home), symlinks=True)


def workspace_key(workspace):
    return hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()


def main_command():
    # --- the journals, through the real CLI
    source = os.path.join(TMP, "journal-home")
    os.makedirs(source)
    ws_a, ws_b = os.path.join(TMP, "ws-a"), os.path.join(TMP, "ws-b")
    os.makedirs(ws_a)
    os.makedirs(ws_b)
    code, out, err = journal(source, "begin-run", "--workspace", ws_a)
    run_a = next((line[4:] for line in out.splitlines() if line.startswith("run=")), None)
    emit("journal: begin-run allocates the schema-2 run", code == 0 and run_a, (code, err))
    fixture = build_run(run_a)
    statuses = []
    for event, payload in fixture.records:
        code, _out, err = journal(source, "append", "--schema", "2", "--workspace", ws_a, "--event", event,
                                  "--json", json.dumps(payload, sort_keys=True, separators=(",", ":")))
        statuses.append((event, code, err.strip()[-200:]))
    emit(f"journal: all {len(fixture.records)} schema-2 records are written by loop-journal append --schema 2",
         all(code == 0 for _e, code, _err in statuses), [s for s in statuses if s[1] != 0][:2])
    code, out, err = journal(source, "begin-run", "--workspace", ws_b)
    run_b = next((line[4:] for line in out.splitlines() if line.startswith("run=")), None)
    legacy = [("unit.begin", ["unit=u1"]), ("round.begin", ["unit=u1", "round=1"]),
              ("dispatch.start", ["dispatch_id=d1", "backend=codex", "mode=implement", "unit=u1", "round=1"]),
              ("dispatch.end", ["dispatch_id=d1", "exit=0"]),
              ("gate.result", ["policy=strict", "purpose=unit-final", "binding=clean", "verdict=green",
                               "gate_exit=0"]),
              ("review.recorded", ["unit=u1", "round=1", "verdict=pass"]),
              ("publish.recorded", ["unit=u1", "branch=topic", "sha=abc"]), ("checkpoint", ["note=pause"])]
    codes = []
    for event, fields in legacy:
        args = ["append", "--workspace", ws_b, "--event", event]
        for field in fields:
            args += ["--field", field]
        codes.append(journal(source, *args)[0])
    emit("journal: a schema-1-only run is written by loop-journal append (no --schema)",
         run_b and codes == [0] * len(legacy), codes)
    segment_a = journal_path(source, workspace_key(ws_a), "runs", f"{run_a}.jsonl")
    with open(segment_a, "rb") as handle:
        written = [json.loads(line) for line in handle.read().splitlines()]
    emit("journal: the segment holds run.begin and every schema-2 record, in order",
         [line.get("event") for line in written] == ["run.begin"] + [e for e, _p in fixture.records]
         and all(line["schema"] == 2 for line in written[1:]), len(written))
    # --- the store fixtures (child ceremonies, in parallel), each with the journal copied in
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        futures = {label: pool.submit(make_fixture, label) for label in FIXTURES}
        made = {label: future.result() for label, future in futures.items()}
    for label, (home, _remote, _url) in made.items():
        install_journal(source, home)
    home, remote, _url = made["unreachable"]
    os.rename(remote, remote + ".away")
    made["unreachable"] = (home, remote + ".away", _url)
    vacated = remote
    reference = None
    for label in FIXTURES:
        home, remote, _url = made[label]
        roots = (journal_path(home), auth_path(home), remote)
        before = [tree(root) for root in roots]
        vacated_before = os.path.lexists(vacated)
        scratch_before = scratch_entries(home)
        result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
        after = [tree(root) for root in roots]
        if label == "unreachable":
            emit("refs [unreachable]: nothing is created at the remote's original path (absent before and after)",
                 not vacated_before and not os.path.lexists(vacated), vacated)
        report = result["json"] or {}
        emit(f"refs [{label}]: exit 0 with one line of canonical JSON",
             result["rc"] == 0 and result["json"] is not None and result["stdout"] == canon(result["json"]) + b"\n",
             (result["rc"], result["stderr"]))
        store = report.get("store", {})
        state, reason, classification, lineage = EXPECT[label]
        emit(f"refs [{label}]: the store is reported {state}" + (f" ({reason})" if reason else "")
             + f", classification {classification}, lineage {lineage}",
             (store.get("state"), store.get("reason"), store.get("classification"), store.get("lineage"))
             == EXPECT[label], store)
        emit(f"refs [{label}]: the journal store, the authority directory, and the remote are byte-identical "
             "afterwards (content, modes, mtimes)", before == after,
             [name for name, b, a in zip(("journal", "authority", "remote"), before, after) if b != a])
        scratch = sorted(set(scratch_entries(home)) - set(scratch_before))
        emit(f"refs [{label}]: its process scratch (0a.2's, under $HOME/.cache/olddonkey-loop) is removed on exit",
             scratch == [], scratch[:3])
        claims, nodes = report.get("claims", []), report.get("nodes", {})
        problems = claim_problems(claims, nodes)
        emit(f"refs [{label}]: every request, answer, expiry, and request_id claim is rejected (rows-dormant) and "
             "refutes its node; everything else is claimed; nothing is completion-eligible",
             claims and not problems and report.get("completion_eligible") is False, problems[:4])
        if reference is None:
            reference = canon([claims, nodes])
        emit(f"refs [{label}]: the claims and nodes are byte-identical to every other store state's",
             canon([claims, nodes]) == reference)
        if label == "current":
            emit("refs [current]: a test lineage is current but never current authorization",
                 store.get("current_authorization") is False and store.get("test_only") is True, store)
        if label == "replay":
            status = authority(home, "status")
            emit("refs [replay]: afterwards the store is still pending replay-forward (refs replayed nothing)",
                 status["rc"] == 0 and (status["json"] or {}).get("row") == "anchor-replay-forward", status)
    home, remote, _url = made["current"]
    # --- the schema-1-only run
    before = [tree(journal_path(home)), tree(auth_path(home)), tree(remote)]
    result = authority(home, "refs", "--workspace", ws_b, "--run", run_b)
    report = result["json"] or {}
    emit("refs [schema-1 run]: a schema-1-only run yields no claim, no node, nothing refuted, and no eligibility",
         result["rc"] == 0 and report.get("claims") == [] and report.get("nodes") == {}
         and report.get("completion_eligible") is False and report.get("journal", {}).get("lines") == 1 + len(legacy)
         and report.get("journal", {}).get("degraded") is False, (result["rc"], result["stderr"], report))
    emit("refs [schema-1 run]: the store is still reported (current) and nothing changed",
         report.get("store", {}).get("state") == "current"
         and before == [tree(journal_path(home)), tree(auth_path(home)), tree(remote)])
    # --- no lock that blocks the writer
    fd = os.open(auth_path(home, "lock"), os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
        emit("locks: with the authority writer's lock held exclusively, refs still reports (it takes neither the "
             "shared nor the exclusive lock, each of which would be refused lock-busy here)", result["rc"] == 0,
             (result["rc"], result["elapsed"], result["stderr"]))
        result = authority(home, "status")
        emit("locks (control): status, which takes the shared reader lock, is refused lock-busy under the same "
             "held lock", result["rc"] == 3, (result["rc"], result["stderr"]))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    fd = os.open(journal_path(home, workspace_key(ws_a), "meta.lock"), os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
        emit("locks: with the journal's meta.lock held exclusively, refs still reports (it never takes it)",
             result["rc"] == 0, (result["rc"], result["elapsed"], result["stderr"]))
        code, _out, err = journal(home, "append", "--workspace", ws_a, "--event", "checkpoint",
                                  LOOP_JOURNAL_LOCK_TIMEOUT_SEC="0.2")
        emit("locks (control): a journal append is refused lock-busy under the same held lock", code == 3, (code, err))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    # --- bad input fails closed and repairs nothing
    home = made["absent"][0]
    segment = journal_path(home, workspace_key(ws_a), "runs", f"{run_a}.jsonl")
    with open(segment, "rb") as handle:
        original = handle.read()
    for label, workspace, run, code, needle in (
            ("a malformed run id", ws_a, "not-a-run", 2, "run-id"),
            ("a run with no segment", ws_a, "20990101T000000Z-abcdef", 2, "no-run"),
            ("a workspace that is not a directory", os.path.join(TMP, "missing"), run_a, 2, "workspace")):
        result = authority(home, "refs", "--workspace", workspace, "--run", run)
        emit(f"refs: {label} is a usage error (exit 2, {needle}) with nothing printed",
             result["rc"] == code and needle in result["stderr"] and result["stdout"] == b"",
             (result["rc"], result["stderr"]))
    tail = b'{"schema":1,"seq":99,"ev'
    write_private(segment, original + tail)
    before = tree(journal_path(home))
    result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
    report = result["json"] or {}
    emit("refs: a torn last line is left out and reported (torn_tail_bytes); the claims are unchanged",
         result["rc"] == 0 and report.get("journal", {}).get("torn_tail_bytes") == len(tail)
         and canon([report.get("claims"), report.get("nodes")]) == reference, (result["rc"], result["stderr"]))
    emit("refs: the torn tail is not repaired (the journal is byte-identical)", tree(journal_path(home)) == before)
    lines = original.split(b"\n")
    write_private(segment, b"\n".join(lines[:3] + [b"not json"] + lines[3:]))
    before = tree(journal_path(home))
    result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
    emit("refs: mid-file corruption fails closed (exit 12, journal-corrupt) and is not repaired",
         result["rc"] == 12 and "journal-corrupt" in result["stderr"] and result["stdout"] == b""
         and tree(journal_path(home)) == before, (result["rc"], result["stderr"]))
    write_private(segment, original)
    os.chmod(segment, 0o644)
    result = authority(home, "refs", "--workspace", ws_a, "--run", run_a)
    emit("refs: a segment that is not 0600 fails closed (exit 12, journal-unsafe)",
         result["rc"] == 12 and "journal-unsafe" in result["stderr"], (result["rc"], result["stderr"]))
    os.chmod(segment, 0o600)
    result = authority(home, "refs", "--workspace", ws_a, "--run", run_a, LOOP_AUTHORITY_TEST="1",
                       LOOP_AUTHORITY_CRASH_AT="after-push")
    emit("refs: like status, refs has no crash point (refused, exit 4)",
         result["rc"] == 4 and "crash-point" in result["stderr"], (result["rc"], result["stderr"]))


def run(function):
    try:
        function()
    except Exception:  # noqa: BLE001
        emit(f"{function.__name__} completes", False, traceback.format_exc()[-1500:])


{"static": lambda: run(main_static), "claims": lambda: run(main_claims), "command": lambda: run(main_command),
 "child": child_ceremony}[MODE]()
PY

for mode in static claims command; do
  python3 "$TMP_ROOT/rf.py" "$mode" "$LIB" "$TMP_ROOT" > "$TMP_ROOT/$mode.tsv" 2> "$TMP_ROOT/$mode.stderr"
  status=$?
  tally "$TMP_ROOT/$mode.tsv" "$TMP_ROOT/$mode.stderr" "$status" "refs $mode checks"
done

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
