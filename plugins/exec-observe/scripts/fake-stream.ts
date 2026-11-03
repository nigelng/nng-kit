#!/usr/bin/env node
// Node 24 CLI over the pure generator. Tests must not import this file
// (node: imports fail under `claude plugin test`).
import fs from 'node:fs'
import path from 'node:path'

import {
  generateLines,
  type GenerateBackend,
  type GenerateOutcome,
} from './generate.ts'

type Args = {
  backend: GenerateBackend
  events: number
  seed: number
  out: string | null
  replay: string | null
  dir: string | null
  n: number
  rate: number
  burst: boolean
  outcome: GenerateOutcome
  finishReason: string | undefined
}

const usage = (): never => {
  console.error(
    'usage: fake-stream.ts [--backend cursor|agy] [--events N] [--seed N] [--out file] | [--replay <repo>] [--dir <tmp>] [--n 900] [--rate 250] [--burst] [--outcome pass|fail|print_timeout]',
  )
  process.exit(2)
}

const isBackend = (value: string): value is GenerateBackend =>
  value === 'cursor' || value === 'agy'

const isOutcome = (value: string): value is GenerateOutcome =>
  value === 'pass' || value === 'fail' || value === 'print_timeout'

const parseArgs = (argv: string[]): Args => {
  if (argv.length === 0) usage()
  const args: Args = {
    backend: 'cursor',
    events: 5000,
    seed: 1,
    out: null,
    replay: null,
    dir: null,
    n: 900,
    rate: 250,
    burst: false,
    outcome: 'pass',
    finishReason: undefined,
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) usage()
      return v
    }
    if (a === '--backend') {
      const b = next()
      if (!isBackend(b)) usage()
      args.backend = b
    } else if (a === '--events') args.events = Number(next())
    else if (a === '--seed') args.seed = Number(next())
    else if (a === '--out') args.out = next()
    else if (a === '--replay') args.replay = next()
    else if (a === '--dir' || a === '--tmp') args.dir = next()
    else if (a === '--n') args.n = Number(next())
    else if (a === '--rate') args.rate = Number(next())
    else if (a === '--burst') args.burst = true
    else if (a === '--outcome') {
      const o = next()
      if (!isOutcome(o)) usage()
      args.outcome = o
    } else if (a === '--finish-reason') args.finishReason = next()
    else usage()
  }
  if (!Number.isFinite(args.events) || args.events < 1) usage()
  if (!Number.isFinite(args.seed)) usage()
  if (args.out === null && (!Number.isFinite(args.n) || !Number.isFinite(args.rate) || args.rate <= 0))
    usage()
  return args
}

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))

const resolveTmpDir = (args: Args): string => {
  if (args.dir !== null) return path.resolve(args.dir)
  if (args.replay !== null) return path.join(path.resolve(args.replay), '.claude', 'tmp')
  return process.cwd()
}

const main = async (): Promise<void> => {
  const args = parseArgs(process.argv.slice(2))
  const lines = generateLines({
    backend: args.backend,
    events: args.events,
    seed: args.seed,
    outcome: args.outcome,
    finishReason: args.finishReason,
  })

  if (args.out) {
    fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true })
    fs.writeFileSync(args.out, lines.map(l => `${l}\n`).join(''))
    return
  }

  const tmp = resolveTmpDir(args)
  const base = path.join(tmp, `exec-run-${args.backend}-${args.n}`)
  for (const ext of ['.ndjson', '.err', '.exit'] as const) {
    if (fs.existsSync(base + ext)) {
      console.error(`refuse: ${base}${ext} already exists (won't overwrite a real run)`)
      process.exit(1)
    }
  }

  fs.mkdirSync(tmp, { recursive: true })
  const ndjson = `${base}.ndjson`
  const err = `${base}.err`
  fs.writeFileSync(ndjson, '')
  fs.writeFileSync(err, '')

  const intervalMs = 1000 / args.rate
  let wrote = 0
  for (const row of lines) {
    fs.appendFileSync(ndjson, `${row}\n`)
    wrote += 1
    if (wrote === Math.floor(lines.length / 3)) {
      fs.appendFileSync(err, 'warning: fake replay mid-stream\n')
    }
    if (wrote === Math.floor((lines.length * 2) / 3)) {
      fs.appendFileSync(err, 'warning: fake replay near end\n')
    }
    if (!args.burst) await sleep(intervalMs)
  }

  fs.writeFileSync(`${base}.exit`, args.outcome === 'fail' ? '1\n' : '0\n')
}

main().catch(error => {
  console.error(error)
  process.exit(1)
})
