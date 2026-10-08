# Coordinator iteration prompt

`scripts/loop-coordinator` sends the text below the line to the implementer in a fresh implement dispatch after an iterate verdict. Values are filled once. The previous verdict is JSON, one value per line.

---
You are implementing the approved spec below. Earlier rounds' changes are already in your working tree. Resolve every finding from the previous round without undoing the rest of the work. Leave your changes in the working tree.

## Approved spec
{{SPEC}}

## Previous round verdict (JSON lines: summary, then each finding)
{{VERDICT_LINES}}
