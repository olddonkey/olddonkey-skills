#!/usr/bin/env bash
# Hermetic PATH-stub regression harness for the Claude Code backend.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
TMP_ROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/claude-selftest.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT_RAW" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
CHECKS=0
FAILURES=0
pass() { CHECKS=$((CHECKS + 1)); printf 'ok %d - %s\n' "$CHECKS" "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2; }
check() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  elif [[ "$1" == status_is ]]; then
    fail "$description (status $STATUS, expected $2)"
  else
    fail "$description"
  fi
}
status_is() { [[ "$STATUS" -eq "$1" ]]; }
contains() { grep -Fq -- "$1" "$2"; }
missing() { [[ ! -e "$1" && ! -L "$1" ]]; }
summary() { sed -n "s/^$1: //p" "$OUT" | tail -1; }
clean_repo() {
  [[ "$(git -C "$REPO" status --porcelain --ignored)" == "$BASE_STATUS" ]] &&
    cmp -s "$REPO/tracked.txt" "$BASE_TRACKED"
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf 'stdin sentinel: the adapter must replace this with /dev/null\n' > "$TMP_ROOT/adapter-input"
cat > "$BIN/claude" <<'PY_STUB'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

if sys.argv[1:] == ["--version"]:
    print("claude 2.1.285-stub")
    raise SystemExit(0)
argv = sys.argv[1:]
work = Path.cwd()
record = Path(os.environ["CLAUDE_STUB_LOG"])
probe = subprocess.run(["git", "-C", str(work), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
stdin = os.fstat(0)
null = os.stat(os.devnull)
record.write_text(json.dumps({
    "argv": argv, "cwd": str(work), "git_top": probe.stdout.strip(),
    "stdin_devnull": (stdin.st_dev, stdin.st_ino) == (null.st_dev, null.st_ino),
}) + "\n")
mode = "read-only" if argv[argv.index("--tools") + 1:argv.index("--permission-mode")] == ["Read", "Glob", "Grep"] else "implement"
(action, variant) = (os.environ.get("CLAUDE_STUB_ACTION", "none"), os.environ.get("CLAUDE_STUB_VARIANT", "normal"))
if action == "edit":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / "added.txt").write_text("added-by-claude\n")
    (work / "delete-me.txt").unlink()
elif action == "complex":
    (work / "rename-old.txt").rename(work / "rename-new.txt")
    (work / "lib/a/work/f.txt").write_text("nested-work-changed\n")
    (work / "work/nested.txt").write_text("top-work-changed\n")
    (work / "pristine/nested.txt").write_text("top-pristine-changed\n")
    (work / "a space.txt").write_text("space-changed\n")
    (work / "hunk.txt").write_text("++ see b/work/notes\n")
    (work / "binary.bin").write_bytes(bytes([0, 255, 17, 18, 0]))
    (work / "mode.sh").chmod(0o755)
    (work / "added.txt").write_text("new mode check\n")
elif action == "readonly-edit":
    (work / "tracked.txt").write_text("copy-only\n")
elif action == "git-file":
    (work / ".git").write_text("forbidden")
elif action == "git-dir":
    (work / ".git").mkdir()
elif action == "git-mixed":
    (work / ".GIT").mkdir()
    (work / ".GIT" / "config").write_text("forbidden")
elif action == "link-new":
    (work / "new-link").symlink_to("tracked.txt")
elif action == "link-dir":
    (work / "new-dir-link").symlink_to(".", target_is_directory=True)
elif action == "link-change":
    (work / "tracked-link").unlink()
    (work / "tracked-link").symlink_to("delete-me.txt")
elif action == "settings":
    (work / ".claude").mkdir(exist_ok=True)
    (work / ".claude" / "settings.json").write_text('{"hooks":{}}')
elif action == "claude-tracked":
    (work / ".claude" / "commands" / "deploy.md").write_text("changed\n")
elif action == "claude-added":
    path = work / ".claude" / "skills" / "x"
    path.mkdir(parents=True)
    (path / "SKILL.md").write_text("new skill\n")
elif action == "claude-nested":
    path = work / "pkg" / ".claude"
    path.mkdir(parents=True)
    (path / "settings.json").write_text("{}\n")
elif action == "claude-delete":
    (work / ".claude" / "delete.md").unlink()
elif action == "claude-mode":
    (work / ".claude" / "commands" / "deploy.md").chmod(0o755)
elif action == "claude-cc-writes":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / ".claude" / ".cc-writes").mkdir(parents=True)
elif action == "claude-mixed":
    path = work / ".ClAuDe"
    path.mkdir()
    (path / "file").write_text("mixed case\n")
elif action == "claude-link":
    (work / ".claude").symlink_to("tracked.txt")
elif action == "ignored":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / ".env").write_text("secret\n")
    cache = work / "__pycache__"
    cache.mkdir()
    (cache / "x.pyc").write_bytes(b"cache")
    (cache / "link").symlink_to("../tracked.txt")
    (work / "ignored.txt").write_text("agent ignored change\n")
