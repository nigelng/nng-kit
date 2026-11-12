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

# --print output starts with the `env -i NAME=<set>` clean-env prefix; the
# argv tests below compare what follows it.
strip_env_prefix() {
  awk 'BEGIN { head = 1 } head && /^(env|-i|[A-Z_][A-Z0-9_]*=.*)$/ { next } { head = 0; print }'
}

run_print() {
  run_cmd "$@"
  LAST_OUT=$(strip_env_prefix <<<"$LAST_OUT")
}

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q

no_files() {
  [[ ! -e "$repo/.claude" ]]
}

# --- argv: each backend × brief / fix+resume / fix fresh / interactive ---

cursor_base=$'agent\n-p\n--force\n--trust\n--workspace\n'"$repo"$'\n--output-format\nstream-json\n--stream-partial-output\n--model\ngrok-4.7-high'

run_print bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high brief
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$cursor_base"$'\n'"Read .claude/tmp/exec-cursor-brief.md and follow it exactly." ]]; then
  pass "cursor brief argv"
else
  fail "cursor brief argv"
fi
if no_files; then pass "cursor brief --print writes nothing"; else fail "cursor brief --print writes nothing"; fi

run_print bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high fix:2 sess-abc
want="$cursor_base"$'\n--resume\nsess-abc\n'"Read .claude/tmp/exec-cursor-fix-2.md and apply the fixes exactly."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "cursor fix+resume argv"
else
  fail "cursor fix+resume argv"
fi

run_print bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high fix:2
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

run_print bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
want="$agy_base"$'\n-p\n'"Read .claude/tmp/exec-agy-brief.md and follow it exactly."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy brief argv"
else
  fail "agy brief argv"
fi

run_print bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium fix:2 conv-1
want="$agy_base"$'\n--conversation\nconv-1\n-p\n'"Read .claude/tmp/exec-agy-fix-2.md and fix every issue listed."
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "agy fix+resume argv"
else
  fail "agy fix+resume argv"
fi

run_print bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium fix:2
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

devin_base=$'devin\n--model\ngpt-6-1-terra-high\n--permission-mode\ndangerous\n--respect-workspace-trust=false\n--export=.claude/tmp/exec-run-devin-3.json'

run_print bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high brief
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

# DELEGATE_MCP=1 must not change cursor, agy or devin argv (no per-run MCP off).
for mcp_backend in cursor agy devin; do
  run_print bash "$SCRIPT" --print "$mcp_backend" "$repo" 3 m-1 brief
  mcp_default=$LAST_OUT
  DELEGATE_MCP=1 run_print bash "$SCRIPT" --print "$mcp_backend" "$repo" 3 m-1 brief
  if [[ "$LAST_OUT" == "$mcp_default" && -n "$mcp_default" ]]; then
    pass "DELEGATE_MCP=1 leaves $mcp_backend argv unchanged"
  else
    fail "DELEGATE_MCP=1 leaves $mcp_backend argv unchanged"
  fi
done

run_print bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high fix:2 sess-devin
want="$devin_base"$'\n--resume=sess-devin\n--print=Read .claude/tmp/exec-devin-fix-2.md and fix every issue listed.'
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == "$want" ]]; then
  pass "devin fix+resume argv"
else
  fail "devin fix+resume argv"
fi

run_print bash "$SCRIPT" --print devin "$repo" 3 gpt-6-1-terra-high fix:2
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
ln -s "$(command -v env)" "$notime/env"
ln -s "$(command -v dirname)" "$notime/dirname"
ln -s "$(command -v jq)" "$notime/jq"
ln -s "$(command -v mkdir)" "$notime/mkdir"
cat >"$notime/agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${STUB_ARGV_LOG:?}"
exit 4
EOF
chmod +x "$notime/agent"
rm -rf "$repo/.claude"
# Absolute bash: env would otherwise search the stripped PATH for `bash`.
run_cmd env PATH="$notime" STUB_ARGV_LOG="$work/agent-notime.args" DELEGATE_ENV_ALLOW=STUB_ARGV_LOG "$(command -v bash)" "$SCRIPT" cursor "$repo" 8 grok-4.7-high brief
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
ln -s "$(command -v env)" "$gto/env"
ln -s "$(command -v dirname)" "$gto/dirname"
ln -s "$(command -v jq)" "$gto/jq"
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

# --- clean environment: allowlist, DELEGATE_ENV_ALLOW, names-only --print ---

clean_print() {
  run_cmd env -i HOME=/h PATH="$PATH" SECRET_TOKEN=sekrit-value CURSOR_API_KEY=key-value "$@"
}

clean_print bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
if [[ "$LAST_RC" -eq 0 && "$(sed -n '1,4p' <<<"$LAST_OUT")" == $'env\n-i\nHOME=<set>\nPATH=<set>' ]]; then
  pass "--print starts with env -i and allowed names"
else
  fail "--print starts with env -i and allowed names"
fi
case "$LAST_OUT" in
  *sekrit-value* | *SECRET_TOKEN* | *key-value* | */h*) fail "--print shows no values and no outside names" ;;
  *) pass "--print shows no values and no outside names" ;;
esac
if ! grep -q 'CURSOR_API_KEY' <<<"$LAST_OUT"; then
  pass "agy does not get CURSOR_API_KEY"
else
  fail "agy does not get CURSOR_API_KEY"
fi
clean_print env AGY_CLI_DISABLE_AUTO_UPDATE=true bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
if grep -qx 'AGY_CLI_DISABLE_AUTO_UPDATE=<set>' <<<"$LAST_OUT" && ! grep -q 'AGY_CLI_DISABLE_AUTO_UPDATE=true' <<<"$LAST_OUT"; then
  pass "agy passes AGY_CLI_DISABLE_AUTO_UPDATE by name"
