export const meta = {
  name: 'triage-exec',
  description: 'Execute a pre-built triage plan: delegate each subtask to its level agent (Claude, or an external vendor), run the objective checks, remediate and escalate',
  whenToUse: 'Run a plan the orchestrator has ALREADY classified (it never classifies; a malformed plan throws before any spawn): args = {repo?, subtasks:[{brief, level, vendor?, files, acceptance, danger?, effort?, checks?}], checks:[cmd...], review?, crossReview?, overflow?, vendor?, bakeoff?, noFable?}. noFable: true (rubric rule 7 material) refuses claude top subtasks and stops at deep@max with report.needsUser instead of escalating to Fable. Inline build bake-offs are on by default: pass bakeoff on every plan unless triage.md rule 10 excludes the work, then run each report.ingest entry. Full arg spec: README.md › Workflow arguments › triage-exec.',
  phases: [
    { title: 'Execute' },
    { title: 'Verify' },
  ],
}

// ─── Entry contract ─────────────────────────────────────────────────────────
// Classification lives in the ORCHESTRATOR now, not here: it is the best classifier
// available and already holds the task context, so spending a spawn to re-derive a
// plan was pure waste. What arrives is a finished plan, validated in plain JS BEFORE
// any agent() call — a malformed plan is a caller bug and must fail loudly and for
// free, never half-execute and bill for it.
//
// Two axes (Wave 12): LEVEL describes the task (quick|builder|deep|top, never a model)
// and VENDOR says who serves it (claude|codex). Which models serve a level is data
// in config/tiers.json (ext-run.sh reads it for the external vendors); the routing
// POLICY — defaults, danger floors, fallbacks — lives here.
const LEVELS = ['quick', 'builder', 'deep', 'top']
// Legacy tier names that are really a level + a vendor. `fable` was the top level's
// Claude slot; `overflow` is builder work moved onto codex (on agy until its
// retirement, 2026-09-24).
const LEVEL_ALIASES = { fable: { level: 'top', vendor: 'claude' }, overflow: { level: 'builder', vendor: 'codex' } }
const LEVEL_NAMES = [...LEVELS, ...Object.keys(LEVEL_ALIASES)]
const VENDORS = ['claude', 'codex']
// Vendors that once existed and are now refused by name, with the reason. agy's
// headless mode let the model set a per-command BypassSandbox flag, and a
// read-only review run used it to write into a real repo.
const RETIRED_VENDORS = { agy: 'agy was retired 2026-09-24 (it bypassed its own sandbox and wrote into a real repo) — use codex or claude' }
const isRetired = v => typeof v === 'string' && Object.prototype.hasOwnProperty.call(RETIRED_VENDORS, v)
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
const REVIEW_MODES = ['auto', 'always', 'never']
// crossReview → the external reviewers spawned: `true` or 'codex' = codex (agy until
// its retirement); false/absent = none. 'agy' and 'both' are refused by name.
const CROSS_REVIEW_VENDORS = { codex: ['codex'] }
const RETIRED_CROSS_REVIEW = ['agy', 'both']
// The Claude agent serving each level. test/lint.sh checks this map against
// config/tiers.json levels.*.claude.agent. `top` is listed for that check only: its
// one spawn path is runFable().
const CLAUDE_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', top: 'triage-fable-architect' }

const USAGE = 'Expected args = {\n' +
  `  subtasks: [{ id?, brief, level: ${LEVELS.join('|')} (alias tier; ${Object.keys(LEVEL_ALIASES).join('|')} also accepted), vendor?: ${VENDORS.join('|')},\n` +
  `               files?: string[], acceptance, danger?: bool, effort?: ${EFFORTS.join('|')},\n` +
  '               checks?: string[] }]  // at least one; checks = this subtask\'s own checks (an inline bake-off\'s grade)\n' +
  '  checks?:      string[]   // shell commands run as objective gates\n' +
  '  repo?:        "/abs repo" // the plan\'s tree: checks, reviewer, cross-review, briefs and WORKDIR use it (default: the session cwd)\n' +
  `  vendor?:      ${VENDORS.join('|')}   // default vendor for subtasks that omit one (default: claude)\n` +
  '  overflow?:    boolean    // default: false — builder-level subtasks without a vendor run on codex\n' +
  `  review?:      ${REVIEW_MODES.join('|')}   // default: auto\n` +
  `  crossReview?: boolean|${Object.keys(CROSS_REVIEW_VENDORS).join('|')}   // default: false (true = codex)\n` +
  '  noFable?:     boolean    // default: false — never spawn Fable: no claude top subtask; stop at deep@max (report.needsUser)\n' +
  '  bakeoff?:     { config: <triage-tiers.sh --bakeoff-json object>, seed: string, repo?: "/abs repo" (default args.repo; must equal it),\n' +
  '                  outDir: "/abs dir outside repo", weeklyPct?: number,\n' +
  `                  rates?: { ${LEVELS.join('|')}: number in [0, 1] } }   // opt-in inline bake-offs; rates = parity-report.sh rates --json .rates\n}`

function bad(msg) {
  throw new Error(`triage-exec: ${msg}\n${USAGE}`)
}

const isStr = v => typeof v === 'string' && v.trim().length > 0
const typeName = v => (v === null ? 'null' : Array.isArray(v) ? 'an array' : typeof v)
const atLeast = (level, floor) => (LEVELS.indexOf(level) >= LEVELS.indexOf(floor) ? level : floor)
// tierName() — the rung label used in labels, logs, escalations and the report: the
// pre-Wave-12 tier name on Claude (top on Claude IS Fable), `<vendor>:<level>` off it.
const tierName = (level, vendor) => (vendor === 'claude' ? (level === 'top' ? 'fable' : level) : `${vendor}:${level}`)

if (!args || typeof args !== 'object' || Array.isArray(args)) bad(`args must be a plan object (got ${typeName(args)}).`)
if (!Array.isArray(args.subtasks) || args.subtasks.length === 0) bad('args.subtasks must be a non-empty array.')
if (args.checks != null && !(Array.isArray(args.checks) && args.checks.every(isStr))) bad('args.checks must be an array of non-empty shell-command strings.')
if (args.review != null && !REVIEW_MODES.includes(args.review)) bad(`args.review must be one of ${REVIEW_MODES.join('|')} (got ${JSON.stringify(args.review)}).`)
if (RETIRED_CROSS_REVIEW.includes(args.crossReview)) bad(`args.crossReview ${JSON.stringify(args.crossReview)} is no longer accepted: ${RETIRED_VENDORS.agy}; crossReview true means codex.`)
if (args.crossReview != null && typeof args.crossReview !== 'boolean' && !Object.keys(CROSS_REVIEW_VENDORS).includes(args.crossReview)) {
  bad(`args.crossReview must be a boolean or one of ${Object.keys(CROSS_REVIEW_VENDORS).join('|')} (got ${JSON.stringify(args.crossReview)}).`)
}
if (args.overflow != null && typeof args.overflow !== 'boolean') bad('args.overflow must be a boolean.')
if (args.noFable != null && typeof args.noFable !== 'boolean') bad(`args.noFable must be a boolean (got ${JSON.stringify(args.noFable)}).`)
if (isRetired(args.vendor)) bad(`args.vendor ${JSON.stringify(args.vendor)}: ${RETIRED_VENDORS[args.vendor]}.`)
if (args.vendor != null && !VENDORS.includes(args.vendor)) bad(`args.vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(args.vendor)}).`)
const wantsOverflow = args.overflow === true
// noFable — the plan's material is excluded from Fable (rubric rule 7(a)/(b)). Deep@max
// is then the ceiling: redoStep() never steps onto top and runFable() never spawns Fable.
const noFable = args.noFable === true
const planVendor = args.vendor || null

