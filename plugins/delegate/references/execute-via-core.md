# execute-via shared core

Backend-neutral flow for `/delegate:execute-via-cursor` (`<backend> = cursor`),
`/delegate:execute-via-agy` (`agy`), `/delegate:execute-via-devin` (`devin`). Backend CLI implements
the plan on a branch; **Claude gates, briefs, reviews**; may propose commit text. Never commit
without `/commit`. Launch argv, run classification, plan-status writes come from plugin scripts; CLI
install/auth/model-list checks stay in the calling `SKILL.md`.

**References:** [brief-template.md](brief-template.md) ·
[execution-status.md](execution-status.md) · [review-brief-template.md](review-brief-template.md) ·
[model-tiers.md](model-tiers.md). From `skills/<name>/SKILL.md` use `../../references/` prefix.

**Scripts** (from `skills/<name>/SKILL.md`): `plan-status.sh` (`lock`,`rows`,`start`,`batch`,
`terminal`) · `delegate-launch.sh` (headless run or `--interactive` text) ·
`delegate-review-launch.sh` (`snapshot`/`check`/`scope`/`run`/`verdict`) · `delegate-verdict.sh`
(classify one run's logs) · `delegate-verify.sh` (run Verification commands → PASS/FAIL) ·
`delegate-usage.sh` (token totals for `terminal --usage`).

`<skill-dir>` = calling `SKILL.md` dir. Run every script as
`bash <skill-dir>/../../scripts/<name>.sh` with the **literal absolute** `<skill-dir>`.

## Parameterised contract

Each skill binds `<backend>` (`cursor`/`agy`/`devin`) and `<last_skill>`
(`execute-via-cursor`/`execute-via-agy`/`execute-via-devin`):

| Placeholder | Pattern |
| --- | --- |
| `<backend>` | `cursor` \| `agy` \| `devin` — `.claude/tmp/` filename tag |
| `<last_skill>` | `execute-via-cursor` \| `execute-via-agy` \| `execute-via-devin` — `execution.last_skill` + `## Execution log` |
| `<brief>` | `.claude/tmp/exec-<backend>-brief.md` |
| `<rows-json>` | `.claude/tmp/exec-<backend>-rows.json` — `rows` stdout; `start`/`terminal` path |
| `<fix-n>` | `.claude/tmp/exec-<backend>-fix-<n>.md` — FIX round `<n>` list |
| `<questions>` | `.claude/tmp/exec-<backend>-questions.md` |
| `<run-n>` | `.claude/tmp/exec-run-<backend>-<n>.{ndjson,err,exit}` — Devin `{json,out,err,exit}` |

## Relationship to `/execute-plan`

`/delegate:execute-via-*`: backend CLI (Cursor `agent`, Antigravity `agy`, Devin CLI — headless or
user terminal) implements on a branch; batch Review runner (Step 7) reviews. `/execute-plan`:
in-process Task orchestrator; independent review (final pass top-tier). Keep `/execute-plan`
unchanged. Prefer delegate skill for an external coding CLI while Claude gates/reviews. Do not
implement a `delegate:*` row from `/execute-plan`, or `subagent`/`session` row from a delegate skill
— `plan-status.sh rows` selects only this backend's rows.

## Arg parse (locked)

Signature: `[plan-file] [step-scope] [safe|no-force] [model=<slug>]`

1. First positional = plan path (required). Missing/invalid → list `docs/plans/*.md`, ask.
2. Remaining (any order): `safe`/`no-force` (case-insensitive) = mode flags — interactive
   user-terminal mode; Claude never invokes the CLI; `model=<slug>` (optional) = backend model
   override (preflight-validated; **Model default**); other tokens = **step-scope** row IDs (none →
   `rows` selects every `<backend>` row). Pass IDs to every `plan-status.sh rows` call. Never `all`.
3. Drop `--force` / `--dangerously-skip-permissions` as skill args (unused; interactive-friendly
   flags only).

### Model default (when `model=` is omitted)

Resolve slug from `<rows-json>` **after Step 4 writes it**, **before** Step 5 — every run
(`--reexecute` or not): pre-switch Step 2 `launch_tier`/pin does not stick if the branch plan body
differs. Always pass as `--model` via `delegate-launch.sh`.

1. `model=<slug>` → overrides pin; `model_requested` = that slug; `model=auto` = logged fallback
   (`fallback: model=auto`); preflight checks it against CLI model list.
2. `router: true` (no `model=`) → `--model auto`.
3. Else → `launch_tier` (`low`/`execute`/`mid`) backend pin from
   [model-tiers.md](model-tiers.md): first unexpired CLI-listed slug in chain; skip `until:`-expired
   (`fallback: expired <slug>`) and rows of a disabled tool (registry `enabled: false`). Pass `--model <slug>`.
4. No slug → if chain names `auto` fallback, `--model auto` (`fallback: pin missing`); else **stop
   and ask** for `model=<slug>` — never pick Auto without it. A listed pin failing usage/quota is
   Step 6.

Terminal model fields — the **only** statement; Status audit §3 and Step 6 refer here. `verdict` =
`model_resolved` of the `delegate-verdict.sh` stdout after Step 6 (relaunch → new `<n>`'s verdict).
`effort` = slug suffix (`grok-4.7-high` → `high`), `default` when none (`composer-2.5`); `suffix /
default` below means exactly that.

| Case | model_requested | model_resolved | effort | fallback |
| --- | --- | --- | --- | --- |
| Pin run | slug | verdict | suffix / `default` | `null` |
| `model=<slug>` | that slug | verdict | suffix / `default` | `null` |
| `model=auto` | `auto` | verdict | `default` | `model=auto` |
| Router (`router: true`) | `auto` | `auto(router)` | `unknown` | `null` |
| Pin missing → `--model auto` | `auto` | verdict | `default` | `pin missing` |
| Expired slug skipped | slug passed | verdict | suffix / `default` | `expired <slug>` |
| Quota relaunch (ok or not) | `auto` | relaunch verdict | `default` | `quota` |
| Devin model mismatch | run's slug | verdict | run's effort | `model mismatch <requested>→<resolved>` — strip `fallback: `; never `null`; FAIL |
| Cursor/agy display label | run's slug | verdict | run's effort | `null` unless a launch trigger applies |
| No verdict JSON (safe/no-force, or FAIL/abort before Step 6) | resolved slug | `auto(unresolved)` or user-reported slug (router `auto(router)`) | suffix / `default` (`unknown` router) | per triggers |

`fallback` non-`null` only on launch trigger: `expired <slug>`, `pin missing`, `quota`, `model=auto`,
`auto(unresolved)`, or resolved == `auto` (case-insensitive). Cursor/agy report display labels, not
slug — not a mismatch; resolved-vs-requested is Devin-only (exact slugs).

## Step 1 — Preflight / gates

Stop and report on any failure. **Never stash for the user.**

0. **Host gate (Claude Code only)** — before anything else:

   ```bash
   [ "${CLAUDECODE:-}" = "1" ]
   ```

   Not running inside Claude Code → **stop**: `delegate:*` skills are Claude Code
   only (Cursor and other tools can list them via Claude Code plugin import, but
   they must never execute there — no `claude` background sessions, no `Task`
   review runners, and headless backend runs would escape the gates). Do not run
   any script, `cd`, or status write.
1. **Backend CLI & auth preflight (skill hook)** — calling skill's check (`which agent` / `which agy`
   + auth/model / `which devin` + `devin auth status`). Missing/unauthenticated → stop with install/
   login hint. Model listing here; slug choice waits for **Model default**.
2. **Repo root** — `git rev-parse --show-toplevel`; record and `cd` to the printed **literal**
   absolute path (fail if it errors — not a git work tree):

   ```bash
   git rev-parse --show-toplevel
   cd /absolute/path/from/previous/step
   ```

   Relative `.claude/tmp/...` then works; for absolute/CLI args use the literal path or
   `"$(git rev-parse --show-toplevel)"` inline (`cwd` persists). Never `$REPO_ROOT`. Keep backend
   cwd aligned with the brief.
3. **Plan file** — must exist and be readable under `<repo-root>/docs/plans/**` (or given path
   resolving there). Missing → stop; resolve relative paths against recorded root.
4. **Clean working tree** — ignore `.claude/tmp`:

   ```bash
   git status --short -- . ':!.claude/tmp'
   ```

   Allowed dirty residue: **plan file only**, and only when its diff is YAML frontmatter +
   `## Execution log`. Any other dirty path or plan-body change → stop; ask user to commit/stash.
5. **Plan lock** — after the plan file is known to exist:

   ```bash
   bash <skill-dir>/../../scripts/plan-status.sh lock <plan>
   ```

   Exit 0 `ok`/`legacy` (stderr `WARN: legacy plan (no plan_sha)`) → continue. Exit 3 → stop
   (stderr `plan body changed since approval; re-approve with /make-plan update <plan>`); no brief
   or launch. Exit 2 → stop, show stderr.

## Step 2 — Validate plan and select rows

Require readable sections (or clear equivalents): Purpose (or Goal); Ordered Implementation steps;
Files to modify/create (or a clear file list inside steps, or Files cells on a v2 Execution map);
Success criteria; Verification (include test/lint commands when present). A missing Execution map
is valid — `rows` uses the Implementation-step fallback (`map: none`). Do not re-select rows in
prose. Missing → list gaps and **stop**.

Hard stop (not a clarifying question) on explicit unresolved **"Blocked on"** note (or clear
equivalent): list blocker and **stop** — no brief, no CLI. Next: resolve or
`/make-plan update <path>`, re-invoke `/delegate:execute-via-<backend>`. Ambiguous *content* in an
existing section → clarifying question first; missing section / unresolved blocker → hard stop.

**Row selection** — after both checks, before branch divert:

```bash
bash <skill-dir>/../../scripts/plan-status.sh rows <plan> <backend> [ID...]
```

`--reexecute` only after user confirmed re-execute (Status audit Start, exit 4). Stdout = one JSON
object (`map`, `launch_tier`, `router`, `selected`, `skipped`, `files_union`; each `selected` has
`id`, `tier`, `wave`, `depends`, `files`, `acceptance`, `model`, `review`). Keep it; Step 4 writes
the same invocation to `<rows-json>`. `selected` is the only row set the brief may contain.

Exit 3 → stop. Print `REFUSE:` stderr lines verbatim, then the matching `## Dispatch` hint:
`REFUSE: <ID>: …` → each Dispatch line naming that ID; `REFUSE: no rows routed to
delegate:<backend>` → each line naming a different runner. `## Dispatch` missing/names nothing →
say so. Do not divert, write `<rows-json>`, brief, or launch. Exit 2 → stop, show stderr.

Only after both pass:

1. **Branch divert** — on `main`/`master`/`develop`/`trunk`: slug `impl/<short-slug>` (lowercase,
   hyphens, ≤40 chars). Branch absent → `git switch -c <branch>`; present → `git switch <branch>`
   (reuse; failure → **stop and ask** — never invent slug or force-checkout). After a successful
   switch onto an existing branch, re-run `plan-status.sh lock <plan>` (Step 1 exit rules) — branch
   plan body can differ; `git switch -c` keeps the Step 1 lock.
2. **Base SHA** — `git rev-parse HEAD` after any required switch; rollback point.

## Status audit (via `plan-status.sh`)

`Read` [execution-status.md](execution-status.md) (or `../../references/execution-status.md`) for
schema, row statuses, dual-write rule — do **not** paste the contract into skill bodies.
**Claude** (never the backend CLI) runs `plan-status.sh`; it dual-writes YAML frontmatter +
`## Execution log`, sets `last_skill: <last_skill>`. Do not hand-edit the plan.

`<rows-json>` is `.claude/tmp/exec-<backend>-rows.json`; `start`/`terminal` take that path. Record
one UTC stamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) as `--now` on the writing `start`; pass it as `--started`
on `terminal`.

