# Delegate loop for /conduct

Applies at [SKILL.md](SKILL.md) Stage 4 under `/conduct`, on top of [stage-overrides.md](stage-overrides.md#execute-plan) and [../execute-plan/SKILL.md](../execute-plan/SKILL.md). The mode comes from `delegate=` (SKILL.md Step 0.5): `print` (default) or `run`. `<skill-dir>` is the absolute directory of [SKILL.md](SKILL.md).

## print

Hosts other than Claude Code always use `print`.

- If the map contains `delegate:*` rows, or terminal `execution.status` is `partial` after `terminal --deferred-review` (a Step 5/6 deferral with a printed `/delegate:review` line), print the matching **Dispatch** lines (or the fallback commands it specifies). Do not implement delegate rows or silently substitute an in-host review. Apply the conductor's downgrade rule: `finish=none`, stop before commit and report the outstanding dispatch/review work. No `deferred` label.

## run

Claude Code only. Drives `/execute-plan`, checkpoint commits, delegate rows and an external final review in-session, without re-invocation.

### Entry preflight

Runs after Stage 4 entry **Branch** ([finish.md](finish.md#branch)) and before any commit, so the branch-name check below sees the feature branch, not the default.

1. Locate the backend of every unfinished `delegate:*` row: `bash <skill-dir>/scripts/delegate-skill.sh execute-via-<b>` per backend `<b>`. For every unfinished row whose Review is an external `top@*` (any row that could print a `/delegate:review` line), also locate its reviewer: `bash <skill-dir>/scripts/delegate-skill.sh review <tool>`, with `<tool>` from `bash <skill-dir>/../execute-plan/scripts/tiers.sh runner-tool <runner without top@>`. Any non-zero locator exit (3 refuse; 2 usage or tiers error), or a non-zero `runner-tool` exit → `delegate=print`, nothing committed.
2. List untracked, non-ignored paths a checkpoint would exclude (dropped plan, brainstorms, secrets). Any → `print`, with the reason and fixes. `docs/brainstorms/` is normally git-ignored (the kit's brainstorm skill recommends ignoring it), so this fallback rarely fires; ignoring it removes the fallback.
3. Also `print`, with the reason, when:
   - `finish=none`, including a Step 0.6 downgrade;
   - `plan=drop` and the plan is not ignored (tracked or untracked): a rollback would wipe its audit;
   - dirty paths other than the plan and its sibling `.notes.md` at entry (resume after a failed run); the first checkpoint commits both under `plan=keep`;
   - the branch is named `main`, `master`, `develop` or `trunk` (the delegate core diverts there).

### Loop

Repeat until exit. An **iteration** is one `/execute-plan` run plus the delegate and review lines it printed.

1. Run `/execute-plan` with the [overrides](stage-overrides.md#execute-plan). Terminal `completed` → step 3, then exit; except a dirty in-host final review → **Stops** directly (do not run carried external reviews). Only a clean final (or no in-host final this iteration) proceeds to step 3. A stop with a deferred `/delegate:review` line and no Dispatch lines → step 3. A stop with Dispatch lines → step 2.
2. At the stop, record any `/delegate:review` line printed with the Dispatch lines as **carried** (not dropped), once. A delegate-dependency stop, or delegate skips with Dispatch lines, with a clean interim review (or nothing implemented) → **Checkpoint**. Then, for each unfinished `/delegate:execute-via-<b> <plan> <IDs>` Dispatch line, in order:
   1. `bash <skill-dir>/scripts/delegate-skill.sh execute-via-<b>` prints the absolute path of its `SKILL.md`. Non-zero exit → **Stops**.
   2. `Read` it and follow it in-session with `<plan> <IDs>`. Its `<skill-dir>` is that file's directory. Its PASS step "offer `/commit`" is replaced by returning to this loop. Below the host's top-review pin, read a batch's `top@session` as `top@claude-task`.
   3. After PASS → **Checkpoint**, then read `execution.status` from the plan frontmatter. `completed` → step 3 (carried/deferred reviews), then exit. Otherwise continue with the next Dispatch line, and re-enter at 1 only after all of this stop's Dispatch lines are done (not after the first line).
3. Reviews: the deferred `/delegate:review …` line printed by the last iteration (including an `/execute-plan` stop with that line and no Dispatch lines) and each carried line. Dedupe: identical lines run once; a later line supersedes a carried one only for the same ID, or when both are ID-less with the same runner. Run each once, in order. For each:
   1. `<tool>` = `bash <skill-dir>/../execute-plan/scripts/tiers.sh runner-tool <runner without top@>`. Non-zero exit → **Stops**.
   2. `bash <skill-dir>/scripts/delegate-skill.sh review <tool>` prints the absolute path of its `SKILL.md`. `Read` it and follow it in-session with the printed args. Non-zero exit → **Stops**.
   3. PASS → continue. After the last one, read `execution.status`: `completed` → exit; `partial` with the count of `done` rows raised (e.g. a mid-plan `session` row with Files `—` whose external review later rows depend on) → re-enter at 1; anything else → **Stops**. Review FIX/FAIL verdict or unresolved `ok:false` → **Stops**.
4. Any other stop (failed wave, dirty review, abort) → **Stops**.

### Guards

- Each iteration must raise the count of `done` rows in `## Execution log`. Do not use `steps_done`: it counts skips. The guard does not apply to the final review-only step (step 3 after `completed`, or after a stop with only a deferred review).
- After the last review PASS, `execution.status` must be `completed`, unless it is `partial` and the `done` count rose, leaving unfinished rows to re-enter for (step 3.3). A PASS that leaves `partial` without raising the count stops. A carried review may run while status is already `completed` (step 2.3 → 3); it never runs while Dispatch lines remain unfinished and status is not `completed`.
- Otherwise stop (**Stops**).

### Checkpoint

A local commit that gives a delegate FAIL rollback (`reset --hard` to HEAD at launch) a point to reset to.

1. **Preconditions.** Only after a passing stop or a delegate PASS, and only with eligible changes. Never after a failed wave or dirty review; no empty commit.
2. **Branch.** Re-run `bash <skill-dir>/../commit/scripts/git-preflight.sh state`. `branch=` equals the Step 0.6 default → stop.
3. **Stage.** Use only [finish.md](finish.md#commit) **Commit**'s staging and exclusion rules (the staging-set paragraph and its exclusion bullets: foreign paths, `docs/brainstorms/**`, secrets, `.claude/tmp/**`, plans per `plan=`; path-specific adds; staged-path check). Its downgrade preamble, Stage-6-only scope, message/approval steps and push continuation do not apply to checkpoints; this section's Preconditions, Branch, Message and Failure steps govern instead. Nothing implemented → stage plan files only.
4. **Message.** `<type>: checkpoint <IDs> of <plan-slug>`: `<type>` per finish.md **Branch**, `<IDs>` = rows completed since the last checkpoint, `<plan-slug>` = plan basename without `.md` and date prefix. At most 72 characters: if `<type>: checkpoint <IDs> of <plan-slug>` is longer, replace `<IDs>` with `<N> rows`; if still over, shorten the slug. No trailers. `confirm=yes` → ask each time.
5. **Failure.** Hook rejection or a declined confirmation → stop. No retry, amend or `--no-verify`.
6. **Residue probe.** `git status --short -- . ':!.claude/tmp'`. Anything beyond the plan's frontmatter and `## Execution log` diff → stop; list the paths and fixes (`plan=keep`, ignore, stash, `delegate=print`).

### In-session

Delegate `allowed-tools` do not apply here, so expect permission prompts. Keep Claude Code open. Delegate human prompts (questions file, re-execute, reviewer failure) stay.

### Consent text

SKILL.md Step 0.5 summarizes this for `delegate=run`; state each effect:

- Backends run headless with dangerous-permission flags and no sandbox beyond what the backend provides.
- Repository contents go to the backend vendor (Cursor, Google or Cognition); see the delegate plugin README, section Data egress and trust.
- Local checkpoint commits land before Stage 5 critique and the security pass. Push and PR stay gated by `finish=`.
- `plan=drop` with a non-ignored plan falls back to `print`.

`delegate=run` given as an argument counts as consent, but the effects are still stated once.

### Stops

Downgrade ([SKILL.md](SKILL.md) Downgrade rule) on any of:

- delegate FAIL after the fix budget;
- reviewer `ok:false` not resolved by retry or `top@claude-task`;
- a failed subagent wave;
- a dirty interim or final review;
- user abort;
- a carried or deferred review that does not PASS;
- a non-zero `runner-tool` exit;
- an unanswered questions file;
- a hook-rejected or declined checkpoint;
- checkpoint residue;
- a guard;
- a non-zero locator exit (3: print the remaining Dispatch lines; 2: show stderr).

The summary lists `git log --oneline <Step 0.6 HEAD>..HEAD`; never imply checkpoint commits were undone.

### Fingerprint

Record `bash <skill-dir>/../commit/scripts/git-preflight.sh fingerprint` in chat only when the exit is `completed`, the last final review (in-host, or `/delegate:review` PASS) ran after the last delegate PASS, and every carried review PASSed. Otherwise record nothing and note that Stage 5 runs Phase A and the full closing pass. After a checkpoint, Stage 5 Phase A always runs; do not relax this.
