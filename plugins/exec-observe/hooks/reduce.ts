// Shared core reducer and helpers. Cursor (`agent`) and Antigravity (`agy`)
// are `stream-json` lines. Devin is not a stream: its run file is
// `exec-run-devin-<n>.out`, and the ATIF export is folded separately when the
// run ends. Tolerant by design: unknown events and missing fields are ignored,
// since CLI schemas drift across versions.
import type { Backend, KindCounts, Run, TimelineEntry, TimelineKind } from '../types'
import { classifyAgyTool, reduceAgyEvent } from './adapters/agy'
import { kindOf, reduceCursorEvent } from './adapters/cursor'

export { classifyAgyTool, kindOf, reduceAgyEvent, reduceCursorEvent }

export const SNIPPET = 120
export const FILES = 6
export const TIMELINE_MAX = 200
export const MSG_MAX = 200
export const STALL_MS = 90_000
// Cursor and agy stream `.ndjson` from launch. Devin's `.out` exists from
// launch; `.json` / `.err` / `.exit` are not run anchors.
export const RUN_FILE = /^exec-run-(cursor|agy)-(\d+)\.ndjson$|^exec-run-devin-(\d+)\.out$/

export type Obj = Record<string, unknown>

export function isObj(value: unknown): value is Obj {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function emptyCounts(): KindCounts {
  return {
    msg: 0,
    read: 0,
    search: 0,
    edit: 0,
    shell: 0,
    task: 0,
    tool: 0,
    error: 0,
    result: 0,
  }
}

export function emptyRun(n: number, backend: Backend = 'cursor'): Run {
  return {
    n,
    backend,
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
  }
}

// Byte length of a UTF-8 encoding, so the read offset stays in bytes.
export function utf8Bytes(text: string): number {
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
export function completeLines(chunk: string): { lines: string[]; bytes: number } {
  const cut = chunk.lastIndexOf('\n')
  if (cut < 0) return { lines: [], bytes: 0 }
  const whole = chunk.slice(0, cut + 1)
  return {
    lines: whole.split('\n').filter(line => line.trim() !== ''),
    bytes: utf8Bytes(whole),
  }
}

const CONTROL_CHARS = /[\x00-\x1f\x7f-\x9f]/g

// Strips control characters and caps the length. For strings that come from a
// run's own output and are drawn in the pane, status line or toast.
export function sanitize(text: string, max: number): string {
  const clean = text.replace(CONTROL_CHARS, '').trim()
  return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean
}

export function oneLine(text: string, max = SNIPPET): string {
  return sanitize(text.replace(/\s+/g, ' '), max)
}

export function baseName(path: string): string {
  return path.split('/').filter(Boolean).pop() ?? path
}

export function addFile(files: string[], path: string): string[] {
  const name = baseName(path)
  return [name, ...files.filter(f => f !== name)].slice(0, FILES)
}

export function canFold(last: TimelineEntry, entry: TimelineEntry): boolean {
  if (last.kind !== entry.kind) return false
  if (last.isOk === false || entry.isOk === false) return false
  if (entry.kind === 'read' || entry.kind === 'search') return true
  if (entry.kind === 'edit' || entry.kind === 'shell') return last.detail === entry.detail
  return false
}

export function pushEntry(run: Run, entry: TimelineEntry): Run {
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

export function bumpCount(run: Run, kind: TimelineKind): KindCounts {
  return {
    ...run.counts,
    [kind]: run.counts[kind] + 1,
  }
}

export function appendMessage(run: Run, rawText: string): Run {
  const text = oneLine(rawText, MSG_MAX)
  if (!text) return run
  const snippet = oneLine(rawText)
  const last = run.timeline[run.timeline.length - 1]
  if (last?.kind === 'msg') {
    const merged = oneLine(`${last.label} ${text}`, MSG_MAX)
    const timeline = run.timeline.slice()
    timeline[timeline.length - 1] = { ...last, label: merged }
    return { ...run, snippet, timeline }
  }
  return pushEntry(
    { ...run, snippet, counts: bumpCount(run, 'msg') },
    { kind: 'msg', label: text, detail: null, count: 1, isOk: null },
  )
}

export function applyLine(run: Run, line: string): Run {
  let event: unknown
  try {
    event = JSON.parse(line)
  } catch {
    return { ...run, lines: run.lines + 1, badLines: run.badLines + 1 }
  }
  const next = { ...run, lines: run.lines + 1 }
  if (!isObj(event)) return next

  switch (run.backend) {
    case 'cursor':
      return reduceCursorEvent(next, event)
    case 'agy':
      return reduceAgyEvent(next, event)
    case 'devin':
      // Not a stream. register.tsx folds the ATIF export when the run ends.
      return next
    default: {
      const _exhaustive: never = run.backend
      return _exhaustive
    }
  }
}

export const reduceLine = applyLine

export function elapsed(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`
}

export type Phase = 'running' | 'stalled' | 'passed' | 'failed'

// PASS mirrors the skill's own rule: exit 0 and a success `result`.
export function phaseOf(run: Run, now: number): Phase {
  if (run.exitCode !== null) return run.exitCode === 0 && run.result?.isOk ? 'passed' : 'failed'
  if (run.result) return run.result.isOk ? 'passed' : 'failed'
  if (run.lastGrowthAt !== null && now - run.lastGrowthAt > STALL_MS) return 'stalled'
  return 'running'
}

const failureReason = (run: Run): string =>
  run.exitCode !== null && run.exitCode !== 0 ? `exit ${run.exitCode}` : run.result?.subtype ?? 'failed'

const doingLabel = (run: Run): string =>
  run.tool ? `${run.tool}${run.toolDetail ? ` ${run.toolDetail}` : ''}` : 'thinking'

export function statusLine(run: Run, now: number): string {
  const phase = phaseOf(run, now)
  const took = run.result?.durationMs ?? (run.startedAt !== null ? now - run.startedAt : null)
  const time = took !== null ? ` · ${elapsed(took)}` : ''
  const head = `exec #${run.n} [${run.backend}]`
  if (phase === 'passed') return `${head} ✓ done · ${run.tools} tools · ${run.files.length} files${time}`
  if (phase === 'failed') return `${head} ✗ ${failureReason(run)}${time}`
  const stall = phase === 'stalled' ? ' · quiet >90s' : ''
  return `${head} ▸ ${oneLine(doingLabel(run), 50)} · ${run.tools} tools${time}${stall}`
}

export function paneTitle(backend: Backend): string {
  switch (backend) {
    case 'cursor':
      return 'Cursor run'
    case 'agy':
      return 'Antigravity run'
    case 'devin':
      return 'Devin run'
    default: {
      const _exhaustive: never = backend
      return _exhaustive
    }
  }
}

// A new run id or backend, or a shrunken `.out` (the skill cleared tmp and
// rewrote it), means start over.
// Open the pane for a run only while it is still going, or when its anchor file
// changed recently. A finished run that becomes the newest again (for example
// after a later run's files are deleted) updates the status line but does not
// pop the pane open.
export const ANNOUNCE_FRESH_MS = 60_000

export const shouldAnnounce = (run: Run, anchorMtimeMs: number, now: number): boolean => {
  const phase = phaseOf(run, now)
  return phase === 'running' || phase === 'stalled' || now - anchorMtimeMs <= ANNOUNCE_FRESH_MS
}

export const isSwitchedRun = (
  current: { n: number; backend: Backend } | null,
  newest: { n: number; backend: Backend; size: number },
  offset: number,
): boolean =>
  current === null ||
  current.n !== newest.n ||
  current.backend !== newest.backend ||
  newest.size < offset

export type RunFileEntry = {
  name: string
  size?: number
  mtimeMs?: number
  mtime?: number
}

export type PickedRunFile<T extends RunFileEntry = RunFileEntry> = {
  entry: T
  name: string
  backend: Backend
  n: number
  size: number
  mtimeMs: number
  mtime: number
}

const mtimeOfEntry = (entry: RunFileEntry): number =>
  typeof entry.mtimeMs === 'number' ? entry.mtimeMs : typeof entry.mtime === 'number' ? entry.mtime : 0

export function pickNewestRunFile<T extends RunFileEntry>(entries: readonly T[]): PickedRunFile<T> | null {
  const matched: PickedRunFile<T>[] = []
  for (const entry of entries) {
    const m = RUN_FILE.exec(entry.name)
    if (!m) continue
    const backend = (m[1] ?? 'devin') as Backend
    const n = Number(m[1] !== undefined ? m[2] : m[3])
    if (!Number.isFinite(n)) continue
    const mtimeMs = mtimeOfEntry(entry)
    const size = typeof entry.size === 'number' ? entry.size : 0
    matched.push({ entry, name: entry.name, backend, n, size, mtimeMs, mtime: mtimeMs })
  }
  matched.sort((a, b) => b.mtimeMs - a.mtimeMs || b.n - a.n)
  return matched[0] ?? null
}
