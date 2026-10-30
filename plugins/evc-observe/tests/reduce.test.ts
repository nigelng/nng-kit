import { expect, test } from 'claude-code/testing'

import { completeLines, emptyRun, phaseOf, reduceLine, statusLine, utf8Bytes } from '../hooks/reduce'
import { generate } from '../scripts/generate.ts'

// Shape of `agent -p --output-format stream-json`, trimmed.
const STREAM = [
  { type: 'system', subtype: 'init', session_id: 'sess-123', model: 'gpt-5', cwd: '/repo' },
  { type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'Read the brief' }] } },
  { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'Reading the brief and plan now.' }] } },
  { type: 'tool_call', subtype: 'started', call_id: 'c1', tool_call: { readToolCall: { args: { path: '/repo/docs/plans/x.md' } } } },
  { type: 'tool_call', subtype: 'completed', call_id: 'c1', tool_call: { readToolCall: { args: { path: '/repo/docs/plans/x.md' }, result: {} } } },
  { type: 'tool_call', subtype: 'started', call_id: 'c2', tool_call: { editToolCall: { args: { path: '/repo/src/app.ts' } } } },
  { type: 'tool_call', subtype: 'completed', call_id: 'c2', tool_call: { editToolCall: { args: { path: '/repo/src/app.ts' }, result: {} } } },
  { type: 'tool_call', subtype: 'started', call_id: 'c3', tool_call: { shellToolCall: { args: { command: 'yarn test' } } } },
].map(line => JSON.stringify(line))

const RESULT = JSON.stringify({ type: 'result', subtype: 'success', is_error: false, duration_ms: 125000, result: 'All steps done.' })

const fold = (lines: string[]) => lines.reduce(reduceLine, { ...emptyRun(1), startedAt: 0, lastGrowthAt: 0 })

test('a running stream shows the current tool and edited files', async () => {
  const run = fold(STREAM)

  expect(run.sessionId).toBe('sess-123')
  expect(run.tool).toBe('shell')
  expect(run.toolDetail).toBe('yarn test')
  expect(run.tools).toBe(3)
  expect(run.files).toEqual(['app.ts'])
  expect(run.snippet).toBe('Reading the brief and plan now.')
  expect(phaseOf(run, 1000)).toBe('running')
  expect(statusLine(run, 61_000)).toBe('evc #1 ▸ shell yarn test · 3 tools · 1m01s')
})

test('pass needs exit 0 and a success result', async () => {
  const run = fold([...STREAM, RESULT])

  expect(phaseOf(run, 0)).toBe('passed')
  expect(phaseOf({ ...run, exitCode: 0 }, 0)).toBe('passed')
  expect(phaseOf({ ...run, exitCode: 1 }, 0)).toBe('failed')
  expect(phaseOf({ ...fold(STREAM), exitCode: 0 }, 0)).toBe('failed')
  expect(statusLine({ ...run, exitCode: 0 }, 0)).toBe('evc #1 ✓ done · 3 tools · 1 files · 2m05s')
})

test('a quiet stream with no exit reads as stalled', async () => {
  expect(phaseOf(fold(STREAM), 91_000)).toBe('stalled')
})

test('garbage and unknown events are counted, not fatal', async () => {
  const run = fold(['{not json', JSON.stringify({ type: 'thinking', delta: 'x' }), ...STREAM])

  expect(run.badLines).toBe(1)
  expect(run.tools).toBe(3)
})

test('a partial trailing line waits for the next read', async () => {
  const { lines, bytes } = completeLines('{"a":1}\n{"b":2}\n{"c":')

  expect(lines).toEqual(['{"a":1}', '{"b":2}'])
  expect(bytes).toBe(16)
  expect(utf8Bytes('é…😀\n')).toBe(2 + 3 + 4 + 1)
})

test('consecutive reads fold into N× read', async () => {
  const lines = Array.from({ length: 12 }, (_, i) => [
    JSON.stringify({
      type: 'tool_call',
      subtype: 'started',
      call_id: `r${i}`,
      tool_call: { readToolCall: { args: { path: `/repo/f${i}.ts` } } },
    }),
    JSON.stringify({
      type: 'tool_call',
      subtype: 'completed',
      call_id: `r${i}`,
      tool_call: { readToolCall: { args: { path: `/repo/f${i}.ts` }, result: {} } },
    }),
  ]).flat()

  const run = fold(lines)
  const reads = run.timeline.filter(e => e.kind === 'read')
  expect(reads).toHaveLength(1)
  expect(reads[0]?.count).toBe(12)
  expect(run.counts.read).toBe(12)
})

test('assistant chunks merge into one msg entry', async () => {
  const lines = ['one', 'two', 'three'].map(text =>
    JSON.stringify({
      type: 'assistant',
      message: { role: 'assistant', content: [{ type: 'text', text }] },
    }),
  )
  const run = fold(lines)
  const msgs = run.timeline.filter(e => e.kind === 'msg')
  expect(msgs).toHaveLength(1)
  expect(msgs[0]?.label).toContain('one')
  expect(msgs[0]?.label).toContain('three')
})

test('timeline stays at 200 and droppedEntries counts the rest', async () => {
  const lines = Array.from({ length: 250 }, (_, i) =>
    JSON.stringify({
      type: 'tool_call',
      subtype: 'started',
      call_id: `e${i}`,
      tool_call: { editToolCall: { args: { path: `/repo/file-${i}.ts` } } },
    }),
  )
  const run = fold(lines)
  expect(run.timeline.length).toBe(200)
  expect(run.droppedEntries).toBe(50)
  expect(run.tools).toBe(250)
})

test('a failed tool increments failedTools and marks the entry', async () => {
  const lines = [
    JSON.stringify({
      type: 'tool_call',
      subtype: 'started',
      call_id: 's1',
      tool_call: { shellToolCall: { args: { command: 'false' } } },
    }),
    JSON.stringify({
      type: 'tool_call',
      subtype: 'completed',
      call_id: 's1',
      tool_call: {
        shellToolCall: { args: { command: 'false' }, result: { is_error: true, error: 'exit 1' } },
      },
    }),
  ]
  const run = fold(lines)
  expect(run.failedTools).toBe(1)
  expect(run.timeline.some(e => e.isOk === false)).toBe(true)
})

test('a 5k-event stream stays bounded and serializes small', async () => {
  const lines = generate({ events: 5000, seed: 1 })
  const run = fold(lines)

  expect(run.timeline.length).toBeLessThanOrEqual(200)
  const toolKinds = run.counts.read + run.counts.search + run.counts.edit + run.counts.shell + run.counts.task + run.counts.tool
  expect(toolKinds).toBe(run.tools)
  expect(phaseOf({ ...run, exitCode: 0 }, 0)).toBe('passed')
  const size = JSON.stringify(run).length
  expect(size).toBeLessThan(64 * 1024)
})
