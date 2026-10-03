# Loop coordinator (unit 2)

`scripts/loop-coordinator` is a foreground driver for one Git worktree. It is
separate from the agent driven workflow in `SKILL.md`. In this unit it asks a
judge agent to draft a spec, waits for the engineer to approve those exact
bytes, and can run a diagnostic review of an existing working tree diff. It
does not run an implementer, commit, run a gate, publish, or edit working tree
files. Run every command at the worktree root.

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
  "caps": {"rounds": 3, "prompt_bytes": 120000, "ignored_files": 5000, "dispatch_seconds": 3600},
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
and `dispatch_seconds` is 1–14400.
The prompt ceiling stays below Linux's 131072 byte limit for one CLI argument:
three adapters pass the entire prompt as one argument. A prompt over the cap
is never sent. `gate` is optional here and validated for shape only: `argv`
is a nonempty list of nonempty strings, `mode` is `strict` or `passthrough`,
and `runner_unsupported` is a boolean. No command in this unit reads its
values. Unknown config keys at any level are refused.

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

## Commands

| Command | Effect and requirements |
| --- | --- |
| `init` | Create the private directory; no config or lock needed. |
| `spec --unit-file PATH` | Require a clean base branch, unused id and `canvas/<id>` branch, no active run, valid agents, config, references, and calibration. Begin a journal run, create `canvas/<id>`, record ignored files, ask the judge for a spec, and wait in `spec-ready`. An invalid spec is retried once; a decline or dispatch failure parks the unit. |
| `approve-spec --unit ID --digest SHA256` | From `spec-ready`, read `spec.txt` once, compare the digest, and store exactly those bytes in `approved-spec.txt`. Reapproval with a new digest replaces the approval. No config or calibration needed. |
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
unknown outcome needing resolution; 130 signal interruption during a dispatch.
Checks run in this order: quarantine,
usage and file shape, private directory/config/references/calibration,
reconciliation, command preconditions.

The coordinator strips every inherited `LOOP_*` variable, `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_NAMESPACE`, and
every registered backend namespace variable from child environments.
`GIT_CEILING_DIRECTORIES` stays. The one exception is the engineer's
`CODEX_LOOP_BLOCK_EXTERNAL_TOOLS` safety setting. It sets
`GIT_OPTIONAL_LOCKS=0`, then sets `LOOP_UNIT` and, for a review round,
`LOOP_ROUND`.

## States and recovery

| State | Meaning | Journal |
| --- | --- | --- |
| `spec-ready` | Spec waiting for engineer approval | Active run |
| `running` | A step is in progress | Active run |
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

For an unreadable `state.json` with no active run, use `abandon --unit ID`.
It renames the damaged file to `state.json.unreadable`, keeps the directory
and unit id reserved, and writes no journal event. With an active context,
that command refuses and prints the exact `abandon --run ID` to use.

Each dispatch runs in a new process group. On SIGINT, SIGTERM, or SIGHUP the
coordinator sends TERM to that group, waits up to ten seconds, then sends
KILL and exits 130 with the step begun. On `dispatch_seconds` expiry it does
the same and reports a timeout dispatch failure. After any adapter exit it
checks for living descendants and stops them before closing a run with an
unmatched `dispatch.start`; a surviving descendant leaves an
`unknown-outcome` requiring engineer inspection.

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
