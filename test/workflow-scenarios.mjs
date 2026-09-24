#!/usr/bin/env node
// Scenario tests for workflows/triage-exec.js — executes the ACTUAL workflow body
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
const src = readFileSync(join(here, '..', 'workflows', 'triage-exec.js'), 'utf8')
  .replace(/^export const meta/m, 'const meta')

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let pass = 0
let fail = 0
function chk(name, cond) {
  if (cond) { pass++; console.log(`PASS: ${name}`) }
  else { fail++; console.log(`FAIL: ${name}`) }
}

// A budget mock with no target set — the unbudgeted/identity case: remaining() is
// Infinity, so every budget branch in the workflow short-circuits.
// NOTE: spent: () => 0 is a mock convenience only — the REAL runtime's spent()
// returns actual session-wide spend even when total is null (observed live
// 2026-07-01: spent=649,955 with total:null). The workflow just passes it
// through; assertions on spent===0 hold for the mock, not the runtime.
const NO_BUDGET = { total: null, remaining: () => Infinity, spent: () => 0 }

// Run the workflow body with a scripted agent. `script` maps a label-prefix to an
// array of queued responses; a queue exhausting falls back to its last entry. A
// queued value that is an Error instance is THROWN by agent() instead of returned —
// simulating the DSL's hard budget ceiling. `budget` overrides the mocked DSL budget
// global (default: none). Returns {result, logs, calls, events}; `events` interleaves
// logs and spawns in order ('log:<msg>' / 'agent:<label>') for announce-before-spawn checks.
async function run(plan, script, budget = NO_BUDGET) {
  const logs = []
  const calls = [] // { label, prompt, opts }
  const events = []
  const queues = new Map(Object.entries(script).map(([k, v]) => [k, [...v]]))

  function scripted(key) {
    const q = queues.get(key)
    if (!q || q.length === 0) return undefined
    return q.length > 1 ? q.shift() : q[0]
  }

  async function agent(prompt, opts = {}) {
    const label = opts.label || '(none)'
    calls.push({ label, prompt, opts })
    events.push(`agent:${label}`)
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
  const log = m => { logs.push(String(m)); events.push(`log:${m}`) }
  const phase = () => {}

  const fn = new AsyncFunction('args', 'log', 'phase', 'agent', 'parallel', 'pipeline', 'budget', src)
  let result
  try {
    result = await fn(plan, log, phase, agent, parallel, pipeline, budget)
  } catch (e) {
    // Attach the call log to the throw so a validation test can assert that NOTHING
    // was spawned before it fired (an empty list built by the catch would be vacuous).
    if (e && typeof e === 'object') e.calls = calls
    throw e
  }
  return { result, logs, calls, events }
}

// Capture the throw from a malformed-args run (validation must fire BEFORE any spawn).
async function runExpectingThrow(plan, script = {}) {
  try {
    const { calls } = await run(plan, script)
    return { threw: false, message: '', calls }
  } catch (e) {
    return { threw: true, message: String((e && e.message) || e), calls: (e && e.calls) || [] }
  }
}

const ST = (id, tier, files, extra = {}) =>
  Object.assign({ id, brief: `do ${id}`, tier, files, acceptance: 'works' }, extra)

const countCalls = (calls, prefix) => calls.filter(c => c.label.startsWith(prefix)).length
const statusOf = (result, id) => (result.subtasks.find(s => s.id === id) || {}).status

// ---- Scenario 1: no danger, one check PASS → single gate, no reviewer, no remediation
{
  const { result, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'] },
    {
      'builder:': ['did t1'],
      'verify:objective-check': ['all good\nPASS'],
    })
  chk('S1: objective-only path — no reviewer spawned', countCalls(calls, 'verify:reviewer') === 0)
  chk('S1: review.ran is false', result.review.ran === false)
  chk('S1: no remediation on PASS', result.remediation === null)
  chk('S1: not incomplete', result.incomplete === false)
  chk('S1: checks report the command and pass=true', result.checks.length === 1 && result.checks[0].cmd === 'make test' && result.checks[0].pass === true)
  chk('S1: subtask reported ok with 1 attempt', statusOf(result, 't1') === 'ok' && result.subtasks[0].attempts === 1)
}

// ---- Scenario 2: danger subtask + a check → BOTH gates run (seam)
{
  const { result, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { danger: true })], checks: ['make test'] },
    {
      'deep:': ['did core edit'],
      'verify:objective-check': ['ok\nPASS'],
      'verify:reviewer': ['PASS'],
    })
  chk('S2: seam runs the objective gate', countCalls(calls, 'verify:objective-check') === 1)
  chk('S2: seam runs the reviewer gate', countCalls(calls, 'verify:reviewer') === 1)
  chk('S2: review verdict parsed as PASS', result.review.ran === true && result.review.verdict === 'PASS')
  chk('S2: no remediation when both gates pass', result.remediation === null)
  chk('S2: not failed', result.failed === false)
}

// ---- Scenario 3: FIX naming one subtask's file → targeted remediation, same tier
{
  const { result, calls } = await run(
    { subtasks: [ST('parse', 'builder', ['src/parse.js']), ST('docs', 'quick', ['README.md'])] },
    {
      'builder:': ['did parser'],
      'quick:': ['did docs'],
      'verify:reviewer': ['FIX: src/parse.js mishandles empty input'],
      'redo:': ['fixed parser'],
      'verify:re-review': ['PASS'],
    })
  chk('S3: exactly one subtask re-run', countCalls(calls, 'redo:') === 1)
  chk('S3: the parser subtask was the one re-run', countCalls(calls, 'redo:parse') === 1)
  chk('S3: remediation implicated exactly one subtask', result.remediation.implicated === 1)
  chk('S3: attribution did not fail', result.remediation.attributionFailed === false)
  chk('S3: not escalated (FIX = same tier)', result.remediation.escalated === false && result.escalations.length === 0)
  chk('S3: re-run subtask reports 2 attempts, untouched one reports 1',
    result.subtasks.find(s => s.id === 'parse').attempts === 2 && result.subtasks.find(s => s.id === 'docs').attempts === 1)
}

// ---- Scenario 4: ESCALATE naming no files → ALL re-run one tier up, attribution-failure logged
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('t1', 'quick', ['a.js']), ST('t2', 'builder', ['b.js'])] },
    {
      'quick:': ['did t1'],
      'builder:': ['did t2'],
      'verify:reviewer': ['ESCALATE: approach is wrong overall'],
      'redo:': ['redone'],
      'verify:re-review': ['PASS'],
    })
  chk('S4: all subtasks re-run', countCalls(calls, 'redo:') === 2)
  chk('S4: attribution failure logged', logs.some(l => l.includes('attribution matched no subtask files')))
  chk('S4: escalated flag set', result.remediation.escalated === true)
  chk('S4: escalations recorded one tier up per subtask',
    result.escalations.length === 2 &&
    result.escalations.some(e => e.id === 't1' && e.from === 'quick' && e.to === 'builder') &&
    result.escalations.some(e => e.id === 't2' && e.from === 'builder' && e.to === 'deep'))
  chk('S4: subtask tiers in the report reflect the escalation',
    result.subtasks.find(s => s.id === 't1').tier === 'builder' && result.subtasks.find(s => s.id === 't2').tier === 'deep')
}

// ---- Scenario 5: objective gate null once, PASS on retry → retried, clean
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'] },
    {
      'builder:': ['did t1'],
      'verify:objective-check': [null, 'ok\nPASS'],
    })
  chk('S5: gate retried once', countCalls(calls, 'verify:objective-check') === 2)
  chk('S5: retry logged', logs.some(l => l.includes('retrying the gate once')))
  chk('S5: not incomplete after successful retry', result.incomplete === false)
  chk('S5: no remediation', result.remediation === null)
}

// ---- Scenario 6: objective gate null twice → INCOMPLETE, no remediation, loud log
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'] },
    {
      'builder:': ['did t1'],
      'verify:objective-check': [null, null],
    })
  chk('S6: gate tried exactly twice', countCalls(calls, 'verify:objective-check') === 2)
  chk('S6: result.incomplete === true', result.incomplete === true)
  chk('S6: dead gate reports pass:null, not false', result.checks[0].pass === null)
  chk('S6: NO remediation on a dead gate (no signal to act on)', result.remediation === null)
  chk('S6: INCOMPLETE logged loudly', logs.some(l => l.includes('VERIFICATION INCOMPLETE')))
}

