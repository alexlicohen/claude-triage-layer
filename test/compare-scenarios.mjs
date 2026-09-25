#!/usr/bin/env node
// Scenario tests for workflows/triage-compare.js — executes the ACTUAL workflow body
// under mocked DSL globals (agent/parallel/log/phase/budget), exactly as
// test/workflow-scenarios.mjs does for triage-exec.js, and asserts the control flow:
// validation before any spawn, ONE staging spawn first (one worktree per candidate),
// strictly sequential candidates each pointed at its OWN staged worktree and never at
// the real repo, the spawn options per vendor/level, unavailable != fail, the grade
// from the final quick-task result alone (worktree diff + patch-check + leakcheck), a
// leak voiding every grade, BASE_MOVED flagged, cleanup on every path, the
// work-only-inside line, and $PARITY_ checks shown unexpanded (.parity-env only
// with selfCheckEnv). kind:'review' (RV*): validation before any spawn, the
// snapshot first, reviewers in parallel on the snapshot + range diff only (never
// the live repo), a blind merge, blind adjudicators (no labels, no provenance),
// the verdict combination rule, scores over non-disputed items only, unavailable
// never zero, the ⚠ Fable line, SOURCE_CHANGED, codex deny carried over; codex
// TIMEOUT/PROMPT_BYTES headers and the image-link note (RV21-23); extend mode (EX*):
// the prior result taken INLINE (extendResult; the path form refused), shape/caller
// refusals before any spawn, one tiny snapshot check (never a relay of the prior),
// attach-without-re-adjudication, blind adjudication of new items only, superseded
// runs kept but unscored, recall recomputed — and the check's real jq command.
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
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
// patch-check line per {label: [applies, rc, error?]}, and the leakcheck line.
const FIN = (rows, { leak = 'CLEAN', rc, badDiff = [], leakField, baseMoved } = {}) => prompt => {
  const diffs = [...prompt.matchAll(/diff --worktree '([^']+)' --base '[^']+' --out '([^']+)'/g)].map(m => {
    const label = m[2].replace(/^.*\//, '').replace(/\.patch$/, '')
    return badDiff.includes(label) ? { worktree: m[1], patch: m[2], ok: false, error: 'worktree does not exist' } : { worktree: m[1], patch: m[2], ok: true, shortstat: '' }
  })
  const results = Object.entries(rows).map(([label, [applies, rc2, error]]) => Object.assign({ patch: `/o/out/${label}.patch`, applies, rc: rc2, diffstat: applies ? '1 file changed, 1 insertion(+)' : '', tail: `tail-${label}` }, error ? { error } : {}))
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
    ['retired agy vendor', A({ candidates: [{ vendor: 'agy', level: 'builder' }] })],
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
  const agy = await throws(A({ candidates: [{ vendor: 'codex', level: 'builder' }, { vendor: 'agy', level: 'builder' }] }))
  chk('C1: an agy candidate is refused by name, naming its retirement, before any spawn',
    agy.threw && agy.calls.length === 0 && agy.message.includes('candidates[1].vendor "agy"') && agy.message.includes('agy was retired 2026-09-24'))
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
      { vendor: 'codex', level: 'quick' },
      { vendor: 'claude', level: 'deep', label: 'mine' },
    ] }),
    {
      'candidate:claude-builder': ['done\nCHECK rc=0\nDONE'],
      'candidate:codex-deep': [EXT_OK('codex', 'gpt-6-astra')],
      'candidate:codex-quick': [EXT_OK('codex', 'gpt-6-luna', 500, 30, null)],
      'candidate:mine': ['done\nCHECK rc=0\nDONE'],
      'grade:': [FIN({ 'claude-builder': [true, 0], 'codex-deep-gpt-6-astra-high': [true, 0], 'codex-quick': [true, 1], mine: [false, null] })],
    })
  chk('C2: stage spawn first, candidates one at a time in plan order, ONE grade spawn, then cleanup',
    maxInflight === 1 && calls.map(c => c.label).join() === 'stage:create,candidate:claude-builder,candidate:codex-deep-gpt-6-astra-high,candidate:codex-quick,candidate:mine,grade:finalize,cleanup:stage')
  chk('C2: the stage spawn is ONE triage-quick-task running stage-worktree.sh create with --count = the number of candidates, the repo, base and <outDir>/stage',
    calls[0].opts.agentType === 'triage-quick-task' && calls[0].opts.schema && calls[0].opts.schema.required.includes('worktrees') &&
    calls[0].prompt.includes(`~/.claude/scripts/stage-worktree.sh create --repo '${REPO}' --base 'HEAD' --count 4 --dir '${STAGE}'`))
  chk('C2: default labels are vendor-level[-model][-effort]; explicit labels are kept',
    result.candidates.map(c => c.label).join() === 'claude-builder,codex-deep-gpt-6-astra-high,codex-quick,mine')
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
      { vendor: 'claude', level: 'builder', model: 'claude-sonnet-5' },
      { vendor: 'claude', level: 'deep', effort: 'max' },
      { vendor: 'claude', level: 'top', model: 'fable', effort: 'xhigh' },
    ] }),
    { 'candidate:': ['done'], 'grade:': [FIN({})] })
  const cand = cands(calls)
  chk('C3: no spawn uses isolation:worktree (it bases on the default branch, not the staged sha)', calls.every(c => !('isolation' in c.opts)))
  chk('C3: agentType follows the level map (quick/builder/deep/top)',
    cand.map(c => c.opts.agentType).join() === 'triage-quick-task,triage-builder,triage-deep-reasoner,triage-fable-architect')
  chk('C3: model/effort pass through only when given (a pinned id like claude-sonnet-5 verbatim, an alias like fable verbatim)',
    !('model' in cand[0].opts) && !('effort' in cand[0].opts) && cand[1].opts.model === 'claude-sonnet-5' && !('effort' in cand[1].opts) &&
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
      { vendor: 'codex', level: 'builder' },
      { vendor: 'codex', level: 'quick', label: 'luna' },
    ] }),
    { 'candidate:': [EXT_OK('codex', 'm')], 'grade:': [FIN({})] })
  const cand = cands(calls)
  const first = c => c.prompt.split('\n')[0]
  chk('C4: codex header is exact (EFFORT, MODEL, then WORKDIR = its own staged worktree, last)',
    first(cand[0]) === `VENDOR=codex LEVEL=deep EFFORT=high MODEL=gpt-6-astra WORKDIR=${STAGE}/wt-1`)
  chk('C4: the header omits EFFORT/MODEL when not given', first(cand[1]) === `VENDOR=codex LEVEL=builder WORKDIR=${STAGE}/wt-2`)
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
      { vendor: 'codex', level: 'builder', label: 'u2' },
      { vendor: 'claude', level: 'builder', label: 'u3' },
      { vendor: 'codex', level: 'deep', label: 'u4' },
      { vendor: 'claude', level: 'deep', label: 'ok' },
    ] }),
    {
      'candidate:u1': ['UNAVAILABLE: codex exited 1 — rate limited'],
      'candidate:u2': ['REFUSED: .codex-deny marker'],
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
      { vendor: 'codex', level: 'quick', label: 'g1' },
      { vendor: 'claude', level: 'builder', label: 'c2' },
    ] }),
    {
      'candidate:c1': ['done'], 'candidate:c2': ['done'],
      'candidate:x1': [EXT_OK('codex', 'gpt-6-sol', 5000, 42, 800)],
      'candidate:g1': [EXT_OK('codex', 'gpt-6-luna', 700, 9.5, null)],
      'grade:': [FIN({ c1: [true, 0], x1: [true, 0], g1: [true, 0], c2: [true, 0] })],
    },
    { spend: { 'stage:': 55, 'candidate:c1': 1234, 'candidate:x1': 50, 'candidate:g1': 60, 'candidate:c2': 777, 'grade:': 99, 'cleanup:': 11 } })
  chk('C8: a Claude candidate outTokens is exactly its own budget.spent() delta (stage/grade/cleanup excluded)', byLabel(result, 'c1').outTokens === 1234 && byLabel(result, 'c2').outTokens === 777)
  chk('C8: Claude candidates have no vendor total/seconds', byLabel(result, 'c1').totalTokens === null && byLabel(result, 'c1').seconds === null)
  chk('C8: an external candidate parses tokens/seconds/out/model from the ext-run line',
    byLabel(result, 'x1').totalTokens === 5000 && byLabel(result, 'x1').seconds === 42 && byLabel(result, 'x1').outTokens === 800 && byLabel(result, 'x1').model === 'gpt-6-sol')
  chk('C8: modelFrom says where model came from: runner (the ext-run line) for an external candidate with no model, null for a Claude candidate with none',
    byLabel(result, 'x1').modelFrom === 'runner' && byLabel(result, 'g1').modelFrom === 'runner' && byLabel(result, 'c1').modelFrom === null && byLabel(result, 'c1').model === null)
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
  chk('C12: a leakcheck that errored is UNKNOWN (leak null, loud), not clean', r3.leak === null && l3.some(l => l.startsWith('⚠ LEAK CHECK INCOMPLETE')))
  chk('C12: …and an UNKNOWN leak state voids every grade: a checks-green candidate is invalid, graded:false, the ⚠ says so',
    byLabel(r3, 'a').status === 'invalid' && /LEAK STATE UNKNOWN/.test(byLabel(r3, 'a').tail) && r3.graded === false &&
    l3.some(l => l.startsWith('⚠ LEAK CHECK INCOMPLETE') && l.includes('Every candidate is INVALID')))
  const { result: r4 } = await run(
    A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'codex', level: 'builder', label: 'u' }] }),
    { 'candidate:a': ['done'], 'candidate:u': ['UNAVAILABLE: x'], 'grade:': [FIN({ a: [true, 0] }, { leak: 'CLEAN', rc: 0, leakField: false })].map(f => p => Object.assign(f(p), { leakcheck: { rc: 0 } })) })
  chk('C12: a leakcheck line with no status (relayed badly) is UNKNOWN too — every candidate, unavailable included, is invalid',
    r4.leak === null && r4.candidates.every(c => c.status === 'invalid') && r4.graded === false)
  chk('C12: a LEAK also leaves graded:false (no grade stands)', result.graded === false)
}

