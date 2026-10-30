# Drafting rules (coverage, architecture docs, tiers, waves)

Read when drafting Step 4 content or validating an update. Companion to [plan-template.md](plan-template.md).

## Execution scaffold (Step 4–5, required)

Every new plan **must** ship the execution scaffold from [plan-template.md](plan-template.md): YAML frontmatter `execution:` block with `status: not-started` and zeroed progress, plus an empty `## Execution log` placed **immediately after** `## Execution map` and **before** `## Files to modify/create`. Do not append it at EOF. Field meanings and update rules live in `../execute-plan/execution-status.md` (SoT); do not restate them in the plan.

## Test coverage probe (Step 3)

Determine whether the project can measure coverage and what threshold (if any) already exists:

1. Inspect manifests and config for coverage tooling, e.g.:
   - JS/TS: `package.json` scripts (`coverage`, `test:coverage`, `vitest --coverage`, `jest --coverage`), `jest.config.*` / `vitest.config.*` `coverageThreshold`, `c8` / `nyc` / `@vitest/coverage-*`
   - Python: `pytest-cov`, `[tool.coverage]` / `.coveragerc`, `pyproject.toml` fail-under
   - Go: `go test -cover` / `-coverprofile` in Makefile/CI
   - Rust: `cargo llvm-cov` / `tarpaulin` in CI or docs
   - Other: CI workflow steps that publish or gate on coverage
2. Record one of:
   - **Available + threshold** — note the command and the existing percent (or per-metric floors).
   - **Available, no threshold** — note the command; plan will set a target (default **90%** unless the user chose otherwise in Step 2 / a follow-up ask).
   - **Not available** — no runnable coverage command found; do **not** invent a coverage gate. Note in Verification that coverage was not found; optionally list adding coverage tooling as out of scope or a follow-up.
3. If coverage is available and the target is still unclear, ask once (after this probe) with grounded options: repo threshold / 90% default / Other.

### Coverage in the plan

- Always run the probe and record the result under **Verification**.
- When coverage **is** available: set an explicit numeric **target** (prefer existing repo threshold; otherwise **90%** to match `/execute-plan`'s default unless the user chose another). Include the coverage command and target so `/execute-plan` does not guess. Prefer Implementation / Execution-map rows for tests that close coverage gaps on new or changed code.
- When coverage is **not** available: say so; do not block the plan on a fake percentage. Do not list a coverage command that does not exist.

## Update documentation (architecture docs)

Every new plan **must** include Implementation step(s) **and** matching Execution-map row(s) to **update** relevant architecture docs (or **create** under `docs/architecture/` if the Step 3 scan found none and the change affects system shape), **or** an explicit **justified skip** in Scope or Implementation.

- **Prefer updating** `docs/architecture/OVERVIEW.md` and the **canonical** Archify / diagram path from the Step 3 scan over inventing parallel docs.
- **Justified skip** — allowed only for pure chore / docs-only / formatting with **no** change to: runtime topology, config contracts, control plane, trust boundaries, or subsystem ownership. One line is enough (e.g. in Scope or the Implementation docs step).
- **Verification** for this outcome must be execute-checkable (`git diff` / Files show those architecture-doc paths changed as listed, **or** the one-line skip is present). Recording scan paths in Assumptions/Dependencies alone does **not** satisfy Verification.
- **Success criteria** must say architecture docs reflect the shape change, or that the skip is recorded.

### Architecture-doc scan (Step 3)

`Glob` / `Grep` / `Read` for architecture documentation. Default hints: `docs/architecture/**`, `**/ARCHITECTURE*`, `**/architecture/**`, README Architecture links, and Archify artifacts under `docs/architecture/`. Record paths for Assumptions / Dependencies / a short Architecture docs note.

**Canonical selection:** if a canonical prose doc (e.g. `OVERVIEW`) names a diagram or path, treat that as canonical; else prefer the newest `docs/architecture/**` artifact by folder timestamp; never ground on historical folders that disagree with the canonical doc.

On **update**, if the change alters system shape or Scope, re-run the scan and add/adjust the docs step + map row, or the justified skip. Pure wording-only plan edits may keep the prior note if Scope/shape is unchanged.

## Tier rules (when writing the map)

Portable tiers: `haiku` | `auto` | `opus`. Do **not** write `sonnet` in new plans — use `auto` for mid-tier.

- **`haiku`** — mechanical, tightly scoped: renames, copy patterns, fill-in boilerplate, add a test case from a template, wire an existing helper. One concern, few files, little judgment.
- **`auto`** — **default mid-tier** for most implementation: new logic, API shape, non-trivial tests, refactors with judgment. At execute time: **Cursor → platform Auto** (`model: inherit` / omit; never pin Sonnet); **Claude Code → Sonnet**.
- **`opus`** — rare; only for steps that need deep design judgment during execute. Prefer finishing design here so execute stays `auto`/`haiku`. Final whole-diff review may still use opus per subagent rules.

## Wave / parallel rules

- Same **Wave** number → independent (no shared write paths, no ordering dependency) → `/execute-plan` may run them **in parallel**.
- Higher wave waits on listed `Depends on` IDs.
- Split large steps until most rows are `haiku` or `auto`; avoid “do the feature” mega-steps.
- Prefer many small steps over few large ones when it does not create thrash (shared file conflicts → serial in the same wave or a later wave).