elif action == "ignored-symlink":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / "cache" / "deep").mkdir(parents=True)
    (work / "cache" / "deep" / "out.o").write_text("built\n")
elif action in ("symlink-to-dir", "symlink-to-dir-link"):
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / "dirlink").unlink()
    (work / "dirlink").mkdir()
    (work / "dirlink" / "new.txt").write_text("beyond-the-real-symlink\n")
    if action == "symlink-to-dir-link":
        (work / "dirlink" / "inner-link").symlink_to("new.txt")
elif action == "trailing-space":
    (work / "tracked.txt").write_text("base\nclaude-change  \t\n\n\n")
    (work / "added.txt").write_text("added-by-claude \n\n")
elif action == "unreadable":
    path = work / "unreadable"
    path.mkdir()
    (path / "file").write_text("cannot copy\n")
    path.chmod(0)
elif action == "fifo":
    os.mkfifo(work / "pipe")
elif action == "cleanup-lock":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    (work / "locked").chmod(0o500)
elif action == "late-write":
    import subprocess as sp
    watcher = r"""
import pathlib, sys, time
work = pathlib.Path(sys.argv[1])
marker = pathlib.Path(sys.argv[2])
frozen_ok = work.parent / 'frozen.ok'
for _ in range(1000):
    if frozen_ok.exists():
        (work / 'tracked.txt').write_text('late-write\n')
        marker.write_text('done\n')
        break
    time.sleep(0.01)
"""
    sp.Popen([sys.executable, "-c", watcher, str(work), os.environ["CLAUDE_LATE_MARKER"]],
             stdin=sp.DEVNULL, stdout=sp.DEVNULL, stderr=sp.DEVNULL, start_new_session=True)
elif action == "diverge":
    (work / "tracked.txt").write_text("base\nclaude-change\n")
    Path(os.environ["CLAUDE_REAL_REPO"]).joinpath("tracked.txt").write_text("base\nreal-divergence\n")

allowed = argv[argv.index("--tools") + 1:argv.index("--permission-mode")]
init = {"type": "system", "subtype": "init", "tools": allowed, "mcp_servers": [], "session_id": "session-123"}
result = {"type": "result", "subtype": "success", "is_error": False, "result": "stub complete", "session_id": "session-123"}
if variant == "extra-tool": init["tools"] = allowed + ["WebFetch"]
if variant == "missing-tool": init["tools"] = allowed[:-1]
if variant == "tool-space": init["tools"] = allowed[:-1] + ["Bad Tool"]
if variant == "mcp": init["mcp_servers"] = [{"name": "poison"}]
if variant == "missing-session":
    del init["session_id"]
    del result["session_id"]
if variant == "empty-session": init["session_id"] = result["session_id"] = ""
if variant == "session-newline": init["session_id"] = result["session_id"] = "bad\nid"
if variant == "different-session": result["session_id"] = "other-session"
if variant == "subtype": result["subtype"] = "error"
if variant == "is-error": result["is_error"] = True
if variant == "bad-result": result["result"] = {"text": "not string"}
if variant == "surrogate": result["result"] = "\ud800"
if variant == "nonutf8":
    sys.stdout.buffer.write(b"\xff\n")
    sys.stdout.flush()
    raise SystemExit(0)
if variant == "nonjson": print("not-json")
if variant == "blank-line": print("")
if variant == "result-before-init": print(json.dumps(result))
if variant != "zero-init": print(json.dumps(init))
if variant == "two-init": print(json.dumps(init))
if variant not in ("zero-result", "result-before-init"): print(json.dumps(result))
if variant == "two-result": print(json.dumps(result))
if variant == "exit-7": raise SystemExit(7)
if variant == "signal":
    sys.stdout.flush()
    os.kill(os.getpid(), signal.SIGTERM)
PY_STUB
chmod 755 "$BIN/claude"

init_fixture() {
  local name="$1"
  HOME_FIX="$TMP_ROOT/$name-home"
  REPO="$TMP_ROOT/$name-repo"
  mkdir -p "$HOME_FIX"
  git init -q "$REPO"
  git -C "$REPO" config user.email selftest@example.invalid
  git -C "$REPO" config user.name selftest
  printf 'base\n' > "$REPO/tracked.txt"
  printf 'delete-me\n' > "$REPO/delete-me.txt"
  printf 'ignored.txt\n__pycache__/\n.env\n' > "$REPO/.gitignore"
  ln -s tracked.txt "$REPO/tracked-link"
  git -C "$REPO" add tracked.txt delete-me.txt .gitignore tracked-link
  git -C "$REPO" commit -qm base
  printf 'untracked\n' > "$REPO/untracked.txt"
  printf 'ignored\n' > "$REPO/ignored.txt"
  snapshot_fixture "$name"
}

snapshot_fixture() { # $1=name; refresh after specialized fixture setup
  HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
  BASE_STATUS="$(git -C "$REPO" status --porcelain --ignored)"
  BASE_TRACKED="$TMP_ROOT/$1.tracked.baseline"
  cp "$REPO/tracked.txt" "$BASE_TRACKED"
}

