#!/usr/bin/env node
// Scenario tests for workflows/triage-compare.js — executes the ACTUAL workflow body
// under mocked DSL globals (agent/parallel/log/phase/budget), exactly as
// test/workflow-scenarios.mjs does for triage-exec.js, and asserts the control flow:
// validation before any spawn, ONE staging spawn first (one worktree per candidate),
// strictly sequential candidates each pointed at its OWN staged worktree and never at
// the real repo, the spawn options per vendor/level, unavailable != fail, the grade
// from the final quick-task result alone (worktree diff + patch-check + leakcheck), a
// leak voiding every grade, BASE_MOVED flagged, and cleanup on every path.
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

const SHA = 'a'.repeat(40)
const REPO = '/r/repo'
const STAGE = '/o/out/stage'

// The staging reply: exactly what stage-worktree.sh create prints for the prompt's
// --count and --dir.
const STAGED = (prompt, over = {}) => {
  const n = Number((prompt.match(/--count (\d+)/) || [])[1])
  const dir = (prompt.match(/--dir '([^']+)'/) || [])[1]
  return Object.assign({ sha: SHA, worktrees: Array.from({ length: n }, (_, i) => `${dir}/wt-${i + 1}`), fingerprint: `${dir}/fingerprint` }, over)
}
// The grade reply, built from the grade prompt itself: one diff line per
// `stage-worktree.sh diff` command (ok unless the label is in opts.badDiff), one
// patch-check line per {label: [applies, rc]}, and the leakcheck line.
const FIN = (rows, { leak = 'CLEAN', rc, badDiff = [], leakField, baseMoved } = {}) => prompt => {
  const diffs = [...prompt.matchAll(/diff --worktree '([^']+)' --base '[^']+' --out '([^']+)'/g)].map(m => {
    const label = m[2].replace(/^.*\//, '').replace(/\.patch$/, '')
    return badDiff.includes(label) ? { worktree: m[1], patch: m[2], ok: false, error: 'worktree does not exist' } : { worktree: m[1], patch: m[2], ok: true, shortstat: '' }
  })
  const results = Object.entries(rows).map(([label, [applies, rc2]]) => ({ patch: `/o/out/${label}.patch`, applies, rc: rc2, diffstat: applies ? '1 file changed, 1 insertion(+)' : '', tail: `tail-${label}` }))
  const leakcheck = { status: leak, leak: leakField != null ? leakField : leak === 'LEAK', baseMoved: baseMoved != null ? baseMoved : leak === 'BASE_MOVED', rc: rc != null ? rc : leak === 'LEAK' ? 7 : 0, detail: `${leak}: detail` }
  return { diffs, results, leakcheck }
}
const CLEANED = { ok: true, rc: 0 }

// run(args, script, {spend}) — `script` maps a label prefix to a queue of responses
// (longest prefix wins; a queue repeats its last entry; an Error is thrown; a function
// is called with (prompt, opts)). stage:/cleanup: default to a successful reply.
// Every spawn adds `spend[prefix] ?? 0` to the mocked budget.spent(), so
// per-candidate deltas are checkable. Each agent() yields to the event loop before
// resolving, so any concurrency would show up in maxInflight.
async function run(args, script = {}, { spend = {} } = {}) {
  const logs = []
  const calls = []
  const events = []
  let spent = 0
  let inflight = 0
  let maxInflight = 0
  const full = Object.assign({ 'stage:': [p => STAGED(p)], 'cleanup:': [CLEANED] }, script)
  const queues = new Map(Object.entries(full).map(([k, v]) => [k, [...v]]))
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
async function throws(args, script) {
  try { const { calls } = await run(args, script); return { threw: false, calls } }
  catch (e) { return { threw: true, message: String(e.message || e), calls: e.calls || [] } }
}

const BASE = {
  repo: REPO, brief: 'Fix calc.', files: ['calc.txt'], acceptance: 'calc passes',
  checks: ['make test'], outDir: '/o/out',
}
const A = extra => Object.assign({}, BASE, extra)
const byLabel = (result, l) => result.candidates.find(c => c.label === l) || {}
const cands = calls => calls.filter(c => c.label.startsWith('candidate:'))
const EXT_OK = (vendor, model, n = 1000, s = 12, out = 300) =>
  `EXTERNAL (${vendor} · build · exit 0)\nCHANGED FILES: calc.txt\nDONE exit=0\nworker text\next-run: ${n} tokens (${s}s, ${vendor}/${model})${out == null ? '' : ` out=${out}`}`
// The real repo as a working directory: a cd target or a WORKDIR value.
const repoAsWorkdir = p => /(^|\s)cd\s+'?\/r\/repo'?(\s|$|\/)/.test(p) || /WORKDIR='?\/r\/repo(\s|'|$|\/)/.test(p)

