# Loop backend state schema

Normative inventory of production state written by the four adapters, plus
the journal store the index reads. Derived from write sites in this tree, not
from earlier plan summaries. Lifecycle cells in every artifact table are
exactly `present` or `absent`. Conditional artifacts are called out in the
format column and by those cells.

**Citations.** Source is cited by name, never by line number, so an edit
above a cited site cannot leave a citation pointing at the wrong code. A
citation is `path:name`: a function, constant, or variable defined in `path`
(relative to this skill's root). A citation that starts at the colon omits
the path, and its name is defined in the file of the nearest full citation
before it. A writer cell that gives a path alone means the artifact is
written inline, and its file name is the search term.
`tests/index-selftest.sh` fails when a cited name is not defined in its file,
when an artifact's file name does not appear in its writer, or when a
line-number citation appears.

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

**Readers.** `scripts/loop-journal read-context`, `read-run`, and `find-run` are the exact
segment read interface described below. `scripts/loop-index` is the derived
reader of the store. The following readers consume its JSON document and
open no segment, cache, context, or repository file themselves:

- `scripts/loop-console` — the local web console.
- `scripts/loop-evidence` — the per-unit record card. It runs the sibling
  `loop-index --workspace <canonical>` with a fixed argv and a timeout, and
  uses only the unit's `units` row (`rounds`, `review`, `publish`), dispatch
  and gate objects whose `attribution` is `declared` for that unit, dispatches
  whose `attribution` is `conflict` or `partial` (listed as attribution
  unclear, counted for no unit), `counts.units[<unit>].reviews`, and
  `counts_complete`. Its final gate is the unit's last `unit-final` gate; it
  compares that gate's `post_head` with the publication's `sha` only when both
  are 40 lowercase hex, and labels every row `recorded`, `declared`,
  `values match`, or `unknown` — never verified.

**Root layout** (`scripts/loop-journal:journal_root`, `:store_paths`):

`$HOME/.config/olddonkey-loop/journal/<workspace-key>/`

`workspace-key` is `sha256(canonical workspace)`
(`scripts/loop-journal:workspace_key_for`).
The store contains `runs/`, `runs.tsv` (rebuildable cache), `context`,
`unattributed.jsonl`, `generation`, and `meta.lock`. Retired context files are
`context.retired-<run-id>` (`scripts/loop-journal:retire_context`).

**Segment naming** (`scripts/loop-journal:segment_path`):
`runs/<run-id>.jsonl` where `<run-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex
digits (`scripts/loop-journal:RUN_ID_RE`).

**Envelope fields** (`scripts/loop-journal:ENVELOPE_KEYS`): `schema`, `seq`,
`ts`, `event`, `run`, `attribution_failure`. Attributed lines carry
`schema=1`, monotonic `seq`, UTC `ts`, `event`, and `run`
(`scripts/loop-journal:append_event`). Unattributed lines omit `seq` and
record `attribution_failure` (`scripts/loop-journal:append_unattributed`).

**Closed event list** (`scripts/loop-journal:EVENT_SPECS`):

`run.begin`, `run.end`, `unit.begin`, `unit.end`, `round.begin`,
`checkpoint`, `review.recorded`, `publish.recorded`, `dispatch.start`,
`dispatch.end`, `dispatch.abandoned`, `gate.result`, `journal.repaired`.

**Segment classification** (`scripts/loop-journal:parse_segment`): an
unterminated valid tail line counts; an unterminated invalid tail is ignored
(torn write); a newline-terminated invalid line mid-file or at the tail is
mid-file corruption. The index uses this classification and never repairs; a
discarded torn tail makes that run's `counts_complete` false.

**Exact read interface.** These commands take `--workspace`, hold `meta.lock`
only to snapshot bytes, and never write, repair, rebuild, or create a store.

- `loop-journal read-context` prints `{"schema":1,"state":S,"run":R}`.
  `S` is `none` for no store or context, `active` for a live context,
  `stale` for a context naming an ended or missing run, and `malformed` for
  malformed or wrong-workspace context. `R` is the context's run id when
  readable, otherwise null. It skips the lock when there is no store or the
  store has no `meta.lock`; a missing lock does not hide a present context.
  `malformed` is stricter than `begin-run`, which would overwrite a malformed
  context. Exits: 0 when printed, 2 for usage, 3 for a busy lock, 5 for a
  context permission or symlink violation.
- `loop-journal read-run --run ID` prints one JSON object with `schema: 1`,
  `run`, `ended`, `end_status`, `tail`, `complete`, and `events`. The events are
  the parsed segment objects in order, including a valid unterminated last
  line but excluding a torn last line. `tail` is `clean`, `unterminated`, or
  `torn`; `complete` is true exactly for `clean`. `ended` reflects a `run.end`
  event and `end_status` is its status or null. This works after context
  retirement and does not read context. A newline-terminated non-object line
  is mid-file corruption; an unterminated non-object last line is a torn tail.
  Output JSON is ASCII-safe, including stored non-ASCII and escaped surrogate
  strings. Exits: 0 when printed; 2 for usage,
  invalid or missing run, or no store; 3 for a busy lock; 4 for mid-file
  corruption; 6 for a different event `run`, or an absent,
  non-integer, repeated, or decreasing `seq`. It does not validate payloads
  or dispatch ids.
- `loop-journal find-run --plan TEXT` prints one JSON object with `schema: 1`,
  sorted `runs` and `ambiguous` id lists. `runs` contains segments whose first
  event is `run.begin` with the exact plan, including a valid first event
  without a trailing newline. `ambiguous` contains segments without a
  parseable first event or whose first event is not `run.begin`; later
  corruption does not affect the result. An absent plan on
  a valid `run.begin` is neither a match nor ambiguous. A missing store
  prints empty lists and creates nothing. Exits: 0 when printed; 2 for usage,
  including empty or multiline plan; 3 for a busy lock; 5 for a malformed
  `runs` directory.

`review.recorded` accepts optional `reviewer` from the closed enum
`claude`, `codex`, `cursor`, `grok`, `session`. The last valid review for a
unit projects this value into the index unit's `review` object and its
timeline item; an absent or unknown stored value is omitted.

### `gate.result`

Intended mechanical writer: `scripts/run-gate.sh:journal_gate_result`,
called from `:emit_result` after the `RESULT:` line is printed and before the
gate exits. It writes nothing when the journal helper is absent, and a failed
append only warns; neither changes the gate's exit. Validation is the
`gate.result` entry of `scripts/loop-journal:EVENT_SPECS`. The
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

Readers (`scripts/loop-index:build_gates`) give every gate object a
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
already carry them (`scripts/loop-journal:attribution_from_env`); an
explicit `--field`/`--json` value wins, key by key. An empty or multi-line
`LOOP_UNIT`, or a `LOOP_ROUND` that is not a positive decimal integer, fails
the append with exit 2 — an adapter then refuses to launch and the gate warns.
Every other event ignores both variables. The four adapters and
`run-gate.sh` call `loop-journal append` as a child process with their own
environment, so the caller sets the variables on the dispatch or gate command.

`recover --acknowledge` never reads the environment. First, before any tail
repair, append, or context retirement, it refuses with exit 2 when any
`dispatch_id` in the active run has more than one `dispatch.start` or more than
one terminal event (`dispatch.end` / `dispatch.abandoned`): such a history is
neither open nor closed
(`scripts/loop-journal:duplicated_dispatch_ids`). Otherwise each acknowledged id has exactly one
start and no terminal event, and its `dispatch.abandoned` copies that start's
`unit`/`round` when present and writes neither when absent
(`scripts/loop-journal:abandoned_payload`).

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
  `review_verdict` (`pass`, `iterate`, anything else `unknown`) and optional
  valid `reviewer` on `review.recorded`. Dispatch events carry `backend`,
  `unit`, `round`, and `attribution` resolved from the whole dispatch, so an
  end whose start fell outside the window still names its backend. Every
  event of a conflicted dispatch reads `conflict` with no unit. `gate.result` carries its own
  declared `unit`/`round` and `attribution`; `review.recorded` and
  `publish.recorded` carry their `unit` with `attribution: declared`.
  Free-text fields (`findings`, `note`, `plan`, `reason`, `attested_by`,
  `branch`, `pr`, `sha`, `session`) are never projected.

Events in `unattributed.jsonl` are in no run's timeline or counts; the
top-level `unattributed_events` count is unchanged.

---

## 2. Per backend

### Codex

State root pattern (`backends/codex/dispatch.sh:STATE_ROOT`,
`:workspace_root`, `:dispatch_directory`):

`$HOME/.config/olddonkey-loop/codex/<workspace-key>/<dispatch-id>/`

`workspace-key` is `sha256(canonical workspace)` (`:workspace_key`).
`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 8 hex digits (`:dispatch_id`). The
dispatch directory (`:dispatch_directory`) is created after the workspace lock
(`.lock`, `:lock_path`) and before `:journal_dispatch_start` and the child
(`:child`). Early failure after that mkdir therefore has a dispatch
directory. The directory enforces a file allowlist (`:scan_records`:
`meta.tsv`, `prompt.txt`, `transcript.log`, `last-message.txt`).
Workspace-root files `.lock` (`:lock_path`) and `current` (`:repair_current`)
are not per-dispatch artifacts. `.lock` holds one holder line (`:read_holder`,
`:write_holder`): the lock holder's id and wrapper pid, plus the process group
and start time of the last CLI the workspace spawned. Only the adapter's own
`--recover-stale` reads it.

All four dispatch files are created together before launch (three
`:create_regular` calls, then `:write_meta`), so every class that has a
dispatch directory has the same names. `last-message.txt` (`:last_message`)
is created empty and required non-empty only on success (`:validate_regular`
with `allow_empty=False`). `meta.tsv` is rewritten by `:write_meta` across
`initializing` / `running` / `ready` / `failed`; a stop signal or a closed
output reader (`:fail_generation`) and `--recover-stale` (`:recover_stale`)
also write `failed`. Parse failure is
banner/session verification failure after the child (`:banner_error` and the
checks that follow `:child_status`), not a JSON parser.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| meta.tsv | `backends/codex/dispatch.sh:write_meta` | present | present | present | present | present | TSV rows schema,state,generation,session_id,workspace,created,updated |
| prompt.txt | `backends/codex/dispatch.sh:create_regular` | present | present | present | present | present | UTF-8 prompt body |
| transcript.log | `backends/codex/dispatch.sh:create_regular` | present | present | present | present | present | bytes; created empty, appended live through `:transcript_path` |
| last-message.txt | `backends/codex/dispatch.sh:create_regular` | present | present | present | present | present | CLI last-message file; empty until success |

### Grok

State root pattern (`backends/grok/dispatch.sh:STATE_ROOT`, `:STATE_DIR`):

`<git-common-dir>/olddonkey-loop/grok/<dispatch-id>/`

`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits (`:DISPATCH_ID`).
`git-common-dir` is `rev-parse --git-common-dir` resolved against the
workspace (`:COMMON_DIR`). The dispatch directory (`:STATE_DIR`) is created
after pre-state refusals. The `:journal_dispatch_start` call is after
`state.json` and the first `transition.jsonl` append (`:journal`, event
`prepared`) and before the child (`:GROK_STATUS`). `baseline.json` is
implement-only (`:write_baseline` into `:BASELINE`). `session.json` is
written only near completion, just before the `authoritative-recorded`
transition, after parse (`:PARSED_OUTPUT`) and the implement transition;
exits before that write (an empty `:PGID_FILE`, an existing `:SNAPSHOT`)
leave it absent. `output.json` / `pgid` are created at child launch
(`:OUTPUT_JSON`, `:PGID_FILE`). Snapshot artifacts are implement-only after a
successful copy (`:SNAPSHOT_BASELINE`, `:write_baseline`, `:AUTHORITATIVE`).
Workspace-root `writable-ledger.tsv` (`:LEDGER`, `:ledger`) is not a
per-dispatch artifact.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| state.json | `backends/grok/dispatch.sh` | present | present | present | present | present | JSON schema=1 dispatch record |
| transition.jsonl | `backends/grok/dispatch.sh:journal` | present | present | present | present | present | JSONL {at,event} append-only |
| baseline.json | `backends/grok/dispatch.sh:BASELINE` | present | present | absent | present | present | JSON marker inventory; implement-only |
| output.json | `backends/grok/dispatch.sh:OUTPUT_JSON` | absent | present | present | present | present | child stdout JSON object |
| pgid | `backends/grok/dispatch.sh:PGID_FILE` | absent | present | present | present | present | ASCII process-group id plus newline |
| snapshot-baseline.json | `backends/grok/dispatch.sh:SNAPSHOT_BASELINE` | absent | absent | absent | present | present | JSON; implement-only after snapshot copy |
| authoritative-baseline.json | `backends/grok/dispatch.sh:write_baseline` | absent | absent | absent | present | present | JSON; implement-only after worktree repair |
| authoritative-path | `backends/grok/dispatch.sh` | absent | absent | absent | present | present | one pathname line; implement-only |
| session.json | `backends/grok/dispatch.sh` | absent | absent | present | absent | present | JSON; only near successful completion |

### Cursor

State root pattern (`backends/cursor/dispatch.sh:STATE_ROOT`, `:STATE_DIR`):

`<git-common-dir>/olddonkey-loop/cursor/<dispatch-id>/`

`<dispatch-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits (`:DISPATCH_ID`).
`git-common-dir` is `rev-parse --git-common-dir` resolved against the
workspace (`:COMMON_DIR`). The dispatch directory (`:STATE_DIR`) is created
together with `:COPY_ROOT`. `project-files.zlist` (`:MANIFEST`) and
`prompt.txt` (`:PROMPT_RECORD`) are written before the
`:journal_dispatch_start` call and the child (`:CURSOR_STATUS`). Parse
failure (`:PARSE_OK`) writes neither `parsed.json` nor `result.txt`.
On a successful result, new paths the real repository ignores are deleted
from the work copy before the diff (`:IGNORED_DROPPED`). `changes.patch`
(`:PATCH_PATH`) is implement-only after a successful post-copy walk
(`:POST_COPY_OK`); it is the raw pristine-vs-work diff, applied with
`git apply -p2` and never rewritten. `apply-check.log` / `apply.log` are
written only on the successful nonempty apply path, which follows
`:FILES_CHANGED`. Disposable copies under
`$HOME/.config/olddonkey-loop/cursor-work/<dispatch-id>/` (`:WORK_ROOT`,
`:COPY_ROOT`) are not protected run state.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| project-files.zlist | `backends/cursor/dispatch.sh:MANIFEST` | present | present | present | present | present | NUL-separated git ls-files paths |
| prompt.txt | `backends/cursor/dispatch.sh:PROMPT_RECORD` | present | present | present | present | present | UTF-8 preamble plus prompt |
| output.json | `backends/cursor/dispatch.sh:OUTPUT_JSON` | absent | present | present | present | present | child stdout; created at child launch |
| stderr.log | `backends/cursor/dispatch.sh:STDERR_LOG` | absent | present | present | present | present | child stderr; created at child launch |
| parsed.json | `backends/cursor/dispatch.sh` | absent | absent | present | present | present | JSON {is_error,session_id}; absent on parse failure |
| result.txt | `backends/cursor/dispatch.sh:RESULT_FILE` | absent | absent | present | present | present | result string; absent on parse failure |
| changes.patch | `backends/cursor/dispatch.sh:PATCH_PATH` | absent | present | absent | present | present | raw pristine-vs-work patch; implement-only |
| apply-check.log | `backends/cursor/dispatch.sh` | absent | absent | absent | absent | present | git apply --check output; successful nonempty apply |
| apply.log | `backends/cursor/dispatch.sh` | absent | absent | absent | absent | present | git apply output; successful nonempty apply |

### Claude

State root pattern (`backends/claude/dispatch.sh:STATE_ROOT`, `:STATE_DIR`):

`<git-common-dir>/olddonkey-loop/claude/<dispatch-id>/`

The dispatch id (`:DISPATCH_ID`) is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits.
The directory (`:STATE_DIR`) is created together with `:COPY_ROOT`, and the
git-less copies live under
`$HOME/.config/olddonkey-loop/claude-work/<dispatch-id>/` with
`pristine/`, `work/`, and the post-run `frozen/` snapshot. A `frozen.ok` marker
is created beside `frozen/` only after the copy succeeds. These are copy-root
artifacts, not protected state artifacts. The manifest and prompt are written
before the journal start and child. `stream.jsonl` and `stderr.log` are
created at child launch. `last-message.txt` is created only after a valid init
and result; parse failures create no patch. Before checking or diffing
`frozen/`, the adapter drops new ignored paths and new paths under any
`.claude/` component, including empty CLI scratch directories. It never adds
anything under `.claude/` to the real worktree; a changed or deleted pristine
path under `.claude/` is refused. In implement mode, `changes.patch` is
written from pristine to frozen after those drops and all boundary checks.
It is applied with `git apply -p2` and no path rewrite. Apply logs occur only
for a nonempty patch on the apply path.

| artifact | writer | early failure | parse failure | read-only | implement | successful terminal | format |
| --- | --- | --- | --- | --- | --- | --- | --- |
| project-files.zlist | `backends/claude/dispatch.sh:MANIFEST` | present | present | present | present | present | NUL-separated git ls-files paths |
| prompt.txt | `backends/claude/dispatch.sh:PROMPT_RECORD` | present | present | present | present | present | UTF-8 preamble plus prompt |
| stream.jsonl | `backends/claude/dispatch.sh:STREAM_JSONL` | absent | present | present | present | present | child stream JSONL; created at child launch |
| stderr.log | `backends/claude/dispatch.sh:STDERR_LOG` | absent | present | present | present | present | child stderr; created at child launch |
| last-message.txt | `backends/claude/dispatch.sh:RESULT_FILE` | absent | absent | present | present | present | exact result string, no added newline |
| changes.patch | `backends/claude/dispatch.sh:PATCH_PATH` | absent | absent | absent | present | present | raw pristine-vs-frozen patch; implement-only |
| apply-check.log | `backends/claude/dispatch.sh` | absent | absent | absent | absent | present | git apply --check output; nonempty patch only |
| apply.log | `backends/claude/dispatch.sh` | absent | absent | absent | absent | present | git apply output; nonempty patch only |

---

## 3. Correlation rule

Journal `dispatch_id` correlates to a state-directory basename by **exact
match only**. The adapters use the same id as the directory name
(`backends/codex/dispatch.sh:dispatch_id` and `:dispatch_directory`;
`backends/grok/dispatch.sh:DISPATCH_ID` and `:STATE_DIR`;
`backends/cursor/dispatch.sh:DISPATCH_ID` and `:STATE_DIR`;
`backends/claude/dispatch.sh:DISPATCH_ID` and `:STATE_DIR`). Timestamp-proximity
correlation is forbidden (v2 non-goal). A state directory whose basename
matches no journal `dispatch.start` is **unattributed state** and is
displayed as such. A journal dispatch whose directory is absent is
`state_dir=missing`. When `git` or the git common dir cannot be resolved,
claude, grok, and cursor state read as `unavailable` — not an error, and not a
guessed path.

---

## 4. Liveness evidence (D4)

v1 records no process identity in the journal or in per-dispatch state.
States are evidence words only. The Codex adapter's `.lock` holder line (§2)
is private to that adapter's own recovery; the index does not read it.
`dispatch open` is a journal fact (start without `dispatch.end` or
`dispatch.abandoned`). It is refined by exactly these words:
`recent activity`, `idle N min`, `suspected stall`, `unknown`.
No other liveness word is a v1 state.

| backend | activity signal | source |
| --- | --- | --- |
| claude | named artifact mtimes in the dispatch dir | `backends/claude/dispatch.sh:STATE_DIR` |
| codex | `transcript.log` growth (size/mtime) | `backends/codex/dispatch.sh:transcript_path` |
| grok | named artifact mtimes in the dispatch dir | `backends/grok/dispatch.sh:STATE_DIR` |
| cursor | named artifact mtimes in the dispatch dir | `backends/cursor/dispatch.sh:STATE_DIR` |

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
