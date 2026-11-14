#!/usr/bin/env bash
# env-snippet.sh — fixture harness for the inline RELAY_* env+resolver snippet
# embedded in the relay skills' fenced bash blocks. The three unmasked copies
# (save, discard, pickup/references/remote.md) must be byte-identical and end
# with `"${root:-unset}"`. The check copy must equal them except for its final
# printf line, which masks root as `set`/`unset`. All copies must run with empty
# stderr under bash AND zsh (macOS default agent shell — `${!k+x}` indirect
# expansion is a fatal "bad substitution" there), and stay semantically equal
# to relay_load_env_file and relay_resolve_remote in scripts/relay-lib.sh.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$PLUGIN_ROOT/scripts/relay-lib.sh"
UNMASKED_FILES=(
  "$PLUGIN_ROOT/skills/save/SKILL.md"
  "$PLUGIN_ROOT/skills/discard/SKILL.md"
  "$PLUGIN_ROOT/skills/pickup/references/remote.md"
)
CHECK_FILE="$PLUGIN_ROOT/skills/check/SKILL.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# Literal suffixes expected on the final line of each snippet copy.
# shellcheck disable=SC2016
UNMASKED_SUFFIX='"${backend:-none}" "$relay_status" "${root:-unset}"'
# shellcheck disable=SC2016
MASKED_SUFFIX='"${backend:-none}" "$relay_status" "$([ -n "$root" ] && echo set || echo unset)"'