// ---- C1: validation throws before ANY spawn ---------------------------------
{
  const cases = [
    ['non-object args', null],
    ['relative repo', A({ repo: 'repo', candidates: [{ vendor: 'claude', level: 'builder' }] })],
    ['repo with a space', A({ repo: '/r/my repo', candidates: [{ vendor: 'claude', level: 'builder' }] })],
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
    ['relative overlay', A({ overlay: 'hidden', candidates: [{ vendor: 'claude', level: 'builder' }] })],
  ]
  for (const [name, args] of cases) {
    const r = await throws(args)
    chk(`C1: ${name} throws before any spawn`, r.threw && r.calls.length === 0 && /triage-compare:/.test(r.message))
  }
  const ok = await throws(A({ base: 'main~1', candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'grade:': [FIN({})] })
  chk('C1: a non-HEAD base is fine for Claude candidates', ok.threw === false)
  const okExt = await throws(A({ base: 'main~1', candidates: [{ vendor: 'codex', level: 'builder' }] }), { 'candidate:': [EXT_OK('codex', 'm')], 'grade:': [FIN({})] })
  chk('C1: a non-HEAD base is fine for external candidates too (every candidate starts from the staged sha)', okExt.threw === false)
}

// ---- C2: stage first, then strictly sequential candidates, ONE grade, cleanup --
{
  const { result, calls, maxInflight } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'builder' },
      { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' },
      { vendor: 'agy', level: 'builder' },
      { vendor: 'claude', level: 'deep', label: 'mine' },
    ] }),
    {
      'candidate:claude-builder': ['done\nCHECK rc=0\nDONE'],
      'candidate:codex-deep': [EXT_OK('codex', 'gpt-6-astra')],
      'candidate:agy-builder': [EXT_OK('agy', 'gemini-3.1-pro-high', 500, 30, null)],
      'candidate:mine': ['done\nCHECK rc=0\nDONE'],
      'grade:': [FIN({ 'claude-builder': [true, 0], 'codex-deep-gpt-6-astra-high': [true, 0], 'agy-builder': [true, 1], mine: [false, null] })],
    })
  chk('C2: stage spawn first, candidates one at a time in plan order, ONE grade spawn, then cleanup',
    maxInflight === 1 && calls.map(c => c.label).join() === 'stage:create,candidate:claude-builder,candidate:codex-deep-gpt-6-astra-high,candidate:agy-builder,candidate:mine,grade:finalize,cleanup:stage')
  chk('C2: the stage spawn is ONE triage-quick-task running stage-worktree.sh create with --count = the number of candidates, the repo, base and <outDir>/stage',
    calls[0].opts.agentType === 'triage-quick-task' && calls[0].opts.schema && calls[0].opts.schema.required.includes('worktrees') &&
    calls[0].prompt.includes(`~/.claude/scripts/stage-worktree.sh create --repo '${REPO}' --base 'HEAD' --count 4 --dir '${STAGE}'`))
  chk('C2: default labels are vendor-level[-model][-effort]; explicit labels are kept',
    result.candidates.map(c => c.label).join() === 'claude-builder,codex-deep-gpt-6-astra-high,agy-builder,mine')
  chk('C2: patches land at <outDir>/<label>.patch', byLabel(result, 'mine').patch === '/o/out/mine.patch')
  chk('C2: statuses come out pass/pass/fail/fail', result.candidates.map(c => c.status).join() === 'pass,pass,fail,fail')
  chk('C2: returns base (default HEAD), the staged sha, leak:false, baseMoved:false and graded:true',
    result.base === 'HEAD' && result.sha === SHA && result.leak === false && result.baseMoved === false && result.graded === true)
}

