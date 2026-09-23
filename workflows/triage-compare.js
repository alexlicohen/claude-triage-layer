export const meta = {
  name: 'triage-compare',
  description: 'Implementation bake-off: run one brief on several candidates (Claude levels, codex, agy), each in its own staged worktree outside the repo, then grade every worktree diff independently with patch-check.sh. Never applies a patch; the real repo is never a candidate workdir.',
  whenToUse: 'Compare vendors/levels/models on the SAME well-specified task: /triage-compare with args = {repo, base?, brief, files, acceptance, checks:[cmd...], outDir, overlay?, candidates:[{vendor:claude|codex|agy, level:quick|builder|deep|top, model?, effort?, label?}]}. repo is any absolute git repo path (not necessarily the session repo) and may be dirty: base (default HEAD) is resolved to ONE sha up front and each candidate works in its own detached worktree at that sha under <outDir>/stage (scripts/stage-worktree.sh), never in repo. outDir/overlay must be OUTSIDE repo and <outDir>/stage must not already exist. External (non-claude) candidates require args.files. Candidates run one at a time; the grade is scripts/patch-check.sh on each worktree diff at the sha (plus the hidden overlay), never the candidate self-report; a leakcheck then proves repo did not change (leak:true => every candidate invalid). Returns sha/leak/baseMoved and per-candidate status/applies/rc/diffstat/patch/tokens; the orchestrator picks and applies.',
  phases: [
    { title: 'Stage' },
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
const STAGE_WT = '~/.claude/scripts/stage-worktree.sh'

const USAGE = 'Expected args = {\n' +
  '  repo: "/abs/repo"            // any git repo (need not be the session repo); may be dirty — candidates never see its tree\n' +
  '  base?: "HEAD", brief, files?: string[] (required if any candidate is non-claude), acceptance,\n' +
  '  checks: string[]            // at least one; the grade\n' +
  '  outDir: "/abs/dir"          // must be outside repo; worktrees are staged in <outDir>/stage (must not exist yet), patches land at <outDir>/<label>.patch\n' +
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
// The stage (worktrees + patches) under repo would dirty the real tree — which the
// leakcheck then reports as a LEAK, voiding the run; an overlay under repo leaks the
// hidden tests into every candidate worktree. Both are rejected here, before any spawn. A trailing slash on either side is normalized
// first so repo+'/sub' and repo+'/sub/' are caught the same way.
const stripSlash = v => String(v).replace(/\/+$/, '')
if (isAbsPath(args.repo) && isAbsPath(args.outDir)) {
  const repoC = stripSlash(args.repo.trim())
  const outDirC = stripSlash(args.outDir.trim())
  if (outDirC === repoC || outDirC.startsWith(`${repoC}/`)) bad('args.outDir must not be inside args.repo — the staged worktrees and patches would dirty the real tree.')
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
const stageDir = `${outDir}/stage`
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
  // Candidate i works in <stageDir>/wt-<i+1> — computed HERE, never taken from a
  // spawn's reply, so no reply can steer a candidate into the real repo.
  return { label, vendor: raw.vendor, level: raw.level, model: raw.model || null, effort: raw.effort || null,
    patch: `${outDir}/${label}.patch`, worktree: `${stageDir}/wt-${i + 1}` }
})
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
const errText = e => String((e && e.message) || e).slice(0, 200)
// UNAVAILABLE / REFUSED as a reply's FIRST line (triage-external's exit-code
// mapping), or no reply at all: the candidate produced nothing to grade.
const producedNothing = out => out == null || /^\s*(UNAVAILABLE|REFUSED)\b/i.test(String(out).trimStart())
// The accounting line ext-run.sh prints and triage-external relays:
//   ext-run: <N> tokens (<S>s, <vendor>/<model>)[ out=<M>]
const EXT_LINE = /ext-run:\s*(\d+)\s+tokens\s*\(([\d.]+)s,\s*([a-z]+)\/([^)\s]+)\)(?:\s+out=(\d+))?/
// The candidate's OWN check claim — informational only (selfRc), never the grade:
// a `CHECK rc=<n>` line, else the external worker's `DONE exit=<n>` sentinel.
const selfRcOf = out => {
  const m = String(out || '').match(/(^|\n)\s*CHECK rc=(\d+)/) || String(out || '').match(/(^|\n)\s*DONE exit=(\d+)/)
  return m ? Number(m[2]) : null
}
const SHA_RE = /^[0-9a-f]{40}([0-9a-f]{24})?$/

