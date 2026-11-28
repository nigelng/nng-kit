---
name: conduct
description: >-
  Conduct an idea through brainstorm, make-plan, critique plan, execute-plan,
  and critique change, then branch, commit, push, or open a PR per the chosen
  finish mode. Args: [idea | docs/brainstorms/<f>.md | docs/plans/<f>.md]
  [finish=push|pr|commit|none] [delegate=run|print] [plan=keep|drop] [confirm=yes|no] [runner=<policy>]
  [unattended=yes|no] [launcher=<name>].
  Use when the user asks for the whole lifecycle chain or mentions /conduct.
disable-model-invocation: true
---

# conduct

Take an idea to a reviewed change via sibling skills, two human gates, and an up-front finish mode. Thin conductor: read and follow each sibling in-session with only the linked overrides; siblings disable model invocation (never invoke as slash commands).

**References (read when needed):** [stage-overrides.md](stage-overrides.md) | [finish.md](finish.md) | [unattended.md](unattended.md) | [model-tiers.md](../make-plan/model-tiers.md)

`<skill-dir>` is this file's absolute directory; `<exec>` is `<skill-dir>/../execute-plan/scripts`. Sibling `model-tiers.md` and `execution-status.md` copies are identical; read each once.

## Preconditions

**Requires Agent mode.** In Plan or Ask mode, stop and tell the user to switch.

