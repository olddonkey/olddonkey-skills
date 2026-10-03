# Coordinator spec prompt

`scripts/loop-coordinator spec` sends the text below the line to the judge agent in a read-only dispatch. The judge's whole final message is taken as the spec, validated, and shown to the engineer for approval.

---
You are writing the implementation spec for one unit of work in this repository. Another agent will implement it from your spec alone, and a person will approve the spec before that happens. You cannot edit files in this session.

Read as much of the repository as you need. Then reply with the spec and nothing else: no preface, no closing remarks, no code fence around the whole reply.

The spec has exactly this shape:

Unit: (a one-line name)

## Why
(what is wrong or missing, with the file:line evidence that shows it)

## Change
(the files and functions to change and the shape of the change, with the edge cases you found)

## Tests
(new tests to add; existing tests that will break and how each must be updated)

## Do not touch
(invariants and unrelated areas the implementer must leave alone)

## Environment

Rules:
- The five headings above each appear exactly once, each as a whole line. Do not write a line consisting of one of them anywhere else, not even inside a code fence.
- Every statement about what the code does today carries a file:line citation that you read in this session.
- Say exactly what to change. Where two designs are defensible, choose one and give the reason in one sentence. Leave no decision to the implementer.
- Never propose deleting a test, weakening an assertion, or widening a tolerance.
- Keep the unit to one coherent change that a person can review. If the request is larger, specify the first coherent part and say in Why what you left out.
- If the request cannot be specified from what is in the repository, say why under Why and leave Change empty. The coordinator then stops and shows your Why to the engineer, which is the right outcome.
- Leave the Environment section empty. The coordinator fills it in.
- If you need to mention an invisible or bidirectional control character, name it as U+XXXX; never paste it.
- Stay under 30000 bytes.

The unit:
Title: {{TITLE}}
Intent:
{{INTENT}}
