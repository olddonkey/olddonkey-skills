#!/usr/bin/env bash
# Hermetic regression checks for loop-evidence, the per-unit record card.
# HOME is a scratch directory so the real ~/.config tree is never touched.
# Fixtures come from loop-run and loop-journal append where the validator
# accepts them, and from raw segment lines where it would refuse.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
EVIDENCE="$SCRIPT_DIR/../scripts/loop-evidence"
JOURNAL="$SCRIPT_DIR/../scripts/loop-journal"
RUN="$SCRIPT_DIR/../scripts/loop-run"
GATE="$SCRIPT_DIR/../scripts/run-gate.sh"
TREE_OID="$SCRIPT_DIR/../../engineering-mode/scripts/tree-oid.sh"
SCHEMA="$SCRIPT_DIR/../references/state-schema.md"
SKILL="$SCRIPT_DIR/../SKILL.md"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/evidence-selftest.XXXXXX")" || exit 1
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"

cleanup() {
  local status="$1"
  trap - EXIT HUP INT TERM
  rm -rf -- "$TMP_ROOT" || true
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.config/olddonkey-loop" || exit 1
chmod 700 "$HOME/.config" "$HOME/.config/olddonkey-loop" || exit 1
export LC_ALL=C
# A caller's declared attribution must not leak into fixture events.
unset LOOP_UNIT LOOP_ROUND

CHECKS=0
FAILED_CHECKS=0
CASE_STATUS=0
CASE_STDOUT=""
CASE_STDERR=""
FIXTURE_ERRORS=""
CARDS="$TMP_ROOT/cards"
mkdir -p "$CARDS" || exit 1

SHA_A="0123456789abcdef0123456789abcdef01234567"
SHA_A_UPPER="0123456789ABCDEF0123456789ABCDEF01234567"
SHA_A_SHORT="0123456789abcdef0123456789abcdef0123456"
SHA_B="fedcba9876543210fedcba9876543210fedcba98"

FINAL_GREEN=(--field policy=strict --field purpose=unit-final --field binding=clean
  --field verdict=green --field gate_exit=0 --field totals=exit=0)
FINAL_RED_DIRTY=(--field policy=strict --field purpose=unit-final --field binding=dirty
  --field verdict=red --field gate_exit=1 --field totals=exit=1)
# A legacy gate.result: no verdict and no gate_exit, only the suite's totals.
FINAL_LEGACY=(--field policy=passthrough --field purpose=unit-final --field binding=clean
  --field totals=exit=0)
FOCUSED_GREEN=(--field policy=passthrough --field purpose=focused --field binding=clean
  --field verdict=green --field gate_exit=0 --field totals=exit=0)
FOCUSED_RED=(--field policy=passthrough --field purpose=focused --field binding=clean
  --field verdict=red --field gate_exit=1 --field totals=exit=1)
FOCUSED_UNKNOWN=(--field policy=passthrough --field purpose=focused --field binding=clean
  --field totals=exit=0)

# Expected "strength|attribution" of each row, in card order.
R_DISPATCHES="recorded|declared"
R_REVIEW="recorded|not applicable"
R_FINAL="recorded|declared"
R_NO_FINAL="unknown|none"
R_LATER="recorded|declared"
R_SHAS_MATCH="values match|not applicable"
R_SHAS_UNKNOWN="unknown|not applicable"
R_PUBLISHED="recorded|not applicable"
R_UNPUBLISHED="unknown|not applicable"

# The card checker: parses the markdown table (cells split on unescaped
# pipes) and validates the JSON card's shape and closed value sets.
cat > "$TMP_ROOT/cardcheck.py" <<'PY'
import json
import re
import sys

CAVEAT = (
    "Every row is an unverified entry in the local journal, which any process "
    "running as this user can append to; nothing here meets task-graph-v1 "
    "§3's proof bar."
)
STRENGTHS = ("recorded", "declared", "values match", "unknown")
ATTRIBUTIONS = ("declared", "none", "not applicable")
TOP_KEYS = [
    "schema", "unit", "run", "run_status", "counts_complete", "rows",
    "attribution_unclear", "caveat",
]
ROW_KEYS = {
    "dispatches": ["row", "strength", "attribution", "count", "dispatches"],
    "review": ["row", "strength", "attribution", "rounds", "last_verdict", "reviews"],
    "final_gate": ["row", "strength", "attribution", "gate"],
    "later_adverse_gates": ["row", "strength", "attribution", "gates"],
    "recorded_shas": [
        "row", "strength", "attribution", "comparison", "gate_post_head", "publish_sha",
    ],
    "publication": ["row", "strength", "attribution", "publication"],
}
ROW_LABELS = [
    "dispatches attributed to this unit",
    "review rounds and last recorded verdict",
    "final gate",
    "later adverse gates",
    "recorded SHAs",
    "publication",
]
DISPATCH_KEYS = ["dispatch_id", "backend", "mode", "round", "state", "exit"]
UNCLEAR_KEYS = ["dispatch_id", "backend", "mode", "state", "exit", "unclear"]
GATE_KEYS = ["verdict", "policy", "purpose", "binding", "round", "post_head"]
HEADER = "| row | recorded value | strength | attribution |"
RULE = "| --- | --- | --- | --- |"
CELL_SPLIT = re.compile(r"(?<!\\)\|")
FORBIDDEN = re.compile(r"\b(proven|verified|passed|safe)\b", re.IGNORECASE)


class Bad(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def md_table(path):
    lines = read(path).split("\n")
    if HEADER not in lines:
        raise Bad("no table header")
    start = lines.index(HEADER)
    if lines[start + 1] != RULE:
        raise Bad("no table rule")
    rows = []
    for line in lines[start + 2 :]:
        if line == "":
            break
        if not (line.startswith("| ") and line.endswith(" |")):
            raise Bad(f"malformed table line {line!r}")
        cells = [cell.strip() for cell in CELL_SPLIT.split(line[1:-1])]
        if len(cells) != 4:
            raise Bad(f"{len(cells)} cells in {line!r}")
        rows.append((line, cells))
    labels = [cells[0] for _, cells in rows]
    if labels != ROW_LABELS:
        raise Bad(f"row labels {labels}")
    for line, cells in rows:
        if cells[2] not in STRENGTHS or cells[3] not in ATTRIBUTIONS:
            raise Bad(f"strength/attribution outside the closed sets: {line!r}")
    return rows


def json_card(path):
    text = read(path)
    doc = json.loads(text)
    if not isinstance(doc, dict) or list(doc) != TOP_KEYS:
        raise Bad(f"top-level keys {list(doc) if isinstance(doc, dict) else doc!r}")
    if doc["schema"] != 1 or doc["caveat"] != CAVEAT:
        raise Bad("schema or caveat")
    if type(doc["counts_complete"]) is not bool or not isinstance(doc["run"], str):
        raise Bad("counts_complete or run")
    rows = doc["rows"]
    if [row.get("row") for row in rows] != list(ROW_KEYS):
        raise Bad(f"row ids {[row.get('row') for row in rows]}")
    for row in rows:
        if list(row) != ROW_KEYS[row["row"]]:
            raise Bad(f"row keys {row}")
    seen = {"strength": 0, "attribution": 0}

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in seen:
                    seen[key] += 1
                    allowed = STRENGTHS if key == "strength" else ATTRIBUTIONS
                    if value not in allowed:
                        raise Bad(f"{key}={value!r} is outside the closed set")
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(doc)
    if seen != {"strength": 6, "attribution": 6}:
        raise Bad(f"strength/attribution appear outside the six rows: {seen}")
    by_id = {row["row"]: row for row in rows}
    for item in by_id["dispatches"]["dispatches"]:
        if list(item) != DISPATCH_KEYS:
            raise Bad(f"dispatch keys {item}")
    if by_id["dispatches"]["count"] != len(by_id["dispatches"]["dispatches"]):
        raise Bad("dispatch count")
    gates = list(by_id["later_adverse_gates"]["gates"])
    if by_id["final_gate"]["gate"] is not None:
        gates.append(by_id["final_gate"]["gate"])
    for gate in gates:
        if list(gate) != GATE_KEYS or gate["verdict"] not in ("green", "red", "unknown"):
            raise Bad(f"gate {gate}")
    for gate in by_id["later_adverse_gates"]["gates"]:
        if gate["verdict"] not in ("red", "unknown"):
            raise Bad(f"later gate is not adverse: {gate}")
    if by_id["recorded_shas"]["comparison"] not in (
        "values match", "recorded SHAs differ", "cannot compare"
    ):
        raise Bad("comparison")
    for item in doc["attribution_unclear"]:
        if list(item) != UNCLEAR_KEYS or item["unclear"] not in ("conflict", "partial"):
            raise Bad(f"unclear item {item}")
    return doc


def main(argv):
    command, path = argv[0], argv[1]
    if command == "rows":
        if path.endswith(".json"):
            doc = json_card(path)
            pairs = [(row["strength"], row["attribution"]) for row in doc["rows"]]
        else:
            pairs = [(cells[2], cells[3]) for _, cells in md_table(path)]
        print("\n".join(f"{strength}|{attribution}" for strength, attribution in pairs))
    elif command == "line":
        index = ROW_LABELS.index(argv[2])
        print(md_table(path)[index][0])
    elif command == "nth":
        print(read(path).split("\n")[int(argv[2])])
    elif command == "items":
        print("\n".join(line for line in read(path).split("\n") if line.startswith("- ")))
    elif command == "get":
        node = json_card(path)
        for part in argv[2].split("."):
            node = node[int(part)] if isinstance(node, list) else node[part]
        print(json.dumps(node, ensure_ascii=True))
    elif command == "tail":
        text = read(path)
        if not text.endswith("\n") or text.split("\n")[-2] != CAVEAT:
            raise Bad("the card does not end with the fixed sentence")
        if text.count(CAVEAT) != 1:
            raise Bad("the fixed sentence is not printed exactly once")
    elif command == "roundtrip":
        text = read(path)
        if json.dumps(json.loads(text), ensure_ascii=True, indent=2) + "\n" != text:
            raise Bad("json does not round-trip")
    elif command == "words":
        for name in argv[1:]:
            match = FORBIDDEN.search(read(name))
            if match:
                raise Bad(f"{name}: {match.group(0)!r}")
    elif command == "same":
        md = [(cells[2], cells[3]) for _, cells in md_table(path)]
        doc = json_card(argv[2])
        if md != [(row["strength"], row["attribution"]) for row in doc["rows"]]:
            raise Bad("markdown and json rows differ")
    else:
        raise Bad(f"unknown command {command}")


try:
    main(sys.argv[1:])
except (Bad, ValueError, KeyError, IndexError, OSError) as error:
    print(f"cardcheck: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'not ok %d - %s\n' "$CHECKS" "$1" >&2
  if [[ -n "$CASE_STDOUT" && -s "$CASE_STDOUT" ]]; then
    printf '  stdout:\n' >&2
    sed 's/^/  | /' "$CASE_STDOUT" >&2
  fi
  if [[ -n "$CASE_STDERR" && -s "$CASE_STDERR" ]]; then
    printf '  stderr:\n' >&2
    sed 's/^/  | /' "$CASE_STDERR" >&2
  fi
}

workspace() { # $1=name
  local path="$TMP_ROOT/ws-$1"
  mkdir -p "$path"
  printf '%s\n' "$path"
}

store_dir() { # $1=workspace
  python3 - "$HOME" "$1" <<'PY'
import hashlib, os, sys
home, workspace = sys.argv[1], sys.argv[2]
key = hashlib.sha256(os.path.realpath(workspace).encode("utf-8")).hexdigest()
print(os.path.join(home, ".config", "olddonkey-loop", "journal", key))
PY
}

run_cmd() { # $1=name, remaining=command
  local name="$1"
  shift
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if "$@" >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

run_cmd_in_dir() { # $1=name $2=dir, remaining=command
  local name="$1" dir="$2"
  shift 2
  CASE_STDOUT="$TMP_ROOT/$name.stdout"
  CASE_STDERR="$TMP_ROOT/$name.stderr"
  if (cd "$dir" && "$@") >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
}

expect_status() { # $1=expected $2=description
  if [[ $CASE_STATUS -eq $1 ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1, got $CASE_STATUS)"
  fi
}

expect_refusal() { # $1=expected status $2=description; stdout must stay empty
  if [[ $CASE_STATUS -eq $1 && ! -s "$CASE_STDOUT" && -s "$CASE_STDERR" ]]; then
    pass "$2"
  else
    fail "$2 (expected status $1 with empty stdout, got $CASE_STATUS)"
  fi
}

field_from() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" | head -n 1
}

cardcheck() {
  python3 "$TMP_ROOT/cardcheck.py" "$@"
}

rows_of() { # remaining="strength|attribution" per row
  local IFS=$'\n'
  printf '%s' "$*"
}

# Fixture steps never abort the suite; expect_fixture turns the collected
# failures into one check.
step() { # remaining=command
  if ! "$@" >"$TMP_ROOT/step.stdout" 2>"$TMP_ROOT/step.stderr"; then
    FIXTURE_ERRORS+="$*: $(head -c 300 "$TMP_ROOT/step.stderr")"$'\n'
  fi
}

expect_fixture() { # $1=description
  CASE_STDOUT=""
  CASE_STDERR=""
  if [[ -z "$FIXTURE_ERRORS" ]]; then
    pass "$1"
  else
    fail "$1"
    printf '%s' "$FIXTURE_ERRORS" | sed 's/^/  | /' >&2
  fi
  FIXTURE_ERRORS=""
}

# Runs in a command substitution: callers check for an empty id.
begin_run() { # $1=workspace; prints the run id
  "$RUN" begin --workspace "$1" 2>/dev/null | sed -n 's/^run=//p' | head -n 1
}

dispatch() { # $1=workspace $2=unit $3=round $4=dispatch id $5=backend $6=mode $7=exit
  step env LOOP_UNIT="$2" LOOP_ROUND="$3" "$JOURNAL" append --workspace "$1" \
    --event dispatch.start --field "dispatch_id=$4" --field "backend=$5" --field "mode=$6"
  step env LOOP_UNIT="$2" LOOP_ROUND="$3" "$JOURNAL" append --workspace "$1" \
    --event dispatch.end --field "dispatch_id=$4" --field "exit=$7"
}

gate() { # $1=workspace $2=unit ("" = unlabelled) $3=round, remaining=--field args
  local ws="$1" unit="$2" round="$3"
  shift 3
  if [[ -n "$unit" ]]; then
    step env LOOP_UNIT="$unit" LOOP_ROUND="$round" "$JOURNAL" append --workspace "$ws" \
      --event gate.result "$@"
  else
    step "$JOURNAL" append --workspace "$ws" --event gate.result "$@"
  fi
}

# Print one card in both formats: $CARDS/<name>.json and $CARDS/<name>.md.
make_card() { # $1=card name $2=workspace, remaining=loop-evidence args
  local name="$1" ws="$2" json_status
  shift 2
  run_cmd "card-$name-json" "$EVIDENCE" --workspace "$ws" --format json "$@"
  json_status=$CASE_STATUS
  cp "$CASE_STDOUT" "$CARDS/$name.json"
  run_cmd "card-$name-md" "$EVIDENCE" --workspace "$ws" "$@"
  cp "$CASE_STDOUT" "$CARDS/$name.md"
  if [[ $json_status -eq 0 && $CASE_STATUS -eq 0 ]]; then
    pass "$name: card exits 0 in markdown and json"
  else
    fail "$name: card exits 0 in markdown and json (json $json_status, markdown $CASE_STATUS)"
  fi
}

expect_rows() { # $1=card name $2=expected rows $3=description
  local format got
  for format in md json; do
    CASE_STDOUT="$CARDS/$1.$format"
    CASE_STDERR=""
    if got="$(cardcheck rows "$CARDS/$1.$format" 2>&1)" && [[ "$got" == "$2" ]]; then
      pass "$3 ($format)"
    else
      fail "$3 ($format): got [${got//$'\n'/, }]"
    fi
  done
}

expect_line() { # $1=card name $2=row label $3=expected table line $4=description
  local got
  CASE_STDOUT="$CARDS/$1.md"
  CASE_STDERR=""
  got="$(cardcheck line "$CARDS/$1.md" "$2" 2>&1)"
  if [[ "$got" == "$3" ]]; then
    pass "$4"
  else
    fail "$4: got [$got]"
  fi
}

expect_get() { # $1=card name $2=json path $3=expected json value $4=description
  local got
  CASE_STDOUT="$CARDS/$1.json"
  CASE_STDERR=""
  got="$(cardcheck get "$CARDS/$1.json" "$2" 2>&1)"
  if [[ "$got" == "$3" ]]; then
    pass "$4"
  else
    fail "$4: got [$got]"
  fi
}

expect_no_green() { # $1=card name $2=description
  CASE_STDOUT=""
  CASE_STDERR=""
  if grep -qi green "$CARDS/$1.md" "$CARDS/$1.json"; then
    fail "$2"
  else
    pass "$2"
  fi
}

# ---------------------------------------------------------------------------
# 1. Writer-built run: green path, red and legacy final gates, no final gate,
#    SHA comparisons, later adverse gates, iterate then pass.
# ---------------------------------------------------------------------------
WS_MAIN="$(workspace main)"
RUN_MAIN="$(begin_run "$WS_MAIN")"

step "$RUN" unit-begin --unit u-green --workspace "$WS_MAIN"
step "$RUN" round-begin --unit u-green --round 1 --workspace "$WS_MAIN"
dispatch "$WS_MAIN" u-green 1 d-green codex implement 0
gate "$WS_MAIN" u-green 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A"
step "$RUN" review --unit u-green --round 1 --verdict pass --workspace "$WS_MAIN"
step "$RUN" publish --unit u-green --branch feat/u-green \
  --pr https://example.invalid/pr/1 --sha "$SHA_A" --workspace "$WS_MAIN"
# Unlabelled: after u-green's final gate, yet no unit's gate.
gate "$WS_MAIN" "" "" "${FOCUSED_RED[@]}"

step "$RUN" unit-begin --unit u-red --workspace "$WS_MAIN"
gate "$WS_MAIN" u-red 1 "${FINAL_RED_DIRTY[@]}"

step "$RUN" unit-begin --unit u-legacy --workspace "$WS_MAIN"
gate "$WS_MAIN" u-legacy 1 "${FINAL_LEGACY[@]}"

step "$RUN" unit-begin --unit u-nofinal --workspace "$WS_MAIN"
gate "$WS_MAIN" u-nofinal 1 "${FOCUSED_GREEN[@]}" --field "post_head=$SHA_A"
step "$RUN" publish --unit u-nofinal --branch b-nofinal --sha "$SHA_A" --workspace "$WS_MAIN"

gate "$WS_MAIN" u-sha-none 1 "${FINAL_GREEN[@]}"
step "$RUN" publish --unit u-sha-none --branch b-none --workspace "$WS_MAIN"
gate "$WS_MAIN" u-sha-one 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A"
step "$RUN" publish --unit u-sha-one --branch b-one --workspace "$WS_MAIN"
gate "$WS_MAIN" u-sha-upper 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A_UPPER"
step "$RUN" publish --unit u-sha-upper --branch b-upper --sha "$SHA_A" --workspace "$WS_MAIN"
gate "$WS_MAIN" u-sha-short 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A"
step "$RUN" publish --unit u-sha-short --branch b-short --sha "$SHA_A_SHORT" --workspace "$WS_MAIN"
gate "$WS_MAIN" u-sha-diff 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A"
step "$RUN" publish --unit u-sha-diff --branch b-diff --sha "$SHA_B" --workspace "$WS_MAIN"

# u-later: a red gate before the final gate, then after it red, green, and
# unknown gates of its own, plus another unit's and an unlabelled red gate.
gate "$WS_MAIN" u-later 1 "${FOCUSED_RED[@]}"
gate "$WS_MAIN" u-later 1 "${FINAL_GREEN[@]}" --field "post_head=$SHA_A"
gate "$WS_MAIN" u-later 2 "${FOCUSED_RED[@]}"
gate "$WS_MAIN" u-later 2 "${FOCUSED_GREEN[@]}"
gate "$WS_MAIN" u-later 2 "${FOCUSED_UNKNOWN[@]}"
gate "$WS_MAIN" u-other 2 "${FOCUSED_RED[@]}"
gate "$WS_MAIN" "" "" "${FOCUSED_RED[@]}"

step "$RUN" unit-begin --unit u-iter --workspace "$WS_MAIN"
step "$RUN" round-begin --unit u-iter --round 1 --workspace "$WS_MAIN"
dispatch "$WS_MAIN" u-iter 1 d-iter-1 grok implement 0
step "$RUN" review --unit u-iter --round 1 --verdict iterate --workspace "$WS_MAIN"
step "$RUN" round-begin --unit u-iter --round 2 --workspace "$WS_MAIN"
dispatch "$WS_MAIN" u-iter 2 d-iter-2 grok implement 0
step "$RUN" review --unit u-iter --round 2 --verdict pass --workspace "$WS_MAIN"
gate "$WS_MAIN" u-iter 2 "${FINAL_GREEN[@]}" --field "post_head=$SHA_B"
step "$RUN" publish --unit u-iter --branch feat/u-iter --sha "$SHA_B" --workspace "$WS_MAIN"
[[ -n "$RUN_MAIN" ]] || FIXTURE_ERRORS+="no run id from loop-run begin"$'\n'
expect_fixture "main: writer fixture appends through loop-run and loop-journal"

# Green path: the whole card, byte for byte.
make_card green "$WS_MAIN" --unit u-green
cat > "$TMP_ROOT/green.expected" <<'EOF'
### Record card for unit u\-green

Run @RUN@ (status active; journal record complete)

| row | recorded value | strength | attribution |
| --- | --- | --- | --- |
| dispatches attributed to this unit | 1 recorded: d\-green (codex, implement, round 1, ended, exit 0) | recorded | declared |
| review rounds and last recorded verdict | rounds begun: 1; last recorded verdict pass (round 1); reviews recorded: 0 iterate, 1 pass | recorded | not applicable |
| final gate | verdict green; policy strict; purpose unit\-final; binding clean; post head 0123456789abcdef0123456789abcdef01234567; round 1 | recorded | declared |
| later adverse gates | none recorded after the final gate | recorded | declared |
| recorded SHAs | values match: gate post head 0123456789abcdef0123456789abcdef01234567, publish sha 0123456789abcdef0123456789abcdef01234567 | values match | not applicable |
| publication | branch feat/u\-green; PR https\://example\.invalid/pr/1; sha 0123456789abcdef0123456789abcdef01234567 | recorded | not applicable |

Attribution unclear (counted for no unit): none recorded.

Every row is an unverified entry in the local journal, which any process running as this user can append to; nothing here meets task-graph-v1 §3's proof bar.
EOF
CASE_STDOUT="$CARDS/green.md"
CASE_STDERR=""
if python3 - "$TMP_ROOT/green.expected" "$CARDS/green.md" "$RUN_MAIN" <<'PY'
import sys
expected = open(sys.argv[1], encoding="utf-8").read()
expected = expected.replace("@RUN@", sys.argv[3].replace("-", "\\-"))
actual = open(sys.argv[2], encoding="utf-8", newline="").read()
if actual != expected:
    raise SystemExit("card differs from the expected text")
PY
then
  pass "green: the markdown card is exactly the expected text (default run is the active run)"
else
  fail "green: the markdown card is exactly the expected text (default run is the active run)"
fi
expect_rows green "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_MATCH" "$R_PUBLISHED")" "green: every row's strength and attribution"
expect_get green run "\"$RUN_MAIN\"" "green: json names the active run"
expect_get green rows.0.dispatches \
  '[{"dispatch_id": "d-green", "backend": "codex", "mode": "implement", "round": 1, "state": "ended", "exit": 0}]' \
  "green: json dispatches carry id, backend, mode, round, state, and the recorded exit"
expect_get green rows.4 \
  "{\"row\": \"recorded_shas\", \"strength\": \"values match\", \"attribution\": \"not applicable\", \"comparison\": \"values match\", \"gate_post_head\": \"$SHA_A\", \"publish_sha\": \"$SHA_A\"}" \
  "green: json recorded SHAs row carries both values and the comparison"

run_cmd green-md-again "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green
if cmp -s "$CASE_STDOUT" "$CARDS/green.md"; then
  pass "determinism: a second markdown card is byte-identical"
else
  fail "determinism: a second markdown card is byte-identical"
fi
run_cmd green-json-again "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green --format json
if cmp -s "$CASE_STDOUT" "$CARDS/green.json"; then
  pass "determinism: a second json card is byte-identical"
else
  fail "determinism: a second json card is byte-identical"
fi

make_card red "$WS_MAIN" --unit u-red
expect_line red "final gate" \
  '| final gate | verdict red; policy strict; purpose unit\-final; binding dirty (not clean); post head not recorded; round 1 | recorded | declared |' \
  "red: the final gate row shows the red verdict and that binding is not clean"
expect_rows red "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_UNKNOWN" "$R_UNPUBLISHED")" "red: every row's strength and attribution"
expect_no_green red "red: the card never says green"
expect_line red publication '| publication | no publication recorded | unknown | not applicable |' \
  "red: an absent publication reads unknown"

make_card legacy "$WS_MAIN" --unit u-legacy
expect_line legacy "final gate" \
  '| final gate | verdict unknown; policy passthrough; purpose unit\-final; binding clean; post head not recorded; round 1 | recorded | declared |' \
  "legacy: a gate without verdict or gate_exit renders verdict unknown"
expect_no_green legacy "legacy: totals=exit=0 is never read as green, in markdown or json"
expect_get legacy rows.2.gate.verdict '"unknown"' "legacy: json final gate verdict is unknown"
expect_rows legacy "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_UNKNOWN" "$R_UNPUBLISHED")" "legacy: every row's strength and attribution"