invoke() { # name action variant flags...
  local name="$1" action="$2" variant="$3"
  shift 3
  OUT="$TMP_ROOT/$name.stdout"
  ERR="$TMP_ROOT/$name.stderr"
  LOG="$TMP_ROOT/$name.argv.json"
  set +e
  env HOME="$HOME_FIX" PATH="$BIN:$PATH" LOOP_JOURNAL="$TMP_ROOT/no-journal" \
    CLAUDE_STUB_LOG="$LOG" CLAUDE_STUB_ACTION="$action" CLAUDE_STUB_VARIANT="$variant" \
    CLAUDE_REAL_REPO="$REPO" CLAUDE_LATE_MARKER="$TMP_ROOT/$name.late-marker" ${INVOKE_ENV[@]+"${INVOKE_ENV[@]}"} \
    bash -c 'umask "$1" && cd "$2" && shift 2 && exec "$@"' _ "$INVOKE_UMASK" "$REPO" "$DISPATCH" --prompt 'bounded fixture change' "$@" \
      < "$TMP_ROOT/adapter-input" > "$OUT" 2> "$ERR"
  STATUS=$?
  set -e
}
INVOKE_ENV=()
# The adapter applies its patch under the caller's umask, so every case pins
# the mask it is called with instead of inheriting the host's.
INVOKE_UMASK=022

# Implement: patch, provenance, exact fixed argv, result, and Git ownership.
init_fixture implement
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke implement edit normal --model claude-stub --effort high
check 'implement succeeds' status_is 0
check 'edit applied' contains claude-change "$REPO/tracked.txt"
check 'addition applied' contains added-by-claude "$REPO/added.txt"
check 'deletion applied' missing "$REPO/delete-me.txt"
check 'HEAD unchanged' test "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE"
check 'nothing staged' git -C "$REPO" diff --cached --quiet
check 'summary before final message' python3 - "$OUT" <<'PY'
import sys
s=open(sys.argv[1]).read()
raise SystemExit(0 if s.index('claude dispatch summary:') < s.index('stub complete') else 1)
PY
STATE="$(summary 'run state')"
COPIES="$(summary 'work copy')"
check 'last message stored exactly' python3 - "$STATE/last-message.txt" <<'PY'
import sys
raise SystemExit(0 if open(sys.argv[1]).read() == 'stub complete' else 1)
PY
check 'copies retained on request' test -d "$COPIES"
check 'run state in git common dir' test "${STATE#"$REPO/.git/olddonkey-loop/claude/"}" != "$STATE"
check 'model flag provenance' contains 'model: claude-stub (explicit)' "$OUT"
check 'effort flag provenance' contains 'effort: high (explicit)' "$OUT"
check 'version reported' contains 'claude version: claude 2.1.285-stub' "$OUT"
check 'init tools reported' contains 'tools granted: Bash Read Edit Write Glob Grep' "$OUT"
check 'session reported' contains 'session id: session-123' "$OUT"
check 'implement patch exists' test -s "$STATE/changes.patch"
check 'successful implement reports applied yes' contains 'applied: yes' "$OUT"
check 'manifest includes tracked and untracked' test -f "$COPIES/untracked.txt"
check 'ignored excluded' missing "$COPIES/ignored.txt"
check 'CLI runs in git-less copy' python3 - "$LOG" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
raise SystemExit(0 if not x['git_top'] and x['cwd'].endswith('/work') else 1)
PY
check 'CLI stdin is /dev/null' python3 - "$LOG" <<'PY'
import json,sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["stdin_devnull"] is True else 1)
PY
check 'full fixed argv and settings' python3 - "$LOG" <<'PY'
import json,sys
argv=json.load(open(sys.argv[1]))['argv']
settings='{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false},"permissions":{"deny":["WebFetch","WebSearch"]}}'
want=['-p','--model','claude-stub','--effort','high','--restricted','--tools','Bash','Read','Edit','Write','Glob','Grep','--permission-mode','acceptEdits','--permission-prompts','none','--no-chrome','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--settings',settings,'--disallowedTools','WebFetch','WebSearch','Task','Agent','--no-session-persistence','--output-format','stream-json','--verbose']
raise SystemExit(0 if argv[:-1] == want and argv[-1].startswith('You are in a git-less copy') and argv[-1].endswith('\n\nbounded fixture change') else 1)
PY