// ---- C3: Claude candidates — own worktree, agentType per level, model/effort ----
{
  const { calls, events } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'quick' },
      { vendor: 'claude', level: 'builder', model: 'sonnet' },
      { vendor: 'claude', level: 'deep', effort: 'max' },
      { vendor: 'claude', level: 'top', model: 'fable', effort: 'xhigh' },
    ] }),
    { 'candidate:': ['done'], 'grade:': [FIN({})] })
  const cand = cands(calls)
  chk('C3: no spawn uses isolation:worktree (it bases on the default branch, not the staged sha)', calls.every(c => !('isolation' in c.opts)))
  chk('C3: agentType follows the level map (quick/builder/deep/top)',
    cand.map(c => c.opts.agentType).join() === 'triage-quick-task,triage-builder,triage-deep-reasoner,triage-fable-architect')
  chk('C3: model/effort pass through only when given',
    !('model' in cand[0].opts) && !('effort' in cand[0].opts) && cand[1].opts.model === 'sonnet' && !('effort' in cand[1].opts) &&
    cand[2].opts.effort === 'max' && !('model' in cand[2].opts) && cand[3].opts.model === 'fable' && cand[3].opts.effort === 'xhigh')
  chk('C3: candidate i must prefix EVERY shell command with `cd <its own worktree> && ` (cwd resets between Bash calls), with the first check as the example',
    cand.every((c, i) => c.prompt.includes(`EVERY shell command you run MUST start with \`cd ${STAGE}/wt-${i + 1} && \``) &&
      c.prompt.includes(`\`cd ${STAGE}/wt-${i + 1} && make test\``)) &&
    cand.every((c, i) => cand.every((o, j) => i === j || !c.prompt.includes(`${STAGE}/wt-${j + 1}`))))
  chk('C3: no bare `cd <dir>` instruction — every cd in the prompt is chained with && (a lone cd does not persist)',
    cand.every(c => /`cd \//.test(c.prompt) && [...c.prompt.matchAll(/(^|[\s`])cd\s+(\/\S*)/g)].every(m => c.prompt.slice(m.index + m[0].length).startsWith(' && '))))
  chk('C3: file edits use absolute paths under the worktree; the real repo is named once, only as off-limits (never a path to edit)',
    cand.every((c, i) => c.prompt.includes(`Every file edit uses an absolute path under ${STAGE}/wt-${i + 1}/.`) &&
      c.prompt.split(REPO).length === 2 && c.prompt.includes(`The repository at ${REPO} is NOT your workspace: never use a path under it`)))
  chk('C3: the Claude prompt carries brief, files, acceptance, the checks, the sha, and the CHECK rc / DONE ending',
    /Fix calc\./.test(cand[0].prompt) && /Relevant files: calc\.txt/.test(cand[0].prompt) && /Acceptance criteria: calc passes/.test(cand[0].prompt) &&
    /\n {2}make test\n/.test(cand[0].prompt) && cand[0].prompt.includes(`detached at ${SHA}`) && cand[0].prompt.includes('`CHECK rc=') && cand[0].prompt.includes('`DONE`'))
  chk('C3: the Claude prompt no longer asks for a patch file or a PATCH line', cand.every(c => !/git diff|PATCH \/|\.patch/.test(c.prompt)))
  chk('C3: the real repo appears only as off-limits — never as a cd target', cand.every(c => !repoAsWorkdir(c.prompt) && c.prompt.includes(`The repository at ${REPO} is NOT your workspace`)))
  const iWarn = events.indexOf('log:⚠ Escalating to Fable: triage-compare candidate claude-top-fable-xhigh')
  const iTop = events.indexOf('agent:candidate:claude-top-fable-xhigh')
  chk('C3: a top-level Claude candidate logs the ⚠ Fable line BEFORE its spawn', iWarn >= 0 && iTop > iWarn)
  chk('C3: only the top candidate gets the Fable line', events.filter(e => e.startsWith('log:⚠ Escalating to Fable')).length === 1)

  const { calls: c2 } = await run(A({ base: 'v1.2', candidates: [{ vendor: 'claude', level: 'deep' }] }), { 'candidate:': ['done'], 'grade:': [FIN({})] })
  chk('C3: a non-HEAD base goes to staging (resolved once), never to a candidate checkout',
    c2[0].prompt.includes("--base 'v1.2'") && !/git checkout/.test(cands(c2)[0].prompt) && cands(c2)[0].prompt.includes(`detached at ${SHA}`))
}

