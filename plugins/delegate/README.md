# delegate

Delegate fleet plan implementation to a headless coding CLI while Claude Code
stays in charge of the gates. Three execute skills share one flow:

- `/delegate:execute-via-cursor` runs the plan with Cursor's headless CLI
  (`agent`).
- `/delegate:execute-via-agy` runs the plan with Google's Antigravity CLI
  (`agy`).
- `/delegate:execute-via-devin` runs the plan with the Devin CLI (`devin`).

In each, the backend implements the plan on a branch. Claude Code runs the
preflight gates, reviews the resulting diff, and drives the PASS / FIX / FAIL
verdict loop.

`/delegate:review` is the fourth skill: the plan's final whole-branch
top-tier review through its Review runner. It is read-only — it never
implements, fixes, or commits.

## Prerequisites

Install and sign in to the CLI for the backend you use. Each skill needs only
its own CLI.

### `/delegate:execute-via-cursor`

- Cursor CLI (`agent`), installed and signed in.

### `/delegate:execute-via-agy`

- Google Antigravity CLI (`agy`):

  ```bash
  brew install --cask antigravity-cli
  ```

- One-time interactive sign-in: run `agy` in a terminal and complete the
  Google account login (stored in the keyring). This is not automated.
- Recommended when managed via Homebrew: set
  `AGY_CLI_DISABLE_AUTO_UPDATE=true`, so Homebrew stays the only updater.

### `/delegate:execute-via-devin`

- Devin CLI (`devin`), installed and signed in (`devin auth status` reports
  logged in). Install with `brew install --cask devin-cli`, then
  `devin auth login`.
- The plan must be runnable on the pinned models. The skill passes an exact
  effort slug from `model-tiers.md` (never Adaptive or Fusion).

## Platform

These skills are Claude Code only. They are not exposed to Cursor, Devin, or
Windsurf by the installer; Cursor's "Include Third-Party Plugins" import can
still list them from the Claude Code plugin set, so each skill runs a host gate
(`$CLAUDECODE` must be `1`) as its first preflight step and refuses outside
Claude Code.

## Scripts

Committed under `plugins/delegate/scripts/` (mode `100644`, run with `bash`):

| Script | Role |
| --- | --- |
| `plan-status.sh` | Plan lock (`lock`, `lock --gate`), Execution-map selection (`rows`, `rows --lint`), status writes (`start`, `batch` including `--skipped`, `terminal` including `--deferred-review`, `review`), plus `stamp`, `recent`, and `approve` |
| `delegate-launch.sh` | Build and run the backend CLI (headless background, or `--interactive` / `--print`) |
| `delegate-verdict.sh` | Classify one run's logs (`ok`, model, session id) |
| `delegate-review-launch.sh` | Review git guard (`snapshot`/`check`), `scope` check, external read-only reviewer `run`, and `verdict` (review trailer → JSON) |
| `delegate-verify.sh` | Run Verification commands from the repo root → `PASS` / `FAIL` / `FAIL (tree changed)` |
| `delegate-usage.sh` | Sum token usage over a run's launch files (feeds `terminal --usage`) |

Skills invoke them as `bash <skill-dir>/../../scripts/<name>.sh` (see
[execute-via-core.md](references/execute-via-core.md)).
`bash scripts/sync-kit-scripts.sh` copies `plan-status.sh`,
`delegate-verify.sh`, `tiers.sh` and `tiers.json` into
`lifecycle/skills/execute-plan/scripts/` (mode 0644) so a host that installs
lifecycle without delegate still runs them. `references/model-tiers.md` here
is a full copy of the lifecycle canonical file. The five lifecycle skill
copies are compact (a generated header, then Fallback, Per-tool resolution,
tool notes, and Review runners). Regenerate with
`bash scripts/sync-model-tiers.sh`.

