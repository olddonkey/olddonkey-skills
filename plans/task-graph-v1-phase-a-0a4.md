# task-graph-v1 Phase A — sub-unit 0a.4 (the named falsifier, end to end)

**Status: ACCEPTED** at Codex read-only review round 3 (2026-09-29, gpt-6-sol /
max, thread `01a0ec41`; findings 6 → 4 → 1 minor), together with
amendment A2.6 (`plans/task-graph-v1-amendment-a2.md`). The contract is
`plans/task-graph-v1.md` (ACCEPTED round 11) as amended by A1 (ACCEPTED
round 9) and A2 (A2.1, A2.3, A2.4 ACCEPTED). This document decides only what
those leave to implementation.

`tg:NN`, `A1.n`, `A2.n` cite the plan and amendments; `pa`, `p2`, `p3` cite
the accepted 0a.1, 0a.2, and 0a.3 specifications
(`plans/task-graph-v1-phase-a.md`, `-0a2.md`, `-0a3.md`). 0a.4 is the last
sub-unit of 0a and runs over the tree the first three leave.

---

## 1. Scope

The plan names one falsifier for Phase A (`tg:1397-1407`): unit 0a must show
that every authority-store and anchor mutation is **structurally** reachable
only through the admission registry, and that crash injection across a
compound transition never yields one part without the other; if either needs
"a generic sealing or append escape hatch, a directly callable derived
transition, or recovery that invents authority", the design is wrong, not the
implementation.

After A2.1 and A2.6, 0a admits exactly: authority genesis, epoch rotation,
epoch revocation (compound with store quarantine), authority-head advance,
torn-frame truncation, anchor replay-forward (compound with delimiter
completion when the frame was unterminated), recovery tidy, store quarantine,
and linked re-genesis — plus the ceremony-completion and abandonment paths of
A2.3–A2.4. Every other row is dormant. 0a.2 already tests each of these rows
and sinks; its tests are organized by mechanism. **0a.4 adds nothing to the
writer.** It delivers one suite, `falsifier-selftest.sh`, that states the
falsifier's claims as executable checks over the **final 0a tree** (0a.1 +
0a.2 + 0a.3), fills the invariant tests 0a.2 does not name, and fails if any
claim fails.

## 2. The claims and their checks

**F1 — every mutation sink is reachable only through an admitted row.**
- **Writer paths** — every Python module under `lib/loopauth/` and the
  Python embedded in `scripts/loop-authority` (heredoc bodies extracted and
  parsed): the AST scan of p2 §7 is re-run — a sink function of the frozen
  list is called only from the transaction driver of a registry row, every
  subprocess goes through `tools.run`, and no module other than `store.py`
  opens a path under the authority directory for writing.
- **The independent verifier** (`scripts/loop-authority-verify`, which by
  design imports nothing from `lib/loopauth` and runs its own git and
  `ssh-keygen`): its subprocess calls are exactly its frozen argv forms (p2 §7:
  three git forms plus `ssh-keygen -Y verify`/`-l`), it opens nothing under
  the authority directory or the remote for writing, and — run against a
  read-only store and remote — it leaves both byte-identical.
- **Journal paths** (`scripts/loop-journal`, `scripts/loop-index`): they
  import no store module and open nothing under the authority directory.
