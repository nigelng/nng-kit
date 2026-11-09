#!/usr/bin/env bash
# Fixture tests for delegate-verdict.sh. NDJSON/export bodies are copied from
# contract.sh. Run with bash. Do not modify contract.sh or its fixtures.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/delegate-verdict.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-verdict.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

fails=0
LAST_OUT=""
LAST_ERR=""
LAST_RC=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  fails=$((fails + 1))
  printf 'FAIL: %s\n' "$1"
  printf '  rc=%s\n' "$LAST_RC"
  printf '  stdout=%s\n' "$LAST_OUT"
  printf '  stderr=%s\n' "$LAST_ERR"
}

run_cmd() {
  local err
  err=$(mktemp)
  set +e
  LAST_OUT=$("$@" 2>"$err")
  LAST_RC=$?
  set -e
  LAST_ERR=$(cat "$err")
  rm -f "$err"
}

assert_jq() {
  local label=$1 filter=$2
  if [[ "$LAST_RC" -ne 0 ]]; then
    fail "$label (rc $LAST_RC)"
    return
  fi
  if jq -e "$filter" >/dev/null <<<"$LAST_OUT"; then
    pass "$label"
  else
    fail "$label (jq $filter)"
  fi
}

repo="$work/repo"
mkdir -p "$repo/.claude/tmp"
tmp="$repo/.claude/tmp"

reset_run() {
  rm -f "$tmp"/exec-run-* "$tmp"/exec-*-questions.md
}

# Fixtures copied from contract.sh.
cat >"$work/cursor-success.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-success"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}
{"type":"result","subtype":"success","is_error":false}
EOF
cat >"$work/cursor-missing-init.ndjson" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"result","subtype":"success","is_error":false}
EOF
cat >"$work/cursor-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-model","model":"Grok 4.7 256K High"}
{"type":"result","subtype":"success","is_error":false}
EOF
cat >"$work/cursor-no-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-nomodel"}
{"type":"result","subtype":"success","is_error":false}
EOF
cat >"$work/cursor-null-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-nullmodel","model":null}
{"type":"result","subtype":"success","is_error":false}
EOF
cat >"$work/cursor-bad-model.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-badmodel","model":"Grok\t$(touch contract-pwned)"}
{"type":"result","subtype":"success","is_error":false}
EOF
long_model=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf "a" }')
printf '{"type":"system","subtype":"init","session_id":"sess-longmodel","model":"%s"}\n{"type":"result","subtype":"success","is_error":false}\n' "$long_model" >"$work/cursor-long-model.ndjson"
cat >"$work/cursor-bad-session.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"x; rm -rf /"}
{"type":"result","subtype":"success","is_error":false}
EOF

cat >"$work/agy-success.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-success"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-soft-deny.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-deny"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-print-timeout.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-timeout"}
{"event":"result","status":"SUCCESS","finished_reason":"print_timeout"}
EOF
cat >"$work/agy-missing-init.ndjson" <<'EOF'
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-model","model":"gemini-4-argon-medium"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-nested-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nested","init":{"model":"gemini-4-argon-medium"}}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-no-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nomodel"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-null-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-nullmodel","model":null}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
cat >"$work/agy-bad-model.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-badmodel","model":"Gemini\t$(touch contract-pwned)"}
{"event":"result","status":"SUCCESS","finished_reason":"completed"}
EOF
printf '{"event":"init","conversation_id":"conv-longmodel","model":"%s"}\n{"event":"result","status":"SUCCESS","finished_reason":"completed"}\n' "$long_model" >"$work/agy-long-model.ndjson"