make_card nofinal "$WS_MAIN" --unit u-nofinal
expect_line nofinal "final gate" '| final gate | no final gate recorded | unknown | none |' \
  "no final gate: the row reads no final gate recorded, strength unknown, attribution none"
expect_line nofinal "later adverse gates" \
  '| later adverse gates | no final gate recorded | unknown | none |' \
  "no final gate: later adverse gates has nothing to follow, strength unknown, attribution none"
expect_line nofinal "recorded SHAs" \
  '| recorded SHAs | cannot compare: gate post head not recorded, publish sha 0123456789abcdef0123456789abcdef01234567 | unknown | not applicable |' \
  "no final gate: a focused gate's post head is never compared"
expect_rows nofinal "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_NO_FINAL" "$R_NO_FINAL" \
  "$R_SHAS_UNKNOWN" "$R_PUBLISHED")" "no final gate: every row's strength and attribution"
expect_get nofinal rows.2 \
  '{"row": "final_gate", "strength": "unknown", "attribution": "none", "gate": null}' \
  "no final gate: json final gate row is unknown/none with a null gate"
expect_get nofinal rows.3 \
  '{"row": "later_adverse_gates", "strength": "unknown", "attribution": "none", "gates": []}' \
  "no final gate: json later adverse gates row is unknown/none with no gates"

