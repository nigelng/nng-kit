#!/usr/bin/env bash
# status.sh — record unattended /conduct run markers and terminal status files.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# usage:
#   status.sh write --status <pr-opened|pushed|committed|stopped|failed>
#                   [--stage <preflight|execute|critique|finish>]
#                   [--reason <text>] [--pr-url <url>]
#                   [--worktree <dir>] [--if-absent]
#   status.sh start [--worktree <dir>]
#
# exit:
#   0 ok
#   2 usage / validation error (nothing written)
#   3 REFUSE (not a git work tree, missing worktree, run id not found, missing jq)
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIERS_SH="$SCRIPT_DIR/../../execute-plan/scripts/tiers.sh"
RUN_ID_TAIL_RE='([0-9]{8}T[0-9]{6}Z-[a-z0-9-]+)$'

WT_ABS=""
RUN_ID=""
META_PLAN=""
META_BASE=""

OPT_STATUS=""
OPT_STAGE=""
OPT_HAS_STAGE=0
OPT_REASON=""
OPT_PR_URL=""
OPT_HAS_PR_URL=0
OPT_WORKTREE="."
OPT_IF_ABSENT=0

usage() {
  echo "usage: status.sh write --status <pr-opened|pushed|committed|stopped|failed> [--stage <preflight|execute|critique|finish>] [--reason <text>] [--pr-url <url>] [--worktree <dir>] [--if-absent]" >&2
  echo "       status.sh start [--worktree <dir>]" >&2
  exit 2
}

die_usage() {
  echo "status.sh: $*" >&2
  exit 2
}

refuse() {
  echo "REFUSE: $*" >&2
  exit 3
}

warn() {
  echo "WARN: $*" >&2
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

resolve_worktree_and_run_id() {
  local wt_arg=${1:-.} inside toplevel base
  [[ -d "$wt_arg" ]] || refuse "worktree directory does not exist: $wt_arg"
  cd -P -- "$wt_arg" 2>/dev/null || refuse "cannot enter worktree: $wt_arg"

  inside=$(git rev-parse --is-inside-work-tree 2>/dev/null || true)
  [[ "$inside" == "true" ]] || refuse "not a git work tree: $wt_arg"

  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not a git work tree: $wt_arg"
  cd -P -- "$toplevel" 2>/dev/null || refuse "cannot enter git toplevel: $toplevel"
  WT_ABS=$(phys_pwd) || refuse "cannot resolve worktree path: $toplevel"

  base=$(basename -- "$WT_ABS")
  if [[ "$base" =~ $RUN_ID_TAIL_RE ]]; then
    RUN_ID=${BASH_REMATCH[1]}
  else
    refuse "run id not found"
  fi
}

parse_start_args() {
  OPT_WORKTREE="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree)
        [[ $# -ge 2 && -n "$2" ]] || usage
        OPT_WORKTREE=$2
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done
}

parse_write_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        [[ $# -ge 2 ]] || usage
        OPT_STATUS=$2
        shift 2
        ;;
      --stage)
        [[ $# -ge 2 ]] || usage
        OPT_STAGE=$2
        OPT_HAS_STAGE=1
        shift 2
        ;;
      --reason)
        [[ $# -ge 2 ]] || usage
        OPT_REASON=$2
        shift 2
        ;;
      --pr-url)
        [[ $# -ge 2 ]] || usage
        OPT_PR_URL=$2
        OPT_HAS_PR_URL=1
        shift 2
        ;;
      --worktree)
        [[ $# -ge 2 && -n "$2" ]] || usage
        OPT_WORKTREE=$2
        shift 2
        ;;
      --if-absent)
        OPT_IF_ABSENT=1
        shift
        ;;
      *)
        usage
        ;;
    esac
  done
}

validate_write_args() {
  case "$OPT_STATUS" in
    pr-opened | pushed | committed | stopped | failed) ;;
    "") die_usage "--status is required" ;;
    *) die_usage "invalid --status: $OPT_STATUS" ;;
  esac

  if [[ "$OPT_HAS_STAGE" -eq 1 ]]; then
    case "$OPT_STAGE" in
      preflight | execute | critique | finish) ;;
      *) die_usage "invalid --stage: $OPT_STAGE" ;;
    esac
  fi

  if [[ "$OPT_HAS_PR_URL" -eq 1 && "$OPT_STATUS" != "pr-opened" ]]; then
    die_usage "--pr-url is allowed only with --status pr-opened"
  fi

  if [[ "$OPT_STATUS" == "pr-opened" && -z "$OPT_PR_URL" ]]; then
    die_usage "--status pr-opened requires non-empty --pr-url"
  fi

  if [[ ("$OPT_STATUS" == "stopped" || "$OPT_STATUS" == "failed") && -z "$OPT_REASON" ]]; then
    die_usage "--status $OPT_STATUS requires non-empty --reason"
  fi
}

read_meta_fields() {
  local meta_file="$WT_ABS/.claude/tmp/conduct-${RUN_ID}.meta.json"
  META_PLAN=""
  META_BASE=""
  [[ -f "$meta_file" ]] || return 0
  META_PLAN=$(jq -r '.plan // empty' "$meta_file" 2>/dev/null || true)
  META_BASE=$(jq -r '.base // empty' "$meta_file" 2>/dev/null || true)
}

derive_commits_json() {
  local base=$1 rev_out
  if [[ -z "$base" ]]; then
    printf 'null\n'
    return 0
  fi
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi
  rev_out=$(git rev-list --reverse "${base}..HEAD" 2>/dev/null || true)
  if [[ -z "$rev_out" ]]; then
    printf 'null\n'
    return 0
  fi
  printf '%s\n' "$rev_out" | jq -R 'select(length > 0)' | jq -cs 'if length == 0 then null else . end'
}

validate_git_state() {
  local branch=$1 commits_json=$2
  case "$OPT_STATUS" in
    pr-opened | pushed | committed)
      [[ -n "$branch" ]] || die_usage "--status $OPT_STATUS requires a branch (HEAD is detached)"
      [[ "$commits_json" != "null" ]] || die_usage "--status $OPT_STATUS requires at least one commit"
      ;;
  esac
}