- The four planted-bypass controls of p2 §7 are re-run, plus two for 0a.4's
  wider scope: a sink call planted in `scripts/loop-authority`'s embedded
  Python, and a sink call planted in `refs.py` (0a.3's read-only module).
  Each makes F1 fail.

**F2 — every external entry point maps to exactly one row.**
- A frozen table, written in the test, maps each external entry point —
  `loop-authority ceremony genesis|rotate|revoke|regenesis` — to its one row;
  `loop-authority recover` to the **recovery routine**, an observation-driven
  dispatcher whose branches are exactly torn-frame truncation, anchor
  replay-forward (with delimiter completion), recovery tidy, store
  quarantine, and A2.4's ceremony completion and abandonment; and
  `loop-authority status|verify|refs` and `loop-authority-verify` to **no**
  row (read-only). The test enumerates the actual argument parser's
  subcommands and ceremony names and requires the enumeration to equal the
  table (an added subcommand fails the check until the table names its row).
- For `recover`: its parser accepts no option that names a row, sequence,
  digest, path, or evidence. One invocation may apply **several** rows in
  order, so the check is an **ordered token trace** per recovery case,
  recorded by a token-recording fixture and compared with a frozen expected
  trace written in the test — for example: A2.3 row 7 (unterminated frame 1,
  ref absent) → `[recovery: delimiter completion + anchor replay-forward,
  ceremony(genesis): completion]`; row 8 → `[recovery: anchor replay-forward,
  ceremony(genesis): completion]`; row 9 → `[ceremony(genesis): completion]`;
  row 6 → `[ceremony(genesis): abandonment]`; a torn tail →
  `[recovery: torn-frame truncation]`, followed by whatever the resulting
  state requires; an A1.2 committed state with a residual intent →
  `[recovery: recovery tidy]`; every **pending** outcome (remote unreachable)
  and every **fail-closed** outcome (A2.3 rows 1–2) → `[]` (no token at all);
  every quarantine outcome → `[recovery: store quarantine]`. Every case of
  the crash matrix has its expected trace; an extra, missing, or reordered
  token fails.
- Each read-only entry point, run against a store in every state 0a.2's tests
  build (current, pending, quarantined, each bootstrap terminal state), leaves
  the authority directory, the journal store, and the remote byte-identical.

**F3 — derived-only rows have no external entry point.**
- The derived rows 0a admits — authority-head advance, torn-frame truncation,
  anchor replay-forward, recovery tidy, store quarantine, and the compound
  children (the quarantine inside revocation, the delimiter completion inside
  replay-forward) — appear in no entry point's row list (F2's table), and no
  argument of `recover` selects a row or supplies evidence (the parser
  accepts no row-, seq-, digest-, or path-naming option).
- Each **compound child** is refused when invoked with no token, with its
  parent's row token outside that parent's transaction, with another
  parent's token, or with a spent parent token (A1.5's compound-derived test,
  which 0a.2 names only for recovery rows).

**F4 — no generic sealing or append hatch.**
- `store.seal`, `store.seal_pointer`, and the frame-append sink are called
  only from the transaction driver, with the record type fixed by the row
  (a frozen map row → type written in the test), never from a function that
  takes a record type as a parameter from a caller outside `store.py` (AST
  check over every call site).
- Every dormant row (A2.1, A2.6), `approval.consume`, and an unknown row name
  are refused through the only entry points; a validly sealed record of each
  type `ALLOWED["tg-v1.0a"]` does not admit, planted with the store's own
  subkey, is refused by the writer's log validation and by the independent
  verifier with `type-not-admitted` (A2.6).
- **Planted generic hatch:** a copy of the tree with a function added that
  takes a record type and payload from its caller and seals and appends an
  **allowed** type (e.g. `epoch.rotated`) without that row's validator must
  make the structural check fail.

**F5 — no recovery invents authority.**
- For every crash point of p2 §6, recovery either completes a transaction
  the operator authorized (the intent's exact bytes, A1.6; A2.3–A2.4's exact
  proven state) or abandons or quarantines — never seals, signs, or pushes
  bytes that were not durable before the crash. The check: across the whole
  crash matrix, every record and pointer present after recovery is
  byte-equal to one the interrupted transaction had made durable (its intent
  or its frame), and `ssh-keygen.sign`/`sign-pointer` is never invoked by
  recovery (a `tools.run` recording fixture).