# Raw -p2 patch: names, content, binary bytes, and file modes survive.
init_fixture complex
mkdir -p "$REPO/lib/a/work" "$REPO/work" "$REPO/pristine"
printf 'rename-base\n' > "$REPO/rename-old.txt"
printf 'nested-work-base\n' > "$REPO/lib/a/work/f.txt"
printf 'neighbor-base\n' > "$REPO/lib/a/f.txt"
printf 'top-work-base\n' > "$REPO/work/nested.txt"
printf 'top-pristine-base\n' > "$REPO/pristine/nested.txt"
printf 'space-base\n' > "$REPO/a space.txt"
printf '%s\n' '-- a/work/x' > "$REPO/hunk.txt"
python3 - "$REPO/binary.bin" <<'PY'
import sys
open(sys.argv[1], 'wb').write(bytes([0, 255, 16, 0]))
PY
printf '#!/bin/sh\n' > "$REPO/mode.sh"
chmod 644 "$REPO/mode.sh"
git -C "$REPO" add rename-old.txt lib work pristine 'a space.txt' hunk.txt binary.bin mode.sh
git -C "$REPO" commit -qm complex-base
snapshot_fixture complex
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke complex complex normal
check 'complex raw patch succeeds' status_is 0
check 'rename deletes old path' missing "$REPO/rename-old.txt"
check 'rename creates new path' contains rename-base "$REPO/rename-new.txt"
check 'nested lib/a/work path changed' contains nested-work-changed "$REPO/lib/a/work/f.txt"
check 'neighbor lib/a/f path unchanged' contains neighbor-base "$REPO/lib/a/f.txt"
check 'top-level work path changed' contains top-work-changed "$REPO/work/nested.txt"
check 'top-level pristine path changed' contains top-pristine-changed "$REPO/pristine/nested.txt"
check 'space-containing path changed' contains space-changed "$REPO/a space.txt"
check 'hunk addition arrives unchanged' contains '++ see b/work/notes' "$REPO/hunk.txt"
check 'raw patch preserves deletion content' contains '--- a/work/x' "$(summary 'patch')"
check 'raw patch preserves addition content' contains '+++ see b/work/notes' "$(summary 'patch')"
check 'binary change matches frozen copy' cmp -s "$REPO/binary.bin" "$(summary 'work copy')/../frozen/binary.bin"
check 'mode change reaches 755' python3 - "$REPO/mode.sh" <<'PY'
import os,stat,sys
raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o755 else 1)
PY
check 'new file mode is 644 under caller umask 022' python3 - "$REPO/added.txt" <<'PY'
import os,stat,sys
raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o644 else 1)
PY
check 'single raw patch has no normalized companion' missing "$(summary 'run state')/changes.raw.patch"

# The patch is applied under the caller's umask, not a fixed 022: a caller
# with 027 gets the new file as 0640, as its own shell would create it, while
# the adapter's own run state stays private.
init_fixture umask-027
INVOKE_UMASK=027
invoke umask-027 edit normal
INVOKE_UMASK=022
check 'dispatch under caller umask 027 succeeds' status_is 0
check 'summary discloses caller umask 027 as the worktree umask' contains "worktree umask: 0027 (caller's; the patch is applied under it)" "$OUT"
check 'new file mode is 640 under caller umask 027' python3 - "$REPO/added.txt" <<'PY'
import os,stat,sys
raise SystemExit(0 if stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o640 else 1)
PY
check 'run state stays private under caller umask 027' python3 - "$(summary 'run state')" <<'PY'
import os,stat,sys
root=sys.argv[1]
def mode(path): return stat.S_IMODE(os.lstat(path).st_mode)
ok = mode(root)==0o700 and all(
    mode(os.path.join(root,name)) == (0o700 if os.path.isdir(os.path.join(root,name)) else 0o600)
    for name in os.listdir(root))
raise SystemExit(0 if ok else 1)
PY

# The background child writes only after frozen/untracked.txt appears.
init_fixture late-write
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke late-write late-write normal
check 'late writer dispatch succeeds' status_is 0
wait_late_marker() {
  local n
  for n in {1..120}; do
    [[ ! -f "$TMP_ROOT/late-write.late-marker" ]] || return 0
    sleep 0.1
  done
  echo 'late writer marker never appeared after frozen.ok' >&2
  return 1
}
check 'frozen.ok exists after completed copy' test -f "$(summary 'work copy')/../frozen.ok"
check 'background watcher marker appeared within 12 seconds' wait_late_marker
check 'late content exists only in work copy' contains late-write "$(summary 'work copy')/tracked.txt"
check 'frozen content remained baseline' contains base "$(summary 'work copy')/../frozen/tracked.txt"
check 'late content was not applied' clean_repo
check 'late writer produced empty patch' contains 'files changed: 0' "$OUT"
INVOKE_ENV=()

init_fixture readonly
INVOKE_ENV=()
invoke readonly readonly-edit normal --read-only
check 'read-only succeeds' status_is 0
check 'read-only worktree unchanged' clean_repo
check 'read-only grants only Read Glob Grep and default permission mode' python3 - "$LOG" <<'PY'
import json,sys
argv=json.load(open(sys.argv[1]))['argv']
a=argv.index('--tools'); b=argv.index('--permission-mode')
raise SystemExit(0 if argv[a+1:b]==['Read','Glob','Grep'] and argv[b+1]=='default' else 1)
PY
check 'read-only does not build patch' missing "$(summary 'run state')/changes.patch"
check 'read-only summary has no patch' contains 'patch: <none; read-only mode>' "$OUT"
check 'read-only reports applied no' contains 'applied: no' "$OUT"
check 'default removes copies' missing "$(summary 'work copy')"
check 'absent model uses CLI configuration' contains 'model: <claude CLI configuration> (not overridden)' "$OUT"
check 'absent effort uses CLI configuration' contains 'effort: <claude CLI configuration> (not overridden)' "$OUT"
check 'absent model and effort omit both CLI flags' python3 - "$LOG" <<'PY'
import json,sys
argv=json.load(open(sys.argv[1]))['argv']
raise SystemExit(0 if '--model' not in argv and '--effort' not in argv else 1)
PY

