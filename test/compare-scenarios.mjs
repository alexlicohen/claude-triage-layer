#!/usr/bin/env node
// Scenario tests for workflows/triage-compare.js — executes the ACTUAL workflow body
// under mocked DSL globals (agent/parallel/log/phase/budget), exactly as
// test/workflow-scenarios.mjs does for triage-exec.js, and asserts the control flow:
// validation before any spawn, strictly sequential candidates, the spawn options per
// vendor/level, unavailable != fail, and that the grade comes from patch-check alone.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, '..', 'workflows', 'triage-compare.js'), 'utf8')
  .replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let pass = 0
let fail = 0
function chk(name, cond) {
  if (cond) { pass++; console.log(`PASS: ${name}`) }
  else { fail++; console.log(`FAIL: ${name}`) }
}

// run(args, script, {spend}) — `script` maps a label prefix to a queue of responses
// (longest prefix wins; a queue repeats its last entry; an Error is thrown; a function
// is called with (prompt, opts)). Every spawn adds `spend[prefix] ?? 0` to the mocked
// budget.spent(), so per-candidate deltas are checkable. Each agent() yields to the
// event loop before resolving, so any concurrency would show up in maxInflight.
async function run(args, script = {}, { spend = {} } = {}) {
  const logs = []
  const calls = []
  const events = []
  let spent = 0
  let inflight = 0
  let maxInflight = 0
  const queues = new Map(Object.entries(script).map(([k, v]) => [k, [...v]]))
  const bestKey = (label, keys) => {
    let best
    for (const k of keys) if (label.startsWith(k) && (!best || k.length > best.length)) best = k
    return best
  }
  async function agent(prompt, opts = {}) {
    const label = opts.label || '(none)'
    calls.push({ label, prompt, opts })
    events.push(`agent:${label}`)
    inflight++
    maxInflight = Math.max(maxInflight, inflight)
    await new Promise(r => setTimeout(r, 2))
    inflight--
    const sk = bestKey(label, Object.keys(spend))
    if (sk !== undefined) spent += spend[sk]
    const key = bestKey(label, queues.keys())
    if (key === undefined) throw new Error(`unscripted agent call: label=${label}`)
    const q = queues.get(key)
    const val = q.length > 1 ? q.shift() : q[0]
    if (val instanceof Error) throw val
    return typeof val === 'function' ? val(prompt, opts) : val
  }
  const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
  const log = m => { logs.push(String(m)); events.push(`log:${m}`) }
  const phase = () => {}
  const budget = { total: null, remaining: () => Infinity, spent: () => spent }
  const fn = new AsyncFunction('args', 'log', 'phase', 'agent', 'parallel', 'budget', src)
  try {
    const result = await fn(args, log, phase, agent, parallel, budget)
    return { result, logs, calls, events, maxInflight }
  } catch (e) {
    if (e && typeof e === 'object') e.calls = calls
    throw e
  }
}
async function throws(args) {
  try { const { calls } = await run(args); return { threw: false, calls } }
  catch (e) { return { threw: true, message: String(e.message || e), calls: e.calls || [] } }
}

const BASE = {
  repo: '/r/repo', brief: 'Fix calc.', files: ['calc.txt'], acceptance: 'calc passes',
  checks: ['make test'], outDir: '/o/out',
}
const A = extra => Object.assign({}, BASE, extra)
// A patch-check grader reply built from {label: [applies, rc]}.
const PC = rows => ({ results: Object.entries(rows).map(([label, [applies, rc]]) => ({ patch: `/o/out/${label}.patch`, applies, rc, diffstat: applies ? '1 file changed, 1 insertion(+)' : '', tail: `tail-${label}` })) })
const byLabel = (result, l) => result.candidates.find(c => c.label === l) || {}
// patch: the candidate's OWN patch path — must match to be graded (defaults to a
// generic path for callers that don't assert availability).
const EXT_OK = (vendor, model, patch = '/o/out/x.patch', n = 1000, s = 12, out = 300) =>
  `EXTERNAL (${vendor} · build · exit 0)\nPATCH ${patch}\nDONE exit=0\nCHECK rc=0\nworker text\next-run: ${n} tokens (${s}s, ${vendor}/${model})${out == null ? '' : ` out=${out}`}`

