# task-graph-v1 Phase A — sub-unit 0a.2 (the authority store and its ceremonies)

**Status: ACCEPTED** at Codex read-only review round 15 (2026-09-29, gpt-6-sol / max, thread `01a0ebb0`), together with amendment A2.3–A2.4; the two round-15 minors are applied (§23). Its post-acceptance delta under
A2.1 (§24) was accepted at round 5 of thread `01a0ec41`. The contract is amendment A1
(`plans/task-graph-v1-amendment-a1.md`, ACCEPTED round 9) on top of
`plans/task-graph-v1.md` (ACCEPTED round 11). This document **implements** A1;
it decides only what A1 leaves to implementation (file layout, encodings,
module boundaries, the test seam, and the order of sub-units). Anything here
that contradicts A1 is a defect in this document.

`tg:NN` cites task-graph-v1, `A1.n` cites the amendment. Code citations are
lines at `d28e796` under `skills/implementation-loop/`. 0a.2 builds on 0a.1
(`lib/loopauth/canonical.py`, `vocabulary.py`, `reduce.py`).

---

## 1. Scope and the split of the writer

| sub-unit | delivers | rows made **admissible** |
| --- | --- | --- |
| **0a.2** (this document) | the authority store, framing and write intent, per-type subkeys and seals, the anchor, recovery, the operator-TTY ceremony, the **complete** registry (every row, most dormant), transaction tokens on every sink, the reachability invariants, the independent verifier | authority genesis, epoch rotation, epoch revocation (with its compound quarantine), authority-head advance, torn-frame truncation, anchor replay-forward, recovery tidy, store quarantine, linked re-genesis |
| 0a.3 | verification of 0a.1's claimed authority references (the request rows stay dormant through 0a — A2.1, which replaced this row's original allocation) | none |
| 0a.4 | gesture-nonce issuance (console session), the falsifier end to end (`approval.consume` is already refused from 0a.2, below) | nonce issuance |

**Admissibility in 0a.2, row by row.** Admissible: authority genesis, epoch
rotation, epoch revocation (with its compound quarantine), authority-head
advance, torn-frame truncation, anchor replay-forward, recovery tidy, store
quarantine, linked re-genesis. **Dormant from the first store write:** request
opening + capability issuance, request cancellation, request expiry,
capability redemption (through 0a, A2.1); gesture-nonce issuance (until 0a.4);
repository registration, rebind, execution-root registration (unit 2);
standing authorization, standing revocation (unit 3); segment discharge
(unit 8, A2.1); enrollment, enrollment revocation (unit 4); mechanism closure,
acceptance-platform designation, release acceptance (unit 12). Every dormant
row is refused with its distinct error and zero store or anchor mutation, and
0a.2 tests each. `approval.consume` is refused by the writer from 0a.2 on (no
row produces it, A1.9); 0a.2 tests the refusal.

## 2. Layout

`$HOME/.config/olddonkey-loop/authority/` (mode 0700), every file 0600, owner
the current uid, `nlink == 1`, every open — directories included — with
`O_NOFOLLOW`:

```
authority/
  lock                         the writer's exclusive flock (distinct from
                               the journal's meta.lock and console.lock)
  active                       {store_id, generation} of the active store
  regenesis.intent             present only during linked re-genesis (A1.3)
  genesis.intent               present only during authority genesis (§2)
  stores/<store_id>/
    log/segment-000001.olf     framed records (A1.6); one segment in 0a
    keys/epoch-<n>-<16 hex>/root, root.pub
    keys/epoch-<n>-<16 hex>/<type>, <type>.pub, <type>-cert.pub
    intent                     the durable write intent (A1.6)
    cursor                     recovery hint only (A1.2)
    quarantine                 marker with the offending position and rule
  archive/<store_id>/          quarantined stores **moved** here, read-only
```

**Key directories are staged, then published by a record.** A key directory's
name carries a random suffix, and the genesis or rotation record that
introduces an epoch names it (`key_dir`). The writer loads keys **only** from
the directory the latest epoch record names; any other key directory is
**unpublished** — never read, never trusted, reported by `status` — so a
crash while keys are being created leaves inert files, and the next ceremony
creates a fresh directory rather than resuming or reusing staged keys.

