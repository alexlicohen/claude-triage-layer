# Claude Code Model Triage Layer

A drop-in config layer for [Claude Code](https://code.claude.com) that routes every task to the **cheapest adequate Claude model** (Haiku → Sonnet → Opus → Fable 5), escalates automatically when a cheaper tier's output fails verification, and reports per-tier usage — **all billed to your Claude Pro/Max subscription**, not the pay-per-token API.

No app, no server, no API keys. It's five subagent definitions, one instructions file, a statusline script, a `/triage-run` workflow, and a handful of settings keys.

## Why this exists

Top-tier models (Fable 5) are excellent but burn subscription quota ~3–5× faster than Sonnet. Two facts shape the design:

1. **A standalone router (Agent SDK / API) cannot use subscription auth** — Anthropic's policy requires API keys for SDK-built agents. The only subscription-billed implementation is configuration *inside* Claude Code.
2. **Claude Code has no automatic prompt router** — nothing can swap the main-loop model per prompt. So triage is done by the orchestrating model itself, following a rubric, delegating to subagents pinned to cheaper/stronger models.

## How it works

```
You ──► Main loop: Opus (1M context, high effort)  ← triage rubric (triage.md)
              │  classifies difficulty upfront, fans out in parallel
              ├──► triage-quick-task      Haiku  · low    renames, lookups, boilerplate
              ├──► triage-builder         Sonnet · medium well-specified features/fixes
              ├──► triage-deep-reasoner   Opus   · xhigh  hard debugging, design, fan-out
              ├──► triage-fable-architect Fable  · xhigh  hardest problems (auto, with ⚠ notice)
              └──► triage-reviewer        Opus   · high   read-only quality gate
```

- **Routing**: the orchestrator classifies each task by difficulty *before* delegating (no wasteful "try cheap first" ladder-climbing) and parallelizes independent subtasks.
- **Verification**: after a worker returns code, the orchestrator runs the project's own tests/lint/build before accepting. No objective check available? The read-only Opus reviewer reads the diff — far cheaper than redoing the work.
- **Escalation**: workers reply `ESCALATE:` when out of their depth; failed verification escalates one tier up with the failed attempt as context. Escalation to Fable is automatic but always announced: `⚠ Escalating to Fable: <reason>`.
- **Seam checks & targeted remediation**: `/triage-run` runs both the test/lint gate and a reviewer on correctness-critical (`danger`) subtasks, and on failure re-runs only the subtasks implicated by the failure output — re-running everything only when it can't attribute the failure.
- **Visibility**: a one-line per-tier token tally after each task (say `usage report` anytime) — computed deterministically from the session's on-disk subagent transcripts by `scripts/triage-usage.sh`, not recalled from model memory — and a statusline showing `model · ctx N%` that turns red at ≥60% context, plus live `ccusage` cost/burn when `ccusage` is installed.
- **Conveniences**: each implementation tier (not the read-only reviewer) carries `memory: project` (per-codebase memory across sessions); `/triage-run <task>` runs classify→delegate→verify as one command; and the installer adds harness-level `permissions` rules — an `ask` confirm-gate before any Fable spawn, plus an allowlist for the cheaper worker spawns so fan-out doesn't prompt. See `triage.md`.

## Requirements

- Claude Code with a **Pro or Max subscription** login (this is what makes it subscription-billed)
- `jq` (for the installer and statusline): `brew install jq`
- **Max plan**: Opus 1M context is included. **Pro plan**: Opus 1M bills extra usage credits — after installing, change `"model"` to `"opus"` (200K) in `~/.claude/settings.json`.
- **Version**: built and verified against Claude Code **2.1.195**. The harness permission gate needs **≥ 2.1.186**, `/triage-run`'s structured-output classify stage needs **≥ 2.1.187**, and per-agent memory needs **≥ 2.1.172**. On older builds the permission rules simply no-op and per-agent memory is ignored; `/triage-run` is the exception — its classify stage can loop on schema-validation retries below 2.1.187 rather than degrade cleanly, so run it on a current build. `install.sh` checks `claude --version` itself and prints a specific warning per shortfall (or "could not verify" if `claude` is missing/unparseable) — warn-only, it never blocks the install.

## Install

```bash
git clone <this-repo> && cd claude-triage-layer
./install.sh
```

Then **start a new Claude Code session** (config loads at startup). The installer:

- copies the 5 agents to `~/.claude/agents/`, the rubric to `~/.claude/triage.md`, the statusline script, and the `/triage-run` workflow (`~/.claude/workflows/`)
- appends one line — `@triage.md` — to your global `~/.claude/CLAUDE.md` (append-only; never overwrites)
- sets `model: "opus[1m]"`, `effortLevel: "high"`, and the `statusLine` in `~/.claude/settings.json` (**saving your previous values** to `~/.claude/triage-preinstall.json` first), and adds the Fable confirm-gate / worker-allowlist `permissions` rules
- warns if `ANTHROPIC_API_KEY` is set (see Caveats)

Two flags, composable: `./install.sh --dry-run` prints the full mutation plan (every file's create/overwrite/unchanged status, the CLAUDE.md append, the settings keys and permission rules, the snapshot) and writes nothing; `./install.sh --files-only` copies/chmods just the installed files — agents, `statusline.sh`, the `/triage-run` workflow, `scripts/triage-usage.sh`, `triage.md` — skipping anything listed in `.driftignore` (e.g. a hand-forked `triage.md`) instead of clobbering it, and leaves `CLAUDE.md`, `settings.json`, and permissions untouched. This is the primitive behind `make sync` for re-pulling repo file updates without re-running the settings merge.

<details>
<summary>Manual install (no script)</summary>

1. `cp agents/triage-*.md ~/.claude/agents/`
2. `cp triage.md ~/.claude/ && cp statusline.sh ~/.claude/ && chmod +x ~/.claude/statusline.sh`
3. `mkdir -p ~/.claude/workflows && cp workflows/triage-run.js ~/.claude/workflows/` (needed for `/triage-run`)
4. Append a line containing exactly `@triage.md` to `~/.claude/CLAUDE.md` — make sure the file ends in a newline first, or the line fuses onto the last one
5. In `~/.claude/settings.json` (note your old values first), using your real home path in the `statusLine` command (tilde is not expanded inside JSON):
   ```json
   {
     "model": "opus[1m]",
     "effortLevel": "high",
     "statusLine": { "type": "command", "command": "/Users/<you>/.claude/statusline.sh" }
   }
   ```
6. Optional (harness ≥ 2.1.186): to enforce the rubric at the permission layer, add `permissions` rules — an `ask` on `Agent(triage-fable-architect)` and an `allow` for the four cheaper `Agent(triage-*)` spawns. `install.sh` does this for you.
</details>

## Using it

**Nothing to invoke — it's always on in new sessions.** Ask for what you want; the orchestrator decides which tier does it. Useful controls:

| You want | Do |
|---|---|
| Override its routing | "send this to triage-deep-reasoner" / "just use triage-quick-task" |
| A full top-tier session | `/model fable` — the rubric still delegates cheap work down |
| A cheap session | `/model sonnet` |
| One-turn deep reasoning | include `ultrathink` in your prompt |
| Spend tally | say `usage report` (also printed after each task) |
| Subscription quota | `/usage` (the tally covers delegated tokens only) |

**Verify it's working**: in a fresh session, ask for a trivial rename — you should see a Task spawn for `triage-quick-task` (Haiku). Ask for gnarly debugging — it should go straight to `triage-deep-reasoner`.

## Customizing

- **Tier models/effort**: edit the frontmatter in `~/.claude/agents/triage-*.md` (`model:` takes `haiku|sonnet|opus|fable|inherit` or full IDs; `effort:` takes `low|medium|high|xhigh|max`). Aliases track the latest models automatically.
- **Routing behavior**: edit `~/.claude/triage.md`. The installer already adds an `ask`-gate before Fable; change it to `deny` in `settings.json` → `permissions` to hard-block, or remove the rule to go back to notify-only.
- **Per project**: a project's own `CLAUDE.md` can override or opt out.
- **Context-warning threshold**: edit the `60` in `~/.claude/statusline.sh`.

## Disable / uninstall

- **Kill switch** (keep files, stop routing): delete the `@triage.md` line from `~/.claude/CLAUDE.md`.
- **Full uninstall**: `./uninstall.sh` — removes all files and restores your pre-install `model`/`effortLevel`/`statusLine` from the snapshot.

Every piece degrades independently: unknown frontmatter keys are ignored, a broken statusline shows nothing, agents fall back to inheriting the session model.

## Testing

```bash
make verify   # lint -> drift -> test, fail-fast; the single green gate
```

- `make lint` — `bash -n` on every `*.sh`, `node --check` on `workflows/*.js`, `shellcheck` (if installed) at `--severity=warning`, and a docs-consistency check (every path this README's install sections cite must exist; the "five subagent definitions" claim above must match `agents/triage-*.md` on disk).
- `make test` — `test/roundtrip.sh`, an install/uninstall round-trip suite that never touches your real `~/.claude` (every case runs in its own `mktemp -d` sandbox via `$CLAUDE_DIR`). Covers idempotent re-install, an empty-dir install, a symlinked `settings.json`, an invalid `settings.json` (install must abort with zero mutation), a hand-converted Fable `ask`→`deny` rule surviving uninstall cleanup, and both statusline render paths.
- `make drift` — `./drift.sh` compares your **installed** `~/.claude` copies against this repo file-by-file (5 agents, `statusline.sh`, `workflows/triage-run.js`, `triage.md`) and reports `same` / `MISSING (not installed)` / `FORKED`. A fork you've made on purpose (e.g. a hand-tuned `triage.md`) goes in `.driftignore` and reports `forked (expected)` instead of failing. Run it with `CLAUDE_DIR=/path/to/other/.claude ./drift.sh` to check a non-default install.
- CI (`.github/workflows/ci.yml`) runs `make verify` on macOS + Linux for every push/PR, with `shellcheck` installed so lint is never running in `SKIP` mode there.

## Caveats

- **`ANTHROPIC_API_KEY` silently overrides subscription billing.** If it's set in your environment, Claude Code bills the API instead of your plan. Unset it.
- The rubric is **instructions, not enforcement** — the orchestrator follows it reliably but it isn't a hard gate. The deterministic parts (per-agent model/effort pins, statusline) don't depend on model compliance.
- Per-model subscription quota weighting is undocumented; expect savings as *more usable hours per week* rather than a number on a dashboard.
- Built and verified against Claude Code **2.1.195** (June 2026): statusline `context_window.used_percentage`, `opus[1m]` syntax, `effort:` agent frontmatter, and `Agent(type)` permission rules. If a future version changes these, the affected piece degrades gracefully — see Disable above.