write_status_atomic() {
  local status_file=$1 branch=$2 commits_json=$3
  local finished_at tmp

  mkdir -p "$(dirname "$status_file")"
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="${status_file}.tmp.$$"

  if jq -cn \
    --arg run_id "$RUN_ID" \
    --arg plan "$META_PLAN" \
    --arg status "$OPT_STATUS" \
    --arg stage "$OPT_STAGE" \
    --arg branch "$branch" \
    --argjson commits "$commits_json" \
    --arg pr_url "$OPT_PR_URL" \
    --arg reason "$OPT_REASON" \
    --arg finished_at "$finished_at" \
    '{
      run_id: $run_id,
      plan: (if $plan == "" then null else $plan end),
      status: $status,
      stage: (if $stage == "" then null else $stage end),
      branch: (if $branch == "" then null else $branch end),
      commits: $commits,
      pr_url: (if $pr_url == "" then null else $pr_url end),
      reason: (if $reason == "" then null else $reason end),
      finished_at: $finished_at
    }' >"$tmp"; then
    mv -f "$tmp" "$status_file"
  else
    rm -f "$tmp"
    exit 1
  fi
}

spawn_detached() {
  if command -v perl >/dev/null 2>&1; then
    if ! perl -MPOSIX -e '
      my $pid = fork();
      exit 1 unless defined $pid;
      exit 0 if $pid > 0;
      POSIX::setsid();
      exec { $ARGV[0] } @ARGV;
      exit 127;
    ' "$@" </dev/null >/dev/null 2>&1; then
      warn "failed to start notify command"
    fi
    return 0
  fi

  if ! (nohup "$@" </dev/null >/dev/null 2>&1 &); then
    warn "failed to start notify command"
  fi
}

run_notify_hook() {
  local status_file=$1 headless_json rc=0 item
  local -a argv=()

  if [[ ! -f "$TIERS_SH" ]]; then
    warn "tiers.sh not found: $TIERS_SH"
    return 0
  fi

  # cwd is already $WT_ABS (tiers.sh in-repo guard checks cwd).
  headless_json=$(bash "$TIERS_SH" headless) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    warn "tiers.sh headless failed (rc=$rc)"
    return 0
  fi

  if ! jq -e '.notify | (type == "array") and (length > 0)' <<<"$headless_json" >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r -d '' item; do
    argv+=("$item")
  done < <(jq -j '.notify[] | ., "\u0000"' <<<"$headless_json" 2>/dev/null)

  if [[ ${#argv[@]} -eq 0 ]]; then
    warn "notify command is empty"
    return 0
  fi

  case "${argv[0]}" in
    /*) ;;
    *)
      warn "notify[0] must be an absolute path: ${argv[0]}"
      return 0
      ;;
  esac

  if [[ ! -x "${argv[0]}" || -d "${argv[0]}" ]]; then
    warn "notify command is not executable: ${argv[0]}"
    return 0
  fi

  argv+=("$status_file")
  spawn_detached "${argv[@]}"
}

cmd_start() {
  parse_start_args "$@"
  resolve_worktree_and_run_id "$OPT_WORKTREE"

  local started_file="$WT_ABS/.claude/tmp/conduct-${RUN_ID}.started"
  [[ ! -e "$started_file" ]] || return 0

  mkdir -p "$WT_ABS/.claude/tmp"
  local ts tmp="${started_file}.tmp.$$"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if printf '%s\n' "$ts" >"$tmp"; then
    mv -f "$tmp" "$started_file"
  else
    rm -f "$tmp"
    exit 1
  fi
}

cmd_write() {
  require_jq
  parse_write_args "$@"
  validate_write_args
  resolve_worktree_and_run_id "$OPT_WORKTREE"

  local status_file="$WT_ABS/.claude/tmp/conduct-${RUN_ID}.json"
  if [[ "$OPT_IF_ABSENT" -eq 1 && -e "$status_file" ]]; then
    return 0
  fi

  read_meta_fields
  local branch commits_json
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
  commits_json=$(derive_commits_json "$META_BASE")

  validate_git_state "$branch" "$commits_json"
  write_status_atomic "$status_file" "$branch" "$commits_json"
  run_notify_hook "$status_file"
}

main() {
  [[ $# -ge 1 ]] || usage
  local sub=$1
  shift
  case "$sub" in
    write) cmd_write "$@" ;;
    start) cmd_start "$@" ;;
    *) usage ;;
  esac
}

main "$@"
