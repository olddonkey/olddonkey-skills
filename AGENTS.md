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

- `skills/implementation-loop/` — the backend-neutral implementation loop skill.
  Uniform backend modules live under `backends/{claude,codex,grok,cursor}/`, each with
  `dispatch.sh`, `runtime.md`, `selftest.sh`, and `fixture-driver.sh`; grok also
  has `verify-worktree.sh`. `backends/backends.tsv` registers their capabilities.
  Shared suites and the opt-in real-backend gate live under `tests/`; the frozen
  Codex matrix is `tests/codex-cases.tsv`. `scripts/run-gate.sh` remains the
  backend-neutral gate, while the other eight `scripts/*.sh` executables are
  one-release forwarding shims removed in 0.5.0. The shared observable interface
  is recorded in `references/dispatch-contract.md` and enforced by the contract
  suites. `scripts/loop-coordinator` is the foreground, headless coordinator:
  it drafts specs through a judge, records engineer approval, and performs a
  diagnostic diff review. Its operator guide is `references/coordinator.md`;
  `tests/coordinator-selftest.sh` uses temporary repositories and CLI stubs.
  `lib/loopauth/` is stdlib-only python3 shared by `scripts/loop-journal`,
  `scripts/loop-index`, and `scripts/loop-authority` (canonical JSON and
  digests, the task-graph-v1 schema-2 vocabulary, the pure reducer, and the
  0a.2 authority store: records, framing, keys and seals, the git anchor,
  recovery, the operator-TTY ceremonies, the admission registry, and
  `tools.py`, the one subprocess wrapper with its closed command table); each
  imports it only from the `lib/` beside its real `scripts/` directory and
  refuses a symlinked `lib/`. `scripts/loop-authority-verify` is the
  independent authority verifier and imports nothing from `lib/loopauth`.
  Both authority wrappers write nothing themselves and run their Python entry
  file beside them (`scripts/loop-authority.py`,
  `scripts/loop-authority-verify.py`). The authority store is described in
  `references/state-schema.md` section 6; ceremonies need a terminal, and
  `LOOP_AUTHORITY_TEST=1` (tests only) admits a `file://` remote that can only
  ever form a non-authorizing test lineage.
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

`.github/workflows/selftest.yml` runs the `scripts` job, the sharded authority
crash matrix (`crash-matrix-plan`, eight `crash-matrix` shards, and
`crash-matrix-coverage`; see step 12), `authority-macos`, and `tree-oid`. Reproduce locally from
the repo root in this order — all suites are self-contained, need no network, and the
backend CLIs are **not** required (they are only needed to dispatch a live
run):

1. `bash -n` syntax checks on every shipped shell script: the builder and its
   selftest, backend modules and fixture drivers, shared tests, the gate, all
   forwarding shims, the two generated Cursor gate scripts, and both installer
   scripts.
2. **Generated Cursor package checks:** `bash build.sh --check`, two builds into
   separate temporary destinations with byte-identical external inventories,
   then `bash tests/build-selftest.sh` (expect `selftest: PASS (21 checks)`).
   The inventory records path, type, mode, and SHA-256 independently of the
   embedded manifest. Edit `skills/` or `hosts/cursor/`, run `bash build.sh`,
   and record the version decision in `hosts/cursor/version-decision.tsv`.
3. Playbooks must stay platform-neutral: no `read-only` / `investigate` words
   and no `codex-dispatch` references anywhere under either
   `references/playbooks/` tree.
4. `bash skills/implementation-loop/backends/codex/selftest.sh` — expect
   `selftest: PASS (166 checks)`, then
   `bash skills/implementation-loop/tests/gate-selftest.sh` — expect
   `selftest: PASS (207 checks)`. Their split total is 373. The Codex cases
   use python3 for secure state, argv, and fixture validation; python3 3.11+ is
   part of the repo toolchain.
