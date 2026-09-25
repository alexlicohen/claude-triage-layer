#!/usr/bin/env node
// Scenario tests for workflows/triage-parity.js — executes the ACTUAL workflow
// body under mocked DSL globals (agent/workflow/parallel/log/phase/budget), the
// way test/compare-scenarios.mjs does for triage-compare.js. Covers: validation
// before any spawn; the loader -> materialize -> triage-compare wiring; vendors
// restricted per task and deny-marked vendors dropped per task; the adaptive stop
// (consecutive failed bands only); unavailable/denied/invalid/unresolved never
// counted as pass or fail; rubric judges (blind, agreement, disagreement); the
// review scoring path; a LEAK aborting the run; the ranking with NO proposal (the
// decision rule is scripts/parity-report.sh's, tested by test/parity-report.sh);
// the Fable warning; reps; the desk leg; that nothing outside outDir (never
// tiers.json) is ever written; the source-repo fingerprint guard on every task
// kind (SOURCE_CHANGED/UNVERIFIED => invalid, run continues); judges given only
// patch + key; selfCheckEnv passed through only on opt-in; the ignored-files and
// refs fingerprint fields, generator tasks marked guarded:false, and modelFrom
// forwarded on every build row.
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
// The source fingerprint parity-suite.sh fingerprint prints for a git source
// (materialize's first command, and source:after@<id> after grading).
const FP = (id, over = {}) => Object.assign({ id, source: 'git', guarded: true, name: 'srcrepo', head: 'c'.repeat(40), tree: 'd'.repeat(40), ignored: 'e'.repeat(40), refs: 'f'.repeat(40) }, over)
const fpId = p => (p.match(/fingerprint --task '[^']*\/([^/']+)'/) || [])[1]

// run(args, opts) — opts.tasks: the loader's list; opts.denied: {taskId: {codex}};
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
      return { fingerprint: FP(fpId(p)), repo: `${out}/repo`, sha: SHA, denied: Object.assign({ codex: false }, denied[id] || {}), rc: 0 }
    }],
    'source:': [p => FP(fpId(p))],
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
        return { label: c.label, vendor: c.vendor, level: c.level, model: c.model || (ext ? 'gpt-6-sol' : null), modelFrom: c.model ? 'candidate' : (ext ? 'runner' : null), effort: c.effort || null, status,
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
    ['retired agy candidate', A({ candidates: [C('agy', 'builder', 'a')] })],
    ['retired agy judge', A({ candidates: ok, judges: [{ vendor: 'agy', level: 'builder' }, { vendor: 'claude', level: 'deep' }] })],
    ['bad effort', A({ candidates: [C('codex', 'deep', 'a', { effort: 'ultra' })] })],
    ['label reserved for reps', A({ candidates: [C('claude', 'deep', 'x-r2')] })],
    ['label with @', A({ candidates: [C('claude', 'deep', 'x@y')] })],
    ['duplicate labels', A({ candidates: [C('claude', 'deep', 'x'), C('codex', 'deep', 'x')] })],
    ['band 0', A({ bands: [0], candidates: ok })],
    ['reps 0', A({ reps: 0, candidates: ok })],
    ['bandPassRate 2', A({ bandPassRate: 2, candidates: ok })],
    ['stopAfterFailedBands 0', A({ stopAfterFailedBands: 0, candidates: ok })],
    ['incumbents (moved to parity-report.sh)', A({ candidates: ok, incumbents: { builder: { claude: 'a' } } })],
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
  const tasks = [task('t1', 1), task('t2', 1, { vendors: ['codex'] })]
  const { result, calls, wf } = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'cb'), C('codex', 'builder', 'xb'), C('claude', 'quick', 'ab')] }), { tasks })
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
    w1 && w1.args.candidates.map(c => `${c.label}:${c.vendor}:${c.level}`).join() === 'cb:claude:builder,xb:codex:builder,ab:claude:quick')
  const w2 = wf.find(w => w.args.outDir === `${OUT}/1/t2/cmp`)
  chk('P2: a vendor the task does not allow is not a candidate there, and is recorded as skipped', w2 && !w2.args.candidates.some(c => c.vendor === 'claude') && cellOf(result, 't2', 'ab').status === 'skipped')
  chk('P2: skipped is not counted (ab: 1 graded task in band 1, not 2)', rank(result, 'ab').perBand[1].pass === 1 && rank(result, 'ab').perBand[1].other === 0)
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
  const badMat = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [task('t1', 1)], script: { 'materialize:': [{ repo: '/elsewhere/repo', sha: SHA, denied: { codex: false } }] } })
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
  chk('P6: the Claude judge is a deep-level agent with a schema; the codex judge is triage-cross-reviewer VENDOR=codex MODE=review with --input patch + key (both staged in its own judge dir)',
    jc.filter(c => c.label.startsWith('judge:claude')).every(c => c.opts.agentType === 'triage-deep-reasoner' && c.opts.schema) &&
    jc.filter(c => c.label.startsWith('judge:codex')).every(c => c.opts.agentType === 'triage-cross-reviewer' && /^VENDOR=codex\nMODE=review\n/.test(c.prompt) &&
      new RegExp(`--input ${OUT}/4/rb/judge/(s\\d+)/\\1\\.patch --input ${OUT}/4/rb/judge/\\1/key\\.md\\n`).test(c.prompt)))
  // (e) JUDGES: patch + key only. No judge prompt names a repo (the materialized
  // one or any source), the task dir or the suite; a codex judge gets exactly two
  // --input files; a Claude judge is named exactly two paths, both in its own dir.
  chk('P6: no judge prompt names a repo path, the task dir or the suite — and each says read only these two files, no cd',
    jc.every(c => !c.prompt.includes('/mat/repo') && !c.prompt.includes('/mat') && !c.prompt.includes(SUITE) && !/\/src\/|repository is \//.test(c.prompt) &&
      c.prompt.includes('Read only these two files; do not cd anywhere') && /no repository access/.test(c.prompt)))
  chk('P6: a codex judge gets exactly 2 --input files (its patch and the key); a Claude judge is named exactly 2 paths, both in its own judge dir',
    jc.filter(c => c.label.startsWith('judge:codex')).every(c => (c.prompt.match(/--input /g) || []).length === 2) &&
    jc.every(c => {
      const anon = (c.label.match(/:(s\d+)$/) || [])[1]
      const paths = c.prompt.match(/\/[^\s'"`]+/g) || []
      const fsPaths = paths.filter(x => x.startsWith('/o/') || x.startsWith('/s/'))
      return fsPaths.length === 2 && fsPaths.every(x => x.startsWith(`${OUT}/4/rb/judge/${anon}/`))
    }))
  chk('P6: judges are blind — no judge prompt or label names any candidate', jc.every(c => !/alpha|beta|gamma|zz-failing/.test(c.prompt + c.label)))
  const cp = calls.find(c => c.label === 'judge:copy@rb')
  chk('P6: patches are copied to anonymized ids under outDir before judging, each with the key into its own fresh judge dir',
    cp && /mkdir -p '\/o\/par\/4\/rb\/judge\/s1' '\/o\/par\/4\/rb\/judge\/s2'/.test(cp.prompt) && Object.keys(anonOf).length === 4 &&
    [1, 2, 3, 4].every(i => cp.prompt.includes(`cp '${SUITE}/4/rb/key.md' '${OUT}/4/rb/judge/s${i}/key.md'`)))
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
  const { result, calls, wf } = await run(A({ bands: [3], candidates: [C('claude', 'deep', 'good'), C('claude', 'builder', 'poor'), C('codex', 'deep', 'xgood', { model: 'gpt-6-astra', effort: 'high' }), C('codex', 'builder', 'xjunk')] }), {
    tasks,
    script: {
      'candidate:good@rv': [{ findings: [{ file: 'app.py', line: 3, desc: 'a' }] }],
      'candidate:poor@rv': [{ findings: [{ file: 'app.py', line: 30, desc: 'b' }] }],
      'candidate:xgood@rv': ['CROSS-REVIEW (codex · read · exit 0)\n```json\n{"findings":[{"file":"app.py","line":9,"desc":"c"}]}\n```\next-run: 500 tokens (4s, codex/gpt-6-astra)'],
      'candidate:xjunk@rv': ['CROSS-REVIEW (codex · read · exit 0)\nI found some problems but will not say where.'],
      'score:rv': [scoreReply],
    },
  })
  chk('P7: a review task runs no triage-compare', wf.length === 0)
  const cg = calls.find(c => c.label === 'candidate:good@rv')
  chk('P7: a Claude reviewer is its level agent with a findings schema, told read-only and `cd <repo> && ` for every command',
    cg && cg.opts.agentType === 'triage-deep-reasoner' && cg.opts.schema && cg.prompt.includes(`\`cd ${OUT}/3/rv/mat/repo && \``) && /READ-ONLY/.test(cg.prompt))
  const cx = calls.find(c => c.label === 'candidate:xgood@rv')
  chk('P7: an external reviewer is triage-cross-reviewer VENDOR=codex MODE=read with MODEL/EFFORT and every file as an absolute --input',
    cx && cx.opts.agentType === 'triage-cross-reviewer' && /^VENDOR=codex\nMODE=read\nMODEL=gpt-6-astra\nEFFORT=high\n/.test(cx.prompt) &&
    cx.prompt.includes(`--input ${OUT}/3/rv/mat/repo/app.py --input ${OUT}/3/rv/mat/repo/lib/util.py`))
  chk('P7: the external reviewer prompt carries the findings JSON Schema for ext-run.sh --schema', /Write this exact JSON Schema/.test(cx.prompt) && cx.prompt.includes('"findings"'))
  const cj = calls.find(c => c.label === 'candidate:xjunk@rv')
  chk('P7: an external reviewer with no candidate model/effort omits the MODEL/EFFORT lines', cj && /^VENDOR=codex\nMODE=read\n(?!MODEL=)(?!EFFORT=)/.test(cj.prompt))
  chk('P7: no review-task candidate is ever sent MODE=review', calls.filter(c => c.label.startsWith('candidate:')).every(c => !/\bMODE=review\b/.test(c.prompt)))
  chk('P7: the Claude reviewer is told to work only inside the materialized repo and search nowhere else',
    cg.prompt.includes(`Work only inside ${OUT}/3/rv/mat/repo. Do not read, list or search any other directory on this machine (including other copies of this project)`))
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
  chk('P7: no review-mode-model caveat is flagged now that external reviewers carry their own model', !result.flags.some(f => /review-mode model/.test(f)))
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

// ---- P9: ranking only — no proposal; the orchestrator runs parity-report.sh ---
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
  chk('P9: the ranking puts the strongest first (opus before sonnet before haiku among Claude)',
    result.ranking.filter(r => r.vendor === 'claude').map(r => r.label).join() === 'opus,sonnet,haiku')
  chk('P9: equal records tie by label, not by cost (sol-hi, sol-lo and opus all clear B2 at 1.0: opus, sol-hi, sol-lo)',
    result.ranking.slice(0, 3).map(r => r.label).join() === 'opus,sol-hi,sol-lo')
  chk('P9: no proposal is returned — the decision rule is parity-report.sh\'s alone', !('proposal' in result))
  chk('P9: the result says what comes next: parity-report.sh ingest-parity, then report',
    Array.isArray(result.next) && result.next.some(l => /parity-report\.sh ingest-parity --result/.test(l)) && result.next.some(l => /parity-report\.sh report/.test(l)) &&
    result.next.findIndex(l => /ingest-parity/.test(l)) < result.next.findIndex(l => /parity-report\.sh report/.test(l)))
  chk('P9: the markdown has the ranking table, no proposal table, and points at parity-report.sh',
    /\| opus \| claude \| opus \| high \| B2 \|/.test(result.markdown) && !/\| Level \| Vendor \| Proposed/.test(result.markdown) && /parity-report\.sh ingest-parity/.test(result.markdown))
  chk('P9: no cheapness inference is flagged any more (cost is not judged here)', !result.flags.some(f => /cheapness/.test(f)))
  const inc = await throws(A({ bands: [1, 2], candidates: cands, incumbents: { quick: { claude: 'sonnet' } } }), { tasks, outcome })
  chk('P9: an incumbents arg is refused before any spawn and names parity-report.sh', inc.threw && /incumbents is no longer accepted/.test(inc.message) && /parity-report\.sh/.test(inc.message) && inc.calls.length === 0)
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
  chk('P11: no prompt or nested workflow arg mentions tiers.json, tiers-sync or make tiers', !/tiers\.json|tiers-sync|make tiers/.test(text))
  const targets = []
  for (const c of calls) {
    for (const m of c.prompt.matchAll(/(?:--out|mkdir -p|cat >) '([^']+)'/g)) targets.push(m[1])
    for (const m of c.prompt.matchAll(/cp '[^']+' '([^']+)'/g)) targets.push(m[1])
  }
  for (const w of wf) targets.push(w.args.outDir)
  chk('P11: every path this run writes (materialize --out, compare outDir, findings, judge copies) is under outDir',
    targets.length >= 5 && targets.every(p => p === OUT || p.startsWith(`${OUT}/`)))
  chk('P11: nothing is proposed, and the result carries the flags/desk/markdown/next fields',
    !('proposal' in result) && Array.isArray(result.next) && Array.isArray(result.flags) && typeof result.markdown === 'string' && result.desk && result.desk.note === 'signal only, never scored')
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
  chk('P12: the desk leg is ONE codex cross-reviewer call in verify mode naming the candidate models (no agy)',
    desk.length === 1 && desk.every(c => c.opts.agentType === 'triage-cross-reviewer') && /^VENDOR=codex\nMODE=verify\n/.test(desk[0].prompt) &&
    desk.every(c => c.prompt.includes('codex:gpt-6-astra@high') && c.prompt.includes('claude:sonnet')) && !('agy' in d.result.desk))
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

// ---- P13: SOURCE-REPO LEAK GUARD on every task kind -----------------------------
{
  const t1 = task('t1', 1)
  const t2 = task('t2', 2)
  const rb = task('rb', 1, { grading: 'rubric', key: 'key.md', vendors: ['claude'] })
  const rv = task('rv', 1, { kind: 'review', grading: 'seeded', key: 'key.json', checks: [], overlay: null, vendors: ['claude'] })
  const base = { 'candidate:a@rv': [{ findings: [] }], 'score:rv': [{ scores: [{ label: 'a', recall: 1, precision: 1 }] }], 'judge:claude-deep': [{ score: 0.9 }], 'judge:codex-deep': ['{"score": 0.9}'] }
  // No change: every kind is fingerprinted before (in the materialize spawn,
  // BEFORE the materialize command) and after grading, and the grades stand.
  const ok = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1, rb, rv], script: base })
  const mt = ok.calls.find(c => c.label === 'materialize:rv')
  chk('P13: the before-fingerprint runs in the materialize spawn, BEFORE the materialize command, and the reply must carry it',
    mt && mt.prompt.indexOf(`parity-suite.sh fingerprint --task '${SUITE}/1/rv'`) >= 0 &&
    mt.prompt.indexOf(`parity-suite.sh fingerprint --task '${SUITE}/1/rv'`) < mt.prompt.indexOf('parity-suite.sh materialize --task') && mt.opts.schema.required.includes('fingerprint'))
  chk('P13: build, rubric AND review tasks are each re-fingerprinted once after grading (quick-task, schema)',
    ['t1', 'rb', 'rv'].every(id => ok.calls.filter(c => c.label === `source:after@${id}`).length === 1) &&
    ok.calls.filter(c => c.label.startsWith('source:')).every(c => c.opts.agentType === 'triage-quick-task' && c.opts.schema && c.prompt.includes('parity-suite.sh fingerprint --task')))
  const iJudge = ok.events.findIndex(e => e.startsWith('agent:judge:claude-deep@rb'))
  const iAfter = ok.events.indexOf('agent:source:after@rb')
  const iScore = ok.events.indexOf('agent:score:rv')
  chk('P13: the after-fingerprint comes after grading (after the judges, after the review score)',
    iJudge >= 0 && iAfter > iJudge && iScore >= 0 && ok.events.indexOf('agent:source:after@rv') > iScore)
  chk('P13: an unchanged source leaves every grade standing, no flag', ['t1', 'rb', 'rv'].every(id => cellOf(ok.result, id, 'a').status === 'pass') && !ok.result.flags.some(f => /SOURCE_/.test(f)))

  // HEAD moved on a build task; the tree changed on a review task: that task's
  // results are all invalid, flagged, and the run CONTINUES (t2 in band 2 still runs).
  const after = { t1: { head: 'e'.repeat(40) }, rv: { tree: 'f'.repeat(40) } }
  const ch = await run(A({ bands: [1, 2], candidates: [C('claude', 'builder', 'a'), C('codex', 'builder', 'x')] }), {
    tasks: [Object.assign({}, t1), Object.assign({}, rv, { vendors: ['claude', 'codex'] }), t2],
    script: Object.assign({}, base, {
      'source:': [p => FP(fpId(p), after[fpId(p)] || {})],
      'candidate:x@rv': ['CROSS-REVIEW (codex · read · exit 0)\n{"findings": []}'],
      'score:rv': [{ scores: [{ label: 'a', recall: 1, precision: 1 }, { label: 'x', recall: 1, precision: 1 }] }],
    }),
  })
  chk('P13: HEAD moved on a build task => every result of it invalid (never pass/fail)', ['a', 'x'].every(l => cellOf(ch.result, 't1', l).status === 'invalid' && /^SOURCE_CHANGED srcrepo: HEAD moved/.test(cellOf(ch.result, 't1', l).reason)))
  chk('P13: tree changed on a REVIEW task => every result invalid too', ['a', 'x'].every(l => cellOf(ch.result, 'rv', l).status === 'invalid' && /^SOURCE_CHANGED srcrepo: tree changed/.test(cellOf(ch.result, 'rv', l).reason)))
  chk('P13: each change is flagged SOURCE_CHANGED <repo name>: <what> and logged with ⚠',
    ch.result.flags.some(f => /^SOURCE_CHANGED srcrepo: HEAD moved \(task t1\)/.test(f)) && ch.result.flags.some(f => /^SOURCE_CHANGED srcrepo: tree changed \(task rv\)/.test(f)) &&
    ch.logs.some(l => /^⚠ SOURCE_CHANGED srcrepo: HEAD moved/.test(l)))
  chk('P13: the run continues — band 2 still runs, and invalid counts as other, never as a fail',
    ch.wf.some(w => w.args.outDir === `${OUT}/2/t2/cmp`) && cellOf(ch.result, 't2', 'a').status === 'pass' && rank(ch.result, 'a').perBand[1].fail === 0 && rank(ch.result, 'a').perBand[1].other === 2)
  const both = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'source:': [p => FP(fpId(p), { head: 'e'.repeat(40), tree: 'f'.repeat(40) })] } })
  chk('P13: HEAD moved AND tree changed are both named', both.result.flags.some(f => /^SOURCE_CHANGED srcrepo: HEAD moved, tree changed/.test(f)))

  // No usable after-fingerprint (twice) => SOURCE_UNVERIFIED, invalid.
  const dead = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'source:': [new Error('dead')] } })
  chk('P13: an after-fingerprint that fails twice => SOURCE_UNVERIFIED, results invalid, one retry',
    cellOf(dead.result, 't1', 'a').status === 'invalid' && dead.result.flags.some(f => /^SOURCE_UNVERIFIED srcrepo/.test(f)) && dead.calls.filter(c => c.label.startsWith('source:after@t1')).length === 2)
  const junk = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'source:': [{ source: 'generator' }] } })
  chk('P13: an after-reply that downgrades a git source to "generator" is not accepted (unverified, invalid)', cellOf(junk.result, 't1', 'a').status === 'invalid')

  // Generator sources carry nothing to guard: no after-fingerprint, grades stand.
  const gen = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), {
    tasks: [task('g1', 1, { source: { type: 'generator' } })],
    script: { 'materialize:': [p => ({ fingerprint: { id: 'g1', source: 'generator' }, repo: `${OUT}/1/g1/mat/repo`, sha: SHA, denied: { codex: false } })] },
  })
  chk('P13: a generator-source task is not re-fingerprinted and its grades stand', !gen.calls.some(c => c.label.startsWith('source:')) && cellOf(gen.result, 'g1', 'a').status === 'pass')
  // The before-fingerprint is mandatory: none, or one contradicting the task's
  // source type => materialize failed, nothing runs.
  const noFp = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'materialize:': [{ repo: `${OUT}/1/t1/mat/repo`, sha: SHA, denied: { codex: false } }] } })
  chk('P13: a materialize reply with no fingerprint => unavailable, no compare', noFp.wf.length === 0 && cellOf(noFp.result, 't1', 'a').status === 'unavailable')
  const lie = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), {
    tasks: [task('t1', 1, { source: { type: 'git', repo: '/src/real', base: 'abc' } })],
    script: { 'materialize:': [{ fingerprint: { source: 'generator' }, repo: `${OUT}/1/t1/mat/repo`, sha: SHA, denied: { codex: false } }] },
  })
  chk('P13: a before-fingerprint claiming "generator" for a git task => unavailable, no compare', lie.wf.length === 0 && cellOf(lie.result, 't1', 'a').status === 'unavailable')
}


