---
name: save
description: >-
  Relay handoffs (`/relay:save`) for Claude Code, Devin, Cursor and agy.
  Capture this session's intent as a relay handoff (repo file and optional
  remote mirror). Use when the user says "save handoff", "hand this off", or
  "continue later" in a coding agent session.
  Not for claude.ai chat (that surface uses the separate relay chat skill).
---

# relay save

Capture session intent into a relay handoff for the next Claude surface.

Contract: [format.md](references/format.md), [storage.md](references/storage.md). Shell stays inline; do not source plugin scripts. Name remote calls with the storage.md operations (`create_if_absent`, `read`, `create_folder`, and so on). The backend mapping and the conflict signal live in storage.md — do not hard-code a vendor tool name in place of those operations.

This skill writes `docs/relay/<slug>.md` only. It never creates a file under `docs/handoffs/`.

## 1. Invocation mode

| Trigger | Mode |
| --- | --- |
| User typed `/relay:save` | **Direct** — skip the Save now / Edit first / Cancel gate; continue from the draft |
| NL phrase ("save handoff", "continue later", …) | **Confirm** — run the confirm gate before drafting |

If unsure, use **Confirm**.

Direct mode does **not** skip the legacy migrate gate or the overwrite gate (step 5).

### Confirm gate (Confirm mode only)

Ask (single-select):

- **Save now** *(Recommended)* — draft from this session and write immediately
- **Edit first** — draft, show for edits, then write
- **Cancel** — do not write

**Cancel** → stop with no writes.
**Save now** or **Edit first** → continue. If **Edit first**, show the draft
directive after step 3 and iterate until the user approves before any write
(including a legacy `git mv`).

## 2. Resolve remote

Before any remote `read` or write, resolve from the environment, or `~/.config/relay/env` when unset. Pure env; no network. Same rules as `relay_resolve_remote` in `../../scripts/relay-lib.sh` (prints `backend<TAB>root<TAB>legacy_root<TAB>status`).

```bash
# RELAY_* from ~/.config/relay/env when unset (same rules as relay_load_env_file)
relay_env="${XDG_CONFIG_HOME:-$HOME/.config}/relay/env"
if [ -r "$relay_env" ]; then
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      *"$(printf '\t')"*|*"$(printf '\r')"*) continue ;;
      RELAY_BACKEND=*) [ -n "${RELAY_BACKEND+x}" ] || export RELAY_BACKEND="${l#*=}" ;;
      RELAY_ROOT=*) [ -n "${RELAY_ROOT+x}" ] || export RELAY_ROOT="${l#*=}" ;;
      RELAY_LEGACY_ROOT=*) [ -n "${RELAY_LEGACY_ROOT+x}" ] || export RELAY_LEGACY_ROOT="${l#*=}" ;;
      RELAY_DROPBOX_ROOT=*) [ -n "${RELAY_DROPBOX_ROOT+x}" ] || export RELAY_DROPBOX_ROOT="${l#*=}" ;;
    esac
  done < "$relay_env"
fi
backend="" root="" legacy="" relay_status="off"
if [ -n "${RELAY_ROOT:-}" ]; then
  root="$RELAY_ROOT"
  backend="${RELAY_BACKEND:-dropbox}"
  case "$backend" in
    dropbox) relay_status="on" ;;
    onedrive) relay_status="not-implemented" ;;
    *) relay_status="unknown-backend" ;;
  esac
elif [ -n "${RELAY_DROPBOX_ROOT:-}" ]; then
  backend="dropbox"
  root="$RELAY_DROPBOX_ROOT"
  relay_status="deprecated-alias"
fi
legacy="${RELAY_LEGACY_ROOT:-}"
if [ -n "$legacy" ] && [ "$legacy" = "$root" ]; then
  legacy=""
fi
# A tab or newline in either root → invalid-root (repo-only; roots cleared).
nl='
'
case "$root$legacy" in
  *"$(printf '\t')"*|*"$nl"*) root="" legacy="" relay_status="invalid-root" ;;
esac
printf 'backend=%s status=%s root=%s legacy=%s\n' \
  "${backend:-none}" "$relay_status" "${root:-unset}" "${legacy:-unset}"
```

