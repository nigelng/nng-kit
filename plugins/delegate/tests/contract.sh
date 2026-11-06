#!/usr/bin/env bash
# Delegate CLI contract tests (no login).
# (a) every flag the SKILL.md files invoke exists in fixtures/{agent,agy,devin}-help.txt
# (b) PATH-shim stubs emit fixture NDJSON; documented predicates classify correctly
# (c) guard: SKILL.md still contains the exact predicate strings the stubs exercise
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
CURSOR_SKILL="$TESTS_DIR/../skills/execute-via-cursor/SKILL.md"
AGY_SKILL="$TESTS_DIR/../skills/execute-via-agy/SKILL.md"
DEVIN_SKILL="$TESTS_DIR/../skills/execute-via-devin/SKILL.md"

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

# Cursor sections always run. agy flag-inventory, skill-flag, and stub
# sections run only when AGY_ENABLED is exactly 1. The parked-refusal
# predicate always runs.
agy_gate=0
if [[ "${AGY_ENABLED:-}" == "1" ]]; then
  agy_gate=1
fi

skip_agy() {
  n=$((n + 1))
  echo "ok $n - $1 # skip agy (AGY_ENABLED unset)"
}

# --- (a) flag inventory vs help fixtures ---
AGENT_FLAGS=(-p --force --trust --workspace --output-format --stream-partial-output --resume --model)
AGY_FLAGS=(--dangerously-skip-permissions --output-format --conversation --model -p)
DEVIN_FLAGS=(--model --permission-mode --respect-workspace-trust --export --print --resume)

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

if [[ "$agy_gate" -eq 1 ]]; then
  for f in "${AGY_FLAGS[@]}"; do
    if flag_in_fixture "$FIXTURES/agy-help.txt" "$f"; then
      report "agy flag $f in agy-help.txt" 0
    else
      report "agy flag $f in agy-help.txt" 1 "FAIL: execute-via-agy uses $f, absent from fixtures/agy-help.txt"
    fi
  done
else
  for f in "${AGY_FLAGS[@]}"; do
    skip_agy "agy flag $f in agy-help.txt"
  done
fi

for f in "${DEVIN_FLAGS[@]}"; do
  if flag_in_fixture "$FIXTURES/devin-help.txt" "$f"; then
    report "devin flag $f in devin-help.txt" 0
  else
    report "devin flag $f in devin-help.txt" 1 "FAIL: execute-via-devin uses $f, absent from fixtures/devin-help.txt"
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
if [[ "$agy_gate" -eq 1 ]]; then
  check_skill_flags agy "$AGY_SKILL" agy AGY_FLAGS
else
  skip_agy "agy SKILL.md flags"
fi
check_skill_flags devin "$DEVIN_SKILL" devin DEVIN_FLAGS

# Negative: fixture with --conversation removed must fail the agy check.
if [[ "$agy_gate" -eq 1 ]]; then
  tmp_help=$(mktemp)
  sed '/--conversation/d' "$FIXTURES/agy-help.txt" >"$tmp_help"
  if flag_in_fixture "$tmp_help" --conversation; then
    report "stripped agy-help lacks --conversation" 1 "still matched"
  else
    report "stripped agy-help lacks --conversation" 0
  fi
  rm -f "$tmp_help"
else
  skip_agy "stripped agy-help lacks --conversation"
