import { expect, test } from 'claude-code/testing'

import {
  classifyAgyTool,
  completeLines,
  emptyRun,
  paneTitle,
  phaseOf,
  pickNewestRunFile,
  reduceLine,
  statusLine,
  utf8Bytes,
} from '../hooks/reduce'
import { generate, generateLines } from '../scripts/generate.ts'
import type { Backend } from '../types'

// Shape of `agent -p --output-format stream-json`, trimmed.
const STREAM = [
  { type: 'system', subtype: 'init', session_id: 'sess-123', model: 'gpt-5', cwd: '/repo' },
  { type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'Read the brief' }] } },
  {
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'text', text: 'Reading the brief and plan now.' }] },
  },
  {
    type: 'tool_call',
    subtype: 'started',
    call_id: 'c1',
    tool_call: { readToolCall: { args: { path: '/repo/docs/plans/x.md' } } },
  },
  {
    type: 'tool_call',
    subtype: 'completed',
    call_id: 'c1',
    tool_call: { readToolCall: { args: { path: '/repo/docs/plans/x.md' }, result: {} } },
  },
  {
    type: 'tool_call',
    subtype: 'started',
    call_id: 'c2',
    tool_call: { editToolCall: { args: { path: '/repo/src/app.ts' } } },
  },
  {
    type: 'tool_call',
    subtype: 'completed',
    call_id: 'c2',
    tool_call: { editToolCall: { args: { path: '/repo/src/app.ts' }, result: {} } },
  },
  {
    type: 'tool_call',
    subtype: 'started',
    call_id: 'c3',
    tool_call: { shellToolCall: { args: { command: 'yarn test' } } },
  },
].map(line => JSON.stringify(line))

const RESULT = JSON.stringify({
  type: 'result',
  subtype: 'success',
  is_error: false,
  duration_ms: 125000,
  result: 'All steps done.',
})

const fold = (lines: string[], backend: Backend = 'cursor', n = 1) =>
  lines.reduce(reduceLine, { ...emptyRun(n, backend), startedAt: 0, lastGrowthAt: 0 })

test('a running stream shows the current tool and edited files', async () => {
  const run = fold(STREAM)

  expect(run.backend).toBe('cursor')
  expect(run.sessionId).toBe('sess-123')
  expect(run.tool).toBe('shell')
  expect(run.toolDetail).toBe('yarn test')
  expect(run.tools).toBe(3)
  expect(run.files).toEqual(['app.ts'])
  expect(run.snippet).toBe('Reading the brief and plan now.')
  expect(phaseOf(run, 1000)).toBe('running')
  expect(statusLine(run, 61_000)).toBe('exec #1 [cursor] ▸ shell yarn test · 3 tools · 1m01s')
})

test('pass needs exit 0 and a success result', async () => {
  const run = fold([...STREAM, RESULT])

  expect(phaseOf(run, 0)).toBe('passed')
  expect(phaseOf({ ...run, exitCode: 0 }, 0)).toBe('passed')
  expect(phaseOf({ ...run, exitCode: 1 }, 0)).toBe('failed')
  expect(phaseOf({ ...fold(STREAM), exitCode: 0 }, 0)).toBe('failed')
  expect(statusLine({ ...run, exitCode: 0 }, 0)).toBe(
    'exec #1 [cursor] ✓ done · 3 tools · 1 files · 2m05s',
  )
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
  const toolKinds =
    run.counts.read +
    run.counts.search +
    run.counts.edit +
    run.counts.shell +
    run.counts.task +
    run.counts.tool
  expect(toolKinds).toBe(run.tools)
  expect(phaseOf({ ...run, exitCode: 0 }, 0)).toBe('passed')
  const size = JSON.stringify(run).length
  expect(size).toBeLessThan(64 * 1024)
})

