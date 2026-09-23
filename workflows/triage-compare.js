export const meta = {
  name: 'triage-compare',
  description: 'Implementation bake-off: run one brief on several candidates (Claude levels, codex, agy), each producing a patch, then grade every patch independently with patch-check.sh. Never applies a patch.',
  whenToUse: 'Compare vendors/levels/models on the SAME well-specified task: /triage-compare with args = {repo, base?, brief, files, acceptance, checks:[cmd...], outDir, overlay?, candidates:[{vendor:claude|codex|agy, level:quick|builder|deep|top, model?, effort?, label?}]}. Needs a clean tree; repo must be the session working repo (Claude candidates get an isolated worktree of it). outDir/overlay must be OUTSIDE repo, and outDir should be fresh per run — a stale leftover patch is never graded. External (non-claude) candidates require args.files. Candidates run one at a time; the grade is scripts/patch-check.sh on each patch in a fresh worktree at base (plus the hidden overlay), never the candidate self-report. Returns per-candidate status/applies/rc/diffstat/patch/tokens; the orchestrator picks and applies.',
  phases: [
    { title: 'Candidates' },
    { title: 'Grade' },
  ],
}

// ─── Entry contract ─────────────────────────────────────────────────────────
// A bake-off is a measurement, so everything that could make it unfair or unsafe is
// rejected in plain JS BEFORE any spawn: unknown vendor/level/effort, agy off the
// builder level, duplicate or path-unsafe labels, relative paths, no checks to grade
// by. A malformed plan is a caller bug and fails loudly and for free.
const LEVELS = ['quick', 'builder', 'deep', 'top']
const VENDORS = ['claude', 'codex', 'agy']
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
// The Claude agent serving each level — the SAME map as triage-exec.js; test/lint.sh
// checks both against config/tiers.json levels.*.claude.agent.
const CLAUDE_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', top: 'triage-fable-architect' }
const PATCH_CHECK = '~/.claude/scripts/patch-check.sh'

const USAGE = 'Expected args = {\n' +
  '  repo: "/abs/repo", base?: "HEAD", brief, files?: string[] (required if any candidate is non-claude), acceptance,\n' +
  '  checks: string[]            // at least one; the grade\n' +
  '  outDir: "/abs/dir"          // patches land at <outDir>/<label>.patch — must be outside repo; use a FRESH dir per run, a stale patch left over from a previous run is never graded\n' +
  '  overlay?: "/abs/dir"        // hidden tests copied in before the check; never shown to candidates; must be outside repo\n' +
  `  candidates: [{ vendor: ${VENDORS.join('|')}, level: ${LEVELS.join('|')}, model?, effort?: ${EFFORTS.join('|')}, label? }]\n}`

function bad(msg) {
  throw new Error(`triage-compare: ${msg}\n${USAGE}`)
}

