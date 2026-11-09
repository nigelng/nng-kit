---
name: execute-plan
description: >-
  Execute a structured implementation plan produced by /make-plan, delegating
  implementation to a subagent and iterating with an independent review
  subagent until quality criteria are met. Args: [plan] [step-scope IDs…].
  Use when the user asks to execute a plan or mentions /execute-plan.
disable-model-invocation: true
---

# execute-plan

Execute a structured plan. Orchestrate: locate plan → plan lock → ensure Execution map → pre-flight → **wave-delegated implement** (parallel `generalPurpose` Tasks, tier per step; `delegate:*` rows are not Tasks) → **independent** review loop (mid intermediate, **top** final) until no `blocking`/`important` remain and agreed tests pass.

**References (read when needed):** [implementer.md](implementer.md) · [review.md](review.md) · [execution-status.md](execution-status.md) · [../make-plan/drafting-rules.md](../make-plan/drafting-rules.md)

## Preconditions

**Requires Agent mode.** If you are in Plan or Ask mode, stop and tell the user to switch to Agent mode before continuing.

**Orchestrator model (top-review).** Session/Task tiers: [model-tiers.md](model-tiers.md) (`top`/`mid`/`low`). Warn once if the session is below **top-review** and recommend switching before delegating. The orchestrator does **not** edit implementation source files — only locates the plan, manages the map, dual-writes plan status/log (see Status audit), launches Tasks, and summarizes. Plan-file map and status edits remain allowed.

## Step 1 — Locate the plan

Args: `[plan] [step-scope IDs…]`. The first argument is a path under `docs/plans/**` or a plan slug/timestamp. Any further arguments are step-scope IDs (`S1`, `I2`, …). Resolve slugs against `docs/plans/` only.

**Recency.** When several files match, pick the most recent per [execution-status.md](execution-status.md) § Plan recency. `*.notes.md` is never a plan — ignore it in listings and matches. If the argument is a notes file, stop and point at the sibling plan. Do not sort raw filenames.

If no plan argument, list `docs/plans/*.md` except `*.notes.md`, then ask the user to pick (`AskQuestion` when available).

**Step-scope.** With no IDs, every map row is in scope. With IDs, a map row not named is outside scope. At Status audit Start, dual-write it `skipped` with Notes `out of step-scope` per [execution-status.md](execution-status.md) § Out-of-scope / step-scope (only if not already `done`; never leave `pending`; never downgrade a prior `done`). An ID that is not on the map is a hard stop — do not dual-write.

If the user points at `.cursor/plans/`, stop and tell them to promote via `/make-plan` into `docs/plans/**` first. If missing/unreadable, stop. Do **not** execute raw `~/.claude/plans/` — require a fleet plan under `docs/plans/**`.

## Step 2 — Read and parse the plan

Extract: Purpose, Scope, Assumptions, Dependencies, Implementation steps, Execution map (v2 or legacy), `## Dispatch` when present, Files to modify/create, Verification, Success criteria, Rollback, Risks.

If a section is ambiguous or referenced files do not exist, ask a focused clarifying question before proceeding. A legacy plan may have no `## Dispatch` and no Runner / Files / Acceptance / Review columns; Step 2.75 accepts that map. Tier aliases are normalized there, not here.

## Step 2.5 — Refuse if blocked or incomplete

Hard stop (not a clarifying question) if any of:

- Explicit unresolved **"Blocked on"** note
- Missing **Success criteria** section
- Missing **Verification** section

State which condition triggered and the next step: resolve the blocker, or `/make-plan update <path>`, then re-invoke `/execute-plan`. Ambiguous *content* inside an existing section → clarifying question (Step 2); missing section / unresolved blocker → hard stop.

## Step 2.6 — Plan lock

`Read` [execution-status.md](execution-status.md) § Plan lock. Run the code block under that section — the lines inside the fence between the `plan-sha` markers (`plan_body` / `plan_sha`) — and compare its `plan_sha` output to the frontmatter `plan_sha`. Do not reimplement the hash. Do not dual-write on this step.

- No `plan_sha` → warn `legacy plan (no plan_sha)` and continue.
- Mismatch → hard stop with `plan body changed since approval; re-approve with /make-plan update <path>`.

## Step 2.75 — Execution map (required before implement)

Do **not** invent silent sequential steps and proceed. An Execution map must exist and be validated before Step 4.

Accept a v2 map or a legacy map. Column sets, defaults, and the remaining Review constraints live in [../make-plan/drafting-rules.md](../make-plan/drafting-rules.md) § Map v2 rules. Do not restate per-tool pins.

### Map present

