export const meta = {
  name: 'triage-parity',
  description: 'Parity research run: every candidate (vendor x model x effort) climbs a private task suite band by band (B1 mechanical to B4 danger/judgment), each build task graded by a nested triage-compare bake-off, rubric tasks by two blind judges, review tasks by seeded-defect recall/precision. Returns a ranking, plateau clusters and flags; never writes tiers.json or anything outside outDir. Tier-change proposals are not made here: the orchestrator saves the result, runs scripts/parity-report.sh ingest-parity, then report (the ONE owner of the ledger and the decision rule).',
  whenToUse: 'Re-rank models and efforts when a model ships or on request: /triage-parity with args = {suite:"/abs task suite dir", outDir:"/abs fresh dir outside any source repo", candidates:[{vendor:claude|codex, level:quick|builder|deep|top, model?, effort?, label?}] (agy was retired 2026-09-24 and is refused, as a candidate and as a judge), bands?:[1,2,3,4], reps?:1, stopAfterFailedBands?:2, bandPassRate?:0.5, judges?:[{vendor,level,label?}], taskFilter?:[ids], desk?:true}. Adaptive: a candidate stops after stopAfterFailedBands consecutive failed bands. unavailable/denied/invalid/unresolved never count as pass or fail; a compare LEAK aborts the run. Every task with a git source (build, rubric, review) is fingerprinted (parity-suite.sh fingerprint) before its candidates run and after grading: a change voids that task (invalid, flag SOURCE_CHANGED <repo>: HEAD moved|tree changed|ignored files changed|refs/config/hooks changed) and the run continues; a generator task has no source repo and is marked guarded:false in tasks[]. Rubric judges get only the staged patch + key. Afterwards: parity-report.sh ingest-parity --result <saved result> then parity-report.sh report proposes any tiers.json change (min-n + margin rule; Alex approves); Claude cost per candidate comes from scripts/parity-cost.sh on the run transcript.',
  phases: [
    { title: 'Load' },
    { title: 'Desk' },
    { title: 'Band 1' },
    { title: 'Band 2' },
    { title: 'Band 3' },
    { title: 'Band 4' },
  ],
}

// ─── Entry contract ─────────────────────────────────────────────────────────
// A parity run is a measurement that can spend a lot, so everything that could
// make it unfair or unsafe is rejected in plain JS before any spawn.
const LEVELS = ['quick', 'builder', 'deep', 'top']
const VENDORS = ['claude', 'codex']
// agy was retired 2026-09-24 (its headless mode let the model bypass its sandbox; a
// parity review run wrote into a real repo): refused by name for candidates and judges.
const RETIRED_VENDORS = { agy: 'agy was retired 2026-09-24 (it bypassed its own sandbox and wrote into a real repo) — use codex or claude' }
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
// The Claude agent serving each level — the SAME map as triage-exec.js and
// triage-compare.js; test/lint.sh checks it against config/tiers.json.
const CLAUDE_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', top: 'triage-fable-architect' }
const PARITY_SUITE = '~/.claude/scripts/parity-suite.sh'
// The ledger + tier-change decision rule (min-n, Wilson bound, margins, the
// cheapness order) live ONLY in scripts/parity-report.sh; this run measures.
const PARITY_REPORT = '~/.claude/scripts/parity-report.sh'
// Grading thresholds.
const REVIEW_RECALL = 0.6
const REVIEW_PRECISION = 0.5
const JUDGE_PASS = 0.7
const JUDGE_SPREAD = 0.3
const GRADED = ['pass', 'fail']

const USAGE = 'Expected args = {\n' +
  '  suite: "/abs/suite"          // <suite>/<band>/<id>/task.json (scripts/README.md, parity-suite.sh)\n' +
  '  outDir: "/abs/dir"           // fresh, outside any source repo and the suite; everything this run writes goes here\n' +
  `  candidates: [{ vendor: ${VENDORS.join('|')}, level: ${LEVELS.join('|')}, model?, effort?: ${EFFORTS.join('|')}, label? }]\n` +
  '  bands?: [1,2,3,4], reps?: 1, stopAfterFailedBands?: 2, bandPassRate?: 0.5,\n' +
  '  judges?: [{vendor:"claude",level:"deep"},{vendor:"codex",level:"deep"}], taskFilter?: [ids],\n' +
  '  desk?: true\n}'

function bad(msg) {
  throw new Error(`triage-parity: ${msg}\n${USAGE}`)
}

