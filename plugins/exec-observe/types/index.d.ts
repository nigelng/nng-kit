export type RunResult = { isOk: boolean; subtype: string; durationMs: number | null }

export type TimelineKind =
  | 'msg'
  | 'read'
  | 'search'
  | 'edit'
  | 'shell'
  | 'task'
  | 'tool'
  | 'error'
  | 'result'

export type TimelineEntry = {
  kind: TimelineKind
  label: string
  detail: string | null
  count: number
  isOk: boolean | null
}

export type KindCounts = Record<TimelineKind, number>

export type Backend = 'cursor' | 'agy'

export type Run = {
  n: number
  backend: Backend
  sessionId: string | null
  model: string | null
  tool: string | null
  toolDetail: string | null
  tools: number
  files: string[]
  snippet: string | null
  result: RunResult | null
  exitCode: number | null
  errTail: string | null
  lines: number
  badLines: number
  startedAt: number | null
  lastGrowthAt: number | null
  timeline: TimelineEntry[]
  counts: KindCounts
  failedTools: number
  droppedEntries: number
}

export type ViewMode = 'compact' | 'full'

declare module 'claude-code' {
  interface PluginState {
    'exec-observe': {
      run: Shaped<Run | null>
      view: ViewMode
      showErr: boolean
    }
  }
}
