# Cursor adapter

This file is platform-specific. It maps the shared playbooks' canonical tokens to the concrete Cursor implementation-loop interface.

## Canonical token map

| Canonical token | Concrete Cursor interface | Kernel source |
| --- | --- | --- |
| `investigation dispatch` | Select the kernel's `investigate` mode for a native Task dispatch: a read-only subagent that produces an argument, not a diff. | `cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md` §Dials, “Dispatch mode,” and the `investigate` description |
| `unit contract` | Use the Task-prompt skeleton at `cursor-implementation-loop/skills/cursor-implementation-loop/references/unit-contract.md`. Its contract includes the kernel's bug-fix regression-test-in-spec rule. | `cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md` §2, “Dispatch,” and §4, “Iterate” |
| `full-suite gate` | Use `cursor-implementation-loop/skills/cursor-implementation-loop/scripts/run-gate.sh` as specified by the kernel. | `cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md` §5, “Gate” |

Keep concrete platform tokens here; shared playbooks use only the canonical names.

The enforcement caveats remain authoritative in the [Cursor runtime reference](../../cursor-implementation-loop/references/cursor-runtime.md): model pinning is intent, not proof, because silent fallback is possible—check completion output for signs; every follow-up resumes the recorded agent ID; only one writable subagent may operate in a worktree; and “do not use Git” is a prompt rule, not mechanical enforcement. Use worktree isolation for higher-risk unattended work.

This adapter is deliberately excluded from the cross-package byte-equality check. The Codex package has its own `adapter.md`, mapping the same tokens to the `read-only` dial.
