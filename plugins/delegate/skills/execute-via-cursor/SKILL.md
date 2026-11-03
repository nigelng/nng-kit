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
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(agent:*), Bash(which:*), Bash(mkdir:*), Bash(rm:*), Bash(cd:*), Bash(jq:*), Bash(test:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Bash(echo:*), Bash(cat:*)
disable-model-invocation: true
---

# execute-via-cursor

Claude Code–only alternative to `/execute-plan` in the `delegate` plugin
(`/delegate:execute-via-cursor`): **Cursor (`agent`) implements**, Claude
**gates, briefs, reviews**, and may propose commit text. Never commit without a
separate `/commit`.

**Shared workflow & contracts (read first):**
- [execute-via-core.md](../../references/execute-via-core.md) — arg parse,
  Steps 1–4, Status audit, Steps 7–8, and shared constraints.
- [brief-template.md](../../references/brief-template.md) — Step 4 brief
  template (`{{BACKEND}} = cursor`).
- [execution-status.md](../../references/execution-status.md) — YAML
  frontmatter + `## Execution log` dual-write contract.

## Parameter binding

Bind the placeholders in [execute-via-core.md](../../references/execute-via-core.md)
for this skill:

| Placeholder | Value for `execute-via-cursor` |
| --- | --- |
| `<backend>` | `cursor` |
| `<last_skill>` | `execute-via-cursor` |
| `<brief>` | `.claude/tmp/exec-cursor-brief.md` |
| `<fix-n>` | `.claude/tmp/exec-cursor-fix-<n>.md` |
| `<questions>` | `.claude/tmp/exec-cursor-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-cursor-<n>.{ndjson,err,exit}` |

Follow [execute-via-core.md](../../references/execute-via-core.md) for argument
parsing (`[plan-file] [step-scope] [safe|no-force] [model=<slug>]`), Steps 1–4,
Status audit (`last_skill: execute-via-cursor`), Step 7 review, Step 8 verdict
loop, and shared constraints, plugging in the Cursor-specific sections below.

## Step 1.1 — Cursor preflight

Run before the shared repo-root, plan-file, and clean-tree gates in
[execute-via-core.md § Step 1](../../references/execute-via-core.md):

1. **`agent` on PATH** — run `which agent`. If missing → stop with an
   install/login hint for Cursor CLI (`agent`) and authentication.
2. **Model default / optional override** — when `model=` is **omitted**, use
   Cursor platform **Auto** (do not pass `--model`; never pin Sonnet/Opus by
   default). Aligns with LIFECYCLE delegate Auto default; map-row `haiku` that
   would run under `/execute-plan` may fall back to Auto when haiku is
   unavailable/capped. When the user passed `model=<slug>`, validate `<slug>`
   against `agent models`. If `agent models` fails (not signed in) or `<slug>`
   is not listed → stop and show the available model slugs from `agent models`.

Then complete Steps 1.2–1.4, Step 2, Status audit (Start), Step 3, and Step 4
from [execute-via-core.md](../../references/execute-via-core.md). In Step 4,
clear only `cursor` artifacts:

```bash
mkdir -p .claude/tmp
rm -f .claude/tmp/exec-cursor-brief.md \
      .claude/tmp/exec-cursor-fix-*.md \
      .claude/tmp/exec-cursor-questions.md \
      .claude/tmp/exec-run-cursor-*
```

and write `.claude/tmp/exec-cursor-brief.md` from
[brief-template.md](../../references/brief-template.md) with
`{{BACKEND}} = cursor` and
`{{QUESTIONS_PATH}} = .claude/tmp/exec-cursor-questions.md`.

## Step 5 — Run Cursor

Pick a new run id `<n>` per implement/FIX round (`1`, `2`, …). Include
`--model <slug>` only when `model=<slug>` was passed and validated in Step 1.1;
otherwise omit `--model` so Cursor uses platform **Auto**.

### Default (`--force` + `--trust`)

Invoke via Bash with `run_in_background: true` (do **not** poll with `sleep`):

```bash
agent -p --force --trust --workspace /absolute/repo/root \
  --output-format stream-json --stream-partial-output [--model <slug>] \
  "Read .claude/tmp/exec-cursor-brief.md and follow it exactly." \
  > .claude/tmp/exec-run-cursor-<n>.ndjson 2> .claude/tmp/exec-run-cursor-<n>.err; echo $? > .claude/tmp/exec-run-cursor-<n>.exit
```

Replace `/absolute/repo/root` with the **literal** path recorded in Step 1.2
(or `"$(git rev-parse --show-toplevel)"`). Never leave `--workspace` empty.

Wait for Claude Code's **background-task completion notification**.

**Why these flags:** `--trust` skips the workspace-trust prompt; `--force`
auto-allows tools/shell. Either alone stalls headless background runs. Use
`--output-format stream-json` with `--stream-partial-output` (not `json`) so
`session_id` appears on the first `system`/`init` line even if the run fails
and `exec-observe` can render live stream deltas. Do **not** use `--yolo`
(alias of `--force`).

### `safe` / `no-force`

Claude **never** invokes `agent`. Print the exact interactive command for the
user's terminal (literal absolute `--workspace`, plus `--model <slug>` if
requested):

```bash
agent --trust --workspace /absolute/repo/root [--model <slug>] \
  "Read .claude/tmp/exec-cursor-brief.md and follow it exactly."
```

Wait for the user to say done. Step 3 was skipped (Claude is not running
`agent`). **Skip Step 6** (no `exec-run-cursor-*` logs); proceed directly to
Step 7 review in [execute-via-core.md](../../references/execute-via-core.md).

