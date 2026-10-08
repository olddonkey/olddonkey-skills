"""The complete admission registry (task-graph-v1 Phase A, sub-unit 0a.2
section 1; tg:801-915 as amended by A1.3, A1.4, A1.9, A1.10, A2.1, A2.6).

Every row carries the six columns of tg:801-804, copied from the accepted
matrix (tg:809-829) and A1.3's table with only their Markdown emphasis
removed: trigger, principal / source, required evidence, validator,
exclusions (A1.10 ids), transition. The exclusions are tg:874-880 numbered
X1-X7 in the order written there; A1.3's seven rows list them as written in
A1.3's exclusion column. Each row also carries its admissibility (A1.4): a row
is admissible only once the unit that implements its complete domain
predicate has landed. A dormant row is registered in full and refused on
every use with its own error, before any store or anchor mutation.
approval.consume exists in the journal vocabulary but no row produces it
(A1.9); admit() refuses it with its own error.

entry says how a row can be reached:
  ceremony   an operator-TTY ceremony (external; store.begin)
  external   another external typed API (console session, target session)
  derived    a deterministic source other than recovery (the reducer, the
             expiry clock, the coordinator); never requested directly
  recovery   the recovery routine only (store.begin_recovery)
  compound   only as the child of its parent row's compound transition
Request cancellation has two branches (tg:810): the console gesture
(external) and the source state becoming invalid (derived).

sinks lists the A1.5 sinks a token of the row may use; children the rows a
parent token may open (store.child).

The validators and transitions of the admissible rows are pure functions
over a small abstract state, so the registry selftest can drive each one
positively and negatively; the writer calls the same functions.
"""

from __future__ import annotations

import re

# tg:874-880, in the order written there (A1.10).
EXCLUSIONS = {
    "X1": "a session may not answer its own request",
    "X2": "the implementing session may not close its own mechanism",
    "X3": "the builder, coordinator, and writer sessions are mechanically excluded from "
          "release acceptance",
    "X4": "an execution root may not mint scope its repository lacks",
    "X5": "an inheritance-changing rebind requires a fresh gesture",
    "X6": "the writer may not rotate its own key without the operator",
    "X7": "derived operations may never be requested directly",
}

# tg:855-868: the closed mapping from request kind to its source state.
REQUEST_SOURCE_STATES = {
    "review": "node state", "triage": "node state", "scope-change": "node state",
    "approval": "node state", "attestation": "node state", "observation": "node state",
    "design-decision": "node state", "ceiling": "node state", "safety-boundary": "node state",
    "mechanism-closure": "mechanism state",
    "segment-discharge": "accumulator state",
    "release-acceptance": "candidate-release state",
}
SOURCE_STATES = ("node state", "mechanism state", "accumulator state", "candidate-release state")

# tg:844-849: capability redemption's compound transition, by request kind.
REDEMPTION_COMPOUND = {kind: ("T-request-answered",) for kind in REQUEST_SOURCE_STATES}
REDEMPTION_COMPOUND.update({
    "segment-discharge": ("T-request-answered", "T-segment-reset"),
    "mechanism-closure": ("T-request-answered", "T-mechanism-closed"),
    "release-acceptance": ("T-request-answered", "T-release-accepted"),
})

SINKS = (
    "store-dir-create", "key-dir-create", "key-create", "seal", "pointer-seal",
    "intent-write", "genesis-intent-write", "regenesis-intent-write", "frame-append",
    "delimiter-completion", "intent-remove", "genesis-intent-remove",
    "regenesis-intent-remove", "cursor-write", "truncation", "quarantine-marker",
    "active-marker", "archive-move", "anchor-push",
)


def _row(row_id: str, *, operation: str, trigger: str, principal: str, evidence: str,
         validator: str, exclusions: tuple, transition: str, admissible_from: str,
         entry: str, cites: str, record_type: str | None = None, keys: bool = False,
         sinks: tuple = (), children: tuple = (), parent: str | None = None,
         branches: dict | None = None) -> dict:
    return {
        "id": row_id,
        "operation": operation,
        "cites": cites,
        "trigger": trigger,
        "principal": principal,
        "evidence": evidence,
        "validator": validator,
        "exclusions": exclusions,
        "transition": transition,
        "admissible_from": admissible_from,
        "admissible": admissible_from == "0a.2",
        "error": f"dormant-row:{row_id}",
        "entry": entry,
        "branches": branches or {},
        "record_type": record_type,
        "keys": keys,
        "sinks": sinks,
        "children": children,
        "parent": parent,
    }


