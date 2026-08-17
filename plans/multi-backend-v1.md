# Multi-backend v1 — backend adapter layer for the implementation loop

Status: r12 — **ACCEPTED at Codex plan-review round 12** (gpt-5.6-sol /
xhigh / fast; one thread, 12 rounds, 2026-08-16). Round 11's final
finding (MCP as an agent-process publication channel → D10(g): grok has
no `warn` posture, verified-empty loaded-tool graph required in both
modes) closed in this revision; round 12 returned no findings. Round
history: git log of this file. **User approval and execution kickoff
pending** — per D7 and the kernel's kickoff protocol, the Backend dial
default stays codex; execution starts with PR 1 after the user settles
stop point and cadence. Precondition: PR #33 (dogfood refinements)
merges before PR 1 branches.
Scope: `olddonkey/olddonkey-skills`
Shape: a backend adapter layer under `skills/codex-implementation-loop/`
(the Claude Code host), so the loop can dispatch implementation to the
Codex CLI, the grok CLI, and — conditional on its PR 3 calibration — the
cursor-agent CLI, while keeping a later host-axis expansion (running the
loop *inside* another agent CLI) a port, not a rewrite.
Executable by: codex-implementation-loop, unit by unit, after user approval.

## 0. Motivation and the two axes

Today the loop hardwires one pairing: Claude Code orchestrates, Codex
implements. The user wants the implementer to be selectable — Codex, grok,
or cursor-agent — and, longer-term, wants any host to be able to drive any
backend ("在 codex 或者任意的一个调用任意的").

Two axes, deliberately separated:

- **Backend axis** (this plan): which implementer CLI a dispatch goes to.
  Backend adapters are plain bash + a runtime reference file; they invoke a
  CLI and shape its flags. The grok and cursor adapters call their CLIs
  directly and need nothing from the host beyond "can run a shell"; the
  codex adapter is the exception — its companion discovery walks Claude
  Code plugin directories (`CODEX_LOOP_COMPANION` is the portable
  override). "Host-portable" therefore means *portable in mechanism*, not
  packaged for other hosts — see the matrix note below.
- **Host axis** (explicitly out of scope): which agent runs the loop
  doctrine. A host port is what `cursor-implementation-loop/` already is —
  packaging, trigger/description format, kickoff phrasing, calibration
  store, byte-locked kernel prose. Adding a host is a port like that one;
  what it gains from this plan is the adapter content and the calibrated
  runtime references — the matrix note below states what it must still do
  itself.

