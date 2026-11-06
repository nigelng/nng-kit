// Cursor `agent --output-format stream-json` event adapter.
import type { Run, TimelineKind } from '../../types'
import {
  addFile,
  appendMessage,
  baseName,
  bumpCount,
  closeMessage,
  durationMsOf,
  finishMessage,
  isObj,
  MODEL_MAX,
  oneLine,
  pushEntry,
  sanitize,
  SESSION_MAX,
  TOOL_MAX,
  type Obj,
} from '../reduce'

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

// `tool_call: { editToolCall: { args: { path } } }` → `{ name: 'edit', args }`
const toolOf = (call: unknown): { name: string; args: Obj; result: unknown } | null => {
  if (!isObj(call)) return null
  const key = Object.keys(call).find(k => k.endsWith('ToolCall')) ?? Object.keys(call)[0]
  if (!key) return null
  const body = call[key]
  const args = isObj(body) && isObj(body.args) ? body.args : {}
  const result = isObj(body) ? body.result : undefined
  return { name: oneLine(key.replace(/ToolCall$/, '') || key, TOOL_MAX) || 'tool', args, result }
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

const onSystem = (run: Run, event: Obj): Run => {
  if (event.subtype !== 'init') return run
  return {
    ...run,
    sessionId: typeof event.session_id === 'string' ? sanitize(event.session_id, SESSION_MAX) || run.sessionId : run.sessionId,
    model: typeof event.model === 'string' ? sanitize(event.model, MODEL_MAX) || run.model : run.model,
  }
}

const onToolStarted = (run: Run, name: string, args: Obj): Run => {
  const kind = kindOf(name)
  const detail = detailOf(args)
  const withTool: Run = {
    ...closeMessage(run),
    doing: null,
    tool: name,
    toolDetail: detail,
    tools: run.tools + 1,
    counts: bumpCount(run, kind),
  }
  return pushEntry(withTool, {
    kind,
    label: name,
    detail,
    count: 1,
    isOk: null,
  })
}

const markToolFailed = (run: Run, name: string, args: Obj): Run => {
  const kind = kindOf(name)
  const detail = detailOf(args)
  const timeline = run.timeline.slice()
  const last = timeline[timeline.length - 1]
  const matchesLast =
    last !== undefined &&
    last.kind === kind &&
    (kind === 'read' || kind === 'search' || last.detail === detail)

  if (matchesLast) {
    timeline[timeline.length - 1] = { ...last, isOk: false }
    return {
      ...run,
      timeline,
      failedTools: run.failedTools + 1,
      counts: bumpCount(run, 'error'),
    }
  }
  return pushEntry(
    {
      ...run,
      failedTools: run.failedTools + 1,
      counts: bumpCount(run, 'error'),
    },
    {
      kind: 'error',
      label: name,
      detail,
      count: 1,
      isOk: false,
    },
  )
}

const onToolCompleted = (run: Run, name: string, args: Obj, result: unknown): Run => {
  const path = args.path ?? args.filePath ?? args.file_path
  const files = WRITES.test(name) && typeof path === 'string' ? addFile(run.files, path) : run.files
  const cleared: Run = { ...run, tool: null, toolDetail: null, files }
  return resultFailed(result) ? markToolFailed(cleared, name, args) : cleared
}

const onToolCall = (run: Run, event: Obj): Run => {
  const tool = toolOf(event.tool_call)
  if (!tool) return run
  if (event.subtype === 'started') return onToolStarted(run, tool.name, tool.args)
  if (event.subtype === 'completed') return onToolCompleted(run, tool.name, tool.args, tool.result)
  return run
}

const onResult = (run: Run, event: Obj): Run => {
  const isOk = event.subtype === 'success' && event.is_error !== true
  const subtype = (typeof event.subtype === 'string' ? oneLine(event.subtype, TOOL_MAX) : '') || 'unknown'
  const snippet =
    typeof event.result === 'string' && event.result.trim() !== '' ? oneLine(event.result) : run.snippet
  const withResult: Run = {
    ...closeMessage(run),
    doing: null,
    tool: null,
    toolDetail: null,
    result: {
      isOk,
      subtype,
      durationMs: durationMsOf(event.duration_ms),
    },
    snippet,
    counts: bumpCount(run, 'result'),
  }
  return pushEntry(withResult, {
    kind: 'result',
    label: isOk ? 'success' : subtype !== 'unknown' ? subtype : 'failed',
    detail: null,
    count: 1,
    isOk,
  })
}

export const reduceCursorEvent = (run: Run, event: Obj): Run => {
  switch (event.type) {
    case 'system':
      return onSystem(run, event)
    case 'assistant': {
      const text = textOf(event.message)
      if (!text) return run
      // With --stream-partial-output, deltas carry no model_call_id and the
      // closing full message does; without it, every message is whole.
      return typeof event.model_call_id === 'string' ? finishMessage(run, text) : appendMessage(run, text)
    }
    case 'thinking':
      return { ...closeMessage(run), doing: 'thinking' }
    case 'tool_call':
      return onToolCall(run, event)
    case 'result':
      return onResult(run, event)
    default:
      return run
  }
}
