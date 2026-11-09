---
name: conduct
description: >-
  Conduct an idea through brainstorm, make-plan, critique plan, execute-plan,
  and critique change, then branch, commit, push, or open a PR per the chosen
  finish mode. Args: [idea | docs/brainstorms/<f>.md | docs/plans/<f>.md]
  [finish=push|pr|none] [plan=keep|drop] [confirm=yes|no] [runner=<policy>].
  Use when the user asks for the whole lifecycle chain or mentions /conduct.
disable-model-invocation: true
---

# conduct

Take an idea to a reviewed change through the sibling lifecycle skills, with two human gates and an up-front finish mode. Resume from a saved brainstorm or plan instead of restarting. This is a thin conductor: read each sibling skill and follow it in-session, applying only the linked overrides. The siblings disable model invocation; do not invoke them as slash commands.

**References (read when needed):** [stage-overrides.md](stage-overrides.md) (stage-specific differences) | [finish.md](finish.md) (branch, commit, push, PR) | [model-tiers.md](../make-plan/model-tiers.md) (tier resolution)

## Preconditions

**Requires Agent mode.** In Plan or Ask mode, stop and tell the user to switch before continuing.

**Session needs top-plan.** Resolve via [model-tiers.md](../make-plan/model-tiers.md). Warn once and recommend switching if below **top-plan**; do not silently run a thin brainstorm or plan. A top-plan session also meets **top-review** for the execute orchestrator. Do not repeat the warning at each stage. Preserve each sibling's independent-review and explicit Task-model requirements; report intended tier and resolved model, never an invented resolution.

Work in the project root (`git rev-parse --show-toplevel`). The up-front `finish=push` or `finish=pr` choice is the user's explicit request to commit/push under this skill, subject to Gate B, safety checks, and the downgrade rule. It is not permission to bypass a failed gate.

## Step 0 - Router

Parse and remove `finish=`, `plan=`, `confirm=`, and `runner=` before routing the remaining argument. Keep the runner policy for Stage 2. Resolve paths with `Read`/`Glob`; never guess a file. A `*.notes.md` file is not a plan. Missing, ambiguous, or unsupported artifact status: ask before proceeding.

| Argument / artifact | Start at |
| --- | --- |
| `docs/plans/*.md`, `execution.status: not-started` | Stage 3 |
| `docs/plans/*.md`, `execution.status: in-progress`, `partial`, or `failed` | Stage 4, resuming the existing plan |
| `docs/plans/*.md`, `execution.status: completed` | Stage 5 |
| `docs/brainstorms/*.md` | Stage 2, using the file's saved `/make-plan` prompt as arguments |
| Free text or no argument | Stage 1 |

Read `execution.status` from YAML frontmatter, not the execution-log table. When routing an existing plan, read its Purpose, Scope, Assumptions, Execution map, Verification, Success criteria, and Risks before continuing. Keep the artifact path for the later stages.

