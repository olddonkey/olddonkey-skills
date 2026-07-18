<div align="center">

# Donkey Skills

**Open-source [Agent Skills](https://support.claude.com/en/articles/12512176-what-are-skills) distilled from real-world usage — for Claude Code and any agent that speaks the `SKILL.md` format.**

[![License: MIT](https://img.shields.io/github/license/olddonkey/donkey-skills?style=flat-square&color=blue)](./LICENSE)
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

**Requires:** [Claude Code](https://claude.com/claude-code) with the [OpenAI Codex plugin](https://github.com/openai/codex) installed (provides the `codex-companion` runtime), and a working `codex` CLI login.

---

## Install

### Option A — Claude Code plugin marketplace

```text
/plugin marketplace add olddonkey/donkey-skills
/plugin install codex-implementation-loop@donkey-skills
```

### Option B — copy into your personal skills directory

```bash
git clone https://github.com/olddonkey/donkey-skills /tmp/donkey-skills
cp -R /tmp/donkey-skills/skills/codex-implementation-loop ~/.claude/skills/
```

### Option C — git clone straight into skills (pull to update)

```bash
git clone https://github.com/olddonkey/donkey-skills ~/Documents/donkey-skills
ln -s ~/Documents/donkey-skills/skills/codex-implementation-loop ~/.claude/skills/codex-implementation-loop
```

> If your agent doesn't follow symlinks in the skills directory, use Option B and re-copy after `git pull`.

## Compatibility

Skills follow the plain `SKILL.md` format (YAML frontmatter + Markdown instructions + bundled `scripts/`). Built and tested with Claude Code; anything that reads the same format should work, though the bundled shell scripts assume a POSIX environment (developed on macOS).

## License

[MIT](./LICENSE)
