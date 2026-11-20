# CI watch and triage

Callers may restrict this procedure (for example, `conduct`'s report-only finish forbids fixes, commits, pushes, and reruns).

CI checks are triggered by the push and/or PR creation. After the PR exists:

1. Run `gh pr checks <PR-number> --watch` to monitor status checks in real time.
2. If `--watch` is unsupported or times out, poll with `gh pr checks <PR-number>` every 30–60 seconds until all checks reach a terminal state (success, failure, or cancelled), **or until ~20 minutes have elapsed**.
3. If still pending after ~20 minutes, stop polling and report which checks are still pending (names + current status). Do not keep waiting indefinitely.

**If all checks pass** — report success and stop. Do not merge.

**If any check fails** — do not only report failure; investigate:

1. Run `gh run view <run-id> --log-failed` to fetch the failed job's logs.
2. Identify the failing step and extract the error message(s).
3. Cross-reference with the PR changes (caused by this PR vs pre-existing/flaky).
4. Present a summary:
   - Which check(s) failed and the job name(s)
   - Specific error message(s) and failing step(s)
   - Whether the failure is caused by the PR or appears pre-existing/flaky
   - A recommended next step (fix code, update workflow, re-run, etc.)
5. If the failure is clearly caused by the PR and the fix is obvious, offer to fix it. Do **not** fix without user approval; if approved, commit via `/commit` (a new commit, not an amend) and push normally without `--force`.
6. If flaky or infrastructure-related (network timeout, runner issue), offer `gh run rerun <run-id> --failed`.

**If checks are skipped or none run** — tell the user no CI checks were triggered and ask whether they expected any.
