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
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(agy:*), Bash(which:*), Bash(mkdir:*), Bash(rm:*), Bash(cd:*), Bash(cat:*), Bash(jq:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Bash(ls:*), Bash(date:*), Bash(echo:*), Bash(grep:*), AskUserQuestion
disable-model-invocation: true
---

# execute-via-agy

Claude Code–only alternative to `/execute-plan` and sibling of `/delegate:execute-via-cursor`: **Google's Antigravity CLI (`agy`) implements** the plan on a branch, while **Claude gates, briefs, reviews**, and may propose commit text. Never commit without a separate `/commit`.

**Shared workflow & references (read before executing):**

- [execute-via-core.md](../../references/execute-via-core.md) — shared arg parse, Step 1 generic gates, Step 2 plan validation & branch divert, Status audit, Step 3 background runtime gates, Step 4 stale-tmp cleanup & brief writing, Step 7 independent review, Step 8 verdict loop, and shared constraints.
- [brief-template.md](../../references/brief-template.md) — implementation brief template.
- [execution-status.md](../../references/execution-status.md) — plan status dual-write schema, `%` formula, and placement rules.

Follow every step in [execute-via-core.md](../../references/execute-via-core.md) with the `agy` bindings and backend hooks below.

## Parameter bindings

| Placeholder | Value for `execute-via-agy` |
| --- | --- |
| `<backend>` | `agy` |
| `<last_skill>` | `execute-via-agy` |
| `<brief>` | `.claude/tmp/exec-agy-brief.md` |
| `<fix-n>` | `.claude/tmp/exec-agy-fix-<n>.md` |
| `<questions>` | `.claude/tmp/exec-agy-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-agy-<n>.{ndjson,err,exit}` |

## Step 1.0 — Parked gate (`AGY_ENABLED`)

Before Step 1 preflight, and before any brief, tmp file, plan audit write, or call to `agy`:

If the environment variable `AGY_ENABLED` is not exactly `1`, stop immediately and report this message only:

`agy is parked; set AGY_ENABLED=1 to re-enable`

Write nothing (no brief, no tmp files, no plan audit write) and do not call `agy`.

## Step 1 — Backend preflight (`agy` CLI, auth & model check)

Run these checks at Step 1.1 of [execute-via-core.md](../../references/execute-via-core.md) only after Step 1.0 has passed, before proceeding to repo-root and plan checks. Stop and report on any failure.

1. **`agy` on `PATH`:**

   ```bash
   which agy
   ```

   If missing, stop and give install instructions:
   - Install the Homebrew cask: `brew install --cask antigravity-cli`
   - Disable self-auto-update so Homebrew stays the sole updater: export `AGY_CLI_DISABLE_AUTO_UPDATE=true` in your shell / Claude environment.

2. **Auth & model probe:**
   Run `agy models` (`agy models >/dev/null` when no `model=` override is passed, or capture the output when validating `<slug>`).
   - If `agy models` fails or cannot distinguish signed-in from signed-out state, fall back to a trivial headless probe:

     ```bash
     agy --output-format json -p "reply ok"
     ```

     and verify `.status == "SUCCESS"` (or `.result.status == "SUCCESS"`).
   - On auth failure, **stop** and tell the user: *"run `agy` once interactively and sign in"*.
   - **Folder trust note:** `agy` does not document a headless `--trust` flag. If a first headless run in a never-trusted repository reports an untrusted workspace error or stalls on trust, stop and tell the user to open `agy` once interactively in that repository root to grant folder trust.

3. **Model default / optional override:**
   When `model=` is **omitted**, resolve agy's tier `execute` pin from [model-tiers.md](../../references/model-tiers.md) (`gemini-4-argon-medium` → `claude-sonnet-5-5-high`, parked unless `AGY_ENABLED=1`; `--model <slug>` is always passed; Auto only as a logged fallback). If `model=` is omitted and no `execute` slug resolves (every row expired, parked without its enable flag such as `AGY_ENABLED=1`, or missing from the CLI's model list), **stop and ask the user for `model=<slug>`**; never fall back to Auto silently. Verify that the resolved or user-supplied `<slug>` appears in the `agy models` output before launching. If `<slug>` is not recognized, stop, show the available models from `agy models`, and ask the user to pick a valid slug.

Then continue with Step 1.2–1.4 (repo root `cd`, plan file check, clean working tree), Step 2 (plan validation, branch divert, Base SHA), Status audit (start write with `last_skill: execute-via-agy`), Step 3 (background runtime gates unless `safe` / `no-force`), and Step 4 (clear stale `agy`-only tmp files and write `.claude/tmp/exec-agy-brief.md`) per [execute-via-core.md](../../references/execute-via-core.md).

## Step 5 — Run Antigravity (`agy`)

Pick a new run id `<n>` per implement/FIX round (`1`, `2`, …).

