---
name: execute-via-agy
description: >-
  Delegate implementation of a structured plan to Google's Antigravity CLI
  (`agy` in headless mode) while Claude Code gates preflight, reviews the
  resulting diff, and drives a PASS / FIX / FAIL loop. Args: [plan-file]
  [step-scope] [safe|no-force] [model=<slug>]. Use when the user invokes
  `/delegate:execute-via-agy` or asks to hand a plan to Antigravity / agy for
  implementation with Claude reviewing.
argument-hint: "[plan-file] [step-scope] [safe|no-force] [model=<slug>]"
allowed-tools: Read, Write, Edit, Glob, Grep, Task, AskUserQuestion, Bash(git:*), Bash(agy:*), Bash(which:*), Bash(bash:*), Bash(mkdir:*), Bash(rm:*), Bash(cd:*), Bash(date:*)
disable-model-invocation: true
---

# execute-via-agy

**Antigravity (`agy`) implements**; Claude gates, briefs, reviews, and may propose commit text. Never commit without a separate `/commit`.

Read [execute-via-core.md](../../references/execute-via-core.md) first (arg parse, Steps 1–8, Status audit, model default, shared constraints) and [model-tiers.md](../../references/model-tiers.md). `<skill-dir>` is this file's directory; paste that literal absolute path into every script call. Shell variables do not persist.

## Parameter bindings

| Placeholder | Value |
| --- | --- |
| `<backend>` | `agy` |
| `<last_skill>` | `execute-via-agy` |
| `<brief>` | `.claude/tmp/exec-agy-brief.md` |
| `<fix-n>` | `.claude/tmp/exec-agy-fix-<n>.md` |
| `<questions>` | `.claude/tmp/exec-agy-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-agy-<n>.{ndjson,err,exit}` |
| `<rows-json>` | `.claude/tmp/exec-agy-rows.json` |

## Step 1.1 — agy preflight

Run before core repo-root and plan checks. Stop on failure.

1. **Install:** `which agy`. If missing, stop. Install with `brew install --cask antigravity-cli`. Export `AGY_CLI_DISABLE_AUTO_UPDATE=true` so Homebrew stays the sole updater.
2. **Probe:** `agy models` (`>/dev/null` when no `model=` override; capture stdout when checking a slug). If it fails or cannot tell signed-in from signed-out:

   ```bash
   agy --output-format json -p "reply ok"
   ```

   Require `.status == "SUCCESS"` or `.result.status == "SUCCESS"`. On auth failure, stop: run `agy` once interactively and sign in.
3. **Folder trust:** `agy` has no headless trust flag. If a run reports an untrusted workspace or stalls on trust, stop and tell the user to open `agy` once interactively in that repo root and grant folder trust.
4. **Model list:** confirm the slug from **Model default** (or `model=<slug>`) is in `agy models` before launch. If not, stop, show the list, and ask.

Then core Steps 1.2–1.5 (repo root, plan, clean tree, `plan-status.sh lock`) and Steps 2–4.

## Model default

Follow core **Model default**. After Step 4 writes `<rows-json>`, and before Step 5, resolve agy's pin for `launch_tier` (`low`, `execute`, or `mid`) from the agy per-tool bullets in [model-tiers.md](../../references/model-tiers.md): first unexpired slug that `agy models` lists. Skip a row past its `until:` date. Do not copy the summary block (it rewrites `.` as `-`). Pass the slug via `delegate-launch.sh`.

Current chains (model-tiers wins if they differ), all `until: 2026-11-26`: `low` = `gemini-3.8-flash-high`; `execute` and `mid` = `gemini-4-argon-medium` → `gemini-3.8-flash-high`.

Those chains do not name `auto`. If no slug resolves, **stop and ask** for `model=<slug>`. Do not pass Auto unless core does: explicit `model=auto` (`fallback: model=auto`) or `router: true`. A usage or quota failure does not relaunch on Auto.

## Scripts

Do not hand-build plan-run `agy` argv. Launch only through `delegate-launch.sh`; classify only through `delegate-verdict.sh`; write plan status only through `plan-status.sh`. Replace `<skill-dir>` and `/absolute/repo/root` with literal paths:

```bash
bash <skill-dir>/../../scripts/plan-status.sh lock <plan>
bash <skill-dir>/../../scripts/plan-status.sh rows <plan> agy [ID...] > .claude/tmp/exec-agy-rows.json
bash <skill-dir>/../../scripts/plan-status.sh start <plan> execute-via-agy .claude/tmp/exec-agy-rows.json --now <TS>
bash <skill-dir>/../../scripts/delegate-launch.sh agy /absolute/repo/root <n> <model> brief
bash <skill-dir>/../../scripts/delegate-launch.sh --interactive agy /absolute/repo/root <n> <model> brief
bash <skill-dir>/../../scripts/delegate-launch.sh agy /absolute/repo/root <n> <model> fix:<k> [session_id]
bash <skill-dir>/../../scripts/delegate-verdict.sh agy /absolute/repo/root <n> <requested-slug>
```

`batch` / `terminal`: core Status audit (`terminal` gets `--backend agy`). `safe` FIX: `--interactive … fix:<k>` with no resume id. Script exit 2: stop and show stderr.

Headless: `run_in_background: true`; wait for completion; do not sleep-poll. Exit 0 means `.exit` was written. `safe` / `no-force`: print the interactive line, do not invoke `agy`, skip the verdict, then core Step 7 (`Task`). FIX passes verdict `session_id` when set.

## `agy` exit codes

Applied by `delegate-verdict.sh`. Exit `0` is not success by itself.

| Exit | Meaning |
| --- | --- |
| `0` | Success — also on permission soft-denies, tool errors, and print-timeout (`finished_reason: print_timeout`) |
| `1` | Bad model, agent, or schema |
| `2` | CLI usage / flag error |
| `3` | API failure, with `AGY_ERROR:` on stderr |

## Flags and modes

Reference only. The launch script passes the headless flags. Do not assemble argv from this table.

| Flag / mode | Behavior | Headless? |
| --- | --- | --- |
| `--dangerously-skip-permissions` | Auto-approves edits and shell | **Yes** — required |
| `--mode accept-edits` | Edits only; shell soft-denied, still exits `0` | **No** |
| Neither (default) | Prompts; headless soft-denies tools, still exits `0` | **No** — `safe` / `no-force` only |
| `-p "<prompt>"` | Headless prompt | Required |
| `--output-format stream-json` | NDJSON; `conversation_id` on first `init` | Required |
| `--conversation <id>` | Resume `init.conversation_id` | FIX when `session_id` is set |
| `--model <slug>` | **Model default** pin, or `model=<slug>` | Always; checked in `agy models` |
| `cwd` (no `--workspace`) | Workspace is the working directory | Script `cd`s to the repo root |
| `safe` / `no-force` | Skill mode, not an `agy` flag | User runs the interactive line |

## agy constraints

Plus core **Shared constraints**:

- Never pass `--continue`. Resume only via `delegate-launch.sh` and the verdict `session_id`.
- Never read `~/.gemini` transcripts. The contract is `.claude/tmp/exec-run-agy-<n>.ndjson` plus `delegate-verdict.sh`.
- Never treat exit `0` alone as success. Require verdict `ok: true` (SUCCESS, `finished_reason` not `print_timeout` / `interrupted` / `error`, no `AGY_ERROR` or permission soft-deny on stderr).
- Never hand-build plan-run `agy` argv.
