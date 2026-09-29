# task-graph-v1 — amendment A2 (request rows dormant through 0a; genesis recovery)

**Status: A2.3–A2.4 ACCEPTED** at Codex read-only review round 15 (2026-09-29,
gpt-6-sol / max, thread `01a0ebb0`) together with the 0a.2 specification.
**A2.1 ACCEPTED** at round 4 (thread `01a0ec41`) together with
`plans/task-graph-v1-phase-a-0a3.md`; A2.2 withdrawn. **A2.6 ACCEPTED** at round 3
of the 0a.4 review (thread `01a0ec41`), with `plans/task-graph-v1-phase-a-0a4.md`. Amends `plans/task-graph-v1.md`
(ACCEPTED round 11) as already amended by A1
(`plans/task-graph-v1-amendment-a1.md`, ACCEPTED round 9). Where A2 differs
from either, A2 wins. `tg:NN` and `A1:NN` cite lines.

Specifying sub-units 0a.2 and 0a.3 surfaced these plan-level gaps. None can
be settled inside a sub-unit specification without silently changing an
accepted rule, so they are stated here. A2.3 and A2.4 were reviewed with
0a.2 (which depends on them); A2.1 with 0a.3.

---

## A2.1 Request rows stay dormant through 0a (amends A1.4)

**Accepted text.** A1.4 admits request opening + capability issuance,
cancellation, expiry, and redemption in 0a, with their positive tests in 0a
(`A1:223`); the 0a.1 hand-off asks 0a.3 to verify claimed authority references
(`plans/task-graph-v1-phase-a.md` §4).

**The gap** (0a.3 specification review, round 1). In 0a **no request kind has
a principal the writer can authenticate or a channel to reach it**:

- agent-session kinds (`review`, `triage`, `tg:1034-1035`) need the adapter
  identity handshake that turns a live process into a known session (unit 9,
  `tg:1161-1163`), and `review` needs a dispatch bound to its attempt (the
  adapter bindings, `tg:1220`); a live pid with a matching start token proves
  neither;
- human kinds exist only inside the authenticated console's answer path
  (`tg:1064`, `A1:46-48`; unit 8, `tg:1156-1160`);
- **targeted delivery** bound to the recorded PID and start token
  (`tg:1059-1064`) is unit 7's (`tg:1153-1155`); handing the secret to
  whatever descriptor a caller supplies does not target anyone;
- a journal claim cannot choose the kind, target, or emitter: the journal is
  unauthenticated (`tg:1082-1084`), so a derived opening triggered by a
  journal line would let any journal writer route a capability to its own
  process — the indirect request X7 forbids (`tg:879-880`).

Admitting the rows in 0a would therefore seal capabilities that no principal
can be proven to receive or redeem.

**Amended.** The five request rows (opening + issuance, cancellation in both
branches, expiry, redemption) stay **dormant through 0a**: registered with all
six columns, refused with their distinct errors, covered by the reachability
invariants (0a.2). Each request kind — and each derived row that can arise only
from its redemption — becomes admissible only in the unit that supplies
**all** of its source state, its target principal, and targeted delivery:

| request kinds (and derived rows) | needs | admissible from |
| --- | --- | --- |
| `scope-change`, `approval`, `observation`, `design-decision`, `ceiling`, `safety-boundary` | targeted delivery (unit 7), the console answer path (unit 8) | unit 8 |
| `segment-discharge`, with the **segment discharge** row and its compound `T-segment-reset` | the accumulator (unit 3), delivery (unit 7), the console (unit 8) | unit 8 (the accumulator itself stays unit 3's; A1.4's unit-3 placement of the row is replaced) |
| `review`, `triage` | delivery (unit 7), the agent-session identity handshake and dispatch binding (unit 9) | unit 9 |
| `attestation` | the console (unit 8), and child identity, loss, and reconciliation (unit 9), so that `unknown-outcome` is established independently rather than asserted by the journal | unit 9 |
| `mechanism-closure`, `release-acceptance`, with the mechanism-closure and release-acceptance rows | their states and principals (unit 12) | unit 12 |

**A durable activation boundary.** Admission is decided by the record, never
by the verifier's version, so a record sealed before its kind was admitted can
never become valid later.

