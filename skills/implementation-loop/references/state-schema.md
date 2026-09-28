# Loop backend state schema

Normative inventory of production state written by the three adapters, plus
the journal store the index reads. Derived from write sites in this tree, not
from earlier plan summaries. Lifecycle cells in every artifact table are
exactly `present` or `absent`. Conditional artifacts are called out in the
format column and by those cells.

The five lifecycle classes are moments on the production path:

- **early failure** — refused before child launch (after any pre-launch state
  writes).
- **parse failure** — child launched; calibrated output parse failed; later
  completion writes have not happened.
- **read-only** — completed `--read-only` / `--investigate` path.
- **implement** — implement-mode after the child, including implement-only
  transition artifacts, before the successful-terminal write.
- **successful terminal** — the adapter reached its near-completion write.

---

## 1. Journal store

Authority is `scripts/loop-journal`. This section is a reader index, not a
second store spec.

**Root layout** (`scripts/loop-journal:336-352`):

`$HOME/.config/olddonkey-loop/journal/<workspace-key>/`

`workspace-key` is `sha256(canonical workspace)` (`scripts/loop-journal:321-322`).
The store contains `runs/`, `runs.tsv` (rebuildable cache), `context`,
`unattributed.jsonl`, `generation`, and `meta.lock`. Retired context files are
`context.retired-<run-id>` (`scripts/loop-journal:889`).