// ---- Scenario 7: review-only path, reviewer null twice → INCOMPLETE, no remediation
{
  const { result, logs } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])] },
    {
      'builder:': ['did t1'],
      'verify:reviewer': [null, null],
    })
  chk('S7: result.incomplete === true', result.incomplete === true)
  chk('S7: no remediation', result.remediation === null)
  chk('S7: INCOMPLETE logged', logs.some(l => l.includes('VERIFICATION INCOMPLETE')))
}

// ---- Scenario 8: seam — objective dead, reviewer gives a real FIX → remediation
// still runs on the reviewer's feedback AND the result stays flagged if a gate is dead
{
  const { result } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { danger: true })], checks: ['make test'] },
    {
      'deep:': ['did core edit'],
      'verify:objective-check': [null], // dead on every attempt (initial + retry)
      'verify:reviewer': ['FIX: core.js breaks the seam'],
      'redo:': ['fixed core'],
      'verify:recheck': [null],
      'verify:re-review': ['PASS'],
    })
  chk('S8: remediation ran on the live gate\'s feedback', result.remediation !== null)
  chk('S8: remediation targeted the core subtask', result.remediation.implicated === 1 && result.remediation.attributionFailed === false)
  chk('S8: final result flagged incomplete (objective gate still dead)', result.incomplete === true)
}

// ---- Scenario 9: budget with total=null → IDENTITY. Same behavior as S1, plus a
// budget field reporting total:null / spent:0 / empty skipped.
{
  const { result, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'] },
    {
      'builder:': ['did t1'],
      'verify:objective-check': ['all good\nPASS'],
    }, NO_BUDGET)
  chk('S9: budget field present with total:null', result.budget && result.budget.total === null)
  chk('S9: budget.skipped empty (nothing skipped in null mode)', Array.isArray(result.budget.skipped) && result.budget.skipped.length === 0)
  chk('S9: budget.spent is 0 in null mode', result.budget.spent === 0)
  chk('S9: identity — no reviewer spawned, no remediation, not incomplete',
    countCalls(calls, 'verify:reviewer') === 0 && result.remediation === null && result.incomplete === false)
}

// ---- Scenario 10: constrained budget — remaining() drops below RESERVE after the
// first subtask's pre-check → the second subtask is skipped and reported in
// return.budget.skipped, the skip is logged, and verification still runs on the work
// that DID complete. (RESERVE = 60_000 in the workflow.)
{
  let n = 0
  const budget = { total: 200000, remaining: () => (++n === 1 ? 150000 : 20000), spent: () => 180000 }
  const { result, logs, calls: agentCalls } = await run(
    { subtasks: [ST('subA', 'builder', ['a.js']), ST('subB', 'builder', ['b.js'])], checks: ['make test'] },
    {
      'builder:': ['did sub A'],
      'verify:objective-check': ['ok\nPASS'],
    }, budget)
  chk('S10: only the first subtask spawned (second skipped for budget)', countCalls(agentCalls, 'builder:') === 1)
  chk('S10: skipped subtask reported in return.budget.skipped',
    result.budget.skipped.some(s => s.stage.startsWith('Execute') && s.desc === 'subB'))
  chk('S10: skipped subtask reported with status "skipped"', statusOf(result, 'subB') === 'skipped')
  chk('S10: skip logged with what was skipped + remaining budget',
    logs.some(l => l.includes('Budget: skipping') && l.includes('subB') && l.includes('20000')))
  chk('S10: verification still ran on the completed work',
    countCalls(agentCalls, 'verify:objective-check') === 1 && result.incomplete === false)
  chk('S10: budget report carries total + stamped spent', result.budget.total === 200000 && result.budget.spent === 180000)
}

// ---- Scenario 11: hard ceiling — agent() THROWS mid-execute (spent hit total). The
// throw is caught, the subtask recorded as skipped, and the workflow returns PARTIAL
// results + a budget report instead of crashing.
{
  const budget = { total: 500000, remaining: () => 400000, spent: () => 250000 }
  const { result, logs } = await run(
    { subtasks: [ST('good', 'builder', ['a.js']), ST('ceiling', 'deep', ['b.js'])], checks: ['make test'] },
    {
      'builder:': ['did good sub'],
      'deep:': [new Error('agent() budget ceiling reached')],
      'verify:objective-check': ['ok\nPASS'],
    }, budget)
  chk('S11: partial results kept — the good subtask survived', statusOf(result, 'good') === 'ok')
  chk('S11: ceiling subtask recorded as skipped',
    result.budget.skipped.some(s => s.stage.startsWith('Execute') && s.desc === 'ceiling') && statusOf(result, 'ceiling') === 'skipped')
  chk('S11: ceiling hit logged (caught, not crashed)', logs.some(l => l.includes('token ceiling')))
  chk('S11: returned a budget report + no error field (not a crash/abort)',
    result.budget.total === 500000 && result.budget.spent === 250000 && result.error === undefined)
  chk('S11: verification still ran on the partial results', result.incomplete === false)
}

// ---- Scenario 12: budget below RESERVE from the start → EVERY subtask skipped →
// early return with an explicit error field (not a hollow empty success), and
// verification is never reached.
{
  const budget = { total: 100000, remaining: () => 5000, spent: () => 96000 }
  const { result, logs, calls } = await run(
    { subtasks: [ST('only', 'builder', ['a.js'])], checks: ['make test'] },
    {
      // 'builder:' intentionally unscripted — it must never be called (would throw).
      'verify:objective-check': ['should never run\nPASS'],
    }, budget)
  chk('S12: explicit error field on total budget exhaustion', typeof result.error === 'string' && result.error.includes('all subtasks skipped'))
  chk('S12: no work done, all recorded in budget.skipped', statusOf(result, 'only') === 'skipped' && result.budget.skipped.length === 1)
  chk('S12: verification never reached (no gate spawned)', countCalls(calls, 'verify:') === 0 && result.checks[0].pass === null)
  chk('S12: the abort was logged', logs.some(l => l.includes('every subtask was skipped')))
}

// ---- Scenario 13 (wave 9): args validation — every malformed plan THROWS with a
// triage-exec: message and spawns NOTHING.
{
  const cases = [
    ['missing args', undefined, 'must be a plan object'],
    ['args is a string (the old /triage-run <task> form)', 'do the thing', 'must be a plan object'],
    ['no subtasks', { checks: ['make test'] }, 'subtasks must be a non-empty array'],
    ['empty subtasks', { subtasks: [] }, 'subtasks must be a non-empty array'],
    ['subtask is not an object', { subtasks: ['t1'] }, 'subtasks[0] must be an object'],
    ['missing brief', { subtasks: [{ tier: 'builder', acceptance: 'works' }] }, 'brief must be a non-empty string'],
    ['unknown tier', { subtasks: [ST('t1', 'wizard', ['a.js'])] }, 'tier must be one of'],
    ['missing acceptance', { subtasks: [{ brief: 'b', tier: 'builder' }] }, 'acceptance must be a non-empty string'],
    ['bad files type', { subtasks: [ST('t1', 'builder', 'a.js')] }, 'files must be an array'],
    ['bad danger type', { subtasks: [ST('t1', 'builder', [], { danger: 'yes' })] }, 'danger must be a boolean'],
    ['bad effort', { subtasks: [ST('t1', 'builder', [], { effort: 'turbo' })] }, 'effort must be one of'],
    ['duplicate ids', { subtasks: [ST('t1', 'builder', []), ST('t1', 'quick', [])] }, 'duplicate subtask id'],
    ['bad checks type', { subtasks: [ST('t1', 'builder', [])], checks: 'make test' }, 'checks must be an array'],
    ['bad review mode', { subtasks: [ST('t1', 'builder', [])], review: 'sometimes' }, 'review must be one of'],
    ['bad crossReview type', { subtasks: [ST('t1', 'builder', [])], crossReview: 'yes' }, 'crossReview must be a boolean'],
    ['crossReview names an unknown vendor', { subtasks: [ST('t1', 'builder', [])], crossReview: 'gemini' }, 'crossReview must be a boolean or one of agy|codex|both'],
    ['crossReview names an inherited key', { subtasks: [ST('t1', 'builder', [])], crossReview: 'toString' }, 'crossReview must be'],
  ]
  for (const [name, plan, needle] of cases) {
    const r = await runExpectingThrow(plan)
    chk(`S13: ${name} → throws before any spawn`,
      r.threw && r.message.startsWith('triage-exec:') && r.message.includes(needle) && r.calls.length === 0)
  }
}

