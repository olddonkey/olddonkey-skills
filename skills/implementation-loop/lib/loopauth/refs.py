"""Verification of claimed authority references (task-graph-v1 Phase A,
sub-unit 0a.3).

0a.1 records every reference to an authority record as a claim and never
upgrades it. This module classifies every claim of a run on two separate
dimensions:

- claim validity. A request, answer, or expiry reference, and
  review.recorded's request_id, is rejected with reason rows-dormant in
  every 0a store: A2.1 keeps every request row dormant through 0a (every 0a
  epoch admits no request protocol, enforced by 0a.2's writer and
  verifier), so no admitted row could have produced the record it names,
  whatever the store holds, and no lookup is needed to reject it. Every
  other reference and evidence field stays claimed. Nothing is ever
  verified: the positive verification rules arrive with the units that
  admit the records they verify.
- store state: current (anchored; not pending, quarantined, or in a
  bootstrap terminal state) or unavailable with its reason, plus the
  lineage class. The store is read only through 0a.2's read-only
  classification, recover.classify_stable (wrapping what `loop-authority status` and
  `verify` run); the state is reported beside the claims and never changes
  one.

REFERENCE_MAP (by reference kind) and FIELD_MAP (every other claim, by
field) are the closed reference map; CONTAINERS are walked, never
classified themselves. A kind, a reference field, a claim, or an event the
map does not list is an error (fail closed), never a silent claim.

Read-only: the journal is read by journal_read without loop-journal's lock,
and classification is sampled between local-state digests without the shared
lock `status` takes, so
no writer is ever blocked; guard status and eligibility are eligibility.py's.
Nothing here admits a row or writes, and registry-selftest.sh's
reachability scan proves that no path from this module reaches a sink.
"""

from __future__ import annotations

from . import eligibility, journal_read, recover, reduce, vocabulary

CLAIMED = eligibility.CLAIMED
REJECTED = eligibility.REJECTED
ROWS_DORMANT = "rows-dormant"


