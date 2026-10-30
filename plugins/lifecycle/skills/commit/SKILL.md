---
name: commit
description: >-
  Scan current changes, optionally bump package version and update
  CHANGELOG/README, then create a Conventional Commits message for review before
  committing. Args: none required. Use when the user asks to commit, save work,
  or mentions /commit, semantic commits, or Conventional Commits.
disable-model-invocation: true
---

# commit

Scan the current working-tree changes, update docs and version when appropriate, then create a [Conventional Commits](https://www.conventionalcommits.org/) commit after user review.

## Session model (Haiku default)

`/commit` is intended to run on a **low-tier / Haiku-class** model (e.g. Haiku 5.5, or Cursor Luna if equivalent). It is a checklist workflow (inspect → classify → draft → approve → stage/commit), not a design or orchestration skill.

- **Default:** Haiku (or Luna-class) for single-type / small–medium diffs.
- **Bump to mid-tier (`auto`):** large mixed trees that need careful multi-commit splits, or repos with version + CHANGELOG bumps where judgment matters.
- Do **not** require Opus / top-tier for routine `/commit`. Keep `/make-plan` and `/execute-plan` orchestration on stronger models.

If the session is clearly mid- or top-tier, still follow this skill — no need to switch down mid-flight unless the user asks.

## Delta over default Agent commit

User rules / Agent already cover Conventional Commits style and git safety (no force-push, no secrets, no amend abuse). **This skill's added value:**

1. Optional **version bump** + **CHANGELOG** / README updates when the repo uses them
2. Never stage **`docs/plans/**`** or **`docs/brainstorms/**`** unless the user explicitly asks
3. Explicit **approve / revise / cancel** before `git commit`

Do not restate or contradict global git safety rules; follow them.

## Preconditions

- User explicitly asked to commit (this skill does not commit on its own initiative).
- Do not commit files that likely contain secrets (`.env`, credentials, tokens). Warn the user if they request those.
- Never stage or commit `docs/plans/**` or `docs/brainstorms/**` — those are local planning artifacts (from `/make-plan` and `/brainstorm`). Leave them unstaged; do not mention them as part of the commit plan unless the user explicitly asks to include them.

## Workflow

### 1. Inspect (parallel)

Run these in parallel:

```bash
git status --short
git diff HEAD
git diff --staged
git log -5 --oneline
```

If the working tree is clean, inform the user and stop.

### 2. Classify changes

Analyze the diff to determine the change type and scope:

- `feat:` — new feature or config
- `fix:` — bug fix or correction
- `chore:` — tooling, deps, CI, formatting
- `refactor:` — code restructuring with no behavior change
- `docs:` — documentation only
- `style:` — whitespace, formatting only
- `perf:`, `test:`, `build:`, `ci:`, `revert:` — as appropriate
- `BREAKING CHANGE` or `!:` suffix — breaking change (highest priority for version bump)

Match the repo's recent commit style from `git log`.

### 3. Split plan (if needed)

If the diff spans multiple distinct change types (e.g. `feat` + `chore` + `docs`), suggest splitting into multiple commits grouped by change type:

- Present a commit plan as a list of proposed commits, each with its type, summary, and the files it covers.
- Wait for user approval of the plan via `AskQuestion` when available (otherwise ask conversationally).
- On approval, process each group sequentially through steps 4–9, then commit each group.
- If the user requests changes to the plan, revise and re-present.

If the diff is a single change type (or the user declines splitting), continue with one commit.

### 4. Draft commit message

Generate a conventional commit message:

```
<type>[optional scope][optional !]: <description>

[optional body — why, not what; 1-2 sentences max]
```

**Rules:**
- Description starts with a **lowercase** letter
- Imperative mood (`add`, not `added`)
- Summary ≤72 chars, no trailing period
- Focus on **why**, not a file list
- If the change spans multiple types and the user declined splitting, pick the most significant type

**Invalid:** `Add feature`, `feat: Added thing.`, `fix: fixed the bug`

**Valid:**
```
feat(processor): add retry for transient SQS failures
fix: correct contact deduplication in batch queries
chore: bump node to 24 and update jest config
```

### 5. Auto-bump package version

If a `package.json` exists (or equivalent package manifest like `pyproject.toml`, `Cargo.toml`), bump the version according to the commit type using semantic versioning:

- `BREAKING CHANGE` or `!:` → major bump (e.g. 1.2.3 → 2.0.0)
- `feat:` → minor bump (e.g. 1.2.3 → 1.3.0)
- `fix:` → patch bump (e.g. 1.2.3 → 1.2.4)
- `chore:`, `refactor:`, `docs:`, `style:`, `perf:`, `test:`, `build:`, `ci:`, `revert:` → no bump

Present the suggested version bump to the user for approval via `AskQuestion` when available (otherwise ask conversationally). If the user declines, skip the bump.

### 6. Update CHANGELOG

If a `CHANGELOG.md` exists, prepend a new entry under a `## [Unreleased]` or `## [<new-version>]` section with:

- The commit type and summary as a bullet point.
- Group by type if multiple changes are being committed together.

If no `CHANGELOG.md` exists, skip this step — do not create one.

### 7. Update README

If the changes affect documented features, configuration options, usage examples, or any content covered in `README.md`, suggest updates to keep it in sync. Present the proposed README changes to the user for approval. If no updates are needed, skip this step.

### 8. Present for review

Present the proposed commit message, version bump, changelog diff, and README diff (if any) to the user for review via `AskQuestion` when available (approve / revise / cancel); otherwise ask conversationally. **Do not commit until the user approves.**

If the user requests changes, revise and repeat this step.

### 9. Stage and commit (sequential)

On approval:

```bash
# Prefer path-specific adds. Avoid `git add -A` when docs/plans or docs/brainstorms exist.
git add <paths-to-commit>
git commit -m "$(cat <<'EOF'
<type>[scope]: <description>

<optional body>

EOF
)"
git status
```

Stage from the repo root so approved changes are included (including any approved version/CHANGELOG/README edits). Prefer path-specific `git add` over `git add -A` when `docs/plans/**` or `docs/brainstorms/**` appear in the working tree — those paths must stay unstaged. Exclude secret files if any were flagged. If a version bump was applied, include it in the same commit.

### 10. Hook failure

If pre-commit fails:

- Fix the reported issues
- Create a **new** commit — never `--amend` after a rejected hook
- Only `--amend` when the user explicitly requested it, HEAD was created by you in this session, and the commit was not pushed

## Constraints

- Do not commit if the working tree is clean — inform the user instead.
- Do not amend previous commits unless explicitly asked (see Amend below).
- Do not push — this skill only creates a local commit.
- Never stage or commit `docs/plans/**` or `docs/brainstorms/**` unless the user explicitly requests it.
- Only bump version for `feat`, `fix`, and `BREAKING CHANGE` / `!:` commit types.
- Only update CHANGELOG and README if they exist or if changes warrant it — do not create a `CHANGELOG.md` if one doesn't exist.
- Keep commit messages clean and user-authored — no AI co-author trailers or "Generated with …" lines.
- Prefer `AskQuestion` when available for approvals (commit plan, version bump, final commit message); otherwise ask conversationally.

## Safety (never)

- Update git config
- `git push --force` to main/master (warn if requested)
- Skip hooks (`--no-verify`) unless the user explicitly asks
- Commit when there are no changes
- Push unless the user explicitly asks

## Amend (rare)

Use `git commit --amend` only when **all** are true:

1. User explicitly requested amend, **or** commit succeeded but the hook auto-modified files
2. HEAD commit was created by you in this conversation
3. Commit has not been pushed

If already pushed, never amend unless the user explicitly requests it (requires force push).

## Offer next steps

After a successful commit:
- Done — stop here (local commit only).
- **Open a PR** — suggest `/gh-create-pr` to create a branch (if needed), push, and open a PR.
- **Review the change first** — suggest `/critique change` if the diff hasn't been reviewed yet.