Full matrix = N host packages × M backend adapters sharing one kernel.
This plan builds up to M=3 on the existing Claude Code host — codex and
grok as implementers, cursor-agent conditional on its PR 3 calibration
(deferred entirely if no boundary meeting D10's standards is found) —
and does not touch the host set. A future host port does **not** inherit the adapters for
free: it must package them (marketplace manifest, install path, skill
references) and re-verify the summary/permission behavior under its own
harness — what it inherits is the adapter *content* and the calibrated
runtime references, which is where the cost lives. This plan also does not
add backend adapters to the Cursor plugin package: that port's implementer
is Cursor's own subagent mechanism, which is a host-native backend with
different attribution and enforcement properties; grafting CLI backends
onto it is future work on the host axis.

## 1. Verified backend facts (calibrated 2026-08-16, this machine)

Provenance markers: **[live]** = exercised in this session; **[help/docs]**
= read from `--help` or bundled docs, not yet exercised; **[calib]** = must
be pinned empirically during the unit that depends on it.

### codex (codex-cli 0.147.0) [live — the shipping baseline]

Unchanged. Dispatch goes through the codex-companion via
`codex-dispatch.sh`: sandbox pinned `workspace-write` / `read-only`,
effort enum read from the installed companion, `ultra`/`max` as config-only
assertions against `model_reasoning_effort`, `--resume-last` threading,
tomllib scan of `~/.codex/config.toml` + `$PWD/.codex/config.toml` for MCP
servers/apps, summary block naming model/effort/tier in force.

### grok (grok 1.0.4) [help/docs unless marked]

- Headless: `grok --prompt-file PATH` or `-p "prompt"`; `--verbatim` sends
  the prompt literally (the flag-injection guard analogous to the codex
  `--` terminator). The CLI offers `plain`, `json`, and two streaming
  output formats; the adapter will use `json` (machine-parseable final
  message + session metadata [calib: exact fields]).
- Sandbox: **off by default** — a dispatch must always pass `--sandbox`.
  Profiles (kernel-enforced, Seatbelt/Landlock): `workspace` = read
  everywhere, write CWD + `~/.grok/` + temp, network allowed; `read-only`
  = write only `~/.grok/` + temp. Four hard caveats the adapter must
  engineer around, not just disclose:
  1. **`workspace` writes include `.git/` when it sits inside CWD** —
     unlike the codex companion's effectively-read-only `.git`. D10's
     response is to dispatch implement mode where the real git metadata
     is *outside* CWD (a linked worktree), so the base profile itself
     makes it unwritable.
  2. **Built-in profile initialization failure warns and continues**
     (documented fail-open), while **an explicitly requested custom
     profile refuses to start** on failure. Consequence: the adapter
     never dispatches on a built-in profile in either mode — custom
     profiles are the only fail-closed shape [calib: verify the
     refuse-to-start behavior live].
  3. **Profile `deny` entries block reads as well as writes/renames, and
     deny globs are expanded at launch on Linux** (later-created files
     escape a `**` glob). Both properties disqualify deny-listing git
     paths as the boundary: a glob misses `index.lock`, and a directory
     deny would make `git status`/`git diff` fail inside the dispatch —
     materially weaker than the codex baseline. D10 therefore uses
     placement (caveat 1) plus integrity verification, not deny entries,
     for git state.
  4. **Child-process network blocking is Linux-only (seccomp); on macOS
     it is a documented no-op.** Consequence for implement mode: with
     network open and git metadata readable, a dispatched implementer
     could `git push` — the exact "leaves the machine" event the loop's
     non-negotiable #2 exists to prevent, and one the codex baseline
     blocks (its sandbox denies child network on both OSes). Custom
     profiles expose network-restriction fields [calib: exact field names
     and what they enforce per OS]; `[shell_environment_policy]` can
     strip credential env vars from tool subprocesses [calib: scope].
     D10(f) turns this into a per-OS shipping condition.
  The agent-level `web_search`/`web_fetch` tools are on by default and run
  in the agent process regardless of profile — `--disable-web-search`
  exists and the dispatch always passes it.
- Model/effort: `--model`, `--reasoning-effort` (alias `--effort`) are
  plain forwarded flags in both modes. No config-only-assertion mechanism
  is needed: no known effort level is rejected as a flag. [calib: confirm
  accepted effort spellings; there is no enum in `--help`.]
- Resume: `--resume` resumes the most recent session *for the current
  working directory*; `--resume <id>` targets one. [calib: whether headless
  output carries the session id so the loop can resume by id rather than
  by "most recent in cwd", which is racy if the user also runs grok there.]
- Config: `~/.grok/config.toml` (TOML), plus project-level `.grok/`
  directory. **MCP servers load from multiple sources, not only the native
  TOML**: grok also reads compat configs (`.claude.json`, Cursor-style MCP
  JSON, `.mcp.json`) and plugin-provided servers. A TOML-only scan
  therefore under-reports. The external-tools check must use grok's own
  loaded-server surface as the source of truth [calib: which of
  `grok mcp list` / `grok inspect` reports the full loaded set in
  parseable form]. MCP tools run in the agent process — outside every
  child-network control — so for grok this check is not a disclosure:
  D10(g) requires the loaded set to verify as empty in both modes, and
  an unavailable or unparseable surface refuses dispatch.
- Permissions: `--permission-mode` (default, acceptEdits, auto, dontAsk,
  bypassPermissions, plan). [calib: which mode a sandboxed headless
  implement dispatch needs so it neither stalls on approval nor grants
  beyond the sandbox; the pairing is the D10 custom profile + a
  non-interactive permission mode, with the kernel sandbox as the
  boundary. Bare `--sandbox workspace` is never an implement candidate.]

### cursor-agent (2026.08.11) [help only — weakest facts, hence last PR]

- Headless: `-p/--print`, `--output-format text|json|stream-json`; prompt
  is a positional argument. [calib: long-prompt path — stdin, file, or
  argv limits; argv-only would need a length guard in the adapter.]
- Read-only analog: `--mode plan` (read-only planning) / `--mode ask`.
  There is no OS-sandbox read-only claim here — plan mode is an
  application-level restriction. [calib: what plan mode actually blocks.]
- Sandbox: `--sandbox enabled|disabled` exists. [calib: what it bounds —
  filesystem scope, network, or both; and its default.]
- Permissions: `-f/--force` auto-allows commands ("unless explicitly
  denied"), `--approve-mcps` auto-approves MCP servers. The adapter never
  passes `--approve-mcps`; whether implement dispatches need `--force` (and
  what deny rules from `~/.cursor/cli.json` still hold) is [calib].
- Model/effort: `--model` with bracket parameterization, e.g.
  `claude-opus-4-8[context=1m,effort=high,fast=false]` — effort rides
  inside the model string; there is no separate effort flag.
- Resume: `--resume [chatId]` / `--continue`. [calib: obtaining chatId from
  `--output-format json` so resume is by id.]
- MCP config: JSON (`~/.cursor/mcp.json` and project `.cursor/mcp.json`)
  [calib: exact paths] → external-tools scan is a JSON parse, not TOML.

## 2. Design decisions

**D1 — one skill, a Backend dial; no per-backend skill copies.** The repo
already pays a manual-sync tax for one prose copy (the Cursor port); three
more copies would make every doctrine edit a 4-way sync. Backends differ in
*mechanics*, which live in scripts and per-backend runtime references —
exactly the split the skill already uses for codex.

**D2 — sibling dispatch scripts, not a refactor of `codex-dispatch.sh`.**
`grok-dispatch.sh` (with its `grok-verify-worktree.sh` companion) — and,
in PR 3's boundary branch only, `cursor-dispatch.sh` — are new scripts
implementing the same flag contract; `codex-dispatch.sh` is not modified
(r1: no edits
at all — renames or shared-lib extraction are refused, not just logic
edits). Rationale: the codex script plus its 217-check selftest is the
most load-bearing asset in the repo, and the standing rule is that kernel
assets change only for cause. A shared entry script (`dispatch.sh
--backend X`) was considered and rejected for r1: it would put all three
backends behind one argument parser and turn every backend addition into
an edit of the shared entry — risk concentrated exactly where it is least
wanted. Cost of the sibling shape: the common flag surface is convention,
not code; §5 R4 handles drift.

**D3 — common dispatch contract.** Every backend script accepts:
`--prompt-file PATH` / `--prompt TEXT`, `--model M`, `--effort E`,
`--read-only|--investigate`, `--resume`, `-h/--help`; it runs from the
target repo root, prints a summary block (workspace, CLI version,
model/effort actually in force and their provenance, mode, resume state,
and — where the CLI reports one — the session/thread id this dispatch
created or resumed), guards prompt text against being parsed as flags, and
forwards nothing the caller didn't choose (absent flags inherit the user's
own CLI config). **`--background` is codex-only**: the companion owns
detached-job lifecycle (status/cancel/logs). The grok and cursor adapters
run strictly foreground — their authoritative completion signal is the
script's own exit — and backgrounding happens at the harness level, as the
loop already prescribes for every dispatch. Resume for direct-CLI backends
is exact-id wherever the id is capturable (from the summary of the prior
dispatch); recency-based resume is a disclosed fallback, not the default. Per-backend flags beyond the contract are allowed where a
capability genuinely exists (they must not contradict the contract), and
each script documents its own enforcement gaps in its runtime reference.
Env-var overrides are per-backend, following the existing names:
`CODEX_LOOP_*` (unchanged), `GROK_LOOP_MODEL/EFFORT/BLOCK_EXTERNAL_TOOLS`,
`CURSOR_LOOP_MODEL/EFFORT/BLOCK_EXTERNAL_TOOLS`.

**D4 — backend-specific mappings.**

| Contract point | codex | grok | cursor-agent |
| --- | --- | --- | --- |
| implement mode | companion `--write` (sandbox `workspace-write`) | D10: custom profile extending `workspace` + linked-worktree precondition + pointer integrity check | default perms or `--force` per calib; `--sandbox` per calib |
| read-only mode | companion default (sandbox `read-only`) | D10 custom profile extending `read-only` (CWD unwritable ⇒ git state safe in place) + D10(f)'s network tuple gate — read access to objects and credentials is enough to push, so unenforced tuples refuse or carve out here too | `--mode plan` (app-level; gap disclosed in summary) |
| effort | flag enum + config-only assertion | `--reasoning-effort` forwarded | folded into `--model` bracket params; a bare `--effort` with no `--model` is an error naming the bracket syntax |
| resume | `--resume-last` | by session id when capturable, else `--resume` + disclosed cwd-recency caveat | `--resume <chatId>` captured from JSON output |
| external tools | TOML scan, both layers; warn/block per repo posture | **stricter than the codex posture — warn is not available**: D10(f) requires a verified-empty loaded-tool graph (see D10(g)); always `--disable-web-search` | JSON scan of mcp.json layers; never `--approve-mcps` |
| prompt injection guard | `--` terminator | `--verbatim` | per calib (quoting/stdin) |

**D10 — the grok git boundary is engineered, not assumed.** The codex
companion gives the loop an effectively-read-only-but-readable `.git`;
grok's profile machinery cannot express that per-path (deny blocks reads,
§1 caveat 3). So the boundary comes from *placement* — run the implementer
where the real git metadata is outside the writable scope — with profile
validation and integrity checks around it:

- **(a) Custom profiles in both modes, never a bare built-in.** Implement
  dispatches use a loop-owned profile extending `workspace`; read-only
  dispatches use one extending `read-only`. Custom profiles are the only
  shape grok refuses to start when sandbox init fails (§1 caveat 2), so
  fail-closed comes from the CLI's own refuse-to-start behavior, not from
  the adapter parsing warnings after execution has begun. Neither profile
  contains repo-specific paths, so **profile creation is genuinely
  one-time per machine** — a consented calibration step; the adapter
  never edits the user's config (refuse-rather-than-edit, same posture as
  the codex config-only effort assertion).
- **(b) Implement dispatches run in a linked worktree; the adapter
  enforces the precondition mechanically.** In a linked worktree,
  `git rev-parse --git-dir --git-common-dir` both resolve outside CWD, so
  refs, objects, index, and hooks are kernel-unwritable under the
  `workspace` base while remaining readable — `git status`/`diff` keep
  working. Before an implement dispatch the adapter verifies, after
  canonicalizing every path (symlinks resolved on both sides): both
  paths resolve outside CWD; **no protected or trusted path overlaps any
  effective sandbox-writable root** — CWD, the resolved `GROK_HOME`, and
  every temp root — because "outside CWD" alone is worthless for a
  checkout living under `/tmp` or `$GROK_HOME`, where git metadata, the
  baseline, or the snapshot target would sit inside what the sandbox can
  write (this overlap check covers git-dir, common-dir, baseline
  location, and snapshot destination, in both modes — a read-only
  dispatch whose CWD lies under a temp root is refused for the same
  reason); **and no `.git` *directory* exists anywhere inside CWD** (an
  unabsorbed old-style submodule would be real, writable git state in
  place — refuse). It inventories **every in-CWD `.git` marker file**
  (worktree root plus populated submodules, recursively) for (c)'s
  integrity set, and verifies each submodule's resolved git dir also
  lies outside CWD. Read-only dispatches need no worktree: the
  `read-only` base makes all of CWD unwritable (subject to the same
  overlap check), which protects in-CWD git state by construction.