// ---- Scenario 14 (wave 9): a valid minimal plan gets ids assigned, and effort is
// passed through to agent() only when the plan set one.
{
  const { result, calls } = await run(
    {
      subtasks: [
        { brief: 'no id here', tier: 'builder', acceptance: 'works' },
        { brief: 'max effort', tier: 'deep', acceptance: 'works', effort: 'max' },
      ],
      review: 'never',
      checks: ['make test'],
    },
    {
      'builder:': ['did 1'],
      'deep:': ['did 2'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S14: ids auto-assigned positionally', result.subtasks.map(s => s.id).join(',') === 's1,s2')
  chk('S14: files default to [] and the brief still spawns', statusOf(result, 's1') === 'ok' && statusOf(result, 's2') === 'ok')
  chk('S14: effort passed through when set', calls.find(c => c.label === 'deep:s2').opts.effort === 'max')
  chk('S14: effort omitted when unset (agent definition default wins)',
    calls.find(c => c.label === 'builder:s1').opts.effort === undefined)
  chk('S14: every agent() call sets agentType (never inherit the session model)',
    calls.every(c => typeof c.opts.agentType === 'string' && c.opts.agentType.startsWith('triage-')))
  chk('S14: review:"never" suppresses the reviewer even with no danger', result.review.ran === false)
}

// ---- Scenario 15 (wave 9): review modes — "always" runs the reviewer next to the
// checks; "never" suppresses it even for a danger subtask (caller owns its gate).
{
  const { result, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'always' },
    {
      'builder:': ['did t1'],
      'verify:objective-check': ['ok\nPASS'],
      'verify:reviewer': ['PASS'],
    })
  chk('S15a: review:"always" runs the reviewer alongside a passing check', countCalls(calls, 'verify:reviewer') === 1 && result.review.verdict === 'PASS')

  const { result: r2, calls: c2 } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { danger: true })], checks: ['make test'], review: 'never' },
    {
      'deep:': ['did core'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S15b: review:"never" suppresses the seam reviewer for a danger subtask', countCalls(c2, 'verify:reviewer') === 0 && r2.review.ran === false)
  chk('S15b: check still gates the round', r2.checks[0].pass === true && r2.incomplete === false)
}

// ---- Scenario 16 (wave 9): no checks AND review:"never" → nothing gated the work,
// which is INCOMPLETE (fail-loud), never a silent pass.
{
  const { result, logs } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], review: 'never' },
    { 'builder:': ['did t1'] })
  chk('S16: ungated run is reported INCOMPLETE', result.incomplete === true)
  chk('S16: ungated run logs the loud notice', logs.some(l => l.includes('VERIFICATION INCOMPLETE')))
  chk('S16: no gate was spawned', result.checks.length === 0 && result.review.ran === false)
}

// ---- Scenario 17 (wave 9): danger=true on a cheap tier is upgraded to deep, loudly.
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('core', 'builder', ['core.js'], { danger: true })], checks: ['make test'], review: 'never' },
    {
      'deep:': ['did core on the deep tier'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S17: danger subtask ran on triage-deep-reasoner, not the planned builder',
    calls.find(c => c.label.startsWith('deep:')).opts.agentType === 'triage-deep-reasoner' && countCalls(calls, 'builder:') === 0)
  chk('S17: the upgrade is logged', logs.some(l => l.includes('Danger-zone routing') && l.includes('core')))
  chk('S17: the report shows the tier actually used', result.subtasks[0].tier === 'deep')
}

// ---- Scenario 18 (wave 9): multiple checks — each is its own gate, and ONE failing
// check fails the round and drives remediation.
{
  const { result, calls } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make lint', 'make test'], review: 'never' },
    {
      'builder:': ['did t1'],
      'verify:objective-check#0': ['lint clean\nPASS'],
      'verify:objective-check#1': ['a.js exploded\nFAIL'],
      'redo:': ['fixed a.js'],
      'verify:recheck#0': ['PASS'],
      'verify:recheck#1': ['PASS'],
    })
  chk('S18: one gate per check', countCalls(calls, 'verify:objective-check') === 2)
  chk('S18: remediation ran on the failing check', countCalls(calls, 'redo:t1') === 1)
  chk('S18: per-check pass/fail attributed to the right command after the re-check',
    result.checks.length === 2 && result.checks[0].cmd === 'make lint' && result.checks[1].cmd === 'make test' &&
    result.checks[0].pass === true && result.checks[1].pass === true)
  chk('S18: final round is green', result.failed === false && result.incomplete === false)
}

// ---- Scenario 19 (wave 9): Fable spawn returns null → deep-reasoner at max effort,
// announced, and recorded in escalations.
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('arch', 'fable', ['x.js'])], checks: ['make test'] },
    {
      'fable:': [null],
      'deep←fable:': ['did it on deep at max'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S19: Fable escalation announced before the spawn', logs.some(l => l.startsWith('⚠ Escalating to Fable:')))
  chk('S19: fallback announced', logs.some(l => l.includes('Fable unavailable — using triage-deep-reasoner at max effort')))
  chk('S19: fallback ran on deep at max effort',
    calls.find(c => c.label.startsWith('deep←fable:')).opts.agentType === 'triage-deep-reasoner' &&
    calls.find(c => c.label.startsWith('deep←fable:')).opts.effort === 'max')
  chk('S19: fallback recorded in escalations', result.escalations.some(e => e.id === 'arch' && e.from === 'fable' && e.to === 'deep'))
  chk('S19: subtask reported ok on the tier that actually ran it', statusOf(result, 'arch') === 'ok' && result.subtasks[0].tier === 'deep')
}

// ---- Scenario 20 (wave 9): crossReview:true adds an advisory stage that NEVER
// changes the verdict; omitted entirely when not requested.
{
  const { result, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { danger: true })], checks: ['make test'], review: 'never', crossReview: true },
    {
      'deep:': ['did core'],
      'verify:objective-check': ['ok\nPASS'],
      'verify:cross-review': ['CROSS-REVIEW (agy · review · exit 0): core.js line 12 looks wrong to me'],
    })
  // Wave 12: crossReview:true still means agy, but findings are keyed by vendor.
  chk('S20: cross-reviewer spawned on the cross-review tier, for agy',
    countCalls(calls, 'verify:cross-review') === 1 &&
    calls.find(c => c.label === 'verify:cross-review:agy').opts.agentType === 'triage-cross-reviewer')
  chk('S20: brief names the vendor first and states the data boundary is cleared',
    calls.find(c => c.label === 'verify:cross-review:agy').prompt.split('\n')[0] === 'VENDOR=agy' &&
    /data boundary has been cleared/i.test(calls.find(c => c.label === 'verify:cross-review:agy').prompt))
  chk('S20: findings returned, keyed agy only', result.crossReview.ran === true &&
    result.crossReview.findings.agy.includes('line 12 looks wrong') && Object.keys(result.crossReview.findings).join() === 'agy')
  chk('S20: findings do NOT change the verdict (round stays green, no remediation)',
    result.failed === false && result.incomplete === false && result.remediation === null)

  const { result: r2, calls: c2 } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never' },
    {
      'builder:': ['did t1'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S20: crossReview absent from the result when not requested',
    r2.crossReview === undefined && countCalls(c2, 'verify:cross-review') === 0)
}

