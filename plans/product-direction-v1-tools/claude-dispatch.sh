#!/usr/bin/env bash
# Sandboxed Claude Code implementer dispatch, modelled on backends/cursor:
# git-less copy -> claude -p inside Claude Code's OS sandbox -> patch -> apply.
# Usage: claude-dispatch.sh <tag> <prompt-file> <real-worktree> [model] [effort]
# Never stages, commits, or pushes. Exit: 0 applied, 1 agent error/malformed
# result, 2 usage, 3 boundary, 4 patch. On any nonzero exit the real worktree
# is untouched and copies are retained for forensics.
# Test seam: CLAUDE_DISPATCH_TEST=1 honours CLAUDE_BIN and CLAUDE_DISPATCH_ROOT.
set -euo pipefail
umask 077
TAG="${1:-}"; PROMPT_FILE="${2:-}"; REAL="${3:-}"; MODEL="${4:-claude-opus-5-5}"; EFFORT="${5:-xhigh}"
[[ "$TAG" =~ ^[a-z0-9][a-z0-9.-]{0,40}$ && "$TAG" != *..* ]] || { echo "usage: invalid tag" >&2; exit 2; }
[[ -f "$PROMPT_FILE" && -d "$REAL" ]] || { echo "usage: prompt file and real worktree required" >&2; exit 2; }
[[ "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]] || { echo "usage: invalid effort" >&2; exit 2; }
CLAUDE_BIN_DEFAULT="$HOME/.local/bin/claude"
ROOT_DEFAULT="$HOME/.config/olddonkey-loop/opus-work"
if [[ "${CLAUDE_DISPATCH_TEST:-}" == 1 ]]; then
  CLAUDE_BIN="${CLAUDE_BIN:-$CLAUDE_BIN_DEFAULT}"; ROOT="${CLAUDE_DISPATCH_ROOT:-$ROOT_DEFAULT}"
else
  CLAUDE_BIN="$CLAUDE_BIN_DEFAULT"; ROOT="$ROOT_DEFAULT"
fi
REAL="$(cd "$REAL" && pwd -P)"
[[ "$(git -C "$REAL" rev-parse --show-toplevel 2>/dev/null)" == "$REAL" ]] || { echo "usage: real worktree must be a repo root" >&2; exit 2; }
# Protected root: real directory, owned by us, private, no symlink. Every
# check that can refuse runs BEFORE anything is created or chmod-ed.
if [[ -L "$ROOT" ]]; then echo "boundary: root is a symlink" >&2; exit 3; fi
ROOT_PARENT="$(dirname "$ROOT")"
[[ -d "$ROOT_PARENT" && ! -L "$ROOT_PARENT" ]] || { echo "usage: root parent $ROOT_PARENT must be an existing directory" >&2; exit 2; }
ROOT_REAL="$(cd "$ROOT_PARENT" && pwd -P)/$(basename "$ROOT")"
case "$ROOT_REAL/" in "$REAL/"*) echo "boundary: root inside the real worktree" >&2; exit 3;; esac
case "$REAL/" in "$ROOT_REAL/"*) echo "boundary: real worktree inside the root" >&2; exit 3;; esac
if [[ -e "$ROOT_REAL" ]]; then
  [[ -d "$ROOT_REAL" && -O "$ROOT_REAL" ]] || { echo "boundary: root not a directory owned by $USER" >&2; exit 3; }
else
  mkdir "$ROOT_REAL"
fi
chmod 700 "$ROOT_REAL"
B="$ROOT_REAL/$TAG"
mkdir "$B" 2>/dev/null || { echo "usage: $B already exists (tags are single-use)" >&2; exit 2; }
[[ "$(cd "$B" && pwd -P)" == "$B" ]] || { echo "boundary: tag path escapes the root" >&2; exit 3; }
mkdir "$B/pristine"
(cd "$REAL" && git ls-files -z --cached --others --exclude-standard | cpio -0pdm "$B/pristine" 2>/dev/null)
cp -R "$B/pristine" "$B/work"
for d in pristine work; do
  [[ -z "$(find "$B/$d" -name .git -print -quit)" ]] || { echo "boundary: .git entry in $d" >&2; exit 3; }
  if (cd "$B/$d" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git rev-parse --show-toplevel >/dev/null 2>&1); then
    echo "boundary: $d is inside a git repository" >&2; exit 3
  fi
  [[ -z "$(find "$B/$d" -type l -print -quit)" ]] || { echo "boundary: symlink in $d" >&2; exit 3; }
done
TOOLS=(Bash Read Edit Write Glob Grep)
# Project settings are never loaded (--setting-sources ""), so a tracked or
# agent-written .claude/settings*.json cannot add hooks, permissions, or paths.
SETTINGS='{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false,"network":{"allowLocalBinding":true}},"permissions":{"deny":["WebFetch","WebSearch"]}}'
PROMPT="$(cat "$PROMPT_FILE")"
printf 'claude dispatch summary:\ntag: %s\nmodel: %s (explicit)\neffort: %s (explicit)\nreal worktree: %s\nwork copy: %s\nboundary: git-less copy (mode 0700 root); --restricted (file tools confined to the copy, settings/git/tool-config writes need a person); tools exactly Bash Read Edit Write Glob Grep; OS sandbox for Bash with failIfUnavailable (writes confined to the copy and temp, egress denied, unsandboxed escape disabled); permission prompts: none (auto-deny); Chrome off; setting sources: none; MCP: none; init tool list verified after the run; not a registered loop backend (no dispatch.* journal events)\n' \
  "$TAG" "$MODEL" "$EFFORT" "$REAL" "$B/work"
