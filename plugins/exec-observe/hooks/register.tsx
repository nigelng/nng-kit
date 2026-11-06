import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, TimelineFilter, ViewMode } from '../types'
import { DEVIN_EXPORT_MAX_BYTES, devinExitCode, resolveDevinRun } from './adapters/devin'
import {
  applyLine,
  BRIEF_MAX_BYTES,
  briefKeyAfterRead,
  cappedText,
  changedFileKey,
  cleanErrTail,
  completeLines,
  emptyRun,
  endTimeOf,
  EXIT_MAX_BYTES,
  isDevinSettled,
  isReadableSideFile,
  isSwitchedRun,
  paneTitle,
  parseBrief,
  isAnimating,
  withSpark,
  shouldAnnounce,
  phaseOf,
  pickNewestRunFile,
  RUN_FILE,
  statusLine,
  utf8Bytes,
  type PickedRunFile,
  type RunFileEntry,
} from './reduce'
import { renderPane } from './view'

export { paneTitle, pickNewestRunFile, RUN_FILE, type PickedRunFile, type RunFileEntry }

const PANE = 'exec-observe'
const POLL_MS = 2000
// Side files are read only when they are regular files (stat first), so a FIFO
// planted at their path is never opened. Reading a local file never takes this
// long; past it the read is abandoned, as a backstop.
const READ_TIMEOUT_MS = 10_000
// `pgrep` answers at once; a hung one is treated as "cannot tell" (null).
const PGREP_TIMEOUT_MS = 5_000
const MAX_READ_BYTES = DEVIN_EXPORT_MAX_BYTES
const MAX_LINES_PER_TICK = 20_000

// Change the tag when Run's fields change: it declines what an earlier
// version stored, which outlives a reload. run-7 drops runs stored before
// stream text was cleaned.
const runAtom = atom({ plugin: 'exec-observe', key: 'run' } as const, null, {
  shape: 'run-7',
})

const viewAtom = atom({ plugin: 'exec-observe', key: 'view' } as const, 'compact' as ViewMode)
const showErrAtom = atom({ plugin: 'exec-observe', key: 'showErr' } as const, false)
// Animation frame for the spinner and live clock; only advances while a run is open.
const frameAtom = atom({ plugin: 'exec-observe', key: 'frame' } as const, 0)
const FRAME_MS = 150

const filterAtom = atom({ plugin: 'exec-observe', key: 'filter' } as const, 'all' as TimelineFilter)

type Watch = {
  tmp: string
  cwd: string
  // Byte offset into the current run's ndjson; only bytes past it are read.
  // For a Devin run, the `.out` size at the last tick, so a rewrite (the file
  // shrinks) starts the summary over.
  offset: number
  errSize: number
  // Size and mtime of the brief when it was last read without yielding a task;
  // it is read again only once it changes.
  briefKey: string | null
  current: Run | null
  isBusy: boolean
  announced: string
  // Whether the spinner should advance: only while the run is actively running
  // (not stalled, orphaned or finished).
  isAnimating: boolean
}

const linesBytes = (lines: string[]): number => utf8Bytes(lines.map(line => `${line}\n`).join(''))

async function listRunCandidates($: EngineInterface, tmp: string): Promise<RunFileEntry[]> {
  if (!(await $.fs.exists(tmp))) return []
  const entries = await $.fs.list(tmp)
  const candidates: RunFileEntry[] = []
  for (const entry of entries) {
    if (!RUN_FILE.test(entry.name)) continue
    const stat = await $.fs.stat(`${tmp}/${entry.name}`).catch(() => null)
    // Only a regular file is tailed: a FIFO (or a link to one) would block the read.
    if (stat && stat.kind !== 'file') continue
    const fallbackMtime =
      (entry as { mtimeMs?: number; mtime?: number }).mtimeMs ??
      (entry as { mtime?: number }).mtime ??
      0
    candidates.push({
      name: entry.name,
      size: stat?.size ?? entry.size,
      mtimeMs: stat?.mtimeMs ?? fallbackMtime,
    })
  }
  return candidates
}

