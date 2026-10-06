# Loop coordinator

`scripts/loop-coordinator` is a foreground driver for one Git worktree. It is
separate from the agent driven workflow in `SKILL.md`. It asks a judge to
draft a spec, waits for approval of those exact bytes, and can run a
diagnostic review. `run` dispatches an implementer, reviews each round, then
commits locally when the stop point permits and runs the configured gate. It
stops at `awaiting-engineer`. No command pushes, fetches, opens a pull request,
or calls a unit done. Run every command at the worktree root.

The coordinator stores private state at
`$HOME/.config/olddonkey-loop/coordinator/<sha256(realpath(worktree))>/`.
Directories are 0700; files are 0600. It holds `coordinator.lock` for each
mutating command except `init`. A busy lock exits 3.

## Initialize and configure

Run `scripts/loop-coordinator init`. It prints the workspace key, state
directory, and a commented `config.json` example, and creates no config. The
engineer creates `config.json` as an owned, regular 0600 file in that real
0700 directory. The file accepts exactly these keys:

```json
{
  "schema": 1,
  "base_branch": "main",
  "remote": "origin",
  "agents": {
    "judge": {"backend": "claude", "model": "sonnet", "effort": "high"},
    "implementer": {"backend": "codex", "model": "gpt-5"}
  },
  "caps": {"rounds": 3, "prompt_bytes": 120000, "ignored_files": 5000, "dispatch_seconds": 3600, "commit_seconds": 300, "gate_seconds": 3600},
  "gate": {"argv": ["python3", "-m", "unittest"], "mode": "strict", "runner_unsupported": false}
}
```

`base_branch` and `remote` are nonempty names. `agents` is nonempty; names
match `[a-z][a-z0-9-]{0,31}` and each agent has only `backend`, `model`, and
optional `effort`. Backend is a registered `claude`, `codex`, `cursor`, or
`grok`; model and effort are nonempty tokens without whitespace or a leading
hyphen. Claude effort is `low`, `medium`, `high`, `xhigh`, or `max`. Cursor
effort is `low`, `medium`, `high`, or `xhigh` and its model ends with
`-<effort>` or `-<effort>-fast`. Codex and grok forward any valid effort
token. The judge and implementer must use different backends; grok cannot be
the implementer.

`caps` and each of its keys are optional. Defaults are shown above. `rounds`
is 1–10, `prompt_bytes` is 1000–120000, `ignored_files` is 0–100000,
`dispatch_seconds` and `gate_seconds` are 1–14400, and `commit_seconds` is
1–3600.
The prompt ceiling stays below Linux's 131072 byte limit for one CLI argument:
three adapters pass the entire prompt as one argument. A prompt over the cap
is never sent. `gate` is optional for spec and diagnostic review, but required
for `run`: `argv` is a nonempty list of nonempty strings, `mode` is `strict` or
`passthrough`, and `runner_unsupported` is a boolean. The gate command comes
from this engineer-owned config, never from the spec or repository. Unknown
config keys at any level are refused.

`run` accepts exactly these gate cells. `baseline` does not run a baseline
comparison; it allows a stricter gate, or an explicit passthrough exception.
Every passthrough report says “exit code only”.

| Calibration `gate` | Config `strict` | Config `passthrough`, `runner_unsupported: true` | Other config |
| --- | --- | --- | --- |
| `strict` | strict | refused | refused |
| `baseline` | strict | passthrough | refused |
| `skip` | refused | refused | refused |

`dispatch-mode` must be `implement`. The config selects the agents; `backend`,
`cadence`, `on-red`, and `fix-lane` are not consulted by `run`. Every red gate
parks. The `depth` dial still controls whether a passing first review gets a
spec-blind second review.

The engineer also writes a unit JSON file outside the worktree:

```json
{"id":"my-unit","title":"One-line title","intent":"What to change","implementer":"implementer","judge":"judge"}
```

Those five keys are exact. `id` matches `[a-z][a-z0-9-]{0,39}`; title has
at most 200 characters and no newline; intent has at most 20000 UTF-8
bytes. The spec and note files passed to commands also stay outside the
worktree. Unit ids are never reused.

The spec heading look-alike guard is defence in depth: it recognizes level-2
ATX and dashed setext headings with invisible formatting characters, while
ordinary prose and other heading levels remain valid. Homoglyphs, such as a
Cyrillic letter substituted for a Latin one, are out of scope. The engineer's
approval of the spec's exact bytes is the control. Invalid specs report a
fixed reason (with a line number for a look-alike heading); the unit state
still records `spec-invalid`.
The judge's reply must be at most 10000 bytes. An invalid first reply is
retried once with the validator's fixed reason appended to the prompt.
Spec and verdict strings reject line and paragraph separators, Unicode tags
and supplemental variation selectors, interlinear annotations, invisible
operators, and private-use characters in addition to the existing control
characters. ZWJ, ZWNJ, direction marks, U+FE0F, U+061C, and U+180E remain
allowed. `run` checks approved spec bytes again, because approval records a
digest without validating their content.