1. **Start** — immediately after Step 4 writes `<rows-json>`, **before** the brief:

   ```bash
   bash <skill-dir>/../../scripts/plan-status.sh start <plan> <last_skill> .claude/tmp/exec-<backend>-rows.json --now <TS>
   ```

   Exit 4 (stderr `plan already completed; confirm re-execute`) → ask user. On confirm, rewrite file
   and start again (new `<TS>`):

   ```bash
   bash <skill-dir>/../../scripts/plan-status.sh rows --reexecute <plan> <backend> [ID...] \
     > .claude/tmp/exec-<backend>-rows.json
   bash <skill-dir>/../../scripts/plan-status.sh start <plan> <last_skill> .claude/tmp/exec-<backend>-rows.json --now <TS> --reexecute
   ```

   Brief uses the rewritten `selected` array. Decline → stop; no brief. Exit 2 → stop, show stderr.

2. **After a successful scoped batch** (step-scope IDs passed) — once Step 7 for that scope is
   clean, before a further FIX round if none:

   ```bash
   bash <skill-dir>/../../scripts/plan-status.sh batch <plan> <last_skill> --done ID... [--failed ID...]
   ```

   IDs = selected rows that passed or failed review. Skip when no step-scope IDs passed (terminal
   covers it).

3. **Terminal** — on Step 8 verdict (**PASS**, **FAIL** after FIX budget, or user **abort**):

   ```bash
   bash <skill-dir>/../../scripts/plan-status.sh terminal <plan> <last_skill> .claude/tmp/exec-<backend>-rows.json \
     --outcome pass|fail|abort --backend <backend> --model-requested <slug> --model-resolved "<resolved>" \
     --effort <effort> --started <TS> --findings <N> --fix-loops <N> --fallback "<reason-or-null>" \
     [--usage <json>] [--done ID...] [--notes "<TEXT>"]
   ```

   - `--outcome` per verdict; overall `completed`/`partial` per execution-status.md (do not claim
     `completed` yourself).
   - Model flags: shell-quote the CLI arg (script YAML-quotes it); values per **Model default**.
   - `--findings`/`--fix-loops` = `review_findings`/`fix_loops` per execution-status.md; `--notes` =
     one short paragraph.
   - Token usage: before `terminal`, sum this run's launches —

     ```bash
     bash <skill-dir>/../../scripts/delegate-usage.sh <backend> /absolute/repo/root <n> [<n>...]
     ```

     over every implement and FIX `<n>` of this run — and pass its stdout JSON as
     `--usage '<json>'`. `safe`/`no-force` has no run files (all `null`); omit `--usage`.
   - Write on FAIL and abort too. `safe`/`no-force` run has no verdict JSON (fields per **Model
     default**).