# Each stream boundary failure retains its copies and leaves the worktree alone.
for variant in extra-tool missing-tool tool-space mcp zero-init two-init missing-session empty-session session-newline different-session zero-result two-result result-before-init subtype is-error bad-result surrogate blank-line nonjson nonutf8; do
  init_fixture "stream-$variant"
  invoke "stream-$variant" edit "$variant"
  check "$variant exits 10" status_is 10
  check "$variant leaves worktree unchanged" clean_repo
  check "$variant retains copies" test -d "$(summary 'work copy')"
  check "$variant reports boundary" contains 'boundary:' "$ERR"
  if [[ "$variant" == surrogate ]]; then
    check "surrogate leaves no last-message file" missing "$(summary 'run state')/last-message.txt"
    check "surrogate produces no traceback" bash -c '! grep -Fq Traceback "$1"' _ "$ERR"
  fi
done

init_fixture cli-exit
invoke cli-exit edit exit-7
check 'CLI exit 7 propagates' status_is 7
check 'CLI failure leaves worktree unchanged' clean_repo
check 'CLI failure retains copies' test -d "$(summary 'work copy')"

for action in git-file git-dir git-mixed link-new link-dir link-change; do
  init_fixture "$action"
  invoke "$action" "$action" normal
  check "$action exits 10" status_is 10
  check "$action leaves worktree unchanged" clean_repo
  check "$action retains copies" test -d "$(summary 'work copy')"
done

init_fixture link-unchanged
invoke link-unchanged none normal
check 'unchanged tracked symlink succeeds' status_is 0
check 'unchanged symlink remains in real worktree' test "$(readlink "$REPO/tracked-link")" = tracked.txt

# Ignored additions are filtered using the real repository's ignore rules.
init_fixture ignored
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke ignored ignored normal
check 'ignored additions do not fail dispatch' status_is 0
check 'ordinary edit still applies with ignored additions' contains claude-change "$REPO/tracked.txt"
check 'new .env never reaches real tree' missing "$REPO/.env"
check 'ignored directory and symlink never reach real tree' missing "$REPO/__pycache__"
check 'pre-existing ignored real file remains unchanged' contains ignored "$REPO/ignored.txt"
check 'ignored note names .env' contains 'note: ignored path not applied: .env' "$ERR"
check 'ignored note names ignored symlink' contains 'note: ignored path not applied: __pycache__/link' "$ERR"
check 'ignored summary reports positive count' grep -Eq '^ignored paths dropped: [1-9][0-9]*$' "$OUT"
check 'ignored status entries are unchanged in real repo' python3 - "$BASE_STATUS" "$(git -C "$REPO" status --porcelain --ignored)" <<'PY'
import sys
before, after = sys.argv[1:]
def unmodified(text):
    return [line for line in text.splitlines() if not line.endswith(' tracked.txt')]
raise SystemExit(0 if unmodified(before)==unmodified(after) else 1)
PY
check 'ignored paths are absent in frozen copy' missing "$(summary 'work copy')/../frozen/__pycache__/link"
INVOKE_ENV=()

# git check-ignore dies on a path beyond a symlink in the real worktree, so
# those paths are never sent to it. An ignored symlink the agent shadows with
# a directory is dropped whole, and the real symlink's target stays untouched.
init_fixture ignored-symlink
printf 'cache\n' >> "$REPO/.gitignore"
git -C "$REPO" commit -qam ignore-cache
mkdir "$TMP_ROOT/ignored-symlink-target"
ln -s "$TMP_ROOT/ignored-symlink-target" "$REPO/cache"
snapshot_fixture ignored-symlink
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke ignored-symlink ignored-symlink normal
check 'directory shadowing an ignored real symlink does not fail dispatch' status_is 0
check 'ordinary edit applies beside the shadowed symlink' contains claude-change "$REPO/tracked.txt"
check 'ignored real symlink is untouched' test "$(readlink "$REPO/cache")" = "$TMP_ROOT/ignored-symlink-target"
check 'ignored real symlink target stays empty' test -z "$(ls -A "$TMP_ROOT/ignored-symlink-target")"
check 'shadowing directory is named in a note' grep -Fxq 'note: ignored path not applied: cache' "$ERR"
check 'paths beneath the shadowing directory get no note of their own' bash -c '! grep -Fq cache/deep "$1"' _ "$ERR"
check 'summary counts the shadowing directory once' contains 'ignored paths dropped: 1' "$OUT"
check 'shadowing directory is absent in frozen copy' missing "$(summary 'work copy')/../frozen/cache"
INVOKE_ENV=()

