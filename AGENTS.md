# AGENTS.md

## Cursor Cloud specific instructions

This repository is a collection of **Agent Skills** (Markdown SOPs + helper Bash
scripts), not a long-running service. There is no repo-level `package.json`,
lockfile, or `requirements.txt`; all runtimes (Bash, Node.js, npm, and
`python3` with `tomllib`) are already provided by the environment, so the
startup update script has nothing to install.

There are three components:

- `skills/codex-implementation-loop/` — Bash scripts (`codex-dispatch.sh`,
  `run-gate.sh`) plus a self-test suite `scripts/selftest.sh`.
- `cursor-implementation-loop/` — Cursor plugin port; ships `run-gate.sh`
  (byte-for-byte identical to the Codex copy) and `scripts/gate-selftest.sh`.
- `skills/web-slides/` — a scaffolder that generates a runnable
  Vite + React + TypeScript slide deck. This is the only runnable "app".

### Lint / test (the CI gate)

CI is `.github/workflows/selftest.yml`. Reproduce it locally by running the same
steps it runs (in order): `bash -n` syntax checks on all five scripts, a
`diff -q` proving the two `run-gate.sh` copies are identical, then
`bash skills/codex-implementation-loop/scripts/selftest.sh` (expect
`selftest: PASS (217 checks)`) and
`bash cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh`
(expect `selftest: PASS (122 checks)`). The `selftest.sh` dispatch checks that
depend on `tomllib` run fully here (python3 3.12 has it); on a host without it
they self-skip while keeping a stable check count.

### Running the web-slides app (non-obvious gotchas)

Scaffold, then run the Vite dev server (per `skills/web-slides/scripts/scaffold.sh`):

```bash
cd /tmp                                                  # a scratch parent dir
bash /workspace/skills/web-slides/scripts/scaffold.sh ws-demo --theme=midnight-press
cd ws-demo && npm run dev                                # serves http://localhost:5174/
```

- **Pass a RELATIVE target dir and run from the intended parent.** The current
  `create-vite` (v9+) resolves the project path relative to the working
  directory and mishandles a leading `/`, so an absolute target like
  `/tmp/ws-demo` gets scaffolded into `$PWD/tmp/ws-demo` and the script's later
  `cd "$TARGET"` fails with "No such file or directory". Do not scaffold from
  inside `/workspace` (it would drop an untracked `tmp/ws-demo` into the repo).
- **First `npm create vite` invocation may no-op while it downloads
  `create-vite`.** If the very first scaffold attempt exits without creating the
  dir, just re-run it — the package is cached on the second run.
- The scaffolder runs `npx tsc --noEmit` itself and aborts on type errors, so a
  successful scaffold already means the generated project typechecks.
- Dev server is fixed to port `5174` (`templates/vite.config.ts`). In the deck,
  arrow keys / space / clicking the stage advance one step; `P` opens the
  presenter view at `/presenter`; `N` toggles the notes overlay.
