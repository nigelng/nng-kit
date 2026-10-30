# L0 lifecycle skills

These skills form the shared "idea → shipped" chain. They live in the `nng-kit`
marketplace (`plugins/lifecycle/skills/<name>/`), which is the source of truth.
Editing a skill means editing it **here**, never in an installed copy.

## Install

| Surface | How it gets the skills | Invoke as |
| --- | --- | --- |
| Claude Code (local or cloud) | `claude plugin marketplace add nigelng/nng-kit` then `claude plugin install lifecycle@nng-kit` | `/lifecycle:<name>` |
| Cursor, Devin, Windsurf | Each skill dir symlinked into `~/.agents/skills/<name>/` and the tool's own skills dir (the dotnix-macos Home Manager kit does this) | `/<name>` |

The SKILL.md files use only relative links to sibling files and no plugin-only
syntax, so the same directory works on every surface.

`execute-via-cursor` (needs the Cursor `agent` CLI) is a separate, local-only
Claude Code skill and is **not** part of this plugin. It is described below
because it writes the same plan audit metadata as `/execute-plan`.

## The chain

```
/brainstorm [idea]                 read-only; adaptive Goal brief (extract → ask
  → docs/brainstorms/**              gaps → never empty), explores feasibility,
  → /make-plan handoff prompt        iterates with the user, then emits a roadmap
                                       + a ready-to-paste /make-plan prompt

/make-plan [update] [task]         top-tier planner; interview-first for Goal/requirements
  → docs/plans/**                     when no brainstorm handoff; drafts a structured plan
                                       with an Execution map (haiku/auto/opus waves)

/critique plan <path>              optional lean second opinion (mid-tier, 1–2 passes;
  (optional)                          Opus escalate if blockers remain) before execute

/execute-plan <path>               top-tier orchestrator; requires Agent mode; refuses
  → uncommitted working-tree diff     if Blocked / missing Success or Verification;
                                       requires Execution map (draft→confirm→persist if
                                       missing); runs waves (haiku/auto implementers)
                                       then top-tier review every pass until clean

/execute-via-cursor <path>         Claude Code–only alternative: Cursor `agent` CLI
  → uncommitted working-tree diff     implements; Claude gates, briefs, reviews (≤2 FIX
                                       resumes). Not an L0 multi-consumer skill — see
                                       Claude-only install note below. Prefer when you
                                       want Cursor to code and Claude to review; keep
                                       `/execute-plan` for in-process Task waves.

/critique change [ref]             optional lean diff critique + security pass
  (optional)                          (Cursor/Claude security-review when available);
                                       after execute-plan skip lean critique by default
                                       but still run security unless docs-only

/commit                            Haiku-class default; classifies the diff, drafts a
  → local commit(s)                   Conventional Commit, optionally bumps
                                       version/CHANGELOG, commits only after approval
                                       (bump to mid-tier Auto for large mixed splits)

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
  independent top-tier review). Multi-consumer L0 skill.
- **`/execute-via-cursor`** — Claude Code–only: hands the plan to Cursor's
  `agent` CLI for implementation; Claude writes the brief, reviews against Base
  SHA + Verification, and may FIX-resume ≤2 times. Never commits (offer
  `/commit`). Local-only; not in this plugin and not linked into
  `~/.agents/skills` or Cursor/Devin/Windsurf.

## Ideate vs plan (three-way split)

- **`/brainstorm`** — open-ended ideation: multiple approaches, feasibility unknown,
  Goal brief + roadmap. Persists to `docs/brainstorms/**`.
- **`/make-plan`** — scope already clear (or after brainstorm handoff); durable
  step-by-step plan under `docs/plans/**` for execute/critique and cross-session
  handoff. Intended to run on a **top-tier** planner (Opus or equivalent). When
  there is no brainstorm artifact, interviews for Goal, requirements, non-goals,
  and constraints before drafting. Plans include an **Execution map** (waves +
  `haiku` / `auto` / `opus` tiers) for parallel, tiered execute.
- **Built-in Plan** (Cursor Plan mode / Claude Code `/plan`) — same "ready for
  steps" case, but product-owned artifacts under `~/.cursor/plans` or
  `~/.claude/plans` (not the fleet `docs/plans/**` contract). Claude `/plan`
  often continues into implementation after approval; `/make-plan` never does.
  Promote product plans into `docs/plans/**` before `/critique` / `/execute-plan`.

`/brainstorm` exits early with a recommendation when a plan path is enough.
`/make-plan` suggests `/brainstorm` first when approaches or a Goal brief are still
missing.

## Execution tiers

Portable labels in plan Execution maps: **`haiku`** | **`auto`** | **`opus`**.

- **Planner** (`/make-plan` session): top-tier (Opus or equivalent).
- **Orchestrator** (`/execute-plan` session): top-tier (Opus or equivalent); does
  not implement code itself.
- **`/commit` session**: **Haiku-class default** (Haiku 5.5 / Luna-equivalent).
  Checklist skill — not design/orchestration. Use mid-tier Auto for large mixed
  multi-commit splits or version+CHANGELOG judgment; do not require Opus.
- **`haiku`**: mechanical implementer / fix steps (also the default for `/commit`).
- **`auto` (mid-tier default for implement)**: Cursor → platform **Auto** (do not
  pin Sonnet); Claude Code → **Sonnet**. Legacy `sonnet` in old plans means `auto`.
- **`/execute-plan` reviewer**: **top-tier every pass** (Opus / Fable) — independent
  read-only Task; never Auto/Sonnet for this skill's review loop.
- **Map-first:** if the plan has no Execution map, `/execute-plan` drafts a
  mechanical haiku/auto map, confirms with the user, **persists** it into the plan
  file, then runs. If a map is present, validate and follow it (no silent rewrite).
- Map-row **`opus`** for implement remains rare; prefer finishing design in
  `/make-plan`. Other Opus subagent uses: see `subagents-claude.md` /
  `subagents-auto.md` (escalation / whole-branch review).

## Critique (lean second opinion)

`/critique` is **not** a second Opus planning/execute loop. Defaults:

- **Mid-tier** lean review (Cursor Auto / Claude Sonnet), max **2** review+fix
  cycles; then **one Opus escalate** if `blocking` / unresolved `important`
  remain; then stop and hand remaining items to the user.
- High-confidence findings only — prefer Ship as-is over inventing nits; never
  Ship as-is while blockers remain.
- **`/critique change` security pass:** invoke Cursor `security-review` (or
  Claude Code equivalent) once when available; inline trust-boundary fallback
  otherwise. After a successful `/execute-plan` review, skip lean critique by
  default but **still run the security pass** (unless docs-only / user opts out).

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
  `/execute-via-cursor`) implement only what `docs/plans/**` specifies; they do
  not re-plan or expand scope.
- **Execute skills persist progress on the plan.** `/execute-plan` and
  `/execute-via-cursor` record row status and run history in the plan file
  (frontmatter + `## Execution log`) per `execute-plan/execution-status.md`.
- **Refuse, don't guess, when a plan is unsafe to execute.** Execute skills
  (`/execute-plan`, `/execute-via-cursor`) stop (do not proceed, do not ask a
  soft clarifying question) if the plan has an unresolved "Blocked on" note or
  is missing a Success criteria or Verification section entirely.
- **Independent review is never self-review.** `/critique` and `/execute-plan`'s
  review loop always use a different subagent than the one that wrote the
  plan/code, and that reviewer is read-only. `/execute-plan` reviewers are
  always top-tier (every pass). `/critique` lean reviewers are mid-tier; Opus
  only on escalate; security uses platform `security-review` when available.
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
| `execute-via-cursor` | Working tree (via Cursor `agent` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; local Claude Code only, not in this plugin) |
| `commit` | Local git history | Commits only, after approval; never pushes |
| `gh-create-pr` | Remote branch + PR | Pushes + opens PR, after approval |
| `gh-draft-release` | Draft GitHub Release | Creates a draft release, after approval |
| `gh-tag-release` | Git tag + publish CI trigger | Tags + pushes, after approval per step |
