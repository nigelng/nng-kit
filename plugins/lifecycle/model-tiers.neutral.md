<!-- Generated from nng-kit/plugins/lifecycle/model-tiers.md. Do not edit. -->

## Fallback

Resolve with `tiers.sh resolve <tool> <tier>` (`tiers.sh` = `bash <skill-dir>/../execute-plan/scripts/tiers.sh` in lifecycle skills, `bash <skill-dir>/../../scripts/tiers.sh` in delegate skills; `<host>` in skill preconditions is the registry id of the tool running the session, not `tiers.sh host`, which is only the default); the rows below are generated from the registry and follow these rules.
- **Expired rows (`until: YYYY-MM-DD`):** skip any row whose `until:` date has passed (`today > until`, local date) and log `fallback: expired <slug>`. A tool-level `until` (shown in the tool's header) applies to every row of that tool.
- **Planning fallback order:** per `tiers.sh order` (registry `planningOrder`), handing off via `/relay:save` + `/relay:pickup`.
- **Routers:** Cursor `auto` (Cost mode, included pool) only (1) as the logged fallback for Cursor `execute`, `mid`, and `low` (existing triggers: the pin missing from `agent models`, a usage/quota error, or an explicit `model=auto`; record `fallback: <reason>`), or (2) on a map row with `Model: auto` + `Tier: low` + `Runner: delegate:cursor`, recorded `auto(router)`. Never on top or review work. Devin `adaptive` never: it costs more than the pins and has no pool advantage.
- **Tier exhaustion:** if `low` is exhausted → fall back to `mid` (never stall a wave). `top-plan` → next tool in the planning fallback order. `top-review` → `top@devin-fusion` when Devin is active and not the host, logged `fallback: top-review exhausted`; otherwise stop and ask.
- **Review family:** a mid review pass prefers an allowed model from a different family than the implementer's; if the host has none at mid, proceed and log `same-family mid review` in the run notes. On Cursor the second family is `claude-sonnet-5-5-high` (third-party pool; the one exception to Cursor-models-only for `mid`); on Devin it is `gpt-6-1-sol-high` against the SWE-2 implementer. Top-review is unaffected.
- **Cursor model rule:** on Cursor, `execute`/`mid`/`low` use Cursor models only (Grok for `execute`/`mid` pins, Composer 2.5, Auto), except `mid` review passes, which use `claude-sonnet-5-5-high`. Other Claude models only for `top-plan`/`top-review`, or by a manual `model=` override. Never GPT.

## Per-tool resolution

<!-- tiers:generated:per-tool:start -->
- **claude-code** (Claude Code; cli `claude`; default review runner `top@claude-task`):
  - `top-plan` = none
  - `top-review` = none
  - `execute` = none (resolves to `mid`)
  - `mid` = none
  - `low` = none (resolves to `mid`)
<!-- tiers:generated:per-tool:end -->

## Review runners

- `top@session` = the host session at `top-review` (a `mid` `/execute-plan` orchestrator uses the host's `defaultReviewRunner`)
<!-- tiers:generated:review-runners:start -->
- `top@claude-task` = Claude Code `top-review` pin, mode `task`
<!-- tiers:generated:review-runners:end -->

External runners (every runner except `top@session` and `top@claude-task`) run through the delegate plugin's review launcher. They read the host's verify-script summary and never run Verification themselves, and they run under a git guard that reverts any reviewer edit. A reviewer failure (launch error, quota, timeout, guard trip, missing or inconsistent verdict) → stop and ask: retry, the host's `defaultReviewRunner`, or abort.
