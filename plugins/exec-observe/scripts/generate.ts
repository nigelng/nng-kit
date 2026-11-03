// Pure, seeded fake Cursor (`agent`) and Antigravity (`agy`) stream-json
// generator. No imports, no process — `claude plugin test` loads this from
// tests, and refuses any node: import.

export type GenerateBackend = 'cursor' | 'agy'
export type GenerateOutcome = 'pass' | 'fail' | 'print_timeout'
/** Live Antigravity streams nest step fields under `step_update`; `flat` keeps the legacy fixture shape. */
export type AgyEnvelope = 'nested' | 'flat'

export type GenerateOptions = {
  events?: number
  seed?: number
  backend?: GenerateBackend
  outcome?: GenerateOutcome
  finishReason?: string
  /** Default `nested` matches published `agy --output-format stream-json`. */
  agyEnvelope?: AgyEnvelope
}

type Rng = () => number

const mulberry32 = (seed: number): Rng => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const pick = <T>(rng: Rng, items: readonly T[]): T => items[Math.floor(rng() * items.length)]!

const pad = (_n: number, width: number): string => {
  let out = ''
  const chunk = 'lorem ipsum dolor sit amet consectetur adipiscing elit '
  while (out.length < width) out += chunk
  return out.slice(0, width)
}

const FILES = Array.from({ length: 40 }, (_, i) => `/repo/src/module-${String(i).padStart(2, '0')}.ts`)

const line = (value: unknown): string => JSON.stringify(value)