// args.bakeoff — opt-in inline build bake-offs (Wave 13B; see bakeoffPick() and
// runBakeoff()). Absent → none of that code runs and the return has no bake-off
// fields. config is `triage-tiers.sh --bakeoff-json` verbatim (that script owns the
// full tuning schema; a workflow has no fs), so only the fields read here are checked.
// Paths go into shell commands: absolute, no whitespace or quotes; outDir outside repo
// (each subtask's compare stages worktrees and patches under it).
const isAbsPath = v => isStr(v) && v.startsWith('/') && !/[\s'"`$\\]/.test(v)
const stripSlash = v => String(v).trim().replace(/\/+$/, '')
const isNum = v => typeof v === 'number' && Number.isFinite(v)
const isObj = v => !!v && typeof v === 'object' && !Array.isArray(v)
// args.repo — the plan's repository (absolute). Set: every objective check runs as
// `cd <repo> && …`, the reviewer and the cross-review read it with `git -C <repo>`,
// every worker brief opens with a `Repository:` line, external workers get
// WORKDIR=<repo>, and args.bakeoff.repo defaults to it. Unset: everything runs in the
// session's working directory, as before. Without it a plan aimed at a linked worktree
// while the session sits in the main tree edits one tree and checks another.
if (args.repo != null && !isAbsPath(args.repo)) bad(`args.repo must be an absolute path with no whitespace or quotes (got ${JSON.stringify(args.repo)}).`)
const planRepo = args.repo != null ? stripSlash(args.repo) : null
const bakeoffOn = args.bakeoff != null
if (bakeoffOn) {
  const b = args.bakeoff
  if (!isObj(b)) bad(`args.bakeoff must be an object (got ${typeName(b)}).`)
  const cfg = b.config
  if (!isObj(cfg) || !isObj(cfg.levels) || !isObj(cfg.tuning)) bad('args.bakeoff.config must be the object `triage-tiers.sh --bakeoff-json` prints ({asOf, levels, tuning}).')
  const t = cfg.tuning
  if (!(isNum(t.sampleRate) && t.sampleRate > 0 && t.sampleRate <= 1)) bad('args.bakeoff.config.tuning.sampleRate must be a number in (0, 1].')
  if (!isObj(t.challengerMix) || !Object.entries(t.challengerMix).every(([v, s]) => VENDORS.includes(v) && isNum(s) && s >= 0 && s <= 1)) {
    bad(`args.bakeoff.config.tuning.challengerMix must be {vendor: share in [0, 1]} over ${VENDORS.join('|')}.`)
  }
  if (!isObj(t.challengers) || !Object.entries(t.challengers).every(([l, byV]) => LEVELS.includes(l) && isObj(byV) &&
      Object.entries(byV).every(([v, list]) => VENDORS.includes(v) && Array.isArray(list) &&
        list.every(c => isObj(c) && isStr(c.model) && /^[A-Za-z0-9._+-]+$/.test(c.model) && EFFORTS.includes(c.effort))))) {
    bad('args.bakeoff.config.tuning.challengers must be {level: {vendor: [{model, effort}]}}.')
  }
  if (!isNum(t.pauseAtWeeklyPct)) bad('args.bakeoff.config.tuning.pauseAtWeeklyPct must be a number.')
  if (!isStr(b.seed)) bad('args.bakeoff.seed must be a non-empty string (the orchestrator picks it; sampling is a pure function of it).')
  if (b.repo == null ? !planRepo : !isAbsPath(b.repo)) bad('args.bakeoff.repo must be an absolute path with no whitespace or quotes (it may be left out when args.repo is set: it defaults to that).')
  if (b.repo != null && planRepo && stripSlash(b.repo) !== planRepo) bad(`args.repo (${planRepo}) and args.bakeoff.repo (${stripSlash(b.repo)}) name different trees — the bake-off patch would land in one and the checks run in the other; give one, or the same path in both.`)
  if (!isAbsPath(b.outDir)) bad('args.bakeoff.outDir must be an absolute path with no whitespace or quotes.')
  const repoC = b.repo != null ? stripSlash(b.repo) : planRepo
  const outC = stripSlash(b.outDir)
  if (outC === repoC || outC.startsWith(`${repoC}/`) || repoC.startsWith(`${outC}/`)) bad('args.bakeoff.outDir must be outside args.bakeoff.repo (and must not contain it) — the staged worktrees and patches would dirty the real tree.')
  if (b.weeklyPct != null && !isNum(b.weeklyPct)) bad(`args.bakeoff.weeklyPct must be a number when given (got ${JSON.stringify(b.weeklyPct)}).`)
  // rates — the per-level sampling rate parity-report.sh decides (explore/maintain/none).
  if (b.rates != null && (!isObj(b.rates) || !Object.entries(b.rates).every(([l, r]) => LEVELS.includes(l) && isNum(r) && r >= 0 && r <= 1))) {
    bad(`args.bakeoff.rates must be {level: number in [0, 1]} over ${LEVELS.join('|')} (parity-report.sh rates --json .rates; got ${JSON.stringify(b.rates)}).`)
  }
}

// DANGER_FAMILIES — the danger floor by MODEL FAMILY (Alex, 2026-09-25): danger work
// is served only by Claude opus|fable or codex astra (codex also at effort >= high,
// codexDangerEffort()). A family is a whole token of the model id, split on - . _ :
// + @ (claude-opus-5-5 is "opus", gpt-6-astra is "astra") — the same notion as
// scripts/parity-report.sh's family order. Policy, so it lives here; test/lint.sh
// checks that config/tiers.json levels.deep and levels.top name a floor family for
// every vendor, so planned danger routing (always lifted to >= deep) complies.
const DANGER_FAMILIES = { claude: ['opus', 'fable'], codex: ['astra'] }
// OWNER of the model family-token split: parity-report.sh id_tokens and lint 6c/6d check against it.
const modelTokens = m => String(m || '').toLowerCase().split(/[-._:+@]/).filter(Boolean)
const meetsDangerFloor = (vendor, model) => {
  const t = modelTokens(model)
  return (DANGER_FAMILIES[vendor] || []).some(f => t.includes(f))
}

// codexDangerEffort() — the danger floor for codex: effort at least `high`. An unset
// effort would otherwise fall to the tiers.json default, which is data and may drop;
// the floor is policy, so it is written into the header explicitly. At `top` an unset
// effort becomes xhigh rather than high, so the floor never LOWERS the level's default.
function codexDangerEffort(level, effort) {
  if (!effort) return level === 'top' ? 'xhigh' : 'high'
  return EFFORTS.indexOf(effort) >= EFFORTS.indexOf('high') ? effort : 'high'
}

// isFableModel() — a model of Fable's family. Fable's one spawn path is runFable()
// (announced, noFable-aware), so a Fable-family model is never a bake-off candidate,
// planned or challenger, at ANY level (a tiers entry could put one below top).
const FABLE_FAMILY = 'fable'
const isFableModel = m => modelTokens(m).includes(FABLE_FAMILY)

// normFile(f, i) — ONE spelling for every subtask file: repo-relative, no ./ or empty
// components, no trailing slash; an absolute path under the plan's repo (args.repo,
// else args.bakeoff.repo) is made relative. Briefs, reviewer focus, attribution, the
// bake-off dirty check and triage-compare's scope check all read this spelling. With a
// bake-off on, a path that cannot be made repo-relative (absolute elsewhere, a ..
// component, the repo itself) is refused: every candidate would read as out of scope
// and no bake-off patch could ever land.
const fileRepo = planRepo || (bakeoffOn ? stripSlash(args.bakeoff.repo) : null)
function normFile(f, i) {
  let s = f.trim().replace(/\/{2,}/g, '/')
  if (fileRepo && s.startsWith(`${fileRepo}/`)) s = s.slice(fileRepo.length + 1)
  if (!s.startsWith('/')) s = s.split('/').filter(x => x !== '' && x !== '.').join('/')
  if (bakeoffOn && (s === '' || s.startsWith('/') || s.split('/').includes('..'))) {
    bad(`subtasks[${i}].files: ${JSON.stringify(f)} is not a path inside ${fileRepo} — with args.bakeoff, files must be repo-relative (an absolute path under the repo is accepted).`)
  }
  return s || f.trim()
}

const seenIds = new Set()
const subtasks = args.subtasks.map((raw, i) => {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`subtasks[${i}] must be an object (got ${typeName(raw)}).`)
  if (!isStr(raw.brief)) bad(`subtasks[${i}].brief must be a non-empty string.`)
  // level, with `tier` as its alias. Each is resolved through LEVEL_ALIASES; when both
  // are given they must name the same level (and the same vendor, if either implies one).
  const resolveLevel = field => {
    const v = raw[field]
    if (!LEVEL_NAMES.includes(v)) bad(`subtasks[${i}].${field} must be one of ${LEVELS.join('|')} (aliases: ${Object.keys(LEVEL_ALIASES).join('|')}) (got ${JSON.stringify(v)}).`)
    return LEVEL_ALIASES[v] || { level: v, vendor: null }
  }
  if (raw.level == null && raw.tier == null) bad(`subtasks[${i}].level (or its alias tier) must be one of ${LEVELS.join('|')} (got none).`)
  const byLevel = raw.level != null ? resolveLevel('level') : null
  const byTier = raw.tier != null ? resolveLevel('tier') : null
  if (byLevel && byTier && (byLevel.level !== byTier.level || (byLevel.vendor && byTier.vendor && byLevel.vendor !== byTier.vendor))) {
    bad(`subtasks[${i}]: level ${JSON.stringify(raw.level)} and tier ${JSON.stringify(raw.tier)} disagree — give one, or the same level in both.`)
  }
  const plannedLevel = (byLevel || byTier).level
  const aliasVendor = (byLevel && byLevel.vendor) || (byTier && byTier.vendor) || null
  if (!isStr(raw.acceptance)) bad(`subtasks[${i}].acceptance must be a non-empty string — verification has nothing to check against without it.`)
  if (raw.files != null && !(Array.isArray(raw.files) && raw.files.every(isStr))) bad(`subtasks[${i}].files must be an array of path strings.`)
  if (raw.checks != null && !(Array.isArray(raw.checks) && raw.checks.every(isStr))) bad(`subtasks[${i}].checks must be an array of non-empty shell-command strings.`)
  if (raw.danger != null && typeof raw.danger !== 'boolean') bad(`subtasks[${i}].danger must be a boolean.`)
  if (raw.effort != null && !EFFORTS.includes(raw.effort)) bad(`subtasks[${i}].effort must be one of ${EFFORTS.join('|')} (got ${JSON.stringify(raw.effort)}).`)
  if (isRetired(raw.vendor)) bad(`subtasks[${i}].vendor ${JSON.stringify(raw.vendor)}: ${RETIRED_VENDORS[raw.vendor]}.`)
  if (raw.vendor != null && !VENDORS.includes(raw.vendor)) bad(`subtasks[${i}].vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(raw.vendor)}).`)
  if (raw.vendor != null && aliasVendor && raw.vendor !== aliasVendor) bad(`subtasks[${i}]: ${byLevel && byLevel.vendor ? `level ${JSON.stringify(raw.level)}` : `tier ${JSON.stringify(raw.tier)}`} implies vendor ${aliasVendor}, but vendor is ${JSON.stringify(raw.vendor)}.`)
  if (raw.id != null && !isStr(raw.id)) bad(`subtasks[${i}].id must be a non-empty string when given.`)
  // Ids are the handle everything downstream uses (logs, skip records, remediation
  // attribution, the returned report), so they are assigned here when absent and
  // must be unique — a duplicate would silently merge two subtasks in the report.
  const id = raw.id ? raw.id.trim() : `s${i + 1}`
  if (seenIds.has(id)) bad(`duplicate subtask id "${id}" — ids must be unique.`)
  seenIds.add(id)
  const danger = raw.danger === true
  // Vendor precedence, most specific first: the subtask's own vendor, the vendor its
  // alias implies, plan-level overflow (builder-level work only — quick work is too cheap
  // to be worth the external round-trip, and deep/top was never overflow's remit), the
  // plan-level vendor default, then Claude.
  const overflowVendor = wantsOverflow && plannedLevel === 'builder' ? LEVEL_ALIASES.overflow.vendor : null
  const plannedVendor = raw.vendor || aliasVendor || overflowVendor || planVendor || 'claude'
  // viaOverflow — this subtask is external because of OVERFLOW (the alias, or the plan
  // flag deciding its vendor): a throughput choice for work that was never hard, not a
  // parity-based routing decision.
  const viaOverflow = raw.level === 'overflow' || raw.tier === 'overflow' || (!raw.vendor && !aliasVendor && overflowVendor !== null)
  const plannedEffort = raw.effort || null
  // Danger-zone routing, ENFORCED here rather than trusted to the caller. The plan is
  // well-formed, only mis-routed — so upgrade loudly instead of throwing:
  //   overflow → Claude deep. Correctness-critical work never goes off-vendor for
  //              throughput, exactly as overflow+danger always did (on agy, then codex).
  //   codex    → allowed (parity is data in tiers.json), but lifted to at least deep and
  //              to at least effort high (codexDangerEffort()).
  //   claude   → quick/builder lifted to deep.
  let level = plannedLevel
  let vendor = plannedVendor
  let effort = plannedEffort
  if (danger) {
    if (viaOverflow) { vendor = 'claude'; level = 'deep' }
    else if (vendor === 'codex') { level = atLeast(level, 'deep'); effort = codexDangerEffort(level, effort) }
    else level = atLeast(level, 'deep')
  }
  return {
    id,
    brief: raw.brief.trim(),
    level,
    vendor,
    plannedLevel,
    plannedVendor,
    plannedEffort,
    files: raw.files ? raw.files.map(f => normFile(f, i)) : [],
    acceptance: raw.acceptance.trim(),
    danger,
    effort,
    checks: raw.checks ? raw.checks.map(c => c.trim()) : [],
  }
})

// noFable + a plan-time top-level Claude subtask (= Fable itself) is a contradiction:
// refused before any spawn. A codex top subtask is fine — codex is not Fable.
if (noFable) {
  const fableSt = subtasks.find(st => st.level === 'top' && st.vendor === 'claude')
  if (fableSt) bad(`subtask "${fableSt.id}" is level top on claude (= Fable), but args.noFable is true — plan it at deep (deep@max is the ceiling) or on codex, or drop noFable.`)
}

const checks = (args.checks || []).map(c => c.trim())
const reviewMode = args.review || 'auto'
const crossVendors = args.crossReview === true ? CROSS_REVIEW_VENDORS.codex : (CROSS_REVIEW_VENDORS[args.crossReview] || [])
const isExternal = v => v !== 'claude'

for (const st of subtasks) {
  const planned = `${tierName(st.plannedLevel, st.plannedVendor)}${st.plannedEffort ? `@${st.plannedEffort}` : ''}`
  const now = `${tierName(st.level, st.vendor)}${st.effort ? `@${st.effort}` : ''}`
  if (planned !== now) {
    log(`⚠ Danger-zone routing: "${st.id}" was planned as ${planned} but danger=true — running it on ${now} instead (correctness-critical work never runs below deep, never below effort high off-vendor, and never via overflow).`)
  }
  if (isExternal(st.vendor)) {
    log(`⚠ External routing: "${st.id}" runs on ${st.vendor} at level ${st.level}${st.effort ? ` (effort ${st.effort})` : ''} instead of Claude — its workspace leaves this machine.`)
  }
}

// escalations — every rung change this run made, for the returned report. Kinds: a
// verdict-driven remediation step (same rung on FIX, one up on ESCALATE, deep→deep@max→
// fable: see redoStep()), the Fable→deep@max availability fallback or, when deep@max
// already failed, its recorded skip (to:'none', see runFable()), and an external
// subtask coming back to Claude: from '<vendor>:<level>' to the same level's Claude
// rung, either because the external CLI never produced work (runOn()) or because its
// work failed verification (redoStep()).
const escalations = []
// Ids whose external spawn produced no work (classifyBuild(): no work) and so ran
// on Claude instead — the one fact report()'s ranExternally cannot derive from the
// escalation log, since a verification failure records the same from/to pair.
const neverRanExternally = new Set()
// Ids stopped under noFable where the ladder would have gone to Fable (stopForUser()).
const needsUser = new Set()
const NO_FABLE_REASON = 'noFable: Fable excluded for this plan — needs the user'

// ─── Budget awareness ───────────────────────────────────────────────────────
// The DSL exposes `budget = {total, spent(), remaining()}`. total === null means
// the user set NO token target: remaining() is Infinity and behavior must be
// EXACTLY the unbudgeted control flow. Every budget branch below is guarded on
// `budgeted`, so the null path never calls remaining(), never skips, never wraps a
// spawn in a catch — it is byte-for-byte the pre-budget workflow.
const budgeted = !!(budget && budget.total != null)
const skipped = []   // {stage, desc} for every spawn we refuse OR that hit the ceiling

// RESERVE — the ONE tuned budget constant: a floor of tokens held back from WORK
// spawns (Execute subtasks + remediation redos). Once remaining() is at/below it we
// stop STARTING new work, so this much budget stays available to VERIFY the work
// already done. Ordering choice (rubric: an unverified result is worse than a
// smaller verified one): we skip WORK before VERIFICATION, so verify gates are NOT
// held to this floor — they may draw the reserve down to the last token (see
// runGate, floor 0). Sized to cover one seam verification of the completed work: an
// objective-check gate (Haiku, ~12k in the usage tally) plus a reviewer gate (Opus,
// ~40k) ≈ 52k; 60k adds headroom. Deeper stages (remediation re-verify) draw further
// down and are themselves budget-gated and ceiling-guarded, not silently unbounded.
const RESERVE = 60_000