# A tracked symlink the agent replaces with a directory still applies. Ignore
# rules cannot be asked about the paths beneath it, and a note says so. A new
# symlink among those paths is refused like any other.
for action in symlink-to-dir symlink-to-dir-link; do
  init_fixture "$action"
  mkdir "$REPO/realdir"
  printf 'real\n' > "$REPO/realdir/f.txt"
  ln -s realdir "$REPO/dirlink"
  git -C "$REPO" add realdir dirlink
  git -C "$REPO" commit -qm symlink-base
  snapshot_fixture "$action"
  invoke "$action" "$action" normal
  check "$action names the unchecked path in a note" grep -Fxq 'note: ignore rules not checked beyond a real-worktree symlink: dirlink/new.txt' "$ERR"
  check "$action leaves the former symlink target alone" test "$(ls -A "$REPO/realdir")" = f.txt
  if [[ "$action" == symlink-to-dir ]]; then
    check 'tracked symlink replaced by a directory still applies' status_is 0
    check 'replacement directory is not a symlink in the real worktree' test ! -L "$REPO/dirlink"
    check 'file beneath the replacement directory reaches the real worktree' contains beyond-the-real-symlink "$REPO/dirlink/new.txt"
  else
    check 'new symlink beneath a replaced symlink exits 10' status_is 10
    check 'new symlink beneath a replaced symlink is named in the refusal' contains 'boundary: new or changed symlink: dirlink/inner-link' "$ERR"
    check 'new symlink beneath a replaced symlink leaves worktree unchanged' clean_repo
  fi
done

# A configured apply.whitespace must not rewrite the agent's lines on apply.
init_fixture whitespace-fix
git -C "$REPO" config apply.whitespace fix
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke whitespace-fix trailing-space normal
check 'apply.whitespace=fix dispatch succeeds' status_is 0
check 'changed file keeps trailing whitespace and blank lines' cmp -s "$REPO/tracked.txt" "$(summary 'work copy')/../frozen/tracked.txt"
check 'added file keeps trailing whitespace and blank lines' cmp -s "$REPO/added.txt" "$(summary 'work copy')/../frozen/added.txt"
init_fixture whitespace-error
git -C "$REPO" config apply.whitespace error
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke whitespace-error trailing-space normal
check 'apply.whitespace=error does not refuse the patch' status_is 0
check 'apply.whitespace=error still applies the edit unchanged' cmp -s "$REPO/tracked.txt" "$(summary 'work copy')/../frozen/tracked.txt"
INVOKE_ENV=()

# New .claude paths are dropped, while changes to pristine paths refuse.
for action in settings claude-added claude-nested claude-mixed claude-link; do
  init_fixture "$action"
  INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
  invoke "$action" "$action" normal
  case "$action" in
    settings) dropped=.claude/settings.json ; root=.claude ;;
    claude-added) dropped=.claude/skills/x/SKILL.md ; root=.claude ;;
    claude-nested) dropped=pkg/.claude/settings.json ; root=pkg/.claude ;;
    claude-mixed) dropped=.ClAuDe/file ; root=.ClAuDe ;;
    claude-link) dropped=.claude ; root=.claude ;;
  esac
  check "$action new path dispatch succeeds" status_is 0
  check "$action leaves real worktree unchanged" clean_repo
  check "$action note names dropped path" contains "note: new path under .claude/ not applied: $dropped" "$ERR"
  check "$action summary counts one dropped path" contains 'claude-dir paths dropped: 1' "$OUT"
  check "$action path absent in real worktree" missing "$REPO/$root"
  check "$action path absent in frozen copy" missing "$(summary 'work copy')/../frozen/$root"
  check "$action path absent from patch" bash -c '! grep -Fq .claude "$1"' _ "$(summary 'patch')"
done
INVOKE_ENV=()

init_fixture claude-cc-writes
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke claude-cc-writes claude-cc-writes normal
check 'empty .cc-writes scratch beside edit succeeds' status_is 0
check 'ordinary edit beside .cc-writes applies' contains claude-change "$REPO/tracked.txt"
check 'empty .cc-writes counts as one dropped directory' contains 'claude-dir paths dropped: 1' "$OUT"
check 'empty .cc-writes emits directory note' contains 'note: new path under .claude/ not applied: .claude' "$ERR"
check 'empty .cc-writes leaves no real .claude directory' missing "$REPO/.claude"
check 'empty .cc-writes absent from frozen copy' missing "$(summary 'work copy')/../frozen/.claude"
check 'empty .cc-writes absent from patch' bash -c '! grep -Fq .claude "$1"' _ "$(summary 'patch')"
INVOKE_ENV=()

