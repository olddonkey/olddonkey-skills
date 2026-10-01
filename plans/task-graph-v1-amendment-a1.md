# task-graph-v1 — amendment A1 (trusted writer)

**Status: ACCEPTED** at Codex read-only review round 9 (2026-09-29, gpt-6-sol /
max, thread `01a0ebb0`), findings per round 8 → 4 → 3 → 3 → 2 → 1 → 1 → 1 → 0.
A1 **amends** `plans/task-graph-v1.md` (ACCEPTED, round 11): where they
differ, A1 wins. The acceptance covers the plan contract, including the
user's stated operator-principal weakening (A1.1) and the deferred positive
tests (A1.4); it does not assert that any writer code exists.

**Why an amendment.** The Phase A kickoff (`plans/task-graph-v1-phase-a.md`,
round 1) found that unit 0a's writer cannot be specified from task-graph-v1 as
written without either re-deciding accepted rules or leaving them
unimplementable. An operation absent from the admission matrix is inadmissible
(`tg:915`), so adding rows or changing how rows become admissible is a change
to the accepted plan, not a kickoff choice. A1 makes those changes explicitly
and nothing else. Two of them are the user's decisions (2026-09-28), recorded
as such.

`tg:NN` cites `plans/task-graph-v1.md`.

---

## A1.1 The operator principal is a terminal session (user decision — a weakening)

**Accepted text.** Genesis's first trusted party is "an authenticated local
operator — a human, not a process" (`tg:934`); platform designation, epoch
rotation, and epoch revocation are authorized by that operator (`tg:825-829`).

**Amended.** The operator principal is an **operator-TTY session**: a ceremony
command whose stdin and stdout are a terminal, which prints the canonical
envelope and a fresh random challenge and proceeds only when the challenge is
typed back. The sealed record carries `principal = {kind: operator-tty, tty,
session start token (A1.8)}`.

**What this gives up, stated plainly.** Any process running as the user can
allocate a pseudo-terminal and complete the challenge. That includes the
implementers this loop dispatches. So an operator ceremony proves "a session
with a terminal performed this", **not** "a human approved this". The user
chose this over a hardware key (FIDO2) and Touch ID on 2026-09-28, preferring
practicality. The plan's honest bound already excludes same-uid attackers
(`tg:951-956`); A1.1 makes explicit that a dispatched agent is one.

**Consequences carried forward.**
- Nothing sealed by an operator-TTY ceremony may be described as human
  approval in any surface (card, console, canvas, PR text).
- Console gestures (`tg:816-822`) are unchanged: they remain the D7-handshake
  console session, where the human capability exists only in the console
  (`tg:1063-1064`).
- Release acceptance keeps its separate human principal requirement
  (`tg:1045`); A1.1 does not relax it, and unit 12 must specify it.
- A future amendment may add a hardware-presence operator (FIDO2) as a
  stronger principal. It would count only with a key created **without**
  `no-touch-required` (and preferably with `verify-required`), verification
  that **enforces** the user-presence (or user-verification) flag, and a
  signature over the displayed ceremony envelope; records would carry which
  principal authorized them, and the weaker one could then be retired.

## A1.2 The anchor is a signed pointer in a private git remote (user decision)

**Accepted text.** "An independently protected anchor store" (`tg:937`) and a
head that detects "the ledger *and* its head being restored to an older,
perfectly valid snapshot" (`tg:967-970`), with rollback a fail-closed error.

**Amended.** The anchor is **one** ref, `refs/olddonkey-loop/anchor`, in a
private git remote the user controls, named at authority genesis. Each commit
on that ref (fast-forward only) carries one file, `anchor.json`:

```
{ "active": { "store_id", "generation", "genesis_digest",
              "seq", "record_digest", "epoch", "key_id" },
  "prev_generation": { "store_id", "generation", "last_seq",
                       "last_record_digest" } | null,
  "sig": <seal by the ACTIVE epoch root of the store named in "active"> }
```

**Who signs a pointer.** Always the active epoch root of the store the pointer
names in `active`, and **at the time the pointer is created**: the pointer
(`anchor.json` with its `sig`) is built and signed inside the writer
transaction, before the frame's `fsync`, and stored with the write intent
(A1.6). Anchor replay-forward pushes those pre-signed bytes; **nothing is ever
signed again during recovery**.