SHA_ROWS="$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" "$R_SHAS_UNKNOWN" \
  "$R_PUBLISHED")"
make_card sha-none "$WS_MAIN" --unit u-sha-none
expect_line sha-none "recorded SHAs" \
  '| recorded SHAs | cannot compare: gate post head not recorded, publish sha not recorded | unknown | not applicable |' \
  "SHAs: both missing cannot compare"
expect_rows sha-none "$SHA_ROWS" "SHAs both missing: every row's strength and attribution"
make_card sha-one "$WS_MAIN" --unit u-sha-one
expect_line sha-one "recorded SHAs" \
  '| recorded SHAs | cannot compare: gate post head 0123456789abcdef0123456789abcdef01234567, publish sha not recorded | unknown | not applicable |' \
  "SHAs: one missing cannot compare"
expect_rows sha-one "$SHA_ROWS" "SHAs one missing: every row's strength and attribution"
make_card sha-upper "$WS_MAIN" --unit u-sha-upper
expect_line sha-upper "recorded SHAs" \
  '| recorded SHAs | cannot compare: gate post head 0123456789ABCDEF0123456789ABCDEF01234567, publish sha 0123456789abcdef0123456789abcdef01234567 | unknown | not applicable |' \
  "SHAs: an uppercase post head is malformed and cannot compare"