// ---- Scenario 21 (wave 9): the return value is a distillate — worker prose never
// leaves the workflow.
{
  const secret = 'VERBOSE-WORKER-PROSE-THAT-MUST-NOT-LEAK'
  const { result } = await run(
    { subtasks: [ST('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never' },
    {
      'builder:': [`${secret} ... many thousands of tokens ...`],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S21: worker output is not in the returned report', !JSON.stringify(result).includes(secret))
  chk('S21: report keys are the compact contract',
    ['subtasks', 'checks', 'review', 'escalations'].every(k => k in result))
}

// ---- Scenario 22 (wave 10; wave 12 names): plan-level overflow rewrites ONLY builder
// subtasks onto agy (via triage-external); quick/deep are untouched.
{
  const { result, logs, calls } = await run(
    { overflow: true, subtasks: [ST('b1', 'builder', ['a.js']), ST('d1', 'deep', ['b.js']), ST('q1', 'quick', ['c.js'])], checks: ['make test'], review: 'never' },
    {
      'agy:': ['EXTERNAL (agy · build · exit 0)\ndid b1 externally'],
      'deep:': ['did d1'],
      'quick:': ['did q1'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S22: exactly one external spawn, on triage-external with the agy header',
    countCalls(calls, 'agy:') === 1 &&
    calls.find(c => c.label === 'agy:builder:b1').opts.agentType === 'triage-external' &&
    calls.find(c => c.label === 'agy:builder:b1').prompt.split('\n')[0] === 'VENDOR=agy LEVEL=builder')
  chk('S22: deep and quick subtasks were NOT rewritten',
    calls.find(c => c.label === 'deep:d1').opts.agentType === 'triage-deep-reasoner' &&
    calls.find(c => c.label === 'quick:q1').opts.agentType === 'triage-quick-task')
  chk('S22: report shows the tier that actually ran b1',
    result.subtasks.find(s => s.id === 'b1').tier === 'agy:builder' &&
    result.subtasks.find(s => s.id === 'b1').vendor === 'agy' && result.subtasks.find(s => s.id === 'b1').level === 'builder' &&
    result.subtasks.find(s => s.id === 'd1').tier === 'deep')
  chk('S22: external routing is logged loudly and names the subtask and vendor',
    logs.some(l => l.includes('External routing') && l.includes('b1') && l.includes('agy')))
  // An overflow rewrite also makes tier !== plannedTier, but it is NOT a danger upgrade —
  // the danger log asserts danger=true and claims the opposite of the rule, so it must
  // stay silent here (see the else-if in the routing log loop).
  chk('S22: the overflow rewrite does NOT fire the danger-zone log',
    !logs.some(l => l.includes('Danger-zone routing')))
  chk('S22: overflow report is ids-only and accurate',
    JSON.stringify(result.overflow) === JSON.stringify({ routed: ['b1'], ranExternally: ['b1'], returnedToClaude: [] }) &&
    JSON.stringify(result.external.agy) === JSON.stringify(result.overflow))
  chk('S22: round is green with no remediation', result.failed === false && result.remediation === null)
}

// ---- Scenario 23 (wave 10; CHANGED in wave 12): an overflow (agy builder) subtask that
// fails its objective check comes back to the Claude ladder AT ITS LEVEL — Claude
// builder on a plain FAIL (was: straight to deep) — and never externally again.
{
  const { result, calls } = await run(
    { overflow: true, subtasks: [ST('b1', 'builder', ['a.js'])], checks: ['make test'], review: 'never' },
    {
      'agy:': ['did b1 externally'],
      'redo:b1': ['fixed it on Claude builder'],
      'verify:objective-check': ['a.js is broken\nFAIL'],
      'verify:recheck': ['ok\nPASS'],
    })
  chk('S23: the redo ran on triage-builder (same level, on Claude)',
    countCalls(calls, 'redo:b1') === 1 &&
    calls.find(c => c.label === 'redo:b1').opts.agentType === 'triage-builder')
  chk('S23: no second external spawn', calls.filter(c => c.opts.agentType === 'triage-external').length === 1)
  chk('S23: escalation recorded agy:builder -> builder',
    result.escalations.some(e => e.id === 'b1' && e.from === 'agy:builder' && e.to === 'builder'))
  chk('S23: subtask reports the tier that finished it, with 2 attempts',
    result.subtasks[0].tier === 'builder' && result.subtasks[0].vendor === 'claude' && result.subtasks[0].attempts === 2)
  chk('S23: ranExternally still credits the external run (derived, not read off results)',
    result.overflow.ranExternally.includes('b1') && result.overflow.returnedToClaude.includes('b1→builder'))
  chk('S23: second round is green', result.failed === false && result.incomplete === false)
}

// ---- Scenario 24 (wave 10): (a) danger work NEVER goes off-vendor; (b) an unavailable
// external tier falls back sideways to builder, loudly.
{
  const { result, logs, calls } = await run(
    { overflow: true, subtasks: [ST('core', 'builder', ['core.js'], { danger: true })], checks: ['make test'], review: 'never' },
    { 'deep:': ['did core on deep'], 'verify:objective-check': ['ok\nPASS'] })
  chk('S24a: zero external spawns for a danger subtask', !calls.some(c => c.opts.agentType === 'triage-external'))
  chk('S24a: it ran on deep', calls.find(c => c.label === 'deep:core').opts.agentType === 'triage-deep-reasoner')
  chk('S24a: the danger upgrade is logged', logs.some(l => l.includes('Danger-zone routing') && l.includes('core')))
  chk('S24a: overflow report shows nothing routed', result.overflow.routed.length === 0)

  const { result: rX, calls: cX } = await run(
    { subtasks: [ST('core2', 'overflow', ['core.js'], { danger: true })], checks: ['make test'], review: 'never' },
    { 'deep:': ['did core2 on deep'], 'verify:objective-check': ['ok\nPASS'] })
  chk('S24a: an EXPLICIT tier:overflow + danger is also upgraded to deep',
    !cX.some(c => c.opts.agentType === 'triage-external') && rX.subtasks[0].tier === 'deep')

  const { result: r2, logs: l2, calls: c2 } = await run(
    { overflow: true, subtasks: [ST('b1', 'builder', ['a.js'])], checks: ['make test'], review: 'never' },
    {
      'agy:': [null],
      'builder←agy:': ['did it on builder'],
      'verify:objective-check': ['ok\nPASS'],
    })
  chk('S24b: fallback spawned on triage-builder',
    c2.find(c => c.label === 'builder←agy:b1').opts.agentType === 'triage-builder')
  chk('S24b: the quota cost is announced loudly, as agy→claude',
    l2.some(l => l.includes('agy→claude') && l.includes('SPENDS Claude quota')))
  chk('S24b: escalation records agy:builder -> builder',
    r2.escalations.some(e => e.id === 'b1' && e.from === 'agy:builder' && e.to === 'builder'))
  chk('S24b: subtask reported ok on the tier that ran it',
    statusOf(r2, 'b1') === 'ok' && r2.subtasks[0].tier === 'builder')
  chk('S24b: routed records the PLAN, ranExternally records what actually reached the CLI',
    JSON.stringify(r2.overflow) === JSON.stringify({ routed: ['b1'], ranExternally: [], returnedToClaude: ['b1→builder'] }))
}

// ---- Scenario 25 (wave 10): entry contract for the overflow flag/tier.
{
  const badOverflow = await runExpectingThrow({ subtasks: [ST('t1', 'builder', ['a.js'])], overflow: 'yes' })
  chk('S25: non-boolean overflow throws before any spawn',
    badOverflow.threw && /args\.overflow must be a boolean/.test(badOverflow.message) && badOverflow.calls.length === 0)
  chk('S25: the usage text advertises the overflow tier', /overflow/.test(badOverflow.message))

  const { result } = await run(
    { subtasks: [ST('t1', 'overflow', ['a.js'])], checks: ['make test'], review: 'never' },
    { 'agy:': ['ok'], 'verify:objective-check': ['ok\nPASS'] })
  chk('S25: an explicit tier:"overflow" is accepted without the plan flag (= builder on agy)',
    result.subtasks[0].tier === 'agy:builder' && result.overflow.routed[0] === 't1')
}

// ---- Scenario 26 (wave 11): the deep@max rung. The rubric escalates to Fable only from
// a failed/escalated Opus@max attempt, and the deep tier defaults below max — so an
// ESCALATE on a below-max deep attempt buys ONE deep@max attempt before any Fable spawn.
const deepMaxCalls = calls => calls.filter(c => c.opts.agentType === 'triage-deep-reasoner' && c.opts.effort === 'max')
const escChain = result => result.escalations.map(e => `${e.from}->${e.to}`).join(',')
const REVIEW_ESCALATE = 'ESCALATE: core.js approach is wrong'

// (a) deep at its default effort → ESCALATE → deep@max → PASS: Fable is never spawned.
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'])] },
    {
      'deep:': ['did core'],
      'verify:reviewer': [REVIEW_ESCALATE],
      'redo:deep@max:': ['redone at max'],
      'verify:re-review': ['PASS'],
    })
  const mx = deepMaxCalls(calls)
  chk('S26a: exactly one deep@max re-run, on triage-deep-reasoner at effort max',
    mx.length === 1 && mx[0].label === 'redo:deep@max:core')
  chk('S26a: the deep@max brief carries the verifier feedback Fable would have got', mx.length > 0 && mx[0].prompt.includes(REVIEW_ESCALATE))
  chk('S26a: no Fable spawn and no Fable announcement',
    !calls.some(c => c.opts.agentType === 'triage-fable-architect') && !logs.some(l => l.includes('Escalating to Fable')))
  chk('S26a: the step is its own escalation entry, deep -> deep@max', escChain(result) === 'deep->deep@max' && result.escalations[0].id === 'core')
  chk('S26a: green after ONE round; subtask reports deep with 2 attempts',
    result.failed === false && result.remediation.rounds === 1 &&
    result.subtasks[0].tier === 'deep' && result.subtasks[0].attempts === 2)
}

// (b) deep@high → ESCALATE → deep@max still fails (a plain FIX counts) → Fable, announced first.
{
  const { result, events, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { effort: 'high' })] },
    {
      'deep:': ['did core'],
      'verify:reviewer': [REVIEW_ESCALATE],
      'redo:deep@max:': ['redone at max'],
      'verify:re-review': ['FIX: core.js still drops the edge case', 'PASS'],
      'redo:fable:': ['fable fixed it'],
    })
  const iMax = events.indexOf('agent:redo:deep@max:core')
  const iFable = events.indexOf('agent:redo:fable:core')
  const iWarn = events.findIndex(e => e.startsWith('log:⚠ Escalating to Fable: core'))
  const fable = calls.find(c => c.label === 'redo:fable:core')
  chk('S26b: the plan ran deep at effort high, then deep@max, then Fable — in that order',
    (calls.find(c => c.label === 'deep:core') || { opts: {} }).opts.effort === 'high' && iMax > 0 && iFable > iMax)
  chk('S26b: Fable ran on triage-fable-architect', fable && fable.opts.agentType === 'triage-fable-architect')
  chk('S26b: ⚠ Escalating to Fable printed AFTER deep@max and BEFORE the Fable spawn', iWarn > iMax && iWarn < iFable)
  chk('S26b: the Fable brief carries the deep@max attempt\'s failure feedback', !!fable && fable.prompt.includes('still drops the edge case'))
  chk('S26b: escalations = deep->deep@max, then deep@max->fable', escChain(result) === 'deep->deep@max,deep@max->fable')
  chk('S26b: the Fable round is re-verified; final green on fable with 3 attempts',
    countCalls(calls, 'verify:re-review') === 2 && result.failed === false && result.remediation.rounds === 2 &&
    result.subtasks[0].tier === 'fable' && result.subtasks[0].attempts === 3)
}

// (c) the plan already set effort:'max' on the deep subtask → straight to Fable.
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'], { effort: 'max' })] },
    {
      'deep:': ['did core at max'],
      'verify:reviewer': [REVIEW_ESCALATE],
      'redo:fable:': ['fable did it'],
      'verify:re-review': ['PASS'],
    })
  chk('S26c: no extra deep@max step — deep-reasoner ran once (the plan\'s own max attempt)',
    countCalls(calls, 'redo:deep@max:') === 0 && calls.filter(c => c.opts.agentType === 'triage-deep-reasoner').length === 1)
  chk('S26c: straight to Fable, announced', countCalls(calls, 'redo:fable:core') === 1 && logs.some(l => l.startsWith('⚠ Escalating to Fable: core')))
  chk('S26c: one escalation, recorded from the max rung', escChain(result) === 'deep@max->fable')
  chk('S26c: one round, green on fable', result.remediation.rounds === 1 && result.failed === false && result.subtasks[0].tier === 'fable')
}