1. **Normalize, then default.** Legacy tiers: `opus` → `top`, `auto` / `sonnet` → `mid`, `haiku` → `low`. If Tier is `—`, the row is **not scheduled**: treat it as `skipped`, do not default Runner, Model, or Review, and exclude it from the tier set check below. Wave `—` on that row is not placed in any wave (same scheduling sense as a skipped step). Then, on **scheduled** rows only: a missing Runner defaults per the drafting rules (`top` → `session`, anything else → `subagent`); a missing Review defaults to `mid`; a missing Model column is empty.
2. **Validate** (scheduled rows only — Tier not `—`).
   - Every Implementation step has a map ID (or clear sub-bullet coverage).
   - Tier is one of `top` | `execute` | `mid` | `low`.
   - Runner is one of `session` | `delegate:cursor` | `delegate:devin` | `delegate:agy` | `subagent`.
   - Model is empty, or `auto` / `auto(router)` only with `low` + `delegate:cursor`.
   - Review is one of `top@session` | `top@claude-task` | `top@devin-fusion` | `top@cursor-ask` | `top@agy-plan` | `mid` | `none`. `none` only on a `low` row with an Acceptance command. Rows in one (wave, Runner) batch share a single `top@*` value.
   - A `top` row never uses `delegate:*`.
   - **Files overlap, per wave.** On a v2 map, the same path must not appear on two rows of one wave (`—` overlaps nothing). A legacy map with no Files column keeps today's inferred check: same-wave rows do not share write paths. Conflict → ask to re-wave or serialize.
3. Use the map as the schedule. Do **not** rewrite unless the user asks.
4. **Hard follow:** never collapse the map into a single whole-plan Task; never invent extra implementation steps outside the map without explicit user approval.

On a scheduled row, an invalid tier (any value other than `top` | `execute` | `mid` | `low` — Tier `—` is handled above), Runner, Model, or Review, or a `top` row on `delegate:*`, is a hard stop: name the row and the field. Tell the user to fix it with `/make-plan update <path>`. Do not silently rewrite. Do not dual-write.

### Map absent

If the plan has **`plan_sha`** (Step 2.6 did not warn `legacy plan (no plan_sha)`): **hard stop.** Do not draft a map, split Implementation bullets, or write `## Execution map` into the plan body — re-stamping would break the approved hash. State that the Execution map is missing from an approved plan; the user must add it with `/make-plan update <path>`, then re-invoke `/execute-plan`.

**Legacy (no `plan_sha` only)** — draft-confirm-persist in place:

1. Draft a v2 map biased to **smallest mechanical units**: tiers `low` for tightly scoped work, `execute` for interface-level work, `mid` for judgment; avoid `top` for implement rows. Use the drafting-rules columns (Runner, Files, Acceptance, Review). Prefer parallel waves when Files do not overlap. Split coarse steps into map rows (and split plan bullets if needed).
2. Present for confirmation (`AskQuestion`: approve / revise / abort).
3. **On approve:** write `## Execution map` into the **same plan file** (after Implementation steps if present), then re-read.
4. **On revise:** iterate until approved — do not start Step 3/4 until confirmed. **On abort:** stop.
5. If Implementation steps are too coarse for a safe map, offer `/make-plan update <path>`; default remains in-place map (+ split bullets as needed).

Re-run validation after legacy confirm/persist (or when the map was already present); fix or ask before Step 4.

## Step 3 — Pre-flight checks

1. Project root: `git rev-parse --show-toplevel` (else cwd).
2. `git status --short` and `git diff HEAD` for baseline.
3. If working tree not clean, warn and ask proceed / stash / abort.
4. Determine test / build / lint / type-check tooling from manifests, Verification, and common config.
5. Build a **Quality toolkit** for every implementation Task: unit/integration commands (prefer path-scoped), lint, type-check/format-check, and **Coverage** (if Verification says available: command + target, else plan target or **90%**; if not available, do not invent a gate).
6. **Optional:** if the plan was not stress-tested via `/critique plan` and does not record `Plan size: small`, offer that first; do not block if they decline.

## Status audit (orchestrator dual-write)

`Read` [execution-status.md](execution-status.md) for schema, `%` formula, placement, and dual-write rule. Dual-write YAML frontmatter + `## Execution log` in **one edit** at:

1. **Start** — after Step 3 (and map validation) pass, before or as Step 4 begins: ensure frontmatter + log exist; `status: in-progress`; `started_at` if unset. In-scope rows this run will implement: `pending` with Notes cleared (leave prior `done` rows untouched). Outside step-scope: `skipped` with Notes `out of step-scope`. In-scope `delegate:*`: `skipped` with Notes `out of step-scope (dispatch via delegate)`. Both skips only if the row is not already `done`. Confirm with the user before resetting an already-`completed` plan.
2. **After each wave** (success or wave-failure stop): update those row statuses + frontmatter `%` / `updated_at`.
3. **Terminal** — at Step 6 (or earlier abort/hard stop): set overall `status` (`completed` / `partial` / `failed` / `aborted`), `completed_at` iff `completed`, final `%`, one `### Run …` stanza with its `Run:` line, and append one `runs:` entry (fields in [execution-status.md](execution-status.md) § Run records): `backend: claude-code`; `model_requested` / `model_resolved` = the distinct implementer models in run order (resolved = what the Tasks actually ran on); `effort` = their tier efforts; `review_findings` = `blocking` + `important` findings from every review pass this run; `fix_loops` = fix rounds after review; `fallback` = `null` or the reason (for example a `low` row that fell back to `mid`). A Note that begins with `out of step-scope` does not satisfy `completed`; stopping for step-scope, for an unfinished delegate row, or because the final top pass was deferred to `/delegate:review` is `partial`.

## Step 4 — Delegate implementation by waves

Do **not** send the whole plan to a single subagent. Orchestrate from the validated Execution map only. For quality bar, Task prompt, and full verification details, `Read` [implementer.md](implementer.md).

### Model resolution (per map tier) — implementers

Resolve `top`, `mid`, and `low` via [model-tiers.md](model-tiers.md). Resolve `execute` to the host's `execute` pin when that host lists one; otherwise `mid` (claude-code lists no `execute` row, so an in-process `execute` row is `mid`). Always set the model explicitly; if you can't, stop and tell the user before delegating.

### Wave schedule

