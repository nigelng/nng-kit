---
name: execute-via-cursor
description: >-
  Hand a fleet plan under docs/plans/** to Cursor's agent CLI for
  implementation, then Claude reviews the result against the plan (diff +
  Verification) with a short FIX resume loop. Alternative to in-process
  /execute-plan. Claude does not implement; Cursor does. Args: [plan-file]
  [step-scope] [safe|no-force] [model=<slug>]. Use when the user asks for
  /delegate:execute-via-cursor (or /execute-via-cursor) or wants Cursor CLI to
  implement a fleet plan while Claude gates and reviews.
argument-hint: "[plan-file] [step-scope] [safe|no-force] [model=<slug>]"
allowed-tools: Read, Write, Edit, Glob, Grep, Task, Bash(bash:*), Bash(git:*), Bash(agent:*), Bash(which:*), Bash(mkdir:*), Bash(rm:*), Bash(cd:*), Bash(date:*)
disable-model-invocation: true
---

# execute-via-cursor

`/delegate:execute-via-cursor`: **Cursor (`agent`) implements**; Claude gates,
briefs, and reviews. Never commit without a separate `/commit`.

Read [execute-via-core.md](../../references/execute-via-core.md) first (arg
parse, Steps 1–8, Model default, Status audit, exit codes, shared constraints),
plus [brief-template.md](../../references/brief-template.md),
[execution-status.md](../../references/execution-status.md), and
[model-tiers.md](../../references/model-tiers.md). Follow core. Do not
hand-build `agent` argv. `<skill-dir>` is this file's absolute directory; paste
that literal path into every `bash` call (shell variables do not persist).

## Parameter binding

| Placeholder | Value for `execute-via-cursor` |
| --- | --- |
| `<backend>` | `cursor` |
| `<last_skill>` | `execute-via-cursor` |
| `<brief>` | `.claude/tmp/exec-cursor-brief.md` |
| `<rows-json>` | `.claude/tmp/exec-cursor-rows.json` |
| `<fix-n>` | `.claude/tmp/exec-cursor-fix-<n>.md` |
| `<questions>` | `.claude/tmp/exec-cursor-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-cursor-<n>.{ndjson,err,exit}` |

## Step 1.1 — Cursor preflight

Run before core Step 1.2. Stop on failure.

1. **`which agent`.** Missing → stop: install the Cursor CLI (`agent`) and
   sign in with `agent login`.
2. **`agent models`.** Failure (not signed in) → stop and say `agent login`.
   Keep the printed slugs. Choose the slug only after `<rows-json>` exists.

## Model default (Cursor)

After Step 4 writes `<rows-json>`, before Step 5, follow
[execute-via-core.md § Model default](../../references/execute-via-core.md).
The pin is the Cursor chain for `launch_tier` (strongest selected tier), not
always `execute`. Use the **cursor** block in
[model-tiers.md](../../references/model-tiers.md). Pass dotted CLI slugs
(`grok-4.7-high`, `composer-2.5`), not hyphenated summary spellings
(`grok-4-7-high`).

| `launch_tier` | First pin | Pin absent from `agent models` |
| --- | --- | --- |
| `execute` | `grok-4.7-high` | `--model auto`, `fallback: pin missing` |
| `low` | `composer-2.5` | `--model auto`, `fallback: pin missing` |
| `mid` | `grok-4.7-high` | `--model auto`, `fallback: pin missing` |

**Cursor model rule:** `execute` / `mid` / `low` use Grok, Composer 2.5, or
Auto only. Claude only for `top-plan` / `top-review`, or a manual `model=`
override. Never GPT.

**`router: true`** and no `model=`: pass `--model auto`. Record
`model_requested: auto`, `model_resolved: auto(router)`, `effort: unknown`,
`fallback: null`. Do not copy the CLI display label.

`model=<slug>` overrides the pin and must be listed by `agent models` (`auto`
is allowed); otherwise stop and show that list. `model=auto` is
`fallback: model=auto`. A listed pin that then fails usage or quota is core
Step 6: one `auto` relaunch, and only for `execute`, `mid` and `low`. Do not
relaunch a run that already used `auto`.

## Script calls

`<model>` and `<requested-slug>` are the slug from Model default. `batch` and
`terminal` use this `<last_skill>` and `<rows-json>`; their flags are core
Status audit. Exit codes and the FIX loop are core Steps 5–8.

```bash
bash <skill-dir>/../../scripts/plan-status.sh lock <plan>
bash <skill-dir>/../../scripts/plan-status.sh rows <plan> cursor [ID...] > .claude/tmp/exec-cursor-rows.json
bash <skill-dir>/../../scripts/plan-status.sh start <plan> execute-via-cursor .claude/tmp/exec-cursor-rows.json --now <TS>
bash <skill-dir>/../../scripts/delegate-launch.sh [--interactive] cursor /absolute/repo/root <n> <model> brief
bash <skill-dir>/../../scripts/delegate-launch.sh [--interactive] cursor /absolute/repo/root <n> <model> fix:<n> [session_id]
bash <skill-dir>/../../scripts/delegate-verdict.sh cursor /absolute/repo/root <n> <requested-slug>
```

Step 5 default: background `brief` (`run_in_background: true`; do not `sleep`).
`safe` / `no-force`: `--interactive` only, then skip Steps 3 and 6. Step 6 is
`delegate-verdict.sh` only — do not parse `.ndjson` here. Step 8: `fix:<n>`,
passing `session_id` when Step 6 returned one. Step 7 verification is core's
verify script (`delegate-verify.sh`).

## Flags

| Arg | Effect |
| --- | --- |
| `safe`, `no-force` | Interactive. Claude never invokes `agent`. Print `--interactive` and wait. |
| `model=<slug>` | Overrides the `launch_tier` pin. Validate with `agent models`. |
| (no `model=`) | Pin for `launch_tier`, or `--model auto` when `router: true` (`auto(router)`). |

`--force`, `--trust`, `stream-json`, `--stream-partial-output`, `--workspace`,
and `--resume` are inside `delegate-launch.sh`, not skill args. Do not pass
`--yolo`.

## Constraints

In addition to core Shared constraints:

- Never commit, push, or open a PR. Propose a Conventional Commit and offer
  `/commit`.
- Never hand-build `agent` argv, and never invoke `agent` on `safe` /
  `no-force`. Launch only through `delegate-launch.sh`; classify only through
  `delegate-verdict.sh`.
- Never treat `--trust` alone or `--force` alone as headless-ready, and never
  prefer `--yolo`. The script pairs both and sets `--workspace` to the recorded
  absolute repo root.
- `model_resolved` is a display label (for example `Grok 4.7 256K High`), not
  the slug. That difference is not a mismatch. Router runs record
  `auto(router)` and ignore the label.
- Cursor subagent writes surface only as a top-level `taskToolCall`. `git diff`
  and untracked files (Step 7) are the source of truth.
- **`agent` must never** edit the plan (YAML frontmatter or `## Execution log`)
  or act as the reviewer.
