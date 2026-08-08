# Bug fix

## Reproduce before specifying

- Define the failure at the goal level: name the user-visible or system-observable result that is wrong.
- Build or reuse the smallest faithful reproduction before writing any fix spec. Record its inputs, preconditions, action, and observed result.
- Treat “a bug you can't reproduce you can't prove fixed” as the entry criterion. If the failure does not reproduce, keep narrowing its conditions; do not guess a fix.

## Establish root cause

- Trace the reproduced failure through the relevant state and control flow.
- Distinguish the trigger from the defect. A candidate cause is sufficient only when it explains the goal-level failure and the available counterevidence.
- Settle the root cause before specifying the fix. Scope the fix to the causal mechanism, not merely the visible symptom.

## Form the unit

- Carry the reproduction evidence and root-cause account into the spec.
- Take every post-spec requirement from the [unit contract](../adapter.md#canonical-token-map); do not duplicate that contract here.

On a plan-only route, stop with the plan. Otherwise, hand the completed unit to the implementation loop under the unit contract.
