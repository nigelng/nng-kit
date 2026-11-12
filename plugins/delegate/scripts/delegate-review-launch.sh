#!/usr/bin/env bash
# delegate-review-launch.sh — review git guard, scope, launch, and verdict.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -euo pipefail

usage() {
  echo "usage: delegate-review-launch.sh snapshot <repo-root> <rid>" >&2
  echo "       delegate-review-launch.sh check <repo-root> <rid>" >&2
  echo "       delegate-review-launch.sh scope <repo-root> <base> <rows-json> <plan>" >&2
  echo "       delegate-review-launch.sh run [--print] <runner> <repo-root> <rid> <model>" >&2
  echo "       delegate-review-launch.sh verdict <repo-root> <rid>" >&2
}

die_usage() {
  usage
  exit 2
}

TMP_INDEX=""
cleanup_tmp() {
  if [[ -n "${TMP_INDEX:-}" ]]; then
    rm -f "$TMP_INDEX"
    TMP_INDEX=""
  fi
}
trap cleanup_tmp EXIT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- clean environment: delegated CLIs run under `env -i` + an allowlist ---
# AGY_CLI_DISABLE_AUTO_UPDATE is a non-secret updater switch (other CLIs ignore it).
# The proxy and CA names are network config needed behind a proxy or a
# TLS-inspecting CA; passed only when set. --print shows names only: values can
# embed proxy credentials.
ENV_BASE_NAMES="HOME PATH USER LOGNAME SHELL TERM LANG LC_ALL LC_CTYPE TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME NIX_PATH NIX_PROFILES NIX_SSL_CERT_FILE SSL_CERT_FILE __CF_USER_TEXT_ENCODING AGY_CLI_DISABLE_AUTO_UPDATE HTTPS_PROXY HTTP_PROXY NO_PROXY ALL_PROXY https_proxy http_proxy no_proxy all_proxy NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE GIT_SSL_CAINFO"

env_name_ok() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Names the registry (shipped file, then the user override) lists as authEnv.
registry_auth_env() {
  local tool=$1 override
  local -a files
  override=${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/nng-kit/tiers.json}
  files=("$DIR/tiers.json")
  if [[ -f "$override" ]]; then
    files+=("$override")
  fi
  jq -s -r --arg t "$tool" \
    'reduce .[] as $x ({}; . * $x) | (.tools[$t].authEnv // [])[]' "${files[@]}"
}

# Names from DELEGATE_ENV_ALLOW (comma-separated); a bad name is a usage error.
extra_allow_env() {
  local list=${DELEGATE_ENV_ALLOW:-}
  [[ -n "$list" ]] || return 0
  [[ "$list" =~ ^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$ ]] || return 1
  printf '%s\n' "${list//,/$'\n'}"
}

# add_env_name <name>: validates one whole name, then records it once.
# Uses seen, env_names and cleanenv from build_clean_env.
add_env_name() {
  local name=$1
  env_name_ok "$name" || return 1
  case "$seen" in *" $name "*) return 0 ;; esac
  seen+="$name "
  if [[ -n "${!name+x}" ]]; then
    env_names+=("$name")
    cleanenv+=("$name=${!name}")
  fi
}

# add_env_lines <text>: one name per line,
# read without word-splitting or globbing; a bad line returns 1.
add_env_lines() {
  local lines=$1 name
  [[ -n "$lines" ]] || return 0
  while IFS= read -r name; do
    add_env_name "$name" || return 1
  done <<<"$lines"
}

# build_clean_env <tool>: sets env_names (allowed names that are set) and
# cleanenv (`env -i NAME=value ...`). Returns 1 on a bad DELEGATE_ENV_ALLOW
# or authEnv name.
build_clean_env() {
  local tool=$1 extra auth seen=" "
  env_names=()
  cleanenv=(env -i)
  extra=$(extra_allow_env) || return 1
  auth=$(registry_auth_env "$tool") || return 1
  add_env_lines "${ENV_BASE_NAMES// /$'\n'}" || return 1
  add_env_lines "$auth" || return 1
  add_env_lines "$extra" || return 1
}

# Names only, never values, so run logs cannot leak a token.
print_clean_env() {
  local name
  printf '%s\n' env -i
  for name in ${env_names[@]+"${env_names[@]}"}; do
    printf '%s=<set>\n' "$name"
  done
}

