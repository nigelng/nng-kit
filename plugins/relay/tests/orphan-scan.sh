#!/usr/bin/env bash
# Fixture harness for the relay orphan scan (format.md "Orphans").
# The block between the BEGIN/END markers is the canonical scan; it is copied
# byte-identically into the relay skills. Keep it self-contained.

# BEGIN relay_orphan_scan
relay_slug() {
  printf '%s' "$1" | sed -e 's#/#--#g' -e 's#[^A-Za-z0-9._-]#-#g'
}

relay_detached_is_orphan() {
  local sha="$1"
  [[ "$sha" =~ ^[0-9a-fA-F]{4,40}$ ]] || return 0
  git cat-file -e "${sha}^{commit}" 2>/dev/null && return 1
  [ -z "$(git rev-parse --disambiguate="$sha" 2>/dev/null)" ]
}

relay_orphan_scan() {
  local local_names remote_names remote_out stale=0 to name known="" f base
  local_names="$(git for-each-ref --format='%(refname)' refs/heads | sed 's#^refs/heads/##')"
  git remote get-url origin >/dev/null 2>&1 || stale=1
  to="$(command -v timeout || command -v gtimeout || true)"
  [ -n "$to" ] || stale=1
  if [ "$stale" = 0 ]; then
    remote_out="$(GIT_TERMINAL_PROMPT=0 "$to" 10 git ls-remote --heads origin 2>/dev/null)" || stale=1
  fi
  remote_names="$(printf '%s\n' "${remote_out:-}" | awk 'NF{print $2}' | sed 's#^refs/heads/##')"
  while IFS= read -r name; do
    [ -n "$name" ] && known="${known}$(relay_slug "$name")"$'\n'
  done < <(printf '%s\n%s\n' "$local_names" "$remote_names")
  printf 'stale=%s\n' "$stale"
  while IFS= read -r f; do
    base="$(basename "$f" .md)"
    if [[ "$base" == detached-* ]]; then
      relay_detached_is_orphan "${base#detached-}" || continue
    else
      printf '%s' "$known" | grep -Fxq -- "$base" && continue
    fi
    printf 'orphan %s\n' "$(basename "$f")"
  done < <(find docs/handoffs -maxdepth 1 -type f -name '*.md' 2>/dev/null) | LC_ALL=C sort
}
# END relay_orphan_scan

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

GIT=(git -c user.email=t@t -c user.name=t)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

commit_file() { # <repo> <file>
  echo "$2" >"$1/$2"
  "${GIT[@]}" -C "$1" add "$2"
  "${GIT[@]}" -C "$1" commit -q -m "add $2"
}

write_handoff() { # <repo> <file-slug>
  mkdir -p "$1/docs/handoffs"
  printf -- '---\nid: %s\ntitle: t\norigin: code\nsaved-at: 2026-10-01T12:00:00Z\n---\nbody\n' \
    "$2" >"$1/docs/handoffs/$2.md"
}

# Bare origin plus a working clone on main with one commit pushed.
make_repo() { # <name> -> sets BARE and CLONE
  BARE="$TMP/$1.git"
  CLONE="$TMP/$1"
  git init -q --bare -b main "$BARE"
  git clone -q "$BARE" "$CLONE" 2>/dev/null
  git -C "$CLONE" checkout -q -b main 2>/dev/null || true
  commit_file "$CLONE" seed
  git -C "$CLONE" push -q origin main
}

