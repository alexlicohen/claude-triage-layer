#!/usr/bin/env node
// Scenario tests for workflows/triage-parity.js — executes the ACTUAL workflow
// body under mocked DSL globals (agent/workflow/parallel/log/phase/budget), the
// way test/compare-scenarios.mjs does for triage-compare.js. Covers: validation
// before any spawn; the loader -> materialize -> triage-compare wiring; vendors
// restricted per task and deny-marked vendors dropped per task; the adaptive stop
// (consecutive failed bands only); unavailable/denied/invalid/unresolved never
// counted as pass or fail; rubric judges (blind, agreement, disagreement); the
// review scoring path; a LEAK aborting the run; the proposal (cheapest clearing
// candidate, incumbents respected); the Fable warning; reps; the desk leg; and
// that nothing outside outDir (never tiers.json) is ever written.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, '..', 'workflows', 'triage-parity.js'), 'utf8')
  .replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let pass = 0
let fail = 0
function chk(name, cond) {
  if (cond) { pass++; console.log(`PASS: ${name}`) }
  else { fail++; console.log(`FAIL: ${name}`) }
}

const SUITE = '/s/suite'
const OUT = '/o/par'
const SHA = 'b'.repeat(40)
const task = (id, band, over = {}) => Object.assign({
  id, band, kind: 'build', taskDir: `${SUITE}/${band}/${id}`, brief: `Brief ${id}.`, files: ['calc.sh'], acceptance: `acc ${id}`,
  checks: ['sh test.sh'], overlay: 'hidden/', grading: 'check', key: null, vendors: ['claude', 'codex', 'agy'], timeoutMin: null,
}, over)
const LADDER = [task('t1', 1), task('t2', 2), task('t3', 3), task('t4', 4)]

