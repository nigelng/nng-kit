# Install nng-kit

Per-surface installation instructions for the `nng-kit` marketplace plugins (`lifecycle`, `relay`, `delegate`, and `exec-observe`).

## Claude Code

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install lifecycle@nng-kit
claude plugin install relay@nng-kit
```

Optional, local only:

```bash
# Headless CLI delegation (Cursor agent, Antigravity agy, Devin CLI)
claude plugin install delegate@nng-kit

# Live /exec side pane and /exec history for delegate runs
claude plugin install exec-observe@nng-kit
```

Per-repo alternative (also required for Claude Code Cloud sessions), in `.claude/settings.json`:

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

Plugin skills are namespaced: `/lifecycle:conduct`, `/lifecycle:make-plan`, `/relay:save`, `/delegate:execute-via-cursor`, …

- **`delegate` prerequisites** (Claude Code only): install and sign in to only the CLI(s) you use — Cursor `agent`, Antigravity `agy`, and/or Devin `devin` — and disable any unused tool in `~/.config/nng-kit/tiers.json`. See [plugins/delegate/README.md](../delegate/README.md#prerequisites).
- **`exec-observe`** (Claude Code only): optional; without it, delegated runs still work and report normally. See [plugins/exec-observe/README.md](../exec-observe/README.md).
- **`relay` remote root** (optional): configure `$RELAY_BACKEND` and `$RELAY_ROOT` in your host `settings.json` `env` block (or `~/.config/relay/env`). Without a remote root, `relay` is repo-only (`docs/relay/<branch-slug>.md`). See [plugins/relay/README.md](../relay/README.md).

## Devin

In <https://app.devin.ai> → **Customize → Plugins**, add these as personal plugins:

```text
nigelng/nng-kit#plugins/lifecycle
nigelng/nng-kit#plugins/relay
```

They load in cloud sessions and on every machine you sign in to. Pull account plugins on a signed-in machine with:

```bash
devin plugins update
```

For a single-machine local install instead:

```bash
devin plugins install --local <nng-kit>/plugins/lifecycle
devin plugins install --local <nng-kit>/plugins/relay
```

Recommendation: use the web app for cloud + multi-machine delivery; `--local` is machine-only.

### Devin subagent profiles (`kit-*`)

Devin subagents spawned by `/execute-plan` and `/critique` use the six `kit-*` profiles under `plugins/lifecycle/host-profiles/devin/`. Copy or symlink them into `~/.config/devin/agents/`:

```bash
mkdir -p ~/.config/devin/agents
ln -sf <nng-kit>/plugins/lifecycle/host-profiles/devin/kit-*.md ~/.config/devin/agents/
```

A missing profile stops `/execute-plan` and `/critique change`. The exception is `/critique plan`: without `kit-critique` or `kit-review-top`, it reviews in-session and warns once.

The profiles carry the shipped model pins and do not read `~/.config/nng-kit/tiers.json` overrides at runtime. Maintainers regenerate them with `scripts/sync-model-tiers.sh` and reinstall. If you do not use Devin on a host, disable `devin` across the kit ([Enable or disable a tool](../../README.md#enable-or-disable-a-tool)).

## Cursor

The repo ships `.cursor-plugin/marketplace.json` listing `lifecycle` and `relay`.

- **Personal plan:** in the Cursor app open **Customize → From GitHub Repository** and paste the full URL `https://github.com/nigelng/nng-kit` (`nigelng/nng-kit` alone fails with `{invalid_argument} Error`). Open the marketplace and **Install** `lifecycle` and `relay`; your Cloud Agents inherit them.
- **Teams / Enterprise:** an admin imports `https://github.com/nigelng/nng-kit` (or a fork for team change control) under **Dashboard → Plugins & MCPs → Team Marketplaces → Add Marketplace → Import from Repo**.
- **Third-Party Imports (local):** Cursor can also import plugins installed in Claude Code when Third-Party Imports is enabled in settings.

Cloud Agents install marketplace plugins at start and do not run plugin hooks, so invoke `/relay:pickup` manually there. Local Cursor plugin installs run `relay`'s `hooks/cursor-hooks.json` (`sessionStart`) on new chats.

### Per-repo vendoring (Cursor, Devin Cloud, or CI repos)

On any plan, vendor `lifecycle` skills directly into a consumer repo from a published `lifecycle-vX.Y.Z` tag:

```bash
bash plugins/lifecycle/scripts/vendor-skills.sh --tag lifecycle-vX.Y.Z <repo>
```

Pass `--neutral` to vendor `model-tiers.neutral.md` and `tiers.example.json` instead of the owner's model pins. Commit `<repo>/.agents/skills/` including `.nng-kit-version`. Vendored skills invoke as plain `/<name>` (not namespaced). Gate drift in consumer CI with:

```yaml
- uses: nigelng/nng-kit/plugins/lifecycle/ci/vendor-check@lifecycle-vX.Y.Z
```

Recommendation: personal import covers your own Cloud Agents, team marketplace covers a team, and vendoring covers repos shared with others or automations. If you do not use Cursor on a host, disable `cursor` ([Enable or disable a tool](../../README.md#enable-or-disable-a-tool)).

## Antigravity (`agy`)

Install `lifecycle` (and optionally `relay`) from a local checkout of this repo:

```bash
agy plugin install <nng-kit>/plugins/lifecycle
agy plugin install <nng-kit>/plugins/relay
```

Invoke as `/lifecycle:<name>` and `/relay:<name>`. Antigravity does not run the `relay` SessionStart hook, so run `/relay:pickup` manually. If you do not use Antigravity on a host, disable `agy` ([Enable or disable a tool](../../README.md#enable-or-disable-a-tool)).

## Windsurf / plain `SKILL.md` skills

Symlink each `plugins/lifecycle/skills/<name>/` directory into `~/.agents/skills/<name>/` and into the tool's skills directory (`~/.codeium/windsurf/skills`, or as a fallback `~/.cursor/skills`, `~/.config/devin/skills`). Invoke as `/<name>`.
