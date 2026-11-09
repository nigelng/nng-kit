#!/usr/bin/env bash
# Fixture tests for delegate-launch.sh. Run with bash.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/delegate-launch.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-launch.XXXXXX")
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
  printf '  stdout<<%s>>\n' "$LAST_OUT"
  printf '  stderr<<%s>>\n' "$LAST_ERR"
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

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q

no_files() {
  [[ ! -e "$repo/.claude" ]]
}

# --- argv: each backend × brief / fix+resume / fix fresh / interactive ---

cursor_base=$'agent\n-p\n--force\n--trust\n--workspace\n'"$repo"$'\n--output-format\nstream-json\n--stream-partial-output\n--model\ngrok-4.7-high'

run_cmd bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high brief
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$cursor_base"$'\n'"Read .claude/tmp/exec-cursor-brief.md and follow it exactly." ]]; then
  pass "cursor brief argv"
else
  fail "cursor brief argv"
fi
if no_files; then pass "cursor brief --print writes nothing"; else fail "cursor brief --print writes nothing"; fi

run_cmd bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high fix:2 sess-abc
want="$cursor_base"$'\n--resume\nsess-abc\n'"Read .claude/tmp/exec-cursor-fix-2.md and apply the fixes exactly."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "cursor fix+resume argv"
else
  fail "cursor fix+resume argv"
fi

run_cmd bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high fix:2
want="$cursor_base"$'\n'"Read .claude/tmp/exec-cursor-brief.md and .claude/tmp/exec-cursor-fix-2.md; apply the fixes exactly."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "cursor fix fresh argv"
else
  fail "cursor fix fresh argv"
fi

run_cmd bash "$SCRIPT" --interactive cursor "$repo" 3 grok-4.7-high brief
want="agent --trust --workspace $repo --model grok-4.7-high \"Read .claude/tmp/exec-cursor-brief.md and follow it exactly.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "cursor interactive"
else
  fail "cursor interactive"
fi

agy_base=$'agy\n--dangerously-skip-permissions\n--output-format\nstream-json\n--model\ngemini-4-argon-medium'

run_cmd bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
want="$agy_base"$'\n-p\n'"Read .claude/tmp/exec-agy-brief.md and follow it exactly."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy brief argv"
else
  fail "agy brief argv"
fi

run_cmd bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium fix:2 conv-1
want="$agy_base"$'\n--conversation\nconv-1\n-p\n'"Read .claude/tmp/exec-agy-fix-2.md and fix every issue listed."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy fix+resume argv"
else
  fail "agy fix+resume argv"
fi

run_cmd bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium fix:2
want="$agy_base"$'\n-p\n'"Read .claude/tmp/exec-agy-brief.md and .claude/tmp/exec-agy-fix-2.md and fix every issue listed."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy fix fresh argv"
else
  fail "agy fix fresh argv"
fi

run_cmd bash "$SCRIPT" --interactive agy "$repo" 3 gemini-4-argon-medium brief
want="cd $repo && agy --model gemini-4-argon-medium \"Read .claude/tmp/exec-agy-brief.md and follow it exactly.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy interactive"
else
  fail "agy interactive"
fi

devin_base=$'env\n-u\nDEVIN_REFUSAL_FALLBACK\ndevin\n--model\ngpt-6-1-terra-high\n--permission-mode\ndangerous\n--respect-workspace-trust=false\n--export=.claude/tmp/exec-run-devin-3.json'

run_cmd bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high brief
want="$devin_base"$'\n--print=Read .claude/tmp/exec-devin-brief.md and follow it exactly.'
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin brief argv"
else
  fail "devin brief argv"
fi
case "$LAST_OUT" in
  *'--export=.claude/tmp/exec-run-devin-3.json'*) pass "devin export is relative" ;;
  *) fail "devin export is relative" ;;
esac
case "$LAST_OUT" in
  *"$repo"*) fail "devin export is not absolute" ;;
  *) pass "devin export path has no repo root" ;;
esac

run_cmd bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high fix:2 sess-devin
want="$devin_base"$'\n--resume=sess-devin\n--print=Read .claude/tmp/exec-devin-fix-2.md and fix every issue listed.'
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin fix+resume argv"
else
  fail "devin fix+resume argv"
fi

run_cmd bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high fix:2
want="$devin_base"$'\n--print=Read .claude/tmp/exec-devin-brief.md and .claude/tmp/exec-devin-fix-2.md and fix every issue listed.'
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin fix fresh argv"
else
  fail "devin fix fresh argv"
fi

