# collab-canvas-v1

**Status: ACCEPTED** — Codex read-only adversarial review, 8 rounds,
2026-10-01 (record and the falsifier carried into implementation in §12). It
records a product direction the user stated on 2026-08-20 that no plan had
carried since. Nothing here is implemented. §10 records the three decisions
the user settled on 2026-09-30.

**Executable scope.** Units 0–3 and the two falsifier stages (§7, §8). Units
4–8 and §5 are direction only; each unit there needs its own reviewed kickoff
document before any dispatch.

## 0. Provenance

**The goal, in the user's words** (session "task-graph-v1 评审流程", 2026-08-20):

> 可以让大家不需要会用 codex，claude code 这些，通过 UI 画画线连起来就可以做这样的跨 agent 协作

and (session "项目差异对比", 2026-09-26) the picture is a flow diagram of the
loop where "可以拖动线改动".

**Three answers the user gave on 2026-08-20**, which this plan treats as settled:

| question | answer |
| --- | --- |
| who is the user | both, in different roles: people who do not write code draw, start, and watch; engineers hold review and approval |
| what a run produces | code only for now; the node model leaves room for other products |
| where agents run | on a local machine, with that machine's own CLIs and keys |

**Citations.** Code is cited against `direction-u5-card-followups` @ `d28e796`
(the head of PR #64, which is the base this plan's units build on, per §10
decision 1). Paths are relative to `skills/implementation-loop/` unless they
start with `AGENTS.md`, `build.sh`, `.github/`, `skills/`, or `plans/`. Plans
are cited against `direction-plan` @ `e16607b`. A claim marked *assumed* has
not been checked and must be before the unit that depends on it is dispatched.

## 1. What this is

A canvas, served from an engineer's machine, on which someone draws units of
work and connects each to the agents that will write and judge it. A
coordinator on that machine then runs the implementation loop for each unit.
The engineer approves each unit's spec before any code is written and decides
on each finished diff before the unit can end.

- **Requester**: draws, starts, watches. Needs a browser and nothing else.
- **Engineer**: owns the machine, the agent CLIs, and the repo, and makes the
  decisions a requester cannot: whether a graph runs at all, whether a spec is
  what should be built, and whether a finished diff is accepted.

**What it claims.** A run ends in a pull request that an agent other than the
implementer reviewed, on which `run-gate.sh` reported green for the commit
that was pushed, and that the engineer accepted after seeing the diff.

**What it does not claim.** That the record proves any of this against a
hostile process on the same machine, or that the gate contained what it ran
(§6). task-graph-v1's evidence model exists for the first claim
(task-graph-v1 §3) and this plan does not use it. The honesty rule of
product-direction-v1 §2 still binds: the canvas shows recorded claims and
labels them as such.

## 2. Decisions

| decision | value | source |
| --- | --- | --- |
| executor | the engineer's machine, a foreground coordinator the engineer starts | user (2026-08-20); task-graph-v1 §1a keeps "user-started foreground" |
| graph storage | outside the repo, under `~/.config/olddonkey-loop/` | this plan; removes the `git pull` execution vector (task-graph-v1:110-119) |
| drawable node types | `unit` and `agent` only | this plan (§3) |
| highest stop point | `pr`; merging stays a human act on the hosting platform | this plan; avoids task-graph-v1 P4 entirely |
| who admits a graph | the engineer, once per graph, before any agent runs | this plan (§5) |
| who approves a spec | the engineer, once per unit, before the implementer runs | this plan (§4) |
| who decides on a diff | the engineer, once per unit; no unit ends as done without it, and nothing is pushed without it | this plan (§4) |
| concurrency | one unit in flight per workspace | inherited (`SKILL.md:102`) |
| where commands come from | an engineer-owned config file outside the repo, never the canvas or the repo | this plan (§4a) |

## 3. What a line means

The canvas has two node kinds and two line kinds. Nothing else can be drawn.

- **Unit node**: a title and a plain-language statement of what should change.
  It has two slots, `implementer` and `judge`.
- **Agent node**: a named `(backend, model, effort)` tuple that the engineer
  configured and that the doctor (unit 7) found installed and signed in. The
  shipped backends are codex, cursor, and grok (`backends/backends.tsv`);
  unit 0 adds claude.
- **Assignment line**, slot → agent: which agent fills that role for that
  unit. Dragging it to another agent is the "change the flow" gesture. The
  canvas refuses a unit whose two slots resolve to the same backend, because
  review must be independent of the implementer (`SKILL.md:14`).
- **Dependency line**, unit → unit: the second unit starts from the first
  unit's gated commit. The dependency graph must be acyclic.

**Grok fills only the judge slot in v1.** A grok implement dispatch moves
authority to a sibling snapshot path (`backends/grok/dispatch.sh:1211-1214`),
and the journal store is keyed by the workspace path, so a coordinator would
have to follow the move. Read-only grok stays on the same path.

**What is deliberately not drawable.** Review, gate, and publish are not nodes.
Every unit runs all of them in a fixed order, so a graph cannot omit one. The
iterate loop is not a line either: it lives inside the unit's state machine,
and each round appears in the run overlay as a new attempt. This is
task-graph-v1's three-layer split (task-graph-v1:147-154), kept unchanged. The
run overlay is the flow view from PR #63
(`scripts/console-assets/console.js:955-981`).

## 4. The coordinator replaces the agent session as driver

Today a Claude session reads a prose plan and performs every step in the loop
(`SKILL.md:8`). The people this plan is for do not have that session. The
driver's work is split three ways: mechanical steps go to the coordinator,
drafting and first-pass review go to the judge agent, and the two judgments
doctrine gives the driver (`SKILL.md:14`, `:61`) go to the engineer.

| step | today | here |
| --- | --- | --- |
| write the dispatch spec | Claude session | `judge` agent drafts it in a read-only dispatch; **the engineer approves it** |
| implement | backend via `dispatch.sh` | the same scripts, unchanged; every round is a fresh dispatch carrying the spec and the findings so far |
| review the diff | Claude session reads every hunk | `judge` agent returns a structured verdict, which is advisory; **the engineer's decision ends the unit** |
| iterate | Claude session sends findings back | coordinator sends the verdict's findings back, capped |
| gate | Claude session runs `run-gate.sh` | coordinator runs `run-gate.sh` with the configured command |
| red gate | Claude session triages (`SKILL.md:172-178`) | the coordinator cannot triage, so every red gate parks the unit |
| publish | Claude session, as far as the stop point | unit 4: after the engineer accepts, push exactly the gated SHA (`SKILL.md:186`) |

**The agent verdict is a filter, not the review.** An agent judge given one
prompt is a weaker reviewer than a Claude session that has held the whole plan
in context. So no state before the engineer's decision is a success state, and
unit 3 ends every completed unit in `awaiting-engineer`. The journal keeps the
two facts apart: `review.recorded` is the agent's verdict and names its
backend, and the engineer's accept or send-back is a separate event that unit
4 adds. Neither is shown as the other. Whether the filter is good enough to be
worth having is what §8 tests, in two stages, before anything that publishes
is specified.

**`deep` review.** When the calibrated depth is `deep`, the coordinator adds a
second review dispatch that gets the diff and the repo but not the spec
(`SKILL.md:37`). Both verdicts must be `pass`. `light` is treated as
`standard`.

### 4a. Inputs

The calibration store holds only the eight dials
(`scripts/loop-calibration:44-63`). It has no gate command, base branch, or
model. The coordinator reads:

- **The dials**, from `loop-calibration show --json`. An absent store yields
  the safe defaults, which stop at the working tree
  (`scripts/loop-calibration:64-73`). A rejected store means no standing
  authorization (`SKILL.md:231`), and the coordinator refuses to start until
  the engineer repairs it.
- **An engineer-owned config file** at
  `~/.config/olddonkey-loop/coordinator/<workspace-key>/config.json`: the base
  branch, the remote name, the agent tuples, the caps, and a gate block
  `{argv, mode, runner_unsupported}`. A gate command is executed, so it may
  never come from the repo or from a unit file.

**Gate mode.** v1 supports two modes, and the matrix below is complete.
`run-gate.sh` enforces `strict` only for pytest and unittest output
(`scripts/run-gate.sh:17-27`). `passthrough` is doctrine's own exception for a
runner the parser does not understand (`SKILL.md:167-169`): it is accepted
only when the config also sets `runner_unsupported: true`, and every report of
that gate says "exit code only". It never stands in for a `strict` dial: an
engineer who recorded `strict` and has such a runner changes the dial first.