fi

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
assert_skill_contains "$CURSOR_SKILL" "jq -r 'select(.type==\"system\" and .subtype==\"init\").model // empty' .claude/tmp/exec-run-cursor-<n>.ndjson | head -1" 'cursor init.model'
assert_skill_contains "$CURSOR_SKILL" 'auto(unresolved)' 'cursor auto(unresolved)'
assert_skill_contains "$CURSOR_SKILL" "re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'" 'cursor model regex'
assert_skill_contains "$CURSOR_SKILL" "[[ \"\$model\" =~ \$re && \"\$model\" != null ]] || model='auto(unresolved)'" 'cursor model regex check'
assert_skill_contains "$AGY_SKILL" 'agy is parked; set AGY_ENABLED=1 to re-enable' 'agy parked refusal'
assert_skill_contains "$AGY_SKILL" 'select(.event=="init").conversation_id' 'agy init.conversation_id'
assert_skill_contains "$AGY_SKILL" 'finished_reason: (.finished_reason // .result.finished_reason)' 'agy finished_reason'
assert_skill_contains "$AGY_SKILL" 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' 'agy stderr grep'
assert_skill_contains "$AGY_SKILL" "jq -r 'select(.event==\"init\") | (.model // .init.model // empty)' .claude/tmp/exec-run-agy-<n>.ndjson | head -1" 'agy init.model'
assert_skill_contains "$AGY_SKILL" 'auto(unresolved)' 'agy auto(unresolved)'
assert_skill_contains "$AGY_SKILL" "re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'" 'agy model regex'
assert_skill_contains "$AGY_SKILL" "[[ \"\$model\" =~ \$re && \"\$model\" != null ]] || model='auto(unresolved)'" 'agy model regex check'
assert_skill_contains "$DEVIN_SKILL" "jq -r '.steps[-1].source'" 'devin last step source'
assert_skill_contains "$DEVIN_SKILL" "jq -r '.session_id'" 'devin session_id'
assert_skill_contains "$DEVIN_SKILL" "jq -r '[.steps[].model_name // empty] | unique | .[]'" 'devin step model_name'
assert_skill_contains "$DEVIN_SKILL" 'model_resolved' 'devin model_resolved'
assert_skill_contains "$DEVIN_SKILL" '[[ ${#models[@]} -eq 1 && "$model_resolved" == "$slug" ]]' 'devin single-model count check'
assert_skill_contains "$DEVIN_SKILL" 'auto(unresolved)' 'devin auto(unresolved)'
assert_skill_contains "$DEVIN_SKILL" "re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'" 'devin model regex'
assert_skill_contains "$DEVIN_SKILL" "[[ \"\$model\" =~ \$re && \"\$model\" != null ]] || model='auto(unresolved)'" 'devin model regex check'
assert_skill_contains "$DEVIN_SKILL" '[[ "$session_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]' 'devin session_id regex'
assert_skill_contains "$DEVIN_SKILL" '[[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]]' 'devin slug regex'
assert_skill_contains "$DEVIN_SKILL" 'Refuse `adaptive`' 'devin refuses adaptive'
assert_skill_contains "$DEVIN_SKILL" '`fusion-*`' 'devin refuses fusion-*'
assert_skill_contains "$DEVIN_SKILL" '**exactly** in `devin models`' 'devin exact-match requirement'
assert_skill_contains "$DEVIN_SKILL" '-- "Read .claude/tmp/exec-devin-brief.md' 'devin interactive prompt after --'
assert_skill_contains "$DEVIN_SKILL" 'no resolved model' 'devin empty model list fails'
assert_skill_contains "$DEVIN_SKILL" '--export=' 'devin --export= form'
assert_skill_contains "$DEVIN_SKILL" '--print=' 'devin --print= form'
assert_skill_contains "$DEVIN_SKILL" '--respect-workspace-trust=false' 'devin --respect-workspace-trust=false form'
assert_skill_contains "$DEVIN_SKILL" '--resume=' 'devin --resume= form'
assert_skill_contains "$DEVIN_SKILL" '-- "Read .claude/tmp/exec-devin-fix-<round>.md' 'devin safe/no-force fix prompt after --'
assert_skill_contains "$DEVIN_SKILL" "find .claude/tmp -maxdepth 1 -type f -name 'exec-run-devin-*' -delete" 'devin run files deleted after verdict'
assert_skill_contains "$DEVIN_SKILL" '--respect-workspace-trust=false` (Devin'"'"'s workspace-trust check skipped)' 'devin trust warning'

