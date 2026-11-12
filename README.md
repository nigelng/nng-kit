# nng-kit

A Claude Code plugin marketplace with the `lifecycle` skill chain, the
`delegate` skills that hand a plan to a headless coding CLI, the
`exec-observe` pane that watches those runs, and `relay` cross-surface
handoff. The lifecycle skill directories also work in Cursor, Devin and
Windsurf as plain `SKILL.md` skills.

Source of truth is the `nng-kit/` folder of the private source repo. This repo
is snapshot-synced from that folder by CI on each merge, so open changes there,
not here. Notable changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Install (Claude Code)

```bash
claude plugin marketplace add nigelng/nng-kit
```

```bash
claude plugin install lifecycle@nng-kit
```

```bash
claude plugin install relay@nng-kit
```

Optional, local only (needs the Cursor `agent` CLI, the Antigravity `agy`
CLI, and/or the Devin CLI, see [Prerequisites](#prerequisites-for-delegate)):

```bash
claude plugin install delegate@nng-kit
```

Optional, local only (live pane for `delegate` runs, `/exec`):

```bash
claude plugin install exec-observe@nng-kit
```

Per-repo alternative, in `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "nng-kit": { "source": { "source": "github", "repo": "nigelng/nng-kit" } }
  },
  "enabledPlugins": {
    "lifecycle@nng-kit": true,
    "relay@nng-kit": true
  }
}
```

Plugin skills are namespaced: `/lifecycle:make-plan`, `/relay:save`,
`/delegate:execute-via-cursor`, …

### Prerequisites for `delegate`

`delegate` needs only the CLI for the backend you use. Each is optional.

- **Cursor** (`/delegate:execute-via-cursor`): the Cursor CLI `agent`,
  installed and signed in.
- **Antigravity** (`/delegate:execute-via-agy`): the Google Antigravity CLI
  `agy`. Install it with `brew install --cask antigravity-cli`, then run `agy`
  once in a terminal to sign in with your Google account (manual, not
  automated). Optionally set `AGY_CLI_DISABLE_AUTO_UPDATE=true` so Homebrew
  stays the only updater.
- **Devin** (`/delegate:execute-via-devin`): the Devin CLI `devin`, signed in,
  and a plan that can run the pinned models. Install it with
  `brew install --cask devin-cli`, then run `devin auth login`.

These skills are Claude Code only. `exec-observe` is optional: without it, the
delegated runs still work and report normally.

### Optional remote root for `relay`

Code-side remote mirroring uses `$RELAY_BACKEND` and `$RELAY_ROOT` from the
environment (set in the host `settings.json` `env` block). `$RELAY_DROPBOX_ROOT`
remains a deprecated alias for `$RELAY_ROOT` on Dropbox. If no root is set,
`relay` is repo-only (`docs/relay/<branch-slug>.md`, with legacy
`docs/handoffs/` still readable). Spaces are listed at runtime in
`<root>/README.md` (`## Spaces`). See [plugins/relay/README.md](plugins/relay/README.md).

## Install (Devin)

In <https://app.devin.ai> → **Customize → Plugins**, add these as personal
plugins:

```text
nigelng/nng-kit#plugins/lifecycle
nigelng/nng-kit#plugins/relay
```

They load in cloud sessions and on every machine you sign in to. Run this
on a signed-in machine to pull the account plugins:

```bash
devin plugins update
```

For a machine-only install, use a local plugin directory instead:

```bash
devin plugins install --local <dir>
```

Recommendation: use the web app for cloud + multi-machine delivery;
`--local` is for one machine only.

## Install (Cursor)

For Teams/Enterprise, an admin imports this repo (or a fork) under
**Dashboard → Plugins & MCPs → Team Marketplaces → Add Marketplace → Import
from Repo**, pasting the full URL `https://github.com/nigelng/nng-kit` (or
the fork's). The `.cursor-plugin/marketplace.json` lists lifecycle and relay.
A fork gives the team change control; direct import tracks this repo's
public `main`.

Cloud Agents install marketplace plugins at start and keep those versions
for the run. Plugin hooks don't run in Cloud Agents, so invoke
`/relay:pickup` manually. Local installs of the Cursor plugin use relay's
`hooks/cursor-hooks.json` (`sessionStart`).

On a personal plan, in the Cursor app open **Customize → From GitHub
Repository** and paste the full URL `https://github.com/nigelng/nng-kit`
(`nigelng/nng-kit` alone fails with `{invalid_argument} Error`). Open the
marketplace and **Install** `lifecycle` and `relay`; your Cloud Agents then
have the plugins.

Per-repo alternative on every plan: from a checkout of this repo, vendor
lifecycle skills from an existing published tag. Replace `X.Y.Z` and `<repo>`:

```bash
bash plugins/lifecycle/scripts/vendor-skills.sh --tag lifecycle-vX.Y.Z <repo>
```

Commit `<repo>/.agents/skills/`, including its `.nng-kit-version` stamp.
This installs lifecycle only, with plain `/<name>` commands, not namespaced
plugin commands. Use the
`nigelng/nng-kit/plugins/lifecycle/ci/vendor-check@lifecycle-vX.Y.Z` action in
consumer CI to catch drift from the stamped tag.

Recommendation: the personal import covers your own Cloud Agents, the team
marketplace covers a team, and vendoring covers repos used by others or
automations.

## Install (Windsurf / plain skills)

Symlink each `plugins/lifecycle/skills/<name>/` directory into
`~/.agents/skills/<name>/` and into the tool's skills directory
(`~/.cursor/skills`, `~/.config/devin/skills`, `~/.codeium/windsurf/skills`).
Invoke as `/<name>`.

## Plugins

| Plugin | Version | What it is |
| --- | --- | --- |
| `lifecycle` | 0.15.1 | Idea → shipped skill chain. See [LIFECYCLE.md](plugins/lifecycle/LIFECYCLE.md). |
| `delegate` | 0.11.1 | Hands plan implementation to the Cursor (`agent`), Antigravity (`agy`), or Devin (`devin`) CLI while Claude Code gates and reviews. See [README](plugins/delegate/README.md). |
| `exec-observe` | 0.5.0 | Pane + status line for `/exec` runs of `delegate` (Cursor, Antigravity and Devin badges). Replaces the retired observe plugin. See [README](plugins/exec-observe/README.md). |
| `relay` | 0.5.0 | Cross-surface handoff (save / pickup / check / discard + SessionStart). See [README](plugins/relay/README.md). |

### `lifecycle` skills

| Skill | Does | Writes to | Commits/pushes? |
| --- | --- | --- | --- |
| `conduct` | Runs brainstorm, make-plan, critique plan, execute-plan and full critique change with two human gates, then finishes per up-front mode. After Gate B, a fresh session starts at execute-plan only when `gate_b_sha` still matches the plan | Brainstorms, plans, working tree; git branch/commit/push/PR per finish mode | Per up-front finish mode (`push`, `pr`, `none`); never to default branch |
| `brainstorm` | Goal brief, explore feasibility, roadmap + `/make-plan` handoff | `docs/brainstorms/**` | Never |
| `make-plan` | Structured plan with an Execution map | `docs/plans/**` | Never |
| `critique` | Lean independent review of a plan or a change, plus a security pass | Plan file or working tree | Never |
| `execute-plan` | Runs the plan's waves through subagents, mid-tier review passes plus a top-tier final pass. Lock, map rows, and status writes go through `plan-status.sh`; Verification through `delegate-verify.sh` | Working tree + plan audit metadata | Never |
| `commit` | Conventional Commit (optional version/CHANGELOG bump) after approval | Local git history | Commits only |
| `gh-create-pr` | Branch, push, open PR via `gh`, watch CI | Remote branch + PR | After approval |
| `gh-draft-release` | Draft GitHub Release with notes | Draft release | After approval |
| `gh-tag-release` | Date the changelog and push a release tag | Tag + publish CI | After approval |

Plan lock, map checks, status writes, verification, the PR artifact
inventory, and git preflight are bash scripts the skills call
(`plan-status.sh`, `delegate-verify.sh`, `pr-artifacts.sh`,
`git-preflight.sh`). The first two ship inside the lifecycle `execute-plan`
skill too, so a host that installs lifecycle without delegate still runs
them. Detail is in [LIFECYCLE.md](plugins/lifecycle/LIFECYCLE.md).

Maintainers only (source repo; `scripts/` is not published here):
`scripts/sync-kit-scripts.sh` copies those scripts from `delegate` into
`execute-plan`. `scripts/sync-model-tiers.sh` writes compact tier copies into
the five lifecycle skills that link `model-tiers.md`; the canonical file and
the delegate copy stay full. `scripts/skill-budget.sh` checks each skill's
own bytes and closure bytes against `scripts/nng-kit-skill-budgets.tsv`.

## Models & configuration

Skills pick models by role, not by name:

- `top-plan`: `/brainstorm`, `/make-plan`, `/critique plan` sessions.
- `top-review`: map tier `top`, final and escalate reviews, `/critique`
  closing pass.
- `execute` / `mid` / `low`: implementation rows and intermediate reviews.

Each tool's pins for each role are in
[model-tiers.md](plugins/lifecycle/model-tiers.md), generated from the
registry `plugins/delegate/scripts/tiers.json`.

To change the registry without forking, create
`~/.config/nng-kit/tiers.json` (or point `$NNG_KIT_TIERS` at a file). It is
deep-merged over the shipped registry: objects merge, arrays replace, so set
only what you change. For example, turn Devin off:

```json
{ "tools": { "devin": { "enabled": false } } }
```

A disabled tool drops out of `tiers.sh tools` and resolves to no pin
(`tiers.sh resolve` exits 3). The override also applies
to lifecycle-only installs, since `execute-plan` ships its own `tiers.sh`.
The generated `model-tiers.md` does not reflect it; check with
`tiers.sh resolve <tool> <tier>`.

Advisor: the kit does not configure one. In Claude Code, set `advisorModel`
in `settings.json`; in Cursor, install the Advisor plugin and run
`/advisor <slug>` per project.

## Portability rules

- `SKILL.md` files use only relative links to sibling files (one level deep,
  or `../<skill>/<file>` inside `plugins/lifecycle/skills/`).
- No `${CLAUDE_PLUGIN_ROOT}` or other plugin-only syntax in any `SKILL.md`.