// (d) Fable unavailable after the deep@max step. Contract: the unavailable→deep@max
// fallback is SKIPPED (deep@max is the attempt that just failed), logged, and recorded as
// fable->none; nothing new ran, so there is no re-verify and the deep@max verdict stands.
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'])] },
    {
      'deep:': ['did core'],
      'verify:reviewer': [REVIEW_ESCALATE],
      'redo:deep@max:': ['redone at max'],
      'verify:re-review': ['FIX: core.js still wrong'],
      'redo:fable:': [null],
      'redo:deep←fable:': ['MUST NOT RUN'],
    })
  chk('S26d: deep@max ran exactly once — the fallback did not re-run it',
    deepMaxCalls(calls).length === 1 && countCalls(calls, 'redo:deep←fable:') === 0)
  chk('S26d: Fable was announced and attempted once; the skip is logged',
    countCalls(calls, 'redo:fable:core') === 1 && logs.some(l => l.startsWith('⚠ Escalating to Fable: core')) &&
    logs.some(l => l.includes('Fable unavailable') && l.includes('NOT re-run')))
  chk('S26d: escalations record the skip (to:none), so the report never reads as if Fable ran',
    escChain(result) === 'deep->deep@max,deep@max->fable,fable->none')
  chk('S26d: no re-verify of unchanged work — the deep@max verdict stands, failed loudly',
    countCalls(calls, 'verify:re-review') === 1 && result.failed === true && result.review.verdict === 'FIX')
  chk('S26d: subtask keeps its deep@max output: deep, 2 attempts, 2 rounds',
    result.subtasks[0].tier === 'deep' && result.subtasks[0].attempts === 2 && result.remediation.rounds === 2)

  // Same contract from the other entry: a plan-time fable subtask whose Execute spawn fell
  // back to deep@max, then ESCALATEd → Fable again (no extra max step: it already ran at
  // max) → unavailable → no second deep@max.
  const { result: r2, calls: c2 } = await run(
    { subtasks: [ST('arch', 'fable', ['x.js'])] },
    {
      'fable:': [null],
      'deep←fable:': ['did it on deep at max'],
      'verify:reviewer': ['ESCALATE: x.js is wrong'],
      'redo:fable:': [null],
      'redo:deep←fable:': ['MUST NOT RUN'],
      'verify:re-review': ['ESCALATE: x.js is wrong'],
    })
  chk('S26d: after the Execute fallback, deep@max still runs only once in total',
    deepMaxCalls(c2).length === 1 && countCalls(c2, 'redo:deep←fable:') === 0 && countCalls(c2, 'redo:fable:arch') === 1)
  chk('S26d: fallback, re-escalation and skip all on record',
    escChain(r2) === 'fable->deep,deep@max->fable,fable->none' && r2.failed === true)
}

// (e) a plain FIX on a below-max deep attempt is a same-rung retry — no deep@max step.
{
  const { result, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js'])] },
    {
      'deep:': ['did core'],
      'verify:reviewer': ['FIX: core.js off by one'],
      'redo:': ['fixed'],
      'verify:re-review': ['PASS'],
    })
  chk('S26e: FIX retries deep at the plan\'s effort, not max, with no escalation entry',
    countCalls(calls, 'redo:core') === 1 && (calls.find(c => c.label === 'redo:core') || { opts: { effort: '?' } }).opts.effort === undefined &&
    deepMaxCalls(calls).length === 0 && result.escalations.length === 0 && result.failed === false)
}

