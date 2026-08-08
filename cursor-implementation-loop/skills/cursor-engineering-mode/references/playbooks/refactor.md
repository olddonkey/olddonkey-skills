# Refactor

## Fix the behavioral boundary

- Name the observable behavior that must not change before forming refactor units.
- Identify the existing observable baseline that demonstrates that behavior, including its inputs, outputs, side effects, and relevant failure behavior.

## Decide whether preparation is code

- If the existing observable baseline is sufficient, use it directly; no preparatory unit is needed.
- If characterization tests must be created first, make their creation a separate preparatory kernel unit. The wrapper never writes those tests or any other code.
- Complete and observe that preparatory unit before forming a unit that changes structure. Do not combine missing characterization with the refactor it is meant to constrain.

## Form behavior-preserving units

- Bound each refactor unit by the named unchanged behavior and the established baseline.
- Treat any intended behavior change as separate work, not as part of the refactor.

On a plan-only route, stop with the plan. Otherwise, hand the preparatory unit first when required; when it is not, hand the first refactor unit to the implementation loop under the [unit contract](../adapter.md#canonical-token-map).
