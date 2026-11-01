# relay

Cross-surface handoff for Claude: save session intent on one surface and pick
it up on another. Surfaces: Claude Code in a git repo, Claude Code outside a
repo, and claude.ai chat (via a separate private upload-only skill).

Format contract: [references/format.md](references/format.md).

## Surfaces and ownership

| Surface | Owner |
| --- | --- |
| Claude Code (git repo or not) | `/relay:*` plugin skills in this package |
| claude.ai chat | private `relay` chat skill (uploaded separately; not in this repo) |

Exactly one owner per surface. The chat skill defers to `/relay:*` whenever it
appears inside Claude Code.

If the older `handoff@…` plugin is installed, see "Migrating from handoff" below.

## Storage

| Context | Where |
| --- | --- |
| Code in a git repo | `docs/handoffs/<branch-slug>.md` (committed with your next commit; never auto-committed) |
| Dropbox (optional) | `$RELAY_DROPBOX_ROOT/{pending,archive,locks}/` |

There is no default Dropbox root. If `RELAY_DROPBOX_ROOT` is unset, Dropbox
features are off and the plugin is repo-only (typical for cloud sessions).

### `<root>/README.md` contract

Readers look for a `## Spaces` section with one `` `name` — description ``
bullet per space. Missing file or section means "no space list"; omit `space`
from frontmatter. Example placeholders only:

```markdown
## Spaces

- `work` — employment and professional tasks
- `home` — personal admin and home life
```

## Verbs

| Skill | Does |
| --- | --- |
| `/relay:save` | Draft directive + frontmatter; write the branch file; optional Dropbox mirror |
| `/relay:pickup` | Re-read, twin-check, then Execute / Edit / Discard / Save for later |
| `/relay:check` | Read-only status (branch file, other handoffs, Dropbox counts) |
| `/relay:discard` | Confirm and discard without acting (`disable-model-invocation`) |

Claim and conflict detection use Dropbox `create_file` + `[ALREADY_EXISTS]`
only. Moves and deletes are eventual cleanup.

## `RELAY_DROPBOX_ROOT`

Set in the host's Claude Code `settings.json` `env` block (private config, not
in this marketplace). Example shape:

```json
{
  "env": {
    "RELAY_DROPBOX_ROOT": "/path/to/your/handoffs-root"
  }
}
```

When set, `/relay:save` may ask "continue where?" (here / chat / anywhere) and
mirror a twin under `pending/`. When unset, save writes the repo file only.

## Required Dropbox tools

For Dropbox-backed save / pickup / check / discard, the session needs these
MCP tools allowed:

- `create_folder`
- `create_file`
- `fetch`
- `move`
- `list_folder`
- `delete`

relay never needs `check_job_status`. A repo with a tool-pruning deny list must
allow these six.

## Cloud sessions

Cloud sessions do not inherit the kit host's `env` or marketplace install.
Add a per-repo `.claude/settings.json` (same shape as the lifecycle snippet in
the marketplace README):

```json
{
  "extraKnownMarketplaces": {
    "nng-kit": { "source": { "source": "github", "repo": "nigelng/nng-kit" } }
  },
  "enabledPlugins": { "relay@nng-kit": true }
}
```

Without it, cloud sessions have no relay plugin. They also lack
`RELAY_DROPBOX_ROOT`, so behaviour is repo-only.

## SessionStart

The hook reads only `docs/handoffs/<branch-slug>.md` for the current branch
(no network). It routes to `/relay:pickup` with the directive and frontmatter
wrapped in `<untrusted-source>`. Snooze via `deferred-at` (24h). Stale files
(≥90 days) get a one-line `/relay:check` note; the hook never deletes a
committed file.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install relay@nng-kit
```

## Tests

From the plugin directory:

```bash
bats tests                   # bats suite
bash tests/orphan-scan.sh    # orphan-scan fixture; exits 0 and prints the expected orphans
```

## Migrating from handoff

Relay replaces the older `handoff` plugin. Both can stay installed during the
switch.

### Importing a legacy handoff

`/relay:check` reports a legacy `.claude/handoff/active.md` by its frontmatter
only. `/relay:pickup` offers **Import / Leave for now** after its branch-file
flow ends, or when there is no branch file. Import works in git repos only.

The confirm gate shows the full body, any absolute paths found in it, the
derived title and the target repo. Review the whole body before you confirm:
the import commits it verbatim to `docs/handoffs/<branch-slug>.md`, and the
legacy content is untrusted. If something should not be committed, choose
Cancel, edit the legacy file by hand, then run pickup again.

After a successful import the old file moves to
`.claude/handoff/archive/imported-<timestamp>.md`. It is never deleted, and
existing archive files are left in place.

### Retiring the old plugin

1. Uninstall `handoff` from your claude.ai account. This is the authoritative
   switch, and it applies to every device signed in to that account.
2. Optionally, pin `"handoff@synced": false` under `enabledPlugins` in your user
   settings. This stops the old session-start hook at once on that machine.
   Whether a later account sync keeps it disabled is unverified, so treat the
   pin as a backstop, not the switch.

Do this only after every machine you use runs relay 0.2.0 or later. Uninstalling
the old plugin first hides any legacy `active.md` from machines still on an
older relay.

### Orphan handoffs

An orphan is a `docs/handoffs/<slug>.md` whose branch exists neither locally nor
on `origin`. Typically it is a handoff left unconsumed when its branch was
squash-merged or deleted.

- `/relay:check` lists orphans read-only.
- `/relay:pickup` on the default branch offers **Delete / Keep** for each one.
  Deletions ride along with your next commit; nothing is committed automatically.
- A mirrored handoff takes the `discarded` lock before its file is deleted, so
  its Dropbox twin cannot be picked up from chat.
- If `origin` does not answer within 10 seconds, the status is **stale**. The
  orphans are listed, and nothing is offered.

Detection is one read-only `git ls-remote --heads origin`, run only by check and
pickup, never by the SessionStart hook. Branches `a/b` and `a--b` share the slug
`a--b`, so a file stays live while either branch exists.
