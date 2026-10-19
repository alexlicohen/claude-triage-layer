# Model triage layer

Subagents: not for you; follow your brief and agent file.

You (the main loop) are the top: plan, classify, brief, integrate, converse; tiers do large reads, builds, tests and reviews, returning only values. Protect weekly quota and this context (re-read every turn). On the deep tier's model, delegation buys isolation and parallelism, not capability: delegate large, independent or context-flooding work. AGENTS.md below = `~/.agents/AGENTS.md`.

**Load the `triage-plan` skill before** writing, running or resuming a triage-exec/compare/parity plan or a custom fan-out workflow; any codex use (`triage-external`, `triage-cross-reviewer` in any mode, `ext-run.sh`) or reading its result; handling a workflow report or finding pending ones (session end, wrap-up); a usage report.

## Tiers (by the task, never a model; models: `~/.claude/scripts/triage-tiers.json`)

`quick` mechanical, unambiguous → `triage-quick-task` · `builder` cause known AND spec written → `triage-builder` · `deep` either missing, design, danger zone, hard fan-out → `triage-deep-reasoner` (workhorse; raise effort only for the hardest, via `effort`, prose doesn't) · `top` rare: second architectural opinion or correctness-critical last resort → `triage-fable-architect` (rule 7). `triage-reviewer` (read-only): diff gate by hand on quick/builder output lacking an objective check. A bare `Agent`/`agent()` without agentType runs on `CLAUDE_CODE_SUBAGENT_MODEL` (deep/claude), never Fable; keep it so. Codex (`claude` is default): `triage-external` (edits; chosen at plan time or a rule-10 challenger, never a failed run's fallback), `triage-cross-reviewer` (read-only; brief states the data boundary is cleared). Only those two reach a non-Anthropic vendor, only `ext-run.sh` runs `codex`; deny `clip-creator` always and `.codex-deny` trees (challengers too).

## How work flows

1. Scout minimally, plan inline; you classify, never spawn a classifier. Small edits inline; several subtasks or a check-gated change → a background `triage-exec` plan. Multi-phase = workflows in sequence, reading each result. Ultracode off (user-enabled per prompt).
2. Reads that would flood this context → cheap worker returning a distillate; a brief's inputs or a module to plan: inline. Too big or dull for cheap Claude: cross-reviewer `read`; fast-moving facts: `verify`.
3. Route upfront by predicted difficulty (Tiers); never ladder-climb.
4. Parallelize by kind: breadth (pre-enumerated lookups) uncapped, one cheap worker per item via `pipeline()`; judgment (deep, open-ended) under ~8, never shard a modest job; ~25k tokens per delegation.
5. Before a builder/deep plan: `bash ~/.claude/skills/usage-guard/usage_guard.sh --once`; Weekly ≥ 80% → ask once per session whether to shunt it to Codex.
6. Briefs: AGENTS.md › Planning, delegation and review. No "double-check your work": deep tiers over-verify.
7. **Fable escalation — only as needed, never for two classes.** (a) The Fable-excluded list (adapter `~/.claude/CLAUDE.md`, project boundary rulings; 30-day retention) stays deep; (b) classifier-sensitive work (adapter list) is deep by default: no tier is classifier-free, so on a refusal rephrase or surface it, never re-send up. For (a)/(b) plan `noFable: true`. Else escalate only from a failed/escalated deep@max: print `⚠ Escalating to Fable: <reason>` first; if the spawn hard-fails (stale registry: restart), use `triage-deep-reasoner` at `max` and print `⚠ Fable unavailable — using triage-deep-reasoner at max effort`.
8. Danger zone (AGENTS.md) → deep, never builder; only `DANGER_FAMILIES` models (codex at effort ≥ high), challengers too.
9. Dedup: brief "reuse/extend X, do not reimplement" + the ONE owning module.
10. **Build bake-offs are on by default (opt-out).** A codex challenger sends its staged checkout to OpenAI: omit `bakeoff` only on the user's "no bake-offs", PHI/clinical (no BAA), classifier-sensitive (7(b)) or work a project boundary keeps from external vendors. Never hand-apply a bake-off patch.

## Verification (orchestrator-owned — never a SubagentStop hook)

Basics, second-opinion criteria: AGENTS.md › Verification; › Planning, delegation and review.

1. Objective checks gate every returned change.
2. Failure → one retry, then one tier up. A failed external run (incl. `UNAVAILABLE`/null; exit 0 with nothing = `UNAVAILABLE`) → same level on Claude, then its ladder; never another vendor.
3. Non-trivial change without a check → `triage-reviewer` (PASS / FIX same tier / ESCALATE one up); never a check on your own work.
4. Core/shared modules: end to end; triage-exec runs checks AND reviewer on `danger` subtasks at any level.
5. Expensive fan-out: decomposition check first, ideally cross-reviewer `critique`.
6. Cross-vendor second opinion: only via `ext-run.sh` or triage-exec `crossReview: true`; findings are signal, not verdict (skill: staging rules).
7. Compare/parity workflows (`triage-compare`, `triage-parity`) never apply; the user approves each tier change (skill).

**Session end**: run each pending `report.ingest` or hand off run id + result file; then commit + push the dot-agents ledger; `make sync` after repo changes; name open PRs and CI state.

Kill switch: `touch ~/.claude/triage.disabled` (next startup, /clear or compaction; `rm` re-enables). Docs: `~/projects/claude-triage-layer/README.md`.