const isStr = v => typeof v === 'string' && v.trim().length > 0
const typeName = v => (v === null ? 'null' : Array.isArray(v) ? 'an array' : typeof v)
const isAbsPath = v => isStr(v) && v.startsWith('/') && !/[\s'"`$\\]/.test(v)
const SAFE_TOKEN = /^[A-Za-z0-9._+-]+$/
const stripSlash = v => String(v).replace(/\/+$/, '')
const within = (a, b) => a === b || a.startsWith(`${b}/`)
const isInt = v => typeof v === 'number' && Number.isInteger(v)

if (!args || typeof args !== 'object' || Array.isArray(args)) bad(`args must be an object (got ${typeName(args)}).`)
if (!isAbsPath(args.suite)) bad('args.suite must be an absolute path with no whitespace or quotes.')
if (!isAbsPath(args.outDir)) bad('args.outDir must be an absolute path with no whitespace or quotes.')
const suite = stripSlash(args.suite.trim())
const outDir = stripSlash(args.outDir.trim())
if (within(outDir, suite) || within(suite, outDir)) bad('args.outDir must not overlap args.suite — the suite (hidden tests, keys) is never written.')
if (!Array.isArray(args.candidates) || args.candidates.length === 0) bad('args.candidates must be a non-empty array.')
if (args.bands != null && !(Array.isArray(args.bands) && args.bands.length > 0 && args.bands.every(b => [1, 2, 3, 4].includes(b)) && new Set(args.bands).size === args.bands.length)) {
  bad(`args.bands must be a non-empty list of distinct bands from 1..4 (got ${JSON.stringify(args.bands)}).`)
}
if (args.reps != null && !(isInt(args.reps) && args.reps >= 1 && args.reps <= 5)) bad(`args.reps must be an integer 1..5 (got ${JSON.stringify(args.reps)}).`)
if (args.stopAfterFailedBands != null && !(isInt(args.stopAfterFailedBands) && args.stopAfterFailedBands >= 1)) bad('args.stopAfterFailedBands must be an integer >= 1.')
if (args.bandPassRate != null && !(typeof args.bandPassRate === 'number' && args.bandPassRate > 0 && args.bandPassRate <= 1)) bad('args.bandPassRate must be a number in (0, 1].')
if (args.taskFilter != null && !(Array.isArray(args.taskFilter) && args.taskFilter.every(isStr))) bad('args.taskFilter must be an array of task ids.')
if (args.desk != null && typeof args.desk !== 'boolean') bad('args.desk must be true or false.')

const bands = (args.bands || [1, 2, 3, 4]).slice().sort((a, b) => a - b)
const reps = args.reps || 1
const stopAfter = args.stopAfterFailedBands || 2
const passRate = args.bandPassRate || 0.5

function checkAgentSpec(raw, what, i) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`${what}[${i}] must be an object (got ${typeName(raw)}).`)
  if (typeof raw.vendor === 'string' && Object.prototype.hasOwnProperty.call(RETIRED_VENDORS, raw.vendor)) bad(`${what}[${i}].vendor ${JSON.stringify(raw.vendor)}: ${RETIRED_VENDORS[raw.vendor]}.`)
  if (!VENDORS.includes(raw.vendor)) bad(`${what}[${i}].vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(raw.vendor)}).`)
  if (!LEVELS.includes(raw.level)) bad(`${what}[${i}].level must be one of ${LEVELS.join('|')} (got ${JSON.stringify(raw.level)}).`)
  if (raw.effort != null && !EFFORTS.includes(raw.effort)) bad(`${what}[${i}].effort must be one of ${EFFORTS.join('|')} (got ${JSON.stringify(raw.effort)}).`)
  if (raw.model != null && !(isStr(raw.model) && SAFE_TOKEN.test(raw.model))) bad(`${what}[${i}].model must be a model id with no spaces (got ${JSON.stringify(raw.model)}).`)
  if (raw.label != null && !isStr(raw.label)) bad(`${what}[${i}].label must be a non-empty string when given.`)
  const label = raw.label ? raw.label.trim()
    : `${raw.vendor}-${raw.level}${raw.model ? `-${raw.model}` : ''}${raw.effort ? `-${raw.effort}` : ''}`
  // Labels name patch files, compare candidates and transcript labels
  // (candidate:<label>[@task]); -r<N> is reserved for repetitions.
  if (!SAFE_TOKEN.test(label)) bad(`${what}[${i}]: label ${JSON.stringify(label)} must use only letters, digits, . _ + - — pass an explicit label.`)
  if (/-r\d+$/.test(label)) bad(`${what}[${i}]: label ${JSON.stringify(label)} ends in -r<N>, which is reserved for repetitions.`)
  return { label, vendor: raw.vendor, level: raw.level, model: raw.model || null, effort: raw.effort || null }
}

const candidates = args.candidates.map((raw, i) => checkAgentSpec(raw, 'candidates', i))
{
  const seen = new Set()
  for (const c of candidates) {
    if (seen.has(c.label)) bad(`duplicate candidate label "${c.label}" — labels must be unique.`)
    seen.add(c.label)
  }
}
if (args.judges != null && !(Array.isArray(args.judges) && args.judges.length > 0)) bad('args.judges must be a non-empty array when given.')
const judges = (args.judges || [{ vendor: 'claude', level: 'deep' }, { vendor: 'codex', level: 'deep' }]).map((raw, i) => checkAgentSpec(raw, 'judges', i))
if (new Set(judges.map(j => j.label)).size !== judges.length) bad('judge labels must be unique.')
// Proposals moved to scripts/parity-report.sh (incumbents = config/tiers.json
// levels there): an incumbents arg would silently do nothing, so it is refused.
if (args.incumbents != null) bad('args.incumbents is no longer accepted: the incumbents are config/tiers.json levels, and tier-change proposals come from scripts/parity-report.sh report after ingest-parity.')

