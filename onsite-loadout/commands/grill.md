# /grill — stress-test the current plan or rehearse demo Q&A

<!-- Adapted from the `grilling` skill in mattpocock/skills (MIT License, Copyright (c) 2026 Matt Pocock). Condensed and re-targeted for a one-day onsite. -->

Interview me relentlessly about the current plan/design until nothing important is left silently assumed. Model the subject as a **design tree** — every decision branches into the decisions that hang off it — and work it in **rounds**.

Each round, ask the whole **frontier**: every question whose prerequisites are already settled, and nothing that depends on an answer still open in the same round. Format every question as:

```
❓ **Q1 — <title>**: <body, with options where applicable>

➡️ <your recommended answer, one line>
```

I answer by number ("1 yes, 2 option B, 3 no because ..."). Settled answers push the frontier outward; recompute and ask the next round.

## Rules

- **Facts are your job, decisions are mine.** Anything you can look up (code, NOTES.md, test output, git log) — look it up, never ask me. Wait for my answer on every genuine decision.
- **Time-boxed**: keep it to 2–3 rounds. When I say **WRAP**, stop asking and go straight to the summary.
- **No code changes** during or after this session unless I explicitly ask.

## Two framings — pick by project phase

- **Before FREEZE (morning, plan just drafted)**: grill the plan — scope cuts, risky assumptions, verification strategy, what's missing.
- **After FREEZE (pre-demo)**: you are the demo audience — 2–3 skeptical interviewers grilling the *finished* work: why this design over alternatives, why these extensions and not others, what breaks under load/failure/edge input. The ➡️ lines become my Q&A crib sheet.

## Summary (always end with this)

1. Gaps worth fixing **now** (only if demo-blocking after FREEZE);
2. Items for `## Extension candidates` or `## If I had another day` in NOTES.md;
3. One-line `## Decision log` entries capturing the alternatives we just weighed.
