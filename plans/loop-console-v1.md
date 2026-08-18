# loop-console-v1

**Status: ACCEPTED** at Codex review round 8 (2026-08-18, gpt-5.6-sol / xhigh /
fast, one thread). Findings 15 → 10 → 9 → 5 → 4 → 2 → 1 → 0. Scope was cut
twice during review, both times at the reviewer's recommendation: the general
intent mailbox (no acquisition mechanism without a resident reader) and
kill + process identity (unsafe without cursor's process group; carries a
billable matrix re-run) both moved to v2. v1 = journal, mechanical writers,
index, read-only console, dials. Dispositions: §9–§15.

A local web console for the implementation loop: see what it is doing, see
the activity/idle/stall evidence for what is in flight, and change the dials
that are the user's to set.

Follow-on to `plans/repo-structure-v1.md` (D8 deferred this unification; D4a's
state discipline — protected paths, owner/mode checks, symlink refusal, atomic
writes, containment against sandbox-writable roots — applies to every store
here).

**Provenance discipline:** every "today it does X" claim carries a file:line
citation or is marked *assumed*. Rounds 1–3 refuted five uncited claims; the
citation habit is now procedure. Round 3 verified one assumption for us:
`tree-oid.sh` does cover untracked non-ignored content — no extension needed.

---

## 1. Problem

The loop runs for tens of minutes per dispatch with no surface. During the
predecessor plan the user asked, in one session: "大概还要多久 … 这个是不是卡死了
这么久了". Both are observability questions; the second was right — a dispatch
had hung 56 minutes emitting one line.

### P1. Per-dispatch state exists in three shapes; the inventory must be normative

- **codex** — `~/.config/olddonkey-loop/codex/<workspace-key>/<dispatch-id>/`:
  `meta.tsv` (key set and order strictly validated,
  `backends/codex/dispatch.sh:479-495`), `prompt.txt`, `transcript.log` (teed
  live), `last-message.txt`; the dispatch dir enforces a **file allowlist**
  (`:527-533`), so any new artifact is a parser change.
- **grok** — `<git-common-dir>/olddonkey-loop/grok/<dispatch-id>/`:
  `state.json`, `transition.jsonl`, `pgid` (`grok-dispatch.sh:885-943`),
  `session.json`; conditional: `baseline.json`, `snapshot-baseline.json`,
  `authoritative-baseline.json` (`:1151-1153`); root-level
  `writable-ledger.tsv` (`:446-449`).
- **cursor** — protected state under `<git-common-dir>/olddonkey-loop/cursor`
  (`cursor-dispatch.sh:154-160`); `$HOME` work root holds disposable copies.
  `changes*.patch`, `apply*.log` conditional (`:371-423`);
  `parsed.json`/`result.txt` absent on parse failure (`:316-358`). cursor's
  child runs as a foreground subshell with **no process group of its own**
  (`:293`) — one reason kill is v2.

The lists above are **illustrative, not normative** — round 4 caught this
summary dropping artifacts three times running (grok `output.json`,
`authoritative-path`; cursor `project-files.zlist`, `prompt.txt`,
`output.json`, `stderr.log`), and lifecycle nuances besides (grok
`baseline.json` is implement-mode-only, `grok-dispatch.sh:848`;
`session.json` is written only near successful completion, `:1182`). The
normative rule is therefore about derivation, not transcription: Unit 3's
`references/state-schema.md` **must be derived from every production write
site in the three adapters**, and its selftest must carry fixture inventories
for the five lifecycle classes — early failure, parse failure, read-only,
implement, successful terminal. The index is written against that document.

### P2. There is no loop-level state anywhere

Nothing on disk says which unit, round, or stage, what the last gate returned,
or which PR a unit became (`SKILL.md:183-189` says "somewhere durable").
The "user-level calibration record" is prose plus a textual example, not a
machine-readable store (`SKILL.md:210-222`, `references/dials.md:23-39`) —
dials need a real store (D9) before anything "lands mechanically".

