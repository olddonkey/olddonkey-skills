<div align="center">

# Olddonkey Skills

**Delegate implementation to Codex without delegating judgment.**

Open-source [Agent Skills](https://agentskills.io) distilled from workflows that ran, broke, and got fixed.

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [简体中文](./README.zh-CN.md)

</div>

---

The featured skill, [`codex-implementation-loop`](./skills/codex-implementation-loop), lets Claude Code hand implementation to Codex while keeping diff review, full-suite gating, and release decisions in Claude's hands.

**Codex implements and runs focused tests. Claude reviews the real diff, runs the full gate, and ships only what it would sign its name to.**

## Quick start

### 1. Install

Run these commands inside Claude Code:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install codex-implementation-loop@olddonkey-skills
/reload-plugins
/codex:setup
```

`/codex:setup` comes from the official [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc). It checks whether the Codex CLI is installed and authenticated. The plugin requires Node.js 18.18 or later and can offer to install the CLI when npm is available. To set it up manually instead:

```bash
npm install -g @openai/codex
codex login
```

You can sign in with a ChatGPT account, including Free, or an OpenAI API key. Already installed? Check `codex --version`; if a newly released model is unavailable, a stale CLI is a common cause:

```bash
codex update
```

### 2. Start your first loop

Open the target repository in Claude Code and ask naturally:

> Use codex-implementation-loop to implement item 1 in PLAN.md. Stop at a PR, use the baseline gate, review at standard depth, confirm before the next unit, and inherit my Codex model and effort settings.

Natural-language invocation works with both marketplace and manual installations. On the first run, Claude states the resolved controls before dispatching so cost, autonomy, and the publish boundary are visible.

## How the loop works

**decompose → dispatch → review → iterate → gate → publish → next**

1. Claude turns a plan, spec, or TODO into one coherent, reviewable unit.
2. Codex implements it in the working tree and runs only the focused tests named in the dispatch.
3. Claude reads the actual diff, checks the whole working tree, and sends concrete findings back on the same Codex thread.
4. Claude runs the full test suite itself and interprets it under the chosen gate policy.
5. Claude stops at the configured boundary: working tree, commit, PR, or an explicitly authorized merge.

Codex's summary is a map of where to look, not proof that the change is correct. The diff and the gate are the evidence.

## Why use it

- **Evidence-first review.** The checklist targets delegated-change failures that generic review often misses: weakened tests, silent default regressions, gitignored files, new dependencies, and softened enforcement points.
- **Bounded autonomy.** Seven controls settle how far the loop may act, how deeply it reviews, who implements fixes, and what happens when the gate is red. They are chosen once per repository instead of re-litigated on every unit.
- **Expensive lessons encoded once.** The workflow distinguishes focused tests from the full gate, detects stuck jobs by their event stream, and covers cancellation plus orphaned-process cleanup.
- **Two bundled helpers.** [`codex-dispatch.sh`](./skills/codex-implementation-loop/scripts/codex-dispatch.sh) locates the live companion runtime and makes dispatch settings visible; [`run-gate.sh`](./skills/codex-implementation-loop/scripts/run-gate.sh) preserves the suite's real exit code and can compare failures with a baseline.

Read the complete workflow in [`SKILL.md`](./skills/codex-implementation-loop/SKILL.md).

## Controls

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

## Manual installation

These options replace only the two `olddonkey-skills` marketplace commands in Quick start. The official Codex plugin and an authenticated Codex CLI are still required.

### Copy into your personal skills directory

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
mkdir -p ~/.claude/skills
cp -R /tmp/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/
```

### Symlink a clone for pull-to-update

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
mkdir -p ~/.claude/skills
ln -s ~/Documents/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/codex-implementation-loop
```

If you created `~/.claude/skills` for the first time during an active Claude Code session, restart the session so the new top-level directory is discovered. If your agent does not follow symlinks in its skills directory, use the copy option and re-copy after `git pull`.

## Compatibility and limits

- The instructions use the open `SKILL.md` format, but the current runtime and bundled dispatch script are built and tested for **Claude Code plus the official [OpenAI Codex plugin](https://github.com/openai/codex-plugin-cc)**.
- Other agents can reuse the workflow, but they need an adapter for their own dispatch runtime; `codex-dispatch.sh` currently discovers `codex-companion` inside Claude Code's plugin directories.
- The scripts require Bash, Node.js, and common Unix command-line tools. They were developed on macOS.
- Codex runs on the same checkout and machine-local environment as Claude Code. Its usage counts toward your ChatGPT or API limits; see [Codex pricing](https://developers.openai.com/codex/pricing).

## Update

For a marketplace installation, run inside Claude Code:

```text
/plugin marketplace update olddonkey-skills
/plugin update codex-implementation-loop@olddonkey-skills
/reload-plugins
```

For a cloned installation, run `git pull`; re-copy the skill when using the copy method.

## License

[MIT](./LICENSE)
