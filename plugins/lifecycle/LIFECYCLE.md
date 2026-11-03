# L0 lifecycle skills

These skills form the shared "idea → shipped" chain. They live in the `nng-kit`
marketplace (`plugins/lifecycle/skills/<name>/`), which is the source of truth.
Editing a skill means editing it **here**, never in an installed copy.

## Install

| Surface | How it gets the skills | Invoke as |
| --- | --- | --- |
| Claude Code (local or cloud) | `claude plugin marketplace add nigelng/nng-kit` then `claude plugin install lifecycle@nng-kit` | `/lifecycle:<name>` |
| Cursor, Devin, Windsurf | Each skill dir symlinked into `~/.agents/skills/<name>/` and the tool's own skills dir (the private source repo's Home Manager kit does this) | `/<name>` |
| Antigravity | Kit links each skill into `~/.gemini/config/skills/<name>/` when `antigravity-cli` is in the host's Homebrew casks (same HM kit as Cursor/Devin/Windsurf) | `/<name>` |

The SKILL.md files use only relative links to sibling files and no plugin-only
syntax, so the same directory works on every surface.

`/delegate:execute-via-cursor` (needs the Cursor `agent` CLI) and
`/delegate:execute-via-agy` (needs the Antigravity `agy` CLI) are separate Claude
Code skills in the `delegate` plugin and are **not** part of this plugin. They are
described below because they write the same plan audit metadata as `/execute-plan`.

## The chain

```
/brainstorm [idea]                 top-tier session; read-only; adaptive Goal brief
  → docs/brainstorms/**              (extract → ask gaps → never empty), explores
  → /make-plan handoff prompt        feasibility, iterates with the user, then emits a
                                       roadmap + a ready-to-paste /make-plan prompt

/make-plan [update] [task]         top-tier planner; interview-first for Goal/requirements
  → docs/plans/**                     when no brainstorm handoff; drafts a structured plan
                                       with an Execution map (haiku/auto/opus waves)

/critique plan <path>              optional top-tier second opinion on the plan before
  (optional)                          execute (not a lean mid-tier pass)

/execute-plan <path>               top-tier orchestrator; requires Agent mode; refuses
  → uncommitted working-tree diff     if Blocked / missing Success or Verification;
                                       requires Execution map (draft→confirm→persist if
                                       missing); runs waves (haiku-biased / auto
                                       implementers; low→mid fallback if capped) then
                                       mid-tier review passes, then a top-tier
                                       final pass, until clean

/delegate:execute-via-cursor <path>  Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Cursor `agent` CLI implements (default Auto when
                                       `model=` omitted); Claude gates, briefs, reviews
                                       (bounded FIX loop). Not an L0 multi-consumer skill —
                                       see Claude-only install note below. Prefer when you
                                       want Cursor to code and Claude to review; keep
                                       `/execute-plan` for in-process Task waves.

/delegate:execute-via-agy <path>    Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Antigravity `agy` CLI implements (default Auto when
                                       `model=` omitted); Claude gates, briefs, reviews
                                       (bounded FIX loop). Same contract as
                                       `/delegate:execute-via-cursor`, different backend.

/critique change [ref]             lean mid-tier diff rounds + final top-tier change
  (optional)                          critique; security pass (Cursor/Claude
                                       security-review when available); after a
                                       converged execute-plan review skip lean and
                                       skip the closing final pass by default; still
                                       run security unless docs-only

/commit                            low-tier default; classifies the diff, drafts a
  → local commit(s)                   Conventional Commit, optionally bumps
                                       version/CHANGELOG, commits only after approval
                                       (use mid-tier for large mixed splits)

/gh-create-pr                      ensures a feature branch, pushes, opens a PR via
  → pull request                      `gh`, and watches CI (investigates failures,
                                       does not auto-fix without approval)

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
  omitted, backend **Auto**); Claude writes the brief, reviews against Base SHA +
  Verification, and may FIX-resume ≤2 times. Never commits (offer `/commit`).
  Not linked into `~/.agents/skills` or Cursor/Devin/Windsurf.
- **`/delegate:execute-via-agy`** — Claude Code–only, in the `delegate` plugin:
  same contract as `/delegate:execute-via-cursor`, but Google's Antigravity `agy`
  CLI does the implementing (default **Auto** when `model=` omitted). Never
  commits.

## Ideate vs plan (three-way split)

- **`/brainstorm`** — open-ended ideation: multiple approaches, feasibility unknown,
  Goal brief + roadmap. Persists to `docs/brainstorms/**`. Always a **top-tier**
  session (same model bar as `/make-plan`).
- **`/make-plan`** — scope already clear (or after brainstorm handoff); durable
  step-by-step plan under `docs/plans/**` for execute/critique and cross-session
  handoff. Always a **top-tier** planner session. When there is no brainstorm
  artifact, interviews for Goal, requirements, non-goals, and constraints before
  drafting. Plans include an **Execution map** (waves + `haiku` / `auto` /
  `opus` tiers) for parallel, tiered execute — biased to smallest mechanical
  units / prefer `haiku`.
- **Built-in Plan** (Cursor Plan mode / Claude Code `/plan`) — same "ready for
  steps" case, but product-owned artifacts under `~/.cursor/plans` or
  `~/.claude/plans` (not the fleet `docs/plans/**` contract). Claude `/plan`
  often continues into implementation after approval; `/make-plan` never does.
  Promote product plans into `docs/plans/**` before `/critique` / `/execute-plan`.

`/brainstorm` exits early with a recommendation when a plan path is enough.
`/make-plan` suggests `/brainstorm` first when approaches or a Goal brief are still
missing.

## Execution tiers

Portable map labels: **`haiku`** | **`auto`** | **`opus`** (`low`/`mid`/`top`).
Per-skill session/Task requirements: that skill's `SKILL.md`. Canonical chains,
fallback, and per-tool resolution: [model-tiers.md](model-tiers.md) — **edit
tier policy there**, then run `bash scripts/sync-model-tiers.sh`.

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
  `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`) implement only what `docs/plans/**` specifies; they do
  not re-plan or expand scope.
- **Execute skills persist progress on the plan.** `/execute-plan`,
  `/delegate:execute-via-cursor`, and `/delegate:execute-via-agy` record row status and run history in the plan file
  (frontmatter + `## Execution log`) per `skills/execute-plan/execution-status.md`.
- **Refuse, don't guess, when a plan is unsafe to execute.** Execute skills
  (`/execute-plan`, `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`) stop (do not proceed, do not ask a
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
- **`AskQuestion` options vs. questions.** `AskQuestion` supports up to **4 options
  per call**, not up to 4 questions. When a step needs to ask several questions
  (`/brainstorm`'s Goal brief, `/make-plan`'s scope/constraints/success/assumptions
  — up to ~7 facets combined), each question gets its own `AskQuestion` call
  (2-4 options plus "Other"); never compress multiple questions into one call.

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
| `make-plan` | `docs/plans/**` | Never |
| `critique` | Plan file (plan mode) or working tree (change mode, via a fix subagent) | Never |
| `execute-plan` | Working tree (via implementation subagent); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted for review) |
| `delegate:execute-via-cursor` | Working tree (via Cursor `agent` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:execute-via-agy` | Working tree (via Antigravity `agy` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `commit` | Local git history | Commits only, after approval; never pushes |
| `gh-create-pr` | Remote branch + PR | Pushes + opens PR, after approval |
| `gh-draft-release` | Draft GitHub Release | Creates a draft release, after approval |
| `gh-tag-release` | Git tag + publish CI trigger | Tags + pushes, after approval per step |
