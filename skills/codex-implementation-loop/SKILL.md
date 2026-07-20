---
name: codex-implementation-loop
description: 'Delegate implementation work to Codex (via the codex-companion runtime), then review its diff, send it back to iterate, gate on the full test suite, and ship it as a PR. Use this whenever the user wants Codex to write code, mentions handing off / delegating implementation to Codex, asks to work through a plan or spec unit-by-unit with Codex doing the coding, or wants a review-and-merge loop wrapped around Codex output — and also when resuming such a loop ("keep going", "next unit", "继续下一个"). It encodes constraints that are expensive to rediscover: Codex runs in the real environment with effectively read-only git, must not be pointed at a full test suite by default, accepts only specific --effort values, and its self-report is a claim rather than evidence.'
---

# Codex implementation loop

**Codex writes the code; you own the judgment.** Codex is fast at implementation but it self-reports success, cannot commit, and will hang a machine if pointed at a long test suite. You give it a precise spec, then be the thing that actually verifies and ships. **This includes bug fixes**: a bug found at review, at the gate, or later is a unit like any other — you diagnose and spec, Codex implements. Editing code directly "because it's faster" silently inverts the division of labor and costs review its independence.

The loop: **decompose → dispatch → review → iterate → gate → publish → next**.

## Non-negotiables

1. **Review is mandatory and independent.** Codex's summary is a claim; the diff is the evidence. Never skip review because it says it's done.
2. **An assumed default never leaves the machine.** With no explicit user choice, stop at the working tree — even a local commit can fire hooks/signing. Commit, push, PR, and merge each need the user to have said yes once for this repo. **Once is once**: that authorization is per-repo, given at calibration, persists across sessions until revoked or the work changes character — never re-ask per unit.
3. **Never push straight to the default branch.**
4. **The full-suite gate is yours**, run by you, with the real exit code. A fix means the code satisfies the test — a weakened assertion, deleted case, or widened tolerance to turn red green is a stop, not a pass.
5. **Don't let Codex run the full test suite by default** — focused subsets only, unless calibration showed the suite is small and fast.

## Dials (settle once per repo, record, stop re-asking)

| Dial | Options | Recommended default |
| --- | --- | --- |
| **Stop point** | `worktree` / `commit` / `pr` / `merge` | recommend `pr`; assumed default stops at `worktree` |
| **Dispatch mode** | `implement` / `read-only` | `implement` |
| **Gate policy** | `baseline` / `strict` / `skip` | `baseline` |
| **On gate red** | `stop` / `iterate` | `stop` |
| **Review depth** | `light` / `standard` / `deep` | `standard` |
| **Cadence** | `confirm` / `continuous` | `confirm`; `continuous` fits stop=`merge` |
| **Fix lane** | `codex` / `claude-trivial-ok` | `codex` |

Full rationale: [references/dials.md](references/dials.md). Compressed non-obvious parts:

- `continuous` only fits stop=`merge` — anything earlier stacks unit 2 on unit 1's unmerged changes and breaks review attribution.
- **Fix lane drifts silently** — hand-fixing feels faster every time. `claude-trivial-ok` is a user-granted carve-out for mechanical one-liners only; logic always goes to Codex; the gate runs either way.
- `deep` review = an independent subagent given the diff and repo but *not* your spec — for changes touching security, concurrency, migrations, auth, or money.
- `skip` gate only for changes with no runtime surface. `read-only` dispatch is investigation — no diff, nothing to gate; useful as a first pass before an implement dispatch on gnarly problems.

## Model, effort, speed — the kickoff question

At each invocation of this skill, ask **one compact question** covering thinking level (effort) and speed (service tier), presenting the user's current `~/.codex/config.toml` values as the inherit option. The answer holds for the entire invocation; never re-ask per unit. A recorded standing preference ("always inherit, stop asking") suppresses it. Everything else — flag/config resolution, config-only efforts, tier mechanics, model-name aging, stale-CLI diagnosis, the companion contract — is in [references/runtime.md](references/runtime.md); read it before the first dispatch of a session.

## 1. Decompose

A unit = one coherent, reviewable change, roughly one PR. Settle the design **before** dispatching — ambiguity becomes discarded work. If the task changes a documented design, update the doc/spec first (your lane), then dispatch code against it.

## 2. Dispatch

```bash
# ${CLAUDE_SKILL_DIR} is replaced with this skill's absolute path when the skill
# loads, making each command self-contained — no variable needs to survive
# between Bash calls (env vars don't). In a non-substituting agent, replace it
# manually with the skill's install directory.
"${CLAUDE_SKILL_DIR}/scripts/codex-dispatch.sh" --prompt-file /tmp/unit-prompt.txt   # inherit config
"${CLAUDE_SKILL_DIR}/scripts/codex-dispatch.sh" --prompt-file /tmp/unit-prompt.txt \
    --model gpt-5.6-sol --effort xhigh    # explicit override (model names age)
```

Hygiene — each failure mode here is silent:

