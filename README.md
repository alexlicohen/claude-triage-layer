# Claude Code Model Triage Layer

[![CI](https://github.com/alexlicohen/claude-triage-layer/actions/workflows/ci.yml/badge.svg)](https://github.com/alexlicohen/claude-triage-layer/actions/workflows/ci.yml)

A drop-in config layer for [Claude Code](https://code.claude.com) that routes every task to the **cheapest adequate Claude model** (Haiku → Sonnet → Opus → Fable 5.1), escalates automatically when a cheaper tier's output fails verification, and reports per-tier usage — **all billed to your Claude Pro/Max subscription**, not the pay-per-token API.

No app, no server, no API keys. It's seven subagent definitions, one instructions file, a statusline script, `scripts/ext-run.sh` (the single owner of every external-CLI invocation), `config/tiers.json` (the single owner of every model id and effort, Claude or external — see "Tiers are data" below), a `triage-exec` workflow, and a few settings keys.

**The split:** your session model — whatever frontier model you point at it — does the part only it can do (classify, decompose, write briefs, integrate). It writes the plan *inline*, then hands it to the `triage-exec` workflow, which spawns the tier agents, runs your tests, re-runs only the subtasks a failure implicates, and escalates one tier up when the reviewer says so. What comes back is a distillate — per-subtask status, per-check pass/fail, the review verdict — so worker prose never lands in the expensive context.

## Why this exists

Frontier models burn subscription quota several times faster than Sonnet (Fable 5.1 lists at 5× Sonnet 5's price, Opus 5.5 at 2×), and every orchestrator turn re-reads its whole context. Two facts shape the design:

1. **A standalone router (Agent SDK / API) cannot use subscription auth** — Anthropic's policy requires API keys for SDK-built agents. The only subscription-billed implementation is configuration *inside* Claude Code.
2. **Claude Code has no automatic prompt router** — nothing can swap the main-loop model per prompt. So triage is done by the orchestrating model itself, following a rubric, delegating to subagents pinned to cheaper/stronger models.

The economics aren't speculative: Anthropic's own [coordinator-pattern cookbook](https://github.com/anthropics/claude-cookbooks/blob/main/managed_agents/CMA_plan_big_execute_small.ipynb) measures the same split on the Managed Agents API — a frontier model plans and synthesizes while cheap workers absorb the token-heavy reading — and finds it **~2.5× cheaper and ~3× faster** than a rigor-matched solo frontier agent, with 84–98% of input tokens billed at the worker rate. This layer is the Claude Code / subscription-billed implementation of the same delegation economics (plus the verification, escalation, and per-tier accounting the cookbook leaves to you); its context-isolation and brief-granularity lessons are codified as flow rules 2 and 4, and verification rule 5, in `triage.md`.

## How it works

```
You ──► Main loop: your session model (your choice — the installer never sets it)
              │     ← triage rubric (triage.md): classify + decompose INLINE
              │       level (quick/builder/deep/top) x vendor (claude/codex) x role
              │
              └──► Workflow triage-exec  ← the plan: {subtasks, checks, review, crossReview, vendor}
                     │  executes, verifies, remediates, escalates — models come from config/tiers.json
                     ├──► triage-quick-task      Claude  quick   renames, lookups, boilerplate
                     ├──► triage-builder         Claude  builder well-specified features/fixes
                     ├──► triage-deep-reasoner   Claude  deep    hard debugging, design, fan-out, danger zone
                     ├──► triage-fable-architect Claude  top     last resort after deep@max (with ⚠ notice)
                     ├──► triage-reviewer        Claude  review, read-only  quality gate on cheap output
                     ├──► triage-cross-reviewer  external, read-only  cross-vendor signal (5 modes, VENDOR=codex)
                     └──► triage-external        external, writes  build worker any level codex serves (VENDOR=codex)
                     ▼
              returns a distillate: per-subtask status · per-check pass/fail · verdict · escalations · external{codex}
```

- **Routing**: the orchestrator classifies each task by difficulty *before* delegating (no wasteful "try cheap first" ladder-climbing) and parallelizes independent subtasks. Classification stays in the main loop — it is the best classifier in the system and already holds the context, so no spawn is spent re-deriving a plan.
- **Verification**: after a worker returns code, the orchestrator runs the project's own tests/lint/build before accepting. No objective check available? The read-only Opus reviewer reads the diff — far cheaper than redoing the work.
- **Escalation**: workers reply `ESCALATE:` when out of their depth; failed verification escalates one tier up with the failed attempt as context. Escalation to Fable is automatic but always announced (`⚠ Escalating to Fable: <reason>`), and `triage-exec` first re-runs a deep-tier subtask once at `max` effort unless the plan already set `max`.
- **Seam checks & targeted remediation**: `triage-exec` runs both the test/lint gates and a reviewer on correctness-critical (`danger`) subtasks, and on failure re-runs only the subtasks implicated by the failure output — re-running everything only when it can't attribute the failure. A `danger` subtask planned onto a cheap tier is upgraded to the deep tier, loudly.
- **Visibility**: a one-line per-tier token tally on request (say `usage report`) — computed deterministically from the session's on-disk subagent transcripts by `scripts/triage-usage.sh`, not recalled from model memory — and an optional statusline (copied, not wired — see Install) showing `model · ctx N%` that turns red at ≥60% context, plus live `ccusage` cost/burn when `ccusage` is installed.
- **Conveniences**: each implementation tier (not the read-only reviewer) carries `memory: project` (per-codebase memory across sessions); `triage-exec` runs delegate→verify→remediate→escalate as one workflow call; and the installer adds harness-level `permissions` rules — an `ask` confirm-gate before any Fable spawn, plus an allowlist for the cheaper worker spawns so fan-out doesn't prompt. See `triage.md`.

## Tiers are data

Model ids and efforts — Claude agents and both external vendors — live in exactly one place: `config/tiers.json` (installed as `~/.claude/scripts/triage-tiers.json`). Each entry carries a `basis` (`alex <date>`, `incumbent <date>`, or `guess`); `scripts/triage-tiers.sh` prints the level × vendor table and flags any `guess` entry as unverified until a parity run replaces it. To change a model: edit `config/tiers.json` → `make tiers` (runs `scripts/tiers-sync.sh`, which rewrites the `model:`/`effort:` frontmatter in `agents/*.md` to match) → `make verify` (which checks the two never drift apart again). Shipped code reads its model ids from this file (`install.sh` takes the subagent default from `levels.deep.claude.model`) or is linted against it (`triage-compare`'s default adjudicators); the only other literals are the historical subagent defaults `install.sh` migrates from.

## Requirements

- Claude Code with a **Pro or Max subscription** login (this is what makes it subscription-billed)
- `jq` (for the installer and statusline): `brew install jq`
- **Your orchestrator model is your choice** — the installer no longer sets `model` or `effortLevel`. Pick with `/model`: Opus 5.5 is the recommended orchestrator (Fable 5.1-level on most work at 40% of its per-token price, no 30-day retention requirement); the tiers absorb the volume either way. On a Pro plan, note that 1M-context Opus variants bill extra usage credits.
- Optional: the [`usage-guard`](https://github.com/alexlicohen/usage-guard) skill. The rubric reads its weekly-quota figure to pause bake-offs and to offer a codex shunt at ≥ 80%; without it those two steps are skipped, nothing else changes.
- Optional: OpenAI's Codex CLI (`codex`), for the external tiers and bake-off challengers — see "Security and data flow".
- **Version**: built and verified against Claude Code **2.1.272**. The harness permission gate needs **≥ 2.1.186** and per-agent memory needs **≥ 2.1.172**; on older builds the permission rules simply no-op and per-agent memory is ignored. `install.sh` checks `claude --version` itself and prints a specific warning per shortfall (or "could not verify" if `claude` is missing/unparseable) — warn-only, it never blocks the install.

## Install

```bash
git clone <this-repo> && cd claude-triage-layer
./install.sh
```

Then **start a new Claude Code session** (config loads at startup). The installer:

- copies the 7 agents to `~/.claude/agents/`, the rubric to `~/.claude/triage.md`, the statusline script, the three workflows (`triage-exec`, `triage-compare`, `triage-parity`) to `~/.claude/workflows/`, the runtime scripts to `~/.claude/scripts/`, and `config/tiers.json` as `~/.claude/scripts/triage-tiers.json` — the `install_file` lines in `install.sh` are the complete list, and `drift.sh` checks the same set. A locally modified installed file is backed up first, to `<file>.bak-triage-<UTC timestamp>` (the newest 5 per file are kept)
- appends a `SessionStart` hook to `settings.json` that runs `~/.claude/scripts/triage-context.sh`, which hands `~/.claude/triage.md` to the main session (matcher `startup|resume|clear|compact`, timeout 10 s). The command is `CLAUDE_DIR=<dir> bash <dir>/scripts/triage-context.sh` with the install dir pinned, so a non-default `CLAUDE_DIR` install reads its own kill switch, legacy guard and `triage.md` whatever `$HOME` is. An entry is this install's hook only when it is a `"type": "command"` hook whose command is exactly that string for the current `CLAUDE_DIR`; anything else — a hook pinned to another `CLAUDE_DIR`, an unpinned `bash <dir>/scripts/triage-context.sh`, a non-command entry carrying the same command, `…/triage-context.sh.backup` — is yours: never counted as installed, never removed. The hook counts as installed only when a group holding this install's hook has a matcher covering all four of `startup`, `resume`, `clear` and `compact` (absent, `""` and `*` cover everything; otherwise `|`-separated names are compared exactly); otherwise the group is appended and your groups stay as they are. `settings.json` is written once: every settings change (subagent model, cache TTL, `Agent(...)` rules, the hook) and the `CLAUDE.md` decision are computed first, so an evaluation error (jq or awk failing) aborts with `settings.json` and `CLAUDE.md` byte-for-byte untouched (the installed files under `~/.claude` may already be updated: they are copied first). Only after the settings write succeeds does it touch `~/.claude/CLAUDE.md`: a legacy `@triage.md` import line (older installs; CRLF too) is removed, with a timestamped backup first and every other byte kept, and one pointer line is appended once. `CLAUDE.md` is left alone, with a warning, when the hook could not deliver the rubric: with `"disableAllHooks": true` in `settings.json`, or when the installed `triage.md` fails `scripts/triage-context.sh --check` (a preserved fork over the hook's cap) — a legacy import then stays the working wiring, with no pointer; `--settings-status` and `make drift` report either as `settings migration blocked`. The pointer line names the install's own rubric: `The triage routing rubric (<CLAUDE_DIR>/triage.md) reaches the main session through a SessionStart hook; subagents don't receive it.`
- adds the Fable confirm-gate / worker-allowlist `permissions` rules, and sets two keys **only if they are unset**: `env.CLAUDE_CODE_SUBAGENT_MODEL` (the deep level's Claude model from `config/tiers.json`, so an un-pinned subagent spawn runs on Opus, not on your — possibly much pricier — session model) and `subagentPromptCacheTtl: "1h"`. Next to the subagent model it writes `env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL` (same value): ownership is recorded, not guessed from the value, so a later install upgrades — and uninstall removes — only a model it set and you haven't changed since. (An install made before the marker existed wrote `claude-opus-5` or `claude-opus-5-5` unmarked; install still upgrades those, uninstall leaves them with a note.)
- retires files older installs left behind — `workflows/triage-run.js`, `scripts/agy-run.sh`, `agents/triage-overflow.md` — deleting one only when its bytes match a version this repo shipped; a copy you edited is left in place (`triage-run.js`) or moved to a timestamped backup, never deleted
- warns if `ANTHROPIC_API_KEY` is set (see Caveats)

**Why a hook, not an `@triage.md` import.** An import in `~/.claude/CLAUDE.md` loads into every subagent too: the rubric rode along on nearly every Agent-tool and workflow spawn, about 3.6k input tokens each, and subagents have no use for it. `SessionStart` does not fire for subagents, so the hook reaches the main session only, and it fires again after `/clear` and compaction, so the rubric is re-injected rather than summarized away. Claude Code caps a hook's `additionalContext` at 10,000 characters (anything longer arrives as a 2,000-character preview plus a file path), so `triage.md` must stay under it with the hook's one-line label: lint runs `scripts/triage-context.sh --check triage.md` and holds the file to 9,500 bytes. The script prints a short notice instead of the rubric when `triage.md` is missing or over the cap, and stays silent while `~/.claude/triage.disabled` exists, while `CLAUDE.md` still has the `@triage.md` line (no double load), or when the hook input names a subagent. The SessionStart behavior above was verified live in the Claude Code CLI (2.1.289); hooks in the Desktop, IDE and Remote Control surfaces are not live-verified. Managed settings can stop the hook (`allowManagedHooksOnly`, or `disableAllHooks` set at a higher-precedence level); in that case keep or restore the `@triage.md` import in `CLAUDE.md`.

**What it does NOT touch**: `model`, `effortLevel`, and `statusLine` are never written, so there is no snapshot to restore and nothing for uninstall to revert. `statusline.sh` is copied but not wired — point `statusLine` at it yourself if you want it (the installer prints the exact JSON).

Two flags, composable: `./install.sh --dry-run` prints the full mutation plan (every file's create/overwrite/unchanged status, the settings keys, permission rules and `SessionStart` hook — `triage hook missing` when it would add it —, and the CLAUDE.md changes, including `legacy @triage.md import present`) and writes nothing; `./install.sh --files-only` copies/chmods just the installed files (the same `install_file` list) — skipping anything listed in `.driftignore` (deliberate personal forks — none currently) instead of clobbering it, and leaves `CLAUDE.md`, `settings.json`, and permissions untouched. This is the primitive behind `make sync` for re-pulling repo file updates without re-running the settings merge — so a settings change a newer installer would make (upgrading the subagent model, adding the `SessionStart` hook, migrating a legacy `@triage.md` import) needs a bare `./install.sh`; `make drift` says so (`settings migration pending`). Any jq or write failure makes install exit non-zero without printing "Installed.", and a `settings.json` of the wrong shape is refused before anything changes.

<details>
<summary>Manual install (no script)</summary>

1. Copy the files: `./install.sh --files-only` does exactly this and nothing else (no `CLAUDE.md`, no `settings.json`). By hand, follow the `install_file` lines in `install.sh` — agents, `triage.md`, `statusline.sh` (`chmod +x`), the three workflows into `~/.claude/workflows/`, the scripts into `~/.claude/scripts/` (`chmod +x`), and `config/tiers.json` as `~/.claude/scripts/triage-tiers.json`
2. In `~/.claude/settings.json` (the model is `levels.deep.claude.model` in `config/tiers.json`; use your real home path in the hook command, and append the hook group to any `SessionStart` array you already have rather than replacing it):
   ```json
   {
     "env": { "CLAUDE_CODE_SUBAGENT_MODEL": "<levels.deep.claude.model>" },
     "subagentPromptCacheTtl": "1h",
     "hooks": {
       "SessionStart": [
         { "matcher": "startup|resume|clear|compact",
           "hooks": [{ "type": "command", "command": "CLAUDE_DIR=/Users/<you>/.claude bash /Users/<you>/.claude/scripts/triage-context.sh", "timeout": 10 }] }
       ]
     }
   }
   ```
3. Remove any `@triage.md` line from `~/.claude/CLAUDE.md` (the hook stays silent while it is there, to avoid loading the rubric twice). Optionally append the pointer line `install.sh` writes (`pointer_line`), so the file says where the rubric comes from.
4. Optional: wire the statusline, using your real home path (tilde is not expanded inside JSON) — `"statusLine": { "type": "command", "command": "/Users/<you>/.claude/statusline.sh" }`
5. Optional (harness ≥ 2.1.186): to enforce the rubric at the permission layer, add `permissions` rules — an `ask` on `Agent(triage-fable-architect)` and an `allow` for the six cheaper `Agent(triage-*)` spawns. `install.sh` does this for you.
</details>

## Using it

**Nothing to invoke — it's always on in new sessions.** Ask for what you want; the orchestrator decides which tier does it. Useful controls:

| You want | Do |
|---|---|
| Override its routing | "send this to triage-deep-reasoner" / "just use triage-quick-task" |
| A full top-tier session | `/model fable` — the rubric still delegates cheap work down |
| Run a plan you wrote yourself | `Workflow({name:'triage-exec', args:{subtasks:[…], checks:['make test']}})` — full args: [Workflow arguments](#workflow-arguments) |
| A cheap session | `/model sonnet` |
| One-turn deep reasoning | include `ultrathink` in your prompt |
| Spend tally | say `usage report` (also printed after each task) |
| Subscription quota | `/usage` (the tally covers delegated tokens only) |

**Verify it's working**: in a fresh session, ask for a trivial rename — you should see a Task spawn for `triage-quick-task` (Haiku). Ask for gnarly debugging — it should go straight to `triage-deep-reasoner`.

## Customizing

- **Tier models/effort**: edit `config/tiers.json`, then `make tiers` — see "Tiers are data" above. Don't hand-edit the agent frontmatter directly; `make tiers` regenerates it and `make verify` fails if the two drift apart.
- **Quick-task agent**: ships with `omitClaudeMd: true` (harness ≥ 2.1.271) because its work is mechanical and the brief carries everything it needs; builder/deep keep CLAUDE.md so project conventions (AGENTS.md, make verify) still load.
- **Routing behavior**: edit `~/.claude/triage.md`. The installer already adds an `ask`-gate before Fable; change it to `deny` in `settings.json` → `permissions` to hard-block, or remove the rule to go back to notify-only.
- **Per project**: a project's own `CLAUDE.md` (or `AGENTS.md` via an `@AGENTS.md` wrapper — the pattern this repo itself uses) can override or opt out.
- **Context-warning threshold**: edit the `60` in `~/.claude/statusline.sh`.
- **Deny-list**: `clip-creator` is hard-denied for the external vendor. `CODEX_DENY_REPOS` (or an empty `.codex-deny` marker anywhere from a repo up to `$HOME`) opts a tree out of `codex`. `CODEX_BOUNDARY_CLEARED=1` must also be set by the calling agent — the runner's boundary attestation — attesting the data boundary (no clinical/BCH/PHI: no BAA; COI material is allowed since the codex account's training opt-out was confirmed, 2026-09-25) was checked; its absence refuses the run before anything is sent externally.

## External CLI tiers

Two tiers — `triage-cross-reviewer` (read-only: `review`/`read`/`verify`/`critique`/`fuzz`) and `triage-external` (writes: `build`) — are thin Haiku wrappers around an external, non-Claude CLI: OpenAI's Codex CLI (`codex`), at any level `config/tiers.json` lists for it. Both route through `scripts/ext-run.sh`, the single owner of the model table (`config/tiers.json`), the OS sandbox profile, the command audit log, the deny-list, and the exit-code contract — `0` OK, `2` USAGE, `3` REFUSED, `4` UNAVAILABLE, `5` SCHEMA, `6` build-mode patch-apply failure (working tree left unchanged; the wrapper applies nothing) — nothing else in the repo, and no agent, calls `codex` directly. Every codex run is **OS-confined** by a per-run `sandbox-exec` profile (macOS): it can read nothing under `$HOME` but its workspace, `~/.codex` and any `--allow-read` path, and write only its workspace, `~/.codex` and its scratch dir; no `sandbox-exec` (or a profile that does not apply or enforce) is `UNAVAILABLE`, never an unconfined run. Each command codex ran is logged (command + exit code, never output) to `~/.claude/logs/ext-run/codex-commands.jsonl`. The external CLI is an **optional** dependency — if it isn't installed, both tiers return `UNAVAILABLE` and nothing else in the layer degrades. Read-only modes run against a throwaway staging workspace; `build` runs against a disposable git worktree of the target repo and applies the result back as a patch, so the external CLI never has write access to your actual working tree.

Google's Antigravity (`agy`) was an external vendor until 2026-09-24, when it was retired: its headless mode let the model bypass its own sandbox, and a read-only review run wrote into a real repo. `VENDOR=agy`, `--vendor agy`, `crossReview: 'agy'|'both'` and agy compare/parity candidates are refused by name; `overflow` now means builder-level work on codex.

**Compare (bake-off, never applies)**: `Workflow({name:'triage-compare', args:{repo, base, brief, files, acceptance, checks, outDir, candidates:[...]}})` runs several `{vendor, level}` candidates, each in its own detached worktree at one base sha staged under `<outDir>/stage` by `scripts/stage-worktree.sh` — the real repo is never a candidate's working directory, and `repo` can be any repo, not just the session's — then grades each worktree's diff with `scripts/patch-check.sh`, which applies it to a fresh worktree at that sha, runs the check there, and reports pass/fail plus diffstat as one JSON line per candidate. A leakcheck afterwards proves the real repo did not change (a leak, or a leak check that could not confirm a clean repo, voids every grade); nothing is ever applied to your real tree. The orchestrator (or you) picks a winner, applies it with `git apply`, and re-runs the checks. See `triage.md`'s Compare section for the parity-ledger write that follows.

**Review bake-off (`kind:'review'`, never applies)**: `Workflow({name:'triage-compare', args:{kind:'review', repo, repoName, base, head, include, exclude?, context?, extras?, hardExclude?, groundTruth, accepted?, conventions?, outDir, reviewers:[...]}})` gives the same review to N reviewers in parallel. `scripts/review-stage.sh` snapshots commit `head` (never the live tree; `context/` and `PROJECT_MEMORY*.md` are always hard-excluded, tracked or not) plus the `base..head` diff under `outDir`; Claude reviewers read only that, codex reviewers get it through `ext-run.sh --input-dir` inside the OS sandbox. A deep agent merges duplicate findings, two adjudicators of different vendors judge every merged item blind to who reported it (both real = real, both not = rejected, else **disputed** for the user), and each reviewer gets precision/recall over the agreed items; an unavailable reviewer is never scored as zero. `scripts/parity-report.sh ingest-review` records the scores (after the user resolves the disputed items) as `inline-review` ledger lines, reported apart from build pass rates and not (yet) used for tier proposals.

**Parity (ranks models and efforts; proposals only)**: `Workflow({name:'triage-parity', args:{suite, outDir, candidates:[...]}})` runs every candidate `{vendor, level, model?, effort?}` up a private task suite (kept outside this repo; format and tooling in `scripts/README.md` › `parity-suite.sh`) in four difficulty bands, grading build tasks with nested `triage-compare` bake-offs, rubric tasks with two blind judges from different vendors, and review tasks by seeded-defect recall/precision; weak candidates stop early. Confinement: checks name tools only as `$PARITY_` variables (env map, never a real path in anything a candidate sees), judges get only the staged patch + key, and every git task source is fingerprinted before and after its task (`SOURCE_CHANGED` voids that task). The result is a ranking and the band where each candidate plateaus; proposals come from `scripts/parity-report.sh` (ingest the result into the parity ledger, then `report`: a **proposed** `config/tiers.json` change only past a min-n + margin rule, with its evidence). Nothing edits tiers.json; the user approves before `make tiers`. `scripts/parity-cost.sh` attributes the run's Claude usage to each candidate afterwards.

**FORCE warning**: if `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set (in your environment or in `settings.json`), it silently overrides every tier agent's `model:` — including the external-CLI tiers' Haiku wrapper — collapsing all routing onto one model. `install.sh` and `drift.sh` both warn loudly when they see it set but never edit it: if it's set, it was set on purpose, and only you should unset it.

## Workflow arguments

The full argument spec for the three workflows. Each workflow's `meta.whenToUse` carries only the minimal args shape (the skill listing truncates long strings) and points here. Model ids are never written here or in the workflows: defaults come from `config/tiers.json`. `agy` was retired on 2026-09-24 and is refused by name everywhere (as a vendor, candidate, reviewer or judge).

### triage-exec

`Workflow({name:'triage-exec', args})` runs a plan the orchestrator has **already** classified. It never classifies: a malformed plan throws before any spawn. It executes, verifies, re-runs only the implicated subtasks on failure (always on Claude), and escalates one rung up on `ESCALATE` (deep below max effort gets one deep@max attempt before Fable).

- `subtasks` — `[{brief, level, vendor, files, acceptance, danger, effort, checks?}]`.
  - `level`: `quick|builder|deep|top`; `tier` is an alias; `fable` = top on Claude, `overflow` = builder on codex.
  - `vendor`: `claude|codex`.
  - `checks: [cmd]`: the subtask's own objective checks, used as an inline bake-off's grade; the plan `checks` stay the verify gate.
- `checks` — `[shell commands]`, the plan's verify gate.
- `review` — reviewer mode: `auto` (default: reviewer when there are no checks or a subtask is `danger`), `always`, `never`.
- `crossReview` — `true` (= codex) or a vendor name; adds a cross-vendor second opinion.
- `overflow` — boolean; `true` = codex on builder subtasks.
- `vendor` — plan-level vendor (`claude|codex`).
- `noFable` — boolean (default `false`); set for material `triage.md` rule 7 keeps from Fable. A Claude `top` subtask (or `fable`) is then refused before any spawn; codex `top` is allowed. Deep@max is the ceiling: a `FIX` or failed check on a deep@max attempt (planned at `effort: 'max'`, or deep@max in place of top) gets one same-rung retry; where the ladder would then go to Fable (that retry failing, a failed deep@max step, or `ESCALATE` at deep@max) the subtask keeps its last output, gets an escalation `{from: 'deep', to: 'user'}`, status `needs-user`, and is listed in `needsUser`; the run reports `incomplete` (and `failed` while a gate still fails). A codex `top` subtask that comes back to Claude gets deep@max instead of Fable; if that deep@max attempt returns nothing, it stops for the user the same way. The report echoes `noFable` (and `needsUser`, empty otherwise) on every run.
- `bakeoff` — **inline build bake-offs, on by default**: the orchestrator passes it on every plan unless `triage.md` rule 10 excludes the work (the user said no bake-offs, PHI/clinical, classifier-sensitive, or a project boundary that keeps the material from external vendors). Shape `{config, seed, repo, outDir, weeklyPct, rates?}`:
  - `config`: the `scripts/triage-tiers.sh --bakeoff-json` object.
  - `seed`: string (`"<session id>:<plan #>"`).
  - `repo`: absolute path of the session repo.
  - `outDir`: absolute, outside `repo` (globally unique; ledger run ids derive from it).
  - `weeklyPct`: the weekly usage %; missing = sampling paused.
  - `rates`: `scripts/parity-report.sh rates --json` `.rates` (`{level: rate in [0, 1]}`: explore, maintain or 0 per level), used in place of `sampleRate` for its level and recorded on each `bakeoffs`/`bakeoffSkipped` entry that reached the draw.

Bake-off sampling and apply rules:

- **Eligible** subtask: has its own checks, or the plan checks when it is the only subtask; non-empty `files`; a tuning challenger that differs from its planned vendor/model/effort; not a planned top/claude (Fable) subtask; danger work only on the danger floor (`DANGER_FAMILIES`: the Claude Opus/Fable families, the codex family listed there at effort >= high).
- **Sampled** deterministically: FNV-1a of seed+id+brief < `rates[level]`, else `sampleRate`; none at `weeklyPct >= pauseAtWeeklyPct`.
- A sampled subtask runs **first**, one at a time, as a planned-vs-challenger `triage-compare`, only if `git status` shows its files unmodified.
- **Apply** via `stage-worktree.sh apply --require-clean`, counting only a real (non-empty), in-scope diff: the planned patch if it passed, else a passing challenger (logged as a fallback), else a failing planned diff (normal verify + remediation), else the subtask runs in place.
- A **LEAK** aborts the run. An unknown leak state, a failed compare, or an unknown/tree-modifying apply **withholds** the subtask (never run in place; returned in `withheld`; the run is incomplete).
- Returns `bakeoffs`, `bakeoffSkipped` and `ingest`: for each `ingest` entry the orchestrator writes `result` as JSON to `file`, then runs `cmd` (`parity-report.sh ingest-compare`).

### triage-compare

`Workflow({name:'triage-compare', args})` is a bake-off. It never applies anything; the real repo is never a candidate's or reviewer's workdir. Overview and confinement: "External CLI tiers" above.

**Build (`kind` omitted or `"build"`)** — args `{repo, base?, brief, files, acceptance, checks:[cmd...], outDir, overlay?, selfCheckEnv?, parallel?, candidates:[{vendor:claude|codex, level:quick|builder|deep|top, model?, effort?, label?}]}`:

- `repo`: any absolute git repo path (not necessarily the session repo); may be dirty. `base` (default `HEAD`) is resolved to ONE sha up front, and each candidate works in its own detached worktree at that sha under `<outDir>/stage` (`scripts/stage-worktree.sh`), never in `repo`.
- `outDir` and `overlay` must be OUTSIDE `repo`; `<outDir>/stage` must not already exist.
- External (non-claude) candidates require `files`.
- `checks` may name tools only as `$PARITY_<NAME>` variables (exported at grading by `patch-check.sh` from the parity env map; candidates see them unexpanded). Several checks are graded each in its own `bash -c` (one check's `||` never masks another's failure).
- `selfCheckEnv: true` copies `<repo>/.parity-env` into each CLAUDE candidate's worktree and tells it to source it (external candidates cannot self-check; recorded per candidate as `selfCheckEnv`).
- Candidates run one at a time; `parallel: true` runs them concurrently (Claude `outTokens` is then null).
- The grade is `scripts/patch-check.sh` on each worktree diff at the sha (plus the hidden `overlay`), never the candidate's self-report.
- A leakcheck then proves `repo` did not change. Only `leak:false` lets a grade stand: leak true OR unknown => every candidate invalid, `graded:false`. Also invalid: a patch `patch-check` could not grade (e.g. overlay-failed or a harness fault); every graded candidate when the relayed `PATCHCHECK` line is missing, garbled or not for this sha and patch set; a candidate whose ext-run line shows another model/effort than it asked for.
- Returns `sha`/`leak`/`baseMoved` and per candidate `status`/`applies`/`rc`/`diffstat`/`patch`/`tokens`/`model`/`effort`/`modelFrom` (`candidate|runner|null`)/`changedFiles`/`outOfScope` (a changed path outside `files`; null without `files`)/`captureWarnings`/`selfCheckEnv`. Check output stays in `<outDir>/tails` (`tail` names the file). The orchestrator picks and applies.

**Review (`kind:"review"`)** — args `{kind:"review", repo, repoName, base, head?, include:[globs], exclude?, context?, extras?:[{src,dest}], hardExclude?, groundTruth, accepted?, conventions?, outDir, reviewers:[...], adjudicators?, batchSize?, reviewerTimeout?, adjudicatorTimeout?, extendResult?, supersedes?}`:

- `outDir`: fresh, outside `repo`.
- `reviewers`: `[{vendor:claude|codex, level, model?, effort?, label?}]`; codex reviewers need `model` + `effort`.
- `adjudicators`: at least two; default = `config/tiers.json` `levels.deep` for each vendor (one Claude, one codex, at that level's model and effort).
- `batchSize` (default 10); `reviewerTimeout` (default `"30m"`), `adjudicatorTimeout` (default `"15m"`): codex spawns only, passed as `TIMEOUT=` to the `ext-run.sh` watchdog.
- `scripts/review-stage.sh` snapshots commit `head` (never the live tree; `context/` and `PROJECT_MEMORY*.md` always hard-excluded) plus the `base..head` range diff under `outDir`. Reviewers read ONLY those (Claude: `cd <snap>` on every command; codex: `INPUT_DIR`, OS-confined).
- One deep agent merges duplicates (provenance kept in the workflow, anonymized). Every merged item is judged by each adjudicator BLIND to reviewers and provenance: all real = real; all not-real/accepted-deviation = rejected; else disputed (for the user).
- Precision/recall per reviewer over non-disputed items; a failed or invalid reviewer is unavailable, never zero.
- Every codex prompt carries `PROMPT_BYTES` (the UTF-8 byte length of its prompt-file body); the wrapper refuses a prompt file that is not verbatim.
- **Extend**: `extendResult` = the result OBJECT a prior run of this workflow returned, passed inline (the path form `extend:"/file"` is refused; a prior result never passes through an LLM). Re-pass the prior run's args with ONLY the new reviewers, `base`/`head` resolving to the prior shas, and the prior `outDir`. The prior result is validated in code; then one quick task only checks that its snapshot still exists (manifest base/head = the prior shas) and re-asks the codex deny (`review-stage.sh deny-refresh`: a marker or deny-list entry added since the original run, or a failed re-check, makes codex reviewers/adjudicators unavailable). Only the new reviewers run (labels must not collide with prior ones). The merge attaches each new finding to an existing item (provenance only, never re-adjudicated) or makes a new item (next id); only new items are adjudicated, blind, by the same panel. Every non-superseded reviewer is rescored over the combined set; `supersedes:[labels]` keeps those prior runs as status `superseded`, unscored, their findings intact.
- Returns `{kind, base, head, reviewers, items, disputed, sourceChanged, flags, markdown}` (+ `extendedFrom {base, head, outDir, reviewers, items}`, `newItems`, `superseded` when extending). Ingest with `scripts/parity-report.sh ingest-review`.

### triage-parity

`Workflow({name:'triage-parity', args})` re-ranks models and efforts when a model ships or on request. Args:

- `suite`: `"/abs task suite dir"`.
- `outDir`: `"/abs fresh dir outside any source repo"`.
- `candidates`: `[{vendor:claude|codex, level:quick|builder|deep|top, model?, effort?, label?}]`.
- `bands?` (default `[1,2,3,4]`), `reps?` (default 1), `stopAfterFailedBands?` (default 2), `bandPassRate?` (default 0.5), `judges?: [{vendor, level, label?}]`, `taskFilter?: [ids]`, `desk?: true`.

Behaviour:

- Adaptive: a candidate stops after `stopAfterFailedBands` consecutive failed bands.
- unavailable/denied/invalid/unresolved never count as pass or fail; a compare LEAK aborts the run.
- Every task with a git source (build, rubric, review) is fingerprinted (`parity-suite.sh fingerprint`) before its candidates run and after grading: a change voids that task (invalid, flag `SOURCE_CHANGED <repo>: HEAD moved|tree changed|ignored files changed|refs/config/hooks changed`) and the run continues. A generator task has no source repo and is marked `guarded:false` in `tasks[]`.
- Rubric judges get only the staged patch + key.
- Afterwards: `parity-report.sh ingest-parity --result <saved result>`, then `parity-report.sh report` proposes any `config/tiers.json` change (min-n + margin rule; the user approves). Claude cost per candidate comes from `scripts/parity-cost.sh` on the run transcript.

## Security and data flow

**Threat model.** Codex, the one external vendor, is treated as a trusted collaborator that can make mistakes — not as an adversary. The OS sandbox, the deny-list, the staged worktrees and the bake-off leak checks exist to keep an *accident* (a wrong path, a stray `cp`, a patch landing in the wrong tree) away from your real repos, and to keep bake-off measurements honest (a candidate that can read the real fix scores falsely). They are not built to contain a hostile model, and nothing here claims they would. Concretely:

- codex can write only its workspace, its scratch dir and `~/.codex`; it can read its workspace, `~/.codex`, and paths outside `$HOME` and the temp dirs (system directories, mounted volumes). `scripts/README.md` › `ext-run.sh` has the exact profile and its known limits.
- Its network access is not restricted: anything in its workspace can reach OpenAI.
- A bake-off's check command and `patch-check.sh`'s grading run candidate code **unsandboxed**, in a disposable worktree, with your user's rights.
- The data-boundary attestation (`CODEX_BOUNDARY_CLEARED=1`) is the caller stating that no clinical/regulated material is involved; nothing verifies it.
- The command audit log is an after-the-fact record, not a control.

**What leaves the machine.** Only codex runs, always through `scripts/ext-run.sh`: the two external tiers (`triage-cross-reviewer`, `triage-external`), codex candidates in `triage-compare`/`triage-parity`, and bake-off challengers. Each sends its brief plus whatever is in its staged workspace — for build work, a checkout of the repo at the base commit (a planned codex subtask also carries your uncommitted work in). Everything else runs inside Claude Code on your subscription.

**Build bake-offs are on by default.** Flow rule 10 in `triage.md` has the orchestrator pass `bakeoff` on every `triage-exec` plan. triage-exec then samples about half of eligible subtasks (`tuning.sampleRate` in `config/tiers.json`; less once a level has enough data), runs a challenger next to each — codex about 90% of the time — grades both, and applies the challenger's patch only when it passes and the planned run fails. A sampled subtask with a codex challenger sends its staged checkout of the repo and its brief to OpenAI. Sampling pauses at ≥ 80% weekly quota (read with `usage-guard` when installed). To opt out:

- for a session: tell the orchestrator "no bake-offs";
- for a repo: an empty `.codex-deny` file anywhere from the repo up to `$HOME` (or a `CODEX_DENY_REPOS` entry) refuses every codex run on that tree, bake-off challengers included;
- everywhere: delete flow rule 10 from your `~/.claude/triage.md` (add `triage.md` to `.driftignore` first if you want `make sync` to keep your hand edit); without `bakeoff` args triage-exec runs none.

Review bake-offs (`triage-compare kind:'review'`) are opt-in: they run only when you ask for one.

## Disable / uninstall

- **Kill switch** (keep files, stop routing): `touch ~/.claude/triage.disabled`. It takes effect at the next startup, `/clear` or compaction (a running session keeps the rubric it already has); `rm ~/.claude/triage.disabled` re-enables. An install still wired by a legacy `@triage.md` line in `~/.claude/CLAUDE.md` (a `make sync` upgrade never migrates it) loads the rubric through that import instead: remove that line to switch it off.
- **Full uninstall**: `./uninstall.sh` — removes the seven agents by name (never by glob), the rubric, the statusline, the workflows, the scripts and the installed `triage-tiers.json`; strips the triage `permissions` rules; deletes only this install's `SessionStart` hook, the command hook pinned to its `CLAUDE_DIR` (a group it leaves empty goes too; your other hooks, including ones pinned to another `CLAUDE_DIR` or that merely mention the script, stay); removes this install's CLAUDE.md pointer line and any legacy `@triage.md` line, keeping every other byte; moves `~/.claude/triage.disabled`, if present, to the backup dir; drops `subagentPromptCacheTtl` only while it still holds the value install wrote, and `env.CLAUDE_CODE_SUBAGENT_MODEL` only while it still equals the ownership marker (the marker always goes). It never destroys bytes this repo cannot reproduce: an installed file is deleted only while it matches the clone's copy, and anything else — a hand-edited file, a tuned `statusline.sh`, a leftover from an older install — plus each agent's memory (`~/.claude/agent-memory/triage-*`) is **moved** to `~/.claude/triage-uninstall-backup-<UTC timestamp>/`, which it names. The settings rewrite is computed before any file is touched, so a jq failure aborts with nothing changed. `model`, `effortLevel`, and `statusLine` are never touched, because the installer never wrote them.

Every piece degrades independently: unknown frontmatter keys are ignored, a broken statusline shows nothing, agents fall back to inheriting the session model.

## Testing

```bash
make verify        # lint -> test, fail-fast; the gate for any branch
make verify-live   # verify -> drift; run after `make sync` to check the live install too
```

- `make lint` — `bash -n` on every `*.sh`, `node --check` on `workflows/*.js`, `shellcheck` (if installed) at `--severity=warning`, and a docs-consistency check (every path this README's install sections cite must exist; the "seven subagent definitions" claim above must match `agents/triage-*.md` on disk).
- `make test` — twelve suites (the Makefile's `test` target lists them). `test/roundtrip.sh` is an install/uninstall round-trip that never touches your real `~/.claude` (every case runs in its own `mktemp -d` sandbox via `$CLAUDE_DIR`): idempotent re-install, empty-dir install, symlinked `settings.json`, invalid or wrong-shaped `settings.json` (install must abort with zero mutation), jq failures mid-install/uninstall, a hand-converted Fable `ask`→`deny` rule surviving uninstall cleanup, user-set settings keys and the subagent-model ownership marker in both directions, timestamped install backups, uninstall's backup dir and exact leftover set, retirement of `triage-run.js`, `agy-run.sh` and `triage-overflow.md` behind their shipped checksums, `.driftignore` normalization, `tiers-sync.sh`'s guards, drift's settings-migration warning, the `SessionStart` hook (appended once, the pinned `CLAUDE_DIR` honoured with `$HOME` elsewhere, foreign `SessionStart` hooks — including near-miss commands that mention the script — surviving install and uninstall, matcher coverage, `disableAllHooks`, CRLF and legacy `@triage.md` migration, no CLAUDE.md or settings change after a jq/awk failure), and the statusline render paths. `test/triage-context.sh` covers the hook script itself: byte-exact injection after the label, silence on the kill switch, a legacy import or a subagent's `agent_id`, notices for a missing or oversize file, and `--check`. `test/usage-tally.sh` covers the per-tier accounting. `test/ext-run.sh` exercises `scripts/ext-run.sh` end-to-end against a stub `codex` CLI run under the REAL generated `sandbox-exec` profile (macOS; a non-confining test double elsewhere, with the enforcement checks skipped): the confinement itself (workspace r/w, `$HOME`/`/private/tmp`/meta-dir writes and `$HOME` reads denied, `--allow-read`, fail-closed without an enforcing sandbox), the command audit log, the retired-agy refusal, the level/mode table read from `config/tiers.json`, the deny-list, the exit-code contract (including the exit-0-with-nothing-produced regression case), and the build-mode worktree/patch-back path including `--patch-out`/`--check`. `test/workflow-scenarios.mjs` executes the real `triage-exec.js` body under mocked DSL globals — entry-contract validation, level/vendor routing (including the `fable`/`overflow` aliases and codex+danger), effort passthrough, seam gating, targeted remediation, escalation, and the cross-review stage (codex; the retired `'agy'`/`'both'` refused).
- `make drift` — `./drift.sh` compares your **installed** `~/.claude` copies against this repo file-by-file (7 agents, `statusline.sh`, the three workflows, the scripts including `scripts/ext-run.sh`, `triage.md`) and reports `same` / `MISSING (not installed)` / `FORKED`. A fork you've made on purpose goes in `.driftignore` and reports `forked (expected)` instead of failing. It also prints a warn-only `settings migration pending` line when `settings.json` still holds something a bare `./install.sh` would change but `make sync` never does (a subagent model at an earlier installer default, `triage hook missing`, `legacy @triage.md import present`; a missing `settings.json` counts as an empty one), and `settings migration blocked` while `disableAllHooks` is true. Run it with `CLAUDE_DIR=/path/to/other/.claude ./drift.sh` to check a non-default install. `make verify` never runs it (an unmerged or unsynced branch has nothing to drift against); use `make verify-live` after `make sync` to check the live install matches the repo too.
- CI (`.github/workflows/ci.yml`) runs `make verify` on macOS + Linux for every push/PR, with `shellcheck` installed so lint is never running in `SKIP` mode there.

## Caveats

- **`ANTHROPIC_API_KEY` silently overrides subscription billing.** If it's set in your environment, Claude Code bills the API instead of your plan. Unset it.
- The rubric is **instructions, not enforcement** — the orchestrator follows it reliably but it isn't a hard gate. The deterministic parts (per-agent model/effort pins, statusline) don't depend on model compliance.
- Per-model subscription quota weighting is undocumented; expect savings as *more usable hours per week* rather than a number on a dashboard.
- Built and verified against Claude Code **2.1.272** (September 2026): statusline `context_window.used_percentage`, `effort:` agent frontmatter, `Agent(type)` permission rules, and the Workflow DSL (`agent`/`parallel`/`budget`). If a future version changes these, the affected piece degrades gracefully — see Disable above.
