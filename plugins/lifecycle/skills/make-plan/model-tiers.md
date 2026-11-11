<!-- Generated from nng-kit/plugins/lifecycle/model-tiers.md. Do not edit. -->

## Fallback

Filter the tier’s chain to the active tool; first available uncapped model wins.
- **Expired rows (`until: YYYY-MM-DD`):** skip any row whose `until:` date has passed (`today > until`, local date) and log `fallback: expired <slug>`.
- **Parked rows (`status: parked`):** skip parked rows unless that backend's enable flag is set (none is defined today).
- **Planning fallback order:** Claude Code → Cursor → Devin → agy, handing off via `/relay:save` + `/relay:pickup`.
- **Routers:** Cursor `auto` (Cost mode, included pool) only (1) as the logged fallback for Cursor `execute`, `mid`, and `low` (existing triggers: the pin missing from `agent models`, a usage/quota error, or an explicit `model=auto`; record `fallback: <reason>`), or (2) on a map row with `Model: auto` + `Tier: low` + `Runner: delegate:cursor`, recorded `auto(router)`. Never on top or review work. Devin `adaptive` never: it costs more than the pins and has no pool advantage.
- **Tier exhaustion:** if `low` is exhausted → fall back to `mid` (never stall a wave). `top-plan` → next tool in the planning fallback order. `top-review` → stop and ask.
- **Review family:** a mid review pass prefers an allowed model from a different family than the implementer's; if the host has none at mid, proceed and log `same-family mid review` in the run notes. Top-review is unaffected.
- **Cursor model rule:** on Cursor, `execute`/`mid`/`low` use Cursor models only (Grok for `execute`/`mid` pins, Composer 2.5, Auto). Claude models only for `top-plan`/`top-review`, or by a manual `model=` override. Never GPT.

## Per-tool resolution

- **claude-code** (`status: active`):
  - `top-plan` (`status: active`) = `claude-opus-5-5` effort `high` (`--effort xhigh` for large/risky plans; `Task(model: "opus")`)
  - `top-review` (`status: active`) = `claude-opus-5-5` effort `medium` (`Task(model: "opus")`)
  - `execute` (`status: active`) = none (in-process `/execute-plan` uses the map tiers; no claude-code `execute` pin, so this resolves to `mid`)
  - `mid` (`status: active`) = `claude-sonnet-5-5` effort `high` (`Task(model: "sonnet")`)
  - `low` (`status: active`) = `claude-haiku-5-5` effort `high` (`Task(model: "haiku")`)
  - Always set `model:` explicitly on spawns.
- **cursor** (`status: active`; CLI uses dots in `4.7` / `2.5`; `execute`/`mid`/`low` use Cursor models only (Grok, Composer 2.5, Auto); Claude models only for `top-plan`/`top-review`, or by a manual `model=` override; never GPT):
  - `top-plan` (`status: active`) = `claude-opus-5-5-high`
  - `top-review` (`status: active`) = `claude-opus-5-5-medium` (`--mode=ask`)
  - `execute` (`status: active`) = `grok-4.7-high` → `auto` (logged fallback)
  - `mid` (`status: active`) = `grok-4.7-high` → `auto` (logged fallback)
  - `low` (`status: active`) = `composer-2.5` → `auto` (logged fallback)
- **devin** (`status: active`; pinned only for delegate execution (`execute`/`mid`/`low`): never `adaptive` or `fusion-*` there; Fusion only for `top-plan`/`top-review`; Devin CLI strips the `cognition-` prefix on `swe-2-*`):
  - `top-plan` (`status: active`) = `fusion-claude-opus-5-5-high-sidekick-swe-2-flash-max`
  - `top-review` (`status: active`) = `fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max`
  - `execute` (`status: active`) = `swe-2-high` (`until: 2026-11-30`) → `gpt-6-1-terra-high`
  - `mid` (`status: active`) = `gpt-6-1-sol-high` → `gemini-4-argon-medium` (`until: 2026-12-01`)
  - `low` (`status: active`) = `swe-2-flash-high` → `claude-haiku-5-5-high`
  - **Standalone Devin tasks** (guidance, not a resolver row): Fusion lead `gpt-6-1-sol-high` with sidekick `swe-2-medium` (`fusion-gpt-6-1-sol-high-sidekick-swe-2-medium`, `until: 2026-11-30`), then `gpt-6-1-terra-high` (`fusion-gpt-6-1-sol-high-sidekick-gpt-6-1-terra-high`); Adaptive (`adaptive`) only for ad-hoc interactive use.
  - Note: Flash is free until 2026-12-04, then priced the same as Haiku, so the order still holds.
- **agy** (Antigravity; `status: active`; `until: 2026-11-26`):
  - `top-plan` (`status: active`, `until: 2026-11-26`) = `claude-opus-5-5-high` (subagent `Model: "inherit"` when parent session is top, else `"pro"`)
  - `top-review` (`status: active`, `until: 2026-11-26`) = `claude-opus-5-5-medium` (`--mode plan`; subagent `Model: "inherit"` when parent session is top, else `"pro"`)
  - `top-critique` (`status: active`, `until: 2026-11-26`) = `gemini-4-argon-high`
  - `execute` (`status: active`, `until: 2026-11-26`) = `gemini-4-argon-medium` → `gemini-3.8-flash-high`
  - `mid` (`status: active`, `until: 2026-11-26`) = `gemini-4-argon-medium` → `gemini-3.8-flash-high` (subagent `Model: "inherit"` when parent session is mid, else `"flash"`)
  - `low` (`status: active`, `until: 2026-11-26`) = `gemini-3.8-flash-high` (subagent `Model: "flash_lite"`)
  - Claude only in `top-plan`/`top-review` (Claude + GPT quota group).

## Review runners

- `top@session` = the host session at `top-review`
- `top@claude-task` = `Task(model: "opus")` effort medium (read-only)
- `top@devin-fusion` = Devin `top-review` pin with `--permission-mode auto` (review only; never execution)
- `top@cursor-ask` = Cursor `top-review` pin with `--mode=ask`
- `top@agy-plan` = agy `top-review` pin with `--mode plan` (until 2026-11-26)

External runners (`top@devin-fusion`, `top@cursor-ask`, `top@agy-plan`) run through the delegate plugin's review launcher. They read the host's verify-script summary and never run Verification themselves, and they run under a git guard that reverts any reviewer edit. A reviewer failure (launch error, quota, timeout, guard trip, missing or inconsistent verdict) → stop and ask: retry, `top@claude-task`, or abort.

<!-- tiers:summary:start -->
top-plan: claude-opus-5-5-high→fusion-claude-opus-5-5-high-sidekick-swe-2-flash-max
top-review: claude-opus-5-5-medium→fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max
top-critique: gemini-4-argon-high(until 2026-11-26)
execute: grok-4-7-high→swe-2-high(until 2026-11-30)→gpt-6-1-terra-high→gemini-4-argon-medium(until 2026-11-26)
mid(auto): gpt-6-1-sol-high→gemini-4-argon-medium(until 2026-12-01)→grok-4-7-high→claude-sonnet-5-5-high
low(haiku): swe-2-flash-high→claude-haiku-5-5-high→composer-2-5→gemini-3-8-flash-high(until 2026-11-26)
<!-- tiers:summary:end -->
