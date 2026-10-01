# task-graph-v1 Phase A — kickoff

**Status: 0a.1 ACCEPTED** at Codex read-only review round 13 (2026-09-29,
gpt-6-sol / max, thread `01a0ebb0`); findings per round 15 → 10 → 5 → 4 → 5 → 3
→ 3 → 2 → 2 → 2 → 2 → 3 → 2 (minor). This document specifies **only sub-unit
0a.1** (journal schema 2, canonical encoding, and the reducer). The trusted
writer (0a.2 onward) is **not specified here**: its contract is amendment A1
(`plans/task-graph-v1-amendment-a1.md`, **accepted** at round 9), and its
sub-units get their own kickoff. Earlier drafts' writer sections (the G
closures about rows, the signature, anchor, and principal decisions, and
0a.2–0a.4) are **withdrawn**; nothing in them is an instruction to anyone.

`tg:NN` cites `plans/task-graph-v1.md` (ACCEPTED, round 11). Code citations are
current lines at `d28e796` (branch `direction-u5-card-followups`, the head of
the unmerged product-direction-v1 stack) under `skills/implementation-loop/`.

**Base.** task-graph-v1 unit 0b shipped as product-direction-v1 Unit 1
(PR #60, `a6576b8`), not yet on `main`. 0a.1 stacks on the product-direction
stack and rebases onto `main` if the stack is merged first.

---

## 1. Two stores

| store | contents | trust |
| --- | --- | --- |
| **journal** (`scripts/loop-journal`) | observational events: lifecycle transitions, attempts, operation phases, reconciliation, `graph.diverged`, gates, dispatches, reviews, publications | unauthenticated; "single-writer convention plus provenance, not an OS boundary" (`tg:1082-1084`) |
| **authority store** (amendment A1, accepted) | sealed artifacts: requests, capabilities, redemptions and their compound transitions, approvals, receipts, keys, the anchored head | writer-sealed, anchored, independently verified |

The journal may **name** an authority record (by the digest of its canonical
payload) but never substitutes for it. **A journaled answer, approval, or
receipt label is never treated as a redeemed response or an authority fact**;
only the authority store can establish those (`tg:1065-1074`).

## 2. Decisions already made

- **Operator principal:** a terminal-challenge session, explicitly weaker than
  "a human, not a process" (user decision, 2026-09-28) — amendment A1.1.
- **Anchor:** a signed head in a ref of a private git remote the user controls,
  fail-closed on rollback and on unanchored state (user decision) — A1.2.
- **Runtime:** bash wrappers around stdlib-only `python3`, as every existing
  script (`scripts/loop-journal:25`, `scripts/loop-index:16`); shared code in
  `skills/implementation-loop/lib/loopauth/`, imported through the resolved
  sibling `lib/` directory, refusing a symlinked `lib/`.

---

## 3. Sub-unit 0a.1 — journal schema 2, canonical encoding, and the reducer

**Why.** The journal validates schema 1 only (`scripts/loop-journal:689-690`),
writes events with unsorted keys (`:606`), has no node, attempt, operation,
reconciliation, or `graph-diverged` events, no assurance fields, no reviewer
identity (`:73-80`), and records attestation as a caller string (`:97-100`).
task-graph-v1 requires a versioned vocabulary with schema-1 compatibility where
absence reads weakest (`tg:1128-1132`, `tg:245-246`), the §3 bindings on
completion-relevant records (`tg:183-198`), and the §3a lifecycle
(`tg:276-302`). None of this needs the writer, so it proceeds now.

### 3.1 Claims, not facts

0a.1 reads the journal only. Every reference it sees to an authority record,
and every fact that only the authority store could establish (that a request
was answered, that the answer was `denied`, that an approval exists), is a
**claim**: a typed field the event's writer asserted. The reducer checks
claims for **shape and internal consistency** — well-typed, of the kind the
row requires, and claiming the same `node_id` and `attempt_id` as the
transition — and records each guard as `claimed`. It never records `verified`;
0a.3 introduces verification against the authority store. **No node is
completion-eligible while any of its guards is only `claimed`**, so 0a.1
reduces runs and certifies nothing.

A reference is `{kind, digest, node_id, attempt_id, content}` plus, where a
row needs it, a claimed outcome (for example `answer: "denied"`) or, for
`provider_receipt_ref`, the claimed `receipt_object` the receipt names. `digest` is
the canonical digest (§3.4) of the referenced payload; `content` is the
**claimed** content object (§3.4) the referenced record is about, or `null`
for records that concern no content (answers, expiries).

### 3.2 Two axes and a separate marker set

- **Lifecycle state** (`tg:281-297`): `ready`, `blocked`, `starting`,
  `running`, `unknown-outcome`; terminal: `succeeded`, `failed`, `cancelled`,
  `parked`. Leaving a terminal state is a **new attempt** (`tg:152-154`),
  never a transition.
- **Stop-point result** (`tg:316-323`), a field only a `succeeded` unit node
  may carry: `reviewed-worktree`, `gated-commit`, `pr-open`, `integrated`. An
  investigation node's `succeeded` carries `informational` instead
  (`tg:565-569`).
- **Markers** (`tg:299`, `tg:339-340`), a set any node may carry in any state:
  `stale`, `superseded`, `landed-but-ungated`. A marker is never a result and
  never success. In the fold, an omitted, `null`, or empty `markers` all mean
  the empty set; a populated list is that set (duplicates refused).

### 3.3 The guarded transition table

Each row lists the claimed evidence its `node.transition` event must carry.
**Row selection:** the specific rows are tried first; the two general rows
(`any non-terminal → cancelled`, `any non-terminal → parked`) apply only from
a state that has no specific row to the same target (so `blocked → parked` and
`unknown-outcome → parked` always use their specific rows).

| from → to | required claimed evidence |
| --- | --- |
| ready → starting | `selection_ref` (the coordinator's selection), `authorization_ref`, `preconditions_digest` |
| ready → blocked | `request_ref` (an opened request, claimed) |
| blocked → ready | `answer_ref` (claimed outcome `granted` or `answered`), `revalidation_digest` |
| blocked → failed | `answer_ref` with claimed outcome `denied` |
| blocked → parked | `expiry_ref`, or `no_permitted_actor: true` |
| starting → running | `identity` (below) and `observation_ref` to the `operation.spawned` event that observed it (`tg:991-997`) |
| starting → failed | `spawn_error`, `effect: "none"` |
| starting → blocked | `drift_ref` and `barrier_closed_ref` to the `operation.reserve` event with **no** `operation.released` for the same attempt (`tg:290`) |
| running → blocked | `quiescence_ref`, `request_ref` (`tg:291`) |
| running → succeeded | `terminal_evidence` (below) with a success outcome |
| running → failed | `failure_evidence` (below) |
| running → unknown-outcome | `lost_child: true` |
| unknown-outcome → succeeded | `reconciliation_ref` of kind `reconciliation` or `receipt-lookup` (kind `attestation` refused, `tg:294`) **plus** the full `terminal_evidence` for the pinned row and the matching `stop_point_result` |
| unknown-outcome → failed | `reconciliation_ref` of kind `reconciliation` or `receipt-lookup` (kind `attestation` refused) **plus** `failure_evidence` |
| unknown-outcome → parked | `unresolvable_reason` |
| any non-terminal → cancelled | `cancel_ref`, `quiescence_ref` (`tg:296`) |
| any non-terminal → parked | `park_reason` |

**Process identity** (`tg:991-1011`): `identity = {adapter: P, effect_child:
P}` with `P = {boot_id, pid, pgid, start_time}`; the effect child is the
process that can cause effects, and the two are distinct records even when
one process plays both roles.

**Pinned node type and stop point.** `attempt.begin` pins the claimed
`node_type` and, for a unit, the claimed `stop_point`; both are in its request
subject (§3.4). Every later `node.transition` of that attempt carries the same
`node_type` (and `stop_point` for units) and is refused if they differ, and
`terminal_evidence` is selected by the **pinned** values — a caller cannot
choose the worktree row for a unit pinned to `pr`. **Every** transition into
`succeeded` (from `running` or from `unknown-outcome`) must carry the pinned
row's full `terminal_evidence` and a non-null `stop_point_result` equal to the
pinned stop point's result (`worktree` → `reviewed-worktree`, `commit` → `gated-commit`,
`pr` → `pr-open`, `merge` → `integrated`; `informational` for an
investigation). The pins stay claims until the node spec is verified (§4).

**`terminal_evidence`** is typed by node type and, for units, by stop point
(`tg:316-323`, `tg:342`, `tg:565-569`):

| node | stop point | required claimed evidence, each naming the content it is about |
| --- | --- | --- |
| unit | worktree | `review_ref` (verdict `pass`, a `reviewer`) whose reviewed content is the working tree (`tg:318`) |
| unit | commit | `review_ref` whose reviewed content is the **candidate commit** `{head: sha, tree_oid}`; `gate_ref` whose `input_content` is that same commit; `branch`, `sha` (`tg:319`) |
| unit | pr | the commit row's evidence, plus `publish_ref` with `pr` and `head_sha`, where `head_sha` = `sha` (`tg:320`) |
| unit | merge | the pr row's evidence, plus `pre_merge_gate_ref` whose `input_content` is the **integration** content, `integration_content`, `provider_receipt_ref`, `receipt_object` (the exact object the receipt names, fetched) **equal to the `receipt_object` claimed on `provider_receipt_ref`**, and `target_containment = {target_ref, contains: true}` — a claimed `contains: false`, or a `receipt_object` that differs from the receipt's object, refuses `running → succeeded` for a merge (the node may carry the `landed-but-ungated` marker instead) (`tg:336-340`) |
| investigation | — | `dispatch_ref` (the dispatch record), `transcript_digest`, `report_digest` (`tg:565-569`) |
| operation | — | `operation_result_ref` with the operation's completion evidence (`tg:411-419`) |
| approval | — | `answer_ref` |

**`failure_evidence`** governs every transition into `failed` except
`blocked → failed` and `starting → failed` (which have their own rows); the
`terminal_evidence` matrix governs success only. It is `{phase, failing_ref,
reason}`, where `phase` and the kind of `failing_ref` are typed by node type:

| node | phase | `failing_ref` kind |
| --- | --- | --- |
| unit | `dispatch` | a `dispatch.end` with a nonzero exit, or `dispatch.abandoned` |
| unit | `review` | a `review.recorded` with verdict `iterate` after the attempt's iteration limit |
| unit | `gate` | a `gate.result` whose verdict is `red` |
| unit | `publish` | a `publish.recorded` with `outcome: failed` |
| unit | `integrate` | the pre-merge gate or the provider receipt showing refusal |
| investigation | `dispatch` | as for units |
| operation | `operation` | an `operation.result` with a failure outcome |

A unit that fails before any review or gate therefore needs only its
`dispatch` failure, not the success matrix.

**Reconciliation substitutes for the lost result** (`tg:294`, `tg:421-429`).
`unknown-outcome` exists because the record the lost child would have
produced — its `operation.result`, `dispatch.end`, or a publish step's
`publish.recorded` — was never written. **In 0a.1 only `operation-result`
and `publish` can be substituted.** Schema-1 `dispatch.end` carries neither an
attempt nor a request binding (`scripts/loop-journal:93`), so the absence of a
dispatch end cannot be established against legacy history; a lost dispatch's
`unknown-outcome` can only be parked until dispatch records carry the binding
envelope (the adapter bindings of `tg:1220`, P5). On a transition out of
`unknown-outcome`, exactly that **one** missing reference in the pinned
`terminal_evidence` row (for `succeeded`) or in `failure_evidence` (for
`failed`) may be replaced by `reconciliation_ref` to a
`reconciliation.result` whose `substitutes` names that reference's kind,
whose `reconciliation_outcome` matches the direction of the transition, and whose
`observed_content` (and, for receipt lookup, `receipt_ref`) carries what the
missing record would have bound. Every other reference in the row is still
required, the pinned `stop_point_result` still applies, and the substitute is
a claim like any other.

**Outcome mapping and request source, per substituted kind** (every other
combination is refused):

| `substitutes` | request digest must equal | `reconciliation_outcome` ↔ `substituted_result` | content agreement |
| --- | --- | --- | --- |
| `operation-result` | the attempt's `operation.reserve` `request_digest` (the same request subject `operation.result` uses) | `succeeded` ↔ `outcome: succeeded`; `failed` ↔ `outcome: failed` | `observed_content` = `substituted_result.output_content` |
| `publish` | the digest recomputed from `substituted_result`'s `{stop_point, branch, content}`, with `stop_point` equal to the pinned stop point | `succeeded` ↔ `outcome: published`; `failed` ↔ `outcome: failed` | `observed_content` = `substituted_result.content` |

These request digests differ from `attempt.begin`'s by design: each record
kind has its own request subject (§3.4).

A `reconciliation.result` with `reconciliation_outcome: unresolved` is a
**diagnostic**: it carries no `substituted_result` (the field is `null`),
substitutes nothing, and leaves the node in `unknown-outcome`; only the
`unknown-outcome → parked` row can follow it.

A substitution is admitted only when the substituted record is **absent**: no
record of that kind exists for the same `attempt_id` and original
`request_digest`. If one exists — whether it agrees or conflicts with the
reconciliation — the substitution is refused, and two reconciliation results
substituting for the same record are refused.

**Relations between evidence** (`tg:195-205`). For every pair of references in
one row that must concern the same content (review ↔ gate ↔ publication, and
the pre-merge gate ↔ the integration content), the reducer compares the two
references' claimed `content` objects: exactly equal (`kind`, `head`,
`tree_oid`, or `content_digest`) is recorded as **`identity-claimed`**,
anything else as **`unproven`** — equal trees under different heads included
(`tg:207-212`). Neither certifies anything in 0a.1: `identity-claimed` becomes
`identity` only when 0a.3 or a later unit verifies both referenced records;
`unproven` is recorded, not rejected, as the plan requires for relation
candidates (`tg:204-205`).