**Revoking the active epoch.** The revocation record and its pointer are the
revoked root's **last** acts, signed while it is still active; the compound
`T-epoch-revoked + T-quarantined` commits when that pointer is anchored. A
signature made while a key was active stays verifiable as **historical
evidence**, and the revocation pointer only ever **removes** authority, so
relying on it after revocation grants nothing. After it, the store is
quarantined, no further pointer is signed by that store, and the next pointer
is the new generation's, signed by the new root (linked re-genesis). A crash
between the revocation frame's `fsync` and its readback leaves the store
**pending** — no current authorization at all — and replay-forward pushes the
pre-signed revocation pointer; there is no unsigned fallback and no
re-signing with the revoked key. For generation 1, that root is introduced by the authority
genesis ceremony's record; for a new generation, by the linked re-genesis
ceremony's record in the **new** store (A1.3), which the operator-TTY session
authorizes. The operator-TTY principal is evidence of a session, not a
signing key, so it never signs a pointer itself. The link between generations
is `prev_generation`, which names the old store's last valid pointer — a
pointer signed by the **old** root and verifiable only as **history**. No
current authority ever rests on a revoked or verify-only key.

`generation` starts at 1 and only increases; a linked re-genesis (A1.3)
advances it on the **same** ref. The ref's commit history is the generation
chain. There is no per-store ref, so restoring an older store generation
locally cannot match the anchor (round-1 finding B2).

**Write protocol** (lag is fixed at 0): under the writer lock, (1) write the
durable write intent (A1.6); (2) append and `fsync` the frame; (3) push the
anchor commit naming the new `seq` (fast-forward from the previous anchor);
(4) read the remote ref back and require it to equal what was pushed —
**by content**: fetch the commit it names, check its parent, read
`anchor.json` from its tree, and verify those bytes and their signature,
never the ref's object id alone;
(5) remove the intent and update the local cursor file (a recovery hint, never
authority). The append returns success only after (4).

**States and recovery.** On every writer start and before every append, under
the lock, in this order:

1. **A `regenesis.intent` is resolved first** (A1.3's crash protocol), before
   the ordinary comparison, so a re-genesis interrupted after its
   generation-changing push is completed rather than quarantined — but only
   **after** the remote anchor has passed step 3's prerequisites (signature
   and chain), checked against both the old store's and the new store's
   roots as the pointer requires. An anchor failing them leaves both local
   stores untouched and quarantines.
2. Parse and validate the log to its last complete valid frame `L` (A1.6). Let
   `ptr(n)` be the full signed pointer frame `n` would anchor: `{store_id,
   generation, genesis_digest, seq, record_digest, epoch, key_id}`.
3. Read the remote anchor `R`. **Before any row of the table applies**, `R`
   must pass: `R.sig` verifies under the active epoch root of the store
   `R.active` names — for a pointer of the local store's own generation, the
   root its verified history designates; for a generation-changing pointer,
   the **new** generation's root, and **separately** the new store's linked
   re-genesis ceremony record must verify and must be the record that
   introduced that root; the ref's commit chain is consistent —
   within a generation each commit's `active.seq` increases by one from its
   parent's, and a generation change sets `prev_generation` to exactly its
   parent's `active`. A pointer failing either is **quarantine**. Then compare
   **the complete signed pointer**, not the sequence number alone:

| observed | meaning | action |
| --- | --- | --- |
| `R.active` has another `store_id` or `generation` (after step 1) | a restored older generation, or a foreign store | **quarantine** |
| `R.active = ptr(L)` | committed | **recovery tidy** (A1.3): a residual write intent for `L` is cleared only if its offset, length, and digest match frame `L` exactly (otherwise **quarantine**); an intent for `L + 1` at exactly the end of the log with no bytes after it is cleared (crash after step 1 only); a cursor that disagrees is reset |
| `R.active = ptr(L − 1)` **and** a durable write intent matches frame `L` | the last append was fsynced but not anchored | the store is **pending**; **anchor replay-forward** (A1.3) re-validates frame `L` (digest, signature, chain, admission) and pushes it |
| `R.active = ptr(L − 1)` **without** a matching intent | a one-step rollback of the remote, or a planted frame | **quarantine** |
| `R.active.seq = L` but any other field differs | a fork at the same sequence | **quarantine** |
| `R.active.seq > L`, or `< L − 1` | rollback of the log, or of the remote | **quarantine** |
| a write intent naming any sequence other than `L` or `L + 1`, or an intent for `L + 1` with bytes after the end of frame `L` that do not form a torn or unterminated frame | an intent that no protocol step leaves | **quarantine** |
| remote unreachable | unknown | the store is **pending** |

