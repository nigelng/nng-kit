# Stage overrides for /conduct

These overrides apply only when a stage runs under `/conduct`; see [SKILL.md](SKILL.md) for the conductor's stages, gates and downgrade rule. Step 0.6 ("Preflight + baseline") in SKILL.md defines conductor-owned vs foreign paths. Read the sibling skill and follow it with only the overrides listed here; standalone behaviour is unchanged.

## Brainstorm

Read [brainstorm/SKILL.md](../brainstorm/SKILL.md).

- In **When NOT to brainstorm**, do not offer built-in Plan mode. If the user picks the `/make-plan` path, pass the one-line prompt to Stage 2 instead of stopping for the user to paste it; do not run the remaining brainstorm steps.
- Run **Step 6 ("Produce the /make-plan prompt")** and **Step 6.5 ("Persist the brainstorm")** before Gate A when brainstorming completes. Preserve the saved prompt verbatim.
- Replace **Step 7 ("Offer next steps")** with the conductor's **Gate A**: Refine / Continue to plan / Stop. Refine returns to **Step 4 ("Ideate iteratively")** and later overwrites the same persisted brainstorm per Step 6.5 ("Persist the brainstorm").
- The **Constraints** rule "Never invoke /make-plan (prompt only)" is lifted for the conductor only. On Continue to plan, pass the Step 6 ("Produce the /make-plan prompt") prompt as make-plan args and follow Stage 2 in-session; do not invoke a disabled slash command.
- All other read-only constraints stand: brainstorm writes only its own `docs/brainstorms/**` artifact, never implementation code or commits.

## Make-plan

Read [make-plan/SKILL.md](../make-plan/SKILL.md).

- For **Step 1 ("Determine intent: new plan vs. update")**, use the prompt from brainstorm **Step 6 ("Produce the /make-plan prompt")**, the saved brainstorm prompt on resume, or the user's text when no brainstorm ran. Forward `runner=<policy>` if supplied; let make-plan parse the handoff and avoid duplicate questions.
- Replace **Step 7 ("Offer next steps")** with the transition to conductor **Stage 3**. The conductor handles the small-plan critique skip and Gate B; do not offer a separate Proceed prompt here.
- "Never implement" stands. This stage writes only `docs/plans/**`; it does not implement, commit or push.

## Critique plan

Read [critique/SKILL.md](../critique/SKILL.md).

- In **Step 1 ("Detect review context")**, select explicit **plan mode** on the conductor's plan path (`plan <path>`); do not auto-detect change mode from the dirty tree.
- Follow **Plan mode**, including its top-plan requirement, two-pass budget and plan-lock re-stamping after edits.
- Show the verdict and any remaining findings at conductor **Gate B**, rather than treating the critique's next-step suggestion as approval to execute. A **Rework** verdict recommends **Refine**; the user still chooses Approve / Refine / Abort at Gate B.

## Execute-plan

Read [execute-plan/SKILL.md](../execute-plan/SKILL.md).

- In **Step 3 ("Pre-flight checks"), item 3**, auto-proceed through the dirty-tree check only when every dirty path is conductor-owned or is a foreign path the user already accepted at conductor Step 0.6 ("Preflight + baseline"). Otherwise ask proceed / stash / abort. An accepted foreign path remains foreign and excluded from staging; accepting it at Step 0.6 already requires `finish=none`.
- Skip **Step 3 ("Pre-flight checks"), item 6** (the optional critique-plan offer): Stage 3 and Gate B already handle it.
- Keep all other execution checks, quality gates, independent review and status audit writes. In **Step 6 ("Final summary")**, retain the summary and terminal status write, but replace the `/critique change` / `/commit` / `/gh-create-pr` offers with the transition to conductor **Stage 5**.
- If the map contains `delegate:*` rows, or the final review is deferred to `/delegate:review`, end the run with terminal **partial** status and print its matching **Dispatch** lines (or the fallback commands it specifies). Do not implement delegate rows or silently substitute an in-host review. Apply the conductor's downgrade rule: `finish=none`, stop before commit and report the outstanding dispatch/review work.

## Critique change

Read [critique/SKILL.md](../critique/SKILL.md).

- In **Step 1 ("Detect review context")**, select explicit **change mode**. Override **Change mode / Resolve the diff** to review the whole branch plus working tree, not only the latest commit or `git diff HEAD`.
- Run `git fetch origin <default>` first, using the default branch from conductor Step 0.6 ("Preflight + baseline"). Set `<merge-base>` to `git merge-base origin/<default> HEAD`, then capture `git diff <merge-base>` (branch commits plus staged and unstaged changes). If there is no `origin`, use the HEAD SHA recorded at Step 0.6 as the base instead. A failed fetch or base resolution is a blocker, not permission to use a stale or narrower diff.
- Include untracked files from `git ls-files --others --exclude-standard`: read their contents as part of the review. Exclude `docs/brainstorms/**` and `docs/plans/**` from both the tracked diff and untracked review input.
- Disable **After execute-plan or a converged delegate PASS**: a converged execution review does not skip this stage. Run **Phase A** (at most two mid-tier reviews), **Phase B** (at most one top-tier escalation, only when triggered), and **Final `/critique change`** (one top-tier closing pass when ship-ready). Preserve separate read-only reviewers and fix agents, the two-top-pass ceiling, and the stop rule for remaining blocking or unresolved important findings.
- Run **Security pass (change mode)** once, using platform `security-review` when available or the skill's trust-boundary fallback. Do not take its docs-only skip under `/conduct`; unattended commit/push/PR authority remains a security-sensitive boundary.
- After critique fixes, the conductor re-runs the plan's **Verification** commands, including after closing-pass fixes that critique otherwise labels **unverified**. Report the results separately from review convergence; verification does not replace a review. Any failed verification or remaining blocking/unresolved important finding triggers the conductor's downgrade rule and prevents commit.