const task = `${args.brief.trim()}\n\nRelevant files: ${files.join(', ') || '(discover)'}\nAcceptance criteria: ${args.acceptance.trim()}`
const stageCmd = `${STAGE_WT} create --repo ${shq(repo)} --base ${shq(base)} --count ${candidates.length} --dir ${shq(stageDir)}`
const cleanupCmd = `${STAGE_WT} cleanup --repo ${shq(repo)} --dir ${shq(stageDir)}`

// The real repo is never a candidate's working directory: each one is pointed at
// its own staged worktree (c.worktree), and repo appears in a Claude prompt only
// as the place it must stay out of. A subagent's Bash cwd is RESET between calls,
// so a one-time `cd` does not persist: every shell command carries its own
// `cd <worktree> && ` prefix, or a check would run (and leave build output) in
// the session repo — a wrong selfRc and a false LEAK.
function claudePrompt(c, sha) {
  const cdPrefix = `cd ${c.worktree} && `
  return `${task}\n\n` +
    `--- Bake-off protocol (you are one candidate; others get the same brief) ---\n` +
    `Your workspace is the staged git worktree ${c.worktree} (detached at ${sha}).\n` +
    `Your shell's working directory is reset between commands, so a cd on its own does not stick: EVERY shell command you run MUST start with \`${cdPrefix}\` — for example \`${cdPrefix}${checks[0]}\`.\n` +
    `Every file edit uses an absolute path under ${c.worktree}/.\n` +
    `The repository at ${repo} is NOT your workspace: never use a path under it, and never read from, modify, or run anything in it.\n` +
    `Run these checks, each prefixed with \`${cdPrefix}\`:\n${checks.map(c2 => `  ${c2}`).join('\n')}\n` +
    `Leave your changes in the worktree as they are — do not commit, stash, or write a patch; they are collected from ${c.worktree} after you finish.\n` +
    `End your reply with two lines: \`CHECK rc=<exit status of the checks joined with &&>\` and \`DONE\`.`
}

// WORKDIR is the staged worktree, so even a wrapper that drops a flag, or an
// ext-run that applies its patch back, lands the change in a throwaway checkout —
// which is exactly where the grade collects it from. No PATCH_OUT: a bake-off-mode
// run would leave the worktree untouched (nothing to grade), and triage-external
// refuses a CHECK without one, so the check command travels in the brief instead.
function externalPrompt(c, sha) {
  const header = `VENDOR=${c.vendor} LEVEL=${c.level}` + (c.effort ? ` EFFORT=${c.effort}` : '') + (c.model ? ` MODEL=${c.model}` : '') +
    ` WORKDIR=${c.worktree}`
  return `${header}\n\n${task}\n\n` +
    `Check command (run from the workdir root): ${checkCmd}\n` +
    `The data boundary has been cleared by the orchestrator for this repository.\n` +
    `This is a bake-off candidate: the workdir is a throwaway checkout at ${sha}; the change is collected from it afterwards.`
}

