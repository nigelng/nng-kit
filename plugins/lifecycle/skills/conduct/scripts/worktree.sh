#!/usr/bin/env bash
# worktree.sh — manage sibling worktrees for unattended /conduct runs.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# usage:
#   worktree.sh create <plan>
#   worktree.sh list
#   worktree.sh remove <run-id> [--discard-plan] [--release] [--force]
#
# Exit: 0 ok; 2 usage; 3 REFUSE (prefix stderr with "REFUSE: ").
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXEC_SCRIPTS="$SCRIPT_DIR/../../execute-plan/scripts"

usage() {
  echo "usage: worktree.sh create <plan>" >&2
  echo "       worktree.sh list" >&2
  echo "       worktree.sh remove <run-id> [--discard-plan] [--release] [--force]" >&2
  exit 2
}

refuse() {
  echo "REFUSE: $1" >&2
  exit 3
}

require_jq() {
  command -v jq >/dev/null 2>&1 || refuse "jq not found on PATH"
}

phys_pwd() {
  local out
  out=$(env pwd -P 2>/dev/null || pwd -P)
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Validate that <rel> is a clean repo-relative file path under <root>/docs/plans/
# with no traversal, control characters, or symlink escapes along any component.
validate_plan_rel_in_root() {
  local root=$1 rel=$2
  local root_phys cur rest comp parent_dir parent_phys plans_phys

  [[ -n "$root" && -d "$root" && -n "$rel" ]] || return 1
  case "$rel" in
    *[[:cntrl:]]*) return 1 ;;
    /* | */ | *//*) return 1 ;;
    docs/plans/?*) ;;
    *) return 1 ;;
  esac
  case "/$rel/" in
    */../* | */./*) return 1 ;;
  esac

  root_phys=$(cd -P -- "$root" 2>/dev/null && phys_pwd) || return 1

  cur=$root_phys
  rest=$rel
  while [[ -n "$rest" ]]; do
    case "$rest" in
      */*)
        comp=${rest%%/*}
        rest=${rest#*/}
        ;;
      *)
        comp=$rest
        rest=""
        ;;
    esac
    [[ -n "$comp" ]] || return 1
    cur="$cur/$comp"
    [[ ! -L "$cur" ]] || return 1
    if [[ -n "$rest" ]]; then
      [[ ! -e "$cur" || -d "$cur" ]] || return 1
    else
      [[ ! -e "$cur" || -f "$cur" ]] || return 1
    fi
  done

  if [[ -d "$root_phys/docs/plans" ]]; then
    plans_phys=$(cd -P -- "$root_phys/docs/plans" 2>/dev/null && phys_pwd) || return 1
    [[ "$plans_phys" == "$root_phys/docs/plans" ]] || return 1
  elif [[ -e "$root_phys/docs/plans" ]]; then
    return 1
  fi

  parent_dir=$(dirname -- "$root_phys/$rel")
  if [[ -d "$parent_dir" ]]; then
    parent_phys=$(cd -P -- "$parent_dir" 2>/dev/null && phys_pwd) || return 1
    case "$parent_phys" in
      "$root_phys/docs/plans" | "$root_phys/docs/plans/"*) ;;
      *) return 1 ;;
    esac
  elif [[ -e "$parent_dir" ]]; then
    return 1
  fi

  return 0
}

resolve_main_repo() {
  local line first_wt=""
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    refuse "not inside a git repository"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        first_wt=${line#worktree }
        break
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null || true)
  [[ -n "$first_wt" && -d "$first_wt" ]] ||
    refuse "failed to resolve main repository"
  (cd "$first_wt" && pwd -P)
}

