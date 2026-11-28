# L0 lifecycle skills

These skills form the shared "idea → shipped" chain. They live in the `nng-kit`
marketplace (`plugins/lifecycle/skills/<name>/`), which is the source of truth.
Editing a skill means editing it **here**, never in an installed copy.

## Install

Full per-surface setup (including Devin `kit-*` profiles, Cursor Cloud Agents, and vendoring CI): [INSTALL.md](INSTALL.md).

| Surface | How it gets the skills | Invoke as |
| --- | --- | --- |
| Claude Code (local or cloud) | `claude plugin marketplace add nigelng/nng-kit` then `claude plugin install lifecycle@nng-kit` | `/lifecycle:<name>` |
| Devin CLI/Desktop | Web app (**Customize → Plugins** → `nigelng/nng-kit#plugins/lifecycle`), or `devin plugins install -y --local <nng-kit>/plugins/lifecycle` + link `host-profiles/devin/kit-*.md` | `/lifecycle:<name>` |
| Cursor | Import `https://github.com/nigelng/nng-kit` (`.cursor-plugin/marketplace.json`) or import plugins installed in Claude Code (enable Third-Party Imports) | `/lifecycle:<name>` |
| Antigravity | `agy plugin install <nng-kit>/plugins/lifecycle` | `/lifecycle:<name>` |
| Windsurf / other agents | Each skill dir linked into the tool's skills dir from a store location the tools do not scan, as a fallback when no plugin is installed | `/<name>` |
| Devin Cloud / consumer repos | Vendored real files under `<repo>/.agents/skills/` from a `lifecycle-v*` tag: `bash plugins/lifecycle/scripts/vendor-skills.sh <repo>` (in an nng-kit checkout). Drift is gated by the `nigelng/nng-kit/plugins/lifecycle/ci/vendor-check@lifecycle-vX.Y.Z` composite action — it fails CI when a vendored copy differs from its stamped tag. Re-vendor after a new tag. | `/<name>` |

The SKILL.md files use only relative links to sibling files and no plugin-only
syntax, so the same directory works on every surface.

`/delegate:execute-via-cursor` (needs the Cursor `agent` CLI),
`/delegate:execute-via-agy` (needs the Antigravity `agy` CLI),
`/delegate:execute-via-devin` (needs the Devin CLI) and `/delegate:review`
(the plan's Review runner — host session, read-only Task, or an external
read-only reviewer) are separate skills in the `delegate` plugin and are
**not** part of this plugin. They are described below because they write the
same plan audit metadata as `/execute-plan`.

## The chain

