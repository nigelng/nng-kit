#!/usr/bin/env bash
# launch.sh — launch or probe an unattended /conduct worker session.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
#
# usage:
#   launch.sh <launcher> --worktree <path> --model <id> --cmd <slash command> --run-id <id> [--log-dir <dir>]
#   launch.sh probe headless --model <id>
#
# stdout:
#   print:    copy-pasteable `cd ... && claude --model ... ...` and `handle=print`
#   headless: `handle=pid:<n>`
#
# exit:
#   0 ok
#   2 usage (bad/missing args, invalid --run-id/--worktree/--cmd, worktree/run-id mismatch)
#   3 REFUSE (unknown/unavailable launcher, missing/mismatched probe marker,
#             disallowed permission mode, invalid .conduct override,
#             invalid timeout override, missing claude/jq, probe failed)
#   4 INELIGIBLE (worker command or worktree plan fails unattended eligibility)
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXEC_SCRIPTS="$SCRIPT_DIR/../../execute-plan/scripts"
TIERS_SH="$EXEC_SCRIPTS/tiers.sh"
PLAN_STATUS_SH="$EXEC_SCRIPTS/plan-status.sh"
STATUS_SH="$SCRIPT_DIR/status.sh"

RUN_ID_RE='^[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+$'

HEADLESS_TIMEOUT_MIN=120
HEADLESS_PERM_MODE="auto"

usage() {
  echo "usage: launch.sh <launcher> --worktree <path> --model <id> --cmd <slash command> --run-id <id> [--log-dir <dir>]" >&2
  echo "       launch.sh probe headless --model <id>" >&2
  exit 2
}

refuse() {
  echo "REFUSE: $1: $2" >&2
  exit 3
}

ineligible() {
  echo "INELIGIBLE: $1" >&2
  exit 4
}

trim_ws() {
  local s=$1
  while case "$s" in [[:space:]]*) true ;; *) false ;; esac; do
    s=${s#?}
  done
  while case "$s" in *[[:space:]]) true ;; *) false ;; esac; do
    s=${s%?}
  done
  printf '%s' "$s"
}

phys_pwd() {
  local out
  out=$(env pwd -P 2>/dev/null || pwd -P)
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

read_headless_config() {
  local cwd=$1 json="" rc=0 t p
  HEADLESS_TIMEOUT_MIN=120
  HEADLESS_PERM_MODE="auto"
  [[ -f "$TIERS_SH" ]] || return 0

  json=$(cd "$cwd" && bash "$TIERS_SH" headless) || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    refuse "config" "invalid .conduct override (tiers.sh headless exit 2)"
  fi
  if [[ "$rc" -ne 0 || -z "$json" ]]; then
    echo "WARN: tiers.sh headless failed (rc=$rc); using defaults (timeoutMinutes=120, permissionMode=auto)" >&2
    return 0
  fi

  t=$(jq -r '.timeoutMinutes // 120' <<<"$json" 2>/dev/null || printf '120')
  p=$(jq -r '.permissionMode // "auto"' <<<"$json" 2>/dev/null || printf 'auto')
  if [[ "$t" =~ ^[0-9]+$ && "$t" -ge 1 && "$t" -le 1440 ]]; then
    HEADLESS_TIMEOUT_MIN=$t
  fi
  case "$p" in
    auto | acceptEdits | default) HEADLESS_PERM_MODE=$p ;;
  esac
}

resolve_permission_mode() {
  local cfg_mode=${1:-auto} mode
  if [[ -n "${NNG_KIT_HEADLESS_PERMISSION_MODE:-}" ]]; then
    mode=$NNG_KIT_HEADLESS_PERMISSION_MODE
  else
    mode=$cfg_mode
  fi
  case "$mode" in
    auto | acceptEdits | default) printf '%s\n' "$mode" ;;
    *) refuse "permission-mode" "disallowed permission mode '$mode' (allowed: auto, acceptEdits, default)" ;;
  esac
}

