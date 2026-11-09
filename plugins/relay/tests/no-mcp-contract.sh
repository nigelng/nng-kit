#!/usr/bin/env bash
# no-mcp-contract.sh — every `dbxcli` WRITE fallback in the relay skills and
# references must be gated on the Dropbox MCP `create_file` tool being
# available (a partial MCP surface, i.e. Claude Code). Without `create_file`
# remote access is read-only — see references/storage.md § Without the
# Dropbox MCP. Read-only `dbxcli` uses (ls/get) are exempt.
#
# A "block" is a run of non-blank lines (markdown paragraph or table). Any
# block that mentions `dbxcli` together with a dbxcli write subcommand
# (`dbxcli mv`, `dbxcli rm`, `dbxcli mkdir`, `dbxcli put`, `dbxcli upload`,
# `dbxcli cp` — token within a few non-alphanumerics of `dbxcli`) must also
# contain the gate phrase. Prose uses of "put"/"move" are not subcommands.
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Literal gate phrase incl. backticks — must not be shell-expanded.
# shellcheck disable=SC2016
PHRASE='only when the Dropbox MCP `create_file` tool is available'
# dbxcli followed by <=4 non-alphanumerics then a write subcommand word.
WRITE_TOKEN='dbxcli[^a-zA-Z0-9]{0,4}(mv|rm|mkdir|put|upload|cp)([^a-zA-Z0-9]|$)'

fail=0
checked=0
scanned=0

while IFS= read -r f; do
  scanned=$((scanned + 1))
  # awk paragraph mode: each record is a non-blank-line block, RS=""
  while IFS= read -r block; do
    [[ -n "$block" ]] || continue
    if printf '%s\n' "$block" | grep -q 'dbxcli' \
      && printf '%s\n' "$block" | grep -Eq "$WRITE_TOKEN"; then
      checked=$((checked + 1))
      if ! printf '%s\n' "$block" | grep -qF "$PHRASE"; then
        fail=1
        echo "FAIL: $f — dbxcli write without the create_file gate:" >&2
        printf '%s\n' "$block" | grep -n 'dbxcli' | head -3 | sed 's/^/  /' >&2
      fi
    fi
  done < <(awk 'BEGIN{RS=""} {print $0 "\x01"}' "$f")
done < <(find "$KIT/skills" "$KIT/references" -name '*.md' -type f | sort)

if [[ "$fail" -ne 0 ]]; then
  echo "no-mcp-contract: FAILED ($checked gated blocks checked)" >&2
  exit 1
fi
echo "no-mcp-contract: ok ($scanned files, $checked dbxcli-write blocks gated)"
exit 0
