#!/usr/bin/env bash
# lessons.sh — capped docs/lessons.md entries for /retro.
# summary <plan>
# add [--date YYYY-MM-DD] <file> <slug> <stats> <lesson>...
# has <file> <slug>
# read <file>
# Bash 3.2. Mode 0644; invoke with bash.
# Exit 0 ok, 1 has-miss, 2 usage or unreadable/unwritable, 3 over cap.
set -euo pipefail

export LC_ALL=C

usage() {
  echo "usage: lessons.sh summary <plan>" >&2
  echo "       lessons.sh add [--date YYYY-MM-DD] <file> <slug> <stats> <lesson>..." >&2
  echo "       lessons.sh has <file> <slug>" >&2
  echo "       lessons.sh read <file>" >&2
  exit 2
}

HEADER=""
ENTRIES=()
LESSONS_TMP=""

byte_len() {
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

norm_text() {
  local s=$1
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

valid_date() {
  local d=$1 norm
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  if norm=$(date -j -f "%Y-%m-%d" "$d" "+%F" 2>/dev/null); then
    [[ "$norm" == "$d" ]]
    return
  fi
  if norm=$(date -d "$d" "+%F" 2>/dev/null); then
    [[ "$norm" == "$d" ]]
    return
  fi
  return 1
}

plans_match() {
  local s prev
  s=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  while [[ "$s" == *//* ]]; do s=${s//\/\//\/}; done
  prev=
  while [[ "$s" != "$prev" ]]; do
    prev=$s
    s=${s//\/.\//\/}
  done
  case "/$s/" in
    */../*) return 0 ;;
  esac
  case "/$s/" in
    */docs/plans/* | */docs/plans/./) return 0 ;;
  esac
  return 1
}

# Match against the part of a path below the repo root only, so a repo that
# itself lives under a docs/plans directory is not refused.
plans_lit() {
  local p=$1 root=$2
  case "$p" in
    "$root"/*) p=${p#"$root"/} ;;
  esac
  plans_match "$p"
}

# Resolve the nearest existing ancestor physically, re-append the missing tail.
plans_resolved() {
  local p=$1 root=$2 anc next base tail="" d
  anc=$p
  while [[ ! -d "$anc" ]]; do
    base=$(basename -- "$anc")
    tail=/$base$tail
    next=$(dirname -- "$anc")
    [[ "$next" != "$anc" ]] || break
    anc=$next
  done
  d=$(cd -P -- "$anc" 2>/dev/null && pwd -P) || return 1
  case "$d$tail" in
    "$root"/*) plans_match "${d#"$root"}$tail" && return 0 ;;
  esac
  return 1
}

plans_path() {
  local file=$1 p t i=0 root
  root=$(pwd -P) || root=
  [[ -n "$root" ]] || { plans_match "$file"; return; }
  plans_lit "$file" "$root" && return 0
  p=$file
  while [[ -L "$p" && $i -lt 20 ]]; do
    t=$(ls -l -- "$p" 2>/dev/null | sed 's/.* -> //')
    [[ -n "$t" ]] || break
    case "$t" in
      /*) p=$t ;;
      *) p=$(dirname -- "$p")/$t ;;
    esac
    plans_lit "$p" "$root" && return 0
    plans_resolved "$p" "$root" && return 0
    i=$((i + 1))
  done
  plans_resolved "$p" "$root" && return 0
  return 1
}

strip_entry() {
  STRIPPED=$1
  while [[ "$STRIPPED" == *$'\n\n' ]]; do
    STRIPPED=${STRIPPED%$'\n'}
  done
}

load_lessons() {
  local file=$1 line in_header=1 current=""
  HEADER=""
  ENTRIES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_header" -eq 1 ]]; then
      if [[ "$line" == "## "* ]]; then
        in_header=0
        current="$line"$'\n'
      else
        HEADER+="$line"$'\n'
      fi
    elif [[ "$line" == "## "* ]]; then
      strip_entry "$current"
      ENTRIES+=("$STRIPPED")
      current="$line"$'\n'
    else
      current+="$line"$'\n'
    fi
  done <"$file"
  if [[ "$in_header" -eq 0 && -n "$current" ]]; then
    strip_entry "$current"
    ENTRIES+=("$STRIPPED")
  fi
  if [[ -n "$HEADER" && "$HEADER" != *$'\n\n' ]]; then
    HEADER+=$'\n'
  fi
}

# Trailing blank line is part of the header. Do not assign this through
# a command substitution: that strips the final newlines.
set_default_header() {
  HEADER="# Lessons"$'\n\n'"Newest first. Written by /retro; at most 8 entries and 4096 bytes, oldest removed first."$'\n\n'
}

cmd_summary() {
  [[ $# -eq 1 ]] || usage
  local plan=$1
  if [[ ! -f "$plan" || ! -r "$plan" ]]; then
    echo "lessons.sh: cannot read $plan" >&2
    exit 2
  fi
  awk -v sq="'" '
function unwrap(v) {
  gsub(/\r/, "", v)
  gsub(/"/, "", v)
  gsub(sq, "", v)
  sub(/^[[:space:]]+/, "", v)
  sub(/[[:space:]]+$/, "", v)
  return v
}
function after_colon(line, v) {
  v = line
  sub(/^[^:]*:[[:space:]]*/, "", v)
  return v
}
function sanitise(s, cap) {
  gsub(/\r/, "", s)
  gsub(/"/, "", s)
  gsub(sq, "", s)
  gsub("[^A-Za-z0-9 ._:/()+,=-]", "_", s)
  if (cap > 0 && length(s) > cap) {
    if (cap < 4) return substr("...", 1, cap)
    s = substr(s, 1, cap - 3) "..."
  }
  return s
}
function as_int(s, sign) {
  if (s !~ /^-?[0-9]+$/) return 0
  sign = 1
  if (substr(s, 1, 1) == "-") {
    sign = -1
    s = substr(s, 2)
  }
  sub(/^0+/, "", s)
  if (s == "") return 0
  return sign * (s + 0)
}
function add_model(piece, m) {
  m = piece
  gsub(/\r/, "", m)
  sub(/^[[:space:]]+/, "", m)
  sub(/[[:space:]]+$/, "", m)
  if (m == "") return
  m = sanitise(m, 48)
  if (m == "") return
  if (models == "") {
    models = m
    return
  }
  if (index("," models ",", "," m ",") > 0) return
  models = models "," m
}
function add_fallback(raw, u, r) {
  u = unwrap(raw)
  if (u == "" || u == "null") return
  r = sanitise(u, 40)
  fb_n++
  if (fb_n == 1) fb1 = r
  else if (fb_n == 2) fb2 = r
}
function clear_item() {
  cur_model = ""
  cur_findings = ""
  cur_loops = ""
  cur_fb = ""
  cur_fb_set = 0
  cur_outcome = ""
  cur_outcome_set = 0
}
function flush_run(i, nparts, mv, o) {
  if (in_item != 1) return
  runs_n++
  mv = unwrap(cur_model)
  if (mv != "") {
    nparts = split(mv, parts, ",")
    for (i = 1; i <= nparts; i++) add_model(parts[i])
  }
  findings += as_int(unwrap(cur_findings))
  loops += as_int(unwrap(cur_loops))
  if (cur_fb_set == 1) add_fallback(cur_fb)
  if (cur_outcome_set == 1) {
    o = sanitise(unwrap(cur_outcome), 0)
    if (o == "") o = "-"
    outcome_v = o
  }
  in_item = 0
}
BEGIN {
  state = 0
  exec_state = 0
  in_runs = 0
  in_item = 0
  runs_n = 0
  findings = 0
  loops = 0
  fb_n = 0
  fb1 = ""
  fb2 = ""
  models = ""
  outcome_v = "-"
  status_v = "unknown"
  clear_item()
}
/^---[[:space:]]*$/ {
  if (state == 0) { state = 1; next }
  if (state == 1) {
    flush_run()
    state = 2
    in_runs = 0
  }
  next
}
state != 1 { next }
/^execution:[[:space:]]*$/ {
  if (exec_state == 0) exec_state = 1
  next
}
/^[^[:space:]]/ {
  flush_run()
  if (exec_state == 1) exec_state = 2
  in_runs = 0
  next
}
/^  [^[:space:]]/ {
  if (exec_state == 1) {
    flush_run()
    if ($0 ~ /^  runs:[[:space:]]*$/) {
      in_runs = 1
    } else if ($0 ~ /^  status:/) {
      in_runs = 0
      st = sanitise(unwrap(after_colon($0)), 0)
      if (st == "") st = "unknown"
      status_v = st
    } else {
      in_runs = 0
    }
  }
  next
}
/^    - skill:/ {
  if (in_runs) {
    flush_run()
    clear_item()
    in_item = 1
  }
  next
}
in_runs && in_item && /^      [A-Za-z0-9_]+:/ {
  key = $0
  sub(/^      /, "", key)
  sub(/:.*/, "", key)
  val = after_colon($0)
  if (key == "model_resolved") cur_model = val
  else if (key == "review_findings") cur_findings = val
  else if (key == "fix_loops") cur_loops = val
  else if (key == "fallback") { cur_fb = val; cur_fb_set = 1 }
  else if (key == "outcome") { cur_outcome = val; cur_outcome_set = 1 }
  next
}
END {
  if (state != 2) {
    runs_n = 0
    findings = 0
    loops = 0
    fb_n = 0
    models = ""
    outcome_v = "-"
    status_v = "unknown"
  } else {
    flush_run()
  }
  if (models == "") models = "-"
  line = "runs=" runs_n " models=" models " findings=" findings " fix_loops=" loops " fallbacks=" fb_n
  if (fb_n > 0) {
    line = line " (" fb1
    if (fb_n >= 2) line = line "; " fb2
    if (fb_n > 2) line = line "; +" (fb_n - 2) " more"
    line = line ")"
  }
  line = line " status=" status_v " outcome=" outcome_v
  if (length(line) > 200) line = substr(line, 1, 197) "..."
  printf "%s\n", line
}
' "$plan"
}

assemble() {
  local e sep=0
  BODY=$HEADER
  if [[ ${#final[@]} -eq 0 ]]; then
    return
  fi
  for e in "${final[@]}"; do
    if [[ "$sep" -eq 1 ]]; then
      BODY+=$'\n'
    fi
    BODY+=$e
    sep=1
  done
}

cmd_add() {
  local when file slug stats one elen dir mode
  local -a lessons
  local -a kept
  local -a final
  when=$(date -u +%F)
  if [[ "${1:-}" == "--date" ]]; then
    [[ $# -ge 2 ]] || usage
    when=$2
    shift 2
    if ! valid_date "$when"; then
      echo "lessons.sh: bad date" >&2
      exit 2
    fi
  elif [[ "${1:-}" == --* ]]; then
    usage
  fi
  [[ $# -ge 3 ]] || usage
  file=$1
  slug=$2
  stats=$3
  shift 3
  if plans_path "$file"; then
    echo "lessons.sh: refusing path under docs/plans" >&2
    exit 2
  fi
  if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]{0,79}$ ]]; then
    echo "lessons.sh: bad slug" >&2
    exit 2
  fi
  if [[ $# -eq 0 ]]; then
    echo "lessons.sh: need 1 to 3 lessons" >&2
    exit 2
  fi
  if [[ $# -gt 3 ]]; then
    echo "lessons.sh: at most 3 lessons" >&2
    exit 3
  fi
  lessons=()
  while [[ $# -gt 0 ]]; do
    one=$(norm_text "$1")
    case "$one" in
      "- "*) one=$(norm_text "${one#"- "}") ;;
    esac
    if [[ -z "$one" ]]; then
      echo "lessons.sh: empty lesson" >&2
      exit 2
    fi
    lessons+=("$one")
    shift
  done
  stats=$(norm_text "$stats")
  if [[ -z "$stats" ]]; then
    echo "lessons.sh: empty stats" >&2
    exit 2
  fi
  local entry lesson
  entry="## ${slug} (${when})"$'\n'"- Stats: ${stats}"$'\n'
  for lesson in "${lessons[@]}"; do
    entry+="- ${lesson}"$'\n'
  done
  elen=$(byte_len "$entry")
  if [[ "$elen" -gt 500 ]]; then
    echo "lessons.sh: entry is ${elen} bytes (max 500)" >&2
    exit 3
  fi

  dir=$(dirname -- "$file")
  if [[ -e "$file" ]]; then
    if [[ ! -f "$file" || ! -r "$file" || ! -w "$file" ]]; then
      echo "lessons.sh: cannot update $file" >&2
      exit 2
    fi
    if [[ ! -w "$dir" ]]; then
      echo "lessons.sh: cannot write $dir" >&2
      exit 2
    fi
    load_lessons "$file"
  else
    if [[ -d "$dir" ]]; then
      if [[ ! -w "$dir" ]]; then
        echo "lessons.sh: cannot write $dir" >&2
        exit 2
      fi
    else
      mkdir -p -- "$dir" || {
        echo "lessons.sh: cannot create $dir" >&2
        exit 2
      }
    fi
    set_default_header
    ENTRIES=()
  fi

  kept=()
  local e first prefix="## ${slug} ("
  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    for e in "${ENTRIES[@]}"; do
      first=${e%%$'\n'*}
      if [[ "${first#"$prefix"}" != "$first" ]]; then
        continue
      fi
      kept+=("$e")
    done
  fi
  final=()
  final+=("$entry")
  if [[ ${#kept[@]} -gt 0 ]]; then
    for e in "${kept[@]}"; do
      final+=("$e")
    done
  fi

  local pruned=0 blen count
  while true; do
    assemble
    blen=$(byte_len "$BODY")
    count=${#final[@]}
    if [[ "$count" -le 8 && "$blen" -le 4096 ]]; then
      break
    fi
    if [[ "$count" -le 1 ]]; then
      echo "lessons.sh: header plus entry is ${blen} bytes (max 4096)" >&2
      exit 3
    fi
    unset "final[$((count - 1))]"
    pruned=$((pruned + 1))
  done

  mode=0644
  if [[ -f "$file" ]]; then
    mode=$(stat -c %a -- "$file" 2>/dev/null || stat -f %Lp -- "$file" 2>/dev/null) || mode=0644
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || mode=0644
  fi

  LESSONS_TMP=$(mktemp "${dir}/.lessons.XXXXXX") || {
    echo "lessons.sh: cannot create temp file" >&2
    exit 2
  }
  trap 'rm -f "$LESSONS_TMP"' EXIT
  if ! printf '%s' "$BODY" >"$LESSONS_TMP"; then
    echo "lessons.sh: cannot write $file" >&2
    exit 2
  fi
  chmod -- "$mode" "$LESSONS_TMP" || exit 2
  if ! mv -- "$LESSONS_TMP" "$file"; then
    echo "lessons.sh: cannot write $file" >&2
    exit 2
  fi
  printf 'added %s entries=%s bytes=%s pruned=%s\n' "$slug" "${#final[@]}" "$blen" "$pruned"
}

cmd_has() {
  [[ $# -eq 2 ]] || usage
  local file=$1 slug=$2 line prefix
  if [[ ! -e "$file" ]]; then
    exit 1
  fi
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo "lessons.sh: cannot read $file" >&2
    exit 2
  fi
  prefix="## ${slug} ("
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line#"$prefix"}" != "$line" ]]; then
      exit 0
    fi
  done <"$file"
  exit 1
}

cmd_read() {
  [[ $# -eq 1 ]] || usage
  local file=$1
  if [[ ! -e "$file" ]]; then
    exit 0
  fi
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo "lessons.sh: cannot read $file" >&2
    exit 2
  fi
  head -c 4096 <"$file"
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift
case "$cmd" in
  summary) cmd_summary "$@" ;;
  add) cmd_add "$@" ;;
  has) cmd_has "$@" ;;
  read) cmd_read "$@" ;;
  *) usage ;;
esac
