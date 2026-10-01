# product-direction-v1 judge-side tools

These are the judge-side scripts the overnight run of 2026-09-28 used. They are
evidence for claims in `../product-direction-v1.md` §4, **not** part of the
shipped implementation-loop skill, and nothing in the skill calls them.

- `claude-dispatch.sh` — the sandboxed `claude -p` implementer dispatch
  (git-less copy → `--restricted` Claude Code with a closed tool allowlist
  and the OS sandbox → init tool-surface check → strict result contract →
  patch → `git apply`). Not a registered loop backend: it writes no
  `dispatch.*` journal events.
- `claude-dispatch-selftest.sh` — stub-driven selftest for it (32 checks).
- `ci-gate.sh` — host replica of `.github/workflows/selftest.yml`: extracts
  every `run:` step verbatim and runs each in a fresh `bash -e`.

Paths in the scripts assume the author's machine (`~/.local/bin/claude`,
`~/.config/olddonkey-loop/opus-work`). A future unit that wants a Claude
Code backend should start from `backends/cursor/` and these notes, not from
these files as-is.
