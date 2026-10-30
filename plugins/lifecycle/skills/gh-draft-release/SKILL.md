---
name: gh-draft-release
description: >-
  Stash WIP, sync to the default branch, check unreleased commits, and create a
  draft GitHub Release with notes. Differs from gh-tag-release, which dates the
  changelog and pushes a tag to trigger publish CI. Args: none required. Use when
  the user asks to draft a release, create release notes, or mentions
  /gh-draft-release.
disable-model-invocation: true
---

# gh-draft-release

Create a **draft GitHub Release** (release notes) for unreleased commits on the
repo default branch. This is not `gh-tag-release`: that skill dates the changelog
and pushes a tag to trigger publish CI; this skill only drafts notes + a draft
release via `gh`.

**When to use this vs `/gh-tag-release`:**
- `/gh-draft-release` (this skill) — create a **draft** GitHub Release with generated notes from unreleased commits. Does **not** push a tag or trigger publish. User publishes the draft manually.
- `/gh-tag-release` — push a git tag on `<default>` (after CI is green) to trigger the publish workflow. Does **not** create a GitHub Release draft; the publish workflow handles the release.

## Preconditions

- User explicitly asked to create a draft release (this skill does not create releases on its own initiative).
- Use `gh` for all GitHub operations. If `gh` is not available, inform the user and stop.

## Workflow

### 0. Resolve default branch

```bash
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
```

Use that name (e.g. `main` or `master`) everywhere below as `<default>`. Do **not** hardcode `main` / `origin/main`.

### 1. Handle uncommitted changes

```bash
git status --short
git branch --show-current
```

Prefer **stash** on every branch (including feature branches):

```bash
git stash push -m "gh-draft-release-wip"
```

Do **not** create a `wip` commit without approval. If the user prefers a WIP commit on a feature branch instead of stash, ask first (`AskQuestion` when available, else conversational). Only after explicit approval:

```bash
git add -A
git commit -m "$(cat <<'EOF'
wip

EOF
)"
```

If no changes, proceed.

### 2. Switch to default branch

```bash
git checkout <default>
```

### 3. Fetch and rebase

```bash
git fetch origin
git rebase origin/<default>
```

### 4. Detect unreleased changes

```bash
git describe --tags --abbrev=0
git log <latest-tag>..HEAD --oneline
```

If no tags exist, all commits are unreleased.

If there are no commits since the latest tag, inform the user "nothing to release" and stop.

### 5. Generate release notes

From commits since the last tag, group by conventional commit type (`feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`).

Present as a markdown summary with sections per type. Omit empty groups.

### 6. Suggest a release tag

- Read the `version` field from `package.json`.
- Suggest `v<version>` as the tag (e.g. `v0.1.0`).
- Present the tag and release note to the user for approval.

Use `AskQuestion` when available (otherwise ask conversationally).

### 7. Check existing tag / release

Before creating, verify the suggested tag is free:

```bash
git rev-parse "v<version>" 2>/dev/null && echo "tag-exists" || echo "tag-free"
gh release view "v<version>" 2>/dev/null && echo "release-exists" || echo "release-free"
```

If the tag or release already exists, stop or ask the user whether to bump the version — do not overwrite or recreate.

### 8. Ensure local default matches remote

Release notes must only describe commits that the remote release target includes. Before `gh release create --target <default>`:

```bash
git fetch origin
git rev-parse HEAD
git rev-parse origin/<default>
git status -sb
```

Require local `<default>` == `origin/<default>` (same commit).

- If local is **ahead** / has unpushed commits: stop, or ask whether to push first (`AskQuestion` when available). Do not create a release whose notes describe commits the remote target does not include.
- If local is **behind**: rebase onto `origin/<default>` (step 3) and re-check.
- If they match: proceed.

### 9. Create draft GitHub Release

On approval of tag + notes, and after steps 7–8 pass:

```bash
gh release create <tag> --title "<tag>" --notes "<release-note>" --draft --target <default>
```

Share the release URL with the user.

### 10. Revisions

If the user requests changes to the tag or release note, revise and repeat from step 6 (re-run steps 7–8 before create).

## Post-release

After the release is created (or if the workflow stops early), inform the user how to restore their working state:

- If changes were stashed: `git stash pop`
- If a WIP commit was created on a feature branch (only after approval):
  1. `git checkout <branch>` to return to the feature branch.
  2. `git reset --soft HEAD~1` to uncommit the WIP while keeping changes staged (or `git reset HEAD~1` to unstage).

## Constraints

- Always create releases in **draft** mode — the user publishes them manually.
- Do not push to `<default>` directly unless the user explicitly approves a push to sync local ahead commits (step 8).
- If already on `<default>` with no unreleased changes, inform the user and stop.
- Keep release text clean and user-authored — no AI co-author trailers.
- Use [Conventional Commits](https://www.conventionalcommits.org/) to group release notes by type.

## Safety (never)

- Update git config
- `git push --force` to `<default>` (warn if requested)
- Skip hooks (`--no-verify`) unless the user explicitly asks
- Push to `<default>` without explicit user approval
- Create a non-draft release without explicit user approval
- Create a release without user approval of the tag and notes
- Create a `wip` commit without explicit user approval
