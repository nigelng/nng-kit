---
name: execute-via-devin
description: >-
  Delegate implementation of a structured plan to the Devin CLI (`devin` in
  headless print mode) while Claude Code gates preflight, reviews the
  resulting diff, and drives a PASS / FIX / FAIL loop. Args: [plan-file]
  [step-scope] [safe|no-force] [model=<slug>]. Use when the user invokes
  `/delegate:execute-via-devin` or asks to hand a plan to Devin for
  implementation with Claude reviewing.
argument-hint: "[plan-file] [step-scope] [safe|no-force] [model=<slug>]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(devin:*), Bash(env:*), Bash(which:*), Bash(mkdir:*), Bash(rm:*), Bash(find:*), Bash(cd:*), Bash(cat:*), Bash(jq:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Bash(ls:*), Bash(date:*), Bash(echo:*), Bash(grep:*), AskUserQuestion
disable-model-invocation: true
---

# execute-via-devin

Claude Code–only alternative to `/execute-plan` and sibling of `/delegate:execute-via-cursor` and `/delegate:execute-via-agy`: **the Devin CLI (`devin`) implements** the plan on a branch, while **Claude gates, briefs, reviews**, and may propose commit text. Never commit without a separate `/commit`.

**Shared workflow & references (read before executing):**

- [execute-via-core.md](../../references/execute-via-core.md) — shared arg parse, Step 1 generic gates, Step 2 plan validation & branch divert, Status audit, Step 3 background runtime gates, Step 4 stale-tmp cleanup & brief writing, Step 7 independent review, Step 8 verdict loop, and shared constraints.
- [brief-template.md](../../references/brief-template.md) — implementation brief template.
- [execution-status.md](../../references/execution-status.md) — plan status dual-write schema, `%` formula, and placement rules.

Follow every step in [execute-via-core.md](../../references/execute-via-core.md) with the `devin` bindings and backend hooks below.

## Parameter bindings

| Placeholder | Value for `execute-via-devin` |
| --- | --- |
| `<backend>` | `devin` |
| `<last_skill>` | `execute-via-devin` |
| `<brief>` | `.claude/tmp/exec-devin-brief.md` |
| `<fix-n>` | `.claude/tmp/exec-devin-fix-<n>.md` |
| `<questions>` | `.claude/tmp/exec-devin-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-devin-<n>.{json,out,err,exit}` |

## Step 1 — Backend preflight (`devin` CLI, auth & model check)

Run these checks at Step 1.1 of [execute-via-core.md](../../references/execute-via-core.md), before proceeding to repo-root and plan checks. Stop and report on any failure.

1. **`devin` on `PATH`:**

   ```bash
   which devin
   ```

   If missing, stop and give install instructions: `brew install --cask devin-cli`, then `devin auth login`.

2. **Auth:** run `devin auth status`. It must report signed in (a line beginning `Logged in`). Otherwise **stop** and tell the user to run `devin auth login`. Do not copy account names, emails, or credential paths into the plan, the brief, or the status log.

3. **Model — always an exact pinned slug (never Auto):**
   - Refuse `adaptive`. Refuse any `fusion-*` slug. Refuse any slug that is not listed **exactly** in `devin models` (a family name such as `gpt-6.1-terra` or `swe-2` is not an exact effort slug). Show `devin models` when refusing a user-supplied slug.
   - When `model=<slug>` is given, use that slug only after the checks above. Before `<slug>` is used in any command it must **also** match `^[A-Za-z0-9._-]+$`, in addition to the exact `devin models` match. A slug that fails the regex is refused. Never put a user-supplied value in a command without this check:

     ```bash
     [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refuse: invalid slug"; exit 1; }
     ```
   - When `model=` is **omitted**, resolve the first unexpired Devin `execute` pin from [model-tiers.md](../../references/model-tiers.md): `swe-2-high` (`until: 2026-11-30`) → `gpt-6-1-terra-high`. Skip a row when the local date is after its `until:` date (`today > until`). With today faked past 2026-11-30 the default pin is `gpt-6-1-terra-high`. Skip a pin that is not listed exactly in `devin models` and try the next unexpired pin.
   - If no pin resolves → **stop and ask the user for `model=<slug>`**. Never fall back to `adaptive`, Fusion, or a family name.

   ```bash
   devin models
   ```

