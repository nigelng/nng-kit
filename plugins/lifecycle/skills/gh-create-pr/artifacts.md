# Planning-artifacts gate

Follow this guide at `SKILL.md` step 3 (after step 2, before creating a branch), and its Archive push section at step 4c. Do not commit, do not run `git rm`, and do not run `/relay:discard`. Uncommitted artifact files are outside this PR. The only repository write here is creating local `refs/plan-archive/*` refs with `pr-artifacts.sh archive`; pushing them needs the separate approval in Archive push.

## 1. Inventory

Call the script once:

```bash
bash <skill-dir>/scripts/pr-artifacts.sh <default>
```

Read that JSON: `plans` (`path`, `execution_status`, `archive_ref`, `archive_sha`), `notes` (`path`, `sibling`, `sibling_in_gate`), `relay` (`path`, `current_branch`, `mirror`), `dropped` (`path`, `sha`, `archive_ref`, `archive_sha`), `skipped` (unusual name). An `archive_*` value is `null` when no archive ref exists. Show each skipped path as "skipped: unusual name" and do not print a `git rm` or permalink for it. Never use `skipped` to find a dropped plan's notes; list an archive's contents with `git ls-tree -r --name-only <archive_sha>`.

Each `dropped` entry whose `archive_sha` is null (the removal was committed before it was archived, or the ref is not in this clone) gets `bash <skill-dir>/scripts/pr-artifacts.sh archive <default> <path>`. Exit 0 prints `ref=<ref> sha=<sha>`; use that sha. Exit 3: show the `REFUSE:` line, run `git ls-remote origin refs/plan-archive/<basename without .md>`; a line means the archive is already pushed, so keep that remote SHA; otherwise treat the entry as unarchived (step 5 fallback labels). Continue either way. Re-runs never rely on a remembered SHA: read `archive_sha` from this JSON.

If `plans`, `notes`, and `relay` are all empty, skip the questions and continue to step 4. Do not announce an empty gate. Still pass dropped-plan results to step 5.

## 2. Questions

**Plans.** One **Distil & Drop (Recommended)** / **Drop** / **Keep** question per `plans` entry. The prompt shows the path and `execution_status`. When that status is not `completed`, include "execution not finished" and the actual status. The user still decides. Explain the options in the prompt: Distil & Drop archives the plan to the local ref `refs/plan-archive/<slug>`, then asks you to run `/retro <plan>` (lessons and a decision record) and remove the plan; Drop archives and removes it without `/retro`; Keep leaves it in the PR. `<slug>` is the plan basename without `.md`.

**Notes.** `sibling_in_gate` true follows that plan's answer (Distil & Drop, Drop or Keep) — do not ask. `sibling_in_gate` false gets its own Keep / Drop question (path only; `*.notes.md` is not a plan, so it is not archived).

**Relay.** One question per file. `current_branch` true: **Keep** or **Discard via `/relay:discard`** (do not `git rm`; `/relay:discard` takes the `discarded` lock when a twin exists). `current_branch` false and `mirror` false: **Keep** or **Drop**. `current_branch` false and `mirror` true: **Keep** or **Discard later from its own branch** (no Drop — removing it here would orphan the twin). **Discard later** counts as Keep: nothing is printed, the gate does not stop, tell the user to run `/relay:discard` on that branch later, and list the path as `(kept)` in step 5.

Up to four questions per call of the question tool (`AskQuestion`/`AskUserQuestion`/`ask_user_question`); wait before the next four (otherwise ask conversationally).

## 3. Any Distil & Drop, Drop, or Discard via `/relay:discard`

Stop. Do not continue to step 4, push, or open a PR.

1. Archive each plan answered Distil & Drop or Drop, before printing anything else:

   ```bash
   bash <skill-dir>/scripts/pr-artifacts.sh archive <default> <plan>
   ```

   Exit 0 prints `ref=<ref> sha=<sha>` (a re-run with the same tree is a no-op). Exit 2: stop and report. Exit 3 prints `REFUSE: …` (typically: the ref exists with a different tree, e.g. the plan was edited after an earlier Drop). Show that line, then run `git ls-remote origin <ref>`:
   - Prints a line: the ref is pushed. Keep that remote SHA as the plan's archive SHA, report it, do not re-archive, and carry on.
   - Prints nothing: offer Keep for this plan, or (only when the ref exists locally) print `git update-ref -d <ref>` for the user to run. Do not run it. Stop; the re-run asks again.