// ---- C4: external candidates — the exact header, WORKDIR = own staged worktree --
{
  const { calls } = await run(
    A({ checks: ['make test', 'npm t'], candidates: [
      { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' },
      { vendor: 'agy', level: 'builder' },
      { vendor: 'codex', level: 'quick', label: 'luna' },
    ] }),
    { 'candidate:': [EXT_OK('codex', 'm')], 'grade:': [FIN({})] })
  const cand = cands(calls)
  const first = c => c.prompt.split('\n')[0]
  chk('C4: codex header is exact (EFFORT, MODEL, then WORKDIR = its own staged worktree, last)',
    first(cand[0]) === `VENDOR=codex LEVEL=deep EFFORT=high MODEL=gpt-6-astra WORKDIR=${STAGE}/wt-1`)
  chk('C4: agy header omits EFFORT/MODEL when not given', first(cand[1]) === `VENDOR=agy LEVEL=builder WORKDIR=${STAGE}/wt-2`)
  chk('C4: an explicit label changes nothing about the workdir', first(cand[2]) === `VENDOR=codex LEVEL=quick WORKDIR=${STAGE}/wt-3`)
  chk('C4: no PATCH_OUT/CHECK in the header — the grade never depends on the wrapper carrying a flag',
    cand.every(c => !/PATCH_OUT=|CHECK=/.test(first(c))))
  chk('C4: the real repo path appears NOWHERE in an external prompt', cand.every(c => !c.prompt.includes(REPO)))
  chk('C4: external candidates spawn triage-external with no isolation/model/effort of their own',
    cand.every(c => c.opts.agentType === 'triage-external' && !('isolation' in c.opts) && !('model' in c.opts) && !('effort' in c.opts)))
  chk('C4: the external brief states the data boundary is cleared and carries files, acceptance and the joined check command',
    cand[0].prompt.includes('The data boundary has been cleared by the orchestrator') && cand[0].prompt.includes('Relevant files: calc.txt') &&
    cand[0].prompt.includes('Acceptance criteria: calc passes') && cand[0].prompt.includes('Check command (run from the workdir root): make test && npm t'))
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
      'candidate:ok': ['done\nCHECK rc=0'],
      'grade:': [FIN({ ok: [true, 0] })],
    })
  chk('C5: null / UNAVAILABLE / REFUSED / a thrown spawn are all status unavailable',
    ['u1', 'u2', 'u3', 'u4'].every(l => byLabel(result, l).status === 'unavailable'))
  chk('C5: an unavailable candidate has no patch, applies/rc null, and its reason in tail',
    byLabel(result, 'u1').patch === null && byLabel(result, 'u1').applies === null && byLabel(result, 'u1').rc === null &&
    /rate limited/.test(byLabel(result, 'u1').tail) && /REFUSED/.test(byLabel(result, 'u2').tail) && /ceiling/.test(byLabel(result, 'u4').tail))
  const grade = calls.find(c => c.label.startsWith('grade:'))
  chk('C5: only available candidates are diffed and sent to patch-check', grade && grade.prompt.includes(`--worktree '${STAGE}/wt-5'`) &&
    !/wt-[1-4]'/.test(grade.prompt) && grade.prompt.includes("'/o/out/ok.patch'") && !/u[1-4]\.patch/.test(grade.prompt))
  chk('C5: the available candidate still passes', byLabel(result, 'ok').status === 'pass')
  chk('C5: unavailability is logged as not-a-fail', logs.some(l => /u1 unavailable .* not graded as a fail/.test(l)))
  chk('C5: the run continued past the thrown spawn (sequential, nothing lost)', calls.map(c => c.label).includes('candidate:ok'))

  const { calls: c2, result: r2 } = await run(A({ candidates: [{ vendor: 'codex', level: 'builder' }] }), { 'candidate:': [null], 'grade:': [FIN({})] })
  const g2 = c2.find(c => c.label.startsWith('grade:'))
  chk('C5: every candidate unavailable → the grade spawn still runs the leakcheck, with no diff and no patch-check',
    g2 && g2.prompt.includes('stage-worktree.sh leakcheck') && !g2.prompt.includes('patch-check.sh') && !g2.prompt.includes(' diff --worktree') && r2.candidates[0].status === 'unavailable')
  chk('C5: …and cleanup still runs', c2.some(c => c.label === 'cleanup:stage'))
}