// (f) round 2 is targeted: when the post-deep@max failure names only ANOTHER subtask's
// file, the deep@max subtask is not sent to Fable (its one extra round would be wasted).
{
  const { result, logs, calls } = await run(
    { subtasks: [ST('core', 'deep', ['core.js']), ST('ui', 'builder', ['ui.js'])] },
    {
      'deep:': ['did core'],
      'builder:': ['did ui'],
      'verify:reviewer': ['ESCALATE: the approach is wrong overall'],
      'redo:deep@max:': ['core at max'],
      'redo:ui': ['ui on deep'],
      'verify:re-review': ['FIX: ui.js still renders nothing'],
    })
  chk('S26f: round 1 took core to deep@max and ui one tier up',
    escChain(result) === 'deep->deep@max,builder->deep' && deepMaxCalls(calls).length === 1)
  chk('S26f: failure pinned on ui.js only → no Fable spawn, one round, failed loudly',
    !calls.some(c => c.opts.agentType === 'triage-fable-architect') && result.remediation.rounds === 1 &&
    result.failed === true && logs.some(l => l.includes('attributed only to other subtasks')))
}


// ════════════════════════ Wave 12: levels × vendors ════════════════════════
const LV = (id, level, files, extra = {}) =>
  Object.assign({ id, brief: `do ${id}`, level, files, acceptance: 'works' }, extra)
const extCalls = calls => calls.filter(c => c.opts.agentType === 'triage-external')
const firstLine = c => (c ? String(c.prompt).split('\n')[0] : '')
const GREEN = { 'verify:objective-check': ['ok\nPASS'] }

// ---- Scenario 27: `level` is the field; `tier` is its alias; both given must agree.
{
  const { result, calls } = await run(
    { subtasks: [LV('a', 'deep', ['a.js']), ST('b', 'builder', ['b.js'], { level: 'builder' })], checks: ['make test'], review: 'never' },
    { 'deep:': ['did a'], 'builder:': ['did b'], ...GREEN })
  chk('S27: level:"deep" runs on triage-deep-reasoner', calls.find(c => c.label === 'deep:a').opts.agentType === 'triage-deep-reasoner')
  chk('S27: tier and level both given and equal is accepted', calls.find(c => c.label === 'builder:b').opts.agentType === 'triage-builder')
  chk('S27: report carries level + vendor + legacy tier name',
    result.subtasks.every(x => x.vendor === 'claude') && result.subtasks[0].level === 'deep' && result.subtasks[0].tier === 'deep')

  const conflict = await runExpectingThrow({ subtasks: [ST('t1', 'builder', ['a.js'], { level: 'deep' })] })
  chk('S27: tier:"builder" + level:"deep" throws before any spawn',
    conflict.threw && /level "deep" and tier "builder" disagree/.test(conflict.message) && conflict.calls.length === 0)
  const unknown = await runExpectingThrow({ subtasks: [LV('t1', 'wizard', ['a.js'])] })
  chk('S27: unknown level throws, naming the field', unknown.threw && unknown.message.includes('subtasks[0].level must be one of quick|builder|deep|top') && unknown.calls.length === 0)
  const none = await runExpectingThrow({ subtasks: [{ brief: 'b', acceptance: 'works' }] })
  chk('S27: no level and no tier throws', none.threw && none.message.includes('level (or its alias tier)') && none.calls.length === 0)
  const oldName = await runExpectingThrow({ subtasks: [LV('t1', 'fable', ['a.js'], { tier: 'deep' })] })
  chk('S27: alias vs level conflict (level fable = top, tier deep) throws', oldName.threw && oldName.message.includes('disagree') && oldName.calls.length === 0)
}

// ---- Scenario 28: the legacy aliases. fable = top on Claude; overflow = builder on agy.
{
  const { result, calls, logs } = await run(
    { subtasks: [ST('f', 'fable', ['f.js']), ST('o', 'overflow', ['o.js'])], checks: ['make test'], review: 'never' },
    { 'fable:': ['fable did f'], 'agy:': ['agy did o'], ...GREEN })
  const f = result.subtasks.find(x => x.id === 'f')
  const o = result.subtasks.find(x => x.id === 'o')
  chk('S28: tier:"fable" = level top on claude, via runFable (announced)',
    f.level === 'top' && f.vendor === 'claude' && f.tier === 'fable' &&
    calls.find(c => c.label === 'fable:f').opts.agentType === 'triage-fable-architect' && logs.some(l => l.startsWith('⚠ Escalating to Fable: f')))
  chk('S28: tier:"overflow" = level builder on agy',
    o.level === 'builder' && o.vendor === 'agy' && firstLine(calls.find(c => c.label === 'agy:builder:o')) === 'VENDOR=agy LEVEL=builder')
  const both = await run(
    { subtasks: [ST('f', 'fable', [], { level: 'top' }), ST('o', 'overflow', [], { level: 'builder' })], checks: ['make test'], review: 'never' },
    { 'fable:': ['ok'], 'agy:': ['ok'], ...GREEN })
  chk('S28: an alias and its expansion given together agree', both.result.subtasks.map(x => x.tier).join() === 'fable,agy:builder')
  const clash = await runExpectingThrow({ subtasks: [ST('f', 'fable', [], { vendor: 'codex' })] })
  chk('S28: tier:"fable" with vendor:"codex" throws (the alias implies claude)',
    clash.threw && clash.message.includes('implies vendor claude') && clash.calls.length === 0)
}

// ---- Scenario 29: plan-level vendor default; overflow:true is the more specific default.
{
  const { result, calls } = await run(
    { vendor: 'codex', subtasks: [LV('b', 'builder', ['b.js']), LV('d', 'deep', ['d.js'], { vendor: 'claude' })], checks: ['make test'], review: 'never' },
    { 'codex:': ['codex did b'], 'deep:': ['did d'], ...GREEN })
  chk('S29: a subtask without vendor takes the plan default (codex)',
    extCalls(calls).length === 1 && firstLine(extCalls(calls)[0]) === 'VENDOR=codex LEVEL=builder')
  chk('S29: a subtask vendor overrides the plan default', calls.find(c => c.label === 'deep:d').opts.agentType === 'triage-deep-reasoner')
  chk('S29: report shows both vendors', result.subtasks.map(x => `${x.id}=${x.vendor}`).join() === 'b=codex,d=claude')

  const { calls: c2 } = await run(
    { vendor: 'codex', overflow: true, subtasks: [LV('b', 'builder', ['b.js']), LV('d', 'deep', ['d.js'])], checks: ['make test'], review: 'never' },
    { 'agy:': ['agy did b'], 'codex:': ['codex did d'], ...GREEN })
  chk('S29: overflow:true beats the plan vendor for builder work; deep keeps the plan vendor',
    firstLine(c2.find(c => c.label === 'agy:builder:b')) === 'VENDOR=agy LEVEL=builder' &&
    firstLine(c2.find(c => c.label === 'codex:deep:d')) === 'VENDOR=codex LEVEL=deep')
}

// ---- Scenario 30: an unknown vendor throws before any spawn (subtask or plan level).
{
  const sub = await runExpectingThrow({ subtasks: [LV('t1', 'builder', ['a.js'], { vendor: 'gemini' })] })
  chk('S30: unknown subtask vendor throws before any spawn',
    sub.threw && sub.message.includes('subtasks[0].vendor must be one of claude|codex|agy') && sub.calls.length === 0)
  const plan = await runExpectingThrow({ vendor: 'openai', subtasks: [LV('t1', 'builder', ['a.js'])] })
  chk('S30: unknown plan vendor throws before any spawn',
    plan.threw && plan.message.includes('args.vendor must be one of') && plan.calls.length === 0)
  chk('S30: the usage text advertises level and vendor', /level: quick\|builder\|deep\|top/.test(plan.message) && /vendor\?:/.test(plan.message))
}

// ---- Scenario 31: agy serves the builder level only.
{
  for (const level of ['quick', 'deep', 'top']) {
    const r = await runExpectingThrow({ subtasks: [LV('t1', level, ['a.js'], { vendor: 'agy' })] })
    chk(`S31: vendor agy at level ${level} throws before any spawn`,
      r.threw && r.message.includes('vendor agy serves the builder level only') && r.calls.length === 0)
  }
  const planAgy = await runExpectingThrow({ vendor: 'agy', subtasks: [LV('q', 'quick', ['a.js'])] })
  chk('S31: a plan-level agy default on a quick subtask throws too, and says where agy came from',
    planAgy.threw && planAgy.message.includes('from the plan-level vendor') && planAgy.calls.length === 0)
}