- **Epoch introducers.** Every record that introduces an epoch —
  `store.genesis`, `epoch.rotated`, and `store.regenesis` (the first epoch of
  a new generation) — carries `registry_version` (the registry that sealed
  it) and `admitted_protocols` (the request-protocol versions, each with the
  kinds it admits, that records sealed **in that epoch** may use). Both are
  part of the canonical envelope the ceremony displays.
- **A closed transition table.** `ALLOWED[registry_version]` fixes which
  protocols a registry version may list; for Phase A 0a,
  `ALLOWED["tg-v1.0a"] = []`. The writer and the independent verifier refuse
  an introducer whose `registry_version` is unknown to them or lower than its
  predecessor epoch's, or whose list is not a subset of
  `ALLOWED[registry_version]`, or — within a generation — does not include
  every protocol its predecessor listed (lists only grow). So in 0a every
  introducer carries `tg-v1.0a` and the empty list, and a premature listing is
  refused by both, never merely ignored.
- **Request records.** A request record is valid only if its `protocol` is
  listed by the introducer of the epoch it was sealed in and that protocol
  admits its kind; every terminal record (`redeemed`, `cancelled`, `expired`)
  carries its opening's `protocol` and kind unchanged. Because lists only
  grow within a generation, a request opened in one epoch stays answerable
  after a rotation, its terminal record sealed with the new epoch's subkey
  (the old epoch's key is verify-only, A1.7); linked re-genesis makes every
  open request historical, like every other authorization of the old store
  (A1.3).
- **Activation** of a unit's kinds is therefore an operator-TTY epoch
  rotation by a writer whose registry version's `ALLOWED` entry lists the new
  protocol; records of earlier epochs, and records of kinds a protocol does
  not list, stay invalid under every later verifier.

**Gates reassigned, so none is lost.**
- **Unit 7** delivers the closed policy lattice, the `execution-disabled`
  marking, the targeted delivery channel bound to PID and start token, and
  the transactional redemption machinery, each with its own tests; with no
  admissible kind yet, its end-to-end positive redemption tests move to the
  first activating unit (unit 8).
- **The named falsifier** (`tg:1397-1407`) runs in 0a over every compound
  0a admits (epoch revocation with quarantine, delimiter completion with
  anchor replay-forward) and over the reachability invariants; its
  compound-**redemption** crash property moves to units 8 (answer; segment
  reset), 9 (review, triage, attestation), and 12 (closure, acceptance), each
  for its own kinds.
- **0a keeps** every request row's refusal, the full kind × source-state
  cross-product as **negative** tests (every combination refused while
  dormant), and 0a.3's reference verification. Each activating unit adds its
  kinds' positive half of the cross-product (`tg:869`) and the positive
  verification rules for the records it admits.
- **Replaced allocations:** 0a.2's §1 row for 0a.3 ("request opening +
  capability issuance …, those five") becomes "verification of claimed
  authority references; no row admitted", and the 0a.1 hand-off's "upgrading
  those guards from `claimed` to `verified`" (pa §4) moves to the activating
  units.

**Carried forward so they cannot be dropped.** The activating unit must also
specify how the **derived** request rows (opening, derived cancellation,
expiry) obtain transaction tokens — A1.5 names no source for them — with a
trigger decided from independently verifiable state, never from a journal
claim alone; that a request stays valid while its node waits in `blocked`
for it (`tg:291`); its `ALLOWED` entry and activation rotation, tested for
rotation between opening and each terminal outcome; and the binding of reviewed content and reviewer identity
into the request and its answer (`tg:183-198`, `tg:222-224`). The approval
grant (`tg:529-548`) is the redeemed answer of an `approval` request and
arrives with unit 8; `approval.consume` stays refused (A1.9).

**What 0a keeps.** Because every request row is dormant, **no journaled
answer, request, or expiry can be backed by a redeemed capability in 0a**, so
0a.3 marks each such claim **rejected** — whatever the store's availability,
which it reports separately. That enforces "a response event without a
redeemed capability is **rejected**, not merely unattributed"
(`tg:1071-1072`) from 0a on; no guard is upgraded until an activating unit
adds positive verification rules with positive tests.

## A2.2 (withdrawn)

Per-kind admissibility with `review` and `triage` in 0a was withdrawn at the
0a.3 review's round 1 and folded into A2.1.

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

## A2.6 Gesture-nonce issuance stays dormant through 0a (amends A1.4)

(A2.5 was a withdrawn draft during the 0a.2 review; the number is not reused.)

**Accepted text.** A1.3 adds gesture-nonce issuance as an external row whose
principal is the console session through "one typed display API" (`A1:177`),
and A1.4 admits the A1.3 rows in 0a with positive tests in 0a (`A1:223`);
the 0a.2 specification leaves it dormant "until 0a.4".

**The gap** (0a.4 preparation, the same test A2.1 applied to requests):

- **no consumer in 0a** — a nonce is consumed by enrollment
  (`tg:374-383`, `tg:816`; unit 4) and by approval consumption
  (`tg:541-548`), which stays refused through Phase A (A1.9); no other
  console-gesture row names a nonce as evidence;
- **no closed artifact set** — the artifacts a nonce is issued for (catalog
  entries, registrations, envelopes) do not exist in 0a, so a display API
  that seals any caller-supplied digest would be the generic sealing hatch
  the falsifier forbids (`tg:1405-1406`);
- **no authenticable principal or channel** — the console's handshake
  (`plans/loop-console-v1.md`, D7) proves only possession of the token the
  console printed, the writer cannot authenticate a caller claiming to be the
  console, and the authenticated console-to-writer path is units 7–8's
  (`tg:1153-1160`).

**Amended.** Gesture-nonce issuance stays **dormant through 0a**, refused
with its distinct error, and becomes admissible in **unit 4** with its first
consumer (enrollment), on the console-to-writer channel below, which must
also specify: the closed artifact types, the expiry clock, the `execution-disabled` domain (`tg:1075-1078`), how a spent
nonce is recorded within the closed type list, and positive tests. **One activation boundary for every row.** A2.1's rule is generalized: a
record of **any** type is valid only if its row is admitted by the registry
version of its epoch's introducer. `ALLOWED[registry_version]` therefore
names both the admitted request protocols and the admitted record types; for
0a, `ALLOWED["tg-v1.0a"]` admits exactly the record types of the rows 0a
admits — `store.genesis`, `epoch.rotated`, `epoch.revoked`, and
`store.regenesis` — and no request protocol. Admitted **type sets only grow**,
like protocol lists: the writer and the verifier refuse an introducer whose
registry version's type set does not contain every type its predecessor
epoch's version admitted (within a generation), so no later version can
disable a row — `epoch.revoked` included — that an earlier one admitted; unit
2 tests the rejection of a shrinking set. The writer and the independent
verifier refuse, as invalid (quarantine, A1.6), a `nonce.issued` record and a
record of every other later row's type (`repo.registered`, `repo.rebound`,
`exec-root.registered`, `standing.granted`, `standing.revoked`,
`entry.enrolled`, `entry.revoked`, `platform.designated`, and the request
types) in any 0a epoch; each activating unit (2, 3, 4, 8, 9, 12) extends
`ALLOWED` with its registry version.

