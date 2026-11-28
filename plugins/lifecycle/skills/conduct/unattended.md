# Unattended /conduct

Applies to [SKILL.md](SKILL.md) Gate B **Continue unattended** and `/conduct … unattended=yes`. `<skill-dir>` is [SKILL.md](SKILL.md)'s absolute directory; `<scripts>` = `<skill-dir>/scripts`; `<exec>` = `<skill-dir>/../execute-plan/scripts`.

## Eligibility

Shared by Gate B, `launch.sh` (both launchers; exit `4` `INELIGIBLE: <reason>`), and the worker:

- `/conduct <plan> …` with `unattended=yes`, `delegate=print`, `confirm=no`, `plan=keep|drop`, and `finish` in `tiers.sh policy` `.relax.unattendedFinish` (policy exit 2 → strict `["pr"]`).
- Regular repo-relative `<plan>` under `docs/plans/` in the worktree; `plan-status.sh lock --gate <plan>` exits `0`; `rows --lint <plan>` prints `ok`; `rows --runners <plan>` has no `delegate:*` rows (v1 is `delegate=print` only).

## Gate B

Offered after `approve` exits `0`. Pre-check refusal stops with its reason (never fall back to `here`/`fresh`; create no worktree).

0. **Pre-checks:** check `rows --lint` (`ok`) and `rows --runners` (no `delegate:*`). Resolve worker finish from Step 0.5 effective finish and `relax.unattendedFinish` (strict `["pr"]`): if allowed, use it; else if `push` and `pr` is allowed, fall back to `pr` and announce `finish=pr`; else (`none`, `commit`, or disallowed `push` — never escalate `none`/`commit` to `pr`) refuse and stop.
1. **Create worktree:** `bash <scripts>/worktree.sh create <plan>` → stdout `run_id=<id>  worktree=<abs path>  plan=<repo-rel plan>` (non-zero → show stderr, stop). Creates detached `../<repo>-conduct-<run-id>` at `HEAD`, copies `<plan>` + sibling `.notes.md` (0644, `gate_b_sha`, no `handoff_run`), writes `.claude/tmp/conduct-<run-id>.meta.json`, and stamps `handoff_run` on the main-tree plan. On **any stop after `create`** (steps 2–5), tell the user to run `bash <scripts>/worktree.sh remove <run-id>` to release `handoff_run`.
2. **Launcher:** `launcher=` arg; else `bash <exec>/tiers.sh launcher` (`.conduct.launcher // "print"`; non-zero → `print` + reason).
3. **Model:** `bash <exec>/tiers.sh resolve <host> mid` (non-zero → show stderr, stop).
4. **Command:** `/conduct <plan> finish=<worker-finish> delegate=print plan=<keep|drop> confirm=no unattended=yes` (`<plan>` from step 1).
5. **Launch:** `bash <scripts>/launch.sh <launcher> --worktree <worktree> --model <id> --cmd <cmd> --run-id <run_id> [--log-dir <dir>]`
   - Stdout: `print` emits quoted `cd <worktree> && claude --model <id> <cmd>` + `handle=print`; `headless` emits `handle=pid:<n>`.
   - Exit `4` (`INELIGIBLE`): **hard stop** (no `print` retry). Exit `3` (launcher unavailable): retry once with `print` + reason. Other non-zero: show stderr, stop.
   - **`headless`:** reads `tiers.sh headless` (user override only; in-repo ignored): `permissionMode` (`NNG_KIT_HEADLESS_PERMISSION_MODE` > config > `auto`; allowlist `auto|acceptEdits|default`, `bypassPermissions` refused), `timeoutMinutes` (1–1440, default `120`), and `notify`. Needs `${XDG_STATE_HOME:-$HOME/.local/state}/nng-kit/headless-probe.json` matching `claude --version`, `--model`, and permission mode; billed probe (only when asked): `bash <scripts>/launch.sh probe headless --model <id>`. Default log: `<worktree>/.claude/tmp/conduct-<run-id>.log` (`--log-dir` moves `.log` only). Watcher kills the `claude` process group on timeout (TERM, KILL after 10 s; cleans leftovers on normal exit too) and writes `failed` via `status.sh write --if-absent`.
6. **Report and stop:** print `run_id`, `worktree`, `handle`, log path (headless), status path `<worktree>/.claude/tmp/conduct-<run-id>.json`, and `worktree.sh list` / `worktree.sh remove <run-id>`.

