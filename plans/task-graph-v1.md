# task-graph-v1

**Status: ACCEPTED** — Codex read-only adversarial review, 11 rounds, 2026-08-18.
**Amended by A1** (`plans/task-graph-v1-amendment-a1.md`, accepted 2026-09-29):
the trusted writer's operator principal, anchor, added operations, row
admissibility, typed entry points, framing, keys, and start tokens. Where the
two differ, A1 wins.
See §12 for the acceptance record and the falsifier carried into implementation.

Round 1 (12 findings, 9 BLOCKER) reversed two decisions settled at kickoff and
rebuilt the evidence model. Round 2 (12, 8 BLOCKER) broke most of the mechanisms
round 1 introduced. Round 3 (12, 8 BLOCKER) reported the architecture
**converging** while finding that every remaining defect sat at one seam: *where
evidence becomes authority and effects*. Round 4 narrowed the scope to Phase A.
Rounds 5–7 hardened the control plane, ending with a single BLOCKER: Phase A
could not honestly issue its own acceptance receipt. Rounds 8–10 closed the
admission matrix, the segment accumulator, and the genesis trust bound. Round 11
settled the last one — how a capability-bound answer becomes its authority
transition — and accepted.

**Round 4 acts on that.** This plan is now scoped to **Phase A only** — the
evidence model, the graph, the catalog, the request/discharge protocol, and a
coordinator that causes no production effects. Execution (Phase B) is split into
a successor plan, `task-graph-v2`, which may not begin until the five
enforcement seams in §7b are mechanically closed and separately reviewed.

This is not a dodge. Round 3's open BLOCKERs are all about *causing effects*; a
v1 that causes none does not inherit them, but it does not get to forget them
either. §7b records each one with its required fix as a **precondition on the
successor plan**, so v2 starts from them rather than rediscovering them.

Round 2 recorded convergence, which is worth naming: the plan-DAG / state-machine
/ attempt-DAG split, foreground execution, attempt-local bases, typed edge
direction, semantics-vs-layout separation, mandatory internal review, and the
explicit admission that provenance is not an OS boundary all survived.

The long-term goal is a visual node graph that **orchestrates** the
implementation loop — the user authors the graph, a coordinator executes it.
That is a change of kind, not degree: today the orchestrator is an agent reading
a prose plan.

**This plan is not that.** `task-graph-v1` is the effect-free control plane
underneath it (§7); execution is `task-graph-v2`. The opening promise is stated
here as the destination, not as what v1 delivers.

---

## 0. Provenance discipline

Carried over from loop-console-v1, where the reviewer refuted seven uncited
"current state" claims: every claim about what the code does today carries a
`file:line` citation or is marked *assumed*. Claims marked *assumed* must be
verified before the plan is accepted, not after.

**Round-0 verification** (against `origin/main` @ `dd203b9`): three citations
were re-pathed — they had named a repo-root `scripts/` that does not exist —
then confirmed. `gate.result` requires
`binding ∈ {clean,dirty,changed,unavailable}` (`loop-journal:97`);
`run-gate.sh` accepts `--purpose unit-final|baseline-generation|focused|unspecified`
(`run-gate.sh:14`); the journal root is
`$HOME/.config/olddonkey-loop/journal/<sha256(workspace)>/` (`loop-journal:12`).

**Round-1 verification** (five highest-stakes findings re-checked against the
code before accepting them — the reviewer has been wrong before):

| claim | verdict |
| --- | --- |
| `set_by=console` is not evidence of human approval | **confirmed** — `refuse_permission_import` (`loop-calibration:599`) guards only the write path; the loader accepts a permission row carrying `set_by=import-confirmed` (`loop-calibration:435`), and the console grants by shelling out with a hardcoded `--set-by console` (`loop-console:1107`) that any caller can pass |
| `gate.result` cannot distinguish green from red | **confirmed, and a live defect in merged code** — `emit_result` journals `$STATUS`, the raw suite exit, then exits `$code` (`run-gate.sh:318-319`); strict mode has four paths that call `emit_result 1` with `STATUS=0`, producing an event whose payload is **equivalent** to a green gate's (sequence and timestamp still differ) |
| gate and dispatch events carry no `unit` | **confirmed** — absent from `EVENT_SPECS` (`loop-journal:81,97`); `build_units` skips any event without one (`loop-index:384`) |
| the completion contract fits only 2 of 4 stop points | **confirmed** — stop points are `worktree/commit/pr/merge` (`SKILL.md:25`; rationale `dials.md:7`); at `worktree` a real change is necessarily `binding=dirty` and never publishes |
| real loops spawn units the two-graph model must hide | **confirmed by this repo's own history** — PR #52 `console-unit2-hotfix` (`7159b86`) is a separately published fix merged *between* Unit 2 (#51) and Unit 3 (#53) |

