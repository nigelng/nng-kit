# Changelog

Notable changes to the nng-kit plugins, newest first. Each sync commit on
nigelng/nng-kit quotes the lines added here since the previous sync, so write
for plugin users. This file is public: keep private names and paths out.

## 2026-11-02

- Sync commits now list the plugins and versions they change, plus the new
  lines from this changelog, instead of a bare snapshot note.

## 2026-11-01

- relay 0.2.0: one-time import of a legacy `.claude/handoff/active.md`;
  `/relay:check` reports handoff files whose branch is gone and
  `/relay:pickup` offers to clean them up on the default branch. Supersedes
  the older `handoff` plugin.
- Snapshots of this repo are now GitHub-signed commits (shown as Verified).

## Earlier

- Initial releases of `lifecycle`, `evc-observe` and `relay`.