5. `bash skills/implementation-loop/backends/grok/selftest.sh` — expect
   `selftest: PASS (276 checks)`.
6. `bash skills/implementation-loop/backends/cursor/selftest.sh` — expect
   `selftest: PASS (142 checks)`.
   `bash skills/implementation-loop/backends/claude/selftest.sh` — expect
   `selftest: PASS (303 checks)`.
7. `bash skills/implementation-loop/tests/journal-selftest.sh` — expect
   `selftest: PASS (604 checks)`; `bash skills/implementation-loop/tests/index-selftest.sh`
   — expect `selftest: PASS (111 checks)`; and
   `bash skills/implementation-loop/tests/console-selftest.sh` — expect
   `selftest: PASS (151 checks)`.
8. `bash skills/implementation-loop/tests/contract-core.sh`,
   `bash skills/implementation-loop/tests/contract-negative.sh`, and
   `bash skills/implementation-loop/tests/shim-selftest.sh` — expect all green.
   The contract-core per-backend counts are claude 61, codex 63, cursor 67,
   and grok 63. Contract-negative expects
   `contract-negative: PASS (42 checks; 21 broken adapters rejected)`.
9. `bash skills/implementation-loop/tests/evidence-selftest.sh` (the
   `scripts/loop-evidence` record card) — expect `selftest: PASS (152 checks)`.
10. `bash skills/implementation-loop/tests/coordinator-selftest.sh` — expect
    `selftest: PASS (735 checks)`. It uses only local temporary repositories
    and backend CLI stubs, and never calls a real agent. `COORD_SELFTEST_JOBS`
    defaults to 4; set it to 1 for declaration-order serial execution.
11. `bash skills/implementation-loop/tests/reduce-selftest.sh` (`lib/loopauth`:
   canonical encoding, the schema-2 vocabulary, and the reducer against a
   frozen oracle of the transition table and the terminal_evidence matrix,
   plus schema-2 records written through `loop-journal append --schema 2`) —
   expect `selftest: PASS (803 checks)`.