run_cmd bash "$SCRIPT" --interactive devin "$repo" 3 gpt-6-1-terra-high brief
want="cd $repo && devin --model gpt-6-1-terra-high -- \"Read .claude/tmp/exec-devin-brief.md and follow it exactly.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin interactive"
else
  fail "devin interactive"
fi

run_cmd bash "$SCRIPT" --interactive devin "$repo" 3 gpt-6-1-terra-high fix:2
want="cd $repo && devin --model gpt-6-1-terra-high -- \"Read .claude/tmp/exec-devin-fix-2.md and fix every issue listed.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin interactive fix"
else
  fail "devin interactive fix"
fi

# --- interactive lines shell-quote a repo root containing spaces ---

space_repo="$work/repo with space"
mkdir -p "$space_repo"
git -C "$space_repo" init -q
space_root=$(cd "$space_repo" && pwd -P)
space_q=$(printf '%q' "$space_root")

run_cmd bash "$SCRIPT" --interactive cursor "$space_root" 1 grok-4.7-high brief
want="agent --trust --workspace $space_q --model grok-4.7-high \"Read .claude/tmp/exec-cursor-brief.md and follow it exactly.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "cursor interactive quotes spaced root"
else
  fail "cursor interactive quotes spaced root"
fi

run_cmd bash "$SCRIPT" --interactive devin "$space_root" 1 swe-2-high brief
want="cd $space_q && devin --model swe-2-high -- \"Read .claude/tmp/exec-devin-brief.md and follow it exactly.\""
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin interactive quotes spaced root"
else
  fail "devin interactive quotes spaced root"
fi

# --- run: .exit holds the stub code; timeout ceiling is passed ---

stub="$work/bin"
mkdir -p "$stub"
cat >"$stub/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${STUB_TIMEOUT_LOG:?}"
exit "${STUB_RC:-0}"
EOF
cat >"$stub/agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${STUB_ARGV_LOG:?}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub/timeout" "$stub/agent"

export STUB_TIMEOUT_LOG="$work/timeout.args"
export STUB_ARGV_LOG="$work/agent.args"
export STUB_RC=9
run_cmd env PATH="$stub:$PATH" bash "$SCRIPT" cursor "$repo" 1 grok-4.7-high brief
if [[ "$LAST_RC" -eq 0 ]]; then
  pass "run exits 0 after writing .exit"
else
  fail "run exits 0 after writing .exit"
fi
got_exit=$(tr -d '[:space:]' <"$repo/.claude/tmp/exec-run-cursor-1.exit")
if [[ "$got_exit" == 9 ]]; then
  pass ".exit holds stub code"
else
  fail ".exit holds stub code (got $got_exit)"
fi
if [[ -f "$repo/.claude/tmp/exec-run-cursor-1.ndjson" && -f "$repo/.claude/tmp/exec-run-cursor-1.err" ]]; then
  pass "cursor run files created"
else
  fail "cursor run files created"
fi
if [[ "$(head -2 "$STUB_TIMEOUT_LOG")" == $'--kill-after=2m\n90m' ]]; then
  pass "timeout ceiling is 90m"
else
  fail "timeout ceiling is 90m (got $(head -2 "$STUB_TIMEOUT_LOG"))"
fi

rm -rf "$repo/.claude"
export STUB_RC=3
run_cmd env PATH="$stub:$PATH" DELEGATE_TIMEOUT=5s bash "$SCRIPT" devin "$repo" 4 gpt-6-1-terra-high brief
if [[ "$LAST_RC" -eq 0 && "$(tr -d '[:space:]' <"$repo/.claude/tmp/exec-run-devin-4.exit")" == 3 ]]; then
  pass "devin .exit holds stub code"
else
  fail "devin .exit holds stub code"
fi
if [[ -f "$repo/.claude/tmp/exec-run-devin-4.out" && ! -e "$repo/.claude/tmp/exec-run-devin-4.ndjson" ]]; then
  pass "devin stdout is .out"
else
  fail "devin stdout is .out"
fi
if grep -F -q -e '--export=.claude/tmp/exec-run-devin-4.json' "$STUB_TIMEOUT_LOG"; then
  pass "devin run keeps relative --export"
else
  fail "devin run keeps relative --export"
fi
if [[ "$(sed -n '2p' "$STUB_TIMEOUT_LOG")" == 5s ]]; then
  pass "DELEGATE_TIMEOUT overrides the ceiling"
else
  fail "DELEGATE_TIMEOUT overrides the ceiling"
fi