// ---- C1: validation throws before ANY spawn ---------------------------------
{
  const cases = [
    ['non-object args', null],
    ['relative repo', A({ repo: 'repo', candidates: [{ vendor: 'claude', level: 'builder' }] })],
    ['relative outDir', A({ outDir: 'out', candidates: [{ vendor: 'claude', level: 'builder' }] })],
    ['outDir with a space', A({ outDir: '/o/my out', candidates: [{ vendor: 'claude', level: 'builder' }] })],
    ['no checks', A({ checks: [], candidates: [{ vendor: 'claude', level: 'builder' }] })],
    ['no candidates', A({ candidates: [] })],
    ['unknown vendor', A({ candidates: [{ vendor: 'gemini', level: 'builder' }] })],
    ['unknown level', A({ candidates: [{ vendor: 'claude', level: 'fable' }] })],
    ['agy off builder', A({ candidates: [{ vendor: 'agy', level: 'deep' }] })],
    ['bad effort', A({ candidates: [{ vendor: 'codex', level: 'deep', effort: 'ultra' }] })],
    ['model with a space', A({ candidates: [{ vendor: 'codex', level: 'deep', model: 'gpt 6' }] })],
    ['duplicate default labels', A({ candidates: [{ vendor: 'claude', level: 'deep' }, { vendor: 'claude', level: 'deep' }] })],
    ['duplicate explicit labels', A({ candidates: [{ vendor: 'claude', level: 'deep', label: 'x' }, { vendor: 'codex', level: 'deep', label: 'x' }] })],
    ['path-unsafe label', A({ candidates: [{ vendor: 'claude', level: 'deep', label: '../evil' }] })],
    ['non-HEAD base with an external candidate', A({ base: 'main~1', candidates: [{ vendor: 'codex', level: 'builder' }] })],
    ['relative overlay', A({ overlay: 'hidden', candidates: [{ vendor: 'claude', level: 'builder' }] })],
  ]
  for (const [name, args] of cases) {
    const r = await throws(args)
    chk(`C1: ${name} throws before any spawn`, r.threw && r.calls.length === 0 && /triage-compare:/.test(r.message))
  }
  const ok = await throws(A({ base: 'main~1', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C1: a non-HEAD base is fine for Claude-only bake-offs', ok.threw === false)
}

// ---- C2: strictly sequential, grade last, labels ------------------------------
{
  const { result, calls, maxInflight } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'builder' },
      { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' },
      { vendor: 'agy', level: 'builder' },
      { vendor: 'claude', level: 'deep', label: 'mine' },
    ] }),
    {
      'candidate:claude-builder': ['done\nCHECK rc=0\nPATCH /o/out/claude-builder.patch'],
      'candidate:codex-deep': [EXT_OK('codex', 'gpt-6-astra', '/o/out/codex-deep-gpt-6-astra-high.patch')],
      'candidate:agy-builder': [EXT_OK('agy', 'gemini-3.1-pro-high', '/o/out/agy-builder.patch', 500, 30, null)],
      'candidate:mine': ['done\nCHECK rc=0\nPATCH /o/out/mine.patch'],
      'grade:': [PC({ 'claude-builder': [true, 0], 'codex-deep-gpt-6-astra-high': [true, 0], 'agy-builder': [true, 1], mine: [false, null] })],
    })
  chk('C2: candidates spawn one at a time, in plan order, then ONE grade spawn',
    maxInflight === 1 && calls.map(c => c.label).join() === 'candidate:claude-builder,candidate:codex-deep-gpt-6-astra-high,candidate:agy-builder,candidate:mine,grade:patch-check')
  chk('C2: default labels are vendor-level[-model][-effort]; explicit labels are kept',
    result.candidates.map(c => c.label).join() === 'claude-builder,codex-deep-gpt-6-astra-high,agy-builder,mine')
  chk('C2: patches land at <outDir>/<label>.patch', byLabel(result, 'mine').patch === '/o/out/mine.patch')
  chk('C2: statuses come out pass/pass/fail/fail', result.candidates.map(c => c.status).join() === 'pass,pass,fail,fail')
  chk('C2: returns base (default HEAD) and graded:true', result.base === 'HEAD' && result.graded === true)
}