expect_rows sha-upper "$SHA_ROWS" "SHAs malformed: every row's strength and attribution"
make_card sha-short "$WS_MAIN" --unit u-sha-short
expect_line sha-short "recorded SHAs" \
  '| recorded SHAs | cannot compare: gate post head 0123456789abcdef0123456789abcdef01234567, publish sha 0123456789abcdef0123456789abcdef0123456 | unknown | not applicable |' \
  "SHAs: a 39-digit publish sha is malformed and cannot compare"
make_card sha-diff "$WS_MAIN" --unit u-sha-diff
expect_line sha-diff "recorded SHAs" \
  '| recorded SHAs | recorded SHAs differ: gate post head 0123456789abcdef0123456789abcdef01234567, publish sha fedcba9876543210fedcba9876543210fedcba98 | unknown | not applicable |' \
  "SHAs: unequal values read recorded SHAs differ"
expect_rows sha-diff "$SHA_ROWS" "SHAs unequal: every row's strength and attribution"
expect_get sha-diff rows.4.comparison '"recorded SHAs differ"' \
  "SHAs: json comparison says recorded SHAs differ"

make_card later "$WS_MAIN" --unit u-later
expect_line later "later adverse gates" \
  '| later adverse gates | 2 recorded: verdict red (policy passthrough, purpose focused, binding clean, post head not recorded, round 2); verdict unknown (policy passthrough, purpose focused, binding clean, post head not recorded, round 2) | recorded | declared |' \
  "later gates: a later red and a later unknown gate are listed; earlier, green, other-unit, and unlabelled gates are not"