test('agy init sets sessionId and model from top-level or nested init object', async () => {
  const topLevel = fold(
    [
      JSON.stringify({
        event: 'init',
        conversation_id: 'conv-abc',
        model: 'gemini-2.5-pro',
        init: { cwd: '/repo', permission_mode: 'dangerously_skip_permissions' },
      }),
    ],
    'agy',
  )
  expect(topLevel.backend).toBe('agy')
  expect(topLevel.sessionId).toBe('conv-abc')
  expect(topLevel.model).toBe('gemini-2.5-pro')

  const nested = fold(
    [
      JSON.stringify({
        event: 'init',
        init: { conversation_id: 'conv-nested', model: 'gemini-2.5-flash', cwd: '/repo' },
      }),
    ],
    'agy',
  )
  expect(nested.sessionId).toBe('conv-nested')
  expect(nested.model).toBe('gemini-2.5-flash')
})

const nestedAgyStep = (
  fields: Record<string, unknown>,
  state: 'ACTIVE' | 'DONE' = 'DONE',
  stepIndex = 0,
) =>
  JSON.stringify({
    event: 'step_update',
    step_update: {
      conversation_id: 'conv-nested',
      step_index: stepIndex,
      state,
      ...fields,
    },
  })

test('agy step_update classifies tools across all categories and tracks edited files', async () => {
  expect(classifyAgyTool('read_file')).toBe('read')
  expect(classifyAgyTool('view_file_outline')).toBe('read')
  expect(classifyAgyTool('grep_search')).toBe('search')
  expect(classifyAgyTool('code_search')).toBe('search')
  expect(classifyAgyTool('find_by_name')).toBe('search')
  expect(classifyAgyTool('glob_files')).toBe('search')
  expect(classifyAgyTool('write_to_file')).toBe('edit')
  expect(classifyAgyTool('edit_file')).toBe('edit')
  expect(classifyAgyTool('replace_file_content')).toBe('edit')
  expect(classifyAgyTool('create_file')).toBe('edit')
  expect(classifyAgyTool('run_command')).toBe('shell')
  expect(classifyAgyTool('shell_exec')).toBe('shell')
  expect(classifyAgyTool('browser_subagent')).toBe('task')
  expect(classifyAgyTool('mcp_custom_action')).toBe('tool')

  // Flat fixture shape (compat): fields on the top-level event.
  const steps = [
    { name: 'read_file', parameters: { path: '/repo/README.md' } },
    { name: 'view_file', parameters: { AbsolutePath: '/repo/docs/plan.md' } },
    { name: 'grep_search', parameters: { query: 'reduceAgyEvent' } },
    { name: 'find_by_name', parameters: { pattern: '*.ts' } },
    { name: 'glob_files', parameters: { DirectoryPath: '/repo/src' } },
    { name: 'write_to_file', parameters: { TargetFile: '/repo/src/a.ts' } },
    { name: 'replace_file_content', parameters: { target_file: '/repo/src/b.ts' } },
    { name: 'run_command', parameters: { CommandLine: 'nix flake check' } },
    { name: 'browser_subagent', parameters: { description: 'inspect docs' } },
    { name: 'mcp_custom_action', parameters: { description: 'custom call' } },
  ].map(tool_info =>
    JSON.stringify({
      event: 'step_update',
      step_type: 'tool',
      tool_info,
    }),
  )

  const run = fold(steps, 'agy')
  expect(run.tools).toBe(10)
  expect(run.counts.read).toBe(2)
  expect(run.counts.search).toBe(3)
  expect(run.counts.edit).toBe(2)
  expect(run.counts.shell).toBe(1)
  expect(run.counts.task).toBe(1)
  expect(run.counts.tool).toBe(1)
  expect(run.files).toEqual(['b.ts', 'a.ts'])
})

