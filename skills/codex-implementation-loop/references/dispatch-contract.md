# Dispatch contract

Every backend dispatch script implements the same observable contract; `codex-dispatch.sh` is the current implementation.

The common contract accepts `--prompt-file PATH` / `--prompt TEXT`, `--model M`, `--effort E`, `--read-only|--investigate`, `--resume`, and `-h` / `--help`. It runs from the target repo root; prints a summary block naming the workspace, CLI version, model and effort actually in force with their provenance, mode, resume state, and the session or thread id where the CLI reports one; guards prompt text against being parsed as flags; and forwards nothing the caller did not choose, so absent flags inherit the user's own CLI config.

Per-backend flags beyond the contract are allowed where a real capability exists and must not contradict the contract. Environment-variable overrides are namespaced per backend (`CODEX_LOOP_*` today).

`--background` is companion-only: the Codex companion owns detached-job lifecycle. A dispatch script without a companion runs strictly foreground, its own exit is the authoritative completion signal, and backgrounding happens at the harness level. Resume uses the exact id from the prior dispatch summary wherever that id is capturable; recency-based resume is a disclosed fallback.