else
  fail "agy passes AGY_CLI_DISABLE_AUTO_UPDATE by name"
fi
if ! grep -q 'DEVIN_REFUSAL_FALLBACK\|^-u$' <<<"$LAST_OUT"; then
  pass "no env -u in agy argv"
else
  fail "no env -u in agy argv"
fi

clean_print bash "$SCRIPT" --print cursor "$repo" 3 grok-4.7-high brief
if grep -qx 'CURSOR_API_KEY=<set>' <<<"$LAST_OUT" && ! grep -q 'key-value' <<<"$LAST_OUT"; then
  pass "cursor passes registry authEnv CURSOR_API_KEY, name only"
else
  fail "cursor passes registry authEnv CURSOR_API_KEY, name only"
fi

clean_print env DELEGATE_ENV_ALLOW=SECRET_TOKEN bash "$SCRIPT" --print devin "$repo" 3 swe-2-high brief
if grep -qx 'SECRET_TOKEN=<set>' <<<"$LAST_OUT" && ! grep -q 'sekrit-value' <<<"$LAST_OUT"; then
  pass "DELEGATE_ENV_ALLOW adds a name, still no value in --print"
else
  fail "DELEGATE_ENV_ALLOW adds a name, still no value in --print"
fi
clean_print env https_proxy=http://u:proxy-secret@p:1 HTTPS_PROXY=http://u:proxy-secret@p:2 bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
if grep -qx 'https_proxy=<set>' <<<"$LAST_OUT" && grep -qx 'HTTPS_PROXY=<set>' <<<"$LAST_OUT" && ! grep -q 'proxy-secret' <<<"$LAST_OUT"; then
  pass "proxy variables pass by name, never by value"
else
  fail "proxy variables pass by name, never by value"
fi
clean_print env DELEGATE_ENV_ALLOW=my_lower_var my_lower_var=lowval bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
if [[ "$LAST_RC" -eq 0 ]] && grep -qx 'my_lower_var=<set>' <<<"$LAST_OUT" && ! grep -q 'lowval' <<<"$LAST_OUT"; then
  pass "DELEGATE_ENV_ALLOW accepts a lowercase name"
else
  fail "DELEGATE_ENV_ALLOW accepts a lowercase name"
fi
for bad_allow in 'bad.name' 'A B' 'GOOD,' ',GOOD' '1ABC' 'A-B' 'A;B'; do
  clean_print env DELEGATE_ENV_ALLOW="$bad_allow" bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
  if [[ "$LAST_RC" -eq 2 ]]; then
    pass "bad DELEGATE_ENV_ALLOW '$bad_allow' rejected"
  else
    fail "bad DELEGATE_ENV_ALLOW '$bad_allow' rejected"
  fi
done

printf '{"tools":{"agy":{"authEnv":["bad name"]}}}\n' >"$work/tiers-auth-bad.json"
clean_print env NNG_KIT_TIERS="$work/tiers-auth-bad.json" bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
if [[ "$LAST_RC" -eq 2 ]]; then pass "bad authEnv name rejected"; else fail "bad authEnv name rejected"; fi

# A malformed entry is validated whole: no word-splitting, no globbing.
globdir="$work/globdir"
mkdir -p "$globdir"
: >"$globdir/ZZTOP"
for bad_auth in 'FOO BAR' 'Z*'; do
  printf '{"tools":{"agy":{"authEnv":["%s"]}}}\n' "$bad_auth" >"$work/tiers-auth-split.json"
  pushd "$globdir" >/dev/null
  clean_print env NNG_KIT_TIERS="$work/tiers-auth-split.json" bash "$SCRIPT" --print agy "$repo" 3 gemini-4-argon-medium brief
  popd >/dev/null
  if [[ "$LAST_RC" -eq 2 ]]; then pass "authEnv '$bad_auth' rejected whole"; else fail "authEnv '$bad_auth' rejected whole"; fi
done

# Real run: the child sees the allowlist only.
envstub="$work/envstub"
mkdir -p "$envstub"
for c in git env dirname jq mkdir; do ln -s "$(command -v "$c")" "$envstub/$c"; done
cat >"$envstub/agy" <<'STUB'
#!/bin/bash
env >"${STUB_ENV_LOG:?}"
STUB
chmod +x "$envstub/agy"
rm -rf "$repo/.claude"
rm -f "$work/child.env"
run_cmd env PATH="$envstub" SECRET_TOKEN=sekrit-value STUB_ENV_LOG="$work/child.env" \
  DELEGATE_ENV_ALLOW=STUB_ENV_LOG "$(command -v bash)" "$SCRIPT" agy "$repo" 20 gemini-4-argon-medium brief
if grep -q '^PATH=' "$work/child.env" && ! grep -q 'SECRET_TOKEN' "$work/child.env"; then
  pass "child env has allowed PATH and lacks SECRET_TOKEN"
else
  fail "child env has allowed PATH and lacks SECRET_TOKEN"
fi
rm -rf "$repo/.claude"
rm -f "$work/child.env"
run_cmd env PATH="$envstub" SECRET_TOKEN=sekrit-value STUB_ENV_LOG="$work/child.env" \
  DELEGATE_ENV_ALLOW=STUB_ENV_LOG,SECRET_TOKEN "$(command -v bash)" "$SCRIPT" agy "$repo" 21 gemini-4-argon-medium brief
if grep -qx 'SECRET_TOKEN=sekrit-value' "$work/child.env"; then
  pass "DELEGATE_ENV_ALLOW passes the named variable to the child"
else
  fail "DELEGATE_ENV_ALLOW passes the named variable to the child"
fi

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