## Commands

| Command | Effect and requirements |
| --- | --- |
| `init` | Create the private directory; no config or lock needed. |
| `spec --unit-file PATH` | Require a clean base branch, unused id and `canvas/<id>` branch, no active run, valid agents, config, references, and calibration. Begin a journal run, create `canvas/<id>`, record ignored files, ask the judge for a spec, and wait in `spec-ready`. An invalid spec is retried once; a decline or dispatch failure parks the unit. |
| `approve-spec --unit ID --digest SHA256` | From `spec-ready`, read `spec.txt` once, compare the digest, and store exactly those bytes in `approved-spec.txt`. Reapproval with a new digest replaces the approval. No config or calibration needed. |
| `run --unit ID` | Require the approved spec and clean `canvas/<id>` branch at its base SHA, valid agents, matching active run, `dispatch-mode=implement`, and an accepted gate cell. Dispatch fresh implementation and review rounds up to `caps.rounds`; on pass, gate the reviewed worktree or commit; finish in `awaiting-engineer` only on a bound green gate. |
| `check-diff --unit-file PATH --spec PATH --spec-digest SHA256 --base SHA` | Require no active run, HEAD at base, a changed working tree, and matching spec bytes. Snapshot the tree, classify binary and symlink changes, dispatch review, record any verdict, and close as `checked`. No commit or working tree edit. |
| `status [--unit ID] [--json]` | Read only, without lock, config, calibration, or journal. Reports quarantine, unit state (including `unreadable`), current spec digest, approval match, and whether `verdict.json` exists. |
| `abandon [--unit ID] [--run ID] [--dispatches-terminated]` | Close a coordinator run. With readable state, its exact attempt token binds the run; `unit.end` is written only after `unit.begin`. Without readable state, an active run requires `--run` and the unit is derived from journal events. Zero named units closes without a unit record; multiple named units quarantine. A mismatched `--unit` is refused. An unreadable state file is renamed `state.json.unreadable` before replacement; with no active run, `abandon --unit ID` only renames it. An unmatched dispatch requires the explicit process and descendant attestation. No config or calibration needed. |
| `release-quarantine --id QID --processes-gone --note-file PATH` | After manual inspection and process termination, record the note and release the marker under `coordinator.lock`. No readable journal segment, config, or calibration needed. |

Exit codes: 0 completed; 1 internal error (traceback saved to
`CDIR/last-error.txt`; the next command reconciles); 2 malformed arguments or
unit/spec/note file; 3
refused precondition or busy lock; 4 quarantine; 5 missing or unsafe private
directory/config, unreadable reference, or failed/rejected calibration; 6
unit blocked; 7 unit parked; 8 diagnostic check completed without review; 9
unknown outcome needing resolution; 130 signal interruption during a dispatch,
commit, or gate.
Checks run in this order: quarantine,
usage and file shape, private directory/config/references/calibration,
lock, reconciliation, command preconditions. A rejected or unreadable
calibration store exits 5; a refused `run` precondition exits 3 without
changing the unit state, journal, or worktree.

## Running an approved unit

Approve the digest printed by `spec`, then run `run --unit ID`. Approval alone
does not check the spec's encoding or name; `run` requires approved bytes that
are valid UTF-8 and start with `Unit: ` followed by a name. An old gate event
appended while the unit waited in `spec-ready` is ignored by moving the
coordinator's journal cursor to the end before the first round.

