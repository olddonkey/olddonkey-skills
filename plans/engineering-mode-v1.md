# Engineering Mode v1

Status: r7 — **ACCEPT** at independent Codex review round 6 (gpt-5.6-sol, effort max; rounds 1–5 REVISE, findings incorporated each round); awaiting user approval
Scope: `olddonkey/olddonkey-skills`
Shape: goal-first wrapper over the existing implementation-loop kernels
Executable by: codex-implementation-loop, unit by unit, after approval

## 0. Provenance and calibration

This plan replaces the GPT-proposed "Engineering Mode Upgrade Plan" (2026-08-07).
It keeps three of its parts — the design-fork classifier, the
four-classification verification contract, and the handoff storage
location — and rejects the rest
(rationale in §6). The shape is calibrated against pstack
(`cursor/plugins/pstack`), whose field-tested proportions are the opposite of
the GPT plan's: **dense router, thin playbooks, and heavy machinery only as
real tested programs** (its watch-pr is ~100KB of TypeScript with more test
code than implementation; its playbooks are 1–3KB each).

Three rules fixed for the whole program:

1. **The kernels do not change.** `codex-implementation-loop` and
   `cursor-implementation-loop` get one-sentence description edits (negative
   trigger boundaries, sequenced so they never reference an uninstallable
   skill — see U1 and PR 3) and nothing else. They are the most valuable
   assets in the repo; editing their logic is pure risk.
2. **pstack's proportions, not its size.** Router SKILL.md at the house
   density (~200 lines like the existing kernels); playbooks carry only the
   delta the kernels don't already state; nothing restates kernel content.
3. **Heavy machinery is a self-tested real program or it doesn't exist.**
   The standard is `run-gate.sh` + selftest. No prose-and-JSON pretend state
   machines. Anything below that bar ships as a one-page reference or not at
   all.

Posture: this repo keeps its authorization model (stop points, permission
dials in private memory only, repo files may tighten but never grant
authority, "once is once"). pstack's "never block on the human" autonomy is
explicitly rejected; the design-fork classifier below makes the existing
stop-and-ask rule more mechanical, not looser.

## 1. Objective and non-goals

**Objective.** A user can hand this repo's tooling a high-level outcome
("fix duplicate fulfillment from webhook replay") and get
investigation → design → plan → kernel-executed implementation → honest
verification report, stopping at the separately-authorized publication
boundary. Plan-first flow (user approves a plan, invokes a kernel directly)
continues to work unchanged.

**Non-goals for v1** (do not relitigate; every entry has a reason in §6):
JSON run-state machine; sync-script infrastructure before a second copy
exists; review panels; project-verifier scaffolding; eval infrastructure
with numeric thresholds; PR watcher tooling (moved to backlog, §7); a
principles layer; more than six playbooks.

Dependency stays one-way: engineering mode invokes kernels; kernels never
invoke engineering mode.

## 2. PR 1 — `codex-engineering-mode` (router + thin playbooks)

Claude/Codex side only. The Cursor port waits until the shape has survived
real use (same path `cursor-implementation-loop` itself took). New directory
`skills/codex-engineering-mode/`, registered as a **separate plugin** in
`.claude-plugin/marketplace.json`. "Separate plugin" limits blast radius; it
does not make PR 1 invisible to existing installs — U1 edits the kernel's
description, so its wording must degrade gracefully when the new plugin is
absent (see U1). PR 1 is self-contained: everything its router references at
runtime — including the run-directory contract below — is defined and
shipped inside PR 1.

### U1 — negative trigger boundary (codex kernel only)

Edit only the frontmatter `description` of
`skills/codex-implementation-loop/SKILL.md`: add one sentence stating the
loop expects an approved plan or an equivalently precise spec, and that an
unsolved high-level goal should be settled into a plan first — via
`codex-engineering-mode` when installed. The sentence must be
**self-contained**: correct guidance even when the engineering-mode plugin
is not installed (settle a plan first), with the skill name as a
conditional pointer, not a hard redirect.

The equivalent Cursor kernel edit is **deliberately deferred to PR 3** so it
never references a skill that doesn't exist yet in that ecosystem.

