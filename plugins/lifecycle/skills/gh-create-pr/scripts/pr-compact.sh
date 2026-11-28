#!/usr/bin/env bash
# pr-compact.sh — inspect PR branch noise signals and compact commits via plumbing.
# Subcommands:
#   pr-compact.sh signals <default-branch>
#   pr-compact.sh apply <default-branch> <spec-file>
# Bash 3.2 compatible. Never touches the working tree, index, or remote.
set -euo pipefail

ORIG_PWD=$(pwd -P)
TMP_DIR=""
BASE=""
OLD_HEAD=""
MB=""
BRANCH=""
RANGE_COMMITS=()
NET_ZERO=()
FOLLOWUPS=()
GROUP_ENDS=()
GROUP_MSG_MODES=()
GROUP_MSG_VALS=()
GROUP_TREES=()
NEW_COMMITS=()
OFFER=false
REASON=""

cleanup() {
  [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

die_usage() {
  echo "pr-compact.sh: $*" >&2
  exit 2
}

die_fail() {
  echo "pr-compact.sh: $*" >&2
  exit 1
}

refuse() {
  echo "REFUSE: $*" >&2
  exit 3
}

usage() {
  cat >&2 <<'EOF'
usage:
  pr-compact.sh signals <default-branch>
  pr-compact.sh apply <default-branch> <spec-file>
EOF
  exit 2
}

ensure_tmpdir() {
  if [[ -z "$TMP_DIR" ]]; then
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pr-compact.XXXXXX")
  fi
}

resolve_base() {
  local default=$1 top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die_usage "not a git repository"
  cd "$top"

  if [[ "$default" == */* ]]; then
    BASE=$default
  else
    BASE="origin/$default"
  fi
  git rev-parse --verify "${BASE}^{commit}" >/dev/null 2>&1 || die_usage "cannot resolve $BASE"
  OLD_HEAD=$(git rev-parse HEAD 2>/dev/null) || die_fail "cannot resolve HEAD"
  MB=$(git merge-base "$BASE" "$OLD_HEAD" 2>/dev/null) ||
    die_usage "cannot find merge-base between $BASE and HEAD"
}

branch_slug() {
  local branch=$1 slug
  slug=${branch//\//--}
  printf '%s' "$slug" | sed 's/[^A-Za-z0-9._-]/-/g'
}

array_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# NUL-delimited paths on stdin -> one path per line. A newline inside a path
# becomes \001 so sort/comm/awk can treat each line as one path.
path_lines() {
  LC_ALL=C tr '\0\n' '\n\001' | LC_ALL=C sed '/^$/d'
}

collect_net_zero() {
  local diff_tmp="$TMP_DIR/nz_diff" log_tmp="$TMP_DIR/nz_log" nz_tmp="$TMP_DIR/nz"
  local soh=$'\001' nl=$'\n' p
  NET_ZERO=()

  git diff --no-renames -z --name-only "$MB" "$OLD_HEAD" |
    path_lines | LC_ALL=C sort -u >"$diff_tmp" ||
    die_fail "failed to diff $MB..$OLD_HEAD"
  git log --no-show-signature --no-renames -z -m --format='' --name-only "$MB..$OLD_HEAD" |
    path_lines | LC_ALL=C sort -u >"$log_tmp" ||
    die_fail "failed to list touched paths in $MB..$OLD_HEAD"

  # Touched in the range but unchanged between merge-base and HEAD.
  LC_ALL=C comm -23 "$log_tmp" "$diff_tmp" >"$nz_tmp" ||
    die_fail "failed to compute net-zero paths"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    NET_ZERO+=("${p//$soh/$nl}")
  done <"$nz_tmp"
}

is_followup_subject() {
  local re='^(fix|docs|test|ci|style)(\([^)]+\))?!?:'
  [[ "$1" =~ $re ]]
}

# A followup has a fix/docs/test/ci/style subject, touches at least one path,
# and touches only paths an earlier range commit already touched. The stream is
# one block per commit, oldest first: blank line, "<sha> <subject-flag>", paths.
collect_followups() {
  local revs_tmp="$TMP_DIR/followup_revs" stream="$TMP_DIR/followup_stream"
  local out_tmp="$TMP_DIR/followups" line sha subject flag
  FOLLOWUPS=()

  git log --no-show-signature --reverse --format='%H %s' "$MB..$OLD_HEAD" >"$revs_tmp" ||
    die_fail "failed to list commits in $MB..$OLD_HEAD"

  : >"$stream"
  # Split on the first space only: read's own splitting would trim the subject.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sha=${line%% *}
    subject=${line#* }
    flag=0
    if is_followup_subject "$subject"; then
      flag=1
    fi
    printf '\n%s %s\n' "$sha" "$flag" >>"$stream"
    git diff-tree -m -r --no-renames -z --name-only --no-commit-id "$sha" |
      path_lines >>"$stream" ||
      die_fail "failed to list paths for $sha"
  done <"$revs_tmp"

  LC_ALL=C awk '
    function flush(   i) {
      if (sha != "" && flag == 1 && n > 0 && unseen == 0) print sha
      for (i = 1; i <= n; i++) seen[cp[i]] = 1
      n = 0
      unseen = 0
    }
    $0 == "" { flush(); hdr = 1; next }
    hdr == 1 { split($0, h, " "); sha = h[1]; flag = h[2]; hdr = 0; next }
    { n++; cp[n] = $0; if (!($0 in seen)) unseen++ }
    END { flush() }
  ' "$stream" >"$out_tmp" || die_fail "failed to compute followup commits"

  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    FOLLOWUPS+=("$sha")
  done <"$out_tmp"
}

paths_to_json() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\0' "$@" | jq -c -R -s 'split("\u0000")[:-1]'
}

is_noisy() {
  [[ "$1" -gt 0 || "$2" -ge 2 ]]
}

noise_reason() {
  local nz_count=$1 fu_count=$2
  if [[ "$nz_count" -gt 0 && "$fu_count" -ge 2 ]]; then
    printf '%s' "net-zero paths and followup commits"
  elif [[ "$nz_count" -gt 0 ]]; then
    printf '%s' "net-zero paths"
  else
    printf '%s' "followup commits"
  fi
}

decide_offer() {
  local commits=$1 merges=$2 nz_count=$3 fu_count=$4
  if [[ "$merges" -gt 0 ]]; then
    OFFER=false; REASON="merge commits in range"
  elif [[ "$commits" -le 3 ]]; then
    OFFER=false; REASON="at most 3 commits"
  elif [[ "$commits" -ge 8 ]]; then
    OFFER=true; REASON="8 or more commits"
  elif is_noisy "$nz_count" "$fu_count"; then
    OFFER=true; REASON=$(noise_reason "$nz_count" "$fu_count")
  else
    OFFER=false; REASON="no noise signal"
  fi
}

cmd_signals() {
  local default=$1 commits merges nz_json fu_json
  resolve_base "$default"
  ensure_tmpdir
  commits=$(git rev-list --count "$MB..$OLD_HEAD") || die_fail "failed to count commits"
  merges=$(git rev-list --count --merges "$MB..$OLD_HEAD") || die_fail "failed to count merges"
  collect_net_zero
  collect_followups
  decide_offer "$commits" "$merges" "${#NET_ZERO[@]}" "${#FOLLOWUPS[@]}"

  nz_json=$(paths_to_json ${NET_ZERO[@]+"${NET_ZERO[@]}"})
  fu_json=$(paths_to_json ${FOLLOWUPS[@]+"${FOLLOWUPS[@]}"})

  jq -n -c \
    --argjson commits "$commits" \
    --argjson merges "$merges" \
    --argjson net_zero "$nz_json" \
    --argjson followups "$fu_json" \
    --argjson offer "$OFFER" \
    --arg reason "$REASON" \
    '{commits:$commits,merges:$merges,net_zero:$net_zero,followups:$followups,offer:$offer,reason:$reason}'
}

check_apply_preconditions() {
  local default=$1 ref merges
  ref=$(git symbolic-ref -q HEAD 2>/dev/null) || refuse "detached HEAD"
  case "$ref" in
    refs/heads/*) BRANCH=${ref#refs/heads/} ;;
    *) refuse "HEAD is not on a local branch ($ref)" ;;
  esac

  if [[ "$BRANCH" == "$default" || ( "$default" == */* && "$BRANCH" == "${default#*/}" ) ]]; then
    refuse "current branch is $default"
  fi

  if ! git diff --quiet || ! git diff --cached --quiet ||
     [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    refuse "tracked changes in working tree or index"
  fi

  merges=$(git rev-list --count --merges "$MB..$OLD_HEAD") || die_fail "failed to count merges"
  [[ "$merges" -eq 0 ]] || refuse "merge commits in range ($merges)"
}

load_range_commits() {
  local tmp="$TMP_DIR/range_commits" sha
  RANGE_COMMITS=()
  git rev-list --reverse "$MB..$OLD_HEAD" >"$tmp" ||
    die_fail "failed to list commits in $MB..$OLD_HEAD"
  while IFS= read -r sha; do
    [[ -n "$sha" ]] && RANGE_COMMITS+=("$sha")
  done <"$tmp"
}

range_index_of() {
  local target=$1 i
  for ((i = 0; i < ${#RANGE_COMMITS[@]}; i++)); do
    if [[ "${RANGE_COMMITS[$i]}" == "$target" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# Physical path of <git-dir>/pr-compact, the only place message files may live.
msg_root() {
  local d
  d=$(git rev-parse --git-path pr-compact 2>/dev/null) || return 1
  [[ -d "$d" ]] || return 1
  (cd "$d" && pwd -P)
}

resolve_msg_file() {
  local raw=$1 file dir root
  if [[ "$raw" == /* ]]; then
    file=$raw
  elif [[ -f "$ORIG_PWD/$raw" ]]; then
    file="$ORIG_PWD/$raw"
  else
    file="$(pwd -P)/$raw"
  fi
  [[ -f "$file" ]] || refuse "message file not found: $raw"
  [[ ! -L "$file" ]] || refuse "message file must not be a symlink: $raw"
  root=$(msg_root) || refuse "message file must be under <git-dir>/pr-compact: $raw"
  dir=$(cd "$(dirname "$file")" && pwd -P) ||
    refuse "message file must be under <git-dir>/pr-compact: $raw"
  case "$dir/" in
    "$root/"*) ;;
    *) refuse "message file must be under <git-dir>/pr-compact: $raw" ;;
  esac
  printf '%s/%s' "$dir" "$(basename "$file")"
}

SPEC_PREV_IDX=-1

is_hex_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{4,40}$ ]]
}

validate_end_sha() {
  local end_raw=$1 end_sha idx
  is_hex_sha "$end_raw" || refuse "malformed spec: invalid SHA '$end_raw'"
  end_sha=$(git rev-parse --verify "${end_raw}^{commit}" 2>/dev/null) ||
    refuse "malformed spec: unknown commit '$end_raw'"
  idx=$(range_index_of "$end_sha") ||
    refuse "end SHA $end_sha is not in range $MB..HEAD"
  [[ "$idx" -gt "$SPEC_PREV_IDX" ]] ||
    refuse "end SHAs must be in strictly ascending order ($end_sha)"
  GROUP_ENDS+=("$end_sha")
  SPEC_PREV_IDX=$idx
}

parse_msg_sha() {
  local msg_raw=$1 msg_sha
  is_hex_sha "$msg_raw" || refuse "malformed spec: invalid message SHA '$msg_raw'"
  msg_sha=$(git rev-parse --verify "${msg_raw}^{commit}" 2>/dev/null) ||
    refuse "=<sha> '$msg_raw' is not a valid commit"
  range_index_of "$msg_sha" >/dev/null ||
    refuse "=$msg_sha is not a range commit"
  GROUP_MSG_MODES+=("=")
  GROUP_MSG_VALS+=("$msg_sha")
}

parse_msg_spec() {
  local msg_spec=$1 msg_file
  case "$msg_spec" in
    =*)
      parse_msg_sha "${msg_spec#=}"
      ;;
    @*)
      msg_file=${msg_spec#@}
      [[ -n "$msg_file" ]] || refuse "malformed spec: empty message file path"
      msg_file=$(resolve_msg_file "$msg_file")
      GROUP_MSG_MODES+=("@")
      GROUP_MSG_VALS+=("$msg_file")
      ;;
    *)
      refuse "malformed spec: message must start with = or @"
      ;;
  esac
}

parse_spec_line() {
  local line=$1 end_raw msg_spec
  [[ -n "$line" ]] || refuse "malformed spec: empty line"
  [[ "$line" == *$'\t'* ]] || refuse "malformed spec: missing tab"
  end_raw=${line%%$'\t'*}
  msg_spec=${line#*$'\t'}
  [[ "$msg_spec" != *$'\t'* ]] || refuse "malformed spec: unexpected tab"
  validate_end_sha "$end_raw"
  parse_msg_spec "$msg_spec"
}

parse_spec() {
  local spec_file=$1 line last_idx
  GROUP_ENDS=()
  GROUP_MSG_MODES=()
  GROUP_MSG_VALS=()
  SPEC_PREV_IDX=-1

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_spec_line "$line"
  done <"$spec_file"

  [[ "${#GROUP_ENDS[@]}" -gt 0 ]] || refuse "no groups in spec"
  last_idx=$((${#GROUP_ENDS[@]} - 1))
  if [[ "${GROUP_ENDS[$last_idx]}" != "$OLD_HEAD" ]]; then
    refuse "last group end SHA must equal HEAD ($OLD_HEAD)"
  fi
}

prepare_mb_net_zero_files() {
  local absent_file="$TMP_DIR/mb_absent.z"
  local entries_file="$TMP_DIR/mb_entries.z"
  local p entry
  : >"$absent_file"
  : >"$entries_file"

  for p in ${NET_ZERO[@]+"${NET_ZERO[@]}"}; do
    entry=$(git --literal-pathspecs ls-tree "$MB" -- "$p" 2>/dev/null || true)
    if [[ -z "$entry" || "$entry" == "040000 "* ]]; then
      printf '%s\0' "$p" >>"$absent_file"
    else
      git --literal-pathspecs ls-tree -z "$MB" -- "$p" >>"$entries_file"
    fi
  done
}

build_group_tree() {
  local end_sha=$1 prev_tree=$2 group_num=$3
  local idx_file="$TMP_DIR/index"
  local absent_file="$TMP_DIR/mb_absent.z"
  local entries_file="$TMP_DIR/mb_entries.z"
  local tree

  rm -f "$idx_file"
  GIT_INDEX_FILE="$idx_file" git read-tree "$end_sha" ||
    die_fail "failed to read tree for group $group_num ($end_sha)"
  if [[ -s "$absent_file" ]]; then
    GIT_INDEX_FILE="$idx_file" git update-index --force-remove -z --stdin <"$absent_file" ||
      die_fail "failed to strip net-zero paths for group $group_num ($end_sha)"
  fi
  if [[ -s "$entries_file" ]]; then
    GIT_INDEX_FILE="$idx_file" git update-index -z --index-info <"$entries_file" ||
      die_fail "failed to restore merge-base net-zero paths for group $group_num ($end_sha)"
  fi
  tree=$(GIT_INDEX_FILE="$idx_file" git write-tree) ||
    die_fail "failed to write tree for group $group_num ($end_sha)"
  if [[ "$tree" == "$prev_tree" ]]; then
    refuse "group $group_num ($end_sha) has a tree equal to its parent's tree"
  fi
  printf '%s' "$tree"
}

create_group_commit() {
  local tree=$1 parent=$2 end_sha=$3 mode=$4 val=$5 idx=$6
  local author_src msg_file an ae ad gpgsign gpg_args=()

  if [[ "$mode" == "=" ]]; then
    author_src=$val
    msg_file="$TMP_DIR/msg-$idx"
    git cat-file commit "$val" | sed '1,/^$/d' >"$msg_file"
  else
    author_src=$end_sha
    msg_file=$val
  fi

  an=$(git show --no-show-signature -s --format=%an "$author_src")
  ae=$(git show --no-show-signature -s --format=%ae "$author_src")
  ad=$(git show --no-show-signature -s --format=%aI "$author_src")

  gpgsign=$(git config --bool --get commit.gpgsign 2>/dev/null || echo false)
  if [[ "$gpgsign" == "true" ]]; then
    gpg_args=(-S)
  fi

  GIT_AUTHOR_NAME="$an" \
    GIT_AUTHOR_EMAIL="$ae" \
    GIT_AUTHOR_DATE="$ad" \
    git commit-tree "$tree" -p "$parent" ${gpg_args[@]+"${gpg_args[@]}"} -F "$msg_file" ||
    die_fail "failed to create commit for group $((idx + 1)) ($end_sha)"
}

assert_group_diff_subset() {
  local end_sha=$1 new_sha=$2 tmp="$TMP_DIR/group_diff.z" p
  git diff --no-renames -z --name-only "$end_sha" "$new_sha" >"$tmp" ||
    die_fail "assertion failed: could not diff $end_sha..$new_sha"
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] || continue
    if ! array_contains "$p" ${NET_ZERO[@]+"${NET_ZERO[@]}"}; then
      die_fail "assertion failed: $new_sha differs from $end_sha on non-net-zero path '$p'"
    fi
  done <"$tmp"
}

assert_compacted_history() {
  local old_head=$1 new_head=$2
  local i old_tree new_tree count first_parents

  for ((i = 0; i < ${#NEW_COMMITS[@]}; i++)); do
    assert_group_diff_subset "${GROUP_ENDS[$i]}" "${NEW_COMMITS[$i]}"
  done

  old_tree=$(git rev-parse "${old_head}^{tree}")
  new_tree=$(git rev-parse "${new_head}^{tree}")
  if [[ "${PR_COMPACT_TEST_FAIL_ASSERT:-}" == "1" ]]; then
    new_tree="forced-assert-failure"
  fi
  [[ "$old_tree" == "$new_tree" ]] ||
    die_fail "assertion failed: tree mismatch ($old_tree != $new_tree)"

  count=$(git rev-list --count "$MB..$new_head")
  [[ "$count" -eq "${#GROUP_ENDS[@]}" ]] ||
    die_fail "assertion failed: commit count $count != group count ${#GROUP_ENDS[@]}"

  first_parents=$(git show --no-show-signature -s --format=%P "${NEW_COMMITS[0]}")
  [[ "$first_parents" == "$MB" ]] ||
    die_fail "assertion failed: first commit parent '$first_parents' != '$MB'"
}

make_backup_ref() {
  local slug ts ref
  slug=$(branch_slug "$BRANCH")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  ref="refs/backups/pr-compact/${slug}-${ts}"
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    ref="${ref}-$$"
  fi
  printf '%s' "$ref"
}

build_all_trees() {
  local prev_tree tree i
  GROUP_TREES=()
  prev_tree=$(git rev-parse "${MB}^{tree}") || die_fail "cannot resolve merge-base tree"
  for ((i = 0; i < ${#GROUP_ENDS[@]}; i++)); do
    tree=$(build_group_tree "${GROUP_ENDS[$i]}" "$prev_tree" "$((i + 1))")
    GROUP_TREES+=("$tree")
    prev_tree=$tree
  done
}

build_all_commits() {
  local parent=$MB new_sha i
  NEW_COMMITS=()
  for ((i = 0; i < ${#GROUP_ENDS[@]}; i++)); do
    new_sha=$(create_group_commit \
      "${GROUP_TREES[$i]}" "$parent" "${GROUP_ENDS[$i]}" \
      "${GROUP_MSG_MODES[$i]}" "${GROUP_MSG_VALS[$i]}" "$i")
    NEW_COMMITS+=("$new_sha")
    parent=$new_sha
  done
}

cmd_apply() {
  local default=$1 spec_arg=$2 spec_file backup_ref new_head
  if [[ "$spec_arg" == /* ]]; then
    spec_file=$spec_arg
  else
    spec_file="$ORIG_PWD/$spec_arg"
  fi
  [[ -f "$spec_file" ]] || die_usage "spec file not found: $spec_arg"

  resolve_base "$default"
  check_apply_preconditions "$default"
  ensure_tmpdir
  load_range_commits
  parse_spec "$spec_file"

  collect_net_zero
  prepare_mb_net_zero_files
  build_all_trees

  backup_ref=$(make_backup_ref)
  git update-ref "$backup_ref" "$OLD_HEAD" ||
    die_fail "failed to create backup ref $backup_ref"

  build_all_commits
  new_head=${NEW_COMMITS[$((${#NEW_COMMITS[@]} - 1))]}
  assert_compacted_history "$OLD_HEAD" "$new_head"

  git update-ref "refs/heads/$BRANCH" "$new_head" "$OLD_HEAD" ||
    die_fail "failed to update refs/heads/$BRANCH (HEAD may have moved; backup at $backup_ref)"
  printf 'old=%s new=%s backup=%s commits=%s\n' \
    "$OLD_HEAD" "$new_head" "$backup_ref" "${#NEW_COMMITS[@]}"
}

main() {
  [[ "$#" -ge 1 ]] || usage
  local subcmd=$1
  shift
  case "$subcmd" in
    signals)
      [[ "$#" -eq 1 && -n "$1" ]] || usage
      cmd_signals "$1"
      ;;
    apply)
      [[ "$#" -eq 2 && -n "$1" && -n "$2" ]] || usage
      cmd_apply "$1" "$2"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
