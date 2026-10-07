# Codex runtime reference

Dispatch Codex through `backends/codex/dispatch.sh`. The adapter uses plain
`codex exec`, runs strictly in the foreground, records each turn under
`~/.config/olddonkey-loop/codex/`, and emits only the final implementer message
on stdout. Its summary, warnings, CLI transcript, and policy-banner checks go to
stderr.

### Choosing model, effort, and tier

**These are the user's call, not yours to silently assume.** At loop kickoff,
ask one compact question covering model/effort and service tier, showing the
current top-level values from `~/.codex/config.toml` as the inherit option. The
answer holds for the invocation; do not re-ask per unit. Respect a standing
preference to inherit.

- Omit `--model` and `--effort` to let the installed CLI resolve its normal
  config layers.
- `--model VALUE` passes `-m VALUE` for that turn.
- `--effort VALUE` passes a quoted TOML
  `-c 'model_reasoning_effort="VALUE"'` override. The CLI is the authority for
  supported values, so `ultra` and `max` are forwarded like every other level.
- Service tier has no adapter flag. The CLI resolves it from config; the
  summary displays the top-level project/global value only as disclosure.
- Model names and tier spellings age quickly. Read the installed config and
  check `codex --version` before making a current recommendation.

`CODEX_LOOP_MODEL` and `CODEX_LOOP_EFFORT` provide standing per-project
overrides without editing global config. Never edit the user's Codex config on
your own initiative.

### Flag semantics: pinned policy on every path

Both fresh and resume argv come from one mode-parameterized builder.

| path | sandbox/workspace shape |
| --- | --- |
| fresh | `codex exec -s <workspace-write|read-only> ... -C <canonical-workspace>` |
| resume | `cd <canonical-workspace>` then `codex exec resume <exact-id> -c 'sandbox_mode="<mode>"' ...` |

Every invocation also carries:

```text
-c 'approval_policy="never"'
--strict-config
-c 'sandbox_workspace_write.writable_roots=[]'
-c 'sandbox_workspace_write.network_access=false'
```

Do not add `sandbox_permissions=[]` from the `codex exec --help` examples. In
codex-cli 0.147.0 that help text is stale relative to the real configuration
schema: `sandbox_permissions` is not a schema field, and `--strict-config`
makes the unknown `-c` override fatal during config loading. The same strict
schema rejects that field in user config, so there is no accepted ambient value
for the adapter to clear. Before shipping any new fixed `-c` key, validate it
against the installed real CLI with the non-Git, pre-API `config-schema-pins`
case in `tests/integration-test.sh`; PATH stubs cannot validate config schemas.
The same gate's `config-fixture-schema` case independently loads the exact
hostile user and project fixture bytes as user config before any paid dispatch.

Resume accepts neither `-s` nor `-C`; omitting the explicit `sandbox_mode`
override would fall through to ambient config rather than inherit the original
thread policy. The adapter never uses `--last`, never passes `--json`, and
redirects the child stdin from `/dev/null`. It rejects policy broadeners,
including bypass flags, extra writable directories, profiles, config/rule
ignores, and feature toggles.

Profile layering is unreachable through the adapter. In codex-cli 0.147.0 a
profile is a standalone `$CODEX_HOME/<name>.config.toml` file selected with
`--profile <name>`; profiles are not an ambient layer. The adapter rejects both
`-p` and `--profile`, so the former frozen `config-profile-layer` integration
case was retired rather than claiming that an active profile was overridden.
The real coverage is in `backends/codex/selftest.sh`: “`--profile` is refused by
the direct parser guard” and “`--profile` never reaches Codex argv.” The live
matrix continues to exercise hostile valid user and project config layers.

### Calibrated tuple

The required matrix ran end to end on 2026-08-17 at source head
`f1690f47b84f83fe50875470daf4f83ee5216fa1`. At that head, twenty-six frozen
expectations matched and none skipped; the hard-link probe measured the
vendor-sandbox hole described below. Both resume probes matched: repository
write `allow`, Git-state write `deny`.

The matrix wrote this release provenance before its temporary fixture was
cleaned up:

| field | calibrated value |
| --- | --- |
| OS / kernel / architecture | `Darwin` / `25.5.0` / `arm64` |
| launcher chain | `/Users/olddonkey/.local/bin/codex` -> `/Users/olddonkey/.codex/packages/standalone/releases/0.147.0-aarch64-apple-darwin/bin/codex` |
| terminal executable SHA-256 | `19c4f144c5226a9f17c58e6f0fa854843b0f77a6eb420f40e2745a12f10f5d37` |
| CLI / adapter version | `codex-cli 0.147.0` / `2` |
| validated adapter SHA-256 | `23fc8da51ad55e6096a47b7b4fb2d059c03b2358ff7398f3bfc04913acc45635` |
| disclosed host-side channels | `none` in the isolated hostile-config fixture |
| effective-policy fingerprint | not retained in the release handoff; the harness deleted the run-specific temporary provenance file at exit |

