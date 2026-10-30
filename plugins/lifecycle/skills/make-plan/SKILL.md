---
name: make-plan
description: >-
  Prompt for a task's purpose and build a structured implementation plan,
  grounded in codebase exploration and prior plans. Args: [update]
  [optional task description or path to existing plan]. Use when the user asks
  to plan a task, draft an implementation plan, or mentions /make-plan.
disable-model-invocation: true
---

# make-plan

Build a structured implementation plan for a task. Prompt for purpose, clarify scope, explore the codebase and recent plans, then draft and persist the plan to `docs/plans/**`. Can also update an existing plan.

**References (read when needed):** [plan-template.md](plan-template.md) · [drafting-rules.md](drafting-rules.md) · [brainstorm-handoff.md](brainstorm-handoff.md) · [execution-status.md](../execute-plan/execution-status.md) (execution scaffold SoT)

## Planner model (top-tier)

`/make-plan` is intended to run on a **top-tier** model (Opus 5.5 / Opus 4.6 / Fable or equivalent). If the current session is clearly mid- or low-tier, warn once and recommend switching before drafting — do not silently produce a thin plan.

## Relationship to built-in Plan (Cursor / Claude Code)

Built-in Plan is fine for a single-session explore→approve→code loop. This skill's job is a **durable** plan under `docs/plans/**` for Claude Code, Devin, Cursor execute/critique, and cross-session handoff.

| Surface | Artifact | After approve |
| --- | --- | --- |
| **This skill** (`/make-plan`) | `docs/plans/**` (fleet template) | Stops — user runs `/critique plan` → `/execute-plan` |
| **Cursor Plan mode** | `~/.cursor/plans/*.plan.md` or project `.cursor/plans/` | Switch to Agent and implement |
| **Claude Code `/plan`** | `~/.claude/plans/` | Often **continues into implementation** |

- Prefer **this skill** when you need a checked-in/shared plan or a `/execute-plan` / `/critique plan` input.
- Claude `/plan` may implement after approval; **`/make-plan` never implements**.
- If a Cursor or Claude plan already exists for the same task, **offer to promote/copy** it into `docs/plans/` (adapt to the fleet template) instead of re-running full discovery. Once promoted, `docs/plans/**` is the cross-tool source of truth. Do **not** teach `/execute-plan` to run raw `~/.claude/plans/` — promote first.
- If the user is still choosing among approaches or lacks a Goal brief, suggest `/brainstorm` first — then return here with the handoff prompt.

## Step 1 — Determine intent: new plan vs. update

Parse the user's slash-command or message args:

1. **Update mode** — if args start with `update` or `revise` (case-insensitive), strip the keyword and treat the remainder as a path or slug to an existing plan file. Read that plan and skip to "Update mode" below.
2. **Existing plan path** — if args are a single argument that is an existing file path under `docs/plans/` (or resolves to one via `Glob`), ask: "Update this plan, or use it as context for a new plan?" Default to **Update**.
3. **Brainstorm handoff** — if args contain `Scope:`, `Target Phase 1:`, `Brainstorm:`, or a `docs/brainstorms/*.md` path, parse per [brainstorm-handoff.md](brainstorm-handoff.md).
4. **New plan** — otherwise use args as the task description and proceed to Step 1.5.

If no arguments were given, use `AskQuestion` when available (otherwise ask conversationally):
- **What do you want to build or accomplish?** (free-text via "Other", plus 2–4 example options inferred from the current project)
- Optional follow-up: **Is this a new plan or an update to an existing plan?**

## Step 1.5 — Requirements interview (when no brainstorm)

After Step 1, detect whether a brainstorm artifact already answers Goal / requirements:

- **Has brainstorm handoff** — `Brainstorm:` path, bare `docs/brainstorms/*.md`, or parsed `Goal:` + `Scope:` + `Constraints:` markers with enough detail → `Read` the brainstorm file when a path is present; skip duplicate questions (see [brainstorm-handoff.md](brainstorm-handoff.md)). Continue to Step 2 only for gaps.
- **No brainstorm artifact** → before codebase exploration (Step 3), run a mandatory **Requirements interview**. Use `AskQuestion` when available (otherwise ask conversationally). `AskQuestion` supports **up to 4 options per call, not up to 4 questions** — issue **one `AskQuestion` call per question** (2-4 options plus "Other" each). Ask only gaps: **Goal**, **Requirements / must-haves**, **Non-goals**, **Hard constraints**, **Success criteria** (may fold into Step 2 if already answered).

