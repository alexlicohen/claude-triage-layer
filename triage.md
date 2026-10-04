# Model triage layer

Subagents: not for you; follow your brief and agent file.

You (the main loop) are the **top of this system**: plan, classify, brief, integrate, converse; the tiers below do large reads, builds, tests and reviews, returning only *values*. Protect weekly quota and this context (re-read every turn). On the deep tier's model, delegation buys isolation and parallelism, not capability: delegate large, independent or context-flooding work.

## Tiers: level × vendor × role

**Level** describes the task, never a model: `quick` (mechanical) · `builder` (cause known AND spec written) · `deep` (either missing, design, danger zone) · `top` (second architectural opinion, or last resort after deep@max; `fable` = top+claude). **Vendor**: `claude` (default) | `codex`. **Role**: implement · review · read. Model/effort per level × vendor is **data**: `~/.claude/scripts/triage-tiers.json` (repo `config/tiers.json`; `triage-tiers.sh` prints it; `GUESS` = unverified; README.md › Tiers are data).

| Agent | Role | Send it |
|---|---|---|
| `triage-quick-task` | implement, `quick` | Mechanical, unambiguous: renames, simple edits, lookups, boilerplate, formatting |
| `triage-builder` | implement, `builder` | Spec'd features, known-cause fixes, tests, routine refactors |
| `triage-deep-reasoner` | implement, `deep` | **Workhorse**: unfamiliar debugging, root cause, design, danger zone, hard fan-out. Effort: raise only for the hardest, via subtask `effort` (prose doesn't). |
| `triage-fable-architect` | implement, `top`+claude | Rare: second opinion, or correctness-critical last resort; rule 7. |
| `triage-reviewer` | review, read-only | Diff gate: by hand on quick/builder output lacking an objective check; triage-exec runs it per `review` (`auto`: no checks or a `danger` subtask; `always`; `never`) |
| `triage-external` | implement, via codex, **edits the repo** | Codex work chosen at plan time (`vendor: 'codex'`; `overflow: true` = codex builders) or a rule-10 challenger; never a failed run's fallback; disposable worktree. triage-exec attests planned codex briefs (choosing codex = the boundary decision); `REFUSED`/`UNAVAILABLE` → re-run on Claude, in `report.external.codex`. |
| `triage-cross-reviewer` | review/read via codex, read-only | Modes `review` · `read` (distil; typed JSON) · `verify` (web fact check) · `critique` (attack a decomposition) · `fuzz`. Brief must state the data boundary is cleared. |

An `agent()`/`Agent` call without model/agentType runs on `CLAUDE_CODE_SUBAGENT_MODEL` (= deep/claude), never Fable; keep it so.

Work reaches a non-Anthropic vendor only via the 2 external agents, and only `~/.claude/scripts/ext-run.sh` runs `codex`. Deny: `clip-creator` always; `.codex-deny` markers opt a tree out (challengers too). Threat model: accidents, not a hostile model. Docs (every README.md path here): `~/projects/claude-triage-layer/` (ext-run: `scripts/README.md` › `ext-run.sh`).

## How work flows

1. **Scout minimally, plan inline, then hand implementation to a workflow.** You classify; never spawn a classifier. Small edits: inline; several subtasks or a check-gated change: plan `subtasks` + `checks` (README.md › Workflow arguments), run `Workflow({name:'triage-exec', args})`; it runs, verifies, re-runs, escalates in the background. Multi-phase = workflows in sequence (understand → design → exec → review), reading each result between. Ultracode stays **off** (multiplies agents; user-enabled per prompt).
2. **Delegate reads that would flood this context** (corpora, many files, logs, broad searches) to a cheap worker returning a distillate; a brief's inputs or a module to plan: inline. Too big or dull for cheap Claude: `triage-cross-reviewer` `read` (1M context, no Claude quota; `--schema` shapes, never validates); fast-moving facts: `verify`.
3. **Route by predicted difficulty upfront — never ladder-climb.** Tie-breaker: the `builder`/`deep` definitions above.
4. **Parallelize by kind.** Breadth (pre-enumerated lookups): no cap, one cheap worker per item via `pipeline()`; wide ones need `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` (≤ 256, settings.json `env`). Judgment (deep, open-ended): under ~8; never shard a modest job. ~25k tokens per delegation: fewer, meatier briefs.
5. **Weekly quota.** Before a builder/deep plan: `bash ~/.claude/skills/usage-guard/usage_guard.sh --once`; at Weekly ≥ 80% ask once per session (`AskUserQuestion`) whether to shunt it to Codex (yes = plan `vendor: 'codex'`).
6. **Load-bearing briefs**: `~/.agents/AGENTS.md` (below: AGENTS.md) › Planning, delegation and review. No "double-check your work": deep tiers over-verify.
7. **Fable escalation — only as needed, never for two classes.** (a) Fable needs 30-day retention: the Fable-excluded list (adapter `~/.claude/CLAUDE.md`; project boundary rulings) stays deep. (b) Classifier-sensitive work (adapter list): no tier is classifier-free; deep by default; on a refusal rephrase or surface it, never re-send up. For (a)/(b) the plan sets `noFable: true` (triage-exec stops at deep@max, reports needs-user). Else escalate only from a failed/escalated deep@max (triage-exec runs it first): print `⚠ Escalating to Fable: <reason>` first; if the spawn hard-fails (stale registry: restart), fall back to `triage-deep-reasoner` at `max` and print `⚠ Fable unavailable — using triage-deep-reasoner at max effort`. Codex at any level tiers.json lists, chosen at plan time.
8. **Danger-zone → deep tier**, never builder (zones: AGENTS.md › Danger zones); `danger` work runs only on Claude Opus/Fable or codex `gpt-6-astra` at effort ≥ high; triage-exec enforces it, challengers too.
9. **Dedup-check** (AGENTS.md › Working style, Danger zones): brief "reuse/extend X, do not reimplement" + the ONE owning module.
10. **Build bake-offs are on by default (opt-out).** Every `triage-exec` plan carries `bakeoff: {config: <~/.claude/scripts/triage-tiers.sh --bakeoff-json>, rates: <~/.claude/scripts/parity-report.sh rates --json | jq .rates>, seed: "<session id>:<plan #>", repo: <abs repo root>, outDir: <scratchpad>/bakeoff-<session id>-<plan #>, weeklyPct: <usage_guard --once Weekly %>}` — `outDir` globally unique (ledger run ids derive from it); `weeklyPct` required (missing = sampling paused). A codex challenger sends its staged checkout to OpenAI. Omit it only on the user's "no bake-offs" (session or equivalent), or for PHI/clinical (no BAA), classifier-sensitive (7(b)) or work a project boundary keeps from external vendors. triage-exec samples, grades and applies; never hand-apply a bake-off patch. `withheld` (safety unconfirmed, not run; `report.incomplete`) → re-run without `bakeoff`. Then for each `report.ingest[i]`, write `.result` as JSON to `.file`, then run `.cmd`. Review bake-offs stay opt-in.

## Verification (orchestrator-owned — never a SubagentStop hook)

Basics, second-opinion criteria: AGENTS.md › Verification; › Planning, delegation and review.

1. Objective checks gate every returned change; triage-exec runs `checks:[…]`.
2. Failure → one retry, then escalate one tier (AGENTS.md). Failed external run (incl. `UNAVAILABLE`/null) → same level on Claude, then its ladder; never another vendor.
3. Non-trivial change, no objective check → `triage-reviewer` (PASS / FIX → same tier / ESCALATE → one tier up; triage-exec's cases: its table row). Never a check on your own work.
4. Core/shared modules: end to end (AGENTS.md); triage-exec runs checks AND reviewer on `danger` subtasks at any level.
5. Expensive fan-out: decomposition check first (AGENTS.md), ideally `triage-cross-reviewer` `critique` (other family, no Claude quota; finds hidden couplings).
6. **Cross-vendor second opinion**: `~/.claude/scripts/ext-run.sh <mode> --vendor codex --prompt-file …` or triage-exec `crossReview: true`, never the CLI. (a) explicit non-Claude model; (b) diff/corpus as a staged `--input` file, never inlined or with the real repo as cwd (nothing to write = read-only); (c) findings = signal, not verdict; (d) exit 0 with nothing = `UNAVAILABLE`, not "no findings". `CODEX_BOUNDARY_CLEARED=1` is the boundary attestation.
7. **Bake-off and parity workflows** (`triage-compare` build/review, `triage-parity`) never apply. After a compare: pick (or ask the user), apply, re-check, ingest (`scripts/README.md` › `parity-report.sh`). Parity: `ingest-parity`, then `report` proposes tier changes; the user approves each.

## Usage

`/workflows`: per-agent tokens per run; `/usage`: authoritative quota. Only when asked ("usage report"): run `~/.claude/scripts/triage-usage.sh`, print its line verbatim (`INCOMPLETE` too). Codex spend is vendor-side (`ext-run: N tokens`, stderr); its wrappers cost only Haiku.

**Session end** (this layer's part of AGENTS.md › Session end): run each pending `report.ingest` or hand off run id + result file (runs: `~/.claude/projects/<slug>/<session>/workflows/`); then commit + push the dot-agents ledger; `make sync` after repo changes; name open PRs and CI state.

Kill switch: `touch ~/.claude/triage.disabled` (next startup, /clear or compaction; `rm` re-enables; if CLAUDE.md still has `@triage.md`, remove that line instead). Full uninstall: `README.md` › Disable / uninstall.
