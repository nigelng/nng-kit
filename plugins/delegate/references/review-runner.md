# External review runner

Read only when a batch's **Review** is an external runner (table below), and by `/delegate:review`.
Covers the external-runner dispatch that core Step 7 item 5 delegates here; runner selection, brief
fill, `snapshot`/`check`/`verdict`, and reviewer-failure handling stay in
[execute-via-core.md](execute-via-core.md).

`<skill-dir>` is the calling `SKILL.md`'s directory; invoke scripts as
`bash <skill-dir>/../../scripts/<name>.sh` with the literal absolute path (same convention as core).

## Runner mapping and preflight

| Review value | `<runner>` | CLI | Model list |
| --- | --- | --- | --- |
| `top@claude-headless` | `claude-headless` | `claude` | none |
| `top@devin-fusion` | `devin-fusion` | `devin` | `devin models` |
| `top@cursor-ask` | `cursor-ask` | `agent` | `agent models` |
| `top@agy-plan` | `agy-plan` | `agy` | `agy models` |

Reviewer preflight — before `run`:

1. `which <CLI>`; missing, unauthenticated or at its usage limit → **reviewer failure** (core
   Step 8 `ok: false` handling — stop and ask).
2. The model is that tool's `top-review` pin from [model-tiers.md](model-tiers.md) (Devin
   `fusion-claude-opus-5-5-medium-sidekick-swe-2-flash-max`, Cursor and agy
   `claude-opus-5-5-medium`, Claude `claude-opus-5-5`). The table's model list must show it
   **exactly**, else **reviewer failure** (Claude: no list, skip).
3. agy past its `until:` date → refuse → **reviewer failure**.

## Run

`run` snapshots, launches the reviewer read-only, writes `.md`/`.err`/`.exit`, and runs `check`
internally — do **not** call `snapshot`/`check` yourself for an external runner:

```bash
bash <skill-dir>/../../scripts/delegate-review-launch.sh run <runner> /absolute/repo/root <rid> <model>
```

Run it in the background (`run_in_background: true`, same as a headless implement run). Wait for
the **background-task completion notification**; do not poll with `sleep`. `<model>` is the
preflighted `top-review` pin.

The reviewer reads the host verifier summary in the brief and **never runs Verification** itself.
After the run completes, core Step 7 item 5's shared `verdict` call produces the result JSON.
