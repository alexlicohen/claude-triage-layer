#!/usr/bin/env node
// Scenario tests for workflows/triage-run.js — executes the ACTUAL workflow body
// under mocked DSL globals (agent/parallel/log/phase) and asserts the control flow.
// The Workflow DSL sandbox is not available outside Claude Code, so this is the
// closest runnable seam check: same source, scripted agent responses.
//
// Fail-loud runner: accumulates all failures, prints RESULT line, exits non-zero
// on any failure.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, '..', 'workflows', 'triage-run.js'), 'utf8')
  .replace(/^export const meta/m, 'const meta')

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let pass = 0
let fail = 0
function chk(name, cond) {
  if (cond) { pass++; console.log(`PASS: ${name}`) }
  else { fail++; console.log(`FAIL: ${name}`) }
}

// Run the workflow body with a scripted agent. `script` maps a label-prefix (or
// 'classify' for the schema'd classify call) to an array of queued responses;
// a queue exhausting falls back to its last entry. Returns {result, logs, calls}.
async function run(script) {
  const logs = []
  const calls = [] // { label, prompt }
  const queues = new Map(Object.entries(script).map(([k, v]) => [k, [...v]]))

  function scripted(key) {
    const q = queues.get(key)
    if (!q || q.length === 0) return undefined
    return q.length > 1 ? q.shift() : q[0]
  }

  async function agent(prompt, opts = {}) {
    const label = opts.label || (opts.schema ? 'classify' : '(none)')
    calls.push({ label, prompt })
    // longest-prefix match against the script keys
    let best
    for (const key of queues.keys()) {
      if (label.startsWith(key) && (!best || key.length > best.length)) best = key
    }
    if (best === undefined) throw new Error(`unscripted agent call: label=${label}`)
    return scripted(best)
  }

  const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
  const pipeline = async (items, ...stages) => {
    const out = []
    for (const [i, item] of items.entries()) {
      let v = item
      try { for (const s of stages) v = await s(v, item, i) } catch { v = null }
      out.push(v)
    }
    return out
  }
  const log = m => logs.push(String(m))
  const phase = () => {}

  const fn = new AsyncFunction('args', 'log', 'phase', 'agent', 'parallel', 'pipeline', src)
  const result = await fn('test task', log, phase, agent, parallel, pipeline)
  return { result, logs, calls }
}

const PLAN = (objective, subtasks) => ({ objective_check: objective, subtasks })
const ST = (desc, tier, files, danger = false) => ({ desc, tier, files, acceptance: 'works', danger })

const countCalls = (calls, prefix) => calls.filter(c => c.label.startsWith(prefix)).length

// ---- Scenario 1: no danger, objective PASS → single gate, no reviewer, no remediation
{
  const { result, calls } = await run({
    classify: [PLAN('make test', [ST('t1', 'builder', ['a.js'])])],
    'builder:': ['did t1'],
    'verify:objective-check': ['all good\nPASS'],
  })
  chk('S1: objective-only path — no reviewer spawned', countCalls(calls, 'verify:reviewer') === 0)
  chk('S1: no remediation on PASS', result.remediation === null)
  chk('S1: not incomplete', result.verification.incomplete !== true)
}

// ---- Scenario 2: danger subtask + objective check → BOTH gates run (seam)
{
  const { result, calls } = await run({
    classify: [PLAN('make test', [ST('core edit', 'deep', ['core.js'], true)])],
    'deep:': ['did core edit'],
    'verify:objective-check': ['ok\nPASS'],
    'verify:reviewer': ['PASS'],
  })
  chk('S2: seam runs objective gate', countCalls(calls, 'verify:objective-check') === 1)
  chk('S2: seam runs reviewer gate', countCalls(calls, 'verify:reviewer') === 1)
  chk('S2: verification.type is seam', result.verification.type === 'seam')
  chk('S2: no remediation when both gates pass', result.remediation === null)
}

