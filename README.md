# nng-kit

A Claude Code plugin marketplace with the `lifecycle` skill chain and the
`evc-observe` mod. The same skill directories also work in Cursor, Devin and
Windsurf as plain `SKILL.md` skills.

Source of truth is the `nng-kit/` folder of
[nigelng/dotnix-macos](https://github.com/nigelng/dotnix-macos). This repo is
a `git subtree split` of that folder, so open changes there, not here.

## Install (Claude Code)

```bash
claude plugin marketplace add nigelng/nng-kit
```

```bash
claude plugin install lifecycle@nng-kit
```

Optional, local only (needs the Cursor `agent` CLI for the runs it watches):

```bash
claude plugin install evc-observe@nng-kit
```

Per-repo alternative, in `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "nng-kit": { "source": { "source": "github", "repo": "nigelng/nng-kit" } }
  },
  "enabledPlugins": { "lifecycle@nng-kit": true }
}
```

Plugin skills are namespaced: `/lifecycle:make-plan`, `/lifecycle:commit`, …

## Install (Cursor, Devin, Windsurf)

Symlink each `plugins/lifecycle/skills/<name>/` directory into
`~/.agents/skills/<name>/` and into the tool's skills directory
(`~/.cursor/skills`, `~/.config/devin/skills`, `~/.codeium/windsurf/skills`).
Invoke as `/<name>`.

## Plugins

| Plugin | Version | What it is |
| --- | --- | --- |
| `lifecycle` | 0.1.0 | Idea → shipped skill chain. See [LIFECYCLE.md](plugins/lifecycle/LIFECYCLE.md). |
| `evc-observe` | 0.2.0 | Pane + status line for `/execute-via-cursor` runs. See [README](plugins/evc-observe/README.md). |

### `lifecycle` skills

| Skill | Does | Writes to | Commits/pushes? |
| --- | --- | --- | --- |
| `brainstorm` | Goal brief, explore feasibility, roadmap + `/make-plan` handoff | `docs/brainstorms/**` | Never |
| `make-plan` | Structured plan with an Execution map | `docs/plans/**` | Never |
| `critique` | Lean independent review of a plan or a change, plus a security pass | Plan file or working tree | Never |
| `execute-plan` | Runs the plan's waves through subagents, top-tier review until clean | Working tree + plan audit metadata | Never |
| `commit` | Conventional Commit (optional version/CHANGELOG bump) after approval | Local git history | Commits only |
| `gh-create-pr` | Branch, push, open PR via `gh`, watch CI | Remote branch + PR | After approval |
| `gh-draft-release` | Draft GitHub Release with notes | Draft release | After approval |
| `gh-tag-release` | Date the changelog and push a release tag | Tag + publish CI | After approval |

## Portability rules

- `SKILL.md` files use only relative links to sibling files (one level deep,
  or `../<skill>/<file>` inside `plugins/lifecycle/skills/`).
- No `${CLAUDE_PLUGIN_ROOT}` or other plugin-only syntax in any `SKILL.md`.
