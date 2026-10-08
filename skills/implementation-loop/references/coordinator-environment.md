# Coordinator environment block

`scripts/loop-coordinator` puts the text below the line into the `## Environment` section of every spec, replacing whatever the judge wrote there.

---
- Leave your changes in the working tree you are given. You may be working in a copy that has no git repository. The coordinator commits and publishes.
- Do not modify, delete, or rename git state. Do not commit or publish. Do not run any git command that changes state.
- Do not use MCP servers, app connectors, or any external service. Work with local files and the shell only.
- Do not run the full test suite. Run only the tests named in the Tests section, or nothing. The coordinator owns the full gate.
- When you are done, report the files you changed, the tests you added, which tests you ran, and their result.