// ─── Helpers ────────────────────────────────────────────────────────────────
const shq = s => `'${String(s).replace(/'/g, `'\\''`)}'`
const errText = e => String((e && e.message) || e).slice(0, 300)
const SHA_RE = /^[0-9a-f]{40}([0-9a-f]{24})?$/
const producedNothing = out => out == null || /^\s*(UNAVAILABLE|REFUSED)\b/i.test(String(out).trimStart())
const firstLine = out => String(out || '').trimStart().split('\n')[0]
const flags = []
const flag = msg => { flags.push(msg); log(`⚠ ${msg}`) }
// Deterministic, label-blind ordering for anonymized patch ids (FNV-1a).
function hashStr(s) {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 }
  return h
}
// The first JSON object in an external reply (after its CROSS-REVIEW header).
function parseJsonObject(text) {
  const body = String(text || '').split('\n').filter(l => !/^\s*(CROSS-REVIEW|ext-run:)/.test(l)).join('\n')
  const tries = []
  const a = body.indexOf('{')
  const b = body.lastIndexOf('}')
  if (a >= 0 && b > a) tries.push(body.slice(a, b + 1))
  for (const m of body.matchAll(/```(?:json)?\s*([\s\S]*?)```/g)) tries.push(m[1])
  for (const t of tries) {
    try { const v = JSON.parse(t); if (v && typeof v === 'object') return v } catch (e) { /* next */ }
  }
  return null
}
const taskDirOf = t => stripSlash(t.taskDir)
const bandDir = (b, t) => `${outDir}/${b}/${t.id}`


// ─── Load ───────────────────────────────────────────────────────────────────
phase('Load')
const TASK_ITEM = {
  type: 'object',
  properties: {
    id: { type: 'string' }, band: { type: 'integer' }, kind: { type: 'string', enum: ['build', 'review'] },
    taskDir: { type: 'string' }, brief: { type: 'string' }, files: { type: 'array', items: { type: 'string' } },
    acceptance: { type: 'string' }, checks: { type: 'array', items: { type: 'string' } },
    overlay: { type: ['string', 'null'] }, grading: { type: 'string', enum: ['check', 'rubric', 'seeded'] },
    key: { type: ['string', 'null'] }, vendors: { type: 'array', items: { type: 'string' } },
    timeoutMin: { type: ['number', 'null'] }, selfCheckEnv: { type: ['boolean', 'null'] },
    source: { type: 'object', properties: { type: { type: 'string' } } },
  },
  required: ['id', 'band', 'kind', 'taskDir', 'brief', 'files', 'acceptance', 'grading', 'vendors'],
}
const LOAD_SCHEMA = { type: 'object', properties: { tasks: { type: 'array', items: TASK_ITEM }, rc: { type: ['integer', 'null'] } }, required: ['tasks'] }
const loadCmd = `${PARITY_SUITE} list --suite ${shq(suite)}`
const taskOk = t => t && isStr(t.id) && SAFE_TOKEN.test(t.id) && [1, 2, 3, 4].includes(t.band) && ['build', 'review'].includes(t.kind) &&
  isAbsPath(t.taskDir) && within(stripSlash(t.taskDir), suite) && isStr(t.brief) && isStr(t.acceptance) &&
  Array.isArray(t.files) && t.files.length > 0 && t.files.every(isStr) && Array.isArray(t.vendors) && t.vendors.length > 0 &&
  ['check', 'rubric', 'seeded'].includes(t.grading) && (t.kind !== 'build' || (Array.isArray(t.checks) && t.checks.length > 0 && t.checks.every(isStr))) &&
  (t.grading === 'check' || isStr(t.key)) && (t.overlay == null || (isStr(t.overlay) && !t.overlay.startsWith('/') && !t.overlay.split('/').includes('..')))
let loaded = null
for (let attempt = 1; attempt <= 2 && !loaded; attempt++) {
  let r = null
  try {
    r = await agent(`Run this one command exactly as written. It prints one JSON array on stdout. Return tasks = that array, every element field for field (omit none, add none), and rc = its exit status. Do not run anything else, and do not interpret or fix anything.\n${loadCmd}`,
      { phase: 'Load', agentType: 'triage-quick-task', label: attempt === 1 ? 'load:suite' : 'load:suite#retry', schema: LOAD_SCHEMA })
  } catch (e) {
    r = null
  }
  if (r && Array.isArray(r.tasks) && r.tasks.length > 0 && r.tasks.every(taskOk) && new Set(r.tasks.map(t => t.id)).size === r.tasks.length) loaded = r.tasks
}
if (!loaded) throw new Error(`triage-parity: could not load a valid task list from ${suite} (run: ${loadCmd}) — nothing was run.`)
let tasks = loaded
if (args.taskFilter) {
  const want = new Set(args.taskFilter.map(s => s.trim()))
  const missing = [...want].filter(id => !tasks.some(t => t.id === id))
  if (missing.length) flag(`taskFilter names unknown task(s): ${missing.join(', ')}`)
  tasks = tasks.filter(t => want.has(t.id))
  log(`taskFilter kept ${tasks.length} of ${loaded.length} task(s); dropped: ${loaded.filter(t => !want.has(t.id)).map(t => t.id).join(', ') || 'none'}.`)
}
const outOfBand = tasks.filter(t => !bands.includes(t.band))
if (outOfBand.length) log(`bands ${bands.join(',')} selected; not run: ${outOfBand.map(t => `${t.id} (B${t.band})`).join(', ')}.`)
tasks = tasks.filter(t => bands.includes(t.band))
if (reps > 1 && tasks.some(t => t.kind === 'review')) log(`reps=${reps} applies to build tasks only; review tasks run once.`)

// ─── Desk research (signal only, never scored) — runs alongside the bands ───
const deskModels = [...new Set(candidates.map(c => `${c.vendor}:${c.model || `${c.level}-level default`}${c.effort ? `@${c.effort}` : ''}`))]
const deskPrompt = vendor => `VENDOR=${vendor}\nMODE=verify\n` +
  'The data boundary has been checked by the orchestrator: this question contains only public model names, no repository or private material.\n\n' +
  `Question: for each of these models, what are the current published benchmark results (coding / agentic / reasoning), list pricing per million input and output tokens, and the meaning of their reasoning-effort settings? Models: ${deskModels.join(', ')}. Cite each source with its date; say "unknown" rather than guessing.`
const deskRun = args.desk === false ? Promise.resolve(null) : parallel(['codex'].map(v => () =>
  agent(deskPrompt(v), { phase: 'Desk', agentType: 'triage-cross-reviewer', label: `desk:${v}` })))

// ─── Per-task work ──────────────────────────────────────────────────────────
// A source fingerprint (parity-suite.sh fingerprint): git sources carry name,
// head, tree, ignored (gitignored files) and refs (refs/stash/config/hooks); a
// generator source has nothing to guard (guarded:false — the task is unguarded).
const FP_SCHEMA = {
  type: 'object',
  properties: { id: { type: 'string' }, source: { type: 'string', enum: ['git', 'generator'] }, guarded: { type: 'boolean' }, name: { type: 'string' }, head: { type: 'string' }, tree: { type: 'string' }, ignored: { type: 'string' }, refs: { type: 'string' }, rc: { type: ['integer', 'null'] } },
  required: ['source'],
}
const MAT_SCHEMA = {
  type: 'object',
  properties: {
    fingerprint: FP_SCHEMA,
    repo: { type: 'string' }, sha: { type: 'string' },
    denied: { type: 'object', properties: { codex: { type: 'boolean' } }, required: ['codex'] },
    rc: { type: ['integer', 'null'] },
  },
  required: ['fingerprint', 'repo', 'sha', 'denied'],
}
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: { findings: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, line: { type: 'integer' }, desc: { type: 'string' } }, required: ['file', 'line', 'desc'] } } },
  required: ['findings'],
}
const SCORE_SCHEMA = {
  type: 'object',
  properties: { scores: { type: 'array', items: { type: 'object', properties: { label: { type: 'string' }, recall: { type: ['number', 'null'] }, precision: { type: ['number', 'null'] }, matched: { type: 'array', items: { type: 'string' } } }, required: ['label', 'recall', 'precision'] } } },
  required: ['scores'],
}
const JUDGE_SCHEMA = { type: 'object', properties: { score: { type: 'number' }, rationale: { type: 'string' } }, required: ['score'] }
const OK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, rc: { type: ['integer', 'null'] } }, required: ['ok'] }

let leakAbort = null
const fableLog = (who, label) => log(`⚠ Escalating to Fable: parity ${who} ${label}`)

// One result row per (task, candidate run).
const row = (c, runLabel, status, extra) => Object.assign({ label: c.label, runLabel, vendor: c.vendor, status, reason: null, totalTokens: null, seconds: null }, extra || {})

// ─── Source-repo leak guard (every task kind) ───────────────────────────────
// Staging and deny markers only control what a candidate is HANDED, not what it
// can reach: each git source.repo is fingerprinted before the task's candidates
// run (in the materialize spawn, BEFORE materializing) and again after grading.
const fpCmd = t => `${PARITY_SUITE} fingerprint --task ${shq(taskDirOf(t))}`
const FP_HASH = /^[0-9a-f]{40}([0-9a-f]{24})?$/
function fpOk(fp, t) {
  if (!fp || typeof fp !== 'object') return false
  // The loaded task says which kind of source it has; a reply may not downgrade it.
  if (t.source && isStr(t.source.type) && t.source.type !== fp.source) return false
  if (fp.source === 'generator') return true
  return fp.source === 'git' && isStr(fp.name) && typeof fp.head === 'string' && (fp.head === '' || SHA_RE.test(fp.head)) &&
    FP_HASH.test(String(fp.tree || '')) && FP_HASH.test(String(fp.ignored || '')) && FP_HASH.test(String(fp.refs || ''))
}

async function materialize(t, b) {
  const out = `${bandDir(b, t)}/mat`
  const cmd = `${PARITY_SUITE} materialize --task ${shq(taskDirOf(t))} --out ${shq(out)}`
  let r = null
  try {
    r = await agent('Run these two commands in order, each exactly as written. Do not run anything else, and do not interpret or fix anything. ' +
      'Return fingerprint = the FIRST command\'s stdout JSON object field for field; then repo, sha and denied field for field from the SECOND command\'s stdout JSON object, plus rc = the second command\'s exit status.\n' +
      `${fpCmd(t)}\n${cmd}`,
      { phase: `Band ${b}`, agentType: 'triage-quick-task', label: `materialize:${t.id}`, schema: MAT_SCHEMA })
  } catch (e) {
    return { error: errText(e) }
  }
  // The path used is always the computed one; the reply only proves it was made.
  if (!r || stripSlash(String(r.repo || '')) !== `${out}/repo` || !SHA_RE.test(String(r.sha || '').trim()) || !r.denied ||
      typeof r.denied.codex !== 'boolean') {
    return { error: `materialize returned ${JSON.stringify(r).slice(0, 200)}` }
  }
  if (!fpOk(r.fingerprint, t)) return { error: `no valid source fingerprint before the run (${JSON.stringify(r.fingerprint || null).slice(0, 160)})` }
  return { repo: `${out}/repo`, sha: r.sha.trim(), denied: r.denied, fp: r.fingerprint }
}

// sourceGuard(t, b, rows) — SINGLE OWNER of the source-change verdict. Re-
// fingerprints t's git source after grading (one retry); any difference, or no
// usable fingerprint, voids every row of the task (invalid, never pass or fail)
// and flags it — the run continues (a concurrent human commit is possible: the
// flag tells the orchestrator to investigate).
async function sourceGuard(t, b, rows) {
  const before = t.mat.fp
  let after = null
  for (let attempt = 1; attempt <= 2 && !after; attempt++) {
    try {
      const r = await agent(`Run this one command exactly as written and return its stdout JSON object field for field, plus rc = its exit status. Do not run anything else, and do not interpret or fix anything.\n${fpCmd(t)}`,
        { phase: `Band ${b}`, agentType: 'triage-quick-task', label: attempt === 1 ? `source:after@${t.id}` : `source:after@${t.id}#retry`, schema: FP_SCHEMA })
      if (fpOk(r, t) && r.source === 'git') after = r
    } catch (e) {
      after = null
    }
  }
  const what = after ? [after.head !== before.head ? 'HEAD moved' : null, after.tree !== before.tree ? 'tree changed' : null,
    after.ignored !== before.ignored ? 'ignored files changed' : null, after.refs !== before.refs ? 'refs/config/hooks changed' : null].filter(Boolean).join(', ') : null
  if (after && !what) return rows
  const reason = after ? `SOURCE_CHANGED ${before.name}: ${what}` : `SOURCE_UNVERIFIED ${before.name}: could not re-fingerprint the source repo after grading`
  flag(`${reason} (task ${t.id}) — every result of the task is invalid; investigate the source repo before trusting anything from it`)
  return rows.map(r => (['skipped', 'denied'].includes(r.status) ? r : Object.assign({}, r, { status: 'invalid', reason })))
}

