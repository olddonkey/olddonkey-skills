# Loop backend state schema

Normative inventory of production state written by the four adapters, plus
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

**Root layout** (`scripts/loop-journal:387-403`):

`$HOME/.config/olddonkey-loop/journal/<workspace-key>/`

`workspace-key` is `sha256(canonical workspace)` (`scripts/loop-journal:372-373`).
The store contains `runs/`, `runs.tsv` (rebuildable cache), `context`,
`unattributed.jsonl`, `generation`, and `meta.lock`. Retired context files are
`context.retired-<run-id>` (`scripts/loop-journal:979`).

**Segment naming** (`scripts/loop-journal:476-479`):
`runs/<run-id>.jsonl` where `<run-id>` is `YYYYMMDDTHHMMSSZ-` plus 6 hex
digits (`scripts/loop-journal:65`).

**Envelope fields** (`scripts/loop-journal:72`): `schema`, `seq`, `ts`,
`event`, `run`, `attribution_failure`. Attributed schema-1 lines carry
`schema=1`, monotonic `seq`, UTC `ts`, `event`, and `run`
(`scripts/loop-journal:994-1000`). Unattributed lines omit `seq` and record
`attribution_failure` (`scripts/loop-journal:1014-1019`). Schema-2 lines carry
the same envelope with `schema=2` and are never unattributed (see
[Schema 2](#schema-2-task-graph-v1-vocabulary-tg-v10a1) below).

**Closed event list** (schema 1, `scripts/loop-journal:73-142`):

`run.begin`, `run.end`, `unit.begin`, `unit.end`, `round.begin`,
`checkpoint`, `review.recorded`, `publish.recorded`, `dispatch.start`,
`dispatch.end`, `dispatch.abandoned`, `gate.result`, `journal.repaired`.

**Segment classification** (`scripts/loop-journal:497-522`): an unterminated
valid tail line counts; an unterminated invalid tail is ignored (torn write);
a newline-terminated invalid line mid-file or at the tail is mid-file
corruption. The index uses this classification and never repairs; a
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

Intended mechanical writer: `scripts/run-gate.sh` — `journal_gate_result`,
called from `emit_result` after the `RESULT:` line is printed and before the
gate exits. It writes nothing when the journal helper is absent, and a failed
append only warns; neither changes the gate's exit. Validation is the
`gate.result` entry of `EVENT_SPECS` (`scripts/loop-journal:117-140`). The
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
already carry them (`attribution_from_env`, `scripts/loop-journal:748`); an
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
neither open nor closed (`duplicated_dispatch_ids`,
`scripts/loop-journal:1365`). Otherwise each acknowledged id has exactly one
start and no terminal event, and its `dispatch.abandoned` copies that start's
`unit`/`round` when present and writes neither when absent
(`abandoned_payload`, `scripts/loop-journal:1388`).

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
Verification against the authority store is later work (sub-unit 0a.3).

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
| unknown-outcome → succeeded | `reconciliation_ref` (kind `reconciliation` or `receipt-lookup`; `attestation` refused), `terminal_evidence`, the pinned `stop_point_result` |
| unknown-outcome → failed | `reconciliation_ref` (as above), `failure_evidence` |
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
| unit / merge | the pr row, `pre_merge_gate_ref`, `integration_content`, `provider_receipt_ref` (`receipt_object`), `receipt_object` (equal to the receipt's), `target_containment` `{target_ref, contains: true}` |
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

**Reconciliation.** Out of `unknown-outcome`, exactly one missing reference
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

**The reducer** (`reduce.py`, pure). `reduce_run(events)` returns per-node
state, `stop_point_result`, markers, guards (all `claimed`), transitions with
their relations, per-record axes (weakest) and declared `unit`/`round`
attribution, `rejected` records with a reason code, `unknown_schema`
positions, `degraded`, and `gates` with `gate_ineligibility` reasons —
`binding-changed`, `binding-unavailable`, `isolation-weak`,
`verdict-not-green`, `verdict-inconsistent`, `envelope-missing` — each rule
contributing its own reason. Schema-1 records reduce with every axis weakest
and are never completion evidence. `completion_eligible` is always false.
Across records it also refuses: a record naming an attempt with no
`attempt.begin`, or disagreeing with that attempt's `node_id`, `run_id`,
`run_snapshot_digest`, or `node_spec_digest`; a second open attempt for a
node; a `run_snapshot_digest` other than the run's first; a transition of a
superseded attempt or from a state the attempt is not in; an
`operation.spawned`, `.released`, or `.result` with no matching
`operation.reserve`; and any new attempt after `graph.diverged`.

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
On a successful result, new paths the real repository ignores are deleted
from the work copy before the diff (`:423-501`). `changes.patch` is
implement-only after a successful post-copy walk (`:510-526`); it is the raw
pristine-vs-work diff, applied with `git apply -p2` and never rewritten.
`apply-check.log` / `apply.log` are written only on the successful nonempty
apply path (`:528-534`). Disposable copies
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
| changes.patch | backends/cursor/dispatch.sh:517 | absent | present | absent | present | present | raw pristine-vs-work patch; implement-only |
| apply-check.log | backends/cursor/dispatch.sh:530 | absent | absent | absent | absent | present | git apply --check output; successful nonempty apply |
| apply.log | backends/cursor/dispatch.sh:534 | absent | absent | absent | absent | present | git apply output; successful nonempty apply |

### Claude

State root pattern (`backends/claude/dispatch.sh:141-143`):

`<git-common-dir>/olddonkey-loop/claude/<dispatch-id>/`

The dispatch id is `YYYYMMDDTHHMMSSZ-` plus 6 hex digits. The directory is
created at `backends/claude/dispatch.sh:186` and the git-less copies live under
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
| project-files.zlist | backends/claude/dispatch.sh:190 | present | present | present | present | present | NUL-separated git ls-files paths |
| prompt.txt | backends/claude/dispatch.sh:272 | present | present | present | present | present | UTF-8 preamble plus prompt |
| stream.jsonl | backends/claude/dispatch.sh:338 | absent | present | present | present | present | child stream JSONL; created at :338 |
| stderr.log | backends/claude/dispatch.sh:338 | absent | present | present | present | present | child stderr; created at :338 |
| last-message.txt | backends/claude/dispatch.sh:398 | absent | absent | present | present | present | exact result string, no added newline; written at :398 |
| changes.patch | backends/claude/dispatch.sh:722 | absent | absent | absent | present | present | raw pristine-vs-frozen patch; implement-only |
| apply-check.log | backends/claude/dispatch.sh:736 | absent | absent | absent | absent | present | git apply --check output; nonempty patch only |
| apply.log | backends/claude/dispatch.sh:742 | absent | absent | absent | absent | present | git apply output; nonempty patch only |

---

## 3. Correlation rule

Journal `dispatch_id` correlates to a state-directory basename by **exact
match only**. The adapters use the same id as the directory name
(`backends/codex/dispatch.sh:742` and `:770`;
`backends/grok/dispatch.sh:186` and `:452`;
`backends/cursor/dispatch.sh:161` and `:163`;
`backends/claude/dispatch.sh:141` and `:143`). Timestamp-proximity
correlation is forbidden (v2 non-goal). A state directory whose basename
matches no journal `dispatch.start` is **unattributed state** and is
displayed as such. A journal dispatch whose directory is absent is
`state_dir=missing`. When `git` or the git common dir cannot be resolved,
claude, grok, and cursor state read as `unavailable` — not an error, and not a
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
| claude | named artifact mtimes in the dispatch dir | backends/claude/dispatch.sh:186 |
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
