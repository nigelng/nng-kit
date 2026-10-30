# Brainstorm handoff parsing

`brainstorm` produces a prompt like:

```
/make-plan <task description>. Goal: <one-sentence Goal>. Scope: <in/out>. Constraints: <list>. Target Phase 1: <phase name and deliverable>. Brainstorm: docs/brainstorms/<yymmddhhmm>-<slug>.md
```

Parse args for these markers:

- **Task description** — text before the first `.` or before `Goal:` / `Scope:`
- **Goal** — text between `Goal:` and the next marker (or end)
- **Scope** — text between `Scope:` and the next marker (or end)
- **Constraints** — text between `Constraints:` and the next marker (or end)
- **Target Phase 1** — text between `Target Phase 1:` and the next marker (or end)
- **Brainstorm** — path after `Brainstorm:` (or a bare `docs/brainstorms/*.md` path in args)

If a `Brainstorm:` path (or `docs/brainstorms/*.md`) is present, `Read` that file and treat its Goal brief, Phase 1, constraints, strategy, and architecture as already answered — skip duplicate Step 1.5 / Step 2 questions that would re-derive them.

Use the markers (and the brainstorm file when loaded) to pre-populate:

- **Purpose** — Goal (if present) + task description + Target Phase 1 as the immediate focus
- **Scope** — parsed `Scope:` text
- **Risks & considerations / Constraints** — parsed `Constraints:` text
- **Implementation steps** — focus on the Phase 1 deliverable first; prefer strategy/architecture from the brainstorm file over re-deriving from the one-liner

Skip Step 1.5 / Step 2 clarifying questions already answered by the handoff or the brainstorm file.
