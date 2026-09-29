# task-graph-v1 — amendment A2 (derived request rows, per-kind admissibility, genesis recovery)

**Status: A2.3–A2.4 ACCEPTED** at Codex read-only review round 15 (2026-09-29,
gpt-6-sol / max, thread `01a0ebb0`) together with the 0a.2 specification.
**A2.1–A2.2 DRAFT** — for review together with
`plans/task-graph-v1-phase-a-0a3.md`. Amends `plans/task-graph-v1.md`
(ACCEPTED round 11) as already amended by A1
(`plans/task-graph-v1-amendment-a1.md`, ACCEPTED round 9). Where A2 differs
from either, A2 wins. `tg:NN` and `A1:NN` cite lines.

Specifying sub-units 0a.2 and 0a.3 surfaced four plan-level gaps. None can
be settled inside a sub-unit specification without silently changing an
accepted rule, so they are stated here. A2.3 and A2.4 are reviewed with 0a.2
(which depends on them); A2.1 and A2.2 with 0a.3.

---

## A2.1 The derivation routine is a token source (amends A1.5)

**Accepted text.** Tokens have exactly three sources: an external row's
authenticated principal, the recovery routine (for the four recovery rows), and
a compound parent (for the child rows it names) (`A1:244-251`). Request
opening, derived request cancellation, and request expiry are **derived** rows
(`tg:811-813`) with no external entry point (`tg:901`), and derived operations
may never be requested directly (X7, `tg:879-880`).

**The gap.** None of the three sources can mint a token for those three rows,
so as written they could never be admitted — or an implementer would invent a
fourth source, which is exactly the generic hatch the falsifier forbids
(`tg:1405-1406`).

**Amended.** A fourth source, the **derivation routine**, mints tokens for
exactly three rows: request opening (with its capability issuance, A1.9),
derived request cancellation, and request expiry. It mirrors the recovery
routine (`A1:255-258`):

- Its only input is **observed state**: the journal, reduced by the 0a.1
  reducer, and the authority store itself. No caller supplies a kind, subject,
  target, scope, expiry, or binding; the routine takes none as a parameter.
- **Opening's trigger** is the coordinator's "emit requests" (`tg:724-725`)
  made concrete: a journal event `request.emitted` (a **claim**, like every
  journal event) naming the kind, subject, and proposed target. The reducer
  folds it into the source state; the routine opens the request only if
  `V-request-open` accepts that source state as reduced by the routine itself.
  An emission is a claim that a request is wanted, never a request of the
  writer: the writer is not asked, it observes.
- A derivation token binds the digest of the observed state that triggered
  the row (for opening and derived cancellation, the reduced source state and
  the journal position read; for expiry, the request's sealed records and the
  clock reading) and is refused if the row's validator, re-run under the
  writer lock at commit, observes a different state.
- The routine has one external entry point (`loop-authority derive`), exactly
  as recovery has `loop-authority recover`; neither accepts row-selecting
  parameters. The registry invariant "derived-only rows have no external
  entry point" is read as: no entry point that selects the row or supplies
  its evidence.