expect_get later rows.3.gates \
  '[{"verdict": "red", "policy": "passthrough", "purpose": "focused", "binding": "clean", "round": 2, "post_head": null}, {"verdict": "unknown", "policy": "passthrough", "purpose": "focused", "binding": "clean", "round": 2, "post_head": null}]' \
  "later gates: json lists the red then the unknown gate"
expect_rows later "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_UNKNOWN" "$R_UNPUBLISHED")" "later gates: every row's strength and attribution"
expect_line green "later adverse gates" \
  '| later adverse gates | none recorded after the final gate | recorded | declared |' \
  "later gates: an unlabelled red gate after u-green's final gate is not u-green's"

make_card iter "$WS_MAIN" --unit u-iter
expect_line iter "review rounds and last recorded verdict" \
  '| review rounds and last recorded verdict | rounds begun: 2; last recorded verdict pass (round 2); reviews recorded: 1 iterate, 1 pass | recorded | not applicable |' \
  "iterate then pass: two rounds, last verdict pass in round 2, one review of each"
expect_line iter "dispatches attributed to this unit" \
  '| dispatches attributed to this unit | 2 recorded: d\-iter\-1 (grok, implement, round 1, ended, exit 0); d\-iter\-2 (grok, implement, round 2, ended, exit 0) | recorded | declared |' \
  "iterate then pass: both rounds' dispatches are attributed"
expect_rows iter "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_MATCH" "$R_PUBLISHED")" "iterate then pass: every row's strength and attribution"

# ---------------------------------------------------------------------------
# 2. Raw segment: partial, conflicted, and unlabelled dispatches and gates the
#    writer would label differently; a discarded torn tail.
# ---------------------------------------------------------------------------
WS_RAW="$(workspace raw)"
RUN_RAW="20260901T000000Z-0e0a01"
python3 - "$WS_RAW" "$HOME" "$RUN_RAW" <<'PY'
import hashlib, json, os, sys
ws, home, run_id = sys.argv[1:]
key = hashlib.sha256(os.path.realpath(ws).encode("utf-8")).hexdigest()
runs_dir = os.path.join(home, ".config", "olddonkey-loop", "journal", key, "runs")
os.makedirs(runs_dir, exist_ok=True)
green = {"policy": "strict", "binding": "clean", "verdict": "green", "gate_exit": 0,
         "totals": "exit=0"}
red = {"policy": "passthrough", "binding": "clean", "verdict": "red", "gate_exit": 1,
       "totals": "exit=1"}
events = [
    {"event": "run.begin", "generation": 1, "workspace": ws, "workspace_key": key},
    {"event": "unit.begin", "unit": "u-a"},
    # declared: counted for u-a.
    {"event": "dispatch.start", "dispatch_id": "d-decl", "backend": "codex",
     "mode": "implement", "unit": "u-a", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-decl", "exit": 0, "unit": "u-a", "round": 1},
    # none: no label anywhere; counted for no unit and not listed.
    {"event": "dispatch.start", "dispatch_id": "d-none", "backend": "grok", "mode": "implement"},
    {"event": "dispatch.end", "dispatch_id": "d-none", "exit": 1},
    # partial: an end with no start, still declaring u-a.
    {"event": "dispatch.end", "dispatch_id": "d-part", "exit": 1, "unit": "u-a", "round": 1},
    # conflict: the start declares u-a, the end u-b.
    {"event": "dispatch.start", "dispatch_id": "d-conf", "backend": "grok",
     "mode": "implement", "unit": "u-a", "round": 1},
    {"event": "dispatch.end", "dispatch_id": "d-conf", "exit": 0, "unit": "u-b", "round": 1},
    dict(green, event="gate.result", purpose="unit-final", unit="u-a", round=1),
    # Unlabelled or malformed labels: no unit's gates, whatever their purpose.
    dict(red, event="gate.result", purpose="unit-final"),
    dict(red, event="gate.result", purpose="focused", unit=7),
    dict(red, event="gate.result", purpose="focused", unit=""),
]
with open(os.path.join(runs_dir, run_id + ".jsonl"), "w", encoding="utf-8") as handle:
    for seq, event in enumerate(events, 1):
        row = {"schema": 1, "seq": seq, "ts": "2026-09-01T00:00:00Z", "run": run_id}
        row.update(event)
        handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
    # A torn tail: unterminated and unparseable, so the index discards it.
    handle.write('{"schema":1,"seq":99,"event":"chec')
PY
make_card raw "$WS_RAW" --unit u-a
expect_line raw "dispatches attributed to this unit" \
  '| dispatches attributed to this unit | 1 recorded: d\-decl (codex, implement, round 1, ended, exit 0) | recorded | declared |' \
  "attribution: only the declared dispatch counts; unlabelled, partial, and conflicted ones do not"
expect_line raw "final gate" \
  '| final gate | verdict green; policy strict; purpose unit\-final; binding clean; post head not recorded; round 1 | recorded | declared |' \
  "attribution: a later unlabelled unit-final gate never becomes the unit's final gate"
expect_line raw "later adverse gates" \
  '| later adverse gates | none recorded after the final gate | recorded | declared |' \
  "attribution: unlabelled and malformed-unit red gates are not the unit's adverse gates"
CASE_STDOUT="$CARDS/raw.md"
CASE_STDERR=""
RAW_ITEMS="$(cardcheck items "$CARDS/raw.md")"
RAW_ITEMS_WANT='- d\-part (unknown, unknown, ended, exit 1): no dispatch.start recorded
- d\-conf (grok, implement, ended, exit 0): its events declare different units or rounds'
if [[ "$RAW_ITEMS" == "$RAW_ITEMS_WANT" ]]; then
  pass "attribution: partial and conflicted dispatches are listed separately as attribution unclear"
else
  fail "attribution: partial and conflicted dispatches are listed separately as attribution unclear"
fi
expect_get raw attribution_unclear \
  '[{"dispatch_id": "d-part", "backend": "unknown", "mode": "unknown", "state": "ended", "exit": 1, "unclear": "partial"}, {"dispatch_id": "d-conf", "backend": "grok", "mode": "implement", "state": "ended", "exit": 0, "unclear": "conflict"}]' \
  "attribution: json lists the unclear dispatches outside every row"
expect_get raw rows.0.count 1 "attribution: json counts one dispatch for the unit"
expect_rows raw "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_UNKNOWN" "$R_UNPUBLISHED")" "attribution fixture: every row's strength and attribution"
CASE_STDOUT="$CARDS/raw.md"
if [[ "$(cardcheck nth "$CARDS/raw.md" 2)" == 'Run 20260901T000000Z\-0e0a01 (status active; journal record partial)' ]]; then
  pass "partial record: a discarded torn tail labels the journal record partial"