// ---- Scenario 32: codex routing — triage-external, the exact header line, the brief
// after it, and the wrapper's OWN effort left at its default.
{
  const { result, calls } = await run(
    { subtasks: [LV('c1', 'builder', ['c.js'], { vendor: 'codex', effort: 'medium' }), LV('c2', 'quick', ['q.js'], { vendor: 'codex' })], checks: ['make test'], review: 'never' },
    { 'codex:': ['EXTERNAL (codex · build · exit 0)\nCHANGED FILES: c.js'], ...GREEN })
  const c1 = calls.find(c => c.label === 'codex:builder:c1')
  const c2 = calls.find(c => c.label === 'codex:quick:c2')
  chk('S32: codex subtask spawns triage-external', !!c1 && c1.opts.agentType === 'triage-external' && c2.opts.agentType === 'triage-external')
  chk('S32: exact header line with EFFORT when the plan set one', firstLine(c1) === 'VENDOR=codex LEVEL=builder EFFORT=medium')
  chk('S32: EFFORT omitted when the plan set none', firstLine(c2) === 'VENDOR=codex LEVEL=quick')
  chk('S32: the header is followed by a blank line and the full brief',
    c1.prompt.startsWith('VENDOR=codex LEVEL=builder EFFORT=medium\n\ndo c1\n') && c1.prompt.includes('Acceptance criteria: works'))
  chk('S32: the Haiku wrapper runs at its own effort (EFFORT is the external model\'s)', c1.opts.effort === undefined)
  chk('S32: no Claude worker spawned for the codex subtasks',
    !calls.some(c => c.opts.phase === 'Execute' && c.opts.agentType !== 'triage-external'))
  chk('S32: report: ok on codex', result.subtasks.every(x => x.vendor === 'codex' && x.status === 'ok') && result.subtasks[0].tier === 'codex:builder')
}

// ---- Scenario 33: danger on codex is ALLOWED, lifted to >= deep and effort >= high.
{
  const { calls, logs, result } = await run(
    {
      vendor: 'codex',
      subtasks: [
        LV('q', 'quick', ['q.js'], { danger: true, effort: 'low' }),
        LV('b', 'builder', ['b.js'], { danger: true }),
        LV('m', 'deep', ['m.js'], { danger: true, effort: 'max' }),
        LV('x', 'deep', ['x.js'], { danger: true, effort: 'xhigh' }),
        LV('t', 'top', ['t.js'], { danger: true }),
      ],
      checks: ['make test'], review: 'never',
    },
    { 'codex:': ['did it'], ...GREEN })
  const hdr = id => firstLine(calls.find(c => c.label.startsWith('codex:') && c.label.endsWith(`:${id}`)))
  chk('S33: codex+danger quick@low → deep at effort high (still on codex)', hdr('q') === 'VENDOR=codex LEVEL=deep EFFORT=high')
  chk('S33: codex+danger builder, effort unset → deep at effort high', hdr('b') === 'VENDOR=codex LEVEL=deep EFFORT=high')
  chk('S33: an explicit max is kept', hdr('m') === 'VENDOR=codex LEVEL=deep EFFORT=max')
  chk('S33: an explicit xhigh is kept', hdr('x') === 'VENDOR=codex LEVEL=deep EFFORT=xhigh')
  chk('S33: top keeps its level; unset effort floors to xhigh, never lowered to high', hdr('t') === 'VENDOR=codex LEVEL=top EFFORT=xhigh')
  chk('S33: every danger subtask ran on codex (5 external spawns, no Claude worker)',
    extCalls(calls).length === 5 && !calls.some(c => c.opts.phase === 'Execute' && c.opts.agentType !== 'triage-external'))
  chk('S33: the lift is logged for the changed subtasks only',
    logs.some(l => l.includes('Danger-zone routing') && l.includes('"q"') && l.includes('codex:deep@high')) &&
    !logs.some(l => l.includes('Danger-zone routing') && (l.includes('"m"') || l.includes('"x"'))))
  chk('S33: the report shows the lifted level', result.subtasks.find(x => x.id === 'q').level === 'deep')
}

// ---- Scenario 34: danger on agy is rerouted to Claude deep (never off-vendor on agy).
{
  const { result, calls, logs } = await run(
    { subtasks: [LV('core', 'builder', ['core.js'], { vendor: 'agy', danger: true })], checks: ['make test'], review: 'never' },
    { 'deep:': ['did core on Claude deep'], ...GREEN })
  chk('S34: explicit vendor agy + danger → triage-deep-reasoner, zero external spawns',
    extCalls(calls).length === 0 && calls.find(c => c.label === 'deep:core').opts.agentType === 'triage-deep-reasoner')
  chk('S34: the vendor-neutral danger log names both routes',
    logs.some(l => l.includes('Danger-zone routing') && l.includes('agy:builder') && l.includes('running it on deep')))
  chk('S34: report: Claude deep, and external.agy shows nothing routed',
    result.subtasks[0].tier === 'deep' && result.subtasks[0].vendor === 'claude' && result.external.agy.routed.length === 0)
}

// ---- Scenario 35: an external spawn with no work (null, UNAVAILABLE, REFUSED) reruns
// the SAME level on Claude — never the same vendor again, never a climb.
{
  const { result, calls, logs } = await run(
    {
      vendor: 'codex',
      subtasks: [LV('q', 'quick', ['q.js']), LV('b', 'builder', ['b.js']), LV('d', 'deep', ['d.js']), LV('t', 'top', ['t.js'])],
      checks: ['make test'], review: 'never',
    },
    {
      'codex:quick:': [null],
      'codex:builder:': ['REFUSED: /x is under a deny-listed repo'],
      'codex:deep:': ['UNAVAILABLE: codex exited 4 (rate limited)'],
      'codex:top:': [null],
      'quick←codex:': ['q on Claude'],
      'builder←codex:': ['b on Claude'],
      'deep←codex:': ['d on Claude'],
      'fable:': ['t on Fable'],
      ...GREEN,
    })
  const lbl = l => calls.find(c => c.label === l)
  chk('S35: null quick → triage-quick-task', lbl('quick←codex:q').opts.agentType === 'triage-quick-task')
  chk('S35: REFUSED builder → triage-builder', lbl('builder←codex:b').opts.agentType === 'triage-builder')
  chk('S35: UNAVAILABLE deep → triage-deep-reasoner', lbl('deep←codex:d').opts.agentType === 'triage-deep-reasoner')
  chk('S35: null top → Fable, only via runFable (announced first)',
    lbl('fable:t').opts.agentType === 'triage-fable-architect' &&
    logs.some(l => l.startsWith('⚠ Escalating to Fable: t')))
  chk('S35: exactly one external spawn per subtask (no sideways retry)', extCalls(calls).length === 4)
  chk('S35: each fallback logged as codex→claude',
    ['q', 'b', 'd', 't'].every(id => logs.some(l => l.includes('codex→claude') && l.includes(` ${id} `))))
  chk('S35: escalations record <vendor>:<level> -> same-level Claude rung',
    escChain(result).split(',').sort().join() === ['codex:quick->quick', 'codex:builder->builder', 'codex:deep->deep', 'codex:top->fable'].sort().join())
  chk('S35: all ok on Claude at the planned level',
    result.subtasks.map(x => `${x.id}:${x.tier}:${x.status}`).join() === 'q:quick:ok,b:builder:ok,d:deep:ok,t:fable:ok')
  chk('S35: external.codex: routed all, ranExternally none',
    JSON.stringify(result.external.codex.routed) === '["q","b","d","t"]' && result.external.codex.ranExternally.length === 0 &&
    result.external.codex.returnedToClaude.length === 4)
}