- **Run from the target repo root**; the companion works on the invoking directory. Read the `workspace:` line it prints.
- **Start from a clean tree** (`git status --short`), or Codex's changes are unattributable.
- **One unit in flight** — `--resume` binds to the most recent thread.
- **Prompt in a file, outside the target repo** (`/tmp`) — shell-escaping corrupts long prompts, and in-repo files pollute the diff.
- **Create the unit branch before dispatching** when the stop point involves one.
- **Background at the harness level**; the companion's own `--background` detaches and can outlive a failed-looking launch.

The prompt is the whole spec: **why** (evidence, file:line), **exactly what to change**, **tests expected** (including which existing tests will break and how they update — never deleted), **what not to touch**, and the environment constraints. Copy-ready skeleton: [references/dispatch-prompt.md](references/dispatch-prompt.md).

Environment constraints to include verbatim-ish in every dispatch:

- Codex executes on the same host (companion pins sandbox: `workspace-write` for implement, `read-only` otherwise) and shares your CPU/RAM/disk.
- Its `.git` is effectively read-only — changes stay in the working tree; you commit and publish.
- No full test suite by default — focused subset or nothing; you own the gate. Ask it to report files changed, tests added, subset run.

Stuck jobs (no new events 15–20 min): cancel, read what it attempted, fix the prompt or split the unit — and kill orphaned test processes. Commands in [references/runtime.md](references/runtime.md).

## 3. Review the diff yourself

Read the actual diff; the summary only says where to look. Check the whole tree (`git status --short`), not just files Codex mentioned. Recurring delegated-implementation failure modes, priority order — detail in [references/review-checklist.md](references/review-checklist.md):

1. **Silent regressions from changed defaults** — trace production call paths, not just the changed function.
2. **Tests "fixed" by weakening intent** — deleted cases, softened assertions, tautologies.
3. **New code paths with no coverage.**
4. **Gitignored files** — local-only, will never ship; tests reading them must skip when absent.
5. **Order/snapshot-dependent tests** when serialization changed.
6. **Softened enforcement points** anywhere security-adjacent.
7. **New dependencies, network calls, external services** — a decision, not a detail; check the lockfile.

## 4. Iterate

Send findings back on the same thread with specifics — what's wrong, why it matters, what you expect:

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex-dispatch.sh" --resume --prompt-file /tmp/review-findings.txt
```

Repeat until the diff is something you'd sign. A bug that surfaces **outside** an active thread is a new unit, not a hand-edit: diagnose, dispatch on a fresh thread with repro + root cause + expected fix + the regression test you expect — a fix without a test that would have caught the bug is incomplete.

## 5. Gate

Run the whole suite yourself via the bundled helper — piping through `tail` masks the real exit code:

```bash
# strict policy — real exit code (forced red if the runner's own summary disagrees):
"${CLAUDE_SKILL_DIR}/scripts/run-gate.sh" --log /tmp/gate.log -- <test command>
# baseline policy ONLY — tolerates failures already present in the base-branch log:
"${CLAUDE_SKILL_DIR}/scripts/run-gate.sh" --log /tmp/gate.log --baseline /tmp/base.log -- <test command>
```

`baseline` policy = no new non-flake failures vs the base branch, decided mechanically (pytest identifiers include the exception class; skipped-only, empty, or unparseable runs fail closed). It proves *no new failure identifiers and that tests executed* — not that the full calibrated suite ran; check the reported count when it matters. On red, follow the on-red dial with capped attempts. Serial-vs-parallel, unreliable CI, no-suite repos, parser scope: [references/gate.md](references/gate.md).

## 6. Publish

Go exactly as far as the stop point says. **Check the branch before pushing** (`git status -sb`) — other tools quietly move checkouts, and a blind push lands commits on whatever is checked out; with the unit branch created at dispatch time this is confirmation, not rescue. Write commits/PRs so an absent reader understands *why*, with real gate numbers; match the repo's existing conventions. Merge only under recorded authorization (non-negotiable #2).

## 7. Record and continue

Note what landed and what's next somewhere durable (memory, progress doc, the plan) — a cross-session loop that isn't written down gets re-derived. Then take the next unit per the cadence dial.

## Stop and ask only when

- **A human/manual ceiling** — credentials, policy, hardware only the user can provide; hand them a concrete checklist.
- **A real design fork** — two defensible directions with materially different consequences; recommend, don't survey.
- **Codex is stuck** — repeated failures, or tests unfixable without weakening them.
- **A safety/correctness boundary would soften** — surface it even if the request implies it.

## First-run calibration per repo

Record once (CLAUDE.md or memory): the seven dials; whether the kickoff effort/speed question is wanted or standing-inherit; full-suite command, runtime, serial-vs-parallel; known flakes (keep a base-branch gate log for `--baseline`, regenerate after merges); CI trustworthiness; commit/PR conventions; where progress is recorded. Record format example: [references/dials.md](references/dials.md).

A stored setting IS standing authorization for the scope it was given in — that's what lets sessions resume without re-asking. It does not stretch to work of a different character: a `light`-depth unit that turns out to touch a security boundary, or a `merge` stop point meeting money, gets surfaced and re-checked.
