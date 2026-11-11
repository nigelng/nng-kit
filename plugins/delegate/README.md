# delegate

Delegate fleet plan implementation to a headless coding CLI while Claude Code
stays in charge of the gates. Three execute skills share one flow:

- `/delegate:execute-via-cursor` runs the plan with Cursor's headless CLI
  (`agent`).
- `/delegate:execute-via-agy` runs the plan with Google's Antigravity CLI
  (`agy`).
- `/delegate:execute-via-devin` runs the plan with the Devin CLI (`devin`).

In each, the backend implements the plan on a branch. Claude Code runs the
preflight gates, reviews the resulting diff, and drives the PASS / FIX / FAIL
verdict loop.

`/delegate:review` is the fourth skill: the plan's final whole-branch
top-tier review through its Review runner. It is read-only — it never
implements, fixes, or commits.

## Prerequisites

Install and sign in to the CLI for the backend you use. Each skill needs only
its own CLI.

### `/delegate:execute-via-cursor`

- Cursor CLI (`agent`), installed and signed in.

### `/delegate:execute-via-agy`

- Google Antigravity CLI (`agy`):

  ```bash
  brew install --cask antigravity-cli
  ```

- One-time interactive sign-in: run `agy` in a terminal and complete the
  Google account login (stored in the keyring). This is not automated.
- Recommended when managed via Homebrew: set
  `AGY_CLI_DISABLE_AUTO_UPDATE=true`, so Homebrew stays the only updater.

### `/delegate:execute-via-devin`

- Devin CLI (`devin`), installed and signed in (`devin auth status` reports
  logged in). Install with `brew install --cask devin-cli`, then
  `devin auth login`.
- The plan must be runnable on the pinned models. The skill passes an exact
  effort slug from `model-tiers.md` (never Adaptive or Fusion).

## Platform

These skills are Claude Code only. They are not exposed to Cursor, Devin, or
Windsurf by the installer; Cursor's "Include Third-Party Plugins" import can
still list them from the Claude Code plugin set, so each skill runs a host gate
(`$CLAUDECODE` must be `1`) as its first preflight step and refuses outside
Claude Code.

## Scripts

Committed under `plugins/delegate/scripts/` (mode `100644`, run with `bash`):

| Script | Role |
| --- | --- |
| `plan-status.sh` | Plan lock (`lock`, `lock --gate`), Execution-map selection (`rows`, `rows --lint`), status writes (`start`, `batch` including `--skipped`, `terminal` including `--deferred-review`, `review`), plus `stamp`, `recent`, and `approve` |
| `delegate-launch.sh` | Build and run the backend CLI (headless background, or `--interactive` / `--print`) |
| `delegate-verdict.sh` | Classify one run's logs (`ok`, model, session id) |
| `delegate-review-launch.sh` | Review git guard (`snapshot`/`check`), `scope` check, external read-only reviewer `run`, and `verdict` (review trailer → JSON) |
| `delegate-verify.sh` | Run Verification commands from the repo root → `PASS` / `FAIL` / `FAIL (tree changed)` |
| `delegate-usage.sh` | Sum token usage over a run's launch files (feeds `terminal --usage`) |

Skills invoke them as `bash <skill-dir>/../../scripts/<name>.sh` (see
[execute-via-core.md](references/execute-via-core.md)).
`bash scripts/sync-kit-scripts.sh` copies `plan-status.sh` and
`delegate-verify.sh` into `lifecycle/skills/execute-plan/scripts/` (mode
0644) so a host that installs lifecycle without delegate still runs them.
`references/model-tiers.md` here is a full copy of the lifecycle canonical
file. The five lifecycle skill copies are compact (Fallback, Per-tool
resolution, Review runners, and the summary block). Regenerate both with
`bash scripts/sync-model-tiers.sh`.

**Row routing (`plan-status.sh rows`):** On a v2 Execution map, only rows whose
`Runner` is `delegate:<backend>` for the active skill (`delegate:cursor`,
`delegate:agy`, or `delegate:devin`) are selected; legacy plans without a map
fall back to Implementation-step selection. **Refuse:** a **top** row on
`delegate:*`, or a top ID you named in step-scope (`top rows never run on a
delegate`). **Skip** (exit 0): an unscoped top row whose runner is `session` or
`subagent`, with a note like `out of step-scope (top row: run in session)`.
Also refuses rows routed to a foreign runner (when step-scope names that ID).
`launch_tier` is the strongest tier among the
selected rows (`low` < `execute` < `mid`). Launch model comes from
`model-tiers.md` for that tier unless the JSON has `router: true` (every
selected row is `Model: auto` on Cursor `delegate:cursor`) → pass `--model auto`
and record `auto(router)`.