# Normalize <plan> against orig_pwd (then toplevel) to a repo-relative path
# under docs/plans/ and verify it exists as a regular file.
resolve_plan_rel() {
  local raw=$1 orig_pwd=$2 toplevel=$3 cand dir base abs rel
  if [[ "$raw" == /* ]]; then
    cand=$raw
  elif [[ -e "$orig_pwd/$raw" ]]; then
    cand="$orig_pwd/$raw"
  else
    cand="$toplevel/$raw"
  fi
  dir=$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P) ||
    refuse "plan file does not exist: $raw"
  base=$(basename "$cand")
  abs="$dir/$base"
  case "$abs" in
    "$toplevel/"*) rel=${abs#"$toplevel"/} ;;
    *) refuse "plan path is outside repository: $raw" ;;
  esac
  case "$rel" in
    docs/plans/*) ;;
    *) refuse "plan must be under docs/plans/: $rel" ;;
  esac
  [[ -f "$abs" ]] || refuse "plan file does not exist: $rel"
  printf '%s' "$rel"
}

is_allowed_dirty_path() {
  case "$1" in
    docs/plans/* | docs/brainstorms/*) return 0 ;;
    *) return 1 ;;
  esac
}

check_clean_main_tree() {
  local entry xy path orig_path
  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || continue
    xy=${entry:0:2}
    path=${entry:3}
    is_allowed_dirty_path "$path" ||
      refuse "dirty path outside docs/plans/ and docs/brainstorms/: $path"
    case "$xy" in
      R* | C*)
        if IFS= read -r -d '' orig_path; then
          is_allowed_dirty_path "$orig_path" ||
            refuse "dirty path outside docs/plans/ and docs/brainstorms/: $orig_path"
        fi
        ;;
    esac
  done < <(git status --porcelain -z -uall)
}

plan_slug() {
  local base slug
  base=$(basename "$1")
  base=${base%.md}
  if [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.*)$ ]]; then
    base=${BASH_REMATCH[1]}
  fi
  slug=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
  printf '%s' "$slug"
}

copy_into_worktree() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  install -m 0644 "$src" "$dst"
}

write_meta_atomic() {
  local meta_file=$1 run_id=$2 plan_rel=$3 base_sha=$4 origin=$5 tmp
  mkdir -p "$(dirname "$meta_file")"
  tmp="${meta_file}.tmp.$$"
  if jq -cn \
    --arg run_id "$run_id" \
    --arg plan "$plan_rel" \
    --arg base "$base_sha" \
    --arg origin "$origin" \
    '{run_id: $run_id, plan: $plan, base: $base, origin: $origin}' >"$tmp"; then
    mv -f "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    return 1
  fi
}

trim_ws() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

is_pid_running() {
  local pid_file=$1 line pid recorded_lstart live_lstart
  [[ -f "$pid_file" ]] || return 1
  IFS= read -r line <"$pid_file" || true
  line=$(trim_ws "$line")
  [[ -n "$line" ]] || return 1
  case "$line" in
    *[[:space:]]*)
      pid=${line%%[[:space:]]*}
      recorded_lstart=$(trim_ws "${line#"$pid"}")
      ;;
    *)
      return 1
      ;;
  esac
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -n "$recorded_lstart" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  live_lstart=$(ps -o lstart= -p "$pid" 2>/dev/null || true)
  live_lstart=$(trim_ws "$live_lstart")
  [[ -n "$live_lstart" && "$live_lstart" == "$recorded_lstart" ]]
}

worktree_state() {
  local wt=$1 run_id=$2
  local tmp_dir="$wt/.claude/tmp"
  local pid_file="$tmp_dir/conduct-${run_id}.pid"
  local status_file="$tmp_dir/conduct-${run_id}.json"
  local started_file="$tmp_dir/conduct-${run_id}.started"
  local st=""

  if is_pid_running "$pid_file"; then
    printf 'running'
    return 0
  fi

  if [[ -f "$status_file" ]]; then
    st=$(jq -r 'if (.status | type) == "string" and (.status | length) > 0 then .status else empty end' "$status_file" 2>/dev/null || true)
    if [[ -n "$st" ]]; then
      printf '%s' "$st"
      return 0
    fi
    printf 'unknown'
    return 0
  fi

  if [[ -e "$started_file" || -e "$pid_file" ]]; then
    printf 'unknown'
    return 0
  fi

  printf 'created'
}

worktree_branch() {
  local wt=$1 branch
  branch=$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)
  if [[ -n "$branch" ]]; then
    printf '%s' "$branch"
  else
    printf 'detached'
  fi
}

worktree_pr_url() {
  local status_file=$1 pr_url="none"
  if [[ -f "$status_file" ]]; then
    pr_url=$(jq -r 'if (.pr_url | type) == "string" and (.pr_url | length) > 0 then .pr_url else "none" end' "$status_file" 2>/dev/null || printf 'none')
    [[ -n "$pr_url" ]] || pr_url="none"
  fi
  printf '%s' "$pr_url"
}

# Match any git-listed worktree whose basename ends with "-conduct-<run_id>"
# (create names it after the toplevel it ran from, which may be a linked
# worktree). Refuse when more than one listed worktree matches.
find_worktree_for_run_id() {
  local main_repo=$1 run_id=$2
  local suffix line wt wt_abs found=""
  suffix="-conduct-${run_id}"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt=${line#worktree }
        [[ -d "$wt" ]] || continue
        wt_abs=$(cd "$wt" && pwd -P)
        case "$(basename "$wt_abs")" in
          *"$suffix")
            [[ -z "$found" ]] ||
              refuse "multiple worktrees match run_id $run_id: $found and $wt_abs"
            found=$wt_abs
            ;;
        esac
        ;;
    esac
  done < <(git -C "$main_repo" worktree list --porcelain)
  [[ -n "$found" ]] || refuse "worktree not found for run_id: $run_id"
  printf '%s' "$found"
}

# Pick the root whose plan copy create stamped. The meta file is untrusted:
# accept its "origin" only when it is the physical path of a worktree root
# that git itself lists; otherwise fall back to the main repository.
resolve_release_root() {
  local main_repo=$1 origin=$2
  local origin_phys="" line wt wt_abs
  if [[ "$origin" == /* ]]; then
    origin_phys=$(cd -P -- "$origin" 2>/dev/null && pwd -P) || origin_phys=""
  fi
  if [[ -n "$origin_phys" ]]; then
    while IFS= read -r line; do
      case "$line" in
        "worktree "*)
          wt=${line#worktree }
          [[ -d "$wt" ]] || continue
          wt_abs=$(cd -P -- "$wt" && pwd -P)
          if [[ "$wt_abs" == "$origin_phys" ]]; then
            printf '%s' "$origin_phys"
            return 0
          fi
          ;;
      esac
    done < <(git -C "$main_repo" worktree list --porcelain)
  fi
  printf '%s' "$main_repo"
}

execution_status_of() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm == 1 && /^---[[:space:]]*$/ { exit }
    fm == 1 && /^execution:[[:space:]]*$/ { ex = 1; next }
    ex && /^[^[:space:]#]/ { exit }
    ex && /^[[:space:]]+status:[[:space:]]*/ {
      sub(/^[[:space:]]+status:[[:space:]]*/, "")
      gsub(/["'\'']/, "")
      sub(/[[:space:]].*$/, "")
      print
      exit
    }
  ' "$1"
}

is_allowed_worktree_dirty_path() {
  local path=$1 meta_plan=$2 notes_plan=$3 allow_plan=$4
  case "$path" in
    .claude/tmp/*) return 0 ;;
  esac
  if [[ "$allow_plan" -eq 1 && -n "$meta_plan" ]]; then
    if [[ "$path" == "$meta_plan" ]]; then
      return 0
    fi
    if [[ -n "$notes_plan" && "$path" == "$notes_plan" ]]; then
      return 0
    fi
  fi
  return 1
}

check_clean_worktree() {
  local wt=$1 meta_plan=$2 discard_plan=$3
  local notes_plan="" cand_notes="" allow_plan=0 plan_status=""
  local entry xy path orig_path

  if [[ -n "$meta_plan" ]] && ! validate_plan_rel_in_root "$wt" "$meta_plan"; then
    meta_plan=""
  fi

  if [[ -n "$meta_plan" ]]; then
    if [[ "${meta_plan%.md}.notes.md" != "$meta_plan" ]]; then
      cand_notes="${meta_plan%.md}.notes.md"
      if validate_plan_rel_in_root "$wt" "$cand_notes"; then
        notes_plan=$cand_notes
      fi
    fi
    if [[ "$discard_plan" -eq 1 ]]; then
      allow_plan=1
    elif [[ -f "$wt/$meta_plan" && ! -L "$wt/$meta_plan" ]]; then
      plan_status=$(execution_status_of "$wt/$meta_plan")
      if [[ "$plan_status" == "not-started" ]]; then
        allow_plan=1
      fi
    fi
  fi

  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || continue
    xy=${entry:0:2}
    path=${entry:3}
    is_allowed_worktree_dirty_path "$path" "$meta_plan" "$notes_plan" "$allow_plan" ||
      refuse "dirty path in worktree: $path"
    case "$xy" in
      R* | C*)
        if IFS= read -r -d '' orig_path; then
          is_allowed_worktree_dirty_path "$orig_path" "$meta_plan" "$notes_plan" "$allow_plan" ||
            refuse "dirty path in worktree: $orig_path"
        fi
        ;;
    esac
  done < <(git -C "$wt" status --porcelain -z -uall)
}

has_git_commits_past_base() {
  local wt=$1 base=$2 revs
  [[ -n "$base" ]] || return 1
  git -C "$wt" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  revs=$(git -C "$wt" rev-list "${base}..HEAD" 2>/dev/null || true)
  [[ -n "$revs" ]]
}

has_worktree_commits() {
  local wt=$1 base=$2 status_file=$3
  if has_git_commits_past_base "$wt" "$base"; then
    return 0
  fi
  if [[ -f "$status_file" ]] &&
    jq -e '(.commits | type) == "array" and (.commits | length) > 0' "$status_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

rollback_worktree() {
  local toplevel=$1 wt=$2
  git -C "$toplevel" worktree remove --force "$wt" >/dev/null 2>&1 || true
}

cmd_create() {
  local plan_arg=$1 orig_pwd toplevel plan_rel default_ref default ahead
  local slug ts run_id worktree_path worktree_abs notes_rel base_sha meta_file

  require_jq

  orig_pwd=$(pwd -P)
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) ||
    refuse "not inside a git repository"
  toplevel=$(cd "$toplevel" && pwd -P)

  plan_rel=$(resolve_plan_rel "$plan_arg" "$orig_pwd" "$toplevel")
  cd "$toplevel"

  default_ref=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default_ref#origin/}
  [[ -n "$default" ]] || refuse "refs/remotes/origin/HEAD is unset"

  git fetch --quiet origin "$default" >/dev/null 2>&1 ||
    refuse "git fetch origin $default failed"
  ahead=$(git rev-list --count "origin/${default}..HEAD" 2>/dev/null) ||
    refuse "failed to count commits ahead of origin/$default"
  if [[ ! "$ahead" =~ ^[0-9]+$ ]] || [[ "$ahead" -gt 0 ]]; then
    refuse "HEAD has $ahead commit(s) ahead of origin/$default"
  fi

  check_clean_main_tree

  slug=$(plan_slug "$plan_rel")
  [[ -n "$slug" ]] || refuse "empty plan slug for $plan_rel"

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  run_id="${ts}-${slug}"
  worktree_path="$(dirname "$toplevel")/$(basename "$toplevel")-conduct-${run_id}"
  if [[ -e "$worktree_path" || -L "$worktree_path" ]]; then
    refuse "worktree path already exists: $worktree_path"
  fi

  base_sha=$(git rev-parse HEAD 2>/dev/null) ||
    refuse "failed to resolve HEAD"

  git worktree add --quiet --detach "$worktree_path" HEAD >/dev/null ||
    refuse "git worktree add failed"
  worktree_abs=$(cd "$worktree_path" && pwd -P)

  if ! copy_into_worktree "$toplevel/$plan_rel" "$worktree_abs/$plan_rel"; then
    rollback_worktree "$toplevel" "$worktree_abs"
    refuse "failed to copy plan into worktree"
  fi
  notes_rel="${plan_rel%.md}.notes.md"
  if [[ "$notes_rel" != "$plan_rel" && -f "$toplevel/$notes_rel" ]]; then
    if ! copy_into_worktree "$toplevel/$notes_rel" "$worktree_abs/$notes_rel"; then
      rollback_worktree "$toplevel" "$worktree_abs"
      refuse "failed to copy notes into worktree"
    fi
  fi

  meta_file="$worktree_abs/.claude/tmp/conduct-${run_id}.meta.json"
  if ! write_meta_atomic "$meta_file" "$run_id" "$plan_rel" "$base_sha" "$toplevel"; then
    rollback_worktree "$toplevel" "$worktree_abs"
    refuse "failed to write meta file"
  fi

  if ! bash "$EXEC_SCRIPTS/plan-status.sh" handoff "$toplevel/$plan_rel" "$run_id"; then
    rollback_worktree "$toplevel" "$worktree_abs"
    exit 3
  fi

  printf 'run_id=%s  worktree=%s  plan=%s\n' "$run_id" "$worktree_abs" "$plan_rel"
}

cmd_list() {
  require_jq
  local main_repo line wt wt_abs wt_base run_id
  local state branch pr_url status_file
  local run_id_re='^.*-conduct-([0-9]{8}T[0-9]{6}Z-[a-z0-9-]+)$'

  main_repo=$(resolve_main_repo)

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt=${line#worktree }
        [[ -d "$wt" ]] || continue
        wt_abs=$(cd "$wt" && pwd -P)
        wt_base=$(basename "$wt_abs")
        if [[ "$wt_base" =~ $run_id_re ]]; then
          run_id=${BASH_REMATCH[1]}
          state=$(worktree_state "$wt_abs" "$run_id")
          branch=$(worktree_branch "$wt_abs")
          status_file="$wt_abs/.claude/tmp/conduct-${run_id}.json"
          pr_url=$(worktree_pr_url "$status_file")
          printf 'run_id=%s state=%s branch=%s pr_url=%s worktree=%s\n' \
            "$run_id" "$state" "$branch" "$pr_url" "$wt_abs"
        fi
        ;;
    esac
  done < <(git -C "$main_repo" worktree list --porcelain)
}

cmd_remove() {
  local run_id="" discard_plan=0 release=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --discard-plan) discard_plan=1; shift ;;
      --release) release=1; shift ;;
      --force) force=1; shift ;;
      -*) usage ;;
      *)
        [[ -z "$run_id" ]] || usage
        run_id=$1
        shift
        ;;
    esac
  done
  [[ -n "$run_id" ]] || usage

  require_jq
  local main_repo wt state meta_file status_file release_root meta_origin=""
  local meta_plan="" meta_base="" status_plan="" release_plan="" has_commits=0

  main_repo=$(resolve_main_repo)
  wt=$(find_worktree_for_run_id "$main_repo" "$run_id")
  state=$(worktree_state "$wt" "$run_id")

  if [[ "$force" -eq 0 && ( "$state" == "running" || "$state" == "unknown" ) ]]; then
    refuse "worktree $run_id is in state '$state' (use --force to override)"
  fi

  meta_file="$wt/.claude/tmp/conduct-${run_id}.meta.json"
  status_file="$wt/.claude/tmp/conduct-${run_id}.json"
  if [[ -f "$meta_file" ]]; then
    meta_plan=$(jq -r 'if (.plan | type) == "string" then .plan else empty end' "$meta_file" 2>/dev/null || true)
    meta_base=$(jq -r 'if (.base | type) == "string" then .base else empty end' "$meta_file" 2>/dev/null || true)
    meta_origin=$(jq -r 'if (.origin | type) == "string" then .origin else empty end' "$meta_file" 2>/dev/null || true)
  fi
  if [[ -f "$status_file" ]]; then
    status_plan=$(jq -r 'if (.plan | type) == "string" then .plan else empty end' "$status_file" 2>/dev/null || true)
  fi

  check_clean_worktree "$wt" "$meta_plan" "$discard_plan"

  if ! git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
    if has_git_commits_past_base "$wt" "$meta_base"; then
      refuse "worktree $run_id has detached HEAD with commits past base"
    fi
  fi

  if has_worktree_commits "$wt" "$meta_base" "$status_file"; then
    has_commits=1
  fi

  git -C "$main_repo" worktree remove --force "$wt" >/dev/null ||
    refuse "git worktree remove failed for $wt"

  if [[ "$has_commits" -eq 0 || "$release" -eq 1 ]]; then
    release_plan=""
    release_root=$(resolve_release_root "$main_repo" "$meta_origin")
    if [[ -n "$meta_plan" ]] && validate_plan_rel_in_root "$release_root" "$meta_plan"; then
      release_plan=$meta_plan
    elif [[ -n "$status_plan" ]] && validate_plan_rel_in_root "$release_root" "$status_plan"; then
      release_plan=$status_plan
    fi
    if [[ -n "$release_plan" && -f "$release_root/$release_plan" && ! -L "$release_root/$release_plan" ]]; then
      if ! bash "$EXEC_SCRIPTS/plan-status.sh" handoff --clear "$release_root/$release_plan" "$run_id"; then
        exit 3
      fi
    fi
  fi
}

main() {
  [[ $# -ge 1 ]] || usage
  local sub=$1
  shift
  case "$sub" in
    create)
      [[ $# -eq 1 && -n "$1" ]] || usage
      cmd_create "$1"
      ;;
    list)
      [[ $# -eq 0 ]] || usage
      cmd_list
      ;;
    remove)
      cmd_remove "$@"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
