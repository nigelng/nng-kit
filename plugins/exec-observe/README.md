# exec-observe

Live status for `/exec` runs of fleet plans, shown beside the chat and never
fed into model context. A run is either a Cursor run (`agent -p`) or an
Antigravity run (`agy -p`), driven by the `delegate` plugin.

The skill runs the backend CLI in the background, writing
`.claude/tmp/exec-run-<backend>-<n>.ndjson`, `.err` and `.exit` under the repo
root (where `<backend>` is `cursor` or `agy`). Every 2 s this mod:

1. picks the newest `exec-run-<backend>-<n>.ndjson` in `<repo>/.claude/tmp` by
   mtime (breaking ties by highest `<n>`),
2. reads only the bytes past its last offset (`tail -c +N`), holding back a
   partial trailing line and capping each tick at ~4 MiB / ~20k lines,
3. folds each event via the per-backend adapter (`hooks/adapters/cursor.ts` or
   `hooks/adapters/agy.ts`) into a bounded `Run` summary: backend, session id,
   current tool, files edited, counters, a ≤200-entry timeline (repeats folded,
   assistant chunks merged), `result`, exit code, stderr tail.

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install exec-observe@nng-kit
```

It watches runs started by `delegate` (`/delegate:execute-via-cursor` or
`/delegate:execute-via-agy`). The `delegate` plugin is needed to start a run,
and the backend CLI (Cursor `agent` or Antigravity `agy`) must be installed
for that run. See [delegate](../delegate/README.md).

## Pane layout

Desktop and terminal share the same tree (`Box` / `Text` / `Button` only):

- **Header card**: status badge (running / stalled / passed / failed),
  `exec #n [<backend>]`, elapsed, model, shortened session id
- **Counters**: `read · search · edit · shell · task · ✗`, plus an
  activity strip (not percent done)
- **Now** and **files** rows (up to 6 files, then `+k more`)
- **Timeline**: newest last. Compact shows the last rows that fit
  `bodyRows`; Full shows every stored entry (with `… N earlier entries
  dropped` when the bound trimmed history)
- **stderr**: behind a button when `.err` has content

### Buttons

| Button | Action |
| --- | --- |
| **Copy session id** | `$.ui.copy` of the run's session id |
| **Compact / Full** | toggles the timeline view atom |
| **Show / Hide stderr** | toggles the stderr panel (only when `errTail` is set) |

`/exec` reopens the pane. A toast fires when the run finishes.

PASS matches the skill's rule: `.exit` is 0 and the terminal `result` is a
clean success (Cursor `subtype: 'success'` with `is_error: false`; Antigravity
`status: 'SUCCESS'` without `finished_reason` in `print_timeout`, `interrupted`
or `error`). No growth for 90 s without an exit is shown as stalled. Unknown
event types are ignored, since the stream schema drifts.

## Fake stream / replay

`scripts/generate.ts` is a pure seeded generator (no imports) that tests
import (`generateLines({ backend: 'cursor' | 'agy', ... })`).
`scripts/fake-stream.ts` is the Node CLI (run from the nng-kit root):

```bash
# Write ~3 MB of Cursor or Antigravity NDJSON
node plugins/exec-observe/scripts/fake-stream.ts \
  --backend agy --events 5000 --seed 1 --out /tmp/exec-fake.ndjson

# Live-replay into a repo's .claude/tmp (refuses if exec-run-<backend>-<n>.* exists)
node plugins/exec-observe/scripts/fake-stream.ts \
  --backend agy --replay /path/to/repo --n 900 --events 5000 --rate 250

# Instant burst write into a scratch directory
node plugins/exec-observe/scripts/fake-stream.ts \
  --backend agy --dir /tmp/scratch --burst --n 900
```

Replay writes `exec-run-<backend>-<n>.ndjson`, a couple of `.err` warnings,
then `.exit` `0` (`1` when `--outcome fail`). Default `--n 900` sits above real
run ids. Clean up only those files afterwards, never `rm -rf .claude/`.

The contract with the skill is the file layout above; if the skill changes
its paths or flags, update `hooks/register.tsx` to match.
