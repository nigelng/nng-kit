#!/usr/bin/env bash
# pr-feedback.sh [<pr-number>] — read-only GitHub PR review & CI feedback JSON.
# Prints JSON for PR metadata, unresolved review threads (with outdated flag and
# REST comment IDs), substantive reviews, top-level comments, failing checks
# (with parsed Actions run IDs), and truncation status. Never mutates GitHub.
# Bash 3.2. Requires gh and jq.
set -euo pipefail

tmp_dir=""
PR_NUMBER=""
REPO_OWNER=""
REPO_NAME=""

cleanup() { [[ -z "$tmp_dir" ]] || rm -rf "$tmp_dir"; }
trap cleanup EXIT

die() {
  echo "pr-feedback.sh: $*" >&2
  exit 2
}

usage() {
  echo "usage: pr-feedback.sh [<pr-number>]" >&2
  exit 2
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

parse_pr_arg() {
  if [[ $# -gt 1 ]]; then
    usage
  fi
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  local raw="${1#\#}"
  [[ "$raw" =~ ^[1-9][0-9]*$ ]] || usage
  PR_NUMBER="$raw"
}

run_gh() {
  local rc=0
  gh "$@" >"$tmp_dir/gh.out" 2>"$tmp_dir/gh.err" || rc=$?
  return "$rc"
}

die_with_gh_err() {
  local msg=$1
  if [[ -s "$tmp_dir/gh.err" ]]; then
    cat "$tmp_dir/gh.err" >&2
  fi
  die "$msg"
}

resolve_repo() {
  run_gh repo view --json nameWithOwner || die_with_gh_err "failed to resolve repository"
  local nwo
  nwo=$(jq -r '.nameWithOwner // ""' "$tmp_dir/gh.out" 2>/dev/null) \
    || die "invalid JSON from gh repo view"
  [[ "$nwo" == */* ]] || die "could not determine owner/repo from gh repo view"
  REPO_OWNER="${nwo%%/*}"
  REPO_NAME="${nwo#*/}"
  [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]] || die "invalid repository name: $nwo"
}

resolve_pr_number() {
  [[ -z "$PR_NUMBER" ]] || return 0
  run_gh pr view --json number || die_with_gh_err "no pull request found for current branch"
  local num
  num=$(jq -r '.number // ""' "$tmp_dir/gh.out" 2>/dev/null) \
    || die "invalid JSON from gh pr view"
  [[ "$num" =~ ^[1-9][0-9]*$ ]] || die "no pull request number returned by gh pr view"
  PR_NUMBER="$num"
}

graphql_query() {
  cat <<'EOF'
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      url
      state
      isDraft
      headRefName
      headRefOid
      baseRefName
      isCrossRepository
      author {
        __typename
        login
      }
      reviewThreads(first: 100) {
        pageInfo {
          hasNextPage
        }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          comments(first: 50) {
            pageInfo {
              hasNextPage
            }
            nodes {
              databaseId
              author {
                __typename
                login
              }
              body
              url
              createdAt
            }
          }
        }
      }
      reviews(first: 100) {
        pageInfo {
          hasNextPage
        }
        nodes {
          id
          databaseId
          author {
            __typename
            login
          }
          state
          body
          submittedAt
        }
      }
      comments(first: 100) {
        pageInfo {
          hasNextPage
        }
        nodes {
          id
          databaseId
          author {
            __typename
            login
          }
          body
          url
          createdAt
        }
      }
    }
  }
}
EOF
}

fetch_graphql() {
  local query
  query=$(graphql_query)
  run_gh api graphql \
    -f query="$query" \
    -f owner="$REPO_OWNER" \
    -f repo="$REPO_NAME" \
    -F number="$PR_NUMBER" \
    || die_with_gh_err "GraphQL query failed for PR #$PR_NUMBER"
  cp "$tmp_dir/gh.out" "$tmp_dir/gql.json"
  jq -e 'type == "object"' "$tmp_dir/gql.json" >/dev/null 2>&1 \
    || die "invalid JSON from gh api graphql"
  if jq -e '(.errors // []) | length > 0' "$tmp_dir/gql.json" >/dev/null 2>&1; then
    jq -r '.errors[].message // "GraphQL error"' "$tmp_dir/gql.json" >&2
    die "GraphQL query returned errors"
  fi
  jq -e '.data.repository.pullRequest != null' "$tmp_dir/gql.json" >/dev/null 2>&1 \
    || die "pull request #$PR_NUMBER not found in $REPO_OWNER/$REPO_NAME"
}

