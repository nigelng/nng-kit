#!/usr/bin/env bash
# delegate-usage.sh — sum token usage over delegate run files.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# Usage: delegate-usage.sh <backend> <repo-root> <n> [<n>...]
#
# backend is cursor, agy or devin; <n> are launch numbers. Reads the same
# run files delegate-verdict.sh uses:
#   cursor/agy: <repo-root>/.claude/tmp/exec-run-<backend>-<n>.ndjson
#   devin:     <repo-root>/.claude/tmp/exec-run-<backend>-<n>.json
#
# Prints one JSON object on stdout:
#   {"tokens_in":N|null,"tokens_cached":N|null,"tokens_out":N|null}
# summed over the given launches. tokens_in is uncached input, tokens_cached
# is cache reads, tokens_out is output as reported (reasoning/thinking not
# added). If any launch lacks a field (missing file, no result line,
# non-integer value) that field is null for the total — never undercount.
# Exit 0 even when fields are null; 2 on usage error.
set -euo pipefail

usage() {
  echo "usage: delegate-usage.sh <backend> <repo-root> <n> [<n>...]" >&2
}

if [[ $# -lt 3 ]]; then
  usage
  exit 2
fi

backend=$1
root=$2
shift 2

case "$backend" in
  cursor | agy | devin) ;;
  *)
    usage
    exit 2
    ;;
esac

case "$root" in
  /*) ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -d "$root" ]]; then
  usage
  exit 2
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

for n in "$@"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    usage
    exit 2
  fi
done

num_def='def num: if type == "number" and . >= 0 and . == floor then . else null end;'
null_obj='{"tokens_in":null,"tokens_cached":null,"tokens_out":null}'

launch_json() {
  local backend=$1 file=$2 out
  case "$backend" in
    cursor)
      out=$(tail -n 1 "$file" 2>/dev/null | jq -c "
        $num_def
        select(.type == \"result\") |
        (if (.usage | type) == \"object\" then .usage else {} end) as \$u |
        {tokens_in: (\$u.inputTokens | num),
         tokens_cached: (\$u.cacheReadTokens | num),
         tokens_out: (\$u.outputTokens | num)}" 2>/dev/null) || out=""
      ;;
    agy)
      out=$(jq -c "
        $num_def
        select(.event == \"result\") |
        (if (.result | type) == \"object\" then .result else {} end) as \$r |
        (if (\$r.usage | type) == \"object\" then \$r.usage else {} end) as \$u |
        {tokens_in: (\$u.input_tokens | num),
         tokens_cached: (\$u.cache_read_tokens | num),
         tokens_out: (\$u.output_tokens | num)}" "$file" 2>/dev/null | tail -n 1) || out=""
      ;;
    devin)
      out=$(jq -c "
        $num_def
        (if (.final_metrics | type) == \"object\" then .final_metrics else {} end) as \$m |
        (\$m.total_prompt_tokens | num) as \$p |
        (\$m.total_cached_tokens | num) as \$c |
        (\$m.total_completion_tokens | num) as \$o |
        {tokens_in: (if \$p == null or \$c == null or (\$p - \$c) < 0 then null else \$p - \$c end),
         tokens_cached: \$c,
         tokens_out: \$o}" "$file" 2>/dev/null) || out=""
      ;;
  esac
  if [[ -z "$out" ]]; then
    printf '%s' "$null_obj"
  else
    printf '%s' "$out"
  fi
}

ext=ndjson
[[ "$backend" == devin ]] && ext=json

for n in "$@"; do
  launch_json "$backend" "$root/.claude/tmp/exec-run-${backend}-${n}.${ext}"
  printf '\n'
done | jq -sc '
  def fld(f):
    [.[] | f] as $v
    | if ([$v[] | select(. == null)] | length) > 0 then null else ($v | add) end;
  {tokens_in: fld(.tokens_in),
   tokens_cached: fld(.tokens_cached),
   tokens_out: fld(.tokens_out)}'
