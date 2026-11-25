# Changelog

Notable changes to the nng-kit plugins, newest first. Each sync commit on
nigelng/nng-kit quotes the lines added here since the previous sync, so write
for plugin users. This file is public: keep private names and paths out.

## 2026-11-26

- lifecycle 0.21.0, delegate 0.16.0: Antigravity (`agy`) is enabled again
  (`enabled: true`, `delegate: true` in `tiers.json`). Tier resolution,
  `/delegate:execute-via-agy`, and the `top@agy-plan` review runner work
  again; `top@agy-plan` is listed in the generated Review runners, its
  summary block returns, and the grunt-work and review-family rules list agy
  Gemini again.

## 2026-11-24

- lifecycle 0.20.0: `/brainstorm` persists a required **Decisions** section (option
  picked + reason), and `/make-plan` lists those decisions under the plan's
  Assumptions as settled choices. `/brainstorm` notes that
  `docs/brainstorms/` is usually gitignored (run `/make-plan` in the same
  checkout or copy the file); when the `Brainstorm:` file is missing,
  `/make-plan` continues from the prompt's inline markers.
- lifecycle 0.20.0: `/critique change` now has a mid-tier verifier confirm each
  blocking/important lean finding before it is auto-applied (unconfirmed
  PLAUSIBLE ones go to the closing pass), requires a failure scenario per
  finding, adds a project-rules check and `--depth quick|standard|deep`, and
  re-checks closing-pass fixes.
- lifecycle 0.20.0, delegate 0.15.0: Devin `top-critique` (the
  `/critique plan` review Task and the `kit-critique` profile) is now
  `gemini-4-neon-xhigh`, falling back to `gpt-6-1-sol-high`. Reinstall the
  Devin `kit-*` profiles to pick up the new pin.

## 2026-11-22

- exec-observe 0.6.0: an old run no longer lingers in the status line. A
  finished run shows there only if it ended after this session started and
  less than 10 minutes ago; running and stalled runs always show. After
  `/clear` or in a new session the line starts empty, while `/exec` still
  opens the latest run's pane. New `/exec history` lists the last 10 finished
  runs (newest first: backend, number, plan and step, result, tools, files,
  duration, age). Each finished run is appended once to
  `<repo>/.claude/exec-history.ndjson`, capped at the newest 50, so history
  outlives the `.claude/tmp` files the skill clears. The file is local state:
  if the repo does not already ignore it, the plugin adds it to
  `.git/info/exclude` (never a tracked file).

## 2026-11-21

- lifecycle 0.19.0, delegate 0.14.0: Antigravity (`agy`) now ships disabled
  (`enabled: false`, `delegate: false` in `tiers.json`). Tier resolution,
  `/delegate:execute-via-agy`, and the `top@agy-plan` review runner refuse
  `agy`; the generated Review runners list now skips disabled tools, so
  `top@agy-plan` is no longer listed; its summary block is gone, and the grunt-work and review-family rules
  no longer list it. Pins are kept; to re-enable, set
  `{"tools":{"agy":{"enabled":true,"delegate":true}}}` in
  `~/.config/nng-kit/tiers.json`.
- lifecycle 0.19.0, delegate 0.14.0: Cursor gains a second model family for
  review work: `top-critique` (the `/critique plan` review Task) is
  `gemini-4-neon-xhigh`, and `top-review` falls back from
  `claude-opus-5-5-medium` to `gemini-4-neon-high` (both `--mode=ask`). Both
  draw on Cursor's third-party pool; `top-plan` stays on Opus.
- lifecycle 0.19.0, delegate 0.14.0: Claude Code pins `top-critique` (the
  `/critique plan` review Task) to `claude-fable-5-2` at effort medium
  (`Task(model: "fable")`); it falls back to `top-review` when Fable is
  unavailable. Every other Claude Code tier stays on Opus, Sonnet or Haiku.

## 2026-11-20

- lifecycle 0.18.0, delegate 0.13.0: Antigravity (`agy`) tiers now use the full
  Gemini 4 Hydrogen / Neon / Argon lineup (`top-plan` `claude-opus-5-5-high` →
  `gemini-4-neon-xhigh` → `gemini-4-argon-high`; `top-review`
  `claude-opus-5-5-medium` → `gemini-4-neon-high` → `gemini-4-argon-medium`;
  `top-critique` `gemini-4-neon-xhigh` → `gemini-4-argon-high`; `execute`
  `gemini-4-hydrogen-high` → `gemini-4-neon-high` → `gemini-4-argon-medium`;
  `mid` implement `gemini-4-neon-high` → `gemini-4-hydrogen-high` →
  `gemini-4-argon-medium`; `mid` review `gemini-4-argon-medium` →
  `gemini-4-neon-high` → `gemini-4-hydrogen-high`; `low`
  `gemini-4-hydrogen-medium`). `hosts.md`, `brief-template.md`, and the README
  now route `agy` subagents to `invoke_subagent` (`Model: "inherit"`) only when
  the resolved pin matches the session model, and to a pinned `swarm` worker
  (`action: "add"`, `model: "<slug>"`, `workspace: "inherit"`, then `kill`) for
  any other tier or effort level—dropping legacy `flash_lite`/`flash`/`pro`
  approximations and `else stop` row notes.