// ---- C12o: a patch patch-check could not grade (overlay-failed) is invalid -------
{
  const { result, logs } = await run(
    A({ overlay: '/h/hidden', candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'claude', level: 'deep', label: 'b' }, { vendor: 'claude', level: 'deep', label: 'c' }] }),
    { 'candidate:': ['done\nCHECK rc=0'], 'grade:': [FIN({ a: [true, null, 'overlay-failed'], b: [true, 0], c: [true, null] })] })
  chk('C12o: patch-check error overlay-failed → invalid (never pass, never fail), the reason in tail',
    byLabel(result, 'a').status === 'invalid' && byLabel(result, 'a').rc === null && /overlay-failed/.test(byLabel(result, 'a').tail))
  chk('C12o: an applied patch relayed with rc null (error field dropped by the relay) is invalid too, not a fail', byLabel(result, 'c').status === 'invalid')
  chk('C12o: the other candidate still grades, but graded:false (not every candidate was graded)', byLabel(result, 'b').status === 'pass' && result.leak === false && result.graded === false)
  chk('C12o: the tally counts it as INVALID', logs.some(l => /2 INVALID/.test(l)))
}

// ---- C13: external candidates require args.files -----------------------------
{
  const noFiles = await throws(A({ files: undefined, candidates: [{ vendor: 'codex', level: 'builder' }] }))
  chk('C13: an external candidate without args.files throws before any spawn',
    noFiles.threw && noFiles.calls.length === 0 && /args\.files must be a non-empty array/.test(noFiles.message))
  const emptyFiles = await throws(A({ files: [], candidates: [{ vendor: 'codex', level: 'quick' }] }))
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
      { vendor: 'claude', level: 'quick' }, { vendor: 'codex', level: 'builder' }, { vendor: 'codex', level: 'quick' }, { vendor: 'claude', level: 'top' },
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

// ---- C18: (i) every Claude candidate is told to work only inside its worktree ---
{
  const { calls } = await run(A({ candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'claude', level: 'deep', label: 'b' }] }),
    { 'candidate:': ['done'], 'grade:': [FIN({})] })
  chk('C18: every Claude prompt says work only inside <its worktree>, search no other directory (incl. other copies), graded only from the worktree',
    cands(calls).every((c, i) => c.prompt.includes(`Work only inside ${STAGE}/wt-${i + 1}. Do not read, list or search any other directory on this machine (including other copies of this project); the task is graded only from your worktree.`)))
}

// ---- C19: (d) $PARITY_ checks stay unexpanded; .parity-env only when opted in ---
{
  const PCHECK = '"$PARITY_PY" -m pytest tests/test_x.py'
  const cs = [{ vendor: 'claude', level: 'builder', label: 'a' }, { vendor: 'codex', level: 'deep', label: 'x' }]
  const opt = await run(A({ checks: [PCHECK], selfCheckEnv: true, candidates: cs }),
    { 'candidate:a': ['done'], 'candidate:x': [EXT_OK('codex', 'gpt-6-sol')], 'grade:': [FIN({})] })
  const [ca, cx] = cands(opt.calls)
  chk('C19: the checks reach every candidate prompt with $PARITY_ UNEXPANDED, plus the one self-check line',
    [ca, cx].every(c => c.prompt.includes(PCHECK) && c.prompt.includes('To run the checks yourself, first run: . .parity-env')))
  chk('C19: the Claude candidate sources it in the SAME command, after its cd prefix',
    ca.prompt.includes(`\`cd ${STAGE}/wt-1 && . .parity-env && ${PCHECK}\``))
  const st = opt.calls.find(c => c.label === 'stage:create')
  chk('C19: selfCheckEnv: the stage command copies <repo>/.parity-env into EACH staged worktree (never the other way)',
    st && [1, 2].every(i => st.prompt.includes(`cp '${REPO}/.parity-env' '${STAGE}/wt-${i}/.parity-env'`)))
  const no = await run(A({ checks: [PCHECK], candidates: cs }),
    { 'candidate:a': ['done'], 'candidate:x': [EXT_OK('codex', 'gpt-6-sol')], 'grade:': [FIN({})] })
  const [na, nx] = cands(no.calls)
  chk('C19: without selfCheckEnv: no .parity-env line, no copy, and the candidates are told the checks run only at grading',
    [na, nx].every(c => c.prompt.includes(PCHECK) && !c.prompt.includes('.parity-env') && /set only (when your work is graded|at grading)/.test(c.prompt)) &&
    !no.calls.find(c => c.label === 'stage:create').prompt.includes('.parity-env'))
  const plain = await run(A({ selfCheckEnv: true, candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }), { 'candidate:': ['done'], 'grade:': [FIN({})] })
  chk('C19: checks with no $PARITY_ variable get no env line at all', !cands(plain.calls)[0].prompt.includes('PARITY_'))
  const r = await throws(A({ selfCheckEnv: 'yes', candidates: [{ vendor: 'claude', level: 'builder' }] }))
  chk('C19: a non-boolean selfCheckEnv throws before any spawn', r.threw && r.calls.length === 0 && /args\.selfCheckEnv/.test(r.message))
}

