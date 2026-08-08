# AGENTS.md

## Cursor Cloud specific instructions

This repo is a **Claude Code / Agent Skills marketplace** (`.claude-plugin/marketplace.json`), not a deployable
application or service. It ships two skills under `skills/`:

- `codex-implementation-loop` — Markdown spec (`SKILL.md`) plus Bash helper scripts in `scripts/`.
- `web-slides` — a Vite + React + TypeScript slide-deck **template** (`templates/`) scaffolded on demand by
  `scripts/scaffold.sh`.

There are **no repo-level dependency manifests** (no `package.json`, lockfile, Makefile, or Dockerfile at the root).
The toolchain it needs — `bash`, `git`, and Node.js/npm — is preinstalled system-wide, so the startup update script has
nothing to install.

### Lint + test (the CI gate)

The only automated checks are defined in `.github/workflows/selftest.yml`:

- Lint = Bash syntax check: `bash -n` on the three scripts in `skills/codex-implementation-loop/scripts/`.
- Test = `bash skills/codex-implementation-loop/scripts/selftest.sh` (a self-contained regression harness; ~217
  checks, needs no network or external tools).

Run both from the repo root. The Codex CLI/plugin is **not** required for the selftest — it is only needed to actually
dispatch a live `codex-implementation-loop` run.

### Running the `web-slides` app

`scripts/scaffold.sh` generates a runnable Vite deck, installs its deps (`npm install`), and typechecks it
(`npx tsc --noEmit`). The dev server (`npm run dev`) serves on **port 5174** (hardcoded in `templates/vite.config.ts`).

Non-obvious gotchas discovered during setup:

- **Pass a RELATIVE target dir to `scaffold.sh`, run from the intended parent directory.** The current
  `npm create vite@latest` (create-vite v9+) strips the leading `/` from an **absolute** target path and treats it as
  relative to the cwd, so `scaffold.sh /abs/path ...` scaffolds into `$CWD/abs/path` and then its `cd` fails. Working
  invocation: `cd /tmp && bash /workspace/skills/web-slides/scripts/scaffold.sh demo-deck --theme=midnight-press`.
- List themes with `bash skills/web-slides/scripts/scaffold.sh --list-themes`; default theme is `midnight-press`.
- The generated deck is click/keyboard-driven: click the stage or press `→`/space to advance one step, `P` opens the
  presenter window, `N` toggles the notes overlay.