**Segment naming** (`scripts/loop-journal:425-428`):
`runs/<run-id>.jsonl` where `<run-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex
digits (`scripts/loop-journal:49`).

**Envelope fields** (`scripts/loop-journal:56`): `schema`, `seq`, `ts`,
`event`, `run`, `attribution_failure`. Attributed lines carry `schema=1`,
monotonic `seq`, UTC `ts`, `event`, and `run` (`scripts/loop-journal:904-910`).
Unattributed lines omit `seq` and record `attribution_failure`
(`scripts/loop-journal:924-929`).

**Closed event list** (`scripts/loop-journal:57-126`):

`run.begin`, `run.end`, `unit.begin`, `unit.end`, `round.begin`,
`checkpoint`, `review.recorded`, `publish.recorded`, `dispatch.start`,
`dispatch.end`, `dispatch.abandoned`, `gate.result`, `journal.repaired`.

**Segment classification** (`scripts/loop-journal:446-471`): an unterminated
valid tail line counts; an unterminated invalid tail is ignored (torn write);
a newline-terminated invalid line mid-file or at the tail is mid-file
corruption. The index uses this classification and never repairs; a
discarded torn tail makes that run's `counts_complete` false.

### `gate.result`

Intended mechanical writer: `scripts/run-gate.sh` — `journal_gate_result`,
called from `emit_result` after the `RESULT:` line is printed and before the
gate exits. It writes nothing when the journal helper is absent, and a failed
append only warns; neither changes the gate's exit. Validation is the
`gate.result` entry of `EVENT_SPECS` (`scripts/loop-journal:101-124`). The
journal is local and unauthenticated — validation checks the payload's shape,
not the actor, so any process running as the user can append a well-shaped
`gate.result` through `loop-journal append` — so a `gate.result` is a
recorded claim, not proof of who wrote it.

| field | required | values | writer source |
|---|---|---|---|
| `policy` | yes | `strict`, `baseline`, `passthrough` | `--strict` / `--baseline` / neither |
| `purpose` | yes | `unit-final`, `baseline-generation`, `focused`, `unspecified` | `--purpose` |
| `binding` | yes | `clean`, `dirty`, `changed`, `unavailable` | before/after tree samples |
| `verdict` | no | `green`, `red` | `green` iff the gate's own exit code is 0 |
| `gate_exit` | no | int | the gate's own exit code — the value `run-gate.sh` exits with |
| `totals` | no | `exit=<n>` (any JSON value is accepted) | the test suite's raw exit code |
| `pre_head`, `pre_tree` | no | str | pre-run capture, only when it succeeded |
| `post_head`, `post_tree` | no | str | post-run capture, only when it succeeded |
| `reason` | no | str | why `binding` is `unavailable` |
| `unit` | no | non-empty str | declared: `LOOP_UNIT` of the gate's caller (see below) |
| `round` | no | int ≥ 1 | declared: `LOOP_ROUND` of the gate's caller (see below) |

`verdict` and `gate_exit` record what the gate decided; `totals` records what
the suite returned. They disagree whenever a policy overrides the suite: an
exit-0 run judged red (a failed runner summary, an unrecognized runner under
`--strict` or `--baseline`, zero executed tests, stray failure lines, a log
replaced mid-run) is `totals=exit=0`, `verdict=red`, `gate_exit=1`, and a
baseline-matched failure run is `totals=exit=1`, `verdict=green`,
`gate_exit=0`. `run-gate.sh` always writes both `verdict` and `gate_exit`;
they stay optional because earlier history and fixtures lack them.

Readers (`build_gates` in `scripts/loop-index`) give every gate object a
normalized `verdict`: `green` only when the journaled `verdict` is `green` and
`gate_exit` is exactly the int 0; `red` only when it is `red` and `gate_exit`
is an exact int other than 0; `unknown` otherwise — absent, malformed, or
inconsistent pairs (`green` with 1, `red` with 0), a missing `gate_exit`, and
non-int values such as `false` or `0.0`. `gate_exit` is passed through only
when it is an exact int. An absent verdict reads as unknown; readers must
never infer green from `totals`.

No gate record is publication evidence, whatever its binding: a clean gate
may be a `focused` or `baseline-generation` run, and even a `unit-final` gate
only samples the tree at its endpoints. The console shows the verdict and the
fixed caveat "Recorded gate result — not proof of what ships."

### Declared attribution (`unit`, `round`)

`dispatch.start`, `dispatch.end`, `dispatch.abandoned`, and `gate.result`
accept optional `unit` (non-empty str) and `round` (int ≥ 1). `loop-journal
append` fills them from `LOOP_UNIT` and `LOOP_ROUND` when the payload does not
already carry them (`attribution_from_env`, `scripts/loop-journal:669`); an
explicit `--field`/`--json` value wins, key by key. An empty or multi-line
`LOOP_UNIT`, or a `LOOP_ROUND` that is not a positive decimal integer, fails
the append with exit 2 — an adapter then refuses to launch and the gate warns.
Every other event ignores both variables. The three adapters and
`run-gate.sh` call `loop-journal append` as a child process with their own
environment, so the caller sets the variables on the dispatch or gate command.

`recover --acknowledge` never reads the environment. First, before any tail
repair, append, or context retirement, it refuses with exit 2 when any
`dispatch_id` in the active run has more than one `dispatch.start` or more than
one terminal event (`dispatch.end` / `dispatch.abandoned`): such a history is
neither open nor closed (`duplicated_dispatch_ids`,
`scripts/loop-journal:1196`). Otherwise each acknowledged id has exactly one
start and no terminal event, and its `dispatch.abandoned` copies that start's
`unit`/`round` when present and writes neither when absent
(`abandoned_payload`, `scripts/loop-journal:1219`).

**The label is a declaration, not proof.** `unit` and `round` record what
whoever ran the command declared. They carry no digest binding them to a
prompt, diff, or tree, and, like every journal line, any process running as
the user can write them (the journal is local and unauthenticated; see
`gate.result` above). Readers take them as declared attribution with the
weakest assurance and never present them as verified.

The index (`scripts/loop-index`) resolves a dispatch's `unit`/`round` as the
values its `dispatch.start`, `dispatch.end`, and `dispatch.abandoned` agree
on. An absent label does not disagree; a malformed stored value (empty or
non-str `unit`, `round` not an int ≥ 1) reads as absent. It never joins events
by order or time.

| `attribution` | when | `unit` / `round` |
| --- | --- | --- |
| `declared` | the events agree and name a unit | shown |
| `none` | no event names a unit | `round` only if declared |
| `partial` | the dispatch has no `dispatch.start` | whatever its other events agree on; still counted as unattributed |
| `conflict` | its events declare different units or rounds | never shown; views treat it as unattributed |

A gate object is `declared` when its own `gate.result` names a unit and
`none` otherwise. A declared dispatch or gate label never creates a `units`
row; unit rows still come from unit, round, review, and publish events.

### Run totals and timeline (`loop-index`)

Each run object also carries:

- `counts_complete` — `true` only when the segment parsed with no mid-file
  corruption and no discarded torn tail. When it is `false`, every consumer
  labels the counts "partial".
- `counts` — totals over every parsed event of the run, never the timeline
  window: `{"all": C, "units": {"<unit>": C, …}, "unattributed": C}` where
  `C` is `{"dispatches": {"<backend>": {"ok", "failed", "open",
  "abandoned"}}, "reviews": {"iterate", "pass"}, "gates": {"green", "red",
  "unknown"}, "publishes": n}`. `ok` means a recorded exit of 0, nothing more;
  a start with no parsed terminal event is `open`. One rule covers
  dispatches, gates, reviews, and publications: an item counts under
  `units["<unit>"]` only when its resolved attribution is `declared` and
  names that unit (a dispatch's resolution above; a gate, review, or
  publication's own label). `none`, `partial`, and `conflict` count under
  `unattributed` — a `partial` dispatch too, even though it still carries
  the unit its other events agree on. `all` counts everything.
- `timeline` — the run's last 500 events in `seq` order, with
  `timeline_truncated` saying whether older events fell outside the window.
  Each event is projected to a closed whitelist: `seq`, `ts`, `event`;
  `dispatch_id`, `mode`, and `exit` on dispatch events; `binding`, `purpose`,
  and `gate_verdict` (the normalized verdict above) on `gate.result`;
  `review_verdict` (`pass`, `iterate`, anything else `unknown`) on
  `review.recorded`. Dispatch events carry `backend`, `unit`, `round`, and
  `attribution` resolved from the whole dispatch, so an end whose start fell
  outside the window still names its backend and every event of a conflicted
  dispatch reads `conflict` with no unit. `gate.result` carries its own
  declared `unit`/`round` and `attribution`; `review.recorded` and
  `publish.recorded` carry their `unit` with `attribution: declared`.
  Free-text fields (`findings`, `note`, `plan`, `reason`, `attested_by`,
  `branch`, `pr`, `sha`, `session`) are never projected.

Events in `unattributed.jsonl` are in no run's timeline or counts; the
top-level `unattributed_events` count is unchanged.

---

## 2. Per backend

### Codex

State root pattern (`backends/codex/dispatch.sh:264`, `:722-723`, `:770-771`):

`$HOME/.config/olddonkey-loop/codex/<workspace-key>/<dispatch-id>/`

`workspace-key` is `sha256(canonical workspace)` (`:722-723`).
`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 8 hex digits (`:742`). The
dispatch directory is created at `:771` after the workspace lock
(`.lock`, `:726-730`) and before `journal_dispatch_start` (`:800`) and the
child (`:804`). Early failure after that mkdir therefore has a dispatch
directory. The directory enforces a file allowlist
(`:535`: `meta.tsv`, `prompt.txt`, `transcript.log`, `last-message.txt`).
Workspace-root files `.lock` (`:726`) and `current` (`:552-563`) are not
per-dispatch artifacts.