// spawn() — SINGLE OWNER of "may I start this WORK agent under the budget?". Two
// budget failure modes, kept DISTINCT from the existing null-resolve (spawn/run
// failure) handling that callers already do:
//   1. pre-spawn refusal — remaining() at/below `need`: record a skip, do NOT call
//      agent(). (fail-loud: logged with what was skipped + remaining budget.)
//   2. hard ceiling — agent() THROWS mid-flight (spent reached total, the DSL's
//      documented throw for a budgeted spawn): catch it, record a skip, return null.
//      Never an unhandled crash that would lose the partial results already gathered.
// `need` = RESERVE for work. When NOT budgeted this is a transparent `await thunk()`
// — no check, no catch — so ordinary throw propagation is preserved and behavior is
// unchanged.
async function spawn(need, stage, desc, thunk) {
  if (!budgeted) return await thunk()
  const left = budget.remaining()
  if (left <= need) {
    log(`⚠ Budget: skipping ${stage} "${desc}" — ${left} tokens remaining, at/below the ${need}-token work reserve.`)
    skipped.push({ stage, desc })
    return null
  }
  try {
    return await thunk()
  } catch (e) {
    log(`⚠ Budget: ${stage} "${desc}" hit the token ceiling (${String((e && e.message) || e)}); ~${left} remaining at pre-check — recorded as skipped, partial results kept.`)
    skipped.push({ stage, desc })
    return null
  }
}

// budgetReport() — the `budget` field added to the return value. spent is stamped
// at return time. NOTE (observed live 2026-07-01): even with total:null the real
// runtime's spent() reports actual session-wide spend (e.g. 649,955), not 0 —
// only the mock returns 0. skipped is always [] when not budgeted.
function budgetReport() {
  return { total: budget ? budget.total : null, spent: budget ? budget.spent() : 0, skipped }
}

phase('Execute')

// With args.repo every brief opens with the tree it is about (a Claude worker's cwd is
// the session's, which may be another worktree).
const repoHeader = planRepo ? `Repository: ${planRepo} (work in this tree; paths below are relative to it)\n\n` : ''
function brief(st, extra) {
  return `${repoHeader}${st.brief}\n\nRelevant files: ${st.files.join(', ') || '(discover)'}\n` +
    `Acceptance criteria: ${st.acceptance}` + (extra ? `\n\n${extra}` : '')
}

// agent() options for a subtask spawn. agentType is ALWAYS set — never rely on an
// inherited model, or the worker silently runs on the orchestrator's (expensive) tier
// instead of the planned one. `effort` is passed through only when the plan set one,
// so an unset effort keeps the agent definition's own default. `effort` overrides the
// plan's value for a step that must run at a specific effort (the deep@max rung).
function agentOpts(st, agentType, ph, label, effort = st.effort) {
  const o = { phase: ph, agentType, label }
  if (effort) o.effort = effort
  return o
}

// runFable() — SINGLE OWNER of every triage-fable-architect spawn: a plan-time top-level
// Claude subtask (Execute), an external top-level subtask coming back to Claude, and any
// remediation step that lands on top, at that step's effort (`effort`; an escalation
// onto top passes none, so the Fable agent keeps its own default). Rubric rule 6: announce
// it first; if the spawn hard-fails (agent() → null — e.g. a stale model registry), fall
// back to triage-deep-reasoner at max effort. EXCEPT when the attempt being escalated
// already WAS deep@max (`afterMax`): the fallback would re-run exactly the attempt that
// just failed. The subtask keeps its last output instead, and the skip is logged and
// recorded (to:'none') so the report never reads as if Fable ran. `prefix` namespaces the
// labels ('' in Execute, 'redo:' in remediation). Returns {output, level, vendor, effort} or null.
//
// noFable (defence in depth — redoStep() never steps onto top under it): Fable is never
// spawned. An external top subtask coming back to Claude gets deep@max instead; after a
// failed deep@max attempt (`afterMax`) the subtask stops for the user (stopForUser()).
async function runFable(st, prompt, ph, prefix, afterMax, effort) {
  if (noFable) {
    if (afterMax) return stopForUser(st.id)
    log(`⚠ noFable: ${st.id} — Fable is excluded for this plan; triage-deep-reasoner at max effort instead.`)
    escalations.push({ id: st.id, from: 'fable', to: 'deep', reason: 'noFable: Fable excluded for this plan — deep-reasoner at max effort instead (Fable never spawned)' })
    const mx = await agent(prompt, agentOpts(st, CLAUDE_AGENT.deep, ph, `${prefix}deep@max:${st.id}`, 'max'))
    // No output from deep@max: the ladder this plan allows is spent — the user, not a bare null.
    return mx ? { output: mx, level: 'deep', vendor: 'claude', effort: 'max' } : stopForUser(st.id, 'returned no output at deep@max')
  }
  log(`⚠ Escalating to Fable: ${st.id} — ${st.brief.slice(0, 80)}`)
  const out = await agent(prompt, agentOpts(st, CLAUDE_AGENT.top, ph, `${prefix}fable:${st.id}`, effort))
  if (out) return { output: out, level: 'top', vendor: 'claude', effort: effort || null }
  if (afterMax) {
    log(`⚠ Fable unavailable — ${st.id} already failed at deep@max, so the deep@max fallback is NOT re-run; it keeps its last output.`)
    escalations.push({ id: st.id, from: 'fable', to: 'none', reason: 'fable spawn unavailable — deep@max fallback skipped: that attempt already ran and failed' })
    return null
  }
  log(`⚠ Fable unavailable — using triage-deep-reasoner at max effort: ${st.id}`)
  escalations.push({ id: st.id, from: 'fable', to: 'deep', reason: 'fable spawn unavailable — deep-reasoner at max effort' })
  const fb = await agent(prompt, agentOpts(st, CLAUDE_AGENT.deep, ph, `${prefix}deep←fable:${st.id}`, 'max'))
  return fb ? { output: fb, level: 'deep', vendor: 'claude', effort: 'max' } : null
}

// stopForUser(id) — noFable's end of the ladder: the subtask failed at deep@max and the
// next rung is Fable, which this plan excludes. Nothing is spawned; it keeps its last
// output, the stop is recorded (deep → user) and report() lists it in needsUser (and the
// run reads INCOMPLETE). `why` names the deep@max outcome for the log. Returns null.
function stopForUser(id, why = 'failed at deep@max') {
  log(`⚠ noFable: ${id} ${why} and Fable is excluded for this plan — stopping; it needs the user.`)
  escalations.push({ id, from: 'deep', to: 'user', reason: NO_FABLE_REASON })
  needsUser.add(id)
  return null
}

// The data-boundary attestation: ONE sentence, used by every brief this workflow sends
// an external-vendor agent (runOn()'s triage-external path and the crossReview brief).
// Both wrappers refuse a brief without it. Choosing vendor codex (or crossReview) in the
// plan IS the orchestrator's boundary decision; the wrappers' own refusals (PHI, a repo
// that forbids external agents, an excluded repo) and ext-run.sh's deny-list still apply.
const BOUNDARY_ATTESTATION = 'The data boundary has been cleared by the orchestrator for this repository.'

// classifyExternal(out) — SINGLE owner of reading a triage-external reply. The FIRST
// line anywhere in the reply that starts (after leading whitespace) with one of the
// wrapper's verdict tokens decides; the Haiku wrapper may write a preamble before it,
// and a token on a LATER line is relayed worker output, never a verdict:
//   `EXTERNAL (`   → {work: true,  kind: 'work'}
//   `REFUSED:`     → {work: false, kind: 'refused',     reason}
//   `UNAVAILABLE:` → {work: false, kind: 'unavailable', reason}
//   no such line (preamble only, garbage, empty) → {work: false, kind: 'malformed'}
//   null (the spawn returned nothing)            → {work: false, kind: 'no-reply'}
// No work = nothing to verify: runOn() takes the same-level Claude fallback. This is
// availability, not a verification verdict — those stay in assess().
const EXTERNAL_REASON_MAX = 160
function classifyExternal(out) {
  const cut = s => s.trim().slice(0, EXTERNAL_REASON_MAX)
  if (out == null) return { work: false, kind: 'no-reply', reason: 'spawn returned nothing' }
  const lines = String(out).split('\n')
  for (const raw of lines) {
    const line = raw.trimStart()
    if (line.startsWith('EXTERNAL (')) return { work: true, kind: 'work', reason: '' }
    if (line.startsWith('REFUSED:')) return { work: false, kind: 'refused', reason: cut(line.slice('REFUSED:'.length)) || '(no reason given)' }
    if (line.startsWith('UNAVAILABLE:')) return { work: false, kind: 'unavailable', reason: cut(line.slice('UNAVAILABLE:'.length)) || '(no reason given)' }
  }
  const first = lines.map(l => l.trim()).find(Boolean)
  return { work: false, kind: 'malformed', reason: cut(first ? `no EXTERNAL/REFUSED/UNAVAILABLE line; reply began: ${first}` : 'empty reply') }
}
// classifyCrossReview(out) — the SAME rule for a triage-cross-reviewer reply: its
// positive header is `CROSS-REVIEW (`, which takes `EXTERNAL (`'s place; a stray
// `EXTERNAL (` line in it is no verdict. Pinned copy, identical in triage-compare.js
// and triage-parity.js.
const CROSS_HEADER = 'CROSS-REVIEW ('
function classifyCrossReview(out) {
  if (out == null) return classifyExternal(out)
  return classifyExternal(String(out).split('\n').map(raw => {
    const line = raw.trimStart()
    return line.startsWith(CROSS_HEADER) ? `EXTERNAL (${line.slice(CROSS_HEADER.length)}` : line.startsWith('EXTERNAL (') ? `- ${line}` : raw
  }).join('\n'))
}
// classifyBuild(out) — triage-exec's reading of a BUILD-mode triage-external reply
// (runOn() never runs bake-off mode): classifyExternal()'s verdict first; then work
// counts only when the `EXTERNAL (` header says `exit 0` and its `CHANGED FILES:` line
// (when present) does not say none. `exit 6` = ext-run.sh could not apply the patch and
// wrote nothing; any other or missing exit code = nothing proven written. Both are
// 'unavailable': no work landed, so runOn() takes the same-level Claude fallback.
function classifyBuild(out) {
  const v = classifyExternal(out)
  if (!v.work) return v
  const lines = String(out).split('\n').map(l => l.trim())
  const at = lines.findIndex(l => l.startsWith('EXTERNAL ('))
  const exit = (lines[at].match(/\bexit (-?\d+)\s*\)/) || [])[1]
  if (exit !== '0') {
    return { work: false, kind: 'unavailable', reason: exit === '6' ? 'exit 6: the patch did not apply, nothing was written'
      : `${exit == null ? 'no exit code' : `exit ${exit}`} in the EXTERNAL header: no work proven written` }
  }
  const changed = lines.slice(at + 1).find(l => l.startsWith('CHANGED FILES:'))
  if (changed && /^CHANGED FILES:\s*none\s*$/i.test(changed)) return { work: false, kind: 'unavailable', reason: 'CHANGED FILES: none (nothing changed in the tree)' }
  return v
}
// Every runOn() external spawn that produced no work: {id, vendor, kind, reason}.
// externalReport() splits it into refused / unavailable per vendor.
const externalNoWork = []

// The one header line triage-external reads before the brief. EFFORT is omitted when
// the plan set none, so ext-run.sh takes the tiers.json default for the level; WORKDIR
// only with args.repo (else the wrapper builds in its cwd).
const externalHeader = step => `VENDOR=${step.vendor} LEVEL=${step.level}` + (step.effort ? ` EFFORT=${step.effort}` : '') +
  (planRepo ? ` WORKDIR=${planRepo}` : '')