// ---- C3: Claude candidates — isolation, agentType per level, model/effort ----
{
  const { calls, events } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'quick' },
      { vendor: 'claude', level: 'builder', model: 'sonnet' },
      { vendor: 'claude', level: 'deep', effort: 'max' },
      { vendor: 'claude', level: 'top', model: 'fable', effort: 'xhigh' },
    ] }),
    { 'candidate:': ['done'], 'grade:': [PC({})] })
  const cand = calls.filter(c => c.label.startsWith('candidate:'))
  chk('C3: every Claude candidate runs with isolation:worktree', cand.length === 4 && cand.every(c => c.opts.isolation === 'worktree'))
  chk('C3: agentType follows the level map (quick/builder/deep/top)',
    cand.map(c => c.opts.agentType).join() === 'triage-quick-task,triage-builder,triage-deep-reasoner,triage-fable-architect')
  chk('C3: model/effort pass through only when given',
    !('model' in cand[0].opts) && !('effort' in cand[0].opts) && cand[1].opts.model === 'sonnet' && !('effort' in cand[1].opts) &&
    cand[2].opts.effort === 'max' && !('model' in cand[2].opts) && cand[3].opts.model === 'fable' && cand[3].opts.effort === 'xhigh')
  chk('C3: the Claude prompt carries brief, files, acceptance, the checks, and the patch-writing protocol',
    /Fix calc\./.test(cand[0].prompt) && /Relevant files: calc\.txt/.test(cand[0].prompt) && /Acceptance criteria: calc passes/.test(cand[0].prompt) &&
    /\n {2}make test\n/.test(cand[0].prompt) && cand[0].prompt.includes('git add -A && git diff --binary HEAD > /o/out/claude-quick.patch') &&
    cand[0].prompt.includes('PATCH /o/out/claude-quick.patch'))
  const iWarn = events.indexOf('log:⚠ Escalating to Fable: triage-compare candidate claude-top-fable-xhigh')
  const iTop = events.indexOf('agent:candidate:claude-top-fable-xhigh')
  chk('C3: a top-level Claude candidate logs the ⚠ Fable line BEFORE its spawn', iWarn >= 0 && iTop > iWarn)
  chk('C3: only the top candidate gets the Fable line', events.filter(e => e.startsWith('log:⚠ Escalating to Fable')).length === 1)

  const { calls: c2 } = await run(A({ base: 'v1.2', candidates: [{ vendor: 'claude', level: 'deep' }] }), { 'candidate:': ['done'], 'grade:': [PC({})] })
  chk('C3: a non-HEAD base makes the Claude candidate detach to it and diff against it',
    c2[0].prompt.includes('git checkout --detach v1.2') && c2[0].prompt.includes('git diff --binary v1.2 >'))
}

