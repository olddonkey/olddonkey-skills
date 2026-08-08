# Codex adapter

This file is platform-specific. It maps the shared playbooks' canonical tokens to the concrete Codex implementation-loop interface.

## Canonical token map

| Canonical token | Concrete Codex interface | Kernel source |
| --- | --- | --- |
| `investigation dispatch` | Select the kernel's `read-only` dispatch mode with `--read-only` on `skills/codex-implementation-loop/scripts/codex-dispatch.sh`. | `skills/codex-implementation-loop/SKILL.md` §Dials, “Dispatch mode,” and §2, “Dispatch” |
| `unit contract` | Use the dispatch-prompt skeleton at `skills/codex-implementation-loop/references/dispatch-prompt.md`. Its contract includes the kernel's bug-fix regression-test-in-spec rule. | `skills/codex-implementation-loop/SKILL.md` §2, “Dispatch,” and §4, “Iterate” |
| `full-suite gate` | Use `skills/codex-implementation-loop/scripts/run-gate.sh` as specified by the kernel. | `skills/codex-implementation-loop/SKILL.md` §5, “Gate” |

Keep concrete platform tokens here; shared playbooks use only the canonical names.

This adapter is deliberately excluded from the cross-package byte-equality check. The Cursor package gets its own `adapter.md`, mapping the same tokens to the `investigate` dial and Task dispatch rather than copying this file.