Then continue with Step 1.2–1.4 (repo root `cd`, plan file check, clean working tree), Step 2 (plan validation, branch divert, Base SHA), Status audit (start write with `last_skill: execute-via-devin`), Step 3 (background runtime gates unless `safe` / `no-force`), and Step 4 (clear stale `devin`-only tmp files and write `.claude/tmp/exec-devin-brief.md`) per [execute-via-core.md](../../references/execute-via-core.md).

## Step 5 — Run Devin (`devin`)

Pick a new run id `<n>` per implement/FIX round (`1`, `2`, …).

Devin has **no `--workspace` flag**. Its workspace is `cwd`. Always `cd` to the literal absolute repo root recorded in Step 1.2 in the same command before invoking `devin`.

Unset `DEVIN_REFUSAL_FALLBACK` for every headless run (`env -u DEVIN_REFUSAL_FALLBACK`). When set, it switches models on a refusal, so the export's `model_name` can differ from the pin.

Optional-value flags `--print`, `--export`, `--respect-workspace-trust`, and `--resume` **must** use the `=` form. The space form makes the parser swallow the next argument (exit 2 usage error).

### Default (`--permission-mode dangerous`, headless background)

Invoke via Bash with `run_in_background: true` (do **not** poll with `sleep`). `<slug>` is the exact effort slug resolved in Step 1.

```bash
cd /abs/root && env -u DEVIN_REFUSAL_FALLBACK devin --model <slug> --permission-mode dangerous --respect-workspace-trust=false \
  --export=.claude/tmp/exec-run-devin-<n>.json --print="Read .claude/tmp/exec-devin-brief.md and follow it exactly." \
  > .claude/tmp/exec-run-devin-<n>.out 2> .claude/tmp/exec-run-devin-<n>.err; echo $? > .claude/tmp/exec-run-devin-<n>.exit
```

- Replace `/abs/root` with the **literal** absolute repo root recorded in Step 1.2 (never rely on `$REPO_ROOT` across Bash calls).
- Always pass `--model <slug>` (user `model=<slug>` or the Devin `execute` pin). Never omit it.
- Wait for Claude Code's **background-task completion notification** — never sleep-poll.

### `safe` / `no-force` mode (interactive user terminal)

Do **not** pass `--permission-mode` and do **not** invoke `devin` from Claude.

Print the exact interactive command for the user to run in their own terminal:

```bash
cd /abs/root && devin --model <slug> -- "Read .claude/tmp/exec-devin-brief.md and follow it exactly."
```

The prompt **must** follow `--`: a bare positional is treated as a PATH (it opens Devin Desktop instead of starting a prompt).

Wait for the user to confirm completion, then proceed directly to **Step 7** in [execute-via-core.md](../../references/execute-via-core.md) (skipping Step 6, since interactive mode does not write the export, `.out`, or `.exit` files).

## Step 6 — Parse the export (default path only)

Run only for Claude-invoked background runs (`safe` / `no-force` skips straight to Step 7). The contract is the `--export` JSON file (ATIF), not stdout. Summarize with `jq` — do **not** read a large export whole into context.

1. **Resume handle** (`session_id`):

   ```bash
   session_id=$(jq -r '.session_id' .claude/tmp/exec-run-devin-<n>.json)
   ```

   Before `<session_id>` is used in any command (this resume handle and Step 8 `--resume=<session_id>`) it must match `^[A-Za-z0-9_-]{1,64}$`. It is never expanded from raw file contents without this check:

   ```bash
   [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || session_id=""
   [[ "$session_id" != "null" ]] || session_id=""
   ```

   Record it so Step 8 FIX rounds can pass `--resume=<session_id>` even if the run stopped early. Empty, `null`, or a value that fails the regex is treated as no session_id: **FAIL** (`no session_id`), there is no resume handle, and Step 8 takes the fresh-run fallback.

2. **Blocking questions:** if `.claude/tmp/exec-devin-questions.md` exists and is non-empty, read it, relay the questions via `AskUserQuestion`, and once answered resume that session with the user's answers (or fold them into the next round).

3. **Success predicate.** A clean run requires **all** of the following:
   - `.claude/tmp/exec-run-devin-<n>.exit` is `0`
   - `.claude/tmp/exec-run-devin-<n>.json` exists
   - The last step's source is `agent`:

     ```bash
     jq -r '.steps[-1].source' .claude/tmp/exec-run-devin-<n>.json
     ```
   - `session_id` is present and valid (non-empty, not `null`, matches `^[A-Za-z0-9_-]{1,64}$`; item 1)
   - The unique step `model_name` list is non-empty, has exactly one entry, and that validated entry equals the requested `<slug>` (item 4)

