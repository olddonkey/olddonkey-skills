#!/usr/bin/env bash
# Selftest for claude-dispatch.sh using a stub claude binary that emits the
# stream-json shape (one init event, one result event). Every refusal case
# asserts the real worktree is untouched; pre-launch refusals also assert the
# stub never started.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
D="$HERE/claude-dispatch.sh"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
REPO="$T/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; echo base > "$REPO/file.txt"
git -C "$REPO" add file.txt; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
echo "prompt" > "$T/prompt.txt"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok - $1"; }
bad(){ fail=$((fail+1)); echo "not ok - $1"; }
INIT_OK='{"type":"system","subtype":"init","tools":["Bash","Read","Edit","Write","Glob","Grep"],"mcp_servers":[]}'
RES_OK='{"type":"result","subtype":"success","is_error":false,"result":"done","num_turns":1}'
mkstub(){ # $1=name $2=init line $3=result line $4=optional shell to run in cwd
  cat > "$T/$1" <<EOF
#!/usr/bin/env bash
touch "$T/started.$1"
${4:-true}
printf '%s\n' '$2'
printf '%s\n' '$3'
EOF
  chmod +x "$T/$1"; }
untouched(){ [[ -z "$(git -C "$REPO" status --porcelain)" && "$(cat "$REPO/file.txt")" == base ]]; }
started(){ [[ -e "$T/started.$1" ]]; }
run(){ # $1=tag $2=stub [$3=root] [$4=repo]
  CLAUDE_DISPATCH_TEST=1 CLAUDE_BIN="$T/$2" CLAUDE_DISPATCH_ROOT="${3:-$T/root}" bash "$D" "$1" "$T/prompt.txt" "${4:-$REPO}" >"$T/out.$(printf '%s' "$1$2" | shasum | cut -c1-8)" 2>&1; echo $?; }

mkstub edits "$INIT_OK" "$RES_OK" 'echo changed > file.txt'

# Malformed or failed results: exit 1, worktree untouched.
i=0
for res in 'not json at all' \
  '{"type":"result","subtype":"success","is_error":null,"result":"x"}' \
  '{"type":"result","subtype":"success","is_error":"false","result":"x"}' \
  '{"type":"result","subtype":"success","result":"x"}' \
  '{"type":"result","subtype":"success","is_error":true,"result":"x"}' \
  '{"type":"result","subtype":"error_max_turns","is_error":false,"result":"x"}' \
  '{"type":"result","subtype":"success","is_error":false}' \
  '[1,2]'; do
  i=$((i+1)); mkstub "m$i" "$INIT_OK" "$res" 'echo changed > file.txt'
  rc=$(run "t-m$i" "m$i"); if [[ "$rc" == 1 ]] && untouched; then ok "malformed result #$i -> exit 1, untouched"; else bad "malformed #$i rc=$rc"; fi
done

# Tool surface: wrong tools, extra MCP server, missing or duplicate init -> exit 3.
mkstub w1 '{"type":"system","subtype":"init","tools":["Bash","Read","Edit","Write","Glob","Grep","WebFetch"],"mcp_servers":[]}' "$RES_OK" 'echo changed > file.txt'
mkstub w2 '{"type":"system","subtype":"init","tools":["Bash","Read","Edit","Write","Glob","Grep"],"mcp_servers":[{"name":"x","status":"connected"}]}' "$RES_OK" 'echo changed > file.txt'
mkstub w3 '{"type":"system","subtype":"other"}' "$RES_OK" 'echo changed > file.txt'
mkstub w4 '{"type":"system","subtype":"init","tools":["Bash","Read"],"mcp_servers":[]}' "$RES_OK" 'echo changed > file.txt'
for w in w1 w2 w3 w4; do
  rc=$(run "t-$w" "$w"); if [[ "$rc" == 3 ]] && untouched; then ok "tool surface $w -> boundary refusal, untouched"; else bad "tool surface $w rc=$rc"; fi
done

# Tags.
for tag in '../x' 'a/b' '' 'UPPER' '.hidden' 'x..y'; do
  rc=$(run "$tag" edits); if [[ "$rc" == 2 ]] && untouched; then ok "tag '$tag' refused"; else bad "tag '$tag' rc=$rc"; fi
done

