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
-c 'sandbox_permissions=[]'
```

Resume accepts neither `-s` nor `-C`; omitting the explicit `sandbox_mode`
override would fall through to ambient config rather than inherit the original
thread policy. The adapter never uses `--last`, never passes `--json`, and
redirects the child stdin from `/dev/null`. It rejects policy broadeners,
including bypass flags, extra writable directories, profiles, config/rule
ignores, and feature toggles.

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

Managed resume is release-disabled until
`tests/integration-test.sh --require codex` executes every non-managed frozen
case with no skip or failure. While disabled, iterate with a fresh dispatch and
carry the prior findings in the prompt. Once enabled, `--resume` selects the
highest ready loop-owned exact id, and `--resume ID` additionally asserts that
id. It never selects unrelated interactive work.

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