| `gate` dial | config `strict` | config `passthrough` with `runner_unsupported` | anything else |
| --- | --- | --- | --- |
| `strict` | strict | refused | refused |
| `baseline` (also the default) | strict, which is tighter | passthrough, reported as exit code only | refused |
| `skip` | refused | refused | refused |

`baseline` mode is not supported in v1, so a repo whose base branch has known
failures cannot use the coordinator yet. The `on-red` dial is not consulted:
red always parks, which is at least as strict as either value.

### 4b. Where a dispatch's final message is

Only codex prints the final message alone on stdout
(`backends/codex/dispatch.sh:949-951`). Cursor and grok print a summary block
and then the message with no delimiter (`backends/cursor/dispatch.sh:505-522`,
`backends/grok/dispatch.sh:1241-1261`). All three also leave it in the
dispatch's state directory: `last-message.txt` (codex, `:787-792`),
`result.txt` (cursor, `:366`), and the `text` member of `output.json` (grok,
`:890`, `:1035-1040`). Unit 1 adds an eighth column to `backends/backends.tsv`
with the grammar `FILE` or `FILE#KEY`, where `#KEY` means a string member of a
JSON object: `last-message.txt`, `result.txt`, `output.json#text`. A new
contract rule checks the exact extracted bytes. The coordinator reads the
message that way, and finds the state directory through `loop-index`
(`scripts/loop-index:895-899`), given the dispatch id it took from the journal.

### 4c. The run's journal segment is the instrument

`loop-index` is a projection: it folds events by dispatch id, drops a gate's
tree ids, and reports an unreadable unattributed file as zero
(`scripts/loop-index:490-542`, `:572-594`, `:726-734`). The coordinator
therefore does not decide anything from it.

**`loop-journal read-run --run ID`** (unit 1) is read-only. It never creates
or changes the store, and takes the journal lock only while it reads the
segment into memory, which is the same lock appends and repairs hold. It
prints one JSON object:

```
{"schema": 1, "run": "<id>", "ended": true|false,
 "end_status": "completed"|"abandoned"|"failed"|null,
 "tail": "clean"|"unterminated"|"torn",
 "complete": true|false, "events": [<each event exactly as stored>]}
```

`events` is exactly what the journal's own parser would act on
(`scripts/loop-journal:446-471`): a last line that is valid but has no
terminator is included and `tail` is `unterminated`; a last line that cannot
be parsed is left out and `tail` is `torn`. `complete` is true only when
`tail` is `clean`. So the reader and `recover` never disagree about which
dispatches are open. Exit codes follow the journal's
own (`:39-46`): 0 for a document, complete or not; 2 for usage or a run id
with no segment; 3 for a busy lock; 4 for mid-file corruption; 6 for an event
whose run id is not the one asked for or a `seq` that is not strictly greater
than the one before it. It works on a run whose context has been retired,
which is the only way to confirm a `run.end` (`:1161-1173`). It does not judge
dispatch ids; the coordinator's dispatch rule below does.

**`loop-journal find-run --plan TEXT`** (unit 1) is read-only under the same
rules and prints `{"schema": 1, "runs": ["<id>", ...], "ambiguous":
["<id>", ...]}`. `runs` are the segments whose `run.begin` carries exactly
that `plan` value. `ambiguous` are the segments in which no complete
`run.begin` can be read, which is what a short write of that first line
leaves behind (`:712-729`). §4e uses it to find a run whose id the
coordinator never learned.

The coordinator remembers the last `seq` it has seen and, after every step,
reads what was added. It advances the cursor only on `complete: true`. An
incomplete read is retried once; a second one makes the unit
`unknown-outcome(journal-tail)` (§4e).

- **A dispatch** must add exactly one `dispatch.start` and exactly one
  `dispatch.end` with the same id, the expected backend and mode, the unit
  declared, and exit 0, and no other dispatch event. Then its state directory
  must resolve and its final message must be non-empty. Anything else blocks
  the unit. An adapter that fails to append `dispatch.end` only warns
  (`backends/cursor/dispatch.sh:318-330`), and this rule is what catches it.
- **A gate** must add exactly one `gate.result`, with purpose `unit-final`,
  the expected policy, the unit and round declared, verdict `green` with
  `gate_exit` 0, and a binding that ties it to the reviewed snapshot (§4d).
  `run-gate.sh` can exit green while recording `changed` or `unavailable`, and
  only warns if its own append fails (`scripts/run-gate.sh:290-326`); either
  case blocks.
- **The coordinator's own writes** through `loop-run` must each appear as one
  new event in its run. `loop-journal append` exits 0 even when an event lands
  in the unattributed file (`scripts/loop-journal:984-990`), so exit status is
  not evidence.
- **Clean environment.** `LOOP_CONTEXT` redirects where an append looks for
  its run (`scripts/loop-journal:854-865`). The coordinator removes
  `LOOP_CONTEXT`, `LOOP_JOURNAL`, `LOOP_TREE_OID`, and every backend namespace
  variable from the environment of everything it starts, and sets only
  `LOOP_UNIT` and `LOOP_ROUND`.
- **Stop points.** The coordinator never exceeds the calibrated stop point and
  never exceeds `pr`.

### 4d. One snapshot is reviewed, committed, and gated

`skills/engineering-mode/scripts/tree-oid.sh` writes the working tree's
non-ignored content as a tree object into the repository and prints its id
(`:337-375`). The coordinator uses that one object as the unit of review.

1. After the implementer returns, take the tree id `T`. Exit 3 means the tree
   cannot be bound (a dirty submodule, an embedded repository, suppression
   flags; `:10-14`), and the unit ends `blocked(tree-unbindable)`.
2. The diff shown to the judge is
   `git diff --text --no-color --no-ext-diff --no-textconv --no-renames <base> <T>`,
   so the diff and the id cannot come from different moments. A prompt can
   carry a change losslessly only if the content is text, and v1 has no way
   for the judge to review anything else. So a unit that changes content
   which is not text parks as `binary-change`, with the paths listed, instead
   of reaching the engineer as agent-reviewed. What counts as text is decided
   from the blobs' own bytes, never from Git's diff machinery, which the
   repository's attributes control in both directions: checked in a scratch
   repository, a `diff` attribute makes `--numstat` count lines in a file
   with a NUL byte, and `-diff` makes it report a plain text file as binary.
   `--text` is there so that an attribute cannot hide a text change from the
   judge. The classification, from the two trees' entries:
   - an entry whose blob id differs is a binary change, and parks the unit,
     if the old or the new blob contains a NUL byte, is not valid UTF-8, or
     is a Git LFS pointer (it begins with the line
     `version https://git-lfs.github.com/spec/v1`). A pointer is valid text,
     but the content it stands for is not in the tree, so v1 refuses
     LFS-managed changes instead of showing the judge a pointer;
   - an entry whose blob id is the same and whose mode differs is not a
     content change; its mode lines are in the diff and are reviewed, binary
     file or not;
   - an entry that is a symlink on either side is reviewed as link data, the
     target string, and the judge and the engineer are told the target's
     content was not followed;
   - an entry that is a gitlink on either side blocks the unit as
     `tree-unbindable`; a modified submodule already takes the helper's
     exit 3 (`:242-269`).

   This rule guarantees that the judge was shown every changed byte. It does
   not guarantee the judge understood them: encoded, minified, or generated
   text passes it, and the engineer is the one who sees that.
3. Before staging, take the tree id again; it must equal `T`.
4. After committing, the commit's tree must equal `T`. A hook that changed
   content therefore blocks the unit.
5. The gate's `gate.result` must show binding `clean`, `pre_head` and
   `post_head` equal to the commit, and `post_tree` equal to `T`. On the
   worktree path, where nothing is committed, it must show binding `dirty`
   with `pre_tree` and `post_tree` equal to `T`.

Ignored files are in neither tree (`SKILL.md:125-130`). `spec` records a
manifest of every ignored file's path, size, and modification time, before
any implementer has run. With each diff in `run`, the coordinator gives the
judge and the engineer the ignored files that are new or changed since then.
Above a configured number of ignored files it records no manifest and says,
in the same place, that ignored files were not tracked for this unit.
`check-diff` starts on a tree that is already changed, so it has no reference
manifest; it says ignored files were not compared.

