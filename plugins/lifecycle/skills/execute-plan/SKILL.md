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

> **Under /conduct:** Step 3 dirty-tree and critique-plan prompts and Step 6 offers are handled by the conductor; see [../conduct/stage-overrides.md](../conduct/stage-overrides.md#execute-plan). Standalone behaviour is unchanged.

**References (read when needed):** [implementer.md](implementer.md) · [review.md](review.md) · [execution-status.md](execution-status.md) · [../make-plan/drafting-rules.md](../make-plan/drafting-rules.md)

## Preconditions

**Requires Agent mode.** If you are in Plan or Ask mode, stop and tell the user to switch to Agent mode before continuing.

**Orchestrator model (top-review).** Session/Task tiers: [model-tiers.md](model-tiers.md) (`top`/`mid`/`low`). Warn once if the session is below **top-review** and recommend switching before delegating. The orchestrator does **not** edit implementation source files — only locates the plan, manages the map, dual-writes plan status/log (see Status audit), launches Tasks, and summarizes. Plan-file map and status edits remain allowed.

## Step 1 — Locate the plan

Args: `[plan] [step-scope IDs…]`. The first argument is a path under `docs/plans/**` or a plan slug/timestamp. Any further arguments are step-scope IDs (`S1`, `I2`, …). Resolve slugs against `docs/plans/` only.

**Recency.** When several files match, pick the most recent per [execution-status.md](execution-status.md) § Plan recency. `*.notes.md` is never a plan — ignore it in listings and matches. If the argument is a notes file, stop and point at the sibling plan. Do not sort raw filenames.

If no plan argument, list `docs/plans/*.md` except `*.notes.md`, then ask the user to pick (`AskQuestion` when available).

**Step-scope.** With no IDs, every map row is in scope. With IDs, a map row not named is outside scope. `rows` reports those as `skipped` (`out of step-scope`, or `out of step-scope (top row: run in session)`). An ID that is not on the map is a `rows` refusal — quote stderr and do not `start`.

If the user points at `.cursor/plans/`, stop and tell them to promote via `/make-plan` into `docs/plans/**` first. If missing/unreadable, stop. Do **not** execute raw `~/.claude/plans/`; require `docs/plans/**`.

## Step 2 — Read and parse the plan

Extract: Purpose, Scope, Assumptions, Dependencies, Implementation steps, Execution map (v2 or legacy), `## Dispatch` when present, Files to modify/create, Verification, Success criteria, Rollback, Risks.

If a section is ambiguous or referenced files do not exist, ask a focused clarifying question before proceeding. A legacy plan may have no `## Dispatch` and no Runner / Files / Acceptance / Review columns; Step 2.75 accepts that map. Tier aliases are normalized there.

## Step 2.5 — Refuse if blocked or incomplete

Hard stop (not a clarifying question) if any of:

- Explicit unresolved **"Blocked on"** note
- Missing **Success criteria** section
- Missing **Verification** section

State the condition and next step: resolve the blocker, or `/make-plan update <path>`, then re-invoke `/execute-plan`. Ambiguous *content* inside an existing section → clarifying question (Step 2).

## Step 2.6 — Plan lock

`<skill-dir>` is the absolute directory of this `SKILL.md`. Do not reimplement the hash. Do not write status on this step. A script refusal is the hard stop: quote stderr verbatim.

```bash
bash <skill-dir>/scripts/plan-status.sh lock <plan>
```

- Exit 0, stdout `ok` → continue.
- Exit 0, stdout `legacy` (stderr `WARN: legacy plan (no plan_sha)`) → warn and continue.
- Exit 3 or exit 2 → stop. Quote stderr.

## Step 2.75 — Execution map (required before implement)

Do **not** invent silent sequential steps. An Execution map must exist and be validated before Step 4.

Accept a v2 or legacy map. Column sets, defaults, and the remaining Review constraints live in [../make-plan/drafting-rules.md](../make-plan/drafting-rules.md) § Map v2 rules. Do not restate per-tool pins.

### Map present

```bash
mkdir -p .claude/tmp
bash <skill-dir>/scripts/plan-status.sh rows <plan> claude-code [ID…] \
  > .claude/tmp/exec-claude-rows.json
```

Pass step-scope IDs when the user gave them. Warn not to commit the rows file. Exit 3 or exit 2 → delete that file, quote stderr verbatim, stop. Do not `start`. Exit 0 with `selected: []` is not a refusal (only skips remain). `blocked` is `[{id, on}]` for an in-scope row that depends on an unfinished delegate row or on a blocked row — not a refusal.

Do not re-check tier, Runner, Model, Review, review batches, or selected-row Files overlap — `rows` does. Tier `—` is unscheduled (`skipped` / `not scheduled`, or a refusal if that ID was requested). Do **not** rewrite the map unless the user asks.

Still confirm every Implementation step has a map ID (or clear sub-bullet coverage). A gap is a hard stop: name it and send the user to `/make-plan update <path>`. A legacy map with no Files column keeps the inferred overlap check: same-wave rows must not share write paths. Conflict → ask to re-wave or serialize.

**Hard follow:** never collapse the map into a single whole-plan Task; never invent extra implementation steps outside the map without explicit user approval.

### Map absent

If the plan has **`plan_sha`** (Step 2.6 did not warn `legacy plan (no plan_sha)`): **hard stop.** Do not draft a map, split Implementation bullets, or write `## Execution map` into the plan body — re-stamping would break the approved hash. State that the Execution map is missing from an approved plan; the user must add it with `/make-plan update <path>`, then re-invoke `/execute-plan`.

**Legacy (no `plan_sha` only)** — draft-confirm-persist in place:

1. Draft a v2 map biased to **smallest mechanical units**: tiers `low` for tightly scoped work, `execute` for interface-level work, `mid` for judgment; avoid `top` for implement rows. Use the drafting-rules columns (Runner, Files, Acceptance, Review). Prefer parallel waves when Files do not overlap. Split coarse steps into map rows (and plan bullets).
2. Present for confirmation (`AskQuestion`: approve / revise / abort).
3. **On approve:** write `## Execution map` into the **same plan file** (after Implementation steps if present), then re-read.
4. **On revise:** iterate until approved — do not start Step 3/4 until confirmed. **On abort:** stop.
5. If Implementation steps are too coarse for a safe map, offer `/make-plan update <path>`; default remains in-place map (+ split bullets as needed).

Re-run `rows` after legacy confirm/persist. A refusal is the hard stop, quoted verbatim, before Step 4.

## Step 3 — Pre-flight checks

1. Project root: `git rev-parse --show-toplevel` (else cwd).
2. `git status --short` and `git diff HEAD` for baseline.
3. If working tree not clean, warn and ask proceed / stash / abort.
4. Determine test / build / lint / type-check tooling from manifests, Verification, and common config.
5. Build a **Quality toolkit** for every implementation Task: unit/integration commands (prefer path-scoped), lint, type-check/format-check, and **Coverage** (if Verification says available: command + target, else plan target or **90%**; if not available, do not invent a gate).
6. **Optional:** if the plan was not stress-tested via `/critique plan` and does not record `Plan size: small`, offer that first; do not block if they decline.

## Status audit (orchestrator dual-write)

Do not hand-edit the plan. `plan-status.sh` writes the schema, `%`, placement, and the dual-write. `<rows-json>` is `.claude/tmp/exec-claude-rows.json`. One UTC stamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) is `--now` on `start` and `--started` on `terminal`. Exit 3 or 2 → quote stderr and stop.