Because `agy` has **no `--workspace` flag** (`--add-dir` only adds extra directories), its workspace is always `cwd`. Always `cd` to the literal absolute repo root recorded in Step 1.2 in the same command before invoking `agy`.

### Default (`--dangerously-skip-permissions`, headless background)

Invoke via Bash with `run_in_background: true` (do **not** poll with `sleep`):

```bash
cd /abs/root && agy --dangerously-skip-permissions \
  --output-format stream-json --model <slug> \
  -p "Read .claude/tmp/exec-agy-brief.md and follow it exactly." \
  > .claude/tmp/exec-run-agy-<n>.ndjson 2> .claude/tmp/exec-run-agy-<n>.err; \
  echo $? > .claude/tmp/exec-run-agy-<n>.exit
```

- Replace `/abs/root` with the **literal** absolute repo root recorded in Step 1.2 (never rely on `$REPO_ROOT` across Bash calls).
- Always pass `--model <slug>` using the slug resolved in Step 1 (`model=<slug>` override or agy's `execute` pin from [model-tiers.md](../../references/model-tiers.md); Auto only as a logged fallback).
- Remind the user they can open `/exec` (from the companion `exec-observe` plugin) to watch the live Antigravity run in the side pane.
- Wait for Claude Code's **background-task completion notification** — never sleep-poll.

### `safe` / `no-force` mode (interactive user terminal)

Do **not** pass `--dangerously-skip-permissions` and do **not** invoke `agy` from Claude.

Print the exact interactive command for the user to run in their own terminal:

```bash
cd /abs/root && agy --model <slug> "Read .claude/tmp/exec-agy-brief.md and follow it exactly."
```

Wait for the user to confirm completion, then proceed directly to **Step 7** in [execute-via-core.md](../../references/execute-via-core.md) (skipping Step 6 log parsing since interactive mode does not write `.ndjson` or `.exit` files).

## Step 6 — Parse run logs (default path only)

Run only for Claude-invoked background runs (`safe` / `no-force` skips straight to Step 7). Summarize with `jq`, `head`, `tail`, and `grep` — do **not** read large `.ndjson` files whole into context.

1. **Extract `conversation_id` (session resume handle):**

   ```bash
   jq -r 'select(.event=="init").conversation_id' .claude/tmp/exec-run-agy-<n>.ndjson | head -1
   ```

   Record this `conversation_id` so Step 8 FIX rounds (or question resumes) can pass `--conversation <id>` even if the run stopped early.

   Resolved model for the run record's `model_resolved` (`model`, otherwise `init.model`). The value is untrusted CLI output: nothing, `null`, or a value that fails the pattern is `auto(unresolved)`:

   ```bash
   model=$(jq -r 'select(.event=="init") | (.model // .init.model // empty)' .claude/tmp/exec-run-agy-<n>.ndjson | head -1)
   re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
   [[ "$model" =~ $re && "$model" != null ]] || model='auto(unresolved)'
   ```

   Write `model_resolved` YAML-quoted in `runs:` (for example `model_resolved: "gemini-4-argon-medium"`) and use the same validated value in the `Run:` line. `fallback` is set only from `expired <slug>`, `pin missing`, `quota`, `model=auto`, or `auto(unresolved)`, plus a resolved value equal to `auto` (case-insensitive), which is a router fallback; the resolved model is not compared with the requested slug.

2. **Check blocking questions first:**
   If `.claude/tmp/exec-agy-questions.md` exists and is non-empty, read it, relay the questions to the user via `AskUserQuestion`, and once answered, resume the same conversation (`--conversation <id>`) with the user's answers (or fold into the next round).

3. **Verify clean headless completion:**
   A clean run requires **all** of the following:
   - `.claude/tmp/exec-run-agy-<n>.exit` equals `0`
   - Last NDJSON line has `event == "result"` with `status == "SUCCESS"` (or `result.status == "SUCCESS"`):

     ```bash
     tail -1 .claude/tmp/exec-run-agy-<n>.ndjson | jq -c '{event, status: (.status // .result.status), finished_reason: (.finished_reason // .result.finished_reason)}'
     ```

   - `finished_reason` (or `result.finished_reason`) is **not** `print_timeout`, `interrupted`, or `error`

4. **Inspect stderr for silent failures / soft-denies:**

   Match intentional denial / `AGY_ERROR` notices only — not every line that merely contains `permission` (e.g. `permission_mode` in logs):

   ```bash
   grep -iE 'AGY_ERROR|permission denied|soft-?den(y|ied)|untrusted' .claude/tmp/exec-run-agy-<n>.err || true
   ```

   No match is success: `grep` exit `1` (no lines) means clean for this check (`|| true` keeps the shell non-failing; treat exit `1` as clean if you omit `|| true`). Treat any match (`AGY_ERROR`, permission soft-denial, or untrusted-workspace notice) as a failed/incomplete run and surface `.err` prominently before Step 7 — `agy` exits `0` on permission soft-denies and `--print-timeout`.

### `agy` exit code reference

| Exit code | Meaning |
| --- | --- |
| `0` | Success — **also** returned on permission soft-denies, tool errors, and `--print-timeout` expiry (`finished_reason: print_timeout`) |
| `1` | Bad model, agent, or schema |
| `2` | CLI usage / flag error |
| `3` | API failure, accompanied by an `AGY_ERROR:` line on stderr |

After Step 6, run **Step 7 (Claude review)** from [execute-via-core.md](../../references/execute-via-core.md): inspect `git status`, `git diff <BaseSHA>`, untracked files, and re-run the plan's Verification commands yourself.

## Step 8 — Verdict loop & FIX resume

Follow **Step 8** and **Status audit** in [execute-via-core.md](../../references/execute-via-core.md) (`last_skill: execute-via-agy`).

When the verdict is **FIX** (max **2** rounds):

1. Write numbered issues to `.claude/tmp/exec-agy-fix-<round>.md` (keep `.claude/tmp/exec-agy-brief.md` intact) and increment the run counter `<n>`.
2. **Default (when `conversation_id` was captured):** resume the same conversation in the background (`run_in_background: true`):

   ```bash
   cd /abs/root && agy --dangerously-skip-permissions \
     --output-format stream-json --model <slug> \
     --conversation "$CONVERSATION_ID" \
     -p "Read .claude/tmp/exec-agy-fix-<round>.md and fix every issue listed." \
     > .claude/tmp/exec-run-agy-<n>.ndjson 2> .claude/tmp/exec-run-agy-<n>.err; \
     echo $? > .claude/tmp/exec-run-agy-<n>.exit
   ```

   *(Substitute the literal repo root for `/abs/root` and the literal captured conversation ID for `"$CONVERSATION_ID"`.)*
3. **Fallback (when no `conversation_id` was captured):** start a fresh background run without `--conversation` that reads both `.claude/tmp/exec-agy-brief.md` and `.claude/tmp/exec-agy-fix-<round>.md`:

   ```bash
   cd /abs/root && agy --dangerously-skip-permissions \
     --output-format stream-json --model <slug> \
     -p "Read .claude/tmp/exec-agy-brief.md and .claude/tmp/exec-agy-fix-<round>.md and fix every issue listed." \
     > .claude/tmp/exec-run-agy-<n>.ndjson 2> .claude/tmp/exec-run-agy-<n>.err; \
     echo $? > .claude/tmp/exec-run-agy-<n>.exit
   ```

4. **`safe` / `no-force`:** print the numbered fixes and `.claude/tmp/exec-agy-fix-<round>.md` path for the user to run in their interactive session, wait for user confirmation, then re-run Step 7.

## `agy` flags & permission modes

| Flag / Mode | Behavior | Sufficient for headless `/delegate:execute-via-agy`? |
| --- | --- | --- |
| `--dangerously-skip-permissions` | Auto-approves file edits and shell commands (`run_command`, test suites, linters) | **Yes** — required so `agy` can run Verification commands headlessly |
| `--mode accept-edits` | Auto-approves file edits only; shell commands (`run_command`) are soft-denied in headless mode while still exiting `0` | **No** — Verification test suites cannot run |
| Neither (default mode) | Prompts for edits and shell commands; headless runs soft-deny unapproved tool calls while still exiting `0` | **No** — only usable in interactive `safe` / `no-force` mode |
| `-p "<prompt>"` | Non-interactive print/headless execution of `<prompt>` | Required for headless runs |
| `--output-format stream-json` | Emits NDJSON events (`init`, `step_update`, `result`) on stdout so `conversation_id` is captured on the first `init` line | Required for headless runs and `exec-observe` |
| `--conversation <id>` | Resumes the exact conversation captured from `init.conversation_id` | Required for Step 8 FIX resume |
| `--model <slug>` | Pinned model (`execute` pin from [model-tiers.md](../../references/model-tiers.md) when `model=` omitted, or user `model=<slug>` override) | Always passed; validated against `agy models` in Step 1 (Auto only as a logged fallback) |
| `cwd` (no `--workspace`) | `agy` uses the current working directory as workspace (`--add-dir` only adds extra dirs) | Always `cd /abs/root` before invoking `agy` |

## Agy-specific constraints

In addition to all **Shared constraints** in [execute-via-core.md](../../references/execute-via-core.md):

- **Never pass `--continue`** — it is ambiguous across concurrent or recent conversations. Always resume explicitly with `--conversation <id>` captured from the run's `init` event.
- **Never rely on `~/.gemini` transcripts on disk** — `stream-json` stdout redirected to `.claude/tmp/exec-run-agy-<n>.ndjson` is the sole event contract.
- **Never treat exit `0` alone as success** — always check the terminal `result` event (`status == "SUCCESS"` and `finished_reason` not `print_timeout` / `interrupted` / `error`) and scan `.err` for `AGY_ERROR` or permission soft-denies.
