export const meta = {
  name: 'triage-run',
  description: 'Cost-tiered triage: classify a task, delegate to the right tier agent(s), then verify',
  whenToUse: 'Run a task through the triage layer as a repeatable command: /triage-run <task>. Codifies triage.md (classify by difficulty → delegate to quick/builder/deep/fable → verify).',
  phases: [
    { title: 'Classify' },
    { title: 'Execute' },
    { title: 'Verify' },
  ],
}

const task = (typeof args === 'string' && args.trim()) ? args.trim()
  : (args && typeof args.task === 'string') ? args.task.trim()
  : null
if (!task) {
  log('Usage: /triage-run <task description>  (or pass args.task)')
  return { error: 'no task provided' }
}

phase('Classify')
const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    objective_check: { type: ['string', 'null'], description: 'shell command for the project test/lint, or null if none discoverable' },
    subtasks: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          desc: { type: 'string' },
          tier: { type: 'string', enum: ['quick', 'builder', 'deep', 'fable'] },
          files: { type: 'array', items: { type: 'string' } },
          acceptance: { type: 'string' },
          danger: { type: 'boolean', description: 'correctness-critical work: a shared primitive/dispatcher many callers depend on, ≥3 modules touched at once, or format-sensitive output a subtle wrong layer silently corrupts' },
        },
        required: ['desc', 'tier', 'files', 'acceptance', 'danger'],
      },
    },
  },
  required: ['objective_check', 'subtasks'],
}
const plan = await agent(
  `Classify and decompose this task for a cost-tiered delegation system, then return the plan.\n` +
  `Route each INDEPENDENT subtask by predicted difficulty — never ladder-climb (a hard task goes straight to deep/fable):\n` +
  `  quick   = mechanical/low-ambiguity (renames, simple edits, lookups, boilerplate)\n` +
  `  builder = well-specified implementation (spec'd feature, known-cause bugfix, tests, routine refactor)\n` +
  `  deep    = unfamiliar debugging, root-cause analysis, design exploration\n` +
  `  fable   = architecture, or work the Opus tier would escalate; correctness >> cost\n` +
  `Set danger=true for any correctness-critical subtask — a shared primitive/dispatcher many callers depend on, ≥3 modules touched at once, or format-sensitive output a subtle wrong layer silently corrupts; such work routes to deep or fable (never builder). Otherwise danger=false.\n` +
  `Give each subtask concrete files and an acceptance criterion. Discover the project's objective check (test/lint) command if you can.\n\n` +
  `TASK: ${task}`,
  { phase: 'Classify', schema: PLAN_SCHEMA }
)

// Guard: a null/malformed classification (older builds without reliable structured
// output, or a terminal spawn failure) must not crash on plan.subtasks.map below.
if (!plan || !Array.isArray(plan.subtasks) || plan.subtasks.length === 0) {
  log('Classification failed or returned no subtasks — aborting.')
  return { error: 'classify failed', plan: plan ?? null }
}

// ─── Budget awareness ───────────────────────────────────────────────────────
// The DSL exposes `budget = {total, spent(), remaining()}`. total === null means
// the user set NO token target: remaining() is Infinity and behavior must be
// EXACTLY the legacy control flow. Every budget branch below is guarded on
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
// — no check, no catch — so legacy throw propagation (e.g. an unscripted test call)
// is preserved and behavior is unchanged.
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
  return `${st.desc}\n\nRelevant files: ${(st.files || []).join(', ') || '(discover)'}\n` +
    `Acceptance criteria: ${st.acceptance}` + (extra ? `\n\n${extra}` : '')
}

// Run one subtask, budget-gated (WORK floor = RESERVE) via spawn(): one budget
// decision per subtask, before it starts, plus a hard-ceiling catch around the
// agent() call(s). Fable is available and gated: announce it, and if the spawn
// hard-fails (agent() returns null — e.g. a stale model registry), fall back to
// triage-deep-reasoner at max effort per the rubric. Returns null if the subtask is
// budget-skipped, hits the ceiling, or even the fallback dies — so filter(Boolean)
// drops it (rather than leaking a `null` output).
async function runSubtask(st) {
  return spawn(RESERVE, `Execute:${st.tier}`, st.desc, async () => {
    if (st.tier === 'fable') {
      log(`⚠ Escalating to Fable: ${st.desc}`)
      const out = await agent(brief(st), { phase: 'Execute', agentType: 'triage-fable-architect', label: `fable:${st.desc.slice(0, 24)}` })
      if (out) return { subtask: st, output: out }
      log(`⚠ Fable unavailable — using triage-deep-reasoner at max effort: ${st.desc}`)
      const fb = await agent(brief(st), { phase: 'Execute', agentType: 'triage-deep-reasoner', effort: 'max', label: `deep←fable:${st.desc.slice(0, 24)}` })
      return fb ? { subtask: st, output: fb } : null
    }
    const agentType = TIER_AGENT[st.tier] || 'triage-builder'
    const out = await agent(brief(st), { phase: 'Execute', agentType, label: `${st.tier}:${st.desc.slice(0, 24)}` })
    return out ? { subtask: st, output: out } : null
  })
}