// ---- P15: Wave 16B — ignored/refs in the source guard, unguarded generator tasks, modelFrom (M30, M7)
{
  const t1 = task('t1', 1)
  const ign = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'source:': [p => FP(fpId(p), { ignored: '1'.repeat(40) })] } })
  chk('P15: a changed gitignored file in the source (the cache-refresh class) voids the task: SOURCE_CHANGED ... ignored files changed',
    cellOf(ign.result, 't1', 'a').status === 'invalid' && ign.result.flags.some(f => /^SOURCE_CHANGED srcrepo: ignored files changed \(task t1\)/.test(f)))
  const refs = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks: [t1], script: { 'source:': [p => FP(fpId(p), { refs: '2'.repeat(40) })] } })
  chk('P15: a changed ref/stash/config/hook voids the task: SOURCE_CHANGED ... refs/config/hooks changed',
    cellOf(refs.result, 't1', 'a').status === 'invalid' && refs.result.flags.some(f => /^SOURCE_CHANGED srcrepo: refs\/config\/hooks changed/.test(f)))
  const noIgn = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), {
    tasks: [t1],
    script: { 'materialize:': [p => ({ fingerprint: FP('t1', { ignored: undefined }), repo: `${OUT}/1/t1/mat/repo`, sha: SHA, denied: { codex: false } })] },
  })
  chk('P15: a before-fingerprint without the ignored hash is not usable => unavailable, no compare', noIgn.wf.length === 0 && cellOf(noIgn.result, 't1', 'a').status === 'unavailable')
  const mix = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), {
    tasks: [t1, task('g1', 1, { source: { type: 'generator' } })],
    script: { 'materialize:': [p => {
      const id = (p.match(/--task '[^']*\/([^/']+)'/) || [])[1]
      const out = (p.match(/--out '([^']+)'/) || [])[1]
      return { fingerprint: id === 'g1' ? { id, source: 'generator', guarded: false } : FP(id), repo: `${out}/repo`, sha: SHA, denied: { codex: false } }
    }] },
  })
  const guardedOf = id => (mix.result.tasks.find(x => x.id === id) || {}).guarded
  chk('P15: tasks[] marks a git-source task guarded:true and a generator task guarded:false (unguarded, said so)', guardedOf('t1') === true && guardedOf('g1') === false)
  const mf = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a'), C('codex', 'builder', 'x'), C('codex', 'builder', 'y', { model: 'gpt-6-sol', effort: 'medium' })] }), { tasks: [t1] })
  chk('P15: each build row forwards modelFrom (M7): a runner-reported model is runner, a candidate model candidate, none null',
    cellOf(mf.result, 't1', 'x').modelFrom === 'runner' && cellOf(mf.result, 't1', 'x').model === 'gpt-6-sol' &&
    cellOf(mf.result, 't1', 'y').modelFrom === 'candidate' && cellOf(mf.result, 't1', 'a').modelFrom === null)
}
// ---- P14: selfCheckEnv reaches triage-compare only when the task opts in -------
{
  const tasks = [task('t1', 1, { checks: ['"$PARITY_PY" -m pytest'], selfCheckEnv: true }), task('t2', 1, { checks: ['"$PARITY_PY" -m pytest'] })]
  const { wf } = await run(A({ bands: [1], candidates: [C('claude', 'builder', 'a')] }), { tasks })
  const w1 = wf.find(w => w.args.outDir === `${OUT}/1/t1/cmp`)
  const w2 = wf.find(w => w.args.outDir === `${OUT}/1/t2/cmp`)
  chk('P14: an opted-in task passes selfCheckEnv:true; checks go through with $PARITY_ unexpanded', w1 && w1.args.selfCheckEnv === true && w1.args.checks[0] === '"$PARITY_PY" -m pytest')
  chk('P14: a task that did not opt in passes no selfCheckEnv', w2 && !('selfCheckEnv' in w2.args))
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