Claude must not edit Implementation steps, Execution map content, or other plan sections. Status
changes go through `start`, `batch`, `terminal` only.

## Step 3 — Background runtime gates (default path only)

Resolve clarifying questions about ambiguous plan content **before** launching the headless run
(backend runs non-interactively; on mid-run ambiguity it must stop and write `<questions>`). Run
**before** writing the brief when **not** `safe`/`no-force` (a failed gate leaves no stray brief).
Skip entirely for `safe`/`no-force`.

1. `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` (or bare/disabled background mode) → **stop**:
   background runs unavailable; suggest `safe`/`no-force` or re-enable background tasks.
2. Tell the user: **keep Claude Code open** until the run finishes — background tasks stop on exit.
3. Interactive local sessions only. Unattended `claude -p`/cloud are best-effort; background
   commands may be time-limited. No hard detection — document in the session notice; do not invent
   a confirm branch.

## Step 4 — Clear stale tmp, write rows, start, write brief

Clear **only** `<backend>`'s artifacts so the other backend's files remain intact:

```bash
mkdir -p .claude/tmp
rm -f .claude/tmp/exec-<backend>-brief.md \
      .claude/tmp/exec-<backend>-fix-*.md \
      .claude/tmp/exec-<backend>-questions.md \
      .claude/tmp/exec-<backend>-rows.json \
      .claude/tmp/exec-<backend>-verify.txt \
      .claude/tmp/exec-<backend>-verify.out \
      .claude/tmp/exec-review-<backend>-* \
      .claude/tmp/exec-run-<backend>-*
```

