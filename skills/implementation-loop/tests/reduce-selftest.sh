#!/usr/bin/env bash
# Hermetic checks for lib/loopauth (task-graph-v1 Phase A, sub-unit 0a.1):
# canonical encoding and digests, the schema-2 vocabulary, and the pure
# reducer. The transition table, every row's evidence, and the full
# terminal_evidence matrix are a frozen oracle written out below; nothing
# here reads them from reduce.py or vocabulary.py. Fixture digests use their
# own frozen subjects and canonical encoder. The last section writes schema-1
# and schema-2 records through the real loop-journal CLI and reduces that
# segment. HOME is a scratch directory so the real ~/.config tree is never
# touched.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
LIB="$SCRIPT_DIR/../lib"
JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
RUN="$SCRIPT_DIR/../scripts/loop-run"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reduce-selftest.XXXXXX")" || exit 1

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
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
export PYTHONDONTWRITEBYTECODE=1
# A caller's declared attribution or context must not leak into fixtures.
unset LOOP_UNIT LOOP_ROUND LOOP_CONTEXT

PINNED_CHECKS=803
CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$CASE_STDERR" >&2
  fi
}

run_cmd() { # $1=name, remaining=command
  local name="$1"
  shift
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if "$@" >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

expect_output() { # $1=stream stdout|stderr $2=fixed string $3=description
  local stream="$1" needle="$2" description="$3" path=""
  if [[ "$stream" == stdout ]]; then path="$CASE_STDOUT"; else path="$CASE_STDERR"; fi
  if grep -Fq -- "$needle" "$path"; then
    pass "$description"
  else
    fail "$description (missing: $needle)"
  fi
}

field_from() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" | head -n 1
}

store_dir() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key))
PY
}

file_sum() { # $1=path
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

# A python check program prints one "ok<TAB>description" or
# "not ok<TAB>description<TAB>detail" line per check.
tally() { # $1=results file $2=stderr file $3=python exit status $4=label
  local verdict description detail
  CASE_STDOUT=""
  CASE_STDERR=""
  while IFS=$'\t' read -r verdict description detail; do
    if [[ "$verdict" == ok ]]; then
      pass "$description"
    else
      fail "$description${detail:+ -- $detail}"
    fi
  done < "$1"
  if [[ "$3" -ne 0 ]]; then
    CASE_STDERR="$2"
    fail "$4: the check program exited $3"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builder: frozen digest subjects and an independent canonical encoder
# ---------------------------------------------------------------------------
cat > "$TMP_ROOT/fixture.py" <<'PY'
"""reduce-selftest fixtures. Digests use the subjects frozen here and an
independent canonical encoder, never the library's."""

import hashlib
import json

VOCABULARY = "tg-v1.0a1"
TS = "2026-09-28T12:00:00Z"
RUN_ID = "20260928T120000Z-0a1a1a"
OTHER_RUN_ID = "20260928T120001Z-0b2b2b"
ENVELOPE = ("schema", "seq", "ts", "event", "run")
DROP = object()


def canon(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")


def D(value):
    return "sha256:" + hashlib.sha256(canon(value)).hexdigest()


# Frozen digest subjects (section 3.4).
OPERATION_REQUEST = ["invocation", "expected_preconditions"]
REQUEST_SUBJECTS = {
    "operation.reserve": OPERATION_REQUEST,
    "operation.spawned": OPERATION_REQUEST,
    "operation.released": OPERATION_REQUEST,
    "operation.result": OPERATION_REQUEST,
    "gate.result": ["suite_invocation", "input_content"],
    "review.recorded": ["request_id", "reviewed_content_digest"],
    "publish.recorded": ["stop_point", "branch", "content"],
    "node.transition": ["node_id", "attempt_id", "from", "to"],
}
ATTEMPT_REQUEST_SUBJECTS = {
    "unit": ["node_type", "stop_point", "node_spec_digest", "input_content", "dispatch"],
    "investigation": ["node_type", "node_spec_digest", "input_content", "dispatch"],
    "operation": [
        "node_type",
        "node_spec_digest",
        "input_content",
        "invocation",
        "catalog_entry_digest",
    ],
    "approval": ["node_type", "node_spec_digest", "envelope_digest"],
}
RESULT_SUBJECTS = {
    "operation.result": ["outcome", "producer", "log_digest", "identity", "output_content"],
    "gate.result": [
        "verdict",
        "gate_exit",
        "suite_exit",
        "binding",
        "producer",
        "log_digest",
        "output_content",
    ],
    "review.recorded": ["verdict", "reviewer", "findings_digest"],
    "publish.recorded": ["outcome", "sha", "pr", "head_sha", "error_code"],
    "node.transition": ["to", "evidence", "stop_point_result", "markers", "content"],
    "reconciliation.result": [
        "reconciliation_outcome",
        "method",
        "substitutes",
        "observed_content",
        "receipt_ref",
        "substituted_result",
        "producer",
    ],
}


def subject(fields, payload):
    return {field: payload.get(field) for field in fields}


def seal(event, payload):
    sealed = dict(payload)
    if event == "attempt.begin":
        fields = ATTEMPT_REQUEST_SUBJECTS.get(sealed.get("node_type"))
    else:
        fields = REQUEST_SUBJECTS.get(event)
    if fields is not None:
        sealed["request_digest"] = D(subject(fields, sealed))
    fields = RESULT_SUBJECTS.get(event)
    if fields is not None:
        sealed["result_digest"] = D(subject(fields, sealed))
    return sealed


def record_digest(event, payload):
    return D({"event": event, "payload": payload})


def git(head, tree):
    return {"kind": "git", "head": head * 40, "tree_oid": tree * 40}


def nongit(label):
    return {"kind": "non-git", "content_digest": D(["content", label])}


INPUT = git("a", "b")
COMMIT = git("c", "d")
COMMIT_SHA = "c" * 40
INTEGRATION = git("e", "d")
RECEIPT_OBJECT = git("f", "d")
WORKTREE = nongit("working-tree")
SNAPSHOT = D("run-snapshot")
PR_URL = "https://example.invalid/pr/1"
INVOCATION = {
    "argv": ["/usr/bin/env", "true"],
    "cwd": "/work",
    "env_digest": D("environment"),
    "executor_version": "executor-1",
}
IDENTITY = {
    "adapter": {"boot_id": "boot-1", "pid": 100, "pgid": 100, "start_time": "2026-09-28T11:59:00Z"},
    "effect_child": {"boot_id": "boot-1", "pid": 101, "pgid": 100, "start_time": "2026-09-28T11:59:01Z"},
}
PRODUCER = {"tool": "fixture-writer", "tool_digest": D("fixture-writer")}
DISPATCH = {"backend": "codex", "model": "model-1", "effort": "high", "prompt_digest": D("prompt")}


def publish_result(stop_point, outcome):
    result = {"stop_point": stop_point, "branch": "topic", "content": COMMIT, "outcome": outcome}
    if outcome == "published":
        result["sha"] = COMMIT_SHA
        if stop_point in ("pr", "merge"):
            result["pr"] = PR_URL
            result["head_sha"] = COMMIT_SHA
    else:
        result["error_code"] = "push-rejected"
    return result


def apply_extra(payload, extra):
    for key, value in extra.items():
        if value is DROP:
            payload.pop(key, None)
        else:
            payload[key] = value


class Scenario:
    def __init__(self, run_id=RUN_ID):
        self.run_id = run_id
        self.events = []
        self.pins = {}
        self.reserves = {}
        self.spawned = {}
        self.recons = {}

    @property
    def last(self):
        return len(self.events) - 1

    def payloads(self):
        return [
            (line["event"], {key: value for key, value in line.items() if key not in ENVELOPE})
            for line in self.events
            if line.get("schema") == 2
        ]

    def base(self, attempt):
        node = self.pins[attempt][0]
        return {
            "vocabulary": VOCABULARY,
            "run_id": self.run_id,
            "run_snapshot_digest": SNAPSHOT,
            "node_id": node,
            "node_spec_digest": D(["spec", node]),
            "attempt_id": attempt,
        }

    def add(self, event, payload, sealed=True):
        if sealed:
            payload = seal(event, payload)
        line = {"schema": 2, "seq": len(self.events) + 1, "ts": TS, "event": event, "run": self.run_id}
        line.update(payload)
        self.events.append(line)
        return payload

    def raw(self, line):
        self.events.append(line)
        return line

    def begin(self, node, attempt, node_type, stop_point=None, parent=None, **extra):
        self.pins[attempt] = (node, node_type, stop_point)
        payload = self.base(attempt)
        payload.update({"node_type": node_type, "input_content": INPUT})
        if node_type == "unit":
            payload["stop_point"] = stop_point
        if node_type in ("unit", "investigation"):
            payload["dispatch"] = DISPATCH
        if node_type == "operation":
            payload["invocation"] = INVOCATION
            payload["catalog_entry_digest"] = D("catalog-entry")
        if node_type == "approval":
            payload["envelope_digest"] = D("approval-envelope")
        if parent is not None:
            payload["parent_attempt_id"] = parent
        apply_extra(payload, extra)
        return self.add("attempt.begin", payload)

    def transition(self, attempt, frm, to, evidence, **extra):
        node, node_type, stop_point = self.pins[attempt]
        payload = self.base(attempt)
        payload.update(
            {"content": INPUT, "from": frm, "to": to, "node_type": node_type, "evidence": evidence}
        )
        if node_type == "unit":
            payload["stop_point"] = stop_point
        apply_extra(payload, extra)
        return self.add("node.transition", payload)

    def operation(self, event, attempt, **extra):
        payload = self.base(attempt)
        payload.update(
            {
                "invocation": INVOCATION,
                "expected_preconditions": {"branch": "main"},
                "retry_class": "reconcilable",
            }
        )
        if event == "operation.spawned":
            payload["identity"] = IDENTITY
        if event == "operation.result":
            payload.update(
                {
                    "content": COMMIT,
                    "outcome": "succeeded",
                    "producer": PRODUCER,
                    "log_digest": D("operation-log"),
                    "identity": IDENTITY,
                    "output_content": COMMIT,
                }
            )
        apply_extra(payload, extra)
        payload = self.add(event, payload)
        if event == "operation.reserve":
            self.reserves[attempt] = payload
        if event == "operation.spawned":
            self.spawned[attempt] = payload
        return payload

    def publish(self, attempt, outcome="published", **extra):
        stop_point = self.pins[attempt][2]
        payload = self.base(attempt)
        payload.update(publish_result(stop_point, outcome))
        apply_extra(payload, extra)
        return self.add("publish.recorded", payload)

    def gate(self, attempt, **extra):
        payload = self.base(attempt)
        payload.update(
            {
                "content": COMMIT,
                "policy": "strict",
                "purpose": "unit-final",
                "binding": "clean",
                "verdict": "green",
                "gate_exit": 0,
                "suite_exit": 0,
                "suite_invocation": INVOCATION,
                "input_content": COMMIT,
                "producer": PRODUCER,
                "log_digest": D("gate-log"),
                "output_content": COMMIT,
                "input_isolation": "endpoint-sampled",
            }
        )
        apply_extra(payload, extra)
        return self.add("gate.result", payload)

    def ref(self, kind, attempt, content=None, **claims):
        node = self.pins[attempt][0]
        reference = {
            "kind": kind,
            "digest": D(["claimed", kind, node, attempt]),
            "node_id": node,
            "attempt_id": attempt,
            "content": content,
        }
        reference.update(claims)
        return reference

    def record_ref(self, kind, event, payload, content=None, **claims):
        reference = {
            "kind": kind,
            "digest": record_digest(event, payload),
            "node_id": payload["node_id"],
            "attempt_id": payload["attempt_id"],
            "content": content,
        }
        reference.update(claims)
        return reference

    def recon_ref(self, attempt, record=None):
        """A reconciliation_ref that claims this attempt and names record."""
        record = record if record is not None else self.recons[attempt]
        reference = self.record_ref(
            record["method"], "reconciliation.result", record, record.get("observed_content")
        )
        reference["node_id"] = self.pins[attempt][0]
        reference["attempt_id"] = attempt
        return reference

    def start(self, attempt):
        self.transition(
            attempt,
            "ready",
            "starting",
            {
                "selection_ref": self.ref("selection", attempt),
                "authorization_ref": self.ref("authorization", attempt),
                "preconditions_digest": D("preconditions"),
            },
        )
        self.operation("operation.reserve", attempt)
        self.operation("operation.spawned", attempt)

    def run(self, attempt):
        self.start(attempt)
        self.transition(
            attempt,
            "starting",
            "running",
            {
                "identity": IDENTITY,
                "observation_ref": self.record_ref(
                    "operation-spawned", "operation.spawned", self.spawned[attempt]
                ),
            },
        )

    def lose(self, attempt):
        self.run(attempt)
        self.transition(attempt, "running", "unknown-outcome", {"lost_child": True})

    def block(self, attempt):
        self.transition(attempt, "ready", "blocked", {"request_ref": self.ref("request", attempt)})

    def reach(self, attempt, state):
        if state == "blocked":
            self.block(attempt)
        elif state == "starting":
            self.start(attempt)
        elif state == "running":
            self.run(attempt)
        elif state == "unknown-outcome":
            self.lose(attempt)
        elif state != "ready":
            raise ValueError(state)

    def reconciliation(
        self, attempt, outcome="succeeded", substitutes="operation-result", method="receipt-lookup", **extra
    ):
        stop_point = self.pins[attempt][2]
        payload = self.base(attempt)
        payload.update(
            {
                "reconciliation_outcome": outcome,
                "method": method,
                "substitutes": substitutes,
                "producer": PRODUCER,
            }
        )
        if method == "receipt-lookup":
            payload["receipt_ref"] = self.ref("provider-receipt", attempt)
        if substitutes == "operation-result":
            payload["request_digest"] = self.reserves[attempt]["request_digest"]
            if outcome != "unresolved":
                payload["observed_content"] = COMMIT
                payload["substituted_result"] = {
                    "outcome": outcome,
                    "output_content": COMMIT,
                    "identity": IDENTITY,
                }
        else:
            result = publish_result(stop_point, "published" if outcome == "succeeded" else "failed")
            payload["request_digest"] = D(subject(REQUEST_SUBJECTS["publish.recorded"], result))
            if outcome != "unresolved":
                payload["observed_content"] = result["content"]
                payload["substituted_result"] = result
        apply_extra(payload, extra)
        payload = self.add("reconciliation.result", payload)
        self.recons[attempt] = payload
        return payload
PY

# ---------------------------------------------------------------------------
# Pure checks: canonical encoding, digests, vocabulary, and the reducer
# ---------------------------------------------------------------------------
python3 - "$LIB" "$TMP_ROOT" > "$TMP_ROOT/pure.tsv" 2> "$TMP_ROOT/pure.stderr" <<'PY'
import copy
import hashlib
import json
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])

from loopauth import canonical, reduce, vocabulary  # noqa: E402
import fixture as fx  # noqa: E402
from fixture import (  # noqa: E402
    COMMIT,
    COMMIT_SHA,
    D,
    DROP,
    IDENTITY,
    INPUT,
    INTEGRATION,
    RECEIPT_OBJECT,
    WORKTREE,
    Scenario,
    git,
)


def emit(description, ok, detail=""):
    description = " ".join(str(description).split())
    if ok:
        print(f"ok\t{description}")
    else:
        print(f"not ok\t{description}\t{' '.join(str(detail).split())}")
    sys.stdout.flush()


def section(label, function):
    try:
        function()
    except Exception:
        emit(f"{label}: the section completes without raising", False, traceback.format_exc()[-600:])


# ===========================================================================
# The frozen oracle (sections 3.2 and 3.3), written out literally.
# ===========================================================================
def R(kinds, claims=None):
    return {"type": "ref", "kinds": list(kinds), "claims": dict(claims or {})}


def CONST(value):
    return {"type": "const", "value": value}


DIGEST = {"type": "digest"}
TEXT = {"type": "text"}
SHA = {"type": "sha"}
CONTENT = {"type": "content"}
IDENTITY_FIELD = {"type": "identity"}
CONTAINMENT = {"type": "containment"}
TERMINAL_FIELD = {"type": "terminal_evidence"}
FAILURE_FIELD = {"type": "failure_evidence"}


def ROW(frm, to, evidence, one_of=(), result="none", substitution=False):
    return {
        "from": frm,
        "to": to,
        "evidence": evidence,
        "one_of": list(one_of),
        "stop_point_result": result,
        "substitution": substitution,
    }


ORACLE_ROWS = [
    ROW("ready", "starting", {
        "selection_ref": R(["selection"]),
        "authorization_ref": R(["authorization"]),
        "preconditions_digest": DIGEST,
    }),
    ROW("ready", "blocked", {"request_ref": R(["request"])}),
    ROW("blocked", "ready", {
        "answer_ref": R(["answer"], {"answer": ["granted", "answered"]}),
        "revalidation_digest": DIGEST,
    }),
    ROW("blocked", "failed", {"answer_ref": R(["answer"], {"answer": ["denied"]})}),
    ROW("blocked", "parked", {
        "expiry_ref": R(["expiry"]),
        "no_permitted_actor": CONST(True),
    }, one_of=["expiry_ref", "no_permitted_actor"]),
    ROW("starting", "running", {
        "identity": IDENTITY_FIELD,
        "observation_ref": R(["operation-spawned"]),
    }),
    ROW("starting", "failed", {"spawn_error": TEXT, "effect": CONST("none")}),
    ROW("starting", "blocked", {
        "drift_ref": R(["drift"]),
        "barrier_closed_ref": R(["operation-reserve"]),
    }),
    ROW("running", "blocked", {"quiescence_ref": R(["quiescence"]), "request_ref": R(["request"])}),
    ROW("running", "succeeded", {"terminal_evidence": TERMINAL_FIELD}, result="pinned"),
    ROW("running", "failed", {"failure_evidence": FAILURE_FIELD}),
    ROW("running", "unknown-outcome", {"lost_child": CONST(True)}),
    ROW("unknown-outcome", "succeeded", {
        "reconciliation_ref": R(["reconciliation", "receipt-lookup"]),
        "terminal_evidence": TERMINAL_FIELD,
    }, result="pinned", substitution=True),
    ROW("unknown-outcome", "failed", {
        "reconciliation_ref": R(["reconciliation", "receipt-lookup"]),
        "failure_evidence": FAILURE_FIELD,
    }, substitution=True),
    ROW("unknown-outcome", "parked", {"unresolvable_reason": TEXT}),
    ROW("*", "cancelled", {"cancel_ref": R(["cancel"]), "quiescence_ref": R(["quiescence"])}),
    ROW("*", "parked", {"park_reason": TEXT}),
]

REVIEW_PASS = R(["review"], {"verdict": ["pass"], "reviewer": "present"})
GATE_GREEN = R(["gate"], {"verdict": ["green"], "input_content": "present"})
PUBLISH_PR = R(["publish"], {"outcome": ["published"], "pr": "present", "head_sha": "present"})
ORACLE_TERMINAL = {
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
        "relations": [
            ["review_ref", "gate_ref"],
            ["review_ref", "publish_ref"],
            ["gate_ref", "publish_ref"],
            ["review_ref", "sha"],
            ["gate_ref", "sha"],
            ["publish_ref", "sha"],
        ],
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
            "provider_receipt_ref": R(["provider-receipt"], {"receipt_object": "present", "outcome": ["merged"]}),
            "receipt_object": CONTENT,
            "target_containment": CONTAINMENT,
        },
        "equal": [
            ["publish_ref.head_sha", "sha"],
            ["receipt_object", "provider_receipt_ref.receipt_object"],
        ],
        "relations": [
            ["review_ref", "gate_ref"],
            ["review_ref", "publish_ref"],
            ["gate_ref", "publish_ref"],
            ["review_ref", "sha"],
            ["gate_ref", "sha"],
            ["publish_ref", "sha"],
            ["pre_merge_gate_ref", "integration_content"],
        ],
        "substitutable": {"publish_ref": "publish"},
    },
    "investigation": {
        "fields": {"dispatch_ref": R(["dispatch"]), "transcript_digest": DIGEST, "report_digest": DIGEST},
        "equal": [],
        "relations": [],
        "substitutable": {},
    },
    "operation": {
        "fields": {"operation_result_ref": R(["operation-result"], {"outcome": ["succeeded"]})},
        "equal": [],
        "relations": [],
        "substitutable": {"operation_result_ref": "operation-result"},
    },
    "approval": {
        "fields": {"answer_ref": R(["answer"], {"answer": ["granted"]})},
        "equal": [],
        "relations": [],
        "substitutable": {},
    },
}

