# execute-via shared core

Backend-neutral flow shared by `/delegate:execute-via-cursor` (`<backend> = cursor`)
and `/delegate:execute-via-agy` (`<backend> = agy`). In both skills, **the
delegated backend CLI implements** the plan on a branch while **Claude gates,
briefs, reviews**, and may propose commit text. Never commit without a separate
`/commit`.

**References:** [brief-template.md](brief-template.md) ·
[execution-status.md](execution-status.md)
(when linked from `skills/<name>/SKILL.md`, use
`../../references/brief-template.md` and
`../../references/execution-status.md`).

**Repo root:** Step 1 records the absolute path from
`git rev-parse --show-toplevel`. Claude Code Bash **keeps `cwd`** across calls
but **does not keep shell variables** — never rely on `$REPO_ROOT` in a later
Bash call. Paste the **literal absolute path** into every later command (or
re-derive with `"$(git rev-parse --show-toplevel)"` after `cd`). Operate from
that root for all `git` / `mkdir` / `rm` / CLI / tmp work.

## Parameterised contract

Each skill binds `<backend>` (`cursor` or `agy`) and `<last_skill>`
(`execute-via-cursor` or `execute-via-agy`):

| Placeholder | Pattern | Purpose |
| --- | --- | --- |
| `<backend>` | `cursor` \| `agy` | Backend tag used in all `.claude/tmp/` filenames |
| `<last_skill>` | `execute-via-cursor` \| `execute-via-agy` | Value written to `execution.last_skill` and `## Execution log` |
| `<brief>` | `.claude/tmp/exec-<backend>-brief.md` | Implementation brief written by Claude in Step 4 |
| `<fix-n>` | `.claude/tmp/exec-<backend>-fix-<n>.md` | Numbered fix list written by Claude in Step 8 FIX round `<n>` |
| `<questions>` | `.claude/tmp/exec-<backend>-questions.md` | Blocking questions written by the backend if it stops mid-run |
| `<run-n>` | `.claude/tmp/exec-run-<backend>-<n>.{ndjson,err,exit}` | Per-round event stream (`ndjson`), stderr (`err`), and exit status (`exit`) |

## Relationship to `/execute-plan`

| Skill | Who implements | Who reviews |
| --- | --- | --- |
| **`/delegate:execute-via-cursor`** | Cursor `agent` CLI (headless or user terminal) | Claude in this session |
| **`/delegate:execute-via-agy`** | Google Antigravity `agy` CLI (headless or user terminal) | Claude in this session |
| **`/execute-plan`** | In-process Task orchestrator (waves) | Independent review (final pass top-tier) |

Keep `/execute-plan` unchanged. Prefer a `/delegate:execute-via-*` skill when
the user wants an external coding CLI to do the coding work while Claude stays
the gatekeeper and reviewer.

## Arg parse (locked)

Signature: `[plan-file] [step-scope] [safe|no-force] [model=<slug>]`

1. **First positional** = plan path (required). If missing or invalid → list
   `docs/plans/*.md` and ask the user to pick.
