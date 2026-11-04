# relay

Cross-surface handoff for Claude: save session intent on one surface and pick
it up on another. Surfaces: Claude Code in a git repo, Claude Code outside a
repo, and claude.ai chat (via a separate private upload-only skill).

Format contract: [references/format.md](references/format.md). Remote
operations: [references/storage.md](references/storage.md).

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
| Code in a git repo | `docs/relay/<branch-slug>.md` (legacy `docs/handoffs/<branch-slug>.md`; committed with your next commit; never auto-committed) |
| Remote (optional) | `$RELAY_ROOT/{pending,archive,locks}/` when a backend is configured |

There is no default remote root. When `$RELAY_ROOT` is unset and the deprecated
`$RELAY_DROPBOX_ROOT` alias is also unset, remote mirroring is off and the
plugin is repo-only (typical for cloud sessions).

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
| `/relay:save` | Draft directive + frontmatter; write the branch file; optional remote mirror |
| `/relay:pickup` | Re-read, twin-check, then Execute / Edit / Discard / Save for later |
| `/relay:check` | Read-only status (branch file, other handoffs, remote summary) |
| `/relay:discard` | Confirm and discard without acting (`disable-model-invocation`) |

Claim and conflict detection use remote `create_if_absent` where the backend
supports it (see [storage.md](references/storage.md)). Moves and deletes are
eventual cleanup.

## Environment

Set in the host's Claude Code `settings.json` `env` block (private config, not
in this marketplace).

| Variable | Role |
| --- | --- |
| `RELAY_BACKEND` | `dropbox` (default when `RELAY_ROOT` is set) or `onedrive` (repo-only until implemented) |
| `RELAY_ROOT` | Active remote root folder |
| `RELAY_LEGACY_ROOT` | Optional former root; list/read only for migration and straggler adoption |
| `RELAY_DROPBOX_ROOT` | **Deprecated alias** for `RELAY_ROOT` when backend is Dropbox; skills nudge you toward `RELAY_ROOT` |

Example shape:

```json
{
  "env": {
    "RELAY_BACKEND": "dropbox",
    "RELAY_ROOT": "/path/to/your/relay-root",
    "RELAY_LEGACY_ROOT": "/path/to/your/legacy-relay-root"
  }
}
```

When a root is configured, `/relay:save` may ask "continue where?" (here /
chat / anywhere) and mirror a twin under `pending/`. When no root is set, save
writes the repo file only.

Resolver behaviour (repo-only vs mirror, deprecated alias, unimplemented
backend) is implemented in `scripts/relay-lib.sh` and described in
[storage.md](references/storage.md#env).

## Required tools per backend

### Dropbox (`RELAY_BACKEND=dropbox`)

For Dropbox-backed save / pickup / check / discard, the session needs these
MCP tools allowed (mapped to [storage.md](references/storage.md) operations):

- `create_folder`
- `create_file`
- `fetch`
- `move`
- `list_folder`
- `delete`

relay never needs `check_job_status`. A repo with a tool-pruning deny list must
allow these six. Non-lock operations may fall back to `dbxcli` when MCP is
unavailable; locks always use MCP `create_file`.

### OneDrive (`RELAY_BACKEND=onedrive`)

**Not implemented.** Skills stay repo-only and do not call Graph. The planned
mapping and auth prerequisites are in [storage.md](references/storage.md#onedrive).

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

Without it, cloud sessions have no relay plugin. They also lack `RELAY_ROOT`,
so behaviour is repo-only.

## SessionStart

The hook reads `docs/relay/<branch-slug>.md` for the current branch, then
legacy `docs/handoffs/<branch-slug>.md` if needed (no network). It routes to
`/relay:pickup` with the directive and frontmatter
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

## Migrating to `docs/relay` and a new root

After upgrading to relay 0.3.0+ (skills that read legacy paths and offer
migration), run this on **every** machine that uses relay, then finish repo and
remote moves in order.

### Repo path (`docs/handoffs` → `docs/relay`)

- `/relay:save` writes only `docs/relay/<slug>.md`. If a legacy
  `docs/handoffs/<slug>.md` exists, save offers **Migrate (`git mv`) then save /
  Cancel** first.
- On the default branch, `/relay:pickup` may offer to move all
  `docs/handoffs/*.md` → `docs/relay/` with `git mv -k` (no clobber,
  uncommitted until you commit).
- SessionStart prefers `docs/relay/` and falls back to `docs/handoffs/` with a
  one-line legacy note.

### Remote root (legacy folder → active root)

Set `RELAY_ROOT` to the new folder and `RELAY_LEGACY_ROOT` to the old one.
Pickup offers a guarded whole-folder move when the legacy root has content and
the active root is absent. Verification is always by **listing** (`pending/`,
`locks/`, `README.md` at the new root; legacy gone or empty), never by the move
return value. Stragglers written to the legacy root after migration are adopted
via `/relay:pickup` (terminal `superseded` lock in the legacy root, pending
file recreated under the active root).

### Rollout runbook (manual, after merge + host rebuild)

1. Rebuild **every** kit host so no machine still runs an older relay against
   the legacy remote root (`nix run '.#check'`, then your usual
   `darwin-rebuild switch` or equivalent).
2. Run `/relay:pickup` in any repo and accept the **remote migration** when
   offered (repo `git mv` can happen here too).
3. Upload the updated claude.ai chat skill **immediately after** step 2. Do
   **not** upload it before step 2: a new chat save would create the active root
   and block the whole-folder move (straggler adoption would be the only route).
4. Run `/relay:check`, then `/relay:pickup` to adopt stragglers until the
   legacy root has no pending files.
5. Later, remove `RELAY_LEGACY_ROOT` from host env when you no longer need
   legacy read/list.

## Migrating from handoff

Relay replaces the older `handoff` plugin. Both can stay installed during the
switch.

### Importing a legacy handoff

`/relay:check` reports a legacy `.claude/handoff/active.md` by its frontmatter
only. `/relay:pickup` offers **Import / Leave for now** after its branch-file
flow ends, or when there is no branch file. Import works in git repos only.

The confirm gate shows the full body, any absolute paths found in it, the
derived title and the target repo. Review the whole body before you confirm:
the import commits it verbatim to `docs/relay/<branch-slug>.md`, and the
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

An orphan is a `docs/relay/<slug>.md` or legacy `docs/handoffs/<slug>.md`
whose branch exists neither locally nor on `origin`. Typically it is a handoff
left unconsumed when its branch was squash-merged or deleted.

- `/relay:check` lists orphans read-only.
- `/relay:pickup` on the default branch offers **Delete / Keep** for each one.
  Deletions ride along with your next commit; nothing is committed automatically.
- A mirrored handoff takes the `discarded` lock before its file is deleted, so
  its remote twin cannot be picked up from chat.
- If `origin` does not answer within 10 seconds, the status is **stale**. The
  orphans are listed, and nothing is offered.

Detection is one read-only `git ls-remote --heads origin`, run only by check and
pickup, never by the SessionStart hook. Branches `a/b` and `a--b` share the slug
`a--b`, so a file stays live while either branch exists.