test('agy nested step_update tool DONE classifies tools and tracks edited files', async () => {
  const steps = [
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'read_file',
        tool_info: { name: 'read_file', parameters: { path: '/repo/README.md' } },
      },
      'DONE',
      1,
    ),
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'write_to_file',
        tool_info: { name: 'write_to_file', parameters: { TargetFile: '/repo/src/a.ts' } },
      },
      'DONE',
      2,
    ),
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'replace_file_content',
        tool_info: {
          name: 'replace_file_content',
          parameters: { target_file: '/repo/src/b.ts' },
        },
      },
      'DONE',
      3,
    ),
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'run_command',
        tool_info: { name: 'run_command', parameters: { CommandLine: 'nix flake check' } },
      },
      'DONE',
      4,
    ),
  ]
  const run = fold(steps, 'agy')
  expect(run.tools).toBe(4)
  expect(run.counts.read).toBe(1)
  expect(run.counts.edit).toBe(2)
  expect(run.counts.shell).toBe(1)
  expect(run.files).toEqual(['b.ts', 'a.ts'])
})

test('agy nested ACTIVE then DONE does not double-count a tool', async () => {
  const lines = [
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'run_command',
        tool_info: { name: 'run_command', parameters: { CommandLine: 'echo hi' } },
      },
      'ACTIVE',
      4,
    ),
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'run_command',
        tool_info: {
          name: 'run_command',
          parameters: { CommandLine: 'echo hi' },
          output: 'hi\n',
        },
      },
      'DONE',
      4,
    ),
  ]
  const run = fold(lines, 'agy')
  expect(run.tools).toBe(1)
  expect(run.counts.shell).toBe(1)
  expect(run.timeline).toHaveLength(1)
  expect(run.tool).toBe('run_command')
  expect(run.toolDetail).toBe('echo hi')
})

test('agy nested agent_response text_delta chunks merge into a single msg entry', async () => {
  const lines = [
    nestedAgyStep(
      { step_type: 'agent_response', text_delta: 'Inspecting ' },
      'ACTIVE',
      2,
    ),
    nestedAgyStep(
      { step_type: 'agent_response', text_delta: 'the repository ' },
      'ACTIVE',
      2,
    ),
    nestedAgyStep(
      { step_type: 'agent_response', text_delta: 'layout now.' },
      'DONE',
      2,
    ),
  ]
  const run = fold(lines, 'agy')
  expect(run.counts.msg).toBe(1)
  const msgs = run.timeline.filter(e => e.kind === 'msg')
  expect(msgs).toHaveLength(1)
  expect(msgs[0]?.label).toContain('Inspecting')
  expect(msgs[0]?.label).toContain('layout now.')
  expect(run.snippet).toBe('layout now.')
})

test('agy nested subagent_info maps to task', async () => {
  const lines = [
    nestedAgyStep(
      {
        step_type: 'tool',
        tool_name: 'browser_subagent',
        subagent_info: {
          subagents: [{ type_name: 'browser_subagent', role: 'inspect docs' }],
        },
      },
      'DONE',
      7,
    ),
  ]
  const run = fold(lines, 'agy')
  expect(run.tools).toBe(1)
  expect(run.counts.task).toBe(1)
  expect(run.timeline[0]?.kind).toBe('task')
  expect(run.tool).toBe('browser_subagent')
})

test('agy failed tool sets isOk false and increments failedTools and counts.error', async () => {
  // Flat string error (compat).
  const flat = fold(
    [
      JSON.stringify({
        event: 'step_update',
        step_type: 'tool',
        tool_info: {
          name: 'run_command',
          parameters: { command: 'false' },
          output: '',
          error: 'Command exited with status 1',
        },
      }),
    ],
    'agy',
  )
  expect(flat.failedTools).toBe(1)
  expect(flat.counts.shell).toBe(1)
  expect(flat.counts.error).toBe(1)
  expect(flat.timeline).toHaveLength(1)
  expect(flat.timeline[0]?.isOk).toBe(false)

  // Nested error object `{ type, message }` (live stream).
  const nested = fold(
    [
      nestedAgyStep(
        {
          step_type: 'tool',
          tool_name: 'run_command',
          tool_info: {
            name: 'run_command',
            parameters: { CommandLine: 'false' },
            output: '',
            error: { type: 'command_failed', message: 'Command exited with status 1' },
          },
        },
        'DONE',
        5,
      ),
    ],
    'agy',
  )
  expect(nested.failedTools).toBe(1)
  expect(nested.counts.shell).toBe(1)
  expect(nested.counts.error).toBe(1)
  expect(nested.timeline[0]?.isOk).toBe(false)
})