### 4e. Lifecycle

`loop-run` can end a unit only as `done` or `parked` and a run only as
`completed`, `abandoned`, or `failed` (`scripts/loop-journal:57-70`). The
coordinator's states do not fit there, so it keeps its own state file per
unit under its config directory and maps onto the journal as follows.

| coordinator state | meaning | journal |
| --- | --- | --- |
| `spec-ready` | the judge's spec is waiting for the engineer | run active |
| `running` | implement, review, commit, or gate in progress | run active |
| `awaiting-engineer` | judge passed, gate green and bound, waiting for the decision | run active |
| `checked` | a diagnostic review finished (`check-diff`) | `unit.end parked`, `run.end completed` |
| `parked(reason)` | the unit failed in a way doctrine parks (`SKILL.md:211`) | `unit.end parked`, `run.end completed` |
| `blocked(reason)` | the coordinator could not trust its inputs or the record | `unit.end parked`, `run.end failed` |
| `unknown-outcome(step)` | the coordinator died inside a step, or the segment's tail is incomplete | run active until abandoned |
| `abandoned` | the engineer closed an unknown outcome or a waiting unit | `unit.end parked`, `run.end abandoned` |
| `quarantined` | the journal will not read the run or close it, or the run has no context | run left as it is |

Units 0–3 have no `done`: accepting a unit is unit 4. Until then a unit in
`awaiting-engineer` leaves only through `abandon`.

**The journal decides whether the run is open; the state file is the
coordinator's memory of where it was.** The state file is written before each
step that has an effect and again after it. Every command except `status` and
`release-quarantine` starts by reconciling the two:

0. **A begin with no run id.** `loop-journal begin-run` appends `run.begin`,
   then writes the context, and only then prints the id
   (`scripts/loop-journal:1122-1150`), so a kill in between leaves a run the
   coordinator has no id for. Before calling `loop-run begin` the coordinator
   therefore writes a random attempt token to the state file and passes it as
   `--plan coordinator:<token>`, together with the list of segments
   `find-run` already calls ambiguous. If the state has a token and no run
   id, it asks `find-run` again. No matching run and no new ambiguous segment
   means nothing was appended, and the attempt is discarded. One matching run
   that the context names is adopted and handled by rule 2. A matching run
   that no context names, more than one matching run, or a new ambiguous
   segment is `quarantined` with reason `orphan-run`.
1. A step is recorded as begun and not finished, and `read-run --run ID`
   shows the run ended: finish the state write to the terminal state that
   step named. This covers a crash between `run.end` and the state file.
2. A step is begun and not finished, and the run is still open:
   `unknown-outcome(step)`. Only `abandon` is accepted from here.
3. `read-run` returns `complete: false` twice: `unknown-outcome(journal-tail)`.
   `abandon` is accepted; the journal repairs the tail under its own rules
   on the next write (`:735-772`).
4. `read-run` fails with mid-file corruption, or `loop-run recover` refuses
   to close the run, which it does for a dispatch id with more than one start
   or end (`:1242-1254`): `quarantined`.
5. The state file is missing or unreadable: `blocked(state-lost)`. The
   engineer runs `abandon --unit ID --run ID`. Before it writes or attests
   anything, `abandon` requires that the active context names that run, that
   the run's `run.begin` carries a `coordinator:` plan, and that the run's
   events name exactly one unit, which is that one: a `unit.begin` for it,
   and no event of any kind carrying another unit. The journal does not limit
   a run to one unit (`scripts/loop-journal:57-70`), so this is checked, not
   assumed. If no `unit.begin` ties the run to the unit, or another unit
   appears in it, the run is `quarantined` instead.

**Quarantine.** `loop-journal` has no repair for a run it refuses, and no
command that ends a run without a context, at `d28e796`. The coordinator
writes a quarantine marker for the workspace naming the run and the reason,
prints the journal's message and the segment's path, and from then on refuses
every command except `status` and `release-quarantine`. Those two do not
reconcile and do not need a readable segment, a valid config, or a healthy
calibration store: `status` prints the marker, and `release-quarantine`
checks only what is listed here. The engineer inspects the segment and, if a
context names the run, renames that context file aside by hand, which is the
only way a new run can begin (`scripts/loop-journal:1109-1123`). That rename
does not end the old run or show that its processes stopped, so
`release-quarantine --run ID --processes-gone --note-file PATH` requires the
marker to name that run, the engineer's statement that its processes have
stopped, a readable note, and a context that does not name that run. It
writes the run id, the reason, the statement, and the note to the
coordinator's quarantine log, then removes the marker. The quarantined
segment stays in the journal, unterminated. The coordinator never renames the
context itself.

Further rules:

- The run stays active while a unit waits for the engineer. `loop-run begin`
  refuses a second run in the workspace (`scripts/loop-journal:1109-1119`), so
  one waiting unit holds the workspace. That is the one-unit limit, stated as
  a mechanism. Until unit 6 projects coordinator state, `loop-index` and the
  console show such a unit as `active` (`scripts/loop-index:400-426`), and
  `loop-coordinator status` is the only place the waiting state is named.
- `abandon` is the rescue command, so it needs only the journal and the
  unit's state file or a run id. It does not read the config or the
  calibration store, and works when either is broken. It reads back what
  exists (branch, commits, the processes of the last adapter it started) and
  prints it. It writes `unit.end parked` if the unit has no end, which also
  makes the journal repair an incomplete tail. It then reads the run again,
  works out from that read which dispatch starts have no end, and closes the
  run through `loop-run recover`, passing `--acknowledge` for exactly those;
  the attestation that such a dispatch's descendants are gone is the
  engineer's (`scripts/loop-journal:97-99`). A healthy run with no open
  dispatch closes with no acknowledgement (`:1255-1297`). The work stays on
  the unit branch.
- Parked and blocked also leave the work in place on the unit branch and say
  so. Parking that leaves a clean tree for a next unit is a multi-unit concern
  and belongs to unit 5.

### 4f. Process shape

`loop-coordinator` is a foreground script holding a workspace lock. The
console stays a separate process and, from unit 6 on, writes intents (drafts,
admissions, approvals, decisions) to a store that the coordinator reads. This
is the intent mailbox that loop-console-v1 deferred for lack of a reader
(loop-console-v1:6). The coordinator records every step through `loop-run`
and the existing adapters.

## 5. Two roles on one machine

This section is direction for units 6 and 8. Nothing in units 0–3 implements it.

**Admission.** A requester's graph is a proposal. No agent runs, read-only or
otherwise, until the engineer admits it. Admission is where the engineer
checks that the units are cut sensibly, and may edit them. It is also the
security boundary: text from another person becomes a prompt on the engineer's
machine only after the engineer has read it.

**Spec approval and the decision.** These are §4's two engineer steps, shown
on the canvas. Every unit needs both, whoever drew the graph. There is no
standing authorization to publish in v1: a field in a graph that claimed one
would let requester-originated work promote itself (`SKILL.md:15`).

**The engineer must not drown.** A requester can draw five graphs in ten
minutes. Three mechanical limits bound the engineer's load:

1. One unit in flight per workspace, and a unit that waits for the engineer
   holds the workspace (§4e).
2. Admission is per graph, so an unadmitted graph costs the engineer nothing.
3. A spec is a page; a diff is not. Approving the spec first is where a badly
   cut unit is caught before any implementer has run.

"Waiting for the engineer" is a first-class state that the requester sees by
name, once unit 6 projects it. task-graph-v1's point that blocking nodes are
part of the product, not a failure, survives here.

**What a requester sees.** Unit states, the judge's plain-language summary,
and the PR link. Transcripts and dials are engineer-only, because transcripts
can carry secrets from the engineer's machine.

**Access.** The console binds `127.0.0.1` (`scripts/loop-console:1199`) and
keeps doing so. The engineer chooses how a requester reaches it (SSH forward,
Tailscale, a tunnel). The product adds two things: invite links that create a
named, revocable `requester` session, and an allowlisted public origin so the
origin check (`scripts/loop-console:793-794`) accepts the tunnel. There are no
accounts, no relay, and no hosted service.

