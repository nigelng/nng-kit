#!/usr/bin/env bash
# Delegate CLI contract tests (no login).
# (a) every flag delegate-launch.sh (--print / --interactive) and
#     delegate-review-launch.sh run --print emits is listed in
#     AGENT_FLAGS / AGY_FLAGS / DEVIN_FLAGS and in fixtures/{agent,agy,devin}-help.txt
# (b) PATH-shim stubs emit fixture NDJSON; delegate-verdict.sh classifies it
# (c) guard: delegate-verdict.sh still contains the jq/reason/regex strings the
#     stubs exercise; execute-via-devin/SKILL.md keeps refusal, find -delete,
#     and trust-warning text. Review argv keeps the read-only forms
#     (--mode=ask, --mode plan, --permission-mode auto) and omits
#     --force / --dangerously-skip-permissions / dangerous.
# Ends by running tests/test-plan-status.sh, tests/test-delegate-launch.sh,
# tests/test-delegate-verdict.sh, tests/test-delegate-verify.sh,
# tests/test-delegate-usage.sh, and tests/test-delegate-review-launch.sh.
# AGENT_FLAGS / AGY_FLAGS / DEVIN_FLAGS below are read by scripts/check-delegate-cli.sh
# (first line matching ^NAME=\(, words never eval'd). Keep them unindented.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
LAUNCH="$TESTS_DIR/../scripts/delegate-launch.sh"
REVIEW="$TESTS_DIR/../scripts/delegate-review-launch.sh"
VERDICT="$TESTS_DIR/../scripts/delegate-verdict.sh"
DEVIN_SKILL="$TESTS_DIR/../skills/execute-via-devin/SKILL.md"
ORIG_PATH=$PATH

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
AGENT_FLAGS=(-p --force --trust --workspace --output-format --stream-partial-output --resume --model --mode)
AGY_FLAGS=(--dangerously-skip-permissions --output-format --conversation --model -p --mode)
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

for f in "${AGY_FLAGS[@]}"; do
  if flag_in_fixture "$FIXTURES/agy-help.txt" "$f"; then
    report "agy flag $f in agy-help.txt" 0
  else
    report "agy flag $f in agy-help.txt" 1 "FAIL: execute-via-agy uses $f, absent from fixtures/agy-help.txt"
  fi
done

for f in "${DEVIN_FLAGS[@]}"; do
  if flag_in_fixture "$FIXTURES/devin-help.txt" "$f"; then
    report "devin flag $f in devin-help.txt" 0
  else
    report "devin flag $f in devin-help.txt" 1 "FAIL: execute-via-devin uses $f, absent from fixtures/devin-help.txt"
  fi
done

# Flags delegate-launch.sh actually emits (--print argv, one token per line,
# and the --interactive command line) must sit in the arrays above and so get
# checked against the help fixtures. Tokens before the backend binary (the
# `env -i NAME=<set>` clean-env prefix) are ignored, so `-i` is never read as
# a CLI flag. --flag=value counts as --flag. Quoted interactive prompts are
# dropped so prose is not read as flags.
work=$(mktemp -d "${TMPDIR:-/tmp}/delegate-contract.XXXXXX")
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
: >"$work/flags-cursor"
: >"$work/flags-agy"
: >"$work/flags-devin"

