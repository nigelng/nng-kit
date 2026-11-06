import { expect, test } from 'claude-code/testing'

import { applyDevinExport } from '../hooks/adapters/devin'
import { emptyRun, reduceLine } from '../hooks/reduce'
import { chromeRows, KIND_COLOR, spinnerAt } from '../hooks/view'
import { generate, generateLines } from '../scripts/generate.ts'
import type { Backend, Run } from '../types'

const PANE = {
  plugin: 'exec-observe',
  component: 'Pane',
  requestId: 'exec-observe',
  props: {
    title: 'Cursor run',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

const fold = (lines: string[], backend: Backend = 'cursor', n = 2): Run =>
  lines.reduce(reduceLine, { ...emptyRun(n, backend), startedAt: 0, lastGrowthAt: 0 })

const BIG = fold(generate({ events: 5000, seed: 1 }), 'cursor', 2)
const BIG_AGY = fold(generateLines({ backend: 'agy', events: 5000, seed: 1 }), 'agy', 3)

const isTimeline = (text: string | undefined): boolean =>
  !!text && /^(READ|SRCH|EDIT|SH  |TASK|TOOL|MSG |ERR |RES )/.test(text)

const seedRun = (on: (event: string, handler: (...args: any[]) => unknown) => void, run: Run) => {
  on('state.get', async (_$, e, next) => {
    if (e.key === 'run') {
      return { value: { value: { shape: 'run-7', value: run }, version: 1 } }
    }
    // view / showErr: let the harness own them so set invalidates the drawing.
    return next(e)
  })
}

test('the pane draws header and counters on every surface for cursor and agy', async ($, on) => {
  let activeRun: Run = BIG
  on('state.get', async (_$, e, next) => {
    if (e.key === 'run') {
      return { value: { value: { shape: 'run-7', value: activeRun }, version: 1 } }
    }
    return next(e)
  })
  on('clock.now', () => ({ value: 30_000 }))
  on('ui.copy', () => ({ value: { isCopied: true } }))

  for (const surface of ['terminal', 'desktop'] as const) {
    activeRun = BIG
    const cursorUi = await $.ui.mount({ ...PANE, surface })
    expect((await cursorUi.find({ type: 'Text', text: /RUNNING|PASSED|FAILED|STALLED/ }))?.text).toMatch(
      /PASSED|RUNNING/,
    )
    expect((await cursorUi.find({ type: 'Text', text: /Cursor #2/ }))?.text).toContain('Cursor #2')
    expect((await cursorUi.find({ type: 'Text', text: /read \d+/ }))?.text).toMatch(/read \d+/)
    expect((await cursorUi.find({ type: 'Text', text: /^now:/ }))?.text).toMatch(/^now:/)
    await cursorUi.unmount()

    activeRun = BIG_AGY
    const agyUi = await $.ui.mount({ ...PANE, surface })
    expect((await agyUi.find({ type: 'Text', text: /RUNNING|PASSED|FAILED|STALLED/ }))?.text).toMatch(
      /PASSED|RUNNING/,
    )
    expect((await agyUi.find({ type: 'Text', text: /Antigravity #3/ }))?.text).toContain('Antigravity #3')
    expect((await agyUi.find({ type: 'Text', text: /gemini-2\.5-pro/ }))?.text).toContain(
      'gemini-2.5-pro',
    )
    await agyUi.unmount()
  }
})

test('Compact fits bodyRows; Full shows the whole timeline', async ($, on) => {
  seedRun(on, BIG)
  on('clock.now', () => ({ value: 30_000 }))
  on('ui.copy', () => ({ value: { isCopied: true } }))

  const bodyRows = PANE.props.scroll.bodyRows
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const compactTexts = (await ui.findAll({ type: 'Text' })).map(n => n.text).filter(isTimeline)
  expect(compactTexts.length).toBeGreaterThan(0)
  expect(compactTexts.length).toBeLessThanOrEqual(bodyRows)

  expect(await ui.find({ key: 'toggle-view' })).toBeDefined()
  await ui.press({ key: 'toggle-view' })
  const toggle = await ui.find({ key: 'toggle-view' })
  expect(toggle?.text).toBe('Compact')
  const fullTexts = (await ui.findAll({ type: 'Text' })).map(n => n.text).filter(isTimeline)
  expect(fullTexts.length).toBe(BIG.timeline.length)
  expect(fullTexts.length).toBeGreaterThan(compactTexts.length)
  await ui.unmount()
})

test('Compact budgets every row, not just timeline rows', async ($, on) => {
  seedRun(on, BIG)
  on('clock.now', () => ({ value: 30_000 }))

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const texts = await ui.findAll({ type: 'Text' })
    const timeline = texts.filter(n => isTimeline(n.text))
    // Badge and title share one row (as do counters and failures); the timeline and button rows each sit
    // under a one-row margin, and the buttons take one row.
    // Texts that sit beside another on its row: failures by the counters,
    // the quiet gauge by "now", the sparkline by the meta row.
    const sharedRows =
      1 + texts.filter(n => /^(· \d+ failed|[▰▱]+ quiet|[▁-█ ]+$)/.test(n.text ?? '')).length
    // Each timeline row is a tag Text and a body Text.
    const headerRows = texts.length - 2 * timeline.length - sharedRows
    expect(chromeRows(BIG, false, false)).toBe(headerRows + 1 + 2)
    expect(timeline.length + chromeRows(BIG, false, false)).toBeLessThan(PANE.props.scroll.bodyRows)
    expect(texts.every(n => n.props.wrap === 'truncate-end')).toBe(true)
    await ui.unmount()
  }
})

test('the badge is a filled label, not inverted text', async ($, on) => {
  seedRun(on, BIG)
  on('clock.now', () => ({ value: 30_000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const badge = await ui.find({ type: 'Text', text: /RUNNING|PASSED|FAILED|STALLED/ })
  expect(badge?.props.backgroundColor).toBeDefined()
  expect(badge?.props.color).toBe('inverseText')
  expect(badge?.props.inverse).toBeUndefined()
  await ui.unmount()
})

test('Copy session id calls ui.copy', async ($, on) => {
  seedRun(on, BIG)
  on('clock.now', () => ({ value: 30_000 }))
  const copies: { text: string; surface?: string }[] = []
  on('ui.copy', (_$, e) => {
    copies.push({ text: String(e.text), surface: e.surface })
    return { value: { isCopied: true } }
  })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'copy-session' })
  expect(copies).toEqual([{ text: BIG.sessionId ?? '', surface: 'terminal' }])
  await ui.unmount()
})

test('Copy session id is absent for an id that is not plain', async ($, on) => {
  seedRun(on, { ...BIG, sessionId: 'bad id; with spaces' })
  on('clock.now', () => ({ value: 30_000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'copy-session' })).toBeUndefined()
  await ui.unmount()
})

test('stderr button is absent without errTail', async ($, on) => {
  seedRun(on, { ...BIG, errTail: null })
  on('clock.now', () => ({ value: 30_000 }))
  on('ui.copy', () => ({ value: { isCopied: true } }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ key: 'toggle-err' })).toBeUndefined()
  await ui.unmount()
})

test('stderr button toggles the tail into view', async ($, on) => {
  seedRun(on, { ...BIG, errTail: 'boom' })
  on('clock.now', () => ({ value: 30_000 }))
  on('ui.copy', () => ({ value: { isCopied: true } }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ key: 'toggle-err' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^stderr:/ })).toBeUndefined()
  await ui.press({ key: 'toggle-err' })
  expect((await ui.find({ type: 'Text', text: /^stderr:/ }))?.text).toMatch(/^stderr: boom/)
  await ui.unmount()
})

test('the pane draws a devin summary when the run has ended', async ($, on) => {
  const text = generateLines({ backend: 'devin', events: 12, seed: 1 }).join('\n')
  const run = applyDevinExport({ ...emptyRun(8, 'devin'), startedAt: 0 }, text, 0)
  seedRun(on, run)
  on('clock.now', () => ({ value: 30_000 }))
  on('ui.copy', () => ({ value: { isCopied: true } }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /PASSED/ }))?.text).toMatch(/PASSED/)
  expect((await ui.find({ type: 'Text', text: /Devin #8/ }))?.text).toContain('Devin #8')
  expect((await ui.find({ type: 'Text', text: /gpt-6-1-terra-high/ }))?.text).toContain(
    'gpt-6-1-terra-high',
  )
  await ui.unmount()
})

test('with no run the pane says so', async ($, on) => {
  on('clock.now', () => ({ value: 30_000 }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect((await ui.find({ type: 'Text' }))?.text).toBe('No /exec run yet.')
  await ui.unmount()
})

test('now row names the work, task row shows plan and scope, quiet time is shown', async ($, on) => {
  const run: Run = {
    ...emptyRun(4, 'cursor'),
    sessionId: 'abcdef-1234-5678',
    startedAt: 0,
    lastGrowthAt: 0,
    lines: 10,
    tool: 'edit',
    toolDetail: 'view.tsx',
    tools: 3,
    task: { plan: 'agent-workflow-consolidation', scope: 'S7, S8, S10' },
    lastMessage: 'Now editing the view.',
  }
  seedRun(on, run)
  on('clock.now', () => ({ value: 25_000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^task:/ }))?.text).toBe(
    'task: agent-workflow-consolidation · S7, S8, S10',
  )
  const now = (await ui.find({ type: 'Text', text: /^now:/ }))?.text ?? ''
  expect(now).toContain('⚙ edit view.tsx')
  expect((await ui.find({ type: 'Text', text: /quiet 25s$/ }))?.text).toBe('▰▰▰▱▱▱▱▱▱▱ quiet 25s')
  expect((await ui.find({ type: 'Text', text: /^says:/ }))?.text).toBe('says: Now editing the view.')
  await ui.unmount()
})

test('Show filter cycles all → msgs → tools → errors and narrows the timeline', async ($, on) => {
  seedRun(on, BIG)
  on('clock.now', () => ({ value: 30_000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'filter' }))?.text).toBe('Show: all')

  await ui.press({ key: 'filter' })
  expect((await ui.find({ key: 'filter' }))?.text).toBe('Show: msgs')
  const msgRows = (await ui.findAll({ type: 'Text' })).map(n => n.text).filter(isTimeline)
  expect(msgRows.length).toBeGreaterThan(0)
  expect(msgRows.every(t => t?.startsWith('MSG'))).toBe(true)

  await ui.press({ key: 'filter' })
  await ui.press({ key: 'filter' })
  expect((await ui.find({ key: 'filter' }))?.text).toBe('Show: errors')
  expect((await ui.find({ type: 'Text', text: /^showing errors:/ }))?.text).toMatch(/of \d+/)
  await ui.unmount()
})

test('Copy resume cmd copies the backend resume command', async ($, on) => {
  const copies: string[] = []
  on('ui.copy', (_$, e) => {
    copies.push(String(e.text))
    return { value: { isCopied: true } }
  })
  on('clock.now', () => ({ value: 30_000 }))

  seedRun(on, BIG_AGY)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'copy-resume' })
  expect(copies).toEqual([`agy --conversation ${BIG_AGY.sessionId}`])
  await ui.unmount()
})

test('running badge spins with the frame, tags carry their kind color, sparkline shows', async ($, on) => {
  const run: Run = { ...BIG, result: null, exitCode: null, lastGrowthAt: 29_000, spark: [0, 3, 9, 1] }
  on('state.get', async (_$, e, next) => {
    if (e.key === 'run') return { value: { value: { shape: 'run-7', value: run }, version: 1 } }
    if (e.key === 'frame') return { value: { value: 2, version: 1 } }
    return next(e)
  })
  on('clock.now', () => ({ value: 30_000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /RUNNING/ }))?.text).toBe(` ${spinnerAt(2)} RUNNING `)
  const read = await ui.find({ type: 'Text', text: /^READ$/ })
  expect(read?.props.color).toBe(KIND_COLOR.read)
  expect((await ui.find({ type: 'Text', text: /^[ ▁-█]+$/ }))?.text).toBe(' ▃█▁')
  await ui.unmount()
})
