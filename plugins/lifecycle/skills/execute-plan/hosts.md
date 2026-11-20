# Subagent hosts

Spawn every Task per the host (the tool running this session). Pins: [model-tiers.md](model-tiers.md).

- **claude-code:** `Task` with `model:` set to the tier's alias (`opus`, `sonnet`, `haiku`).
- **cursor:** `Task` with the resolved model slug.
- **devin:** `run_subagent` with `profile: kit-<role>`. Write: `kit-execute`, `kit-mid`, `kit-low`. Read-only (no shell: run each Task's commands here into `.claude/tmp/exec-claude-review-*`, pass paths): `kit-review-mid`, `kit-review-top`, `kit-critique` (`top-critique`). Install per the kit README. Profile not offered: stop and tell the user (`/critique plan`: fallback). The profile's `model:` is the resolved model; if it differs from `tiers.sh resolve devin <tier>` (read-only: `--role review`), warn once and log it.
- **agy:** resolve the tier's first unexpired pin in `agy models` (`tiers.sh resolve agy <tier>`, `--role review` for read-only). When that slug matches this session's model, use `invoke_subagent` with `Model: inherit`; otherwise spawn a `swarm` worker (`action: "add"`, `model: "<slug>"`, `workspace: "inherit"`, `brief: "<task>"`, then `action: "kill"` when done). Never use `flash_lite`/`flash`/`pro` to approximate a pin.

No Devin write top profile: on Devin, a `top` row with Files runs here if this session is top tier, else stop and tell the user. Never use a read-only or default profile for writes.

Any other host, or no way to pin the model: stop and tell the user before delegating (unattended: fail the row, report why).