**The console-to-writer channel comes first.** Every console-gesture row —
repository registration and rebind (unit 2), standing authorization and
revocation (unit 3), enrollment and its revocation and nonce issuance
(unit 4), and the human request kinds (unit 8) — needs the writer to
authenticate that a call comes from the console session, which the D7
handshake does not do (it authenticates a browser to the console; the
console's current writes pass a claimed `--set-by console`). So the **first
unit that activates any console-gesture row (unit 2 in `tg`'s order) must
first deliver and test an authenticated console-to-writer channel**, and
units 3, 4, 7, and 8 reuse it; if unit 2 cannot, its gesture rows and their
positive tests move until the channel exists. Nonce issuance activates at
unit 4 only with both its consumer and that channel present.

**Order of validation.** A record's type admission under its epoch's
introducer is checked **before** its body schema, with a distinct result
(`type-not-admitted`), so a refusal of a not-yet-admitted type is proved to
come from the boundary and not from a missing body schema. The first unit to
admit a second type set (unit 2) carries a corpus mixing epochs of both
registry versions, in which the verifier accepts each record only under its
own epoch's set.

**0a.4** therefore delivers the falsifier end to end over the rows 0a admits
(A2.1's reassignment of the compound-redemption property stands).

## Open questions for review

1. Is any request kind placed in the wrong activating unit?
2. Is anything in the 0a.1 hand-off (`plans/task-graph-v1-phase-a.md` §4)
   lost by keeping the request rows dormant through 0a?