const isStr = v => typeof v === 'string' && v.trim().length > 0
const typeName = v => (v === null ? 'null' : Array.isArray(v) ? 'an array' : typeof v)
// Paths and labels go into a header line and into shell commands, so: absolute,
// no whitespace, no quote characters.
const isAbsPath = v => isStr(v) && v.startsWith('/') && !/[\s'"`$\\]/.test(v)
const SAFE_TOKEN = /^[A-Za-z0-9._@+-]+$/

if (!args || typeof args !== 'object' || Array.isArray(args)) bad(`args must be an object (got ${typeName(args)}).`)
if (!isAbsPath(args.repo)) bad('args.repo must be an absolute path with no whitespace or quotes.')
if (args.base != null && !(isStr(args.base) && /^[A-Za-z0-9._@+~^/-]+$/.test(args.base.trim()))) bad(`args.base must be a revision name like HEAD or a sha (got ${JSON.stringify(args.base)}).`)
if (!isStr(args.brief)) bad('args.brief must be a non-empty string.')
if (!isStr(args.acceptance)) bad('args.acceptance must be a non-empty string.')
if (args.files != null && !(Array.isArray(args.files) && args.files.every(isStr))) bad('args.files must be an array of path strings.')
if (!Array.isArray(args.checks) || args.checks.length === 0 || !args.checks.every(isStr)) bad('args.checks must be a non-empty array of shell commands — they are the grade.')
if (!isAbsPath(args.outDir)) bad('args.outDir must be an absolute path with no whitespace or quotes.')
if (args.overlay != null && !isAbsPath(args.overlay)) bad('args.overlay must be an absolute path with no whitespace or quotes.')
// A patch written under repo dirties the real tree, so ext-run --patch-out refuses
// every later external candidate (a measurement fault reported as unavailability);
// an overlay under repo leaks the hidden tests into candidate worktrees. Both are
// rejected here, before any spawn. A trailing slash on either side is normalized
// first so repo+'/sub' and repo+'/sub/' are caught the same way.
const stripSlash = v => String(v).replace(/\/+$/, '')
if (isAbsPath(args.repo) && isAbsPath(args.outDir)) {
  const repoC = stripSlash(args.repo.trim())
  const outDirC = stripSlash(args.outDir.trim())
  if (outDirC === repoC || outDirC.startsWith(`${repoC}/`)) bad('args.outDir must not be inside args.repo — a patch written under the repo dirties the tree and ext-run --patch-out refuses every later external candidate.')
}
if (args.overlay != null && isAbsPath(args.repo) && isAbsPath(args.overlay)) {
  const repoC = stripSlash(args.repo.trim())
  const overlayC = stripSlash(args.overlay.trim())
  if (overlayC === repoC || overlayC.startsWith(`${repoC}/`)) bad('args.overlay must not be inside args.repo — an overlay under the repo leaks the hidden tests into candidate worktrees.')
}
if (!Array.isArray(args.candidates) || args.candidates.length === 0) bad('args.candidates must be a non-empty array.')

const repo = args.repo.trim()
const base = (args.base || 'HEAD').trim()
const outDir = args.outDir.trim().replace(/\/+$/, '')
const overlay = args.overlay ? args.overlay.trim() : null
const files = (args.files || []).map(f => f.trim())
const checks = args.checks.map(c => c.trim())
const checkCmd = checks.join(' && ')

const seen = new Set()
const candidates = args.candidates.map((raw, i) => {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`candidates[${i}] must be an object (got ${typeName(raw)}).`)
  if (!VENDORS.includes(raw.vendor)) bad(`candidates[${i}].vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(raw.vendor)}).`)
  if (!LEVELS.includes(raw.level)) bad(`candidates[${i}].level must be one of ${LEVELS.join('|')} (got ${JSON.stringify(raw.level)}).`)
  if (raw.vendor === 'agy' && raw.level !== 'builder') bad(`candidates[${i}]: vendor agy serves the builder level only (got level ${raw.level}).`)
  if (raw.effort != null && !EFFORTS.includes(raw.effort)) bad(`candidates[${i}].effort must be one of ${EFFORTS.join('|')} (got ${JSON.stringify(raw.effort)}).`)
  if (raw.model != null && !(isStr(raw.model) && SAFE_TOKEN.test(raw.model))) bad(`candidates[${i}].model must be a model id with no spaces (got ${JSON.stringify(raw.model)}).`)
  if (raw.label != null && !isStr(raw.label)) bad(`candidates[${i}].label must be a non-empty string when given.`)
  const label = raw.label ? raw.label.trim()
    : `${raw.vendor}-${raw.level}${raw.model ? `-${raw.model}` : ''}${raw.effort ? `-${raw.effort}` : ''}`
  if (!SAFE_TOKEN.test(label)) bad(`candidates[${i}]: label ${JSON.stringify(label)} is not file-name safe (letters, digits, . _ @ + -) — pass an explicit label.`)
  if (seen.has(label)) bad(`duplicate candidate label "${label}" — labels name the patch files and must be unique.`)
  seen.add(label)
  return { label, vendor: raw.vendor, level: raw.level, model: raw.model || null, effort: raw.effort || null, patch: `${outDir}/${label}.patch` }
})
// External candidates are built by ext-run.sh from the repo's clean HEAD — it has no
// base option — so a bake-off with one grades against HEAD only.
if (base !== 'HEAD' && candidates.some(c => c.vendor !== 'claude')) {
  bad(`base ${JSON.stringify(base)} with an external candidate: ext-run.sh builds from HEAD, so external candidates can only be graded against base HEAD.`)
}
// triage-external refuses a brief without exact files, so a bake-off with any
// non-claude candidate needs args.files up front — never discovered by the caller
// mid-run as a per-candidate spawn failure.
if (candidates.some(c => c.vendor !== 'claude') && files.length === 0) {
  bad('args.files must be a non-empty array when any candidate has vendor other than claude — triage-external refuses briefs without exact files.')
}