**Row routing (`plan-status.sh rows`):** On a v2 Execution map, only rows whose
`Runner` is `delegate:<backend>` for the active skill (`delegate:cursor`,
`delegate:agy`, or `delegate:devin`) are selected; legacy plans without a map
fall back to Implementation-step selection. **Refuse:** a **top** row on
`delegate:*`, or a top ID you named in step-scope (`top rows never run on a
delegate`). **Skip** (exit 0): an unscoped top row whose runner is `session` or
`subagent`, with a note like `out of step-scope (top row: run in session)`.
Also refuses rows routed to a foreign runner (when step-scope names that ID).
`launch_tier` is the strongest tier among the
selected rows (`low` < `execute` < `mid`). Launch model comes from
`model-tiers.md` for that tier unless the JSON has `router: true` (every
selected row is `Model: auto` on Cursor `delegate:cursor`) → pass `--model auto`
and record `auto(router)`.

**Lifecycle commands on the same script.** `rows <plan> claude-code` selects
`session` and `subagent` rows, including `top`; `delegate:*` rows are skips
(`out of step-scope (dispatch via delegate)`). A selected row blocked on an
unfinished delegate row is reported as `blocked`, not refused, and an empty
selection still exits 0. `rows --lint <plan>` validates every scheduled row
and does not refuse for dependencies or an empty selection. `batch --skipped
ID --note TEXT` records a skip. `terminal --deferred-review` forces status
`partial` even on `--outcome pass`. `stamp` writes `plan_sha` and
`approved_at` (never `created_at`). `recent <dir>` prints the newest plan,
ignoring `*.notes.md` (exit 3 on a tie). `approve` writes `gate_b_sha` and
`gate_b_at` after a passing lock; only `/conduct` calls it, at Gate B.
`lock --gate` prints `gate_b_at` only when that stamp still equals both the
frontmatter and the computed `plan_sha`. A mismatch, a missing stamp, or a
legacy plan (no `plan_sha`) exits 3, and `/conduct` still requires Gate B.

## Tool registry

Which tools exist, which is the default host, the tier pins and the review
runners are data, not prose. The canonical registry is `scripts/tiers.json`,
resolved by `scripts/tiers.sh`:

- `tiers.sh tools` — enabled tool ids; `host` — the default host; `order` —
  planning order; `delegates` — ids with `delegate: true` (enabled or not);
  `runners` — review runners as `top@<name>` (never `top@session`).
- `tiers.sh resolve <tool> <tier> [--role implement|review]` — first usable
  pin. Exit 0 ok, 2 usage or malformed, 3 no usable pin or a disabled tool.
  `execute` and `low` with no usable pin fall through to `mid` (logged
  `fallback: <tier>→mid`). `KIT_TODAY` overrides the date.
- `tiers.sh authenv <tool>` — the tool's merged `authEnv` names, one per
  line; `runner-tool <runner>` — the tool whose `reviewRunners` lists the
  runner (first in planning order when several do; exit 3 when none does).
- `tiers.sh validate` — schema check.

Each tool entry carries `label`, `enabled`, an optional tool-level `until`,
`cli`, `delegate`, `authEnv`, `defaultReviewRunner`, `reviewRunners`
(`<name>: {tier, mode}`) and `tiers` with all six keys (`top-plan`,
`top-review`, `top-critique`, `execute`, `mid`, `low`; an empty list when
none). Rows are `{model, until?, role?, note?}`.

An optional user file —
`${NNG_KIT_TIERS:-${XDG_CONFIG_HOME:-$HOME/.config}/nng-kit/tiers.json}` —
is deep-merged over the shipped registry (objects merge, arrays replace). It
is partial: set only what you change. Generated docs ignore it.

`bash scripts/sync-kit-scripts.sh` copies `tiers.json` and `tiers.sh` into
`lifecycle/skills/execute-plan/scripts/`; skills call
`bash <skill-dir>/../execute-plan/scripts/tiers.sh`.
`bash scripts/sync-model-tiers.sh` renders `model-tiers.md`'s per-tool rows,
the review-runner list and the per-tool summary blocks from `tiers.json`,
and writes `home/claude/rules/tiers-summary-<tool>.md` (each tool's rules
list only its own pins) plus `model-tiers.neutral.md`; `--check` fails on
drift. `plan-status.sh` reads delegate ids, review values, backends and
`execute-via-<id>` skill names from the registry (the literals `session`,
`subagent`, `top@session`, `mid`, `none` and backend `claude-code` stay); a
missing registry is `REFUSE:` exit 3. `vendor-skills.sh --neutral` vendors
`model-tiers.neutral.md` and `tiers.example.json` in place of the owner's
pins and stamps `tiers=neutral`; `--check` honours the stamp.