**Genesis follows A2.3 and A2.4** (amendment A2, under review with this
document): `genesis.intent` is written once, complete, with A1.6's intent
fields for frame 1 plus `store_id`, `key_dir`, the remote, and the exact frame
bytes, is fully validated before any recovery row is chosen, and is the
**only** intent for frame 1 (the store's own `intent` file is used from
frame 2 on); the store stays unpublished until step 6 writes `active`;
bootstrap recovery follows A2.3's eleven ordered rows, classifying the intent,
`active`, and frame 1 (none / torn / unterminated / valid / nonconforming)
**before** reading the remote: an unparsable intent or a wrong `active` fails
closed (an invalid intent, or an `active` that is present but not exactly
the intent's store); a nonconforming frame is quarantine; only then is an unreachable
remote pending; abandonment only for a none-or-torn frame 1 with the ref and
`active` absent; delimiter completion and replay-forward of the intent's exact
commit for an unterminated or valid frame with the ref absent; completion on
the exact intended commit over a valid frame; quarantine for an absent ref
after `active`, for the exact commit over a frame that is not valid, and for
any other remote state. Every bootstrap failure (`genesis-invalid`,
`anchor-mismatch`, `genesis-quarantined`) is **terminal** for the authority
directory: no row resets it, and `status` reports it with its evidence. Genesis refuses when `active`, either intent, or the remote ref
exists.

**Scratch git repositories — outside the store, fresh per use.** Each writer
transaction, and each verifier run, creates a **fresh** bare repository
`$HOME/.cache/olddonkey-loop/anchor-scratch/<pid>-<16 hex>.git`: the directory
must not already exist (exclusive `mkdir`, `O_NOFOLLOW` on every component),
it is initialized with `git init --bare --template= --object-format=sha1`,
and its `config` is then parsed and refused unless it holds only a `[core]`
section — so no `url.*.insteadOf`, `url.*.pushInsteadOf`, `credential.*`,
`remote.*`, or `include*` setting can be present. It is removed when the
transaction ends. It is **not authority state**: everything in it is derived
from `anchor_json` and the parent fetched from the remote, and nothing in it
is read as evidence; its object and ref writes are not sinks; the push is
(A1.5). **Every** git command runs with `-C <that repository>` — `ls-remote`
included — so no repository is ever discovered from the working directory.

`store_id` is 16 random bytes, hex. The remote URL, the anchor ref
(`refs/olddonkey-loop/anchor`), and the deterministic commit identity live in
the genesis record, never in a config file.

## 3. Records, types, and seals

- **Record payload** (canonical JSON, `canonical.py`): `{type, v: 1, store_id,
  generation, seq, epoch, key_id, prev, body}`, where `prev` is the previous
  record's digest (`null` at `seq` 1) and `body` is the type's schema. The
  frame (A1.6) wraps the payload plus `sig`. **`key_id`** is the SHA256
  fingerprint of the signing subkey's public key (as printed by `ssh-keygen
  -l -E sha256`); a verifier refuses a record whose `key_id` differs from the
  certificate that verified its signature.
- **Compound transactions are one frame.** `request.opened`'s body nests the
  issued capability (`{capability_hash, binding}`) — opening and issuance are
  one record (A1.9); `request.redeemed`'s body nests the answer and, for the
  three compound kinds, the consequence (a `segment_reset` for
  `segment-discharge`, a `mechanism_closed` for `mechanism-closure`, a
  `release_accepted` for `release-acceptance`, `tg:847-849`). Every other
  kind, `approval` included, has only `T-request-answered` (`tg:846`): an
  approval's answer **is** its grant — it carries the approved envelope's
  digest (`tg:529-532`) — and has no separate part. No compound part has a type or frame of its own, so none can
  come apart from its parent; the activating units of A2.1 (8, 9, 12) carry
  the compound-redemption crash tests.
- **The activation boundary (A2.1, a post-acceptance addition reviewed with
  0a.3).** Every epoch introducer — `store.genesis`, `epoch.rotated`, and
  `store.regenesis` — carries `registry_version` and `admitted_protocols`,
  both part of the canonical envelope its ceremony displays. The writer and
  the independent verifier each implement A2.1's checks on every introducer:
  `registry_version` must be known to them and not lower than the predecessor
  epoch's; `admitted_protocols` must be a subset of
  `ALLOWED[registry_version]` and, within a generation, include every
  protocol the predecessor listed. 0a knows one version, `"tg-v1.0a"`, with
  `ALLOWED["tg-v1.0a"] = []`, so every 0a introducer carries that version and
  the empty list. Both also refuse a record of a request type
  (`request.opened`, `.cancelled`, `.expired`, `.redeemed`) unless its
  epoch's introducer admits its `protocol` and kind — so in 0a, always; a
  store holding such a record is invalid (quarantine, A1.6).
- **The closed type list for Phase A**, fixed in `lib/loopauth/records.py`, so
  genesis and rotation can certify one subkey per type up front:
  `store.genesis`, `epoch.rotated`, `epoch.revoked`, `store.regenesis`,
  `request.opened`, `request.cancelled`, `request.expired`,
  `request.redeemed`, `nonce.issued`, plus one type per dormant row
  (`repo.registered`, `repo.rebound`, `exec-root.registered`,
  `standing.granted`, `standing.revoked`, `entry.enrolled`, `entry.revoked`,
  `platform.designated`). There is **no** standalone type for segment reset,
  mechanism closure, or release acceptance: they exist only as nested parts of
  a `request.redeemed` frame (below), so no key can seal them directly. The anchor pointer is not a record type; it is sealed
  by the epoch **root** (A1.2).
- **Keys** (A1.7): Ed25519 via `ssh-keygen -t ed25519`. The root certifies
  each type's subkey with `ssh-keygen -s root -I <type>@e<epoch> -n <type>
  -V always:forever`: the certificate's **key identity** carries the epoch,
  its **principal** is the type, and time validity is unbounded (epochs are
  logical; `always:forever` is the form `ssh-keygen` accepts — `always` alone
  is refused). An `ssh-keygen` that cannot create or verify such a
  certificate makes the writer refuse; there is no unsigned fallback. Verification requires, in addition to the signature: the
  certificate chains to the epoch root the verifier pinned for the record's
  `epoch`; its key identity is exactly `<type>@e<epoch>` for the record's
  `type` and `epoch`; its principal is the record's `type`. A seal is `ssh-keygen -Y
  sign -f <subkey> -n olddonkey-loop.authority.<type>.v1` over the payload
  bytes; verification builds a temporary `allowed_signers` line
  `<type> cert-authority,namespaces="olddonkey-loop.authority.<type>.v1"
  <root.pub>` and runs `ssh-keygen -Y verify -I <type>`. Key files are
  published before any record names them by one sequence (A1.7's "rename",
  done without replacement): write `.tmp-<16 hex>` → `fsync` → `os.link` to
  the final name (fails if it exists) → directory `fsync` → unlink the
  temporary → directory `fsync`. A crash between link and unlink leaves a
  `.tmp-*` file that nothing ever reads.
- **Deterministic anchor objects**: the scratch repository is created with
  `git init --bare --object-format=sha1`; author and committer dates are the
  raw git form `@<seq> +0000` (the `@` makes a small `seq` such as `1` parse
  as seconds since the epoch — without it git refuses `1 +0000`; explicit UTC
  offset), so the commit id does not depend on the local timezone.
- **Binaries and subprocesses**: `ssh-keygen`, `git`, and `ssh` are resolved
  only from `/usr/bin`, `/opt/homebrew/bin`, `/usr/local/bin`; `ssh-keygen`
  must accept `-Y` (OpenSSH ≥ 8.2). **Every** subprocess in `lib/loopauth`
  goes through one wrapper, `tools.run(command_id, **params)`, which scrubs
  the environment (below) and builds the argv itself from the **closed
  command table** in `lib/loopauth/tools.py`; there is no free-form argv, so
  an unlisted command, subcommand, or option cannot be expressed. A **sink**
  entry runs only with an open, row-specific transaction token for that sink
  (A1.5) — **regardless of path**: a push from the outside-store scratch
  repository is still the anchor sink, and a signature written to stdout is
  still a seal. Independently of the table, a working directory or parameter
  under the authority directory is refused without a token.

  | id | argv (`<…>` are validated parameters) | effect |
  | --- | --- | --- |
  | `git.init` | `git -C <scratch> init --bare --template= --object-format=sha1 .` (inside the just-created empty directory) | scratch |
  | `git.hash-object` | `git -C <scratch> hash-object -w --stdin` | scratch |
  | `git.mktree` | `git -C <scratch> mktree` (stdin: the one tree line) | scratch |
  | `git.commit-tree` | `git -C <scratch> commit-tree <tree> [-p <parent>] -m <message>` (pinned identity and `@<seq> +0000` dates) | scratch |
  | `git.fetch-anchor` | `git <transport options> -C <scratch> fetch --no-tags --no-write-fetch-head <remote> +refs/olddonkey-loop/anchor:refs/readback/anchor` | scratch (writes objects and one scratch ref) |
  | `git.ls-remote` | `git <transport options> -C <scratch> ls-remote <remote> refs/olddonkey-loop/anchor` | read |
  | `git.cat-file` | `git -C <scratch> cat-file (-t\|-p) <oid>` | read |
  | `git.push-anchor` | `git <transport options> -C <scratch> push <remote> <commit>:refs/olddonkey-loop/anchor` | **sink**: anchor push |
  | `ssh-keygen.generate` | `ssh-keygen -q -t ed25519 -N '' -C <comment> -f <temp path in the store's keys dir>` | **sink**: key file create |
  | `ssh-keygen.certify` | `ssh-keygen -q -s <root> -I <type>@e<epoch> -n <type> -V always:forever <subkey.pub>` | **sink**: key file create (uses the root) |
  | `ssh-keygen.sign` | `ssh-keygen -Y sign -f <subkey> -n olddonkey-loop.authority.<type>.v1` (payload on stdin, signature on stdout) | **sink**: seal |
  | `ssh-keygen.verify` | `ssh-keygen -Y verify -f <allowed_signers in scratch> -I <type> -n <namespace> -s <sig in scratch>` (payload on stdin) | read |
  | `ssh-keygen.sign-pointer` | `ssh-keygen -Y sign -f <active epoch root> -n olddonkey-loop.anchor.pointer.v1` (pointer bytes on stdin, signature on stdout) | **sink**: pointer seal |
  | `ssh-keygen.verify-pointer` | `ssh-keygen -Y verify -f <allowed_signers in scratch> -I anchor-root -n olddonkey-loop.anchor.pointer.v1 -s <sig in scratch>` (pointer bytes on stdin) | read |
  | `ssh-keygen.fingerprint` | `ssh-keygen -l -E sha256 -f <pub>` | read |

  `<remote>` is only the genesis-pinned URL; `<scratch>` only the scratch
  repository; `<type>` only a member of the closed type list. Every git
  command also starts with `-c core.hooksPath=/dev/null -c
  core.fsmonitor=false`, and the three that contact the remote add the
  `<transport options>` of §4. `ssh` is never run directly: it is reached only
  as git's transport, through `core.sshCommand` (§4).
- **The anchor pointer is signed by the epoch root, not a subkey** (A1.2).
  Its signed bytes are the canonical JSON of `{active, prev_generation}`;
  `anchor.json` is the canonical JSON of `{active, prev_generation, sig}`,
  where `sig` is the armored signature from `ssh-keygen.sign-pointer` under the
  namespace `olddonkey-loop.anchor.pointer.v1`, which no record type uses.
  Verification builds the line `anchor-root
  namespaces="olddonkey-loop.anchor.pointer.v1" <root.pub>` (a plain key, not
  `cert-authority`) from the root pinned for `active.epoch`, and runs
  `ssh-keygen.verify-pointer`.
- **Tokens are bound, in stages, to the validated effect.** A token is valid
  for one row (A1.5). Its binding is **append-only**: the transaction driver in
  `store.py` — never a sink — adds each stage once, in order, and a bound value
  can never be replaced. Stage 1 is bound before any key sink runs, and all
  three stages are bound before the intent and the frame are written (A1.6,
  A2.3):
  1. **after validation** — record rows: the record `type`, the payload
     digest, and the signing subkey's `key_id`; key rows (genesis, rotation):
     the `store_id`, epoch, exact type set, and the freshly allocated
     `key_dir`; genesis and linked re-genesis also bind the exact `active`
     target `{store_id, generation}` and the intent file's path;
  2. **after `store.seal` returns** — the frame bytes' digest (payload plus
     signature) and the pointer bytes' digest (`{active, prev_generation}`);
  3. **after `store.seal_pointer` returns** — the `anchor_json` digest, the
     `anchor_commit` built from it in the scratch repository, the ref, and the
     intent bytes' digest.

  **Each sink requires the stage its input depends on and compares its
  parameters with it**: the key sinks and `store.seal` with stage 1 (only the
  bound keys; only the bound payload and type, with the bound subkey);
  `store.seal_pointer` with stage 2 (only the bound pointer bytes); the frame
  append with stage 2 and the intent write with stage 3 (only the bound
  bytes); `store.push_anchor` with stage 3 (only the bound commit to the
  bound ref); the `active` marker with stage 1 (only the bound target).
  Key files are created **without replacement** (the sequence above), so no
  published key is ever overwritten. A sink called
  before its stage is bound, with any differing parameter, or after an
  attempt to re-bind a stage, refuses with no mutation.
