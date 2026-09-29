"""The pure reducer (task-graph-v1 Phase A, sub-unit 0a.1, section 3.7).

reduce_run(events) folds one run's parsed journal lines, in order, into
per-node lifecycle state, stop-point result, markers, and a per-guard status.
It performs no I/O.

- Each line is dispatched on its `schema`. Schema-1 lines reduce with every
  assurance axis weakest and are never completion evidence; declared
  unit/round read as weakest-assurance attribution. A line with an unknown
  schema is reported and makes the run degraded; it is never folded.
- Each schema-2 line is re-validated with vocabulary.validate_record (shape,
  recomputed digests, run_id against the envelope run) and then checked
  against the run so far: its attempt, the attempt's pins, the current
  lifecycle state, and the journal records the row names (observation,
  closed barrier, reconciliation). A refused line changes nothing and is
  listed under "rejected" with a reason code.
- Every guard is recorded as "claimed". 0a.1 never records "verified", so no
  node is ever completion-eligible.
"""

from __future__ import annotations

import copy

from . import VOCABULARY
from . import vocabulary as v
from .canonical import is_digest

CLAIMED = "claimed"
VERIFIED = "verified"
IDENTITY_CLAIMED = "identity-claimed"
UNPROVEN = "unproven"
GATE_REASONS = (
    "binding-changed",
    "binding-unavailable",
    "isolation-weak",
    "verdict-not-green",
    "verdict-inconsistent",
    "envelope-missing",
)
SUBSTITUTED_EVENTS = {"operation-result": "operation.result", "publish": "publish.recorded"}


def transition_table() -> dict:
    """The reducer's table (rows, terminal_evidence, failure_evidence, words)."""
    return v.table()


def select_row(from_state: object, to_state: object) -> dict | None:
    row = v.select_row(from_state, to_state)
    return copy.deepcopy(row) if row is not None else None


def _content_ok(value: object) -> bool:
    try:
        v.check_content(value, "content")
    except v.VocabularyError:
        return False
    return True


def envelope_complete(record: object) -> bool:
    """True when record carries the whole schema-2 binding envelope, well typed."""
    if not isinstance(record, dict) or v.line_schema(record) != 2:
        return False
    if record.get("vocabulary") != VOCABULARY:
        return False
    run_id = record.get("run_id")
    if type(run_id) is not str or not v.RUN_ID_RE.fullmatch(run_id):
        return False
    for key in ("node_id", "attempt_id"):
        value = record.get(key)
        if type(value) is not str or not v.ID_RE.fullmatch(value):
            return False
    for key in ("run_snapshot_digest", "node_spec_digest", "request_digest", "result_digest"):
        if not is_digest(record.get(key)):
            return False
    return _content_ok(record.get("content"))


def gate_ineligibility(gate: dict) -> frozenset[str]:
    """Every reason a gate is not completion evidence, one per rule. The empty
    set means no rule applies; it still certifies nothing in 0a.1."""
    reasons: set[str] = set()
    binding = gate.get("binding")
    if binding == "changed":
        reasons.add("binding-changed")
    elif binding not in ("clean", "dirty"):
        reasons.add("binding-unavailable")
    if gate.get("input_isolation") != "immutable":
        reasons.add("isolation-weak")
    verdict = gate.get("verdict")
    gate_exit = gate.get("gate_exit")
    if verdict != "green":
        reasons.add("verdict-not-green")
    if (
        verdict not in ("green", "red")
        or type(gate_exit) is not int
        or (verdict == "green" and gate_exit != 0)
        or (verdict == "red" and gate_exit == 0)
    ):
        reasons.add("verdict-inconsistent")
    if not envelope_complete(gate):
        reasons.add("envelope-missing")
    return frozenset(reasons)


def completion_eligible(state: str, guards: dict) -> bool:
    """Succeeded with every guard verified. Guards are only ever claimed in
    0a.1, so this is always false."""
    return state == "succeeded" and bool(guards) and all(
        status == VERIFIED for status in guards.values()
    )


def declared_attribution(event: dict) -> dict | None:
    """Declared unit/round: weakest-assurance attribution, never proof."""
    unit = event.get("unit")
    round_n = event.get("round")
    result: dict = {}
    if type(unit) is str and unit:
        result["unit"] = unit
    if type(round_n) is int and round_n >= 1:
        result["round"] = round_n
    if not result:
        return None
    result["assurance"] = "declared"
    return result


