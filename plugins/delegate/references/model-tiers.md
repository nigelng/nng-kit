# Model tiers

Canonical ordered preference lists (`provider-model-version-effort`, left-to-right). Map tiers: `top|execute|mid|low`. Legacy aliases: `opus`→`top`, `auto`/`sonnet`→`mid`, `haiku`→`low`. Per-tool rows are generated from `nng-kit/plugins/delegate/scripts/tiers.json`; rows may carry `until: YYYY-MM-DD`; a disabled tool is shown as `disabled` and gets no summary block. A tool-level `until` (shown in the tool's header) applies to every row of that tool.

**Roles:** `top-plan` = `/brainstorm`, `/make-plan` and `/critique plan` sessions. `top-review` = map tier `top`, the batch/final reviews, and `/critique` escalate + closing pass. The `/execute-plan` orchestrator is `mid` on a v2 map (`plan-status.sh rows --lint` exits 0), else `top-review`. `top-critique` (optional) = a second-family `/critique plan` pass. `execute` is a map tier: it resolves to the host's `execute` pin, else `mid`. Delegates default to it.

**Grunt-work rule:** `execute`/`mid`/`low` resolve to each tool's own free or included models: Cursor Grok/Composer/Auto (included pool), Devin SWE-2 family first, agy Gemini (Gemini and Argon pools). Paid or third-party models (Claude on Cursor, Claude on agy, Opus/Fusion on Devin) only for `top-plan`/`top-review`, with one exception: Cursor `mid` review passes use `claude-sonnet-5-5-high` (Cursor's third-party pool). Claude Code is exempt (every model is Claude).

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
  - `top-plan` = `claude-opus-5-5` (effort high (xhigh for large/risky plans); Task(model: "opus"))
  - `top-review` = `claude-opus-5-5` (effort medium; Task(model: "opus"))
  - `execute` = none (resolves to `mid`)
  - `mid` = `claude-sonnet-5-5` (effort high; Task(model: "sonnet"))
  - `low` = `claude-haiku-5-5` (effort high; Task(model: "haiku"))
- **cursor** (Cursor; cli `agent`; delegate; default review runner `top@claude-headless`):
  - `top-plan` = `claude-opus-5-5-high`
  - `top-review` = `claude-opus-5-5-medium` (--mode=ask)
  - `execute` = `grok-4.7-high` → `auto` (logged fallback)
  - `mid` = implement: `grok-4.7-high` → `auto` (logged fallback); review passes: `claude-sonnet-5-5-high` (Cursor third-party pool)
  - `low` = `composer-2.5` → `auto` (logged fallback)
- **devin** (Devin; cli `devin`; delegate; default review runner `top@claude-headless`):
  - `top-plan` = `fusion-claude-opus-5-5-high-sidekick-swe-2-flash-max`
  - `top-review` = `fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max`
  - `top-critique` = `gpt-6-1-sol-high`
  - `execute` = `swe-2-high` (`until: 2026-11-30`) → `swe-2-medium` → `gpt-6-1-terra-high`
  - `mid` = implement: `swe-2-high` (`until: 2026-11-30`) → `swe-2-flash-medium` → `gpt-6-1-sol-high`; review passes: `gpt-6-1-sol-high` → `gemini-4-argon-medium` (`until: 2026-12-01`)
  - `low` = `swe-2-flash-high` → `claude-haiku-5-5-high`
- **agy** (Antigravity; cli `agy`; delegate; `until: 2026-11-26`; default review runner `top@claude-headless`):
  - `top-plan` = `claude-opus-5-5-high` (subagent Model: "inherit" when parent session is top, else "pro") (`until: 2026-11-26`)
  - `top-review` = `claude-opus-5-5-medium` (--mode plan; subagent Model: "inherit" when parent session is top, else "pro") (`until: 2026-11-26`)
  - `top-critique` = `gemini-4-argon-high` (`until: 2026-11-26`)
  - `execute` = `gemini-4-argon-medium` (`until: 2026-11-26`) → `gemini-3.8-flash-high` (`until: 2026-11-26`)
  - `mid` = `gemini-4-argon-medium` (`until: 2026-11-26`) → `gemini-3.8-flash-high` (subagent Model: "inherit" when parent session is mid, else "flash") (`until: 2026-11-26`)
  - `low` = `gemini-3.8-flash-high` (subagent Model: "flash_lite") (`until: 2026-11-26`)