// ---- Scenario 3: FIX naming one subtask's file → targeted remediation, same tier
{
  const { result, calls } = await run({
    classify: [PLAN(null, [ST('parser work', 'builder', ['src/parse.js']), ST('docs work', 'quick', ['README.md'])])],
    'builder:': ['did parser'],
    'quick:': ['did docs'],
    'verify:reviewer': ['FIX: src/parse.js mishandles empty input'],
    'redo:': ['fixed parser'],
    'verify:re-review': ['PASS'],
  })
  chk('S3: exactly one subtask re-run', countCalls(calls, 'redo:') === 1)
  chk('S3: implicated names the parser subtask only',
    result.remediation.implicated.length === 1 && result.remediation.implicated[0].desc === 'parser work')
  chk('S3: attribution did not fail', result.remediation.attributionFailed === false)
  chk('S3: not escalated (FIX = same tier)', result.remediation.escalated === false)
}

// ---- Scenario 4: ESCALATE naming no files → ALL re-run one tier up, attribution-failure logged
{
  const { result, logs, calls } = await run({
    classify: [PLAN(null, [ST('t1', 'quick', ['a.js']), ST('t2', 'builder', ['b.js'])])],
    'quick:': ['did t1'],
    'builder:': ['did t2'],
    'verify:reviewer': ['ESCALATE: approach is wrong overall'],
    'redo:': ['redone'],
    'verify:re-review': ['PASS'],
  })
  chk('S4: all subtasks re-run', countCalls(calls, 'redo:') === 2)
  chk('S4: attribution failure logged', logs.some(l => l.includes('attribution matched no subtask files')))
  chk('S4: escalated flag set', result.remediation.escalated === true)
}

// ---- Scenario 5 (#7): objective gate null once, PASS on retry → retried, clean
{
  const { result, logs, calls } = await run({
    classify: [PLAN('make test', [ST('t1', 'builder', ['a.js'])])],
    'builder:': ['did t1'],
    'verify:objective-check': [null, 'ok\nPASS'],
  })
  chk('S5: gate retried once', countCalls(calls, 'verify:objective-check') === 2)
  chk('S5: retry logged', logs.some(l => l.includes('retrying the gate once')))
  chk('S5: not incomplete after successful retry', result.verification.incomplete !== true)
  chk('S5: no remediation', result.remediation === null)
}

// ---- Scenario 6 (#7): objective gate null twice → INCOMPLETE, no remediation, loud log
{
  const { result, logs, calls } = await run({
    classify: [PLAN('make test', [ST('t1', 'builder', ['a.js'])])],
    'builder:': ['did t1'],
    'verify:objective-check': [null, null],
  })
  chk('S6: gate tried exactly twice', countCalls(calls, 'verify:objective-check') === 2)
  chk('S6: verification.incomplete === true', result.verification.incomplete === true)
  chk('S6: NO remediation on a dead gate (no signal to act on)', result.remediation === null)
  chk('S6: INCOMPLETE logged loudly', logs.some(l => l.includes('VERIFICATION INCOMPLETE')))
}

// ---- Scenario 7 (#7): review-only path, reviewer null twice → INCOMPLETE, no remediation
{
  const { result, logs } = await run({
    classify: [PLAN(null, [ST('t1', 'builder', ['a.js'])])],
    'builder:': ['did t1'],
    'verify:reviewer': [null, null],
  })
  chk('S7: verification.incomplete === true', result.verification.incomplete === true)
  chk('S7: no remediation', result.remediation === null)
  chk('S7: INCOMPLETE logged', logs.some(l => l.includes('VERIFICATION INCOMPLETE')))
}

// ---- Scenario 8 (#7): seam — objective dead, reviewer gives real FIX → remediation
// still runs on the reviewer's feedback AND the result stays flagged if a gate is dead
{
  const { result, calls } = await run({
    classify: [PLAN('make test', [ST('core edit', 'deep', ['core.js'], true)])],
    'deep:': ['did core edit'],
    'verify:objective-check': [null], // dead on every attempt (initial + retry + re-verify)
    'verify:reviewer': ['FIX: core.js breaks the seam'],
    'redo:': ['fixed core'],
    'verify:recheck': [null],
    'verify:re-review': ['PASS'],
  })
  chk('S8: remediation ran on the live gate\'s feedback', result.remediation !== null)
  chk('S8: remediation targeted core.js', result.remediation.implicated.some(i => i.matched.includes('core.js')))
  chk('S8: final verification flagged incomplete (objective gate still dead)', result.verification.incomplete === true)
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