// runOn(st, step, prompt, ph, prefix, afterMax, label) — SINGLE place a work step
// {level, vendor, effort} is spawned, in Execute and in remediation alike. Returns
// {output, level, vendor, effort} (what actually ran) or null.
//   external (codex): triage-external with the header line. Its own effort stays
//     the wrapper's default — EFFORT in the header is the external model's effort.
//     The brief carries BOUNDARY_ATTESTATION right after the header line.
//     No work (classifyBuild(): refused, unavailable incl. exit 6 or no change, malformed, no reply, or a
//     rejected spawn) → the SAME level on Claude, logged '<vendor>→claude' with the
//     kind and reason, recorded in escalations and externalNoWork. An external CLI
//     that never ran has taught us nothing about the task, so it is not a reason to
//     climb; it is also never retried
//     on the same vendor, and there is no automatic hop to another vendor.
//   claude: top goes through runFable() only; every other level spawns its agent.
// Labels: `prefix` is '' in Execute ('<tier>:<id>') and 'redo:' / 'redo:deep@max:' in
// remediation ('<prefix><id>'); `label` overrides both (the external fallback's
// '<tier>←<vendor>:<id>').
async function runOn(st, step, prompt, ph, prefix, afterMax, label) {
  if (isExternal(step.vendor)) {
    let out = null
    let verdict = null
    try {
      out = await agent(`${externalHeader(step)}\n\n${BOUNDARY_ATTESTATION}\n\n${prompt}`,
        { phase: ph, agentType: 'triage-external', label: `${prefix}${step.vendor}:${step.level}:${st.id}` })
    } catch (e) {
      // A spent budget's hard ceiling stays the budget's (spawn() records the skip);
      // any other rejection is an external run that produced no work → the same
      // same-level Claude fallback as UNAVAILABLE, never a dropped subtask.
      if (budgeted && budget.remaining() <= 0) throw e
      const msg = String((e && e.message) || e).slice(0, EXTERNAL_REASON_MAX)
      log(`⚠ ${step.vendor} spawn for ${st.id} was rejected (${msg}).`)
      verdict = { work: false, kind: 'rejected', reason: msg }
    }
    verdict = verdict || classifyBuild(out)
    if (verdict.work) return { output: out, level: step.level, vendor: step.vendor, effort: step.effort }
    const claudeTier = tierName(step.level, 'claude')
    const what = `${step.vendor} ${verdict.kind}: ${verdict.reason}`
    log(`⚠ ${step.vendor}→claude: ${what} — ${step.vendor} produced no work for ${st.id} — re-running the same level on Claude (${claudeTier}); this SPENDS Claude quota.`)
    escalations.push({ id: st.id, from: tierName(step.level, step.vendor), to: claudeTier, reason: `${what} — same level on Claude` })
    externalNoWork.push({ id: st.id, vendor: step.vendor, kind: verdict.kind, reason: verdict.reason })
    neverRanExternally.add(st.id)
    const onClaude = { level: step.level, vendor: 'claude', effort: step.effort }
    return runOn(st, onClaude, prompt, ph, prefix, afterMax, `${prefix}${claudeTier}←${step.vendor}:${st.id}`)
  }
  if (step.level === 'top') return runFable(st, prompt, ph, prefix, afterMax, step.effort)
  const lbl = label || (prefix ? `${prefix}${st.id}` : `${tierName(step.level, 'claude')}:${st.id}`)
  const out = await agent(prompt, agentOpts(st, CLAUDE_AGENT[step.level], ph, lbl, step.effort))
  return out ? { output: out, level: step.level, vendor: 'claude', effort: step.effort } : null
}

// Run one subtask, budget-gated (WORK floor = RESERVE) via spawn(): one budget
// decision per subtask, before it starts, plus a hard-ceiling catch around the
// agent() call(s). Every result records the level, vendor and effort it actually ran
// at — redoStep() needs them. Returns null if the subtask is budget-skipped, hits the
// ceiling, or even the fallback dies — so filter(Boolean) drops it (rather than
// leaking a `null` output).
async function runSubtask(st) {
  return spawn(RESERVE, `Execute:${tierName(st.level, st.vendor)}`, st.id, async () => {
    const r = await runOn(st, { level: st.level, vendor: st.vendor, effort: st.effort }, brief(st), 'Execute', '', false)
    return r ? { subtask: st, ...r, attempts: 1 } : null
  })
}