1. **Start** — after Step 3 and map validation, before or as Step 4 begins:

```bash
bash <skill-dir>/scripts/plan-status.sh start <plan> execute-plan .claude/tmp/exec-claude-rows.json --now <TS>
```

Exit 4 (stderr `plan already completed; confirm re-execute`) → ask. On confirm, rewrite the rows file and restart (new `<TS>`):

```bash
bash <skill-dir>/scripts/plan-status.sh rows --reexecute <plan> claude-code [ID…] \
  > .claude/tmp/exec-claude-rows.json
bash <skill-dir>/scripts/plan-status.sh start <plan> execute-plan .claude/tmp/exec-claude-rows.json --now <TS> --reexecute
```

Decline → stop. `start` marks `selected` rows `pending` (prior `done` stays unless `--reexecute`) and writes `skipped` notes from the rows file unless the row is `done`.

2. **After each wave** (success or wave-failure stop):

```bash
bash <skill-dir>/scripts/plan-status.sh batch <plan> execute-plan --done ID… [--failed ID…] [--skipped ID --note TEXT]
```

3. **Terminal** — once, at Step 6 or an earlier abort/hard stop. Skip when a delegate-dependency stop already wrote this run's `runs:` entry. Implementer models comma-separated in run order; `--model-resolved` is what the Tasks ran on; `--effort` their tier efforts likewise; no Task ran → `none` for all three. `--findings` = `blocking` + `important`. `--fix-loops` = fix rounds after review. `--fallback` is `null` or the reason. Omit `--usage`. `--notes`: one short paragraph; never claim `completed`. Every call but a clean finish passes `--done` with this run's completed IDs.

