export const meta = {
  name: 'triage-exec',
  description: 'Execute a pre-built triage plan: delegate each subtask to its level agent (Claude, or an external vendor), run the objective checks, remediate and escalate',
  whenToUse: 'Run a plan the orchestrator has ALREADY classified: /triage-exec with args = {subtasks:[{brief,level,vendor,files,acceptance,danger,effort}], checks:[shell commands], review, crossReview, overflow, vendor}. level is quick|builder|deep|top (tier is an alias; fable = top on Claude, overflow = builder on codex); vendor is claude|codex (agy was retired 2026-09-24 and is refused). It executes, verifies, re-runs only the implicated subtasks on failure (always on Claude), and escalates one rung up on ESCALATE (deep below max effort gets one deep@max attempt before Fable). It never classifies — a malformed plan throws before any spawn. A subtask may carry checks:[cmd] (its own objective checks: an inline bake-off\'s grade; the plan checks stay the verify gate). Opt-in INLINE BAKE-OFFS: bakeoff = {config: the `triage-tiers.sh --bakeoff-json` object, seed, repo (abs), outDir (abs, outside repo), weeklyPct?, rates?}; rates = `parity-report.sh rates --json` .rates ({level: rate in [0, 1]}: explore, maintain or 0 per level), used in place of sampleRate for its level and recorded on each bakeoffs/bakeoffSkipped entry that reached the draw. An eligible subtask (own checks, or the plan checks when it is the only subtask; non-empty files; a tuning challenger differing from its planned vendor/model/effort; codex challengers of danger work at effort >= high) is sampled deterministically (FNV-1a of seed+id+brief < rates[level], else sampleRate; none at weeklyPct >= pauseAtWeeklyPct) and runs FIRST, one at a time, as a planned-vs-challenger triage-compare, only if git status shows its files unmodified. Applied via stage-worktree.sh apply: the planned patch if it passed, else a passing challenger (logged as a fallback), else a failing planned diff (normal verify + remediation), else the subtask runs in place; a LEAK aborts the run. Returns bakeoffs, bakeoffSkipped and ingest: for each ingest entry the orchestrator writes result as JSON to file, then runs cmd (parity-report.sh ingest-compare).',
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
  `  vendor?:      ${VENDORS.join('|')}   // default vendor for subtasks that omit one (default: claude)\n` +
  '  overflow?:    boolean    // default: false — builder-level subtasks without a vendor run on codex\n' +
  `  review?:      ${REVIEW_MODES.join('|')}   // default: auto\n` +
  `  crossReview?: boolean|${Object.keys(CROSS_REVIEW_VENDORS).join('|')}   // default: false (true = codex)\n` +
  '  bakeoff?:     { config: <triage-tiers.sh --bakeoff-json object>, seed: string, repo: "/abs repo",\n' +
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
if (isRetired(args.vendor)) bad(`args.vendor ${JSON.stringify(args.vendor)}: ${RETIRED_VENDORS[args.vendor]}.`)
if (args.vendor != null && !VENDORS.includes(args.vendor)) bad(`args.vendor must be one of ${VENDORS.join('|')} (got ${JSON.stringify(args.vendor)}).`)
const wantsOverflow = args.overflow === true
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
  if (!isAbsPath(b.repo)) bad('args.bakeoff.repo must be an absolute path with no whitespace or quotes.')
  if (!isAbsPath(b.outDir)) bad('args.bakeoff.outDir must be an absolute path with no whitespace or quotes.')
  const repoC = stripSlash(b.repo)
  const outC = stripSlash(b.outDir)
  if (outC === repoC || outC.startsWith(`${repoC}/`) || repoC.startsWith(`${outC}/`)) bad('args.bakeoff.outDir must be outside args.bakeoff.repo (and must not contain it) — the staged worktrees and patches would dirty the real tree.')
  if (b.weeklyPct != null && !isNum(b.weeklyPct)) bad(`args.bakeoff.weeklyPct must be a number when given (got ${JSON.stringify(b.weeklyPct)}).`)
  // rates — the per-level sampling rate parity-report.sh decides (explore/maintain/none).
  if (b.rates != null && (!isObj(b.rates) || !Object.entries(b.rates).every(([l, r]) => LEVELS.includes(l) && isNum(r) && r >= 0 && r <= 1))) {
    bad(`args.bakeoff.rates must be {level: number in [0, 1]} over ${LEVELS.join('|')} (parity-report.sh rates --json .rates; got ${JSON.stringify(b.rates)}).`)
  }
}

