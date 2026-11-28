#!/usr/bin/env bash
# tiers.sh — resolve model tier pins from tiers.json.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# Reads tiers.json from its own directory. When the override file
# ${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-$HOME/.config}/nng-kit/tiers.json}
# exists, it is deep-merged over the shipped file (jq '.[0] * .[1]':
# objects merge, arrays replace). KIT_TODAY overrides the date for tests;
# a row or tool is expired when today > until (string compare).
#
# authenv <tool> prints the merged authEnv names, one per line (the
# launchers validate them). runner-tool <runner> prints the tool whose
# reviewRunners lists <runner>; a runner listed by several tools resolves
# to the first in canonical order, the same order `runners` dedupes in.
#
# Exit codes: 0 ok; 2 usage error, unknown tool, unknown tier, missing jq,
# malformed JSON (shipped or override), invalid .conduct schema;
# 3 no usable pin / disabled tool / no tool lists the runner.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPPED="$DIR/tiers.json"
OVERRIDE="${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/nng-kit/tiers.json}"
TODAY="${KIT_TODAY:-}" # resolve fills it; the other commands need no `date`
TIER_NAMES="top-plan top-review top-critique execute mid low"
REGISTRY=""

die() {
  local rc=$1
  shift
  echo "tiers.sh: $*" >&2
  exit "$rc"
}

usage() {
  echo "usage: tiers.sh tools|host|order|delegates|runners|launcher|policy|headless|validate" >&2
  echo "       tiers.sh resolve <tool> <tier> [--role implement|review]" >&2
  echo "       tiers.sh authenv <tool> | runner-tool <runner>" >&2
}

command -v jq >/dev/null 2>&1 || die 2 "jq not found on PATH"
[[ -f "$SHIPPED" ]] || die 2 "registry not found: $SHIPPED"

load_registry() {
  if [[ -f "$OVERRIDE" ]]; then
    if ! REGISTRY=$(jq -s '.[0] * .[1]' "$SHIPPED" "$OVERRIDE"); then
      die 2 "malformed JSON in $SHIPPED or $OVERRIDE"
    fi
  else
    if ! REGISTRY=$(jq '.' "$SHIPPED"); then
      die 2 "malformed JSON in $SHIPPED"
    fi
  fi
}

