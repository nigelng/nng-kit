# Model tiers

Canonical ordered preference lists (`provider-model-version-effort`, left-to-right). Execution-map aliases: `opus` = `top`, `auto` = `mid`, `haiku` = `low`.

## Master chains

- **top (`opus`)**: `claude-opus-5-5-medium (all)` → `gemini-4-carbon-high (agy)` → `gemini-4-argon-high (agy)` → `gpt-6-astra-medium (devin)` → `grok-4-7-high (cursor)` → `cognition-swe-2-max (devin)`
- **mid (`auto`)**: `gpt-6-1-sol-high (devin)` → `cognition-swe-2-high (devin)` → `grok-4-7-high (cursor)` → `gemini-4-argon-medium (agy)` → `claude-sonnet-5-5-high (claude-code | agy)` *(+ `auto` last fallback on `cursor`)*
- **low (`haiku`)**: `gpt-6-1-terra-high (devin)` → `claude-haiku-5-5-high (claude-code)` → `composer-2-5 (cursor)` → `cognition-swe-2-medium (devin)` → `gemini-3-8-flash-high (agy)`

## Fallback

Filter the tier’s chain to the active tool; first available uncapped model wins. If `low` is exhausted → fall back to `mid` (never stall a wave). If `top` is exhausted → stop and ask. Avoid GPT models on Cursor.

## Per-tool resolution

- **claude-code:** `top` = `claude-opus-5-5` effort `medium` (`Task(model: "opus")`); `mid` = `claude-sonnet-5-5` effort `high` (`Task(model: "sonnet")`); `low` = `claude-haiku-5-5` effort `high` (`Task(model: "haiku")`). Always set `model:` explicitly on spawns.
- **cursor:** `top` = `claude-opus-5-5-medium` → `grok-4.7-high`; `mid` = `grok-4.7-high` → `auto`; `low` = `composer-2.5` (CLI uses dots in `4.7` / `2.5`; never GPT or Sonnet on Cursor).
- **agy** (Antigravity): `top` = `claude-opus-5-5-medium` → `gemini-4-carbon-high` → `gemini-4-argon-high` (subagent `Model: "inherit"` when parent session is top, else `"pro"`); `mid` = `gemini-4-argon-medium` → `claude-sonnet-5-5-high` (subagent `Model: "inherit"` when parent session is mid, else `"flash"`); `low` = `gemini-3.8-flash-high` (subagent `Model: "flash_lite"`).
- **devin:** `top` = `claude-opus-5-5-medium` → `gpt-6-astra-medium` → `swe-2-max`; `mid` = `gpt-6-1-sol-high` → `swe-2-high`; `low` = `gpt-6-1-terra-high` → `swe-2-medium` (Devin CLI strips the `cognition-` prefix on `swe-2-*`).

<!-- tiers:summary:start -->
top(opus): claude-opus-5-5-medium→gemini-4-carbon-high→gemini-4-argon-high→gpt-6-astra-medium→grok-4-7-high→cognition-swe-2-max; mid(auto): gpt-6-1-sol-high→cognition-swe-2-high→grok-4-7-high→gemini-4-argon-medium→claude-sonnet-5-5-high (+auto on cursor); low(haiku): gpt-6-1-terra-high→claude-haiku-5-5-high→composer-2-5→cognition-swe-2-medium→gemini-3-8-flash-high
<!-- tiers:summary:end -->

**Edit:** change this file, then run `bash scripts/sync-model-tiers.sh`.
