# Drafting rules (coverage, architecture docs, tiers, waves)

Read when drafting Step 4 content or validating an update. Companion to [plan-template.md](plan-template.md). SoT for coverage, architecture-doc, map v2, Runner policy, and wave rules — skills point here rather than restating.

## Execution scaffold (Step 4–5, required)

Every new plan **must** ship the execution scaffold from [plan-template.md](plan-template.md): YAML frontmatter `execution:` block with `status: not-started` and zeroed progress, plus an empty `## Execution log` placed **immediately after** `## Execution map` and **before** `## Files to modify/create`. Do not append it at EOF. Field meanings and update rules live in `../execute-plan/execution-status.md` (SoT); do not restate them in the plan.

## Test coverage probe (Step 3)

Default numeric target when tooling exists but the repo has no threshold: **90%** (unless the user chooses otherwise after the probe).

1. Inspect manifests/CI for coverage tooling (JS/TS `coverage`/`vitest`/`jest`/`c8`/`nyc`; Python `pytest-cov`/`.coveragerc`; Go `-cover`; Rust `llvm-cov`/`tarpaulin`; CI gates).
2. Record **Available + threshold** (command + percent), **Available, no threshold** (command; use the default above), or **Not available** (do not invent a gate; note in Verification; optional follow-up).
3. If available and the target is still unclear, ask once: repo threshold / that default / Other.

Always record the probe under **Verification**. When available: include command + numeric target; prefer map/Implementation rows that close coverage gaps. When not: say so — no fake percentage or non-existent command.

## Update documentation (architecture docs)

Every new plan **must** include Implementation step(s) **and** matching Execution-map row(s) to **update** relevant architecture docs (or **create** under `docs/architecture/` if the Step 3 scan found none and the change affects system shape), **or** an explicit **justified skip** in Scope or Implementation.

**Scan (Step 3):** `Glob` / `Grep` / `Read` for architecture documentation. Default hints: `docs/architecture/**`, `**/ARCHITECTURE*`, `**/architecture/**`, README Architecture links, and Archify artifacts under `docs/architecture/`. Record paths for Assumptions / Dependencies / a short Architecture docs note. If a canonical prose doc (e.g. `OVERVIEW`) names a diagram or path, treat that as canonical; else prefer the newest `docs/architecture/**` artifact by folder timestamp; never ground on historical folders that disagree with the canonical doc.

- **Prefer updating** `docs/architecture/OVERVIEW.md` and the **canonical** Archify / diagram path from the scan over inventing parallel docs.
- **Justified skip** — allowed only for pure chore / docs-only / formatting with **no** change to: runtime topology, config contracts, control plane, trust boundaries, or subsystem ownership. One line is enough (e.g. in Scope or the Implementation docs step).
- **Verification** must be execute-checkable (`git diff` / Files show those architecture-doc paths changed as listed, **or** the one-line skip is present). Recording scan paths in Assumptions/Dependencies alone does **not** satisfy Verification.
- **Success criteria** must say architecture docs reflect the shape change, or that the skip is recorded.

On **update**, if the change alters system shape or Scope, re-run the scan and add/adjust the docs step + map row, or the justified skip. Pure wording-only plan edits may keep the prior note if Scope/shape is unchanged.

## Map v2 rules (when writing the map)

Columns and generation rules for the Execution map. Do not restate per-tool pins; resolution stays in [model-tiers.md](model-tiers.md).

**Tier:** `top` | `execute` | `mid` | `low`. Never write `sonnet`. Legacy labels map over: `opus` → `top`, `auto` / `sonnet` → `mid`, `haiku` → `low`.

**Detail by tier:**

- `low` — exact edits, paths and commands.
- `execute` — interface, test cases and the helpers to use.
- `mid` — judgment within a stated design.
- `top` — planning, decisions or review only.

**Runner:** `session` | `delegate:cursor` | `delegate:devin` | `delegate:agy` | `subagent`.