All four dispatch files are created together (`:785-788`) before launch, so
every class that has a dispatch directory has the same names. `last-message.txt`
is created empty (`:787`) and required non-empty only on success (`:943`).
`meta.tsv` is rewritten across `initializing` / `running` / `ready` / `failed`
(`:482-484`, `:788-790`, `:901-947`). Parse failure is banner/session
verification failure after the child (`:901-942`), not a JSON parser.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| meta.tsv | backends/codex/dispatch.sh:484 | present | present | present | present | present | TSV rows schema,state,generation,session_id,workspace,created,updated |
| prompt.txt | backends/codex/dispatch.sh:785 | present | present | present | present | present | UTF-8 prompt body |
| transcript.log | backends/codex/dispatch.sh:786 | present | present | present | present | present | bytes; created empty, appended live at :823 |
| last-message.txt | backends/codex/dispatch.sh:787 | present | present | present | present | present | CLI last-message file; empty until success (:943) |

### Grok

State root pattern (`backends/grok/dispatch.sh:451-452`):

`<git-common-dir>/olddonkey-loop/grok/<dispatch-id>/`

`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits (`:186`).
`git-common-dir` is `rev-parse --git-common-dir` resolved against the
workspace (`:438-450`). The dispatch directory is created at `:746` after
pre-state refusals. `journal_dispatch_start` (`:962`) is after `state.json`
(`:836`) and the first `transition.jsonl` append (`:749`, `:857`) and before
the child (`:974`). `baseline.json` is implement-only (`:831-832`).
`session.json` is written only near completion (`:1217`), after parse
(`:1026-1046`) and the implement transition; exits before that write
(`:991`, `:1053`) leave it absent. `output.json` / `pgid` are created at
child launch (`:890-891`, `:977`, `:980`). Snapshot artifacts are
implement-only after a successful copy (`:1061`, `:1208`, `:1213`).
Workspace-root `writable-ledger.tsv` (`:453`, `:766-784`) is not a
per-dispatch artifact.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| state.json | backends/grok/dispatch.sh:836 | present | present | present | present | present | JSON schema=1 dispatch record |
| transition.jsonl | backends/grok/dispatch.sh:749 | present | present | present | present | present | JSONL {at,event} append-only |
| baseline.json | backends/grok/dispatch.sh:832 | present | present | absent | present | present | JSON marker inventory; implement-only (:831-832) |
| output.json | backends/grok/dispatch.sh:890 | absent | present | present | present | present | child stdout JSON object |
| pgid | backends/grok/dispatch.sh:891 | absent | present | present | present | present | ASCII process-group id plus newline |
| snapshot-baseline.json | backends/grok/dispatch.sh:1061 | absent | absent | absent | present | present | JSON; implement-only after snapshot copy |
| authoritative-baseline.json | backends/grok/dispatch.sh:1208 | absent | absent | absent | present | present | JSON; implement-only after worktree repair |
| authoritative-path | backends/grok/dispatch.sh:1213 | absent | absent | absent | present | present | one pathname line; implement-only |
| session.json | backends/grok/dispatch.sh:1217 | absent | absent | present | absent | present | JSON; only near successful completion (:1217) |

### Cursor

State root pattern (`backends/cursor/dispatch.sh:162-163`):

`<git-common-dir>/olddonkey-loop/cursor/<dispatch-id>/`

`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits (`:161`).
`git-common-dir` is `rev-parse --git-common-dir` resolved against the
workspace (`:146-152`). The dispatch directory is created at `:205`.
`project-files.zlist` (`:208-209`) and `prompt.txt` (`:284-285`) are written
before `journal_dispatch_start` (`:333`) and the child (`:345`). Parse
failure (`:367-392`) writes neither `parsed.json` nor `result.txt`.
`changes.raw.patch` / `changes.patch` are implement-only after a successful
post-copy walk (`:425-455`). `apply-check.log` / `apply.log` are written
only on the successful nonempty apply path (`:458-464`). Disposable copies
under `$HOME/.config/olddonkey-loop/cursor-work/<dispatch-id>/` (`:164-167`)
are not protected run state.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| project-files.zlist | backends/cursor/dispatch.sh:208 | present | present | present | present | present | NUL-separated git ls-files paths |
| prompt.txt | backends/cursor/dispatch.sh:284 | present | present | present | present | present | UTF-8 preamble plus prompt |
| output.json | backends/cursor/dispatch.sh:288 | absent | present | present | present | present | child stdout; created at :345 |
| stderr.log | backends/cursor/dispatch.sh:289 | absent | present | present | present | present | child stderr; created at :345 |
| parsed.json | backends/cursor/dispatch.sh:367 | absent | absent | present | present | present | JSON {is_error,session_id}; absent on parse failure |
| result.txt | backends/cursor/dispatch.sh:366 | absent | absent | present | present | present | result string; absent on parse failure |
| changes.raw.patch | backends/cursor/dispatch.sh:426 | absent | present | absent | present | present | git diff --no-index; implement-only |
| changes.patch | backends/cursor/dispatch.sh:418 | absent | present | absent | present | present | normalized patch; implement-only |
| apply-check.log | backends/cursor/dispatch.sh:460 | absent | absent | absent | absent | present | git apply --check output; successful nonempty apply |
| apply.log | backends/cursor/dispatch.sh:464 | absent | absent | absent | absent | present | git apply output; successful nonempty apply |

