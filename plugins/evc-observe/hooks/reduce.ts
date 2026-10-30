// Pure reducer over Cursor `agent --output-format stream-json` lines.
// Tolerant by design: unknown types and missing fields are ignored, since the
// schema drifts between Cursor CLI versions.
import type { KindCounts, Run, TimelineEntry, TimelineKind } from '../types'

const SNIPPET = 120
const FILES = 6
const TIMELINE_MAX = 200
const MSG_MAX = 200

export const emptyCounts = (): KindCounts => ({
  msg: 0,
  read: 0,
  search: 0,
  edit: 0,
  shell: 0,
  task: 0,
  tool: 0,
  error: 0,
  result: 0,
})

export const emptyRun = (n: number): Run => ({
  n,
  sessionId: null,
  model: null,
  tool: null,
  toolDetail: null,
  tools: 0,
  files: [],
  snippet: null,
  result: null,
  exitCode: null,
  errTail: null,
  lines: 0,
  badLines: 0,
  startedAt: null,
  lastGrowthAt: null,
  timeline: [],
  counts: emptyCounts(),
  failedTools: 0,
  droppedEntries: 0,
})

// Byte length of a UTF-8 encoding, so the read offset stays in bytes.
export const utf8Bytes = (text: string): number => {
  let bytes = 0
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i)
    if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff) {
      bytes += 4
      i++
    } else bytes += 3
  }
  return bytes
}

// Splits a chunk into complete lines and the bytes they cover; a trailing
// partial line is left for the next read.
export const completeLines = (chunk: string): { lines: string[]; bytes: number } => {
  const cut = chunk.lastIndexOf('\n')
  if (cut < 0) return { lines: [], bytes: 0 }
  const whole = chunk.slice(0, cut + 1)
  return {
    lines: whole.split('\n').filter(line => line.trim() !== ''),
    bytes: utf8Bytes(whole),
  }
}

const oneLine = (text: string, max = SNIPPET): string => {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat
}

const baseName = (path: string): string => path.split('/').filter(Boolean).pop() ?? path

type Obj = Record<string, unknown>
const isObj = (value: unknown): value is Obj =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

// `tool_call: { editToolCall: { args: { path } } }` → `{ name: 'edit', args }`
const toolOf = (call: unknown): { name: string; args: Obj; result: unknown } | null => {
  if (!isObj(call)) return null
  const key = Object.keys(call).find(k => k.endsWith('ToolCall')) ?? Object.keys(call)[0]
  if (!key) return null
  const body = call[key]
  const args = isObj(body) && isObj(body.args) ? body.args : {}
  const result = isObj(body) ? body.result : undefined
  return { name: key.replace(/ToolCall$/, '') || key, args, result }
}

const WRITES = /^(edit|write|delete|multiEdit|strReplace|applyPatch)/i

export const kindOf = (name: string): TimelineKind => {
  const n = name.toLowerCase()
  if (n === 'read' || n === 'ls' || n === 'glob') return 'read'
  if (n === 'grep' || n === 'search' || n === 'codebasesearch') return 'search'
  if (
    n === 'edit' ||
    n === 'write' ||
    n === 'delete' ||
    n === 'multiedit' ||
    n === 'applypatch' ||
    n === 'strreplace'
  )
    return 'edit'
  if (n === 'shell') return 'shell'
  if (n === 'task') return 'task'
  return 'tool'
}

const detailOf = (args: Obj): string | null => {
  for (const field of ['path', 'filePath', 'file_path', 'command', 'pattern', 'query', 'description']) {
    const value = args[field]
    if (typeof value === 'string' && value !== '') {
      return field.toLowerCase().includes('path') ? baseName(value) : oneLine(value, 60)
    }
  }
  return null
}

const textOf = (message: unknown): string | null => {
  if (!isObj(message)) return null
  const content = message.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return null
  const texts = content
    .filter(isObj)
    .filter(part => part.type === 'text' && typeof part.text === 'string')
    .map(part => part.text as string)
  return texts.length ? texts.join(' ') : null
}

const resultFailed = (result: unknown): boolean => {
  if (!isObj(result)) return false
  if (result.is_error === true) return true
  if (result.error != null && result.error !== false && result.error !== '') return true
  if (typeof result.exitCode === 'number' && result.exitCode !== 0) return true
  return false
}

const canFold = (last: TimelineEntry, entry: TimelineEntry): boolean => {
  if (last.kind !== entry.kind) return false
  if (entry.kind === 'read' || entry.kind === 'search') return true
  if (entry.kind === 'edit' || entry.kind === 'shell') return last.detail === entry.detail
  return false
}

const pushEntry = (run: Run, entry: TimelineEntry): Run => {
  const timeline = run.timeline.slice()
  const last = timeline[timeline.length - 1]
  if (last && canFold(last, entry)) {
    timeline[timeline.length - 1] = { ...last, count: last.count + 1 }
  } else {
    timeline.push(entry)
  }
  let droppedEntries = run.droppedEntries
  while (timeline.length > TIMELINE_MAX) {
    timeline.shift()
    droppedEntries += 1
  }
  return { ...run, timeline, droppedEntries }
}

const bumpCount = (run: Run, kind: TimelineKind): KindCounts => ({
  ...run.counts,
  [kind]: run.counts[kind] + 1,
})