// ---- C6: the grade is the final quick-task result, never the self-report -----
{
  const { result } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'builder', label: 'liar' },
      { vendor: 'codex', level: 'builder', label: 'modest' },
      { vendor: 'claude', level: 'deep', label: 'noapply' },
    ] }),
    {
      'candidate:liar': ['all green!\nCHECK rc=0\nDONE'],
      'candidate:modest': ['EXTERNAL (codex · build · exit 0)\nCHANGED FILES: calc.txt\nDONE exit=1\next-run: 10 tokens (1s, codex/gpt-6-sol) out=4'],
      'candidate:noapply': ['done\nCHECK rc=0\nDONE'],
      'grade:': [FIN({ liar: [true, 1], modest: [true, 0], noapply: [false, null] })],
    })
  chk('C6: self-reported rc 0 but patch-check rc 1 → fail', byLabel(result, 'liar').status === 'fail' && byLabel(result, 'liar').rc === 1)
  chk('C6: self-reported rc 1 but patch-check rc 0 → pass', byLabel(result, 'modest').status === 'pass' && byLabel(result, 'modest').rc === 0)
  chk('C6: a diff that does not apply at the sha → fail, whatever the candidate said', byLabel(result, 'noapply').status === 'fail' && byLabel(result, 'noapply').applies === false)
  chk('C6: the self-report is kept as selfRc (CHECK rc=, else DONE exit=), informational', byLabel(result, 'liar').selfRc === 0 && byLabel(result, 'modest').selfRc === 1)
  chk('C6: diffstat and tail come from patch-check', byLabel(result, 'liar').diffstat === '1 file changed, 1 insertion(+)' && byLabel(result, 'liar').tail === 'tail-liar')
}

// ---- C7: never an apply step; the grade command is exact ---------------------
{
  const { result, calls } = await run(
    A({ checks: ["grep -q 'ok' calc.txt", 'make test'], overlay: '/h/hidden', candidates: [
      { vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'codex', level: 'builder', label: 'b' },
    ] }),
    { 'candidate:a': ['done'], 'candidate:b': [EXT_OK('codex', 'gpt-6-sol')], 'grade:': [FIN({ a: [true, 0], b: [true, 0] })] })
  const grade = calls.filter(c => c.label.startsWith('grade:'))
  chk('C7: exactly one grade spawn, on triage-quick-task, with a diffs/results/leakcheck schema',
    grade.length === 1 && grade[0].opts.agentType === 'triage-quick-task' && ['diffs', 'results', 'leakcheck'].every(k => grade[0].opts.schema.required.includes(k)))
  const S = '~/.claude/scripts/stage-worktree.sh'
  const lines = grade[0].prompt.split('\n')
  const iA = lines.indexOf(`${S} diff --worktree '${STAGE}/wt-1' --base '${SHA}' --out '/o/out/a.patch'`)
  const iB = lines.indexOf(`${S} diff --worktree '${STAGE}/wt-2' --base '${SHA}' --out '/o/out/b.patch'`)
  const iPC = lines.indexOf(`~/.claude/scripts/patch-check.sh --repo '${REPO}' --base '${SHA}' --check 'grep -q '\\''ok'\\'' calc.txt && make test' --overlay '/h/hidden' '/o/out/a.patch' '/o/out/b.patch'`)
  const iLC = lines.indexOf(`${S} leakcheck --repo '${REPO}' --dir '${STAGE}'`)
  chk('C7: in order — a diff of each candidate worktree at the sha, patch-check at the SHA (never HEAD) with the quoted checks, overlay and every patch, then leakcheck',
    iA >= 0 && iB > iA && iPC > iB && iLC > iPC)
  chk('C7: the grade spawn never runs cleanup (it stays idempotent and retryable)', !grade[0].prompt.includes(' cleanup '))
  chk('C7: no spawn is ever asked to apply, am, stash or commit into the repo',
    calls.every(c => !/git (apply|am|stash|commit|merge|cherry-pick)\b/.test(c.prompt)))
  chk('C7: the overlay path is never shown to a candidate', cands(calls).every(c => !c.prompt.includes('/h/hidden')))
  chk('C7: the result has no applied/merged field — the orchestrator applies', !('applied' in result) && result.candidates.every(c => !('applied' in c)))
  const cl = calls.find(c => c.label === 'cleanup:stage')
  chk('C7: cleanup runs last, on the stage dir of the same repo', cl && cl.prompt.includes(`${S} cleanup --repo '${REPO}' --dir '${STAGE}'`) && calls[calls.length - 1] === cl)
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
      'candidate:c1': ['done'], 'candidate:c2': ['done'],
      'candidate:x1': [EXT_OK('codex', 'gpt-6-sol', 5000, 42, 800)],
      'candidate:g1': [EXT_OK('agy', 'gemini-3.1-pro-high', 700, 9.5, null)],
      'grade:': [FIN({ c1: [true, 0], x1: [true, 0], g1: [true, 0], c2: [true, 0] })],
    },
    { spend: { 'stage:': 55, 'candidate:c1': 1234, 'candidate:x1': 50, 'candidate:g1': 60, 'candidate:c2': 777, 'grade:': 99, 'cleanup:': 11 } })
  chk('C8: a Claude candidate outTokens is exactly its own budget.spent() delta (stage/grade/cleanup excluded)', byLabel(result, 'c1').outTokens === 1234 && byLabel(result, 'c2').outTokens === 777)
  chk('C8: Claude candidates have no vendor total/seconds', byLabel(result, 'c1').totalTokens === null && byLabel(result, 'c1').seconds === null)
  chk('C8: an external candidate parses tokens/seconds/out/model from the ext-run line',
    byLabel(result, 'x1').totalTokens === 5000 && byLabel(result, 'x1').seconds === 42 && byLabel(result, 'x1').outTokens === 800 && byLabel(result, 'x1').model === 'gpt-6-sol')
  chk('C8: no out= on the line → outTokens null (never the wrapper spend)', byLabel(result, 'g1').outTokens === null && byLabel(result, 'g1').seconds === 9.5 && byLabel(result, 'g1').totalTokens === 700)
}

