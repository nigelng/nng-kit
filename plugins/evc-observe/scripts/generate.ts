// Pure, seeded fake Cursor stream-json generator. No imports, no process —
// `claude plugin test` loads this from tests, and refuses any node: import.

export type GenerateOptions = { events: number; seed: number }

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

const pick = <T>(rng: Rng, items: T[]): T => items[Math.floor(rng() * items.length)]!

const pad = (n: number, width: number): string => {
  let out = ''
  const chunk = 'lorem ipsum dolor sit amet consectetur adipiscing elit '
  while (out.length < width) out += chunk
  return out.slice(0, width)
}

const FILES = Array.from({ length: 40 }, (_, i) => `/repo/src/module-${String(i).padStart(2, '0')}.ts`)

const line = (value: unknown): string => JSON.stringify(value)

/**
 * Build a realistic Cursor `stream-json` NDJSON as an array of lines.
 * Two entries are deliberately malformed (not JSON). Aimed size at
 * `--events 5000` is roughly 2.5–3.5 MB thanks to sized `result.content`.
 */
export const generate = (options: GenerateOptions): string[] => {
  const events = Math.max(10, Math.floor(options.events))
  const rng = mulberry32(options.seed >>> 0)
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
      session_id: `sess-fake-${options.seed}`,
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
      const pattern = pick(rng, ['TODO', 'export', 'reduceLine', 'evc-observe'])
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
      shellOne(long ? 'yarn test --coverage && nix flake check' : pick(rng, ['ls', 'pwd', 'git status']), false)
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
  pushClosing(
    line({
      type: 'result',
      subtype: 'success',
      is_error: false,
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
  return combined.length > events ? combined.slice(0, events - closing.length).concat(closing) : combined
}
