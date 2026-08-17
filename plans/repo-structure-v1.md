# repo-structure-v1

**Status: ACCEPTED** at Codex review round 6 (2026-08-17, gpt-5.6-sol / xhigh /
fast, one thread). Six rounds; findings 11 → 10 → 10 → 6 → 8 → 3, ending with
two MINOR scope/test-list omissions and one NIT, all folded in below.

Round 5's two BLOCKERs were the last substantive ones. All accepted. Both BLOCKERs were real
holes in D4a: `~/.config` is **not** automatically outside the sandbox's writable
roots (a repo rooted at `$HOME`, or a `HOME` under `/tmp`, puts the state inside
them), and the selection rule could fall back from a crashed dispatch's
`running` record to an older `ready` one and resume a **live** session.
Dispositions in §8 (round 2), §9 (round 3), §10 (round 4), §11 (round 5).
Where an older disposition row conflicts with a newer one, the newer supersedes.

Follow-on to `plans/multi-backend-v1.md`, which shipped three implementer
backends (codex, grok, cursor-agent) but left two things unfinished: the codex
adapter still depends on a Claude Code plugin, and the repo layout still
expresses "one host, one backend" while the content is now "many hosts, many
backends".

- **Phase A** — move the codex backend off `codex-companion.mjs` onto plain
  `codex exec`.
- **Phase B** — restructure the loop skill into per-backend modules, move the
  gate's tests to a single home, and generate the Cursor package instead of
  hand-mirroring it.

Phase A comes first on purpose: the companion is the only reason the three
backends are not already the same shape, and Phase B's premise is a uniform
backend module. Restructuring first would bake the asymmetry into the layout.

---

## 1. Problem — measured, not asserted

### P1. One of three backends is locked to Claude Code

`codex-dispatch.sh` ends in `exec node "$COMPANION" …`, where `$COMPANION` is
`codex-companion.mjs` — a file that ships inside the third-party `openai-codex`
**Claude Code plugin** and is discovered through `claude plugin list` and
`~/.claude/plugins/{cache,marketplaces}` paths. Locally no standalone package
exists; whether one exists globally was not verifiable offline and the plan does
not depend on the answer.

The other two adapters have zero Claude coupling: `grep -n 'CLAUDE_'` over
`grok-dispatch.sh`, `grok-verify-worktree.sh`, and `cursor-dispatch.sh` returns
no hits. The loop's host-neutrality is two-thirds true.

### P2. The companion imposes a maintenance tax we have already paid once

Companion 1.0.6 rejects `ultra` and `max` as `--effort` flag values. Because the
adapter cannot forward them, `codex-dispatch.sh` carries a `tomllib`
config-parsing block that *asserts* the user's config already contains the
requested effort and fails closed otherwise; `references/runtime-codex.md`
carries a paragraph explaining the assertion's layering rules. Verified: the
installed CLI parses `codex exec -c model_reasoning_effort=max` and the selected
model catalog supports both levels. The assertion machinery exists only to work
around a third-party artifact we neither control nor version-pin.

### P3. The sandbox is config-inherited, and the local config is wide open

The calibrated host's `~/.codex/config.toml` contains
`sandbox_mode = "danger-full-access"` and `approval_policy = "never"`. A
`codex exec` invocation that omits `-s` inherits that: no sandbox, no boundary,
and no warning beyond one banner field. This is the single most important
constraint on Phase A — not a reason to keep the companion, but the reason the
replacement must pin the mode on every path and print what it asked for.

### P4. One measured boundary instance — what it does and does not establish

**Measured 2026-08-17**, macOS 25.5.0 / arm64, `codex-cli 0.147.0` reached
through `/Users/olddonkey/.local/bin/codex`, which is an **OpenCodex shim** that
re-execs `codex.opencodex-real`. Version alone does not identify the launch
mechanism, so the resolved executable path is part of the observation.

Probe under `codex exec -s workspace-write` on a throwaway repo (control run
outside any sandbox first: 9/9 ALLOW, so the probe discriminates):

| probe | `-s workspace-write` | `-s read-only` |
| --- | --- | --- |
| write tracked file in repo | ALLOW | DENY |
| write new file in repo | ALLOW | — |
| write `.git/probe` | **DENY** | DENY |
| write `.git/index.lock` | **DENY** | — |
| read `.git/HEAD` | ALLOW | — |
| `git status` | ALLOW | — |
| `git commit -am` | **DENY** (commit count unchanged) | — |
| write `$HOME/…` | DENY | — |
| network (`curl`) | DENY | — |

Post-run tree under `workspace-write`: `M file.txt`, `?? newfile.txt`, one
commit. That is the loop's contract — `.git` readable so `git status` works,
unwritable so the implementer cannot commit, changes left for the orchestrator.
Banner fields observed: `approval: never`, `sandbox: workspace-write [workdir,
/tmp, $TMPDIR]` and `sandbox: read-only` respectively.

**What this does NOT establish** (round-1 finding 2, accepted in full). The
probe is one point sample of the shell-command policy. It does not cover:
linked-worktree or submodule `.git` marker files and their resolved
git-dir/common-dir; refs, objects, packed-refs, worktree metadata; symlink and
hard-link aliases; rename and atomic-replace paths; parent/sibling/extra
writable roots or a symlinked workspace; raw TCP with positive and negative
controls; resumed turns as opposed to fresh ones; or config variants for
`sandbox_workspace_write.writable_roots`, `network_access`,
`sandbox_permissions`, approval escalation, and hook trust.

The safety claim is therefore stated **tuple- and config-bound**: what was
measured holds for (OS, kernel, arch, resolved codex executable + hash, CLI
version, adapter version, effective-policy fingerprint), and nothing here claims
more. Unlike grok — whose boundary we construct and therefore gate per tuple at
runtime — codex's boundary is the vendor's own and is what the shipped companion
already relies on. D10 defines the evidence matrix and explains why this is
release evidence rather than a runtime allowlist. There is no runtime tuple
gate; D2a is a post-start tripwire, not a substitute for one.

### P5. The sandbox does not bound MCP servers, Apps, hooks, or `notify`

`codex-dispatch.sh` already scans the Codex config's `mcp_servers` and `apps`
families and prints a `warn` line, precisely because those tool calls execute in
the agent process rather than the sandboxed child shell. On the calibrated host
that warning is live on every dispatch:

```
warn  : external tools outside the sandbox: mcp_servers.node_repl,
        mcp_servers.openaiDeveloperDocs, mcp_servers.fastmail,
        mcp_servers.unclebg, apps.connector_5f3c…
```

The scan, its `CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1` refusal mode, and its
warn-not-stop posture are **preserved verbatim** by Phase A. `codex exec` also
exposes `--ignore-rules` and `--dangerously-bypass-hook-trust`, so exec-policy
rules and hook trust join the list of things the adapter must never relax.

**The scan is narrower than the exposure, and this plan does not close the gap
— it states it.** Round-2 finding 9: the scanner reads only `mcp_servers` and
`apps`, while the calibrated host's config also carries a live
`notify = ["…/SkyComputerUseClient", "turn-ended"]` hook and **15 enabled
`[plugins.*]` entries** (counted, not estimated — the previous draft said three).
The scan discloses whatever is enabled at dispatch time rather than a fixed
list, so the count is illustrative of the exposure, not a constant. Denying
`--dangerously-bypass-hook-trust` prevents *granting* trust in this invocation;
it does not disable hooks, plugins, or `notify` that are **already** trusted.

Phase A therefore extends the scan's disclosure to `notify` and `plugins` —
cheap, same mechanism, same warn-not-stop posture — and the plan declares
plainly that MCP servers, Apps, hooks, plugins, and `notify` are **accepted
host-side side-effect channels outside the sandbox boundary**, not things the
boundary covers. They are added to D10's effective-policy fingerprint so a
tuple's evidence records what was enabled when it was measured.

### P6. 1869 lines of duplication policed by CI `diff -q`

`cursor-implementation-loop/` is 3547 lines of Markdown and Bash; **1869
(52.7%)** are byte-locked copies of files under `skills/` — `run-gate.sh` (494),
`tree-oid-selftest.sh` (771), `tree-oid.sh` (375), `verification-contract.md`
(67), `handoff.md` (31), six playbooks (131). CI enforces 11 `diff -q` pairs and
`AGENTS.md` instructs contributors to "mirror the other in the same commit" —
a build step implemented as a human obligation with a tripwire.

### P7. The gate's test suite exists twice, and only one copy is protected

`cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh`
(668 lines, 122 checks) declares its own provenance: "gate section **extracted
verbatim** from the implementation-loop selftest; dispatch checks dropped". So
`run-gate.sh` is covered by two suites: 60 `$GATE` assertions inside
`skills/implementation-loop/scripts/selftest.sh` (1356 lines, 37 `$DISPATCH`
uses) and the 668-line extraction. **`gate-selftest.sh` is not in the byte-lock
set** — only `run-gate.sh` is. The tails are byte-identical today; nothing keeps
them that way. This is a live defect, not an aesthetic complaint.

