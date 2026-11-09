#!/usr/bin/env bash
# Fixture tests for delegate-review-launch.sh snapshot, check, scope, run, verdict.
# Run with bash. Disables the global excludes file so `.claude/tmp` is not
# already ignored and the pathspec exclude is what the guard relies on.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/delegate-review-launch.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-review-launch.XXXXXX")
empty_ignore="$work/empty-gitignore"
: >"$empty_ignore"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.excludesFile
export GIT_CONFIG_VALUE_0=$empty_ignore

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

assert_rc() {
  local label=$1 want=$2
  if [[ "$LAST_RC" -eq "$want" ]]; then
    pass "$label"
  else
    fail "$label (want rc $want)"
  fi
}

assert_stdout_empty() {
  local label=$1
  if [[ -z "$LAST_OUT" ]]; then
    pass "$label"
  else
    fail "$label (stdout not empty)"
  fi
}

assert_stderr_empty() {
  local label=$1
  if [[ -z "$LAST_ERR" ]]; then
    pass "$label"
  else
    fail "$label (stderr not empty)"
  fi
}

assert_jq() {
  local label=$1 filter=$2
  if [[ -z "$LAST_OUT" ]]; then
    fail "$label (no stdout)"
    return
  fi
  if jq -e "$filter" >/dev/null <<<"$LAST_OUT"; then
    pass "$label"
  else
    fail "$label (jq $filter)"
  fi
}

assert_file() {
  local label=$1 file=$2 want=$3 tmp
  tmp=$(mktemp)
  printf '%s' "$want" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    pass "$label"
  else
    fail "$label"
  fi
  rm -f "$tmp"
}

new_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'init\n' >"$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false \
    commit --no-gpg-sign -qm init
}

commit_paths() {
  local dir=$1 msg=$2
  shift 2
  git -C "$dir" add -- "$@"
  git -C "$dir" -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false \
    commit --no-gpg-sign -qm "$msg"
}

snap_file() {
  printf '%s/.claude/tmp/exec-review-%s.snap' "$1" "$2"
}

guard_file() {
  printf '%s/.claude/tmp/exec-review-%s.guard.json' "$1" "$2"
}

# --- clean snapshot/check for every rid prefix ---

clean_repo="$work/clean"
new_repo "$clean_repo"
for rid in cursor-1 agy-2 devin-3 final-4; do
  run_cmd bash "$SCRIPT" snapshot "$clean_repo" "$rid"
  assert_rc "snapshot $rid exits 0" 0
  assert_stdout_empty "snapshot $rid no stdout"
  assert_stderr_empty "snapshot $rid no stderr"
  if [[ -f $(snap_file "$clean_repo" "$rid") ]]; then
    pass "snapshot $rid writes snap"
  else
    fail "snapshot $rid writes snap"
  fi
  run_cmd bash "$SCRIPT" check "$clean_repo" "$rid"
  assert_rc "check $rid exits 0" 0
  assert_stderr_empty "check $rid no stderr"
  assert_jq "check $rid clean" \
    '.clean == true and .head_moved == false and .index_restored == false and .reverted == [] and .removed == []'
  guard=$(guard_file "$clean_repo" "$rid")
  if [[ "$(cat "$guard")" == "$LAST_OUT" ]]; then
    pass "check $rid guard matches stdout"
  else
    fail "check $rid guard matches stdout"
  fi
done

# --- modified tracked file restored byte-exact ---

mod_repo="$work/mod"
new_repo "$mod_repo"
printf 'line1\nline2\n' >"$mod_repo/tracked.txt"
commit_paths "$mod_repo" add-tracked tracked.txt
cp "$mod_repo/tracked.txt" "$work/tracked-orig"
run_cmd bash "$SCRIPT" snapshot "$mod_repo" cursor-1
assert_rc "mod snapshot exits 0" 0
printf 'nope\n' >"$mod_repo/tracked.txt"
run_cmd bash "$SCRIPT" check "$mod_repo" cursor-1
assert_rc "mod check exits 0" 0
assert_jq "mod reverted" '.clean == false and .reverted == ["tracked.txt"] and .removed == [] and .head_moved == false'
if cmp -s "$work/tracked-orig" "$mod_repo/tracked.txt"; then
  pass "mod restored byte-exact"
else
  fail "mod restored byte-exact"
fi

# --- reviewer-created file removed ---

create_repo="$work/create"
new_repo "$create_repo"
run_cmd bash "$SCRIPT" snapshot "$create_repo" cursor-1
assert_rc "create snapshot exits 0" 0
printf 'hi\n' >"$create_repo/created.txt"
run_cmd bash "$SCRIPT" check "$create_repo" cursor-1
assert_rc "create check exits 0" 0
assert_jq "create removed" '.clean == false and .removed == ["created.txt"] and .reverted == []'
if [[ ! -e "$create_repo/created.txt" ]]; then
  pass "create file removed"
else
  fail "create file removed"
fi

# --- deleted and renamed files restored ---

