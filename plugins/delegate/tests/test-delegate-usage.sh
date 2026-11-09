#!/usr/bin/env bash
# Fixture tests for delegate-usage.sh. Run with bash.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/delegate-usage.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-usage.XXXXXX")
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

assert_usage() {
  local label=$1 want_in=$2 want_cached=$3 want_out=$4
  local got_in got_cached got_out
  if [[ "$LAST_RC" -ne 0 ]]; then
    fail "$label (rc $LAST_RC)"
    return
  fi
  got_in=$(jq -r '.tokens_in' <<<"$LAST_OUT")
  got_cached=$(jq -r '.tokens_cached' <<<"$LAST_OUT")
  got_out=$(jq -r '.tokens_out' <<<"$LAST_OUT")
  if [[ "$got_in" == "$want_in" && "$got_cached" == "$want_cached" && "$got_out" == "$want_out" ]]; then
    pass "$label"
  else
    fail "$label (got in=$got_in cached=$got_cached out=$got_out; want $want_in/$want_cached/$want_out)"
  fi
}

assert_rc() {
  local label=$1 want=$2
  if [[ "$LAST_RC" -eq "$want" ]]; then
    pass "$label"
  else
    fail "$label (want rc $want)"
  fi
}

repo="$work/repo"
tmp="$repo/.claude/tmp"
mkdir -p "$tmp"

# --- cursor fixtures ---------------------------------------------------------
cat >"$tmp/exec-run-cursor-1.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}
{"type":"result","subtype":"success","is_error":false,"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":200,"cacheWriteTokens":10,"reasoningTokens":20}}
EOF
cat >"$tmp/exec-run-cursor-2.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-2"}
{"type":"result","subtype":"success","is_error":false,"usage":{"inputTokens":300,"outputTokens":70,"cacheReadTokens":100,"cacheWriteTokens":0,"reasoningTokens":5}}
EOF
cat >"$tmp/exec-run-cursor-3.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-3"}
{"type":"result","subtype":"success","is_error":false,"usage":{"inputTokens":"many","outputTokens":50,"cacheReadTokens":200,"cacheWriteTokens":0,"reasoningTokens":0}}
EOF
cat >"$tmp/exec-run-cursor-4.ndjson" <<'EOF'
{"type":"system","subtype":"init","session_id":"sess-4"}
this is not json
EOF

# --- agy fixtures --------------------------------------------------------------
cat >"$tmp/exec-run-agy-1.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-1"}
{"event":"result","status":"SUCCESS","finished_reason":"completed","result":{"steps":[],"usage":{"input_tokens":1000,"output_tokens":200,"thinking_tokens":50,"cache_read_tokens":4000,"total_tokens":1200}}}
EOF
cat >"$tmp/exec-run-agy-2.ndjson" <<'EOF'
{"event":"init","conversation_id":"conv-2"}
{"event":"result","status":"SUCCESS","finished_reason":"completed","result":{"usage":{"input_tokens":500,"output_tokens":100,"thinking_tokens":10,"cache_read_tokens":250,"total_tokens":600}}}
EOF

# --- devin fixtures --------------------------------------------------------------
cat >"$tmp/exec-run-devin-1.json" <<'EOF'
{"session_id":"devin-1","final_metrics":{"total_prompt_tokens":500,"total_completion_tokens":60,"total_cached_tokens":200}}
EOF
cat >"$tmp/exec-run-devin-2.json" <<'EOF'
{"session_id":"devin-2","final_metrics":{"total_prompt_tokens":900,"total_completion_tokens":30,"total_cached_tokens":100}}
EOF
cat >"$tmp/exec-run-devin-3.json" <<'EOF'
{"session_id":"devin-3","steps":[]}
EOF

# --- cursor ---------------------------------------------------------------------
run_cmd bash "$SCRIPT" cursor "$repo" 1
assert_usage "cursor single launch" 100 200 50

run_cmd bash "$SCRIPT" cursor "$repo" 1 2
assert_usage "cursor sum of two launches" 400 300 120

run_cmd bash "$SCRIPT" cursor "$repo" 9
assert_usage "cursor missing file → all null" null null null

run_cmd bash "$SCRIPT" cursor "$repo" 1 9
assert_usage "cursor one missing → all null" null null null

run_cmd bash "$SCRIPT" cursor "$repo" 3
assert_usage "cursor non-integer field → that field null" null 200 50

run_cmd bash "$SCRIPT" cursor "$repo" 4
assert_usage "cursor malformed last line → all null" null null null

# --- agy -------------------------------------------------------------------------
run_cmd bash "$SCRIPT" agy "$repo" 1
assert_usage "agy single launch" 1000 4000 200

run_cmd bash "$SCRIPT" agy "$repo" 1 2
assert_usage "agy sum of two launches" 1500 4250 300

run_cmd bash "$SCRIPT" agy "$repo" 9
assert_usage "agy missing file → all null" null null null

# --- devin -------------------------------------------------------------------------
run_cmd bash "$SCRIPT" devin "$repo" 1
assert_usage "devin single launch (prompt-cached)" 300 200 60

run_cmd bash "$SCRIPT" devin "$repo" 1 2
assert_usage "devin sum of two launches" 1100 300 90

run_cmd bash "$SCRIPT" devin "$repo" 3
assert_usage "devin no final_metrics → all null" null null null

run_cmd bash "$SCRIPT" devin "$repo" 1 3
assert_usage "devin one missing metrics → all null" null null null

# --- usage errors -------------------------------------------------------------------
run_cmd bash "$SCRIPT" bogus "$repo" 1
assert_rc "bad backend rc 2" 2

run_cmd bash "$SCRIPT" cursor "relative/repo" 1
assert_rc "relative root rc 2" 2

run_cmd bash "$SCRIPT" cursor "$work/no-such-dir" 1
assert_rc "missing root rc 2" 2

run_cmd bash "$SCRIPT" cursor "$repo" abc
assert_rc "non-numeric n rc 2" 2

run_cmd bash "$SCRIPT" cursor "$repo"
assert_rc "no launch numbers rc 2" 2

echo "failures: $fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