cat >"$work/devin-success.json" <<'EOF'
{"session_id":"sess-devin-success","steps":[{"source":"user"},{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
EOF
cat >"$work/devin-mismatch.json" <<'EOF'
{"session_id":"sess-devin-mismatch","steps":[{"source":"agent","model_name":"gpt-6-1-terra-low"}]}
EOF
cat >"$work/devin-mixed.json" <<'EOF'
{"session_id":"sess-devin-mixed","steps":[{"source":"user"},{"source":"agent","model_name":"swe-2-high"},{"source":"agent","model_name":"gpt-6-1-terra-low"}]}
EOF
cat >"$work/devin-missing-session.json" <<'EOF'
{"steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
EOF
cat >"$work/devin-bad-session.json" <<'EOF'
{"session_id":"x; rm -rf /","steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"}]}
EOF
cat >"$work/devin-no-model.json" <<'EOF'
{"session_id":"sess-devin-nomodel","steps":[{"source":"user"},{"source":"agent"}]}
EOF
cat >"$work/devin-source-user.json" <<'EOF'
{"session_id":"sess-devin-user","steps":[{"source":"agent","model_name":"gpt-6-1-terra-high"},{"source":"user"}]}
EOF

cursor_case() {
  local label=$1 src=$2 exit_code=$3
  reset_run
  cp "$src" "$tmp/exec-run-cursor-1.ndjson"
  printf '%s\n' "$exit_code" >"$tmp/exec-run-cursor-1.exit"
  : >"$tmp/exec-run-cursor-1.err"
  run_cmd bash "$SCRIPT" cursor "$repo" 1
  assert_jq "$label" "$4"
}

cursor_case "cursor success ok" "$work/cursor-success.ndjson" 0 \
  '.ok == true and .session_id == "sess-success" and .model_resolved == "auto(unresolved)" and .timed_out == false and .questions == false and .reasons == []'
cursor_case "cursor missing init" "$work/cursor-missing-init.ndjson" 0 \
  '.ok == false and .reasons == ["no init.session_id"]'
cursor_case "cursor init model label" "$work/cursor-model.ndjson" 0 \
  '.ok == true and .model_resolved == "Grok 4.7 256K High"'
cursor_case "cursor init model missing" "$work/cursor-no-model.ndjson" 0 \
  '.ok == true and .model_resolved == "auto(unresolved)"'
cursor_case "cursor init model null" "$work/cursor-null-model.ndjson" 0 \
  '.ok == true and .model_resolved == "auto(unresolved)"'
cursor_case "cursor model with tab" "$work/cursor-bad-model.ndjson" 0 \
  '.ok == true and .model_resolved == "auto(unresolved)"'
if [[ -e "$repo/contract-pwned" || -e "$work/contract-pwned" ]]; then
  fail "cursor bad model was not executed"
else
  pass "cursor bad model was not executed"
fi
cursor_case "cursor 200-char model" "$work/cursor-long-model.ndjson" 0 \
  '.ok == true and .model_resolved == "auto(unresolved)"'
cursor_case "bad cursor session id" "$work/cursor-bad-session.ndjson" 0 \
  '.ok == false and .session_id == "" and (.reasons | index("no init.session_id"))'

agy_case() {
  local label=$1 src=$2 exit_code=$3 err_text=$4
  reset_run
  cp "$src" "$tmp/exec-run-agy-1.ndjson"
  printf '%s\n' "$exit_code" >"$tmp/exec-run-agy-1.exit"
  printf '%s\n' "$err_text" >"$tmp/exec-run-agy-1.err"
  run_cmd bash "$SCRIPT" agy "$repo" 1
  assert_jq "$label" "$5"
}

agy_case "agy success ok" "$work/agy-success.ndjson" 0 "" \
  '.ok == true and .session_id == "conv-success" and .model_resolved == "auto(unresolved)" and .reasons == []'
agy_case "agy soft-deny" "$work/agy-soft-deny.ndjson" 0 "permission denied: run_command soft-denied" \
  '.ok == false and .reasons == ["stderr soft-deny"]'
agy_case "agy print_timeout" "$work/agy-print-timeout.ndjson" 0 "" \
  '.ok == false and .reasons == ["finished_reason=print_timeout"]'
agy_case "agy missing init" "$work/agy-missing-init.ndjson" 0 "" \
  '.ok == false and .reasons == ["no init.conversation_id"]'
agy_case "agy init model" "$work/agy-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "gemini-4-argon-medium"'
agy_case "agy init.model" "$work/agy-nested-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "gemini-4-argon-medium"'
agy_case "agy init model missing" "$work/agy-no-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "auto(unresolved)"'
agy_case "agy init model null" "$work/agy-null-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "auto(unresolved)"'
agy_case "agy model with tab" "$work/agy-bad-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "auto(unresolved)"'
agy_case "agy 200-char model" "$work/agy-long-model.ndjson" 0 "" \
  '.ok == true and .model_resolved == "auto(unresolved)"'

devin_case() {
  local label=$1 src=$2 exit_code=$3 slug=$4
  reset_run
  if [[ -n "$src" ]]; then
    cp "$src" "$tmp/exec-run-devin-1.json"
  fi
  printf '%s\n' "$exit_code" >"$tmp/exec-run-devin-1.exit"
  run_cmd bash "$SCRIPT" devin "$repo" 1 "$slug"
  assert_jq "$label" "$5"
}

devin_case "devin success ok" "$work/devin-success.json" 0 gpt-6-1-terra-high \
  '.ok == true and .session_id == "sess-devin-success" and .model_resolved == "gpt-6-1-terra-high" and .reasons == []'
devin_case "devin exit 1 no export" "" 1 gpt-6-1-terra-high \
  '.ok == false and .reasons == ["exit 1","no export"] and .model_resolved == "auto(unresolved)"'
devin_case "devin model mismatch" "$work/devin-mismatch.json" 0 gpt-6-1-terra-high \
  '.ok == false and .reasons == ["fallback: model mismatch gpt-6-1-terra-high→gpt-6-1-terra-low"]'
devin_case "devin mixed models" "$work/devin-mixed.json" 0 swe-2-high \
  '.ok == false and .model_resolved == "gpt-6-1-terra-low,swe-2-high" and .reasons == ["fallback: model mismatch swe-2-high→gpt-6-1-terra-low,swe-2-high"]'
devin_case "devin missing session_id" "$work/devin-missing-session.json" 0 gpt-6-1-terra-high \
  '.ok == false and .session_id == "" and .reasons == ["no session_id"]'
devin_case "devin invalid session_id" "$work/devin-bad-session.json" 0 gpt-6-1-terra-high \
  '.ok == false and .session_id == "" and .reasons == ["no session_id"]'
devin_case "devin no step model" "$work/devin-no-model.json" 0 gpt-6-1-terra-high \
  '.ok == false and .model_resolved == "auto(unresolved)" and .reasons == ["no resolved model"]'
devin_case "devin last step source user" "$work/devin-source-user.json" 0 gpt-6-1-terra-high \
  '.ok == false and .reasons == ["source=user"]'

# timeout 124 → timed_out, not ok
reset_run
cp "$work/cursor-success.ndjson" "$tmp/exec-run-cursor-2.ndjson"
printf '%s\n' 124 >"$tmp/exec-run-cursor-2.exit"
run_cmd bash "$SCRIPT" cursor "$repo" 2
assert_jq "timeout 124" '.ok == false and .timed_out == true and .reasons == ["exit 124","timeout ceiling"]'

reset_run
cp "$work/cursor-success.ndjson" "$tmp/exec-run-cursor-2.ndjson"
printf '%s\n' 137 >"$tmp/exec-run-cursor-2.exit"
run_cmd bash "$SCRIPT" cursor "$repo" 2
assert_jq "timeout 137" '.ok == false and .timed_out == true and (.reasons | index("timeout ceiling"))'

# questions file is independent of ok
reset_run
cp "$work/cursor-success.ndjson" "$tmp/exec-run-cursor-1.ndjson"
printf '%s\n' 0 >"$tmp/exec-run-cursor-1.exit"
printf '%s\n' "what now?" >"$tmp/exec-cursor-questions.md"
run_cmd bash "$SCRIPT" cursor "$repo" 1
assert_jq "questions file sets questions" '.ok == true and .questions == true'

run_cmd bash "$SCRIPT" devin "$repo" 1
if [[ "$LAST_RC" -eq 2 ]]; then
  pass "devin without slug is usage"
else
  fail "devin without slug is usage"
fi

printf 'PASS/FAIL summary: %s failed\n' "$fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
