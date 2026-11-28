# Stage overrides for /conduct

Applies only under `/conduct`; see [SKILL.md](SKILL.md) for stages, gates, Step 0.6 path ownership, and the downgrade rule, and [unattended.md](unattended.md#worker-contract) for `unattended=yes` workers. Follow each sibling skill with only these overrides; standalone behaviour is unchanged.

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
- Follow **Plan mode**, including its separate `top-critique` review Task (`top-review` fallback), two-pass budget and session re-stamping after edits.
- Show the verdict and any remaining findings at conductor **Gate B**, rather than treating the critique's next-step suggestion as approval to execute. A **Rework** verdict recommends **Refine**; the user still chooses Approve / Refine / Abort at Gate B.

## Execute-plan

Read [execute-plan/SKILL.md](../execute-plan/SKILL.md).

- In **Step 3 ("Pre-flight checks"), item 3**, auto-proceed through the dirty-tree check only when every dirty path is conductor-owned or is a foreign path the user already accepted at conductor Step 0.6 ("Preflight + baseline"). Otherwise ask proceed / stash / abort. An accepted foreign path remains foreign and excluded from staging; accepting it at Step 0.6 already requires `finish=none`.
- Skip **Step 3 ("Pre-flight checks"), item 6** (the optional critique-plan offer): Stage 3 and Gate B already handle it.
- Keep all other execution checks, quality gates, independent review and status audit writes. In **Step 6 ("Final summary")**, retain the summary and terminal status write, but replace the `/critique change` / `/commit` / `/gh-create-pr` offers with the transition to conductor **Stage 5**.
- Delegate rows and deferred reviews: follow [delegate-loop.md](delegate-loop.md) by `delegate=` mode (`print` default, `run`).

## Critique change

Read [critique/SKILL.md](../critique/SKILL.md).

- In **Step 1 ("Detect review context")**, select explicit **change mode**. Override **Change mode / Resolve the diff** to review the whole branch plus working tree, not only the latest commit or `git diff HEAD`. `<skill-dir>` is the absolute directory of [SKILL.md](SKILL.md).

```bash
bash <skill-dir>/../commit/scripts/git-preflight.sh state
bash <skill-dir>/../commit/scripts/git-preflight.sh fingerprint
```

Review base, fetch failure, and exclusions: [SKILL.md](SKILL.md) Stage 5.

- Disable **After execute-plan or a converged delegate PASS** as a reason to skip the closing pass or the security pass. Phase A skip: [SKILL.md](SKILL.md) Stage 5. Run **Final `/critique change`** (one top-tier closing pass when ship-ready) except when Stage 5 skips it: Phase A skipped on a fingerprint match and Stage 4's final review a clean `top@*`. Preserve separate read-only reviewers and fix agents, the two-top-pass ceiling, and the stop rule for remaining blocking or unresolved important findings.
- Run **Security pass (change mode)** once, using platform `security-review` when available or the skill's trust-boundary fallback. Do not take its docs-only skip under `/conduct`; unattended commit/push/PR authority remains a security-sensitive boundary.
- After critique fixes, the conductor re-runs the plan's **Verification** commands, including after closing-pass fixes (re-checked by critique). Report the results separately from review convergence; verification does not replace a review or authorize another review loop. Any failed verification or remaining blocking/unresolved important finding triggers the conductor's downgrade rule and prevents commit.