- lifecycle 0.18.0: `/retro [plan]` writes one approved lessons entry to
  `docs/lessons.md` through `lessons.sh` (at most 500 bytes and 3 lessons
  per entry, 8 entries, and 4096 bytes). It never commits.

## 2026-11-15

- delegate 0.12.0: Cursor delegate runs default to `--sandbox enabled` with
  no `--force`; `DELEGATE_SANDBOX=off` restores the old argv. The Cursor
  sandbox blocks writes outside the workspace (including `$HOME` and
  `.git/hooks/`) and rejects network-classified commands such as
  `curl https://…` before they run; it does not stop reads outside the
  workspace, `git commit`, or ssh egress. Devin and agy runs are unchanged
  (`DELEGATE_SANDBOX` is validated for every backend but changes only the
  Cursor argv). Known gap: a run whose commands were refused still exits 0
  and classifies `ok:true` in `delegate-verdict.sh`.

- lifecycle 0.17.0, delegate 0.12.0: Devin `mid` review passes now fall back
  `gpt-6-1-sol-high` → `claude-sonnet-5-5-high` → `kimi-k3-1-pro-high`. The
  dated `gemini-4-argon-medium` row is gone (its Devin price doubles on
  2026-12-01). The standalone Devin Fusion guidance keeps the `swe-2-medium`
  sidekick with no end date. No `until:` rows remain in the shipped tiers.

## 2026-11-14

- lifecycle 0.17.0, delegate 0.12.0: `enabled: false` in the tier registry
  (`~/.config/nng-kit/tiers.json` or `$NNG_KIT_TIERS`) is now enforced as a
  real off switch across row selection, lint, and launch (`cursor`, `devin`,
  `agy`). `plan-status.sh rows` refuses a disabled delegate backend or any
  selected row whose external `Review` runner belongs to a disabled tool
  (exit 3, `REFUSE:`); `rows --lint` flags non-`done` rows whose `Runner` or
  `Review` tool is disabled while leaving completed (`done`) rows valid.
  `delegate-launch.sh` (run, `--print`, `--interactive`) and
  `delegate-review-launch.sh run` (including `--print`) refuse disabled tools
  with exit 3 even when an explicit model slug is given, before writing
  `.claude/tmp` files or snapshots. Status-recording commands (`start`, `batch`,
  `terminal`, `review`), review guard/verdict helpers (`snapshot`, `check`,
  `scope`, `verdict`), and `tiers.sh delegates` keep accepting disabled ids so
  in-flight runs can finish. Agent references (`execute-via-core.md`,
  `review-runner.md`), `model-tiers.md`, and the README document the switch,
  verification via `tiers.sh`, and refusals.

- lifecycle 0.17.0: `/make-plan` runs its context reads (git state, recent
  plan, architecture-doc and coverage probes, template and drafting rules) as
  one parallel batch before the requirements interview. It asks the coverage
  target in that same batch instead of a second round. Drafting rules now
  schedule each map row in the earliest wave its dependencies allow, let docs
  and CHANGELOG rows run alongside implementation when nothing needs quoting,
  and say how to handle same-file rows, which `rows --lint` refuses in one
  wave. Plans keep each wave on one runner where the policy allows, so the
  whole wave runs as one parallel batch. `/critique` adds the recent-plan
  lookup to its first parallel batch. In change mode it merges security
  findings into lean round 1's fixes, so round 2 reviews them, and it runs
  fixes as one fix Task per separate file group, all launched together.

- delegate 0.12.0: the execute-via brief now passes each row's `Wave`. Backends
  run waves in order and run same-wave rows in parallel subagents when the CLI
  supports them, instead of working out row independence themselves.

- lifecycle 0.16.0 (Devin follow-ups): Devin needs the six `kit-*` profiles
  linked into `~/.config/devin/agents/` (README, Install (Devin)); the plugin
  install does not place them. Without `kit-critique` and `kit-review-top`,
  `/critique plan` reviews in-session, warns once and marks the verdict
  `in-session review`; `/execute-plan` and `/critique change` still stop.
  Read-only Devin profiles have no shell, so the session writes the diff and
  `rows --lint` output to `.claude/tmp/` and passes the paths.

