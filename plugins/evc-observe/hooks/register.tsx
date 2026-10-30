import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, ViewMode } from '../types'
import { completeLines, emptyRun, phaseOf, reduceLine, statusLine, utf8Bytes } from './reduce'
import { renderPane } from './view'

const PANE = 'evc-observe'
const POLL_MS = 2000
const RUN_FILE = /^evc-run-(\d+)\.ndjson$/
const MAX_READ_BYTES = 4_194_304
const MAX_LINES_PER_TICK = 20_000

// Change the tag when Run's fields change: it declines what an earlier
// version stored, which outlives a reload.
const runAtom = atom({ plugin: 'evc-observe', key: 'run' } as const, null, {
  shape: 'run-2',
})

const viewAtom = atom({ plugin: 'evc-observe', key: 'view' } as const, 'compact' as ViewMode)
const showErrAtom = atom({ plugin: 'evc-observe', key: 'showErr' } as const, false)

type Watch = {
  tmp: string
  cwd: string
  // Byte offset into the current run's ndjson; only bytes past it are read.
  offset: number
  errSize: number
  current: Run | null
  isBusy: boolean
  announced: number
}

const linesBytes = (lines: string[]): number => utf8Bytes(lines.map(line => `${line}\n`).join(''))

async function tick($: EngineInterface, w: Watch): Promise<void> {
  if (w.isBusy || w.tmp === '') return
  w.isBusy = true
  try {
    const now = await $.clock.now()
    const entries = (await $.fs.exists(w.tmp)) ? await $.fs.list(w.tmp) : []
    const newest = entries
      .map(entry => ({ entry, n: Number(RUN_FILE.exec(entry.name)?.[1] ?? NaN) }))
      .filter(one => Number.isFinite(one.n))
      .sort((a, b) => b.n - a.n)[0]

    if (!newest) {
      if (w.current !== null) {
        w.current = null
        await update($, runAtom, () => null)
        $.ui.status(undefined)
      }
      return
    }

    const file = `${w.tmp}/${newest.entry.name}`
    const size = newest.entry.size
    let run: Run = w.current ?? emptyRun(newest.n)

    // New run id, or the skill cleared tmp and rewrote the file: start over.
    if (w.current === null || w.current.n !== newest.n || size < w.offset) {
      run = { ...emptyRun(newest.n), startedAt: now, lastGrowthAt: now }
      w.offset = 0
      w.errSize = 0
      if (w.announced !== newest.n) {
        w.announced = newest.n
        void $.ui.open({ id: PANE, title: 'Cursor run' })
      }
    }

    if (size > w.offset) {
      const { stdout, isStdoutTruncated } = await $.process.run(
        ['tail', '-c', `+${w.offset + 1}`, file],
        { cwd: w.cwd },
      )
      const { lines, bytes } = completeLines(stdout)
      const take = lines.slice(0, MAX_LINES_PER_TICK)
      for (const line of take) run = reduceLine(run, line)
      const consumed =
        take.length < lines.length ? linesBytes(take) : Math.min(bytes, MAX_READ_BYTES)
      w.offset += consumed
      if (take.length > 0 || isStdoutTruncated) {
        run = { ...run, lastGrowthAt: now }
      }
    }

    const base = `${w.tmp}/evc-run-${newest.n}`
    if (run.exitCode === null && (await $.fs.exists(`${base}.exit`))) {
      const code = Number.parseInt((await $.fs.read(`${base}.exit`)).trim(), 10)
      if (Number.isFinite(code)) run = { ...run, exitCode: code }
    }
    const err = await $.fs.stat(`${base}.err`).catch(() => null)
    if (err && err.size > 0 && err.size !== w.errSize) {
      w.errSize = err.size
      const { stdout } = await $.process.run(['tail', '-n', '2', `${base}.err`], { cwd: w.cwd })
      run = { ...run, errTail: stdout.trim().slice(-300) || null }
    }

    const wasOpen = w.current !== null && phaseOf(w.current, now) !== 'passed' && phaseOf(w.current, now) !== 'failed'
    w.current = run
    await update($, runAtom, () => run)
    $.ui.status(statusLine(run, now))

    const phase = phaseOf(run, now)
    if (wasOpen && (phase === 'passed' || phase === 'failed')) {
      $.ui.toast(statusLine(run, now))
    }
  } catch (error) {
    $.ui.log(`evc-observe: ${String(error)}`, { to: 'debug' })
  } finally {
    w.isBusy = false
  }
}

export const register: Register = on => {
  const w: Watch = { tmp: '', cwd: '', offset: 0, errSize: 0, current: null, isBusy: false, announced: -1 }

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    w.cwd = e.cwd
    const top = await $.process
      .run(['git', 'rev-parse', '--show-toplevel'], { cwd: e.cwd })
      .catch(() => null)
    const root = top && top.exitCode === 0 ? top.stdout.trim() : e.cwd
    w.tmp = `${root}/.claude/tmp`

    await $.command.register({
      name: 'evc',
      description: 'Show the latest execute-via-cursor run in a pane',
    })
    $.clock.every(POLL_MS, () => void tick($, w))
    void tick($, w)

    return started
  })

  on('command.run', { command: 'evc' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Cursor run' })
    const run = await read($, runAtom)

    // Shown to the person only; a short line, never the stream.
    return { text: run ? statusLine(run, await $.clock.now()) : `No evc-run logs in ${w.tmp}.` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const run = await read($, runAtom)
    const view = await read($, viewAtom)
    const showErr = await read($, showErrAtom)
    const now = await $.clock.now()
    return renderPane($, e, { run, view, showErr, watching: w.tmp }, now)
  })
}