// ═══ kind:'review' — the review bake-off ════════════════════════════════════════
const RB = 'b'.repeat(40)
const RH = 'c'.repeat(40)
const LIVE = '/r/live-repo'
const ROUT = '/o/rv'
const SNAPDIR = `${ROUT}/snap`
const SNAP_OK = (over = {}, fp = { rc: 0, head: RH }) => ({ snapshot: Object.assign({ ok: true, base: RB, head: RH, files: 3, bytes: 100, diffBytes: 50, extras: 0, excluded: 1, codexDenied: false }, over), fingerprint: fp })
const RF = (file, line, claim, severity = 'major') => ({ file, line, severity, category: 'U1', claim, evidence: `page image p${line}`, suggestedFix: 'fix it' })
const CX = (obj, n = 500, sec = 12, model = 'gpt-6-sol') => `CROSS-REVIEW (codex · read · exit 0)\n${JSON.stringify(obj)}\next-run: ${n} tokens (${sec}s, codex/${model}) out=100`
// The merge mock: clusters findings with the same claim text (what a good merger does).
const MERGE_BY_CLAIM = prompt => {
  const fs = prompt.split('\n').filter(l => l.startsWith('{"id":"F')).map(l => JSON.parse(l))
  const g = new Map()
  for (const f of fs) { if (!g.has(f.claim)) g.set(f.claim, []); g.get(f.claim).push(f) }
  return { items: [...g.values()].map(list => ({ members: list.map(f => f.id), file: list[0].file, line: list[0].line, severity: list[0].severity, category: list[0].category, claim: list[0].claim, evidence: list[0].evidence, suggestedFix: list[0].suggestedFix })) }
}
// Adjudicator mocks: the verdict is keyed off a word in the claim, per adjudicator.
const decide = (who, claim) => {
  if (/SPLIT/.test(claim)) return who === 'claude' ? 'real' : 'not-real'
  if (/UNSURE/.test(claim)) return who === 'claude' ? 'real' : 'unsure'
  if (/MIXREJ/.test(claim)) return who === 'claude' ? 'not-real' : 'accepted-deviation'
  if (/ACCDEV/.test(claim)) return 'accepted-deviation'
  if (/FAKE/.test(claim)) return 'not-real'
  return 'real'
}
const blindItems = prompt => prompt.split('\n').filter(l => l.startsWith('{"id":"M')).map(l => JSON.parse(l))
const ADJ = who => prompt => {
  const v = blindItems(prompt).map(it => ({ id: it.id, verdict: decide(who, it.claim), evidence: `${who} checked ${it.file}:${it.line}` }))
  return who === 'codex' ? CX({ verdicts: v }, 300, 5, 'gpt-6-astra') : { verdicts: v }
}
const RV_REVIEWERS = [
  { vendor: 'claude', level: 'builder', model: 'sonnet', effort: 'high', label: 'rv-sonnet' },
  { vendor: 'claude', level: 'deep', model: 'opus', effort: 'high', label: 'rv-opus' },
  { vendor: 'codex', level: 'deep', model: 'gpt-6-sol', effort: 'medium', label: 'rv-sol' },
  { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high', label: 'rv-astra' },
  { vendor: 'claude', level: 'quick', label: 'rv-bad' },
]
const RBASE = {
  kind: 'review', repo: LIVE, repoName: 'voron', base: 'abc123', head: 'HEAD', include: ['docs/**/*.md'], context: ['review/RUBRIC.md'],
  groundTruth: 'GT-TEXT: page images under assets are authoritative', accepted: 'ACCEPTED-TEXT: parts-first render order', conventions: 'CONV-TEXT: Do <= 40 words',
  outDir: ROUT, reviewers: RV_REVIEWERS,
}
const RA = extra => Object.assign({}, RBASE, extra)
const RV_SCRIPT = (extra = {}) => Object.assign({
  'review:snapshot': [SNAP_OK()],
  'reviewer:rv-sonnet': [{ findings: [RF('docs/a.md', 3, 'REAL typo in step 1'), RF('docs/a.md', 10, 'FAKE missing tag', 'minor'), RF('docs/b.md', 5, 'SPLIT wrong torque', 'blocker')] }],
  'reviewer:rv-opus': [{ findings: [RF('docs/a.md', 3, 'REAL typo in step 1'), RF('docs/b.md', 8, 'REAL wrong bolt count')] }],
  'reviewer:rv-sol': [CX({ findings: [RF('docs/a.md', 3, 'REAL typo in step 1'), RF('docs/c.md', 1, 'ACCDEV parts-first order'), RF('docs/c.md', 2, 'UNSURE ambiguous step'), RF('docs/c.md', 9, 'MIXREJ lids first')] })],
  'reviewer:rv-astra': ['UNAVAILABLE: codex exited 1 — rate limited'],
  'reviewer:rv-bad': [null],
  'review:merge': [MERGE_BY_CLAIM],
  'adjudicate:claude': [ADJ('claude')],
  'adjudicate:codex': [ADJ('codex')],
  'review:fingerprint': [{ rc: 0, same: true, changed: [], headMoved: false, detail: 'SAME: nothing under the paths changed' }],
}, extra)
const rvItem = (res, file, line) => res.items.find(it => it.file === file && it.line === line) || {}
const rvRev = (res, l) => res.reviewers.find(r => r.label === l) || {}
const near = (x, y) => x != null && Math.abs(x - y) < 1e-9

// ---- RV1: validation throws before ANY spawn ----------------------------------
{
  const cases = [
    ['unknown kind', RA({ kind: 'audit' })],
    ['no repoName', RA({ repoName: undefined })],
    ['repoName that is a path', RA({ repoName: 'a/b' })],
    ['relative repo', RA({ repo: 'repo' })],
    ['no base', RA({ base: undefined })],
    ['no include', RA({ include: undefined })],
    ['empty include', RA({ include: [] })],
    ['absolute include', RA({ include: ['/etc/passwd'] })],
    ['.. in include', RA({ include: ['docs/../../x'] })],
    ['pathspec magic in include', RA({ include: [':(top)x'] })],
    ['flag-like include', RA({ include: ['--out'] })],
    ['.. in context', RA({ context: ['../secret.md'] })],
    ['no groundTruth', RA({ groundTruth: '' })],
    ['non-string accepted', RA({ accepted: 5 })],
    ['relative outDir', RA({ outDir: 'out' })],
    ['outDir inside repo', RA({ outDir: `${LIVE}/rv` })],
    ['outDir === repo', RA({ outDir: LIVE })],
    ['outDir containing the repo', RA({ outDir: '/r' })],
    ['extras src relative', RA({ extras: [{ src: 'cache.json', dest: 'cad/index.json' }] })],
    ['extras src inside repo', RA({ extras: [{ src: `${LIVE}/cache.json`, dest: 'cad/index.json' }] })],
    ['extras dest with ..', RA({ extras: [{ src: '/c/cache.json', dest: '../index.json' }] })],
    ['no reviewers', RA({ reviewers: [] })],
    ['retired agy reviewer', RA({ reviewers: [{ vendor: 'agy', level: 'deep' }] })],
    ['codex reviewer without model/effort', RA({ reviewers: [{ vendor: 'codex', level: 'deep' }] })],
    ['duplicate reviewer labels', RA({ reviewers: [{ vendor: 'claude', level: 'deep', label: 'x' }, { vendor: 'claude', level: 'top', label: 'x' }] })],
    ['path-unsafe reviewer label', RA({ reviewers: [{ vendor: 'claude', level: 'deep', label: '../x' }] })],
    ['a single adjudicator', RA({ adjudicators: [{ vendor: 'claude', level: 'deep' }] })],
    ['agy adjudicator', RA({ adjudicators: [{ vendor: 'claude', level: 'deep' }, { vendor: 'agy', level: 'deep' }] })],
    ['batchSize 0', RA({ batchSize: 0 })],
  ]
  for (const [name, args] of cases) {
    const r = await throws(args)
    chk(`RV1: ${name} throws before any spawn`, r.threw && r.calls.length === 0 && /triage-compare/.test(r.message))
  }
  const agy = await throws(RA({ reviewers: [{ vendor: 'agy', level: 'deep' }] }))
  chk('RV1: an agy reviewer is refused by name, naming its retirement', agy.threw && agy.message.includes('agy was retired 2026-09-24'))
  const cx = await throws(RA({ reviewers: [{ vendor: 'codex', level: 'deep' }] }))
  chk('RV1: the codex refusal says why (read mode would run its own default model)', cx.threw && /must pin model and effort/.test(cx.message))
}

// ---- RV2: the flow — snapshot, parallel reviewers, merge, adjudicate, fingerprint
const RV = await run(RA({}), RV_SCRIPT())
{
  const { calls, maxInflight, result } = RV
  const L = calls.map(c => c.label)
  const idx = pfx => L.findIndex(l => l.startsWith(pfx))
  const last = pfx => L.map((l, i) => (l.startsWith(pfx) ? i : -1)).filter(i => i >= 0).pop()
  chk('RV2: ONE snapshot spawn first, on triage-quick-task with a snapshot/fingerprint schema', L[0] === 'review:snapshot' && calls[0].opts.agentType === 'triage-quick-task' &&
    ['snapshot', 'fingerprint'].every(k => calls[0].opts.schema.required.includes(k)) && L.filter(l => l === 'review:snapshot').length === 1)
  chk('RV2: every reviewer spawns (5), all before the merge; the merge before any adjudicator; the fingerprint last',
    L.filter(l => l.startsWith('reviewer:')).length === 5 && last('reviewer:') < idx('review:merge') && idx('review:merge') < idx('adjudicate:') &&
    last('adjudicate:') < idx('review:fingerprint') && L[L.length - 1] === 'review:fingerprint')
  chk('RV2: reviewers run IN PARALLEL (all five in flight at once)', maxInflight >= 5)
  chk('RV2: the review flow never stages worktrees, grades patches or cleans a stage', !L.some(l => /^(stage:|grade:|cleanup:|candidate:)/.test(l)))
  chk('RV2: returns kind review, the resolved base/head shas, sourceChanged false', result.kind === 'review' && result.base === RB && result.head === RH && result.sourceChanged === false)
}

// ---- RV3: the snapshot + fingerprint commands are exact -------------------------
{
  const p = RV.calls[0].prompt
  chk('RV3: the snapshot command names repo, base, head, include, context and outDir exactly (review-stage.sh)',
    p.includes(`~/.claude/scripts/review-stage.sh snapshot --repo '${LIVE}' --base 'abc123' --head 'HEAD' --include 'docs/**/*.md' --context 'review/RUBRIC.md' --out '${ROUT}'`))
  chk('RV3: the fingerprint covers include + context and is written to <outDir>/fingerprint-before.json',
    p.includes(`~/.claude/scripts/review-stage.sh fingerprint --repo '${LIVE}' --path 'docs/**/*.md' 'review/RUBRIC.md' --out '${ROUT}/fingerprint-before.json'`))
  const { calls } = await run(RA({ exclude: ['site'], hardExclude: ['secret/'], extras: [{ src: '/c/voron-cad/index.json', dest: 'cad/index.json' }] }), RV_SCRIPT())
  chk('RV3: exclude, extras (SRC:DEST) and hard excludes are passed through to the snapshot, hard excludes to the fingerprint too',
    calls[0].prompt.includes(` --exclude 'site' --context 'review/RUBRIC.md' --extra '/c/voron-cad/index.json:cad/index.json' --hard-exclude 'secret/' --out '${ROUT}'`) &&
    calls[0].prompt.includes(`--path 'docs/**/*.md' 'review/RUBRIC.md' --hard-exclude 'secret/' --out '${ROUT}/fingerprint-before.json'`))
}

// ---- RV4: reviewers get ONLY the snapshot + range diff ------------------------
{
  const rv = RV.calls.filter(c => c.label.startsWith('reviewer:'))
  const by = l => rv.find(c => c.label === `reviewer:${l}`)
  const claude = rv.filter(c => !/^VENDOR=/.test(c.prompt))
  const codex = rv.filter(c => /^VENDOR=/.test(c.prompt))
  chk('RV4: a Claude reviewer spawns its level\'s agent with its model/effort and the findings schema',
    by('rv-sonnet').opts.agentType === 'triage-builder' && by('rv-sonnet').opts.model === 'sonnet' && by('rv-sonnet').opts.effort === 'high' &&
    by('rv-opus').opts.agentType === 'triage-deep-reasoner' && by('rv-bad').opts.agentType === 'triage-quick-task' && !('model' in by('rv-bad').opts) &&
    claude.every(c => c.opts.schema && c.opts.schema.required.includes('findings')))
  chk('RV4: a Claude reviewer reads only <outDir>/snap and <outDir>/range.diff, with `cd <snap> && ` on every command, read-only, no git',
    claude.every(c => c.prompt.includes(`Your ONLY inputs: the snapshot directory ${SNAPDIR}`) && c.prompt.includes(`range diff ${ROUT}/range.diff`) &&
      c.prompt.includes(`EVERY shell command you run MUST start with \`cd ${SNAPDIR} && \``) && /READ-ONLY/.test(c.prompt) && /never run git/.test(c.prompt) &&
      /image files under the snapshot/.test(c.prompt)))
  chk('RV4: every cd in a Claude reviewer prompt targets the snapshot, chained with &&',
    claude.every(c => [...c.prompt.matchAll(/(^|[\s`])cd\s+(\/\S*)/g)].every(m => m[2] === SNAPDIR && c.prompt.slice(m.index + m[0].length).startsWith(' && '))))
  chk('RV4: a codex reviewer is triage-cross-reviewer in MODE=read with MODEL/EFFORT pinned and INPUT_DIR = the snapshot, plus the range diff as --input',
    codex.length === 2 && codex.every(c => c.opts.agentType === 'triage-cross-reviewer' && !('model' in c.opts)) &&
    by('rv-sol').prompt.startsWith(`VENDOR=codex\nMODE=read\nMODEL=gpt-6-sol\nEFFORT=medium\nINPUT_DIR=${SNAPDIR}\n`) &&
    by('rv-sol').prompt.includes(`--input ${ROUT}/range.diff`) && by('rv-sol').prompt.includes('The data boundary has been checked') &&
    by('rv-sol').prompt.includes('"required":["file","line","severity","category","claim","evidence","suggestedFix"]'))
}

// ---- RV5: the live repo path appears in NO reviewer, merge or adjudicator prompt --
{
  const judged = RV.calls.filter(c => /^(reviewer:|review:merge|adjudicate:)/.test(c.label))
  chk('RV5: the live repo path appears in no reviewer / merge / adjudicator prompt (only the snapshot + fingerprint commands name it)',
    judged.length > 0 && judged.every(c => !c.prompt.includes(LIVE)) && RV.calls.filter(c => c.prompt.includes(LIVE)).every(c => /^review:(snapshot|fingerprint)$/.test(c.label)))
  chk('RV5: …and neither does the repo name (metadata-free prompts)', judged.every(c => !c.prompt.includes('voron')))
}

// ---- RV6: ground truth, conventions, accepted deviations — verbatim ------------
{
  const rv = RV.calls.filter(c => /^(reviewer:|adjudicate:)/.test(c.label))
  chk('RV6: every reviewer and adjudicator prompt carries groundTruth, conventions and accepted verbatim',
    rv.every(c => c.prompt.includes(RBASE.groundTruth) && c.prompt.includes(RBASE.conventions) && c.prompt.includes(RBASE.accepted)))
  chk('RV6: accepted deviations come with "do not flag these unless you cite NEW ground-truth evidence"; summaries are never ground truth',
    rv.every(c => c.prompt.includes('do not flag these unless you cite NEW ground-truth evidence') && c.prompt.includes('is NEVER ground truth')))
}

// ---- RV7/RV8: merge and adjudicators are blind ---------------------------------
{
  const m = RV.calls.find(c => c.label === 'review:merge')
  chk('RV7: ONE merge spawn on the deep agent, with a members/items schema', RV.calls.filter(c => c.label.startsWith('review:merge')).length === 1 &&
    m.opts.agentType === 'triage-deep-reasoner' && m.opts.schema.required.includes('items'))
  chk('RV7: the merge sees opaque finding ids only — no reviewer label, vendor or reviewer id', !/rv-|\bR\d+\b|codex|claude/.test(m.prompt) && /"id":"F1"/.test(m.prompt))
  const adj = RV.calls.filter(c => c.label.startsWith('adjudicate:'))
  chk('RV8: adjudicator prompts name no reviewer label, no reviewer id and no provenance field',
    adj.length === 2 && adj.every(c => !/rv-|\bR\d+\b|"prov"|"members"|"foundBy"|[Ff]ound by|reported by \d/.test(c.prompt)))
  chk('RV8: each adjudicator got every item, blind JSON lines with id/file/line/claim/evidence',
    adj.every(c => blindItems(c.prompt).length === RV.result.items.length && blindItems(c.prompt).every(it => /^M\d+$/.test(it.id) && Object.keys(it).join() === 'id,file,line,severity,category,claim,evidence,suggestedFix')))
  const cj = adj.find(c => c.label.startsWith('adjudicate:claude'))
  const xj = adj.find(c => c.label.startsWith('adjudicate:codex'))
  chk('RV8: default adjudicators = claude deep (claude-opus-5-5·high, a pinned id, triage-deep-reasoner, schema) + codex deep (gpt-6-astra·high, MODE=read, INPUT_DIR = snapshot only)',
    cj.opts.agentType === 'triage-deep-reasoner' && cj.opts.model === 'claude-opus-5-5' && cj.opts.effort === 'high' && cj.opts.schema.required.includes('verdicts') &&
    cj.prompt.includes(`Your ONLY input is the snapshot directory ${SNAPDIR}`) && !cj.prompt.includes('range.diff') &&
    xj.opts.agentType === 'triage-cross-reviewer' && xj.prompt.startsWith(`VENDOR=codex\nMODE=read\nMODEL=gpt-6-astra\nEFFORT=high\nINPUT_DIR=${SNAPDIR}\n`) && !xj.prompt.includes('--input '))
}

// ---- RV9: verdict combination ------------------------------------------------------
{
  const r = RV.result
  chk('RV9: duplicates merged into one item (docs/a.md:3 found by three reviewers)', r.items.filter(it => it.file === 'docs/a.md' && it.line === 3).length === 1 &&
    rvItem(r, 'docs/a.md', 3).foundBy.join() === 'rv-opus,rv-sol,rv-sonnet')
  chk('RV9: both real => real', rvItem(r, 'docs/a.md', 3).verdict === 'real' && rvItem(r, 'docs/b.md', 8).verdict === 'real')
  chk('RV9: both not-real => rejected; both accepted-deviation => rejected; not-real + accepted-deviation => rejected',
    rvItem(r, 'docs/a.md', 10).verdict === 'rejected' && rvItem(r, 'docs/c.md', 1).verdict === 'rejected' && rvItem(r, 'docs/c.md', 9).verdict === 'rejected')
  chk('RV9: real vs not-real => disputed; real vs unsure => disputed', rvItem(r, 'docs/b.md', 5).verdict === 'disputed' && rvItem(r, 'docs/c.md', 2).verdict === 'disputed')
  chk('RV9: disputed ids are listed, and each item keeps both adjudicators\' verdict + evidence',
    r.disputed.slice().sort().join() === [rvItem(r, 'docs/b.md', 5).id, rvItem(r, 'docs/c.md', 2).id].sort().join() &&
    rvItem(r, 'docs/b.md', 5).adjudication.map(x => `${x.adjudicator}:${x.verdict}`).join() === 'claude-deep-claude-opus-5-5-high:real,codex-deep-gpt-6-astra-high:not-real' &&
    rvItem(r, 'docs/b.md', 5).adjudication.every(x => /checked docs\/b\.md:5/.test(x.evidence)))
  chk('RV9: item ids are M1..Mn in file/line order', r.items.map(it => it.id).join() === r.items.map((_, i) => `M${i + 1}`).join() &&
    r.items.map(it => `${it.file}:${it.line}`).join() === 'docs/a.md:3,docs/a.md:10,docs/b.md:5,docs/b.md:8,docs/c.md:1,docs/c.md:2,docs/c.md:9')
}

// ---- RV10: scores — disputed excluded, unavailable never zero ------------------
{
  const r = RV.result
  const s = rvRev(r, 'rv-sonnet')
  const o = rvRev(r, 'rv-opus')
  const x = rvRev(r, 'rv-sol')
  chk('RV10: precision = real / adjudicated (disputed excluded): sonnet 1/2, opus 2/2, sol 1/3', near(s.precision, 0.5) && near(o.precision, 1) && near(x.precision, 1 / 3))
  chk('RV10: recall = real found / all real (2): sonnet 1/2, opus 2/2, sol 1/2', near(s.recall, 0.5) && near(o.recall, 1) && near(x.recall, 0.5))
  chk('RV10: per-reviewer counts: findings, real, rejected, disputed', [s.findings, s.real, s.rejected, s.disputed].join() === '3,1,1,1' && [x.findings, x.real, x.rejected, x.disputed].join() === '4,1,2,1')
  chk('RV10: an UNAVAILABLE codex reply and an invalid (null) Claude reply are status unavailable with null scores — never zero',
    ['rv-astra', 'rv-bad'].every(l => rvRev(r, l).status === 'unavailable' && rvRev(r, l).precision === null && rvRev(r, l).recall === null && rvRev(r, l).findings === null) &&
    /rate limited/.test(rvRev(r, 'rv-astra').reason))
  chk('RV10: codex tokens/seconds come from its ext-run line; a parallel Claude reviewer has none', x.tokens === 500 && x.seconds === 12 && s.tokens === null)
  chk('RV10: each reviewer row carries label/vendor/level/model/effort/status', s.vendor === 'claude' && s.level === 'builder' && s.model === 'sonnet' && s.effort === 'high' && s.status === 'ok')
}

// ---- RV11: a reply that is not the findings JSON is unavailable -----------------
{
  const { result } = await run(RA({}), RV_SCRIPT({ 'reviewer:rv-sol': ['CROSS-REVIEW (codex · read · exit 0)\nI found some problems but here is prose.\next-run: 10 tokens (1s, codex/gpt-6-sol)'] }))
  chk('RV11: a codex reply with no {"findings": [...]} JSON is unavailable, not a reviewer with zero findings', rvRev(result, 'rv-sol').status === 'unavailable' && rvRev(result, 'rv-sol').precision === null)
  const { result: r2 } = await run(RA({}), RV_SCRIPT({ 'reviewer:rv-opus': [new Error('budget ceiling')] }))
  chk('RV11: a reviewer spawn that throws is unavailable; the others still score', rvRev(r2, 'rv-opus').status === 'unavailable' && rvRev(r2, 'rv-sonnet').status === 'ok')
  const { result: r3, logs } = await run(RA({}), RV_SCRIPT({ 'reviewer:rv-opus': [{ findings: [RF('docs/b.md', 8, 'REAL wrong bolt count'), { file: 'docs/x.md', line: 'n/a', severity: 'major', claim: 'x', evidence: 'y' }, { file: 'docs/x.md', line: 2, severity: 'fatal', claim: 'x', evidence: 'y' }] }] }))
  chk('RV11: malformed findings (bad line / severity) are dropped and flagged; the valid one counts', rvRev(r3, 'rv-opus').findings === 1 && logs.some(l => /rv-opus: 2 malformed finding/.test(l)))
}

// ---- RV12: the ⚠ Fable line before a top-level Claude reviewer / adjudicator ------
{
  const { events } = await run(RA({
    reviewers: [{ vendor: 'claude', level: 'top', model: 'fable', effort: 'xhigh', label: 'rv-fable' }, { vendor: 'claude', level: 'deep', label: 'rv-deep' }],
    adjudicators: [{ vendor: 'claude', level: 'top', label: 'adj-top' }, { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' }],
  }), RV_SCRIPT({
    'reviewer:rv-fable': [{ findings: [RF('docs/a.md', 3, 'REAL typo')] }], 'reviewer:rv-deep': [{ findings: [] }],
    'adjudicate:adj-top': [ADJ('claude')],
  }))
  const iW = events.indexOf('log:⚠ Escalating to Fable: triage-compare review reviewer rv-fable')
  const iS = events.indexOf('agent:reviewer:rv-fable')
  const iWA = events.indexOf('log:⚠ Escalating to Fable: triage-compare review adjudicator adj-top')
  const iSA = events.findIndex(e => e.startsWith('agent:adjudicate:adj-top'))
  chk('RV12: a top-level Claude reviewer logs the ⚠ Fable line BEFORE its spawn', iW >= 0 && iS > iW)
  chk('RV12: a top-level Claude adjudicator too', iWA >= 0 && iSA > iWA)
  chk('RV12: only top-level Claude spawns get it', events.filter(e => e.startsWith('log:⚠ Escalating to Fable')).length === 2)
  const { events: e2 } = await run(RA({}), RV_SCRIPT())
  chk('RV12: an external reviewer/adjudicator is announced as leaving the machine', e2.some(e => e.startsWith('log:⚠ External reviewer rv-sol')) && e2.some(e => e.startsWith('log:⚠ External adjudicator codex-deep-gpt-6-astra-high')))
}

// ---- RV13: adjudicator failure => those items disputed; batching ------------------
{
  const { result, calls, logs } = await run(RA({}), RV_SCRIPT({ 'adjudicate:codex': ['UNAVAILABLE: codex exited 1'] }))
  chk('RV13: a failed adjudicator batch is retried once', calls.filter(c => c.label.startsWith('adjudicate:codex')).map(c => c.label).join() === 'adjudicate:codex-deep-gpt-6-astra-high@b1,adjudicate:codex-deep-gpt-6-astra-high@b1#retry')
  chk('RV13: …then every item of the batch is disputed (a missing verdict is never agreement), flagged',
    result.items.every(it => it.verdict === 'disputed') && logs.some(l => /returned no verdicts for 7 item/.test(l)))
  chk('RV13: with everything disputed no reviewer has a precision or recall (nothing agreed), yet none is unavailable',
    result.reviewers.filter(r => r.status === 'ok').every(r => r.precision === null && r.recall === null))
  const many = Array.from({ length: 12 }, (_, i) => RF(`docs/m${String(i).padStart(2, '0')}.md`, 1, `REAL issue ${i}`))
  const b = await run(RA({ batchSize: 5, reviewers: [{ vendor: 'claude', level: 'deep', label: 'rv-one' }] }), RV_SCRIPT({ 'reviewer:rv-one': [{ findings: many }] }))
  const bj = b.calls.filter(c => c.label.startsWith('adjudicate:'))
  chk('RV13: 12 items in batches of 5 → 3 batches per adjudicator (6 spawns), each with at most 5 items, every item judged by both',
    bj.length === 6 && bj.every(c => blindItems(c.prompt).length <= 5) && b.result.items.every(it => it.verdict === 'real') &&
    bj.filter(c => c.label.startsWith('adjudicate:claude')).map(c => blindItems(c.prompt).length).join() === '5,5,2')
}

// ---- RV14: merge fallback and membership enforcement ------------------------------
{
  const { result, logs } = await run(RA({}), RV_SCRIPT({ 'review:merge': [null] }))
  chk('RV14: a dead merge agent (twice) → every finding its own item, mergeFallback true, flagged',
    result.mergeFallback === true && result.items.length === 9 && logs.some(l => /duplicates NOT merged/.test(l)))
  const sneaky = p => { const m = MERGE_BY_CLAIM(p); m.items[0].members.push('F99', m.items[0].members[0]); m.items.pop(); return m }
  const { result: r2, logs: l2 } = await run(RA({}), RV_SCRIPT({ 'review:merge': [sneaky] }))
  chk('RV14: an unknown id is ignored, and a finding the merge left out becomes its own item (flagged)',
    r2.items.length === 7 && l2.some(l => /left 1 finding\(s\) unplaced/.test(l)))
}

// ---- RV15: the snapshot must succeed, or nothing runs ------------------------------
{
  const dead = await throws(RA({}), RV_SCRIPT({ 'review:snapshot': [{ snapshot: { ok: false, error: '--out exists and is not empty' }, fingerprint: { rc: null } }] }))
  chk('RV15: a failed snapshot throws, naming why, and no reviewer is spawned', dead.threw && /snapshot failed/.test(dead.message) && /not empty/.test(dead.message) && dead.calls.length === 1)
  const badSha = await throws(RA({}), RV_SCRIPT({ 'review:snapshot': [SNAP_OK({ head: 'HEAD' })] }))
  chk('RV15: a snapshot reply without real shas aborts too', badSha.threw && badSha.calls.length === 1)
}

// ---- RV16: SOURCE_CHANGED is informational ----------------------------------------
{
  const { result, logs, calls } = await run(RA({}), RV_SCRIPT({ 'review:fingerprint': [{ rc: 7, same: false, changed: ['status'], headMoved: false, detail: 'SOURCE_CHANGED: status changed under the paths' }] }))
  const fp = calls.find(c => c.label === 'review:fingerprint')
  chk('RV16: the final quick task re-fingerprints to fingerprint-after.json and compares it with the before file',
    fp.opts.agentType === 'triage-quick-task' && fp.prompt.includes(`--out '${ROUT}/fingerprint-after.json'`) &&
    fp.prompt.includes(`review-stage.sh compare '${ROUT}/fingerprint-before.json' '${ROUT}/fingerprint-after.json'`))
  chk('RV16: compare rc 7 → sourceChanged true, flagged SOURCE_CHANGED as informational; the verdicts still stand',
    result.sourceChanged === true && logs.some(l => /SOURCE_CHANGED voron: .*informational/.test(l)) && rvItem(result, 'docs/a.md', 3).verdict === 'real')
  const { result: r2, calls: c2 } = await run(RA({}), RV_SCRIPT({ 'review:snapshot': [SNAP_OK({}, { rc: 1 })] }))
  chk('RV16: a failed initial fingerprint → no final fingerprint spawn, sourceChanged null (unknown, never false)',
    r2.sourceChanged === null && !c2.some(c => c.label === 'review:fingerprint'))
}

// ---- RV17: codexDenied carried from the snapshot ------------------------------------
{
  const { result, calls } = await run(RA({}), RV_SCRIPT({ 'review:snapshot': [SNAP_OK({ codexDenied: true })] }))
  chk('RV17: a snapshot that carries .codex-deny → no codex reviewer or adjudicator is spawned; they are unavailable',
    !calls.some(c => /reviewer:rv-sol|reviewer:rv-astra|adjudicate:codex/.test(c.label)) && rvRev(result, 'rv-sol').status === 'unavailable' && /off-limits to codex/.test(rvRev(result, 'rv-sol').reason))
  chk('RV17: …and with one adjudicator missing, every item is disputed (never decided by one side alone)', result.items.length > 0 && result.items.every(it => it.verdict === 'disputed'))
}

{
  const { logs } = await run(RA({}), RV_SCRIPT({ 'review:snapshot': [SNAP_OK({ bytes: 300 * 1024 * 1024 })] }))
  chk('RV17: a snapshot over ext-run\'s 200 MB --input-dir cap is flagged up front when codex takes part', logs.some(l => /300 MB — over ext-run\.sh's 200 MB --input-dir cap/.test(l)))
  const { logs: l2 } = await run(RA({ reviewers: [{ vendor: 'claude', level: 'deep', label: 'rv-a' }], adjudicators: [{ vendor: 'claude', level: 'deep', label: 'j1' }, { vendor: 'claude', level: 'builder', label: 'j2' }] }),
    RV_SCRIPT({ 'review:snapshot': [SNAP_OK({ bytes: 300 * 1024 * 1024 })], 'reviewer:rv-a': [{ findings: [] }] }))
  chk('RV17: …but not for an all-Claude panel (no --input-dir involved)', !l2.some(l => /--input-dir cap/.test(l)))
}

// ---- RV18: no findings at all → no merge, no adjudication --------------------------
{
  const { result, calls } = await run(RA({ reviewers: [{ vendor: 'claude', level: 'deep', label: 'rv-a' }, { vendor: 'claude', level: 'builder', label: 'rv-b' }] }),
    RV_SCRIPT({ 'reviewer:rv-a': [{ findings: [] }], 'reviewer:rv-b': [{ findings: [] }] }))
  chk('RV18: zero findings → no merge and no adjudicator spawn; precision/recall null (nothing to score), findings 0',
    !calls.some(c => /review:merge|adjudicate:/.test(c.label)) && result.items.length === 0 && result.reviewers.every(r => r.status === 'ok' && r.findings === 0 && r.precision === null && r.recall === null))
}

// ---- RV19: markdown for Alex --------------------------------------------------------
{
  const md = RV.result.markdown
  const iReal = md.indexOf('## Real findings (2)')
  const iDisp = md.indexOf('## Disputed — for Alex (2)')
  chk('RV19: markdown lists real items first, grouped by file, then the disputed ones', iReal >= 0 && iDisp > iReal && md.indexOf('### docs/a.md') > iReal && md.indexOf('### docs/b.md') < iDisp)
  const dsec = md.slice(iDisp)
  chk('RV19: each disputed item shows BOTH adjudicators\' verdict and evidence', dsec.includes('- claude-deep-claude-opus-5-5-high: **real** — claude checked docs/b.md:5') && dsec.includes('- codex-deep-gpt-6-astra-high: **not-real** — codex checked docs/b.md:5'))
  chk('RV19: the markdown ends with the score table and says nothing was applied', /\| rv-opus \| claude \| opus \| high \| ok \| 2 \| 2 \| 0 \| 0 \| 1 \| 1 \|/.test(md) && md.includes('Nothing was applied'))
}

// ---- RV20: an explicit kind:'build' is the unchanged build flow ------------------
{
  const { result, calls } = await run(A({ kind: 'build', candidates: [{ vendor: 'claude', level: 'builder', label: 'a' }] }), { 'candidate:': ['done'], 'grade:': [FIN({ a: [true, 0] })] })
  chk('RV20: kind "build" runs the build bake-off exactly as before', calls[0].label === 'stage:create' && byLabel(result, 'a').status === 'pass' && !('kind' in result))
}

// ---- RV21: codex spawns carry an explicit TIMEOUT; Claude spawns do not --------
{
  const hdr = (p, k) => (p.match(new RegExp(`^${k}=(.*)$`, 'm')) || [])[1]
  const cx = RV.calls.filter(c => c.label.startsWith('reviewer:') && /^VENDOR=/.test(c.prompt))
  const xj = RV.calls.filter(c => c.label.startsWith('adjudicate:codex'))
  chk('RV21: every codex reviewer carries TIMEOUT=30m and every codex adjudicator TIMEOUT=15m (the defaults), in the header after INPUT_DIR',
    cx.length === 2 && cx.every(c => /\nINPUT_DIR=[^\n]+\nTIMEOUT=30m\n/.test(c.prompt)) && xj.length > 0 && xj.every(c => /\nINPUT_DIR=[^\n]+\nTIMEOUT=15m\n/.test(c.prompt)))
  chk('RV21: no Claude reviewer or adjudicator gets a TIMEOUT line or option',
    RV.calls.filter(c => /^(reviewer:|adjudicate:)/.test(c.label) && !/^VENDOR=/.test(c.prompt)).every(c => !/TIMEOUT=/.test(c.prompt) && !('timeout' in c.opts)))
  const { calls } = await run(RA({ reviewerTimeout: '45m', adjudicatorTimeout: '1h' }), RV_SCRIPT())
  chk('RV21: reviewerTimeout / adjudicatorTimeout override the defaults',
    calls.filter(c => /^reviewer:rv-(sol|astra)$/.test(c.label)).every(c => hdr(c.prompt, 'TIMEOUT') === '45m') &&
    calls.filter(c => c.label.startsWith('adjudicate:codex')).every(c => hdr(c.prompt, 'TIMEOUT') === '1h'))
  for (const [name, extra] of [['a word', { reviewerTimeout: 'soon' }], ['zero', { reviewerTimeout: '0m' }], ['over 3h', { adjudicatorTimeout: '4h' }],
    ['a number', { reviewerTimeout: 30 }], ['a compound 1m30s (the watchdog cannot parse it)', { reviewerTimeout: '1m30s' }]]) {
    const r = await throws(RA(extra))
    chk(`RV21: ${name} as a timeout throws before any spawn`, r.threw && r.calls.length === 0 && /Timeout must be a duration/.test(r.message))
  }
}

// ---- RV22: PROMPT_BYTES = the UTF-8 byte length of the prompt-file body ------------
{
  const GT = 'GT: café → ✓ 🔩 page images are authoritative'
  const { calls } = await run(RA({ groundTruth: GT }), RV_SCRIPT())
  const cx = calls.filter(c => /^VENDOR=codex/.test(c.prompt))
  const MARK = /--- Brief for the external (?:reviewer|adjudicator): all of what follows goes into the prompt file ---\n/
  const bytesOf = c => Number((c.prompt.match(/^PROMPT_BYTES=(\d+)$/m) || [])[1])
  const bodyOf = c => c.prompt.split(MARK)
  chk('RV22: every codex reviewer AND adjudicator carries PROMPT_BYTES = Buffer.byteLength(body after the marker + one final newline)',
    cx.length >= 3 && cx.some(c => c.label.startsWith('adjudicate:')) &&
    cx.every(c => bodyOf(c).length === 2 && bytesOf(c) === Buffer.byteLength(`${bodyOf(c)[1]}\n`, 'utf8') && bodyOf(c)[1].includes(GT)))
  chk('RV22: …counted in UTF-8 bytes, not characters (the body holds 2-, 3- and 4-byte characters)', cx.every(c => bytesOf(c) > bodyOf(c)[1].length + 1))
  chk('RV22: PROMPT_BYTES is a header line (before the marker) and the body does not end in a newline',
    cx.every(c => c.prompt.indexOf('\nPROMPT_BYTES=') < c.prompt.search(MARK) && !c.prompt.endsWith('\n')))
}

// ---- RV23: the URL-encoded image-link note reaches every reviewer and adjudicator --
{
  const NOTE = 'Image links in the markdown are URL-encoded (%5B = [, %5D = ], %20 = space, etc.): decode the path before opening the file.'
  const judged = RV.calls.filter(c => /^(reviewer:|adjudicate:)/.test(c.label))
  chk('RV23: every reviewer and adjudicator prompt, both vendors, carries the image-link note once, verbatim',
    judged.length === 7 && judged.every(c => c.prompt.split(NOTE).length === 2) && judged.some(c => /^VENDOR=codex/.test(c.prompt)) && judged.some(c => !/^VENDOR=/.test(c.prompt)))
}

// ---- RV24: the wrapper protocol travels in the codex brief, matching the agent file --
// (agent definitions appear cached per session: a stale wrapper must still get it)
{
  const agentDoc = readFileSync(join(here, '..', 'agents', 'triage-cross-reviewer.md'), 'utf8')
  const cx = RV.calls.filter(c => /^VENDOR=codex/.test(c.prompt))
  const cmdAfter = (p, lead) => { const i = p.indexOf(lead); return i < 0 ? null : p.slice(i + lead.length).split('\n')[1].trim() }
  const pb = cx.map(c => cmdAfter(c.prompt, 'ending with a newline, then run exactly:'))
  const wait = cx.map(c => cmdAfter(c.prompt, 'never reply before it does (a background command dies with your reply):'))
  chk('RV24: every codex brief carries the wrapper steps before the marker: private mktemp -d dir, verbatim prompt + byte check, --timeout, rc-file wait',
    cx.length >= 3 && cx.every(c => { const i = c.prompt.indexOf('Wrapper steps for this run'); return i > 0 && i < c.prompt.indexOf('goes into the prompt file ---') && /mktemp -d/.test(c.prompt) && /REFUSED: prompt not verbatim/.test(c.prompt) }) &&
    cx.filter(c => c.label.startsWith('reviewer:')).every(c => c.prompt.includes('--timeout 30m')) && cx.filter(c => c.label.startsWith('adjudicate:')).every(c => c.prompt.includes('--timeout 15m')))
  chk('RV24: the byte-check and wait commands in the brief are the agent file\'s, verbatim',
    pb.every(x => x && x.startsWith('P=<run dir>/prompt.txt; awk') && agentDoc.includes(x)) && wait.every(x => x && x.startsWith('for i in $(seq 1 100)') && agentDoc.includes(x)))
}

// ═══ extend: add reviewers to a prior review result ════════════════════════════════
// The prior is RV.result itself (this workflow's own output shape), passed INLINE as
// args.extendResult. CHECK builds what the one tiny snapshot-check command prints.
const PRIOR = RV.result
const CHECK = (prior, over = {}) => Object.assign({
  ok: true, resolvedBase: prior.base, resolvedHead: prior.head, manifestBase: prior.base, manifestHead: prior.head,
  snapshotExists: true, snapshotOk: true, fingerprintExists: true, codexDenied: false, files: 3, extras: 0, diffBytes: 50, snapKB: 4,
}, over)
const clone = v => JSON.parse(JSON.stringify(v))
const EXT_REVIEWERS = [
  { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high', label: 'rv-astra2' },
  { vendor: 'claude', level: 'deep', model: 'opus', effort: 'high', label: 'rv-new' },
]
const XA = extra => RA(Object.assign({ extendResult: PRIOR, supersedes: ['rv-sol', 'rv-astra'], reviewers: EXT_REVIEWERS }, extra))
// A prior with one edit (a deep copy — RV.result itself is never touched).
const priorWith = edit => { const p = clone(PRIOR); edit(p); return p }
// The extend merge mock: a new finding whose claim equals an EXISTING item's attaches
// to it; the rest cluster by claim into new items.
const EXT_MERGE = prompt => {
  const lines = prompt.split('\n')
  const ex = lines.filter(l => l.startsWith('{"id":"M')).map(l => JSON.parse(l))
  const fs = lines.filter(l => l.startsWith('{"id":"F')).map(l => JSON.parse(l))
  const out = []
  const g = new Map()
  for (const f of fs) {
    const hit = ex.find(e => e.claim === f.claim)
    if (hit) { out.push({ members: [f.id], existing: hit.id }); continue }
    if (!g.has(f.claim)) g.set(f.claim, [])
    g.get(f.claim).push(f)
  }
  for (const list of g.values()) out.push({ members: list.map(f => f.id), existing: '', file: list[0].file, line: list[0].line, severity: list[0].severity, category: list[0].category, claim: list[0].claim, evidence: list[0].evidence, suggestedFix: list[0].suggestedFix })
  return { items: out }
}
const XS = (extra = {}) => Object.assign({
  'review:extend-check': [CHECK(PRIOR)],
  'reviewer:rv-astra2': [CX({ findings: [RF('docs/a.md', 3, 'REAL typo in step 1'), RF('docs/d.md', 4, 'REAL new defect')] }, 900, 30, 'gpt-6-astra')],
  'reviewer:rv-new': [{ findings: [RF('docs/d.md', 4, 'REAL new defect'), RF('docs/b.md', 5, 'SPLIT wrong torque', 'blocker'), RF('docs/e.md', 2, 'FAKE made up')] }],
  'review:merge': [EXT_MERGE],
  'adjudicate:claude': [ADJ('claude')],
  'adjudicate:codex': [ADJ('codex')],
  'review:fingerprint': [{ rc: 0, same: true, changed: [], headMoved: false, detail: 'SAME: nothing under the paths changed' }],
}, extra)
const priorItem = id => PRIOR.items.find(it => it.id === id)
const idOf = (file, line) => rvItem(PRIOR, file, line).id
const noReviewer = calls => !calls.some(c => /^(reviewer:|review:merge|adjudicate:)/.test(c.label))

// ---- EX1: argument + shape checks before any spawn ------------------------------------
{
  const cases = [
    ['extendResult that is not an object (a string)', XA({ extendResult: '/p/prior-result.json' }), /extendResult must be the prior kind:"review" result OBJECT/],
    ['extendResult that is an array', XA({ extendResult: [PRIOR] }), /OBJECT/],
    ['supersedes without extendResult', RA({ supersedes: ['rv-sol'] }), /needs args\.extendResult/],
    ['supersedes that is not a label list', XA({ supersedes: 'rv-sol' }), /supersedes/],
    ['a path-unsafe supersedes label', XA({ supersedes: ['../x'] }), /supersedes/],
    ['a prior that is not kind:"review"', XA({ extendResult: priorWith(p => { p.kind = 'build' }) }), /not a kind:"review" result/],
    ['a prior without base/head shas', XA({ extendResult: priorWith(p => { p.head = 'HEAD' }) }), /no base\/head shas/],
    ['a prior for another repoName', XA({ extendResult: priorWith(p => { p.repoName = 'other' }) }), /repoName/],
    ['a prior from another outDir', XA({ extendResult: priorWith(p => { p.outDir = '/o/elsewhere' }) }), /outDir/],
    ['a prior with no items[]', XA({ extendResult: priorWith(p => { delete p.items }) }), /no items\[\]/],
    ['a prior with no reviewers', XA({ extendResult: priorWith(p => { p.reviewers = [] }) }), /no reviewers\[\]/],
    ['a malformed prior item (no adjudication list)', XA({ extendResult: priorWith(p => { p.items[2].adjudication = 'n/a' }) }), /prior item is malformed/],
    ['a malformed prior item (a non-integer line)', XA({ extendResult: priorWith(p => { p.items[0].line = '3' }) }), /prior item is malformed/],
    ['a malformed prior item (an unknown verdict)', XA({ extendResult: priorWith(p => { p.items[0].verdict = 'maybe' }) }), /prior item is malformed/],
    ['a malformed prior item (foundBy not a list)', XA({ extendResult: priorWith(p => { p.items[0].foundBy = 'rv-opus' }) }), /prior item is malformed/],
    ['duplicate prior item ids', XA({ extendResult: priorWith(p => { p.items[1].id = p.items[0].id }) }), /unique M<n> ids/],
    ['a prior reviewer without a label', XA({ extendResult: priorWith(p => { delete p.reviewers[0].label }) }), /prior reviewer is malformed/],
    ['duplicate prior reviewer labels', XA({ extendResult: priorWith(p => { p.reviewers[1].label = p.reviewers[0].label }) }), /labels are not unique/],
    ['a prior reviewer with an unknown status', XA({ extendResult: priorWith(p => { p.reviewers[0].status = 'weird' }) }), /unknown status/],
    ['a prior item found by a reviewer the prior result does not list', XA({ extendResult: priorWith(p => { p.items[0].foundBy = ['rv-opus', 'rv-nobody'] }) }), /rv-nobody/],
    ['prior flags that are not strings', XA({ extendResult: priorWith(p => { p.flags = [1] }) }), /flags/],
    ['a sha args.head that is not the prior head', XA({ head: 'd'.repeat(40) }), /base\/head mismatch/],
    ['a sha args.base that is not the prior base', XA({ base: 'd'.repeat(40) }), /base\/head mismatch/],
    ['a new reviewer label that collides with a prior one', XA({ reviewers: [{ vendor: 'claude', level: 'deep', label: 'rv-opus' }] }), /collide/],
    ['supersedes naming a label the prior result lacks', XA({ supersedes: ['rv-ghost'] }), /rv-ghost/],
    ['another adjudicator panel than the prior items were judged by', XA({ adjudicators: [{ vendor: 'claude', level: 'deep', label: 'j1' }, { vendor: 'claude', level: 'builder', label: 'j2' }] }), /same panel/],
  ]
  for (const [name, args, re] of cases) {
    const r = await throws(args, XS())
    chk(`EX1: ${name} throws before any spawn`, r.threw && r.calls.length === 0 && /triage-compare/.test(r.message) && re.test(r.message))
    if (!(r.threw && re.test(r.message))) console.log(`  (EX1 ${name}: ${r.threw ? r.message.split('\n')[0] : 'did not throw'})`)
  }
  // The path form is refused, with the single safe way named.
  for (const extend of ['/p/prior-result.json', 'prior.json', `${LIVE}/prior.json`]) {
    const r = await throws(XA({ extend, extendResult: undefined }), XS())
    chk(`EX1: the path form extend:${JSON.stringify(extend)} is refused before any spawn, telling the caller to pass extendResult inline`,
      r.threw && r.calls.length === 0 && /args\.extend \(a path to a prior result\) is refused/.test(r.message) && /never relayed through an LLM/.test(r.message) &&
      /inline, as args\.extendResult/.test(r.message))
  }
  const both = await throws(XA({ extend: '/p/prior-result.json' }), XS())
  chk('EX1: …also when extendResult is passed alongside it', both.threw && both.calls.length === 0 && /args\.extend \(a path/.test(both.message))
  const sha = await run(XA({ base: RB, head: RH }), XS())
  chk('EX1: sha base/head equal to the prior shas pass the up-front check', sha.result.extendedFrom.base === RB && sha.result.extendedFrom.head === RH)
}

// ---- EX2: the snapshot check — refusals after it, before any reviewer ------------------
{
  const refuse = async (name, re, script, args = XA({})) => {
    const r = await throws(args, XS(script))
    chk(`EX2: ${name} is refused before any reviewer runs`, r.threw && re.test(r.message) && /No reviewer ran/.test(r.message) && noReviewer(r.calls))
    return r
  }
  const hm = await refuse('a head that does not resolve to the prior head (base/head mismatch)', /base\/head mismatch/, { 'review:extend-check': [CHECK(PRIOR, { resolvedHead: 'd'.repeat(40) })] })
  chk('EX2: …after one retry of the check (2 check spawns, on triage-quick-task, no snapshot spawn)',
    hm.calls.map(c => c.label).join() === 'review:extend-check,review:extend-check#retry' && hm.calls.every(c => c.opts.agentType === 'triage-quick-task'))
  await refuse('a base that does not resolve to the prior base', /base\/head mismatch/, { 'review:extend-check': [CHECK(PRIOR, { resolvedBase: 'd'.repeat(40) })] })
  await refuse('a missing snapshot (snap/ or range.diff gone)', /snapshot is gone/, { 'review:extend-check': [CHECK(PRIOR, { snapshotExists: false, snapshotOk: false })] })
  await refuse('a manifest whose head is not the prior head', /snapshot is gone/, { 'review:extend-check': [CHECK(PRIOR, { manifestHead: 'e'.repeat(40), snapshotOk: false })] })
  await refuse('a manifest head mismatch even when the relay says snapshotOk', /snapshot is gone/, { 'review:extend-check': [CHECK(PRIOR, { manifestBase: 'e'.repeat(40) })] })
  await refuse('a missing manifest.json (the command printed no JSON)', /snapshot is gone or unreadable/, { 'review:extend-check': [{ ok: false, error: `jq: error: Could not open ${ROUT}/manifest.json` }] })
  await refuse('a dead check spawn (twice)', /snapshot check spawn failed/, { 'review:extend-check': [new Error('spawn died')] })
  const { result } = await run(XA({}), XS({ 'review:extend-check': [CHECK(PRIOR, { snapshotOk: false }), CHECK(PRIOR)] }))
  chk('EX2: a failed check that passes on the retry proceeds', result.extendedFrom.items === 7 && result.newItems.join() === 'M8,M9')
}

// ---- EX3: the prior result never passes through an LLM -----------------------------------
{
  const before = JSON.stringify(PRIOR)
  const r = await run(XA({}), XS())
  const ext = r.calls.filter(c => c.label.startsWith('review:extend'))
  const ck = ext[0]
  const props = Object.keys(ck.opts.schema.properties)
  chk('EX3: exactly ONE extend spawn, and its schema holds only small snapshot scalars (no items, reviewers or digest)',
    ext.length === 1 && props.every(k => ['ok', 'error', 'resolvedBase', 'resolvedHead', 'manifestBase', 'manifestHead', 'snapshotExists', 'snapshotOk',
      'fingerprintExists', 'codexDenied', 'files', 'extras', 'diffBytes', 'snapKB'].includes(k)) && !props.includes('items') && !props.includes('reviewers'))
  chk('EX3: …its prompt carries no prior item text or reviewer label, and stays small',
    PRIOR.items.every(it => !ck.prompt.includes(it.claim)) && PRIOR.reviewers.every(x => !ck.prompt.includes(x.label)) && ck.prompt.length < 2000)
  chk('EX3: the prior items reach the result verbatim from the inline object (text, verdict, adjudication)',
    PRIOR.items.every(p => { const it = r.result.items.find(x => x.id === p.id); return it && it.claim === p.claim && it.verdict === p.verdict && JSON.stringify(it.adjudication) === JSON.stringify(p.adjudication) }))
  chk('EX3: args.extendResult is not mutated by the extension', JSON.stringify(PRIOR) === before)
  const big = priorWith(p => { p.items[0].claim += ' ' + 'x'.repeat(60000) + ' — café → 🔩' })
  const rb = await run(XA({ extendResult: big }), XS())
  chk('EX3: a 60 KB prior result is taken inline (its long non-ASCII claim intact; the check prompt does not grow)',
    rb.result.items.find(it => it.id === 'M1').claim === big.items[0].claim && rb.calls.find(c => c.label === 'review:extend-check').prompt.length < 2000)
}

// ---- EX4: the extension flow ----------------------------------------------------------
const EX = await run(XA({}), XS())
{
  const { calls, result } = EX
  const L = calls.map(c => c.label)
  chk('EX4: the snapshot check first; no snapshot; ONLY the new reviewers run; one merge; adjudication; the fingerprint last',
    L[0] === 'review:extend-check' && !L.includes('review:snapshot') && L.filter(l => l.startsWith('reviewer:')).sort().join() === 'reviewer:rv-astra2,reviewer:rv-new' &&
    L.filter(l => l === 'review:merge').length === 1 && L[L.length - 1] === 'review:fingerprint')
  const ld = calls[0]
  chk('EX4: the check runs one jq -n command over the outDir manifest, snap/, range.diff and the rev-parse of base/head, with the prior shas as args (no input file)',
    ld.prompt.includes(`jq -n -c --arg pb '${RB}' --arg ph '${RH}'`) && ld.prompt.includes(`--slurpfile man '${ROUT}/manifest.json'`) && ld.prompt.includes(`[ -d '${SNAPDIR}' ] && [ -f '${ROUT}/range.diff' ]`) &&
    ld.prompt.includes(`git -C '${LIVE}' rev-parse --verify --quiet 'abc123^{commit}'`) && ld.prompt.includes(`'HEAD^{commit}'`) && !ld.opts.schema.properties.digest && !/prior-result|utf8bytelength/.test(ld.prompt))
  chk('EX4: returns the prior base/head/outDir, extendedFrom, the new item ids and the superseded labels',
    result.kind === 'review' && result.base === RB && result.head === RH && result.outDir === ROUT &&
    JSON.stringify(result.extendedFrom) === JSON.stringify({ base: RB, head: RH, outDir: ROUT, reviewers: PRIOR.reviewers.map(x => x.label), items: 7 }) &&
    result.newItems.join() === 'M8,M9' && result.superseded.join() === 'rv-sol,rv-astra')
  const fp = calls.find(c => c.label === 'review:fingerprint')
  chk('EX4: the re-fingerprint writes fingerprint-extend.json (the prior after-file is kept) and compares with the prior before-file',
    fp.prompt.includes(`--out '${ROUT}/fingerprint-extend.json'`) && fp.prompt.includes(`compare '${ROUT}/fingerprint-before.json' '${ROUT}/fingerprint-extend.json'`) && result.sourceChanged === false)
  const judged = calls.filter(c => /^(reviewer:|review:merge|adjudicate:)/.test(c.label))
  chk('EX4: the live repo path and repo name reach no reviewer, merge or adjudicator prompt', judged.every(c => !c.prompt.includes(LIVE) && !c.prompt.includes('voron')))
  const cx = calls.find(c => c.label === 'reviewer:rv-astra2')
  chk('EX4: a new codex reviewer gets the same header contract (MODE=read, INPUT_DIR = the prior snapshot, TIMEOUT, PROMPT_BYTES)',
    cx.prompt.startsWith(`VENDOR=codex\nMODE=read\nMODEL=gpt-6-astra\nEFFORT=high\nINPUT_DIR=${SNAPDIR}\nTIMEOUT=30m\nPROMPT_BYTES=`))
}

// ---- EX5: merge — attach or new item, blind ---------------------------------------------
{
  const m = EX.calls.find(c => c.label === 'review:merge')
  chk('EX5: the merge sees the prior items (ids, text) and the new findings (opaque ids) — no label, reviewer id, verdict or provenance',
    m.opts.schema.properties.items.items.required.join() === 'members,existing' && /--- EXISTING items \(7\) ---/.test(m.prompt) && /--- NEW findings \(5\) ---/.test(m.prompt) &&
    !/rv-|\bR\d+\b|"verdict"|"foundBy"|"adjudication"|"prov"|codex|claude/.test(m.prompt))
  const r = EX.result
  const M1 = r.items.find(it => it.id === 'M1')
  chk('EX5: a new finding matching an existing item attaches: the new reviewer joins its foundBy; text, verdict and adjudication unchanged',
    M1.foundBy.join() === 'rv-astra2,rv-opus,rv-sol,rv-sonnet' && M1.verdict === 'real' && M1.claim === priorItem('M1').claim &&
    JSON.stringify(M1.adjudication) === JSON.stringify(priorItem('M1').adjudication))
  const M3 = r.items.find(it => it.id === idOf('docs/b.md', 5))
  chk('EX5: an attached DISPUTED item stays disputed with its prior adjudication (no re-adjudication)',
    M3.verdict === 'disputed' && M3.foundBy.join() === 'rv-new,rv-sonnet' && JSON.stringify(M3.adjudication) === JSON.stringify(priorItem(M3.id).adjudication))
  chk('EX5: prior ids are kept as they were; new items get the next ids (M8, M9) in location order',
    r.items.slice(0, 7).map(it => `${it.id}:${it.file}:${it.line}`).join() === RV.result.items.map(it => `${it.id}:${it.file}:${it.line}`).join() &&
    r.items.slice(7).map(it => `${it.id}:${it.file}:${it.line}`).join() === 'M8:docs/d.md:4,M9:docs/e.md:2' &&
    r.items.find(it => it.id === 'M8').foundBy.join() === 'rv-astra2,rv-new')
}

// ---- EX6: only new items are adjudicated, blind -------------------------------------------
{
  const adj = EX.calls.filter(c => c.label.startsWith('adjudicate:'))
  chk('EX6: each adjudicator judges ONLY the new items (M8, M9) — never an attached prior item',
    adj.length === 2 && adj.every(c => blindItems(c.prompt).map(it => it.id).join() === 'M8,M9'))
  chk('EX6: …blind: no reviewer label, reviewer id or provenance in the adjudicator prompts',
    adj.every(c => !/rv-|\bR\d+\b|"prov"|"members"|"foundBy"|[Ff]ound by|reported by \d/.test(c.prompt)))
  const r = EX.result
  chk('EX6: new items get the combined verdict (real / rejected) with both adjudications',
    r.items.find(it => it.id === 'M8').verdict === 'real' && r.items.find(it => it.id === 'M9').verdict === 'rejected' &&
    r.items.find(it => it.id === 'M8').adjudication.length === 2 && r.disputed.join() === RV.result.disputed.join())
}

// ---- EX7: rescoring — superseded kept but unscored; recall over the combined set --------
{
  const r = EX.result
  const sol = rvRev(r, 'rv-sol')
  chk('EX7: a superseded reviewer is kept with status superseded, no precision/recall, its findings count and prior status kept',
    sol.status === 'superseded' && sol.precision === null && sol.recall === null && sol.real === null && sol.findings === 4 && sol.priorStatus === 'ok' &&
    rvRev(r, 'rv-astra').status === 'superseded' && rvRev(r, 'rv-astra').priorStatus === 'unavailable')
  chk('EX7: …and its findings stay in the items with provenance intact (docs/c.md:1 found only by rv-sol)',
    r.items.find(it => it.id === idOf('docs/c.md', 1)).foundBy.join() === 'rv-sol' && r.items.length === 9)
  chk('EX7: recall is recomputed for prior reviewers over the combined real set (3): opus 2/3, sonnet 1/3; precision unchanged',
    near(rvRev(r, 'rv-opus').recall, 2 / 3) && near(rvRev(r, 'rv-sonnet').recall, 1 / 3) && near(rvRev(r, 'rv-opus').precision, 1) && near(rvRev(r, 'rv-sonnet').precision, 0.5))
  chk('EX7: new reviewers are scored over the combined set: astra2 2/2 precision, 2/3 recall; new 1/2, 1/3',
    near(rvRev(r, 'rv-astra2').precision, 1) && near(rvRev(r, 'rv-astra2').recall, 2 / 3) && rvRev(r, 'rv-astra2').findings === 2 && rvRev(r, 'rv-astra2').tokens === 900 &&
    near(rvRev(r, 'rv-new').precision, 0.5) && near(rvRev(r, 'rv-new').recall, 1 / 3))
  chk('EX7: a prior unavailable reviewer that is not superseded stays unavailable, never zero', rvRev(r, 'rv-bad').status === 'unavailable' && rvRev(r, 'rv-bad').precision === null)
  chk('EX7: reviewer rows: the prior ones in their order, then the new ones', r.reviewers.map(x => x.label).join() === 'rv-sonnet,rv-opus,rv-sol,rv-astra,rv-bad,rv-astra2,rv-new')
}

// ---- EX8: markdown for the combined set ----------------------------------------------------
{
  const md = EX.result.markdown
  chk('EX8: the markdown says what extended it (reviewers, source, attached vs new, superseded)',
    md.includes(`Extended with rv-astra2, rv-new (prior result: 7 item(s) by rv-sonnet, rv-opus, rv-sol, rv-astra, rv-bad): 5 new finding(s) — 2 attached to prior items (not re-adjudicated), 2 new item(s) (M8, M9). Superseded: rv-sol, rv-astra.`))
  chk('EX8: …and lists the combined items and a score row per reviewer, superseded included',
    md.includes('## Real findings (3)') && md.includes('### docs/d.md') && /\| rv-sol \| codex \| gpt-6-sol \| medium \| superseded \| 4 \|/.test(md) && /\| rv-astra2 \| codex \|/.test(md) &&
    md.includes('Reviewers: 7 (1 unavailable, 2 superseded)'))
}

// ---- EX9: no new findings, a dead merge -----------------------------------------------------
{
  const { result, calls } = await run(XA({ supersedes: [] }), XS({ 'reviewer:rv-astra2': ['UNAVAILABLE: codex timed out after 30m'], 'reviewer:rv-new': [{ findings: [] }] }))
  chk('EX9: new reviewers with no findings → no merge, no adjudication; prior items as they were; recall unchanged',
    !calls.some(c => /review:merge|adjudicate:/.test(c.label)) && result.items.length === 7 && result.newItems.length === 0 &&
    near(rvRev(result, 'rv-opus').recall, 1) && rvRev(result, 'rv-astra2').status === 'unavailable' && result.superseded.length === 0)
  const { result: r2, calls: c2 } = await run(XA({}), XS({ 'review:merge': [null] }))
  chk('EX9: a dead merge (twice) → every new finding a new item of its own (nothing attached), all of them adjudicated, flagged',
    r2.mergeFallback === true && r2.newItems.length === 5 && r2.items.find(it => it.id === 'M1').foundBy.join() === 'rv-opus,rv-sol,rv-sonnet' &&
    c2.filter(c => c.label.startsWith('adjudicate:claude')).every(c => blindItems(c.prompt).every(it => Number(it.id.slice(1)) >= 8)) &&
    r2.flags.some(f => /none attached to a prior item/.test(f)))
  const bogus = p => ({ items: [{ members: EXT_MERGE(p).items.flatMap(x => x.members), existing: 'M99' }] })
  const { result: r3 } = await run(XA({}), XS({ 'review:merge': [bogus] }))
  chk('EX9: attaching to an id that is no prior item makes a new item instead (flagged)', r3.newItems.length === 1 && r3.flags.some(f => /no prior item/.test(f)))
}

// ---- EX10: the snapshot check's REAL command, with an inline synthetic prior ----------------------------
// Runs the jq/git command the snapshot-check spawn is told to run, with bash, against a
// temp git repo + outDir, with the prior result inline — proving the check's JSON satisfies
// the workflow on an intact snapshot and that the snapshot/base-head refusals fire.
{
  const tmp = mkdtempSync(join(tmpdir(), 'tc-extend-'))
  try {
    const repo = join(tmp, 'repo')
    const out = join(tmp, 'out')
    const g = (...xs) => execFileSync('git', ['-C', repo, ...xs], { encoding: 'utf8' }).trim()
    mkdirSync(repo)
    g('init', '-q')
    writeFileSync(join(repo, 'a.md'), 'one\n')
    g('add', '.'); g('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base')
    const baseSha = g('rev-parse', 'HEAD')
    writeFileSync(join(repo, 'a.md'), 'two\n')
    g('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'head')
    const headSha = g('rev-parse', 'HEAD')
    mkdirSync(join(out, 'snap'), { recursive: true })
    writeFileSync(join(out, 'snap', 'a.md'), 'two\n')
    writeFileSync(join(out, 'range.diff'), 'diff\n')
    writeFileSync(join(out, 'fingerprint-before.json'), '{}\n')
    writeFileSync(join(out, 'manifest.json'), JSON.stringify({ base: baseSha, head: headSha, files: ['a.md', 'b.md'], extras: [], codexDenied: false }))
    const prior = JSON.parse(JSON.stringify(RV.result))
    Object.assign(prior, { base: baseSha, head: headSha, outDir: out })
    prior.items[0].claim += ' — café → 🔩'
    prior.items[0].adjudication[1].evidence = null
    const REAL_CHECK = p => {
      try { return JSON.parse(execFileSync('bash', ['-c', p.split('\n').pop()], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })) } catch (e) { return { ok: false, error: String(e.stderr || e.message).trim().split('\n').pop() } }
    }
    // base/head as revision NAMES, so the real rev-parse is what resolves them.
    const args = extra => RA(Object.assign({ repo, base: 'HEAD~1', head: 'HEAD', outDir: out, extendResult: prior, supersedes: [], reviewers: [{ vendor: 'claude', level: 'deep', label: 'rv-real' }] }, extra))
    const script = { 'review:extend-check': [REAL_CHECK], 'reviewer:rv-real': [{ findings: [] }], 'review:fingerprint': [{ rc: 0, same: true, changed: [], headMoved: false, detail: 'SAME' }] }
    const ok = await throws(args({}), script)
    let res = null
    if (!ok.threw) res = (await run(args({}), script)).result
    chk('EX10: the real check command passes an inline prior (non-ASCII text, a null evidence kept) on an intact snapshot; its manifest scalars reach the markdown',
      !ok.threw && res && res.items.length === 7 && res.items[0].claim === prior.items[0].claim && res.items[0].adjudication[1].evidence === null &&
      res.extendedFrom.head === headSha && rvRev(res, 'rv-opus').precision === 1 && res.markdown.includes('Snapshot: 2 file(s), range diff 5 bytes'))
    if (ok.threw) console.log(`  (EX10 threw: ${ok.message.split('\n')[0]})`)
    const hm = await throws(args({ head: 'HEAD~1' }), script)
    chk('EX10: …a head that resolves elsewhere is refused (real rev-parse)', hm.threw && /base\/head mismatch/.test(hm.message) && noReviewer(hm.calls))
    writeFileSync(join(out, 'manifest.json'), JSON.stringify({ base: baseSha, head: baseSha, files: [], extras: [] }))
    const wrongMan = await throws(args({}), script)
    chk('EX10: …a manifest of another head is refused (real jq)', wrongMan.threw && /snapshot is gone or is not the prior/.test(wrongMan.message) && noReviewer(wrongMan.calls))
    rmSync(join(out, 'manifest.json'))
    const noMan = await throws(args({}), script)
    chk('EX10: …a missing manifest.json is refused (real jq --slurpfile)', noMan.threw && /snapshot is gone or unreadable/.test(noMan.message) && noReviewer(noMan.calls))
    writeFileSync(join(out, 'manifest.json'), JSON.stringify({ base: baseSha, head: headSha, files: [], extras: [] }))
    rmSync(join(out, 'range.diff'))
    const gone = await throws(args({}), script)
    chk('EX10: …and a snapshot missing its range.diff is refused (real test -f)', gone.threw && /snapshot is gone/.test(gone.message) && noReviewer(gone.calls))
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

console.log('')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