2. When any plan is Distil & Dropped or Dropped, run `git rev-parse HEAD` before printing `git rm`. Print that full SHA and each dropped plan path. The re-run uses this SHA for fallback permalinks when `git cat-file -e "<sha>:<path>"` succeeds; otherwise use the JSON `sha`. Name each dropped plan and its sibling note when `notes` lists that plan as `sibling`.

3. For each plan answered Distil & Drop, print `/retro <plan>` and tell the user to run it before the `git rm` below (it reads the plan and writes `docs/lessons.md` and a decision record under `docs/decisions/`). Do not run it. Then, for every Distil & Drop or Drop plan, print this and do not run it. Paths are each such plan plus each `notes` path whose `sibling` is that plan:

   ```bash
   git rm -- docs/plans/<file> docs/plans/<slug>.notes.md …
   ```

   3b. When a note with `sibling_in_gate` false is Dropped, print `git rm -- <path> …` for those notes paths only and do not run it. No dropped-plan permalink.

4. When any relay file is Discarded or Dropped:
   - `current_branch` true: print: Run `/relay:discard`. It takes the `discarded` lock when a twin exists, then removes this branch’s handoff (`docs/relay/<slug>.md` or legacy `docs/handoffs/<slug>.md`). Do not `git rm` `docs/relay/**` or `docs/handoffs/**`.
   - `current_branch` false and `mirror` false: print `git rm -- <path> …` and do not run it. Mirrored other-branch files are never Dropped here.

5. Ask the user to run `/commit` for removals already made (plan `git rm`, other-branch relay `git rm`, relay files removed by `/relay:discard`, and the `/retro` outputs for Distil & Drop). When a plan is dropped, suggest `chore: drop plan <slug>` (`<slug>` is the basename without `.md`; several slugs, space-separated, in one subject). When only current-branch relay files are discarded, suggest `chore: discard relay <slug>`; for other-branch relay drops use `chore: drop relay <slug>`. When plans and relay files are mixed, name both. Then stop. Kept answers are not stored: the re-run asks again, and reads `archive_sha` from the JSON. After those paths are gone and committed, re-running `/gh-create-pr` passes the gate.

**All Keep (including Discard later).** Continue to step 4. Step 5 lists every kept path under `## Planning artifacts`, including a kept plan's sibling note when `notes` lists it, and each note kept via its own question.

## Archive push (step 4c)

Runs after step 4b (compaction does not touch `refs/plan-archive/*`) and before step 5 drafting, for each `dropped` entry with an `archive_ref` (or a remote archive found in section 1). Archive refs are parentless commits holding only the plan and its notes, so pushing one never publishes branch history. Steps:

1. Compare each ref with the remote: `git ls-remote origin <archive_ref>`.
   - Same SHA as `archive_sha`: already pushed.
   - A different SHA: do not push. Use that remote SHA as the archive SHA and report it.
   - Nothing: unpushed.
2. When any are unpushed, ask once (question tool when available; otherwise conversationally): **Push** / **Don't push**. List each unpushed ref, its SHA, and every path in its tree (`git ls-tree -r --name-only <archive_sha>`: the plan and its notes). State that the content becomes effectively permanent on the remote (deleting the ref later can leave the objects reachable by SHA). This approval is separate from the step 6 and force-push approvals. When step 1 found an existing PR, still ask; the permalinks go in the step 8 report.
3. On **Push**, run `git push origin <ref>:<ref> …` for the unpushed refs. Never force-push or delete a ref. A rejected push (some hosts refuse custom refs) is reported and treated as declined; never abort the PR.
4. **Don't push** or rejected: the plan's archive counts as not pushed. Continue to step 5 either way.

Link labels for step 5 and the step 8 existing-PR report come from these results (see `SKILL.md` step 5).
