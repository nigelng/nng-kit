# Implementer quality bar and Task prompt

Give each implementation Task (must meet the quality bar below before reporting success):

- Needed **plan sections** (Purpose, Scope, Assumptions, step text, related Files, relevant Verification, Success criteria, Risks).
- Its **map row** (ID, tier, Runner, wave, depends-on), **Files** (`—` = edit nothing), and **Acceptance** (`—` = none). Implement **only that step**.
- **Project root** path and Step 3 **Quality toolkit** (test/lint/type-check/coverage commands and target, when available).
- The instructions below:

> Implement only your assigned step. Meet the **per-step quality bar** before reporting success:
>
> 1. **Small cycles: test & implement → lint → verify** for behavior-changing work:
>    - **One behavior per cycle:** add/change one test assertion (per plan behavior, not implementation quirks) and the smallest code that satisfies it together (never run an intentionally incomplete stub test first); run path-scoped lint then the scoped test, then start the next cycle.
>    - **Edit, don't rewrite:** change only the lines the behavior needs; never regenerate a whole file or reorder untouched code; a rewrite the plan does not ask for → report and stop.
>    - **Tools before hand edits:** formatter for formatting, lint autofix for lint, a rename/codemod tool for mechanical changes, the project's sync or generator script for vendored and generated files.
>    - Keep functions small and readable (cyclomatic complexity **6 or lower**, no god methods, readable over clever); follow existing project conventions, naming, and patterns.
>    - Verify paths with `Glob` or `Read` before writing; do not invent file paths.
>    - Edit only the row's **Files** (no other paths). If an outside change is required, report and stop.
>    - **Acceptance:** when not `—`, run after lint and tests; it must pass (failing fails the step). `—` = none.
>    - **Lint first:** run toolkit lint/format-check/type-check on touched files (path-scoped when possible) before tests. Fix all lint/type/complexity errors; do not disable lint rules unless allowed by the plan. If toolkit has none, skip to verify and report "not available in toolkit".
>    - **Verify second:** run scoped tests on lint-clean code (or chain `lint && test`). Any fix must re-run lint and tests so final bytes on disk pass both.
> 2. **Justified skip** — pure docs, comment-only, formatting-only, or config/skill wording with no runtime behavior: skip unit tests, state why in the report, and run validate/portable/nix (or plan Verification) checks instead. Also allowed when preparing fixtures/scaffolding explicitly covered by a later mapped test step (cite that map ID).
> 3. **Do not commit or push.**
>
> Report back with:
> - Map step ID and tier.
> - Files changed (created, modified, deleted), plus `git diff --numstat -- <Files>` and `wc -l` for each created file (untracked files do not appear in `git diff`).
> - **Lint / type-check:** command(s) run, pass/fail — or "not available in toolkit".
> - **Tests:** paths added/updated, command(s) run, pass/fail — or justified skip (+ validate/portable/nix if used).
> - **Acceptance:** command and output, pass/fail — or `—` / no Acceptance column.
> - Issues you could not resolve.

## Full verification (after all waves)

Write `.claude/tmp/exec-claude-verify.txt` (not a tracked path; do not commit it). One command per line, as delegate `execute-via-core.md` Step 7.1 does: in-scope Acceptance, then copy-pastable Verification commands. A pipeline is one line. Skip empty acceptance and prose. Step 4 of `SKILL.md` chooses full suite or partial scope. Docs-only: validate/portable/nix commands, not a unit suite. `<skill-dir>` is the absolute directory of `execute-plan/SKILL.md`. From the repo root:

```bash
bash <skill-dir>/scripts/delegate-verify.sh /absolute/repo/root .claude/tmp/exec-claude-verify.txt
```

Exit 1 → fix Task (resume a wave agent when possible; `mid`, or `low` when mechanical), then re-run. Exit 3 (tree changed) → stop and ask. Exit 2 → stop and show stderr. Do not re-run the commands. From the output, check prose Verification bullets and coverage of the files the plan changed against the target: extend tests if below when available; never delete tests unless the replacement is equal or better. No coverage gate when Verification says unavailable.
