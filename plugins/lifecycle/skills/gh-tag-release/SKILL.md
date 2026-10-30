---
name: gh-tag-release
description: >-
  Date the changelog and push a release tag to trigger publish CI. Differs from
  gh-draft-release, which drafts a GitHub Release with notes. Args: none
  required. Use when the user asks to tag a release, publish a version, or
  mentions /gh-tag-release.
disable-model-invocation: true
---

# gh-tag-release

Date the changelog and **push a release tag** to trigger publish CI. This is not
`gh-draft-release`: that skill drafts a GitHub Release with notes via `gh`; this
skill only dates the changelog and pushes a git tag (the publish workflow
handles the release).

**When to use this vs `/gh-draft-release`:**
- `/gh-tag-release` (this skill) — push a git tag on `<default>` (after CI is green) to trigger the publish workflow. Does **not** create a GitHub Release draft; the publish workflow handles the release.
- `/gh-draft-release` — create a **draft** GitHub Release with generated notes from unreleased commits. Does **not** push a tag or trigger publish. User publishes the draft manually.

## Preconditions

- User explicitly asked to tag a release (this skill does not push or tag on its own initiative).
- Use `gh` for all GitHub operations. If `gh` is not available, skip the CI wait step with a note.
- Do not create a GitHub Release — this skill only creates and pushes a git tag. The publish workflow handles the release.

## Workflow

### 0. Resolve default branch

```bash
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
```

Use that name (e.g. `main` or `master`) everywhere below as `<default>`. Do **not** hardcode `main` / `origin/main`.

Confirm the current branch:

```bash
git branch --show-current
```

- If already on `<default>`, proceed.
- If not on `<default>`: abort, **or** ask for approval to `git checkout <default>` before any push/tag. Do not push or tag from a non-default branch.

### 1. Propose the tag version

- Read the `version` field from `package.json` (e.g. `3.0.0`).
- Read the latest unreleased section header in `CHANGELOG.md`. Common variants include:
  - `## [3.0.0] — unreleased` / `## [3.0.0] - unreleased` (em-dash or hyphen)
  - `## [Unreleased]` / `## Unreleased`
  - Other fuzzy matches of an unreleased heading (case-insensitive `unreleased`)
- Extract the version from that heading when present (e.g. from `## [3.0.0] — unreleased`). If the heading is only `Unreleased` / `[Unreleased]` with no version, use the `package.json` version.
- If the `package.json` version and the CHANGELOG header version **match**, propose `v<version>` as the tag.
- If they **differ**, present both versions and propose a reconciliation:
  - Use `AskQuestion` when available (otherwise ask conversationally) which version to use, or suggest bumping `package.json` to match the CHANGELOG (or vice versa).
  - On approval, update the mismatched file(s) so both agree.
- Present the proposed tag to the user for approval. If the user requests a different tag, revise.

If no `package.json` exists, ask the user for the version directly.

### 2. Check for uncommitted changes

```bash
git status --short
```

If there are uncommitted changes, inform the user: "There are uncommitted changes. Commit or stash them first." and stop.

If the working tree is clean, proceed.

### 3. Push default branch to remote (if local is ahead)

```bash
git fetch origin
git log origin/<default>..<default> --oneline
```

If local `<default>` is **ahead** of `origin/<default>` (there are unpushed commits):

- Ask the user for approval to push: `git push origin <default>`.
- On approval, push. On denial, stop.

If local `<default>` is **behind** `origin/<default>`: inform the user "local `<default>` is behind origin/`<default>` — pull or rebase first" and stop.

If local `<default>` is **up to date** with `origin/<default>`: proceed to step 4.

### 4. Wait for CI to pass on the default branch

```bash
gh run list --branch <default> --limit 5
```

Identify the latest run for the verify workflow (the one triggered by the push to `<default>`, or the most recent run if already up to date).

- If the latest run is still in progress, watch it: `gh run watch <run-id> --exit-status`.
- If the run **fails**, inform the user: "CI failed on `<default>`. Fix the issues before releasing." and stop.
- If the run **succeeds**, proceed to step 5.
- If no verify workflow exists for this repo, skip this step with a note to the user.

### 5. Update the CHANGELOG for release

If no `CHANGELOG.md` exists, skip this step with a note.

Otherwise:

- Find the latest unreleased heading (see variants in step 1). Date it for release:
  - Versioned unreleased (e.g. `## [3.0.0] — unreleased` / `- unreleased`) → `## [<version>] — <today's-date>` (ISO: `YYYY-MM-DD`), preserving the repo's heading style where practical.
  - Bare `## [Unreleased]` / `## Unreleased` → replace with a dated versioned heading such as `## [<version>] — <today's-date>` (or the repo's established pattern).
- Present the changelog change to the user for approval.
- On approval, apply the edit and commit:

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: date <version> release in changelog

EOF
)"
```

- Push the commit: ask the user for approval to `git push origin <default>`, then push.

### 6. Tag and push the tag

```bash
git tag v<version>
```

Ask the user for approval to push the tag: `git push origin v<version>`.

On approval, push the tag. This triggers the publish workflow.

Share the workflow run URL with the user:

```bash
gh run list --workflow=publish.yml --limit 1
```

(Use the appropriate workflow name if not `publish.yml`.)

### 7. Revisions

If the user requests changes to the tag or version, revise and repeat from step 1.

## Constraints

- Do not push anything without explicit user approval for each push.
- If CI fails on `<default>`, stop and inform the user. Do not tag until CI passes.
- If local `<default>` is behind `origin/<default>`, stop and inform the user. Do not force-push or overwrite.
- Do not push or tag unless on `<default>` (or after approved checkout to `<default>`).
- Keep commit messages clean and user-authored — no AI co-author trailers or "Generated with …" lines.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for the changelog commit (`docs: date <version> release in changelog`).

## Safety (never)

- Update git config
- `git push --force` to `<default>` (warn if requested)
- Skip hooks (`--no-verify`) unless the user explicitly asks
- Tag or push without explicit user approval
- Create a GitHub Release (the publish workflow handles that; use `gh-draft-release` to draft one)