ren_repo="$work/ren"
new_repo "$ren_repo"
printf 'D\n' >"$ren_repo/del.txt"
printf 'R\n' >"$ren_repo/ren.txt"
commit_paths "$ren_repo" add-ren del.txt ren.txt
cp "$ren_repo/del.txt" "$work/del-orig"
cp "$ren_repo/ren.txt" "$work/ren-orig"
run_cmd bash "$SCRIPT" snapshot "$ren_repo" cursor-1
assert_rc "ren snapshot exits 0" 0
rm -f "$ren_repo/del.txt"
mv "$ren_repo/ren.txt" "$ren_repo/ren2.txt"
run_cmd bash "$SCRIPT" check "$ren_repo" cursor-1
assert_rc "ren check exits 0" 0
assert_jq "ren reverted and removed" \
  '.reverted | sort == ["del.txt","ren.txt"]' 
assert_jq "ren removed new name" '.removed == ["ren2.txt"]'
if cmp -s "$work/del-orig" "$ren_repo/del.txt" && cmp -s "$work/ren-orig" "$ren_repo/ren.txt" && [[ ! -e "$ren_repo/ren2.txt" ]]; then
  pass "deleted and renamed restored"
else
  fail "deleted and renamed restored"
fi

# --- pre-existing dirty and untracked survive a revert ---

dirty_repo="$work/dirty"
new_repo "$dirty_repo"
printf 'base\n' >"$dirty_repo/tracked"
printf 'other\n' >"$dirty_repo/other"
commit_paths "$dirty_repo" add-dirty tracked other
printf 'dirty\n' >"$dirty_repo/tracked"
printf 'free\n' >"$dirty_repo/extra"
run_cmd bash "$SCRIPT" snapshot "$dirty_repo" cursor-1
assert_rc "dirty snapshot exits 0" 0
printf 'changed\n' >"$dirty_repo/other"
run_cmd bash "$SCRIPT" check "$dirty_repo" cursor-1
assert_rc "dirty check exits 0" 0
assert_jq "dirty reverts only the reviewer edit" '.reverted == ["other"] and .removed == []'
assert_file "dirty file survives" "$dirty_repo/tracked" $'dirty\n'
assert_file "untracked survives" "$dirty_repo/extra" $'free\n'
assert_file "other restored" "$dirty_repo/other" $'other\n'

# --- staged change undone, index restored ---

stage_repo="$work/stage"
new_repo "$stage_repo"
printf 'base\n' >"$stage_repo/f"
commit_paths "$stage_repo" add-f f
printf 'dirty\n' >"$stage_repo/f"
run_cmd bash "$SCRIPT" snapshot "$stage_repo" cursor-1
assert_rc "stage snapshot exits 0" 0
snap_index=$(sed -n 's/^index=//p' "$(snap_file "$stage_repo" cursor-1)")
git -C "$stage_repo" add f
run_cmd bash "$SCRIPT" check "$stage_repo" cursor-1
assert_rc "stage check exits 0" 0
assert_jq "stage index restored" '.index_restored == true and .head_moved == false and .reverted == [] and .removed == [] and .clean == false'
assert_file "staged file content untouched" "$stage_repo/f" $'dirty\n'
now_index=$(git -C "$stage_repo" write-tree)
if [[ "$now_index" == "$snap_index" ]]; then
  pass "stage index tree matches snap"
else
  fail "stage index tree matches snap"
fi

# --- commit by reviewer: head moved, file content untouched ---

commit_repo="$work/commit"
new_repo "$commit_repo"
printf 'v1\n' >"$commit_repo/f"
commit_paths "$commit_repo" add-v1 f
cp "$commit_repo/f" "$work/v1-orig"
run_cmd bash "$SCRIPT" snapshot "$commit_repo" final-1
assert_rc "commit snapshot exits 0" 0
snap_head=$(sed -n 's/^head=//p' "$(snap_file "$commit_repo" final-1)")
git -C "$commit_repo" -c user.email=t@example.com -c user.name=reviewer -c commit.gpgsign=false \
  commit --no-gpg-sign --allow-empty -qm reviewer
new_head=$(git -C "$commit_repo" rev-parse HEAD)
run_cmd bash "$SCRIPT" check "$commit_repo" final-1
assert_rc "commit check exits 0" 0
assert_jq "commit head_moved" '.head_moved == true and .clean == false and .reverted == [] and .removed == [] and .index_restored == false'
want_err="HEAD moved: git log ${snap_head}..HEAD"
if [[ "$LAST_ERR" == "$want_err" ]]; then
  pass "commit stderr hint"
else
  fail "commit stderr hint"
fi
if cmp -s "$work/v1-orig" "$commit_repo/f"; then
  pass "commit file content untouched"
else
  fail "commit file content untouched"
fi
after_head=$(git -C "$commit_repo" rev-parse HEAD)
if [[ "$after_head" == "$new_head" && "$after_head" != "$snap_head" ]]; then
  pass "commit leaves HEAD"
else
  fail "commit leaves HEAD"
fi

# --- .claude/tmp writes ignored ---

