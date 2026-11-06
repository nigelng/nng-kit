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

export type Backend = 'cursor' | 'agy' | 'devin'

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
  // What the agent is doing between tool calls: reasoning or streaming a reply.
  doing: 'thinking' | 'writing' | null
  // Raw text of the assistant message still streaming (null once closed), so
  // deltas join exactly as sent instead of with an invented space.
  msgRaw: string | null
  // Latest full assistant message (tail-capped), for the "says" row.
  lastMessage: string | null
  // From the run's brief: plan name and step scope, when the brief exists.
  task: RunTask | null
  // New events per poll, oldest first, for the activity sparkline.
  spark: number[]
  // Wall-clock time (epoch ms) of the newest stream event carrying one
  // (Cursor's `timestamp_ms`); null for streams without timestamps.
  lastEventAt: number | null
  // When the run ended: the `.exit` file's mtime, once it exists.
  endedAt: number | null
}

export type RunTask = { plan: string | null; scope: string | null }

export type TimelineFilter = 'all' | 'msgs' | 'tools' | 'errors'

export type ViewMode = 'compact' | 'full'

declare module 'claude-code' {
  interface PluginState {
    'exec-observe': {
      run: Shaped<Run | null>
      view: ViewMode
      showErr: boolean
      filter: TimelineFilter
      frame: number
    }
  }
}