**While the store is pending, it gives no current authorization at all** — not
from frame `L`, and not from any earlier anchored record either, because `L`
may revoke something earlier (round-1 finding B1). Readers and the verifier
report `pending`; the only admissible row is anchor replay-forward. A
cursor file that disagrees with `L` or `R` is ignored for every decision and
reset by recovery tidy (A1.3); it never decides anything.

**Honest bound.** The user controls the remote and can rewrite it. The writer
refuses a non-fast-forward anchor and branch protection on the ref is
recommended, but a user who rewrites both the local store and the remote
defeats the anchor — the same same-uid bound as everything else.

**Tests** use a local bare repository as the remote (`file://`); CI never
touches the network. Crash injection covers each cut between steps 1–5.

## A1.3 Seven added operations

Added to the admission matrix (`tg:809-829`) with all six columns of
`tg:801-804`; exclusion identifiers per A1.10.

| operation | trigger | principal / source | required evidence | validator | exclusions | transition |
| --- | --- | --- | --- | --- | --- | --- |
| **authority genesis** | operator ceremony on an **absent** store and a remote whose anchor ref is absent | operator-TTY (A1.1) | store id, remote URL, first epoch root public key, per-type subkey certificates (A1.7) | `V-genesis` | X6 | `T-store-created` + anchor generation 1 |
| **gesture-nonce issuance** | the console asks to display an artifact for a gesture | **console session** (external; one typed display API) | artifact digest, session id, expiry | `V-nonce-issue` | none | `T-nonce-issued` (only the hash is stored) |
| **torn-frame truncation** | recovery observes a torn final frame (A1.6) | derived — recovery source | the write intent and the frame's byte range | `V-torn` | X7 | `T-torn-truncated` — the only discard (`tg:945`) |
| **anchor replay-forward** | recovery observes `R.active = ptr(L − 1)` **and** a durable write intent matching frame `L` (A1.2) | derived — recovery source | the validated frame `L` and its intent | `V-replay` | X7 | `T-anchor-advanced`; compound `T-delimiter-completed` + `T-anchor-advanced` when frame `L` was complete but unterminated (A1.6) |
| **recovery tidy** | recovery observes `R.active = ptr(L)` with any of: a residual intent for `L` matching frame `L` exactly, an intent for `L + 1` at exactly the end of the log with no bytes after it, or a cursor that disagrees with `L` | derived — recovery source | the observed intent (if any), cursor, `L`, `R` | `V-tidy` | X7 | `T-intent-cleared` (when an intent is present) and/or `T-cursor-reset` |
| **store quarantine** | recovery observes a complete-but-invalid frame, a record naming a missing key file, or any quarantine row of the A1.2 table; **or** revocation of the active epoch (compound with `T-epoch-revoked`) | derived — recovery source, or the revocation transaction | the offending position and the rule it failed | `V-quarantine` | X7 | `T-quarantined` |
| **linked re-genesis** | operator ceremony on a quarantined store | operator-TTY | the quarantined store's id, generation, last valid seq and digest, archive location, new genesis evidence | `V-regenesis` | X6 | the crash protocol below |

**Quarantine** refuses every row except linked re-genesis, and read-only
verification keeps working.

