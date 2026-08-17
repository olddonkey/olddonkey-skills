# Prototype

## Define the question

- State the empirical question the prototype will settle before choosing its shape.
- Name the evidence each plausible outcome would produce and the decision that would follow. A prototype is complete when it answers the question, not when it resembles production.

## Isolate the experiment

- Create a dedicated branch in an isolated worktree before any prototype change.
- Keep all prototype edits inside that disposable worktree. Never place them in a checkout containing pre-existing user work or use them to modify such work.
- Scope the prototype to the shortest path that can generate the deciding evidence.

## Decide and dispose

- Use the result to choose or reject the direction, and record what the prototype actually established.
- Once the direction is chosen, abandon the prototype code in place: never merge it, copy it into the target work, or let it touch pre-existing user work.
- Depart from that disposition only when the user explicitly promotes the prototype. Promotion leads first to a production plan; it is not an automatic integration step.

On a plan-only route, stop with the question, experiment design, and resulting plan. Otherwise, hand the isolated prototype unit to the implementation loop under the [unit contract](../adapter.md#canonical-token-map).
