# task-graph-v1 Phase A — sub-unit 0a.3 (verifying claimed authority references)

**Status: ACCEPTED** at Codex read-only review round 3 (2026-09-29, gpt-6-sol /
max, thread `01a0ec41`; findings 10 → 7 → 4, the last on A2.1 and the 0a.2
delta, both accepted at rounds 4 and 5), together with
amendment A2.1 (`plans/task-graph-v1-amendment-a2.md`). Round 1 (thread
`01a0ec41`) rejected the first draft, which admitted `review` and `triage`
requests in 0a; its findings are dispositioned in §8, and the scope moved as
A2.1 states. The contract is `plans/task-graph-v1.md` (ACCEPTED round 11) as
amended by A1 (ACCEPTED round 9) and A2. This document decides only what those
leave to implementation.

`tg:NN`, `A1.n`, `A2.n` cite the plan and amendments; `pa §n` cites the 0a.1
specification (`plans/task-graph-v1-phase-a.md`, ACCEPTED round 13, with
§3.9); `p2 §n` cites the 0a.2 specification
(`plans/task-graph-v1-phase-a-0a2.md`, ACCEPTED round 15). 0a.3 builds on
0a.1 (`lib/loopauth/vocabulary.py`, `reduce.py`) and 0a.2 (the store and its
read-only verification).

---

## 1. Scope

0a.1 records every reference to an authority record as a **claim** and never
upgrades it (pa §3.1); its hand-off asks 0a.3 to verify those claims against
the authority store (pa §4). A2.1 keeps every request row dormant through 0a,
so **no request, answer, or expiry can be backed by a sealed record in 0a**.
0a.3 therefore delivers the verification layer with the outcomes 0a can
honestly produce, on two separate dimensions:

- **claim validity** — for an authority reference: **rejected**, reason
  `rows-dormant`, always in 0a (no admitted row could have produced the
  record, whatever the store holds); for every other reference: **claimed**;
- **store state** — `current` or `unavailable` with its reason, reported
  beside the claims and never softening them.

It never produces `verified`, upgrades no guard, admits no row, and writes
nothing. The activating units of A2.1 add the positive verification rules
together with the records they verify.

## 2. The closed reference map