async function judgeTask(t, b, rows) {
  // Every graded (pass or fail) candidate's patch is judged blind: patches are
  // copied to anonymized ids in a label-blind hash order, and no judge prompt
  // names a candidate.
  const graded = rows.filter(r => GRADED.includes(r.status) && r.patch)
  if (!graded.length) return
  const jd = `${bandDir(b, t)}/judge`
  const order = graded.slice().sort((x, y) => hashStr(`${t.id}:${x.runLabel}`) - hashStr(`${t.id}:${y.runLabel}`) || (x.runLabel < y.runLabel ? -1 : 1))
  order.forEach((r, i) => { r.anon = `s${i + 1}` })
  // JUDGES GET ONLY THE PATCH AND THE KEY: each anonymized patch gets a fresh dir
  // under outDir holding exactly <anon>.patch and a copy of the key — no repo, no
  // task dir, no other patch is ever named to a judge.
  const keyName = `key${(String(t.key).match(/\.[A-Za-z0-9]+$/) || [''])[0]}`
  const staged = r => ({ patch: `${jd}/${r.anon}/${r.anon}.patch`, key: `${jd}/${r.anon}/${keyName}` })
  const copyCmd = `mkdir -p ${order.map(r => shq(`${jd}/${r.anon}`)).join(' ')} && ` +
    order.map(r => `cp ${shq(r.patch)} ${shq(staged(r).patch)} && cp ${shq(`${taskDirOf(t)}/${t.key}`)} ${shq(staged(r).key)}`).join(' && ')
  let copied = null
  try {
    copied = await agent(`Run this one command exactly as written and return ok = true if it exited 0, and rc = its exit status. Do not run anything else.\n${copyCmd}`,
      { phase: `Band ${b}`, agentType: 'triage-quick-task', label: `judge:copy@${t.id}`, schema: OK_SCHEMA })
  } catch (e) {
    copied = null
  }
  if (!copied || copied.ok !== true) {
    for (const r of graded) { r.status = 'unresolved'; r.reason = 'could not stage anonymized patches for the judges' }
    flag(`${t.id}: judges not run (patch staging failed) — ${graded.length} candidate(s) unresolved`)
    return
  }
  const spec = `Task brief given to the candidates:\n${t.brief}\n\nAcceptance criteria:\n${t.acceptance}\n\n` +
    `Grade how fully and correctly the patch meets the brief, against the grading key (the ground truth). Score 0..1: 1 = fully correct and complete, 0.7 = acceptable with minor gaps, below 0.5 = wrong or incomplete. You do not know who wrote the patch; do not guess.`
  const ONLY_TWO = 'Read only these two files; do not cd anywhere or read, list or search any other path. You have no repository access: grade from the patch and the key alone.'
  const jobs = []
  for (const j of judges) {
    for (const r of order) {
      const { patch: patchPath, key: keyPath } = staged(r)
      jobs.push({ j, r, run: () => {
        if (j.vendor === 'claude') {
          return agent(`${spec}\n\nYour two files (read-only; change nothing):\n  patch: ${patchPath}\n  key:   ${keyPath}\n${ONLY_TWO}\n\nReturn score (0..1) and a one-paragraph rationale.`,
            Object.assign({ phase: `Band ${b}`, agentType: CLAUDE_AGENT[j.level], label: `judge:${j.label}@${t.id}:${r.anon}`, schema: JUDGE_SCHEMA },
              j.model ? { model: j.model } : {}, j.effort ? { effort: j.effort } : {}))
        }
        return agent(`VENDOR=${j.vendor}\nMODE=review\n` +
          'The data boundary has been checked by the orchestrator for this material (a synthetic or cleared parity task).\n' +
          `Pass exactly these two files to ext-run.sh, and nothing else: --input ${patchPath} --input ${keyPath}\n${ONLY_TWO}\n\n${spec}\n\n` +
          'Output ONLY one JSON object: {"score": <number 0..1>, "rationale": "<one paragraph>"} — no other text.',
          { phase: `Band ${b}`, agentType: 'triage-cross-reviewer', label: `judge:${j.label}@${t.id}:${r.anon}` })
      } })
    }
  }
  for (const j of judges) if (j.vendor === 'claude' && j.level === 'top') fableLog('judge', j.label)
  const outs = await parallel(jobs.map(x => x.run))
  jobs.forEach((x, i) => {
    const o = outs[i]
    let s = null
    if (x.j.vendor === 'claude') s = o && typeof o.score === 'number' ? o.score : null
    else if (!producedNothing(o)) { const p = parseJsonObject(o); s = p && typeof p.score === 'number' ? p.score : null }
    if (s != null && (s < 0 || s > 1)) s = null
    x.r.judges = x.r.judges || {}
    x.r.judges[x.j.label] = s
  })
  // rubric status — pass needs the checks AND every judge >= JUDGE_PASS; judges
  // that disagree by more than JUDGE_SPREAD, or a missing judge, is unresolved.
  for (const r of graded) {
    const scores = judges.map(j => (r.judges || {})[j.label])
    if (r.status === 'fail') continue   // the objective checks failed: the judges are recorded, the grade stands
    if (scores.some(s => s == null)) {
      r.status = 'unresolved'
      r.reason = 'a judge returned no score'
      flag(`${t.id}/${r.runLabel}: a judge returned no score — unresolved, not pass or fail`)
    } else if (Math.max(...scores) - Math.min(...scores) > JUDGE_SPREAD) {
      r.status = 'unresolved'
      r.reason = `judges disagree (${judges.map(j => `${j.label} ${r.judges[j.label]}`).join(', ')})`
      flag(`JUDGES DISAGREE on ${t.id}/${r.runLabel} (patch ${r.anon}): ${judges.map(j => `${j.label} ${r.judges[j.label]}`).join(', ')} — for Alex, counted unresolved`)
    } else {
      r.status = scores.every(s => s >= JUDGE_PASS) ? 'pass' : 'fail'
    }
  }
}

