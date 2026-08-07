# Cursor runtime reference

Detail companion to the cursor-implementation-loop skill: how dispatch,
resume, and model pinning actually work in Cursor, and — read this part even
if you skip the rest — **where this port is weaker than the Codex original**.
The workflow itself lives in SKILL.md; this file is the part you consult at
dispatch time.

## Dispatch mechanics

The original skill dispatched through a shell script to an external Codex
CLI. In Cursor, the implementer is a **custom subagent** (`agents/` in this
plugin), dispatched natively:

- **Foreground dispatch** blocks until the subagent completes and returns
  its report — this is the loop's default, since review follows immediately
  and one-unit-in-flight is a rule anyway.
- **Clean context**: the subagent sees only what the Task prompt contains.
  The unit contract (references/unit-contract.md) is the whole spec; there
  is no ambient conversation history to lean on.
- **Resume**: every dispatch returns an agent ID. Follow-ups for the same
  unit — review findings, gate failures under on-red=`iterate` — resume that
  ID. A fresh dispatch has no memory of the unit; resuming the wrong ID
  sends your findings to the wrong thread. Record the ID with the unit.
- **One writable subagent per worktree.** Parallel implementers in one
  checkout produce unattributable diffs. Parallelism across *independent*
  units needs separate worktrees or separate machines (cloud agents), never
  one shared tree.

## Choosing the implementer model

Subagent model pinning is frontmatter: `model: <id>` in the agent file, with
optional parameters like `claude-opus-5[effort=high]` or `composer-2.5[]`.
Two ways to give the user a per-dispatch choice:

1. **Pinned variants** (recommended): keep one agent file per model —
   `loop-implementer-gpt.md`, `loop-implementer-composer.md` — and settle
   which to dispatch at kickoff. A Skill cannot rewrite an agent's `model:`
   field at runtime, so variants are how "which model implements" stays a
   dial rather than an edit.
2. **Edit the frontmatter** of the single shipped `loop-implementer.md`.
   Simpler for a standing choice, invisible for a per-invocation one.

Model names age fast; never recommend one from memory. Present what the
user's installation actually offers and let them pick. The same applies to
the independent reviewer — pin it to a **different** model than the
implementer, or its independence is thinner than it looks.

## Where this port is weaker than the Codex original — know these

The original bought three hard guarantees with runtime machinery. This port
has **none of them natively**; each is listed with its compensation.

1. **Git was mechanically read-only for Codex.** The companion runtime
   pinned the sandbox so dispatched work *could not* commit or push. Here,
   the implementer subagent has full shell access, and "do not touch git" is
   a prompt-level rule — strong in practice, but not enforcement. If a repo
   needs the hard guarantee (shared machines, valuable branches), add a
   Cursor **hook** that blocks `git commit`/`git push` for subagent shells,
   or run units in a throwaway worktree where a stray commit is containable.
   Check `git log` at review time either way; a commit the implementer made
   is a finding.

2. **Policy checks could fail closed before dispatch.** The original's
   dispatch script refused to run when its effort assertion or external-tool
   scan couldn't be satisfied — a script can exit nonzero; a Task call
   cannot half-refuse. Nothing here re-validates configuration before
   dispatch. The compensation is procedural: the kickoff question settles
   the dials before the first dispatch, and anything unsettled parks the
   unit rather than guessing.

3. **The model actually in force was disclosed on every dispatch.** The
   original printed model/effort/tier per dispatch precisely because a CLI
   once got silently repointed at another vendor's model. Cursor honors the
   `model:` pin **except** when team admin policy, plan limitations, or Max
   Mode settings make the model unavailable — then it **falls back
   silently**, and the parent has no per-dispatch confirmation of what ran.
   Treat the pin as intent, not proof: note the intended model in the unit
   record, and if output quality shifts abruptly mid-loop, suspect a
   fallback before suspecting the spec.

4. **`readonly` is narrower than "read-only".** Cursor's `readonly: true`
   (used by the independent reviewer) restricts file edits and
   state-changing shell commands. It does **not** by itself prevent MCP or
   external tool calls — the same boundary the original's sandbox also
   couldn't enforce, which is why the external-service prohibition lives in
   the unit contract's prompt for *every* dispatch mode, and why hard
   isolation requires disabling the tools at the Cursor level (permissions,
   hooks, or removing the MCP servers), not prompt text.

None of these gaps changes the loop's shape; they change **how much of the
loop's safety is procedure instead of mechanism**. The original could afford
occasional sloppiness because the runtime would catch it; this port cannot.

## Monitoring and stuck dispatches

Foreground dispatch means the completion signal is the Task call returning —
there is no separate watcher to arm, and no watcher failure mode. What
remains:

- A dispatch that returns with an **incomplete or evasive report** (no file
  list, "tests should pass", vague success claims) is not a partial success;
  it's a finding. Resume with specifics or, if the spec itself was
  ambiguous, fix the spec and dispatch fresh.
- A dispatch that reports a **design fork** did its job — that's the
  implementer honoring its boundary. Settle the fork (your lane), then
  resume with the decision.
- **Repeated failure on one unit** (two-three resumes without convergence)
  means the unit is misspecced or too large: split it or re-diagnose. Don't
  keep resuming the same thread at the same problem.
- If a dispatch left the tree half-modified and unusable, reset to the unit
  branch point (`git checkout -- .` / `git clean -fd` on the unit's scope)
  and dispatch fresh with the improved spec. The tree, not the subagent
  session, is the source of truth about what happened.

## The gate stays in the parent's shell

`scripts/run-gate.sh` is copied verbatim from the Codex original and is
model-agnostic: real exit codes, ANSI-stripped bytewise parsing, unittest +
pytest verdicts, baseline comparison, log-swap detection. Everything in
references/gate.md applies unchanged. `scripts/gate-selftest.sh` (also
extracted from the original, 122 checks) verifies the gate's behavior on the
machine it runs on:

```bash
bash scripts/gate-selftest.sh   # expect: selftest: PASS (122 checks)
```

Run it once when installing this plugin on a new machine — the gate's
guarantees are load-bearing, so prove them locally instead of assuming.
