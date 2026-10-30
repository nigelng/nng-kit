# Plan execution status contract

Single source of truth for durable completion state on fleet plans under `docs/plans/**`. Execute skills **dual-write** YAML frontmatter + `## Execution log` in one edit. Skills link here; do not restate the full schema in SKILL bodies.

## Frontmatter schema

Required once any execute skill has touched the plan:

```yaml
---
execution:
  status: not-started | in-progress | completed | partial | failed | aborted
  progress_pct: 0-100
  steps_done: <int>
  steps_total: <int>
  last_skill: execute-plan | execute-via-cursor
  started_at: <ISO-8601Z>   # first run that moved status off not-started
  updated_at: <ISO-8601Z>   # every write
  completed_at: <ISO-8601Z | null>  # only when status == completed
---
```

Timestamps: ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`).

## Overall `status` meanings

| Value | Meaning |
| --- | --- |
| `not-started` | Scaffold only; no execute run yet. |
| `in-progress` | At least one row `in-progress` or `done`, and not terminal. |
| `completed` | Every row is `done` **or** `skipped` for a reason **other than** solely `out of step-scope`, **and** the skill’s success path finished (execute-plan review clean / execute-via-cursor PASS). Rows skipped only as out-of-scope do **not** satisfy this. |
| `partial` | Run stopped without meeting `completed`: user abort mid-wave; scoped PASS that left other rows as out-of-scope skips (or any in-scope row not yet `done`/`skipped`); or any row still `pending`/`in-progress`/`failed` after a non-failed stop. A scoped PASS is **`partial`**, not `completed`, when the only unresolved work was marked `skipped` / `out of step-scope`. |
| `failed` | Terminal failure (execute-via-cursor FAIL after FIX budget; execute-plan hard stop after failed wave/review stop conditions without a clean finish). |
| `aborted` | User explicitly aborted before meaningful progress, or preflight refuse after a prior `in-progress` write was not applicable (prefer leaving prior state if never started this run). |

## Row statuses

Table column values: `pending` | `in-progress` | `done` | `skipped` | `failed`.

## Progress formula

- **`steps_total`** = number of Execution-map rows (preferred), or Implementation-step fallback rows when no map.
- **`steps_done`** = count of rows with status `done` **or** `skipped` (skipped counts as resolved for progress).
- **`progress_pct`** = `round(100 * steps_done / steps_total)`.
- If **`steps_total == 0`**: set `progress_pct` to `0` and **never** claim `completed`.

## Out-of-scope / step-scope (locked)

Rows not in the current `step-scope` (or equivalent execute-plan subset) → status **`skipped`** with Notes **`out of step-scope`**, **only if the row is not already `done`**. Do **not** leave them `pending`. Do **not** downgrade a prior `done` to `skipped` (preserve-prior-done).

**Preserve-prior-done:** if an out-of-scope row was `done` from an earlier run, leave it `done` (and its prior Notes). Only non-`done` out-of-scope rows get `skipped` / `out of step-scope`.

Out-of-scope skips alone never make overall `completed` — see status meanings above (scoped PASS → `partial`).

## Placement (locked)

`## Execution log` goes **immediately after** `## Execution map` and **before** `## Files to modify/create`.

If the plan has **no** Execution map: place immediately after `## Implementation steps` and before Files.

Writers must **create or move** the section to that slot — do **not** append at EOF; do **not** leave a duplicate mid-file.

## Markdown log template

```markdown
## Execution log

- **Overall:** <status> — <progress_pct>% (<steps_done>/<steps_total>)
- **Last skill:** <execute-plan|execute-via-cursor>
- **Updated:** <ISO-8601Z>

| ID | Status | Notes |
| --- | --- | --- |
| S1 | done | … |
| S2 | skipped | out of step-scope |
| S3 | pending | |

### Run <ISO-8601Z> (<skill>)
- Outcome: <completed|partial|failed|aborted|in-progress>
- Notes: <one short paragraph or bullet list>
```

Keep history short: replace/update the summary table on each write; add one `### Run …` stanza per terminal (or meaningful) outcome rather than unbounded append noise.

## Update timing (locked)

1. **Start of execute** (after preflight/validation passes): ensure frontmatter + empty/updated log exist; set `status: in-progress`, `started_at` if unset, mark scoped rows `pending` (or leave prior `done` on resume).
2. **After each wave / scoped batch** succeeds or fails: update those row statuses + frontmatter `%` / `updated_at`.
3. **Terminal outcome** (final summary / PASS / FAIL / abort): set overall `status`, `completed_at` iff `completed`, final `%`, one `### Run …` stanza.

## Who writes

| Skill | Writer |
| --- | --- |
| `/execute-plan` | **Orchestrator** (same agent that persists the Execution map). |
| `/execute-via-cursor` | **Claude** after each meaningful phase (post-Cursor implement before/after review as needed; always on terminal verdict). **Never Cursor.** |

## Fallback when no Execution map

Treat numbered **Implementation steps** as the row set for progress. Use IDs `I1`…`In` or the plan’s existing step numbers. Same row statuses, formula, out-of-scope rule, and log template.

## Idempotency / re-execute

Re-running on an already **`completed`** plan: **confirm with the user** before resetting row statuses (or only add a new Run stanza if the user confirms re-execute).

Default recommendation when user confirms re-execute: reset non-`skipped` rows in scope to `pending` and set overall `in-progress`.

## Dual-write rule

Every status update is **one edit** that updates frontmatter **and** `## Execution log` together. Prefer replace-the-summary-table over conflicting formats. Never write one without the other.