normalize_flag() {
  local t=$1
  t=${t#\"}
  t=${t%\"}
  t=${t#\'}
  t=${t%\'}
  t=${t%%=*}
  if [[ "$t" =~ ^--?[A-Za-z][A-Za-z0-9-]*$ ]]; then
    printf '%s\n' "$t"
  fi
  return 0
}

collect_print_flags() {
  local cmd=$1 line seen=0 flag
  seen=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$seen" -eq 0 ]]; then
      [[ "$line" == "$cmd" ]] && seen=1
      continue
    fi
    flag=$(normalize_flag "$line")
    if [[ -n "$flag" ]]; then
      printf '%s\n' "$flag"
    fi
  done
  return 0
}

# --print must open with `env`, `-i`, then names-only NAME=<set> lines, and
# only then the CLI binary; no clean-env token may reach the flag collector.
check_env_prefix() {
  local label=$1 out=$2 cmd=$3 line idx=0 ok=1
  while IFS= read -r line; do
    if [[ "$idx" -eq 0 ]]; then
      [[ "$line" == env ]] || ok=0
    elif [[ "$idx" -eq 1 ]]; then
      [[ "$line" == -i ]] || ok=0
    elif [[ "$line" == "$cmd" ]]; then
      break
    elif [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*=\<set\>$ ]]; then
      ok=0
    fi
    idx=$((idx + 1))
  done <<<"$out"
  if [[ "$ok" -eq 1 ]]; then
    report "$label opens with env -i and names-only prefix" 0
  else
    report "$label opens with env -i and names-only prefix" 1 "bad prefix before $cmd"
  fi
}

collect_interactive_flags() {
  local cmd=$1
  awk -v cmd="$cmd" '
    {
      line = $0
      gsub(/"[^"]*"/, "", line)
      gsub(/\047[^\047]*\047/, "", line)
      n = split(line, tok, /[[:space:]]+/)
      seen = 0
      for (i = 1; i <= n; i++) {
        t = tok[i]
        sub(/=.*$/, "", t)
        if (t == cmd) { seen = 1; continue }
        if (!seen) continue
        if (t ~ /^--?[A-Za-z][A-Za-z0-9-]*$/) print t
      }
    }
  '
}

launch_collect() {
  local mode=$1 backend=$2 kind=$3 resume=$4
  local cmd out label
  local -a args
  case "$backend" in
    cursor) cmd=agent ;;
    agy) cmd=agy ;;
    devin) cmd=devin ;;
  esac
  label="delegate-launch.sh $mode $backend $kind${resume:+ $resume}"
  args=("$mode" "$backend" "$repo" 1 grok-4.7-high "$kind")
  if [[ -n "$resume" ]]; then
    args+=("$resume")
  fi
  out=$(bash "$LAUNCH" "${args[@]}" 2>"$work/launch.err") || {
    report "$label" 1 "$(cat "$work/launch.err")"
    return 0
  }
  if [[ "$mode" == --print ]]; then
    check_env_prefix "$label" "$out" "$cmd"
    printf '%s\n' "$out" | collect_print_flags "$cmd" >>"$work/flags-$backend"
  else
    printf '%s\n' "$out" | collect_interactive_flags "$cmd" >>"$work/flags-$backend"
  fi
}

for backend in cursor agy devin; do
  for kind in brief fix:1; do
    for resume in "" sess-1; do
      launch_collect --print "$backend" "$kind" "$resume"
      launch_collect --interactive "$backend" "$kind" "$resume"
    done
  done
done

check_launch_flags() {
  local backend=$1 fixture=$2 arr_name=$3
  local flag k missing_array missing_fixture why
  local -a known_flags=()
  case "$backend" in
    cursor) known_flags=("${AGENT_FLAGS[@]}") ;;
    agy) known_flags=("${AGY_FLAGS[@]}") ;;
    devin) known_flags=("${DEVIN_FLAGS[@]}") ;;
  esac
  if [[ ! -s "$work/flags-$backend" ]]; then
    report "$backend launch flags extracted" 1 "no flags collected from delegate-launch.sh"
    return
  fi
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    missing_array=1
    for k in "${known_flags[@]}"; do
      [[ "$k" == "$flag" ]] && missing_array=0
    done
    if flag_in_fixture "$fixture" "$flag"; then
      missing_fixture=0
    else
      missing_fixture=1
    fi
    if [[ "$missing_array" -eq 0 && "$missing_fixture" -eq 0 ]]; then
      report "$backend launch flag $flag covered by flag array and help fixture" 0
    else
      why=""
      [[ "$missing_array" -eq 0 ]] || why="not in $arr_name"
      [[ "$missing_fixture" -eq 0 ]] || why="${why:+$why; }absent from $(basename "$fixture")"
      report "$backend launch flag $flag covered by flag array and help fixture" 1 "$why"
    fi
  done < <(sort -u "$work/flags-$backend")
}