- **(c) The residual in-CWD surface is the set of `.git` marker files,
  guarded by hardened integrity verification.** Markers must stay
  readable (git resolves through them), so they cannot be denied.
  Instead, for every marker in (b)'s inventory the adapter records
  content hash **plus `lstat` identity — file type, device, inode, link
  count, size** — so a delete-and-recreate, symlink swap, or hard-link
  game changes the record even when bytes match. The baseline is stored
  **outside every sandbox-writable root** (not CWD, not `~/.grok`, not
  temp — concretely, under the run/calibration directory rooted in the
  git common dir, which the sandbox cannot write). **Descendant
  containment is a proven tuple property, not best effort** — while any
  process retains marker write access, verification-before-use is
  race-able (wait for the verify, then repoint), so implement mode ships
  on a tuple only when its calibrated containment mechanism provably
  leaves **zero surviving mutation ability** after dispatch exit:

  - *Linux candidate:* run the dispatch inside a PID namespace or a
    dedicated cgroup, whose teardown kills every descendant including
    double-forked escapees [calib: unprivileged availability and the
    exact mechanism per distro]. Proven kernel containment makes the
    snapshot below optional on that tuple.
  - *Everywhere else (macOS today):* session/group termination, then the
    **snapshot transition** — the property that closes the race without
    depending on any sandbox semantics: after the kill, the orchestrator
    copies the worktree into a **fresh-inode snapshot** at a fresh path
    outside every sandbox-writable root (plain copy guarantees new
    inodes on any filesystem; APFS clonefile is the cheap variant), and
    **every host-side operation from then on — review reads, commit,
    gate, publish — touches only the snapshot.** A surviving child's
    retained descriptors and writable mappings all reference the old
    inodes: anything it writes after the snapshot lands in a tree no one
    reads again. Anything it managed to write *before or during* the
    snapshot is simply part of the diff — visible to review like any
    other change, which is exactly the property review needs
    (post-review immutability, not pre-review purity — with one
    exception: **markers are linkage, not diff content**, so they are
    re-verified *inside the snapshot* before git ever runs there). The
    transition is trusted, ordered, and **journaled for crash
    consistency**: group kill → copy → **verify the snapshot's complete
    marker path set and bytes against the old baseline with the no-git
    verifier — before any git command touches the snapshot** (a marker
    mutated during the copy window is caught here, not executed) →
    **validate snapshot closure**: refuse any symlink that resolves into
    any sandbox-writable root or **any path in the historical writable
    ledger** — a protected, append-only record (kept with the baseline)
    of every CWD, per-dispatch grok home, and temp path any dispatch
    generation was ever granted, retired only when that generation is
    proven terminated — because a later-resume symlink can target a
    *first*-generation discarded tree that an old survivor still writes;
    also refuse unsafe special files (a copied symlink is a fresh inode
    whose *target* a survivor can still write) → repair the worktree
    linkage
    (`git worktree repair` [calib]) → write a fresh baseline for the
    snapshot's markers → atomically record the snapshot as the unit's
    authoritative path. Each step is recorded in a transition journal
    stored with the baseline (outside writable roots); on startup an
    interrupted transition is completed forward or refused, never
    half-trusted, and the selftest interrupts after every step. Resume,
    review, cleanup, and stop-point semantics all follow the recorded
    authoritative path from here; the old tree is discarded. Because the
    authoritative CWD changes, **exact-id resume across a changed
    `--cwd` is its own [calib]**: prove a resumed session's tool
    operations land only in the snapshot path; if grok cannot, the
    adapter forks a fresh session against the snapshot (or refuses
    resume) rather than letting a resumed session resolve the discarded
    workspace.

  The escaping-child smoke (`setsid` + `chdir` away + retained writable
  file descriptor and writable mapping to a marker AND to an ordinary
  tracked file + retained directory descriptor + path re-open attempts
  + tracked and untracked symlinks, relative and absolute, whose
  *targets* the child mutates after the transition) must demonstrate
  that **no channel can alter what the host reads after the transition
  completes** — post-snapshot writes through every retained capability
  must be invisible in the snapshot, and closure validation must have
  caught every snapshot symlink resolving into survivor-writable space;
  any surviving channel refuses implement mode on that tuple. Group-kill-then-verify
  remains the first step everywhere (the existing cwd-matched recipe is
  explicitly NOT the mechanism — it greps test runners and a child can
  `chdir` away). Marker verification via `grok-verify-worktree.sh` — a
  no-git verifier (it must not run `git rev-parse`, since the pointer is
  what is being verified) invoked with the absolute baseline path the
  dispatch recorded, whose baseline carries the worktree identity and
  marker records, failing closed on missing, stale, or wrong-worktree
  baselines — runs at the transition and again **immediately before
  every host-side git operation** (review reads, commit, gate, publish)
  as defense-in-depth, no longer as the load-bearing boundary. The
  publish path additionally keeps the loop's SHA binding (commit, record
  SHA, gate that SHA, confirm before push). Any mismatch at any point is
  a hard attribution failure: the unit's diff is discarded, not
  repaired.
