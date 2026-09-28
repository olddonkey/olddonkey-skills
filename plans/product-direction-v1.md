# product-direction-v1

**Status: ACCEPTED** at Codex read-only review round 5 (2026-09-28,
gpt-6-sol / max, one thread; session `01a0e7a5-51ab-7273-89b7-ac5505b0a28e`).
Findings per round 10 → 10 → 9 → 7 → 3 (all minor at round 5). Dispositions:
§8–§12. Rounds 2–5 were mostly about the implementer harness (§4), not the
product direction.

What implementation-loop is becoming, in product terms, and the first four
units that move it there. It sits **above** `plans/task-graph-v1.md` (the
accepted, effect-free control plane) and does not amend it: where the two
touch, task-graph-v1 wins and this plan says so at the point of contact.

**Provenance discipline** (inherited from loop-console-v1 §0 and
task-graph-v1 §0): every "today the code does X" claim carries a `file:line`
citation against `origin/main` @ `dd203b9`, or is marked *assumed*. External
observations about other products carry their date and source, and are
context, not requirements.

---

## 1. What the product is

**One sentence.** implementation-loop is a local **verified-delivery layer**:
it turns code written by any coding agent into a change you can merge without
re-deriving, yourself, whether the change is what it claims to be.

The product is not the dispatch. Dispatching a task to Codex from a Claude
session is already a commodity — the `openai-codex` Claude Code plugin does
it (installed on this host under `~/.claude/plugins/cache/openai-codex/`,
observed 2026-09-28). What the loop adds is everything **after** dispatch, and
that part is written down as doctrine that already ships:

| doctrine | where it lives today |
| --- | --- |
| the implementer's summary is a claim; the diff is the evidence | `SKILL.md:14` |
| an assumed default never leaves the machine; publication is granted per repo, once | `SKILL.md:15` |
| the full-suite gate belongs to the judge, with the real exit code | `SKILL.md:17` |
| the gate is bound to the commit that ships, and the base is re-checked before landing | `SKILL.md:179`, `SKILL.md:181` |
| park, never weaken; parking is the escape hatch at 3am | `SKILL.md:204`, `SKILL.md:206` |
| repo files cannot grant publish authority | `SKILL.md:212`, `SKILL.md:216` |

**The gap it fills.** Agent workbenches trust the agent. Observed 2026-09-25
from todos.dev's public docs and the `@todos-dev/cli` 0.1.53 npm package: a
finished build goes straight to a human acceptance column, all three agent
runtimes run without a sandbox, and there is no gate concept between "agent
says done" and "human looks". The loop's doctrine is the part those products
do not have. As more code is written by agents, the bottleneck moves from
"get it written" to "can I merge this", and that is the loop's whole subject.

**Who it is for.** First user: the author, running a Claude session as judge
over Codex, Cursor, and Grok implementers. Open-source audience: developers
who hold more than one agent subscription and want one agent to write while
another's work is verified before it lands.

### 1a. What it is not

- **Not a task board or a team-of-agents platform.** No chief-agent chat,
  schedules, agent memory, multi-user workspaces, or hosted control plane.
  A board may *read* the loop's record; the loop does not become one.