check_launch_flags cursor "$FIXTURES/agent-help.txt" AGENT_FLAGS
check_launch_flags agy "$FIXTURES/agy-help.txt" AGY_FLAGS
check_launch_flags devin "$FIXTURES/devin-help.txt" DEVIN_FLAGS

# Flags delegate-review-launch.sh run --print emits (one token per line) must
# sit in the same arrays and help fixtures. Tokens before the backend binary
# (the `env -i NAME=<set>` prefix) are ignored, same as launch. Guard strings are the read-only review
# forms; write-capable flags stay out of the review argv.
: >"$work/review-argv"
: >"$work/review-flags-cursor"
: >"$work/review-flags-agy"
: >"$work/review-flags-devin"

review_collect() {
  local runner=$1 rid=$2 model=$3 backend=$4
  local cmd out label
  case "$backend" in
    cursor) cmd=agent ;;
    agy) cmd=agy ;;
    devin) cmd=devin ;;
  esac
  label="delegate-review-launch.sh run --print $runner"
  out=$(bash "$REVIEW" run --print "$runner" "$repo" "$rid" "$model" 2>"$work/review.err") || {
    report "$label" 1 "$(cat "$work/review.err")"
    return 0
  }
  check_env_prefix "$label" "$out" "$cmd"
  printf '%s\n' "$out" >"$work/review-argv-$runner"
  printf '%s\n' "$out" >>"$work/review-argv"
  printf '%s\n' "$out" | collect_print_flags "$cmd" >>"$work/review-flags-$backend"
  report "$label" 0
}

review_collect cursor-ask cursor-1 claude-opus-5-5-medium cursor
review_collect agy-plan agy-1 claude-opus-5-5-medium agy
review_collect devin-fusion devin-1 fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max devin

check_review_flags() {
  local backend=$1 fixture=$2 arr_name=$3
  local flag k missing_array missing_fixture why
  local -a known_flags=()
  case "$backend" in
    cursor) known_flags=("${AGENT_FLAGS[@]}") ;;
    agy) known_flags=("${AGY_FLAGS[@]}") ;;
    devin) known_flags=("${DEVIN_FLAGS[@]}") ;;
  esac
  if [[ ! -s "$work/review-flags-$backend" ]]; then
    report "$backend review flags extracted" 1 "no flags collected from delegate-review-launch.sh"
    return
  fi
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    missing_array=1
    for k in "${known_flags[@]}"; do
      [[ "$k" == "$flag" ]] && missing_array=0
    done
    if flag_in_fixture "$fixture" "$flag"; then
      missing_fixture=0
    else
      missing_fixture=1
    fi
    if [[ "$missing_array" -eq 0 && "$missing_fixture" -eq 0 ]]; then
      report "$backend review flag $flag covered by flag array and help fixture" 0
    else
      why=""
      [[ "$missing_array" -eq 0 ]] || why="not in $arr_name"
      [[ "$missing_fixture" -eq 0 ]] || why="${why:+$why; }absent from $(basename "$fixture")"
      report "$backend review flag $flag covered by flag array and help fixture" 1 "$why"
    fi
  done < <(sort -u "$work/review-flags-$backend")
}

check_review_flags cursor "$FIXTURES/agent-help.txt" AGENT_FLAGS
check_review_flags agy "$FIXTURES/agy-help.txt" AGY_FLAGS
check_review_flags devin "$FIXTURES/devin-help.txt" DEVIN_FLAGS