## Handoff lock and worktrees

`worktree.sh create` stamps top-level `handoff_run` on the main-tree plan (outside `plan_sha`; absent from the worktree copy). While set, `plan-status.sh lock`, `lock --gate`, and `approve` exit `3` with `REFUSE: plan handed off to unattended run <id>; release with plan-status.sh handoff --clear <plan>`, blocking a second run.

- `bash <scripts>/worktree.sh list`: prints `run_id=… state=<created|running|<status>|unknown> branch=… pr_url=… worktree=…` for each `<repo>-conduct-<run-id>` worktree.
- `bash <scripts>/worktree.sh remove <run-id> [--discard-plan] [--release] [--force]`: refuses (`exit 3`) if state is `running`/`unknown` (`--force` overrides only this), if dirty outside `.claude/tmp/**` (`not-started` plan/notes allowed; `--discard-plan` allows them in any state), or on detached HEAD with commits past base. Clears main-tree `handoff_run` when no commits were left or with `--release`; manual clear: `bash <exec>/plan-status.sh handoff --clear <plan>`.

## Worker contract

- **Start marker:** run `bash <scripts>/status.sh start` first (writes `.claude/tmp/conduct-<run-id>.started`, idempotent, so `print` runs appear in `worktree.sh list`).
- **Policy, eligibility & routing:** re-read `bash <exec>/tiers.sh policy` (exit 2 → log stderr, strict `["pr"]`) and print `policy: <relaxed list|none> (<source>)`. Enforce **Eligibility**; skip [SKILL.md](SKILL.md) `top-plan` warning (worker runs on `mid`). Route only `not-started` passing `lock --gate`, or resume (`in-progress`/`partial`/`failed`) passing `lock` (Stage 4); Stages 1–3, Gate A/B, brainstorms, free text, `completed`, or failed lock → stop.
- **No questions:** never prompt. In Step 0.6, `.claude/tmp/**` is **conductor-owned** (never staged). Require default branch for all modes, `origin` for `push`/`pr`, `gh auth` for `finish=pr` only. `relax.reuseAheadBranch` does **not** apply to workers. Foreign paths, ahead branch, missing remote/auth/default, `execute-plan` Step 3 prompt, or any question/downgrade → stop.
- **Advisor gate:** `advisor` unavailable before commit/push/PR (per host rules) → stop with `--reason "advisor unavailable"`, commit/push nothing.
- **Status (`status.sh write` only; never hand-write JSON):**
  `bash <scripts>/status.sh write --status <pr-opened|pushed|committed|stopped|failed> [--stage <preflight|execute|critique|finish>] [--reason <text>] [--pr-url <url>]`
  Derives `run_id` from worktree basename (`[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+$`; no match → exit `3` `REFUSE: run id not found`), `plan`/`base` from `.meta.json`, `branch`/`commits` from git; writes `<worktree>/.claude/tmp/conduct-<run-id>.json` atomically; fires `.conduct.headless.notify` (user override only, detached argv + status path, never awaited, failure warns only). Validation (exit `2`, no file): `pr-opened` needs `--pr-url` + branch + ≥1 commit; `pushed`/`committed` need branch + ≥1 commit; `--pr-url` only with `pr-opened`; `stopped`/`failed` need `--reason`.
- **Stop:** set `finish=none`, commit/push nothing further, call `status.sh write --status stopped --stage <stage> --reason <why>`, exit.
- **Finish:** detached HEAD → feature branch at Stage 4 for all modes; follow [finish.md](finish.md):

| Mode | Steps | Success (`status.sh write --stage finish …`) | Later-step failure (`status.sh write --stage finish …`) |
| --- | --- | --- | --- |
| `commit` | **Commit** | `--status committed` | `--status stopped --reason <why>` |
| `push` | **Commit**, **Push** | `--status pushed` | `--status stopped --reason "<branch + push error>"` |
| `pr` | **Commit**, **Push**, **PR** (`--draft`; Final summary + `run_id` in body; CI report only) | `--status pr-opened --pr-url <url>` | `--status stopped --reason "<branch + push/PR error>"` |

`status.sh` derives `branch` and `commits` from git (post-commit/post-push `stopped` records them with `pr_url: null`). On every exit, print [finish.md](finish.md#final-summary) **Final summary** with `run_id`, status path, and `worktree.sh remove <run-id>`.
