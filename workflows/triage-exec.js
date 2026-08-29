export const meta = {
  name: 'triage-exec',
  description: 'Execute a pre-built triage plan: delegate each subtask to its tier agent, run the objective checks, remediate and escalate',
  whenToUse: 'Run a plan the orchestrator has ALREADY classified: /triage-exec with args = {subtasks:[{brief,tier,files,acceptance,danger,effort}], checks:[shell commands], review, crossReview}. It executes, verifies, re-runs only the implicated subtasks on failure, and escalates one tier up on ESCALATE. It never classifies — a malformed plan throws before any spawn.',
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
const TIERS = ['quick', 'builder', 'deep', 'fable']
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
const REVIEW_MODES = ['auto', 'always', 'never']

const USAGE = 'Expected args = {\n' +
  `  subtasks: [{ id?, brief, tier: ${TIERS.join('|')}, files?: string[], acceptance, danger?: bool, effort?: ${EFFORTS.join('|')} }]  // at least one\n` +
  '  checks?:      string[]   // shell commands run as objective gates\n' +
  `  review?:      ${REVIEW_MODES.join('|')}   // default: auto\n` +
  '  crossReview?: boolean    // default: false\n}'

function bad(msg) {
  throw new Error(`triage-exec: ${msg}\n${USAGE}`)
}

const isStr = v => typeof v === 'string' && v.trim().length > 0
const typeName = v => (v === null ? 'null' : Array.isArray(v) ? 'an array' : typeof v)

if (!args || typeof args !== 'object' || Array.isArray(args)) bad(`args must be a plan object (got ${typeName(args)}).`)
if (!Array.isArray(args.subtasks) || args.subtasks.length === 0) bad('args.subtasks must be a non-empty array.')
if (args.checks != null && !(Array.isArray(args.checks) && args.checks.every(isStr))) bad('args.checks must be an array of non-empty shell-command strings.')
if (args.review != null && !REVIEW_MODES.includes(args.review)) bad(`args.review must be one of ${REVIEW_MODES.join('|')} (got ${JSON.stringify(args.review)}).`)
if (args.crossReview != null && typeof args.crossReview !== 'boolean') bad('args.crossReview must be a boolean.')

const seenIds = new Set()
const subtasks = args.subtasks.map((raw, i) => {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`subtasks[${i}] must be an object (got ${typeName(raw)}).`)
  if (!isStr(raw.brief)) bad(`subtasks[${i}].brief must be a non-empty string.`)
  if (!TIERS.includes(raw.tier)) bad(`subtasks[${i}].tier must be one of ${TIERS.join('|')} (got ${JSON.stringify(raw.tier)}).`)
  if (!isStr(raw.acceptance)) bad(`subtasks[${i}].acceptance must be a non-empty string — verification has nothing to check against without it.`)
  if (raw.files != null && !(Array.isArray(raw.files) && raw.files.every(isStr))) bad(`subtasks[${i}].files must be an array of path strings.`)
  if (raw.danger != null && typeof raw.danger !== 'boolean') bad(`subtasks[${i}].danger must be a boolean.`)
  if (raw.effort != null && !EFFORTS.includes(raw.effort)) bad(`subtasks[${i}].effort must be one of ${EFFORTS.join('|')} (got ${JSON.stringify(raw.effort)}).`)
  if (raw.id != null && !isStr(raw.id)) bad(`subtasks[${i}].id must be a non-empty string when given.`)
  // Ids are the handle everything downstream uses (logs, skip records, remediation
  // attribution, the returned report), so they are assigned here when absent and
  // must be unique — a duplicate would silently merge two subtasks in the report.
  const id = raw.id ? raw.id.trim() : `s${i + 1}`
  if (seenIds.has(id)) bad(`duplicate subtask id "${id}" — ids must be unique.`)
  seenIds.add(id)
  const danger = raw.danger === true
  // Danger-zone routing, ENFORCED here rather than trusted to the caller: correctness-
  // critical work never runs on quick/builder (rubric routing rule). The plan is
  // well-formed, only mis-routed — so upgrade loudly instead of throwing.
  const tier = (danger && (raw.tier === 'quick' || raw.tier === 'builder')) ? 'deep' : raw.tier
  return {
    id,
    brief: raw.brief.trim(),
    tier,
    plannedTier: raw.tier,
    files: raw.files ? raw.files.map(f => f.trim()) : [],
    acceptance: raw.acceptance.trim(),
    danger,
    effort: raw.effort || null,
  }
})

