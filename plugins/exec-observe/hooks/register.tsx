import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, ViewMode } from '../types'
import {
  applyLine,
  completeLines,
  emptyRun,
  paneTitle,
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
const MAX_READ_BYTES = 4_194_304
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
  const err = await $.fs.stat(`${base}.err`).catch(() => null)
  if (err && err.size > 0 && err.size !== w.errSize) {
    w.errSize = err.size
    const { stdout } = await $.process.run(['tail', '-n', '2', `${base}.err`], { cwd: w.cwd })
    next = { ...next, errTail: stdout.trim().slice(-300) || null }
  }
  return next
}

const isSwitchedRun = (current: Run | null, newest: PickedRunFile, offset: number): boolean =>
  current === null ||
  current.n !== newest.n ||
  current.backend !== newest.backend ||
  newest.size < offset

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

    const file = `${w.tmp}/${newest.name}`
    let run: Run = w.current ?? emptyRun(newest.n, newest.backend)

    // New run id or backend, or the skill cleared tmp and rewrote the file: start over.
    if (isSwitchedRun(w.current, newest, w.offset)) {
      run = { ...emptyRun(newest.n, newest.backend), startedAt: now, lastGrowthAt: now }
      w.offset = 0
      w.errSize = 0
      const key = `${newest.backend}-${newest.n}`
      if (w.announced !== key) {
        w.announced = key
        void $.ui.open({ id: PANE, title: paneTitle(newest.backend) })
      }
    }

    run = await readNewLines($, w, file, newest.size, run, now)
    const base = `${w.tmp}/exec-run-${newest.backend}-${newest.n}`
    run = await readExitAndErr($, w, base, run)

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
      description: 'Show the latest /delegate run (Cursor or Antigravity) in a pane',
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