**Default host.** The top-level `host` key picks the default tool; a
one-line override `{"host":"cursor"}` (or `"devin"`) in the user file
switches it. On the Cursor and Devin hosts the default review runner is
`top@claude-headless` — Claude Code in print mode (`claude -p` with
`--permission-mode plan`, read-only tools and `--strict-mcp-config`), under
the same git guard and verdict contract as the other external runners.
Limitation: the `/delegate:*` skills still run only inside Claude Code —
they refuse unless `CLAUDECODE=1`. Another host can use the registry, the
resolver and the review runner, but it hands `delegate:*` rows to Claude
Code or runs them itself.

### Adding a tool

1. Add the tool's entry to `tiers.json` — all six tier keys plus `cli`,
   `delegate`, `authEnv`, `reviewRunners` and `defaultReviewRunner` — then
   run `bash scripts/tiers.sh validate`, `bash scripts/sync-kit-scripts.sh`
   and `bash scripts/sync-model-tiers.sh`.
2. Add the launcher arm in `scripts/delegate-launch.sh` (argv for the new
   CLI), its flags in the `*_FLAGS` list of `tests/contract.sh`, and
   `tests/fixtures/<cli>-help.txt`.
3. Add the review-runner arm in `scripts/delegate-review-launch.sh` and a
   row in `references/review-runner.md`.
4. Add a thin `skills/execute-via-<id>/SKILL.md` over
   `references/execute-via-core.md`.
5. Add the CLI version entry in `config/delegate-cli-versions.json` and
   `tests/fixtures/<cli>-version.txt` (read by `scripts/check-delegate-cli.sh`).

## Review runners

Each delegated batch is reviewed at the strongest `Review` value among its
selected rows (`none` < `mid` < `top@*`; rows in one batch share one
`top@*`). The reviewer is read-only: it reviews a brief that already
contains the host verifier summary and the `scope` JSON, and it never runs
Verification itself (the host verify script does). Reviewers:

- `top@session` — this Claude Code session (the host) reviews the brief.
- `top@claude-task` — a read-only `Task(model: "opus")` subagent.
- `top@claude-headless` — Claude Code in print mode (`claude -p` with
  `--permission-mode plan`, read-only tools and `--strict-mcp-config`);
  same git guard and verdict contract as the other external runners.
- `top@devin-fusion` — Devin Fusion, `devin --model <fusion pin>
  --permission-mode auto --respect-workspace-trust=false --print=…`.
- `top@cursor-ask` — Cursor `agent -p --mode=ask`.
- `top@agy-plan` — Antigravity `agy --mode plan`.
- `mid` — a read-only `Task(model: "sonnet")`.
- `none` — no review; clean only when the verify script says PASS and the scope
  check found nothing.

External runners are preflighted (`which`, and the exact model pin from
`model-tiers.md` listed by the CLI's `models` command where the CLI has
one) and launched in the background through `delegate-review-launch.sh run`;
the host waits for the completion notification, then reads `verdict`. Before
the review the host snapshots the worktree (`snapshot`); after it, `check`
reverts any reviewer edit byte-exact (added files removed, index restored)
and reports a moved HEAD without resetting it — any change fails the
review. Gitignored paths are not covered by the guard. The review must end
with the `FINDINGS:`/`VERDICT:` trailer; `verdict` maps it to PASS / FIX /
FAIL, and a PASS also requires the verifier summary PASS and an empty
`outside` + `protected` scope — host evidence overrides a reviewer PASS.
Reviewer failure (`ok: false`) stops and asks; it is never reported as
PASS.

`/delegate:review <plan> [ID] [base=<ref>] [runner=top@…]` runs the final
whole-branch review at the plan's Review runner (review ids `final-<k>`).
With an ID it marks that final `top` row done on PASS (failed otherwise) via
`plan-status.sh review` — a log stanza only, no `runs:` entry.

## Companion plugin: exec-observe

`exec-observe` is optional. It renders a live side pane for a delegated run:
status, counters, the current tool, and the timeline. It reads the run files
below and never feeds them into model context. Without it, the skills still
run and report normally. Cursor and Antigravity runs stream live; a Devin run
shows its summary when the run ends.

