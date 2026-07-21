# Dispatch prompt skeleton

Companion to SKILL.md §2. The bullets there say what a prompt needs; this is the copy-ready shape.

A skeleton that has worked well:

```text
Unit: <one-line name>

## Why
<bug/goal, with the file:line evidence that motivated it>

## Change
<files, functions, shape of the change; known edge cases>

## Tests
<new tests expected; existing tests that will break and how to update them>

## Do not touch
<invariants, unrelated subsystems>

## Environment
- You run in the real environment; .git is read-only — leave changes in
  the working tree, I commit and publish.
- Do NOT use MCP servers, app connectors, or any external service — the
  sandbox does not bound them; work with local files and shell only.
- Do NOT run the full test suite. Run only <focused subset>, or nothing;
  I own the full gate.
- When done, report: files changed, tests added, which subset you ran
  and its result.
```
