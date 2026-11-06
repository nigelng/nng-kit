// Google Antigravity (`agy --output-format stream-json`) event adapter.
import type { Run, TimelineKind } from '../../types'
import {
  addFile,
  appendMessage,
  closeMessage,
  baseName,
  durationMsOf,
  bumpCount,
  isObj,
  MODEL_MAX,
  oneLine,
  pushEntry,
  sanitize,
  SESSION_MAX,
  TOOL_MAX,
  type Obj,
} from '../reduce'

const AGY_TOOL_PATTERNS: readonly [RegExp, TimelineKind][] = [
  [/subagent/i, 'task'],
  [/read|view/i, 'read'],
  [/grep|search|find|glob/i, 'search'],
  [/write|edit|replace|create/i, 'edit'],
  [/run|command|shell|exec/i, 'shell'],
]

export const classifyAgyTool = (name: string): TimelineKind => {
  for (const [pattern, kind] of AGY_TOOL_PATTERNS) {
    if (pattern.test(name)) return kind
  }
  return 'tool'
}

const PATH_KEYS = [
  'path',
  'file_path',
  'filePath',
  'target_file',
  'targetFile',
  'file',
  'AbsolutePath',
  'TargetFile',
] as const

const DETAIL_KEYS = [
  'directory',
  'DirectoryPath',
  'command',
  'CommandLine',
  'pattern',
  'query',
  'Query',
  'description',
] as const

const BAD_FINISH_REASONS = new Set(['print_timeout', 'interrupted', 'error'])

const filePathOf = (params: Obj): string | null => {
  for (const key of PATH_KEYS) {
    const val = params[key]
    if (typeof val === 'string' && val.trim() !== '') return val
  }
  return null
}

const detailOfParams = (params: Obj): string | null => {
  const file = filePathOf(params)
  if (file) return baseName(file)
  for (const key of DETAIL_KEYS) {
    const val = params[key]
    if (typeof val === 'string' && val.trim() !== '') {
      return key.toLowerCase().includes('dir') ? baseName(val) : oneLine(val, 60)
    }
  }
  return null
}

// Live streams may send `error: { type, message }`; fixtures may send a string.
const hasToolError = (err: unknown): boolean => {
  if (typeof err === 'string') return err.trim() !== ''
  if (isObj(err)) {
    if (typeof err.message === 'string' && err.message.trim() !== '') return true
    if (typeof err.type === 'string' && err.type.trim() !== '') return true
    return false
  }
  return false
}

const onInit = (run: Run, event: Obj): Run => {
  const nested = isObj(event.init) ? event.init : null
  const sessionId =
    typeof event.conversation_id === 'string'
      ? event.conversation_id
      : nested && typeof nested.conversation_id === 'string'
        ? nested.conversation_id
        : run.sessionId
  const model =
    typeof event.model === 'string'
      ? event.model
      : nested && typeof nested.model === 'string'
        ? nested.model
        : run.model
  return {
    ...run,
    sessionId: sessionId ? sanitize(sessionId, SESSION_MAX) || run.sessionId : sessionId,
    model: model ? sanitize(model, MODEL_MAX) || run.model : model,
  }
}

// Names are classified at full length (an MCP tool's kind word can sit past
// the display cap), then capped at TOOL_MAX where they are shown.
const NAME_SCAN_MAX = 200

// A name counts only if something is left once it is cleaned: one made only of
// control or invisible characters falls through to the next source.
const cleanName = (value: unknown): string => (typeof value === 'string' ? oneLine(value, NAME_SCAN_MAX) : '')

const nameOf = (info: Obj, nameHint: string | null): string =>
  cleanName(info.name) || cleanName(nameHint) || 'tool'

const subagentNameOf = (info: Obj, nameHint: string | null): string => {
  const named = cleanName(info.name) || cleanName(nameHint)
  if (named) return named
  const subagents = info.subagents
  if (Array.isArray(subagents)) {
    for (const entry of subagents) {
      if (!isObj(entry)) continue
      const label = cleanName(entry.type_name) || cleanName(entry.role)
      if (label) return label
    }
  }
  return 'subagent'
}