// ─── Helpers ────────────────────────────────────────────────────────────────
const shq = s => `'${String(s).replace(/'/g, `'\\''`)}'`
const spentNow = () => (budget && typeof budget.spent === 'function' ? budget.spent() : null)
const firstLine = out => String(out || '').trimStart().split('\n')[0]
// UNAVAILABLE / REFUSED as a reply's FIRST line (triage-external's exit-code
// mapping), or no reply at all: the candidate produced nothing to grade.
const producedNothing = out => out == null || /^\s*(UNAVAILABLE|REFUSED)\b/i.test(String(out).trimStart())
// The accounting line ext-run.sh prints and triage-external relays:
//   ext-run: <N> tokens (<S>s, <vendor>/<model>)[ out=<M>]
const EXT_LINE = /ext-run:\s*(\d+)\s+tokens\s*\(([\d.]+)s,\s*([a-z]+)\/([^)\s]+)\)(?:\s+out=(\d+))?/
// The candidate's OWN check claim — informational only (selfRc), never the grade.
const selfRcOf = out => {
  const m = String(out || '').match(/(^|\n)\s*CHECK rc=(\d+)/)
  return m ? Number(m[2]) : null
}
// A candidate reply that otherwise looks fine but never reports its OWN patch path
// leaves no way to tell a fresh write from a stale patch already sitting in outDir
// from a previous run — so it is never graded, same as REFUSED/UNAVAILABLE.
const escapeRe = s => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const hasPatchLine = (out, patchPath) => new RegExp(`(^|\\n)\\s*PATCH ${escapeRe(patchPath)}\\s*($|\\n)`).test(String(out || ''))

const task = `${args.brief.trim()}\n\nRelevant files: ${files.join(', ') || '(discover)'}\nAcceptance criteria: ${args.acceptance.trim()}`

function claudePrompt(c) {
  return `${task}\n\n` +
    `--- Bake-off protocol (you are one candidate; others get the same brief) ---\n` +
    `You are working in your OWN isolated git worktree of ${repo}. Change files only there.\n` +
    (base !== 'HEAD' ? `First run: git checkout --detach ${base}\n` : '') +
    `Run these checks from the worktree root:\n${checks.map(c2 => `  ${c2}`).join('\n')}\n` +
    `When done:\n` +
    `  rm -f ${c.patch}\n` +
    `  mkdir -p ${outDir}\n` +
    `  git add -A && git diff --binary ${base} > ${c.patch}\n` +
    `Never apply, commit to, push, or check out anything in ${repo} itself, and write nowhere else outside your worktree.\n` +
    `End your reply with two lines: \`CHECK rc=<exit status of the checks joined with &&>\` and \`PATCH ${c.patch}\`.`
}

function externalPrompt(c) {
  const header = `VENDOR=${c.vendor} LEVEL=${c.level}` + (c.effort ? ` EFFORT=${c.effort}` : '') + (c.model ? ` MODEL=${c.model}` : '') +
    ` WORKDIR=${repo} PATCH_OUT=${c.patch} CHECK=${checkCmd}`
  return `${header}\n\n${task}\n\n` +
    `Check command: ${checkCmd}\n` +
    `The data boundary has been cleared by the orchestrator for this repository.\n` +
    `This is a bake-off: write the patch to PATCH_OUT only; nothing is applied to the repo.`
}

// ─── Candidates: strictly sequential ────────────────────────────────────────
// One at a time, so each budget.spent() delta is that candidate's Claude output tokens
// and nothing else (the pool is shared across the whole turn).
phase('Candidates')
const runs = []
for (const c of candidates) {
  const external = c.vendor !== 'claude'
  if (!external && c.level === 'top') log(`⚠ Escalating to Fable: triage-compare candidate ${c.label}`)
  if (external) log(`⚠ External candidate ${c.label}: the workspace leaves this machine for ${c.vendor}.`)
  const opts = external
    ? { phase: 'Candidates', agentType: 'triage-external', label: `candidate:${c.label}` }
    : Object.assign({ phase: 'Candidates', agentType: CLAUDE_AGENT[c.level], label: `candidate:${c.label}`, isolation: 'worktree' },
        c.model ? { model: c.model } : {}, c.effort ? { effort: c.effort } : {})
  const before = spentNow()
  let out = null
  let err = null
  try {
    out = await agent(external ? externalPrompt(c) : claudePrompt(c), opts)
  } catch (e) {
    err = String((e && e.message) || e)   // e.g. the budget's hard ceiling
  }
  const after = spentNow()
  const claudeOut = before != null && after != null ? after - before : null
  let nothing = err != null || producedNothing(out)
  let reason = err ? `spawn failed: ${err.slice(0, 200)}` : out == null ? 'spawn returned nothing' : nothing ? firstLine(out).slice(0, 200) : null
  if (!nothing && !hasPatchLine(out, c.patch)) {
    nothing = true
    reason = external ? 'no patch reported' : 'no PATCH line'
  }
  const ext = external && out ? String(out).match(EXT_LINE) : null
  const run = {
    c,
    available: !nothing,
    reason,
    selfRc: nothing ? null : selfRcOf(out),
    model: c.model || (ext ? ext[4] : null),
    // Claude: the output tokens this candidate cost (budget delta). External: the
    // vendor's own output count from the ext-run line (null when it gave none).
    outTokens: external ? (ext && ext[5] != null ? Number(ext[5]) : null) : claudeOut,
    totalTokens: external && ext ? Number(ext[1]) : null,
    seconds: external && ext ? Number(ext[2]) : null,
  }
  if (!run.available) log(`⚠ ${c.label} unavailable (${run.reason}) — reported, not graded as a fail.`)
  runs.push(run)
}

