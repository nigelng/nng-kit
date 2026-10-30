#!/usr/bin/env node
// Node 24 CLI over the pure generator. Tests must not import this file
// (node: imports fail under `claude plugin test`).
import fs from 'node:fs'
import path from 'node:path'

import { generate } from './generate.ts'

type Args = {
  events: number
  seed: number
  out: string | null
  replay: string | null
  n: number
  rate: number
}

const usage = (): never => {
  console.error(
    'usage: fake-stream.ts --events N [--seed N] [--out file] | --replay <repo> [--n 900] [--rate 250]',
  )
  process.exit(2)
}

const parseArgs = (argv: string[]): Args => {
  const args: Args = { events: 5000, seed: 1, out: null, replay: null, n: 900, rate: 250 }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) usage()
      return v
    }
    if (a === '--events') args.events = Number(next())
    else if (a === '--seed') args.seed = Number(next())
    else if (a === '--out') args.out = next()
    else if (a === '--replay') args.replay = next()
    else if (a === '--n') args.n = Number(next())
    else if (a === '--rate') args.rate = Number(next())
    else usage()
  }
  if (!Number.isFinite(args.events) || args.events < 1) usage()
  if (!Number.isFinite(args.seed)) usage()
  if (args.replay === null && args.out === null) usage()
  if (args.replay !== null && (!Number.isFinite(args.n) || !Number.isFinite(args.rate) || args.rate <= 0))
    usage()
  return args
}

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))

const main = async (): Promise<void> => {
  const args = parseArgs(process.argv.slice(2))
  const lines = generate({ events: args.events, seed: args.seed })

  if (args.out) {
    fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true })
    fs.writeFileSync(args.out, lines.map(l => `${l}\n`).join(''))
    return
  }

  const repo = path.resolve(args.replay!)
  const tmp = path.join(repo, '.claude', 'tmp')
  const base = path.join(tmp, `evc-run-${args.n}`)
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
    await sleep(intervalMs)
  }

  fs.writeFileSync(`${base}.exit`, '0\n')
}

main().catch(error => {
  console.error(error)
  process.exit(1)
})