### 3.4 Canonical encoding and the two digests

`lib/loopauth/canonical.py`: canonical JSON — UTF-8, keys sorted, no
insignificant whitespace, integers only; floats, NaN, infinities, and
non-string keys refused. `digest(x) = "sha256:" + hex(sha256(canonical(x)))`.

A record's digests are computed over **named subject objects**, never over the
record itself, so no digest depends on itself:

| record | `request_digest` = digest of | `result_digest` = digest of |
| --- | --- | --- |
| `attempt.begin` | typed by node type (below) | — (absent) |
| `operation.reserve` / `.result` | `{invocation, expected_preconditions}` | `.result` only: `{outcome, producer, log_digest, identity, output_content}` |
| `gate.result` | `{suite_invocation, input_content}` | `{verdict, gate_exit, suite_exit, binding, producer, log_digest, output_content}` |
| `review.recorded` | `{request_id, reviewed_content_digest}` | `{verdict, reviewer, findings_digest}` |
| `publish.recorded` | `{stop_point, branch, content}` | `{outcome, sha, pr, head_sha, error_code}` |
| `node.transition` | `{node_id, attempt_id, from, to}` | `{to, evidence, stop_point_result, markers, content}` |
| `reconciliation.result` | the substituted record's request subject (its `request_digest` is carried, not recomputed, because the original record is absent) | `{reconciliation_outcome, method, substitutes, observed_content, receipt_ref, substituted_result, producer}` |