**F6 — compound transitions never come apart.** The safe outcomes of every
cut are: **both** parts, **neither** part (the prior state intact), or
**pending** — a durable frame the remote has not yet anchored, which A1.2
treats as giving **no current authorization at all** (asserted through
`status`, the verifier, and 0a.3's store state). Never one part accepted as
current without the other.
- The two compounds 0a admits, crashed at every named crash point and at
  every frame byte in the sense of 0a2 §25 (real crashes at every planned torn
  byte and the final byte of genesis frame 1, a rotation frame, and an
  active-epoch revocation frame, in the required crash-matrix job, which F6
  checks enumerates all three kinds; sampled real bytes plus the classifier
  over every prefix elsewhere):
  **epoch revocation + quarantine** — both hold, or neither does and the old
  epoch is still active, or the store is pending; **delimiter completion +
  anchor replay-forward** — the completed frame anchored, or the store
  pending (with the frame unterminated, or completed but not yet pushed),
  never a completed frame with the old anchor accepted as current. The cut
  between recovery's delimiter completion and its push is injected
  deterministically at a new crash point `recovery-after-delimiter`, and a
  failed push there (the remote made unreachable) is tested too. The ceremony compounds of A2.3–A2.4 (genesis completion; re-genesis
  completion with its archive move) likewise: completed in full or
  abandoned, never half.
- The request compounds are A2.1's activating units' (8, 9, 12); this suite
  asserts only that each is refused in 0a.

## 3. Output

The suite prints one line per claim (`F1` … `F6`) with its check count and
`PASS`/`FAIL`, then `falsifier: PASS (<n> checks)` only if all pass. It also
prints `escape-hatch: none` — the suite fails if any F4 check would need an
exception list to pass (the frozen maps allow no exceptions).

## 4. Fields

**C:** `skills/implementation-loop/tests/falsifier-selftest.sh` and its
fixtures (`tests/fixtures/falsifier/`), reusing 0a.2's test helpers where they
exist (scratch `HOME`, `file://` test lineage, PTY driver, crash seam, the
`tools.run` and token recording fixtures). Production changes are limited to
the test seam: the crash point `recovery-after-delimiter` is added to p2 §6's
closed list (honoured only under `LOOP_AUTHORITY_TEST=1`, like every other),
and a recording fixture for minted tokens if 0a.2's tree has none. A check
that finds a real violation is a defect to fix in the module it names
(through its own dispatch), never a test to relax.

**M:** `.github/workflows/selftest.yml` (`bash -n` and a "Falsifier" step),
`AGENTS.md` (the suite and its count), `references/state-schema.md` (a short
"falsifier" section naming F1–F6).

**T:** the suite itself; each planted-bypass control (F1's six, F4's planted
records) must make its claim fail, shown by running the claim's check against
the planted copy inside the suite.

**G:** `bash skills/implementation-loop/tests/falsifier-selftest.sh` plus the
full host replica of `.github/workflows/selftest.yml`.

## 5. After 0a

With 0a.4, Phase A unit 0a is complete for the rows it admits. The next
units' specifications must carry A2.1's and A2.6's forwarded obligations
(request activation, derived-row token source, approval grant, nonce
issuance with its consumer, the `ALLOWED` extension, and the compound
redemption crash tests).

## 6. Round-1 disposition (Codex gpt-6-sol / max, thread `01a0ec41`)

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: unit 4 relies on a unit 7–8 channel | **accepted** (A2.6) — the first unit activating any console-gesture row (unit 2) must deliver the authenticated console-to-writer channel first, or its rows move; nonce issuance at unit 4 needs consumer and channel |
| 2 | BLOCKER: F1 would reject the independent verifier | **accepted** — `tools.run` applies to writer paths; the verifier has its own frozen argv and no-mutation checks; journal scripts import no store module |
| 3 | BLOCKER: F2 omits `recover` | **accepted** — `recover` is inventoried as the recovery routine's dispatcher with its exact branches; no row-selecting option; each branch's exact token recorded |
| 4 | MAJOR: F6 excludes valid pending states | **accepted** — pending is an explicit safe outcome with no current authorization; a deterministic `recovery-after-delimiter` crash point (a seam-only production change) and a failed push there |
| 5 | MAJOR: F4 does not falsify a generic hatch | **accepted** — a planted allowed-type generic seal path must fail F4; compound-child tokens: none, outside, other parent, spent |
| 6 | MAJOR: planted-record test may not prove the boundary | **accepted** (A2.6, 0a.2 §7) — `type-not-admitted` decided before body schema, asserted against bodies that would also fail schema; a mixed-version corpus gated to unit 2 |

## 7. Round-2 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: one token per `recover` call | **accepted** — an ordered, frozen token trace per recovery case, including multi-row (delimiter + replay + ceremony completion) and no-token (pending, fail-closed) cases |
| 2 | MAJOR: the crash point is not in 0a.2's closed list | **accepted** — `recovery-after-delimiter` added to p2 §6's list, after durable delimiter completion and before the push |
| 3 | MAJOR: type sets could shrink | **accepted** (A2.6) — admitted type sets only grow within a generation; unit 2 tests the rejection |
| 4 | MAJOR: lower-version test gated too late | **accepted** (0a.2 §7) — lower-version and shrinking-set tests gated to unit 2; dropped-protocol stays at unit 8 |

