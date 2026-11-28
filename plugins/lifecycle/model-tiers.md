# Model tiers

Canonical ordered preference lists (`provider-model-version-effort`, left-to-right). Map tiers: `top|execute|mid|low`. Aliases (`opus`, `auto`, `sonnet`, `haiku`) are refused. Per-tool rows are generated from `nng-kit/plugins/delegate/scripts/tiers.json`; rows may carry `until: YYYY-MM-DD`; a disabled tool is shown as `disabled` and gets no summary block. A tool-level `until` (shown in the tool's header) applies to every row of that tool.

**Roles:** `top-plan` = `/brainstorm`, `/make-plan` and `/critique plan` sessions (Claude Code: a `/make-plan` the user declares small may run at `mid` + advisor; see the Claude overlay). `top-review` = map tier `top`, the batch/final reviews, and `/critique` escalate + closing pass. The `/execute-plan` orchestrator is `mid` on a v2 map (`plan-status.sh rows --lint` exits 0), else `top-review`. `top-critique` (optional) = the `/critique plan` review Task (second family); absent or unpinnable → `top-review`. `execute` is a map tier: it resolves to the host's `execute` pin, else `mid`. Delegates default to it.

**Grunt-work rule:** `execute`/`low` use each tool's free or included models (Cursor Grok/Composer/Auto, Devin SWE-2.1 then GPT Terra, agy Hydrogen/Neon); Cursor `mid` implement adds `claude-sonnet-5-5-high` before `auto`. Review and top rows lead with Gemini Neon, then Sonnet (`mid` review), Opus (`top-plan`/`top-review`) or Fable (`top-critique`; agy Opus). Claude Code is exempt.

## Fallback

Resolve with `tiers.sh resolve <tool> <tier>` (`tiers.sh` = `bash <skill-dir>/../execute-plan/scripts/tiers.sh` in lifecycle skills, `bash <skill-dir>/../../scripts/tiers.sh` in delegate skills; `<host>` in skill preconditions is the registry id of the tool running the session, not `tiers.sh host`, which is only the default); the rows below are generated from the registry and follow these rules.
Spawn Tasks per the host: `<skill-dir>/../execute-plan/hosts.md`.
- **Expired rows (`until: YYYY-MM-DD`):** skip any row whose `until:` date has passed (`today > until`, local date) and log `fallback: expired <slug>`. A tool-level `until` (shown in the tool's header) applies to every row of that tool.
- **Planning fallback order:** per `tiers.sh order` (registry `planningOrder`), handing off via `/relay:save` + `/relay:pickup`.
- **Routers:** Cursor `auto` (Cost mode, included pool) only (1) as the logged fallback for Cursor `execute`, `mid`, and `low` (existing triggers: the pin missing from `agent models`, a usage/quota error, or an explicit `model=auto`; record `fallback: <reason>`), or (2) on a map row with `Model: auto` + `Tier: low` + `Runner: delegate:cursor`, recorded `auto(router)`. Never on top or review work. Devin `adaptive` never: it costs more than the pins and has no pool advantage.
- **Tier exhaustion:** if `low` is exhausted → fall back to `mid` (never stall a wave). After its in-row fallbacks, `top-plan` → next tool in the planning fallback order; `top-review` → `top@devin-fusion` when Devin is enabled and not the host, logged `fallback: top-review exhausted`; otherwise stop and ask. It resolves Devin `top-review` (Neon, then Fusion).
- **Review family:** a mid review pass prefers an allowed model from a different family than the implementer's; if the host has none at mid, proceed and log `same-family mid review` in the run notes. Cursor and Devin review with Neon, then Sonnet; agy (Gemini implementer) reviews with Sonnet first, and its Neon fallback logs `same-family mid review`. Top-review is unaffected.
- **Cursor model rule:** on Cursor, `execute`/`low` use Cursor models only (Grok, `composer-2.5`, never `-fast`, Auto); Claude and Gemini only on review, `top-*` and `mid` implement rows, or a manual `model=`. Never GPT.

## Per-tool resolution

<!-- tiers:generated:per-tool:start -->
- **claude-code** (Claude Code; cli `claude`; default review runner `top@claude-task`):
  - `top-plan` = `claude-opus-5-5` (effort high (xhigh for large/risky plans); Task(model: "opus")) → `claude-fable-5-2` (effort medium; Task(model: "fable"))
  - `top-review` = `claude-opus-5-5` (effort medium; Task(model: "opus"))
  - `top-critique` = `claude-fable-5-2` (effort medium; Task(model: "fable"))
  - `execute` = none (resolves to `mid`)
  - `mid` = `claude-sonnet-5-5` (effort high; Task(model: "sonnet"))
  - `low` = `claude-haiku-5-5` (effort high; Task(model: "haiku"))
- **cursor** (Cursor; cli `agent`; delegate; default review runner `top@claude-headless`):
  - `top-plan` = `gemini-4-neon-xhigh` → `claude-opus-5-5-high`
  - `top-review` = `gemini-4-neon-xhigh` (--mode=ask) → `claude-opus-5-5-high` (--mode=ask)
  - `top-critique` = `gemini-4-neon-xhigh` → `gemini-4-carbon-high` → `claude-fable-5-2-medium`
  - `execute` = `grok-4.7-high` → `auto` (logged fallback)
  - `mid` = implement: `grok-4.7-high` → `claude-sonnet-5-5-high` (Cursor third-party pool) → `auto` (logged fallback); review passes: `gemini-4-neon-high` → `claude-sonnet-5-5-high` (Cursor third-party pool)
  - `low` = `composer-2.5` (Standard tier; never composer-2.5-fast) → `auto` (logged fallback)
- **devin** (Devin; cli `devin`; delegate; default review runner `top@claude-headless`):
  - `top-plan` = `gemini-4-neon-xhigh` → `claude-opus-5-5-high` (plain Opus, no Fusion: planning exploration stays on the lead)
  - `top-review` = `gemini-4-neon-xhigh` → `fusion-claude-opus-5-5-high-sidekick-swe-2-1-medium`
  - `top-critique` = `gemini-4-neon-xhigh` → `gemini-4-carbon-high` → `claude-fable-5-2-medium`
  - `execute` = `swe-2-1-high` → `swe-2-1-medium` → `gpt-6-1-terra-high`
  - `mid` = implement: `swe-2-1-high` → `gpt-6-1-terra-high`; review passes: `gemini-4-neon-high` → `claude-sonnet-5-5-high`
  - `low` = `swe-2-1-medium` → `claude-haiku-5-5-high`
- **agy** (Antigravity; cli `agy`; delegate; default review runner `top@claude-headless`):
  - `top-plan` = `gemini-4-neon-xhigh` → `claude-opus-5-5-high`
  - `top-review` = `gemini-4-neon-xhigh` (--mode plan) → `claude-opus-5-5-high` (--mode plan)
  - `top-critique` = `gemini-4-neon-xhigh` → `gemini-4-carbon-high` → `claude-opus-5-5-high` (agy has no Fable)
  - `execute` = `gemini-4-hydrogen-high` → `gemini-4-neon-high`
  - `mid` = implement: `gemini-4-neon-high` → `gemini-4-hydrogen-high`; review passes: `claude-sonnet-5-5-high` (cross-family to the Gemini implementer) → `gemini-4-neon-high`
  - `low` = `gemini-4-hydrogen-medium`
<!-- tiers:generated:per-tool:end -->

<!-- tiers:tool-notes:start -->
- **claude-code:** Always set `model:` explicitly on spawns.
- **devin:** never `adaptive` or `fusion-*` for `execute`/`mid`/`low`; Fusion only for `top-review`; Devin CLI strips the `cognition-` prefix on `swe-2-*`.
  - **Standalone Devin tasks** (guidance, not a resolver row): Fusion lead GPT-6.2 Sol with sidekick SWE-2.1 (`fusion-gpt-6-2-sol-high-sidekick-swe-2-1-medium`, then `fusion-gpt-6-2-sol-medium-sidekick-swe-2-1-medium`); Adaptive (`adaptive`) only for ad-hoc interactive use.
- **agy:** Gemini first on every row except `mid` review (Sonnet); Claude otherwise only as fallback; no Argon or Fable.
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
top-plan: claude-opus-5-5→claude-fable-5-2
top-review: claude-opus-5-5
top-critique: claude-fable-5-2
execute: none
mid(auto): claude-sonnet-5-5
low(haiku): claude-haiku-5-5
<!-- tiers:summary:claude-code:end -->

<!-- tiers:summary:cursor:start -->
top-plan: gemini-4-neon-xhigh→claude-opus-5-5-high
top-review: gemini-4-neon-xhigh→claude-opus-5-5-high
top-critique: gemini-4-neon-xhigh→gemini-4-carbon-high→claude-fable-5-2-medium
execute: grok-4.7-high→auto
mid(auto): implement grok-4.7-high→claude-sonnet-5-5-high→auto; review gemini-4-neon-high→claude-sonnet-5-5-high
low(haiku): composer-2.5→auto
<!-- tiers:summary:cursor:end -->

<!-- tiers:summary:devin:start -->
top-plan: gemini-4-neon-xhigh→claude-opus-5-5-high
top-review: gemini-4-neon-xhigh→fusion-claude-opus-5-5-high-sidekick-swe-2-1-medium
top-critique: gemini-4-neon-xhigh→gemini-4-carbon-high→claude-fable-5-2-medium
execute: swe-2-1-high→swe-2-1-medium→gpt-6-1-terra-high
mid(auto): implement swe-2-1-high→gpt-6-1-terra-high; review gemini-4-neon-high→claude-sonnet-5-5-high
low(haiku): swe-2-1-medium→claude-haiku-5-5-high
<!-- tiers:summary:devin:end -->

<!-- tiers:summary:agy:start -->
top-plan: gemini-4-neon-xhigh→claude-opus-5-5-high
top-review: gemini-4-neon-xhigh→claude-opus-5-5-high
top-critique: gemini-4-neon-xhigh→gemini-4-carbon-high→claude-opus-5-5-high
execute: gemini-4-hydrogen-high→gemini-4-neon-high
mid(auto): implement gemini-4-neon-high→gemini-4-hydrogen-high; review claude-sonnet-5-5-high→gemini-4-neon-high
low(haiku): gemini-4-hydrogen-medium
<!-- tiers:summary:agy:end -->

**Edit:** pins live in `nng-kit/plugins/delegate/scripts/tiers.json`; prose lives here. Edit either, then run `bash scripts/sync-model-tiers.sh`.
