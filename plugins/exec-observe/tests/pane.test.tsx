import { expect, test } from 'claude-code/testing'

import { emptyRun, reduceLine } from '../hooks/reduce'
import { chromeRows } from '../hooks/view'
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
      return { value: { value: { shape: 'run-3', value: run }, version: 1 } }
    }
    // view / showErr: let the harness own them so set invalidates the drawing.
    return next(e)
  })
}

test('the pane draws header and counters on every surface for cursor and agy', async ($, on) => {
  let activeRun: Run = BIG
  on('state.get', async (_$, e, next) => {
    if (e.key === 'run') {
      return { value: { value: { shape: 'run-3', value: activeRun }, version: 1 } }
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
    expect((await cursorUi.find({ type: 'Text', text: /exec #2 \[cursor\]/ }))?.text).toContain(
      '[cursor]',
    )
    expect((await cursorUi.find({ type: 'Text', text: /read \d+/ }))?.text).toMatch(/read \d+/)
    expect((await cursorUi.find({ type: 'Text', text: /^now:/ }))?.text).toMatch(/^now:/)
    await cursorUi.unmount()

    activeRun = BIG_AGY
    const agyUi = await $.ui.mount({ ...PANE, surface })
    expect((await agyUi.find({ type: 'Text', text: /RUNNING|PASSED|FAILED|STALLED/ }))?.text).toMatch(
      /PASSED|RUNNING/,
    )
    expect((await agyUi.find({ type: 'Text', text: /exec #3 \[agy\]/ }))?.text).toContain('[agy]')
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
    // Badge and title share one row; the timeline and button rows each sit
    // under a one-row margin, and the buttons take one row.
    const headerRows = texts.length - timeline.length - 1
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

test('with no run the pane says so', async ($, on) => {
  on('clock.now', () => ({ value: 30_000 }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect((await ui.find({ type: 'Text' }))?.text).toBe('No /exec run yet.')
  await ui.unmount()
})