// codexDangerEffort() — the danger floor for codex: effort at least `high`. An unset
// effort would otherwise fall to the tiers.json default, which is data and may drop;
// the floor is policy, so it is written into the header explicitly. At `top` an unset
// effort becomes xhigh rather than high, so the floor never LOWERS the level's default.
function codexDangerEffort(level, effort) {
  if (!effort) return level === 'top' ? 'xhigh' : 'high'
  return EFFORTS.indexOf(effort) >= EFFORTS.indexOf('high') ? effort : 'high'
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
    files: raw.files ? raw.files.map(f => f.trim()) : [],
    acceptance: raw.acceptance.trim(),
    danger,
    effort,
    checks: raw.checks ? raw.checks.map(c => c.trim()) : [],
  }
})

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
// Ids whose external spawn produced no work (null, UNAVAILABLE or REFUSED) and so ran
// on Claude instead — the one fact report()'s ranExternally cannot derive from the
// escalation log, since a verification failure records the same from/to pair.
const neverRanExternally = new Set()

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

function brief(st, extra) {
  return `${st.brief}\n\nRelevant files: ${st.files.join(', ') || '(discover)'}\n` +
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
// remediation step that lands on top. Rubric rule 6: announce
// it first; if the spawn hard-fails (agent() → null — e.g. a stale model registry), fall
// back to triage-deep-reasoner at max effort. EXCEPT when the attempt being escalated
// already WAS deep@max (`afterMax`): the fallback would re-run exactly the attempt that
// just failed. The subtask keeps its last output instead, and the skip is logged and
// recorded (to:'none') so the report never reads as if Fable ran. `prefix` namespaces the
// labels ('' in Execute, 'redo:' in remediation). Returns {output, level, vendor, effort} or null.
async function runFable(st, prompt, ph, prefix, afterMax) {
  log(`⚠ Escalating to Fable: ${st.id} — ${st.brief.slice(0, 80)}`)
  const out = await agent(prompt, agentOpts(st, CLAUDE_AGENT.top, ph, `${prefix}fable:${st.id}`))
  if (out) return { output: out, level: 'top', vendor: 'claude', effort: st.effort }
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

// The first line of an external wrapper's reply says whether the vendor produced work.
// UNAVAILABLE/REFUSED (triage-external's exit-code mapping) means it did not: there is
// nothing to verify, so it is treated like a null spawn. This is availability, not a
// verification verdict — those stay in assess().
const externalProducedNothing = out => /^\s*(UNAVAILABLE|REFUSED)\b/i.test(String(out || '').trimStart())

// The one header line triage-external reads before the brief. EFFORT is omitted when
// the plan set none, so ext-run.sh takes the tiers.json default for the level.
const externalHeader = step => `VENDOR=${step.vendor} LEVEL=${step.level}` + (step.effort ? ` EFFORT=${step.effort}` : '')

// runOn(st, step, prompt, ph, prefix, afterMax, label) — SINGLE place a work step
// {level, vendor, effort} is spawned, in Execute and in remediation alike. Returns
// {output, level, vendor, effort} (what actually ran) or null.
//   external (codex): triage-external with the header line. Its own effort stays
//     the wrapper's default — EFFORT in the header is the external model's effort.
//     No work (null, UNAVAILABLE, REFUSED) → the SAME level on Claude, logged
//     '<vendor>→claude' and recorded. An external CLI that never ran has taught us
//     nothing about the task, so it is not a reason to climb; it is also never retried
//     on the same vendor, and there is no automatic hop to another vendor.
//   claude: top goes through runFable() only; every other level spawns its agent.
// Labels: `prefix` is '' in Execute ('<tier>:<id>') and 'redo:' / 'redo:deep@max:' in
// remediation ('<prefix><id>'); `label` overrides both (the external fallback's
// '<tier>←<vendor>:<id>').
async function runOn(st, step, prompt, ph, prefix, afterMax, label) {
  if (isExternal(step.vendor)) {
    const out = await agent(`${externalHeader(step)}\n\n${prompt}`,
      { phase: ph, agentType: 'triage-external', label: `${prefix}${step.vendor}:${step.level}:${st.id}` })
    if (out && !externalProducedNothing(out)) return { output: out, level: step.level, vendor: step.vendor, effort: step.effort }
    const claudeTier = tierName(step.level, 'claude')
    log(`⚠ ${step.vendor}→claude: ${step.vendor} produced no work for ${st.id} (${out ? String(out).trimStart().split('\n')[0].slice(0, 120) : 'spawn returned nothing'}) — re-running the same level on Claude (${claudeTier}); this SPENDS Claude quota.`)
    escalations.push({ id: st.id, from: tierName(step.level, step.vendor), to: claudeTier, reason: `${step.vendor} unavailable — same level on Claude` })
    neverRanExternally.add(st.id)
    const onClaude = { level: step.level, vendor: 'claude', effort: step.effort }
    return runOn(st, onClaude, prompt, ph, prefix, afterMax, `${prefix}${claudeTier}←${step.vendor}:${st.id}`)
  }
  if (step.level === 'top') return runFable(st, prompt, ph, prefix, afterMax)
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
  repo: stripSlash(args.bakeoff.repo),
  outDir: stripSlash(args.bakeoff.outDir),
  weeklyPct: args.bakeoff.weeklyPct != null ? args.bakeoff.weeklyPct : null,
  rates: args.bakeoff.rates != null ? args.bakeoff.rates : null,
} : null
const bakeoffPaused = !!bo && bo.weeklyPct != null && bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct
const bakeoffs = []        // one record per SAMPLED subtask (report().bakeoffs)
const bakeoffSkipped = []  // {id, reason} for every subtask not sampled
const ingest = []          // one ledger hand-off per compare that graded

// A codex challenger for a danger subtask must clear the same floor the plan's own
// codex danger work does (level >= deep, effort >= high): codexDangerEffort() is that
// rule, so an effort it would lift fails the floor and the challenger is excluded.
const meetsCodexDangerFloor = (level, effort) => atLeast(level, 'deep') === level && codexDangerEffort(level, effort) === effort

// bakeoffPick(st) — SINGLE OWNER of the whole sampling decision: eligibility, the
// deterministic sample, the challenger vendor and entry. → {planned, challenger, checks}
// | {skip: reason}. Eligible: its own checks (or the plan's, when it is the only
// subtask), non-empty files (compare needs them for an external candidate), an id
// usable as a path/ledger token, and at least one challenger that differs from the
// planned (vendor, model, effort) — planned model/effort = the subtask's effort, else
// config.levels[level][vendor]. Sampled iff draw(seed, id, brief) < the level's rate
// (args.bakeoff.rates[level] when given — parity-report.sh's explore/maintain/none
// decision — else tuning.sampleRate; with rates given, the rate is returned for the
// record as {rate, rateFrom}). The vendor from a second draw over challengerMix's
// cumulative shares (VENDORS order); an empty vendor pool falls to the other; the
// entry from a third hash.
function bakeoffPick(st) {
  if (bakeoffPaused) return { skip: 'paused' }
  const own = st.checks.length ? st.checks : (subtasks.length === 1 ? checks : [])
  if (!own.length) return { skip: subtasks.length === 1 ? 'no-checks' : 'no-own-checks' }
  if (!st.files.length) return { skip: 'no-files' }
  if (!BAKEOFF_ID.test(st.id)) return { skip: 'id-not-a-token' }
  const inc = (bo.cfg.levels[st.level] || {})[st.vendor]
  if (!isObj(inc) || !isStr(inc.model)) return { skip: 'no-levels-entry' }
  const planned = { vendor: st.vendor, level: st.level, model: inc.model, effort: st.effort || inc.effort || null }
  const byVendor = bo.tuning.challengers[st.level] || {}
  const pool = {}
  for (const v of VENDORS) {
    pool[v] = (byVendor[v] || []).filter(c =>
      !(v === planned.vendor && c.model === planned.model && c.effort === planned.effort) &&
      !(st.danger && v === 'codex' && !meetsCodexDangerFloor(st.level, c.effort)))
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
  const c = list[fnv1a32(`${key}\0entry`) % list.length]
  return Object.assign({ planned, challenger: { vendor, level: st.level, model: c.model, effort: c.effort }, checks: own }, rateRec)
}

// bakeoffChoice(res) — SINGLE OWNER of which patch (if any) an inline bake-off applies.
//   planned pass                                 → planned
//   planned not pass AND challenger pass         → challenger (the logged fallback)
//   planned fail with a real diff that applied   → planned: the normal verify +
//                                                  remediation ladder then runs on it,
//                                                  as if it had run in place
//   anything else (planned produced nothing: unavailable / ungraded / invalid / an
//   empty or non-applying diff)                  → null: run the subtask in place
function bakeoffChoice(res) {
  const by = new Map(res.candidates.map(c => [c.label, c]))
  const p = by.get('planned') || { status: 'missing' }
  const ch = by.get('challenger') || { status: 'missing' }
  if (p.status === 'pass') return { apply: 'planned', cand: p }
  if (ch.status === 'pass') return { apply: 'challenger', cand: ch, planned: p }
  if (p.status === 'fail' && p.applies === true && isStr(p.diffstat)) return { apply: 'planned', cand: p }
  return { apply: null, why: `planned ${p.status}${p.status === 'fail' ? ' with no usable diff' : ''}, challenger ${ch.status}` }
}

// runBakeoff(st, pick) — one sampled subtask: dirty-files guard → triage-compare →
// bakeoffChoice() → stage-worktree.sh apply. → {result} (applied; joins results),
// {inPlace: true} (run it normally after the bake-offs) or {leak: true} (abort).
async function runBakeoff(st, pick, rec, at) {
  const files = st.files.map(shq).join(' ')
  const dirty = await agent(`Run this one command exactly as written and return porcelain = its stdout verbatim ("" if it printed nothing) and rc = its exit status. Do not run anything else, and do not interpret or fix anything.\n` +
    `git -C ${shq(bo.repo)} status --porcelain -- ${files}`,
  { phase: 'Execute', agentType: 'triage-quick-task', label: `bakeoff:dirty:${st.id}`,
    schema: { type: 'object', properties: { porcelain: { type: 'string' }, rc: { type: ['integer', 'null'] } }, required: ['porcelain', 'rc'] } })
  // Unknown counts as dirty: a bake-off runs only on files proven unmodified.
  if (!dirty || dirty.rc !== 0 || typeof dirty.porcelain !== 'string' || dirty.porcelain.trim() !== '') {
    rec.reason = dirty && dirty.rc === 0 && typeof dirty.porcelain === 'string' ? 'files modified in the tree' : 'dirty check failed'
    log(`Bake-off: "${st.id}" not run (${rec.reason}) — running it normally in place.`)
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
  if (res && res.leak === true) {
    rec.outcome = 'skipped'
    rec.reason = 'LEAK'
    rec.candidates = Array.isArray(res.candidates) ? res.candidates.map(c => ({ label: c.label, status: c.status })) : []
    log(`⚠ LEAK in the bake-off for "${st.id}": triage-compare reports ${bo.repo} changed during the run — nothing applied; aborting before any further work. Inspect the repo first.`)
    return { leak: true }
  }
  if (!res || !Array.isArray(res.candidates)) {
    rec.outcome = 'in-place'
    rec.reason = err ? `triage-compare failed: ${err}` : 'triage-compare returned no candidate list'
    log(`⚠ Bake-off "${st.id}": ${rec.reason} — its candidates are unavailable; running it normally in place.`)
    return { inPlace: true }
  }
  rec.candidates = res.candidates.map(c => ({ label: c.label, status: c.status }))
  if (res.leak == null) log(`⚠ Bake-off "${st.id}": triage-compare could not confirm ${bo.repo} is unchanged (leak check incomplete) — its grades are void.`)
  if (res.leak === false && res.candidates.some(c => c.status === 'pass' || c.status === 'fail')) {
    const file = `${rec.compareOutDir}/compare-result.json`
    const repoName = bo.repo.split('/').pop().replace(/[^A-Za-z0-9._-]/g, '-').slice(0, 64) || 'repo'
    const run = `${bo.outDir.split('/').pop().replace(/[^A-Za-z0-9._:+-]/g, '-')}:${st.id}`.slice(0, 80)
    ingest.push({ id: st.id, file,
      result: { base: res.base, sha: res.sha, leak: res.leak, baseMoved: res.baseMoved, graded: res.graded,
        candidates: res.candidates.map(c => ({ label: c.label, vendor: c.vendor, level: c.level, model: c.model == null ? null : c.model,
          effort: c.effort == null ? null : c.effort, status: c.status, totalTokens: c.totalTokens == null ? null : c.totalTokens,
          seconds: c.seconds == null ? null : c.seconds })) },
      cmd: `${PARITY_REPORT} ingest-compare --result ${shq(file)} --repo-name ${repoName} --level ${st.level} --source inline --task ${st.id} --run ${run}` })
  }
  const choice = res.leak === false ? bakeoffChoice(res) : { apply: null, why: 'leak state unknown — every grade void' }
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
    `${STAGE_WT} apply --repo ${shq(bo.repo)} --patch ${shq(patch)}`,
  { phase: 'Execute', agentType: 'triage-quick-task', label: `bakeoff:apply:${st.id}`,
    schema: { type: 'object', properties: { ok: { type: 'boolean' }, applied: { type: 'boolean' }, method: { type: 'string' }, error: { type: 'string' }, rc: { type: ['integer', 'null'] } }, required: ['ok', 'rc'] } })
  if (!ap || ap.rc !== 0 || ap.ok !== true) {
    rec.outcome = 'in-place'
    rec.reason = !ap ? 'apply result unknown' : ap.rc === 6 ? 'patch would not apply to the tree (exit 6, nothing written)' : `apply failed (rc ${ap.rc})`
    log(`⚠ Bake-off "${st.id}": the ${choice.apply} patch was not applied (${rec.reason}) — running it normally in place.` +
      (!ap ? ` The apply step returned nothing: check ${bo.repo} for a half-known state (stage-worktree.sh apply is atomic).` : ''))
    return { inPlace: true }
  }
  rec.outcome = choice.apply
  rec.applied = choice.apply
  const who = choice.apply === 'planned' ? { level: st.level, vendor: st.vendor, effort: st.effort } : { level: st.level, vendor: ch.vendor, effort: ch.effort }
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
  if (bakeoffPaused) log(`Bake-off paused: weekly usage ${bo.weeklyPct}% >= pauseAtWeeklyPct ${bo.tuning.pauseAtWeeklyPct}% — no subtask sampled.`)
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
      if (at.stage === 'apply') log(`⚠ Bake-off "${st.id}" stopped during its apply step — check ${bo.repo} before trusting the in-place run.`)
      continue
    }
    if (out.leak) return { leak: true, applied }
    if (out.result) applied.push(out.result)
  }
  return { leak: false, applied }
}

const bake = bakeoffOn ? await runBakeoffs() : null
const results = bake ? bake.applied.slice() : []
if (bake && bake.leak) {
  return report({
    checks: checks.map(cmd => ({ cmd, pass: null })),
    review: { ran: false, verdict: null, text: '' },
    remediation: null,
    incomplete: true,
    failed: false,
    error: 'LEAK: a bake-off\'s triage-compare reports the real repo changed during the run — aborted before any further work',
  })
}
const appliedIds = new Set(results.map(r => r.subtask.id))
results.push(...(await parallel(subtasks.filter(st => !appliedIds.has(st.id)).map(st => () => runSubtask(st)))).filter(Boolean))
const dropped = subtasks.length - results.length
if (dropped > 0) log(`⚠ ${dropped} of ${subtasks.length} subtask(s) failed or were dropped — results are incomplete`)

// externalReport() — the external half of the distillate, defined immediately above
// report() (which remains its single owner). DERIVED from the plan, the escalation log
// and neverRanExternally, NOT read off `results`: remediation rewrites `results` in
// place (results.length = 0; results.push(...merged)), so by the time report() runs, a
// subtask that really did run on codex and was then redone on Claude reads back as a
// Claude result. Ids only: bounded size, no worker prose. With args.bakeoff, each
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
      const status = r ? 'ok' : (skippedIds.has(st.id) ? 'skipped' : 'failed')
      const level = r ? r.level : st.level
      const vendor = r ? r.vendor : st.vendor
      return { id: st.id, tier: tierName(level, vendor), level, vendor, status, attempts: r ? r.attempts : 0 }
    }),
    escalations,
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
  const vendor = 'claude' // every redo runs on Claude — never sideways on the same vendor
  if (r.owesFable) return { level: 'top', vendor, effort: r.subtask.effort, reason: 'the deep@max attempt failed verification too — the deferred Fable escalation goes ahead' }
  if (!isEscalate) {
    return { level: r.level, vendor, effort: r.effort, reason: isExternal(r.vendor) ? `${r.vendor} output failed verification — same level on Claude` : undefined }
  }
  if (r.level === 'deep' && !ranMax(r)) return { level: 'deep', vendor, effort: 'max', owesFable: true, reason: 'reviewer returned ESCALATE — one deep@max attempt before any Fable spawn' }
  return { level: nextLevel(r.level), vendor, effort: r.subtask.effort, reason: 'reviewer returned ESCALATE' }
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