<!-- tiers:generated:per-tool:end -->

<!-- tiers:tool-notes:start -->
- **claude-code:** Always set `model:` explicitly on spawns.
- **devin:** pinned only for delegate execution: never `adaptive` or `fusion-*` for `execute`/`mid`/`low`; Fusion only for `top-plan`/`top-review`; Devin CLI strips the `cognition-` prefix on `swe-2-*`.
  - **Standalone Devin tasks** (guidance, not a resolver row): Fusion lead `gpt-6-1-sol-high` with sidekick `swe-2-medium` (`fusion-gpt-6-1-sol-high-sidekick-swe-2-medium`, `until: 2026-11-30`), then `gpt-6-1-terra-high` (`fusion-gpt-6-1-sol-high-sidekick-gpt-6-1-terra-high`); Adaptive (`adaptive`) only for ad-hoc interactive use.
  - Note: Flash is free until 2026-12-04, then priced the same as Haiku, so the order still holds.
- **agy:** Claude only in `top-plan`/`top-review` (Claude + GPT quota group).
<!-- tiers:tool-notes:end -->

## Review runners

- `top@session` = the host session at `top-review` (a `mid` `/execute-plan` orchestrator uses the host's `defaultReviewRunner`)
<!-- tiers:generated:review-runners:start -->
- `top@claude-task` = Claude Code `top-review` pin, mode `task`
- `top@claude-headless` = Claude Code `top-review` pin, mode `headless`
- `top@cursor-ask` = Cursor `top-review` pin, mode `ask`
- `top@devin-fusion` = Devin `top-review` pin, mode `auto`
- `top@agy-plan` = Antigravity `top-review` pin, mode `plan`
<!-- tiers:generated:review-runners:end -->

External runners (every runner except `top@session` and `top@claude-task`) run through the delegate plugin's review launcher. They read the host's verify-script summary and never run Verification themselves, and they run under a git guard that reverts any reviewer edit. A reviewer failure (launch error, quota, timeout, guard trip, missing or inconsistent verdict) → stop and ask: retry, the host's `defaultReviewRunner`, or abort.

<!-- tiers:summary:claude-code:start -->
top-plan: claude-opus-5-5
top-review: claude-opus-5-5
execute: none
mid(auto): claude-sonnet-5-5
low(haiku): claude-haiku-5-5
<!-- tiers:summary:claude-code:end -->

<!-- tiers:summary:cursor:start -->
top-plan: claude-opus-5-5-high
top-review: claude-opus-5-5-medium
execute: grok-4.7-high→auto
mid(auto): implement grok-4.7-high→auto; review claude-sonnet-5-5-high
low(haiku): composer-2.5→auto
<!-- tiers:summary:cursor:end -->

<!-- tiers:summary:devin:start -->
top-plan: fusion-claude-opus-5-5-high-sidekick-swe-2-flash-max
top-review: fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max
top-critique: gpt-6-1-sol-high
execute: swe-2-high(until 2026-11-30)→swe-2-medium→gpt-6-1-terra-high
mid(auto): implement swe-2-high(until 2026-11-30)→swe-2-flash-medium→gpt-6-1-sol-high; review gpt-6-1-sol-high→gemini-4-argon-medium(until 2026-12-01)
low(haiku): swe-2-flash-high→claude-haiku-5-5-high
<!-- tiers:summary:devin:end -->

<!-- tiers:summary:agy:start -->
top-plan: claude-opus-5-5-high(until 2026-11-26)
top-review: claude-opus-5-5-medium(until 2026-11-26)
top-critique: gemini-4-argon-high(until 2026-11-26)
execute: gemini-4-argon-medium(until 2026-11-26)→gemini-3.8-flash-high(until 2026-11-26)
mid(auto): gemini-4-argon-medium(until 2026-11-26)→gemini-3.8-flash-high(until 2026-11-26)
low(haiku): gemini-3.8-flash-high(until 2026-11-26)
<!-- tiers:summary:agy:end -->

**Edit:** pins live in `nng-kit/plugins/delegate/scripts/tiers.json`; prose lives here. Edit either, then run `bash scripts/sync-model-tiers.sh`.