- lifecycle 0.16.0, delegate 0.11.2 (ultrareview fixes): `gh-tag-release`
  waits up to about 2 minutes for the push-triggered CI run before stopping.
  The branch-divert check always covers `main`, `master`, `develop` and
  `trunk`, plus the `origin/HEAD` default. Read-only Devin reviewer profiles
  drop `exec` and have no shell. `/execute-plan` review findings outside the
  plan's Files go to the user, not to fix Tasks. `relay` `check` names the
  variable that supplied a bad root.

- lifecycle 0.16.0, delegate 0.11.2: agy (Antigravity) re-pin, balanced
  across its quota pools. Gemini 4 Hydrogen replaces Gemini 3.8 Flash.
  `execute` and `mid` implement are `gemini-4-hydrogen-high`, then
  `gemini-4-argon-medium` (Generic pool first, Argon on overflow; subagents
  use `Model: "inherit"`, which runs the session model, so a row matches
  only when the session is on that model). New `mid` review list:
  `gemini-4-argon-medium`, then `gemini-4-hydrogen-high` (same `inherit`
  rule, so the reviewer is the session model; logs `same-family mid
  review`). `low` is
  `gemini-4-hydrogen-medium` (`Model: "flash_lite"`, which resolves to
  `gemini-3.5-flash-lite`). `top-plan` and
  `top-review` inherit when the parent session is top, else stop.
  `top-critique` stays `gemini-4-argon-high`. The agy tools no longer expire
  (tool-level `until` removed).

- lifecycle 0.16.0, delegate 0.11.2: Devin model re-pin (2026-11-13). Devin
  `top-plan` is plain `claude-opus-5-5-high` (no Fusion, so planning
  exploration stays on the lead). Devin `top-review` is
  `fusion-claude-opus-5-5-medium-sidekick-swe-2-medium`, provisional until a
  Fusion-vs-plain-Opus review test. Devin `top-critique` gains a
  `gpt-6-1-terra-high` fallback. Devin `execute` `swe-2-high` no longer
  expires. Devin `mid` implement is `swe-2-high`, then `swe-2-medium`, then
  `gpt-6-1-terra-high` (review stays `gpt-6-1-sol-high`, then
  `gemini-4-argon-medium`). Devin `low` is `swe-2-medium`, then
  `claude-haiku-5-5-high`. The review runner and `execute-via-devin` resolve
  pins through `tiers.sh` instead of listing slugs.

- lifecycle 0.16.0: `/critique plan` reviews in a separate read-only Task at
  the host's `top-critique` pin (else `top-review`). The drafting session only
  applies edits and stamps. New `execute-plan/hosts.md` names the subagent
  mechanism per host: Claude Code Task model alias, Cursor Task slug, Devin
  `run_subagent` profile `kit-<role>`, and agy `invoke_subagent` `Model` alias
  (`inherit` or `flash_lite`). Any other host, or a model that cannot
  be pinned, stops the run. Devin custom subagent profiles
  (`host-profiles/devin/kit-{execute,mid,low,review-mid,review-top,critique}.md`)
  are generated from `tiers.json` by the sync script. Read-only reviewer
  profiles have no edit or write tools.

- lifecycle 0.16.0: `/execute-plan` final review and escalation diff against
  `merge-base origin/<default> HEAD`, so multi-run plans are reviewed whole.
  Step 5 deferral rules are one decision table. Run files under
  `.claude/tmp/exec-claude-*` are deleted after the run. The coverage target
  applies to files the plan changes. `/conduct` never stages `.claude/tmp/**`.
  Gate B and `/make-plan` show a plan summary plus the path, not the full
  plan. `/make-plan` suggests `pin subagent`, allows delegate runners only on
  a Claude Code host, and requires a CHANGELOG step when the repo has
  `CHANGELOG.md`. `git-preflight.sh version` prints `manifest_file=`.
  `/gh-tag-release` waits for the CI run on HEAD and stages that manifest.
  `/gh-draft-release` restores the branch and stash on every stop. Skills name
  the host's question tool (`AskQuestion`, `AskUserQuestion` or
  `ask_user_question`).

- delegate 0.11.2: `execute-via-cursor` and `execute-via-agy` no longer
  hardcode model chains. They resolve pins with `tiers.sh resolve`.
  `/delegate:review` and the branch-divert check resolve the default branch
  from `origin/HEAD`, then `main`, then `master`. The branch-divert check
  also always covers `main`, `master`, `develop` and `trunk`.

