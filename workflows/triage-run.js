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

phase('Execute')
const TIER_AGENT = { quick: 'triage-quick-task', builder: 'triage-builder', deep: 'triage-deep-reasoner', fable: 'triage-fable-architect' }
// Fable is disabled org-wide (Anthropic-side) as of 2026-06-29. While unavailable,
// remap the `fable` tier to triage-deep-reasoner at MAX effort (triage.md routing
// rule: Fable tier unavailable → deep-reasoner at max). Flip to true when restored.
const FABLE_AVAILABLE = false
const results = await parallel(plan.subtasks.map(st => () => {
  let agentType = TIER_AGENT[st.tier] || 'triage-builder'
  const opts = { phase: 'Execute' }
  if (st.tier === 'fable') {
    if (FABLE_AVAILABLE) {
      log(`⚠ Escalating to Fable: ${st.desc}`)
    } else {
      agentType = 'triage-deep-reasoner'
      opts.effort = 'max'
      log(`⚠ Fable unavailable — using triage-deep-reasoner at max effort: ${st.desc}`)
    }
  }
  opts.agentType = agentType
  opts.label = `${st.tier === 'fable' && !FABLE_AVAILABLE ? 'deep←fable' : st.tier}:${st.desc.slice(0, 24)}`
  return agent(
    `${st.desc}\n\nRelevant files: ${(st.files || []).join(', ') || '(discover)'}\nAcceptance criteria: ${st.acceptance}`,
    opts
  ).then(out => ({ subtask: st, output: out }))
})).then(r => r.filter(Boolean))

phase('Verify')
let verification
if (plan.objective_check) {
  const checkOut = await agent(
    `Run this command from the repo root and report the result. Quote the last ~40 lines of output verbatim, then state PASS or FAIL on its own line:\n${plan.objective_check}`,
    { label: 'verify:objective-check', phase: 'Verify', agentType: 'triage-quick-task' }
  )
  verification = { type: 'objective', command: plan.objective_check, result: checkOut }
} else {
  const review = await agent(
    `Review these changes for correctness and quality. Reply with PASS, or 'FIX: <what>' , or 'ESCALATE: <why>'.\n\n` +
    results.map(r => `## ${r.subtask.desc}\n${String(r.output).slice(0, 4000)}`).join('\n\n').slice(0, 14000),
    { label: 'verify:reviewer', phase: 'Verify', agentType: 'triage-reviewer' }
  )
  verification = { type: 'review', verdict: review }
}

return { task, plan, results, verification }