// cleanupStage() — SINGLE OWNER of removing the stage. Runs on every exit path
// once staging succeeded; a failure is loud but never fatal.
async function cleanupStage(phaseName) {
  let r = null
  try {
    r = await agent(`Run this one command exactly as written and return ok = the ok field of the JSON line it prints (false if it printed none) and rc = its exit status. Do not run anything else, and do not interpret or fix anything.\n${cleanupCmd}`,
      { phase: phaseName, agentType: 'triage-quick-task', label: 'cleanup:stage', schema: { type: 'object', properties: { ok: { type: 'boolean' }, rc: { type: ['integer', 'null'] } }, required: ['ok'] } })
  } catch (e) {
    r = null
  }
  const ok = !!(r && r.ok === true)
  if (!ok) log(`⚠ Staged worktrees may remain under ${stageDir} — run: ${cleanupCmd}`)
  return ok
}

// ─── Stage: ONE sha, one worktree per candidate, fingerprint of repo ─────────
phase('Stage')
const STAGE_SCHEMA = {
  type: 'object',
  properties: { sha: { type: 'string' }, worktrees: { type: 'array', items: { type: 'string' } }, fingerprint: { type: 'string' } },
  required: ['sha', 'worktrees', 'fingerprint'],
}
let staged = null
let stageErr = null
try {
  staged = await agent(`Run this one command exactly as written and return its stdout JSON object field for field. Do not run anything else, and do not interpret or fix anything.\n${stageCmd}`,
    { phase: 'Stage', agentType: 'triage-quick-task', label: 'stage:create', schema: STAGE_SCHEMA })
} catch (e) {
  stageErr = errText(e)
}
// The reply must name exactly the worktrees computed above, in order — the paths
// used are always the computed ones; this only proves staging made them.
const stageOk = !!(staged && isStr(staged.sha) && SHA_RE.test(staged.sha.trim()) && Array.isArray(staged.worktrees) &&
  staged.worktrees.length === candidates.length && staged.worktrees.every((w, i) => isStr(w) && stripSlash(w.trim()) === candidates[i].worktree))
// create rolls back its own failures, and a populated stage dir may be another
// run's, so nothing is removed here: the error names the cleanup command instead.
if (!stageOk) {
  throw new Error(`triage-compare: staging failed — no candidate ran (${stageErr || `stage-worktree.sh create returned ${JSON.stringify(staged).slice(0, 300)}`}). ` +
    `If ${stageDir} was created by this run, remove it with: ${cleanupCmd}`)
}
const sha = staged.sha.trim()

