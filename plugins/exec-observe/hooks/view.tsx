import { atom, update } from 'claude-code'
import type { EngineInterface, RenderInput } from 'claude-code'

import type { Run, TimelineEntry, TimelineFilter, TimelineKind, ViewMode } from '../types'
import {
  backendName,
  cleanErrTail,
  doingLabel,
  isCopyableId,
  elapsed,
  phaseOf,
  resumeCommand,
  runElapsed,
  sparkline,
  STALL_MS,
  taskLabel,
  type Phase,
} from './reduce'

// Same refs as register.tsx; declared here so `update` is scannable in this file.
const viewAtom = atom({ plugin: 'exec-observe', key: 'view' } as const, 'compact' as ViewMode)
const showErrAtom = atom({ plugin: 'exec-observe', key: 'showErr' } as const, false)
const filterAtom = atom({ plugin: 'exec-observe', key: 'filter' } as const, 'all' as TimelineFilter)

// Below this, a quiet stream is normal (a long tool call, a slow token); above
// it the "now" row says how long it has been quiet.
const QUIET_MS = 10_000

const FILTERS: readonly TimelineFilter[] = ['all', 'msgs', 'tools', 'errors']

const nextFilter = (filter: TimelineFilter): TimelineFilter =>
  FILTERS[(FILTERS.indexOf(filter) + 1) % FILTERS.length] ?? 'all'

const isErrEntry = (entry: TimelineEntry): boolean => entry.kind === 'error' || entry.isOk === false

export const matchesFilter = (entry: TimelineEntry, filter: TimelineFilter): boolean => {
  if (filter === 'msgs') return entry.kind === 'msg'
  if (filter === 'errors') return isErrEntry(entry)
  if (filter === 'tools') return entry.kind !== 'msg' && entry.kind !== 'result'
  return true
}

const isQuiet = (run: Run, now: number, phase: Phase): boolean =>
  phase === 'stalled' ||
  (phase === 'running' && run.lastGrowthAt !== null && now - run.lastGrowthAt > QUIET_MS)

// Rows outside the timeline, counted from the tree renderPane draws: every
// Text is one row (`wrap="truncate-end"`), and only the timeline, stderr and
// button rows carry a one-row top margin. Narrow panes let the buttons wrap
// onto a second row.
export const chromeRows = (
  run: Run,
  showErr: boolean,
  narrow: boolean,
  filter: TimelineFilter = 'all',
): number => {
  const header =
    1 + // badge · backend · elapsed · model
    (taskLabel(run.task) ? 1 : 0) +
    1 + // now
    (run.lastMessage ? 1 : 0) +
    1 + // counters
    1 + // files
    1 + // session · events · last event
    (filter !== 'all' ? 1 : 0)
  const stderr = showErr && run.errTail ? 2 : 0
  const buttons = narrow ? 3 : 2
  return header + 1 + stderr + buttons
}

// Timeline rows Compact shows, keeping one spare row for the pane's own chrome.
export const compactRoom = (
  run: Run,
  showErr: boolean,
  narrow: boolean,
  bodyRows: number,
  filter: TimelineFilter = 'all',
): number => Math.max(1, bodyRows - chromeRows(run, showErr, narrow, filter) - 1)

const TAG: Record<TimelineKind, string> = {
  msg: 'MSG',
  read: 'READ',
  search: 'SRCH',
  edit: 'EDIT',
  shell: 'SH',
  task: 'TASK',
  tool: 'TOOL',
  error: 'ERR',
  result: 'RES',
}

// One theme color per kind, so the timeline reads by color before by text.
type Tone = 'suggestion' | 'ide' | 'success' | 'bashBorder' | 'planMode' | 'subtle' | 'error' | 'inactive' | 'warning' | 'claude'
export const KIND_COLOR: Record<TimelineKind, Tone> = {
  msg: 'inactive',
  read: 'suggestion',
  search: 'ide',
  edit: 'success',
  shell: 'bashBorder',
  task: 'planMode',
  tool: 'subtle',
  error: 'error',
  result: 'success',
}

const entryColor = (entry: TimelineEntry): Tone =>
  isErrEntry(entry) ? 'error' : KIND_COLOR[entry.kind]

const SPINNER = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
export const spinnerAt = (frame: number): string => SPINNER[frame % SPINNER.length] ?? '⠋'

// Fills toward the stall threshold; warning past half, then error-like stall.
export const quietGauge = (quietMs: number): string => {
  const cells = 10
  const filled = Math.min(cells, Math.max(0, Math.round((quietMs / STALL_MS) * cells)))
  return `${'▰'.repeat(filled)}${'▱'.repeat(cells - filled)}`
}