4. **Resolved model must equal the requested slug.** Read the whole list of unique step models and check all of it, not just the first entry:

   ```bash
   models=()
   while IFS= read -r line; do models+=("$line"); done < <(jq -r '[.steps[].model_name // empty] | unique | .[]' .claude/tmp/exec-run-devin-<n>.json)
   re='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
   resolved=()
   for model in "${models[@]}"; do
     [[ "$model" =~ $re && "$model" != null ]] || model='auto(unresolved)'
     resolved+=("$model")
   done
   model_resolved=$(IFS=,; printf '%s' "${resolved[*]}")
   [[ ${#models[@]} -eq 1 && "$model_resolved" == "$slug" ]] || model_ok=0
   ```

   Each `model_name` is untrusted CLI output: an entry that is `null` or fails the pattern is replaced by `auto(unresolved)`. `model_resolved` is the validated list joined with `,` (a single value for a one-model run). Write it YAML-quoted in `runs:` (for example `model_resolved: "gpt-6-1-terra-high"`, or `"swe-2-high,gpt-6-1-terra-low"` for a multi-model run) and use the same validated value in the `Run:` line and in any `model mismatch` text.

   The run passes the model check **only** when the unique list has exactly one entry (`${#models[@]}` is `1`) and that validated entry equals the `<slug>` passed to `--model`.
   - Empty list (no step has a `model_name`): **FAIL** (`no resolved model`), never PASS.
   - More than one unique entry (a mid-run fallback, even when one of them equals `<slug>`), or a single entry that differs from `<slug>`: **FAIL**. Record `fallback: model mismatch <requested>→<resolved>` with `<resolved>` set to `model_resolved` (never PASS).

   A family name silently resolves to a default effort; that mismatch is a failure, not a successful fallback.

5. **Exit 1 with no export** is **FAIL**. Stderr often says `Upgrade to Pro` or `Unknown model` when the account cannot use the slug. Surface `.claude/tmp/exec-run-devin-<n>.err`.

Anything else (non-zero exit, missing export, last step source other than `agent`, missing, `null`, or invalid `session_id`, no resolved model) → **failed run**. When a `session_id` was captured, Step 8 may still resume it.

After Step 6, run **Step 7 (Claude review)** from [execute-via-core.md](../../references/execute-via-core.md): inspect `git status`, `git diff <BaseSHA>`, untracked files, and re-run the plan's Verification commands yourself.

## Step 8 — Verdict loop & FIX resume

Follow **Step 8** and **Status audit** in [execute-via-core.md](../../references/execute-via-core.md) (`last_skill: execute-via-devin`).

When the verdict is **FIX** (max **2** rounds):

1. Write numbered issues to `.claude/tmp/exec-devin-fix-<round>.md` (keep `.claude/tmp/exec-devin-brief.md` intact) and increment the run counter `<n>`.
2. **Default (when `session_id` was captured):** resume that session in the background (`run_in_background: true`). `<session_id>` is the literal value from Step 6 and must already have passed the `^[A-Za-z0-9_-]{1,64}$` check there.

   ```bash
   cd /abs/root && env -u DEVIN_REFUSAL_FALLBACK devin --model <slug> --permission-mode dangerous --respect-workspace-trust=false \
     --export=.claude/tmp/exec-run-devin-<n>.json --resume=<session_id> \
     --print="Read .claude/tmp/exec-devin-fix-<round>.md and fix every issue listed." \
     > .claude/tmp/exec-run-devin-<n>.out 2> .claude/tmp/exec-run-devin-<n>.err; echo $? > .claude/tmp/exec-run-devin-<n>.exit
   ```

3. **Fallback (when no valid `session_id` was captured):** start a fresh background run (no `--resume`) that reads both the brief and the fix file:

   ```bash
   cd /abs/root && env -u DEVIN_REFUSAL_FALLBACK devin --model <slug> --permission-mode dangerous --respect-workspace-trust=false \
     --export=.claude/tmp/exec-run-devin-<n>.json \
     --print="Read .claude/tmp/exec-devin-brief.md and .claude/tmp/exec-devin-fix-<round>.md and fix every issue listed." \
     > .claude/tmp/exec-run-devin-<n>.out 2> .claude/tmp/exec-run-devin-<n>.err; echo $? > .claude/tmp/exec-run-devin-<n>.exit
   ```

