# Compact branch history

Follow this guide only when step 4b's `pr-compact.sh signals <default>` returned `"offer": true`.

## 1. Check skip conditions

Skip the compaction offer silently and continue to `SKILL.md` step 4c if any of the following hold:

- `clean=no` (from step 1 `git-preflight.sh state`).
- `refs/remotes/origin/<branch>` exists (`git rev-parse --verify --quiet refs/remotes/origin/<branch>`) and `git rev-list --count HEAD..refs/remotes/origin/<branch>` is greater than 0.
- Step 4 did not just create the branch **and** `upstream=` is not `none`, not `origin/<branch>`, and not `origin/<default>` (avoids mis-targeting a branch that tracks another remote or a differently-named remote branch).
- The repository only allows squash merges: run `gh repo view --json mergeCommitAllowed,rebaseMergeAllowed`. If both `mergeCommitAllowed` and `rebaseMergeAllowed` are `false`, skip the offer.

## 2. Propose commit groups

Inspect the branch commits (`git log --reverse --stat origin/<default>..HEAD`) together with the `signals` JSON (`net_zero`, `followups`, `reason`).

Group the commits in `origin/<default>..HEAD` into a small number of contiguous ranges:

- **One commit per logical change.** Keep a version bump with its feature; fold fixups and follow-up churn (`fix`, `docs`, `test`, `ci`, `style` touching already-touched paths) into the logical change they belong to.
- **Net-zero paths.** A commit that touches only paths listed in `net_zero` must never end its own group — fold it into the adjacent group. (`pr-compact.sh apply` resets `net_zero` paths to their merge-base state in every group tree, so a group ending on a net-zero-only commit would produce an empty diff.)
- **Ordering and coverage.** Groups cover `origin/<default>..HEAD` in strictly ascending order; the final group's `<end-sha>` must equal `HEAD`.
- **Messages.** For each group, either reuse an existing range commit's message (`=<sha>`, which also preserves its author metadata) or draft a new message file (`@<file>`, Conventional Commits, lowercase imperative summary ≤72 chars, no trailing period, no AI attribution or trailers; author metadata comes from `<end-sha>`).

## 3. Present and get approval

Show the proposed groups (which commits fold into each group and each group's resulting subject/message) and the `signals` reason. Note that `apply` uses git plumbing (runs no commit hooks) and writes a backup ref; if `refs/remotes/origin/<branch>` exists, note that step 7 will ask separately before force-pushing with `--force-with-lease`.

Ask for approval via the question tool (`AskQuestion`/`AskUserQuestion`/`ask_user_question`) when available; otherwise ask conversationally.

- When step 1 found an existing PR for this branch, **default the answer to No** (keep commits as-is).
- If the user declines, continue to `SKILL.md` step 4c without compacting.

## 4. Record remote tip and write spec

Before running `apply`, check `git rev-parse --verify --quiet refs/remotes/origin/<branch>`. When it succeeds, record its full SHA as `<remote-old>` for step 7's lease:

```bash
git rev-parse refs/remotes/origin/<branch>
```

Step 1 already fetched `origin`, and section 1 verified `HEAD..refs/remotes/origin/<branch>` is 0 so `<remote-old>` is an ancestor of `HEAD`. Otherwise (including branches just created in step 4 and unpushed branches tracking `origin/<default>`), leave `<remote-old>` unset — step 7 will run a normal `git push -u origin HEAD`.

Write the spec file and any `@<file>` message files under `$(git rev-parse --git-path pr-compact)/` (`mkdir -p` first) — **never** in the working tree. `apply` refuses (exit 3) a message file that is outside that directory or is a symlink.

Spec format — one group per line, no blank lines, strictly one tab per line:

```text
<end-sha><TAB>=<sha>
<end-sha><TAB>@<abs-path-to-msg-file>
```

## 5. Run `apply` and handle exit codes

```bash
bash <skill-dir>/scripts/pr-compact.sh apply <default> <spec-file>
```

- **Exit 0:** stdout prints `old=<sha> new=<sha> backup=<ref> commits=<n>`. Show that output and the backup ref (recovery: `git reset --hard <backup>`) to the user, then continue to `SKILL.md` step 4c.
- **Exit 3 (empty group — tree equal to parent's tree):** re-propose once with that group folded into an adjacent group, present for approval, and retry `apply`.
- **Any other exit 3:** report the `REFUSE:` message and continue to `SKILL.md` step 4c without compaction.
- **Exit 1, 2, or any other non-zero exit:** stop and report the error. Do not push or open the PR.

## 6. After compaction

- Re-read `git log --oneline origin/<default>...HEAD` before drafting the PR title and summary in `SKILL.md` step 5.
- Dropped plans noted in step 3 before compaction are no longer at their old SHAs in the compacted history. A plan whose archive is pushed (step 4c) keeps its archive permalink (`blob/<archive_sha>/<path> (dropped)`); only plans without a pushed archive are listed under `## Planning artifacts` by path as `<path> (dropped, history compacted)` with no permalink.
- Carry `<remote-old>` (when `refs/remotes/origin/<branch>` existed) and `<backup>` into step 7.