# Shared jq snippet validating .conduct on root object $r.
# shellcheck disable=SC2016 # jq program, not shell expansion
CONDUCT_PROBLEMS_JQ='
  if ($r | has("conduct")) | not then empty
  elif ($r.conduct | type) != "object" then "conduct must be an object"
  else
    ($r.conduct) as $c
    | (
        ($c | keys_unsorted[] | . as $k
          | select((["launcher", "defaults", "relax", "headless"] | index($k)) == null)
          | "conduct: unknown key: \($k)"),

        (if ($c | has("launcher"))
            and (($c.launcher | type) != "string"
                 or (($c.launcher | test("^[a-z][a-z0-9-]*$")) | not))
          then "conduct.launcher must match ^[a-z][a-z0-9-]*$"
          else empty end),

        (if ($c | has("defaults")) | not then empty
          elif ($c.defaults | type) != "object" then "conduct.defaults must be an object"
          else
            ($c.defaults) as $d
            | (
                ($d | keys_unsorted[] | . as $k
                  | select((["finish", "delegate", "plan", "confirm", "continue"] | index($k)) == null)
                  | "conduct.defaults: unknown key: \($k)"),
                (if ($d | has("finish"))
                    and (($d.finish | type) != "string"
                         or ((["push", "pr", "commit", "none"] | index($d.finish)) == null))
                  then "conduct.defaults.finish must be push, pr, commit, or none"
                  else empty end),
                (if ($d | has("delegate"))
                    and (($d.delegate | type) != "string"
                         or ((["print", "run"] | index($d.delegate)) == null))
                  then "conduct.defaults.delegate must be print or run"
                  else empty end),
                (if ($d | has("plan"))
                    and (($d.plan | type) != "string"
                         or ((["keep", "drop"] | index($d.plan)) == null))
                  then "conduct.defaults.plan must be keep or drop"
                  else empty end),
                (if ($d | has("confirm"))
                    and (($d.confirm | type) != "string"
                         or ((["yes", "no"] | index($d.confirm)) == null))
                  then "conduct.defaults.confirm must be yes or no"
                  else empty end),
                (if ($d | has("continue"))
                    and (($d.continue | type) != "string"
                         or ((["here", "fresh", "unattended"] | index($d.continue)) == null))
                  then "conduct.defaults.continue must be here, fresh, or unattended"
                  else empty end)
              )
          end),

        (if ($c | has("headless")) | not then empty
          elif ($c.headless | type) != "object" then "conduct.headless must be an object"
          else
            ($c.headless) as $h
            | (
                ($h | keys_unsorted[] | . as $k
                  | select((["timeoutMinutes", "permissionMode", "notify"] | index($k)) == null)
                  | "conduct.headless: unknown key: \($k)"),
                (if ($h | has("timeoutMinutes"))
                    and (($h.timeoutMinutes | type) != "number"
                         or ($h.timeoutMinutes | isnan)
                         or ($h.timeoutMinutes | isinfinite)
                         or (($h.timeoutMinutes | floor) != $h.timeoutMinutes)
                         or $h.timeoutMinutes < 1
                         or $h.timeoutMinutes > 1440)
                  then "conduct.headless.timeoutMinutes must be an integer between 1 and 1440"
                  else empty end),
                (if ($h | has("permissionMode"))
                    and (($h.permissionMode | type) != "string"
                         or ((["auto", "acceptEdits", "default"] | index($h.permissionMode)) == null))
                  then "conduct.headless.permissionMode must be auto, acceptEdits, or default"
                  else empty end),
                (if ($h | has("notify")) | not then empty
                  elif ($h.notify | type) != "array"
                    then "conduct.headless.notify must be a non-empty array"
                  elif ($h.notify | length) == 0
                    then "conduct.headless.notify must be non-empty"
                  else
                    ($h.notify | to_entries[]
                      | select((.value | type) != "string" or (.value | length) == 0)
                      | "conduct.headless.notify[\(.key)] must be a non-empty string"),
                    (if (($h.notify[0] | type) == "string")
                        and (($h.notify[0] | length) > 0)
                        and (($h.notify[0] | startswith("/")) | not)
                      then "conduct.headless.notify[0] must be an absolute path"
                      else empty end)
                  end)
              )
          end),

        (if ($c | has("relax")) | not then empty
          elif ($c.relax | type) != "object" then "conduct.relax must be an object"
          else
            ($c.relax) as $rx
            | (
                ($rx | keys_unsorted[] | . as $k
                  | select((["skipChoicePrompt", "reuseAheadBranch", "executePlanCommit", "unattendedFinish"] | index($k)) == null)
                  | "conduct.relax: unknown key: \($k)"),
                (["skipChoicePrompt", "reuseAheadBranch", "executePlanCommit"][] as $bk
                  | if ($rx | has($bk)) and (($rx[$bk] | type) != "boolean")
                    then "conduct.relax.\($bk) must be a boolean"
                    else empty end),
                (if ($rx | has("unattendedFinish")) | not then empty
                  elif ($rx.unattendedFinish | type) != "array"
                    then "conduct.relax.unattendedFinish must be a non-empty array"
                  elif ($rx.unattendedFinish | length) == 0
                    then "conduct.relax.unattendedFinish must be non-empty"
                  else
                    ($rx.unattendedFinish[] | . as $v
                      | select(($v | type) != "string" or ((["pr", "push", "commit"] | index($v)) == null))
                      | "conduct.relax.unattendedFinish: invalid value \($v | tojson)"),
                    (if (($rx.unattendedFinish | unique | length) != ($rx.unattendedFinish | length))
                      then "conduct.relax.unattendedFinish must not contain duplicates"
                      else empty end)
                  end)
              )
          end)
      )
  end
'

# Canonical tool order: planningOrder first, then any other tool ids in
# document (key) order. Emitted as a jq snippet used by several commands.
# shellcheck disable=SC2016 # jq program, not shell expansion
TOOL_ORDER='(($r.planningOrder // []) + ((($r.tools // {}) | keys_unsorted) - ($r.planningOrder // [])))'