else
  fail "partial record: a discarded torn tail labels the journal record partial"
fi
expect_get raw counts_complete false "partial record: json counts_complete is false"
run_cmd raw-conflict-only "$EVIDENCE" --workspace "$WS_RAW" --unit u-b
expect_refusal 2 "attribution: a unit named only by a conflicted dispatch is unknown (exit 2)"

# ---------------------------------------------------------------------------
# 3. Escaping: exact markdown output for hostile journal strings.
# ---------------------------------------------------------------------------
WS_ESC="$(workspace escaping)"
RUN_ESC="$(begin_run "$WS_ESC")"
ESC_CASES=(
  "e-script|<script>alert(1)</script>|&lt;script&gt;alert\\(1\\)&lt;/script&gt;"
  "e-amp|a&b&amp;c|a&amp;b&amp;amp;c"
  "e-bslash|back\\slash\\\\|back\\\\slash\\\\\\\\"
  "e-link|[x](http://e)|\\[x\\]\\(http\\://e\\)"
  "e-image|![i](http://e)|\\!\\[i\\]\\(http\\://e\\)"
  "e-tick|\`code\`|\\\`code\\\`"
  "e-quote|\"q\" 'q'|&quot;q&quot; &apos;q&apos;"
  "e-punct|*_{}#+-.!~|\\*\\_\\{\\}\\#\\+\\-\\.\\!\\~"
  "e-url|https://example.com/a|https\\://example\\.com/a"
  "e-www|www.example.com|www\\.example\\.com"
)
for entry in "${ESC_CASES[@]}"; do
  IFS='|' read -r esc_unit esc_raw _ <<< "$entry"
  step "$RUN" publish --unit "$esc_unit" --branch "$esc_raw" --workspace "$WS_ESC"
done
# The table-cell pipe case, kept out of the '|'-separated list above.
step "$RUN" publish --unit e-pipe --branch 'a|b' --workspace "$WS_ESC"
step "$RUN" unit-begin --unit '<b>|x' --workspace "$WS_ESC"
# CR, LF, and tab: the append validator refuses them, so a raw line.
python3 - "$(store_dir "$WS_ESC")" "$RUN_ESC" <<'PY' || FIXTURE_ERRORS+="raw CR/LF/tab line"$'\n'
import json, os, sys
store, run_id = sys.argv[1:]
path = os.path.join(store, "runs", run_id + ".jsonl")
last = [line for line in open(path, encoding="utf-8").read().split("\n") if line][-1]
row = {"schema": 1, "seq": json.loads(last)["seq"] + 1, "ts": "2026-09-01T00:00:00Z",
       "event": "publish.recorded", "run": run_id, "unit": "e-ctl", "branch": "a\rb\nc\td"}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n")
PY
[[ -n "$RUN_ESC" ]] || FIXTURE_ERRORS+="no run id from loop-run begin"$'\n'
expect_fixture "escaping: hostile strings append through loop-run publish and one raw line"

ESC_CASES+=("e-pipe|PIPE|a\\|b" "e-ctl|CTL|a b c d")
for entry in "${ESC_CASES[@]}"; do
  IFS='|' read -r esc_unit _ esc_want <<< "$entry"
  make_card "$esc_unit" "$WS_ESC" --unit "$esc_unit"
  expect_line "$esc_unit" publication \
    "| publication | branch $esc_want; PR not recorded; sha not recorded | recorded | not applicable |" \
    "escaping $esc_unit: exact publication row"
done
make_card e-heading "$WS_ESC" --unit '<b>|x'
CASE_STDOUT="$CARDS/e-heading.md"
if [[ "$(cardcheck nth "$CARDS/e-heading.md" 0)" == '### Record card for unit &lt;b&gt;\|x' ]]; then
  pass "escaping: the unit name in the heading is escaped"
else
  fail "escaping: the unit name in the heading is escaped"
fi
expect_get e-ctl rows.5.publication.branch '"a\rb\nc\td"' \
  "escaping: json carries CR, LF, and tab with JSON's own escaping only"
expect_get e-script rows.5.publication.branch '"<script>alert(1)</script>"' \
  "escaping: json carries <script> unescaped"
CASE_STDOUT=""
CASE_STDERR=""
if python3 - "$CARDS" <<'PY'
import glob, os, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], "e-*.md"))):
    text = open(path, encoding="utf-8", newline="").read()
    for bad in ("<", "](", "![", "\r", "\t"):
        if bad in text:
            raise SystemExit(f"{os.path.basename(path)} contains {bad!r}")
PY
then
  pass "escaping: no escaping card contains raw HTML, link or image syntax, CR, or tab"
else
  fail "escaping: no escaping card contains raw HTML, link or image syntax, CR, or tab"
fi
if python3 - "$CARDS" <<'PY'
import glob, os, re, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], "e-*.md"))):
    text = open(path, encoding="utf-8", newline="").read()
    match = re.search(r"(?<!\\)://|www\.", text)
    if match:
        raise SystemExit(f"{os.path.basename(path)} contains {match.group(0)!r}")
