import { atom, update } from 'claude-code'
import type { EngineInterface, RenderInput } from 'claude-code'

import type { Run, TimelineEntry, TimelineKind, ViewMode } from '../types'
import { elapsed, phaseOf, type Phase } from './reduce'

// Same refs as register.tsx; declared here so `update` is scannable in this file.
const viewAtom = atom({ plugin: 'evc-observe', key: 'view' } as const, 'compact' as ViewMode)
const showErrAtom = atom({ plugin: 'evc-observe', key: 'showErr' } as const, false)

// Rows outside the timeline, counted from the tree renderPane draws: every
// Text is one row (`wrap="truncate-end"`), and only the timeline, stderr and
// button rows carry a one-row top margin.
export const chromeRows = (run: Run, showErr: boolean, narrow: boolean): number => {
  const header = 1 + (run.sessionId ? 1 : 0) + (narrow ? 2 : 1) + 1 + 1 + 1
  const stderr = showErr && run.errTail ? 2 : 0
  const buttons = 2
  return header + 1 + stderr + buttons
}

// Timeline rows Compact shows, keeping one spare row for the pane's own chrome.
export const compactRoom = (run: Run, showErr: boolean, narrow: boolean, bodyRows: number): number =>
  Math.max(1, bodyRows - chromeRows(run, showErr, narrow) - 1)

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

const phaseColor = (phase: Phase): 'success' | 'error' | 'warning' | 'claude' => {
  if (phase === 'passed') return 'success'
  if (phase === 'failed') return 'error'
  if (phase === 'stalled') return 'warning'
  return 'claude'
}

const phaseLabel = (phase: Phase): string => {
  if (phase === 'passed') return ' PASSED '
  if (phase === 'failed') return ' FAILED '
  if (phase === 'stalled') return ' STALLED '
  return ' RUNNING '
}

const shortId = (id: string): string => (id.length <= 12 ? id : `${id.slice(0, 6)}…${id.slice(-4)}`)

const trunc = (text: string, max: number): string =>
  text.length <= max ? text : `${text.slice(0, Math.max(0, max - 1))}…`

const activityStrip = (tools: number): string => {
  const bars = 8
  const filled = tools === 0 ? 0 : ((tools - 1) % bars) + 1
  return `${'▰'.repeat(filled)}${'▱'.repeat(bars - filled)}`
}

const countersText = (run: Run): string => {
  const c = run.counts
  return `read ${c.read} · search ${c.search} · edit ${c.edit} · shell ${c.shell} · task ${c.task} · ✗ ${run.failedTools}`
}

const rowText = (entry: TimelineEntry, columns: number): string => {
  const tag = TAG[entry.kind].padEnd(4)
  const times = entry.count > 1 ? `${entry.count}× ` : ''
  const body = `${times}${entry.label}${entry.detail ? ` ${entry.detail}` : ''}`
  return trunc(`${tag} ${body}`, Math.max(8, columns))
}

export type PaneModel = {
  run: Run | null
  view: ViewMode
  showErr: boolean
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
  const props = e.props as PaneProps
  const columns = Math.max(20, props.bodyColumns ?? 60)
  const bodyRows = props.scroll?.bodyRows ?? 20

  if (!run) {
    return (
      <Box flexDirection="column" gap={1}>
        <Text dimColor>No execute-via-cursor run yet.</Text>
        <Text dimColor>Watching {watching || '.claude/tmp'}</Text>
      </Box>
    )
  }

  const phase = phaseOf(run, now)
  const color = phaseColor(phase)
  const took = run.result?.durationMs ?? (run.startedAt !== null ? now - run.startedAt : null)
  const counters = countersText(run)
  const narrow = columns < 60
  const room = compactRoom(run, showErr, narrow, bodyRows)
  const entries = view === 'compact' ? run.timeline.slice(-room) : run.timeline
  const one = 'truncate-end' as const

  const files =
    run.files.length === 0
      ? '—'
      : run.files.length <= 6
        ? run.files.join(', ')
        : `${run.files.slice(0, 6).join(', ')} +${run.files.length - 6} more`

  return (
    <Box flexDirection="column">
      <Box gap={1}>
        <Text backgroundColor={color} color="inverseText" bold wrap={one}>
          {phaseLabel(phase)}
        </Text>
        <Text bold wrap={one}>
          evc #{run.n}
          {took !== null ? ` · ${elapsed(took)}` : ''}
          {run.model ? ` · ${run.model}` : ''}
        </Text>
      </Box>
      {run.sessionId && (
        <Text dimColor wrap={one}>
          session {shortId(run.sessionId)}
        </Text>
      )}

      {narrow ? (
        <Box flexDirection="column">
          <Text wrap={one}>
            read {run.counts.read} · search {run.counts.search} · edit {run.counts.edit}
          </Text>
          <Text wrap={one}>
            shell {run.counts.shell} · task {run.counts.task} · ✗ {run.failedTools}
          </Text>
        </Box>
      ) : (
        <Text wrap={one}>{counters}</Text>
      )}
      <Text dimColor wrap={one}>
        activity {activityStrip(run.tools)} · {run.tools} tool calls
      </Text>

      <Text wrap={one}>
        now: {run.tool ? `${run.tool}${run.toolDetail ? ` ${run.toolDetail}` : ''}` : 'thinking'}
      </Text>
      <Text wrap={one}>files: {files}</Text>

      <Box flexDirection="column" marginTop={1}>
        {view === 'full' && run.droppedEntries > 0 && (
          <Text dimColor wrap={one}>
            … {run.droppedEntries} earlier entries dropped
          </Text>
        )}
        {entries.map(entry => {
          const isErr = entry.kind === 'error' || entry.isOk === false
          const isMsg = entry.kind === 'msg'
          return (
            <Text color={isErr ? 'error' : undefined} dimColor={isMsg} italic={isMsg} wrap={one}>
              {rowText(entry, columns)}
            </Text>
          )
        })}
      </Box>

      {showErr && run.errTail && (
        <Box marginTop={1}>
          <Text color="error" wrap={one}>
            stderr: {run.errTail}
          </Text>
        </Box>
      )}

      <Box gap={1} marginTop={1}>
        {run.sessionId && (
          <Button
            key="copy-session"
            label="Copy session id"
            onPress={press => $.ui.copy({ text: run.sessionId!, surface: press.surface })}
          />
        )}
        <Button
          key="toggle-view"
          label={view === 'compact' ? 'Full' : 'Compact'}
          onPress={() => update($, viewAtom, current => (current === 'compact' ? 'full' : 'compact'))}
        />
        {run.errTail && (
          <Button
            key="toggle-err"
            label={showErr ? 'Hide stderr' : 'Show stderr'}
            onPress={() => update($, showErrAtom, current => !current)}
          />
        )}
      </Box>
    </Box>
  )
}