cmd_tools() {
  jq -r ". as \$r | ${TOOL_ORDER}[] as \$t
    | select((\$r.tools[\$t].enabled // false) == true) | \$t" <<<"$REGISTRY"
}

cmd_host() {
  jq -r '.host // empty' <<<"$REGISTRY"
}

cmd_order() {
  jq -r '. as $r | ($r.planningOrder // [])[] as $t
    | select(($r.tools[$t].enabled // false) == true) | $t' <<<"$REGISTRY"
}

cmd_delegates() {
  jq -r ". as \$r | ${TOOL_ORDER}[] as \$t
    | select((\$r.tools[\$t].delegate // false) == true) | \$t" <<<"$REGISTRY"
}

cmd_runners() {
  jq -r ". as \$r
    | [ ${TOOL_ORDER}[] as \$t | ((\$r.tools[\$t].reviewRunners // {}) | keys_unsorted[]) ]
    | reduce .[] as \$x ([]; if index(\$x) == null then . + [\$x] else . end)
    | .[] | select(. != \"session\") | \"top@\(.)\"" <<<"$REGISTRY"
}

require_tool() {
  jq -e --arg t "$1" '.tools | has($t)' <<<"$REGISTRY" >/dev/null \
    || die 2 "unknown tool: $1"
}

cmd_authenv() {
  require_tool "$1"
  jq -r --arg t "$1" '(.tools[$t].authEnv // [])[]' <<<"$REGISTRY"
}

cmd_runner_tool() {
  local tool
  tool=$(jq -r --arg x "$1" ". as \$r | [ ${TOOL_ORDER}[] as \$t
    | select((\$r.tools[\$t].reviewRunners // {}) | has(\$x)) | \$t ] | .[0] // empty" <<<"$REGISTRY")
  [[ -n "$tool" ]] || die 3 "no tool lists review runner: $1"
  printf '%s\n' "$tool"
}

# resolve_tier <tool> <tier> <role> — tool must exist. Prints the first
# usable model on stdout and returns 0; expired candidates are logged to
# stderr. execute falls through to mid --role implement, low to mid with
# the same role, each logging "fallback: <tier>→mid"; mid and top-*
# return 3 when no candidate is usable.
resolve_tier() {
  local tool=$1 tier=$2 role=$3
  local enabled tuntil texp rows status model

  enabled=$(jq -r --arg t "$tool" '.tools[$t].enabled // false' <<<"$REGISTRY")
  [[ "$enabled" == "true" ]] || return 3

  texp=false
  tuntil=$(jq -r --arg t "$tool" '.tools[$t].until // ""' <<<"$REGISTRY")
  if [[ -n "$tuntil" && "$TODAY" > "$tuntil" ]]; then
    texp=true
  fi

  if ! rows=$(jq -r \
      --arg t "$tool" --arg tier "$tier" --arg role "$role" \
      --arg today "$TODAY" --argjson texp "$texp" '
    (.tools[$t].tiers[$tier]) as $rows
    | if ($rows | type) != "array" then error("tiers[" + $tier + "] is not an array") else $rows end
    | .[]
    | select((has("role") | not) or .role == $role)
    | select($role != "review" or .model != "auto")
    | if ($texp or (((.until // "") != "") and ($today > .until)))
      then "expired\t\(.model)"
      else "pin\t\(.model)"
      end
  ' <<<"$REGISTRY"); then
    die 2 "malformed registry rows for $tool/$tier"
  fi

  while IFS=$'\t' read -r status model; do
    [[ -z "$status" ]] && continue
    if [[ "$status" == "expired" ]]; then
      echo "fallback: expired $model" >&2
      continue
    fi
    printf '%s\n' "$model"
    return 0
  done <<<"$rows"

  case "$tier" in
    execute)
      echo "fallback: execute→mid" >&2
      resolve_tier "$tool" mid implement
      ;;
    low)
      echo "fallback: low→mid" >&2
      resolve_tier "$tool" mid "$role"
      ;;
    *)
      return 3
      ;;
  esac
}

cmd_resolve() {
  local tool=$1 tier=$2
  shift 2
  local role=implement
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        [[ $# -ge 2 ]] || die 2 "--role needs implement or review"
        role=$2
        shift 2
        ;;
      --role=*)
        role=${1#--role=}
        shift
        ;;
      *)
        die 2 "unknown resolve argument: $1"
        ;;
    esac
  done
  [[ "$role" == "implement" || "$role" == "review" ]] || die 2 "--role must be implement or review"
  case " $TIER_NAMES " in
    *" $tier "*) ;;
    *) die 2 "unknown tier: $tier" ;;
  esac
  require_tool "$tool"
  [[ -n "$TODAY" ]] || TODAY=$(date +%F)

  resolve_tier "$tool" "$tier" "$role"
}

validate_conduct_json() {
  local problems
  if ! problems=$(jq -r ". as \$r | ${CONDUCT_PROBLEMS_JQ}"); then
    return 1
  fi
  printf '%s' "$problems"
}

cmd_validate() {
  local problems conduct_problems
  if ! problems=$(jq -r '
    . as $r
    | (.tools // {}) as $tools
    | ($tools | keys_unsorted) as $ids
    | ([$ids[] as $t | (($tools[$t].reviewRunners // {}) | keys_unsorted[])]) as $runnerNames
    | (
        (if (($r.host | type) != "string") or (($ids | index($r.host)) == null)
          then "host is not a known tool id: \($r.host | tojson)" else empty end),

        (($r.planningOrder // [])[] | . as $id
          | select(($ids | index($id)) == null)
          | "planningOrder id is not a tool: \($id)"),

        ($ids[] as $t | ($tools[$t]) as $tool | (
          (["top-plan","top-review","top-critique","execute","mid","low"][] as $k
            | select(($tool.tiers[$k] | type) != "array")
            | "tools.\($t).tiers.\($k): missing or not an array"),

          (if (($tool | has("until"))
               and (($tool.until | type) != "string"
                    or (($tool.until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not)))
            then "tools.\($t).until: must match YYYY-MM-DD" else empty end),

          (($tool.defaultReviewRunner // null) as $d
            | if (($d != null) and (($runnerNames | index($d)) == null))
              then "tools.\($t).defaultReviewRunner is not a reviewRunner: \($d)" else empty end),

          (($tool.tiers // {}) | to_entries[]
            | select(.value | type == "array")
            | .key as $k
            | (.value | to_entries[]) | .key as $i | .value as $row
            | if ($row | type) != "object"
              then "tools.\($t).tiers.\($k)[\($i)]: row must be an object"
              else
                (if (($row.model | type) != "string")
                  then "tools.\($t).tiers.\($k)[\($i)].model: must be a string" else empty end),
                (if (($row | has("until"))
                     and (($row.until | type) != "string"
                          or (($row.until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not)))
                  then "tools.\($t).tiers.\($k)[\($i)].until: must match YYYY-MM-DD" else empty end),
                (if (($row | has("role"))
                     and ((["implement","review"] | index($row.role)) == null))
                  then "tools.\($t).tiers.\($k)[\($i)].role: must be implement or review" else empty end)
              end
          )
        ))
      )
  ' <<<"$REGISTRY"); then
    die 2 "validate: could not evaluate registry"
  fi
  if ! conduct_problems=$(validate_conduct_json <<<"$REGISTRY"); then
    die 2 "validate: could not evaluate conduct schema"
  fi
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
  fi
  if [[ -n "$conduct_problems" ]]; then
    printf '%s\n' "$conduct_problems" >&2
  fi
  if [[ -n "$problems" || -n "$conduct_problems" ]]; then
    exit 2
  fi
}

# External pwd -P (via getcwd(3)) returns canonical on-disk casing on
# case-insensitive filesystems (e.g. macOS APFS), unlike bash's builtin pwd -P.
phys_pwd() {
  local out
  out=$(env pwd -P 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Canonicalise a path iteratively without realpath (Bash 3.2 safe).
# Resolves relative paths against phys_pwd, canonicalises parent on each
# symlink hop (max 40 hops), and fails closed (returns 1) on loop or error.
canonicalise_path() {
  local p=$1 hops=0 dir base parent target cwd
  [[ -n "$p" ]] || return 1
  if [[ "$p" != /* ]]; then
    cwd=$(phys_pwd) || return 1
    if [[ "$cwd" == "/" ]]; then p="/$p"; else p="$cwd/$p"; fi
  fi
  while true; do
    while [[ "$p" != "/" && "$p" == */ ]]; do p=${p%/}; done
    [[ "$p" == "/" ]] && break
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    if [[ "$base" == "." || "$base" == ".." ]]; then
      p=$(cd -P -- "$p" 2>/dev/null && phys_pwd) || return 1
      break
    fi
    parent=$(cd -P -- "$dir" 2>/dev/null && phys_pwd) || return 1
    if [[ "$parent" == "/" ]]; then p="/$base"; else p="$parent/$base"; fi
    [[ -L "$p" ]] || break
    hops=$((hops + 1))
    [[ "$hops" -le 40 ]] || return 1
    target=$(readlink "$p" 2>/dev/null) || return 1
    [[ -n "$target" ]] || return 1
    if [[ "$target" == /* ]]; then
      p="$target"
    elif [[ "$parent" == "/" ]]; then
      p="/$target"
    else
      p="$parent/$target"
    fi
  done
  while [[ "$p" != "/" && "$p" == */ ]]; do p=${p%/}; done
  if [[ "$p" != "/" ]]; then
    if [[ -d "$p" ]]; then
      p=$(cd -P -- "$p" 2>/dev/null && phys_pwd) || return 1
    else
      dir=$(dirname -- "$p")
      base=$(basename -- "$p")
      parent=$(cd -P -- "$dir" 2>/dev/null && phys_pwd) || return 1
      if [[ "$parent" == "/" ]]; then p="/$base"; else p="$parent/$base"; fi
    fi
  fi
  printf '%s\n' "$p"
}

# Returns 0 if $OVERRIDE is inside any candidate git root (or canonicalisation
# or git repo detection fails), 1 if outside all git roots or not inside a git repo.
is_override_in_repo() {
  local canon common git_out git_rc toplevel super wt line r rcanon
  command -v git >/dev/null 2>&1 || return 1
  git_rc=0
  git_out=$(LC_ALL=C git rev-parse --path-format=absolute --git-common-dir 2>&1) || git_rc=$?
  if [[ "$git_rc" -ne 0 ]]; then
    case "$(printf '%s' "$git_out" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
      *"not a git repository"*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  [[ -n "$git_out" ]] || return 0
  common=$git_out

  if ! canon=$(canonicalise_path "$OVERRIDE"); then
    return 0
  fi

  local roots=()
  if toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -n "$toplevel" ]]; then
    roots+=("$toplevel")
  fi
  if super=$(git rev-parse --show-superproject-working-tree 2>/dev/null) && [[ -n "$super" ]]; then
    roots+=("$super")
  fi
  if [[ -n "$common" ]]; then
    roots+=("$common")
    if [[ "$(basename -- "$common")" == ".git" ]]; then
      roots+=("$(dirname -- "$common")")
    fi
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt=${line#"worktree "}
        [[ -n "$wt" ]] && roots+=("$wt")
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null || true)

  for r in ${roots[@]+"${roots[@]}"}; do
    if rcanon=$(cd -P -- "$r" 2>/dev/null && phys_pwd); then
      if [[ "$rcanon" == "/" ]]; then
        [[ "$canon" == /* ]] && return 0
      elif [[ "$canon" == "$rcanon" || "$canon" == "$rcanon"/* ]]; then
        return 0
      fi
    fi
  done
  return 1
}

print_policy_json() {
  local source=$1 defaults_json=$2 relax_json=$3
  jq -cn \
    --arg source "$source" \
    --argjson defaults "$defaults_json" \
    --argjson raw_relax "$relax_json" '
    ({
      skipChoicePrompt: false,
      reuseAheadBranch: false,
      executePlanCommit: false,
      unattendedFinish: ["pr"]
    } + $raw_relax) as $relax
    | ([
        (if $relax.skipChoicePrompt then "skipChoicePrompt" else empty end),
        (if $relax.reuseAheadBranch then "reuseAheadBranch" else empty end),
        (if $relax.executePlanCommit then "executePlanCommit" else empty end),
        (if ($relax.unattendedFinish | sort) != ["pr"] then "unattendedFinish" else empty end)
      ] | sort) as $relaxed
    | {
        defaults: $defaults,
        relax: $relax,
        relaxed: $relaxed,
        source: $source
      }
  '
}

# Loads and validates $OVERRIDE exclusively (never $SHIPPED) for conduct
# commands (`policy`, `launcher`, `headless`). Sets OVERRIDE_STATUS to "absent",
# "in-repo", or "loaded" (with OVERRIDE_JSON populated). Exits 2 on
# malformed JSON, non-object JSON, or invalid .conduct schema.
load_conduct_override() {
  OVERRIDE_STATUS=""
  OVERRIDE_JSON=""

  if [[ ! -e "$OVERRIDE" && ! -L "$OVERRIDE" ]]; then
    OVERRIDE_STATUS="absent"
    return 0
  fi

  if is_override_in_repo; then
    echo "tiers.sh: ignoring in-repo override: $OVERRIDE" >&2
    OVERRIDE_STATUS="in-repo"
    return 0
  fi

  if [[ ! -f "$OVERRIDE" ]]; then
    OVERRIDE_STATUS="absent"
    return 0
  fi

  local override_type problems
  if ! OVERRIDE_JSON=$(jq '.' "$OVERRIDE" 2>/dev/null); then
    die 2 "malformed JSON in $OVERRIDE"
  fi
  override_type=$(jq -r 'type' <<<"$OVERRIDE_JSON")
  if [[ "$override_type" != "object" ]]; then
    die 2 "override must be a JSON object: $OVERRIDE"
  fi

  if ! problems=$(validate_conduct_json <<<"$OVERRIDE_JSON"); then
    die 2 "validate: could not evaluate conduct policy in $OVERRIDE"
  fi
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    exit 2
  fi

  OVERRIDE_STATUS="loaded"
}

cmd_launcher() {
  load_conduct_override
  if [[ "$OVERRIDE_STATUS" != "loaded" ]]; then
    printf '%s\n' "print"
    return 0
  fi
  jq -r '.conduct.launcher // "print"' <<<"$OVERRIDE_JSON"
}

cmd_policy() {
  load_conduct_override
  case "$OVERRIDE_STATUS" in
    absent)
      print_policy_json "shipped" "{}" "{}"
      return 0
      ;;
    in-repo)
      print_policy_json "ignored:in-repo" "{}" "{}"
      return 0
      ;;
  esac

  local defaults_json relax_json
  defaults_json=$(jq -c '.conduct.defaults // {}' <<<"$OVERRIDE_JSON")
  relax_json=$(jq -c '.conduct.relax // {}' <<<"$OVERRIDE_JSON")
  print_policy_json "$OVERRIDE" "$defaults_json" "$relax_json"
}

print_headless_json() {
  local source=$1 headless_json=$2
  jq -cn \
    --arg source "$source" \
    --argjson raw_headless "$headless_json" '
    ({
      timeoutMinutes: 120,
      permissionMode: "auto",
      notify: null
    } + $raw_headless)
    | . + { source: $source }
  '
}

cmd_headless() {
  load_conduct_override
  case "$OVERRIDE_STATUS" in
    absent)
      print_headless_json "shipped" "{}"
      return 0
      ;;
    in-repo)
      print_headless_json "ignored:in-repo" "{}"
      return 0
      ;;
  esac

  local headless_json
  headless_json=$(jq -c '.conduct.headless // {}' <<<"$OVERRIDE_JSON")
  print_headless_json "$OVERRIDE" "$headless_json"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local cmd=$1
  shift
  case "$cmd" in
    policy)
      [[ $# -eq 0 ]] || { usage; exit 2; }
      cmd_policy
      ;;
    launcher)
      [[ $# -eq 0 ]] || { usage; exit 2; }
      cmd_launcher
      ;;
    headless)
      [[ $# -eq 0 ]] || { usage; exit 2; }
      cmd_headless
      ;;
    tools | host | order | delegates | runners | validate)
      [[ $# -eq 0 ]] || { usage; exit 2; }
      load_registry
      "cmd_$cmd"
      ;;
    resolve)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      load_registry
      cmd_resolve "$@"
      ;;
    authenv)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      load_registry
      cmd_authenv "$1"
      ;;
    runner-tool)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      load_registry
      cmd_runner_tool "$1"
      ;;
    *)
      echo "tiers.sh: unknown subcommand: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