# missing timeout → WARN and still runs
notime="$work/notime"
mkdir -p "$notime"
# Real git and mkdir, and no timeout/gtimeout/caffeinate on PATH.
ln -s "$(command -v git)" "$notime/git"
ln -s "$(command -v mkdir)" "$notime/mkdir"
cat >"$notime/agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${STUB_ARGV_LOG:?}"
exit 4
EOF
chmod +x "$notime/agent"
rm -rf "$repo/.claude"
# Absolute bash: env would otherwise search the stripped PATH for `bash`.
run_cmd env PATH="$notime" STUB_ARGV_LOG="$work/agent-notime.args" "$(command -v bash)" "$SCRIPT" cursor "$repo" 8 grok-4.7-high brief
if [[ "$LAST_RC" -eq 0 ]]; then
  pass "missing timeout still exits 0"
else
  fail "missing timeout still exits 0"
fi
case "$LAST_ERR" in
  *"WARN: no timeout binary; running without ceiling"*) pass "missing timeout warns" ;;
  *) fail "missing timeout warns" ;;
esac
if [[ "$(tr -d '[:space:]' <"$repo/.claude/tmp/exec-run-cursor-8.exit")" == 4 ]]; then
  pass "missing timeout runs the cli"
else
  fail "missing timeout runs the cli"
fi
if grep -q -- '--force' "$work/agent-notime.args"; then
  pass "missing timeout invoked agent"
else
  fail "missing timeout invoked agent"
fi

# gtimeout is used when timeout is absent.
gto="$work/gto"
mkdir -p "$gto"
ln -s "$(command -v git)" "$gto/git"
ln -s "$(command -v mkdir)" "$gto/mkdir"
cat >"$gto/gtimeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${STUB_TIMEOUT_LOG:?}"
exit 6
EOF
chmod +x "$gto/gtimeout"
rm -rf "$repo/.claude"
run_cmd env PATH="$gto" STUB_TIMEOUT_LOG="$work/gtimeout.args" "$(command -v bash)" "$SCRIPT" cursor "$repo" 9 grok-4.7-high brief
if [[ "$LAST_RC" -eq 0 && "$(tr -d '[:space:]' <"$repo/.claude/tmp/exec-run-cursor-9.exit")" == 6 ]]; then
  pass "gtimeout used when timeout is absent"
else
  fail "gtimeout used when timeout is absent"
fi
if [[ "$(head -1 "$work/gtimeout.args")" == "--kill-after=2m" ]]; then
  pass "gtimeout receives the ceiling flags"
else
  fail "gtimeout receives the ceiling flags"
fi
case "$LAST_ERR" in
  *WARN*) fail "gtimeout path does not warn" ;;
  *) pass "gtimeout path does not warn" ;;
esac

# --- rejections: exit 2, nothing written ---

rm -rf "$repo/.claude"
run_cmd bash "$SCRIPT" cursor "$repo" 1 'bad model' brief
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "invalid model rejected"
else
  fail "invalid model rejected"
fi
case "$LAST_ERR" in
  usage:*) pass "invalid model usage" ;;
  *) fail "invalid model usage" ;;
esac

run_cmd bash "$SCRIPT" cursor "$repo" 1 grok-4.7-high brief 'bad id'
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "invalid resume rejected"
else
  fail "invalid resume rejected"
fi

long_resume=$(awk 'BEGIN { for (i = 0; i < 65; i++) printf "a" }')
run_cmd bash "$SCRIPT" cursor "$repo" 1 grok-4.7-high fix:1 "$long_resume"
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "overlong resume rejected"
else
  fail "overlong resume rejected"
fi

plain=$(mktemp -d "$work/plain.XXXXXX")
run_cmd bash "$SCRIPT" cursor "$plain" 1 grok-4.7-high brief
if [[ "$LAST_RC" -eq 2 && ! -e "$plain/.claude" ]]; then
  pass "non-git root rejected"
else
  fail "non-git root rejected"
fi

mkdir -p "$repo/sub"
run_cmd bash "$SCRIPT" cursor "$repo/sub" 1 grok-4.7-high brief
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "subdir root rejected"
else
  fail "subdir root rejected"
fi

run_cmd bash "$SCRIPT" cursor relpath 1 grok-4.7-high brief
if [[ "$LAST_RC" -eq 2 ]]; then
  pass "relative root rejected"
else
  fail "relative root rejected"
fi

run_cmd env DELEGATE_TIMEOUT=bad bash "$SCRIPT" cursor "$repo" 1 grok-4.7-high brief
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "DELEGATE_TIMEOUT=bad rejected"
else
  fail "DELEGATE_TIMEOUT=bad rejected"
fi

run_cmd bash "$SCRIPT" cursor "$repo" 1 grok-4.7-high fix:
if [[ "$LAST_RC" -eq 2 ]] && no_files; then
  pass "bad kind rejected"
else
  fail "bad kind rejected"
fi

printf 'PASS/FAIL summary: %s failed\n' "$fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
