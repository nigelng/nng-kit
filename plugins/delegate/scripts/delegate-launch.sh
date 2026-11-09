#!/usr/bin/env bash
# delegate-launch.sh — build and run today's execute-via CLI commands.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -euo pipefail

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
        env -u DEVIN_REFUSAL_FALLBACK
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

if [[ "$mode" == print ]]; then
  t=""
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
    "$caf" -i "$timeout_bin" --kill-after=2m "$ceiling" "${argv[@]}" >"$outfile" 2>"$errfile"
  else
    "$timeout_bin" --kill-after=2m "$ceiling" "${argv[@]}" >"$outfile" 2>"$errfile"
  fi
else
  printf '%s\n' "WARN: no timeout binary; running without ceiling" >&2
  if [[ -n "$caf" ]]; then
    "$caf" -i "${argv[@]}" >"$outfile" 2>"$errfile"
  else
    "${argv[@]}" >"$outfile" 2>"$errfile"
  fi
fi
rc=$?
set -e
printf '%s\n' "$rc" >"$exitfile"
exit 0
