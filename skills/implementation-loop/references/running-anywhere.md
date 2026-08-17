# Running an adapter anywhere

Each backend is a self-contained module. Invoke its `dispatch.sh` by absolute
path while the current directory is the target repository root:

```bash
/absolute/path/to/implementation-loop/backends/codex/dispatch.sh --prompt-file /tmp/unit-prompt.txt
/absolute/path/to/implementation-loop/backends/grok/dispatch.sh --prompt-file /tmp/unit-prompt.txt
/absolute/path/to/implementation-loop/backends/cursor/dispatch.sh --prompt-file /tmp/unit-prompt.txt
```

The same commands work from a Cursor terminal or agent shell, a plain local
shell, and CI. After Unit 1, each backend needs only its own authenticated CLI:
`codex`, `grok`, or `cursor-agent`. None needs a Claude Code plugin.

In installed-skill examples, `${CLAUDE_SKILL_DIR}` is a path placeholder that
the host substitutes with this skill's absolute install directory. It is not an
environment variable the adapters read and not a runtime dependency. Hosts that
do not substitute it should replace it with the absolute install path directly.

The adapters remain foreground processes. Background them in the calling
harness if needed, and retain their real exit or signal status as the completion
authority. The one-release wrappers under `scripts/` exist only for migration;
new callers should use `backends/<name>/dispatch.sh`.
