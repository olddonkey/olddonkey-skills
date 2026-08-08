# PR 1 review record — U2 acceptance artifacts

Preserved per plan §2-U2 acceptance: the filled routing table and
deferred-concern inventory from the parent's review of the shipped router
(`skills/codex-engineering-mode/SKILL.md`), verified against the plan's §5
fixtures at PR 1 review time and re-checked after the post-merge fixes
round. Historical record, not authority.

## Filled routing table (§5 fixtures vs shipped router text)

| Fixture | Rule fired | Implementation dispatches | Stop / deliverable |
| --- | --- | --- | --- |
| 1 Execute approved PLAN item 1 | 4 (kernel direct; rule 3 defers plan-governed changes) | plan-defined, unchanged | open PR |
| 2 Duplicate-charge bug end to end | 5 → bug-fix | ≥ 1, reproduce recorded first | PR + required-vs-achieved report |
| 3 Investigate regression, no code | 2 (investigation-playbook discipline) | 0 | evidence-backed argument, no diff |
| 4 Plan only (named objective) | 2 | 0 | uncommitted plan in `plans/` |
| 5 Execute plan + verify live CLI | 4 passthrough (capability branch) | exactly 2 (frozen plan) | PR after artifact verification |
| 6 Rename helper (explicitly invoked) | 1 → internal 3 fast path | exactly 1 | worktree; focused-or-artifact verification; equal tree OIDs |
| 7 Plan-only rename | 2 (dominates 3) | 0 | plan artifact, no diff |
| 8 Investigate `--foo` drop | 3 fails (no change requested) → 5 tie-break → investigation | 0 | argument, no diff |

## Deferred-concern inventory (router vs kernel)

| Kernel concern | Router treatment |
| --- | --- |
| Dispatch hygiene | Defers — cites kernel §2 Dispatch |
| Diff review | Defers — cites kernel §3 |
| Iteration | Defers — cites kernel §4 |
| Full-suite gate | Defers — cites kernel §5; verification contract explicitly supplements, never replaces |
| Publication | Defers — cites kernel §6 and non-negotiables |
| Calibration / authority records | Defers — cites First-run calibration; claim-not-authority restated only as a pointer |

No "restates" rows; U2's duplication criterion holds. Novel-rule check
(U3): bug-fix goal-level reproduce-before-spec; performance measurement
contract; prototype abandon-in-place; investigation fact/inference/
uncertainty; feature data-shape/blast-radius precondition; refactor
characterization-as-preparatory-unit — none present in either kernel.

Known accepted deviation: `investigation.md` ends with its argument rather
than a kernel invocation (plan §2-U3 acceptance, investigation exception).