## Run records

Every finished run (PASS, FAIL or abort) appends one `runs:` entry to the plan's
`execution:` frontmatter and a matching `Run:` line in its `### Run` stanza:
backend, the requested model, the model the CLI actually reported (verbatim,
or `auto(unresolved)` when it reports none), effort, start and end, token
usage (`tokens_in`/`tokens_cached`/`tokens_out`, `null` when unknown), review
findings, FIX loops, and the fallback reason if a non-pinned model ran. Field
definitions live in [execution-status.md](references/execution-status.md).
Compare models across plans by counting findings per run in these records.

## Run-file contract

All run files live under the repo's `.claude/tmp/` directory. `<backend>` is
`cursor`, `agy`, or `devin`; review files use `<rid>` (`<backend>-<k>` for
batch reviews, `final-<k>` for `/delegate:review`).

| File | Purpose |
| --- | --- |
| `.claude/tmp/exec-<backend>-brief.md` | Brief handed to the backend |
| `.claude/tmp/exec-<backend>-fix-<n>.md` | Fix brief for verdict-loop round `<n>` |
| `.claude/tmp/exec-<backend>-questions.md` | Questions the backend raised for Claude |
| `.claude/tmp/exec-<backend>-rows.json` | Selected map rows from `plan-status.sh rows` (written in Step 4) |
| `.claude/tmp/exec-<backend>-verify.txt` | Verification commands for `delegate-verify.sh` |
| `.claude/tmp/exec-<backend>-verify.out` | Verify script output (the verifier summary) |
| `.claude/tmp/exec-run-<backend>-<n>.ndjson` | Run event stream (stdout) for `cursor` and `agy` |
| `.claude/tmp/exec-run-devin-<n>.json` | Devin conversation export |
| `.claude/tmp/exec-run-devin-<n>.out` | Devin stdout |
| `.claude/tmp/exec-run-<backend>-<n>.err` | Run stderr |
| `.claude/tmp/exec-run-<backend>-<n>.exit` | Run exit code |
| `.claude/tmp/exec-review-<rid>-brief.md` | Review brief (verifier summary + scope JSON + diff) |
| `.claude/tmp/exec-review-<rid>.md` | Reviewer output (must end with the `FINDINGS:`/`VERDICT:` trailer) |
| `.claude/tmp/exec-review-<rid>.err` | Reviewer stderr |
| `.claude/tmp/exec-review-<rid>.exit` | Reviewer exit code |
| `.claude/tmp/exec-review-<rid>.snap` | Guard snapshot taken before the review |
| `.claude/tmp/exec-review-<rid>.guard.json` | Guard result from `check` (`clean`, `head_moved`, `reverted`, `removed`) |
| `.claude/tmp/exec-review-final-verify.txt` / `.out` | Verification commands and verify script output for `/delegate:review` |

## Data egress and trust

Running a backend sends repository contents and the `.claude/tmp` brief to that
vendor: Cursor for `execute-via-cursor`, Google for `execute-via-agy`, or
Cognition for `execute-via-devin`, under your active sign-in. Briefs quote only
plan text and file paths. They never include secrets or `.env` contents. Review
the plan and the repo before you delegate it.

An external review runner (`top@devin-fusion`, `top@cursor-ask`,
`top@agy-plan`) receives the same kind of payload — the plan text and the
diff — from the same vendor as that backend's execution.

**Headless runs are unattended.** The default (non-`safe`) path auto-approves
every tool the backend calls: Cursor `--force --trust`, Antigravity
`--dangerously-skip-permissions`, Devin `--permission-mode dangerous`. Devin also
gets `--respect-workspace-trust=false`, which skips its workspace-trust check, so
repo-local Devin config and anything the plan or repository tells the agent to
run executes without a prompt. Delegate headless only on repositories you trust;
otherwise use `safe` / `no-force`, which never runs the CLI for you.

Devin's export (`exec-run-devin-<n>.json`) is the whole conversation, including
tool output, so it and the `.out` / `.err` files can contain secrets the agent
read. `execute-via-devin` deletes them once the verdict is final (PASS, FAIL or
abort).

## Threat model

