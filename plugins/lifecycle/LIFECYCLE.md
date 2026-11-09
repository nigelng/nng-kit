# L0 lifecycle skills

These skills form the shared "idea → shipped" chain. They live in the `nng-kit`
marketplace (`plugins/lifecycle/skills/<name>/`), which is the source of truth.
Editing a skill means editing it **here**, never in an installed copy.

## Install

| Surface | How it gets the skills | Invoke as |
| --- | --- | --- |
| Claude Code (local or cloud) | `claude plugin marketplace add nigelng/nng-kit` then `claude plugin install lifecycle@nng-kit` | `/lifecycle:<name>` |
| Devin CLI/Desktop | `devin plugins install -y --local <nng-kit>/plugins/lifecycle` (once per Devin data home) | `/lifecycle:<name>` |
| Cursor | Imports plugins installed in Claude Code (enable Third-Party Imports in settings) | `/lifecycle:<name>` |
| Antigravity | `agy plugin install <nng-kit>/plugins/lifecycle` | `/lifecycle:<name>` |
| Windsurf / other agents | Each skill dir linked into the tool's skills dir from a store location the tools do not scan, as a fallback when no plugin is installed | `/<name>` |
| Devin Cloud / consumer repos | Vendored real files under `<repo>/.agents/skills/` from a `lifecycle-v*` tag: `bash plugins/lifecycle/scripts/vendor-skills.sh <repo>` (in an nng-kit checkout). Drift is gated by the `nigelng/nng-kit/plugins/lifecycle/ci/vendor-check@lifecycle-vX.Y.Z` composite action — it fails CI when a vendored copy differs from its stamped tag. Re-vendor after a new tag. | `/<name>` |

The SKILL.md files use only relative links to sibling files and no plugin-only
syntax, so the same directory works on every surface.

`/delegate:execute-via-cursor` (needs the Cursor `agent` CLI),
`/delegate:execute-via-agy` (needs the Antigravity `agy` CLI),
`/delegate:execute-via-devin` (needs the Devin CLI) and `/delegate:review`
(the plan's Review runner — host session, read-only Task, or an external
read-only reviewer) are separate skills in the `delegate` plugin and are
**not** part of this plugin. They are described below because they write the
same plan audit metadata as `/execute-plan`.

## The chain