async function verify(items, remediated) {
  const dangerItems = items.filter(r => r.subtask && r.subtask.danger)
  const hasDanger = dangerItems.length > 0
  const files = [...new Set(items.flatMap(r => r.subtask.files || []))]
  const wantsReview = reviewWanted(hasDanger)

  // Objective check: quick-task runs ONE of the plan's commands and reports PASS/FAIL.
  // One gate per command, so a failure is attributable to the command that produced it.
  const runCheck = (cmd, i) => () => agent(
    `Run this command from the repo root and report the result. Quote the last ~40 lines of output verbatim, then state PASS or FAIL on its own line:\n${cmd}`,
    { label: `${remediated ? 'verify:recheck' : 'verify:objective-check'}#${i}`, phase: 'Verify', agentType: 'triage-quick-task' }
  )

  // Reviewer: reads the real git diff and returns PASS / FIX / ESCALATE. When danger
  // subtasks are present it names them and demands extra seam scrutiny (rubric verification
  // rule 4: green unit tests can hide a broken seam).
  const runReview = () => {
    const dangerNote = hasDanger
      ? `\n\nDANGER-FLAGGED subtasks (correctness-critical — a shared primitive/dispatcher many callers depend on, ≥3 modules touched at once, or format-sensitive output a subtle wrong layer silently corrupts). Give these EXTRA seam scrutiny: verify the dependent workflow end-to-end, not merely that unit tests pass:\n` +
        dangerItems.map(r => `  - [${r.subtask.id}] ${r.subtask.brief.slice(0, 120)}`).join('\n')
      : ''
    return agent(
      `You are the quality gate. Inspect the ACTUAL changes — do not just trust the worker summaries below.\n` +
      `Run \`git status\` and \`git diff\` from the repo root${files.length ? ` (focus on: ${files.join(', ')})` : ''}, then reply with ` +
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
  // A gate whose agent dies (agent() → null, a spawn/run failure) still gets ONE
  // bounded retry; a second null is reported INCOMPLETE by assess(). Retrying the GATE
  // (not the subtasks) is deliberate: a dead verifier says nothing about the work, so
  // re-running subtasks on it would be remediation without a signal. A hard-ceiling
  // THROW (budgeted only) is DISTINCT: caught, recorded once as a skip, and NOT
  // retried (a spent-out budget won't recover on a re-attempt).
  async function runGate(mk, name) {
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
    let out = await attempt()
    if (out == null && !ceilinged) {
      log(`⚠ ${name} gate returned no output (spawn/run failure) — retrying the gate once.`)
      out = await attempt()
      if (out == null) log(`⚠ ${name} gate failed twice — verification will be reported INCOMPLETE.`)
    }
    return out
  }

  const gates = checks.map((cmd, i) => () => runGate(runCheck(cmd, i), `check#${i}`))
  if (wantsReview) gates.push(() => runGate(runReview, 'reviewer'))
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

// --- Verdict parsing: SINGLE OWNER. Every FAIL/FIX/ESCALATE interpretation lives here. ---
const objFailed = t => /(^|\n)\s*FAIL\b/i.test(String(t || ''))
const reviewFailed = t => /^\s*(FIX|ESCALATE)\b/i.test(String(t || '').trimStart())
const reviewEscalate = t => /^\s*ESCALATE\b/i.test(String(t || '').trimStart())

// Aggregate a verification object into { text, failed, isEscalate, incomplete }.
//   text       = feedback fed to remediation AND matched against for failure attribution.
//   failed     = ANY gate failing fails the round (an objective FAIL from any check, or
//                the reviewer saying FIX/ESCALATE).
//   isEscalate = the reviewer escalates when it ran; with no reviewer, a check whose
//                output opens with ESCALATE does.
//   incomplete = a gate died (null even after its retry), or nothing gated the work at
//                all. Tri-state, per the rubric's fail-loud rule: INCOMPLETE is not a
//                pass and not a work-failure — there is no feedback to remediate
//                against, so it is reported loudly instead.
function assess(v) {
  const liveChecks = v.checks.filter(c => c.result != null)
  const objText = v.checks.map(c => `$ ${c.cmd}\n${c.result == null ? '(gate did not run)' : String(c.result)}`).join('\n\n')
  const revText = v.verdict == null ? '' : String(v.verdict)
  const parts = []
  if (v.checks.length) parts.push(`Objective checks:\n${objText}`)
  if (v.reviewRan) parts.push(`Reviewer:\n${revText}`)
  return {
    text: parts.join('\n\n'),
    failed: liveChecks.some(c => objFailed(String(c.result))) || (v.reviewRan && v.verdict != null && reviewFailed(revText)),
    isEscalate: (v.reviewRan && v.verdict != null) ? reviewEscalate(revText) : liveChecks.some(c => reviewEscalate(String(c.result))),
    incomplete: v.checks.some(c => c.result == null) || (v.reviewRan && v.verdict == null) || (v.checks.length === 0 && !v.reviewRan),
  }
}

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
    log(`⚠ deep@max attempt(s) failed verification — sending ${targets.map(r => `"${r.subtask.id}"`).join(', ')} on to Fable` +
      (attributionFailed ? ' (attribution matched no subtask files: ALL deep@max subtasks).' : '.'))
  } else {
    log('deep@max step: the remaining failure is attributed only to other subtasks — no Fable escalation.')
  }
  const extra = `A prior attempt did not pass verification. Verifier feedback:\n${a.text.slice(0, 2000)}\nAddress it and complete the task.`
  // Remediation redos are WORK → budget-gated on the RESERVE floor (same as Execute),
  // with a ceiling catch, via spawn(). A budget-skipped redo drops from redoResults
  // (filter(Boolean)); the original result stays in the merged re-verify set below.
  const redo = await parallel(targets.map(r => () => spawn(RESERVE, `Remediate:${rung(r)}`, r.subtask.id, async () => {
    const id = r.subtask.id
    const step = redoStep(r, a.isEscalate)
    if (rung(step) !== rung(r)) escalations.push({ id, from: rung(r), to: rung(step), reason: step.reason })
    const prefix = step.owesFable ? 'redo:deep@max:' : 'redo:'
    const out = await runOn(r.subtask, step, brief(r.subtask, extra), 'Verify', prefix, ranMax(r))
    return out ? { subtask: r.subtask, ...out, attempts: r.attempts + 1, owesFable: !!step.owesFable } : null
  })))
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
// Nothing sets owesFable in round 2, so there is never a round 3.
const first = assess(verification)
let remediation = null
if (first.failed && results.length) {
  const r1 = await remediate(results.slice(), first, 1)
  remediation = { implicated: r1.implicated, attributionFailed: r1.attributionFailed, escalated: first.isEscalate, rounds: 1 }
  verification = await verify(r1.merged, true)
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
// first line. findings is keyed by vendor and holds only the vendors that returned
// something; ran = at least one did.
let crossReview = null
if (crossVendors.length) {
  const dangerNames = subtasks.filter(st => st.danger).map(st => st.id)
  const files = [...new Set(subtasks.flatMap(st => st.files))]
  const outs = await parallel(crossVendors.map(v => () => spawn(0, 'CrossReview', `cross-vendor second opinion (${v})`, () => agent(
    `VENDOR=${v}\n` +
    `Cross-vendor review of the working-tree diff in this repo. The data boundary has been cleared by the orchestrator for this repository.\n` +
    `Run \`git diff\` (and \`git status\`) from the repo root${files.length ? ` — focus on: ${files.join(', ')}` : ''} and relay the external reviewer's findings verbatim.\n` +
    (dangerNames.length ? `Danger-flagged subtasks needing seam scrutiny: ${dangerNames.join(', ')}\n` : '') +
    `Findings are advisory signal for the orchestrator, not a merge verdict.`,
    { label: `verify:cross-review:${v}`, phase: 'Verify', agentType: 'triage-cross-reviewer' }
  ))))
  const findings = {}
  crossVendors.forEach((v, i) => { if (outs[i] != null) findings[v] = String(outs[i]).slice(0, 4000) })
  crossReview = { ran: Object.keys(findings).length > 0, findings }
  const missing = crossVendors.filter(v => !(v in findings))
  log(missing.length ? `⚠ Cross-review produced no findings from ${missing.join(', ')} (unavailable, refused, or budget-skipped) — advisory only, verdict unchanged.`
                     : `Cross-review returned findings from ${crossVendors.join(', ')} (advisory signal only — the objective checks remain the gate).`)
}

// Tri-state, fail-loud: whatever verification object we're returning (initial or
// re-verified), a dead gate makes it INCOMPLETE — flagged on the result and logged,
// never passed off as a confirmed green.
const finalAssessment = assess(verification)
if (finalAssessment.incomplete) {
  log('⚠ VERIFICATION INCOMPLETE — a gate could not run (or nothing gated the work); this result is NOT a confirmed pass.')
}

const reviewText = verification.verdict == null ? '' : String(verification.verdict)
const out = report({
  checks: verification.checks.map(c => ({ cmd: c.cmd, pass: c.result == null ? null : !objFailed(String(c.result)) })),
  review: {
    ran: verification.reviewRan,
    verdict: !verification.reviewRan || verification.verdict == null ? null
      : reviewEscalate(reviewText) ? 'ESCALATE' : reviewFailed(reviewText) ? 'FIX' : 'PASS',
    text: reviewText.slice(0, 1200),
  },
  remediation,
  incomplete: finalAssessment.incomplete,
  failed: finalAssessment.failed,
})
if (crossReview) out.crossReview = crossReview
return out
