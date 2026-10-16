# Dispatch contract

Every backend dispatch script implements the same observable contract. The
shipping implementations are `backends/codex/dispatch.sh` and
`backends/claude/dispatch.sh`; their capability
metadata and execution-wrapper fixtures are registered in
`backends/backends.tsv`. The contract suites discover `backends/*/dispatch.sh`
and cross-check that set against the manifest in both directions.

The manifest is `#schema=2` with eight tab-separated columns per backend.
Column 8, `final_message`, names the final message inside the dispatch's
`state_dir`. Its grammar is `FILE` or `FILE#KEY`, where `FILE` is a file name
and `KEY` names a string member of a JSON object in that file. The file and
member named here are part of the adapter's observable interface. Current
location is `last-message.txt` for both claude and codex. The contract suite checks the
extracted UTF-8 bytes against the scripted final message without trimming.

The common contract accepts `--prompt-file PATH` / `--prompt TEXT`, `--model M`, `--effort E`, `--read-only|--investigate`, `--resume`, and `-h` / `--help`. When both prompt forms are present, `--prompt-file` wins. Missing values, unknown flags, an absent prompt, and `--background` fail closed; repeated flags are last-wins; prompt text beginning with `--` remains data. It runs from the target repo root; prints a summary block naming the workspace, CLI version, model and effort actually in force with their provenance, mode, resume state, and the session or thread id where the CLI reports one; and guards prompt text against being parsed as flags. Codex additionally distinguishes `sandbox (requested)` from `sandbox (CLI reported)`. Codex leaves absent model flags to its backend configuration; claude leaves absent model and effort flags to the Claude CLI.

Per-backend flags beyond the contract are allowed where a real capability exists and must not contradict the contract. Environment-variable overrides are namespaced per backend (`CODEX_LOOP_*` and `CLAUDE_LOOP_*`).

Both adapters run strictly foreground: their own exit is the authoritative completion signal, and backgrounding happens at the harness level. Codex uses the exact id from loop-owned state wherever its runtime permits resume and may not fall back to a newest-session selector. Codex resume is release-enabled for the calibrated 2026-08-17 tuple recorded in `backends/codex/runtime.md`; a changed adapter argv, state schema, pinned config set, or host tuple requires recalibration. claude refuses resume, with a fresh-dispatch iterate instruction, and carries iterate state through the applied worktree plus a fresh prompt.

Every adapter keeps its own run state private (0600 files, 0700 directories), but what the implementer creates belongs to the engineer: a file or directory that reaches the real worktree carries the modes the caller's umask gives (0666 and 0777 masked by it), the same as a command run from the engineer's own shell. Codex writes into the worktree directly and starts the CLI under the caller's mask; claude applies its patch under it. The `worktree-umask` rule in `tests/contract-core.sh` dispatches under umask 027 and requires the implementer's new file to be 0640 and its new directory 0750 in the delivered workspace.

`tests/contract-core.sh` enforces the shared rules against every registered real
adapter through its fixture driver. `tests/contract-negative.sh` supplies one
deliberately broken adapter per shared rule and requires the core suite to name
the correct failure, preventing skipped or vacuous assertions. These are stubbed
conformance checks, not sandbox evidence; authenticated boundary evidence stays
in the opt-in `tests/integration-test.sh` gate.