tmp_repo="$work/tmp"
new_repo "$tmp_repo"
run_cmd bash "$SCRIPT" snapshot "$tmp_repo" cursor-1
assert_rc "tmp snapshot exits 0" 0
printf 'secret\n' >"$tmp_repo/.claude/tmp/note"
printf 'x\n' >"$tmp_repo/.claude/tmp/exec-review-cursor-1-extra"
run_cmd bash "$SCRIPT" check "$tmp_repo" cursor-1
assert_rc "tmp check exits 0" 0
assert_jq "tmp clean" '.clean == true and .reverted == [] and .removed == []'
assert_file "tmp note kept" "$tmp_repo/.claude/tmp/note" $'secret\n'
assert_file "tmp extra kept" "$tmp_repo/.claude/tmp/exec-review-cursor-1-extra" $'x\n'

# --- scope: outside / protected / untracked; legacy outside empty; absolute plan excluded ---

scope_repo="$work/scope"
new_repo "$scope_repo"
mkdir -p "$scope_repo/src" "$scope_repo/sub" "$scope_repo/.cursor/rules" \
  "$scope_repo/.agents" "$scope_repo/.github/workflows" "$scope_repo/docs"
printf 'a\n' >"$scope_repo/src/a.sh"
printf 'b\n' >"$scope_repo/src/b.sh"
printf 'c\n' >"$scope_repo/CLAUDE.md"
printf 'd\n' >"$scope_repo/sub/AGENTS.md"
printf 'e\n' >"$scope_repo/GEMINI.md"
printf 'f\n' >"$scope_repo/.cursor/rules/x.md"
printf 'g\n' >"$scope_repo/.agents/y.md"
printf 'h\n' >"$scope_repo/.github/workflows/z.yml"
printf 'plan\n' >"$scope_repo/docs/plan.md"
commit_paths "$scope_repo" add-scope \
  src/a.sh src/b.sh CLAUDE.md sub/AGENTS.md GEMINI.md \
  .cursor/rules/x.md .agents/y.md .github/workflows/z.yml docs/plan.md
printf 'a2\n' >"$scope_repo/src/a.sh"
printf 'b2\n' >"$scope_repo/src/b.sh"
printf 'c2\n' >"$scope_repo/CLAUDE.md"
printf 'd2\n' >"$scope_repo/sub/AGENTS.md"
printf 'e2\n' >"$scope_repo/GEMINI.md"
printf 'f2\n' >"$scope_repo/.cursor/rules/x.md"
printf 'g2\n' >"$scope_repo/.agents/y.md"
printf 'h2\n' >"$scope_repo/.github/workflows/z.yml"
printf 'plan2\n' >"$scope_repo/docs/plan.md"
printf 'new\n' >"$scope_repo/src/new.sh"
mkdir -p "$scope_repo/.claude/tmp"
printf 'junk\n' >"$scope_repo/.claude/tmp/junk"
cat >"$work/rows-v2.json" <<'EOF'
{"map":"v2","files_union":["src/a.sh","CLAUDE.md"]}
EOF
cat >"$work/rows-legacy.json" <<'EOF'
{"map":"legacy","files_union":["src/a.sh","CLAUDE.md"]}
EOF
plan_abs="$scope_repo/docs/plan.md"
run_cmd bash "$SCRIPT" scope "$scope_repo" HEAD "$work/rows-v2.json" "$plan_abs"
assert_rc "scope v2 exits 0" 0
assert_jq "scope v2 outside" \
  '.outside == [".agents/y.md",".cursor/rules/x.md",".github/workflows/z.yml","GEMINI.md","src/b.sh","src/new.sh","sub/AGENTS.md"]'
assert_jq "scope v2 protected" \
  '.protected == [".agents/y.md",".cursor/rules/x.md",".github/workflows/z.yml","CLAUDE.md","GEMINI.md","sub/AGENTS.md"]'
assert_jq "scope v2 untracked" '.untracked == ["src/new.sh"]'
assert_jq "scope v2 drops union and plan and tmp" \
  '([.outside[], .protected[], .untracked[]] | index("src/a.sh") == null) and ([.outside[], .protected[], .untracked[]] | index("docs/plan.md") == null) and ([.outside[], .protected[], .untracked[]] | index(".claude/tmp/junk") == null)'

run_cmd bash "$SCRIPT" scope "$scope_repo" HEAD "$work/rows-legacy.json" "$plan_abs"
assert_rc "scope legacy exits 0" 0
assert_jq "scope legacy outside empty" '.outside == []'
assert_jq "scope legacy still protects" \
  '.protected == [".agents/y.md",".cursor/rules/x.md",".github/workflows/z.yml","CLAUDE.md","GEMINI.md","sub/AGENTS.md"]'
assert_jq "scope legacy untracked" '.untracked == ["src/new.sh"]'
assert_jq "scope legacy drops absolute plan" \
  '([.outside[], .protected[], .untracked[]] | index("docs/plan.md") == null)'

# --- case-variant protected and non-ascii check ---