- relay 0.6.0 (breaking): the legacy remote root (`RELAY_LEGACY_ROOT`) is
  removed, with its folder move, straggler adoption, absent and empty-root
  gates, and `superseded` lock. `relay_resolve_remote` prints three fields
  (`backend<TAB>root<TAB>status`). Before upgrading, run 0.5.x
  `/relay:pickup` to migrate any handoffs still under the legacy root: they
  become invisible afterwards and no tool can recover them. If you still set
  `RELAY_LEGACY_ROOT`, remove it; it is ignored. `RELAY_DROPBOX_ROOT`, the `docs/handoffs`
  repo-path migration and the `.claude/handoff/active.md` import are
  unchanged.

- lifecycle 0.16.0, delegate 0.11.2, relay 0.6.0 (follow-ups): aligned agy
  `invoke_subagent` alias guidance across `tiers.json`, `hosts.md`, and
  `brief-template.md` to probe-verified `inherit` (session tier) and
  `flash_lite` (`low`), removing `else "pro"` and `"pro"`/`"flash"` claims.
  Expanded `relay` `env-snippet.sh` to cover the full snippet (resolver
  cases and `check` root masking) and removed remaining legacy folder-move
  wording in `relay`/`pickup` references. Updated `delegate` `model-tiers.md`
  to refer to the `lifecycle` plugin's `skills/execute-plan/hosts.md` as text
  instead of a broken relative link. Clarified `execute-plan` Step 5
  `/delegate:review` print count (one per skipped row, else at most one),
  restored the `, ineffective cache` review criterion, added the `critique`
  `top-plan` session warning note, and added the `LIFECYCLE.md` host-guard
  bullet.

## 2026-11-12

- README gains a Models & configuration section (tier roles, user
  `tiers.json` override, advisor note).

- delegate 0.11.1, lifecycle 0.15.1: `tiers.sh` gains `authenv <tool>`
  (the merged `authEnv` names) and `runner-tool <runner>` (the tool whose
  `reviewRunners` lists the runner; exit 3 when none does). The review
  launcher now looks a runner's tool up in the registry instead of a fixed
  table, so an override that adds a runner gets that tool's `authEnv`, and
  an unlisted runner is refused rather than launched with no `authEnv`. Both
  launchers source one `env -i` allowlist (`scripts/lib-clean-env.sh`) and
  read `authEnv` through `tiers.sh`, so the shipped-plus-override merge lives
  in one place. `tiers.sh` no longer needs `HOME` or `date` outside
  `resolve`. lifecycle carries the updated `tiers.sh` copy.

## 2026-11-11

- lifecycle 0.15.0, delegate 0.11.0, relay 0.5.0: model tiers re-pinned ahead of the
  2026-11-26 and 2026-11-30 expiries. Devin `execute` falls back to
  `swe-2-medium` after `swe-2-high`. Devin and Cursor `mid` split implement
  and review passes; review uses a second model family (Devin
  `gpt-6-1-sol-high`; Cursor `claude-sonnet-5-5-high`). Devin `mid`
  implement falls back to `swe-2-flash-medium` after `swe-2-high`, so its
  reviewer stays a second family. Devin gets a `top-critique` row
  (`gpt-6-1-sol-high`). When Devin is active and not the host,
  `top-review` falls back to `top@devin-fusion` and logs the fallback. The
  delegate `model-tiers.md` copy carries the same change. Publishing now
  creates a `<plugin>-v<version>` tag for each plugin version (for example
  `lifecycle-v0.15.0`) and never moves an existing tag. Tools, the default host
  and tier pins are now data. A registry (`tiers.json`) with a resolver
  (`tiers.sh`: `tools`, `host`, `order`, `delegates`, `runners`, `resolve`,
  `validate`) replaces the tool lists in prose and scripts; an optional
  `~/.config/nng-kit/tiers.json` (or `NNG_KIT_TIERS`) is deep-merged over it.
  `model-tiers.md` per-tool rows, review runners and per-tool summary blocks
  are generated from the registry; the cross-tool master chains are gone and
  the compact skill copies no longer carry a summary block. `plan-status.sh`
  reads runner, review, backend and skill names from the registry and
  refuses when it is missing. New review runner `top@claude-headless`
  (Claude Code in print mode, plan permission mode, read-only tools) gives a
  Cursor or Devin host a Claude review. Skill preconditions and the default
  final-review runner are host-neutral. `vendor-skills.sh --neutral` vendors
  neutral example tiers instead of the owner's pins. Delegate and review
  launches run under an `env -i` allowlist (base names, the registry's
  per-tool `authEnv`, and `DELEGATE_ENV_ALLOW`); `--print` shows names only.
  The headless Claude reviewer starts with no MCP servers; `DELEGATE_MCP=1`
  opts back in. The delegate README adds a threat model. `/execute-plan` may run
  on a `mid` orchestrator when the map is v2 and `plan-status.sh rows --lint`
  passes, and `/conduct` skips the closing pass when Phase A was skipped and
  Stage 4's final review was a clean `top@*`. The relay SessionStart hook fires
  on startup and clear only and injects at most `RELAY_INJECT_LINES` (default
  20) body lines.