const checks = (args.checks || []).map(c => c.trim())
const reviewMode = args.review || 'auto'
const wantsCrossReview = args.crossReview === true

for (const st of subtasks) {
  if (st.tier !== st.plannedTier) {
    log(`⚠ Danger-zone routing: "${st.id}" was planned as ${st.plannedTier} but danger=true — running it on ${st.tier} instead (correctness-critical work never goes to quick/builder).`)
  }
}

// escalations — every tier change this run made, for the returned report. Two kinds:
// a verdict-driven one-tier-up remediation, and the Fable→deep@max availability fallback.
const escalations = []

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
const TIER_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', fable: 'triage-fable-architect' }

function brief(st, extra) {
  return `${st.brief}\n\nRelevant files: ${st.files.join(', ') || '(discover)'}\n` +
    `Acceptance criteria: ${st.acceptance}` + (extra ? `\n\n${extra}` : '')
}

// agent() options for a subtask spawn. agentType is ALWAYS set — never rely on an
// inherited model, or the worker silently runs on the orchestrator's (expensive) tier
// instead of the planned one. `effort` is passed through only when the plan set one,
// so an unset effort keeps the agent definition's own default.
function agentOpts(st, agentType, ph, label) {
  const o = { phase: ph, agentType, label }
  if (st.effort) o.effort = st.effort
  return o
}

// Run one subtask, budget-gated (WORK floor = RESERVE) via spawn(): one budget
// decision per subtask, before it starts, plus a hard-ceiling catch around the
// agent() call(s). Fable is available and gated: announce it, and if the spawn
// hard-fails (agent() returns null — e.g. a stale model registry), fall back to
// triage-deep-reasoner at max effort per the rubric. Returns null if the subtask is
// budget-skipped, hits the ceiling, or even the fallback dies — so filter(Boolean)
// drops it (rather than leaking a `null` output).
async function runSubtask(st) {
  return spawn(RESERVE, `Execute:${st.tier}`, st.id, async () => {
    if (st.tier === 'fable') {
      log(`⚠ Escalating to Fable: ${st.id} — ${st.brief.slice(0, 80)}`)
      const out = await agent(brief(st), agentOpts(st, 'triage-fable-architect', 'Execute', `fable:${st.id}`))
      if (out) return { subtask: st, output: out, tier: 'fable', attempts: 1 }
      log(`⚠ Fable unavailable — using triage-deep-reasoner at max effort: ${st.id}`)
      escalations.push({ id: st.id, from: 'fable', to: 'deep', reason: 'fable spawn unavailable — deep-reasoner at max effort' })
      const fb = await agent(brief(st), { phase: 'Execute', agentType: 'triage-deep-reasoner', effort: 'max', label: `deep←fable:${st.id}` })
      return fb ? { subtask: st, output: fb, tier: 'deep', attempts: 1 } : null
    }
    const agentType = TIER_AGENT[st.tier] || 'triage-builder'
    const out = await agent(brief(st), agentOpts(st, agentType, 'Execute', `${st.tier}:${st.id}`))
    return out ? { subtask: st, output: out, tier: st.tier, attempts: 1 } : null
  })
}

const results = (await parallel(subtasks.map(st => () => runSubtask(st)))).filter(Boolean)
const dropped = subtasks.length - results.length
if (dropped > 0) log(`⚠ ${dropped} of ${subtasks.length} subtask(s) failed or were dropped — results are incomplete`)