### P8. Module boundaries are not expressed by the layout

`selftest.sh` is the codex backend's selftest under a generic name and also
holds the gate's tests. A backend is three or four files scattered across two
directories. `references/dispatch-contract.md` describes an interface every
adapter must implement, and nothing verifies that they do.

---

## 2. Non-goals

- **No change to plugin ids or marketplace `source` paths.** The D8 rename
  merged 2026-08-16 PDT (`9d8861a`); a second round of user-visible churn is not
  acceptable. `.claude-plugin/marketplace.json` keeps pointing at `./skills/…`.
- **No top-level `core/` + `hosts/` split.** A Claude Code plugin installs one
  directory, so everything the installed skill needs must live inside
  `skills/implementation-loop/`.
- **No shared Bash library for the adapters.** Their arg loops are 13/16/20
  lines (verified) and their mechanisms encode three different security models.
  The shared surface is the contract and its conformance suites.
- **No unification of the two hosts' doctrine.** The Cursor port's implementer
  is a native subagent with no hard sandbox; generation must carry
  host-specific deltas, not erase them.
- **No behavior change to grok or cursor-agent.** Their files move; their logic
  does not.

---

## 3. Design decisions

### D1. `codex exec`, not the companion — with an honest parity ledger

Round-1 finding 3 refuted the earlier claim that the companion "sets the sandbox
and nothing more". It does more. Full ledger:

| companion capability | replacement under `codex exec` |
| --- | --- |
| `sandbox: write ? workspace-write : read-only` | `-s workspace-write` / `-s read-only`, pinned (D2) |
| hardcoded `approvalPolicy: "never"` | `-c approval_policy=never`, pinned (D2) — **`codex exec` has no `-a`/`--ask-for-approval` flag** |
| persistent named threads, loop-specific name prefix | native session ids, captured per dispatch (D4) |
| resumable-thread filtering by cwd + `sourceKinds: ["appServer"]` + name prefix | exact session id recorded by the adapter (D4) |
| rendered final result on stdout | `-o <file>` for the final message, re-emitted by the adapter on stdout (D5a) |
| progress / reasoning / touched-files capture | **observability regression, accepted** — the human-readable transcript is kept as `transcript.log`, but the structured JSONL event stream is given up, because `--json` suppresses the policy banner D2a needs (§6). Session ids are parsed from the banner instead of read from `thread.started` |
| detached-job lifecycle: `--background`, `status --all`, `cancel` | **dropped** — see below |
| job registry surviving session death | **regression, accepted** — D8 |

The dropped capability is detached-job lifecycle. Two facts make it not worth a
second code path:

1. **The skill already forbids the feature.** `SKILL.md` hygiene list:
   "**Background at the harness level**; the companion's own `--background`
   detaches and can outlive a failed-looking launch."
2. **`references/dispatch-contract.md` already blesses its absence:** "A
   dispatch script without a companion runs strictly foreground, its own exit is
   the authoritative completion signal, and backgrounding happens at the harness
   level." grok and cursor shipped on exactly those terms.

*Alternative considered and rejected:* keep the companion when present and
`--background` is requested. Rejected because a dual path doubles the code and
selftest surface of the one adapter Phase B is trying to make uniform, keeps a
third-party dependency alive in the docs, and preserves P2's tax.

### D2. Two calibrated argv builders, both pinned — they are not the same shape

Round-1 finding 1 was correct and the situation is worse than it reported.
Measured flag surfaces on `codex-cli 0.147.0`:

- **`codex exec`** accepts `-s`, `-C`, `-m`, `-c`, `-o`, `--json`,
  `--add-dir`, `--approve-for-me`, `-p/--profile`, `--ignore-user-config`,
  `--ignore-rules`, `--skip-git-repo-check`, `--ephemeral`, both
  `--dangerously-bypass-*`. It does **not** accept `-a`/`--ask-for-approval`, so
  the reviewer's suggested `-s <mode> -a never` is unavailable.
- **`codex exec resume`** accepts `--all --json --last --ephemeral
  --ignore-rules --ignore-user-config --output-schema --skip-git-repo-check
  --strict-config --enable --disable
  --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust
  -c -i -m -o`. It accepts **neither `-s` nor `-C`**
  (`codex exec resume -s read-only` → exit 2, `unexpected argument '-s' found`;
  same for `-C`). Note that both bypass flags and both feature toggles *are*
  present on resume — the guard below is what keeps them out, not their absence.

Therefore:

- **Fresh builder:** `codex exec -s <mode> -c 'approval_policy="never"'
  --strict-config -C <repo> …`
- **Resume builder:** `cd <repo>` first — there is no `-C` — then
  `codex exec resume <SESSION_ID> -c 'sandbox_mode="<mode>"'
  -c 'approval_policy="never"' --strict-config …`

`-c` values are written as **quoted TOML strings**, not bare words. The CLI
documents a fallback that treats unparseable values as literals, and the
calibration in §6 exercised that fallback — but depending on a fallback for a
security-critical value is gratuitous risk. `--strict-config` is passed so an
unrecognized key fails loudly instead of being ignored.

Both builders are produced by one function with a single mode variable, so the
two paths cannot drift. Invariants enforced by selftest on **both** builders:

- exactly one sandbox specification, from the allowed set, on every code path;
- `approval_policy=never` present on every code path;
- neither `--dangerously-bypass-approvals-and-sandbox` nor
  `--dangerously-bypass-hook-trust` can reach argv — a guard refuses if either
  string appears, mirroring the cursor adapter's `--force` ban;
- no policy broadener is ever emitted: `--add-dir`, `--approve-for-me`,
  `-p/--profile`, `--ignore-user-config`, `--ignore-rules`, `--enable`,
  `--disable`;
- the resume builder asserts it changed directory to the recorded workspace
  before exec, because it cannot pass one;
- **stdin is redirected from `/dev/null` on every invocation.** With a prompt
  passed positionally and stdin left open, `codex exec` blocks forever waiting
  to append a `<stdin>` block — observed as a 56-minute hang producing one line
  of output and no error (§6). A hung dispatch is indistinguishable from a
  working one, so this is a selftested invariant, not a convention.

**D2a. Banner verification — fail-closed *detection*, not pre-execution
enforcement.** Round-3 finding 1 was right on all three counts, and a
measurement settles the first one against the previous draft:

**`--json` suppresses the banner entirely.** Measured on 0.147.0:
`codex exec --json -s read-only` emits pure JSONL on stdout
(`thread.started` / `turn.started` / `item.completed` / `turn.completed`) whose
schema carries **no `sandbox` or `approval` field**, and stderr carries no
banner either. `grep sandbox` over both streams returns nothing. The previous
draft required `--json` in D5a and banner parsing in D2a — mutually exclusive.

Consequences, all adopted:

- **The adapter does not pass `--json`.** It runs `codex exec` in its default
  human-readable mode, parses the banner from that stream, and takes the final
  message from `-o`. The full transcript is kept as the run log; the structured
  event stream is given up, because a policy line the adapter can verify is
  worth more than a schema that omits policy entirely.
- **D2a is demoted to post-start detection.** `codex exec` receives the prompt
  at launch and there is no handshake that blocks turn submission on the
  wrapper's acknowledgement. Parsing the banner and killing is therefore a race:
  a mismatched run may have executed some tool calls before the kill lands. D2a
  is described here, and in `runtime-codex.md`, as **fail-closed detection that
  bounds the damage and surfaces the problem loudly** — never as a guarantee
  that nothing ran. The pre-execution protection is the pinned argv in D2; D2a
  catches the case where the pin did not take.
- **A truthful banner proves resolved intent, not kernel enforcement.** Stated
  explicitly rather than implied.
- **The kill is bounded to a process group the adapter creates.** The previous
  draft said "kills the process group" while D8 deferred process-group design to
  v2 — killing the *inherited* group could terminate the calling harness. The
  adapter starts codex in its own session/process group and kills only that.

The summary block prints `sandbox (requested):` and `sandbox (CLI reported):`
as separate lines, so a reader never has to infer which one they are looking at.

**D2b. Nested policy controls — exact argv, not a placeholder.** Round-3
finding 2: "set to the adapter's value or refuse" named neither values nor a
detection mechanism, and `--strict-config` only rejects unknown keys, it does
not reveal effective ones. Both builders therefore pass these explicitly, so
inheritance cannot supply them:

```
-c 'sandbox_workspace_write.writable_roots=[]'
-c 'sandbox_workspace_write.network_access=false'
-c 'sandbox_permissions=[]'
```