const generateCursor = (
  events: number,
  seed: number,
  outcome: GenerateOutcome,
  finishReason?: string,
): string[] => {
  const rng = mulberry32(seed >>> 0)
  const out: string[] = []
  let callId = 0

  const nextId = () => {
    callId += 1
    return `c${callId}`
  }

  out.push(
    line({
      type: 'system',
      subtype: 'init',
      session_id: `sess-fake-${seed}`,
      model: 'gpt-5.1',
      cwd: '/repo',
    }),
  )

  for (let i = 0; i < 5; i++) {
    out.push(
      line({
        type: 'assistant',
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: `Streaming thought chunk ${i + 1}. ` }],
        },
      }),
    )
  }

  out.push(line({ type: 'thinking', delta: 'planning the next tools' }))

  // Two malformed lines near the start so badLines stays visible.
  out.push('{not valid json')
  out.push('also-not-json')

  const payload = (scale: number) => pad(0, Math.floor(550 + rng() * 1000 * scale))

  const readBurst = (n: number) => {
    for (let i = 0; i < n; i++) {
      const id = nextId()
      const path = pick(rng, FILES)
      const tool = pick(rng, ['read', 'glob', 'ls'] as const)
      const key = `${tool}ToolCall`
      out.push(
        line({
          type: 'tool_call',
          subtype: 'started',
          call_id: id,
          tool_call: { [key]: { args: tool === 'glob' ? { pattern: '**/*.ts' } : { path } } },
        }),
      )
      out.push(
        line({
          type: 'tool_call',
          subtype: 'completed',
          call_id: id,
          tool_call: {
            [key]: {
              args: tool === 'glob' ? { pattern: '**/*.ts' } : { path },
              result: { content: payload(1) },
            },
          },
        }),
      )
    }
  }

  const searchBurst = (n: number) => {
    for (let i = 0; i < n; i++) {
      const id = nextId()
      const pattern = pick(rng, ['TODO', 'export', 'reduceLine', 'exec-observe'])
      out.push(
        line({
          type: 'tool_call',
          subtype: 'started',
          call_id: id,
          tool_call: { grepToolCall: { args: { pattern } } },
        }),
      )
      out.push(
        line({
          type: 'tool_call',
          subtype: 'completed',
          call_id: id,
          tool_call: {
            grepToolCall: { args: { pattern }, result: { content: payload(1.2) } },
          },
        }),
      )
    }
  }

  const editOne = (path: string) => {
    const id = nextId()
    out.push(
      line({
        type: 'tool_call',
        subtype: 'started',
        call_id: id,
        tool_call: { editToolCall: { args: { path } } },
      }),
    )
    out.push(
      line({
        type: 'tool_call',
        subtype: 'completed',
        call_id: id,
        tool_call: { editToolCall: { args: { path }, result: {} } },
      }),
    )
  }

  const shellOne = (command: string, fail: boolean) => {
    const id = nextId()
    out.push(
      line({
        type: 'tool_call',
        subtype: 'started',
        call_id: id,
        tool_call: { shellToolCall: { args: { command } } },
      }),
    )
    out.push(
      line({
        type: 'tool_call',
        subtype: 'completed',
        call_id: id,
        tool_call: {
          shellToolCall: {
            args: { command },
            result: fail
              ? { is_error: true, error: 'exit 1', exitCode: 1, content: 'failed' }
              : { content: pad(0, command.length > 40 ? 900 : 120) },
          },
        },
      }),
    )
  }

  // Fill a body, then always append the closing sequence (failing shell, task,
  // final assistant, result) so a length trim never drops them.
  const closingBudget = 10
  while (out.length < events - closingBudget) {
    const roll = rng()
    if (roll < 0.45) readBurst(2 + Math.floor(rng() * 4))
    else if (roll < 0.65) searchBurst(1 + Math.floor(rng() * 3))
    else if (roll < 0.8) editOne(pick(rng, FILES))
    else if (roll < 0.9) {
      const long = rng() < 0.3
      shellOne(
        long ? 'yarn test --coverage && nix flake check' : pick(rng, ['ls', 'pwd', 'git status']),
        false,
      )
    } else {
      out.push(
        line({
          type: 'assistant',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: `Working through step ${out.length}. ` }],
          },
        }),
      )
    }
    if (out.length > events * 2) break
  }

  // Ensure ~40 distinct edits appear somewhere in the body.
  for (const path of FILES) {
    if (out.length >= events - closingBudget) break
    editOne(path)
  }

  const body = out.slice()
  const closing: string[] = []
  const pushClosing = (row: string) => {
    closing.push(row)
  }

  {
    const id = nextId()
    pushClosing(
      line({
        type: 'tool_call',
        subtype: 'started',
        call_id: id,
        tool_call: { shellToolCall: { args: { command: 'false' } } },
      }),
    )
    pushClosing(
      line({
        type: 'tool_call',
        subtype: 'completed',
        call_id: id,
        tool_call: {
          shellToolCall: {
            args: { command: 'false' },
            result: { is_error: true, error: 'exit 1', exitCode: 1, content: 'failed' },
          },
        },
      }),
    )
  }

  {
    const taskId = nextId()
    pushClosing(
      line({
        type: 'tool_call',
        subtype: 'started',
        call_id: taskId,
        tool_call: { taskToolCall: { args: { description: 'explore reducer' } } },
      }),
    )
    pushClosing(
      line({
        type: 'tool_call',
        subtype: 'completed',
        call_id: taskId,
        tool_call: {
          taskToolCall: { args: { description: 'explore reducer' }, result: { content: 'done' } },
        },
      }),
    )
  }

  pushClosing(
    line({
      type: 'assistant',
      message: {
        role: 'assistant',
        content: [{ type: 'text', text: 'All fake steps complete.' }],
      },
    }),
  )

  const isError = outcome !== 'pass' || (finishReason !== undefined && finishReason !== 'success')
  const subtype =
    finishReason ??
    (outcome === 'print_timeout' ? 'print_timeout' : outcome === 'fail' ? 'error' : 'success')

  pushClosing(
    line({
      type: 'result',
      subtype,
      is_error: isError,
      duration_ms: 185_000,
      result: 'Fake stream finished.',
    }),
  )

  const room = Math.max(0, events - closing.length)
  const trimmedBody = body.length > room ? body.slice(0, room) : body
  const combined = [...trimmedBody, ...closing]
  while (combined.length < events) {
    combined.splice(
      combined.length - closing.length,
      0,
      line({
        type: 'assistant',
        message: { role: 'assistant', content: [{ type: 'text', text: 'padding ' }] },
      }),
    )
  }
  return combined.length > events
    ? combined.slice(0, events - closing.length).concat(closing)
    : combined
}

