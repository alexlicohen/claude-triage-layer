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
// global (default: none). Returns {result, logs, calls}.
async function run(plan, script, budget = NO_BUDGET) {
  const logs = []
  const calls = [] // { label, prompt, opts }
  const queues = new Map(Object.entries(script).map(([k, v]) => [k, [...v]]))

  function scripted(key) {
    const q = queues.get(key)
    if (!q || q.length === 0) return undefined
    return q.length > 1 ? q.shift() : q[0]
  }

  async function agent(prompt, opts = {}) {
    const label = opts.label || '(none)'
    calls.push({ label, prompt, opts })
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
  let result
  try {
    result = await fn(plan, log, phase, agent, parallel, pipeline, budget)
  } catch (e) {
    // Attach the call log to the throw so a validation test can assert that NOTHING
    // was spawned before it fired (an empty list built by the catch would be vacuous).
    if (e && typeof e === 'object') e.calls = calls
    throw e
  }
  return { result, logs, calls }
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
      'verify:cross-review': ['CROSS-REVIEW (gemini): core.js line 12 looks wrong to me'],
    })
  chk('S20: cross-reviewer spawned on the cross-review tier',
    countCalls(calls, 'verify:cross-review') === 1 &&
    calls.find(c => c.label === 'verify:cross-review').opts.agentType === 'triage-cross-reviewer')
  chk('S20: brief states the data boundary is cleared',
    /data boundary has been cleared/i.test(calls.find(c => c.label === 'verify:cross-review').prompt))
  chk('S20: findings returned', result.crossReview.ran === true && result.crossReview.findings.includes('line 12 looks wrong'))
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

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
