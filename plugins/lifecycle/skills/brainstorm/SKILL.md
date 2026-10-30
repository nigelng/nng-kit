---
name: brainstorm
description: >-
  Explore the codebase, ideate with the user until satisfied, then produce a
  roadmap and a /make-plan prompt. Args: [optional idea or feature description].
  Use when the user asks to brainstorm an idea, explore feasibility, or mentions
  /brainstorm.
disable-model-invocation: true
---

# brainstorm

Brainstorm an idea with the user: explore the codebase for feasibility, iterate on the concept until the user is satisfied, then produce a high-level roadmap and a ready-to-use `/make-plan` prompt.

This skill is read-only except for persisting its own output. It does not edit code or commit. It produces a prompt that the user can paste into `/make-plan` to turn the agreed idea into an implementation plan.

## Step 1 — Gather the idea

If arguments were provided (the user's slash-command or message args), use them as the initial idea and continue to **When NOT to brainstorm** — do **not** skip Step 1.5 or jump to Step 2.

If no arguments were given, use `AskQuestion` when available; otherwise ask conversationally:
- **What idea do you want to brainstorm?** (free-text via the "Other" option is expected — offer 2-4 example options inferred from the current project's recent commits, open files, or TODOs, plus "Other" for custom input)

Use the response as the initial idea, then continue to **When NOT to brainstorm**.

## When NOT to brainstorm

Right after the idea is known (args or Step 1 answer), check whether brainstorm is the right tool. Present this once with a recommendation and rationale — not a neutral menu. No domain-specific branches.

- **Scope clear, one approach, ready for steps** → prefer `/make-plan` (durable `docs/plans/**` + execute/critique chain). Recommended when the user already knows what to build.
- **Same, but no fleet handoff needed** → Cursor Plan mode (`SwitchMode` / `CreatePlan`) or Claude Code `/plan` (product-owned under `~/.cursor/plans` / `~/.claude/plans`). Recommended when `docs/plans/**` is not required.
- **Open-ended: multiple approaches, feasibility unknown, need Goal brief + roadmap** → continue `/brainstorm`. Recommended when ideation is still needed.

If the user picks a plan path, stop and hand them a one-line prompt they can paste — do **not** run Steps 1.5–7.

## Step 1.5 — Establish the Goal brief

Before exploring the codebase, establish a short **Goal brief** — the fixed reference point that `/make-plan` and `/execute-plan` will build on rather than re-derive. Adaptive, interview-first for gaps only (do not scout the codebase first).

The four facets:
- **Goal** — one sentence: what does "done" look like?
- **Why now** — the motivation or trigger
- **Non-goals** — what this idea explicitly will NOT do, so scope doesn't silently creep
- **Hard constraints** — anything that must not change (APIs, data shape, deadlines, compatibility)

Process:

1. **Extract** Goal / why-now / non-goals / hard constraints from args + the user message when already stated.
2. **Ask only gaps** — one `AskQuestion` per missing facet when available (otherwise ask conversationally). `AskQuestion` supports **up to 4 options per call, not up to 4 questions.** Issue **one `AskQuestion` call per question** (2-4 options plus "Other" each) — never compress several questions into a single 4-option call. For why-now, offer 2-4 inferred candidates (recent pain point, upcoming deadline, user request, tech debt, etc.) plus "Other".
3. **Compress** when the idea is tiny or args already encode the brief: confirm a drafted 4-line brief in one turn instead of four interviews.
4. **Floor**: if any of the four lines is still empty after extraction, ask until filled. Never proceed to exploration with a blank brief. Never silently skip this step because args existed in Step 1.
5. Carry the brief verbatim into Step 5.5 (persisted brainstorm) and Step 6 (`/make-plan` handoff) so the eventual plan starts from the same Goal, not a re-interpreted one.

Keep the brief to four short lines, not a discussion.

## Step 2 — Explore the codebase for feasibility

Use `Read`, `Grep`, and `Glob` **in parallel** to:
- Find files, modules, and patterns relevant to the idea
- Trace dependencies and consumers that the idea would touch
- Identify existing abstractions the idea should build on or replace
- Check for prior art: TODOs, issues, disabled code, or half-finished attempts at the same idea
- Assess feasibility: does the codebase have the primitives needed? What's missing?

Run `git log --oneline -20` and `git status` to understand recent direction and current state.

Do not over-explore. Focus on what's needed to assess feasibility and ground the ideation. If the idea is small, a few targeted searches suffice.

## Step 3 — Present feasibility assessment

Present a concise feasibility read before ideating. Structure it as:

### What we can build on
- Existing modules, patterns, or primitives the idea leverages

### What's missing
- Dependencies, abstractions, or infrastructure that don't exist yet

### Feasibility verdict
One of: **Straightforward** (codebase supports it), **Moderate** (needs new abstractions but no architectural shift), **Hard** (requires architectural changes or new dependencies), **Not feasible** (explain why — wrong layer, conflicts with existing design, external constraint).

Be honest. Do not soften a "Hard" into "Moderate" to please the user. If the idea is not feasible, say so directly and explain what would need to change to make it feasible.

## Step 4 — Ideate iteratively

This is the core loop. Present a concrete proposal for the idea, grounded in what you found in Step 2. Then use `AskQuestion` when available (otherwise ask conversationally) to let the user steer:

- **Direction** — offer 2-4 concrete approaches to the idea, each with trade-offs. End with your recommendation and rationale. Do not present a neutral menu.
- **Scope** — what to include vs. defer. Offer a "minimal viable" option and a "full vision" option, plus your recommendation.
- **Open questions** — anything the codebase exploration couldn't resolve (e.g. "should this be a new module or extend the existing one?")

Rules for the ideation loop:
- Each proposal must be concrete: reference specific files, modules, and patterns from the codebase. No generic advice.
- Each set of options must include a recommendation with rationale. Never leave the decision entirely to the user.
- Iterate until the user explicitly says they're satisfied (e.g. "looks good", "ship it", "that's the one"). Do not exit the loop early — **except** if the user says "good enough", "ship Phase 1", or "make the plan": exit ideation and go to Step 5; do not demand another satisfaction round.
- If the user rejects an approach, ask why before proposing the next one. Don't just cycle through options blindly.
- If the user proposes something the codebase can't support, say so and explain the constraint.

## Step 5 — Produce the roadmap

Once the user is satisfied with the idea, produce a high-level roadmap. Structure:

### Strategy
1-2 sentences: the core approach and why it's the right one for this codebase.

### Architecture
- How the idea fits into the existing codebase structure
- New modules/files to create (with paths grounded in codebase exploration)
- Existing modules/files to modify
- Key abstractions or interfaces introduced

### Roadmap
Phased delivery, ordered so each phase is independently useful:

1. **Phase 1 — <name>**: <what it delivers, why it's first>. Files: `<paths>`.
2. **Phase 2 — <name>**: <what it delivers, what it depends on from Phase 1>. Files: `<paths>`.
3. ...

### What we can do (realistic)
- Capabilities the codebase and current approach support

### What we can't do (not realistic)
- Capabilities that are out of reach with this approach, and why
- What would need to change to make them possible (if ever)

### What we're explicitly deferring
- Things that are feasible but deliberately postponed, with the reason

Be explicit about all three lists. Do not blur the line between "can't" and "deferring" — they're different commitments.

## Step 5.5 — Persist the brainstorm

Determine the project root with `git rev-parse --show-toplevel` (fall back to the current working directory if not a git repo).

Derive a kebab-case slug from the idea title (lowercase, hyphen-separated). Remove stopwords: `the`, `a`, `an`, `and`, `or`, `for`, `to`, `in`, `on`, `of`, `with`, `is`, `are`, `this`, `that`, `it`, `as`, `by`, `from`. Example: "Add a plugin system" → `add-plugin-system`.

Generate a timestamp with `date +%y%m%d%H%M` (2-digit year, month, day, hour, minute — e.g. `2607051430`).

Create the `docs/brainstorms/` directory at the project root if it doesn't exist, then write the brainstorm to `<project-root>/docs/brainstorms/<yymmddhhmm>-<slug>.md`.

The file must contain: the Step 1.5 Goal brief, the Step 3 feasibility assessment, the Step 5 roadmap (strategy, architecture, phases, can/can't/deferring lists), and the Step 6 make-plan prompt.

## Step 6 — Produce the /make-plan prompt

Produce a single prompt that the user can paste into `/make-plan` to turn the agreed idea into a concrete implementation plan. The prompt must:

- Start with a one-sentence task description (what to build)
- Include the **Goal** from the Step 1.5 Goal brief, verbatim
- Include the scope decisions from Step 4 (what's in, what's out)
- Reference the Phase 1 deliverable from Step 5 as the immediate target (make-plan handles one phase at a time, not the whole roadmap)
- Include any constraints or must-not-touch areas agreed during ideation (fold in the Goal brief's non-goals and hard constraints)
- Include the persisted brainstorm path as `Brainstorm: docs/brainstorms/<file>.md` so `/make-plan` can load strategy/architecture/phases instead of re-deriving from a lossy one-liner
- Be self-contained — the `/make-plan` skill should not need to re-run the brainstorm

Format the prompt in a fenced code block so the user can copy-paste it cleanly:

```
/make-plan <task description>. Goal: <one-sentence Goal from the Step 1.5 brief>. Scope: <in/out>. Constraints: <list>. Target Phase 1: <phase name and deliverable>. Brainstorm: docs/brainstorms/<yymmddhhmm>-<slug>.md
```

If the prompt is too long for a single line, use a multi-line fenced block and instruct the user to paste it after `/make-plan`.

## Step 7 — Offer next steps

After presenting the roadmap and prompt (and confirming the brainstorm was saved to `docs/brainstorms/`), offer the user these options:
- **Refine the idea** — go back to Step 4 and iterate further (the persisted file will be updated)
- **Run /make-plan now** — the user pastes the prompt from Step 6 to produce the implementation plan
- Mention the recommended chain after planning: `/make-plan` → `/critique plan` → `/execute-plan`

Wait for the user's choice. Do not invoke `/make-plan` yourself — the user runs it with the prompt you produced.

## Constraints

- Never edit code or commit anything — this skill only writes to `docs/brainstorms/**`.
- Never invoke `/make-plan` directly — produce the prompt and let the user run it.
- Be honest about feasibility. Do not soft-pedal "Hard" or "Not feasible" verdicts.
- Every set of options presented to the user must include a recommendation with rationale.
- Ground every proposal in specific files, modules, and patterns from the codebase. No generic advice.
- If the idea is ambiguous even after exploration, say so and ask rather than guess.
- The roadmap is high-level. Detailed step-by-step implementation belongs in `/make-plan`, not here.
