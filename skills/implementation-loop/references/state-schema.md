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
`ts`, `event`, `run`, `attribution_failure`. Attributed schema-1 lines carry
`schema=1`, monotonic `seq`, UTC `ts`, `event`, and `run`
(`scripts/loop-journal:append_event`). Unattributed lines omit `seq` and
record `attribution_failure` (`scripts/loop-journal:append_unattributed`).
Schema-2 lines carry the same envelope with `schema=2` and are never
unattributed (see [Schema 2](#schema-2-task-graph-v1-vocabulary-tg-v10a1) below).

**Closed event list** (schema 1, `scripts/loop-journal:EVENT_SPECS`):

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
  `torn`; `complete` is true exactly for `clean`. `ended` reflects a schema-1
  `run.end` event and `end_status` is the last such event's status or null;
  schema-2 lines affect neither field. This works after context
  retirement and does not read context. A newline-terminated non-object line
  is mid-file corruption; an unterminated non-object last line is a torn tail.
  Output JSON is ASCII-safe, including stored non-ASCII and escaped surrogate
  strings. Exits: 0 when printed; 2 for usage,
  invalid or missing run, or no store; 3 for a busy lock; 4 for mid-file
  corruption; 6 for a different, absent, or non-string event `run`, or an absent,
  non-integer, repeated, or decreasing `seq`. It does not validate payloads
  or dispatch ids. Exit 9 means an unknown-schema line. Run and sequence
  checks cover all parsed lines before the schema check, so an unknown-schema
  line with an invalid run or sequence exits 6 rather than 9.
- `loop-journal find-run --plan TEXT` prints one JSON object with `schema: 1`,
  sorted `runs` and `ambiguous` id lists. `runs` contains segments whose first
  event is a schema-1 `run.begin` with the exact plan, including a valid first event
  without a trailing newline. `ambiguous` contains segments without a
  parseable first event, whose first event is not `run.begin`, or whose first
  line is not schema 1 (including schema 2 or an unknown schema); later
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

### Schema 2 (task-graph-v1 vocabulary `tg-v1.0a1`)

Authority is `lib/loopauth/` (stdlib-only python3): `canonical.py`
(encoding and digests), `vocabulary.py` (record shapes, digest subjects, the
guarded transition table), and `reduce.py` (the pure reducer).
`scripts/loop-journal` and `scripts/loop-index` import it only from the
`lib/` directory beside their own real `scripts/` directory and refuse a
symlinked `lib/`, package directory, or module (journal exit 5, index exit 6).

**Claims, not facts.** The journal is observational and unauthenticated. A
schema-2 record may name an authority record (a request, answer, approval,
capability, receipt) by digest, but every such reference, and every fact only
the authority store could establish, is a **claim** its writer asserted. The
reducer checks claims for shape and internal consistency and records each
guard as `claimed`, never `verified`; no node is completion-eligible while any
guard is only claimed, so schema 2 reduces runs and certifies nothing.
Sub-unit 0a.3 classifies these claims against the authority store (section 6,
*Claimed references*): in 0a it rejects every request, answer, and expiry
claim and verifies none.

**Writing.** `loop-journal append --schema 2 --event E --json OBJ` validates
the payload against `vocabulary.py` and writes the whole event as canonical
JSON (sorted keys); `schema`, `seq`, `ts`, `event`, and `run` are added as for
schema 1. `--field` is refused with `--schema 2`, only `--schema 2` is defined,
and `LOOP_UNIT`/`LOOP_ROUND` are never read. A schema-2 record needs a fresh
context and its `run_id` must equal that context's run; it is never written to
`unattributed.jsonl`. Refusals exit 2 and name a reason code in brackets
(`[missing-field]`, `[evidence-missing]`, `[strong-assurance]`,
`[run-mismatch]`, `[request-digest-mismatch]`, ...). `approval.consume` is a
reserved word whose shape is defined, but the journal refuses it, with or
without `--schema`, with exit 10: consuming an approval is an authority-store
transition. Without `--schema`, `append` is byte-for-byte schema 1.

**Reading and failing closed.** A segment may mix schema-1 and schema-2 lines;
every reader dispatches on each line's own `schema`. `loop-journal`'s
schema-1 views — a run's terminal status and generation, and `recover`'s
dispatch matching — read schema-1 lines only: a schema-2 line never closes a
`dispatch.start`, never ends a run, and never counts as a duplicate. A line
whose `schema` is absent or anything but the integer 1 or 2 is **unknown**:
`loop-journal` reads the run as `degraded` (never terminal), `loop-index`
counts it in the run's `unknown_schema_lines` and reads the run and the
journal as `degraded`, and the reducer reports it and marks the run degraded;
none interprets the line. The shared check every mutating command runs before
its first write — `append` (either schema), `begin-run` (before retiring a
stale context), `end-run`, `recover`, and `gc` (for every run in the store) —
exits 9 on an unknown-schema line and never mutates, retires, deletes,
truncates, or rewrites anything. It runs first as a read-only scan of the run
the command would touch (the context's run; every run for `gc`), before the
store is bootstrapped, so not even a missing `meta.lock`, `generation`, or
`runs.tsv` is recreated; it repeats under the lock. `rebuild` still records
the run as `degraded` in `runs.tsv`. `loop-index` counts schema-2 lines per
run in `schema_2_events`; they feed none of the schema-1 views (units,
dispatches, gates, checkpoint, counts, timeline).

**Canonical encoding and digests** (`canonical.py`). UTF-8 JSON, object keys
sorted by code point, no insignificant whitespace, integers only; floats,
NaN, infinities, non-string keys, and duplicate keys are refused. Two limits
are part of the format, and a value outside either has no canonical encoding
and is refused: integers lie in [−(2^53 − 1), 2^53 − 1] (2^53 − 1 is
accepted, 2^53 refused), and nesting is at most 64 levels deep, counting
arrays and objects (a scalar is depth 0, `[]` and `{}` depth 1, `[[1]]` depth
2; depth 64 is accepted, 65 refused). `digest(x) = "sha256:" +
hex(sha256(canonical(x)))`. Digests cover named subject objects, never the
record itself:

| record | `request_digest` over | `result_digest` over |
| --- | --- | --- |
| `attempt.begin` | unit `{node_type, stop_point, node_spec_digest, input_content, dispatch}`; investigation `{node_type, node_spec_digest, input_content, dispatch}`; operation `{node_type, node_spec_digest, input_content, invocation, catalog_entry_digest}`; approval `{node_type, node_spec_digest, envelope_digest}` | — |
| `operation.reserve` / `.spawned` / `.released` / `.result` | `{invocation, expected_preconditions}` | `.result` only: `{outcome, producer, log_digest, identity, output_content}` |
| `gate.result` | `{suite_invocation, input_content}` | `{verdict, gate_exit, suite_exit, binding, producer, log_digest, output_content}` |
| `review.recorded` | `{request_id, reviewed_content_digest}` | `{verdict, reviewer, findings_digest}` |
| `publish.recorded` | `{stop_point, branch, content}` | `{outcome, sha, pr, head_sha, error_code}` |
| `node.transition` | `{node_id, attempt_id, from, to}` | `{to, evidence, stop_point_result, markers, content}` |
| `reconciliation.result` | carried: the substituted record's request subject | `{reconciliation_outcome, method, substitutes, observed_content, receipt_ref, substituted_result, producer}` |

A subject always holds every field it names; an omitted optional field is JSON
`null`, so omitted and explicitly `null` digest the same. Both digests are
recomputed in exactly two places: `loop-journal append --schema 2` refuses a
record whose claimed digest differs from the recomputed one, and the reducer
re-validates every schema-2 line it folds (digests included) and rejects a
mismatching line. `loop-journal`'s run inspection (`rebuild`, `gc`, context
staleness, `recover`) and `loop-index` classify schema-2 lines by `schema`
only and never recompute their digests, so a schema-2 line edited in place
after it was written is caught only when the reducer reads it. Either check
rejects internally inconsistent records only, and says nothing about whether
the recorded invocation really ran or the producer really wrote the record. A
reference's `digest` is `digest({"event": E, "payload": P})` over the named
record's payload `P` (every field but the journal envelope).

**Shapes.** Content is `{kind: "git", head, tree_oid}` or `{kind: "non-git",
content_digest}`; an invocation is `{argv, cwd, env_digest, executor_version}`;
a producer is `{tool, tool_digest}`; process identity is `{adapter: P,
effect_child: P}` with `P = {boot_id, pid, pgid, start_time}`. A reference is
`{kind, digest, node_id, attempt_id, content}` plus the claims its kind may
carry (for example `answer`, `verdict`, `reviewer`, `input_content`,
`receipt_object`); `content` is `null` for kinds that concern no content
(answers, requests, expiries, cancellations, quiescence, reservations). A
reference must claim the same `node_id` and `attempt_id` as its record.

**Records.** Every record carries `vocabulary: "tg-v1.0a1"`. The binding
envelope — `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`,
`attempt_id`, `content`, `request_digest`, `result_digest` — is required on
`gate.result`, `review.recorded`, `publish.recorded`, `operation.result`, and
`node.transition`. Payloads are closed: an unknown field is refused.

| event | fields beyond the vocabulary word |
| --- | --- |
| `attempt.begin` | `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`, `attempt_id`, `parent_attempt_id?`, `input_content`, `node_type`, `stop_point` (units), the node type's request fields, `request_digest` |
| `node.transition` | the binding envelope, `from`, `to`, `node_type`, `stop_point` (units), `evidence` (the row's claimed evidence), `stop_point_result?`, `markers?` |
| `operation.reserve` / `.spawned` / `.released` | `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`, `attempt_id`, `request_digest`, `invocation`, `expected_preconditions`, `retry_class` (`safe-retry`, `reconcilable`, `manual-only`); `.spawned` adds `identity` |
| `operation.result` | the binding envelope, the reserve fields, `outcome` (`succeeded`, `failed`), `producer`, `log_digest`, `identity`, `output_content` |
| `reconciliation.result` | the substituted record's `run_id`, `run_snapshot_digest`, `node_id`, `node_spec_digest`, `attempt_id`, `request_digest`; `reconciliation_outcome` (`succeeded`, `failed`, `unresolved`), `method` (`reconciliation`, `receipt-lookup`), `substitutes` (`operation-result`, `publish`; `dispatch-end` refused), `observed_content`, `receipt_ref` (receipt lookup only), `producer`, `result_digest`, `substituted_result` |
| `graph.diverged` | `run_id`, `prior_semantic_digest`, `observed_semantic_digest` (must differ), `successor_run_id` |
| `gate.result` | the binding envelope, `policy`, `purpose`, `binding`, `verdict`, `gate_exit` (consistent with `verdict`), `suite_exit`, `suite_invocation`, `input_content`, `producer`, `log_digest`, `output_content`; optional `totals`, `pre_*`/`post_*`, `reason`, `unit`, `round`, `input_isolation` |
| `review.recorded` | the binding envelope, `reviewer`, `request_id`, `reviewed_content_digest`, `verdict`, `findings_digest` |
| `publish.recorded` | the binding envelope, `stop_point`, `branch`, `outcome` (`published`, `failed`); `published` needs `sha`, and `pr` and `head_sha` (equal to `sha`) at `pr` or `merge`; `failed` needs `error_code`; inapplicable fields are absent or `null` |

A `substituted_result` holds the substituted kind's claimed result:
`{outcome, output_content, identity}` for `operation-result`, and the
`publish.recorded` fields with the same requiredness for `publish`. An
`unresolved` reconciliation carries neither `substituted_result` nor
`observed_content` and substitutes nothing.

**Assurance axes.** `input_isolation` (`endpoint-sampled` / `immutable`),
`capability_assurance` (`declared` / `enforced`), `atomicity` (`unproven` /
`atomic`), and `conformance` (`unproven` / `conformant`) may appear on any
schema-2 record. The journal refuses the strong (second) value from any
caller; an absent axis reads as weak, and every record reduces with every axis
weakest.

**Lifecycle, results, and markers.** Two axes and a marker set:

- lifecycle state: `ready`, `blocked`, `starting`, `running`,
  `unknown-outcome`; terminal `succeeded`, `failed`, `cancelled`, `parked`.
  An `attempt.begin` starts in `ready`. Nothing transitions out of a terminal
  state: a new `attempt.begin` (naming the latest attempt as
  `parent_attempt_id`, same `node_type`) starts a new attempt instead.
- stop-point result, carried only into `succeeded`: a unit's pinned stop
  point `worktree`, `commit`, `pr`, `merge` yields `reviewed-worktree`,
  `gated-commit`, `pr-open`, `integrated`; an investigation yields
  `informational`; operation and approval nodes carry none.
- markers `stale`, `superseded`, `landed-but-ungated`, carried by any node in
  any state and set by each transition; omitted, `null`, and empty all mean
  the empty set, duplicates are refused. A marker is never a result and never
  success.

**The guarded transition table.** Each `node.transition` carries its row's
claimed evidence under `evidence`; a row's specific entry wins, and the two
general rows apply only from a non-terminal state with no specific row to the
same target.

| from → to | claimed evidence |
| --- | --- |
| ready → starting | `selection_ref`, `authorization_ref`, `preconditions_digest` |
| ready → blocked | `request_ref` |
| blocked → ready | `answer_ref` (`answer`: `granted` or `answered`), `revalidation_digest` |
| blocked → failed | `answer_ref` (`answer`: `denied`) |
| blocked → parked | exactly one of `expiry_ref`, `no_permitted_actor: true` |
| starting → running | `identity`, `observation_ref` to this attempt's `operation.spawned` with that identity |
| starting → failed | `spawn_error`, `effect: "none"` |
| starting → blocked | `drift_ref`, `barrier_closed_ref` to this attempt's `operation.reserve`, with no `operation.released` for the attempt |
| running → blocked | `quiescence_ref`, `request_ref` |
| running → succeeded | `terminal_evidence` for the pinned row, and the pinned `stop_point_result` |
| running → failed | `failure_evidence` |
| running → unknown-outcome | `lost_child: true` |
| unknown-outcome → succeeded | optional `reconciliation_ref` (kind `reconciliation` or `receipt-lookup`; `attestation` refused), `terminal_evidence`, the pinned `stop_point_result` |
| unknown-outcome → failed | optional `reconciliation_ref` (as above), `failure_evidence` |
| unknown-outcome → parked | `unresolvable_reason` |
| any non-terminal → cancelled | `cancel_ref`, `quiescence_ref` |
| any non-terminal → parked | `park_reason` |

`attempt.begin` pins `node_type` and, for a unit, `stop_point`; every later
transition of the attempt must repeat them, so `terminal_evidence` is always
selected by the pinned values.

| node / stop point | `terminal_evidence` (each reference claims its content) |
| --- | --- |
| unit / worktree | `review_ref` (`verdict: pass`, `reviewer`) |
| unit / commit | `review_ref`, `gate_ref` (`verdict: green`, `input_content`), `branch`, `sha` |
| unit / pr | the commit row, `publish_ref` (`outcome: published`, `pr`, `head_sha` = `sha`) |
| unit / merge | the pr row, `pre_merge_gate_ref`, `integration_content`, `provider_receipt_ref` (`receipt_object`, `outcome: merged`), `receipt_object` (equal to the receipt's), `target_containment` `{target_ref, contains: true}` |
| investigation | `dispatch_ref`, `transcript_digest`, `report_digest` |
| operation | `operation_result_ref` (`outcome: succeeded`) |
| approval | `answer_ref` (`answer: granted`) |

`failure_evidence` is `{phase, failing_ref, reason}`: a unit's `dispatch`
(`dispatch-end` with a nonzero `exit`, or `dispatch-abandoned`), `review`
(`review`, `verdict: iterate`, `iteration_limit_reached: true`), `gate`
(`gate`, `verdict: red`), `publish` (`publish`, `outcome: failed`), or
`integrate`; an investigation's `dispatch`; an operation's `operation`
(`operation-result`, `outcome: failed`). An approval node has no `running →
failed` phase. `integrate` is admissible only for a unit pinned to `merge`
(any other pin is refused, `failure-phase`); its `failing_ref` is either the
pre-merge gate — a red `gate` whose claimed `input_content` equals the
`integration_content` that `failure_evidence` then also carries (a
difference is refused, `evidence-inconsistent`) — or a `provider-receipt`
with `outcome: refused`, which carries no `integration_content`.

**Relations.** For each pair that must concern the same content (review ↔
gate ↔ publication, and the pre-merge gate ↔ `integration_content`), exactly
equal claimed content is recorded `identity-claimed`, anything else —
including the same tree under a different head — `unproven`. At `commit`,
`pr`, and `merge`, each referenced candidate content (`review_ref`,
`gate_ref`, and at `pr`/`merge` `publish_ref`) is also related to the
terminal evidence's `sha`: `identity-claimed` only when it is git content
whose `head` equals `sha`, `unproven` otherwise (non-git content included),
so references that agree with each other but not with `sha` stay unproven.
Relations are recorded, never refused, and never read as identity.

**Resolved journal references.** A reference to an accepted `operation.result`,
`gate.result`, `review.recorded` or `publish.recorded` must agree with the
record's event, node and attempt. Its required `content` is always compared:

| reference kind | record field compared with reference `content` | other claims compared when present |
| --- | --- | --- |
| `operation-result` | `output_content` | `outcome` |
| `gate` | `input_content` | `verdict`, `input_content` |
| `review` | `content` (what was reviewed) | `verdict`, `reviewer` |
| `publish` | `content` | `outcome`, `pr`, `head_sha` |

An omitted claim is not a contradiction; a carried claim that the record
does not state is a contradiction. Required claims are still selected by the
vocabulary's evidence row. A resolving publication must also match the
attempt's pinned `stop_point` and, for success, the terminal evidence's
`branch`, mirroring the substitution path. Contradictions are refused as
`reference-contradicted`; unresolved digests remain claims. Only the accepted
prefix can resolve a reference, and guards remain `claimed`. A reconciliation
receipt's `outcome` may be omitted; when present, a `succeeded` reconciliation
requires `merged`, and a `failed` reconciliation requires `refused`.
A mismatch is refused by the vocabulary as `evidence-inconsistent` (including
through the journal CLI). An `unresolved` reconciliation constrains neither
receipt outcome and substitutes nothing.

**Late records and reconciliation.** An exit from `unknown-outcome` carries
the full row evidence. Without `reconciliation_ref`, the operation-result or
publish reference must resolve to an already accepted record of this attempt;
an unresolved digest is refused (`reconciliation-required`). Rows without a
substitutable slot remain park-only in both success and failure directions.
This late-record form carries `evidence: {terminal_evidence: ...}` for success
(and the pinned `stop_point_result`), or `evidence: {failure_evidence: ...}`
for failure, with the resolving reference present in that full evidence.
Alternatively, exactly one missing reference
of the pinned row may be replaced by the `reconciliation_ref`'s record:
`publish_ref` (unit `pr`/`merge`) or `operation_result_ref` (operation) into
`succeeded`, the `failing_ref` of a `publish` or `operation` phase into
`failed`. The record must belong to the attempt (in `unknown-outcome`), its
`method` must equal the reference's kind, its `reconciliation_outcome` must
match the transition, and its outcome pair must agree (`succeeded` ↔
`succeeded`/`published`, `failed` ↔ `failed`), with `observed_content` equal
to the substituted content. An `operation-result` substitute's
`request_digest` must be one of the attempt's `operation.reserve` requests; a
`publish` substitute's is recomputed from `{stop_point, branch, content}` with
the pinned stop point. The substitution is refused when a record of that kind
already exists for the attempt and request (agreeing or not), when two
reconciliations substitute the same record, or when the reference is present;
a record of that kind arriving after the substitution is refused. A lost
dispatch cannot be substituted (schema-1 `dispatch.end` has no binding): it
can only be parked.

**The reducer** (`reduce.py`, pure). `reduce_run(events, *, run=None)` returns per-node
state, `stop_point_result`, markers, guards (all `claimed`), transitions with
their relations, per-record axes (weakest) and declared `unit`/`round`
attribution, `rejected` records with a reason code, `unknown_schema`
positions, `degraded`, and `gates` with `gate_ineligibility` reasons —
`binding-changed`, `binding-unavailable`, `isolation-weak`,
`verdict-not-green`, `verdict-inconsistent`, `envelope-missing` — each rule
contributing its own reason. Schema-1 records reduce with every axis weakest
and are never completion evidence. `completion_eligible` is always false.
The optional keyword `run=ID` binds the expected journal run. A schema-1 or
schema-2 line carrying another string `run` is refused as `run-mismatch`.
Without `run=`, the first recognized-schema line carrying a string `run`
pins it, so a foreign first line can cause later genuine lines to be refused;
callers that know the segment id should pass it. For compatibility, even
with `run=`, a schema-1 line whose `run` is absent or non-string remains
`legacy`; `read-run` instead exits 6 for that shape. Schema-2 lines still
require a string envelope `run`.
Across records it also refuses: a record naming an attempt with no
`attempt.begin`, or disagreeing with that attempt's `node_id`, `run_id`,
`run_snapshot_digest`, or `node_spec_digest`; a second open attempt for a
node; a `run_snapshot_digest` other than the run's first; a transition of a
superseded attempt or from a state the attempt is not in; an
`operation.spawned`, `.released`, or `.result` with no matching
`operation.reserve`; and any new attempt after `graph.diverged`.
Relevant rejection codes include `run-mismatch` (foreign string run),
`reference-contradicted` (a resolving reference disagrees with its record or
publication pin/branch), `reconciliation-required` (an unresolved late-record
reference without reconciliation), `substitution-kind` (no substitutable slot;
park only), `substitution-not-absent` (a real record already exists), and
`substituted` (a late record arrives after substitution).

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

---

## 6. Authority store (task-graph-v1 sub-unit 0a.2)

Authority is `scripts/loop-authority` (the writer) over `lib/loopauth/`
(`records.py`, `keys.py`, `frame.py`, `store.py`, `anchor.py`, `recover.py`,
`ceremony.py`, `registry.py`, `tools.py`). `scripts/loop-authority-verify` is
an independent verifier that imports nothing from `lib/loopauth`. Both are
stdlib-only python3: each bash wrapper writes nothing (no directory, no
heredoc temporary file) and only runs `python3 -I -B` on the entry file beside
its real path (`scripts/loop-authority.py`, `scripts/loop-authority-verify.py`),
whose first act -- after refusals that need no file -- is to create its
scratch directory with `O_NOFOLLOW` on every component (a symlinked
`$HOME/.cache` component is refused, exit 9). The writer imports `lib/loopauth`
only from the `lib/` beside its real `scripts/` directory and refuses a
symlinked `lib/` (exit 9).

### Layout

    $HOME/.config/olddonkey-loop/authority/        0700
      lock                       the writer's exclusive flock
      active                     canonical {store_id, generation}
      genesis.intent             only during authority genesis (A2.3)
      regenesis.intent           only during linked re-genesis (A1.3)
      stores/<store_id>/
        log/segment-000001.olf   framed records
        keys/epoch-<n>-<16 hex>/ root, root.pub, and per type <type>,
                                 <type>.pub, <type>-cert.pub
        intent                   the durable write intent (frame 2 on)
        cursor                   recovery hint only
        quarantine               canonical {store_id, rule, position, detail}
      archive/<store_id>/        an archived generation: dirs 0500, files 0400

Every file is 0600, owned by the current uid, `nlink == 1`, and opened with
`O_NOFOLLOW`; no path component below `$HOME` may be a symlink. Scratch space
is outside it: `$HOME/.cache/olddonkey-loop/tmp/<pid>-<16 hex>` (the process
`TMPDIR`; the inherited `TMPDIR` is never used) and a fresh
`$HOME/.cache/olddonkey-loop/anchor-scratch/<pid>-<16 hex>.git` per
transaction, whose `config` must hold only `[core]`. The verifier uses
`$HOME/.cache/olddonkey-loop/verify/<pid>-<16 hex>` and deletes it. A2.4
abandonment deletes nothing: it removes the intent, and the intent-named
store directory stays, permanently unpublished -- named by neither `active`
nor any intent, never read as authority, reported by `status` under
`unpublished.stores`, and never renamed or removed.

### Records and frames

A payload is canonical JSON `{type, v: 1, store_id, generation, seq, epoch,
key_id, prev, body}`: `epoch` is the epoch whose subkey sealed it, `key_id`
that subkey's `SHA256:` fingerprint, `prev` the previous record digest (null
at seq 1). A frame is `OLF1 <seq> <type> <length> <digest>\n` + content +
`\n`, content = canonical `{payload, sig}`, `<digest>` = `sha256:` over
`OLF1 <seq> <type> <length>` then the content. That digest is the record
digest (`prev`, the pointer's `record_digest`, the intent's `digest`).

The closed type list (`records.TYPES`): `store.genesis`, `epoch.rotated`,
`epoch.revoked`, `store.regenesis`, `request.opened`, `request.cancelled`,
`request.expired`, `request.redeemed`, `nonce.issued`, `repo.registered`,
`repo.rebound`, `exec-root.registered`, `standing.granted`,
`standing.revoked`, `entry.enrolled`, `entry.revoked`, `platform.designated`.
Segment reset, mechanism closure, and release acceptance are never types.
Bodies:

| type | body |
| --- | --- |
| `store.genesis` (seq 1, generation 1) | `ceremony`, `envelope_digest`, `principal`, `remote`, `anchor_ref`, `anchor_class`, `commit_identity`, `epoch: 1`, `key_dir`, `root_pub`, `root_key_id`, `subkeys` (one key_id per type), `registry_version`, `admitted_protocols` |
| `store.regenesis` (seq 1, generation > 1) | the genesis fields plus `prev_generation` (the parent pointer's `{store_id, generation, last_seq, last_record_digest}`), `prev_commit`, `quarantined {last_seq, last_record_digest}` (the archived store's valid prefix), `archive` |
| `epoch.rotated` | `ceremony`, `envelope_digest`, `principal`, `remote`, `from_epoch`, `epoch`, `key_dir`, `root_pub`, `root_key_id`, `subkeys`, `registry_version`, `admitted_protocols`; sealed by the active (old) epoch |
| `epoch.revoked` | `ceremony`, `envelope_digest`, `principal`, `epoch`, `prior_state` (`active` or `verify-only`); sealed by the active epoch |

**The activation boundary** (A2.1, A2.6). Every epoch introducer
(`store.genesis`, `epoch.rotated`, `store.regenesis`) carries
`registry_version` and `admitted_protocols`, both in the canonical envelope
its ceremony displays (and whose digest is `envelope_digest`).
`ALLOWED["tg-v1.0a"] = {types: [store.genesis, epoch.rotated, epoch.revoked,
store.regenesis], protocols: []}` is the only version 0a knows, so every 0a
introducer carries `tg-v1.0a` and `[]`; another version (`introducer-version`)
or a nonempty list (`introducer-protocols`) is refused. A version is never
lower than its predecessor epoch's; within a generation the protocols and the
admitted type set only grow (`introducer-types`). A record of any type is
valid only if its epoch introducer's version admits the type, decided from
the envelope before any body schema (`type-not-admitted`): a validly sealed
record of any other certified type makes the store invalid (quarantine). The
writer and the verifier each implement these checks with their own code.

`principal = {kind: operator-tty, tty, start_token: {boot_id, pid,
start_time}}` (A1.1, A1.8) is evidence of a terminal session, never of human
approval. `remote` is the genesis-pinned URL, copied unchanged by every
rotation and re-genesis. `anchor_class` (`production` for `git@host:path.git`
and `https://host[:port]/path.git`; `test` for `file:///path`, accepted only
with `LOOP_AUTHORITY_TEST=1`) is derived from that remote and checked against
it; a test lineage never gives current authorization.

### Keys and seals

Each epoch has an Ed25519 root and one Ed25519 subkey per type, certified by
the root with key identity `<type>@e<epoch>`, principal `<type>`, validity
`always:forever`. A seal is `ssh-keygen -Y sign -f <type>-cert.pub -n
olddonkey-loop.authority.<type>.v1` (the certificate path makes ssh-keygen
embed the certificate; the private half beside it signs). Verification
requires ssh-keygen to accept the line `<type>
cert-authority,namespaces="olddonkey-loop.authority.<type>.v1" <root.pub>`
and, parsed from the signature itself, a user certificate signed by exactly
the pinned root, identity `<type>@e<epoch>`, principals `[<type>]`, no
critical options, and a subject fingerprint equal to the payload `key_id` and
to the epoch's `subkeys[type]`. Roots are pinned only from the genesis,
re-genesis, and rotation records. Key files are created in a key directory
with a random suffix and published without replacement (temp, fsync, link,
dir fsync, unlink temp, dir fsync); a directory no epoch record names is
unpublished and never read. Every published directory must hold exactly the
root and the per-type files, matching its record, or the store is
quarantined. Key states: `active -> verify-only` (rotation), `active ->
revoked`, `verify-only -> revoked`.

### The anchor

One ref, `refs/olddonkey-loop/anchor`, in the pinned remote. Each commit
carries one file, `anchor.json` = canonical `{active, prev_generation, sig}`
with `active = {store_id, generation, genesis_digest, seq, record_digest,
epoch, key_id}`. `active.epoch` and `key_id` name the root that signs the
pointer: the epoch active after the record (the new root for genesis,
re-genesis, and rotation), or, for the revocation of the active epoch, the
revoked root itself (its last act). The signature is by that root over
canonical `{active, prev_generation}` under `olddonkey-loop.anchor.pointer.v1`.
`prev_generation` is non-null only on a generation's first pointer. The
commit is deterministic: tree = one entry `100644 anchor.json`, author and
committer `olddonkey-loop <anchor@olddonkey-loop.invalid>` at `@<seq> +0000`,
message `anchor <store_id> g<generation> s<seq>`. Every git run has an
allowlisted environment and `-c core.hooksPath=/dev/null -c
core.fsmonitor=false`, plus the pinned transport's options where the remote
is contacted (0a.2 section 4).

### Write intents and the write protocol

The store intent (`stores/<id>/intent`) is canonical `{seq, offset, length,
digest, expected_parent, anchor_json, anchor_commit, frame_length,
frame_b64}`: A1.6's fields plus the exact frame bytes (as A2.3 gives
`genesis.intent`), so a torn tail is compared byte for byte. `anchor_commit`
is the commit id rebuilt from `anchor_json` and `expected_parent`.
`genesis.intent` adds `store_id`, `key_dir`, `remote`; `regenesis.intent`
adds `old` (the linked old pointer), `old_commit`, `new_store_id`, `key_dir`,
`archive`, `remote`.

Write protocol (lag 0): seal the record and its pointer and build the commit
(stages 1-3 bound); write and fsync the intent; append and fsync the frame;
push, fast-forward from `expected_parent` only; read back by content; remove
the intent; write the cursor. Genesis: store and key directories, keys,
`genesis.intent`, frame 1, push, readback, `active`, remove the intent.
Linked re-genesis: new store and keys (inert), `regenesis.intent`, the new
frame 1, push (the commit point), archive the old store read-only, `active`,
remove the intent. An archived generation verifies as history: its valid
prefix (up to the invalid frame or nonconforming tail that quarantined it,
which stays as evidence) and its quarantine marker; the re-genesis record's
link and `quarantined` must name that prefix.

In A2.3's frame-1 classes, a missing intent-named store directory is never
`none`: the ceremony creates it before its intent and nothing removes it,
so without it nothing shows that frame 1 never became durable (it may have
been pushed and then deleted with the ref). It is A2.3 row 1
(`genesis-invalid`; for re-genesis, `regenesis-invalid`): fail closed,
nothing mutated, in the writer and the independent verifier alike. A2.3 row
6's only sink removes `genesis.intent` (re-genesis abandonment:
`regenesis.intent`).

### States

`loop-authority status` and `verify`, and the verifier, print one JSON
object: `state`, `table` (the A1.2 / A1.6 / A2.3 row), `row` (the recovery or
finish row that applies next), `rule` (the rule a quarantine names, e.g.
`type-not-admitted`), `authorizing_state` (the state itself would
authorize), `current_authorization` (and the lineage is production and no
test binaries are in use), `test_only`, `unpublished` (`key_dirs`,
`stores`), and for terminal states `evidence`. `recover` adds `steps`: each
row it ran, with the state and table that triggered it (the first is its
classification of the state it found).

| state | meaning |
| --- | --- |
| `none` | no active store and no intent |
| `committed` | `R.active = ptr(L)`; a stale cursor alone never changes it |
| `needs-recovery` | a torn tail (truncation) or a residual intent (tidy) |
| `pending` | remote unreachable, or replay-forward needed |
| `quarantined` | a marker, or a quarantine row of A1.2 / A1.6 / A1.7 / A2.3 |
| `genesis-pending` | A2.3 rows 4, 6, 7, 8, 9 |
| `genesis-invalid`, `anchor-mismatch`, `genesis-quarantined` | A2.3 rows 1, 2, and 3/10/11 with `active` absent: terminal |
| `regenesis-pending` | remote unreachable, or abandon/complete on exact state |
| `regenesis-invalid`, `regenesis-quarantined` | the intent does not validate (or its new store directory is missing), or the remote is neither the recorded old commit nor the intent's exact new one: fail closed, both stores untouched |
| `active-invalid` | the active marker or the lineage does not load |

Writer exit codes: 0 ok, 2 usage, 3 lock busy, 4 refused, 5 pending or needs
recovery, 6 quarantined, 7 terminal, 8 dormant row, 9 environment, 10
`approval.consume`, 11 TTY or challenge, 12 invalid, 137 test crash point.
The verifier uses 0, 5, 6, 7, 9, and 12 with the same meanings.
Both `verify` commands return 12 for `none`; an absent authority store is not
verified. `status` remains informational (exit 0), and recovery may return 0
after safely abandoning an unpublished genesis.

A remote/local disagreement may leave `quarantined` with no admitted linked
re-genesis: `ceremony regenesis` then refuses `regenesis-unlinkable` (exit 4)
because the remote pointer is not in the local valid prefix. Rollback, fork,
foreign-store and remote-ahead cases can reach this condition. Current behavior
is intentionally preserved and tested: no new terminal classification or
lineage-discarding reset is provided. A lineage-preserving exit remains an
owner/specification decision; deleting local authority files is not a repair.

### Rows and tokens

`registry.py` holds all 26 rows (tg:809-829 and A1.3) with their six columns
as the accepted matrix writes them, and the exclusions X1-X7 of tg:874-880 in
their written order (X7 on every derived row). 0a.2 admits genesis,
rotation, revocation, head advance, torn-frame truncation, replay-forward,
tidy, quarantine, and re-genesis; the other 17 rows are dormant.
`loop-authority submit <row>` refuses every dormant row with
`dormant-row:<row>` (exit 8) and `approval.consume` (exit 10) before touching
anything. Tokens come only from `store.begin` (ceremonies), `store.child`
(compound children), and `store.begin_recovery` / `store.begin_finish`
(only `recover._mint` calls them), whose one input is a plan object
`observe()` issued: no path accepts a caller-built binding. Minting spends
the plan (a replayed plan is refused), requires the local state it
observed, and observes the files and the remote afresh; only when that
observation decides the same row, parameters, and remote evidence is the
binding derived -- the row, the observed local state, the remote tip
verified by content (or that the remote was not read, which only a
quarantine decided from local files alone may carry), and the row's exact
sink parameters (a finish token's targets come from the validated intent).
Every destructive sink re-proves it from the files and the remote; the
quarantine marker is written only after one more fresh observation names
its offending position and rule. The revocation of an epoch binds that
epoch's prior state as observed in the store's own log, the active epoch,
and its record's sequence and offset; its `store-quarantine` child opens
only when that state was `active`, and writes only the marker
`{store_id, rule: active-epoch-revoked, position: {seq}}` of that record,
after checking that the log holds the bound, read-back revocation record
revoking its own sealing epoch from `active`. Every token-checked sink is
in `store.SINK_FUNCTIONS`; each grants itself a one-shot permit that the
low-level write or `tools.run` consumes.

Intents and markers publish a fsynced temporary by rename under the exclusive
writer lock, after refusing an existing target. They never have the two-link
publication window; inert key files retain their no-replace hard-link protocol
inside unpublished key directories. All file and directory syncs use the same
`_durable_fsync` helper: Darwin requests `F_FULLFSYNC`, other hosts use `fsync`.
On macOS the authority directory must be on a filesystem that supports
`F_FULLFSYNC` for its files and directories. An unsupported full sync is a hard
environment failure (exit 9); there is no fallback to `fsync`, and a directory
created before that failure may remain.
This is ordering evidence from code and tests, not a simulated power-loss proof.
Transport timeouts and malformed remote-ref replies stay pending; only verified
content/chain contradictions quarantine. Local tool timeouts are environment
failures (exit 9). Writer and verifier select only the exact advertised
`refs/olddonkey-loop/anchor` name; both fetch with
`+refs/olddonkey-loop/*:refs/readback/*`. The writer stages the bound commit
as the sole ref under `refs/olddonkey-loop/` in its scratch repository, then
pushes `refs/olddonkey-loop/*:refs/olddonkey-loop/*` without force. These pattern
refspecs do not tail-match `refs/heads/refs/olddonkey-loop/anchor`. An advertised
anchor whose successful fetch leaves a missing or malformed readback ref is
pending (exit 5); an absent advertised anchor is classified by the existing
absent-anchor recovery rows.

### Test seams (`LOOP_AUTHORITY_TEST=1` only)

`file://` remotes; `LOOP_AUTHORITY_CRASH_AT=<point>` (`after-intent-fsync`,
`frame-byte-<n>`, `after-frame-fsync`, `after-push`, `after-readback`,
`after-intent-remove`, `genesis-step-<1..5>`, `genesis-step-6a`,
`genesis-step-6b`, `regenesis-step-<1..5>`, for genesis and rotation
`after-store-dir` and `key-step-<1..53>`, and in recovery
`recovery-after-delimiter`; primitive cuts `fs-create-after-temp-fsync`,
`fs-create-after-rename` (legacy first-create cuts retained),
`fs-create-intent-after-temp-fsync`, `fs-create-intent-after-rename`
(genesis, rotation, revocation, and re-genesis intents),
`fs-create-marker-after-temp-fsync`, `fs-create-marker-after-rename`
(revocation and recovery quarantine markers), `fs-replace-after-temp-fsync`,
`fs-replace-after-rename`, `archive-after-rename`, and
`archive-after-readonly`), whose only effect is `os._exit(137)`; and `LOOP_AUTHORITY_TEST_BIN_DIR` (wrapper fixtures searched
before the binary allowlist; refused for every mutation of a production
lineage -- genesis before it creates a key or an intent, recovery, and every
ceremony -- so a lineage a test seam touched is test forever; read-only
classification may use it and then reports `test_only`).

The normal authority selftest derives real crash/recovery cases for every
command from `CRASH_APPLICABLE`, compares it with an independently written
point inventory (including the scenario-specific revocation and re-genesis
lists), checks single-link publication and a second
recovery converging, and compares the independent verifier. The sharded CI
matrix still exhausts frame-byte cuts. CI also runs the authority suite on
macOS to exercise the Darwin start-token and durability paths.

### Claimed references (sub-unit 0a.3)

`loop-authority refs --workspace <path> --run <run_id>` verifies a run's
claimed references, read-only. It reads the run's segment exactly where
`loop-journal` keeps it (`journal/<sha256(realpath(workspace))>/runs/<run>.jsonl`,
`lib/loopauth/journal_read.py`: the same ownership, mode, and no-symlink
checks, `O_NOFOLLOW | O_NONBLOCK` (a FIFO is refused without waiting), never `meta.lock`, and no repair -- a torn last line is
left out and reported as `torn_tail_bytes`, a mid-file invalid line fails
closed), reduces it with 0a.1's reducer (unchanged), classifies every claim
of every record the reducer accepted (`refs.py`), lays the outcomes over the
reducer's guards (`eligibility.py`, pure), and reads the store only through
0a.2's read-only classification (`recover.classify_stable`, wrapping the
classifier that `status` runs, without its reader lock). It prints one canonical
JSON object -- `run`,
`workspace`, `workspace_key`, `vocabulary`, `journal` (`lines`,
`torn_tail_bytes`, `degraded`, `unknown_schema`, the reducer's `rejected`),
`store`, `claims`, `nodes`, `completion_eligible` -- and exits 0 whenever it
prints it; 2 for a workspace that is not a directory, a malformed run id, or
a run with no segment; 9 for an environment or output error (including closed
stdout); 12 for a journal it cannot trust or a claim the map does not list.
Stable classifier faults retain their coded errors, as with `status`.
It admits no row and writes nothing to the journal store, the
authority directory, or the remote (its only writes are 0a.2's process
scratch under `$HOME/.cache/olddonkey-loop`, removed on exit); it takes
neither the authority lock nor the journal's, so no writer waits on it; and
the registry selftest's reachability scan proves that `refs.py`,
`eligibility.py`, and `journal_read.py` reach no sink.

Two dimensions, never mixed:

- **Claim validity.** Every request, answer (any claimed outcome), and expiry
  reference and every `review.recorded` `request_id` is `rejected`, reason
  `rows-dormant`: A2.1 keeps every request row dormant through 0a and every
  0a epoch admits no request protocol, so no admitted row could have
  produced the record it names, whatever the store holds (a response without
  a redeemed capability is rejected, not unattributed). Every other
  reference and evidence field is `claimed`. Nothing is `verified`: the
  positive verification rules arrive with the units that admit the records
  they verify (A2.1: units 7, 8, 9, 12).
- **Store state.** `current` (committed: anchored, and not pending,
  quarantined, or in a bootstrap terminal state) or `unavailable` with its
  reason: `absent`, `pending`, `changing` (no stable observation within the
  attempt bound), `remote-unreachable` (a pending state whose
  remote could not be read), `quarantined` (also for
  `regenesis-quarantined`), `genesis-invalid`, `anchor-mismatch`,
  `genesis-quarantined`, and the classifier's two other fail-closed states
  under their own names, `active-invalid` and `regenesis-invalid`. It is
  reported with the `classification`, its `table` and `rule`, the `lineage`
  (`production` or `test`; null when no lineage was read), `test_only`, and
  `current_authorization`. It is context: it never changes a claim.

The closed reference map (`refs.REFERENCE_MAP` by reference kind,
`refs.FIELD_MAP` for every other claim); a kind, field, event, or store
classification it does not list is an error, never a silent claim:

| reference kind (the 0a.1 fields that carry it) | names | validity in 0a |
| --- | --- | --- |
| `request` (`request_ref`) | a `request.opened` record | rejected (`rows-dormant`) |
| `answer` (`answer_ref`, any claimed outcome; the approval row's `answer_ref`) | a `request.redeemed` record | rejected (`rows-dormant`) |
| `expiry` (`expiry_ref`) | a `request.expired` record | rejected (`rows-dormant`) |
| `cancel` (`cancel_ref`) | a node cancellation (tg:296); no record type in Phase A | claimed |
| `authorization` (`authorization_ref`) | an effect authorization (units 3, 7, 8) | claimed |
| `selection` (`selection_ref`), `drift` (`drift_ref`) | coordinator decisions (unit 10) | claimed |
| `quiescence` (`quiescence_ref`), `operation-spawned` (`observation_ref`), `operation-reserve` (`barrier_closed_ref`) | process guards (unit 9, P5) | claimed |
| `review`, `gate`, `publish`, `provider-receipt`, `operation-result`, `dispatch`, `dispatch-end`, `dispatch-abandoned` (the `terminal_evidence` references, every `failing_ref` alternative, and `reconciliation.result`'s `receipt_ref`, kind `provider-receipt`) | journal records (units 6, 9) | claimed |
| `reconciliation`, `receipt-lookup` (`reconciliation_ref`); `attestation` (no field: 0a.1 refuses it there, tg:294) | journal records (unit 9) | claimed |

| other claim | validity in 0a |
| --- | --- |
| `review.recorded`'s `request_id` (names the `request.redeemed` that answered it) | rejected (`rows-dormant`) |
| `attempt.begin`'s pinned `node_type` and `stop_point` (node spec, unit 5) | claimed |
| `identity`, `target_containment`, `integration_content`, `receipt_object`, `branch`, `sha`, `no_permitted_actor`, `phase`, and every digest and text field (`preconditions_digest`, `revalidation_digest`, `transcript_digest`, `report_digest`, `spawn_error`, `effect`, `lost_child`, `park_reason`, `unresolvable_reason`, `reason`) | claimed |

`terminal_evidence` and `failure_evidence` are walked, never classified
themselves; the one reference a reconciliation replaced is a claim of the
substituted kind (`substituted_by: reconciliation_ref`). Each claim carries
its report-local `id` (the key referenced by `refuted_by`), its originating
`field`, and `substituted_by` (a replacement field name or null), plus its
record's `position`, `seq`, `event`, `node_id`, and `attempt_id`, its
`path` and the reducer's `guard` (null for a record's own field), `kind`,
`digest`, the reference's own claims (`claims`, e.g. `answer`), `names`,
`authority`, `validity`, and `reason`. Per node (its latest attempt, as the
reducer reports it): each guard's `status` (`claimed`, or `rejected` with its
`reason`); `refuted`, set when any of the node's authority claims in any of
its attempts is rejected, with `refuted_by` listing them; and
`completion_eligible`, the constant `false` of 0a -- an explicit gate, not
derived from the guards, so a node with no reference at all is ineligible
too.

The lock-free store observation compares a local-state digest before and after
classification, making at most three attempts. Any classification exception is
retried if the after-digest differs or cannot be taken; identical digests
re-raise the exception. A first-attempt `pending` plan whose remote read failed
is retried too, since the remote may have moved between `ls-remote` and `fetch`.
If no attempt produced two digests, the last error is re-raised. Otherwise, if
no stable read is obtained it reports `unavailable` with reason `changing` and
`current_authorization: false`. This is an observation, not synchronization:
a later ceremony can still change the store after the report. It never acquires
the writer lock.

The refs command validates the journal and claims before establishing scratch
space. Invalid input leaves no new cache directory. Valid observations may leave
the parents `$HOME/.cache/olddonkey-loop/tmp` and
`$HOME/.cache/olddonkey-loop/anchor-scratch` after their scratch entries
are cleaned; “read-only” refers to authority, journal and remote contents. The
canonical report is written as UTF-8 bytes, independent of stdout's locale codec.

The classifier owns the closed `recover.STATES` tuple. `Plan` checks it during
construction and later state assignments; the refs selftest compares the keys
of `refs.CLASSIFICATIONS` directly with that tuple.