**Round-3 citation corrections** (the plan's own discipline, applied to itself):
parking is `SKILL.md:204`; the `unit.end` enum is `loop-journal:64`; the
safety-boundary case is `SKILL.md:196` while standing-authorization scope is
`SKILL.md:222`. The claim that cursor and grok emit JSON only at completion
(§10) is marked *assumed* — it comes from loop-console-v1's transcript work and
has not been re-verified against the installed CLIs at this head.

The gate-verdict defect is a **prerequisite fix, not a finding about this plan**
(§7, Unit 0b). Until it lands, no `gate.result` in the existing journal proves
that any gate passed.

---

## 1. What this is, and what it replaces

`loop-console-v1` shipped an **observability** layer: a journal, mechanical
writers, a derived index, and a read-only console with dials. The loop itself
is driven by an agent session reading `plans/*.md` and deciding what to
dispatch next.

This plan inverts that: **the graph becomes the authored source of truth for
intent**, and the implementation-loop skill becomes one executor among the
graph's node types.

Round 1 forced a narrowing of that sentence. The graph is the source of truth
for **declared intent**. It is *not* the source of truth for authorization
(§4) and *not* the source of truth for execution history (§3). A graph file
that is committed to the repo is editable by anyone who can push — including a
dispatched implementer — so it can declare what is wanted and can never itself
authorize anything.

### 1a. Decisions, and the two that round 1 reversed

| decision | value | status |
| --- | --- | --- |
| graph is | **the source of truth for declared intent** | narrowed at round 2 (was: unqualified) |
| executor | **user-started foreground coordinator** | **reversed at round 2** (was: resident daemon) |
| concurrency | serial execution; the model expresses parallelism | unchanged |
| node scope | **unit + closed typed-operation registry + approval** | **reversed at round 2** (was: unit + arbitrary command) |

**Why the executor reversed.** A committed graph plus a resident daemon that
executes commands from it is arbitrary code execution triggered by `git pull`.
`run-gate.sh` execs the supplied argv directly (`run-gate.sh:509`) with no
allowlist and no sandbox; `bash -c`, network calls, and destructive commands
all fit. A background process would run them under the user's authority without
the user present, bypassing the stop-point dial — the one dial whose entire job
is to bound irreversible action (`dials.md:7`). Nothing in the shipped lock
discipline can even make the daemon unique: `meta.lock` (`loop-journal:372`)
guards short store mutations, and `console.lock` (`loop-console:362`) proves
only the console singleton. Neither is a coordinator lock.

**Why the node scope reversed.** Raw commands are the same attack surface, and
round 1 showed they cannot produce honest evidence anyway: `gate.result`
certifies a *tree*, so it says nothing useful about a step whose purpose is to
*change* the tree (baseline regeneration, a version bump). A closed registry of
typed operations is enumerable, auditable, and can define per-operation
evidence.

### 1b. Why the node scope is still not "unit only"

With an agent driving, a step the graph cannot express is harmless — the agent
improvises. During loop-console-v1 the agent hand-performed, between units:
base-branch sync, baseline regeneration, waiting on CI, the Cursor package
rebuild, a version-decision bump, and the installer selftest. Those mechanical
steps were roughly as numerous as the units.

**A coordinator that meets an unexpressible step stops.** So the graph must
express them — but as named operations with defined effects (§4b), never as an
escape hatch.

---

## 2. D1 — Three layers, not two

Round 0 proposed two graphs. Round 1 refuted it, and this repo's own history is
the counterexample.

- **Plan graph** — authored, **acyclic**, edited on the canvas, committed to
  the repo (§5). Nodes are intentions. Never mutated by execution.
- **Node state machine** — a per-node-type lifecycle definition (§3a). This is
  where the cycle lives: round 1 → `iterate` → round 2. It is a *template*, not
  a trace.
- **Attempt DAG** — the append-only record of what actually happened. It is
  **acyclic**: round 2 is a new attempt node pointing back at round 1, not an
  edge returning to it. It is rendered as a run overlay, not on the plan canvas.

**Why the previous model failed.** It claimed iteration is node-interior and
dependency is node-exterior. PR #52 breaks that: a defect found while working
unit B becomes a fix unit F with **its own branch, its own review, its own PR,
and its own base** — and F can become a prerequisite of a *sibling* C. Hiding F
inside B's interior loses F's publication identity and cannot express F→C.
Drawing F on the authored canvas violates "the plan graph is authored intent."

**Rule:** execution-derived nodes are real nodes in the attempt DAG, visible in
the run overlay, and may acquire explicit dependencies there. They never
rewrite the authored plan graph. Promoting one into the plan graph is an
explicit user edit, reviewed like any other graph edit.

---
## 3. D2 — Evidence identity: what makes a completion claim true

Round 1's deepest finding: the existing event names *narrate* a happy-path
unit, but nothing binds them together. `gate.result` and `dispatch.*` carry no
`unit` at all; `review.recorded` carries no reviewed content and no reviewer
identity; `publish.recorded` requires only `unit` and makes branch/sha/PR
optional (`loop-journal:77`). Serial adjacency is not identity.

Round 2 then showed **correlation is not truth**. Labelling four events with
the same run/node/attempt/content does not make the claim true: a node can
require suite S while the coordinator runs the passing suite S′, and every
equality check still passes, because `gate.result` records neither the resolved
command nor a digest of it.

So each phase records **two** digests, not one label set:

| | what it pins |
| --- | --- |
| **request digest** | the exact subject asked for — resolved invocation (argv, cwd, environment, executor version) for an operation; the review request and its subject content for a review; the action envelope for an approval |
| **result digest** | the mechanically derived outcome — explicit verdict, log or receipt identity, producer/actor provenance, and the resulting content state |

…on top of the four-way binding that makes them addressable at all:
`run_id` + run snapshot digest; `node_id` + `node_spec_digest` (a stable id
whose *meaning* changed is worse than no id); `attempt_id`; and content state
(`head`, `tree_oid`).

**A completion claim is true only when** the request digest matches what the
node specified, the result digest carries an explicit success verdict, the
producer is an actor permitted to produce it, and review / gate / publication
are all bound to the same content **through a proven relation**.

Round 3 caught the earlier wording — "the same `{head, tree_oid}`" — being
self-contradictory: a squash or rebase merge *necessarily* produces a different
head, so the rule outlawed the very stop point §4a defines.

**In Phase A, `identity` is the only completion-eligible relation.** Everything
else is recorded as an unproven relation candidate and certifies nothing.

The earlier draft's example — "the commit differing only in parentage" — was
itself wrong: squash and rebase commits differ in author, committer, message,
signature, **and** parentage. Worse, equal trees do not imply equal review or
gate *subjects*: a suite can inspect Git history, parents, commit count, or
tags, and a review against a base-relative diff changes meaning when parentage
changes. So tree equality alone is never sufficient.

A closed set of provider-specific proof kinds may be added **in v2 only**, and
only once P1, P2, and P4 establish what a review and a gate could actually
observe and how the landing is atomically bound. Proof kinds are defined by the
event schema; a relation type may never be introduced by a graph file, a catalog
entry, or free text.

Consequences the earlier drafts missed:

- **Reviewer identity is required.** §3 named the omission at round 2 and then
  did not fix it. `review.recorded` must carry who reviewed, and the review
  request it answers.
- **`binding=changed` is ineligible**, not merely noted. A gate whose tree moved
  under it certifies nothing.
- **Endpoint-sampled gates are ineligible too**, and this constrains Phase A
  even though the underlying defect is deferred to §7b P1. `run-gate.sh` samples
  content before and after the suite (`run-gate.sh:507-512`), so a suite that
  changes T→T′, passes against T′, and restores T yields a gate where every
  digest agrees and the tested tree was never the certified one. Unit 0b
  separates verdict from suite exit; it does **not** close this. So every gate
  event carries an assurance field —
  `input_isolation ∈ {endpoint-sampled, immutable}` — and the reducer treats
  `endpoint-sampled` as **not completion evidence**. The canvas may display it;
  certification stays `unknown`. Otherwise Phase A's evidence model would make a
  false claim before v2 exists.

### 3b. The assurance-promotion rule

A field is not proof. `input_isolation=immutable` appended by a caller, or an
adapter self-reporting `enforced`, would be exactly the `set_by=console` mistake
in a third costume. One rule governs every assurance axis:

- **Absent or legacy means the weakest value.** Schema-1 events predate these
  fields; compatibility must never infer a stronger state from silence.
- **Phase A may only ever emit the weak values** — `endpoint-sampled`,
  `declared`, `unproven`.
- **Promotion to `immutable`, `enforced`, `atomic`, or `conformant` requires a
  trusted-writer-verified closure receipt** (§6c) bound to the exact mechanism
  *and* the exact event.
- **Graphs, catalog entries, and event callers may never assert an upgraded
  assurance.** The writer is the only thing that can.

This is also how the deferred seams shape Phase A's schema without being built
in it (Q14): each records a **claim** now and becomes verified only when its
closure receipt exists — P2 records the declared capability and executor-profile
digests, P3 the conditional primitive and expected-state digest, P5 the logical
repository, execution root, and adapter/effect-child identities plus the
handshake mechanism. A claim-versus-proof envelope, uniform across all five.
- **Unit 0b must add an explicit gate verdict field and keep the raw suite exit
  separately** — both, not one replacing the other. The suite's exit code is
  real evidence; it is simply not the gate's verdict.

`EVENT_SPECS` is fail-closed on unknown payload keys (`loop-journal:621`), so
all of this is a schema change (§7, Unit 0a).

### 3a. Lifecycle — a transition table, not a state list

Round 2: the previous draft listed states and called it closed. It had no
`ready → starting`, no way back from `blocked`, no resolution out of
`unknown-outcome`, and it omitted `parked` — which is doctrine's real outcome
for a unit that cannot proceed unattended (`SKILL.md:204`, and `unit.end`
already accepts `status ∈ {done, parked}` at `loop-journal:64`).

**Execution lifecycle and stop-point result are different axes.** Conflating
them was the error.

*Execution lifecycle* (what the coordinator is doing):

| from | to | on |
| --- | --- | --- |
| `ready` | `starting` | selected, preconditions hold, effect authorized |
| `ready` | `blocked` | a precondition needs a decision or approval |
| `blocked` | `ready` | the request was answered, the answer still applies, and its preconditions revalidate |
| `blocked` | `failed` | the request was **denied** |
| `blocked` | `parked` | the request **expired** or no permitted actor is available |
| `starting` | `running` | child identity observed and verified (§6a) |
| `starting` | `failed` | spawn failed with no effect |
| `starting` | `blocked` | an approval expired or its preconditions drifted **before the barrier released** — effect-free, so this is always safe |
| `running` | `blocked` | a mid-flight judgment is required (review, triage) — **requires established quiescence first**, otherwise the child is still causing effects while the node claims to be waiting |
| `running` | `succeeded` / `failed` | terminal evidence recorded |
| `running` | `unknown-outcome` | coordinator lost the child; effect status unprovable |
| `unknown-outcome` | `succeeded` / `failed` | **separately proven evidence** resolved it — reconciliation or receipt lookup. User attestation alone may **not** produce `succeeded`: §4b and §6b define attestation as establishing quiescence, not retroactive success |
| `unknown-outcome` | `parked` | it cannot be resolved; carry it to the user |
| any non-terminal | `cancelled` | user cancellation, with quiescence established |
| any **non-terminal** | `parked` | doctrine's park-don't-halt (`SKILL.md:204`). A terminal state is never rewritten as parked; Unit 0a's reducer carries a test proving it |

Derived markers: `stale`, `superseded`, `landed-but-ungated` (§4a).

*Stop-point result* (how far a `unit` travelled) is a separate enum and lives in
§4a. A node is `succeeded` **at** `pr-open`; the two are not alternatives.

---

## 4. D3 — Node types and their evidence

The closed set for v1. **A node type is admissible only if its completion
evidence is defined**, and after rounds 1–2, only if that evidence is bound and
digested per §3.

### 4a. `unit` — a reviewable change

Runs the loop doctrine: dispatch → review → gate → publish.

Terminal result is **stop-point-specific** (`SKILL.md:25`):

| stop point | result | evidence |
| --- | --- | --- |
| `worktree` | `reviewed-worktree` | review `pass` bound to a working-tree content digest and a reviewer; no publication; `binding=dirty` is *expected* |
| `commit` | `gated-commit` | review `pass` + a gate with an explicit passing verdict certifying the candidate commit's tree; branch + sha |
| `pr` | `pr-open` | the above + PR identity and its head sha |
| `merge` | `integrated` | the above + a **pre-merge-gated** integration result (below) + the provider's merge receipt |

**The merge row, corrected — twice now.** Round 0 assumed the merge commit is
the predecessor's output. Round 2's fix, "read the integrated state back from
the remote," was *also* wrong, and worse: it proves what landed, not that what
landed was gated. The shipped doctrine already had the right answer and this
plan had regressed off it (`SKILL.md:179-181`):

> Before merging, verify the remote head still equals the gated SHA and the base
> still equals the recorded one; if either moved, satisfy one of these before
> landing — update head onto the current base and re-gate, gate the platform's
> synthetic merge commit, or construct the merge locally and gate that tree.

So `integrated` requires: head and base pinned and verified unmoved, **or** one
of those three re-gating paths executed; then the provider's immutable merge
receipt recorded, that exact object fetched, and target-ref containment
verified. If the post-merge tree differs from what was gated, the result is
**`landed-but-ungated`** — a reported, visible state, never a success.

Only verdict `pass` counts (`loop-journal:73`).

**Review is mandatory and cannot be satisfied by the coordinator** (§6b).

### 4b. `operation` — typed steps from an out-of-repo catalog

Replaces the rejected `command` node. Round 2 showed the round-1 version was
still not a boundary: `run-suite` has to resolve to a repo-specific command,
and if that command comes from the graph then arbitrary execution is back,
while if it is hard-coded the operation is useless across repos. "Fixed argv
shape" was an assertion with no mechanism.

**The mechanism:** a graph node may bind only an **immutable operation ID**.
Resolution happens through a **user-approved catalog that lives outside the
repository** (alongside the calibration store, which the graph also cannot
write). The graph names *what*; the catalog decides *how*.

Round 3 was right that moving the file was not by itself a root of trust — it
relocated the hole rather than closing it, and risked repeating the discarded
`set_by=console` model where provenance is whatever the caller asserts. The
catalog's own trust contract:

- **Default-deny and empty.** A workspace with no catalog can run no operation.
- **Entries are canonically encoded and content-addressed.** The ID *is* the
  digest, so an entry cannot change meaning under a stable name — the same rule
  §3 applies to node specs.
- **Enrollment is a one-shot authenticated human action**, through the same
  authenticated console as approvals, displaying the executable's provenance,
  parameter grammar, sandbox profile, write targets, retry class, and repository
  scope. Recording the resolved invocation *afterwards* is audit, not
  authorization.
- **Any change creates a new ID.** There is no in-place edit.
- **Enrollment produces a receipt, sealed by the trusted writer**, binding the
  entry digest, the logical repository (§5b), the executor-profile digest, the
  policy version (§4c), and the gesture nonce. Content addressing proves *which
  bytes* were loaded; only the receipt proves the console's authenticated
  gesture enrolled them. A loader that accepts an entry without a valid receipt
  would be the `set_by=console` mistake again, in a new file.
- **Enrollment is one transaction:** the gesture nonce is **consumed atomically
  with the sealed receipt's append**, under the writer lock. Consuming and
  sealing separately would leave a spent gesture with no receipt, or a receipt no
  gesture authorised.
- **Pinning and revocation are separate mechanisms**, because one run-pinned
  snapshot cannot express both. The pinned catalog version is **immutable** — it
  is what the run's evidence means. Revocation is an **authenticated,
  sequenced, append-only ledger** written under the writer lock, with defined
  sequence allocation and fsync/recovery ordering. Rollback detection rests on
  the independently anchored authority head (§6c) — a signed sequence alone
  cannot detect restoration to an older valid snapshot. A ledger that appears to
  move backwards is a fail-closed error, not a fresh start.
- **Every resolution returns a proof**, not just an entry: the entry digest, its
  enrollment receipt, the pinned catalog version, and the **observed revocation
  generation**. That generation participates in staleness (§5b, Q1) and is
  **re-checked before any future effect** — otherwise a cached resolution
  outlives a later revocation, which is how a revoked operation would still run.
  Resolution is fail-closed on a missing receipt, a revoked entry, or an
  unreadable ledger.
- **Scope** is a logical repository plus an enforced executor profile.

Standing enrollment is what keeps this from becoming per-run rubber-stamping;
high-effect actions still require a §4c envelope at execution time.

Each catalog entry is normative and specifies: executable, argv template and
parameter grammar with bounds, cwd, environment allowlist, declared capabilities
(tree / refs / network), write set, timeout, effect contract, and **retry
class** (below). The attempt records the **exact resolved invocation**, the
executor version, and the capabilities in force — that is the request digest of
§3.

| operation | effects | completion evidence | retry class |
| --- | --- | --- | --- |
| `run-suite` | reads tree | `gate.result` with explicit passing verdict + equal pre/post content | safe-retry |
| `wait-for-checks` | observation, network | PR head sha + exact check set and conclusions | safe-retry |
| `sync-base` | mutates refs | ref compare-and-swap: expected old → new OID | reconcilable |
| `produce-baseline` | produces artifact | artifact digest bound to base commit/tree, suite request, executor/environment, and log | safe-retry *inside containment* |
| `activate-baseline` | mutates pointer | base-ref CAS: activation succeeds only if the base still equals the commit the artifact was produced for | reconcilable |
| `build-package` | mutates tree | output artifact digest + input tree + version-decision evidence (§4d) | reconcilable (atomic staging) |
| `integrate-candidates` | mutates refs | see §5a — a typed transaction, not a sync | manual-only |

**Retry classes exist because round 2 was right that a durable start record
detects ambiguity without resolving it.** After a crash the effect may have
happened with no result recorded. So recovery is per-operation, not blanket:

- *safe-retry* — observations and read-only gates; repeating them is free.
- *reconcilable* — the operation defines how to inspect the world and decide:
  local effects use atomic staging (write beside, rename into place) or ref
  compare-and-swap; external effects carry an immutable client-side request ID
  so the receipt can be looked up rather than re-created.

  **Atomic staging is not sufficient on its own.** Round 3's baseline case:
  bytes generated for base B can be atomically installed after the branch has
  moved to B′ — complete, and semantically stale in exactly the way doctrine
  warns about, where a stale baseline both invents failures and hides
  regressions (`SKILL.md:189`). Hence the split above: **production** yields an
  immutable artifact bound to its base; **activation** is a separate operation
  gated by a CAS on that base. A moved base makes the artifact ineligible — kept
  as evidence for B, never silently current.
- *manual-only* — the user attests. Attestation establishes **quiescence**, not
  retroactive success; the honest outcome may still be `parked`.

The round-2 blanket "never auto-retry `unknown-outcome`" is withdrawn as
over-broad: it stalled observation nodes that are safe to repeat.

`run-gate.sh` is used by `run-suite` **only**, after the Unit 0b verdict fix.

### 4c. `approval` — a human authorization

Round 1 killed the calibration-row premise. Round 2 killed the replacement: a
console-minted nonce proves a console *code path* executed, not that a human
approved **this action under its current preconditions**.

- **The graph cannot be trusted to require an approval.** An untrusted file can
  simply omit the node. So **effect policy generates mandatory approval
  requests**, independent of what the graph drew. A graph may add approvals; it
  can never remove one.
- **That policy must be a closed function, not a principle.** The kernel
  (unit 3) cannot emit deterministic requests, and the discharge units cannot
  test the omission-resistance claim, against prose. Round 5 was right that naming a codomain is not defining a
  lattice; the laws matter more than the values:

  - **Total function** over
    `{mode, effective standing policy, capability set, alias-closed targets, parameters}`.
    Standing authorization and the stop-point dial are **inputs**
    (`dials.md:7`, `SKILL.md:216-222`), not context the caller applies afterwards.
    Because they are inputs that can *lower* the result, **permission-bearing
    standing policy is itself a sealed artifact** (§6c) created through an
    authenticated gesture, with monotonic revocation. Round 6 confirmed why in
    code: today any caller can run `loop-calibration set --set-by console`
    (`loop-calibration:623`, `loop-console:1099`), so a digest over those bytes
    authenticates the bytes and not the human. **A legacy or unsealed
    permission row is no authorization at all**, and an unsealed value may only
    ever *tighten* the result — never widen it to `allow`.
  - **Ordered** `allow < one-shot-approval < manual-only`.
  - **Monotone:** widening a capability or a target scope may **never** lower the
    result.
  - **Composition accumulates over a segment; it does not merely take a
    maximum.** Round 6 showed `max` alone does not close the split — two one-ref
    operations each evaluating to `allow` compose to `allow` even where their
    union is `manual-only`. Round 7 showed that unioning capabilities and targets
    is *still* not enough, because **set union loses multiplicity**: two
    operations against the same target evade any quantity, count, or ordering
    threshold. So the segment carries a **canonical accumulator**:

    `{primitive-effect descriptors, multiplicity and order, parameters,
    capabilities, alias-closed targets, policy version, descriptor version,
    logical repository identity + incarnation, execution domain, relevant
    authority generation}`

    The last three exist because round 9 found identical primitive effects in
    two different repositories — or a Phase A **simulation** against a Phase B
    **effect** — producing the same discharge subject. A human discharging one
    would have discharged the other.

    Each parameter declares a **schema-defined associative fold** — owned by the
    **policy schema**, never by a catalog entry or a graph — and a parameter
    with no defined composition folds to `manual-only` rather than being dropped.
  - **Equivalence needs a canonical subject, not authored identity.** Round 8
    showed the required split-versus-unsplit test had no mechanical oracle:
    authored action digests *inherently* differ between one batched node and five
    separate ones, so comparing them can never establish sameness. Instead each
    closed operation schema emits **canonical primitive-effect descriptors**, and
    the accumulator accumulates and compares *those*. Action digests are retained
    for provenance only. "The same work" therefore means the same primitive
    effects, which is a property of the operations rather than of how someone
    drew them.
  - **Only a sealed `segment-discharge` resets the accumulator**, bound to the
    **complete accumulator digest** — so a human discharges *what they were
    shown*, not a moving target. It is the **redemption of its typed request**,
    not a fresh console gesture, and redemption, current-digest validation,
    sealing, and reset are **one writer transaction**. Splitting them would let
    the accumulator move between what the human saw and what got reset. Run termination is
    not a reset: the accumulator **carries across runs** until an authenticated
    human explicitly resets it, otherwise ending a run is a graph-shaped reset
    an attacker can trigger. The §4c approval envelope binds the current
    invocation; the accumulator is what binds the pattern.
  - **Targets are alias-closed and canonicalised**, so symlinked paths, packed vs
    loose refs, and equivalent spellings cannot make one concrete target look
    narrower than it is.
  - Unknown, unclassifiable, or broad effects resolve to `manual-only` — never
    `allow`.

  The request and the catalog snapshot both pin the policy version, so an answer
  cannot outlive the rules that produced it.
- **Declared capabilities are provisional, and their output is advisory only.**
  Until §7b P2 lands enforcement, a declared capability is a claim by a catalog
  entry (§3b), so Phase A's policy output over declared inputs is a dry-run
  advisory — never a grant that v2 can inherit.
- **The human approves an envelope, not a node.** The console displays and binds
  a canonical action envelope: the resolved invocation, the expected refs and
  content OIDs, the effect contract, and the policy in force. A human gesture
  grants *that envelope*.
- **The condition must ride into the mutation, not merely precede it.** Round 3
  showed "atomic consumption immediately before the effect" narrows the window
  without closing it: another process can move a ref or a remote base between
  revalidation and mutation. So the envelope's expected values are carried
  **into the mutation primitive itself** — a ref compare-and-swap, a conditional
  provider request, or a lease. **An effect whose target cannot enforce the
  condition atomically may not be executed automatically at all**; it becomes a
  manual-only operation (§4b).
- **Storage and redemption:** store only a hash of the nonce; consume it
  atomically as part of that conditional mutation; re-validate every precondition
  in the envelope at consumption time. Any drift — head moved, base moved,
  policy changed — voids it and requires a new approval. Expiry is checked at
  consumption, not at issue.
- **Crash after redemption** is an `unknown-outcome` for the effect and a
  **spent** approval. A spent nonce is never re-usable; recovery goes through
  §4b's retry class.

**Honest scope.** The console runs as the user's own uid, so this is a
**provenance boundary, not a kernel boundary**. It defends against accident,
replay, a graph that lies by omission, and a dispatched implementer following
the documented interface. It does not defend against a deliberate local
attacker already running as the user. The plan claims exactly that much.

### 4d. Phases the registry still has to name

Round 2 found that the five-entry registry already fails on work *this repo has
actually done*. Each becomes typed rather than smuggled through a generic node:

Round 4: naming them was not typing them, and a fail-closed validator cannot
validate alternatives and prose. **Each is assigned to exactly one schema
construct** — no "either/or" left for implementation:

- **investigation — a node type** with its own state machine. A read-only
  dispatch has no diff, so nothing to review, gate, or publish
  (`dials.md:11`, dispatch mode). Completion evidence: the dispatch record and
  transcript identity, and the node's terminal result is explicitly
  `informational`, never a completion claim about code.
- **manual/interactive observation — a mandatory phase** on any node whose
  catalog entry or node type declares one, discharged by an `observation`
  request (§6b). loop-console-v1 shipped a defect that 82 passing selftests did
  not catch and that opening a real browser did (`f612848`, PR #56). CI
  observation is not this. Evidence is a capability-bound human attestation tied
  to the attempt and content.
- **version-decision — a `design-decision` request** (§6b) attached to a named
  `build-package` operation attempt. loop-console-v1 consumed a tracked version
  decision this way (`build.sh:345-377`, *assumed* — cited from the round-3
  review and not independently re-read at this head). The earlier "either a unit
  or attached evidence" is resolved to the request form; a `unit` remains
  available when the decision genuinely produces a reviewable diff, but the
  schema no longer offers two homes for one thing.
- **candidate integration** — §5a, a typed transaction with its own contract.

**Still rejected:** a generic "run anything" node, and a sixth registry entry
used as an escape hatch. If the first real graph needs an unlisted operation,
the taxonomy is unfinished — that is the answer to Q6, not a new entry.

---

## 5. D4 — Edges, bases, and the graph file

### 5a. Attempt-local bases, typed edges, explicit integration

Round 1 moved the base off the edge; that survived. Round 2 found the join
still had no contract.

- The base lives on the **node attempt** as one immutable
  `{input_commit, input_tree}`.
- Edges are **typed**: a *control* dependency (ordering only) is distinct from
  an *integration* dependency (B needs A's git result).
- Reading the current workspace to choose a base is forbidden — that is how
  hidden dependencies are created.
- A node with more than one integration parent requires an
  **`integrate-candidates` transaction**, which is a real operation with real
  evidence: it names every parent candidate by OID, produces one result tree,
  and **gates that result** before anything depends on it. A failed integration
  is a first-class outcome, not a merge conflict left in a worktree.
  `sync-base` cannot stand in for it — moving one ref is not combining
  candidates.
- **The canvas may collapse join ceremony visually.** Explicitness is a property
  of the semantic graph and its evidence, not a demand that the user hand-draw
  every integration node. Semantically explicit, visually collapsible.

### 5b. The graph file, the run snapshot, and what divergence actually means

- Location: `<repo>/.olddonkey-loop/graph.json`. Semantics tracked; **canvas
  layout in a separate, untracked, per-machine file** — the earlier "positions
  are semantically inert" claim was withdrawn because inert and tracked cannot
  both be true. Startup must distinguish a committed pinned graph from a
  deliberately bound dirty snapshot.
- Validation is **fail-closed**: unknown node type, unknown field, duplicate id,
  a cycle, an edge to a missing node, or an operation ID absent from the
  approved catalog **rejects the whole file**.
- The file is **untrusted input**. It declares intent; it authorizes nothing.

**Divergence, corrected.** Round 2 caught the round-1 mechanism firing on the
loop's own normal behaviour: doctrine creates the unit branch **at dispatch
time** (`SKILL.md:44`), commits on it, and between units syncs the base branch
and re-branches from the updated base (`SKILL.md:189`). A rule that says "a
branch switch stops new launches" diverges the run from itself at its first
normal step.

So: **freeze graph semantics, not the execution checkout.**

- The run snapshot pins the **semantic graph digest and graph blob sha** — never
  the working checkout.
- Expected Git transitions are declared per attempt as **compare-and-swap
  preconditions** (`expected_ref`, `expected_old_oid`). A transition the attempt
  predicted is normal; only an unpredicted one is drift.
- Execution prefers **separate worktrees** — but round 3 showed this is not
  transparent, and the earlier one-line version hand-waved over real machinery.
  The journal is keyed by canonical path (`loop-journal:307`) and `load_context`
  rejects a record whose workspace differs from the current one
  (`loop-journal:826`, `wrong-workspace`). The adapters then differ from each
  other: grok *requires* the caller to already be in a linked worktree
  and then works from a snapshot copy placed **beside the workspace**, with only
  its Git administrative directory under the common dir's `worktrees` path
  (`backends/grok/dispatch.sh:455-457`; preconditions `528-573`), cursor works
  in a gitless copy and applies a normalized patch back
  (`backends/cursor/dispatch.sh:11-13`), and codex edits the workspace in place
  (`backends/codex/dispatch.sh:608`, `-C <workspace>`).

  So **logical run identity and execution-root identity are separate concepts**.
  A run is identified by its logical repository and snapshot, not by whichever
  directory an adapter happened to execute in; the coordinator issues a **writer
  capability** binding the two; ref effects are fenced by the **Git common
  directory** rather than the worktree path; and worktree create/retire is
  itself a typed effect. Each backend declares its own execution/output
  contract — `{expected_ref, expected_old_oid}` alone does not describe
  worktree registration, symbolic-HEAD changes, or patch application.
- The staleness digest covers the node's **effective policy** — the dials that
  actually bear on it — not the whole calibration store. A whole-store digest
  stales unrelated nodes whenever any irrelevant dial moves.
- `graph-diverged` therefore fires only on an **unplanned semantic-graph or
  relevant-policy change**, and it is **not** recoverable by in-place migration:
  it creates a **successor run** that may reference still-valid
  content-addressed evidence from the predecessor. An active run is never
  rewritten underneath itself.

**Logical repository identity.** §5b and §4b both lean on "logical repository,"
and round 4 was right that naming it is not defining it. It is a **locally
registered identity**, not derived from a remote URL (which may be absent,
shared between clones, or changed):

- Registration records the Git **common directory** and the worktrees mapped to
  it, so linked worktrees of one repository share an identity while separate
  clones do not. The mapping is **one-to-one** and canonical-path validated.
- **A path is not an incarnation.** Round 6's case: delete repository A, create
  unrelated repository B at the same canonical common-directory path, and the
  one-to-one mapping still holds while B silently inherits A's identity and
  every catalog grant it carried. So registration also seals an **incarnation
  identifier** — filesystem identity plus a random registration generation —
  and revalidates it on every use. Replacement, ambiguity, or a cross-device
  move **blocks** and demands authenticated rebinding.
- **Registration is a sealed authority artifact** (§6c), not bookkeeping.
  It decides which catalog grants a workspace inherits, so *initial*
  registration is authenticated and sealed — not only rebinding, which the
  earlier draft alone required.
- Moving a repository **rebinds** the existing identity rather than minting a
  new one. Any rebinding that changes inherited grants requires an authenticated
  gesture and produces its own sealed, audited receipt.
- A non-Git workspace gets a registered identity with no ref mappings and no
  ref-effect capabilities.

Runs are stored under that identity. **Execution roots are separate registered
subjects**, each acting under a coordinator-issued one-shot writer capability.

Execution state is never written back into the graph file. It lives in the
journal (`loop-journal:12`), which is keyed by canonical workspace path
(`loop-journal:307`) and whose `load_context` rejects a record from a different
path (`loop-journal:826`). **Binding a run to its snapshot does not close that**
— the earlier draft claimed it did, which was wrong. Path attribution is closed
by storing runs under the logical-repository identity above and treating the
execution root as a separate subject.

---

## 6. D5 — The coordinator

**Foreground, user-started, one per logical repository** (reversed from resident
— §1a).

Round 4: "no production effects" was a stated intention while §6 still
authorized adapters, operations, and publication. It is now a **capability set,
enforced in code**.

**The v1 coordinator holds `execution-disabled`:** it has **no entry point** for
an adapter launch, a catalog operation, a Git ref mutation, or a publication.
Absence of the code path is the mechanism; a runtime flag someone can flip is
not.

**It may:** select the next runnable node in topological order; evaluate
staleness, divergence, and blocking; emit requests; append journal events. Those
control-plane writes are real mutations, and the plan calls them that rather
than pretending Phase A writes nothing. The **enumerated** list — any write not
on it is a defect — is: journal appends; lock acquisition; catalog enrollment
and revocation-ledger appends; **logical-repository registration and rebinding**;
**execution-root registration**; request discharge; and receipt sealing. Round 5
caught the first version of this list omitting the registration writes while
calling itself exhaustive.

**Fixtures live in the selftest harness, not in the coordinator.** The spawn
barrier, process-group escape prevention, and quiescence cannot be proven with
no processes at all — but round 5 was right that "hermetic fixture, touching
nothing the user owns" is intent, not a boundary, and that a parameterised
fixture launcher is the arbitrary-command node returning under a new name. So:

- Fixture executables are **fixed, content-digested assets of a separate
  selftest harness**. The production coordinator has no fixture-launch entry
  point at all.
- **Fixed argv.** The interface accepts no executable, path, or parameter
  supplied by a graph, a catalog entry, or a run.
- A **private fresh root** with its own `HOME`/XDG state; **no inherited
  authority descriptors**; **network denied**; **no writes outside the scratch
  root**.
- **Confinement must be OS-enforced, deny-by-default, over the complete fixture
  process tree** — and if that boundary is unavailable on the host, acceptance
  **fails** rather than degrading. Round 6 caught the previous version making
  exactly the mistake §3 rejects for gates: before/after protected-root hashes
  cannot see a descendant that writes T→T′→T, so they are **diagnostics only**,
  never confinement evidence.
- Round 7 caught those two sentences contradicting each other — one said
  acceptance fails without OS confinement, the next said Phase A may use a fake
  — leaving it undefined whether such a host can issue a release receipt. It is
  now defined by **designated acceptance platforms**: on a designated platform,
  enforced live-fixture coverage is **mandatory** and its absence fails
  acceptance. Any other host may use a **pure process-model fake** for
  development, and **cannot issue unit 12's receipt**. No host both lacks
  enforced confinement and accepts a release.
- **The platform set is itself rooted**, because round 8 was right that it is an
  authority input: a candidate that could designate its own acceptance platform
  would weaken the gate it is passing. Designation is an **operator ceremony**
  with its own matrix row (§6c), its policy digest is pinned at genesis, and
  **release acceptance binds the platform identity, the confinement mechanism
  and version, and the platform-policy digest**. An empty or unreachable
  platform set makes acceptance impossible rather than automatic — fail-closed,
  like everything else here.

**It may never:** decide a review verdict, grant an approval, treat a missing
signal as success, or acquire an effect capability at runtime.

Phase A **specifies and fixture-tests the adapter handshake interface** (§6a);
modifying the real adapters and proving their conformance is §7b P5.

### 6c. The trusted writer

Everything this plan calls "sealed" is sealed by one writer. Round 5 asked
whether concentrating them is correct, and the answer is **yes, keep one logical
writer**: centralisation is what makes serialization, one-shot redemption, and
audit possible, and splitting into several same-uid writers would add
distributed transactions without creating a real trust boundary. But "sealed"
was a label with no contract, so:

- **One narrow logical writer**, with **typed per-artifact APIs** and an
  exclusive lock on the authority store. Round 6 refined what it must be: not
  *policy-free* — sealing inherently requires deciding whether to seal — but
  **domain-judgment-free while admission-policy-enforcing**. It never decides
  whether a review passed, whether a release is done, or whether a grant is
  wise. It always decides whether *this* artifact, from *this* source, with
  *this* evidence, is admissible.
#### The admission matrix

Round 7 found the six-row version **not total under its own fail-closed rule** —
catalog revocation, key and anchor transitions, execution-root capability
issuance, and segment discharge are all authority decisions with no row, so the
writer would have had to reject required transitions or handle them outside the
rule that is supposed to be central. It also had only two columns, which cannot
express a validation rule.

Every admissible operation declares six things:
`{trigger, authorized principal or deterministic source, required evidence,
validation predicate, exclusion predicate, resulting transition}`. Round 8 found
the previous table declaring that contract and then omitting two of the six
columns — identifying evidence without saying when it is valid or what atomic
change follows. Both are now present as named identifiers that unit 0a
implements and tests.

| operation | trigger | principal / source | required evidence | validator | transition |
| --- | --- | --- | --- | --- | --- |
| **request opening** | reducer, from the request kind's **source state** (below) | **derived** | source state, request kind, schema-derived scope, target eligibility | `V-request-open` | `T-request-opened` |
| **request cancellation** | console gesture, or the source state becoming invalid | authenticated human, or **derived** | request id, open state, reason | `V-request-cancel` | `T-request-cancelled` |
| **request expiry** | the expiry passing | **derived, not decided** | request id, expiry | `V-request-expire` | `T-request-expired` |
| capability issuance | a request is opened | **derived** from that request | request id, target session + start token, scope, expiry, mode | `V-cap-issue` | `T-cap-issued` |
| capability redemption | the target answers | the bound target session | the secret + the answer, in one append (§6b) | `V-cap-redeem` | **compound, by request kind** (below) |
| enrollment | console gesture | authenticated human | canonical entry, executor profile, policy version, gesture nonce | `V-enroll` | `T-entry-active` |
| enrollment revocation | console gesture | authenticated human | entry digest, prior generation | `V-revoke-entry` | `T-entry-revoked` |
| repository registration | console gesture | authenticated human | common dir, incarnation id, generation | `V-repo-register` | `T-repo-active` |
| repository rebind | console gesture | authenticated human | prior + proposed incarnation, grant delta | `V-repo-rebind` | `T-repo-rebound` |
| execution-root registration | coordinator selects a root | **derived** from the registered repository | logical repo id, root path, incarnation | `V-exec-root` | `T-exec-root-active` |
| standing authorization | console gesture | authenticated human | dial, scope, policy version | `V-standing` | `T-standing-active` |
| standing revocation | console gesture | authenticated human | prior sealed grant | `V-revoke-standing` | `T-standing-revoked` |
| segment discharge | **derived** — redemption of a `segment-discharge` request | **derived** from that redeemed request | complete accumulator digest (§4c) | `V-segment` | `T-segment-reset` |
| mechanism closure (P1–P5) | **derived** — redemption of a `mechanism-closure` request | **derived** from that redeemed request | mechanism id, conformance evidence, verifier identity | `V-closure` | `T-mechanism-closed` |
| **acceptance-platform designation** | ceremony | authenticated local operator | platform set, confinement mechanism + version | `V-platform` | `T-platform-policy-active` |
| release acceptance | **derived** — redemption of a `release-acceptance` request | **derived** from that redeemed request | exact release tree, acceptance evidence, decision chain, **platform identity + confinement mechanism/version + platform-policy digest** | `V-accept` | `T-release-accepted` |
| authority-head advance | an admitted append | **derived, not decided** | the append it follows | `V-head` | `T-head-advanced` |
| epoch **rotation** | ceremony | authenticated local operator | current epoch, **proposed key identity + new epoch**, anchor position | `V-epoch-rotate` | `T-epoch-rotated` (atomically: old → `verify-only`, new → `active`) |
| epoch **revocation** | incident | authenticated local operator | current epoch, anchor position | `V-epoch-revoke` | `T-epoch-revoked` |

**Redemption is the only way an answer becomes an authority change.** Round 10
found the last plan-level decision hiding here: the registry authorized segment
discharge, mechanism closure, and release acceptance as *fresh console
gestures*, while §4c required discharge to be the redemption of its typed
request in one transaction. An implementer would have had to decide for itself
whether redeeming a capability merely **records an answer** or also **applies
the decision** — an authority rule wearing the costume of an encoding choice.
It also broke the invariant that each external entry point maps to exactly one
row, since discharge had two.

Settled: **capability redemption is the sole external entry point**, and its
transition is **compound, selected by request kind**:

| request kind | compound transition |
| --- | --- |
| `review`, `triage`, `scope-change`, `approval`, `attestation`, `observation`, `design-decision`, `ceiling`, `safety-boundary` | `T-request-answered` |
| `segment-discharge` | `T-request-answered` **+** `T-segment-reset` |
| `mechanism-closure` | `T-request-answered` **+** `T-mechanism-closed` |
| `release-acceptance` | `T-request-answered` **+** `T-release-accepted` |

The three authority rows above are therefore **derived**: each may arise *only*
from the redemption of its matching request, never from a direct gesture, and —
being derived — has no external entry point of its own. Validation, sealing, and
the state change are one writer transaction, so an answer and its consequence
cannot come apart.

**Request kinds have different source states.** Round 9 caught `V-request-open`
requiring "a valid node state" while three of the requests are not
node-originated — which meant Phase A could not open its *own* acceptance
request without violating the matrix. The mapping is closed:

| request kind | source state |
| --- | --- |
| `review`, `triage`, `scope-change`, `approval`, `attestation`, `observation`, `design-decision`, `ceiling`, `safety-boundary` | node state |
| `mechanism-closure` | mechanism state |
| `segment-discharge` | accumulator state |
| `release-acceptance` | candidate-release state |

The full request-kind × source-state cross-product is a test, not a convention.
**Cancellation and expiry are admitted operations**, because both change whether
a bearer capability is still redeemable — round 9 was right that leaving them
unadmitted meant they either bypassed the matrix or could not happen.

**Exclusions**, kept out of the table for width: a session may not answer its own
request; the implementing session may not close its own mechanism; the builder,
coordinator, and writer sessions are mechanically excluded from release
acceptance; an execution root may not mint scope its repository lacks; an
inheritance-changing rebind requires a fresh gesture; the writer may not rotate
its own key without the operator; and derived operations may never be requested
directly.

**Totality is a test, not a reading.** This matrix has failed prose inspection
three rounds running — round 6 found standing authorization missing, round 7
found four more, round 8 found request opening and platform designation, and
round 9 found cancellation. A reviewer's eye cannot hold this invariant as the
APIs evolve.

Round 9 also showed the first version of that test was wrong: comparing five
sets for equality can **pass while all five omit the same authority path**, and
the sets are not one-to-one anyway — a derived operation like `authority-head
advance` must have *no* directly callable public API, and requiring it to name a
further appended record would recurse.

So: **one executable admission registry is authoritative**, each row declaring
which projections it must possess, and unit 0a asserts reachability invariants
rather than set equality:

- every mutation sink in the authority store **and the anchor** is reachable
  **only** through an admitted row;
- every external entry point maps to **exactly one** row;
- **derived-only rows have no external entry point at all**;
- every validator, exclusion, and transition is exercised by **both positive and
  negative** tests.

That closes the failure the equality test could not see: an authority path
nobody declared is now unreachable rather than merely unlisted.

Two distinctions round 7 forced. **Capability issuance is not capability
response** — a capability is minted when the request opens, before any target
answers, so "the target session decides" was wrong for issuance and right only
for redemption. And **authority-head advancement is derived, not decided**: it
is the mechanical consequence of an admitted append, so it has a row saying
exactly that rather than implying someone authorizes it.

An operation absent from this matrix is inadmissible.

#### Release acceptance and genesis

Round 6 found the sharpest hole: `independent acceptance decision` was a
*field*, so the writer would have had to either originate the judgment —
violating its own contract — or seal whatever a caller asserted, which is
`set_by=console` a fourth time. And the first Phase A release would have
self-sealed using the very writer it was accepting.

- `release-acceptance` is a **typed request** (§6b), bound to the exact release
  tree and the acceptance evidence it rests on.
- The **independent verifier validates the whole decision chain**, not merely
  that a seal verifies: which source decided, under which admission rule, with
  which evidence.
- **Genesis names its trusted parties** rather than gesturing at them. Round 7
  was right that "pinned out of band" and "something that is not the writer" do
  not identify anyone, and that a verifier shipped by the unaccepted release just
  relocates self-verification into another binary. The root is:
  1. an **authenticated local operator** — a human, not a process;
  2. a **bootstrap verifier pinned independently of the candidate release**, so
     it is not a binary the release itself produced;
  3. an **independently protected anchor store**.
- **Crash boundaries, actually enumerated.** Round 8 caught the previous draft
  saying "crash boundaries are enumerated" and then enumerating none. The states
  between a log append and the anchor advance, with the recovery for each:

  | observed state | meaning | recovery |
  | --- | --- | --- |
  | pre-append | nothing durable | no effect; retry is safe |
  | log durable **but torn** | an incomplete final frame — an uncommitted crash tail | truncate the torn frame; this is the only discard permitted |
  | log durable and complete, anchor old | the append survived, the head did not advance | **replay-forward**: validate against the anchor's position and advance |
  | log durable and complete **but invalid** | a complete record that fails validation — corruption, a writer defect, or a fork | **quarantine the store**; operator ceremony required. Round 9 caught the previous draft discarding this together with a torn frame under one word, "invalid", which would have concealed exactly the case fail-closed recovery exists for |
  | log durable, anchor new | committed | nothing to do |
  | anchor new, log record missing | the head names a record that is not there | **fail-closed and stop.** This is either corruption or rollback; it is never repaired automatically, and the authority store is unusable until an operator ceremony resolves it |

**What this root does not resist**, stated as plainly as §4c states its own
bound: a compromised OS account, root, a same-uid attacker, a compromised
bootstrap verifier, or a compromised operator. Recovery from any of those is a
**new ceremony**, not a repair. This is a provenance and accident boundary at
uid granularity — the same honest bound the rest of the plan claims, and no
more.
- **Canonical, type-tagged payloads** and **domain-separated keys or subkeys**,
  so an artifact of one type can never be replayed as another.
- **Key identity and epoch** on every seal, governed by an explicit state
  machine — `active → verify-only → revoked`. Round 6 was right that "stale
  epoch rejected" conflates two different events: **routine rotation** moves a
  key to `verify-only`, where existing receipts remain valid *as historical
  evidence* but issue nothing new; **compromise revocation** moves it to
  `revoked`, where its artifacts stop being current authorization and
  re-enrollment and re-acceptance are required. Who may authorize each is part
  of the admission matrix, not an operational detail.
- **A durable, independently anchored authority head.** A sequenced signed log
  detects malformed edits but cannot by itself detect the ledger *and* its head
  being restored to an older, perfectly valid snapshot. The anchor and its
  fsync/recovery ordering are specified, and rollback is a fail-closed error.
- **Durable append semantics**, and **independent read-only verification** —
  something other than the writer must be able to check a seal, or "sealed"
  means "the writer says so."
- **Fail-closed recovery.** Writer compromise invalidates its epoch and forces
  re-enrollment and re-acceptance. **There is no unsigned fallback path**, which
  is the failure mode that would otherwise quietly undo all of this.

The writer is the smallest component in Phase A and the one with the most tests.
Its concentration is the design; its narrowness is the mitigation.

### 6a. Identity, spawn, and reconciliation

No shipped lock can make a coordinator unique: `meta.lock` (`loop-journal:372`)
guards short store mutations and `console.lock` (`loop-console:362`) proves only
the console singleton.

Round 2 also caught the round-1 spawn protocol being **temporally impossible** —
it required a durable record of the child's PID and PGID written *before* the
child exists. Corrected to a four-stage protocol:

1. **Reserve** — persist an attempt reservation (node, spec digest, attempt id,
   request digest, expected preconditions) **before** any spawn.
2. **Spawn behind a no-effect barrier** — the child starts but cannot cause an
   effect yet.
3. **Observe and persist identity** — record PID/PGID plus a non-reusable start
   token, and verify the observed child is the one just launched.
4. **Release the barrier** — only now may effects occur.

A crash in stages 1–3 is provably effect-free. A crash after stage 4 is
`unknown-outcome`, resolved by the operation's retry class (§4b).

**The recorded process must be the process that can cause effects.** Round 3:
the coordinator spawns an *adapter*, but codex and grok create new-session
descendants and cursor has a different foreground topology, so one recorded
PID/PGID can name the adapter and miss the process still able to act. The
adapters therefore need a **handshake** that reports both the adapter's and the
effect-child's identity and start token, forbids unreported process-group
escape, and places the no-effect barrier **before every adapter mutation** —
not merely before the adapter starts. Reconciliation inspects the full recorded
process tree; quiescence means the whole tree is quiet, not that the parent
exited.

Naming the four stages correctly: this is a **four-stage** protocol. An earlier
draft called it two-stage while listing four.

Also required before any node executes: a dedicated long-lived coordinator lock
distinct from `meta.lock` and `console.lock`; an instance epoch / fencing token
so a stale instance cannot act; restart reconciliation resolving every in-flight
attempt to a terminal state or `unknown-outcome`; and sleep/wake revalidation.

Foreground operation makes this tractable — the user is present when it starts
and when it dies. Resident operation waits until this contract is proven.

### 6b. The authority line, as a protocol

Round 1: "schedule but never judge" was unenforceable and insufficient. Round 2:
calling the coordinator a "validator of externally supplied decisions" was the
same prose with a new noun, because no request/decision protocol was specified.

**The protocol** (defined in Unit 0a, before anything executes):

| request type | asked of | answer binds |
| --- | --- | --- |
| `review` | agent session | verdict, reviewer identity, reviewed content digest |
| `triage` | agent session | gate-red disposition: fix / park / escalate |
| `scope-change` | user | the work changed character; standing authorization does not extend to it (`SKILL.md:222`) |
| `approval` | user | the §4c action envelope |
| `attestation` | user | quiescence after `unknown-outcome` — never retroactive success |
| `observation` | user | a manual/interactive check (§4d), bound to the attempt and content |
| `design-decision` | user | a version decision or equivalent judgment with no mechanical answer |
| `ceiling` | user | doctrine's manual ceiling — the work cannot proceed unattended |
| `safety-boundary` | user | a safety/correctness boundary would soften (`SKILL.md:196`) |
| `mechanism-closure` | the independent verifier session for that mechanism; the implementing session is excluded | mechanism id (P1–P5), conformance evidence, verifier identity (§6c) |
| `segment-discharge` | authenticated human | the complete policy accumulator digest (§4c) |
| `release-acceptance` | separately authenticated human or independent reviewer session; builder/coordinator/writer **mechanically excluded** | the exact release tree and its acceptance evidence (§6c) |

Each request has an id, a scope, an expiry, and cancellation semantics. This is
now closed against doctrine's escalation paths — round 3 found `triage:escalate`
had nowhere typed to go.

**Answers carry a capability, not a claimed identity.** Naming a permitted
"actor class" in the event would reintroduce exactly the caller-supplied
provenance that §4c rejects. "Derived from the actual target" was still too
loose to implement, so the mechanics:

- The capability is an **unpredictable one-shot secret**, minted per request and
  bound to `{request_id, target session + start token, scope, expiry, mode,
  protocol version}`. Only its hash is stored.
- **Delivery is targeted, and the exclusions are the substance.** The secret
  travels over a private inherited descriptor or an authenticated local channel
  bound to the recorded PID and start token. It is **never** placed in argv, the
  environment, a repository file, a transcript, or a log — each of which would
  expose a bearer secret to exactly the processes it is meant to exclude. Human
  capabilities exist only inside the authenticated console.
- **Redemption and the answer are one durable append** under the writer lock,
  which validates open state, target, mode, expiry, and cancellation **before
  fsync**. Two records would let a crash spend the capability without recording
  the answer, or record an answer while leaving the capability reusable.
  **Duplicate redemption fails deterministically**, and cancellation or expiry
  racing a redemption resolves inside that same transaction rather than beside
  it. A response event without a redeemed capability is **rejected**, not merely
  unattributed. The shipped journal validates fields, not redemption
  (`loop-journal:617`), so this is Unit 0a work, not an assumption about
  existing code.
- **Mode is part of the binding.** Every Phase A capability and approval envelope
  carries an `execution-disabled` domain and is **permanently ineligible in v2**.
  Otherwise dry-run could mint approvals that a later executing build consumes —
  a Phase A that quietly pre-authorizes Phase B. **Every
case not mechanically decidable blocks**; blocking is designed behaviour, not a
failure state.

Stated plainly: with journal events writable by any process running as the
user, this is **single-writer convention plus provenance, not an OS boundary**.
The plan does not claim more.

---

## 7. Scope — this plan is Phase A

Round 3's verdict: the architecture is converging, but every open BLOCKER sits
where evidence turns into authority and effects. Building all twelve units as
one release would put the executor on top of seams that are not yet
mechanically closed.

**So `task-graph-v1` is Phase A: everything needed to model, validate, and
observe the loop, with no production effects.** Execution is `task-graph-v2`,
a separate plan requiring its own consensus review, gated on §7b.

**What Phase A is, stated plainly:** it is **scaffolding with real diagnostic
value — not a standalone orchestration product.** It validates graphs, exposes
missing or ineligible evidence, simulates blocking, and gives an audit canvas
over runs it did not cause. It does **not** execute the graph, and it does not
deliver this document's opening promise of orchestrating the loop. Judge it on
control-plane correctness and on the defects it surfaces, not on task
throughput. The plan says this rather than claiming standalone value it does not
have.

**Ship first, independently of this plan:**

- **0b — gate verdict fix.** `emit_result` journals the raw suite exit as though
  it were the gate's verdict (`run-gate.sh:318-319`). Add an explicit verdict
  field, **keep the raw suite exit separately**, and regression-test every
  exit-zero-but-red path. A defect in *merged* code; it should not wait for this
  project (Q7).

**Phase A — this plan:**

1. **0a — event vocabulary, reducer, and the trusted writer** (§6c). The writer
   is the first thing built and the most heavily tested: typed APIs, exclusive
   authority-store lock, domain-separated keys with epochs, independent
   read-only verification, rotation and fail-closed recovery. It also carries the
   **executable admission registry** and its invariants (§6c): every authority-
   store and anchor mutation sink reachable only through an admitted row, every
   external entry point mapping to exactly one row, derived-only rows having no
   external entry point, and every validator/exclusion/transition exercised by
   positive **and** negative tests. Plus the full request-kind × source-state
   cross-product.
   The vocabulary is versioned and covers lifecycle transitions, request/response
   pairs, operation start/effect/result, approval grant and consume,
   reconciliation, `graph-diverged`, and the §3b assurance fields — plus a
   reducer and defined compatibility with existing schema-1 history, in which
   absent assurance always reads as the weakest value.
2. **Logical-repository registration** (§5b) — sealed initial registration and
   rebinding, one-to-one common-dir mapping, execution roots as separate
   subjects. Catalog scope depends on it, so it precedes the catalog.
3. **Policy kernel + sealed standing authorization** (§4c). The pure versioned
   lattice — laws, ordering, monotonicity, alias closure — the **canonical
   segment accumulator** with its per-parameter folds and sealed
   `segment-discharge`, and the sealed standing-policy artifact it takes as
   input. Split-versus-unsplit equivalence is one of its acceptance tests. Round 6 found this
   inverted: catalog enrollment binds a policy version, so the catalog cannot
   precede the thing that defines it. Request delivery and the discharge UI stay
   later; only the kernel moves up.
4. **Operation catalog and its root of trust** (§4b): content-addressed entries,
   default-deny, enrollment sealed atomically with its gesture, versioned
   pinning, the sequenced revocation ledger, and resolution proofs carrying the
   observed revocation generation.
5. **Graph file + validator.** Schema — including the `investigation` node type
   and declared mandatory-observation phases (§4d) — fail-closed validation,
   catalog-ID binding, semantics/layout split, round-trip.
6. **Run snapshot + evidence correlation.** Bind a run; join node attempts to
   journal evidence; every axis explicitly `unknown` when unproven.
7. **Request/response + mandatory-approval protocol** (§6b, §4c): the closed
   policy lattice, one-shot response capabilities with targeted delivery and
   transactional redemption, and the `execution-disabled` domain marking.
8. **Minimal authenticated discharge UI.** The console path through which a
   human actually answers a request and grants an envelope. Round 3 caught the
   round-3 phase split preserving the original inversion by leaving this until
   after execution — without it, §4c's required human gesture is never exercised
   end-to-end.
9. **Coordinator identity and lifecycle** (§6a): dedicated lock, fencing,
   four-stage spawn, adapter identity handshake, reconciliation, sleep/wake —
   with failure injection, executing nothing.
10. **Coordinator dry-run.** Topological selection, staleness, divergence, and
   blocking decisions with no side effects.
11. **Canvas, read-only.** Plan graph, node states, run overlay, blocked states.

12. **Release acceptance** (§6c). The `release-acceptance` request, the
    independent verifier and its `mechanism-closure` counterpart, the exclusion
    rules, the designated-acceptance-platform rule (§6), and the genesis
    ceremony —
    an explicit final unit rather than prose after unit 11, because it is the
    thing that makes the Phase B interlock real.

Literal C/M/T/G/Gate lists are written per unit at kickoff — round 2 confirmed
that deferral is acceptable, because the design's safety mechanisms are units
here rather than implementation detail.

**Phase A is a separately accepted release**, and its acceptance produces a
**gate receipt**. Round 4 was right that the previous sentence was still a
promise — an underspecified check is satisfied by a copied or fabricated file.
The receipt is:

- **stored out of repo and sealed by the trusted writer** — never a file the
  graph, the catalog, or a dispatched implementer can produce;
- **bound to** the exact Phase A release tree, the schema and reducer versions,
  the catalog and policy protocol versions, the acceptance-suite result digests,
  and the independent acceptance decision;
- **invalidated** when any shared schema, reducer, or control-plane component it
  names changes — a receipt for a tree that no longer exists proves nothing.

**The Phase B entry point requires this receipt *and* separately bound closure
receipts for P1–P5** (§7b), and rejects an incompatible or superseded version.
That is the interlock: v2 has no path to an effect capability without them
(Q8).

---

## 7b. Phase B entry preconditions

`task-graph-v2` may not begin until each of these is mechanically closed and
reviewed. They are round 3's open BLOCKERs, recorded with their required fix so
the successor plan starts from them.

| # | seam | what must be true before execution ships |
| --- | --- | --- |
| P1 | **Gate is sampled, not enforced** | `run-gate.sh` captures content before and after (`run-gate.sh:507-512`), so a suite can change tree T→T′, pass against T′, and restore T with every digest agreeing. Gates must run against a verified immutable snapshot, with read-only access enforced for the **whole process tree** and descendant quiescence required before success is recorded. |
| P2 | **Declared capabilities and declared effects are both unenforced** | Fixed argv is not fixed behaviour: an approved package runner interprets repository-controlled scripts and can write the tree, move refs, reach the network, or leave persistent children while labelled `reads tree`. Capabilities must derive from **enforced containment** of the transitive process tree; anything uncontainable is rejected or classified broad-effect. **Round 9 widened this**: it is not enough to bound capabilities, because Phase A's accumulator now reasons over **canonical primitive-effect descriptors** (§4c). P2 must enforce or observe the concrete **primitive-effect envelope across the whole process tree**, so an executor cannot perform more primitives than were accumulated. |
| P3 | **The authority-to-effect handoff must be atomic** | §4c requires ref CAS / conditional provider request / lease, and each effect contract must name its primitive; effects whose targets cannot enforce the condition atomically stay manual-only. **Round 9 widened this too**: binding target preconditions is not sufficient while the *authority* state moves independently. Acquiring an effect must **atomically reserve and fold the proposed effects into the accumulator** and bind, in one step: the current accumulator, repository identity and incarnation, policy and standing-authority state, catalog revocation generation, the approval envelope, and the coordinator's fencing token. Otherwise two concurrent actions each evaluate against the same pre-effect accumulator and both pass. |
| P4 | **Landing is not yet an atomic contract** | §4a's three re-gating paths are necessary doctrine (`SKILL.md:179-181`) but a coordinator can still lose a race between verification and the provider's merge. Needs provider-specific atomic landing (expected head/base bound to the provider operation, or landing the exact gated object under a lease), review and gate evidence for the final integration content, and the §3 transformation relation proven mechanically. |
| P5 | **Execution-root and process identity** | §5b and §6a define the model; v2 must implement per-backend execution/output contracts, common-dir ref fencing, typed worktree create/retire, and the adapter handshake that records the effect-child, not just the adapter. |

## 8. Reuse map

| shipped in loop-console-v1 | status here |
| --- | --- |
| `loop-journal` event log | **schema replaced, history compatible** (Unit 0a) — round 1 refuted "reused as-is"; round 2 refuted "identity fields are enough" |
| `run-gate.sh` binding truth table | **reused by `run-suite` only**, after the Unit 0b verdict fix; it is a test gate, never a general executor |
| `loop-calibration` store | **standing policy only** — it is not approval evidence, and it is the model for the out-of-repo operation catalog |
| adapters' `dispatch.start/end` writers | reused; must gain node/attempt binding and a request digest |
| D7 loopback security handshake | reused; the canvas and every decision UI are served by the same authenticated server |
| `loop-index` derived views | **rewritten** — current joins are run-scoped and cannot correlate nodes |
| console list rendering | replaced by the canvas |
| "one active run per workspace" | retained for v1 (serial execution) |
| implementation-loop skill as orchestrator | demoted to the `unit` node's executor |
| the doctrine in `SKILL.md` | **treated as normative** — §4a regressed off `SKILL.md:179-181` once; the plan may not weaken doctrine it inherits |

---

## 9. Risks

| risk | mitigation |
| --- | --- |
| A committed graph becomes an execution vector | Out-of-repo approved catalog (§4b); untrusted-file rule (§5b); policy-generated approvals the graph cannot omit (§4c) |
| Correlation mistaken for truth | §3's request + result digests, actor provenance, and explicit verdicts |
| Divergence fires on the loop's own normal Git transitions | §5b: semantics frozen, checkout not; predicted transitions declared as CAS preconditions; separate worktrees |
| `unknown-outcome` retried into a duplicated effect | §4b retry classes; atomic staging, ref CAS, immutable external request IDs |
| Approval replayed, or consumed after preconditions moved | §4c envelope + hashed nonce + atomic consume + revalidation at consumption |
| Something lands ungated | §4a's pre-merge gating paths from `SKILL.md:179-181`; `landed-but-ungated` is a reported state; **and P4 must close the race before v2 lands anything** |
| The registry becomes an escape hatch | Closed catalog; an unlisted need means the taxonomy is unfinished (Q6), not that a generic entry is added |
| Phase B starts before the evidence model is real | §7's versioned gate receipt is required by the Phase B entry point — an interlock, not a promise |
| The graph becomes a prettier list nobody edits | Deferred to v2 with canvas editing — Phase A's read-only canvas cannot answer it, and the plan should not pretend otherwise |

---

## 10. Non-goals for v1

**All production effects** — operation execution, unit execution, and canvas
editing are `task-graph-v2` (§7, §7b). Resident/background execution (§1a).
Concurrent execution. Multi-workspace. Remote or multi-user access. Distribution beyond the
existing Cursor plugin build. Live model output for cursor/grok (*assumed* blocked
upstream: both CLIs emit JSON only at completion — from loop-console-v1's
transcript work, not re-verified at this head). Graph templates or a node
library. Surviving logout or reboot — §7 is a foreground tool, and the plan
promises no progress past a judgment block (Q2).

---

## 11. Open questions for review

Settled across rounds 1–3, recorded so they are not relitigated:

- **Q1** Staleness is a content-addressed eligibility predicate over the node's
  **effective policy**, resolved operation version, input, and parent-output
  digests — not the whole calibration store. Evidence is never deleted; an
  upstream re-run producing an identical integrated output invalidates nothing.
- **Q2** Foreground coordinator (user reversal, round 2). Overnight use relies
  on the user's own terminal multiplexer and keep-awake choice; the plan
  promises neither survival across logout/reboot nor progress past a judgment
  block.
- **Q3** `.olddonkey-loop/graph.json`; semantics tracked, layout untracked and
  per-machine, with the ignored path named and startup distinguishing a
  committed pinned graph from a bound dirty snapshot.
- **Q4** Review stays an intrinsic mandatory phase of `unit`, with its
  request/response generated by the state machine — never made optional through
  graph wiring.
- **Q5** Reframed (round 2 was right that the original was mis-framed): expected
  ref transitions never diverge a run. An unplanned semantic change creates a
  **successor run** that may reference still-valid content-addressed evidence.
  An active run is never migrated in place.
- **Q6** The registry was not closed at round 2; §4b/§4d finish the taxonomy
  (`integrate-candidates`, manual observation, version-decision) rather than
  adding a generic entry. **Open:** does it hold against a second real graph?
- **Q7** Unit 0b ships independently, before this project, and the plan then
  depends on that fixed commit.

Answered at round 3, recorded:

- **Q6** The registry is now closed against the *known* history — round 3
  confirmed it covers base-sync, CI-wait, package-build, installer-suite,
  hotfix-unit, and candidate integration with no new mechanical operation
  required. It remains open against a second real graph.
- **Q8** Phase A is a separately shipped and accepted release with a versioned
  gate receipt enforced at the Phase B entry point (§7), not the first half of
  one implementation.
- **Q9** Default-deny, content-addressed, authenticated one-shot enrollment,
  new IDs on change, run-pinned catalog version, fail-closed revocation (§4b).
- **Q10** Split into `produce-baseline` (immutable artifact bound to its base)
  and `activate-baseline` (base-ref CAS). A moved base makes the artifact
  ineligible, never retrospectively current (§4b).

Answered at round 4, recorded:

- **Q11** Phase A is **scaffolding with real diagnostic value**, not a
  standalone orchestration product — now stated outright in §7 rather than
  implied.
- **Q12** Yes. P1 (endpoint-sampled gates) affects every gate the loop runs
  today and gets its **own immediate hardening plan**, separate from both this
  plan and Unit 0b — it is larger than 0b because it needs containment and
  process-tree quiescence. Until it lands, Phase A labels existing gates
  `input_isolation=endpoint-sampled` and refuses to treat them as completion
  evidence (§3).
- **Q13** No generic transformation relation. Phase A makes **identity the only
  completion-eligible relation**; everything else is an unproven candidate. V2
  may add closed, schema-defined, provider-specific proof kinds only once P1,
  P2, and P4 establish what review and gate could observe. Tree equality alone
  is never sufficient (§3).

Answered at round 5, recorded:

- **Q14** P2, P3, and P5 are not inert — but they shape Phase A's **schema**
  rather than its implementation, through the §3b claim-versus-proof envelope.
  Nothing becomes verified without its closure receipt. The catalog revocation
  generation belongs to **P2**'s resolution proof — round 5 assigned it to P3 and
  round 6 corrected that.
- **Q15** Hermetic fixtures are definable, but only as fixed selftest assets
  outside the production coordinator's runtime surface — §6 now draws that
  boundary explicitly, because a generic fixture command would be the escape
  hatch.
- **Q16** Keep **one** logical trusted writer; splitting into several same-uid
  writers would add distributed transactions without a real trust boundary.
  Concentration is mitigated by making the writer very small and
  domain-judgment-free (Q17's correction of this wording), with typed APIs,
  domain-separated keys, independent verifiers, append-only audit, key epochs and
  rotation, and fail-closed recovery with **no unsigned fallback**.
  Logical-repository registration is recognised as a sealed type in its own right
  (§5b).

Answered at round 6, recorded:

- **Q17** "Policy-free writer" was the wrong phrase. The writer is
  **domain-judgment-free but admission-policy-enforcing**: it never judges a
  review, a release, or a grant, and it always judges admissibility. Every sealed
  type now declares a decision source, a validation rule, and an
  anti-self-approval rule (§6c). Acceptance gets its own protocol and a genesis
  ceremony.
- **Q18** Yes — the policy kernel was inverted behind the catalog that binds its
  version. The kernel and sealed standing authorization move to unit 3, before
  catalog enrollment; release acceptance becomes an explicit final unit rather
  than prose.

Answered at round 8, recorded:

- **Q19** Totality **cannot be established by inspection** — it failed three
  rounds running. It is enforced by unit 0a against the **executable admission
  registry**, using the reachability invariants in §6c. (Round 9 first proposed
  exact set equality across five sets; round 10 refuted that — five sets can omit
  the same authority path and still compare equal, and derived rows are not
  one-to-one with public APIs. The registry invariants replace it.)
- **Q20** The named operator, the independently pinned bootstrap verifier, and
  the protected anchor form an honest root — one that rests on stated external
  assumptions rather than proving itself, which is the most any root does. §6c
  states the exclusions plainly.

Answered at round 9, recorded:

- **Q21** Individual folds stay in unit 3. The associative **fallback is
  lossless ordered descriptor-sequence concatenation**; semantic compression is
  optional; undefined or unbounded composition becomes `manual-only`. Property
  tests cover associativity, identity, canonical encoding, cross-operation
  normalisation, split/unsplit equivalence, policy-version changes, and overflow
  without truncation. No currently named operation makes the design impossible.
- **Q22** Keep P1–P5; no sixth is needed. P1, P4, and P5 remain correct as
  written. **P2 and P3 were rewritten** (§7b) — P2 to enforce the concrete
  primitive-effect envelope rather than only capabilities, P3 to become the
  atomic authority-and-accumulator-to-effect handoff.

Closed at acceptance:

- **Q23** No remaining plan-level authority rule, state transition, or trust
  boundary needs more prose. Validator bodies, fold definitions, encodings, and
  test vectors are settled through implementation.

---

## 12. Acceptance, and the falsifier to carry into implementation

Accepted at round 11 after 11 rounds of adversarial read-only review. Across
those rounds the review reversed two decisions settled at kickoff, refuted the
original two-graph model using this repo's own history, found a live defect in
merged code (§7 unit 0b), and rejected four successive versions of the
authority model before this one.

**Implementation order:** unit 0b ships first and independently; then Phase A
unit 0a.

**The named falsifier.** Acceptance is not the end of scrutiny — this is the
evidence that would indict the *design* rather than the implementation:

> Unit 0a must demonstrate that every authority-store and anchor mutation is
> **structurally** reachable only through the admission registry, and that crash
> injection across compound redemption can never produce "answer recorded,
> consequence absent" or the reverse.
>
> If satisfying that requires a generic sealing or append escape hatch, a
> directly callable derived transition, or recovery that invents authority —
> **doubt the design, not merely the implementation.**

Each of those three is a mechanism this plan explicitly forbids. If the first
real code needs one, the control plane described here is not implementable as
written, and that is a plan-level finding rather than a coding problem.
