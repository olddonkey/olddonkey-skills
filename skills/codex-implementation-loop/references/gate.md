# Gate details

Companion to SKILL.md §5.

**Prefer serial.** For suites heavy in real I/O, file locks, fixed ports, or subprocess spawning, parallelism serializes on the shared resources anyway and often ends up *slower* than serial while making failures harder to attribute. Measure before assuming parallel helps.

Interpret results according to the **gate policy** dial. Under `baseline` — the usual case — the bar is no new non-flake failures relative to the base branch. Environment-specific flakes that also fail on the base branch aren't regressions, but say so explicitly rather than waving them off, and don't let "it's probably flaky" absorb a real failure. `run-gate.sh --baseline <log>` does that comparison mechanically, which beats eyeballing two lists.

When the gate is red, follow the **on-red** dial: `stop` hands it to the user; `iterate` sends the failures back to Codex for a bounded number of attempts. Either way the standard is the same — the code satisfies the test. If a proposed fix relaxes an assertion, deletes a case, or widens a tolerance to make red turn green, stop and raise it, because that converts a caught bug into a shipped one.

If the repo's CI is unreliable for reasons unrelated to code (billing, broken infra), the local gate is the real signal — note that plainly in the PR so a red CI badge isn't mistaken for a broken change.

Be honest about what the baseline gate proves and doesn't: it proves **no new failure identifiers** (pytest identifiers include the exception class; for ordinary single-separator lines a message-only change in a known flake stays green — messages containing ` - ` keep whole-line identity and go red, see the guarantees below), and that at least some tests executed — it does **not** prove the full calibrated suite ran. Compare the reported test count against the calibration record when it matters.

The gate's failure parsing understands **unittest and pytest** output. Under `--strict` or `--baseline`, any other runner fails closed with an unsupported-runner message rather than guessing — plain pass-through mode (no policy flag) works with any runner but is the weakest: it judges by exit code alone (plus the summary/exit consistency override), so empty output and zero-test runs pass. Use `--strict` for the strict policy on unittest/pytest suites; reserve plain mode for unsupported runners and say so in the report. Under `--strict` and `--baseline`, a run must show real executed tests: skipped-only or empty output is red even on exit 0, and `--strict` additionally rejects any parsed failure line even when the final summary is clean.

If the repo has no meaningful suite, say so instead of letting the gate silently pass on nothing: the bar becomes the tests this unit itself added, plus driving the affected flow once by hand. Flag the missing suite to the user as its own backlog item rather than quietly treating "no tests ran" as green.

## Consistency and normalization guarantees

- In **every** mode, a runner whose own final summary reports failures or errors (`=== N failed ===`, `=== N error ===`, quiet-mode `N failed in Xs`, subtest terms like `N failed, M subtests passed`, `FAILED (failures=N)`) while exiting 0 is distrusted and gates red.
- `--strict` enforces zero failures mechanically: a recognized unittest/pytest verdict, executed tests (>0, not skipped-only), and no parsed failure lines — anything else is red, on exit 0 or otherwise. Plain no-flag mode is an exit-code pass-through and makes none of these guarantees.
- Test-execution evidence comes from the **last** formal runner verdict in the log — a pytest summary (fenced `=== ... ===` or full-shape `-q` bottom line) or a unittest block (`Ran N tests` + its OK/FAILED result), **whichever runner reported last** — never from arbitrary output. Error messages containing phrases like "1 passed", or an inner runner's output captured mid-log (a test that shells out to unittest inside a pytest suite, or vice versa), don't count in either direction: the real runner's verdict is always the final one printed.
- All parsing reads an ANSI-stripped view of the log, so forced-color output (`pytest --color=yes`) is recognized normally; the log file on disk keeps the raw bytes. Parsers run bytewise (`LC_ALL=C`) so a log containing invalid UTF-8 bytes cannot poison them, and if normalization itself fails the gate refuses to judge and fails closed.
- Failure-identifier normalization (`id [ExceptionClass]`) applies only when a pytest line contains exactly one raw ` - ` separator; any other shape — custom param IDs or messages containing ` - `, unbalanced brackets — keeps the whole line as the identifier. Consequence: volatile messages containing ` - ` read as changed failures (red). False-red on exotic flakes is accepted; false-green is not.
- pytest 9 native subtest failures are fingerprinted from their `SUBFAILED(param)`/`SUBFAILED[msg]` lines, which carry the specific failing subtest — a different subtest failing under the same parent test is a new failure, not a baseline match.
