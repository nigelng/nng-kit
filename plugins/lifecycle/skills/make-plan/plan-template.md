# Plan file template

Write new/updated plans in this structure. Every multi-step plan needs an **Execution map**; a single trivial step may use one `auto` wave with one row. Every map ID must match a numbered Implementation step (or a clear sub-bullet).

```markdown
---
execution:
  status: not-started
  progress_pct: 0
  steps_done: 0
  steps_total: 0
  last_skill: null
  started_at: null
  updated_at: null
  completed_at: null
---

# Plan: <task title>

## Purpose
<1-2 sentences: what and why>

## Scope
**In scope:**
- <item>
**Out of scope:**
- <item>

## Assumptions
- <assumption the plan makes about existing code, environment, data shape, dependencies, or prior state; mark as `[verified]` or `[unverified]`>
- **Architecture docs (from scan):** <paths / canonical doc from Step 3, or "none found">

## Dependencies
- <other plans, PRs, external API approvals, or infra that must be in place first; link if known>
- **Architecture docs (from scan):** <same paths / canonical pointer; note if create-under-`docs/architecture/` is needed>

## Implementation steps
1. <step> — <file(s) affected>
2. <step> — <file(s) affected>
3. **Update documentation** — <architecture doc path(s) to update, or create under `docs/architecture/` if scan empty and shape changes> — **or** one-line **justified skip** here / in Scope (see drafting-rules.md)
...

## Execution map

| ID | Step summary | Tier | Wave | Depends on | Notes |
| --- | --- | --- | --- | --- | --- |
| S1 | … | haiku | 1 | — | mechanical rename / boilerplate |
| S2 | … | auto | 1 | — | parallel with S1 (no shared files); mid-tier |
| S3 | … | auto | 2 | S1,S2 | integration after wave 1 |
| S4 | Update architecture docs (or justified skip) | haiku | 3 | S3 | OVERVIEW / canonical Archify — or skip |

## Execution log

- **Overall:** not-started — 0% (0/0)
- **Last skill:** —
- **Updated:** —

| ID | Status | Notes |
| --- | --- | --- |

<!-- Scaffold only. /execute-plan and /execute-via-cursor fill this table and the frontmatter above (dual-write). Do not hand-edit rows. -->

## Files to modify/create
- `<path>` — <brief description of the change>
- `<path>` — <brief description of the change>

## Verification
- <test / lint / type-check / build commands — concrete and copy-pastable>
- **Coverage:** <available | not available>
  - If available: command `<exact coverage command>`; **target: <N>%** (repo threshold if present, else **90%** unless user overrode); scope of measurement if known (e.g. changed packages only)
  - If not available: state that explicitly; do not require `/execute-plan` to invent a coverage run
- **Architecture docs:** execute-checkable proof — `git diff` / Files show the architecture-doc paths changed as listed in the Implementation docs step, **or** Scope/Implementation contains a one-line justified skip. Listing scan paths in Assumptions alone is **not** proof.

## Success criteria
- <how the user will know the task is done and correct; distinct from verification — "what good looks like" vs "how to check">
- If coverage is available: include meeting the stated **coverage target** as a success criterion
- Architecture docs reflect the shape change (OVERVIEW / canonical Archify updated or created as planned), **or** a justified skip is recorded

## Rollback / reversibility
- <what can be undone cleanly and how; what's NOT reversible (schema changes, deleted files, external API calls with side effects)>

## Risks & considerations
- <edge case, tradeoff, backwards-compatibility note, or "None identified">
- If coverage is unavailable but the change is high-risk: note the gap
```

Implementation steps stay human-readable; the map is the machine-oriented schedule for `/execute-plan`.