Write `<rows-json>` with the same `rows` arguments as Step 2 (`--reexecute` only when already
confirmed):

```bash
bash <skill-dir>/../../scripts/plan-status.sh rows <plan> <backend> [ID...] \
  > .claude/tmp/exec-<backend>-rows.json
```

Exit 3 or 2 → delete the rows file the redirect created, print `REFUSE:` lines + `## Dispatch` hint
(Step 2), stop. Do not `start`. The file just written is the row set for the brief and **Model
default** — re-resolve the slug from it even when not a `--reexecute` rewrite.

Then run **Status audit Start** before the brief. Exit 4 → ask, then the `--reexecute` pair. The
brief uses the `selected` array in the rows file `start` accepted.

Write `.claude/tmp/exec-<backend>-brief.md` from [brief-template.md](brief-template.md) (or
`../../references/brief-template.md`): copy `<!-- static:start -->`…`<!-- static:end -->` unchanged;
fill placeholders per the template — `{{STEP_SCOPE}}` = ID list or `all rows routed to <backend>`
(no IDs), `{{QUESTIONS_PATH}}` = `.claude/tmp/exec-<backend>-questions.md`. **Rows** = `selected[]`
only (omit `skipped`); join `files`/`depends` with `, ` (`—` when empty). Under the table paste each
selected row's Implementation-step text verbatim; step choice by `map` in `<rows-json>`:

- `map: none` — id `In` = nth top-level numbered step in order (`I1` = first `1.` line); synthetic,
  not in text — do not search for `I3`. No nth step → stop and ask.
- Map ids (`v2`/`legacy`) — the step whose own `N.` opening heading is that id (e.g. `(S8)`); an id
  only inside a body or another step does not count (`S1..S4` cited ≠ the `S1` step). No
  opening-line match or two → stop and ask.

Omit the Fix-file section (implement brief). Prefer `.claude/tmp/` even if not gitignored; warn not
to commit briefs/questions/rows file (check `.gitignore`). For `safe`/`no-force`, still write rows +
`start` + brief before handing the user the interactive command.

## Step 5 & Step 6 — Launch and verdict

Do not hand-build `agent`/`agy`/`devin` argv. `delegate-launch.sh` is the only launch path;
`delegate-verdict.sh` the only log parse.

### Step 5 — Run `<backend>`

New run id `<n>` per implement/FIX round (`1`,`2`,…). `<model>` = slug from **Model default**.

- **Default (headless background):** Bash `run_in_background: true` (no `sleep` polling); wait for
  the **background-task completion notification**:

  ```bash
  bash <skill-dir>/../../scripts/delegate-launch.sh <backend> /absolute/repo/root <n> <model> brief
  ```

  Script exit 0 after recording backend status in `.exit` (even on backend failure); exit 2 =
  usage error → stop, show stderr.
- **`safe`/`no-force`:** Claude **never** invokes the backend CLI. Print the command, wait for the
  user to say done:

  ```bash
  bash <skill-dir>/../../scripts/delegate-launch.sh --interactive <backend> /absolute/repo/root <n> <model> brief
  ```

  Step 3 was skipped. **Skip Step 6** (no run logs); proceed to Step 7.

### Step 6 — Verdict (default path only)

`safe`/`no-force` skips this. Missing logs there are not a failed run. Do not read large `.ndjson`
or Devin export files whole.

```bash
bash <skill-dir>/../../scripts/delegate-verdict.sh <backend> /absolute/repo/root <n> <requested-slug>
```

`<requested-slug>` required for `devin`, passed for every backend. Exit 2 → stop, show stderr.

- `ok: true` — record `session_id` for Step 8; terminal model fields per **Model default**.
- `ok: false` — failed run. Surface `reasons` and `.err`. Non-empty `session_id` may still resume.
  `questions: true` → read `<questions>` in Step 7 before the verdict. A `reasons` entry
  `fallback: model mismatch <requested>→<resolved>` is a Devin FAIL — `--fallback` per **Model
  default**.
- **Usage/quota, one relaunch.** Pin was listed and this launch ran, then failed with usage/quota
  (CLI text in `.err`/`reasons`). If the `launch_tier` chain lists `auto` as a logged fallback,
  relaunch **once** (new `<n>`, same kind, `--model auto`), then:
  1. Wait for that `<n>` (background-task completion).
  2. `delegate-verdict.sh` on the new `<n>` — its stdout **is** the Step 6 result (`ok`,
     `session_id`, `model_resolved`, `reasons`); the pin run's `ok: false` does not stick.
  3. Terminal fields per **Model default** (quota relaunch row — `--fallback quota`, never the
     router record).
  4. New verdict `ok: true` → may PASS; not `ok` → no second relaunch; the FAIL `terminal` still
     records `--fallback quota`.
  Chain lacks `auto` → stop; never pick Auto; never relaunch an `auto` attempt.