test('agy agent_response text_delta chunks merge into a single msg entry', async () => {
  // Flat fixture shape (compat).
  const lines = ['Inspecting ', 'the repository ', 'layout now.'].map(text_delta =>
    JSON.stringify({
      event: 'step_update',
      step_type: 'agent_response',
      text_delta,
    }),
  )
  const run = fold(lines, 'agy')
  expect(run.counts.msg).toBe(1)
  const msgs = run.timeline.filter(e => e.kind === 'msg')
  expect(msgs).toHaveLength(1)
  expect(msgs[0]?.label).toContain('Inspecting')
  expect(msgs[0]?.label).toContain('layout now.')
  expect(run.snippet).toBe('layout now.')
})

test('agy result handles SUCCESS, ERROR, and print_timeout', async () => {
  const okRun = fold(
    [
      JSON.stringify({
        event: 'result',
        status: 'SUCCESS',
        finished_reason: 'stop',
        duration_seconds: 42.4,
      }),
    ],
    'agy',
    3,
  )
  expect(okRun.result).toEqual({ isOk: true, subtype: 'success', durationMs: 42_400 })
  expect(phaseOf({ ...okRun, exitCode: 0 }, 0)).toBe('passed')
  expect(statusLine({ ...okRun, exitCode: 0 }, 0)).toBe(
    'exec #3 [agy] ✓ done · 0 tools · 0 files · 42s',
  )

  const errRun = fold(
    [
      JSON.stringify({
        event: 'result',
        status: 'ERROR',
        finished_reason: 'api_error',
        duration_seconds: 12,
      }),
    ],
    'agy',
    4,
  )
  expect(errRun.result?.isOk).toBe(false)
  expect(errRun.result?.subtype).toBe('ERROR')
  expect(phaseOf({ ...errRun, exitCode: 0 }, 0)).toBe('failed')
  expect(statusLine({ ...errRun, exitCode: 0 }, 0)).toBe('exec #4 [agy] ✗ ERROR · 12s')

  const timeoutRun = fold(
    [
      JSON.stringify({
        event: 'result',
        result: {
          status: 'SUCCESS',
          finished_reason: 'print_timeout',
          duration_seconds: 300,
        },
      }),
    ],
    'agy',
    5,
  )
  expect(timeoutRun.result?.isOk).toBe(false)
  expect(timeoutRun.result?.subtype).toBe('print_timeout')
  expect(phaseOf({ ...timeoutRun, exitCode: 0 }, 0)).toBe('failed')
  expect(statusLine({ ...timeoutRun, exitCode: 0 }, 0)).toBe('exec #5 [agy] ✗ print_timeout · 5m00s')
})

test('agy unknown events and malformed lines are ignored cleanly', async () => {
  const lines = [
    '{bad json',
    'not-json-at-all',
    JSON.stringify({ event: 'unknown_future_event', foo: 'bar' }),
    JSON.stringify({ event: 'step_update', step_type: 'checkpoint', id: 'cp-1' }),
    JSON.stringify({ event: 'step_update', step_type: 'user_input', text: 'hello' }),
    JSON.stringify({ event: 'step_update', step_type: 'agent_response', text_delta: '   ' }),
    JSON.stringify({
      event: 'init',
      conversation_id: 'conv-clean',
      model: 'gemini-2.5-pro',
    }),
  ]
  const run = fold(lines, 'agy')
  expect(run.lines).toBe(7)
  expect(run.badLines).toBe(2)
  expect(run.sessionId).toBe('conv-clean')
  expect(run.timeline).toHaveLength(0)
})

