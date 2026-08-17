# cursor-implementation-loop

Cursor port of [`implementation-loop`](../skills/implementation-loop):
delegate implementation to a dedicated subagent without delegating judgment.
The parent agent decomposes work into units, dispatches an implementer
subagent, reviews the real diff, runs the full test gate itself, and ships
only what it would sign its name to.

## What's in the box

| Path | What it is |
| --- | --- |
| `skills/cursor-implementation-loop/SKILL.md` | The loop: decompose → dispatch → review → iterate → gate → publish → next |
| `skills/.../references/` | Dials rationale, unit-contract skeleton, review checklist, gate details, Cursor runtime notes |
| `skills/.../scripts/run-gate.sh` | Test gate with real exit codes, baseline comparison, fail-closed parsing (verbatim from the Codex original) |
| `skills/.../scripts/gate-selftest.sh` | 122 regression checks for the gate (extracted from the original selftest) |
| `agents/loop-implementer.md` | The only writable subagent — implements exactly one unit per dispatch |
| `agents/loop-independent-reviewer.md` | Read-only deep reviewer; never saw the dispatch prompt, never fixes code |

## Install

**As a plugin (recommended — skills and agents install together):**

```bash
git clone https://github.com/olddonkey/olddonkey-skills
ln -s "$(pwd)/olddonkey-skills/cursor-implementation-loop" \
      ~/.cursor/plugins/local/cursor-implementation-loop
# restart Cursor or run "Developer: Reload Window"
```

Team marketplaces (Teams/Enterprise) can import this repository directly:
Dashboard → Plugins → Import from Repo.

**Bare files (no plugin machinery):** copy
`skills/cursor-implementation-loop/` into `~/.cursor/skills/` **and**
`agents/*.md` into `~/.cursor/agents/`. Both steps are required — the skill
orchestrates, the agents implement and review.

After installing, verify the gate on your machine:

```bash
bash skills/cursor-implementation-loop/scripts/gate-selftest.sh
# expect: selftest: PASS (122 checks)
```

## Pin your implementer model

The shipped agents use `model: inherit` as a placeholder. The loop's value
usually comes from pairing a strong reviewing model (the parent) with a
different implementing model — pin one in
`agents/loop-implementer.md`, or keep one variant per model
(`loop-implementer-gpt.md`, `loop-implementer-composer.md`, …) and choose at
kickoff. Pin the independent reviewer to a different model than the
implementer.

## How it differs from implementation-loop

- **Dispatch is native.** The Codex companion runtime, its discovery
  script, effort/tier config assertions, and the `--` injection defense are
  gone — a Cursor subagent is dispatched as a Task call with a structured
  prompt.
- **The gate is unchanged.** `run-gate.sh` and its guarantees are copied
  verbatim; the parent still runs the full suite itself.
- **Three hard guarantees became procedure.** Read-only git for the
  implementer, fail-closed pre-dispatch checks, and per-dispatch model
  disclosure have no native Cursor equivalent; the skill compensates
  procedurally and documents each gap in
  `references/cursor-runtime.md` — read that file before relying on the
  loop unattended.

## Invoke / teach the agent

Open the **target repo** in Cursor (after install), then either:

```text
/cursor-implementation-loop work through docs/my-plan.md unit by unit.
Stop at a PR, baseline gate, standard review, confirm before the next unit.
```

or natural language:

> Use cursor-implementation-loop to implement item 1 in PLAN.md. Hand coding
> to the implementer; you review the real diff, run the full gate, and open
> a PR.

The parent agent loads `SKILL.md` and runs the loop — you should not restate
the whole workflow. It asks one kickoff question (stop point, cadence,
implementer choice), then: **decompose → dispatch → review → iterate →
gate → publish → next**. Parent owns judgment/gate/publish; only
`loop-implementer` writes code; resume the same agent for iteration.

`disable-model-invocation` is intentionally not set — mentions of "hand this
plan to the implementer" and similar phrasing let the agent select the skill
on its own; invoke explicitly when in doubt. For temporary machines, a
symlink under `~/.cursor/plugins/local/` is enough; remove the symlink +
clone to uninstall.
