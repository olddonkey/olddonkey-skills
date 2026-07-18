<div align="center">

# Olddonkey Skills

**Open-source [Agent Skills](https://support.claude.com/en/articles/12512176-what-are-skills) distilled from real-world usage — for Claude Code and any agent that speaks the `SKILL.md` format.**

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Skills count](https://img.shields.io/badge/skills-1-orange?style=flat-square)](#skills)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [中文文档](./README.zh-CN.md)

</div>

---

Every skill here was extracted from a workflow that actually ran, broke, and got fixed — the constraints encoded in them were paid for in real debugging hours, not imagined. Where a rule sounds oddly specific ("never let Codex run the full test suite"), that's because it once cost an afternoon.

## Skills

### [`codex-implementation-loop`](./skills/codex-implementation-loop)

**Category:** Delegated implementation / orchestration
**Good for:** working through a plan, spec, or TODO list where Codex writes the code and Claude owns review, test-gating, and shipping.

A division of labor: **Codex writes the code, Claude keeps the judgment.** The loop runs *decompose → dispatch → review → iterate → gate → publish → next*, with Claude reading the actual diff (Codex's self-report is a claim, not evidence), running the full test suite itself, and shipping only what it would sign its name to.

Highlights:

- **Six user-configurable dials**, settled once per repo and recorded: stop point (`worktree`/`commit`/`pr`/`merge`), dispatch mode (`implement`/`read-only`), gate policy (`baseline`/`strict`/`skip`), on-gate-red (`stop`/`iterate`), review depth (`light`/`standard`/`deep`), cadence (`confirm`/`continuous`)
- **Model/effort respect the user's own Codex config** by default — flags only override per-task, and the skill knows which effort levels are flag-reachable vs config-only
- **A delegated-diff review checklist** that hunts what generic code review misses: silent regressions from changed defaults, tests weakened to pass, gitignored files that will never ship, quietly added dependencies, softened enforcement points
- **Environment constraints that are expensive to rediscover**: Codex runs in the real environment with effectively read-only git; never ask it to run a full test suite; stuck-job heuristics, cancel commands, and orphaned-test-process cleanup
- **Two battle-tested scripts**: `codex-dispatch.sh` (locates the newest companion runtime, validates flags, prints the workspace so wrong-directory dispatches are visible) and `run-gate.sh` (reports the *real* suite exit code — never masked by a pipe — with baseline comparison for flaky suites)

Links: [SKILL.md](./skills/codex-implementation-loop/SKILL.md) · [scripts](./skills/codex-implementation-loop/scripts)

**Requires:** [Claude Code](https://claude.com/claude-code) + the official OpenAI Codex plugin (provides the `codex-companion` runtime) + a logged-in `codex` CLI — setup steps below.

---

## Prerequisite — set up Codex

This skill drives Codex through the official [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc). Install and log in once; the skill handles everything after that.

Inside Claude Code:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

`/codex:setup` checks whether the `codex` CLI is ready — if it's missing and npm is available, it offers to install it for you. To do it manually instead:

```bash
npm install -g @openai/codex   # requires Node.js ≥ 18.18
codex login                    # ChatGPT account (incl. Free) or OpenAI API key
```

> Codex usage counts toward your ChatGPT / API usage limits — see [Codex pricing](https://developers.openai.com/codex/pricing).

## Install

### Option A — Claude Code plugin marketplace

```text
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install codex-implementation-loop@olddonkey-skills
```

### Option B — copy into your personal skills directory

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
cp -R /tmp/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/
```

### Option C — git clone straight into skills (pull to update)

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
ln -s ~/Documents/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/codex-implementation-loop
```

> If your agent doesn't follow symlinks in the skills directory, use Option B and re-copy after `git pull`.

## Compatibility

Skills follow the plain `SKILL.md` format (YAML frontmatter + Markdown instructions + bundled `scripts/`). Built and tested with Claude Code; anything that reads the same format should work, though the bundled shell scripts assume a POSIX environment (developed on macOS).

## License

[MIT](./LICENSE)