1. Group in-scope map rows by **Wave** (ascending). Leave rows that are already `done` as `done`. Decide what to launch from the current step-scope, Runner, and status — never from Notes left by an earlier run.
2. **Delegate rows.** Do not implement a `delegate:*` row here. An in-scope one that is not already `done` was dual-written at Start as `skipped` with Notes `out of step-scope (dispatch via delegate)`. Print the matching `## Dispatch` lines now (each line whose command names those IDs), and tell the user to `/commit` this run's changes before running any `/delegate:execute-via-*` line — delegates refuse a dirty working tree. If `## Dispatch` is missing, print `/delegate:execute-via-<b> <plan> <IDs>` from the row's Runner with the same commit-first note. A delegate row outside step-scope keeps the plain `out of step-scope` note.
3. For each wave, in order:
   1. **Stop before a dependent wave.** If any row in this wave `Depends on` a delegate row that is not `done`, stop. Do not start this wave or any later wave. Print the matching Dispatch lines for those unfinished delegate rows (with the commit-first note from step 2). If this run already implemented rows, run their Acceptance commands plus the Verification commands whose files already exist — step 4's partial-scope rule — then run the Step 5 review loop over this run's diff. If nothing was implemented this run, skip verification and review and say so in the Step 6 summary. Dual-write terminal `partial` once (Status audit #3), then present the Step 6 summary. Do not append a second `runs:` entry.
   2. For every remaining row in the wave with no unmet `Depends on`:
      - **`session` and Files `—`:** a decision or note. Do not edit implementation source. When Review is an external runner (`top@devin-fusion`, `top@cursor-ask`, `top@agy-plan`) and the host tool is not that runner's tool (`top@devin-fusion` → Devin, `top@cursor-ask` → Cursor, `top@agy-plan` → agy), do not run the row: dual-write it `skipped` with Notes `out of step-scope (dispatch via delegate:review)` and print its `/delegate:review` Dispatch line (the `## Dispatch` line whose command names this ID; if `## Dispatch` is missing or no line names this ID, print `/delegate:review <plan> <ID>`). When the host is that runner's tool, or Review is anything else, do the row in this session, record the outcome, and mark it `done` in this wave's dual-write.
      - **Any other `session` row** (Files lists paths, or a legacy map has no Files column): launch one top-tier `Task` (`generalPurpose`). The orchestrator never edits source.
      - **`subagent`:** launch **one `Task` (`generalPurpose`) per step**, model from Model resolution. Same-wave Tasks run **in parallel**.
   3. Wait for the wave. **Orchestrator quality gate (lint before tests):** each Task report must show **lint+tests status** — (a) lint/type-check results when those tools exist, (b) tests added/updated or justified skip, (c) no failing commands in scope. On failure, **stop the wave** — do not start later waves; dual-write status (Status audit #2) then ask or resume that step. If any step reports unresolved issues, ask the user how to proceed before continuing to review. An in-session `session` row is done when its decision or note is recorded; it does not run this gate.
   4. Next wave only after every prior in-wave Task passed the gate; dual-write status after each successful wave (Status audit #2).
4. After the **last** wave this run implemented: when step-scope covers every map row that is not yet `done` (this run finishes the plan), run the full Verification suite once via a mid-tier Task unless the last wave already ran an equivalent full suite successfully. Otherwise (partial scope), run only the in-scope rows' Acceptance commands plus the Verification commands whose files already exist; list every deferred Verification command in the Step 6 summary and never fix forward into out-of-scope rows.

Track each Task's agent ID, map tier, and resolved platform model for the final report and resume-on-fix.

## Step 5 — Review loop (independent review; final pass top-review)

`Read` [review.md](review.md) and follow its loop.

The final top pass uses the strongest Review among the rows this run marked `done` (`none` < `mid` < `top@*`). Do not count a row skipped for `delegate:review`. When several `top@*` values tie, use the `top@*` from the last wave this run marked `done`.

If this run skipped a `session` + Files `—` row for `delegate:review`: do not run the in-host final top pass, and do not print a second, different command. When any row was marked `done`, run the mid-tier loop until clean, then stop that loop. When no row was marked `done`, skip the review loop and say so in the Step 6 summary. Report `final top-tier review: deferred` and repeat each such row's `/delegate:review <plan> <ID>` line — the same line Step 4 printed (the `## Dispatch` line whose command names that ID, or `/delegate:review <plan> <ID>` when Dispatch is missing or names no such ID). Terminal status stays `partial` until that ID form passes.

Otherwise, when that strongest Review is an external runner on another tool (`top@devin-fusion`, `top@cursor-ask`, or `top@agy-plan` whose tool is not the host), whether or not every in-scope row is `done`: when any row was marked `done`, run the mid-tier loop until clean, then do not run the in-host final top pass and do not send the review to Cursor, Devin, or agy. Print `/delegate:review <plan> base=<Step 3 HEAD> runner=<x>` and report `final top-tier review: deferred`. If a base and an ID are both required, print one line that includes the ID (`/delegate:review <plan> <ID> base=<Step 3 HEAD> runner=<x>`), never a second command. Terminal status stays `partial` until `/delegate:review` passes.

`top@session`, `top@claude-task`, or an external runner whose tool is the host (`top@cursor-ask` on Cursor, `top@devin-fusion` on Devin, `top@agy-plan` on agy) runs in-host — the same top-tier pass this loop already runs. When the strongest Review is `mid` or `none`, the in-host loop stands. Those in-host paths apply only when no `session` + Files `—` row was skipped for `delegate:review` and the strongest Review among `done` rows is one of those.

## Step 6 — Final summary

Dual-write terminal status first (Status audit #3). If a delegate-dependency stop already wrote that terminal `runs:` entry, present from it and do not write another. Present: plan path (note if map was drafted/persisted this run); **plan lock** (matched, or the legacy-plan warning); **step-scope** (the IDs, or the whole map) and any `out of step-scope` rows; **delegate** rows skipped `out of step-scope (dispatch via delegate)` and the Dispatch lines printed for them — with the note to `/commit` this run's changes first, since delegates refuse a dirty tree; **audit** (`execution.status`, `progress_pct`, `steps_done`/`steps_total`, `last_skill`); files changed; test/coverage results; deferred Verification commands (partial scope); verification/review skipped (delegate stop before any implementation); **orchestrator** model; **each implementer/fix Task** (map ID, tier, resolved model, lint+tests status); **each reviewer** (tier `mid` for intermediate passes, `top` for the final pass or escalation — review.md still names those passes `auto` and `opus`; resolved model); whether the **final top-tier review converged** (`clean` or `dirty` — `/critique change` keys off this); **reviews** — the strongest Review among rows this run marked `done` (not rows skipped for `delegate:review`). If a `session` + Files `—` row was skipped for `delegate:review`: report `final top-tier review: deferred`, repeat that row's `/delegate:review <plan> <ID>` line from Step 4, and do not print a different command (not converged; terminal status stays `partial` until that ID form passes); if no row was marked `done`, say the review loop was skipped. Otherwise, when that strongest Review is an external runner on another tool, even if some in-scope rows are not `done`: report `final top-tier review: deferred` and the single line `/delegate:review <plan> base=<Step 3 HEAD> runner=<x>` (include `<ID>` on that same line when an ID is also required; not converged; terminal status stays `partial` until `/delegate:review` passes). Otherwise name the in-host final (`top@session`, `top@claude-task`, or a matching host, or the in-host loop when the strongest Review is `mid` or `none`); remaining notes; clear statement that changes are **uncommitted**.

Offer: `/critique change` · `/commit` · `/gh-create-pr` (clean tree / commits first). Do not commit or push unless explicitly asked.

## Constraints

- Implementers and the review subagent must be **different agents** — never resume an implementer for review; never use the reviewer to apply fixes.
- Ask rather than guess when a fix is unclear.
