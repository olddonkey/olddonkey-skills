#!/usr/bin/env bash
# Host replica of .github/workflows/selftest.yml (scripts job + tree-oid job).
# Run from the repo root. Extracts every `run:` step from the workflow so the
# gate cannot drift from CI; each step runs in a fresh bash with -e semantics
# like GitHub Actions. Exit 0 only if every step exits 0.
set -uo pipefail
ROOT="$(pwd -P)"
WF="$ROOT/.github/workflows/selftest.yml"
LOGDIR="${CI_GATE_LOGDIR:-$(mktemp -d)}"
mkdir -p "$LOGDIR"
python3 - "$WF" "$LOGDIR" <<'PY'
import sys, re, os
wf, logdir = sys.argv[1], sys.argv[2]
lines = open(wf, encoding="utf-8").read().splitlines()
steps = []
i = 0
name = None
while i < len(lines):
    line = lines[i]
    m = re.match(r"^(\s*)- name: (.*)$", line)
    if m:
        name = m.group(2).strip()
    m = re.match(r"^(\s*)run: (.*)$", line)
    if m:
        indent = len(m.group(1))
        rest = m.group(2)
        if rest.strip() == "|":
            body = []
            i += 1
            while i < len(lines):
                l = lines[i]
                if l.strip() == "":
                    body.append("")
                    i += 1
                    continue
                if len(l) - len(l.lstrip()) <= indent:
                    break
                body.append(l[indent + 2:])
                i += 1
            steps.append((name, "\n".join(body)))
            continue
        else:
            steps.append((name, rest))
    i += 1
for n, (nm, body) in enumerate(steps, 1):
    with open(os.path.join(logdir, f"step{n:02d}.sh"), "w", encoding="utf-8") as f:
        f.write(body + "\n")
    with open(os.path.join(logdir, f"step{n:02d}.name"), "w", encoding="utf-8") as f:
        f.write(nm or f"step {n}")
PY
fail=0
total=0
for script in "$LOGDIR"/step*.sh; do
  base="${script%.sh}"
  nm="$(cat "$base.name")"
  total=$((total + 1))
  start=$(date +%s)
  if bash -e "$script" > "$base.log" 2>&1; then
    printf 'STEP PASS (%3ss) %s\n' "$(( $(date +%s) - start ))" "$nm"
  else
    rc=$?
    printf 'STEP FAIL (%3ss) rc=%s %s  [log: %s]\n' "$(( $(date +%s) - start ))" "$rc" "$nm" "$base.log"
    tail -15 "$base.log" | sed 's/^/    | /'
    fail=$((fail + 1))
  fi
  # surface each selftest's own summary line
  grep -h -E 'selftest: (PASS|FAIL)|^# (pass|fail)|[0-9]+ passed|checks\)' "$base.log" | tail -3 | sed 's/^/    = /'
done
printf 'CI-GATE: %d steps, %d failed (logs: %s)\n' "$total" "$fail" "$LOGDIR"
[[ "$fail" -eq 0 ]]