```
/brainstorm [idea]                 top-tier session; read-only; adaptive Goal brief
  → docs/brainstorms/**              (extract → ask gaps → never empty), explores
  → /make-plan handoff prompt        feasibility, iterates with the user, then emits a
                                       roadmap + a ready-to-paste /make-plan prompt

/make-plan [update] [task]         top-tier planner; interview-first for Goal/requirements
  → docs/plans/**                     when no brainstorm handoff; drafts a structured plan
                                       with an Execution map v2 (top/execute/mid/low
                                       tiers, waves; Dispatch run order)

/critique plan <path>              optional top-tier second opinion on the plan before
  (optional)                          execute (not a lean mid-tier pass)

/execute-plan <path>               top-tier orchestrator; requires Agent mode; refuses
  → uncommitted working-tree diff     if Blocked / missing Success or Verification;
                                       requires Execution map (draft→confirm→persist if
                                       missing); runs waves per ## Dispatch
                                       (execute/low implementers; mid review passes;
                                       top-tier final pass, until clean)

/delegate:execute-via-cursor <path>  Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Cursor `agent` CLI implements (default tier
                                       `execute` pin when `model=` omitted; Auto only as a
                                       logged fallback); Claude gates, briefs, reviews
                                       (bounded FIX loop). Not an L0 multi-consumer skill —
                                       see Claude-only install note below. Prefer when you
                                       want Cursor to code and Claude to review; keep
                                       `/execute-plan` for in-process Task waves.

/delegate:execute-via-agy <path>    Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Antigravity `agy` CLI implements (default tier
                                       `execute` pin when `model=` omitted; Auto only as a
                                       logged fallback); Claude gates, briefs, reviews
                                       (bounded FIX loop). Same contract as
                                       `/delegate:execute-via-cursor`, different backend.

/delegate:execute-via-devin <path>  Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Devin CLI implements (default Devin `execute` pin
                                       from model-tiers when `model=` omitted; pinned only,
                                       never `adaptive` or `fusion-*`); Claude gates,
                                       briefs, reviews (bounded FIX loop). Same contract as
                                       `/delegate:execute-via-cursor`, different backend.

/delegate:review <plan> [ID]        Claude Code–only (`delegate` plugin):
  → plan audit metadata                final whole-branch top-tier review through the
                                       plan's Review runner (read-only; the reviewer
                                       never runs Verification); `/execute-plan`
                                       defers to it when the Review runner is an
                                       external tool other than the host

/critique change [ref]             lean mid-tier diff rounds + final top-tier change
  (optional)                          critique; security pass (Cursor/Claude
                                       security-review when available); after a
                                       converged execute-plan review skip lean and
                                       skip the closing final pass by default; still
                                       run security unless docs-only

/commit                            low-tier default; classifies the diff, drafts a
  → local commit(s)                   Conventional Commit, optionally bumps
                                       version/CHANGELOG, commits only after approval
                                       (use mid-tier for large mixed splits); may stage
                                       tracked-eligible `docs/plans/**` with the feature
                                       (`docs/brainstorms/**` never)

/gh-create-pr                      planning-artifacts gate (Keep/Drop per plan and relay
  → pull request                      file on the branch), then ensures a feature branch,
                                       pushes, opens a PR via `gh`, and watches CI
                                       (investigates failures; does not auto-fix without
                                       approval; never commits or deletes artifacts itself)

/gh-draft-release                  drafts a GitHub Release with generated notes from
  → draft GitHub Release              unreleased commits; does not tag or publish

/gh-tag-release                    dates the changelog and pushes a release tag to
  → git tag + publish CI              trigger the publish workflow; does not create a
                                       GitHub Release (the workflow does)
```

`gh-draft-release` and `gh-tag-release` are alternatives, not a sequence — pick one
depending on whether the repo's release process is "draft notes for manual publish"
or "tag to trigger CI publish."

## Execute alternatives

- **`/execute-plan`** — in-process Task orchestrator (Execution-map waves +
  independent review: mid-tier passes, top-tier final pass). Multi-consumer L0
  skill.
- **`/delegate:execute-via-cursor`** — Claude Code–only, in the `delegate` plugin:
  hands the plan to Cursor's `agent` CLI for implementation (when `model=` is
  omitted, resolves the Cursor `execute` pin from [model-tiers.md](model-tiers.md);
  Auto only as a logged fallback); Claude writes the brief, reviews against Base SHA +
  Verification, and may FIX-resume ≤2 times. Never commits (offer `/commit`).
  Not linked into `~/.agents/skills` or Cursor/Devin/Windsurf.
- **`/delegate:execute-via-agy`** — Claude Code–only, in the `delegate` plugin:
  same contract as `/delegate:execute-via-cursor`, but Google's Antigravity `agy`
  CLI does the implementing (default `execute` pin from [model-tiers.md](model-tiers.md)
  when `model=` omitted; Auto only as a logged fallback). Never commits.
- **`/delegate:execute-via-devin`** — Claude Code–only, in the `delegate` plugin:
  same contract as `/delegate:execute-via-cursor`, but the Devin CLI does the
  implementing (default Devin `execute` pin from [model-tiers.md](model-tiers.md)
  when `model=` omitted; pinned only — never `adaptive` or `fusion-*`). Never commits.
- **`/delegate:review`** — Claude Code–only, in the `delegate` plugin: the final
  whole-branch top-tier review through the plan's Review runner
  (`top@session`, `top@claude-task`, `top@devin-fusion`, `top@cursor-ask`, or
  `top@agy-plan`). Read-only — the reviewer never runs Verification and never
  edits (a git guard reverts any reviewer change). `/execute-plan` prints the
  `/delegate:review` command when a plan's Review runner is an external tool
  other than the host; pass `[ID]` to mark that row done via
  `plan-status.sh review`. Never commits.

## Ideate vs plan (three-way split)

- **`/brainstorm`** — open-ended ideation: multiple approaches, feasibility unknown,
  Goal brief + roadmap. Persists to `docs/brainstorms/**`. Always a **top-tier**
  session (same model bar as `/make-plan`).
- **`/make-plan`** — scope already clear (or after brainstorm handoff); durable
  step-by-step plan under `docs/plans/**` for execute/critique and cross-session
  handoff. Always a **top-tier** planner session. When there is no brainstorm
  artifact, interviews for Goal, requirements, non-goals, and constraints before
  drafting. Plans include an **Execution map** v2 (waves; tiers `top` /
  `execute` / `mid` / `low`; **Runner**, **Files**, **Acceptance**, **Review**;
  optional **Model**), a **`## Dispatch`** run order, and `docs/plans/**` files
  named `YYYY-MM-DD-<slug>.md` with plan-lock metadata (`created_at`, `plan_sha`,
  `approved_at`). Map routing, recency (`created_at`, then filename, then mtime),
  and the body hash live in
  [skills/execute-plan/execution-status.md](skills/execute-plan/execution-status.md)
  (Plan metadata / Plan lock / Plan recency) — do not restate here. Biased to
  smallest mechanical units / prefer **low** tier. Plans may be committed with the feature (`/commit`
  when tracked-eligible); `/gh-create-pr` asks **Keep/Drop** per plan on the
  branch so `main` does not accumulate stale plans.
- **Built-in Plan** (Cursor Plan mode / Claude Code `/plan`) — same "ready for
  steps" case, but product-owned artifacts under `~/.cursor/plans` or
  `~/.claude/plans` (not the fleet `docs/plans/**` contract). Claude `/plan`
  often continues into implementation after approval; `/make-plan` never does.
  Promote product plans into `docs/plans/**` before `/critique` / `/execute-plan`.

`/brainstorm` exits early with a recommendation when a plan path is enough.
`/make-plan` suggests `/brainstorm` first when approaches or a Goal brief are still
missing.

## Execution tiers

Portable map tiers: **`top`** | **`execute`** | **`mid`** | **`low`** (legacy
`opus` / `auto` / low-tier aliases still normalize to these four).
**Roles:** `top-plan` = `/brainstorm`, `/make-plan`, and `/critique plan`;
`top-review` = map tier `top`, `/execute-plan` orchestrator, reviews, and
`/critique` escalate/closing; `top-critique` (optional) = second-family
`/critique plan` — map tier **`top`** resolves to **`top-review`**. Per-skill
session/Task requirements: that skill's `SKILL.md`. Canonical chains, fallback,
and per-tool resolution: [model-tiers.md](model-tiers.md) — **edit tier policy
there**, then run `bash scripts/sync-model-tiers.sh`. Full v2 map columns,
**`## Dispatch`**, naming, plan lock, and recency:
[skills/execute-plan/execution-status.md](skills/execute-plan/execution-status.md).

## Critique (policy A)

`/critique` is **not** a second planning/execute loop. Pass table and modes:
`skills/critique/SKILL.md`; models via
[model-tiers.md](model-tiers.md).

## Goal brief

`/brainstorm` establishes a short **Goal brief** — Goal, why now, non-goals, hard
constraints — before codebase exploration. The process is adaptive: **extract**
what args and the user message already state, **ask only gaps**, and **never
proceed with an empty brief** (floor). When the idea is tiny or args already encode
the brief, confirm a drafted 4-line brief in one turn instead of four interviews.

This brief is the fixed reference point carried, verbatim, through:

1. The persisted `docs/brainstorms/**` file.
2. The `/make-plan` handoff prompt (`Goal:` / `Scope:` / `Constraints:` /
   `Target Phase 1:` / `Brainstorm:` path markers).
3. The plan's `Purpose` section in `docs/plans/**`.

`/make-plan` parses `Brainstorm: docs/brainstorms/*.md` when present, reads that
file, and does not re-interview for facts the Goal brief or brainstorm already
answered. Without a brainstorm artifact, `/make-plan` runs the Requirements
interview (Goal, must-haves, non-goals, constraints) before exploring the
codebase.

## Guardrails carried by every skill in this chain

- **No unapproved commits or pushes.** `/commit` and `/gh-create-pr`/`/gh-tag-release`
  always present the exact change (message, branch, tag) for approval before acting.
- **No scope creep past the plan.** Execute skills (`/execute-plan`,
  `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, `/delegate:execute-via-devin`) implement only what `docs/plans/**` specifies; they do
  not re-plan or expand scope.
- **Execute skills persist progress on the plan.** `/execute-plan`,
  `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, and `/delegate:execute-via-devin` record row status and
  run history in the plan file (frontmatter + `## Execution log`) per `skills/execute-plan/execution-status.md`. Each
  finished run also appends a `runs:` record: backend, requested and resolved model (`auto(unresolved)` when the
  CLI reports none), effort, start/end, review findings, FIX loops and any fallback.
- **Refuse, don't guess, when a plan is unsafe to execute.** Execute skills
  (`/execute-plan`, `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, `/delegate:execute-via-devin`) stop (do not proceed, do not ask a
  soft clarifying question) if the plan has an unresolved "Blocked on" note or
  is missing a Success criteria or Verification section entirely.
- **Independent review is never self-review** for `/critique change` and
  `/execute-plan`'s review loop — details:
  `skills/critique/SKILL.md`,
  `skills/execute-plan/review.md`;
  models via [model-tiers.md](model-tiers.md).
- **Behavior-changing implement steps:** quality loop in
  `skills/execute-plan/implementer.md` (docs/config-only:
  justified skip + validate/portable checks).
- **`AskQuestion` batching.** Batch up to **4 independent questions** per
  `AskQuestion` call (2–4 options each, plus "Other" when useful); split only
  questions that depend on an earlier answer (`/brainstorm`'s Goal brief,
  `/make-plan`'s scope/constraints/success/assumptions, and similar).

## SKILL.md size budget

Cursor warns when a skill **body** exceeds ~**5,000 tokens**. Keep each
`SKILL.md` under that limit; put templates, long prompts, and detailed criteria
in sibling reference files one level deep (e.g. `plan-template.md`) and link
them from `SKILL.md`. Home Manager installs each skill as a whole directory
(one store symlink) and the plugin ships whole skill directories, so those
companions ship with the skill.

## Skills in this chain

| Skill | Writes to | Commits/pushes? |
| --- | --- | --- |
| `brainstorm` | `docs/brainstorms/**` | Never |
| `make-plan` | `docs/plans/**` | Never (skill); plans committable via `/commit` when tracked-eligible |
| `critique` | Plan file (plan mode) or working tree (change mode, via a fix subagent) | Never |
| `execute-plan` | Working tree (via implementation subagent); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted for review) |
| `delegate:execute-via-cursor` | Working tree (via Cursor `agent` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:execute-via-agy` | Working tree (via Antigravity `agy` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:execute-via-devin` | Working tree (via Devin `devin` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:review` | Plan audit metadata on `docs/plans/**` (`plan-status.sh review` marks the final `top` row; log stanza only, no `runs:` entry) | Never (read-only review through the plan's Review runner; Claude Code only, in the `delegate` plugin) |
| `commit` | Local git history | Commits only, after approval; never pushes |
| `gh-create-pr` | Remote branch + PR; runs planning-artifacts gate on branch plans/relay | Pushes + opens PR, after approval; Keep/Drop (plans) or Keep/Discard (relay) — user runs `/commit` if dropping |
| `gh-draft-release` | Draft GitHub Release | Creates a draft release, after approval |
| `gh-tag-release` | Git tag + publish CI trigger | Tags + pushes, after approval per step |