The fingerprint is the one incomplete provenance value: its input includes the
matrix's random fixture paths, so it cannot be truthfully regenerated after
cleanup. Do not substitute a newly computed value and call it the measured run.
The remaining tuple values above were independently rechecked against the same
host and source head. A different launcher, terminal executable hash, CLI,
adapter version, OS/kernel/architecture, or effective-policy fingerprint is an
uncalibrated tuple.

### Known workspace-write sandbox holes

`workspace-write` on the calibrated tuple has two measured Git-boundary holes:

- `hardlink-git-alias-write` is `allow`. The matrix changed the protected ref
  through a workspace hard link and reported
  `.git/refs/heads/codex-probe before=cb422285ff190c9e... after=c3f9de796983e5c0...`.
  Authorization is path-based: a hard link is a second path to the same inode,
  so the workspace path is writable even though the inode also names a file in
  `.git`. The corresponding symlink probe is `deny` because symlinks resolve to
  the protected path; hard links do not.

- Matrix run 5 at source head `d9f98ab` established that
  `submodule-resolved-git-dir-write` is `deny`: the resolved Git-dir `HEAD`
  write exited 1 and its before/after SHA-256 hashes were both
  `162e8e6f...`. `submodule-marker-write` is independently `allow`: the
  in-workspace `.git` marker write exited 0 and changed its SHA-256 from
  `00e17535...` to `b0465a6e...`. A submodule's `.git` marker is a plain file
  inside the workspace, so path-based `workspace-write` authorizes it;
  rewriting the marker can redirect where Git resolves that submodule's
  Git-dir. The top-level linked-worktree marker is not affected:
  `fresh-git-marker-write` remains `deny`.

This claim was wrong twice before the per-target diagnostic settled it: first
the bundled output was read as “the submodule Git-dir is writable,” then the
claim was withdrawn entirely. Keeping one target per case preserves the
opposite measured outcomes instead of collapsing them into one expectation.

This is a property of Codex's vendor `workspace-write` sandbox, not this
adapter. The retired companion passed the identical mode string to the same
core, so it had the same holes before this adapter and matrix existed.

The practical boundary stops an implementer from accidentally touching Git
state—the common failure, such as deciding to run `git commit`. It does not and
never did stop deliberate circumvention. P5 host-side channels (MCP, Apps,
hooks, plugins, and `notify`) are outside the child sandbox as described below.
If a future user needs defense against a deliberately misbehaving implementer,
a post-dispatch `.git` integrity check in the shape of Grok's
[`verify-worktree.sh`](../grok/verify-worktree.sh) is the known mitigation. It
is deliberately not built into this adapter.

The adapter scans only the initial delimited human banner block for
`approval:`, `sandbox:`, and the session id while teeing the full stream to
`transcript.log`; duplicate banner fields are rejected, and policy-looking
model output after the banner cannot override them. Seeing a calibrated
human-stream turn marker closes banner discovery permanently, so later output
also cannot synthesize a banner that was absent at startup. A mismatch kills only the
new Codex process group and fails nonzero. This is post-start detection that bounds
damage; it cannot undo a tool call already initiated, and a truthful banner
proves resolved CLI intent rather than kernel enforcement. The pinned argv is
the pre-launch protection.

### State and resume

State is keyed by the SHA-256 of the canonical workspace. A non-blocking
`fcntl.flock` is held across selection, child execution, and the final state
transition, and is released only when the wrapper process exits. The
authoritative `meta.tsv` lifecycle is `initializing → running → ready|failed`;
highest generation wins. `initializing` is written before any CLI exists and
`running` immediately before the spawn. A highest `initializing` or `running`
record refuses both fresh dispatch and resume, so a crashed wrapper cannot fall
back to an older live session. `current` is only a validated cache.

The lock file is also the holder record. Its single line is

```text
<holder-id> TAB wrapper_pid=N [TAB child_dispatch=ID TAB child_pgid=N [TAB child_start=S]]
```

The first two fields name whoever holds the lock now. The child fields name
the last CLI the workspace spawned: the generation it belongs to, its process
group (the child is started in its own session, so its pid is the group id),
and an opaque start-time identity. Later invocations carry the child fields
forward until the next spawn. `meta.tsv` and the generation directory did not
change for this: schema `1`, the same seven keys, the same four files. An
adapter from before this record and one from after it read each other's state;
the older one rewrites the lock line without the child fields, which only
costs a later recovery its process check.

Managed resume is release-enabled for the calibrated tuple above. `--resume`
selects the highest ready loop-owned exact id, and `--resume ID` additionally
asserts that id. It never selects unrelated interactive work. Reset the source
constant to `0` if the adapter argv, state schema, or pinned config keys change,
and leave it reset until `tests/integration-test.sh --require codex` recalibrates
the changed tuple. Signal handling, the lock file's holder line, and
`--recover-stale` changed none of the three: the argv builder, `meta.tsv`, the
pinned `-c` keys, and the record `--resume` selects are as calibrated.

