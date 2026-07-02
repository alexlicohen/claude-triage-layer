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

// A budget mock with no target set — the legacy/identity case: remaining() is
// Infinity, so every budget branch in the workflow short-circuits.
const NO_BUDGET = { total: null, remaining: () => Infinity, spent: () => 0 }

// Run the workflow body with a scripted agent. `script` maps a label-prefix (or
// 'classify' for the schema'd classify call) to an array of queued responses;
// a queue exhausting falls back to its last entry. A queued value that is an Error
// instance is THROWN by agent() instead of returned — simulating the DSL's hard
// budget ceiling. `budget` overrides the mocked DSL budget global (default: none).
// Returns {result, logs, calls}.
async function run(script, budget = NO_BUDGET) {
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
    const val = scripted(best)
    if (val instanceof Error) throw val   // simulate the DSL hard budget ceiling
    return val
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

  const fn = new AsyncFunction('args', 'log', 'phase', 'agent', 'parallel', 'pipeline', 'budget', src)
  const result = await fn('test task', log, phase, agent, parallel, pipeline, budget)
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

// ---- Scenario 9: budget with total=null → IDENTITY. Same behavior as S1, plus a
// budget field reporting total:null / spent:0 / empty skipped. (Explicit NO_BUDGET,
// which is also the default the other 8 scenarios run under.)
{
  const { result, calls } = await run({
    classify: [PLAN('make test', [ST('t1', 'builder', ['a.js'])])],
    'builder:': ['did t1'],
    'verify:objective-check': ['all good\nPASS'],
  }, NO_BUDGET)
  chk('S9: budget field present with total:null', result.budget && result.budget.total === null)
  chk('S9: budget.skipped empty (nothing skipped in null mode)', Array.isArray(result.budget.skipped) && result.budget.skipped.length === 0)
  chk('S9: budget.spent is 0 in null mode', result.budget.spent === 0)
  chk('S9: identity — no reviewer spawned, no remediation, not incomplete',
    countCalls(calls, 'verify:reviewer') === 0 && result.remediation === null && result.verification.incomplete !== true)
}

// ---- Scenario 10: constrained budget — remaining() drops below RESERVE after the
// first subtask's pre-check → the second subtask is skipped and reported in
// return.budget.skipped, the skip is logged, and verification still runs on the work
// that DID complete. (RESERVE = 60_000 in the workflow.) remaining() returns a high
// value on its FIRST call (subtask A's pre-check) and a sub-reserve value after.
{
  let calls = 0
  const budget = { total: 200000, remaining: () => (++calls === 1 ? 150000 : 20000), spent: () => 180000 }
  const { result, logs, calls: agentCalls } = await run({
    classify: [PLAN('make test', [ST('sub A', 'builder', ['a.js']), ST('sub B', 'builder', ['b.js'])])],
    'builder:': ['did sub A'],
    'verify:objective-check': ['ok\nPASS'],
  }, budget)
  chk('S10: only the first subtask spawned (second skipped for budget)', countCalls(agentCalls, 'builder:') === 1)
  chk('S10: skipped subtask reported in return.budget.skipped',
    result.budget.skipped.some(s => s.stage.startsWith('Execute') && s.desc === 'sub B'))
  chk('S10: skip logged with what was skipped + remaining budget',
    logs.some(l => l.includes('Budget: skipping') && l.includes('sub B') && l.includes('20000')))
  chk('S10: verification still ran on the completed work',
    countCalls(agentCalls, 'verify:objective-check') === 1 && result.verification.incomplete !== true)
  chk('S10: budget report carries total + stamped spent', result.budget.total === 200000 && result.budget.spent === 180000)
}

// ---- Scenario 11: hard ceiling — agent() THROWS mid-execute (spent hit total). The
// throw is caught, the subtask recorded as skipped, and the workflow returns PARTIAL
// results + a budget report instead of crashing. remaining() stays high so pre-checks
// pass and the THROW (not a refusal) is what exercises the ceiling path.
{
  const budget = { total: 500000, remaining: () => 400000, spent: () => 250000 }
  const { result, logs } = await run({
    classify: [PLAN('make test', [ST('good sub', 'builder', ['a.js']), ST('ceiling sub', 'deep', ['b.js'])])],
    'builder:': ['did good sub'],
    'deep:': [new Error('agent() budget ceiling reached')],
    'verify:objective-check': ['ok\nPASS'],
  }, budget)
  chk('S11: partial results kept — the good subtask survived',
    result.results.length === 1 && result.results[0].subtask.desc === 'good sub')
  chk('S11: ceiling subtask recorded as skipped',
    result.budget.skipped.some(s => s.stage.startsWith('Execute') && s.desc === 'ceiling sub'))
  chk('S11: ceiling hit logged (caught, not crashed)', logs.some(l => l.includes('token ceiling')))
  chk('S11: returned a budget report + no error field (not a crash/abort)',
    result.budget.total === 500000 && result.budget.spent === 250000 && result.error === undefined)
  chk('S11: verification still ran on the partial results', result.verification && result.verification.incomplete !== true)
}

// ---- Scenario 12: budget below RESERVE from the start → EVERY subtask skipped →
// early return with an explicit error field (not a hollow empty success), and
// verification is never reached. (remaining() always < RESERVE.)
{
  const budget = { total: 100000, remaining: () => 5000, spent: () => 96000 }
  const { result, logs, calls } = await run({
    classify: [PLAN('make test', [ST('only sub', 'builder', ['a.js'])])],
    // 'builder:' intentionally unscripted — it must never be called (would throw).
    'verify:objective-check': ['should never run\nPASS'],
  }, budget)
  chk('S12: explicit error field on total budget exhaustion', typeof result.error === 'string' && result.error.includes('all subtasks skipped'))
  chk('S12: no results, all recorded in budget.skipped', result.results.length === 0 && result.budget.skipped.length === 1)
  chk('S12: verification never reached (no gate spawned)', countCalls(calls, 'verify:') === 0 && result.verification === null)
  chk('S12: the abort was logged', logs.some(l => l.includes('every subtask was skipped')))
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