---

## 3. Correlation rule

Journal `dispatch_id` correlates to a state-directory basename by **exact
match only**. The adapters use the same id as the directory name
(`backends/codex/dispatch.sh:742` and `:770`;
`backends/grok/dispatch.sh:186` and `:452`;
`backends/cursor/dispatch.sh:161` and `:163`). Timestamp-proximity
correlation is forbidden (v2 non-goal). A state directory whose basename
matches no journal `dispatch.start` is **unattributed state** and is
displayed as such. A journal dispatch whose directory is absent is
`state_dir=missing`. When `git` or the git common dir cannot be resolved,
grok and cursor state reads as `unavailable` — not an error, and not a
guessed path.

---

## 4. Liveness evidence (D4)

v1 records no process identity. States are evidence words only.
`dispatch open` is a journal fact (start without `dispatch.end` or
`dispatch.abandoned`). It is refined by exactly these words:
`recent activity`, `idle N min`, `suspected stall`, `unknown`.
No other liveness word is a v1 state.

| backend | activity signal | source |
| --- | --- | --- |
| codex | `transcript.log` growth (size/mtime) | backends/codex/dispatch.sh:786, :823 |
| grok | named artifact mtimes in the dispatch dir | backends/grok/dispatch.sh:746 |
| cursor | named artifact mtimes in the dispatch dir | backends/cursor/dispatch.sh:205 |

