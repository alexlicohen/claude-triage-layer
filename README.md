# Claude Code Model Triage Layer

[![CI](https://github.com/alexlicohen/claude-triage-layer/actions/workflows/ci.yml/badge.svg)](https://github.com/alexlicohen/claude-triage-layer/actions/workflows/ci.yml)

A drop-in config layer for [Claude Code](https://code.claude.com) that routes every task to the **cheapest adequate Claude model** (Haiku → Sonnet → Opus → Fable 5), escalates automatically when a cheaper tier's output fails verification, and reports per-tier usage — **all billed to your Claude Pro/Max subscription**, not the pay-per-token API.

No app, no server, no API keys. It's six subagent definitions, one instructions file, a statusline script, a `triage-exec` workflow, and three settings keys.

**The split:** your session model — whatever frontier model you point at it — does the part only it can do (classify, decompose, write briefs, integrate). It writes the plan *inline*, then hands it to the `triage-exec` workflow, which spawns the tier agents, runs your tests, re-runs only the subtasks a failure implicates, and escalates one tier up when the reviewer says so. What comes back is a distillate — per-subtask status, per-check pass/fail, the review verdict — so worker prose never lands in the expensive context.

## Why this exists

Top-tier models (Fable 5) are excellent but burn subscription quota ~3–5× faster than Sonnet. Two facts shape the design:

1. **A standalone router (Agent SDK / API) cannot use subscription auth** — Anthropic's policy requires API keys for SDK-built agents. The only subscription-billed implementation is configuration *inside* Claude Code.
2. **Claude Code has no automatic prompt router** — nothing can swap the main-loop model per prompt. So triage is done by the orchestrating model itself, following a rubric, delegating to subagents pinned to cheaper/stronger models.

The economics aren't speculative: Anthropic's own [coordinator-pattern cookbook](https://github.com/anthropics/claude-cookbooks/blob/main/managed_agents/CMA_plan_big_execute_small.ipynb) measures the same split on the Managed Agents API — a frontier model plans and synthesizes while cheap workers absorb the token-heavy reading — and finds it **~2.5× cheaper and ~3× faster** than a rigor-matched solo frontier agent, with 84–98% of input tokens billed at the worker rate. This layer is the Claude Code / subscription-billed implementation of the same delegation economics (plus the verification, escalation, and per-tier accounting the cookbook leaves to you); its context-isolation and brief-granularity lessons are codified as flow rules 2 and 4, and verification rule 5, in `triage.md`.

## How it works

```
You ──► Main loop: your session model (your choice — the installer never sets it)
              │     ← triage rubric (triage.md): classify + decompose INLINE
              │
              └──► Workflow triage-exec  ← the plan: {subtasks, checks, review, crossReview}
                     │  executes, verifies, remediates, escalates
                     ├──► triage-quick-task      Haiku  · low    renames, lookups, boilerplate
                     ├──► triage-builder         Sonnet · medium well-specified features/fixes
                     ├──► triage-deep-reasoner   Opus   · xhigh  hard debugging, design, fan-out
                     ├──► triage-fable-architect Fable  · xhigh  hardest problems (with ⚠ notice)
                     ├──► triage-reviewer        Opus   · high   read-only quality gate
                     └──► triage-cross-reviewer  → external CLI  cross-vendor second opinion
                     ▼
              returns a distillate: per-subtask status · per-check pass/fail · verdict · escalations
```

- **Routing**: the orchestrator classifies each task by difficulty *before* delegating (no wasteful "try cheap first" ladder-climbing) and parallelizes independent subtasks. Classification stays in the main loop — it is the best classifier in the system and already holds the context, so no spawn is spent re-deriving a plan.
- **Verification**: after a worker returns code, the orchestrator runs the project's own tests/lint/build before accepting. No objective check available? The read-only Opus reviewer reads the diff — far cheaper than redoing the work.
- **Escalation**: workers reply `ESCALATE:` when out of their depth; failed verification escalates one tier up with the failed attempt as context. Escalation to Fable is automatic but always announced: `⚠ Escalating to Fable: <reason>`.
- **Seam checks & targeted remediation**: `triage-exec` runs both the test/lint gates and a reviewer on correctness-critical (`danger`) subtasks, and on failure re-runs only the subtasks implicated by the failure output — re-running everything only when it can't attribute the failure. A `danger` subtask planned onto a cheap tier is upgraded to the deep tier, loudly.
- **Visibility**: a one-line per-tier token tally on request (say `usage report`) — computed deterministically from the session's on-disk subagent transcripts by `scripts/triage-usage.sh`, not recalled from model memory — and an optional statusline (copied, not wired — see Install) showing `model · ctx N%` that turns red at ≥60% context, plus live `ccusage` cost/burn when `ccusage` is installed.
- **Conveniences**: each implementation tier (not the read-only reviewer) carries `memory: project` (per-codebase memory across sessions); `triage-exec` runs delegate→verify→remediate→escalate as one workflow call; and the installer adds harness-level `permissions` rules — an `ask` confirm-gate before any Fable spawn, plus an allowlist for the cheaper worker spawns so fan-out doesn't prompt. See `triage.md`.

## Requirements

- Claude Code with a **Pro or Max subscription** login (this is what makes it subscription-billed)
- `jq` (for the installer and statusline): `brew install jq`
- **Your orchestrator model is your choice** — the installer no longer sets `model` or `effortLevel`. Pick with `/model`: a frontier model plans best, and the tiers absorb the volume either way. On a Pro plan, note that 1M-context Opus variants bill extra usage credits.
- **Version**: built and verified against Claude Code **2.1.195**. The harness permission gate needs **≥ 2.1.186** and per-agent memory needs **≥ 2.1.172**; on older builds the permission rules simply no-op and per-agent memory is ignored. `install.sh` checks `claude --version` itself and prints a specific warning per shortfall (or "could not verify" if `claude` is missing/unparseable) — warn-only, it never blocks the install.

## Install

```bash
git clone <this-repo> && cd claude-triage-layer
./install.sh
```

Then **start a new Claude Code session** (config loads at startup). The installer:

- copies the 6 agents to `~/.claude/agents/`, the rubric to `~/.claude/triage.md`, the statusline script, the usage/stats scripts, and the `triage-exec` workflow (`~/.claude/workflows/`)
- appends one line — `@triage.md` — to your global `~/.claude/CLAUDE.md` (append-only; never overwrites)
- adds the Fable confirm-gate / worker-allowlist `permissions` rules, and sets two keys **only if they are unset**: `env.CLAUDE_CODE_SUBAGENT_MODEL` (so an un-pinned subagent spawn runs on Opus, not on your — possibly much pricier — session model) and `subagentPromptCacheTtl: "1h"`
- removes a superseded `~/.claude/workflows/triage-run.js` from an older install, but only when its bytes match a version this repo shipped; a copy you edited is left alone with a note
- warns if `ANTHROPIC_API_KEY` is set (see Caveats)

**What it does NOT touch**: `model`, `effortLevel`, and `statusLine` are never written, so there is no snapshot to restore and nothing for uninstall to revert. `statusline.sh` is copied but not wired — point `statusLine` at it yourself if you want it (the installer prints the exact JSON).

Two flags, composable: `./install.sh --dry-run` prints the full mutation plan (every file's create/overwrite/unchanged status, the CLAUDE.md append, the settings keys and permission rules) and writes nothing; `./install.sh --files-only` copies/chmods just the installed files — agents, `statusline.sh`, the `triage-exec` workflow, `scripts/triage-usage.sh`, `triage.md` — skipping anything listed in `.driftignore` (e.g. a hand-forked `triage.md`) instead of clobbering it, and leaves `CLAUDE.md`, `settings.json`, and permissions untouched. This is the primitive behind `make sync` for re-pulling repo file updates without re-running the settings merge.

<details>
<summary>Manual install (no script)</summary>

1. `cp agents/triage-*.md ~/.claude/agents/`
2. `cp triage.md ~/.claude/ && cp statusline.sh ~/.claude/ && chmod +x ~/.claude/statusline.sh`
3. `mkdir -p ~/.claude/workflows && cp workflows/triage-exec.js ~/.claude/workflows/` (needed for `triage-exec`)
4. Append a line containing exactly `@triage.md` to `~/.claude/CLAUDE.md` — make sure the file ends in a newline first, or the line fuses onto the last one
5. In `~/.claude/settings.json`:
   ```json
   {
     "env": { "CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5" },
     "subagentPromptCacheTtl": "1h"
   }
   ```
6. Optional: wire the statusline, using your real home path (tilde is not expanded inside JSON) — `"statusLine": { "type": "command", "command": "/Users/<you>/.claude/statusline.sh" }`
7. Optional (harness ≥ 2.1.186): to enforce the rubric at the permission layer, add `permissions` rules — an `ask` on `Agent(triage-fable-architect)` and an `allow` for the five cheaper `Agent(triage-*)` spawns. `install.sh` does this for you.
</details>

## Using it

**Nothing to invoke — it's always on in new sessions.** Ask for what you want; the orchestrator decides which tier does it. Useful controls:

| You want | Do |
|---|---|
| Override its routing | "send this to triage-deep-reasoner" / "just use triage-quick-task" |
| A full top-tier session | `/model fable` — the rubric still delegates cheap work down |
| Run a plan you wrote yourself | `Workflow({name:'triage-exec', args:{subtasks:[…], checks:['make test']}})` |
| A cheap session | `/model sonnet` |
| One-turn deep reasoning | include `ultrathink` in your prompt |
| Spend tally | say `usage report` (also printed after each task) |
| Subscription quota | `/usage` (the tally covers delegated tokens only) |

**Verify it's working**: in a fresh session, ask for a trivial rename — you should see a Task spawn for `triage-quick-task` (Haiku). Ask for gnarly debugging — it should go straight to `triage-deep-reasoner`.

## Customizing

- **Tier models/effort**: edit the frontmatter in `~/.claude/agents/triage-*.md` (`model:` takes `haiku|sonnet|opus|fable|inherit` or full IDs; `effort:` takes `low|medium|high|xhigh|max`). Aliases track the latest models automatically.
- **Routing behavior**: edit `~/.claude/triage.md`. The installer already adds an `ask`-gate before Fable; change it to `deny` in `settings.json` → `permissions` to hard-block, or remove the rule to go back to notify-only.
- **Per project**: a project's own `CLAUDE.md` (or `AGENTS.md` via an `@AGENTS.md` wrapper — the pattern this repo itself uses) can override or opt out.
- **Context-warning threshold**: edit the `60` in `~/.claude/statusline.sh`.

## Disable / uninstall

- **Kill switch** (keep files, stop routing): delete the `@triage.md` line from `~/.claude/CLAUDE.md`.
- **Full uninstall**: `./uninstall.sh` — removes the six agents by name, the rubric, the scripts, and the workflow; strips the triage `permissions` rules; and drops `env.CLAUDE_CODE_SUBAGENT_MODEL` / `subagentPromptCacheTtl` **only while they still hold the values it wrote**. `model`, `effortLevel`, and `statusLine` are never touched, because the installer never wrote them.

Every piece degrades independently: unknown frontmatter keys are ignored, a broken statusline shows nothing, agents fall back to inheriting the session model.

## Testing

```bash
make verify   # lint -> drift -> test, fail-fast; the single green gate
```

- `make lint` — `bash -n` on every `*.sh`, `node --check` on `workflows/*.js`, `shellcheck` (if installed) at `--severity=warning`, and a docs-consistency check (every path this README's install sections cite must exist; the "six subagent definitions" claim above must match `agents/triage-*.md` on disk).
- `make test` — three suites. `test/roundtrip.sh` is an install/uninstall round-trip that never touches your real `~/.claude` (every case runs in its own `mktemp -d` sandbox via `$CLAUDE_DIR`): idempotent re-install, empty-dir install, symlinked `settings.json`, invalid `settings.json` (install must abort with zero mutation), a hand-converted Fable `ask`→`deny` rule surviving uninstall cleanup, user-set settings keys surviving both directions, retirement of a superseded `triage-run.js`, and the statusline render paths. `test/usage-tally.sh` covers the per-tier accounting. `test/workflow-scenarios.mjs` executes the real `triage-exec.js` body under mocked DSL globals — entry-contract validation, effort passthrough, seam gating, targeted remediation, escalation, budget refusal/ceiling, and the cross-review stage.
- `make drift` — `./drift.sh` compares your **installed** `~/.claude` copies against this repo file-by-file (6 agents, `statusline.sh`, `workflows/triage-exec.js`, the scripts, `triage.md`) and reports `same` / `MISSING (not installed)` / `FORKED`. A fork you've made on purpose (e.g. a hand-tuned `triage.md`) goes in `.driftignore` and reports `forked (expected)` instead of failing. Run it with `CLAUDE_DIR=/path/to/other/.claude ./drift.sh` to check a non-default install.
- CI (`.github/workflows/ci.yml`) runs `make verify` on macOS + Linux for every push/PR, with `shellcheck` installed so lint is never running in `SKIP` mode there.

## Caveats

- **`ANTHROPIC_API_KEY` silently overrides subscription billing.** If it's set in your environment, Claude Code bills the API instead of your plan. Unset it.
- The rubric is **instructions, not enforcement** — the orchestrator follows it reliably but it isn't a hard gate. The deterministic parts (per-agent model/effort pins, statusline) don't depend on model compliance.
- Per-model subscription quota weighting is undocumented; expect savings as *more usable hours per week* rather than a number on a dashboard.
- Built and verified against Claude Code **2.1.195** (June 2026): statusline `context_window.used_percentage`, `effort:` agent frontmatter, `Agent(type)` permission rules, and the Workflow DSL (`agent`/`parallel`/`budget`). If a future version changes these, the affected piece degrades gracefully — see Disable above.