// ---- Scenario 36: an external result that FAILS verification goes onto the Claude
// ladder from its level (redoStep) — never a second external spawn.
{
  // (a) plain objective FAIL on codex builder → Claude builder with the failure text.
  const { result, calls } = await run(
    { subtasks: [LV('b', 'builder', ['b.js'], { vendor: 'codex' })], checks: ['make test'], review: 'never' },
    { 'codex:': ['did b'], 'verify:objective-check': ['b.js broke\nFAIL'], 'redo:': ['fixed on Claude'], 'verify:recheck': ['ok\nPASS'] })
  chk('S36a: redo ran on triage-builder with the failure text',
    calls.find(c => c.label === 'redo:b').opts.agentType === 'triage-builder' && calls.find(c => c.label === 'redo:b').prompt.includes('b.js broke'))
  chk('S36a: never a second external spawn', extCalls(calls).length === 1)
  chk('S36a: escalation codex:builder -> builder; ranExternally still credits codex',
    escChain(result) === 'codex:builder->builder' && result.external.codex.ranExternally.includes('b') &&
    result.external.codex.returnedToClaude.includes('b→builder'))
  chk('S36a: green, on Claude builder, 2 attempts',
    result.failed === false && result.subtasks[0].tier === 'builder' && result.subtasks[0].attempts === 2)

  // (b) reviewer ESCALATE on codex deep at max → Claude deep@max (an external max is NOT
  // an Opus@max attempt, so Fable is not next).
  const { result: r2, calls: c2, logs: l2 } = await run(
    { subtasks: [LV('d', 'deep', ['d.js'], { vendor: 'codex', effort: 'max' })] },
    { 'codex:': ['did d'], 'verify:reviewer': ['ESCALATE: d.js approach wrong'], 'redo:deep@max:': ['redone'], 'verify:re-review': ['PASS'] })
  chk('S36b: ESCALATE on codex deep@max → Claude deep@max, not Fable',
    deepMaxCalls(c2).length === 1 && deepMaxCalls(c2)[0].label === 'redo:deep@max:d' &&
    !c2.some(c => c.opts.agentType === 'triage-fable-architect') && !l2.some(l => l.includes('Escalating to Fable')))
  chk('S36b: never a second external spawn; escalation codex:deep -> deep@max',
    extCalls(c2).length === 1 && escChain(r2) === 'codex:deep->deep@max' && r2.failed === false)

  // (c) ESCALATE on agy builder climbs the Claude ladder: builder -> deep.
  const { result: r3, calls: c3 } = await run(
    { subtasks: [ST('o', 'overflow', ['o.js'])] },
    { 'agy:': ['did o'], 'verify:reviewer': ['ESCALATE: o.js wrong'], 'redo:': ['redone'], 'verify:re-review': ['PASS'] })
  chk('S36c: ESCALATE on agy builder → Claude deep, no second external spawn',
    c3.find(c => c.label === 'redo:o').opts.agentType === 'triage-deep-reasoner' && extCalls(c3).length === 1 &&
    escChain(r3) === 'agy:builder->deep')
}

// ---- Scenario 37: top on Claude is ONLY ever spawned through runFable (announced);
// top on codex is an external spawn, and no Fable is involved.
{
  const { calls, events } = await run(
    { subtasks: [LV('t', 'top', ['t.js']), LV('c', 'top', ['c.js'], { vendor: 'codex' })], checks: ['make test'], review: 'never' },
    { 'fable:': ['fable did t'], 'codex:': ['codex did c'], ...GREEN })
  const fableCalls = calls.filter(c => c.opts.agentType === 'triage-fable-architect')
  const iWarn = events.indexOf('log:⚠ Escalating to Fable: t — do t')
  chk('S37: exactly one Fable spawn, labelled by runFable, announced before it',
    fableCalls.length === 1 && fableCalls[0].label === 'fable:t' && iWarn >= 0 && iWarn < events.indexOf('agent:fable:t'))
  chk('S37: top on codex is one triage-external spawn with LEVEL=top, and is not announced as Fable',
    extCalls(calls).length === 1 && firstLine(extCalls(calls)[0]) === 'VENDOR=codex LEVEL=top' &&
    !events.some(e => e.startsWith('log:⚠ Escalating to Fable: c')))
}

// ---- Scenario 38: crossReview modes — 'both' is two parallel spawns keyed by vendor.
{
  const { result, calls, logs } = await run(
    { subtasks: [LV('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never', crossReview: 'both' },
    { 'builder:': ['did t1'], ...GREEN,
      'verify:cross-review:agy': ['CROSS-REVIEW (agy · review · exit 0)\nagy finding'],
      'verify:cross-review:codex': ['CROSS-REVIEW (codex · review · exit 0)\ncodex finding'] })
  const cr = calls.filter(c => c.opts.agentType === 'triage-cross-reviewer')
  chk('S38: crossReview "both" → exactly 2 cross-reviewer spawns', cr.length === 2)
  chk('S38: one per vendor, each with its VENDOR line',
    cr.map(firstLine).sort().join() === 'VENDOR=agy,VENDOR=codex')
  chk('S38: findings keyed by vendor', result.crossReview.ran === true &&
    result.crossReview.findings.agy.includes('agy finding') && result.crossReview.findings.codex.includes('codex finding'))
  chk('S38: still advisory — verdict unchanged', result.failed === false && result.remediation === null)
  chk('S38: success logged naming both', logs.some(l => l.includes('Cross-review returned findings from agy, codex')))

  const { result: r2, logs: l2 } = await run(
    { subtasks: [LV('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never', crossReview: 'both' },
    { 'builder:': ['did t1'], ...GREEN, 'verify:cross-review:agy': ['agy finding'], 'verify:cross-review:codex': [null] })
  chk('S38: one vendor unavailable → only the other is keyed; loud log names the missing one',
    r2.crossReview.ran === true && Object.keys(r2.crossReview.findings).join() === 'agy' &&
    l2.some(l => l.includes('no findings from codex')))

  const { calls: c3, result: r3 } = await run(
    { subtasks: [LV('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never', crossReview: 'codex' },
    { 'builder:': ['did t1'], ...GREEN, 'verify:cross-review:codex': ['codex finding'] })
  chk('S38: crossReview "codex" → one codex spawn only',
    c3.filter(c => c.opts.agentType === 'triage-cross-reviewer').length === 1 && firstLine(c3.find(c => c.label === 'verify:cross-review:codex')) === 'VENDOR=codex' &&
    Object.keys(r3.crossReview.findings).join() === 'codex')

  const { calls: c4 } = await run(
    { subtasks: [LV('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never', crossReview: true },
    { 'builder:': ['did t1'], ...GREEN, 'verify:cross-review': ['agy finding'] })
  chk('S38: crossReview true still means agy (one spawn)',
    c4.filter(c => c.opts.agentType === 'triage-cross-reviewer').map(c => c.label).join() === 'verify:cross-review:agy')
  const { calls: c5, result: r5 } = await run(
    { subtasks: [LV('t1', 'builder', ['a.js'])], checks: ['make test'], review: 'never', crossReview: false },
    { 'builder:': ['did t1'], ...GREEN })
  chk('S38: crossReview false → no spawn, no field', !c5.some(c => c.opts.agentType === 'triage-cross-reviewer') && r5.crossReview === undefined)
}

// ---- Scenario 39: report().external counts per vendor, with overflow mirroring agy.
{
  const { result } = await run(
    {
      subtasks: [
        ST('o', 'overflow', ['o.js']),
        LV('c', 'builder', ['c.js'], { vendor: 'codex' }),
        LV('n', 'deep', ['n.js'], { vendor: 'codex' }),
        LV('k', 'quick', ['k.js']),
      ],
      checks: ['make test'], review: 'never',
    },
    { 'agy:': ['did o'], 'codex:builder:': ['did c'], 'codex:deep:': [null], 'deep←codex:': ['n on Claude'], 'quick:': ['did k'], ...GREEN })
  chk('S39: external.agy', JSON.stringify(result.external.agy) === JSON.stringify({ routed: ['o'], ranExternally: ['o'], returnedToClaude: [] }))
  chk('S39: external.codex', JSON.stringify(result.external.codex) === JSON.stringify({ routed: ['c', 'n'], ranExternally: ['c'], returnedToClaude: ['n→deep'] }))
  chk('S39: overflow mirrors external.agy (back-compat)', JSON.stringify(result.overflow) === JSON.stringify(result.external.agy))

  const { result: r2 } = await run(
    { subtasks: [LV('k', 'quick', ['k.js'])], checks: ['make test'], review: 'never' },
    { 'quick:': ['did k'], ...GREEN })
  chk('S39: an all-Claude plan has neither external nor overflow', r2.external === undefined && r2.overflow === undefined)
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