- `git diff` + untracked files (Step 7) remain the source of truth for what changed on disk.

## Step 7 — Claude review (independent of the backend's report)

1. Before verifying, re-check `plan-status.sh lock <plan>` (must match Step 1) and use Step 4
   `selected`/`files_union` (backend-modified plan body or `<rows-json>` → flag as backend
   violation, skip verification). Write `.claude/tmp/exec-<backend>-verify.txt`, one command per
   line: each selected row's `acceptance` (a pipeline stays one line) then each copy-pastable plan
   Verification command. Skip empty acceptance and non-command prose.
2. Run the verify script from the repo root:

   ```bash
   bash <skill-dir>/../../scripts/delegate-verify.sh /absolute/repo/root \
     .claude/tmp/exec-<backend>-verify.txt > .claude/tmp/exec-<backend>-verify.out
   ```

   Exit 0 → verifier PASS; exit 1 → verifier FAIL; exit 3 → a Verification command modified the
   tree — stop and ask (never treat it as PASS); exit 2 → stop and show stderr. The script owns
   the tree snapshots; do not re-run commands yourself.
3. The "verifier summary" everywhere below is the contents of
   `.claude/tmp/exec-<backend>-verify.out`, pasted unchanged into review briefs.
4. **Scope check** — mechanical path check:

   ```bash
   bash <skill-dir>/../../scripts/delegate-review-launch.sh scope /absolute/repo/root <BaseSHA> .claude/tmp/exec-<backend>-rows.json <plan>
   ```

   → `{outside,protected,untracked}`. Non-empty `outside`/`protected` = **host finding**
   (`important` default; `blocking` for protected repo config) added to reviewer findings. Read
   `.claude/tmp/exec-<backend>-questions.md` if present or Step 6 said `questions: true`; surface
   before the verdict. **Plan-file exception:** plan may appear in the `plan-status.sh` diff —
   expected delta is **only** YAML frontmatter + `## Execution log`; any other plan-body change =
   backend violation; do not flag audit-only plan diffs as outside `files_union`. Deleted/weakened
   tests, TODOs, secrets, new deps, protected-config edits are reviewer criteria → review findings,
   not host prose.
5. **Review runner** — strongest `review` across `selected` in `<rows-json>` (`none` < `mid` <
   `top@*`; one batch shares one `top@*`). `<rid>` = `<backend>-<k>` (`k` = 1 first review, +1 per
   later). Fill `.claude/tmp/exec-review-<rid>-brief.md` from
   [review-brief-template.md](review-brief-template.md) (or `../../references/review-brief-template.md`):
   static block unchanged; `{{RID}}`=`<rid>`, `{{RUNNER}}`=the review value (`mid`/`top@*`),
   `{{SCOPE}}`=selected IDs; other placeholders per the template. Dispatch:
   - `none` — no review, no `verdict`. Clean only when verifier `PASS` and scope `outside`+
     `protected` empty; else FIX with those as findings.
   - `mid` — read-only `Task(model: "sonnet")` on the brief (claude-code `mid`); **Review family**
     per model-tiers.md.
   - `top@session` — this session reviews the brief itself.
   - `top@claude-task` — read-only `Task(model: "opus")` on the brief.
   - The implementing CLI session never reviews; a runner is a fresh read-only session or Task.
   - For `mid`/`top@session`/`top@claude-task`: snapshot first:

     ```bash
     bash <skill-dir>/../../scripts/delegate-review-launch.sh snapshot /absolute/repo/root <rid>
     ```

     Write review text (ends with `FINDINGS:`/`VERDICT:` trailer) to
     `.claude/tmp/exec-review-<rid>.md`, then check:

     ```bash
     bash <skill-dir>/../../scripts/delegate-review-launch.sh check /absolute/repo/root <rid>
     ```
   - Any other `top@*` (an external runner listed by `tiers.sh runners`, e.g.
     `top@claude-headless`, `top@devin-fusion`) → read
     [review-runner.md](review-runner.md) (from `skills/<name>/SKILL.md`:
     `../../references/review-runner.md`).
   - Every non-`none` review ends with `verdict`:

     ```bash
     bash <skill-dir>/../../scripts/delegate-review-launch.sh verdict /absolute/repo/root <rid>
     ```

     → `{ok,verdict,blocking,important,nit,timed_out,guard_clean,reasons}`. Exit 2 → stop, show
     stderr. Do not re-parse review prose for the verdict; read findings text only for fix items.

