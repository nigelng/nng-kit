# delegate

Delegate fleet plan implementation to a headless coding CLI while Claude Code
stays in charge of the gates. Three skills share one flow:

- `/delegate:execute-via-cursor` runs the plan with Cursor's headless CLI
  (`agent`).
- `/delegate:execute-via-agy` runs the plan with Google's Antigravity CLI
  (`agy`).
- `/delegate:execute-via-devin` runs the plan with the Devin CLI (`devin`).

In each, the backend implements the plan on a branch. Claude Code runs the
preflight gates, reviews the resulting diff, and drives the PASS / FIX / FAIL
verdict loop.

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

- Set `AGY_ENABLED=1` or the skill stops immediately and writes nothing.

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
Windsurf.

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
or `auto(unresolved)` when it reports none), effort, start and end, review
findings, FIX loops, and the fallback reason if a non-pinned model ran. Field
definitions live in [execution-status.md](references/execution-status.md).
Compare models across plans by counting findings per run in these records.

## Run-file contract

All run files live under the repo's `.claude/tmp/` directory. `<backend>` is
`cursor`, `agy`, or `devin`.

| File | Purpose |
| --- | --- |
| `.claude/tmp/exec-<backend>-brief.md` | Brief handed to the backend |
| `.claude/tmp/exec-<backend>-fix-<n>.md` | Fix brief for verdict-loop round `<n>` |
| `.claude/tmp/exec-<backend>-questions.md` | Questions the backend raised for Claude |
| `.claude/tmp/exec-run-<backend>-<n>.ndjson` | Run event stream (stdout) for `cursor` and `agy` |
| `.claude/tmp/exec-run-devin-<n>.json` | Devin conversation export |
| `.claude/tmp/exec-run-devin-<n>.out` | Devin stdout |
| `.claude/tmp/exec-run-<backend>-<n>.err` | Run stderr |
| `.claude/tmp/exec-run-<backend>-<n>.exit` | Run exit code |

## Data egress and trust

Running a backend sends repository contents and the `.claude/tmp` brief to that
vendor: Cursor for `execute-via-cursor`, Google for `execute-via-agy`, or
Cognition for `execute-via-devin`, under your active sign-in. Briefs quote only
plan text and file paths. They never include secrets or `.env` contents. Review
the plan and the repo before you delegate it.

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

Run `tests/contract.sh` (skill flags vs committed help fixtures; stub CLI
NDJSON and Devin export predicates; predicate-string guard). Maintainers also run a live version/flag check and an authenticated smoke
outside this repo.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install delegate@nng-kit
```
