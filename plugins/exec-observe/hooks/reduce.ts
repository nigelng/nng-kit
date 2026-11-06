// Shared core reducer and helpers. Cursor (`agent`) and Antigravity (`agy`)
// are `stream-json` lines. Devin is not a stream: its run file is
// `exec-run-devin-<n>.out`, and the ATIF export is folded separately when the
// run ends. Tolerant by design: unknown events and missing fields are ignored,
// since CLI schemas drift across versions.
import type { Backend, KindCounts, Run, RunTask, TimelineEntry, TimelineKind } from '../types'
import { classifyAgyTool, reduceAgyEvent } from './adapters/agy'
import { kindOf, reduceCursorEvent } from './adapters/cursor'

export { classifyAgyTool, kindOf, reduceAgyEvent, reduceCursorEvent }

export const SNIPPET = 120
export const PATH_MAX = 60
export const MODEL_MAX = 64
export const SESSION_MAX = 64
export const TOOL_MAX = 40
export const FILES = 6
export const TIMELINE_MAX = 200
export const MSG_MAX = 200
export const MSG_RAW_MAX = 2000
export const LAST_MSG_MAX = 400
export const STALL_MS = 90_000
export const SPARK_LEN = 16
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
    doing: null,
    msgRaw: null,
    lastMessage: null,
    task: null,
    spark: [],
    lastEventAt: null,
    endedAt: null,
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

// C0/C1 controls, plus the invisible format characters that can reorder or
// hide text: zero-width marks, bidi embeddings and isolates, line and
// paragraph separators, and the BOM.
const CONTROL_CHARS = /[\x00-\x1f\x7f-\x9f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufe00-\ufe0f\ufeff\u{e0000}-\u{e007f}]/gu

// Strips control characters and caps the length. For strings that come from a
// run's own output and are drawn in the pane, status line or toast.
export function sanitize(text: string, max: number): string {
  const clean = text.replace(CONTROL_CHARS, '').trim()
  return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean
}

// The run's stderr tail is raw terminal output (it may hold ANSI/OSC codes).
// Keeps at most two lines, each stripped of control characters, so the pane's
// two-row stderr layout still holds.
export function cleanErrTail(text: string): string {
  return text
    .split('\n')
    .map(line => sanitize(line, 300))
    .filter(line => line !== '')
    .slice(-2)
    .join('\n')
}

export function oneLine(text: string, max = SNIPPET): string {
  return sanitize(text.replace(/\s+/g, ' '), max)
}

// Only a plain id is copied or interpolated into a command; anything else could
// carry control characters or shell syntax.
// It must start with a letter, digit or underscore, so it cannot read as a flag.
export const isCopyableId = (id: string): boolean => /^\w[\w.-]{0,63}$/.test(id)

