<!-- static:start -->
# Delegated execution brief

## Rules (hard)

1. Implement **only** the scoped Implementation steps (and map rows if present).
2. No drive-by refactors, renames, or dependency changes outside the plan.
3. **Do not** edit the plan file in any way — including YAML frontmatter and
   `## Execution log` (Claude owns status writes; the delegated backend never
   touches them). Also **do not** edit: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`,
   `.cursor/rules`, `.agents/` rules, or CI workflows/config.
4. Run the plan's Verification **test** command(s) before finishing (and other
   Verification commands that apply to your scoped changes).
5. **Do not** commit, push, or change git branches.
6. On ambiguity or a hard block: stop and write questions to the path under
   **Run** — do not guess.
7. **Parallel subagents (optional):** you may delegate scoped steps to
   parallel subagents (Task tool) **only** when the steps are independent and
   touch **disjoint files**. Give each subagent its exact file list and these
   same rules. Keep dependent or overlapping steps sequential in the main
   session. Run Verification yourself after all subagents finish.
8. Implement only the rows under **Rows**.
9. Each row's Files is its write allowlist. Do not create, modify, or delete
   any path a selected row does not list.
10. Run each row's Acceptance and the quoted Verification.
11. Tier tags — you may hand a lower-tier row to a subagent pinned at that
    tier if your tool supports it (agy: `Model: "flash_lite"` for `low`,
    `"flash"` for `mid`), otherwise do it yourself.
12. Questions go to the path under **Run**.

## Required final output

When finished (or when stopped on questions), report clearly:

1. **Files changed** — paths created/modified/deleted.
2. **Tests run** — exact commands and pass/fail, including each row's
   Acceptance and the quoted Verification.
3. **Deviations** — anything done differently from the plan (or "none").
<!-- static:end -->

# Execute via {{BACKEND}} — brief

## Run

Claude fills this file at `.claude/tmp/exec-{{BACKEND}}-brief.md` (`{{BACKEND}}`
is `cursor`, `agy`, or `devin`) before invoking the delegated backend. Replace
every placeholder. Do not commit the filled brief.

- **Plan path:** `{{PLAN_PATH}}`
- **Repo root:** `{{REPO_ROOT}}`
- **Step scope:** `{{STEP_SCOPE}}`
  (default: all Implementation steps / Execution-map rows)
- **Questions path:** `{{QUESTIONS_PATH}}`
  (`.claude/tmp/exec-{{BACKEND}}-questions.md`)

## Shared plan context

Quote these plan sections verbatim under the headings below (no paraphrase).
Purpose may be titled Goal in the plan. Paste the plan's Purpose (or Goal),
Verification, and Success criteria.

### Purpose

{{PURPOSE}}

### Verification

{{VERIFICATION}}

### Success criteria

{{SUCCESS_CRITERIA}}

## Rows

One table row per selected row. Escape a literal pipe in a cell as `\|`.
After the table, paste each row's Implementation-step text verbatim.

| ID | Tier | Files | Acceptance | Depends on |
| --- | --- | --- | --- | --- |
| {{ROW_ID}} | {{ROW_TIER}} | {{ROW_FILES}} | {{ROW_ACCEPTANCE}} | {{ROW_DEPENDS}} |

### {{ROW_ID}}

{{ROW_STEP_TEXT}}

## Fix-file

<!-- On the implement brief, omit this section. On a FIX round, write `.claude/tmp/exec-{{BACKEND}}-fix-<n>.md` starting at the static header below, then the numbered fixes, then the diff excerpts. -->

<!-- static:start -->
# Fix header

Apply every numbered fix below exactly. Do not invent extra edits. Diff
excerpts show the failure; they are not a second task list. Do not edit the
plan file (frontmatter or `## Execution log`), `CLAUDE.md`, `AGENTS.md`,
`GEMINI.md`, `.cursor/rules`, `.agents/` rules, or CI workflows/config. Do not
commit, push, or change git branches. Stay inside the write allowlist (each
row's Files under **Rows**). Re-run each row's Acceptance and the quoted
Verification.

When finished, report:

1. **Files changed** — paths created/modified/deleted.
2. **Tests run** — exact commands and pass/fail.
3. **Deviations** — anything done differently from the numbered fixes (or "none").
<!-- static:end -->

### Numbered fixes

1. {{FIX_ITEM}}

### Diff excerpts

{{DIFF_EXCERPTS}}
