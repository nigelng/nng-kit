# Independent review criteria and loop

The review must be run by a **different subagent** than any that implemented. Use `subagent_type: "generalPurpose"` with an explicit **read-only** contract (do not edit files). Apply the same code-review criteria used by `/critique change`.

**Review model (every pass):** **top-tier / opus** — Claude Code: explicit Opus (or Fable) slug; Cursor: pin top-tier when the surface allows. Do **not** run `/execute-plan` review as Auto or Sonnet. If the tool cannot pin a top-tier review model, stop and tell the user before reviewing. Report each review as tier `opus` (execute-plan policy).

## Each review pass

1. Run `git diff` to capture the full change.
2. Launch a `Task` with `subagent_type: "generalPurpose"` and the **top-tier** review model. Give it:
   - The complete `git diff` output.
   - The full plan file content (including Execution map).
   - The review criteria below.
   - Explicit instruction: **read-only — do not edit, write, or delete any files**; only produce a structured review.
3. Wait for the Task to complete.
4. Parse the sub-agent's report.

## Sub-agent review criteria

The sub-agent must review the diff against each of these and report only concrete, high-confidence findings:

1. Logic errors and incorrect behavior.
2. Edge cases that are not handled.
3. Null/undefined reference issues.
4. Race conditions or concurrency issues.
5. Security vulnerabilities.
6. Improper resource management or resource leaks.
7. API contract violations.
8. Incorrect caching behavior, including staleness, key bugs, invalidation, and ineffective caching.
9. Violations of existing code patterns or conventions.
10. Code-smell indicators: god methods, cyclomatic complexity above the target, duplicated logic, weak test assertions, or missing tests for newly introduced behavior.
11. Missing or skipped per-step tests without a valid justification; behavior changed with no accompanying tests.
12. Lint / type-check regressions introduced in the diff when the project has those tools.

## Required sub-agent output format

Each finding must include:

- **Severity**: `blocking`, `important`, or `nit` (same vocabulary as `/critique change`).
- **Location**: file path and approximate line(s) if possible.
- **Description**: what is wrong and why it matters.
- **Suggested fix**: concrete change or test to add.
- **Tests needed**: yes/no — whether a new or updated test should cover the issue.

If no findings, the sub-agent must explicitly state: "No high-confidence issues found."

## Handling findings — fix subagent

For each concrete, high-confidence issue:

- If severity is `nit`, record it for the final summary but **do not** auto-fix unless the user asks.
- If severity is `blocking` or `important` and the fix is clear and safe, **resume the relevant implementation subagent** (using `Task` with the `resume` parameter and that step's agent ID), or spawn a new fix Task scoped to the finding's files. Prefer **`haiku`** when the fix is mechanical; otherwise **`auto`** (Cursor Auto / Claude Sonnet). Never use the review subagent to apply fixes.
- If the fix is unclear or risky, ask the user before proceeding.

After fixes are applied, re-run the full verification via a mid-tier Task, then launch a **new top-tier** review subagent for the next review pass.

**Loop until:** full tests pass; coverage meets target; no high-confidence bugs; no significant concerns remain.

**Stop conditions:**

- If two consecutive review passes find no new issues, stop.
- If after **5 iterations** issues still remain, stop and present the remaining concerns to the user.