Read [Data egress and trust](#data-egress-and-trust) first. This section
covers what a delegate can reach and what the kit does and does not limit.
It reduces exposure; it is not a sandbox.

**What a delegate can reach.** Headless runs use the permission-bypass flags
above, so a backend (and any review runner) can use:

- the working tree;
- a shell with your permissions;
- files under `$HOME`, including credential files such as `~/.config/gh`
  and `~/.aws`, and CLI logins held in the macOS keychain;
- the network.

**What the environment allowlist removes.** `delegate-launch.sh` and
`delegate-review-launch.sh` start the CLI under `env -i` plus an allowlist
that both source from `scripts/lib-clean-env.sh`, so secrets carried in environment variables (cloud keys, `GH_TOKEN` and the
like) are not inherited by the CLI and its tools. The `--interactive` line
printed for `safe` / `no-force`, and agy's preflight probe, run in your own
shell with your full environment; the allowlist applies to headless runs
only. The allowlist is:

- the base list: `HOME`, `PATH`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`,
  `LC_ALL`, `LC_CTYPE`, `TMPDIR`, the four `XDG_*` dirs (config, data, state,
  cache), `NIX_PATH`, `NIX_PROFILES`, `NIX_SSL_CERT_FILE`, `SSL_CERT_FILE`,
  `__CF_USER_TEXT_ENCODING`, `AGY_CLI_DISABLE_AUTO_UPDATE` (a non-secret
  updater switch that keeps Homebrew as agy's sole updater), and the proxy
  and CA names (`HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `ALL_PROXY` in upper
  and lower case, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`,
  `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`), needed behind a proxy or a
  TLS-inspecting CA; their values can embed proxy credentials, so `--print`
  never shows them;
- the tool's registry `authEnv` (`CURSOR_API_KEY` for Cursor; empty for
  agy, Devin and Claude Code; a review runner's tool is the one whose
  `reviewRunners` lists it), read through `tiers.sh authenv` and merged with your `tiers.json` override
  (`$NNG_KIT_TIERS`, else `${XDG_CONFIG_HOME:-~/.config}/nng-kit/tiers.json`);
- any names in `DELEGATE_ENV_ALLOW`.

Only names that are set in your shell are passed. `--print` shows names
only (`NAME=<set>`), never values, so run logs cannot leak a token. Cursor,
agy, Devin and the headless Claude reviewer all authenticated under this
list from `$HOME` state or the keychain, with no extra variable.

**What the no-MCP profile removes.** Only the headless Claude review runner
(`top@claude-headless`) starts with no MCP servers
(`--strict-mcp-config` and no `--mcp-config`). The others cannot disable MCP
per run and inherit the MCP servers you have configured:

- Cursor (`agent`; execute and `cursor-ask`): `~/.cursor/mcp.json` and the
  project's `.cursor/mcp.json`, for servers you have approved.
- Devin (execute and `devin-fusion`): `~/.config/devin/mcp_config.json`, the
  project's `.devin/mcp_config*.json`, marketplace plugins and other tools'
  configs. A temporary `--config` does not hide them.
- agy (execute and `agy-plan`): no launch flag exists; `agy mcp disable` is
  persistent, not per run. No servers are configured on the maintainer's
  machine today.

**What neither protects.**

- Credential files under `$HOME` and keychain-backed logins.
- The permission-bypass flags listed under
  [Data egress and trust](#data-egress-and-trust). The review runners are
  read-only by mode, not by sandbox: Cursor `--mode=ask` still passes
  `--trust`, agy runs `--mode plan`, Devin Fusion runs
  `--permission-mode auto` with workspace trust off, and the Claude reviewer
  keeps a `Bash` tool in plan mode.
- Network access.
- Environment variables of your other processes. Same-user processes can
  read each other's environment (`ps -E`), so the allowlist stops
  inheritance, not a delegate that goes looking. The launcher, `timeout`,
  `caffeinate`, your Claude Code session and your shells still hold the full
  environment. The same applies to the SSH agent socket (`SSH_AUTH_SOCK`)
  and keys under `~/.ssh`.

Worktree or sandbox isolation is the real fix. It is out of scope here.

**The review git guard, and its limit.** `delegate-review-launch.sh
snapshot` records HEAD, the index and a tree of tracked and untracked files
(excluding `.claude/tmp`). After the review, `check` reverts reviewer edits
byte-exact (changed files restored, added files removed, index restored)
and reports a moved HEAD without resetting it. Any change to HEAD, the
index or the work tree fails the review. It compares only those (HEAD and
branch name, the index tree and the work-tree tree). It cannot see or undo
`.git/` contents other than HEAD and the index (hooks, config, other refs,
tags, stash), `.claude/tmp`, gitignored paths, files outside the repo,
network calls and other side effects. A planted git hook or shell rc edit
runs later with your full environment.

**Third-party pins and their gap.** The filesystem MCP server is pinned
(`@modelcontextprotocol/server-filesystem@2.1.0`) and archify is pinned
(`skills@1.8.1` at a fixed commit of `tt-a1i/archify`). These pins are
top-level only: npm transitive dependencies are not locked. The `dbxcli` and
`llm-wiki` plugin marketplaces are not pinned. Claude Code passes a
marketplace `ref` to `git clone --branch`, which rejects a commit SHA, so
they track upstream until someone pins them by tag. That is your decision;
tags can move.

**Opt-outs and escape hatches.**

- `DELEGATE_ENV_ALLOW=NAME1,NAME2` adds variables to the allowlist. Names
  are validated (`[A-Za-z_][A-Za-z0-9_]*`, comma-separated); a bad name is a usage
  error. If you sign in to Claude with `ANTHROPIC_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN` rather than the keychain, add it here or the
  headless review will not authenticate.
- An `authEnv` entry in your `tiers.json` override also widens the
  allowlist for that tool. Entries are validated the same way.
- `DELEGATE_MCP=1` re-enables MCP on the headless Claude reviewer only. It
  has no effect on Cursor, agy or Devin.

## Long runs

Long or unattended runs default to Claude Code background sessions:

- `claude --bg -n <name> "<prompt>"` starts one and returns immediately (`/bg` does the same inside a session); it keeps running under the background daemon.
- `claude agents` lists live sessions; `claude attach <id>` reopens one, `claude logs <id>` prints recent output, `claude stop <id>` stops one (the conversation is kept).
- Where `ccstop` is installed, it stops every background session and then the daemon — the safe "stop them all" after a runaway or finished wave. `ccstop --dry-run` prints each action first.
- Never run `/loop` or other self-rescheduling commands inside a background session; they keep a paid worker alive indefinitely.
- tmux stays the fallback for CLIs that must outlive the Claude install or when the daemon misbehaves: `safe` / `no-force` prints the command; run it inside a user-started tmux session.

Spend caps are manual: before a long delegate wave, check the Cursor on-demand limit and the Devin extra-usage cap in their dashboards/settings.

## Parallel runs

Runs are sequential: one `impl/*` branch in the main checkout, one set of
`.claude/tmp` files per backend. Running in parallel across separate repos
needs nothing extra. Worktree support is decided later, when two delegated
plans must run in the same repo at once.

## Tests and smoke

From plugin root (`nng-kit/plugins/delegate/`):

- `bash tests/contract.sh`
- `bash tests/test-plan-status.sh`, `bash tests/test-delegate-launch.sh`,
  `bash tests/test-delegate-verdict.sh`, `bash tests/test-delegate-verify.sh`,
  `bash tests/test-delegate-usage.sh`,
  `bash tests/test-delegate-review-launch.sh` (or `bash tests/test-*.sh`)

From repo root, prefix paths with `nng-kit/plugins/delegate/` (e.g.
`bash nng-kit/plugins/delegate/tests/contract.sh` and the same for the
`test-*.sh` suites).

`contract.sh` checks flags that `delegate-launch.sh` emits via `--print` and
`--interactive` against `AGENT_FLAGS` / `AGY_FLAGS` / `DEVIN_FLAGS` and the
committed help fixtures; runs `delegate-verdict.sh` on PATH-shim stub logs;
asserts remaining Devin skill strings; then runs the `test-*.sh` suites.
Antigravity (`agy`) cases always run (no feature gate, no optional skip).

Maintainers also run a live version/flag check and an authenticated smoke outside
this repo.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install delegate@nng-kit
```