- An **invocation** is always resolved: `{argv, cwd, env_digest,
  executor_version}` — `argv` as the exact vector executed
  (`scripts/run-gate.sh:516` executes its supplied argv), `env_digest` the
  digest of the canonical environment the child received. `suite_invocation`
  is an invocation, so a gate that ran suite S′ cannot match a node that
  specified S (`tg:177-181`).
- A **producer** is `{tool, tool_digest}`: the script that wrote the record
  and the digest of its bytes.
- `attempt.begin`'s request subject always includes `node_type`, and by node
  type: **unit** `{node_type, stop_point, node_spec_digest, input_content,
  dispatch: {backend, model, effort, prompt_digest}}`; **investigation**
  `{node_type, node_spec_digest, input_content, dispatch}`; **operation**
  `{node_type, node_spec_digest, input_content, invocation,
  catalog_entry_digest}`; **approval** `{node_type, node_spec_digest,
  envelope_digest}`.

**Absent fields.** A digest subject always contains **every** field its row
names. An optional field the record omits appears in the subject as JSON
`null`; a record may also carry it explicitly as `null`, which digests the
same. So `node.transition`'s `stop_point_result` and `markers`, and
`publish.recorded`'s `pr` and `head_sha` below the `pr` stop point, have one
defined digest whether present or absent.

