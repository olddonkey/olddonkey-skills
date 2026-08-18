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

**Root layout** (`scripts/loop-journal:322-338`):

`$HOME/.config/olddonkey-loop/journal/<workspace-key>/`

`workspace-key` is `sha256(canonical workspace)` (`scripts/loop-journal:307-308`).
The store contains `runs/`, `runs.tsv` (rebuildable cache), `context`,
`unattributed.jsonl`, `generation`, and `meta.lock`. Retired context files are
`context.retired-<run-id>` (`scripts/loop-journal:854`).

**Segment naming** (`scripts/loop-journal:411-414`):
`runs/<run-id>.jsonl` where `<run-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex
digits (`scripts/loop-journal:45`).

**Envelope fields** (`scripts/loop-journal:52`): `schema`, `seq`, `ts`,
`event`, `run`, `attribution_failure`. Attributed lines carry `schema=1`,
monotonic `seq`, UTC `ts`, `event`, and `run` (`scripts/loop-journal:869-875`).
Unattributed lines omit `seq` and record `attribution_failure`
(`scripts/loop-journal:889-894`).

**Closed event list** (`scripts/loop-journal:53-118`):

`run.begin`, `run.end`, `unit.begin`, `unit.end`, `round.begin`,
`checkpoint`, `review.recorded`, `publish.recorded`, `dispatch.start`,
`dispatch.end`, `dispatch.abandoned`, `gate.result`, `journal.repaired`.

**Segment classification** (`scripts/loop-journal:432-457`): an unterminated
valid tail line counts; an unterminated invalid tail is ignored (torn write);
a newline-terminated invalid line mid-file or at the tail is mid-file
corruption. The index uses this classification and never repairs.

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
