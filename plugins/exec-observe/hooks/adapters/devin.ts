// Devin (`devin --export`) ATIF-v1.7 adapter. The export is one pretty-printed
// JSON document written when the run ends, not a line stream. Unknown fields
// are ignored.
import type { Run, TimelineKind } from '../../types'
import {
  addFile,
  appendMessage,
  baseName,
  bumpCount,
  isObj,
  oneLine,
  pushEntry,
  sanitize,
  type Obj,
} from '../reduce'

const DEVIN_TOOL_PATTERNS: readonly [RegExp, TimelineKind][] = [
  [/subagent|\btask\b/i, 'task'],
  [/grep|search|find|glob/i, 'search'],
  [/read|view|list|\bls\b/i, 'read'],
  [/write|edit|replace|create|patch|delete/i, 'edit'],
  [/shell|bash|command|exec|\brun\b/i, 'shell'],
]

export const classifyDevinTool = (name: string): TimelineKind => {
  for (const [pattern, kind] of DEVIN_TOOL_PATTERNS) {
    if (pattern.test(name)) return kind
  }
  return 'tool'
}

const PATH_KEYS = ['path', 'file_path', 'filePath', 'target_file', 'targetFile', 'file'] as const

const DETAIL_KEYS = ['command', 'CommandLine', 'pattern', 'query', 'description'] as const

const filePathOf = (args: Obj): string | null => {
  for (const key of PATH_KEYS) {
    const val = args[key]
    if (typeof val === 'string' && val.trim() !== '') return val
  }
  return null
}

const detailOf = (args: Obj, file: string | null): string | null => {
  if (file) return sanitize(baseName(file), 60)
  for (const key of DETAIL_KEYS) {
    const val = args[key]
    if (typeof val === 'string' && val.trim() !== '') return oneLine(val, 60)
  }
  return null
}

const argsOf = (value: unknown): Obj => {
  if (isObj(value)) return value
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (trimmed.startsWith('{')) {
      try {
        const parsed: unknown = JSON.parse(trimmed)
        return isObj(parsed) ? parsed : {}
      } catch {
        return {}
      }
    }
  }
  return {}
}

const hasErrorValue = (value: unknown): boolean => {
  if (typeof value === 'string') return value.trim() !== ''
  if (value === true) return true
  return isObj(value)
}

const failedCallIds = (step: Obj): Set<string> => {
  const ids = new Set<string>()
  const observation = step.observation
  if (!isObj(observation) || !Array.isArray(observation.results)) return ids
  for (const result of observation.results) {
    if (!isObj(result) || !hasErrorValue(result.error)) continue
    const id = result.source_call_id
    if (typeof id === 'string' && id !== '') ids.add(id)
  }
  return ids
}

const MODEL_MAX = 64
const MODELS_MAX = 5
const SESSION_MAX = 64
const TOOL_MAX = 40
// Only these step sources are shown; anything else is a plain failure.
const SOURCES: ReadonlySet<string> = new Set(['user', 'system', 'agent'])

const modelsOf = (steps: readonly unknown[]): string | null => {
  const seen = new Set<string>()
  for (const step of steps) {
    if (seen.size >= MODELS_MAX) break
    if (!isObj(step) || typeof step.model_name !== 'string') continue
    const model = sanitize(step.model_name, MODEL_MAX)
    if (model !== '') seen.add(model)
  }
  return seen.size === 0 ? null : [...seen].join(', ')
}

const agentModelOf = (doc: Obj): string | null => {
  if (!isObj(doc.agent) || typeof doc.agent.model_name !== 'string') return null
  const model = sanitize(doc.agent.model_name, MODEL_MAX)
  return model === '' ? null : model
}

const failResult = (run: Run, subtype: string): Run => {
  const withResult: Run = {
    ...run,
    tool: null,
    toolDetail: null,
    result: { isOk: false, subtype, durationMs: null },
    counts: bumpCount(run, 'result'),
  }
  return pushEntry(withResult, {
    kind: 'result',
    label: subtype,
    detail: null,
    count: 1,
    isOk: false,
  })
}

const applyOneCall = (run: Run, call: Obj, failedIds: ReadonlySet<string>): Run => {
  const rawName =
    typeof call.function_name === 'string' && call.function_name.trim() !== ''
      ? call.function_name
      : typeof call.name === 'string'
        ? call.name
        : ''
  const name = sanitize(rawName, TOOL_MAX) || 'tool'
  const args = argsOf(call.arguments !== undefined ? call.arguments : call.args)
  const kind = classifyDevinTool(name)
  const file = filePathOf(args)
  const detail = detailOf(args, file)
  const id = typeof call.tool_call_id === 'string' ? call.tool_call_id : null
  const failed = (id !== null && failedIds.has(id)) || hasErrorValue(call.error)
  const shownFile = file ? sanitize(baseName(file), 60) : ''
  const files = kind === 'edit' && shownFile !== '' ? addFile(run.files, shownFile) : run.files
  const countsAfterKind = bumpCount(run, kind)
  const counts = failed ? { ...countsAfterKind, error: countsAfterKind.error + 1 } : countsAfterKind
  const withTool: Run = {
    ...run,
    tool: name,
    toolDetail: detail,
    tools: run.tools + 1,
    files,
    counts,
    failedTools: failed ? run.failedTools + 1 : run.failedTools,
  }
  return pushEntry(withTool, {
    kind,
    label: name,
    detail,
    count: 1,
    isOk: failed ? false : null,
  })
}

