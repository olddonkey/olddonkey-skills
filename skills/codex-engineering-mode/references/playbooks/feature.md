# Feature

## Set the product contract before decomposition

- Write acceptance criteria in observable terms, including the success path, material edge cases, and failure behavior.
- Name the core data shape: identities, required and optional fields, invariants, lifecycle or state transitions, and the boundaries where the shape enters or leaves the system.
- Resolve material ambiguity in the criteria or data shape before dividing the work into units.

## Check the blast radius

- Find the affected callers before the plan is final. Inspect who constructs, reads, writes, serializes, persists, or presents the changed shape or behavior.
- For each affected caller, record whether it changes, remains compatible, needs migration, or needs explicit protection.
- Revise the criteria and data shape when caller evidence exposes a missing case. Do not finalize a plan from the callee alone.

Only after those checks, decompose the feature into ordered units. On a plan-only route, stop with the plan. Otherwise, hand the units to the implementation loop one at a time under the [unit contract](../adapter.md#canonical-token-map).
