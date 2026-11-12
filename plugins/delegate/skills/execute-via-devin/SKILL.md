---
name: execute-via-devin
description: >-
  Delegate a structured plan to the Devin CLI. Claude gates preflight, reviews
  the diff, and drives PASS / FIX / FAIL. Args: [plan-file] [step-scope]
  [safe|no-force] [model=<slug>]. Use for `/delegate:execute-via-devin`.
argument-hint: "[plan-file] [step-scope] [safe|no-force] [model=<slug>]"
allowed-tools: Read, Write, Edit, Glob, Grep, Task, AskUserQuestion, Bash(bash:*), Bash(git:*), Bash(devin:*), Bash(which:*), Bash(find:*), Bash(mkdir:*), Bash(rm:*), Bash(cd:*), Bash(date:*)
disable-model-invocation: true
---

# execute-via-devin

**Devin (`devin`) implements**; **Claude gates, briefs, and reviews**. Never commit without a separate `/commit`. Claude Code only.

Read [execute-via-core.md](../../references/execute-via-core.md) first (arg parse, Steps 1–8, status audit, model default, shared constraints), plus [brief-template.md](../../references/brief-template.md), [execution-status.md](../../references/execution-status.md), and [model-tiers.md](../../references/model-tiers.md).

Do not hand-build headless `devin` argv. `<skill-dir>` is this file's directory; paste that literal absolute path:

- `bash <skill-dir>/../../scripts/plan-status.sh` — status writes
- `bash <skill-dir>/../../scripts/delegate-launch.sh` — launch (keeps relative `--export=.claude/tmp/...`)
- `bash <skill-dir>/../../scripts/delegate-verdict.sh` — classify the run

## Parameter bindings

| Placeholder | Value |
| --- | --- |
| `<backend>` | `devin` |
| `<last_skill>` | `execute-via-devin` |
| `<brief>` | `.claude/tmp/exec-devin-brief.md` |
| `<fix-n>` | `.claude/tmp/exec-devin-fix-<n>.md` |
| `<rows-json>` | `.claude/tmp/exec-devin-rows.json` |
| `<questions>` | `.claude/tmp/exec-devin-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-devin-<n>.{json,out,err,exit}` |

Run files are export JSON, stdout, stderr, and exit status (not `ndjson`).

## Step 1.1 — Devin preflight

Run at core Step 1.1, before repo-root and plan checks. Stop on failure. Do not copy account names, emails, or credential paths into the plan, brief, or status log.

1. **PATH:** `which devin`. If missing, stop: `brew install --cask devin-cli`, then `devin auth login`.
2. **Auth:** `devin auth status` must show a line beginning `Logged in`. Otherwise stop; the user runs `devin auth login`.
3. **Models:** `devin models`. A slug is usable only when listed **exactly** in `devin models`. A family name (`gpt-6.1-terra`, `swe-2`) is not an exact effort slug. Show `devin models` when refusing a user slug.

### Slug refusals

For execution (`model=` and pins): Refuse `adaptive`. Refuse any `fusion-*` slug. Refuse any slug not listed **exactly** in `devin models`.

Before `<slug>` is used in a command it must match `^[A-Za-z0-9._-]+$`. A failure is refused:

```bash
[[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refuse: invalid slug"; exit 1; }
```

### Pin per `launch_tier`

List models here. Choose the slug at core **Model default**, after Step 4 writes the rows file.

- **`model=<slug>`** — only after the refusals and regex.
- **Omitted** — first unexpired Devin pin for `launch_tier` (`low`, `execute`, or `mid`) in [model-tiers.md](../../references/model-tiers.md) that is listed **exactly** in `devin models`. Skip a row when today is after its `until:`. Skip a pin absent from `devin models`.
  - `execute`: `swe-2-high` (`until: 2026-11-30`) → `gpt-6-1-terra-high` (that pin once today is past 2026-11-30).
  - `mid`: `gpt-6-1-sol-high` → `gemini-4-argon-medium` (`until: 2026-12-01`).
  - `low`: `swe-2-flash-high` → `claude-haiku-5-5-high`.
- **None resolves** — stop and ask for `model=<slug>`. Never Auto, `adaptive`, or Fusion as a default. Those chains have no `auto` fallback, including after a usage or quota error. Do not pass a family name. `router` is never true for Devin.

Pass the slug as `--model` through `delegate-launch.sh` (always). The env allowlist drops `DEVIN_REFUSAL_FALLBACK`. `safe` / `no-force` prints `delegate-launch.sh --interactive`; Claude never invokes `devin`. The prompt follows `--` (a bare positional is a PATH and opens Devin Desktop).

Then core Steps 1.2–8.

## After the verdict — delete the run files

`.json`, `.out`, and `.err` can hold secrets from tool output. After a terminal verdict (**PASS**, **FAIL** after the FIX budget, or user **abort**), the terminal status write, and the user report, delete Devin run files from the repo root:

```bash
find .claude/tmp -maxdepth 1 -type f -name 'exec-run-devin-*' -delete
```

`find … -delete` is used instead of an `rm` glob because zsh errors when a glob matches nothing. Do this on every terminal path, including FAIL before any rollback, and never between FIX rounds (a FIX round needs the previous export's `session_id`). Leave brief, fix, and questions files (plan text Claude wrote). `safe` / `no-force` writes no run files.

## `devin` flags

`delegate-launch.sh` emits these. Do not assemble argv. Value flags use `=` (the space form swallows the next argument, exit 2).

| Flag / mode | Behavior | Headless? |
| --- | --- | --- |
| `--permission-mode dangerous` | Auto-approves tools | **Yes** |
| `--permission-mode` omitted | Prompts; print mode cannot | **No** — `safe` / `no-force` |
| `--respect-workspace-trust=false` | Skip workspace-trust check | **Yes** — `=` form |
| `--print=` | Print mode | Required; `=` |
| `--export=` | ATIF JSON, relative `.claude/tmp/...` | Required; `=` |
| `--resume=` | Resume verdict `session_id` | FIX when captured; `=` |
| `--model <slug>` | Exact effort slug (space form) | Always |
| `cwd` (no `--workspace`) | Workspace is cwd | Script `cd`s to the repo root |
| `safe` / `no-force` | Not a `devin` flag | `--interactive` only |

## Devin constraints

Plus core **Shared constraints**:

- **Never `--continue` or `-c`.** Resume only with `--resume=<session_id>`. `--continue` attaches to the latest conversation.
- **For execution, never `adaptive`, `fusion-*`, or a family name** (`model=` and pins). Fusion runs only as the `top@devin-fusion` reviewer via `delegate-review-launch.sh` (core Step 7).
- **Exit 0 is not success.** `delegate-verdict.sh` must return `ok: true` (export present, last step source `agent`, one model equal to the slug). Empty list → `no resolved model`. A mid-run fallback is FAIL.
- **Delete run files** on every terminal path, never between FIX rounds.
- **Trust:** the default headless path passes `--permission-mode dangerous` (every tool auto-approved) and `--respect-workspace-trust=false` (Devin's workspace-trust check skipped), so repo-local Devin config and anything the plan or repo tells the agent to run executes unattended. Use it only on repositories you trust; otherwise use `safe` / `no-force`.
- **Data egress:** repo contents and the brief go to Cognition under the signed-in account. Briefs quote plan text and paths only — never secrets or `.env` contents.