export const reduceLine = (run: Run, line: string): Run => {
  let event: unknown
  try {
    event = JSON.parse(line)
  } catch {
    return { ...run, lines: run.lines + 1, badLines: run.badLines + 1 }
  }
  const next = { ...run, lines: run.lines + 1 }
  if (!isObj(event)) return next

  switch (event.type) {
    case 'system':
      if (event.subtype === 'init') {
        return {
          ...next,
          sessionId: typeof event.session_id === 'string' ? event.session_id : run.sessionId,
          model: typeof event.model === 'string' ? event.model : run.model,
        }
      }
      return next

    case 'assistant': {
      const text = textOf(event.message)
      if (!text) return next
      const snippet = oneLine(text)
      const last = next.timeline[next.timeline.length - 1]
      if (last?.kind === 'msg') {
        const merged = oneLine(`${last.label} ${text}`, MSG_MAX)
        const timeline = next.timeline.slice()
        timeline[timeline.length - 1] = { ...last, label: merged }
        return { ...next, snippet, timeline }
      }
      return pushEntry(
        { ...next, snippet, counts: bumpCount(next, 'msg') },
        { kind: 'msg', label: oneLine(text, MSG_MAX), detail: null, count: 1, isOk: null },
      )
    }

    case 'tool_call': {
      const tool = toolOf(event.tool_call)
      if (!tool) return next
      if (event.subtype === 'started') {
        const kind = kindOf(tool.name)
        const detail = detailOf(tool.args)
        const withTool = {
          ...next,
          tool: tool.name,
          toolDetail: detail,
          tools: run.tools + 1,
          counts: bumpCount(next, kind),
        }
        return pushEntry(withTool, {
          kind,
          label: tool.name,
          detail,
          count: 1,
          isOk: null,
        })
      }
      if (event.subtype === 'completed') {
        const path = tool.args.path ?? tool.args.filePath ?? tool.args.file_path
        const files =
          WRITES.test(tool.name) && typeof path === 'string'
            ? [baseName(path), ...run.files.filter(f => f !== baseName(path))].slice(0, FILES)
            : run.files
        let updated: Run = { ...next, tool: null, toolDetail: null, files }
        if (resultFailed(tool.result)) {
          const kind = kindOf(tool.name)
          const detail = detailOf(tool.args)
          const timeline = updated.timeline.slice()
          const last = timeline[timeline.length - 1]
          if (last && last.kind === kind && (kind === 'read' || kind === 'search' || last.detail === detail)) {
            timeline[timeline.length - 1] = { ...last, isOk: false }
            updated = {
              ...updated,
              timeline,
              failedTools: updated.failedTools + 1,
              counts: bumpCount(updated, 'error'),
            }
          } else {
            updated = pushEntry(
              {
                ...updated,
                failedTools: updated.failedTools + 1,
                counts: bumpCount(updated, 'error'),
              },
              {
                kind: 'error',
                label: tool.name,
                detail,
                count: 1,
                isOk: false,
              },
            )
          }
        }
        return updated
      }
      return next
    }

    case 'result': {
      const isOk = event.subtype === 'success' && event.is_error !== true
      const withResult: Run = {
        ...next,
        tool: null,
        toolDetail: null,
        result: {
          isOk,
          subtype: typeof event.subtype === 'string' ? event.subtype : 'unknown',
          durationMs: typeof event.duration_ms === 'number' ? event.duration_ms : null,
        },
        snippet:
          typeof event.result === 'string' && event.result.trim() !== ''
            ? oneLine(event.result)
            : run.snippet,
        counts: bumpCount(next, 'result'),
      }
      return pushEntry(withResult, {
        kind: 'result',
        label: isOk ? 'success' : typeof event.subtype === 'string' ? event.subtype : 'failed',
        detail: null,
        count: 1,
        isOk,
      })
    }

    default:
      return next
  }
}

export const elapsed = (ms: number): string => {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`
}

export const STALL_MS = 90_000

export type Phase = 'running' | 'stalled' | 'passed' | 'failed'

// PASS mirrors the skill's own rule: exit 0 and a success `result`.
export const phaseOf = (run: Run, now: number): Phase => {
  if (run.exitCode !== null) return run.exitCode === 0 && run.result?.isOk ? 'passed' : 'failed'
  if (run.result) return run.result.isOk ? 'passed' : 'failed'
  if (run.lastGrowthAt !== null && now - run.lastGrowthAt > STALL_MS) return 'stalled'
  return 'running'
}

export const statusLine = (run: Run, now: number): string => {
  const phase = phaseOf(run, now)
  const took = run.result?.durationMs ?? (run.startedAt !== null ? now - run.startedAt : null)
  const time = took !== null ? ` · ${elapsed(took)}` : ''
  const head = `evc #${run.n}`
  if (phase === 'passed') return `${head} ✓ done · ${run.tools} tools · ${run.files.length} files${time}`
  if (phase === 'failed') {
    const why = run.exitCode !== null && run.exitCode !== 0 ? `exit ${run.exitCode}` : run.result?.subtype ?? 'failed'
    return `${head} ✗ ${why}${time}`
  }
  const doing = run.tool ? `${run.tool}${run.toolDetail ? ` ${run.toolDetail}` : ''}` : 'thinking'
  const stall = phase === 'stalled' ? ' · quiet >90s' : ''
  return `${head} ▸ ${oneLine(doing, 50)} · ${run.tools} tools${time}${stall}`
}
