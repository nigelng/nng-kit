# exec-observe

Status for `/exec` runs of fleet plans, shown beside the chat and never fed
into model context. A run is a Cursor run (`agent -p`), an Antigravity run
(`agy -p`), or a Devin run (`devin --print`), driven by the `delegate` plugin.

Cursor and Antigravity stream
`.claude/tmp/exec-run-<backend>-<n>.ndjson` (plus `.err` and `.exit`). Devin
does not stream: the shell creates `.claude/tmp/exec-run-devin-<n>.out` at
launch, and writes `exec-run-devin-<n>.json` (one ATIF document) when the run
ends, with `.err` and `.exit`. Every 2 s this mod:

1. picks the newest run file in `<repo>/.claude/tmp` by mtime (breaking ties
   by highest `<n>`): `exec-run-<backend>-<n>.ndjson` for Cursor and
   Antigravity, `exec-run-devin-<n>.out` for Devin,
2. for a streaming run, reads only the bytes past its last offset
   (`tail -c +N`), holding back a partial trailing line and capping each tick
   at ~4 MiB / ~20k lines,
3. for a Devin run, does not tail. Until `.exit` holds a number (it may be
   empty for a moment) the run shows as running. Then it reads
   `exec-run-devin-<n>.json` (capped at ~4 MiB on the read itself) and folds
   it. A missing or unparseable export is a failed result, not a crash. An
   export over the cap is not parsed: the exit code alone decides, and exit 0
   shows as passed with an `export too large` note. Model, session id, tool
   names and the last step `source` (`user`, `system`, `agent`; anything else is
   `failed`) are stripped of control characters and capped, since the export is
   written by an agent that auto-approves tools,
4. folds via the per-backend adapter (`hooks/adapters/cursor.ts`,
   `hooks/adapters/agy.ts`, or `hooks/adapters/devin.ts`) into a bounded `Run`
   summary: backend, session id, model, current tool, files edited, counters,
   a ≤200-entry timeline (repeats folded, assistant chunks merged), `result`,
   exit code, stderr tail.

Devin runs show a summary when the run ends (no live stream).

## Install

```bash
claude plugin marketplace add nigelng/nng-kit
claude plugin install exec-observe@nng-kit
```

It watches runs started by `delegate` (`/delegate:execute-via-cursor`,
`/delegate:execute-via-agy`, or `/delegate:execute-via-devin`). The `delegate`
plugin is needed to start a run, and the backend CLI (Cursor `agent`,
Antigravity `agy`, or Devin `devin`) must be installed for that run. See
[delegate](../delegate/README.md).

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

`/exec` reopens the pane. A toast fires when the run finishes. The pane opens
by itself only for a run that is still going or whose file changed in the last
minute, so an old finished run that becomes the newest again (for example after
a later Devin run's files are deleted) updates the status line without popping
the pane open.

PASS matches the skill's rule: `.exit` is 0 and the terminal `result` is a
clean success (Cursor `subtype: 'success'` with `is_error: false`; Antigravity
`status: 'SUCCESS'` without `finished_reason` in `print_timeout`, `interrupted`
or `error`; Devin's last step `source` is `agent`). A streaming run with no
growth for 90 s and no exit is shown as stalled. A Devin run with no `.exit`
stays running while its `devin` process is alive (found with `pgrep -f` on its
`--export=…exec-run-devin-<n>.json` argument); once the process is gone, its
clock follows the newest `.out` / `.err` change, so a killed run shows as
stalled after 90 s. If `pgrep` cannot run, a Devin run without `.exit` stays
running. Unknown event types are ignored, since the stream schema
drifts.

## Fake stream / replay

`scripts/generate.ts` is a pure seeded generator (no imports) that tests
import (`generateLines({ backend: 'cursor' | 'agy' | 'devin', ... })`).
Cursor and Antigravity return NDJSON lines. Devin returns one pretty-printed
ATIF-v1.7 document split into lines, not a live stream.
`scripts/fake-stream.ts` is the Node CLI for the streaming backends (run from
the nng-kit root):

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
