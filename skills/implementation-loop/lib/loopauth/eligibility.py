"""Guard status and completion eligibility (task-graph-v1 Phase A, sub-unit
0a.3). Pure: no I/O and no import.

apply(reduced_run, outcomes) lays refs.py's claim outcomes over the
reducer's result. Per node (its latest attempt, as the reducer reports it):

- each guard's status: rejected, with its reason, when any claim behind it
  is rejected; claimed otherwise. A guard with no classified claim, a
  classified guard the reducer does not list, and any validity other than
  claimed or rejected are errors (fail closed): nothing here ever reads
  "verified".
- refuted: set when any of the node's authority claims, in any of its
  attempts, is rejected; refuted_by lists those claims' ids.
- completion_eligible: COMPLETION_ELIGIBLE, the constant False of 0a. It is
  an explicit gate, not a consequence of the guard set: no positive
  verification rule exists before the activating units of A2.1, so a node
  with no reference at all, and even a node whose guards all read verified,
  is ineligible.
"""

from __future__ import annotations

COMPLETION_ELIGIBLE = False
CLAIMED = "claimed"
REJECTED = "rejected"
VALIDITIES = (CLAIMED, REJECTED)


class EligibilityError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def apply(reduced_run: dict, outcomes: list) -> dict:
    by_guard: dict[tuple, list] = {}
    for outcome in outcomes:
        if outcome["validity"] not in VALIDITIES:
            raise EligibilityError("unknown-validity",
                                   f"claim {outcome['id']} has validity {outcome['validity']!r}")
        if outcome["guard"] is not None:
            by_guard.setdefault((outcome["attempt_id"], outcome["guard"]), []).append(outcome)
    nodes: dict[str, dict] = {}
    for node_id in sorted(reduced_run["nodes"]):
        node = reduced_run["nodes"][node_id]
        attempt_id = node["attempt_id"]
        listed = set(node["guards"])
        unknown = sorted(guard for attempt, guard in by_guard if attempt == attempt_id and guard not in listed)
        if unknown:
            raise EligibilityError("unknown-guard",
                                   f"{node_id}: classified guard(s) the reducer does not list: {unknown}")
        guards: dict[str, dict] = {}
        for guard in sorted(listed):
            behind = by_guard.get((attempt_id, guard))
            if not behind:
                raise EligibilityError("unclassified-guard", f"{node_id}: guard {guard} has no classified claim")
            rejected = [outcome for outcome in behind if outcome["validity"] == REJECTED]
            if rejected:
                guards[guard] = {"status": REJECTED, "reason": rejected[0]["reason"]}
            else:
                guards[guard] = {"status": CLAIMED, "reason": None}
        refuted_by = [outcome["id"] for outcome in outcomes
                      if outcome["node_id"] == node_id and outcome["authority"]
                      and outcome["validity"] == REJECTED]
        nodes[node_id] = {
            "node_id": node_id,
            "node_type": node["node_type"],
            "attempt_id": attempt_id,
            "state": node["state"],
            "guards": guards,
            "refuted": bool(refuted_by),
            "refuted_by": refuted_by,
            "completion_eligible": COMPLETION_ELIGIBLE,
        }
    return {"nodes": nodes, "completion_eligible": COMPLETION_ELIGIBLE}