// run(args, opts) — opts.tasks: the loader's list; opts.denied: {taskId: {agy,codex}};
// opts.outcome(taskId, runLabel, cmpArgs) -> compare status (default 'pass');
// opts.script: {labelPrefix: [responses]} for any other agent (longest prefix
// wins, a queue repeats its last entry, an Error is thrown, a function is called
// with (prompt, opts)); opts.compare: a full override of the workflow() mock.
async function run(args, opts = {}) {
  const logs = []
  const calls = []
  const wf = []
  const events = []
  const tasks = opts.tasks || LADDER
  const denied = opts.denied || {}
  const outcome = opts.outcome || (() => 'pass')
  const script = Object.assign({
    'load:': [{ tasks }],
    'materialize:': [p => {
      const out = (p.match(/--out '([^']+)'/) || [])[1]
      const id = (p.match(/--task '[^']*\/([^/']+)'/) || [])[1]
      return { repo: `${out}/repo`, sha: SHA, denied: Object.assign({ agy: false, codex: false }, denied[id] || {}), rc: 0 }
    }],
    'desk:': ['CROSS-REVIEW (x · verify · exit 0)\nsome published numbers'],
    'judge:copy': [{ ok: true, rc: 0 }],
  }, opts.script || {})
  const queues = new Map(Object.entries(script).map(([k, v]) => [k, [...v]]))
  const bestKey = label => {
    let best
    for (const k of queues.keys()) if (label.startsWith(k) && (!best || k.length > best.length)) best = k
    return best
  }
  async function agent(prompt, o = {}) {
    const label = o.label || '(none)'
    calls.push({ label, prompt, opts: o })
    events.push(`agent:${label}`)
    await new Promise(r => setTimeout(r, 1))
    const key = bestKey(label)
    if (key === undefined) throw new Error(`unscripted agent call: label=${label}`)
    const q = queues.get(key)
    const val = q.length > 1 ? q.shift() : q[0]
    if (val instanceof Error) throw val
    return typeof val === 'function' ? val(prompt, o) : val
  }
  async function workflow(name, a) {
    wf.push({ name, args: a })
    events.push(`workflow:${name}:${a.outDir}`)
    await new Promise(r => setTimeout(r, 1))
    if (opts.compare) return opts.compare(name, a)
    const id = a.outDir.split('/').slice(-2, -1)[0]
    return {
      base: a.base, sha: a.base, leak: false, baseMoved: false, graded: true,
      candidates: a.candidates.map(c => {
        const status = outcome(id, c.label, a)
        const ext = c.vendor !== 'claude'
        return { label: c.label, vendor: c.vendor, level: c.level, model: c.model || (ext ? 'gpt-6-sol' : null), effort: c.effort || null, status,
          patch: ['pass', 'fail'].includes(status) ? `${a.outDir}/${c.label}.patch` : null, outTokens: null,
          totalTokens: ext ? 1000 : null, seconds: ext ? 10 : null, tail: `tail ${c.label}` }
      }),
    }
  }
  const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
  const log = m => { logs.push(String(m)); events.push(`log:${m}`) }
  const phase = () => {}
  const budget = { total: null, remaining: () => Infinity, spent: () => 0 }
  const fn = new AsyncFunction('args', 'log', 'phase', 'agent', 'parallel', 'budget', 'workflow', src)
  try {
    const result = await fn(args, log, phase, agent, parallel, budget, workflow)
    return { result, logs, calls, wf, events }
  } catch (e) {
    if (e && typeof e === 'object') { e.calls = calls; e.wf = wf; e.logs = logs }
    throw e
  }
}
async function throws(args, opts) {
  try { const r = await run(args, opts); return Object.assign({ threw: false }, r) }
  catch (e) { return { threw: true, message: String(e.message || e), calls: e.calls || [], wf: e.wf || [], logs: e.logs || [] } }
}

const A = extra => Object.assign({ suite: SUITE, outDir: OUT, desk: false }, extra)
const C = (vendor, level, label, extra) => Object.assign({ vendor, level, label }, extra || {})
const rank = (result, l) => result.ranking.find(r => r.label === l) || {}
const cellOf = (result, id, l) => ((result.tasks.find(t => t.id === id) || { results: [] }).results.find(r => r.runLabel === l) || {})

// ---- P1: validation throws before ANY spawn --------------------------------
{
  const ok = [C('claude', 'builder', 'a')]
  const cases = [
    ['non-object args', null],
    ['relative suite', A({ suite: 'suite', candidates: ok })],
    ['relative outDir', A({ outDir: 'out', candidates: ok })],
    ['outDir inside the suite', A({ outDir: `${SUITE}/runs`, candidates: ok })],
    ['no candidates', A({ candidates: [] })],
    ['unknown vendor', A({ candidates: [C('gemini', 'builder', 'a')] })],
    ['agy off builder', A({ candidates: [C('agy', 'deep', 'a')] })],
    ['bad effort', A({ candidates: [C('codex', 'deep', 'a', { effort: 'ultra' })] })],
    ['label reserved for reps', A({ candidates: [C('claude', 'deep', 'x-r2')] })],
    ['label with @', A({ candidates: [C('claude', 'deep', 'x@y')] })],
    ['duplicate labels', A({ candidates: [C('claude', 'deep', 'x'), C('codex', 'deep', 'x')] })],
    ['band 0', A({ bands: [0], candidates: ok })],
    ['reps 0', A({ reps: 0, candidates: ok })],
    ['bandPassRate 2', A({ bandPassRate: 2, candidates: ok })],
    ['stopAfterFailedBands 0', A({ stopAfterFailedBands: 0, candidates: ok })],
    ['incumbent not a candidate', A({ candidates: ok, incumbents: { builder: { claude: 'zzz' } } })],
    ['incumbent of the wrong vendor', A({ candidates: ok, incumbents: { builder: { codex: 'a' } } })],
    ['judges empty', A({ candidates: ok, judges: [] })],
    ['judges not an array', A({ candidates: ok, judges: { vendor: 'claude', level: 'deep' } })],
    ['duplicate judge labels', A({ candidates: ok, judges: [{ vendor: 'claude', level: 'deep' }, { vendor: 'claude', level: 'deep' }] })],
    ['desk not boolean', A({ candidates: ok, desk: 'yes' })],
  ]
  for (const [name, args] of cases) {
    const r = await throws(args)
    chk(`P1: ${name} throws before any spawn`, r.threw && r.calls.length === 0 && r.wf.length === 0 && /triage-parity:/.test(r.message))
  }
}

// ---- P2: loader -> materialize -> compare wiring, vendors per task, skipped ---
{
  const tasks = [task('t1', 1), task('t2', 1, { vendors: ['claude', 'codex'] })]
  const { result, calls, wf } = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'cb'), C('codex', 'builder', 'xb'), C('agy', 'builder', 'ab')] }), { tasks })
  const load = calls.filter(c => c.label === 'load:suite')
  chk('P2: ONE loader spawn — a triage-quick-task running parity-suite.sh list on the suite, with a schema',
    load.length === 1 && load[0].opts.agentType === 'triage-quick-task' && load[0].prompt.includes(`parity-suite.sh list --suite '${SUITE}'`) && !!load[0].opts.schema)
  const mats = calls.filter(c => c.label.startsWith('materialize:'))
  chk('P2: one materialize quick-task per task, --task <taskDir> --out <outDir>/<band>/<id>/mat',
    mats.length === 2 && mats.every(m => m.opts.agentType === 'triage-quick-task') &&
    mats.some(m => m.prompt.includes(`materialize --task '${SUITE}/1/t1' --out '${OUT}/1/t1/mat'`)))
  const w1 = wf.find(w => w.args.outDir === `${OUT}/1/t1/cmp`)
  chk('P2: each build task nests ONE triage-compare on the materialized repo at its sha, parallel:true',
    wf.length === 2 && wf.every(w => w.name === 'triage-compare' && w.args.parallel === true) && w1 &&
    w1.args.repo === `${OUT}/1/t1/mat/repo` && w1.args.base === SHA && w1.args.brief === 'Brief t1.' && w1.args.checks[0] === 'sh test.sh' &&
    w1.args.files[0] === 'calc.sh' && w1.args.acceptance === 'acc t1')
  chk('P2: the hidden overlay is passed as an absolute path in the task dir (never shown in a brief)', w1 && w1.args.overlay === `${SUITE}/1/t1/hidden`)
  chk('P2: compare candidates carry the stable parity labels, vendor and level',
    w1 && w1.args.candidates.map(c => `${c.label}:${c.vendor}:${c.level}`).join() === 'cb:claude:builder,xb:codex:builder,ab:agy:builder')
  const w2 = wf.find(w => w.args.outDir === `${OUT}/1/t2/cmp`)
  chk('P2: a vendor the task does not allow is not a candidate there, and is recorded as skipped', w2 && !w2.args.candidates.some(c => c.vendor === 'agy') && cellOf(result, 't2', 'ab').status === 'skipped')
  chk('P2: skipped is not counted (agy: 1 graded task in band 1, not 2)', rank(result, 'ab').perBand[1].pass === 1 && rank(result, 'ab').perBand[1].other === 0)
  chk('P2: the task matrix is complete: every task x candidate has a cell', result.tasks.length === 2 && result.tasks.every(t => t.results.length === 3))
  chk('P2: external tokens and seconds are summed from the compare results', rank(result, 'xb').externalTokens === 2000 && rank(result, 'xb').seconds === 20 && rank(result, 'cb').externalTokens === null)
}