- **Sink ownership.** **Every** token-checked sink function lives in
  `store.py` — the frame, intent, cursor, truncation, quarantine, and
  re-genesis sinks, the key sinks (`store.create_key`, `store.certify_key`),
  sealing (`store.seal`, `store.seal_pointer`), and the anchor push
  (`store.push_anchor`). `keys.py`
  and `anchor.py` are pure helpers (parsing, fingerprints, building
  `allowed_signers` lines and anchor objects) that may call only **read** and
  **scratch** commands.

## 4. The anchor commit

Built in the scratch repository from `anchor_json` alone (A1.6): blob = the exact bytes;
tree = one entry `100644 anchor.json`; commit with parent `expected_parent`,
author and committer `olddonkey-loop <anchor@olddonkey-loop.invalid>` and
date = the raw git date `@<seq> +0000` (deterministic, timezone-independent), message
`anchor <store_id> g<generation> s<seq>`. `git hash-object -w`, `git mktree`,
and `git commit-tree` with `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` fixed; push
`git push <remote> <commit>:refs/olddonkey-loop/anchor` (fast-forward only;
a non-fast-forward is refused); readback `git fetch` of the ref into the
scratch ref `refs/readback/anchor`, then verify by content (A1.2 step 4).

**The remote and git isolation.** `genesis --remote` accepts, in production,
only two URL forms, pinned in the genesis record: `git@<host>:<path>.git` (SSH)
and `https://<host>/<path>.git`. **`file:///<absolute path>` is accepted only
when `LOOP_AUTHORITY_TEST=1`**, and the genesis record then carries
`anchor_class: "test"`: a local bare repository can be restored together with
the store, so a test-anchored store gives **no current authorization** —
`status` and the verifier report it as test-only. In practice only the
selftests set the flag, but it is not a boundary: any caller that sets it can
create **only a permanently non-authorizing test lineage**, which is the real
safeguard. **The remote never changes** (A1.2: one ref, named at genesis,
whose history is the generation chain): epoch rotation and linked re-genesis
take no remote parameter, `store.regenesis` copies the pinned remote, and a
record naming any other remote is refused by the writer and the verifier;
moving to another remote would need its own amendment and crash protocol.
**The test class is therefore a permanent property of the lineage**, never a
free field: every reader (the writer, `status`, the verifier, and 0a.3's
authorization checks) derives it from the remote pinned in generation 1's
genesis record, checked equal along every `store.regenesis` link; a record
whose `anchor_class` disagrees with the pinned remote is refused by the
verifier; linked re-genesis of a test lineage requires `LOOP_AUTHORITY_TEST=1`.
Anything else
— any `<transport>::` form (`ext::`, `fd::`, …), whitespace, a leading `-`,
credentials in the URL — is refused. Every `git` run gets an environment **built from an allowlist**, not a
scrubbed copy: `PATH` fixed to the binary allowlist's directories, `HOME`,
`LANG=C`, `LC_ALL=C`, `SSH_AUTH_SOCK` (for an SSH agent), `TMPDIR` set to
the **writer's own scratch directory** (below) — never the inherited value — and the
explicit settings `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_TERMINAL_PROMPT=0`; nothing else is inherited, so `GIT_CONFIG_COUNT` /
`GIT_CONFIG_KEY_*` / `GIT_CONFIG_VALUE_*`, `GIT_SSL_NO_VERIFY`, `GIT_SSH*`,
`GIT_PROXY_COMMAND`, `GIT_EXEC_PATH`, and the askpass variables cannot reach
it.

