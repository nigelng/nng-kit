# Changelog

Notable changes to the nng-kit plugins, newest first. Each sync commit on
nigelng/nng-kit quotes the lines added here since the previous sync, so write
for plugin users. This file is public: keep private names and paths out.

## 2026-11-03

- lifecycle 0.2.0: canonical **model-tiers** policy (`top` / `mid` / `low`
  per-tool chains) lives in `plugins/lifecycle/model-tiers.md`; skill copies
  stay in sync via `bash scripts/sync-model-tiers.sh` (`--check` in CI).
  `/brainstorm`, `/make-plan` and `/critique plan` run as top-tier sessions;
  `/critique change` runs up to two lean mid-tier rounds plus at most two
  top-tier passes per run (escalate + closing pass); `/execute-plan` uses
  mid-tier review passes with one top-tier final pass (plus at most one
  escalation), and `haiku` map rows fall back to `mid` when capped.
  Behaviour-changing `/execute-plan` steps follow `test & implement → lint →
  verify` (justified skip + validate checks for docs/config). Includes token
  trims, changelog and git-safety tightening across the skill chain, portable
  byte-identity checks for vendored references, and optional rule summary-block
  sync when marker comments are present.
- delegate 0.1.2: `/delegate:execute-via-cursor` and
  `/delegate:execute-via-agy` default to the backend's Auto model when `model=`
  is omitted, and the vendored **execution-status** reference stays byte-synced
  with `lifecycle` (enforced by the portable drift guard).

## 2026-11-02

- Sync commits now list the plugins and versions they change, plus the new
  lines from this changelog, instead of a bare snapshot note.
- delegate 0.1.0 (new plugin): `/delegate:execute-via-cursor` (Cursor `agent`)
  and `/delegate:execute-via-agy` (Google Antigravity `agy`). Both skills
  share one core reference and one brief template. Claude Code gates the run,
  reviews the diff and drives the PASS / FIX / FAIL loop. Install the CLI for
  the backend you use.
- exec-observe 0.3.0 replaces the retired observe plugin. **Breaking:**
  uninstall `evc-observe@nng-kit` and install `exec-observe@nng-kit`
  (`claude plugin uninstall evc-observe@nng-kit`, then
  `claude plugin install exec-observe@nng-kit`). Run files are renamed from
  `evc-run-<n>.{ndjson,err,exit}` to
  `exec-run-<backend>-<n>.{ndjson,err,exit}`. The `/exec` command replaces
  `/evc`. The header shows a backend badge for Cursor and Antigravity runs.
- lifecycle 0.1.1: `execution-status.md`, `LIFECYCLE.md` and `plan-template.md`
  now point to `/delegate:execute-via-cursor` and `/delegate:execute-via-agy`.
  `execute-via-cursor` moved from local-only into the published `delegate`
  plugin.

## 2026-11-01

- relay 0.2.0: one-time import of a legacy `.claude/handoff/active.md`;
  `/relay:check` reports handoff files whose branch is gone and
  `/relay:pickup` offers to clean them up on the default branch. Supersedes
  the older `handoff` plugin.
- Snapshots of this repo are now GitHub-signed commits (shown as Verified).

## Earlier

- Initial releases of `lifecycle`, `evc-observe` and `relay`.