const generateAgy = (
  events: number,
  seed: number,
  outcome: GenerateOutcome,
  finishReason: string | undefined,
  envelope: AgyEnvelope,
): string[] => {
  const rng = mulberry32(seed >>> 0)
  const out: string[] = []
  const conversationId = `conv-fake-${seed}`
  let stepIndex = 0

  const pushStep = (fields: Record<string, unknown>, state: 'ACTIVE' | 'DONE' = 'DONE') => {
    const body = {
      conversation_id: conversationId,
      step_index: stepIndex,
      state,
      ...fields,
    }
    stepIndex += 1
    if (envelope === 'flat') {
      out.push(line({ event: 'step_update', ...body }))
      return
    }
    out.push(line({ event: 'step_update', step_update: body }))
  }

  const pushClosingStep = (
    closing: string[],
    fields: Record<string, unknown>,
    state: 'ACTIVE' | 'DONE' = 'DONE',
  ) => {
    const body = {
      conversation_id: conversationId,
      step_index: stepIndex,
      state,
      ...fields,
    }
    stepIndex += 1
    if (envelope === 'flat') {
      closing.push(line({ event: 'step_update', ...body }))
      return
    }
    closing.push(line({ event: 'step_update', step_update: body }))
  }

  out.push(
    line({
      event: 'init',
      conversation_id: conversationId,
      model: 'gemini-2.5-pro',
      init: {
        conversation_id: conversationId,
        cwd: '/repo',
        permission_mode: 'dangerously_skip_permissions',
        model: 'gemini-2.5-pro',
      },
    }),
  )

  for (let i = 0; i < 5; i++) {
    pushStep({
      step_type: 'agent_response',
      text_delta: `Streaming thought chunk ${i + 1}. `,
    })
  }

  pushStep({ step_type: 'checkpoint', checkpoint_id: 'cp-1' })

  // Two malformed lines near the start so badLines stays visible.
  out.push('{not valid json')
  out.push('also-not-json')

  const payload = (scale: number) => pad(0, Math.floor(550 + rng() * 1000 * scale))

  const readBurst = (n: number) => {
    for (let i = 0; i < n; i++) {
      const path = pick(rng, FILES)
      const tool = pick(rng, ['read_file', 'view_file'] as const)
      pushStep({
        step_type: 'tool',
        tool_name: tool,
        tool_info: {
          name: tool,
          parameters: { path },
          output: payload(1),
        },
      })
    }
  }

  const searchBurst = (n: number) => {
    for (let i = 0; i < n; i++) {
      const pattern = pick(rng, ['TODO', 'export', 'reduceLine', 'exec-observe'])
      const tool = pick(rng, ['grep_search', 'find_by_name', 'glob_search'] as const)
      pushStep({
        step_type: 'tool',
        tool_name: tool,
        tool_info: {
          name: tool,
          parameters: { query: pattern, pattern },
          output: payload(1.2),
        },
      })
    }
  }

  const editOne = (path: string) => {
    const tool = pick(rng, ['edit_file', 'write_to_file', 'replace_file_content'] as const)
    pushStep({
      step_type: 'tool',
      tool_name: tool,
      tool_info: {
        name: tool,
        parameters: { target_file: path, path },
        output: 'ok',
      },
    })
  }

  const shellOne = (command: string, fail: boolean) => {
    pushStep({
      step_type: 'tool',
      tool_name: 'run_command',
      tool_info: {
        name: 'run_command',
        parameters: { command },
        output: fail ? 'failed' : pad(0, command.length > 40 ? 900 : 120),
        ...(fail
          ? { error: { type: 'command_failed', message: 'exit 1' } }
          : {}),
      },
    })
  }

  const closingBudget = 10
  while (out.length < events - closingBudget) {
    const roll = rng()
    if (roll < 0.45) readBurst(2 + Math.floor(rng() * 4))
    else if (roll < 0.65) searchBurst(1 + Math.floor(rng() * 3))
    else if (roll < 0.8) editOne(pick(rng, FILES))
    else if (roll < 0.9) {
      const long = rng() < 0.3
      shellOne(
        long ? 'yarn test --coverage && nix flake check' : pick(rng, ['ls', 'pwd', 'git status']),
        false,
      )
    } else {
      pushStep({
        step_type: 'agent_response',
        text_delta: `Working through step ${out.length}. `,
      })
    }
    if (out.length > events * 2) break
  }

  for (const path of FILES) {
    if (out.length >= events - closingBudget) break
    editOne(path)
  }

  const body = out.slice()
  const closing: string[] = []

  pushClosingStep(closing, {
    step_type: 'tool',
    tool_name: 'run_command',
    tool_info: {
      name: 'run_command',
      parameters: { command: 'false' },
      output: 'failed',
      error: { type: 'command_failed', message: 'exit 1' },
    },
  })

  pushClosingStep(closing, {
    step_type: 'tool',
    tool_name: 'browser_subagent',
    subagent_info: {
      subagents: [{ type_name: 'browser_subagent', role: 'explore reducer' }],
    },
  })

  pushClosingStep(closing, {
    step_type: 'agent_response',
    text_delta: 'All fake steps complete.',
  })

  const resolvedReason =
    finishReason ??
    (outcome === 'print_timeout' ? 'print_timeout' : outcome === 'fail' ? 'error' : 'stop')
  const status = outcome === 'fail' ? 'ERROR' : 'SUCCESS'

  if (envelope === 'flat') {
    closing.push(
      line({
        event: 'result',
        status,
        finished_reason: resolvedReason,
        duration_seconds: 185,
        result: {
          status,
          finished_reason: resolvedReason,
          duration_seconds: 185,
        },
      }),
    )
  } else {
    closing.push(
      line({
        event: 'result',
        result: {
          conversation_id: conversationId,
          status,
          finished_reason: resolvedReason,
          duration_seconds: 185,
        },
      }),
    )
  }

  const room = Math.max(0, events - closing.length)
  const trimmedBody = body.length > room ? body.slice(0, room) : body
  const combined = [...trimmedBody, ...closing]
  while (combined.length < events) {
    const padBody = {
      conversation_id: conversationId,
      step_index: stepIndex,
      state: 'DONE' as const,
      step_type: 'agent_response',
      text_delta: 'padding ',
    }
    stepIndex += 1
    const padLine =
      envelope === 'flat'
        ? line({ event: 'step_update', ...padBody })
        : line({ event: 'step_update', step_update: padBody })
    combined.splice(combined.length - closing.length, 0, padLine)
  }
  return combined.length > events
    ? combined.slice(0, events - closing.length).concat(closing)
    : combined
}

/**
 * Build a realistic Cursor (`agent`) or Antigravity (`agy`) `stream-json`
 * NDJSON as an array of lines. Two entries are deliberately malformed (not
 * JSON). Aimed size at `--events 5000` is roughly 2.5–3.5 MB.
 */
export const generateLines = (options: GenerateOptions = {}): string[] => {
  const events = Math.max(10, Math.floor(options.events ?? 100))
  const seed = (options.seed ?? 1) >>> 0
  const backend: GenerateBackend = options.backend ?? 'cursor'
  const outcome: GenerateOutcome = options.outcome ?? 'pass'
  const agyEnvelope: AgyEnvelope = options.agyEnvelope ?? 'nested'

  switch (backend) {
    case 'cursor':
      return generateCursor(events, seed, outcome, options.finishReason)
    case 'agy':
      return generateAgy(events, seed, outcome, options.finishReason, agyEnvelope)
    default: {
      const _exhaustive: never = backend
      return _exhaustive
    }
  }
}

export const generate = generateLines