# Root boundaries (pre-launch: the stub must never start).
mkstub pre "$INIT_OK" "$RES_OK" 'echo changed > file.txt'
rm -f "$T/started.pre"
rc=$(run t-inside pre "$REPO/.dispatch-root"); if [[ "$rc" == 3 ]] && untouched && ! started pre && [[ ! -e "$REPO/.dispatch-root" ]]; then ok "root inside the real worktree refused before launch and before creating anything"; else bad "root-inside rc=$rc"; fi
rm -rf "$REPO/.dispatch-root"
OUTER="$T/outer"; mkdir -p "$OUTER"; chmod 755 "$OUTER"; git clone -q "$REPO" "$OUTER/inner" 2>/dev/null
rc=$(run t-contains pre "$OUTER" "$OUTER/inner"); omode=$(stat -f '%Lp' "$OUTER")
if [[ "$rc" == 3 ]] && ! started pre && [[ "$omode" == 755 && ! -e "$OUTER/t-contains" ]]; then ok "real worktree inside the root refused before launch, root mode unchanged"; else bad "root-contains rc=$rc mode=$omode"; fi
mkdir -p "$T/realroot"; chmod 755 "$T/realroot"; ln -s "$T/realroot" "$T/linkroot"
rc=$(run t-link pre "$T/linkroot"); lmode=$(stat -f '%Lp' "$T/realroot")
if [[ "$rc" == 3 ]] && untouched && ! started pre && [[ "$lmode" == 755 && -z "$(ls -A "$T/realroot")" ]]; then ok "symlinked root refused before launch, target untouched"; else bad "symlink-root rc=$rc mode=$lmode"; fi
ln -s /etc/hosts "$REPO/evil-link"
rc=$(run t-pristine-link pre); if [[ "$rc" == 3 ]] && ! started pre; then ok "symlink in the pristine snapshot refused before launch"; else bad "pristine-symlink rc=$rc"; fi
rm -f "$REPO/evil-link"

# Success, reuse, modes.
rc=$(run good edits); if [[ "$rc" == 0 && "$(cat "$REPO/file.txt")" == changed ]]; then ok "good result applies the patch"; else bad "good rc=$rc"; fi
fmode=$(stat -f '%Lp' "$REPO/file.txt"); [[ "$fmode" == 644 ]] && ok "applied file keeps a normal mode (644), not the private umask" || bad "applied file mode $fmode"
git -C "$REPO" checkout -q -- file.txt
rc=$(run good edits); if [[ "$rc" == 2 ]] && untouched; then ok "reused tag refused"; else bad "reused tag rc=$rc"; fi
mode=$(stat -f '%Lp' "$T/root/good"); [[ "$mode" == 700 ]] && ok "copy dir mode 0700" || bad "copy dir mode $mode"
rmode=$(stat -f '%Lp' "$T/root"); [[ "$rmode" == 700 ]] && ok "root mode 0700" || bad "root mode $rmode"

# New and deleted files survive the patch normalisation.
echo gone > "$REPO/old.txt"; git -C "$REPO" add old.txt; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm old
mkstub newdel "$INIT_OK" "$RES_OK" 'mkdir -p sub && printf "new\n" > sub/new.sh && chmod 755 sub/new.sh && rm -f old.txt'
rc=$(run t-newdel newdel)
if [[ "$rc" == 0 && -f "$REPO/sub/new.sh" && ! -e "$REPO/old.txt" && "$(stat -f '%Lp' "$REPO/sub/new.sh")" == 755 ]]; then ok "a new executable file and a deleted file apply"; else bad "new/deleted rc=$rc"; cat "$T"/out.* | tail -5; fi
git -C "$REPO" checkout -q -- old.txt 2>/dev/null; rm -rf "$REPO/sub"

# Post-run boundary refusals.
mkstub gitdir "$INIT_OK" "$RES_OK" 'mkdir -p .git'
rc=$(run t-gitdir gitdir); if [[ "$rc" == 3 ]] && untouched; then ok ".git appearing in work -> refusal"; else bad "gitdir rc=$rc"; fi
mkstub symlink "$INIT_OK" "$RES_OK" 'ln -s /etc/hosts evil'
rc=$(run t-symlink symlink); if [[ "$rc" == 3 ]] && untouched; then ok "symlink appearing in work -> refusal"; else bad "symlink rc=$rc"; fi
mkstub settings "$INIT_OK" "$RES_OK" 'mkdir -p .claude && echo "{}" > .claude/settings.json && echo changed > file.txt'
rc=$(run t-settings settings); if [[ "$rc" == 0 ]] && ! git -C "$REPO" status --porcelain | grep -q .claude; then ok "agent-written .claude/settings.json kept out of the patch"; else bad "settings rc=$rc"; fi
git -C "$REPO" checkout -q -- file.txt

# argv contract.
mkstub args "$INIT_OK" "$RES_OK" 'printf "%s\n" "$@" > "$0.argv"'
run t-args args >/dev/null
A="$T/args.argv"
argv_has(){ grep -qx -- "$1" "$A"; }
argv_after(){ grep -A1 -x -- "$1" "$A" | sed -n 2p; }
if argv_has --restricted && argv_has --no-chrome && [[ "$(argv_after --permission-prompts)" == none ]] \
   && argv_has --setting-sources && [[ "$(argv_after --setting-sources)" == "" ]] \
   && [[ "$(argv_after --tools)" == Bash ]] && argv_has Grep && argv_has --strict-mcp-config \
   && grep -q '"failIfUnavailable":true' "$A" && grep -q '"allowUnsandboxedCommands":false' "$A"; then
  ok "argv: restricted, tools allowlist, no chrome, prompts none, empty setting sources, sandbox fail-closed"
else bad "argv"; cat "$A"; fi
echo "claude-dispatch-selftest: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