Computation (index, evidence only): for an open dispatch whose `state_dir`
exists, take the newest mtime of that backend's activity artifacts. Age
below `LOOP_INDEX_ACTIVITY_SEC` (default 300) is `recent activity`. Age at
or above `LOOP_INDEX_STALL_SEC` (default 1200) is `suspected stall`.
Otherwise `idle` with `idle_minutes = floor(age/60)`. Missing or unreadable
`state_dir` is `unknown`. Never inspect processes, pids, or `/proc`.

---

## 5. Checkpoint evidence (D4)

Orchestrator checkpoint is an evidence axis, not a process word. States are
exactly `fresh`, `stale`, and `unknown`. v1 must not say `disconnected` — a
foreground dispatch is legitimately silent for tens of minutes.

Evidence base: the newest **agent-invoked** event in that run's segment.
Agent-invoked events are `run.begin`, `run.end`, `unit.begin`, `unit.end`,
`round.begin`, `checkpoint`, `review.recorded`, and `publish.recorded`.
Mechanical events (`dispatch.start`, `dispatch.end`, `dispatch.abandoned`,
`gate.result`, `journal.repaired`) do not count — the axis measures the
orchestrator, not the machinery.

The event's `ts` (ISO-8601 Z) is the evidence timestamp. Unparseable or
absent `ts` is `unknown` with no other keys. Mid-file-corrupt (degraded)
runs are `unknown`. Terminal runs (`completed` / `abandoned` / `failed`)
still compute the axis; the console decides what to show.

Age is `now - ts`. Age below `LOOP_INDEX_CHECKPOINT_FRESH_SEC` (default
900) is `fresh`. Otherwise `stale` with `age_minutes = floor(age/60)`.
Both `fresh` and `stale` carry `ts`.

`note` is taken from the newest `checkpoint` event that has a note, if
any, even when a later non-checkpoint agent event is the freshness
evidence.