Empty `writable_roots` means the workspace defaults only (`[workdir, /tmp,
$TMPDIR]`, as the banner reports); the adapter never adds roots. Because a
`-c` override wins over the config layers beneath it, this pins the values
rather than merely detecting them — which is why it does not depend on
enumerating what the user's layered configuration resolved to.

What this does **not** do is prove the pin beat a managed requirement, which
cannot be synthesized by an ordinary test process. That evidence is conditional
on a genuinely managed host, is labelled as such in D10, and its absence is
recorded rather than papered over.

**Calibration — resolved, and it demonstrates P3 on the resume path.** A session
created with `-s read-only` was resumed twice by exact id in the same workspace:

| resume invocation | banner `sandbox:` | repo write | `.git` write |
| --- | --- | --- | --- |
| `resume <id> -c sandbox_mode=workspace-write` | `workspace-write [workdir, /tmp, $TMPDIR]` | ALLOW | **DENY** |
| `resume <id>` (unpinned) | **`danger-full-access`** | ALLOW | **ALLOW** |

Two conclusions, both load-bearing:

1. `-c sandbox_mode=<mode>` overrides in **both directions** — it beat the
   thread's stored `read-only` (loosening) and the global `danger-full-access`
   (tightening). The resume builder is pinnable, so Unit 1 keeps resume.
2. **An unpinned resume does not inherit the thread's policy at all.** It falls
   through to global config, and on this host that means the boundary silently
   disappears — `.git` becomes writable and the implementer can commit. P3 is
   not a theoretical hazard on the resume path; it is the observed default.

`approval: never` was reported on every run — **but that proves nothing about
the flag**, because the global config already said `never`. This calibration was
non-discriminating for approval (round-2 finding 7), and D10 therefore adds a
config-variant run with a non-`never` `approval_policy` to test the pin against
a config that disagrees with it. Until that runs, the approval pin is a
belt-and-braces measure whose independent effect is unverified, and D2a — which
compares the CLI's reported `approval:` line to the request — is what actually
catches a disagreement.

### D3. Effort becomes a real override

`--effort <level>` maps to `-c model_reasoning_effort=<level>`, forwarded
verbatim for every level including `ultra` and `max`. The `tomllib`
config-assertion block and its `runtime-codex.md` paragraph are deleted, as are
the selftest checks exercising the assertion. The summary reports the effort as
`(explicit)` in all cases. An unsupported level fails at the CLI, which is the
correct authority — unlike the current hardcoded `ultra max` snapshot that
`runtime-codex.md` already flags as liable to age.

### D4. Resume binds an exact loop-owned session id, never `--last`

Round-1 finding 4 accepted. The companion filters resumable threads by cwd,
`sourceKinds: ["appServer"]`, and a loop-specific thread-name prefix. Native
`--last` selects the newest recorded session for the cwd, **including the user's
own interactive Codex work in the same repo** — and "one loop unit in flight"
constrains the loop, not the user. Using `--last` would also contradict the
shipped contract: "Codex and grok use the exact id from the prior dispatch
summary."

- Every fresh dispatch captures the session id the CLI reports and records it in
  the run-state directory alongside the canonical workspace path.
- `--resume` resolves that recorded id and passes it positionally. With no
  recorded id it **fails closed** with an instruction, never falling back to
  `--last`.
- `--resume <SESSION_ID>` requires the id to match a loop record for the same
  canonical workspace. An id with no such record is refused; resuming a
  foreign session is available only as the separately named, explicitly unsafe
  `--resume-unmanaged <SESSION_ID>` used for the companion migration below.

**D4a. The state directory is a security boundary, and must be defined now.**
Round-2 finding 2: the implementer runs with `-s workspace-write`, whose writable
roots are `[workdir, /tmp, $TMPDIR]`. Any state kept inside the repo — including
the git common dir on an ordinary checkout — is therefore **writable by the
thing it is supposed to constrain**, so an implementer could rewrite the session
or workspace record and redirect the next iterate round. Deferring this to v2
(as the previous draft did) is not available.

Codex run state lives at
`~/.config/olddonkey-loop/codex/<workspace-key>/<dispatch-id>/`, where
**`<workspace-key>` is the lowercase hex SHA-256 of the canonical (`pwd -P`)
workspace path** and **`<dispatch-id>` is `<UTC ISO-8601 basic>-<8 hex random>`**,
unique per dispatch.

Unit 1 specifies the full lifecycle, because "deterministic selection" without
one is not implementable (round-3 finding 3):

- **`meta.tsv`** per dispatch, holding `schema=1`, `state`, `generation`,
  `session_id`, `workspace`, `created`, `updated`.
- **`state` ∈ {`initializing`, `running`, `ready`, `failed`}.** Round-4 finding 2
  was correct that promoting on session-id capture is too early: the id appears
  near startup while the turn is still running, so a second dispatch could select
  and resume a **live** session. A record is `initializing` before launch,
  `running` for the whole child lifetime, and promoted to `ready` **only after
  the turn has terminated and its final state is recorded**; otherwise `failed`.
- **Selection is by `generation`, not wall clock**, and **the highest valid
  generation is decisive** — it is never skipped over. Round-5 finding 2 caught
  the hole: if the wrapper dies while its codex child survives, its record stays
  `running`, and a "latest `ready`" rule would happily fall back to the
  *previous* dispatch's `ready` record and resume a live session. So: if the
  highest valid generation is `initializing` or `running`, ordinary dispatch and
  resume both **refuse**, naming that record. Falling back to an older `ready`
  is never correct. Wall-clock `updated` is retained for humans, never for
  ordering — it is ambiguous under equal timestamps and wrong under a backward
  clock adjustment.
- **`generation` is `1 + max(valid generation)` computed from the authoritative
  scan under the lock**, not from a separate counter file that would need its own
  bootstrap and crash recovery.
- **The workspace lock is a non-blocking descriptor lock held across the whole
  critical section** — selection, the transition to `running`, child execution,
  and the final transition — which also mechanically enforces the loop's "one
  unit in flight" rule per workspace. Round-5 finding 3: `flock(1)` is **not on
  PATH** on the calibrated macOS host, so the lock is taken by a supervising
  `python3` process using `fcntl.flock(LOCK_EX|LOCK_NB)`. Acquisition is
  non-blocking and fails immediately with the holding dispatch id rather than
  waiting — a blocking lock would hang behind an overnight run and look like a
  working job. The descriptor is close-on-exec so an escaped descendant cannot
  keep it held, and the lock file's *contents* are advisory only: a stale file is
  ignored once the descriptor lock is successfully acquired, because the kernel
  releases the lock on holder death.
- **`<workspace-key>/current` is a validated cache, not the authority.** The
  authority is a scan of the records under the lock. `current` is rewritten by
  temp-file plus rename after a promotion; if it disagrees with the scan — the
  crash-between-promote-and-pointer case — the scan wins and `current` is
  repaired.
- **Secure bootstrap.** `~/.config/olddonkey-loop/` and `<workspace-key>/` are
  created with `0700` before `.lock` can exist; each path component's ownership
  and mode are verified on every use; `.lock` is opened `O_NOFOLLOW` so a
  planted symlink cannot redirect it. Bootstrap failure refuses the dispatch.
- **Containment check — `~/.config` is not automatically outside the sandbox.**
  Round-5 finding 1, and it defeats the whole premise where it applies: the
  writable roots are `[workdir, /tmp, $TMPDIR]`, so a repository rooted at
  `$HOME` puts `~/.config/olddonkey-loop` **inside `workdir`**, and a `HOME`
  under `/tmp` (containers, CI, test harnesses) puts it inside `/tmp`. In both
  cases the implementer could rewrite the state that constrains it.

  Before launch the adapter canonicalizes (`realpath`) the state root and every
  writable root and **refuses the dispatch if any writable root contains the
  state root, the state root contains a writable root, or the two are equal.**
  Negative tests cover `workspace=$HOME`, `HOME` under `/tmp`, and symlink
  aliases that only collide after canonicalization.
- Directories `0700`, regular files `0600`, owner verified on every read,
  symlinks and hard links refused anywhere on the resolved path, and fail-closed
  parsing — a malformed, foreign-owned, or unreadable record refuses the
  dispatch rather than falling back.