const onToolStep = (
  run: Run,
  info: Obj,
  opts: { forceKind?: TimelineKind; nameHint?: string | null } = {},
): Run => {
  const fullName =
    opts.forceKind === 'task' ? subagentNameOf(info, opts.nameHint ?? null) : nameOf(info, opts.nameHint ?? null)
  const name = oneLine(fullName, TOOL_MAX)
  const params = isObj(info.parameters) ? info.parameters : isObj(info.args) ? info.args : {}
  const kind = opts.forceKind ?? classifyAgyTool(fullName)
  const file = filePathOf(params)
  const detail = detailOfParams(params)
  const failed = hasToolError(info.error)
  const files = kind === 'edit' && file ? addFile(run.files, file) : run.files
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

// ACTIVE tool/subagent steps update the live badge without counting.
const onToolActive = (
  run: Run,
  info: Obj,
  opts: { forceKind?: TimelineKind; nameHint?: string | null } = {},
): Run => {
  const name = oneLine(
    opts.forceKind === 'task' ? subagentNameOf(info, opts.nameHint ?? null) : nameOf(info, opts.nameHint ?? null),
    TOOL_MAX,
  )
  const params = isObj(info.parameters) ? info.parameters : isObj(info.args) ? info.args : {}
  return {
    ...run,
    tool: name,
    toolDetail: detailOfParams(params),
  }
}

const toolNameHint = (step: Obj): string | null =>
  typeof step.tool_name === 'string' ? step.tool_name : null

const applyToolOrSubagent = (open: Run, step: Obj, count: boolean): Run => {
  const run: Run = { ...closeMessage(open), doing: null }
  const nameHint = toolNameHint(step)
  if (isObj(step.tool_info)) {
    return count
      ? onToolStep(run, step.tool_info, { nameHint })
      : onToolActive(run, step.tool_info, { nameHint })
  }
  if (isObj(step.subagent_info)) {
    return count
      ? onToolStep(run, step.subagent_info, { forceKind: 'task', nameHint })
      : onToolActive(run, step.subagent_info, { forceKind: 'task', nameHint })
  }
  return run
}

// Live streams nest fields under `step_update`; fixtures may keep them flat.
const stepPayload = (event: Obj): Obj => (isObj(event.step_update) ? event.step_update : event)

const onStepUpdate = (run: Run, event: Obj): Run => {
  const step = stepPayload(event)
  const state = typeof step.state === 'string' ? step.state : null

  if (step.step_type === 'tool') {
    // Count once on DONE (or when state is absent, for flat fixtures).
    if (state === 'ACTIVE') return applyToolOrSubagent(run, step, false)
    if (state === null || state === 'DONE') return applyToolOrSubagent(run, step, true)
    return run
  }

  if (step.step_type === 'agent_response') {
    return typeof step.text_delta === 'string' && step.text_delta !== ''
      ? appendMessage(run, step.text_delta)
      : run
  }
  return run
}

const resolveResultField = (event: Obj, nested: Obj | null, key: string): unknown =>
  event[key] !== undefined ? event[key] : nested ? nested[key] : undefined

const subtypeOfResult = (isOk: boolean, status: string, finishedReason: string): string => {
  if (isOk) return 'success'
  if (BAD_FINISH_REASONS.has(finishedReason)) return finishedReason
  return oneLine(status, TOOL_MAX) || oneLine(finishedReason, TOOL_MAX) || 'failed'
}

const onResult = (run: Run, event: Obj): Run => {
  const nested = isObj(event.result) ? event.result : null
  const rawStatus = resolveResultField(event, nested, 'status')
  const rawReason = resolveResultField(event, nested, 'finished_reason')
  const rawDuration = resolveResultField(event, nested, 'duration_seconds')

  const status = typeof rawStatus === 'string' ? rawStatus : ''
  const finishedReason = typeof rawReason === 'string' ? rawReason : ''
  const isOk = status === 'SUCCESS' && !BAD_FINISH_REASONS.has(finishedReason)
  const durationMs = typeof rawDuration === 'number' ? durationMsOf(Math.round(rawDuration * 1000)) : null
  const subtype = subtypeOfResult(isOk, status, finishedReason)

  const withResult: Run = {
    ...run,
    tool: null,
    toolDetail: null,
    result: { isOk, subtype, durationMs },
    counts: bumpCount(run, 'result'),
  }
  return pushEntry(withResult, {
    kind: 'result',
    label: subtype,
    detail: null,
    count: 1,
    isOk,
  })
}

export const reduceAgyEvent = (run: Run, event: Obj): Run => {
  const eventKind = typeof event.event === 'string' ? event.event : event.type
  switch (eventKind) {
    case 'init':
      return onInit(run, event)
    case 'step_update':
      return onStepUpdate(run, event)
    case 'result':
      return onResult(run, event)
    default:
      return run
  }
}
