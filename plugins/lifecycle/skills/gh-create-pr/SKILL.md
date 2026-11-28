---
name: gh-create-pr
description: >-
  Create a feature branch if on the default branch, push commits, open a PR via
  gh CLI, and watch CI. Ask the user to run /commit first if the tree is dirty.
  Gate plan and relay files on the branch (Distil & Drop, Drop or Keep) and
  stop without deleting or committing when any are dropped. Args: none
  required. Use when
  the user asks to create a PR, open a pull request, push and PR, or mentions
  /gh-create-pr.
disable-model-invocation: true
---

# gh-create-pr

Create a pull request for the current changes: ensure a feature branch, optionally compact noisy history, push, open the PR, then watch CI. Does not commit or delete plan or relay files (step 4b compaction, when approved, rewrites commits). Archives dropped plans to local `refs/plan-archive/*` refs and pushes them only after a separate approval (step 4c). Ask the user to run `/commit` first if the tree is dirty. If they Distil & Drop or Drop a plan, or Discard a relay file, print the commands, ask them to commit, and stop.

## Preconditions

- User explicitly asked to create a PR (this skill does not push or open PRs on its own initiative).
- Use `gh` for all GitHub operations. If `gh` is not available, inform the user and stop.

## Workflow

### 1. Inspect (parallel)

`<skill-dir>` is the absolute directory of this `SKILL.md`. Run:

```bash
bash <skill-dir>/../commit/scripts/git-preflight.sh state
git log -5 --oneline
gh pr view --json url -q .url 2>/dev/null || echo "no-pr"
```

Use `default=` as `<default>` everywhere below. Do **not** hardcode `main` / `origin/main`. If `default=` is empty, stop and ask — do not guess. `state` fetched `origin`; on stderr `WARN: git fetch failed`, stop (stale `origin`). `clean=`, `branch=`, `upstream=`, `ahead=`, and `behind=` are against that upstream.

If `gh pr view` returned a URL, a PR already exists for this branch — report that URL and skip create later (still may push / watch CI as needed).

Compare against the remote default (not a possibly stale local ref):

```bash
git log --oneline origin/<default>...HEAD
git diff origin/<default>...HEAD
```

If `clean=yes` **and** that log is empty, inform the user and stop.

### 2. Commit uncommitted work (if any)

If `clean=no`, ask the user to run `/commit` to handle uncommitted changes first. Stop until the tree is clean (or the user confirms they will commit separately and continue with already-committed work only).

### 3. Planning-artifacts gate

After step 2, before creating a branch. Read and follow `<skill-dir>/artifacts.md`: it runs `scripts/pr-artifacts.sh <default>`, asks **Distil & Drop (Recommended)** / **Drop** / **Keep** per plan (and the note and relay questions), archives dropped plans to local `refs/plan-archive/*` refs, and stops for `/commit` on any Distil & Drop, Drop, or Discard. Do not commit, `git rm`, or run `/relay:discard` here. If it does not stop, continue to step 4 and carry its dropped-plan results (`archive_sha`, `sha`) to steps 4c and 5.

### 4. Ensure feature branch

Use the current branch from step 1 (do not re-run `git branch --show-current`):

- If already on a feature branch (not `<default>`), skip branch creation.
- If on `<default>`, analyze the commits and suggest a branch name in the format `<type>/<short-description>` (e.g. `feat/add-tsconfig`, `fix/publish-workflow`). Present the suggested name for approval. On approval, run `git checkout -b <branch>`.

Never push commits directly to `<default>`.

### 4b. Compact (optional)

Inspect commit noise on the branch:

```bash
bash <skill-dir>/scripts/pr-compact.sh signals <default>
```

When `offer` is `true`, read and follow `<skill-dir>/compact.md`. When `offer` is `false`, continue to step 4c silently. On non-zero exit, report briefly and continue to step 4c. If compaction runs, re-read `git log --oneline origin/<default>...HEAD` for step 5.

### 4c. Archive push approval

After step 4b, before step 5. When step 3 produced dropped plans with an `archive_ref`, follow the Archive push section of `<skill-dir>/artifacts.md`. Push only on that separate approval; declined or rejected still continues to step 5.

### 5. Draft PR title and body