**Linked re-genesis crash protocol.** Steps, each durable before the next:
(1) write `regenesis.intent` naming the old store, its generation and last
valid record, the new store id, and the archive path; (2) create the new store
directory with its genesis record — **inactive**; (3) push the anchor commit
that advances `generation` and sets `prev_generation` to the old store — **the
commit point**; (4) move the old store to the archive, read-only; (5) mark the
new store active locally and remove the intent. Recovery with an intent
present: if the remote still names the old generation, the new directory is
discarded and the old store stays quarantined; if it names the new
generation, steps 4–5 are completed. At every cut, **nothing authorizes**
until the remote and the local store agree on the new generation. Every
authorization of the old store — receipts, grants, capabilities, enrollments,
registrations — is historical evidence only and must be re-established; the
archive stays verifiable through `prev_generation`.

**Key establishment after revocation** is linked re-genesis: revoking the
active epoch is the compound `T-epoch-revoked + T-quarantined`, so no record is
ever signed by a revoked or verify-only key.

## A1.4 Rows become admissible only when their domain predicate exists (a second change)

**Accepted text.** 0a asserts that "every validator, exclusion, and transition
is exercised by both positive and negative tests" (`tg:902-903`), and all
nineteen rows are 0a's (`tg:1118-1132`).

**Amended — and this changes an accepted obligation, stated as such.** Each row
carries an **admissibility** flag and is admissible only once the unit that
implements its complete domain predicate has landed. Until then it is
**dormant**: registered with all six columns, covered by the reachability
invariants, and refused on every use with a distinct error. **Unit 0a still
runs the negative tests for every dormant row** (refusal, and no store or
anchor mutation); the **positive** tests move to the activating unit, listed
here so none is lost:

| rows | admissible from | positive tests land in |
| --- | --- | --- |
| request opening + capability issuance, cancellation, expiry, redemption, authority-head advance, the seven A1.3 rows, epoch rotation, epoch revocation | 0a | 0a |
| repository registration, rebind, execution-root registration | unit 2 | unit 2 |
| standing authorization, standing revocation, segment discharge | unit 3 | unit 3 |
| enrollment, enrollment revocation | unit 4 | unit 4 |
| mechanism closure, acceptance-platform designation, release acceptance | unit 12 | unit 12 |

Nothing is ever sealed under a validator that a later unit could not retract.

## A1.5 Transaction tokens on every sink

**Accepted text.** Every mutation sink is reachable only through an admitted
row; derived rows have no external entry point (`tg:894-903`).

**Amended mechanism.**

- **Sinks** — every one of these requires an open token: frame append,
  delimiter completion, write intent create/remove, cursor write, key file create/rename, truncation,
  quarantine marker, nonce-hash store, `regenesis.intent` create/remove, new
  store directory creation, the new store's active marker, the old store's
  archive move and its read-only permission change, and the remote anchor
  push.
- **Tokens** are created only by `store.begin(row, source)`, which is not
  exported: an external row's typed API calls it with the authenticated
  principal as `source`; the recovery routine calls it with the observed
  recovery state as `source` for the four recovery rows (truncation,
  quarantine, anchor replay-forward, recovery tidy); a compound
  transition's parent token authorizes exactly the child rows its compound
  transition names. A token lives for one writer transaction under the lock
  and is spent at commit or abort.
- **No retry by token.** A push that fails after the frame is durable leaves
  the store pending (A1.2); the retry is the derived anchor replay-forward row
  with its own recovery-source token, never the spent one.
- **Recovery tokens** are minted only by the recovery routine after it has
  observed and validated the state that triggers the row, and bind the digest
  of that observed state; a recovery-derived row with a token whose state
  digest does not match the current state is refused.
- **Tests:** each sink called with no token, a spent token, and another row's
  token is refused, for local files and for the remote push (against the bare
  repository); each **compound-derived** row invoked without its parent's
  token is refused; each **recovery-derived** row (truncation, quarantine,
  anchor replay-forward, recovery tidy) invoked without a recovery token, or with one bound
  to a different observed state, is refused; a planted-bypass build (an extra
  write path that skips the token) makes the reachability test fail.

## A1.6 Framing and the durable write intent