fetch_checks() {
  local rc=0
  run_gh pr checks "$PR_NUMBER" --json name,state,bucket,link,workflow || rc=$?
  if jq -e 'type == "array"' "$tmp_dir/gh.out" >/dev/null 2>&1; then
    cp "$tmp_dir/gh.out" "$tmp_dir/checks.json"
    return 0
  fi
  if ! grep -q '[^[:space:]]' "$tmp_dir/gh.out" && grep -qi 'no checks reported' "$tmp_dir/gh.err"; then
    printf '[]\n' >"$tmp_dir/checks.json"
    return 0
  fi
  die_with_gh_err "gh pr checks failed (exit $rc)"
}

render_output() {
  jq -c --slurpfile checks_raw "$tmp_dir/checks.json" '
    def author_login:
      if . == null or (.login // "") == "" then "ghost" else .login end;
    def author_is_bot:
      if . == null then false
      else ((.__typename // "") == "Bot") or ((.login // "") | endswith("[bot]"))
      end;
    def parse_run_id:
      if ((. // "") | test("/actions/runs/[0-9]+")) then
        (capture("/actions/runs/(?<id>[0-9]+)").id)
      else
        null
      end;

    .data.repository.pullRequest as $pr
    | ($pr.reviewThreads.nodes // [] | map(select(. != null))) as $all_threads
    | ($pr.reviews.nodes // [] | map(select(. != null))) as $all_reviews
    | ($pr.comments.nodes // [] | map(select(. != null))) as $all_comments
    | {
        pr: {
          number: $pr.number,
          url: $pr.url,
          state: $pr.state,
          is_draft: ($pr.isDraft // false),
          head_ref: $pr.headRefName,
          head_oid: $pr.headRefOid,
          base_ref: $pr.baseRefName,
          is_cross_repository: ($pr.isCrossRepository // false),
          author: ($pr.author | author_login)
        },
        threads: [
          $all_threads[]
          | select((.isResolved // false) | not)
          | {
              id: .id,
              path: .path,
              line: (.line // .originalLine // null),
              is_outdated: (.isOutdated // false),
              comments: [
                (.comments.nodes // [] | map(select(. != null)))[]
                | {
                    id: .databaseId,
                    author: (.author | author_login),
                    is_bot: (.author | author_is_bot),
                    body: (.body // ""),
                    url: (.url // ""),
                    created_at: (.createdAt // "")
                  }
              ]
            }
        ],
        reviews: [
          $all_reviews[]
          | select(((.body // "") | test("\\S")) or (.state == "CHANGES_REQUESTED"))
          | {
              id: (.databaseId // .id),
              author: (.author | author_login),
              is_bot: (.author | author_is_bot),
              state: (.state // ""),
              body: (.body // ""),
              submitted_at: (.submittedAt // null)
            }
        ],
        comments: [
          $all_comments[]
          | {
              id: (.databaseId // .id),
              author: (.author | author_login),
              is_bot: (.author | author_is_bot),
              body: (.body // ""),
              url: (.url // ""),
              created_at: (.createdAt // "")
            }
        ],
        checks: [
          ($checks_raw[0] // [])[]
          | select(.bucket == "fail")
          | {
              name: (.name // ""),
              state: (.state // ""),
              workflow: (.workflow // ""),
              link: (.link // ""),
              run_id: (.link | parse_run_id)
            }
        ],
        truncated: (
          ($pr.reviewThreads.pageInfo.hasNextPage // false)
          or ($pr.reviews.pageInfo.hasNextPage // false)
          or ($pr.comments.pageInfo.hasNextPage // false)
          or any($all_threads[]; .comments.pageInfo.hasNextPage // false)
        )
      }
  ' "$tmp_dir/gql.json"
}

main() {
  parse_pr_arg "$@"
  require_tools
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-feedback.XXXXXX")
  resolve_repo
  resolve_pr_number
  fetch_graphql
  fetch_checks
  render_output
}

main "$@"