// ---- C9: a dead grader is ungraded, never pass or fail; leak unknown ----------
{
  const { result, calls, logs } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done\nCHECK rc=0'], 'grade:': [null] })
  chk('C9: the grader is retried once', calls.filter(c => c.label.startsWith('grade:')).length === 2 && calls.some(c => c.label === 'grade:finalize#retry'))
  chk('C9: two dead graders → status ungraded, graded:false, loud log',
    byLabel(result, 'a').status === 'ungraded' && result.graded === false && logs.some(l => l.includes('GRADING INCOMPLETE')))
  chk('C9: …and the leak state is UNKNOWN (null), loudly — never assumed clean',
    result.leak === null && logs.some(l => l.startsWith('⚠ LEAK CHECK INCOMPLETE')))
  chk('C9: cleanup still runs after a dead grader', calls[calls.length - 1].label === 'cleanup:stage')
  const { result: r2 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:a': ['done'], 'grade:finalize#retry': [FIN({ a: [true, 0] })], 'grade:finalize': [null] })
  chk('C9: a retry that answers grades normally', byLabel(r2, 'a').status === 'pass' && r2.graded === true && r2.leak === false)
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
  const sibling = await throws(A({ outDir: '/r/repo-out', candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'candidate:': ['done'], 'grade:': [FIN({})] })
  chk('C10: a sibling path like repo+"-out" is allowed (prefix match, not substring)', sibling.threw === false)
}

// ---- C11: a reply that says nothing about a patch — and an EMPTY diff — is graded
{
  const { result, calls } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'quiet' }, { vendor: 'claude', level: 'deep', label: 'nochange' }] }),
    { 'candidate:quiet': ['all good'], 'candidate:nochange': ['nothing to do'], 'grade:': [FIN({ quiet: [true, 0], nochange: [true, 1] })] })
  const grade = calls.find(c => c.label.startsWith('grade:'))
  chk('C11: a reply with no PATCH/CHECK line is still diffed and graded', byLabel(result, 'quiet').status === 'pass' && byLabel(result, 'quiet').patch === '/o/out/quiet.patch')
  chk('C11: an empty worktree diff goes through patch-check like any other (checks decide: here fail)',
    grade.prompt.includes("'/o/out/nochange.patch'") && byLabel(result, 'nochange').status === 'fail' && byLabel(result, 'nochange').rc === 1)
  const { result: r2 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'claude', level: 'deep', label: 'b' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({ b: [true, 0] }, { badDiff: ['a'] })] })
  chk('C11: a failed worktree diff is ungraded (never pass/fail), the others still grade',
    byLabel(r2, 'a').status === 'ungraded' && /worktree diff failed/.test(byLabel(r2, 'a').tail) && byLabel(r2, 'a').patch === null && byLabel(r2, 'b').status === 'pass' && r2.graded === false)
}

