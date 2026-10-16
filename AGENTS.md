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

- `skills/implementation-loop/` — the implementation loop skill: one model
  implements, a model from another vendor reviews, and the session owns the
  gate and publication. The two backend modules live under
  `backends/{claude,codex}/`, each with `dispatch.sh`, `runtime.md`,
  `selftest.sh`, and `fixture-driver.sh`. `backends/backends.tsv` registers
  their capabilities. The grok and cursor-agent backends were removed in
  2026-10 and stay in main's history; the journal, index, and console still
  read their old state and records. Shared suites and the opt-in real-backend
  gate live under `tests/`; the frozen Codex matrix is `tests/codex-cases.tsv`.
  `scripts/run-gate.sh` remains the backend-neutral gate, while
  `scripts/codex-dispatch.sh` and `scripts/selftest.sh` are one-release
  forwarding shims removed in 0.5.0. The shared observable interface
  is recorded in `references/dispatch-contract.md` and enforced by the contract
  suites. The headless `loop-coordinator` (collab-canvas) was removed in
  2026-10 because `SKILL.md` never called it; it stays in main's history and on
  the `canvas-u3-run` branch.
- `skills/engineering-mode/` — goal-first wrapper over the loop. Shared
  playbooks in `references/playbooks/`, plus `scripts/tree-oid.sh` and its
  selftest.
- `skills/web-slides/` — a scaffolder (`scripts/scaffold.sh`) that generates a
  runnable Vite + React + TypeScript slide deck. The only runnable "app".
- `cursor-implementation-loop/` — the generated Cursor plugin port. It ships
  two skills (`cursor-implementation-loop`, `cursor-engineering-mode`) and two
  agents (`agents/loop-implementer.md`, `agents/loop-independent-reviewer.md`).
  Edit shared inputs under `skills/` or Cursor-authored inputs under
  `hosts/cursor/`, then run `bash build.sh`; do not hand-edit the generated
  tree. Manifest: `.cursor-plugin/plugin.json`.
- `build.sh`, `hosts/cursor/`, `tests/build-{inventory.py,selftest.sh}` — the
  deterministic Cursor-package generator, its host-only overlay, and its
  external-inventory/selftest tooling. `bash build.sh --check` verifies the
  committed tree and its recorded version decision without rewriting it.
- `install-cursor.sh` / `install-cursor-selftest.sh` — root-level one-line
  installer for the Cursor plugin (`curl … install-cursor.sh | bash`), plus its
  own selftest.
- `plans/`, `docs/` — design plans and review records; prose only, no CI hooks.

## Invariants CI will hold you to

`.github/workflows/selftest.yml` runs two jobs. Reproduce locally from the repo
root in this order — all suites are self-contained, need no network, and the
backend CLIs are **not** required (they are only needed to dispatch a live
run). A suite passes when it exits 0 and prints its `PASS` summary line with
no failed checks; check counts move with every change and are not pinned here.

1. `bash -n` syntax checks on every shipped shell script: the builder and its
   selftest, backend modules and fixture drivers, shared tests, the gate, all
   forwarding shims, the two generated Cursor gate scripts, and both installer
   scripts.
2. **Generated Cursor package checks:** `bash build.sh --check`, two builds into
   separate temporary destinations with byte-identical external inventories,
   then `bash tests/build-selftest.sh`.
   The inventory records path, type, mode, and SHA-256 independently of the
   embedded manifest. Edit `skills/` or `hosts/cursor/`, run `bash build.sh`,
   and record the version decision in `hosts/cursor/version-decision.tsv`.
3. Playbooks must stay platform-neutral: no `read-only` / `investigate` words
   and no `codex-dispatch` references anywhere under either
   `references/playbooks/` tree.
4. `bash skills/implementation-loop/backends/codex/selftest.sh`, then
   `bash skills/implementation-loop/tests/gate-selftest.sh`. The Codex cases
   use python3 for secure state, argv, and fixture validation; python3 3.11+ is
   part of the repo toolchain. The Codex suite also starts, signals, and kills
   real stub processes to cover stop signals and `--recover-stale`; it needs no
   network and no codex CLI.
5. `bash skills/implementation-loop/backends/claude/selftest.sh`.
6. `bash skills/implementation-loop/tests/journal-selftest.sh`,
   `bash skills/implementation-loop/tests/index-selftest.sh`,
   `bash skills/implementation-loop/tests/console-selftest.sh`, and
   `bash skills/implementation-loop/tests/calibration-selftest.sh`. The
   journal, console, and calibration suites each run
   `tests/link-count-cases.py`, which loads that script's Python body and
   calls its `validate_regular` directly.
7. `bash skills/implementation-loop/tests/contract-core.sh`,
   `bash skills/implementation-loop/tests/contract-negative.sh`, and
   `bash skills/implementation-loop/tests/shim-selftest.sh`. Contract-core runs
   every registered backend; contract-negative must report every broken
   adapter rejected.
8. `bash skills/implementation-loop/tests/evidence-selftest.sh` (the
   `scripts/loop-evidence` record card).
9. `bash cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh`.
10. `bash install-cursor-selftest.sh`.
11. Packaging checks: both marketplace JSON manifests must parse; every
   `SKILL.md` (under `skills/` and `cursor-implementation-loop/skills/`) must
   have non-empty `name:` and `description:` frontmatter; engineering-mode and
   implementation-loop Markdown must have no dangling relative links.
12. `tree-oid` job (runs on ubuntu **and** macos):
   `bash skills/engineering-mode/scripts/tree-oid-selftest.sh` and the
   Cursor copy. Keep these scripts portable across GNU and BSD userlands.

## Process rules (keep the skill small)

These come from the 2026-10 review that found the loop had grown to ~71k lines
around machinery nothing called.

- **Plan review stops at 3 rounds.** Every plan-review prompt must answer
  "Does this part have a caller now? What happens if we don't build it?" for
  each part of the plan. Adversarial review only finds holes and never says "don't
  build this", so an unbounded review keeps adding mechanism.
- **No caller, no main.** A new subsystem reaches main only when `SKILL.md`
  has a step that uses it. Code nothing calls stays on its branch or in
  `plans/`.
- **No pinned check counts.** This file and CI check that a suite passes, not
  how many checks it has, so a change never needs a commit just to update
  numbers.

## Shell gotcha: locale prefixes in forked shells

Inside `$(...)`, `( ... )`, `<( ... )`, or a function called from one of them,
write `env LC_ALL=C cmd`, never a bare `LC_ALL=C cmd` (same for `LANG` and other
`LC_*`). After a bare prefix the forked shell restores its own locale; with
Homebrew bash 5.3 on macOS and no `LANG`/`LC_*` in the environment that restore
can segfault, so the substitution returns 139 and `set -e` ends the script.
A bare prefix in a script's own main shell is safe. `env` runs external
commands only, not shell functions or builtins.

## Manual backend integration gate

`skills/implementation-loop/tests/integration-test.sh` is the manual,
opt-in pre-release gate for backend changes. It exercises the real claude and
codex sandboxes, needs authenticated CLIs, and makes real API calls.
`--backend claude|codex|all` is repeatable and deduplicated; `--require
codex` implies codex and fails unless every frozen non-managed Codex case runs
exactly once with no skip/failure and complete provenance. Unavailable or
logged-out backends otherwise remain skips. `--require claude` implies claude and
fails if any Claude case is skipped. CI only runs `bash -n` on this
script and never executes it.

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