Each round records `round.begin`, sends a fresh implement dispatch with the
approved spec (or the previous verdict's summary and findings as JSON lines),
and reviews a single tree object against the unit's base commit. Prior edits
are already in the implementer's working tree. The diff includes text and mode
changes; symlinks are reported as link data; new or changed ignored files are
reported against the manifest recorded by `spec`. The prompt, stdout, state,
and result show at most the first 50 sorted changed ignored paths. When there
are more, they give the remaining count and name `ignored-files.txt` in the
unit directory; that file holds the complete JSON-quoted list, one path per
line. It is removed when there are no changed paths. `check-diff` has no prior
manifest, so it reports exactly `Ignored files were not compared.` and writes
no `ignored-files.txt`. A tree equal to the base
parks as `empty-diff` without dispatching review. `iterate` starts another
round until the cap, then parks as `round-cap`.

On `pass`, calibration is read again. `worktree` gates the reviewed working
tree. `commit`, `pr`, and `merge` all stage and commit locally, then gate that
commit. The commit uses hooks and a message file with the unit name, unit id,
approved spec digest, reviewed tree, and run id. The coordinator checks the
tree again before staging, then verifies the commit tree, sole parent, and
clean status. After those checks, it reads the journal: a commit hook that
wrote any event blocks as `journal-write` before the gate starts. The gate
runs `run-gate.sh --purpose unit-final --log ...` with the configured argv.
Its own suite must not write another event into this checkout's loop journal:
for example, calling `run-gate.sh` from that suite adds an event and blocks
as `gate-record`. The gate must add exactly one `unit-final` record. Its
recorded `gate_exit` must agree with the observed `run-gate.sh` exit status;
a signal exit or mismatch blocks as `gate-record`. A valid red record parks.
A green record must bind both head and tree captures to the reviewed worktree
or commit. Only then does the coordinator check the branch, HEAD, tree, and,
on the commit path, clean status once more. A post-gate change blocks as
`head-moved` or `tree-changed`. A missing, stale, unattributed, or conflicting
record blocks the unit.

The successful result is one JSON object and a matching state file: unit,
run, branch, base SHA, stop point and path, optional commit, reviewed tree,
round, full judge verdict, gate policy and log, and ignored-file report. A
passthrough result also says “exit code only”. The run remains open for the
engineer. `status --json` shows these fields. `run` refuses an
`awaiting-engineer` unit, and the active run prevents another `spec`.

Parked and blocked units get `unit.end parked`; parked runs end `completed`,
blocked runs end `failed`. Their work remains for inspection. `abandon` on
`awaiting-engineer` ends the run as abandoned and retains any commit or dirty
branch. A unit in that state has no other exit in this version.

| Reason | What the engineer does next |
| --- | --- |
| `too-large`, `binary-change`, `empty-diff`, `round-cap` | Inspect the spec, diff, ignored-file report, and worktree. Split or restart the unit with a reviewable change. |
| `implement-dispatch-failed`, `review-dispatch-failed` | Inspect the captured stdout/stderr and any edits left by the adapter. Correct the cause before a new unit. |
| `commit-failed` | Read the escaped tail in the message and full `commit.stderr`, then inspect the staged index; fix identity, signing, or hooks before restarting. |
| `gate-red`, `gate-timeout` | Inspect the printed gate log and worktree; fix the gate or its deadline before restarting. |
| `dispatch-identity`, `state-dir`, `final-message`, `prompt-changed`, `verdict-unparseable`, `tree-unbindable`, `tree-id` | Inspect adapter, journal, and tree evidence; the coordinator could not trust the review. |
| `head-moved`, `tree-changed`, `stage-failed`, `commit-timeout`, `commit-tree-mismatch`, `tree-dirty-after-commit` | Inspect the branch, index, hooks, and committed tree before any further action. |
| `calibration`, `gate-matrix`, `gate-record`, `gate-binding`, `journal-write` | Repair the relevant store or record and inspect the gated snapshot; no green result is accepted. |

The coordinator strips every inherited `LOOP_*` variable, `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_NAMESPACE`, and
every registered backend namespace variable from child environments.
`GIT_CEILING_DIRECTORIES` stays. The one exception is the engineer's
`CODEX_LOOP_BLOCK_EXTERNAL_TOOLS` safety setting. It sets
`GIT_OPTIONAL_LOCKS=0`, then sets `LOOP_UNIT` and, for a review round,
`LOOP_ROUND`.
The coordinator's own files and read-only children use private umask 077.
The implement dispatch, commit, and gate start with the caller's original
umask, and every adapter hands that mask on to what it runs in the checkout
(the `worktree-umask` rule in `references/dispatch-contract.md`).
`gate.log` is tightened to 0600 after the gate exits. A `commit-failed` or
`stage-failed` output detail, or an adapter or gate start error, is limited to
the last 2000 raw bytes and JSON-escaped before display and storage. The full
commit output remains in `commit.stderr`.

## States and recovery

| State | Meaning | Journal |
| --- | --- | --- |
| `spec-ready` | Spec waiting for engineer approval | Active run |
| `running` | A step is in progress | Active run |
| `awaiting-engineer` | Bound green gate and judge pass, waiting for the engineer | Active run |
| `checked` | Diagnostic review done, with or without verdict | `unit.end parked`, `run.end completed` |
| `parked(reason)` | Unit or agent failure | `unit.end parked`, `run.end completed` |
| `blocked(reason)` | Inputs or record cannot be trusted | `unit.end parked`, `run.end failed` |
| `unknown-outcome(step)` | Step began but did not finish, journal tail incomplete, or state lost | Active run |
| `abandoned(reason)` | Engineer closed it or run ended externally | `unit.end parked` when needed; abandoned or external run end |
| `quarantined` | Journal cannot be read or safely closed, or run lacks context | Run left as found |
| `released` | Engineer released quarantine | Run remains unterminated |

Every command other than `status`, `init`, and `release-quarantine`
reconciles nonterminal state before its own work. A `running` step without
its completion record becomes `unknown-outcome`; use `abandon --unit ID`
to inspect and close it. The command prints the branch, commits beyond base,
working tree status, and live processes in the last dispatch's process
group. If that group is still alive, `abandon` refuses before writing unless
`--dispatches-terminated` asserts the listed processes are unrelated or can
no longer act. If a dispatch start lacks an end, verify that it and all
descendants cannot act again before using the same flag. A lost state file,
or an unreadable one with an active run, requires `abandon --run ID`; a
readable state requires an exact
`coordinator:<attempt_token>` plan. Reconciliation keeps checking
`unknown-outcome` units: an external run end becomes `abandoned`, and an open
run without its context quarantines. A busy journal lock is retried for at
most ten seconds; a write that remains busy leaves its step begun and the
next command reports `unknown-outcome`.
If a step is begun but its child pid was never recorded, `abandon` also
requires `--dispatches-terminated` before its first journal write. It names
that step; repeated calls without the flag remain refusals.

For an unreadable `state.json` with no active run, use `abandon --unit ID`.
It renames the damaged file to `state.json.unreadable`, keeps the directory
and unit id reserved, and writes no journal event. With an active context,
that command refuses and prints the exact `abandon --run ID` to use.

Each dispatch, commit, and gate runs in a new process group with `/dev/null`
as stdin. On SIGINT, SIGTERM, SIGHUP, or a time cap, the coordinator snapshots
all descendants from the process table *before* signaling. It sends TERM,
then KILL if needed, to each descendant's process group and its own created
group. It judges survivors from the process table, ignoring zombies. Once a
stop begins, a second signal cannot restart or cut it short. Signals are
blocked and handlers installed before the begun step or empty process slot is
written; a signal during child launch is held until its pid is recorded, then
handled. A signal the
coordinator inherited as ignored stays ignored. A survivor leaves
`unknown-outcome`; a completed signalled stop exits 130 with its step begun.
If the process table cannot be read, the coordinator still stops its created
group. A read-only dispatch then retains its unit 2 timeout or signal result;
an implement dispatch, commit, or gate becomes `unknown-outcome(<step>)`
because a detached writer cannot be ruled out. After a normal exit it checks
only the group it created. The last
started commit or gate group is recorded where `abandon` checks liveness, so
`abandon` refuses while it remains alive unless the engineer supplies
`--dispatches-terminated`.

The Codex adapter stops its own CLI when the coordinator's TERM reaches it
and records that generation `failed`. Only a stop that reached the KILL
stage, or a crash, can leave the adapter's own
`$HOME/.config/olddonkey-loop/codex/<workspace key>/<dispatch id>/meta.tsv`
marked `running`; the adapter then refuses another dispatch in that
workspace with “highest generation is still running” and names
`--recover-stale`, which `backends/codex/runtime.md` describes. The
coordinator does not edit this adapter record.

### Limits of observation and control

A process that detaches before the stop snapshot, or one spawned while the
stop is underway, may be outside the captured descendant groups. The final
tree check before `awaiting-engineer` can catch a change already made; a
later change leaves a dirty tree for the engineer to inspect. The calibration
store, journal, and coordinator directory are protected from an implementer
by the selected adapter's sandbox, not by a coordinator permission boundary.
Ignored files are compared by path, size, and modification time; a rewrite
that restores both size and mtime is not reported.

The combined diagnostic verdict is saved as `verdict.json` and printed before
the run is closed, so a failed terminal write does not hide it. Paths in
review notes and binary-change reports are JSON strings, one per line.

For `quarantined`, inspect the segment paths printed in the marker and the
reported reason. Confirm processes have stopped. If the journal context
still names one of the marker's runs, rename that context file aside by
hand; the coordinator never does it. Then run `release-quarantine` with the
marker id, `--processes-gone`, and an outside-worktree note file. This logs
the release and removes the marker. A released run stays **unterminated** in
the journal.

For a parked, blocked, or abandoned unit on `canvas/<id>`, the coordinator
returns to base and deletes the branch only if the tree is clean and HEAD
still equals the recorded base SHA. Otherwise it leaves the checkout in
place and prints the commands to use after inspection.

The hermetic `tests/coordinator-selftest.sh` pins 1745 checks where `ps` is
readable, or 1641 in a sandbox that denies it. The latter still exercises the
unreadable-process-table path using a test-local failing `ps`; cases requiring
the real table are explicitly skipped for a host run.