const applyToolCalls = (run: Run, step: Obj): Run => {
  if (!Array.isArray(step.tool_calls)) return run
  const failedIds = failedCallIds(step)
  let next = run
  for (const call of step.tool_calls) {
    if (!isObj(call)) continue
    next = applyOneCall(next, call, failedIds)
  }
  return next
}

const foldDevinDocument = (run: Run, doc: Obj): Run => {
  const steps = Array.isArray(doc.steps) ? doc.steps : []
  const docSession = typeof doc.session_id === 'string' ? sanitize(doc.session_id, SESSION_MAX) : ''
  const sessionId = docSession !== '' ? docSession : run.sessionId
  let next: Run = {
    ...run,
    sessionId,
    model: modelsOf(steps) ?? agentModelOf(doc),
    lines: steps.length,
  }

  for (const step of steps) {
    if (!isObj(step)) continue
    if (step.source === 'agent' && typeof step.message === 'string' && step.message.trim() !== '') {
      next = appendMessage(next, step.message)
    }
    next = applyToolCalls(next, step)
  }

  const last = steps.length > 0 ? steps[steps.length - 1] : null
  const source = isObj(last) && typeof last.source === 'string' ? last.source : ''
  const isOk = next.exitCode === 0 && source === 'agent'
  const subtype = isOk ? 'success' : source !== 'agent' && SOURCES.has(source) ? source : 'failed'
  const withResult: Run = {
    ...next,
    tool: null,
    toolDetail: null,
    result: { isOk, subtype, durationMs: null },
    counts: bumpCount(next, 'result'),
  }
  return pushEntry(withResult, {
    kind: 'result',
    label: isOk ? 'success' : subtype,
    detail: null,
    count: 1,
    isOk,
  })
}

// `text` null means the export file is missing. Anything that is not a JSON
// object (including a read that was refused for size) is unparseable.
export const applyDevinExport = (run: Run, text: string | null, exitCode: number | null): Run => {
  const base: Run = { ...run, exitCode }
  if (text === null) return failResult(base, 'missing export')
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return failResult(base, 'unparseable')
  }
  if (!isObj(parsed)) return failResult(base, 'unparseable')
  return foldDevinDocument(base, parsed)
}

export const EXPORT_TOO_LARGE = 'export too large'

// The export was over the size cap, so it was not read. Pass or fail comes from
// the exit code alone; a passed run keeps the note in its result.
export const applyOversizeDevinExport = (run: Run, exitCode: number | null): Run => {
  const base: Run = { ...run, exitCode }
  if (exitCode !== 0) return failResult(base, EXPORT_TOO_LARGE)
  const withResult: Run = {
    ...base,
    tool: null,
    toolDetail: null,
    result: { isOk: true, subtype: EXPORT_TOO_LARGE, durationMs: null },
    counts: bumpCount(base, 'result'),
  }
  return pushEntry(withResult, {
    kind: 'result',
    label: EXPORT_TOO_LARGE,
    detail: null,
    count: 1,
    isOk: true,
  })
}

export const DEVIN_EXPORT_MAX_BYTES = 4_194_304

// An empty or non-numeric `.exit` means the shell has not written the code yet.
export const devinExitCode = (exitText: string | null): number | null => {
  const text = (exitText ?? '').trim()
  return /^-?\d{1,6}$/.test(text) ? Number(text) : null
}

export type DevinInputs = {
  // Contents of `.exit`, or null when the file does not exist.
  exitText: string | null
  // Export size in bytes and contents, or nulls when the export is missing.
  exportSize: number | null
  exportText: string | null
  // Last time the run showed life before it exited: `now` while its `devin`
  // process is alive, else the newest `.out` / `.err` mtime. Undefined when
  // unknown (liveness could not be checked): the growth clock is refreshed, as
  // before, so a long silent run is not marked stalled.
  activityAt?: number
}

// What a tick knows: running until `.exit` holds a number, then a result from
// the export. A result already latched on the run is kept.
export const resolveDevinRun = (run: Run, input: DevinInputs, now: number): Run => {
  const code = devinExitCode(input.exitText)
  if (code === null) {
    if (input.activityAt === undefined) return { ...run, lastGrowthAt: now }
    // A killed task leaves no `.exit`: with no live process and no file
    // activity, the clock stops and `phaseOf` reports stalled after STALL_MS.
    const floor = run.startedAt ?? input.activityAt
    return { ...run, lastGrowthAt: Math.min(now, Math.max(input.activityAt, floor)) }
  }
  const next: Run = { ...run, exitCode: code }
  if (run.result !== null) return next
  const grown: Run = { ...next, lastGrowthAt: now }
  if (input.exportSize === null || input.exportText === null) return applyDevinExport(grown, null, code)
  if (input.exportSize > DEVIN_EXPORT_MAX_BYTES) return applyOversizeDevinExport(grown, code)
  return applyDevinExport(grown, input.exportText, code)
}