// ---- P3: a deny-marked vendor is dropped for that task only -------------------
{
  const tasks = [task('t1', 1), task('t2', 1)]
  const { result, wf, logs } = await run(A({ bands: [1], candidates: [C('claude', 'deep', 'cd'), C('codex', 'deep', 'xd')] }), { tasks, denied: { t1: { codex: true } } })
  const w1 = wf.find(w => w.args.outDir === `${OUT}/1/t1/cmp`)
  const w2 = wf.find(w => w.args.outDir === `${OUT}/1/t2/cmp`)
  chk('P3: materialize reports codex denied for t1 => the codex candidate is not in t1\'s compare', w1 && w1.args.candidates.map(c => c.label).join() === 'cd')
  chk('P3: ...but still runs t2', w2 && w2.args.candidates.map(c => c.label).join() === 'cd,xd')
  chk('P3: the dropped run is recorded as denied and counted as other, never as a fail',
    cellOf(result, 't1', 'xd').status === 'denied' && rank(result, 'xd').perBand[1].pass === 1 && rank(result, 'xd').perBand[1].fail === 0 && rank(result, 'xd').perBand[1].other === 1)
  chk('P3: the drop is logged', logs.some(l => /t1: xd dropped .*deny-marked for codex/.test(l)))
  const all = await run(A({ bands: [1], candidates: [C('codex', 'deep', 'xd')] }), { tasks: [task('t1', 1)], denied: { t1: { codex: true } } })
  chk('P3: a task with every candidate denied runs no compare at all', all.wf.length === 0 && cellOf(all.result, 't1', 'xd').status === 'denied')
}

// ---- P4: adaptive stop after CONSECUTIVE failed bands only --------------------
{
  // weak fails B1 and B2 -> stops after B2. zig fails B1, passes B2, fails B3 -> never 2 in a row -> runs B4.
  const outcome = (id, l) => ({ weak: { t1: 'fail', t2: 'fail' }, zig: { t1: 'fail', t2: 'pass', t3: 'fail', t4: 'pass' } }[l] || {})[id] || 'pass'
  const { result, wf, logs } = await run(A({ candidates: [C('claude', 'quick', 'weak'), C('claude', 'deep', 'zig'), C('claude', 'deep', 'strong')] }), { outcome })
  const inBand = (b, l) => wf.some(w => w.args.outDir.startsWith(`${OUT}/${b}/`) && w.args.candidates.some(c => c.label === l))
  chk('P4: two consecutive failed bands stop a candidate (weak ran B1, B2 only)', inBand(1, 'weak') && inBand(2, 'weak') && !inBand(3, 'weak') && !inBand(4, 'weak'))
  chk('P4: ...its stop is logged with the bands it will not run (no silent caps)', logs.some(l => /weak stops after band 2: 2 consecutive failed band\(s\) — bands 3,4 not run for it/.test(l)))
  chk('P4: non-consecutive failures do NOT stop a candidate (zig: fail, pass, fail -> still runs B4)', inBand(4, 'zig') && rank(result, 'zig').stoppedAfterBand === null)
  chk('P4: highestBandCleared is the highest band passed (zig B4, weak 0, strong B4)',
    rank(result, 'zig').highestBandCleared === 4 && rank(result, 'weak').highestBandCleared === 0 && rank(result, 'strong').highestBandCleared === 4 && rank(result, 'weak').stoppedAfterBand === 2)
  chk('P4: ranking orders by highest band cleared, then pass rate (strong, zig, weak)', result.ranking.map(r => r.label).join() === 'strong,zig,weak')
  chk('P4: plateaus cluster candidates by the band they top out at', JSON.stringify(result.plateaus) === JSON.stringify({ 0: ['weak'], 4: ['strong', 'zig'] }))
  const three = await run(A({ stopAfterFailedBands: 3, candidates: [C('claude', 'quick', 'weak')] }), { outcome })
  chk('P4: stopAfterFailedBands is honoured (3: weak keeps going into B3)', three.wf.some(w => w.args.outDir.startsWith(`${OUT}/3/`)))
}

