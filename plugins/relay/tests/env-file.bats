#!/usr/bin/env bats
# relay_load_env_file tests (scripts/relay-lib.sh).
# Each case sources the lib in a subshell so exported vars cannot leak.

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="${PLUGIN_ROOT}/scripts/relay-lib.sh"
  ENVFILE="${BATS_TEST_TMPDIR}/relay-env"
}

# Run relay_load_env_file in a clean subshell and print the four relay vars
# (empty when unset) plus the function's exit status via a marker line.
load_and_dump() { # <env-file> [extra env assignments...]
  local envfile="$1"
  shift
  env -u RELAY_BACKEND -u RELAY_ROOT -u RELAY_LEGACY_ROOT -u RELAY_DROPBOX_ROOT \
    -u XDG_CONFIG_HOME "$@" bash -c '
      . "$1"
      relay_load_env_file "$2"
      rc=$?
      printf "rc=%s\n" "$rc"
      for k in RELAY_BACKEND RELAY_ROOT RELAY_LEGACY_ROOT RELAY_DROPBOX_ROOT; do
        if [[ -z "${!k+x}" ]]; then printf "%s=<unset>\n" "$k"; else printf "%s=%s\n" "$k" "${!k}"; fi
      done
    ' _ "$LIB" "$envfile"
}

@test "missing file → silent no-op, rc 0" {
  run load_and_dump "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"RELAY_ROOT=<unset>"* ]]
  [[ "$output" == *"RELAY_BACKEND=<unset>"* ]]
}

@test "loads all four keys, comments and blanks skipped" {
  cat >"$ENVFILE" <<'EOF'
# relay settings

RELAY_BACKEND=dropbox
RELAY_ROOT=/srv/relay root
RELAY_LEGACY_ROOT=/srv/old
RELAY_DROPBOX_ROOT=/srv/dbx
EOF
  run load_and_dump "$ENVFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_BACKEND=dropbox"* ]]
  [[ "$output" == *"RELAY_ROOT=/srv/relay root"* ]]
  [[ "$output" == *"RELAY_LEGACY_ROOT=/srv/old"* ]]
  [[ "$output" == *"RELAY_DROPBOX_ROOT=/srv/dbx"* ]]
}

@test "unknown keys and junk lines ignored" {
  cat >"$ENVFILE" <<'EOF'
NOT_A_VAR=1
RELAY_OTHER=/nope
RELAY_STATUS=on
this is not an assignment
=empty-key
RELAY_ROOT=/good
EOF
  run load_and_dump "$ENVFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=/good"* ]]
  [[ "$output" != *"NOT_A_VAR"* ]]
  [[ "$output" != *"RELAY_OTHER"* ]]
  [[ "$output" != *"RELAY_STATUS"* ]]
  [[ "$output" == *"RELAY_BACKEND=<unset>"* ]]
  [[ "$output" == *"RELAY_LEGACY_ROOT=<unset>"* ]]
  [[ "$output" == *"RELAY_DROPBOX_ROOT=<unset>"* ]]
}

@test "pre-set variable is not overridden" {
  cat >"$ENVFILE" <<'EOF'
RELAY_ROOT=/from/file
RELAY_BACKEND=dropbox
EOF
  run load_and_dump "$ENVFILE" "RELAY_ROOT=/from/env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=/from/env"* ]]
  [[ "$output" != *"RELAY_ROOT=/from/file"* ]]
  [[ "$output" == *"RELAY_BACKEND=dropbox"* ]]
}

@test "value with spaces kept verbatim; \$HOME not expanded" {
  cat >"$ENVFILE" <<'EOF'
RELAY_ROOT=/data/my relay/files
RELAY_LEGACY_ROOT=$HOME/legacy dir
EOF
  run load_and_dump "$ENVFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=/data/my relay/files"* ]]
  [[ "$output" == *'RELAY_LEGACY_ROOT=$HOME/legacy dir'* ]]
  # $HOME must not have been expanded into the value.
  [[ "$output" != *"RELAY_LEGACY_ROOT=${HOME}"* ]]
}

@test "quotes are not stripped; export-prefixed lines ignored" {
  cat >"$ENVFILE" <<'EOF'
export RELAY_ROOT=/exported
RELAY_BACKEND="dropbox"
'RELAY_LEGACY_ROOT'=/single
RELAY_DROPBOX_ROOT=/plain
EOF
  run load_and_dump "$ENVFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'RELAY_BACKEND="dropbox"'* ]]
  [[ "$output" == *"RELAY_DROPBOX_ROOT=/plain"* ]]
  [[ "$output" == *"RELAY_ROOT=<unset>"* ]]
  [[ "$output" == *"RELAY_LEGACY_ROOT=<unset>"* ]]
}

@test "value containing tab or CR rejected" {
  printf 'RELAY_ROOT=/a\tb\nRELAY_BACKEND=dropbox\nRELAY_LEGACY_ROOT=/c\rd\n' >"$ENVFILE"
  run load_and_dump "$ENVFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=<unset>"* ]]
  [[ "$output" == *"RELAY_BACKEND=dropbox"* ]]
  [[ "$output" == *"RELAY_LEGACY_ROOT=<unset>"* ]]
}

@test "default path honours XDG_CONFIG_HOME" {
  xdg="${BATS_TEST_TMPDIR}/xdg"
  mkdir -p "$xdg/relay"
  printf 'RELAY_ROOT=/xdg/root\n' >"$xdg/relay/env"
  run env -u RELAY_BACKEND -u RELAY_ROOT -u RELAY_LEGACY_ROOT -u RELAY_DROPBOX_ROOT \
    XDG_CONFIG_HOME="$xdg" bash -c '
      . "$1"
      relay_load_env_file
      printf "RELAY_ROOT=%s\n" "${RELAY_ROOT-<unset>}"
    ' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=/xdg/root"* ]]
}

@test "missing default file under XDG_CONFIG_HOME → no-op" {
  run env -u RELAY_BACKEND -u RELAY_ROOT -u RELAY_LEGACY_ROOT -u RELAY_DROPBOX_ROOT \
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/no-xdg" bash -c '
      . "$1"
      relay_load_env_file
      printf "rc-ok RELAY_ROOT=%s\n" "${RELAY_ROOT-<unset>}"
    ' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELAY_ROOT=<unset>"* ]]
}