**Transport options** — the exact `-c` list, in this order, that the writer
and the verifier (each with its own code) put before the subcommand of every
git command that contacts the remote:

- always: `-c protocol.allow=never -c protocol.<t>.allow=always`, where `<t>`
  is exactly the pinned transport (`ssh`, `https`, or — test lineage only —
  `file`);
- SSH remote: `-c "core.sshCommand=<ssh> -F /dev/null -o BatchMode=yes -o
  StrictHostKeyChecking=yes -o UpdateHostKeys=no"`, `<ssh>` the absolute path
  from the binary allowlist — so neither the user's ssh config nor any
  `ProxyCommand` or `Match exec` in it is read (`GIT_SSH*` cannot override it:
  the environment is allowlisted);
- HTTPS remote: `-c http.sslVerify=true -c http.followRedirects=false -c
  credential.helper= -c "credential.helper=!<gh> auth git-credential"`, where
  the empty value clears any helper list and `<gh>` is the absolute path from
  the binary allowlist (both helper options omitted when `gh` is absent).

A remote that cannot be reached this way leaves the store pending (A1.2); it
never falls back to inherited configuration. Only the HTTPS form accepts an
optional `:<port>` after the host; in the SSH form `git@<host>:<path>.git`
the colon starts the path, and a port is not expressible.

**Temporary files.** At start the writer creates a fresh scratch directory
`$HOME/.cache/olddonkey-loop/tmp/<pid>-<16 hex>` (0700, created with
`O_NOFOLLOW` checks on every component, refused if its resolved path lies
under the authority directory), sets `tempfile.tempdir` to it in-process, and
passes it as `TMPDIR` to every subprocess (`git`, `ssh`, `ssh-keygen`, the
credential helper); it is removed on exit. The inherited `TMPDIR` is ignored
everywhere, so no temporary write — the writer's or a child's — can land in
authority state outside the token-checked sinks.

## 5. Ceremonies (operator-TTY, A1.1)

`scripts/loop-authority ceremony <genesis|rotate|revoke|regenesis>` refuses
unless stdin and stdout are TTYs; prints the canonical envelope and a
12-hex-character challenge from `secrets`; proceeds only on an exact echo;
records `principal = {kind: operator-tty, tty: ttyname(0), start_token}` with
`start_token = {boot_id, pid, start_time}` (A1.8): on macOS `boot_id` from
`sysctl kern.bootsessionuuid` and `start_time` the process's
`p_starttime` in **microseconds**, read with `ctypes` from
`sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)`; on Linux `boot_id` from
`/proc/sys/kernel/random/boot_id` and `start_time` field 22 of
`/proc/<pid>/stat` (clock ticks since boot). If either value cannot be read,
the ceremony refuses — there is no coarser fallback. No
environment variable skips the TTY check. `genesis` takes `--remote <url>` and
refuses when `active`, `genesis.intent`, `regenesis.intent`, or the remote
ref exists (A2.3).

## 6. The test seam for crash injection

Crash injection (A1.2, A1.6) needs the writer to die at exact points.
`LOOP_AUTHORITY_CRASH_AT=<point>` is honoured **only** when
`LOOP_AUTHORITY_TEST=1` is also set, and its only effect is `os._exit(137)` at
the named point — it cannot skip a check, change a value, or write anything.
The closed point list: `after-intent-fsync`, `frame-byte-<n>`,
`after-frame-fsync`, `after-push`, `after-readback`, `after-intent-remove`,
`regenesis-step-<1..5>`, `genesis-step-<1..5>`, `genesis-step-6a`,
`genesis-step-6b`, and for genesis and rotation
`after-store-dir` and `key-step-<n>` (after the `n`-th durable key or
certificate link of that ceremony). An unknown point, a `frame-byte-<n>` with `n`
not strictly inside the frame being written, or a `key-step-<n>` beyond the
ceremony's key steps makes the writer refuse to start.
The selftest runs the writer as a subprocess under a scratch `HOME`.

## 7. Fields

**C:** `skills/implementation-loop/lib/loopauth/records.py`, `keys.py`,
`frame.py`, `store.py` (layout, lock, `begin`/commit, the sink functions),
`anchor.py`, `recover.py`, `ceremony.py`, `registry.py`,
`skills/implementation-loop/scripts/loop-authority` (`status`, `verify`,
`recover`, `ceremony …`), `skills/implementation-loop/scripts/loop-authority-verify`
(independent: its own frame parser, canonical encoder, chain and anchor
checks; **imports nothing from `lib/loopauth`**; writes nothing to the
authority store or the remote — it fetches the anchor into a **disposable
scratch repository in a fresh temporary directory** that it deletes, and
writes its temporary `allowed_signers` there. Its git and ssh runs are
**separately implemented** — by design it shares no code with `tools.py` —
with the same rules: an environment built from its own allowlist (never
inherited), `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
`-c protocol.allow=never` plus the pinned transport, `-c http.sslVerify=true`,
ssh as `-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes`, and
exactly three argv forms, each with `-c core.hooksPath=/dev/null -c
core.fsmonitor=false` (and the transport options where the remote is
contacted) before the subcommand, and the same `[core]`-only config check
after init: `git -C <temp> init --bare --template= --object-format=sha1 .`,
`git -C <temp> fetch --no-tags --no-write-fetch-head <pinned remote>
+refs/olddonkey-loop/anchor:refs/verify/anchor`, and `git -C <temp> cat-file
(-t|-p) <oid>`, where the remote is only the genesis-pinned URL),
`skills/implementation-loop/lib/loopauth/tools.py` (the subprocess wrapper),
`skills/implementation-loop/tests/authority-selftest.sh`,
`skills/implementation-loop/tests/registry-selftest.sh`.

**M:** `references/state-schema.md` (the authority store, records, anchor,
recovery states), `.github/workflows/selftest.yml` (`bash -n` for both scripts
and both suites; run steps), `AGENTS.md`.

**T** — `authority-selftest.sh` (scratch `HOME`, a `file://` bare remote in a
temp directory, subprocess writer):
- canonical payload vectors; a frame's digest over header-without-digest plus
  payload; each header field mutated → quarantine;
