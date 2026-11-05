#!/usr/bin/env bash
# Delegate CLI contract tests (no login).
# (a) every flag the SKILL.md files invoke exists in fixtures/{agent,agy}-help.txt
# (b) PATH-shim stubs emit fixture NDJSON; documented predicates classify correctly
# (c) guard: SKILL.md still contains the exact predicate strings the stubs exercise
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
CURSOR_SKILL="$TESTS_DIR/../skills/execute-via-cursor/SKILL.md"
AGY_SKILL="$TESTS_DIR/../skills/execute-via-agy/SKILL.md"

fails=0
n=0
work=""

cleanup() { [[ -z "$work" ]] || rm -rf "$work"; }
trap cleanup EXIT

report() {
  n=$((n + 1))
  if [[ "$2" -eq 0 ]]; then
    echo "ok $n - $1"
  else
    echo "not ok $n - $1"
    [[ -z "${3:-}" ]] || printf '  # %s\n' "$3" | head -n 8
    fails=$((fails + 1))
  fi
}

# --- (a) flag inventory vs help fixtures ---
AGENT_FLAGS=(-p --force --trust --workspace --output-format --stream-partial-output --resume --model)
AGY_FLAGS=(--dangerously-skip-permissions --output-format --conversation --model -p)

flag_in_fixture() {
  local fixture=$1 flag=$2
  grep -qE -- "(^|[[:space:]])${flag}([[:space:]/,]|$)" "$fixture"
}

for f in "${AGENT_FLAGS[@]}"; do
  if flag_in_fixture "$FIXTURES/agent-help.txt" "$f"; then
    report "agent flag $f in agent-help.txt" 0
  else
    report "agent flag $f in agent-help.txt" 1 "FAIL: execute-via-cursor uses $f, absent from fixtures/agent-help.txt"
  fi
done

for f in "${AGY_FLAGS[@]}"; do
  if flag_in_fixture "$FIXTURES/agy-help.txt" "$f"; then
    report "agy flag $f in agy-help.txt" 0
  else
    report "agy flag $f in agy-help.txt" 1 "FAIL: execute-via-agy uses $f, absent from fixtures/agy-help.txt"
  fi
done