const phaseColor = (phase: Phase): 'success' | 'error' | 'warning' | 'claude' => {
  if (phase === 'passed') return 'success'
  if (phase === 'failed') return 'error'
  if (phase === 'stalled') return 'warning'
  return 'claude'
}

const phaseLabel = (phase: Phase, frame: number): string => {
  if (phase === 'passed') return ' ✓ PASSED '
  if (phase === 'failed') return ' ✗ FAILED '
  if (phase === 'stalled') return ' ⚠ STALLED '
  return ` ${spinnerAt(frame)} RUNNING `
}

export { isCopyableId }

const shortId = (id: string): string => (id.length <= 12 ? id : `${id.slice(0, 6)}…${id.slice(-4)}`)

const trunc = (text: string, max: number): string =>
  text.length <= max ? text : `${text.slice(0, Math.max(0, max - 1))}…`

const compactNum = (n: number): string => (n < 1000 ? String(n) : `${(n / 1000).toFixed(1)}k`)

// Only the kinds that happened, so the row reads at a glance.
export const countersText = (run: Run): string => {
  const c = run.counts
  const parts = (['read', 'search', 'edit', 'shell', 'task', 'tool'] as const)
    .filter(kind => c[kind] > 0)
    .map(kind => `${kind} ${c[kind]}`)
  const tools = `${run.tools} tool call${run.tools === 1 ? '' : 's'}`
  return parts.length ? `${tools}: ${parts.join(' · ')}` : tools
}

// What the agent is doing this moment, with a glyph per kind of work.
export const nowText = (run: Run, phase: Phase): string => {
  if (phase === 'passed') return 'finished'
  if (phase === 'failed') return run.exitCode !== null && run.exitCode !== 0 ? `exited ${run.exitCode}` : 'failed'
  const glyph = run.tool ? '⚙' : run.doing === 'writing' ? '✎' : '…'
  return `${glyph} ${doingLabel(run)}`
}

const tagText = (entry: TimelineEntry): string => TAG[entry.kind].padEnd(4)

const bodyText = (entry: TimelineEntry, columns: number): string => {
  const times = entry.count > 1 ? `${entry.count}× ` : ''
  const body = `${times}${entry.label}${entry.detail ? ` ${entry.detail}` : ''}`
  return trunc(body, Math.max(3, columns - 5))
}

export type PaneModel = {
  run: Run | null
  view: ViewMode
  showErr: boolean
  filter?: TimelineFilter
  frame?: number
  watching: string
}

type PaneProps = {
  bodyColumns?: number
  scroll?: { bodyRows?: number }
}