**Digests are recomputed, never trusted.** Every field a subject names is
**required on the same record** (§3.5), and `loop-journal append --schema 2`
recomputes `request_digest` and `result_digest` from those fields and
**refuses** the record when either differs from the claimed value. This
rejects **internally inconsistent declarations** only: whether the recorded
`suite_invocation` is what actually ran, and whether `producer` really wrote
the record, stay unverified claims (§3.1) and never promote a gate. Today's
`run-gate.sh` still writes schema-1 gates; a producer-bound schema-2 gate path
is later work (§4).

**Content identity** (`tg:693-694` admits non-Git workspaces):
`content = {kind: "git", head, tree_oid}` or `{kind: "non-git",
content_digest}`; `input_content` and `output_content` use the same shape.

### 3.5 Schema-2 records

**Binding envelope**, required on every schema-2 `gate.result`,
`review.recorded`, `publish.recorded`, `operation.result`, and
`node.transition`: `run_id`, `run_snapshot_digest`, `node_id`,
`node_spec_digest`, `attempt_id`, `content`, `request_digest`,
`result_digest` (`tg:183-193`), plus `schema: 2` and `vocabulary: "tg-v1.0a1"`.
**`run_id` must equal the journal envelope's `run`** (the active context's
run, added by the journal as today); a mismatch is refused.

| event | fields beyond the envelope |
| --- | --- |
| `attempt.begin` | `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`, `attempt_id`, `parent_attempt_id?`, `input_content`, `node_type`, `stop_point` (units), and the typed request-subject fields for that node type (§3.4: `dispatch` for unit and investigation; `invocation` and `catalog_entry_digest` for operation; `envelope_digest` for approval), `request_digest` |
| `node.transition` | `from`, `to`, `node_type`, `stop_point` (units), the row's claimed evidence (§3.3), `stop_point_result?`, `markers?` |
| `operation.reserve` / `.spawned` / `.released` / `.result` | per `tg:991-1000`: `invocation`, `expected_preconditions`, `retry_class ∈ {safe-retry, reconcilable, manual-only}` (`tg:421-441`); `.spawned` adds `identity` (adapter and effect child); `.result` adds `outcome`, `producer`, `log_digest`, `identity`, `output_content` |
| `reconciliation.result` | the binding envelope of the **substituted** record — `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`, `attempt_id`, and that record's `request_digest`; `reconciliation_outcome ∈ {succeeded, failed, unresolved}`, `method ∈ {reconciliation, receipt-lookup}`, `substitutes ∈ {operation-result, publish}` (`dispatch-end` is refused in 0a.1), `observed_content`, `receipt_ref` (required when `method` is `receipt-lookup`), `producer`, `result_digest`, and a **nested** `substituted_result` object holding the substituted kind's claimed result fields: for `operation-result` `{outcome, output_content, identity}`; for `publish` `{stop_point, branch, content, outcome, sha, pr, head_sha, error_code}` with the same requiredness as `publish.recorded`. The two outcomes never share a field: `reconciliation_outcome` says which direction reconciliation resolved; `substituted_result.outcome` is the substituted record's own value (for example `published`) |
| `graph.diverged` | `run_id`, `prior_semantic_digest`, `observed_semantic_digest`, `successor_run_id` (`tg:665-669`) |
| `gate.result` | today's fields, typed `suite_exit` beside `verdict`/`gate_exit` (`tg:261-263`), `input_isolation`, and the subject fields `suite_invocation`, `input_content`, `producer`, `log_digest`, `output_content` |
| `review.recorded` | **required** `reviewer`, `request_id`, `reviewed_content_digest`, `verdict`, `findings_digest` (`tg:222-224`, `tg:1034`) |
| `publish.recorded` | **required** `stop_point ∈ {worktree, commit, pr, merge}`, `branch`, `content`, `outcome ∈ {published, failed}`; when `published`: `sha`, and `pr` and `head_sha` when `stop_point` is `pr` or `merge`; when `failed`: `error_code` |
| `approval.consume` | schema defined; **refused** by the journal in Phase A with a distinct error (`tg:541-545`, `tg:718-721`) |