const results = (await parallel(plan.subtasks.map(st => () => runSubtask(st)))).filter(Boolean)
const dropped = plan.subtasks.length - results.length
if (dropped > 0) log(`⚠ ${dropped} of ${plan.subtasks.length} subtask(s) failed or were dropped — results are incomplete`)

// Fail-loud (no silent empty success): if the budget refused EVERY subtask before it
// could spawn, there is nothing to verify — return an explicit error, not a hollow
// "success" with empty results. (A partial success — at least one subtask ran — falls
// through and gets verified normally.)
if (budgeted && results.length === 0 &&
    skipped.filter(s => s.stage.startsWith('Execute')).length === plan.subtasks.length) {
  log('⚠ Budget: every subtask was skipped before it could spawn — no work performed; aborting before verification.')
  return {
    task, plan, results: [], remediation: null, verification: null,
    error: 'budget exhausted: all subtasks skipped before execution',
    budget: budgetReport(),
  }
}

phase('Verify')
const TIER_ORDER = ['quick', 'builder', 'deep', 'fable']
const nextTier = t => { const i = TIER_ORDER.indexOf(t); return i >= 0 && i < TIER_ORDER.length - 1 ? TIER_ORDER[i + 1] : t }

async function verify(items, remediated) {
  const dangerItems = items.filter(r => r.subtask && r.subtask.danger)
  const hasDanger = dangerItems.length > 0
  const files = [...new Set(items.flatMap(r => r.subtask.files || []))]

  // Objective check: quick-task runs the project's test/lint and reports PASS/FAIL.
  const runObjective = () => agent(
    `Run this command from the repo root and report the result. Quote the last ~40 lines of output verbatim, then state PASS or FAIL on its own line:\n${plan.objective_check}`,
    { label: remediated ? 'verify:recheck' : 'verify:objective-check', phase: 'Verify', agentType: 'triage-quick-task' }
  )

  // Reviewer: reads the real git diff and returns PASS / FIX / ESCALATE. When danger
  // subtasks are present it names them and demands extra seam scrutiny (rubric verification
  // rule 4: green unit tests can hide a broken seam).
  const runReview = () => {
    const dangerNote = hasDanger
      ? `\n\nDANGER-FLAGGED subtasks (correctness-critical — a shared primitive/dispatcher many callers depend on, ≥3 modules touched at once, or format-sensitive output a subtle wrong layer silently corrupts). Give these EXTRA seam scrutiny: verify the dependent workflow end-to-end, not merely that unit tests pass:\n` +
        dangerItems.map(r => `  - ${r.subtask.desc}`).join('\n')
      : ''
    return agent(
      `You are the quality gate. Inspect the ACTUAL changes — do not just trust the worker summaries below.\n` +
      `Run \`git status\` and \`git diff\` from the repo root${files.length ? ` (focus on: ${files.join(', ')})` : ''}, then reply with ` +
      `PASS, or 'FIX: <what>', or 'ESCALATE: <why>' on the first line.${dangerNote}\n\n` +
      `Worker summaries for context:\n` +
      items.map(r => `## ${r.subtask.desc}\n${String(r.output).slice(0, 4000)}`).join('\n\n').slice(0, 14000),
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
      if (!budgeted) return await mk()   // legacy path: throws propagate, no catch
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

  if (plan.objective_check) {
    // Seam enforcement (rubric verification rule 4): a danger subtask means a green
    // objective check can still hide a broken seam, so run BOTH gates; the combined
    // verdict fails if EITHER fails (see assess()). Non-danger plans keep the either/or.
    if (hasDanger) {
      const [checkOut, review] = await parallel([
        () => runGate(runObjective, 'objective'),
        () => runGate(runReview, 'reviewer'),
      ])
      return { type: 'seam', command: plan.objective_check, result: checkOut, verdict: review, seam: true, remediated: !!remediated }
    }
    const checkOut = await runGate(runObjective, 'objective')
    return { type: 'objective', command: plan.objective_check, result: checkOut, remediated: !!remediated }
  }
  const review = await runGate(runReview, 'reviewer')
  return { type: 'review', verdict: review, remediated: !!remediated }
}

let verification = await verify(results, false)

// --- Verdict parsing: SINGLE OWNER. Every FAIL/FIX/ESCALATE interpretation lives here. ---
const objFailed = t => /(^|\n)\s*FAIL\b/i.test(String(t || ''))
const reviewFailed = t => /^\s*(FIX|ESCALATE)\b/i.test(String(t || '').trimStart())
const reviewEscalate = t => /^\s*ESCALATE\b/i.test(String(t || '').trimStart())

// Aggregate a verification object into { text, failed, isEscalate, incomplete }.
//   text       = feedback fed to remediation AND matched against for failure attribution.
//   failed     = a 'seam' result fails if EITHER gate fails (objective FAIL or reviewer FIX/ESCALATE).
//   isEscalate = only the reviewer escalates; an objective FAIL is a same-tier retry.
//   incomplete = a gate died (null even after its retry). Tri-state, per the rubric's
//                fail-loud rule: INCOMPLETE is not a pass and not a work-failure — there
//                is no feedback to remediate against, so it is reported loudly instead.
function assess(v) {
  if (v.type === 'objective') {
    if (v.result == null) return { text: '', failed: false, isEscalate: false, incomplete: true }
    const t = String(v.result)
    return { text: t, failed: objFailed(t), isEscalate: reviewEscalate(t), incomplete: false }
  }
  if (v.type === 'review') {
    if (v.verdict == null) return { text: '', failed: false, isEscalate: false, incomplete: true }
    const t = String(v.verdict)
    return { text: t, failed: reviewFailed(t), isEscalate: reviewEscalate(t), incomplete: false }
  }
  // 'seam': both gates ran (danger subtask + objective_check). A dead gate marks the
  // verification INCOMPLETE; a REAL failure from whichever gate did run still fails
  // (and remediates on its feedback). Never a silent pass.
  const objText = String(v.result ?? '')
  const revText = String(v.verdict ?? '')
  return {
    text: `Objective check:\n${objText}\n\nReviewer:\n${revText}`,
    failed: objFailed(objText) || reviewFailed(revText),
    isEscalate: reviewEscalate(revText),
    incomplete: v.result == null || v.verdict == null,
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
      targets.map(r => `"${r.subtask.desc.slice(0, 40)}" (matched: ${matchedFiles(r, vtext).join(', ')})`).join('; '))
  }
  log(isEscalate ? 'Verification: ESCALATE — re-running the implicated subtask(s) one tier up with the feedback.'
                 : 'Verification did not pass — re-running the implicated subtask(s) with the feedback as context.')
  // Remediation redos are WORK → budget-gated on the RESERVE floor (same as Execute),
  // with a ceiling catch, via spawn(). A budget-skipped redo drops from redoResults
  // (filter(Boolean)); the original result stays in the merged re-verify set below.
  const redo = await parallel(targets.map(r => () => spawn(RESERVE, `Remediate:${r.subtask.tier}`, r.subtask.desc, async () => {
    const tier = isEscalate ? nextTier(r.subtask.tier) : r.subtask.tier
    const agentType = TIER_AGENT[tier] || 'triage-builder'
    const extra = `A prior attempt did not pass verification. Verifier feedback:\n${vtext.slice(0, 2000)}\nAddress it and complete the task.`
    const out = await agent(brief(r.subtask, extra), { phase: 'Verify', agentType, label: `redo:${r.subtask.desc.slice(0, 20)}` })
    return out ? { subtask: r.subtask, output: out, tier } : null
  })))
  const redoResults = redo.filter(Boolean)
  remediation = {
    implicated: targets.map(r => ({ desc: r.subtask.desc, matched: matchedFiles(r, vtext) })),
    attributionFailed,
    escalated: isEscalate,
    results: redoResults,
  }
  // Re-verify the WHOLE task, not just the re-run subset: merge latest output per subtask
  // (remediated where re-run, original otherwise) so danger flags and file focus reflect
  // ALL executed work (seam rule 4).
  const bySubtask = new Map(results.map(r => [r.subtask, r]))
  for (const r of redoResults) bySubtask.set(r.subtask, r)
  verification = await verify([...bySubtask.values()], true)
}

// Tri-state, fail-loud: whatever verification object we're returning (initial or
// re-verified), a dead gate makes it INCOMPLETE — flagged on the result and logged,
// never passed off as a confirmed green.
if (assess(verification).incomplete) {
  log('⚠ VERIFICATION INCOMPLETE — a gate could not run even after a retry; this result is NOT a confirmed pass.')
  verification.incomplete = true
}

return { task, plan, results, remediation, verification, budget: budgetReport() }