# Guard: flags actually used on the SKILL.md CLI invocations must be in the
# arrays above (and so get checked against the fixtures). Scans fenced code
# blocks only; a command starts at a line beginning `agent`/`agy` (optionally
# after `cd … &&`) and continues across trailing-backslash lines. Quoted
# strings are dropped so prose inside prompts is not read as flags.
extract_skill_flags() {
  awk -v cmd="$2" '
    /^[[:space:]]*```/ { fence = !fence; cont = 0; next }
    !fence { next }
    {
      line = $0
      if (!cont) {
        # Command at any word position: `cd x && agent`, `timeout 5 agent`, `$(agent`.
        if (!match(line, "(^|[[:space:];&|(])" cmd "([[:space:]]|$)")) next
        line = substr(line, RSTART)
      }
      cont = ($0 ~ /\\[[:space:]]*$/)
      gsub(/"[^"]*"/, "", line)
      gsub(/\047[^\047]*\047/, "", line)
      n = split(line, tok, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        # Normalise `[--flag]`, `--flag=value`, `--flag)` to `--flag`.
        t = tok[i]; sub(/^[[(]+/, "", t); sub(/=.*$/, "", t); sub(/[])]+$/, "", t)
        if (t ~ /^--?[A-Za-z][A-Za-z0-9-]*$/) print t
      }
    }
  ' "$1" | sort -u
}

check_skill_flags() {
  local label=$1 skill=$2 cmd=$3 arr_name=$4 flag known k
  local -a known_flags
  eval "known_flags=(\"\${${arr_name}[@]}\")"
  local extracted
  extracted=$(extract_skill_flags "$skill" "$cmd")
  if [[ -z "$extracted" ]]; then
    report "$label SKILL.md flags extracted" 1 "no $cmd invocation flags found in $skill"
    return
  fi
  while IFS= read -r flag; do
    known=1
    for k in "${known_flags[@]}"; do
      [[ "$k" == "$flag" ]] && known=0
    done
    if [[ "$known" -eq 0 ]]; then
      report "$label SKILL.md flag $flag covered by flag array" 0
    else
      report "$label SKILL.md flag $flag covered by flag array" 1 "FAIL: $skill uses $flag; add it to the flag array so it is checked against the fixture"
    fi
  done <<<"$extracted"
}

check_skill_flags cursor "$CURSOR_SKILL" agent AGENT_FLAGS
check_skill_flags agy "$AGY_SKILL" agy AGY_FLAGS

# Negative: fixture with --conversation removed must fail the agy check.
tmp_help=$(mktemp)
sed '/--conversation/d' "$FIXTURES/agy-help.txt" >"$tmp_help"
if flag_in_fixture "$tmp_help" --conversation; then
  report "stripped agy-help lacks --conversation" 1 "still matched"
else
  report "stripped agy-help lacks --conversation" 0
fi
rm -f "$tmp_help"

# --- (c) predicate-string guard (skill ↔ test) ---
assert_skill_contains() {
  local skill=$1 needle=$2 label=$3
  if grep -qF -- "$needle" "$skill"; then
    report "skill predicate: $label" 0
  else
    report "skill predicate: $label" 1 "missing from $(basename "$(dirname "$skill")")/SKILL.md: $needle"
  fi
}

assert_skill_contains "$CURSOR_SKILL" 'select(.type=="system" and .subtype=="init").session_id' 'cursor init.session_id'
assert_skill_contains "$CURSOR_SKILL" "jq -c '{type,subtype,is_error}'" 'cursor result shape'
assert_skill_contains "$AGY_SKILL" 'select(.event=="init").conversation_id' 'agy init.conversation_id'
assert_skill_contains "$AGY_SKILL" 'finished_reason: (.finished_reason // .result.finished_reason)' 'agy finished_reason'
assert_skill_contains "$AGY_SKILL" 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' 'agy stderr grep'

# --- (b) stub CLI + NDJSON fixtures ---
work=$(mktemp -d "${TMPDIR:-/tmp}/delegate-contract.XXXXXX")
mkdir -p "$work/bin" "$work/ndjson" "$work/err"

# NDJSON cases
cat >"$work/ndjson/cursor-success.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-success"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/ndjson/cursor-missing-init.ndjson" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/ndjson/agy-success.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-success"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

cat >"$work/ndjson/agy-soft-deny.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-deny"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

cat >"$work/ndjson/agy-print-timeout.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-timeout"}
{"event":"result","status":"SUCCESS","finished_reason":"print_timeout"}
EOF

cat >"$work/ndjson/agy-missing-init.ndjson" <<'EOF'
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

# Stub agent: first arg after options is ignored; MODE via env CONTRACT_STUB_MODE
cat >"$work/bin/agent" <<'EOF'
#!/usr/bin/env bash
mode=${CONTRACT_STUB_MODE:-success}
case "$mode" in
  success) cat "$CONTRACT_NDJSON_DIR/cursor-success.ndjson" ;;
  missing_init) cat "$CONTRACT_NDJSON_DIR/cursor-missing-init.ndjson" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
exit 0
EOF

cat >"$work/bin/agy" <<'EOF'
#!/usr/bin/env bash
mode=${CONTRACT_STUB_MODE:-success}
case "$mode" in
  success) cat "$CONTRACT_NDJSON_DIR/agy-success.ndjson" ;;
  soft_deny)
    cat "$CONTRACT_NDJSON_DIR/agy-soft-deny.ndjson"
    echo "permission denied: run_command soft-denied" >&2
    ;;
  print_timeout) cat "$CONTRACT_NDJSON_DIR/agy-print-timeout.ndjson" ;;
  missing_init) cat "$CONTRACT_NDJSON_DIR/agy-missing-init.ndjson" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
exit 0
EOF
chmod +x "$work/bin/agent" "$work/bin/agy"

export CONTRACT_NDJSON_DIR="$work/ndjson"
export PATH="$work/bin:$PATH"

# Predicates mirroring the skills (same jq/grep).
classify_cursor() {
  # classify_cursor <ndjson> <exit> → prints PASS|FAIL:<reason>
  local ndjson=$1 exit_code=$2
  local session_id result
  session_id=$(jq -r 'select(.type=="system" and .subtype=="init").session_id' "$ndjson" | head -1)
  result=$(tail -1 "$ndjson" | jq -c '{type,subtype,is_error}')
  if [[ -z "$session_id" || "$session_id" == "null" ]]; then
    echo "FAIL:no init.session_id"
    return
  fi
  if [[ "$exit_code" != "0" ]]; then
    echo "FAIL:exit $exit_code"
    return
  fi
  if [[ "$result" != '{"type":"result","subtype":"success","is_error":false}' ]]; then
    echo "FAIL:result $result"
    return
  fi
  echo PASS
}

classify_agy() {
  local ndjson=$1 exit_code=$2 err=$3
  local conv summary status finished
  conv=$(jq -r 'select(.event=="init").conversation_id' "$ndjson" | head -1)
  summary=$(tail -1 "$ndjson" | jq -c '{event, status: (.status // .result.status), finished_reason: (.finished_reason // .result.finished_reason)}')
  status=$(jq -r '.status // empty' <<<"$summary")
  finished=$(jq -r '.finished_reason // empty' <<<"$summary")
  if [[ -z "$conv" || "$conv" == "null" ]]; then
    echo "FAIL:no init.conversation_id"
    return
  fi
  if [[ "$exit_code" != "0" ]]; then
    echo "FAIL:exit $exit_code"
    return
  fi
  if [[ "$status" != "SUCCESS" ]]; then
    echo "FAIL:status=$status"
    return
  fi
  case "$finished" in
    print_timeout | interrupted | error) echo "FAIL:finished_reason=$finished"; return ;;
  esac
  if grep -qiE 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' "$err" 2>/dev/null; then
    echo "FAIL:stderr soft-deny"
    return
  fi
  echo PASS
}

run_stub_cursor() {
  local mode=$1 out=$2
  export CONTRACT_STUB_MODE=$mode
  local ndjson="$work/out-cursor.ndjson" err="$work/out-cursor.err"
  : >"$err"
  set +e
  agent -p --force --trust --workspace /tmp \
    --output-format stream-json --stream-partial-output \
    "noop" >"$ndjson" 2>"$err"
  local rc=$?
  set -e
  classify_cursor "$ndjson" "$rc" >"$out"
}

run_stub_agy() {
  local mode=$1 out=$2
  export CONTRACT_STUB_MODE=$mode
  local ndjson="$work/out-agy.ndjson" err="$work/out-agy.err"
  : >"$err"
  set +e
  agy --dangerously-skip-permissions --output-format stream-json -p "noop" \
    >"$ndjson" 2>"$err"
  local rc=$?
  set -e
  classify_agy "$ndjson" "$rc" "$err" >"$out"
}

expect_class() {
  local label=$1 got_file=$2 want=$3
  local got
  got=$(cat "$got_file")
  if [[ "$got" == "$want" ]]; then
    report "$label" 0
  else
    report "$label" 1 "want=$want got=$got"
  fi
}

run_stub_cursor success "$work/class.txt"
expect_class "cursor stub success → PASS" "$work/class.txt" PASS

run_stub_cursor missing_init "$work/class.txt"
expect_class "cursor stub missing init → FAIL" "$work/class.txt" "FAIL:no init.session_id"

run_stub_agy success "$work/class.txt"
expect_class "agy stub success → PASS" "$work/class.txt" PASS

run_stub_agy soft_deny "$work/class.txt"
expect_class "agy stub soft-deny → FAIL" "$work/class.txt" "FAIL:stderr soft-deny"

run_stub_agy print_timeout "$work/class.txt"
expect_class "agy stub print_timeout → FAIL" "$work/class.txt" "FAIL:finished_reason=print_timeout"

run_stub_agy missing_init "$work/class.txt"
expect_class "agy stub missing init → FAIL" "$work/class.txt" "FAIL:no init.conversation_id"

echo "1..$n"
if [[ "$fails" -ne 0 ]]; then
  echo "FAILED: $fails/$n" >&2
  exit 1
fi
echo "PASS: $n/$n"
