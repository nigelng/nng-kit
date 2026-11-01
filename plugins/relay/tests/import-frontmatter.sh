#!/usr/bin/env bash
# Fixture harness for the relay legacy-import frontmatter derivation
# (format.md "Legacy import"). The block between the BEGIN/END markers is the
# canonical derivation; it is copied byte-identically into the pickup skill.
# Keep it self-contained.

# BEGIN relay_import_frontmatter
relay_import_title() {
  PYTHONIOENCODING=utf-8 python3 -c '
import re, sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
def clean(line):
  t = re.sub(r"^[\s\-#>*\"\x27`\u201c\u201d\u2018\u2019]+", "", line)
  t = t.replace("\"", "").replace("\\", "").replace(":", "\u2014")
  t = re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", t)
  return " ".join(t.split())[:60].strip()
t = next((c for c in map(clean, text.splitlines()) if c), "")
sys.stdout.buffer.write(t.encode("utf-8", "replace"))
'
}

relay_import_title_line() {
  local title
  title="$(printf '%s\n' "$1" | relay_import_title)" || title=""
  [ -n "$title" ] || title="imported handoff"
  printf 'title: "%s"\n' "$title"
}

relay_import_saved_at() {
  local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:?[0-9]{2})$'
  if [[ "$1" =~ $iso ]]; then
    printf '%s\n' "$1"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
# END relay_import_frontmatter

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

PASS=0
FAIL=0
ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "${2:-}" ] || echo "    $2"; }

# Parse the title line as YAML (yq-go) and print the string value.
yaml_title() {
  printf '%s\n' "$1" | nix shell nixpkgs#yq-go -c yq -r '.title'
}

valid_utf8_max60() { # <string>
  printf '%s' "$1" | python3 -c '
import sys
s = sys.stdin.buffer.read().decode("utf-8")
sys.exit(1 if len(s) > 60 else 0)'
}

assert_title() { # <label> <first-body-line> <expected>
  local line got
  line="$(relay_import_title_line "$2")"
  got="$(yaml_title "$line")"
  if [ "$got" != "$3" ]; then
    not_ok "$1" "want [$3] got [$got] from [$line]"
  elif ! valid_utf8_max60 "$got"; then
    not_ok "$1" "title over 60 chars or invalid UTF-8"
  else
    ok "$1"
  fi
}

assert_saved_at_kept() { # <label> <input>
  local got
  got="$(relay_import_saved_at "$2")"
  if [ "$got" = "$2" ]; then ok "$1"; else not_ok "$1" "got [$got]"; fi
}

assert_saved_at_fresh() { # <label> <input>
  local got
  got="$(relay_import_saved_at "$2")"
  if [[ "$got" =~ $ISO ]] && [ "$got" != "$2" ]; then ok "$1"; else not_ok "$1" "got [$got]"; fi
}

long_in="$(python3 -c 'print("é—" * 35)')"
long_out="$(python3 -c 'print("é—" * 30)')"

assert_title "bracket prefix" '[WIP] fix' '[WIP] fix'
assert_title "ampersand" '& x' '& x'
assert_title "at sign" '@x' '@x'
assert_title "hash inside" 'a #b' 'a #b'
assert_title "double quotes" '"q"' 'q'
# shellcheck disable=SC2016
assert_title "backticks" '`code`' 'code`'
assert_title "dashes only" '---' 'imported handoff'
assert_title "empty" '' 'imported handoff'
assert_title "skips rule line" $'---\n[WIP]: finish the parser' '[WIP]— finish the parser'
assert_title "skips several empty-after-sanitising lines" $'***\n> \nreal title' 'real title'
assert_title "only rules" $'---\n***' 'imported handoff'
assert_title "colon" 'a: b' 'a— b'
assert_title "backslash and quote" 'a\b "c"' 'ab c'
assert_title "70 chars with multibyte" "$long_in" "$long_out"

assert_saved_at_kept "valid Z timestamp kept" '2026-10-01T12:00:00Z'
assert_saved_at_kept "valid offset timestamp kept" '2026-10-01T12:00:00+10:00'
assert_saved_at_fresh "garbage replaced" 'garbage'
# shellcheck disable=SC2016
assert_saved_at_fresh "command substitution replaced" '$(x)'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