- **Not a model gateway.** Which model answers is the implementer CLI's
  business (or a gateway's). The loop names model and effort on every
  dispatch (`SKILL.md:90`) and records what it named; it does not route.
- **Not a resident executor.** task-graph-v1 §1a reversed that at round 2: a
  committed graph plus a background process that executes it is arbitrary
  code execution triggered by `git pull`. Nothing in this plan reopens it —
  no queue that a timer drains, no daemon that picks up work.

---

## 2. The three things the product delivers

Independent of any UI, a user of the loop gets three artifacts. Every stage
in §3 improves one of them; a stage that improves none is out of scope.

1. **The record** — the loop's lifecycle as journal events from a closed
   list of thirteen types (`scripts/loop-journal:53-118`, shipped in
   loop-console-v1). Its value comes from being *true*, not from being
   complete — and today it is a local, unauthenticated record (§4).
2. **The evidence** — for each unit, a statement of what is recorded, what
   only matches by value, and what is unknown, in a form a reviewer can read
   in a PR description. Today the judge assembles this by hand; the doctrine
   asks for PRs "with real gate numbers" (`SKILL.md:177`).
3. **The cockpit** — where the user sees the loop moving and changes what is
   theirs to change: today the console's Vitals, Now, This run, and Dials
   sections (`scripts/console-assets/index.html`, rendered by
   `console.js:419-1265`), next a read-only flow view, eventually
   task-graph's authored canvas.

**Honesty rule for all three.** The record, the evidence, and the cockpit may
never state more than the underlying events prove. task-graph-v1 §3 is the
authority on what "proven" means (request digest + result digest + permitted
producer + bound content). Nothing in schema-1 reaches that bar, so S1–S3
display **recorded, unverified claims**: a recorded success is never styled as
proven success, and absent or inconsistent data reads as *unknown*.

**Direction versus tonight.** "Verified delivery" is where the product is
going; it is reached when task-graph-v1's trusted writer and Phase B
preconditions exist. S1–S3 are diagnostic: they make the record honest and
visible, and say so.

---

## 3. Stages

| stage | what the user gets | status |
| --- | --- | --- |
| S0 observability | journal, index, console, dials | shipped (loop-console-v1, PRs #50–#58) |
| S1 truthful record | a gate event that says green only when the gate was green; gate and dispatch events that name their unit | **this plan, units 1–2** |
| S2 evidence card | `loop-evidence`: a per-unit card for the PR body, every line labelled by strength | **this plan, unit 3** |
| S3 flow view | a read-only animated view of a run in the console: packets moving between judge, implementer, review, gate, publication | **this plan, unit 4** |
| S4 control plane | task-graph-v1 Phase A, as accepted | accepted plan, not started |
| S5 authored canvas + execution | task-graph-v2: editing the graph on the canvas ("dragging the lines") changes declared intent; permission edges are approval nodes | gated on task-graph-v1 §7b P1–P5 |
| S6 open surfaces | the coordinator's typed operations as a tool surface so the judge is replaceable; an optional model-layer lane in the flow view fed by a gateway's trace | direction only, not specced |

### 3a. Why S1–S3 come before task-graph Phase A

Phase A is twelve units of control plane that, by its own statement, is
"scaffolding with real diagnostic value — not a standalone orchestration
product" (task-graph-v1 §7). S1–S3 give the user something visible now, and
they are **chosen to be subsumed by Phase A without contradiction**:

- They only **add** optional, typed fields to schema-1 events and **read**
  the journal. Unit 0a must already define "compatibility with existing
  schema-1 history, in which absent assurance always reads as the weakest
  value" (task-graph-v1 §7, Phase A item 1); these units create schema-1
  history of exactly that kind, documented in `references/state-schema.md` so
  0a's reducer has a written source.
- S1's unit 1 **is** task-graph-v1 unit 0b, which that plan says ships "first,
  independently of this plan" (task-graph-v1 §7). This plan adopts it
  verbatim rather than re-deciding it.
- S2 and S3 are read-only consumers. Neither writes to any store the loop
  reads for authority, and neither grants, answers, or consumes anything. The
  flow view is served by the existing authenticated console (loop-console-v1
  Unit 4 handshake), not by a new server.

### 3b. What S5 means for "dragging the lines"

The user's stated goal is a flow picture where lines can be dragged to change
what happens. task-graph-v1 already decides what a drag may mean, and this
plan restates it so no earlier stage pre-empts it:

- A drag edits the **authored plan graph** — declared intent only
  (task-graph-v1 §1). It never authorizes anything and never rewrites
  execution history.
- A drag that would widen authority (for example moving a unit's terminal
  edge from "PR" to "merge") is not an edit; it creates an **approval node**
  that a human discharges through the authenticated UI (task-graph-v1 §4c,
  Phase A item 8).
- A change takes effect at the next attempt, never mid-attempt.
- None of this exists before S5. S3's flow view is **read-only**: no drag
  handles, no endpoints that mutate anything.

### 3c. S6, recorded as direction only

Two surfaces are plausible once S5 exists, and both are deliberately not
specced here:

- **Replaceable judge.** Exposing the coordinator's typed operations
  (dispatch, gate, publish) as a tool surface would let a judge other than a
  Claude session drive the loop. Doing it before task-graph-v1 §7b P2/P3 are
  closed would hand an external caller effect capabilities whose containment
  is unenforced — the same vector §1a reversed. So: after S5, not before.
- **Model-layer lane.** A gateway that emits a routing trace could add one
  lane under each dispatch in the flow view (which provider and account
  actually answered). Read-only, optional, and outside this repo.

---

## 4. Units (this plan's executable scope)

Four units, stacked in order (each unit branch bases on the previous one;
stop point `pr`, no merge in this run). Literal fields as in
loop-console-v1 §5: **C** create · **M** modify · **T** tests · **G**
generated · **Gate**.

**Implementers (revised at rounds 1 and 2, 2026-09-28).** The user named two
implementers, Claude Opus 5.5 and Grok 4.7 at extra-high effort, fast tier.
Neither calibrated path to them is open tonight: cursor-agent refuses named
models on the account's current plan (`ActionRequiredError: Named models
unavailable — Free plans can only use Auto`, recorded under
`<git-common-dir>/olddonkey-loop/cursor/20260928T105429Z-91a2a2/stderr.log`),
and the grok backend's tuple gate has no entry for grok 1.0.41 on this kernel
or for this repository (`~/.config/olddonkey-loop/grok-backend.toml`), while
that per-repo carve-out is a separate user grant the judge must ask for
(`SKILL.md:47`, `references/dials.md:5`). Grok runs are therefore **parked on
the user's grant**, not worked around.

Opus 5.5 implements every unit through a **sandboxed Claude Code dispatch**
that follows the cursor backend's protocol step for step
(`backends/cursor/runtime.md:99-144`), performed by a judge-side script (`plans/product-direction-v1-tools/claude-dispatch.sh`, with its selftest and README):

1. Validate the tag (`^[a-z0-9][a-z0-9.-]{0,40}$`, no `..`), run under
   `umask 077`, and — **before creating or chmod-ing anything** — refuse a
   symlinked root, a root whose parent is not an existing directory, and a
   root and real worktree that contain one another; only then create (if
   absent) the root `~/.config/olddonkey-loop/opus-work/`, require it to be a
   directory owned by the user, force it to mode 0700, and create
   `<root>/<tag>/` **exclusively** (an existing tag is refused; tags are
   single-use) and confirm it canonicalises inside the root. Snapshot the real
   unit worktree's `git ls-files -z --cached --others --exclude-standard` set
   into `pristine/` and clone it to `work/`. Refuse if either copy contains a
   `.git` entry or a symlink, or `git rev-parse --show-toplevel` succeeds from
   it.
2. Run `claude -p --model claude-opus-5-5 --effort xhigh` with `work/` as its
   working directory and this enforcement surface: **`--restricted`**, which
   confines the file tools (read and write) to the working directory, ignores
   user, project, and local settings files (managed settings and the
   `--settings` JSON this script supplies still apply), refuses
   `bypassPermissions`, and lets only a person
   approve writes to settings, git, and tool-configuration files;
   **`--tools Bash Read Edit Write Glob Grep`**, a closed built-in allowlist;
   `--permission-mode acceptEdits` with **`--permission-prompts none`**, so
   anything that would prompt is denied automatically; **`--no-chrome`**;
   Claude Code's OS sandbox for every Bash command
   (`sandbox.enabled`, `autoAllowBashIfSandboxed`,
   `allowUnsandboxedCommands: false`, so the per-command escape hatch is off;
   `failIfUnavailable: true`, so a sandbox that cannot start stops the session
   instead of running commands unsandboxed;
   `network.allowLocalBinding: true`, which the restricted-mode smoke shows is
   still refused at runtime — so **the console selftest is run by the judge
   on the host only**; egress denied); `--strict-mcp-config` with an empty
   server map; `--disallowedTools WebFetch WebSearch Task Agent`;
   **no setting sources at all** (`--setting-sources ""`), so neither user
   settings nor a tracked or agent-written `.claude/settings*.json` can add
   hooks (which run outside the sandbox), permissions, or writable paths;
   stdin from `/dev/null`; no session persistence; `--output-format
   stream-json --verbose`.
3. **Verify the granted tool surface from the CLI's own init event**: exactly
   one `system/init` event whose `tools` equal the allowlist and whose
   `mcp_servers` is empty; otherwise a boundary failure with the real worktree
   untouched. Then capture the result under a strict contract: a JSON object with
   exactly one `result` event with `subtype == "success"`, `is_error` **exactly** `false`,
   and `result` a string; anything else, or a nonzero exit, fails with the
   real worktree untouched. Refuse if a `.git` entry or a symlink appeared in
   `work/`. `work/.claude/` is harness scratch: it is removed before the diff
   (any settings file the agent wrote there is reported, never loaded, never
   applied).
4. `git diff --no-index --binary pristine work`, normalise headers, `git apply
   --check --binary` against the real worktree, then apply. The script never
   stages, commits, or pushes; the judge owns all Git.

**Script selftest** (judge-side, stub `claude` emitting the stream-json
shape; 30/30 on 2026-09-28): eight malformed results (not JSON, `is_error`
null / `"false"` / absent / true, wrong `subtype`, no `result`, an array)
each exit 1 with the real worktree untouched; four wrong tool surfaces (an
extra tool, an MCP server, no init event, too few tools) each exit 3,
untouched; six invalid tags refused; **root inside the real worktree, real
worktree inside the root, a symlinked root, and a symlink in the pristine
snapshot are each refused before the stub starts** (asserted by a start
marker); a reused tag refused; root and copy directories are mode 0700; a
`.git` or a symlink appearing in `work/` is a refusal; an agent-written
`.claude/settings.json` stays out of the patch; the argv carries
`--restricted`, the tools allowlist, `--no-chrome`, `--permission-prompts
none`, an empty `--setting-sources`, `failIfUnavailable`, and
`allowUnsandboxedCommands: false`.

**Restricted-mode smoke (2026-09-28, same flags, cheaper model):** the init
event listed exactly `Bash Edit Glob Grep Read Write` and no MCP server;
the Read tool on a file outside the copy was refused ("--restricted confines
the file tools to the working directory"); Write outside was refused; Bash
`echo >` outside was refused by the sandbox; `curl` was refused by the proxy;
Bash writing `.claude/settings.json` was refused; a 127.0.0.1 bind was
refused (so the console selftest is judge-only; the implementer is told not
to run it).

**Project-settings vector, demonstrated:** a `.claude/settings.json` in the
copy with a `PreToolUse` hook that `touch`es a path outside the copy wrote
that file when the session loaded `--setting-sources project`, and wrote
nothing with `--setting-sources ""` (same flags, same host, 2026-09-28).
`failIfUnavailable` could not be exercised because the sandbox starts on this
host; it is configured and asserted in argv, not demonstrated.

**Smoke evidence (2026-09-28, this host, claude 2.1.283, same flags with a
cheaper model — the boundary is enforced by the harness, not the model):**
Write inside the copy succeeded; Bash `echo > <outside path>` was denied by
the sandbox ("operation not permitted"); the Write tool to an outside path
was denied; `curl https://example.com` was denied by the network proxy; Bash
with `dangerouslyDisableSandbox` was denied; no outside file existed
afterwards; temp directories, `python3`, and `node` worked; a 127.0.0.1 bind
was refused until `allowLocalBinding` was set. **Stated gaps versus cursor:**
Bash can still *read* files outside the copy (the OS sandbox confines writes,
not reads; the file tools cannot, under `--restricted`) — cursor's
calibration does not claim read denial either; the Claude process's own API traffic is not blocked
(the same class as grok's agent-process gap, `backends/grok/runtime.md:126-133`);
and this dispatch is **not a registered backend**, so it writes no
`dispatch.start`/`dispatch.end` (the enum is `codex|grok|cursor`,
`scripts/loop-journal:81-88`). Tonight's Opus dispatches are recorded only as
`checkpoint` notes, which are declared text, and each PR says so. The
no-commit and no-full-suite rules are enforced as far as the sandbox goes
(no `.git` exists in the copy to commit to) and otherwise by instruction.

**Unit 1's main implementation dispatch (tag `u1-r2`) ran before the round-3
and round-4 hardening.** It lacked: `--restricted`, the tools allowlist,
`--no-chrome`, `--permission-prompts none`, `failIfUnavailable`, empty setting
sources (it loaded `--setting-sources project`), the init tool-surface check,
the strict result contract, symlink refusals, and private modes (its copy
directories were 0755, its output files 0644). Readbacks after the fact: its
output was one valid success result object; its copy held no symlinks and no
`.claude/settings*.json`; the three checkouts were unchanged apart from the
applied patch. Those readbacks do not prove the absence of every host-side
effect (for example a browser action through Claude in Chrome), and the PR
says so. Unit 1's review fixes and every later dispatch use the hardened
script.

An earlier attempt at round 1 ran Opus as an unconstrained Claude Code
subagent; it was stopped before producing a patch once round 2 showed that
boundary was instruction-only, and an audit found no writes outside its copy
(`git status` of all three checkouts unchanged). Nothing from it is used.

The judge is Claude Fable 5.1 and the implementer Claude Opus 5.5: different
models, same vendor family — the pairing caveat of `references/dials.md:5` is
surfaced here rather than silently. Cross-review for Units 1 and 4 moves from
grok to Codex `gpt-6-sol` read-only, which restores a cross-vendor check where
it matters most.

**The journal is a local record, not an authenticated one.** Any process
running as the user can append to it: `cmd_append` validates payload shape,
not the actor (`scripts/loop-journal:921-960`), and the host gate executes
repository-supplied commands (`scripts/run-gate.sh:509`), so a tracked test
suite can append a false review or publication during a gate. task-graph-v1
already calls this a single-writer convention, not an OS boundary
(`plans/task-graph-v1.md:1082-1084`), and fixes it only with Phase A's trusted
writer. Until then every surface in this plan presents journal content as
**recorded, unverified claims**; none presents anything as a judge-verified or
proven action.

**Gate for every unit** is the whole of `.github/workflows/selftest.yml`
run on the host (both jobs; each `run:` step extracted verbatim), because the
suites overlap: `run-gate.sh` and `tests/gate-selftest.sh` are Cursor
package build inputs (`build.sh:72-73`), and loop-console-v1's Unit 2 merged
red once because its gate list omitted the installer selftest. **Host
environment defect:** this Mac's Homebrew bash 5.3.20 on macOS 27 sometimes
dies with SIGSEGV inside its own `termsig_handler` → `kill_shell` (crash
reports `~/Library/Logs/DiagnosticReports/bash-*.ips`), which turns an
expected exit into 139. On untouched `dd203b9` this fails
`tests/contract-core.sh` check 113 reproducibly and `backends/codex/selftest.sh`
check 101 intermittently. A failure is waived as environmental **only** when
all three hold for that exact failure: its status is 139; a bash crash report
with `termsig_handler` → `kill_shell` frames is timestamped within that
step's run; and the same check fails the same way on the untouched base tree
in the same session. A waived step is reported as "host: unresolved
(environmental)", never as green; the PR's ubuntu CI corroborates but does not
convert it. Any other red is red.

### Unit 1 — gate verdict (task-graph-v1 unit 0b)

*Implementer: Opus 5.5 (subagent, git-less copy). Cross-review: Codex
`gpt-6-sol` read-only.*

**Why.** `emit_result` journals `$STATUS`, the suite's exit, then exits with
`$code`, the gate's (`scripts/run-gate.sh:318-319`; `STATUS=$?` at `:510`).
Call sites that exit 1 while `STATUS=0` make a red gate's `gate.result` equal
a green one's: `:567, :578, :581, :584, :601, :613, :616`, and `:522/:528`
when the suite exited 0. The reverse also exists: `:638` (baseline, failures
match baseline) is green with `STATUS=1`. `loop-index` passes `totals`
through without a verdict (`scripts/loop-index:466-483`). The console labels
any `binding=clean` gate "Publication evidence" whatever its outcome or
purpose (`scripts/console-assets/console.js:758-767`, asserted by
`tests/console-selftest.sh:1158-1166`), although a clean gate may be
`purpose=focused` or `baseline-generation` (`scripts/loop-journal:97-106`) and
even a unit-final gate samples only its endpoints (`plans/task-graph-v1.md:225-236`).

**Change.**
- `gate.result` gains `verdict` ∈ {green, red}, derived from the same `$code`
  the process exits with, and `gate_exit` (int). `totals` stays, unchanged, as
  the raw suite exit (task-graph-v1 §7: "keep the raw suite exit separately").
  Both new fields are optional in the validator (legacy history lacks them)
  and always written by `run-gate.sh`.
- `loop-index` emits `verdict`: `green` only when `verdict == "green"` and
  `gate_exit` is exactly an int (`type(v) is int`, so never `bool` or
  `float`) equal to 0; `red` only when `verdict == "red"` and `gate_exit` is
  exactly an int other than 0; **`unknown` otherwise** — absent, malformed, or
  inconsistent pairs, `false`, `0.0`, and legacy history. The index reads
  stored JSON without payload validation (`scripts/loop-index:224-246`) and the
  journal is unauthenticated, so the reader's check cannot rely on the
  writer's. It never infers a verdict from `totals`.
- The console drops the "Publication evidence" / "Not publication evidence"
  claim entirely. A gate card shows the recorded verdict as a word chip
  (green → ok, red → danger, unknown → neutral), the binding chip, and
  `policy · purpose`, under one fixed caveat: "Recorded gate result — not
  proof of what ships."

C: none.
M: `skills/implementation-loop/scripts/run-gate.sh`,
`skills/implementation-loop/scripts/loop-journal` (EVENT_SPECS `:97-116`,
INT_FIELDS `:119-121`), `skills/implementation-loop/scripts/loop-index`
(`build_gates`), `skills/implementation-loop/scripts/console-assets/console.js`
(`createGate`/`updateGate`), `skills/implementation-loop/references/state-schema.md`
(a `gate.result` subsection; today the event appears only in the closed list
`:46-50` and the checkpoint sentence `:204-206`), and every document that
states the gate-selftest check count: `AGENTS.md`, `README.md`,
`README.zh-CN.md`, `hosts/cursor/README.md`,
`hosts/cursor/skills/cursor-implementation-loop/references/cursor-runtime.md`
(the last two are Cursor build inputs; their generated copies follow from
`bash build.sh`).
T: `tests/gate-selftest.sh` — `expect_gate_result` (`:174-204`) asserts
`verdict` and `gate_exit`; one journal case per reachable exit-zero-but-red
path above, each asserting `verdict=red`, `gate_exit=1`, `totals=exit=0`;
the `:638` reverse case; at least one assertion compares the journaled
verdict with the process exit the test observed, so reverting to `$STATUS`
fails; the skip branch (`:906-913`) emits as many checks as the live branch.
`tests/journal-selftest.sh` — accepts green/0; rejects `verdict=maybe`,
`gate_exit=abc`, and an unknown key with exit 2. `tests/index-selftest.sh` —
green/0 → green; red/1 → red; green/1, red/0, green without `gate_exit`,
green with `gate_exit` `false`, green with `0.0` (written as raw segment
lines, since the append validator refuses them), and the legacy pipeline
fixture (`:401-404`) → `unknown`; malformed → `unknown`.
`tests/console-selftest.sh` — the old assertion at `:1158-1166` is replaced:
no gate card ever contains the string "Publication evidence"; chips and the
fixed caveat for green, red, and unknown.
G: `cursor-implementation-loop/` regenerated by `bash build.sh`;
`hosts/cursor/version-decision.tsv` line 2 updated to the new tree hash, line 3
unchanged (`bump=0.3.0` still matches the unreleased plugin version,
`hosts/cursor/.cursor-plugin/plugin.json:4`; a further bump is a release
decision left to the user).
Gate: full CI (above).

### Unit 2 — declared attribution, run totals, and an ordered timeline

*Implementer: Opus 5.5 (subagent, git-less copy).*

**Why.** No dispatch or gate event names its unit: `dispatch.start` carries
only `dispatch_id`, `backend`, `mode` (`scripts/loop-journal:81-88`), and
`gate.result` has no `unit` either (`:97-116`). `build_units` skips any event
without a `unit` (`scripts/loop-index:382-384`). Joining them by order or
time is what the shipped design refuses: it never attaches by timestamp
proximity (`plans/loop-console-v1.md:166`), and task-graph-v1 §3 holds that
"serial adjacency is not identity". Separately, `loop-index` collapses events
into per-entity records and drops `seq` and `ts` (the journal writes both,
`scripts/loop-journal:869-875`), so no reader can replay a run in order.

**Change.**

1. **Declared attribution through the environment.** `loop-journal append`
   reads `LOOP_UNIT` and `LOOP_ROUND` for exactly four events —
   `dispatch.start`, `dispatch.end`, `dispatch.abandoned`, `gate.result` — and
   writes them as optional payload fields `unit` (str) and `round` (int ≥ 1)
   when the payload does not already carry them. An invalid value (empty,
   newline, round not a positive int) fails the append with exit 2, which
   makes an adapter refuse to launch (`backends/cursor/dispatch.sh:333-337`,
   `backends/grok/dispatch.sh:962-966`; codex raises `StateError`) and makes
   the gate warn. Other events ignore the variables. The judge sets them per
   command. **No adapter or `run-gate.sh` change**: all three adapters and the
   gate already call `loop-journal append` as a child process; the unit
   verifies each passes the environment through (codex's helper:
   `backends/codex/dispatch.sh:659-673`) with a contract test per backend.
2. **Recovery.** `recover --acknowledge` writes `dispatch.abandoned` directly
   through `append_event`, bypassing `cmd_append`
   (`scripts/loop-journal:1193-1202`), and `unmatched_starts` keeps duplicate
   `dispatch_id` entries while putting ended ids in a set (`:1145-1157`), so
   two starts and one end for one id read as fully closed. So: before
   considering closures, acknowledgements, or retirement, recovery scans the
   active run and fails with exit 2 — **before any append or context
   retirement** — if any `dispatch_id` has more than one `dispatch.start` or
   more than one terminal event (`dispatch.end`/`dispatch.abandoned`). With
   every id at most one start and one terminal, each acknowledged id must
   have exactly one start and no terminal. With exactly one, it copies
   that start's `unit`/`round` when present and writes neither when absent. It
   never reads the environment.
3. **Conflicts are unknown.** In the index, a dispatch's attribution is the
   value its events agree on. If `start`, `end`, and `abandoned` for one
   `dispatch_id` carry different `unit` or `round` values, the dispatch gets
   `attribution: "conflict"` and **no** `unit`/`round`; views treat it as
   unattributed. A dispatch with no `start` keeps whatever its other events
   agree on, with `attribution: "partial"`. Otherwise `attribution` is
   `"declared"` or `"none"`.
4. **The label is a declaration, not proof.** `state-schema.md` records that
   `unit`/`round` on these events are declared by whoever ran the command,
   carry no digest, and can be written by any local process (see the journal
   note above). Unit 0a's reducer reads them as declared attribution with the
   weakest assurance.
5. **Index output.** Dispatch and gate objects carry `unit`, `round`, and
   `attribution` as above. Each run gains:
   - `counts_complete`: `true` only when the run's segment parsed with no
     mid-file corruption **and** no discarded bytes — an invalid unterminated
     tail is discarded by the parser (`scripts/loop-index:224-246`) and
     `inspect_run` currently drops that signal (`:280`), so the unit
     preserves it. A degraded run or a discarded tail gets `false`, and every
     consumer labels its counts "partial".
   - `counts`: totals over **all parsed** events of the run, never the window —
     `{"all": C, "units": {"<unit>": C, …}, "unattributed": C}` where `C` is
     `{"dispatches": {"<backend>": {"ok": n, "failed": n, "open": n,
     "abandoned": n}}, "reviews": {"iterate": n, "pass": n}, "gates":
     {"green": n, "red": n, "unknown": n}, "publishes": n}` ("ok" means a
     recorded exit of 0, nothing more);
   - `timeline`: the run's events in `seq` order, each projected to a closed
     whitelist — `seq`, `ts`, `event`, and when present `dispatch_id`,
     `mode`, `exit`, `binding`, `purpose`, plus:
     `gate_verdict` on `gate.result` only (Unit 1's normalised
     green/red/unknown); `review_verdict` on `review.recorded` only
     (`pass|iterate`, anything else `unknown`); and for the three `dispatch.*`
     events, `backend`, `unit`, `round`, and `attribution` **resolved from the
     full dispatch record**, not from the event — so an end whose start fell
     outside the window still names its backend, and a conflicted dispatch
     carries `attribution: "conflict"` and no unit on every one of its events.
     Every other packet-bearing event also carries `unit` and `attribution`:
     `gate.result` its own declared `unit`/`round` with `attribution:
     "declared"` when a unit is present and `"none"` otherwise;
     `review.recorded` and `publish.recorded` their required `unit` with
     `attribution: "declared"`. Free-text fields
     (`findings`, `note`, `plan`, `reason`, `attested_by`, `branch`, `pr`,
     `sha`) are never projected. At most the last 500 events, with
     `timeline_truncated: true|false`.
   Unattributed-file events are in no run's timeline or counts (the top-level
   count stays).

C: none.
M: `skills/implementation-loop/scripts/loop-journal`,
`skills/implementation-loop/scripts/loop-index`,
`skills/implementation-loop/references/state-schema.md`,
`skills/implementation-loop/SKILL.md` (§2 dispatch and §5 gate examples set
`LOOP_UNIT`/`LOOP_ROUND`; one sentence that the label is declared, not
proof), `AGENTS.md` (counts).
T: `tests/journal-selftest.sh` — env fills the four events; explicit payload
wins over env; other events ignore env; invalid values exit 2; unknown keys
still exit 2; `recover --acknowledge` run with **no** `LOOP_UNIT`/`LOOP_ROUND`
in its environment copies them from the matching start, and writes neither
when the start had none; two starts with one id (equal labels, conflicting
labels), two starts plus one end, one start plus two ends, and one start plus
an end and an abandonment — each run both with and without `--acknowledge` —
fail recovery with exit 2 and leave the segment and the context file
byte-identical. `tests/contract-core.sh` — for each of codex, grok,
cursor, a fixture dispatch with `LOOP_UNIT=uX LOOP_ROUND=2` journals both
`dispatch.start` and `dispatch.end` carrying them, and one without the
variables carries neither. `tests/gate-selftest.sh` — a gate run with the
variables journals them. `tests/index-selftest.sh` — attributed and
unattributed dispatches/gates; conflicting start/end → `conflict` with no
unit on every timeline event of that dispatch; end without start →
`partial`; an end whose start is outside the 500-event window still carries
its resolved backend; every packet-bearing event type carries `unit` and
`attribution` as specified; a discarded torn tail → `counts_complete: false`; `counts` over a run of 600 events equal the true totals
while `timeline` holds 500 and sets the flag; a corrupt-middle segment with
countable events after the damaged line → `counts_complete: false`; review
events carry `review_verdict` and gate events `gate_verdict`, never each
other's; timeline order by `seq`; the whitelist excludes every free-text field
(a fixture whose free-text fields, including `pr` and `branch`, contain a
marker string that must appear nowhere in the output).
G: `cursor-implementation-loop/` and `version-decision.tsv` line 2 (gate
selftest is a build input).
Gate: full CI.

### Unit 3 — `loop-evidence`, the per-unit record card

*Implementer: Opus 5.5 (subagent, git-less copy).*

**Why.** The PR body is where a reviewer decides whether to trust a unit.
The doctrine asks for commits and PRs "so an absent reader understands why,
with real gate numbers" (`SKILL.md:177`), and today the judge assembles that
by hand from its own notes. With verdicts (Unit 1) and declared attribution
(Unit 2) in the record, a card derived mechanically from it is cheaper and
cannot be shaded by the judge's wording — while stating plainly that it is
a record, not a proof.

**Change.** New `scripts/loop-evidence`:
`loop-evidence --unit U [--run RUN_ID] [--workspace DIR] [--format markdown|json]`.
It runs the sibling `loop-index --workspace <canonical>` with a fixed argv
and a timeout, exactly as the console does (`scripts/loop-console:590-596`),
and never reads the journal, the repository, or any tracked file itself
(loop-index is the only reader, `scripts/loop-index:7-8`). Default run: the
context's active run, else the newest run containing the unit; the card
always prints the run id.

Every row has two separate fields. `strength` is exactly one of four
strings — `recorded`, `declared`, `values match`, `unknown` — and nothing
else, in both formats. `attribution` is exactly one of `declared`, `none`,
`not applicable`.

| row | source | strength | attribution |
| --- | --- | --- | --- |
| dispatches attributed to U (count, backend, mode, recorded exits) | dispatch objects with `unit == U` and `attribution == "declared"` | recorded | declared |
| review rounds and last recorded verdict | `round.begin` / `review.recorded` | recorded | not applicable |
| final gate: verdict, policy, purpose, binding, post head | the last `gate.result` for U with `purpose == "unit-final"` | recorded; `unknown` when absent | declared; `none` when absent |
| later adverse gates | every gate for U after the final gate whose verdict is red or unknown | recorded | declared |
| recorded SHAs | gate `post_head` and `publish.sha`, **both present and both 40 lowercase hex**, equal | values match, else unknown | not applicable |
| publication (branch, PR, sha) | `publish.recorded` | recorded, or unknown when absent | not applicable |

Honesty rules: a gate whose verdict is `unknown` renders as unknown; no
unit-final gate → "no final gate recorded"; if either SHA is missing or not
40 hex → "cannot compare"; unequal → "recorded SHAs differ"; `binding ≠
clean` is shown; conflicted or partial dispatches are listed separately as
"attribution unclear". The words proven, verified, passed, and safe never
appear. The card ends with one fixed sentence: "Every row is an unverified
entry in the local journal, which any process running as this user can
append to; nothing here meets task-graph-v1 §3's proof bar."

**Escaping, defined.** Every journal-sourced string is rendered through one
function, in this order: CR, LF, and tab become a space; `&`, `<`, `>`, `"`,
`'` become `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`; then each of
`` \ ` * _ { } [ ] ( ) # + - . ! | ~ `` is backslash-escaped. No
journal-sourced string is ever emitted as a link, image, or raw HTML; the PR
URL is printed as escaped text. `--format json` emits the same data as JSON
with no escaping beyond JSON's own. Output is deterministic. Exit 2 on usage
errors or an unknown unit, 5 when the index fails.

C: `skills/implementation-loop/scripts/loop-evidence`,
`skills/implementation-loop/tests/evidence-selftest.sh`.
M: `.github/workflows/selftest.yml` (`bash -n` for both, plus a run step),
`skills/implementation-loop/SKILL.md` (§6: the card may be pasted into the
PR body, and says what it is), `skills/implementation-loop/references/state-schema.md`
(reader list), `AGENTS.md` (the new suite and its count).
T: `tests/evidence-selftest.sh` — green path; red final gate; legacy gate
without verdict → unknown (the test fails if the output contains "green" for
it); no final gate → that row reads `strength: unknown`, `attribution:
none`; both SHAs missing, one missing, one malformed → "cannot compare";
unequal → "recorded SHAs differ"; a later red gate after a green final gate
is listed; unattributed and conflicted gates/dispatches are not counted for
U; a later **unknown** gate is listed as adverse too; iterate then pass;
unknown unit → exit 2; **exact-output** escaping assertions for `<script>`,
`&`, backslashes, `[x](http://e)`, `![i](http://e)`, `|` inside a table cell,
backticks, and a string containing CR, LF, and tab (a raw segment line, since
the append validator refuses newlines); **the exact `strength` and
`attribution` value of every row** in both formats, plus a JSON-schema-style
check that no other value occurs; no "proven", "verified", "passed", or "safe"
anywhere; a **hostile
tracked-suite fixture** — a gate whose command itself runs
`loop-journal append` to add a forged `review.recorded` and
`publish.recorded` — whose card still labels those rows `recorded` and
carries the fixed sentence; `--format json` round-trips; index failure →
exit 5.
G: none (not a Cursor build input).
Gate: full CI.

### Unit 4 — read-only flow view in the console

*Implementer: Opus 5.5 (subagent, git-less copy). Cross-review: Codex
`gpt-6-sol` read-only (web surface).*

**Why.** The user's stated picture of the product is traffic moving between
the parts of the loop. S3 draws that picture read-only, from Unit 2's
`counts` and `timeline`, inside the console that already carries the
authentication and CSP model: authenticated, CSRF-checked `/api/state`
(`scripts/loop-console:920-924`), the security headers
(`scripts/loop-console:56-66`), and a fixed asset set served from
`ASSET_TYPES` (`scripts/loop-console:67-71`; `plans/loop-console-v1.md:376-381`).

**Change.** A "Flow" section between "Now" and "This run", rendered from
`/api/state` only: no new endpoint, no new asset file.

- **SVG through an allowlist.** One helper `svgEl(tag)` creates elements with
  `document.createElementNS("http://www.w3.org/2000/svg", tag)` and refuses
  any tag outside {`svg`, `g`, `path`, `circle`, `rect`, `line`, `text`,
  `title`, `desc`}. One helper `svgAttr(node, name, value)` refuses any
  attribute outside {`viewBox`, `d`, `cx`, `cy`, `r`, `x`, `y`, `x1`, `y1`,
  `x2`, `y2`, `width`, `height`, `rx`, `class`, `role`, `aria-label`,
  `aria-hidden`, `focusable`, `text-anchor`} and refuses any value
  containing `url(`, `javascript:`, or `<`. Journal-sourced strings (unit
  names, backends) reach the DOM **only** through `textContent`, never an
  attribute other than `aria-label`, which is itself assembled from fixed
  words plus counts.
- **Layout.** Fixed: Judge; one implementer node per backend present in the
  run's `counts` (order codex, cursor, grok); Review; Gate; Publication.
- **Edge labels come from `counts`**, the full-run totals, for the selected
  filter. When `timeline_truncated` is true the section says "packets show
  the last 500 events; totals cover the whole run". When `counts_complete` is
  false every label is prefixed "partial" and the section says the run's
  record is damaged.
- **Event-to-edge map (closed).** `dispatch.start`: Judge → its backend;
  `dispatch.end`: backend → Judge; `dispatch.abandoned`: backend → Judge;
  `review.recorded`: Judge → Review; `gate.result`: Judge → Gate;
  `publish.recorded`: Judge → Publication. There is **no Gate → Publication
  edge** in the drawing: the journal records no relation between a gate and a
  publication (`scripts/loop-journal:77-79`), and adjacency is not identity
  (task-graph-v1 §3). Every other event type
  (`run.*`, `unit.*`, `round.begin`, `checkpoint`, `journal.repaired`) makes
  no packet. The backend of a `dispatch.*` packet is the timeline's resolved
  `backend` (Unit 2); `unknown` makes no packet.
- **Packets are recorded outcomes, styled as such.** One packet per timeline
  event with `seq` above the highest `seq` already shown **for that run id**;
  the high-water mark is kept per run id and a run switch resets rendering
  without replaying history; the first render of any run animates nothing.
  Recorded successes (exit 0, review pass, gate green) are `neutral`;
  recorded failures (nonzero exit, gate red) are `danger`; iterate is
  `caution`; unknown is `neutral`. A fixed legend reads "recorded events —
  not verified". No packet or edge ever uses the `ok` variant.
- **Reduced motion.** When `matchMedia("(prefers-reduced-motion: reduce)")`
  matches, no packet element is created at all; counts still update. With
  motion, packets are removed on `animationend`, and at most 20 packet
  elements exist at once (older ones are removed first).
- **Filter.** A `<select>`: All, each unit in `counts.units`, Unattributed.
  A packet belongs to a unit only through the timeline's resolved
  attribution (`attribution == "declared"` and `unit`); conflicted, partial,
  and unlabelled events belong to Unattributed, in counts and packets alike.
- **Accessibility.** The SVG has `role="img"` and an `aria-label` built from
  fixed words and counts; a visually hidden list gives the last ten events as
  text.
- **Read-only.** No drag handles, no handler that changes server state. The
  flow code issues no request of its own; it reads the object the existing
  `/api/state` poll already fetched.
- Constraints from the shipped selftest still hold: no `innerHTML`/
  `outerHTML`/`insertAdjacentHTML`, no `.style.`, no `setTimeout`, no
  substring "eval", no `new Function` (`tests/console-selftest.sh:232-249`);
  colours come from existing OKLCH tokens (`console-assets/console.css:1-63`),
  and any new token exists in both themes (`tests/console-selftest.sh:285-361`);
  keyed in-place updates (`syncKeyed`, `console.js:76-124`) — a poll never
  rebuilds the SVG. Old index output without `counts`/`timeline` → an
  empty-state hint.

C: none.
M: `skills/implementation-loop/scripts/console-assets/index.html`,
`skills/implementation-loop/scripts/console-assets/console.js`,
`skills/implementation-loop/scripts/console-assets/console.css`.
T: `tests/console-selftest.sh` — the fake DOM gains `createElementNS` and
`matchMedia`, and the new helpers join the extraction lists (`:651-692`,
`:973-1013`). Render: nodes only for backends present; first render → zero
packets; an update with two new events → exactly two packets with the right
classes; a repeated update → none; a run switch → zero packets and a reset
high-water mark; A → B → A with new events on A in between → exactly those
new events animate on return; 21 events arriving in one update → at most 20
packet elements; reduced motion → zero packets while counts change; a
`dispatch.end` whose start is outside the window routes to its resolved
backend; a conflicted dispatch's packets appear under Unattributed and under
no unit, for every filter value; `counts_complete: false` → "partial" labels; a publication with no gate, and
a publication after a red gate, both route Judge → Publication, and the SVG
contains no Gate → Publication path; each packet-bearing event type lands
under All, under its unit, and not under Unattributed (and a unit-less gate
under Unattributed only);
truncated timeline → the notice and edge labels equal to `counts`, not to
the window; no element ever carries the `is-ok` class inside the flow
section; `svgEl` accepts each allowlisted tag and refuses **every** tag in a
list of at least twenty others (including `script`, `foreignObject`, `a`,
`image`, `use`, `animate`, `set`, `style`, `iframe`, `object`); `svgAttr`
accepts each allowlisted attribute and refuses **every** attribute in a list
of at least twenty others (including `href`, `xlink:href`, `onload`,
`onclick`, `style`, `src`, `fill` with `url(`), and refuses a `url(`,
`javascript:`, or `<` value on an allowlisted attribute; a unit named
`<img src=x onerror=1>` appears only as text; a fake `fetch` records every
call during render, filter change, and run switch, and the test asserts the
flow code made **zero** calls; node identity is preserved across
updates; the source-ban checks still pass.
**Plus a real-browser render by the judge** at gate time (the console
selftest never renders a page, and loop-console-v1 shipped an unopenable
page for that reason — commit `f612848`).
G: none.
Gate: full CI plus the browser render.

---

## 5. Risks

| risk | mitigation |
| --- | --- |
| Declared attribution is read as proof | `state-schema.md` names it declared; the evidence card labels every attributed row "declared attribution"; unit 0a reads it with the weakest assurance (§3a) |
| A wrong `LOOP_UNIT` silently misfiles a dispatch | the value is visible in the dispatch summary, the index, the card, and the flow view; the judge sets it per command; a misfiled row is a wrong declaration, never a promoted verdict |
| S1–S3 grow schema-1 history that 0a must carry | fields are optional, typed, enumerated in `state-schema.md`; 0a already owes schema-1 compatibility (task-graph-v1 §7 item 1) |
| The flow view becomes the product and the doctrine erodes | §2's honesty rule; the view is read-only until task-graph-v2; it renders only what the index already states |
| Card or view shows green for a red or unknown gate | Unit 1 makes the verdict explicit; Units 3–4 tests assert unknown is never green and red is never "publication evidence" |
| The gate still samples rather than enforces (task-graph-v1 §7b P1) | out of scope and stated so; the card's fixed closing sentence says no row meets the proof bar |
| The user-named implementers are unavailable tonight (cursor plan, grok grant) | Opus 5.5 implements every unit through a copy/patch boundary the judge operates; the substitution and its weaker boundary are stated in §4 and in each PR; grok is parked on the user's grant, not worked around |
| A local process forges journal entries | stated in §4; every surface says "recorded, unverified"; Unit 3's hostile-suite fixture pins the wording; the real fix is task-graph-v1 Phase A's trusted writer |

---

## 6. Non-goals for this plan

Anything that causes an effect beyond what the loop already does: no new
executor, queue, daemon, timer, or endpoint that mutates state. No canvas
editing, drag handles, or approval UI (task-graph-v2). No change to gate
policy logic or the before/after sampling (task-graph-v1 §7b P1). No
multi-workspace board, remote access, or multi-user access. No new console
asset files. No recording of model/effort per dispatch (worth doing, but it
changes all three adapters and one of them has unmerged work in another
checkout). No merge of any unit in this run.

---

## 7. Open questions for review

1. Is environment-variable attribution (Unit 2) the right mechanism, versus
   explicit `--unit/--round` flags on each adapter and on `run-gate.sh`? Env
   keeps the change in one file and needs no adapter edit; flags are more
   visible in argv. The plan picks env; say if that weakens anything.
2. Should the timeline cap (500) be a per-run constant or configurable? The
   plan fixes it.
3. Does Unit 3's "newest run containing the unit" default risk picking a
   stale run when a unit name is reused across runs? The plan accepts it
   because `--run` exists and the card prints the run id.
4. Is anything in §3 (stage order) wrong given task-graph-v1's §7b
   interlock?

---

## 8. Round-1 disposition (Codex gpt-6-sol / max, 2026-09-28)

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: Unit 1 calls an unproven gate "Publication evidence" | **accepted.** The claim is removed entirely; the card shows recorded verdict, binding, and purpose under a fixed caveat. The index returns `unknown` for inconsistent `verdict`/`gate_exit` pairs, with tests. |
| 2 | BLOCKER: tracked test code can forge journal entries the card and view read | **accepted.** §4 now states the journal is local and unauthenticated (`loop-journal:921-960`, `run-gate.sh:509`, task-graph-v1:1082-1084); every surface presents recorded, unverified claims; Unit 3 adds a hostile tracked-suite fixture and a closed vocabulary. Authenticated provenance stays with Phase A. |
| 3 | BLOCKER: green packets contradict the honesty rule | **accepted.** Recorded successes are neutral, failures danger, iterate caution; a fixed "recorded events — not verified" legend; a test that no flow element carries `is-ok`. |
| 4 | MAJOR: recovery path bypasses the env hook | **accepted.** `recover --acknowledge` copies `unit`/`round` from the matching `dispatch.start`, never reads env; tested without the variables. |
| 5 | MAJOR: conflicting attribution undefined | **accepted.** Disagreeing events → `attribution: "conflict"`, no unit; end without start → `partial`; views treat both as unattributed; tested. |
| 6 | MAJOR: false commit match | **accepted.** "Recorded SHAs match" requires two present 40-hex values; missing/malformed → "cannot compare"; later red or unknown gates are listed; tested. |
| 7 | MAJOR: escaping incomplete | **accepted.** One defined escaping function (whitespace, HTML entities, Markdown punctuation), no journal string ever emitted as link/image/HTML, exact-output tests. |
| 8 | MAJOR: totals from a partial timeline; high-water and reduced motion | **accepted.** Unit 2 adds full-run `counts`; edge labels use them; truncation notice; per-run high-water reset on run switch; reduced motion creates no packets; packet cap 20; tests for 600 events, run switch, reduced motion. |
| 9 | MAJOR: SVG and interaction paths untested | **accepted.** Tag and attribute allowlists with refusal tests, text-only journal strings, hostile unit names, and a fake-`fetch` assertion of no POST or dial request during render, filter, and run switch. |
| 10 | MINOR: provenance | **accepted.** §2 cites the closed event list and the console render range; Unit 2 now cites `plans/loop-console-v1.md:166` and task-graph-v1 §3 instead of misreading `state-schema.md:162-163`; Unit 3 cites what `SKILL.md:177` actually says; §2 separates direction from tonight's diagnostic scope. |

Also changed since round 1, not from a finding: implementer availability
(§4) — the user-named cursor models are refused on the account's plan and the
grok tuple has no grant for this repository, so Opus 5.5 implements every unit
through a copy/patch boundary, and cross-review moves to Codex.

## 9. Round-2 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: the Opus substitution has no enforced boundary | **accepted.** §4 now specifies a sandboxed `claude -p` dispatch with the cursor protocol's four steps, its exact enforcement flags, smoke evidence from this host, and its stated gaps (reads, agent-process traffic, not a registered backend so no dispatch events — checkpoint notes only). The unconstrained attempt was stopped and audited; nothing from it is used. |
| 2 | MAJOR: the host-gate waiver can hide a regression | **accepted.** A waiver needs status 139, a matching crash report inside that step's run, and the same failure on the untouched base in the same session; a waived step reads "host: unresolved (environmental)", never green. |
| 3 | MAJOR: `gate_exit == 0` matches `false` and `0.0` | **accepted.** `type(v) is int` for both verdicts; `false` and `0.0` tested as unknown via raw segment lines. |
| 4 | MAJOR: recovery assumes a unique start | **accepted.** Exactly one unmatched start or the whole recovery fails with exit 2 before any append or context retirement; equal and conflicting duplicate labels tested with byte-identical state afterwards. |
| 5 | MAJOR: counts on a degraded run are not full-run | **accepted.** `counts_complete`; consumers label partial; corrupt-middle fixture. |
| 6 | MAJOR: verdict vocabularies conflated; `pr` is free text | **accepted.** `gate_verdict` and `review_verdict` are separate event-specific fields; `pr`, `branch`, `sha` leave the timeline; marker test covers them. |
| 7 | MAJOR: strength vocabulary not closed | **accepted.** Separate `strength` (four exact values) and `attribution` (three exact values) fields; exact value asserted for every row in both formats; later unknown gate and CR/LF/tab escaping tested. |
| 8 | MAJOR: packets not routable or filterable from inputs | **accepted.** The index resolves `backend` and attribution for every `dispatch.*` timeline event from the full record; a closed event-to-edge map; evicted-start and conflicted-dispatch tests under every filter. |
| 9 | MAJOR: tests do not enforce the protections | **accepted.** 21 arrivals, A→B→A, allowlist tests against twenty-plus unlisted tags and attributes each, and zero flow-originated requests. |
| 10 | MINOR: `.git` citation path | **accepted.** Cited as `<git-common-dir>/olddonkey-loop/cursor/…`. |

## 10. Round-3 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: sandbox can fall back to unsandboxed | **accepted.** `failIfUnavailable: true`, asserted in the script selftest's argv check; stated as configured, not demonstrated. Unit 1's dispatch predates it; §4 records the evidence that its sandbox ran and the PR discloses it. |
| 2 | MAJOR: project settings loaded into the boundary | **accepted.** `--setting-sources ""`; the hook vector was demonstrated with `project` and absent with `""`; agent-written settings are reported, never loaded or applied. |
| 3 | MAJOR: script lacks the protected-copy protocol | **accepted.** Tag validation, `umask 077`, private owned root with no symlink, mutual-containment refusal, exclusive single-use tag directory, symlink refusal in both copies; selftested. |
| 4 | MAJOR: malformed JSON can pass | **accepted.** Strict result contract (`type`, `subtype`, `is_error is False`, string `result`); eight malformed stubs selftested with the worktree untouched. |
| 5 | BLOCKER: duplicate-start closure bypass | **accepted.** Recovery refuses any run where an id has more than one start or more than one terminal, before closures, acknowledgements, or retirement; two-starts/one-end tested with and without `--acknowledge`. |
| 6 | MAJOR: torn tail counted as complete | **accepted.** The discarded-tail signal is preserved; `counts_complete` is false for either corruption or discarded bytes; both tested. |
| 7 | MAJOR: filter lacks attribution for review/gate/publication | **accepted.** Every packet-bearing event carries `unit` and `attribution`; tests per event type under every filter value. |
| 8 | MAJOR: absent final gate marked declared | **accepted.** `strength: unknown`, `attribution: none`; asserted. |
| 9 | MAJOR: Gate → Publication implies an unrecorded relation | **accepted.** Publication routes Judge → Publication; no Gate → Publication path exists; tested with no gate and after a red gate. |

## 11. Round-4 disposition, and the review cap

The unattended run capped plan review at four rounds. Round 4's findings were
all concrete and mechanical, so the cap is extended by one round (round 5) to
re-verify these fixes. Review may overlap implementation, but dependent unit
implementation stays **serial** (one unit in flight, `SKILL.md:98`): each unit
starts only after its predecessor's branch is final, and any round-5 finding
against a unit becomes that unit's next iteration.

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: browser tool surface and prompt handling not closed | **accepted.** `--restricted`, a closed `--tools` allowlist, `--no-chrome`, `--permission-prompts none`; the CLI's own init event is checked after every dispatch (exact tools, no MCP) before any patch is applied; restricted-mode smoke recorded above. The gap applied to Unit 1's `u1-r2` dispatch and is disclosed there and in its PR. |
| 2 | MAJOR: selftest does not exercise the containment checks | **accepted.** Root-inside-worktree, worktree-inside-root, symlinked root, and pristine symlink cases, each asserting the stub never started and the worktree is untouched; plus four tool-surface cases. 30/30. |
| 3 | MAJOR: duplicate-terminal refusal untested | **accepted.** One start plus two ends, and one start plus end plus abandonment, each with and without acknowledgement, byte-identical state afterwards. |
| 4 | MINOR: pre-hardening disclosure too narrow | **accepted.** Every missing protection and every readback is listed; the text says readbacks do not prove absence of all host-side effects. |
| 5 | MINOR (Unit 1 diff): no journal case for the normalization-failure path | **accepted as a Unit 1 iteration** (tag `u1-r3`, hardened script). |
| 6 | MINOR (Unit 1 diff): schema says run-gate.sh is the only writer | **accepted as a Unit 1 iteration**: "intended mechanical writer" plus the unauthenticated-journal sentence. |
| 7 | MINOR: Unit 1's Modify list omits the count documents | **accepted.** Listed, with their generated copies. |

## 12. Round-5 disposition — ACCEPT

| # | finding | disposition |
| --- | --- | --- |
| 1 | MINOR: root created/chmod-ed before the containment check | **accepted.** All refusals run before any `mkdir`/`chmod`; the selftest asserts the in-worktree root path does not exist after refusal, and that an outer root's and a symlink target's modes and contents are unchanged. |
| 2 | MINOR: settings and local-binding descriptions overstated | **accepted.** `--restricted` ignores user/project/local settings while managed settings and the supplied `--settings` apply; the console selftest is judge-only because the bind is refused at runtime. |
| 3 | MINOR: "in parallel" needs a serial qualifier | **accepted.** Review may overlap; dependent units implement serially. |

The reviewer's closing note: the post-run init check is adequate as a
**patch-admission** check; it cannot undo an earlier host action, which is
what the pre-launch flags are for.

Found by the judge during Unit 1's gate, not by the review: the script's
private `umask 077` also governed `git apply` into the real worktree, so
rewritten files landed as 0600/0700 and the Cursor package inventory check
failed. The script now applies under `umask 022`, a selftest case asserts an
applied file is 0644, and the eleven affected files in the unit worktree
were restored to the modes git records (no content change).

Found during Unit 3: `git diff --no-index` names a **new** file `work/X` on
both sides of its header (and a deleted file `pristine/X` on both), which the
script's header normalisation did not handle, so `git apply --check` refused
the patch and left the worktree untouched. The normalisation now strips
either prefix; a selftest case applies a new executable file and a deletion
(32/32). Unit 3's retained copy was re-diffed and applied.

