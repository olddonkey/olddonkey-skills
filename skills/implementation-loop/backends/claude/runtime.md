# Claude Code runtime — shipped coordinator backend

**Status: shipped.** This backend implements the shared
[dispatch contract](../../references/dispatch-contract.md) for a coordinator.
It is deliberately absent from the agent-driven loop's `backend` dial: a Claude
session choosing Claude as its implementer is the same-model case described in
[dials.md](../../references/dials.md).

## Dispatch, model, and effort

Run `backends/claude/dispatch.sh` from the real Git worktree root with
`--prompt-file PATH` or `--prompt TEXT`. `--model` and `--effort` pass through to
`claude` when set. `CLAUDE_LOOP_MODEL` and `CLAUDE_LOOP_EFFORT` are standing
overrides; explicit flags win. There is no adapter default for either. With no
value, the CLI's own configuration applies. Effort must be `low`, `medium`,
`high`, `xhigh`, or `max`. `--resume` and `--background` are refused.

## Copy, run, patch, and apply protocol

The adapter snapshots tracked plus untracked non-ignored files into disjoint,
git-less `pristine/` and `work/` copies outside the real repository. It runs
`claude -p` in `work/` with Git environment variables unset, stdin from
`/dev/null`, `--restricted`, a closed tool list, the CLI's OS sandbox with
`failIfUnavailable`, no setting sources, and no MCP servers. It requires one
`system/init` event with the exact granted tools, an empty MCP list, and a
bounded, safe session id before one successful `result` event with the same id
and a UTF-8 result string. A nonzero CLI exit propagates.

After the child exits and the stream validates, the adapter copies `work/` to
`frozen/` and writes `frozen.ok` beside it only after the copy succeeds. Every
later boundary check and the diff read that frozen snapshot. It drops newly
created paths ignored by the **real** repository's rules, then drops new paths
under any `.claude/` component, including the CLI's empty `.cc-writes/` scratch
directory. Both drop counts are reported. It refuses any `.git` component
(case-insensitively), new or changed symlink outside dropped paths, or change
or deletion of an existing path under `.claude/`. A tracked symlink named
`.claude` is an unsupported pre-launch layout. This backend never adds
anything under a `.claude/` directory and refuses to change or delete what
is already there.

`git check-ignore` cannot answer for a path beneath a symlink in the real
worktree, so those paths are never sent to it. When the real symlink is itself
ignored, the directory the agent created in its place is dropped whole and
counted once; the real symlink and its target are untouched. When the agent
replaces a snapshotted symlink with a directory, the paths beneath it are
applied unfiltered and each is reported on stderr as `note: ignore rules not
checked beyond a real-worktree symlink: <path>` (the first 20, then a count).
A new symlink among them is still refused.

In implement mode, `git diff --no-index --binary --no-renames` creates one raw
`changes.patch` from `pristine/` to `frozen/`. The adapter checks it with
`git apply -p2 --check --binary --whitespace=nowarn`, then applies it with
`git apply -p2 --binary --whitespace=nowarn` under the umask the adapter was
invoked with. The adapter itself runs under `umask 077` so the copies and run
state stay private, and Claude edits the work copy under that private mask,
but a patch carries only Git's 100644 and 100755 modes, so a new file or
directory reaches the real worktree as 0666 or 0777 masked by the caller's
umask: 0644 and 0755 under 022, 0640 and 0750 under 027, exactly what a
`git apply` from the engineer's shell would create. The summary line
`worktree umask:` discloses that mask. An earlier version applied under a
fixed 022, which gave a caller with a stricter mask looser files than its own
shell would. The shared outcome is the `worktree-umask` rule in
[dispatch-contract.md](../../references/dispatch-contract.md). The whitespace
flag overrides a configured `apply.whitespace`, which would otherwise rewrite
or refuse the agent's lines. There is no patch rewrite. It never
stages or commits. An empty patch succeeds. Failures keep the state and
copies. Successful dispatches clean the copies unless
`CLAUDE_LOOP_KEEP_COPIES=1` is set.

## State artifacts

State is `<git-common-dir>/olddonkey-loop/claude/<dispatch-id>/`. The copy root
is `${CLAUDE_LOOP_WORK_ROOT:-$HOME/.config/olddonkey-loop/claude-work}/<dispatch-id>/`
with `pristine/`, `work/`, and, after launch, `frozen/` and the
`frozen.ok` completion marker. The marker is part of the disposable copy
root, not the protected state directory.
State includes `project-files.zlist`, `prompt.txt`, `stream.jsonl`,
`stderr.log`, and, after a valid result, `last-message.txt`. Implement mode
also records `changes.patch`; a nonempty checked patch
records apply logs. See the [state schema](../../references/state-schema.md).
`dispatch.start` is appended after the copies exist and before launch;
`dispatch.end` is appended by the exit trap.

## Read-only mode

`--read-only` and `--investigate` grant only `Read Glob Grep`, use
`--permission-mode default`, and build no patch. The prompt asks for an
argument or plan. The real worktree remains unchanged even if the agent
writes to its disposable copy. Iterate with a fresh dispatch and a new prompt.

## Boundary and limits

The tool restriction and Bash sandbox are enforced by the Claude CLI. The
adapter checks the CLI-reported granted tool list **after** the run; that
check is detection, not containment. The adapter does not itself sandbox the
child. The real worktree is outside the child CWD, and the dispatcher applies
only a captured, validated patch. The coordinator still owns diff review,
gates, commit, and publication. A stub selftest validates the adapter's
protocol; real CLI containment requires the opt-in
[integration gate](../../tests/integration-test.sh).

The summary's `applied: yes` means the apply command was invoked. Exit 13 can
follow a partly applied patch; exit 14 occurs when copy cleanup fails after
a successful dispatch, including one that fully applied a nonempty patch. A
nonzero exit is therefore not evidence that the real worktree was untouched. Review the real diff and retained state on either exit.