- **Title:** [Conventional Commits](https://www.conventionalcommits.org/) format.
  - Single commit → use its subject directly.
  - Multiple commits → primary commit's type+summary, or a combined summary of the main change.
- **Body:**
  - Start with a `## Summary` bullet list derived from the commit messages (what changed and why).
  - If step 3 kept any files or recovered any dropped-plan permalinks, add `## Planning artifacts` after the summary and before the test plan. One bullet per kept path (`<path> (kept)`), plans and relay files included; for each kept plan, also bullet the sibling path `notes` lists for it (`(kept)`). One bullet per dropped plan (notes siblings are removed via `git rm` with the plan, not separate permalinks), by its step 4c result, with `<url>` = `https://github.com/<owner>/<repo>/blob/<sha>/<path>` (`gh repo view --json nameWithOwner -q .nameWithOwner`; `<path>` has no leading slash):
    - Archive pushed (or found on the remote): `<url with the archive SHA (the remote SHA when it differs)> (dropped)`.
    - Not pushed (declined, rejected, or never archived), step 4b did not compact: `<url with the dropped sha> (dropped, archive not pushed)`.
    - Not pushed, step 4b compacted: `<path> (dropped, history compacted)`, no permalink.

    Include only rows that exist. Omit the heading when both lists are empty.
  - Include a short `## Test plan` checklist.
  - Check for a repo PR template (`.github/PULL_REQUEST_TEMPLATE.md` or any `.md` under `.github/PULL_REQUEST_TEMPLATE/`). If found, append its content below the generated summary, separated by a blank line.

### 6. Present for review

Present the branch name (if newly created or just confirmed), PR title, and combined body for review via the question tool when available (approve / revise / cancel); otherwise ask conversationally. **Do not push or create the PR until the user approves.**

If the user requests changes to the title or body, revise and re-present.

### 7. Push (sequential)

If step 4b compacted commits in this run **and** `<remote-old>` was recorded:

- Do not attempt a plain push. Ask separately for approval to force-push the compacted branch (question tool when available; otherwise conversationally).
- On approval, run with the `<remote-old>` SHA recorded before `apply` (succeeds only if the remote tip is still that commit):

```bash
git push --force-with-lease=<branch>:<remote-old> origin <branch>
```

- If the user declines or the lease is rejected, print `git reset --hard <backup>`, stop, and report. Never fall back to a bare `--force`.

Otherwise, on step 6 approval:

```bash
git push -u origin HEAD
```

Use `-u` when the branch has no upstream. If rejected on a diverged branch with no `<remote-old>` from this run (e.g. compacted in an earlier session), stop and report — this skill does not force-push it. Never force-push to `<default>`.

### 8. Create PR (sequential)

If step 1 already found an existing PR for this branch, report that URL and skip create (do not call `gh pr create`). If step 3 or 4c produced planning-artifact lines, show them in that report, including each dropped plan's archive permalink. Do not edit the existing PR body unless the user asks.

Otherwise:

```bash
gh pr create --base <default> --title "<conventional-commit title>" --body "$(cat <<'EOF'
## Summary
- <bullet 1>
- <bullet 2>

## Planning artifacts
- docs/plans/<file>.md (kept)
- docs/plans/<slug>.notes.md (kept)
- https://github.com/<owner>/<repo>/blob/<archive_sha>/docs/plans/<file>.md (dropped)

## Test plan
- [ ] <checklist item>

<optional PR template content>

EOF
)"
```

Include only the kept and dropped rows that exist.

Share the returned PR URL. Mention any commits created and the base branch (`<default>`) used.

### 9. Watch CI status

Follow [ci-triage.md](ci-triage.md) for `<PR-number>` after the PR exists.

### 10. Offer next steps

After the PR is open (and CI is green or the user accepted skipped checks):
- Done — stop here; user merges manually.
- After merge on `<default>`: suggest `/gh-tag-release` to tag and trigger the publish workflow, **or** `/gh-draft-release` to create a draft GitHub Release with notes (no tag/publish).

## Safety (never)

- Push `refs/plan-archive/*` before the step 4c approval, or force-push or delete one (print `git update-ref -d <ref>` for the user instead). Creating them locally via `pr-artifacts.sh archive` is allowed

- Commit secret/credential files (`.env`, tokens, keys), update `git config`, or skip hooks (`--no-verify`) unless the user explicitly asks
- Commit, `git rm`, or `/relay:discard` from this skill (approved compaction in step 4b via `pr-compact.sh` is the only case that rewrites commits). On Drop or Discard, print the commands and ask the user to run `/commit`. Never `git rm` a relay file for the current branch (use `/relay:discard`) or any relay file with `mirror:`; for an unmirrored other-branch relay file, only print the `git rm`, never run it
- `git commit --amend` after push, rewrite commits without step 4b approval, or run bare `git push --force` (to `<default>` or the PR branch). After step 4b compaction on a pushed branch, use only `--force-with-lease=<branch>:<remote-old>` after separate approval