for action in claude-tracked claude-delete claude-mode; do
  init_fixture "$action"
  mkdir -p "$REPO/.claude/commands"
  printf 'base command\n' > "$REPO/.claude/commands/deploy.md"
  printf 'delete this\n' > "$REPO/.claude/delete.md"
  git -C "$REPO" add .claude
  git -C "$REPO" commit -qm claude-base
  snapshot_fixture "$action"
  invoke "$action" "$action" normal
  check "$action exits 10" status_is 10
  check "$action leaves worktree unchanged" clean_repo
  check "$action reports .claude refusal" contains 'boundary: change under .claude/ refused:' "$ERR"
done

init_fixture claude-added-existing
mkdir -p "$REPO/.claude/commands"
printf 'base command\n' > "$REPO/.claude/commands/deploy.md"
git -C "$REPO" add .claude
git -C "$REPO" commit -qm claude-base
snapshot_fixture claude-added-existing
INVOKE_ENV=(CLAUDE_LOOP_KEEP_COPIES=1)
invoke claude-added-existing claude-added normal
check 'new path under existing .claude succeeds' status_is 0
check 'new path under existing .claude is dropped' missing "$REPO/.claude/skills"
check 'existing .claude path remains' contains 'base command' "$REPO/.claude/commands/deploy.md"
check 'new path under existing .claude counts one' contains 'claude-dir paths dropped: 1' "$OUT"
check 'new path under existing .claude has note' contains 'note: new path under .claude/ not applied: .claude/skills/x/SKILL.md' "$ERR"
check 'new path under existing .claude absent from frozen' missing "$(summary 'work copy')/../frozen/.claude/skills"
INVOKE_ENV=()

init_fixture claude-symlink
ln -s tracked.txt "$REPO/.CLAUDE"
git -C "$REPO" add .CLAUDE
git -C "$REPO" commit -qm claude-symlink
snapshot_fixture claude-symlink
invoke claude-symlink none normal
check 'tracked symlink named .claude is refused before launch with exit 5' status_is 5
check 'tracked .claude symlink never launches CLI' missing "$LOG"
check 'tracked .claude symlink refusal names unsupported layout' contains 'unsupported layout' "$ERR"
check 'tracked .claude symlink leaves worktree unchanged' clean_repo

init_fixture empty
invoke empty none normal
check 'empty implement patch succeeds' status_is 0
check 'empty patch reports zero files' contains 'files changed: 0' "$OUT"
check 'empty patch reports applied no' contains 'applied: no' "$OUT"

init_fixture diverge
invoke diverge diverge normal
check 'diverged real worktree exits 12' status_is 12
check 'diverged file retains only external change' contains real-divergence "$REPO/tracked.txt"
check 'diverged file has no agent edit' bash -c '! grep -Fq claude-change "$1"' _ "$REPO/tracked.txt"

# A failed copy, unsupported file, and cleanup failure have distinct exits.
init_fixture overlap
INVOKE_ENV=("CLAUDE_LOOP_WORK_ROOT=$REPO/inside")
invoke overlap none normal
check 'copy root inside real repository is refused' status_is 1
check 'overlap refusal precedes child launch' missing "$LOG"
check 'overlap refusal leaves real tree unchanged' clean_repo

init_fixture ancestor-git
git init -q "$TMP_ROOT/outer-git"
INVOKE_ENV=("CLAUDE_LOOP_WORK_ROOT=$TMP_ROOT/outer-git/copies")
invoke ancestor-git none normal
check 'copy inside another Git repository exits 5' status_is 5
check 'ancestor-Git refusal precedes child launch' missing "$LOG"
check 'ancestor-Git refusal leaves real tree unchanged' clean_repo
INVOKE_ENV=()

init_fixture unreadable
invoke unreadable unreadable normal
check 'unreadable work directory exits 10' status_is 10
check 'unreadable work directory reports boundary' contains 'boundary: could not freeze work copy' "$ERR"
check 'unreadable work directory leaves real tree unchanged' clean_repo
[[ ! -d "$(summary 'work copy')/unreadable" ]] || chmod 700 "$(summary 'work copy')/unreadable"
[[ ! -d "$(summary 'work copy')/../frozen/unreadable" ]] || chmod 700 "$(summary 'work copy')/../frozen/unreadable"

init_fixture fifo
invoke fifo fifo normal
check 'FIFO in work copy exits 11' status_is 11
check 'FIFO is retained in frozen copy' test -p "$(summary 'work copy')/../frozen/pipe"
check 'FIFO leaves real tree unchanged' clean_repo

init_fixture cleanup-fail
mkdir -p "$REPO/locked"
printf 'locked\n' > "$REPO/locked/file"
git -C "$REPO" add locked/file
git -C "$REPO" commit -qm locked-base
snapshot_fixture cleanup-fail
invoke cleanup-fail cleanup-lock normal
check 'cleanup failure after apply exits 14' status_is 14
check 'cleanup failure reports applied yes' contains 'applied: yes' "$OUT"
check 'cleanup failure still applied edit' contains claude-change "$REPO/tracked.txt"
[[ ! -d "$(summary 'work copy')/locked" ]] || chmod 700 "$(summary 'work copy')/locked"
[[ ! -d "$(summary 'work copy')/../frozen/locked" ]] || chmod 700 "$(summary 'work copy')/../frozen/locked"

