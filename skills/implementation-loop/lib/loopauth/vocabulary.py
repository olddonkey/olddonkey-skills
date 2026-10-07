"""Schema-2 journal vocabulary "tg-v1.0a1" (task-graph-v1 Phase A, sub-unit 0a.1).

This module is the single definition of:

- the schema-2 record shapes that `loop-journal append --schema 2` accepts and
  the reducer re-validates (validate_record); loop-journal's run inspection
  and loop-index classify schema-2 lines by schema only;
- the named digest subjects (section 3.4): request_digest and result_digest
  are computed over subject objects, never over the record itself, and are
  recomputed by `append --schema 2` on write and by the reducer on read;
- the guarded lifecycle transition table, the terminal_evidence matrix, and
  the failure_evidence table (section 3.3), exported as plain data in TABLE.

Everything a record carries is a claim by its writer. Validation checks shape
and internal consistency only; it never establishes that a referenced
authority record exists (sub-unit 0a.3).
"""

from __future__ import annotations

import copy
import re

from . import VOCABULARY
from .canonical import CanonicalError, check as canonical_check, digest, is_digest

SCHEMA = 2
KNOWN_SCHEMAS = (1, 2)
# Keys the journal adds around a payload. A schema-2 payload never carries them.
ENVELOPE_KEYS = frozenset({"schema", "seq", "ts", "event", "run", "attribution_failure"})

RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


def line_schema(obj: object) -> int | None:
    """The schema of one parsed journal line: 1, 2, or None when the value is
    absent or unknown. Every reader dispatches on this."""
    if not isinstance(obj, dict):
        return None
    value = obj.get("schema")
    if type(value) is int and value in KNOWN_SCHEMAS:
        return value
    return None


class VocabularyError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _fail(code: str, message: str) -> None:
    raise VocabularyError(code, message)


# ---------------------------------------------------------------------------
# Lifecycle words (section 3.2)
# ---------------------------------------------------------------------------
NON_TERMINAL_STATES = ("ready", "blocked", "starting", "running", "unknown-outcome")
TERMINAL_STATES = ("succeeded", "failed", "cancelled", "parked")
STATES = NON_TERMINAL_STATES + TERMINAL_STATES
INITIAL_STATE = "ready"
NODE_TYPES = ("unit", "investigation", "operation", "approval")
STOP_POINTS = ("worktree", "commit", "pr", "merge")
STOP_POINT_RESULTS = {
    "worktree": "reviewed-worktree",
    "commit": "gated-commit",
    "pr": "pr-open",
    "merge": "integrated",
}
INFORMATIONAL = "informational"
MARKERS = ("stale", "superseded", "landed-but-ungated")

# Assurance axes: (weak, strong). The journal refuses the strong value from
# any caller; an absent axis reads as weak.
ASSURANCE = {
    "input_isolation": ("endpoint-sampled", "immutable"),
    "capability_assurance": ("declared", "enforced"),
    "atomicity": ("unproven", "atomic"),
    "conformance": ("unproven", "conformant"),
}
ASSURANCE_KEYS = tuple(ASSURANCE)
WEAKEST_AXES = {axis: values[0] for axis, values in ASSURANCE.items()}

BACKENDS = ("claude", "codex", "grok", "cursor")
RETRY_CLASSES = ("safe-retry", "reconcilable", "manual-only")
OPERATION_OUTCOMES = ("succeeded", "failed")
PUBLISH_OUTCOMES = ("published", "failed")
RECONCILIATION_OUTCOMES = ("succeeded", "failed", "unresolved")
RECONCILIATION_METHODS = ("reconciliation", "receipt-lookup")
SUBSTITUTES = ("operation-result", "publish")
GATE_POLICIES = ("strict", "baseline", "passthrough")
GATE_PURPOSES = ("unit-final", "baseline-generation", "focused", "unspecified")
GATE_BINDINGS = ("clean", "dirty", "changed", "unavailable")
GATE_VERDICTS = ("green", "red")
REVIEW_VERDICTS = ("pass", "iterate")

# ---------------------------------------------------------------------------
# References (section 3.1): {kind, digest, node_id, attempt_id, content} plus
# the claims a kind may carry. content is "required" (a content object),
# "null" (the record concerns no content), or "any" (either).
# ---------------------------------------------------------------------------
REFERENCE_KEYS = ("kind", "digest", "node_id", "attempt_id", "content")
REFERENCE_KINDS = {
    "selection": {"content": "any", "claims": {}},
    "authorization": {"content": "any", "claims": {}},
    "request": {"content": "null", "claims": {}},
    "answer": {"content": "null", "claims": {"answer": ["enum", "granted", "answered", "denied"]}},
    "expiry": {"content": "null", "claims": {}},
    "cancel": {"content": "null", "claims": {}},
    "quiescence": {"content": "null", "claims": {}},
    "drift": {"content": "any", "claims": {}},
    "operation-reserve": {"content": "null", "claims": {}},
    "operation-spawned": {"content": "null", "claims": {}},
    "operation-result": {"content": "required", "claims": {"outcome": ["enum", "succeeded", "failed"]}},
    "review": {
        "content": "required",
        "claims": {
            "verdict": ["enum", "pass", "iterate"],
            "reviewer": ["text"],
            "iteration_limit_reached": ["bool"],
        },
    },
    "gate": {
        "content": "required",
        "claims": {"verdict": ["enum", "green", "red"], "input_content": ["content"]},
    },
    "publish": {
        "content": "required",
        "claims": {"outcome": ["enum", "published", "failed"], "pr": ["text"], "head_sha": ["sha"]},
    },
    "provider-receipt": {
        "content": "any",
        "claims": {"receipt_object": ["content"], "outcome": ["enum", "merged", "refused"]},
    },
    "dispatch": {"content": "any", "claims": {}},
    "dispatch-end": {"content": "any", "claims": {"exit": ["int"]}},
    "dispatch-abandoned": {"content": "any", "claims": {}},
    "reconciliation": {"content": "any", "claims": {}},
    "receipt-lookup": {"content": "any", "claims": {}},
    "attestation": {"content": "any", "claims": {}},
}
# Reference kinds that name a record in this run's journal, and that record's
# event. The reducer requires resolution for observation_ref, barrier_closed_ref
# and reconciliation_ref. Resolved operation-result, gate, review and publish
# references must agree with their accepted record; unresolved digests stay claims.
JOURNAL_REFERENCE_EVENTS = {
    "operation-reserve": "operation.reserve",
    "operation-spawned": "operation.spawned",
    "reconciliation": "reconciliation.result",
    "receipt-lookup": "reconciliation.result",
}


def _ref(kinds: list[str], claims: dict | None = None) -> dict:
    return {"type": "ref", "kinds": list(kinds), "claims": dict(claims or {})}


def _const(value: object) -> dict:
    return {"type": "const", "value": value}