**Assurance fields** (`tg:239-260`): `input_isolation ∈ {endpoint-sampled,
immutable}`, `capability_assurance ∈ {declared, enforced}`, `atomicity ∈
{unproven, atomic}`, `conformance ∈ {unproven, conformant}`. The journal
**refuses the strong value from any caller** (`tg:249-253`); absent reads as
weak.

### 3.6 How schema 2 is written and read

- `loop-journal append` gains `--schema 2`. Without it, behaviour is exactly
  today's schema 1, so every existing caller (adapters, `run-gate.sh`,
  `loop-run`) is unchanged.
- With `--schema 2`, the payload is validated against `lib/loopauth/
  vocabulary.py` and the whole event is written with `canonical.py` (sorted
  keys). The existing envelope fields (`schema`, `seq`, `ts`, `event`, `run`)
  are added as today.
- A segment may mix schema-1 and schema-2 lines. Readers (`loop-journal`'s
  own reader, `loop-index`, the reducer) dispatch on each line's `schema`. A
  line with an **unknown** schema value is reported as degraded evidence by
  every reader (never skipped silently, never a crash), and the reducer
  treats the run as degraded. **The writer fails closed:** the shared segment
  validation that every mutating command runs first — `append`, `begin-run`
  (which retires a stale context), `end-run`, `recover`, and `gc` — refuses,
  with one distinct exit code, to mutate, retire, or delete a run whose
  segment contains an unknown-schema line, and never truncates or rewrites
  that line.

### 3.7 The reducer

`lib/loopauth/reduce.py`, pure (no I/O): folds a run's events into per-node
lifecycle state, stop-point result, markers, and a per-guard status
(`claimed`), applying §3.2–§3.3. It rejects any transition not in the table,
any row whose claimed evidence is missing, mistyped, of the wrong kind, or
claims another node or attempt, and any transition out of a terminal state
(`tg:297`). `gate_ineligibility(gate)` returns the **set of reasons** a gate
is not completion evidence — `binding-changed`, `binding-unavailable`,
`isolation-weak` (absent or `endpoint-sampled`), `verdict-not-green`,
`verdict-inconsistent` (`verdict` absent, or `gate_exit` absent or not an
exact int, or `green` with `gate_exit ≠ 0`, or `red` with `gate_exit = 0`;
compared with `gate_exit`, not `suite_exit`, because a baseline-matched gate
is green over a nonzero suite exit), `envelope-missing` — each rule
contributing its own reason (`tg:225-237`); the reducer exposes these reasons
per gate, independently of overall eligibility. Declared
`unit`/`round` read as weakest-assurance attribution (product-direction-v1
Unit 2). Schema-1 records reduce with every axis weakest and are never
completion evidence. **Completion eligibility is always false in 0a.1**,
because every guard is `claimed` (§3.1).

### 3.8 Fields

C: `skills/implementation-loop/lib/loopauth/__init__.py`,
`skills/implementation-loop/lib/loopauth/canonical.py`,
`skills/implementation-loop/lib/loopauth/vocabulary.py`,
`skills/implementation-loop/lib/loopauth/reduce.py`,
`skills/implementation-loop/tests/reduce-selftest.sh`.

M: `skills/implementation-loop/scripts/loop-journal` (`--schema 2`, the
import, canonical write, mixed reads, strong-value and `approval.consume`
refusal), `skills/implementation-loop/scripts/loop-index` (tolerate schema-2
lines; an unknown schema is degraded, never a crash),
`skills/implementation-loop/tests/journal-selftest.sh`,
`skills/implementation-loop/tests/index-selftest.sh`,
`skills/implementation-loop/references/state-schema.md` (schema 2, both axes,
markers, the guard table, digests, compatibility),
`.github/workflows/selftest.yml` (`bash -n` and a run step for the new suite),
`AGENTS.md` (the new suite and changed counts).

