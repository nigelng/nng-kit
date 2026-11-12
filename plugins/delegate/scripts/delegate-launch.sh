#!/usr/bin/env bash
# delegate-launch.sh — build and run today's execute-via CLI commands.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: delegate-launch.sh [--print|--interactive] <backend> <repo-root> <n> <model> <kind> [resume-id]" >&2
}

mode=run
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      [[ "$mode" == run ]] || { usage; exit 2; }
      mode=print
      shift
      ;;
    --interactive)
      [[ "$mode" == run ]] || { usage; exit 2; }
      mode=interactive
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 5 || $# -gt 6 ]]; then
  usage
  exit 2
fi

backend=$1
root=$2
n=$3
model=$4
kind=$5
resume=${6:-}

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

phys=$(cd "$root" 2>/dev/null && pwd -P) || { usage; exit 2; }
git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || { usage; exit 2; }
git_phys=$(cd "$git_top" 2>/dev/null && pwd -P) || { usage; exit 2; }
if [[ "$phys" != "$git_phys" ]]; then
  usage
  exit 2
fi

if [[ ! "$n" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi
if [[ ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
  usage
  exit 2
fi

k=""
case "$kind" in
  brief) ;;
  fix:*)
    k=${kind#fix:}
    if [[ ! "$k" =~ ^[0-9]+$ ]]; then
      usage
      exit 2
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ -n "$resume" ]]; then
  if [[ ! "$resume" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    usage
    exit 2
  fi
fi

if [[ -n "${DELEGATE_TIMEOUT+x}" ]]; then
  if [[ ! "$DELEGATE_TIMEOUT" =~ ^[0-9]+[smh]$ ]]; then
    usage
    exit 2
  fi
  ceiling=$DELEGATE_TIMEOUT
else
  ceiling=90m
fi

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

prompt_for() {
  case "$kind" in
    brief)
      printf '%s' "Read .claude/tmp/exec-${backend}-brief.md and follow it exactly."
      ;;
    fix:*)
      if [[ -n "$resume" ]]; then
        if [[ "$backend" == cursor ]]; then
          printf '%s' "Read .claude/tmp/exec-cursor-fix-${k}.md and apply the fixes exactly."
        else
          printf '%s' "Read .claude/tmp/exec-${backend}-fix-${k}.md and fix every issue listed."
        fi
      else
        if [[ "$backend" == cursor ]]; then
          printf '%s' "Read .claude/tmp/exec-cursor-brief.md and .claude/tmp/exec-cursor-fix-${k}.md; apply the fixes exactly."
        else
          printf '%s' "Read .claude/tmp/exec-${backend}-brief.md and .claude/tmp/exec-${backend}-fix-${k}.md and fix every issue listed."
        fi
      fi
      ;;
  esac
}

build_argv() {
  local prompt
  prompt=$(prompt_for)
  argv=()
  # cursor, agy and devin cannot disable MCP per run, so DELEGATE_MCP has no
  # effect here and no MCP flag is added; see the delegate README threat model.
  case "$backend" in
    cursor)
      argv=(
        agent -p --force --trust --workspace "$root"
        --output-format stream-json --stream-partial-output --model "$model"
      )
      if [[ -n "$resume" ]]; then
        argv+=(--resume "$resume")
      fi
      argv+=("$prompt")
      ;;
    agy)
      argv=(
        agy --dangerously-skip-permissions
        --output-format stream-json --model "$model"
      )
      if [[ -n "$resume" ]]; then
        argv+=(--conversation "$resume")
      fi
      argv+=(-p "$prompt")
      ;;
    devin)
      argv=(
        devin --model "$model" --permission-mode dangerous
        --respect-workspace-trust=false
        "--export=.claude/tmp/exec-run-devin-${n}.json"
      )
      if [[ -n "$resume" ]]; then
        argv+=("--resume=${resume}")
      fi
      argv+=("--print=${prompt}")
      ;;
  esac
}

interactive_line() {
  local prompt
  case "$backend" in
    cursor)
      prompt=$(prompt_for)
      printf 'agent --trust --workspace %q --model %s "%s"\n' "$root" "$model" "$prompt"
      ;;
    agy)
      prompt=$(prompt_for)
      printf 'cd %q && agy --model %s "%s"\n' "$root" "$model" "$prompt"
      ;;
    devin)
      if [[ "$kind" == fix:* ]]; then
        prompt="Read .claude/tmp/exec-devin-fix-${k}.md and fix every issue listed."
      else
        prompt=$(prompt_for)
      fi
      printf 'cd %q && devin --model %s -- "%s"\n' "$root" "$model" "$prompt"
      ;;
  esac
}

build_argv
build_clean_env "$backend" || { usage; exit 2; }

if [[ "$mode" == print ]]; then
  t=""
  print_clean_env
  for t in "${argv[@]}"; do
    printf '%s\n' "$t"
  done
  exit 0
fi

if [[ "$mode" == interactive ]]; then
  interactive_line
  exit 0
fi

cd "$root"
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

out_ext=ndjson
if [[ "$backend" == devin ]]; then
  out_ext=out
fi
outfile=".claude/tmp/exec-run-${backend}-${n}.${out_ext}"
errfile=".claude/tmp/exec-run-${backend}-${n}.err"
exitfile=".claude/tmp/exec-run-${backend}-${n}.exit"

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
exit 0