// ─── Grade: ONE independent patch-check over every produced patch ───────────
// This is THE grade. The candidates' own CHECK rc claims are kept as selfRc for the
// reader, and ignored here.
phase('Grade')
const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          patch: { type: 'string' },
          applies: { type: 'boolean' },
          rc: { type: ['integer', 'null'] },
          diffstat: { type: 'string' },
          tail: { type: 'string' },
        },
        required: ['patch', 'applies', 'rc', 'diffstat', 'tail'],
      },
    },
  },
  required: ['results'],
}
const graded = runs.filter(r => r.available)
let byPatch = null
if (graded.length) {
  const cmd = `${PATCH_CHECK} --repo ${shq(repo)} --base ${shq(base)} --check ${shq(checkCmd)}` +
    (overlay ? ` --overlay ${shq(overlay)}` : '') + ' ' + graded.map(r => shq(r.c.patch)).join(' ')
  const gradePrompt = `Run this one command exactly as written and return its stdout JSON lines, one results[] entry per line, field for field, in order. Do not run anything else, and do not interpret or fix anything.\n${cmd}`
  let pc = null
  for (let attempt = 1; attempt <= 2 && !(pc && Array.isArray(pc.results)); attempt++) {
    try {
      pc = await agent(gradePrompt, { phase: 'Grade', agentType: 'triage-quick-task', label: attempt === 1 ? 'grade:patch-check' : 'grade:patch-check#retry', schema: RESULT_SCHEMA })
    } catch (e) {
      log(`⚠ patch-check grader spawn failed (${String((e && e.message) || e).slice(0, 200)}).`)
      pc = null
    }
  }
  if (pc && Array.isArray(pc.results)) byPatch = new Map(pc.results.map(x => [x.patch, x]))
  else log('⚠ GRADING INCOMPLETE — the patch-check grader returned nothing twice; available candidates are reported as ungraded, NOT as passes or fails.')
}

// grade() — SINGLE OWNER of a candidate's status. pass = the patch applied at base AND
// the checks exited 0 in patch-check's own worktree. Nothing the candidate said counts.
function grade(r) {
  if (!r.available) return { status: 'unavailable', applies: null, rc: null, diffstat: null, tail: r.reason }
  const pc = byPatch && byPatch.get(r.c.patch)
  if (!pc) return { status: 'ungraded', applies: null, rc: null, diffstat: null, tail: 'patch-check produced no result for this patch' }
  const status = pc.applies === true && pc.rc === 0 ? 'pass' : 'fail'
  return { status, applies: pc.applies, rc: pc.rc, diffstat: pc.diffstat, tail: pc.tail }
}

const results = runs.map(r => {
  const g = grade(r)
  return {
    label: r.c.label, vendor: r.c.vendor, level: r.c.level, model: r.model, effort: r.c.effort,
    status: g.status, applies: g.applies, rc: g.rc, diffstat: g.diffstat,
    patch: r.available ? r.c.patch : null,
    outTokens: r.outTokens, totalTokens: r.totalTokens, seconds: r.seconds,
    selfRc: r.selfRc,
    tail: g.tail == null ? null : String(g.tail).slice(-2000),
  }
})
const tally = s => results.filter(x => x.status === s).length
log(`Bake-off graded by patch-check: ${tally('pass')} pass, ${tally('fail')} fail, ${tally('unavailable')} unavailable` +
  (tally('ungraded') ? `, ${tally('ungraded')} UNGRADED` : '') + ' — nothing was applied to the repo.')
return { base, graded: graded.length === 0 || byPatch != null, candidates: results }