- `top` rows use only `session` or `subagent`, never `delegate:*`.
- Missing Runner: `top` → `session`, anything else → `subagent`.
- Which Runner a row gets: [Runner policy](#runner-policy).

**Files:** repo-relative paths; `—` when a row writes nothing. No overlap within a wave. Escape a literal pipe in a cell as `\|`.

**Acceptance:** one runnable command; `—` allowed only on `top` rows. Escape a literal pipe in a cell as `\|`.

**Model:** empty, or `auto` only with `low` + `delegate:cursor` (recorded as `auto(router)`).

**Review:** `top@session` | `top@claude-task` | `top@devin-fusion` | `top@cursor-ask` | `top@agy-plan` | `mid` | `none`.

- Missing Review → `mid`.
- `none` only on `low` rows with an Acceptance command.
- Rows in one (wave, runner) batch share a single `top@*` value.

**Dispatch generation:**

- Waves in ascending order. Within a wave, `session` and `subagent` rows go in one `/execute-plan <plan> <IDs>` line, and each `delegate:<b>` gets one `/delegate:execute-via-<b> <plan> <IDs>` line.
- Insert a `/commit` line before every `/delegate:execute-via-<b>` line that has any execution line before it — delegates refuse a dirty working tree.
- Then one review line per wave at the strongest Review per batch (`none` < `mid` < `top@*`).
- Batch reviews for delegate rows run inside the delegate run, at the batch's strongest Review; the per-wave review line is informational.
- **Small plans** (see Small plans below) omit the per-wave review lines entirely.
- Then one final whole-branch review line naming the final `top` | `session` review row `<ID>` (Review `top@claude-task` unless the planner names another `top@*`): `Final whole-branch review — top@<x> — /execute-plan <plan> <ID>` for `top@session` / `top@claude-task`, else `Final whole-branch review — top@<x> — /delegate:review <plan> <ID>`.

**Size budget:** keep the body (per SoT in `../execute-plan/execution-status.md`) under about 15 KB. Risk registers, decision records and long evidence go to a sibling `<plan-file>.notes.md` (same basename with `.notes.md` in place of `.md`), which only `top` rows and reviews read.

## Small plans

A plan is **small** when all of these hold:

- The map has at most 4 non-`top` rows, all in wave 1.
- There is exactly one `top` row: the final whole-branch review.
- The planner judges it touches no trust boundary (auth, secrets, permissions, CI credentials, network exposure).

When small, record `- **Plan size:** small` under **Assumptions** (in the body, so the plan lock covers it). A missing Plan size line means normal plan behavior.

Effects:

1. Dispatch omits the per-wave review lines and keeps only the final whole-branch review line.
2. `/make-plan`'s closing offer does not recommend `/critique plan` (still offered on request).
3. `/execute-plan`'s review loop starts at the top-tier final pass — no mid passes. A dirty final follows the existing dirty-final path (fix → re-verify → one mid confirmation → stop).

The hard cap is unchanged.

## Runner policy

SoT for which Runner each map row gets. Record this line under **Assumptions**, in the body, so the [plan lock](../execute-plan/execution-status.md#plan-lock) covers it:

- **Runner policy:** <mode> [<list>]

Missing → `auto`.

List members: `cursor`, `devin`, `agy`, `subagent`. Write `delegate:<member>` for `cursor`, `devin`, and `agy`; write `subagent` for `subagent`. The default list for `round-robin`, when the list is omitted, is the active delegates in [planning fallback order](model-tiers.md) (`cursor`, `devin`, `agy`).

**Eligible** = the tool is active per [model-tiers.md](model-tiers.md) (not past `until:`, not parked) and has a pin for the row's tier. A `subagent` list member is eligible for every non-`top` row. `top` rows are never eligible for delegates (they stay `session` or `subagent`). The modes below assign non-`top` rows only.

- `auto` — the planner's choice (today).
- `pin <tool>` — every non-`top` row → `delegate:<tool>` if that delegate is eligible, else `subagent`. `pin subagent` writes `subagent` on every non-`top` row.
- `order <list>` — each non-`top` row → the first eligible member.
- `round-robin [<list>]` — the rotation advances from wave to wave. Per wave, assign that wave's non-`top` rows to the next member. A row that member can't take goes to the next eligible member in list order (walk the list from that member, wrapping). A member eligible for none of the wave's rows is skipped without consuming the turn.

Same-wave **Files** overlap rules still apply across runners. **Dispatch** generation is unchanged: one line per (wave, runner), and a `/commit` before each delegate line.

Never write a runner the policy didn't pick. If no member is eligible, use `subagent` and say why in the row's Step summary.

## Wave / parallel rules

- Same **Wave** number → independent (no shared write paths, no ordering dependency) → `/execute-plan` may run them **in parallel**.
- Higher wave waits on listed `Depends on` IDs.
- Split large steps until most rows are `low`, `execute`, or `mid`; avoid “do the feature” mega-steps.
- Prefer many small steps over few large ones when it does not create thrash (shared file conflicts → serial in the same wave or a later wave).