For a visual overview of the lifecycle and how `/conduct` orchestrates it, see the diagram in [README.md](../../README.md#lifecycle--conduct-flow).

```
/conduct [idea | artifact-path]    top-plan session; Agent mode; resumes from saved artifacts
  up-front finish=push|pr|commit|none push is default; plan=keep|drop; confirm=yes|no;
                                       delegate=run|print (print is default);
                                       unattended=yes|no (no is default); launcher=<name>
  Stage 1: brainstorm                reads sibling skills in-session with stage overrides
  Gate A                             Refine / Continue to plan / Stop
  Stage 2: make-plan                 writes or updates docs/plans/**
  Stage 3: critique plan             skips critique only for Plan size: small
  Gate B (hard)                      Approve / Refine (back to Stage 2) / Abort;
                                       never bypassed by args. Approve runs
                                       plan-status.sh approve, which writes gate_b_sha.
                                       Continue here, in a fresh session (recommended
                                       unless Plan size: small), or unattended
                                       (v2 map without delegate:* rows; creates a
                                       sibling worktree and starts or prints a mid
                                       worker). A fresh session starts at Stage 4
                                       only when lock --gate matches; a mismatch, a
                                       missing stamp, or an unstamped plan still
                                       requires Gate B. An executed-plan resume with
                                       a matching plan lock already passed Gate B
  Stage 4: execute-plan              ensures feature branch first unless finish=none
  Stage 5: critique change           whole branch + working tree + untracked files;
                                       review Tasks receive a base ref and run the
                                       diff themselves. Phase A (lean mid rounds)
                                       skips only when this session's Stage 4
                                       fingerprint is unchanged and head equals the
                                       review base. Skip the closing top pass when
                                       Phase A was skipped and Stage 4's final review
                                       was a clean `top@*`; otherwise keep it. The
                                       security pass always runs, then re-run
                                       Verification
  Stage 6: finish                    push = branch + commit + push (default);
                                       pr = push + PR + CI watch;
                                       commit = branch + local commits, no push/PR;
                                       none = uncommitted, no branch/commit/push/PR
  downgrade to finish=none            stop before any further commit and report if execution is not
                                       completed, final review is dirty/deferred, critique
                                       leaves blocking/unresolved important findings,
                                       Verification fails, a hook rejects, or the current
                                       branch is the default branch at finish

/brainstorm [idea]                 top-tier session; read-only; adaptive Goal brief
  → docs/brainstorms/**              (extract → ask gaps → never empty), explores
  → /make-plan handoff prompt        feasibility, iterates with the user, then emits a
                                       roadmap + a ready-to-paste /make-plan prompt

/make-plan [update] [task]         top-tier planner; interview-first for Goal/requirements
  → docs/plans/**                     when no brainstorm handoff; drafts a structured plan
                                       with an Execution map v2 (top/execute/mid/low
                                       tiers, waves; Dispatch run order)

/critique plan <path>              optional top-tier second opinion on the plan before
  (optional)                          execute (not a lean mid-tier pass)

/execute-plan <path>               orchestrator (`mid` on a linted v2 map, else the
                                       host's `top-review` pin); requires Agent mode; refuses
  → uncommitted working-tree diff     if Blocked / missing Success or Verification;
    (or local commit when              requires an Execution map v2 (hard stop if missing;
     relax.executePlanCommit=true)     /make-plan update); runs waves per ## Dispatch
                                       (execute/low implementers; mid review passes;
                                       top-tier final pass, until clean). Lock, map
                                       rows, and status writes go through
                                       plan-status.sh; Verification goes through
                                       delegate-verify.sh

/delegate:execute-via-cursor <path>  Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Cursor `agent` CLI implements (default tier
                                       `execute` pin when `model=` omitted; Auto only as a
                                       logged fallback); Claude gates, briefs, reviews
                                       (bounded FIX loop). Not an L0 multi-consumer skill —
                                       see Claude-only install note below. Prefer when you
                                       want Cursor to code and Claude to review; keep
                                       `/execute-plan` for in-process Task waves.

/delegate:execute-via-agy <path>    Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Antigravity `agy` CLI implements (default tier
                                       `execute` pin when `model=` omitted; Auto only as a
                                       logged fallback); Claude gates, briefs, reviews
                                       (bounded FIX loop). Same contract as
                                       `/delegate:execute-via-cursor`, different backend.

/delegate:execute-via-devin <path>  Claude Code–only alternative (`delegate` plugin):
  → uncommitted working-tree diff     Devin CLI implements (default Devin `execute` pin
                                       from model-tiers when `model=` omitted; pinned only,
                                       never `adaptive` or `fusion-*`); Claude gates,
                                       briefs, reviews (bounded FIX loop). Same contract as
                                       `/delegate:execute-via-cursor`, different backend.

/delegate:review <plan> [ID]        Claude Code–only (`delegate` plugin):
  → plan audit metadata                final whole-branch top-tier review through the
                                       plan's Review runner (read-only; the reviewer
                                       never runs Verification); `/execute-plan`
                                       defers to it when the Review runner is an
                                       external tool other than the host

/critique change [ref]             lean mid-tier diff rounds + final top-tier change
  (optional)                          critique; security pass (Cursor/Claude
                                       security-review when available); after a
                                       converged execute-plan review skip lean and
                                       skip the closing final pass by default; still
                                       run security unless docs-only; mid verify gate
                                       confirms lean findings before fixes; project-
                                       rules check; --depth quick|standard|deep

/commit                            low-tier default; classifies the diff, drafts a
  → local commit(s)                   Conventional Commit, optionally bumps
                                       version/CHANGELOG, commits only after approval
                                       (use mid-tier for large mixed splits); may stage
                                       tracked-eligible `docs/plans/**` with the feature
                                       (`docs/brainstorms/**` never)

/retro [plan]                      optional; run before the plan is dropped.
  → docs/lessons.md                   One approved entry (stats + 1–3 lessons) via
                                       lessons.sh. Never commits; never edits the plan.

/gh-create-pr                      planning-artifacts gate (Keep/Drop per plan and relay
  → pull request                      file on the branch), ensures a feature branch,
                                       optionally compacts noisy commits (`compact.md`,
                                       separate `--force-with-lease` approval if pushed),
                                       pushes, opens a PR via `gh`, and watches CI
                                       (investigates failures; does not auto-fix without
                                       approval; never deletes artifacts itself)

/gh-address-review [#PR]           one approval-gated PR feedback round: inspects threads,
  → fixes + replies + CI watch        reviews, comments, and failing CI (`pr-feedback.sh`),
                                       triages with approval, fixes, commits via `/commit`,
                                       pushes, posts batch-approved replies (opt-in thread
                                       resolution), and re-watches CI; never merges

/gh-draft-release                  drafts a GitHub Release with generated notes from
  → draft GitHub Release              unreleased commits; does not tag or publish

/gh-tag-release                    dates the changelog and pushes a release tag to
  → git tag + publish CI              trigger the publish workflow; does not create a
                                       GitHub Release (the workflow does)
```

`gh-draft-release` and `gh-tag-release` are alternatives, not a sequence — pick one
depending on whether the repo's release process is "draft notes for manual publish"
or "tag to trigger CI publish."

## Execute alternatives

- **`/execute-plan`** — in-process Task orchestrator (Execution-map waves +
  independent review: mid-tier passes, top-tier final pass). The orchestrator
  runs at **`mid`** when the map is v2 and `plan-status.sh rows --lint` exits 0,
  otherwise at the host's **`top-review`** pin; a **`mid`** orchestrator never
  does top-tier work itself (`top@session` → the host's `defaultReviewRunner`; a
  `top` `session` row → a top-tier Task). Multi-consumer L0 skill.
- **`/delegate:execute-via-cursor`** — Claude Code–only, in the `delegate` plugin:
  hands the plan to Cursor's `agent` CLI for implementation (when `model=` is
  omitted, resolves the Cursor `execute` pin from [model-tiers.md](model-tiers.md);
  Auto only as a logged fallback); Claude writes the brief, reviews against Base SHA +
  Verification, and may FIX-resume ≤2 times. Never commits (offer `/commit`).
  Not linked into `~/.agents/skills` or Cursor/Devin/Windsurf.
- **`/delegate:execute-via-agy`** — Claude Code–only, in the `delegate` plugin:
  same contract as `/delegate:execute-via-cursor`, but Google's Antigravity `agy`
  CLI does the implementing (default `execute` pin from [model-tiers.md](model-tiers.md)
  when `model=` omitted; Auto only as a logged fallback). Never commits.
- **`/delegate:execute-via-devin`** — Claude Code–only, in the `delegate` plugin:
  same contract as `/delegate:execute-via-cursor`, but the Devin CLI does the
  implementing (default Devin `execute` pin from [model-tiers.md](model-tiers.md)
  when `model=` omitted; pinned only — never `adaptive` or `fusion-*`). Never commits.
- **`/delegate:review`** — Claude Code–only, in the `delegate` plugin: the final
  whole-branch top-tier review through the plan's Review runner
  (`top@session`, `top@claude-task`, or an external runner from `tiers.sh
  runners`, such as `top@claude-headless` or `top@devin-fusion`). Read-only —
  the reviewer never runs Verification and never edits (a git guard reverts
  any reviewer change). `/execute-plan` prints the
  `/delegate:review` command when a plan's Review runner is an external tool
  other than the host; pass `[ID]` to mark that row done via
  `plan-status.sh review`. Never commits.

## Ideate vs plan (three-way split)

- **`/brainstorm`** — open-ended ideation: multiple approaches, feasibility unknown,
  Goal brief + roadmap. Persists to `docs/brainstorms/**`. Always a **top-tier**
  session (same model bar as `/make-plan`).
- **`/make-plan`** — scope already clear (or after brainstorm handoff); durable
  step-by-step plan under `docs/plans/**` for execute/critique and cross-session
  handoff. Always a **top-tier** planner session. When there is no brainstorm
  artifact, interviews for Goal, requirements, non-goals, and constraints before
  drafting. Plans include an **Execution map** v2 (waves; tiers `top` /
  `execute` / `mid` / `low`; **Runner**, **Files**, **Acceptance**, **Review**;
  optional **Model**), a **`## Dispatch`** run order, and `docs/plans/**` files
  named `YYYY-MM-DD-<slug>.md` with plan-lock metadata (`created_at`, `plan_sha`,
  `approved_at`). Map routing, recency (`created_at`, then filename, then mtime),
  and the body hash live in
  [skills/execute-plan/execution-status.md](skills/execute-plan/execution-status.md)
  (Plan metadata / Plan lock / Plan recency) — do not restate here. Biased to
  smallest mechanical units / prefer **low** tier. A plan that qualifies under
  **Small plans** in [skills/make-plan/drafting-rules.md](skills/make-plan/drafting-rules.md)
  records `Plan size: small` under Assumptions and skips the per-wave review
  lines plus the mid-tier review passes. Plans may be committed with the feature (`/commit`
  when tracked-eligible); `/gh-create-pr` asks **Keep/Drop** per plan on the
  branch so `main` does not accumulate stale plans.
- **Built-in Plan** (Cursor Plan mode / Claude Code `/plan`) — same "ready for
  steps" case, but product-owned artifacts under `~/.cursor/plans` or
  `~/.claude/plans` (not the fleet `docs/plans/**` contract). Claude `/plan`
  often continues into implementation after approval; `/make-plan` never does.
  Promote product plans into `docs/plans/**` before `/critique` / `/execute-plan`.

`/brainstorm` exits early with a recommendation when a plan path is enough.
`/make-plan` suggests `/brainstorm` first when approaches or a Goal brief are still
missing.

## Execution tiers

Portable map tiers: **`top`** | **`execute`** | **`mid`** | **`low`**
(aliases such as `opus`, `auto`, `sonnet`, `haiku` are refused).
**Roles:** `top-plan` = `/brainstorm`, `/make-plan`, and `/critique plan`;
`top-review` = map tier `top`, `/execute-plan` orchestrator, reviews, and
`/critique` escalate/closing; `top-critique` (optional) = the second-family
`/critique plan` review Task (`top-review` when absent or unpinnable) — map
tier **`top`** resolves to **`top-review`**. Per-skill
session/Task requirements: that skill's `SKILL.md`. Fallback and per-tool
resolution: [model-tiers.md](model-tiers.md). Maintainers (source repo only)
edit tier policy there, then run `bash scripts/sync-model-tiers.sh`; users
override pins with the user `tiers.json` file below. The five lifecycle skill copies
are compact: a generated header, then Fallback, Per-tool resolution, tool
notes, and Review runners. The canonical file and the delegate copy stay
full. Full v2 map columns,
**`## Dispatch`**, naming, plan lock, and recency:
[skills/execute-plan/execution-status.md](skills/execute-plan/execution-status.md).

Tier pins resolve from the registry `tiers.json` — canonical in the delegate
plugin at `plugins/delegate/scripts/tiers.json`, copied into
`skills/execute-plan/scripts/` — through `tiers.sh resolve <tool> <tier>`. An
optional user file
(`${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-$HOME/.config}/nng-kit/tiers.json}`)
is deep-merged over it. Setting `.tools.<id>.enabled = false` in that file
disables a tool across `tiers.sh`, row selection/lint, and delegate launches
(exit 3; see [Enable or disable a tool](../../README.md#enable-or-disable-a-tool)).
`model-tiers.md` is generated from the registry:
pins live in `tiers.json`, policy prose in `model-tiers.md`; edit either,
then run `bash scripts/sync-model-tiers.sh`. The registry schema, the
override file, the default host and the adding-a-tool checklist live in the
delegate plugin's
[Tool registry](../delegate/README.md#tool-registry) section.
Subagent spawning per host (claude-code, cursor, devin, agy; any other host or
no way to pin the model stops) is in
[skills/execute-plan/hosts.md](skills/execute-plan/hosts.md).

## Critique (policy A)

`/critique` is **not** a second planning/execute loop. Pass table and modes:
`skills/critique/SKILL.md`; models via
[model-tiers.md](model-tiers.md).

## Goal brief

`/brainstorm` establishes a short **Goal brief** — Goal, why now, non-goals, hard
constraints — before codebase exploration. The process is adaptive: **extract**
what args and the user message already state, **ask only gaps**, and **never
proceed with an empty brief** (floor). When the idea is tiny or args already encode
the brief, confirm a drafted 4-line brief in one turn instead of four interviews.

This brief is the fixed reference point carried, verbatim, through:

1. The persisted `docs/brainstorms/**` file.
2. The `/make-plan` handoff prompt (`Goal:` / `Scope:` / `Constraints:` /
   `Target Phase 1:` / `Brainstorm:` path markers).
3. The plan's `Purpose` section in `docs/plans/**`.

`/make-plan` parses `Brainstorm: docs/brainstorms/*.md` when present, reads that
file, and does not re-interview for facts the Goal brief or brainstorm already
answered. Without a brainstorm artifact, `/make-plan` runs the Requirements
interview (Goal, must-haves, non-goals, constraints) before exploring the
codebase.

Under `delegate=run` (Claude Code only, explicit consent asked up front;
needs `finish` other than `none`), the conductor runs `/execute-plan`,
checkpoint-commits the interim work (same exclusions as the finish commit),
follows the `delegate` plugin's execute skills and an external
`/delegate:review` in-session, and re-enters until the plan is `completed`.
Any stop (failed delegate run, dirty review, unresolved question, rejected
hook) downgrades: the checkpoints stay and are reported, never undone.
`delegate=print` (default) leaves the Dispatch lines for you to run.
`finish=commit` is branch plus local commits only, with no push or PR.

## Unattended /conduct

At Gate B, **Continue unattended** (`skills/conduct/unattended.md`) hands an approved v2 plan (without `delegate:*` rows) to a `mid`-model worker in a fresh detached sibling worktree (`../<repo>-conduct-<run-id>`):

- **Worktree & handoff lock:** `worktree.sh create <plan>` creates the worktree, copies `<plan>` (with `gate_b_sha`, without `handoff_run`) and any sibling `.notes.md`, writes `.claude/tmp/conduct-<run-id>.meta.json`, and stamps top-level `handoff_run` on the main-tree plan. While `handoff_run` is set, `plan-status.sh lock`, `lock --gate`, and `approve` refuse (exit 3) to block a second run; release it via `worktree.sh remove <run-id>` (when no commits were left or with `--release`) or manually with `plan-status.sh handoff --clear <plan>`. `worktree.sh list` reports `<repo>-conduct-<run-id>` worktrees (`run_id`, `state`, `branch`, `pr_url`, `worktree`), and `worktree.sh remove <run-id> [--discard-plan] [--release] [--force]` removes a finished or stopped worktree.
- **Launcher:** comes from `launcher=` or `tiers.sh launcher` (`.conduct.launcher // "print"` in `tiers.json`); unknown launchers are refused. `launch.sh` enforces shared eligibility checks for both launchers (exit 4 `INELIGIBLE`, never falls back to `print`) and supports `print` (prints the quoted `cd ... && claude --model <id> ...` command) and `headless` (runs `claude -p` in the background; reads `tiers.sh headless` for `permissionMode`, `timeoutMinutes`, and `notify`, requires a matching probe marker from `launch.sh probe headless --model <id>`, writes `.claude/tmp/conduct-<run-id>.pid` with PID + `lstart`, and falls back once to `print` on exit 3). The exit watcher enforces `timeoutMinutes` (TERM, then KILL after 10 s on the `claude` process group, and cleans up leftovers on normal exit) and writes `status: "failed"` via `status.sh write --if-absent` if the session exits without writing the status file.
- **Worker contract (`unattended=yes`):** Gate B checks the resolved finish mode against `relax.unattendedFinish` (strict default `["pr"]`; allowed values `pr`, `push`, `commit`; `push` falls back to `pr` when `pr` is allowed and `push` is not; `none` or disallowed modes are refused). The worker runs `status.sh start` first (writes `.claude/tmp/conduct-<run-id>.started` so `print` runs appear in `worktree.sh list`), executes with `finish=<worker-finish> delegate=print plan=<keep|drop> confirm=no unattended=yes`, and never asks questions (`relax.reuseAheadBranch` does not apply). Foreign dirty paths, a branch ahead of `origin/<default>`, an unavailable `advisor`, or any downgrade/question stops the run with `finish=none` and writes `status: "stopped"` via `status.sh write`. Otherwise it creates a feature branch from the detached HEAD at Stage 4 and finishes per mode, recording status atomically to `<worktree>/.claude/tmp/conduct-<run-id>.json` via `status.sh write` (which derives `branch` and oldest-first `commits` from git and fires `.conduct.headless.notify` detached when configured): `finish=commit` writes `status: "committed"`, `finish=push` writes `status: "pushed"`, and `finish=pr` opens a draft PR (`gh pr create --draft`) and writes `status: "pr-opened"` with `pr_url`.

## Guardrail policy

User-only `/conduct` and `/execute-plan` policy lives under `.conduct` in `${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-$HOME/.config}/nng-kit/tiers.json}` (e.g. `~/.config/nng-kit/tiers.json`). `tiers.sh policy` reads `.conduct.defaults` and `.conduct.relax` (and `tiers.sh headless` reads `.conduct.headless`) exclusively from `$OVERRIDE` — if `$OVERRIDE` resolves inside any git repository or worktree it is ignored with `source: "ignored:in-repo"`, and unknown keys or invalid schemas exit 2 (callers fall back to strict defaults):

- **`.conduct.defaults`** (`CLI args > user config defaults > skill default`): `finish` (`push|pr|commit|none`), `delegate` (`print|run`), `plan` (`keep|drop`), `confirm` (`yes|no`), `continue` (`here|fresh|unattended`).
- **`.conduct.headless`** (override-only; in-repo ignored): `timeoutMinutes` (integer `1`–`1440`, default `120`), `permissionMode` (`auto|acceptEdits|default`, default `auto`; `NNG_KIT_HEADLESS_PERMISSION_MODE` env var overrides config), `notify` (optional non-empty argv array of non-empty strings with `notify[0]` an absolute path).
- **`.conduct.relax`** (opt-in relaxations, strict defaults shown):
  - `skipChoicePrompt` (`false`): skip prompting in `/conduct` Step 0.5 for choices already covered by `.conduct.defaults`.
  - `reuseAheadBranch` (`false`): in `/conduct` Step 0.6, reuse a non-default branch ahead of `origin/<default>` without prompting (reports the existing commits that will ship; not applied to unattended workers).
  - `executePlanCommit` (`false`): in standalone `/execute-plan`, auto-commit locally on a non-default branch after whole-map `completed` execution, clean final top-tier review, and clean Step 3 baseline (never pushes; ignored under `/conduct`).
  - `unattendedFinish` (`["pr"]`): non-empty subset of `["pr", "push", "commit"]` allowed for unattended `/conduct` workers.
- **Safety (never — cannot be relaxed by `.conduct`):** committing or pushing to the default branch; force-pushing, `--no-verify`, or amending; staging/committing `docs/brainstorms/**` or secrets/credentials; staging foreign paths or pre-staged foreign content; bypassing Gate B / plan lock, independent review (`/critique plan`'s Devin fallback is not a bypass), failed verification, or a downgrade; deleting dropped plans, discarding foreign work, auto-fixing CI, or merging a PR.

## Guardrails carried by every skill in this chain

- **No unapproved commits or pushes.** `/commit` and `/gh-create-pr`/`/gh-tag-release`
  standalone always present the exact change (message, branch, tag) for approval
  before acting. Under [`/conduct`](skills/conduct/SKILL.md), the up-front
  `finish=push`, `finish=pr` or `finish=commit` choice is the approval, subject to Gate B and the
  downgrade rule (`confirm=yes` adds confirmation before commit/PR). Standalone
  [`/execute-plan`](skills/execute-plan/SKILL.md) commits locally only when
  opt-in `relax.executePlanCommit` is `true` and all safety/cleanliness checks pass (never pushes).
  None of them ever commits or pushes to the default branch, bare-force-pushes (only
  standalone `/gh-create-pr` uses pinned `--force-with-lease` after separate approval
  for a compacted branch), or commits on a dirty or deferred review.
- **No scope creep past the plan.** Execute skills (`/execute-plan`,
  `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, `/delegate:execute-via-devin`) implement only what `docs/plans/**` specifies; they do
  not re-plan or expand scope.
- **Execute skills persist progress on the plan.** `/execute-plan`,
  `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, and `/delegate:execute-via-devin` record row status and
  run history in the plan file (frontmatter + `## Execution log`) per `skills/execute-plan/execution-status.md`,
  by calling `plan-status.sh`. Do not hand-edit `plan_sha` or `gate_b_sha`. Each
  finished run also appends a `runs:` record: backend, requested and resolved model (`auto(unresolved)` when the
  CLI reports none), effort, start/end, review findings, FIX loops and any fallback.
- **Refuse, don't guess, when a plan is unsafe to execute.** Execute skills
  (`/execute-plan`, `/delegate:execute-via-cursor`, `/delegate:execute-via-agy`, `/delegate:execute-via-devin`) stop (do not proceed, do not ask a
  soft clarifying question) if the plan has an unresolved "Blocked on" note or
  is missing a Success criteria or Verification section entirely.
- **Supported hosts and pinned models only.** `/execute-plan` and `/critique`
  spawn subagents per [skills/execute-plan/hosts.md](skills/execute-plan/hosts.md)
  (Claude Code, Cursor, Devin, and Antigravity (`agy`)). Any other host, or a
  model that cannot be pinned, stops the run before delegating.
  `/critique plan` on Devin without the profiles reviews in-session instead.
  `delegate` runners need a Claude Code host.
- **Independent review is never self-review** for `/critique change` and
  `/execute-plan`'s review loop — details:
  `skills/critique/SKILL.md`,
  `skills/execute-plan/review.md`;
  models via [model-tiers.md](model-tiers.md).
- **Behavior-changing implement steps:** small one-behavior cycles
  (test & implement → lint → verify), edit don't rewrite, tools before
  hand edits, and `git diff --numstat` reporting in
  `skills/execute-plan/implementer.md` (docs/config-only: justified skip +
  validate/portable checks).
- **`AskQuestion` batching.** Batch up to **4 independent questions** per
  `AskQuestion` call (2–4 options each, plus "Other" when useful); split only
  questions that depend on an earlier answer (`/brainstorm`'s Goal brief,
  `/make-plan`'s scope/constraints/success/assumptions, and similar).

## SKILL.md size budget

Cursor warns when a skill **body** exceeds ~**5,000 tokens**. Keep each
`SKILL.md` under that limit; put templates, long prompts, and detailed criteria
in sibling reference files one level deep (e.g. `plan-template.md`) and link
them from `SKILL.md`. Home Manager installs each skill as a whole directory
(one store symlink) and the plugin ships whole skill directories, so those
companions ship with the skill. `scripts/skill-budget.sh` measures that
closure — the skill file plus every `.md` it links directly, counted once
per path and not followed further — and checks it against
`scripts/nng-kit-skill-budgets.tsv`.

## Deterministic scripts

Bookkeeping that must not depend on the model following prose is a bash 3.2
script. Skills call one as `bash <skill-dir>/<relative>/scripts/<name>.sh`,
with `<skill-dir>` the absolute directory of the calling `SKILL.md`. Files
under `nng-kit/` stay mode 0644. Devin and agy install lifecycle without
delegate, so they run the copies under `skills/execute-plan/scripts/`.
`bash scripts/sync-kit-scripts.sh` writes those copies from
`plugins/delegate/scripts/` (`--check` fails when a copy drifts).

| Script | Role |
| --- | --- |
| `plan-status.sh` | Lock, Execution-map selection, and every status write. Source of truth in delegate; lifecycle copy next to `execute-plan`. |
| `delegate-verify.sh` | Run a Verification commands file from the repo root. Exit 0 pass, 1 command failure, 3 tree changed, 2 usage. |
| `delegate-skill.sh` | `/conduct`-only helper (next to `conduct`, not synced). Prints the absolute path of a delegate skill's `SKILL.md`: the installed `delegate@nng-kit` `installPath`, else the kit source tree. Exit 3 (`REFUSE`) when the skill is not found or its backend is disabled; exit 2 on usage. |
| `worktree.sh` | `/conduct`-only helper (next to `conduct`, not synced). `create <plan>` creates a detached sibling worktree `../<repo>-conduct-<run-id>` at `HEAD`, copies `<plan>` (with `gate_b_sha`, without `handoff_run`) and any sibling `.notes.md`, writes `.claude/tmp/conduct-<run-id>.meta.json`, and stamps `handoff_run` on the main-tree plan. `list` reports `<repo>-conduct-<run-id>` worktrees (`run_id`, `state`, `branch`, `pr_url`, `worktree`). `remove <run-id> [--discard-plan] [--release] [--force]` removes a worktree and clears `handoff_run` when no commits were left or `--release` is passed. Exit 3 (`REFUSE`) on invalid repo/plan/dirty-tree/ahead-branch/running-state checks; exit 2 on usage. |
| `launch.sh` | `/conduct`-only helper (next to `conduct`, not synced). Launches (`print` or `headless`) or probes (`probe headless`) an unattended `/conduct` worker session after running shared eligibility checks (`exit 4` `INELIGIBLE`); exit 3 on an unknown launcher, missing `claude` or `jq`, an unreadable `claude --version`, a failed probe, a missing or mismatched probe marker, or a disallowed permission mode; exit 2 on usage. `headless` reads `tiers.sh headless` (`timeoutMinutes`, `permissionMode`, `notify`), writes `.claude/tmp/conduct-<run-id>.pid`, prints `handle=pid:<n>` (the exit watcher, detached via `perl` `setsid` when available), enforces timeout + process-group cleanup, and writes `failed` via `status.sh write --if-absent` on unexpected exit. |
| `conduct/scripts/status.sh` | `/conduct`-only helper (not synced). `start` writes `.claude/tmp/conduct-<run-id>.started` (idempotent). `write --status <pr-opened\|pushed\|committed\|stopped\|failed> [--stage …] [--reason …] [--pr-url …] [--if-absent]` validates inputs/git state, writes `<worktree>/.claude/tmp/conduct-<run-id>.json` atomically, and fires `.conduct.headless.notify` detached when configured; exit 2 on validation/usage, exit 3 when `run_id` cannot be derived. |
| `tiers.sh` | Resolve tier pins from `tiers.json` beside it (`tools`, `host`, `order`, `delegates`, `runners`, `launcher`, `policy`, `headless`, `resolve`, `validate`); exit 3 when no pin is usable (`launcher` reads `.conduct.launcher // "print"`; `policy` and `headless` read `.conduct.defaults`/`.conduct.relax` and `.conduct.headless` exclusively from `$OVERRIDE`, ignoring in-repo overrides as `ignored:in-repo` and exiting 2 on invalid schema). Source of truth in delegate; lifecycle copy next to `execute-plan`. |
| `pr-artifacts.sh` | Read-only JSON for `/gh-create-pr`: added and modified plans (with `execution.status`), sibling notes at HEAD, relay files (`current_branch`, `mirror`), dropped plans (resolved SHA), and paths skipped for an unusual name. Never runs `git rm`. |
| `pr-compact.sh` | Branch commit compaction for `/gh-create-pr`: `signals <default>` (read-only JSON: `commits`, `merges`, `net_zero`, `followups`, `offer`, `reason`) and `apply <default> <spec-file>` (git-plumbing rewrite preserving author metadata, writing backup ref `refs/backups/pr-compact/<branch>-<ts>` before updating `HEAD`; exit 3 `REFUSE` on dirty tracked tree/index, detached/default HEAD, merges, a malformed spec, empty groups, or an `@<file>` message that is a symlink or outside `<git-dir>/pr-compact`). |
| `pr-feedback.sh` | Read-only JSON for `/gh-address-review`: open PR metadata, unresolved review threads, reviews, top-level comments, failing checks (with `run_id`), and truncation flag. |
| `git-preflight.sh` | Read-only `key=value` facts for `/commit` and the release skills. |
| `lessons.sh` | `summary`, `add`, `has`, and `read` for `/retro`. Caps: 500 bytes and 3 lessons per entry, 8 entries, 4096 bytes; exit 3 when over cap. |
| `skill-budget.sh` | Own and closure bytes for each kit `SKILL.md`, checked against `scripts/nng-kit-skill-budgets.tsv`. |
| `sync-model-tiers.sh` | Regenerate the tier copies from [model-tiers.md](model-tiers.md). |

`plan-status.sh` commands the lifecycle skills use:

- `lock <plan>` — stdout `ok` when `plan_sha` matches; exit 3 when the body changed or the plan has no `plan_sha` (unstamped).
- `lock --gate <plan>` — exit 0 and print `gate_b_at` only when `gate_b_sha` equals both the frontmatter `plan_sha` and the computed hash. A mismatch, a missing stamp, or no `plan_sha` exits 3. `--gate` must be the first argument; any extra or unknown argument exits 2. `/conduct` uses this to start a fresh session at Stage 4.
- `rows <plan> claude-code [ID…]` — selects `session` and `subagent` rows, including `top`. `delegate:*` rows are skips (`out of step-scope (dispatch via delegate)`). Only v2 maps are accepted: a plan with no map or with a non-v2 map is refused, with no step-list fallback. A selected row that depends on an unfinished delegate row is reported as `blocked`, not refused. Refuses (exit 3) if a selected row's external `Review` runner belongs to a disabled tool. Exit 0 with an empty selection when only skips remain.
- `rows --lint <plan>` — validates every scheduled row: the same row checks, plus Acceptance on non-`top` rows and Files overlap across a wave. Does not refuse for dependencies or an empty selection. Refuses (exit 3) any non-`done` row whose `Runner` (`delegate:*`) or `Review` (`top@*` other than `top@session`) belongs to a disabled tool (completed `done` rows stay valid; see [Enable or disable a tool](../../README.md#enable-or-disable-a-tool)). `/make-plan` runs it before presenting; `/critique plan` cites it.
- `start`, `batch`, `terminal`, `review` — the status writers. `batch` takes `--done`, `--failed`, and `--skipped ID --note TEXT`. `terminal --deferred-review` forces status `partial` even when `--outcome` is `pass`, and with it only explicit `--done` IDs are marked. Auto-marking by `terminal` never overwrites a `skipped` row, never marks a `blocked` row (direct or indirect) `done` or `failed`; an explicit `--done` still applies.
- `stamp <plan>` — writes `plan_sha` and `approved_at`, never `created_at`. Prints the body size and warns over 15,000 bytes. `/make-plan` calls it. Do not hand-edit `plan_sha`.
- `recent <dir>` — prints the newest plan (`created_at`, then the filename date, then mtime), ignoring `*.notes.md`. Exit 3 on a tie.
- `approve <plan>` — after a passing lock, writes `gate_b_sha` and `gate_b_at`. Only `/conduct` calls it, at Gate B Approve. Exit 3 writes nothing.
- `rows --runners <plan>` — prints `ID<TAB>runner` for each map row (used by unattended `/conduct` eligibility checks to reject `delegate:*` rows).
- `handoff <plan> <run_id>` / `handoff --clear <plan> [<run_id>]` — stamps or clears top-level `handoff_run` (outside `plan_sha`) after a passing `lock --gate`; while set, `lock`, `lock --gate`, and `approve` refuse (exit 3) to block a second concurrent run.

`git-preflight.sh` subcommands, all read-only: `state` (default branch with no hardcoded name, current branch, clean, upstream, ahead/behind after fetch), `version [<tag>]` (manifest version, unreleased changelog heading and its version, last tag, and whether `<tag>` exists locally and on the remote; `remote_tag=unknown` when `git ls-remote` fails), `bump <type> [<from>]` (`to=` from `<from>`, a tag ending in `x.y.z` such as `v1.2.3` or `lifecycle-v0.13.0`, default the manifest; `skip=yes` when the manifest is already at or past `to=`), and `fingerprint` (hash of `git diff HEAD` plus untracked file contents, excluding `docs/plans/**`, `docs/brainstorms/**` and `.claude/tmp/**`, plus `head=<sha>`). `/conduct` records `fingerprint` on a clean Stage 4 review and compares it at Stage 5.

`skill-budget.sh --write <tsv>` records current sizes and keeps targets. `--check <tsv>` fails when a current size exceeds the recorded one. `--targets <tsv>` lists every row still above its target and exits 1 if any.

`sync-model-tiers.sh` writes the compact copies described under Execution tiers into `brainstorm`, `make-plan`, `critique`, `execute-plan`, and `commit`. `--check` fails on drift.

## Skills in this chain

| Skill | Writes to | Commits/pushes? |
| --- | --- | --- |
| `conduct` | Brainstorms, plans, working tree; git branch/commit/push/PR per finish mode (`commit` stops before push); checkpoint commits under `delegate=run`; unattended worker sessions write `<worktree>/.claude/tmp/conduct-<run-id>.json` and finish per `relax.unattendedFinish` (`pr`/`push`/`commit`) | Per up-front finish mode, plus checkpoint commits under `delegate=run`; never to default branch; unattended workers finish without prompting (`pr` opens a draft PR) |
| `brainstorm` | `docs/brainstorms/**` | Never |
| `make-plan` | `docs/plans/**` | Never (skill); plans committable via `/commit` when tracked-eligible |
| `critique` | Plan file (plan mode) or working tree (change mode, via a fix subagent) | Never |
| `execute-plan` | Working tree (via implementation subagent); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never by default (leaves changes uncommitted for review); standalone auto-commits locally on a non-default branch when opt-in `relax.executePlanCommit` is true and execution + final top-tier review are clean (never pushes; ignored under `/conduct`) |
| `delegate:execute-via-cursor` | Working tree (via Cursor `agent` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:execute-via-agy` | Working tree (via Antigravity `agy` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:execute-via-devin` | Working tree (via Devin `devin` CLI; Claude reviews); plan audit metadata on `docs/plans/**` (frontmatter + Execution log) | Never (leaves changes uncommitted; Claude Code only, in the `delegate` plugin) |
| `delegate:review` | Plan audit metadata on `docs/plans/**` (`plan-status.sh review` marks the final `top` row; log stanza only, no `runs:` entry) | Never (read-only review through the plan's Review runner; Claude Code only, in the `delegate` plugin) |
| `commit` | Local git history | Commits only, after approval; never pushes |
| `retro` | `docs/lessons.md` | Never |
| `gh-create-pr` | Remote branch + PR; planning-artifacts gate on branch plans/relay; optional commit compaction (`compact.md`) | Pushes + opens PR, after approval (optional approved compaction via `pr-compact.sh`, plus separate `--force-with-lease` approval on a pushed branch); Keep/Drop (plans) or Keep/Discard (relay) — user runs `/commit` if dropping |
| `gh-address-review` | Working tree, remote branch + PR replies / opt-in thread resolution | Commits via `/commit`, pushes, posts replies, and reruns CI only after separate approvals; never merges |
| `gh-draft-release` | Draft GitHub Release | Creates a draft release, after approval |
| `gh-tag-release` | Git tag + publish CI trigger | Tags + pushes, after approval per step |