- per-type subkeys: a signature for type A never verifies as type B (key and
  namespace each tested alone); a subkey certificate with a wrong principal,
  namespace, or epoch refused; the verifier pins the root from the genesis
  and rotation records;
- the write protocol's five steps and every recovery-table row of A1.2,
  each as its own case; the frozen vectors of A1.6 (every byte boundary of a
  frame write; the last-byte crash, remote-old and remote-new; a crash after
  push before intent removal → committed; a stale intent for `L` → quarantine;
  cursor-only disagreement → tidied; step-1-only intent → tidied);
- the anchor: wrong parent, extra tree entry, or blob differing from
  `anchor_json` refused before the frame and quarantined on recovery; a
  readback whose ref id matches but whose content or signature differs fails;
  a non-fast-forward remote refused; a remote rolled back one step → quarantine;
  a same-sequence fork → quarantine; an unreachable remote → pending, with no
  current authorization reported by `status` and the verifier;
- epochs: rotation moves the old root to verify-only and refuses sealing with
  it; revocation of a verify-only epoch; revocation of the active epoch is the
  root's last act, compound with quarantine, crashed at every cut with no
  current authorization and the replayed commit's id equal to the stored one;
- linked re-genesis at every crash cut (A1.3), including an invalid anchor
  signature at each cut (both stores untouched, quarantine), and a
  generation-changing pointer with a valid new-root signature but an invalid or
  unlinked ceremony record, and the reverse;
- ceremonies: refused without a TTY and with a wrong challenge (driven through
  Python's `pty`); `genesis` refused when `active` exists (whatever the
  store holds), when either intent exists, and when the remote ref exists;
- key staging: rotation crashed at every `key-step-<n>` before its intent
  leaves the old epoch active, the verifier passing, and the leftover
  directory unpublished — a planted change to its private key or certificate
  changes nothing — and the next rotation succeeds with a fresh directory;
- genesis at every cut (`genesis-step-<1..5>`, `genesis-step-6a`,
  `genesis-step-6b`, `after-store-dir`, every `key-step-<n>`, every
  `frame-byte-<n>`), each landing on its A2.3 row: before `genesis.intent` is
  durable only an inert directory remains; with the intent, `active` absent,
  and frame 1 **none or torn** and the ref absent, recovery abandons (the
  intent-named directory discarded, the intent removed, a new genesis
  succeeds); frame 1 **unterminated** with the ref absent is completed by
  delimiter completion plus replay-forward, and with the exact ref is
  quarantine; frame 1 **valid** with the ref absent is replayed and completed,
  and with the exact ref is completed; every other case and vector listed in
  A2.4's tests (nonconforming tails, unparsable intent, wrong `active`, the
  6a–6b cut, unreachable remote, unrelated or badly signed pointers, a ref
  deleted after success) lands on its row with its exact status; with an otherwise valid same-row token, a key
  sink given another `key_dir` or an existing key file, the `active` sink
  given another target, and the discard sink given another directory are
  refused; A2.4's ceremony token is refused on any other sink;
- bootstrap terminal states: after each of `genesis-invalid`,
  `anchor-mismatch`, and `genesis-quarantined`, every ceremony and every row
  is refused with no mutation, `status` names the state and its evidence,
  and read-only verification still runs;
- the independent verifier agrees with the writer on a corpus of valid and
  invalid stores and imports nothing from `lib/loopauth` (source check); run
  with the authority directory and the bare remote made read-only
  (`chmod -R a-w`), it succeeds, both are byte-identical afterwards, and its
  temporary directory is gone; run under the same injected-variable fixtures
  as the writer below (`GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`, a global git
  config, `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0`, `GIT_SSL_NO_VERIFY=1`, an
  authority-root `TMPDIR`), it fetches only the pinned remote, no marker is
  written, and its git wrapper fixture records none of those variables;
- the remote: `ext::`, `fd::`, another `<x>::` form, whitespace, a leading
  `-`, and credentials in the URL each refused at genesis; `file://` refused
  without `LOOP_AUTHORITY_TEST=1`, and a test-anchored store reported as
  giving no current authorization; with `GIT_SSH_COMMAND`,
  `GIT_PROXY_COMMAND`, a global git config, and `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` each pointing at a
  marker-writing script, and with `GIT_SSL_NO_VERIFY=1`, a push and a fetch
  run and the marker is never written and the variable never reaches git
  (checked by a git wrapper fixture that records its environment);
- the remote and the test class: a linked re-genesis of a test lineage stays
  `test` with no current authorization; without `LOOP_AUTHORITY_TEST=1` it is
  refused; a `store.regenesis` or rotation record naming a remote other than
  the pinned one is refused by the writer and the verifier; a record claiming
  `anchor_class` other than `test` with a `file://` remote is refused by the
  verifier;
- the anchor pointer: a pointer signed by the active root verifies; one
  signed by another epoch's root, by a subkey, or under a record namespace,
  and one whose `{active, prev_generation}` bytes were altered after signing,
  are each refused by the writer's readback and by the verifier;
- transport construction: for an SSH, an HTTPS, and a `file://` remote, the
  exact argv and environment of every remote-contacting command, from the
  writer's builder and from the verifier's, equal a frozen expectation
  written in the test;