**Unsolved, and owed by unit 8's kickoff.** The gate runs repo scripts that
the implementer may have just changed, before any person has seen the diff.
With the engineer's own units that is today's exposure. With a requester's
text upstream of the implementer it is a path from another person's words to
unsandboxed execution on the engineer's machine, guarded only by the spec
approval and an agent review. Unit 8 may not ship until the gate is contained
or the engineer's decision moves ahead of it.

## 6. What this inherits and what it amends

**Doctrine is normative.** The five non-negotiables (`SKILL.md:14-18`) hold.
This plan may not weaken them.

**It amends product-direction-v1** at three points and nowhere else:

| product-direction-v1 | here |
| --- | --- |
| first user is the author, running a Claude session as judge (`:51`) | adds the requester and engineer pair |
| no multi-user access (`:59`, `:800`) | adds one role-scoped requester session per invite, on the engineer's machine |
| S5, the editable canvas, comes after S4 and is gated on P1–P5 (`:112-113`) | the canvas and execution come first, at today's assurance level |

It keeps "not a model gateway" (`:61-63`) and "not a resident executor"
(`:64-66`). The coordinator is started by the engineer, runs in the
foreground, and takes only graphs the engineer admitted.

**It does not close task-graph-v1's P1–P5** (task-graph-v1:1207-1211), and
four of the five are load-bearing here exactly as they are in today's loop.
The table says what each leaves open and what this plan does about it.

| seam | relied on? | what stands in for it |
| --- | --- | --- |
| P1 gate is sampled, not enforced | yes, by unit 3: "gated" means what `run-gate.sh` means today, endpoints sampled | the binding rule in §4d; the engineer sees the binding; CI runs on the PR. A suite that changes and restores the tree is not caught. |
| P2 capabilities unenforced | yes, by unit 3: the configured gate command runs repo scripts with the engineer's full authority | units 0–3 run only unit files the engineer wrote and specs the engineer approved; containment is owed before unit 8 (§5) |
| P3 authority-to-effect not atomic | not by units 0–3, which publish nothing; yes by unit 4 | carried into unit 4's kickoff as a requirement (§7) |
| P4 landing not atomic | no | v1 never merges |
| P5 process identity | yes | a crash yields `unknown-outcome`; the coordinator lists the processes it can see, and the attestation that they are gone is the engineer's, as today |

**From task-graph-v1 it keeps** the three-layer model, the rule that a node
type needs defined completion evidence, blocking as a first-class state, and
the two gate defects it found. It does not use the trusted writer, the
authority store, the admission matrix, or the genesis ceremony.

## 7. Units

