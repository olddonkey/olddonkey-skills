# Dials — full rationale

Detail companion to the codex-implementation-loop skill: why each dial has the options and default it does. The table and compressed interactions live in SKILL.md.

**Stop point** decides how far each unit travels — leave changes in the working tree, commit to a branch, open a PR, or merge. It's the only dial that bounds irreversible action, which makes it the one worth being explicit about. `pr` is the recommendation because a PR is a reviewable artifact that costs nothing to abandon, while merging is the step you can't quietly undo — but per the boundary above, reaching `pr` at all requires the user to have actually chosen it. Only use `merge` when the user has actually authorized autonomous merging; that authorization is per-repo and doesn't transfer between repos; once given and recorded in calibration it persists across sessions until the user revokes it or the work changes character (see calibration).

Stop point and cadence interact: with a stop point short of `merge`, the unit hasn't landed when the next one would start, so `continuous` stacks unit 2 on top of unit 1's unmerged changes — diffs blur together and review attribution breaks. Unless the user deliberately wants stacked branches, pair `worktree`/`commit`/`pr` with `confirm` (or wait for each unit to land before dispatching the next); `continuous` really fits `merge`.

**Dispatch mode** — `read-only` (`--read-only`) runs Codex without write access for diagnosis, code reading, or a design proposal. Treat it as a different activity rather than a cautious implement: there's no diff, so there's nothing to review, gate, or publish, and the output is an argument you should evaluate on its merits rather than a change you can verify. The productive pairing inside the loop: on a gnarly problem, `read-only` first to investigate and settle the design, then a normal `implement` dispatch against the settled spec.

**Gate policy** — `baseline` accepts no new non-flake failures relative to the base branch, which is the honest bar on a suite with known environment flakes. `strict` demands zero failures and suits clean suites. `skip` is only defensible for changes with no runtime surface at all (docs, comments); if a change touches code, something can break, so skipping is how a regression ships. Say which policy is in effect when you report the result.

**On gate red** — `stop` brings failures to the user. `iterate` sends them back to Codex automatically, which is efficient for obvious breakage but needs two boundaries: cap the attempts (two or three) so a stuck loop surfaces instead of grinding, and hold the line that a fix means the code satisfies the test, never the test bending to the code. If Codex's fix weakens an assertion, that's a stop, not a pass.

**Review depth** — `standard` is the checklist in SKILL.md §3 (full detail: review-checklist.md in this directory). `deep` adds an independent reviewer that hasn't seen the dispatch prompt, which is worth the cost when a change touches a correctness or security boundary, concurrency, migrations, auth, or money — places where a plausible-looking diff can be wrong in ways the author's framing hides. `light` still reads the whole diff; it just spends less time hunting on genuinely mechanical edits. Depth is a dial on rigor, not permission to skip reading the diff.

**Cadence** — `continuous` moves to the next unit without checking in, which is the point of a loop once the user trusts it. `confirm` pauses after each unit. Worth asking once up front, because assuming `continuous` on the first run means a lot of merged work before anyone looks.

**Fix lane** — who implements bug fixes. `codex` (the default) means every fix is a unit: diagnosis and spec are your lane, the change itself is Codex's, and review keeps its independence because the reviewer didn't write the fix. This is the dial most prone to silent drift — hand-fixing always feels faster in the moment, and each hand-fix quietly re-inverts the division of labor the user asked for. `claude-trivial-ok` is a user-granted carve-out for mechanical one-liners (a typo, a quoting fix, a comment) where a dispatch round genuinely costs more than the change; it must be explicitly granted, never assumed, and anything touching logic still goes to Codex. Under the carve-out the gate still runs — it's the only independent check left when implementer and reviewer are the same mind.

## Calibration record format

A one-line record keeps the calibration greppable across sessions, e.g.:

```text
codex-loop: stop=merge mode=implement gate=baseline on-red=iterate(max2) depth=standard cadence=continuous fix=codex tier=inherit kickoff=ask
            model=inherit effort=inherit serial ci=untrusted
            suite="PYTHONPATH=src python3 -m unittest discover -s tests" (~700s)
```