async function readNewLines(
  $: EngineInterface,
  w: Watch,
  file: string,
  size: number,
  run: Run,
  grewAt: number,
): Promise<Run> {
  if (size <= w.offset) return run
  const { stdout, isStdoutTruncated } = await $.process.run(
    ['tail', '-c', `+${w.offset + 1}`, '--', file],
    { cwd: w.cwd, timeoutMs: READ_TIMEOUT_MS },
  )
  const { lines, bytes } = completeLines(stdout)
  const take = lines.slice(0, MAX_LINES_PER_TICK)
  let next = run
  for (const line of take) next = applyLine(next, line)
  const consumed = take.length < lines.length ? linesBytes(take) : Math.min(bytes, MAX_READ_BYTES)
  w.offset += consumed
  if (take.length > 0 || isStdoutTruncated) {
    next = { ...next, lastGrowthAt: grewAt }
  }
  return next
}

// The skill writes `exec-<backend>-brief.md` before the run; its plan path and
// step scope say what this run is for. Read until found, then kept.
async function readTask($: EngineInterface, w: Watch, run: Run): Promise<Run> {
  if (run.task !== null) return run
  const brief = `${w.tmp}/exec-${run.backend}-brief.md`
  const key = changedFileKey(w.briefKey, await $.fs.stat(brief).catch(() => null))
  if (key === null) return run
  const text = await readCapped($, w, brief, BRIEF_MAX_BYTES)
  w.briefKey = briefKeyAfterRead(w.briefKey, key, text)
  const task = text === null ? null : parseBrief(text)
  return task ? { ...run, task } : run
}

// Reads a small side file whole only when it fits in max bytes; null when it is
// missing, unreadable or too large.
async function readCapped($: EngineInterface, w: Watch, path: string, max: number): Promise<string | null> {
  const stat = await $.fs.stat(path).catch(() => null)
  if (!isReadableSideFile(stat, max)) return null
  const read = await $.process
    .run(['head', '-c', String(max + 1), '--', path], { cwd: w.cwd, timeoutMs: READ_TIMEOUT_MS })
    .catch(() => null)
  if (!read || read.exitCode !== 0 || read.isStdoutTruncated) return null
  return cappedText(read.stdout, max)
}

// Best guess at launch for streams without event times (Antigravity): the
// skill's shell creates `.err` when it starts the CLI, and an empty `.err` has
// not been written since. Event timestamps, where present, override this.
async function launchTime($: EngineInterface, base: string, now: number): Promise<number> {
  const err = await $.fs.stat(`${base}.err`).catch(() => null)
  return err && err.size === 0 && err.mtimeMs > 0 ? Math.min(now, err.mtimeMs) : now
}

async function readExitAndErr($: EngineInterface, w: Watch, base: string, run: Run, now: number): Promise<Run> {
  let next = run
  if (next.exitCode === null) {
    const code = devinExitCode(await readCapped($, w, `${base}.exit`, EXIT_MAX_BYTES))
    const exit = await $.fs.stat(`${base}.exit`).catch(() => null)
    if (code !== null) next = { ...next, exitCode: code, endedAt: endTimeOf(exit?.mtimeMs, now) }
  }
  return readErrTail($, w, base, next)
}

async function readErrTail($: EngineInterface, w: Watch, base: string, run: Run): Promise<Run> {
  let next = run
  const err = await $.fs.stat(`${base}.err`).catch(() => null)
  if (err && err.kind === 'file' && err.size > 0 && err.size !== w.errSize) {
    w.errSize = err.size
    const { stdout } = await $.process.run(['tail', '-n', '2', '--', `${base}.err`], {
      cwd: w.cwd,
      timeoutMs: READ_TIMEOUT_MS,
    })
    // Cleaned before it is stored, so the atom never holds terminal codes; the
    // pane cleans it again when drawing, for runs stored by older versions.
    next = { ...next, errTail: cleanErrTail(stdout).slice(-300) || null }
  }
  return next
}