init_fixture implement-clean
invoke implement-clean edit normal
check 'default implement cleanup succeeds' status_is 0
check 'default implement cleanup removes work and frozen' missing "$(summary 'work copy')"
check 'default implement cleanup removes frozen marker' missing "$(summary 'work copy')/../frozen.ok"
check 'default implement cleanup reports no copies' contains 'copies retained: no' "$OUT"

init_fixture signal
invoke signal none signal
check 'CLI SIGTERM propagates as 143' status_is 143
check 'CLI signal leaves real tree unchanged' clean_repo

# Interface refusals happen before CLI launch.
for spec in resume background unknown effort extra; do
  init_fixture "refuse-$spec"
  case "$spec" in
    resume) invoke "refuse-$spec" none normal --resume session-x ;;
    background) invoke "refuse-$spec" none normal --background ;;
    unknown) invoke "refuse-$spec" none normal --unknown ;;
    effort) invoke "refuse-$spec" none normal --effort invalid ;;
    extra) INVOKE_ENV=(CLAUDE_LOOP_EXTRA_ARGS=--unsafe); invoke "refuse-$spec" none normal; INVOKE_ENV=() ;;
  esac
  check "$spec refused with exit 2" status_is 2
  check "$spec does not launch CLI" missing "$LOG"
done

init_fixture refuse-resume-bare
invoke refuse-resume-bare none normal --resume
check 'bare --resume refused with exit 2' status_is 2
check 'bare --resume does not launch CLI' missing "$LOG"

init_fixture refuse-model-option
INVOKE_ENV=(CLAUDE_LOOP_MODEL=--dangerously-skip-permissions)
invoke refuse-model-option none normal
INVOKE_ENV=()
check 'option-shaped model refused with exit 2' status_is 2
check 'option-shaped model does not launch CLI' missing "$LOG"

init_fixture env-model
INVOKE_ENV=(CLAUDE_LOOP_MODEL=env-model CLAUDE_LOOP_EFFORT=medium)
invoke env-model none normal
check 'environment model provenance' contains 'model: env-model (CLAUDE_LOOP_MODEL)' "$OUT"
check 'environment effort provenance' contains 'effort: medium (CLAUDE_LOOP_EFFORT)' "$OUT"
INVOKE_ENV=()

# Journal fixtures: a refused start, normal ordered pair, and a failing end.
init_fixture journal-refuse
REFUSER="$TMP_ROOT/journal-refuser"
printf '#!/usr/bin/env bash\nexit 6\n' > "$REFUSER"
chmod 755 "$REFUSER"
INVOKE_ENV=("LOOP_JOURNAL=$REFUSER")
invoke journal-refuse edit normal
check 'failed dispatch.start propagates helper exit' status_is 6
check 'failed dispatch.start never launches CLI' missing "$LOG"
check 'failed dispatch.start leaves real worktree alone' clean_repo

init_fixture journal-good
JOURNAL="$SCRIPT_DIR/../../scripts/loop-journal"
env HOME="$HOME_FIX" "$JOURNAL" begin-run --workspace "$REPO" > "$TMP_ROOT/journal-good.begin"
INVOKE_ENV=("LOOP_JOURNAL=$JOURNAL")
invoke journal-good none normal --read-only
check 'journaled read-only succeeds' status_is 0
check 'journal has ordered start/end, mode, exit and session' python3 - "$HOME_FIX" "$REPO" <<'PY'
import hashlib,json,os,sys
home,repo=sys.argv[1:]
key=hashlib.sha256(os.path.realpath(repo).encode()).hexdigest()
root=os.path.join(home,'.config','olddonkey-loop','journal',key,'runs')
events=[json.loads(line) for name in os.listdir(root) for line in open(os.path.join(root,name))]
pair=[e for e in events if e['event'] in ('dispatch.start','dispatch.end')]
raise SystemExit(0 if len(pair)==2 and pair[0]['backend']=='claude' and pair[0]['mode']=='read-only' and pair[1]['exit']==0 and pair[1]['session']=='session-123' and pair[0]['dispatch_id']==pair[1]['dispatch_id'] else 1)
PY

init_fixture journal-end-fail
END_HELPER="$TMP_ROOT/journal-end-fail-helper"
cat > "$END_HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" != "dispatch.end" ]] || exit 8
done
exit 0
EOF_HELPER
chmod 755 "$END_HELPER"
INVOKE_ENV=("LOOP_JOURNAL=$END_HELPER")
invoke journal-end-fail none normal
check 'failed dispatch.end does not change dispatch exit' status_is 0
check 'failed dispatch.end warns' contains 'warning: loop-journal dispatch.end failed' "$ERR"
INVOKE_ENV=()

EXPECTED_CHECKS=307
if [[ $CHECKS -ne $EXPECTED_CHECKS || $FAILURES -ne 0 ]]; then
  printf 'selftest: FAIL (%d/%d checks failed; expected %d checks)\n' "$FAILURES" "$CHECKS" "$EXPECTED_CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