RECORD_SINKS = ("seal", "pointer-seal", "frame-append", "cursor-write")
BY_REQUEST_KIND = "A2.1 (by request kind: unit 8, 9, or 12)"

ROWS = (
    # --- tg:809-829 -------------------------------------------------------
    _row("request-opening", operation="request opening", cites="tg:811; A1.9; A2.1",
         trigger="reducer, from the request kind's source state (below)",
         principal="derived",
         evidence="source state, request kind, schema-derived scope, target eligibility",
         validator="V-request-open", exclusions=("X7",), transition="T-request-opened",
         admissible_from=BY_REQUEST_KIND, entry="derived", record_type="request.opened",
         children=("capability-issuance",)),
    _row("request-cancellation", operation="request cancellation", cites="tg:812; A2.1",
         trigger="console gesture, or the source state becoming invalid",
         principal="authenticated human, or derived",
         evidence="request id, open state, reason",
         validator="V-request-cancel", exclusions=("X7",), transition="T-request-cancelled",
         admissible_from=BY_REQUEST_KIND, entry="external", record_type="request.cancelled",
         branches={"gesture": "external", "source-invalidated": "derived"}),
    _row("request-expiry", operation="request expiry", cites="tg:813; A2.1",
         trigger="the expiry passing", principal="derived, not decided",
         evidence="request id, expiry", validator="V-request-expire", exclusions=("X7",),
         transition="T-request-expired", admissible_from=BY_REQUEST_KIND, entry="derived",
         record_type="request.expired"),
    _row("capability-issuance", operation="capability issuance", cites="tg:814; A1.9; A2.1",
         trigger="a request is opened", principal="derived from that request",
         evidence="request id, target session + start token, scope, expiry, mode",
         validator="V-cap-issue", exclusions=("X7",), transition="T-cap-issued",
         admissible_from=BY_REQUEST_KIND, entry="compound", record_type="request.opened",
         parent="request-opening"),
    _row("capability-redemption", operation="capability redemption", cites="tg:815; tg:836-849",
         trigger="the target answers", principal="the bound target session",
         evidence="the secret + the answer, in one append (§6b)",
         validator="V-cap-redeem", exclusions=("X1",),
         transition="compound, by request kind (below)", admissible_from=BY_REQUEST_KIND,
         entry="external", record_type="request.redeemed",
         children=("segment-discharge", "mechanism-closure", "release-acceptance")),
    _row("enrollment", operation="enrollment", cites="tg:816; A2.6",
         trigger="console gesture", principal="authenticated human",
         evidence="canonical entry, executor profile, policy version, gesture nonce",
         validator="V-enroll", exclusions=(), transition="T-entry-active",
         admissible_from="unit 4", entry="external", record_type="entry.enrolled"),
    _row("enrollment-revocation", operation="enrollment revocation", cites="tg:817",
         trigger="console gesture", principal="authenticated human",
         evidence="entry digest, prior generation", validator="V-revoke-entry", exclusions=(),
         transition="T-entry-revoked", admissible_from="unit 4", entry="external",
         record_type="entry.revoked"),
    _row("repository-registration", operation="repository registration", cites="tg:818",
         trigger="console gesture", principal="authenticated human",
         evidence="common dir, incarnation id, generation", validator="V-repo-register",
         exclusions=(), transition="T-repo-active", admissible_from="unit 2", entry="external",
         record_type="repo.registered"),
    _row("repository-rebind", operation="repository rebind", cites="tg:819",
         trigger="console gesture", principal="authenticated human",
         evidence="prior + proposed incarnation, grant delta", validator="V-repo-rebind",
         exclusions=("X5",), transition="T-repo-rebound", admissible_from="unit 2",
         entry="external", record_type="repo.rebound"),
    _row("execution-root-registration", operation="execution-root registration", cites="tg:820",
         trigger="coordinator selects a root",
         principal="derived from the registered repository",
         evidence="logical repo id, root path, incarnation", validator="V-exec-root",
         exclusions=("X4", "X7"), transition="T-exec-root-active", admissible_from="unit 2",
         entry="derived", record_type="exec-root.registered"),
    _row("standing-authorization", operation="standing authorization", cites="tg:821",
         trigger="console gesture", principal="authenticated human",
         evidence="dial, scope, policy version", validator="V-standing", exclusions=(),
         transition="T-standing-active", admissible_from="unit 3", entry="external",
         record_type="standing.granted"),
    _row("standing-revocation", operation="standing revocation", cites="tg:822",
         trigger="console gesture", principal="authenticated human",
         evidence="prior sealed grant", validator="V-revoke-standing", exclusions=(),
         transition="T-standing-revoked", admissible_from="unit 3", entry="external",
         record_type="standing.revoked"),
    _row("segment-discharge", operation="segment discharge", cites="tg:823; tg:847; A2.1",
         trigger="derived — redemption of a segment-discharge request",
         principal="derived from that redeemed request",
         evidence="complete accumulator digest (§4c)", validator="V-segment",
         exclusions=("X7",), transition="T-segment-reset", admissible_from="unit 8 (A2.1)",
         entry="compound", parent="capability-redemption"),
    _row("mechanism-closure", operation="mechanism closure (P1–P5)", cites="tg:824; tg:848",
         trigger="derived — redemption of a mechanism-closure request",
         principal="derived from that redeemed request",
         evidence="mechanism id, conformance evidence, verifier identity",
         validator="V-closure", exclusions=("X2", "X7"), transition="T-mechanism-closed",
         admissible_from="unit 12", entry="compound", parent="capability-redemption"),
    _row("acceptance-platform-designation", operation="acceptance-platform designation",
         cites="tg:825", trigger="ceremony", principal="authenticated local operator",
         evidence="platform set, confinement mechanism + version", validator="V-platform",
         exclusions=(), transition="T-platform-policy-active", admissible_from="unit 12",
         entry="ceremony", record_type="platform.designated"),
    _row("release-acceptance", operation="release acceptance", cites="tg:826; tg:849",
         trigger="derived — redemption of a release-acceptance request",
         principal="derived from that redeemed request",
         evidence="exact release tree, acceptance evidence, decision chain, platform identity "
                  "+ confinement mechanism/version + platform-policy digest",
         validator="V-accept", exclusions=("X3", "X7"), transition="T-release-accepted",
         admissible_from="unit 12", entry="compound", parent="capability-redemption"),
    _row("authority-head-advance", operation="authority-head advance", cites="tg:827; A1.2",
         trigger="an admitted append", principal="derived, not decided",
         evidence="the append it follows", validator="V-head", exclusions=("X7",),
         transition="T-head-advanced", admissible_from="0a.2", entry="compound",
         sinks=("anchor-push",)),
    _row("epoch-rotation", operation="epoch rotation", cites="tg:828; A1.7; A2.1",
         trigger="ceremony", principal="authenticated local operator",
         evidence="current epoch, proposed key identity + new epoch, anchor position",
         validator="V-epoch-rotate", exclusions=("X6",),
         transition="T-epoch-rotated (atomically: old → verify-only, new → active)",
         admissible_from="0a.2", entry="ceremony", record_type="epoch.rotated", keys=True,
         sinks=("key-dir-create", "key-create", "intent-write", "intent-remove") + RECORD_SINKS,
         children=("authority-head-advance",)),
    _row("epoch-revocation", operation="epoch revocation", cites="tg:829; A1.2; A1.3",
         trigger="incident", principal="authenticated local operator",
         evidence="current epoch, anchor position", validator="V-epoch-revoke", exclusions=(),
         transition="T-epoch-revoked", admissible_from="0a.2", entry="ceremony",
         record_type="epoch.revoked",
         sinks=("intent-write", "intent-remove") + RECORD_SINKS,
         children=("authority-head-advance", "store-quarantine")),
    # --- A1.3 --------------------------------------------------------------
    _row("authority-genesis", operation="authority genesis", cites="A1.3; A2.3; A2.4",
         trigger="operator ceremony on an absent store and a remote whose anchor ref is absent",
         principal="operator-TTY (A1.1)",
         evidence="store id, remote URL, first epoch root public key, per-type subkey "
                  "certificates (A1.7)",
         validator="V-genesis", exclusions=("X6",),
         transition="T-store-created + anchor generation 1", admissible_from="0a.2",
         entry="ceremony", record_type="store.genesis", keys=True,
         sinks=("store-dir-create", "key-create", "genesis-intent-write",
                "genesis-intent-remove", "active-marker") + RECORD_SINKS,
         children=("authority-head-advance",)),
    _row("gesture-nonce-issuance", operation="gesture-nonce issuance", cites="A1.3; A2.6",
         trigger="the console asks to display an artifact for a gesture",
         principal="console session (external; one typed display API)",
         evidence="artifact digest, session id, expiry", validator="V-nonce-issue",
         exclusions=(), transition="T-nonce-issued (only the hash is stored)",
         admissible_from="unit 4 (A2.6)", entry="external", record_type="nonce.issued"),
    _row("torn-frame-truncation", operation="torn-frame truncation", cites="A1.3; A1.6",
         trigger="recovery observes a torn final frame (A1.6)",
         principal="derived — recovery source",
         evidence="the write intent and the frame's byte range", validator="V-torn",
         exclusions=("X7",), transition="T-torn-truncated — the only discard (tg:945)",
         admissible_from="0a.2", entry="recovery", sinks=("truncation",)),
    _row("anchor-replay-forward", operation="anchor replay-forward", cites="A1.2; A1.3; A1.6",
         trigger="recovery observes R.active = ptr(L − 1) and a durable write intent matching "
                 "frame L (A1.2)",
         principal="derived — recovery source",
         evidence="the validated frame L and its intent", validator="V-replay",
         exclusions=("X7",),
         transition="T-anchor-advanced; compound T-delimiter-completed + T-anchor-advanced when "
                    "frame L was complete but unterminated (A1.6)",
         admissible_from="0a.2", entry="recovery",
         sinks=("anchor-push", "delimiter-completion")),
    _row("recovery-tidy", operation="recovery tidy", cites="A1.2; A1.3",
         trigger="recovery observes R.active = ptr(L) with any of: a residual intent for L "
                 "matching frame L exactly, an intent for L + 1 at exactly the end of the log "
                 "with no bytes after it, or a cursor that disagrees with L",
         principal="derived — recovery source",
         evidence="the observed intent (if any), cursor, L, R", validator="V-tidy",
         exclusions=("X7",),
         transition="T-intent-cleared (when an intent is present) and/or T-cursor-reset",
         admissible_from="0a.2", entry="recovery", sinks=("intent-remove", "cursor-write")),
    _row("store-quarantine", operation="store quarantine", cites="A1.3",
         trigger="recovery observes a complete-but-invalid frame, a record naming a missing key "
                 "file, or any quarantine row of the A1.2 table; or revocation of the active "
                 "epoch (compound with T-epoch-revoked)",
         principal="derived — recovery source, or the revocation transaction",
         evidence="the offending position and the rule it failed", validator="V-quarantine",
         exclusions=("X7",), transition="T-quarantined", admissible_from="0a.2",
         entry="recovery", sinks=("quarantine-marker",), parent="epoch-revocation"),
    _row("linked-regenesis", operation="linked re-genesis", cites="A1.3; A2.4",
         trigger="operator ceremony on a quarantined store", principal="operator-TTY",
         evidence="the quarantined store's id, generation, last valid seq and digest, archive "
                  "location, new genesis evidence",
         validator="V-regenesis", exclusions=("X6",), transition="the crash protocol below",
         admissible_from="0a.2", entry="ceremony", record_type="store.regenesis", keys=True,
         sinks=("store-dir-create", "key-create", "regenesis-intent-write",
                "regenesis-intent-remove", "active-marker", "archive-move") + RECORD_SINKS,
         children=("authority-head-advance",)),
)