# Fenced-block guard: in the fenced commands these value flags must use the
# `=` form. Prose and the flags table also mention `--export=` etc., so the
# whole-file guards above cannot catch a fenced command drifting to the space
# form. Same fence handling as extract_skill_flags; quoted strings are dropped
# and backslash-continuation lines are scanned like any other line, so a flag
# at the end of a line (`--export \`) is a violation too.
devin_space_form_flags() {
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    !fence { next }
    {
      line = $0
      gsub(/"[^"]*"/, "", line)
      gsub(/\047[^\047]*\047/, "", line)
      n = split(line, tok, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = tok[i]
        # A token that is exactly the bare flag has whitespace or EOL after it.
        if (t == "--print" || t == "--export" || t == "--resume" || t == "--respect-workspace-trust") print NR ": " t
      }
    }
  ' "$1"
}

space_form=$(devin_space_form_flags "$DEVIN_SKILL")
if [[ -z "$space_form" ]]; then
  report "devin fenced commands use = form for value flags" 0
else
  report "devin fenced commands use = form for value flags" 1 "space form in fenced block: $(printf '%s' "$space_form" | tr '\n' ' ')"
fi

# Negative: mutate one fenced occurrence to the space form; the check must fail.
devin_space_form_negative() {
  local label=$1 from=$2 to=$3 tmp_skill
  tmp_skill=$(mktemp)
  # Only fenced lines are rewritten (first match), so prose is untouched.
  awk -v from="$from" -v to="$to" '
    /^[[:space:]]*```/ { fence = !fence }
    fence && !done && (i = index($0, from)) { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); done = 1 }
    { print }
    END { exit done ? 0 : 3 }
  ' "$DEVIN_SKILL" >"$tmp_skill"
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    report "$label" 1 "no fenced $from found to mutate"
  elif [[ -n "$(devin_space_form_flags "$tmp_skill")" ]]; then
    report "$label" 0
  else
    report "$label" 1 "check did not flag fenced $to"
  fi
  rm -f "$tmp_skill"
}
devin_space_form_negative "negative: fenced --export= to space form is flagged" '--export=' '--export '
devin_space_form_negative "negative: fenced --respect-workspace-trust=false to space form is flagged" '--respect-workspace-trust=false' '--respect-workspace-trust false'

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

cat >"$work/ndjson/cursor-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-model","model":"Grok 4.7 256K High"}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/ndjson/cursor-no-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-nomodel"}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/ndjson/cursor-null-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-nullmodel","model":null}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/ndjson/agy-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-model","model":"gemini-4-argon-medium"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

cat >"$work/ndjson/agy-nested-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nested","init":{"model":"gemini-4-argon-medium"}}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

cat >"$work/ndjson/agy-no-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nomodel"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

cat >"$work/ndjson/agy-null-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nullmodel","model":null}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF

# Stub agent: first arg after options is ignored; MODE via env CONTRACT_STUB_MODE
cat >"$work/bin/agent" <<'EOF'
#!/usr/bin/env bash
mode=${CONTRACT_STUB_MODE:-success}
case "$mode" in
  success) cat "$CONTRACT_NDJSON_DIR/cursor-success.ndjson" ;;
  missing_init) cat "$CONTRACT_NDJSON_DIR/cursor-missing-init.ndjson" ;;
  model) cat "$CONTRACT_NDJSON_DIR/cursor-model.ndjson" ;;
  no_model) cat "$CONTRACT_NDJSON_DIR/cursor-no-model.ndjson" ;;
  null_model) cat "$CONTRACT_NDJSON_DIR/cursor-null-model.ndjson" ;;
  bad_model) cat "$CONTRACT_NDJSON_DIR/cursor-bad-model.ndjson" ;;
  long_model) cat "$CONTRACT_NDJSON_DIR/cursor-long-model.ndjson" ;;
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
  model) cat "$CONTRACT_NDJSON_DIR/agy-model.ndjson" ;;
  nested_model) cat "$CONTRACT_NDJSON_DIR/agy-nested-model.ndjson" ;;
  no_model) cat "$CONTRACT_NDJSON_DIR/agy-no-model.ndjson" ;;
  null_model) cat "$CONTRACT_NDJSON_DIR/agy-null-model.ndjson" ;;
  bad_model) cat "$CONTRACT_NDJSON_DIR/agy-bad-model.ndjson" ;;
  long_model) cat "$CONTRACT_NDJSON_DIR/agy-long-model.ndjson" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
exit 0
EOF
cat >"$work/ndjson/cursor-bad-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-badmodel","model":"Grok\t$(touch contract-pwned)"}
{"type":"result","subtype":"success","is_error":false}
EOF
long_model=$(printf 'a%.0s' $(seq 1 200))
printf '{"type":"system","subtype":"init","session_id":"sess-longmodel","model":"%s"}\n{"type":"result","subtype":"success","is_error":false}\n' "$long_model" >"$work/ndjson/cursor-long-model.ndjson"
cat >"$work/ndjson/agy-bad-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-badmodel","model":"Gemini\t$(touch contract-pwned)"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
printf '{"event":"init","conversation_id":"conv-longmodel","model":"%s"}\n{"event":"result","status":"SUCCESS","finished_reason":"completed"}\n' "$long_model" >"$work/ndjson/agy-long-model.ndjson"

cat >"$work/bin/devin" <<'EOF'
#!/usr/bin/env bash
mode=${CONTRACT_STUB_MODE:-success}
export_path=""
for arg in "$@"; do
  case "$arg" in
    --export=*) export_path=${arg#--export=} ;;
  esac
done
write_export() {
  mkdir -p "$(dirname "$export_path")"
  cat >"$export_path"
}
case "$mode" in
  success)
    write_export <<'JSON'
{"session_id":"sess-devin-success","steps":[{"source":"user"},{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
JSON
    exit 0
    ;;
  no_export) exit 1 ;;
  model_mismatch)
    write_export <<'JSON'
{"session_id":"sess-devin-mismatch","steps":[{"source":"agent","model_name":"gpt-6-1-terra-low"}]}
JSON
    exit 0
    ;;
  mixed_model)
    write_export <<'JSON'
{"session_id":"sess-devin-mixed","steps":[{"source":"user"},{"source":"agent","model_name":"swe-2-high"},{"source":"agent","model_name":"gpt-6-1-terra-low"}]}
JSON
    exit 0
    ;;
  missing_session)
    write_export <<'JSON'
{"steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
JSON
    exit 0
    ;;
  bad_session)
    write_export <<'JSON'
{"session_id":"x; rm -rf /","steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
JSON
    exit 0
    ;;
  no_model)
    write_export <<'JSON'
{"session_id":"sess-devin-nomodel","steps":[{"source":"user"},{"source":"agent"}]}
JSON
    exit 0
    ;;
  source_user)
    write_export <<'JSON'
{"session_id":"sess-devin-user","steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"},{"source":"user"}]}
JSON
    exit 0
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/bin/agent" "$work/bin/agy" "$work/bin/devin"

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

# devin_models <export>: sets models (unique step model_names) and model_resolved
# (validated values joined with ","). Mirrors execute-via-devin Step 6 item 4.
devin_models() {
  local export=$1 line model re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
  local resolved=()
  models=()
  while IFS= read -r line; do models+=("$line"); done < <(jq -r '[.steps[].model_name // empty] | unique | .[]' "$export")
  for model in ${models[@]+"${models[@]}"}; do
    [[ "$model" =~ $re && "$model" != null ]] || model='auto(unresolved)'
    resolved+=("$model")
  done
  model_resolved=$(IFS=,; printf '%s' "${resolved[*]-}")
  [[ ${#models[@]} -gt 0 ]] || model_resolved='auto(unresolved)'
}

classify_devin() {
  # classify_devin <export> <exit> <requested-slug> → PASS or FAIL:<reason>
  # jq programs match execute-via-devin Step 6.
  local export=$1 exit_code=$2 requested=$3
  if [[ "$exit_code" != "0" || ! -f "$export" ]]; then
    local why=()
    [[ "$exit_code" == "0" ]] || why+=("exit $exit_code")
    [[ -f "$export" ]] || why+=("no export")
    echo "FAIL:${why[*]}"
    return
  fi
  local session_id source
  session_id=$(jq -r '.session_id' "$export")
  source=$(jq -r '.steps[-1].source' "$export")
  if ! [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || [[ "$session_id" == "null" ]]; then
    echo "FAIL:no session_id"
    return
  fi
  if [[ "$source" != "agent" ]]; then
    echo "FAIL:source=$source"
    return
  fi
  devin_models "$export"
  if [[ "${#models[@]}" -eq 0 ]]; then
    echo "FAIL:no resolved model"
    return
  fi
  if [[ "${#models[@]}" -ne 1 || "$model_resolved" != "$requested" ]]; then
    echo "FAIL:fallback: model mismatch ${requested}→${model_resolved}"
    return
  fi
  echo PASS
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

run_stub_devin() {
  local mode=$1 out=$2 slug=${3:-gpt-6-1-terra-high}
  export CONTRACT_STUB_MODE=$mode
  local export_path="$work/out-devin.json" err="$work/out-devin.err"
  rm -f "$export_path"
  : >"$err"
  set +e
  devin --model "$slug" --permission-mode dangerous \
    --respect-workspace-trust=false \
    --export="$export_path" --print="noop" \
    >"$work/out-devin.out" 2>"$err"
  local rc=$?
  set -e
  classify_devin "$export_path" "$rc" "$slug" >"$out"
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

# model_resolved mirrors Step 6: the jq value verbatim when it matches the
# allowed pattern, otherwise auto(unresolved) (nothing, null, a control char,
# shell metacharacters, or over 64 chars). Does not change PASS/FAIL.
resolve_model() {
  local model=$1 re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
  [[ "$model" =~ $re && "$model" != null ]] || model='auto(unresolved)'
  printf '%s\n' "$model"
}

cursor_model_resolved() {
  local ndjson=$1 raw
  raw=$(jq -r 'select(.type=="system" and .subtype=="init").model // empty' "$ndjson" | head -1)
  resolve_model "$raw"
}

agy_model_resolved() {
  local ndjson=$1 raw
  raw=$(jq -r 'select(.event=="init") | (.model // .init.model // empty)' "$ndjson" | head -1)
  resolve_model "$raw"
}

devin_model_resolved() {
  local export=$1 raw
  if [[ ! -f "$export" ]]; then
    resolve_model ""
    return
  fi
  devin_models "$export"
  printf '%s\n' "$model_resolved"
}

run_stub_cursor success "$work/class.txt"
expect_class "cursor stub success → PASS" "$work/class.txt" PASS

run_stub_cursor missing_init "$work/class.txt"
expect_class "cursor stub missing init → FAIL" "$work/class.txt" "FAIL:no init.session_id"

run_stub_cursor model "$work/class.txt"
cursor_model_resolved "$work/out-cursor.ndjson" >"$work/model.txt"
expect_class "cursor stub init model → label" "$work/model.txt" "Grok 4.7 256K High"

run_stub_cursor no_model "$work/class.txt"
cursor_model_resolved "$work/out-cursor.ndjson" >"$work/model.txt"
expect_class "cursor stub init model missing → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor null_model "$work/class.txt"
cursor_model_resolved "$work/out-cursor.ndjson" >"$work/model.txt"
expect_class "cursor stub init model null → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor bad_model "$work/class.txt"
cursor_model_resolved "$work/out-cursor.ndjson" >"$work/model.txt"
expect_class "cursor stub model with tab and \$(...) → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor long_model "$work/class.txt"
cursor_model_resolved "$work/out-cursor.ndjson" >"$work/model.txt"
expect_class "cursor stub 200-char model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

if [[ "$agy_gate" -eq 1 ]]; then
  run_stub_agy success "$work/class.txt"
  expect_class "agy stub success → PASS" "$work/class.txt" PASS

  run_stub_agy soft_deny "$work/class.txt"
  expect_class "agy stub soft-deny → FAIL" "$work/class.txt" "FAIL:stderr soft-deny"

  run_stub_agy print_timeout "$work/class.txt"
  expect_class "agy stub print_timeout → FAIL" "$work/class.txt" "FAIL:finished_reason=print_timeout"

  run_stub_agy missing_init "$work/class.txt"
  expect_class "agy stub missing init → FAIL" "$work/class.txt" "FAIL:no init.conversation_id"

  run_stub_agy model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub init model → value" "$work/model.txt" "gemini-4-argon-medium"

  run_stub_agy nested_model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub init.model → value" "$work/model.txt" "gemini-4-argon-medium"

  run_stub_agy no_model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub init model missing → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

  run_stub_agy null_model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub init model null → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

  run_stub_agy bad_model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub model with tab and \$(...) → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

  run_stub_agy long_model "$work/class.txt"
  agy_model_resolved "$work/out-agy.ndjson" >"$work/model.txt"
  expect_class "agy stub 200-char model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"
else
  skip_agy "agy stub success → PASS"
  skip_agy "agy stub soft-deny → FAIL"
  skip_agy "agy stub print_timeout → FAIL"
  skip_agy "agy stub missing init → FAIL"
  skip_agy "agy stub init model → value"
  skip_agy "agy stub init.model → value"
  skip_agy "agy stub init model missing → auto(unresolved)"
  skip_agy "agy stub init model null → auto(unresolved)"
  skip_agy "agy stub model with tab and \$(...) → auto(unresolved)"
  skip_agy "agy stub 200-char model → auto(unresolved)"
fi

run_stub_devin success "$work/class.txt"
expect_class "devin stub success → PASS" "$work/class.txt" PASS
devin_model_resolved "$work/out-devin.json" >"$work/model.txt"
expect_class "devin stub model_name → model_resolved" "$work/model.txt" "gpt-6-1-terra-high"

run_stub_devin no_export "$work/class.txt"
expect_class "devin stub exit 1 with no export → FAIL" "$work/class.txt" "FAIL:exit 1 no export"

run_stub_devin model_mismatch "$work/class.txt"
expect_class "devin stub model mismatch → FAIL" "$work/class.txt" "FAIL:fallback: model mismatch gpt-6-1-terra-high→gpt-6-1-terra-low"

run_stub_devin mixed_model "$work/class.txt" swe-2-high
expect_class "devin stub mixed step models → FAIL" "$work/class.txt" "FAIL:fallback: model mismatch swe-2-high→gpt-6-1-terra-low,swe-2-high"
devin_model_resolved "$work/out-devin.json" >"$work/model.txt"
expect_class "devin stub mixed step models → joined model_resolved" "$work/model.txt" "gpt-6-1-terra-low,swe-2-high"

run_stub_devin missing_session "$work/class.txt"
expect_class "devin stub missing session_id → FAIL" "$work/class.txt" "FAIL:no session_id"

run_stub_devin bad_session "$work/class.txt"
expect_class "devin stub invalid session_id → FAIL" "$work/class.txt" "FAIL:no session_id"

run_stub_devin no_model "$work/class.txt"
expect_class "devin stub no step model_name → FAIL" "$work/class.txt" "FAIL:no resolved model"
devin_model_resolved "$work/out-devin.json" >"$work/model.txt"
expect_class "devin stub missing model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_devin source_user "$work/class.txt"
expect_class "devin stub last step source user → FAIL" "$work/class.txt" "FAIL:source=user"

echo "1..$n"
if [[ "$fails" -ne 0 ]]; then
  echo "FAILED: $fails/$n" >&2
  exit 1
fi
echo "PASS: $n/$n"