// ─── Inline bake-offs (Wave 13B, opt-in: args.bakeoff) ──────────────────────
// A sampled subtask runs as a two-candidate triage-compare — its planned rung vs one
// challenger from config.tuning.challengers — BEFORE the rest of the plan, one at a
// time, so no compare's leakcheck ever overlaps a worker editing the tree. The winner's
// patch is applied with stage-worktree.sh apply and joins `results` like any other
// result, so verify()/assess()/remediation run unchanged on it. Reused, never
// reimplemented: triage-compare (staging, grading, leakcheck), stage-worktree.sh apply
// (the only writer of the real tree here), parity-report.sh ingest-compare (the only
// ledger writer — the orchestrator runs it; this workflow never writes the ledger).
const STAGE_WT = '~/.claude/scripts/stage-worktree.sh'
const PARITY_REPORT = '~/.claude/scripts/parity-report.sh'
const shq = s => `'${String(s).replace(/'/g, `'\\''`)}'`
const errText = e => String((e && e.message) || e).slice(0, 200)
// Subtask ids name the compare's outDir and the ledger's task token.
const BAKEOFF_ID = /^[A-Za-z0-9._+-]{1,80}$/
// Deterministic sampling (the DSL forbids Math.random/Date.now): FNV-1a 32-bit over
// UTF-16 code units, as a unit-interval draw.
function fnv1a32(s) {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 }
  return h >>> 0
}
const draw = s => fnv1a32(s) / 4294967296
const bo = bakeoffOn ? {
  cfg: args.bakeoff.config,
  tuning: args.bakeoff.config.tuning,
  seed: args.bakeoff.seed,
  repo: args.bakeoff.repo != null ? stripSlash(args.bakeoff.repo) : planRepo,
  outDir: stripSlash(args.bakeoff.outDir),
  weeklyPct: args.bakeoff.weeklyPct != null ? args.bakeoff.weeklyPct : null,
  rates: args.bakeoff.rates != null ? args.bakeoff.rates : null,
} : null
// Paused at weeklyPct >= pauseAtWeeklyPct, and when weeklyPct is MISSING: an unknown
// weekly usage is never read as "room to spare" (the orchestrator always passes it).
const weeklyUnknown = !!bo && bo.weeklyPct == null
const bakeoffPaused = !!bo && (weeklyUnknown || bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct)
const bakeoffs = []        // one record per SAMPLED subtask (report().bakeoffs)
const bakeoffSkipped = []  // {id, reason} for every subtask not sampled
const ingest = []          // one ledger hand-off per compare that graded
// Ids a bake-off WITHHELD: its apply result is unknown, or a failed apply may have
// written — the tree's state is not known to be what the subtask would start from, so
// it never runs in place on it; reported, and the run is INCOMPLETE. (A compare whose
// leak state is unknown, or that returned no result, stops the whole plan instead.)
const withheld = new Set()

// A codex challenger for a danger subtask must clear the same floor the plan's own
// codex danger work does (level >= deep, effort >= high): codexDangerEffort() is that
// rule, so an effort it would lift fails the floor and the challenger is excluded.
const meetsCodexDangerFloor = (level, effort) => atLeast(level, 'deep') === level && codexDangerEffort(level, effort) === effort

// bakeoffPick(st) — SINGLE OWNER of the whole sampling decision: eligibility, the
// deterministic sample, the challenger vendor and entry. → {planned, challenger, checks}
// | {skip: reason}. Eligible: its own checks (or the plan's, when it is the only
// subtask), non-empty files (compare needs them for an external candidate), an id
// usable as a path/ledger token, no Fable-family model (planned or challenger), and at
// least one challenger that differs from the
// planned (vendor, model, effort) — planned model/effort = the subtask's effort, else
// config.levels[level][vendor]. Sampled iff draw(seed, id, brief) < the level's rate
// (args.bakeoff.rates[level] when given — parity-report.sh's explore/maintain/none
// decision — else tuning.sampleRate; with rates given, the rate is returned for the
// record as {rate, rateFrom}). The vendor from a second draw over challengerMix's
// cumulative shares (VENDORS order); an empty vendor pool falls to the other; the
// entry from a third hash.
function bakeoffPick(st) {
  if (bakeoffPaused) return { skip: weeklyUnknown ? 'weekly-unknown' : 'paused' }
  const own = st.checks.length ? st.checks : (subtasks.length === 1 ? checks : [])
  if (!own.length) return { skip: subtasks.length === 1 ? 'no-checks' : 'no-own-checks' }
  if (!st.files.length) return { skip: 'no-files' }
  if (!BAKEOFF_ID.test(st.id)) return { skip: 'id-not-a-token' }
  // A planned top-level Claude subtask is Fable: its one sanctioned spawn path is
  // runFable() (announced, deep@max fallback), never a bake-off candidate.
  if (st.level === 'top' && st.vendor === 'claude') return { skip: 'top-claude' }
  const inc = (bo.cfg.levels[st.level] || {})[st.vendor]
  if (!isObj(inc) || !isStr(inc.model)) return { skip: 'no-levels-entry' }
  const planned = { vendor: st.vendor, level: st.level, model: inc.model, effort: st.effort || inc.effort || null }
  // Fable never runs as a bake-off candidate, at any level (runFable() is its one path).
  if (isFableModel(planned.model)) return { skip: 'planned-fable' }
  if (st.danger && !meetsDangerFloor(planned.vendor, planned.model)) return { skip: 'planned-below-danger-floor' }
  const byVendor = bo.tuning.challengers[st.level] || {}
  const pool = {}
  for (const v of VENDORS) {
    pool[v] = (byVendor[v] || []).filter(c =>
      !(v === planned.vendor && c.model === planned.model && c.effort === planned.effort) &&
      !(v === 'claude' && st.level === 'top') &&
      !isFableModel(c.model) &&
      !(st.danger && v === 'codex' && !meetsCodexDangerFloor(st.level, c.effort)) &&
      !(st.danger && !meetsDangerFloor(v, c.model)))
  }
  if (!VENDORS.some(v => pool[v].length)) return { skip: 'no-challenger' }
  const key = `${bo.seed}\0${st.id}\0${st.brief}`
  const fromRates = !!bo.rates && isNum(bo.rates[st.level])
  const rate = fromRates ? bo.rates[st.level] : bo.tuning.sampleRate
  const rateRec = bo.rates ? { rate, rateFrom: fromRates ? 'rates' : 'sampleRate' } : {}
  if (!(draw(key) < rate)) return Object.assign({ skip: 'not-sampled' }, rateRec)
  const u = draw(`${key}\0vendor`)
  let acc = 0
  let vendor = null
  for (const v of VENDORS) { acc += bo.tuning.challengerMix[v] || 0; if (u < acc) { vendor = v; break } }
  if (!vendor || !pool[vendor].length) vendor = VENDORS.find(v => v !== vendor && pool[v].length) || VENDORS.find(v => pool[v].length)
  const list = pool[vendor]
  // The entry from the draw's HIGH bits (FNV-1a's low bits are weak: `% 2` of it is
  // close to character parity).
  const c = list[Math.min(list.length - 1, Math.floor(draw(`${key}\0entry`) * list.length))]
  return Object.assign({ planned, challenger: { vendor, level: st.level, model: c.model, effort: c.effort }, checks: own }, rateRec)
}

// bakeoffChoice(res) — SINGLE OWNER of which patch (if any) an inline bake-off applies.
// A candidate counts only with a REAL diff (non-empty diffstat: an empty patch that
// "passes" did no work — the checks were already green) inside the subtask's files
// (outOfScope true = never inline-applied).
//   planned pass with a real, in-scope diff        → planned
//   else challenger pass with a real, in-scope diff → challenger (the logged fallback)
//   planned fail with a real in-scope diff that
//   applied at the sha                             → planned: the normal verify +
//                                                   remediation ladder then runs on it,
//                                                   as if it had run in place
//   anything else (planned produced nothing: unavailable / ungraded / invalid / an
//   empty, out-of-scope or non-applying diff)      → null: run the subtask in place
const realDiff = c => isStr(c.diffstat) && c.outOfScope !== true
function bakeoffChoice(res) {
  const by = new Map(res.candidates.map(c => [c.label, c]))
  const p = by.get('planned') || { status: 'missing' }
  const ch = by.get('challenger') || { status: 'missing' }
  if (p.status === 'pass' && realDiff(p)) return { apply: 'planned', cand: p }
  if (ch.status === 'pass' && realDiff(ch)) return { apply: 'challenger', cand: ch, planned: p }
  if (p.status === 'fail' && p.applies === true && realDiff(p)) return { apply: 'planned', cand: p }
  const note = c => (c.status === 'pass' || c.status === 'fail')
    ? (c.outOfScope === true ? ' outside its files' : !isStr(c.diffstat) ? ' with an empty diff' : c.status === 'fail' ? ' with no usable diff' : '') : ''
  return { apply: null, why: `planned ${p.status}${note(p)}, challenger ${ch.status}${note(ch)}` }
}

// cleanCheckCmd(st) — the bake-off's dirty + same-repo check as ONE command whose stdout
// carries tagged lines, so nothing rides on an agent's paraphrase of three separate
// commands: `CLEANCHECK rc <n>` (git status's exit), one `CLEANCHECK porcelain <line>`
// per modified file, `CLEANCHECK sessionTop|repoTop <physical path>` ('' = unknown),
// `CLEANCHECK now <UTC ISO time>` (the run date, recorded in the ingest result) and a
// final `CLEANCHECK end`. sessionTop is the tree checks/review run in: args.repo's when
// set, else the session's working directory.
function cleanCheckCmd(st) {
  const top = g => `$(t=$(${g} rev-parse --show-toplevel 2>/dev/null) && cd "$t" && pwd -P)`
  return `p=$(git -C ${shq(bo.repo)} status --porcelain -- ${st.files.map(shq).join(' ')} 2>&1); rc=$?; ` +
    'printf \'CLEANCHECK rc %s\\n\' "$rc"; printf \'%s\' "$p" | awk \'{print "CLEANCHECK porcelain " $0}\'; ' +
    `printf 'CLEANCHECK sessionTop %s\\n' "${top(planRepo ? `git -C ${shq(planRepo)}` : 'git')}"; ` +
    `printf 'CLEANCHECK repoTop %s\\n' "${top(`git -C ${shq(bo.repo)}`)}"; ` +
    'printf \'CLEANCHECK now %s\\n\' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo \'CLEANCHECK end\''
}
// parseCleanCheck(text) — the STRICT reading of that reply: rc, sessionTop, repoTop,
// now and end each exactly once, end the last tagged line, rc an exit status, now a UTC
// time, each top level '' or absolute. Anything else (no reply, a paraphrase, a lost
// line) → null: the check is retried once, then the sample is skipped.
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
function parseCleanCheck(text) {
  if (typeof text !== 'string') return null
  const tags = []
  for (const raw of text.split('\n')) {
    const m = raw.trim().match(/^CLEANCHECK (rc|porcelain|sessionTop|repoTop|now|end)(?: (.*))?$/)
    if (m) tags.push({ k: m[1], v: m[2] == null ? '' : m[2].trim() })
  }
  const only = k => { const hit = tags.filter(t => t.k === k); return hit.length === 1 ? hit[0].v : null }
  const rc = only('rc')
  const sessionTop = only('sessionTop')
  const repoTop = only('repoTop')
  const now = only('now')
  if (only('end') !== '' || tags[tags.length - 1].k !== 'end') return null
  if (rc == null || !/^\d{1,3}$/.test(rc) || now == null || !ISO_UTC.test(now)) return null
  if (sessionTop == null || repoTop == null || [sessionTop, repoTop].some(p => p !== '' && !p.startsWith('/'))) return null
  return { rc: Number(rc), porcelain: tags.filter(t => t.k === 'porcelain').map(t => t.v), sessionTop, repoTop, now }
}

// ledgerRun(id) — the ledger run id `<outDir basename>:<subtask id>`, always a
// parity-report.sh id token (letters, digits, . _ : + -, at most RUN_MAX chars; its
// is_token is the rule). Two subtasks never share one (ingest-compare refuses a
// collision): over RUN_MAX, the basename is cut and tagged `.<its FNV-1a hash>`, and an
// id over 40 chars is cut to 31 and tagged `.<its own hash>` too.
const RUN_MAX = 80
const hex8 = s => fnv1a32(s).toString(16).padStart(8, '0')
function ledgerRun(id) {
  const baseName = bo.outDir.split('/').pop().replace(/[^A-Za-z0-9._:+-]/g, '-')
  const full = `${baseName}:${id}`
  if (full.length <= RUN_MAX) return full
  const idPart = id.length <= 40 ? id : `${id.slice(0, 31)}.${hex8(id)}`
  return `${baseName.slice(0, RUN_MAX - idPart.length - 10)}.${hex8(baseName)}:${idPart}`
}
// ingestStatus(c) — the status a compare candidate is ledgered with: compare's grade,
// except that a "pass" with no real in-scope diff (realDiff(): the same rule that keeps
// bakeoffChoice() from applying it) did no work and is booked invalid, never a pass.
const ingestStatus = c => (c.status === 'pass' && !realDiff(c) ? 'invalid' : c.status)

// runBakeoff(st, pick) — one sampled subtask: clean check (dirty files + same repo) →
// triage-compare → bakeoffChoice() → stage-worktree.sh apply --require-clean.
// → {result} (applied; joins results), {inPlace: true} (nothing touched the tree:
// run it normally after the bake-offs), {withheld: true} (an apply left the tree in an
// unknown state: never run in place — reported, the run INCOMPLETE) or {abort: why}
// (LEAK, a leak state the compare could not confirm, or no compare result: the whole
// plan stops — a later subtask must never run on, or take as its clean baseline, a
// tree nobody checked).
async function runBakeoff(st, pick, rec, at) {
  const ask = () => agent(`Run this one command exactly as written and reply with its stdout verbatim — every line, nothing added, nothing left out. ` +
    'Do not run anything else, and do not interpret or fix anything.\n' + cleanCheckCmd(st),
  { phase: 'Execute', agentType: 'triage-quick-task', label: `bakeoff:dirty:${st.id}` })
  let raw = await ask()
  let dirty = parseCleanCheck(raw)
  if (!dirty) {
    log(`⚠ Bake-off: "${st.id}" clean check gave no usable reply (${raw == null ? 'none' : JSON.stringify(String(raw).trim().slice(0, 200))}) — retrying it once.`)
    raw = await ask()
    dirty = parseCleanCheck(raw)
  }
  // Unknown counts as dirty: a bake-off runs only on files proven unmodified.
  if (!dirty || dirty.rc !== 0 || dirty.porcelain.length) {
    rec.reason = !dirty ? 'dirty check unavailable' : dirty.rc !== 0 ? 'dirty check failed' : 'files modified in the tree'
    log(`Bake-off: "${st.id}" not run (${rec.reason}${!dirty ? `; last reply: ${raw == null ? 'none' : JSON.stringify(String(raw).trim().slice(0, 200))}` : ''}) — running it normally in place.`)
    return { inPlace: true }
  }
  // The patch lands in bo.repo while checks, review and in-place work run in the plan's
  // tree (args.repo, else the session's): both must be the same tree.
  if (!isStr(dirty.sessionTop) || !isStr(dirty.repoTop) || stripSlash(dirty.sessionTop) !== stripSlash(dirty.repoTop)) {
    rec.reason = 'repo-mismatch'
    log(`⚠ Bake-off: "${st.id}" not run — args.bakeoff.repo ${bo.repo} is not the ${planRepo ? 'args.repo' : 'session'} repo (${isStr(dirty.sessionTop) ? dirty.sessionTop : 'unknown'}); running it normally in place.`)
    return { inPlace: true }
  }
  at.stage = 'compare'
  const cand = (x, label) => Object.assign({ vendor: x.vendor, level: x.level, label }, x.model ? { model: x.model } : {}, x.effort ? { effort: x.effort } : {})
  // The planned candidate is exactly what runSubtask() would spawn: the level's own
  // agent / ext-run default model, the plan's effort when it set one.
  const plannedCand = cand({ vendor: st.vendor, level: st.level, effort: st.effort }, 'planned')
  if (isExternal(st.vendor) || isExternal(pick.challenger.vendor)) log(`⚠ Bake-off "${st.id}": an external candidate's workspace leaves this machine.`)
  let res = null
  let err = null
  try {
    res = await workflow('triage-compare', {
      repo: bo.repo, base: 'HEAD', brief: st.brief, files: st.files, acceptance: st.acceptance, checks: pick.checks,
      outDir: rec.compareOutDir, parallel: true, candidates: [plannedCand, cand(pick.challenger, 'challenger')],
    })
  } catch (e) {
    err = errText(e)
  }
  const statuses = () => (res && Array.isArray(res.candidates) ? res.candidates.map(c => ({ label: c.label, status: c.status })) : [])
  if (res && res.leak === true) {
    rec.outcome = 'skipped'
    rec.reason = 'LEAK'
    rec.candidates = statuses()
    log(`⚠ LEAK in the bake-off for "${st.id}": triage-compare reports ${bo.repo} changed during the run — nothing applied; aborting before any further work. Inspect the repo first.`)
    return { abort: 'LEAK' }
  }
  // The planned external run that produced nothing never ran externally (unless the
  // subtask later runs in place, where runOn() decides again).
  const plannedNothing = isExternal(st.vendor) && !!res && Array.isArray(res.candidates) && (res.candidates.find(c => c.label === 'planned') || {}).status === 'unavailable'
  const noExt = () => { if (plannedNothing) neverRanExternally.add(st.id) }
  // A compare that threw or returned no candidates, or a leak state it could not
  // confirm: whether the tree is still what it was is UNKNOWN — the code never assumes
  // an unknown leak is clean. Same stop as a LEAK: nothing applied, nothing further runs.
  const unknown = !res || !Array.isArray(res.candidates) ? (err ? `triage-compare failed: ${err}` : 'triage-compare returned no candidate list')
    : res.leak !== false ? 'leak state unknown (triage-compare could not confirm the repo is unchanged) — every grade void' : null
  if (unknown) {
    noExt()
    rec.outcome = 'skipped'
    rec.reason = unknown
    rec.candidates = statuses()
    log(`⚠ LEAK STATE UNKNOWN in the bake-off for "${st.id}": ${unknown} — nothing applied; aborting before any further work. Inspect ${bo.repo} first.`)
    return { abort: unknown }
  }
  const withhold = reason => {
    rec.outcome = 'withheld'
    rec.reason = reason
    withheld.add(st.id)
    log(`⚠ Bake-off "${st.id}" WITHHELD — ${reason}. It is NOT run in place; inspect ${bo.repo}, then re-run it. The run is reported INCOMPLETE.`)
    return { withheld: true }
  }
  rec.candidates = statuses()
  if (res.candidates.some(c => c.status === 'pass' || c.status === 'fail')) {
    const file = `${rec.compareOutDir}/compare-result.json`
    const repoName = bo.repo.split('/').pop().replace(/[^A-Za-z0-9._-]/g, '-').slice(0, 64) || 'repo'
    // Recorded at RUN time, so a deferred ingest never books the run to the tiers file
    // or the date current at ingest: ts = the clean check's clock; a candidate whose
    // model/effort the compare left null (a Claude level agent, an ext-run default)
    // gets what bakeoffPick() resolved from args.bakeoff.config (modelFrom 'tiers': the tiers file as passed at plan time).
    const resolved = { planned: pick.planned, challenger: pick.challenger }
    ingest.push({ id: st.id, file,
      result: { ts: dirty.now, base: res.base, sha: res.sha, leak: res.leak, baseMoved: res.baseMoved, graded: res.graded,
        candidates: res.candidates.map(c => {
          const r = resolved[c.label] || {}
          const fill = c.model == null && isStr(r.model)
          return { label: c.label, vendor: c.vendor, level: c.level, model: fill ? r.model : c.model == null ? null : c.model,
            modelFrom: fill ? 'tiers' : c.modelFrom == null ? null : c.modelFrom,
            effort: c.effort == null ? (r.effort || null) : c.effort, status: ingestStatus(c), totalTokens: c.totalTokens == null ? null : c.totalTokens,
            seconds: c.seconds == null ? null : c.seconds }
        }) },
      cmd: `${PARITY_REPORT} ingest-compare --result ${shq(file)} --repo-name ${repoName} --level ${st.level} --source inline --task ${st.id} --run ${ledgerRun(st.id)}` })
  }
  const choice = bakeoffChoice(res)
  if (!choice.apply) {
    rec.outcome = 'in-place'
    rec.reason = choice.why
    log(`Bake-off "${st.id}": nothing to apply (${choice.why}) — running it normally in place.`)
    return { inPlace: true }
  }
  const plannedRung = `${tierName(st.level, st.vendor)}${st.effort ? `@${st.effort}` : ''}`
  const ch = pick.challenger
  if (choice.apply === 'challenger') {
    log(`⚠ Bake-off fallback: "${st.id}" planned ${plannedRung} ${choice.planned.status === 'fail' ? 'failed' : `was ${choice.planned.status}`}, challenger ${ch.vendor} ${ch.model}@${ch.effort} passed — applying the challenger's patch`)
  }
  at.stage = 'apply'
  const patch = `${rec.compareOutDir}/${choice.apply}.patch`
  const ap = await agent(`Run this one command exactly as written and return its stdout JSON line field for field, plus rc = its exit status. Do not run anything else, and do not interpret or fix anything.\n` +
    `${STAGE_WT} apply --repo ${shq(bo.repo)} --patch ${shq(patch)} --require-clean`,
  { phase: 'Execute', agentType: 'triage-quick-task', label: `bakeoff:apply:${st.id}`,
    schema: { type: 'object', properties: { ok: { type: 'boolean' }, applied: { type: 'boolean' }, method: { type: 'string' }, treeModified: { type: 'boolean' },
      patch: { type: 'string' }, error: { type: 'string' }, rc: { type: ['integer', 'null'] } }, required: ['ok', 'rc', 'applied', 'treeModified'] } })
  // Applied = exit 0, ok, applied, a writing method, and the patch we asked for. Not
  // applied is safe to run in place ONLY when the script says nothing was written
  // (applied:false, treeModified:false: exit 6, an empty patch, an atomic failure);
  // anything else — no reply, a failed 3-way that may have left conflict markers —
  // leaves the tree in an unknown state: withheld, loudly.
  const applied = !!ap && ap.rc === 0 && ap.ok === true && ap.applied === true && (ap.method === 'plain' || ap.method === '3way') && ap.patch === patch
  if (!applied) {
    const untouched = !!ap && ap.applied === false && ap.treeModified === false && [0, 1, 6].includes(ap.rc)
    if (untouched) {
      rec.outcome = 'in-place'
      rec.reason = ap.rc === 6 ? `the ${choice.apply} patch was not applied (exit 6, nothing written: ${String(ap.error || 'it would not apply cleanly, or touches uncommitted work').slice(0, 160)})`
        : `apply failed (rc ${ap.rc}), nothing written`
      log(`⚠ Bake-off "${st.id}": the ${choice.apply} patch was not applied (${rec.reason}) — running it normally in place.`)
      return { inPlace: true }
    }
    noExt()
    return withhold(!ap ? `the apply step returned nothing — ${bo.repo} may already hold the ${choice.apply} patch`
      : ap.treeModified === true ? `the ${choice.apply} patch's apply FAILED after writing (rc ${ap.rc}): ${bo.repo} may hold conflict markers`
        : `the apply result is unknown (rc ${ap.rc}, applied ${ap.applied}, method ${ap.method}, treeModified ${ap.treeModified})`)
  }
  noExt()
  rec.outcome = choice.apply
  rec.applied = choice.apply
  // The applied result carries the PLAN's effort, whoever's patch it is: a later
  // redo (FIX/FAIL) re-runs the plan's rung, not the challenger's effort — that stays
  // in the bakeoffs record (rec.challenger).
  const who = choice.apply === 'planned' ? { level: st.level, vendor: st.vendor, effort: st.effort } : { level: st.level, vendor: ch.vendor, effort: st.effort }
  const c = choice.cand
  log(`Bake-off "${st.id}": applied the ${choice.apply} patch (${c.vendor} ${c.model || 'default'}@${c.effort || 'default'}; patch-check ${c.status}${c.diffstat ? `, ${c.diffstat}` : ''}).`)
  return { result: { subtask: st, level: who.level, vendor: who.vendor, effort: who.effort, attempts: 1, bakeoff: true,
    output: `Inline bake-off: applied the ${choice.apply} candidate's patch (${c.vendor} ${c.model || 'default'}@${c.effort || 'default'}), ` +
      `graded ${c.status} by patch-check at ${String(res.sha || '').slice(0, 12)}${c.diffstat ? ` (${c.diffstat})` : ''}. Nothing else ran in place.` } }
}