- lifecycle 0.13.0: lock, map selection, and status writes go through
  `plan-status.sh` (`rows claude-code`, `rows --lint`, `stamp`, `recent`,
  `approve`, `lock --gate`, `batch --skipped`, `terminal --deferred-review`).
  `/execute-plan` runs Verification through `delegate-verify.sh`. Review
  tasks receive a base ref and produce the diff themselves. `/gh-create-pr`
  inventories plans and relay files with `pr-artifacts.sh` (read-only; it
  never runs `git rm`). `/commit` and the release skills read branch,
  version, bump, and fingerprint facts from `git-preflight.sh`.
  `sync-kit-scripts.sh` copies `plan-status.sh` and `delegate-verify.sh`
  from delegate into the lifecycle skill. The five lifecycle
  `model-tiers.md` copies are a compact generated excerpt (Fallback,
  per-tool resolution, review runners, and the summary); edit the canonical
  file and run `sync-model-tiers.sh`. `skill-budget.sh` checks each skill's
  own bytes and its closure (the skill file plus the `.md` files it links
  directly) against `scripts/nng-kit-skill-budgets.tsv`.
- lifecycle 0.13.0: `/conduct` Gate B Approve writes `gate_b_sha` via
  `plan-status.sh approve`, then offers a fresh session. That session
  starts at Stage 4 only when `lock --gate` matches. A mismatch, a missing
  stamp, or a legacy plan still requires Gate B. Stage 5 skips its lean
  review rounds only when this session's execute fingerprint is unchanged
  and `head` equals the review base. The closing top pass and the security
  pass still run.
- lifecycle 0.13.0: three budget targets are the achieved size, because
  meeting the original number would drop a rule. `execute-plan` own 18864
  (was 14000) and closure 60991 (was 58500), blocked by the wave schedule
  and single Dispatch-line rule, the in-host top@session paragraph, the
  summary checklist, and the closure's linked references. `gh-create-pr`
  own 12014 (was 9500), blocked by the Keep/Drop questions, the printed
  git rm, `/relay:discard`, and `/commit` commands, the stop rules, and
  Safety.
- delegate 0.9.0: `plan-status.sh` gains the lifecycle commands above.
  Delegate-backend `rows` selection is unchanged. `delegate-verify.sh`
  remains the verification runner. The delegate `model-tiers.md` copy
  stays the full canonical file.

## 2026-11-09

- lifecycle 0.12.2: Cursor plugin manifests (`.cursor-plugin/`) so the
  plugin can be imported as a Cursor team marketplace and used in Cursor
  Cloud Agents.
- relay 0.4.1: Cursor plugin manifest plus a Cursor-format `sessionStart`
  hook (`hooks/cursor-hooks.json`) for Cursor installs; Cursor Cloud
  Agents don't run plugin hooks, so use `/relay:pickup` there.
- lifecycle 0.12.1: `/conduct` now downgrades to no-commit when the Stage 5
  review base (fetch or merge-base) cannot be resolved, and stops without
  pushing or opening a PR when there is nothing to commit, unless a reused
  branch with approved existing commits still has work to ship.
- lifecycle 0.12.0: new `/lifecycle:conduct` skill — drives brainstorm →
  make-plan → critique plan → execute-plan → full critique change, then
  branch/commit/push or a PR per an up-front finish mode; hands-off after
  plan approval and downgrades to no-commit on any dirty review or failed
  verification.
- delegate 0.8.0: a deterministic verify script
  (`delegate-verify.sh`) replaces the low-tier LLM verifier for
  execution and `/delegate:review` Verification — exit codes 0/1/3/2
  distinguish pass, command failure, tree mutation and usage error;
  `runs:` records now store token usage (`tokens_in`, `tokens_cached`,
  `tokens_out`) collected by `delegate-usage.sh` from Cursor,
  Antigravity and Devin run outputs.
- lifecycle 0.11.0: small-plan fast lane — plans the planner records
  `Plan size: small` skip the per-wave review lines and the mid-tier
  review passes (final top-tier pass unchanged); the `runs:` schema
  gains the token fields above.
- delegate 0.7.1: `execute-via-core.md` trimmed by about a quarter
  (37.5 KB → 27 KB) — model default and fallback fields are stated once
  (one table the status audit and verdict steps refer to); external
  review-runner steps (Devin Fusion, Cursor ask, Antigravity plan) moved
  to `references/review-runner.md`, read only for those reviews and by
  `/delegate:review`. Wording only; no behavior change.
