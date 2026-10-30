---
name: critique
description: >-
  Lean independent review of a plan file or code changes: mid-tier 1–2 passes,
  Opus escalate if blockers remain, plus a Cursor/Claude security-review pass
  when available. Args: [plan <path> | change <ref|range|#PR> | <path-or-ref>].
  Use when the user asks to review a plan or change, or mentions /critique.
disable-model-invocation: true
---

# critique

High-confidence, low-token second opinion on a **plan** or **change**. Not a second Opus planning/execute loop. Prefer “Ship as-is” over inventing nits. Auto-apply only `blocking` / `important`; leave `nit`s for the user.

**Budget:** Phase A — up to **2 mid-tier** lean review+fix cycles. Phase B — at most **one Opus escalate** if blockers remain, then **stop** and hand remaining items to the user. Never silent “Ship as-is” while `blocking` / unresolved `important` remain. Never spin mid-tier past 2 rounds.

## When to use / skip

- **Use `/critique plan`** after `/make-plan` for an independent stress-test before execute (especially large blast radius, migrations, security-sensitive scope).
- **Keep light** if the plan is tiny/mechanical and already has Execution map + Verification/coverage — one short mid-tier pass, not a multi-round rewrite.
- **Use `/critique change`** before commit when `/execute-plan` was **not** used, or for hand-written diffs.
- **After a successful `/execute-plan` Opus review loop:** skip the **lean** change critique by default; **still run the security pass** unless docs-only or the user opts out. If the user insists on lean critique anyway, one mid-tier pass only.
- Main `/critique` session need not be Opus; mid-tier is fine.

## Not Cursor `/review` (but may invoke Security Review)

Cursor's built-in **`/review`** / **`/review-bugbot`** / **`/review-security`** are product surfaces. This skill is the fleet multi-mode critique. For **security**, `/critique change` **invokes** Cursor Security Review (or Claude Code equivalent) as a sub-step when available — do not tell the user to run `/review-security` separately if this skill already ran it successfully.

| Need | Use |
| --- | --- |
| Stress-test a `docs/plans/**` plan; lean fix loop | **`/critique plan`** |
| Working-tree / commit critique + security pass | **`/critique change`** |
| Standalone PR Bugbot / Security only | Cursor **`/review-bugbot`** / **`/review-security`** |

## Preconditions

**Requires Agent mode** when applying plan edits or code fixes. If you are in Plan or Ask mode and the chosen mode needs writes, stop and tell the user to switch to Agent mode before continuing.

## Model tiers

| Role | Cursor | Claude Code |
| --- | --- | --- |
| Lean review Task | Auto (`model: inherit` / omit) — **never pin Sonnet** | Sonnet (`model: "sonnet"`) |
| Fix Task (change) | Auto; Haiku if mechanical | Sonnet; Haiku if mechanical |
| Opus escalate (≤1) | Pin top-tier when available; reason `critique escalate` | Opus/Fable; reason `critique escalate` |
| Security pass | `security-review` subagent (see below) | Same role if available; else inline fallback |

Report each subagent with intended tier and resolved model.

## Step 1 — Detect review context

Determine whether this is a **plan review** or a **change review**. Run `git status`, `git diff`, `git log --oneline -10`, and `Glob docs/plans/*.md` in parallel first.

Parse the user's slash-command or message args.

### Explicit mode (args start with a mode keyword)

- `critique plan [path]` → **plan mode**. If a path is given, use it; otherwise pick the most recent `docs/plans/*.md` (or ask if multiple candidates).
- `critique change [ref|range|#PR]` → **change mode**. Parse the ref per "Change mode — Resolve the diff" below.
- `critique <path-or-ref>` (no keyword) → resolve the argument:
  - If it's an existing file path ending in `.md` under `docs/plans/` (or matches a plan file) → **plan mode** with that path.
  - If it looks like a commit-ish, range (`a..b`), or PR number (`#123` / `123`) → **change mode** with that ref.
  - Otherwise → ask the user which mode they meant.

### No arguments — auto-detect

- **Has uncommitted changes** (staged or unstaged) → **change mode** (review `git diff HEAD`).
- **Working tree clean, has commits** → look at `docs/plans/*.md`:
  - If the most recent plan file's timestamp is newer than the latest commit's author date → **plan mode**.
  - Otherwise → **change mode** (review the latest commit, `git show HEAD`).
- **No commits and no plan files** → tell the user there's nothing to review and stop.
- **Both a fresh plan and uncommitted changes exist** → ambiguous. Use `AskQuestion` when available (otherwise ask conversationally):
  - Option A: "Review the plan at `<path>`" — rationale: stress-test before execute.
  - Option B: "Review uncommitted changes (`git diff HEAD`)" — rationale: catch bugs before commit.
  - Option C: "Other".
  - **Recommendation: A** if the plan was drafted in this session, otherwise **B**.

If at any point you cannot confidently determine the mode, ask — never guess.

## Step 2 — Run the appropriate mode

Skip to Plan mode or Change mode below.

---

## Shared — lean output contract

Review Tasks must:

- Omit solid categories entirely — **no** “Solid.” padding.
- Report **only** high-confidence `blocking` / `important` / `nit` findings (nits ≤3, optional; prefer zero).
- Blind spots: only if there is a real finding; else one line: “No additional blind spots.”
- No plan/code rewrites for style. Prefer Ship as-is when unsure.
- Verdict: one of `"Ship as-is"`, `"Apply N suggested changes then ship"` / `"Address N findings then ship"`, `"Rework — fundamental issues"`. Count must match actionable items. **Never** verdict Ship as-is while `blocking` or unresolved `important` remain.

Each finding: **Severity**, **Location**, **Description**, **Suggested fix**.

If none: “No high-confidence issues found.”

---

## Shared — round budget (Phase A / B)

### Phase A — lean (mid-tier), max 2

1. Spawn an independent **read-only** lean review Task (`generalPurpose`).
2. Parse findings; auto-apply only `blocking` / `important` (plan: main agent edits; change: fix Task).
3. Stop if Ship as-is / only nits / no high-confidence issues.
4. If blockers remain with clear fixes: apply, then **at most one more** lean review (max **2** mid-tier reviews total).

### Phase B — Opus escalate (only if still dirty)

Run **exactly one** Opus review when:

- round-1 verdict is “Rework”, or
- after **2 mid-tier** rounds any `blocking` or unresolved `important` remains.

Apply clear blocking/important fixes; optional quick lint/tests verify. **No further automatic rounds.**

If issues still remain: **stop**. Present the consolidated remaining list. Offer: refine manually / re-run `/critique` later / accept deferred.

---

## Plan mode

Review a plan file in `docs/plans/**` (or promoted `.cursor/plans/`) for residual failure modes, then apply fixes to the plan file.

### Load the plan

Read the plan with `Read`. Capture content for the review Task. On round 2 / escalate, pass **prior findings + updated plan**, not a full criteria re-narration.

### Lean review criteria (only report hits)

1. **Unverified assumptions / missing decisions** that will cause guesswork at execute time
2. **Failure modes & unsafe half-done states**
3. **Sequencing / blast radius / irreversibility** gaps
4. **Verification gaps** — missing commands, coverage claim without tooling, Success criteria vs Verification mismatch

Also flag **security-sensitive scope** (auth, crypto, PII, network trust boundaries) so a change-mode security pass will be needed later. Do **not** run Cursor `security-review` on a plan file alone (diff-based tool).

Do **not** re-litigate Execution map tier labels or Goal wording unless wrong/unsafe.

### Suggested changes

Concrete, minimal plan edits tied to a finding. If a finding needs a human decision, frame it as a question — do not invent the answer.

### Applying changes

Main agent edits only the plan file under review. Summarize fixes in 1–2 sentences per finding. Never commit or push.

### Plan mode constraints

- Only edit the plan file under review. No other files.
- Never commit or push.
- If the plan references paths you can't verify with `Glob`/`Read`, flag that as a finding rather than guessing.

---

## Change mode

Review a git diff for residual bugs and gaps; apply fixes via a separate fix subagent; run a **security pass** via product tooling when available.

### Resolve the diff

Using the ref from Step 1 (or auto-detected):

- **Commit-ish** → `git show <ref>` / `git diff <ref>~1 <ref>`.
- **Range** (`a..b`) → `git diff a..b`.
- **PR number** → `gh pr diff` / `gh pr view` when `gh` is available.
- **No ref:** dirty tree → `git diff HEAD`; clean → `git show HEAD`.

Capture diff, changed files, base ref. For lean review: if the diff is huge, pass `git diff --stat` + file list and instruct the reviewer to `Read` hottest files — still require evidence before findings.

**Working tree vs commit:** Fixes always land in the working tree (never rewrite history). Tell the user when the reviewed ref was a commit but fixes are uncommitted.

### After execute-plan

If this session (or the user) just finished `/execute-plan` with a converged Opus review: **skip Phase A lean critique** unless the user insists. Proceed to **Security pass**, then Final output.

### Lean review criteria (only report hits)

1. **Correctness & logic**
2. **Edge cases / null safety** where the diff introduces risk
3. **API contracts / breakages**
4. **Tests missing** for new behavior

Optional catch-all: other high-confidence issues (caching, resources, conventions) only when a finding exists. Do **not** full-audit security in the lean Task when the security pass runs.

### Fix subagent contract

- Only edit files in the current diff. Minimal change. No mutating git. No installs/migrations (defer those).
- Per finding: `fixed` | `deferred` | `disputed` | `skipped` (nits).
- Verify edited regions by reading them. Main agent may run fast lint/typecheck after fixes; prefer revert + defer if a non-trivial regression appears.

### Post-round verification (main agent)

1. `git diff --stat` — revert out-of-scope files with `git checkout -- <file>` if needed.
2. Optional fast lint/typecheck/test; fix or revert+defer on failure.
3. Record round outcomes for the summary.

### Security pass (change mode)

Run **once** per `/critique change` (not per lean round). Prefer **in parallel** with the first lean review when the surface allows concurrent Tasks; otherwise after locating the diff / after skipping lean post-execute-plan.

#### When to run

- Diff touches code (not docs-only / lockfile-only / pure markdown).
- Skip with one-line reason if docs-only / generated-only, or user opts out.

#### Cursor

If `security-review` subagent type is available, launch **exactly one**:

- `description: "Security Review"`
- `subagent_type: "security-review"`
- `run_in_background: false` unless the user asked for background

Prompt shape (do **not** pre-compute the diff for this subagent):

```text
Full Repository Path: <absolute repository path>
Diff: <uncommitted changes | branch changes>
```

Use `uncommitted changes` for working-tree / HEAD-diff reviews; `branch changes` when reviewing branch/PR scope. Add `Base Branch:` / `Custom Instructions:` only when needed (same rules as Cursor review-security).

Retry once on incorrect invocation or transient failure; then stop and report the blocker.

#### Claude Code

If a security-review skill, plugin, or subagent with the same role exists, invoke it once equivalently. Otherwise use **inline fallback**.

#### Inline fallback (tooling unavailable)

One short mid-tier read-only Task on trust-boundary issues only: injection, authz, secrets in logs, SSRF, unsafe deserialization. Cap findings; no 9-category essay.

#### Merge security findings

Map into `blocking` / `important` / `nit`. Auto-fix via fix Task only when concrete, in-diff, and safe; otherwise defer. Do not open a multi-round security loop. Do not tell the user to run `/review-security` separately if this pass already succeeded.

---

## Final output (both modes)

- **Mode** (plan / change) and what was reviewed.
- **Round table** (expect 1–2 lean rows; note Opus escalate if used) with model tiers.
- **Security** subsection (change mode): tool used (Cursor security-review / Claude equivalent / inline fallback / skipped + reason) and findings count or “no issues”.
- **Change mode:** current `git diff --stat` after fixes.
- **Deferred / disputed / remaining** list sorted by severity — never hide remaining blockers.
- **Final verdict** from the last substantive review (must not be Ship as-is if blockers remain).
- **Next steps:**
  - Plan: `/execute-plan <path>` or refine further.
  - Change: run tests, review deferred items, `/commit`, then `/gh-create-pr`.

## Global constraints

- Never commit or push.
- Never mutating git except allowed `git checkout -- <file>` revert for out-of-scope / regressing edits in change mode.
- Review Tasks: `generalPurpose` read-only (except platform `security-review` for the security pass). Fix Tasks: separate write agents. Never use the reviewer to apply fixes.
- Plan mode only edits the plan file. Change fix Tasks only edit files in the current diff.
- Auto-apply only `blocking` and `important`. Leave `nit`s for the user.
- Do not report speculative findings. Ground every conclusion in plan text or diff + read context.
- Pre-existing bugs in touched files: label separately; fix only if minimal and in-diff, else defer.