The integration harness uses the shipped adapter while the release switch is
enabled. It retains a narrow recalibration fallback: when the mandated reset is
`0`, only the source constant is changed in a temporary copy for the two resume
probes, avoiding a circular gate. The stub selftest has no temporary copy; all
resume assertions exercise the shipped adapter.

Migration note: a session created by the former companion runtime has no loop
record. After finishing or cancelling any in-flight legacy job, use
`--resume-unmanaged <exact-id>` once; a successful turn adopts that id so later
ordinary `--resume` can use it. The same flag is the explicit exact-id resume
after a failed or recovered turn, described below.

### Stopping a dispatch and recovering a stale generation

**Stopping.** SIGTERM, SIGINT, and SIGHUP to the wrapper stop the dispatch: the
Codex process group gets SIGTERM, then SIGKILL after two seconds if any member
remains; the generation is recorded `failed`; `dispatch.end` is journaled with
the exit status; and the wrapper exits 128 plus the signal number (143, 130,
129). To cancel an in-flight dispatch, send the wrapper SIGTERM. A refused
concurrent dispatch names it: `workspace lock is held by <id> (wrapper pid N)`.
A disposition inherited as ignored is left ignored, so `nohup` keeps a dispatch
running through SIGHUP, and a job backgrounded by a non-interactive shell keeps
ignoring SIGINT. A closed output reader, which is how a parent session that
ended without signalling the wrapper appears, ends the dispatch the same way
with exit 141. A handled stop leaves nothing to recover.

**What still goes stale.** SIGKILL of the wrapper, or a host crash, runs no
handler. The record stays `running`, the CLI may still be alive, and the next
dispatch refuses with `highest generation is still running: <id>` and names
`--recover-stale`.

**Recovering.** From the workspace root, run the adapter with `--recover-stale`
and no other argument. It never dispatches, never signals a process, prints
only to stderr, and exits 0 when the workspace is dispatchable afterwards
(including when there was nothing to recover) or 5 when it refuses.

| what it finds, holding the workspace lock | verdict | `--recover-stale` | `--recover-stale-unverified` |
| --- | --- | --- | --- |
| the lock is held | the wrapper is alive | refuses, naming the holder | refuses |
| highest generation is `ready`, `failed`, or absent | nothing is stale | no change, exit 0 | no change, exit 0 |
| `initializing` | dead: no CLI was started | records `failed` | records `failed` |
| `running`; the recorded process group has no members | dead | records `failed` | records `failed` |
| `running`; the recorded pid is alive with the recorded start time | alive | refuses; prints the `kill` commands for the group | refuses |
| `running`; no process group is recorded for this generation | unverifiable | refuses; prints a `ps` check for this generation | records `failed`, labelled unverified |
| `running`; the group has members but its leader is gone or has another start time | unverifiable | refuses; prints how to list the members | records `failed`, labelled unverified |

The free lock is the proof that the wrapper is gone; the kernel releases it on
any death, and no pid comparison is as strong. Only two findings prove the CLI
dead: the generation never reached `running`, or its recorded process group is
empty. A start-time match proves it alive, and nothing overrides that: stop the
group with the printed commands and run `--recover-stale` again. A start-time
mismatch is never taken as proof of death, because a wrong answer there would
fail a generation whose CLI is still writing to the workspace.
`--recover-stale-unverified` is the operator's assertion for the rows the
adapter cannot decide; check with the printed command first.

No process group is recorded for a generation written by an adapter from before
this record, or when the wrapper was killed in the instant between spawning the
CLI and recording its group. The check does not see a descendant that moved
itself out of the CLI's process group.

**After recovery.** The generation is `failed`, and `--resume` refuses exactly
as it does after any failed turn: it selects only a highest `ready` record and
never an earlier one, even one with the same session id. This is deliberate. A
killed turn leaves the session with a partial turn and the workspace with
whatever that turn had written, so continuing is the operator's decision:
start a fresh dispatch, or name the session with `--resume-unmanaged
<exact-id>`. Recovery prints the recovered generation's session id and the
newest ready generation's. A successful turn makes plain `--resume` available
again.

Recovery writes no journal event. The wrapper that died never wrote
`dispatch.end`, and its exit status is unknown, so a loop run that recorded the
dispatch still shows it open. `loop-journal recover --acknowledge <id>` is the
journal's own acknowledgement and retires that run.

### External tools and foreground lifecycle

MCP servers, Apps, plugins, hooks, and `notify` run in the host agent process,
outside both shell sandboxes. The config scan discloses `mcp_servers`, `apps`,
`plugins`, and `notify`; it warns and proceeds by default, or refuses when
`CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1`. This is accepted exposure, not isolation.

There is no detached-job registry or cancel subcommand; cancelling is SIGTERM
to the wrapper, as above. Background the adapter at the harness level if
needed; its own exit is authoritative. The run state retains `prompt.txt`, an
append-only `transcript.log`, `last-message.txt`, and `meta.tsv` for diagnosis
after failure.