The map is keyed by **reference kind** — every kind in 0a.1's vocabulary
(`REFERENCE_KINDS`), each listed once — plus the one non-reference authority
claim (`review.recorded`'s `request_id`) and the non-reference evidence
fields. A kind or field the map does not list is an error (fail closed).

| reference kind (the 0a.1 fields that use it) | names | claim validity in 0a |
| --- | --- | --- |
| `request` (`request_ref`) | a `request.opened` record | **rejected** (`rows-dormant`) |
| `answer` (`answer_ref`, any claimed outcome; the approval row's `answer_ref`) | a `request.redeemed` record | **rejected** (`rows-dormant`) |
| `expiry` (`expiry_ref`) | a `request.expired` record | **rejected** (`rows-dormant`) |
| — (`review.recorded`'s `request_id`) | the `request.redeemed` that answered it | **rejected** (`rows-dormant`): a response with no redeemed capability is rejected, not unattributed (`tg:1071-1072`) |
| `cancel` (`cancel_ref`) | a node cancellation (`tg:296`); no record type in Phase A | claimed |
| `authorization` (`authorization_ref`) | an effect authorization (units 3, 7, 8) | claimed |
| `selection` (`selection_ref`), `drift` (`drift_ref`) | coordinator decisions (unit 10) | claimed |
| `quiescence` (`quiescence_ref`), `operation-spawned` (`observation_ref`), `operation-reserve` (`barrier_closed_ref`) | process guards (unit 9, P5; pa §4) | claimed |
| `review`, `gate`, `publish`, `provider-receipt`, `operation-result`, `dispatch`, `dispatch-end`, `dispatch-abandoned` (the `terminal_evidence` references and every `failing_ref` alternative) | journal records (units 6, 9) | claimed |
| `reconciliation`, `receipt-lookup`, `attestation` (`reconciliation_ref`, `receipt_ref`) | journal records (unit 9) | claimed |

| non-reference evidence | claim validity in 0a |
| --- | --- |
| `identity` (process identity) | claimed (process guard) |
| `target_containment` (`{target_ref, contains}`), `integration_content`, `receipt_object`, `branch`, `sha` | claimed |
| pinned `node_type`, `stop_point` | claimed (node spec, unit 5) |
| `no_permitted_actor`, every digest and text field (`preconditions_digest`, `revalidation_digest`, `transcript_digest`, `report_digest`, `spawn_error`, `effect`, `lost_child`, `park_reason`, `unresolvable_reason`, `reason`) | claimed |

The map is data in `lib/loopauth/refs.py`; the test compares it with a frozen
copy written out literally and asserts that every kind of 0a.1's
`REFERENCE_KINDS` and every evidence field of 0a.1's rows and matrices appears
exactly once.

## 3. Store state

`refs.py` reads the store **only** through 0a.2's read-only verification path
(the checks `loop-authority verify` runs: frames, seals, chain, anchor
readback by content, recovery classification without mutation) and reports
`current` (anchored; not pending, quarantined, or in a bootstrap terminal
state, A2.3) or `unavailable` with its reason (`absent`, `pending`,
`remote-unreachable`, `quarantined`, `genesis-invalid`, `anchor-mismatch`,
`genesis-quarantined`, and 0a.2's other fail-closed states `active-invalid`
and `regenesis-invalid`; any classification the map does not list is an
error), plus the lineage class (p2 §4). The store state is
context: it never turns a rejected claim into anything else, and in 0a it
never makes a claim valid. A request-type record cannot be valid in any 0a
store — A2.1's activation boundary, enforced by 0a.2's writer and verifier
(`admitted_protocols` is empty in every 0a epoch) — so 0a.3 needs no lookup
to reject.

## 4. Eligibility

`lib/loopauth/eligibility.py` is pure: `apply(reduced_run, outcomes)` returns,
per node, each guard's status (`claimed`, or `rejected` with its reason), a
node-level `refuted` flag set when any of its authority claims is rejected,
and **completion eligibility, which is the constant `false` in 0a** — an
explicit gate, not a consequence of the guard set (so a node with no
references at all is ineligible too). The reducer is not changed and stays
pure (pa §3.7).

## 5. The command

`loop-authority refs --workspace <path> --run <run_id>` reads the run's
journal exactly as `loop-journal` locates it (`workspace_key_for`,
`runs/<run>.jsonl`) through a read-only helper in
`lib/loopauth/journal_read.py`, reduces it with 0a.1's reducer, classifies
every reference and claim, and prints canonical JSON: the store state and
lineage, every claim with its validity and reason, and each node's guards,
`refuted`, and eligibility. It writes nothing, takes no lock that blocks the
writer, and reaches no sink (the reachability scan of p2 §7 covers `refs.py`,
`eligibility.py`, and `journal_read.py`).

## 6. Fields

**C:** `skills/implementation-loop/lib/loopauth/refs.py`,
`skills/implementation-loop/lib/loopauth/eligibility.py`,
`skills/implementation-loop/lib/loopauth/journal_read.py`, the `refs`
subcommand of `skills/implementation-loop/scripts/loop-authority`,
`skills/implementation-loop/tests/refs-selftest.sh`.

**M:** `references/state-schema.md` (the reference map and the two
dimensions), `.github/workflows/selftest.yml` (`bash -n` and a run step),
`AGENTS.md`, and `registry-selftest.sh` (the reachability list, and the
cross-product negatives below).

**T** — `refs-selftest.sh` (scratch `HOME`, a `file://` test lineage built by
0a.2's own genesis, journals written through `loop-journal append --schema 2`):
- the map equals its frozen oracle; every kind of 0a.1's `REFERENCE_KINDS` and
  every evidence field of its rows and matrices appears exactly once; an
  unlisted kind or field fails closed;
- a run whose nodes carry `request_ref`, `answer_ref` (each claimed outcome),
  and `expiry_ref`, and a `review.recorded` with a `request_id`, yields
  **rejected** / `rows-dormant` for each and marks those nodes `refuted`,
  with the store **current**, **absent**, **pending** (remote unreachable),
  **quarantined**, and in each bootstrap terminal state — the store state
  reported each time, the rejection identical each time;
- every other listed reference and evidence field stays `claimed`;
- completion eligibility is false for every node in every case above,
  including a `succeeded` unit whose every non-authority guard is claimed
  and a node with no references at all;
- `loop-authority refs` leaves the journal store, the authority directory,
  and the remote byte-identical (tree digests before and after), including
  when the store is pending;
- schema-1-only runs yield no authority claims and nothing `refuted`.

**T** — `registry-selftest.sh` additions: the full request-kind ×
source-state cross-product (`tg:862-869`) as **negative** tests — every
combination refused as a dormant row with no store or anchor mutation.

**G:** `bash skills/implementation-loop/tests/refs-selftest.sh`, plus the full
host replica of `.github/workflows/selftest.yml`.

## 7. What 0a.3 does not do, and who does

Request opening, issuance, cancellation, expiry, redemption, targeted
delivery, the derived-row token source, the approval grant, the activation
epochs, and every positive verification rule arrive with the units A2.1 names
(7, 8, 9, 12).
0a.4 delivers gesture-nonce issuance and the falsifier end to end over the
rows admissible in 0a.

## 8. Round-1 disposition (Codex gpt-6-sol / max, thread `01a0ec41`)

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: a journal claim chooses kind, target, and emitter | **accepted** — no request opens in 0a (A2.1); the activating unit must decide the trigger from independently verifiable state |
| 2 | BLOCKER: delivery is not bound to the target | **accepted** — targeted delivery is unit 7's; issuance waits for it (A2.1) |
| 3 | BLOCKER: the normal wait (`running → blocked`) would cancel the request | **moot in 0a** — no request exists; recorded for the activating unit's derived-cancellation rule |
| 4 | MAJOR: a live pid is not an agent session | **accepted** — agent kinds wait for unit 9's identity handshake (A2.1) |
| 5 | MAJOR: review opening needs a dispatch bound to its attempt | **accepted** — waits for the adapter bindings (A2.1) |
| 6 | MAJOR: review content and reviewer not verified | **moot in 0a** — nothing is verified; the activating unit binds content and reviewer |
| 7 | MAJOR: journal/authority race and redemption re-check | **moot in 0a** — carried to the activating unit |
| 8 | MAJOR: verifier invariants and record shape | **moot in 0a** — request records are invalid in 0a (p2 §7); the activating unit defines them |
| 9 | MAJOR: no positive production sample; racy race tests | **accepted in spirit** — 0a.3 produces no `verified` outcome at all, so there is no untested positive branch; every outcome it produces has a test |
| 10 | MINOR: the map omitted journal references and mis-stated a test | **accepted** — §2 lists every reference with its outcome, unknown kinds fail closed, and each test expectation is stated per outcome |

## 9. Round-2 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: dormant records could become valid retroactively | **accepted** — A2.1's durable activation boundary: `admitted_protocols` in each epoch's introducing record (`store.genesis`, `epoch.rotated`), empty in 0a; a request record is valid only under its own epoch's list; activation is an operator-TTY rotation; 0a.2 carries the field and the refusal |
| 2 | MAJOR: segment discharge row still at unit 3 | **accepted** — A2.1 moves the row and its compound reset to unit 8; the accumulator stays unit 3's |
| 3 | MAJOR: attestation before its source exists | **accepted** — moved to unit 9 |
| 4 | MAJOR: phase gates not reconciled | **accepted** — A2.1 reassigns unit 7's positive redemption tests to unit 8, the falsifier's compound-redemption property to units 8/9/12 (0a keeps every 0a compound), keeps 0a's cross-product negatives (now in 0a.3's T), and replaces 0a.2's §1 allocation and pa §4's upgrade hand-off |
| 5 | MAJOR: `unavailable` does not reject | **accepted** — claim validity and store state are separate dimensions; every 0a authority claim is **rejected** (`rows-dormant`) whatever the store state; tested under every store state |
| 6 | MINOR: map omits `target_containment`, groups failure kinds | **accepted** — the map is keyed by every reference kind plus every evidence field, with `target_containment` listed |
| 7 | MINOR: zero-guard eligibility | **accepted** — eligibility is the constant `false` in 0a; a node with no references tested |