case_repo="$work/case"
new_repo "$case_repo"
printf 'x\n' >"$case_repo/clAudE.md"
commit_paths "$case_repo" add-case "clAudE.md"
printf 'y\n' >"$case_repo/clAudE.md"
printf 'new\n' >"$case_repo/créated.txt"
run_cmd bash "$SCRIPT" scope "$case_repo" HEAD '{"map":"v2","files_union":[]}' "$case_repo/plan.md"
assert_rc "case scope exits 0" 0
assert_jq "case scope protected" '.protected == ["clAudE.md"]'
run_cmd bash "$SCRIPT" snapshot "$case_repo" cursor-1
assert_rc "case snapshot exits 0" 0
printf 'z\n' >"$case_repo/clAudE.md"
printf 'more\n' >"$case_repo/créated-2.txt"
run_cmd bash "$SCRIPT" check "$case_repo" cursor-1
assert_rc "case check exits 0" 0
assert_jq "case check reverted and removed" '.reverted == ["clAudE.md"] and .removed == ["créated-2.txt"]'

# --- bad rid / root ---

run_cmd bash "$SCRIPT" snapshot "$clean_repo" nope
assert_rc "bad rid exits 2" 2
run_cmd bash "$SCRIPT" snapshot "$clean_repo" cursor-
assert_rc "rid missing digits exits 2" 2
run_cmd bash "$SCRIPT" snapshot "$clean_repo" final-
assert_rc "final rid missing digits exits 2" 2
run_cmd bash "$SCRIPT" check "$clean_repo" 'devin-'
assert_rc "bad check rid exits 2" 2
mkdir -p "$work/notrepo"
run_cmd bash "$SCRIPT" snapshot "$work/notrepo" cursor-1
assert_rc "non-repo root exits 2" 2
run_cmd bash "$SCRIPT" snapshot relative-root cursor-1
assert_rc "relative root exits 2" 2
mkdir -p "$clean_repo/sub"
run_cmd bash "$SCRIPT" snapshot "$clean_repo/sub" cursor-1
assert_rc "subdir root exits 2" 2
run_cmd bash "$SCRIPT" snapshot "$clean_repo/README.md" cursor-1
assert_rc "file root exits 2" 2
run_cmd bash "$SCRIPT" check "$clean_repo" cursor-99
assert_rc "check without snap exits 2" 2
printf 'head=--bad\nbranch=refs/heads/main\nindex=0123456789abcdef0123456789abcdef01234567\nwork=0123456789abcdef0123456789abcdef01234567\n' \
  >"$(snap_file "$clean_repo" cursor-98)"
run_cmd bash "$SCRIPT" check "$clean_repo" cursor-98
assert_rc "check with malformed snap hash exits 2" 2
run_cmd bash "$SCRIPT" scope "$clean_repo" not-a-rev "$work/rows-v2.json" "$plan_abs"
assert_rc "bad base exits 2" 2
run_cmd bash "$SCRIPT" scope "$clean_repo" HEAD 'not-json' "$plan_abs"
assert_rc "bad rows-json exits 2" 2

# --- run --print argv, fusion prefix, missing brief ---

unset DELEGATE_REVIEW_TIMEOUT || true

prompt_for() {
  printf 'Read .claude/tmp/exec-review-%s-brief.md and follow it exactly. Do not edit any file.' "$1"
}