set +e
(cd "$B/work" && "$CLAUDE_BIN" -p --model "$MODEL" --effort "$EFFORT" \
  --restricted --tools "${TOOLS[@]}" \
  --permission-mode acceptEdits --permission-prompts none --no-chrome \
  --setting-sources "" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings "$SETTINGS" \
  --disallowedTools WebFetch WebSearch Task Agent \
  --no-session-persistence --output-format stream-json --verbose "$PROMPT" \
  > "$B/stream.jsonl" 2> "$B/stderr.log" < /dev/null)
RC=$?
set -e
echo "claude exit: $RC"
# Tool surface actually granted, as reported by the CLI's own init event:
# exactly the allowlist, no MCP server. Any mismatch is a boundary failure.
set +e
python3 - "$B/stream.jsonl" "${TOOLS[@]}" <<'PY'
import json,sys
want = sorted(sys.argv[2:]); inits = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    if isinstance(d, dict) and d.get("type") == "system" and d.get("subtype") == "init":
        inits.append(d)
if len(inits) != 1:
    print("boundary: expected one init event, found", len(inits)); sys.exit(3)
tools = inits[0].get("tools"); mcp = inits[0].get("mcp_servers")
print("init tools:", tools, "mcp_servers:", mcp)
if not isinstance(tools, list) or sorted(tools) != want or mcp != []:
    print("boundary: granted tool surface differs from the allowlist"); sys.exit(3)
PY
TRC=$?
set -e
[[ $TRC -eq 0 ]] || { echo "boundary: tool surface check failed; real worktree untouched" >&2; exit 3; }
# Strict result contract: exactly one result event, type=result,
# subtype=success, is_error exactly false, result a string.
if ! python3 - "$B/stream.jsonl" "$B/last-message.txt" <<'PY'
import json,sys
results = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    if isinstance(d, dict) and d.get("type") == "result":
        results.append(d)
if len(results) != 1:
    print("result: expected one result event, found", len(results)); sys.exit(1)
d = results[0]
ok = (d.get("subtype") == "success" and d.get("is_error") is False and isinstance(d.get("result"), str))
print("result: subtype=%r is_error=%r turns=%r cost_usd=%r" % (
    d.get("subtype"), d.get("is_error"), d.get("num_turns"), d.get("total_cost_usd")))
if not ok:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(d["result"])
PY
then
  echo "agent error or malformed result; real worktree untouched; copies retained at $B" >&2; exit 1
fi
[[ $RC -eq 0 ]] || { echo "agent exit $RC; real worktree untouched" >&2; exit 1; }
[[ -z "$(find "$B/work" -name .git -print -quit)" ]] || { echo "boundary: .git appeared in work" >&2; exit 3; }
[[ -z "$(find "$B/work" -type l -print -quit)" ]] || { echo "boundary: symlink appeared in work" >&2; exit 3; }
# .claude/ is harness scratch (and never loaded); keep it out of the patch.
if [[ -e "$B/work/.claude" ]]; then
  find "$B/work/.claude" -name 'settings*.json' -print | sed 's/^/note: agent wrote (not loaded, not applied): /'
  rm -rf "$B/work/.claude"
fi
[[ -e "$B/pristine/.claude" ]] && cp -R "$B/pristine/.claude" "$B/work/.claude"
cd "$B"
set +e
git diff --no-index --binary pristine work > changes.raw.patch; DRC=$?
set -e
[[ $DRC -le 1 ]] || { echo "patch: diff failed" >&2; exit 4; }
python3 - "$B/changes.raw.patch" "$B/changes.patch" <<'PY'
import sys,re
out=[]
for line in open(sys.argv[1],'rb').read().decode('utf-8','surrogateescape').splitlines(True):
    line=re.sub(r'^(diff --git )a/pristine/(\S+) b/work/(\S+)', r'\1a/\2 b/\3', line)
    line=re.sub(r'^--- a/pristine/', '--- a/', line)
    line=re.sub(r'^\+\+\+ b/work/', '+++ b/', line)
    out.append(line)
open(sys.argv[2],'wb').write(''.join(out).encode('utf-8','surrogateescape'))
PY
N=$(grep -c '^diff --git ' changes.patch || true)
echo "patch: $B/changes.patch ($N files)"
[[ "$N" -gt 0 ]] || { echo "patch: empty" >&2; exit 4; }
cd "$REAL"
# The private umask protects the copies; the real worktree must get normal
# modes (git apply creates rewritten files through the process umask, and a
# 0600/0700 file breaks the Cursor package inventory check).
umask 022
git apply --check --binary "$B/changes.patch" || { echo "patch: apply --check failed; real worktree untouched" >&2; exit 4; }
git apply --binary "$B/changes.patch"
git status --short
