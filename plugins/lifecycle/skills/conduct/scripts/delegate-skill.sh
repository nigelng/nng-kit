#!/usr/bin/env bash
# delegate-skill.sh — locate a delegate skill's SKILL.md for in-session use.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# usage: delegate-skill.sh <skill> [<tool>]
#   <skill> is execute-via-cursor|execute-via-agy|execute-via-devin|review.
#   <tool> is only for `review`: the tool whose reviewer will run; absent or
#   claude-code skips the enabled check.
#
# Root: the first installPath of the delegate@nng-kit entries (an array, one
# per scope/project, taken in order) whose directory holds
# skills/<skill>/SKILL.md, read from
# ${CLAUDE_INSTALLED_PLUGINS:-$HOME/.claude/plugins/installed_plugins.json};
# else the delegate plugin next to this one in the source tree. Missing or
# nonexistent installPaths are skipped. Cache version directories are never
# scanned. A missing, unreadable or malformed installed_plugins.json (or no jq)
# counts as no entries: the jq error is swallowed and the source tree is used.
# The tool must be listed by that root's own `scripts/tiers.sh tools` (a tool
# not listed, including an unknown name, is REFUSEd as disabled); an empty tool
# means no check. jq is required (tiers.sh needs it).
#
# stdout: absolute path of SKILL.md. stderr on success: root=<path> source=<s>.
# Exit: 0 ok; 2 usage error, tiers.sh missing under the root, or tiers.sh
# error; 3 REFUSE (not found/disabled).
set -euo pipefail
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLED="${CLAUDE_INSTALLED_PLUGINS:-${HOME:-}/.claude/plugins/installed_plugins.json}"
ROOT=""
SOURCE=""

usage() {
  echo "usage: delegate-skill.sh execute-via-cursor|execute-via-agy|execute-via-devin" >&2
  echo "       delegate-skill.sh review [<tool>]" >&2
  exit 2
}

refuse() {
  echo "REFUSE: $1: $2" >&2
  exit 3
}

check_args() {
  case "$1" in
    execute-via-cursor | execute-via-agy | execute-via-devin)
      [[ $# -eq 1 ]] || usage
      ;;
    review)
      [[ $# -le 2 ]] || usage
      ;;
    *)
      usage
      ;;
  esac
}

# Print every installPath of delegate@nng-kit, one per line, in file order.
installed_paths() {
  [[ -f "$INSTALLED" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.plugins["delegate@nng-kit"][]?.installPath // empty' "$INSTALLED" 2>/dev/null || true
}

# try_root <dir> <skill> <source>: set ROOT/SOURCE when dir holds the skill.
try_root() {
  local dir=$1 skill=$2 source=$3
  [[ -n "$dir" && -f "$dir/skills/$skill/SKILL.md" ]] || return 1
  ROOT="$(cd "$dir" && pwd -P)"
  SOURCE=$source
}

# try_installed <skill>: first installed entry that holds the skill.
try_installed() {
  local skill=$1 paths path
  paths=$(installed_paths)
  while IFS= read -r path; do
    try_root "$path" "$skill" installed && return 0
  done <<<"$paths"
  return 1
}

locate_root() {
  local skill=$1
  try_installed "$skill" && return 0
  try_root "$SELF_DIR/../../../../delegate" "$skill" tree && return 0
  refuse "$skill" "not found"
}

# Tool whose enabled state gates the skill; empty means no check.
gate_tool() {
  local skill=$1 tool=${2:-}
  case "$skill" in
    execute-via-*) printf '%s\n' "${skill#execute-via-}" ;;
    *) [[ "$tool" == "claude-code" ]] || printf '%s\n' "$tool" ;;
  esac
}

require_enabled() {
  local tool=$1 rc=0 listed
  [[ -n "$tool" ]] || return 0
  if [[ ! -f "$ROOT/scripts/tiers.sh" ]]; then
    echo "delegate-skill.sh: tiers.sh missing under $ROOT" >&2
    exit 2
  fi
  listed=$(bash "$ROOT/scripts/tiers.sh" tools) || rc=$?
  [[ "$rc" -eq 0 ]] || exit 2
  case "
$listed
" in
    *"
$tool
"*) ;;
    *) refuse "$tool" "disabled" ;;
  esac
}

main() {
  [[ $# -ge 1 ]] || usage
  check_args "$@"
  local skill=$1
  locate_root "$skill"
  require_enabled "$(gate_tool "$@")"
  echo "root=$ROOT source=$SOURCE" >&2
  printf '%s/skills/%s/SKILL.md\n' "$ROOT" "$skill"
}

main "$@"