Do **not** draft Implementation steps or the Execution map until Goal and requirements are captured. If the user is still choosing among approaches, recommend `/brainstorm` and stop — do not force a thin plan.

## Step 2 — Clarify scope

Use `AskQuestion` when available; otherwise ask conversationally. One `AskQuestion` call per facet (2-4 options plus "Other"), never one call compressing several questions into 4 options:

- **Goal** — skip if clear from Step 1.5, task description, or parsed `Goal:` handoff
- **Scope boundaries** — explicitly in/out
- **Constraints** — must-not-touch, deps, compatibility, performance
- **Success criteria** — how the user knows it's done and correct
- **Assumptions** — existing code, environment, data, deps, prior state
- **Coverage target** — only if Step 3 found coverage tooling (or ask after Step 3): accept repo threshold, default **90%**, or user-stated percent. Skip if coverage unavailable.

Skip answers already known from Step 1.5, brainstorm handoff, an existing plan being updated, or an obvious codebase fact. Prefer running Step 3's coverage probe before asking about a coverage target.

## Step 3 — Explore the codebase and prior plans

Use `Read`, `Grep`, and `Glob` **in parallel** to find relevant files, trace consumers, note patterns/tests, check prior art and recent plans, and **scan architecture docs** + **probe test coverage** (full rules in [drafting-rules.md](drafting-rules.md)).

Run `git status`, `git diff`, and `git log --oneline -10`. Also `Glob docs/plans/*.md` and read the 2–3 most recent plans; note conflicts/related work. Record architecture-doc paths for the draft.

Do not over-explore. Focus on what the plan needs to be concrete and grounded.

## Step 4 — Draft the plan

`Read` [plan-template.md](plan-template.md) and write the plan in that structure. Apply [drafting-rules.md](drafting-rules.md) for coverage, architecture-doc steps, tiers (`haiku` | `auto` | `opus`; never `sonnet`), and waves.

**Execution map** is required for multi-step plans. Ground every step and file reference in exploration — verify unsure paths with `Glob` or `Read` before including them.

## Step 5 — Write or update the plan file

### New plan

Project root: `git rev-parse --show-toplevel` (else cwd). Slug: kebab-case from title; strip stopwords (`the`, `a`, `an`, `and`, `or`, `for`, `to`, `in`, `on`, `of`, `with`, `is`, `are`, `this`, `that`, `it`, `as`, `by`, `from`). Timestamp: `date +%y%m%d%H%M`. Write `<project-root>/docs/plans/<yymmddhhmm>-<slug>.md` (create `docs/plans/` if needed).

### Update path

If updating, follow **Update mode** below — same file path, do not create a new file.

## Step 6 — Present the plan

Show the full plan in the chat and share the file path.

## Step 7 — Offer next steps

Offer: **Refine** · **Review** (`/critique plan`) · **Proceed** (`/execute-plan <path>`, Agent mode). Wait for the user's choice. Do not start implementing unless explicitly asked.

## Update mode

1. `Read` the existing plan; present briefly; ask what to change (or apply the change description from args).
2. Clarify with `AskQuestion` if needed.
3. If the update changes system shape or Scope, re-run the architecture-doc scan and adjust the docs Implementation/map step or justified skip ([drafting-rules.md](drafting-rules.md)). Wording-only edits may keep the prior Architecture docs note.
4. Write back to the **same path**; keep the filename unless the title/slug is badly misleading.
5. Re-read for coherence; present and offer next steps (Step 6–7).

## Constraints

- Never implement in this skill — only produce the plan. Execution needs an explicit request (e.g. `/execute-plan <path>`).
- Do not commit or push — only write `docs/plans/**`.
- If still ambiguous after questioning, say so and ask rather than guess.
- Keep the plan minimal and concrete — each step actionable; no padding.
- When updating, preserve the original filename (timestamp) unless the title changed drastically.
- Prefer small, tier-labeled steps (`haiku` / `auto`) and parallel waves over mega-steps.
- Always probe for coverage; when available put command + numeric target in Verification (default **90%** if no repo threshold); when unavailable, state that explicitly.
- Every plan must include an Update documentation Implementation/Execution-map step for architecture docs (prefer OVERVIEW / canonical Archify; create under `docs/architecture/` if scan empty and shape changes) **or** a one-line justified skip for pure chore/docs-only/formatting with no system-shape impact. Verification must prove doc diffs or the skip — not merely that scan paths were recorded.