- delegate 0.7.0: review runners — each delegated batch is reviewed at its
  strongest map Review (`mid`, read-only Opus Task, host, or an external
  read-only reviewer: Devin Fusion `--permission-mode auto`, Cursor
  `--mode=ask`, Antigravity `--mode plan`); new `delegate-review-launch.sh`
  (git guard that reverts any reviewer edit, scope check, launch, verdict
  trailer → PASS/FIX/FAIL); a PASS also needs the verifier and scope check
  clean; reviewer failure stops and asks; new `/delegate:review` for the
  final whole-branch review; `plan-status.sh review`; review brief template;
  Devin Fusion allowed only as a reviewer; contract tests cover review flags.
- lifecycle 0.10.0: `/execute-plan` honors external `top@*` reviews
  (in-host when the host is that tool, otherwise defers to
  `/delegate:review`); `/critique change` skips lean rounds and the closing
  pass after a converged delegate PASS (security pass still runs);
  `model-tiers.md` documents review runners; drafting rules generate the
  final-review Dispatch line; execution status gains `last_skill: review`.
- lifecycle 0.9.0: `/make-plan` asks for (or accepts `runner=`) a **Runner
  policy** and records it under Assumptions; drafting rules map `auto`, `pin`,
  `order`, and `round-robin` to Execution-map runners, and plan updates can
  re-route rows that are not `done`. Cursor `mid` in `model-tiers.md` pins
  `grok-4.7-high` with logged `auto` fallback (drops stale no-mid-pin wording).
- delegate 0.6.0: `plan-status` allows Cursor `mid` rows; `execute-via-cursor`
  resolves the mid pin and no longer refuses mid-tier dispatch; README matches
  the new routing.

## 2026-11-08

- delegate 0.5.0: map-routed execute-via-* (scripts for launch, verdict, and
  status); skills shrink to bindings; Antigravity runs without `AGY_ENABLED`;
  on Cursor, all-low `Model: auto` maps to `auto(router)`; contract and CI
  always run Antigravity.
- lifecycle 0.8.1: execution-status documents `auto(router)` and script writer
  notes; drafting-rules forbid `mid` rows on `delegate:cursor` (Cursor has no
  mid pin) and say to escape a literal `|` in map cells as `\|`; model-tiers
  uses parked wording (no `AGY_ENABLED` gate).
- lifecycle 0.8.0: `model-tiers.md` splits top tier by role (`top-plan`,
  `top-review`, optional `top-critique`), makes `execute` a map tier, documents
  the grunt-work rule and per-tool pins (Cursor Grok/Composer, Devin SWE-2
  first, Antigravity Gemini-only for execute/mid/low). Antigravity rows are
  active until 2026-11-26. Planning skills and `LIFECYCLE.md` use the new role
  names; Devin delegate docs match Cursor/Antigravity pinned-only execute
  behaviour.
- delegate 0.4.1: synced `references/model-tiers.md` matches the lifecycle 0.8.0
  tier chains and Antigravity metadata.
- lifecycle 0.7.0: execution-map v2 routing columns (tier, runner, files,
  acceptance, review); `/make-plan` adds a `## Dispatch` section; approved plans
  lock the body with `plan_sha`; brainstorm and plan files use `YYYY-MM-DD`
  naming; batched `AskQuestion` during planning; `/execute-plan` refuses a
  plan whose body changed after approval, accepts step-scope IDs, keeps each
  step to its listed files, and leaves delegate steps to their Dispatch lines.
- lifecycle 0.6.1: the marketplace listing now reports the same version as the
  plugin itself, and `LIFECYCLE.md` documents installing the plugin on Devin,
  Cursor and Antigravity alongside Claude Code.
- relay 0.4.0: skills are tool-neutral across Claude Code, Devin, Cursor and
  agy. The SessionStart hook resolves the project directory on each tool and
  emits Cursor's native context output; `RELAY_*` values fall back to
  `~/.config/relay/env` when unset; without the Dropbox MCP, remote access is
  read-only via `dbxcli` (claims and writes need Claude Code). Each skill also
  carries its own copy of the `format.md` and `storage.md` references, so
  links keep resolving when a skill folder is copied or linked elsewhere.

## 2026-11-06