const runs = []
let gr = null
try {
  // ─── Candidates: strictly sequential ──────────────────────────────────────
  // One at a time, so each budget.spent() delta is that candidate's Claude output
  // tokens and nothing else (the pool is shared across the whole turn).
  phase('Candidates')
  for (const c of candidates) {
    const external = c.vendor !== 'claude'
    if (!external && c.level === 'top') log(`⚠ Escalating to Fable: triage-compare candidate ${c.label}`)
    if (external) log(`⚠ External candidate ${c.label}: the workspace leaves this machine for ${c.vendor}.`)
    // No isolation:'worktree': the harness bases that on the default branch, not
    // on the sha every other candidate gets. The staged worktree is the isolation.
    const opts = external
      ? { phase: 'Candidates', agentType: 'triage-external', label: `candidate:${c.label}` }
      : Object.assign({ phase: 'Candidates', agentType: CLAUDE_AGENT[c.level], label: `candidate:${c.label}` },
          c.model ? { model: c.model } : {}, c.effort ? { effort: c.effort } : {})
    const before = spentNow()
    let out = null
    let err = null
    try {
      out = await agent(external ? externalPrompt(c, sha) : claudePrompt(c, sha), opts)
    } catch (e) {
      err = errText(e)   // e.g. the budget's hard ceiling
    }
    const after = spentNow()
    const claudeOut = before != null && after != null ? after - before : null
    const nothing = err != null || producedNothing(out)
    const ext = external && out ? String(out).match(EXT_LINE) : null
    const run = {
      c,
      available: !nothing,
      reason: err ? `spawn failed: ${err}` : out == null ? 'spawn returned nothing' : nothing ? firstLine(out).slice(0, 200) : null,
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

  // ─── Grade: ONE spawn — worktree diffs, patch-check, leakcheck ────────────
  // This is THE grade: each available candidate's staged worktree is diffed
  // against the sha (whatever the candidate said — an empty diff is graded like any
  // other), patch-check applies each diff to a fresh worktree at the sha and runs
  // the checks, and leakcheck compares repo with its fingerprint. Every step is
  // idempotent, so a dead grader is simply re-run once. Cleanup is separate so a
  // retry still has the worktrees and the fingerprint to work from.
  phase('Grade')
  const graded = runs.filter(r => r.available)
  const lines = graded.map(r => `${STAGE_WT} diff --worktree ${shq(r.c.worktree)} --base ${shq(sha)} --out ${shq(r.c.patch)}`)
  if (graded.length) {
    lines.push(`${PATCH_CHECK} --repo ${shq(repo)} --base ${shq(sha)} --check ${shq(checkCmd)}` +
      (overlay ? ` --overlay ${shq(overlay)}` : '') + ' ' + graded.map(r => shq(r.c.patch)).join(' '))
  }
  lines.push(`${STAGE_WT} leakcheck --repo ${shq(repo)} --dir ${shq(stageDir)}`)
  const GRADE_SCHEMA = {
    type: 'object',
    properties: {
      diffs: {
        type: 'array',
        items: {
          type: 'object',
          properties: { worktree: { type: 'string' }, patch: { type: 'string' }, ok: { type: 'boolean' }, shortstat: { type: 'string' }, error: { type: 'string' } },
          required: ['worktree', 'patch', 'ok'],
        },
      },
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
      leakcheck: {
        type: 'object',
        properties: {
          status: { type: 'string', enum: ['CLEAN', 'LEAK', 'BASE_MOVED', 'ERROR'] },
          leak: { type: 'boolean' },
          baseMoved: { type: 'boolean' },
          rc: { type: ['integer', 'null'] },
          detail: { type: 'string' },
        },
        required: ['status', 'rc'],
      },
    },
    required: ['diffs', 'results', 'leakcheck'],
  }
  const gradePrompt = `Run these commands in order, each exactly as written, and each even if an earlier one fails. Do not run anything else, and do not interpret or fix anything.\n` +
    `${lines.join('\n')}\n\n` +
    `Each prints JSON lines on stdout. Return them field for field: diffs = the stage-worktree diff lines, in order (${graded.length}); ` +
    `results = patch-check's lines, one per patch, in order${graded.length ? '' : ' (none ran: [])'}; ` +
    `leakcheck = the leakcheck line's status, leak, baseMoved and detail, plus rc = the leakcheck command's exit status (status ERROR if it printed no JSON line).`
  const gradeOk = x => !!(x && Array.isArray(x.diffs) && Array.isArray(x.results) && x.leakcheck && typeof x.leakcheck === 'object')
  for (let attempt = 1; attempt <= 2 && !gradeOk(gr); attempt++) {
    try {
      gr = await agent(gradePrompt, { phase: 'Grade', agentType: 'triage-quick-task', label: attempt === 1 ? 'grade:finalize' : 'grade:finalize#retry', schema: GRADE_SCHEMA })
    } catch (e) {
      log(`⚠ grader spawn failed (${errText(e)}).`)
      gr = null
    }
  }
  if (!gradeOk(gr)) {
    gr = null
    log('⚠ GRADING INCOMPLETE — the grader returned nothing twice; available candidates are reported as ungraded, NOT as passes or fails.')
  }
} finally {
  await cleanupStage('Grade')
}

// leakState() — SINGLE OWNER of the leak verdict. Any sign of a leak is a leak;
// only an explicit CLEAN/BASE_MOVED with exit 0 is clean; anything else is
// unknown (null), never assumed clean.
function leakState(lc) {
  if (!lc) return { leak: null, baseMoved: null, detail: 'leakcheck did not report' }
  const detail = isStr(lc.detail) ? lc.detail : null
  if (lc.leak === true || lc.rc === 7 || lc.status === 'LEAK') return { leak: true, baseMoved: lc.baseMoved === true, detail }
  if ((lc.status === 'CLEAN' || lc.status === 'BASE_MOVED') && lc.rc === 0) {
    return { leak: false, baseMoved: lc.status === 'BASE_MOVED' || lc.baseMoved === true, detail }
  }
  return { leak: null, baseMoved: lc.baseMoved === true ? true : null, detail: detail || `leakcheck status ${lc.status}, rc ${lc.rc}` }
}
const leakInfo = leakState(gr && gr.leakcheck)
if (leakInfo.leak === true) log(`⚠ LEAK: the real repo changed during triage-compare — inspect before anything else${leakInfo.detail ? ` (${leakInfo.detail})` : ''}`)
else if (leakInfo.leak == null) log(`⚠ LEAK CHECK INCOMPLETE — could not confirm ${repo} is unchanged; inspect it before anything else (${leakInfo.detail}).`)
if (leakInfo.baseMoved) log(`⚠ BASE_MOVED: HEAD of ${repo} moved during the run; every candidate was graded at ${sha}.`)

const byDiff = gr ? new Map(gr.diffs.map(x => [stripSlash(String(x.worktree || '')), x])) : null
const byPatch = gr ? new Map(gr.results.map(x => [x.patch, x])) : null

// grade() — SINGLE OWNER of a candidate's status. pass = its worktree diff applied
// at the sha AND the checks exited 0 in patch-check's own worktree. Nothing the
// candidate said counts, and a leak voids every grade.
function grade(r) {
  const g = gradeOf(r)
  if (leakInfo.leak === true) return Object.assign({}, g, { status: 'invalid', tail: `LEAK — ${leakInfo.detail || 'the real repo changed during the run'}` })
  return g
}
function gradeOf(r) {
  const none = (status, tail) => ({ status, applies: null, rc: null, diffstat: null, patch: null, tail })
  if (!r.available) return none('unavailable', r.reason)
  if (!gr) return none('ungraded', 'the grader returned nothing')
  const d = byDiff.get(r.c.worktree)
  if (!d || d.ok !== true) return none('ungraded', `worktree diff failed: ${(d && d.error) || 'no diff result'}`)
  const pc = byPatch.get(r.c.patch)
  if (!pc) return none('ungraded', 'patch-check produced no result for this patch')
  const status = pc.applies === true && pc.rc === 0 ? 'pass' : 'fail'
  return { status, applies: pc.applies, rc: pc.rc, diffstat: pc.diffstat, patch: r.c.patch, tail: pc.tail }
}

const results = runs.map(r => {
  const g = grade(r)
  return {
    label: r.c.label, vendor: r.c.vendor, level: r.c.level, model: r.model, effort: r.c.effort,
    status: g.status, applies: g.applies, rc: g.rc, diffstat: g.diffstat,
    patch: g.patch,
    outTokens: r.outTokens, totalTokens: r.totalTokens, seconds: r.seconds,
    selfRc: r.selfRc,
    tail: g.tail == null ? null : String(g.tail).slice(-2000),
  }
})
const tally = s => results.filter(x => x.status === s).length
log(`Bake-off graded by patch-check at ${sha.slice(0, 12)}: ${tally('pass')} pass, ${tally('fail')} fail, ${tally('unavailable')} unavailable` +
  (tally('ungraded') ? `, ${tally('ungraded')} UNGRADED` : '') + (tally('invalid') ? `, ${tally('invalid')} INVALID (leak)` : '') +
  ' — nothing was applied to the repo.')
return {
  base, sha, leak: leakInfo.leak, baseMoved: leakInfo.baseMoved,
  graded: runs.every(r => gradeOf(r).status !== 'ungraded'),
  candidates: results,
}
