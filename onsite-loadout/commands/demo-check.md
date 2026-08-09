# /demo-check — pre-demo verification (run at FREEZE, ~16:15)

You are running the pre-demo checklist. **Write no new feature code.** Execute every check for real — do not assume or skip. Finish with a single status table.

1. **Repo state**: run `git status`. Anything uncommitted → commit it (or stash if experimental). Confirm HEAD is the commit we will demo.
2. **Verification**: run the project's test / verification command. Paste the tail of the output.
3. **Demo dry run**: from a clean start, execute the exact demo sequence in planned order (read `## Demo plan` in NOTES.md; if empty, ask for the order first). Confirm every step works; note any step slower than ~10s.
4. **Evidence inventory** — check NOTES.md contains:
   - at least one quantified result (numbers, before/after comparison);
   - `## Decision log` entries that mention alternatives considered;
   - every extension candidate marked with final status (done / cut);
   - a non-empty `## If I had another day`.
   List anything missing.
5. **Fallbacks**: for each live demo step, name the fallback if it fails on stage (pre-captured output, screenshot, test log). If a step has none, capture one now into `demo-evidence/`.
6. **Q&A prep**: from NOTES.md, draft one-sentence answers to:
   - "Why this design over the alternatives?"
   - "Why these extensions and not others?"

**Output**: a table — check | PASS / FAIL / MISSING | fix needed — followed by the two Q&A draft answers. Nothing else.