class RefsError(Exception):
    """usage is true for a caller's mistake (exit 2), false for anything the
    verification cannot classify or trust (exit 12)."""

    def __init__(self, code: str, message: str, usage: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.usage = usage


def _authority(names: str, fields: list) -> dict:
    return {"names": names, "fields": fields, "authority": True, "validity": REJECTED,
            "reason": ROWS_DORMANT}


def _claimed(names: str, fields: list) -> dict:
    return {"names": names, "fields": fields, "authority": False, "validity": CLAIMED, "reason": None}


JOURNAL_RECORD = "a journal record (units 6, 9)"
PROCESS_GUARD = "a process guard (unit 9, P5)"

# Every kind of vocabulary.REFERENCE_KINDS, once, with the 0a.1 fields that
# may carry it (receipt_ref is reconciliation.result's own reference).
REFERENCE_MAP = {
    "selection": _claimed("a coordinator decision (unit 10)", ["selection_ref"]),
    "authorization": _claimed("an effect authorization (units 3, 7, 8)", ["authorization_ref"]),
    "request": _authority("a request.opened record", ["request_ref"]),
    "answer": _authority("a request.redeemed record", ["answer_ref"]),
    "expiry": _authority("a request.expired record", ["expiry_ref"]),
    "cancel": _claimed("a node cancellation (tg:296); no record type in Phase A", ["cancel_ref"]),
    "quiescence": _claimed(PROCESS_GUARD, ["quiescence_ref"]),
    "drift": _claimed("a coordinator decision (unit 10)", ["drift_ref"]),
    "operation-reserve": _claimed(PROCESS_GUARD, ["barrier_closed_ref"]),
    "operation-spawned": _claimed(PROCESS_GUARD, ["observation_ref"]),
    "operation-result": _claimed(JOURNAL_RECORD, ["operation_result_ref", "failing_ref"]),
    "review": _claimed(JOURNAL_RECORD, ["review_ref", "failing_ref"]),
    "gate": _claimed(JOURNAL_RECORD, ["gate_ref", "pre_merge_gate_ref", "failing_ref"]),
    "publish": _claimed(JOURNAL_RECORD, ["publish_ref", "failing_ref"]),
    "provider-receipt": _claimed(JOURNAL_RECORD, ["provider_receipt_ref", "failing_ref", "receipt_ref"]),
    "dispatch": _claimed(JOURNAL_RECORD, ["dispatch_ref"]),
    "dispatch-end": _claimed(JOURNAL_RECORD, ["failing_ref"]),
    "dispatch-abandoned": _claimed(JOURNAL_RECORD, ["failing_ref"]),
    "reconciliation": _claimed("a journal record (unit 9)", ["reconciliation_ref"]),
    "receipt-lookup": _claimed("a journal record (unit 9)", ["reconciliation_ref"]),
    "attestation": _claimed("a journal record (unit 9); 0a.1 refuses it as a reconciliation_ref "
                            "kind (tg:294), so no field carries it", []),
}


def _claim_of(source: str, names: str) -> dict:
    return {"source": source, "names": names, "authority": False, "validity": CLAIMED, "reason": None}


# Every non-reference claim, once: the one non-reference authority claim,
# the attempt's pins, and every non-reference evidence field of the rows and
# matrices. source is where the claim lives: a record's field, or evidence.
FIELD_MAP = {
    "request_id": {"source": "review.recorded", "names": "the request.redeemed that answered it",
                   "authority": True, "validity": REJECTED, "reason": ROWS_DORMANT},
    "node_type": _claim_of("attempt.begin", "the pinned node type (node spec, unit 5)"),
    "stop_point": _claim_of("attempt.begin", "the pinned stop point (node spec, unit 5)"),
    "identity": _claim_of("evidence", "a process identity {adapter, effect_child} (process guard; unit 9, P5)"),
    "target_containment": _claim_of("evidence", "the target's containment {target_ref, contains}"),
    "integration_content": _claim_of("evidence", "the integration content"),
    "receipt_object": _claim_of("evidence", "the object the provider receipt names"),
    "branch": _claim_of("evidence", "the published branch"),
    "sha": _claim_of("evidence", "the candidate commit"),
    "no_permitted_actor": _claim_of("evidence", "that no actor may answer the request"),
    "phase": _claim_of("evidence", "the failing phase"),
    "preconditions_digest": _claim_of("evidence", "a digest"),
    "revalidation_digest": _claim_of("evidence", "a digest"),
    "transcript_digest": _claim_of("evidence", "a digest"),
    "report_digest": _claim_of("evidence", "a digest"),
    "spawn_error": _claim_of("evidence", "a text"),
    "effect": _claim_of("evidence", "that the failed spawn had no effect"),
    "lost_child": _claim_of("evidence", "that the effect child was lost"),
    "park_reason": _claim_of("evidence", "a text"),
    "unresolvable_reason": _claim_of("evidence", "a text"),
    "reason": _claim_of("evidence", "a text"),
}

CONTAINERS = ("terminal_evidence", "failure_evidence")

# Accepted records that carry no reference and no authority claim.
CLAIMLESS_EVENTS = ("operation.reserve", "operation.spawned", "operation.released", "operation.result",
                    "gate.result", "publish.recorded", "graph.diverged")


def classify_reference(kind: object, field: str) -> dict:
    entry = REFERENCE_MAP.get(kind) if type(kind) is str else None
    if entry is None:
        raise RefsError("unlisted-kind", f"reference kind {kind!r} is not in the reference map")
    if field not in entry["fields"]:
        raise RefsError("unlisted-field", f"{field} is not listed for reference kind {kind}")
    return entry


def classify_field(field: str, source: str) -> dict:
    entry = FIELD_MAP.get(field)
    if entry is None or entry["source"] != source:
        raise RefsError("unlisted-field", f"{source} claim {field} is not in the reference map")
    return entry


def _claim(entry: dict, *, path: str, guard: str | None, field: str, kind: str | None = None,
           reference: dict | None = None, substituted_by: str | None = None) -> dict:
    return {
        "path": path,
        "guard": guard,
        "field": field,
        "kind": kind,
        "digest": reference["digest"] if reference is not None else None,
        "claims": ({key: reference[key] for key in reference if key not in vocabulary.REFERENCE_KEYS}
                   if reference is not None else {}),
        "substituted_by": substituted_by,
        "names": entry["names"],
        "authority": entry["authority"],
        "validity": entry["validity"],
        "reason": entry["reason"],
    }


def _reference(field: str, reference: object, path: str, guard: str | None) -> dict:
    if type(reference) is not dict:
        raise RefsError("unlisted-field", f"{path} is not a reference")
    kind = reference.get("kind")
    return _claim(classify_reference(kind, field), path=path, guard=guard, field=field, kind=kind,
                  reference=reference)


def _field(field: str, source: str, path: str, guard: str | None) -> dict:
    return _claim(classify_field(field, source), path=path, guard=guard, field=field)


def _container(name: str, value: dict, prefix: str, node_type: str, stop_point: str | None,
               substitution: bool) -> list[dict]:
    """The members of terminal_evidence or failure_evidence, and the one
    reference a reconciliation replaced (the reducer's substituted slot)."""
    if name == "terminal_evidence":
        entry = vocabulary.TERMINAL_EVIDENCE[vocabulary.matrix_key(node_type, stop_point)]
        specs = entry["fields"]
        substitutable = entry["substitutable"]
    else:
        phase = value.get("phase")
        failing = value.get("failing_ref")
        specs = {"phase": {"type": "enum"}, "reason": {"type": "text"}, "failing_ref": {"type": "ref"}}
        for alternative in vocabulary.FAILURE_EVIDENCE[node_type][phase]:
            if isinstance(failing, dict) and failing.get("kind") in alternative["kinds"]:
                specs.update(alternative.get("fields", {}))
                break
        substitutable = {"failing_ref": vocabulary.FAILURE_SUBSTITUTABLE[phase]} \
            if phase in vocabulary.FAILURE_SUBSTITUTABLE else {}
    claims = []
    for member in sorted(value):
        spec = specs.get(member)
        if spec is None:
            raise RefsError("unlisted-field", f"{name}.{member} is not a member of its row")
        path, guard = f"evidence.{name}.{member}", f"{prefix}:{name}.{member}"
        if spec["type"] == "ref":
            claims.append(_reference(member, value[member], path, guard))
        else:
            claims.append(_field(member, "evidence", path, guard))
    for slot in (slot for slot in specs if slot not in value):
        if not substitution or slot not in substitutable:
            raise RefsError("unlisted-field", f"{name}.{slot} is absent and no reconciliation replaces it")
        kind = substitutable[slot]
        claims.append(_claim(classify_reference(kind, slot), path=f"evidence.{name}.{slot}",
                             guard=f"{prefix}:{name}.{slot}", field=slot, kind=kind,
                             substituted_by="reconciliation_ref"))
    return claims


def _transition(payload: dict) -> list[dict]:
    row = vocabulary.select_row(payload["from"], payload["to"])
    if row is None:
        raise RefsError("unlisted-field", f"no row {payload['from']} -> {payload['to']}")
    prefix = f"{payload['from']}->{payload['to']}"
    evidence = payload["evidence"]
    claims: list[dict] = []
    for name in sorted(evidence):
        spec = row["evidence"].get(name)
        if spec is None:
            raise RefsError("unlisted-field", f"evidence.{name} is not a field of row {prefix}")
        if spec["type"] in ("terminal_evidence", "failure_evidence"):
            if name not in CONTAINERS:
                raise RefsError("unlisted-field", f"evidence.{name} is not a listed container")
            claims += _container(name, evidence[name], prefix, payload["node_type"], payload.get("stop_point"),
                                 bool(row["substitution"]))
        elif spec["type"] == "ref":
            claims.append(_reference(name, evidence[name], f"evidence.{name}", f"{prefix}:{name}"))
        else:
            claims.append(_field(name, "evidence", f"evidence.{name}", f"{prefix}:{name}"))
    return claims


def record_claims(event: str, payload: dict) -> list[dict]:
    """Every claim one accepted schema-2 record makes."""
    if event == "attempt.begin":
        claims = [_field("node_type", event, "node_type", None)]
        if payload["node_type"] == "unit":
            claims.append(_field("stop_point", event, "stop_point", None))
        return claims
    if event == "node.transition":
        return _transition(payload)
    if event == "review.recorded":
        return [_field("request_id", event, "request_id", None)]
    if event == "reconciliation.result":
        receipt = payload.get("receipt_ref")
        return [] if receipt is None else [_reference("receipt_ref", receipt, "receipt_ref", None)]
    if event in CLAIMLESS_EVENTS:
        return []
    raise RefsError("unlisted-event", f"{event} is not in the reference map")


def claims_of(events: list, reduced: dict) -> list[dict]:
    """The claims of every record the reducer accepted, in file order; a
    refused line changed nothing and claims nothing."""
    claims: list[dict] = []
    for summary in reduced["records"]:
        if summary["status"] != "accepted":
            continue
        line = events[summary["position"]]
        payload = {key: value for key, value in line.items() if key not in vocabulary.ENVELOPE_KEYS}
        for claim in record_claims(summary["event"], payload):
            claim.update(id=len(claims), position=summary["position"], seq=summary["seq"],
                         event=summary["event"], node_id=payload["node_id"], attempt_id=payload["attempt_id"])
            claims.append(claim)
    return claims


CURRENT = "current"
UNAVAILABLE = "unavailable"
REMOTE_UNREACHABLE = "remote-unreachable"
# Every state 0a.2's classifier decides, and the reason the store is then
# unavailable (None: current). A classification not listed is an error.
CLASSIFICATIONS = {
    "committed": None,
    "none": "absent",
    "pending": "pending",
    "needs-recovery": "pending",
    "genesis-pending": "pending",
    "regenesis-pending": "pending",
    "quarantined": "quarantined",
    "regenesis-quarantined": "quarantined",
    "genesis-invalid": "genesis-invalid",
    "anchor-mismatch": "anchor-mismatch",
    "genesis-quarantined": "genesis-quarantined",
    "active-invalid": "active-invalid",
    "regenesis-invalid": "regenesis-invalid",
}


def describe_store(summary: dict, remote_read: bool) -> dict:
    """The store state from a classification summary. Current only when the
    state would authorize (committed; a cursor-only tidy never changes
    that); a pending state whose remote was never read is
    remote-unreachable."""
    classification = summary.get("state")
    if classification not in CLASSIFICATIONS:
        raise RefsError("unclassified-store", f"store classification {classification!r} is not mapped")
    reason = CLASSIFICATIONS[classification]
    if reason is None and summary.get("authorizing_state") is not True:
        reason = "pending"
    if reason == "pending" and not remote_read:
        reason = REMOTE_UNREACHABLE
    return {
        "state": CURRENT if reason is None else UNAVAILABLE,
        "reason": reason,
        "classification": classification,
        "table": summary.get("table"),
        "rule": summary.get("rule"),
        "lineage": summary.get("anchor_class"),
        "test_only": summary.get("test_only"),
        "current_authorization": summary.get("current_authorization"),
    }


def observe_store() -> dict:
    """A stable read-only classification, or an explicit changing result."""
    plan = recover.classify_stable()
    if plan is None:
        return {"state": UNAVAILABLE, "reason": "changing", "classification": None,
                "table": None, "rule": None, "lineage": None, "test_only": None,
                "current_authorization": False}
    return describe_store(plan.summary(), plan.remote_read)


def prepare_report(workspace: object, run_id: object) -> dict:
    """Validate the journal and its claims before scratch/store access."""
    try:
        journal = journal_read.read_run(workspace, run_id)
    except journal_read.JournalReadError as error:
        raise RefsError(error.code, error.message, usage=error.usage) from error
    reduced = reduce.reduce_run(journal["events"], run=journal["run"])
    claims = claims_of(journal["events"], reduced)
    try:
        applied = eligibility.apply(reduced, claims)
    except eligibility.EligibilityError as error:
        raise RefsError(error.code, error.message) from error
    return {
        "run": journal["run"],
        "workspace": journal["workspace"],
        "workspace_key": journal["workspace_key"],
        "vocabulary": reduced["vocabulary"],
        "journal": {
            "lines": len(journal["events"]),
            "torn_tail_bytes": journal["torn_tail_bytes"],
            "degraded": reduced["degraded"],
            "unknown_schema": reduced["unknown_schema"],
            "rejected": reduced["rejected"],
        },
        "claims": claims,
        "nodes": applied["nodes"],
        "completion_eligible": applied["completion_eligible"],
    }


def observe_report(prepared: dict) -> dict:
    """Add the store observation after journal/claim validation is complete."""
    return {**prepared, "store": observe_store()}


def report(workspace: object, run_id: object) -> dict:
    return observe_report(prepare_report(workspace, run_id))