// ---- C12: a LEAK voids every grade, loudly --------------------------------------
{
  const { result, logs, events } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'codex', level: 'builder', label: 'b' }, { vendor: 'codex', level: 'deep', label: 'u' }] }),
    { 'candidate:a': ['done'], 'candidate:b': [EXT_OK('codex', 'm')], 'candidate:u': ['UNAVAILABLE: x'], 'grade:': [FIN({ a: [true, 0], b: [true, 0] }, { leak: 'LEAK' })] })
  chk('C12: leak → result.leak true and EVERY candidate (unavailable included) is invalid',
    result.leak === true && result.candidates.length === 3 && result.candidates.every(c => c.status === 'invalid'))
  chk('C12: the ⚠ LEAK line is logged', logs.some(l => l.startsWith('⚠ LEAK: the real repo changed during triage-compare — inspect before anything else')))
  chk('C12: the invalid tail names the leak', /LEAK/.test(byLabel(result, 'a').tail))
  chk('C12: cleanup still runs after a leak', events[events.length - 1] === 'agent:cleanup:stage' || events.includes('agent:cleanup:stage'))
  const { result: r2 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({ a: [true, 0] }, { leak: 'CLEAN', rc: 7, leakField: false })] })
  chk('C12: exit 7 alone is a leak, whatever the relayed status says', r2.leak === true && byLabel(r2, 'a').status === 'invalid')
  const { result: r3, logs: l3 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({ a: [true, 0] }, { leak: 'ERROR', rc: 2, leakField: false })] })
  chk('C12: a leakcheck that errored is UNKNOWN (leak null, loud), not clean', r3.leak === null && l3.some(l => l.startsWith('⚠ LEAK CHECK INCOMPLETE')) && byLabel(r3, 'a').status === 'pass')
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
    { 'candidate:a': ['done'], 'grade:': [FIN({ a: [true, 0] })] })
  chk('C13: a claude-only run without args.files is still allowed', byLabel(result, 'a').status === 'pass')
}

// ---- C14: BASE_MOVED is flagged, grading proceeds at the recorded sha -----------
{
  const { result, logs, calls } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({ a: [true, 0] }, { leak: 'BASE_MOVED' })] })
  chk('C14: BASE_MOVED → baseMoved:true, leak:false, the candidate still graded', result.baseMoved === true && result.leak === false && byLabel(result, 'a').status === 'pass')
  chk('C14: the ⚠ BASE_MOVED line names the sha grading stayed at', logs.some(l => l.startsWith('⚠ BASE_MOVED') && l.includes(SHA)))
  chk('C14: patch-check ran at the recorded sha, not at a moving HEAD', calls.find(c => c.label.startsWith('grade:')).prompt.includes(`--base '${SHA}'`) &&
    !/patch-check\.sh[^\n]*--base 'HEAD'/.test(calls.find(c => c.label.startsWith('grade:')).prompt))
}