// runBakeoffs() — pick every subtask (logged), then run the sampled ones in plan
// order, one at a time. Each is WORK: budget-gated on RESERVE via spawn(). A budget
// skip leaves the subtask to run in place (where spawn() decides again).
async function runBakeoffs() {
  if (bakeoffPaused) {
    log(weeklyUnknown ? 'Bake-off paused: args.bakeoff.weeklyPct was not given (weekly usage unknown) — no subtask sampled.'
      : `Bake-off paused: weekly usage ${bo.weeklyPct}% >= pauseAtWeeklyPct ${bo.tuning.pauseAtWeeklyPct}% — no subtask sampled.`)
  }
  const picks = subtasks.map(st => ({ st, pick: bakeoffPick(st) }))
  const rateOf = p => (p.rate != null ? { rate: p.rate, rateFrom: p.rateFrom } : {})
  for (const x of picks) if (x.pick.skip) bakeoffSkipped.push(Object.assign({ id: x.st.id, reason: x.pick.skip }, rateOf(x.pick)))
  const chosen = picks.filter(x => !x.pick.skip)
  log(`Bake-off: ${chosen.length ? `sampled ${chosen.map(x => `"${x.st.id}" (vs ${x.pick.challenger.vendor} ${x.pick.challenger.model}@${x.pick.challenger.effort})`).join(', ')}` : 'no subtask sampled'}` +
    (bakeoffSkipped.length ? `; not sampled: ${bakeoffSkipped.map(s => `"${s.id}" (${s.reason})`).join(', ')}` : '') + '.')
  const applied = []
  for (const { st, pick } of chosen) {
    const ch = pick.challenger
    const rec = { id: st.id, challenger: { vendor: ch.vendor, model: ch.model, effort: ch.effort }, outcome: 'skipped',
      compareOutDir: `${bo.outDir}/${st.id}`, applied: null, candidates: [], ...rateOf(pick) }
    bakeoffs.push(rec)
    const at = { stage: 'dirty' }
    const out = await spawn(RESERVE, `Bakeoff:${tierName(st.level, st.vendor)}`, st.id, () => runBakeoff(st, pick, rec, at))
    if (!out) {
      rec.reason = rec.reason || 'budget'
      // Stopped (the budget ceiling) while its apply was in flight: the tree may hold
      // the patch — never run it in place on top.
      if (at.stage === 'apply') {
        rec.outcome = 'withheld'
        withheld.add(st.id)
        log(`⚠ Bake-off "${st.id}" stopped during its apply step — WITHHELD, not run in place: check ${bo.repo} first.`)
      }
      continue
    }
    if (out.abort) return { abort: out.abort, applied }
    if (out.result) applied.push(out.result)
  }
  return { abort: null, applied }
}

const bake = bakeoffOn ? await runBakeoffs() : null
const results = bake ? bake.applied.slice() : []
// A LEAK, an unconfirmed leak state or a missing compare result stops the WHOLE plan:
// nothing else runs on (or takes as its clean baseline) a tree nobody has checked.
if (bake && bake.abort) {
  return report({
    checks: checks.map(cmd => ({ cmd, pass: null })),
    review: { ran: false, verdict: null, text: '' },
    remediation: null,
    incomplete: true,
    failed: false,
    error: bake.abort === 'LEAK' ? 'LEAK: a bake-off\'s triage-compare reports the real repo changed during the run — aborted before any further work'
      : `LEAK STATE UNKNOWN: a bake-off's ${bake.abort} — aborted before any further work; inspect ${bo.repo} before re-running`,
  })
}
const appliedIds = new Set(results.map(r => r.subtask.id))
results.push(...(await parallel(subtasks.filter(st => !appliedIds.has(st.id) && !withheld.has(st.id)).map(st => () => runSubtask(st)))).filter(Boolean))
const dropped = subtasks.length - results.length
if (dropped > 0) log(`⚠ ${dropped} of ${subtasks.length} subtask(s) failed, were dropped or withheld — results are incomplete`)
if (withheld.size && results.length === 0) {
  return report({
    checks: checks.map(cmd => ({ cmd, pass: null })),
    review: { ran: false, verdict: null, text: '' },
    remediation: null,
    incomplete: true,
    failed: false,
    error: `bake-off: every subtask was withheld (${[...withheld].join(', ')}) — the real tree's state is unknown; inspect ${bo.repo} before re-running`,
  })
}

// externalReport() — the external half of the distillate, defined immediately above
// report() (which remains its single owner). DERIVED from the plan, the escalation log
// and neverRanExternally, NOT read off `results`: remediation rewrites `results` in
// place (results.length = 0; results.push(...merged)), so by the time report() runs, a
// subtask that really did run on codex and was then redone on Claude reads back as a
// Claude result. Ids only: bounded size, no worker prose — except refused / unavailable
// (runOn()'s externalNoWork: each no-work spawn's id, the wrapper's one-line reason cut
// to EXTERNAL_REASON_MAX, and for unavailable its kind). With args.bakeoff, each
// vendor also carries bakeoffApplied = the subtasks whose APPLIED bake-off patch came
// from that vendor's candidate (read off the bakeoffs records via appliedVendor(), so
// codex work that landed as a challenger shows here and not only in report().bakeoffs).
function externalReport() {
  const byVendor = {}
  for (const v of VENDORS.filter(isExternal)) {
    const routed = subtasks.filter(st => st.vendor === v).map(st => st.id)
    byVendor[v] = Object.assign({
      routed,
      ranExternally: routed.filter(id => !neverRanExternally.has(id)),
      returnedToClaude: escalations.filter(e => e.from.startsWith(`${v}:`)).map(e => `${e.id}→${e.to}`),
      refused: externalNoWork.filter(n => n.vendor === v && n.kind === 'refused').map(n => ({ id: n.id, reason: n.reason })),
      unavailable: externalNoWork.filter(n => n.vendor === v && n.kind !== 'refused').map(n => ({ id: n.id, reason: n.reason, kind: n.kind })),
    }, bakeoffOn ? { bakeoffApplied: bakeoffs.filter(b => appliedVendor(b) === v).map(b => b.id) } : {})
  }
  return byVendor
}

// appliedVendor(b) — the vendor whose patch a bakeoffs record applied (null: none was):
// the challenger's, or the planned candidate's = its subtask's vendor.
function appliedVendor(b) {
  if (b.applied === 'challenger') return b.challenger.vendor
  if (b.applied === 'planned') return subtasks.find(st => st.id === b.id).vendor
  return null
}

// bakeoffReport() — the inline bake-off half of the distillate (report() stays its
// single owner; present only when args.bakeoff was given). bakeoffs = one record per
// sampled subtask; bakeoffSkipped = why every other subtask was not sampled; ingest =
// one ledger hand-off per compare that graded. A workflow cannot write files, so each
// ingest entry carries the compact compare result (scores and ids only — no patch,
// tail or diffstat): the orchestrator writes `result` as JSON to `file`, then runs
// `cmd` (parity-report.sh ingest-compare, the one ledger writer; --applied is added
// here when a candidate's patch was applied, and left out when none was).
function bakeoffReport() {
  const appliedOf = new Map(bakeoffs.map(b => [b.id, b.applied]))
  return {
    bakeoffs: bakeoffs.map(b => Object.assign({}, b)),
    bakeoffSkipped: bakeoffSkipped.slice(),
    withheld: [...withheld],
    ingest: ingest.map(x => Object.assign({}, x, { cmd: x.cmd + (appliedOf.get(x.id) ? ` --applied ${appliedOf.get(x.id)}` : '') })),
  }
}

// report() — the SINGLE place the compact return value is built. Only distillate
// leaves this workflow: worker prose stays out of the orchestrator's context (that
// is the whole point of delegating), so subtasks report status, not output.
function report(extra) {
  const ran = new Map(results.map(r => [r.subtask.id, r]))
  const skippedIds = new Set(skipped.filter(s => s.stage.startsWith('Execute') || s.stage.startsWith('Remediate')).map(s => s.desc))
  // Present only when an external vendor was in play — mirroring how crossReview is
  // absent when not requested. The plan-flag arms keep the field honest when every
  // candidate was pulled back by the danger rule (routed: []). (The pre-Wave-12
  // `overflow` mirror of external.agy went with agy.) The last arm: a bake-off applied
  // an external challenger's patch to an all-Claude plan.
  const externalInPlay = wantsOverflow || (planVendor && isExternal(planVendor)) ||
    subtasks.some(st => isExternal(st.plannedVendor) || isExternal(st.vendor)) ||
    bakeoffs.some(b => { const v = appliedVendor(b); return v !== null && isExternal(v) })
  const external = externalInPlay ? externalReport() : null
  return Object.assign({
    subtasks: subtasks.map(st => {
      const r = ran.get(st.id)
      // A withheld bake-off subtask never ran (by design): skipped, with the reason
      // on its bakeoffs record, and the run INCOMPLETE.
      const status = needsUser.has(st.id) ? 'needs-user' : r ? 'ok' : (skippedIds.has(st.id) || withheld.has(st.id) ? 'skipped' : 'failed')
      const level = r ? r.level : st.level
      const vendor = r ? r.vendor : st.vendor
      return { id: st.id, tier: tierName(level, vendor), level, vendor, status, attempts: r ? r.attempts : 0 }
    }),
    escalations,
    noFable,
    needsUser: [...needsUser],
    budget: budgetReport(),
    ...(external ? { external } : {}),
    ...(bakeoffOn ? bakeoffReport() : {}),
  }, extra)
}