**End states** (Steps 4–6 cite it; do not restate outcomes):

| End state | Call |
| --- | --- |
| `delegate:review` skip | `batch <plan> execute-plan --skipped <ID> --note 'out of step-scope (dispatch via delegate:review)'` |
| Delegate-dependency stop, or deferred final review | `terminal … --outcome pass --deferred-review` |
| Clean finish | `terminal … --outcome pass` |
| Failed wave | `terminal … --outcome fail` |
| User abort | `terminal … --outcome abort` |

```bash
bash <skill-dir>/scripts/plan-status.sh terminal <plan> execute-plan .claude/tmp/exec-claude-rows.json \
  --outcome pass|fail|abort --backend claude-code \
  --model-requested <slugs> --model-resolved "<slugs>" --effort <efforts> \
  --started <TS> --findings <N> --fix-loops <N> --fallback "<reason-or-null>" \
  [--deferred-review] [--done ID…] [--notes "<TEXT>"] [--now <TS>]
```

## Step 4 — Delegate implementation by waves

Do **not** send the whole plan to a single subagent. Orchestrate from the validated Execution map only. For quality bar, Task prompt, and full verification details, `Read` [implementer.md](implementer.md).

### Model resolution (per map tier) — implementers

Resolve `top`, `mid`, and `low` via [model-tiers.md](model-tiers.md). Resolve `execute` to the host's `execute` pin when that host lists one; otherwise `mid` (claude-code lists no `execute` row, so an in-process `execute` row is `mid`). Always set the model explicitly; if you can't, stop and tell the user before delegating.

### Wave schedule