// ---- C15: staging must succeed exactly as computed, or nothing runs -------------
{
  const intoRepo = await throws(A({ candidates: [{ vendor: 'codex', level: 'builder' }] }), { 'stage:': [p => STAGED(p, { worktrees: [REPO] })] })
  chk('C15: a staging reply naming the real repo as a worktree aborts before any candidate', intoRepo.threw && /staging failed/.test(intoRepo.message) && cands(intoRepo.calls).length === 0)
  const short = await throws(A({ candidates: [{ vendor: 'claude', level: 'builder' }, { vendor: 'claude', level: 'deep' }] }), { 'stage:': [p => STAGED(p, { worktrees: [`${STAGE}/wt-1`] })] })
  chk('C15: fewer worktrees than candidates aborts', short.threw && cands(short.calls).length === 0)
  const badSha = await throws(A({ candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'stage:': [p => STAGED(p, { sha: 'HEAD' })] })
  chk('C15: a non-sha base in the staging reply aborts (HEAD is not a stable base)', badSha.threw && cands(badSha.calls).length === 0)
  const dead = await throws(A({ candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'stage:': [new Error('boom')] })
  chk('C15: a dead staging spawn aborts, names the cleanup command, and spawns nothing else',
    dead.threw && /stage-worktree\.sh cleanup/.test(dead.message) && dead.calls.length === 1)
}

// ---- C16: across every spawn, the real repo is never a working directory --------
{
  const { calls } = await run(
    A({ candidates: [
      { vendor: 'claude', level: 'quick' }, { vendor: 'codex', level: 'builder' }, { vendor: 'agy', level: 'builder' }, { vendor: 'claude', level: 'top' },
    ] }),
    { 'candidate:': [EXT_OK('codex', 'm')], 'grade:': [FIN({})] })
  chk('C16: no candidate prompt names the real repo as a cd target or WORKDIR', cands(calls).every(c => !repoAsWorkdir(c.prompt)))
  const wds = cands(calls).map(c => { const m = c.prompt.match(/WORKDIR=(\S+)|`cd (\S+) && /); return m ? m[1] || m[2] : undefined })
  chk('C16: every Claude candidate prompt carries the per-command `cd <worktree> && ` prefix; none names the repo as an edit path',
    cands(calls).filter(c => !/^VENDOR=/.test(c.prompt)).every(c => /`cd \/o\/out\/stage\/wt-\d+ && /.test(c.prompt) && !c.prompt.includes(`${REPO}/`)))
  chk('C16: each candidate gets a distinct workdir under <outDir>/stage', wds.every(w => w && w.startsWith(`${STAGE}/wt-`)) && new Set(wds).size === 4)
  const { calls: c2 } = await run(A({ candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'candidate:': ['done'], 'grade:': [FIN({})], 'cleanup:': [{ ok: false, rc: 1 }] })
  chk('C16: a failed cleanup is loud (the manual command is logged), never fatal', c2.length === 4)
}
{
  const { logs } = await run(A({ candidates: [{ vendor: 'claude', level: 'builder' }] }), { 'candidate:': ['done'], 'grade:': [FIN({})], 'cleanup:': [{ ok: false, rc: 1 }] })
  chk('C16: …the ⚠ names the stage dir and the cleanup command', logs.some(l => l.startsWith(`⚠ Staged worktrees may remain under ${STAGE}`) && l.includes('stage-worktree.sh cleanup')))
}

// ---- C17: parallel:true — concurrent candidates, same grade, no budget deltas --
{
  const { result, calls, maxInflight } = await run(
    A({ parallel: true, candidates: [
      { vendor: 'claude', level: 'builder', label: 'c1' },
      { vendor: 'codex', level: 'deep', label: 'x1' },
      { vendor: 'claude', level: 'deep', label: 'c2' },
    ] }),
    {
      'candidate:c1': ['done\nCHECK rc=0\nDONE'],
      'candidate:x1': [EXT_OK('codex', 'gpt-6-astra', 900, 7, 321)],
      'candidate:c2': [new Error('budget ceiling')],
      'grade:': [FIN({ c1: [true, 0], x1: [true, 1] })],
    },
    { spend: { 'candidate:c1': 1234, 'candidate:x1': 50, 'candidate:c2': 777 } })
  const labels = calls.map(c => c.label)
  chk('C17: parallel:true runs the candidates concurrently (all three in flight at once)', maxInflight === 3)
  chk('C17: …still ONE stage spawn before them and ONE grade spawn after all of them, then cleanup',
    labels[0] === 'stage:create' && labels.slice(1, 4).sort().join() === 'candidate:c1,candidate:c2,candidate:x1' && labels.slice(4).join() === 'grade:finalize,cleanup:stage')
  chk('C17: results keep plan order and grades come from patch-check (pass / fail / unavailable)',
    result.candidates.map(c => `${c.label}:${c.status}`).join() === 'c1:pass,x1:fail,c2:unavailable')
  chk('C17: a Claude candidate\'s outTokens is null in parallel mode (budget deltas cannot be attributed)', byLabel(result, 'c1').outTokens === null)
  chk('C17: an external candidate keeps the vendor\'s own out/total/seconds from its ext-run line',
    byLabel(result, 'x1').outTokens === 321 && byLabel(result, 'x1').totalTokens === 900 && byLabel(result, 'x1').seconds === 7)
  chk('C17: each candidate still gets its own staged worktree', new Set(cands(calls).map(c => (c.prompt.match(/wt-\d+/) || [])[0])).size === 3)
}
{
  const r = await throws(A({ parallel: 'yes', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C17: a non-boolean parallel throws before any spawn', r.threw && r.calls.length === 0 && /args\.parallel/.test(r.message))
  const { maxInflight, result } = await run(A({ parallel: false, candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'claude', level: 'deep', label: 'b' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({ a: [true, 0], b: [true, 0] })] }, { spend: { 'candidate:a': 10, 'candidate:b': 20 } })
  chk('C17: parallel:false (and the default) stays strictly sequential with per-candidate budget deltas',
    maxInflight === 1 && byLabel(result, 'a').outTokens === 10 && byLabel(result, 'b').outTokens === 20)
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