### P3. Gate results land at caller-chosen paths, unbound to any tree

`run-gate.sh --log PATH` writes wherever the caller said
(`scripts/run-gate.sh:34-40`); nothing records which tree was certified,
though doctrine's rule is gate-the-commit (`SKILL.md:175-181`).

*(The process-identity problem formerly in this section moved with kill to v2
— see §7.)*

---

## 2. The authority line — enforced by the event model

The console is a principal's console. Authoritative for the user's decisions:
dials. Never authoritative for a judgment an agent or tool must make: review
verdicts, gate verdicts.

- **Review is an evidence axis** populated only by `review.recorded`
  (verdict + findings pointer, via `loop-run review`). Absent ⇒
  `review: not recorded`; the console never claims publication readiness.
- **No rejection control, no kill, no mailbox in v1.** Each was examined and
  removed for cause across rounds 1–3 (§9–§11).
- Gate verdicts render with policy, totals, purpose, and binding (D3); the
  console displays, never sets.

## 3. The journal

### D1. One locked append helper; segments authoritative; explicit maintenance

All writers go through `loop-journal append` (Python 3.11 stdlib):

- store `~/.config/olddonkey-loop/journal/<workspace-key>/runs/<run-id>.jsonl`;
  `0700`/`0600`, owner verified, `O_NOFOLLOW`, symlink/hardlink refusal,
  containment vs sandbox-writable roots (D4a);
- `fcntl.flock(LOCK_EX|LOCK_NB)` around {allocate seq, single append, fsync};
- **JSONL segments are authoritative; `runs.tsv` is a rebuildable cache.**
  Two locks with different lifetimes (round-3 F11): the **metadata lock** is
  held only for short atomic critical sections (run begin/end, index replace,
  gc, dial replace); the **`console.lock`** is a separate long-lived per-
  workspace lock that enforces the console singleton without blocking writers;
- persisted index rebuilds happen only inside writer operations or an explicit
  `loop-journal rebuild` (round-3 F9) — the console derives its view from
  segments **in memory only**;
- recovery: incomplete tail truncated at next append (`journal.repaired`);
  mid-file corruption fails closed → observability **degraded**; journal
  failure never alters a verdict; a control-store failure fails the control;
- **gc, precisely** (round-3 F12): explicit invocation only. Ordering
  authority is a **monotonic run generation** allocated at `run.begin` under
  the metadata lock (never wall clock). Protected: every run lacking terminal
  `run.end`, plus the 20 highest-generation terminated runs. Counted bytes:
  the run's segment file only. Below the 50 MB cap nothing is deleted —
  older terminated runs survive. Above it, unprotected runs delete
  oldest-generation-first. If protected runs alone exceed the cap, gc stops
  and reports a soft-cap overage; it never deletes protected runs. Index is
  rebuilt after deletion under the metadata lock.

### D2. Events, writers, and the context record

| event | writer | class |
| --- | --- | --- |
| `run.begin/end`, `unit.begin/end`, `round.begin`, checkpoint | `loop-run` | agent-invoked |
| `review.recorded`, `publish.recorded` | `loop-run review/publish` | agent-invoked |
| `dispatch.start/end` (backend, mode, exit, session id) | each `dispatch.sh` | mechanical |
| `gate.result` (policy, totals, purpose, binding) | `run-gate.sh` | mechanical |

**Context is discovered, not passed** (`SKILL.md:69-75` — env does not survive
between calls). `loop-run begin` writes the context record at
`~/.config/olddonkey-loop/journal/<workspace-key>/context`; `LOOP_CONTEXT` is
an optional fully-validated override.

**The context record has a schema and a lifecycle** (round-3 F4):
`schema=1`, canonical workspace path, workspace key, run id, **run
generation**, created-at. *Stale* is defined mechanically: the context is
stale when its run's segment carries a terminal `run.end` or does not exist.
`run.end` and `loop-run recover` **atomically deactivate** the context
(rename-away under the metadata lock), so a leftover context cannot attach
later events to a terminated run.