// report() — the SINGLE place the compact return value is built. Only distillate
// leaves this workflow: worker prose stays out of the orchestrator's context (that
// is the whole point of delegating), so subtasks report status, not output.
function report(extra) {
  const ran = new Map(results.map(r => [r.subtask.id, r]))
  const skippedIds = new Set(skipped.filter(s => s.stage.startsWith('Execute') || s.stage.startsWith('Remediate')).map(s => s.desc))
  return Object.assign({
    subtasks: subtasks.map(st => {
      const r = ran.get(st.id)
      const status = r ? 'ok' : (skippedIds.has(st.id) ? 'skipped' : 'failed')
      return { id: st.id, tier: r ? r.tier : st.tier, status, attempts: r ? r.attempts : 0 }
    }),
    escalations,
    budget: budgetReport(),
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
const TIER_ORDER = ['quick', 'builder', 'deep', 'fable']
const nextTier = t => { const i = TIER_ORDER.indexOf(t); return i >= 0 && i < TIER_ORDER.length - 1 ? TIER_ORDER[i + 1] : t }

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

const { text: vtext, failed, isEscalate } = assess(verification)

// One bounded remediation round (rubric: retry once at the same tier on FIX / objective
// FAIL, escalate one tier on ESCALATE), then re-verify once — but TARGETED: attribute the
// failure to specific subtasks by matching their files against the verifier's failure text
// and re-run only those. Fail loud: if attribution implicates nobody, re-run ALL and say so.
let remediation = null
if (failed && results.length) {
  let targets = results.filter(r => matchedFiles(r, vtext).length > 0)
  const attributionFailed = targets.length === 0
  if (attributionFailed) {
    targets = results
    log('⚠ Remediation attribution matched no subtask files in the failure text — re-running ALL subtasks.')
  } else {
    log(`Remediation implicating ${targets.length} of ${results.length} subtask(s): ` +
      targets.map(r => `"${r.subtask.id}" (matched: ${matchedFiles(r, vtext).join(', ')})`).join('; '))
  }
  log(isEscalate ? 'Verification: ESCALATE — re-running the implicated subtask(s) one tier up with the feedback.'
                 : 'Verification did not pass — re-running the implicated subtask(s) with the feedback as context.')
  // Remediation redos are WORK → budget-gated on the RESERVE floor (same as Execute),
  // with a ceiling catch, via spawn(). A budget-skipped redo drops from redoResults
  // (filter(Boolean)); the original result stays in the merged re-verify set below.
  const redo = await parallel(targets.map(r => () => spawn(RESERVE, `Remediate:${r.tier}`, r.subtask.id, async () => {
    const tier = isEscalate ? nextTier(r.tier) : r.tier
    if (tier !== r.tier) escalations.push({ id: r.subtask.id, from: r.tier, to: tier, reason: 'reviewer returned ESCALATE' })
    const agentType = TIER_AGENT[tier] || 'triage-builder'
    const extra = `A prior attempt did not pass verification. Verifier feedback:\n${vtext.slice(0, 2000)}\nAddress it and complete the task.`
    const out = await agent(brief(r.subtask, extra), agentOpts(r.subtask, agentType, 'Verify', `redo:${r.subtask.id}`))
    return out ? { subtask: r.subtask, output: out, tier, attempts: r.attempts + 1 } : null
  })))
  const redoResults = redo.filter(Boolean)
  remediation = { implicated: targets.length, attributionFailed, escalated: isEscalate }
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
  verification = await verify(merged, true)
}

// --- Cross-vendor second opinion (optional; verification rule 6) -------------
// Runs ONLY when the plan asked for it. The orchestrator owns the data-boundary
// decision (some repos are on a user-maintained deny-list), so the brief states that
// it has been cleared — the tier refuses otherwise. Findings are SIGNAL: logged and
// returned for the orchestrator to weigh, and deliberately NOT fed into assess(),
// remediation, or the pass/fail verdict. The objective checks remain the gate.
let crossReview = null
if (wantsCrossReview) {
  const dangerNames = subtasks.filter(st => st.danger).map(st => st.id)
  const files = [...new Set(subtasks.flatMap(st => st.files))]
  const out = await spawn(0, 'CrossReview', 'cross-vendor second opinion', () => agent(
    `Cross-vendor review of the working-tree diff in this repo. The data boundary has been cleared by the orchestrator for this repository.\n` +
    `Run \`git diff\` (and \`git status\`) from the repo root${files.length ? ` — focus on: ${files.join(', ')}` : ''} and relay the external reviewer's findings verbatim.\n` +
    (dangerNames.length ? `Danger-flagged subtasks needing seam scrutiny: ${dangerNames.join(', ')}\n` : '') +
    `Findings are advisory signal for the orchestrator, not a merge verdict.`,
    { label: 'verify:cross-review', phase: 'Verify', agentType: 'triage-cross-reviewer' }
  ))
  crossReview = { ran: out != null, findings: out == null ? '' : String(out).slice(0, 4000) }
  log(out == null ? '⚠ Cross-review produced no findings (unavailable, refused, or budget-skipped) — advisory only, verdict unchanged.'
                  : 'Cross-review returned findings (advisory signal only — the objective checks remain the gate).')
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