// ---- C4: external candidates — the exact header -----------------------------
{
  const { calls } = await run(
    A({ checks: ['make test', 'npm t'], candidates: [
      { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' },
      { vendor: 'agy', level: 'builder' },
      { vendor: 'codex', level: 'quick', label: 'luna' },
    ] }),
    { 'candidate:': [EXT_OK('codex', 'm')], 'grade:': [PC({})] })
  const first = c => c.prompt.split('\n')[0]
  chk('C4: codex header is exact (EFFORT, MODEL, WORKDIR, PATCH_OUT, CHECK last with checks joined by &&)',
    first(calls[0]) === 'VENDOR=codex LEVEL=deep EFFORT=high MODEL=gpt-6-astra WORKDIR=/r/repo PATCH_OUT=/o/out/codex-deep-gpt-6-astra-high.patch CHECK=make test && npm t')
  chk('C4: agy header omits EFFORT/MODEL when not given',
    first(calls[1]) === 'VENDOR=agy LEVEL=builder WORKDIR=/r/repo PATCH_OUT=/o/out/agy-builder.patch CHECK=make test && npm t')
  chk('C4: an explicit label names the external patch too', first(calls[2]).includes('PATCH_OUT=/o/out/luna.patch'))
  chk('C4: external candidates spawn triage-external with no isolation/model/effort of their own',
    calls.slice(0, 3).every(c => c.opts.agentType === 'triage-external' && !('isolation' in c.opts) && !('model' in c.opts) && !('effort' in c.opts)))
  chk('C4: the external brief states the data boundary is cleared and carries files + acceptance',
    calls[0].prompt.includes('The data boundary has been cleared by the orchestrator') && calls[0].prompt.includes('Relevant files: calc.txt') && calls[0].prompt.includes('Acceptance criteria: calc passes'))
}

// ---- C5: unavailable is never fail ------------------------------------------
{
  const { result, calls, logs } = await run(
    A({ candidates: [
      { vendor: 'codex', level: 'builder', label: 'u1' },
      { vendor: 'agy', level: 'builder', label: 'u2' },
      { vendor: 'claude', level: 'builder', label: 'u3' },
      { vendor: 'codex', level: 'deep', label: 'u4' },
      { vendor: 'claude', level: 'deep', label: 'ok' },
    ] }),
    {
      'candidate:u1': ['UNAVAILABLE: codex exited 1 — rate limited'],
      'candidate:u2': ['REFUSED: .agy-deny marker'],
      'candidate:u3': [null],
      'candidate:u4': [new Error('token ceiling reached')],
      'candidate:ok': ['done\nCHECK rc=0\nPATCH /o/out/ok.patch'],
      'grade:': [PC({ ok: [true, 0] })],
    })
  chk('C5: null / UNAVAILABLE / REFUSED / a thrown spawn are all status unavailable',
    ['u1', 'u2', 'u3', 'u4'].every(l => byLabel(result, l).status === 'unavailable'))
  chk('C5: an unavailable candidate has no patch, applies/rc null, and its reason in tail',
    byLabel(result, 'u1').patch === null && byLabel(result, 'u1').applies === null && byLabel(result, 'u1').rc === null &&
    /rate limited/.test(byLabel(result, 'u1').tail) && /REFUSED/.test(byLabel(result, 'u2').tail) && /ceiling/.test(byLabel(result, 'u4').tail))
  const grade = calls.find(c => c.label.startsWith('grade:'))
  chk('C5: only produced patches go to patch-check', grade && grade.prompt.includes('/o/out/ok.patch') && !/u[1-4]\.patch/.test(grade.prompt))
  chk('C5: the available candidate still passes', byLabel(result, 'ok').status === 'pass')
  chk('C5: unavailability is logged as not-a-fail', logs.some(l => /u1 unavailable .* not graded as a fail/.test(l)))
  chk('C5: the run continued past the thrown spawn (sequential, nothing lost)', calls.map(c => c.label).includes('candidate:ok'))

  const { calls: c2, result: r2 } = await run(A({ candidates: [{ vendor: 'codex', level: 'builder' }] }), { 'candidate:': [null] })
  chk('C5: every candidate unavailable → no grade spawn at all', !c2.some(c => c.label.startsWith('grade:')) && r2.candidates[0].status === 'unavailable')
}

// ---- C6: the grade is patch-check's, never the candidate's self-report -------
{
  const { result } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'builder', label: 'liar' },
      { vendor: 'codex', level: 'builder', label: 'modest' },
      { vendor: 'claude', level: 'deep', label: 'noapply' },
    ] }),
    {
      'candidate:liar': ['all green!\nCHECK rc=0\nPATCH /o/out/liar.patch'],
      'candidate:modest': ['EXTERNAL (codex · build · exit 0)\nPATCH /o/out/modest.patch\nDONE exit=1\nCHECK rc=1\next-run: 10 tokens (1s, codex/gpt-6-sol) out=4'],
      'candidate:noapply': ['done\nCHECK rc=0\nPATCH /o/out/noapply.patch'],
      'grade:': [PC({ liar: [true, 1], modest: [true, 0], noapply: [false, null] })],
    })
  chk('C6: self-reported rc 0 but patch-check rc 1 → fail', byLabel(result, 'liar').status === 'fail' && byLabel(result, 'liar').rc === 1)
  chk('C6: self-reported rc 1 but patch-check rc 0 → pass', byLabel(result, 'modest').status === 'pass' && byLabel(result, 'modest').rc === 0)
  chk('C6: a patch that does not apply at base → fail, whatever the candidate said', byLabel(result, 'noapply').status === 'fail' && byLabel(result, 'noapply').applies === false)
  chk('C6: the self-report is kept as selfRc (informational)', byLabel(result, 'liar').selfRc === 0 && byLabel(result, 'modest').selfRc === 1)
  chk('C6: diffstat and tail come from patch-check', byLabel(result, 'liar').diffstat === '1 file changed, 1 insertion(+)' && byLabel(result, 'liar').tail === 'tail-liar')
}