- **Whole-file atomic replacement applies to the authoritative state files
  only** — `meta.tsv` and `current`. `transcript.log` is append-only,
  non-authoritative evidence that must survive a crash *partially written*,
  which is the point of keeping it (round-5 finding 8; the previous "all writes
  atomic" contradicted D5a's live teeing).
- **`--resume-unmanaged <ID>` adopts on success**: after the resumed turn
  completes, a `ready` record is written for that session and workspace, so the
  next ordinary `--resume` works. Without adoption the migration path would
  strand the user one command later.

**Scope of the guarantee, stated rather than implied** (round-3 finding 3):
this protects state from the **sandboxed shell**, which is the channel `-s
workspace-write` bounds. It does **not** protect against the same-UID host-side
channels P5 accepts — MCP servers, Apps, plugins, hooks, and `notify` all run
in the agent process and can reach `~/.config`. The risk table says so.
- **Migration:** companion-created app-server threads predate the run-state
  record. Unit 1 ships a migration smoke that resumes a companion-created thread
  by exact id, and the release note instructs users to finish or cancel
  in-flight companion jobs before upgrading — a mid-unit upgrade could otherwise
  route the next iterate round to a different session while the old registry
  still shows a job running.

### D5. A backend is a directory with a fixed shape, plus an explicit manifest

```
skills/implementation-loop/
  SKILL.md
  references/           dials.md gate.md unit-contract.md review-checklist.md
                        dispatch-prompt.md dispatch-contract.md
                        running-anywhere.md            # NEW
  scripts/run-gate.sh                                   # shared, backend-neutral
  backends/
    backends.tsv                                        # NEW — the manifest
    codex/    dispatch.sh runtime.md selftest.sh
    grok/     dispatch.sh runtime.md selftest.sh verify-worktree.sh
    cursor/   dispatch.sh runtime.md selftest.sh
  tests/
    gate-selftest.sh          # the gate's ONLY suite
    contract-core.sh          # NEW — shared battery (D6)
    contract-negative.sh      # NEW — negative controls (D6)
    integration-test.sh       # real-backend opt-in gate, gains codex (D10)
```

`backends/backends.tsv` is the single source of truth resolving round-1 finding
7's "enumerate the directory vs. register in a list" contradiction: the
directory is discovered, then **cross-checked against the manifest**, and a
mismatch in either direction is a failure.

Grammar, validated before use (round-2 finding 8): a `#schema=1` first line;
tab-separated; exactly seven columns — `name`, `cli`, `env_namespace`,
`resume` ∈ {`exact-id`,`refuses`}, `effort` ∈ {`flag`,`embedded-in-model`},
`output_schema`, `fixture_driver`; `name` matching `[a-z][a-z0-9-]*` and unique;
`fixture_driver` a repo-relative path with no `..` segment, existing and
executable. Any violation fails the suites rather than being skipped.

Column value rules (round-3 finding 7): `cli` matches `[A-Za-z_][A-Za-z0-9_.-]*` (an executable name). **`env_namespace`
is validated separately as `[A-Z][A-Z0-9_]*_LOOP_`** and is unique — the previous
grammar admitted `bad-name_LOOP_`, which cannot be a Bash variable prefix
(round-4 finding 5). `output_schema` ∈ {`json`,`text`}.

`fixture_driver` is round-2 finding 8's missing piece: PATH stubs alone cannot
prepare grok's protected tuple and worktree state or cursor's isolated-copy
prerequisites. Round-3 finding 7 then showed the proposed `setup`/`stub_path`/
`teardown` shape cannot work: a child `setup` process cannot export environment
into its caller, and grok's existing fixtures need per-case `HOME`, `PATH`, stub
logs, and several `GROK_*` variables (`grok-selftest.sh:240`).

The driver is therefore an **execution wrapper**, not a setup hook:

```
backends/<name>/fixture-driver.sh run <tmpdir> <case> <adapter> -- <args…>
```

It establishes the environment in its own process and `exec`s the adapter, so no
environment has to cross a process boundary. `contract-core.sh` and
`contract-negative.sh` invoke every backend exclusively through this one entry
point, which is also what lets the negative controls run against real adapters
rather than only against stubs.

**D5a. The output contract — scoped to codex only.** Round-2 finding 3 was
correct: the previous draft's stdout/stderr split would have silently changed
grok and cursor, which today print their summary and final text on **stdout**
(`grok-dispatch.sh:1184`, `cursor-dispatch.sh:458`), contradicting the
"no behavior change to grok or cursor-agent" non-goal. Unifying the three
backends' output channels is a real question but a **separate decision**, not a
side effect of this refactor.

So D5a governs `backends/codex/dispatch.sh` only, and preserves the **actual**
current channels. Round-3 finding 4 caught the previous draft misstating them in
the opposite direction: `codex-dispatch.sh` writes its entire summary to
**stderr** (`>&2` at `codex-dispatch.sh:507` and following — workspace, version,
model, effort, tier, mode, resume), and only the companion's final result
reaches stdout. Since D9's shims exist to preserve compatibility, silently
moving a channel would defeat their purpose.

- **stdout** — the implementer's final message, exactly once, and nothing else.
- **stderr** — summary block, warn lines, progress, and the banner D2a parses.
- **run state** — `<state-dir>/{prompt.txt,transcript.log,last-message.txt,meta.tsv}`.
- **capture algorithm** — the adapter runs codex without `--json` (D2a), tees the
  human-readable stream to `transcript.log` while scanning it for the banner and
  the session id, and takes the final message from
  `-o <state-dir>/last-message.txt`. If `-o` is absent or empty, if the banner
  never appears, or if the stream ends mid-turn, the adapter **fails closed**
  with a non-zero exit and preserves `transcript.log` — it never reports an
  empty result as success.
- **exit status** — the CLI's real exit code propagates unmodified; a
  signal-terminated child is reported as `128+signo`, never as 0.

Both descriptors are tested independently, including empty/missing `-o`, an
absent banner, a truncated stream, non-zero exit, and signal termination.

### D6. The contract gets three suites, not one battery

Round-1 finding 7 accepted: a single no-special-casing battery can only test an
argument-parser subset, because the contract deliberately has divergent resume
and effort semantics.

1. **`contract-core.sh`** — genuinely shared rules, run against every backend.
   The battery encodes **existing** behavior; it is a conformance test, not a
   behavior change smuggled in as one (round-2 finding 8): `-h` exits 0 and
   names the contract flags; `--prompt-file` and `--prompt` both accepted, with
   **`--prompt-file` taking precedence when both are given** — the precedence
   all three adapters already implement, rather than the rejection the previous
   draft would have required them to adopt; neither supplied fails closed; a
   prompt beginning with `--` is never parsed as a flag; missing flag values
   rejected; repeated flags resolve last-wins; unknown flags fail closed;
   `--read-only` / `--investigate` synonymous; `--background` rejected with a
   non-zero exit (open question 2); real exit and signal status propagate; env
   overrides confined to the declared namespace.

   **Frozen summary fields**, enumerated here so "the contract's field names" is
   not a forward reference to nothing: `workspace`, `<cli> version`, `model`
   (with provenance), `effort` (with provenance), `mode`, `resume`, and
   `session id` **where the backend's runtime reports one** — required by the
   shipped contract (`dispatch-contract.md:7`) and omitted from the previous
   draft's list (round-3 finding 7). Codex additionally emits
   `sandbox (requested)` / `sandbox (CLI reported)`. A backend may add fields;
   it may not rename or omit these.
2. **Per-backend semantic suites** (`backends/*/selftest.sh`) — capability
   behavior the manifest declares: exact-id resume for codex/grok, hard refusal
   for cursor; effort as flag vs. embedded assertion; session-id capture; model
   forwarding; backend-specific stub argv and output schema.
3. **`contract-negative.sh`** — one deliberately broken stub adapter **per
   shared rule**, each of which `contract-core.sh` must reject. Without this a
   vacuous or skipped assertion makes the harness green (open question 4).

All three run against PATH stubs, make no API calls, need no network, and run in
CI. Stated plainly in the file header: **a stub cannot show that a real CLI's
sandbox enforces anything.** That remains D10's job.

### D7. Generation with a manifest — no per-file headers

Round-1 finding 5 was correct and the previous draft was internally impossible:
"every generated file carries a header" and "every byte-locked pair stays
identical" cannot both hold, `plugin.json` cannot carry a comment, and a line
before a shebang breaks execution while a line after it breaks byte identity.

- **Copied bytes stay exact.** No headers are injected into generated files.
- Provenance lives in a generated `cursor-implementation-loop/GENERATED.md` plus
  a machine-readable `build-manifest.tsv` mapping every output path to its
  ordered source(s), file mode, and transform. `AGENTS.md` points edits at the
  manifest and the source tree.
- **Authoritative host-only inputs live outside the generated tree** —
  `hosts/cursor/` at the repo root — so the build is not circular.
- **Build contract** (round-1 finding 6): `build.sh` writes into a **new empty
  destination**; sets `LC_ALL=C` and `umask 022`; sorts traversal; assigns file
  modes explicitly (the package has four executable scripts, which `diff -r`
  does not check); refuses symlinks in inputs and emits none; declares every
  input and output and fails on anything undeclared; embeds no timestamps,
  absolute paths, or randomness. `build.sh --check` compares the committed tree
  against a fresh build by **path, type, mode, and content hash** — not
  `diff -r`.
- CI replaces the 11 `diff -q` pairs and the duplicated gate suite with two
  steps: `build.sh --check`, and a determinism step building twice into separate
  destinations. **Both comparisons use an externally computed inventory** of
  path, type, mode, and content `sha256` for every file in each tree — never the
  embedded manifest, which round-2 finding 4 correctly observed records sources
  and modes but not output hashes, so a nondeterministic transform could emit
  different bytes under identical manifests. The manifest is documentation; the
  inventory is the check.
- Generated files stay committed — `install-cursor.sh` git-clones and Claude
  Code marketplaces are git clones, so the tree must be complete on checkout.
- **Plugin version:** `build.sh --check` runs on a single checkout with no
  comparison base, so it cannot know whether generated content changed since the
  previous commit — round-2 finding 4. The gate is therefore a committed,
  machine-readable decision artifact, `hosts/cursor/version-decision.tsv`,
  carrying the content hash of the generated tree the decision was made against
  and one of `bump=<version>` or `keep`. CI fails when the built tree's hash
  differs from the recorded one, which forces the author to record a fresh
  decision rather than requiring CI to fetch a base revision.

*Alternative considered and rejected:* git symlinks instead of copies. Both
installers git-clone, so symlinks would survive on POSIX and the duplication
would vanish with no build at all. Rejected because Windows checkouts without
`core.symlinks` materialize them as plain text files containing a path — a
silently broken plugin on a platform Claude Code supports — and because no
installed plugin in the calibrated environment contains a single symlink
(`find ~/.claude/plugins -type l` → 0), so both host loaders' symlink handling is
untested. Neither the Windows behavior nor the loader behavior was verifiable
offline; generation avoids needing either answer.

### D8. Unit 1 accepts a recovery regression; unification is v2

Round-1 finding 11 accepted, including the misreference (D1 previously pointed
at D7). Stated plainly: **Unit 1 gives up cross-session recovery of an orphaned
codex run and does not replace it.** The doctrine already forbids the
`--background` path that capability served, so the loss is bounded to "a session
died mid-dispatch and you want to find the job afterwards".

v2 is a **unification and index over state that already exists**, not a
greenfield four-file directory: `grok-dispatch.sh` already keeps
`$COMMON_DIR/olddonkey-loop/grok/<id>/` with a writable ledger, baseline, and
crash journal; `cursor-dispatch.sh` already records `prompt.txt` (mode 600) and
`output.json`. Required design work for v2, recorded so it is not rediscovered:
ownership and modes, atomicity and locking, PID reuse and process groups,
retention, prompt/log sensitivity, and crash reconciliation.

### D9. One release of forwarding shims at the old paths

Round-1 finding 9 and open question 1. The old script paths are executable
public interfaces embedded in SKILL examples and plausibly in external harnesses,
and a marketplace update mid-session can leave already-loaded instructions
pointing at removed files. The D8 rename is not a precedent: it was explicitly
breaking, shipped uninstall/reinstall instructions, and preserved legacy
calibration records.

Unit 2 therefore ships wrappers at **every moved shipped executable** — round-2
finding 5 caught the previous draft scoping this to "dispatch/selftest" and
thereby omitting two that `AGENTS.md:16` lists as shipped and that the docs
reference directly:

| old path (`skills/implementation-loop/scripts/…`) | forwards to |
| --- | --- |
| `codex-dispatch.sh` | `backends/codex/dispatch.sh` |
| `grok-dispatch.sh` | `backends/grok/dispatch.sh` |
| `cursor-dispatch.sh` | `backends/cursor/dispatch.sh` |
| `grok-verify-worktree.sh` | `backends/grok/verify-worktree.sh` |
| `grok-selftest.sh` | `backends/grok/selftest.sh` |
| `cursor-selftest.sh` | `backends/cursor/selftest.sh` |
| `integration-test.sh` | `tests/integration-test.sh` — **with one argv translation, see below** |
| `selftest.sh` | **composite** — see below |

**The one intentional argv exception.** Today `integration-test.sh --backend all`
means grok plus cursor (`integration-test.sh:18`). D10 adds codex, so a shim that
forwarded `all` verbatim would silently turn a legacy invocation into an
additional authenticated, billable Codex run — round-3 finding 6.

The new test therefore makes **`--backend` repeatable**, accepting
`grok|cursor|codex` per occurrence plus `all` meaning all three, and the shim
translates legacy `all` into **`--backend grok --backend cursor`** — two
occurrences, not the single token `grok,cursor`, which round-4 finding 4 correctly
noted is outside the accepted value set and would be rejected.

**The zero-argument case needs the same translation.** Round-5 finding 6: the
current script initializes `BACKEND="all"` (`integration-test.sh:14`), so running
it with **no arguments at all** means grok plus cursor today. A shim that
translated only an explicit `--backend all` would let the bare legacy invocation
pick up a billable codex run. The shim therefore injects
`--backend grok --backend cursor` whenever **no backend selector is present**, and
both cases — zero arguments and explicit `all` — are tested.

The shim prints a second stderr line whenever it translates. This is the only
token any shim does not pass through unchanged, and it is documented in both the
shim and the release note.

`selftest.sh` is not a codex-only suite: its own header declares it covers
"codex-dispatch.sh and run-gate.sh", and it holds 37 `$DISPATCH` and 60 `$GATE`
assertions. Forwarding it to `backends/codex/selftest.sh` alone would silently
drop half its coverage while still exiting 0. Its shim therefore runs
**both** `backends/codex/selftest.sh` and `tests/gate-selftest.sh` and fails if
either fails.

Every shim preserves argv and exit/signal behavior, emits exactly one
deprecation line to stderr naming the removal release, and is covered by a
selftest asserting argv passthrough, stderr content, exit code, and signal
propagation. They are removed in a later, separately announced release.

### D10. Codex joins the real-backend integration gate — as release evidence, not a runtime gate

Round-2 finding 1 is correct that the previous draft used `multi-backend-v1`'s
language ("not approved") without its mechanism. grok's tuple allowlist is a
protected, machine-readable record the adapter reads on **every dispatch**,
refusing when unmatched. D10 as written recorded provenance and enforced nothing,
so the wording promised a guarantee the design did not deliver.

The resolution is to correct the wording, not to build a tuple allowlist, and the
reason is a real asymmetry with grok:

- **grok's boundary is ours.** We construct it from a custom sandbox profile plus
  linked-worktree placement. It can silently fail to hold on an untested
  platform, so a per-tuple runtime gate is load-bearing.
- **codex's boundary is the vendor's.** `-s workspace-write` is Codex's own
  sandbox, and it is exactly what the shipped companion already relies on today.
  A tuple allowlist would impose a **new** guarantee that the current shipped
  adapter does not provide — scope creep justified by a symmetry that does not
  exist.

What protects a run at launch is D2 + D2b — the pinned argv, applied before the
process starts. **D2a is not a second enforcement layer**; it is a best-effort
post-start tripwire that turns a mispinned run into a loud non-zero failure
instead of a silent one. It cannot undo tool calls already initiated, MCP or App
actions already dispatched, or descendants that escaped the adapter's process
group. Nothing in this plan should be read as claiming otherwise.

So: `tests/integration-test.sh` gains a `codex` backend running the matrix P4
lists as untested — linked-worktree and submodule marker files with resolved
git-dir/common-dir, refs/objects/packed-refs, symlink and hard-link aliases,
rename and atomic replacement, extra and sibling writable roots, a symlinked
workspace, raw TCP with positive and negative controls, **both fresh and resumed
turns**, and **config-variant runs** covering
`sandbox_workspace_write.writable_roots`, `network_access`,
`sandbox_permissions`, a non-`never` `approval_policy` (so the approval pin is
tested discriminatingly rather than against a config that already agreed), and
user/project/profile/managed layering. It records OS, kernel, arch, the full
launcher chain with terminal executable hash, CLI version, adapter version, and
the effective-policy fingerprint.

Its status is stated plainly: **release evidence for a documented tuple, not a
runtime approval gate.** `references/runtime-codex.md` names the tuples it has
been run on. CI continues to run only `bash -n` on this script.

**D10a. A skip is not a pass — the gate needs a required mode.** Round-4 finding
3: the existing harness reports unavailable backends as skips and exits 0 when
nothing failed, so `--backend codex` could print `PASS (0 ok, N skipped)` and
satisfy a naive reading of "the matrix passed". Since Unit 1 gates resume on that
result, the condition has to be mechanically decidable.

`integration-test.sh --require codex` therefore fails unless **every non-managed
codex case executed**: exactly one result per applicable case id, zero skips,
zero failures, every positive control passed, every negative control denied, and
the provenance record (OS, kernel, arch, launcher chain, terminal executable
hash, CLI and adapter versions, effective-policy fingerprint) was written.
Missing managed-host layering is the **only** permitted conditional skip, and it
is reported on its own line rather than folded into the total.

**The expected set comes from a frozen manifest, not from what ran.** Round-5
finding 4: D10 lists categories, and a category like "refs/objects/packed-refs"
expands to an arbitrary number of checks, so an implementation could derive
"expected" from the cases that happened to execute — a circular test that passes
by construction. `codex-cases.tsv` therefore freezes a versioned manifest
with a unique id per case, its applicability, and its expected outcome, with the
managed-layer case as the single `managed-only` row. The expected count is
computed from that manifest **before** availability is probed.

**Selector composition** (round-5 finding 5): backend selectors form a
deduplicated set; `--require codex` implies selecting codex; the zero-skip and
exact-count requirements are **scoped to codex only**, so selected grok/cursor
backends keep ordinary skip semantics and an unavailable grok does not
invalidate a codex-required run. Any actual backend *failure* still fails the
run.

Unit 1 enables resume only on a `--require codex` pass. Anything else — including
a plain `PASS` with skips — ships the adapter with `--resume` hard-refusing.

---

## 4. Units

### Unit 1 — codex backend on `codex exec`

**Scope:** `scripts/codex-dispatch.sh`, `references/runtime-codex.md`,
`scripts/selftest.sh`, `SKILL.md` (dispatch examples, the `--background` hygiene
bullet, the "never call the companion yourself" paragraph),
`references/dispatch-contract.md`, `AGENTS.md`, **and the public claims round-1
finding 8 found outside the previous scope**: `README.md` lines 39/113/179/202,
the four Chinese equivalents, `skills/engineering-mode/SKILL.md` frontmatter
(`Requires … the Codex companion plugin`), and both descriptions in
`.claude-plugin/marketplace.json`.

Implements **D1, D2, D2a, D2b, D3, D4, D4a, and the codex-scoped D5a**, and
**extends** P5's external-tools scan to `notify` and `plugins` while preserving
its refusal mode and warn-not-stop posture. It also adds the codex backend to
the **existing** `scripts/integration-test.sh` together with its frozen case
manifest `scripts/codex-cases.tsv` and the `--require` mode (Unit 2 then moves
both files mechanically) — round-3 finding 5: leaving D10 in Unit 2 would let Unit 1 ship a
replaced boundary before any of its release evidence exists. No files move.

**Resume ships in Unit 1 only on a `integration-test.sh --require codex` pass
(D10a).**
Round-3 finding 2 is right that D2a — now demoted to post-start detection — is
not an adequate substitute for that evidence. If the matrix does not pass,
`--resume` fails closed with the fresh-dispatch iterate instruction, exactly as
`cursor-dispatch.sh --resume` already does, and resume lands in a later unit.

**Acceptance:**
- All suites green at a **reported** count (assertion checks deleted, `-s` /
  approval / bypass-guard checks added — the net is measured, not predicted).
- `rg --hidden` proves no live companion dependency remains outside `plans/`,
  `docs/`, and the explicit migration note.
- **Live acceptance smoke run by the orchestrator, not the implementer**: a real
  implement dispatch confirming repo writes land while `.git` writes and
  `git commit` are denied; a resume round proving the resume builder's sandbox
  pin; and the D4 migration smoke resuming a companion-created thread by id
  under `--resume-unmanaged`, then an ordinary `--resume` proving adoption. A
  refactor of a security boundary is not accepted on selftests alone.
- **Negative acceptance, stubbed** (round-3 finding 5): a banner reporting a mode
  other than the requested one must produce a non-zero exit and a killed child;
  an absent banner must fail closed; a tampered, foreign-owned, or symlinked
  state record must refuse the dispatch; `--resume` with no `ready` record must
  fail closed rather than fall back to `--last`.
- **A wrapper-crash test**: kill the adapter while leaving its codex child
  alive, then prove the next dispatch and the next `--resume` both **refuse**,
  naming the `running` record, rather than falling back to the previous
  dispatch's `ready` one.
- **D10's config-variant runs**, including the non-`never` `approval_policy`
  case, executed here rather than deferred.

### Unit 2 — backend modules, manifest, and contract suites

**Scope:** the moves in D5, `backends.tsv`, `tests/contract-core.sh`,
`tests/contract-negative.sh`, splitting the 60 gate assertions out of the codex
selftest into `tests/gate-selftest.sh`, D9's shims, `references/running-anywhere.md`,
and every path reference in `SKILL.md`, `references/*.md`,
`.github/workflows/selftest.yml`, `AGENTS.md`, both READMEs, and
`skills/engineering-mode/references/adapter.md:9`.

**Named mechanical edits** (round-1 finding 10, extended by round-2 finding 6) —
the declared exceptions to "moved files are byte-identical", each verified
individually:

1. `integration-test.sh`'s `$SCRIPT_DIR/grok-dispatch.sh` and
   `$SCRIPT_DIR/cursor-dispatch.sh` resolution.
2. The `../scripts/integration-test.sh` links in `runtime-grok.md` and
   `runtime-cursor.md`.
3. **`gate-selftest.sh`'s gate resolver.** The Cursor extraction hardcodes
   `GATE="$SCRIPT_DIR/run-gate.sh"`, which is correct in the Cursor package's
   sibling layout and broken from the canonical `tests/` directory, where
   `run-gate.sh` sits at `../scripts/`. Since the interim byte lock requires the
   two files to be identical, one resolver must work in both layouts: prefer a
   sibling `run-gate.sh`, otherwise `../scripts/run-gate.sh`, otherwise fail
   with a clear message. The suite is run from both locations in CI to prove the
   resolver, not just the byte equality.

**Acceptance:** a pre/post manifest of every file's path, mode, and content hash,
proving exactly the declared set changed. Plus all suites green and
`contract-core.sh` passing for all three backends while `contract-negative.sh`
rejects every broken stub.

**Interim protection:** until Unit 3 lands, the Cursor `gate-selftest.sh` is
added to the CI byte-lock set against the new canonical
`tests/gate-selftest.sh`, so P7's drift hole is closed during Unit 2's window
rather than left open.

### Unit 3 — generate the Cursor package

**Scope:** `build.sh` and `build.sh --check`, `hosts/cursor/` as the
authoritative overlay, `GENERATED.md` + `build-manifest.tsv`, deletion of the
duplicated files as hand-maintained sources, the CI swap from 11 `diff -q` pairs
plus the interim byte lock to `--check` + the determinism step, and `AGENTS.md`.

**Acceptance:** two builds into separate destinations produce **identical
external inventories** (path, type, mode, sha256) — not identical manifests,
which round-2 finding 4 showed is the insufficient check (round-3 finding 8);
`--check` passes against the committed tree by the same inventory comparison;
every previously byte-locked pair is still byte-identical after the build; file
modes match on all four executables; a recorded `bump=<version>` equals the
generated `plugin.json` version; `install-cursor.sh` and
`install-cursor-selftest.sh` pass; the Cursor package's suites report their
existing totals.

---

## 5. Risks

| risk | mitigation |
| --- | --- |
| The port silently loses the sandbox (P3) | D2 + D2b pin mode, approval, and every nested control on both builders and deny broadeners — this is the actual protection, applied before launch; plus Unit 1's live smoke |
| The requested pin loses to config layering or a profile | D2b passes `-c` overrides, which win over the ordinary layers beneath them, and `-p/--profile` is denied outright. **D2a is a tripwire, not a second layer**: it detects a disagreement *after* start and kills, which cannot undo tool calls or MCP actions already initiated |
| The pin loses to a *managed* requirement | **Not proven.** Managed layering cannot be synthesized by an ordinary test process; D10 marks that evidence conditional on a managed host and records its absence |
| `--last` resumes the user's unrelated Codex session | D4: exact recorded id, fail closed, never `--last` |
| The implementer's **shell** rewrites its own session/workspace record | D4a: state outside the sandbox's writable roots, `0700`/`0600`, owner-checked, symlink-refusing, atomic, lifecycle-gated, fail-closed |
| A **host-side** channel (MCP, App, plugin, hook, `notify`) rewrites that record | **Not mitigated.** They run same-UID in the agent process and can reach `~/.config`; D4a bounds the sandboxed shell only |
| Boundary holds on the calibrated tuple only | P4 + D10: the claim is stated tuple-bound and D10 is release evidence. There is **no** runtime tuple gate, by the argument in D10 |
| Losing `--json` costs structured observability | Accepted regression, recorded in D1's ledger: `transcript.log` retains the human stream, session ids come from the banner |
| **MCP, Apps, hooks, plugins, and `notify` execute outside the sandbox** | **Not mitigated — accepted and disclosed.** See P5: these are host-side channels the boundary does not cover. The scan discloses them; denying `--dangerously-bypass-hook-trust` does **not** disable already-trusted hooks, plugin hooks, or `notify` |
| Old script paths break installed users mid-session | D9: one release of argv/exit-preserving shims with a deprecation line |
| A large move breaks a link or `${CLAUDE_SKILL_DIR}` reference | CI dangling-link check extended; pre/post path-mode-hash manifest |
| `build.sh` non-determinism reddens unrelated PRs | D7's contract + the two-build determinism step |
| Generated files get hand-edited | `GENERATED.md` + manifest + `--check` mismatch |
| Second structural churn in one week | Non-goal #1: ids and marketplace source paths unchanged |
| Cross-session recovery lost | D8: stated as an accepted regression, not papered over |

## 6. Calibration results

All measured 2026-08-17 on macOS 25.5.0 / arm64, `codex-cli 0.147.0` reached via
`/Users/olddonkey/.local/bin/codex` (an OpenCodex shim re-execing
`codex.opencodex-real`). No row is inferred.

| question | result |
| --- | --- |
| `codex exec -s workspace-write` boundary | measured — table in P4 |
| `codex exec -s read-only` denies repo writes | **yes** — repo-write DENY, git-dir DENY |
| `codex exec resume` accepts `-s` | **no** — exit 2, `unexpected argument '-s' found` |
| `codex exec resume` accepts `-C` | **no** — exit 2; the adapter must `cd` |
| `codex exec` accepts `-a`/`--ask-for-approval` | **no** — approval only via `-c approval_policy=` |
| `-c sandbox_mode=` overrides the thread's stored policy on resume | **yes** — thread created `-s read-only`, resumed as `workspace-write` |
| `-c sandbox_mode=` overrides global `danger-full-access` on resume | **yes** — banner `workspace-write`, `.git` write DENY |
| unpinned resume inherits the thread's policy | **no** — falls through to global; banner `danger-full-access`, `.git` write **ALLOW** |
| `codex exec` blocks on stdin when a prompt is passed positionally | **yes** — hung 56 min until killed; every invocation needs `< /dev/null` |
| `codex exec --json` still prints the `sandbox:`/`approval:` banner | **no** — stdout is pure JSONL (`thread.started`/`turn.started`/`item.completed`/`turn.completed`), the event schema has no policy fields, and stderr carries no banner; `grep sandbox` over both streams returns nothing |
| the codex adapter's summary goes to stdout | **no** — `codex-dispatch.sh:507`ff write the whole summary with `>&2`; only the final result reaches stdout |
| `integration-test.sh --backend all` includes codex | **no** — today `all` means grok + cursor only |

The stdin-hang row is an operational finding from this calibration, not a design
question, but it is a real failure mode with no error output: the process stays
alive, writes one line (`Reading additional input from stdin...`), and produces
nothing. **The adapter must redirect stdin on every invocation**, and its
selftest must assert that it does — otherwise a dispatch hangs indefinitely and
looks exactly like a long-running job.

## 7. Round-1 disposition

| # | severity | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted, partial remedy** — confirmed `resume` rejects `-s`; also found it rejects `-C`, which the review missed. The suggested `-a never` does not exist on `codex exec`; D2 uses `-c approval_policy=never`. Two calibrated builders + a blocking calibration. |
| 2 | BLOCKER | **accepted in full** — P4 rewritten as one tuple-bound instance with an explicit not-tested list; D10 adds codex to the integration gate with the full matrix and provenance recording. Scope stated honestly: uncalibrated tuple = not approved, rather than promising every OS. |
| 3 | MAJOR | **accepted** — D1 replaced with a parity ledger; D5a defines the stdout/stderr/run-state/exit contract. |
| 4 | BLOCKER | **accepted** — D4: exact recorded session id, fail closed, never `--last`; migration smoke + release note for companion-created threads. |
| 5 | BLOCKER | **accepted** — no per-file headers; `GENERATED.md` + `build-manifest.tsv`. |
| 6 | MAJOR | **accepted** — D7 build contract: fresh destination, `LC_ALL`/`umask`, explicit modes, symlink refusal, declared I/O, path+type+mode+hash comparison, `--check`, plugin-version gate, overlay outside the generated tree. |
| 7 | MAJOR | **accepted** — D6 split into core battery + per-backend semantic suites + negative controls; `backends.tsv` resolves the enumerate-vs-register contradiction. |
| 8 | MAJOR | **accepted** — verified independently; both READMEs, engineering-mode frontmatter, and `marketplace.json` added to Unit 1 with an `rg --hidden` acceptance proof. |
| 9 | MAJOR | **accepted** — D9 shims for one release. |
| 10 | MINOR | **accepted** — named mechanical edits, pre/post manifest, interim byte lock on the Cursor gate suite during Unit 2. |
| 11 | MINOR | **accepted** — D8 reframed as unification over existing grok/cursor state; misreference fixed; regression stated plainly. |

Open questions 1–4 answered per the reviewer's recommendations: shims for one
release; `--background` a hard error immediately; one central cross-backend
`tests/integration-test.sh` gaining codex; negative controls required, one per
shared rule.

## 8. Round-2 disposition

Round 2 confirmed round-1 #5, #8, #11 and the "never `--last`" half of #4 as
fully fixed, and reported the rest as still open.

| # | severity | disposition |
| --- | --- | --- |
| 1 | BLOCKER | *(statements in this row about D2a are **superseded by §10 #1** — D2a was demoted to a post-start tripwire in round 4, and resume is gated by D10a, not by D2a.)* **accepted, resolved by correcting the claim.** The reviewer is right that D10 used `multi-backend-v1`'s "not approved" language with none of its enforcement. Resolved by removing the overclaim, not by building a tuple allowlist: grok's boundary is one we construct (so it needs a per-tuple runtime gate), codex's is the vendor's own and is what the shipped companion already trusts, so a tuple gate would add a guarantee the current adapter does not make. The runtime check that *is* load-bearing is new **D2a** — refuse when the CLI's reported policy differs from the request — which targets the failure §6 actually measured. Argued explicitly in D10 for the reviewer to attack. |
| 2 | BLOCKER | **accepted in full** — new **D4a** defines the codex state schema in Unit 1: outside the sandbox's writable roots (`[workdir, /tmp, $TMPDIR]` makes anything in-repo implementer-writable, including the git common dir), `0700`/`0600`, owner-checked, symlink/hardlink-refusing, atomic writes, locking, `schema=1`, canonical workspace binding, deterministic selection, fail-closed parsing. `--resume <ID>` must match a loop record; foreign sessions only via an explicitly named `--resume-unmanaged`. |
| 3 | MAJOR | **accepted** — verified `grok-dispatch.sh:1184` and `cursor-dispatch.sh:458` both print summary and final text on stdout, so the previous D5a would have silently changed them. D5a is now codex-only and matches current companion behavior; channel unification is named as a separate decision. Capture algorithm, `-o` failure modes, and abnormal-exit behavior specified. |
| 4 | MAJOR | **accepted** — determinism and `--check` now compare an externally computed path/type/mode/sha256 inventory, not the embedded manifest; plugin version gated by a committed `version-decision.tsv` carrying the tree hash, since CI has no comparison base. |
| 5 | MAJOR | **accepted** — shim table enumerates all eight moved executables including `integration-test.sh` and `grok-verify-worktree.sh`; legacy `selftest.sh` becomes a composite running both new suites and failing if either fails. |
| 6 | MAJOR | **accepted** — one byte-identical gate resolver (sibling, else `../scripts/`), added as named mechanical edit #3 and run from both locations in CI. |
| 7 | BLOCKER | *(the clause about resume shipping because D2a refuses mismatches is **superseded by §10 #3** — resume now ships only on a `--require codex` pass.)* **accepted** — `-c` values are now quoted TOML rather than relying on the invalid-TOML fallback; `--strict-config` added; nested `writable_roots` / `network_access` / `sandbox_permissions` pinned or refused; D2a added as the general defense; D10 gains config-variant runs including a **non-`never` `approval_policy`**, since the reviewer is right that the existing calibration was non-discriminating — the global config already said `never`. Resume ships rather than being withheld, because D2a refuses on any mismatch; the reviewer should attack whether that substitution is adequate. |
| 8 | MAJOR | **accepted** — `contract-core.sh` adopts the **existing** `--prompt-file`-wins precedence instead of mandating rejection, so it stays a conformance test rather than a behavior change; frozen summary fields enumerated; `backends.tsv` given a `#schema=1` grammar with validation; `fixture_driver` added as the per-backend setup interface both suites drive through. |
| 9 | MAJOR | **accepted** — the risk row now reads "**not mitigated — accepted and disclosed**"; P5 records the live `notify` executable and three enabled plugins, states that denying `--dangerously-bypass-hook-trust` does not disable already-trusted hooks, extends the disclosure scan to `notify` and `plugins`, and adds them to D10's fingerprint. |
| 10 | MINOR | **accepted** — resume's flag list corrected to the full installed surface (it does carry `--enable`, `--disable`, and both `--dangerously-bypass-*`); the stale "open calibration" risk row replaced. |

## 9. Round-3 disposition

Round 3 confirmed round-2 #1's overclaim fix, #6, #10, and the cores of #4, #5,
#8, #9 as landed. All ten new findings accepted; every factual claim was
re-verified against the repo or the installed CLI before revising.

| # | severity | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted, settled by measurement.** Ran `codex exec --json -s read-only`: stdout is pure JSONL with no `sandbox`/`approval` field and stderr carries no banner, so D2a and D5a were mutually exclusive as written. The adapter now **drops `--json`**, parses the banner from the human stream, and takes the final message from `-o`. D2a is demoted to **fail-closed post-start detection** — the race is stated, "a truthful banner proves resolved intent, not kernel enforcement" is stated, and the kill is bounded to a process group **the adapter creates** (the previous text would have killed the inherited group, i.e. potentially the harness). |
| 2 | BLOCKER | **accepted** — new **D2b** gives the exact argv for every nested control (`sandbox_workspace_write.writable_roots=[]`, `network_access=false`, `sandbox_permissions=[]`) and explains why `-c` *pins* rather than merely detects. Managed-layer evidence is marked conditional on a managed host and its absence recorded. **Resume no longer ships on D2a's strength**: it ships only if D10's discriminating matrix passes inside Unit 1, else it fails closed like cursor's. |
| 3 | MAJOR | **accepted** — D4a now specifies SHA-256 workspace keys, dispatch-id format, `meta.tsv` with `schema=1`, an `initializing\|ready\|failed` lifecycle, latest-`ready` selection by `updated`, an atomic `current` pointer plus `.lock`, and **adoption on successful `--resume-unmanaged`**. The guarantee is qualified as shell-sandbox-only, with the host-side channel gap moved into the risk table as *not mitigated*. |
| 4 | MAJOR | **accepted** — verified `codex-dispatch.sh:507`ff: the summary is entirely `>&2`. D5a corrected to stderr summary + stdout final message exactly once, which is what the shims must preserve. Capture algorithm rewritten without `--json`; both descriptors tested independently across empty `-o`, absent banner, truncated stream, non-zero exit, and signal. |
| 5 | MAJOR | **accepted** — Unit 1's normative scope now reads D1–D4a + codex-scoped D5a + the P5 scan extension, and **adds codex to the existing `scripts/integration-test.sh` in Unit 1** so the boundary does not ship ahead of its evidence. Acceptance gains banner-mismatch, absent-banner, state-tampering, and no-`ready`-record negative cases plus the config variants. |
| 6 | MAJOR | **accepted** — verified `--backend all` today means grok + cursor. The new CLI makes `all` mean all three and the **shim translates legacy `all` → `grok,cursor`** with a second stderr line; declared as the single intentional argv exception. |
| 7 | MAJOR | **accepted** — `fixture_driver` becomes an **execution wrapper** (`run <tmpdir> <case> <adapter> -- <args>`) that establishes env in its own process and `exec`s the adapter, since a child `setup` cannot export env to its caller. TSV column value rules added; `session id` added to the frozen fields as a conditional-on-reported field per `dispatch-contract.md:7`. |
| 8 | MINOR | **accepted** — Unit 3 acceptance switched from identical manifests to identical external inventories, plus `bump=<version>` must equal the generated `plugin.json` version. |
| 9 | MINOR | **accepted** — 15 enabled plugin entries, counted; the text now says the scan discloses whatever is enabled at dispatch time rather than fixing a number. |
| 10 | NIT | **accepted** — header points at §8 and §9. |

## 10. Round-4 disposition

Round 4 confirmed D2b's ordinary-layer precedence claim against the installed
CLI, confirmed round-3 #4/#8/#9/#10 fully fixed, and ruled Unit 1 "large but
coherent as one shipping unit" — with the useful suggestion that it be
*implemented* as two commits (dormant harness/state machinery, then
activation/docs) without shipping between them. That sequencing is adopted.

| # | severity | disposition |
| --- | --- | --- |
| 1 | MAJOR | **accepted** — the demotion is now propagated everywhere it leaked: D10 no longer calls D2a "load-bearing at runtime", P4 no longer calls it "the runtime check that fires on every dispatch", and the risk table calls it a tripwire that cannot undo initiated tool calls, MCP actions, or escaped descendants. D1's ledger records the lost structured event stream as an **explicit observability regression** rather than claiming both benefits, and notes session ids now come from the banner. |
| 2 | BLOCKER | **accepted in full** — D4a gains a `running` state; promotion to `ready` happens only after the turn terminates (the previous "on session-id capture" would have let a second dispatch resume a live session); the workspace lock is held across selection → `running` → child execution → final transition, which also enforces one-unit-in-flight per workspace; ordering moves from wall-clock `updated` to a **monotonic `generation` allocated under the lock**; `current` is demoted to a validated cache with the record scan authoritative and repair after a promote/pointer crash; and secure bootstrap is specified (`0700` parents, per-component ownership/mode verification, `O_NOFOLLOW` on `.lock`). |
| 3 | MAJOR | **accepted** — new **D10a**: `--require codex` fails unless every non-managed case executed with the exact expected count, zero skips, zero failures, positive controls passing, negative controls denying, and provenance written. Missing managed-host layering is the only permitted conditional skip and is reported on its own line. Unit 1 enables resume only on a `--require codex` pass; a plain `PASS` with skips ships resume hard-refusing. |
| 4 | MAJOR | **accepted** — `--backend` becomes repeatable and the shim emits `--backend grok --backend cursor`, not the single token `grok,cursor`, which the stated value set would reject. |
| 5 | MINOR | **accepted** — `env_namespace` validated separately as `[A-Z][A-Z0-9_]*_LOOP_`; the looser executable-name grammar stays on `cli`. |
| 6 | NIT | **accepted** — "The last row" → "The stdin-hang row". |

## 11. Round-5 disposition

Round 5 confirmed §10 #5 and #6 fully fixed and #1 fixed in the normative
sections. All eight new findings accepted.

| # | severity | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted** — the premise "`~/.config` is outside the sandbox" is false for a repo rooted at `$HOME` or a `HOME` under `/tmp`, where the state root lands inside `workdir` or `/tmp`. D4a now canonicalizes the state root and every writable root before launch and **refuses when either contains the other or they are equal**, with negative tests for `workspace=$HOME`, `HOME` under `/tmp`, and symlink aliases that only collide after canonicalization. |
| 2 | BLOCKER | **accepted** — selection now makes the **highest valid generation decisive**: if it is `initializing` or `running`, dispatch and resume refuse rather than falling back to an older `ready` record. Without this, a wrapper killed while its codex child survives would let the next dispatch resume a live session — the exact defect round 4 closed, reintroduced one level down. A test kills the wrapper, leaves the child alive, and proves the next dispatch refuses. |
| 3 | MAJOR | **accepted** — `flock(1)` is confirmed **not on PATH** on the calibrated macOS host. The lock becomes a non-blocking descriptor lock taken by a supervising `python3` using `fcntl.flock(LOCK_EX\|LOCK_NB)`: fails immediately with the holding dispatch id rather than blocking (a blocking lock behind an overnight run is indistinguishable from a working job), close-on-exec so escaped descendants cannot hold it, stale file contents ignored once the descriptor lock is acquired. `generation` is `1 + max(valid generation)` from the authoritative scan under that lock — no separate counter file to bootstrap or repair. |
| 4 | MAJOR | **accepted** — expected cases come from a frozen versioned `tests/codex-cases.tsv` with unique ids, applicability, and expected outcome, computed **before** availability is probed, with one `managed-only` row. Deriving "expected" from what ran would be circular. |
| 5 | MAJOR | **accepted** — selectors are a deduplicated set; `--require codex` implies selecting codex; zero-skip and exact-count are scoped to codex so an unavailable grok does not invalidate the run; any real failure still fails. |
| 6 | MAJOR | **accepted** — `integration-test.sh:14` initializes `BACKEND="all"`, so the **zero-argument** invocation also means grok+cursor today. The shim injects `--backend grok --backend cursor` whenever no selector is present; both zero-arg and explicit `all` are tested. |
| 7 | MINOR | **accepted** — the stale D2a language survives only in the two affected §8 rows (§9 already carries the corrected position); those rows are now marked superseded in place, and the header states that newer dispositions win. |
| 8 | MINOR | **accepted** — whole-file atomic replacement is scoped to `meta.tsv` and `current`; `transcript.log` is append-only, non-authoritative evidence that is *supposed* to survive partially written. |
