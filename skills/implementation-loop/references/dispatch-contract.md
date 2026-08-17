# Dispatch contract

Every backend dispatch script implements the same observable contract; the
shipping implementations are `codex-dispatch.sh`, `grok-dispatch.sh`, and
`cursor-dispatch.sh`.

The common contract accepts `--prompt-file PATH` / `--prompt TEXT`, `--model M`, `--effort E`, `--read-only|--investigate`, `--resume`, and `-h` / `--help`. It runs from the target repo root; prints a summary block naming the workspace, CLI version, model and effort actually in force with their provenance, mode, resume state, and the session or thread id where the CLI reports one; and guards prompt text against being parsed as flags. Codex and grok leave absent model flags to their backend configuration; cursor-agent deliberately pins its calibrated `cursor-grok-4.6-xhigh` default because its containment contract requires an explicit `--model` invocation.

Per-backend flags beyond the contract are allowed where a real capability exists and must not contradict the contract. Environment-variable overrides are namespaced per backend (`CODEX_LOOP_*`, `GROK_LOOP_*`, and `CURSOR_LOOP_*`). cursor-agent has no separate effort flag, so its `--effort` contract option asserts the effort embedded in `--model`. Its `--resume` contract option fails with a fresh-dispatch iterate instruction because copy state, not thread state, carries an implementation round forward.

All three adapters run strictly foreground: their own exit is the authoritative completion signal, and backgrounding happens at the harness level. Codex and grok use the exact id from loop-owned state wherever their runtime permits resume; neither may fall back to a newest-session selector. Codex resume stays release-disabled until its required real-backend matrix passes. cursor-agent refuses resume and carries iterate state through the applied worktree plus a fresh prompt.
