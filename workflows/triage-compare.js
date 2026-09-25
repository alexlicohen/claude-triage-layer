export const meta = {
  name: 'triage-compare',
  description: 'Bake-off. kind build (default): run one brief on several candidates (Claude levels, codex), each in its own staged worktree outside the repo, then grade every worktree diff independently with patch-check.sh. kind review: the same pinned snapshot + range diff to N reviewers in parallel, merge duplicate findings, blind cross-vendor adjudication, per-reviewer precision/recall. Never applies anything; the real repo is never a candidate or reviewer workdir.',
  whenToUse: 'Compare vendors/levels/models on the SAME well-specified task: /triage-compare with args = {repo, base?, brief, files, acceptance, checks:[cmd...], outDir, overlay?, selfCheckEnv?, candidates:[{vendor:claude|codex, level:quick|builder|deep|top, model?, effort?, label?}]} (agy was retired 2026-09-24 and is refused). repo is any absolute git repo path (not necessarily the session repo) and may be dirty: base (default HEAD) is resolved to ONE sha up front and each candidate works in its own detached worktree at that sha under <outDir>/stage (scripts/stage-worktree.sh), never in repo. outDir/overlay must be OUTSIDE repo and <outDir>/stage must not already exist. External (non-claude) candidates require args.files. Checks may name tools only as $PARITY_<NAME> variables (exported at grading by patch-check.sh from the parity env map; candidates see them unexpanded); selfCheckEnv:true copies <repo>/.parity-env into each worktree and tells candidates to source it. Candidates run one at a time (parallel:true runs them concurrently; Claude outTokens is then null); the grade is scripts/patch-check.sh on each worktree diff at the sha (plus the hidden overlay), never the candidate self-report; a leakcheck then proves repo did not change (only leak:false lets a grade stand: leak true OR unknown => every candidate invalid, graded:false; a patch patch-check could not grade, e.g. overlay-failed, is invalid). Returns sha/leak/baseMoved and per-candidate status/applies/rc/diffstat/patch/tokens/model/modelFrom (candidate|runner|null); the orchestrator picks and applies. REVIEW bake-off: args = {kind:"review", repo, repoName, base, head?, include:[globs], exclude?, context?, extras?:[{src,dest}], hardExclude?, groundTruth, accepted?, conventions?, outDir (fresh, outside repo), reviewers:[{vendor:claude|codex, level, model?, effort?, label?}] (codex needs model+effort), adjudicators? (default claude deep claude-opus-5-5·high + codex deep gpt-6-astra·high), batchSize?:10, reviewerTimeout?:"30m", adjudicatorTimeout?:"15m" (codex spawns only: passed as TIMEOUT= to the ext-run.sh watchdog), extendResult?:{the prior result OBJECT, inline}, supersedes?:[labels]}. scripts/review-stage.sh snapshots commit head (never the live tree; context/ and PROJECT_MEMORY*.md always hard-excluded) + the base..head range diff under outDir; reviewers read ONLY those (Claude: cd <snap> on every command; codex: INPUT_DIR, OS-confined); one deep agent merges duplicates (provenance kept here, anonymized); every merged item is judged by each adjudicator BLIND to reviewers and provenance: all real = real, all not-real/accepted-deviation = rejected, else disputed (for Alex). precision/recall per reviewer over non-disputed items; a failed or invalid reviewer is unavailable, never zero. Every codex prompt carries PROMPT_BYTES (the UTF-8 byte length of its prompt-file body) and the wrapper refuses a prompt file that is not verbatim. EXTEND (extendResult = the result OBJECT a prior run of this workflow returned, passed inline — the path form extend:"/file" is refused, a prior result never passes through an LLM; re-pass the args of the prior run with ONLY the new reviewers, base/head resolving to the prior shas, the prior outDir): the prior result is validated in code, then one quick task only checks that its snapshot still exists (manifest base/head = the prior shas); only the new reviewers run (labels must not collide with prior ones); the merge attaches each new finding to an existing item (provenance only, never re-adjudicated) or makes a new item (next id); only new items are adjudicated, blind, by the same panel; every non-superseded reviewer is rescored over the combined set (supersedes:[labels] keeps those prior runs as status superseded, unscored, their findings intact). Returns {kind, base, head, reviewers, items, disputed, sourceChanged, flags, markdown} (+ extendedFrom {base, head, outDir, reviewers, items}, newItems, superseded when extending); ingest with scripts/parity-report.sh ingest-review.',
  phases: [
    { title: 'Stage' },
    { title: 'Candidates' },
    { title: 'Grade' },
    { title: 'Snapshot' },
    { title: 'Reviewers' },
    { title: 'Merge' },
    { title: 'Adjudicate' },
    { title: 'Fingerprint' },
  ],
}

// ─── Entry contract ─────────────────────────────────────────────────────────
// A bake-off is a measurement, so everything that could make it unfair or unsafe is
// rejected in plain JS BEFORE any spawn: unknown or retired vendor, unknown level/effort,
// duplicate or path-unsafe labels, relative paths, no checks to grade by. A malformed
// plan is a caller bug and fails loudly and for free.
const LEVELS = ['quick', 'builder', 'deep', 'top']
const VENDORS = ['claude', 'codex']
// agy was retired 2026-09-24 (its headless mode let the model bypass its sandbox; a
// read-only run wrote into a real repo): refused by name, never silently unknown.
const RETIRED_VENDORS = { agy: 'agy was retired 2026-09-24 (it bypassed its own sandbox and wrote into a real repo) — use codex or claude' }
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
  '  selfCheckEnv?: false        // true = copy <repo>/.parity-env (parity-suite.sh materialize) into each worktree so candidates can run $PARITY_ checks\n' +
  `  candidates: [{ vendor: ${VENDORS.join('|')}, level: ${LEVELS.join('|')}, model?, effort?: ${EFFORTS.join('|')}, label? }]\n` +
  '  parallel?: false            // true = candidates run concurrently (Claude outTokens then null)\n}'

function bad(msg) {
  throw new Error(`triage-compare: ${msg}\n${USAGE}`)
}