Degradation ladder — **seven** cases, each a named test (round-3 F4):
attributed / context missing / context stale / context malformed /
wrong-workspace / **helper missing** (silent no-op — the standalone promise,
`references/running-anywhere.md`) / **helper present but failing**.

The failing-helper rule is **asymmetric by event** (round-5 F1): within an
attributed run, the durable append of `dispatch.start` is a **pre-launch
requirement** — if it cannot be written, the dispatch refuses before the
child ever launches, which is the moment failing is still safe. Every other
event, `dispatch.end` included, stays non-blocking (warn on stderr, verdict
unaltered, event lost) — after launch, blocking is what would be harmful.
Without this, a lost start would make recovery vacuous: zero unmatched starts,
recovery proceeds, concurrent side effects. Unit 1 tests that a start-writer
failure provably never launches the fixture child.
With the helper installed, invalid context appends to per-workspace
`unattributed.jsonl`; never attach by timestamp proximity. Two canonical
workspaces sharing one `$HOME` get distinct SHA-256 keys (D4a rule,
`repo-structure-v1.md` D4a); an explicit concurrent A/B same-HOME isolation
test proves it.

### D2a. `loop-run recover` — fail-closed without identity (round-3 F5)

Identity records are v2, so v1 recovery cannot "verify processes are gone" —
and a vacuous check would treat missing evidence as absence. The v1 rule:

> `loop-run recover` proceeds **only when every `dispatch.start` in the run
> has a durable `dispatch.end`** — or an operator attestation for it.

Round-4 F1 caught the deadlock the bare rule creates: the journal helper is
allowed to fail without blocking a dispatch (D2), so `dispatch.end` can be
lost forever; refusal-forever then wedges the workspace, and killing an
already-dead process cannot mint the missing event. The escape is **operator
attestation, never fabrication**: `loop-run recover --acknowledge
<dispatch-id>` — run by the user in their own terminal, which is itself the
authentication — records `dispatch.abandoned(attested_by=user)` against the
unmatched start. **Normative meaning of the flag** (round-6 F1): supplying
`--acknowledge <dispatch-id>` asserts that the dispatch and its descendants
**have terminated or otherwise cannot produce further side effects**. Mere
notice that the event is missing is insufficient and must not retire the run.
This meaning appears verbatim in the CLI's help text **and** in the refusal
diagnostic that recovery prints when declining to proceed, and the recovery
test asserts all three: the help text, the refusal diagnostic, and that an
acknowledgment retires the context only together with the recorded
attestation event. Recovery then proceeds; the attestation stays visible in
the journal as what it is. No code path ever writes a synthetic
`dispatch.end`.

Successful recovery appends terminal `run.end(status=abandoned)` and
atomically retires the context. Nothing is deleted; evidence is preserved.
Unit 1's tests include the end-writer-failure and adapter-SIGKILL cases.
In v2, identity tokens open the stronger, non-interactive proof path.

### D3. Evidence axes; the binding truth table

Axes, each allowed `unknown`: orchestrator checkpoint · run/unit/round ·
dispatch · review · gate · publication · content binding.

**Binding truth table** (round-3 F8 — adopted verbatim; never classify from
HEAD alone). `run-gate.sh` captures `{HEAD, tree_oid}` **unconditionally on
both sides** of the suite, using `tree-oid.sh` (verified: covers untracked
non-ignored content):

| pre vs post | tree vs `HEAD^{tree}` | binding |
| --- | --- | --- |
| equal | equal | `clean` |
| equal | differs | `dirty` |
| differs (captured) | — | `changed` |
| capture failed either side | — | `unavailable` (+ reason recorded) |

Only `binding=clean` is publication evidence. `--purpose` is a validated enum
(`unit-final | baseline-generation | focused | unspecified`), doctrine naming
the required value per call site; policy never implies purpose.

