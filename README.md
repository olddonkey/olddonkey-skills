<div align="center">

# Olddonkey Skills

**Open-source [Agent Skills](https://agentskills.io) distilled from workflows that ran, broke, and got fixed.**

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [简体中文](./README.zh-CN.md)

</div>

---

Three Claude Code skills so far, plus a Cursor Plugin that ships two engineering skills:

- [`implementation-loop`](#implementation-loop) — delegate implementation to **Codex, grok, or cursor-agent** without delegating judgment: Claude reviews the real diff, runs the full test gate, and ships only what it would sign its name to. The implementer backend is a dial; the review-and-ship discipline is identical for all three.
- `engineering-mode` — goal-first engineering ownership: investigate, design, and plan, then drive `implementation-loop` unit by unit.
- [`cursor-implementation-loop`](#cursor-implementation-loop) — Cursor Plugin with the plan-first implementation loop and the goal-first `cursor-engineering-mode` wrapper; the parent agent reviews, gates, and publishes while an implementer subagent writes code.
- [`web-slides`](#web-slides) — turn material or outlines into click-driven 16:9 HTML slide decks for live presenting, with 24 built-in themes and a presenter view that keeps speaker notes off the shared screen.

## Installation

### Marketplace (recommended)

Inside Claude Code, add the marketplace once, then install the skills you want:

```text
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install implementation-loop@olddonkey-skills
/plugin install engineering-mode@olddonkey-skills
/plugin install web-slides@olddonkey-skills
/reload-plugins
```

These plugins were renamed by dropping the `codex-` prefix because the loop now supports Codex, grok, and cursor-agent backends. If the former Codex-prefixed plugin IDs are installed, uninstall them and install `implementation-loop` and `engineering-mode` instead.

`engineering-mode` requires `implementation-loop`; the Codex backend needs an authenticated `codex` CLI and no additional Claude Code plugin — see [Setup](#setup) below. `web-slides` needs nothing beyond Node.js for the generated slide project.

### Manual

Copy into your personal skills directory:

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
mkdir -p ~/.claude/skills
cp -R /tmp/olddonkey-skills/skills/<skill-name> ~/.claude/skills/
```

Or symlink a clone for pull-to-update:

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
mkdir -p ~/.claude/skills
ln -s ~/Documents/olddonkey-skills/skills/<skill-name> ~/.claude/skills/<skill-name>
```

If you created `~/.claude/skills` for the first time during an active Claude Code session, restart the session so the new top-level directory is discovered. If your agent does not follow symlinks in its skills directory, use the copy option and re-copy after `git pull`.

### Cursor Plugin

For Cursor, the one-line installer copies the standalone skill and both agents into Cursor's discovered directories. It works on all current builds and on a personal or temporary/company machine — it only writes under your home directory:

One-line install (bare-copy default):

```bash
curl -fsSL https://raw.githubusercontent.com/olddonkey/olddonkey-skills/main/install-cursor.sh | bash
```

`--copy` remains accepted as an explicit alias. For older Cursor builds that scan `plugins/local`, opt into the managed-checkout symlink with `--link`:

```bash
curl -fsSL https://raw.githubusercontent.com/olddonkey/olddonkey-skills/main/install-cursor.sh | bash -s -- --link
```

Want true plugin form? In Cursor's Customize → Plugins page, press "+ Add" and select `$OLDDONKEY_SKILLS_DIR` (default: `~/olddonkey-skills`); that checkout root contains `.cursor-plugin/marketplace.json`, which registers the `cursor-implementation-loop` plugin. Then remove the standalone copies to avoid double-loading.

Alternatively, install the local-plugin symlink manually:

```bash
git clone https://github.com/olddonkey/olddonkey-skills
mkdir -p ~/.cursor/plugins/local
ln -s "$(pwd)/olddonkey-skills/cursor-implementation-loop" \
      ~/.cursor/plugins/local/cursor-implementation-loop
# restart Cursor or run "Developer: Reload Window"
```

Verify once:

```bash
bash ~/.cursor/plugins/local/cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh
# expect: selftest: PASS (122 checks)
```

To reproduce the default install manually, copy bare files — both steps are required:

```bash
mkdir -p ~/.cursor/skills ~/.cursor/agents
cp -R olddonkey-skills/cursor-implementation-loop/skills/cursor-implementation-loop \
      ~/.cursor/skills/
cp olddonkey-skills/cursor-implementation-loop/agents/*.md ~/.cursor/agents/
```

To uninstall a symlink install: `rm ~/.cursor/plugins/local/cursor-implementation-loop` and delete the clone. Team marketplaces (Teams/Enterprise) can also import this repository: Dashboard → Plugins → Import from Repo. Manifest: [`.cursor-plugin/marketplace.json`](./.cursor-plugin/marketplace.json).

## Plan-first vs goal-first

**Plan-first (unchanged):** approve a plan, then invoke the implementation loop directly: `Use implementation-loop to implement PLAN.md unit by unit.`

**Goal-first:** give engineering mode an outcome; it investigates the root cause, chooses a design, writes the plan, then drives that same loop. Codex: `Use engineering-mode to fix duplicate fulfillment caused by webhook replay.` Cursor: `Use cursor-engineering-mode to fix duplicate fulfillment caused by webhook replay.`

Codex prerequisites: `engineering-mode` → `implementation-loop` → authenticated `codex` CLI. On Cursor, `cursor-engineering-mode` ships inside the `cursor-implementation-loop` plugin, so there is no separate install; existing installs receive it on update by rerunning the one-line installer or running `git pull` in the managed checkout.

---

## implementation-loop

**Delegate implementation to Codex, grok, or cursor-agent without delegating judgment.**

The implementer implements and runs focused tests. Claude reviews the real diff, runs the full gate, and ships only what it would sign its name to.

**Backend is a dial.** The default is Codex (setup below); the same loop and the same review-and-gate discipline apply whichever backend implements. Each backend's git and publication boundary works differently and is documented in its own runtime reference — read the selected backend's before its first dispatch:

- **grok** — a fail-closed custom sandbox, linked-worktree placement, and a per-machine tuple allowlist. [`references/runtime-grok.md`](./skills/implementation-loop/references/runtime-grok.md).
- **cursor-agent** — a git-less-copy architecture: the implementer edits a `.git`-free copy inside a network-denied sandbox, and the orchestrator applies the captured patch to the real repo (it never runs with `--force`/`--yolo`, which would bypass the sandbox). [`references/runtime-cursor.md`](./skills/implementation-loop/references/runtime-cursor.md).

Both default to Grok 4.6 at `xhigh` as the implementer model, but `--model` is a passthrough on every backend — cursor-agent in particular reaches its whole account catalog (Claude, GPT-5.x, Gemini, Composer, Grok tiers), where the effort level is part of the model id.

### Setup

The loop calls the Codex CLI directly through `codex exec`; no additional
Claude Code plugin is required. Install and authenticate the CLI if needed:

```bash
npm install -g @openai/codex
codex login
```

You can sign in with a ChatGPT account, including Free, or an OpenAI API key. Already installed? Check `codex --version`; if a newly released model is unavailable, a stale CLI is a common cause:

```bash
codex update
```

### Start your first loop

Open the target repository in Claude Code and ask naturally:

> Use implementation-loop to implement item 1 in PLAN.md. Stop at a PR, use the baseline gate, review at standard depth, confirm before the next unit, and inherit my Codex model and effort settings.

Natural-language invocation works with both marketplace and manual installations. On the first run, Claude states the resolved controls before dispatching so cost, autonomy, and the publish boundary are visible.

### How the loop works

**decompose → dispatch → review → iterate → gate → publish → next**

1. Claude turns a plan, spec, or TODO into one coherent, reviewable unit.
2. Codex implements it in the working tree and runs only the focused tests named in the dispatch.
3. Claude reads the actual diff, checks the whole working tree, and dispatches concrete findings again; it uses the same exact Codex session only after resume has passed the required real-backend matrix, and otherwise carries context in a fresh prompt.
4. Claude runs the full test suite itself and interprets it under the chosen gate policy.
5. Claude stops at the configured boundary: working tree, commit, PR, or an explicitly authorized merge.

Codex's summary is a map of where to look, not proof that the change is correct. The diff and the gate are the evidence.

### Why use it

- **Evidence-first review.** The checklist targets delegated-change failures that generic review often misses: weakened tests, silent default regressions, gitignored files, new dependencies, and softened enforcement points.
- **Bounded autonomy.** Seven controls settle how far the loop may act, how deeply it reviews, who implements fixes, and what happens when the gate is red. They are chosen once per repository instead of re-litigated on every unit.
- **Expensive lessons encoded once.** The workflow distinguishes focused tests from the full gate, detects stuck foreground runs from retained transcripts, and covers bounded interruption plus orphaned-process cleanup.
- **Two bundled helpers.** [`codex-dispatch.sh`](./skills/implementation-loop/scripts/codex-dispatch.sh) runs plain `codex exec` with pinned policy, loop-owned state, and banner verification; [`run-gate.sh`](./skills/implementation-loop/scripts/run-gate.sh) preserves the suite's real exit code and can compare failures with a baseline.

Read the complete workflow in [`SKILL.md`](./skills/implementation-loop/SKILL.md).

### Controls

The skill has conservative first-run choices. Specify only the values you want to change:

| Control | Typical first run | Purpose |
| --- | --- | --- |
| Stop point | `pr` | Leave changes in the working tree, commit them, open a PR, or merge when explicitly authorized |
| Dispatch mode | `implement` | Choose an implementation run or a read-only investigation |
| Gate policy | `baseline` | Require no new non-flake failures, zero failures, or explicitly skip the gate for non-runtime changes |
| On gate red | `stop` | Stop for the user or send failures back for a bounded number of iterations |
| Review depth | `standard` | Choose light, standard, or independent deep review |
| Cadence | `confirm` | Confirm between units or continue automatically when the publish strategy makes that safe |
| Fix lane | `codex` | Route bug fixes through Codex as fresh units; optionally allow trivial mechanical one-liners to be fixed directly |

Model and effort inherit the user's Codex configuration unless explicitly overridden for a task.

### Compatibility and limits

- The instructions use the open `SKILL.md` format. The Claude marketplace hosts the skill, while the Codex backend calls an authenticated `codex` CLI directly through plain `codex exec`.
- Other agents can reuse the workflow through the shipped grok and cursor-agent adapters or an adapter implementing the same dispatch contract.
- The scripts require Bash, Python 3.11+, the selected backend CLI, and common Unix command-line tools. They were developed on macOS.
- Codex runs on the same checkout and machine-local environment as Claude Code. Its usage counts toward your ChatGPT or API limits; see [Codex pricing](https://developers.openai.com/codex/pricing).

---

## cursor-implementation-loop

**Cursor Plugin shipping two skills: the plan-first `cursor-implementation-loop` and the goal-first `cursor-engineering-mode` wrapper.**

Same review-gated loop, adapted to Cursor's native subagents: the **parent agent** owns planning, diff review, the full test gate, and publication; a dedicated **implementer** subagent writes code. [`run-gate.sh`](./cursor-implementation-loop/skills/cursor-implementation-loop/scripts/run-gate.sh) is shared verbatim with the Codex skill.

Three Codex hard guarantees (read-only git for the implementer, fail-closed pre-dispatch checks, and per-dispatch model disclosure) have no native Cursor equivalent — they become procedure. Read [`references/cursor-runtime.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/references/cursor-runtime.md) before relying on the loop unattended.

### Tell the agent how to use it

Install the plugin (see [Cursor Plugin](#cursor-plugin)), open the **target repository** in Cursor, then ask in natural language or with an explicit slash command. The parent agent should load [`SKILL.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md) and follow it — you do not need to restate the whole workflow.

Explicit:

```text
/cursor-implementation-loop work through docs/my-plan.md unit by unit.
Stop at a PR, baseline gate, standard review, confirm before the next unit.
```

Natural language (also selects the skill):

> Use cursor-implementation-loop to implement item 1 in PLAN.md. Hand coding to the implementer subagent; you review the real diff, run the full gate yourself, and open a PR. Confirm before the next unit.

On the first run the parent asks one kickoff question (stop point, cadence, which implementer / model), then loops. Prefer pinning a different model on `agents/loop-implementer.md` than the parent — `model: inherit` is only a placeholder and forfeits the pairing value.

### What the agent must do

**decompose → dispatch → review → iterate → gate → publish → next**

1. **Parent** turns a plan/spec/TODO into one coherent, reviewable unit and settles design before dispatch.
2. **Parent** dispatches `loop-implementer` as a foreground Task with a full unit contract (why, exact changes, focused tests, what not to touch). The implementer must not touch git and must not run the full suite by default.
3. **Parent** reads the actual diff and whole working tree; the implementer's report is a claim, not evidence. Findings go back by **resuming the same agent**.
4. **Parent** runs the full suite via `scripts/run-gate.sh` and judges under the chosen gate policy.
5. **Parent** stops at the configured boundary: working tree, commit, PR, or an explicitly authorized merge. Never push straight to the default branch.

Bug fixes found at review or at the gate are new units for the implementer — the parent should not quietly hand-edit "because it's faster."

### Controls (same dials as the Codex skill)

| Control | Typical first run | Purpose |
| --- | --- | --- |
| Stop point | `pr` | Working tree, commit, PR, or merge when authorized |
| Dispatch mode | `implement` | Implementation run or read-only investigation |
| Gate policy | `baseline` | No new non-flake failures, zero failures, or skip for non-runtime changes |
| On gate red | `stop` | Stop for the user or iterate a bounded number of times |
| Review depth | `standard` | Light, standard, or independent deep review (`loop-independent-reviewer`) |
| Cadence | `confirm` | Confirm between units or continue when publish strategy allows |
| Fix lane | `implementer` | Route fixes through the implementer; optional trivial one-liner carve-out |
| Implementer model | pinned variant | User's call — never silently assume `inherit` |

Full workflow: [plugin README](./cursor-implementation-loop/README.md) · [`SKILL.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md) · [cursor-runtime.md](./cursor-implementation-loop/skills/cursor-implementation-loop/references/cursor-runtime.md).

---

## web-slides

**Click-driven 16:9 HTML slide decks for live presenting — cinematic, and deliberately not AI-looking.**

Give it material, an outline, or talking points. It plans the deck with you (chapter split, per-step screen content, info pool), aligns outline / theme / assets / dev mode in a single checkpoint, then builds a Vite + React + TypeScript deck where every click advances one logical beat and every step owns the full screen.

- **Presenter view.** Press `P` for a separate speaker window: current and next speaker notes, a live slide preview, and a timer, synced with the main window via `BroadcastChannel`. In Meet/Zoom, share only the slide window — the audience never sees your notes, even on a single screen. Press `N` for a rehearsal-only notes overlay (it does get captured by screen sharing).
- **24 built-in themes**, each with its own design DNA (`theme.json` + `tokens.css`), plus an anti-AI design methodology: content-driven animation, step-by-step reveal, cinematic whitespace.
- **Hard collaboration checkpoints.** Chapter one is always built on the main thread and human-accepted before the rest is developed chapter-by-chapter, sequentially, or in parallel.
- Good for talks, keynotes, product demos, pitch decks, teaching, and project retros.

Trigger it by asking naturally — "turn this material into slides" — or with `/web-slides`. Skill docs are currently in Chinese: [README](./skills/web-slides/README.md) · [SKILL.md](./skills/web-slides/SKILL.md).

Derived from ConardLi's [garden-skills](https://github.com/ConardLi/garden-skills) (MIT): the narration / TTS / screen-recording pipeline is removed, and live-presenting features (per-step speaker notes, the presenter view) are added on top of the same visual methodology and theme system.

## Update

For a marketplace installation, run inside Claude Code:

```text
/plugin marketplace update olddonkey-skills
/plugin update implementation-loop@olddonkey-skills
/plugin update engineering-mode@olddonkey-skills
/plugin update web-slides@olddonkey-skills
/reload-plugins
```

For a cloned installation, run `git pull`; re-copy the skill when using the copy method.

## License

[MIT](./LICENSE). `web-slides` is derived from [garden-skills](https://github.com/ConardLi/garden-skills), also MIT; upstream attribution is kept inside the skill.
