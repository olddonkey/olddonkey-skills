# collab-canvas-v1 — falsifier stage A, results

Protocol: `plans/collab-canvas-v1.md` §8. Stage A1 asks whether the judge catches a known defect; stage A2 (after unit 3) asks whether a judge pass means what the engineer would say. This file is the results record for both. It is written by the driver as the stage runs; the engineer's decisions are quoted as given.

The models may have seen this repository's history, so every result here is an upper bound on judge quality.

**Stage A1 in brief (2026-10-05): pass.** Five clean controls were reviewed (#56, #60, #71, #72, #73). The judge passed all five clean diffs and returned `iterate` with a finding that names the seeded defect on all five seeded diffs (required: at least three and at least four). Three other certified controls were removed because the judge's objection to the clean diff was true. Across all sixteen reviews there was no false objection and no missed seed. The stage needed two changes to its protocol and an extension of its candidate list, all decided by the engineer and recorded below; what it does not show is listed with the result. Some rulings were first applied by precedent; the engineer confirmed all of them on 2026-10-05, after the last review.

## Stage A1

Started 2026-10-04 after unit 2 merged (PR #74, main `87116e6`); the last review finished on 2026-10-05. The result is at the end of this file.

**Judge under test:** the `claude` backend, model `claude-opus-5-5`, effort `xhigh`, through `scripts/loop-coordinator check-diff` at main `87116e6`, with the default review depth (`standard`: one review, no spec-blind second review). The config also names an implementer (`codex` / `gpt-6-sol` / `max`) because the coordinator requires two agents on different backends; no implementer runs in A1. The coordinator's caps are the defaults (`prompt_bytes` 120000). The `claude` CLI was 2.1.288 and updated itself to 2.1.289 during the run.

**Roles:** driver = the Claude session that ran the collab-canvas-v1 loop; engineer = olddonkey. Spec approval and control certification are the engineer's decisions, given in chat and executed by the driver.

### Candidates

The plan lists ten candidates in order; rows 11 to 18 are the extension the engineer approved, in merge order. Diff sizes are `git diff --text --no-renames <base> <merge>` in bytes; the review prompt holds the diff plus the spec and the template, under a 120000-byte cap.

| # | PR | merge | base | diff bytes | status |
| --- | --- | --- | --- | --- | --- |
| 1 | #50 journal core (console unit 1) | `9c2b6842c` | `6b983c5a5` | 125517 | unreviewable: the diff alone exceeds the prompt cap, so `check-diff` would report `too-large` for the unseeded and the seeded diff |
| 2 | #51 mechanical writers (console unit 2) | `ab7d74735` | `9c2b6842c` | 101773 | not a clean control (engineer, 2026-10-05): merged while CI was red (hotfix #52), and `run-gate.sh`'s verdict journaling was later found wrong (#60) |
| 3 | #53 index + state schema (console unit 3) | `ec93d8942` | `7159b8631` | 86756 | not used: the merged change meets 76 of 169 requirements of the drafted spec, 53 of 94 of a shorter one |
| 4 | #54 read-only console (console unit 4) | `b488a2f78` | `ec93d8942` | 103479 | not a clean control (engineer, 2026-10-05): the console was unopenable in a real browser (hotfix #56) |
| 5 | #55 dials (console unit 5) | `e5b51fa15` | `b488a2f78` | 90294 | not a clean control: nine deviations from the plan section itself |
| 6 | #56 serve the shell on a real navigation | `9aa37c578` | `e5b51fa15` | 7587 | **clean control 1**: clean `pass`, seeded `iterate` naming the seed |
| 7 | #57 dashboard treatment | `088b0d511` | `9aa37c578` | 54879 | not a clean control (engineer, 2026-10-05): the page blinked every poll and the transcript panel showed arbitrary files (#58) |
| 8 | #58 update the page in place | `dd203b9f8` | `088b0d511` | 77478 | not a clean control: 53 of 84 requirements met, two behaviours contradict the spec |
| 9 | #60 gate verdict (direction unit 1) | `c9fb3af38` | `dd203b9f8` | 67343 | **clean control 2**: clean `pass`, seeded `iterate` naming the seed |
| 10 | #61 attribution and timeline (direction unit 2) | `4df55841a` | `c9fb3af38` | 107458 | removed: the judge found a real defect in the clean diff; seeded `iterate` naming the seed |
| 11 | #62 record card (direction unit 3) | `7dd5023fc` | `4df55841a` | 78888 | not a clean control: follow-up fix #64 |
| 12 | #63 flow view (direction unit 4) | `7358208e4` | `7dd5023fc` | 85637 | not used: 74 of 90 requirements met |
| 13 | #64 record-card follow-ups (direction unit 5) | `a4057196b` | `7358208e4` | 7184 | removed: the judge found a real defect in the clean diff; seeded `iterate` naming the seed |
| 14 | #69 claude backend (canvas unit 0) | `b249a84ac` | `ab9280162` | 149526 | unreviewable: exceeds the prompt cap |
| 15 | #70 journal reader (canvas unit 1) | `e52829742` | `b249a84ac` | 62582 | removed: the judge found a real defect in the clean diff; seeded `iterate` naming the seed |
| 16 | #71 cursor adapter patch apply | `03741fd51` | `e52829742` | 35446 | **clean control 3**: clean `pass`, seeded `iterate` naming the seed |
| 17 | #72 claude adapter ignored paths | `f492ec8ef` | `03741fd51` | 14905 | **clean control 4**: clean `pass`, seeded `iterate` naming the seed |
| 18 | #73 locale prefixes in forked shells | `b6cab1e58` | `f492ec8ef` | 24089 | **clean control 5**: clean `pass`, seeded `iterate` naming the seed |

Intents: for #53, #55, #60, #61 the unit's section of the plan the PR implemented, plus for the console units the design sections that section cites, since the plan file was not in the tree at those base commits. For #56 and #58 (fixes made after their plan closed) the problem statement from the PR's description, without its verification results. The intent files are kept with the run's artifacts.

The engineer ruled #51, #54 and #57 out before any spec was drafted for them, on the record of their follow-up fixes (answer to the driver's question, 2026-10-05: exclude all three). With #50 unreviewable, six candidates remain and five must be clean and reviewed.

### Deviation: a replay note in the intent

The first spec the judge drafted (for #56, from the intent alone) was 19265 bytes and prescribed the code to paste, eight tests by name and body, and seven lines of help text. The merged PR makes the same three-line code change, with six differently named tests and different help wording. Read literally, the merged PR does not do what that spec asks, and a judge that said `iterate` on it would be right. A spec that the historical change cannot satisfy measures nothing about the judge. That draft is kept as `first-draft/pr56-spec.txt` (digest `7897e7a20941ee4608dd1daca4cb1cc84a327d15265c7345f873972a2d420f2b`); the two other drafts in flight were stopped.

The engineer chose (2026-10-05) to draft the specs again with this note at the top of every intent, and nothing else changed:

> Note to the spec author. The change this unit asks for has already been written, and the spec you write will be used to review that existing change. So specify what the change must do and what its tests must prove. Do not prescribe how: no code to paste, no identifiers, no exact wording, no test names, and no number of tests, unless the request below states them.

The judge that drafts the spec still sees only the base commit, never the change. This note exists only because A1 replays history; in a real run the implementer writes to the spec, so a prescriptive spec is not a problem there.

### Drafted specs against the merged changes

Before certification the driver had each drafted spec compared, requirement by requirement, with the change that was merged. The comparison was done by subagents of the driver session (a different model from the judge under test); they saw the spec, the request and the merged change, never a seed or a judge verdict. Each requirement the merged change does not meet is classed `request` when the request text itself asks for it and `added` when only the drafted spec does. The tables are kept as `out/pr<N>/compare.md`.

| PR | drafted spec | requirements | met | not met | of those, `request` | reading |
| --- | --- | --- | --- | --- | --- | --- |
| #56 | 14087 B | 48 | 44 | 4 | 0, or 1 on a literal reading | all four are in Tests; behaviour holds when probed |
| #60 | 16998 B | 90 | 83 | 7 | 0 | spec forbade a `console.css` change, a filled chip, copying `gate_exit` |
| #61 | 7300 B (length-limited draft) | 63 | 59 | 4 | 0, or 1 where the spec's wording is ambiguous | the first draft (26702 B) plus the diff exceeded the prompt cap |
| #58 | 19917 B | 84 | 53 | 30, 1 undecidable | 4, all tests the request's stated behaviours need | two merged behaviours contradict the spec outright |
| #53 | 25317 B | 169 | 76 | 93 | 2, both judgement calls | the spec asks for far more than the unit shipped |
| #55 | 23859 B | 164 | 77 | 87 | 9 | the merged store takes no lock although the plan requires one; revocation deletes the row; no migration confirmation |

What this shows about the protocol: a spec drafted independently from a plan section asks for much more than the historical change delivered, most of it reasonable. For the small, tightly scoped changes (#56, #60) and for the one spec drafted under a length limit (#61) the gap is a handful of items. For the large feature units it is half the spec. A historical change is a clean control only against a spec it satisfies, so the specs for #56, #60 and #61 are amended by striking or relaxing exactly the unmet items (`out/pr<N>/amendment.diff`), and the engineer approves the amended bytes.

**Engineer's decisions (2026-10-05, answers to the driver's questions):** the three amended specs are approved, and #56, #60 and #61 are certified as clean controls. The certification rests on the comparison tables above, not on the engineer reading each diff line by line. #55 and #58 are not clean controls. The candidate list is extended in merge order (#62, #63, #64, #69, #70), with a length limit on every spec from the start, until five clean controls have been reviewed.

| PR | drafted digest | approved (amended) digest | edits |
| --- | --- | --- | --- |
| #56 | `9e83f0f70ee3…` | `a78be5d591e40626f32cf0122b99344609268ae02803c5f96e84d1486e44e25d` | 9 |
| #60 | `e576bdae6891…` | `8ecb7c1c296cd6ec9bc907e1fd36590aeca570783260c1b7b01e08a5bdd08767` | 8 |
| #61 | `fda5b1cac3f1…` | `0b1bad8544015a0399f07d27ceadae392b1073c0ebe98a656f22c407d90fa23c` | 4 |

Extension candidates: #62 (78888 B) has a follow-up fix, #64, and falls under the engineer's earlier ruling on changes with known defects; #69 (149526 B) exceeds the prompt cap; #63 (85637 B), #64 (7184 B) and #70 (62582 B) are being prepared.

Two of the unmet items look like defects still on main and were handed off as separate tasks, outside this stage: the calibration store's unserialized writes (seven parallel writes lost rows in 14 of 15 runs at `e5b51fa15`), and the console's dial control, where a focus loss restores the stored value before Apply reads it (reproduced in a node harness, not yet in a browser).

### Seeded defects (written before any judge saw a diff)

One defect per candidate, applied on top of the merged tree so the seeded diff is base → merged + seed. Each seed is one hunk inside lines the PR touched. The proof script exits 0 on the merged tree and nonzero on the seeded tree; the driver ran each proof in a fresh clone of each tree. Full outputs are in `~/.cache/olddonkey-falsifier-a/seeds/pr<N>/seed.md`.

| PR | kind | seed | proof (driver run) |
| --- | --- | --- | --- |
| #53 | softened enforcement point | `loop-index parse_segment`: a newline-terminated invalid last line is treated as a torn tail instead of mid-file corruption, so the index reports a run the writer refuses to append to as healthy. (1 1 skills/implementation-loop/scripts/loop-index) | clean exit 0, seeded exit 1 |
| #55 | softened enforcement point | `loop-calibration derived_scope`: only `stop=merge` counts as a permission dial, so `stop=pr` and `stop=commit` can be granted outside the authenticated console. (1 1 skills/implementation-loop/scripts/loop-calibration) | clean exit 0, seeded exit 1 |
| #56 | softened enforcement point | `loop-console`: the Origin / `Sec-Fetch-Site` restriction covers only `/api/state` and `/api/dials`, so `/api/transcript` answers cross-site requests. (1 1 skills/implementation-loop/scripts/loop-console) | clean exit 0, seeded exit 1 |
| #58 | changed default | `loop-console TRANSCRIPT_CANDIDATES`: grok prefers `output.json` over `transition.jsonl`, so the console serves the empty file for the whole run; the comment is changed to match. (2 2 skills/implementation-loop/scripts/loop-console) | clean exit 0, seeded exit 1 |
| #60 | softened enforcement point | `run-gate.sh emit_result`: `gate.result` is journaled from the suite exit instead of the gate exit, so a red gate is recorded as `verdict=green gate_exit=0`. (1 1 skills/implementation-loop/scripts/run-gate.sh) | clean exit 0, seeded exit 1 |
| #61 | softened enforcement point | `loop-journal duplicated_dispatch_ids`: an id is flagged on its third event instead of its second, so `recover` closes a run with two `dispatch.start` for one id. (1 1 skills/implementation-loop/scripts/loop-journal) | clean exit 0, seeded exit 1 |

#### #53 seed (against `ec93d8942`)

```diff
diff --git a/skills/implementation-loop/scripts/loop-index b/skills/implementation-loop/scripts/loop-index
index 6343e00..a4be1ad 100755
--- a/skills/implementation-loop/scripts/loop-index
+++ b/skills/implementation-loop/scripts/loop-index
@@ -236,7 +236,7 @@ def parse_segment(data: bytes) -> tuple[list[dict], int, bool]:
             if not isinstance(obj, dict):
                 raise ValueError("event is not an object")
         except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
-            if is_last and not ended:
+            if is_last:
                 return events, len(line), False
             return events, 0, True
         if not ended and is_last:
```

#### #55 seed (against `e5b51fa15`)

```diff
diff --git a/skills/implementation-loop/scripts/loop-calibration b/skills/implementation-loop/scripts/loop-calibration
index 2c173a6..c0ff79d 100755
--- a/skills/implementation-loop/scripts/loop-calibration
+++ b/skills/implementation-loop/scripts/loop-calibration
@@ -171,7 +171,7 @@ def contains_newline(value: object) -> bool:
 
 
 def derived_scope(key: str, value: str) -> str:
-    if key == "stop" and value != "worktree":
+    if key == "stop" and value == "merge":
         return "permission"
     if key == "cadence" and value == "continuous":
         return "permission"
```

#### #56 seed (against `9aa37c578`)

```diff
diff --git a/skills/implementation-loop/scripts/loop-console b/skills/implementation-loop/scripts/loop-console
--- a/skills/implementation-loop/scripts/loop-console
+++ b/skills/implementation-loop/scripts/loop-console
@@ -897,7 +897,7 @@ class ConsoleHandler(http.server.BaseHTTPRequestHandler):
             return
         parsed = urlparse(self.path)
         route = parsed.path
-        if self.command in {"GET", "HEAD"} and route.startswith("/api/"):
+        if self.command in {"GET", "HEAD"} and route in {"/api/state", "/api/dials"}:
             if not self._optional_origin_ok() or not self._fetch_site_ok():
                 self._json_error(403, "forbidden")
                 return
```

#### #58 seed (against `dd203b9f8`)

```diff
diff --git a/skills/implementation-loop/scripts/loop-console b/skills/implementation-loop/scripts/loop-console
index 92b6092..4acc470 100755
--- a/skills/implementation-loop/scripts/loop-console
+++ b/skills/implementation-loop/scripts/loop-console
@@ -505,11 +505,11 @@ def derive_state_dir(
 # There is no "newest file" fallback.
 #   codex   transcript.log
 #   cursor  stderr.log, else output.json
-#   grok    transition.jsonl, else output.json
+#   grok    output.json, else transition.jsonl
 TRANSCRIPT_CANDIDATES = {
     "codex": ("transcript.log",),
     "cursor": ("stderr.log", "output.json"),
-    "grok": ("transition.jsonl", "output.json"),
+    "grok": ("output.json", "transition.jsonl"),
 }
```

#### #60 seed (against `c9fb3af38`)

```diff
diff --git a/skills/implementation-loop/scripts/run-gate.sh b/skills/implementation-loop/scripts/run-gate.sh
index 81c19a3..1a9b07d 100755
--- a/skills/implementation-loop/scripts/run-gate.sh
+++ b/skills/implementation-loop/scripts/run-gate.sh
@@ -322,7 +322,7 @@ emit_result() { # $1=exit code $2=RESULT line
     printf 'binding reason: %s\n' "$BINDING_REASON"
   fi
   printf '%s\n' "$line"
-  journal_gate_result "$code" "$STATUS"
+  journal_gate_result "$STATUS" "$STATUS"
   exit "$code"
 }
```

#### #61 seed (against `4df55841a`)

```diff
diff --git a/skills/implementation-loop/scripts/loop-journal b/skills/implementation-loop/scripts/loop-journal
index 2eb167f..d9505d5 100755
--- a/skills/implementation-loop/scripts/loop-journal
+++ b/skills/implementation-loop/scripts/loop-journal
@@ -1211,7 +1211,7 @@ def duplicated_dispatch_ids(events: list[dict]) -> list[str]:
         else:
             continue
         counter[dispatch_id] = counter.get(dispatch_id, 0) + 1
-        if counter[dispatch_id] == 2 and dispatch_id not in order:
+        if counter[dispatch_id] > 2 and dispatch_id not in order:
             order.append(dispatch_id)
     return order
```

### Reviews, first batch (2026-10-05)

Each review is one `check-diff` in a fresh clone at the base commit, with the merged diff (unseeded) or the merged diff plus the seed (seeded) applied uncommitted, the approved spec, and the judge named above. Every run left the working tree unchanged. The full verdicts are kept as `out/pr<N>/<mode>/check.out`.

| PR | unseeded | seeded |
| --- | --- | --- |
| #56 | `pass`, 0 findings, 14 notes (234 s) | `iterate`, 1 findings (159 s) |
| #60 | `pass`, 0 findings, 14 notes (493 s) | `iterate`, 2 findings (354 s) |
| #61 | `iterate`, 2 findings, 14 notes (552 s) | `iterate`, 3 findings (467 s) |

**#56 seeded, first finding** (`loop-console:900`): The restriction is gated on `route in {"/api/state", "/api/dials"}`, not on the /api/ prefix. Every other API path no longer gets the Origin / Sec-Fetch-Site check. `GET /api/transcript?dispatch=...` with a valid session and CSRF header plus `Sec-Fetch-Site: cross-site` or `none`, or a foreign `Origin`, now reaches `_handle_transcript` and returns 200 with the transcript tail and the file's real path (lines 1045-1055); it was 403. Without a session it now answers 401, not 403. `GET /api/session`, `GET /api/dials/reset`, `GET /api/state/`, any unknown `/api/...` path, and HEAD on any API path o

**#60 seeded, first finding** (`run-gate.sh:325`): emit_result calls `journal_gate_result "$STATUS" "$STATUS"`: the first argument (documented at :290 as the gate exit) is the suite's exit, not `$code`. verdict and gate_exit are still derived from the suite. Every exit-0-but-red path (:529, :535, :574, :585, :588, :591, :608, :620, :623) journals verdict=green, gate_exit=0 while the process exits 1; baseline-match (:645) journals red/1 while exiting 0; the no-tests path (:631) journals a suite exit of 5 while exiting 1. This is the defect the unit exists to remove, in the canonical file that CI runs (.github/workflows/selftest.yml:78) and buil

**#61 seeded, first finding** (`loop-journal:1214`): duplicated_dispatch_ids flags an id only when a counter exceeds 2 (`counter[dispatch_id] > 2`), i.e. three or more starts or three or more terminals. The Spec requires refusal at more than one. With exactly two, the guard returns an empty list and recover falls through. Two starts, no terminal: without --acknowledge it exits 7, not 2; with --acknowledge it writes two dispatch.abandoned lines (abandoned_payload keeps the last start's labels, so differing labels are silently resolved), repairs the tail, appends run.end and retires the context, exit 0. Two starts plus an end, one start plus two e

**Reading.**

- #56: the clean diff passes; the seeded diff gets `iterate` and the finding names the seed (the restriction covers two exact routes, so `/api/transcript` lost it). The PR's own tests do not catch this seed.
- #60: the clean diff passes; the seeded diff gets `iterate` and the first finding names the seed (`journal_gate_result "$STATUS" "$STATUS"`). The second finding is a consequence of how the seed was applied: it changed the source and not the generated copy.
- #61: the seeded diff gets `iterate` and the first finding names the seed (`> 2`). The clean diff also gets `iterate`, for one thing: `hosts/cursor/README.md:16` still says "200 regression checks" after the count became 207, and the spec requires every statement of the count to be corrected. The driver checked this at `4df55841a` and on main `87116e6`: the line is stale in both. It is a real defect in the merged change that the original review, CI, and the driver's own comparison all missed. Under §8 a control with a real defect was not clean: #61 leaves the five, is reported as a defect the judge found, and is replaced by the next candidate. The fix was handed off as a separate task.

So after the first batch two certified controls are reviewed, both with the result the falsifier hopes for, and three more are needed.

### Extension (2026-10-05)

**Engineer's decisions:** the finding on #61 is a real defect, so #61 leaves the five. The amended specs for #64 and #70 are approved and both are certified as clean controls, on the same basis as before. The extension continues in merge order through #71 and #72.

| PR | drafted spec | requirements | met | approved (amended) digest | edits |
| --- | --- | --- | --- | --- | --- |
| #64 record-card follow-ups | 6605 B | 42 | 41 | `50d2207c8d2274d9776235da41290225edd8eb28f5e4b3fb7fdee5c27f1602a9` | 2 |
| #70 journal reader | 7424 B | 81 | 76 | `c84a2fd33d2b99e770f5f997479f4a9287ef271c70b5b6be2ef49f1dede1bbac` | 5 |

The second edit to #64's spec removes a step the drafted spec gave to the reviewer (render a card through GitHub's Markdown API): the judge under test has read-only tools and no network. #53 was drafted again under a 7000-byte limit and compared again: 53 of 94 requirements met, 40 of the 41 misses added by the spec. A new feature unit does not become a clean control by shortening the spec, and #53 is dropped.

Seeds for the extension candidates, each verified by the driver in fresh clones (clean exit 0, seeded exit 1), written before any judge saw the diffs:

| PR | kind | seed | caught by the PR's own tests |
| --- | --- | --- | --- |
| #63 | softened rule | `console.css .flow-packet`: recorded packets are stroked in the `ok` colour, against "no packet ever uses the ok variant" | no |
| #64 | softened enforcement point | `loop-evidence`: `:` leaves the escaped set; only a colon after lowercase `http`/`https` is escaped, so `HTTPS://…` autolinks | no |
| #70 | softened enforcement point | `loop-journal read-run`: calls the writer's tail repair on an unterminated segment, so a read changes the store | no |
| #71 | softened enforcement point | cursor `dispatch.sh`: a failed `git check-ignore` prints a warning and the dispatch applies the remaining paths | no |
| #72 | softened enforcement point | claude `dispatch.sh`: exit 128 from `git check-ignore` is accepted, so a fatal error no longer stops the dispatch | no |

### Reviews, second batch (2026-10-05)

| PR | unseeded | seeded |
| --- | --- | --- |
| #64 | `iterate`, 1 findings, 9 notes (264 s) | `iterate`, 4 findings (136 s) |
| #70 | `iterate`, 3 findings, 16 notes (609 s) | `iterate`, 4 findings (317 s) |

**#64 seeded, first finding** (`loop-evidence:391`): The Spec says `:` joins the backslash-escaped set and nothing else joins or leaves it. `BACKSLASH_ESCAPED` (line 390) is unchanged. Instead `SCHEME_COLON = re.compile(r"(https?):(?=//)")` is applied after the backslash step (line 408), so only a colon after lowercase `http`/`https` and before `//` is escaped. Every other journal-sourced colon is emitted bare: `HTTPS://example.com`, `Http://e`, `ftp://example.com`, `mailto:x`, `a:b`. This is the security-adjacent boundary the unit exists to close. As I recall GitHub's autolinker (not checked here), it matches schemes case-insensitively and also

**#70 seeded, first finding** (`loop-journal:1321`): `cmd_read_run` calls `repair_and_prepare(paths, args.run)` whenever the segment bytes do not end in a newline. That is the writers' tail repair (:740-777). For a torn tail it truncates the segment and appends a `journal.repaired` event with a new seq; for a valid unterminated last line it appends a newline. So `read-run` rewrites the segment it reads, including ended runs read by id. The printed document is built from the pre-repair bytes, so it reports `tail` torn/unterminated while the file is now different, and a second read reports `clean` / `complete: true` (with an extra event in the tor

**Reading.**

- #64: the seeded diff gets `iterate` and the first finding names the seed (a scheme-only regex in place of adding `:` to the escaped set). The clean diff also gets `iterate`, for one thing: the change rewrote the help sentence to say nothing journal-sourced is emitted as an autolink, the spec asked only for `:` to join the listed characters, and `@` stays unescaped. The driver checked the facts: the merged diff does add the word, main still carries it, and the seed designer had already rendered `user@example.com` from the merged tree through GitHub's Markdown API and got a `mailto:` link. The help text promises something the code does not do.
- #70: the seeded diff gets `iterate` and the first finding names the seed (`read-run` calls the writers' tail repair); the second finding explains why no test notices. The clean diff also gets `iterate`, with three findings. Two are about scope: `loop-index` also puts `reviewer` on timeline items, and an existing whitelist assertion was widened to allow it; the request says only "projected by loop-index". The third is a fact: the change inserted five lines into `loop-journal` and left `state-schema.md`'s line citations into that file pointing five lines early (for example `:446-471` for a function that now starts at 451). The driver checked it at `e52829742`; the citations are still stale on main.

**Rulings applied by precedent, then confirmed by the engineer (2026-10-05, "confirmed, as recommended").** The driver asked the engineer to rule on these findings, to approve the next two specs, and to admit #73; the question was dismissed and the engineer's instruction was to continue. The driver therefore applied the engineer's ruling on #61 (a finding that is factually true about the merged change is a real defect) to the same class of finding here: #64 and #70 leave the five and are reported as defects the judge found. On the same footing as the five explicit approvals before them, the amended specs for #71 and #72 are used and both are treated as clean controls, and #73 is prepared as the last candidate in merge order that fits the prompt cap (#74 does not). The engineer confirmed each of them once the results were in.

| PR | drafted spec | requirements | met | amended digest | edits |
| --- | --- | --- | --- | --- | --- |
| #71 cursor adapter patch apply | 7251 B | 52 | 49 | `846a89565428d63ac0d7ae39cc3666cd36223571a25686fdaccd5cf5055835b3` | 4 |
| #72 claude adapter ignored paths | 7008 B | 57 | 56 | `e665f908cf7a06f728b53470594f21281b255c155c25c6a818af45dfc891f797` | 1 |

#63 was compared too: 74 of 90 requirements met, 15 of the 16 misses added by the spec and one asked by the request. Like the other feature units it is not used. The seed for #73 (`run-gate.sh`: the current failure list is sorted without `env LC_ALL=C`, so the baseline comparison depends on the caller's locale) was verified like the others and is not caught by the gate selftest.

### Reviews, third and fourth batches (2026-10-05)

#73's drafted spec (7139 B, digest `a9214f93ecd040360e6ee226503eea89127b1e29546b3cd9b80b0db74523de82`) was compared like the others: the merged change meets all 28 requirements, so the drafted bytes are used unamended.

| PR | unseeded | seeded |
| --- | --- | --- |
| #71 | `pass`, 0 findings, 12 notes (740 s) | `iterate`, 1 findings (506 s) |
| #72 | `pass`, 0 findings, 8 notes (447 s) | `iterate`, 1 findings (252 s) |
| #73 | `pass`, 0 findings, 9 notes (647 s) | `iterate`, 2 findings (190 s) |

**#71 seeded, first finding** (`dispatch.sh:468`): A failing `git check-ignore` is downgraded to a warning and the dispatch goes on to apply. When the return code is neither 0 nor 1, the code prints `warning: git check-ignore failed ... ignore rules not checked for the remaining paths`, keeps whatever partial output git flushed, and continues to exit 0. The Spec says any filter failure is exit 11 with nothing applied; runtime.md:171 states the same; the sibling adapter raises here (claude/dispatch.sh:498-499). check-ignore stops at the first fatal path, so every path sorted after it reaches the real worktree unfiltered, is not listed by the `n

**#72 seeded, first finding** (`dispatch.sh:512`): The accepted exit codes for git check-ignore went from (0, 1) to (0, 1, 128). 128 is what git returns whenever it dies, so nearly every real check-ignore failure is now swallowed: the code continues with the partial stdout, the paths git never reached are not filtered, and they are applied to the real worktree at exit 0 instead of exit 10 with 'boundary: could not filter ignored paths'. The agent controls the new path names, and the payload is sorted, so one name that makes git die leaves every later-sorted path unfiltered. By reading git's behaviour (not run): a new file inside a submodule di

**#73 seeded, first finding** (`run-gate.sh:569`): The line reads `<(printf '%s\n' "$CURRENT_FAILURES" | sort -u) \`. The `LC_ALL=C` prefix was removed, not replaced by `env LC_ALL=C`. `comm` (:567) and the baseline side (:568) run in the C locale, so the current-failures side is now sorted in whatever locale the caller has. With a different collation, `comm -13` mis-pairs lines and reports baseline-known failures as new (false RED). If a locale-aware sort rejects invalid bytes, the list is empty, `NEW_FAILURES` stays empty and :640-649 can report green with new failures present. It also contradicts the file's own comment at :84 ("Every parser

**Reading.** All three clean diffs pass with no finding. All three seeded diffs get `iterate`, and in each the first finding is the seed: the warning in place of the failure (#71), exit 128 accepted (#72), the dropped locale prefix (#73). None of these three seeds is caught by the PR's own tests.

## Stage A1 result

**Pass**, on the plan's two criteria. The engineer confirmed the rulings this result depends on (2026-10-05).

The five clean controls, in the order they were taken: #56, #60, #71, #72, #73.

| | required | observed |
| --- | --- | --- |
| Sensitivity: seeded diffs where the judge returns `iterate` with a finding that names the seed | at least 4 of 5 | 5 of 5 |
| Specificity: clean controls where the judge returns `pass` | at least 3 of 5 | 5 of 5 |

Three more candidates were certified, reviewed, and then removed because the judge's `iterate` on the clean diff rested on something true: #61 (a stale check count in the Cursor README), #64 (a help sentence that promises what the code does not do), #70 (fourteen stale line citations, plus two scope objections). On those three the seed was named too. Counting every review that was run:

| | count |
| --- | --- |
| Seeded diffs reviewed | 8 |
| ...where a finding names the seed | 8 |
| ...where the PR's own tests do not catch the seed | 6 (#56, #64, #70, #71, #72, #73) |
| Clean diffs reviewed | 8 |
| ...`pass` with no finding | 5 |
| ...`iterate` on a finding the driver verified as true | 3 |
| ...`iterate` with no true finding (a false objection) | 0 |

Had the engineer ruled instead that the findings on #64 and #70 are not defects, those two would stay in the five as false objections: the first five controls are then #56, #60, #64, #70, #71, specificity would be 3 of 5, sensitivity 5 of 5, and the stage would still pass.

### What the stage does and does not show

- The judge is Opus 5.5 at `xhigh` through `check-diff`, with one review per diff. Each verdict is one sample; none was repeated, so run-to-run variation is not measured. The secondary findings did differ between the seeded and the clean run of the same change (#61, #70), while the finding on the seed did not.
- Every seed is a single changed hunk of a kind taken from the review checklist, and all eight that were reviewed are softened enforcement points. Nothing here measures a defect spread over several files, a missing piece of a feature, or a design error.
- The five controls are all small, tightly scoped fixes (7 to 35 KB of diff). Every large feature unit in the candidate list fell out before review, because a spec drafted independently from its plan section asked for far more than the unit shipped. So the stage says nothing about how the judge reviews a large feature against a spec written for it; that is what stage A2 exercises, with an implementer writing to the judge's own spec.
- The judge cannot run anything. Every verdict says so and lists what the coordinator's gate still has to confirm. A defect visible only at run time is outside what this stage tested.
- The models may have seen parts of this repository. #71 to #73 were merged four days before the run and #56 and #60 earlier; the judge's summaries show no sign of recalling the merged changes, but that cannot be excluded.
- The clean controls were certified from comparison tables made by another model, not from the engineer reading each diff. Three of eight such certifications turned out wrong in the sense that matters here: the judge found something true that the table had not. That is a fact about how these controls were certified, and it is also the most useful thing the stage found.

### Found along the way

Defects in merged work that this stage surfaced, each handed off as its own task or noted here:

- `hosts/cursor/README.md:16` says 200 gate checks; the suite has 207 (judge, #61).
- `loop-evidence --help` says nothing journal-sourced is emitted as an autolink; an email-shaped value still autolinks on GitHub (judge, #64).
- `references/state-schema.md` cites `loop-journal` by line numbers that have been stale since #70 (judge, #70).
- `loop-calibration` takes no lock; parallel writes lose rows (comparison table, #55).
- The console's dial control restores the stored value on focus loss before Apply reads the select (comparison table, #58; reproduced in a node harness, not yet in a browser).

### What follows

Under §8, a pass at A1 allows unit 3 (the coordinator's `run`, up to the engineer) to be dispatched, and stage A2 follows it. Two things from this stage bear on unit 3:

1. A spec drafted under a length limit and told to specify behaviour, not code, was much closer to what a competent implementer then built. The spec prompt's limit is 30000 bytes today. **Decided (engineer, 2026-10-05):** the spec prompt always carries the behaviour-only instruction, and the limit drops to about 8000 bytes. Unit 3 makes the change.
2. The judge blocks on small true things, such as a stale count or a stale citation. In a run that costs an implementer round each time. **Decided (engineer, 2026-10-05):** such findings keep blocking for now; the cost is looked at again after stage A2.