### D4. Liveness without overclaiming — evidence words only

v1 records no process identity, so it must not say `alive` (round-4 F1):
cursor's child is a foreground subshell with no durable pid
(`cursor-dispatch.sh:293`), and nothing verifies any pid against reuse. The
states are evidence-only: **`dispatch open`** (start without end) ·
**`recent activity`** (a named artifact advanced within the threshold) ·
**`idle N min`** · **`suspected stall`** · **`unknown`**. Sources named per
backend (codex `transcript.log` growth; grok/cursor artifact mtimes only,
`cursor-dispatch.sh:281-320`, `grok-dispatch.sh:922-939`). Watcher health
separate; adapter exit stays the authoritative completion signal
(`references/dispatch-contract.md:14`).
Orchestrator **checkpoint**: `fresh | stale | unknown`, never "disconnected" —
a foreground dispatch is legitimately silent for tens of minutes. An active
run stays exclusive until `run.end` or D2a recovery; no time-based takeover.

## 4. Control — dials only

### D9. The calibration store is the sole machine authority (round-3 F10)

`~/.config/olddonkey-loop/calibration/<workspace-key>.tsv` — header rows
`#schema=1`, `#workspace=<canonical path>`, `#workspace_key=<sha256>`; exact
columns `key, value, scope(permission|policy), set_by, set_at, provenance`;
keys and values from closed enums (the eight dials and their documented
options, `references/dials.md`); `set_by` is the closed set
`{console, import-confirmed}`; duplicate or unknown rows reject the file
(fail closed — a broken store means **no standing authorization**, so
kickoff asks the user; it never falls back to memory, which is what would
resurrect revoked grants); no tabs/newlines in values; **a reader validates
the header workspace against its own resolved canonical workspace and key,
and a mismatch rejects the file** (round-4 F3) — cross-workspace fixtures in
Unit 5's tests; atomic replace under the metadata lock; D4a protections.

**Authority rules:**

- After migration, the store is the **only** machine-read source. Memory
  becomes a human-readable mirror the doctrine may write for the user's
  benefit but never reads for resolution.
- **Migration is explicit and manual**: today's authorization lives in
  human-readable private memory with no portable parser (`SKILL.md:210`), so
  the console cannot derive it. On first dial write the console shows the
  **safe defaults** and the user enters or confirms each value they hold.
  Confirmed **policy** rows get `set_by=import-confirmed`; confirmed
  **permission** rows are recorded as `set_by=console` — the migration happens
  inside the authenticated console, so confirming a permission there *is*
  granting it via the console, and the console-only rule below holds without a
  transition guard (round-5 F2). No silent import, no prose parsing.
- **Permission rows** (`scope=permission`: stop point beyond worktree,
  `claude-trivial-ok`, `continuous`) can be **granted** only by
  `set_by=console` — an authenticated action by the user on their machine.
  Agent- or repo-originated values may only tighten, never grant
  (`SKILL.md:216-222` already says this for repo files; the store extends it).
- **Stated consequence:** after a workspace migrates, a permission granted in
  chat is valid for that session but does not persist — persisting it takes a
  console action. Pre-migration workspaces keep today's flow unchanged.
- Revocation = writing the row to its default with `set_by=console`.
- Doctrine change (Unit 5): kickoff reads the store when present; the
  migration prompt covers the transition.

### The v1 risk, stated