// ---- P5: unavailable (and friends) never count as pass or fail ------------------
{
  const outcome = (id, l) => (l === 'flaky' && (id === 't1' || id === 't2') ? 'unavailable' : l === 'flaky' && id === 't3' ? 'ungraded' : 'pass')
  const { result, wf, logs } = await run(A({ candidates: [C('codex', 'builder', 'flaky'), C('claude', 'builder', 'ok')] }), { outcome })
  chk('P5: unavailable runs count as other, never as fail', rank(result, 'flaky').perBand[1].fail === 0 && rank(result, 'flaky').perBand[1].other === 1 && rank(result, 'flaky').perBand[2].other === 1)
  chk('P5: bands with only unavailable/ungraded runs neither clear nor fail — the candidate is not stopped and reaches B4',
    wf.some(w => w.args.outDir.startsWith(`${OUT}/4/`) && w.args.candidates.some(c => c.label === 'flaky')) && rank(result, 'flaky').stoppedAfterBand === null)
  chk('P5: ...and its highest band cleared is B4 (the one it passed), rate null where nothing was graded',
    rank(result, 'flaky').highestBandCleared === 4 && rank(result, 'flaky').perBand[1].rate === null)
  chk('P5: the neither-nor band is logged', logs.some(l => /flaky: no graded task in band 1/.test(l)))
  const crash = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [task('t1', 1)], compare: () => { throw new Error('child crashed') } })
  chk('P5: a triage-compare that throws => unavailable (flagged), not fail', cellOf(crash.result, 't1', 'a').status === 'unavailable' && rank(crash.result, 'a').perBand[1].fail === 0 && crash.result.flags.some(f => /triage-compare failed/.test(f)))
  const mat = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [task('t1', 1)], script: { 'materialize:': [new Error('boom')] } })
  chk('P5: a failed materialize => unavailable (flagged), no compare', mat.wf.length === 0 && cellOf(mat.result, 't1', 'a').status === 'unavailable' && mat.result.flags.some(f => /materialize failed/.test(f)))
  const badMat = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [task('t1', 1)], script: { 'materialize:': [{ repo: '/elsewhere/repo', sha: SHA, denied: { agy: false, codex: false } }] } })
  chk('P5: a materialize reply naming another repo path is rejected (the computed path is the only one used)', badMat.wf.length === 0 && cellOf(badMat.result, 't1', 'a').status === 'unavailable')
}

