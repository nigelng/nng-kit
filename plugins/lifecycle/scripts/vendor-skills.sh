#!/usr/bin/env bash
# vendor-skills.sh — vendor lifecycle skills into a consumer repo, or check drift.
#
#   bash vendor-skills.sh [--tag lifecycle-vX.Y.Z] <target-repo>
#   bash vendor-skills.sh --check <target-repo>
#
# Vendor mode copies plugins/lifecycle/skills/* from the stamped nng-kit TAG —
# never from a working tree — so the vendored files are identical to what
# --check verifies against. It writes <target>/.agents/skills/.nng-kit-version
# (plugin, version, tag, skill list, date). Non-lifecycle dirs already in
# .agents/skills/ are left alone; skills dropped from a newer tag and recorded
# in the old stamp are removed.
#
# --check re-fetches the stamped tag from GitHub and fails (exit 1) on any
# drift: missing/changed file, missing stamp, missing skill dir, or a stamp
# version that disagrees with the tag's plugin.json.
#
# NNG_KIT_TAG_DIR (tests/offline): a directory used as the tag's repo tree in
# place of the GitHub tarball fetch.
set -euo pipefail

PROG=${0##*/}
REPO=nigelng/nng-kit
PLUGIN_PATH=plugins/lifecycle
STAMP=.nng-kit-version

usage() {
  cat <<EOF
Usage: bash $PROG [--tag lifecycle-vX.Y.Z] <target-repo>
       bash $PROG --check <target-repo>
EOF
}

die() {
  echo "$PROG: $*" >&2
  exit 1
}

# A stamp lives in the consumer repo, so a PR can edit it: every value that
# reaches rm/cp/URLs is validated before use.
valid_tag() { [[ "$1" =~ ^lifecycle-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_skill() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# fetch_tag mktemp dirs, removed on exit (not used with NNG_KIT_TAG_DIR).
TAG_TMPDIRS=()
cleanup_tmpdirs() {
  [[ ${#TAG_TMPDIRS[@]} -eq 0 ]] || rm -rf "${TAG_TMPDIRS[@]}"
}
trap cleanup_tmpdirs EXIT

TAG=""
CHECK=0
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1 ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag needs a value"
      TAG=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$TARGET" ]] || die "unexpected extra argument: $1"
      TARGET=$1
      ;;
  esac
  shift
done
[[ -n "$TARGET" ]] || {
  usage >&2
  exit 2
}
[[ "$CHECK" -eq 0 || -z "$TAG" ]] || die "--tag has no effect with --check"

# fetch_tag <tag> -> prints path to the tag's repo tree (a dir containing
# plugins/lifecycle). NNG_KIT_TAG_DIR short-circuits the network.
fetch_tag() {
  local tag=$1
  valid_tag "$tag" || die "invalid tag format: '$tag' (want lifecycle-vX.Y.Z)"
  if [[ -n "${NNG_KIT_TAG_DIR:-}" ]]; then
    [[ -d "$NNG_KIT_TAG_DIR/$PLUGIN_PATH" ]] || die "NNG_KIT_TAG_DIR has no $PLUGIN_PATH: $NNG_KIT_TAG_DIR"
    printf '%s\n' "$NNG_KIT_TAG_DIR"
    return 0
  fi
  local dest url
  dest=$(mktemp -d "${TMPDIR:-/tmp}/nng-kit-tag.XXXXXX")
  url="https://codeload.github.com/$REPO/tar.gz/refs/tags/$tag"
  curl -fsSL "$url" | tar xz -C "$dest" --strip-components=1 2>/dev/null ||
    die "cannot fetch tag $tag from github.com/$REPO (does it exist?)"
  [[ -d "$dest/$PLUGIN_PATH" ]] || die "tag $tag has no $PLUGIN_PATH"
  printf '%s\n' "$dest"
}

# stamp_field <stamp-file> <key> -> value or empty
stamp_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

SKILLS_DEST="$TARGET/.agents/skills"
STAMP_FILE="$SKILLS_DEST/$STAMP"
PLUGIN_JSON_REL="$PLUGIN_PATH/.claude-plugin/plugin.json"

# list_skills <dir> -> space-separated dir names under <dir>/skills, C-sorted.
# Names are validated per line BEFORE joining, so a name containing a space
# can't split into two individually-valid tokens.
list_skills() {
  (cd "$1" && LC_ALL=C ls -d */ 2>/dev/null || true) | sed 's|/$||' |
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      valid_skill "$s" || die "unsafe skill name: '$s'"
      printf '%s\n' "$s"
    done | tr '\n' ' ' | sed 's/ $//'
}

# require_valid_skills <names...> -> die on any unsafe name (stamp is PR-editable)
require_valid_skills() {
  local s
  local -a names=()
  read -ra names <<<"$1"
  for s in ${names[@]+"${names[@]}"}; do
    valid_skill "$s" || die "unsafe skill name: '$s'"
  done
}

# reject_symlinks <tree> -> die if the tag tree ships a symlink (publish gate
# already rejects them, but a hand-made tag could carry one)
reject_symlinks() {
  if find "$1/$PLUGIN_PATH/skills" -type l -print -quit 2>/dev/null | grep -q .; then
    die "tag tree contains a symlink under $PLUGIN_PATH/skills"
  fi
}

if [[ "$CHECK" -eq 1 ]]; then
  [[ -f "$STAMP_FILE" ]] || die "no stamp $STAMP_FILE — was this repo vendored?"
  tag=$(stamp_field "$STAMP_FILE" tag)
  stamped_version=$(stamp_field "$STAMP_FILE" version)
  stamped_skills=$(stamp_field "$STAMP_FILE" skills)
  [[ -n "$tag" ]] || die "stamp $STAMP_FILE has no tag="
  tree=$(fetch_tag "$tag")
  [[ -n "${NNG_KIT_TAG_DIR:-}" ]] || TAG_TMPDIRS+=("$tree")
  reject_symlinks "$tree"

  tag_version=$(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' "$tree/$PLUGIN_JSON_REL" | head -n 1)
  fails=0
  if [[ "$stamped_version" != "$tag_version" || "$tag" != "lifecycle-v$tag_version" ]]; then
    echo "$PROG: stamp version '$stamped_version' / tag '$tag' != tag version '$tag_version'" >&2
    fails=1
  fi
  tag_skills=$(list_skills "$tree/$PLUGIN_PATH/skills")
  require_valid_skills "$stamped_skills"
  require_valid_skills "$tag_skills"
  if [[ "$stamped_skills" != "$tag_skills" ]]; then
    echo "$PROG: stamp skills '$stamped_skills' != tag skills '$tag_skills'" >&2
    fails=1
  fi
  for skill in $tag_skills; do
    if [[ ! -d "$SKILLS_DEST/$skill" ]]; then
      echo "$PROG: missing vendored skill: .agents/skills/$skill" >&2
      fails=1
    elif ! diff -rq "$tree/$PLUGIN_PATH/skills/$skill" "$SKILLS_DEST/$skill" >/dev/null 2>&1; then
      echo "$PROG: drift in .agents/skills/$skill vs $tag" >&2
      fails=1
    fi
  done
  if [[ "$fails" -ne 0 ]]; then
    echo "$PROG: vendored skills drifted from $tag — re-vendor to fix" >&2
    exit 1
  fi
  echo "$PROG: .agents/skills/ matches $tag"
  exit 0
fi

# --- vendor mode ---
if [[ -z "$TAG" ]]; then
  # Default: this script sits next to the plugin, so use its version.
  local_plugin_json="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.claude-plugin/plugin.json"
  [[ -f "$local_plugin_json" ]] || die "no --tag and cannot read $local_plugin_json"
  v=$(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' "$local_plugin_json" | head -n 1)
  [[ -n "$v" ]] || die "no --tag and no version in $local_plugin_json"
  TAG="lifecycle-v$v"
fi

tree=$(fetch_tag "$TAG")
[[ -n "${NNG_KIT_TAG_DIR:-}" ]] || TAG_TMPDIRS+=("$tree")
reject_symlinks "$tree"
version=$(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' "$tree/$PLUGIN_JSON_REL" | head -n 1)
tag_skills=$(list_skills "$tree/$PLUGIN_PATH/skills")
[[ -n "$tag_skills" ]] || die "tag $TAG has no skills under $PLUGIN_PATH/skills"
require_valid_skills "$tag_skills"

mkdir -p "$SKILLS_DEST"

# Remove skills the previous stamp recorded that are gone from this tag.
if [[ -f "$STAMP_FILE" ]]; then
  old_skills=$(stamp_field "$STAMP_FILE" skills)
  require_valid_skills "$old_skills"
  old_skill_list=()
  read -ra old_skill_list <<<"$old_skills"
  for skill in ${old_skill_list[@]+"${old_skill_list[@]}"}; do
    case " $tag_skills " in
      *" $skill "*) ;;
      *)
        rm -rf "${SKILLS_DEST:?}/$skill"
        echo "$PROG: removed stale skill .agents/skills/$skill (not in $TAG)"
        ;;
    esac
  done
fi

for skill in $tag_skills; do
  rm -rf "${SKILLS_DEST:?}/$skill"
  cp -R "$tree/$PLUGIN_PATH/skills/$skill" "$SKILLS_DEST/$skill"
done

cat >"$STAMP_FILE" <<EOF
# vendored from github.com/$REPO — do not edit .agents/skills copies; edit the
# plugin in nng-kit and re-vendor. Drift gate: ci/vendor-check composite action.
plugin=lifecycle
version=$version
tag=$TAG
skills=$tag_skills
vendored_at=$(date +%Y-%m-%d)
EOF

echo "$PROG: vendored $version ($TAG): $tag_skills -> $SKILLS_DEST"
