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
`f1690f47b84f83fe50875470daf4f83ee5216fa1`. Twenty-six frozen expectations
matched and none skipped; two probes measured vendor-sandbox holes described
below, and the aggregate gate was the third failure because those rows still
expected denial. Both resume probes matched: repository write `allow`, Git-state
write `deny`.

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
- `submodule-git-dir-write` is `allow`: a write to the resolved submodule
  Git-dir changed its target on this tuple.

These are properties of Codex's vendor `workspace-write` sandbox, not this
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
transition. The authoritative `meta.tsv` lifecycle is
`initializing → running → ready|failed`; highest generation wins. A highest
`initializing` or `running` record refuses both fresh dispatch and resume, so a
crashed wrapper cannot fall back to an older live session. `current` is only a
validated cache.

Managed resume is release-enabled for the calibrated tuple above. `--resume`
selects the highest ready loop-owned exact id, and `--resume ID` additionally
asserts that id. It never selects unrelated interactive work. Reset the source
constant to `0` if the adapter argv, state schema, or pinned config keys change,
and leave it reset until `tests/integration-test.sh --require codex` recalibrates
the changed tuple.

The integration harness uses the shipped adapter while the release switch is
enabled. It retains a narrow recalibration fallback: when the mandated reset is
`0`, only the source constant is changed in a temporary copy for the two resume
probes, avoiding a circular gate. The stub selftest has no temporary copy; all
resume assertions exercise the shipped adapter.

Migration note: a session created by the former companion runtime has no loop
record. After finishing or cancelling any in-flight legacy job, use
`--resume-unmanaged <exact-id>` once; a successful turn adopts that id so later
ordinary `--resume` can use it.

### External tools and foreground lifecycle

MCP servers, Apps, plugins, hooks, and `notify` run in the host agent process,
outside both shell sandboxes. The config scan discloses `mcp_servers`, `apps`,
`plugins`, and `notify`; it warns and proceeds by default, or refuses when
`CODEX_LOOP_BLOCK_EXTERNAL_TOOLS=1`. This is accepted exposure, not isolation.

There is no detached-job registry or cancel subcommand. Background the adapter
at the harness level if needed; its own exit is authoritative. The run state
retains `prompt.txt`, an append-only `transcript.log`, `last-message.txt`, and
`meta.tsv` for diagnosis after failure.