// ---- C7: never an apply step; the grade command is exact ---------------------
{
  const { result, calls } = await run(
    A({ checks: ["grep -q 'ok' calc.txt", 'make test'], overlay: '/h/hidden', candidates: [
      { vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'codex', level: 'builder', label: 'b' },
    ] }),
    { 'candidate:a': ['done\nPATCH /o/out/a.patch'], 'candidate:b': [EXT_OK('codex', 'gpt-6-sol', '/o/out/b.patch')], 'grade:': [PC({ a: [true, 0], b: [true, 0] })] })
  const grade = calls.filter(c => c.label.startsWith('grade:'))
  chk('C7: exactly one grade spawn, on triage-quick-task, with a results schema',
    grade.length === 1 && grade[0].opts.agentType === 'triage-quick-task' && grade[0].opts.schema && grade[0].opts.schema.required.includes('results'))
  chk('C7: the grade command is patch-check.sh with repo, base, the joined checks (quoted), the overlay and every patch',
    grade[0].prompt.includes("~/.claude/scripts/patch-check.sh --repo '/r/repo' --base 'HEAD' --check 'grep -q '\\''ok'\\'' calc.txt && make test' --overlay '/h/hidden' '/o/out/a.patch' '/o/out/b.patch'"))
  chk('C7: no spawn is ever asked to apply, am, stash or commit into the repo',
    calls.every(c => !/git (apply|am|stash|commit|merge|cherry-pick)\b/.test(c.prompt)))
  chk('C7: the Claude candidate is told never to apply to the repo', calls[0].prompt.includes(`Never apply, commit to, push, or check out anything in /r/repo itself`))
  chk('C7: the overlay path is never shown to a candidate', calls.filter(c => c.label.startsWith('candidate:')).every(c => !c.prompt.includes('/h/hidden')))
  chk('C7: the result has no applied/merged field — the orchestrator applies', !('applied' in result) && result.candidates.every(c => !('applied' in c)))
}

// ---- C8: tokens and seconds ---------------------------------------------------
{
  const { result } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'deep', label: 'c1' },
      { vendor: 'codex', level: 'builder', label: 'x1' },
      { vendor: 'agy', level: 'builder', label: 'g1' },
      { vendor: 'claude', level: 'builder', label: 'c2' },
    ] }),
    {
      'candidate:c1': ['done\nPATCH /o/out/c1.patch'], 'candidate:c2': ['done\nPATCH /o/out/c2.patch'],
      'candidate:x1': [EXT_OK('codex', 'gpt-6-sol', '/o/out/x1.patch', 5000, 42, 800)],
      'candidate:g1': [EXT_OK('agy', 'gemini-3.1-pro-high', '/o/out/g1.patch', 700, 9.5, null)],
      'grade:': [PC({ c1: [true, 0], x1: [true, 0], g1: [true, 0], c2: [true, 0] })],
    },
    { spend: { 'candidate:c1': 1234, 'candidate:x1': 50, 'candidate:g1': 60, 'candidate:c2': 777, 'grade:': 99 } })
  chk('C8: a Claude candidate outTokens is exactly its own budget.spent() delta', byLabel(result, 'c1').outTokens === 1234 && byLabel(result, 'c2').outTokens === 777)
  chk('C8: Claude candidates have no vendor total/seconds', byLabel(result, 'c1').totalTokens === null && byLabel(result, 'c1').seconds === null)
  chk('C8: an external candidate parses tokens/seconds/out/model from the ext-run line',
    byLabel(result, 'x1').totalTokens === 5000 && byLabel(result, 'x1').seconds === 42 && byLabel(result, 'x1').outTokens === 800 && byLabel(result, 'x1').model === 'gpt-6-sol')
  chk('C8: no out= on the line → outTokens null (never the wrapper spend)', byLabel(result, 'g1').outTokens === null && byLabel(result, 'g1').seconds === 9.5 && byLabel(result, 'g1').totalTokens === 700)
}