**Session needs top-plan.** Warn once and recommend switching if below the host's **top-plan** pin (`tiers.sh resolve <host> top-plan`); unknown session model → say so in one line, continue. A top-plan session meets **top-review** for the execute orchestrator. Preserve each sibling's independent-review requirements (with `/critique plan`'s Devin in-session fallback) and explicit Task-model requirements; report intended tier and resolved model, never an invented resolution.

Work in the project root (`git rev-parse --show-toplevel`). The up-front `finish=push`, `pr` or `commit` choice is the user's explicit request to commit/push under this skill, subject to Gate B, safety checks, and the downgrade rule, and never permission to bypass a failed gate.

## Step 0 - Router

Parse and remove `finish=`, `delegate=`, `plan=`, `confirm=`, `runner=`, `unattended=` (default `no`), and `launcher=` before routing the remaining argument. Keep `runner=` for Stage 2 and `launcher=` for Gate B. When `unattended=yes`, read [unattended.md](unattended.md) first and follow its contract. Resolve paths with `Read`/`Glob`; never guess a file. A `*.notes.md` file is not a plan. Missing, ambiguous, or unsupported artifact status: ask first.

| Argument / artifact | Start at |
| --- | --- |
| `docs/plans/*.md`, `execution.status: not-started` | Stage 3, unless **Fresh Gate B** below passes |
| `docs/plans/*.md`, `execution.status: in-progress`, `partial`, or `failed` | Stage 4, resuming the existing plan |
| `docs/plans/*.md`, `execution.status: completed` | Stage 5 |
| `docs/brainstorms/*.md` | Stage 2, using the file's saved `/make-plan` prompt as arguments |
| Free text or no argument | Stage 1 |

Read `execution.status` from YAML frontmatter, not the execution-log table. When routing an existing plan, read its Purpose, Scope, Assumptions, Execution map, Verification, Success criteria, and Risks before continuing.

**Fresh Gate B (`not-started` only),** before Step 0.6: `bash <exec>/plan-status.sh lock --gate <plan>`. Pass only on exit 0 **and** ISO-8601Z stdout (`YYYY-MM-DDTHH:MM:SSZ`): print as `gate_b_at`, start at Stage 4. Stderr starting `REFUSE: plan handed off` (on any `lock`/`approve` call) is a **hard stop on every route** (quote stderr verbatim; never stay at Stage 3). Any other non-pass (mismatch, missing `gate_b_sha`/`plan_sha`, exit 2, other stdout) stays at Stage 3 (show stderr; not the resume hard stop). Never hand-edit `plan_sha`/`gate_b_sha`.

**Resume approval** (`in-progress`/`partial`/`failed`/`completed`), before Step 0.6 uses **Files** and any stage: `bash <exec>/plan-status.sh lock <plan>`. Exit 0 (`ok`): Gate B passed; do not re-run ideation or re-approve unchanged executed work. Exit 3: hard stop; quote stderr verbatim (handed off, body changed, or unstamped; re-approve/stamp via `/make-plan update <path>`); no stage runs and nothing is committed. Exit 2: stop, show stderr. No argument bypasses Gate B.

## Step 0.5 - Up-front choices

Before any stage runs, run `bash <exec>/tiers.sh policy` once (exit 2 → fall back to strict defaults and say why, showing stderr). Print `policy: <relaxed list|none> (<source>)` (e.g. `policy: none (shipped)`). Precedence is `CLI args > user config defaults > skill default`; `defaults` pre-fill unanswered choices.

Ask unanswered choices in **one batch** via the question tool (`AskQuestion`/`AskUserQuestion`/`ask_user_question`) if available, else conversationally. Skip choices supplied by args; when `relax.skipChoicePrompt` is true, also skip choices covered by `defaults`:

- **Finish:** `push` (default: feature branch + commit + push), `pr` (push + PR + CI watch), `commit` (feature branch + local commits; no push or PR), or `none` (stop ready-to-PR, uncommitted).
- **Delegate** (only when `CLAUDECODE=1`; else `print`): `print` (default) or `run` = explicit consent per `delegate-loop.md` (via stage-overrides.md § Execute-plan): headless dangerous-flag backends, repo sent to the backend vendor, local checkpoint commits before Stage 5. Needs `finish` other than `none`, else `print` + reason. `delegate=run` from args or `defaults` is explicit consent; still state these effects (including repo sent to delegate vendors) once.
- **Plan file:** `keep` (default: include eligible plan files in the commit) or `drop` (leave them uncommitted; do not delete them).
- **Confirm before commit:** `no` (default: no further commit approval) or `yes` (show the proposed commit and ask once before committing).

State defaults and their effects, especially commit/push authority. Choices live **in chat only**: never write them into the plan body, which would break the plan lock. A resumed invocation asks again for choices not covered by args (or `defaults` when `relax.skipChoicePrompt` is true); do not infer finish permission from a saved plan.

## Step 0.6 - Preflight + baseline

Complete all checks before running any stage, including on resume:

1. **Default branch and access.** Resolve the default with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`; fall back to `git symbolic-ref --short refs/remotes/origin/HEAD` and strip `origin/`. Do not assume `main` or `master`. For `finish` other than `none`, `git remote get-url origin` must succeed; for `finish=pr`, `gh auth status` must also succeed. If the default cannot be established or required access is unavailable, tell the user **now** and set `finish=none`.
2. **Baseline and ownership.** Record the HEAD SHA (`git rev-parse HEAD`), current branch, and `git status --porcelain`, including staged and untracked paths. **Conductor-owned paths** are `docs/brainstorms/**`, `docs/plans/**`, and, when resume `lock` printed `ok`, every path in that plan's Execution-map **Files** column. Every other dirty path is **foreign**. Show those paths and ask **stash / continue with `finish=none` / abort**. Stash only on explicit selection and preserve the stash; continue means preserve the files, never stage them; abort stops the run. Retain the baseline foreign-path list for execution and finishing. Later work must not retroactively authorize foreign changes.
3. **Existing branch history.** With `origin` and a known default, run `git fetch origin <default>` before comparing. If on a non-default branch with commits ahead of `origin/<default>`, count them: when `relax.reuseAheadBranch` is true, reuse `<branch>` without asking and report the N existing commits that will ship; otherwise ask once: **reuse `<branch>` (its N existing commits ship too) / continue with `finish=none` / abort**. Do not silently publish those commits. If the comparison fails, report it and use `finish=none`.

Ownership is permission to continue, not a staging allowlist: brainstorms, secrets, foreign files, and ineligible/dropped plans remain excluded at finish. Keep baseline evidence in chat, not the locked plan body.

## Stage 1 - Brainstorm

`Read` [../brainstorm/SKILL.md](../brainstorm/SKILL.md) and follow it with [stage-overrides.md](stage-overrides.md#brainstorm).

Pass the idea as arguments, or let the sibling gather it when absent. Preserve the Goal brief, roadmap, saved artifact, and verbatim handoff prompt. If its **When NOT to brainstorm** decision selects planning, continue to Stage 2 with the one-line prompt under the override.

### Gate A

After the brainstorm is persisted, replace the sibling's next-step offer with:

- **Refine** - return to brainstorming; preserve and update the same artifact.
- **Continue to plan** - pass the saved `/make-plan` prompt to Stage 2.
- **Stop** - stop with the saved artifact and final summary; nothing to finish.

Wait for the choice. Skip this gate only when routing directly to a later stage or taking the sibling's explicit planning path; report why.

## Stage 2 - Make-plan

`Read` [../make-plan/SKILL.md](../make-plan/SKILL.md) and follow it with [stage-overrides.md](stage-overrides.md#make-plan).

Arguments are the brainstorm handoff prompt (including when resumed from its saved file), or the user's text on the direct planning path. Forward `runner=<policy>` when given. Capture the plan path, keep its lock metadata intact, and go to Stage 3 instead of offering standalone next steps.

## Stage 3 - Critique plan

`Read` [../critique/SKILL.md](../critique/SKILL.md) and follow it in **plan mode** on the plan path with [stage-overrides.md](stage-overrides.md#critique-plan).

Skip the critique only when the plan records `Plan size: small`; record that reason. Any plan edits follow the sibling's re-stamping rules. A Rework verdict recommends **Refine** at Gate B, not silent execution.

### Gate B

**Hard approval gate, never skipped by arguments.** Present a short summary, not the full plan: Purpose, Scope, the Execution map table, the critique verdict and remaining items (or the small-plan skip), and the current finish choices, plus the plan path. Ask:

- **Approve** - `not-started`: run `approve`, then offer the continue choice.
- **Refine** - follow Stage 2 in make-plan **update** mode on the same path, then return to Stage 3 and this gate.
- **Abort** - stop; no implementation, commit, push, or other finish action.

Wait for explicit approval. An approval stamp alone is not this gate. Already passed only when resume `lock` printed `ok`, or **Fresh Gate B** printed `gate_b_at`.

`bash <exec>/plan-status.sh approve <plan>`. Exit 0 writes `gate_b_sha` and `gate_b_at`; never hand-edit them or `plan_sha`. Exit 3 writes nothing: quote stderr verbatim (handed off → hard stop; body changed → `/make-plan update <path>`; no `plan_sha` → **Refine** so `stamp` runs, then return). Exit 2: stop, show stderr. After exit 0, `defaults.continue` (`here|fresh|unattended`, from `tiers.sh policy`) pre-fills the choice below; skip asking only when `relax.skipChoicePrompt` is true. An `unattended` pre-check refusal stops with its reason — never fall back to `here` or `fresh`:

- **Continue here** - Stage 4 in this session.
- **Continue in a fresh session** - recommended unless `Plan size: small`; on a v2 map passing `plan-status.sh rows --lint`, a `mid` session suffices for Stage 4. Print `/conduct <path> finish=<finish> plan=<keep|drop> confirm=<confirm> delegate=<d>` and stop. Starts at Stage 4 only when `lock --gate` passes.
- **Continue unattended** - follow [unattended.md](unattended.md#gate-b) (checks eligibility, creates sibling worktree, stamps `handoff_run` on main-tree plan, launches `/conduct … unattended=yes` on `mid`, and stops).

## Stage 4 - Execute-plan

**On entry, before execution**, from **Continue here**, a passing `lock --gate`, or the resume router: if `finish` is not `none`, follow [finish.md](finish.md#branch) **Branch**. If `finish=none`, do not create a branch.

`Read` [../execute-plan/SKILL.md](../execute-plan/SKILL.md) and follow it with [stage-overrides.md](stage-overrides.md#execute-plan). Do not implement in the conductor.

On a clean final review (`clean`, including the in-host loop when the strongest Review is `mid` or `none`) with `execution.status` `completed`, record in chat, not the plan: `bash <skill-dir>/../commit/scripts/git-preflight.sh fingerprint` (`fingerprint=` and `head=`); `delegate=run`: after the loop's last delegate wave and final review, with every carried review PASSed (`delegate-loop.md` Fingerprint). On `dirty`, `partial`, or `failed`, record nothing and stop before Stage 5.

## Stage 5 - Critique change

`Read` [../critique/SKILL.md](../critique/SKILL.md) and follow it in **change mode** with [stage-overrides.md](stage-overrides.md#critique-change).

`state` fetches `origin` when a remote URL exists. Stderr `WARN: git fetch failed`, or a failed `git merge-base origin/<default> HEAD`, stops this stage and triggers the downgrade rule. Never use a stale or narrower diff. `<default>` is the Step 0.6 branch; `default=` from `state` may be empty and does not replace it. The review base is that merge-base SHA. With no `origin`, the base is the HEAD SHA recorded at Step 0.6. Pass the base ref to each review Task. The Task (Devin: the session, per hosts.md) runs `git diff <base>` and lists untracked files from `git ls-files --others --exclude-standard`. Do not paste the diff. Exclude `docs/brainstorms/**`, `docs/plans/**` and `.claude/tmp/**` from the tracked diff and from the untracked input. Stage 5 compares `fingerprint=` and `head=` with Stage 4's recorded fingerprint.

Skip **Phase A** only when all three hold: this session recorded Stage 4's `fingerprint=` and `head=`; a new `fingerprint` run prints the same values; and `head=` equals that review base. Otherwise run **Phase A** (at most two lean rounds) and **Phase B** (at most one top-tier escalation, only when triggered). A skipped Phase A counts as ship-ready, so Phase B is not triggered. When Phase A is skipped and Stage 4's final review was a clean `top@*`, skip the closing top pass and run only the security pass. Keep the closing top pass when Stage 4's strongest review was `mid` or `none`. The security pass always runs.

## Stage 6 - Finish

Apply the downgrade checks **before staging or committing**. For a Stage 5 resume, inspect the saved execution/review evidence too; do not infer clean review from `completed` alone.

- `finish=none`: stop ready-to-PR if checks are clean, leaving changes uncommitted. Report unfinished work, never as ready.
- `finish=push`: follow [finish.md](finish.md#commit) **Commit**, then [finish.md](finish.md#push) **Push**, sequentially.
- `finish=pr`: follow **Commit**, then **Push**, then [finish.md](finish.md#pull-request) **Pull request**, including CI watch.
- `finish=commit`: follow **Commit** only; report the branch and SHAs, not pushed.

## Downgrade rule

Set **`finish=none`**, stop before any further commit, preserve the working tree, and report why if any holds:

- Execute-plan's terminal status is not `completed` (`delegate=run`: after its loop).
- The final execution review is `dirty`, or status is `partial` after `terminal --deferred-review` (a printed `/delegate:review` line) under `delegate=print` or when the delegate loop cannot resolve it.
- Critique change leaves any `blocking` or unresolved `important` finding.
- The plan's Verification fails after critique fixes.
- A delegate-loop stop (`delegate-loop.md`).
- Stage 5 cannot resolve its review base (failed `git fetch` or `git merge-base`).
- A commit hook rejects the commit: no retry, amend, or hook bypass.
- The current branch is the default branch at Stage 6.

Do not treat missing review evidence as a clean result. A downgrade never converts failure into success or authorizes a new partial commit. Commits that already exist (conductor checkpoints under `delegate=run`, or a push) are reported, never implied undone.

## Final summary

On every completion, stop, or downgrade, follow [finish.md](finish.md#final-summary).

## Safety (never)

- Commit or push to the default branch.
- Force-push, use `--no-verify`, or amend.
- Commit `docs/brainstorms/**` or secret/credential files.
- Stage foreign paths identified in Step 0.6, or include pre-staged foreign content in the conductor's commit.
- Bypass plan approval/lock, independent review (`/critique plan`'s Devin fallback is not a bypass), failed verification, or a downgrade to satisfy the requested finish mode.
- Delete dropped plans, discard foreign work, auto-fix CI, or merge a PR.

Guardrail policy (`.conduct`) cannot relax any item in **Safety (never)**.
