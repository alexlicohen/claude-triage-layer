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
        },
        required: ['desc', 'tier', 'files', 'acceptance'],
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

phase('Execute')
const TIER_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', fable: 'triage-fable-architect' }

function brief(st, extra) {
  return `${st.desc}\n\nRelevant files: ${(st.files || []).join(', ') || '(discover)'}\n` +
    `Acceptance criteria: ${st.acceptance}` + (extra ? `\n\n${extra}` : '')
}

// Run one subtask. Fable is available and gated: announce it, and if the spawn
// hard-fails (agent() returns null — e.g. a stale model registry), fall back to
// triage-deep-reasoner at max effort per the rubric. Returns null if even the
// fallback dies, so filter(Boolean) drops it (rather than leaking a `null` output).
async function runSubtask(st) {
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
}

const results = (await parallel(plan.subtasks.map(st => () => runSubtask(st)))).filter(Boolean)
const dropped = plan.subtasks.length - results.length
if (dropped > 0) log(`⚠ ${dropped} of ${plan.subtasks.length} subtask(s) failed or were dropped — results are incomplete`)

phase('Verify')
const TIER_ORDER = ['quick', 'builder', 'deep', 'fable']
const nextTier = t => { const i = TIER_ORDER.indexOf(t); return i >= 0 && i < TIER_ORDER.length - 1 ? TIER_ORDER[i + 1] : t }

async function verify(items, remediated) {
  if (plan.objective_check) {
    const checkOut = await agent(
      `Run this command from the repo root and report the result. Quote the last ~40 lines of output verbatim, then state PASS or FAIL on its own line:\n${plan.objective_check}`,
      { label: remediated ? 'verify:recheck' : 'verify:objective-check', phase: 'Verify', agentType: 'triage-quick-task' }
    )
    return { type: 'objective', command: plan.objective_check, result: checkOut, remediated: !!remediated }
  }
  const files = [...new Set(items.flatMap(r => r.subtask.files || []))]
  const review = await agent(
    `You are the quality gate. Inspect the ACTUAL changes — do not just trust the worker summaries below.\n` +
    `Run \`git status\` and \`git diff\` from the repo root${files.length ? ` (focus on: ${files.join(', ')})` : ''}, then reply with ` +
    `PASS, or 'FIX: <what>', or 'ESCALATE: <why>' on the first line.\n\n` +
    `Worker summaries for context:\n` +
    items.map(r => `## ${r.subtask.desc}\n${String(r.output).slice(0, 4000)}`).join('\n\n').slice(0, 14000),
    { label: remediated ? 'verify:re-review' : 'verify:reviewer', phase: 'Verify', agentType: 'triage-reviewer' }
  )
  return { type: 'review', verdict: review, remediated: !!remediated }
}

let verification = await verify(results, false)

// Act on the verdict — one bounded remediation round (rubric: retry once at the same
// tier on FIX / objective FAIL, escalate one tier on ESCALATE), then re-verify once.
function verdictOf(v) { return v.type === 'review' ? String(v.verdict || '') : String(v.result || '') }
const vtext = verdictOf(verification)
const isEscalate = /^\s*ESCALATE\b/i.test(vtext.trimStart())
const failed = verification.type === 'review'
  ? /^\s*(FIX|ESCALATE)\b/i.test(vtext.trimStart())
  : /(^|\n)\s*FAIL\b/i.test(vtext)

let remediation = null
if (failed && results.length) {
  log(isEscalate ? 'Verification: ESCALATE — re-running one tier up with the feedback.'
                 : 'Verification did not pass — re-running with the feedback as context.')
  const redo = await parallel(results.map(r => () => {
    const tier = isEscalate ? nextTier(r.subtask.tier) : r.subtask.tier
    const agentType = TIER_AGENT[tier] || 'triage-builder'
    const extra = `A prior attempt did not pass verification. Verifier feedback:\n${vtext.slice(0, 2000)}\nAddress it and complete the task.`
    return agent(brief(r.subtask, extra), { phase: 'Verify', agentType, label: `redo:${r.subtask.desc.slice(0, 20)}` })
      .then(out => out ? { subtask: r.subtask, output: out, tier } : null)
  }))
  remediation = redo.filter(Boolean)
  verification = await verify(remediation.length ? remediation : results, true)
}

return { task, plan, results, remediation, verification }
