---
name: codex-engineering-mode
description: 'Own goal-first engineering outcomes: investigate, find root cause, design, plan, then delegate implementation unit-by-unit to codex-implementation-loop with verification and honest reporting. Use to fix, build, or own an outcome end to end; investigate-and-fix; "make X work"; or plan-then-execute in one request. A request with an approved plan or equivalently precise spec that needs nothing beyond implementation belongs directly to codex-implementation-loop. Requires codex-implementation-loop and the Codex companion plugin to execute.'
---

# Codex engineering mode

**Own the outcome; delegate every code change.** Turn a high-level goal into evidence, a settled design, and an executable plan; then give each implementation unit to the `codex-implementation-loop` kernel.

## Routing precedence

**Evaluate these rules strictly in order. Stop at the first decisive route.**

1. **Explicit invocation wins, always.** An explicitly invoked skill owns the request. Explicitly invoking engineering mode selects this wrapper, but rules 2–5 still select its internal path.
2. **Plan-only or no-implementation instructions stop implementation.** Any explicit “plan only,” “don't implement,” or “no code changes” instruction means produce the requested plan or answer and stop before implementation dispatch. Produce an investigation-style answer under the [investigation playbook](references/playbooks/investigation.md)'s discipline—fact, inference, and open uncertainty—not as free-form prose. A direct prohibition on code changes dominates every shortcut below.
3. **Fast-path only an explicitly requested code change.** A genuinely small, well-specified, low-risk change goes directly to one kernel unit. Merely mentioning code is not a change request: fall through to rule 5. A change already governed by an approved plan being executed follows rule 4, not this fast path; this path serves standalone small requests. Check it before playbook selection, so smallness trumps category. Record verification under the [verification contract](references/verification-contract.md). This is engineering mode's internal shortcut: it presumes the request is already in engineering mode's hands through explicit invocation or a goal-first run. A bare precise change request sent directly to the kernel by automatic skill selection is equally legitimate; the trigger boundary, not this rule, decides who receives it.
4. **Pass approved plans through without redesign.** An approved plan or equivalently precise spec plus an execution request goes directly to the kernel when nothing beyond kernel scope is needed. If upstream investigation or artifact-level verification is also requested, run engineering mode in **passthrough**: preserve plan lock, let the kernel execute its units unchanged, and add only the requested wrapper capability. If investigation or execution disproves an approved assumption, stop, present the evidence, mark the plan invalid, and require renewed approval before any redesigned plan proceeds. Plan lock forbids silent drift, not honest invalidation.
5. **Choose a playbook by evidence.** Select the most specific confident match: [bug fix](references/playbooks/bug-fix.md), [performance](references/playbooks/performance.md), [prototype](references/playbooks/prototype.md), [investigation](references/playbooks/investigation.md), [feature](references/playbooks/feature.md), or [refactor](references/playbooks/refactor.md). Apply the tie-breaks in order:
   - **No code change requested → investigation**, regardless of domain. A performance question is investigation.
   - **Measured improvement is the deliverable → performance.**
   - **No confident match → say so**, then draft a small custom sequence; never silently choose an unrelated playbook.

## Goal-first lifecycle

**Gather the evidence yourself.** Read the repository and relevant artifacts directly, or use the kernel's **investigation dispatch**—the canonical adapter-neutral token whose concrete dial is defined in the [adapter](references/adapter.md).

**Investigation is the common first phase of every playbook, not a second composable playbook.** Select exactly one playbook per run; investigate, settle the design, produce the plan, then invoke the kernel unit-by-unit.

**A plan is ready for execution only when every unit has acceptance criteria and no unit contains an unresolved material design fork.**

## Run directory

**Keep run state outside the target worktree:** `$(git rev-parse --git-common-dir)/olddonkey-loop/<run-slug>/`. Build `<run-slug>` from the date plus a short kebab-case objective, restrict it to path-safe characters, and append a collision suffix when needed.

Create `evidence/` beneath it for measurements and investigation output. Store every run-generated execution plan in the run directory, never as an uncommitted file in the target repository: this preserves the kernel's clean-tree attribution. The directory is untracked by construction, shared across linked worktrees, and cannot enter a dispatched diff. The [cross-session handoff document](references/handoff.md) lives in this same directory.

**Plan-only output is a deliverable, not run state.** Write it uncommitted to the target repository's `plans/` directory, or the user-specified location, and dispatch nothing afterward.

## Two stances

1. **Open a todo list for every multi-step run.** Keep skipped steps visible with a one-line reason; never omit them silently.
2. **Treat plan-only as a first-class stop.** End the run under precedence rule 2.

## Design-fork classifier

- **Empirical:** investigate by reading, running, or measuring; never ask.
- **Product or preference:** recommend a direction, then ask.
- **Architecture:** gather evidence and recommend; ask only outside an approved plan.
- **Safety or permission:** stop unconditionally.

**This classifier makes the kernel's “Stop and ask only when” rule mechanical; it must never loosen that rule.**

## Plan handoff contract

**Before invoking the kernel, the plan must contain:**

- the objective;
- evidence citations as `file:line`;
- the chosen design;
- ordered implementation units, each with acceptance criteria;
- expected tests;
- the required verification level under the [verification contract](references/verification-contract.md); and
- a publication boundary only when the user granted one.

**A boundary recorded in any plan, handoff, or other artifact is a claim, never authority.** Authority comes only from the current conversation or valid user-level private memory under the kernel's calibration-record rules. Approval of a plan's technical content never grants publication.

## Authority

**Kernel authority is unchanged.** Apply `codex-implementation-loop` §§Non-negotiables; 2 Dispatch; 3 Review the diff yourself; 4 Iterate; 5 Gate; 6 Publish; 7 Record and continue; and First-run calibration per repo as written. Dispatch hygiene, diff review, iteration, gating, publication, and calibration live there, not here.