assert_stdout_eq() {
  local label=$1 want=$2
  if [[ "$LAST_OUT" == "$want" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

run_repo="$work/run"
new_repo "$run_repo"
printf 'base\n' >"$run_repo/tracked.txt"
commit_paths "$run_repo" add-tracked tracked.txt

cursor_model=claude-opus-5-5-medium
agy_model=claude-opus-5-5-medium
devin_model=fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max
cursor_prompt=$(prompt_for cursor-1)
agy_prompt=$(prompt_for agy-2)
devin_prompt=$(prompt_for devin-3)

run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 "$cursor_model"
assert_rc "cursor --print exits 0" 0
assert_stderr_empty "cursor --print no stderr"
want=$(printf '%s\n' \
  agent -p --mode=ask --trust --workspace "$run_repo" \
  --output-format text --model "$cursor_model" \
  "$cursor_prompt")
want=${want%$'\n'}
assert_stdout_eq "cursor --print argv" "$want"
if [[ ! -e "$run_repo/.claude" ]]; then
  pass "cursor --print writes nothing"
else
  fail "cursor --print writes nothing"
fi

run_cmd bash "$SCRIPT" run --print agy-plan "$run_repo" agy-2 "$agy_model"
assert_rc "agy --print exits 0" 0
want=$(printf '%s\n' \
  agy --mode plan --output-format text --model "$agy_model" \
  -p "$agy_prompt")
want=${want%$'\n'}
assert_stdout_eq "agy --print argv" "$want"

run_cmd bash "$SCRIPT" run --print devin-fusion "$run_repo" devin-3 "$devin_model"
assert_rc "devin --print exits 0" 0
want=$(printf '%s\n' \
  env -u DEVIN_REFUSAL_FALLBACK \
  devin --model "$devin_model" --permission-mode auto \
  --respect-workspace-trust=false \
  "--print=${devin_prompt}")
want=${want%$'\n'}
assert_stdout_eq "devin --print argv" "$want"
if [[ "$LAST_OUT" != *dangerous* && "$LAST_OUT" != *--force* && "$LAST_OUT" != *dangerously-skip-permissions* ]]; then
  pass "review argv has no write-mode flags"
else
  fail "review argv has no write-mode flags"
fi

run_cmd bash "$SCRIPT" run --print devin-fusion "$run_repo" devin-3 "$cursor_model"
assert_rc "devin without fusion- prefix exits 2" 2
run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 "$devin_model"
assert_rc "cursor refuses fusion- prefix" 2
run_cmd bash "$SCRIPT" run --print agy-plan "$run_repo" agy-2 "$devin_model"
assert_rc "agy refuses fusion- prefix" 2
run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 'bad model'
assert_rc "invalid model exits 2" 2
run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 '-bad-flag'
assert_rc "leading-hyphen model exits 2" 2
run_cmd bash "$SCRIPT" run --print cursor "$run_repo" cursor-1 "$cursor_model"
assert_rc "unknown runner exits 2" 2
run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" nope "$cursor_model"
assert_rc "run bad rid exits 2" 2
run_cmd bash "$SCRIPT" run --print cursor-ask relative-root cursor-1 "$cursor_model"
assert_rc "run relative root exits 2" 2
mkdir -p "$work/notrepo-run"
run_cmd bash "$SCRIPT" run --print cursor-ask "$work/notrepo-run" cursor-1 "$cursor_model"
assert_rc "run non-repo root exits 2" 2
run_cmd env DELEGATE_REVIEW_TIMEOUT=bad bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 "$cursor_model"
assert_rc "bad DELEGATE_REVIEW_TIMEOUT exits 2" 2
run_cmd env DELEGATE_REVIEW_TIMEOUT=30 bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 "$cursor_model"
assert_rc "unitless DELEGATE_REVIEW_TIMEOUT exits 2" 2
if [[ ! -e "$run_repo/.claude" ]]; then
  pass "rejected run --print writes nothing"
else
  fail "rejected run --print writes nothing"
fi

write_brief() {
  local dir=$1 rid=$2
  mkdir -p "$dir/.claude/tmp"
  printf 'brief %s\n' "$rid" >"$dir/.claude/tmp/exec-review-${rid}-brief.md"
}

run_cmd bash "$SCRIPT" run cursor-ask "$run_repo" cursor-9 "$cursor_model"
assert_rc "missing brief exits 2" 2
if [[ ! -e "$run_repo/.claude/tmp/exec-review-cursor-9.snap" && ! -e "$run_repo/.claude/tmp/exec-review-cursor-9.exit" ]]; then
  pass "missing brief writes no snap"
else
  fail "missing brief writes no snap"
fi
write_brief "$run_repo" devin-1
run_cmd bash "$SCRIPT" run devin-fusion "$run_repo" devin-1 "$cursor_model"
assert_rc "run rejects devin model without fusion- prefix" 2
if [[ ! -e "$run_repo/.claude/tmp/exec-review-devin-1.snap" ]]; then
  pass "fusion rejection writes no snap"
else
  fail "fusion rejection writes no snap"
fi
write_brief "$run_repo" cursor-1
run_cmd bash "$SCRIPT" run cursor-ask "$run_repo" cursor-1 "$devin_model"
assert_rc "run rejects cursor fusion- model" 2

# --- PATH stubs: argv echo, revert, timeout ceiling ---

stub_body="$work/stub-cli"
cat >"$stub_body" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"${STUB_TIMEOUT_LOG:?}"
if [[ -n "${STUB_WRITE:-}" ]]; then
  printf '%s' "${STUB_BODY:-dirty}" >"$STUB_WRITE"
fi
if [[ -n "${STUB_STDOUT:-}" ]]; then
  printf '%s' "$STUB_STDOUT"
fi
if [[ -n "${STUB_STDERR:-}" ]]; then
  printf '%s' "$STUB_STDERR" >&2
fi
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub_body"

link_bins() {
  local dest=$1 cmd bin
  mkdir -p "$dest"
  for cmd in git jq mktemp cp rm grep cat mkdir tr sed; do
    bin=$(command -v "$cmd")
    ln -sf "$bin" "$dest/$cmd"
  done
}

pass_trailer=$'review\nFINDINGS: blocking=0 important=0 nit=0\nVERDICT: PASS\n'

runpath="$work/runpath"
link_bins "$runpath"
cp "$stub_body" "$runpath/timeout"
chmod +x "$runpath/timeout"
timeout_log="$work/timeout.args"
bash_bin=$(command -v bash)

run_cmd bash "$SCRIPT" run --print cursor-ask "$run_repo" cursor-1 "$cursor_model"
cursor_print=$LAST_OUT
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  DELEGATE_TIMEOUT=1s STUB_RC=0 STUB_STDOUT="$pass_trailer" STUB_STDERR=$'tool-err\n' \
  "$bash_bin" "$SCRIPT" run cursor-ask "$run_repo" cursor-1 "$cursor_model"
assert_rc "cursor run exits 0" 0
assert_jq "cursor run guard clean" '.clean == true and .reverted == [] and .removed == []'
assert_file "cursor stdout captured" "$run_repo/.claude/tmp/exec-review-cursor-1.md" "$pass_trailer"
assert_file "cursor stderr captured" "$run_repo/.claude/tmp/exec-review-cursor-1.err" $'tool-err\n'
if [[ "$(tr -d '[:space:]' <"$run_repo/.claude/tmp/exec-review-cursor-1.exit")" == 0 ]]; then
  pass "cursor .exit is 0"
else
  fail "cursor .exit is 0"
fi
got_log=$(cat "$timeout_log")
want_log=$'--kill-after=2m\n30m\n'"$cursor_print"
if [[ "$got_log" == "$want_log" ]]; then
  pass "cursor run argv matches --print and default ceiling"
else
  LAST_OUT=$got_log
  fail "cursor run argv matches --print and default ceiling"
fi
run_cmd bash "$SCRIPT" verdict "$run_repo" cursor-1
assert_rc "cursor happy verdict exits 0" 0
assert_jq "cursor happy verdict" \
  '.ok == true and .verdict == "PASS" and .blocking == 0 and .important == 0 and .nit == 0 and .timed_out == false and .guard_clean == true and .reasons == [] and (.blocking | type == "number")'

write_brief "$run_repo" agy-2
run_cmd bash "$SCRIPT" run --print agy-plan "$run_repo" agy-2 "$agy_model"
agy_print=$LAST_OUT
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  STUB_RC=0 STUB_STDOUT="$pass_trailer" \
  "$bash_bin" "$SCRIPT" run agy-plan "$run_repo" agy-2 "$agy_model"
assert_rc "agy run exits 0" 0
got_log=$(cat "$timeout_log")
want_log=$'--kill-after=2m\n30m\n'"$agy_print"
if [[ "$got_log" == "$want_log" ]]; then
  pass "agy run argv matches --print"
else
  LAST_OUT=$got_log
  fail "agy run argv matches --print"
fi

write_brief "$run_repo" devin-3
run_cmd bash "$SCRIPT" run --print devin-fusion "$run_repo" devin-3 "$devin_model"
devin_print=$LAST_OUT
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  STUB_RC=0 STUB_STDOUT="$pass_trailer" \
  "$bash_bin" "$SCRIPT" run devin-fusion "$run_repo" devin-3 "$devin_model"
assert_rc "devin run exits 0" 0
got_log=$(cat "$timeout_log")
want_log=$'--kill-after=2m\n30m\n'"$devin_print"
if [[ "$got_log" == "$want_log" ]]; then
  pass "devin run argv matches --print"
else
  LAST_OUT=$got_log
  fail "devin run argv matches --print"
fi

write_brief "$run_repo" cursor-4
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  STUB_RC=0 STUB_STDOUT="$pass_trailer" \
  STUB_WRITE="$run_repo/tracked.txt" STUB_BODY=$'dirty\n' \
  "$bash_bin" "$SCRIPT" run cursor-ask "$run_repo" cursor-4 "$cursor_model"
assert_rc "stub write run exits 0" 0
assert_jq "stub write reverted" '.clean == false and .reverted == ["tracked.txt"] and .removed == []'
assert_file "stub write restored byte-exact" "$run_repo/tracked.txt" $'base\n'
run_cmd bash "$SCRIPT" verdict "$run_repo" cursor-4
assert_rc "stub write verdict exits 0" 0
assert_jq "stub write guard tripped" \
  '.ok == false and .verdict == "PASS" and .guard_clean == false and .timed_out == false and .reasons == ["guard tripped"]'

write_brief "$run_repo" cursor-5
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  STUB_RC=124 STUB_STDOUT="$pass_trailer" \
  "$bash_bin" "$SCRIPT" run cursor-ask "$run_repo" cursor-5 "$cursor_model"
assert_rc "timeout run exits 0" 0
if [[ "$(tr -d '[:space:]' <"$run_repo/.claude/tmp/exec-review-cursor-5.exit")" == 124 ]]; then
  pass "timeout .exit is 124"
else
  fail "timeout .exit is 124"
fi
run_cmd bash "$SCRIPT" verdict "$run_repo" cursor-5
assert_rc "timeout verdict exits 0" 0
assert_jq "timeout 124" \
  '.ok == false and .timed_out == true and .guard_clean == true and .verdict == "PASS" and .reasons == ["exit 124", "timeout ceiling"]'

write_brief "$run_repo" cursor-6
rm -f "$timeout_log"
run_cmd env PATH="$runpath" STUB_TIMEOUT_LOG="$timeout_log" \
  DELEGATE_REVIEW_TIMEOUT=5s STUB_RC=0 STUB_STDOUT="$pass_trailer" \
  "$bash_bin" "$SCRIPT" run cursor-ask "$run_repo" cursor-6 "$cursor_model"
assert_rc "override ceiling run exits 0" 0
if [[ "$(sed -n '2p' "$timeout_log")" == 5s ]]; then
  pass "DELEGATE_REVIEW_TIMEOUT overrides the ceiling"
else
  fail "DELEGATE_REVIEW_TIMEOUT overrides the ceiling"
fi

# missing timeout → WARN and still runs
notime="$work/notime"
link_bins "$notime"
cp "$stub_body" "$notime/agent"
chmod +x "$notime/agent"
write_brief "$run_repo" cursor-8
rm -f "$timeout_log"
run_cmd env PATH="$notime" STUB_TIMEOUT_LOG="$timeout_log" STUB_RC=4 STUB_STDOUT="$pass_trailer" \
  "$(command -v bash)" "$SCRIPT" run cursor-ask "$run_repo" cursor-8 "$cursor_model"
assert_rc "missing timeout still exits 0" 0
if [[ "$LAST_ERR" == "WARN: no timeout binary; running without ceiling" ]]; then
  pass "missing timeout warns"
else
  fail "missing timeout warns"
fi
if [[ "$(tr -d '[:space:]' <"$run_repo/.claude/tmp/exec-review-cursor-8.exit")" == 4 ]]; then
  pass "missing timeout runs the cli"
else
  fail "missing timeout runs the cli"
fi
if grep -q -F -- '--mode=ask' "$timeout_log" && ! grep -q -F -- '--kill-after=2m' "$timeout_log"; then
  pass "missing timeout invoked agent directly"
else
  fail "missing timeout invoked agent directly"
fi

# gtimeout is used when timeout is absent.
gto="$work/gto"
link_bins "$gto"
cp "$stub_body" "$gto/gtimeout"
chmod +x "$gto/gtimeout"
write_brief "$run_repo" cursor-7
rm -f "$timeout_log"
run_cmd env PATH="$gto" STUB_TIMEOUT_LOG="$timeout_log" STUB_RC=6 STUB_STDOUT="$pass_trailer" \
  "$(command -v bash)" "$SCRIPT" run cursor-ask "$run_repo" cursor-7 "$cursor_model"
assert_rc "gtimeout run exits 0" 0
assert_stderr_empty "gtimeout path does not warn"
if [[ "$(tr -d '[:space:]' <"$run_repo/.claude/tmp/exec-review-cursor-7.exit")" == 6 ]]; then
  pass "gtimeout used when timeout is absent"
else
  fail "gtimeout used when timeout is absent"
fi
if [[ "$(head -2 "$timeout_log")" == $'--kill-after=2m\n30m' ]]; then
  pass "gtimeout receives the ceiling flags"
else
  fail "gtimeout receives the ceiling flags"
fi

# --- verdict trailer variants, task-style, exit 137 ---

put_review() {
  local dir=$1 rid=$2 body=$3 clean=$4
  local guard exitc
  mkdir -p "$dir/.claude/tmp"
  printf '%s' "$body" >"$dir/.claude/tmp/exec-review-${rid}.md"
  if [[ "$clean" == true ]]; then
    guard='{"clean":true,"head_moved":false,"index_restored":false,"reverted":[],"removed":[]}'
  else
    guard='{"clean":false,"head_moved":false,"index_restored":false,"reverted":["tracked.txt"],"removed":[]}'
  fi
  printf '%s\n' "$guard" >"$dir/.claude/tmp/exec-review-${rid}.guard.json"
  rm -f "$dir/.claude/tmp/exec-review-${rid}.exit"
  if [[ $# -ge 5 ]]; then
    exitc=$5
    printf '%s\n' "$exitc" >"$dir/.claude/tmp/exec-review-${rid}.exit"
  fi
}

fix_body=$'review\nFINDINGS: blocking=1 important=2 nit=0\nVERDICT: FIX\n'
fail_body=$'review\nFINDINGS: blocking=0 important=3 nit=1\nVERDICT: FAIL\n'
pass_nits=$'review\nFINDINGS: blocking=0 important=0 nit=2\nVERDICT: PASS\n'
bad_pass=$'review\nFINDINGS: blocking=1 important=0 nit=0\nVERDICT: PASS\n'
bad_fix=$'review\nFINDINGS: blocking=0 important=0 nit=4\nVERDICT: FIX\n'
bad_fail=$'review\nFINDINGS: blocking=0 important=0 nit=0\nVERDICT: FAIL\n'
missing_body=$'No high-confidence issues found.\n'
findings_only=$'FINDINGS: blocking=1 important=1 nit=0\n'
verdict_only=$'VERDICT: PASS\n'
multi_body=$'FINDINGS: blocking=4 important=4 nit=4\nVERDICT: FAIL\nnote\nFINDINGS: blocking=0 important=2 nit=1\nVERDICT: FIX\n'
multi_swap=$'VERDICT: PASS\nFINDINGS: blocking=9 important=0 nit=0\nFINDINGS: blocking=0 important=1 nit=0\nVERDICT: FIX\n'

put_review "$run_repo" final-1 "$fix_body" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-1
assert_rc "FIX verdict exits 0" 0
assert_jq "FIX verdict" \
  '.ok == true and .verdict == "FIX" and .blocking == 1 and .important == 2 and .nit == 0 and .timed_out == false and .guard_clean == true and .reasons == []'

put_review "$run_repo" final-2 "$fail_body" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-2
assert_jq "FAIL verdict" \
  '.ok == true and .verdict == "FAIL" and .blocking == 0 and .important == 3 and .nit == 1 and .reasons == []'

put_review "$run_repo" final-3 "$pass_nits" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-3
assert_jq "PASS with nits" \
  '.ok == true and .verdict == "PASS" and .nit == 2 and .reasons == []'

put_review "$run_repo" final-4 "$bad_pass" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-4
assert_jq "inconsistent PASS" \
  '.ok == false and .verdict == "PASS" and .blocking == 1 and .reasons == ["inconsistent verdict"]'

put_review "$run_repo" final-5 "$bad_fix" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-5
assert_jq "inconsistent FIX" \
  '.ok == false and .verdict == "FIX" and .nit == 4 and .reasons == ["inconsistent verdict"]'

put_review "$run_repo" final-6 "$bad_fail" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-6
assert_jq "inconsistent FAIL" \
  '.ok == false and .verdict == "FAIL" and .reasons == ["inconsistent verdict"]'

put_review "$run_repo" final-7 "$missing_body" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-7
assert_jq "missing trailer" \
  '.ok == false and .verdict == null and .blocking == 0 and .important == 0 and .nit == 0 and .reasons == ["no verdict line"]'

put_review "$run_repo" final-8 "$findings_only" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-8
assert_jq "findings without verdict" \
  '.ok == false and .verdict == null and .blocking == 1 and .important == 1 and .reasons == ["no verdict line"]'

put_review "$run_repo" final-9 "$verdict_only" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-9
assert_jq "verdict without findings" \
  '.ok == false and .verdict == "PASS" and .blocking == 0 and .reasons == ["no verdict line"]'

put_review "$run_repo" final-10 "$multi_body" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-10
assert_jq "multiple trailers last wins" \
  '.ok == true and .verdict == "FIX" and .blocking == 0 and .important == 2 and .nit == 1 and .reasons == []'

put_review "$run_repo" final-11 "$multi_swap" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-11
assert_jq "last findings and last verdict are independent" \
  '.ok == true and .verdict == "FIX" and .blocking == 0 and .important == 1 and .nit == 0 and .reasons == []'

put_review "$run_repo" final-12 "$pass_trailer" true
rm -f "$run_repo/.claude/tmp/exec-review-final-12.exit"
run_cmd bash "$SCRIPT" verdict "$run_repo" final-12
assert_jq "task-style verdict without .exit" \
  '.ok == true and .verdict == "PASS" and .timed_out == false and .guard_clean == true and .reasons == []'

# CRLF trailer test case
crlf_body=$(printf 'Some notes\r\nFINDINGS: blocking=0 important=0 nit=1\r\nVERDICT: PASS\r\n')
put_review "$run_repo" final-999 "$crlf_body" true
run_cmd bash "$SCRIPT" verdict "$run_repo" final-999
assert_jq "CRLF trailer verdict" \
  '.ok == true and .verdict == "PASS" and .nit == 1 and .blocking == 0 and .important == 0 and .reasons == []'

put_review "$run_repo" final-13 "$pass_trailer" true 0
run_cmd bash "$SCRIPT" verdict "$run_repo" final-13
assert_jq "exit 0 is not a reason" \
  '.ok == true and .timed_out == false and .reasons == []'

put_review "$run_repo" final-14 "$pass_trailer" true 7
run_cmd bash "$SCRIPT" verdict "$run_repo" final-14
assert_jq "nonzero exit" \
  '.ok == false and .timed_out == false and .verdict == "PASS" and .reasons == ["exit 7"]'

put_review "$run_repo" final-15 "$pass_trailer" true 137
run_cmd bash "$SCRIPT" verdict "$run_repo" final-15
assert_jq "timeout 137" \
  '.ok == false and .timed_out == true and .reasons == ["exit 137", "timeout ceiling"]'

put_review "$run_repo" final-16 "$bad_pass" false 124
run_cmd bash "$SCRIPT" verdict "$run_repo" final-16
assert_jq "reason order" \
  '.ok == false and .timed_out == true and .guard_clean == false and .verdict == "PASS" and .blocking == 1 and .reasons == ["exit 124", "timeout ceiling", "guard tripped", "inconsistent verdict"]'

rm -f "$run_repo/.claude/tmp/exec-review-final-17.md"
printf '%s\n' '{"clean":true}' >"$run_repo/.claude/tmp/exec-review-final-17.guard.json"
run_cmd bash "$SCRIPT" verdict "$run_repo" final-17
assert_rc "verdict missing .md exits 2" 2
printf '%s\n' "$pass_trailer" >"$run_repo/.claude/tmp/exec-review-final-18.md"
rm -f "$run_repo/.claude/tmp/exec-review-final-18.guard.json"
run_cmd bash "$SCRIPT" verdict "$run_repo" final-18
assert_rc "verdict missing guard exits 2" 2
printf '%s\n' "$pass_trailer" >"$run_repo/.claude/tmp/exec-review-final-19.md"
printf '%s\n' '{"clean":"yes"}' >"$run_repo/.claude/tmp/exec-review-final-19.guard.json"
run_cmd bash "$SCRIPT" verdict "$run_repo" final-19
assert_rc "verdict bad guard exits 2" 2
run_cmd bash "$SCRIPT" verdict "$run_repo" nope
assert_rc "verdict bad rid exits 2" 2

printf 'PASS/FAIL summary: %s failed\n' "$fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
