#!/usr/bin/env bash
# relay-lib.sh — shared pure helpers for the relay plugin.
#
# Contract: pure functions only. No `set -e`, no top-level side effects, no
# `exit`. Safe to source into a SessionStart hook that must always exit 0.

# Extract one frontmatter value from between the first two `---` lines.
# Strips surrounding single or double quotes. Prints empty and returns 0 when
# the file or key is missing.
# Usage: relay_get_fm_value <file> <key>
relay_get_fm_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v key="$key" '
    BEGIN { in_fm = 0; fm_count = 0 }
    /^---[[:space:]]*$/ { fm_count++; in_fm = (fm_count == 1); next }
    fm_count >= 2 { exit }
    in_fm {
      pos = index($0, ":")
      if (pos == 0) next
      k = substr($0, 1, pos - 1)
      v = substr($0, pos + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'\'']|["'\'']$/, "", v)
      if (k == key) { print v; exit }
    }
  ' "$file" 2>/dev/null
  return 0
}

# Body text after the closing frontmatter `---`.
# Usage: relay_get_body <file>
relay_get_body() {
  local file="$1"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk '
    BEGIN { fm_count = 0 }
    /^---[[:space:]]*$/ && fm_count < 2 { fm_count++; next }
    fm_count >= 2 { print }
  ' "$file" 2>/dev/null
  return 0
}

# ISO-8601 timestamp → Unix seconds. Prints 0 on empty / unparseable input.
# Tries GNU date, then BSD date forms.
# Usage: relay_iso_to_epoch <iso>
relay_iso_to_epoch() {
  local ts="$1"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] || {
    printf '0'
    return 0
  }
  date -d "$ts" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
    || printf '0'
  return 0
}

# Neutralise untrusted-source tag sequences so interpolated values cannot
# close or open the wrapper early. Case-insensitive; replaces `<` with `&lt;`
# only in `<untrusted-source` and `</untrusted-source` sequences.
# Usage: relay_neutralize_untrusted_tags <text>
# Prints the sanitised text on stdout.
relay_neutralize_untrusted_tags() {
  local text="${1-}"
  # Portable sed (BSD/GNU): spell out case folds; closing pattern first.
  printf '%s' "$text" | sed -E \
    -e 's#</[uU][nN][tT][rR][uU][sS][tT][eE][dD]-[sS][oO][uU][rR][cC][eE]#\&lt;/untrusted-source#g' \
    -e 's#<[uU][nN][tT][rR][uU][sS][tT][eE][dD]-[sS][oO][uU][rR][cC][eE]#\&lt;untrusted-source#g'
  return 0
}

# True (return 0) when sha looks like a hex object id safe for git args.
# Usage: relay_sha_ok <sha> → exit status only; no stdout.
relay_sha_ok() {
  local sha="${1-}"
  [[ "$sha" =~ ^[0-9a-fA-F]{4,40}$ ]]
}

# Branch slug for docs/handoffs/<slug>.md.
# Optional arg: repo path (default: cwd). Detached HEAD → detached-<short-sha>.
# Usage: relay_branch_slug [repo]
relay_branch_slug() {
  local repo="${1:-.}"
  local branch short_sha slug

  if ! command -v git >/dev/null 2>&1; then
    printf ''
    return 0
  fi
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf ''
    return 0
  fi

  branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    short_sha="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
    if [[ -z "$short_sha" ]]; then
      printf ''
      return 0
    fi
    printf 'detached-%s' "$short_sha"
    return 0
  fi

  # `/` → `--`, then any char outside [A-Za-z0-9._-] → `-`.
  slug="$(printf '%s' "$branch" | sed -e 's|/|--|g' -e 's/[^A-Za-z0-9._-]/-/g')"
  printf '%s' "$slug"
  return 0
}