// Fail-loud (no silent empty success): if the budget refused EVERY subtask before it
// could spawn, there is nothing to verify — return an explicit error, not a hollow
// "success" with empty results. (A partial success — at least one subtask ran — falls
// through and gets verified normally.)
if (budgeted && results.length === 0 &&
    skipped.filter(s => s.stage.startsWith('Execute')).length === subtasks.length) {
  log('⚠ Budget: every subtask was skipped before it could spawn — no work performed; aborting before verification.')
  return report({
    checks: checks.map(cmd => ({ cmd, pass: null })),
    review: { ran: false, verdict: null, text: '' },
    remediation: null,
    incomplete: true,
    failed: false,
    error: 'budget exhausted: all subtasks skipped before execution',
  })
}

phase('Verify')
const nextLevel = l => {
  const i = LEVELS.indexOf(l)
  return i >= 0 && i < LEVELS.length - 1 ? LEVELS[i + 1] : l
}

// ─── Escalation ladder: SINGLE OWNER of "where does a failed result re-run?" ───────
// A rung is a level on a vendor, except that Claude deep at max effort is its own rung.
// The rubric escalates to Fable only from a FAILED or ESCALATED Opus@max attempt, and the
// deep level's default effort is below max — so an ESCALATE on a below-max deep attempt
// buys one Claude deep@max attempt first (cheaper than Fable and likelier to fix it).
// That step owes the Fable escalation it stood in for: if the deep@max attempt fails
// verification too (FIX, FAIL or ESCALATE alike), the second round below sends it on to
// Fable. A plan that already set effort:'max' on a Claude deep subtask has had its
// Opus@max attempt and goes straight on. An EXTERNAL deep attempt at max is not an
// Opus@max attempt, so it never counts as one.
const ranMax = r => r.vendor === 'claude' && r.level === 'deep' && r.effort === 'max'
const rung = r => (ranMax(r) ? 'deep@max' : tierName(r.level, r.vendor))

// redoStep(r, isEscalate) → { level, vendor, effort, reason?, owesFable? } for one failed
// result. Any rung change it implies is logged to `escalations` by remediate().
function redoStep(r, isEscalate) {
  // Every redo runs on CLAUDE. An external (codex) result that failed verification
  // comes back onto the Claude ladder FROM ITS OWN LEVEL, exactly as a Claude result at
  // that level would: FIX / objective FAIL → the same level on Claude, ESCALATE → one
  // level up (deep → deep@max first). Choice, replacing pre-Wave-12 overflow's "any
  // failure → deep": a failed builder-level check condemns the vendor's attempt, not the
  // plan's classification — the task is still well-specified builder work, so Claude
  // builder gets it with the failure text, and a reviewer ESCALATE still climbs. Never
  // sideways on the same vendor (the check already says it got this wrong), and never
  // an automatic hop to another vendor: runFable() stays the only way up to top.
  //
  // Effort: a plan's effort belongs to the level it was planned at. A step that CLIMBS
  // a level drops it (effort null → the target level's own default: builder@low never
  // becomes deep@low, and Fable after deep@max runs at its default); a same-level step
  // keeps the result's effort (for an applied bake-off patch that is the plan's —
  // runBakeoff() records the challenger's effort only in the bakeoffs record).
  const vendor = 'claude' // every redo runs on Claude — never sideways on the same vendor
  // noFable: deep@max is the ceiling. Where the ladder would step onto top — the owed
  // escalation after deep@max, an ESCALATE at deep@max, or a codex top result coming
  // back to Claude — a result that already ran deep@max stops ({stop}: remediate() calls
  // stopForUser()); any other gets one deep@max attempt first.
  if (noFable && (r.owesFable || r.level === 'top' || (isEscalate && ranMax(r)))) {
    if (r.owesFable || ranMax(r)) return { stop: true, level: 'deep', vendor, effort: 'max', reason: NO_FABLE_REASON }
    return { level: 'deep', vendor, effort: 'max', owesFable: true, reason: 'noFable: Fable excluded for this plan — one deep@max attempt instead of top' }
  }
  // noFable: a FIX / objective FAIL on a deep@max attempt that owes nothing yet (the plan's
  // own deep@max, or runFable()'s deep@max in place of top) gets its one same-rung retry,
  // marked owesFable so that a further failure reaches round 2, where the branch above stops
  // it for the user — never a second retry, never left reading `ok` while it still fails.
  if (noFable && ranMax(r)) return { level: 'deep', vendor, effort: 'max', owesFable: true, reason: 'noFable: deep@max retried once at the same rung — a further failure needs the user' }
  if (r.owesFable) return { level: 'top', vendor, effort: null, reason: 'the deep@max attempt failed verification too — the deferred Fable escalation goes ahead' }
  if (!isEscalate) {
    return { level: r.level, vendor, effort: r.effort, reason: isExternal(r.vendor) ? `${r.vendor} output failed verification — same level on Claude` : undefined }
  }
  if (r.level === 'deep' && !ranMax(r)) return { level: 'deep', vendor, effort: 'max', owesFable: true, reason: 'reviewer returned ESCALATE — one deep@max attempt before any Fable spawn' }
  const up = nextLevel(r.level)
  return { level: up, vendor, effort: up === r.level ? r.subtask.effort : null, reason: 'reviewer returned ESCALATE' }
}

// Review policy — the ONE place the reviewer's presence is decided.
//   never  : the reviewer never runs (the caller has its own gate).
//   always : it always runs, checks or not.
//   auto   : it runs when NOTHING else gates the work (no checks), or when a danger
//            subtask is present — verification rule 4's seam enforcement: a green
//            objective check can still hide a broken seam.
function reviewWanted(hasDanger) {
  if (reviewMode === 'never') return false
  if (reviewMode === 'always') return true
  return checks.length === 0 || hasDanger
}

// --- Verdict parsing: SINGLE OWNER. Every gate reading lives here (above verify(), whose
// gate retry asks the same question: did this gate give a usable verdict?). A gate counts
// only on a POSITIVE match; anything else — prose, a refusal, `**FAIL**`, a lost line —
// is a dead gate, retried once and then reported INCOMPLETE, never read as a pass.
//
// checkCommand(cmd) — an objective check as ONE command: the plan's command (in args.repo
// when set; braced, so `a || b` keeps its meaning; a trailing `;` dropped so the brace
// group stays valid), its last 40 lines of output, then a final `CHECKRC <exit status>`
// line printed by the shell itself.
const checkCommand = cmd => `out=$( { ${planRepo ? `cd ${shq(planRepo)} && ` : ''}{ ${cmd.replace(/[\s;]+$/, '')} ; } ; } 2>&1 ); rc=$?; ` +
  'printf \'%s\\n\' "$out" | tail -n 40; echo "CHECKRC $rc"'
// checkRc(text) → the exit status on the LAST `CHECKRC <n>` line (a whole line; the
// shell prints it after the command's own output), or null when there is none.
function checkRc(text) {
  const hits = [...String(text == null ? '' : text).matchAll(/^[ \t]*CHECKRC (\d{1,3})[ \t]*$/gm)]
  return hits.length ? Number(hits[hits.length - 1][1]) : null
}
// reviewVerdict(text) → 'PASS' | 'FIX' | 'ESCALATE' from the reply's first line (markdown
// bold tolerated), or null when it opens with anything else.
function reviewVerdict(text) {
  const m = String(text == null ? '' : text).trimStart().match(/^\**\s*(PASS|FIX|ESCALATE)\b/i)
  return m ? m[1].toUpperCase() : null
}

// Aggregate a verification object into { text, failed, isEscalate, incomplete, rcs, verdict }.
//   text       = feedback fed to remediation AND matched against for failure attribution.
//   rcs        = each check's exit status (null: no usable CHECKRC line).
//   verdict    = the reviewer's PASS/FIX/ESCALATE (null: it did not run, or no usable one).
//   failed     = ANY gate failing fails the round (a non-zero exit from any check, or the
//                reviewer saying FIX/ESCALATE).
//   isEscalate = the reviewer said ESCALATE (an objective check never escalates).
//   incomplete = a gate gave no usable verdict (dead even after its retry), or nothing
//                gated the work at all. Tri-state, per the rubric's fail-loud rule:
//                INCOMPLETE is not a pass and not a work-failure — there is no feedback
//                to remediate against, so it is reported loudly instead.
function assess(v) {
  const rcs = v.checks.map(c => (c.result == null ? null : checkRc(c.result)))
  const verdict = v.reviewRan && v.verdict != null ? reviewVerdict(v.verdict) : null
  const objText = v.checks.map((c, i) => `$ ${c.cmd}\n${rcs[i] == null ? '(gate gave no usable result)' : String(c.result)}`).join('\n\n')
  const revText = v.verdict == null ? '' : String(v.verdict)
  const parts = []
  if (v.checks.length) parts.push(`Objective checks:\n${objText}`)
  if (v.reviewRan) parts.push(`Reviewer:\n${revText}`)
  return {
    text: parts.join('\n\n'),
    rcs,
    verdict,
    failed: rcs.some(rc => rc != null && rc !== 0) || verdict === 'FIX' || verdict === 'ESCALATE',
    isEscalate: verdict === 'ESCALATE',
    incomplete: rcs.some(rc => rc == null) || (v.reviewRan && verdict == null) || (v.checks.length === 0 && !v.reviewRan),
  }
}

async function verify(items, remediated) {
  const dangerItems = items.filter(r => r.subtask && r.subtask.danger)
  const hasDanger = dangerItems.length > 0
  const files = [...new Set(items.flatMap(r => r.subtask.files || []))]
  const wantsReview = reviewWanted(hasDanger)

  // Objective check: quick-task runs ONE of the plan's commands, wrapped by
  // checkCommand(), and quotes its output; checkRc() reads the shell's own exit status.
  // One gate per command, so a failure is attributable to the command that produced it.
  const runCheck = (cmd, i) => () => agent(
    `Run this one command exactly as written${planRepo ? '' : ' from the repo root'} and reply with its output verbatim, including the final CHECKRC line. ` +
    `Do not run anything else, and do not interpret or fix anything:\n${checkCommand(cmd)}`,
    { label: `${remediated ? 'verify:recheck' : 'verify:objective-check'}#${i}`, phase: 'Verify', agentType: 'triage-quick-task' }
  )

  // Reviewer: reads the real git diff and returns PASS / FIX / ESCALATE. When danger
  // subtasks are present it names them and demands extra seam scrutiny (rubric verification
  // rule 4: green unit tests can hide a broken seam).
  const git = planRepo ? `git -C ${shq(planRepo)}` : 'git'
  const runReview = () => {
    const dangerNote = hasDanger
      ? `\n\nDANGER-FLAGGED subtasks (correctness-critical — a shared primitive/dispatcher many callers depend on, ≥3 modules touched at once, or format-sensitive output a subtle wrong layer silently corrupts). Give these EXTRA seam scrutiny: verify the dependent workflow end-to-end, not merely that unit tests pass:\n` +
        dangerItems.map(r => `  - [${r.subtask.id}] ${r.subtask.brief.slice(0, 120)}`).join('\n')
      : ''
    return agent(
      (planRepo ? `Repository: ${planRepo}\n` : '') +
      `You are the quality gate. Inspect the ACTUAL changes — do not just trust the worker summaries below.\n` +
      `Run \`${git} status\` and \`${git} diff\`${planRepo ? '' : ' from the repo root'}${files.length ? ` (focus on: ${files.join(', ')})` : ''}, then reply with ` +
      `PASS, or 'FIX: <what>', or 'ESCALATE: <why>' on the first line.${dangerNote}\n\n` +
      `Worker summaries for context:\n` +
      items.map(r => `## [${r.subtask.id}] ${r.subtask.brief.slice(0, 120)}\n${String(r.output).slice(0, 4000)}`).join('\n\n').slice(0, 14000),
      { label: remediated ? 'verify:re-review' : 'verify:reviewer', phase: 'Verify', agentType: 'triage-reviewer' }
    )
  }

  // Budget: a verify gate runs on the VERIFY floor (0), NOT the work RESERVE — we
  // skip WORK before VERIFICATION (rubric: an unverified result is worse than a
  // smaller verified one), so a gate runs as long as ANY budget remains and may draw
  // the reserve down to the last token. No budget at all → skip the gate (recorded,
  // logged); assess() then reports it INCOMPLETE — fail-loud, never a silent pass.
  //
  // A gate that gives no USABLE verdict (agent() → null, or a reply `usable` rejects:
  // no CHECKRC line, a reviewer reply that is not PASS/FIX/ESCALATE) still gets ONE
  // bounded retry; a second dead reply is returned as null and reported INCOMPLETE by
  // assess(). Retrying the GATE (not the subtasks) is deliberate: a dead verifier says
  // nothing about the work, so re-running subtasks on it would be remediation without a
  // signal. A hard-ceiling THROW (budgeted only) is DISTINCT: caught, recorded once as
  // a skip, and NOT retried (a spent-out budget won't recover on a re-attempt).
  async function runGate(mk, name, usable) {
    const stage = `Verify:${name}`
    if (budgeted && budget.remaining() <= 0) {
      log(`⚠ Budget: skipping ${stage} gate — 0 tokens remaining; verification reported INCOMPLETE.`)
      skipped.push({ stage, desc: name })
      return null
    }
    let ceilinged = false
    const attempt = async () => {
      if (!budgeted) return await mk()   // unbudgeted path: throws propagate, no catch
      try {
        return await mk()
      } catch (e) {
        if (!ceilinged) { skipped.push({ stage, desc: name }); ceilinged = true }
        log(`⚠ Budget: ${stage} gate hit the token ceiling (${String((e && e.message) || e)}) — treated as no output (INCOMPLETE).`)
        return null
      }
    }
    const live = o => o != null && usable(o)
    const why = o => (o == null ? 'returned no output (spawn/run failure)'
      : `gave no usable verdict (reply began: ${JSON.stringify(String(o).trim().slice(0, 200))})`)
    let out = await attempt()
    if (!live(out) && !ceilinged) {
      log(`⚠ ${name} gate ${why(out)} — retrying the gate once.`)
      out = await attempt()
      if (!live(out)) log(`⚠ ${name} gate failed twice (${why(out)}) — verification will be reported INCOMPLETE.`)
    }
    return live(out) ? out : null
  }

  const gates = checks.map((cmd, i) => () => runGate(runCheck(cmd, i), `check#${i}`, o => checkRc(o) !== null))
  if (wantsReview) gates.push(() => runGate(runReview, 'reviewer', o => reviewVerdict(o) !== null))
  const outs = await parallel(gates)
  return {
    checks: checks.map((cmd, i) => ({ cmd, result: outs[i] })),
    verdict: wantsReview ? outs[checks.length] : null,
    reviewRan: wantsReview,
    seam: wantsReview && checks.length > 0,
    remediated: !!remediated,
  }
}