- **(d) Profile validation reads what grok will actually load — and on
  survivor-capable tuples, what grok loads is per-dispatch and fresh.**
  Validation alone has a TOCTOU hole there: `GROK_HOME` is
  sandbox-writable, so a surviving child from an earlier dispatch can
  rewrite `sandbox.toml` or the shell policy *after* the adapter
  validates and *before* the next grok process reads it (grok's direct
  write-protection covers hook paths, not these files). So on tuples
  without proven kernel containment, each dispatch runs with a **fresh,
  orchestrator-prepared `GROK_HOME`** created outside every path any
  earlier sandbox generation could write, containing exactly the
  validated profile, policy, and control state [calib: grok loads only
  from it]; that home joins the historical writable ledger of (c) once
  used. Session state is never reused from a survivor-writable home —
  resume either verifies an independently snapshotted session record
  into the fresh home, or forks/refuses per the resume [calib]. The
  adapter resolves the effective grok home the way the CLI does
  (`GROK_HOME` override included), parses the profile from that source,
  and verifies: defined at user level; no repo-controlled
  `.grok/sandbox.toml` definition of the same name (conflict = refuse);
  `extends` is exactly the expected base (`workspace`/`read-only`, never
  `devbox`/`off`); no `read_write` additions beyond the base; no
  network-weakening overrides; unknown or unparseable fields refuse.
  Absence, parse failure, shadow, or nonconformance **fails closed**.
- **(e) Second layer stays, made explicit.** The dispatch-prompt skeleton
  gains an explicit prohibition on modifying, deleting, renaming,
  committing, or publishing git state (today it only *describes* `.git`
  as read-only), and the loop's branch-check-before-publish applies as
  with every backend.
- **(f) No-publish is a shipping condition, not an aspiration.** Codex's
  sandbox denies child network on both OSes; grok's does so on Linux
  only (§1 caveat 4), and with network open plus readable git metadata a
  dispatched implementer could push. So: the implement profile enables
  every network restriction the profile schema offers and strips
  credential env vars via `[shell_environment_policy]` [calib both];
  and the adapter validates the **effective** shell-environment policy on
  every dispatch (resolved the way the CLI resolves it), refusing when it
  does not match the policy hash bound into the tuple approval — grok's
  default preserves the environment, so drift after approval is refusal,
  not silence. Network enforcement has its own oracle, **separate from
  git**: a disposable raw TCP endpoint with positive and negative
  controls — unsandboxed connect succeeds, sandboxed connect must fail
  with a kernel-attributable denial — because a failed `git push` proves
  nothing about networking (the push can die on filesystem restrictions
  instead, while another protocol client would still get out). The
  git-push smoke stays as the *publication* test: a disposable local git
  endpoint where an unsandboxed push first succeeds, then the identical
  sandboxed push must be denied with the target repo unchanged. It also
  includes a `file://` push targeting a path outside the writable roots,
  which the kernel must block on every OS. **On tuples where
  child-network blocking is mechanically enforced and smoke-proven,
  both dispatch modes ship normally (allowlist entry type `enforced`).
  On tuples where it cannot be (macOS today), **both implement and
  read-only dispatches are refused by default** — reading objects and
  credentials is enough to `git push`, so a read-only dispatch on an
  open-network tuple is a publication risk too, and the loop forbids
  unapproved publication in every mode.** The carve-out that overrides this refusal is a **record in
  the hardened tuple allowlist itself, not an environment variable** —
  ambient env is unattributable (direnv, launch wrappers, stale shells
  can all supply a value), so no env channel exists at all. The grant is
  made in conversation (per repo, after tuple resolution, in its own
  kickoff item — never bundled into backend selection, and granting it
  **never grants publication**; stop-point authority stays separate) and
  the orchestrator then writes an allowlist entry of type `carve-out`
  binding {canonical repo path, tuple including grok version, grant
  date}. The adapter honors it only when the resolved repo and tuple
  both match; a grok upgrade changes the tuple and thus expires it;
  revocation is deleting the entry; and every dispatch under it says so
  in the summary. Selftests cover: absent, matching, wrong-repo,
  wrong-tuple, stale-version, and env-var-only (ignored) cases. Silent
  parity with codex is the failure mode this item exists to prevent.