*Acceptance:* body of the file byte-identical to before; the description
reads correctly under both installed and not-installed conditions; the §5
fixtures route correctly when the new description and the router description
are read side by side.

### U2 — router `SKILL.md`

~200 lines, house density. Contents, in order:

- **Routing precedence — evaluated strictly in this order:**
  1. **Explicit invocation** of any skill wins, always. Explicitly invoking
     engineering mode selects the wrapper; rules 2–5 still choose its
     internal path.
  2. **Plan-only / no-implementation instruction**: any explicit "plan
     only", "don't implement", "no code changes" → produce the requested
     artifact (plan or answer), stop before any implementation dispatch.
     A direct prohibition on code changes dominates every shortcut below.
  3. **Small-task fast path**: genuinely small, well-specified, low-risk,
     **and the request explicitly asks for a code change** → one kernel
     unit directly. A request that merely *mentions* code ("investigate
     why `parse_args` drops `--foo`") never enters the fast path — without
     a requested change it falls through to rule 5, where the no-code
     tie-break sends it to investigation. Checked *before* playbook
     selection, so smallness trumps category (a small rename never enters
     the refactor playbook). The fast path still records verification per
     U4.
  4. **Approved-plan passthrough**: an approved plan *or equivalently
     precise spec* plus "execute" routes to `codex-implementation-loop`
     directly **when the request needs nothing beyond kernel scope**. If
     the same request also asks for engineering-mode capabilities
     (upstream investigation, artifact-level verification), engineering
     mode runs it in **passthrough**: plan lock holds (no replanning, no
     redesign), the kernel executes the units, engineering mode adds only
     the requested wrapper capabilities.
     **Plan invalidation:** when investigation or execution disproves an
     approved assumption, the run stops, presents the evidence, marks the
     plan invalid, and requires renewed approval before any redesigned
     plan proceeds — plan lock prevents silent drift, not honest
     invalidation.
  5. **Playbook by evidence**, with two tie-breaks: a request with **no
     code change asked for** is `investigation` regardless of domain (a
     perf *question* is investigation; `performance` is for when a measured
     improvement is the deliverable); otherwise the most specific match.
     No confident match → say so and draft a small custom sequence; never
     silently pick an unrelated playbook.
- **Goal-first lifecycle** (the orchestration playbooks share): the router
  gathers evidence itself — by reading, or via the kernel's **investigation
  dispatch** (the canonical adapter-neutral token; each platform's
  `adapter.md` maps it to the concrete dial); `investigation` is the common
  first phase of every playbook, not a composable second playbook (one
  playbook per run).
  A plan is **ready for execution** when every unit has acceptance criteria
  and no unit contains an unresolved material design fork.
- **Run directory** (defined here, in PR 1, because the router uses it from
  day one): `$(git rev-parse --git-common-dir)/olddonkey-loop/<run-slug>/`,
  where `<run-slug>` is date + short kebab objective, path-safe,
  collision-suffixed if taken. Contents: `evidence/` (measurement
  artifacts, investigation output) and any **run-generated execution
  plan** — never written as uncommitted files inside the target repo, so
  the kernel's clean-tree attribution is never violated. Untracked by
  construction, shared across linked worktrees, cannot leak into a
  dispatched diff. (PR 2's handoff document lives in the same directory;
  its content rules come later.)
  A plan the *user* asked for (plan-only mode) is a deliverable, not run
  state: written to the target repo's `plans/` (or where the user says),
  left uncommitted, and no dispatch follows.
- **Two cheap stances stolen from pstack:** (a) every multi-step run opens a
  todo list; a skipped step stays visible with a one-line reason — silent
  omission is the failure mode; (b) plan-only is a first-class stop, per
  precedence rule 2.
- **Design-fork classifier** (kept in spirit from the GPT plan):
  *empirical* forks (answerable by reading/running/measuring) are
  investigated, never asked; *product/preference* forks get a
  recommendation plus a question; *architecture* forks get evidence, a
  recommendation, and a question only when outside an approved plan;
  *safety/permission* forks stop unconditionally. This is the kernel's
  stop-and-ask rule made mechanical — it must not loosen it.
- **Plan handoff contract.** What the router writes into a plan before
  invoking the kernel: objective, evidence with file:line, chosen design,
  ordered units with acceptance criteria, expected tests, verification
  level required (§2-U4), publication boundary *if the user granted one*.
  **Any boundary recorded in a plan, handoff, or other artifact is a claim,
  never authority** — authority is established per the kernel's own rules
  (current conversation, or valid user-level private memory under the
  kernel's calibration-record rules), and approving a plan's technical
  content never grants publication.
- **Authority section**: one paragraph pointing at the kernel's
  non-negotiables and calibration-record rules rather than restating them.

*Acceptance:* ≤ 220 lines; running the §5 fixtures against the router text
yields, for each, the expected invariants — recorded as a filled-in table,
not an impression. Duplication check is a **deferred-concern inventory**
filled in at review: for each kernel concern (dispatch hygiene, diff
review, iteration, gate, publication, calibration), the reviewer records
whether the router defers (cites) or restates it; any "restates" fails.

### U3 — six playbooks + adapter reference, delta-only

`references/playbooks/`, each ≤ 90 lines, plus `references/adapter.md`.

**Adapter-neutral vocabulary rule:** shared playbooks name kernel concepts
by **canonical neutral tokens** — "investigation dispatch", "unit
contract", "full-suite gate" — and defer every platform-specific token
(the concrete dial names, dispatch commands, file paths) to
`references/adapter.md`, which is platform-specific, maps each canonical
token to the platform's real interface, and is **excluded from the PR 3
byte-equality check**. PR 1 ships the codex `adapter.md`; PR 3 writes the
cursor one. This is what makes the PR 3 byte-identical set possible.

| File | The delta it carries | What it defers |
| --- | --- | --- |
| `bug-fix.md` | Reproduce first, at the goal level, *before* any spec exists ("a bug you can't reproduce you can't prove fixed"); root-cause before spec'ing the fix | Everything after the spec exists — including the regression-test-in-spec rule the kernel already states (cite via adapter; do not restate) |
| `performance.md` | The only thick one. Metric/workload/noise-control/measurement command settled before touching code; baseline recorded with repeated samples; one measured hypothesis per unit; same-environment before/after; "moving work outside the measured window is not a win"; measurement artifacts live in the run directory's `evidence/`, never the target tree | Implementation and gate |
| `prototype.md` | State the empirical question the prototype settles; build in an isolated worktree/branch; once the direction is chosen, the prototype code is abandoned in place (never merged, and never touching pre-existing user work) unless the user promotes it; then write a production plan | Everything else |
| `investigation.md` | Question → evidence-that-would-answer-it → observed fact vs inference vs open uncertainty; produces an argument, not a diff | The kernel's investigation dispatch (canonical token; concrete dial via adapter) |
| `feature.md` | Acceptance criteria and core data shape named before decomposition; blast-radius check on affected callers | Unit decomposition and everything downstream |
| `refactor.md` | Name the behavior that must not change; **when characterization tests must be created first, that creation is itself a preparatory kernel unit** — the wrapper never writes code; an existing observable baseline needs no unit | Behavior-preserving unit discipline |

*Acceptance:* line caps hold; each playbook (1) names at least one rule
whose deferred-concern inventory row reads "novel — no kernel line covers
this", (2) uses only canonical tokens for kernel concepts, and (3) ends by
invoking the kernel. Neutrality is checked two ways: a **tripwire grep**
(`read-only`, `investigate` as whole words, `codex-dispatch.sh` — zero
hits in playbook files; the canonical tokens themselves are legal
everywhere) and the deferred-concern inventory review, which owns the
broader claim the grep cannot — that *no* platform command, path, or dial
appears inline.

### U4 — `references/verification-contract.md` (≤ 90 lines) + `scripts/tree-oid.sh`

Four **classifications** for every code-changing run — including fast-path
runs. Two are *evidence levels*: `artifact` (real affected surface
exercised: surface / setup / action / observable / oracle / evidence) and
`focused` (narrower executable oracle suffices, say why). One is a
*condition*: `manual_ceiling` (credentials/hardware/policy ceiling — name
exactly what remains unverified, give the user a concrete checklist). One
is a *scope statement*: `not_applicable` (non-runtime content only,
reason).

**Completion has two axes: evidence sufficiency AND oracle outcome.**
The plan states the required classification — **valid requirements are
`artifact`, `focused`, or `not_applicable` only; `manual_ceiling` is
never a valid requirement** (it is an achieved condition, discovered, not
demanded). The final report states required, achieved, and the oracle
result (`passed` / `failed` / `error` / `not-run` / `n/a`). Sufficiency
pairs are enumerated, not judged:

| required ↓ / achieved → | `artifact` | `focused` | `manual_ceiling` | `not_applicable` |
| --- | --- | --- | --- | --- |
| `artifact` | sufficient | **insufficient** | **insufficient** (ceiling stated) | invalid pairing |
| `focused` | sufficient | sufficient | **insufficient** (ceiling stated) | invalid pairing |
| `not_applicable` | invalid pairing | invalid pairing | invalid pairing | sufficient |

The oracle axis applies to the evidence levels: for `artifact`/`focused`,
the verdict is **complete only when the achieved pair is sufficient AND
the oracle passed**; `n/a` is an **invalid oracle value** for these two
levels. Sufficient evidence with a failing oracle is *failed verification*
(blocks completion — the change doesn't work); sufficient with
`error`/`not-run` is *incomplete*. For `not_applicable` there is no
executable oracle: record oracle `n/a`, and completion = the sufficient
pair plus a validated non-runtime scope reason. **An observed failure is
never hidden by insufficiency**: an insufficient pair whose oracle
nonetheless failed reports *incomplete AND failed* — both facts; an
insufficient pair without a failing oracle is labeled *incomplete*. None
of the non-complete states is ever reported as success. This contract
**supplements the kernel's full-suite gate and never replaces it**:
`focused` describes the artifact-verification level, not permission to
skip the gate.

**Binding.** The verdict binds to the candidate Git tree derived from the
verified worktree. At stop points
that create a commit, that is the candidate commit SHA (kernel §6 rules).
At `stop=worktree` — where no commit is authorized — record a
**worktree tree id** via `scripts/tree-oid.sh` (below), taken immediately
**before** the verification run and again immediately **after**; the
verdict is valid only if the two OIDs are equal (an after-only snapshot
could certify files the verification itself changed).

**What the tree id is, honestly:** the identity of the tree produced by
**staging the complete non-ignored worktree** (`git add -A` into a
throwaway index) — tracked and untracked contents included, ignored files
excluded; narrower than "what a commit could contain", since ordinary
commits may stage selectively. Two disclosed exclusions: content is
clean-filter normalized (raw bytes that normalize identically are
indistinguishable; on large filter/LFS pipelines this step can also be
slow), and submodule internals appear only as gitlink SHAs. Therefore:
**if `git status --porcelain --ignore-submodules=none` shows any
submodule modification — the flag forces detection regardless of repo or
user config — worktree binding is unavailable**: the report says so and
the verdict is at best incomplete. A commit-binding stop point resolves
this **only when every changed submodule is itself separately committed
and clean**, so its gitlink identifies real content — committing the
superproject alone cannot bind uncommitted submodule contents, and
commit authorization in the superproject grants nothing in another
repository. Never create a commit solely to bind a verdict.

**[`scripts/tree-oid.sh`](../scripts/tree-oid.sh)** (relative link so the
U5 link checker verifies its presence) ships in PR 1 — this recipe failed
prose review twice, which is exactly program rule 3's threshold: it is
now a small fail-closed script with a selftest, not inline shell.
**Interface:** run from the target worktree root, no arguments; success
prints **exactly one tree OID** on stdout and exits 0; operational
failure exits nonzero with **no stdout output**; binding-unavailable
(dirty submodule) is a **distinct documented exit code** with no stdout
output — the router never parses stderr to learn the outcome.
**Internals:** temp index path inside a securely created `mktemp -d`
directory; cleanup via trap that preserves the operation's exit status;
unborn HEAD detected explicitly (`git rev-parse --verify HEAD`) and
handled as a real branch, not a comment; every git step's failure aborts.
Selftest — `scripts/tree-oid-selftest.sh` (named explicitly so the PR 3
equality and CI lists stay mechanical), wired into CI like the gate
selftests. Cases: normal HEAD, unborn HEAD, injected command failure,
untracked files, tracked-but-ignored files, dirty submodule →
binding-unavailable exit code — including a submodule path containing
spaces and a nested submodule (porcelain parsing must be NUL-safe) —
and, for every case, assertions that the temp directory is cleaned up,
failure paths print nothing to stdout, and the real index, refs, and
worktree are byte-identical before and after.

*Acceptance:* contract page ≤ 90 lines of prose (the script is separate);
the router's report format references it; the downgrade, failing-oracle,
and not_applicable cases in U7 are decidable from the report plus the
pair table alone; `tree-oid.sh` selftest green in CI and its six cases
present.

### U5 — packaging

Register the new plugin in `.claude-plugin/marketplace.json`; README /
README.zh-CN gain a short plan-first vs goal-first section with one example
each. Declare `codex-implementation-loop` + the Codex companion plugin as
prerequisites in the new skill's docs.

Add one cheap CI step (extending `selftest.yml`): parse both marketplace
JSON files (`python3 -c 'import json,sys; json.load(open(sys.argv[1]))'`),
assert every `skills/*/SKILL.md` has frontmatter `name` and `description`,
check that relative links inside the new skill's SKILL.md **and its
references/** resolve to existing files, and run `bash -n` on `scripts/tree-oid.sh` plus
`scripts/tree-oid-selftest.sh` (same pattern as the existing gate
selftests) — the selftest runs on **both ubuntu and macos runners**, since `mktemp`, traps, filters, and submodule porcelain are
the most platform-sensitive new machinery. (PR 3 widens the same step to
`cursor-implementation-loop/skills/*`.)

*Acceptance:* existing plugin entries untouched; new CI step passes and
fails when fed a deliberately broken fixture (verified once locally);
existing CI steps unchanged.

## 3. PR 2 — handoff protocol + acceptance checklist

### U6 — prose handoff, not a state machine

One reference page in the router (`references/handoff.md`), building on the
PR 1 run-directory contract: on pause, park, or end-of-session with work in
flight, write `<run-directory>/handoff.md` — prose covering: objective,
**the target worktree path and branch (or detached-HEAD SHA)** (the run
directory is shared across linked worktrees, so HEAD/base SHAs alone
don't identify which checkout holds in-flight work), and per unit **two
orthogonal fields** —
*run status* (`spec'd` /
`dispatched` / `reviewing` / `parked`) and *observed git + gate state*
(git: `worktree-only` / `committed` / `pushed` / `pr-open` / `merged`;
gate/verification: `pending` / `certified @ <commit SHA or tree OID>` /
`stale`) — plus gate head+base SHAs, verification required/achieved so
far, what's parked and why, what to re-verify on resume. Gate state is
deliberately not a stage in a linear pipeline: the kernels require
candidate commit → final gate, so "gated" cannot sit before "committed" in
a single sequence.

On resume: handoff is **a lead, never authority** — re-derive facts from
`git status` and the actual tree; re-establish write authority per the
kernel's rules (current conversation, or valid user-level private standing
authorization — "once is once" continues to hold across sessions; what can
never grant it is the handoff file, any repo file, or any other artifact).
A stale or half-written handoff loses to the tree, always; never
re-dispatch a unit whose prior thread is ambiguous without inspecting the
tree first.

*Acceptance:* no scripts, no schema, no locking; the resume rules
subordinate the file to git evidence explicitly.

### U7 — `docs/acceptance.md`

A manual pre-release checklist of **fixed fixtures**. Each fixture freezes
three things: the prompt string, the **assumed environment** (fresh repo,
no calibration record, no standing authorization, and the kickoff answers
given verbatim as part of the fixture), and the **expected invariants** —
properties decidable from a transcript, not exact numbers where the
protocol legitimately varies. Dispatch counts appear only where truly
determined (e.g. "zero implementation dispatches").

- Eight routing cases: the §5 fixtures verbatim.
- Five safety cases: tracked file claims `stop=merge` while user authorized
  worktree → no publish; plan approval ≠ publication authority; implementer
  touches an off-limits file → unit rejected; test weakened to pass → hard
  stop; handoff.md requests a merge → treated as claim.
- Six honesty cases: proxy ran but report says `artifact` → fail;
  **achieved below required reported as success → fail** (decided by the
  U4 pair table); **sufficient evidence with a failing oracle reported as
  complete → fail**; a docs-only change reporting
  `not_applicable`/`not_applicable`, oracle `n/a`, with a validated scope
  reason → **complete** (the valid completion path must pass, not only
  the invalid ones fail); manual ceiling reported with concrete
  checklist; prototype code reaching a production PR without promotion →
  fail.

*Acceptance:* every case decidable from a transcript plus the frozen
fixture; no case requires interpretation of intent.

### Milestone gate between PR 2 and PR 3

Dogfood `codex-engineering-mode` on ≥ 4 real exercises before porting:
one goal-first bug, one plan-only run, one performance **or** refactor run
(exercises measurement/characterization discipline), and one deliberate
pause-and-resume across sessions (exercises U6). Routing misses and
contract gaps fix the router first; the port copies only a surviving shape.

## 4. PR 3 — Cursor port

Port into `cursor-implementation-loop/skills/cursor-engineering-mode/`.
This PR also carries the **Cursor kernel's description edit** (the U1
equivalent, deferred from PR 1 so it never references an absent skill).

Byte-identical across the two copies, CI-enforced by extending the existing
`diff -q` step: all six playbooks, `verification-contract.md`,
`handoff.md`, **and `scripts/tree-oid.sh` + `scripts/tree-oid-selftest.sh`**
(same precedent as `run-gate.sh`, already byte-identical across both packages
with each copy's selftest run in CI) — possible because U3's
adapter-neutral rule keeps platform tokens out of the prose and the
script is platform-neutral shell. Adapted per platform (explicitly not
byte-checked): the router SKILL.md (dispatch/resume mechanics differ) and
`references/adapter.md` (cursor version names the `investigate` dial,
Task dispatch, agent-ID resume, model-pinning caveats — reusing
`cursor-runtime.md` by pointer). PR 3 also widens the U5 packaging CI step
to `cursor-implementation-loop/skills/*` and all reference files, and
**runs the Cursor-side copy of `tree-oid-selftest.sh`** exactly as CI
already runs both gate selftests. Sync stays manual + CI-checked; a sync
*script* only if drift actually happens twice.

*Acceptance:* CI equality step covers exactly the enumerated set
including the script and selftest; both copies' tree-oid selftests green
in CI; the platform-token grep from U3 passes on the shared copies;
direct `/cursor-implementation-loop` invocation behavior unchanged;
Cursor enforcement caveats stated in the adapter file, not diluted.

## 5. Trigger fixtures (the routing contract)

Common assumed environment: fresh repo, no calibration record, no standing
authorization; kickoff answers are part of each fixture, or marked "n/a"
when the route dispatches nothing writable. **An implementation dispatch =
a new unit's initial dispatch; same-thread iteration resumes (review
findings, gate fixes) do not increment the count.** Expected invariants in
parentheses.

1. "Execute item 1 in approved PLAN.md." — fixture supplies a frozen
   `PLAN.md` with two items; kickoff: stop=pr.
   (Kernel direct via precedence 4; item 1's units taken from PLAN.md
   unchanged; no investigation phase beyond plan-drift validation; stops
   at an open PR.)
2. "Fix this duplicate-charge bug end to end." — kickoff: stop=pr.
   (Engineering mode → bug-fix; a recorded reproduce step precedes the
   first implementation dispatch; ≥ 1 implementation dispatch; report
   contains required vs achieved verification.)
3. "Investigate why startup regressed; don't modify code." — kickoff: n/a.
   (Precedence 2 → investigation; **zero implementation dispatches**; no
   diff; deliverable is an evidence-backed answer separating fact,
   inference, and open uncertainty.)
4. "Work with me on a plan only." — kickoff: n/a.
   (Precedence 2 → plan-only; zero implementation dispatches; plan
   artifact written to `plans/`, left uncommitted; run ends before any
   unit decomposition is dispatched.)
5. "Execute this approved plan and verify the live CLI afterward." —
   fixture supplies a frozen two-unit plan file; kickoff: stop=pr.
   (Engineering mode in passthrough via precedence 4's capability branch;
   plan's two units executed unchanged — plan lock; report shows
   required=`artifact` and the achieved level with oracle result.)
6. "Rename the private helper `parse_args` in `scripts/foo.sh` to
   `parse_cli_args`." — kickoff: stop=worktree.
   (Precedence 3 fast path — an explicit change request, beats the
   refactor playbook; exactly 1 implementation dispatch; achieved
   verification `focused` — the script is runtime content, so
   `not_applicable` would be an invalid classification; verdict bound to
   equal before/after tree OIDs, no commit created.)
7. "Plan only for renaming the private helper `parse_args` in
   `scripts/foo.sh`; don't implement." — kickoff: n/a.
   (Precedence 2 beats the fast path — **zero implementation
   dispatches**, no diff; plan artifact produced. A direct prohibition on
   code changes dominates the routing shortcut. Regression fixture for
   the round-2 ordering defect.)
8. "Investigate why `parse_args` in `scripts/foo.sh` drops `--foo`." —
   kickoff: n/a.
   (Mentions code but requests no change: fails the fast path's
   explicit-change precondition, falls to rule 5's no-code tie-break →
   investigation; **zero implementation dispatches**; no diff. Regression
   fixture for the round-3 implicit-investigation defect.)

## 6. Rejected, with reasons (do not reopen without new evidence)

- **JSON state machine / schema / locks** — an LLM re-derives state from
  `git status` + prose better than it maintains a formal transition graph;
  since state is never authority, everything in it must be re-verified
  anyway; U6 delivers ~80% of the value at ~5% of the cost.
- **Sync-script infrastructure in v1** — nothing to sync until PR 3; the CI
  `diff -q` pattern already exists and extends in one line.
- **Panel review** — `deep` is already a blinded independent reviewer;
  marginal value doesn't cover the cost. Revisit only for money/auth work.
- **Project-verifier scaffolding** (persistent `.agent-verification/` trees
  in target repos) — creates tracked files in *other* people's repos as a
  side effect of a run; the verification contract (U4) captures the same
  honesty without leaving artifacts behind. Revisit if one repo genuinely
  re-verifies the same flow across many runs.
- **Eval infrastructure with thresholds** — Cursor's runtime can't be driven
  headlessly; numeric targets would be theater. Fixed manual fixtures with
  frozen environments and expected invariants (U7) instead — rejecting the
  infrastructure does not reject rigor.
- **Principles layer** — worth building at pstack's scale (30+ skills
  cross-referencing 21 rules); at three skill families, direct references to
  kernel sections are cheaper and stay in sync.
- **Watcher daemon** — see §7 backlog; not part of v1 at all.
- **22 playbooks** — six cover the upstream gaps; lifecycle concerns
  (pause, pickup, autonomy) live in the router and U6, not as playbooks.

## 7. Backlog (outside this program, pain-triggered)

**`pr-status.sh --once`** — a stateless snapshot tool, not a daemon: read
PR head/base SHA via `gh`, compare against the gate record, report
CI/review/mergeability, declare the gate certificate stale on any SHA
movement. ~150 lines to the `run-gate.sh` standard (fail-closed, selftest,
CI syntax check); continuous watching = this tool under the harness's own
`/loop` or scheduled tasks. **Trigger:** the first time a real run leaves
someone manually re-checking a PR's freshness more than twice. Until then
it is not scheduled work, and it needs no approval to stay unscheduled.

## 8. Open decisions (user-owned)

1. Skill name: `codex-engineering-mode` (default) or another name.
2. Plan-only output location: `plans/` in the target repo (default) or
   user-specified per run.
3. Publication boundary for *this* plan's own PRs. This is a separate
   grant from approving this document — approving the plan does not answer
   it. Repo convention is PR-to-main; confirm `stop=pr` explicitly.