tool_for_runner() {
  case "$1" in
    cursor-ask) printf 'cursor' ;;
    agy-plan) printf 'agy' ;;
    devin-fusion) printf 'devin' ;;
    claude-headless) printf 'claude-code' ;;
    *) return 1 ;;
  esac
}

validate_root() {
  local root=$1 phys git_top git_phys
  case "$root" in
    /*) ;;
    *) die_usage ;;
  esac
  phys=$(cd "$root" 2>/dev/null && pwd -P) || die_usage
  git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || die_usage
  git_phys=$(cd "$git_top" 2>/dev/null && pwd -P) || die_usage
  if [[ "$phys" != "$git_phys" ]]; then
    die_usage
  fi
  ROOT=$phys
}

validate_rid() {
  [[ "$1" =~ ^(cursor|agy|devin|final)-[0-9]+$ ]] || die_usage
}

snap_path() {
  printf '%s/.claude/tmp/exec-review-%s.snap' "$1" "$2"
}

guard_path() {
  printf '%s/.claude/tmp/exec-review-%s.guard.json' "$1" "$2"
}

brief_path() {
  printf '%s/.claude/tmp/exec-review-%s-brief.md' "$1" "$2"
}

md_path() {
  printf '%s/.claude/tmp/exec-review-%s.md' "$1" "$2"
}

err_path() {
  printf '%s/.claude/tmp/exec-review-%s.err' "$1" "$2"
}

exit_path() {
  printf '%s/.claude/tmp/exec-review-%s.exit' "$1" "$2"
}

current_branch() {
  local b
  if b=$(git symbolic-ref --quiet HEAD 2>/dev/null); then
    printf '%s' "$b"
  else
    printf 'detached'
  fi
}

# `git add` exits 1 when the exclude pathspec names a directory a global
# gitignore already ignores (pattern `tmp/`). The index is still updated.
add_worktree() {
  local index_file=$1 err rc
  err=$(mktemp)
  set +e
  GIT_INDEX_FILE="$index_file" git add -A -- . ':!.claude/tmp' 2>"$err"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    rm -f "$err"
    return 0
  fi
  if [[ $rc -eq 1 ]] && grep -q 'ignored by one of your .gitignore files' "$err"; then
    rm -f "$err"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

capture_work_tree() {
  local index_path tmp work
  index_path=$(git rev-parse --git-path index)
  tmp=$(mktemp)
  TMP_INDEX=$tmp
  cp "$index_path" "$tmp"
  add_worktree "$tmp"
  work=$(GIT_INDEX_FILE="$tmp" git write-tree)
  rm -f "$tmp"
  TMP_INDEX=""
  printf '%s' "$work"
}

read_snap() {
  local file=$1 line
  SNAP_HEAD=""
  SNAP_BRANCH=""
  SNAP_INDEX=""
  SNAP_WORK=""
  [[ -f "$file" ]] || die_usage
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      head=*) SNAP_HEAD=${line#head=} ;;
      branch=*) SNAP_BRANCH=${line#branch=} ;;
      index=*) SNAP_INDEX=${line#index=} ;;
      work=*) SNAP_WORK=${line#work=} ;;
      "") ;;
      *) die_usage ;;
    esac
  done <"$file"
  [[ -n "$SNAP_HEAD" && -n "$SNAP_BRANCH" && -n "$SNAP_INDEX" && -n "$SNAP_WORK" ]] || die_usage
  [[ "$SNAP_HEAD" =~ ^[0-9a-f]{40,64}$ ]] || die_usage
  [[ "$SNAP_INDEX" =~ ^[0-9a-f]{40,64}$ ]] || die_usage
  [[ "$SNAP_WORK" =~ ^[0-9a-f]{40,64}$ ]] || die_usage
  [[ "$SNAP_BRANCH" =~ ^(detached|refs/[^[:cntrl:]]+)$ ]] || die_usage
}

json_bool() {
  if [[ "$1" -eq 1 ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

array_json() {
  local line json='[]'
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  for line in "$@"; do
    json=$(jq -n -c --argjson a "$json" --arg p "$line" '$a + [$p]')
  done
  printf '%s' "$json"
}

cmd_snapshot() {
  local root=$1 rid=$2 head branch index work dest
  validate_rid "$rid"
  validate_root "$root"
  cd "$ROOT"
  mkdir -p .claude/tmp
  head=$(git rev-parse HEAD)
  branch=$(current_branch)
  index=$(git write-tree)
  work=$(capture_work_tree)
  dest=$(snap_path "$ROOT" "$rid")
  {
    printf 'head=%s\n' "$head"
    printf 'branch=%s\n' "$branch"
    printf 'index=%s\n' "$index"
    printf 'work=%s\n' "$work"
  } >"$dest"
}

cmd_check() {
  local root=$1 rid=$2 snap now_head now_branch now_index now_work
  local status path tmp clean head_moved index_restored
  local rev_json rem_json json dest
  local -a reverted=()
  local -a removed=()
  validate_rid "$rid"
  validate_root "$root"
  cd "$ROOT"
  snap=$(snap_path "$ROOT" "$rid")
  read_snap "$snap"
  now_head=$(git rev-parse HEAD)
  now_branch=$(current_branch)
  now_index=$(git write-tree)
  now_work=$(capture_work_tree)

  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in
      A)
        removed+=("$path")
        ;;
      M | D | T)
        reverted+=("$path")
        ;;
    esac
  done < <(git diff -z --no-renames --name-status "$SNAP_WORK" "$now_work")

  if [[ ${#reverted[@]} -gt 0 ]]; then
    tmp=$(mktemp)
    rm -f "$tmp"
    TMP_INDEX=$tmp
    GIT_INDEX_FILE="$tmp" git read-tree "$SNAP_WORK"
    GIT_INDEX_FILE="$tmp" git checkout-index -f -- "${reverted[@]}"
    rm -f "$tmp"
    TMP_INDEX=""
  fi
  if [[ ${#removed[@]} -gt 0 ]]; then
    for path in "${removed[@]}"; do
      rm -f -- "$path"
    done
  fi

  index_restored=0
  if [[ "$now_index" != "$SNAP_INDEX" ]]; then
    git read-tree "$SNAP_INDEX"
    index_restored=1
  fi

  head_moved=0
  if [[ "$now_head" != "$SNAP_HEAD" || "$now_branch" != "$SNAP_BRANCH" ]]; then
    head_moved=1
    printf 'HEAD moved: git log %s..HEAD\n' "$SNAP_HEAD" >&2
  fi

  clean=1
  if [[ $head_moved -eq 1 || $index_restored -eq 1 || ${#reverted[@]} -gt 0 || ${#removed[@]} -gt 0 ]]; then
    clean=0
  fi

  if [[ ${#reverted[@]} -eq 0 ]]; then
    rev_json='[]'
  else
    rev_json=$(array_json "${reverted[@]}")
  fi
  if [[ ${#removed[@]} -eq 0 ]]; then
    rem_json='[]'
  else
    rem_json=$(array_json "${removed[@]}")
  fi
  json=$(jq -n -c \
    --argjson clean "$(json_bool "$clean")" \
    --argjson head_moved "$(json_bool "$head_moved")" \
    --argjson index_restored "$(json_bool "$index_restored")" \
    --argjson reverted "$rev_json" \
    --argjson removed "$rem_json" \
    '{clean:$clean,head_moved:$head_moved,index_restored:$index_restored,reverted:$reverted,removed:$removed}')
  mkdir -p .claude/tmp
  dest=$(guard_path "$ROOT" "$rid")
  printf '%s\n' "$json" >"$dest"
  printf '%s\n' "$json"
}

is_review_tmp() {
  case "$1" in
    .claude/tmp | .claude/tmp/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_protected() {
  local p base
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  base=${p##*/}
  case "$base" in
    claude.md | agents.md | gemini.md) return 0 ;;
  esac
  case "$p" in
    .cursor/rules | .cursor/rules/*) return 0 ;;
    .agents | .agents/*) return 0 ;;
    .github/workflows | .github/workflows/*) return 0 ;;
    *) return 1 ;;
  esac
}

plan_rel() {
  local plan=$1 root=$2 abs dir base rel
  case "$plan" in
    /*) abs=$plan ;;
    *) abs=$root/$plan ;;
  esac
  if [[ -e "$abs" ]]; then
    dir=$(cd "$(dirname "$abs")" && pwd -P)
    base=$(basename "$abs")
    abs=$dir/$base
  fi
  case "$abs" in
    "$root"/*) rel=${abs#"$root"/} ;;
    *) rel=$plan ;;
  esac
  while [[ "$rel" == ./* ]]; do
    rel=${rel#./}
  done
  printf '%s' "$rel"
}

has_line() {
  local blob=$1 p=$2 line
  [[ -n "$blob" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$p" ]] && return 0
  done <<< "$blob"
  return 1
}

blob_json() {
  local blob=$1
  if [[ -z "$blob" ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$blob" | jq -Rsc 'split("\n") | map(select(length>0)) | unique'
}

load_rows_spec() {
  local spec=$1
  if [[ -f "$spec" ]]; then
    ROWS_SPEC=$(cat "$spec")
  else
    ROWS_SPEC=$spec
  fi
  if ! jq -e 'type == "object" and (.map == null or (.map | type) == "string") and (.files_union == null or (.files_union | type) == "array")' \
    >/dev/null <<<"$ROWS_SPEC"; then
    die_usage
  fi
}

cmd_scope() {
  local root=$1 base=$2 rows=$3 plan=$4
  local mapkind plan_rel_path union_blob p
  local seen_blob="" outside_blob="" protected_blob="" untracked_blob=""
  local outside_json protected_json untracked_json
  validate_root "$root"
  cd "$ROOT"
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || die_usage
  [[ -n "$plan" ]] || die_usage
  load_rows_spec "$rows"
  mapkind=$(jq -r '.map // ""' <<<"$ROWS_SPEC")
  union_blob=$(jq -r '(.files_union // [])[]' <<<"$ROWS_SPEC")
  plan_rel_path=$(plan_rel "$plan" "$ROOT")

  consider() {
    local path=$1 untracked=$2
    [[ -n "$path" ]] || return 0
    is_review_tmp "$path" && return 0
    [[ "$path" == "$plan_rel_path" ]] && return 0
    if has_line "$seen_blob" "$path"; then
      return 0
    fi
    if [[ -n "$seen_blob" ]]; then
      seen_blob+=$'\n'"$path"
    else
      seen_blob=$path
    fi
    if [[ "$untracked" -eq 1 ]]; then
      if [[ -n "$untracked_blob" ]]; then
        untracked_blob+=$'\n'"$path"
      else
        untracked_blob=$path
      fi
    fi
    if is_protected "$path"; then
      if [[ -n "$protected_blob" ]]; then
        protected_blob+=$'\n'"$path"
      else
        protected_blob=$path
      fi
    fi
    if [[ "$mapkind" == v2 ]]; then
      if ! has_line "$union_blob" "$path"; then
        if [[ -n "$outside_blob" ]]; then
          outside_blob+=$'\n'"$path"
        else
          outside_blob=$path
        fi
      fi
    fi
  }

  while IFS= read -r -d '' p; do
    consider "$p" 0
  done < <(git diff --name-only -z "$base" -- || true)

  while IFS= read -r -d '' p; do
    consider "$p" 1
  done < <(git ls-files --others --exclude-standard -z || true)

  if [[ "$mapkind" == v2 ]]; then
    outside_json=$(blob_json "$outside_blob")
  else
    outside_json='[]'
  fi
  protected_json=$(blob_json "$protected_blob")
  untracked_json=$(blob_json "$untracked_blob")
  jq -n -c \
    --argjson outside "$outside_json" \
    --argjson protected "$protected_json" \
    --argjson untracked "$untracked_json" \
    '{outside:$outside,protected:$protected,untracked:$untracked}'
}

review_prompt() {
  printf 'Read .claude/tmp/exec-review-%s-brief.md and follow it exactly. Do not edit any file.' "$1"
}

build_review_argv() {
  local runner=$1 root=$2 rid=$3 model=$4 prompt
  prompt=$(review_prompt "$rid")
  argv=()
  # cursor, agy and devin cannot disable MCP per run, so no MCP flag is added
  # for them; see the delegate README threat model. Only claude-headless
  # drops MCP (--strict-mcp-config), unless DELEGATE_MCP=1.
  case "$runner" in
    cursor-ask)
      argv=(
        agent -p --mode=ask --trust --workspace "$root"
        --output-format text --model "$model"
        "$prompt"
      )
      ;;
    agy-plan)
      argv=(
        agy --mode plan --output-format text --model "$model"
        -p "$prompt"
      )
      ;;
    devin-fusion)
      argv=(
        devin --model "$model" --permission-mode auto
        --respect-workspace-trust=false
        "--print=${prompt}"
      )
      ;;
    claude-headless)
      argv=(
        claude -p --model "$model" --effort medium
        --permission-mode plan --tools Read,Grep,Glob,Bash
        --output-format text
      )
      [[ "${DELEGATE_MCP:-}" == 1 ]] || argv+=(--strict-mcp-config)
      argv+=("$prompt")
      ;;
  esac
}

cmd_run() {
  local print=0
  if [[ "${1:-}" == "--print" ]]; then
    print=1
    shift
  fi
  [[ $# -eq 4 ]] || die_usage
  local runner=$1 root=$2 rid=$3 model=$4 ceiling timeout_bin caf
  local outfile errfile exitfile rc t brief runners_out
  if ! runners_out=$(bash "$DIR/tiers.sh" runners); then
    printf 'REFUSE: tiers.sh runners failed (%s)\n' "$DIR/tiers.sh" >&2
    exit 2
  fi
  if ! grep -qxF "top@$runner" <<<"$runners_out"; then
    die_usage
  fi
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ && "$model" != -* ]] || die_usage
  case "$runner" in
    devin-fusion)
      [[ "$model" == fusion-* ]] || die_usage
      ;;
    *)
      if [[ "$model" == fusion-* ]]; then
        die_usage
      fi
      ;;
  esac
  validate_rid "$rid"
  validate_root "$root"
  if [[ -n "${DELEGATE_REVIEW_TIMEOUT+x}" ]]; then
    if [[ ! "$DELEGATE_REVIEW_TIMEOUT" =~ ^[0-9]+[smh]$ ]]; then
      die_usage
    fi
    ceiling=$DELEGATE_REVIEW_TIMEOUT
  else
    ceiling=30m
  fi
  build_review_argv "$runner" "$root" "$rid" "$model"
  [[ ${#argv[@]} -gt 0 ]] || die_usage
  build_clean_env "$(tool_for_runner "$runner")" || die_usage
  if [[ "$print" -eq 1 ]]; then
    print_clean_env
    for t in "${argv[@]}"; do
      printf '%s\n' "$t"
    done
    return 0
  fi
  brief=$(brief_path "$ROOT" "$rid")
  [[ -f "$brief" ]] || die_usage

  cmd_snapshot "$root" "$rid"
  cd "$ROOT"
  mkdir -p .claude/tmp

  timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=$(command -v timeout)
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=$(command -v gtimeout)
  fi

  caf=""
  if command -v caffeinate >/dev/null 2>&1; then
    caf=$(command -v caffeinate)
  fi

  outfile=$(md_path "$ROOT" "$rid")
  errfile=$(err_path "$ROOT" "$rid")
  exitfile=$(exit_path "$ROOT" "$rid")

  set +e
  if [[ -n "$timeout_bin" ]]; then
    if [[ -n "$caf" ]]; then
      "$caf" -i "$timeout_bin" --kill-after=2m "$ceiling" "${cleanenv[@]}" "${argv[@]}" >"$outfile" 2>"$errfile"
    else
      "$timeout_bin" --kill-after=2m "$ceiling" "${cleanenv[@]}" "${argv[@]}" >"$outfile" 2>"$errfile"
    fi
  else
    printf '%s\n' "WARN: no timeout binary; running without ceiling" >&2
    if [[ -n "$caf" ]]; then
      "$caf" -i "${cleanenv[@]}" "${argv[@]}" >"$outfile" 2>"$errfile"
    else
      "${cleanenv[@]}" "${argv[@]}" >"$outfile" 2>"$errfile"
    fi
  fi
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$exitfile"
  cmd_check "$root" "$rid"
}

parse_review_md() {
  local file=$1 line
  local findings_re='^FINDINGS: blocking=([0-9]+) important=([0-9]+) nit=([0-9]+)$'
  local verdict_re='^VERDICT: (PASS|FIX|FAIL)$'
  BLOCKING=0
  IMPORTANT=0
  NIT=0
  VERDICT_WORD=""
  FINDINGS_SEEN=0
  VERDICT_SEEN=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    if [[ "$line" =~ $findings_re ]]; then
      BLOCKING=$((10#${BASH_REMATCH[1]}))
      IMPORTANT=$((10#${BASH_REMATCH[2]}))
      NIT=$((10#${BASH_REMATCH[3]}))
      FINDINGS_SEEN=1
    elif [[ "$line" =~ $verdict_re ]]; then
      VERDICT_WORD=${BASH_REMATCH[1]}
      VERDICT_SEEN=1
    fi
  done <"$file"
}

cmd_verdict() {
  local root=$1 rid=$2 md guard exitfile clean exit_code
  local guard_clean_bit timed_out ok reasons_json verdict_json
  local -a reasons
  reasons=()
  validate_rid "$rid"
  validate_root "$root"
  cd "$ROOT"
  md=$(md_path "$ROOT" "$rid")
  guard=$(guard_path "$ROOT" "$rid")
  exitfile=$(exit_path "$ROOT" "$rid")
  [[ -f "$md" && -f "$guard" ]] || die_usage
  clean=$(jq -r 'if .clean == true then "true" elif .clean == false then "false" else "bad" end' "$guard" 2>/dev/null) || die_usage
  case "$clean" in
    true | false) ;;
    *) die_usage ;;
  esac

  timed_out=0
  if [[ -f "$exitfile" ]]; then
    exit_code=$(tr -d '[:space:]' <"$exitfile" || true)
    if [[ -n "$exit_code" && "$exit_code" != 0 ]]; then
      reasons+=("exit ${exit_code}")
    fi
    case "$exit_code" in
      124 | 137)
        timed_out=1
        reasons+=("timeout ceiling")
        ;;
    esac
  fi

  if [[ "$clean" == true ]]; then
    guard_clean_bit=1
  else
    guard_clean_bit=0
    reasons+=("guard tripped")
  fi

  parse_review_md "$md"
  if [[ "$FINDINGS_SEEN" -eq 0 || "$VERDICT_SEEN" -eq 0 ]]; then
    reasons+=("no verdict line")
  else
    case "$VERDICT_WORD" in
      PASS)
        if [[ $((BLOCKING + IMPORTANT)) -gt 0 ]]; then
          reasons+=("inconsistent verdict")
        fi
        ;;
      FIX | FAIL)
        if [[ $((BLOCKING + IMPORTANT)) -eq 0 ]]; then
          reasons+=("inconsistent verdict")
        fi
        ;;
    esac
  fi

  if [[ ${#reasons[@]} -eq 0 ]]; then
    ok=1
    reasons_json='[]'
  else
    ok=0
    reasons_json=$(array_json "${reasons[@]}")
  fi
  if [[ "$VERDICT_SEEN" -eq 1 ]]; then
    verdict_json=$(jq -Rn --arg v "$VERDICT_WORD" '$v')
  else
    verdict_json=null
  fi
  jq -n -c \
    --argjson ok "$(json_bool "$ok")" \
    --argjson verdict "$verdict_json" \
    --argjson blocking "$BLOCKING" \
    --argjson important "$IMPORTANT" \
    --argjson nit "$NIT" \
    --argjson timed_out "$(json_bool "$timed_out")" \
    --argjson guard_clean "$(json_bool "$guard_clean_bit")" \
    --argjson reasons "$reasons_json" \
    '{ok:$ok,verdict:$verdict,blocking:$blocking,important:$important,nit:$nit,timed_out:$timed_out,guard_clean:$guard_clean,reasons:$reasons}'
}

main() {
  local cmd=${1:-}
  if [[ -z "$cmd" ]]; then
    die_usage
  fi
  shift
  case "$cmd" in
    snapshot)
      [[ $# -eq 2 ]] || die_usage
      cmd_snapshot "$1" "$2"
      ;;
    check)
      [[ $# -eq 2 ]] || die_usage
      cmd_check "$1" "$2"
      ;;
    scope)
      [[ $# -eq 4 ]] || die_usage
      cmd_scope "$1" "$2" "$3" "$4"
      ;;
    run)
      cmd_run "$@"
      ;;
    verdict)
      [[ $# -eq 2 ]] || die_usage
      cmd_verdict "$1" "$2"
      ;;
    *)
      die_usage
      ;;
  esac
}

main "$@"