T:
- `reduce-selftest.sh` carries its **own frozen oracle** of the §3a table, of
  every row's evidence fields, **and of the full `terminal_evidence` matrix**
  (every node type and stop point with its required references and content
  bindings), written out literally in the test, **not** imported from
  `reduce.py`. It asserts the reducer's table equals the oracle
  (so deleting a row or a field fails), then, from the oracle: every row
  accepted with its evidence; every row rejected once per missing,
  mistyped, wrong-kind, or other-node/other-attempt evidence field; every pair
  not in the oracle rejected (the full state × state product); every terminal
  × every target rejected, `parked` included; row selection (a specific row
  wins over the general one); attestation refused for `unknown-outcome →
  succeeded`; `terminal_evidence` for each node type and stop point, each
  reference missing in turn; relations: exactly equal content →
  `identity-claimed` and never `identity`, same tree under a different head →
  `unproven`, a review of the working tree
  offered for a commit stop point → `unproven`, and a `pr` row whose
  `head_sha` differs from `sha` refused; a merge with claimed `contains:
  false`, or with `receipt_object` differing from the receipt's object,
  refused; a digest subject with an optional field omitted equals the one
  with it explicitly `null`, and differs from one with a value; a transition
  whose `node_type` or `stop_point` differs from the attempt's pins refused; a
  unit pinned to `pr` refused when it offers only worktree evidence; `running
  → succeeded` refused with a null `stop_point_result` or one not matching the
  pinned stop point; `unknown-outcome → succeeded` refused with a
  reconciliation reference but without the pinned row's terminal evidence or
  without a matching `stop_point_result`; `running → failed` accepted with
  only a `dispatch`-phase failure (no review, no gate), and refused with a
  `failing_ref` of the wrong kind for its phase; an operation that crashed
  after its effect with **no** `operation.result`, resolved by receipt lookup
  both to `succeeded` and to `failed` through a substituting
  `reconciliation.result`, and refused when the substitute names another kind,
  its `reconciliation_outcome` disagrees with the transition, or a second reference is
  substituted; a substitute whose `run_id`, `node_id`, or `attempt_id` differs from the
  attempt's, or whose `request_digest` differs from its kind's source in the
  mapping table, refused; a valid operation substitute whose
  `request_digest` differs from `attempt.begin`'s accepted; every
  contradictory outcome pair (`succeeded` with `outcome: failed`, `failed`
  with `published`, and so on) refused; `observed_content` differing from the
  nested content refused; `substitutes: dispatch-end` refused; an `unresolved` reconciliation with a
  null `substituted_result` accepted and leaving the node in
  `unknown-outcome`, and refused with a non-null one; or (for a `pr` publish) whose
  `head_sha` differs from `sha`, refused; a substitution refused when an
  `operation.result` for the same attempt and request exists, both when it
  agrees and when it conflicts (an existing failure plus a reconciled success);
  two substitutes for one record refused; a successful publish substitute
  (`reconciliation_outcome: succeeded`, `substituted_result.outcome:
  published`) and a failed one accepted through the real schema; a
  reconciliation record whose `result_digest` differs from the one recomputed
  from its fields refused; `publish.recorded` with `outcome: failed` and an `error_code`
  accepted through the CLI and used as a `publish`-phase failure, and refused
  without `error_code`; markers omitted, `null`,
  empty, and populated folded as stated, duplicates refused; stop-point result refused on a non-succeeded
  node; markers accepted on nodes in non-succeeded states and never counted as
  success; each gate-ineligibility rule alone **asserted through its own
reason** in `gate_ineligibility` (so removing any one rule fails even though
overall eligibility stays false), and a gate meeting none of the six yields
the empty set; a `succeeded` node whose guards
  are all `claimed` is **never** completion-eligible; schema-1 fixtures from
  the existing suites reduce with every axis weakest and nothing eligible.
- Canonical encoding vectors: key order, unicode, nested objects, integer
  bounds; floats, NaN, infinities, non-string keys refused; digest inputs per
  §3.4, including that changing any subject field changes the digest and that
  no record's digest is computed over a field that contains it.
- `journal-selftest.sh`, **through the real CLI**: `append --schema 2` for
  every schema-2 event accepted with its required fields and refused without
  each; schema-2 lines written with sorted keys; a strong assurance value
  refused for each axis; `approval.consume` refused with its distinct error;
  appends without `--schema` byte-for-byte as before; a mixed segment reads.
- `index-selftest.sh`: a run with mixed schema-1/schema-2 lines indexes; an
  unknown `schema` value degrades the run without crashing and is reported.
- `journal-selftest.sh` also: with an unknown-schema line in the active
  segment, each of `append`, `begin-run`, `end-run`, `recover`, and `gc` exits
  with the distinct code and leaves the segment, the context file, and the
  store byte-identical; a **terminated** run whose segment contains an
unknown-schema line, under `gc` cap pressure (`LOOP_JOURNAL_GC_CAP_BYTES`),
stays byte-identical; a schema-2 record whose `run_id` differs from the
envelope `run` is refused; `append --schema 2` of a gate whose recorded
  `suite_invocation` differs from the one its claimed `request_digest` was
  computed over is refused, and likewise for `result_digest`.

G: none (no Cursor build input is touched).
Gate: full host replica of `.github/workflows/selftest.yml` plus
`reduce-selftest.sh`.

### 3.9 Clarifications from implementation review (2026-09-29)

The cross-review of the round-1 implementation (Codex gpt-6-sol, read-only)
found three places where this section was silent or loose; the judge settles
them here, and they bind 0a.1:

- **The candidate commit is bound to `sha`.** For unit `commit`, `pr`, and
  `merge`, each reference whose content is the candidate commit (`review_ref`,
  `gate_ref`, `publish_ref`) is also related to the terminal evidence's
  `sha`: a git content with `head = sha` is `identity-claimed`, anything else
  `unproven` — recorded, not refused, like every relation above.