- Tests (added to A1.5's list): each derivation-sourced row invoked without a
  derivation token, with a recovery or external token, or with a derivation
  token bound to a different observed state, is refused; `derive` has no
  parameter that names a kind, subject, target, request id, or expiry.

**What this does not change.** The console-gesture branch of request
cancellation (`tg:812`) keeps an external, authenticated-human principal.
Capability redemption stays the sole external entry point for answers
(`tg:841-842`).

## A2.2 A request kind is admissible only when its source state and target principal exist (amends A1.4)

**Accepted text.** A1.4 made request opening, issuance, cancellation, expiry,
and redemption admissible in 0a with positive tests in 0a (`A1:223`), while
the compound consequence rows stay dormant until units 3 and 12
(`A1:225-227`).

**The gap.** A1.4 grants admissibility per **row**, but whether a request can
be opened and answered depends on its **kind**: each kind has a source state
(`tg:862-867`) and a target principal (`tg:1032-1045`), and several of those
do not exist in 0a. Human capabilities exist only inside the authenticated
console (`tg:1064`, `A1:46-48`), whose answer path is unit 8
(`tg:1156-1160`); the mechanism, accumulator, and candidate-release states are
units 3 and 12. Opening such a request in 0a would seal an artifact no
principal can ever answer — or tempt an implementer to let some non-console
process answer as the human.

**Amended.** The five request rows stay admissible from 0a, and each **request
kind** is additionally admissible only once both its source-state predicate
and its target principal exist. Until then `V-request-open` refuses that kind
with a distinct error and no store or anchor mutation; nothing of that kind is
ever sealed.

| request kinds | source state | target principal | kind admissible from | positive tests land in |
| --- | --- | --- | --- | --- |
| `review`, `triage` | node state (0a.1 reducer) | agent session (start token, A1.8) | 0a (0a.3) | 0a.3 |
| `scope-change`, `approval`, `attestation`, `observation`, `design-decision`, `ceiling`, `safety-boundary` | node state | the authenticated console | unit 8 | unit 8 |
| `segment-discharge` | accumulator state (unit 3) | the authenticated console | unit 8 (after unit 3) | unit 8 |
| `mechanism-closure` | mechanism state | the independent verifier session | unit 12 | unit 12 |
| `release-acceptance` | candidate-release state | a separately authenticated human or independent reviewer | unit 12 | unit 12 |

**Consequences carried forward.**
- The full kind × source-state cross-product test (`tg:869`) runs in 0a.3 for
  every **negative** combination and for the positive combinations of the
  admissible kinds; each activating unit adds its kinds' positive half.
- The falsifier's compound-redemption crash property (`tg:1400-1403`) is
  exercised in 0a.3 on the only compound 0a can seal — the answer with its
  authority-head advance — and on the structural rule that a consequence
  exists only nested in its redemption frame; units 8 and 12 repeat it with
  real consequences.
- The approval grant (`tg:529-548`) is the redeemed answer of an `approval`
  request; it cannot exist before unit 8, and `approval.consume` stays refused
  (A1.9).
- The console-gesture branch of request cancellation (`tg:812`) has the same
  missing principal: it is refused with a distinct error until unit 8, while
  the derived branch is admissible from 0a.

## A2.3 Genesis has a crash protocol and a bootstrap recovery rule (amends A1.2, A1.3)

**Accepted text.** Authority genesis is triggered "on an **absent** store and a
remote whose anchor ref is absent" and produces `T-store-created` + anchor
generation 1 (`A1:176`). A1.3 gives linked re-genesis an explicit crash
protocol (`A1:187-200`), but genesis none; A1.2's recovery table
(`A1:128-160`) presupposes a verified remote pointer `R`, which cannot exist
before the first push.

**The gap.** A genesis that crashes between its frame's `fsync` and the
readback has no recovery row: the table needs `R.active = ptr(L − 1)`, and for
`L = 1` there is no pointer at all. Treating the absent ref as a sentinel
would let an unsigned absence stand in for a verified pointer, and abandoning
such a genesis would hide a push that succeeded and was then deleted.

**Amended.**

- A store is **absent** exactly when the local `active` marker does not exist.
- **Genesis steps**, each durable before the next: (1) create the new store's
  directory and key directory (unpublished; nothing reads them); (2) seal the
  genesis record and its pointer and build the deterministic commit, then
  write **`genesis.intent`** — complete, in one atomic write — holding
  exactly A1.6's intent fields for frame 1 (`seq: 1`, offset, length, frame
  digest, `expected_parent: null`, `anchor_json`, `anchor_commit`) plus the
  `store_id`, `key_dir`, the pinned remote, `frame_length`, and **the exact
  frame bytes** (`frame_b64`), so a torn prefix can be compared byte for byte.
  `length` and `digest` keep A1.6's meaning — the payload length, and sha256
  over the header without its digest field followed by the payload
  (`A1:269-271`); `frame_length` is the whole frame's byte count (header line
  with its digest, payload, final delimiter), and `frame_b64` encodes exactly
  those bytes; (3) append and `fsync` frame 1;
  (4) push the pre-signed commit to the absent ref; (5) read it back by
  content; (6a) write `active`; (6b) remove `genesis.intent`.
