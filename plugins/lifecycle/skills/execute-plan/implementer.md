# Implementer quality bar and Task prompt

Each map-row Task must finish to the quality bar below before reporting success. Give each implementation Task:

- The **plan sections** it needs (Purpose, Scope, Assumptions, its Implementation step text, related Files to modify/create, Verification relevant to its files, Success criteria, Risks).
- Its **map row** (ID, tier, Runner, wave, depends-on), its **Files**, and its **Acceptance**. Implement **only that step**.
- **Files:** edit only those paths. `—` means edit nothing. A legacy row with no Files column uses the paths named in its Implementation step.
- **Acceptance:** when the row has a command, it must pass, and the report includes the command and its output. `—` means there is no acceptance command. A legacy row with no Acceptance column has none.
- The **project root** path.
- The Step 3 **Quality toolkit** (test / lint / type-check / coverage commands and coverage target when available).
- The following instructions:

> Implement only your assigned step. Meet the **per-step quality bar** before reporting success:
>
> 1. **Test & implement → lint → verify** for behavior-changing work:
>    - Write the scoped test assertions (against the plan's expected behavior, not your implementation quirks) and implement the assigned step's files together—do not waste turns running an intentionally incomplete stub test first.
>    - Prefer small, readable functions and methods. Keep cyclomatic complexity around **6 or lower**.
>    - Avoid god methods; no single function should do everything.
>    - Bias toward human-readable code over clever or compact code.
>    - Follow existing project conventions, naming, and patterns.
>    - Do not invent file paths — verify with `Glob` or `Read` before writing.
>    - Edit only the row's **Files**. Do not edit any other path. If a change outside those files is required, report and stop.
>    - **Acceptance:** when the command is not `—`, run it after lint and tests. It must pass. A failing Acceptance command fails the step. `—`, or a legacy row with no Acceptance column, means there is no acceptance command.
>    - **Lint first:** when the Quality toolkit lists lint, format-check, or type-check, run them on files you touched (path-scoped when possible) before the test suite. Treat lint/type errors as step failures and fix them, including complexity findings. If the toolkit has none, skip to verify and report "not available in toolkit". Do not disable lint rules to greenwash unless the plan explicitly allows it.
>    - **Verify second:** run scoped tests on the lint-clean code (or chain `lint && test` in one command). If a fix changes code, re-run lint and tests so the final bytes on disk pass both static checks and runtime assertions.
> 2. **Justified skip** — pure docs, comment-only, formatting-only, or config/skill wording with no runtime behavior: skip unit tests, state why in the report, and run validate/portable/nix (or plan Verification) checks instead. Also allowed when the step only prepares fixtures or scaffolding that a later mapped test step explicitly covers (cite that map ID).
> 3. **Do not commit or push.**
>
> Report back with:
> - Map step ID and tier.
> - Files changed (created, modified, deleted).
> - **Lint / type-check:** command(s) run, pass/fail — or "not available in toolkit".
> - **Tests:** paths added/updated, command(s) run, pass/fail — or justified skip (+ validate/portable/nix if used).
> - **Acceptance:** the command and its output, pass/fail — or `—` / no Acceptance column.
> - Any issues you could not resolve.

## Full verification (after all waves)

Re-run the plan's Verification section:

1. Full test suite (or docs-only validate/portable/nix when the whole run is docs/config).
2. If coverage is available: command vs target — extend tests if below; never delete tests unless replacing with equal/better coverage. Skip if unavailable.
3. Project-wide (or Verification-listed) lint/type-check/build — fix via `auto` or mechanical `haiku` Task on failure.
4. On any failure: fix (resume a wave agent when possible), then re-verify.
