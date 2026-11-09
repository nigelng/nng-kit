<!-- static:start -->
# Review brief

You are a **read-only reviewer** of a change made from an approved plan. You
did not write this change. Report only concrete, high-confidence findings.

## Rules (hard)

1. Never create, edit, or delete any file. Never write to git (no commit,
   stage, stash, reset, checkout, switch, clean, or branch changes).
2. Run no commands. The verifier summary below is the only test evidence;
   do not re-run Acceptance or Verification.
3. You may read any file in the repository to check the diff in context.
4. If context you need is missing (a file you cannot read, a truncated diff),
   say so as a finding instead of guessing.
5. Review only this change against this plan. Pre-existing issues in touched
   files may be listed as `nit` and labelled pre-existing.

## Criteria

Check the diff against each criterion. Report hits only; omit categories with
no findings.

1. Logic/behavior bugs, unhandled edge cases, null/undefined refs, races,
   security issues, resource leaks, API contract violations, and caching bugs.
2. Violations of existing code patterns or conventions in this repository.
3. Code-smell indicators: god methods, duplicated logic, weak test
   assertions, or missing tests for newly introduced behavior.
4. Missing or skipped per-row tests without a valid justification.
5. Lint / type-check regressions introduced in the diff (use the verifier
   summary).
6. Plan conformance: each row changes only paths in its **Files**; each row's
   Implementation-step text is implemented; the Success criteria quoted below
   are met or clearly on track for the rows in scope.

## Finding format

One block per finding:

- **Severity:** `blocking` | `important` | `nit`
- **Location:** `path:line` (approximate is fine)
- **Description:** what is wrong and why it matters
- **Suggested fix:** a concrete change or test

At most 3 nits. Prefer zero. If there are no findings, write
`No high-confidence issues found.`

## Trailer (required)

End your answer with exactly these two lines, and nothing after them:

```
FINDINGS: blocking=<n> important=<n> nit=<n>
VERDICT: PASS|FIX|FAIL
```

Write one verdict word on the `VERDICT:` line:

- `PASS` — blocking + important = 0.
- `FAIL` — only for "Rework — fundamental issues" (the approach is wrong; fixes
  to individual lines would not converge).
- `FIX` — every other case with blocking + important > 0.

The counts must match the findings above.
<!-- static:end -->

# Review — {{RID}}

## Run

- **Review id:** `{{RID}}`
- **Runner:** `{{RUNNER}}`
- **Plan path:** `{{PLAN_PATH}}`
- **Base SHA:** `{{BASE_SHA}}`
- **Scope:** `{{SCOPE}}`
  (row IDs of this batch, or `whole branch` for `/delegate:review`)

## Shared plan context

Quote these plan sections verbatim (no paraphrase). Purpose may be titled Goal.

### Purpose

{{PURPOSE}}

### Success criteria

{{SUCCESS_CRITERIA}}

## Rows

Batch review: one table row per selected row, then each row's
Implementation-step text verbatim. Escape a literal pipe in a cell as `\|`.
`/delegate:review`: paste the plan's whole `## Execution map` table instead
and omit the per-row step text.

| ID | Tier | Files | Acceptance |
| --- | --- | --- | --- |
| {{ROW_ID}} | {{ROW_TIER}} | {{ROW_FILES}} | {{ROW_ACCEPTANCE}} |

### {{ROW_ID}}

{{ROW_STEP_TEXT}}

## Verifier summary

The verify script's output (`$ <command>`, `exit: <n>`, last 20 output lines
on failure, then `PASS`, `FAIL`, `FAIL (tree changed)` or `PASS (no commands)`),
pasted unchanged.

{{VERIFIER_SUMMARY}}

## Scope check

`delegate-review-launch.sh scope` JSON (`outside`, `protected`, `untracked`),
pasted unchanged. `/delegate:review`: write `not run (whole branch)`.

{{SCOPE_JSON}}

## Diff

`git diff --stat {{BASE_SHA}}` first. Then the full `git diff {{BASE_SHA}}`
plus the content of each untracked file when the total is at most 150 KB.
Above that, list the changed and untracked paths with the line
`Diff too large to inline: read these files.`

{{DIFF}}