Without the Dropbox MCP `create_file` tool, follow storage.md § Without the Dropbox MCP.

Say the matching line once, then follow it for the rest of the skill. Remote calls are allowed only when `status` is `on` or `deprecated-alias`. Do not `read`, `create_if_absent`, `create_folder`, `move`, or `delete` under `$legacy`. The only exception is a `list` of `$legacy` for the absent-root gate in step 6.

| `status` | What to tell the user | Remote |
| --- | --- | --- |
| `on` | nothing | mirror allowed on `<root>` |
| `deprecated-alias` | one line: `Set RELAY_ROOT; RELAY_DROPBOX_ROOT is a deprecated alias.` | same as `on`, using the resolved root |
| `not-implemented` | `Backend <backend> is not implemented; this save is repo-only (no remote mirror).` | no remote calls |
| `unknown-backend` | `Backend <backend> is an unknown backend; this save is repo-only (no remote mirror).` | no remote calls |
| `invalid-root` | `RELAY_ROOT or RELAY_LEGACY_ROOT contains a tab or newline; this save is repo-only (no remote mirror). Fix the env value.` | no remote calls |
| `off`, `$legacy` empty | `No remote root set; this save is repo-only.` | no remote calls |
| `off`, `$legacy` non-empty | `No active remote root, and a legacy root is set. Not mirroring. Run /relay:pickup to migrate.` | no remote mirror and no remote calls |

Name `<backend>` from the resolver (for example `onedrive`). Do not print the legacy root path. Repo-only means: inside a git repo, write `docs/relay/<slug>.md` and skip every remote operation. Outside a git repo, follow step 8 (paste block, no invented path).

## 3. Draft

### Directive

Five parts, under 400 words, present-tense imperative to the next Claude.
Intent only — no state the next session can look up (git log, tree, memory).

1. **Next step** — one concrete first action
2. **Pointers** — paths, plans, PRs, refs worth reading first
3. **Constraints** — decisions already made; what not to reopen
4. **Expected state** — what should already be true at resume
5. **Open questions** — unresolved items the next session must handle

Prefer pointing at a written plan over restating it. See format.md § Directive.

### Frontmatter (git repo)

Compute with inline Bash (adapt as needed; do not source plugin scripts):

```bash
saved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sha="$(git rev-parse HEAD 2>/dev/null || true)"
branch="$(git branch --show-current 2>/dev/null || true)"
branch_yaml="$(printf '%s' "${branch:-detached}" | tr -d '"\\')"
origin_url="$(git remote get-url origin 2>/dev/null || true)"
# owner/name from SSH or HTTPS origin; strip .git
repo="$(printf '%s\n' "$origin_url" | sed -E 's#^(git@|https://|ssh://git@)([^/:]+)[:/]##' | sed -E 's#\.git$##')"
```

**id** (UTC): `YYYYMMDDTHHmmZ-<4 base36>`

```bash
id="$(date -u +%Y%m%dT%H%MZ)-$(LC_ALL=C tr -dc '0-9a-z' </dev/urandom | head -c 4)"
```

**Branch slug** (repo path and twin filename):

1. `/` → `--`
2. any character outside `[A-Za-z0-9._-]` → `-`
3. empty / detached HEAD → `detached-<short-sha>`

```bash
short_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -z "$branch" ]; then
  slug="detached-${short_sha}"
else
  slug="$(printf '%s' "$branch" | sed -e 's|/|--|g' -e 's|[^A-Za-z0-9._-]|-|g')"
fi
```

Required fields for a repo save:

| Key | Value |
| --- | --- |
| `id` | as above |
| `title` | short human label |
| `origin` | `code-repo` |
| `saved-at` | `$saved_at` |
| `repo` | `owner/name` |
| `branch` | current branch (or `detached`), written double-quoted as `branch: "$branch_yaml"` (`"` and `\` already deleted) |
| `sha` | commit SHA |
| `rev` | `1` |

Omit `space` when this save is repo-only (any status other than `on` or `deprecated-alias`) or the name is still unclear. When the user names one and remote calls are allowed, `read` `<root>/README.md` (`## Spaces`) and prefer a listed name; if the file or section is missing, treat as no list. Example placeholder names only: `work`, `home`.

Do not set `deferred-at` on save. Do not set `mirror` until a twin is created
(step 6). Absolute working directory: **`cwd` never in repo files**.

## 4. Public-repo warning

Inside a git repo, before the step 5 asks and before any repo mutation, state that the file will be committed to `<owner/name>` (the `repo` field) with the next commit — this skill never runs `git commit`.

Check visibility:

```bash
gh repo view --json visibility -q .visibility 2>/dev/null || echo UNKNOWN
```

When the result is `PUBLIC`, or the command fails / returns unknown: warn the
user to review the directive for private details before they answer step 5.

## 5. Legacy file, then overwrite

Run this only inside a git work tree, after the draft is approved and after the step 4 warning, and before any repo mutation.

### Legacy path first

If `docs/handoffs/<slug>.md` exists and `docs/relay/<slug>.md` does not, ask (single-select) before the overwrite check:

- **Migrate (git mv) then save** *(Recommended)* — move the legacy file onto `docs/relay/<slug>.md` (no clobber), then write this save over that path
- **Cancel** — keep the legacy file; do not write

**Cancel** → stop with no writes.

There is no third choice. Do not write `docs/relay/<slug>.md` beside the legacy file.

If both `docs/handoffs/<slug>.md` and `docs/relay/<slug>.md` exist, do not move (that would clobber). Note once that both exist, this save uses `docs/relay/<slug>.md` only, and the legacy file stays for `/relay:pickup`. Then the overwrite check below.

### Overwrite check

If `docs/relay/<slug>.md` already exists and the user did **not** just choose **Migrate (git mv) then save**, ask (single-select):

- **Overwrite** *(Recommended)* — replace with this save
- **Cancel** — keep the existing file; abort

Do not silently replace. **Cancel** → stop with no writes.

Skip this ask when they chose migrate: that choice already authorises the new body.

## 6. Write (git repo)

Perform the migrate only after **Migrate (git mv) then save**, and only when the destination is absent:

```bash
src="docs/handoffs/${slug}.md"
dest="docs/relay/${slug}.md"
mkdir -p docs/relay
if [ -e "$dest" ]; then
  echo "refusing to clobber ${dest}" >&2
elif git ls-files --error-unmatch "$src" >/dev/null 2>&1; then
  git mv "$src" "$dest"
else
  mv -n "$src" "$dest"
fi
```

Tracked legacy file → `git mv` (this stages the rename; do not commit, and do not stage anything else). Untracked legacy file → `mv -n`. If the refuse line prints, the move fails, or the destination was not created, stop and do not write a second copy.

```bash
mkdir -p docs/relay
```

Write `docs/relay/<slug>.md`: YAML frontmatter (step 3 fields) then the
directive body. Absolute working directory: **`cwd` never in repo files**.

### Continue where?

Offer this only when `status` is `on` or `deprecated-alias`. Otherwise do not ask and do not create a twin (step 2 already said why).

**Absent-root gate.** When `$legacy` is non-empty, `list` `<root>` and `list` `<legacy>` to the end before the ask below, and before any `create_folder`, `create_if_absent`, or `dbxcli` pending write on `<root>`. This `list` is the only storage call this skill makes under `$legacy`.

- A finished `list` shows `<root>` absent (not found) and `<legacy>` has content (that finished `list` is non-empty): do **not** `create_folder` or `create_if_absent` on `<root>`, and do not make a `dbxcli` pending write there. Do not offer **Chat** or **Anywhere**. Tell the user the handoffs still live in the legacy root and to run `/relay:pickup` — it moves the folder. Creating `<root>` here blocks that move. Leave `mirror` unset. The repo file this save already wrote stays. Stop the twin.
- The `<root>` list is unfinished, or returns any error other than not-found: **unknown**. Do not bootstrap and do not write a twin. Stop the twin.
- The `<legacy>` list is unfinished: **unknown**. Do not create `<root>` and do not write a twin. Stop the twin.
- A finished `list` shows `<root>` exists and has zero entries, and the finished `<legacy>` `list` is non-empty: do **not** `create_folder`, `create_if_absent`, or make a `dbxcli` pending write on `<root>`. Do not offer **Chat** or **Anywhere**. The folder existing is not bootstrap permission. Writing here would put content in the empty root and block a later folder move (a folder move is only for an absent root). Tell the user to remove the empty active root outside this skill, then run `/relay:pickup`. Leave `mirror` unset. The repo file this save already wrote stays. Stop the twin.
- Otherwise continue only when a finished `list` shows `<root>` has one or more entries, or a finished `list` shows `<legacy>` is absent or empty. Do not treat "the folder exists" as bootstrap permission.

Ask (single-select), unless the gate just stopped the twin:

- **Here** — repo file only; no remote twin
- **Chat** — also mirror for claude.ai pickup
- **Anywhere** — also mirror for any surface

If not **Here**, `create_if_absent` the twin at:

`<root>/pending/<id>__<slug>.r1.md`

Look up that operation's call and its conflict signal in storage.md for `$backend`. The twin may record the absolute working directory; the repo file must not (**`cwd` never in repo files**). Twin frontmatter uses the same `id` / `rev: 1` and `origin: code-repo`.

A conflict signal on the twin means the path already existed: stop and report; do not overwrite; do not set `mirror`. The repo file already written stays as-is. `move` and `delete` are not a correctness signal.

When the mapped `create_if_absent` call is unavailable but the Dropbox MCP `create_file` tool is available, storage.md allows a `dbxcli` write of that pending file only — `dbxcli` writes apply only when the Dropbox MCP `create_file` tool is available. When `create_file` itself is absent (no Dropbox MCP), refuse the mirror step with `remote claim needs Claude Code (Dropbox MCP)`; the handoff stays repo-only. Discover the subcommand with `dbxcli … --help --output=json`, then pass `--output=json`. A `dbxcli` write is not a conflict signal — do not overwrite; if you cannot show the path was absent, stop and report. This skill does not create `locks/*.lock`.

If the absent-root gate allows a write and `pending/`, `archive/`, or `locks/` under `<root>` are missing, `create_folder` after a brief confirm. An already-exists result from `create_folder` is ordinary, not a claim. Folder creation may use the storage.md `dbxcli` fallback (only when the Dropbox MCP `create_file` tool is available). Seed `<root>/README.md` only if the user agrees, and only with `create_if_absent` (not `dbxcli`) — do not invent a space list. A conflict on that seed means the README is already there; leave it and continue. It is not a failed twin. If `create_if_absent` is unavailable, skip the seed. Do not `create_folder`, seed, or make a `dbxcli` pending write when the absent-root gate forbids a write, including when `<root>` exists and the finished `list` has zero entries while `<legacy>` has content.

After a successful `create_if_absent` of the twin, set `mirror: <id>__<slug>` on the **repo** file (no rev, no folder).

## 7. Report

Tell the user (terse):

- Path written: `docs/relay/<slug>.md`
- Legacy path migrated, if this save moved `docs/handoffs/<slug>.md`
- Twin path if any (`<root>/pending/<id>__<slug>.r1.md`)
- The file rides with the **next** commit — **never commit** from this skill

Do not dump the full directive back unless they chose Edit first. If the repo file was written and the twin was not, say that `mirror` was left unset. Do not repeat the step 2 status line.

## 8. Outside a git repo

If `git rev-parse --is-inside-work-tree` fails, skip steps 4–7. Still run steps 1–3 (no `repo` / `branch` / `sha`; `origin: code`).

1. **`on` or `deprecated-alias`** — save only to `<root>/pending/<id>__<title-slug>.r1.md` with `origin: code` (not `code-repo`). No `docs/relay/` write and no `git mv`. Do not use the step 3 branch slug for this filename. Title slug uses the branch-slug character rules; if the title sanitises to empty, use `untitled`. Same confirm / Edit-first rules. Use the step 6 twin rules only, including the absent-root gate: `create_if_absent`, its conflict signal (stop and report; do not overwrite), the `dbxcli` pending-file fallback (not a conflict signal), and `create_folder` when `pending/`, `archive/`, or `locks/` is missing. If the gate forbids the write, do not `create_folder`, `create_if_absent`, or make a `dbxcli` pending write on `<root>` — including when `<root>` already exists and the finished `list` has zero entries. Print the paste block and stop. Otherwise tell the user the pending path.
2. **`not-implemented`, `unknown-backend`, or `invalid-root`** — no remote calls. The step 2 message names the backend. Then print a copy-ready paste block (frontmatter + directive). Do not invent a remote path.
3. **`off` and `$legacy` non-empty** — no remote mirror. The step 2 line tells the user to run `/relay:pickup` to migrate. Then print the paste block. Do not invent a remote path and do not read the legacy root.
4. **`off` and `$legacy` empty** — paste block only. Do not invent a remote path.

Leave `cwd` out of the paste block.

## Key rules

- Confirm mode always gets Save now / Edit first / Cancel before writes.
- Write `docs/relay/<slug>.md` only. Never create `docs/handoffs/<slug>.md`.
- When `docs/handoffs/<slug>.md` exists and `docs/relay/<slug>.md` does not, ask **Migrate (git mv) then save / Cancel** before overwrite and before any mutation. No clobber. Untracked source uses `mv -n`.
- If both repo paths exist, do not `git mv`; note the duplicate; overwrite applies only to `docs/relay/<slug>.md`.
- Repo saves name `<owner/name>` and harden the warning when visibility is public or unknown.
- Overwrite of an existing `docs/relay/<slug>.md` is explicit, unless this save just migrated that path.
- Absolute working directory: **`cwd` never in repo files**.
- Never `git commit` from this skill.
- Resolve with `relay_resolve_remote` / the inline block above. `not-implemented` and `unknown-backend` are repo-only and name the backend; `invalid-root` is repo-only and names the bad env var. `deprecated-alias` gets one nudge to set `RELAY_ROOT`. No active root plus a legacy root means no mirror; point at `/relay:pickup`.
- Remote operations use storage.md names. `create_if_absent` is the only conflict signal. `create_folder` already-exists is not a claim. A `dbxcli` pending write is not `create_if_absent`.
- **Absent root.** When a finished `list` shows `<root>` absent and `<legacy>` has content, do not `create_folder` or `create_if_absent` on `<root>`, and do not make a `dbxcli` pending write there. Tell the user to run `/relay:pickup` for the folder move. Creating `<root>` blocks that move.
- **Empty root.** When a finished `list` shows `<root>` exists with zero entries and `<legacy>` has content, do not `create_folder`, `create_if_absent`, or make a `dbxcli` pending write there. The folder existing is not bootstrap permission. Tell the user to remove the empty active root outside this skill, then run `/relay:pickup`.
- Do not write under the legacy remote root. `list` it only for the absent-root gate.
- No personal remote paths or space names in this skill's prose. Use `<root>` from the resolver.