review_joined() {
  local runner=$1 line joined=""
  [[ -f "$work/review-argv-$runner" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$joined" ]]; then
      joined=$line
    else
      joined+=" $line"
    fi
  done <"$work/review-argv-$runner"
  printf '%s\n' "$joined"
}

assert_review_has() {
  local runner=$1 needle=$2 label=$3 joined
  if ! joined=$(review_joined "$runner"); then
    report "$label" 1 "no argv for $runner"
    return
  fi
  if [[ "$joined" == *"$needle"* ]]; then
    report "$label" 0
  else
    report "$label" 1 "missing from $runner argv: $needle"
  fi
}

assert_review_has cursor-ask '--mode=ask' 'review argv cursor-ask includes --mode=ask'
assert_review_has agy-plan '--mode plan' 'review argv agy-plan includes --mode plan'
assert_review_has devin-fusion '--permission-mode auto' 'review argv devin-fusion includes --permission-mode auto'

assert_review_lacks() {
  local needle=$1
  if [[ ! -s "$work/review-argv" ]]; then
    report "review argv lacks $needle" 1 "no review argv collected"
    return
  fi
  if grep -qF -- "$needle" "$work/review-argv"; then
    report "review argv lacks $needle" 1 "found in review argv"
  else
    report "review argv lacks $needle" 0
  fi
}

assert_review_lacks '--force'
assert_review_lacks '--dangerously-skip-permissions'
assert_review_lacks 'dangerous'

# Negative: fixture with --conversation removed must fail the agy check.
tmp_help=$(mktemp)
sed '/--conversation/d' "$FIXTURES/agy-help.txt" >"$tmp_help"
if flag_in_fixture "$tmp_help" --conversation; then
  report "stripped agy-help lacks --conversation" 1 "still matched"
else
  report "stripped agy-help lacks --conversation" 0
fi
rm -f "$tmp_help"

# --- (c) predicate-string guard (verdict script + remaining skill text) ---
assert_contains() {
  local file=$1 needle=$2 label=$3
  if grep -qF -- "$needle" "$file"; then
    report "$label" 0
  else
    report "$label" 1 "missing from $(basename "$file"): $needle"
  fi
}

assert_contains "$VERDICT" 'select(.type=="system" and .subtype=="init").session_id' 'verdict predicate: cursor init.session_id'
assert_contains "$VERDICT" "jq -c '{type,subtype,is_error}'" 'verdict predicate: cursor result shape'
assert_contains "$VERDICT" 'select(.type=="system" and .subtype=="init").model // empty' 'verdict predicate: cursor init.model'
assert_contains "$VERDICT" 'no init.session_id' 'verdict predicate: cursor reason no init.session_id'
assert_contains "$VERDICT" 'result $result' 'verdict predicate: cursor result reason'
assert_contains "$VERDICT" 'select(.event=="init").conversation_id' 'verdict predicate: agy init.conversation_id'
assert_contains "$VERDICT" 'finished_reason: (.finished_reason // .result.finished_reason)' 'verdict predicate: agy finished_reason'
assert_contains "$VERDICT" 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' 'verdict predicate: agy stderr grep'
assert_contains "$VERDICT" 'select(.event=="init") | (.model // .init.model // empty)' 'verdict predicate: agy init.model'
assert_contains "$VERDICT" 'no init.conversation_id' 'verdict predicate: agy reason no init.conversation_id'
assert_contains "$VERDICT" 'stderr soft-deny' 'verdict predicate: agy reason stderr soft-deny'
assert_contains "$VERDICT" 'finished_reason=$finished' 'verdict predicate: agy reason finished_reason'
assert_contains "$VERDICT" 'status=$status' 'verdict predicate: agy reason status'
assert_contains "$VERDICT" "jq -r '.steps[-1].source'" 'verdict predicate: devin last step source'
assert_contains "$VERDICT" "jq -r '.session_id'" 'verdict predicate: devin session_id'
assert_contains "$VERDICT" "jq -r '[.steps[].model_name // empty] | unique | .[]'" 'verdict predicate: devin step model_name'
assert_contains "$VERDICT" 'model_resolved' 'verdict predicate: devin model_resolved'
assert_contains "$VERDICT" '[[ ${#MODELS[@]} -ne 1 || "$model_resolved" != "$slug" ]]' 'verdict predicate: devin single-model count check'
assert_contains "$VERDICT" 'no session_id' 'verdict predicate: devin reason no session_id'
assert_contains "$VERDICT" 'no export' 'verdict predicate: devin reason no export'
assert_contains "$VERDICT" 'no resolved model' 'verdict predicate: devin empty model list fails'
assert_contains "$VERDICT" 'fallback: model mismatch' 'verdict predicate: devin model mismatch'
assert_contains "$VERDICT" 'source=$source' 'verdict predicate: devin reason source'
assert_contains "$VERDICT" 'exit $exit_code' 'verdict predicate: exit reason'
assert_contains "$VERDICT" 'timeout ceiling' 'verdict predicate: timeout ceiling'
assert_contains "$VERDICT" 'auto(unresolved)' 'verdict predicate: auto(unresolved)'
assert_contains "$VERDICT" "model_re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'" 'verdict predicate: model regex'
assert_contains "$VERDICT" '[[ "$model" =~ $model_re && "$model" != null ]]' 'verdict predicate: model regex check'
assert_contains "$VERDICT" "id_re='^[A-Za-z0-9_-]{1,64}$'" 'verdict predicate: session id regex'

assert_contains "$DEVIN_SKILL" 'Refuse `adaptive`' 'skill predicate: devin refuses adaptive'
assert_contains "$DEVIN_SKILL" '`fusion-*`' 'skill predicate: devin refuses fusion-*'
assert_contains "$DEVIN_SKILL" '**exactly** in `devin models`' 'skill predicate: devin exact-match requirement'
assert_contains "$DEVIN_SKILL" "find .claude/tmp -maxdepth 1 -type f -name 'exec-run-devin-*' -delete" 'skill predicate: devin run files deleted after verdict'
assert_contains "$DEVIN_SKILL" '--respect-workspace-trust=false` (Devin'"'"'s workspace-trust check skipped)' 'skill predicate: devin trust warning'

# Value flags in delegate-launch.sh must use the `=` form. A bare token
# (`--export`, `--print`, `--resume`, `--respect-workspace-trust`) is the space
# form. Quote characters are stripped but the contents kept, because the argv
# entries are double-quoted (`"--export=.claude/tmp/..."`).
assert_contains "$LAUNCH" '--export=' 'launch: devin --export= form'
assert_contains "$LAUNCH" '--print=' 'launch: devin --print= form'
assert_contains "$LAUNCH" '--respect-workspace-trust=false' 'launch: devin --respect-workspace-trust=false form'
assert_contains "$LAUNCH" '--resume=' 'launch: devin --resume= form'

devin_space_form_flags() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      gsub(/["\047]/, "", line)
      n = split(line, tok, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "--print" || t == "--export" || t == "--resume" || t == "--respect-workspace-trust") print NR ": " t
      }
    }
  ' "$1"
}

space_form=$(devin_space_form_flags "$LAUNCH")
if [[ -z "$space_form" ]]; then
  report "devin launch script uses = form for value flags" 0
else
  report "devin launch script uses = form for value flags" 1 "space form: $(printf '%s' "$space_form" | tr '\n' ' ')"
fi

# Negative: mutate one `=`-form flag to the space form; the check must fail.
devin_space_form_negative() {
  local label=$1 from=$2 to=$3 tmp_launch rc
  tmp_launch=$(mktemp)
  rc=0
  awk -v from="$from" -v to="$to" '
    !done && (i = index($0, from)) {
      $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
      done = 1
    }
    { print }
    END { exit done ? 0 : 3 }
  ' "$LAUNCH" >"$tmp_launch" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    report "$label" 1 "no $from found to mutate in delegate-launch.sh"
  elif [[ -n "$(devin_space_form_flags "$tmp_launch")" ]]; then
    report "$label" 0
  else
    report "$label" 1 "check did not flag $to"
  fi
  rm -f "$tmp_launch"
}
devin_space_form_negative "negative: launch --export= to space form is flagged" '--export=' '--export '
devin_space_form_negative "negative: launch --respect-workspace-trust=false to space form is flagged" '--respect-workspace-trust=false' '--respect-workspace-trust false'

# --- (b) stub CLI + delegate-verdict.sh ---
mkdir -p "$work/bin" "$work/ndjson" "$repo/.claude/tmp"

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

# Map delegate-verdict.sh JSON onto the PASS / FAIL:<reason> lines the stub
# cases expect. Reasons are joined with a space (exit + no export → "exit 1 no export").
apply_verdict() {
  local backend=$1 out=$2 slug=${3:-}
  local json rc=0 reason
  if [[ "$backend" == devin ]]; then
    json=$(bash "$VERDICT" "$backend" "$repo" 1 "$slug") || rc=$?
  else
    json=$(bash "$VERDICT" "$backend" "$repo" 1) || rc=$?
  fi
  printf '%s\n' "$json" >"$work/verdict.json"
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "FAIL:verdict exit $rc" >"$out"
    return
  fi
  if jq -e '.ok == true' >/dev/null <<<"$json"; then
    printf '%s\n' PASS >"$out"
  else
    reason=$(jq -r '.reasons | join(" ")' <<<"$json")
    printf 'FAIL:%s\n' "$reason" >"$out"
  fi
}

run_stub_cursor() {
  local mode=$1 out=$2 rc
  export CONTRACT_STUB_MODE=$mode
  local ndjson="$repo/.claude/tmp/exec-run-cursor-1.ndjson"
  local err="$repo/.claude/tmp/exec-run-cursor-1.err"
  : >"$err"
  set +e
  agent -p --force --trust --workspace /tmp \
    --output-format stream-json --stream-partial-output \
    "noop" >"$ndjson" 2>"$err"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$repo/.claude/tmp/exec-run-cursor-1.exit"
  apply_verdict cursor "$out"
}

run_stub_agy() {
  local mode=$1 out=$2 rc
  export CONTRACT_STUB_MODE=$mode
  local ndjson="$repo/.claude/tmp/exec-run-agy-1.ndjson"
  local err="$repo/.claude/tmp/exec-run-agy-1.err"
  : >"$err"
  set +e
  agy --dangerously-skip-permissions --output-format stream-json -p "noop" \
    >"$ndjson" 2>"$err"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$repo/.claude/tmp/exec-run-agy-1.exit"
  apply_verdict agy "$out"
}

run_stub_devin() {
  local mode=$1 out=$2 slug=${3:-gpt-6-1-terra-high} rc
  export CONTRACT_STUB_MODE=$mode
  local export_path="$repo/.claude/tmp/exec-run-devin-1.json"
  local err="$repo/.claude/tmp/exec-run-devin-1.err"
  rm -f "$export_path"
  : >"$err"
  set +e
  devin --model "$slug" --permission-mode dangerous \
    --respect-workspace-trust=false \
    --export="$export_path" --print="noop" \
    >"$repo/.claude/tmp/exec-run-devin-1.out" 2>"$err"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$repo/.claude/tmp/exec-run-devin-1.exit"
  apply_verdict devin "$out" "$slug"
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

# model_resolved is the value delegate-verdict.sh just emitted.
cursor_model_resolved() {
  jq -r '.model_resolved' "$work/verdict.json"
}

agy_model_resolved() {
  jq -r '.model_resolved' "$work/verdict.json"
}

devin_model_resolved() {
  jq -r '.model_resolved' "$work/verdict.json"
}

run_stub_cursor success "$work/class.txt"
expect_class "cursor stub success → PASS" "$work/class.txt" PASS

run_stub_cursor missing_init "$work/class.txt"
expect_class "cursor stub missing init → FAIL" "$work/class.txt" "FAIL:no init.session_id"

run_stub_cursor model "$work/class.txt"
cursor_model_resolved >"$work/model.txt"
expect_class "cursor stub init model → label" "$work/model.txt" "Grok 4.7 256K High"

run_stub_cursor no_model "$work/class.txt"
cursor_model_resolved >"$work/model.txt"
expect_class "cursor stub init model missing → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor null_model "$work/class.txt"
cursor_model_resolved >"$work/model.txt"
expect_class "cursor stub init model null → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor bad_model "$work/class.txt"
cursor_model_resolved >"$work/model.txt"
expect_class "cursor stub model with tab and \$(...) → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_cursor long_model "$work/class.txt"
cursor_model_resolved >"$work/model.txt"
expect_class "cursor stub 200-char model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_agy success "$work/class.txt"
expect_class "agy stub success → PASS" "$work/class.txt" PASS

run_stub_agy soft_deny "$work/class.txt"
expect_class "agy stub soft-deny → FAIL" "$work/class.txt" "FAIL:stderr soft-deny"

run_stub_agy print_timeout "$work/class.txt"
expect_class "agy stub print_timeout → FAIL" "$work/class.txt" "FAIL:finished_reason=print_timeout"

run_stub_agy missing_init "$work/class.txt"
expect_class "agy stub missing init → FAIL" "$work/class.txt" "FAIL:no init.conversation_id"

run_stub_agy model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub init model → value" "$work/model.txt" "gemini-4-argon-medium"

run_stub_agy nested_model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub init.model → value" "$work/model.txt" "gemini-4-argon-medium"

run_stub_agy no_model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub init model missing → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_agy null_model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub init model null → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_agy bad_model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub model with tab and \$(...) → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_agy long_model "$work/class.txt"
agy_model_resolved >"$work/model.txt"
expect_class "agy stub 200-char model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_devin success "$work/class.txt"
expect_class "devin stub success → PASS" "$work/class.txt" PASS
devin_model_resolved >"$work/model.txt"
expect_class "devin stub model_name → model_resolved" "$work/model.txt" "gpt-6-1-terra-high"

run_stub_devin no_export "$work/class.txt"
expect_class "devin stub exit 1 with no export → FAIL" "$work/class.txt" "FAIL:exit 1 no export"

run_stub_devin model_mismatch "$work/class.txt"
expect_class "devin stub model mismatch → FAIL" "$work/class.txt" "FAIL:fallback: model mismatch gpt-6-1-terra-high→gpt-6-1-terra-low"

run_stub_devin mixed_model "$work/class.txt" swe-2-high
expect_class "devin stub mixed step models → FAIL" "$work/class.txt" "FAIL:fallback: model mismatch swe-2-high→gpt-6-1-terra-low,swe-2-high"
devin_model_resolved >"$work/model.txt"
expect_class "devin stub mixed step models → joined model_resolved" "$work/model.txt" "gpt-6-1-terra-low,swe-2-high"

run_stub_devin missing_session "$work/class.txt"
expect_class "devin stub missing session_id → FAIL" "$work/class.txt" "FAIL:no session_id"

run_stub_devin bad_session "$work/class.txt"
expect_class "devin stub invalid session_id → FAIL" "$work/class.txt" "FAIL:no session_id"

run_stub_devin no_model "$work/class.txt"
expect_class "devin stub no step model_name → FAIL" "$work/class.txt" "FAIL:no resolved model"
devin_model_resolved >"$work/model.txt"
expect_class "devin stub missing model → auto(unresolved)" "$work/model.txt" "auto(unresolved)"

run_stub_devin source_user "$work/class.txt"
expect_class "devin stub last step source user → FAIL" "$work/class.txt" "FAIL:source=user"

export PATH="$ORIG_PATH"
unset CONTRACT_STUB_MODE CONTRACT_NDJSON_DIR

run_suite() {
  local name=$1 rc=0
  bash "$TESTS_DIR/$name" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    report "$name" 0
  else
    report "$name" 1 "exit $rc"
  fi
}

run_suite test-plan-status.sh
run_suite test-delegate-launch.sh
run_suite test-delegate-verdict.sh
run_suite test-delegate-verify.sh
run_suite test-delegate-usage.sh
run_suite test-delegate-review-launch.sh

echo "1..$n"
if [[ "$fails" -ne 0 ]]; then
  echo "FAILED: $fails/$n" >&2
  exit 1
fi
echo "PASS: $n/$n"
