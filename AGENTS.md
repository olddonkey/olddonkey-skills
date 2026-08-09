# AGENTS.md

## What this repo is

A collection of **Agent Skills** (Markdown SOPs + helper Bash scripts) published
as both a Claude Code marketplace (`.claude-plugin/marketplace.json`) and a
Cursor marketplace (`.cursor-plugin/marketplace.json`). It is not a deployable
service. There are no repo-level dependency manifests (no `package.json`,
lockfile, or Makefile at the root); the toolchain — `bash`, `git`, Node.js/npm,
and `python3` 3.11+ (`tomllib`) — is expected to be preinstalled, so a startup
update script has nothing to install.

Components:

- `skills/codex-implementation-loop/` — the original Codex loop skill. Bash
  helpers in `scripts/`: `codex-dispatch.sh`, `run-gate.sh`, and the regression
  harness `selftest.sh`.
- `skills/codex-engineering-mode/` — goal-first wrapper over the loop. Shared
  playbooks in `references/playbooks/`, plus `scripts/tree-oid.sh` and its
  selftest.
- `skills/web-slides/` — a scaffolder (`scripts/scaffold.sh`) that generates a
  runnable Vite + React + TypeScript slide deck. The only runnable "app".
- `cursor-implementation-loop/` — the Cursor plugin port. Ships two skills
  (`cursor-implementation-loop`, `cursor-engineering-mode`) and two agents
  (`agents/loop-implementer.md`, `agents/loop-independent-reviewer.md`).
  Manifest: `.cursor-plugin/plugin.json`.
- `install-cursor.sh` / `install-cursor-selftest.sh` — root-level one-line
  installer for the Cursor plugin (`curl … install-cursor.sh | bash`), plus its
  own selftest.
- `plans/`, `docs/` — design plans and review records; prose only, no CI hooks.

## Invariants CI will hold you to

`.github/workflows/selftest.yml` runs two jobs. Reproduce locally from the repo
root in this order — all suites are self-contained, need no network, and the
Codex/Cursor CLIs are **not** required (they are only needed to dispatch a live
run):

1. `bash -n` syntax checks on all seven shipped scripts (three Codex-loop
   scripts, two Cursor gate scripts, both installer scripts).
2. **Byte-for-byte shared-file checks** (`diff -q`): `run-gate.sh` must stay
   identical between `skills/codex-implementation-loop/scripts/` and
   `cursor-implementation-loop/skills/cursor-implementation-loop/scripts/`; the
   six engineering-mode playbooks, `verification-contract.md`, `handoff.md`,
   `tree-oid.sh`, and `tree-oid-selftest.sh` must stay identical between
   `skills/codex-engineering-mode/` and
   `cursor-implementation-loop/skills/cursor-engineering-mode/`. **If you edit
   one copy, mirror the other in the same commit.**
3. Playbooks must stay platform-neutral: no `read-only` / `investigate` words
   and no `codex-dispatch` references anywhere under either
   `references/playbooks/` tree.
4. `bash skills/codex-implementation-loop/scripts/selftest.sh` — expect
   `selftest: PASS (217 checks)`. The dispatch checks that need `tomllib` run
   fully on python3 ≥ 3.11; on older hosts they self-skip while keeping a
   stable check count.
5. `bash cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh`
   — expect `selftest: PASS (122 checks)`.
6. `bash install-cursor-selftest.sh` — expect `selftest: PASS (64 checks)`.
7. Packaging checks: both marketplace JSON manifests must parse; every
   `SKILL.md` (under `skills/` and `cursor-implementation-loop/skills/`) must
   have non-empty `name:` and `description:` frontmatter; engineering-mode
   Markdown must have no dangling relative links.
8. `tree-oid` job (runs on ubuntu **and** macos):
   `bash skills/codex-engineering-mode/scripts/tree-oid-selftest.sh` and the
   Cursor copy — expect `selftest: PASS (202 checks)` each. Keep these scripts
   portable across GNU and BSD userlands.

## Running the web-slides app (non-obvious gotchas)

Scaffold, then run the Vite dev server:

```bash
cd /tmp                                   # a scratch parent dir, NOT the repo
bash <repo>/skills/web-slides/scripts/scaffold.sh ws-demo --theme=midnight-press
cd ws-demo && npm run dev                 # serves http://localhost:5174/
```

- **Pass a RELATIVE target dir and run from the intended parent.** Current
  `npm create vite` (create-vite v9+) resolves the project path against the
  cwd and mishandles a leading `/`, so an absolute target like `/tmp/ws-demo`
  gets scaffolded into `$PWD/tmp/ws-demo` and the script's later `cd` fails.
  Don't scaffold from inside the repo checkout — it would drop an untracked
  deck into the repo.
- The first `npm create vite` invocation may no-op while it downloads
  `create-vite`; if the target dir wasn't created, just re-run — the package
  is cached the second time.
- The scaffolder runs `npm install` and `npx tsc --noEmit` itself and aborts
  on type errors, so a successful scaffold already typechecks.
- Dev server port is fixed to `5174` in `templates/vite.config.ts`. In the
  deck: click the stage / `→` / space advances one step, `P` opens the
  presenter window, `N` toggles the notes overlay. List themes with
  `scaffold.sh --list-themes`; default is `midnight-press`.