**Lifecycle commands on the same script.** `rows <plan> claude-code` selects
`session` and `subagent` rows, including `top`; `delegate:*` rows are skips
(`out of step-scope (dispatch via delegate)`). A selected row blocked on an
unfinished delegate row is reported as `blocked`, not refused, and an empty
selection still exits 0. `rows --lint <plan>` validates every scheduled row
and does not refuse for dependencies or an empty selection. `batch --skipped
ID --note TEXT` records a skip. `terminal --deferred-review` forces status
`partial` even on `--outcome pass`. `stamp` writes `plan_sha` and
`approved_at` (never `created_at`). `recent <dir>` prints the newest plan,
ignoring `*.notes.md` (exit 3 on a tie). `approve` writes `gate_b_sha` and
`gate_b_at` after a passing lock; only `/conduct` calls it, at Gate B.
`lock --gate` prints `gate_b_at` only when that stamp still equals both the
frontmatter and the computed `plan_sha`. A mismatch, a missing stamp, or a
legacy plan (no `plan_sha`) exits 3, and `/conduct` still requires Gate B.

## Review runners

Each delegated batch is reviewed at the strongest `Review` value among its
selected rows (`none` < `mid` < `top@*`; rows in one batch share one
`top@*`). The reviewer is read-only: it reviews a brief that already
contains the host verifier summary and the `scope` JSON, and it never runs
Verification itself (the host verify script does). Reviewers:

- `top@session` — this Claude Code session (the host) reviews the brief.
- `top@claude-task` — a read-only `Task(model: "opus")` subagent.
- `top@devin-fusion` — Devin Fusion, `devin --model <fusion pin>
  --permission-mode auto --respect-workspace-trust=false --print=…`.
- `top@cursor-ask` — Cursor `agent -p --mode=ask`.
- `top@agy-plan` — Antigravity `agy --mode plan`.
- `mid` — a read-only `Task(model: "sonnet")`.
- `none` — no review; clean only when the verify script says PASS and the scope
  check found nothing.