// ---- P6: rubric tasks — blind judges, agreement, disagreement -----------------
{
  const tasks = [task('rb', 4, { grading: 'rubric', key: 'key.md', vendors: ['claude', 'codex'] })]
  const outcome = (id, l) => (l === 'zz-failing' ? 'fail' : 'pass')
  // Scores by anonymized patch: derived from the copy command's mapping.
  let anonOf = {}
  const copy = p => {
    anonOf = {}
    for (const m of p.matchAll(/cp '[^']*\/([^/']+)\.patch' '[^']*\/(s\d+)\.patch'/g)) anonOf[m[2]] = m[1]
    return { ok: true, rc: 0 }
  }
  const want = { 'alpha-agree': [0.9, 0.8], 'beta-split': [0.9, 0.5], 'gamma-low': [0.6, 0.65], 'zz-failing': [0.95, 0.95] }
  const score = (which, p, o) => {
    const anon = (o.label.match(/:(s\d+)$/) || [])[1]
    return want[anonOf[anon]][which]
  }
  const { result, calls, logs } = await run(A({ bands: [4], candidates: [C('claude', 'deep', 'alpha-agree'), C('claude', 'deep', 'beta-split'), C('codex', 'deep', 'gamma-low'), C('claude', 'builder', 'zz-failing')] }), {
    tasks, outcome,
    script: {
      'judge:copy': [copy],
      'judge:claude-deep': [(p, o) => ({ score: score(0, p, o), rationale: 'r' })],
      'judge:codex-deep': [(p, o) => `CROSS-REVIEW (codex · review · exit 0)\n{"score": ${score(1, p, o)}, "rationale": "r"}\next-run: 10 tokens (1s, codex/gpt-6-astra)`],
    },
  })
  const jc = calls.filter(c => /^judge:(claude|codex)-deep@rb:s\d+$/.test(c.label))
  chk('P6: each judge scores every graded candidate (2 judges x 4 patches, failing one included)', jc.length === 8)
  chk('P6: the Claude judge is a deep-level agent with a schema; the codex judge is triage-cross-reviewer VENDOR=codex MODE=review with --input patch + key',
    jc.filter(c => c.label.startsWith('judge:claude')).every(c => c.opts.agentType === 'triage-deep-reasoner' && c.opts.schema) &&
    jc.filter(c => c.label.startsWith('judge:codex')).every(c => c.opts.agentType === 'triage-cross-reviewer' && /^VENDOR=codex\nMODE=review\n/.test(c.prompt) &&
      new RegExp(`--input ${OUT}/4/rb/judge/s\\d+\\.patch --input ${SUITE}/4/rb/key\\.md`).test(c.prompt)))
  chk('P6: judges are blind — no judge prompt or label names any candidate', jc.every(c => !/alpha|beta|gamma|zz-failing/.test(c.prompt + c.label)))
  const cp = calls.find(c => c.label === 'judge:copy@rb')
  chk('P6: patches are copied to anonymized ids under outDir before judging', cp && /mkdir -p '\/o\/par\/4\/rb\/judge'/.test(cp.prompt) && Object.keys(anonOf).length === 4)
  chk('P6: both judges >= 0.7 (and checks pass) => pass', cellOf(result, 'rb', 'alpha-agree').status === 'pass')
  chk('P6: judges 0.3+ apart => unresolved, flagged for Alex, counted neither pass nor fail',
    cellOf(result, 'rb', 'beta-split').status === 'unresolved' && result.flags.some(f => /JUDGES DISAGREE on rb\/beta-split/.test(f)) && rank(result, 'beta-split').perBand[4].other === 1 && rank(result, 'beta-split').perBand[4].fail === 0)
  chk('P6: agreeing judges below 0.7 => fail', cellOf(result, 'rb', 'gamma-low').status === 'fail')
  chk('P6: a candidate whose checks failed stays a fail whatever the judges say', cellOf(result, 'rb', 'zz-failing').status === 'fail')
  chk('P6: judge scores are recorded on the cell', cellOf(result, 'rb', 'alpha-agree').judges['claude-deep'] === 0.9 && cellOf(result, 'rb', 'alpha-agree').judges['codex-deep'] === 0.8)
  const dead = await run(A({ bands: [4], candidates: [C('claude', 'deep', 'alpha-agree')] }), {
    tasks, outcome, script: { 'judge:copy': [copy], 'judge:claude-deep': [{ score: 0.9 }], 'judge:codex-deep': ['UNAVAILABLE: codex exited 4'] },
  })
  chk('P6: a judge that returns nothing => unresolved, never pass', cellOf(dead.result, 'rb', 'alpha-agree').status === 'unresolved')
  chk('P6: no Fable warning for deep judges', !logs.some(l => /Escalating to Fable/.test(l)))
}

// ---- P7: review tasks — read-only reviewers, score-review, thresholds --------
{
  const tasks = [task('rv', 3, { kind: 'review', grading: 'seeded', key: 'key.json', checks: [], overlay: null, files: ['app.py', 'lib/util.py'], vendors: ['claude', 'codex'] })]
  const scoreReply = p => ({
    scores: [...p.matchAll(/--findings '[^']*\/([^/']+)\.json'/g)].map(m => (
      { good: { label: 'good', recall: 0.67, precision: 0.5, matched: ['S1', 'S2'] }, poor: { label: 'poor', recall: 0.33, precision: 1, matched: ['S1'] }, xgood: { label: 'xgood', recall: 1, precision: 0.6, matched: ['S1', 'S2', 'S3'] } }[m[1]])),
  })
  const { result, calls, wf } = await run(A({ bands: [3], candidates: [C('claude', 'deep', 'good'), C('claude', 'builder', 'poor'), C('codex', 'deep', 'xgood'), C('codex', 'builder', 'xjunk')] }), {
    tasks,
    script: {
      'candidate:good@rv': [{ findings: [{ file: 'app.py', line: 3, desc: 'a' }] }],
      'candidate:poor@rv': [{ findings: [{ file: 'app.py', line: 30, desc: 'b' }] }],
      'candidate:xgood@rv': ['CROSS-REVIEW (codex · review · exit 0)\n```json\n{"findings":[{"file":"app.py","line":9,"desc":"c"}]}\n```\next-run: 500 tokens (4s, codex/gpt-6-astra)'],
      'candidate:xjunk@rv': ['CROSS-REVIEW (codex · review · exit 0)\nI found some problems but will not say where.'],
      'score:rv': [scoreReply],
    },
  })
  chk('P7: a review task runs no triage-compare', wf.length === 0)
  const cg = calls.find(c => c.label === 'candidate:good@rv')
  chk('P7: a Claude reviewer is its level agent with a findings schema, told read-only and `cd <repo> && ` for every command',
    cg && cg.opts.agentType === 'triage-deep-reasoner' && cg.opts.schema && cg.prompt.includes(`\`cd ${OUT}/3/rv/mat/repo && \``) && /READ-ONLY/.test(cg.prompt))
  const cx = calls.find(c => c.label === 'candidate:xgood@rv')
  chk('P7: an external reviewer is triage-cross-reviewer VENDOR=codex MODE=review with every file as an absolute --input',
    cx && cx.opts.agentType === 'triage-cross-reviewer' && /^VENDOR=codex\nMODE=review\n/.test(cx.prompt) && cx.prompt.includes(`--input ${OUT}/3/rv/mat/repo/app.py --input ${OUT}/3/rv/mat/repo/lib/util.py`))
  chk('P7: no reviewer prompt names the key or the task dir', calls.filter(c => c.label.startsWith('candidate:')).every(c => !c.prompt.includes('key.json') && !c.prompt.includes(SUITE)))
  chk('P7: the Claude reviewer prompt tells it never to inspect git history and gives no git-history command (git log/show/diff)',
    /never inspect git history/i.test(cg.prompt) && !/git (log|show|diff)\b/.test(cg.prompt))
  const sc = calls.filter(c => c.label === 'score:rv')
  chk('P7: ONE quick-task writes each findings file under outDir and runs parity-suite.sh score-review with the key',
    sc.length === 1 && sc[0].opts.agentType === 'triage-quick-task' && sc[0].prompt.includes(`cat > '${OUT}/3/rv/review/good.json' <<'PARITY_FINDINGS_EOF'`) &&
    sc[0].prompt.includes(`parity-suite.sh score-review --key '${SUITE}/3/rv/key.json' --findings '${OUT}/3/rv/review/xgood.json'`) && sc[0].prompt.includes('{"findings":[{"file":"app.py","line":9,"desc":"c"}]}'))
  chk('P7: recall >= 0.6 and precision >= 0.5 => pass; recall below => fail', cellOf(result, 'rv', 'good').status === 'pass' && cellOf(result, 'rv', 'poor').status === 'fail' && cellOf(result, 'rv', 'xgood').status === 'pass')
  chk('P7: the recall/precision/matched are on the cell', cellOf(result, 'rv', 'good').recall === 0.67 && cellOf(result, 'rv', 'good').matched.join() === 'S1,S2')
  chk('P7: an external reply without the findings JSON => invalid (flagged), not a fail, and never scored',
    cellOf(result, 'rv', 'xjunk').status === 'invalid' && rank(result, 'xjunk').perBand[3].fail === 0 && !sc[0].prompt.includes('xjunk.json') && result.flags.some(f => /xjunk/.test(f)))
  chk('P7: the review-mode model caveat for external reviewers is flagged', result.flags.some(f => /review-mode model/.test(f)))
  const noScore = await run(A({ bands: [3], candidates: [C('claude', 'deep', 'good')] }), { tasks, script: { 'candidate:good@rv': [{ findings: [] }], 'score:rv': [new Error('dead')] } })
  chk('P7: a dead scorer => ungraded (other), not a fail', cellOf(noScore.result, 'rv', 'good').status === 'ungraded' && rank(noScore.result, 'good').perBand[3].other === 1)
}

// ---- P8: a compare LEAK aborts the whole run loudly ------------------------------
{
  const tasks = [task('t1', 1), task('t2', 1)]
  const r = await throws(A({ candidates: [C('claude', 'builder', 'a')] }), {
    tasks, compare: (n, a) => ({ leak: a.outDir.includes('/t2/'), candidates: a.candidates.map(c => ({ label: c.label, status: 'pass', patch: '/p' })) }),
  })
  chk('P8: leak:true from any task\'s compare aborts the run (throws, names the task, no ranking)', r.threw && /LEAK in task t2/.test(r.message))
  chk('P8: ...logged with ⚠ as it is found', r.logs.some(l => l.startsWith('⚠ LEAK in task t2')))
  chk('P8: ...and no later band runs', !r.calls.some(c => /^materialize:/.test(c.label) && !/t1|t2/.test(c.label)))
  const unk = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), {
    tasks: [task('t1', 1)], compare: (n, a) => ({ leak: null, candidates: a.candidates.map(c => ({ label: c.label, status: 'pass', patch: '/p' })) }),
  })
  chk('P8: an incomplete leak check is flagged but does not abort', unk.result.flags.some(f => /leak check incomplete/.test(f)) && cellOf(unk.result, 't1', 'a').status === 'pass')
}

// ---- P9: the proposal — cheapest clearing candidate, incumbents respected ------
{
  const tasks = [task('q1', 1), task('q2', 1), task('b1', 2), task('b2', 2)]
  // B1: everyone passes q1; haiku fails q2 (rate 0.5), sonnet and opus pass both (1.0).
  // B2: opus passes both; haiku fails both; sonnet passes one.
  const outcome = (id, l) => ({ haiku: { q2: 'fail', b1: 'fail', b2: 'fail' }, sonnet: { b2: 'fail' }, 'luna-hi': { q2: 'fail', b1: 'fail', b2: 'fail' } }[l] || {})[id] || 'pass'
  const cands = [
    C('claude', 'deep', 'opus', { model: 'opus', effort: 'high' }),
    C('claude', 'quick', 'haiku', { model: 'haiku', effort: 'low' }),
    C('claude', 'builder', 'sonnet', { model: 'sonnet', effort: 'medium' }),
    C('codex', 'builder', 'sol-hi', { model: 'gpt-6-sol', effort: 'high' }),
    C('codex', 'builder', 'sol-lo', { model: 'gpt-6-sol', effort: 'low' }),
    C('codex', 'quick', 'luna-hi', { model: 'gpt-6-luna', effort: 'high' }),
  ]
  const { result } = await run(A({ bands: [1, 2], candidates: cands }), { tasks, outcome })
  chk('P9: among Claude candidates the ranking puts the strongest first (opus), so a proposal taken in ranking order would be wrong', result.ranking.filter(r => r.vendor === 'claude')[0].label === 'opus')
  chk('P9: quick/claude = the CHEAPEST candidate clearing band 1 (haiku at 0.5 >= bandPassRate), not the top-ranked one',
    result.proposal.quick && result.proposal.quick.claude.label === 'haiku' && result.proposal.quick.claude.basis === 'parity-run')
  chk('P9: builder/claude = sonnet (clears band 2 at 0.5; haiku does not clear it)', result.proposal.builder.claude.label === 'sonnet')
  chk('P9: model order before effort: codex quick = luna-hi (luna < sol even at high effort)', result.proposal.quick.codex.label === 'luna-hi')
  chk('P9: same model, lower effort wins: codex builder = sol-lo', result.proposal.builder.codex.label === 'sol-lo')
  chk('P9: a level whose band was not run gets no proposal', result.proposal.deep === undefined && result.proposal.top === undefined)
  const inc = await run(A({ bands: [1, 2], candidates: cands, incumbents: { quick: { claude: 'sonnet' }, builder: { claude: 'opus' } } }), { tasks, outcome })
  chk('P9: an incumbent raises the bar: quick/claude = sonnet (haiku 0.5 < incumbent sonnet 1.0)', inc.result.proposal.quick.claude.label === 'sonnet' && inc.result.proposal.quick.claude.incumbent === 'sonnet' && inc.result.proposal.quick.claude.incumbentRate === 1)
  chk('P9: builder/claude with incumbent opus (1.0 in band 2) = opus itself (sonnet 0.5 falls short)', inc.result.proposal.builder.claude.label === 'opus')
  chk('P9: the markdown summary has the ranking and the proposal tables and says it is a proposal',
    /\| opus \| claude \| opus \| high \| B2 \|/.test(result.markdown) && /\| quick \| claude \| haiku/.test(result.markdown) && /Alex approves/.test(result.markdown))
  const weakOutcome = (id, l) => (l === 'weak' ? 'fail' : 'pass')
  const nm = await run(A({ bands: [1, 2], stopAfterFailedBands: 1, candidates: [C('claude', 'builder', 'weak'), C('claude', 'builder', 'ok')], incumbents: { builder: { claude: 'weak' } } }), { tasks, outcome: weakOutcome })
  chk('P9: an incumbent that stopped before the level\'s band (never measured there) is flagged, not silently dropped',
    nm.result.flags.some(f => /incumbent weak not measured at band 2 — bar dropped/.test(f)))
}

// ---- P10: the Fable warning precedes any top-level Claude candidate or judge --
{
  const { events } = await run(A({ bands: [1], candidates: [C('claude', 'top', 'fab'), C('codex', 'top', 'astra')] }), { tasks: [task('t1', 1)] })
  const warn = events.findIndex(e => e === 'log:⚠ Escalating to Fable: parity candidate fab')
  const cmp = events.findIndex(e => e.startsWith('workflow:triage-compare'))
  chk('P10: "⚠ Escalating to Fable: parity candidate <label>" is logged before the compare that runs it', warn >= 0 && cmp > warn)
  chk('P10: no Fable warning for a codex top candidate', !events.some(e => /Escalating to Fable: parity candidate astra/.test(e)))
  const tasks = [task('rv', 1, { kind: 'review', grading: 'seeded', key: 'key.json', checks: [], vendors: ['claude'] })]
  const rv = await run(A({ bands: [1], candidates: [C('claude', 'top', 'fab')] }), { tasks, script: { 'candidate:fab@rv': [{ findings: [] }], 'score:rv': [{ scores: [{ label: 'fab', recall: 1, precision: 1 }] }] } })
  const w2 = rv.events.findIndex(e => e === 'log:⚠ Escalating to Fable: parity candidate fab')
  chk('P10: ...also before a top-level Claude reviewer spawn', w2 >= 0 && rv.events.findIndex(e => e === 'agent:candidate:fab@rv') > w2)
  const rb = [task('rb', 1, { grading: 'rubric', key: 'key.md', vendors: ['claude'] })]
  const jt = await run(A({ bands: [1], judges: [{ vendor: 'claude', level: 'top' }], candidates: [C('claude', 'builder', 'b')] }), { tasks: rb, script: { 'judge:claude-top': [{ score: 0.9 }] } })
  const w3 = jt.events.findIndex(e => e === 'log:⚠ Escalating to Fable: parity judge claude-top')
  chk('P10: ...and before a top-level Claude judge', w3 >= 0 && jt.events.findIndex(e => e.startsWith('agent:judge:claude-top')) > w3)
}

// ---- P11: nothing outside outDir is written; tiers.json never touched ---------
{
  const tasks = [task('t1', 1), task('rb', 2, { grading: 'rubric', key: 'key.md', vendors: ['claude'] }), task('rv', 3, { kind: 'review', grading: 'seeded', key: 'key.json', checks: [], vendors: ['claude'] })]
  const { calls, wf, result } = await run(A({ desk: true, candidates: [C('claude', 'builder', 'b'), C('codex', 'builder', 'x')] }), {
    tasks, script: { 'judge:claude-deep': [{ score: 0.9 }], 'judge:codex-deep': ['{"score": 0.9}'], 'candidate:b@rv': [{ findings: [] }], 'score:rv': [{ scores: [{ label: 'b', recall: 1, precision: 1 }] }] },
  })
  const text = calls.map(c => c.prompt).join('\n') + JSON.stringify(wf.map(w => w.args))
  chk('P11: no prompt or nested workflow arg mentions tiers.json, tiers-sync or make tiers', !/tiers\.json|tiers-sync|make tiers/.test(text) && !/tiers\.json/.test(JSON.stringify(result.proposal)))
  const targets = []
  for (const c of calls) {
    for (const m of c.prompt.matchAll(/(?:--out|mkdir -p|cat >) '([^']+)'/g)) targets.push(m[1])
    for (const m of c.prompt.matchAll(/cp '[^']+' '([^']+)'/g)) targets.push(m[1])
  }
  for (const w of wf) targets.push(w.args.outDir)
  chk('P11: every path this run writes (materialize --out, compare outDir, findings, judge copies) is under outDir',
    targets.length >= 5 && targets.every(p => p === OUT || p.startsWith(`${OUT}/`)))
  chk('P11: the proposal is only returned (basis parity-run), and the result carries the flags/desk/markdown fields',
    Array.isArray(result.flags) && typeof result.markdown === 'string' && result.desk && result.desk.note === 'signal only, never scored')
}

// ---- P12: reps, the desk leg, the loader --------------------------------------
{
  const tasks = [task('t1', 1), task('rv', 1, { kind: 'review', grading: 'seeded', key: 'key.json', checks: [], vendors: ['claude'] })]
  const outcome = (id, l) => (l === 'a-r2' ? 'fail' : 'pass')
  const { result, wf, calls, logs } = await run(A({ bands: [1], reps: 2, candidates: [C('claude', 'builder', 'a')] }), {
    tasks, outcome, script: { 'candidate:a@rv': [{ findings: [] }], 'score:rv': [{ scores: [{ label: 'a', recall: 1, precision: 1 }] }] },
  })
  chk('P12: reps=2 repeats a build task with a -r2 label in the same compare', wf[0].args.candidates.map(c => c.label).join() === 'a,a-r2')
  chk('P12: both reps count toward the base label (t1: 1 pass + 1 fail, plus the review pass)', rank(result, 'a').perBand[1].pass === 2 && rank(result, 'a').perBand[1].fail === 1)
  chk('P12: review tasks are not repeated (and that is logged)', calls.filter(c => c.label.startsWith('candidate:a')).length === 1 && logs.some(l => /reps=2 applies to build tasks only/.test(l)))
  const d = await run(A({ desk: true, bands: [1], candidates: [C('claude', 'builder', 'a', { model: 'sonnet' }), C('codex', 'deep', 'x', { model: 'gpt-6-astra', effort: 'high' })] }), { tasks: [task('t1', 1)] })
  const desk = d.calls.filter(c => c.label.startsWith('desk:'))
  chk('P12: the desk leg is one codex and one agy cross-reviewer call in verify mode naming the candidate models',
    desk.length === 2 && desk.every(c => c.opts.agentType === 'triage-cross-reviewer') && desk.some(c => /^VENDOR=codex\nMODE=verify\n/.test(c.prompt)) &&
    desk.some(c => /^VENDOR=agy\nMODE=verify\n/.test(c.prompt)) && desk.every(c => c.prompt.includes('codex:gpt-6-astra@high') && c.prompt.includes('claude:sonnet')))
  chk('P12: the desk result is returned as signal and never scored', d.result.desk.codex.includes('published numbers') && !d.result.ranking.some(r => r.label.startsWith('desk')))
  chk('P12: desk:false skips it', calls.every(c => !c.label.startsWith('desk:')) && result.desk === null)
  const filt = await run(A({ taskFilter: ['t2', 'nope'], candidates: [C('claude', 'builder', 'a')] }))
  chk('P12: taskFilter keeps only the named tasks, logs what it dropped, flags unknown ids',
    filt.wf.length === 1 && filt.wf[0].args.outDir === `${OUT}/2/t2/cmp` && filt.logs.some(l => /taskFilter kept 1 of 4/.test(l)) && filt.result.flags.some(f => /unknown task\(s\): nope/.test(f)))
  const dead = await throws(A({ candidates: [C('claude', 'builder', 'a')] }), { script: { 'load:': [{ tasks: [{ id: 'x' }] }] } })
  chk('P12: a malformed task list is retried once, then the run throws before any materialize',
    dead.threw && /could not load a valid task list/.test(dead.message) && dead.calls.filter(c => c.label.startsWith('load:')).length === 2 && !dead.calls.some(c => c.label.startsWith('materialize:')))
  const out = await throws(A({ candidates: [C('claude', 'builder', 'a')] }), { script: { 'load:': [{ tasks: [task('t1', 1, { taskDir: '/elsewhere/1/t1' })] }] } })
  chk('P12: a loaded taskDir outside the suite is rejected', out.threw && /could not load/.test(out.message))
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
