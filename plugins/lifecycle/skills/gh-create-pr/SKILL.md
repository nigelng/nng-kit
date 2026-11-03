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

## Preconditions

- User explicitly asked to create a PR (this skill does not push or open PRs on its own initiative).
- Use `gh` for all GitHub operations. If `gh` is not available, inform the user and stop.

## Workflow

### 1. Inspect (parallel)

Run these in parallel:

```bash
git status --short
git log -5 --oneline
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no-upstream"
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
gh pr view --json url -q .url 2>/dev/null || echo "no-pr"
```

Use the resolved name (e.g. `main` or `master`) everywhere below as `<default>`. Do **not** hardcode `main` / `origin/main`.

If `gh pr view` returned a URL, a PR already exists for this branch — report that URL and skip create later (still may push / watch CI as needed).

Then fetch the remote default branch and compare against it (not a possibly stale local ref):

```bash
git fetch origin <default>
git log --oneline origin/<default>...HEAD
git diff origin/<default>...HEAD
```

If the working tree is clean **and** there are no commits ahead of `origin/<default>`, inform the user and stop.

### 2. Commit uncommitted work (if any)

If there are uncommitted changes, ask the user to run `/commit` to handle them first. This skill does not commit changes itself. Stop until the tree is clean (or the user confirms they will commit separately and continue with already-committed work only).

### 3. Ensure feature branch

Use the current branch from step 1 (do not re-run `git branch --show-current`):

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

If step 1 already found an existing PR for this branch, report that URL and skip create (do not call `gh pr create`).

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
2. If `--watch` is unsupported or times out, poll with `gh pr checks <PR-number>` every 30–60 seconds until all checks reach a terminal state (success, failure, or cancelled), **or until ~20 minutes have elapsed**.
3. If still pending after ~20 minutes, stop polling and report which checks are still pending (names + current status). Do not keep waiting indefinitely.

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
5. If the failure is clearly caused by the PR and the fix is obvious, offer to fix it. Do **not** fix without user approval; if approved, commit via `/commit` (or a new non-amended commit) and push normally without `--force`.
6. If flaky or infrastructure-related (network timeout, runner issue), offer `gh run rerun <run-id> --failed`.

**If checks are skipped or none run** — tell the user no CI checks were triggered and ask whether they expected any.

### 9. Offer next steps

After the PR is open (and CI is green or the user accepted skipped checks):
- Done — stop here; user merges manually.
- After merge on `<default>`: suggest `/gh-tag-release` to tag and trigger the publish workflow, **or** `/gh-draft-release` to create a draft GitHub Release with notes (no tag/publish).

## Safety (never)

- Commit secret/credential files (`.env`, tokens, keys), update `git config`, or skip hooks (`--no-verify`) unless the user explicitly asks
- `git commit --amend` after push or `git push --force` (to `<default>` or the PR branch) unless the user explicitly asks after warning