require_tools() {
  command -v claude >/dev/null 2>&1 || refuse "claude" "not found on PATH"
  command -v jq >/dev/null 2>&1 || refuse "jq" "not found on PATH"
}

get_claude_version() {
  local ver
  ver=$(claude --version 2>/dev/null | head -n 1 || true)
  ver=$(trim_ws "$ver")
  [[ -n "$ver" ]] || refuse "claude" "failed to read claude --version"
  printf '%s\n' "$ver"
}

probe_marker_path() {
  local state_home="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
  printf '%s/nng-kit/headless-probe.json\n' "$state_home"
}

allowed_unattended_finish() {
  local worktree_abs=$1 policy_json="" policy_rc=0 list=""
  if [[ -f "$TIERS_SH" ]]; then
    policy_json=$(cd "$worktree_abs" && bash "$TIERS_SH" policy) || policy_rc=$?
  else
    policy_rc=2
  fi
  if [[ "$policy_rc" -eq 0 && -n "$policy_json" ]]; then
    list=$(jq -r '.relax.unattendedFinish // ["pr"] | .[]' <<<"$policy_json" 2>/dev/null || true)
  fi
  if [[ -z "$list" ]]; then
    printf 'pr\n'
  else
    printf '%s\n' "$list"
  fi
}

check_plan_path_in_worktree() {
  local worktree_abs=$1 plan=$2 plan_cand plan_dir plan_base plan_abs
  case "$plan" in
    /*) ineligible "plan path must be repo-relative under docs/plans/: $plan" ;;
    docs/plans/?*) ;;
    *) ineligible "plan path must be under docs/plans/: $plan" ;;
  esac
  case "/$plan/" in
    */../*) ineligible "plan path must not contain '..': $plan" ;;
  esac

  plan_cand="$worktree_abs/$plan"
  [[ -f "$plan_cand" ]] || ineligible "plan file does not exist in worktree: $plan"
  [[ ! -L "$plan_cand" ]] || ineligible "plan file must not be a symlink: $plan"

  plan_dir=$(cd -P -- "$(dirname -- "$plan_cand")" 2>/dev/null && phys_pwd) ||
    ineligible "cannot resolve plan directory: $plan"
  plan_base=$(basename -- "$plan_cand")
  plan_abs="$plan_dir/$plan_base"
  case "$plan_abs" in
    "$worktree_abs/docs/plans/"*) ;;
    *) ineligible "plan path resolves outside docs/plans/: $plan" ;;
  esac
}

check_eligibility() {
  local worktree_abs=$1 cmd=$2
  case "$cmd" in
    *$'\n'* | *$'\r'*) ineligible "command must be a single line" ;;
  esac

  local -a tokens=()
  IFS=$' \t' read -r -a tokens <<<"$cmd" || true
  if [[ ${#tokens[@]} -lt 2 || "${tokens[0]}" != "/conduct" ]]; then
    ineligible "command must start with '/conduct <plan>'"
  fi

  local plan="${tokens[1]}"
  local seen_unattended=0 seen_delegate=0 seen_confirm=0 seen_plan=0 seen_finish=0
  local val_unattended="" val_delegate="" val_confirm="" val_plan="" val_finish=""
  local i tok
  for ((i = 2; i < ${#tokens[@]}; i++)); do
    tok=${tokens[$i]}
    case "$tok" in
      unattended=*)
        [[ "$seen_unattended" -eq 0 ]] || ineligible "duplicate unattended= argument"
        seen_unattended=1
        val_unattended=${tok#unattended=}
        ;;
      delegate=*)
        [[ "$seen_delegate" -eq 0 ]] || ineligible "duplicate delegate= argument"
        seen_delegate=1
        val_delegate=${tok#delegate=}
        ;;
      confirm=*)
        [[ "$seen_confirm" -eq 0 ]] || ineligible "duplicate confirm= argument"
        seen_confirm=1
        val_confirm=${tok#confirm=}
        ;;
      plan=*)
        [[ "$seen_plan" -eq 0 ]] || ineligible "duplicate plan= argument"
        seen_plan=1
        val_plan=${tok#plan=}
        ;;
      finish=*)
        [[ "$seen_finish" -eq 0 ]] || ineligible "duplicate finish= argument"
        seen_finish=1
        val_finish=${tok#finish=}
        ;;
    esac
  done

  [[ "$seen_unattended" -eq 1 && "$val_unattended" == "yes" ]] ||
    ineligible "command must include unattended=yes"
  [[ "$seen_delegate" -eq 1 && "$val_delegate" == "print" ]] ||
    ineligible "command must include delegate=print"
  [[ "$seen_confirm" -eq 1 && "$val_confirm" == "no" ]] ||
    ineligible "command must include confirm=no"
  case "$val_plan" in
    keep | drop) ;;
    *) ineligible "command must include plan=keep or plan=drop" ;;
  esac
  [[ "$seen_finish" -eq 1 && -n "$val_finish" ]] ||
    ineligible "command must include finish=<mode>"

  local allowed_list allowed_item finish_ok=0
  allowed_list=$(allowed_unattended_finish "$worktree_abs")
  while IFS= read -r allowed_item; do
    [[ -n "$allowed_item" ]] || continue
    if [[ "$allowed_item" == "$val_finish" ]]; then
      finish_ok=1
      break
    fi
  done <<<"$allowed_list"
  if [[ "$finish_ok" -ne 1 ]]; then
    ineligible "finish=$val_finish is not allowed by unattendedFinish policy"
  fi

  check_plan_path_in_worktree "$worktree_abs" "$plan"

  [[ -f "$PLAN_STATUS_SH" ]] || ineligible "plan-status.sh not found: $PLAN_STATUS_SH"

  if ! (cd "$worktree_abs" && bash "$PLAN_STATUS_SH" lock --gate "$plan" >/dev/null 2>&1); then
    ineligible "plan failed lock --gate: $plan"
  fi

  local lint_out="" lint_rc=0
  lint_out=$(cd "$worktree_abs" && bash "$PLAN_STATUS_SH" rows --lint "$plan" 2>/dev/null) || lint_rc=$?
  if [[ "$lint_rc" -ne 0 || "$(trim_ws "$lint_out")" != "ok" ]]; then
    ineligible "plan failed rows --lint: $plan"
  fi

  local runners_out="" runners_rc=0 row_id row_runner
  runners_out=$(cd "$worktree_abs" && bash "$PLAN_STATUS_SH" rows --runners "$plan" 2>/dev/null) || runners_rc=$?
  if [[ "$runners_rc" -ne 0 ]]; then
    ineligible "plan failed rows --runners: $plan"
  fi
  while IFS=$'\t' read -r row_id row_runner; do
    [[ -n "$row_id" ]] || continue
    case "$row_runner" in
      delegate:*)
        ineligible "plan contains unsupported delegate runner ($row_id: $row_runner)"
        ;;
    esac
  done <<<"$runners_out"
}

probe_headless() {
  local model=$1 perm_mode claude_ver marker prompt probe_out probe_rc trimmed at tmp
  require_tools
  read_headless_config "."
  perm_mode=$(resolve_permission_mode "$HEADLESS_PERM_MODE")
  claude_ver=$(get_claude_version)
  marker=$(probe_marker_path)

  prompt="Call the advisor tool once now. If the advisor tool is available and returns, reply with the exact single token ADVISOR_OK and nothing else. If the advisor tool is absent or unavailable, reply with the exact single token ADVISOR_MISSING and nothing else."

  probe_rc=0
  probe_out=$(claude -p --model "$model" --permission-mode "$perm_mode" --output-format text "$prompt" 2>/dev/null) || probe_rc=$?
  trimmed=$(trim_ws "$probe_out")

  if [[ "$probe_rc" -ne 0 || "$trimmed" != "ADVISOR_OK" ]]; then
    refuse "probe" "advisor probe failed (rc=$probe_rc, output='$trimmed')"
  fi

  mkdir -p "$(dirname "$marker")"
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="${marker}.tmp.$$"
  jq -n \
    --arg claude_version "$claude_ver" \
    --arg model "$model" \
    --arg permission_mode "$perm_mode" \
    --arg at "$at" \
    '{ok: true, claude_version: $claude_version, model: $model, permission_mode: $permission_mode, at: $at}' >"$tmp"
  mv "$tmp" "$marker"
}

cmd_probe() {
  [[ $# -ge 1 ]] || usage
  local target=$1 model=""
  case "$target" in
    -*) usage ;;
  esac
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        [[ $# -ge 2 ]] || usage
        model=$2
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  [[ -n "$model" ]] || usage

  case "$target" in
    headless)
      probe_headless "$model"
      ;;
    *)
      refuse "$target" "unknown launcher"
      ;;
  esac
}

launch_print() {
  local worktree=$1 model=$2 cmd=$3
  printf 'cd %q && claude --model %q %q\n' "$worktree" "$model" "$cmd"
  printf 'handle=print\n'
}

write_pid_file() {
  local pid_file=$1 pid=$2 lstart tmp
  lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
  tmp="${pid_file}.tmp.$$"
  if [[ -n "$lstart" ]]; then
    printf '%s %s\n' "$pid" "$lstart" >"$tmp"
  else
    printf '%s\n' "$pid" >"$tmp"
  fi
  mv -f "$tmp" "$pid_file"
}

launch_headless() {
  local worktree_abs=$1 model=$2 cmd=$3 run_id=$4 log_dir=$5
  local perm_mode claude_ver marker log_dir_abs log_file status_dir pid_file
  local timeout_secs timeout_label pid watcher_script

  require_tools
  read_headless_config "$worktree_abs"
  perm_mode=$(resolve_permission_mode "$HEADLESS_PERM_MODE")

  if [[ -n "${NNG_KIT_HEADLESS_TIMEOUT_SECONDS:-}" ]]; then
    if [[ ! "$NNG_KIT_HEADLESS_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
      refuse "timeout" "invalid NNG_KIT_HEADLESS_TIMEOUT_SECONDS='$NNG_KIT_HEADLESS_TIMEOUT_SECONDS'"
    fi
    timeout_secs=$NNG_KIT_HEADLESS_TIMEOUT_SECONDS
    timeout_label="${timeout_secs}s"
  else
    timeout_secs=$((HEADLESS_TIMEOUT_MIN * 60))
    timeout_label="${HEADLESS_TIMEOUT_MIN}m"
  fi

  claude_ver=$(get_claude_version)
  marker=$(probe_marker_path)

  if [[ ! -f "$marker" ]]; then
    refuse "headless" "probe marker missing ($marker); run: launch.sh probe headless --model $model"
  fi

  if ! jq -e \
    --arg v "$claude_ver" \
    --arg m "$model" \
    --arg p "$perm_mode" \
    '.ok == true and .claude_version == $v and .model == $m and .permission_mode == $p' \
    "$marker" >/dev/null 2>&1; then
    refuse "headless" "probe marker invalid or mismatched ($marker); re-run: launch.sh probe headless --model $model"
  fi

  mkdir -p "$log_dir"
  log_dir_abs="$(cd "$log_dir" && phys_pwd)"
  status_dir="$worktree_abs/.claude/tmp"
  mkdir -p "$status_dir"

  log_file="$log_dir_abs/conduct-$run_id.log"
  pid_file="$status_dir/conduct-$run_id.pid"

  IFS= read -r -d '' watcher_script <<'EOF' || true
set -u
wt=$1 log=$2 run_id=$3 model=$4 mode=$5 cmd=$6 timeout_secs=$7 timeout_label=$8 status_sh=$9
cd "$wt" || exit 1
timeout_mark="$wt/.claude/tmp/conduct-${run_id}.timeout.$$"
rm -f "$timeout_mark"

has_setsid=0
claude_pid=""
sleeper_pid=""
claude_reaped=0

claude_alive() {
  [ "$claude_reaped" -eq 0 ] && [ -n "$claude_pid" ] || return 1
  if ! kill -0 "$claude_pid" 2>/dev/null; then
    wait "$claude_pid" 2>/dev/null || true
    claude_reaped=1
    return 1
  fi
  st=$(ps -o state= -p "$claude_pid" 2>/dev/null | tr -d '[:space:]' || true)
  case "$st" in
    "" | Z*)
      wait "$claude_pid" 2>/dev/null || true
      claude_reaped=1
      return 1
      ;;
  esac
  return 0
}

group_has_members() {
  [ -n "$claude_pid" ] || return 1
  if claude_alive; then
    return 0
  fi
  if [ "$has_setsid" -eq 1 ] && kill -0 -- "-$claude_pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

terminate_claude_group() {
  [ -n "$claude_pid" ] || return 0
  if ! group_has_members; then
    return 0
  fi
  if [ "$has_setsid" -eq 1 ]; then
    kill -TERM -- "-$claude_pid" 2>/dev/null || true
  fi
  if [ "$claude_reaped" -eq 0 ]; then
    kill -TERM "$claude_pid" 2>/dev/null || true
  fi
  i=0
  while [ "$i" -lt 100 ]; do
    if ! group_has_members; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if group_has_members; then
    if [ "$has_setsid" -eq 1 ]; then
      kill -KILL -- "-$claude_pid" 2>/dev/null || true
    fi
    if [ "$claude_reaped" -eq 0 ]; then
      kill -KILL "$claude_pid" 2>/dev/null || true
      wait "$claude_pid" 2>/dev/null || true
      claude_reaped=1
    fi
    j=0
    while [ "$j" -lt 20 ] && group_has_members; do
      sleep 0.05
      j=$((j + 1))
    done
  fi
}

on_watcher_term() {
  trap '' TERM INT HUP
  if [ -n "$sleeper_pid" ]; then
    kill -TERM "$sleeper_pid" 2>/dev/null || true
    wait "$sleeper_pid" 2>/dev/null || true
  fi
  terminate_claude_group
  if [ "$claude_reaped" -eq 0 ] && [ -n "$claude_pid" ]; then
    wait "$claude_pid" 2>/dev/null || true
    claude_reaped=1
  fi
  rm -f "$timeout_mark"
  bash "$status_sh" write --status failed --reason "watcher terminated" --if-absent --worktree "$wt" >>"$log" 2>&1 || true
  exit 143
}

trap on_watcher_term TERM INT HUP

if command -v perl >/dev/null 2>&1; then
  has_setsid=1
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- \
    claude -p --model "$model" --permission-mode "$mode" "$cmd" >"$log" 2>&1 &
  claude_pid=$!
else
  claude -p --model "$model" --permission-mode "$mode" "$cmd" >"$log" 2>&1 &
  claude_pid=$!
fi

(
  sleep_pid=""
  trap '[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
  sleep "$timeout_secs" &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null || exit 0
  sleep_pid=""
  : >"$timeout_mark"
  if [ "$has_setsid" -eq 1 ]; then
    kill -TERM -- "-$claude_pid" 2>/dev/null || true
    kill -TERM "$claude_pid" 2>/dev/null || true
  else
    kill -TERM "$claude_pid" 2>/dev/null || true
  fi
  i=0
  while [ "$i" -lt 100 ]; do
    if [ "$has_setsid" -eq 1 ]; then
      if ! kill -0 -- "-$claude_pid" 2>/dev/null && ! kill -0 "$claude_pid" 2>/dev/null; then
        break
      fi
    else
      if ! kill -0 "$claude_pid" 2>/dev/null; then
        break
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$has_setsid" -eq 1 ]; then
    kill -KILL -- "-$claude_pid" 2>/dev/null || true
    kill -KILL "$claude_pid" 2>/dev/null || true
  else
    kill -KILL "$claude_pid" 2>/dev/null || true
  fi
) </dev/null >/dev/null 2>&1 &
sleeper_pid=$!

rc=0
wait "$claude_pid" || rc=$?
claude_reaped=1

kill -TERM "$sleeper_pid" 2>/dev/null || true
wait "$sleeper_pid" 2>/dev/null || true
sleeper_pid=""

terminate_claude_group

if [ -f "$timeout_mark" ]; then
  rm -f "$timeout_mark"
  reason="timeout after ${timeout_label}"
else
  reason="session exited ${rc} without status"
fi

bash "$status_sh" write --status failed --reason "$reason" --if-absent --worktree "$wt" >>"$log" 2>&1 || true
EOF

  # Detach the watcher into its own session (macOS has no setsid binary) so a
  # process-group kill of the launching session cannot take it down. A failed
  # setsid still execs the watcher; without perl, fall back to plain nohup.
  # The handle is the watcher's PID (perl and nohup exec in place).
  local -a watcher=(/bin/bash -c "$watcher_script" _
    "$worktree_abs" "$log_file" "$run_id" "$model" "$perm_mode" "$cmd"
    "$timeout_secs" "$timeout_label" "$STATUS_SH")
  if command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- "${watcher[@]}" \
      </dev/null >/dev/null 2>&1 &
  else
    nohup "${watcher[@]}" </dev/null >/dev/null 2>&1 &
  fi
  pid=$!

  write_pid_file "$pid_file" "$pid"
  printf 'handle=pid:%s\n' "$pid"
}

main() {
  [[ $# -ge 1 ]] || usage

  if [[ "$1" == "probe" ]]; then
    shift
    cmd_probe "$@"
    return 0
  fi

  local launcher=$1
  case "$launcher" in
    -*) usage ;;
  esac
  shift

  local worktree="" model="" cmd="" run_id="" log_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree)
        [[ $# -ge 2 ]] || usage
        worktree=$2
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || usage
        model=$2
        shift 2
        ;;
      --cmd)
        [[ $# -ge 2 ]] || usage
        cmd=$2
        shift 2
        ;;
      --run-id)
        [[ $# -ge 2 ]] || usage
        run_id=$2
        shift 2
        ;;
      --log-dir)
        [[ $# -ge 2 ]] || usage
        log_dir=$2
        [[ -n "$log_dir" ]] || usage
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  [[ -n "$worktree" && -d "$worktree" ]] || usage
  [[ -n "$model" ]] || usage
  [[ -n "$cmd" ]] || usage
  case "$cmd" in
    /*) ;;
    *) usage ;;
  esac
  [[ -n "$run_id" && "$run_id" =~ $RUN_ID_RE ]] || usage

  local worktree_abs wt_base
  worktree_abs="$(cd -P -- "$worktree" && phys_pwd)" || usage
  wt_base="$(basename -- "$worktree_abs")"
  case "$wt_base" in
    *"-conduct-$run_id") ;;
    *)
      echo "launch.sh: worktree basename '$wt_base' must end with -conduct-$run_id" >&2
      usage
      ;;
  esac

  if [[ -z "$log_dir" ]]; then
    log_dir="$worktree_abs/.claude/tmp"
  fi

  case "$launcher" in
    print | headless) ;;
    # orca|rex|herdr)
    #   Adapter contract for external terminal/session launchers:
    #   1. Map <launcher> to its native spawn command (e.g. orca/rex/herdr CLI)
    #      operating in $worktree with $model, refusing (exit 3) if the tool
    #      is unavailable or refuses to spawn.
    #   2. Keep $cmd as a single intact argv element (never eval or interpolate
    #      into a shell command string; verify it still starts with '/').
    #   3. Ensure logs/status locations follow the conduct-<run_id> contract
    #      and print `handle=<value>` on stdout before exiting 0.
    #   ;;
    *)
      refuse "$launcher" "unknown launcher"
      ;;
  esac

  check_eligibility "$worktree_abs" "$cmd"

  case "$launcher" in
    print)
      launch_print "$worktree" "$model" "$cmd"
      ;;
    headless)
      launch_headless "$worktree_abs" "$model" "$cmd" "$run_id" "$log_dir"
      ;;
  esac
}

main "$@"
