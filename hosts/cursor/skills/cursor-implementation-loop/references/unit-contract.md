# Unit contract skeleton

Companion to SKILL.md §2. The bullets there say what a dispatch needs; this
is the copy-ready shape of the Task prompt you send to the implementer
subagent. The subagent starts with a clean context — it sees nothing you
don't put here.

```text
Unit: <one-line name>

## Why
<bug/goal, with the file:line evidence that motivated it>

## Change
<files, functions, shape of the change; known edge cases>

## Tests
<new tests expected; existing tests that will break and how to update them —
never deleted, never weakened>

## Do not touch
<invariants, unrelated subsystems, off-limits files>

## Environment
- Leave all changes in the working tree. Do NOT create branches, commit,
  push, open PRs, or merge — the parent owns git.
- Do NOT use MCP servers, app connectors, or any external service — work
  with local files and shell only.
- Do NOT run the full test suite. Run only <focused subset>, or nothing;
  the parent owns the full gate.
- When done, report: files changed, tests added, which subset you ran and
  its result. Your report is a claim; the diff is the evidence.
```

Two Cursor-specific notes:

- **Record the agent ID** the dispatch returns. Review findings, gate
  failures under on-red=`iterate`, and any follow-up for this unit resume
  that same agent — a fresh dispatch has no memory of the unit.
- **Findings you send back should be specific**: what's wrong, why it
  matters, what you expect instead — with file:line. "Please fix the review
  comments" resumes the thread but wastes it.
