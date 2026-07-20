---
name: codex-implementation-loop
description: 'Delegate implementation work to Codex (via the codex-companion runtime), then review its diff, send it back to iterate, gate on the full test suite, and ship it as a PR. Use this whenever the user wants Codex to write code, mentions handing off / delegating implementation to Codex, asks to work through a plan or spec unit-by-unit with Codex doing the coding, or wants a review-and-merge loop wrapped around Codex output — and also when resuming such a loop ("keep going", "next unit", "继续下一个"). It encodes constraints that are expensive to rediscover: Codex runs in the real environment with effectively read-only git, must not be pointed at a full test suite by default, accepts only specific --effort values, and its self-report is a claim rather than evidence.'
---

# Codex implementation loop

A division of labor: **Codex writes the code, you own the judgment.** Codex is fast and thorough at implementation but it self-reports success, cannot commit, and will happily hang a machine if pointed at a long test suite. Your job is to give it a precise spec, then be the thing that actually verifies and ships.

**This includes bug fixes.** A bug found at review, at the gate, or reported after shipping is a unit like any other: you diagnose and spec it, Codex implements the fix. If you catch yourself editing the code directly "because it's faster", the division of labor has silently inverted — and review has lost its independence, because you'd be reviewing your own work.

The loop: **decompose → dispatch → review → iterate → gate → publish → next**.

Do not skip review because Codex says it's done. Its summary is a claim; the diff is the evidence. In practice the highest-value findings come from reading the diff — silent behavior regressions, tests weakened to pass, gitignored files that will never ship.

---

## Settings to establish before the first dispatch

These change what the loop does to the user's repo, so they're the user's call. Settle them once at the start, record them (see calibration at the end), and stop re-asking — a loop that checks in on every dial isn't a loop. When the user hasn't said, use the recommended default and *tell them which one you're using* rather than deciding silently.

| Dial | Options | Recommended default |
| --- | --- | --- |
| **Stop point** | `worktree` / `commit` / `pr` / `merge` | recommend `pr`; assumed default stops at `worktree` |
| **Dispatch mode** | `implement` / `read-only` | `implement` |
| **Gate policy** | `baseline` / `strict` / `skip` | `baseline` |
| **On gate red** | `stop` / `iterate` | `stop` |
| **Review depth** | `light` / `standard` / `deep` | `standard` |
| **Cadence** | `confirm` / `continuous` | `confirm`; `continuous` fits stop=`merge` |
| **Fix lane** | `codex` / `claude-trivial-ok` | `codex` |

One boundary is not a dial: **an assumed default never leaves the machine.** Telling the user which default you're using is transparency, not authorization — and pushing a branch or opening a PR is outward-visible (CI runs, notifications fire, collaborators see it). With no explicit user choice, leave the changes in the working tree and stop — even a local commit can fire the repo's hooks or signing machinery, so the truly consent-free default touches nothing but files. Commit, push, PR, and merge each need the user to have actually said yes once for this repo. **Once is once**: this is a per-repo authorization given at calibration, not a per-unit confirmation — after the user has chosen (e.g. "merge everything autonomously"), the loop runs to that stop point on every unit without asking again. The boundary only exists for the case where nobody ever consented.

**Stop point** decides how far each unit travels — leave changes in the working tree, commit to a branch, open a PR, or merge. It's the only dial that bounds irreversible action, which makes it the one worth being explicit about. `pr` is the recommendation because a PR is a reviewable artifact that costs nothing to abandon, while merging is the step you can't quietly undo — but per the boundary above, reaching `pr` at all requires the user to have actually chosen it. Only use `merge` when the user has actually authorized autonomous merging; that authorization is per-repo and doesn't transfer between repos; once given and recorded in calibration it persists across sessions until the user revokes it or the work changes character (see calibration).

Stop point and cadence interact: with a stop point short of `merge`, the unit hasn't landed when the next one would start, so `continuous` stacks unit 2 on top of unit 1's unmerged changes — diffs blur together and review attribution breaks. Unless the user deliberately wants stacked branches, pair `worktree`/`commit`/`pr` with `confirm` (or wait for each unit to land before dispatching the next); `continuous` really fits `merge`.

**Dispatch mode** — `read-only` (`--read-only`) runs Codex without write access for diagnosis, code reading, or a design proposal. Treat it as a different activity rather than a cautious implement: there's no diff, so there's nothing to review, gate, or publish, and the output is an argument you should evaluate on its merits rather than a change you can verify. The productive pairing inside the loop: on a gnarly problem, `read-only` first to investigate and settle the design, then a normal `implement` dispatch against the settled spec.