DIGEST = {"type": "digest"}
TEXT = {"type": "text"}
SHA = {"type": "sha"}
CONTENT = {"type": "content"}
IDENTITY = {"type": "identity"}
CONTAINMENT = {"type": "containment"}
TERMINAL_EVIDENCE_FIELD = {"type": "terminal_evidence"}
FAILURE_EVIDENCE_FIELD = {"type": "failure_evidence"}
RECONCILIATION_REF = _ref(["reconciliation", "receipt-lookup"])

# ---------------------------------------------------------------------------
# The guarded transition table (section 3.3). "from": "*" marks the two
# general rows; they apply only from a non-terminal state that has no
# specific row to the same target. stop_point_result "pinned" means the
# transition must carry the pinned stop point's result; "none" means it must
# carry none. substitution marks the rows where one missing reference may be
# replaced by the reconciliation_ref.
# ---------------------------------------------------------------------------
ROWS = [
    {
        "from": "ready",
        "to": "starting",
        "evidence": {
            "selection_ref": _ref(["selection"]),
            "authorization_ref": _ref(["authorization"]),
            "preconditions_digest": DIGEST,
        },
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "ready",
        "to": "blocked",
        "evidence": {"request_ref": _ref(["request"])},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "blocked",
        "to": "ready",
        "evidence": {
            "answer_ref": _ref(["answer"], {"answer": ["granted", "answered"]}),
            "revalidation_digest": DIGEST,
        },
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "blocked",
        "to": "failed",
        "evidence": {"answer_ref": _ref(["answer"], {"answer": ["denied"]})},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "blocked",
        "to": "parked",
        "evidence": {"expiry_ref": _ref(["expiry"]), "no_permitted_actor": _const(True)},
        "one_of": ["expiry_ref", "no_permitted_actor"],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "starting",
        "to": "running",
        "evidence": {"identity": IDENTITY, "observation_ref": _ref(["operation-spawned"])},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "starting",
        "to": "failed",
        "evidence": {"spawn_error": TEXT, "effect": _const("none")},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "starting",
        "to": "blocked",
        "evidence": {
            "drift_ref": _ref(["drift"]),
            "barrier_closed_ref": _ref(["operation-reserve"]),
        },
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "running",
        "to": "blocked",
        "evidence": {"quiescence_ref": _ref(["quiescence"]), "request_ref": _ref(["request"])},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "running",
        "to": "succeeded",
        "evidence": {"terminal_evidence": TERMINAL_EVIDENCE_FIELD},
        "one_of": [],
        "stop_point_result": "pinned",
        "substitution": False,
    },
    {
        "from": "running",
        "to": "failed",
        "evidence": {"failure_evidence": FAILURE_EVIDENCE_FIELD},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "running",
        "to": "unknown-outcome",
        "evidence": {"lost_child": _const(True)},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "unknown-outcome",
        "to": "succeeded",
        "evidence": {
            "reconciliation_ref": RECONCILIATION_REF,
            "terminal_evidence": TERMINAL_EVIDENCE_FIELD,
        },
        "one_of": [],
        "stop_point_result": "pinned",
        "substitution": True,
    },
    {
        "from": "unknown-outcome",
        "to": "failed",
        "evidence": {
            "reconciliation_ref": RECONCILIATION_REF,
            "failure_evidence": FAILURE_EVIDENCE_FIELD,
        },
        "one_of": [],
        "stop_point_result": "none",
        "substitution": True,
    },
    {
        "from": "unknown-outcome",
        "to": "parked",
        "evidence": {"unresolvable_reason": TEXT},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "*",
        "to": "cancelled",
        "evidence": {"cancel_ref": _ref(["cancel"]), "quiescence_ref": _ref(["quiescence"])},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
    {
        "from": "*",
        "to": "parked",
        "evidence": {"park_reason": TEXT},
        "one_of": [],
        "stop_point_result": "none",
        "substitution": False,
    },
]

# ---------------------------------------------------------------------------
# terminal_evidence, typed by node type and, for units, by stop point. equal
# lists field paths that must hold the same claimed value; relations lists the
# pairs whose claimed content is compared (identity-claimed or unproven): two
# contents compare exactly, and a content against the sha field compares as
# the candidate commit, identity-claimed only for git content whose head is
# that sha; substitutable maps the one reference a reconciliation may replace
# to the kind it substitutes.
# ---------------------------------------------------------------------------
REVIEW_PASS = _ref(["review"], {"verdict": ["pass"], "reviewer": "present"})
GATE_GREEN = _ref(["gate"], {"verdict": ["green"], "input_content": "present"})
PUBLISH_PR = _ref(["publish"], {"outcome": ["published"], "pr": "present", "head_sha": "present"})
PROVIDER_RECEIPT = _ref(["provider-receipt"], {"receipt_object": "present", "outcome": ["merged"]})
PUBLICATION_RELATIONS = [
    ["review_ref", "gate_ref"],
    ["review_ref", "publish_ref"],
    ["gate_ref", "publish_ref"],
    ["review_ref", "sha"],
    ["gate_ref", "sha"],
    ["publish_ref", "sha"],
]
TERMINAL_EVIDENCE = {
    "unit/worktree": {
        "fields": {"review_ref": REVIEW_PASS},
        "equal": [],
        "relations": [],
        "substitutable": {},
    },
    "unit/commit": {
        "fields": {"review_ref": REVIEW_PASS, "gate_ref": GATE_GREEN, "branch": TEXT, "sha": SHA},
        "equal": [],
        "relations": [["review_ref", "gate_ref"], ["review_ref", "sha"], ["gate_ref", "sha"]],
        "substitutable": {},
    },
    "unit/pr": {
        "fields": {
            "review_ref": REVIEW_PASS,
            "gate_ref": GATE_GREEN,
            "branch": TEXT,
            "sha": SHA,
            "publish_ref": PUBLISH_PR,
        },
        "equal": [["publish_ref.head_sha", "sha"]],
        "relations": PUBLICATION_RELATIONS,
        "substitutable": {"publish_ref": "publish"},
    },
    "unit/merge": {
        "fields": {
            "review_ref": REVIEW_PASS,
            "gate_ref": GATE_GREEN,
            "branch": TEXT,
            "sha": SHA,
            "publish_ref": PUBLISH_PR,
            "pre_merge_gate_ref": GATE_GREEN,
            "integration_content": CONTENT,
            "provider_receipt_ref": PROVIDER_RECEIPT,
            "receipt_object": CONTENT,
            "target_containment": CONTAINMENT,
        },
        "equal": [
            ["publish_ref.head_sha", "sha"],
            ["receipt_object", "provider_receipt_ref.receipt_object"],
        ],
        "relations": PUBLICATION_RELATIONS + [["pre_merge_gate_ref", "integration_content"]],
        "substitutable": {"publish_ref": "publish"},
    },
    "investigation": {
        "fields": {
            "dispatch_ref": _ref(["dispatch"]),
            "transcript_digest": DIGEST,
            "report_digest": DIGEST,
        },
        "equal": [],
        "relations": [],
        "substitutable": {},
    },
    "operation": {
        "fields": {"operation_result_ref": _ref(["operation-result"], {"outcome": ["succeeded"]})},
        "equal": [],
        "relations": [],
        "substitutable": {"operation_result_ref": "operation-result"},
    },
    "approval": {
        "fields": {"answer_ref": _ref(["answer"], {"answer": ["granted"]})},
        "equal": [],
        "relations": [],
        "substitutable": {},
    },
}

# failure_evidence = {phase, failing_ref, reason}: phases by node type, and the
# reference kinds (with required claims) a phase's failing_ref may be. An
# alternative may also name further failure_evidence fields it requires
# (fields) and field paths that must hold the same claimed value (equal): the
# integrate phase's gate is the pre-merge gate, so failure_evidence carries
# the integration_content that gate's input_content must equal.
DISPATCH_FAILURE = [_ref(["dispatch-end"], {"exit": "nonzero"}), _ref(["dispatch-abandoned"])]
PRE_MERGE_GATE_RED = dict(
    _ref(["gate"], {"verdict": ["red"], "input_content": "present"}),
    fields={"integration_content": CONTENT},
    equal=[["failing_ref.input_content", "integration_content"]],
)
FAILURE_EVIDENCE = {
    "unit": {
        "dispatch": DISPATCH_FAILURE,
        "review": [_ref(["review"], {"verdict": ["iterate"], "iteration_limit_reached": [True]})],
        "gate": [_ref(["gate"], {"verdict": ["red"]})],
        "publish": [_ref(["publish"], {"outcome": ["failed"]})],
        "integrate": [
            PRE_MERGE_GATE_RED,
            _ref(["provider-receipt"], {"outcome": ["refused"]}),
        ],
    },
    "investigation": {"dispatch": DISPATCH_FAILURE},
    "operation": {"operation": [_ref(["operation-result"], {"outcome": ["failed"]})]},
}
# A phase listed here is admissible only for a unit pinned to one of these
# stop points: only a merge integrates.
FAILURE_STOP_POINTS = {"unit": {"integrate": ["merge"]}}
# The phase whose failing_ref a reconciliation may replace -> the kind it substitutes.
FAILURE_SUBSTITUTABLE = {"operation": "operation-result", "publish": "publish"}

TABLE = {
    "states": {"non_terminal": list(NON_TERMINAL_STATES), "terminal": list(TERMINAL_STATES)},
    "node_types": list(NODE_TYPES),
    "stop_point_results": dict(STOP_POINT_RESULTS),
    "markers": list(MARKERS),
    "reference_kinds": REFERENCE_KINDS,
    "rows": ROWS,
    "terminal_evidence": TERMINAL_EVIDENCE,
    "failure_evidence": FAILURE_EVIDENCE,
    "failure_stop_points": FAILURE_STOP_POINTS,
    "failure_substitutable": FAILURE_SUBSTITUTABLE,
}


def table() -> dict:
    """A deep copy of the transition table, evidence matrices, and words."""
    return copy.deepcopy(TABLE)


def select_row(from_state: object, to_state: object) -> dict | None:
    """Specific rows first; a general row only from a non-terminal state with
    no specific row to the same target."""
    for row in ROWS:
        if row["from"] == from_state and row["to"] == to_state:
            return row
    if from_state in NON_TERMINAL_STATES:
        for row in ROWS:
            if row["from"] == "*" and row["to"] == to_state:
                return row
    return None


def matrix_key(node_type: str, stop_point: str | None) -> str:
    return f"unit/{stop_point}" if node_type == "unit" else node_type


def expected_stop_point_result(node_type: str, stop_point: str | None) -> str | None:
    if node_type == "unit":
        return STOP_POINT_RESULTS.get(stop_point or "")
    if node_type == "investigation":
        return INFORMATIONAL
    return None


# ---------------------------------------------------------------------------
# Digest subjects (section 3.4). A subject always contains every field it
# names; an omitted optional field appears as null.
# ---------------------------------------------------------------------------
OPERATION_REQUEST = ("invocation", "expected_preconditions")
REQUEST_SUBJECTS = {
    "operation.reserve": OPERATION_REQUEST,
    "operation.spawned": OPERATION_REQUEST,
    "operation.released": OPERATION_REQUEST,
    "operation.result": OPERATION_REQUEST,
    "gate.result": ("suite_invocation", "input_content"),
    "review.recorded": ("request_id", "reviewed_content_digest"),
    "publish.recorded": ("stop_point", "branch", "content"),
    "node.transition": ("node_id", "attempt_id", "from", "to"),
}
ATTEMPT_REQUEST_SUBJECTS = {
    "unit": ("node_type", "stop_point", "node_spec_digest", "input_content", "dispatch"),
    "investigation": ("node_type", "node_spec_digest", "input_content", "dispatch"),
    "operation": (
        "node_type",
        "node_spec_digest",
        "input_content",
        "invocation",
        "catalog_entry_digest",
    ),
    "approval": ("node_type", "node_spec_digest", "envelope_digest"),
}
RESULT_SUBJECTS = {
    "operation.result": ("outcome", "producer", "log_digest", "identity", "output_content"),
    "gate.result": (
        "verdict",
        "gate_exit",
        "suite_exit",
        "binding",
        "producer",
        "log_digest",
        "output_content",
    ),
    "review.recorded": ("verdict", "reviewer", "findings_digest"),
    "publish.recorded": ("outcome", "sha", "pr", "head_sha", "error_code"),
    "node.transition": ("to", "evidence", "stop_point_result", "markers", "content"),
    "reconciliation.result": (
        "reconciliation_outcome",
        "method",
        "substitutes",
        "observed_content",
        "receipt_ref",
        "substituted_result",
        "producer",
    ),
}


def subject(fields: tuple[str, ...], payload: dict) -> dict:
    return {field: payload.get(field) for field in fields}


def request_subject_fields(event: str, payload: dict) -> tuple[str, ...] | None:
    if event == "attempt.begin":
        node_type = payload.get("node_type")
        return ATTEMPT_REQUEST_SUBJECTS.get(node_type) if type(node_type) is str else None
    return REQUEST_SUBJECTS.get(event)


def request_digest(event: str, payload: dict) -> str | None:
    """The recomputed request_digest, or None where the record carries it
    (reconciliation.result) or has none."""
    fields = request_subject_fields(event, payload)
    if fields is None:
        return None
    return digest(subject(fields, payload))


def result_digest(event: str, payload: dict) -> str | None:
    fields = RESULT_SUBJECTS.get(event)
    if fields is None:
        return None
    return digest(subject(fields, payload))


def seal(event: str, payload: dict) -> dict:
    """A copy of payload with request_digest and result_digest recomputed from
    its subject fields (for writers and fixtures; the journal never seals)."""
    sealed = dict(payload)
    request = request_digest(event, sealed)
    if request is not None:
        sealed["request_digest"] = request
    result = result_digest(event, sealed)
    if result is not None:
        sealed["result_digest"] = result
    return sealed


def record_digest(event: str, payload: dict) -> str:
    """The digest a reference names: the canonical digest of the record's
    payload (every field except the journal envelope) typed by its event."""
    return digest({"event": event, "payload": payload})


# ---------------------------------------------------------------------------
# Field validators
# ---------------------------------------------------------------------------
def _text(value: object, where: str, code: str = "mistyped") -> None:
    if type(value) is not str or not value:
        _fail(code, f"{where} must be a non-empty string")


def _digest(value: object, where: str, code: str = "mistyped") -> None:
    if not is_digest(value):
        _fail(code, f"{where} must be a sha256:<64 hex> digest")


def _identifier(value: object, where: str, code: str = "mistyped") -> None:
    if type(value) is not str or not ID_RE.fullmatch(value):
        _fail(code, f"{where} must be an identifier [A-Za-z0-9][A-Za-z0-9._:-]{{0,127}}")


def _run_id(value: object, where: str, code: str = "mistyped") -> None:
    if type(value) is not str or not RUN_ID_RE.fullmatch(value):
        _fail(code, f"{where} must be a run id")


def _sha(value: object, where: str, code: str = "mistyped") -> None:
    if type(value) is not str or not SHA_RE.fullmatch(value):
        _fail(code, f"{where} must be a 40- or 64-digit lowercase hex object id")


def _int(value: object, where: str, code: str = "mistyped", minimum: int | None = None) -> None:
    if type(value) is not int:
        _fail(code, f"{where} must be an integer")
    if minimum is not None and value < minimum:  # type: ignore[operator]
        _fail(code, f"{where} must be >= {minimum}")


def _enum(value: object, allowed: tuple[str, ...] | list[str], where: str, code: str = "mistyped") -> None:
    if type(value) is not str or value not in allowed:
        _fail(code, f"{where} must be one of {', '.join(allowed)}")


def _object(value: object, where: str, code: str = "mistyped") -> None:
    if type(value) is not dict:
        _fail(code, f"{where} must be an object")


def _exact_keys(value: dict, keys: tuple[str, ...], where: str, code: str = "mistyped") -> None:
    missing = [key for key in keys if key not in value]
    extra = sorted(set(value) - set(keys))
    if missing or extra:
        _fail(code, f"{where} must have exactly the keys {', '.join(keys)}")


def check_content(value: object, where: str, code: str = "mistyped") -> None:
    """{kind: "git", head, tree_oid} or {kind: "non-git", content_digest}."""
    _object(value, where, code)
    assert isinstance(value, dict)
    kind = value.get("kind")
    if kind == "git":
        _exact_keys(value, ("kind", "head", "tree_oid"), where, code)
        _sha(value["head"], f"{where}.head", code)
        _sha(value["tree_oid"], f"{where}.tree_oid", code)
    elif kind == "non-git":
        _exact_keys(value, ("kind", "content_digest"), where, code)
        _digest(value["content_digest"], f"{where}.content_digest", code)
    else:
        _fail(code, f"{where}.kind must be git or non-git")


def _process(value: object, where: str, code: str) -> None:
    _object(value, where, code)
    assert isinstance(value, dict)
    _exact_keys(value, ("boot_id", "pid", "pgid", "start_time"), where, code)
    _text(value["boot_id"], f"{where}.boot_id", code)
    _int(value["pid"], f"{where}.pid", code, minimum=1)
    _int(value["pgid"], f"{where}.pgid", code, minimum=1)
    _text(value["start_time"], f"{where}.start_time", code)


def check_identity(value: object, where: str, code: str = "mistyped") -> None:
    """{adapter: P, effect_child: P}: two records even when one process plays
    both roles."""
    _object(value, where, code)
    assert isinstance(value, dict)
    _exact_keys(value, ("adapter", "effect_child"), where, code)
    _process(value["adapter"], f"{where}.adapter", code)
    _process(value["effect_child"], f"{where}.effect_child", code)


def check_invocation(value: object, where: str, code: str = "mistyped") -> None:
    """A resolved invocation: {argv, cwd, env_digest, executor_version}."""
    _object(value, where, code)
    assert isinstance(value, dict)
    _exact_keys(value, ("argv", "cwd", "env_digest", "executor_version"), where, code)
    argv = value["argv"]
    if type(argv) is not list or not argv or any(type(item) is not str for item in argv):
        _fail(code, f"{where}.argv must be a non-empty list of strings")
    _text(argv[0], f"{where}.argv[0]", code)
    cwd = value["cwd"]
    if type(cwd) is not str or not cwd.startswith("/"):
        _fail(code, f"{where}.cwd must be an absolute path")
    _digest(value["env_digest"], f"{where}.env_digest", code)
    _text(value["executor_version"], f"{where}.executor_version", code)


def check_producer(value: object, where: str, code: str = "mistyped") -> None:
    _object(value, where, code)
    assert isinstance(value, dict)
    _exact_keys(value, ("tool", "tool_digest"), where, code)
    _text(value["tool"], f"{where}.tool", code)
    _digest(value["tool_digest"], f"{where}.tool_digest", code)


def _dispatch(value: object, where: str) -> None:
    _object(value, where)
    assert isinstance(value, dict)
    _exact_keys(value, ("backend", "model", "effort", "prompt_digest"), where)
    _enum(value["backend"], BACKENDS, f"{where}.backend")
    _text(value["model"], f"{where}.model")
    _text(value["effort"], f"{where}.effort")
    _digest(value["prompt_digest"], f"{where}.prompt_digest")


def _has_newline(value: object) -> bool:
    if isinstance(value, str):
        return "\n" in value or "\r" in value
    if isinstance(value, dict):
        return any(_has_newline(key) or _has_newline(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_has_newline(item) for item in value)
    return False


def _fields(payload: dict, required: tuple[str, ...], optional: tuple[str, ...]) -> None:
    missing = sorted(key for key in required if key not in payload)
    if missing:
        _fail("missing-field", f"missing field(s): {', '.join(missing)}")
    extra = sorted(set(payload) - set(required) - set(optional))
    if extra:
        _fail("unexpected-field", f"unknown field(s): {', '.join(extra)}")


# ---------------------------------------------------------------------------
# Evidence validation (section 3.3)
# ---------------------------------------------------------------------------
class _Context:
    def __init__(self, payload: dict, substitution: bool) -> None:
        self.node_id = payload.get("node_id")
        self.attempt_id = payload.get("attempt_id")
        self.node_type = payload.get("node_type")
        self.stop_point = payload.get("stop_point")
        self.substitution = substitution


def _claim_type(value: object, spec: list, where: str) -> None:
    kind = spec[0]
    if kind == "enum":
        _enum(value, spec[1:], where, "evidence-mistyped")
    elif kind == "text":
        _text(value, where, "evidence-mistyped")
    elif kind == "bool":
        if type(value) is not bool:
            _fail("evidence-mistyped", f"{where} must be a boolean")
    elif kind == "sha":
        _sha(value, where, "evidence-mistyped")
    elif kind == "int":
        _int(value, where, "evidence-mistyped")
    elif kind == "content":
        check_content(value, where, "evidence-mistyped")
    else:  # pragma: no cover - table error
        _fail("evidence-mistyped", f"{where}: unknown claim type {kind}")


def _same_value(value: object, allowed: object) -> bool:
    return type(value) is type(allowed) and value == allowed


def check_reference(
    ref: object,
    spec: dict,
    where: str,
    node_id: object,
    attempt_id: object,
) -> dict:
    """Shape, kind, node/attempt claim, content rule, and required claims of
    one reference. Returns the reference."""
    if type(ref) is not dict:
        _fail("evidence-mistyped", f"{where} must be a reference object")
    assert isinstance(ref, dict)
    for key in REFERENCE_KEYS:
        if key not in ref:
            _fail("evidence-mistyped", f"{where}.{key} is missing")
    kind = ref["kind"]
    if type(kind) is not str or kind not in REFERENCE_KINDS:
        _fail("evidence-mistyped", f"{where}.kind is not a reference kind")
    if kind not in spec["kinds"]:
        _fail(
            "evidence-wrong-kind",
            f"{where} must be of kind {' or '.join(spec['kinds'])}, not {kind}",
        )
    kind_spec = REFERENCE_KINDS[kind]
    extra = sorted(set(ref) - set(REFERENCE_KEYS) - set(kind_spec["claims"]))
    if extra:
        _fail("evidence-mistyped", f"{where} carries claim(s) its kind does not: {', '.join(extra)}")
    _digest(ref["digest"], f"{where}.digest", "evidence-mistyped")
    _identifier(ref["node_id"], f"{where}.node_id", "evidence-mistyped")
    _identifier(ref["attempt_id"], f"{where}.attempt_id", "evidence-mistyped")
    if ref["node_id"] != node_id:
        _fail("evidence-other-node", f"{where} claims another node: {ref['node_id']}")
    if ref["attempt_id"] != attempt_id:
        _fail("evidence-other-attempt", f"{where} claims another attempt: {ref['attempt_id']}")
    rule = kind_spec["content"]
    if rule == "required" or (rule == "any" and ref["content"] is not None):
        check_content(ref["content"], f"{where}.content", "evidence-mistyped")
    elif rule == "null" and ref["content"] is not None:
        _fail("evidence-mistyped", f"{where}.content must be null for kind {kind}")
    for claim, claim_spec in kind_spec["claims"].items():
        if claim in ref:
            _claim_type(ref[claim], claim_spec, f"{where}.{claim}")
    if kind == "gate" and "input_content" in ref and ref["input_content"] != ref["content"]:
        _fail("evidence-inconsistent", f"{where}.input_content differs from its content")
    for claim, requirement in spec["claims"].items():
        if claim not in ref:
            _fail("evidence-claim", f"{where}.{claim} is required")
        value = ref[claim]
        if requirement == "present":
            continue
        if requirement == "nonzero":
            if value == 0:
                _fail("evidence-claim", f"{where}.{claim} must be nonzero")
            continue
        if not any(_same_value(value, allowed) for allowed in requirement):
            _fail("evidence-claim", f"{where}.{claim} must be {' or '.join(map(str, requirement))}")
    return ref


def _check_field(value: object, spec: dict, where: str, ctx: _Context) -> None:
    kind = spec["type"]
    if kind == "ref":
        check_reference(value, spec, where, ctx.node_id, ctx.attempt_id)
    elif kind == "digest":
        _digest(value, where, "evidence-mistyped")
    elif kind == "text":
        _text(value, where, "evidence-mistyped")
    elif kind == "sha":
        _sha(value, where, "evidence-mistyped")
    elif kind == "content":
        check_content(value, where, "evidence-mistyped")
    elif kind == "const":
        if not _same_value(value, spec["value"]):
            _fail("evidence-mistyped", f"{where} must be {spec['value']!r}")
    elif kind == "identity":
        check_identity(value, where, "evidence-mistyped")
    elif kind == "containment":
        _object(value, where, "evidence-mistyped")
        assert isinstance(value, dict)
        _exact_keys(value, ("target_ref", "contains"), where, "evidence-mistyped")
        _text(value["target_ref"], f"{where}.target_ref", "evidence-mistyped")
        if type(value["contains"]) is not bool:
            _fail("evidence-mistyped", f"{where}.contains must be a boolean")
        if value["contains"] is not True:
            _fail("not-contained", f"{where}: the target does not contain the integration")
    elif kind == "terminal_evidence":
        _check_terminal(value, where, ctx)
    elif kind == "failure_evidence":
        _check_failure(value, where, ctx)
    else:  # pragma: no cover - table error
        _fail("evidence-mistyped", f"{where}: unknown field type {kind}")


def _path_value(evidence: dict, path: str) -> tuple[bool, object]:
    current: object = evidence
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return False, None
        current = current[part]
    return True, current


def _check_terminal(value: object, where: str, ctx: _Context) -> None:
    if type(value) is not dict:
        _fail("evidence-mistyped", f"{where} must be an object")
    assert isinstance(value, dict)
    entry = TERMINAL_EVIDENCE[matrix_key(ctx.node_type, ctx.stop_point)]  # type: ignore[arg-type]
    fields = entry["fields"]
    extra = sorted(set(value) - set(fields))
    if extra:
        _fail("evidence-unexpected", f"{where} carries field(s) its row does not: {', '.join(extra)}")
    absent = [name for name in fields if name not in value]
    allowed_absent = set(entry["substitutable"]) if ctx.substitution else set()
    missing = [name for name in absent if name not in allowed_absent]
    if missing:
        _fail("evidence-missing", f"{where} is missing {', '.join(missing)}")
    for name, spec in fields.items():
        if name in value:
            _check_field(value[name], spec, f"{where}.{name}", ctx)
    for left, right in entry["equal"]:
        has_left, left_value = _path_value(value, left)
        has_right, right_value = _path_value(value, right)
        if has_left and has_right and left_value != right_value:
            _fail("evidence-inconsistent", f"{where}: {left} differs from {right}")


def _check_failure(value: object, where: str, ctx: _Context) -> None:
    if type(value) is not dict:
        _fail("evidence-mistyped", f"{where} must be an object")
    assert isinstance(value, dict)
    phases = FAILURE_EVIDENCE.get(ctx.node_type)  # type: ignore[arg-type]
    if phases is None:
        _fail("failure-phase", f"{where}: a {ctx.node_type} node has no failure phase")
    assert phases is not None
    for key in ("phase", "reason"):
        if key not in value:
            _fail("evidence-missing", f"{where}.{key} is missing")
    phase = value["phase"]
    if type(phase) is not str or phase not in phases:
        _fail("failure-phase", f"{where}.phase must be one of {', '.join(phases)} for a {ctx.node_type}")
    pinned = FAILURE_STOP_POINTS.get(ctx.node_type, {}).get(phase)  # type: ignore[arg-type]
    if pinned is not None and ctx.stop_point not in pinned:
        _fail(
            "failure-phase",
            f"{where}.phase {phase} applies only to a {ctx.node_type} pinned to {' or '.join(pinned)}",
        )
    _text(value["reason"], f"{where}.reason", "evidence-mistyped")
    spec = None
    if "failing_ref" in value:
        ref = value["failing_ref"]
        if type(ref) is not dict or type(ref.get("kind")) is not str:
            _fail("evidence-mistyped", f"{where}.failing_ref must be a reference object")
        alternatives = [item for item in phases[phase] if ref["kind"] in item["kinds"]]
        if not alternatives:
            kinds = sorted({kind for item in phases[phase] for kind in item["kinds"]})
            _fail(
                "evidence-wrong-kind",
                f"{where}.failing_ref for phase {phase} must be of kind {' or '.join(kinds)}",
            )
        spec = alternatives[0]
    elif not (ctx.substitution and phase in FAILURE_SUBSTITUTABLE):
        _fail("evidence-missing", f"{where}.failing_ref is missing")
    fields = spec.get("fields", {}) if spec is not None else {}
    extra = sorted(set(value) - {"phase", "failing_ref", "reason"} - set(fields))
    if extra:
        _fail("evidence-unexpected", f"{where} carries field(s) it does not name: {', '.join(extra)}")
    if spec is None:
        return
    check_reference(value["failing_ref"], spec, f"{where}.failing_ref", ctx.node_id, ctx.attempt_id)
    for name, field in fields.items():
        if name not in value:
            _fail("evidence-missing", f"{where}.{name} is missing")
        _check_field(value[name], field, f"{where}.{name}", ctx)
    for left, right in spec.get("equal", []):
        has_left, left_value = _path_value(value, left)
        has_right, right_value = _path_value(value, right)
        if has_left and has_right and left_value != right_value:
            _fail("evidence-inconsistent", f"{where}: {left} differs from {right}")


def check_evidence(payload: dict, row: dict) -> None:
    """The claimed evidence of a node.transition against its row."""
    evidence = payload.get("evidence")
    if type(evidence) is not dict:
        _fail("evidence-mistyped", "evidence must be an object")
    assert isinstance(evidence, dict)
    fields = row["evidence"]
    extra = sorted(set(evidence) - set(fields))
    if extra:
        _fail("evidence-unexpected", f"evidence carries field(s) its row does not: {', '.join(extra)}")
    choice = row["one_of"]
    chosen = [name for name in choice if name in evidence]
    if choice and len(chosen) != 1:
        _fail(
            "evidence-missing" if not chosen else "evidence-unexpected",
            f"evidence must carry exactly one of {', '.join(choice)}",
        )
    for name in fields:
        if name not in evidence and name not in choice and not (row["substitution"] and name == "reconciliation_ref"):
            _fail("evidence-missing", f"evidence.{name} is missing")
    ctx = _Context(payload, bool(row["substitution"] and "reconciliation_ref" in evidence))
    for name, spec in fields.items():
        if name in evidence:
            _check_field(evidence[name], spec, f"evidence.{name}", ctx)


# ---------------------------------------------------------------------------
# Record validators
# ---------------------------------------------------------------------------
BASE = ("vocabulary", "run_id", "run_snapshot_digest", "node_id", "node_spec_digest", "attempt_id")
BINDING = BASE + ("content", "request_digest", "result_digest")


def _check_base(payload: dict) -> None:
    _run_id(payload["run_id"], "run_id")
    _digest(payload["run_snapshot_digest"], "run_snapshot_digest")
    _identifier(payload["node_id"], "node_id")
    _digest(payload["node_spec_digest"], "node_spec_digest")
    _identifier(payload["attempt_id"], "attempt_id")
    if "content" in payload:
        check_content(payload["content"], "content")
    for key in ("request_digest", "result_digest"):
        if key in payload:
            _digest(payload[key], key)


def _attempt_begin(payload: dict) -> None:
    if "node_type" not in payload:
        _fail("missing-field", "missing field(s): node_type")
    node_type = payload["node_type"]
    _enum(node_type, NODE_TYPES, "node_type")
    typed = {
        "unit": ("stop_point", "dispatch"),
        "investigation": ("dispatch",),
        "operation": ("invocation", "catalog_entry_digest"),
        "approval": ("envelope_digest",),
    }[node_type]
    required = BASE + ("input_content", "node_type", "request_digest") + typed
    _fields(payload, required, ("parent_attempt_id",) + ASSURANCE_KEYS)
    _check_base(payload)
    check_content(payload["input_content"], "input_content")
    if node_type == "unit":
        _enum(payload["stop_point"], STOP_POINTS, "stop_point")
    if "dispatch" in typed:
        _dispatch(payload["dispatch"], "dispatch")
    if node_type == "operation":
        check_invocation(payload["invocation"], "invocation")
        _digest(payload["catalog_entry_digest"], "catalog_entry_digest")
    if node_type == "approval":
        _digest(payload["envelope_digest"], "envelope_digest")
    parent = payload.get("parent_attempt_id")
    if parent is not None:
        _identifier(parent, "parent_attempt_id")
        if parent == payload["attempt_id"]:
            _fail("mistyped", "parent_attempt_id must differ from attempt_id")


def _node_transition(payload: dict) -> None:
    for key in ("from", "to", "node_type"):
        if key not in payload:
            _fail("missing-field", f"missing field(s): {key}")
    _enum(payload["from"], STATES, "from")
    _enum(payload["to"], STATES, "to")
    _enum(payload["node_type"], NODE_TYPES, "node_type")
    typed = ("stop_point",) if payload["node_type"] == "unit" else ()
    _fields(
        payload,
        BINDING + ("from", "to", "node_type", "evidence") + typed,
        ("stop_point_result", "markers") + ASSURANCE_KEYS,
    )
    _check_base(payload)
    if typed:
        _enum(payload["stop_point"], STOP_POINTS, "stop_point")
    row = select_row(payload["from"], payload["to"])
    if row is None:
        if payload["from"] in TERMINAL_STATES:
            _fail(
                "from-terminal",
                f"no transition leaves terminal state {payload['from']}; begin a new attempt",
            )
        _fail("no-row", f"no transition {payload['from']} -> {payload['to']} in the table")
    assert row is not None
    check_evidence(payload, row)
    result = payload.get("stop_point_result")
    if row["stop_point_result"] == "pinned":
        expected = expected_stop_point_result(payload["node_type"], payload.get("stop_point"))
        if result != expected:
            _fail(
                "stop-point-result",
                f"stop_point_result must be {expected!r} for the pinned node type and stop point",
            )
    elif result is not None:
        _fail("stop-point-result", "only a transition into succeeded carries a stop_point_result")
    markers = payload.get("markers")
    if markers is not None:
        if type(markers) is not list or any(type(item) is not str for item in markers):
            _fail("markers", "markers must be a list of marker words")
        unknown = sorted(set(markers) - set(MARKERS))
        if unknown:
            _fail("markers", f"unknown marker(s): {', '.join(unknown)}")
        if len(set(markers)) != len(markers):
            _fail("markers", "markers must not repeat")


def _operation(event: str) -> object:
    def check(payload: dict) -> None:
        if event == "operation.result":
            required = BINDING + (
                "invocation",
                "expected_preconditions",
                "retry_class",
                "outcome",
                "producer",
                "log_digest",
                "identity",
                "output_content",
            )
        else:
            required = BASE + ("request_digest", "invocation", "expected_preconditions", "retry_class")
            if event == "operation.spawned":
                required += ("identity",)
        _fields(payload, required, ASSURANCE_KEYS)
        _check_base(payload)
        check_invocation(payload["invocation"], "invocation")
        _object(payload["expected_preconditions"], "expected_preconditions")
        _enum(payload["retry_class"], RETRY_CLASSES, "retry_class")
        if "identity" in required:
            check_identity(payload["identity"], "identity")
        if event == "operation.result":
            _enum(payload["outcome"], OPERATION_OUTCOMES, "outcome")
            check_producer(payload["producer"], "producer")
            _digest(payload["log_digest"], "log_digest")
            check_content(payload["output_content"], "output_content")

    return check


def _gate_result(payload: dict) -> None:
    required = BINDING + (
        "policy",
        "purpose",
        "binding",
        "verdict",
        "gate_exit",
        "suite_exit",
        "suite_invocation",
        "input_content",
        "producer",
        "log_digest",
        "output_content",
    )
    optional = (
        "totals",
        "pre_head",
        "pre_tree",
        "post_head",
        "post_tree",
        "reason",
        "unit",
        "round",
    ) + ASSURANCE_KEYS
    _fields(payload, required, optional)
    _check_base(payload)
    _enum(payload["policy"], GATE_POLICIES, "policy")
    _enum(payload["purpose"], GATE_PURPOSES, "purpose")
    _enum(payload["binding"], GATE_BINDINGS, "binding")
    _enum(payload["verdict"], GATE_VERDICTS, "verdict")
    _int(payload["gate_exit"], "gate_exit")
    _int(payload["suite_exit"], "suite_exit")
    if (payload["verdict"] == "green") != (payload["gate_exit"] == 0):
        _fail("verdict-inconsistent", "verdict green requires gate_exit 0 and red a nonzero gate_exit")
    check_invocation(payload["suite_invocation"], "suite_invocation")
    check_content(payload["input_content"], "input_content")
    check_producer(payload["producer"], "producer")
    _digest(payload["log_digest"], "log_digest")
    check_content(payload["output_content"], "output_content")
    for key in ("pre_head", "pre_tree", "post_head", "post_tree", "reason"):
        if payload.get(key) is not None and type(payload[key]) is not str:
            _fail("mistyped", f"{key} must be a string")
    if payload.get("unit") is not None:
        _text(payload["unit"], "unit")
    if payload.get("round") is not None:
        _int(payload["round"], "round", minimum=1)


def _review_recorded(payload: dict) -> None:
    required = BINDING + (
        "reviewer",
        "request_id",
        "reviewed_content_digest",
        "verdict",
        "findings_digest",
    )
    _fields(payload, required, ASSURANCE_KEYS)
    _check_base(payload)
    _text(payload["reviewer"], "reviewer")
    _text(payload["request_id"], "request_id")
    _digest(payload["reviewed_content_digest"], "reviewed_content_digest")
    _enum(payload["verdict"], REVIEW_VERDICTS, "verdict")
    _digest(payload["findings_digest"], "findings_digest")


PUBLISH_FIELDS = ("stop_point", "branch", "content", "outcome", "sha", "pr", "head_sha", "error_code")


def check_publish_outcome(value: dict, where: str) -> None:
    """publish.recorded requiredness, shared with a publish substitute:
    published needs sha, and pr and head_sha (= sha) at pr or merge; failed
    needs error_code; every inapplicable field is null or absent."""
    prefix = f"{where}." if where else ""
    for key in ("stop_point", "branch", "content", "outcome"):
        if value.get(key) is None:
            _fail("missing-field", f"missing field(s): {prefix}{key}")
    _enum(value["stop_point"], STOP_POINTS, f"{prefix}stop_point")
    _text(value["branch"], f"{prefix}branch")
    check_content(value["content"], f"{prefix}content")
    _enum(value["outcome"], PUBLISH_OUTCOMES, f"{prefix}outcome")
    if value["outcome"] == "published":
        needed = ["sha"]
        if value["stop_point"] in ("pr", "merge"):
            needed += ["pr", "head_sha"]
        unused = ["error_code"]
    else:
        needed = ["error_code"]
        unused = ["sha", "pr", "head_sha"]
    for key in ("pr", "head_sha"):
        if key not in needed and key not in unused:
            unused.append(key)
    for key in needed:
        if value.get(key) is None:
            _fail("missing-field", f"missing field(s): {prefix}{key}")
    for key in unused:
        if value.get(key) is not None:
            _fail("unexpected-field", f"{prefix}{key} does not apply to this publication")
    if value.get("sha") is not None:
        _sha(value["sha"], f"{prefix}sha")
    if value.get("head_sha") is not None:
        _sha(value["head_sha"], f"{prefix}head_sha")
        if value["head_sha"] != value.get("sha"):
            _fail("publish-head-sha", f"{prefix}head_sha differs from {prefix}sha")
    if value.get("pr") is not None:
        _text(value["pr"], f"{prefix}pr")
    if value.get("error_code") is not None:
        _text(value["error_code"], f"{prefix}error_code")


def _publish_recorded(payload: dict) -> None:
    required = BINDING + ("stop_point", "branch", "outcome")
    _fields(payload, required, ("sha", "pr", "head_sha", "error_code") + ASSURANCE_KEYS)
    _check_base(payload)
    check_publish_outcome(payload, "")


SUBSTITUTED_OPERATION_FIELDS = ("outcome", "output_content", "identity")
OUTCOME_MAPPING = {
    "operation-result": {"succeeded": "succeeded", "failed": "failed"},
    "publish": {"succeeded": "published", "failed": "failed"},
}


def _reconciliation_result(payload: dict) -> None:
    required = BASE + (
        "request_digest",
        "reconciliation_outcome",
        "method",
        "substitutes",
        "producer",
        "result_digest",
    )
    optional = ("observed_content", "receipt_ref", "substituted_result") + ASSURANCE_KEYS
    _fields(payload, required, optional)
    _check_base(payload)
    outcome = payload["reconciliation_outcome"]
    _enum(outcome, RECONCILIATION_OUTCOMES, "reconciliation_outcome")
    _enum(payload["method"], RECONCILIATION_METHODS, "method")
    if payload["substitutes"] == "dispatch-end":
        _fail(
            "substitutes-dispatch-end",
            "substitutes dispatch-end is refused: schema-1 dispatch.end carries no attempt "
            "or request binding, so its absence cannot be established",
        )
    _enum(payload["substitutes"], SUBSTITUTES, "substitutes")
    check_producer(payload["producer"], "producer")
    receipt = payload.get("receipt_ref")
    if payload["method"] == "receipt-lookup":
        if receipt is None:
            _fail("missing-field", "missing field(s): receipt_ref (required for receipt-lookup)")
        spec = _ref(["provider-receipt"])
        try:
            check_reference(receipt, spec, "receipt_ref", payload["node_id"], payload["attempt_id"])
        except VocabularyError as error:
            _fail("mistyped", error.message)
        expected_receipt = {"succeeded": "merged", "failed": "refused"}.get(outcome)
        if expected_receipt is not None and "outcome" in receipt and receipt["outcome"] != expected_receipt:
            _fail(
                "evidence-inconsistent",
                f"receipt_ref.outcome must be {expected_receipt} for reconciliation_outcome {outcome}",
            )
    elif receipt is not None:
        _fail("unexpected-field", "receipt_ref applies only to method receipt-lookup")
    result = payload.get("substituted_result")
    observed = payload.get("observed_content")
    if outcome == "unresolved":
        if result is not None:
            _fail(
                "reconciliation-unresolved",
                "an unresolved reconciliation carries no substituted_result",
            )
        if observed is not None:
            _fail("reconciliation-unresolved", "an unresolved reconciliation carries no observed_content")
        return
    if result is None:
        _fail("missing-field", "missing field(s): substituted_result")
    if observed is None:
        _fail("missing-field", "missing field(s): observed_content")
    check_content(observed, "observed_content")
    _object(result, "substituted_result")
    assert isinstance(result, dict)
    substitutes = payload["substitutes"]
    if substitutes == "operation-result":
        _exact_keys(result, SUBSTITUTED_OPERATION_FIELDS, "substituted_result")
        _enum(result["outcome"], OPERATION_OUTCOMES, "substituted_result.outcome")
        check_content(result["output_content"], "substituted_result.output_content")
        check_identity(result["identity"], "substituted_result.identity")
        nested = result["output_content"]
    else:
        extra = sorted(set(result) - set(PUBLISH_FIELDS))
        if extra:
            _fail("unexpected-field", f"substituted_result carries unknown field(s): {', '.join(extra)}")
        check_publish_outcome(result, "substituted_result")
        nested = result["content"]
        recomputed = digest(subject(REQUEST_SUBJECTS["publish.recorded"], result))
        if payload["request_digest"] != recomputed:
            _fail(
                "reconciliation-request",
                "request_digest differs from the digest of substituted_result's "
                "{stop_point, branch, content}",
            )
    if OUTCOME_MAPPING[substitutes][outcome] != result["outcome"]:
        _fail(
            "reconciliation-outcome",
            f"reconciliation_outcome {outcome} contradicts substituted_result.outcome "
            f"{result['outcome']}",
        )
    if observed != nested:
        _fail("reconciliation-content", "observed_content differs from the substituted content")


def _graph_diverged(payload: dict) -> None:
    required = (
        "vocabulary",
        "run_id",
        "prior_semantic_digest",
        "observed_semantic_digest",
        "successor_run_id",
    )
    _fields(payload, required, ASSURANCE_KEYS)
    _run_id(payload["run_id"], "run_id")
    _digest(payload["prior_semantic_digest"], "prior_semantic_digest")
    _digest(payload["observed_semantic_digest"], "observed_semantic_digest")
    _run_id(payload["successor_run_id"], "successor_run_id")
    if payload["successor_run_id"] == payload["run_id"]:
        _fail("mistyped", "successor_run_id must differ from run_id")
    if payload["prior_semantic_digest"] == payload["observed_semantic_digest"]:
        _fail("graph-not-diverged", "prior and observed semantic digests are equal")


# approval.consume: the shape is defined here so the word is reserved, but the
# journal refuses the record in Phase A: consuming an approval is an
# authority-store transition, never a journal line.
APPROVAL_CONSUME_FIELDS = BASE + ("capability_ref", "answer_ref", "request_digest")

RECORDS = {
    "attempt.begin": _attempt_begin,
    "node.transition": _node_transition,
    "operation.reserve": _operation("operation.reserve"),
    "operation.spawned": _operation("operation.spawned"),
    "operation.released": _operation("operation.released"),
    "operation.result": _operation("operation.result"),
    "reconciliation.result": _reconciliation_result,
    "graph.diverged": _graph_diverged,
    "gate.result": _gate_result,
    "review.recorded": _review_recorded,
    "publish.recorded": _publish_recorded,
}
EVENTS = tuple(RECORDS) + ("approval.consume",)


def check_assurance(payload: dict) -> None:
    for axis, (weak, strong) in ASSURANCE.items():
        value = payload.get(axis)
        if value is None:
            continue
        if value == strong:
            _fail(
                "strong-assurance",
                f"{axis}={strong} is refused: the journal never accepts the strong "
                "assurance value from a caller",
            )
        if value != weak:
            _fail("mistyped", f"{axis} must be {weak} (or absent)")


def validate_record(event: object, payload: object, *, run: str | None = None) -> dict:
    """Validate one schema-2 payload (the record without the journal envelope).
    Digests are recomputed and compared; run, when given, is the journal
    envelope's run, which run_id must equal. Raises VocabularyError."""
    if event == "approval.consume":
        _fail(
            "approval-consume-refused",
            "approval.consume is refused in Phase A: only the authority store can "
            "consume an approval",
        )
    if type(event) is not str or event not in RECORDS:
        _fail("unknown-event", f"{event} is not a schema-2 event")
    if type(payload) is not dict:
        _fail("mistyped", "payload must be an object")
    assert isinstance(payload, dict) and isinstance(event, str)
    reserved = sorted(ENVELOPE_KEYS & set(payload))
    if reserved:
        _fail("reserved-field", f"reserved envelope field(s): {', '.join(reserved)}")
    try:
        canonical_check(payload)
    except CanonicalError as error:
        _fail("not-canonical", str(error))
    if _has_newline(payload):
        _fail("newline", "values must not contain raw newlines")
    check_assurance(payload)
    if "vocabulary" in payload and payload["vocabulary"] != VOCABULARY:
        _fail("vocabulary", f"vocabulary must be {VOCABULARY}")
    RECORDS[event](payload)
    expected = request_digest(event, payload)
    if expected is not None and payload.get("request_digest") != expected:
        _fail(
            "request-digest-mismatch",
            "request_digest differs from the digest recomputed from its subject fields",
        )
    expected = result_digest(event, payload)
    if expected is not None and payload.get("result_digest") != expected:
        _fail(
            "result-digest-mismatch",
            "result_digest differs from the digest recomputed from its subject fields",
        )
    if run is not None and payload.get("run_id") != run:
        _fail("run-mismatch", "run_id differs from the journal envelope's run")
    return payload