Prerequisite: PRs #60–#64 land. Unit 3 needs the truthful gate verdict (#60)
and unit attribution (#61); the canvas's run overlay is #63. Units run in
order, each branching from the previous one's result. Model, effort, stop
point, and cadence for implementing these units are settled at kickoff
(`SKILL.md:40-57`), not here.

**The gate for building each unit below** is every `run:` step of
`.github/workflows/selftest.yml`, run on the host by
`plans/product-direction-v1-tools/ci-gate.sh` under `run-gate.sh` in
pass-through mode, because shell selftests are outside its parser. The
verdict is each step's exit code (`ci-gate.sh:58-70`). This is the gate of
whoever drives the loop for this plan, and is separate from the coordinator's
runtime gate in §4a. Each unit lists the suites whose pinned counts change;
`AGENTS.md` and the workflow are updated to match in the same unit.

### Unit 0 — `claude` backend

Turn the `claude -p` harness in `plans/product-direction-v1-tools/` into a
fourth backend module. It keeps the cursor protocol: a git-less copy, the
agent confined to the copy, then a patch applied to the real worktree
(`backends/cursor/dispatch.sh:208-259`, `:425-465`). Review depth is `deep`,
because the unit defines a sandbox boundary.

- **Creates** `backends/claude/dispatch.sh`, `runtime.md`, `selftest.sh`,
  `fixture-driver.sh`.
- **Behaviour.** Implement mode grants `Bash Read Edit Write Glob Grep` inside
  Claude Code's OS sandbox with `failIfUnavailable`, and loads no setting
  sources and no MCP servers. Read-only mode grants `Read Glob Grep` and
  builds no patch. The tool restriction is the CLI's; the adapter's own check
  of the granted tool list, read from the init event after the run, is
  detection and not containment, and `runtime.md` says so. State lives at
  `<git-common-dir>/olddonkey-loop/claude/<dispatch-id>/` and holds
  `last-message.txt`. Resume is refused.
- **Contract.** The adapter passes every rule in `tests/contract-core.sh:141`
  that applies to a `flag`-effort, `refuses`-resume, `json` backend with the
  namespace `CLAUDE_LOOP_`, including the summary's version, model and effort
  provenance, mode, and session id lines (`:523-528`). The session id comes
  from the init event. Checked on 2026-09-30 against CLI 2.1.285: with
  `--no-session-persistence`, both the init and the result event carry a
  `session_id`.
- **Modifies, code:** `backends/backends.tsv` (one row);
  `scripts/loop-journal:88` (the `backend` enum, without which every journaled
  claude dispatch is refused); `scripts/loop-index:516`, `:536`, `:895`,
  `:903`, `:911`, `:1019-1028`; `scripts/loop-console:461-463`, `:506-512`;
  `scripts/console-assets/console.js:60`.
- **Modifies, tests:** `tests/journal-selftest.sh` (the widened enum);
  `tests/index-selftest.sh` (the per-backend inventory and the section regex
  near `:252`, which would otherwise file a new `### Claude` table under
  cursor); `tests/console-selftest.sh` (node order, row count, and the
  unknown-backend sentinel at `:1895`, which is the literal `claude` today);
  the three existing fixture drivers (add `CLAUDE_LOOP_` to the
  foreign-namespace poison); `tests/integration-test.sh` (`--backend claude`
  and `--require claude`, which fails on any skipped claude case; today an
  unavailable backend is a skip and the run still passes, `:25-43`, `:1466`).
- **Modifies, docs and CI:** `references/dispatch-contract.md`,
  `references/state-schema.md`, `references/running-anywhere.md`,
  `.github/workflows/selftest.yml` (syntax lines and a selftest step after
  `:84`), `AGENTS.md`, `README.md`, `README.zh-CN.md`.
- **Does not modify** `scripts/loop-calibration:55` or the `backend` dial in
  `console.js:22`. Those name the implementer of the agent-driven loop, and a
  Claude session choosing Claude as its implementer is the same-model case
  `references/dials.md:5` warns about.
- **Tests.** The new selftest pins its own check count and covers: both modes;
  a tool list that differs from the allowlist; an agent-created `.git` or
  symlink; a malformed or error result; a missing session id; an empty patch;
  `apply --check` failure leaving the real worktree untouched; journal start
  refusal. `contract-core.sh` picks the new row up on its own (`:603`).
- **Counts that change:** journal, index, and console selftests; the new
  claude suite. `build.sh` copies nothing from `backends/`, so the Cursor
  package and its version decision are unaffected.
- **Required before the unit is published:**
  `tests/integration-test.sh --require claude` against the real CLI, no skips.
  Its claude cases cover both modes and one denial each: a read-only run asked
  to write a file, and an implement run asked to fetch a URL. In both the real
  worktree is unchanged and no ungranted tool was used.

### Unit 1 — journal reader and final-message contract

Protocol only. No coordinator yet.

- **`loop-journal read-run --run ID`** and **`loop-journal find-run --plan
  TEXT`**, with the output objects and exit codes of §4c. Those are the whole
  consumer interface; `references/state-schema.md` records them.
- **`reviewer`**: an optional field on `review.recorded`
  (`scripts/loop-journal:79`), an enum of the backend names plus `session`, so
  it is never free text; `loop-run review --reviewer`
  (`scripts/loop-run:210-218`); projected by `scripts/loop-index` and
  `scripts/loop-evidence`.
- **Final message**: `backends/backends.tsv` becomes schema 2 with the eighth
  column of §4b; `tests/contract-core.sh:78-84`, `:141`, `:603` and
  `tests/contract-negative.sh` gain a `final-message` rule: after a fixture
  run whose scripted message has a newline, a quote, a backslash, and a
  non-ASCII character, the bytes extracted per the column equal it.
- **Modifies also:** `references/state-schema.md`,
  `references/dispatch-contract.md`, the four fixture drivers where the
  scripted message needs it, `tests/journal-selftest.sh`,
  `tests/index-selftest.sh`, `tests/evidence-selftest.sh`, `AGENTS.md`.
- **Tests for `read-run`:** an active run; an ended run by id after its
  context was retired; an unknown run id; mid-file corruption; an event with
  another run's id; a `seq` that repeats or goes backwards; a torn tail and a
  valid unterminated last line, both `complete: false`; lock contention
  reported as the journal's lock-busy exit; a missing store left uncreated; a
  store whose bytes are identical before and after the read; for both tail
  cases, the same open dispatches that `recover` computes. **For
  `find-run`:** no match, one match, two matches, a run with no `plan`, a run
  whose context was never written, and a segment holding only a short-written
  `run.begin`, reported as ambiguous.
- **Counts that change:** journal, index, evidence, and contract suites.

### Unit 2 — coordinator: spec, approval, diagnostic review

Nothing in this unit runs an implementer, commits, gates, or changes the
working tree.

- **Creates** `scripts/loop-coordinator`, `references/coordinator.md`,
  `references/coordinator-spec-prompt.md`,
  `references/coordinator-review-prompt.md`, `tests/coordinator-selftest.sh`.
- **CLI**, run from the repo root: `spec --unit-file PATH`;
  `approve-spec --unit ID --digest SHA256`; `status`;
  `abandon --unit ID [--run ID]`, where `--run` is required when the unit has
  no state file (§4e rule 5); `release-quarantine`;
  `check-diff --unit-file PATH --spec PATH --spec-digest SHA256 --base SHA`.
- **Unit file** (outside the repo): `id`, `title`, `intent`, `implementer`,
  `judge`. The last two name agents from the config. Any other key is an
  error, so a unit file cannot carry a command or an authorization.
- **Owns:** the workspace lock, the per-unit state file, reconciliation and
  quarantine (§4e), the ignored-file manifest taken at `spec`, and the review
  step that unit 3 reuses.
- **Checked by `spec`, `approve-spec`, and `check-diff`:** no quarantine
  marker; reconciliation per §4e; config readable, owned by the user, and not
  a symlink; calibration store not rejected. The config must name the agents
  and the caps. Its gate block is not read by any command in this unit; unit
  3's `run` checks it against the §4a matrix.
- **Checked by `abandon`:** no quarantine marker; reconciliation per §4e.
  Nothing else (§4e).
- **Checked by `status` and `release-quarantine`:** only what §4e lists for
  quarantine.
- **`spec`.** Requires: both agents exist, their backends differ, the
  implementer is not grok, no state for this unit id, a clean tree
  (`SKILL.md:101`), the checkout on the configured base branch, and no active
  run.
  1. Write the attempt token, `loop-run begin --plan coordinator:<token>`
     (§4e rule 0), create branch `canvas/<id>` (`SKILL.md:104`), record the
     base SHA and the ignored-file manifest, `loop-run unit-begin`.
  2. Read-only judge dispatch with the spec template and the intent, with
     `LOOP_UNIT` set and no round.
  3. The result must be at most 32 KiB, begin with `Unit:`, and contain the
     five section headers of `references/dispatch-prompt.md:8-32` in order,
     with non-empty `Why`, `Change`, and `Tests`. The coordinator replaces the
     `## Environment` body with its own fixed text, so a judge cannot loosen it.
  4. State `spec-ready`; print the spec's path, digest, run id, and base SHA.
- **`approve-spec`.** Requires state `spec-ready`. It reads the spec once,
  checks the digest the engineer gave against those bytes, and stores them in
  the unit's state directory with the run id and base SHA
  (`SKILL.md:61`, `:107`). Every later dispatch is built from that stored
  copy, written to a fresh private file, and the copy is re-hashed after the
  dispatch returns; a mismatch blocks.
- **Review step**, shared with unit 3. Given a base and the working tree:
  the snapshot of §4d steps 1–2; a diff that changes a binary file, or one
  over the configured byte cap, ends the step without a review; otherwise a
  read-only judge dispatch with the review template, the spec, the diff
  inline, and the ignored-file report (cursor and claude judges run in a
  git-less copy, so the diff cannot be left for them to compute); under
  `deep`, a second dispatch without the spec.
- **Verdict schema.** One JSON object of at most 64 KiB, optionally in a
  single fenced block, with exactly the keys `verdict` (`pass` or `iterate`),
  `summary` (string, at most 2000 characters), `findings` (at most 50 objects
  with exactly `file` string, `line` non-negative integer, `what` and
  `expected` strings of at most 1000 characters), and `notes` (at most 20
  strings of at most 500 characters). A duplicate key, a wrong type, or an
  extra key is unparseable. `iterate` needs at least one finding; `pass` needs
  none. An unparseable review is retried once with a fresh dispatch, then
  blocks. The verdict is recorded with `loop-run review --reviewer <backend>`.
- **`check-diff`.** Requires: no active run; HEAD equal to `--base`; a working
  tree that differs from HEAD; the spec file's bytes matching `--spec-digest`.
  It begins its own run with the unit file's id, runs the review step once as
  round 1, records and prints the verdict (or that there was no review, and
  why), writes `unit.end parked` and `run.end completed`, and ends in state
  `checked`. It exits 0 with a verdict and with a distinct status when there
  was no review, so a driver can tell the two apart. It commits nothing and
  leaves the tree and HEAD as it found them. The index then shows the unit
  as `parked` with no gate or publication, and with the recorded review, or
  with `review: not recorded` when there was none.
- **Tests** drive the real adapters with PATH stubs, as the fixture drivers
  do, with the temp root under `tests/` (`tests/contract-core.sh:46`). Cases:
  - each backend as judge, the final message extracted per its column;
  - `spec` on a dirty tree, off the base branch, with an active run, with
    same-backend slots, a grok implementer, an unknown unit-file key, a
    symlinked config, a config with no gate block (accepted here), and a
    rejected calibration store;
  - spec: missing header, empty section, oversize, the Environment body
    replaced, `approve-spec` with a wrong digest, and the spec file replaced
    after approval;
  - verdict: fenced and bare; each schema violation; retry once, then blocked;
    `deep` with one failing verdict;
  - snapshot: `tree-oid.sh` exit 3; a binary content change ending the step
    with no review, including a NUL-bearing blob that an attribute forces
    to text, a blob that is not valid UTF-8, and an LFS pointer; a text file
    that an attribute marks binary shown in full; a mode-only change on a
    binary file reviewed;
    a file replaced by a symlink reviewed as link data; a gitlink entry
    blocking; a
    diff over the byte cap; `spec` recording the manifest and the manifest
    cap; `check-diff` saying ignored files were not compared;
  - journal rule: an adapter whose end append fails; two starts with one id;
    two new ids; an inherited `LOOP_CONTEXT`; a `loop-run` write that lands
    unattributed; one incomplete read then a complete one; two incomplete
    reads, then `abandon` repairing the tail;
  - lifecycle: a kill inside `begin-run` after the append and before the
    context, after the context and before the id is returned, and after the id
    and before the state write; a kill inside the spec dispatch and between
    `run.end` and the state write; each followed by a command that reconciles
    as §4e says; a short-written `run.begin` leading to quarantine;
    `abandon` with and without an open dispatch, with a torn `dispatch.end`
    and with a valid unterminated one, and with a missing config and a
    rejected calibration store; a missing state file, where `abandon` without
    `--run` is refused, with a run the context does not name is refused, with
    the right run and a matching `unit.begin` closes it, with no
    `unit.begin` quarantines, and with a second unit in the run quarantines;
  - quarantine: a corrupted segment, a `recover` that refuses on a duplicate
    dispatch id, and an orphan run each lead to it; every other command is
    refused; `status` and `release-quarantine` work with an unreadable
    segment, a broken config, and a rejected calibration store; release
    without the statement, with the context still naming the run, and for a
    run the marker does not name are each refused;
  - `check-diff`: on a clean tree, under an active run, with a wrong digest,
    with HEAD not at the base, a normal run that leaves the tree and HEAD
    unchanged and shows as `parked` in the index and on the record card, and
    a no-review outcome reported with its own exit status and shown as
    `review: not recorded`.
- **Counts that change:** the new coordinator suite; `AGENTS.md` and the
  workflow gain its step.

### Falsifier, stage A1 — between units 2 and 3

See §8. Unit 3 is not dispatched unless it passes.

### Unit 3 — coordinator: `run`, up to the engineer

Nothing in this unit pushes, opens a PR, or ends a unit as done.

- **CLI.** `loop-coordinator run --unit ID`.
- **Requires:** a gate block that the §4a matrix accepts under the current
  dial; an approval for this unit's run id and base SHA; the active run is
  that run; the checkout is `canvas/<id>`; HEAD is the base SHA; the tree is
  clean.
- **Round `r`, from 1:**
  1. `loop-run round-begin`, then a fresh implement dispatch with `LOOP_UNIT`
     and `LOOP_ROUND` set. A nonzero exit parks the unit.
  2. Unit 2's review step, with the manifest `spec` recorded. A binary
     change or a diff too large to review parks the unit.
  3. `iterate` below the round cap returns to step 1. At the cap, the unit parks.
  4. `pass`, by the stop point read now and stored in the state file:
     - `worktree`: gate the working tree.
     - `commit` or higher: §4d step 3; stage everything; commit; §4d step 4;
       require a clean tree; gate.
  5. Gate result, per §4c and §4d step 5. Bound green ends the unit in
     `awaiting-engineer`. Red parks with the log path. Anything else blocks.
- **Modifies:** `scripts/loop-coordinator`, `references/coordinator.md`,
  `tests/coordinator-selftest.sh`, `AGENTS.md`.
- **Tests:**
  - each backend as implementer where allowed; `run` without approval, on the
    wrong branch, under another run, with HEAD off the base, with no gate
    block, and with each refused cell of the gate matrix;
  - `iterate` to the cap; an implementer that exits nonzero; a binary content
    change, a mode-only change, and a symlink change, as in unit 2; a new and
    a changed ignored file reported to the judge;
  - snapshot: a change between review and staging; a commit hook that fails;
    a commit hook that succeeds and changes content;
  - gate: each stop point; red; both accepted cells of the matrix; a gate
    whose append fails; a stale green gate event from an earlier round; a gate
    that leaves `changed` or `unavailable`; tree ids that do not equal the
    reviewed one;
  - lifecycle: a kill inside the implement dispatch, after the commit, and
    after the gate, each followed by reconciliation and `abandon`; a second
    `spec` while a unit waits for the engineer.
- **Counts that change:** the coordinator suite.

### Falsifier, stage A2 — after unit 3

See §8. Unit 4's kickoff is not written unless it passes and the user says go.

### Direction only

4. **The engineer's decision, and publish.** Its kickoff inherits these
   requirements, which three review rounds established:
   - a `decision.recorded` event (`accept` or `send-back`, by `engineer`),
     kept apart from `review.recorded` in the journal, the index, and the
     record card;
   - no standing mode; the decision names the gated commit, or the reviewed
     tree id when nothing was committed;
   - the stop point re-read before every effect, with a defined outcome for
     each combination of what was gated and what the dial now says;
   - push by lease to the unit's branch, reading the remote ref first and
     skipping a push that is already satisfied;
   - one open PR with the exact head SHA and the configured base; any other
     PR for that head blocks; an ambiguous create is held until the host's
     state is conclusive or the engineer makes an explicit manual decision
     that accepts the risk of a duplicate;
   - the record card regenerated after publication is recorded, and the PR
     body read back;
   - the branch, a clean tree, and the exact gated SHA or tree checked again
     immediately before each effect (`SKILL.md:182`, `:186`);
   - every journal write confirmed in the run's segment, `unit.end done` and
     `run.end completed` included, and a repeat after a crash that reconciles
     existing decision and publish events first;
   - send-back with its own continuation preconditions, starting a new round
     from the gated commit or the reviewed worktree without discarding either.
5. **Graph store and multi-unit runs.** Out-of-repo graph file with semantics
   and layout kept apart, a fail-closed validator, topological order, each
   unit's base taken from its upstream's gated commit, and parking that leaves
   a clean tree.
6. **Canvas authoring.** Draw units and both line kinds, run, spec approval,
   and the decision screen, for the engineer session only, plus the intent
   mailbox and the projection of coordinator state into the index and
   console. Rendered and exercised in a real browser before it is called done.
7. **Doctor.** Probe which backend CLIs are installed and signed in, and
   populate the agent rail from the result.
8. **Requester role.** Invite links, a role-scoped API, the proposal inbox and
   admission, and the public-origin allowlist. It changes the console's
   security model from one local user to two roles and puts another person's
   text upstream of the gate (§5), so it ships only after the gate question is
   answered and after an independent security audit given the code and not
   this plan.

## 8. Falsifiers

Stage A tests whether the agent judge is a usable filter. It does not test
whether the engineer saves time; that is stage B. The units come from this
repo's merged history. Candidates, in order: loop-console-v1 units 1–5 (PRs
#50, #51, #53, #54, #55), then #56, #57, #58, #60, #61. The models may have
seen this code, so every result here is an upper bound on judge quality and
the write-up says so. Results go in `docs/collab-canvas-falsifier-a.md`.

### Stage A1, after unit 2: does the judge catch a known defect?

No implementer runs. Every clone used here is a separate workspace with its
own workspace key, so the driver writes the same coordinator config (the
agent tuples and the caps; no gate block is needed) for each one. Take
candidates in order until five are certified as controls, with at most ten
candidates:

1. **Spec.** In a scratch clone, create branch `falsifier/<n>` at the PR's
   base commit, name it as the base branch in that clone's config, and run
   `spec` with the unit's section of the plan the PR implemented as the
   intent. The engineer approves the spec. Record its digest and the base SHA,
   then close that clone with `abandon`.
2. **Certify.** Before any judge sees the diff, the engineer reads the PR's
   merged diff against the approved spec and records one of two things in the
   results file: it is a clean control (it does what the spec asks and the
   engineer knows of no defect in it), or it is not, with the reason. A
   candidate that is not a clean control is skipped. So is a candidate on
   which `check-diff` reports no review for the unseeded or the seeded diff
   (too large, a binary change, a tree that cannot be bound): it is recorded
   as unreviewable, since it measures nothing about the judge.
3. **Unseeded.** In a second clone at the same base commit, apply the merged
   diff uncommitted and run `check-diff` with that spec, digest, and base.
4. **Seeded.** Before any judge sees it, the driver writes into the results
   file one defective variant of the merged diff, changed in one way taken
   from the review checklist (`references/review-checklist.md:7-13`): a
   weakened assertion, a deleted test case, a changed default, a softened
   enforcement point, a new network call. The driver also records the
   difference between the merged diff and the seeded one, which must be that
   one change and nothing else, and a command with its output that shows the
   defect has the intended effect. In a third clone, apply the seeded diff
   uncommitted and run `check-diff` the same way.

**Inconclusive:** fewer than five clean controls that the judge actually
reviewed, unseeded and seeded, among ten candidates. That says nothing about
the judge; the user decides whether to extend the list.

**Pass, both required:**

1. Sensitivity: on at least four of the five seeded diffs the judge returns
   `iterate` with a finding that names the seeded defect.
2. Specificity: on at least three of the five clean controls the judge
   returns `pass`. An `iterate` on a clean control is a false objection. If
   the engineer finds that such a finding is a real defect, the control was
   not clean: it is reported separately as a defect the judge found, removed
   from the five, and replaced by the next candidate. So a judge that objects
   to everything cannot pass.

### Stage A2, after unit 3: does a judge pass mean what the engineer would say?

For each candidate in order, in a fresh scratch clone: create the branch and
config as in A1 step 1, with a gate block of `ci-gate.sh`, mode
`passthrough`, and `runner_unsupported: true`. The clone has no calibration
store, so the stop point is `worktree`, and the default `baseline` dial with
that config is an accepted cell of the §4a matrix. The judge and implementer
are on different backends. Run `spec`; the engineer approves it; then `run`,
in the same run that `spec` began.

**Preflight.** That `ci-gate.sh` runs against those older commits is
*assumed*. Before `spec`, the driver runs the gate command on the untouched
base commit in that clone. A candidate whose base is not green there is
skipped and does not count as an attempt.

Take candidates until five have reached `awaiting-engineer`, with at most ten
attempts. For each of the five the engineer reads the diff before seeing the
judge's summary, records accept or reject with the reason, and records the
minutes spent on the spec and on the diff. Each clone is then closed with
`abandon`. Every attempt that did not reach the engineer is recorded with its
reason and one of three causes: the pipeline (a blocked unit, an adapter or
gate failure), the implementer (a nonzero exit, a red gate, the round cap),
or the unit (too large, a binary change).

**Pass:** five units reached `awaiting-engineer`, and the engineer rejected
at most one of them for a defect.

**Fail:** five reached the engineer and two or more were rejected for a
defect. The judge passes what the engineer would not.

**Inconclusive:** fewer than five reached the engineer within ten attempts.
That is evidence about the pipeline or the implementers, recorded by cause,
and not about the judge.

### What follows from each outcome

- A1 or A2 fails: the next unit is not started, and the design needs a
  stronger judge before it needs a canvas.
- Either is inconclusive: the next unit is not started either, but nothing
  has been learned about the judge. The user decides whether to fix the cause
  and run the stage again.
- Both pass: the user reads the minutes and decides whether unit 4's kickoff
  is written.

### Stage B, after unit 8

One real requester submits three graphs. Measure the engineer's minutes per
shipped unit against doing the same work through their own session. If the
canvas costs the engineer more time, the product has moved work onto the
person it depends on, and they will stop running it.

## 9. Risks

| risk | handling |
| --- | --- |
| The engineer accepts without reading | The decision screen puts the diff first and the button last. This is a social risk the product can discourage but not prevent. The record says "engineer decision: accept" and never calls it a review. |
| A requester's text steers an agent into harm | Admission before any run, spec approval before any implementer, the existing sandbox per backend, and nothing pushed or published before the decision. Agent API calls and the gate's repo scripts do run before it; §5 names that as unsolved for unit 8. |
| The canvas market is crowded (n8n, Dify, Flowise) | The canvas is not the product. The product is that a run ends in a gated, reviewed PR, and stage A tests the judge before any canvas work. |
| A judge and implementer from the same vendor family agree too easily | The independence check is on backend identity only in v1; model-family independence is a known gap |
| Two engineer steps per unit is itself too much | Stage A2 records the minutes; stage B compares them with the engineer's own session |
| An adapter moves its final-message file | Unit 1 makes the location a contract rule with a negative control |
| Many repos need `baseline` mode | Out of scope for v1 and said so in §4a; the coordinator refuses such a config instead of running a weaker gate |
| A quarantined journal run is released while its processes still run | The release needs the engineer's explicit statement and is logged; the coordinator cannot verify it, and says so |

## 10. Decisions the user settled (2026-09-30)

1. **The Phase A stack (#65–#68) is frozen, not merged.** This plan does not
   use the authority store. No further Phase A unit is started, the four PRs
   stay open, and their fate is decided after stage A. This plan's units
   therefore branch from the head of #64 and stay on journal schema 1. The
   frozen stack's own schema-1 event list and index do not know the `claude`
   backend value, the `reviewer` field, or `read-run`; if the stack is ever
   merged, porting those is required work, not an automatic compatibility.
2. **Claude is an agent on the canvas in v1.** There is no shipped `claude`
   backend; a `claude -p` harness exists under
   `plans/product-direction-v1-tools/`. Unit 0 turns it into a fourth backend
   module, because Claude as judge over another vendor's implementer is the
   configuration the user runs today.
3. **This plan sits beside product-direction-v1.** S1–S3 stay as shipped
   work, S4–S6 are paused, and this plan is the next stage.

## 11. Non-goals

Merging. Concurrent units. Standing authorization to publish. Resuming a
crashed unit. `baseline` gate mode and iterating on a red gate. Repairing a
journal that refuses. Hosted execution, a relay, or accounts. Non-code
products. Command or operation nodes. Grok as an implementer on the canvas.
Claude as the implementer of the agent-driven loop. Codex resume inside the
coordinator. An agent that splits a requester's graph into better units (the
engineer does that at admission). Live model output for cursor and grok. Gate
containment (owed before unit 8). Proof-grade evidence.

## 13. Implementation notes

What building the units changed, relative to §4 and §7 above. Where this section and those differ, this section is what was built.

### Unit 0, as merged (PR #69)

- Every post-run check and the diff read one frozen copy of the work tree, taken after the CLI exits. A reviewer's stub that kept writing after the checks got a file applied in four runs of five before this.
- The patch is not rewritten. It is `git diff --no-index --no-renames` applied with `git apply -p2`. The header rewriting the cursor adapter does breaks renames, paths such as `lib/work/x`, and hunk lines that look like headers; the cursor adapter still has it and that is a separate change.
- New paths that the real repository ignores are dropped and reported, not applied.
- The real CLI creates an empty `.claude/.cc-writes/` in its working directory whenever Bash runs. So new paths under any `.claude/` directory are dropped and reported, and only a change to or deletion of an existing one is refused.
- The real CLI refuses a compound shell command it cannot analyse statically, because there is nobody to approve it. The real-CLI containment case therefore runs three separate simple commands and is judged from the stream.
- §12's carried falsifier was run against CLI 2.1.285 and was not triggered: an in-copy edit lands, an out-of-copy write is refused by the OS sandbox, and `curl` is refused.

### Unit 1, as merged (PR #70)

- `read-run` returns exactly the events the journal's own parser returns. A line that is valid JSON and not an object is therefore corruption (exit 4) or a torn tail, never exit 6.
- `find-run` treats a complete `run.begin` that lacks its newline as a run, as the parser does.
- Both print ASCII-only JSON.

### Unit 2, as specified for implementation

- `loop-journal` gains a third read-only subcommand, `read-context`, because nothing else lets a caller ask which run the context names.
- A quarantine has its own id and a list of runs, which may be empty, and is released with `release-quarantine --id`. A released unit is in a new terminal state, `released`; its run stays unterminated in the journal.
- The lost-state case is `unknown-outcome(state-lost)`, not a `blocked` state: its run is still open and it leaves by `abandon`.
- The cap is on the whole prompt, `caps.prompt_bytes`, at most 120000, because three adapters pass the prompt as one argument and Linux limits an argument to 131072 bytes. There is no separate diff cap.
- The spec's Environment section comes from a new `references/coordinator-environment.md`, not from `dispatch-prompt.md`, whose block has an unfilled placeholder.
- A judge that explains under Why that the request cannot be specified, and leaves Change empty, ends the unit `parked(spec-declined)` with no retry.
- Under `deep`, the spec-blind review is dispatched only after the first review passes.
- A unit that ends parked, blocked, or abandoned with a clean tree at the base commit is returned to the base branch and its `canvas/<id>` branch is deleted.
- An `init` command creates the config directory and prints the workspace key.
- The own-write rule tolerates a `journal.repaired` event before the expected one, since the journal emits it when it repairs a torn tail.

## 12. Review record

Codex read-only review, `gpt-6-sol` at `max`, one thread
(`01a0f612-e425-7922-96d8-e86dae35ca0c`). Each code claim in a finding was
re-checked against `d28e796` before it was accepted. Unit numbers in rounds 1
and 2 are the ones in force then; round 3 renumbered them.

**Round 1** (13 findings: 8 BLOCKER, 3 MAJOR, 2 MINOR; NOT YET).

| # | finding | disposition |
| --- | --- | --- |
| 1 | agent review recorded as success without the engineer | accepted: no success state before the engineer's decision; verdict is advisory; `deep` adds a spec-blind review |
| 2 | the gate is not executable as specified | accepted, then narrowed further in rounds 2 and 3 |
| 3 | a commit hook can change what is committed | accepted: tree id at review, before staging, and against the commit |
| 4 | "exactly one dispatch" and context checks do not fail closed | accepted, then rebuilt on the journal segment in round 2 |
| 5 | end states and handoff have no durable form | accepted: state file, journal mapping, run held open while waiting |
| 6 | `standing` and publication lack an authority path | accepted: `standing` removed |
| 7 | stage A can pass vacuously | accepted: completed cases, seeded defects, explicit recipe, minutes; the time-saving claim moved to stage B |
| 8 | the claude assumption is checked too late | accepted: checked against the real CLI; `--require claude` before publish |
| 9 | four of P1–P5 are load-bearing | accepted: §6 table rewritten; gate containment owed before the requester role |
| 10 | spec and verdict interfaces are open design decisions | accepted: schemas and caps; engineer approves the spec |
| 11 | file and test inventories incomplete | accepted: lists extended |
| 12 | citation anchors | accepted: each corrected |
| 13 | Phase A port | accepted: recorded in §10 decision 1 |

**Round 2** (13 findings: 7 BLOCKER, 5 MAJOR, 1 MINOR; NOT YET). Most were
against round 1's own fixes.

| # | finding | disposition |
| --- | --- | --- |
| 1 | `run` must refuse the state `spec` created | accepted: preconditions are per command |
| 2 | gate policy undefined for several combinations | accepted by narrowing: two modes, a complete matrix, `baseline` mode and red-gate iteration removed from v1 |
| 3 | a worktree gate is not tied to the reviewed tree; a stale gate event can satisfy a later run | accepted: exactly one new `gate.result`, tree ids compared |
| 4 | lifecycle recovery is not total | accepted: reconciliation rules; a refused journal handled apart |
| 5 | dispatch pairing cannot be read from the index | accepted: the coordinator reads the run's journal segment through `read-run` |
| 6 | the seeded-defect protocol cannot run | accepted: separate clones, `check-diff` with its own preconditions |
| 7 | PR read-back is not enough for a repeatable publish | accepted, carried into the publish unit's requirements |
| 8 | tree identity is narrower than "what was reviewed" | accepted: the diff is derived from the tree object; exit 3 has an end state; ignored files are listed |
| 9 | approval binds a digest, not the dispatched bytes | accepted: approved bytes stored and re-hashed |
| 10 | the console cannot show the waiting state; "review of record" conflicts with the record | accepted: projection deferred and said so; two separate events |
| 11 | the eighth column names a file, but grok's message is a JSON member | accepted: `FILE#KEY` grammar; exact bytes checked |
| 12 | lowering the stop point after a commit is undefined; the PR body's card is stale | accepted, carried into the publish unit's requirements |
| 13 | post-run tool check is detection; two anchors; `ci-gate.sh` verdict | accepted |

**Round 3** (9 findings: 5 BLOCKER, 4 MAJOR; NOT YET).

| # | finding | disposition |
| --- | --- | --- |
| 1 | a `strict` dial must not accept `passthrough` | accepted: that cell is refused (§4a) |
| 2 | `read-run` cannot confirm `run.end` | accepted: `read-run --run ID` works after the context is retired (§4c) |
| 3 | `send-back` cannot invoke `run` | accepted: the decision and publish unit is now direction only, with continuation preconditions among its inherited requirements (§7 unit 4) |
| 4 | sign-off is not repeatable; the stop point is read once; a second create can duplicate a PR | accepted: same move; read-before-push, authority re-read per effect, and no blind second create are inherited requirements |
| 5 | the manual context rename bypasses the one-unit limit | accepted: quarantine marker, every command refused until `release-quarantine` with the engineer's statement, logged (§4e) |
| 6 | `read-run` needs a cursor and lock contract | accepted: validation, `complete`, no store creation, lock held only while reading; tests listed (§4c, unit 1) |
| 7 | binary changes and changed ignored files are not presented | accepted: pinned diff flags, a binary list, a manifest of ignored files with new and changed reported (§4d) |
| 8 | `check-diff` leaves the unit `active`; its spec is not tied to the approved one | accepted: it ends `unit.end parked` in state `checked`; it takes and verifies the digest and base (unit 2) |
| 9 | the coordinator unit is too broad | accepted: split into unit 1 (journal reader, final-message contract), unit 2 (spec, approval, diagnostic review), unit 3 (`run`); the falsifier is split to match, so the seeded-defect test runs before any implementer does (§7, §8) |

**Round 4** (9 findings: 4 BLOCKER, 4 MAJOR, 1 MINOR; NOT YET). The reviewer
judged moving publish out of executable scope a legitimate re-scoping.

| # | finding | disposition |
| --- | --- | --- |
| 1 | quarantine cannot be released under the stated preconditions | accepted: `status` and `release-quarantine` do not reconcile and need no healthy config, store, or segment (§4e, unit 2) |
| 2 | a crash inside `loop-run begin` leaves a run with no known id | accepted: an attempt token passed as `--plan`, `find-run`, and reconciliation rule 0; an orphan is quarantined (§4c, §4e) |
| 3 | an incomplete read has no exit | accepted: `unknown-outcome(journal-tail)`, from which `abandon` repairs and closes (§4e rule 3) |
| 4 | A1's second and third clones have no config | accepted: one config per clone; the gate block is checked only by `run` (unit 2, unit 3, §8) |
| 5 | specificity lacks certified clean controls | accepted: the engineer certifies each control before any judge sees it; three outright passes required; a withdrawn control is replaced (§8) |
| 6 | no ignored-file baseline for `check-diff` | accepted: the manifest is taken at `spec`; `check-diff` says ignored files were not compared (§4d) |
| 7 | duplicate-id handling and the reader interface | accepted: literal output and exit codes; duplicates are caught by the coordinator's dispatch rule and by `recover`, and the text now says so (§4c, §4e rule 4) |
| 8 | binary changes reach the engineer as agent-reviewed | accepted: such a unit parks as `binary-change` (§4d) |
| 9 | terminal checks for unit 4; A2's use of "as in A1 step 1" | accepted (§7 unit 4, §8) |

**Round 5** (5 findings: 1 BLOCKER, 4 MAJOR; NOT YET).

| # | finding | disposition |
| --- | --- | --- |
| 1 | a short-written `run.begin` makes `find-run` report nothing, and the attempt is wrongly discarded | accepted: `find-run` reports ambiguous segments; rule 0 discards only when there is no match and no new ambiguous segment (§4c, §4e) |
| 2 | `read-run` and `recover` can disagree about a valid unterminated `dispatch.end` | accepted: `read-run` returns what the journal's parser would act on, with a `tail` field; `abandon` re-reads after its append and derives acknowledgements from that read (§4c, §4e) |
| 3 | the diff text is not a binary classifier | accepted: classification from tree entries; mode-only, symlink, and gitlink cases stated and tested (§4d) |
| 4 | `abandon` is blocked by a damaged config or store | accepted: `abandon` needs only the journal and the state file or a run id (§4e, unit 2) |
| 5 | a falsifier stage that cannot complete is read as a judge failure | accepted: pass, fail, and inconclusive are separate; A2 preflights the gate; seeds are shown to be the one intended change (§8) |

**Round 6** (3 findings: 2 BLOCKER, 1 MAJOR; NOT YET).

| # | finding | disposition |
| --- | --- | --- |
| 1 | `blocked(state-lost)` has no usable rescue command | accepted: `abandon --unit ID --run ID`, validated against the context, the run's plan, and its `unit.begin`; no `unit.begin` means quarantine (§4e rule 5, unit 2) |
| 2 | `--numstat` is itself configurable by repository attributes | accepted after reproducing it both ways in a scratch repository: text is decided from the blobs' bytes (no NUL, valid UTF-8), and the diff is produced with `--text` (§4d) |
| 3 | a clean control may be unreviewable | accepted: such a candidate is recorded and replaced; fewer than five reviewed controls is inconclusive; `check-diff` reports no-review with its own status (§8, unit 2) |

**Round 7** (3 findings: 1 BLOCKER, 1 MAJOR, 1 MINOR; NOT YET).

| # | finding | disposition |
| --- | --- | --- |
| 1 | a Git LFS pointer is valid text that hides binary content | accepted: a pointer on either side parks the unit; the rule's limit (shown, not understood) is stated (§4d) |
| 2 | the state-lost rescue can close a run that holds another unit | accepted: the run must name exactly one unit, the one given; otherwise quarantine (§4e rule 5) |
| 3 | `check-diff`'s no-review path described as having a review | accepted: wording corrected, test covers both paths (unit 2) |

**Round 8: ACCEPT, no findings.** Findings per round: 13, 13, 9, 9, 5, 3,
3, 0. Every finding in every round was accepted after its code claims were
checked; none was refuted.

**The falsifier carried into implementation.** Asked where real code could
first show the design wrong, the reviewer named unit 0's real-CLI gate. If
the `claude` adapter uses the flags this plan specifies and reports the
expected tool list, and yet the read-only write probe or the implement-mode
network probe succeeds, then the containment this plan assumes of Claude Code
is wrong. That would indict the design, not the adapter, and unit 0 does not
ship on a workaround. The two judge-quality tests in §8 are the next ones.

Two changes in round 3 go beyond the findings. The publish unit left the
executable scope because the falsifier decides whether it is built at all, and
its mechanics are better specified against unit 3 as implemented. Stage A1
gained a specificity criterion, because a judge that returns `iterate` on
everything would otherwise pass the seeded-defect test.
