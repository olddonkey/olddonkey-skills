<div align="center">

# Olddonkey Skills

**Open-source [Agent Skills](https://agentskills.io) distilled from workflows that ran, broke, and got fixed.**

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [简体中文](./README.zh-CN.md)

</div>

---

Two skills so far:

- [`codex-implementation-loop`](#codex-implementation-loop) — delegate implementation to Codex without delegating judgment: Claude reviews the real diff, runs the full test gate, and ships only what it would sign its name to.
- [`web-slides`](#web-slides) — turn material or outlines into click-driven 16:9 HTML slide decks for live presenting, with 24 built-in themes and a presenter view that keeps speaker notes off the shared screen.

## Installation

### Marketplace (recommended)

Inside Claude Code, add the marketplace once, then install either skill or both:

```text
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install codex-implementation-loop@olddonkey-skills
/plugin install web-slides@olddonkey-skills
/reload-plugins
```

`codex-implementation-loop` additionally needs the official Codex plugin and an authenticated Codex CLI — see [Setup](#setup) below. `web-slides` needs nothing beyond Node.js for the generated slide project.

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

---

## codex-implementation-loop

**Delegate implementation to Codex without delegating judgment.**

Codex implements and runs focused tests. Claude reviews the real diff, runs the full gate, and ships only what it would sign its name to.

### Setup

The loop drives the official [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc):

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

`/codex:setup` checks whether the Codex CLI is installed and authenticated. The plugin requires Node.js 18.18 or later and can offer to install the CLI when npm is available. To set it up manually instead:

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

> Use codex-implementation-loop to implement item 1 in PLAN.md. Stop at a PR, use the baseline gate, review at standard depth, confirm before the next unit, and inherit my Codex model and effort settings.

Natural-language invocation works with both marketplace and manual installations. On the first run, Claude states the resolved controls before dispatching so cost, autonomy, and the publish boundary are visible.

### How the loop works

**decompose → dispatch → review → iterate → gate → publish → next**

1. Claude turns a plan, spec, or TODO into one coherent, reviewable unit.
2. Codex implements it in the working tree and runs only the focused tests named in the dispatch.
3. Claude reads the actual diff, checks the whole working tree, and sends concrete findings back on the same Codex thread.
4. Claude runs the full test suite itself and interprets it under the chosen gate policy.
5. Claude stops at the configured boundary: working tree, commit, PR, or an explicitly authorized merge.

Codex's summary is a map of where to look, not proof that the change is correct. The diff and the gate are the evidence.

### Why use it

- **Evidence-first review.** The checklist targets delegated-change failures that generic review often misses: weakened tests, silent default regressions, gitignored files, new dependencies, and softened enforcement points.
- **Bounded autonomy.** Seven controls settle how far the loop may act, how deeply it reviews, who implements fixes, and what happens when the gate is red. They are chosen once per repository instead of re-litigated on every unit.
- **Expensive lessons encoded once.** The workflow distinguishes focused tests from the full gate, detects stuck jobs by their event stream, and covers cancellation plus orphaned-process cleanup.
- **Two bundled helpers.** [`codex-dispatch.sh`](./skills/codex-implementation-loop/scripts/codex-dispatch.sh) locates the live companion runtime and makes dispatch settings visible; [`run-gate.sh`](./skills/codex-implementation-loop/scripts/run-gate.sh) preserves the suite's real exit code and can compare failures with a baseline.

Read the complete workflow in [`SKILL.md`](./skills/codex-implementation-loop/SKILL.md).

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

- The instructions use the open `SKILL.md` format, but the current runtime and bundled dispatch script are built and tested for **Claude Code plus the official [OpenAI Codex plugin](https://github.com/openai/codex-plugin-cc)**.
- Other agents can reuse the workflow, but they need an adapter for their own dispatch runtime; `codex-dispatch.sh` currently discovers `codex-companion` inside Claude Code's plugin directories.
- The scripts require Bash, Node.js, and common Unix command-line tools. They were developed on macOS.
- Codex runs on the same checkout and machine-local environment as Claude Code. Its usage counts toward your ChatGPT or API limits; see [Codex pricing](https://developers.openai.com/codex/pricing).

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
/plugin update codex-implementation-loop@olddonkey-skills
/plugin update web-slides@olddonkey-skills
/reload-plugins
```

For a cloned installation, run `git pull`; re-copy the skill when using the copy method.

## License

[MIT](./LICENSE). `web-slides` is derived from [garden-skills](https://github.com/ConardLi/garden-skills), also MIT; upstream attribution is kept inside the skill.
