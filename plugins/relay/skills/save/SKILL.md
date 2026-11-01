---
name: save
description: >-
  Claude Code only (`/relay:save`). Capture this session's intent as a relay
  handoff (repo file and optional Dropbox mirror). Use when the user says
  "save handoff", "hand this off", or "continue later" inside Claude Code.
  Not for claude.ai chat (that surface uses the separate relay chat skill).
---

# relay save

Capture session intent into a relay handoff for the next Claude surface.

Contract: [format.md](../../references/format.md). Shell stays inline; read
`$RELAY_DROPBOX_ROOT` from the environment when Dropbox features are needed.

## 1. Invocation mode

| Trigger | Mode |
| --- | --- |
| User typed `/relay:save` | **Direct** — skip the Save now / Edit first / Cancel gate; continue from draft |
| NL phrase ("save handoff", "continue later", …) | **Confirm** — run the confirm gate before drafting |

If unsure, use **Confirm**.

### Confirm gate (Confirm mode only)

Ask (single-select):

- **Save now** *(Recommended)* — draft from this session and write immediately
- **Edit first** — draft, show for edits, then write
- **Cancel** — do not write

**Cancel** → stop with no writes.
**Save now** or **Edit first** → continue. If **Edit first**, show the draft
directive after step 2 and iterate until the user approves before writing.

## 2. Draft

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
| `branch` | current branch (or note detached) |
| `sha` | commit SHA |
| `rev` | `1` |

Omit `space` unless the user names one. If they name one **and**
`$RELAY_DROPBOX_ROOT` is set, read `<root>/README.md` (`## Spaces`) and prefer
a listed name; if the file or section is missing, treat as no list. Example
placeholder names only: `work`, `home`. Leave `space` out when still unclear.

Do not set `deferred-at` on save. Do not set `mirror` until a twin is created
(step 5). Absolute working directory: **`cwd` never in repo files**.

## 3. Overwrite check

If `docs/handoffs/<slug>.md` already exists, ask (single-select):

- **Overwrite** *(Recommended)* — replace with this save
- **Cancel** — keep the existing file; abort

Do not silently replace.

## 4. Public-repo warning

Before writing a repo file, state that it will be committed to `<owner/name>`
(the `repo` field) with the next commit — this skill never runs `git commit`.

Check visibility:

```bash
gh repo view --json visibility -q .visibility 2>/dev/null || echo UNKNOWN
```

When the result is `PUBLIC`, or the command fails / returns unknown: warn the
user to review the directive for private details before confirming the write.

## 5. Write (git repo)

```bash
mkdir -p docs/handoffs
```

Write `docs/handoffs/<slug>.md`: YAML frontmatter (step 2 fields) then the
directive body. Absolute working directory: **`cwd` never in repo files**.

### Continue where? (only if `$RELAY_DROPBOX_ROOT` is set)

Ask (single-select):

- **Here** — repo file only; no Dropbox twin
- **Chat** — also mirror for claude.ai pickup
- **Anywhere** — also mirror for any surface

If not **Here**, create the twin at:

`$RELAY_DROPBOX_ROOT/pending/<id>__<slug>.r1.md`

Prefer the Dropbox MCP `create_file`. Fall back to `dbxcli` (discover via
`dbxcli … --help --output=json`, then `--output=json` on the write) when MCP
is unavailable — **only for writing the pending twin file and creating
folders** (`pending/`, `archive/`, `locks/` directory itself). **Lock files
(`locks/*.lock`) are created only with the Dropbox MCP `create_file`**,
because `[ALREADY_EXISTS]` is the atomic claim signal and `dbxcli` upload
semantics are not verified to fail on existing paths. If a later step needs a
lock and the MCP is unavailable, stop (do not invent a lock via `dbxcli`).

If `pending/`, `archive/`, or `locks/` under the root are missing, create the
folders after a brief confirm (and seed `README.md` only if the user agrees —
do not invent a space list). Folder creation may use MCP or `dbxcli`; lock
*files* may not.

Conflict detection: trust **MCP `create_file` + `[ALREADY_EXISTS]` only**.
Moves and deletes are eventual cleanup and are never a correctness signal. A
twin create that returns `[ALREADY_EXISTS]` means stop and report; do not
overwrite.

After a successful twin create, set `mirror: <id>__<slug>` on the **repo**
file (no rev, no folder). The Dropbox twin may record the absolute working
directory; the repo file must not (**`cwd` never in repo files**). Twin
frontmatter uses the same `id` / `rev: 1` and may use `origin: code-repo`.

## 6. Report

Tell the user (terse):

- Path written: `docs/handoffs/<slug>.md`
- Twin path if any
- The file rides with the **next** commit — **never commit** from this skill

Do not dump the full directive back unless they chose Edit first.

## 7. Outside a git repo

If `git rev-parse --is-inside-work-tree` fails:

1. **`$RELAY_DROPBOX_ROOT` set** — save only to Dropbox pending as
   `<id>__<title-slug>.r1.md` with `origin: code` (not `code-repo`). No
   `docs/handoffs/` write. Same confirm / Edit-first rules; skip overwrite of
   a branch file and skip the public-repo commit warning (nothing is
   committed). Still use create_file / `[ALREADY_EXISTS]` for conflicts.
2. **Root unset** — print a copy-ready paste block (frontmatter + directive)
   the user can paste into another surface. Do not invent a Dropbox path.

## Key rules

- Confirm mode always gets Save now / Edit first / Cancel before writes.
- Repo saves name `<owner/name>` and harden the warning when visibility is
  public or unknown.
- Overwrite is explicit; never silent.
- Absolute working directory: **`cwd` never in repo files**.
- Never `git commit` from this skill.
- Dropbox correctness = MCP `create_file` success vs `[ALREADY_EXISTS]`; treat
  move/delete as eventual cleanup only. `dbxcli` is pending-file / folder
  fallback only — never for `locks/*.lock`.
- Keep shell inline; read `$RELAY_DROPBOX_ROOT` from the environment.
