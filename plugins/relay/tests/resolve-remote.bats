#!/usr/bin/env bats
# relay_resolve_remote: env → backend<TAB>root<TAB>legacy_root<TAB>status.
# Pure function; no fixtures. Each case clears RELAY_* then sets only what it needs.

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/relay-lib.sh
  source "${PLUGIN_ROOT}/scripts/relay-lib.sh"
  unset RELAY_ROOT RELAY_BACKEND RELAY_DROPBOX_ROOT RELAY_LEGACY_ROOT
}

# $1 is the expected TSV line (no trailing newline; bats strips it).
assert_resolve() {
  local expected="$1"
  run relay_resolve_remote
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "RELAY_ROOT set, RELAY_BACKEND unset → dropbox, status on" {
  RELAY_ROOT="/remote/relay"
  assert_resolve $'dropbox\t/remote/relay\t\ton'
}

@test "RELAY_ROOT set, RELAY_BACKEND=dropbox → dropbox, status on" {
  RELAY_ROOT="/remote/relay"
  RELAY_BACKEND="dropbox"
  assert_resolve $'dropbox\t/remote/relay\t\ton'
}

@test "RELAY_ROOT set, RELAY_BACKEND empty → dropbox, status on" {
  RELAY_ROOT="/remote/relay"
  RELAY_BACKEND=""
  assert_resolve $'dropbox\t/remote/relay\t\ton'
}

@test "RELAY_DROPBOX_ROOT only → dropbox, status deprecated-alias" {
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  assert_resolve $'dropbox\t/remote/dropbox-alias\t\tdeprecated-alias'
}

@test "neither RELAY_ROOT nor RELAY_DROPBOX_ROOT → status off" {
  assert_resolve $'\t\t\toff'
}

@test "empty RELAY_ROOT is unset; RELAY_DROPBOX_ROOT still applies" {
  RELAY_ROOT=""
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  assert_resolve $'dropbox\t/remote/dropbox-alias\t\tdeprecated-alias'
}

@test "unknown backend → status unknown-backend, root still printed" {
  RELAY_ROOT="/remote/relay"
  RELAY_BACKEND="s3"
  assert_resolve $'s3\t/remote/relay\t\tunknown-backend'
}

@test "onedrive → status not-implemented, root still printed" {
  RELAY_ROOT="/remote/relay"
  RELAY_BACKEND="onedrive"
  assert_resolve $'onedrive\t/remote/relay\t\tnot-implemented'
}

@test "RELAY_LEGACY_ROOT passes through when it differs from root" {
  RELAY_ROOT="/remote/relay"
  RELAY_LEGACY_ROOT="/remote/legacy"
  assert_resolve $'dropbox\t/remote/relay\t/remote/legacy\ton'
}

@test "RELAY_LEGACY_ROOT passes through on the deprecated alias" {
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  RELAY_LEGACY_ROOT="/remote/legacy"
  assert_resolve $'dropbox\t/remote/dropbox-alias\t/remote/legacy\tdeprecated-alias'
}

@test "RELAY_LEGACY_ROOT passes through when status is off" {
  RELAY_LEGACY_ROOT="/remote/legacy"
  assert_resolve $'\t\t/remote/legacy\toff'
}

@test "RELAY_LEGACY_ROOT ignored when equal to RELAY_ROOT" {
  RELAY_ROOT="/remote/same"
  RELAY_LEGACY_ROOT="/remote/same"
  assert_resolve $'dropbox\t/remote/same\t\ton'
}

@test "RELAY_LEGACY_ROOT ignored when equal to RELAY_DROPBOX_ROOT" {
  RELAY_DROPBOX_ROOT="/remote/same"
  RELAY_LEGACY_ROOT="/remote/same"
  assert_resolve $'dropbox\t/remote/same\t\tdeprecated-alias'
}

@test "both roots set → RELAY_ROOT wins (not deprecated-alias)" {
  RELAY_ROOT="/remote/relay"
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  assert_resolve $'dropbox\t/remote/relay\t\ton'
}

@test "both roots set, explicit backend → RELAY_ROOT wins and names the backend" {
  RELAY_ROOT="/remote/relay"
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  RELAY_BACKEND="onedrive"
  RELAY_LEGACY_ROOT="/remote/legacy"
  assert_resolve $'onedrive\t/remote/relay\t/remote/legacy\tnot-implemented'
}

@test "both roots set, legacy equal to RELAY_ROOT → legacy cleared, dropbox root ignored" {
  RELAY_ROOT="/remote/same"
  RELAY_DROPBOX_ROOT="/remote/dropbox-alias"
  RELAY_LEGACY_ROOT="/remote/same"
  assert_resolve $'dropbox\t/remote/same\t\ton'
}

@test "tab in RELAY_ROOT → invalid-root, both roots empty" {
  RELAY_ROOT=$'/remote/a\tb'
  RELAY_LEGACY_ROOT="/remote/legacy"
  assert_resolve $'dropbox\t\t\tinvalid-root'
}

@test "newline in RELAY_ROOT → invalid-root, both roots empty" {
  RELAY_ROOT=$'/remote/a\nb'
  assert_resolve $'dropbox\t\t\tinvalid-root'
}

@test "tab in RELAY_LEGACY_ROOT → invalid-root, both roots empty" {
  RELAY_ROOT="/remote/relay"
  RELAY_LEGACY_ROOT=$'/remote/old\tx'
  assert_resolve $'dropbox\t\t\tinvalid-root'
}

@test "newline in RELAY_LEGACY_ROOT with status off → invalid-root" {
  RELAY_LEGACY_ROOT=$'/remote/old\nx'
  assert_resolve $'\t\t\tinvalid-root'
}

@test "newline in RELAY_DROPBOX_ROOT alias → invalid-root" {
  RELAY_DROPBOX_ROOT=$'/remote/alias\nx'
  assert_resolve $'dropbox\t\t\tinvalid-root'
}

@test "invalid-root output still splits into exactly four fields" {
  RELAY_ROOT=$'/remote/a\tb'
  run relay_resolve_remote
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 4 ]
}