// Devin writes one ATIF document at the end. Do not tail `.out`. Until `.exit`
// holds a number the run stays running (the shell creates the file before it
// writes the code; the growth clock is refreshed so a long run is not marked
// stalled). Then read the export, capped on the read itself: a larger export is
// not parsed, and the exit code alone decides pass or fail.
async function readDevinExport(
  $: EngineInterface,
  w: Watch,
  jsonPath: string,
): Promise<{ exportSize: number | null; exportText: string | null }> {
  // Any size: an oversized export is still reported as oversized below.
  const stat = await $.fs.stat(jsonPath).catch(() => null)
  if (stat === null || stat.kind !== 'file') return { exportSize: null, exportText: null }
  const read = await $.process
    .run(['head', '-c', String(MAX_READ_BYTES + 1), '--', jsonPath], {
      cwd: w.cwd,
      timeoutMs: READ_TIMEOUT_MS,
    })
    .catch(() => null)
  if (!read || read.exitCode !== 0) return { exportSize: null, exportText: null }
  const exportSize = read.isStdoutTruncated ? MAX_READ_BYTES + 1 : utf8Bytes(read.stdout)
  return { exportSize, exportText: read.stdout }
}

// Is this run's `devin` process still alive? Its command line carries
// `--export=…exec-run-devin-<n>.json`. Null when `pgrep` cannot be run.
async function isDevinAlive($: EngineInterface, w: Watch, n: number): Promise<boolean | null> {
  const found = await $.process
    .run(['pgrep', '-f', `export=[^ ]*exec-run-devin-${n}\\.json`], {
      cwd: w.cwd,
      timeoutMs: PGREP_TIMEOUT_MS,
    })
    .catch(() => null)
  if (!found) return null
  if (found.exitCode === 0) return true
  if (found.exitCode === 1) return false
  return null
}

async function devinActivityAt(
  $: EngineInterface,
  w: Watch,
  base: string,
  n: number,
  now: number,
): Promise<number | undefined> {
  const alive = await isDevinAlive($, w, n)
  if (alive === null) return undefined
  if (alive) return now
  let latest = 0
  for (const ext of ['out', 'err']) {
    const stat = await $.fs.stat(`${base}.${ext}`).catch(() => null)
    if (stat && typeof stat.mtimeMs === 'number') latest = Math.max(latest, stat.mtimeMs)
  }
  return latest
}

async function readDevinRun(
  $: EngineInterface,
  w: Watch,
  newest: PickedRunFile,
  run: Run,
  now: number,
): Promise<Run> {
  const base = `${w.tmp}/exec-run-devin-${newest.n}`
  const next = await readErrTail($, w, base, run)
  if (isDevinSettled(next)) return next
  // Null when `.exit` is missing: readCapped stats it before reading.
  const exitText = await readCapped($, w, `${base}.exit`, EXIT_MAX_BYTES)
  const hasExited = devinExitCode(exitText) !== null
  const isReady = hasExited && next.result === null
  const exported = isReady
    ? await readDevinExport($, w, `${base}.json`)
    : { exportSize: null, exportText: null }
  const activityAt = hasExited ? undefined : await devinActivityAt($, w, base, newest.n, now)
  const resolved = resolveDevinRun(next, { exitText, ...exported, activityAt }, now)
  if (!hasExited || resolved.endedAt !== null) return resolved
  const exit = await $.fs.stat(`${base}.exit`).catch(() => null)
  return { ...resolved, endedAt: endTimeOf(exit?.mtimeMs, now) ?? now }
}

const isRunningOrStalled = (run: Run | null, now: number): boolean => {
  if (run === null) return false
  const phase = phaseOf(run, now)
  return phase !== 'passed' && phase !== 'failed'
}