- exec-observe 0.5.0: the run pane says what is running and lets you act on it.
  A **task** row shows the plan and step scope from the run's brief; **now**
  says `⚙ <tool> <file>`, `✎ writing a reply`, `… thinking` or `waiting for the
  model`, and how long the stream has been quiet before the 90 s stall; **says**
  shows the latest agent message. Counters hide zero kinds and show failures in
  red; the meaningless activity strip is replaced by events and time since the
  last event. Buttons gain hotkeys (`v` Full/Compact, `f` Show filter
  all/msgs/tools/errors, `c` copy session id, `r` copy resume command, `e`
  stderr), and Full view wraps rows. Fixes Cursor messages being shown twice
  (streamed deltas plus the final message) and spaced punctuation (`7 , 8 .`).
  Visuals: the RUNNING badge spins while the run is running and the elapsed time
  ticks live; timeline tags are colored by kind (read blue, search cyan, edit
  green, shell pink, task purple, errors red); a sparkline shows events per
  poll; a quiet gauge fills toward the stall and turns amber past half.
  Elapsed time comes from the run itself (Cursor event timestamps, else the
  `.err` file's creation) and stops at `.exit`, so it no longer resets when a
  session starts; a dead run found at session start shows as stalled at once.
  Text from the stream is stripped of control characters before it is drawn,
  and `r` offers a resume command only for a plain session id.
- lifecycle 0.6.0: skills can be vendored into consumer repos (Devin Cloud
  workspaces, other machines) via `plugins/lifecycle/scripts/vendor-skills.sh`.
  It copies `plugins/lifecycle/skills/*` from a `lifecycle-v*` tag into
  `<repo>/.agents/skills/` and stamps `.nng-kit-version`; `--check` fails on any
  drift from the stamped tag. The `plugins/lifecycle/ci/vendor-check` composite
  action runs the check in consumer-repo CI
  (`nigelng/nng-kit/plugins/lifecycle/ci/vendor-check@lifecycle-vX.Y.Z`).

## 2026-11-05

- lifecycle 0.5.0: plan execution status gains per-run records. Each finished
  `/execute-plan` or `delegate` run appends a `runs:` entry to the plan's
  `execution:` frontmatter (backend, requested and resolved model, effort,
  start/end, review findings, FIX loops, fallback, outcome) and a matching
  `Run:` line in its `### Run` stanza. A model the CLI does not report is
  recorded as `auto(unresolved)`.
- delegate 0.4.0: `execute-via-cursor`, `execute-via-agy` and
  `execute-via-devin` read the model each CLI actually reports and write it to
  the run record verbatim.
- exec-observe 0.4.0: the pane shows Devin runs. Devin does not stream, so the
  pane shows the run as running until it exits, then reads the conversation
  export and shows the summary.
- delegate 0.3.0: `/delegate:execute-via-devin` hands implementation to the Devin CLI with an exact pinned model (never Adaptive or Fusion). Headless runs use print mode and a conversation export; a resolved model that differs from the requested slug fails the run. Repository contents go to Cognition. The skill deletes Devin's run files (which can hold secrets) once the verdict is final, and the README now warns that headless runs auto-approve every tool and, for Devin, skip the workspace-trust check.
- lifecycle 0.4.0: `model-tiers.md` adds per-row `status: active|parked` and
  `until: YYYY-MM-DD` metadata plus a new `execute` tier (per-backend delegate
  default pin). Cursor sets `execute` to `grok-4.7-high` → `auto` (logged
  fallback only), `low` to `claude-haiku-5-5-high` → `composer-2.5`, and `mid`
  to none (escalates to `claude-code`). Devin pins `top` (`gpt-6-astra-medium`),
  `execute` (`swe-2-high` until 2026-11-30 → `gpt-6-1-terra-high`), `mid`
  (`gpt-6-1-sol-high` → `gemini-4-argon-medium` until 2026-12-01), and `low`
  (`gpt-6-1-terra-high`), with guidance for standalone Fusion/Adaptive tasks.
  Antigravity (`agy`) rows are marked `status: parked (agy-ai-pro)` unless
  `AGY_ENABLED=1`. Resolver rules skip expired `until:` rows (logging
  `fallback: expired <slug>`) and forbid unlogged router (`auto`, `adaptive`)
  runs in review loops.
- delegate 0.2.0: when `model=` is omitted, `/delegate:execute-via-cursor` and
  `/delegate:execute-via-agy` now resolve the backend's `execute` pin from
  `model-tiers.md` and always pass `--model <slug>`; platform Auto is used only
  as a logged fallback. `delegate` now ships its own synced copy of
  `model-tiers.md` under `plugins/delegate/references/model-tiers.md`.
  `/delegate:execute-via-agy` stops unless `AGY_ENABLED=1`, reports "agy is parked; set AGY_ENABLED=1 to re-enable", and writes nothing.
- lifecycle 0.3.1: the `/make-plan` template's Rollback section now asks
  steps that force-push, rewrite history or delete remote refs to check
  repository rulesets (`gh api repos/<owner>/<repo>/rulesets`) as well as
  classic branch protection. Rulesets can block force-pushes or require signed
  commits even when branch protection returns 404.
- delegate 0.1.3: contract tests under `plugins/delegate/tests/` (help-fixture
  flag inventory, stub NDJSON predicates, skill predicate-string guard).
  README documents Long runs (`safe` / `no-force` in tmux as the interim) and
  the local smoke / version-check scripts. Source-of-truth wording no longer
  names the private repo.

## 2026-11-04

- relay 0.3.0: storage is configured with **`RELAY_BACKEND`** (`dropbox` or
  `onedrive`, when supported) and **`RELAY_ROOT`**; optional **`RELAY_LEGACY_ROOT`**
  for read/list on a previous remote root (no claims there). **`RELAY_DROPBOX_ROOT`**
  remains a deprecated alias. New **`references/storage.md`** documents abstract
  remote operations and per-backend mapping; skills and **`format.md`** use
  backend-neutral “remote” wording. Repo handoffs live under **`docs/relay/`**;
  **`docs/handoffs/`** is still read for pickup, check, SessionStart, and orphan
  scan. **`/relay:save`** writes only the new path and can offer a local
  **`git mv`** migration first; **`/relay:pickup`** can migrate all legacy repo
  files and offers guarded remote folder migration plus straggler adoption.
  OneDrive is documented but not implemented (repo-only until an adapter lands).
  A tab or newline in a root env value resolves to `invalid-root` (repo-only).
- lifecycle 0.3.0: **`docs/plans/**`** may be committed when the repo tracks that
  path; **`/commit`** stages plan files only when they are not gitignored and
  belong to the change. **`/gh-create-pr`** adds a **planning-artifacts gate**:
  changed plans get Keep/Drop; changed **`docs/relay/**`** (and legacy
  **`docs/handoffs/**`**) get Keep/Discard via **`/relay:discard`**; another
  branch's relay file can be dropped only when it has no remote twin. Dropped
  plans get a PR-body permalink before removal. **`LIFECYCLE.md`** and
  **`/make-plan`** note that plans are committable and the gate decides what
  ships.

## 2026-11-03

- lifecycle 0.2.0: canonical **model-tiers** policy (`top` / `mid` / `low`
  per-tool chains) lives in `plugins/lifecycle/model-tiers.md`; skill copies
  stay in sync via `bash scripts/sync-model-tiers.sh` (`--check` in CI).
  `/brainstorm`, `/make-plan` and `/critique plan` run as top-tier sessions;
  `/critique change` runs up to two lean mid-tier rounds plus at most two
  top-tier passes per run (escalate + closing pass); `/execute-plan` uses
  mid-tier review passes with one top-tier final pass (plus at most one
  escalation), and `haiku` map rows fall back to `mid` when capped.
  Behaviour-changing `/execute-plan` steps follow `test & implement → lint →
  verify` (justified skip + validate checks for docs/config). Includes token
  trims, changelog and git-safety tightening across the skill chain, portable
  byte-identity checks for vendored references, and optional rule summary-block
  sync when marker comments are present.
- delegate 0.1.2: `/delegate:execute-via-cursor` and
  `/delegate:execute-via-agy` default to the backend's Auto model when `model=`
  is omitted, and the vendored **execution-status** reference stays byte-synced
  with `lifecycle` (enforced by the portable drift guard).

## 2026-11-02

- Sync commits now list the plugins and versions they change, plus the new
  lines from this changelog, instead of a bare snapshot note.
- delegate 0.1.0 (new plugin): `/delegate:execute-via-cursor` (Cursor `agent`)
  and `/delegate:execute-via-agy` (Google Antigravity `agy`). Both skills
  share one core reference and one brief template. Claude Code gates the run,
  reviews the diff and drives the PASS / FIX / FAIL loop. Install the CLI for
  the backend you use.
- exec-observe 0.3.0 replaces the retired observe plugin. **Breaking:**
  uninstall `evc-observe@nng-kit` and install `exec-observe@nng-kit`
  (`claude plugin uninstall evc-observe@nng-kit`, then
  `claude plugin install exec-observe@nng-kit`). Run files are renamed from
  `evc-run-<n>.{ndjson,err,exit}` to
  `exec-run-<backend>-<n>.{ndjson,err,exit}`. The `/exec` command replaces
  `/evc`. The header shows a backend badge for Cursor and Antigravity runs.
- lifecycle 0.1.1: `execution-status.md`, `LIFECYCLE.md` and `plan-template.md`
  now point to `/delegate:execute-via-cursor` and `/delegate:execute-via-agy`.
  `execute-via-cursor` moved from local-only into the published `delegate`
  plugin.

## 2026-11-01

- relay 0.2.0: one-time import of a legacy `.claude/handoff/active.md`;
  `/relay:check` reports handoff files whose branch is gone and
  `/relay:pickup` offers to clean them up on the default branch. Supersedes
  the older `handoff` plugin.
- Snapshots of this repo are now GitHub-signed commits (shown as Verified).

## Earlier

- Initial releases of `lifecycle`, `evc-observe` and `relay`.
