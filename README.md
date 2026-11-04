# nng-kit

A Claude Code plugin marketplace with the `lifecycle` skill chain, the
`delegate` skills that hand a plan to a headless coding CLI, the
`exec-observe` pane that watches those runs, and `relay` cross-surface
handoff. The lifecycle skill directories also work in Cursor, Devin and
Windsurf as plain `SKILL.md` skills.

Source of truth is the `nng-kit/` folder of
the private source repo. This repo is
snapshot-synced from that folder by CI on each merge, so open changes there,
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

Optional, local only (needs the Cursor `agent` CLI and/or the Antigravity
`agy` CLI, see [Prerequisites](#prerequisites-for-delegate)):

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

`delegate` needs only the CLI for the backend you use. Both are optional.

- **Cursor** (`/delegate:execute-via-cursor`): the Cursor CLI `agent`,
  installed and signed in.
- **Antigravity** (`/delegate:execute-via-agy`): the Google Antigravity CLI
  `agy`. Install it with `brew install --cask antigravity-cli`, then run `agy`
  once in a terminal to sign in with your Google account (manual, not
  automated). Optionally set `AGY_CLI_DISABLE_AUTO_UPDATE=true` so Homebrew
  stays the only updater.

Both skills are Claude Code only. `exec-observe` is optional: without it, the
delegated runs still work and report normally.

### Optional remote root for `relay`

Code-side remote mirroring uses `$RELAY_BACKEND` and `$RELAY_ROOT` from the
environment (set in the host `settings.json` `env` block). `$RELAY_DROPBOX_ROOT`
remains a deprecated alias for `$RELAY_ROOT` on Dropbox. If no root is set,
`relay` is repo-only (`docs/relay/<branch-slug>.md`, with legacy
`docs/handoffs/` still readable). Spaces are listed at runtime in
`<root>/README.md` (`## Spaces`). See [plugins/relay/README.md](plugins/relay/README.md).

## Install (Cursor, Devin, Windsurf)

Symlink each `plugins/lifecycle/skills/<name>/` directory into
`~/.agents/skills/<name>/` and into the tool's skills directory
(`~/.cursor/skills`, `~/.config/devin/skills`, `~/.codeium/windsurf/skills`).
Invoke as `/<name>`.

## Plugins

| Plugin | Version | What it is |
| --- | --- | --- |
| `lifecycle` | 0.3.0 | Idea → shipped skill chain. See [LIFECYCLE.md](plugins/lifecycle/LIFECYCLE.md). |
| `delegate` | 0.1.2 | Hands plan implementation to the Cursor (`agent`) or Antigravity (`agy`) CLI while Claude Code gates and reviews. See [README](plugins/delegate/README.md). |
| `exec-observe` | 0.3.0 | Pane + status line for `/exec` runs of `delegate` (Cursor and Antigravity badges). Replaces the retired observe plugin. See [README](plugins/exec-observe/README.md). |
| `relay` | 0.3.0 | Cross-surface handoff (save / pickup / check / discard + SessionStart). See [README](plugins/relay/README.md). |

### `lifecycle` skills

| Skill | Does | Writes to | Commits/pushes? |
| --- | --- | --- | --- |
| `brainstorm` | Goal brief, explore feasibility, roadmap + `/make-plan` handoff | `docs/brainstorms/**` | Never |
| `make-plan` | Structured plan with an Execution map | `docs/plans/**` | Never |
| `critique` | Lean independent review of a plan or a change, plus a security pass | Plan file or working tree | Never |
| `execute-plan` | Runs the plan's waves through subagents, mid-tier review passes plus a top-tier final pass | Working tree + plan audit metadata | Never |
| `commit` | Conventional Commit (optional version/CHANGELOG bump) after approval | Local git history | Commits only |
| `gh-create-pr` | Branch, push, open PR via `gh`, watch CI | Remote branch + PR | After approval |
| `gh-draft-release` | Draft GitHub Release with notes | Draft release | After approval |
| `gh-tag-release` | Date the changelog and push a release tag | Tag + publish CI | After approval |

## Portability rules

- `SKILL.md` files use only relative links to sibling files (one level deep,
  or `../<skill>/<file>` inside `plugins/lifecycle/skills/`).
- No `${CLAUDE_PLUGIN_ROOT}` or other plugin-only syntax in any `SKILL.md`.