- **Bootstrap recovery**, resolved first whenever `genesis.intent` exists
  (like A1.2 recovery step 1). Step 6 is two durable cuts — (6a) write
  `active`, (6b) remove the intent — so `active` is part of the observed
  state. **Local state is classified before the remote is read**, as A1.2
  validates the log first. Frame 1 is classified against the intent's
  offset, length, and digest, as A1.6 classifies a tail:

  - **none** — the log is empty;
  - **torn** — the log is a strict prefix of the intent's frame bytes;
  - **unterminated** — the log equals the intent's frame bytes minus only the
    final delimiter, and the header and payload validate;
  - **valid** — the log equals the intent's frame bytes exactly, ending at
    end of file, and the record validates;
  - **nonconforming** — anything else: a complete frame that fails validation
    or differs from the intent, a short tail that is not a prefix of the
    intent's bytes, a wrong length, or any byte after the frame.

  The intent is **valid** only if it parses under its exact schema; its
  `frame_b64` decodes to exactly `frame_length` bytes forming one complete
  A1.6 frame whose header carries `seq` 1, the intent's `length`, and the
  intent's `digest`, and whose recomputed digest (header without the digest
  field, then the payload) equals it;
  those bytes parse as one complete frame holding a `store.genesis` record
  whose seal and subkey certificate verify under the root that record
  introduces, for the intent's `store_id` and `key_dir`; `anchor_json` is
  exactly the pointer for that record (generation 1, `seq` 1,
  `prev_generation: null`) and its signature verifies under that root; and
  the commit rebuilt from `anchor_json` with no parent (A1.6's deterministic
  construction) is exactly `anchor_commit`. Any failure is row 1.

  Rows are tried in order; the first match applies:

  | # | intent / `active` | frame 1 | remote | action |
  | --- | --- | --- | --- | --- |
  | 1 | intent **invalid** (below) | any | — | **fail closed** (`genesis-invalid`): no mutation |
  | 2 | `active` **present but not exactly** `{store_id, generation: 1}` of the intent's store — another store, malformed, or unreadable | any | — | **fail closed** (`anchor-mismatch`): no mutation |
  | 3 | `active` absent or the intent's store | nonconforming | — | **quarantine** (A1.6) of the intent-named store |
  | 4 | as row 3 | none, torn, unterminated, or valid | unreachable | **pending**: no mutation, no token; retried when reachable |
  | 5 | `active` = the intent's store | any | ref absent | **quarantine**: the readback had verified the push before 6a, so an absent ref is a rollback of the remote |
  | 6 | `active` absent | none or torn | ref absent | **abandon**: discard the intent-named directory, remove the intent |
  | 7 | `active` absent | unterminated | ref absent | **pending**; validate, then **delimiter completion + anchor replay-forward** (A1.6's compound) of the intent's exact commit; then steps 5–6 |
  | 8 | `active` absent | valid | ref absent | **pending**; **anchor replay-forward** of the intent's exact commit — the absent ref plays `ptr(L − 1)` for `L = 1` **only** in rows 7–8 — then steps 5–6 |
  | 9 | `active` absent or the intent's store | valid | exactly the intent's `anchor_commit`, whose `anchor.json` is byte-equal to the intent's and verifies under the root introduced by that store's genesis record | **complete**: step 5, then 6a if `active` is absent, then 6b |
  | 10 | any | none, torn, or unterminated | the intent's exact commit | **quarantine**: the remote holds a commit for a frame that is not durable and complete locally (A1.6's remote-new last-byte state; A1.2's log rollback) |
  | 11 | any | any | anything else (another commit, store, or generation; a bad signature or chain) | **quarantine** (A1.2) |

  Quarantine here is A1.3's recovery-derived store quarantine, its marker
  written in the intent-named store. With `active` absent that store was
  never anchored locally and `status` reports `genesis-quarantined`; genesis
  stays refused while the intent remains.
- **Bootstrap failures are terminal.** `genesis-invalid` (row 1),
  `anchor-mismatch` (row 2), and `genesis-quarantined` (rows 3, 10, 11 with
  `active` absent) are **terminal for this authority directory**: from local
  evidence alone the loop cannot prove the ceremony stopped before its push
  (a ref can be deleted and an intent corrupted after a successful push), so
  no row retires or resets them, `status` reports the state and the evidence
  that caused it, and nothing in the loop describes a manual change to the
  directory as recovery. A later amendment may add a lineage-preserving exit.
  So a
  genesis whose frame is durable and complete is **never** abandoned: a ref
  deleted before 6a is re-pushed with the same bytes; deleted after 6a, it is
  quarantine.
- **Once `active` exists**, an absent ref is a rollback of the remote and is
  **quarantine**, like `R.active.seq < L − 1` (`A1:150`).
- Genesis refuses when `active`, `genesis.intent`, or `regenesis.intent`
  exists, or the remote ref exists.

## A2.4 Recovery may finish or abandon a ceremony, only on exact state (amends A1.5)

**Accepted text.** The recovery routine mints tokens for exactly four recovery
rows (`A1:246-248`), yet A1.3's re-genesis protocol has recovery complete
steps 4–5 or discard the new directory (`A1:193-196`), and A2.3 gives genesis
the same shape. Those mutations belong to the ceremony rows, so as written
they are sinks without an authorizing token.

**Amended.** The recovery routine also mints a token for a **ceremony row**
(authority genesis, linked re-genesis) — the ceremony's own authorization,
recorded in the intent it wrote under its operator-TTY principal; recovery
only finishes it. The token is minted **only after** the routine has proved
the exact state, and binds the digest of that state:

- **completion**: the remote ref's commit equals the intent's exact new
  `anchor_commit`, the fetched `anchor.json` is byte-equal to the intent's,
  and it verifies (A1.2 recovery step 3's prerequisites, against the roots the
  pointer requires); for genesis also A2.3 row 9's `active` (absent or
  exactly the intent's store) and frame (valid) conditions;
- **abandonment**: the remote shows exactly the pre-ceremony state the intent
  recorded — for genesis, A2.3 row 6 exactly (reachable, ref absent, `active`
  absent, frame 1 none or torn); for linked re-genesis, a ref whose commit
  equals the old-generation commit that `regenesis.intent` now also records
  (added to A1.3 step 1);
- no token at all while the remote is unreachable (A2.3 row 4), and none for
  rows 1–2, which mutate nothing.

A signed, chain-valid pointer that is not exactly the intent's — an unrelated
pointer, or an old-generation pointer advanced past the recorded one — mints
nothing and fails closed.

The token authorizes **only** that protocol's completion or abandonment sinks
— the active marker, the old store's archive move and read-only change,
intent removal, and discarding exactly the intent-named unpublished directory
— never a key, a seal, a frame, or a push (A2.3's re-push is the ordinary
anchor replay-forward row with its own recovery token).

**Tests** (added to A1.5's list): a ceremony token on any other sink, bound to
another observed state, or for another directory, refused; no token minted
for a valid-but-unrelated pointer or an advanced old-generation pointer;
completion with the pre-ceremony ref, and abandonment after the commit point,
refused; a genesis ref deleted after a successful push and a crash is
re-pushed with identical bytes; every A2.3 row at every genesis cut,
including: the last-byte crash with an absent ref (row 7) and with the exact
ref (row 10); a complete invalid frame, a short tail that is not a prefix,
a wrong length, and trailing bytes after a valid frame (row 3), each also
with the remote unreachable and with `active` exact and the ref absent;
an unparsable intent and a wrong `active`, each with the remote unreachable
(rows 1–2), a parseable intent with each semantic defect — wrong digest,
frame bytes that are not a genesis record, a bad seal or certificate, a
pointer that is not that record's or is badly signed, a rebuilt commit that
differs — with no frame and an absent ref (row 1, never row 6), a genuine
crash prefix of frame 1 (row 6) versus an altered prefix of the same length
(row 3), and a malformed, unreadable, or other-store `active` with the remote
reachable and unreachable (row 2); the 6a–6b cut with the exact ref (row 9) and with the ref
deleted (row 5); and an unreachable remote at each clean cut for the writer
and the verifier (row 4).

## Open questions for review

1. Is A2.1's reading of "no external entry point" (no entry point that
   selects the row or supplies its evidence) sound, given that recovery
   already has one?
2. Is the `request.emitted` journal claim the right trigger, or should the
   trigger be a pure function of node state with no emission at all (which
   would require the demand rules of unit 10 now)?
3. Is any kind's placement in the A2.2 table wrong?