PY
then
  pass "escaping: no escaping card contains an unescaped scheme or www autolink"
else
  fail "escaping: no escaping card contains an unescaped scheme or www autolink"
fi

# ---------------------------------------------------------------------------
# 4. Run selection
# ---------------------------------------------------------------------------
WS_RUNS="$(workspace runs)"
RUN_OLD="$(begin_run "$WS_RUNS")"
step "$RUN" unit-begin --unit u-old --workspace "$WS_RUNS"
step "$RUN" unit-begin --unit u-both --workspace "$WS_RUNS"
step "$RUN" end --status completed --workspace "$WS_RUNS"
RUN_NEW="$(begin_run "$WS_RUNS")"
step "$RUN" unit-begin --unit u-new --workspace "$WS_RUNS"
step "$RUN" unit-begin --unit u-both --workspace "$WS_RUNS"
[[ -n "$RUN_OLD" && -n "$RUN_NEW" && "$RUN_OLD" != "$RUN_NEW" ]] ||
  FIXTURE_ERRORS+="two distinct run ids"$'\n'
expect_fixture "runs: two runs, the second active"
make_card runs-both "$WS_RUNS" --unit u-both
expect_get runs-both run "\"$RUN_NEW\"" "runs: the active run is the default when it contains the unit"
make_card runs-old "$WS_RUNS" --unit u-old
expect_get runs-old run "\"$RUN_OLD\"" "runs: otherwise the newest run containing the unit"
make_card runs-pick "$WS_RUNS" --unit u-both --run "$RUN_OLD"
expect_get runs-pick run "\"$RUN_OLD\"" "runs: --run selects that run"
run_cmd runs-missing-unit "$EVIDENCE" --workspace "$WS_RUNS" --unit u-old --run "$RUN_NEW"
expect_refusal 2 "runs: a unit absent from the named run exits 2"
run_cmd runs-unknown-run "$EVIDENCE" --workspace "$WS_RUNS" --unit u-both \
  --run 20990101T000000Z-abcdef
expect_refusal 2 "runs: a run id the index does not list exits 2"
step "$RUN" end --status completed --workspace "$WS_RUNS"
expect_fixture "runs: the second run ends"
make_card runs-ended "$WS_RUNS" --unit u-both
expect_get runs-ended run "\"$RUN_NEW\"" "runs: with no active run, the newest run containing the unit"

# ---------------------------------------------------------------------------
# 5. Hostile tracked suite: the gated command forges a review and a
#    publication through loop-journal append.
# ---------------------------------------------------------------------------
WS_HOST="$(workspace hostile)"
git init -q "$WS_HOST"
git -C "$WS_HOST" config user.email evidence-selftest@example.invalid
git -C "$WS_HOST" config user.name evidence-selftest
printf 'base\n' > "$WS_HOST/file.txt"
git -C "$WS_HOST" add file.txt
git -C "$WS_HOST" commit -qm base
HOST_HEAD="$(git -C "$WS_HOST" rev-parse HEAD)"
RUN_HOST="$(begin_run "$WS_HOST")"
step "$RUN" unit-begin --unit u-host --workspace "$WS_HOST"
[[ -n "$RUN_HOST" ]] || FIXTURE_ERRORS+="no run id from loop-run begin"$'\n'
expect_fixture "hostile: a git workspace with an active run"
FORGE='"$FORGE_JOURNAL" append --workspace "$PWD" --event review.recorded --field unit=u-host --field round=1 --field verdict=pass --field findings=forged-by-suite && "$FORGE_JOURNAL" append --workspace "$PWD" --event publish.recorded --field unit=u-host --field branch=forged-branch --field "sha=$(git rev-parse HEAD)" && printf "Ran 1 test in 0.001s\nOK\n"'
run_cmd_in_dir hostile-gate "$WS_HOST" env FORGE_JOURNAL="$JOURNAL" LOOP_JOURNAL="$JOURNAL" \
  LOOP_TREE_OID="$TREE_OID" LOOP_UNIT=u-host LOOP_ROUND=1 \
  bash "$GATE" --strict --purpose unit-final --log "$TMP_ROOT/hostile-gate.log" -- bash -c "$FORGE"
expect_status 0 "hostile: the gate whose suite forges journal entries exits 0"
make_card hostile "$WS_HOST" --unit u-host
expect_line hostile "review rounds and last recorded verdict" \
  '| review rounds and last recorded verdict | rounds begun: 0; last recorded verdict pass (round 1); reviews recorded: 0 iterate, 1 pass | recorded | not applicable |' \
  "hostile: the forged review is shown only as a recorded entry"
expect_line hostile publication \
  "| publication | branch forged\\-branch; PR not recorded; sha $HOST_HEAD | recorded | not applicable |" \
  "hostile: the forged publication is shown only as a recorded entry"
expect_line hostile "final gate" \
  "| final gate | verdict green; policy strict; purpose unit\\-final; binding clean; post head $HOST_HEAD; round 1 | recorded | declared |" \
  "hostile: the gate is recorded with its declared label"
expect_rows hostile "$(rows_of "$R_DISPATCHES" "$R_REVIEW" "$R_FINAL" "$R_LATER" \
  "$R_SHAS_MATCH" "$R_PUBLISHED")" \
  "hostile: forged rows read recorded, and matching forged SHAs read only values match"
CASE_STDOUT="$CARDS/hostile.md"
if cardcheck tail "$CARDS/hostile.md" 2>"$TMP_ROOT/hostile-tail.stderr"; then
  pass "hostile: the card carries the fixed sentence"
else
  fail "hostile: the card carries the fixed sentence"
fi

# ---------------------------------------------------------------------------
# 6. Usage, unknown unit, and index failure
# ---------------------------------------------------------------------------
run_cmd usage-no-unit "$EVIDENCE" --workspace "$WS_MAIN"
expect_refusal 2 "usage: --unit is required (exit 2)"
run_cmd usage-empty-unit "$EVIDENCE" --workspace "$WS_MAIN" --unit ""
expect_refusal 2 "usage: an empty unit exits 2"
run_cmd usage-newline-unit "$EVIDENCE" --workspace "$WS_MAIN" --unit $'u-green\nx'
expect_refusal 2 "usage: a multi-line unit exits 2"
run_cmd usage-format "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green --format html
expect_refusal 2 "usage: an unknown --format exits 2"
run_cmd usage-run "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green --run latest
expect_refusal 2 "usage: a malformed --run exits 2"
run_cmd usage-flag "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green --pretty
expect_refusal 2 "usage: an unknown flag exits 2"
run_cmd usage-workspace "$EVIDENCE" --workspace "$TMP_ROOT/absent" --unit u-green
expect_refusal 2 "usage: a missing workspace exits 2"
run_cmd unknown-unit "$EVIDENCE" --workspace "$WS_MAIN" --unit u-absent
expect_refusal 2 "unknown unit: exit 2"
WS_EMPTY="$(workspace empty)"
run_cmd unknown-empty "$EVIDENCE" --workspace "$WS_EMPTY" --unit u-green
expect_refusal 2 "unknown unit: a workspace with no journal exits 2"
run_cmd help "$EVIDENCE" --help
if [[ $CASE_STATUS -eq 0 ]] && grep -q 'values match' "$CASE_STDOUT"; then
  pass "usage: --help exits 0 and names the strength values"
