#!/usr/bin/env bash
# delegate-verdict.sh — classify a delegate run the way contract.sh does.
# Bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -euo pipefail

usage() {
  echo "usage: delegate-verdict.sh <backend> <repo-root> <n> [requested-slug]" >&2
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage
  exit 2
fi

backend=$1
root=$2
n=$3
slug=${4:-}

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
if [[ ! "$n" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi
if [[ "$backend" == devin && -z "$slug" ]]; then
  usage
  exit 2
fi

model_re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
id_re='^[A-Za-z0-9_-]{1,64}$'

resolve_model() {
  local model=$1
  if [[ "$model" =~ $model_re && "$model" != null ]]; then
    printf '%s' "$model"
  else
    printf '%s' 'auto(unresolved)'
  fi
}

first_line() {
  awk 'NR==1 { print; exit }'
}

json_strings() {
  local out='[' first=1 line enc
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  for line in "$@"; do
    enc=$(jq -Rn --arg s "$line" '$s')
    if [[ $first -eq 1 ]]; then
      first=0
    else
      out+=','
    fi
    out+="$enc"
  done
  printf '%s]' "$out"
}

# Sets MODELS and MODEL_RESOLVED from a Devin export. Mirrors contract.sh.
devin_models() {
  local export_path=$1 line model
  local -a resolved=()
  MODELS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    MODELS+=("$line")
  done < <(jq -r '[.steps[].model_name // empty] | unique | .[]' "$export_path" 2>/dev/null || true)
  for model in ${MODELS[@]+"${MODELS[@]}"}; do
    if [[ "$model" =~ $model_re && "$model" != null ]]; then
      resolved+=("$model")
    else
      resolved+=('auto(unresolved)')
    fi
  done
  MODEL_RESOLVED=$(IFS=,; printf '%s' "${resolved[*]-}")
  if [[ ${#MODELS[@]} -eq 0 ]]; then
    MODEL_RESOLVED='auto(unresolved)'
  fi
}

tmp="$root/.claude/tmp"
qfile="$tmp/exec-${backend}-questions.md"
questions=false
if [[ -s "$qfile" ]]; then
  questions=true
fi

exit_file="$tmp/exec-run-${backend}-${n}.exit"
exit_code=""
if [[ -f "$exit_file" ]]; then
  exit_code=$(tr -d '[:space:]' <"$exit_file" || true)
fi

timed_out=false
case "$exit_code" in
  124 | 137) timed_out=true ;;
esac

REASONS=()
session_id=""
model_resolved="auto(unresolved)"

case "$backend" in
  cursor)
    ndjson="$tmp/exec-run-cursor-${n}.ndjson"
    err="$tmp/exec-run-cursor-${n}.err"
    session_raw=""
    model_raw=""
    if [[ -f "$ndjson" ]]; then
      session_raw=$(jq -r 'select(.type=="system" and .subtype=="init").session_id' "$ndjson" 2>/dev/null | first_line || true)
      model_raw=$(jq -r 'select(.type=="system" and .subtype=="init").model // empty' "$ndjson" 2>/dev/null | first_line || true)
      model_resolved=$(resolve_model "$model_raw")
    fi
    if [[ -z "$session_raw" || "$session_raw" == null || ! "$session_raw" =~ $id_re ]]; then
      session_id=""
      REASONS+=("no init.session_id")
    else
      session_id=$session_raw
      if [[ "$exit_code" != 0 ]]; then
        REASONS+=("exit $exit_code")
      else
        result=$(tail -1 "$ndjson" | jq -c '{type,subtype,is_error}' 2>/dev/null || true)
        if [[ "$result" != '{"type":"result","subtype":"success","is_error":false}' ]]; then
          REASONS+=("result $result")
        fi
      fi
    fi
    ;;
  agy)
    ndjson="$tmp/exec-run-agy-${n}.ndjson"
    err="$tmp/exec-run-agy-${n}.err"
    conv=""
    model_raw=""
    if [[ -f "$ndjson" ]]; then
      conv=$(jq -r 'select(.event=="init").conversation_id' "$ndjson" 2>/dev/null | first_line || true)
      model_raw=$(jq -r 'select(.event=="init") | (.model // .init.model // empty)' "$ndjson" 2>/dev/null | first_line || true)
      model_resolved=$(resolve_model "$model_raw")
    fi
    if [[ -z "$conv" || "$conv" == null || ! "$conv" =~ $id_re ]]; then
      session_id=""
      REASONS+=("no init.conversation_id")
    else
      session_id=$conv
      if [[ "$exit_code" != 0 ]]; then
        REASONS+=("exit $exit_code")
      else
        summary=$(tail -1 "$ndjson" | jq -c '{event, status: (.status // .result.status), finished_reason: (.finished_reason // .result.finished_reason)}' 2>/dev/null || true)
        status=$(jq -r '.status // empty' <<<"${summary:-}" 2>/dev/null || true)
        finished=$(jq -r '.finished_reason // empty' <<<"${summary:-}" 2>/dev/null || true)
        if [[ "$status" != SUCCESS ]]; then
          REASONS+=("status=$status")
        else
          case "$finished" in
            print_timeout | interrupted | error)
              REASONS+=("finished_reason=$finished")
              ;;
            *)
              if [[ -f "$err" ]] && grep -qiE 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' "$err" 2>/dev/null; then
                REASONS+=("stderr soft-deny")
              fi
              ;;
          esac
        fi
      fi
    fi
    ;;
  devin)
    export_path="$tmp/exec-run-devin-${n}.json"
    MODELS=()
    MODEL_RESOLVED='auto(unresolved)'
    if [[ -f "$export_path" ]]; then
      devin_models "$export_path"
      model_resolved=$MODEL_RESOLVED
      session_raw=$(jq -r '.session_id' "$export_path" 2>/dev/null || true)
      if [[ "$session_raw" =~ $id_re && "$session_raw" != null ]]; then
        session_id=$session_raw
      else
        session_id=""
      fi
    else
      model_resolved='auto(unresolved)'
      session_id=""
    fi
    if [[ "$exit_code" != 0 || ! -f "$export_path" ]]; then
      if [[ "$exit_code" != 0 ]]; then
        REASONS+=("exit $exit_code")
      fi
      if [[ ! -f "$export_path" ]]; then
        REASONS+=("no export")
      fi
    elif [[ -z "$session_id" ]]; then
      REASONS+=("no session_id")
    else
      source=$(jq -r '.steps[-1].source' "$export_path" 2>/dev/null || true)
      if [[ "$source" != agent ]]; then
        REASONS+=("source=$source")
      elif [[ ${#MODELS[@]} -eq 0 ]]; then
        REASONS+=("no resolved model")
      elif [[ ${#MODELS[@]} -ne 1 || "$model_resolved" != "$slug" ]]; then
        REASONS+=("fallback: model mismatch ${slug}→${model_resolved}")
      fi
    fi
    ;;
esac

if [[ "$timed_out" == true ]]; then
  REASONS+=("timeout ceiling")
fi

if [[ ${#REASONS[@]} -eq 0 ]]; then
  ok=true
  reasons_json='[]'
else
  ok=false
  reasons_json=$(json_strings "${REASONS[@]}")
fi

jq -n \
  --argjson ok "$ok" \
  --arg session_id "$session_id" \
  --arg model_resolved "$model_resolved" \
  --argjson timed_out "$timed_out" \
  --argjson questions "$questions" \
  --argjson reasons "$reasons_json" \
  '{ok:$ok,session_id:$session_id,model_resolved:$model_resolved,timed_out:$timed_out,questions:$questions,reasons:$reasons}'