const isStr = v => typeof v === 'string' && v.trim().length > 0
const typeName = v => (v === null ? 'null' : Array.isArray(v) ? 'an array' : typeof v)
// Paths and labels go into a header line and into shell commands, so: absolute,
// no whitespace, no quote characters.
const isAbsPath = v => isStr(v) && v.startsWith('/') && !/[\s'"`$\\]/.test(v)
const SAFE_TOKEN = /^[A-Za-z0-9._@+-]+$/
const stripSlash = v => String(v).replace(/\/+$/, '')
const shq = s => `'${String(s).replace(/'/g, `'\\''`)}'`
const firstLine = out => String(out || '').trimStart().split('\n')[0]
const errText = e => String((e && e.message) || e).slice(0, 200)
// UNAVAILABLE / REFUSED as a reply's FIRST line (triage-external's exit-code
// mapping), or no reply at all: the candidate produced nothing to grade.
const producedNothing = out => out == null || /^\s*(UNAVAILABLE|REFUSED)\b/i.test(String(out).trimStart())
// The accounting line ext-run.sh prints and triage-external relays:
//   ext-run: <N> tokens (<S>s, <vendor>/<model>)[ out=<M>]
const EXT_LINE = /ext-run:\s*(\d+)\s+tokens\s*\(([\d.]+)s,\s*([a-z]+)\/([^)\s]+)\)(?:\s+out=(\d+))?/
const SHA_RE = /^[0-9a-f]{40}([0-9a-f]{24})?$/

if (!args || typeof args !== 'object' || Array.isArray(args)) bad(`args must be an object (got ${typeName(args)}).`)
if (args.kind != null && args.kind !== 'build' && args.kind !== 'review') bad(`args.kind must be "build" (the default) or "review" (got ${JSON.stringify(args.kind)}).`)

// ─── kind:'review' — the review bake-off (runReview, at the end of this file) ──
// Its own contract and flow; the build flow below is untouched by it. Constants it
// needs are defined here, before the dispatch, so they exist when it runs.
const REVIEW_STAGE = '~/.claude/scripts/review-stage.sh'
const SEVERITIES = ['blocker', 'major', 'minor']
const VERDICTS = ['real', 'not-real', 'accepted-deviation', 'unsure']
// The default adjudicators = config/tiers.json levels.deep for each vendor (the DSL
// cannot read tiers.json; test/lint.sh fails when this line and the file disagree).
const DEFAULT_ADJUDICATORS = [{ vendor: 'claude', level: 'deep', model: 'claude-opus-5-5', effort: 'high' }, { vendor: 'codex', level: 'deep', model: 'gpt-6-astra', effort: 'high' }]
const REVIEW_USAGE = 'Expected args (kind:"review") = {\n' +
  '  kind: "review", repo: "/abs/repo", repoName: "bare-name",   // repo is never shown to a reviewer\n' +
  '  base: "<rev>", head?: "HEAD",                               // resolved to shas once; the snapshot is of head\n' +
  '  include: ["docs/**/*.md", ...], exclude?: [...], context?: [...], hardExclude?: [...],   // repo-relative globs\n' +
  '  extras?: [{src: "/abs/file outside repo", dest: "rel/path"}],                          // copied to <snap>/_extra/<dest>\n' +
  '  groundTruth: "text", accepted?: "text", conventions?: "text",\n' +
  '  outDir: "/abs/dir"                                          // fresh, outside repo: snap/, range.diff, manifest.json\n' +
  `  reviewers: [{ vendor: ${VENDORS.join('|')}, level: ${LEVELS.join('|')}, model?, effort?, label? }]   // codex: model + effort required\n` +
  '  adjudicators?: [>= 2, default claude deep claude-opus-5-5·high + codex deep gpt-6-astra·high], batchSize?: 10,\n' +
  '  reviewerTimeout?: "30m", adjudicatorTimeout?: "15m",            // codex only: N | Ns | Nm | Nh, at most 3h\n' +
  '  extendResult?: {the prior result object, inline}, supersedes?: ["prior label"]  // add reviewers to a prior review of the SAME snapshot:\n' +
  '                                // re-pass its args (outDir = its outDir; base/head resolving to its shas) with only the NEW reviewers\n}'

if (args.kind === 'review') return await runReview()
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
if (args.parallel != null && typeof args.parallel !== 'boolean') bad(`args.parallel must be true or false (got ${JSON.stringify(args.parallel)}).`)
if (args.selfCheckEnv != null && typeof args.selfCheckEnv !== 'boolean') bad(`args.selfCheckEnv must be true or false (got ${JSON.stringify(args.selfCheckEnv)}).`)
const runParallel = args.parallel === true
const selfCheckEnv = args.selfCheckEnv === true

const repo = args.repo.trim()
const base = (args.base || 'HEAD').trim()
const outDir = args.outDir.trim().replace(/\/+$/, '')
const overlay = args.overlay ? args.overlay.trim() : null
const stageDir = `${outDir}/stage`
const files = (args.files || []).map(f => f.trim())
const checks = args.checks.map(c => c.trim())
const checkCmd = checks.join(' && ')
// NO REAL PATHS TO CANDIDATES: a check names a tool only as $PARITY_<NAME>; the
// prompts show it UNEXPANDED. patch-check.sh exports the mapped paths at grading.
// A candidate can run such checks itself only when the task opted in
// (selfCheckEnv: <repo>/.parity-env is copied into its worktree — git-excluded, so
// it never enters the diff); otherwise it is told the checks run only at grading.
const usesParityEnv = checks.some(c => /\$\{?PARITY_[A-Z0-9_]/.test(c))
const ENV_LINE = 'To run the checks yourself, first run: . .parity-env'

const seen = new Set()
const candidates = args.candidates.map((raw, i) => {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`candidates[${i}] must be an object (got ${typeName(raw)}).`)
  if (typeof raw.vendor === 'string' && Object.prototype.hasOwnProperty.call(RETIRED_VENDORS, raw.vendor)) bad(`candidates[${i}].vendor ${JSON.stringify(raw.vendor)}: ${RETIRED_VENDORS[raw.vendor]}.`)
  if (!VENDORS.includes(raw.vendor)) bad(`candidates[${i}].vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(raw.vendor)}).`)
  if (!LEVELS.includes(raw.level)) bad(`candidates[${i}].level must be one of ${LEVELS.join('|')} (got ${JSON.stringify(raw.level)}).`)
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
const spentNow = () => (budget && typeof budget.spent === 'function' ? budget.spent() : null)
// The candidate's OWN check claim — informational only (selfRc), never the grade:
// a `CHECK rc=<n>` line, else the external worker's `DONE exit=<n>` sentinel.
const selfRcOf = out => {
  const m = String(out || '').match(/(^|\n)\s*CHECK rc=(\d+)/) || String(out || '').match(/(^|\n)\s*DONE exit=(\d+)/)
  return m ? Number(m[2]) : null
}

const task = `${args.brief.trim()}\n\nRelevant files: ${files.join(', ') || '(discover)'}\nAcceptance criteria: ${args.acceptance.trim()}`
const stageCmd = `${STAGE_WT} create --repo ${shq(repo)} --base ${shq(base)} --count ${candidates.length} --dir ${shq(stageDir)}` +
  (selfCheckEnv ? candidates.map(c => ` && cp ${shq(`${repo}/.parity-env`)} ${shq(`${c.worktree}/.parity-env`)}`).join('') : '')
const cleanupCmd = `${STAGE_WT} cleanup --repo ${shq(repo)} --dir ${shq(stageDir)}`

// The real repo is never a candidate's working directory: each one is pointed at
// its own staged worktree (c.worktree), and repo appears in a Claude prompt only
// as the place it must stay out of. A subagent's Bash cwd is RESET between calls,
// so a one-time `cd` does not persist: every shell command carries its own
// `cd <worktree> && ` prefix, or a check would run (and leave build output) in
// the session repo — a wrong selfRc and a false LEAK.
function claudePrompt(c, sha) {
  const cdPrefix = `cd ${c.worktree} && `
  // With a self-check env, the env is sourced in the SAME command (nothing persists).
  const runPrefix = usesParityEnv && selfCheckEnv ? `${cdPrefix}. .parity-env && ` : cdPrefix
  return `${task}\n\n` +
    `--- Bake-off protocol (you are one candidate; others get the same brief) ---\n` +
    `Your workspace is the staged git worktree ${c.worktree} (detached at ${sha}).\n` +
    `Work only inside ${c.worktree}. Do not read, list or search any other directory on this machine (including other copies of this project); the task is graded only from your worktree.\n` +
    `Your shell's working directory is reset between commands, so a cd on its own does not stick: EVERY shell command you run MUST start with \`${cdPrefix}\` — for example \`${runPrefix}${checks[0]}\`.\n` +
    `Every file edit uses an absolute path under ${c.worktree}/.\n` +
    `The repository at ${repo} is NOT your workspace: never use a path under it, and never read from, modify, or run anything in it.\n` +
    (usesParityEnv && !selfCheckEnv
      ? 'The checks name their tools as $PARITY_ variables that are set only when your work is graded: you cannot run them here, so do not look for those tools, and end with CHECK rc=none. They are:\n'
      : (usesParityEnv ? `The checks name their tools as $PARITY_ variables. ${ENV_LINE} — in the same command, after the cd: \`${runPrefix}<check>\`.\n` : '') +
        `Run these checks, each prefixed with \`${runPrefix}\`:\n`) +
    `${checks.map(c2 => `  ${c2}`).join('\n')}\n` +
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
    (usesParityEnv ? (selfCheckEnv ? `The check names its tools as $PARITY_ variables. ${ENV_LINE}\n`
      : 'The check names its tools as $PARITY_ variables that are set only at grading: it cannot be run in the workdir.\n') : '') +
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
  // ─── Candidates: sequential by default, concurrent with parallel:true ──────
  // Sequential: one at a time, so each budget.spent() delta is that candidate's
  // Claude output tokens and nothing else (the pool is shared across the whole
  // turn). parallel:true runs them concurrently — safe, since each already has
  // its own staged worktree — but then no budget delta can be attributed to one
  // candidate, so a Claude candidate's outTokens is null (an external one keeps
  // the vendor's own count from its ext-run line). parity runs attribute Claude
  // cost afterwards from the transcripts (scripts/parity-cost.sh).
  phase('Candidates')
  async function runCandidate(c) {
    const external = c.vendor !== 'claude'
    if (!external && c.level === 'top') log(`⚠ Escalating to Fable: triage-compare candidate ${c.label}`)
    if (external) log(`⚠ External candidate ${c.label}: the workspace leaves this machine for ${c.vendor}.`)
    // No isolation:'worktree': the harness bases that on the default branch, not
    // on the sha every other candidate gets. The staged worktree is the isolation.
    const opts = external
      ? { phase: 'Candidates', agentType: 'triage-external', label: `candidate:${c.label}` }
      : Object.assign({ phase: 'Candidates', agentType: CLAUDE_AGENT[c.level], label: `candidate:${c.label}` },
          c.model ? { model: c.model } : {}, c.effort ? { effort: c.effort } : {})
    const before = runParallel ? null : spentNow()
    let out = null
    let err = null
    try {
      out = await agent(external ? externalPrompt(c, sha) : claudePrompt(c, sha), opts)
    } catch (e) {
      err = errText(e)   // e.g. the budget's hard ceiling
    }
    const after = runParallel ? null : spentNow()
    const claudeOut = before != null && after != null ? after - before : null
    const nothing = err != null || producedNothing(out)
    const ext = external && out ? String(out).match(EXT_LINE) : null
    const run = {
      c,
      available: !nothing,
      reason: err ? `spawn failed: ${err}` : out == null ? 'spawn returned nothing' : nothing ? firstLine(out).slice(0, 200) : null,
      selfRc: nothing ? null : selfRcOf(out),
      model: c.model || (ext ? ext[4] : null),
      // Claude: the output tokens this candidate cost (budget delta; null in
      // parallel mode). External: the vendor's own output count from the ext-run
      // line (null when it gave none).
      outTokens: external ? (ext && ext[5] != null ? Number(ext[5]) : null) : claudeOut,
      totalTokens: external && ext ? Number(ext[1]) : null,
      seconds: external && ext ? Number(ext[2]) : null,
    }
    if (!run.available) log(`⚠ ${c.label} unavailable (${run.reason}) — reported, not graded as a fail.`)
    return run
  }
  if (runParallel) {
    // parallel() maps a thrown thunk to null; runCandidate never throws, but a
    // null is still reported as unavailable, never dropped.
    const got = await parallel(candidates.map(c => () => runCandidate(c)))
    candidates.forEach((c, i) => runs.push(got[i] || { c, available: false, reason: 'candidate run failed', selfRc: null, model: c.model, outTokens: null, totalTokens: null, seconds: null }))
  } else {
    for (const c of candidates) runs.push(await runCandidate(c))
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
            error: { type: ['string', 'null'] },
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
    `results = patch-check's lines, one per patch, in order, including an error field whenever a line has one${graded.length ? '' : ' (none ran: [])'}; ` +
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
else if (leakInfo.leak == null) {
  log(`⚠ LEAK CHECK INCOMPLETE — could not confirm ${repo} is unchanged; inspect it before anything else (${leakInfo.detail}).` +
    (gr ? ' Every candidate is INVALID: no grade stands without a confirmed-clean repo.' : ''))
}
if (leakInfo.baseMoved) log(`⚠ BASE_MOVED: HEAD of ${repo} moved during the run; every candidate was graded at ${sha}.`)

const byDiff = gr ? new Map(gr.diffs.map(x => [stripSlash(String(x.worktree || '')), x])) : null
const byPatch = gr ? new Map(gr.results.map(x => [x.patch, x])) : null

// grade() — SINGLE OWNER of a candidate's status. pass = its worktree diff applied
// at the sha AND the checks exited 0 in patch-check's own worktree. Nothing the
// candidate said counts. A grade stands ONLY with leak === false: a leak voids
// every grade, and so does an UNKNOWN leak state (leakcheck errored or relayed
// nothing usable). A dead grader (gr null) leaves 'ungraded' — there was no grade
// to accept.
function grade(r) {
  const g = gradeOf(r)
  if (leakInfo.leak === true) return Object.assign({}, g, { status: 'invalid', tail: `LEAK — ${leakInfo.detail || 'the real repo changed during the run'}` })
  if (leakInfo.leak !== false && gr) return Object.assign({}, g, { status: 'invalid', tail: `LEAK STATE UNKNOWN — ${leakInfo.detail}` })
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
  // patch-check could not grade it (error, e.g. overlay-failed: the hidden tests
  // never ran), or relayed an applied patch with no rc: never a pass or a fail.
  if (pc.error != null || (pc.applies === true && pc.rc == null)) {
    return { status: 'invalid', applies: pc.applies, rc: null, diffstat: pc.diffstat, patch: r.c.patch, tail: `UNGRADABLE (${pc.error || 'applied, but no check rc'}) — ${pc.tail}` }
  }
  const status = pc.applies === true && pc.rc === 0 ? 'pass' : 'fail'
  return { status, applies: pc.applies, rc: pc.rc, diffstat: pc.diffstat, patch: r.c.patch, tail: pc.tail }
}

const results = runs.map(r => {
  const g = grade(r)
  return {
    label: r.c.label, vendor: r.c.vendor, level: r.c.level, model: r.model, effort: r.c.effort,
    // Where `model` came from: the candidate spec, the runner's own ext-run line
    // (parity-report.sh ledgers that as modelIdSource "observed"), or nowhere (null).
    modelFrom: r.c.model ? 'candidate' : r.model ? 'runner' : null,
    status: g.status, applies: g.applies, rc: g.rc, diffstat: g.diffstat,
    patch: g.patch,
    outTokens: r.outTokens, totalTokens: r.totalTokens, seconds: r.seconds,
    selfRc: r.selfRc,
    tail: g.tail == null ? null : String(g.tail).slice(-2000),
  }
})
const tally = s => results.filter(x => x.status === s).length
log(`Bake-off graded by patch-check at ${sha.slice(0, 12)}: ${tally('pass')} pass, ${tally('fail')} fail, ${tally('unavailable')} unavailable` +
  (tally('ungraded') ? `, ${tally('ungraded')} UNGRADED` : '') + (tally('invalid') ? `, ${tally('invalid')} INVALID` : '') +
  ' — nothing was applied to the repo.')
return {
  base, sha, leak: leakInfo.leak, baseMoved: leakInfo.baseMoved,
  graded: leakInfo.leak === false && results.every(x => x.status !== 'ungraded' && x.status !== 'invalid'),
  candidates: results,
}

// ═══ kind:'review' — REVIEW BAKE-OFF ═════════════════════════════════════════
// The same pinned snapshot and range diff go to N reviewers IN PARALLEL; none sees
// the live repo (scripts/review-stage.sh writes a snapshot of ONE commit plus the
// base..head diff under outDir, hard-excluding context/ and PROJECT_MEMORY*.md).
// One deep agent merges duplicate findings — provenance stays in THIS script,
// anonymized, never in a prompt. Every merged item is judged by each adjudicator
// BLIND to who (or how many) reported it: all real => real, all not-real /
// accepted-deviation => rejected, anything else => disputed (Alex decides).
// Precision/recall per reviewer count only items the adjudicators agree on; a
// reviewer that failed or returned no valid findings JSON is unavailable, never 0.
// Nothing is applied, and nothing is written outside outDir.
async function runReview() {
  const a = args
  const badR = msg => { throw new Error(`triage-compare (kind:"review"): ${msg}\n${REVIEW_USAGE}`) }
  const REV = /^[A-Za-z0-9._@+~^/-]+$/
  // A repo-relative glob: no leading / : or -, no . or .. component, single line.
  const globOk = g => isStr(g) && !/^[/:-]/.test(g.trim()) && !/[\n\r\t]/.test(g) && !/(^|\/)\.\.?(\/|$)/.test(g.trim())
  const globList = (v, name, required) => {
    if (v == null && !required) return []
    if (!Array.isArray(v) || (required && v.length === 0) || !v.every(globOk)) {
      badR(`args.${name} must be ${required ? 'a non-empty' : 'an'} array of repo-relative globs (no leading / : or -, no . or .. components).`)
    }
    return v.map(g => g.trim())
  }
  if (!isAbsPath(a.repo)) badR('args.repo must be an absolute path with no whitespace or quotes.')
  if (!(isStr(a.repoName) && /^[A-Za-z0-9._-]{1,64}$/.test(a.repoName.trim()))) badR('args.repoName must be a bare repo name (letters, digits, . _ -) — ledger metadata, never a path.')
  if (!(isStr(a.base) && REV.test(a.base.trim()))) badR(`args.base must be a revision name or sha (got ${JSON.stringify(a.base)}).`)
  if (a.head != null && !(isStr(a.head) && REV.test(a.head.trim()))) badR(`args.head must be a revision name or sha (got ${JSON.stringify(a.head)}).`)
  const include = globList(a.include, 'include', true)
  const exclude = globList(a.exclude, 'exclude', false)
  const context = globList(a.context, 'context', false)
  if (a.hardExclude != null && !(Array.isArray(a.hardExclude) && a.hardExclude.every(h => isStr(h) && !/^[:-]/.test(h.trim()) && !/[\n\r\t]/.test(h)))) {
    badR('args.hardExclude must be an array of gitignore-style patterns (context/ and PROJECT_MEMORY*.md are always applied).')
  }
  const hardExclude = (a.hardExclude || []).map(h => h.trim())
  if (!isStr(a.groundTruth)) badR('args.groundTruth must be a non-empty string: the ground-truth sources, in order of authority.')
  for (const k of ['accepted', 'conventions']) if (a[k] != null && typeof a[k] !== 'string') badR(`args.${k} must be a string when given.`)
  if (!isAbsPath(a.outDir)) badR('args.outDir must be an absolute path with no whitespace or quotes.')
  const repo = stripSlash(a.repo.trim())
  const outDir = stripSlash(a.outDir.trim())
  const within = (x, y) => x === y || x.startsWith(`${y}/`)
  if (within(outDir, repo) || within(repo, outDir)) badR('args.outDir must lie outside args.repo and must not contain it — a snapshot there would dirty the real tree.')
  if (a.extras != null && !Array.isArray(a.extras)) badR('args.extras must be an array of {src, dest}.')
  const extras = (a.extras || []).map((x, i) => {
    if (!x || typeof x !== 'object' || !isAbsPath(x.src) || !globOk(x.dest) || /:/.test(x.src) || /:/.test(x.dest)) {
      badR(`args.extras[${i}] must be {src: "/abs/file", dest: "relative/path"} (no whitespace, quotes or colons).`)
    }
    const src = stripSlash(x.src.trim())
    if (within(src, repo)) badR(`args.extras[${i}].src is inside args.repo — repo content comes only from the snapshotted commit.`)
    if (within(src, outDir)) badR(`args.extras[${i}].src is inside args.outDir.`)
    return { src, dest: x.dest.trim() }
  })
  if (a.batchSize != null && !(Number.isInteger(a.batchSize) && a.batchSize >= 1 && a.batchSize <= 50)) badR('args.batchSize must be an integer 1..50.')
  const batchSize = a.batchSize || 10
  // A codex review of a large snapshot outlasts ext-run's read-mode default (5m):
  // every codex reviewer / adjudicator gets an explicit TIMEOUT= for the watchdog.
  // Claude spawns are unaffected.
  const durSecs = v => {
    const m = /^([1-9][0-9]{0,5})([smh]?)$/.exec(v)
    return m ? Number(m[1]) * { '': 1, s: 1, m: 60, h: 3600 }[m[2]] : null
  }
  const timeoutOf = (name, dflt) => {
    const v = a[name]
    if (v == null) return dflt
    const s = isStr(v) ? durSecs(v.trim()) : null
    if (s == null || s > 3 * 3600) badR(`args.${name} must be a duration N, Ns, Nm or Nh of at most 3h, e.g. "${dflt}" (got ${JSON.stringify(v)}).`)
    return v.trim()
  }
  const reviewerTimeout = timeoutOf('reviewerTimeout', '30m')
  const adjudicatorTimeout = timeoutOf('adjudicatorTimeout', '15m')
  // EXTEND: the prior result OBJECT, passed inline (the workflow receives args verbatim).
  // The path form is refused: the DSL cannot read files, and a prior result (tens of KB)
  // relayed through an LLM is never verbatim — a large payload never passes through one.
  if (a.extend != null) {
    badR('args.extend (a path to a prior result) is refused: a prior result is never relayed through an LLM. Pass the prior result OBJECT itself, inline, ' +
      'as args.extendResult (the JSON the prior run returned — e.g. JSON.parse of its saved result file), together with the prior run\'s args and ONLY the new reviewers.')
  }
  if (a.extendResult != null && (typeof a.extendResult !== 'object' || Array.isArray(a.extendResult))) {
    badR(`args.extendResult must be the prior kind:"review" result OBJECT, passed inline (got ${typeName(a.extendResult)}).`)
  }
  const extending = a.extendResult != null
  if (a.supersedes != null) {
    if (!extending) badR('args.supersedes marks reviewers of a PRIOR result: it needs args.extendResult.')
    if (!(Array.isArray(a.supersedes) && a.supersedes.every(l => isStr(l) && SAFE_TOKEN.test(l.trim())))) badR('args.supersedes must be an array of prior reviewer labels.')
  }
  const supersedes = [...new Set((a.supersedes || []).map(l => l.trim()))]

  function spec(raw, what, i) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) badR(`${what}[${i}] must be an object (got ${typeName(raw)}).`)
    if (typeof raw.vendor === 'string' && Object.prototype.hasOwnProperty.call(RETIRED_VENDORS, raw.vendor)) badR(`${what}[${i}].vendor ${JSON.stringify(raw.vendor)}: ${RETIRED_VENDORS[raw.vendor]}.`)
    if (!VENDORS.includes(raw.vendor)) badR(`${what}[${i}].vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(raw.vendor)}).`)
    if (!LEVELS.includes(raw.level)) badR(`${what}[${i}].level must be one of ${LEVELS.join('|')} (got ${JSON.stringify(raw.level)}).`)
    if (raw.effort != null && !EFFORTS.includes(raw.effort)) badR(`${what}[${i}].effort must be one of ${EFFORTS.join('|')} (got ${JSON.stringify(raw.effort)}).`)
    if (raw.model != null && !(isStr(raw.model) && SAFE_TOKEN.test(raw.model))) badR(`${what}[${i}].model must be a model id with no spaces (got ${JSON.stringify(raw.model)}).`)
    // An external reviewer runs in ext-run read mode, whose default model is the
    // tiers.json READ-mode one, not the level's: it must say what it measures.
    if (raw.vendor !== 'claude' && (raw.model == null || raw.effort == null)) badR(`${what}[${i}]: a ${raw.vendor} entry must pin model and effort (read mode would otherwise run its own default model, not the level's).`)
    if (raw.label != null && !isStr(raw.label)) badR(`${what}[${i}].label must be a non-empty string when given.`)
    const label = raw.label ? raw.label.trim()
      : `${raw.vendor}-${raw.level}${raw.model ? `-${raw.model}` : ''}${raw.effort ? `-${raw.effort}` : ''}`
    if (!SAFE_TOKEN.test(label)) badR(`${what}[${i}]: label ${JSON.stringify(label)} is not file-name safe (letters, digits, . _ @ + -) — pass an explicit label.`)
    return { label, vendor: raw.vendor, level: raw.level, model: raw.model || null, effort: raw.effort || null }
  }
  const uniq = (list, what) => {
    const seen = new Set()
    for (const x of list) {
      if (seen.has(x.label)) badR(`duplicate ${what} label "${x.label}" — labels must be unique.`)
      seen.add(x.label)
    }
    return list
  }
  if (!Array.isArray(a.reviewers) || a.reviewers.length === 0) badR('args.reviewers must be a non-empty array.')
  const reviewers = uniq(a.reviewers.map((r, i) => spec(r, 'reviewers', i)), 'reviewer')
  if (a.adjudicators != null && !(Array.isArray(a.adjudicators) && a.adjudicators.length >= 2)) badR('args.adjudicators must be an array of at least two (blind, independent) adjudicators.')
  const adjudicators = uniq((a.adjudicators || DEFAULT_ADJUDICATORS).map((j, i) => spec(j, 'adjudicators', i)), 'adjudicator')

  const base = a.base.trim()
  const headRef = (a.head || 'HEAD').trim()
  const groundTruth = a.groundTruth.trim()
  const accepted = (a.accepted || '').trim()
  const conventions = (a.conventions || '').trim()
  const snap = `${outDir}/snap`
  const diffPath = `${outDir}/range.diff`
  const fpBefore = `${outDir}/fingerprint-before.json`
  // An extension keeps the prior run's after-fingerprint and writes its own.
  const fpAfter = extending ? `${outDir}/fingerprint-extend.json` : `${outDir}/fingerprint-after.json`
  const flags = []
  const flag = m => { flags.push(m); log(`⚠ ${m}`) }
  // Label-blind deterministic order (FNV-1a) — the DSL has no Math.random.
  const hashStr = str => {
    let h = 0x811c9dc5
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 }
    return h
  }
  const q = xs => xs.map(shq).join(' ')
  // UTF-8 byte length in pure JS (no Buffer in the DSL); a lone surrogate counts 3,
  // as an encoder writes it (U+FFFD).
  const utf8Bytes = str => {
    let n = 0
    for (const ch of String(str)) {
      const cp = ch.codePointAt(0)
      n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4
    }
    return n
  }

  // ─── extend: the prior result arrives INLINE (args.extendResult) ─────────────
  // It is validated HERE, in code, before any spawn: its shape, repoName/outDir against
  // the args, base/head against args.base/head when those are shas, and the caller
  // errors (label collisions, supersedes, the adjudicator panel). Then ONE quick task
  // runs one tiny jq command — rev-parse of args.base/head, snap/ + range.diff present,
  // manifest.json base/head and a few scalars — whose small JSON is compared here with
  // the prior shas; a failed or mismatched check is retried once, then refused before
  // any reviewer runs. No item or reviewer of the prior result ever passes through an LLM.
  const refuseExtend = msg => { throw new Error(`triage-compare (kind:"review", extend): refused — ${msg}. No reviewer ran.`) }
  const strOrNull = v => v == null || typeof v === 'string'
  const numOrNull = v => v == null || (typeof v === 'number' && isFinite(v))
  const plainObj = v => !!v && typeof v === 'object' && !Array.isArray(v)
  function priorShapeProblem(p) {
    if (p.kind !== 'review') return `args.extendResult is not a kind:"review" result (kind ${JSON.stringify(p.kind)})`
    if (!(isStr(p.base) && SHA_RE.test(p.base) && isStr(p.head) && SHA_RE.test(p.head))) return 'args.extendResult carries no base/head shas'
    if (p.repoName !== a.repoName.trim()) return `the prior result is for repoName ${JSON.stringify(p.repoName)}, not ${JSON.stringify(a.repoName.trim())}`
    if (!isStr(p.outDir) || stripSlash(p.outDir.trim()) !== outDir) return `the prior outDir is ${JSON.stringify(p.outDir)}, not args.outDir ${outDir} — an extension reads the prior snapshot: pass its outDir`
    if (!Array.isArray(p.items) || !Array.isArray(p.reviewers) || p.reviewers.length === 0) return 'args.extendResult has no items[] or no reviewers[]'
    if (!p.reviewers.every(r => plainObj(r) && isStr(r.label) && SAFE_TOKEN.test(r.label) && isStr(r.vendor) && isStr(r.level) &&
      strOrNull(r.model) && strOrNull(r.effort) && strOrNull(r.reason) && (r.findings == null || Number.isInteger(r.findings)) && numOrNull(r.tokens) && numOrNull(r.seconds))) {
      return 'a prior reviewer is malformed (label, vendor, level, model, effort, findings, tokens, seconds or reason)'
    }
    const labels = p.reviewers.map(r => r.label)
    if (new Set(labels).size !== labels.length) return 'the prior reviewer labels are not unique'
    if (!p.reviewers.every(r => ['ok', 'unavailable', 'superseded'].includes(r.status))) return 'a prior reviewer has an unknown status'
    if (!p.items.every(it => plainObj(it) && isStr(it.file) && Number.isInteger(it.line) && it.line >= 0 && SEVERITIES.includes(it.severity) &&
      typeof it.category === 'string' && isStr(it.claim) && typeof it.evidence === 'string' && typeof it.suggestedFix === 'string' &&
      ['real', 'rejected', 'disputed'].includes(it.verdict) &&
      Array.isArray(it.adjudication) && it.adjudication.every(x => plainObj(x) && isStr(x.adjudicator) && isStr(x.vendor) && strOrNull(x.verdict) && strOrNull(x.evidence)) &&
      Array.isArray(it.foundBy) && it.foundBy.every(isStr))) {
      return 'a prior item is malformed (file, line, severity, category, claim, evidence, suggestedFix, verdict, adjudication or foundBy)'
    }
    const ids = p.items.map(it => it.id)
    if (!ids.every(id => isStr(id) && /^M[1-9][0-9]*$/.test(id)) || new Set(ids).size !== ids.length) return 'the prior item ids are not unique M<n> ids'
    const stray = p.items.flatMap(it => it.foundBy.filter(l => !labels.includes(l)).map(l => `${it.id}:${l}`))
    if (stray.length) return `prior items name reviewers that are not in the prior result (${stray.slice(0, 5).join(', ')})`
    if (p.flags != null && !(Array.isArray(p.flags) && p.flags.every(f => typeof f === 'string'))) return 'the prior flags are not a list of strings'
    if (p.mergeFallback != null && typeof p.mergeFallback !== 'boolean') return 'the prior mergeFallback is not a boolean'
    if (p.sourceChanged != null && typeof p.sourceChanged !== 'boolean') return 'the prior sourceChanged is not a boolean or null'
    return null
  }
  // A fresh projection of the fields the extension uses — args.extendResult itself is never mutated.
  const nul = v => (v == null ? null : v)
  const projectPrior = p => ({
    kind: 'review', repoName: p.repoName, base: p.base, head: p.head, outDir,
    mergeFallback: p.mergeFallback === true, sourceChanged: nul(p.sourceChanged), flags: (p.flags || []).slice(),
    reviewers: p.reviewers.map(r => ({ label: r.label, vendor: r.vendor, level: r.level, model: nul(r.model), effort: nul(r.effort), status: r.status,
      findings: nul(r.findings), tokens: nul(r.tokens), seconds: nul(r.seconds), reason: nul(r.reason) })),
    items: p.items.map(it => ({ id: it.id, file: it.file, line: it.line, severity: it.severity, category: it.category, claim: it.claim, evidence: it.evidence,
      suggestedFix: it.suggestedFix, verdict: it.verdict, adjudication: it.adjudication.map(x => ({ adjudicator: x.adjudicator, vendor: x.vendor, verdict: nul(x.verdict), evidence: nul(x.evidence) })),
      foundBy: it.foundBy.slice() })),
  })
  // Everything checkable without a spawn. Returns the projected prior.
  function acceptPrior() {
    const why = priorShapeProblem(a.extendResult)
    if (why) refuseExtend(why)
    const p = projectPrior(a.extendResult)
    // A sha passed as base/head resolves to itself: a mismatch needs no spawn to see.
    if ((SHA_RE.test(base) && base !== p.base) || (SHA_RE.test(headRef) && headRef !== p.head)) {
      refuseExtend(`base/head mismatch: args.base ${base} / args.head ${headRef}, the prior result is ${p.base}..${p.head} — pass the prior shas`)
    }
    const priorLabels = p.reviewers.map(r => r.label)
    const clash = reviewers.filter(r => priorLabels.includes(r.label)).map(r => r.label)
    if (clash.length) refuseExtend(`new reviewer label(s) ${clash.join(', ')} collide with the prior result's reviewers — give the new runs new labels (and supersede the old ones if they are re-runs)`)
    const unknown = supersedes.filter(l => !priorLabels.includes(l))
    if (unknown.length) refuseExtend(`supersedes names ${unknown.join(', ')}, which the prior result has no reviewer for`)
    // New items are judged by the panel that judged the prior ones, or the scores mix panels.
    const priorPanel = [...new Set(p.items.flatMap(it => it.adjudication.map(x => x.adjudicator)))].sort()
    const panel = adjudicators.map(j => j.label).sort()
    if (p.items.length && priorPanel.join() !== panel.join()) {
      refuseExtend(`the prior items were adjudicated by ${priorPanel.join(', ')}; new items must be judged by the same panel (got ${panel.join(', ')}) — pass the prior run's adjudicators`)
    }
    return p
  }
  // The ONE spawn of the extend load: a tiny check of the snapshot on disk.
  const CHECK_JQ = '(($man[0] // {})) as $m | {ok: true, resolvedBase: $rb, resolvedHead: $rh, manifestBase: $m.base, manifestHead: $m.head,' +
    ' snapshotExists: ($snap == "yes"), snapshotOk: ($snap == "yes" and $m.base == $pb and $m.head == $ph),' +
    ' fingerprintExists: ($fp == "yes"), codexDenied: ($m.codexDenied == true),' +
    ' files: (($m.files // []) | length), extras: (($m.extras // []) | length),' +
    ' diffBytes: ($db | tonumber? // null), snapKB: ($kb | tonumber? // null)}'
  const checkCmd = p => `jq -n -c --arg pb ${shq(p.base)} --arg ph ${shq(p.head)}` +
    ` --arg snap "$([ -d ${shq(snap)} ] && [ -f ${shq(diffPath)} ] && echo yes)"` +
    ` --arg fp "$([ -f ${shq(fpBefore)} ] && echo yes)"` +
    ` --arg rb "$(git -C ${shq(repo)} rev-parse --verify --quiet ${shq(`${base}^{commit}`)})"` +
    ` --arg rh "$(git -C ${shq(repo)} rev-parse --verify --quiet ${shq(`${headRef}^{commit}`)})"` +
    ` --arg db "$(wc -c < ${shq(diffPath)} 2>/dev/null | tr -d ' ')" --arg kb "$(du -sk ${shq(snap)} 2>/dev/null | cut -f1)"` +
    ` --slurpfile man ${shq(`${outDir}/manifest.json`)} ${shq(CHECK_JQ)}`
  const STR = { type: 'string' }
  const STR_N = { type: ['string', 'null'] }
  const INT_N = { type: ['integer', 'null'] }
  const BOOL = { type: 'boolean' }
  const CHECK_SCHEMA = {
    type: 'object',
    properties: {
      ok: BOOL, error: STR, resolvedBase: STR, resolvedHead: STR, manifestBase: STR_N, manifestHead: STR_N,
      snapshotExists: BOOL, snapshotOk: BOOL, fingerprintExists: BOOL, codexDenied: BOOL,
      files: INT_N, extras: INT_N, diffBytes: INT_N, snapKB: INT_N,
    },
    required: ['ok'],
  }
  const short = v => String(v || '?').slice(0, 12)
  function checkProblem(c, p) {
    if (!c || typeof c !== 'object') return 'the snapshot check returned nothing'
    if (c.ok !== true) return `the prior snapshot is gone or unreadable (${String(c.error || 'the check printed no JSON').slice(0, 200)}) — ${outDir}/manifest.json, snap/ and range.diff must exist`
    if (c.resolvedBase !== p.base || c.resolvedHead !== p.head) {
      return `base/head mismatch: args.base ${base} / args.head ${headRef} resolve to ${short(c.resolvedBase)}..${short(c.resolvedHead)}, the prior result is ${short(p.base)}..${short(p.head)} — pass the prior shas`
    }
    if (!(c.snapshotExists === true && c.snapshotOk === true && c.manifestBase === p.base && c.manifestHead === p.head)) {
      return `the prior snapshot is gone or is not the prior result's (${snap}, ${diffPath} and manifest.json base/head must all match)`
    }
    return null
  }
  async function loadPrior(p) {
    let why = null
    for (let attempt = 1; attempt <= 2; attempt++) {
      let c = null
      try {
        c = await agent('Run this one command exactly as written and return the JSON object it prints, field for field. ' +
          'If it printed no JSON object, return ok false and error = the last line of its stderr. Do not run anything else, and do not interpret or fix anything.\n' + checkCmd(p),
          { phase: 'Snapshot', agentType: 'triage-quick-task', label: attempt === 1 ? 'review:extend-check' : 'review:extend-check#retry', schema: CHECK_SCHEMA })
      } catch (e) {
        why = `the snapshot check spawn failed (${errText(e)})`
        continue
      }
      why = checkProblem(c, p)
      if (!why) {
        return Object.assign(p, {
          fingerprintExists: c.fingerprintExists === true, codexDenied: c.codexDenied === true,
          files: nul(c.files), extras: nul(c.extras), diffBytes: nul(c.diffBytes), snapKB: nul(c.snapKB),
        })
      }
    }
    refuseExtend(why)
  }

  // An extension's prior result is refused (or accepted) here, before any spawn.
  const priorIn = extending ? acceptPrior() : null

  // ─── (a) Snapshot + fingerprint: ONE quick task ─────────────────────────────
  phase('Snapshot')
  const hardArgs = hardExclude.length ? ` --hard-exclude ${q(hardExclude)}` : ''
  const fpCmd = out => `${REVIEW_STAGE} fingerprint --repo ${shq(repo)} --path ${q(include.concat(context))}${hardArgs} --out ${shq(out)}`
  const snapCmd = `${REVIEW_STAGE} snapshot --repo ${shq(repo)} --base ${shq(base)} --head ${shq(headRef)} --include ${q(include)}` +
    (exclude.length ? ` --exclude ${q(exclude)}` : '') + (context.length ? ` --context ${q(context)}` : '') +
    (extras.length ? ` --extra ${q(extras.map(x => `${x.src}:${x.dest}`))}` : '') + `${hardArgs} --out ${shq(outDir)}`
  const SNAP_SCHEMA = {
    type: 'object',
    properties: {
      snapshot: {
        type: 'object',
        properties: { ok: { type: 'boolean' }, base: { type: 'string' }, head: { type: 'string' }, files: { type: 'integer' }, bytes: { type: 'integer' },
          diffBytes: { type: 'integer' }, extras: { type: 'integer' }, excluded: { type: 'integer' }, codexDenied: { type: 'boolean' }, error: { type: 'string' } },
        required: ['ok'],
      },
      fingerprint: { type: 'object', properties: { rc: { type: ['integer', 'null'] }, head: { type: 'string' } }, required: ['rc'] },
    },
    required: ['snapshot', 'fingerprint'],
  }
  // sn = {files, extras, diffBytes, bytes} of the snapshot the reviewers read.
  let sn = null
  let baseSha = null
  let headSha = null
  let fpOk = false
  let prior = null
  if (!extending) {
    let st = null
    let stErr = null
    try {
      st = await agent('Run these two commands in order, each exactly as written; run the second only if the first exited 0. Do not run anything else, and do not interpret or fix anything.\n' +
        `${snapCmd}\n${fpCmd(fpBefore)}\n\n` +
        'Each prints one JSON line on stdout. Return snapshot = the first one\'s fields, field for field (if it printed no JSON line: ok false and error = the last line of its stderr), and fingerprint = rc (the second command\'s exit status, null if it did not run) and head from its JSON line.',
        { phase: 'Snapshot', agentType: 'triage-quick-task', label: 'review:snapshot', schema: SNAP_SCHEMA })
    } catch (e) {
      stErr = errText(e)
    }
    sn = st && st.snapshot
    if (!(sn && sn.ok === true && isStr(sn.base) && SHA_RE.test(sn.base.trim()) && isStr(sn.head) && SHA_RE.test(sn.head.trim()))) {
      throw new Error(`triage-compare (kind:"review"): the snapshot failed — no reviewer ran (${stErr || (sn && sn.error) || JSON.stringify(st).slice(0, 300)}). ` +
        `review-stage.sh removes a failed snapshot itself; ${outDir} must be empty (or absent) before a re-run.`)
    }
    baseSha = sn.base.trim()
    headSha = sn.head.trim()
    fpOk = !!(st.fingerprint && st.fingerprint.rc === 0)
    if (!fpOk) flag(`source fingerprint failed (rc ${st.fingerprint && st.fingerprint.rc}) — SOURCE_CHANGED cannot be checked for this review`)
    if (sn.diffBytes === 0) flag(`the range diff ${base}..${headRef} is EMPTY under the include globs — reviewers see the snapshot only`)
  } else {
    prior = await loadPrior(priorIn)
    sn = { files: prior.files, extras: prior.extras, diffBytes: prior.diffBytes, bytes: Number.isInteger(prior.snapKB) ? prior.snapKB * 1024 : null, codexDenied: prior.codexDenied === true }
    baseSha = prior.base
    headSha = prior.head
    fpOk = prior.fingerprintExists === true
    if (!fpOk) flag(`${fpBefore} is missing — SOURCE_CHANGED cannot be checked for this extension`)
  }
  const codexDenied = sn.codexDenied === true
  if (codexDenied) flag('the repo (or an extra) is off-limits to codex (.codex-deny / deny-list): codex reviewers and adjudicators are unavailable for this review')
  // ext-run.sh refuses an --input-dir over its size cap (default 200 MB): say so now,
  // not as a string of unavailable codex spawns later.
  if (!codexDenied && typeof sn.bytes === 'number' && sn.bytes > 200 * 1024 * 1024 && reviewers.concat(adjudicators).some(x => x.vendor !== 'claude')) {
    flag(`the snapshot is ${Math.round(sn.bytes / 1048576)} MB — over ext-run.sh's 200 MB --input-dir cap: codex reviewers/adjudicators will be refused (narrow include/context)`)
  }

  // ─── (b) Reviewers, in parallel ──────────────────────────────────────────────
  const FINDINGS_SCHEMA = {
    type: 'object',
    properties: {
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            file: { type: 'string' }, line: { type: 'integer' }, severity: { type: 'string', enum: SEVERITIES },
            category: { type: 'string' }, claim: { type: 'string' }, evidence: { type: 'string' }, suggestedFix: { type: 'string' },
          },
          required: ['file', 'line', 'severity', 'category', 'claim', 'evidence', 'suggestedFix'],
        },
      },
    },
    required: ['findings'],
  }
  // Ground truth, conventions and accepted deviations — verbatim, for every
  // reviewer and adjudicator alike, both vendors (so is the image-link note: codex's
  // image viewer failed on the markdown's URL-encoded paths).
  const IMAGE_NOTE = 'Image links in the markdown are URL-encoded (%5B = [, %5D = ], %20 = space, etc.): decode the path before opening the file.'
  const RULES = `--- Ground truth (in order of authority) ---\n${groundTruth}\n\n` +
    'A summary or replacement text — a reviewer\'s, the change author\'s, or yours — is NEVER ground truth. Evidence must cite a ground-truth source in the snapshot: its path relative to the snapshot root (extras are under _extra/), and a page, line or item where it has one.\n' +
    `${IMAGE_NOTE}\n\n` +
    (conventions ? `--- Conventions to check ---\n${conventions}\n\n` : '') +
    (accepted ? `--- Accepted deviations (accepted by Alex): do not flag these unless you cite NEW ground-truth evidence ---\n${accepted}\n\n` : '')
  const REVIEW_TASK = 'You are one of several independent reviewers of the SAME change; the others get the same inputs, and you will not see their findings.\n' +
    `Review the change in the range diff (${base}..${headRef}) against the ground truth and the conventions below: report every defect it introduces or leaves in the reviewed files. ` +
    'Report every finding you can support — do not filter by your own confidence — but never one you cannot support with ground-truth evidence.\n' +
    'Each finding: file = its path relative to the snapshot root; line = the 1-based line in the snapshot\'s version of that file (0 = the file as a whole); severity = blocker | major | minor; ' +
    'category = the rubric or convention code it falls under ("" if none); claim = what is wrong, in one or two sentences; evidence = the ground-truth source that shows it (snapshot path and page/line/item) and what it says; suggestedFix = one line ("" if none).\n\n'
  const readOnly = root => `Your shell's working directory is reset between commands, so EVERY shell command you run MUST start with \`cd ${root} && \` — for example \`cd ${root} && ls\`.\n` +
    'This is READ-ONLY work: never create, edit, move or delete any file, and never run git (the snapshot has no history; a git command would read some other repository).\n' +
    'You may view image files under the snapshot (page images, crops) with your file-reading tool.\n'
  function claudeReviewPrompt() {
    return `${REVIEW_TASK}${RULES}--- Review protocol ---\n` +
      `Your ONLY inputs: the snapshot directory ${snap} (the reviewed files at commit ${headSha}, their context files, and extras under ${snap}/_extra/) and the range diff ${diffPath}.\n` +
      'Read nothing else: do not read, list or search any other directory on this machine, and do not look for other copies of this project — anything outside the snapshot is not part of the review.\n' +
      readOnly(snap) +
      'Return findings = every finding, each once.'
  }
  // Every codex spawn: TIMEOUT= for ext-run.sh's watchdog, and PROMPT_BYTES = the
  // UTF-8 byte length of the prompt file the wrapper must write — the body after the
  // marker line plus ONE final newline. The wrapper (an LLM) checks it with wc -c and
  // refuses a prompt it did not carry verbatim (a paraphrased brief is a different
  // review). The body itself never ends in a newline, so no relay shows a stray line.
  function codexHeader(c, dir, timeout, promptBytes) {
    return `VENDOR=${c.vendor}\nMODE=read\nMODEL=${c.model}\nEFFORT=${c.effort}\nINPUT_DIR=${dir}\nTIMEOUT=${timeout}\nPROMPT_BYTES=${promptBytes}\n` +
      'The data boundary has been checked by the orchestrator for this material.\n'
  }
  // The wrapper protocol travels IN the brief as well as in agents/triage-cross-reviewer.md:
  // agent definitions appear to be cached when a session starts, so a wrapper spawned
  // after `make sync` can still run its old definition — one that drops TIMEOUT and
  // writes the prompt its own way. The two commands are the agent file's, verbatim
  // (compare-scenarios checks that they match).
  const PB_CHECK = 'P=<run dir>/prompt.txt; awk \'length($0) && !/^  / {x=1} END {exit x}\' "$P" && { sed \'s/^  //\' "$P" > "$P.u" && mv "$P.u" "$P"; }; [ -z "$(tail -c1 "$P")" ] || echo >> "$P"; wc -c < "$P" | tr -d \' \''
  const RC_WAIT = 'for i in $(seq 1 100); do [ -s <run dir>/rc ] && break; sleep 5; done; cat <run dir>/rc 2>/dev/null || echo RUNNING'
  const wrapperSteps = timeout => 'Wrapper steps for this run (they hold even if your standing instructions predate them):\n' +
    '1. Make a private run directory with mktemp -d "<your scratchpad directory, else ${TMPDIR:-/tmp}>/cross.XXXXXX" and write its path out literally in every later command (shell variables do not persist between commands). ' +
    'Put every file of this run in it, never at a fixed or shared path: other wrappers run at the same time.\n' +
    '2. Write the text after the marker line at the end of this brief into <run dir>/prompt.txt VERBATIM (no summarizing, shortening or rewording), ending with a newline, then run exactly:\n' +
    `   ${PB_CHECK}\n` +
    '   If the number it prints is not PROMPT_BYTES, write the file once more and run it again; if it still differs, reply REFUSED: prompt not verbatim, and stop.\n' +
    `3. Run ext-run.sh with --timeout ${timeout} (from the TIMEOUT line — the orchestrator's, not a flag of your own), its stdout to <run dir>/out and its stderr to <run dir>/err, followed by ; echo $? > <run dir>/rc — as ONE Bash call with timeout 600000. ` +
    'If Bash moves it to the background, repeat this until it prints a number, and never reply before it does (a background command dies with your reply):\n' +
    `   ${RC_WAIT}\n`
  const codexPrompt = (c, timeout, who, pre, body) => codexHeader(c, snap, timeout, utf8Bytes(`${body}\n`)) + wrapperSteps(timeout) + pre +
    `--- Brief for the external ${who}: all of what follows goes into the prompt file ---\n${body}`
  const schemaLine = sch => 'Write this exact JSON Schema to <run dir>/schema.json and pass it to ext-run.sh as --schema (read mode enforces it; the answer is JSON matching it):\n' +
    `${JSON.stringify(sch)}\n\n`
  function codexReviewPrompt(c) {
    return codexPrompt(c, reviewerTimeout, 'reviewer',
      `Pass exactly these inputs to ext-run.sh and nothing else: --input-dir ${snap} (from INPUT_DIR) and --input ${diffPath}\n` + schemaLine(FINDINGS_SCHEMA),
      REVIEW_TASK + RULES +
      `Your inputs are staged in your workspace: the snapshot directory "snap" (the reviewed files at commit ${headSha}, their context files, extras under snap/_extra/) and range.diff. ` +
      'Paths in your findings are relative to the snapshot root. Read only the staged files; never run git.\n' +
      'Output ONLY one JSON object {"findings": [...]} matching the schema — no other text.')
  }
  const cleanPath = f => String(f).trim().replace(/^\.\//, '').split(`${snap}/`).join('').replace(/^\/.*\/inputs\/snap\//, '')
  function cleanFindings(list) {
    const ok = []
    let dropped = 0
    for (const f of list) {
      const sev = f && typeof f.severity === 'string' ? f.severity.trim().toLowerCase() : ''
      const line = f && (Number.isInteger(f.line) ? f.line : (typeof f.line === 'string' && /^\d+$/.test(f.line.trim()) ? Number(f.line) : null))
      if (!f || typeof f !== 'object' || !isStr(f.file) || line == null || line < 0 || !SEVERITIES.includes(sev) || !isStr(f.claim) || !isStr(f.evidence)) { dropped++; continue }
      ok.push({ file: cleanPath(f.file), line, severity: sev, category: String(f.category || '').trim(), claim: f.claim.trim(), evidence: f.evidence.trim(), suggestedFix: String(f.suggestedFix || '').trim() })
    }
    return { ok, dropped }
  }
  // The first JSON object in an external reply (after its CROSS-REVIEW header).
  function parseJsonObject(text) {
    const body = String(text || '').split('\n').filter(l => !/^\s*(CROSS-REVIEW|ext-run:)/.test(l)).join('\n')
    const tries = []
    const i = body.indexOf('{')
    const j = body.lastIndexOf('}')
    if (i >= 0 && j > i) tries.push(body.slice(i, j + 1))
    for (const m of body.matchAll(/```(?:json)?\s*([\s\S]*?)```/g)) tries.push(m[1])
    for (const t of tries) {
      try { const v = JSON.parse(t); if (v && typeof v === 'object') return v } catch (e) { /* next */ }
    }
    return null
  }
  const fable = (who, x) => { if (x.vendor === 'claude' && x.level === 'top') log(`⚠ Escalating to Fable: triage-compare review ${who} ${x.label}`) }
  const claudeOpts = (x, phaseName, label, schema) => Object.assign({ phase: phaseName, agentType: CLAUDE_AGENT[x.level], label, schema },
    x.model ? { model: x.model } : {}, x.effort ? { effort: x.effort } : {})

  phase('Reviewers')
  for (const r of reviewers) {
    fable('reviewer', r)
    if (r.vendor !== 'claude' && !codexDenied) log(`⚠ External reviewer ${r.label}: the snapshot and range diff leave this machine for ${r.vendor}.`)
  }
  async function runReviewer(r) {
    const done = (status, extra) => Object.assign({ r, status, reason: null, findings: [], dropped: 0, tokens: null, seconds: null }, extra)
    if (r.vendor !== 'claude' && codexDenied) return done('unavailable', { reason: 'the repo is off-limits to codex (.codex-deny carried into the snapshot)' })
    let out = null
    try {
      out = await agent(r.vendor === 'claude' ? claudeReviewPrompt() : codexReviewPrompt(r),
        r.vendor === 'claude' ? claudeOpts(r, 'Reviewers', `reviewer:${r.label}`, FINDINGS_SCHEMA)
          : { phase: 'Reviewers', agentType: 'triage-cross-reviewer', label: `reviewer:${r.label}` })
    } catch (e) {
      return done('unavailable', { reason: `spawn failed: ${errText(e)}` })
    }
    if (r.vendor === 'claude') {
      if (!out || !Array.isArray(out.findings)) return done('unavailable', { reason: 'the reviewer returned no findings object' })
      const c = cleanFindings(out.findings)
      return done('ok', { findings: c.ok, dropped: c.dropped })
    }
    if (producedNothing(out)) return done('unavailable', { reason: firstLine(out).slice(0, 200) || 'no reply' })
    const ext = String(out).match(EXT_LINE)
    const cost = { tokens: ext ? Number(ext[1]) : null, seconds: ext ? Number(ext[2]) : null }
    const p = parseJsonObject(out)
    if (!p || !Array.isArray(p.findings)) return done('unavailable', Object.assign({ reason: 'the reply held no valid {"findings": [...]} JSON' }, cost))
    const c = cleanFindings(p.findings)
    return done('ok', Object.assign({ findings: c.ok, dropped: c.dropped }, cost))
  }
  const got = await parallel(reviewers.map(r => () => runReviewer(r)))
  const runs = reviewers.map((r, i) => got[i] || { r, status: 'unavailable', reason: 'reviewer run failed', findings: [], dropped: 0, tokens: null, seconds: null })
  for (const x of runs) {
    if (x.status !== 'ok') log(`⚠ reviewer ${x.r.label} unavailable (${x.reason}) — reported, never scored as zero.`)
    else if (x.dropped) flag(`reviewer ${x.r.label}: ${x.dropped} malformed finding(s) dropped (missing file/line/severity/claim/evidence)`)
  }
  // EXTEND: the prior reviewer runs join as rows of their own — rescored over the
  // combined items unless superseded (kept, status superseded, never scored; their
  // findings stay in the items with provenance intact).
  const supersededSet = new Set(supersedes)
  const priorRows = prior ? prior.reviewers.map(p => ({
    r: { label: p.label, vendor: p.vendor, level: p.level, model: p.model == null ? null : p.model, effort: p.effort == null ? null : p.effort },
    status: supersededSet.has(p.label) || p.status === 'superseded' ? 'superseded' : p.status,
    priorStatus: p.status, reason: p.reason == null ? null : p.reason, count: Number.isInteger(p.findings) ? p.findings : null,
    tokens: p.tokens == null ? null : p.tokens, seconds: p.seconds == null ? null : p.seconds, prior: true,
  })) : []
  const rows = priorRows.concat(runs)
  // Anonymized reviewer ids R1..Rn over every row, in a label-blind hash order. The map stays here.
  const anonOrder = rows.slice().sort((x, y) => hashStr(`r:${x.r.label}`) - hashStr(`r:${y.r.label}`) || (x.r.label < y.r.label ? -1 : 1))
  anonOrder.forEach((x, i) => { x.rid = `R${i + 1}` })
  const ridOfLabel = new Map(rows.map(x => [x.r.label, x.rid]))
  const labelOfRid = new Map(rows.map(x => [x.rid, x.r.label]))

  // ─── (c) Merge duplicates: ONE deep agent, opaque finding ids ───────────────
  // Findings get opaque ids F1..Fm (sorted by location + a content hash, never by
  // reviewer), so the merge agent sees neither labels nor reviewer ids. An extension
  // shows the prior items too (ids, text — never verdicts or provenance): each new
  // finding attaches to one of them or joins a new item.
  const flat = []
  for (const x of runs) if (x.status === 'ok') for (const f of x.findings) flat.push(Object.assign({ rid: x.rid }, f))
  flat.sort((x, y) => (x.file < y.file ? -1 : x.file > y.file ? 1 : 0) || x.line - y.line || hashStr(x.claim) - hashStr(y.claim))
  flat.forEach((f, i) => { f.fid = `F${i + 1}` })
  const byFid = new Map(flat.map(f => [f.fid, f]))
  const pub = f => ({ id: f.fid, file: f.file, line: f.line, severity: f.severity, category: f.category, claim: f.claim, evidence: f.evidence, suggestedFix: f.suggestedFix })
  const pubItem = it => ({ id: it.id, file: it.file, line: it.line, severity: it.severity, category: it.category, claim: it.claim, evidence: it.evidence, suggestedFix: it.suggestedFix })
  const sevRank = s => SEVERITIES.length - SEVERITIES.indexOf(s)
  const topSev = list => list.map(f => f.severity).sort((x, y) => sevRank(y) - sevRank(x))[0]
  // The prior items: ids, text, verdict and adjudication fixed; provenance from foundBy.
  const priorItems = prior ? prior.items.map(p => Object.assign(pubItem(p), {
    verdict: p.verdict, adjudication: p.adjudication, prov: [...new Set(p.foundBy.map(l => ridOfLabel.get(l)))].sort(),
  })) : []
  const priorById = new Map(priorItems.map(it => [it.id, it]))
  // A cluster of findings -> a NEW item, with the merge agent's text where it gave one.
  const groupOf = (members, it) => {
    const fs = members.map(id => byFid.get(id))
    return {
      members, file: isStr(it.file) ? cleanPath(it.file) : fs[0].file, line: Number.isInteger(it.line) && it.line >= 0 ? it.line : fs[0].line,
      severity: SEVERITIES.includes(it.severity) ? it.severity : topSev(fs), category: typeof it.category === 'string' ? it.category.trim() : fs[0].category,
      claim: isStr(it.claim) ? it.claim.trim() : fs[0].claim, evidence: isStr(it.evidence) ? it.evidence.trim() : fs.map(f => f.evidence).join(' | '),
      suggestedFix: typeof it.suggestedFix === 'string' ? it.suggestedFix.trim() : fs[0].suggestedFix,
    }
  }
  const attached = new Map()   // extend: finding id -> the prior item it reports
  let groups = null
  let mergeFallback = false
  if (prior ? flat.length > 0 && (priorItems.length > 0 || flat.length > 1) : flat.length > 1) {
    phase('Merge')
    const fieldProps = {
      file: { type: 'string' }, line: { type: 'integer' }, severity: { type: 'string', enum: SEVERITIES },
      category: { type: 'string' }, claim: { type: 'string' }, evidence: { type: 'string' }, suggestedFix: { type: 'string' },
    }
    const MERGE_SCHEMA = {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: prior
            ? { type: 'object', properties: Object.assign({ members: { type: 'array', items: { type: 'string' } }, existing: { type: 'string' } }, fieldProps), required: ['members', 'existing'] }
            : { type: 'object', properties: Object.assign({ members: { type: 'array', items: { type: 'string' } } }, fieldProps),
              required: ['members', 'file', 'line', 'severity', 'category', 'claim', 'evidence', 'suggestedFix'] },
        },
      },
      required: ['items'],
    }
    const mergePrompt = prior
      ? 'Merge NEW review findings into an EXISTING list of merged items. The EXISTING items (ids M…) were merged earlier from independent reviewers of one change; the NEW findings (ids F…) come from further independent reviewers of the same change (anonymous; ids are opaque).\n' +
        'For each NEW finding: if it reports the SAME defect as an EXISTING item — the same location or the same underlying problem, however worded — attach it to that item. Otherwise it belongs to a new item: cluster NEW findings that report the same defect as each other into one new item. ' +
        'Do not merge findings that are merely similar, or different defects in the same file.\n' +
        'Do not judge whether any finding is correct, do not change any EXISTING item, and do not drop any NEW finding: every F id goes into exactly one entry.\n' +
        'For each entry return members = its F ids and existing = the id of the EXISTING item they attach to, or "" for a new item. For a new item also return file and line (of the clearest member), severity = the highest among its members, category, ' +
        'claim = a faithful consolidation of the members\' claims (add nothing of your own), evidence = the members\' cited evidence combined, suggestedFix.\n' +
        'Work only from the lists below; do not read any file.\n\n' +
        `--- EXISTING items (${priorItems.length}) ---\n${priorItems.map(it => JSON.stringify(pubItem(it))).join('\n')}\n\n` +
        `--- NEW findings (${flat.length}) ---\n${flat.map(f => JSON.stringify(pub(f))).join('\n')}`
      : 'Merge DUPLICATE review findings. Below are findings from several independent reviewers of one change (anonymous; ids are opaque).\n' +
        'Cluster findings that report the SAME defect — the same location or the same underlying problem, however worded. Do not merge findings that are merely similar, or different defects in the same file. ' +
        'Do not judge whether any finding is correct, and do not drop any: every input id goes into exactly one item (a finding with no duplicate is an item of its own).\n' +
        'For each item return members = the ids it merges, file and line (of the clearest member), severity = the highest among its members, category, ' +
        'claim = a faithful consolidation of the members\' claims (add nothing of your own), evidence = the members\' cited evidence combined, suggestedFix.\n' +
        'Work only from the list below; do not read any file.\n\n' +
        `${flat.map(f => JSON.stringify(pub(f))).join('\n')}`
    let mr = null
    for (let attempt = 1; attempt <= 2 && !(mr && Array.isArray(mr.items)); attempt++) {
      try {
        mr = await agent(mergePrompt, { phase: 'Merge', agentType: CLAUDE_AGENT.deep, label: attempt === 1 ? 'review:merge' : 'review:merge#retry', schema: MERGE_SCHEMA })
      } catch (e) {
        mr = null
      }
    }
    if (mr && Array.isArray(mr.items)) {
      // The merge agent proposes clusters; membership is enforced HERE: unknown ids
      // are ignored, an id already placed stays in its first item, and a finding
      // the agent left out becomes an item of its own. Only a real prior item id can
      // be attached to.
      const placed = new Set()
      groups = []
      for (const it of mr.items) {
        const members = [...new Set(Array.isArray(it.members) ? it.members : [])].filter(id => byFid.has(id) && !placed.has(id))
        if (!members.length) continue
        members.forEach(id => placed.add(id))
        const target = prior && isStr(it.existing) && priorById.has(it.existing.trim()) ? it.existing.trim() : null
        if (target) {
          members.forEach(id => attached.set(id, target))
          continue
        }
        if (prior && isStr(it.existing)) flag(`the merge attached finding(s) to ${JSON.stringify(it.existing.trim().slice(0, 20))}, which is no prior item — kept as a new item`)
        groups.push(groupOf(members, it))
      }
      const left = flat.filter(f => !placed.has(f.fid))
      if (left.length) flag(`the merge left ${left.length} finding(s) unplaced — each kept as an item of its own`)
      for (const f of left) groups.push(Object.assign({ members: [f.fid] }, pub(f)))
    } else {
      mergeFallback = true
      flag(prior ? 'the merge agent returned nothing twice — every new finding is a new item of its own (none attached to a prior item; duplicates NOT merged: recall is understated)'
        : 'the merge agent returned nothing twice — every finding is its own item (duplicates NOT merged: recall is understated)')
    }
  }
  if (!groups) groups = flat.map(f => Object.assign({ members: [f.fid] }, pub(f)))
  // Item ids in location order (never merge or reviewer order); provenance from members.
  // An extension numbers its new items after the prior ones and never renumbers those.
  groups.sort((x, y) => (x.file < y.file ? -1 : x.file > y.file ? 1 : 0) || x.line - y.line || hashStr(x.claim) - hashStr(y.claim))
  const firstNew = 1 + priorItems.reduce((m, it) => Math.max(m, Number(it.id.slice(1))), 0)
  const newItems = groups.map((g, i) => ({
    id: `M${firstNew + i}`, file: g.file, line: g.line, severity: g.severity, category: g.category, claim: g.claim, evidence: g.evidence, suggestedFix: g.suggestedFix,
    prov: [...new Set(g.members.map(id => byFid.get(id).rid))].sort(),
  }))
  // A new finding attached to a prior item adds its reviewer to that item's provenance
  // and nothing else: the item's text, verdict and adjudication stay as they were.
  for (const [fid, mid] of attached) {
    const it = priorById.get(mid)
    const rid = byFid.get(fid).rid
    if (!it.prov.includes(rid)) it.prov = it.prov.concat(rid).sort()
  }
  const items = priorItems.concat(newItems)
  const newIds = new Set(newItems.map(it => it.id))
  // Only NEW items are adjudicated in an extension — an attached prior item keeps its verdict.
  const toJudge = prior ? items.filter(it => newIds.has(it.id)) : items

  // ─── (d) Blind adjudication, in batches ──────────────────────────────────────
  // An adjudicator sees an item's location, severity, category, claim, evidence and
  // fix — never who reported it, how many did, or any reviewer id or label.
  const ADJ_SCHEMA = {
    type: 'object',
    properties: {
      verdicts: {
        type: 'array',
        items: { type: 'object', properties: { id: { type: 'string' }, verdict: { type: 'string', enum: VERDICTS }, evidence: { type: 'string' } }, required: ['id', 'verdict', 'evidence'] },
      },
    },
    required: ['verdicts'],
  }
  const blindItem = it => JSON.stringify({ id: it.id, file: it.file, line: it.line, severity: it.severity, category: it.category, claim: it.claim, evidence: it.evidence, suggestedFix: it.suggestedFix })
  const ADJ_TASK = 'You are an independent adjudicator of review findings. For EACH item below, decide against the ground truth whether the claimed defect is real. ' +
    'Verify it yourself in the snapshot: open the file at the line and check the cited ground-truth source (or find the right one) — an item\'s evidence text is a claim to check, never proof.\n' +
    'Verdicts: real = the defect exists as claimed (or substantially so); not-real = the snapshot or the ground truth contradicts it, or nothing supports it; ' +
    'accepted-deviation = it is one of the accepted deviations below and cites no new ground-truth evidence; unsure = you cannot decide from the snapshot.\n' +
    'For every item return {id, verdict, evidence = the ground-truth source you checked (snapshot path and page/line/item) and what it shows}. ' +
    'You do not know who reported these items or how many did; do not guess.\n\n'
  const adjClaudePrompt = batch => `${ADJ_TASK}${RULES}--- Adjudication protocol ---\n` +
    `Your ONLY input is the snapshot directory ${snap} (files at commit ${headSha}, context files, extras under ${snap}/_extra/). ` +
    'Read nothing else: do not read, list or search any other directory on this machine.\n' +
    readOnly(snap) + `\n--- Items (${batch.length}) ---\n${batch.map(blindItem).join('\n')}`
  const adjCodexPrompt = (j, batch) => codexPrompt(j, adjudicatorTimeout, 'adjudicator',
    `Pass exactly this input to ext-run.sh and nothing else: --input-dir ${snap} (from INPUT_DIR)\n` + schemaLine(ADJ_SCHEMA),
    ADJ_TASK + RULES +
    `Your input is staged in your workspace: the snapshot directory "snap" (files at commit ${headSha}, context files, extras under snap/_extra/); paths are relative to it. Read only the staged files; never run git.\n` +
    `--- Items (${batch.length}) ---\n${batch.map(blindItem).join('\n')}\n` +
    'Output ONLY one JSON object {"verdicts": [...]} matching the schema — no other text.')
  const batches = []
  for (let i = 0; i < toJudge.length; i += batchSize) batches.push(toJudge.slice(i, i + batchSize))
  const verdictOf = new Map(toJudge.map(it => [it.id, {}]))
  if (toJudge.length) {
    phase('Adjudicate')
    for (const j of adjudicators) {
      fable('adjudicator', j)
      if (j.vendor !== 'claude' && !codexDenied) log(`⚠ External adjudicator ${j.label}: the snapshot leaves this machine for ${j.vendor}.`)
    }
    async function adjudicate(j, batch, k) {
      if (j.vendor !== 'claude' && codexDenied) return null
      for (let attempt = 1; attempt <= 2; attempt++) {
        const label = `adjudicate:${j.label}@b${k + 1}${attempt === 1 ? '' : '#retry'}`
        let out = null
        try {
          out = await agent(j.vendor === 'claude' ? adjClaudePrompt(batch) : adjCodexPrompt(j, batch),
            j.vendor === 'claude' ? claudeOpts(j, 'Adjudicate', label, ADJ_SCHEMA) : { phase: 'Adjudicate', agentType: 'triage-cross-reviewer', label })
        } catch (e) {
          out = null
        }
        const obj = j.vendor === 'claude' ? out : (producedNothing(out) ? null : parseJsonObject(out))
        if (obj && Array.isArray(obj.verdicts)) return obj.verdicts
      }
      return null
    }
    const jobs = []
    for (const j of adjudicators) batches.forEach((batch, k) => jobs.push({ j, batch, run: () => adjudicate(j, batch, k) }))
    const outs = await parallel(jobs.map(x => x.run))
    jobs.forEach((x, n) => {
      const vs = outs[n]
      if (!Array.isArray(vs)) {
        flag(`adjudicator ${x.j.label} returned no verdicts for ${x.batch.length} item(s) (${x.batch.map(it => it.id).join(', ')}) — those items are disputed`)
        return
      }
      const ids = new Set(x.batch.map(it => it.id))
      for (const v of vs) {
        if (!v || !ids.has(v.id) || !VERDICTS.includes(v.verdict)) continue
        const m = verdictOf.get(v.id)
        if (!m[x.j.label]) m[x.j.label] = { verdict: v.verdict, evidence: String(v.evidence || '').trim() }
      }
    })
  }
  // combine() — SINGLE OWNER of an item's verdict: every adjudicator real => real;
  // every one not-real or accepted-deviation => rejected; unsure, a missing verdict or
  // any disagreement => disputed (left for Alex, never scored).
  function combine(vs) {
    if (vs.some(v => v == null || v === 'unsure')) return 'disputed'
    if (vs.every(v => v === 'real')) return 'real'
    if (vs.every(v => v === 'not-real' || v === 'accepted-deviation')) return 'rejected'
    return 'disputed'
  }
  for (const it of toJudge) {
    const m = verdictOf.get(it.id)
    it.adjudication = adjudicators.map(j => ({ adjudicator: j.label, vendor: j.vendor, verdict: m[j.label] ? m[j.label].verdict : null, evidence: m[j.label] ? m[j.label].evidence : null }))
    it.verdict = combine(it.adjudication.map(x => x.verdict))
  }
  for (const it of items) it.foundBy = it.prov.map(rid => labelOfRid.get(rid)).sort()

  // ─── (e) Scores: only items the adjudicators agree on count ─────────────────
  // Every reviewer that is not superseded — an extension's prior ones included — over
  // the COMBINED items: a new real item lowers the recall of everyone who missed it.
  const isReal = it => it.verdict === 'real'
  const isJudged = it => isReal(it) || it.verdict === 'rejected'
  const allReal = items.filter(isReal).length
  const ratio = (n, d) => (d ? n / d : null)
  const scored = rows.map(x => {
    const row = { label: x.r.label, vendor: x.r.vendor, level: x.r.level, model: x.r.model, effort: x.r.effort, status: x.status }
    const count = x.prior ? x.count : x.findings.length
    if (x.status !== 'ok') {
      return Object.assign(row, { precision: null, recall: null, findings: x.status === 'superseded' ? count : null, real: null, rejected: null, disputed: null, tokens: x.tokens, seconds: x.seconds, reason: x.reason },
        x.status === 'superseded' ? { priorStatus: x.priorStatus } : {})
    }
    const mine = items.filter(it => it.prov.includes(x.rid))
    const real = mine.filter(isReal).length
    return Object.assign(row, {
      precision: ratio(real, mine.filter(isJudged).length), recall: ratio(real, allReal),
      findings: count, real, rejected: mine.filter(it => it.verdict === 'rejected').length, disputed: mine.filter(it => it.verdict === 'disputed').length,
      tokens: x.tokens, seconds: x.seconds,
    })
  })

  // ─── (f) Re-fingerprint the source (informational: the review was pinned) ──
  let sourceChanged = null
  if (fpOk) {
    phase('Fingerprint')
    let fc = null
    try {
      fc = await agent('Run these two commands in order, each exactly as written, the second even if the first fails. Do not run anything else, and do not interpret or fix anything.\n' +
        `${fpCmd(fpAfter)}\n${REVIEW_STAGE} compare ${shq(fpBefore)} ${shq(fpAfter)}\n\n` +
        'Return rc = the exit status of the SECOND command, and same, changed, headMoved and detail from the JSON line it prints.',
        { phase: 'Fingerprint', agentType: 'triage-quick-task', label: 'review:fingerprint', schema: { type: 'object', properties: { rc: { type: ['integer', 'null'] }, same: { type: 'boolean' }, changed: { type: 'array', items: { type: 'string' } }, headMoved: { type: 'boolean' }, detail: { type: 'string' } }, required: ['rc'] } })
    } catch (e) {
      fc = null
    }
    if (fc && (fc.rc === 7 || fc.same === false)) sourceChanged = true
    else if (fc && fc.rc === 0 && fc.same === true) sourceChanged = false
    if (sourceChanged === true) flag(`SOURCE_CHANGED ${a.repoName.trim()}: ${(fc && fc.detail) || 'the reviewed paths changed during the review'} — informational: every reviewer read the pinned snapshot at ${headSha.slice(0, 12)}`)
    else if (sourceChanged == null) flag('the after-review source fingerprint could not be compared — SOURCE_CHANGED unknown')
  }

  // ─── Output ─────────────────────────────────────────────────────────────────
  const outItems = items.map(it => ({
    id: it.id, file: it.file, line: it.line, severity: it.severity, category: it.category, claim: it.claim, evidence: it.evidence, suggestedFix: it.suggestedFix,
    verdict: it.verdict, adjudication: it.adjudication, foundBy: it.foundBy,
  })).sort((x, y) => Number(x.id.slice(1)) - Number(y.id.slice(1)))
  const disputed = outItems.filter(it => it.verdict === 'disputed').map(it => it.id)
  const superseded = scored.filter(x => x.status === 'superseded').map(x => x.label)
  const unavailable = scored.filter(x => x.status === 'unavailable').length
  const allFlags = (prior ? (prior.flags || []).map(f => `prior run: ${f}`) : []).concat(flags)
  const f3 = v => (v == null ? '—' : String(Math.round(v * 1000) / 1000))
  const md = [`# Review bake-off — ${a.repoName.trim()} ${baseSha.slice(0, 12)}..${headSha.slice(0, 12)}`, '',
    `Snapshot: ${sn.files == null ? '?' : sn.files} file(s)${sn.extras ? ` + ${sn.extras} extra(s)` : ''}, range diff ${sn.diffBytes == null ? '?' : sn.diffBytes} bytes. Reviewers: ${scored.length} (${unavailable} unavailable${superseded.length ? `, ${superseded.length} superseded` : ''}). ` +
    `Items: ${outItems.length} merged — ${outItems.filter(isReal).length} real, ${outItems.filter(it => it.verdict === 'rejected').length} rejected, ${disputed.length} disputed.`]
  if (prior) {
    md.push('', `Extended with ${reviewers.map(r => r.label).join(', ')} (prior result: ${prior.items.length} item(s) by ${prior.reviewers.map(r => r.label).join(', ')}): ${flat.length} new finding(s) — ${attached.size} attached to prior items (not re-adjudicated), ` +
      `${newItems.length} new item(s)${newItems.length ? ` (${newItems.map(it => it.id).join(', ')})` : ''}. Superseded: ${superseded.length ? superseded.join(', ') : 'none'}.`)
  }
  if (allFlags.length) md.push('', ...allFlags.map(f => `- ⚠ ${f}`))
  const real = outItems.filter(isReal)
  md.push('', `## Real findings (${real.length})`)
  const files = [...new Set(real.map(it => it.file))]
  for (const f of files) {
    md.push('', `### ${f}`)
    for (const it of real.filter(x => x.file === f)) {
      md.push(`- **L${it.line}** · ${it.severity}${it.category ? ` · ${it.category}` : ''} — ${it.claim}`, `  - Evidence: ${it.evidence}`)
      if (it.suggestedFix) md.push(`  - Fix: ${it.suggestedFix}`)
      md.push(`  - Found by: ${it.foundBy.join(', ')}`)
    }
  }
  const disp = outItems.filter(it => it.verdict === 'disputed')
  md.push('', `## Disputed — for Alex (${disp.length})`)
  for (const it of disp) {
    md.push('', `### ${it.id} ${it.file}:${it.line} · ${it.severity}${it.category ? ` · ${it.category}` : ''}`, it.claim, `- Reviewer evidence: ${it.evidence}`)
    for (const x of it.adjudication) md.push(`- ${x.adjudicator}: **${x.verdict || 'no verdict'}** — ${x.evidence || '(none)'}`)
    md.push(`- Found by: ${it.foundBy.join(', ')}`)
  }
  const rej = outItems.filter(it => it.verdict === 'rejected')
  if (rej.length) md.push('', `## Rejected (${rej.length})`, ...rej.map(it => `- ${it.id} ${it.file}:${it.line} — ${it.claim}`))
  md.push('', '## Scores (non-disputed items only)', '',
    '| Reviewer | Vendor | Model | Effort | Status | Findings | Real | Rejected | Disputed | Precision | Recall | Tokens | s |',
    '|---|---|---|---|---|---|---|---|---|---|---|---|---|',
    ...scored.map(x => `| ${x.label} | ${x.vendor} | ${x.model || 'default'} | ${x.effort || 'default'} | ${x.status} | ${x.findings == null ? '—' : x.findings} | ${x.real == null ? '—' : x.real} | ${x.rejected == null ? '—' : x.rejected} | ${x.disputed == null ? '—' : x.disputed} | ${f3(x.precision)} | ${f3(x.recall)} | ${x.tokens == null ? '—' : x.tokens} | ${x.seconds == null ? '—' : x.seconds} |`),
    '', 'Nothing was applied. Ingest the scores (after resolving the disputed ids) with scripts/parity-report.sh ingest-review.')
  log(`Review bake-off at ${headSha.slice(0, 12)}: ${outItems.length} item(s) — ${real.length} real, ${rej.length} rejected, ${disp.length} disputed; ${unavailable} reviewer(s) unavailable` +
    (prior ? `; extended the prior result with ${newItems.length} new item(s), ${superseded.length} superseded.` : '.'))
  return Object.assign({
    kind: 'review', repoName: a.repoName.trim(), base: baseSha, head: headSha, outDir,
    reviewers: scored, items: outItems, disputed, sourceChanged, mergeFallback: mergeFallback || !!(prior && prior.mergeFallback), flags: allFlags, markdown: md.join('\n'),
  }, prior ? { extendedFrom: { base: prior.base, head: prior.head, outDir, reviewers: prior.reviewers.map(r => r.label), items: prior.items.length }, newItems: newItems.map(it => it.id), superseded } : {})
}