else
  fail "usage: --help exits 0 and names the strength values"
fi

run_cmd index-no-home env -u HOME "$EVIDENCE" --workspace "$WS_MAIN" --unit u-green
expect_refusal 5 "index failure: loop-index exiting nonzero (HOME unset) exits 5"

# A copy of loop-evidence beside a stub loop-index: the sibling is the only
# reader, so the stub's document alone decides the card.
STUB_DIR="$TMP_ROOT/stub-scripts"
mkdir -p "$STUB_DIR"
cp "$EVIDENCE" "$STUB_DIR/loop-evidence"
chmod 755 "$STUB_DIR/loop-evidence"
cat > "$STUB_DIR/loop-index" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
case "$STUB_MODE" in
  fail) echo "error: stub failure" >&2; exit 1 ;;
  garbage) printf 'not json\n' ;;
  array) printf '[]\n' ;;
  schema) printf '{"schema":2,"context":{},"runs":[]}\n' ;;
  shape) printf '{"schema":1,"context":{},"runs":[{"run_id":"x","units":{},"dispatches":[],"gates":[]}]}\n' ;;
  canned) cat "$STUB_DOC" ;;
esac
SH
chmod 755 "$STUB_DIR/loop-index"
for mode in fail garbage array schema shape; do
  run_cmd "index-$mode" env STUB_MODE="$mode" STUB_ARGV="$TMP_ROOT/stub-argv" \
    "$STUB_DIR/loop-evidence" --workspace "$WS_EMPTY" --unit u-stub
  expect_refusal 5 "index failure: stub loop-index ($mode) exits 5"
done
STUB_MISSING="$TMP_ROOT/stub-missing"
mkdir -p "$STUB_MISSING"
cp "$EVIDENCE" "$STUB_MISSING/loop-evidence"
chmod 755 "$STUB_MISSING/loop-evidence"
run_cmd index-missing "$STUB_MISSING/loop-evidence" --workspace "$WS_EMPTY" --unit u-stub
expect_refusal 5 "index failure: no sibling loop-index exits 5"

python3 - "$TMP_ROOT/stub-doc.json" <<'PY'
import json, sys
run_id = "20260901T000000Z-5a0b01"
doc = {
    "schema": 1, "workspace": "/stub", "workspace_key": "0" * 64,
    "journal": {"status": "ok"}, "context": {"state": "active", "run": run_id},
    "runs": [{
        "run_id": run_id, "generation": 1, "status": "active",
        "units": [{"unit": "u-stub", "status": "active", "rounds": 0,
                   "review": "not recorded", "publish": "not recorded"}],
        "dispatches": [], "gates": [], "counts_complete": True,
    }],
    "unattributed_events": 0, "unattributed_state": {},
}
json.dump(doc, open(sys.argv[1], "w", encoding="utf-8"))
PY
run_cmd index-canned env STUB_MODE=canned STUB_DOC="$TMP_ROOT/stub-doc.json" \
  STUB_ARGV="$TMP_ROOT/stub-argv" "$STUB_DIR/loop-evidence" --workspace "$WS_EMPTY" \
  --unit u-stub --format json
if [[ $CASE_STATUS -eq 0 ]] && grep -q '"run": "20260901T000000Z-5a0b01"' "$CASE_STDOUT"; then
  pass "reader: the card comes from the sibling loop-index document alone"
else
  fail "reader: the card comes from the sibling loop-index document alone"
fi
if [[ "$(cat "$TMP_ROOT/stub-argv")" == "--workspace"$'\n'"$WS_EMPTY" ]]; then
  pass "reader: loop-index runs with the fixed argv --workspace <canonical workspace>"
else
  fail "reader: loop-index runs with the fixed argv --workspace <canonical workspace>"
fi

# ---------------------------------------------------------------------------
# 7. Every card: wording, fixed sentence, json shape, round trip
# ---------------------------------------------------------------------------
CASE_STDOUT=""
CASE_STDERR="$TMP_ROOT/words.stderr"
if cardcheck words "$CARDS"/*.md "$CARDS"/*.json 2>"$CASE_STDERR"; then
  pass "wording: no card says proven, verified, passed, or safe"
else
  fail "wording: no card says proven, verified, passed, or safe"
fi
CASE_STDERR="$TMP_ROOT/tail.stderr"
TAIL_OK=1
for card in "$CARDS"/*.md; do
  cardcheck tail "$card" 2>>"$CASE_STDERR" || TAIL_OK=0
done
if [[ $TAIL_OK -eq 1 ]]; then
  pass "wording: every markdown card ends with the fixed sentence, printed once"
else
  fail "wording: every markdown card ends with the fixed sentence, printed once"
fi
CASE_STDERR="$TMP_ROOT/schema.stderr"
SCHEMA_OK=1
for card in "$CARDS"/*.json; do
  cardcheck rows "$card" >/dev/null 2>>"$CASE_STDERR" || SCHEMA_OK=0
done
if [[ $SCHEMA_OK -eq 1 ]]; then
  pass "json: every card has the fixed keys, and strength/attribution only on rows with closed values"
else
  fail "json: every card has the fixed keys, and strength/attribution only on rows with closed values"
fi
CASE_STDERR="$TMP_ROOT/roundtrip.stderr"
ROUNDTRIP_OK=1
for card in "$CARDS"/*.json; do
  cardcheck roundtrip "$card" 2>>"$CASE_STDERR" || ROUNDTRIP_OK=0
done
if [[ $ROUNDTRIP_OK -eq 1 ]]; then
  pass "json: every card round-trips through a JSON parser unchanged"
else
  fail "json: every card round-trips through a JSON parser unchanged"
fi
CASE_STDERR="$TMP_ROOT/same.stderr"
SAME_OK=1
for card in "$CARDS"/*.md; do
  cardcheck same "$card" "${card%.md}.json" 2>>"$CASE_STDERR" || SAME_OK=0
done
if [[ $SAME_OK -eq 1 ]]; then
  pass "formats: every markdown card shows the same strength and attribution as its json"
else
  fail "formats: every markdown card shows the same strength and attribution as its json"
fi

CASE_STDERR=""
if grep -q 'scripts/loop-evidence' "$SKILL" && grep -q 'loop-evidence' "$SCHEMA"; then
  pass "docs: SKILL.md and state-schema.md name loop-evidence"
else
  fail "docs: SKILL.md and state-schema.md name loop-evidence"
fi

if [[ $FAILED_CHECKS -gt 0 ]]; then
  printf 'selftest: FAIL (%d of %d checks failed)\n' "$FAILED_CHECKS" "$CHECKS" >&2
  exit 1
fi
printf 'selftest: PASS (%d checks)\n' "$CHECKS"