- **(g) MCP is a publication channel, so grok gets no `warn` posture.**
  MCP tools run in the *agent* process — a loaded GitHub-style server
  mutates remote state without any child networking, bypassing the TCP
  oracle and the carve-out protocol entirely. The codex loop's
  disclose-and-continue posture is therefore not available for grok:
  in **both modes** the dispatch requires a **verified-empty loaded-tool
  graph** — the fresh per-dispatch `GROK_HOME` from (d) contains zero
  MCP configuration by construction, compat sources (`.mcp.json`,
  `.claude.json`, project `.grok/`, plugins) can still inject servers,
  so the adapter queries grok's own loaded-server surface (§1) and
  **refuses dispatch when it is nonzero or unverifiable** [calib:
  whether a denial flag can mechanically remove MCP invocation as an
  alternative to the empty-graph requirement]. The
  `GROK_LOOP_BLOCK_EXTERNAL_TOOLS` variable therefore has no `0` mode
  with teeth removed — for grok, blocked is the only posture, and D7's
  per-repo external-tools dial applies to codex only.

Selftests for (a)–(d): absent profile, malformed TOML, project-level
shadow, conflicting definitions, wrong base (`extends = "devbox"`),
broadened `read_write` (e.g. `["/"]`), network-weakening override,
unknown field, overridden `GROK_HOME` (validated source must follow it),
worktree-precondition refusals (git-dir inside CWD; in-CWD `.git`
directory; submodule git dir inside CWD), marker-integrity mismatches
(byte change, delete-and-recreate with identical bytes, symlink swap,
hard-link swap — the lstat identity must catch each), baseline stored
outside writable roots, and the conforming both-mode profiles.

PR 2's live smoke **attacks the boundary, not just observes git fail**,
from inside the sandbox in both modes: write/delete/rename against
git-dir and common-dir contents and each marker file; **alias attacks**
— symlinks and hard links created in every writable root (CWD,
`~/.grok`, temp) targeting protected git *files*, written through, AND
symlinks to the protected *directories* through which the smoke attempts
to **create** new paths (`index.lock`, refs, objects) and to rename or
atomically replace them — because git's dangerous writes are mostly new
files that don't exist to be targeted beforehand; the escaping-child
case from (c); (f)'s raw-TCP network oracle (positive and negative
controls, both modes — recorded oracle evidence is a prerequisite for
writing any `enforced` entry); (f)'s push attempts as the publication
test; and the writable-root overlap matrix (each protected path —
CWD, git-dir, common-dir, baseline, snapshot destination — laid out
under temp and under `GROK_HOME`, in both modes, each refused).
**Smoke failures are typed, so acceptance is mechanically decidable:**
any filesystem, marker, alias, containment, or `file://`-push bypass is
an absolute refusal for that tuple — no carve-out reaches it. The
child-**network** push succeeding is the one failure class that routes
to (f)'s carve-out path instead of shipping as `enforced`.

**Shipping is gated per tuple, machine-readably, and the allowlist is
itself a guarded trust boundary.** Approval is keyed by (OS,
architecture, grok version) in a calibration file with a **fixed
canonical user-level location and a defined schema**; entries are typed with per-type keys —
`enforced` entries are unique per full mechanism tuple, `carve-out`
entries are unique per **(full mechanism tuple, canonical repo path)**,
so independent repos on one machine hold independent grants (granted and
revoked independently, which the selftests assert) — and **approval is
bound
to the mechanism it certifies, not just the platform**: the key includes
OS and kernel release, architecture, grok version, the adapter and
containment-mechanism version, the smoke-schema version, and the
profile/policy hashes — so a kernel update, adapter revision, changed
transition, or revised oracle invalidates the entry and re-runs the
smoke instead of inheriting stale approval; the runtime prerequisites
(profile hash, policy hash, mechanism availability) are additionally
revalidated on every dispatch. Before honoring it the
adapter verifies: the resolved path (symlinks followed) is the canonical
location, outside every sandbox-writable root and outside any repo; the
file is a regular, user-owned, non-group/world-writable file; the
content parses against the schema with no duplicate or conflicting
entries. **Any failure of those checks refuses both dispatch modes** —
the allowlist gates read-only dispatches too (D10(f)), and a symlinked,
repo-reachable, malformed, or ambiguous allowlist grants nothing in
either mode. The adapter reads it on each dispatch and refuses any
unlisted tuple, so a grok upgrade re-runs the smoke rather than
inheriting an old approval, and "Linux evidence now exists" is a
recorded fact the script can check, not a PR-body memory. macOS evidence
lands with PR 2; other tuples append as their smokes run. Selftests
cover the source-integrity matrix (symlink, wrong owner, loose
permissions, malformed, duplicate, conflicting types — each asserted to
refuse both modes) alongside the unknown-tuple refusal and independent
per-repo carve-out grant/revocation.

**D5 — SKILL.md changes are additive and targeted, not a rewrite.** The
dials table gains one row (**Backend**; default `codex`, matching every
existing calibration record), and **a backend option appears in that row
only in the PR that lands its working script** — the docs never offer a
choice that cannot dispatch. Same rule for the Dispatch section's
invocation examples. The environment-constraints list and non-negotiables
are already backend-agnostic in substance and keep their wording except
where "Codex" names the actor generically — those become "the
implementer". Sections whose content is genuinely codex-specific (the
flag-semantics table for config-only efforts) move into the codex runtime
reference rather than being neutralized in place.