let verification = await verify(results, false)

// --- Failure attribution helpers (targeted remediation) ---
function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') }
const basename = p => String(p).split('/').pop()
// True if `needle` (a file path or basename) appears as a path-boundary token in `text`.
// The left boundary accepts '/', so a listed basename matches inside a longer path (a path
// suffix); both sides reject filename chars, so 'bar.js' won't match inside 'foobar.jsx'.
function fileMentioned(needle, text) {
  if (!needle) return false
  return new RegExp(`(^|[^A-Za-z0-9._-])${escapeRe(needle)}(?![A-Za-z0-9._-])`).test(text)
}
// Which of a subtask's declared files are named in the failure text (basename or path-suffix).
function matchedFiles(r, text) {
  return (r.subtask.files || []).filter(f => fileMentioned(f, text) || fileMentioned(basename(f), text))
}

// remediate(pool, a, round) — one remediation round over `pool`, driven by assessment `a`
// (rubric: retry once at the same rung on FIX / objective FAIL, one rung up on ESCALATE;
// where to is redoStep()'s call). TARGETED: attribute the failure to specific subtasks by
// matching their files against the failure text and re-run only those. Fail loud: if
// attribution implicates NO subtask at all, re-run the whole pool and say so. In round 2
// (pool = subtasks still owed a Fable escalation), a failure attributed only to OTHER
// subtasks escalates nobody — their one round is spent, and Fable would be wasted.
async function remediate(pool, a, round) {
  const matched = r => matchedFiles(r, a.text).length > 0
  const attributionFailed = !results.some(matched)
  const targets = attributionFailed ? pool.slice() : pool.filter(matched)
  if (round === 1) {
    if (attributionFailed) log('⚠ Remediation attribution matched no subtask files in the failure text — re-running ALL subtasks.')
    else log(`Remediation implicating ${targets.length} of ${results.length} subtask(s): ` +
      targets.map(r => `"${r.subtask.id}" (matched: ${matchedFiles(r, a.text).join(', ')})`).join('; '))
    log(a.isEscalate ? 'Verification: ESCALATE — re-running the implicated subtask(s) one rung up with the feedback.'
                     : 'Verification did not pass — re-running the implicated subtask(s) with the feedback as context.')
  } else if (targets.length) {
    log(`⚠ deep@max attempt(s) failed verification — ${noFable ? 'stopping' : 'sending'} ${targets.map(r => `"${r.subtask.id}"`).join(', ')} ${noFable ? 'for the user (noFable)' : 'on to Fable'}` +
      (attributionFailed ? ' (attribution matched no subtask files: ALL deep@max subtasks).' : '.'))
  } else {
    log('deep@max step: the remaining failure is attributed only to other subtasks — no Fable escalation.')
  }
  const extra = `A prior attempt did not pass verification. Verifier feedback:\n${a.text.slice(0, 2000)}\nAddress it and complete the task.`
  // Remediation redos are WORK → budget-gated on the RESERVE floor (same as Execute),
  // with a ceiling catch, via spawn(). A budget-skipped redo drops from redoResults
  // (filter(Boolean)); the original result stays in the merged re-verify set below.
  const redo = await parallel(targets.map(r => () => {
    const step = redoStep(r, a.isEscalate)
    // A noFable stop spawns nothing (so needs no budget): the subtask keeps its last output.
    if (step.stop) { stopForUser(r.subtask.id); return null }
    return spawn(RESERVE, `Remediate:${rung(r)}`, r.subtask.id, async () => {
      const id = r.subtask.id
      if (rung(step) !== rung(r)) escalations.push({ id, from: rung(r), to: rung(step), reason: step.reason })
      const prefix = step.owesFable ? 'redo:deep@max:' : 'redo:'
      const out = await runOn(r.subtask, step, brief(r.subtask, extra), 'Verify', prefix, ranMax(r))
      return out ? { subtask: r.subtask, ...out, attempts: r.attempts + 1, owesFable: !!step.owesFable } : null
    })
  }))
  const redoResults = redo.filter(Boolean)
  // Re-verify the WHOLE task, not just the re-run subset: merge latest output per subtask
  // (remediated where re-run, original otherwise) so danger flags and file focus reflect
  // ALL executed work (seam rule 4).
  const bySubtask = new Map(results.map(r => [r.subtask.id, r]))
  for (const r of redoResults) bySubtask.set(r.subtask.id, r)
  const merged = [...bySubtask.values()]
  // `results` is what report() reads for per-subtask status/tier/attempts — refresh it
  // in place so a remediated subtask reports its NEW tier and attempt count.
  results.length = 0
  results.push(...merged)
  return { implicated: targets.length, attributionFailed, redoResults, merged }
}

// Round 1: one bounded remediation round, then re-verify once. Round 2 exists ONLY for
// subtasks whose round-1 step was deep@max (owesFable) and only when the re-verify still
// fails: they go on to Fable. It re-verifies only if something new ran — Fable unavailable
// after deep@max (runFable() skips the fallback) leaves the round-1 verification standing.
// Nothing sets owesFable in round 2, so there is never a round 3. Under noFable, round 2
// spawns nothing: every owed subtask it implicates stops for the user (redoStep()).
const first = assess(verification)
let remediation = null
if (first.failed && results.length) {
  const r1 = await remediate(results.slice(), first, 1)
  remediation = { implicated: r1.implicated, attributionFailed: r1.attributionFailed, escalated: first.isEscalate, rounds: 1 }
  // Re-verify only if something new ran (every redo budget-skipped, or stopped for the
  // user, leaves the round-1 verification standing — as in round 2).
  if (r1.redoResults.length) verification = await verify(r1.merged, true)
  const owed = r1.redoResults.filter(r => r.owesFable)
  const again = assess(verification)
  if (owed.length && again.failed) {
    const r2 = await remediate(owed, again, 2)
    if (r2.implicated) remediation.rounds = 2
    if (r2.redoResults.length) verification = await verify(r2.merged, true)
  }
}

// --- Cross-vendor second opinion (optional; verification rule 6) -------------
// Runs ONLY when the plan asked for it. The orchestrator owns the data-boundary
// decision (some repos are on a user-maintained deny-list), so the brief states that
// it has been cleared — the tier refuses otherwise. Findings are SIGNAL: logged and
// returned for the orchestrator to weigh, and deliberately NOT fed into assess(),
// remediation, or the pass/fail verdict. The objective checks remain the gate.
//
// One spawn per requested vendor (today: codex), each told its vendor on a VENDOR=
// first line and MODE=review. findings is keyed by vendor and holds only the vendors
// whose reply carried a `CROSS-REVIEW (` header; refused / unavailable list the rest
// ({vendor, reason} / {vendor, kind, reason}); ran = at least one returned findings.
let crossReview = null
if (crossVendors.length) {
  const dangerNames = subtasks.filter(st => st.danger).map(st => st.id)
  const files = [...new Set(subtasks.flatMap(st => st.files))]
  const outs = await parallel(crossVendors.map(v => () => spawn(0, 'CrossReview', `cross-vendor second opinion (${v})`, () => agent(
    `VENDOR=${v}\nMODE=review\n` +
    (planRepo ? `Repository: ${planRepo}\n` : '') +
    `Cross-vendor review of the working-tree diff in this repo. ${BOUNDARY_ATTESTATION}\n` +
    `Run \`${planRepo ? `git -C ${shq(planRepo)}` : 'git'} diff\` (and \`${planRepo ? `git -C ${shq(planRepo)}` : 'git'} status\`)${planRepo ? '' : ' from the repo root'}${files.length ? ` — focus on: ${files.join(', ')}` : ''} and relay the external reviewer's findings verbatim.\n` +
    (dangerNames.length ? `Danger-flagged subtasks needing seam scrutiny: ${dangerNames.join(', ')}\n` : '') +
    `Findings are advisory signal for the orchestrator, not a merge verdict.`,
    { label: `verify:cross-review:${v}`, phase: 'Verify', agentType: 'triage-cross-reviewer' }
  ))))
  // classifyCrossReview(): only a reply with a `CROSS-REVIEW (` header is findings; a
  // refusal, an unavailable run, a header-less reply or no reply is reported as such and
  // never counts toward ran (rule 6(d): nothing produced is UNAVAILABLE, not findings).
  const findings = {}
  const refused = []
  const unavailable = []
  crossVendors.forEach((v, i) => {
    const cls = classifyCrossReview(outs[i])
    if (cls.work) findings[v] = String(outs[i]).slice(0, 4000)
    else if (cls.kind === 'refused') refused.push({ vendor: v, reason: cls.reason })
    else unavailable.push({ vendor: v, kind: cls.kind, reason: cls.reason })
  })
  crossReview = { ran: Object.keys(findings).length > 0, findings, refused, unavailable }
  const missing = [...refused, ...unavailable].map(n => `${n.vendor} (${n.kind || 'refused'}: ${n.reason})`)
  log(missing.length ? `⚠ Cross-review produced no findings from ${missing.join(', ')} — advisory only, verdict unchanged.`
                     : `Cross-review returned findings from ${crossVendors.join(', ')} (advisory signal only — the objective checks remain the gate).`)
}

// Tri-state, fail-loud: whatever verification object we're returning (initial or
// re-verified), a dead gate makes it INCOMPLETE — flagged on the result and logged,
// never passed off as a confirmed green.
const finalAssessment = assess(verification)
if (finalAssessment.incomplete) {
  log('⚠ VERIFICATION INCOMPLETE — a gate could not run (or nothing gated the work); this result is NOT a confirmed pass.')
}
if (withheld.size) log(`⚠ INCOMPLETE — bake-off subtask(s) withheld, never run: ${[...withheld].join(', ')} (see bakeoffs[].reason).`)
// A subtask stopped for the user (noFable) is unfinished work whatever the final gates say
// (its deep@max fallback may have produced nothing for them to check): never a clean run.
if (needsUser.size) log(`⚠ INCOMPLETE — needs the user (noFable): ${[...needsUser].join(', ')}.`)

const reviewText = verification.verdict == null ? '' : String(verification.verdict)
const out = report({
  checks: verification.checks.map((c, i) => ({ cmd: c.cmd, pass: finalAssessment.rcs[i] == null ? null : finalAssessment.rcs[i] === 0 })),
  review: {
    ran: verification.reviewRan,
    verdict: finalAssessment.verdict,
    text: reviewText.slice(0, 1200),
  },
  remediation,
  incomplete: finalAssessment.incomplete || withheld.size > 0 || needsUser.size > 0,
  failed: finalAssessment.failed,
})
if (crossReview) out.crossReview = crossReview
return out