- repository config: pre-existing sibling directories under `anchor-scratch/`
  whose config sets `url.<decoy>.insteadOf`, `pushInsteadOf`, and a credential
  helper are never used; with the writer's and the verifier's working
  directory inside a git repository whose `.git/config` rewrites the pinned
  URL to a decoy bare remote, the push and fetches reach only the pinned
  remote (the decoy's refs unchanged); a scratch `config` with any section
  other than `[core]` is refused;
- SSH behaviour: under a scratch `HOME` whose `~/.ssh/config` has `Host *`
  with a `ProxyCommand` and a `Match exec` that write a marker (positive
  control: `ssh -G -F <that config> x` shows both), a genesis pinned to
  `git@127.0.0.1:x.git` fails to push and leaves the store pending, and the
  verifier's fetch fails, with the marker never written;
- HTTPS behaviour: against a local TLS server with a self-signed certificate
  on `127.0.0.1`, a genesis pinned to `https://127.0.0.1:<port>/x.git` and the
  verifier's fetch both fail certificate verification — also with
  `GIT_SSL_NO_VERIFY=1` injected and `http.sslVerify=false` in an injected
  global config — and the store stays pending;
- temporary files: with the inherited `TMPDIR` pointed at the authority
  directory, a genesis, a rotation, and a recovery run leave the authority
  directory containing exactly the files the sinks wrote (listed before and
  after), and the git, ssh, and ssh-keygen wrapper fixtures each record
  `TMPDIR` equal to the writer's scratch directory, which is gone afterwards;
- anchor objects: an actual anchor commit is created at `seq` 1 (genesis);
  the same record under `TZ=UTC` and `TZ=Asia/Shanghai` yields the same
  commit id; genesis and rotation actually create and verify
  per-type certificates with the host `ssh-keygen` (in CI too);
- no standalone signing type exists for segment reset, mechanism closure, or
  release acceptance; sealing a record of those names is refused;
- the activation boundary (A2.1): genesis and rotation records carry
  `admitted_protocols: []`; a validly sealed `request.opened` (and each other
  request type) planted in the log by the test with the store's own subkey is
  refused by the writer's log validation and by the independent verifier,
  and the store quarantines;
- start tokens: the comparison function, given two tokens with equal
  `boot_id`, `pid`, and whole second but different microseconds, treats them
  as different processes (a deterministic fixture — no skip); the reader
  returns microseconds on the host (a live check that the fraction field is
  populated); an unreadable start time refuses the ceremony;
- `key_id` and epochs: a valid signature whose payload `key_id` differs from
  the verifying certificate refused; a certificate from another epoch's root,
  or whose key identity names another epoch, refused;
- the crash seam: honoured only with `LOOP_AUTHORITY_TEST=1`; an unknown point
  and an out-of-frame `frame-byte-<n>` refused; with `LOOP_AUTHORITY_TEST=1`
  and a crash point set, a ceremony without a TTY is still refused (the seam
  never suppresses validation);
- dormant rows and `approval.consume`, named explicitly in the test's oracle:
  request opening + capability issuance, request cancellation (both
  branches), request expiry, capability redemption, gesture-nonce issuance,
  repository registration, rebind, execution-root registration, standing
  authorization, standing revocation, segment discharge, enrollment,
  enrollment revocation, mechanism closure, acceptance-platform designation,
  and release acceptance — each refused with its distinct error and no
  mutation — and `approval.consume` refused likewise;
- the activation boundary: every introducer (genesis, rotation, re-genesis,
  at each re-genesis recovery cut) carries `registry_version: "tg-v1.0a"`
  and `admitted_protocols: []`; an introducer with a nonempty list (a
  premature future protocol) or an unknown registry version is refused by
  the writer and by the independent verifier; for genesis, rotation, and
  re-genesis, the fields shown in the PTY-captured ceremony display equal the
  sealed introducer's. The **lower-version** and **dropped-protocol** checks
  cannot be isolated while 0a knows a single version with an empty list, so
  their positive and negative tests are a gate of the first activating unit
  (unit 8), which introduces a second version with a nonempty list;

**T** — `registry-selftest.sh`:
- the registry holds every row of `tg:809-829` and A1.3 with its six columns
  and exclusion ids, compared with a **frozen oracle written in the test**;
- **reachability** (A1.5): an AST scan of `lib/loopauth/` proving that every
  write to any sink of A1.5's list goes through a token-checked function in
  `store.py` (the **frozen sink-function list** of §3, written in the test);
  with an otherwise **valid, same-row** token, at each stage: `store.seal`
  given another type, subkey, or payload; `store.seal_pointer` given other
  pointer bytes; the frame append and the intent write given other bytes;
  `store.push_anchor` given another commit or ref — each refused with no
  mutation, including when the low-level sink is called directly; a sink
  called before its stage is bound, and an attempt to re-bind a bound stage,
  refused;
  that **every subprocess call** goes through `tools.run`, and that `keys.py`
  and `anchor.py` reach only read and scratch commands; the command table is
  compared with a frozen copy written in the test; an unlisted git variant
  (e.g. `fetch` without `--no-write-fetch-head`, `push --force`, a push
  without the transport options) cannot be built, and `ssh-keygen.sign` with stdout output and no token is refused; each sink called with no token, a spent token, and another row's
  token refused (local files and the remote push); recovery-derived rows
  without a recovery token, or with one bound to a different observed state,
  refused; **planted-bypass** copies make the reachability test fail (negative
  controls): one with an extra unchecked Python file write into the store,
  one with a direct `subprocess.run(["git", …])` whose working directory is the
  authority directory, one with an unchecked key-file write added to
  `keys.py`, and one with a direct `tools.run("git.push-anchor", …)` call
  from a non-sink function — which both fails the reachability scan and, run,
  is refused at `tools.run` with the bare remote's ref unchanged; a command
  outside the closed table is refused;
- every dormant row refused with its distinct error and no store or anchor
  mutation (A1.4); every 0a.2-admissible row's validator, exclusion, and
  transition positive and negative.

**G:** none (no Cursor build input is touched).
**Gate:** the full host replica of `.github/workflows/selftest.yml` plus both
new suites.

## 8. Open questions for review

1. Is the split (0a.2 store and ceremonies; 0a.3 requests; 0a.4 nonce and the
   end-to-end falsifier) coherent with A1.4's table, where all of them are
   "admissible from 0a"?
2. Is the crash seam (§6) consistent with A1.1's "no environment variable
   skips the TTY check" and with the falsifier?
3. Is certifying one subkey per type for the closed Phase A type list at
   genesis and rotation the right reading of A1.7, given later units add no new
   types in Phase A?

---

## 9. Round-1 disposition (Codex gpt-6-sol / max, thread `01a0ebb0`)

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: `anchor.git` inside the store | **accepted** — the scratch repository lives in `~/.cache`, is not authority state and is rebuildable; every subprocess goes through `tools.run`; a planted direct git subprocess into the store is a negative control |
| 2 | BLOCKER: compound records undefined | **accepted** — opening + issuance and redemption + consequence are one frame each, with nested bodies; no compound part has its own type |
| 3 | MAJOR: initial admissibility of 0a.3/0a.4 rows | **accepted** — every row's 0a.2 flag listed; all 0a.3/0a.4 rows dormant from the first write; `approval.consume` refused from 0a.2; tested |
| 4 | MAJOR: remote URL is an uncontrolled git input | **accepted** — three pinned URL forms; helpers and injected forms refused; system/global config and command variables isolated; ssh without user config; one named credential helper; tested with marker scripts |
| 5 | MAJOR: macOS start token at second precision | **accepted** — microsecond `p_starttime` via `sysctl` through `ctypes`; no coarser fallback; tested |
| 6 | MAJOR: verifier "opens nothing for writing" | **accepted** — it writes only to a disposable temporary scratch repository; tested with the store and remote read-only |
| 7 | MAJOR: `key_id` and certificate epoch binding | **accepted** — `key_id` is the subkey fingerprint; certificate identity `<type>@e<epoch>`, principal the type, `-V always`; mismatches tested |
| 8 | MINOR: archive wording, seam tests | **accepted** — "moved"; the seam never suppresses the TTY check; out-of-frame byte points refused |

## 10. Round-2 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: production `file://` defeats the anchor | **accepted** — `file://` only with `LOOP_AUTHORITY_TEST=1`, marked `anchor_class: test`, giving no current authorization; tested |
| 2 | BLOCKER: `-V always` fails on the host | **accepted** — `-V always:forever`; real certificate creation and verification run in the selftest and CI; an incapable `ssh-keygen` refuses |
| 3 | MAJOR: inherited git environment | **accepted** — the git environment is built from an allowlist; `GIT_CONFIG_*` injection and `GIT_SSL_NO_VERIFY` tested |
| 4 | MAJOR: standalone compound types | **accepted** — removed; they exist only nested in `request.redeemed`; direct sealing refused |
| 5 | MAJOR: start-token test could skip | **accepted** — a deterministic comparison fixture plus a live check that microseconds are populated |
| 6 | MINOR: commit date encoding | **accepted** — raw `<seq> +0000`, `--object-format=sha1`; identical ids under two timezones tested |

## 11. Round-3 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: `<seq> +0000` refused by git for small `seq` | **accepted** — `@<seq> +0000`; an actual commit at `seq` 1 is tested |
| 2 | MAJOR: test class not pinned across re-genesis | **accepted** — derived from the whole lineage by every reader; re-genesis from a test lineage stays test and needs `LOOP_AUTHORITY_TEST=1`; mismatches refused; tested |
| 3 | MAJOR: inherited `TMPDIR` can reach authority state | **accepted** — the writer's own scratch directory outside authority state is `TMPDIR` and `tempfile.tempdir`; inherited value ignored; tested |

## 12. Round-4 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: `tools.run` is a generic push path | **accepted** — a closed command table classifies every subprocess as read / scratch / sink; a sink command (the push included, whatever the path) needs an open row-specific token that only the token-checked sink functions supply; a planted direct `tools.run` push is a negative control that fails the scan and is refused at run time with the remote unchanged |
| 2 | MINOR: the test flag is not a boundary | **accepted** — reworded: any flag-setting caller can create only a permanently non-authorizing test lineage |

## 13. Round-5 disposition, and two self-contradictions

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: the command table is neither closed nor consistent | **accepted** — `tools.run` takes a command id and builds the argv from an enumerated table; fetch is **scratch**; signing is a **sink** whatever its output; the table is frozen in the test; unlisted variants cannot be built; unsigned-token stdout signing refused |
| 2 | MAJOR: key sinks in `keys.py` vs the `store.py` oracle | **accepted** — every sink function, keys, seal, and push included, lives in `store.py`; `keys.py` and `anchor.py` are pure helpers limited to read and scratch commands; an unchecked key write in `keys.py` is a planted negative control |
| — | self-found: §3 nested an `approval_grant` consequence that `tg:846` does not have | fixed — `approval` has only `T-request-answered`; its answer carries the envelope digest and is the grant |
| — | self-found: §1 listed `approval.consume` refusal under 0a.4 while §1's prose puts it in 0a.2 | fixed — refused from 0a.2; the 0a.4 row no longer claims it |

## 14. Round-6 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: a valid row token is not bound to the validated effect | **accepted** — the validator path binds each token once to the exact record type, payload digest, subkey, frame bytes, and anchor commit and ref (or, for key rows, the store, epoch, and type set); every sink compares and refuses on difference or an unbound token; wrong type, subkey, payload, bytes, commit, and ref each tested with a valid same-row token |
| 2 | MAJOR: the verifier's git path is unspecified and untested | **accepted** — the verifier's separately implemented allowlist environment, pinned options, and three exact argv forms are specified; it runs under every injected-variable fixture and fetches only the pinned remote |

## 15. Round-7 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: binding cannot precede the first seal | **accepted** — staged, append-only binding under one token (validated payload and key → frame and pointer bytes → anchor JSON, commit, ref, intent), all before the first durable write; each sink checks its stage; substitutions at each stage and direct low-level calls tested |
| 2 | BLOCKER: no command signs the pointer | **accepted** — `ssh-keygen.sign-pointer` / `verify-pointer` with the root, namespace `olddonkey-loop.anchor.pointer.v1`, exact pointer bytes, `store.seal_pointer` as a stage-2 sink; positive, wrong-root, subkey, wrong-namespace, and altered-bytes tests |
| 3 | MAJOR: re-genesis could change the remote | **accepted** — the remote never changes; rotation and re-genesis take none; a different remote is refused by writer and verifier; migration would need its own amendment |
| 4 | MAJOR: transport isolation absent from the exact argv | **accepted** — the exact transport `-c` list (protocol allow, `core.sshCommand` with pinned options, HTTPS verify/redirect/helper) is specified for both implementations; a frozen construction oracle; SSH-config marker and local self-signed-TLS behaviour fixtures |

## 16. Round-8 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: pre-intent key writes have no crash rule | **accepted** — key directories carry a random suffix and are published only by the record naming them; genesis writes `active` before its record, reads an absent ref as `ptr(0)`, and treats an empty store as absent, so every cut is covered by existing rows or leaves inert files; new crash points and tests at every key step |
| 2 | MAJOR: local git config can redirect the remote | **accepted** — a fresh scratch repository per transaction and verifier run (exclusive creation, `--template=`, `[core]`-only config check), `-C` on every command including `ls-remote`; decoy-rewrite fixtures for sibling scratch config and for the working directory's repository |
| 3 | MINOR: SSH port syntax | **accepted** — a port only in the HTTPS form |

## 17. Round-9 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: `ptr(0)` and "empty store = absent" do not fit A1 | **accepted** — withdrawn. Genesis now follows A1.3's re-genesis shape: `genesis.intent`, an unpublished store, the push as commit point, and recovery that abandons (ref absent), completes (ref verified against the new store's genesis root), or fails closed (`anchor-mismatch`); absent store = no `active`. The recovery token for completing or abandoning a ceremony is a gap A1 already has for re-genesis; it is proposed as **A2.3** (`plans/task-graph-v1-amendment-a2.md`) rather than assumed |
| 2 | MAJOR: `key_dir` and `active` not bound | **accepted** — stage 1 binds the allocated `key_dir`, the `active` target, and the intent path; key files are created without replacement; wrong directory, existing key, and wrong target tested with valid same-row tokens |
| 3 | MINOR: `git init` without `-C` | **accepted** — `git -C <scratch> init … .` in both implementations |

## 18. Round-10 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: abandonment can hide a pushed-then-deleted genesis | **accepted** — the bootstrap rule moves into the plan as **A2.3**: abandonment only without a complete valid frame 1; with it, replay-forward of the intent's exact commit to an absent ref (the absent ref plays `ptr(L − 1)` only under a genesis intent); once `active` exists an absent ref is quarantine; the deleted-ref case tested |
| 2 | MAJOR: A2.3 minted before proving exact state | **accepted** — now **A2.4**: completion needs the intent's exact commit and byte-equal pointer, abandonment the exact recorded pre-ceremony state (re-genesis intents now record the old commit); unrelated and advanced pointers mint nothing |
| 3 | MAJOR: re-genesis discard sink missing | **accepted** — A2.4 authorizes discarding exactly the intent-named directory; wrong-directory tested |
| 4 | MAJOR: two genesis intents, no order | **accepted** — one `genesis.intent`, written once and complete (A1.6 fields for frame 1 plus store, key directory, remote) before the frame; it is the only intent for frame 1 |
| 5 | MAJOR: stale empty-store refusal | **accepted** — genesis refuses on any `active`, either intent, or the ref; §5 and the test aligned |
| 6 | MINOR: verifier init argv | **accepted** — `git -C <temp> init … .` |

## 19. Round-11 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: "no complete valid frame" too broad for abandonment | **accepted** — A2.3 classifies frame 1 as none / torn / unterminated / valid / invalid; abandonment only for none or torn; unterminated → delimiter completion + replay; invalid → fail closed |
| 2 | MAJOR: `active` omitted during step 6 | **accepted** — step 6 split into 6a (`active`) and 6b (intent removal); `active` absent / exact / other is a table column; an absent ref after 6a is quarantine; A2.4's predicate includes it |
| 3 | MAJOR: unreachable remote has no outcome | **accepted** — row 1: pending, no mutation, no token, retried; tested at each cut for writer and verifier |
| 4 | MINOR: stale stage-timing sentence | **accepted** — stage 1 precedes key sinks; all stages precede intent and frame |

## 20. Round-12 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | MAJOR: unreachable masks local corruption | **accepted** — A2.3 classifies intent, `active`, and frame 1 before reading the remote; unreachable → pending only after local checks pass; tested with each local fault and an unreachable remote |
| 2 | MAJOR: malformed partial and trailing data unclassified | **accepted** — a **nonconforming** class (short non-prefix tail, wrong length, trailing bytes, invalid or differing frame) → quarantine; **valid** requires exact end of file; vectors added |
| 3 | MAJOR: row order defeats post-`active` rollback | **accepted** — nonconforming (row 3) and post-`active` absent ref (row 5) are both quarantine, so no order can turn a rollback into a softer outcome |
| 4 | MAJOR: remote-new unterminated frame | **accepted** — row 10: the exact commit over a none/torn/unterminated frame is quarantine; tested through genesis recovery |
| 5 | MINOR: test shorthand | **accepted** — the genesis test names none/torn for abandonment and states the unterminated outcomes separately |

## 21. Round-13 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: torn-prefix test needs the frame bytes | **accepted** — `genesis.intent` durably carries `frame_b64`; a genuine crash prefix and an altered same-length prefix tested separately |
| 2 | MAJOR: a parseable invalid intent could be abandoned | **accepted** — A2.3 defines intent validity (schema, frame bytes and digest, genesis record seal and certificate, pointer and its signature, rebuilt commit) checked before row selection; any failure is row 1 (fail closed); each defect tested with no frame and an absent ref |
| 3 | MAJOR: malformed `active` unclassified | **accepted** — row 2 is any `active` present but not exactly the intent's store, malformed and unreadable included; tested with the remote reachable and unreachable |
| 4 | MAJOR: quarantined unanchored genesis has no admitted exit | **accepted** — new row **A2.5** `unanchored genesis retirement` (operator-TTY, ref absent and reachable, `active` absent) archives the store and removes the intent; every other bootstrap failure is declared terminal, with no manual change presented as recovery |

## 22. Round-14 disposition

| # | finding | disposition |
| --- | --- | --- |
| 1 | BLOCKER: an absent ref does not prove genesis never anchored | **accepted** — A2.5 is **withdrawn**; bootstrap failures are declared terminal for the authority directory (A2.3), since local evidence cannot prove the ceremony stopped before its push |
| 2 | BLOCKER: retirement's crash path | **moot** — A2.5 withdrawn |
| 3 | MAJOR: evidence-free reset | **moot** — A2.5 withdrawn; no row clears a bootstrap failure |

## 23. Round-15 disposition — ACCEPT

| # | finding | disposition |
| --- | --- | --- |
| 1 | MINOR: two key publication procedures | **applied** — one sequence: temp, `fsync`, `os.link` without replacement, directory `fsync`, unlink, directory `fsync`; a leftover `.tmp-*` is never read |
| 2 | MINOR: intent length and digest subjects | **applied** (in A2.3) — `length` and `digest` keep A1.6's meaning; `frame_length` and `frame_b64` cover the whole frame; validity checks the header against them |

## 24. Post-acceptance delta under A2.1 (reviewed with 0a.3, thread `01a0ec41`)

The 0a.3 review moved the request rows out of 0a (A2.1) and added a durable
activation boundary. This document changed accordingly: §1's allocation row
for 0a.3 and the dormant-row list (segment discharge → unit 8); §3's
compound-redemption crash tests → units 8, 9, 12; §3's activation boundary
on every epoch introducer; §7's explicit dormant-row oracle and
activation-boundary tests, with the lower-version and dropped-protocol tests
gated to unit 8 and a display-versus-sealed ceremony check.

