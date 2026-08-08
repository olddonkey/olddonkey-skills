# Verification contract

This contract applies to every code-changing engineering-mode run, including fast-path runs.

## Classifications

- `artifact` is an evidence level: exercise the real affected surface and record its surface, setup, action, observable, oracle, and evidence.
- `focused` is an evidence level: a narrower executable oracle suffices; state why it is sufficient.
- `manual_ceiling` is a condition: credentials, hardware, or policy prevent stronger evidence. Name exactly what remains unverified and give the user a concrete checklist.
- `not_applicable` is a scope statement: only non-runtime content changed; state the reason.

Valid REQUIRED values are `artifact`, `focused`, and `not_applicable`. `manual_ceiling` is never a valid requirement: it is an achieved condition, discovered rather than demanded.

The report records the required classification, achieved classification, and oracle result: `passed`, `failed`, `error`, `not-run`, or `n/a`.

## Sufficiency pairs

| required ↓ / achieved → | `artifact` | `focused` | `manual_ceiling` | `not_applicable` |
| --- | --- | --- | --- | --- |
| `artifact` | sufficient | **insufficient** | **insufficient** (ceiling stated) | invalid pairing |
| `focused` | sufficient | sufficient | **insufficient** (ceiling stated) | invalid pairing |
| `not_applicable` | invalid pairing | invalid pairing | invalid pairing | sufficient |

## Two-axis completion

For `artifact` and `focused`, verification is complete only when the pair is sufficient **and** the oracle passed. Oracle `n/a` is invalid for these evidence levels. A sufficient pair with oracle `failed` is failed verification and blocks completion: the change does not work. A sufficient pair with `error` or `not-run` is incomplete.

For `not_applicable`, record oracle `n/a`. Completion requires a sufficient pair and a validated reason that the change is non-runtime only.

An observed failure is never hidden. An insufficient pair with a failing oracle is reported as both incomplete and failed; an insufficient pair without a failing oracle is incomplete. No non-complete state is ever reported as success.

This contract supplements the kernel's full-suite gate and never replaces it. `focused` describes the artifact-verification level; it is not permission to skip the gate.

## Binding

The verdict binds to the candidate Git tree derived from the verified worktree. At a stop point that creates a commit, bind it to the candidate commit SHA under the kernel's publish rules.

At `stop=worktree`, run [`tree-oid.sh`](../scripts/tree-oid.sh) with no arguments from the target worktree root immediately **before** the verification run and again immediately **after** it. Its caller-facing interface is:

- Exit `0`: success; stdout contains exactly one tree OID.
- Exit `1`: operational failure; stdout is empty and diagnostics go to stderr.
- Exit `3`: worktree binding is unavailable; stdout is empty and stderr contains a one-line cause.

The verdict is valid only when both runs exit `0` and the two OIDs are equal.

The worktree tree id identifies the tree produced by staging the complete non-ignored worktree with `git add -A` in a throwaway index. It includes tracked and untracked contents and excludes ignored files. It is narrower than what a commit could contain because a commit may stage selectively.

Two exclusions must be disclosed:

- Content is clean-filter normalized, so raw bytes that normalize identically are indistinguishable; large filter or LFS pipelines can also make this slow.
- Submodule internals appear only as gitlink SHAs.

Worktree binding is unavailable when any of these conditions exists:

- A registered submodule is modified.
- A populated registered submodule's own index, at any recursive depth, has change-suppression flags.
- An unregistered embedded repository would be absorbed as a gitlink.
- Any entry has `skip-worktree`; sparse checkouts are therefore a disclosed can't-bind limitation.
- A gitlink has `assume-unchanged`.

For ordinary entries, `assume-unchanged` bits are cleared only in the throwaway index so their worktree content is certified; the real index retains its flags. On exit `3`, disclose the cause in the report; the verdict is at best incomplete. A commit-binding stop point resolves a modified registered submodule only when every changed submodule is separately committed and clean, so its gitlink identifies real content. Committing the superproject alone binds nothing inside submodules, and authorization to commit the superproject grants nothing in another repository. Never create a commit solely to bind a verdict.
