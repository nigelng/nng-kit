---
name: review
description: >-
  Final whole-branch top-tier review of a fleet plan's branch via the plan's
  Review runner (top@claude-task, top@session, or an external read-only
  reviewer: top@devin-fusion, top@cursor-ask, top@agy-plan). Read-only; never
  fixes or commits. Args: <plan> [ID] [base=<ref>] [runner=top@…]. Use for
  `/delegate:review`.
argument-hint: "<plan> [ID] [base=<ref>] [runner=top@…]"
allowed-tools: Read, Write, Glob, Grep, Task, AskUserQuestion, Bash(bash:*), Bash(git:*), Bash(which:*), Bash(agent:*), Bash(agy:*), Bash(devin:*), Bash(mkdir:*), Bash(rm:*), Bash(date:*)
disable-model-invocation: true
---

# review

`/delegate:review`: **Claude orchestrates; the review runner reviews.** Read-only — never fixes, never commits. Claude Code only.

Read [execute-via-core.md](../../references/execute-via-core.md) first — its Step 7 item 5 holds the review-runner rules (snapshot/check, `verdict`) this skill reuses — plus [review-runner.md](../../references/review-runner.md) for external `top@*` runners, [review-brief-template.md](../../references/review-brief-template.md), and [execution-status.md](../../references/execution-status.md).

`<skill-dir>` is this file's directory; invoke scripts as `bash <skill-dir>/../../scripts/<name>.sh` with the literal absolute path (same convention as core).

## Args

- `<plan>` — required; a plan under `docs/plans/**` (not `*.notes.md`).
- `[ID]` — optional Execution-map row id, validated in Step 1 before review runs. Runner comes from that row's `Review` cell; if `runner=` differs → stop and ask.
- `runner=top@…` — required when `ID` is omitted. Any runner not `top@*` → refuse.
- `base=<ref>` — optional; default `git merge-base HEAD main`, else `master`; neither resolves → stop and ask for `base=`. Resolve to a SHA with `git rev-parse`.

## Steps

0. **Host gate (Claude Code only).** `[ "${CLAUDECODE:-}" = "1" ]` — unset → stop: `delegate:*` skills never execute outside Claude Code (other tools can list them via Claude Code plugin import). No scripts, no `cd`, no status writes.
1. **Repo root + plan + lock.** `git rev-parse --show-toplevel`; record literal absolute path and `cd` there (shell vars do not persist across Bash calls). Plan must exist. Then `bash <skill-dir>/../../scripts/plan-status.sh lock <plan>`: exit 0 (`ok`/`legacy`) → continue; exit 3 → stop with stderr; exit 2 → stop. Dirty worktrees allowed — reviews may run before `/commit`.
   When `ID` is given, read its `## Execution map` row before verifier or review runs. Stop if missing, Tier != `top`, Runner != `session` (missing Runner on `top` row counts as `session`), Files != `—`, or Review != `top@*`; print failing field and suggest `/make-plan update <plan>`. Then derive runner from `Review`. `plan-status.sh review` enforces this at the end: exit 3 → print `REFUSE:` lines and stop; a failed write is never reported as PASS.
2. **Clear + rid.** `mkdir -p .claude/tmp` then `rm -f .claude/tmp/exec-review-final-*`. Review id `<rid>` = `final-<k>` (`k` = 1, +1 per retry).
3. **Verifier.** Write `.claude/tmp/exec-review-final-verify.txt`, one command per line: every copy-pastable command from the plan's Verification section (whole branch; no per-row Acceptance). Then run:

   ```bash
   bash <skill-dir>/../../scripts/delegate-verify.sh /absolute/repo/root \
     .claude/tmp/exec-review-final-verify.txt > .claude/tmp/exec-review-final-verify.out
   ```

   Exit 0 → verifier PASS; exit 1 → verifier FAIL; exit 3 → a Verification command modified the tree — stop and ask (never treat it as PASS); exit 2 → stop and show stderr. The script owns the tree snapshots; do not re-run commands outside it. Do not brief or review without a valid verifier summary — the summary is the `.out` contents.
4. **Brief.** Write `.claude/tmp/exec-review-<rid>-brief.md` from [review-brief-template.md](../../references/review-brief-template.md): copy `<!-- static:start -->`…`<!-- static:end -->` block unchanged. **Run**: `{{RID}}` = `<rid>`, `{{RUNNER}}` = the `top@*` value, plan path, `{{BASE_SHA}}` = resolved base SHA, `{{SCOPE}}` = `whole branch`. **Shared plan context**: Purpose (or Goal) and Success criteria verbatim. **Rows**: paste whole `## Execution map` table; no per-row step text. **Verifier summary**: paste unchanged. **Scope check**: `not run (whole branch)`. **Diff**: per template against base (untracked files included, `.claude/tmp` excluded; >150 KB → path list).
5. **Review.** Run the review exactly per core Step 7 item 5 for the resolved `top@*` runner (`top@session` / `top@claude-task`: `snapshot`, review text with the `FINDINGS:`/`VERDICT:` trailer → `.claude/tmp/exec-review-<rid>.md`, `check`; external runners: [review-runner.md](../../references/review-runner.md)). Then:

   ```bash
   bash <skill-dir>/../../scripts/delegate-review-launch.sh verdict /absolute/repo/root <rid>
   ```

   → `{ok,verdict,blocking,important,nit,timed_out,guard_clean,reasons}`. Exit 2 from any script call → stop and show stderr.
6. **Outcome.**
   - `ok: false` (launch error, quota, timeout, guard trip, `no verdict line`, `inconsistent verdict`) → **reviewer failure**: stop and ask — retry (new `<rid>`), `top@claude-task`, or abort. Never downgrade silently. Tripped guards already reverted reviewer edits; if `head_moved`, show stderr hint and do not touch refs. **No status write on abort.**
   - `verdict: PASS` and verifier `PASS` → pass (`ID` only when given):

     ```bash
     bash <skill-dir>/../../scripts/plan-status.sh review <plan> [ID] --outcome pass --runner <top@…> --findings 0 --notes "review=<top@…> clean"
     ```

   - Otherwise (a `FIX`/`FAIL` verdict, or a valid verifier summary that reported `FAIL`) → fail (`ID` only when given):

     ```bash
     bash <skill-dir>/../../scripts/plan-status.sh review <plan> [ID] --outcome fail --runner <top@…> --findings <blocking+important> --notes "review=<top@…> findings=<N>"
     ```

     List findings (severity, location, suggested fix) and failing verifier commands; suggest fixing (e.g. `/critique change` or a fix round) and re-running `/delegate:review`. No auto-fix.

## Report

Runner + resolved model, the verdict JSON, the verifier summary line, the status write result, and `final top-tier review converged: clean` only on PASS.

## Constraints

- Never edit source files or the plan body — status changes go through `plan-status.sh review` only. Never commit or push.
- Never use the implementing CLI session as the reviewer; a review runner is a fresh read-only session or Task (core Step 7 rules).
- Devin Fusion runs only as `top@devin-fusion` via `delegate-review-launch.sh` — never for execution here.
- Data egress: the diff and plan text go to the review runner's vendor. Briefs carry plan text and the diff only — never secrets or `.env` contents.