// Top-level so `claude plugin validate` accepts `$` into helpers.
export function renderPane($: EngineInterface, e: RenderInput, model: PaneModel, now: number) {
  const { Box, Text, Button } = $.ui.resolve(e)
  const { run, view, showErr, watching } = model
  const filter = model.filter ?? 'all'
  const frame = model.frame ?? 0
  const props = e.props as PaneProps
  const columns = Math.max(20, props.bodyColumns ?? 60)
  const bodyRows = props.scroll?.bodyRows ?? 20

  if (!run) {
    return (
      <Box flexDirection="column" gap={1}>
        <Text dimColor>No /exec run yet.</Text>
        <Text dimColor>Watching {watching || '.claude/tmp'}</Text>
      </Box>
    )
  }

  const phase = phaseOf(run, now)
  const color = phaseColor(phase)
  const took = runElapsed(run, now)
  const narrow = columns < 60
  const room = compactRoom(run, showErr, narrow, bodyRows, filter)
  const matched = filter === 'all' ? run.timeline : run.timeline.filter(entry => matchesFilter(entry, filter))
  const entries = view === 'compact' ? matched.slice(-room) : matched
  const one = 'truncate-end' as const
  const rowWrap = view === 'full' ? ('wrap' as const) : one
  const task = taskLabel(run.task)
  const quiet = isQuiet(run, now, phase)
  const quietFor = run.lastGrowthAt !== null ? now - run.lastGrowthAt : 0
  const resume = resumeCommand(run)
  const lastEntry = run.timeline[run.timeline.length - 1]
  const nowColor: Tone | undefined =
    phase === 'stalled'
      ? 'warning'
      : phase !== 'running'
        ? undefined
        : run.tool && lastEntry
          ? entryColor(lastEntry)
          : 'claude'

  const files =
    run.files.length === 0
      ? 'none yet'
      : run.files.length <= 6
        ? run.files.join(', ')
        : `${run.files.slice(0, 6).join(', ')} +${run.files.length - 6} more`

  const lastEvent =
    run.lastGrowthAt !== null && phase !== 'passed' && phase !== 'failed'
      ? ` · last event ${elapsed(quietFor)} ago`
      : ''

  return (
    <Box flexDirection="column">
      <Box gap={1}>
        <Text backgroundColor={color} color="inverseText" bold wrap={one}>
          {phaseLabel(phase, frame)}
        </Text>
        <Text bold wrap={one}>
          {backendName(run.backend)} #{run.n}
          {took !== null ? ` · ${elapsed(took)}` : ''}
          {run.model ? ` · ${run.model}` : ''}
        </Text>
      </Box>
      {task && (
        <Text bold wrap={one}>
          task: {task}
        </Text>
      )}

      <Box gap={1}>
        <Text color={nowColor} bold={phase === 'running'} wrap={one}>
          now: {nowText(run, phase)}
        </Text>
        {quiet && (
          <Text color={phase === 'stalled' || quietFor > STALL_MS / 2 ? 'warning' : 'subtle'} wrap={one}>
            {quietGauge(quietFor)} quiet {elapsed(quietFor)}
          </Text>
        )}
      </Box>
      {run.lastMessage && (
        <Text dimColor italic wrap={one}>
          says: {run.lastMessage}
        </Text>
      )}

      <Box gap={1}>
        <Text wrap={one}>{countersText(run)}</Text>
        {run.failedTools > 0 && (
          <Text color="error" wrap={one}>
            · {run.failedTools} failed
          </Text>
        )}
      </Box>
      <Text color={run.files.length ? 'success' : 'subtle'} wrap={one}>
        edited ({run.files.length}): {files}
      </Text>
      <Box gap={1}>
        {run.spark.some(n => n > 0) && (
          <Text color={phase === 'running' ? 'claude' : 'subtle'} wrap={one}>
            {sparkline(run.spark)}
          </Text>
        )}
        <Text dimColor wrap={one}>
          {run.sessionId ? `session ${shortId(run.sessionId)} · ` : ''}
          {compactNum(run.lines)} events{lastEvent}
        </Text>
      </Box>
      {filter !== 'all' && (
        <Text dimColor wrap={one}>
          showing {filter}: {matched.length} of {run.timeline.length}
        </Text>
      )}

      <Box flexDirection="column" marginTop={1}>
        {view === 'full' && filter === 'all' && run.droppedEntries > 0 && (
          <Text dimColor wrap={one}>
            … {run.droppedEntries} earlier entries dropped
          </Text>
        )}
        {entries.length === 0 && (
          <Text dimColor wrap={one}>
            {filter === 'all' ? 'No events yet.' : `No ${filter} yet.`}
          </Text>
        )}
        {entries.map(entry => {
          const isMsg = entry.kind === 'msg'
          const isErr = isErrEntry(entry)
          return (
            <Box gap={1}>
              <Text color={entryColor(entry)} bold={!isMsg} wrap={one}>
                {tagText(entry)}
              </Text>
              <Text color={isErr ? 'error' : undefined} dimColor={isMsg} italic={isMsg} wrap={rowWrap}>
                {view === 'full' ? bodyText(entry, Number.MAX_SAFE_INTEGER) : bodyText(entry, columns)}
              </Text>
            </Box>
          )
        })}
      </Box>

      {showErr && run.errTail && (
        <Box marginTop={1}>
          <Text color="error" wrap={one}>
            stderr: {cleanErrTail(run.errTail)}
          </Text>
        </Box>
      )}

      <Box gap={1} marginTop={1} flexWrap="wrap">
        <Button
          key="toggle-view"
          hotkey="v"
          label={view === 'compact' ? 'Full' : 'Compact'}
          onPress={() => update($, viewAtom, current => (current === 'compact' ? 'full' : 'compact'))}
        />
        <Button
          key="filter"
          hotkey="f"
          label={`Show: ${filter}`}
          onPress={() => update($, filterAtom, current => nextFilter(current ?? 'all'))}
        />
        {run.sessionId && isCopyableId(run.sessionId) && (
          <Button
            key="copy-session"
            hotkey="c"
            label="Copy session id"
            dimColor
            onPress={press => $.ui.copy({ text: run.sessionId!, surface: press.surface })}
          />
        )}
        {resume && (
          <Button
            key="copy-resume"
            hotkey="r"
            label="Copy resume cmd"
            dimColor
            onPress={press => $.ui.copy({ text: resume, surface: press.surface })}
          />
        )}
        {run.errTail && (
          <Button
            key="toggle-err"
            hotkey="e"
            label={showErr ? 'Hide stderr' : 'Show stderr'}
            onPress={() => update($, showErrAtom, current => !current)}
          />
        )}
      </Box>
    </Box>
  )
}
