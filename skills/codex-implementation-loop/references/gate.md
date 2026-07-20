# Gate details

Companion to SKILL.md §5.

**Prefer serial.** For suites heavy in real I/O, file locks, fixed ports, or subprocess spawning, parallelism serializes on the shared resources anyway and often ends up *slower* than serial while making failures harder to attribute. Measure before assuming parallel helps.

Interpret results according to the **gate policy** dial. Under `baseline` — the usual case — the bar is no new non-flake failures relative to the base branch. Environment-specific flakes that also fail on the base branch aren't regressions, but say so explicitly rather than waving them off, and don't let "it's probably flaky" absorb a real failure. `run-gate.sh --baseline <log>` does that comparison mechanically, which beats eyeballing two lists.

When the gate is red, follow the **on-red** dial: `stop` hands it to the user; `iterate` sends the failures back to Codex for a bounded number of attempts. Either way the standard is the same — the code satisfies the test. If a proposed fix relaxes an assertion, deletes a case, or widens a tolerance to make red turn green, stop and raise it, because that converts a caught bug into a shipped one.

If the repo's CI is unreliable for reasons unrelated to code (billing, broken infra), the local gate is the real signal — note that plainly in the PR so a red CI badge isn't mistaken for a broken change.

Be honest about what the baseline gate proves and doesn't: it proves **no new failure identifiers** (pytest identifiers include the exception class; a message-only change in a known flake stays green by design), and that at least some tests executed — it does **not** prove the full calibrated suite ran. Compare the reported test count against the calibration record when it matters.

The gate's failure parsing understands **unittest and pytest** output. Under `--baseline`, any other runner fails closed with an unsupported-runner message rather than guessing — plain pass-through mode (no `--baseline`) works with any runner. Also under `--baseline`, a run must show real executed tests: skipped-only or empty output is red even on exit 0.

If the repo has no meaningful suite, say so instead of letting the gate silently pass on nothing: the bar becomes the tests this unit itself added, plus driving the affected flow once by hand. Flag the missing suite to the user as its own backlog item rather than quietly treating "no tests ran" as green.

## Consistency and normalization guarantees

- In **every** mode, a runner whose own summary reports failures (`=== N failed ===`, `FAILED (failures=N)`) while exiting 0 is distrusted and gates red — strict's "zero failures" is enforced, not assumed from the exit code.
- Test-execution evidence is taken only from formal summary lines (pytest's `=== ... ===` fence, unittest's `Ran N tests`), never from arbitrary output — error messages containing phrases like "1 passed" don't count.
- Failure-identifier normalization (`id [ExceptionClass]`) applies only when a pytest line contains exactly one raw ` - ` separator; any other shape — custom param IDs or messages containing ` - `, unbalanced brackets — keeps the whole line as the identifier. Consequence: volatile messages containing ` - ` read as changed failures (red). False-red on exotic flakes is accepted; false-green is not.
