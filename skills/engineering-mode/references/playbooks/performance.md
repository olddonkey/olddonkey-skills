# Performance

## Set the measurement contract before code

Settle and record all four items before touching code:

1. **Metric:** name the quantity, unit, direction of improvement, and success threshold.
2. **Workload:** fix the inputs, data size and shape, concurrency, operation mix, and duration or iteration count that represent the goal.
3. **Noise controls:** control the material sources of variance, such as warm-up, cache state, background load, seeds, and resource limits.
4. **Measurement command:** write the exact repeatable command, including setup and relevant configuration.

Do not optimize against an unsettled or changing measurement contract.

## Record the baseline

- Run the measurement before implementation. Where variance can affect the decision, retain repeated raw samples and a summary rather than a single result.
- Record enough environment identity to reproduce the comparison, including the candidate revision, runtime and dependency versions, hardware or resource allocation, and material configuration.
- If baseline noise is large enough to obscure the success threshold, repair the measurement before changing code.
- Put commands, raw output, samples, summaries, and environment records in the run directory's `evidence/`. Never write measurement artifacts into the target tree.

## Shape measured units

- Give each unit exactly one measured hypothesis.
- State the proposed causal mechanism and the predicted metric movement. Keep unrelated cleanup and a second hypothesis out of the unit.
- Make the unchanged measurement contract part of the unit's acceptance evidence.

## Judge the result

- Compare before and after with the same workload, environment, command, and noise controls. If they differ materially, label the results incomparable and remeasure.
- Compare repeated samples when variance matters; report the distribution or dispersion needed to support the conclusion.
- Moving work outside the measured window is not a win. Expand the window to cover the displaced work and measure again.
- Keep every after-result and comparison artifact beside the baseline in the run directory's `evidence/`, never in the target tree.

On a plan-only route, stop with the plan. Otherwise, hand the current single-hypothesis unit to the implementation loop under the [unit contract](../adapter.md#canonical-token-map); after implementation, apply this comparison before accepting it, and leave the [full-suite gate](../adapter.md#canonical-token-map) to the loop.