**Resume approval:** For any resumed plan (`in-progress`, `partial`, `failed`, or `completed`), before Step 0.6 uses its **Files** column and before any stage runs, run the plan lock exactly as written in [execution-status.md](../execute-plan/execution-status.md#plan-lock) section **Plan lock**: `eval` the code block between the `plan-sha` markers and compare `plan_sha <path>` to frontmatter `plan_sha`; do not reimplement the hash. A present, matching `plan_sha` counts Gate B as previously passed; continue to the routed stage without re-running ideation or asking for approval of unchanged executed work. Missing `plan_sha` (legacy plan) does **not** pass Gate B: present the plan at Gate B for explicit approval before continuing to the routed stage. A mismatch is a **hard stop**: `plan body changed since approval; re-approve with /make-plan update <path>`; no stage runs and nothing is committed. Otherwise Gate B remains mandatory; no argument can bypass it.

## Step 0.5 - Up-front choices

Before any stage runs, ask all unanswered choices in **one `AskQuestion` batch** (otherwise ask conversationally). Skip only choices already supplied by arguments:

- **Finish:** `push` (default: feature branch + commit + push), `pr` (push + PR + CI watch), or `none` (stop ready-to-PR, uncommitted).
- **Plan file:** `keep` (default: include eligible plan files in the commit) or `drop` (leave them uncommitted; do not delete them).
- **Confirm before commit:** `no` (default: no further commit approval) or `yes` (show the proposed commit and ask once before committing).

State the defaults and their effects, especially commit/push authority. Choices live **in chat only**: never write them into the plan body, which would break the plan lock. A resumed invocation asks again for choices not given in its arguments; do not infer finish permission from a saved plan.

## Step 0.6 - Preflight + baseline

Complete all checks before running any stage, including on resume:

1. **Default branch and access.** Resolve the default with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`; fall back to `git symbolic-ref --short refs/remotes/origin/HEAD` and strip `origin/`. Do not assume `main` or `master`. For `finish` other than `none`, `git remote get-url origin` must succeed; for `finish=pr`, `gh auth status` must also succeed. If the default cannot be established or required access is unavailable, tell the user **now** and set `finish=none`, rather than discovering the problem after implementation.
2. **Baseline and ownership.** Record the HEAD SHA (`git rev-parse HEAD`), current branch, and `git status --porcelain`, including staged and untracked paths. **Conductor-owned paths** are `docs/brainstorms/**`, `docs/plans/**`, and, when the router resumed an existing plan whose plan lock matched (Step 0), every path in that plan's Execution-map **Files** column. Every other dirty path is **foreign**. Show those paths and ask **stash / continue with `finish=none` / abort**. Stash only on explicit selection and preserve the stash; continue means preserve the files, never stage them; abort stops the run. Retain the baseline foreign-path list for execution and finishing. Later work must not retroactively authorize foreign changes.
3. **Existing branch history.** With `origin` and a known default, run `git fetch origin <default>` before comparing. If on a non-default branch with commits ahead of `origin/<default>`, count them and ask once: **reuse `<branch>` (its N existing commits ship too) / continue with `finish=none` / abort**. Do not silently publish those commits. If the comparison cannot be established, report it and use `finish=none`; do not claim the branch is safe to publish.

Ownership is permission to continue, not a staging allowlist: brainstorms, secrets, foreign files, and ineligible/dropped plans remain excluded at finish. Keep baseline evidence in chat, not the locked plan body.

## Stage 1 - Brainstorm

`Read` [../brainstorm/SKILL.md](../brainstorm/SKILL.md) and follow it with [stage-overrides.md](stage-overrides.md#brainstorm) section **Brainstorm**.

Pass the idea as arguments, or let the sibling gather it when absent. Preserve the Goal brief, roadmap, saved artifact, and verbatim handoff prompt. If its **When NOT to brainstorm** decision selects planning, continue to Stage 2 with the one-line prompt under the override; do not offer built-in Plan.

### Gate A

After the brainstorm is persisted, replace the sibling's next-step offer with:

- **Refine** - return to brainstorming; preserve and update the same artifact.
- **Continue to plan** - pass the saved `/make-plan` prompt to Stage 2.
- **Stop** - stop with the saved artifact and final summary; nothing to finish.

Wait for the user's choice. Skip this gate only when routing directly to a later stage or taking the sibling's explicit planning path; report why.

## Stage 2 - Make-plan

`Read` [../make-plan/SKILL.md](../make-plan/SKILL.md) and follow it with [stage-overrides.md](stage-overrides.md#make-plan) section **Make-plan**.

Arguments are the brainstorm handoff prompt (including when resumed from its saved file), or the user's text on the direct planning path. Forward `runner=<policy>` when given. Capture the plan path, keep its lock metadata intact, and proceed to Stage 3 instead of offering standalone next steps. This stage never implements.

## Stage 3 - Critique plan

`Read` [../critique/SKILL.md](../critique/SKILL.md) and follow it in **plan mode** on the plan path with [stage-overrides.md](stage-overrides.md#critique-plan) section **Critique plan**.

Skip the critique only when the plan records `Plan size: small`; record that reason. Any plan edits follow the sibling's re-stamping rules. Show the critique verdict and remaining items at Gate B; a Rework verdict recommends **Refine**, not silent execution.

### Gate B

**Hard approval gate, never skipped by arguments.** Present the final plan (including any critique edits), its path, verdict/remaining items or small-plan skip, and current finish choices. Ask:

- **Approve** - approve this plan and enter Stage 4.
- **Refine** - follow Stage 2 in make-plan **update** mode on the same path, then return to Stage 3 and this gate.
- **Abort** - stop; no implementation, commit, push, or other finish action.

Wait for explicit approval. An existing plan's approval stamp alone is not this gate. Only the router's already-executed-plan resume rule counts Gate B as previously passed, and only with a matching plan lock.

## Stage 4 - Execute-plan

**On entry, before execution**, whether arriving from Gate B **or the resume router**, if `finish` is not `none`, read and follow [finish.md](finish.md#branch) section **Branch** to ensure a non-default feature branch. If `finish=none`, do not create a branch on the conductor's behalf.

`Read` [../execute-plan/SKILL.md](../execute-plan/SKILL.md) and follow it on the plan path with [stage-overrides.md](stage-overrides.md#execute-plan) section **Execute-plan**.

Let the sibling validate the plan lock, orchestrate its Execution map, persist execution status, verify, and perform independent review; do not implement the plan in the conductor. Replace its concluding offers with Stage 5 only after the completion/review checks pass.

Read the terminal `execution.status` and final top-tier review result. An unfinished `delegate:*` dispatch or final review deferred to `/delegate:review` leaves the run `partial`: print the sibling's Dispatch lines and apply the downgrade rule, not an automatic commit to unblock delegation.

## Stage 5 - Critique change

`Read` [../critique/SKILL.md](../critique/SKILL.md) and follow it in **change mode** with [stage-overrides.md](stage-overrides.md#critique-change) section **Critique change**.

Review the whole branch plus working tree, not only this session's last edit: fetch `origin/<default>` and use `git diff <merge-base>`, where `<merge-base>` is `git merge-base origin/<default> HEAD`; without `origin`, use the Step 0.6 HEAD SHA as base. Include untracked files from `git ls-files --others --exclude-standard`. Exclude `docs/brainstorms/**` and `docs/plans/**`.

The **After execute-plan or a converged delegate PASS** skip is disabled: run Phase A (at most two mid-tier reviews), Phase B (at most one top-tier escalation when triggered), and the top-tier closing pass when ship-ready. Run the security pass too, using the sibling's platform tool or inline fallback; do not take a docs-only security skip for this unattended commit/push trust boundary. Keep reviewers separate from implementers/fix agents.

After critique fixes, re-run the plan's **Verification** commands, including after closing-pass fixes that the sibling otherwise labels unverified. Preserve the review budgets; verification does not authorize another review loop. Any remaining `blocking` or unresolved `important`, or a verification failure, invokes the downgrade rule.

## Stage 6 - Finish

Apply the downgrade checks **before staging or committing**. For a Stage 5 resume, inspect the saved execution/review evidence too; do not infer clean review from `completed` alone.

- `finish=none`: stop ready-to-PR if checks are clean, leaving changes uncommitted. Report any unfinished work instead of calling it ready.
- `finish=push`: follow [finish.md](finish.md#commit) section **Commit**, then [finish.md](finish.md#push) section **Push**, sequentially.
- `finish=pr`: follow **Commit**, then **Push**, then [finish.md](finish.md#pull-request) section **Pull request**, including CI watch.

The linked finish rules own branching, staging exclusions, the single Conventional Commit, `plan=keep|drop`, and optional `confirm=yes` approval. Do not reintroduce standalone split/version/CHANGELOG/README offers. With `confirm=no`, do not add routine prompts after Gate B; safety stops and downgrades still apply. A push rejection stops the run without pull/rebase/force; CI failures are investigated and reported, never auto-fixed.

## Downgrade rule

Set **`finish=none`**, stop before commit, preserve the working tree, and report why if any condition holds:

- Execute-plan's terminal status is not `completed`.
- The final top-tier execution review is `dirty` or `deferred`.
- Critique change leaves any `blocking` or unresolved `important` finding.
- The plan's Verification fails after critique fixes.
- A commit hook rejects the commit: no retry, amend, or hook bypass.
- The current branch is the default branch at Stage 6.

Do not treat missing review evidence as a clean result. A downgrade never converts failure into success or authorizes a partial commit. If a failure occurs after a commit/push already succeeded, report the actual state; do not imply it was undone.

## Final summary

On completion, stop, or downgrade, report concisely:

- Stages run and skipped, with reasons; brainstorm/plan artifact paths.
- Model per stage and per subagent: intended tier plus resolved model.
- Execution status, review verdicts, remaining findings, and Verification results.
- Branch, commit SHA (or not committed), push result (or not pushed).
- PR URL and CI state when applicable; no merge.
- Downgrade reason, any Dispatch lines, and the next safe action if unfinished.

## Safety (never)

- Commit or push to the default branch.
- Force-push, use `--no-verify`, or amend.
- Commit `docs/brainstorms/**` or secret/credential files.
- Stage foreign paths identified in Step 0.6, or include pre-staged foreign content in the conductor's commit.
- Bypass plan approval/lock, independent review, failed verification, or a downgrade to satisfy the requested finish mode.
- Delete dropped plans, discard foreign work, auto-fix CI, or merge a PR.
