# delegate

Delegate fleet plan implementation to a headless coding CLI while Claude Code
stays in charge of the gates. Two skills share one flow:

- `/delegate:execute-via-cursor` runs the plan with Cursor's headless CLI
  (`agent`).
- `/delegate:execute-via-agy` runs the plan with Google's Antigravity CLI
  (`agy`).

In both, the backend implements the plan on a branch. Claude Code runs the
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

- One-time interactive sign-in: run `agy` in a terminal and complete the
  Google account login (stored in the keyring). This is not automated.
- Recommended when managed via Homebrew: set
  `AGY_CLI_DISABLE_AUTO_UPDATE=true`, so Homebrew stays the only updater.

## Platform

These skills are Claude Code only. They are not exposed to Cursor, Devin, or
Windsurf.

## Companion plugin: exec-observe

`exec-observe` is optional. It renders a live side pane for a delegated run:
status, counters, the current tool, and the timeline. It reads the run files
below and never feeds them into model context. Without it, the skills still
run and report normally.

## Run-file contract

All run files live under the repo's `.claude/tmp/` directory. `<backend>` is
`cursor` or `agy`.

| File | Purpose |
| --- | --- |
| `.claude/tmp/exec-<backend>-brief.md` | Brief handed to the backend |
| `.claude/tmp/exec-<backend>-fix-<n>.md` | Fix brief for verdict-loop round `<n>` |
| `.claude/tmp/exec-<backend>-questions.md` | Questions the backend raised for Claude |
| `.claude/tmp/exec-run-<backend>-<n>.ndjson` | Run event stream (stdout) |
| `.claude/tmp/exec-run-<backend>-<n>.err` | Run stderr |
| `.claude/tmp/exec-run-<backend>-<n>.exit` | Run exit code |

## Data egress and trust

Running a backend sends repository contents and the `.claude/tmp` brief to that
vendor: Cursor for `execute-via-cursor`, or Google for `execute-via-agy`, under
your active sign-in. Briefs quote only plan text and file paths. They never
include secrets or `.env` contents. Review the plan and the repo before you
delegate it.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install delegate@nng-kit
```