2. **Remaining args** (in any order after the plan path):
   - Tokens matching `safe` or `no-force` (case-insensitive) are **mode flags**
     (interactive user-terminal mode; Claude never invokes the backend CLI).
   - Token matching `model=<slug>` (optional) sets the backend model override
     (validated and passed by the skill's preflight / Step 5 when provided).
   - Any other remaining tokens join as **step-scope** (default: all
     Implementation steps / Execution-map rows).
3. Drop `--force` / `--dangerously-skip-permissions` as skill args (not used;
   interactive-friendly flags only).

### Model default (when `model=` is omitted)

For Cursor / agy / Devin **implement** backends: when `model=` is **omitted**, use
backend **Auto** — do **not** pass `--model`, and do **not** pin Sonnet/Opus.
Same mid-tier bar as Execution-map row `auto` (see LIFECYCLE Execution tiers).

Map rows that would use `haiku` on in-process `/execute-plan` may fall back to
**Auto** when a haiku pin is unavailable or usage-capped (LIFECYCLE /
`/execute-plan` haiku→Auto); these delegate skills still default to Auto when
`model=` is omitted (no separate haiku pin path unless the user passes
`model=<slug>`).

## Step 1 — Preflight / gates

Stop and report on any failure. **Never stash for the user.**

1. **Backend CLI & auth preflight (skill hook)** — run the calling skill's
   CLI check (`which agent` for `cursor`; `which agy` + auth/model check for
   `agy`). Missing or unauthenticated → stop with the skill's install/login
   hint.
2. **Repo root** — resolve, record, then `cd` (shell vars do **not** persist
   across Bash tool calls; `cwd` does):

   1. Run and **record the printed absolute path** (keep it in your notes /
      context as the repo root for this invocation):

      ```bash
      git rev-parse --show-toplevel
      ```

      Fail if this errors (not a git work tree).
   2. `cd` using that **literal** path (helps Bash allowlist matching too):

      ```bash
      cd /absolute/path/from/previous/step
      ```

   3. Thereafter: relative `.claude/tmp/...` is fine **only after** this `cd`.
      For any absolute paths or CLI workspace/directory arguments, substitute
      the **same literal path** (or `"$(git rev-parse --show-toplevel)"`
      inline — `cwd` persists). Do **not** use `$REPO_ROOT` in a later Bash
      call expecting the variable to still be set. Keep the backend's working
      directory aligned with where the brief is written.
3. **Plan file** — must exist and be readable under
   `<repo-root>/docs/plans/**` (or the path the user gave that resolves there).
   Missing → stop. If the user passed a relative plan path, resolve it against
   the recorded repo root (or absolute).
4. **Clean working tree** — ignore `.claude/tmp` so leftovers from a prior run
   do not block. From repo root after `cd`:

   ```bash
   git status --short -- . ':!.claude/tmp'
   ```

   Allowed dirty residue: the **plan file only**, and only when its diff is
   YAML frontmatter + `## Execution log` (prior audit writes). Any other
   dirty path, or any other plan-body change → stop; ask user to commit or
   stash.

## Step 2 — Validate plan (fleet vocabulary)

Require readable sections (or clear equivalents):

- Purpose (or Goal)
- Ordered Implementation steps
- Files to modify/create (or a clear file list inside steps)
- Success criteria
- Verification (include test/lint commands when present)

Execution map is optional (nice-to-have; `/execute-plan`'s specialty).

Missing → list gaps and **stop**. Do not let the delegated backend guess.

Hard stop (not a clarifying question) if the plan has an explicit unresolved
**"Blocked on"** note (or clear equivalent). List the blocker and **stop** —
do not write the brief or invoke the backend CLI. Next step: resolve the
blocker, or `/make-plan update <path>`, then re-invoke
`/delegate:execute-via-<backend>`. Ambiguous *content* inside an existing
section → ask a clarifying question before launch; missing section /
unresolved blocker → hard stop.

Only after validation passes:

1. **Branch divert** — if current branch is `main` / `master` / `develop` /
   `trunk`:
   - Slug: `impl/<short-slug-from-plan-title>` (lowercase, hyphens, ≤40 chars).
   - Branch **does not exist** → `git switch -c <branch>`.
   - Branch **exists** → `git switch <branch>` (reuse). If switch fails
     (conflicts / unrelated local state) → **stop and ask**. Never invent a
     new slug; never force-checkout.
2. **Base SHA** — after any required branch switch:
   `git rev-parse HEAD`. Record as the rollback point.

## Status audit (Claude dual-write)

`Read` [execution-status.md](execution-status.md) (or
`../../references/execution-status.md` from `skills/<name>/SKILL.md`) for
schema, `%` formula, placement, and dual-write rule — do **not** paste the full
contract into skill bodies. **Claude** (never the delegated backend CLI)
dual-writes YAML frontmatter + `## Execution log` in **one edit** at each
locked timing below, setting `last_skill: <last_skill>` (`execute-via-cursor`
or `execute-via-agy`).

**Row set:** Execution-map rows when present; otherwise Implementation-step
fallback IDs (`I1`…`In` or the plan's existing step numbers) per the SoT.
Rows outside the current `step-scope` → `skipped` with Notes
`out of step-scope` (never leave them `pending`), **except** preserve prior
`done` — never downgrade a prior `done` row to `skipped`.

1. **Start** — after Steps 1–2 pass (and Step 3 when on the default path),
   before or as Step 4 writes the brief: ensure frontmatter + log exist;
   `status: in-progress`; `started_at` if unset; scoped rows `pending`
   (leave prior `done` on resume); for out-of-scope rows, set `skipped` /
   `out of step-scope` **only if** the row was not already `done`. Confirm
   with the user before resetting an already-`completed` plan.
2. **After a successful scoped batch** (when `step-scope` ≠ all) — once the
   backend's implement for that scope has been reviewed clean (before a
   further FIX round if none): update in-scope row statuses + frontmatter
   `%` / `updated_at`. Skip this mid-run write when scope is all (terminal
   write covers it).
3. **Terminal** — on Step 8 verdict (**PASS**, **FAIL** after FIX budget,
   or user **abort**): set overall `status` (`completed` / `partial` /
   `failed` / `aborted`), `completed_at` iff `completed`, final `%`, one
   `### Run …` stanza. **Scoped terminal PASS:** overall is `partial`
   unless every row is actually `done` — rows that are only `skipped`
   solely because `out of step-scope` do **not** count toward `completed`.

Claude may edit the plan file **only** for frontmatter + `## Execution log`
(create/move the section per SoT placement). Do **not** edit Implementation
steps, Execution map content, or other plan sections as part of this skill.

## Step 3 — Background runtime gates (default path only)

Resolve any clarifying questions about ambiguous plan content **before**
launching the headless run (the backend runs non-interactively with no mid-run
prompts; if it hits a mid-run ambiguity it must stop and write `<questions>`).

Run **before** writing the brief when **not** `safe` / `no-force` (so a failed
gate never leaves a stray brief). Skip entirely for `safe` / `no-force`.

1. If `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` (or bare/disabled background
   mode) → **stop**: background runs unavailable. Suggest `safe` / `no-force`
   or re-enable background tasks.
2. Tell the user: **keep Claude Code open** until the run finishes —
   background tasks stop on exit.
3. Designed for **interactive local sessions only**. Unattended `claude -p` /
   cloud are best-effort; background commands may be time-limited. No hard
   detection signal — document in the session notice; do not invent a confirm
   branch.

## Step 4 — Clear stale tmp (per-backend) + write brief

Clear **only** `<backend>`'s artifacts so any files belonging to the other
backend remain intact:

```bash
mkdir -p .claude/tmp
# Drop stale skill artifacts for <backend> ONLY (do not touch the other backend's files)
rm -f .claude/tmp/exec-<backend>-brief.md \
      .claude/tmp/exec-<backend>-fix-*.md \
      .claude/tmp/exec-<backend>-questions.md \
      .claude/tmp/exec-run-<backend>-*
```

Then write `.claude/tmp/exec-<backend>-brief.md` from
[brief-template.md](brief-template.md) (or
`../../references/brief-template.md` from `skills/<name>/SKILL.md`),
replacing `{{BACKEND}}` (`cursor` or `agy`), `{{PLAN_PATH}}`, `{{REPO_ROOT}}`,
`{{STEP_SCOPE}}`, and `{{QUESTIONS_PATH}}`
(`.claude/tmp/exec-<backend>-questions.md`). Prefer `.claude/tmp/` even if not
gitignored; warn not to commit briefs/questions (check `.gitignore` if unsure).
For `safe` / `no-force`, still write the brief here before handing the user the
interactive command.

## Step 5 & Step 6 — Backend execution & log parsing (skill hooks)

Each skill defines its own Step 5 (CLI invocation) and Step 6 (log parsing)
meeting these interface requirements before entering Step 7:

### Step 5 interface (Run `<backend>`)

- Pick a new run id `<n>` per implement/FIX round (`1`, `2`, …).
- **Default (headless background):** invoke the backend CLI via Bash with
  `run_in_background: true` (do **not** poll with `sleep`), redirecting stdout
  to `.claude/tmp/exec-run-<backend>-<n>.ndjson`, stderr to
  `.claude/tmp/exec-run-<backend>-<n>.err`, and exit code to
  `.claude/tmp/exec-run-<backend>-<n>.exit`. Wait for Claude Code's
  **background-task completion notification**.
- **`safe` / `no-force` (interactive user terminal):** Claude **never** invokes
  the backend CLI. Print the exact interactive command for the user's terminal
  pointing at `.claude/tmp/exec-<backend>-brief.md`. Wait for the user to say
  done. Step 3 was skipped; **skip Step 6** (no run logs) and proceed directly
  to Step 7 review.

### Step 6 interface (Parse run logs — default path only)

- **Claude-invoked runs only** (`safe` / `no-force` skips Step 6 — do not treat
  missing logs in `safe` / `no-force` mode as a failed run).
- Summarize via `jq` / `head` / `tail` / `grep`; do **not** read large
  `.ndjson` files whole into context.
- Extract and record the **resume handle** (`session_id` for `cursor`;
  `conversation_id` for `agy`) from the stream's init event so Step 8 FIX
  rounds can resume the conversation even if the run failed.
- Check run-level completion: verify `.claude/tmp/exec-run-<backend>-<n>.exit`
  is `0`, the terminal `.ndjson` `result` event meets the backend's success
  predicate, and `.claude/tmp/exec-run-<backend>-<n>.err` has no fatal error
  or permission soft-deny.
- Anything else → **failed run**: surface `.err`; if a resume handle was
  captured, Step 8 FIX may still resume it. Ignore unknown JSON fields (schema
  drift). `git diff` + untracked files (Step 7) remain the source of truth for
  what changed on disk.

## Step 7 — Claude review (independent of the backend's report)

1. `git status --short -- . ':!.claude/tmp'` plus `git diff --stat <BaseSHA>`
   and `git diff <BaseSHA>` (tracked changes against `<BaseSHA>`).
2. **Untracked** backend output (exclude skill tmp):
   `git ls-files --others --exclude-standard -- . ':!.claude/tmp'` — read and
   review those files too.
3. Read `.claude/tmp/exec-<backend>-questions.md` if present. If the backend
   stopped on blocking questions, surface them to the user before deciding the
   verdict.
4. Per Success criterion and scoped Implementation step: met / not met /
   unverifiable + `file:line` evidence.
5. Flag: out-of-scope files, deleted/weakened tests, TODOs, secrets, new deps,
   or edits to protected repo config (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`,
   `.cursor/rules`, `.agents/` rules, CI workflows).
   **Plan-file exception:** the plan path may appear in the diff from Claude's
   status dual-writes. Expected delta is **only** YAML frontmatter +
   `## Execution log`. Any other plan-body change → treat as a backend
   violation / out-of-scope (the backend must never edit the plan). Do **not**
   flag audit-only plan diffs as out-of-scope.
6. **Re-run** plan Verification commands yourself — do not trust the backend's
   self-report alone.

## Step 8 — Verdict loop

Dual-write status per **Status audit** on terminal outcomes below (and after
a successful scoped batch when `step-scope` ≠ all — see Status audit §2).

- **PASS** → dual-write terminal status (scoped PASS → `partial` unless every
  row is actually `done` — see Status audit §3); summarize; propose
  Conventional Commit message; **do not commit** (offer `/commit`).
- **FIX** (max **2** rounds) → write numbered fixes to
  `.claude/tmp/exec-<backend>-fix-<n>.md` (new `<n>` per FIX round; do
  **not** clear `.claude/tmp/exec-<backend>-brief.md`). Then invoke the
  backend using the skill's FIX command shape:
  - **Default (with resume handle from prior run):** invoke the backend CLI in
    background resuming that session (`--resume <session_id>` for `cursor`;
    `--conversation <conversation_id>` for `agy`) with prompt
    `"Read .claude/tmp/exec-<backend>-fix-<n>.md and apply the fixes exactly."`,
    writing to `.claude/tmp/exec-run-<backend>-<n>.{ndjson,err,exit}`.
  - **If resume handle is empty/missing:** fresh background run (no resume
    flag); instruct the backend to read **both**
    `.claude/tmp/exec-<backend>-brief.md` and
    `.claude/tmp/exec-<backend>-fix-<n>.md` and apply the fixes.
  - Then re-parse (Step 6) and re-review (Step 7).
  - **`safe` / `no-force`:** print the numbered fixes (and the
    `.claude/tmp/exec-<backend>-fix-<n>.md` path) for the user to paste into /
    point at their interactive session; wait for done; re-review (Step 7). Do
    not invoke the backend CLI.
- **FAIL** (or still failing after 2 FIX rounds) → dual-write terminal
  `failed`; report; show rollback:

  ```bash
  git reset --hard <BaseSHA> && git clean -fd
  ```

  Run **only after user confirms**. Warn that `git clean -fd` wipes untracked
  files **and the plan's audit write**. **After** the confirmed rollback
  completes, **re-apply** the terminal `failed` dual-write (frontmatter +
  `## Execution log`) so the audit trail survives rollback. On user
  **abort** before a terminal PASS/FAIL → dual-write `aborted` (or leave
  prior state if this run never started status writes).

## Shared constraints

- Claude Code–only plugin (`delegate`). Not exposed to Cursor, Devin, or
  Windsurf skill directories.
- Refuse (Step 2) on unresolved `"Blocked on"` (or clear equivalent) — do not
  write the brief or invoke the backend CLI.
- Never auto-commit, auto-push, or open a PR.
- Never run `git reset --hard` / `git clean -fd` without explicit user confirm.
- Never stash for the user; never invent a new `impl/*` slug on switch failure.
- Never rely on `$REPO_ROOT` across Bash tool calls; paste the recorded
  absolute path (or re-derive with `git rev-parse --show-toplevel`).
- Never clear the other backend's `.claude/tmp/exec-*` files in Step 4.
- Never touch or write files outside the recorded repo root.
- Never report PASS if `.exit` ≠ `0`, `.err` contains a fatal/permission error,
  or the terminal stream event is not a clean success result.
- Claude never edits target implementation files during the loop; Claude may
  edit the plan file **only** for YAML frontmatter + `## Execution log`
  (Status audit / [execution-status.md](execution-status.md)). Do **not** edit
  Implementation steps, other plan sections, `CLAUDE.md`, `AGENTS.md`,
  `GEMINI.md`, `.cursor/rules`, `.agents/` rules, or CI workflows. **The
  delegated backend must never** edit the plan (brief forbids it, including
  frontmatter and Execution log) or protected repo config.
- Keep `/execute-plan` unchanged; do not use the delegated backend as the
  reviewer.