test('generated agy stream reduces end-to-end across outcomes', async () => {
  const lines = generateLines({ backend: 'agy', events: 5000, seed: 1 })
  const run = fold(lines, 'agy')

  expect(run.backend).toBe('agy')
  expect(run.sessionId).toBe('conv-fake-1')
  expect(run.model).toBe('gemini-2.5-pro')
  expect(run.badLines).toBe(2)
  expect(run.timeline.length).toBeLessThanOrEqual(200)
  const toolKinds =
    run.counts.read +
    run.counts.search +
    run.counts.edit +
    run.counts.shell +
    run.counts.task +
    run.counts.tool
  expect(toolKinds).toBe(run.tools)
  expect(run.counts.read).toBeGreaterThan(0)
  expect(run.counts.search).toBeGreaterThan(0)
  expect(run.counts.edit).toBeGreaterThan(0)
  expect(run.counts.shell).toBeGreaterThan(0)
  expect(run.counts.task).toBeGreaterThan(0)
  expect(run.counts.error).toBeGreaterThan(0)
  expect(run.failedTools).toBeGreaterThanOrEqual(1)
  expect(run.files.length).toBe(6)
  expect(phaseOf({ ...run, exitCode: 0 }, 0)).toBe('passed')
  expect(JSON.stringify(run).length).toBeLessThan(64 * 1024)

  const failed = fold(generateLines({ backend: 'agy', events: 40, seed: 2, outcome: 'fail' }), 'agy')
  expect(failed.result?.isOk).toBe(false)
  expect(phaseOf({ ...failed, exitCode: 0 }, 0)).toBe('failed')

  const timedOut = fold(
    generateLines({ backend: 'agy', events: 40, seed: 3, outcome: 'print_timeout' }),
    'agy',
  )
  expect(timedOut.result?.isOk).toBe(false)
  expect(timedOut.result?.subtype).toBe('print_timeout')
  expect(phaseOf({ ...timedOut, exitCode: 0 }, 0)).toBe('failed')
})

test('pickNewestRunFile prefers newer mtime, tiebreaks by higher n, and ignores legacy/non-matching files', async () => {
  const legacyRunName = `${'evc'}-run-1.ndjson`
  const picked = pickNewestRunFile([
    { name: legacyRunName, mtimeMs: 9_999_999, size: 500 },
    { name: 'exec-run-cursor-5.ndjson', mtimeMs: 1_000, size: 1200 },
    { name: 'exec-run-agy-1.ndjson', mtimeMs: 2_000, size: 800 },
    { name: 'exec-run-agy-1.err', mtimeMs: 5_000, size: 50 },
    { name: 'exec-agy-brief.md', mtimeMs: 6_000, size: 300 },
  ])
  expect(picked?.name).toBe('exec-run-agy-1.ndjson')
  expect(picked?.backend).toBe('agy')
  expect(picked?.n).toBe(1)

  const tieBroken = pickNewestRunFile([
    { name: 'exec-run-cursor-2.ndjson', mtimeMs: 3_000, size: 100 },
    { name: 'exec-run-agy-7.ndjson', mtimeMs: 3_000, size: 100 },
    { name: 'exec-run-cursor-4.ndjson', mtimeMs: 3_000, size: 100 },
  ])
  expect(tieBroken?.name).toBe('exec-run-agy-7.ndjson')
  expect(tieBroken?.backend).toBe('agy')
  expect(tieBroken?.n).toBe(7)

  expect(
    pickNewestRunFile([
      { name: legacyRunName, mtimeMs: 1_000 },
      { name: 'exec-run-unknown-1.ndjson', mtimeMs: 2_000 },
      { name: 'notes.txt', mtimeMs: 3_000 },
    ]),
  ).toBeNull()

  expect(paneTitle('cursor')).toBe('Cursor run')
  expect(paneTitle('agy')).toBe('Antigravity run')
})