4. **`safe` / `no-force`:** print the numbered fixes and the `.claude/tmp/exec-devin-fix-<round>.md` path for the user to run in their interactive session, with the command `cd /abs/root && devin --model <slug> -- "Read .claude/tmp/exec-devin-fix-<round>.md and fix every issue listed."` (the prompt follows `--`). Wait for confirmation, then re-run Step 7. Do not invoke `devin`.

### After the verdict — delete the run files

The export (`.json`) is the full conversation, including tool output, so it, `.out` and `.err` can hold secrets the agent read (for example from an `.env` file). Once the verdict is terminal — **PASS**, **FAIL** after the FIX budget, or user **abort** — and after the terminal Status audit write and the report to the user (which already quoted anything needed from `.err`), delete every Devin run file from the repo root:

```bash
find .claude/tmp -maxdepth 1 -type f -name 'exec-run-devin-*' -delete
```

`find … -delete` is used instead of an `rm` glob because zsh errors when a glob matches nothing. Do this on every terminal path, including FAIL before any rollback, and never between FIX rounds (a FIX round needs the previous export's `session_id`). Leave the brief, fix and questions files: Claude wrote them and they hold only plan text. `safe` / `no-force` runs write no run files, so there is nothing to delete.

## `devin` flags & permission modes

| Flag / Mode | Behavior | Sufficient for headless `/delegate:execute-via-devin`? |
| --- | --- | --- |
| `--permission-mode dangerous` | Auto-approves all tools | **Yes** — required so Verification commands can run headlessly |
| `--permission-mode` omitted (default `auto`) | Prompts; print mode cannot prompt | **No** — interactive `safe` / `no-force` only |
| `--respect-workspace-trust=false` | Skip the workspace-trust check (print mode cannot show the prompt) | **Yes** — pass it on every headless run, using `=` |
| `--print=<prompt>` | Non-interactive print mode | Required for headless runs; use `=` |
| `--export=<path>` | Write the ATIF conversation JSON after the turn | Required; this file is the Step 6 contract; use `=` |
| `--resume=<session_id>` | Resume the session from `jq -r '.session_id'` | Required for Step 8 when a session id was captured; use `=` |
| `--model <slug>` | Exact effort slug (space form) | Always passed; validated against `devin models` in Step 1 |
| `cwd` (no `--workspace`) | Workspace is the current directory | Always `cd /abs/root` before invoking `devin` |
| `safe` / `no-force` | Skill mode (not a `devin` flag) | User runs the interactive command; Claude never invokes `devin` |

## Devin-specific constraints

In addition to all **Shared constraints** in [execute-via-core.md](../../references/execute-via-core.md):

- **Never pass `--continue` or `-c`.** Resume only with `--resume=<session_id>` from the export. `--continue` attaches to whichever conversation is most recent.
- **Never Fusion or Adaptive.** Do not pass `adaptive` or any `fusion-*` slug. Do not pass a family name. Unset `DEVIN_REFUSAL_FALLBACK` so a refusal cannot switch models.
- **Never treat exit `0` alone as success.** The export file must exist, `jq -r '.steps[-1].source'` must be `agent`, the unique list of step `model_name`s must be non-empty (otherwise `no resolved model`) and have exactly one validated entry equal to the requested slug. More than one unique model (a mid-run fallback) or any difference is `fallback: model mismatch <requested>→<resolved>` (`<resolved>` is the validated models joined with `,`) and the run is FAIL.
- **Delete run files after the verdict.** `.claude/tmp/exec-run-devin-*` can hold secrets; remove them on every terminal path (see Step 8 "After the verdict"), never between FIX rounds.
- **Trust:** the default headless path passes `--permission-mode dangerous` (every tool auto-approved) and `--respect-workspace-trust=false` (Devin's workspace-trust check skipped), so repo-local Devin config and anything the plan or repo tells the agent to run executes unattended. Use it only on repositories you trust; otherwise use `safe` / `no-force`.
- **Data egress:** repository contents and the `.claude/tmp` brief are sent to Cognition under the signed-in account. Briefs quote plan text and file paths only — never secrets or `.env` contents.
