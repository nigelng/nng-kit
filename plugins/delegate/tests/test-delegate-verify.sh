#!/usr/bin/env bash
# Fixture tests for delegate-verify.sh. Run with bash.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
SCRIPT="$ROOT/nng-kit/plugins/delegate/scripts/delegate-verify.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-verify.XXXXXX")
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

assert_contains() {
  local label=$1 needle=$2
  if printf '%s\n' "$LAST_OUT" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (missing: $needle)"
  fi
}

assert_lacks() {
  local label=$1 needle=$2
  if printf '%s\n' "$LAST_OUT" | grep -qF -- "$needle"; then
    fail "$label (unexpected: $needle)"
  else
    pass "$label"
  fi
}

assert_last_line() {
  local label=$1 want=$2 got
  got=$(printf '%s\n' "$LAST_OUT" | tail -n 1)
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (last line: $got)"
  fi
}

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
cmds="$work/cmds"
mkdir -p "$cmds"

# --- passing commands ---------------------------------------------------------
cat >"$cmds/pass.txt" <<'EOF'
true
echo hello
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/pass.txt"
assert_rc "pass commands rc 0" 0
assert_contains "pass echoes command" '$ true'
assert_contains "pass echoes exit" 'exit: 0'
assert_last_line "pass final line" 'PASS'

# --- failing command shows output tail ----------------------------------------
cat >"$cmds/fail.txt" <<'EOF'
for i in $(seq 1 25); do echo "outline$i"; done; exit 3
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/fail.txt"
assert_rc "failing command rc 1" 1
assert_contains "fail exit code shown" 'exit: 3'
assert_contains "fail tail last line" '  outline25'
assert_lacks "fail tail drops early lines" '  outline5'
assert_last_line "fail final line" 'FAIL'

# --- pipeline line runs whole --------------------------------------------------
cat >"$cmds/pipeline.txt" <<'EOF'
false | true
printf 'one\ntwo\n' | grep -c '^two$'
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/pipeline.txt"
assert_rc "pipeline rc 0" 0
assert_contains "pipeline first command" '$ false | true'
assert_last_line "pipeline final line" 'PASS'

# --- comments and blank lines skipped ------------------------------------------
cat >"$cmds/comments.txt" <<'EOF'
# a comment

   # an indented comment
   
true
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/comments.txt"
assert_rc "comments rc 0" 0
n_cmds=$(printf '%s\n' "$LAST_OUT" | grep -c '^[$] ' || true)
if [[ "$n_cmds" -eq 1 ]]; then
  pass "comments: exactly one command ran"
else
  fail "comments: exactly one command ran (got $n_cmds)"
fi
assert_last_line "comments final line" 'PASS'

# --- no effective commands ------------------------------------------------------
cat >"$cmds/empty.txt" <<'EOF'
# only comments

   # nothing else
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/empty.txt"
assert_rc "empty rc 0" 0
assert_last_line "empty final line" 'PASS (no commands)'

# --- tree change wins ------------------------------------------------------------
cat >"$cmds/tree.txt" <<'EOF'
touch planted-by-verify.txt
EOF
run_cmd bash "$SCRIPT" "$repo" "$cmds/tree.txt"
assert_rc "tree change rc 3" 3
assert_contains "tree change diff shown" 'planted-by-verify.txt'
assert_last_line "tree change final line" 'FAIL (tree changed)'
rm -f "$repo/planted-by-verify.txt"

# --- timeout ---------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  cat >"$cmds/slow.txt" <<'EOF'
sleep 5
EOF
  set +e
  LAST_OUT=$(DELEGATE_VERIFY_TIMEOUT=1 bash "$SCRIPT" "$repo" "$cmds/slow.txt" 2>"$work/slow.err")
  LAST_RC=$?
  set -e
  LAST_ERR=$(cat "$work/slow.err")
  if [[ "$LAST_RC" -eq 1 ]] && printf '%s\n' "$LAST_OUT" | grep -qF 'exit: 124'; then
    pass "timeout kills slow command"
  else
    fail "timeout kills slow command (rc $LAST_RC)"
  fi
  assert_last_line "timeout final line" 'FAIL'
else
  printf 'SKIP: no timeout/gtimeout on PATH; timeout case not run\n'
fi

# --- usage errors ------------------------------------------------------------------
cat >"$cmds/ok.txt" <<'EOF'
true
EOF
run_cmd bash "$SCRIPT" "relative/repo" "$cmds/ok.txt"
assert_rc "relative root rc 2" 2

run_cmd bash "$SCRIPT" "$repo" "$work/no-such-file.txt"
assert_rc "missing commands file rc 2" 2

mkdir -p "$work/not-a-repo"
run_cmd bash "$SCRIPT" "$work/not-a-repo" "$cmds/ok.txt"
assert_rc "non-git root rc 2" 2

echo "failures: $fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
