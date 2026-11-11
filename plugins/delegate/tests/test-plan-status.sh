#!/usr/bin/env bash
# Fixture tests for plan-status.sh lock + rows. Run with bash.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/plan-status.sh"
SOT="$ROOT/nng-kit/plugins/delegate/references/execution-status.md"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-plan-status.XXXXXX")
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

assert_rc() {
  local label=$1 want=$2
  if [[ "$LAST_RC" -eq "$want" ]]; then
    pass "$label"
  else
    fail "$label (want rc $want)"
  fi
}

assert_stdout() {
  local label=$1 want=$2
  if [[ "$LAST_OUT" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (want stdout [$want])"
  fi
}

assert_stderr_has() {
  local label=$1 want=$2
  case "$LAST_ERR" in
    *"$want"*) pass "$label" ;;
    *) fail "$label (stderr missing [$want])" ;;
  esac
}

assert_stdout_empty() {
  local label=$1
  if [[ -z "$LAST_OUT" ]]; then
    pass "$label"
  else
    fail "$label (stdout not empty)"
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

# --- lock ---

plan_sha_of() {
  local snippet
  snippet=$(awk '
    $0 == "<!-- plan-sha:start -->" { grab = 1; next }
    $0 == "<!-- plan-sha:end -->" { exit }
    grab && $0 !~ /^```/ { print }
  ' "$SOT")
  eval "$snippet"
  plan_sha "$1"
}

cat >"$work/lock.md" <<'EOF'
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
---

# Plan

BODYTOKEN stays hashed.

## Execution map

| ID | Tier |
| --- | --- |
| S1 | execute |

## Execution log

- **Overall:** not-started

| ID | Status | Notes |
| --- | --- | --- |
| S1 | pending | |
EOF

sum=$(plan_sha_of "$work/lock.md")
# Frontmatter is outside the hash, so rewriting plan_sha does not change it.
awk -v sum="$sum" '
  /^plan_sha:/ { print "plan_sha: \"" sum "\""; next }
  { print }
' "$work/lock.md" >"$work/lock-ok.md"

run_cmd "$BASH" "$SCRIPT" lock "$work/lock-ok.md"
assert_rc "lock ok exits 0" 0
assert_stdout "lock ok prints ok" "ok"

# A log edit stays inside the excluded section.
awk '/^\| S1 \| pending/ { print "| S1 | done | edited |"; next } { print }' \
  "$work/lock-ok.md" >"$work/lock-log.md"
run_cmd "$BASH" "$SCRIPT" lock "$work/lock-log.md"
assert_rc "lock ignores execution log edits" 0
assert_stdout "lock still ok after log edit" "ok"

awk '/BODYTOKEN/ { print "BODYTOKEN changed"; next } { print }' \
  "$work/lock-ok.md" >"$work/lock-bad.md"
run_cmd "$BASH" "$SCRIPT" lock "$work/lock-bad.md"
assert_rc "lock mismatch exits 3" 3
assert_stdout_empty "lock mismatch has no stdout"
assert_stderr_has "lock mismatch message" \
  "plan body changed since approval; re-approve with /make-plan update $work/lock-bad.md"

cat >"$work/legacy.md" <<'EOF'
---
execution:
  status: not-started
---

# Legacy

No hash here.
EOF
run_cmd "$BASH" "$SCRIPT" lock "$work/legacy.md"
assert_rc "lock legacy exits 0" 0
assert_stdout "lock legacy prints legacy" "legacy"
assert_stderr_has "lock legacy warning" "WARN: legacy plan (no plan_sha)"

# --- shared v2 header helpers ---

write_v2() {
  local dest=$1
  cat >"$dest"
}

# v2 selects only own-backend rows; top|session and mid|subagent are skipped.
write_v2 "$work/own.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:agy | 1 | — | `b.sh` | `true` | mid |
| S3 | top | session | 1 | — | — | — | top@claude-task |
| S4 | mid | subagent | 1 | — | `c.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" cursor
assert_rc "v2 own-backend exits 0" 0
assert_jq "v2 map kind" '.map == "v2"'
assert_jq "v2 selects only cursor row" '[.selected[].id] == ["S1"]'
assert_jq "v2 skips agy row" '.skipped[] | select(.id=="S2") | .note == "out of step-scope"'
assert_jq "v2 skips unscoped top" '.skipped[] | select(.id=="S3") | .note == "out of step-scope (top row: run in session)"'
assert_jq "v2 skips mid subagent" '.skipped[] | select(.id=="S4") | .note == "out of step-scope"'
assert_jq "v2 launch_tier execute" '.launch_tier == "execute"'
assert_jq "v2 router false" '.router == false'

# scoped foreign row
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" cursor S2
assert_rc "scoped foreign row exits 3" 3
assert_stdout_empty "scoped foreign row no stdout"
assert_stderr_has "scoped foreign row reason" "REFUSE: S2: routed to delegate:agy"

# top on delegate
write_v2 "$work/topdel.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | top | delegate:cursor | 1 | — | — | — | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/topdel.md" cursor
assert_rc "top on delegate exits 3" 3
assert_stdout_empty "top on delegate no stdout"
assert_stderr_has "top on delegate reason" "REFUSE: S1: top rows never run on a delegate"

# scoped top on session
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" cursor S3
assert_rc "scoped top exits 3" 3
assert_stdout_empty "scoped top no stdout"
assert_stderr_has "scoped top reason" "REFUSE: S3: top rows never run on a delegate"

# cursor mid
write_v2 "$work/mid.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | mid | delegate:cursor | 1 | — | `b.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/mid.md" cursor
assert_rc "cursor mid exits 0" 0
assert_jq "cursor mid selected" '[.selected[].id] == ["S1","S2"]'
assert_jq "cursor mid launch_tier" '.launch_tier == "mid"'
assert_jq "cursor mid router false" '.router == false'

# mid on agy is not refused
write_v2 "$work/midagy.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | mid | delegate:agy | 1 | — | `a.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/midagy.md" agy
assert_rc "agy mid allowed" 0
assert_jq "agy mid selected" '[.selected[].id] == ["S1"]'
assert_jq "agy mid launch_tier" '.launch_tier == "mid"'

# deps: undone (dependency is another runner and not done)
write_v2 "$work/dep-undone.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | subagent | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:cursor | 2 | S1 | `b.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/dep-undone.md" cursor
assert_rc "dep on undone exits 3" 3
assert_stdout_empty "dep on undone no stdout"
assert_stderr_has "dep on undone reason" "REFUSE: S2: depends on S1 (not done)"

# dep on a done row, and --reexecute / completed keep done rows as candidates
write_v2 "$work/dep-done.md" <<'EOF'
---
execution:
  status: in-progress
---

## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:cursor | 2 | S1 | `b.sh` | `true` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | earlier |
| S2 | pending | |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/dep-done.md" cursor
assert_rc "dep on done row exits 0" 0
assert_jq "done row omitted, dependent selected" '[.selected[].id] == ["S2"]'

run_cmd "$BASH" "$SCRIPT" rows --reexecute "$work/dep-done.md" cursor
assert_rc "reexecute keeps done candidates" 0
assert_jq "reexecute selects done and dependent" '[.selected[].id] == ["S1","S2"]'

awk '/status: in-progress/ { print "  status: completed"; next } { print }' \
  "$work/dep-done.md" >"$work/dep-completed.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/dep-completed.md" cursor
assert_rc "completed plan keeps candidates" 0
assert_jq "completed selects done rows" '[.selected[].id] == ["S1","S2"]'

# co-selected dependency
write_v2 "$work/dep-co.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:cursor | 2 | S1 | `b.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/dep-co.md" cursor
assert_rc "dep on co-selected exits 0" 0
assert_jq "co-selected both rows" '[.selected[].id] == ["S1","S2"]'

# overlap
write_v2 "$work/overlap.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/overlap.md" cursor
assert_rc "overlap exits 3" 3
assert_stdout_empty "overlap no stdout"
assert_stderr_has "overlap reason" "REFUSE: S2: files overlap with S1"

write_v2 "$work/overlap-wave.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | execute | delegate:cursor | 2 | S1 | `a.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/overlap-wave.md" cursor
assert_rc "overlap across waves allowed" 0
assert_jq "different waves both selected" '[.selected[].id] == ["S1","S2"]'

# brace expansion
write_v2 "$work/brace.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | low | delegate:cursor | 1 | — | `dir/{a,b}.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/brace.md" cursor
assert_rc "brace expansion exits 0" 0
assert_jq "brace files" '.selected[0].files == ["dir/a.sh","dir/b.sh"]'
assert_jq "brace files_union" '.files_union == ["dir/a.sh","dir/b.sh"]'

# escaped pipe in Acceptance
write_v2 "$work/pipe.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | execute | delegate:cursor | 1 | — | `f.sh` | `echo a \| b` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/pipe.md" cursor
assert_rc "escaped pipe exits 0" 0
assert_jq "escaped pipe acceptance" '.selected[0].acceptance == "echo a | b"'

# legacy map: prose above the table, Notes column, top skipped
write_v2 "$work/legacy-map.md" <<'EOF'
## Execution map
Runners are advisory until Phase 2 makes delegates read them.

| ID | Step summary | Tier | Wave | Depends on | Notes (runner · acceptance) |
| --- | --- | --- | --- | --- | --- |
| S1 | review | opus | 1 | — | session · top work |
| S2 | edit | haiku | 1 | — | delegate:cursor · `true` |
| S3 | parked | — | — | — | not a scheduled row |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/legacy-map.md" agy
assert_rc "legacy map exits 0" 0
assert_jq "legacy map kind" '.map == "legacy"'
assert_jq "legacy selects non-top" '[.selected[].id] == ["S2"]'
assert_jq "legacy tier normalized" '.selected[0].tier == "low"'
assert_jq "legacy top skipped with note" '.skipped[] | select(.id=="S1") | .note == "out of step-scope (top row: run in session)"'
assert_jq "legacy dash tier not scheduled" '.skipped[] | select(.id=="S3") | .note == "not scheduled"'
assert_jq "legacy review default" '.selected[0].review == "mid"'

# extra Phase column ignored
write_v2 "$work/phase.md" <<'EOF'
## Execution map

| ID | Phase | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | alpha | execute | delegate:cursor | 1 | — | `a.sh` | `true` | mid |
| S2 | beta | execute | delegate:agy | 1 | — | `b.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/phase.md" cursor
assert_rc "phase column exits 0" 0
assert_jq "phase column ignored" '[.selected[].id] == ["S1"]'
assert_jq "phase column still v2" '.map == "v2"'

# malformed row
write_v2 "$work/badrow.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S9 | execute | delegate:cursor |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/badrow.md" cursor
assert_rc "malformed row exits 3" 3
assert_stdout_empty "malformed row no stdout"
assert_stderr_has "malformed row reason" "REFUSE: S9: malformed row (cell count)"

# no map → I1..In
write_v2 "$work/nomap.md" <<'EOF'
## Implementation steps
1. First step does a thing
2. Second step does another

   1. nested item is not its own step
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/nomap.md" devin
assert_rc "no map exits 0" 0
assert_jq "no map kind" '.map == "none"'
assert_jq "no map ids" '[.selected[].id] == ["I1","I2"]'
assert_jq "no map tier" '.selected[0].tier == "execute"'
assert_jq "no map launch_tier" '.launch_tier == "execute"'

# unknown ID
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" cursor S99
assert_rc "unknown ID exits 3" 3
assert_stdout_empty "unknown ID no stdout"
assert_stderr_has "unknown ID reason" "REFUSE: S99: unknown ID"

# router true / false and mixed launch_tier
write_v2 "$work/router.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Model | Review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | low | delegate:cursor | 1 | — | `a.sh` | `true` | auto | mid |
| S2 | low | delegate:cursor | 1 | — | `b.sh` | `true` | auto(router) | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/router.md" cursor
assert_rc "router true exits 0" 0
assert_jq "router true" '.router == true'
assert_jq "router launch_tier low" '.launch_tier == "low"'

write_v2 "$work/mixed.md" <<'EOF'
## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Model | Review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | low | delegate:cursor | 1 | — | `a.sh` | `true` | auto | mid |
| S2 | execute | delegate:cursor | 2 | — | `b.sh` | `true` |  | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/mixed.md" cursor
assert_rc "mixed tier exits 0" 0
assert_jq "mixed launch_tier execute" '.launch_tier == "execute"'
assert_jq "mixed router false" '.router == false'

# empty selection
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" devin
assert_rc "no rows exits 3" 3
assert_stdout_empty "no rows no stdout"
assert_stderr_has "no rows reason" "REFUSE: no rows routed to delegate:devin"

# bad usage
run_cmd "$BASH" "$SCRIPT" rows "$work/own.md" nope
assert_rc "bad backend exits 2" 2

# --- writes (start / batch / terminal) ---

EM=$'\xe2\x80\x94'
AR=$'\xe2\x86\x92'

write_stamped() {
  local dest=$1 sum tmp
  cat >"$dest"
  sum=$(plan_sha_of "$dest")
  tmp=$(mktemp)
  awk -v sum="$sum" '
    /^plan_sha:/ { print "plan_sha: \"" sum "\""; next }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
}

fm_rest() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm == 1 && /^---[[:space:]]*$/ { exit }
    fm == 1 && /^execution:[[:space:]]*$/ { skip = 1; next }
    skip && /^[^[:space:]#]/ { skip = 0 }
    skip { next }
    fm == 1 { print }
  ' "$1"
}

assert_fm_same() {
  local label=$1 before=$2 after=$3 a b
  a=$(fm_rest "$before")
  b=$(fm_rest "$after")
  if [[ "$a" == "$b" ]]; then
    pass "$label"
  else
    fail "$label"
    printf '  before=[%s]\n' "$a"
    printf '  after=[%s]\n' "$b"
  fi
}

assert_lock_ok() {
  local label=$1 file=$2
  run_cmd "$BASH" "$SCRIPT" lock "$file"
  if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == ok ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_file_has() {
  local label=$1 file=$2 want=$3
  if grep -F -q -e "$want" "$file"; then
    pass "$label"
  else
    fail "$label (missing [$want])"
  fi
}

assert_file_lacks() {
  local label=$1 file=$2 want=$3
  if grep -F -q -e "$want" "$file"; then
    fail "$label (unexpected [$want])"
  else
    pass "$label"
  fi
}

assert_count() {
  local label=$1 file=$2 pattern=$3 want=$4 n
  n=$(grep -c -e "$pattern" "$file" || true)
  if [[ "$n" -eq "$want" ]]; then
    pass "$label"
  else
    fail "$label (count $n want $want)"
  fi
}

assert_headings() {
  local label=$1 file=$2 want=$3 got
  got=$(awk '/^## [^#]/ { print }' "$file")
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label"
    printf '  headings=[%s]\n' "$got"
  fi
}

extract_runs() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm == 1 && /^---[[:space:]]*$/ { exit }
    fm == 1 && /^  runs:/ { r = 1 }
    r && /^[^[:space:]]/ { exit }
    r { print }
  ' "$1"
}

MAP_TABLE=$'| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |\n| --- | --- | --- | --- | --- | --- | --- | --- |'

# scaffold: no log yet; rows-json is a file path (the rows stdout shape)
write_stamped "$work/scaffold.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "scaffold-keep"
---

# Scaffold

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:agy | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER scaffold
EOF
cp "$work/scaffold.md" "$work/scaffold.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/scaffold.md" cursor
assert_rc "scaffold rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/scaffold-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/scaffold.md" execute-via-cursor "$work/scaffold-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "start scaffold exits 0" 0
assert_stdout_empty "start scaffold no stdout"
assert_fm_same "start scaffold keeps non-execution keys" "$work/scaffold.before" "$work/scaffold.md"
assert_lock_ok "lock ok after scaffold start" "$work/scaffold.md"
assert_headings "scaffold log placed after map" "$work/scaffold.md" \
  $'## Execution map\n## Execution log\n## Files to modify/create'
assert_count "scaffold one log heading" "$work/scaffold.md" '^## Execution log$' 1
assert_file_has "scaffold selected pending" "$work/scaffold.md" "| S1 | pending | |"
assert_file_has "scaffold skipped note" "$work/scaffold.md" "| S2 | skipped | out of step-scope |"
assert_file_has "scaffold overall" "$work/scaffold.md" "- **Overall:** in-progress ${EM} 50% (1/2)"
assert_file_has "scaffold started_at set" "$work/scaffold.md" 'started_at: "2026-04-01T00:00:00Z"'
assert_file_has "scaffold status in-progress" "$work/scaffold.md" "  status: in-progress"
assert_file_lacks "scaffold has no runs yet" "$work/scaffold.md" "  runs:"
assert_file_has "scaffold files marker" "$work/scaffold.md" "FILEMARKER scaffold"
assert_file_has "scaffold custom key" "$work/scaffold.md" 'custom_key: "scaffold-keep"'

# legacy plan: frontmatter without execution:, no log section
write_stamped "$work/legacy-nolog.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
custom_key: "legacy-keep"
---

# Legacy

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER legacy
EOF
cp "$work/legacy-nolog.md" "$work/legacy-nolog.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/legacy-nolog.md" cursor
assert_rc "legacy-no-log rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/legacy-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/legacy-nolog.md" execute-via-cursor "$work/legacy-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "start legacy-no-log exits 0" 0
assert_fm_same "legacy-no-log keeps non-execution keys" "$work/legacy-nolog.before" "$work/legacy-nolog.md"
assert_lock_ok "lock ok after legacy-no-log start" "$work/legacy-nolog.md"
assert_headings "legacy-no-log creates log after map" "$work/legacy-nolog.md" \
  $'## Execution map\n## Execution log\n## Files to modify/create'
assert_file_has "legacy-no-log pending" "$work/legacy-nolog.md" "| S1 | pending | |"
assert_file_has "legacy-no-log execution block" "$work/legacy-nolog.md" "  status: in-progress"
assert_file_has "legacy-no-log custom key" "$work/legacy-nolog.md" 'custom_key: "legacy-keep"'

# log sitting at EOF is moved to just after the map; prior ### Run stays
write_stamped "$work/log-eof.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
  started_at: "2026-03-01T00:00:00Z"
custom_key: "eof-keep"
---

# Log at EOF

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | low | subagent | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER eof

## Execution log

- **Overall:** not-started ${EM} 0% (0/2)
- **Last skill:** execute-plan
- **Updated:** 2026-01-01T00:00:00Z

| ID | Status | Notes |
| --- | --- | --- |
| S1 | pending | |
| S2 | pending | |

### Run 2026-01-01T00:00:00Z (execute-plan)
- Outcome: partial
- Notes: kept-run
EOF
cp "$work/log-eof.md" "$work/log-eof.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/log-eof.md" cursor
assert_rc "log-at-EOF rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/eof-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/log-eof.md" execute-via-cursor "$work/eof-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "start log-at-EOF exits 0" 0
assert_fm_same "log-at-EOF keeps non-execution keys" "$work/log-eof.before" "$work/log-eof.md"
assert_lock_ok "lock ok after log move" "$work/log-eof.md"
assert_headings "log moved to after map" "$work/log-eof.md" \
  $'## Execution map\n## Execution log\n## Files to modify/create'
assert_count "moved log is not duplicated" "$work/log-eof.md" '^## Execution log$' 1
assert_file_has "moved log keeps prior run" "$work/log-eof.md" "- Notes: kept-run"
assert_file_lacks "moved log replaces old overall" "$work/log-eof.md" "not-started ${EM} 0% (0/2)"
assert_file_has "moved log keeps started_at" "$work/log-eof.md" 'started_at: "2026-03-01T00:00:00Z"'
assert_file_has "moved log updates updated_at" "$work/log-eof.md" 'updated_at: "2026-04-01T00:00:00Z"'
assert_file_has "moved log files marker" "$work/log-eof.md" "FILEMARKER eof"
assert_file_has "S2 skipped on move" "$work/log-eof.md" "| S2 | skipped | out of step-scope |"

# prior done kept: omitted done row, and a selected done row without --reexecute
write_stamped "$work/prior-done.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: in-progress
  started_at: "2026-03-01T00:00:00Z"
custom_key: "prior-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |
| S3 | execute | delegate:agy | 1 | - | \`c.sh\` | \`true\` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | earlier |
| S2 | pending | leftover |
| S3 | pending | |

## Files to modify/create

FILEMARKER prior
EOF
cp "$work/prior-done.md" "$work/prior-done.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/prior-done.md" cursor
assert_rc "prior-done rows exits 0" 0
assert_jq "prior-done rows omits done row" '[.selected[].id] == ["S2"]'
printf '%s\n' "$LAST_OUT" >"$work/prior-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/prior-done.md" execute-via-cursor "$work/prior-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "start keeps prior done exits 0" 0
assert_fm_same "prior-done keeps non-execution keys" "$work/prior-done.before" "$work/prior-done.md"
assert_lock_ok "lock ok after prior-done start" "$work/prior-done.md"
assert_file_has "omitted done row kept" "$work/prior-done.md" "| S1 | done | earlier |"
assert_file_has "selected pending clears notes" "$work/prior-done.md" "| S2 | pending | |"
assert_file_has "skipped note written" "$work/prior-done.md" "| S3 | skipped | out of step-scope |"
assert_file_has "prior-done keeps started_at" "$work/prior-done.md" 'started_at: "2026-03-01T00:00:00Z"'

cp "$work/prior-done.before" "$work/prior-sel.md"
run_cmd "$BASH" "$SCRIPT" start "$work/prior-sel.md" execute-via-cursor \
  '{"selected":[{"id":"S1"},{"id":"S2"}],"skipped":[{"id":"S3","note":"out of step-scope"}]}' \
  --now 2026-04-01T00:00:00Z
assert_rc "inline json start exits 0" 0
assert_lock_ok "lock ok after inline json start" "$work/prior-sel.md"
assert_file_has "selected done kept without reexecute" "$work/prior-sel.md" "| S1 | done | earlier |"
assert_file_has "other selected becomes pending" "$work/prior-sel.md" "| S2 | pending | |"

# completed refuses without --reexecute; --reexecute resets selected to pending
write_stamped "$work/completed.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: completed
  progress_pct: 100
  steps_done: 3
  steps_total: 3
  last_skill: execute-via-cursor
  started_at: "2026-03-01T00:00:00Z"
  updated_at: "2026-03-02T00:00:00Z"
  completed_at: "2026-03-02T00:00:00Z"
custom_key: "completed-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |
| S3 | execute | delegate:agy | 1 | - | \`c.sh\` | \`true\` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | |
| S2 | done | |
| S3 | done | earlier-agy |

## Files to modify/create

FILEMARKER completed
EOF
cp "$work/completed.md" "$work/completed.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/completed.md" cursor
assert_rc "completed rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/completed-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/completed.md" execute-via-cursor "$work/completed-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "completed start refuses" 4
assert_stdout_empty "completed refuse no stdout"
assert_stderr_has "completed refuse message" "plan already completed; confirm re-execute"
if cmp -s "$work/completed.md" "$work/completed.before"; then
  pass "completed refuse leaves file unchanged"
else
  fail "completed refuse leaves file unchanged"
fi
run_cmd "$BASH" "$SCRIPT" start "$work/completed.md" execute-via-cursor "$work/completed-rows.json" \
  --now 2026-04-01T04:00:00Z --reexecute
assert_rc "reexecute start exits 0" 0
assert_fm_same "reexecute keeps non-execution keys" "$work/completed.before" "$work/completed.md"
assert_lock_ok "lock ok after reexecute" "$work/completed.md"
assert_file_has "reexecute resets selected S1" "$work/completed.md" "| S1 | pending | |"
assert_file_has "reexecute resets selected S2" "$work/completed.md" "| S2 | pending | |"
assert_file_has "reexecute keeps skipped done" "$work/completed.md" "| S3 | done | earlier-agy |"
assert_file_has "reexecute status in-progress" "$work/completed.md" "  status: in-progress"
assert_file_has "reexecute clears completed_at" "$work/completed.md" "  completed_at: null"
assert_file_has "reexecute keeps started_at" "$work/completed.md" 'started_at: "2026-03-01T00:00:00Z"'
assert_file_lacks "reexecute drops completed status" "$work/completed.md" "  status: completed"

# batch math: skipped counts toward steps_done; failed does not; round half up
write_stamped "$work/batch.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "batch-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |
| S3 | execute | delegate:agy | 1 | - | \`c.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER batch
EOF
cp "$work/batch.md" "$work/batch.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/batch.md" cursor
assert_rc "batch rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/batch-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/batch.md" execute-via-cursor "$work/batch-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "batch start exits 0" 0
assert_lock_ok "lock ok after batch start" "$work/batch.md"
assert_file_has "start progress is 1/3 rounded" "$work/batch.md" "- **Overall:** in-progress ${EM} 33% (1/3)"
assert_file_has "start steps_done 1" "$work/batch.md" "  steps_done: 1"
run_cmd "$BASH" "$SCRIPT" batch "$work/batch.md" execute-via-cursor --done S1 --failed S2 --now 2026-04-01T01:00:00Z
assert_rc "batch exits 0" 0
assert_stdout_empty "batch no stdout"
assert_fm_same "batch keeps non-execution keys" "$work/batch.before" "$work/batch.md"
assert_lock_ok "lock ok after batch" "$work/batch.md"
assert_file_has "batch marks done" "$work/batch.md" "| S1 | done | |"
assert_file_has "batch marks failed" "$work/batch.md" "| S2 | failed | |"
assert_file_has "batch keeps skip" "$work/batch.md" "| S3 | skipped | out of step-scope |"
assert_file_has "batch progress 2/3 rounds to 67" "$work/batch.md" "- **Overall:** in-progress ${EM} 67% (2/3)"
assert_file_has "batch steps_done" "$work/batch.md" "  steps_done: 2"
assert_file_has "batch steps_total" "$work/batch.md" "  steps_total: 3"
assert_file_has "batch progress_pct" "$work/batch.md" "  progress_pct: 67"
assert_file_has "batch updated_at" "$work/batch.md" 'updated_at: "2026-04-01T01:00:00Z"'
assert_file_has "batch keeps started_at" "$work/batch.md" 'started_at: "2026-04-01T00:00:00Z"'
assert_file_has "batch keeps in-progress" "$work/batch.md" "  status: in-progress"
assert_file_lacks "batch adds no runs" "$work/batch.md" "  runs:"

term_base() {
  local dest=$1
  write_stamped "$dest" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "term-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER term
EOF
}

# terminal pass, every row done → completed
term_base "$work/pass-all.md"
cp "$work/pass-all.md" "$work/pass-all.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/pass-all.md" cursor
assert_rc "pass-all rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/pass-all-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/pass-all.md" execute-via-cursor "$work/pass-all-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "pass-all start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/pass-all.md" execute-via-cursor "$work/pass-all-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --notes "wave ok" --now 2026-04-01T02:00:00Z
assert_rc "terminal pass all-done exits 0" 0
assert_stdout_empty "terminal pass no stdout"
assert_fm_same "terminal pass keeps non-execution keys" "$work/pass-all.before" "$work/pass-all.md"
assert_lock_ok "lock ok after terminal pass" "$work/pass-all.md"
assert_file_has "pass all-done status" "$work/pass-all.md" "  status: completed"
assert_file_has "pass all-done completed_at" "$work/pass-all.md" 'completed_at: "2026-04-01T02:00:00Z"'
assert_file_has "pass all-done pct" "$work/pass-all.md" "- **Overall:** completed ${EM} 100% (2/2)"
assert_file_has "pass all-done S1" "$work/pass-all.md" "| S1 | done | |"
assert_file_has "pass all-done S2" "$work/pass-all.md" "| S2 | done | |"
assert_file_has "pass run heading" "$work/pass-all.md" "### Run 2026-04-01T02:00:00Z (execute-via-cursor)"
assert_file_has "pass run outcome" "$work/pass-all.md" "- Outcome: completed"
assert_file_has "pass run line" "$work/pass-all.md" \
  "- Run: backend=cursor model=grok-4.7-high${AR}Grok 4.7 256K High effort=high findings=0 fix_loops=0 fallback=none tokens_in=null tokens_cached=null tokens_out=null (2026-04-01T00:00:00Z${AR}2026-04-01T02:00:00Z)"
assert_file_has "pass run notes" "$work/pass-all.md" "- Notes: wave ok"
assert_file_has "pass runs skill indent" "$work/pass-all.md" "    - skill: execute-via-cursor"
assert_file_has "pass runs backend indent" "$work/pass-all.md" "      backend: cursor"
assert_file_has "pass runs model quoted" "$work/pass-all.md" '      model_resolved: "Grok 4.7 256K High"'
assert_file_has "pass runs requested quoted" "$work/pass-all.md" '      model_requested: "grok-4.7-high"'
assert_file_has "pass runs effort quoted" "$work/pass-all.md" '      effort: "high"'
assert_file_has "pass runs fallback null" "$work/pass-all.md" "      fallback: null"
assert_file_has "pass runs outcome" "$work/pass-all.md" "      outcome: completed"
assert_file_has "pass runs findings" "$work/pass-all.md" "      review_findings: 0"
assert_file_has "pass runs tokens_in null" "$work/pass-all.md" "      tokens_in: null"
assert_file_has "pass runs tokens_cached null" "$work/pass-all.md" "      tokens_cached: null"
assert_file_has "pass runs tokens_out null" "$work/pass-all.md" "      tokens_out: null"
assert_count "pass one runs entry" "$work/pass-all.md" '^    - skill:' 1

# terminal --usage writes token fields into the runs entry and Run line
term_base "$work/usage.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/usage.md" cursor
assert_rc "usage rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/usage-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/usage.md" execute-via-cursor "$work/usage-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "usage start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/usage.md" execute-via-cursor "$work/usage-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --usage '{"tokens_in":1200,"tokens_cached":3400,"tokens_out":256}' \
  --now 2026-04-01T02:00:00Z
assert_rc "terminal --usage exits 0" 0
assert_file_has "usage tokens_in" "$work/usage.md" "      tokens_in: 1200"
assert_file_has "usage tokens_cached" "$work/usage.md" "      tokens_cached: 3400"
assert_file_has "usage tokens_out" "$work/usage.md" "      tokens_out: 256"
assert_file_has "usage run line tokens" "$work/usage.md" \
  "tokens_in=1200 tokens_cached=3400 tokens_out=256 (2026-04-01T00:00:00Z${AR}2026-04-01T02:00:00Z)"

# partial nulls are allowed; bad shapes are usage errors
term_base "$work/usage-null.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/usage-null.md" cursor
assert_rc "usage-null rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/usage-null-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/usage-null.md" execute-via-cursor "$work/usage-null-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "usage-null start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/usage-null.md" execute-via-cursor "$work/usage-null-rows.json" \
  --outcome pass --backend agy --model-requested gemini-4-argon-medium \
  --model-resolved "gemini-4-argon-medium" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --usage '{"tokens_in":null,"tokens_cached":10,"tokens_out":null}' \
  --now 2026-04-01T02:00:00Z
assert_rc "terminal --usage partial null exits 0" 0
assert_file_has "usage-null tokens_in" "$work/usage-null.md" "      tokens_in: null"
assert_file_has "usage-null tokens_cached" "$work/usage-null.md" "      tokens_cached: 10"
assert_file_has "usage-null tokens_out" "$work/usage-null.md" "      tokens_out: null"

for bad in 'not json' '{"tokens_in":-1,"tokens_cached":null,"tokens_out":null}' \
  '{"tokens_in":"5","tokens_cached":null,"tokens_out":null}' \
  '{"tokens_in":1,"tokens_out":null}' ; do
  run_cmd "$BASH" "$SCRIPT" terminal "$work/usage.md" execute-via-cursor "$work/usage-rows.json" \
    --outcome pass --backend cursor --model-requested grok-4.7-high \
    --model-resolved "Grok 4.7 256K High" --effort high \
    --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
    --usage "$bad" --now 2026-04-01T03:00:00Z
  assert_rc "terminal --usage bad json rc 2 ($bad)" 2
done

# acceptable skip (not scheduled) still completes; out-of-step-scope does not
write_stamped "$work/pass-skip.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "skip-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER skip
EOF
printf '%s\n' '{"selected":[{"id":"S1"}],"skipped":[{"id":"S2","note":"not scheduled"}]}' >"$work/pass-skip-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/pass-skip.md" execute-via-cursor "$work/pass-skip-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "not-scheduled start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/pass-skip.md" execute-via-cursor "$work/pass-skip-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T02:00:00Z
assert_rc "not-scheduled pass exits 0" 0
assert_lock_ok "lock ok after not-scheduled pass" "$work/pass-skip.md"
assert_file_has "not-scheduled is completed" "$work/pass-skip.md" "  status: completed"
assert_file_has "not-scheduled row kept" "$work/pass-skip.md" "| S2 | skipped | not scheduled |"

# scoped pass: out of step-scope skip → partial
write_stamped "$work/scoped.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "scoped-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:agy | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER scoped
EOF
cp "$work/scoped.md" "$work/scoped.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/scoped.md" cursor
assert_rc "scoped rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/scoped-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/scoped.md" execute-via-cursor "$work/scoped-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "scoped start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/scoped.md" execute-via-cursor "$work/scoped-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T02:00:00Z
assert_rc "terminal scoped pass exits 0" 0
assert_fm_same "scoped keeps non-execution keys" "$work/scoped.before" "$work/scoped.md"
assert_lock_ok "lock ok after scoped pass" "$work/scoped.md"
assert_file_has "scoped status partial" "$work/scoped.md" "  status: partial"
assert_file_has "scoped completed_at null" "$work/scoped.md" "  completed_at: null"
assert_file_has "scoped overall partial" "$work/scoped.md" "- **Overall:** partial ${EM} 100% (2/2)"
assert_file_has "scoped selected done" "$work/scoped.md" "| S1 | done | |"
assert_file_has "scoped skip remains" "$work/scoped.md" "| S2 | skipped | out of step-scope |"
assert_file_has "scoped run outcome" "$work/scoped.md" "- Outcome: partial"
assert_file_has "scoped runs outcome" "$work/scoped.md" "      outcome: partial"

# fail marks non-done selected rows failed and keeps an already-done selected row
write_stamped "$work/fail.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: in-progress
  started_at: "2026-03-01T00:00:00Z"
custom_key: "fail-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | earlier |
| S2 | pending | |

## Files to modify/create

FILEMARKER fail
EOF
cp "$work/fail.md" "$work/fail.before"
printf '%s\n' '{"selected":[{"id":"S1"},{"id":"S2"}],"skipped":[]}' >"$work/fail-rows.json"
run_cmd "$BASH" "$SCRIPT" terminal "$work/fail.md" execute-via-cursor "$work/fail-rows.json" \
  --outcome fail --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 2 --fix-loops 1 --fallback quota \
  --notes "broke" --now 2026-04-01T02:00:00Z
assert_rc "terminal fail exits 0" 0
assert_fm_same "fail keeps non-execution keys" "$work/fail.before" "$work/fail.md"
assert_lock_ok "lock ok after fail" "$work/fail.md"
assert_file_has "fail status" "$work/fail.md" "  status: failed"
assert_file_has "fail keeps done row" "$work/fail.md" "| S1 | done | earlier |"
assert_file_has "fail marks pending failed" "$work/fail.md" "| S2 | failed | |"
assert_file_has "fail completed_at null" "$work/fail.md" "  completed_at: null"
assert_file_has "fail run outcome" "$work/fail.md" "- Outcome: failed"
assert_file_has "fail fallback text" "$work/fail.md" "      fallback: \"quota\""
assert_file_has "fail run line fallback" "$work/fail.md" "fallback=quota"
assert_file_has "fail findings" "$work/fail.md" "      review_findings: 2"
assert_file_has "fail fix loops" "$work/fail.md" "      fix_loops: 1"

# abort with nothing done → aborted
write_stamped "$work/abort.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "abort-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER abort
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/abort.md" cursor
assert_rc "abort rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/abort-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/abort.md" execute-via-cursor "$work/abort-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "abort start exits 0" 0
run_cmd "$BASH" "$SCRIPT" terminal "$work/abort.md" execute-via-cursor "$work/abort-rows.json" \
  --outcome abort --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T02:00:00Z
assert_rc "abort nothing done exits 0" 0
assert_lock_ok "lock ok after abort" "$work/abort.md"
assert_file_has "abort status aborted" "$work/abort.md" "  status: aborted"
assert_file_has "abort outcome" "$work/abort.md" "- Outcome: aborted"
assert_file_has "abort rows still pending" "$work/abort.md" "| S1 | pending | |"
assert_file_has "abort completed_at null" "$work/abort.md" "  completed_at: null"

# abort after batch --done → partial; a second terminal appends and keeps the first runs entry
write_stamped "$work/abort-partial.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "abort2-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |
| S3 | execute | delegate:agy | 1 | - | \`c.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER abort2
EOF
cp "$work/abort-partial.md" "$work/abort-partial.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/abort-partial.md" cursor
assert_rc "abort-partial rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/abort-partial-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/abort-partial.md" execute-via-cursor "$work/abort-partial-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "abort-partial start exits 0" 0
assert_lock_ok "lock ok after abort-partial start" "$work/abort-partial.md"
run_cmd "$BASH" "$SCRIPT" batch "$work/abort-partial.md" execute-via-cursor --done S1 --now 2026-04-01T01:00:00Z
assert_rc "abort-partial batch exits 0" 0
assert_lock_ok "lock ok after abort-partial batch" "$work/abort-partial.md"
run_cmd "$BASH" "$SCRIPT" terminal "$work/abort-partial.md" execute-via-cursor "$work/abort-partial-rows.json" \
  --outcome abort --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --notes "first-run" --now 2026-04-01T02:00:00Z
assert_rc "abort after done exits 0" 0
assert_fm_same "abort-partial keeps non-execution keys" "$work/abort-partial.before" "$work/abort-partial.md"
assert_lock_ok "lock ok after abort-partial" "$work/abort-partial.md"
assert_file_has "abort after done is partial" "$work/abort-partial.md" "  status: partial"
assert_file_has "abort after done keeps S1" "$work/abort-partial.md" "| S1 | done | |"
assert_file_has "abort after done leaves S2 pending" "$work/abort-partial.md" "| S2 | pending | |"
assert_file_has "abort after done outcome" "$work/abort-partial.md" "- Outcome: partial"
assert_file_has "first run notes" "$work/abort-partial.md" "- Notes: first-run"
first_runs=$(extract_runs "$work/abort-partial.md")
run_cmd "$BASH" "$SCRIPT" terminal "$work/abort-partial.md" execute-via-cursor "$work/abort-partial-rows.json" \
  --outcome fail --backend cursor --model-requested grok-4.7-high \
  --model-resolved "auto(router)" --effort unknown \
  --started 2026-04-01T02:00:00Z --findings 1 --fix-loops 0 --fallback null \
  --notes "second-run" --now 2026-04-01T03:00:00Z
assert_rc "second terminal exits 0" 0
assert_lock_ok "lock ok after second terminal" "$work/abort-partial.md"
assert_fm_same "second terminal keeps non-execution keys" "$work/abort-partial.before" "$work/abort-partial.md"
second_runs=$(extract_runs "$work/abort-partial.md")
case "$second_runs" in
  "$first_runs"*) pass "second terminal keeps the first runs entry" ;;
  *) fail "second terminal keeps the first runs entry" ;;
esac
assert_count "two runs entries" "$work/abort-partial.md" '^    - skill:' 2
assert_count "two run stanzas" "$work/abort-partial.md" '^### Run ' 2
assert_file_has "first run notes survive" "$work/abort-partial.md" "- Notes: first-run"
assert_file_has "second run notes appended" "$work/abort-partial.md" "- Notes: second-run"
assert_file_has "router model kept" "$work/abort-partial.md" '      model_resolved: "auto(router)"'
assert_file_has "first model kept" "$work/abort-partial.md" '      model_resolved: "Grok 4.7 256K High"'
assert_file_has "second terminal failed the open row" "$work/abort-partial.md" "| S2 | failed | |"
assert_file_has "second terminal status failed" "$work/abort-partial.md" "  status: failed"

# malicious model_resolved is re-validated to auto(unresolved)
write_stamped "$work/evil.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "evil-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER evil
EOF
printf '%s\n' '{"selected":[{"id":"S1"}],"skipped":[]}' >"$work/evil-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/evil.md" execute-via-cursor "$work/evil-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "evil start exits 0" 0
evil=$'evil\n  status: pwned'
run_cmd "$BASH" "$SCRIPT" terminal "$work/evil.md" execute-via-cursor "$work/evil-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "$evil" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T02:00:00Z
assert_rc "malicious newline model exits 0" 0
assert_lock_ok "lock ok after malicious model" "$work/evil.md"
assert_file_has "newline model becomes unresolved" "$work/evil.md" '      model_resolved: "auto(unresolved)"'
assert_file_lacks "newline model is not written" "$work/evil.md" "status: pwned"
assert_file_has "run line uses unresolved" "$work/evil.md" "model=grok-4.7-high${AR}auto(unresolved)"
run_cmd "$BASH" "$SCRIPT" terminal "$work/evil.md" execute-via-cursor "$work/evil-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved 'bad"model' --effort high \
  --started 2026-04-01T02:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T03:00:00Z
assert_rc "malicious quoted model exits 0" 0
assert_lock_ok "lock ok after quoted malicious model" "$work/evil.md"
assert_file_lacks "quoted malicious model is not written" "$work/evil.md" 'bad"model'
assert_file_lacks "quoted malicious model is not escaped in" "$work/evil.md" 'bad\"model'
assert_count "both malicious runs are unresolved" "$work/evil.md" 'model_resolved: "auto(unresolved)"' 2

evil_fb=$'quota-exceeded\ninjected_key: evil'
evil_notes=$'note line one\n## Injected Heading\nnote line two'
run_cmd "$BASH" "$SCRIPT" terminal "$work/evil.md" execute-via-cursor "$work/evil-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "auto(router)" --effort high \
  --started 2026-04-01T03:00:00Z --findings 0 --fix-loops 0 --fallback "$evil_fb" \
  --notes "$evil_notes" \
  --now 2026-04-01T04:00:00Z
assert_rc "multiline fallback and notes exits 0" 0
assert_lock_ok "lock ok after multiline fallback and notes" "$work/evil.md"
assert_file_has "multiline fallback flattened in frontmatter" "$work/evil.md" '      fallback: "quota-exceeded injected_key: evil"'
assert_file_has "multiline fallback flattened in markdown run" "$work/evil.md" 'fallback=quota-exceeded injected_key: evil'
assert_file_has "multiline notes flattened in markdown run" "$work/evil.md" '- Notes: note line one ## Injected Heading note line two'
assert_count "injected heading not an H2" "$work/evil.md" '^## Injected Heading' 0
assert_count "only three H2 headings in evil plan" "$work/evil.md" '^## ' 3

# subsequent write still succeeds and keeps lock ok
run_cmd "$BASH" "$SCRIPT" terminal "$work/evil.md" execute-via-cursor "$work/evil-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "auto(router)" --effort high \
  --started 2026-04-01T04:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --notes "clean subsequent note" \
  --now 2026-04-01T05:00:00Z
assert_rc "subsequent write exits 0" 0
assert_lock_ok "lock ok after subsequent write" "$work/evil.md"
assert_file_has "subsequent write note present" "$work/evil.md" "- Notes: clean subsequent note"

# no Execution map: log goes after Implementation steps
write_stamped "$work/nomap-write.md" <<'EOF'
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "nomap-keep"
---

## Implementation steps
1. First step does a thing
2. Second step does another

## Files to modify/create

FILEMARKER nomap
EOF
cp "$work/nomap-write.md" "$work/nomap-write.before"
run_cmd "$BASH" "$SCRIPT" rows "$work/nomap-write.md" devin
assert_rc "nomap write rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/nomap-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/nomap-write.md" execute-via-devin "$work/nomap-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "nomap start exits 0" 0
assert_fm_same "nomap keeps non-execution keys" "$work/nomap-write.before" "$work/nomap-write.md"
assert_lock_ok "lock ok after nomap start" "$work/nomap-write.md"
assert_headings "nomap log after implementation steps" "$work/nomap-write.md" \
  $'## Implementation steps\n## Execution log\n## Files to modify/create'
assert_file_has "nomap I1 pending" "$work/nomap-write.md" "| I1 | pending | |"
assert_file_has "nomap I2 pending" "$work/nomap-write.md" "| I2 | pending | |"

# Permission bits survive the temp+mv write (mktemp is 0600).
file_mode() {
  local mode
  if ! mode=$(stat -c %a "$1" 2>/dev/null); then
    mode=$(stat -f %OLp "$1" 2>/dev/null) || mode=""
  fi
  mode=${mode#0}
  printf '%s' "$mode"
}

assert_mode() {
  local label=$1 file=$2 want=$3 got
  got=$(file_mode "$file")
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (mode $got want $want)"
  fi
}

write_stamped "$work/mode.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
custom_key: "mode-keep"
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | execute | delegate:agy | 1 | - | \`b.sh\` | \`true\` | mid |

## Files to modify/create

FILEMARKER mode
EOF
chmod 644 "$work/mode.md"
assert_mode "mode fixture is 0644" "$work/mode.md" "644"
run_cmd "$BASH" "$SCRIPT" rows "$work/mode.md" cursor
assert_rc "mode rows exits 0" 0
printf '%s\n' "$LAST_OUT" >"$work/mode-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/mode.md" execute-via-cursor "$work/mode-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "mode start exits 0" 0
assert_stdout_empty "mode start no stdout"
assert_mode "start keeps 0644" "$work/mode.md" "644"
run_cmd "$BASH" "$SCRIPT" batch "$work/mode.md" execute-via-cursor --done S1 --now 2026-04-01T01:00:00Z
assert_rc "mode batch exits 0" 0
assert_stdout_empty "mode batch no stdout"
assert_mode "batch keeps 0644" "$work/mode.md" "644"
run_cmd "$BASH" "$SCRIPT" terminal "$work/mode.md" execute-via-cursor "$work/mode-rows.json" \
  --outcome pass --backend cursor --model-requested grok-4.7-high \
  --model-resolved "Grok 4.7 256K High" --effort high \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 --fallback null \
  --now 2026-04-01T02:00:00Z
assert_rc "mode terminal exits 0" 0
assert_stdout_empty "mode terminal no stdout"
assert_mode "terminal keeps 0644" "$work/mode.md" "644"
assert_lock_ok "lock ok after mode writes" "$work/mode.md"

# --- review ---

review_runs() {
  cat <<'EOF'
  runs:
    - skill: execute-via-cursor
      backend: cursor
      model_requested: "grok-4.7-high"
      model_resolved: "Grok 4.7 256K High"
      effort: "high"
      started_at: "2026-04-01T00:00:00Z"
      ended_at: "2026-04-01T02:00:00Z"
      review_findings: 0
      fix_loops: 0
      fallback: null
      outcome: partial
EOF
}

write_review_plan() {
  local dest=$1 s1=$2 s2=$3 s2note=$4 s2cell
  if [[ -n "$s2note" ]]; then
    s2cell="| S2 | ${s2} | ${s2note} |"
  else
    s2cell="| S2 | ${s2} | |"
  fi
  write_stamped "$dest" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: partial
  progress_pct: 50
  steps_done: 1
  steps_total: 2
  last_skill: execute-via-cursor
  started_at: "2026-04-01T00:00:00Z"
  updated_at: "2026-04-01T02:00:00Z"
  completed_at: null
$(review_runs)
custom_key: "review-keep"
---

# Review

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | top | session | 2 | - | ${EM} | - | top@session |

## Execution log

- **Overall:** partial ${EM} 50% (1/2)
- **Last skill:** execute-via-cursor
- **Updated:** 2026-04-01T02:00:00Z

| ID | Status | Notes |
| --- | --- | --- |
| S1 | ${s1} | |
${s2cell}

### Run 2026-04-01T02:00:00Z (execute-via-cursor)
- Outcome: partial
- Run: backend=cursor model=grok-4.7-high${AR}Grok 4.7 256K High effort=high findings=0 fix_loops=0 fallback=none (2026-04-01T00:00:00Z${AR}2026-04-01T02:00:00Z)
- Notes: prior

## Files to modify/create

FILEMARKER review
EOF
}

review_now=2026-05-02T03:04:05Z

write_review_plan "$work/review-pass-id.md" done pending ""
cp "$work/review-pass-id.md" "$work/review-pass-id.before"
runs_before=$(extract_runs "$work/review-pass-id.md")
run_cmd "$BASH" "$SCRIPT" review "$work/review-pass-id.md" S2 \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review pass with ID exits 0" 0
assert_stdout_empty "review pass with ID no stdout"
assert_fm_same "review pass with ID keeps non-execution keys" \
  "$work/review-pass-id.before" "$work/review-pass-id.md"
assert_lock_ok "lock ok after review pass with ID" "$work/review-pass-id.md"
assert_file_has "review pass with ID completed" "$work/review-pass-id.md" "  status: completed"
assert_file_has "review pass with ID last_skill" "$work/review-pass-id.md" "  last_skill: review"
assert_file_has "review pass with ID completed_at" "$work/review-pass-id.md" \
  "completed_at: \"$review_now\""
assert_file_has "review pass with ID keeps started_at" "$work/review-pass-id.md" \
  'started_at: "2026-04-01T00:00:00Z"'
assert_file_has "review pass with ID overall" "$work/review-pass-id.md" \
  "- **Overall:** completed ${EM} 100% (2/2)"
assert_file_has "review pass with ID last skill line" "$work/review-pass-id.md" "- **Last skill:** review"
assert_file_has "review pass with ID S1 unchanged" "$work/review-pass-id.md" "| S1 | done | |"
assert_file_has "review pass with ID S2 done" "$work/review-pass-id.md" \
  "| S2 | done | review=top@session clean |"
assert_file_has "review pass with ID stanza" "$work/review-pass-id.md" \
  "### Run ${review_now} (review)"
assert_file_has "review pass with ID outcome" "$work/review-pass-id.md" "- Outcome: completed"
assert_file_has "review pass with ID run line" "$work/review-pass-id.md" \
  "- Run: runner=top@session findings=0"
assert_file_has "review pass with ID notes" "$work/review-pass-id.md" "- Notes: review=top@session clean"
assert_file_has "review pass with ID keeps prior stanza" "$work/review-pass-id.md" \
  "### Run 2026-04-01T02:00:00Z (execute-via-cursor)"
assert_count "review pass with ID runs count unchanged" "$work/review-pass-id.md" '^    - skill:' 1
assert_file_lacks "review pass with ID adds no review run" "$work/review-pass-id.md" "    - skill: review"
runs_after=$(extract_runs "$work/review-pass-id.md")
if [[ "$runs_before" == "$runs_after" ]]; then
  pass "review pass with ID runs block unchanged"
else
  fail "review pass with ID runs block unchanged"
fi
assert_file_has "review pass with ID marker" "$work/review-pass-id.md" "FILEMARKER review"

write_review_plan "$work/review-pass-noid.md" done done "keep-me"
cp "$work/review-pass-noid.md" "$work/review-pass-noid.before"
run_cmd "$BASH" "$SCRIPT" review "$work/review-pass-noid.md" \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review pass without ID exits 0" 0
assert_lock_ok "lock ok after review pass without ID" "$work/review-pass-noid.md"
assert_file_has "review pass without ID completed" "$work/review-pass-noid.md" "  status: completed"
assert_file_has "review pass without ID S1 unchanged" "$work/review-pass-noid.md" "| S1 | done | |"
assert_file_has "review pass without ID S2 note kept" "$work/review-pass-noid.md" "| S2 | done | keep-me |"
assert_file_has "review pass without ID stanza" "$work/review-pass-noid.md" "### Run ${review_now} (review)"
assert_file_has "review pass without ID notes" "$work/review-pass-noid.md" "- Notes: review=top@session clean"
assert_count "review pass without ID runs count unchanged" "$work/review-pass-noid.md" '^    - skill:' 1
assert_fm_same "review pass without ID keeps non-execution keys" \
  "$work/review-pass-noid.before" "$work/review-pass-noid.md"

write_review_plan "$work/review-partial.md" pending pending ""
run_cmd "$BASH" "$SCRIPT" review "$work/review-partial.md" S2 \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review pass undone exits 0" 0
assert_lock_ok "lock ok after review pass undone" "$work/review-partial.md"
assert_file_has "review pass undone partial" "$work/review-partial.md" "  status: partial"
assert_file_has "review pass undone completed_at null" "$work/review-partial.md" "  completed_at: null"
assert_file_has "review pass undone S1 pending" "$work/review-partial.md" "| S1 | pending | |"
assert_file_has "review pass undone S2 done" "$work/review-partial.md" \
  "| S2 | done | review=top@session clean |"
assert_file_has "review pass undone outcome" "$work/review-partial.md" "- Outcome: partial"
assert_file_has "review pass undone overall" "$work/review-partial.md" \
  "- **Overall:** partial ${EM} 50% (1/2)"

write_review_plan "$work/review-fail.md" done pending ""
run_cmd "$BASH" "$SCRIPT" review "$work/review-fail.md" S2 \
  --outcome fail --runner top@session --findings 2 --now "$review_now"
assert_rc "review fail exits 0" 0
assert_lock_ok "lock ok after review fail" "$work/review-fail.md"
assert_file_has "review fail partial" "$work/review-fail.md" "  status: partial"
assert_file_has "review fail row" "$work/review-fail.md" \
  "| S2 | failed | review=top@session findings=2 |"
assert_file_has "review fail outcome" "$work/review-fail.md" "- Outcome: partial"
assert_file_has "review fail run line" "$work/review-fail.md" "- Run: runner=top@session findings=2"
assert_file_has "review fail notes" "$work/review-fail.md" "- Notes: review=top@session findings=2"
assert_count "review fail runs count unchanged" "$work/review-fail.md" '^    - skill:' 1

write_review_plan "$work/review-notes.md" done pending ""
run_cmd "$BASH" "$SCRIPT" review "$work/review-notes.md" S2 \
  --outcome pass --runner top@claude-task --findings 0 --notes "looks fine" --now "$review_now"
assert_rc "review custom notes exits 0" 0
assert_file_has "review custom notes row uses runner" "$work/review-notes.md" \
  "| S2 | done | review=top@claude-task clean |"
assert_file_has "review custom notes stanza" "$work/review-notes.md" "- Notes: looks fine"
assert_file_has "review custom notes run line" "$work/review-notes.md" \
  "- Run: runner=top@claude-task findings=0"

write_stamped "$work/review-refuse.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: partial
  progress_pct: 0
  steps_done: 0
  steps_total: 4
  last_skill: execute-via-cursor
  started_at: "2026-04-01T00:00:00Z"
  updated_at: "2026-04-01T02:00:00Z"
  completed_at: null
$(review_runs)
custom_key: "refuse-keep"
---

# Refuse

## Execution map

$MAP_TABLE
| Sexec | execute | session | 1 | - | ${EM} | - | top@session |
| Sdel | top | delegate:cursor | 1 | - | ${EM} | - | top@devin-fusion |
| Sfiles | top | session | 1 | - | \`a.sh\` | - | top@cursor-ask |
| Smid | top | session | 1 | - | ${EM} | - | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| Sexec | pending | |
| Sdel | pending | |
| Sfiles | pending | |
| Smid | pending | |

## Files to modify/create

FILEMARKER refuse
EOF
cp "$work/review-refuse.md" "$work/review-refuse.before"
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" Sexec \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review non-top exits 3" 3
assert_stdout_empty "review non-top no stdout"
assert_stderr_has "review non-top reason" "REFUSE: Sexec: Tier is not top"
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" Sdel \
  --outcome pass --runner top@devin-fusion --findings 0 --now "$review_now"
assert_rc "review delegate exits 3" 3
assert_stderr_has "review delegate reason" "REFUSE: Sdel: Runner is not session"
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" Sfiles \
  --outcome pass --runner top@cursor-ask --findings 0 --now "$review_now"
assert_rc "review files row exits 3" 3
assert_stderr_has "review files row reason" "REFUSE: Sfiles: Files is not"
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" Smid \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review non-top@ exits 3" 3
assert_stderr_has "review non-top@ reason" "REFUSE: Smid: Review is not top@*"
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" S99 \
  --outcome pass --runner top@session --findings 0 --now "$review_now"
assert_rc "review unknown ID exits 3" 3
assert_stderr_has "review unknown ID reason" "REFUSE: S99: unknown ID"
if cmp -s "$work/review-refuse.before" "$work/review-refuse.md"; then
  pass "review refusals leave the plan unchanged"
else
  fail "review refusals leave the plan unchanged"
fi

run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md"
assert_rc "review missing flags exits 2" 2
run_cmd "$BASH" "$SCRIPT" review "$work/review-refuse.md" Sexec \
  --outcome pass --runner mid --findings 0 --now "$review_now"
assert_rc "review bad runner exits 2" 2
if cmp -s "$work/review-refuse.before" "$work/review-refuse.md"; then
  pass "review usage errors leave the plan unchanged"
else
  fail "review usage errors leave the plan unchanged"
fi

# --- S2 extensions: layout lock, claude-code rows, lint, batch, terminal, stamp, recent, approve ---

layout="$work/skills/execute-plan"
mkdir -p "$layout/scripts"
cp "$SCRIPT" "$layout/scripts/plan-status.sh"
cp "$SOT" "$layout/execution-status.md"
run_cmd "$BASH" "$layout/scripts/plan-status.sh" lock "$work/lock-ok.md"
assert_rc "lock from skills/execute-plan/scripts layout exits 0" 0
assert_stdout "lock from skills layout prints ok" "ok"

mkdir -p "$layout/references"
printf 'no snippet here\n' >"$layout/execution-status.md"
cp "$SOT" "$layout/references/execution-status.md"
run_cmd "$BASH" "$layout/scripts/plan-status.sh" lock "$work/lock-ok.md"
assert_rc "lock prefers references/execution-status.md exits 0" 0
assert_stdout "lock prefers references prints ok" "ok"

printf 'no snippet here\n' >"$layout/references/execution-status.md"
cp "$SOT" "$layout/execution-status.md"
run_cmd "$BASH" "$layout/scripts/plan-status.sh" lock "$work/lock-ok.md"
assert_rc "existing references file wins over parent exits 2" 2

cat >"$work/cc.md" <<'EOF'
---
execution:
  status: not-started
---

## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | top | session | 1 | - | — | — | top@session |
| S2 | mid | subagent | 1 | - | `a.sh` | `true` | mid |
| S3 | mid | delegate:cursor | 1 | - | `b.sh` | `true` | mid |
| S4 | mid | subagent | 2 | S3 | `c.sh` | `true` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | pending | |
| S2 | pending | |
| S3 | pending | |
| S4 | pending | |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/cc.md" claude-code
assert_rc "claude-code rows exits 0" 0
assert_jq "claude-code selects session and subagent including top" '[.selected[].id] == ["S1","S2","S4"]'
assert_jq "claude-code skips delegate rows" '.skipped[] | select(.id=="S3") | .note == "out of step-scope (dispatch via delegate)"'
assert_jq "unfinished delegate dependency is blocked, not refused" '.blocked == [{"id":"S4","on":"S3"}]'

run_cmd "$BASH" "$SCRIPT" rows "$work/cc.md" claude-code S3
assert_rc "only a delegate id still exits 0" 0
assert_jq "only skips leave selected empty" '.selected == []'
assert_jq "named delegate id is a skip" '.skipped[] | select(.id=="S3") | .note == "out of step-scope (dispatch via delegate)"'

run_cmd "$BASH" "$SCRIPT" rows "$work/cc.md" claude-code S2
assert_rc "claude-code step-scope S2 exits 0" 0
assert_jq "unnamed delegate row outside step-scope keeps the plain note" '.skipped[] | select(.id=="S3") | .note == "out of step-scope"'
assert_jq "step-scope S2 selects only S2" '[.selected[].id] == ["S2"]'

run_cmd "$BASH" "$SCRIPT" rows "$work/cc.md" claude-code S2 S3
assert_jq "named delegate row keeps the dispatch note" '.skipped[] | select(.id=="S3") | .note == "out of step-scope (dispatch via delegate)"'

run_cmd "$BASH" "$SCRIPT" rows "$work/cc.md" claude-code S99
assert_rc "claude-code unknown id exits 3" 3
assert_stderr_has "claude-code unknown id" "REFUSE: S99: unknown ID"

cat >"$work/cc-bad.md" <<'EOF'
---
execution:
  status: not-started
---

## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Model | Review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | mid | session | 1 | - | `a.sh` | `true` | nope | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows "$work/cc-bad.md" claude-code
assert_rc "claude-code still refuses an invalid model" 3
assert_stderr_has "claude-code invalid model" "REFUSE: S1: invalid Model"

cat >"$work/lint-ok.md" <<'EOF'
---
execution:
  status: not-started
---

## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | top | session | 1 | - | — | — | top@session |
| S2 | mid | delegate:cursor | 1 | S9 | `a.sh` | `true` | mid |
| S3 | mid | subagent | 2 | - | `b.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows --lint "$work/lint-ok.md"
assert_rc "lint ignores dependencies and empty-runner mix" 0
assert_stdout "lint ok prints ok" "ok"

cat >"$work/lint-bad.md" <<'EOF'
---
execution:
  status: not-started
---

## Execution map

| ID | Tier | Runner | Wave | Depends on | Files | Acceptance | Review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | top | session | 1 | - | — | — | top@session |
| S2 | mid | subagent | 1 | - | `a.sh` | — | mid |
| S3 | mid | delegate:cursor | 1 | - | `a.sh` | `true` | mid |
EOF
run_cmd "$BASH" "$SCRIPT" rows --lint "$work/lint-bad.md"
assert_rc "lint refuses missing acceptance and overlap" 3
assert_stderr_has "lint missing acceptance" "REFUSE: S2: missing Acceptance"
assert_stderr_has "lint file overlap" "REFUSE: S3: files overlap with S2"

cat >"$work/lint-empty.md" <<'EOF'
# no map
EOF
run_cmd "$BASH" "$SCRIPT" rows --lint "$work/lint-empty.md"
assert_rc "lint of a plan with no rows exits 0" 0

cat >"$work/lint-legacy.md" <<'EOF'
## Execution map

| ID | Step summary | Tier | Wave | Depends on | Notes (runner · acceptance) |
| --- | --- | --- | --- | --- | --- |
| S1 | review | opus | 1 | — | session · top work |
| S2 | edit | haiku | 1 | — | delegate:cursor · `true` |
EOF
run_cmd "$BASH" "$SCRIPT" rows --lint "$work/lint-legacy.md"
assert_rc "lint accepts a legacy map without an Acceptance column" 0
assert_stdout "lint legacy prints ok" "ok"

write_stamped "$work/skip-batch.md" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: in-progress
---

## Execution map

$MAP_TABLE
| S1 | execute | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | mid | subagent | 1 | - | \`b.sh\` | \`true\` | mid |

## Execution log

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | keep |
| S2 | pending | |
EOF
run_cmd "$BASH" "$SCRIPT" batch "$work/skip-batch.md" execute-plan \
  --skipped S1 --note 'out of step-scope (dispatch via delegate)' \
  --skipped S2 --note 'out of step-scope (dispatch via delegate)' \
  --now 2026-04-01T03:00:00Z
assert_rc "batch --skipped exits 0" 0
assert_file_has "batch --skipped does not downgrade done" "$work/skip-batch.md" "| S1 | done | keep |"
assert_file_has "batch --skipped writes the note" "$work/skip-batch.md" "| S2 | skipped | out of step-scope (dispatch via delegate) |"

term_base "$work/defer.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/defer.md" cursor
printf '%s\n' "$LAST_OUT" >"$work/defer-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/defer.md" execute-plan "$work/defer-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" terminal "$work/defer.md" execute-plan "$work/defer-rows.json" \
  --outcome pass --backend claude-code \
  --model-requested 'grok-4-7-high,composer-2-5' \
  --model-resolved 'grok-4-7-high,composer-2-5' \
  --effort high --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --deferred-review --now 2026-04-01T04:00:00Z
assert_rc "deferred-review terminal exits 0" 0
assert_file_has "deferred-review forces partial" "$work/defer.md" "  status: partial"
assert_file_has "deferred-review leaves completed_at null" "$work/defer.md" "  completed_at: null"
assert_file_has "claude-code model list is stored" "$work/defer.md" 'model_requested: "grok-4-7-high,composer-2-5"'
assert_file_has "deferred outcome is partial" "$work/defer.md" "      outcome: partial"

cp "$work/defer.md" "$work/defer.before"
run_cmd "$BASH" "$SCRIPT" terminal "$work/defer.md" execute-plan "$work/defer-rows.json" \
  --outcome pass --backend claude-code \
  --model-requested 'not a slug!' \
  --model-resolved 'grok-4-7-high' \
  --effort high --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T05:00:00Z
assert_rc "invalid claude-code model list exits 2" 2
if cmp -s "$work/defer.before" "$work/defer.md"; then
  pass "invalid model list leaves the plan unchanged"
else
  fail "invalid model list leaves the plan unchanged"
fi

# terminal with no implementer Task: `none` is accepted for claude-code
term_base "$work/none.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/none.md" cursor
printf '%s\n' "$LAST_OUT" >"$work/none-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/none.md" execute-plan "$work/none-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" terminal "$work/none.md" execute-plan "$work/none-rows.json" \
  --outcome abort --backend claude-code \
  --model-requested none --model-resolved none --effort none \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T01:00:00Z
assert_rc "claude-code terminal with none model fields exits 0" 0
assert_file_has "none is stored as model_requested" "$work/none.md" 'model_requested: "none"'
assert_file_has "none is stored as model_resolved" "$work/none.md" 'model_resolved: "none"'
assert_file_has "none is stored as effort" "$work/none.md" 'effort: "none"'

cp "$work/none.md" "$work/none.before"
run_cmd "$BASH" "$SCRIPT" terminal "$work/none.md" execute-plan "$work/none-rows.json" \
  --outcome abort --backend claude-code \
  --model-requested none --model-resolved 'bad slug!' --effort none \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T02:00:00Z
assert_rc "claude-code none beside a bad slug still exits 2" 2
run_cmd "$BASH" "$SCRIPT" terminal "$work/none.md" execute-plan "$work/none-rows.json" \
  --outcome abort --backend claude-code \
  --model-requested 'not a slug!' --model-resolved none --effort none \
  --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T02:00:00Z
assert_rc "claude-code bad requested slug still exits 2" 2
if cmp -s "$work/none.before" "$work/none.md"; then
  pass "rejected none-case terminal leaves the plan unchanged"
else
  fail "rejected none-case terminal leaves the plan unchanged"
fi

# terminal pass must not mark rows that never ran or were skipped
term_cc_base() {
  write_stamped "$1" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
---

## Execution map

$MAP_TABLE
| S1 | mid | subagent | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | mid | delegate:cursor | 1 | - | \`b.sh\` | \`true\` | mid |
| S3 | mid | subagent | 2 | S2 | \`c.sh\` | \`true\` | mid |

## Execution log

- **Overall:** not-started

| ID | Status | Notes |
| --- | --- | --- |
| S1 | pending | |
| S2 | pending | |
| S3 | pending | |
EOF
}
term_cc() {
  local plan=$1
  shift
  run_cmd "$BASH" "$SCRIPT" terminal "$plan" execute-plan "$work/tcc-rows.json" \
    --outcome pass --backend claude-code \
    --model-requested grok-4-7-high --model-resolved grok-4-7-high \
    --effort high --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
    --fallback null --now 2026-04-01T04:00:00Z "$@"
}

term_cc_base "$work/tcc.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/tcc.md" claude-code
assert_rc "blocked rows exits 0" 0
assert_jq "blocked row S3 waits on S2" '.blocked == [{"id":"S3","on":"S2"}]'
printf '%s\n' "$LAST_OUT" >"$work/tcc-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc.md" execute-plan "$work/tcc-rows.json" --now 2026-04-01T00:00:00Z
assert_rc "blocked start exits 0" 0
run_cmd "$BASH" "$SCRIPT" batch "$work/tcc.md" execute-plan --done S1 --now 2026-04-01T01:00:00Z
assert_rc "blocked batch --done exits 0" 0
term_cc "$work/tcc.md" --deferred-review
assert_rc "deferred-review terminal with a blocked row exits 0" 0
assert_file_has "deferred-review keeps the done row" "$work/tcc.md" "| S1 | done |"
assert_file_has "deferred-review keeps the blocked row pending" "$work/tcc.md" "| S3 | pending |"

term_cc_base "$work/tcc-skip.md"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc-skip.md" execute-plan "$work/tcc-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" batch "$work/tcc-skip.md" execute-plan --skipped S2 --note 'delegate:review skipped' --now 2026-04-01T01:00:00Z
assert_rc "skip then batch --skipped exits 0" 0
term_cc "$work/tcc-skip.md"
assert_rc "clean terminal pass after a skip exits 0" 0
assert_file_has "terminal pass leaves a skipped row skipped" "$work/tcc-skip.md" "| S2 | skipped | delegate:review skipped |"
assert_file_has "terminal pass still marks the selected row done" "$work/tcc-skip.md" "| S1 | done |"

term_cc_base "$work/tcc-skip2.md"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc-skip2.md" execute-plan "$work/tcc-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" batch "$work/tcc-skip2.md" execute-plan --skipped S2 --note 'delegate:review skipped' --now 2026-04-01T01:00:00Z
term_cc "$work/tcc-skip2.md" --deferred-review
assert_file_has "deferred terminal leaves a skipped row skipped" "$work/tcc-skip2.md" "| S2 | skipped | delegate:review skipped |"
assert_file_has "deferred terminal does not auto-mark S1" "$work/tcc-skip2.md" "| S1 | pending |"

term_cc_base "$work/tcc-done.md"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc-done.md" execute-plan "$work/tcc-rows.json" --now 2026-04-01T00:00:00Z
term_cc "$work/tcc-done.md"
assert_rc "clean terminal pass auto-marks selected rows" 0
assert_file_has "clean terminal pass marks S1 done" "$work/tcc-done.md" "| S1 | done |"
assert_file_has "clean terminal pass leaves S3 pending" "$work/tcc-done.md" "| S3 | pending |"

# indirect dependents of a blocked row are blocked too
term_cc_chain() {
  write_stamped "$1" <<EOF
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
---

## Execution map

$MAP_TABLE
| S1 | mid | delegate:cursor | 1 | - | \`a.sh\` | \`true\` | mid |
| S2 | mid | subagent | 2 | S1 | \`b.sh\` | \`true\` | mid |
| S3 | mid | subagent | 1 | - | \`c.sh\` | \`true\` | mid |
| S4 | mid | subagent | 3 | S2 | \`d.sh\` | \`true\` | mid |

## Execution log

- **Overall:** not-started

| ID | Status | Notes |
| --- | --- | --- |
| S1 | pending | |
| S2 | pending | |
| S3 | pending | |
| S4 | pending | |
EOF
}
term_cc_chain "$work/tcc-chain.md"
run_cmd "$BASH" "$SCRIPT" rows "$work/tcc-chain.md" claude-code
assert_rc "chain rows exits 0" 0
assert_jq "indirect dependent S4 is blocked on S2" '.blocked == [{"id":"S2","on":"S1"},{"id":"S4","on":"S2"}]'
printf '%s\n' "$LAST_OUT" >"$work/tcc-chain-rows.json"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc-chain.md" execute-plan "$work/tcc-chain-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" terminal "$work/tcc-chain.md" execute-plan "$work/tcc-chain-rows.json" \
  --outcome pass --backend claude-code \
  --model-requested grok-4-7-high --model-resolved grok-4-7-high \
  --effort high --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T04:00:00Z
assert_rc "clean terminal pass with a blocked chain exits 0" 0
assert_file_has "chain pass marks the unblocked row done" "$work/tcc-chain.md" "| S3 | done |"
assert_file_has "chain pass leaves the blocked S2 pending" "$work/tcc-chain.md" "| S2 | pending |"
assert_file_has "chain pass leaves the indirect S4 pending" "$work/tcc-chain.md" "| S4 | pending |"

term_cc_chain "$work/tcc-chain-fail.md"
run_cmd "$BASH" "$SCRIPT" start "$work/tcc-chain-fail.md" execute-plan "$work/tcc-chain-rows.json" --now 2026-04-01T00:00:00Z
run_cmd "$BASH" "$SCRIPT" terminal "$work/tcc-chain-fail.md" execute-plan "$work/tcc-chain-rows.json" \
  --outcome fail --backend claude-code \
  --model-requested grok-4-7-high --model-resolved grok-4-7-high \
  --effort high --started 2026-04-01T00:00:00Z --findings 0 --fix-loops 0 \
  --fallback null --now 2026-04-01T04:00:00Z
assert_file_has "fail terminal marks the unblocked row failed" "$work/tcc-chain-fail.md" "| S3 | failed |"
assert_file_has "fail terminal leaves the blocked S2 pending" "$work/tcc-chain-fail.md" "| S2 | pending |"
assert_file_has "fail terminal leaves the indirect S4 pending" "$work/tcc-chain-fail.md" "| S4 | pending |"

write_stamped "$work/stamp.md" <<'EOF'
---
created_at: "2026-01-01T00:00:00Z"
plan_sha: "placeholder"
approved_at: "2026-01-02T00:00:00Z"
execution:
  status: not-started
---

# Stamp

BODY
EOF
created_before=$(awk '/^created_at:/ { print; exit }' "$work/stamp.md")
run_cmd "$BASH" "$SCRIPT" stamp "$work/stamp.md" --now 2026-05-01T00:00:00Z
assert_rc "stamp exits 0" 0
assert_file_has "stamp sets approved_at" "$work/stamp.md" 'approved_at: "2026-05-01T00:00:00Z"'
assert_file_has "stamp keeps created_at" "$work/stamp.md" "$created_before"
if grep -q '^created_at:' "$work/stamp.md" && [[ $(grep -c '^created_at:' "$work/stamp.md") -eq 1 ]]; then
  pass "stamp does not add a second created_at"
else
  fail "stamp does not add a second created_at"
fi
sum=$(plan_sha_of "$work/stamp.md")
assert_file_has "stamp writes plan_sha" "$work/stamp.md" "plan_sha: \"$sum\""
[[ "$LAST_OUT" =~ ^[0-9]+$ ]] && pass "stamp prints body bytes" || fail "stamp prints body bytes (got $LAST_OUT)"

python3 -c 'print("x"*16000)' >"$work/big-body.txt"
{
  printf '%s\n' '---' 'plan_sha: "placeholder"' '---' '# big'
  cat "$work/big-body.txt"
} >"$work/big.md"
run_cmd "$BASH" "$SCRIPT" stamp "$work/big.md" --now 2026-05-01T00:00:00Z
assert_rc "stamp over the soft cap still exits 0" 0
assert_stderr_has "stamp warns over 15000" "over 15000"
if grep -q '^created_at:' "$work/big.md"; then
  fail "stamp of a plan without created_at invented one"
else
  pass "stamp does not invent created_at"
fi

mkdir -p "$work/recency"
cat >"$work/recency/2026-11-08-older.md" <<'EOF'
# older filename
EOF
cat >"$work/recency/2611081032-newer.md" <<'EOF'
# newer filename
EOF
cat >"$work/recency/2611091032-skip.notes.md" <<'EOF'
---
created_at: "2099-01-01T00:00:00Z"
---
# notes
EOF
cat >"$work/recency/created.md" <<'EOF'
---
created_at: "2026-12-01T00:00:00Z"
---
# created wins
EOF
TZ=Asia/Bangkok run_cmd "$BASH" "$SCRIPT" recent "$work/recency"
assert_rc "recent picks created_at over filenames" 0
assert_stdout "recent prints the created_at plan" "$work/recency/created.md"
rm "$work/recency/created.md"
TZ=Asia/Bangkok run_cmd "$BASH" "$SCRIPT" recent "$work/recency"
assert_rc "recent uses filename prefixes and ignores notes" 0
assert_stdout "recent prints the yymmddhhmm plan" "$work/recency/2611081032-newer.md"
cp "$work/recency/2611081032-newer.md" "$work/recency/also.md"
# Give also.md the same filename-derived instant by copying the winning name's prefix via created_at of the computed ts.
# Two files with the same created_at tie.
cat >"$work/recency/tie-a.md" <<'EOF'
---
created_at: "2026-06-01T00:00:00Z"
---
EOF
cat >"$work/recency/tie-b.md" <<'EOF'
---
created_at: "2026-06-01T00:00:00Z"
---
EOF
rm "$work/recency/2611081032-newer.md" "$work/recency/2026-11-08-older.md" "$work/recency/also.md"
run_cmd "$BASH" "$SCRIPT" recent "$work/recency"
assert_rc "recent tie exits 3" 3
assert_stderr_has "recent tie message" "tie"

# Filename prefixes are local wall time. 2611081032 in +07 is 03:32Z, which is
# before created_at 05:00Z. 2026-11-08 at local midnight is 17:00Z the day
# before, which is before created_at 18:00Z. Both must hold for GNU and BSD date.
mkdir -p "$work/recency-tz"
cat >"$work/recency-tz/2611081032-x.md" <<'EOF'
# filename prefix
EOF
cat >"$work/recency-tz/created-later.md" <<'EOF'
---
created_at: "2026-11-08T05:00:00Z"
---
# later
EOF
TZ=Asia/Bangkok run_cmd "$BASH" "$SCRIPT" recent "$work/recency-tz"
assert_rc "yymmddhhmm prefix is older than created_at 05:00Z" 0
assert_stdout "recent prefers created_at 05:00Z over 2611081032-x" "$work/recency-tz/created-later.md"
rm -rf "$work/recency-tz"
mkdir -p "$work/recency-tz"
cat >"$work/recency-tz/2026-11-08-x.md" <<'EOF'
# date prefix
EOF
cat >"$work/recency-tz/created-later.md" <<'EOF'
---
created_at: "2026-11-07T18:00:00Z"
---
# later
EOF
TZ=Asia/Bangkok run_cmd "$BASH" "$SCRIPT" recent "$work/recency-tz"
assert_rc "YYYY-MM-DD prefix is older than created_at 18:00Z" 0
assert_stdout "recent prefers created_at 18:00Z over 2026-11-08-x" "$work/recency-tz/created-later.md"

cp "$work/stamp.md" "$work/approve.md"
run_cmd "$BASH" "$SCRIPT" approve "$work/approve.md" --now 2026-06-01T00:00:00Z
assert_rc "approve after a matching lock exits 0" 0
assert_file_has "approve writes gate_b_sha" "$work/approve.md" "gate_b_sha: \"$sum\""
assert_file_has "approve writes gate_b_at" "$work/approve.md" 'gate_b_at: "2026-06-01T00:00:00Z"'
assert_file_has "approve keeps created_at" "$work/approve.md" "$created_before"
run_cmd "$BASH" "$SCRIPT" lock --gate "$work/approve.md"
assert_rc "lock --gate exits 0" 0
assert_stdout "lock --gate prints gate_b_at" "2026-06-01T00:00:00Z"

cp "$work/legacy.md" "$work/approve-legacy.md"
run_cmd "$BASH" "$SCRIPT" approve "$work/approve-legacy.md" --now 2026-06-01T00:00:00Z
assert_rc "approve without plan_sha exits 3" 3
if cmp -s "$work/legacy.md" "$work/approve-legacy.md"; then
  pass "approve without plan_sha writes nothing"
else
  fail "approve without plan_sha writes nothing"
fi

cp "$work/lock-bad.md" "$work/approve-bad.md"
run_cmd "$BASH" "$SCRIPT" approve "$work/approve-bad.md" --now 2026-06-01T00:00:00Z
assert_rc "approve when the lock fails exits 3" 3
if cmp -s "$work/lock-bad.md" "$work/approve-bad.md"; then
  pass "approve lock failure writes nothing"
else
  fail "approve lock failure writes nothing"
fi

run_cmd "$BASH" "$SCRIPT" lock "$work/approve.md" --gate
assert_rc "lock with a trailing --gate exits 2" 2
assert_stdout_empty "lock with a trailing --gate prints nothing"
run_cmd "$BASH" "$SCRIPT" lock --gate "$work/approve.md" extra
assert_rc "lock --gate with an extra argument exits 2" 2
run_cmd "$BASH" "$SCRIPT" lock --bogus "$work/approve.md"
assert_rc "lock with an unknown flag exits 2" 2
run_cmd "$BASH" "$SCRIPT" lock "$work/approve.md" --bogus
assert_rc "lock with an unknown trailing argument exits 2" 2

printf 'x\n' >>"$work/approve.md"
run_cmd "$BASH" "$SCRIPT" lock --gate "$work/approve.md"
assert_rc "lock --gate mismatch exits 3" 3
assert_stdout_empty "lock --gate mismatch prints nothing"

printf 'PASS/FAIL summary: %s failed\n' "$fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
