---
name: gh-create-pr
description: >-
  Create a feature branch if on the default branch, push commits, open a PR via
  gh CLI, and watch CI. Ask the user to run /commit first if the tree is dirty.
  Args: none required. Use when the user asks to create a PR, open a pull
  request, push and PR, or mentions /gh-create-pr.
disable-model-invocation: true
---

# gh-create-pr

Create a pull request for the current changes: ensure a feature branch, push, open the PR, then watch CI. Does not commit — ask the user to run `/commit` first if needed.

## Delta over Agent + `gh`

Agent + user PR rules can open PRs without this skill. **Keep this skill focused on:**

1. **Dirty-tree gate** — if uncommitted changes exist, stop and tell the user to run `/commit` first
2. Resolve **`<default>`** branch via `gh` (never hardcode `main`)
3. Feature branch + `git push -u` + `gh pr create` + **CI watch**

Do not expand into Autopilot/Bugbot merge-ready loops (`/autopilot` / Cursor `/review`); stop after CI status is reported.

## Preconditions

- User explicitly asked to create a PR (this skill does not push or open PRs on its own initiative).
- Do not commit files that likely contain secrets (`.env`, credentials, tokens). Warn the user if they request those.
- Use `gh` for all GitHub operations. If `gh` is not available, inform the user and stop.

## Workflow

### 1. Inspect (parallel)

Run these in parallel:

```bash
git status --short
git diff HEAD
git diff --staged
git log -5 --oneline
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no-upstream"
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
```

Use the resolved name (e.g. `main` or `master`) everywhere below as `<default>`. Do **not** hardcode `main` / `origin/main`.

Then compare the current branch to that base:

```bash
git log --oneline <default>...HEAD
git diff <default>...HEAD
```

If the working tree is clean **and** there are no commits ahead of `<default>`/remote, inform the user and stop.

### 2. Commit uncommitted work (if any)

If there are uncommitted changes, ask the user to run `/commit` to handle them first. This skill does not commit changes itself. Stop until the tree is clean (or the user confirms they will commit separately and continue with already-committed work only).

### 3. Ensure feature branch

Check the current branch with `git branch --show-current`:

- If already on a feature branch (not `<default>`), skip branch creation.
- If on `<default>`, analyze the commits and suggest a branch name in the format `<type>/<short-description>` (e.g. `feat/add-tsconfig`, `fix/publish-workflow`). Present the suggested name for approval. On approval, run `git checkout -b <branch>`.

Never push commits directly to `<default>`.

### 4. Draft PR title and body

- **Title:** [Conventional Commits](https://www.conventionalcommits.org/) format.
  - Single commit → use its subject directly.
  - Multiple commits → primary commit's type+summary, or a combined summary of the main change.
- **Body:**
  - Start with a `## Summary` bullet list derived from the commit messages (what changed and why).
  - Include a short `## Test plan` checklist.
  - Check for a repo PR template (`.github/PULL_REQUEST_TEMPLATE.md` or any `.md` under `.github/PULL_REQUEST_TEMPLATE/`). If found, append its content below the generated summary, separated by a blank line.

### 5. Present for review

Present the branch name (if newly created or just confirmed), PR title, and combined body to the user for review via `AskQuestion` when available (approve / revise / cancel); otherwise ask conversationally. **Do not push or create the PR until the user approves.**

If the user requests changes to the title or body, revise and re-present.

### 6. Push (sequential)

On approval:

```bash
git push -u origin HEAD
```

Use `-u` when the branch has no upstream. Do not force-push to `<default>`; warn if the user requests it.

### 7. Create PR (sequential)

If a PR already exists for this branch, report its URL instead of creating a duplicate (`gh pr view --json url -q .url`).

Otherwise:

```bash
gh pr create --base <default> --title "<conventional-commit title>" --body "$(cat <<'EOF'
## Summary
- <bullet 1>
- <bullet 2>

## Test plan
- [ ] <checklist item>

<optional PR template content>

EOF
)"
```

Share the returned PR URL. Mention any commits created and the base branch (`<default>`) used.

### 8. Watch CI status

CI checks are triggered by the push and/or PR creation. After the PR exists:

1. Run `gh pr checks <PR-number> --watch` to monitor status checks in real time.
2. If `--watch` is unsupported or times out, poll with `gh pr checks <PR-number>` every 30–60 seconds until all checks reach a terminal state (success, failure, or cancelled).

**If all checks pass** — report success and stop. Do not merge.

**If any check fails** — do not only report failure; investigate:

1. Run `gh run view <run-id> --log-failed` to fetch the failed job's logs.
2. Identify the failing step and extract the error message(s).
3. Cross-reference with the PR changes (caused by this PR vs pre-existing/flaky).
4. Present a summary:
   - Which check(s) failed and the job name(s)
   - Specific error message(s) and failing step(s)
   - Whether the failure is caused by the PR or appears pre-existing/flaky
   - A recommended next step (fix code, update workflow, re-run, etc.)
5. If the failure is clearly caused by the PR and the fix is obvious, offer to fix it. Do **not** fix without user approval.
6. If flaky or infrastructure-related (network timeout, runner issue), offer `gh run rerun <run-id> --failed`.

**If checks are skipped or none run** — tell the user no CI checks were triggered and ask whether they expected any.

### 9. Offer next steps

After the PR is open (and CI is green or the user accepted skipped checks):
- Done — stop here; user merges manually.
- After merge on `<default>`: suggest `/gh-tag-release` to tag and trigger the publish workflow, **or** `/gh-draft-release` to create a draft GitHub Release with notes (no tag/publish).
- Clarify the difference if useful:
  - `/gh-tag-release` — push a git tag on `<default>` to trigger the publish workflow.
  - `/gh-draft-release` — create a draft GitHub Release from unreleased commits without tagging/publishing.

## Constraints

- Do not push to `<default>` directly — always use a feature branch.
- Do not create a PR if there are no changes or commits ahead of the remote.
- Present branch name (when creating one), PR title, and PR body for approval before executing.
- Do not merge the PR — this skill only creates it and watches CI.
- Do not report a CI failure without investigating — always fetch failed logs and provide a diagnosis.
- Do not fix CI failures without user approval — offer the fix and wait.
- Keep commit/PR text clean and user-authored — no AI co-author trailers.

## Safety (never)

- Update git config
- `git push --force` to `<default>` (warn if requested)
- Skip hooks (`--no-verify`) unless the user explicitly asks
- Push or open a PR when there is nothing to publish

## Amend (rare)

Use `git commit --amend` only when **all** are true:

1. User explicitly requested amend, **or** commit succeeded but the hook auto-modified files
2. HEAD commit was created by you in this conversation
3. Commit has not been pushed

If already pushed, never amend unless the user explicitly requests it (requires force push). Amending after push requires force push — warn and only proceed if the user explicitly asks.
