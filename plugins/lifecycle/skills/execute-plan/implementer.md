# Implementer quality bar and Task prompt

Pass the Step 3 **Quality toolkit** into every implementation Task. Each map-row Task must finish to this bar before reporting success.

## Per-step quality bar

1. **Implement** the assigned step only (scope rules in the prompt below).
2. **Tests with the change** — for any step that changes behavior, API surface, or bug-prone logic: **add or update tests in the same Task**. Prefer smallest scoped tests that prove the step. Do not defer all testing to a final wave unless the map row is explicitly docs/config-only with no runtime behavior.
   - **Justified skip** (must state in the report): pure docs, comment-only, or formatting-only with no executable change; or the step only prepares fixtures that a later mapped test step covers (cite that map ID).
3. **Lint / static checks if available** — if the Quality toolkit lists lint, format-check, or type-check: **run them on the files touched this step** (path-scoped when supported). **Fix failures before finishing.** If no lint/type-check tool exists, say so once in the report.
4. **Scoped tests** — run the relevant test command for the touched area; fix failures before finishing.
5. **Do not commit or push.**

## Per-step subagent prompt

Give each implementation Task:

- The **plan sections** it needs (Purpose, Scope, Assumptions, its Implementation step text, related Files to modify/create, Verification relevant to its files, Success criteria, Risks).
- Its **map row** (ID, tier, wave, depends-on) and instruction to implement **only that step**.
- The **project root** path.
- The **Quality toolkit** (test / lint / type-check / coverage commands and coverage target when available).
- The following instructions:

> Implement only your assigned step. Meet the **per-step quality bar** before reporting success:
>
> 1. **Implement** by writing or editing the affected files.
>    - Prefer small, readable functions and methods. Keep cyclomatic complexity around **6 or lower**.
>    - Avoid god methods; no single function should do everything.
>    - Bias toward human-readable code over clever or compact code.
>    - Follow existing project conventions, naming, and patterns.
>    - Do not invent file paths — verify with `Glob` or `Read` before writing.
>    - Do not edit files outside your step's scope unless required for compilation; if blocked by another step, report and stop.
> 2. **Tests in this Task** — add or update tests for behavior you changed. Run scoped tests for touched files. Fix failures before finishing. If you skip tests, give an explicit justification (docs-only / covered by map ID …).
> 3. **Lint / type-check if available** — run the Quality toolkit lint and type-check commands on files you touched (path-scoped when possible). Treat lint/type errors as step failures; fix them before finishing. Do not disable lint rules to greenwash unless the plan explicitly allows it.
> 4. **Do not commit or push.**
>
> Report back with:
> - Map step ID and tier.
> - Files changed (created, modified, deleted).
> - **Tests:** paths added/updated, command(s) run, pass/fail — or justified skip.
> - **Lint / type-check:** command(s) run, pass/fail — or “not available in toolkit”.
> - Any issues you could not resolve.

## Full verification (after all waves)

Run (or re-run) the plan's Verification section:

1. Full test suite.
2. If coverage is available per the plan: coverage command vs target — add or extend tests if below target. Do not delete existing tests unless replacing with equivalent or better coverage. If coverage is not available, skip this bullet.
3. Project-wide (or Verification-listed) lint, type-check, and build commands — fix via a mid-tier (`auto`) or mechanical (`haiku`) Task if they fail.
4. If any verification fails, fix (resume a relevant wave agent when possible), then re-verify.

If any step reports unresolved issues, ask the user how to proceed before continuing to review.