assert_scan() { # <label> <repo> <expected>
  local got
  got="$(cd "$2" && relay_orphan_scan)"
  if [ "$got" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "ok $PASS - $1"
  else
    FAIL=$((FAIL + 1))
    echo "not ok - $1"
    diff <(printf '%s\n' "$3") <(printf '%s\n' "$got") | sed 's/^/    /'
  fi
}

case_reachable() {
  make_repo reach
  "${GIT[@]}" -C "$CLONE" branch feat/local
  local other="$TMP/reach-other"
  git clone -q "$BARE" "$other" 2>/dev/null
  "${GIT[@]}" -C "$other" checkout -q -b feat/remote
  commit_file "$other" remote
  git -C "$other" push -q origin feat/remote
  local s
  for s in feat--local feat--remote feat--gone detached-deadbeef main; do
    write_handoff "$CLONE" "$s"
  done
  assert_scan "local, remote, gone and unresolvable detached" "$CLONE" \
    $'stale=0\norphan detached-deadbeef.md\norphan feat--gone.md'
}

case_ambiguous_detached() {
  make_repo ambig
  local i dups files=()
  for i in $(seq 1 700); do echo "blob $i" >"$TMP/blob.$i"; files+=("$TMP/blob.$i"); done
  printf '%s\n' "${files[@]}" | git -C "$CLONE" hash-object -w --stdin-paths |
    cut -c1-4 | sort | uniq -d >"$TMP/dups"
  dups="$(head -n 1 "$TMP/dups")"
  if [ -z "$dups" ]; then
    FAIL=$((FAIL + 1)); echo "not ok - could not build an ambiguous 4-hex prefix"; return 0
  fi
  [ -n "$(git -C "$CLONE" rev-parse --disambiguate="$dups")" ] || FAIL=$((FAIL + 1))
  write_handoff "$CLONE" main
  write_handoff "$CLONE" "detached-$dups"
  assert_scan "ambiguous short detached sha is not an orphan" "$CLONE" 'stale=0'
}

case_unreachable() {
  make_repo unreach
  write_handoff "$CLONE" feat--gone
  git -C "$CLONE" remote set-url origin /nonexistent/x.git
  assert_scan "unreachable origin is stale" "$CLONE" \
    $'stale=1\norphan feat--gone.md'
}

case_no_origin() {
  make_repo noorigin
  write_handoff "$CLONE" main
  git -C "$CLONE" remote remove origin
  assert_scan "removed origin is stale" "$CLONE" 'stale=1'
}

case_empty_remote() {
  local bare="$TMP/empty.git" clone="$TMP/empty"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$clone" 2>/dev/null
  git -C "$clone" checkout -q -b main 2>/dev/null || true
  commit_file "$clone" seed
  write_handoff "$clone" main
  write_handoff "$clone" feat--gone
  assert_scan "empty reachable origin counts local only" "$clone" \
    $'stale=0\norphan feat--gone.md'
}

# Run the extracted canonical block under zsh and compare to bash, with empty stderr.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
extract_block() { sed -n '/^# BEGIN relay_orphan_scan$/,/^# END relay_orphan_scan$/p' "$SELF"; }

assert_zsh_matches() { # <label> <repo>
  local want got err="$TMP/zsh.err"
  want="$(cd "$2" && relay_orphan_scan)"
  got="$(cd "$2" && zsh -c "$(extract_block)"$'\nrelay_orphan_scan' 2>"$err")"
  if [ "$got" = "$want" ] && [ ! -s "$err" ]; then
    PASS=$((PASS + 1))
    echo "ok $PASS - $1"
  else
    FAIL=$((FAIL + 1))
    echo "not ok - $1"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/    /'
    sed 's/^/    stderr: /' "$err"
  fi
}

case_zsh() {
  command -v zsh >/dev/null 2>&1 || { echo "skip zsh (not installed)"; return 0; }
  assert_zsh_matches "zsh matches bash with handoffs" "$TMP/reach"
  make_repo nodir
  assert_zsh_matches "zsh matches bash with no docs/handoffs" "$CLONE"
  mkdir -p "$CLONE/docs/handoffs"
  assert_zsh_matches "zsh matches bash with empty docs/handoffs" "$CLONE"
}

case_reachable
case_ambiguous_detached
case_unreachable
case_no_origin
case_empty_remote
case_zsh

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