DISPATCH_FAILURE = [R(["dispatch-end"], {"exit": "nonzero"}), R(["dispatch-abandoned"])]
ORACLE_FAILURE = {
    "unit": {
        "dispatch": DISPATCH_FAILURE,
        "review": [R(["review"], {"verdict": ["iterate"], "iteration_limit_reached": [True]})],
        "gate": [R(["gate"], {"verdict": ["red"]})],
        "publish": [R(["publish"], {"outcome": ["failed"]})],
        "integrate": [
            {
                "type": "ref",
                "kinds": ["gate"],
                "claims": {"verdict": ["red"], "input_content": "present"},
                "fields": {"integration_content": CONTENT},
                "equal": [["failing_ref.input_content", "integration_content"]],
            },
            R(["provider-receipt"], {"outcome": ["refused"]}),
        ],
    },
    "investigation": {"dispatch": DISPATCH_FAILURE},
    "operation": {"operation": [R(["operation-result"], {"outcome": ["failed"]})]},
}
ORACLE_FAILURE_STOP_POINTS = {"unit": {"integrate": ["merge"]}}

ORACLE_REFERENCE_KINDS = {
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
    "review": {"content": "required", "claims": {
        "verdict": ["enum", "pass", "iterate"],
        "reviewer": ["text"],
        "iteration_limit_reached": ["bool"],
    }},
    "gate": {"content": "required", "claims": {
        "verdict": ["enum", "green", "red"],
        "input_content": ["content"],
    }},
    "publish": {"content": "required", "claims": {
        "outcome": ["enum", "published", "failed"],
        "pr": ["text"],
        "head_sha": ["sha"],
    }},
    "provider-receipt": {"content": "any", "claims": {
        "receipt_object": ["content"],
        "outcome": ["enum", "merged", "refused"],
    }},
    "dispatch": {"content": "any", "claims": {}},
    "dispatch-end": {"content": "any", "claims": {"exit": ["int"]}},
    "dispatch-abandoned": {"content": "any", "claims": {}},
    "reconciliation": {"content": "any", "claims": {}},
    "receipt-lookup": {"content": "any", "claims": {}},
    "attestation": {"content": "any", "claims": {}},
}

ORACLE = {
    "states": {
        "non_terminal": ["ready", "blocked", "starting", "running", "unknown-outcome"],
        "terminal": ["succeeded", "failed", "cancelled", "parked"],
    },
    "node_types": ["unit", "investigation", "operation", "approval"],
    "stop_point_results": {
        "worktree": "reviewed-worktree",
        "commit": "gated-commit",
        "pr": "pr-open",
        "merge": "integrated",
    },
    "markers": ["stale", "superseded", "landed-but-ungated"],
    "reference_kinds": ORACLE_REFERENCE_KINDS,
    "rows": ORACLE_ROWS,
    "terminal_evidence": ORACLE_TERMINAL,
    "failure_evidence": ORACLE_FAILURE,
    "failure_stop_points": ORACLE_FAILURE_STOP_POINTS,
    "failure_substitutable": {"operation": "operation-result", "publish": "publish"},
}

NON_TERMINAL = ORACLE["states"]["non_terminal"]
TERMINAL = ORACLE["states"]["terminal"]
STATES = NON_TERMINAL + TERMINAL
PROFILE = {
    "unit/worktree": ("unit", "worktree"),
    "unit/commit": ("unit", "commit"),
    "unit/pr": ("unit", "pr"),
    "unit/merge": ("unit", "merge"),
    "investigation": ("investigation", None),
    "operation": ("operation", None),
    "approval": ("approval", None),
}
EXPECTED_RESULT = {
    "unit/worktree": "reviewed-worktree",
    "unit/commit": "gated-commit",
    "unit/pr": "pr-open",
    "unit/merge": "integrated",
    "investigation": "informational",
    "operation": None,
    "approval": None,
}
WEAKEST = {
    "input_isolation": "endpoint-sampled",
    "capability_assurance": "declared",
    "atomicity": "unproven",
    "conformance": "unproven",
}


def oracle_select(frm, to):
    """Specific rows first; a general row only from a non-terminal state with
    no specific row to the same target."""
    for row in ORACLE_ROWS:
        if row["from"] == frm and row["to"] == to:
            return row
    if frm in NON_TERMINAL:
        for row in ORACLE_ROWS:
            if row["from"] == "*" and row["to"] == to:
                return row
    return None


def row_from_states(row):
    if row["from"] != "*":
        return [row["from"]]
    return [state for state in NON_TERMINAL if oracle_select(state, row["to"]) is row]


def matrix_key(node_type, stop_point):
    return f"unit/{stop_point}" if node_type == "unit" else node_type


# ===========================================================================
# Evidence generated from the oracle
# ===========================================================================
CLAIM_DEFAULT = {
    "reviewer": "reviewer-1",
    "input_content": COMMIT,
    "pr": fx.PR_URL,
    "head_sha": COMMIT_SHA,
    "receipt_object": RECEIPT_OBJECT,
}


def make_ref(sc, attempt, spec):
    kind = spec["kinds"][0]
    if kind == "operation-spawned":
        return sc.record_ref(kind, "operation.spawned", sc.spawned[attempt])
    if kind == "operation-reserve":
        return sc.record_ref(kind, "operation.reserve", sc.reserves[attempt])
    if kind in ("reconciliation", "receipt-lookup"):
        return sc.recon_ref(attempt)
    content = COMMIT if ORACLE_REFERENCE_KINDS[kind]["content"] == "required" else None
    claims = {}
    for claim, requirement in spec["claims"].items():
        if isinstance(requirement, list):
            claims[claim] = requirement[0]
        elif requirement == "nonzero":
            claims[claim] = 1
        else:
            claims[claim] = copy.deepcopy(CLAIM_DEFAULT[claim])
    return sc.ref(kind, attempt, content, **claims)


def make_value(sc, attempt, name, spec):
    kind = spec["type"]
    if kind == "ref":
        return make_ref(sc, attempt, spec)
    if kind == "digest":
        return D(["evidence", name])
    if kind == "text":
        # The branch a publication names (fixture.publish_result) is "topic".
        return "topic" if name == "branch" else f"{name} text"
    if kind == "sha":
        return COMMIT_SHA
    if kind == "content":
        return {"integration_content": INTEGRATION, "receipt_object": RECEIPT_OBJECT}[name]
    if kind == "const":
        return spec["value"]
    if kind == "identity":
        return copy.deepcopy(IDENTITY)
    if kind == "containment":
        return {"target_ref": "refs/heads/main", "contains": True}
    if kind == "terminal_evidence":
        return terminal_evidence(sc, attempt)
    if kind == "failure_evidence":
        return failure_evidence(sc, attempt)
    raise ValueError(kind)


def terminal_evidence(sc, attempt, substituted=False):
    _node, node_type, stop_point = sc.pins[attempt]
    entry = ORACLE_TERMINAL[matrix_key(node_type, stop_point)]
    evidence = {name: make_value(sc, attempt, name, spec) for name, spec in entry["fields"].items()}
    if "pre_merge_gate_ref" in evidence:
        evidence["pre_merge_gate_ref"]["content"] = INTEGRATION
        evidence["pre_merge_gate_ref"]["input_content"] = INTEGRATION
    if substituted:
        kind = sc.recons[attempt]["substitutes"]
        for slot, slot_kind in entry["substitutable"].items():
            if slot_kind == kind:
                evidence.pop(slot)
    return evidence


PHASE_FOR = {kind: phase for phase, kind in ORACLE["failure_substitutable"].items()}


def failure_evidence(sc, attempt, substituted=False, phase=None, alternative=0):
    _node, node_type, _stop_point = sc.pins[attempt]
    phases = ORACLE_FAILURE[node_type]
    if phase is None:
        phase = PHASE_FOR[sc.recons[attempt]["substitutes"]] if substituted else next(iter(phases))
    evidence = {"phase": phase, "reason": f"{phase} failed"}
    if not substituted:
        spec = phases[phase][alternative]
        evidence["failing_ref"] = make_ref(sc, attempt, spec)
        for name, field in spec.get("fields", {}).items():
            evidence[name] = make_value(sc, attempt, name, field)
        if "integration_content" in evidence:
            # The pre-merge gate ran over the integration content.
            evidence["failing_ref"]["content"] = INTEGRATION
            evidence["failing_ref"]["input_content"] = INTEGRATION
    return evidence


def expected_result(sc, attempt):
    _node, node_type, stop_point = sc.pins[attempt]
    return EXPECTED_RESULT[matrix_key(node_type, stop_point)]


def row_evidence(sc, row, choice=None):
    evidence = {}
    for name, spec in row["evidence"].items():
        if row["one_of"] and name in row["one_of"] and name != (choice or row["one_of"][0]):
            continue
        if spec["type"] == "terminal_evidence":
            evidence[name] = terminal_evidence(sc, "a1", substituted=row["substitution"])
        elif spec["type"] == "failure_evidence":
            evidence[name] = failure_evidence(sc, "a1", substituted=row["substitution"])
        else:
            evidence[name] = make_value(sc, "a1", name, spec)
    return evidence


def row_setup(row, frm, node_type="operation", stop_point=None):
    sc = Scenario()
    sc.begin("n1", "a1", node_type, stop_point)
    sc.reach("a1", frm)
    if row["substitution"]:
        sc.reconciliation("a1", outcome=row["to"])
    return sc


def apply_row(sc, row, frm, evidence, **extra):
    if row["stop_point_result"] == "pinned" and "stop_point_result" not in extra:
        result = expected_result(sc, "a1")
        if result is not None:
            extra["stop_point_result"] = result
    return sc.transition("a1", frm, row["to"], evidence, **extra)


def wrong_value(spec):
    if spec["type"] == "const":
        return False if spec["value"] is True else "some-effect"
    return {
        "ref": "not-a-reference",
        "digest": "sha256:not-hex",
        "text": "",
        "sha": "not-a-sha",
        "content": {"kind": "svn", "revision": 7},
        "identity": {"adapter": {"pid": 1}},
        "containment": {"target_ref": "refs/heads/main"},
        "terminal_evidence": "not-an-object",
        "failure_evidence": "not-an-object",
    }[spec["type"]]


def other_kind(kinds):
    return next(kind for kind in sorted(ORACLE_REFERENCE_KINDS) if kind not in kinds)


def violate(reference, claim, requirement):
    if requirement == "present":
        reference.pop(claim)
    elif requirement == "nonzero":
        reference[claim] = 0
    else:
        claim_type = ORACLE_REFERENCE_KINDS[reference["kind"]]["claims"][claim]
        if claim_type[0] == "enum":
            reference[claim] = next(value for value in claim_type[1:] if value not in requirement)
        elif claim_type[0] == "bool":
            reference[claim] = not requirement[0]
        else:
            raise ValueError(claim_type)


def mutations(name, spec):
    out = [
        ("missing", lambda evidence: evidence.pop(name), "evidence-missing"),
        ("mistyped", lambda evidence: evidence.__setitem__(name, wrong_value(spec)), "evidence-mistyped"),
    ]
    if spec["type"] == "ref":
        out += [
            (
                "of the wrong kind",
                lambda evidence: evidence[name].__setitem__("kind", other_kind(spec["kinds"])),
                "evidence-wrong-kind",
            ),
            (
                "claiming another node",
                lambda evidence: evidence[name].__setitem__("node_id", "other-node"),
                "evidence-other-node",
            ),
            (
                "claiming another attempt",
                lambda evidence: evidence[name].__setitem__("attempt_id", "other-attempt"),
                "evidence-other-attempt",
            ),
        ]
    return out


# ===========================================================================
# Reduce and compare
# ===========================================================================
def verdicts(sc):
    result = reduce.reduce_run(sc.events)
    codes = {item["position"]: item["code"] for item in result["rejected"]}
    return result, [codes.get(record["position"], record["status"]) for record in result["records"]]


