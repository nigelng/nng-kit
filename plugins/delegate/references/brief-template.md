# Delegated execution brief template

Claude fills this file at `.claude/tmp/exec-{{BACKEND}}-brief.md` (where
`{{BACKEND}}` is `cursor` or `agy`) before invoking the delegated backend CLI.
Replace the placeholders (`{{BACKEND}}`, `{{PLAN_PATH}}`, `{{REPO_ROOT}}`,
`{{STEP_SCOPE}}`, and `{{QUESTIONS_PATH}}` which resolves to
`.claude/tmp/exec-{{BACKEND}}-questions.md`). Do not commit this file.

---

# Execute via {{BACKEND}} — brief

## Plan

- **Plan path:** `{{PLAN_PATH}}`
- **Repo root:** `{{REPO_ROOT}}`
- **Step scope:** `{{STEP_SCOPE}}`  
  (default: all Implementation steps / Execution-map rows)

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
6. On ambiguity or a hard block: stop and write questions to
   `{{QUESTIONS_PATH}}` (`.claude/tmp/exec-{{BACKEND}}-questions.md`) — do not
   guess.
7. **Parallel subagents (optional):** you may delegate scoped steps to
   parallel subagents (Task tool) **only** when the steps are independent and
   touch **disjoint files**. Give each subagent its exact file list and these
   same rules. Keep dependent or overlapping steps sequential in the main
   session. Run Verification yourself after all subagents finish.

## Required final output

When finished (or when stopped on questions), report clearly:

1. **Files changed** — paths created/modified/deleted.
2. **Tests run** — exact commands and pass/fail.
3. **Deviations** — anything done differently from the plan (or "none").