- **`integrate` is the merge stop point's failure phase only.** It is
  admissible only for a unit pinned to `merge`. Its gate alternative is the
  **pre-merge** gate: `failure_evidence` then also carries
  `integration_content`, and the red gate's claimed `input_content` must equal
  it (otherwise refused). The provider-receipt alternative is unchanged.
- **Canonical limits.** Integers are limited to ±(2^53 − 1) and nesting to
  depth 64; anything beyond has no canonical encoding and is refused.

---

## 4. What 0a.3 must pick up (hand-off)

Recorded so the writer's specification cannot drop them:

- verification of claimed **authority** references against the authority
  store, upgrading those guards from `claimed` to `verified`. This does **not**
  promote the **process** guards — observation, closed barrier, quiescence,
  process identity — which stay `claimed` until their mechanism proof exists
  (the adapter handshake of unit 9 and P5, `tg:1002-1011`, `tg:1203-1205`). A
  node becomes completion-eligible only when every guard it relies on is
  `verified`;
- the **approval-grant** authority record (`tg:529-548`) and the rule that a
  journaled answer counts only when linked to a **redeemed capability** in the
  authority store (`tg:1065-1074`); journal labels (`request_id`,
  `answer_ref`, `result_digest`) are claims until then;
- everything amendment A1 settles for the writer (principals, anchor, rows,
  admissibility, typed entry points, framing, keys, start tokens).

**Amended by A2.1** (`plans/task-graph-v1-amendment-a2.md`, accepted
2026-09-29): the request rows stay dormant through 0a, so 0a.3 verifies these
claims only to the extent 0a can (every authority claim is rejected); the
approval grant arrives with unit 8, and upgrading guards to `verified` moves
to the units that activate each request kind.

## 5. Dispositions

### Round 1 (thread `01a0ebb0`)

Findings 1–9 and 12–14 concerned the writer; they are carried by amendment A1
and the withdrawn sections no longer instruct anyone. Finding 10 (two axes,
guards) and 11 (bindings, review identity) are addressed in §3. Finding 15
(`O_NOFOLLOW` citation) belonged to a withdrawn section; the authority store's
open discipline is A1's to state.

### Round 2

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: reference checks 0a.1 cannot perform | **accepted** — §3.1: references carry claimed `node_id`, `attempt_id`, and outcome; guards are `claimed`; nothing is eligible in 0a.1 |
| 2 | MAJOR: guard table gaps and overlap | **accepted** — selection, observation, and barrier evidence added; `terminal_evidence` typed by node and stop point; row-selection rule |
| 3 | MAJOR: generated tests can lose a protection | **accepted** — a frozen oracle in the test, compared to the reducer's table |
| 4 | MAJOR: binding envelope not literal | **accepted** — §3.4 digest subjects per record, `attempt.begin` without a result digest, a `stop_point` discriminator, non-Git content identity |
| 5 | MAJOR: markers mixed into the result | **accepted** — markers are a separate set allowed in any state |
| 6 | MAJOR: how schema 2 is written | **accepted** — §3.6 `--schema 2`, canonical write, mixed reads; `journal-selftest.sh` and `index-selftest.sh` in M; CLI-path tests |
| 7 | MAJOR: approval grant and redemption linkage | **accepted** — §4 hand-off; journal labels are never redeemed responses (§1) |
| 8 | MAJOR: superseded text still operative | **accepted** — the writer sections are withdrawn (status line) |
| 9 | MAJOR: FIDO2 option overstated | **accepted, moot** — the user chose the terminal challenge; A1.1 records that a future hardware principal must require user-presence or user-verification flags and bind the envelope |
| 10 | MAJOR: anchor options partial | **accepted, moot for options** — the user chose the remote; A1.2 carries the fail-closed rules, including that unanchored records are unusable |
| 11 | MINOR: framing repair is a design task | **accepted** — framing is A1's, with crash and mutated-header vectors |

### Round 3

| # | finding | disposition |
| --- | --- | --- |
| A1 | MAJOR: terminal evidence omits required subjects | **accepted** — per stop point: branch and sha for commit, PR and head sha for pr, pre-merge gate on integration content and provider receipt for merge; dispatch record, transcript, and report digests for investigation |
| A2 | MAJOR: digest subjects let the wrong gate match | **accepted** — resolved `suite_invocation`; `producer` and `output_content` in result subjects; `attempt.begin` subject typed by node type |
| A3 | MAJOR: process identity too narrow; hand-off overclaims | **accepted** — adapter and effect-child identities with pgid; §4 says authority verification does not promote process guards |
| A4 | MAJOR: gate-rule deletion could pass | **accepted** — `gate_ineligibility` returns reasons; each rule tested through its own reason |
| A5 | MAJOR: unknown schema needs a writer rule | **accepted** — readers report degraded; `append` refuses with a distinct code and leaves the segment untouched; both tested |