**Amended.** A frame is `OLF1 <seq> <type> <length> <digest>\n` + payload +
`\n`, where `<digest>` is sha256 over the bytes `OLF1 <seq> <type> <length>`
(the header without the digest field) followed by the payload. Before writing
a frame, the writer durably records a **write intent** (A1.5 sink) —
`{seq, offset, length, digest, expected_parent, anchor_json, anchor_commit}` —
where `expected_parent` is the commit id the remote anchored when the
transaction began (the previous pointer), and
`anchor_json` is the exact signed pointer bytes (A1.2) and `anchor_commit` is
the exact git commit object bytes that will carry them (tree, parent, and
author and committer set deterministically from the record, so its object id
is fixed). The writer checks, **before the intent's `fsync` and again on recovery**, that
`anchor_json` names this `seq` and this frame's record digest, and that
`anchor_commit` is exactly the commit git would build from `anchor_json`: its
tree has one entry, `anchor.json`, whose blob is exactly the `anchor_json`
bytes; its parent is `expected_parent`; and its author, committer, and message are the deterministic values
derived from the record. Because the blob and tree are functions of
`anchor_json` alone, the intent needs no other git objects: recovery rebuilds
blob, tree, and commit from `anchor_json` and the parent id and requires the
rebuilt commit's id to equal the stored one. On recovery the remote tip is
then read against the intent: tip = `expected_parent` means the push is
pending (anchor replay-forward); tip = the stored commit id, whose parent is
`expected_parent`, means the push already committed (recovery tidy); anything
else is quarantine. In both admitted states the commit's tree, blob, and
signature are verified. Only then does the writer write
the intent, `fsync` it and its directory, and append the frame. It removes the intent only after the anchor
readback. Anchor replay-forward pushes **these stored bytes** — the same
object id — and a recovery that finds an intent without them, or whose
`anchor_json` does not match the frame, quarantines.

Recovery classifies the log's tail:

The cases are tested **in this order**:

