# evc-observe

Live status for `/execute-via-cursor` runs, shown beside the chat and never
fed into model context.

The skill runs Cursor's `agent -p --output-format stream-json` in the
background, writing `.claude/tmp/evc-run-<n>.ndjson`, `.err` and `.exit` under
the repo root. Every 2 s this mod:

1. picks the highest `<n>` in `<repo>/.claude/tmp`,
2. reads only the bytes past its last offset (`tail -c +N`), holding back a
   partial trailing line and capping each tick at ~4 MiB / ~20k lines,
3. folds each event into a bounded `Run` summary: session id, current tool,
   files edited, counters, a ≤200-entry timeline (repeats folded, assistant
   chunks merged), `result`, exit code, stderr tail.

## Pane layout

Desktop and terminal share the same tree (`Box` / `Text` / `Button` only):

- **Header card** — status badge (running / stalled / passed / failed),
  `evc #n`, elapsed, model, shortened session id
- **Counters** — `read · search · edit · shell · task · ✗`, plus an
  activity strip (not percent done)
- **Now** and **files** rows (up to 6 files, then `+k more`)
- **Timeline** — newest last; Compact shows the last rows that fit
  `bodyRows`, Full shows every stored entry (with `… N earlier entries
  dropped` when the bound trimmed history)
- **stderr** — behind a button when `.err` has content

### Buttons

| Button | Action |
| --- | --- |
| **Copy session id** | `$.ui.copy` of the run's session id |
| **Compact / Full** | toggles the timeline view atom |
| **Show / Hide stderr** | toggles the stderr panel (only when `errTail` is set) |

`/evc` reopens the pane. A toast fires when the run finishes.

PASS matches the skill's rule: `.exit` is 0 and the last `result` is
`success` with `is_error: false`. No growth for 90 s without an exit is shown
as stalled. Unknown event types are ignored, since the stream schema drifts.

## Fake stream / replay

`scripts/generate.ts` is a pure seeded generator (no imports) that tests
import. `scripts/fake-stream.ts` is the Node CLI (run from the nng-kit root):

```bash
# Write ~3 MB of NDJSON
node plugins/evc-observe/scripts/fake-stream.ts \
  --events 5000 --seed 1 --out /tmp/evc-fake.ndjson

# Live-replay into a repo's .claude/tmp (refuses if evc-run-<n>.* exists)
node plugins/evc-observe/scripts/fake-stream.ts \
  --replay /path/to/repo --n 900 --events 5000 --rate 250
```

Replay writes `evc-run-<n>.ndjson`, a couple of `.err` warnings, then `.exit`
`0`. Default `--n 900` sits above real run ids. Clean up only those files
afterwards — never `rm -rf .claude/`.

The contract with the skill is the file layout above; if the skill changes
its paths or flags, update `hooks/register.tsx` to match.