**No kill.** A stalled dispatch is terminated the way it is today: the user
(or the orchestrator) in a terminal. The console shows liveness and idle time
so that decision is informed; it cannot act on it. Kill returns in v2 with
the identity contract (dual start tokens, cursor process group, timeout and
`kill_failed` outcomes — round-3 F6's full list) and its named cost: touching
codex's validated state surface re-disables resume pending the billable
matrix.

### D7. The web boundary is authentication; the handshake is exact

(Unchanged from round 3, verified against the body by the reviewer.) Inert
unauthenticated shell; fragment cleared via `history.replaceState` before
exchange; one-time token POSTed, constant-time compared, invalidated;
server-side session in HttpOnly `SameSite=Strict` cookie; CSRF token only in
authenticated content; mutations POST + Origin + exact numeric loopback Host +
bound port; no CORS; CSP `default-src 'none'` + enumerated needs; no-referrer,
no-store, nosniff; `textContent` rendering; validated links +
`noopener noreferrer`; zero remote assets; loopback, ephemeral port;
singleton via `console.lock` (not the metadata lock — round-3 F11).

### D8. The page

**Now** (axes, liveness with named source, transcript tail, dial controls),
**This run** (attributed units: dispatch / review evidence / gate with binding
/ publication facts; Unattributed section), **Dials** (values, provenance
store/default, permission dials visually separate; migration prompt on first
write). Empty state: `runs: []`, controls disabled.

---

## 5. Units — literal paths, all five fields (round-4 F4)

**Unit 1 — journal core.**
C: `skills/implementation-loop/scripts/loop-journal`,
`skills/implementation-loop/scripts/loop-run`.
M: `.github/workflows/selftest.yml` (add `bash -n` entries and the suite run).
T: `skills/implementation-loop/tests/journal-selftest.sh` — lock contention,
tail repair, corruption fail-closed, gc rule incl. soft-cap overage, context
schema/lifecycle incl. atomic deactivation, the seven-case ladder, A/B
same-HOME isolation, recover refusal/success, **attested abandonment with all
three D2a semantic assertions (help text, refusal diagnostic, retire-only-with-
attestation), end-writer failure, adapter SIGKILL**.
G: none. Gate: `bash skills/implementation-loop/tests/journal-selftest.sh`;
`bash -n skills/implementation-loop/scripts/loop-journal`;
`bash -n skills/implementation-loop/scripts/loop-run`.

**Unit 2 — mechanical writers.**
C: none.
M: `skills/implementation-loop/backends/codex/dispatch.sh`,
`skills/implementation-loop/backends/grok/dispatch.sh`,
`skills/implementation-loop/backends/cursor/dispatch.sh`
(`dispatch.start/end`, pre-launch start-append refusal with a test proving
the fixture-child marker is absent, helper detection, unattributed path),
`skills/implementation-loop/scripts/run-gate.sh` (`--purpose`, unconditional
pre/post `{HEAD, tree_oid}`, truth-table binding),
`.github/workflows/selftest.yml` (updated suite expectations).
T: `skills/implementation-loop/tests/contract-core.sh`,
`skills/implementation-loop/tests/contract-negative.sh`,
`skills/implementation-loop/backends/codex/fixture-driver.sh`,
`skills/implementation-loop/backends/grok/fixture-driver.sh`,
`skills/implementation-loop/backends/cursor/fixture-driver.sh`,
`skills/implementation-loop/tests/gate-selftest.sh` — the seven ladder
outcomes, the pre-launch start-append refusal, signal exits, every run-gate
terminal path, all four binding rows.
G: regenerated `cursor-implementation-loop/` — **both `run-gate.sh` and
`tests/gate-selftest.sh` are build inputs** (`build.sh:72`) — plus
`hosts/cursor/version-decision.tsv` written as `keep` or `bump=<version>`
exactly as the validator expects (`build.sh:364`).
Gate: `bash skills/implementation-loop/backends/codex/selftest.sh` ·
`bash skills/implementation-loop/backends/grok/selftest.sh` ·
`bash skills/implementation-loop/backends/cursor/selftest.sh` ·
`bash skills/implementation-loop/tests/gate-selftest.sh` ·
`bash cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh` ·
`bash skills/implementation-loop/tests/contract-core.sh` ·
`bash skills/implementation-loop/tests/contract-negative.sh` ·
`bash skills/implementation-loop/tests/shim-selftest.sh` ·
`bash tests/build-selftest.sh` · `bash build.sh --check`. *(No codex
state-surface change — resume stays enabled.)*

**Unit 3 — index.**
C: `skills/implementation-loop/scripts/loop-index`,
`skills/implementation-loop/references/state-schema.md` (derived from every
production write site — P1).
M: `.github/workflows/selftest.yml`.
T: `skills/implementation-loop/tests/index-selftest.sh` — fixture state trees
for all three backends across the five lifecycle classes, conditional-artifact
cases, empty state, degraded-journal display, D4 evidence-state rendering.
G: none. Gate: `bash skills/implementation-loop/tests/index-selftest.sh`;
`bash -n skills/implementation-loop/scripts/loop-index`.

**Unit 4 — console, read-only.**
C: `skills/implementation-loop/scripts/loop-console`,
`skills/implementation-loop/scripts/console-assets/index.html`,
`skills/implementation-loop/scripts/console-assets/console.css`,
`skills/implementation-loop/scripts/console-assets/console.js` — the complete
asset set; anything further is a plan change, not an implementation detail
(round-5 F3).
M: `.github/workflows/selftest.yml`.
T: `skills/implementation-loop/tests/console-selftest.sh` — handshake
(bootstrap reuse refused, CSRF required, Host validation), hostile transcript
fixtures render inert, no filesystem mutation beyond the session store,
in-memory view only.
G: none. Gate: `bash skills/implementation-loop/tests/console-selftest.sh`;
`bash -n skills/implementation-loop/scripts/loop-console`.

**Unit 5 — dials.**
C: `skills/implementation-loop/scripts/loop-calibration` (the D9 store
module).
M: `skills/implementation-loop/scripts/loop-console` (authenticated dial
endpoints), `skills/implementation-loop/SKILL.md` +
`skills/implementation-loop/references/dials.md` (kickoff reads the store;
manual migration; the chat-grant consequence),
`.github/workflows/selftest.yml`.
T: `skills/implementation-loop/tests/calibration-selftest.sh` — enum/
duplicate/unknown-row rejection, fail-closed corrupt store, header
workspace-mismatch rejection, cross-workspace fixtures, migration
confirmation, permission-vs-policy rules, atomic replace; endpoint CSRF/auth
tests in the console selftest.
G: none — the shared `SKILL.md`/`dials.md` are not build inputs; Cursor-host
doctrine comes from `hosts/cursor/` (`build.sh:66`).
Gate: `bash skills/implementation-loop/tests/calibration-selftest.sh` ·
`bash skills/implementation-loop/tests/console-selftest.sh` ·
`bash build.sh --check` (repo CI invariant, `AGENTS.md:56`).

## 6. Risks

| risk | mitigation |
| --- | --- |
| Agents skip `loop-run` | mechanical events still flow; display degrades honestly, never fabricates |
| Console implies review/publication readiness | artifact-only axes; `binding=clean` required |
| Stale context attaches events to a dead run | context lifecycle: terminal-run staleness + atomic deactivation |
| Vacuous recovery | D2a: durable start required pre-launch; refuse unless every start has a durable end **or a user attestation of termination** |
| Journal/index divergence | segments authoritative; in-memory console view; explicit rebuild |
| Store corruption resurrects revoked grants | fail closed to *no standing authorization*, never to memory |
| Two consoles / writer starvation | separate `console.lock` vs short metadata lock |
| GC eats live or protected runs | generation-ordered, protected-set rule, soft-cap stop |
| Hostile transcript XSS | D7 handshake + textContent + CSP |
| **No emergency stop in v1** | **accepted, stated; manual kill as today; v2 scope** |

## 7. Non-goals (v2 backlog)

**Kill + process identity — deferred whole (round-3 Q3), contract recorded
here in full so implementation never depends on review archaeology:** cursor
must first create a dedicated process group for its child (today: foreground
subshell, `cursor-dispatch.sh:293`); every adapter writes a versioned
`identity.json` — schema version, adapter pid + start token, child leader pid
**and** pgid stored separately, child start token, dispatch id, run id —
invalidated at terminal cleanup; codex requires the file-allowlist parser
change (`codex-dispatch.sh:527-533`); start tokens come from defined
fail-closed primitives (Linux `/proc/<pid>/stat` start ticks; a
microsecond-capable Darwin equivalent; unreadable ⇒ refuse); identity is
re-verified immediately before signalling; TERM has a bounded timeout with
escalation; outcomes include `child.kill_succeeded`, `child.kill_failed`, and
timeout; only the adapter's `dispatch.end` marks the dispatch terminal;
orphan kill refused when ownership cannot be proven; and the codex
state-surface change re-disables resume pending the user-owned billable
`--require codex` matrix.

Also v2: the general intent mailbox (needs mandatory polling or a resident
reader). Remote/phone access. Resident coordinator. Cursor-host console port.
Heuristic correlation. State-format migration. Multi-user.

## 8. Open questions — resolved

Round-4 Q1 is settled per the reviewer: **no `loop-run grant` escape hatch.**
A chat grant remains session-local; durable permission requires the
authenticated console. Nothing else is open; round 5 asks only whether the
revision holds.

## 9. Round-1 disposition *(rows superseded by later rounds marked)*

| # | disposition |
| --- | --- |
| 1–2, 4, 6, 13 | held as revised in round 2 |
| 3 | identity/kill design → **superseded: moved to v2** (§11 F6/Q3) |
| 5 | writers exist (`loop-run review/publish`, Unit 1) |
| 7 | `reject-diff` gone; replacements also gone (§10 F3) |
| 8 | axes; binding now per §11 F8 truth table |
| 9 | correlation via discovered context (§10 F1, §11 F4) |
| 10 | no coordinator; v1 further narrowed to dials-only control |
| 11 | mailbox deferred — moot in v1 |
| 12 | journal authority completed §10 F8 + §11 F9/F11/F12 |
| 14 | web list; exact handshake §10 F9 |
| 15 | unit scopes; all-five-fields form §11 F7 |

## 10. Round-2 disposition

As shipped in round 3, except: F4's kill machinery → **superseded to v2**
(§11 F6/Q3); F8's startup reconciliation → corrected to in-memory-only
(§11 F9).

## 11. Round-3 disposition

| # | sev | disposition |
| --- | --- | --- |
| 1–3 | fixed | mailbox removal, F9/F10 alignment, and the tree-oid assumption confirmed by the reviewer (no extension needed) |
| 4 | BLOCKER | **accepted** — context schema (workspace, key, run id, run generation), mechanical staleness (terminal or missing run), atomic deactivation on `run.end`/recover, seven-case ladder (missing-helper ≠ failing-helper), failing helper warns without altering verdicts, A/B same-HOME test |
| 5 | BLOCKER | **accepted** — D2a: recover only when every `dispatch.start` has a durable `dispatch.end`; refusal names the unproven dispatch; success appends `run.end(status=abandoned)` + retires context; identity proof path is v2 |
| 6 | BLOCKER | **accepted via Q3** — kill + identity deferred whole to v2 with the full requirement list (cursor group, leader pid + pgid, `/proc` start ticks + Darwin primitive, reverify-before-signal, TERM timeout/escalation, `kill_failed`); v1 risk stated |
| 7 | MAJOR | **accepted** — every unit now carries C/M/T/G/Gate with `none` explicit and enumerated repo paths |
| 8 | BLOCKER | **accepted** — the truth table verbatim; unconditional dual capture; never classify from HEAD alone; failure reasons recorded |
| 9 | MAJOR | **accepted** — console view is in-memory; persisted rebuilds only in writers or explicit `loop-journal rebuild` |
| 10 | BLOCKER | **accepted** — store-only machine authority; explicit confirmed migration; fail-closed to no-authorization; permission grants console-only; consequence stated |
| 11 | BLOCKER | **accepted** — separate long-lived `console.lock`; metadata lock short-only |
| 12 | MAJOR | **accepted** — generation ordering, counted bytes defined, below-cap survival, protected-set inviolable, soft-cap overage report, post-delete rebuild under lock |

## 12. Round-4 disposition

| # | sev | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted** — liveness states are evidence-only (`dispatch open / recent activity / idle / suspected stall / unknown`; no `alive` without identity); the helper-failure ∧ recover-refusal deadlock is broken by operator-attested abandonment (`recover --acknowledge`, records `dispatch.abandoned(attested_by=user)`, never fabricates `dispatch.end`); end-writer-failure and adapter-SIGKILL tests named in Unit 1 |
| 2 | MAJOR | **accepted** — P1 marked illustrative; the normative rule is derivation from every production write site, with fixture inventories for the five lifecycle classes |
| 3 | MAJOR | **accepted** — store header carries canonical workspace + key, readers reject mismatches, cross-workspace fixtures; migration is manual entry/confirmation over safe defaults with `set_by=import-confirmed` (no prose parsing); **Q1 closed: no `loop-run grant`** — chat grants are session-local, durable permission is console-only |
| 4 | MAJOR | **accepted** — every unit rewritten with literal paths under all five fields; `.github/workflows/selftest.yml` under M wherever suites are added; Unit 2 names both build inputs (`run-gate.sh` **and** `gate-selftest.sh`, `build.sh:72`) and the `keep|bump=<version>` spelling (`build.sh:364`); Unit 5 keeps `G: none` (doctrine files are not build inputs, `build.sh:66`) but gates on `build.sh --check` |
| 5 | MINOR | **accepted** — the full v2 identity contract copied into §7; F7's "every unit" claim made true by the Unit rewrite |

## 13. Round-5 disposition

| # | sev | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted** — the symmetric vacuity hole (lost `dispatch.start` ⇒ zero unmatched starts ⇒ recovery proceeds): the durable attributed start append is now a **pre-launch requirement** (refusing before launch is the safe moment), end-write failure stays non-blocking, a start-writer-failure test proves the fixture child never launches, and attestation is defined as asserting termination/neutralization, not mere notice |
| 2 | MAJOR | **accepted** — migration records confirmed permission rows as `set_by=console` (the migration is an authenticated console action, so the console-only rule holds without a transition guard); `import-confirmed` is policy-only |
| 3 | MAJOR | **accepted** — every glob and shorthand expanded: three literal fixture-driver paths, Unit 2's gate as nine explicit commands, Unit 4's complete three-file asset set fixed in the plan, Units 3/5 gates as literal commands |
| 4 | MINOR | **accepted** — intro reworded to activity/idle/stall evidence; the risk table's recovery row now names attestation |

## 14. Round-6 disposition

| # | sev | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted** — the attestation's normative meaning (terminated or cannot produce further side effects; never mere notice) moved into D2a's body, required in CLI help and refusal diagnostics, asserted by the recovery test; Unit 2's dispatch tests prove the fixture-child marker absent on start-append refusal |
| 2 | MAJOR | **accepted** — both dispatch paths and both Unit 1 `bash -n` commands written literally; the generated Cursor gate suite added as its own command (ten explicit commands), "both layouts" removed |

## 15. Round-7 disposition

| # | sev | disposition |
| --- | --- | --- |
| 1 | BLOCKER | **accepted** — root cause was two stacked silent no-op text replacements (unasserted `.replace()` with a misquoted target); the fix was re-applied with a verifying editor and grep-confirmed: D2a's body now carries the normative meaning ("terminated or otherwise cannot produce further side effects; mere notice is insufficient and must not retire the run"), required verbatim in CLI help **and** the refusal diagnostic, with Unit 1 asserting all three (help, diagnostic, retire-only-with-attestation) |