- **complete, unterminated** — the bytes from `offset` to end of file are
  exactly the header and the payload of the intent (length and digest match)
  and only the final `\n` is missing. **Validate the whole record first**
  (digest, signature, chain, admission) without changing any byte. Then: if
  the remote anchor names the previous sequence (remote old), **anchor
  replay-forward** appends the delimiter and advances the anchor as one
  compound transition (A1.3); if the remote already names
  this sequence (remote new — no protocol step produces this, because the push
  follows the frame's `fsync`), **quarantine**; if validation fails,
  **quarantine**.
- **torn** — a write intent exists for exactly this `seq` and `offset`, the
  file ends **strictly before** the end of the header-plus-payload bytes, and
  the remote anchor does not name this `seq`. Truncate to `offset` (A1.3).
  Nothing else is ever truncated.
- **everything else** — a short tail **without** a matching intent (for
  example a complete frame whose declared length was increased), a digest
  mismatch, a header that does not parse, a signature, chain, or admission
  failure — is **store quarantine**.

A mutated length therefore never produces a truncation: the intent carries the
true length, and a tail that disagrees with it is quarantine (round-1 finding
B4). Tests inject crashes at every byte boundary of a frame write and mutate
each header field of a complete frame. Also frozen: an intent for `L` whose length or digest differs from frame `L`
(quarantine, never tidied); a cursor-only disagreement (tidied); a
generation-changing pointer with a valid new-root signature but an invalid or
unlinked ceremony record, and the reverse, each quarantine; active-epoch
revocation crashed at every cut: no current authorization at any cut, and the
anchor commit that replay-forward pushes has the same object id as the one
stored in the intent before the crash; an intent missing `anchor_json` or
`anchor_commit`, or whose `anchor_json` names another sequence or digest,
quarantines; an `anchor_commit` with the wrong parent, a tree with another
entry, or a blob differing from `anchor_json` — each with every other byte
identical — is refused before the frame is written and quarantines on
recovery; a readback whose ref id matches but whose `anchor.json` or
signature differs fails; a crash after a successful push and before the
intent's removal is recovered as committed (tidy), not quarantined; an invalid
anchor signature at each linked re-genesis crash cut (both stores untouched,
quarantine). The **last-byte crash** — every byte
written except the final `\n` — is a frozen test vector, for both the
remote-old and the remote-new state.

## A1.7 Per-type subkeys and key durability

**Accepted text.** "Domain-separated keys or subkeys" and "key identity and
epoch on every seal" (`tg:957-966`).

**Amended mechanism.** Each epoch has an Ed25519 **root** key; for every
artifact type the root certifies a separate Ed25519 **subkey** with an OpenSSH
certificate whose key id and principal are the type, valid only for that
epoch. A seal is `ssh-keygen -Y sign` by the type's subkey with namespace
`olddonkey-loop.authority.<type>.v1`; verification checks the certificate
chain to the epoch root, the principal, and the namespace. Keys therefore
differ per type, and a signature for one type cannot verify as another either
by key or by namespace.

Key files (root and subkeys) are written temp → `fsync` → `rename` → directory
`fsync` **before** any record naming them is appended. A record naming a key
file that is absent or does not match its certificate is quarantine, never
replay.

Key states: `active → verify-only` (rotation, old key), `active → revoked` and
`verify-only → revoked` (revocation), nothing out of `revoked`; revoking the
active epoch quarantines the store (A1.3).

The verifier pins the trusted epoch root from the genesis record (and each
rotation record), and tests refuse a subkey certificate whose principal,
namespace, or epoch does not match the sealed record.

## A1.8 Start tokens bind the boot

**Amended.** A start token is `{boot_id, pid, start_time}`, where `boot_id` is
`sysctl kern.bootsessionuuid` on macOS and `/proc/sys/kernel/random/boot_id`
on Linux, and `start_time` is the process start time from the OS. A capability
or identity whose boot id differs from the current boot, or whose pid now
belongs to a process with a different start time, is **stale** and refused.

## A1.9 Opening and issuance are one transaction; approval consume is refused

- Request opening and capability issuance (`tg:811`, `tg:814`) are **one
  writer transaction**, like compound redemption, and the falsifier's crash
  injection (`tg:1400-1402`) covers it.
- `approval.consume` exists in the vocabulary (`tg:1130`) but no row produces
  it in Phase A; the writer refuses it with a distinct error.

## A1.10 Exclusion identifiers

The exclusions of `tg:874-880` are `X1`–`X7` in order, and each matrix row
lists the exclusion ids it enforces, giving the table its sixth column
(`tg:801-807`).

---

## Open questions for review

1. Does any part of A1 weaken task-graph-v1 beyond A1.1, which is stated as a
   weakening by the user's decision?
2. Is the remote-anchor protocol (A1.2) a correct implementation of "rollback is
   a fail-closed error" given crash ordering between the local commit and the
   remote push?
3. Is linked re-genesis (A1.3) consistent with "recovery from any of those is a
   new ceremony, not a repair" (`tg:953-954`) and with "recovery that invents
   authority" being a design failure (`tg:1405-1406`)?
4. Is dormant-until-admissible (A1.4) consistent with the falsifier?

---

## Round-1 disposition (Codex gpt-6-sol / max, thread `01a0ebb0`)

| # | finding | disposition |
| --- | --- | --- |
| B1 | BLOCKER: a local record can be stranded before anchoring; cursor vs log; pending revocation | **accepted** — A1.2 write protocol (five steps), the recovery table comparing the remote with the **validated log**, the derived anchor replay-forward row, and the rule that a pending store gives no current authorization at all |
| B2 | BLOCKER: a new ref per re-genesis permits generation rollback | **accepted** — one anchor ref whose `active` names store id and a monotonic `generation`; a mismatched generation is quarantine |
| B3 | BLOCKER: nonce issuance labelled derived with an external trigger | **accepted** — an external row authorized by the console session, one typed display API |
| B4 | BLOCKER: torn rule could discard a corrupted frame | **accepted** — the durable write intent decides torn; a short tail without a matching intent is quarantine; digest bytes specified; validation before replay-forward |
| B5 | MAJOR: linked re-genesis without a crash protocol; quarantine exception; revocation trigger | **accepted** — five durable steps with the remote push as commit point, recovery per cut, quarantine refuses all but linked re-genesis, active-epoch revocation is compound with quarantine |
| B6 | MAJOR: A1.4 is a second relaxation | **accepted** — titled and stated as a change; 0a keeps negative tests for every dormant row; positive tests assigned per activating unit |
| B7 | MAJOR: tokens do not cover every sink or recovery | **accepted** — the sink list, internal token creation with typed sources, per-transaction lifetime, no retry by token, bypass tests for local and remote sinks |
| B8 | MAJOR: added rows lack the exclusion column | **accepted** — exclusions column on every added row |
| — | note: pin the epoch root; test principal, namespace, and epoch mismatches | **accepted** — A1.7 |

## Round-2 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: recovery compared sequences, not pointers | **accepted** — the full signed pointer is compared; replay-forward requires a matching write intent; same-sequence forks, one-step remote rollback, and stray intents are quarantine; residual intents after readback are removed |
| 2 | BLOCKER: torn and unterminated overlap at the last byte | **accepted** — unterminated is tested first, validates before changing bytes, and differs for remote-old (complete, replay) and remote-new (quarantine); torn requires strictly fewer than header-plus-payload bytes; the last-byte crash is a frozen vector for both states |
| 3 | MAJOR: re-genesis recovery vs generation mismatch | **accepted** — a `regenesis.intent` is resolved before the ordinary comparison; crashes before and after the generation push are tested |
| 4 | MAJOR: sinks and derived-row tests incomplete | **accepted** — re-genesis sinks enumerated; recovery tokens bound to the observed state; compound-derived and recovery-derived rows tested separately |

## Round-3 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: the signed pointer is compared, not verified | **accepted** — `R.sig` and the ref's generation-chain consistency are prerequisites to every table row; `V-replay`'s trigger is the full pointer plus a matching intent; signature, lineage, and same-sequence tampering tested |
| 2 | BLOCKER: recovery writes without an admitted row | **accepted** — a seventh row, **recovery tidy** (`T-intent-cleared` + `T-cursor-reset`), and anchor replay-forward's compound `T-delimiter-completed` + `T-anchor-advanced`; delimiter completion is a listed sink |
| 3 | MAJOR: step-1-only crash state | **accepted** — recovery tidy clears an intent for `L + 1` at exactly the end of the log with no bytes after it; any other trailing bytes are quarantine; frozen as a crash vector |

## Round-4 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: re-genesis acted on the remote before verifying it | **accepted** — the anchor's signature and chain are checked before the intent is resolved; failure leaves both stores untouched and quarantines; tested at each cut |
| 2 | BLOCKER: no verification key for a generation-changing pointer | **accepted** — every pointer is sealed by the active epoch root of the store it names; a new generation's root is introduced by the re-genesis ceremony record; the operator-TTY principal never signs; `prev_generation` links history signed by the old root, never current authority |
| 3 | MAJOR: tidy misses or silently clears states | **accepted** — cursor-only tidy admitted; an `L` intent is cleared only on an exact match with frame `L`, otherwise quarantine; the stale "three recovery rows" corrected to four; both cases tested |

## Round-5 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: prerequisite still named the operator record as a verifier | **accepted** — a generation-changing pointer verifies under the new root, and separately the ceremony record must verify and introduce that root; both checks tested independently at each cut |
| 2 | MAJOR: no signing order for active-key revocation | **accepted** — pointers are signed at creation inside the transaction and stored with the intent; revocation is the revoked root's last act, valid as historical denial; recovery pushes pre-signed bytes and never re-signs; crash cuts tested |

## Round-6 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: the intent lacked the pre-signed pointer | **accepted** — the intent stores the exact signed `anchor_json` and the deterministic `anchor_commit` bytes, checked against the frame and `fsync`ed before the frame; replay pushes the same object id; a missing or mismatched pointer in the intent quarantines; tested at every revocation crash cut |

## Round-7 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: the stored commit was not tied to the signed pointer | **accepted** — before the intent's `fsync` and on recovery, the commit's single-entry tree, blob, and parent are validated against `anchor_json` and the previous pointer; blob and tree are rebuilt from `anchor_json`, so no other object needs storing; readback verifies content and signature, not the ref id; wrong parent, tree, and blob tested |

## Round-8 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: recovery checked the parent against the wrong tip after a push | **accepted** — the intent pins `expected_parent`; recovery accepts tip = `expected_parent` (pending) or tip = the stored commit with that parent (committed), verifying tree, blob, and signature in both, and quarantines otherwise; a crash after push and before cleanup is frozen as a vector |