12. `python3 skills/implementation-loop/tests/authority-review-selftest.py`
   runs 13 offline review regression tests, including full-fsync routing.
   `bash skills/implementation-loop/tests/authority-selftest.sh` (the 0a.2
   authority store: the real `scripts/loop-authority` under a scratch `HOME`,
   ceremonies driven through a Python pty, a `file://` bare remote, real
   Ed25519 keys from the host `ssh-keygen`, crash injection at every protocol
   cut, and the independent verifier; needs `ssh-keygen` with `-Y`, `git`,
   `ssh`, and `openssl`, and runs its cases in parallel) — expect
   `selftest: PASS (1678 checks)`, including the real crashes derived from
   every command's `CRASH_APPLICABLE` set; the original first 11 checks are a
   self-test of the crash matrix's coverage check. Then the crash matrix,
   `bash skills/implementation-loop/tests/authority-selftest.sh --crash-matrix`
   (the real writer crashed at every frame-byte cut of genesis frame 1 and of
   an epoch-rotation frame, each followed by the verifier and recovery, then
   the classifier sweep below; slow, parallel) — expect `selftest: PASS`,
   with one check per cut, one classifier-sweep check per frame kind, and
   four coverage checks: (G − 1) + (R − 1) + 2 + 4 = G + R + 4 for planned
   lengths G and R, which is 6466 checks measured on the judge's macOS host
   (6460 cuts: genesis frame 1 and a rotation frame). The count follows the
   two frames' planned lengths N, which
   include the temporary directory's path (the pinned `file://` remote) and
   the ceremony's pid, tty, and start-time digits, and so vary by machine;
   every run prints the enumerated cut list's count and digest
   (`# crash matrix cut list: ...`). Each frame's cuts are
   `<kind>:frame-byte-n` for n from 1 to N − 2 (the torn prefixes) plus
   `<kind>:frame-byte-last`; the final byte is only ever `last`. A run's
   frame need not be N bytes long (on Linux the pid and start-time digits
   only grow). Byte n must prove a torn prefix: it is credited only to a
   real crash of that kind at exactly offset n, measured on disk, of a frame
   of at least n + 2 bytes, so n is never that frame's final byte. A run
   whose frame is too short for byte n, or exactly n + 1 bytes long (n its
   final byte, the unterminated state), is discarded — never credited as n,
   never checked as the unterminated outcome under a numeric id — and
   retried with a fresh ceremony process, up to 50 runs, and then the cut
   fails; no other offset is ever tried or credited. `last` is credited only
   to a real crash at its own frame's final byte, whatever that frame's
   length. Then, for every distinct actual frame length the run's crashes
   wrote (discarded runs included), per kind, the offline classifier — A2.3's
   frame-1 classifier for genesis frame 1, A1.6's tail classifier for a
   rotation frame, the same code as the revocation and re-genesis sweeps —
   classifies every prefix 1 .. N − 1 of that exact frame, and prefixes
   1 .. N − 2 must be torn and N − 1 unterminated; the unsharded run and
   each shard print, per kind, the planned numeric range, the `last` cut,
   and the lengths swept (`# crash matrix <kind> classifier sweep: ...`). In
   CI it is its own jobs: `crash-matrix-plan` probes the two sizes once
   (`--crash-matrix --plan` prints `# crash matrix sizes=G,R`); eight
   `crash-matrix` shards (`fail-fast: false`, 120 minutes each) run
   `--crash-matrix --shard K/8 --sizes G,R --cut-ids-out cut-ids-K-of-8.txt`
   — the i-th enumerated cut (from 0) belongs to shard i mod 8 + 1, and each
   shard prints its partition's count and digest and its classifier sweep
   and uploads its credited cuts, one line each: the cut id, then the
   checked run's actual frame kind, frame length, and crash offset; and
   `crash-matrix-coverage` fails unless the plan and every shard succeeded
   and `--crash-matrix --check-shards <dir> --sizes G,R`, which recomputes
   the full list from the same enumerator, finds the eight lists to be
   exactly its partitions, every planned cut exactly once, with every cut's
   evidence crediting it: the cut's kind; for byte n, offset n and a frame
   length of at least n + 2; for `last`, an offset of its frame length − 1.
   The coverage job does not need the classifier sweep. The unsharded run
   makes the same check over its own list. Then
   `bash skills/implementation-loop/tests/registry-selftest.sh` (the frozen
   admission-registry oracle, the AST reachability scan with planted-bypass
   negative controls, the closed command table, token and stage refusals at
   every sink, recovery and finish tokens against real crash states --
   minted only from an issued plan, once, re-proved by a fresh observation,
   so forged, altered, and replayed plans and caller-built bindings mint
   nothing -- abandonment that removes only the intent, missing intent-named
   directories, and the revocation's quarantine child) — expect
   `selftest: PASS (467 checks)`.
13. `bash cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh`
   — expect `selftest: PASS (207 checks)`.
14. `bash install-cursor-selftest.sh` — expect `selftest: PASS (64 checks)`.
15. Packaging checks: both marketplace JSON manifests must parse; every
   `SKILL.md` (under `skills/` and `cursor-implementation-loop/skills/`) must
   have non-empty `name:` and `description:` frontmatter; engineering-mode and
   Codex-loop Markdown must have no dangling relative links.
16. `tree-oid` job (runs on ubuntu **and** macos):
   `bash skills/engineering-mode/scripts/tree-oid-selftest.sh` and the
   Cursor copy — expect `selftest: PASS (202 checks)` each. Keep these scripts
   portable across GNU and BSD userlands.

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
opt-in pre-release gate for backend changes. It exercises the real claude, codex, grok,
and cursor-agent sandboxes, needs authenticated CLIs, and makes real API calls.
`--backend claude|grok|cursor|codex|all` is repeatable and deduplicated; `--require
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