### Round 4

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: digest subjects absent from records | **accepted** — every subject field is required on its record; `append --schema 2` recomputes both digests and refuses a mismatch; tested with a changed suite under an unchanged digest |
| 2 | MAJOR: later stop points inherit a worktree review | **accepted** — each stop point names its review subject; relations are `identity` only on exactly equal content, otherwise `unproven` |
| 3 | MAJOR: PR/merge evidence and the matrix oracle | **accepted** — `head_sha` required on pr/merge publications; merge adds `receipt_object` and `target_containment`; the oracle freezes the full terminal-evidence matrix |
| 4 | MAJOR: unknown schema covers only `append` | **accepted** — shared validation before `append`, `begin-run`, `end-run`, `recover`, and `gc`; each tested |

### Round 5

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: relations not computable from references | **accepted** — references carry claimed `content`; relations are `identity-claimed` or `unproven`, never `identity` in 0a.1; the terminal-evidence table is contiguous again |
| 2 | MAJOR: recomputation overstated | **accepted** — it rejects internally inconsistent declarations only; invocation and producer stay unverified; the schema-2 gate producer path is later work |
| 3 | MAJOR: two run identities; transition digest omits its result | **accepted** — `run_id` must equal the envelope `run`; the transition's result subject includes `to`, result, markers, and content; both mismatches tested |
| 4 | MAJOR: inconsistent verdict and unavailable binding | **accepted** — `verdict-inconsistent` (compared with `gate_exit`) and `binding-unavailable` reasons, each tested alone |
| 5 | MINOR: gc of a terminated degraded run | **accepted** — tested under cap pressure |

### Round 6

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: optional fields in digest subjects | **accepted** — absent is `null` in the subject; omitted and explicit `null` digest the same; tested |
| 2 | MAJOR: contradictory test expectations | **accepted** — the stale `identity` expectation removed; the empty-reason case tests all six rules |
| 3 | MAJOR: merge containment could be claimed false | **accepted** — claimed `contains: true` and receipt-object equality required for a merge's success; negative vectors added |

### Round 7

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: no pinned stop point | **accepted** — `attempt.begin` pins `node_type` and a unit's `stop_point`, both in its request subject; transitions must agree; terminal evidence is selected by the pins; success needs the matching `stop_point_result` |
| 2 | MAJOR: receipt object not checkable | **accepted** — `provider_receipt_ref` carries the claimed `receipt_object`; the merge row compares the two claims |
| 3 | MINOR: markers `null` meaning | **accepted** — omitted, `null`, and empty are the empty set; duplicates refused; tested |

### Round 8

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: no failure-evidence schema | **accepted** — `failure_evidence {phase, failing_ref, reason}` typed by node and phase; the terminal matrix governs success only; a pre-review failure tested |
| 2 | MAJOR: `unknown-outcome → succeeded` bypassed the pins | **accepted** — every transition into `succeeded` needs the pinned row's terminal evidence and matching result; reconciliation is additional; negative test added |

### Round 9

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: reconciliation needed the missing result | **accepted** — a `reconciliation.result` naming the one missing reference's kind substitutes for it, with matching outcome and observed content; everything else in the row stays required; both directions tested with no `operation.result` |
| 2 | MAJOR: publish failure had no outcome field | **accepted** — `outcome ∈ {published, failed}` and `error_code`, both in the result digest; tested through the CLI |

### Round 10

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: substitute lacked the missing record's identity | **accepted** — it carries the substituted record's binding envelope and request digest, and kind-specific result fields (a publish substitute carries PR and head sha); mismatches tested |
| 2 | MAJOR: substitution did not require absence | **accepted** — only when no record of that kind exists for the attempt and request; agreeing, conflicting, and duplicate cases refused and tested |

### Round 11

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: two incompatible `outcome` values | **accepted** — `reconciliation_outcome` at the top level, the substituted record's fields nested in `substituted_result`; both publish directions tested through the schema |
| 2 | MAJOR: no result digest or producer on the reconciliation record | **accepted** — `producer` and a `result_digest` over the reconciliation's own outcome, method, kind, observed content, receipt, nested result, and producer, recomputed by the journal; the substituted record's request digest is carried |

### Round 12

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: the two outcomes could contradict | **accepted** — a per-kind mapping table; every other pair refused; `observed_content` must equal the nested content; tested |
| 2 | MAJOR: wrong request-digest source | **accepted** — the source is named per kind (the operation's reservation; the publish request recomputed from the nested fields with the pinned stop point); a valid substitute differing from `attempt.begin`'s digest tested |
| 3 | MAJOR: dispatch-end absence against legacy history | **accepted** — `dispatch-end` substitution refused in 0a.1; a lost dispatch can only be parked until dispatch records are bound; tested |

### Round 13 — ACCEPT

| # | finding | disposition |
| --- | --- | --- |
| 1 | MINOR: `unresolved` needs a rule | **accepted** — a diagnostic with a null `substituted_result` that leaves the node in `unknown-outcome`; tested |
| 2 | MINOR: stale status and shifted `tg:` lines | **accepted** — status refreshed; the A1 pointer in task-graph-v1 was moved onto its existing status line, so every `tg:NN` citation (here, in A1, and in product-direction-v1) is valid again |

