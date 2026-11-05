import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, ViewMode } from '../types'
import { DEVIN_EXPORT_MAX_BYTES, devinExitCode, resolveDevinRun } from './adapters/devin'
import {
  applyLine,
  completeLines,
  emptyRun,
  isSwitchedRun,
  paneTitle,
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
const MAX_READ_BYTES = DEVIN_EXPORT_MAX_BYTES
const MAX_LINES_PER_TICK = 20_000

// Change the tag when Run's fields change: it declines what an earlier
// version stored, which outlives a reload.
const runAtom = atom({ plugin: 'exec-observe', key: 'run' } as const, null, {
  shape: 'run-3',
})

const viewAtom = atom({ plugin: 'exec-observe', key: 'view' } as const, 'compact' as ViewMode)
const showErrAtom = atom({ plugin: 'exec-observe', key: 'showErr' } as const, false)

type Watch = {
  tmp: string
  cwd: string
  // Byte offset into the current run's ndjson; only bytes past it are read.
  // For a Devin run, the `.out` size at the last tick, so a rewrite (the file
  // shrinks) starts the summary over.
  offset: number
  errSize: number
  current: Run | null
  isBusy: boolean
  announced: string
}

const linesBytes = (lines: string[]): number => utf8Bytes(lines.map(line => `${line}\n`).join(''))

async function listRunCandidates($: EngineInterface, tmp: string): Promise<RunFileEntry[]> {
  if (!(await $.fs.exists(tmp))) return []
  const entries = await $.fs.list(tmp)
  const candidates: RunFileEntry[] = []
  for (const entry of entries) {
    if (!RUN_FILE.test(entry.name)) continue
    const stat = await $.fs.stat(`${tmp}/${entry.name}`).catch(() => null)
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
  now: number,
): Promise<Run> {
  if (size <= w.offset) return run
  const { stdout, isStdoutTruncated } = await $.process.run(
    ['tail', '-c', `+${w.offset + 1}`, file],
    { cwd: w.cwd },
  )
  const { lines, bytes } = completeLines(stdout)
  const take = lines.slice(0, MAX_LINES_PER_TICK)
  let next = run
  for (const line of take) next = applyLine(next, line)
  const consumed = take.length < lines.length ? linesBytes(take) : Math.min(bytes, MAX_READ_BYTES)
  w.offset += consumed
  if (take.length > 0 || isStdoutTruncated) {
    next = { ...next, lastGrowthAt: now }
  }
  return next
}

async function readExitAndErr($: EngineInterface, w: Watch, base: string, run: Run): Promise<Run> {
  let next = run
  if (next.exitCode === null && (await $.fs.exists(`${base}.exit`))) {
    const code = Number.parseInt((await $.fs.read(`${base}.exit`)).trim(), 10)
    if (Number.isFinite(code)) next = { ...next, exitCode: code }
  }
  return readErrTail($, w, base, next)
}

async function readErrTail($: EngineInterface, w: Watch, base: string, run: Run): Promise<Run> {
  let next = run
  const err = await $.fs.stat(`${base}.err`).catch(() => null)
  if (err && err.size > 0 && err.size !== w.errSize) {
    w.errSize = err.size
    const { stdout } = await $.process.run(['tail', '-n', '2', `${base}.err`], { cwd: w.cwd })
    next = { ...next, errTail: stdout.trim().slice(-300) || null }
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
  if (!(await $.fs.exists(jsonPath))) return { exportSize: null, exportText: null }
  const read = await $.process
    .run(['head', '-c', String(MAX_READ_BYTES + 1), jsonPath], { cwd: w.cwd })
    .catch(() => null)
  if (!read || read.exitCode !== 0) return { exportSize: null, exportText: null }
  const exportSize = read.isStdoutTruncated ? MAX_READ_BYTES + 1 : utf8Bytes(read.stdout)
  return { exportSize, exportText: read.stdout }
}

// Is this run's `devin` process still alive? Its command line carries
// `--export=…exec-run-devin-<n>.json`. Null when `pgrep` cannot be run.
async function isDevinAlive($: EngineInterface, w: Watch, n: number): Promise<boolean | null> {
  const found = await $.process
    .run(['pgrep', '-f', `export=[^ ]*exec-run-devin-${n}\\.json`], { cwd: w.cwd })
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
  const exitText = (await $.fs.exists(`${base}.exit`))
    ? await $.fs.read(`${base}.exit`).catch(() => null)
    : null
  const hasExited = devinExitCode(exitText) !== null
  const isReady = hasExited && next.result === null
  const exported = isReady
    ? await readDevinExport($, w, `${base}.json`)
    : { exportSize: null, exportText: null }
  const activityAt = hasExited ? undefined : await devinActivityAt($, w, base, newest.n, now)
  return resolveDevinRun(next, { exitText, ...exported, activityAt }, now)
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
        await update($, runAtom, () => null)
        $.ui.status(undefined)
      }
      return
    }

    let run: Run = w.current ?? emptyRun(newest.n, newest.backend)

    // New run id or backend, or the skill cleared tmp and rewrote the file: start over.
    const isSwitched = isSwitchedRun(w.current, newest, w.offset)
    if (isSwitched) {
      run = { ...emptyRun(newest.n, newest.backend), startedAt: now, lastGrowthAt: now }
      w.offset = 0
      w.errSize = 0
    }

    if (newest.backend === 'devin') {
      run = await readDevinRun($, w, newest, run, now)
      w.offset = newest.size
    } else {
      const file = `${w.tmp}/${newest.name}`
      run = await readNewLines($, w, file, newest.size, run, now)
      const base = `${w.tmp}/exec-run-${newest.backend}-${newest.n}`
      run = await readExitAndErr($, w, base, run)
    }

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
    current: null,
    isBusy: false,
    announced: '',
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
    const now = await $.clock.now()
    return renderPane($, e, { run, view, showErr, watching: w.tmp }, now)
  })
}