**D6 — runtime reference split.** `references/runtime.md` →
`references/runtime-codex.md` (content unchanged apart from the moved
flag-semantics table), plus new `runtime-grok.md` and `runtime-cursor.md`.
Each carries: dispatch mechanics, enforcement guarantees *and gaps*
(grok/macOS network no-op; cursor plan-mode being app-level), model/effort
semantics, resume semantics, stuck-job handling (grok/cursor have no
companion `status`/`cancel`; document session listing + the existing
cwd-matched process-kill recipe), config locations, and the calibration
items from §1 with their resolved answers once pinned. SKILL.md's pointer
sentence becomes "read the selected backend's runtime reference before the
first dispatch of a session."

**D7 — kickoff and calibration.** Backend selection is **not** a plain
repo fact: backends carry materially different enforcement guarantees
(D4), so letting a tracked file pick one would let repository content
weaken the boundary without anyone consenting — the same
loosen-never-tighten problem the calibration rules already solve for
policy dials. So: the backend is chosen by the user at kickoff and
recorded in **user-level private memory** like a permission dial; a
backend named in CLAUDE.md or any repo file is a claim to reconfirm, and
a *change* of backend on a calibrated repo is always resurfaced. Existing
records that don't name a backend mean `codex` — no re-asking on
already-calibrated repos. The kickoff model/effort/tier question is asked
for the *selected* backend only, with that backend's config as the
inherit option; when the selected backend's resolved tuple requires
D10(f)'s carve-out, that is its own kickoff item, asked after tuple
resolution and answered separately from backend choice. The
external-tools posture (warn vs block) remains a per-repo dial **for
codex only**; grok is always blocked per D10(g), and cursor-agent's
posture is set by its PR 3 calibration.

**D8 — naming.** The skill keeps the name `codex-implementation-loop` in
r1: the name is load-bearing (engineering-mode adapter, README, installer,
marketplace manifests, user calibration records, muscle memory). The
description gains multi-backend trigger language per shipped backend —
grok wording lands with PR 2; cursor-agent wording only in PR 3's
boundary branch (the defer branch adds no trigger text at all). A rename
to `implementation-loop` is deferred to its own change with a
compatibility story, if ever.

**D9 — model-pairing caveat.** The loop's review independence partly rests
on orchestrator ≠ implementer. A backend whose selected model equals the
orchestrator's forfeits that silently — the same caveat the Cursor port
already documents for `inherit`. dials.md notes it under the Backend dial.

## 3. Units (one PR each)

**PR 1 — codex-only docs restructure.** No script changes, no new backend
exposure. `runtime.md` → `runtime-codex.md` (git mv + the D5 table move),
the D3 contract written down as a reference section, targeted
"the implementer" neutralization. No Backend dial row yet, no grok/cursor
stubs, no mention of backends that cannot dispatch (D5 rule) — the D9
caveat lands in PR 2 with the dial row it annotates. *Acceptance:*
selftest still `PASS (217)` untouched; no dangling relative links (extend
the CI link check, currently engineering-mode-only, to
`skills/codex-implementation-loop/`); the codex flow reads unchanged to an
existing user (no dial answers change meaning); AGENTS.md updated for the
reference-file changes.

**PR 2 — grok backend, calibration-first.** Resolve §1's grok [calib]
items with live probes recorded in a new `runtime-grok.md` — including
D10's profile mechanics and sandbox-failure detection, and the
loaded-MCP-surface choice; then `scripts/grok-dispatch.sh` +
`scripts/grok-verify-worktree.sh` (the no-git verifier of D10(c), with
its recorded-absolute-baseline interface) implementing D3/D4/D10, plus
`grok-selftest.sh` using the existing PATH-stub pattern (stub `grok`
binary logging argv; assert: the full D10 selftest matrix as listed in
D10 — profile validation including wrong-base, broadened read_write,
network override, unknown field, `GROK_HOME` resolution,
worktree-precondition refusals, marker-integrity mismatches, shell-policy
hash validation, the allowlist source-integrity and unknown-tuple matrix,
the carve-out record matrix (absent / matching / wrong-repo /
wrong-tuple / stale-version / env-var-only-ignored), the transition
journal (interruption after every step → completed forward or refused),
snapshot-closure validation (symlink into old tree / writable root /
ledgered historical path / special file → refused), the writable-root
overlap matrix (each protected path under each writable root, both
modes), the fresh-per-dispatch `GROK_HOME` preparation and
session-state rules, the resume-across-changed-cwd outcome, and the
verifier at every transition (missing, stale,
wrong-worktree, mismatched, and passing baselines for pre-review,
pre-commit, pre-gate, pre-publish) — plus sandbox flag always a custom
profile in both modes, `--disable-web-search` always present,
`--verbatim` on prompt dispatch, effort forwarding, session-id capture
in the summary and exact-id resume shape, the D10(g) empty-tool-graph
requirement (zero servers passes; nonzero or unverifiable surface
refuses, both modes), summary block content). This PR introduces the Backend dial row with options
`codex` / `grok`, the grok invocation example, the D9 caveat under the
dial row (moved from PR 1), **and the kickoff-question wording that
settles the Backend dial per D7** — the dial never exists without the
protocol that settles it. The dispatch-prompt skeleton gains D10(e)'s
explicit git-state prohibition.

