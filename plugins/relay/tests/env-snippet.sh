#!/usr/bin/env bash
# env-snippet.sh — fixture harness for the inline RELAY_* env snippet embedded
# in the relay skills' fenced bash blocks. The snippet must be byte-identical
# across all four copies, run with empty stderr under bash AND zsh (the macOS
# default agent shell — `${!k+x}` indirect expansion is a fatal "bad
# substitution" there), and stay semantically equal to
# relay_load_env_file in scripts/relay-lib.sh.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$PLUGIN_ROOT/scripts/relay-lib.sh"
SNIPPET_FILES=(
  "$PLUGIN_ROOT/skills/save/SKILL.md"
  "$PLUGIN_ROOT/skills/check/SKILL.md"
  "$PLUGIN_ROOT/skills/discard/SKILL.md"
  "$PLUGIN_ROOT/skills/pickup/references/remote.md"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# The snippet runs from its comment line through the closing column-0 `fi`.
extract_snippet() {
  awk '/^# RELAY_\* from/{p=1} p{print} p&&/^fi$/{exit}' "$1"
}

# --- identity: all four copies byte-identical -------------------------------
first=""
ident=1
for f in "${SNIPPET_FILES[@]}"; do
  s="$(extract_snippet "$f")"
  rel="${f#"$PLUGIN_ROOT"/}"
  if [ -z "$s" ]; then
    bad "snippet not found: $rel"
    ident=0
    continue
  fi
  if [ -z "$first" ]; then
    first="$s"
    printf '%s\n' "$s" >"$TMP/snippet.sh"
  elif [ "$s" != "$first" ]; then
    bad "snippet differs from skills/save/SKILL.md: $rel"
    ident=0
  fi
done
[ "$ident" = 1 ] && ok "four snippets byte-identical"

# --- runner ------------------------------------------------------------------
XDG="$TMP/xdg"
HOME_F="$TMP/home"
mkdir -p "$XDG/relay" "$HOME_F"

# Literal payload for the child shell — $VAR must reach it unexpanded.
# shellcheck disable=SC2016
REPORT='printf "%s|%s|%s|%s\n" "${RELAY_BACKEND-<unset>}" "${RELAY_ROOT-<unset>}" "${RELAY_LEGACY_ROOT-<unset>}" "${RELAY_DROPBOX_ROOT-<unset>}"'
err="$TMP/stderr"
out=""

# run_env <shell> [preset K=V ...] — snippet under an empty environment.
run_env() {
  local sh="$1"
  shift
  # $REPORT is a literal payload for the child shell — $VAR stays unexpanded.
  # shellcheck disable=SC2016
  out="$(env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" \
    SNIPPET="$TMP/snippet.sh" "$@" "$sh" -c \
    'source "$SNIPPET"; '"$REPORT" 2>>"$err")"
}

# ref_out [preset K=V ...] — relay_load_env_file under bash, same presets.
ref_out() {
  # $REPORT is a literal payload for the child shell — $VAR stays unexpanded.
  # shellcheck disable=SC2016
  env -i PATH="$PATH" HOME="$HOME_F" XDG_CONFIG_HOME="$XDG" "$@" bash -c \
    'source "$1"; relay_load_env_file; '"$REPORT" _ "$LIB" 2>>"$err"
}

# check_case <label> <shell> [preset K=V ...] — snippet output must equal the
# library's and stderr must stay empty.
check_case() {
  local label="$1" sh="$2" want
  shift 2
  : >"$err"
  run_env "$sh" "$@"
  want="$(ref_out "$@")"
  if [ -s "$err" ]; then
    bad "$label: stderr not empty"
    sed 's/^/    /' "$err" | head -3
  elif [ "$out" = "$want" ]; then
    ok "$label"
  else
    bad "$label: snippet='$out' lib='$want'"
  fi
}

SHELLS=(bash)
if command -v zsh >/dev/null 2>&1; then
  SHELLS+=(zsh)
else
  echo "note: zsh not installed — zsh parity skipped"
fi

each_shell() { # <label> [preset K=V ...]
  local sh
  for sh in "${SHELLS[@]}"; do
    check_case "$1 ($sh)" "$sh" "${@:2}"
  done
}

# --- fixtures ----------------------------------------------------------------

# All four keys; values with spaces and a literal $HOME (must not expand).
cat >"$XDG/relay/env" <<'EOF'
RELAY_BACKEND=dropbox
RELAY_ROOT=$HOME/Relay Dir
RELAY_LEGACY_ROOT=/old root
RELAY_DROPBOX_ROOT=/alias root
EOF
each_shell "all keys, spaces + literal \$HOME"

# A preset environment variable wins over the file.
each_shell "preset RELAY_ROOT wins" RELAY_ROOT=/preset-root

# Lines containing a tab or CR are ignored entirely.
printf 'RELAY_BACKEND=onedrive\nRELAY_ROOT=/bad\tvalue\nRELAY_LEGACY_ROOT=/leg\racy\nRELAY_DROPBOX_ROOT=/alias\n' \
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

# No env file at all.
rm -f "$XDG/relay/env"
each_shell "no env file"

# --- literal anchors (bash) ---------------------------------------------------
# Equality with the lib is the parity check; these pin the actual values.
cat >"$XDG/relay/env" <<'EOF'
RELAY_BACKEND=dropbox
RELAY_ROOT=$HOME/Relay Dir
RELAY_LEGACY_ROOT=/old root
RELAY_DROPBOX_ROOT=/alias root
EOF
: >"$err"
run_env bash
# Literal expectation: $HOME must arrive unexpanded.
# shellcheck disable=SC2016
if [ "$out" = 'dropbox|$HOME/Relay Dir|/old root|/alias root' ]; then
  ok "literal: all keys load verbatim"
else
  bad "literal: all keys load verbatim (got '$out')"
fi

printf 'RELAY_BACKEND=onedrive\nRELAY_ROOT=/bad\tvalue\nRELAY_LEGACY_ROOT=/leg\racy\nRELAY_DROPBOX_ROOT=/alias\n' \
  >"$XDG/relay/env"
: >"$err"
run_env bash
if [ "$out" = 'onedrive|<unset>|<unset>|/alias' ]; then
  ok "literal: tab/CR lines ignored"
else
  bad "literal: tab/CR lines ignored (got '$out')"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