ROW_BY_ID = {row["id"]: row for row in ROWS}
# store-quarantine is also the child of an active-epoch revocation.
COMPOUND_CHILDREN = {"store-quarantine"}
ADMISSIBLE = tuple(row["id"] for row in ROWS if row["admissible"])
DORMANT = tuple(row["id"] for row in ROWS if not row["admissible"])
APPROVAL_CONSUME = "approval.consume"
DERIVED_ENTRIES = ("derived", "recovery", "compound")


class RowRefused(Exception):
    def __init__(self, code: str, message: str, dormant: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.dormant = dormant


def admit(row_id: str, *, branch: str | None = None, request_kind: str | None = None,
          source_state: str | None = None) -> dict:
    """The row's spec when it is admissible; otherwise its distinct error.
    Called before anything is created, read from the remote, or written. A
    branch (request cancellation) or a request kind and source state
    (request opening) never changes the answer while the row is dormant."""
    if row_id == APPROVAL_CONSUME:
        raise RowRefused("approval-consume-refused",
                         "approval.consume is produced by no row in Phase A (A1.9)")
    row = ROW_BY_ID.get(row_id)
    if row is None:
        raise RowRefused("unknown-row", f"no such row: {row_id!r}")
    if branch is not None and branch not in row["branches"]:
        raise RowRefused("unknown-branch", f"{row_id} has no branch {branch!r}")
    detail = "".join(f" ({name} {value})" for name, value in
                     (("branch", branch), ("kind", request_kind), ("source", source_state))
                     if value is not None)
    if not row["admissible"]:
        raise RowRefused(row["error"], f"{row['operation']}{detail} is dormant until "
                         f"{row['admissible_from']}", dormant=True)
    return row


def compound_entry(row_id: str) -> bool:
    return ROW_BY_ID[row_id]["entry"] == "compound" or row_id in COMPOUND_CHILDREN


# ---------------------------------------------------------------------------
# Epoch key states (A1.7)
# ---------------------------------------------------------------------------

EPOCH_TRANSITIONS = {("active", "verify-only"), ("active", "revoked"), ("verify-only", "revoked")}


def epoch_transition(current: str, target: str) -> str:
    if (current, target) not in EPOCH_TRANSITIONS:
        raise RowRefused("epoch-transition", f"no epoch transition {current} -> {target}")
    return target


# ---------------------------------------------------------------------------
# Validators, exclusions, and transitions of the admissible rows
# ---------------------------------------------------------------------------
# The abstract state: {"store": "absent"|"active", "generation": int,
#  "epochs": {str(n): state}, "active_epoch": int|None, "quarantined": bool,
#  "pending": bool, "log_seq": L, "anchor_seq": int|None, "intent": dict|None,
#  "cursor": int|None, "tail": None|"torn"|"unterminated"|"nonconforming"}

STORE_ID = re.compile(r"^[0-9a-f]{32}$")


def _need(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise RowRefused(code, message)


def check_exclusions(row_id: str, source: dict, branch: str | None = None) -> None:
    """The exclusions an admissible 0a.2 row enforces. X6: the writer may
    not rotate (or create) its own key without the operator -- an
    operator-TTY principal. X7: a derived operation is never requested
    directly -- only the recovery routine or its compound parent reaches
    it. X1-X5 guard dormant rows only; their activating units enforce them,
    so reaching one here is refused."""
    row = ROW_BY_ID[row_id]
    kind = source.get("kind")
    for exclusion in row["exclusions"]:
        if exclusion == "X6":
            _need(kind == "operator-tty", "exclusion-X6",
                  f"{row_id}: the writer may not change its own key without the operator")
        elif exclusion == "X7":
            if row["branches"] and row["branches"].get(branch or "") == "external":
                continue
            _need(kind in ("recovery", "compound-parent", "derived"), "exclusion-X7",
                  f"{row_id} is derived and may never be requested directly")
        else:
            raise RowRefused(f"exclusion-{exclusion}",
                             f"{row_id}: {exclusion} is enforced by the row's activating unit")


def validate(row_id: str, state: dict, evidence: dict) -> None:
    row = admit(row_id)
    function = VALIDATORS[row["validator"]]
    function(state, evidence)


def v_genesis(state: dict, evidence: dict) -> None:
    _need(state.get("store") == "absent" and not state.get("intents"), "V-genesis",
          "genesis needs an absent store with no intent")
    _need(evidence.get("remote_ref") in ("absent", "unreachable"), "V-genesis",
          "genesis needs a remote whose anchor ref is absent")
    _need(bool(STORE_ID.fullmatch(str(evidence.get("store_id", "")))), "V-genesis",
          "genesis needs a fresh store id")
    _need(bool(evidence.get("remote")) and bool(evidence.get("root_pub")), "V-genesis",
          "genesis needs the remote and the first root")
    _need(evidence.get("subkey_types") == evidence.get("types"), "V-genesis",
          "genesis certifies exactly one subkey per type")


def _committed(state: dict, code: str) -> None:
    _need(state.get("store") == "active", code, "the store is not active")
    _need(not state.get("quarantined"), code, "the store is quarantined")
    _need(not state.get("pending"), code, "the store is pending")
    _need(state.get("anchor_seq") == state.get("log_seq"), code, "the store is not committed")


def v_epoch_rotate(state: dict, evidence: dict) -> None:
    """current epoch, proposed key identity + new epoch, anchor position."""
    _committed(state, "V-epoch-rotate")
    active = state.get("active_epoch")
    _need(active is not None, "V-epoch-rotate", "no active epoch")
    _need(evidence.get("current_epoch") == active, "V-epoch-rotate",
          "rotation starts from the current (active) epoch")
    _need(evidence.get("epoch") == max(int(n) for n in state["epochs"]) + 1, "V-epoch-rotate",
          "rotation introduces the next epoch")
    _need(evidence.get("key_dir_fresh") is True, "V-epoch-rotate",
          "the proposed key identity lives in a fresh key directory")
    _need(evidence.get("subkey_types") == evidence.get("types"), "V-epoch-rotate",
          "rotation certifies exactly one subkey per type")
    _need(evidence.get("anchor_position") == state.get("anchor_seq"), "V-epoch-rotate",
          "rotation extends the anchored position")


def v_epoch_revoke(state: dict, evidence: dict) -> None:
    """current epoch, anchor position."""
    _committed(state, "V-epoch-revoke")
    epoch = evidence.get("epoch")
    current = state["epochs"].get(str(epoch))
    _need(current in ("active", "verify-only"), "V-epoch-revoke",
          "only an active or verify-only epoch is revoked")
    _need(evidence.get("prior_state") == current, "V-epoch-revoke", "prior_state must be observed")
    _need(evidence.get("current_epoch") == state.get("active_epoch"), "V-epoch-revoke",
          "the revocation is sealed by the current epoch")
    _need(evidence.get("anchor_position") == state.get("anchor_seq"), "V-epoch-revoke",
          "revocation extends the anchored position")


def v_head(state: dict, evidence: dict) -> None:
    _need(evidence.get("frame_durable") is True, "V-head", "the frame is not durable")
    _need(evidence.get("parent") == evidence.get("remote_tip"), "V-head",
          "the push must fast-forward from the expected parent")
    _need(evidence.get("seq") == state.get("log_seq"), "V-head",
          "the pointer must name the durable frame")


def v_torn(state: dict, evidence: dict) -> None:
    intent = state.get("intent") or {}
    _need(state.get("tail") == "torn", "V-torn", "the tail is not torn")
    _need(intent.get("seq") == state.get("log_seq", 0) + 1, "V-torn",
          "the intent is not for the next frame")
    _need(intent.get("offset") == evidence.get("tail_offset"), "V-torn",
          "the intent offset is not the tail offset")
    _need(evidence.get("remote_seq") != intent.get("seq"), "V-torn",
          "the remote names this sequence")


def v_replay(state: dict, evidence: dict) -> None:
    intent = state.get("intent") or {}
    L = state.get("log_seq", 0)
    if state.get("tail") == "unterminated":
        _need(intent.get("seq") == L + 1 and evidence.get("remote_seq") == L, "V-replay",
              "an unterminated frame is replayed only against the previous pointer")
    else:
        _need(state.get("tail") is None and intent.get("seq") == L
              and evidence.get("remote_seq") == L - 1, "V-replay",
              "replay needs R = ptr(L - 1) and an intent matching frame L")
    _need(evidence.get("intent_matches") is True, "V-replay", "the intent does not match")
    _need(evidence.get("frame_valid") is True, "V-replay", "frame L is not valid")


def v_tidy(state: dict, evidence: dict) -> None:
    L = state.get("log_seq", 0)
    _need(evidence.get("remote_seq") == L and evidence.get("remote_matches") is True, "V-tidy",
          "tidy needs R = ptr(L)")
    intent = state.get("intent")
    cursor_off = state.get("cursor") != L
    if intent is not None:
        exact_l = intent.get("seq") == L and evidence.get("intent_matches") is True
        next_clean = intent.get("seq") == L + 1 and evidence.get("no_tail") is True
        _need(exact_l or next_clean, "V-tidy", "the intent is neither exact for L nor a clean L+1")
    else:
        _need(cursor_off, "V-tidy", "nothing to tidy")


def v_quarantine(state: dict, evidence: dict) -> None:
    _need(bool(evidence.get("rule")), "V-quarantine", "a quarantine names the rule it failed")
    _need("position" in evidence, "V-quarantine", "a quarantine names the offending position")
    _need(not state.get("quarantined"), "V-quarantine", "the store is already quarantined")


def v_regenesis(state: dict, evidence: dict) -> None:
    _need(state.get("store") == "active" and state.get("quarantined") is True, "V-regenesis",
          "linked re-genesis needs a quarantined store")
    _need(not state.get("intents"), "V-regenesis", "an intent is present")
    _need(evidence.get("remote_tip_valid") is True, "V-regenesis",
          "the remote tip must be a valid pointer of the quarantined store")
    _need(evidence.get("lineage") != "test" or evidence.get("test_mode") is True, "V-regenesis",
          "re-genesis of a test lineage needs LOOP_AUTHORITY_TEST=1")


def _dormant_validator(state: dict, evidence: dict) -> None:
    raise RowRefused("dormant", "a dormant row has no validator in 0a.2")


VALIDATORS = {
    "V-genesis": v_genesis,
    "V-epoch-rotate": v_epoch_rotate,
    "V-epoch-revoke": v_epoch_revoke,
    "V-head": v_head,
    "V-torn": v_torn,
    "V-replay": v_replay,
    "V-tidy": v_tidy,
    "V-quarantine": v_quarantine,
    "V-regenesis": v_regenesis,
}
for _row_spec in ROWS:
    VALIDATORS.setdefault(_row_spec["validator"], _dormant_validator)


def transition(row_id: str, state: dict, evidence: dict) -> dict:
    """The row's transition on the abstract state (a new dict)."""
    admit(row_id)
    new = {key: (dict(value) if isinstance(value, dict) else value) for key, value in state.items()}
    if row_id == "authority-genesis":
        new.update(store="active", generation=1, epochs={"1": "active"}, active_epoch=1,
                   quarantined=False, log_seq=1, anchor_seq=1, intent=None, cursor=1,
                   intents=False)
    elif row_id == "epoch-rotation":
        old = new["active_epoch"]
        new["epochs"][str(old)] = epoch_transition(new["epochs"][str(old)], "verify-only")
        new["epochs"][str(evidence["epoch"])] = "active"
        new["active_epoch"] = evidence["epoch"]
        new["log_seq"] += 1
        new["anchor_seq"] = new["log_seq"]
        new["cursor"] = new["log_seq"]
    elif row_id == "epoch-revocation":
        epoch = str(evidence["epoch"])
        was_active = new["epochs"][epoch] == "active"
        new["epochs"][epoch] = epoch_transition(new["epochs"][epoch], "revoked")
        new["log_seq"] += 1
        new["anchor_seq"] = new["log_seq"]
        new["cursor"] = new["log_seq"]
        if was_active:
            new["active_epoch"] = None
            new = transition("store-quarantine", new, {"rule": "active-epoch-revoked",
                                                        "position": new["log_seq"]})
    elif row_id == "authority-head-advance":
        new["anchor_seq"] = new["log_seq"]
    elif row_id == "torn-frame-truncation":
        new["tail"] = None
    elif row_id == "anchor-replay-forward":
        if new.get("tail") == "unterminated":
            new["tail"] = None
            new["log_seq"] += 1
        new["anchor_seq"] = new["log_seq"]
        new["pending"] = False
    elif row_id == "recovery-tidy":
        new["intent"] = None
        new["cursor"] = new["log_seq"]
    elif row_id == "store-quarantine":
        new["quarantined"] = True
    elif row_id == "linked-regenesis":
        new.update(generation=new["generation"] + 1, epochs={"1": "active"}, active_epoch=1,
                   quarantined=False, log_seq=1, anchor_seq=1, intent=None, cursor=1,
                   intents=False)
    return new