async function tick($: EngineInterface, w: Watch): Promise<void> {
  if (w.isBusy || w.tmp === '') return
  w.isBusy = true
  try {
    const now = await $.clock.now()
    const newest = pickNewestRunFile(await listRunCandidates($, w.tmp))

    if (!newest) {
      if (w.current !== null) {
        w.current = null
        w.isAnimating = false
        await update($, runAtom, () => null)
        $.ui.status(undefined)
      }
      return
    }

    const file = `${w.tmp}/${newest.name}`
    const base = `${w.tmp}/exec-run-${newest.backend}-${newest.n}`
    let run: Run = w.current ?? emptyRun(newest.n, newest.backend)
    // When the stream last grew, from the file itself: a run found when this
    // session starts keeps its real quiet time instead of looking fresh.
    const grewAt = newest.mtimeMs > 0 ? Math.min(now, newest.mtimeMs) : now

    // New run id or backend, or the skill cleared tmp and rewrote the file: start over.
    const isSwitched = isSwitchedRun(w.current, newest, w.offset)
    if (isSwitched) {
      const startedAt = await launchTime($, base, now)
      run = { ...emptyRun(newest.n, newest.backend), startedAt, lastGrowthAt: grewAt }
      w.offset = 0
      w.errSize = 0
      w.briefKey = null
    }

    if (newest.backend === 'devin') {
      run = await readDevinRun($, w, newest, run, now)
      w.offset = newest.size
    } else {
      const before = run
      run = withSpark(before, await readNewLines($, w, file, newest.size, run, grewAt))
      run = await readExitAndErr($, w, base, run, now)
    }
    run = await readTask($, w, run).catch(() => run)

    // Announce after reading, so a run that already finished long ago (it became
    // the newest again when a later run's files were deleted) is not re-opened.
    const key = `${newest.backend}-${newest.n}`
    if (isSwitched && w.announced !== key && shouldAnnounce(run, newest.mtimeMs, now)) {
      w.announced = key
      void $.ui.open({ id: PANE, title: paneTitle(newest.backend) })
    }

    const wasOpen = isRunningOrStalled(w.current, now)
    w.current = run
    await update($, runAtom, () => run)
    $.ui.status(statusLine(run, now))

    const phase = phaseOf(run, now)
    w.isAnimating = isAnimating(run, now)
    if (wasOpen && (phase === 'passed' || phase === 'failed')) {
      $.ui.toast(statusLine(run, now))
    }
  } catch (error) {
    $.ui.log(`exec-observe: ${String(error)}`, { to: 'debug' })
  } finally {
    w.isBusy = false
  }
}

export const register: Register = on => {
  const w: Watch = {
    tmp: '',
    cwd: '',
    offset: 0,
    errSize: 0,
    briefKey: null,
    current: null,
    isBusy: false,
    announced: '',
    isAnimating: false,
  }

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    w.cwd = e.cwd
    const top = await $.process
      .run(['git', 'rev-parse', '--show-toplevel'], { cwd: e.cwd })
      .catch(() => null)
    const root = top && top.exitCode === 0 ? top.stdout.trim() : e.cwd
    w.tmp = `${root}/.claude/tmp`

    await $.command.register({
      name: 'exec',
      description: 'Show the latest /delegate run (Cursor, Antigravity, or Devin) in a pane',
    })
    $.clock.every(POLL_MS, () => void tick($, w))
    $.clock.every(FRAME_MS, () => {
      if (w.isAnimating) void update($, frameAtom, frame => (frame + 1) % 1_000_000)
    })
    void tick($, w)

    return started
  })

  on('command.run', { command: 'exec' }, async $ => {
    const run = await read($, runAtom)
    await $.ui.open({ id: PANE, title: paneTitle(run?.backend ?? 'cursor') })

    // Shown to the person only; a short line, never the stream.
    return { text: run ? statusLine(run, await $.clock.now()) : `No exec-run logs in ${w.tmp}.` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const run = await read($, runAtom)
    const view = await read($, viewAtom)
    const showErr = await read($, showErrAtom)
    const filter = await read($, filterAtom)
    const frame = await read($, frameAtom)
    const now = await $.clock.now()
    return renderPane($, e, { run, view, showErr, filter, frame, watching: w.tmp }, now)
  })
}