class Rejected(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _reject(code: str, message: str) -> None:
    raise Rejected(code, message)


class Reducer:
    def __init__(self) -> None:
        self.unknown_schema: list[int] = []
        self.nodes: dict[str, dict] = {}
        self.attempts: dict[str, dict] = {}
        self.records: list[dict] = []
        self.rejected: list[dict] = []
        self.gates: list[dict] = []
        self.accepted: list[tuple[str, dict]] = []
        self.by_digest: dict[tuple[str, str], dict] = {}
        self.substituted: set[tuple[str, str, str]] = set()
        self.diverged: dict | None = None
        self.snapshot: str | None = None

    # -- dispatch ---------------------------------------------------------
    def apply(self, event: object) -> dict:
        position = len(self.records)
        obj = event if isinstance(event, dict) else {}
        schema = v.line_schema(event)
        name = obj.get("event")
        seq = obj.get("seq")
        summary: dict = {
            "position": position,
            "seq": seq if type(seq) is int else None,
            "schema": schema,
            "event": name if type(name) is str else None,
            "axes": dict(v.WEAKEST_AXES),
            "completion_evidence": False,
        }
        if schema is None:
            summary["status"] = "unknown-schema"
            self.unknown_schema.append(position)
        else:
            attribution = declared_attribution(obj)
            if attribution is not None:
                summary["attribution"] = attribution
            if schema == 1:
                summary["status"] = "legacy"
            else:
                try:
                    self._apply_schema_2(obj)
                    summary["status"] = "accepted"
                except (Rejected, v.VocabularyError) as error:
                    summary["status"] = "rejected"
                    self.rejected.append(
                        {
                            "position": position,
                            "seq": summary["seq"],
                            "event": summary["event"],
                            "code": error.code,
                            "message": error.message,
                        }
                    )
            if name == "gate.result":
                self.gates.append(
                    {
                        "position": position,
                        "seq": summary["seq"],
                        "schema": schema,
                        "status": summary["status"],
                        "reasons": sorted(gate_ineligibility(obj)),
                        "completion_evidence": False,
                    }
                )
        self.records.append(summary)
        return summary

    def _apply_schema_2(self, obj: dict) -> None:
        run = obj.get("run")
        if type(run) is not str:
            _reject("envelope", "a schema-2 line must carry the journal envelope run")
        if "attribution_failure" in obj:
            _reject("envelope", "a schema-2 record is never unattributed")
        name = obj.get("event")
        payload = {key: value for key, value in obj.items() if key not in v.ENVELOPE_KEYS}
        v.validate_record(name, payload, run=run)  # type: ignore[arg-type]
        assert isinstance(name, str)
        handler = getattr(self, "_on_" + name.replace(".", "_"))
        handler(payload)
        self.by_digest.setdefault((name, v.record_digest(name, payload)), payload)
        self.accepted.append((name, payload))

    # -- helpers -----------------------------------------------------------
    def _attempt_for(self, payload: dict) -> dict:
        attempt = self.attempts.get(payload["attempt_id"])
        if attempt is None:
            _reject("no-attempt", f"attempt {payload['attempt_id']} has no attempt.begin in this run")
        assert attempt is not None
        for key in ("node_id", "run_id", "run_snapshot_digest", "node_spec_digest"):
            if payload[key] != attempt[key]:
                _reject("envelope-mismatch", f"{key} differs from attempt {attempt['attempt_id']}'s")
        return attempt

    def _records(self, event: str, attempt_id: str) -> list[dict]:
        return [
            payload
            for name, payload in self.accepted
            if name == event and payload["attempt_id"] == attempt_id
        ]

    def _require_reserve(self, payload: dict) -> None:
        reserves = self._records("operation.reserve", payload["attempt_id"])
        if not any(item["request_digest"] == payload["request_digest"] for item in reserves):
            _reject("no-reserve", "no operation.reserve for this attempt and request_digest")

    def _require_open(self, attempt: dict) -> None:
        if attempt["state"] in v.TERMINAL_STATES:
            _reject("attempt-terminal", f"attempt {attempt['attempt_id']} is {attempt['state']}")

    def _refuse_substituted(self, event: str, payload: dict) -> None:
        if (payload["attempt_id"], event, payload["request_digest"]) in self.substituted:
            _reject(
                "substituted",
                f"a reconciliation already substituted this {event}; the late record is refused",
            )

    # -- records -----------------------------------------------------------
    def _on_attempt_begin(self, payload: dict) -> None:
        attempt_id = payload["attempt_id"]
        if self.diverged is not None:
            _reject("run-diverged", "the run's graph diverged; no new attempt begins in it")
        if attempt_id in self.attempts:
            _reject("duplicate-attempt", f"attempt {attempt_id} already began")
        if self.snapshot is not None and payload["run_snapshot_digest"] != self.snapshot:
            _reject("snapshot-mismatch", "run_snapshot_digest differs from the run's first attempt")
        node = self.nodes.get(payload["node_id"])
        parent = payload.get("parent_attempt_id")
        if node is None:
            if parent is not None:
                _reject("parent-attempt", "a node's first attempt has no parent_attempt_id")
        else:
            current = self.attempts[node["attempt_id"]]
            if current["state"] not in v.TERMINAL_STATES:
                _reject(
                    "attempt-open",
                    f"attempt {current['attempt_id']} is {current['state']}; only a terminal "
                    "attempt is followed by a new one",
                )
            if node["node_type"] != payload["node_type"]:
                _reject("node-type-changed", "a node keeps its node_type across attempts")
            if parent != current["attempt_id"]:
                _reject("parent-attempt", "parent_attempt_id must name the node's latest attempt")
        self.snapshot = payload["run_snapshot_digest"]
        self.attempts[attempt_id] = {
            "attempt_id": attempt_id,
            "node_id": payload["node_id"],
            "node_type": payload["node_type"],
            "stop_point": payload.get("stop_point"),
            "run_id": payload["run_id"],
            "run_snapshot_digest": payload["run_snapshot_digest"],
            "node_spec_digest": payload["node_spec_digest"],
            "request_digest": payload["request_digest"],
            "parent_attempt_id": parent,
            "state": v.INITIAL_STATE,
            "stop_point_result": None,
            "markers": [],
            "guards": {},
            "transitions": [],
        }
        if node is None:
            node = {"node_id": payload["node_id"], "node_type": payload["node_type"], "attempts": []}
            self.nodes[payload["node_id"]] = node
        node["attempts"].append(attempt_id)
        node["attempt_id"] = attempt_id

    def _on_node_transition(self, payload: dict) -> None:
        attempt = self._attempt_for(payload)
        node = self.nodes[attempt["node_id"]]
        if node["attempt_id"] != attempt["attempt_id"]:
            _reject("stale-attempt", f"attempt {attempt['attempt_id']} is not the node's latest")
        if payload["node_type"] != attempt["node_type"] or payload.get("stop_point") != attempt["stop_point"]:
            _reject(
                "pin-mismatch",
                "node_type and stop_point must equal the values attempt.begin pinned",
            )
        if payload["from"] != attempt["state"]:
            _reject("from-mismatch", f"the attempt is {attempt['state']}, not {payload['from']}")
        pair = (payload["from"], payload["to"])
        row = v.select_row(*pair)
        assert row is not None
        evidence = payload["evidence"]
        if pair == ("starting", "running"):
            self._check_observation(attempt, evidence)
        elif pair == ("starting", "blocked"):
            self._check_barrier(attempt, evidence)
        substitution = self._check_reconciliation(attempt, payload) if row["substitution"] else None
        relations = self._relations(attempt, evidence, substitution) if payload["to"] == "succeeded" else []
        prefix = f"{payload['from']}->{payload['to']}"
        guards: dict[str, str] = {}
        for name, value in evidence.items():
            if name in ("terminal_evidence", "failure_evidence"):
                for field in value:
                    guards[f"{prefix}:{name}.{field}"] = CLAIMED
            else:
                guards[f"{prefix}:{name}"] = CLAIMED
        if substitution is not None:
            guards[f"{prefix}:{substitution['container']}.{substitution['slot']}"] = CLAIMED
            self.substituted.add(substitution["key"])
        attempt["state"] = payload["to"]
        attempt["stop_point_result"] = (
            payload.get("stop_point_result") if payload["to"] == "succeeded" else None
        )
        attempt["markers"] = sorted(set(payload.get("markers") or []))
        attempt["guards"].update(guards)
        attempt["transitions"].append(
            {
                "from": payload["from"],
                "to": payload["to"],
                "guards": guards,
                "relations": relations,
                "substituted": (
                    f"{substitution['container']}.{substitution['slot']}"
                    if substitution is not None
                    else None
                ),
            }
        )

    def _on_operation_reserve(self, payload: dict) -> None:
        self._require_open(self._attempt_for(payload))

    def _on_operation_spawned(self, payload: dict) -> None:
        self._require_open(self._attempt_for(payload))
        self._require_reserve(payload)

    def _on_operation_released(self, payload: dict) -> None:
        self._attempt_for(payload)
        self._require_reserve(payload)

    def _on_operation_result(self, payload: dict) -> None:
        self._attempt_for(payload)
        self._require_reserve(payload)
        self._refuse_substituted("operation.result", payload)

    def _on_reconciliation_result(self, payload: dict) -> None:
        attempt = self._attempt_for(payload)
        if attempt["state"] != "unknown-outcome":
            _reject(
                "reconciliation-state",
                f"attempt {attempt['attempt_id']} is {attempt['state']}, not unknown-outcome",
            )
        if payload["substitutes"] == "operation-result":
            reserves = self._records("operation.reserve", attempt["attempt_id"])
            if not any(item["request_digest"] == payload["request_digest"] for item in reserves):
                _reject(
                    "substitution-request",
                    "an operation-result substitute's request_digest must be the attempt's "
                    "operation.reserve request_digest",
                )
        else:
            result = payload.get("substituted_result")
            if result is not None and result["stop_point"] != attempt["stop_point"]:
                _reject(
                    "substitution-request",
                    "a publish substitute's stop_point must equal the pinned stop point",
                )

    def _on_graph_diverged(self, payload: dict) -> None:
        if self.diverged is not None:
            _reject("run-diverged", "the run's graph already diverged")
        self.diverged = dict(payload)

    def _on_gate_result(self, payload: dict) -> None:
        self._attempt_for(payload)

    def _on_review_recorded(self, payload: dict) -> None:
        self._attempt_for(payload)

    def _on_publish_recorded(self, payload: dict) -> None:
        self._attempt_for(payload)
        self._refuse_substituted("publish.recorded", payload)

    # -- journal references ----------------------------------------------
    def _named(self, event: str, ref: dict, attempt: dict, code: str) -> dict:
        record = self.by_digest.get((event, ref["digest"]))
        if record is None:
            _reject(code, f"{ref['kind']} reference names no {event} in this run")
        assert record is not None
        if record["attempt_id"] != attempt["attempt_id"] or record["node_id"] != attempt["node_id"]:
            _reject(code, f"the named {event} belongs to another attempt")
        return record

    def _check_observation(self, attempt: dict, evidence: dict) -> None:
        spawned = self._named("operation.spawned", evidence["observation_ref"], attempt, "observation")
        if spawned["identity"] != evidence["identity"]:
            _reject("observation", "identity differs from the one operation.spawned observed")

    def _check_barrier(self, attempt: dict, evidence: dict) -> None:
        self._named("operation.reserve", evidence["barrier_closed_ref"], attempt, "barrier")
        if self._records("operation.released", attempt["attempt_id"]):
            _reject("barrier", "an operation.released exists for the attempt; the barrier is not closed")

    def _check_reconciliation(self, attempt: dict, payload: dict) -> dict:
        evidence = payload["evidence"]
        ref = evidence["reconciliation_ref"]
        record = self._named("reconciliation.result", ref, attempt, "reconciliation-missing")
        if record["method"] != ref["kind"]:
            _reject("reconciliation-method", "reconciliation_ref.kind differs from the record's method")
        if ref["content"] != record.get("observed_content"):
            _reject("reconciliation-content", "reconciliation_ref.content differs from observed_content")
        outcome = record["reconciliation_outcome"]
        if outcome == "unresolved":
            _reject(
                "reconciliation-unresolved",
                "an unresolved reconciliation substitutes nothing; only unknown-outcome -> parked follows it",
            )
        if outcome != payload["to"]:
            _reject(
                "substitution-direction",
                f"reconciliation_outcome {outcome} does not match the transition to {payload['to']}",
            )
        substitutes = record["substitutes"]
        if payload["to"] == "succeeded":
            container_name = "terminal_evidence"
            entry = v.TERMINAL_EVIDENCE[v.matrix_key(attempt["node_type"], attempt["stop_point"])]
            slots = [slot for slot, kind in entry["substitutable"].items() if kind == substitutes]
        else:
            container_name = "failure_evidence"
            phase = evidence["failure_evidence"]["phase"]
            slots = ["failing_ref"] if v.FAILURE_SUBSTITUTABLE.get(phase) == substitutes else []
        container = evidence[container_name]
        if not slots:
            _reject(
                "substitution-kind",
                f"the pinned row has no {substitutes} reference a reconciliation may replace",
            )
        slot = slots[0]
        if slot in container:
            _reject(
                "substitution-present",
                f"{container_name}.{slot} is present; a reconciliation replaces only the missing reference",
            )
        substitutes_for = [
            item
            for item in self._records("reconciliation.result", attempt["attempt_id"])
            if item["reconciliation_outcome"] != "unresolved"
            and item["substitutes"] == substitutes
            and item["request_digest"] == record["request_digest"]
        ]
        if len(substitutes_for) > 1:
            _reject("substitution-duplicate", "two reconciliation results substitute for the same record")
        event = SUBSTITUTED_EVENTS[substitutes]
        if any(
            item["request_digest"] == record["request_digest"]
            for item in self._records(event, attempt["attempt_id"])
        ):
            _reject(
                "substitution-not-absent",
                f"a {event} exists for the attempt and request; only an absent record is substituted",
            )
        if substitutes == "publish" and payload["to"] == "succeeded":
            result = record["substituted_result"]
            if result["sha"] != container["sha"] or result["branch"] != container["branch"]:
                _reject(
                    "substitution-content",
                    "the substituted publication's sha or branch differs from the terminal evidence",
                )
        return {
            "container": container_name,
            "slot": slot,
            "observed_content": record["observed_content"],
            "key": (attempt["attempt_id"], event, record["request_digest"]),
        }

    def _relations(self, attempt: dict, evidence: dict, substitution: dict | None) -> list[dict]:
        entry = v.TERMINAL_EVIDENCE[v.matrix_key(attempt["node_type"], attempt["stop_point"])]
        terminal = evidence["terminal_evidence"]

        def content_of(field: str) -> object:
            if substitution is not None and substitution["slot"] == field:
                return substitution["observed_content"]
            value = terminal[field]
            return value["content"] if entry["fields"][field]["type"] == "ref" else value

        def same(left: str, right: str) -> bool:
            # A content against the sha field is compared as the candidate
            # commit: git content whose head is that sha, any tree.
            for content, other in ((left, right), (right, left)):
                if entry["fields"][other]["type"] == "sha":
                    value = content_of(content)
                    return (
                        isinstance(value, dict)
                        and value.get("kind") == "git"
                        and value.get("head") == terminal[other]
                    )
            return content_of(left) == content_of(right)

        return [
            {
                "between": [left, right],
                "status": IDENTITY_CLAIMED if same(left, right) else UNPROVEN,
            }
            for left, right in entry["relations"]
        ]

    # -- result ------------------------------------------------------------
    def result(self) -> dict:
        nodes: dict[str, dict] = {}
        for node_id, node in self.nodes.items():
            attempt = self.attempts[node["attempt_id"]]
            guards = dict(attempt["guards"])
            nodes[node_id] = {
                "node_id": node_id,
                "node_type": node["node_type"],
                "attempt_id": attempt["attempt_id"],
                "attempts": list(node["attempts"]),
                "state": attempt["state"],
                "stop_point": attempt["stop_point"],
                "stop_point_result": attempt["stop_point_result"],
                "markers": list(attempt["markers"]),
                "guards": guards,
                "transitions": copy.deepcopy(attempt["transitions"]),
                "completion_eligible": completion_eligible(attempt["state"], guards),
            }
        return {
            "vocabulary": VOCABULARY,
            "degraded": bool(self.unknown_schema),
            "unknown_schema": list(self.unknown_schema),
            "diverged": copy.deepcopy(self.diverged),
            "nodes": nodes,
            "gates": copy.deepcopy(self.gates),
            "records": copy.deepcopy(self.records),
            "rejected": copy.deepcopy(self.rejected),
            "completion_eligible": any(item["completion_eligible"] for item in nodes.values()),
        }


def reduce_run(events: object) -> dict:
    """Fold one run's parsed journal lines (in file order)."""
    reducer = Reducer()
    for event in events:  # type: ignore[union-attr]
        reducer.apply(event)
    return reducer.result()