async function buildTask(t, b, runnable) {
  const runs = []
  for (const c of runnable) {
    for (let k = 1; k <= reps; k++) runs.push({ c, runLabel: k === 1 ? c.label : `${c.label}-r${k}` })
  }
  for (const c of runnable) if (c.vendor === 'claude' && c.level === 'top') fableLog('candidate', c.label)
  const cmpArgs = {
    repo: t.mat.repo, base: t.mat.sha, brief: t.brief, files: t.files, acceptance: t.acceptance, checks: t.checks,
    outDir: `${bandDir(b, t)}/cmp`, parallel: true,
    candidates: runs.map(x => Object.assign({ vendor: x.c.vendor, level: x.c.level, label: x.runLabel },
      x.c.model ? { model: x.c.model } : {}, x.c.effort ? { effort: x.c.effort } : {})),
  }
  if (t.overlay) cmpArgs.overlay = `${taskDirOf(t)}/${stripSlash(t.overlay)}`
  // Only an opted-in task's candidates get <mat repo>/.parity-env (tool paths).
  if (t.selfCheckEnv === true) cmpArgs.selfCheckEnv = true
  let res = null
  try {
    res = await workflow('triage-compare', cmpArgs)
  } catch (e) {
    flag(`${t.id}: triage-compare failed (${errText(e)}) — its candidates are unavailable, not failed`)
    return runs.map(x => row(x.c, x.runLabel, 'unavailable', { reason: `triage-compare failed: ${errText(e)}` }))
  }
  if (res && res.leak === true) {
    leakAbort = t.id
    log(`⚠ LEAK in task ${t.id}: triage-compare reports the materialized repo changed during the bake-off — aborting the parity run.`)
    return []
  }
  if (!res || !Array.isArray(res.candidates)) {
    flag(`${t.id}: triage-compare returned no candidate list — unavailable`)
    return runs.map(x => row(x.c, x.runLabel, 'unavailable', { reason: 'triage-compare returned nothing' }))
  }
  if (res.leak == null) flag(`${t.id}: triage-compare could not confirm the materialized repo is unchanged (leak check incomplete)`)
  const got = new Map(res.candidates.map(x => [x.label, x]))
  const rows = runs.map(x => {
    const g = got.get(x.runLabel)
    if (!g) return row(x.c, x.runLabel, 'unavailable', { reason: 'missing from the triage-compare result' })
    return row(x.c, x.runLabel, g.status, { reason: GRADED.includes(g.status) ? null : (g.tail || g.status), patch: g.patch || null,
      totalTokens: g.totalTokens != null ? g.totalTokens : null, seconds: g.seconds != null ? g.seconds : null, model: g.model || x.c.model,
      // Where the model came from (triage-compare: candidate|runner|null) — parity-report.sh
      // ledgers a runner-reported one as observed (M7).
      modelFrom: g.model ? (g.modelFrom || null) : (x.c.model ? 'candidate' : null) })
  })
  if (t.grading === 'rubric') await judgeTask(t, b, rows)
  return rows
}