**PR 2 also integrates the worktree into the loop protocol, not just the
adapter check.** runtime-grok.md defines the workflow the orchestrator
follows: per-unit linked-worktree creation (`git worktree add`, path
outside the main checkout, branch created with it), what each stop point
means under it — `stop=worktree` now means "changes live in the unit
worktree at the recorded path", stated explicitly since that differs
from the codex backend's in-checkout default — plus reuse on `--resume`,
cleanup after publish (`git worktree remove` once the stop point is
reached), and retention with a recorded path for parked/abandoned units.
The adapter refuses when the precondition is unmet; the runtime
reference is what makes meeting it a defined step rather than tribal
knowledge. CI: `bash -n` + run the selftest.
*Acceptance:* selftest green in CI with a stable count; D10's live
attack-smoke evidence recorded in the PR body with summary blocks
(read-only mode in a normal checkout; implement mode in a linked
worktree; the full attack set — direct, alias, creation-through-alias,
escaping child, push with positive control); the tuple gate honored
mechanically — **a tuple ships only after every absolute boundary class
(filesystem, marker, alias, snapshot/containment, `file://` push) passes
its smoke; only then does the child-network result choose `enforced`
versus the carve-out path**, and every unlisted tuple refuses in both
modes; runtime-grok.md has zero remaining [calib] markers; AGENTS.md
script inventory and CI reproduction list updated for the three new
scripts.

**PR 3 — cursor-agent backend, conditional on its calibration.** Same
calibration-first shape: pin the [calib] items live (headless permission
behavior without `--force`, what `--sandbox enabled` actually bounds,
whether any mechanism yields a hard git boundary, chatId capture,
long-prompt path). The PR's shape then follows the findings, stated in
`runtime-cursor.md` either way:

- **Boundary exists** → ship implement + read-only modes; `cursor-agent`
  joins the Backend dial row; acceptance includes the same attack-smoke
  evidence and tuple gating as PR 2.
- **No hard git boundary (or no mechanical no-publish per D10(f)'s
  standard)** → **cursor-agent is deferred entirely.** No script ships,
  nothing joins any dial or selection path, and no skill text names
  cursor-agent as a backend; the PR lands only `runtime-cursor.md`
  recording the calibration findings and exactly which missing guarantee
  deferred it, so a future attempt starts from evidence instead of
  re-probing. The plan's scope claim becomes M=2. (A half-backend
  reachable through no defined selection path — round 4's finding — is
  worse than an honest deferral.)

*Acceptance (per branch taken):* boundary branch — selftest green in CI
with a stable count, live attack-smoke for every shipped mode recorded
in the PR body, tuple gating in place, AGENTS.md inventory updated for
the new scripts; defer branch — runtime-cursor.md states the findings
and the blocking guarantee, and no user-facing surface changed. Both
branches: the enforcement-gap section explicitly compares against codex
guarantees; zero remaining [calib] markers.

**PR 4 — integration prose.** engineering-mode `adapter.md` token map
gains the backend parameter (investigation dispatch = "`--read-only` on
the *selected backend's* dispatch script"); README/README.zh-CN gain a
multi-backend paragraph naming only the backends that actually shipped.
(The kickoff wording for the Backend dial itself landed with the dial in
PR 2.) *Acceptance:* platform-neutral grep still
passes (the byte-locked playbooks are not touched); Cursor-package files
byte-identical where CI demands.

Ordering note: PR #33 (dogfood refinements) touches the same SKILL.md and
must merge before PR 1 branches.

## 4. Non-goals

- No host-axis work: nothing runs the loop inside grok/codex/cursor here.
- No Claude-as-implementer backend (subagent implementer exists in the
  Cursor port's design; bringing it to this package is a separate
  decision).
- No changes to `run-gate.sh`, the gate doctrine, review checklist,
  publish/SHA rules — all already backend-independent.
- No rename (D8), no shared-lib refactor of `codex-dispatch.sh` (D2).
- No changes to the Cursor plugin package beyond byte-lock no-ops.

## 5. Risks

- **R1 — codex-path regression.** Mitigated structurally: PR 1 has no
  script changes; `codex-dispatch.sh` is not edited anywhere in the plan.
- **R2 — weaker enforcement on new backends read as equivalent.** grok on
  macOS does not block child network in read-only; grok's built-in
  sandbox fails open on init failure and its `workspace` profile leaves
  `.git/` writable (both countered by D10, which fails closed instead);
  cursor plan mode is app-level. Mitigation: engineered boundaries where
  possible (D10), and gaps disclosed in the dispatch summary itself (the
  line the orchestrator reads every run), not only in the reference.
- **R3 — model-pairing loss (D9)** — surfaced at kickoff when the chosen
  backend model equals the orchestrator.
- **R4 — contract drift across sibling dispatch scripts** (two or three,
  per PR 3's branch). Convention, not code, so: each selftest asserts
  the shared contract's observable behavior (same flags, same failure
  modes); if drift still bites twice, promote the contract to a shared
  test harness — same threshold-then-script rule the repo already uses.
- **R5 — cursor-agent facts are the weakest.** Hence last, hence
  calibration-first inside its own PR, hence refuse-don't-weaken if a mode
  can't meet the contract.