External runners are preflighted (`which`, and the exact model pin from
`model-tiers.md` listed by the CLI's `models` command) and launched in the
background through `delegate-review-launch.sh run`; the host waits for the
completion notification, then reads `verdict`. Before the review the host
snapshots the worktree (`snapshot`); after it, `check` reverts any reviewer
edit byte-exact (added files removed, index restored) and reports a moved
HEAD without resetting it — any change fails the review. Gitignored paths
are not covered by the guard. The review must end with the
`FINDINGS:`/`VERDICT:` trailer; `verdict` maps it to PASS / FIX / FAIL, and
a PASS also requires the verifier summary PASS and an empty `outside` +
`protected` scope — host evidence overrides a reviewer PASS. Reviewer
failure (`ok: false`) stops and asks; it is never reported as PASS.

`/delegate:review <plan> [ID] [base=<ref>] [runner=top@…]` runs the final
whole-branch review at the plan's Review runner (review ids `final-<k>`).
With an ID it marks that final `top` row done on PASS (failed otherwise) via
`plan-status.sh review` — a log stanza only, no `runs:` entry.

## Companion plugin: exec-observe

`exec-observe` is optional. It renders a live side pane for a delegated run:
status, counters, the current tool, and the timeline. It reads the run files
below and never feeds them into model context. Without it, the skills still
run and report normally. Cursor and Antigravity runs stream live; a Devin run
shows its summary when the run ends.

## Run records

Every finished run (PASS, FAIL or abort) appends one `runs:` entry to the plan's
`execution:` frontmatter and a matching `Run:` line in its `### Run` stanza:
backend, the requested model, the model the CLI actually reported (verbatim,
or `auto(unresolved)` when it reports none), effort, start and end, token
usage (`tokens_in`/`tokens_cached`/`tokens_out`, `null` when unknown), review
findings, FIX loops, and the fallback reason if a non-pinned model ran. Field
definitions live in [execution-status.md](references/execution-status.md).
Compare models across plans by counting findings per run in these records.

## Run-file contract

All run files live under the repo's `.claude/tmp/` directory. `<backend>` is
`cursor`, `agy`, or `devin`; review files use `<rid>` (`<backend>-<k>` for
batch reviews, `final-<k>` for `/delegate:review`).

| File | Purpose |
| --- | --- |
| `.claude/tmp/exec-<backend>-brief.md` | Brief handed to the backend |
| `.claude/tmp/exec-<backend>-fix-<n>.md` | Fix brief for verdict-loop round `<n>` |
| `.claude/tmp/exec-<backend>-questions.md` | Questions the backend raised for Claude |
| `.claude/tmp/exec-<backend>-rows.json` | Selected map rows from `plan-status.sh rows` (written in Step 4) |
| `.claude/tmp/exec-<backend>-verify.txt` | Verification commands for `delegate-verify.sh` |
| `.claude/tmp/exec-<backend>-verify.out` | Verify script output (the verifier summary) |
| `.claude/tmp/exec-run-<backend>-<n>.ndjson` | Run event stream (stdout) for `cursor` and `agy` |
| `.claude/tmp/exec-run-devin-<n>.json` | Devin conversation export |
| `.claude/tmp/exec-run-devin-<n>.out` | Devin stdout |
| `.claude/tmp/exec-run-<backend>-<n>.err` | Run stderr |
| `.claude/tmp/exec-run-<backend>-<n>.exit` | Run exit code |
| `.claude/tmp/exec-review-<rid>-brief.md` | Review brief (verifier summary + scope JSON + diff) |
| `.claude/tmp/exec-review-<rid>.md` | Reviewer output (must end with the `FINDINGS:`/`VERDICT:` trailer) |
| `.claude/tmp/exec-review-<rid>.err` | Reviewer stderr |
| `.claude/tmp/exec-review-<rid>.exit` | Reviewer exit code |
| `.claude/tmp/exec-review-<rid>.snap` | Guard snapshot taken before the review |
| `.claude/tmp/exec-review-<rid>.guard.json` | Guard result from `check` (`clean`, `head_moved`, `reverted`, `removed`) |
| `.claude/tmp/exec-review-final-verify.txt` / `.out` | Verification commands and verify script output for `/delegate:review` |

## Data egress and trust

Running a backend sends repository contents and the `.claude/tmp` brief to that
vendor: Cursor for `execute-via-cursor`, Google for `execute-via-agy`, or
Cognition for `execute-via-devin`, under your active sign-in. Briefs quote only
plan text and file paths. They never include secrets or `.env` contents. Review
the plan and the repo before you delegate it.

An external review runner (`top@devin-fusion`, `top@cursor-ask`,
`top@agy-plan`) receives the same kind of payload — the plan text and the
diff — from the same vendor as that backend's execution.

**Headless runs are unattended.** The default (non-`safe`) path auto-approves
every tool the backend calls: Cursor `--force --trust`, Antigravity
`--dangerously-skip-permissions`, Devin `--permission-mode dangerous`. Devin also
gets `--respect-workspace-trust=false`, which skips its workspace-trust check, so
repo-local Devin config and anything the plan or repository tells the agent to
run executes without a prompt. Delegate headless only on repositories you trust;
otherwise use `safe` / `no-force`, which never runs the CLI for you.

Devin's export (`exec-run-devin-<n>.json`) is the whole conversation, including
tool output, so it and the `.out` / `.err` files can contain secrets the agent
read. `execute-via-devin` deletes them once the verdict is final (PASS, FAIL or
abort).

## Long runs

Long or unattended runs default to Claude Code background sessions:

- `claude --bg -n <name> "<prompt>"` starts one and returns immediately (`/bg` does the same inside a session); it keeps running under the background daemon.
- `claude agents` lists live sessions; `claude attach <id>` reopens one, `claude logs <id>` prints recent output, `claude stop <id>` stops one (the conversation is kept).
- Where `ccstop` is installed, it stops every background session and then the daemon — the safe "stop them all" after a runaway or finished wave. `ccstop --dry-run` prints each action first.
- Never run `/loop` or other self-rescheduling commands inside a background session; they keep a paid worker alive indefinitely.
- tmux stays the fallback for CLIs that must outlive the Claude install or when the daemon misbehaves: `safe` / `no-force` prints the command; run it inside a user-started tmux session.

Spend caps are manual: before a long delegate wave, check the Cursor on-demand limit and the Devin extra-usage cap in their dashboards/settings.

## Parallel runs

Runs are sequential: one `impl/*` branch in the main checkout, one set of
`.claude/tmp` files per backend. Running in parallel across separate repos
needs nothing extra. Worktree support is decided later, when two delegated
plans must run in the same repo at once.

## Tests and smoke

From plugin root (`nng-kit/plugins/delegate/`):

- `bash tests/contract.sh`
- `bash tests/test-plan-status.sh`, `bash tests/test-delegate-launch.sh`,
  `bash tests/test-delegate-verdict.sh`, `bash tests/test-delegate-verify.sh`,
  `bash tests/test-delegate-usage.sh`,
  `bash tests/test-delegate-review-launch.sh` (or `bash tests/test-*.sh`)

From repo root, prefix paths with `nng-kit/plugins/delegate/` (e.g.
`bash nng-kit/plugins/delegate/tests/contract.sh` and the same for the
`test-*.sh` suites).

`contract.sh` checks flags that `delegate-launch.sh` emits via `--print` and
`--interactive` against `AGENT_FLAGS` / `AGY_FLAGS` / `DEVIN_FLAGS` and the
committed help fixtures; runs `delegate-verdict.sh` on PATH-shim stub logs;
asserts remaining Devin skill strings; then runs the `test-*.sh` suites.
Antigravity (`agy`) cases always run (no feature gate, no optional skip).

Maintainers also run a live version/flag check and an authenticated smoke outside
this repo.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install delegate@nng-kit
```