**Gate policy** — `baseline` accepts no new non-flake failures relative to the base branch, which is the honest bar on a suite with known environment flakes. `strict` demands zero failures and suits clean suites. `skip` is only defensible for changes with no runtime surface at all (docs, comments); if a change touches code, something can break, so skipping is how a regression ships. Say which policy is in effect when you report the result.

**On gate red** — `stop` brings failures to the user. `iterate` sends them back to Codex automatically, which is efficient for obvious breakage but needs two boundaries: cap the attempts (two or three) so a stuck loop surfaces instead of grinding, and hold the line that a fix means the code satisfies the test, never the test bending to the code. If Codex's fix weakens an assertion, that's a stop, not a pass.

**Review depth** — `standard` is the checklist below. `deep` adds an independent reviewer that hasn't seen the dispatch prompt, which is worth the cost when a change touches a correctness or security boundary, concurrency, migrations, auth, or money — places where a plausible-looking diff can be wrong in ways the author's framing hides. `light` still reads the whole diff; it just spends less time hunting on genuinely mechanical edits. Depth is a dial on rigor, not permission to skip reading the diff.

**Cadence** — `continuous` moves to the next unit without checking in, which is the point of a loop once the user trusts it. `confirm` pauses after each unit. Worth asking once up front, because assuming `continuous` on the first run means a lot of merged work before anyone looks.

**Fix lane** — who implements bug fixes. `codex` (the default) means every fix is a unit: diagnosis and spec are your lane, the change itself is Codex's, and review keeps its independence because the reviewer didn't write the fix. This is the dial most prone to silent drift — hand-fixing always feels faster in the moment, and each hand-fix quietly re-inverts the division of labor the user asked for. `claude-trivial-ok` is a user-granted carve-out for mechanical one-liners (a typo, a quoting fix, a comment) where a dispatch round genuinely costs more than the change; it must be explicitly granted, never assumed, and anything touching logic still goes to Codex. Under the carve-out the gate still runs — it's the only independent check left when implementer and reviewer are the same mind.

---

## 1. Decompose into units

Pick a unit that is one coherent, reviewable change — roughly one PR. If working from a plan or spec, a unit is usually one numbered item or one section's worth of work.

If the design isn't settled, settle it **before** dispatching. Codex implements against the spec you give it; ambiguity turns into work you throw away. When a task changes a documented design, update the doc/spec first (that's your lane), then dispatch the code against it. This also gives the reviewer — you, later — something to check the diff against.

## 2. Dispatch to Codex

Use `scripts/codex-dispatch.sh` (bundled), which locates the newest installed companion and invokes it correctly:

```bash
# The scripts live next to this SKILL.md — NOT in the target repo, which is where a bare
# relative path would point after you cd to the repo root. Set SKILL_DIR explicitly:
SKILL_DIR="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/codex-implementation-loop}"
"$SKILL_DIR/scripts/codex-dispatch.sh" --prompt-file /tmp/unit-prompt.txt     # inherit user's config
"$SKILL_DIR/scripts/codex-dispatch.sh" --prompt-file /tmp/unit-prompt.txt \
    --model gpt-5.6-sol --effort xhigh          # explicit override (model name is an example — they age)
```

Dispatch hygiene — each of these failure modes is silent when it happens:

- **Run it from the root of the target repo.** The companion operates on the invoking directory; dispatched from the wrong place, Codex works on the wrong workspace with no error. The script prints `workspace:` so a wrong-directory dispatch is visible immediately — read that line.
- **Start from a clean tree** (`git status --short` first). Codex's changes arrive unstaged in the working tree; pre-existing dirt makes "what did Codex actually change" unanswerable at review time.
- **One unit in flight at a time.** Iteration uses `--resume-last`, which binds to the most recent thread — two concurrent dispatches would cross their review threads.
- **Write the prompt to a file, and put that file outside the target repo** (`/tmp` or your scratch directory) — dispatch prompts are long, and shell-escaping a multi-paragraph prompt is a reliable way to corrupt it. Outside the repo, because the clean-tree rule applies to your own droppings too: a prompt file inside the repo pollutes the very diff you're about to review.
- **If the stop point involves a branch** (`commit`/`pr`/`merge`), create and switch to the unit branch *before* dispatching — Codex's changes then land on the right branch from the start, and the pre-push branch check becomes a confirmation instead of a rescue.
- **Background at the harness level** (your shell's background-task mechanism), which keeps the full event stream in one file you can read later. The companion's own `--background` is different: it *detaches* and returns a job id to poll. Use it only when you specifically want detachment, and know that a detached task keeps running even when the launching command looks like it failed — bad arguments can still start a real job.

### Model, effort, speed — the kickoff question

At each loop kickoff — each time this skill is invoked to start or resume working through units — ask **one compact question** covering thinking level (effort) and speed (service tier), presenting the user's current config values as the inherit option (read `~/.codex/config.toml` first so the question shows real values). The answer holds for the **entire invocation**; never re-ask per unit. A recorded standing preference ("always inherit, stop asking") suppresses the question — it exists to give control, not friction.

Everything else about the runtime — how flags interact with the user's config, config-only efforts (`max`/`ultra`), tier mechanics and canonical values, model-name aging, stale-CLI diagnosis, and the companion's task contract — lives in [references/runtime.md](references/runtime.md). Read it before the first dispatch of a session.

### Runtime contract

```
codex-companion.mjs task [--background] [--write] [--resume-last|--resume|--fresh] \
                         [--model <model>] [--effort <level>] [prompt]
```

- **`--write` is required** for Codex to modify files. Without it the workspace is read-only and it will politely explain it can't change anything.
- **The accepted `--effort` levels belong to the installed companion, not to this document.** As of plugin 1.0.6 they are `none|minimal|low|medium|high|xhigh`, with `max`/`ultra` rejected as flags (config-only) — but the dispatch script reads the live list out of the installed companion at runtime, so trust its error message over any remembered list. If the user wants a config-only level like `max`, omit `--effort` so the CLI inherits it from `~/.codex/config.toml`; don't edit their global config to force it, since that affects their own Codex use outside this loop.
- The prompt is the trailing positional argument.
- With no resume flag, every invocation starts a **fresh thread** — right for a new unit. `--resume-last` continues the most recent thread, which is how you send review findings back with context intact; don't reuse a previous unit's thread for a new unit, or its framing bleeds in.

### What a dispatch prompt needs

Codex works semi-autonomously, so the prompt is the whole spec. Include:

- **Why** — the bug or goal, with the specific evidence (file:line) that motivated it. Context prevents it from "fixing" the wrong thing.
- **Exactly what to change** — files, functions, and the shape of the change. Name the edge cases you already know about.
- **Tests you expect** — including which *existing* tests will break and how they should be updated. If a change flips a default, existing tests that relied on the old default must be made explicit rather than deleted.
- **What not to touch** — safety invariants, unrelated subsystems.
- **The environment constraints below**, verbatim-ish.

A skeleton that has worked well:

```text
Unit: <one-line name>

## Why
<bug/goal, with the file:line evidence that motivated it>

## Change
<files, functions, shape of the change; known edge cases>

## Tests
<new tests expected; existing tests that will break and how to update them>

## Do not touch
<invariants, unrelated subsystems>

## Environment
- You run in the real environment; .git is read-only — leave changes in
  the working tree, I commit and publish.
- Do NOT run the full test suite. Run only <focused subset>, or nothing;
  I own the full gate.
- When done, report: files changed, tests added, which subset you ran
  and its result.
```

### Environment constraints to put in every dispatch

These aren't hypothetical; each cost real time to learn.

- **Codex executes on the same host as you.** The companion pins the sandbox per task — `workspace-write` for implement dispatches, `read-only` for read-only ones — regardless of the user's own codex sandbox config. Sandboxed or not, it shares your CPU, RAM, and disk, which is what makes the test-suite rule below matter (and the sandbox explains oddities like /dev/fd permission errors inside its test runs).
- **Its `.git` is effectively read-only** — it cannot commit, branch, or push. Tell it to leave changes in the working tree; you commit and publish.
- **Don't let it run the full test suite by default.** On a suite with real subprocess/socket/lock tests this can crawl for hours *and* saturate the machine, slowing everything else you're running. Tell it explicitly: run only a focused subset covering the modules it touched, or nothing at all, because you own the full gate. If first-run calibration shows the suite is genuinely small and fast, you may relax this deliberately — the gate stays yours either way.
- Ask it to report which files it changed, which tests it added, and which focused subset it ran — so your review has a starting map.

### If a job looks stuck

Judge progress by the event stream, not the clock; see the monitoring section of [references/runtime.md](references/runtime.md) for the stuck heuristic, `status`/`cancel` commands, and orphaned-test-process cleanup. The short version: no new events for 15–20 minutes means cancel, read what it was attempting, fix the prompt or split the unit — and always kill the test processes the job spawned.

## 3. Review the diff yourself

Read the actual diff. Codex's summary tells you where to look, not whether it's correct. At `deep`, also get an independent read from a reviewer that hasn't seen the dispatch prompt — in practice, a fresh subagent given the diff and repo access but *not* your spec or Codex's summary. A diff written to a spec tends to look right to anyone holding that spec; the point is to find what the spec itself missed.

Beyond ordinary code review, these are the failure modes that recur with delegated implementation:

- **Silent behavior regressions from changed defaults.** If a default became weaker (empty, off, permissive), trace the *production* call paths — not just the changed function — and confirm nothing real depended on the old default. This is the single highest-value check when a change touches configuration or defaults.
- **Tests "fixed" by weakening intent.** A test that used to assert a behavior should still assert it, with the setup made explicit — not deleted, and not softened into a tautology.
- **New code paths with no coverage.** A new branch, step, or state that no test exercises.
- **Gitignored files.** Changes to ignored files are local-only and will never reach another user. If the change matters to the product, it belongs in a committed file (an example/template), with the ignored file being just this machine's instance. Tests that read an ignored file need to skip gracefully when it's absent, or they'll fail on a fresh checkout.
- **Order- or snapshot-dependent tests** when serialization order changed.
- **Anything security-adjacent that got softened** — a hard check turned advisory, a validation loosened, a boundary made bypassable. If the diff touches an enforcement point, confirm the enforcement is still enforcement.
- **New dependencies, network calls, or external services.** A delegated diff that quietly adds a package, reaches a new endpoint, or pulls in a new service is a decision, not an implementation detail — surface it to the user rather than absorbing it. Check the manifest/lockfile even if the summary didn't mention one.

Check the whole working tree (`git status --short`), not just the files Codex mentioned.

## 4. Iterate

If you find issues, send them back on the same thread with specifics: what's wrong, why it matters, what you expect instead. Mechanically that's the dispatch script again with `--resume`, so the thread keeps its context:

```bash
"$SKILL_DIR/scripts/codex-dispatch.sh" --resume --prompt-file /tmp/review-findings.txt
```

Then review again. Repeat until the diff is something you'd sign your name to — which you're about to.

### Bugs that surface later

A bug found outside an active thread — a later regression, a user report, something you notice in passing — is a **new unit**, not a hand-edit (see the fix-lane dial). Diagnose first: yourself for most things, or a `read-only` dispatch for the gnarly ones. Then dispatch the fix on a **fresh thread** with the diagnosis in the prompt — the repro, the root cause as you understand it, the shape of the expected fix, and the regression test you expect. A fix without a test that would have caught the bug is incomplete. Then review, gate, and ship it like any other unit.

## 5. Gate on the full test suite

Run the whole suite yourself before publishing. Two details matter:

**Capture the real exit code.** Piping the run through `tail`/`head` makes the pipeline's exit status that of the pager, so a failing suite looks green. Use the bundled helper, which writes full output to a log and reports the actual status:

```bash
"$SKILL_DIR/scripts/run-gate.sh" --log /tmp/gate.log -- <your test command>
```

**Prefer serial.** For suites heavy in real I/O, file locks, fixed ports, or subprocess spawning, parallelism serializes on the shared resources anyway and often ends up *slower* than serial while making failures harder to attribute. Measure before assuming parallel helps.

Interpret results according to the **gate policy** dial. Under `baseline` — the usual case — the bar is no new non-flake failures relative to the base branch. Environment-specific flakes that also fail on the base branch aren't regressions, but say so explicitly rather than waving them off, and don't let "it's probably flaky" absorb a real failure. `run-gate.sh --baseline <log>` does that comparison mechanically, which beats eyeballing two lists.

When the gate is red, follow the **on-red** dial: `stop` hands it to the user; `iterate` sends the failures back to Codex for a bounded number of attempts. Either way the standard is the same — the code satisfies the test. If a proposed fix relaxes an assertion, deletes a case, or widens a tolerance to make red turn green, stop and raise it, because that converts a caught bug into a shipped one.

If the repo's CI is unreliable for reasons unrelated to code (billing, broken infra), the local gate is the real signal — note that plainly in the PR so a red CI badge isn't mistaken for a broken change.

The gate's failure parsing understands **unittest and pytest** output. Under `--baseline`, any other runner fails closed with an unsupported-runner message rather than guessing — plain pass-through mode (no `--baseline`) works with any runner. Also under `--baseline`, a run must show real executed tests: skipped-only or empty output is red even on exit 0.

If the repo has no meaningful suite, say so instead of letting the gate silently pass on nothing: the bar becomes the tests this unit itself added, plus driving the affected flow once by hand. Flag the missing suite to the user as its own backlog item rather than quietly treating "no tests ran" as green.

## 6. Publish

Go as far as the **stop point** dial says, and no further: leave the working tree alone, commit to a branch, open a PR, or merge. Whichever the endpoint, never push straight to the default branch — that's the one step that isn't a preference.

**Check the branch before you push** (`git status -sb`). Other tools quietly move the checkout — `gh pr checkout`, a cloud session, the user reviewing a PR — and a blind `git push` then lands your commit on whatever branch happens to be checked out. This really happens: a commit once rode an unrelated PR branch and missed the default branch entirely because the PR merged first. The branch line is one glance; reconciling a stranded commit is not.

Write the commit and PR body so a reader who wasn't here understands *why*, not just what: the motivating bug, the design decision, and the verification you actually ran (with real numbers from the gate). Follow the repo's existing conventions rather than importing your own — check recent history for whether it uses conventional-commit prefixes, ticket references, or trailers, and match it.

**On merging:** only when the stop point is `merge` and the user has actually authorized autonomous merging. That authorization is per-project: re-asking every unit defeats the point of the loop, and assuming it when it wasn't given is worse.

## 7. Record and continue

After a merge, note what landed and what's next — in the project's memory, progress doc, or the plan itself. A loop that runs across sessions needs its state written down somewhere durable, or the next session re-derives it.

Then take the next unit, per the **cadence** dial — `continuous` keeps going, `confirm` checks in first. Running continuously is the point once the loop is established; the stop conditions below still apply either way.

---

## When to stop and ask

Keep going on your own except when:

- **A human/manual ceiling is hit** — the remaining work needs credentials, policy decisions, hardware, or an account only the user can act on. Say what's blocked and hand them a concrete checklist.
- **A real design fork appears** — two defensible directions with materially different consequences. Present a recommendation, not a survey.
- **Codex is stuck** — repeated failed attempts, or tests you can't get green without weakening them. Weakening a test to ship is not a fix.
- **The change would soften a safety or correctness boundary.** Surface it explicitly, even if the user's request implies it. A hard constraint quietly turned advisory is worse than no change.

## First-run calibration per repo

Work these out once and record them (CLAUDE.md or memory) so future sessions skip the discovery:

- **The seven dials above** — stop point, dispatch mode, gate policy, on-red behavior, review depth, cadence, fix lane. Recording them is what lets later sessions resume without re-litigating settled decisions.
- **Whether the kickoff effort/speed question is wanted** (the default) or the user prefers a standing "always inherit, don't ask". Model/effort/tier themselves are per-invocation kickoff answers, not per-repo constants (tier is config-only — no per-dispatch flag).
- **CLI freshness**: note `codex --version` at loop start. When a model or flag seems missing later, a stale CLI is the first suspect — check the version before debugging anything else.
- The exact full-suite command, its runtime, and whether serial or parallel is faster.
- Known environment flakes on this machine, so the gate has a baseline. Keep a base-branch gate log around for `--baseline` comparison — and regenerate it after each merge, because the baseline is the base branch as it is *now*, not as it was last week.
- Whether CI is trustworthy.
- The repo's commit/PR conventions.
- Where progress gets recorded.

A one-line record keeps the calibration greppable across sessions, e.g.:

```text
codex-loop: stop=merge gate=baseline on-red=iterate(max2) depth=standard cadence=continuous
            model=inherit effort=inherit serial ci=untrusted
            suite="PYTHONPATH=src python3 -m unittest discover -s tests" (~700s)
```

A stored setting IS standing authorization for the scope it was given in — that's what lets later sessions resume without re-asking. What it does not do is stretch to work of a different character than it was granted for. If the work changes character — a unit that touches a security boundary while depth is `light`, or money while the stop point is `merge` — say so and re-check rather than riding the setting into territory it wasn't chosen for.