// ---- C9: a dead grader is ungraded, never pass or fail -----------------------
{
  const { result, calls, logs } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done\nCHECK rc=0\nPATCH /o/out/a.patch'], 'grade:': [null] })
  chk('C9: the grader is retried once', calls.filter(c => c.label.startsWith('grade:')).length === 2)
  chk('C9: two dead graders → status ungraded, graded:false, loud log',
    byLabel(result, 'a').status === 'ungraded' && result.graded === false && logs.some(l => l.includes('GRADING INCOMPLETE')))
  const { result: r2 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done\nPATCH /o/out/a.patch'], 'grade:patch-check#retry': [PC({ a: [true, 0] })], 'grade:patch-check': [null] })
  chk('C9: a retry that answers grades normally', byLabel(r2, 'a').status === 'pass' && r2.graded === true)
}

// ---- C10: outDir/overlay must be outside repo -------------------------------
{
  const sameDir = await throws(A({ outDir: '/r/repo', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C10: outDir === repo throws before any spawn', sameDir.threw && sameDir.calls.length === 0 && /outDir must not be inside args\.repo/.test(sameDir.message))

  const underDir = await throws(A({ outDir: '/r/repo/out', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C10: outDir under repo throws before any spawn', underDir.threw && underDir.calls.length === 0 && /outDir must not be inside args\.repo/.test(underDir.message))

  const underDirSlash = await throws(A({ outDir: '/r/repo/', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C10: outDir === repo with a trailing slash still throws', underDirSlash.threw && /outDir must not be inside args\.repo/.test(underDirSlash.message))

  const overlayUnder = await throws(A({ overlay: '/r/repo/hidden', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C10: overlay under repo throws before any spawn', overlayUnder.threw && overlayUnder.calls.length === 0 && /overlay must not be inside args\.repo/.test(overlayUnder.message))

  const sibling = await throws(A({ outDir: '/r/repo-out', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C10: a sibling path like repo+"-out" is allowed (prefix match, not substring)', sibling.threw === false)
}

// ---- C11: a Claude reply without a PATCH line is never graded ---------------
{
  const { result, calls } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'nopatch' }, { vendor: 'claude', level: 'deep', label: 'ok' }] }),
    { 'candidate:nopatch': ['all good, checks passed\nCHECK rc=0'], 'candidate:ok': ['done\nCHECK rc=0\nPATCH /o/out/ok.patch'], 'grade:': [PC({ ok: [true, 0] })] })
  chk('C11: a reply with no PATCH line is status unavailable', byLabel(result, 'nopatch').status === 'unavailable')
  chk('C11: its reason says so', byLabel(result, 'nopatch').tail === 'no PATCH line')
  chk('C11: it has no patch and is never sent to patch-check', byLabel(result, 'nopatch').patch === null)
  const grade = calls.find(c => c.label.startsWith('grade:'))
  chk('C11: the grader command excludes it entirely', grade && !grade.prompt.includes('nopatch') && grade.prompt.includes('/o/out/ok.patch'))
  chk('C11: the available candidate still grades normally', byLabel(result, 'ok').status === 'pass')
}

// ---- C12: claudePrompt() tells the candidate to clear stale patches first ----
{
  const { calls } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done\nPATCH /o/out/a.patch'], 'grade:': [PC({})] })
  chk('C12: the Claude protocol removes any stale patch before writing a fresh one',
    calls[0].prompt.includes('rm -f /o/out/a.patch\n  mkdir -p /o/out'))
}

// ---- C13: external candidates require args.files -----------------------------
{
  const noFiles = await throws(A({ files: undefined, candidates: [{ vendor: 'codex', level: 'builder' }] }))
  chk('C13: an external candidate without args.files throws before any spawn',
    noFiles.threw && noFiles.calls.length === 0 && /args\.files must be a non-empty array/.test(noFiles.message))

  const emptyFiles = await throws(A({ files: [], candidates: [{ vendor: 'agy', level: 'builder' }] }))
  chk('C13: an empty files array is treated the same as missing', emptyFiles.threw && /args\.files must be a non-empty array/.test(emptyFiles.message))

  const { result } = await run(
    A({ files: undefined, candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done\nPATCH /o/out/a.patch'], 'grade:': [PC({ a: [true, 0] })] })
  chk('C13: a claude-only run without args.files is still allowed', byLabel(result, 'a').status === 'pass')
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