async function reviewTask(t, b, runnable) {
  const repo = t.mat.repo
  const cdPrefix = `cd ${repo} && `
  const abs = t.files.map(f => `${repo}/${f}`)
  for (const c of runnable) if (c.vendor === 'claude' && c.level === 'top') fableLog('candidate', c.label)
  const outs = await parallel(runnable.map(c => () => {
    const label = `candidate:${c.label}@${t.id}`
    if (c.vendor === 'claude') {
      return agent(`${t.brief}\n\nFiles to review (paths relative to the repository root): ${t.files.join(', ')}\nAcceptance: ${t.acceptance}\n\n` +
        `--- Review protocol (you are one reviewer; others get the same brief) ---\n` +
        `The repository is ${repo}. This is READ-ONLY work: never edit, create, stage or commit anything.\n` +
        `Work only inside ${repo}. Do not read, list or search any other directory on this machine (including other copies of this project); the review is graded only from what you report on these files.\n` +
        `Read only the files themselves. Never inspect git history or run any git command — the repository carries no history to read, and its objects are not part of the review.\n` +
        `Your shell's working directory is reset between commands, so EVERY shell command you run MUST start with \`${cdPrefix}\` — for example \`${cdPrefix}cat ${t.files[0]}\`.\n` +
        'Return findings = every defect you find, each {file: path relative to the repository root, line: the 1-based line number, desc: one line}. Report each defect once.',
        Object.assign({ phase: `Band ${b}`, agentType: CLAUDE_AGENT[c.level], label, schema: FINDINGS_SCHEMA },
          c.model ? { model: c.model } : {}, c.effort ? { effort: c.effort } : {}))
    }
    // External review candidates run in MODE=read, not MODE=review: review mode
    // pins triage-cross-reviewer's own review-mode model (config/tiers.json
    // modes.<vendor>.review), which measured the wrong model for this candidate.
    // read mode is the staged, read-only, schema-capable mode, and MODEL=/EFFORT=
    // headers (below) pin it to THIS candidate's model/effort instead.
    return agent(`VENDOR=${c.vendor}\nMODE=read\n` +
      (c.model ? `MODEL=${c.model}\n` : '') +
      (c.effort ? `EFFORT=${c.effort}\n` : '') +
      'The data boundary has been checked by the orchestrator for this material (a synthetic or cleared parity task).\n' +
      `Pass exactly these files to ext-run.sh: ${abs.map(f => `--input ${f}`).join(' ')}\n` +
      `They are, relative to the repository root: ${t.files.join(', ')}\n\n` +
      `Review focus: ${t.brief}\nAcceptance: ${t.acceptance}\n\n` +
      'This is a review task: read only the staged files, never any git history.\n' +
      'Write this exact JSON Schema to a file and pass it to ext-run.sh as --schema (read mode enforces it; ' +
      'the response will be the model\'s answer as JSON matching it):\n' +
      `${JSON.stringify(FINDINGS_SCHEMA)}\n\n` +
      'Report every defect you find. Output ONLY one JSON object: {"findings": [{"file": "<path relative to the repository root, as listed above>", "line": <1-based line number>, "desc": "<one line>"}]} — no other text.',
      { phase: `Band ${b}`, agentType: 'triage-cross-reviewer', label })
  }))
  const rows = []
  const toScore = []
  runnable.forEach((c, i) => {
    const o = outs[i]
    if (c.vendor === 'claude') {
      if (!o || !Array.isArray(o.findings)) { rows.push(row(c, c.label, 'unavailable', { reason: 'reviewer returned nothing' })); return }
      toScore.push({ c, findings: o.findings })
      return
    }
    if (producedNothing(o)) { rows.push(row(c, c.label, 'unavailable', { reason: firstLine(o).slice(0, 200) || 'no reply' })); return }
    const p = parseJsonObject(o)
    if (!p || !Array.isArray(p.findings)) {
      rows.push(row(c, c.label, 'invalid', { reason: 'the external reply held no {"findings": [...]} JSON' }))
      flag(`${t.id}/${c.label}: external review reply was not the findings JSON — invalid, not a fail`)
      return
    }
    const ext = String(o).match(/ext-run:\s*(\d+)\s+tokens\s*\(([\d.]+)s/)
    toScore.push({ c, findings: p.findings, totalTokens: ext ? Number(ext[1]) : null, seconds: ext ? Number(ext[2]) : null })
  })
  if (!toScore.length) return rows
  // score-review (parity-suite.sh) is the ONLY scorer: findings are written to
  // files under outDir, then scored one by one.
  const rv = `${bandDir(b, t)}/review`
  const keyPath = `${taskDirOf(t)}/${t.key}`
  const cmds = toScore.map(x => `mkdir -p ${shq(rv)} && cat > ${shq(`${rv}/${x.c.label}.json`)} <<'PARITY_FINDINGS_EOF'\n` +
    `${JSON.stringify({ findings: x.findings.map(f => ({ file: String(f.file), line: f.line, desc: String(f.desc || '') })) })}\nPARITY_FINDINGS_EOF\n` +
    `${PARITY_SUITE} score-review --key ${shq(keyPath)} --findings ${shq(`${rv}/${x.c.label}.json`)}`)
  let sc = null
  try {
    sc = await agent('Run each of these command blocks exactly as written, in order, each even if an earlier one fails. Do not run anything else, and do not interpret or fix anything. ' +
      'Each block ends with a score-review command that prints one JSON object. Return scores = one entry per block, in order: label = the file name of its --findings file without .json, and recall, precision and matched copied from that JSON (null when it printed none).\n\n' +
      cmds.join('\n\n'),
      { phase: `Band ${b}`, agentType: 'triage-quick-task', label: `score:${t.id}`, schema: SCORE_SCHEMA })
  } catch (e) {
    sc = null
  }
  const byL = new Map(((sc && sc.scores) || []).map(s => [s.label, s]))
  for (const x of toScore) {
    const s = byL.get(x.c.label)
    const extra = { totalTokens: x.totalTokens || null, seconds: x.seconds || null }
    if (!s || typeof s.recall !== 'number' || typeof s.precision !== 'number') {
      rows.push(row(x.c, x.c.label, 'ungraded', Object.assign({ reason: 'score-review produced no score' }, extra)))
      continue
    }
    const ok = s.recall >= REVIEW_RECALL && s.precision >= REVIEW_PRECISION
    rows.push(row(x.c, x.c.label, ok ? 'pass' : 'fail', Object.assign({ recall: s.recall, precision: s.precision, matched: s.matched || [] }, extra)))
  }
  return rows
}

async function runTask(t, b, active) {
  const allowed = active.filter(c => t.vendors.includes(c.vendor))
  const skipped = active.filter(c => !t.vendors.includes(c.vendor)).map(c => row(c, c.label, 'skipped', { reason: `task allows ${t.vendors.join(',')}` }))
  if (!allowed.length) return { t, rows: skipped }
  const mat = await materialize(t, b)
  if (mat.error) {
    flag(`${t.id}: materialize failed (${mat.error}) — its candidates are unavailable, not failed`)
    return { t, rows: skipped.concat(allowed.map(c => row(c, c.label, 'unavailable', { reason: `materialize failed: ${mat.error}` }))) }
  }
  const denied = allowed.filter(c => c.vendor !== 'claude' && mat.denied[c.vendor] === true)
  if (denied.length) log(`${t.id}: ${denied.map(c => c.label).join(', ')} dropped — the task source is deny-marked for ${[...new Set(denied.map(c => c.vendor))].join(', ')}.`)
  const runnable = allowed.filter(c => !denied.includes(c))
  const tm = Object.assign({}, t, { mat })
  let rows = []
  if (runnable.length) rows = t.kind === 'build' ? await buildTask(tm, b, runnable) : await reviewTask(tm, b, runnable)
  // Every task kind — build, rubric AND review — is re-fingerprinted after grading.
  if (mat.fp.source === 'git' && rows.length && !leakAbort) rows = await sourceGuard(tm, b, rows)
  return { t, sha: mat.sha, guarded: mat.fp.source === 'git', rows: skipped.concat(denied.map(c => row(c, c.label, 'denied', { reason: `source deny-marked for ${c.vendor}` })), rows) }
}

// ─── Bands: adaptive climb ──────────────────────────────────────────────────
const st = new Map(candidates.map(c => [c.label, { c, streak: 0, stoppedAfter: null, highest: 0, perBand: {}, externalTokens: null, seconds: null, model: c.model }]))
const matrix = []
for (const b of bands) {
  const active = candidates.filter(c => st.get(c.label).stoppedAfter == null)
  if (!active.length) { log(`Band ${b}: every candidate has stopped — bands ${bands.filter(x => x >= b).join(',')} not run.`); break }
  const bandTasks = tasks.filter(t => t.band === b).sort((x, y) => (x.id < y.id ? -1 : 1))
  if (!bandTasks.length) { log(`Band ${b}: no tasks — neither a pass nor a fail for anyone.`); continue }
  phase(`Band ${b}`)
  log(`Band ${b}: ${bandTasks.length} task(s) × ${active.length} active candidate(s).`)
  const outs = await parallel(bandTasks.map(t => () => runTask(t, b, active)))
  if (leakAbort) throw new Error(`triage-parity: LEAK in task ${leakAbort} — the materialized repo changed during its bake-off; the run is aborted and no ranking is produced. Inspect ${outDir}/${b}/${leakAbort} before anything else.`)
  bandTasks.forEach((t, i) => {
    const o = outs[i]
    if (!o) {
      flag(`${t.id}: task run crashed — its candidates are unavailable, not failed`)
      matrix.push({ band: b, id: t.id, kind: t.kind, grading: t.grading, sha: null, results: active.map(c => row(c, c.label, 'unavailable', { reason: 'task run crashed' })) })
      return
    }
    matrix.push({ band: b, id: t.id, kind: t.kind, grading: t.grading, sha: o.sha || null, guarded: typeof o.guarded === 'boolean' ? o.guarded : null, results: o.rows })
  })
  // tally — pass and fail are graded; skipped (task not for that vendor) is not
  // counted at all; every other status counts as `other`, never as a fail.
  for (const c of active) {
    const s = st.get(c.label)
    const pb = { pass: 0, fail: 0, other: 0 }
    for (const m of matrix.filter(x => x.band === b)) {
      for (const r of m.results.filter(x => x.label === c.label)) {
        if (r.status === 'pass') pb.pass++
        else if (r.status === 'fail') pb.fail++
        else if (r.status !== 'skipped') pb.other++
        if (r.totalTokens != null) s.externalTokens = (s.externalTokens || 0) + r.totalTokens
        if (r.seconds != null) s.seconds = (s.seconds || 0) + r.seconds
        if (!s.model && r.model) s.model = r.model
      }
    }
    const gradedN = pb.pass + pb.fail
    pb.rate = gradedN ? pb.pass / gradedN : null
    s.perBand[b] = pb
    if (!gradedN) { log(`${c.label}: no graded task in band ${b} (${pb.other} other) — the band neither clears nor fails.`); continue }
    if (pb.rate >= passRate) { s.streak = 0; s.highest = Math.max(s.highest, b); continue }
    s.streak++
    if (s.streak >= stopAfter) {
      s.stoppedAfter = b
      const rest = bands.filter(x => x > b)
      log(`⚠ ${c.label} stops after band ${b}: ${s.streak} consecutive failed band(s)${rest.length ? ` — bands ${rest.join(',')} not run for it` : ''}.`)
    }
  }
}

// ─── Report ─────────────────────────────────────────────────────────────────
const overall = s => {
  const p = Object.values(s.perBand).reduce((a, x) => a + x.pass, 0)
  const f = Object.values(s.perBand).reduce((a, x) => a + x.fail, 0)
  return p + f ? p / (p + f) : -1
}
const states = candidates.map(c => st.get(c.label))
// Strongest first; ties by label (deterministic). No cheapness here: comparing
// cost is parity-report.sh's job.
states.sort((x, y) => y.highest - x.highest || overall(y) - overall(x) || (x.c.label < y.c.label ? -1 : x.c.label > y.c.label ? 1 : 0))
const ranking = states.map(s => ({
  label: s.c.label, vendor: s.c.vendor, level: s.c.level, model: s.model, effort: s.c.effort,
  highestBandCleared: s.highest, perBand: s.perBand, externalTokens: s.externalTokens, seconds: s.seconds, stoppedAfterBand: s.stoppedAfter,
}))
const plateaus = {}
for (const s of states) (plateaus[s.highest] = plateaus[s.highest] || []).push(s.c.label)

let desk = null
if (args.desk !== false) {
  const d = await deskRun
  desk = { note: 'signal only, never scored', codex: d && d[0] != null ? String(d[0]) : null }
}

const cell = pb => (pb ? `${pb.pass}/${pb.fail}/${pb.other}` : '—')
const md = [
  `| Candidate | Vendor | Model | Effort | Cleared | ${bands.map(b => `B${b} p/f/o`).join(' | ')} | Ext tokens | Stopped |`,
  `|---|---|---|---|---|${bands.map(() => '---').join('|')}|---|---|`,
  ...ranking.map(r => `| ${r.label} | ${r.vendor} | ${r.model || '—'} | ${r.effort || '—'} | B${r.highestBandCleared} | ${bands.map(b => cell(r.perBand[b])).join(' | ')} | ${r.externalTokens == null ? '—' : r.externalTokens} | ${r.stoppedAfterBand == null ? '—' : `after B${r.stoppedAfterBand}`} |`),
  '',
  'No tier proposal here. Save this result as JSON, then run parity-report.sh ingest-parity --result <file> and parity-report.sh report (min-n + margin rule; Alex approves any config/tiers.json change). Claude cost per candidate: scripts/parity-cost.sh on this run\'s transcript dir.',
].join('\n')

log(`Parity run done: ${ranking.length} candidate(s), ${matrix.length} task run(s), ${flags.length} flag(s). Nothing outside ${outDir} was written; tiers.json untouched.`)
// next — what the orchestrator does with this value: the ledger + decision rule
// have ONE owner, scripts/parity-report.sh.
const next = [
  'Save this return value as JSON (e.g. <outDir>/result.json), then:',
  `${PARITY_REPORT} ingest-parity --result <that file>   # one ledger line per graded (task, candidate run)`,
  `${PARITY_REPORT} report                               # per level x vendor: n, rate, Wilson LB; proposals only past min-n + margin`,
]
return { outDir, bands, ranking, plateaus, flags, desk, tasks: matrix, markdown: md, next }