# Extract from `# RELAY_* from` through the closing code fence (excluded).
extract_snippet() {
  awk '
    /^# RELAY_\* from/ { p = 1 }
    p && /^```[[:space:]]*$/ { closed = 1; exit }
    p { print }
    END { if (!p || !closed) exit 1 }
  ' "$1"
}

extract_to_file() { # <src-md> <dst-sh>
  local src="$1" dst="$2" rel
  rel="${src#"$PLUGIN_ROOT"/}"
  if ! extract_snippet "$src" >"$dst" || [ ! -s "$dst" ]; then
    bad "snippet missing or unclosed: $rel"
    return 1
  fi
  return 0
}

assert_root_suffix() { # <label> <file> <suffix>
  local label="$1" file="$2" suffix="$3" last
  last="$(tail -n 1 "$file")"
  case "$last" in
    *"$suffix") ok "$label" ;;
    *) bad "$label (got '$last')" ;;
  esac
}

compare_against_ref() { # <ref> <candidate> <rel>
  [ -f "$1" ] || return 1
  if cmp -s "$1" "$2"; then
    return 0
  fi
  bad "unmasked snippet differs from skills/save/SKILL.md: $3"
  return 1
}

verify_unmasked() {
  local f rel dst idx=0 ident=1
  for f in "${UNMASKED_FILES[@]}"; do
    idx=$((idx + 1))
    rel="${f#"$PLUGIN_ROOT"/}"
    dst="$TMP/unmasked-$idx.sh"
    if ! extract_to_file "$f" "$dst"; then
      ident=0
      continue
    fi
    assert_root_suffix "$rel: ends with unmasked root" "$dst" "$UNMASKED_SUFFIX"
    if [ "$idx" = 1 ]; then
      cp "$dst" "$TMP/unmasked.sh"
    elif ! compare_against_ref "$TMP/unmasked.sh" "$dst" "$rel"; then
      ident=0
    fi
  done
  if [ "$ident" = 1 ]; then
    ok "three unmasked snippets byte-identical"
  fi
}

verify_check() {
  local rel="${CHECK_FILE#"$PLUGIN_ROOT"/}"
  extract_to_file "$CHECK_FILE" "$TMP/check.sh" || return 1
  assert_root_suffix "$rel: ends with set/unset root mask" "$TMP/check.sh" "$MASKED_SUFFIX"
  [ -s "$TMP/unmasked.sh" ] || return 1
  sed '$d' "$TMP/unmasked.sh" >"$TMP/unmasked.head"
  sed '$d' "$TMP/check.sh" >"$TMP/check.head"
  if cmp -s "$TMP/unmasked.head" "$TMP/check.head"; then
    ok "check snippet identical to unmasked before final line"
  else
    bad "check snippet differs from unmasked outside final printf line"
    diff -u "$TMP/unmasked.head" "$TMP/check.head" | head -20 | sed 's/^/    /'
  fi
}

# --- identity & root-output structure ----------------------------------------
verify_unmasked
verify_check

if [ ! -s "$TMP/unmasked.sh" ] || [ ! -s "$TMP/check.sh" ]; then
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# --- runners -----------------------------------------------------------------
XDG="$TMP/xdg"
HOME_F="$TMP/home"
mkdir -p "$XDG/relay" "$HOME_F"

# Literal payload for the child shell — $VAR must reach it unexpanded.
# shellcheck disable=SC2016
REPORT='printf "%s|%s|%s\n" "${RELAY_BACKEND-<unset>}" "${RELAY_ROOT-<unset>}" "${RELAY_DROPBOX_ROOT-<unset>}"'
err="$TMP/stderr"
out=""

# run_env <shell> [preset K=V ...] — env-file load under an empty environment.
run_env() {
  local sh="$1"
  shift
  # $REPORT is a literal payload for the child shell — $VAR stays unexpanded.
  # shellcheck disable=SC2016
  out="$(env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" \
    SNIPPET="$TMP/unmasked.sh" "$@" "$sh" -c \
    'source "$SNIPPET" >/dev/null && '"$REPORT" 2>>"$err")"
}

# ref_out [preset K=V ...] — relay_load_env_file under bash, same presets.
ref_out() {
  # $REPORT is a literal payload for the child shell — $VAR stays unexpanded.
  # shellcheck disable=SC2016
  env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" "$@" bash -c \
    'source "$1" && relay_load_env_file && '"$REPORT" _ "$LIB" 2>>"$err"
}

# check_case <label> <shell> [preset K=V ...] — env vars must match lib.
check_case() {
  local label="$1" sh="$2" want rc=0
  shift 2
  : >"$err"
  run_env "$sh" "$@" || rc=$?
  want="$(ref_out "$@")" || rc=$?
  if [ "$rc" != 0 ]; then
    bad "$label: exited $rc"
  elif [ -s "$err" ]; then
    bad "$label: stderr not empty"
    sed 's/^/    /' "$err" | head -3
  elif [ "$out" = "$want" ]; then
    ok "$label"
  else
    bad "$label: snippet='$out' lib='$want'"
  fi
}

# run_snippet <shell> <snippet> [preset K=V ...] — full snippet stdout to $TMP/got.
run_snippet() {
  local sh="$1" snippet="$2"
  shift 2
  # $SNIPPET is a literal payload for the child shell — expanded inside child.
  # shellcheck disable=SC2016
  env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" \
    SNIPPET="$snippet" "$@" "$sh" -c 'source "$SNIPPET"' >"$TMP/got" 2>>"$err"
}

# ref_resolve <masked: 0|1> [preset K=V ...] — lib resolver formatted to $TMP/want.
ref_resolve() {
  local masked="$1" tsv
  shift
  # $1 is positional parameter for bash -c — must stay unexpanded in parent.
  # shellcheck disable=SC2016
  tsv="$(env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" "$@" bash -c \
    'source "$1" && relay_load_env_file && relay_resolve_remote' _ "$LIB" 2>>"$err")" || return 1
  printf '%s\n' "$tsv" | awk -F'\t' -v masked="$masked" '
    NF != 3 { exit 1 }
    {
      b = ($1 != "" ? $1 : "none")
      s = $3
      r = (masked == "1") ? ($2 != "" ? "set" : "unset") : ($2 != "" ? $2 : "unset")
      printf "backend=%s status=%s root=%s\n", b, s, r
    }
    END { if (NR != 1) exit 1 }
  ' >"$TMP/want"
}

# check_status_case <label> <shell> <snippet> <masked: 0|1> [preset K=V ...]
check_status_case() {
  local label="$1" sh="$2" snippet="$3" masked="$4"
  shift 4
  : >"$err"
  if ! run_snippet "$sh" "$snippet" "$@"; then
    bad "$label: snippet exited non-zero"
    sed 's/^/    /' "$err" | head -3
    return
  fi
  if ! ref_resolve "$masked" "$@"; then
    bad "$label: relay_resolve_remote failed"
    return
  fi
  if [ -s "$err" ]; then
    bad "$label: stderr not empty"
    sed 's/^/    /' "$err" | head -3
  elif cmp -s "$TMP/got" "$TMP/want"; then
    ok "$label"
  else
    bad "$label: got='$(cat "$TMP/got")' want='$(cat "$TMP/want")'"
  fi
}

check_literal_status() { # <label> <snippet> <expected-line> [preset K=V ...]
  local label="$1" snippet="$2" want="$3"
  shift 3
  : >"$err"
  if ! run_snippet bash "$snippet" "$@"; then
    bad "$label: snippet exited non-zero"
    sed 's/^/    /' "$err" | head -3
    return
  fi
  printf '%s\n' "$want" >"$TMP/want"
  if [ -s "$err" ]; then
    bad "$label: stderr not empty"
    sed 's/^/    /' "$err" | head -3
  elif cmp -s "$TMP/got" "$TMP/want"; then
    ok "$label"
  else
    bad "$label: got='$(cat "$TMP/got")' want='$want'"
  fi
}

SHELLS=(bash)
if command -v zsh >/dev/null 2>&1; then
  SHELLS+=(zsh)
else
  echo "note: zsh not installed — zsh parity skipped"
fi

each_shell() { # <label> [preset K=V ...]
  local label="$1" sh
  shift
  for sh in "${SHELLS[@]}"; do
    check_case "$label ($sh)" "$sh" "$@"
  done
}

each_status() { # <label> [preset K=V ...]
  local label="$1" sh
  shift
  for sh in "${SHELLS[@]}"; do
    check_status_case "$label (unmasked, $sh)" "$sh" "$TMP/unmasked.sh" 0 "$@"
    check_status_case "$label (check, $sh)" "$sh" "$TMP/check.sh" 1 "$@"
  done
}

# --- env-file loading fixtures -----------------------------------------------

# All three keys; values with spaces and a literal $HOME (must not expand).
cat >"$XDG/relay/env" <<'EOF'
RELAY_BACKEND=dropbox
RELAY_ROOT=$HOME/Relay Dir
RELAY_DROPBOX_ROOT=/alias root
EOF
each_shell "all keys, spaces + literal \$HOME"

# A preset environment variable wins over the file.
each_shell "preset RELAY_ROOT wins" RELAY_ROOT=/preset-root

# Lines containing a tab or CR are ignored entirely.
printf 'RELAY_BACKEND=onedrive\nRELAY_ROOT=/bad\tvalue\nRELAY_DROPBOX_ROOT=/leg\racy\nRELAY_DROPBOX_ROOT=/alias\n' \
  >"$XDG/relay/env"
each_shell "tab and CR lines ignored"

# Unknown keys, export-prefixed and quoted lines are ignored.
cat >"$XDG/relay/env" <<'EOF'
# comment
OTHER_KEY=zzz
export RELAY_ROOT=/exported
"RELAY_BACKEND"=quoted
RELAY_ROOT=/real
EOF
each_shell "unknown/export/quoted ignored"

# An unlisted RELAY_* line is not loaded.
printf 'RELAY_UNKNOWN=/old root\nRELAY_ROOT=/real\n' >"$XDG/relay/env"
each_shell "unlisted RELAY_* key ignored"

# No env file at all.
rm -f "$XDG/relay/env"
each_shell "no env file"

# --- env-file literal anchors (bash) -----------------------------------------
cat >"$XDG/relay/env" <<'EOF'
RELAY_BACKEND=dropbox
RELAY_ROOT=$HOME/Relay Dir
RELAY_DROPBOX_ROOT=/alias root
EOF
: >"$err"
run_env bash
# Literal expectation: $HOME must arrive unexpanded.
# shellcheck disable=SC2016
if [ "$out" = 'dropbox|$HOME/Relay Dir|/alias root' ]; then
  ok "literal: all keys load verbatim"
else
  bad "literal: all keys load verbatim (got '$out')"
fi

printf 'RELAY_BACKEND=onedrive\nRELAY_ROOT=/bad\tvalue\nRELAY_DROPBOX_ROOT=/leg\racy\nRELAY_DROPBOX_ROOT=/alias\n' \
  >"$XDG/relay/env"
: >"$err"
run_env bash
if [ "$out" = 'onedrive|<unset>|/alias' ]; then
  ok "literal: tab/CR lines ignored"
else
  bad "literal: tab/CR lines ignored (got '$out')"
fi

# The ignored key never reaches the child environment.
printf 'RELAY_UNKNOWN=/old root\nRELAY_ROOT=/real\n' >"$XDG/relay/env"
: >"$err"
# shellcheck disable=SC2016
REPORT='printf "%s\n" "${RELAY_UNKNOWN-<unset>}"'
run_env bash
if [ "$out" = '<unset>' ]; then
  ok "literal: RELAY_UNKNOWN not exported"
else
  bad "literal: RELAY_UNKNOWN not exported (got '$out')"
fi

# --- resolver status parity (bash & zsh, unmasked & check) -------------------
rm -f "$XDG/relay/env"

# on
each_status "status on: default backend" RELAY_ROOT=/remote/relay
each_status "status on: explicit dropbox" RELAY_ROOT=/remote/relay RELAY_BACKEND=dropbox
each_status "status on: empty RELAY_BACKEND" RELAY_ROOT=/remote/relay RELAY_BACKEND=
each_status "status on: RELAY_ROOT beats alias" RELAY_ROOT=/remote/relay RELAY_DROPBOX_ROOT=/remote/alias
each_status "status on: unlisted RELAY_* tab ignored" RELAY_ROOT=/remote/relay RELAY_UNKNOWN=$'/bad\ttab'

# off
each_status "status off: no root"
each_status "status off: backend without root" RELAY_BACKEND=onedrive
each_status "status off: empty RELAY_ROOT" RELAY_ROOT=

# deprecated-alias
each_status "status deprecated-alias" RELAY_DROPBOX_ROOT=/remote/alias
each_status "status deprecated-alias: empty RELAY_ROOT" RELAY_ROOT= RELAY_DROPBOX_ROOT=/remote/alias

# invalid-root
each_status "status invalid-root: tab in RELAY_ROOT" RELAY_ROOT=$'/bad\troot'
each_status "status invalid-root: newline in RELAY_ROOT" RELAY_ROOT=$'/bad\nroot'
each_status "status invalid-root: tab keeps backend" RELAY_BACKEND=s3 RELAY_ROOT=$'/bad\troot'
each_status "status invalid-root: newline in alias" RELAY_DROPBOX_ROOT=$'/bad\nalias'

# not-implemented
each_status "status not-implemented: onedrive" RELAY_ROOT=/remote/one RELAY_BACKEND=onedrive

# unknown-backend
each_status "status unknown-backend: s3" RELAY_ROOT=/remote/s3 RELAY_BACKEND=s3

# env-file values feeding into resolver
cat >"$XDG/relay/env" <<'EOF'
RELAY_BACKEND=onedrive
RELAY_ROOT=$HOME/Relay Dir
EOF
each_status "env file feeds resolver (spaces + \$HOME)"

printf 'RELAY_DROPBOX_ROOT=/alias root\n' >"$XDG/relay/env"
each_status "env file feeds resolver (deprecated-alias)"
rm -f "$XDG/relay/env"

# --- resolver literal anchors (bash) -----------------------------------------
check_literal_status "literal status: on (unmasked)" \
  "$TMP/unmasked.sh" "backend=dropbox status=on root=/r/on" RELAY_ROOT=/r/on
check_literal_status "literal status: on (check masked)" \
  "$TMP/check.sh" "backend=dropbox status=on root=set" RELAY_ROOT=/r/on
check_literal_status "literal status: off (unmasked)" \
  "$TMP/unmasked.sh" "backend=none status=off root=unset"
check_literal_status "literal status: off (check)" \
  "$TMP/check.sh" "backend=none status=off root=unset"
check_literal_status "literal status: deprecated-alias (unmasked)" \
  "$TMP/unmasked.sh" "backend=dropbox status=deprecated-alias root=/r/alias" RELAY_DROPBOX_ROOT=/r/alias
check_literal_status "literal status: deprecated-alias (check masked)" \
  "$TMP/check.sh" "backend=dropbox status=deprecated-alias root=set" RELAY_DROPBOX_ROOT=/r/alias
check_literal_status "literal status: invalid-root (unmasked)" \
  "$TMP/unmasked.sh" "backend=dropbox status=invalid-root root=unset" RELAY_ROOT=$'/r\tbad'
check_literal_status "literal status: invalid-root (check)" \
  "$TMP/check.sh" "backend=dropbox status=invalid-root root=unset" RELAY_ROOT=$'/r\tbad'
check_literal_status "literal status: not-implemented (unmasked)" \
  "$TMP/unmasked.sh" "backend=onedrive status=not-implemented root=/r/one" RELAY_ROOT=/r/one RELAY_BACKEND=onedrive
check_literal_status "literal status: not-implemented (check masked)" \
  "$TMP/check.sh" "backend=onedrive status=not-implemented root=set" RELAY_ROOT=/r/one RELAY_BACKEND=onedrive
check_literal_status "literal status: unknown-backend (unmasked)" \
  "$TMP/unmasked.sh" "backend=s3 status=unknown-backend root=/r/s3" RELAY_ROOT=/r/s3 RELAY_BACKEND=s3
check_literal_status "literal status: unknown-backend (check masked)" \
  "$TMP/check.sh" "backend=s3 status=unknown-backend root=set" RELAY_ROOT=/r/s3 RELAY_BACKEND=s3

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
