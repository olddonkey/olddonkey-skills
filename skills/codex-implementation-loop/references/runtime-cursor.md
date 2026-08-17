# cursor-agent runtime — shipped backend

**Status: shipped.** This backend uses a git-less-copy boundary. It does not
reuse grok's linked-worktree or snapshot-transition mechanism because
cursor-agent treats the whole discovered Git repository, including `.git`, as
its writable workspace. Read this before the first cursor-agent dispatch in a
session; the shared observable interface is in
[dispatch-contract.md](dispatch-contract.md).

## Contents

- [Dispatch and model](#dispatch-and-model)
- [Why the copy is the boundary](#why-the-copy-is-the-boundary)
- [Copy, patch, and apply protocol](#copy-patch-and-apply-protocol)
- [Read-only and iterate](#read-only-and-iterate)
- [Safety invariants](#safety-invariants)
- [Stuck jobs](#stuck-jobs)
- [Calibration record](#calibration-record)
- [Live smoke procedure](#live-smoke-procedure)
- [Revive or verify](#revive-or-verify)

## Dispatch and model

Run from the real unit worktree root:

```bash
"${CLAUDE_SKILL_DIR}/scripts/cursor-dispatch.sh" \
  --prompt-file /tmp/unit-prompt.txt \
  --model cursor-grok-4.6-xhigh
```

The adapter default is **`cursor-grok-4.6-xhigh`**: Grok 4.6 at xhigh. Known
variants are `cursor-grok-4.6-{low,medium,high,xhigh}[-fast]`. Effort is part of
the model id; cursor-agent has no separate effort flag. The common `--effort`
option is therefore an assertion that the chosen model id embeds the requested
level. `CURSOR_LOOP_MODEL` and `CURSOR_LOOP_EFFORT` provide namespaced standing
values; explicit flags win.

Every real invocation is foreground and has this fixed control surface:

```text
cursor-agent -p --trust --sandbox enabled [--mode plan]
  --model <model> --output-format json <final-single-positional-prompt>
```

`--trust` prevents a non-interactive "Workspace Trust Required" stall in the
throwaway directory. `--sandbox enabled` is mandatory. `--force`, its `-f`
alias, and `--yolo` are **never** passed: they select Cursor's "Run Everything"
posture and bypass the sandbox. The adapter rejects those tokens as flags, as a
model value, and through its unsupported extra-args environment seam.

cursor-agent 2026.08.11 has no `--prompt-file` or `--verbatim`. The adapter
reads `--prompt-file` into a shell variable, prepends a non-dash safety
preamble, and passes the result as the final single positional argument. It
does not use an uncalibrated `--` terminator; the fixed preamble prevents the
prompt from being parsed as an option.

## Why the copy is the boundary

Inside a Git repository, cursor-agent scopes its sandbox to the repository
root, not to the invoking subdirectory. That includes `.git`, so a normal or
linked worktree cannot provide the Git-state boundary used by Codex or grok.

In a directory with no discovered Git repository, cursor-agent scopes the
workspace to the CWD. The adapter therefore exposes only a plain `work/` copy:

```text
real unit worktree                  protected Git common dir
  project files                    olddonkey-loop/cursor/<dispatch-id>/
  .git or worktree marker            output.json, result, manifest, patch
          │
          │ host-side ls-files snapshot
          ▼
external cursor work root
  <dispatch-id>/
    pristine/   immutable baseline; never passed as CWD
    work/       cursor-agent CWD and only sandbox-writable project root
```

Both copies are outside the real repository and disjoint from protected run
state. The adapter rejects any `.git` file or directory in either copy and also
requires `git rev-parse --show-toplevel` to fail from each copy, catching an
ancestor repository. It unsets `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE`
for that check and for cursor-agent.

With `--trust --sandbox enabled` in this git-less CWD, live calibration proved:
ordinary in-CWD writes execute without approval, absolute out-of-CWD writes are
denied, and child network connects are denied. The copy is disposable, so even
an application-level mode failure cannot reach the real worktree or its Git
metadata.

## Copy, patch, and apply protocol

For each fresh dispatch:

1. Require CWD to equal `git rev-parse --show-toplevel` and resolve the Git
   common directory.
2. Create protected state at
   `<git-common-dir>/olddonkey-loop/cursor/<UTC>-<6-hex>/` and a separate copy
   root at
   `${CURSOR_LOOP_WORK_ROOT:-$HOME/.config/olddonkey-loop/cursor-work}/<id>/`.
3. Record the exact NUL-delimited project set from
   `git ls-files -z --cached --others --exclude-standard`. Copy working-tree
   bytes for that set to `pristine/`, then clone that baseline to `work/`.
   Ignored files and Git metadata are absent; tracked deletions remain absent.
4. Verify both paths are outside the real repository, the baseline/run state
   are outside `work/`, no `.git` entry exists, and neither directory is inside
   any discovered Git repository.
5. Run cursor-agent in `work/`, capturing stdout JSON and stderr under protected
   run state. Parse the calibrated `is_error`, `result`, and `session_id`
   fields. A nonzero process exit, invalid JSON, `is_error: true`, or a
   post-run `.git` entry is a hard failure.
6. In implement mode, run `git diff --no-index --binary` from `pristine/` to
   `work/`, normalize its headers to ordinary `a/<relative>` and
   `b/<relative>` paths, and retain `changes.patch` as the reviewable artifact.
7. Only on a successful agent result, run `git apply --check --binary` against
   the real unit worktree. A failed check leaves it untouched and retains both
   copies for forensics. A passing check is followed by `git apply --binary`.
8. Clean the copies after success unless `CURSOR_LOOP_KEEP_COPIES=1` was chosen
   for debugging. Failures retain copies, JSON, stderr, and any forensic patch.

The script runs no `git add`, `commit`, `push`, worktree registration, or other
Git-state mutation. Applying the captured patch is its only real-worktree
write. The orchestrator reviews `git status` and `git diff`, then exclusively
owns commit, gate, and publication.

## Read-only and iterate

`--read-only` and `--investigate` add `--mode plan` but still run in a git-less
copy. Plan mode is an application-level instruction, not the hard boundary;
the copy/sandbox placement is what makes it safe. The adapter emits `result`
text, creates no patch, and applies nothing. Even if plan mode edited its
throwaway copy, the real repository would remain unreachable.

cursor-agent JSON carries `session_id`, but this backend deliberately does not
resume. `--resume` errors with a pointer to the correct iterate flow: dispatch a
fresh cursor-agent session against the real worktree after the prior patch has
been applied, and put the review findings plus necessary context in the new
prompt. File state carries through the worktree; prompt text carries the
conversation. This avoids claiming thread continuity that the adapter does not
provide.

## Safety invariants

- Always use `-p --trust --sandbox enabled --model <model> --output-format
  json`; add only `--mode plan` for read-only work.
- Never use `--force`, `-f`, or `--yolo`. They bypass the very sandbox that
  makes the git-less copy safe. Never use `--approve-mcps` either.
- Refuse dispatch unless both copies are git-less, outside the real repository,
  and disjoint from protected state.
- Keep pristine and run state outside cursor-agent's CWD. cursor-agent receives
  only `work/` as its workspace.
- Treat JSON self-report as a dispatch signal, not review evidence. The patch
  and real-worktree diff remain the evidence.
- The adapter never stages, commits, pushes, opens a PR, or merges. Publication
  belongs to the orchestrator and the recorded stop-point authorization.

## Stuck jobs

The adapter is foreground-only and has no companion `status` or `cancel`.
Interrupt the foreground invocation first. If cursor-agent remains, identify
the exact process for the recorded `work copy:` path and terminate that PID;
do not kill every cursor-agent process on the host:

```bash
work_copy=/absolute/path/from/the-dispatch-summary
ps -axo pid=,ppid=,command= | grep '[c]ursor-agent'

# Inspect candidate PIDs, then on macOS confirm the cwd before killing one:
pid=<exact-cursor-agent-pid>
lsof -a -p "$pid" -d cwd -Fn 2>/dev/null
kill -TERM "$pid"
```

There is no transition or companion to wait for. After the process is gone,
keep the failed run state and copies, inspect `stderr.log` and `output.json`,
then start a fresh dispatch. Never add `--force` to unstick an approval or tool
stall.

## Calibration record

Verified live on Darwin/arm64 with authenticated cursor-agent 2026.08.11:

1. The safe headless combination is `cursor-agent -p --trust --sandbox enabled
   --model <model> --output-format json <PROMPT>`. Tools auto-execute without an
   approval stall. An in-CWD write landed, an absolute out-of-CWD write was
   denied, and network was denied.
2. `--force` and `--yolo` mean Run Everything and bypass the sandbox. With
   `--force`, both an out-of-CWD write and a network connect succeeded.
3. Workspace scope is the Git repository root when Git is discovered, or the
   CWD when it is not. This is why cursor-agent runs only in a git-less copy.
4. The selected default is `cursor-grok-4.6-xhigh`; effort is part of the model
   id and has no separate CLI flag. `--list-models` requires authentication.
5. JSON output keys are `type`, `subtype`, `is_error`, `duration_ms`,
   `duration_api_ms`, `result`, `session_id`, `request_id`, and `usage`.
   Implementer text is `result`; `session_id` is the handle name; `is_error`
   signals failure.
6. There is no `--prompt-file` or `--verbatim`. The prompt is the final single
   positional argument. A `--` terminator was not pinned by this calibration,
   so the adapter uses a fixed non-dash preamble rather than depending on it.
7. `--trust` is required for a non-interactive untrusted directory. Iterate is
   a fresh dispatch on copied file state, not `--resume`.

## Live smoke procedure

This is an **acceptance procedure**, not a normal dispatch. It intentionally
performs one tightly scoped Run Everything breach inside a disposable temp
tree to prove why production bans `--force`. Run it only with the real,
authenticated cursor-agent path. It does not touch a real repository.

### 1. Build a git-less workspace and TCP oracle

```bash
set -euo pipefail
cursor_model=cursor-grok-4.6-xhigh
smoke_root=$(mktemp -d "${TMPDIR:-/tmp}/cursor-loop-smoke.XXXXXX")
smoke_work="$smoke_root/work"
smoke_outside="$smoke_root/outside"
oracle_port_file="$smoke_root/oracle.port"
oracle_log="$smoke_root/oracle.log"
mkdir -m 700 "$smoke_work" "$smoke_outside"
test ! -e "$smoke_work/.git"
! git -C "$smoke_work" rev-parse --show-toplevel >/dev/null 2>&1

python3 - "$oracle_port_file" "$oracle_log" <<'PY' &
import pathlib, socket, sys, time
port_path, log_path = map(pathlib.Path, sys.argv[1:])
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen()
server.settimeout(1)
port_path.write_text(str(server.getsockname()[1]))
deadline = time.time() + 120
with log_path.open("w") as log:
    while time.time() < deadline:
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        with connection:
            label = connection.recv(64).decode("ascii", "replace").strip()
        log.write(label + "\n")
        log.flush()
        if label == "force":
            break
server.close()
PY
oracle_pid=$!
while [[ ! -s "$oracle_port_file" ]]; do sleep 0.05; done
oracle_port=$(cat "$oracle_port_file")

# Unsandboxed positive control: the local endpoint is reachable.
python3 - "$oracle_port" <<'PY'
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2) as connection:
    connection.sendall(b"positive\n")
PY
```

### 2. Prove the production flag set confines writes and network

```bash
safe_prompt="Use the shell tool. Run all three commands separately even if one fails, then report every exit status:
printf 'safe-in-cwd\\n' > '$smoke_work/in-cwd-safe.txt'
printf 'must-not-land\\n' > '$smoke_outside/safe-breach.txt'
python3 -c 'import socket; s=socket.create_connection((\"127.0.0.1\", $oracle_port), 2); s.sendall(b\"safe\\n\"); s.close()'"

(
  cd "$smoke_work"
  cursor-agent -p --trust --sandbox enabled \
    --model "$cursor_model" --output-format json "$safe_prompt"
) | tee "$smoke_root/safe.json"

test -f "$smoke_work/in-cwd-safe.txt"
test ! -e "$smoke_outside/safe-breach.txt"
! grep -qx safe "$oracle_log"
```

The in-CWD file must exist. The absolute out-of-CWD file must not exist, and
the TCP oracle must not record `safe`.

### 3. Deliberately prove `--force` breaches both controls

```bash
force_prompt="Acceptance-only breach probe. Use the shell tool and run both commands separately:
printf 'force-bypassed-sandbox\\n' > '$smoke_outside/force-breach.txt'
python3 -c 'import socket; s=socket.create_connection((\"127.0.0.1\", $oracle_port), 2); s.sendall(b\"force\\n\"); s.close()'"

(
  cd "$smoke_work"
  cursor-agent -p --trust --sandbox enabled --force \
    --model "$cursor_model" --output-format json "$force_prompt"
) | tee "$smoke_root/force.json"

wait "$oracle_pid"
test -f "$smoke_outside/force-breach.txt"
grep -qx positive "$oracle_log"
grep -qx force "$oracle_log"
! grep -qx safe "$oracle_log"
printf 'smoke evidence retained at %s\n' "$smoke_root"
```

Acceptance requires all assertions to pass: normal sandboxed execution writes
only inside CWD and cannot connect; `--force` writes outside CWD and connects.
Retain both JSON files and `oracle.log` with `uname -srm` and
`cursor-agent --version`. Move the disposable directory to Trash after the
evidence is reviewed.

## Revive or verify

After a cursor-agent upgrade, sandbox-policy change, or model-id change, rerun
`cursor-selftest.sh` first and then the live smoke above on the real agent path.
If the safe case can reach outside CWD or the network, or if tools require
Run Everything to proceed, stop using this backend until a new hard boundary is
designed and documented. Never revive it by relaxing the fixed flag set.