// File names come from the run's own output, so they are cleaned like any other
// text the pane draws.
export function baseName(path: string): string {
  return oneLine(path.split('/').filter(Boolean).pop() ?? path, PATH_MAX)
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

const tailOf = (text: string, max: number): string => {
  const flat = text.replace(/\s+/g, ' ').replace(CONTROL_CHARS, '').trim()
  return flat.length > max ? `…${flat.slice(-(max - 1))}` : flat
}

// Streams one assistant chunk. Chunks join exactly as sent (the backends put
// spaces inside the deltas); a chunk extends the last timeline row only while
// that message is still open.
export function appendMessage(run: Run, chunk: string): Run {
  if (chunk === '') return run
  const last = run.timeline[run.timeline.length - 1]
  const isOpen = last?.kind === 'msg' && run.msgRaw !== null
  // msgRaw keeps the newest text, so the "says" tail follows a long message.
  // The row label is the message's head: once the buffer is full the head has
  // scrolled out of it, so the label already drawn stays.
  const joined = `${isOpen ? run.msgRaw : ''}${chunk}`
  const raw = joined.slice(-MSG_RAW_MAX)
  const label = isOpen && run.msgRaw!.length >= MSG_RAW_MAX ? last.label : oneLine(joined, MSG_MAX)
  // A blank first chunk opens nothing: marking it open would let the next
  // chunk overwrite the previous, already closed message row.
  if (!label) return isOpen ? { ...run, msgRaw: raw, doing: 'writing' } : { ...run, doing: 'writing' }
  const base: Run = { ...run, msgRaw: raw, doing: 'writing', snippet: oneLine(chunk) || run.snippet, lastMessage: tailOf(raw, LAST_MSG_MAX) }
  if (isOpen) {
    const timeline = run.timeline.slice()
    timeline[timeline.length - 1] = { ...last, label }
    return { ...base, timeline }
  }
  return pushEntry(
    { ...base, counts: bumpCount(run, 'msg') },
    { kind: 'msg', label, detail: null, count: 1, isOk: null },
  )
}

// A complete assistant message (Cursor repeats the streamed deltas as one
// final event): replaces the open streamed row instead of repeating it.
export function finishMessage(run: Run, text: string): Run {
  const label = oneLine(text, MSG_MAX)
  if (!label) return { ...run, msgRaw: null }
  const last = run.timeline[run.timeline.length - 1]
  const done: Run = { ...run, msgRaw: null, doing: null, snippet: oneLine(text), lastMessage: tailOf(text, LAST_MSG_MAX) }
  if (last?.kind === 'msg' && run.msgRaw !== null) {
    const timeline = run.timeline.slice()
    timeline[timeline.length - 1] = { ...last, label }
    return { ...done, timeline }
  }
  return pushEntry(
    { ...done, counts: bumpCount(run, 'msg') },
    { kind: 'msg', label, detail: null, count: 1, isOk: null },
  )
}

// Ends any open message, e.g. when a tool call or reasoning starts.
export const closeMessage = (run: Run): Run => (run.msgRaw === null ? run : { ...run, msgRaw: null })

// `- **Plan path:** `docs/plans/x.md`` and `- **Step scope:** `S7, S8``.
export function parseBrief(text: string): RunTask | null {
  const field = (name: string): string | null => {
    const m = new RegExp(`\\*\\*${name}:\\*\\*\\s*\`?([^\`\\n]+)\`?`, 'i').exec(text)
    return m ? m[1]!.trim() : null
  }
  const path = field('Plan path')
  const plan = path ? oneLine(baseName(path).replace(/\.md$/, '').replace(/^\d{6,}-/, ''), SNIPPET) || null : null
  const rawScope = field('Step scope')
  const scope = rawScope ? oneLine(rawScope, SNIPPET) || null : null
  return plan || scope ? { plan, scope } : null
}

export function taskLabel(task: RunTask | null): string | null {
  if (!task) return null
  return [task.plan, task.scope].filter(Boolean).join(' · ') || null
}

export function applyLine(run: Run, line: string): Run {
  let event: unknown
  try {
    event = JSON.parse(line)
  } catch {
    return { ...run, lines: run.lines + 1, badLines: run.badLines + 1 }
  }
  let next: Run = { ...run, lines: run.lines + 1 }
  if (!isObj(event)) return next
  next = withEventTime(next, event.timestamp_ms)

  // One poisoned line must not wedge the pane: count it as bad and move on.
  try {
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
  } catch {
    return { ...run, lines: run.lines + 1, badLines: run.badLines + 1 }
  }
}

export const reduceLine = applyLine

// A stream's own event times beat the pane's clock: the run started no later
// than its first event, whenever this session began reading it. A stamp far
// from the pane's own clock (the last time the file grew) is ignored, so a bad
// value cannot claim a run started years ago or ends in the future.
export const STAMP_PAST_MS = 2 * 24 * 60 * 60 * 1000
export const STAMP_FUTURE_MS = 5 * 60 * 1000

export function withEventTime(run: Run, stamp: unknown): Run {
  if (typeof stamp !== 'number' || !Number.isFinite(stamp) || stamp <= 0) return run
  const clock = run.lastGrowthAt
  if (clock !== null && (stamp < clock - STAMP_PAST_MS || stamp > clock + STAMP_FUTURE_MS)) return run
  return {
    ...run,
    startedAt: run.startedAt === null ? stamp : Math.min(run.startedAt, stamp),
    lastEventAt: run.lastEventAt === null ? stamp : Math.max(run.lastEventAt, stamp),
  }
}

// A run duration the backend reports, kept only when it is a plausible run
// length; anything else (negative, NaN, Infinity, centuries) is dropped and the
// elapsed time falls back to the run's own start and end.
export const DURATION_MAX_MS = 7 * 24 * 60 * 60 * 1000

export function durationMsOf(ms: unknown): number | null {
  return typeof ms === 'number' && Number.isFinite(ms) && ms >= 0 && ms <= DURATION_MAX_MS ? ms : null
}

// A file's mtime used as a run's end: a clock in the future (a copied or
// extracted file) would stretch the elapsed time, so it is held to now.
export function endTimeOf(mtimeMs: unknown, now: number): number | null {
  return typeof mtimeMs === 'number' && Number.isFinite(mtimeMs) && mtimeMs > 0 ? Math.min(now, mtimeMs) : null
}

// A side file is re-read only when it changed: its size and mtime make a key,
// and a key equal to the last one read means nothing new. Returns the new key
// when the file should be read, null when it is missing or unchanged.
export function changedFileKey(
  prev: string | null,
  stat: { size: number; mtimeMs: number } | null,
): string | null {
  if (!stat) return null
  const key = `${stat.size}:${stat.mtimeMs}`
  return key === prev ? null : key
}

// The brief's key is kept only once a read went through: a read that failed
// (timeout, file gone, over the cap) leaves the old key, so the next tick tries
// again. A brief read in full but with no task keeps its key and is not re-read
// until it changes.
export const briefKeyAfterRead = (prev: string | null, key: string, text: string | null): string | null =>
  text === null ? prev : key

// A finished Devin run has its exit code, its result and its end time: nothing
// in `.exit` can change it again, so the file is not read on later ticks.
export const isDevinSettled = (run: Run): boolean =>
  run.backend === 'devin' && run.exitCode !== null && run.result !== null && run.endedAt !== null

// Small side files (`.exit`, the brief) are read with `head -c max+1`: text
// longer than max is refused rather than parsed, so a runaway file is never
// loaded whole.
export const EXIT_MAX_BYTES = 64
export const BRIEF_MAX_BYTES = 64 * 1024

export function cappedText(text: string, max: number): string | null {
  return utf8Bytes(text) > max ? null : text
}

// A side file is read only when it is a regular file (not a directory, a FIFO
// or a link to one) that fits in max bytes: opening a FIFO blocks the reader.
export function isReadableSideFile(stat: { kind: string; size: number } | null, max: number): boolean {
  return stat !== null && stat.kind === 'file' && stat.size <= max
}

// How long the run has taken: the backend's own duration when it reports one;
// for a finished run, up to its exit (or last event); otherwise up to now.
export function runElapsed(run: Run, now: number): number | null {
  if (run.result?.durationMs != null) return run.result.durationMs
  if (run.startedAt === null) return null
  const isDone = run.exitCode !== null || run.result !== null
  const end = isDone ? (run.endedAt ?? run.lastEventAt ?? now) : now
  return Math.max(0, end - run.startedAt)
}

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

export const doingLabel = (run: Run): string =>
  run.tool
    ? `${run.tool}${run.toolDetail ? ` ${run.toolDetail}` : ''}`
    : run.doing === 'writing'
      ? 'writing a reply'
      : run.doing === 'thinking'
        ? 'thinking'
        : run.tools === 0 && run.lines === 0
          ? run.backend === 'devin'
            ? 'running (no live stream)'
            : 'starting'
          : 'waiting for the model'

export function statusLine(run: Run, now: number): string {
  const phase = phaseOf(run, now)
  const took = runElapsed(run, now)
  const time = took !== null ? ` · ${elapsed(took)}` : ''
  const task = taskLabel(run.task)
  const head = `exec #${run.n} [${run.backend}]${task ? ` ${oneLine(task, 40)}` : ''}`
  if (phase === 'passed') return `${head} ✓ done · ${run.tools} tools · ${run.files.length} files${time}`
  if (phase === 'failed') return `${head} ✗ ${oneLine(failureReason(run), 50)}${time}`
  const stall = phase === 'stalled' ? ' · quiet >90s' : ''
  return `${head} ▸ ${oneLine(doingLabel(run), 50)} · ${run.tools} tools${time}${stall}`
}

export const pushSpark = (spark: readonly number[], n: number): number[] =>
  [...spark, Math.max(0, n)].slice(-SPARK_LEN)

// Records how many events one poll read, from the run before and after it.
// A run already finished keeps its last sparkline instead of scrolling to blanks.
export function withSpark(before: Run, after: Run): Run {
  if (before.exitCode !== null || before.result !== null) return after
  return { ...after, spark: pushSpark(after.spark, after.lines - before.lines) }
}

// The spinner advances only while the run is actively running.
export const isAnimating = (run: Run | null, now: number): boolean =>
  run !== null && phaseOf(run, now) === 'running'

const BARS = '▁▂▃▄▅▆▇█'

// One cell per poll, scaled to the busiest poll shown; an idle poll is a space.
export function sparkline(spark: readonly number[]): string {
  const max = Math.max(1, ...spark)
  return spark
    .map(n => (n === 0 ? ' ' : BARS[Math.min(BARS.length - 1, Math.ceil((n / max) * BARS.length) - 1)]))
    .join('')
}

export function backendName(backend: Backend): string {
  switch (backend) {
    case 'cursor':
      return 'Cursor'
    case 'agy':
      return 'Antigravity'
    case 'devin':
      return 'Devin'
    default: {
      const _exhaustive: never = backend
      return _exhaustive
    }
  }
}

// Command that reopens the backend's conversation, as the delegate skills run it.
// Devin's resume is a full flagged invocation, not a one-liner, so it gets none.
export function resumeCommand(run: Run): string | null {
  if (!run.sessionId || run.backend === 'devin' || !isCopyableId(run.sessionId)) return null
  return run.backend === 'agy' ? `agy --conversation ${run.sessionId}` : `agent --resume ${run.sessionId}`
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
