# Dispatch contract

Every backend dispatch script implements the same observable contract. The
shipping implementations are `backends/codex/dispatch.sh`,
`backends/grok/dispatch.sh`, and `backends/cursor/dispatch.sh`; their capability
metadata and execution-wrapper fixtures are registered in
`backends/backends.tsv`. The contract suites discover `backends/*/dispatch.sh`
and cross-check that set against the manifest in both directions.

The common contract accepts `--prompt-file PATH` / `--prompt TEXT`, `--model M`, `--effort E`, `--read-only|--investigate`, `--resume`, and `-h` / `--help`. When both prompt forms are present, `--prompt-file` wins. Missing values, unknown flags, an absent prompt, and `--background` fail closed; repeated flags are last-wins; prompt text beginning with `--` remains data. It runs from the target repo root; prints a summary block naming the workspace, CLI version, model and effort actually in force with their provenance, mode, resume state, and the session or thread id where the CLI reports one; and guards prompt text against being parsed as flags. Codex additionally distinguishes `sandbox (requested)` from `sandbox (CLI reported)`. Codex and grok leave absent model flags to their backend configuration; cursor-agent deliberately pins its calibrated `cursor-grok-4.6-xhigh` default because its containment contract requires an explicit `--model` invocation.

Per-backend flags beyond the contract are allowed where a real capability exists and must not contradict the contract. Environment-variable overrides are namespaced per backend (`CODEX_LOOP_*`, `GROK_LOOP_*`, and `CURSOR_LOOP_*`). cursor-agent has no separate effort flag, so its `--effort` contract option asserts the effort embedded in `--model`. Its `--resume` contract option fails with a fresh-dispatch iterate instruction because copy state, not thread state, carries an implementation round forward.

All three adapters run strictly foreground: their own exit is the authoritative completion signal, and backgrounding happens at the harness level. Codex and grok use the exact id from loop-owned state wherever their runtime permits resume; neither may fall back to a newest-session selector. Codex resume is release-enabled for the calibrated 2026-08-17 tuple recorded in `backends/codex/runtime.md`; a changed adapter argv, state schema, pinned config set, or host tuple requires recalibration. cursor-agent refuses resume and carries iterate state through the applied worktree plus a fresh prompt.

`tests/contract-core.sh` enforces the shared rules against every registered real
adapter through its fixture driver. `tests/contract-negative.sh` supplies one
deliberately broken adapter per shared rule and requires the core suite to name
the correct failure, preventing skipped or vacuous assertions. These are stubbed
conformance checks, not sandbox evidence; authenticated boundary evidence stays
in the opt-in `tests/integration-test.sh` gate.