def expect(description, sc, want, predicate=None):
    """want: the last line's outcome ("accepted" or a rejection code), or a
    {position: outcome} map. Every other line must be accepted (schema 2),
    legacy (schema 1), or unknown-schema."""
    result, got = verdicts(sc)
    if not isinstance(want, dict):
        want = {sc.last: want}
    problems = []
    for position, outcome in enumerate(got):
        record = result["records"][position]
        default = {1: "legacy", 2: "accepted"}.get(record["schema"], "unknown-schema")
        expected = want.get(position, default)
        if outcome != expected:
            problems.append(f"line {position} {record['event']}: {outcome}, expected {expected}")
    if not problems and predicate is not None:
        message = predicate(result)
        if message:
            problems.append(message)
    emit(description, not problems, "; ".join(problems))
    return result


def node_is(node_id, state, **fields):
    def predicate(result):
        node = result["nodes"].get(node_id)
        if node is None:
            return f"no node {node_id}"
        if node["state"] != state:
            return f"{node_id} is {node['state']}, expected {state}"
        for key, value in fields.items():
            if node.get(key) != value:
                return f"{node_id}.{key} is {node.get(key)!r}, expected {value!r}"
        if node["completion_eligible"] is not False or result["completion_eligible"] is not False:
            return "something is completion-eligible"
        if any(status != "claimed" for status in node["guards"].values()):
            return f"a guard is not claimed: {node['guards']}"
        return None

    return predicate


def all_of(*predicates):
    def predicate(result):
        for item in predicates:
            message = item(result)
            if message:
                return message
        return None

    return predicate


def relations_are(node_id, statuses):
    """statuses: every relation's status in table order, or a {(left, right):
    status} map for the named relations only."""
    def predicate(result):
        relations = result["nodes"][node_id]["transitions"][-1]["relations"]
        found = [item["status"] for item in relations]
        if "identity" in found:
            return "a relation was recorded as identity"
        if isinstance(statuses, dict):
            got = {tuple(item["between"]): item["status"] for item in relations}
            wrong = {pair: got.get(pair) for pair, status in statuses.items() if got.get(pair) != status}
            return f"relations {wrong}, expected {statuses}" if wrong else None
        if found != statuses:
            return f"relations {found}, expected {statuses}"
        return None

    return predicate


# ===========================================================================
# 1. The reducer's table equals the frozen oracle
# ===========================================================================
def oracle_checks():
    table = reduce.transition_table()
    emit("oracle: the reducer's table equals the frozen oracle", table == ORACLE,
         [key for key in ORACLE if table.get(key) != ORACLE[key]])
    for key in ORACLE:
        emit(f"oracle: {key} equals the frozen oracle", table.get(key) == ORACLE[key], table.get(key))
    emit("oracle: the reducer has no key beyond the oracle", set(table) == set(ORACLE), sorted(table))
    rows = table.get("rows", [])
    emit("oracle: the reducer has exactly the oracle's 17 rows", len(rows) == len(ORACLE_ROWS) == 17, len(rows))
    for row in ORACLE_ROWS:
        match = [item for item in rows if item.get("from") == row["from"] and item.get("to") == row["to"]]
        emit(
            f"oracle: row {row['from']} -> {row['to']} and its evidence fields are in the reducer",
            len(match) == 1 and match[0] == row,
            match,
        )
    matrix = table.get("terminal_evidence", {})
    for key, entry in ORACLE_TERMINAL.items():
        emit(f"oracle: terminal_evidence {key} (references and content bindings)", matrix.get(key) == entry, matrix.get(key))
    failure = table.get("failure_evidence", {})
    for node_type, phases in ORACLE_FAILURE.items():
        emit(f"oracle: failure_evidence phases of {node_type}", failure.get(node_type) == phases, failure.get(node_type))
    mismatched = []
    pairs = 0
    for frm in STATES:
        for to in STATES:
            expected = oracle_select(frm, to)
            pairs += 1 if expected is not None else 0
            if reduce.select_row(frm, to) != expected:
                mismatched.append(f"{frm}->{to}")
    emit("oracle: row selection agrees with the oracle for all 81 state pairs", not mismatched, mismatched)
    emit("oracle: 23 of the 81 state pairs have a row", pairs == 23, pairs)


# ===========================================================================
# 2. Every row, accepted and refused, from the oracle
# ===========================================================================
def row_checks():
    for row in ORACLE_ROWS:
        for frm in row_from_states(row):
            for choice in row["one_of"] or [None]:
                sc = row_setup(row, frm)
                apply_row(sc, row, frm, row_evidence(sc, row, choice))
                label = f" via {choice}" if choice else ""
                expect(
                    f"row {frm} -> {row['to']}{label}: accepted with its evidence",
                    sc,
                    "accepted",
                    node_is("n1", row["to"]),
                )
    for row in ORACLE_ROWS:
        frm = row_from_states(row)[0]
        for choice in row["one_of"] or [None]:
            for name, spec in row["evidence"].items():
                if row["one_of"] and name in row["one_of"] and name != choice:
                    continue
                for label, mutate, code in mutations(name, spec):
                    sc = row_setup(row, frm)
                    evidence = row_evidence(sc, row, choice)
                    mutate(evidence)
                    apply_row(sc, row, frm, evidence)
                    expect(
                        f"row {frm} -> {row['to']}: {name} {label} is refused ({code})",
                        sc,
                        code,
                        node_is("n1", frm),
                    )
    row = oracle_select("blocked", "parked")
    sc = row_setup(row, "blocked")
    evidence = row_evidence(sc, row, "expiry_ref")
    evidence["no_permitted_actor"] = True
    apply_row(sc, row, "blocked", evidence)
    expect("row blocked -> parked: expiry_ref and no_permitted_actor together are refused", sc,
           "evidence-unexpected", node_is("n1", "blocked"))
    for row in ORACLE_ROWS:
        frm = row_from_states(row)[0]
        sc = row_setup(row, frm)
        evidence = row_evidence(sc, row)
        evidence["unlisted_ref"] = sc.ref("request", "a1")
        apply_row(sc, row, frm, evidence)
        expect(f"row {frm} -> {row['to']}: an evidence field the row does not name is refused",
               sc, "evidence-unexpected", node_is("n1", frm))


def reach_any(sc, state):
    if state in NON_TERMINAL:
        sc.reach("a1", state)
    elif state == "succeeded":
        sc.run("a1")
        sc.transition("a1", "running", "succeeded", {"terminal_evidence": {
            "operation_result_ref": sc.ref("operation-result", "a1", COMMIT, outcome="succeeded"),
        }})
    elif state == "failed":
        sc.start("a1")
        sc.transition("a1", "starting", "failed", {"spawn_error": "exec failed", "effect": "none"})
    elif state == "cancelled":
        sc.transition("a1", "ready", "cancelled", {
            "cancel_ref": sc.ref("cancel", "a1"),
            "quiescence_ref": sc.ref("quiescence", "a1"),
        })
    elif state == "parked":
        sc.transition("a1", "ready", "parked", {"park_reason": "held"})


def pair_checks():
    for frm in STATES:
        for to in STATES:
            if oracle_select(frm, to) is not None:
                continue
            sc = Scenario()
            sc.begin("n1", "a1", "operation")
            reach_any(sc, frm)
            sc.transition("a1", frm, to, {})
            if frm in TERMINAL:
                expect(f"terminal {frm} -> {to} is refused (from-terminal)", sc, "from-terminal", node_is("n1", frm))
            else:
                expect(f"pair {frm} -> {to} (not in the oracle) is refused (no-row)", sc, "no-row", node_is("n1", frm))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    reach_any(sc, "parked")
    sc.begin("n1", "a2", "operation", parent="a1")
    expect("leaving a terminal state is a new attempt: attempt.begin after parked is accepted", sc, "accepted",
           node_is("n1", "ready", attempt_id="a2", attempts=["a1", "a2"]))