## Step 8 — Verdict loop

Step 7's result maps to the outcomes below (a `none` review has no verdict JSON; its Step 7
clean/FIX stands in):

- `ok: false` (`exit N`, `timeout ceiling`, `guard tripped`, `no verdict line`, `inconsistent
  verdict`) → **reviewer failure**: stop and ask — retry same runner (new `<rid>`),
  `top@claude-task`, or abort (`terminal --outcome abort`). Never downgrade silently. A tripped
  guard already reverted the reviewer's edits (`.guard.json` `reverted`/`removed`); `head_moved`
  true → show the stderr hint, do not touch refs.
- `verdict: PASS` → PASS **only if** verifier `PASS` and scope `outside`+`protected` empty; else
  FIX with failing verifier commands + scope paths as numbered fixes. `verdict: FIX` → FIX: copy
  blocking/important findings verbatim into fixes (2-round budget); after the FIX run repeat Steps
  6–7, re-review at the **same runner**. `verdict: FAIL` → FAIL.
- `--findings` = `blocking`+`important` sum across all reviews; `--notes` gains
  `review=<runner> clean` (last review PASS) or `review=<runner> dirty`. Report `final top-tier
  review converged: clean` only when the last review ran at `top@*` and PASSed.

Run **Status audit** `batch` (step-scope IDs passed) and `terminal` on the outcomes below.

- **PASS** → `terminal --outcome pass`; summarize; propose a Conventional Commit message; **do not
  commit** (offer `/commit`). Scoped PASS stays `partial` unless the script's row rule yields
  `completed`.
- **FIX** (max **2** rounds) → write `.claude/tmp/exec-<backend>-fix-<n>.md` from the Fix-file
  section of [brief-template.md](brief-template.md) (static header, numbered fixes, diff excerpts);
  do **not** clear `.claude/tmp/exec-<backend>-brief.md`. Launch kind `fix:<n>` (same `<n>` as run
  id):
  - **Default (with `session_id`):** background

    ```bash
    bash <skill-dir>/../../scripts/delegate-launch.sh <backend> /absolute/repo/root <n> <model> fix:<n> <session_id>
    ```

    `session_id` empty/missing → fresh run (omit resume arg; script makes the backend read brief +
    fix file). Then Steps 6–7 again.
  - **`safe`/`no-force`:** print fix path + interactive command; wait for done; re-review (Step 7);
    skip Step 6; never invoke the CLI:

    ```bash
    bash <skill-dir>/../../scripts/delegate-launch.sh --interactive <backend> /absolute/repo/root <n> <model> fix:<n>
    ```

- **FAIL** (or still failing after 2 FIX rounds) → `terminal --outcome fail`; report; show rollback:

  ```bash
  git reset --hard <BaseSHA> && git clean -fd
  ```

  Run **only after user confirms**. Warn `git clean -fd` wipes untracked files **and the plan's
  audit write**. **After** confirmed rollback, **re-apply** the `fail` terminal write (same run
  fields) so the audit trail survives. If `<rows-json>` was removed, rewrite via `rows` (with
  `--reexecute` when that was the path) before `terminal`. User **abort** before terminal
  PASS/FAIL → `terminal --outcome abort` (or leave prior state if this run never wrote status).

## Shared constraints

- Claude Code–only plugin (`delegate`). Not exposed to Cursor, Devin, or Windsurf skill directories.
- Never auto-commit, auto-push, or open a PR.
- Never touch or write files outside the recorded repo root.
- Never report PASS when `delegate-verdict.sh` returns `ok: false` (non-zero `.exit`, fatal or
  permission stderr, timeout, or a non-clean terminal event). `safe`/`no-force` has no verdict JSON;
  Step 7 still has to pass.
- Claude writes plan status only via `plan-status.sh` (`start`,`batch`,`terminal`); never hand-edit
  the plan, and never edit `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursor/rules`, `.agents/` rules,
  or CI workflows during the loop. **The delegated backend must never** edit the plan (brief
  forbids it, incl. frontmatter and Execution log) or protected repo config.