## Step 6 — Parse Cursor run logs (defensive)

**Claude-invoked `agent` runs only** (default path). `safe` / `no-force`
already skipped this step — do not treat missing logs as a failed run.

Summarize; do **not** read large `.ndjson` files whole into context:

```bash
# session_id (survives failed runs with stream-json)
jq -r 'select(.type=="system" and .subtype=="init").session_id' \
  .claude/tmp/exec-run-cursor-<n>.ndjson | head -1

# exit code (must be 0)
cat .claude/tmp/exec-run-cursor-<n>.exit

# success classification
# PASS only if: .exit is 0 AND last JSON line is type=="result",
# subtype=="success", is_error==false
tail -1 .claude/tmp/exec-run-cursor-<n>.ndjson | jq -c '{type,subtype,is_error}'
```

Anything else → **failed run**: surface `.claude/tmp/exec-run-cursor-<n>.err`;
if `session_id` was captured, Step 8 FIX may still `--resume` it. Ignore
unknown fields (schema drift). Also check for
`.claude/tmp/exec-cursor-questions.md` during Step 7. Optional: cross-check
`tool_call` write events against `git diff`. Writes made inside Cursor
subagents surface only as a top-level `taskToolCall`, not as write events, so
`git diff` + untracked files (Step 7) stay the source of truth.

## Step 8 — Cursor FIX resume commands

Run Step 7 review and Step 8 verdict loop per
[execute-via-core.md](../../references/execute-via-core.md). When the verdict
is **FIX** (max **2** rounds), write numbered fixes to
`.claude/tmp/exec-cursor-fix-<n>.md` (new `<n>` per FIX round; do **not** clear
`.claude/tmp/exec-cursor-brief.md`), then invoke Cursor:

- **Default (with `session_id` from the prior run):**

  ```bash
  agent -p --force --trust --workspace /absolute/repo/root \
    --output-format stream-json --stream-partial-output [--model <slug>] \
    --resume "$SESSION_ID" \
    "Read .claude/tmp/exec-cursor-fix-<n>.md and apply the fixes exactly." \
    > .claude/tmp/exec-run-cursor-<n>.ndjson 2> .claude/tmp/exec-run-cursor-<n>.err; echo $? > .claude/tmp/exec-run-cursor-<n>.exit
  ```

- **If `session_id` is empty/missing** — fresh run (no `--resume`); instruct
  Cursor to read **both** the brief and the fix file and apply the fixes:

  ```bash
  agent -p --force --trust --workspace /absolute/repo/root \
    --output-format stream-json --stream-partial-output [--model <slug>] \
    "Read .claude/tmp/exec-cursor-brief.md and .claude/tmp/exec-cursor-fix-<n>.md; apply the fixes exactly." \
    > .claude/tmp/exec-run-cursor-<n>.ndjson 2> .claude/tmp/exec-run-cursor-<n>.err; echo $? > .claude/tmp/exec-run-cursor-<n>.exit
  ```

  Then re-parse (Step 6) and re-review (Step 7).

- **`safe` / `no-force`:** print the numbered fixes (and
  `.claude/tmp/exec-cursor-fix-<n>.md`) for the user to paste into / point at
  their interactive session; wait for done; re-review. Do not invoke `agent`.

## Cursor `agent` CLI flags (reference)

| Flag / Arg | Role | Notes |
| --- | --- | --- |
| `-p` | Non-interactive print/headless mode | Required for background runs; omitted in `safe` / `no-force` |
| `--force` | Auto-allow tool and shell execution (unless denied) | Alone **not** enough for headless (`--trust` also required) |
| `--trust` | Skip workspace-trust prompt; does **not** auto-approve tools | Alone **not** enough for headless (`--force` also required) |
| `--workspace <abs-path>` | Explicit workspace root directory | Always pass the recorded literal repo root |
| `--output-format stream-json` | Emit NDJSON event stream (`system`/`init` → `tool_call` / `assistant` → `result`) | Captures `session_id` on the first `init` line |
| `--stream-partial-output` | Stream incremental assistant deltas in `stream-json` mode | Used by `exec-observe` for live progress |
| `--resume <session_id>` | Resume prior Cursor session in Step 8 FIX rounds | Fall back to fresh run reading brief + fix file if empty |
| `--model <slug>` | Optional model override (when user passes `model=<slug>`) | Omit when `model=` omitted → platform **Auto**; validated in Step 1.1 when supplied |
| `safe` / `no-force` | Skill mode flag (not an `agent` flag) | User runs interactive `agent --trust --workspace ...`; Claude never invokes `agent` |

Pairing `--trust` + `--force` is required for headless background execution.
Real safety is preflight gates + Claude review + confirmed Base SHA rollback —
**not** interactive Cursor prompts.

## Cursor-specific constraints

In addition to [execute-via-core.md § Shared constraints](../../references/execute-via-core.md):

- Never treat `--trust` alone or `--force` alone as headless-ready; always pair
  both in default headless runs.
- Never document or prefer `--yolo` (use `--force`).
- Always pass an explicit literal absolute `--workspace` path matching the repo
  root where `.claude/tmp/exec-cursor-brief.md` lives.
- Never report PASS if `.claude/tmp/exec-run-cursor-<n>.exit` ≠ `0` or the
  terminal `.ndjson` event is not `type=="result"`, `subtype=="success"`,
  `is_error==false`.
- **Cursor (`agent`) must never** edit the plan file (including YAML
  frontmatter and `## Execution log`) or act as the reviewer.