def selection_checks():
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.block("a1")
    sc.transition("a1", "blocked", "parked", {"park_reason": "held"})
    expect("row selection: blocked -> parked never uses the general row (park_reason refused)", sc,
           "evidence-unexpected", node_is("n1", "blocked"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.lose("a1")
    sc.transition("a1", "unknown-outcome", "parked", {"park_reason": "held"})
    expect("row selection: unknown-outcome -> parked never uses the general row", sc,
           "evidence-unexpected", node_is("n1", "unknown-outcome"))
    sc.events.pop()
    sc.transition("a1", "unknown-outcome", "parked", {"unresolvable_reason": "no receipt"})
    expect("row selection: unknown-outcome -> parked uses its specific row", sc, "accepted", node_is("n1", "parked"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.transition("a1", "ready", "parked", {"park_reason": "held"})
    expect("row selection: ready -> parked uses the general row", sc, "accepted", node_is("n1", "parked"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.lose("a1")
    sc.reconciliation("a1")
    reference = sc.recon_ref("a1")
    reference["kind"] = "attestation"
    sc.transition("a1", "unknown-outcome", "succeeded", {"reconciliation_ref": reference, "terminal_evidence": {}})
    expect("attestation is refused for unknown-outcome -> succeeded", sc, "evidence-wrong-kind",
           node_is("n1", "unknown-outcome"))
    sc.events.pop()
    sc.transition("a1", "unknown-outcome", "failed", {
        "reconciliation_ref": reference,
        "failure_evidence": {"phase": "operation", "reason": "r"},
    })
    expect("attestation is refused for unknown-outcome -> failed", sc, "evidence-wrong-kind",
           node_is("n1", "unknown-outcome"))


# ===========================================================================
# 3. terminal_evidence for every node type and stop point
# ===========================================================================
def fresh(node_type, stop_point=None, attempt="a1", node="n1"):
    sc = Scenario()
    sc.begin(node, attempt, node_type, stop_point)
    sc.run(attempt)
    return sc


def succeed(sc, evidence, attempt="a1", **extra):
    if "stop_point_result" not in extra:
        result = expected_result(sc, attempt)
        if result is not None:
            extra["stop_point_result"] = result
    return sc.transition(attempt, "running", "succeeded", {"terminal_evidence": evidence}, **extra)


def terminal_checks():
    for key, entry in ORACLE_TERMINAL.items():
        node_type, stop_point = PROFILE[key]
        sc = fresh(node_type, stop_point)
        succeed(sc, terminal_evidence(sc, "a1"))
        result = expect(
            f"terminal {key}: full evidence is accepted with stop_point_result {EXPECTED_RESULT[key]}",
            sc,
            "accepted",
            node_is("n1", "succeeded", stop_point_result=EXPECTED_RESULT[key]),
        )
        guards = result["nodes"].get("n1", {}).get("guards", {})
        wanted = {f"running->succeeded:terminal_evidence.{name}" for name in entry["fields"]}
        emit(f"terminal {key}: every reference is a claimed guard", wanted <= set(guards)
             and all(guards[name] == "claimed" for name in wanted), sorted(guards))
        for name, spec in entry["fields"].items():
            sc = fresh(node_type, stop_point)
            evidence = terminal_evidence(sc, "a1")
            evidence.pop(name)
            succeed(sc, evidence)
            expect(f"terminal {key}: missing {name} is refused", sc, "evidence-missing", node_is("n1", "running"))
            if spec["type"] != "ref":
                sc = fresh(node_type, stop_point)
                evidence = terminal_evidence(sc, "a1")
                evidence[name] = wrong_value(spec)
                succeed(sc, evidence)
                expect(f"terminal {key}: mistyped {name} is refused", sc, "evidence-mistyped", node_is("n1", "running"))
                continue
            for label, field, value, code in (
                ("of the wrong kind", "kind", other_kind(spec["kinds"]), "evidence-wrong-kind"),
                ("claiming another node", "node_id", "other-node", "evidence-other-node"),
                ("claiming another attempt", "attempt_id", "other-attempt", "evidence-other-attempt"),
            ):
                sc = fresh(node_type, stop_point)
                evidence = terminal_evidence(sc, "a1")
                evidence[name][field] = value
                succeed(sc, evidence)
                expect(f"terminal {key}: {name} {label} is refused", sc, code, node_is("n1", "running"))
            for claim, requirement in spec["claims"].items():
                sc = fresh(node_type, stop_point)
                evidence = terminal_evidence(sc, "a1")
                violate(evidence[name], claim, requirement)
                succeed(sc, evidence)
                expect(f"terminal {key}: {name}.{claim} not {requirement} is refused", sc, "evidence-claim",
                       node_is("n1", "running"))
        sc = fresh(node_type, stop_point)
        evidence = terminal_evidence(sc, "a1")
        evidence["extra_ref"] = sc.ref("request", "a1")
        succeed(sc, evidence)
        expect(f"terminal {key}: a field outside its row is refused", sc, "evidence-unexpected", node_is("n1", "running"))


def stop_point_checks():
    sc = fresh("unit", "pr")
    succeed(sc, terminal_evidence(sc, "a1"), stop_point_result=None)
    expect("running -> succeeded with a null stop_point_result is refused", sc, "stop-point-result", node_is("n1", "running"))
    sc.events.pop()
    succeed(sc, terminal_evidence(sc, "a1"), stop_point_result=DROP)
    expect("running -> succeeded with no stop_point_result is refused", sc, "stop-point-result", node_is("n1", "running"))
    sc.events.pop()
    succeed(sc, terminal_evidence(sc, "a1"), stop_point_result="reviewed-worktree")
    expect("running -> succeeded with a stop_point_result not matching the pinned pr is refused", sc,
           "stop-point-result", node_is("n1", "running"))
    sc = fresh("investigation")
    succeed(sc, terminal_evidence(sc, "a1"), stop_point_result=None)
    expect("an investigation's succeeded without informational is refused", sc, "stop-point-result", node_is("n1", "running"))
    sc = fresh("operation")
    succeed(sc, terminal_evidence(sc, "a1"), stop_point_result="informational")
    expect("an operation's succeeded carrying a stop_point_result is refused", sc, "stop-point-result", node_is("n1", "running"))
    sc = fresh("unit", "pr")
    evidence = {"review_ref": sc.ref("review", "a1", COMMIT, verdict="pass", reviewer="r")}
    succeed(sc, evidence, stop_point="worktree", stop_point_result="reviewed-worktree")
    expect("a unit pinned to pr cannot choose the worktree row (stop_point differs from the pin)", sc,
           "pin-mismatch", node_is("n1", "running"))
    sc.events.pop()
    succeed(sc, evidence)
    expect("a unit pinned to pr offering only worktree evidence is refused", sc, "evidence-missing", node_is("n1", "running"))
    sc = fresh("unit", "pr")
    succeed(sc, {
        "dispatch_ref": sc.ref("dispatch", "a1"),
        "transcript_digest": D("transcript"),
        "report_digest": D("report"),
    }, node_type="investigation", stop_point=DROP, stop_point_result="informational")
    expect("a transition whose node_type differs from the attempt's pin is refused", sc, "pin-mismatch",
           node_is("n1", "running"))
    sc = Scenario()
    sc.begin("n1", "a1", "unit", "pr")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")}, stop_point="commit")
    expect("a non-terminal transition whose stop_point differs from the pin is refused", sc, "pin-mismatch",
           node_is("n1", "ready"))


def relation_checks():
    sc = fresh("unit", "pr")
    succeed(sc, terminal_evidence(sc, "a1"))
    expect("relations: exactly equal content is identity-claimed, never identity", sc, "accepted",
           relations_are("n1", ["identity-claimed"] * 6))
    sc = fresh("unit", "pr")
    evidence = terminal_evidence(sc, "a1")
    other_head = git("9", "d")
    evidence["gate_ref"]["content"] = other_head
    evidence["gate_ref"]["input_content"] = other_head
    succeed(sc, evidence)
    expect("relations: the same tree under a different head is unproven, and recorded, not refused", sc,
           "accepted", relations_are("n1", ["unproven", "identity-claimed", "unproven",
                                            "identity-claimed", "unproven", "identity-claimed"]))
    sc = fresh("unit", "commit")
    evidence = terminal_evidence(sc, "a1")
    evidence["review_ref"]["content"] = WORKTREE
    succeed(sc, evidence)
    expect("relations: a review of the working tree offered for a commit stop point is unproven", sc,
           "accepted", relations_are("n1", ["unproven", "unproven", "identity-claimed"]))
    sc = fresh("unit", "merge")
    succeed(sc, terminal_evidence(sc, "a1"))
    expect("relations: the pre-merge gate over the integration content is identity-claimed", sc,
           "accepted", relations_are("n1", ["identity-claimed"] * 7))
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["pre_merge_gate_ref"]["content"] = COMMIT
    evidence["pre_merge_gate_ref"]["input_content"] = COMMIT
    succeed(sc, evidence)
    expect("relations: a pre-merge gate over other content than the integration is unproven", sc,
           "accepted", relations_are("n1", ["identity-claimed"] * 6 + ["unproven"]))
    # The candidate commit: every referenced candidate content against sha.
    for key in ("unit/commit", "unit/pr", "unit/merge"):
        node_type, stop_point = PROFILE[key]
        pairs = [tuple(pair) for pair in ORACLE_TERMINAL[key]["relations"]]
        against_sha = [pair for pair in pairs if pair[1] == "sha"]
        between_refs = [pair for pair in pairs if pair[1] != "sha"]
        sc = fresh(node_type, stop_point)
        succeed(sc, terminal_evidence(sc, "a1"))
        expect(f"relations {key}: each candidate content whose head equals sha is identity-claimed against sha",
               sc, "accepted", relations_are("n1", {pair: "identity-claimed" for pair in against_sha}))
        sc = fresh(node_type, stop_point)
        evidence = terminal_evidence(sc, "a1")
        evidence["sha"] = "9" * 40
        if "publish_ref" in evidence:
            evidence["publish_ref"]["head_sha"] = "9" * 40
        succeed(sc, evidence)
        expect(f"relations {key}: references equal to each other whose head differs from sha are unproven "
               "against sha (recorded, not refused)", sc, "accepted",
               relations_are("n1", {**{pair: "identity-claimed" for pair in between_refs},
                                    **{pair: "unproven" for pair in against_sha}}))
    sc = fresh("unit", "commit")
    evidence = terminal_evidence(sc, "a1")
    for name in ("review_ref", "gate_ref"):
        evidence[name]["content"] = WORKTREE
    evidence["gate_ref"]["input_content"] = WORKTREE
    succeed(sc, evidence)
    expect("relations unit/commit: equal non-git content is identity-claimed between the references and unproven "
           "against sha", sc, "accepted", relations_are("n1", ["identity-claimed", "unproven", "unproven"]))
    sc = fresh("unit", "commit")
    evidence = terminal_evidence(sc, "a1")
    evidence["review_ref"]["content"] = git("c", "1")
    succeed(sc, evidence)
    expect("relations unit/commit: a content whose head is sha is identity-claimed against sha whatever its tree; "
           "the differing trees stay unproven between the references", sc, "accepted",
           relations_are("n1", ["unproven", "identity-claimed", "identity-claimed"]))
    sc = lost("unit", "pr")
    moved = fx.publish_result("pr", "published")
    moved["content"] = git("9", "d")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation", substituted_result=moved,
                      observed_content=moved["content"],
                      request_digest=D(fx.subject(fx.REQUEST_SUBJECTS["publish.recorded"], moved)))
    resolve(sc, "succeeded")
    expect("relations unit/pr: a substituted publication whose content's head differs from sha is unproven "
           "against sha", sc, "accepted",
           relations_are("n1", {("publish_ref", "sha"): "unproven", ("review_ref", "publish_ref"): "unproven",
                                ("review_ref", "sha"): "identity-claimed"}))
    for key in ("unit/pr", "unit/merge"):
        node_type, stop_point = PROFILE[key]
        sc = fresh(node_type, stop_point)
        evidence = terminal_evidence(sc, "a1")
        evidence["publish_ref"]["head_sha"] = "9" * 40
        succeed(sc, evidence)
        expect(f"{key}: a publish_ref whose head_sha differs from sha is refused", sc, "evidence-inconsistent",
               node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["target_containment"]["contains"] = False
    succeed(sc, evidence)
    expect("unit/merge: a claimed contains: false is refused", sc, "not-contained", node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["receipt_object"] = git("1", "d")
    succeed(sc, evidence)
    expect("unit/merge: a receipt_object differing from the receipt's object is refused", sc,
           "evidence-inconsistent", node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["provider_receipt_ref"]["receipt_object"] = git("1", "d")
    succeed(sc, evidence)
    expect("unit/merge: a receipt naming another object than receipt_object is refused", sc,
           "evidence-inconsistent", node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["target_containment"]["contains"] = False
    sc.transition("a1", "running", "parked", {"park_reason": "landed without a gate"}, markers=["landed-but-ungated"])
    expect("unit/merge: a landed but ungated merge may be parked with the landed-but-ungated marker", sc,
           "accepted", node_is("n1", "parked", markers=["landed-but-ungated"], stop_point_result=None))


# ===========================================================================
# 4. failure_evidence
# ===========================================================================
def failure_pin(node_type, phase):
    """The stop point a failure test pins: the phase's first admissible stop
    point when the oracle restricts it, else pr for a unit."""
    if node_type != "unit":
        return None
    return ORACLE_FAILURE_STOP_POINTS.get(node_type, {}).get(phase, ["pr"])[0]


def failure_checks():
    for node_type, phases in ORACLE_FAILURE.items():
        for phase, alternatives in phases.items():
            stop_point = failure_pin(node_type, phase)
            for index, spec in enumerate(alternatives):
                sc = fresh(node_type, stop_point)
                sc.transition("a1", "running", "failed",
                              {"failure_evidence": failure_evidence(sc, "a1", phase=phase, alternative=index)})
                expect(f"failure {node_type}/{phase} with a {spec['kinds'][0]} failing_ref is accepted", sc,
                       "accepted", node_is("n1", "failed", stop_point_result=None))
                for claim, requirement in spec["claims"].items():
                    sc = fresh(node_type, stop_point)
                    evidence = failure_evidence(sc, "a1", phase=phase, alternative=index)
                    violate(evidence["failing_ref"], claim, requirement)
                    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
                    expect(f"failure {node_type}/{phase}: failing_ref.{claim} not {requirement} is refused", sc,
                           "evidence-claim", node_is("n1", "running"))
            sc = fresh(node_type, stop_point)
            evidence = failure_evidence(sc, "a1", phase=phase)
            allowed = {kind for spec in alternatives for kind in spec["kinds"]}
            evidence["failing_ref"]["kind"] = next(kind for kind in ("request", "review", "gate") if kind not in allowed)
            sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
            expect(f"failure {node_type}/{phase}: a failing_ref of the wrong kind for the phase is refused", sc,
                   "evidence-wrong-kind", node_is("n1", "running"))
            sc = fresh(node_type, stop_point)
            evidence = failure_evidence(sc, "a1", phase=phase)
            evidence.pop("failing_ref")
            sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
            expect(f"failure {node_type}/{phase}: running -> failed without failing_ref is refused", sc,
                   "evidence-missing", node_is("n1", "running"))
    sc = fresh("unit", "pr")
    sc.transition("a1", "running", "failed", {"failure_evidence": {
        "phase": "dispatch",
        "reason": "exit 3",
        "failing_ref": sc.ref("dispatch-end", "a1", exit=3),
    }})
    expect("running -> failed is accepted with only a dispatch-phase failure (no review, no gate)", sc,
           "accepted", node_is("n1", "failed"))
    sc = fresh("unit", "pr")
    sc.transition("a1", "running", "failed", {"failure_evidence": {
        "phase": "gate",
        "reason": "gate red",
        "failing_ref": sc.ref("review", "a1", COMMIT, verdict="iterate", iteration_limit_reached=True),
    }})
    expect("running -> failed with a review failing_ref for the gate phase is refused", sc,
           "evidence-wrong-kind", node_is("n1", "running"))
    sc = fresh("approval")
    sc.transition("a1", "running", "failed", {"failure_evidence": {
        "phase": "dispatch",
        "reason": "none",
        "failing_ref": sc.ref("dispatch-abandoned", "a1"),
    }})
    expect("an approval node has no running -> failed phase", sc, "failure-phase", node_is("n1", "running"))
    sc = fresh("investigation")
    sc.transition("a1", "running", "failed", {"failure_evidence": {
        "phase": "gate",
        "reason": "none",
        "failing_ref": sc.ref("gate", "a1", COMMIT, verdict="red"),
    }})
    expect("an investigation has no gate failure phase", sc, "failure-phase", node_is("n1", "running"))
    # integrate: only a unit pinned to merge integrates; its gate is the
    # pre-merge gate over integration_content.
    integrate = ORACLE_FAILURE["unit"]["integrate"]
    for stop_point in ("worktree", "commit", "pr"):
        for index, spec in enumerate(integrate):
            sc = fresh("unit", stop_point)
            sc.transition("a1", "running", "failed", {"failure_evidence": failure_evidence(
                sc, "a1", phase="integrate", alternative=index)})
            expect(f"failure unit/integrate with a {spec['kinds'][0]} failing_ref is refused for a unit pinned to "
                   f"{stop_point}", sc, "failure-phase", node_is("n1", "running"))
    sc = fresh("unit", "merge")
    sc.transition("a1", "running", "failed", {"failure_evidence": failure_evidence(sc, "a1", phase="integrate")})
    expect("failure unit/integrate: the pre-merge red gate over the integration content is accepted for a merge unit",
           sc, "accepted", node_is("n1", "failed", stop_point_result=None))
    sc = fresh("unit", "merge")
    sc.transition("a1", "running", "failed", {"failure_evidence": failure_evidence(
        sc, "a1", phase="integrate", alternative=1)})
    expect("failure unit/integrate: a refused provider receipt is accepted for a merge unit", sc, "accepted",
           node_is("n1", "failed", stop_point_result=None))
    sc = fresh("unit", "merge")
    evidence = failure_evidence(sc, "a1", phase="integrate")
    evidence["failing_ref"]["content"] = COMMIT
    evidence["failing_ref"]["input_content"] = COMMIT
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("failure unit/integrate: a red gate whose input_content differs from integration_content is refused", sc,
           "evidence-inconsistent", node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = failure_evidence(sc, "a1", phase="integrate")
    evidence.pop("integration_content")
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("failure unit/integrate: a red gate without integration_content is refused", sc, "evidence-missing",
           node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = failure_evidence(sc, "a1", phase="integrate")
    evidence["integration_content"] = "not-content"
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("failure unit/integrate: a mistyped integration_content is refused", sc, "evidence-mistyped",
           node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = failure_evidence(sc, "a1", phase="integrate", alternative=1)
    evidence["integration_content"] = INTEGRATION
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("failure unit/integrate: a provider receipt carries no integration_content", sc, "evidence-unexpected",
           node_is("n1", "running"))
    sc = fresh("unit", "merge")
    evidence = failure_evidence(sc, "a1", phase="gate")
    evidence["integration_content"] = INTEGRATION
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("failure unit/gate: integration_content belongs only to the integrate phase", sc, "evidence-unexpected",
           node_is("n1", "running"))


# ===========================================================================
# 5. Reconciliation substitutes for the lost result
# ===========================================================================
def lost(node_type="operation", stop_point=None):
    sc = Scenario()
    sc.begin("n1", "a1", node_type, stop_point)
    sc.lose("a1")
    return sc


def resolve(sc, to, record=None, **extra):
    evidence = {"reconciliation_ref": sc.recon_ref("a1", record)}
    if to == "succeeded":
        evidence["terminal_evidence"] = terminal_evidence(sc, "a1", substituted=True)
        result = expected_result(sc, "a1")
        if result is not None and "stop_point_result" not in extra:
            extra["stop_point_result"] = result
    else:
        evidence["failure_evidence"] = failure_evidence(sc, "a1", substituted=True)
    return sc.transition("a1", "unknown-outcome", to, evidence, **extra)


def reconciliation_checks():
    for method in ("receipt-lookup", "reconciliation"):
        for to in ("succeeded", "failed"):
            sc = lost()
            sc.reconciliation("a1", outcome=to, method=method)
            resolve(sc, to)
            slot = "terminal_evidence.operation_result_ref" if to == "succeeded" else "failure_evidence.failing_ref"
            expect(
                f"an operation that crashed after its effect with no operation.result, resolved by {method} to {to}, is accepted",
                sc,
                "accepted",
                all_of(node_is("n1", to), lambda result, slot=slot: None
                       if result["nodes"]["n1"]["transitions"][-1]["substituted"] == slot else "substituted slot"),
            )
    sc = lost()
    record = sc.reconciliation("a1")
    reference = sc.recon_ref("a1")
    reference["kind"] = "reconciliation"
    sc.transition("a1", "unknown-outcome", "succeeded", {"reconciliation_ref": reference, "terminal_evidence": {}})
    expect("a reconciliation_ref whose kind differs from the record's method is refused", sc,
           "reconciliation-method", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", outcome="succeeded", substitutes="operation-result")
    resolve(sc, "succeeded")
    expect("a substitute naming another kind than the pinned row's missing reference is refused", sc,
           "substitution-kind", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "commit")
    sc.reconciliation("a1", outcome="succeeded", substitutes="publish")
    resolve(sc, "succeeded")
    expect("a commit unit has no substitutable reference (a lost dispatch can only be parked)", sc,
           "substitution-kind", node_is("n1", "unknown-outcome"))
    sc = lost()
    sc.reconciliation("a1", outcome="failed")
    sc.transition("a1", "unknown-outcome", "succeeded", {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": {}})
    expect("a substitute whose reconciliation_outcome (failed) disagrees with the transition (succeeded) is refused",
           sc, "substitution-direction", node_is("n1", "unknown-outcome"))
    sc = lost()
    sc.reconciliation("a1", outcome="succeeded")
    sc.transition("a1", "unknown-outcome", "failed", {
        "reconciliation_ref": sc.recon_ref("a1"),
        "failure_evidence": {"phase": "operation", "reason": "r"},
    })
    expect("a substitute whose reconciliation_outcome (succeeded) disagrees with the transition (failed) is refused",
           sc, "substitution-direction", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", outcome="succeeded", substitutes="publish", method="reconciliation")
    evidence = terminal_evidence(sc, "a1", substituted=True)
    evidence.pop("gate_ref")
    sc.transition("a1", "unknown-outcome", "succeeded",
                  {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": evidence},
                  stop_point_result="pr-open")
    expect("a second substituted (missing) reference is refused", sc, "evidence-missing", node_is("n1", "unknown-outcome"))
    sc = lost()
    sc.reconciliation("a1")
    sc.transition("a1", "unknown-outcome", "succeeded", {
        "reconciliation_ref": sc.recon_ref("a1"),
        "terminal_evidence": {
            "operation_result_ref": sc.ref("operation-result", "a1", COMMIT, outcome="succeeded"),
        },
    })
    expect("a substitute for a reference that is present is refused", sc, "substitution-present",
           node_is("n1", "unknown-outcome"))
    for label, extra, code in (
        ("run_id", {"run_id": fx.OTHER_RUN_ID}, "run-mismatch"),
        ("node_id", {"node_id": "other-node"}, "envelope-mismatch"),
        ("attempt_id", {"attempt_id": "a9"}, "no-attempt"),
    ):
        sc = lost()
        record = sc.reconciliation("a1", method="reconciliation", **extra)
        resolve(sc, "succeeded", record)
        expect(f"a substitute whose {label} differs from the attempt's is refused", sc,
               {sc.last - 1: code, sc.last: "reconciliation-missing"}, node_is("n1", "unknown-outcome"))
    sc = lost()
    sc.reconciliation("a1", request_digest=D("another request"))
    resolve(sc, "succeeded")
    expect("an operation substitute whose request_digest is not the attempt's operation.reserve request is refused",
           sc, {sc.last - 1: "substitution-request", sc.last: "reconciliation-missing"}, node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation", request_digest=D("another request"))
    resolve(sc, "succeeded")
    expect("a publish substitute whose request_digest is not recomputed from substituted_result is refused", sc,
           {sc.last - 1: "reconciliation-request", sc.last: "reconciliation-missing"}, node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    commit_result = fx.publish_result("commit", "published")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation", substituted_result=commit_result,
                      request_digest=D(fx.subject(fx.REQUEST_SUBJECTS["publish.recorded"], commit_result)))
    expect("a publish substitute whose stop_point differs from the pinned stop point is refused", sc,
           "substitution-request")
    sc = lost()
    record = sc.reconciliation("a1")
    begin_request = sc.events[0]["request_digest"]
    resolve(sc, "succeeded")
    expect("a valid operation substitute whose request_digest differs from attempt.begin's is accepted", sc,
           "accepted", all_of(node_is("n1", "succeeded"), lambda result: None
                               if record["request_digest"] != begin_request else "request digests coincide"))
    for substitutes, outcome, nested in (
        ("operation-result", "succeeded", "failed"),
        ("operation-result", "failed", "succeeded"),
        ("publish", "succeeded", "failed"),
        ("publish", "failed", "published"),
    ):
        sc = lost("unit", "pr") if substitutes == "publish" else lost()
        if substitutes == "publish":
            result = fx.publish_result("pr", nested)
        else:
            result = {"outcome": nested, "output_content": COMMIT, "identity": IDENTITY}
        sc.reconciliation("a1", outcome=outcome, substitutes=substitutes, method="reconciliation",
                          substituted_result=result)
        expect(f"a contradictory pair is refused: {substitutes} reconciliation_outcome {outcome} with outcome {nested}",
               sc, "reconciliation-outcome")
    sc = lost()
    sc.reconciliation("a1", observed_content=git("9", "9"))
    expect("a substitute whose observed_content differs from the nested content is refused", sc, "reconciliation-content")
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation", observed_content=git("9", "9"))
    expect("a publish substitute whose observed_content differs from substituted_result.content is refused", sc,
           "reconciliation-content")
    sc = lost()
    sc.reconciliation("a1", substitutes="dispatch-end")
    expect("substitutes: dispatch-end is refused", sc, "substitutes-dispatch-end")
    sc = lost()
    record = sc.reconciliation("a1", outcome="unresolved")
    expect("an unresolved reconciliation with a null substituted_result is accepted and leaves unknown-outcome", sc,
           "accepted", node_is("n1", "unknown-outcome"))
    sc.transition("a1", "unknown-outcome", "succeeded", {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": {}})
    expect("an unresolved reconciliation substitutes nothing: unknown-outcome -> succeeded is refused", sc,
           "reconciliation-unresolved", node_is("n1", "unknown-outcome"))
    sc.events.pop()
    sc.transition("a1", "unknown-outcome", "parked", {"unresolvable_reason": "no receipt"})
    expect("after an unresolved reconciliation only unknown-outcome -> parked follows", sc, "accepted",
           node_is("n1", "parked"))
    sc = lost()
    sc.reconciliation("a1", outcome="unresolved", substituted_result=None, observed_content=None)
    expect("an unresolved reconciliation carrying substituted_result explicitly null is accepted", sc, "accepted")
    sc = lost()
    sc.reconciliation("a1", outcome="unresolved",
                      substituted_result={"outcome": "succeeded", "output_content": COMMIT, "identity": IDENTITY})
    expect("an unresolved reconciliation with a non-null substituted_result is refused", sc, "reconciliation-unresolved")
    sc = lost("unit", "pr")
    bad = fx.publish_result("pr", "published")
    bad["head_sha"] = "9" * 40
    sc.reconciliation("a1", substitutes="publish", method="reconciliation", substituted_result=bad)
    expect("a pr publish substitute whose head_sha differs from sha is refused", sc, "publish-head-sha")
    for existing in ("succeeded", "failed"):
        sc = lost()
        sc.operation("operation.result", "a1", outcome=existing)
        sc.reconciliation("a1", outcome="succeeded")
        resolve(sc, "succeeded")
        agree = "agrees" if existing == "succeeded" else "conflicts"
        expect(f"a substitution is refused when an operation.result for the attempt and request exists ({agree})",
               sc, "substitution-not-absent", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.publish("a1", "failed")
    sc.reconciliation("a1", outcome="succeeded", substitutes="publish", method="reconciliation")
    resolve(sc, "succeeded")
    expect("a publish substitution is refused when a publish.recorded for the request exists", sc,
           "substitution-not-absent", node_is("n1", "unknown-outcome"))
    sc = lost()
    first = sc.reconciliation("a1")
    sc.reconciliation("a1", method="reconciliation")
    resolve(sc, "succeeded", first)
    expect("two substitutes for one record are refused", sc, "substitution-duplicate", node_is("n1", "unknown-outcome"))
    sc = lost()
    sc.reconciliation("a1")
    sc.events[-1]["result_digest"] = D("not the result subject")
    expect("a reconciliation record whose result_digest differs from the recomputed one is refused", sc,
           "result-digest-mismatch")
    sc = lost()
    sc.reconciliation("a1")
    resolve(sc, "succeeded")
    sc.operation("operation.result", "a1")
    expect("an operation.result arriving after its substitution is refused", sc, "substituted", node_is("n1", "succeeded"))
    sc = fresh("operation")
    sc.reconciliation("a1")
    expect("a reconciliation for an attempt that is not unknown-outcome is refused", sc, "reconciliation-state")
    for to in ("succeeded", "failed"):
        for key in ("unit/pr", "unit/merge"):
            node_type, stop_point = PROFILE[key]
            sc = lost(node_type, stop_point)
            sc.reconciliation("a1", outcome=to, substitutes="publish", method="reconciliation")
            resolve(sc, to)
            expect(f"{key}: a {to} publish substitute is accepted", sc, "accepted",
                   node_is("n1", to, stop_point_result=EXPECTED_RESULT[key] if to == "succeeded" else None))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation")
    evidence = terminal_evidence(sc, "a1", substituted=True)
    evidence["sha"] = "9" * 40
    sc.transition("a1", "unknown-outcome", "succeeded",
                  {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": evidence},
                  stop_point_result="pr-open")
    expect("a publish substitute whose sha differs from the terminal evidence's sha is refused", sc,
           "substitution-content", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation")
    evidence = terminal_evidence(sc, "a1", substituted=True)
    evidence.pop("review_ref")
    sc.transition("a1", "unknown-outcome", "succeeded",
                  {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": evidence},
                  stop_point_result="pr-open")
    expect("unknown-outcome -> succeeded with a reconciliation but without the pinned row's review_ref is refused",
           sc, "evidence-missing", node_is("n1", "unknown-outcome"))
    sc.events.pop()
    sc.transition("a1", "unknown-outcome", "succeeded",
                  {"reconciliation_ref": sc.recon_ref("a1"), "terminal_evidence": terminal_evidence(sc, "a1", substituted=True)},
                  stop_point_result="gated-commit")
    expect("unknown-outcome -> succeeded with a reconciliation but a non-matching stop_point_result is refused",
           sc, "stop-point-result", node_is("n1", "unknown-outcome"))
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish", method="reconciliation")
    resolve(sc, "succeeded", stop_point_result=None)
    expect("unknown-outcome -> succeeded with a null stop_point_result is refused", sc, "stop-point-result",
           node_is("n1", "unknown-outcome"))


# ===========================================================================
# 6. Markers and the stop-point result
# ===========================================================================
def marker_checks():
    for label, value, expected in (
        ("omitted", DROP, []),
        ("null", None, []),
        ("empty", [], []),
        ("populated", ["stale", "landed-but-ungated"], ["landed-but-ungated", "stale"]),
    ):
        sc = fresh("operation")
        sc.transition("a1", "running", "parked", {"park_reason": "held"}, markers=value)
        expect(f"markers {label} fold to {expected}", sc, "accepted", node_is("n1", "parked", markers=expected))
    sc = fresh("operation")
    sc.transition("a1", "running", "parked", {"park_reason": "held"}, markers=["stale", "stale"])
    expect("duplicate markers are refused", sc, "markers", node_is("n1", "running"))
    sc = fresh("operation")
    sc.transition("a1", "running", "parked", {"park_reason": "held"}, markers=["done"])
    expect("an unknown marker word is refused", sc, "markers", node_is("n1", "running"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")}, markers=["superseded"])
    expect("markers are accepted on a non-succeeded node (blocked)", sc, "accepted",
           node_is("n1", "blocked", markers=["superseded"], stop_point_result=None))
    sc = fresh("operation")
    sc.transition("a1", "running", "parked", {"park_reason": "landed"}, markers=["landed-but-ungated"])
    expect("a marker is never success: a landed-but-ungated node stays parked with no result", sc, "accepted",
           node_is("n1", "parked", markers=["landed-but-ungated"], stop_point_result=None))
    sc = fresh("operation")
    succeed(sc, terminal_evidence(sc, "a1"), markers=["stale"])
    expect("markers on a succeeded node are recorded and certify nothing", sc, "accepted",
           node_is("n1", "succeeded", markers=["stale"]))
    sc = fresh("operation")
    sc.transition("a1", "running", "parked", {"park_reason": "held"}, stop_point_result="informational")
    expect("a stop-point result on a non-succeeded node (parked) is refused", sc, "stop-point-result",
           node_is("n1", "running"))
    sc = fresh("unit", "pr")
    sc.transition("a1", "running", "failed", {"failure_evidence": failure_evidence(sc, "a1")},
                  stop_point_result="pr-open")
    expect("a stop-point result on a non-succeeded node (failed) is refused", sc, "stop-point-result",
           node_is("n1", "running"))


# ===========================================================================
# 7. Attempts, pins, observation, and the closed barrier
# ===========================================================================
def attempt_checks():
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.pins["a9"] = ("n1", "operation", None)
    sc.transition("a9", "ready", "blocked", {"request_ref": sc.ref("request", "a9")})
    expect("a transition for an attempt with no attempt.begin is refused", sc, "no-attempt", node_is("n1", "ready"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.begin("n1", "a2", "operation", parent="a1")
    expect("a new attempt while the node's attempt is open is refused", sc, "attempt-open", node_is("n1", "ready", attempt_id="a1"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.begin("n1", "a1", "operation")
    expect("a repeated attempt_id is refused", sc, "duplicate-attempt")
    sc = Scenario()
    sc.begin("n1", "a1", "operation", parent="a0")
    expect("a node's first attempt naming a parent is refused", sc, "parent-attempt")
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    reach_any(sc, "cancelled")
    sc.begin("n1", "a2", "operation")
    expect("a new attempt without parent_attempt_id is refused", sc, "parent-attempt")
    sc.events.pop()
    sc.begin("n1", "a2", "investigation", parent="a1")
    expect("a new attempt changing the node_type is refused", sc, "node-type-changed")
    sc.events.pop()
    sc.begin("n1", "a2", "operation", parent="a1")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")})
    expect("a transition of a superseded attempt is refused", sc, "stale-attempt", node_is("n1", "ready", attempt_id="a2"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.transition("a1", "starting", "running", {
        "identity": IDENTITY,
        "observation_ref": sc.ref("operation-spawned", "a1"),
    })
    expect("a transition whose from is not the attempt's state is refused", sc, "from-mismatch", node_is("n1", "ready"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")}, node_spec_digest=D("other spec"))
    expect("a transition whose node_spec_digest differs from the attempt's is refused", sc, "envelope-mismatch",
           node_is("n1", "ready"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.begin("n2", "b1", "operation", run_snapshot_digest=D("other snapshot"))
    expect("an attempt whose run_snapshot_digest differs from the run's is refused", sc, "snapshot-mismatch")
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.add("graph.diverged", {
        "vocabulary": fx.VOCABULARY,
        "run_id": fx.RUN_ID,
        "prior_semantic_digest": D("graph 1"),
        "observed_semantic_digest": D("graph 2"),
        "successor_run_id": fx.OTHER_RUN_ID,
    })
    sc.begin("n2", "b1", "operation")
    expect("no new attempt begins after graph.diverged", sc, "run-diverged",
           lambda result: None if result["diverged"] and result["diverged"]["successor_run_id"] == fx.OTHER_RUN_ID else "diverged")
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.begin("n2", "b1", "operation")
    sc.start("a1")
    sc.start("b1")
    sc.transition("a1", "starting", "running", {
        "identity": IDENTITY,
        "observation_ref": dict(
            sc.record_ref("operation-spawned", "operation.spawned", sc.spawned["b1"]),
            node_id="n1",
            attempt_id="a1",
        ),
    })
    expect("an observation_ref naming another attempt's operation.spawned is refused", sc, "observation",
           node_is("n1", "starting"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.start("a1")
    other = copy.deepcopy(IDENTITY)
    other["effect_child"]["pid"] = 999
    sc.transition("a1", "starting", "running", {
        "identity": other,
        "observation_ref": sc.record_ref("operation-spawned", "operation.spawned", sc.spawned["a1"]),
    })
    expect("an identity differing from the observed operation.spawned identity is refused", sc, "observation",
           node_is("n1", "starting"))
    sc.events.pop()
    sc.transition("a1", "starting", "running", {
        "identity": IDENTITY,
        "observation_ref": sc.ref("operation-spawned", "a1"),
    })
    expect("an observation_ref naming no operation.spawned in the run is refused", sc, "observation",
           node_is("n1", "starting"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.start("a1")
    sc.operation("operation.released", "a1")
    sc.transition("a1", "starting", "blocked", {
        "drift_ref": sc.ref("drift", "a1"),
        "barrier_closed_ref": sc.record_ref("operation-reserve", "operation.reserve", sc.reserves["a1"]),
    })
    expect("starting -> blocked is refused once an operation.released exists for the attempt", sc, "barrier",
           node_is("n1", "starting"))
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.operation("operation.spawned", "a1")
    expect("an operation.spawned without an operation.reserve for the request is refused", sc, "no-reserve")


# ===========================================================================
# 8. Gate ineligibility, completion eligibility, schema 1, unknown schema
# ===========================================================================
def validation_code(event, payload, run=None):
    try:
        vocabulary.validate_record(event, payload, run=run)
    except vocabulary.VocabularyError as error:
        return error.code
    return "valid"


def gate_checks():
    # The complete schema-2 gate the fixture builder writes (every required
    # field, digests sealed by the fixture's own encoder), with its journal
    # envelope.
    sc = Scenario()
    sc.begin("n1", "a1", "unit", "commit")
    sc.gate("a1")
    line = copy.deepcopy(sc.events[-1])
    payload = {key: value for key, value in line.items() if key not in fx.ENVELOPE}
    code = validation_code("gate.result", payload, run=line["run"])
    emit("gate_ineligibility fixture: the complete schema-2 gate passes vocabulary.validate_record", code == "valid", code)
    # input_isolation=immutable is set only on this in-memory copy: the
    # journal refuses the strong value from any caller, so no journaled gate
    # can carry it. It is outside both digest subjects, so the digests hold.
    code = validation_code("gate.result", dict(payload, input_isolation="immutable"), run=line["run"])
    emit("gate_ineligibility fixture: validate_record refuses input_isolation=immutable, so the fixture sets it "
         "only in memory", code == "strong-assurance", code)
    base = dict(line, input_isolation="immutable")
    cases = [
        ("a gate meeting none of the six rules", {}, set()),
        ("binding changed", {"binding": "changed"}, {"binding-changed"}),
        ("binding unavailable", {"binding": "unavailable"}, {"binding-unavailable"}),
        ("input_isolation absent", {"input_isolation": DROP}, {"isolation-weak"}),
        ("input_isolation endpoint-sampled", {"input_isolation": "endpoint-sampled"}, {"isolation-weak"}),
        ("verdict red with gate_exit 1", {"verdict": "red", "gate_exit": 1}, {"verdict-not-green"}),
        ("verdict green with gate_exit 1", {"gate_exit": 1}, {"verdict-inconsistent"}),
        ("gate_exit absent", {"gate_exit": DROP}, {"verdict-inconsistent"}),
        ("gate_exit false (not an exact int)", {"gate_exit": False}, {"verdict-inconsistent"}),
        ("gate_exit 0.0 (not an exact int)", {"gate_exit": 0.0}, {"verdict-inconsistent"}),
        ("verdict absent", {"verdict": DROP}, {"verdict-not-green", "verdict-inconsistent"}),
        ("verdict red with gate_exit 0", {"verdict": "red", "gate_exit": 0}, {"verdict-not-green", "verdict-inconsistent"}),
        ("node_id absent from the envelope", {"node_id": DROP}, {"envelope-missing"}),
        ("a malformed result_digest", {"result_digest": "sha256:x"}, {"envelope-missing"}),
        ("a schema-1 gate", {"schema": 1}, {"envelope-missing"}),
    ]
    for label, change, expected in cases:
        gate = dict(base)
        fx.apply_extra(gate, change)
        got = set(reduce.gate_ineligibility(gate))
        emit(f"gate_ineligibility: {label} yields {sorted(expected)}", got == expected, sorted(got))
    sc = Scenario()
    sc.begin("n1", "a1", "unit", "commit")
    sc.raw({"schema": 1, "seq": 2, "ts": fx.TS, "event": "gate.result", "run": fx.RUN_ID, "policy": "strict",
            "purpose": "unit-final", "binding": "clean", "totals": "exit=0", "verdict": "green", "gate_exit": 0})
    sc.gate("a1")
    result = expect("the reducer folds schema-1 and schema-2 gates", sc, "accepted")
    reasons = [gate["reasons"] for gate in result["gates"]]
    emit("the reducer exposes each gate's reasons independently of eligibility",
         reasons == [["envelope-missing", "isolation-weak"], ["isolation-weak"]]
         and all(gate["completion_evidence"] is False for gate in result["gates"]), result["gates"])


def eligibility_checks():
    emit("completion_eligible: a succeeded node whose guards are all claimed is not eligible",
         reduce.completion_eligible("succeeded", {"g": "claimed"}) is False)
    emit("completion_eligible: only every guard verified would make it eligible (never recorded in 0a.1)",
         reduce.completion_eligible("succeeded", {"g": "verified", "h": "verified"}) is True
         and reduce.completion_eligible("succeeded", {"g": "verified", "h": "claimed"}) is False
         and reduce.completion_eligible("running", {"g": "verified"}) is False
         and reduce.completion_eligible("succeeded", {}) is False)
    for key in ORACLE_TERMINAL:
        node_type, stop_point = PROFILE[key]
        sc = fresh(node_type, stop_point)
        succeed(sc, terminal_evidence(sc, "a1"))
        result = reduce.reduce_run(sc.events)
        node = result["nodes"]["n1"]
        emit(f"a succeeded {key} node whose guards are all claimed is never completion-eligible",
             node["state"] == "succeeded" and node["guards"]
             and set(node["guards"].values()) == {"claimed"}
             and node["completion_eligible"] is False and result["completion_eligible"] is False,
             node)


LEGACY = [
    {"event": "run.begin", "workspace": "/ws", "workspace_key": "0" * 64, "generation": 1},
    {"event": "unit.begin", "unit": "u1"},
    {"event": "round.begin", "unit": "u1", "round": 1},
    {"event": "dispatch.start", "dispatch_id": "d1", "backend": "codex", "mode": "implement", "unit": "u1", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d1", "exit": 0, "unit": "u1", "round": 1},
    {"event": "gate.result", "policy": "strict", "purpose": "unit-final", "binding": "clean",
     "totals": "exit=0", "verdict": "green", "gate_exit": 0, "unit": "u1", "round": 1},
    {"event": "gate.result", "policy": "baseline", "purpose": "focused", "binding": "changed",
     "totals": "exit=1", "verdict": "red", "gate_exit": 1},
    {"event": "review.recorded", "unit": "u1", "round": 1, "verdict": "pass", "findings": "refs/f1"},
    {"event": "publish.recorded", "unit": "u1", "branch": "topic", "sha": "abc"},
    {"event": "checkpoint", "note": "pause"},
    {"event": "journal.repaired", "truncated_bytes": 10},
    {"event": "unit.end", "unit": "u1", "status": "done"},
    {"event": "run.end", "status": "completed"},
]


def legacy_events():
    events = []
    for index, item in enumerate(LEGACY, 1):
        line = {"schema": 1, "seq": index, "ts": fx.TS, "run": fx.RUN_ID}
        line.update(item)
        events.append(line)
    return events


def schema_checks():
    result = reduce.reduce_run(legacy_events())
    records = result["records"]
    emit("schema 1: every record reduces as legacy with every axis weakest and is never completion evidence",
         all(item["status"] == "legacy" and item["axes"] == WEAKEST and item["completion_evidence"] is False
             for item in records) and len(records) == len(LEGACY), records)
    emit("schema 1: nothing is a node, nothing is eligible, the run is not degraded",
         result["nodes"] == {} and result["completion_eligible"] is False and result["degraded"] is False
         and result["rejected"] == [], result)
    emit("schema 1: declared unit/round read as weakest-assurance attribution",
         records[3].get("attribution") == {"unit": "u1", "round": 1, "assurance": "declared"}
         and records[5].get("attribution") == {"unit": "u1", "round": 1, "assurance": "declared"}
         and "attribution" not in records[6], [records[3], records[6]])
    emit("schema 1: gates carry envelope-missing and isolation-weak among their reasons",
         [gate["reasons"] for gate in result["gates"]] == [
             ["envelope-missing", "isolation-weak"],
             ["binding-changed", "envelope-missing", "isolation-weak", "verdict-not-green"],
         ], result["gates"])
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")})
    unknown = dict(sc.events.pop())
    unknown["schema"] = 3
    sc.raw(unknown)
    as_text = dict(unknown)
    as_text["schema"] = "2"
    sc.raw(as_text)
    missing = dict(unknown)
    missing.pop("schema")
    sc.raw(missing)
    sc.raw({"schema": True, "seq": 9, "event": "checkpoint"})
    result = expect("unknown schema values (3, \"2\", absent, true) are reported and never folded", sc,
                    {1: "unknown-schema", 2: "unknown-schema", 3: "unknown-schema", 4: "unknown-schema"},
                    node_is("n1", "ready"))
    emit("an unknown schema makes the run degraded and lists the lines",
         result["degraded"] is True and result["unknown_schema"] == [1, 2, 3, 4], result["unknown_schema"])
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    line = {"schema": 2, "seq": 2, "ts": fx.TS, "event": "approval.consume", "run": fx.RUN_ID}
    line.update(sc.base("a1"))
    sc.raw(line)
    expect("an approval.consume line is refused by the reducer", sc, "approval-consume-refused")
    sc = Scenario()
    sc.begin("n1", "a1", "operation", input_isolation="immutable")
    expect("a stored strong assurance value is refused by the reducer", sc, "strong-assurance")
    sc = Scenario()
    sc.begin("n1", "a1", "operation")
    sc.events[-1]["run"] = fx.OTHER_RUN_ID
    expect("a schema-2 record whose run_id differs from the envelope run is refused", sc, "run-mismatch")


# ===========================================================================
# 9. Digest subjects and canonical encoding
# ===========================================================================
def sample_payloads():
    sc = Scenario()
    sc.begin("n1", "a1", "unit", "pr")
    sc.begin("n2", "b1", "operation")
    sc.begin("n3", "c1", "investigation")
    sc.begin("n4", "d1", "approval")
    sc.run("b1")
    sc.operation("operation.released", "b1")
    sc.operation("operation.result", "b1")
    sc.gate("a1")
    review = sc.base("a1")
    review.update({"content": COMMIT, "reviewer": "reviewer-1", "request_id": "req-1",
                   "reviewed_content_digest": D(COMMIT), "verdict": "pass", "findings_digest": D("findings")})
    sc.add("review.recorded", review)
    sc.publish("a1")
    sc.transition("b1", "running", "unknown-outcome", {"lost_child": True})
    sc.reconciliation("b1")
    samples = {}
    for event, payload in sc.payloads():
        key = event if event != "attempt.begin" else f"attempt.begin/{payload['node_type']}"
        samples.setdefault(key, payload)
    return sc, samples


def digest_checks():
    as_lists = lambda table: {key: list(value) for key, value in table.items()}  # noqa: E731
    emit("digest subjects: request subjects equal the frozen ones",
         as_lists(vocabulary.REQUEST_SUBJECTS) == fx.REQUEST_SUBJECTS, vocabulary.REQUEST_SUBJECTS)
    emit("digest subjects: attempt.begin request subjects by node type equal the frozen ones",
         as_lists(vocabulary.ATTEMPT_REQUEST_SUBJECTS) == fx.ATTEMPT_REQUEST_SUBJECTS,
         vocabulary.ATTEMPT_REQUEST_SUBJECTS)
    emit("digest subjects: result subjects equal the frozen ones",
         as_lists(vocabulary.RESULT_SUBJECTS) == fx.RESULT_SUBJECTS, vocabulary.RESULT_SUBJECTS)
    every = [fields for table in (fx.REQUEST_SUBJECTS, fx.ATTEMPT_REQUEST_SUBJECTS, fx.RESULT_SUBJECTS)
             for fields in table.values()]
    emit("digest subjects: no subject names request_digest or result_digest (no digest covers itself)",
         all("request_digest" not in fields and "result_digest" not in fields for fields in every))
    sc, samples = sample_payloads()
    result = reduce.reduce_run(sc.events)
    emit("digest samples: every sample record is accepted by the reducer", result["rejected"] == [], result["rejected"])
    for key, payload in samples.items():
        event = key.split("/")[0]
        emit(f"digest samples: {key} digests recomputed by the library equal the frozen subjects'",
             vocabulary.request_digest(event, payload) in (payload.get("request_digest"), None)
             and vocabulary.result_digest(event, payload) in (payload.get("result_digest"), None)
             and vocabulary.seal(event, payload) == fx.seal(event, payload), key)
        altered = dict(payload)
        altered["request_digest"] = D("x")
        altered["result_digest"] = D("y")
        emit(f"digest samples: {key} digests do not depend on the digest fields themselves",
             vocabulary.request_digest(event, altered) == vocabulary.request_digest(event, payload)
             and vocabulary.result_digest(event, altered) == vocabulary.result_digest(event, payload))
        for kind, compute, fields in (
            ("request", vocabulary.request_digest,
             fx.ATTEMPT_REQUEST_SUBJECTS[payload["node_type"]] if event == "attempt.begin" else fx.REQUEST_SUBJECTS.get(event)),
            ("result", vocabulary.result_digest, fx.RESULT_SUBJECTS.get(event)),
        ):
            if fields is None:
                continue
            unchanged = []
            for field in fields:
                changed = dict(payload)
                changed[field] = f"changed-{field}"
                if compute(event, changed) == compute(event, payload):
                    unchanged.append(field)
            emit(f"digest samples: changing any {kind} subject field of {key} changes its digest", not unchanged, unchanged)
    transition = samples["node.transition"]
    omitted = {key: value for key, value in transition.items() if key not in ("stop_point_result", "markers")}
    explicit = dict(omitted, stop_point_result=None, markers=None)
    emit("digest: node.transition with stop_point_result and markers omitted equals explicitly null",
         vocabulary.result_digest("node.transition", omitted) == vocabulary.result_digest("node.transition", explicit)
         == fx.seal("node.transition", omitted)["result_digest"])
    emit("digest: node.transition with a stop_point_result value differs from null",
         vocabulary.result_digest("node.transition", dict(omitted, stop_point_result="informational"))
         != vocabulary.result_digest("node.transition", explicit))
    emit("digest: node.transition with markers differs from null",
         vocabulary.result_digest("node.transition", dict(omitted, markers=["stale"]))
         != vocabulary.result_digest("node.transition", explicit))
    publish = dict(samples["publish.recorded"], stop_point="commit")
    publish.pop("pr")
    publish.pop("head_sha")
    explicit = dict(publish, pr=None, head_sha=None)
    emit("digest: publish.recorded below pr with pr and head_sha omitted equals explicitly null",
         vocabulary.result_digest("publish.recorded", publish) == vocabulary.result_digest("publish.recorded", explicit))
    emit("digest: publish.recorded with pr and head_sha values differs from null",
         vocabulary.result_digest("publish.recorded", dict(publish, pr=fx.PR_URL, head_sha=COMMIT_SHA))
         != vocabulary.result_digest("publish.recorded", explicit))
    gate = dict(samples["gate.result"])
    tampered = dict(gate, suite_invocation=dict(gate["suite_invocation"], argv=["/usr/bin/env", "false"]))
    try:
        vocabulary.validate_record("gate.result", tampered)
        emit("digest: a gate whose suite_invocation differs from its request subject is refused", False, "accepted")
    except vocabulary.VocabularyError as error:
        emit("digest: a gate whose suite_invocation differs from its request subject is refused",
             error.code == "request-digest-mismatch", error.code)
    tampered = dict(gate, output_content=INPUT)
    try:
        vocabulary.validate_record("gate.result", tampered)
        emit("digest: a gate whose output_content differs from its result subject is refused", False, "accepted")
    except vocabulary.VocabularyError as error:
        emit("digest: a gate whose output_content differs from its result subject is refused",
             error.code == "result-digest-mismatch", error.code)
    emit("digest: a reference digest is the canonical digest of the record's event and payload",
         vocabulary.record_digest("gate.result", gate) == fx.record_digest("gate.result", gate))


def nested(depth, kind, inner=None):
    """depth nested arrays or objects (depth 1 is [] or {}), innermost
    holding inner when given."""
    value = ([] if inner is None else [inner]) if kind == "array" else ({} if inner is None else {"k": inner})
    for _ in range(depth - 1):
        value = [value] if kind == "array" else {"k": value}
    return value


def canonical_checks():
    vectors = [
        ("depth 64 (64 nested arrays) is accepted", nested(64, "array"), b"[" * 64 + b"]" * 64),
        ("depth 64 (64 nested objects) is accepted", nested(64, "object"), b'{"k":' * 63 + b"{}" + b"}" * 63),
        ("depth 64 around a scalar is accepted", nested(64, "array", 1), b"[" * 64 + b"1" + b"]" * 64),
        ("key order", {"b": 1, "a": 2, "c": {"z": 0, "y": 1}}, b'{"a":2,"b":1,"c":{"y":1,"z":0}}'),
        ("nested objects and arrays keep array order", {"z": {"y": [3, 1, {"b": None, "a": True}]}},
         b'{"z":{"y":[3,1,{"a":true,"b":null}]}}'),
        ("unicode is raw UTF-8", {"k": "é☃\U0001F600"}, '{"k":"é☃\U0001F600"}'.encode("utf-8")),
        ("keys sort by code point", {"é": 1, "z": 2, "Z": 3}, '{"Z":3,"z":2,"é":1}'.encode("utf-8")),
        ("control characters are escaped", {"k": "a\u0001b\tc"}, b'{"k":"a\\u0001b\\tc"}'),
        ("no insignificant whitespace", [1, [2, [3]], {}], b"[1,[2,[3]],{}]"),
        ("the largest integer", 2**53 - 1, b"9007199254740991"),
        ("the smallest integer", -(2**53 - 1), b"-9007199254740991"),
        ("true, false, null", [True, False, None], b"[true,false,null]"),
    ]
    for label, value, expected in vectors:
        try:
            got = canonical.canonical(value)
        except canonical.CanonicalError as error:
            got = f"refused: {error}"
        emit(f"canonical: {label}", got == expected, got)
    refused = [
        ("an integer above the bound", 2**53),
        ("an integer below the bound", -(2**53)),
        ("a float", 1.0),
        ("a fractional float", 0.5),
        ("NaN", float("nan")),
        ("infinity", float("inf")),
        ("negative infinity", float("-inf")),
        ("an integer key", {1: "a"}),
        ("a null key", {None: 1}),
        ("a boolean key", {True: 1}),
        ("a tuple", (1, 2)),
        ("a lone surrogate", "\ud800"),
        ("a nested float", {"a": [1, {"b": 2.5}]}),
        ("depth 65 (65 nested arrays)", nested(65, "array")),
        ("depth 65 (65 nested objects)", nested(65, "object")),
        ("depth 65 around a scalar", nested(65, "array", 1)),
        ("2^53 inside nested arrays", nested(3, "array", 2**53)),
    ]
    for label, value in refused:
        try:
            canonical.canonical(value)
            emit(f"canonical: {label} is refused", False, "encoded")
        except canonical.CanonicalError:
            emit(f"canonical: {label} is refused", True)
    for label, text in (
        ("a float literal", '{"a": 1.0}'),
        ("an exponent literal", '{"a": 1e3}'),
        ("NaN", '{"a": NaN}'),
        ("Infinity", '{"a": Infinity}'),
        ("-Infinity", '{"a": -Infinity}'),
        ("a duplicate key", '{"a": 1, "a": 2}'),
        ("an out-of-range integer", '{"a": 9007199254740992}'),
        ("an integer below the bound", '{"a": -9007199254740992}'),
        ("depth 65", "[" * 65 + "]" * 65),
    ):
        try:
            canonical.loads(text)
            emit(f"canonical.loads: {label} is refused", False, "parsed")
        except canonical.CanonicalError:
            emit(f"canonical.loads: {label} is refused", True)
    for label, text, expected in (
        ("2^53 - 1", '{"a": 9007199254740991}', {"a": 2**53 - 1}),
        ("-(2^53 - 1)", '{"a": -9007199254740991}', {"a": -(2**53 - 1)}),
        ("depth 64", "[" * 64 + "]" * 64, nested(64, "array")),
    ):
        try:
            got = canonical.loads(text)
        except canonical.CanonicalError as error:
            got = f"refused: {error}"
        emit(f"canonical.loads: {label} is accepted", got == expected, str(got)[:80])
    emit("canonical: digest is sha256: over the canonical bytes",
         canonical.digest({}) == "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
         and canonical.digest({"b": 1, "a": [1]}) == "sha256:" + hashlib.sha256(b'{"a":[1],"b":1}').hexdigest())
    emit("canonical: the fixture encoder and the library agree",
         all(fx.D(value) == canonical.digest(value) for _label, value, _expected in vectors))
    emit("canonical: key order does not change a digest",
         canonical.digest({"a": 1, "b": 2}) == canonical.digest(dict([("b", 2), ("a", 1)])))



def review_regressions():
    # PR65 #1: rejected and legacy gates never acquire stronger isolation.
    for schema in (1, 2):
        sc = fresh("unit", "commit")
        sc.gate("a1", input_isolation="immutable")
        sc.events[-1]["schema"] = schema
        result = reduce.reduce_run(sc.events)
        emit(f"review #1 schema {schema}: isolation stays weak",
             "isolation-weak" in result["gates"][-1]["reasons"])
    sc = fresh("unit", "merge")
    evidence = terminal_evidence(sc, "a1")
    evidence["provider_receipt_ref"]["outcome"] = "refused"
    succeed(sc, evidence)
    expect("review #2 refused receipt cannot prove merge success", sc, "evidence-claim")
    # A failed reconciliation agrees with a refused provider receipt.
    sc = lost()
    sc.reconciliation("a1", outcome="failed", receipt_ref=sc.ref("provider-receipt", "a1", outcome="refused"))
    resolve(sc, "failed")
    expect("review #2 failed reconciliation can cite a refused receipt", sc, "accepted")

    for kind, event, field, node_type, stop in (
        ("operation-result", "operation.result", "operation_result_ref", "operation", None),
        ("gate", "gate.result", "gate_ref", "unit", "commit"),
        ("review", "review.recorded", "review_ref", "unit", "commit"),
        ("publish", "publish.recorded", "publish_ref", "unit", "pr"),
    ):
        for mismatch in ("verdict", "content", "attempt", "unknown", "agree"):
            sc = fresh(node_type, stop)
            if kind == "operation-result":
                rec = sc.operation(event, "a1", outcome="failed" if mismatch == "verdict" else "succeeded")
            elif kind == "gate":
                rec = sc.gate("a1", verdict="red" if mismatch == "verdict" else "green",
                              gate_exit=1 if mismatch == "verdict" else 0)
            elif kind == "review":
                rec = sc.base("a1")
                rec.update(content=COMMIT, reviewer="reviewer-1",
                           request_id="r", reviewed_content_digest=D(COMMIT),
                           verdict="iterate" if mismatch == "verdict" else "pass", findings_digest=D([]))
                rec = sc.add(event, rec)
            else:
                rec = sc.publish("a1", outcome="failed" if mismatch == "verdict" else "published")
            evidence = terminal_evidence(sc, "a1")
            ref = evidence[field]
            # Match all claims before planting a single disagreement.
            keys = {"operation-result": {"outcome": "outcome", "content": "output_content"},
                    "gate": {"verdict": "verdict", "input_content": "input_content", "content": "input_content"},
                    "review": {"verdict": "verdict", "reviewer": "reviewer"},
                    "publish": {"outcome": "outcome", "pr": "pr", "head_sha": "head_sha", "content": "content"}}[kind]
            if mismatch != "verdict":
                for key, source in keys.items(): ref[key] = rec[source]
            if mismatch == "content":
                if kind == "review": ref["reviewer"] = "another-reviewer"
                elif kind == "gate": ref["content"] = ref["input_content"] = INPUT
                else: ref["content"] = INPUT
            if mismatch == "attempt":
                sc.begin("n2", "a2", node_type, stop)
                other = dict(rec, **sc.base("a2"))
                if kind == "operation-result": sc.operation("operation.reserve", "a2")
                rec = sc.add(event, other)
            ref["digest"] = D("absent-record") if mismatch == "unknown" else fx.record_digest(event, rec)
            succeed(sc, evidence)
            expect(f"review #3 {kind} {mismatch}", sc,
                   "accepted" if mismatch in ("unknown", "agree") else "reference-contradicted")

    import ast
    from pathlib import Path
    journal = (Path(sys.argv[1]).parent / "scripts" / "loop-journal").read_text()
    match = __import__("re").search(r'"backend": (\([^\n]+\))', journal)
    emit("review #4 schema backend lists agree", match is not None and set(ast.literal_eval(match[1])) == set(vocabulary.BACKENDS))
    sc = Scenario()
    sc.begin("n1", "a1", "unit", "commit", dispatch=dict(fx.DISPATCH, backend="claude"))
    expect("review #4 claude schema-2 attempt accepted", sc, "accepted")

    for kind, stop in (("operation", None), ("unit", "pr")):
        for to in ("succeeded", "failed"):
            for unknown in (False, True):
                sc = lost(kind, stop)
                # An earlier reconciliation need not be used when the real record arrives.
                sc.reconciliation("a1", outcome="failed" if to == "succeeded" else "succeeded",
                                  substitutes="operation-result" if kind == "operation" else "publish")
                if kind == "operation":
                    event = "operation.result"
                    rec = sc.operation(event, "a1", outcome=to)
                    refkind, slot = "operation-result", "operation_result_ref"
                else:
                    event = "publish.recorded"
                    rec = sc.publish("a1", outcome="published" if to == "succeeded" else "failed")
                    refkind, slot = "publish", "publish_ref"
                container = terminal_evidence(sc, "a1") if to == "succeeded" else failure_evidence(sc, "a1", phase="operation" if kind == "operation" else "publish")
                ref = container[slot if to == "succeeded" else "failing_ref"]
                ref["digest"] = D("absent") if unknown else fx.record_digest(event, rec)
                for key in ("outcome", "pr", "head_sha"):
                    if key in ref and key in rec: ref[key] = rec[key]
                ref["content"] = rec["output_content"] if kind == "operation" else rec["content"]
                extra = {"stop_point_result": "pr-open"} if kind == "unit" and to == "succeeded" else {}
                sc.transition("a1", "unknown-outcome", to,
                              {"terminal_evidence" if to == "succeeded" else "failure_evidence": container}, **extra)
                expect(f"review #5 late {kind} {to} unknown={unknown}", sc,
                       "reconciliation-required" if unknown else "accepted")
    sc = lost("unit", "commit")
    sc.transition("a1", "unknown-outcome", "succeeded", {"terminal_evidence": terminal_evidence(sc, "a1")}, stop_point_result="gated-commit")
    expect("review #5 commit remains park-only", sc, "substitution-kind")

    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish")
    resolve(sc, "succeeded")
    sc.publish("a1")
    expect("review #7 late publish after substitution refused", sc, "substituted")
    sc = lost("unit", "pr")
    sc.reconciliation("a1", substitutes="publish")
    resolve(sc, "succeeded")
    original = copy.deepcopy(sc.events)
    full = reduce.reduce_run(sc.events)
    emit("review #7 reducer does not mutate input", sc.events == original)
    incremental = reduce.Reducer()
    for index, event in enumerate(sc.events):
        incremental.apply(event)
        prefix = reduce.reduce_run(sc.events[:index + 1])
        emit(f"review #7 prefix {index} matches streaming fold", prefix == incremental.result()
             and prefix["records"] == full["records"][:index + 1])
    sc = Scenario(); sc.begin("n1", "a1", "operation")
    sc.transition("a1", "ready", "blocked", {"request_ref": sc.ref("request", "a1")}, markers=["stale"])
    sc.transition("a1", "blocked", "ready", {"answer_ref": sc.ref("answer", "a1", answer="answered"), "revalidation_digest": D("valid")})
    expect("review #7 later transition replaces markers", sc, "accepted", node_is("n1", "ready", markers=[]))
    sc.events[-1]["attribution_failure"] = "missing"
    expect("review #7 schema-2 attribution failure refused", sc, "envelope")

    for field in ("gate_exit", "suite_exit", "round"):
        sc = fresh("unit", "commit"); sc.gate("a1", **{field: field == "round"})
        expect(f"review #8 bool for int {field}", sc, "mistyped")
    for field in ("pid", "pgid"):
        sc = fresh("operation"); sc.operation("operation.result", "a1", identity=dict(IDENTITY, **{field: True}))
        expect(f"review #8 bool for identity {field}", sc, "mistyped")
    sc = fresh("unit", "commit")
    evidence = failure_evidence(sc, "a1", phase="gate")
    # dispatch-end is the integer claim in the closed reference vocabulary.
    ref = sc.ref("dispatch-end", "a1", exit=True)
    try:
        vocabulary.check_reference(ref, R(["dispatch-end"]), "ref", "n1", "a1")
        code = None
    except vocabulary.VocabularyError as error: code = error.code
    emit("review #8 bool for dispatch-end exit", code == "evidence-mistyped", code)
    sc = fresh("operation"); sc.transition("a1", "running", "unknown-outcome", {"lost_child": 1})
    expect("review #8 integer is not true constant", sc, "evidence-mistyped")
    sc = fresh("operation"); evidence = terminal_evidence(sc, "a1"); evidence["operation_result_ref"]["reviewer"] = "foreign"
    succeed(sc, evidence); expect("review #8 foreign reference claim", sc, "evidence-mistyped")
    sc = Scenario(); sc.begin("n1!", "a1", "operation")
    expect("review #8 identifier trailing garbage", sc, "mistyped")
    sc = fresh("unit", "commit"); evidence = terminal_evidence(sc, "a1"); evidence["gate_ref"]["input_content"] = INPUT
    succeed(sc, evidence); expect("review #8 gate content agreement", sc, "evidence-inconsistent")
    try:
        canonical.check({"\ud800": "value"}); rejected = False
    except canonical.CanonicalError: rejected = True
    emit("review #8 surrogate dictionary key rejected before encoding", rejected)
    sc = fresh("unit", "commit"); sc.gate("a1", reason="raw\nnewline")
    expect("review #8 raw newline refused", sc, "newline")

    sc = Scenario(); sc.begin("n1", "a1", "operation")
    other = Scenario(); other.run_id = fx.OTHER_RUN_ID; other.begin("n2", "a2", "operation")
    sc.events.extend(other.events)
    expect("review #9 fold rejects another run", sc, "run-mismatch")
    sc.events[-1]["schema"] = 1
    expect("review #9 legacy line cannot switch runs", sc, "run-mismatch")
    explicit = reduce.reduce_run([sc.events[0]], run=fx.OTHER_RUN_ID)
    emit("review #9 caller can bind the expected run", explicit["rejected"][0]["code"] == "run-mismatch")

def round3_record(sc, kind, failed=False, **extra):
    if kind == "operation-result":
        return sc.operation("operation.result", "a1", outcome="failed" if failed else "succeeded", **extra)
    if kind == "gate":
        return sc.gate("a1", verdict="red" if failed else "green", gate_exit=1 if failed else 0, **extra)
    if kind == "publish":
        return sc.publish("a1", outcome="failed" if failed else "published", **extra)
    payload = sc.base("a1")
    payload.update(content=COMMIT, reviewer="reviewer-1", request_id="r",
                   reviewed_content_digest=D(COMMIT), verdict="iterate" if failed else "pass",
                   findings_digest=D([]))
    payload.update(extra)
    return sc.add("review.recorded", payload)


def round3_reference_checks():
    # Frozen agreement cells, independent of the implementation table.
    cells = (
        ("operation-result", "operation.result", "operation", None, "output_content", ("outcome",)),
        ("gate", "gate.result", "unit", "commit", "input_content", ("verdict", "input_content")),
        ("review", "review.recorded", "unit", "commit", "content", ("verdict", "reviewer")),
        ("publish", "publish.recorded", "unit", "pr", "content", ("outcome", "pr", "head_sha")),
    )
    for kind, event, node_type, stop, content_field, claims in cells:
        sc = fresh(node_type, stop)
        rec = round3_record(sc, kind)
        expect(f"round3 agreement {kind}: accepted record control", sc, "accepted")
        ref = sc.record_ref(kind, event, rec, rec[content_field], **{key: rec[key] for key in claims})
        # Some vocabulary rules couple fields (gate content/input_content),
        # and accepted attempt bindings couple node and attempt identities.
        # Probe the comparison boundary with just one lookup/claim changed,
        # so another rule cannot mask a missing comparison. Lifecycle cases
        # below exercise real accepted digests through the whole reducer.
        for field in ("content",) + claims + ("event", "node_id", "attempt_id"):
            reducer = reduce.Reducer()
            for line in sc.events:
                reducer.apply(line)
            changed = copy.deepcopy(ref)
            if field == "event":
                reducer.by_digest.pop((event, ref["digest"]))
                reducer.by_digest[("another.event", ref["digest"])] = rec
            elif field in ("node_id", "attempt_id"):
                reducer.by_digest[(event, ref["digest"])] = dict(rec, **{field: "another-id"})
            else:
                changed[field] = {
                    "content": WORKTREE, "input_content": WORKTREE, "outcome": "failed",
                    "verdict": "red" if kind == "gate" else "iterate", "reviewer": "another-reviewer",
                    "pr": "https://example.invalid/pr/2", "head_sha": "b" * 40,
                }[field]
            try:
                reducer._check_journal_references(reducer.attempts["a1"], changed)
                code = None
            except reduce.Rejected as error:
                code = error.code
            emit(f"round3 agreement {kind}.{field}: single-field contradiction",
                 code == "reference-contradicted", code)

        phase = "operation" if kind == "operation-result" else kind
        for mismatch in (False, True):
            sc = fresh(node_type, stop)
            rec = round3_record(sc, kind, failed=True)
            evidence = failure_evidence(sc, "a1", phase=phase)
            ref = evidence["failing_ref"]
            ref["digest"] = fx.record_digest(event, rec)
            ref["content"] = WORKTREE if mismatch else rec[content_field]
            sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
            expect(f"round3 failing_ref {kind}: {'content contradiction' if mismatch else 'minimal real digest accepted'}",
                   sc, "reference-contradicted" if mismatch else "accepted",
                   node_is("n1", "running" if mismatch else "failed"))

    for kind, claim, value in (("gate", "input_content", COMMIT), ("review", "reviewer", "another-reviewer")):
        sc = fresh("unit", "commit")
        # For gate, both claimed content fields agree with each other, but
        # disagree with the record's input. For review, only reviewer differs.
        rec = round3_record(sc, kind, failed=True, **({"input_content": INPUT} if kind == "gate" else {}))
        evidence = failure_evidence(sc, "a1", phase=kind)
        evidence["failing_ref"].update(digest=fx.record_digest(f"{kind}.{'result' if kind == 'gate' else 'recorded'}", rec),
                                      **{claim: value})
        sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
        expect(f"round3 failing_ref {kind}: optional {claim} contradiction", sc, "reference-contradicted")

    for claim, value in (("pr", fx.PR_URL), ("head_sha", COMMIT_SHA)):
        sc = fresh("unit", "pr")
        rec = sc.publish("a1", outcome="failed")
        evidence = failure_evidence(sc, "a1", phase="publish")
        evidence["failing_ref"].update(digest=fx.record_digest("publish.recorded", rec), **{claim: value})
        sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
        expect(f"round3 failing_ref publish: claimed {claim} absent from record", sc, "reference-contradicted")

    # Outcome alone disagrees: the published record's PR/head claims match.
    sc = fresh("unit", "pr")
    rec = sc.publish("a1")
    evidence = failure_evidence(sc, "a1", phase="publish")
    evidence["failing_ref"].update(digest=fx.record_digest("publish.recorded", rec), pr=rec["pr"], head_sha=rec["head_sha"])
    sc.transition("a1", "running", "failed", {"failure_evidence": evidence})
    expect("round3 failing_ref publish: outcome alone contradicts published record", sc, "reference-contradicted")

    for field, extra in (
        ("pr", {"pr": "https://example.invalid/pr/2"}),
        ("head_sha", {"sha": "b" * 40, "head_sha": "b" * 40}),
        ("branch", {"branch": "another-branch"}),
        ("stop_point", {"stop_point": "merge"}),
    ):
        sc = fresh("unit", "pr")
        rec = sc.publish("a1", **extra)
        evidence = terminal_evidence(sc, "a1")
        evidence["publish_ref"]["digest"] = fx.record_digest("publish.recorded", rec)
        succeed(sc, evidence)
        expect(f"round3 direct publish: {field} alone contradicts terminal evidence or pin",
               sc, "reference-contradicted", node_is("n1", "running"))

    sc = fresh("unit", "commit")
    rec = round3_record(sc, "review", content=WORKTREE, reviewed_content_digest=D(WORKTREE))
    evidence = terminal_evidence(sc, "a1")
    evidence["review_ref"]["digest"] = fx.record_digest("review.recorded", rec)
    succeed(sc, evidence)
    expect("round3 direct review: working tree is not the claimed commit", sc, "reference-contradicted")

    for mismatch in (False, True):
        sc = fresh("unit", "merge")
        rec = sc.gate("a1", content=INTEGRATION, input_content=COMMIT if mismatch else INTEGRATION)
        evidence = terminal_evidence(sc, "a1")
        evidence["pre_merge_gate_ref"]["digest"] = fx.record_digest("gate.result", rec)
        succeed(sc, evidence)
        expect(f"round3 pre_merge_gate_ref: {'content contradiction' if mismatch else 'real digest accepted'}",
               sc, "reference-contradicted" if mismatch else "accepted")


def round3_reconciliation_checks():
    for direction, receipt_outcome, accepted in (
        ("succeeded", "merged", True), ("failed", "refused", True),
        ("succeeded", "refused", False), ("failed", "merged", False),
    ):
        sc = lost()
        sc.reconciliation("a1", outcome=direction,
                          receipt_ref=sc.ref("provider-receipt", "a1", outcome=receipt_outcome))
        if accepted:
            resolve(sc, direction)
        expect(f"round3 receipt direction: {direction}/{receipt_outcome}", sc,
               "accepted" if accepted else "evidence-inconsistent",
               node_is("n1", direction if accepted else "unknown-outcome"))

    sc = lost("unit", "commit")
    rec = sc.gate("a1", verdict="red", gate_exit=1)
    evidence = failure_evidence(sc, "a1", phase="gate")
    evidence["failing_ref"]["digest"] = fx.record_digest("gate.result", rec)
    sc.transition("a1", "unknown-outcome", "failed", {"failure_evidence": evidence})
    expect("round3 failed park-only: real gate without reconciliation", sc, "substitution-kind",
           node_is("n1", "unknown-outcome"))

    for direction in ("succeeded", "failed"):
        sc = lost("unit", "pr")
        sc.publish("a1", outcome="published" if direction == "succeeded" else "failed")
        sc.reconciliation("a1", outcome=direction, substitutes="publish")
        resolve(sc, direction)
        expect(f"round3 publish {direction}: reconciliation present, slot absent, real record exists",
               sc, "substitution-not-absent", node_is("n1", "unknown-outcome"))


for label, function in (
    ("round3 references", round3_reference_checks),
    ("round3 reconciliation", round3_reconciliation_checks),
    ("review regressions", review_regressions),
    ("oracle", oracle_checks),
    ("rows", row_checks),
    ("pairs", pair_checks),
    ("selection", selection_checks),
    ("terminal evidence", terminal_checks),
    ("stop point", stop_point_checks),
    ("relations", relation_checks),
    ("failure", failure_checks),
    ("reconciliation", reconciliation_checks),
    ("markers", marker_checks),
    ("attempts", attempt_checks),
    ("gates", gate_checks),
    ("eligibility", eligibility_checks),
    ("schemas", schema_checks),
    ("digests", digest_checks),
    ("canonical", canonical_checks),
):
    section(label, function)
PY
PURE_STATUS=$?
tally "$TMP_ROOT/pure.tsv" "$TMP_ROOT/pure.stderr" "$PURE_STATUS" "pure checks"

# ---------------------------------------------------------------------------
# Through the real CLI: a schema-1 fixture and schema-2 lifecycles in one
# segment, written by loop-journal append --schema 2, then reduced.
# ---------------------------------------------------------------------------
WS_CLI="$TMP_ROOT/ws-cli"
mkdir -p "$WS_CLI"
run_cmd cli-begin "$RUN" begin --workspace "$WS_CLI"
expect_status 0 "cli: begin succeeds"
RUN_CLI="$(field_from "$CASE_STDOUT" run)"
SEG_CLI="$(store_dir "$WS_CLI")/runs/${RUN_CLI}.jsonl"

# The schema-1 fixture of journal-selftest's round trip, unchanged.
LEGACY_STATUSES=""
run_cmd cli-unit "$RUN" unit-begin --unit u1 --workspace "$WS_CLI"
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-round "$RUN" round-begin --unit u1 --round 1 --workspace "$WS_CLI"
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-start env LOOP_UNIT=u1 LOOP_ROUND=1 "$JOURNAL" append --workspace "$WS_CLI" \
  --event dispatch.start --field dispatch_id=d-cli --field backend=codex --field mode=implement
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-end env LOOP_UNIT=u1 LOOP_ROUND=1 "$JOURNAL" append --workspace "$WS_CLI" \
  --event dispatch.end --field dispatch_id=d-cli --field exit=0
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-gate "$JOURNAL" append --workspace "$WS_CLI" --event gate.result --field policy=strict \
  --field purpose=unit-final --field binding=clean --field totals=exit=0 --field verdict=green --field gate_exit=0
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-review "$RUN" review --unit u1 --round 1 --verdict pass --findings refs/f1 --workspace "$WS_CLI"
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-publish "$RUN" publish --unit u1 --branch topic --sha abc --workspace "$WS_CLI"
LEGACY_STATUSES+="$CASE_STATUS"
run_cmd cli-checkpoint "$RUN" checkpoint --note pause --workspace "$WS_CLI"
LEGACY_STATUSES+="$CASE_STATUS"
if [[ "$LEGACY_STATUSES" == 00000000 ]]; then
  pass "cli: the schema-1 fixture appends as before"
else
  fail "cli: the schema-1 fixture appends as before (statuses $LEGACY_STATUSES)"
fi

mkdir -p "$TMP_ROOT/cli" "$TMP_ROOT/cli-refused"
python3 - "$TMP_ROOT" "$RUN_CLI" <<'PY'
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import fixture as fx  # noqa: E402
from fixture import COMMIT, COMMIT_SHA, D, Scenario  # noqa: E402

root, run_id = sys.argv[1], sys.argv[2]
sc = Scenario(run_id)


def unit_evidence(attempt):
    return {
        "review_ref": sc.ref("review", attempt, COMMIT, verdict="pass", reviewer="reviewer-1"),
        "gate_ref": sc.ref("gate", attempt, COMMIT, verdict="green", input_content=COMMIT),
        "branch": "topic",
        "sha": COMMIT_SHA,
    }


# A publish.recorded with outcome failed, used as a publish-phase failure.
sc.begin("pub-fail", "pf1", "unit", "pr")
sc.run("pf1")
published = sc.publish("pf1", "failed")
sc.transition("pf1", "running", "failed", {"failure_evidence": {
    "phase": "publish",
    "reason": "push rejected",
    "failing_ref": sc.record_ref("publish", "publish.recorded", published, published["content"], outcome="failed"),
}})
# A successful publish substitute and a failed one.
sc.begin("pub-ok", "ps1", "unit", "pr")
sc.lose("ps1")
sc.reconciliation("ps1", outcome="succeeded", substitutes="publish", method="reconciliation")
sc.transition("ps1", "unknown-outcome", "succeeded",
              {"reconciliation_ref": sc.recon_ref("ps1"), "terminal_evidence": unit_evidence("ps1")},
              stop_point_result="pr-open")
sc.begin("pub-no", "pn1", "unit", "pr")
sc.lose("pn1")
sc.reconciliation("pn1", outcome="failed", substitutes="publish", method="reconciliation")
sc.transition("pn1", "unknown-outcome", "failed", {
    "reconciliation_ref": sc.recon_ref("pn1"),
    "failure_evidence": {"phase": "publish", "reason": "the push was rejected"},
})
# An operation that crashed after its effect, resolved by receipt lookup.
sc.begin("op-crash", "oc1", "operation")
sc.lose("oc1")
sc.reconciliation("oc1", outcome="succeeded")
sc.transition("oc1", "unknown-outcome", "succeeded",
              {"reconciliation_ref": sc.recon_ref("oc1"), "terminal_evidence": {}})


def integrate_failure(attempt):
    return {"failure_evidence": {
        "phase": "integrate",
        "reason": "the pre-merge gate is red",
        "failing_ref": sc.ref("gate", attempt, fx.INTEGRATION, verdict="red", input_content=fx.INTEGRATION),
        "integration_content": fx.INTEGRATION,
    }}


# A merge unit that fails on its pre-merge gate over the integration content.
sc.begin("merge-fail", "mf1", "unit", "merge")
sc.run("mf1")
sc.transition("mf1", "running", "failed", integrate_failure("mf1"))

payloads = sc.payloads()
for index, (event, payload) in enumerate(payloads, 1):
    with open(os.path.join(root, "cli", f"{index:03d}.{event}.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
with open(os.path.join(root, "cli-count"), "w", encoding="utf-8") as handle:
    handle.write(f"{len(payloads)}\n")

refused = {}
missing_code = sc.base("pf1")
missing_code.update(fx.publish_result("pr", "failed"))
missing_code.pop("error_code")
refused["missing-field.publish.recorded"] = fx.seal("publish.recorded", missing_code)
tampered = dict(sc.recons["oc1"])
tampered["result_digest"] = D("not the result subject")
refused["result-digest-mismatch.reconciliation.result"] = tampered
# The integrate phase on a unit pinned to pr (only a merge integrates).
wrong_pin = sc.base("pf1")
wrong_pin.update({"content": fx.INPUT, "from": "running", "to": "failed", "node_type": "unit",
                  "stop_point": "pr", "evidence": integrate_failure("pf1")})
refused["failure-phase.node.transition"] = fx.seal("node.transition", wrong_pin)
for name, payload in refused.items():
    with open(os.path.join(root, "cli-refused", f"{name}.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
PY
CLI_FAILED=""
CLI_COUNT=0
for file in "$TMP_ROOT"/cli/*.json; do
  name="$(basename "$file" .json)"
  event="${name#*.}"
  CLI_COUNT=$((CLI_COUNT + 1))
  run_cmd "cli-$name" "$JOURNAL" append --schema 2 --workspace "$WS_CLI" --event "$event" --json "$(cat "$file")"
  if [[ $CASE_STATUS -ne 0 && -z "$CLI_FAILED" ]]; then
    CLI_FAILED="$name (exit $CASE_STATUS)"
    FIRST_STDERR="$CASE_STDERR"
  fi
done
CASE_STDOUT=""
CASE_STDERR="${FIRST_STDERR:-}"
CLI_EXPECTED="$(cat "$TMP_ROOT/cli-count" 2>/dev/null || true)"
if [[ -z "$CLI_FAILED" && $CLI_COUNT -gt 0 && "$CLI_COUNT" == "$CLI_EXPECTED" ]]; then
  pass "cli: all $CLI_COUNT schema-2 lifecycle records are accepted by loop-journal append --schema 2"
else
  fail "cli: all schema-2 lifecycle records are accepted by append --schema 2 (first refusal: ${CLI_FAILED:-none}, count $CLI_COUNT of ${CLI_EXPECTED:-unknown})"
fi

SUM_CLI_BEFORE="$(file_sum "$SEG_CLI")"
for file in "$TMP_ROOT"/cli-refused/*.json; do
  name="$(basename "$file" .json)"
  code="${name%%.*}"
  event="${name#*.}"
  run_cmd "cli-refused-$code" "$JOURNAL" append --schema 2 --workspace "$WS_CLI" --event "$event" --json "$(cat "$file")"
  expect_status 2 "cli: $event with $code is refused (exit 2)"
  expect_output stderr "[$code]" "cli: the $event refusal names $code"
done
if [[ "$(file_sum "$SEG_CLI")" == "$SUM_CLI_BEFORE" ]]; then
  pass "cli: no refused schema-2 record reached the segment"
else
  fail "cli: no refused schema-2 record reached the segment"
fi

python3 - "$LIB" "$SEG_CLI" > "$TMP_ROOT/cli.tsv" 2> "$TMP_ROOT/cli.stderr" <<'PY'
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from loopauth import reduce  # noqa: E402

WEAKEST = {
    "input_isolation": "endpoint-sampled",
    "capability_assurance": "declared",
    "atomicity": "unproven",
    "conformance": "unproven",
}


def emit(description, ok, detail=""):
    if ok:
        print(f"ok\t{description}")
    else:
        print(f"not ok\t{description}\t{' '.join(str(detail).split())}")


events = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
result = reduce.reduce_run(events)
nodes = result["nodes"]
schemas = sorted({event.get("schema") for event in events})
emit("cli segment: a mixed schema-1/schema-2 segment reduces with nothing rejected",
     schemas == [1, 2] and result["rejected"] == [] and result["degraded"] is False, result["rejected"])
failed = nodes.get("pub-fail", {})
emit("cli segment: a CLI-written publish.recorded (outcome failed, error_code) is used as a publish-phase failure",
     failed.get("state") == "failed"
     and failed.get("guards", {}).get("running->failed:failure_evidence.failing_ref") == "claimed", failed)
ok = nodes.get("pub-ok", {})
emit("cli segment: a successful publish substitute through the real schema reaches succeeded (pr-open)",
     ok.get("state") == "succeeded" and ok.get("stop_point_result") == "pr-open"
     and ok.get("transitions", [{}])[-1].get("substituted") == "terminal_evidence.publish_ref", ok)
no = nodes.get("pub-no", {})
emit("cli segment: a failed publish substitute through the real schema reaches failed",
     no.get("state") == "failed" and no.get("transitions", [{}])[-1].get("substituted") == "failure_evidence.failing_ref", no)
crash = nodes.get("op-crash", {})
emit("cli segment: an operation crash resolved by receipt lookup reaches succeeded",
     crash.get("state") == "succeeded"
     and crash.get("transitions", [{}])[-1].get("substituted") == "terminal_evidence.operation_result_ref", crash)
merge = nodes.get("merge-fail", {})
emit("cli segment: a merge unit failing on its pre-merge red gate over the integration content reaches failed",
     merge.get("state") == "failed"
     and merge.get("guards", {}).get("running->failed:failure_evidence.integration_content") == "claimed", merge)
emit("cli segment: nothing is completion-eligible and every guard is only claimed",
     result["completion_eligible"] is False
     and all(node["completion_eligible"] is False and set(node["guards"].values()) <= {"claimed"} for node in nodes.values()))
legacy = [record for record in result["records"] if record["schema"] == 1]
emit("cli segment: the schema-1 fixture reduces with every axis weakest and is never completion evidence",
     len(legacy) >= 9 and all(record["status"] == "legacy" and record["axes"] == WEAKEST
                             and record["completion_evidence"] is False for record in legacy), legacy)
declared = [record for record in legacy if record["event"] in ("dispatch.start", "dispatch.end")]
emit("cli segment: LOOP_UNIT/LOOP_ROUND labels read as declared attribution",
     len(declared) == 2 and all(record.get("attribution") == {"unit": "u1", "round": 1, "assurance": "declared"}
                                for record in declared), declared)
gates = result["gates"]
emit("cli segment: the schema-1 gate is never completion evidence (envelope-missing, isolation-weak)",
     len(gates) == 1 and gates[0]["reasons"] == ["envelope-missing", "isolation-weak"]
     and gates[0]["completion_evidence"] is False, gates)
PY
CLI_STATUS=$?
tally "$TMP_ROOT/cli.tsv" "$TMP_ROOT/cli.stderr" "$CLI_STATUS" "cli segment checks"

if [[ $CHECKS -ne $PINNED_CHECKS ]]; then
  printf 'selftest: FAIL (expected %d checks, ran %d)\n' "$PINNED_CHECKS" "$CHECKS" >&2
  exit 1
fi
if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