1. Group in-scope map rows by **Wave** (ascending). Leave rows that are already `done` as `done`. Decide what to launch from the current step-scope, Runner, and status — never from Notes left by an earlier run.
2. **Delegate rows.** Do not implement a `delegate:*` row here. Print the matching `## Dispatch` lines now (each line whose command names those IDs), and tell the user to `/commit` this run's changes before running any `/delegate:execute-via-*` line — delegates refuse a dirty working tree. If `## Dispatch` is missing, print `/delegate:execute-via-<b> <plan> <IDs>` from the row's Runner with the same commit-first note. A delegate row outside step-scope keeps the plain `out of step-scope` note.
3. For each wave, in order:
   1. **Stop before a dependent wave.** A row listed in `blocked`, or any row in this wave that `Depends on` a delegate row that is not `done`: stop. Do not start this wave or any later wave. Print the matching Dispatch lines for those unfinished delegate rows (with the commit-first note from step 2). If this run already implemented rows, run step 4's partial-scope verification, then the Step 5 review loop over this run's diff. If nothing was implemented this run, skip verification and review and say so in the Step 6 summary. Then the delegate-dependency-stop row of the end-state table, once, and present the Step 6 summary. Do not call `terminal` again.
   2. For every remaining row in the wave with no unmet `Depends on`:
      - **`session` and Files `—`:** a decision or note. Do not edit implementation source. When Review is an external runner (`top@devin-fusion`, `top@cursor-ask`, `top@agy-plan`) and the host tool is not that runner's tool (`top@devin-fusion` → Devin, `top@cursor-ask` → Cursor, `top@agy-plan` → agy), do not run the row: the `delegate:review` skip row of the end-state table, and print its `/delegate:review` Dispatch line (the `## Dispatch` line whose command names this ID; if `## Dispatch` is missing or no line names this ID, print `/delegate:review <plan> <ID>`). When the host is that runner's tool, or Review is anything else, do the row in this session, record the outcome, and mark it `done` in this wave's `batch`.
      - **Any other `session` row** (Files lists paths, or a legacy map has no Files column): launch one top-tier `Task` (`generalPurpose`). The orchestrator never edits source.
      - **`subagent`:** launch **one `Task` (`generalPurpose`) per step**, model from Model resolution. Same-wave Tasks run **in parallel**.
   3. Wait for the wave. **Orchestrator quality gate (lint before tests):** each Task report must show **lint+tests status** — (a) lint/type-check results when those tools exist, (b) tests added/updated or justified skip, (c) no failing commands in scope. On failure, **stop the wave** — do not start later waves; `batch` the failed rows (Status audit #2; end-state table: failed wave) then ask or resume that step. If any step reports unresolved issues, ask the user how to proceed before continuing to review. An in-session `session` row is done when its decision or note is recorded; it does not run this gate.
   4. Next wave only after every prior in-wave Task passed the gate; `batch --done` after each successful wave (Status audit #2).
4. After the **last** wave this run implemented, verify in this session per [implementer.md](implementer.md) § Full verification. When step-scope covers every map row not yet `done`, the commands file is the full Verification suite unless the last wave already ran that suite. Otherwise (partial scope): in-scope Acceptance commands plus Verification commands whose files already exist. List every deferred command in the Step 6 summary. Never fix forward into out-of-scope rows.

Track each Task's agent ID, map tier, and resolved platform model for the final report and resume-on-fix.

## Step 5 — Review loop (independent review; final pass top-review)

`Read` [review.md](review.md) and follow its loop.

The final top pass uses the strongest Review among the rows this run marked `done` (`none` < `mid` < `top@*`). Do not count a row skipped for `delegate:review`. When several `top@*` values tie, use the `top@*` from the last wave this run marked `done`.

If this run skipped a `session` + Files `—` row for `delegate:review`, or the strongest Review is an external runner on another tool (`top@devin-fusion`, `top@cursor-ask`, or `top@agy-plan` whose tool is not the host), whether or not every in-scope row is `done`: do not run the in-host final top pass. For a skipped row, the Dispatch line is Step 4's. Otherwise Step 4 printed no `/delegate:review` line: print `/delegate:review <plan> base=<Step 3 HEAD> runner=<x>` (`<ID>` on that line when an ID is also required). Print exactly one `/delegate:review` command in total, however many rows were skipped. When any row was marked `done`, run the mid-tier loop until clean, then stop that loop, and do not send the review to Cursor, Devin, or agy. When no row was marked `done`, skip the review loop and say so in the Step 6 summary. Outcome: the deferred-final-review row of the end-state table.

When the strongest Review is `mid` or `none`, the in-host loop stands. The in-host final (`top@session`, `top@claude-task`, a matching host) and the `mid`/`none` loop apply only when no `session` + Files `—` row was skipped for `delegate:review` and the strongest Review among `done` rows is one of those.

## Step 6 — Final summary

Run the matching end-state row first (Status audit #3). If a delegate-dependency stop already wrote that `runs:` entry, present from it and do not write another. Present: plan path (note if map was drafted/persisted this run); **plan lock** (matched, or the legacy-plan warning); **step-scope** (the IDs, or the whole map) and any `out of step-scope` rows; **delegate** rows skipped `out of step-scope (dispatch via delegate)` and the Dispatch lines printed for them; **audit** (`execution.status`, `progress_pct`, `steps_done`/`steps_total`, `last_skill`); files changed; test/coverage results; deferred Verification commands (partial scope); verification/review skipped (delegate stop before any implementation); **orchestrator** model; **each implementer/fix Task** (map ID, tier, resolved model, lint+tests status); **each reviewer** (tier `mid` for intermediate passes, `top` for the final pass or escalation — review.md still names those passes `auto` and `opus`; resolved model); whether the **final top-tier review converged** (`clean` or `dirty` — `/critique change` keys off this); **reviews** — the strongest Review among rows this run marked `done` (not rows skipped for `delegate:review`). Report the Step 5 deferral when one applies (same command already printed: Step 4's for a skipped row, else Step 5's; not converged; outcome is the end-state table). Otherwise name the in-host final (`top@session`, `top@claude-task`, or a matching host, or the in-host loop when the strongest Review is `mid` or `none`). Remaining notes. Changes are **uncommitted**.

Offer: `/critique change` · `/commit` · `/gh-create-pr` (clean tree / commits first). Do not commit or push unless explicitly asked.

## Constraints

- Implementers and the review subagent must be **different agents** — never resume an implementer for review; never use the reviewer to apply fixes.
- Ask rather than guess when a fix is unclear.
