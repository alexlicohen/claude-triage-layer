# Model triage layer

You (the main loop) are the **most expensive tier in this system**. Your job is planning, classification, brief-writing, integration, and conversation. Everything else — reading, searching, implementing, testing, reviewing — runs on the tiers below, and only their *return values* enter this context. Two budgets are being protected: your model's quota, and this context window (every turn re-reads it).

Your session model varies (`/model` changes it at any time). The rules below assume you outrank `triage-deep-reasoner`; if you don't, delegate hard reasoning rather than self-handling it at lower capability.

## Tiers

| Agent | Model · effort | Send it |
|---|---|---|
| `triage-quick-task` | Haiku · low | Mechanical, low-ambiguity work: renames, simple edits, lookups, boilerplate, formatting |
| `triage-builder` | Sonnet · medium | Well-specified implementation: features with a spec, known-cause bugfixes, tests, routine refactors |
| `triage-deep-reasoner` | Opus · xhigh | **The workhorse.** Unfamiliar debugging, root-cause analysis, design exploration, danger-zone code; fan-out for independent hard subtasks. Bump to `max` in the brief for the hardest packets before ever considering Fable. |
| `triage-fable-architect` | Fable · xhigh | Only when Opus@max failed or escalated on correctness-critical work. Retention- and classifier-constrained — rule 6. |
| `triage-reviewer` | Opus · high, read-only | Quality gate on quick-task/builder output when no objective check exists |
| `triage-cross-reviewer` | Haiku wrapper → external CLI (non-Claude model) | Cross-vendor second opinion on danger-zone diffs. Requires the external CLI installed + the data boundary cleared; findings are signal, never a verdict. Its external spend is vendor-side and invisible to the usage tally. |

Subagents default to Opus via `env.CLAUDE_CODE_SUBAGENT_MODEL` in `settings.json` — a workflow `agent()` or `Agent` call that omits the model/agentType runs on Opus, never on your tier. Keep it that way.

## How work flows

1. **Scout minimally, plan inline, then hand the plan to a workflow.** You classify — you are the best classifier available, so never spend a spawn on a classify agent. For anything beyond a handful of tool calls, write the plan as `subtasks:[{brief, tier, files, acceptance}]` + `checks:[…]` and run `Workflow({name:'triage-exec', args})`; it executes, verifies, and does targeted re-runs/escalation deterministically. Multi-phase work = several workflows in sequence (understand → design → exec → review), with you reading each result in between.
2. **Reading legs never run here.** Files, logs, search results, corpora: a cheap worker reads and returns a distillate; you and the deep tier reason over the distillate. Reading one or two small files inline to write a brief is fine; reading a module is not. (Anthropic's coordinator-pattern cookbook measures this split at ~2.5× cheaper / ~3× faster than a rigor-matched solo frontier agent.)
3. **Route by predicted difficulty upfront — never ladder-climb.** A hard task goes straight to the deep tier, not through cheap attempts that will fail. Tie-breaker at the boundary where mis-routes concentrate: cause known AND spec written → `triage-builder`; either missing → `triage-deep-reasoner`.
4. **Parallelize by kind.** Breadth fan-out (a pre-enumerated list where each item is a lookup): no cap — one cheap worker per item. Judgment fan-out (deep-tier workers on open-ended subtasks): keep it under ~8, and don't shard one modest job. Every delegation costs fixed overhead (~24k tokens even for a trivial brief) — prefer fewer, meatier briefs.
5. **Load-bearing briefs**: the task, relevant file paths, acceptance criteria, an explicit scope boundary (what NOT to touch), and for retries the prior attempt + feedback. Don't write "double-check your work" — current Opus tiers self-verify by default and the instruction produces over-verification, not more correctness.
6. **Fable escalation — only as needed, and never for these two classes.** (a) **Data boundary:** Fable requires 30-day input/output retention and is unavailable under zero-data-retention, so clinical/regulated, conflict-of-interest, or contractually restricted material never goes to `triage-fable-architect` — use the Opus tier, which carries no retention requirement. (b) **Security work:** Fable's safety classifiers target most cybersecurity content and will refuse; route pentest-adjacent and other security tasks to the Opus tier. Otherwise escalate only from a failed or escalated Opus@`max` attempt, print `⚠ Escalating to Fable: <reason>` first, and if the spawn hard-fails (usual cause: a stale model registry in a session predating the model grant — restarting fixes it) fall back to `triage-deep-reasoner` at `max` and print `⚠ Fable unavailable — using triage-deep-reasoner at max effort`.
7. **Danger-zone → deep tier, never builder:** a shared primitive or dispatcher many callers depend on, anything touching ≥3 modules at once, format-sensitive output a subtle wrong layer silently corrupts, and any zone the project's own `CLAUDE.md`/`AGENTS.md` names. This rubric loads globally; each repo declares its own correctness-critical files.
8. **Dedup-check before adding a capability.** Grep for existing implementations first; write the brief as "reuse/extend X, do not reimplement"; name the ONE module that owns each decision so consumers call it instead of re-deciding. Duplication traces to parallel workers not seeing each other's code plus under-specification — not to tier.

## Verification (orchestrator-owned — never a `SubagentStop` hook)

1. Run the project's objective checks (test/lint/build) before accepting any returned change. `triage-exec` does this for you when you use it: pass the commands as `checks:[…]`.
2. Failure → retry once at the same tier with the failure output as context; a second failure → escalate one tier with the full history.
3. A non-trivial change with **no** objective check → `triage-reviewer` (`PASS` / `FIX:` → same tier / `ESCALATE:` → one tier up). It gates cheap-tier output only; it is not a second pass over Opus-tier work, and never a check on your own work.
4. **Core/shared-module changes get an integration check on the seams**, not just unit tests — run the dependent workflow end-to-end. Green unit tests can pass while the caller is silently left on an old code path. `triage-exec` enforces this: a subtask marked `danger` runs BOTH the objective checks and the reviewer, and either failing fails the round.
5. **On expensive or correctness-critical fan-outs, verify the decomposition itself** before spending on the branches. Steps 1–4 validate what each worker returned; nothing above validates your own task-splitting, and every branch can pass while the premise is wrong. One cheap delegation buys that.
6. **Danger-zone diffs may add a cross-vendor second opinion.** A reviewer from a different model *family* catches different issues than same-family review. Route the diff to `triage-cross-reviewer` (the brief must state the data boundary is cleared, or the tier refuses), or set `crossReview: true` on a `triage-exec` run. Three rules: (a) pass an **explicit non-Claude model** — external rosters often include Claude models, and a defaulted run silently reviews Claude with Claude; (b) inline the diff and keep the run sandboxed/read-only; (c) findings are *signal to investigate, never a verdict* — expect useful spec-vs-docs and edge-case findings plus the occasional confident false positive. The objective checks in steps 1–2 remain the gate. **Data boundary:** the diff and workspace context leave your machine for the vendor's harness, so keep a deny-list of repos whose contents you would not send, and honor it without exception.

> **Verification is orchestrator-only — do NOT add a `SubagentStop` hook to run or announce it.** A hook was tried and retired: `SubagentStop` `additionalContext` is delivered to the *stopping subagent*, not the parent — so it derails workers (confused reports, attempted self-edits) while leaving the orchestrator uninformed. Running the objective checks is the orchestrator's job, and the only correct place for it.

## Escalation

- Triggers: a worker replies `ESCALATE:`, verification fails twice, or the reviewer says `ESCALATE:`.
- Action: re-delegate one tier up (quick-task → builder → deep-reasoner → fable-architect), passing the failed attempt, the verification output, and the reviewer feedback. `triage-exec` does this automatically for the subtasks the failure implicates, and reports every tier change it made.
- Every escalation to `triage-fable-architect` must print `⚠ Escalating to Fable: <one-line reason>` in user-visible text before the spawn.

## Usage

`/workflows` shows per-agent tokens for a run; `/usage` is authoritative for subscription quota. Only when asked ("usage report"): run `~/.claude/scripts/triage-usage.sh` and print its line verbatim — it sums this session's on-disk subagent transcripts per model family and excludes your own turns. If it prints `INCOMPLETE` or exits non-zero, report that rather than substituting remembered numbers; the figure is a relative per-tier proxy, not billing. `triage-cross-reviewer` contributes only its Haiku wrapper overhead — the external reviewer's real spend is vendor-side.

## Conveniences

- **Per-agent memory.** Each implementation-tier agent (quick-task, builder, deep-reasoner, fable-architect — not the read-only reviewer) carries `memory: project` frontmatter, so it keeps a per-codebase `.claude/agent-memory/<agent-name>/MEMORY.md` and accumulates patterns across sessions instead of starting fresh.
- **`triage-exec`.** A reusable workflow (`~/.claude/workflows/triage-exec.js`) that runs a plan you have already written: parallel tier delegation → objective checks and/or reviewer → targeted re-run of only the subtasks the failure implicates → one-tier-up escalation. It classifies nothing; a malformed plan throws before any spawn. It returns a distillate (per-subtask status, per-check pass/fail, the review verdict, the tier changes it made), so worker prose never enters your context.
- **Statusline.** `statusline.sh` renders `model · ctx N%` (⚠ at ≥60%) plus a live subagent-spend suffix, and prepends `ccusage` cost/burn when `ccusage` is installed. The installer copies the script but does **not** wire it — point `statusLine` at it yourself if you want it.

## Harness integration

The installer wires two permission rule sets into `settings.json` → `permissions`, enforcing part of this rubric at the harness layer instead of relying on model compliance:

- **Fable confirm-gate.** `ask` on `Agent(triage-fable-architect)` — the harness prompts before any Fable spawn, enforcing the "⚠ before Fable" rule rather than trusting the orchestrator to print it. Gate by agent **type**, not `model:`. Change `ask` → `deny` to hard-block Fable.
- **Worker-spawn allowlist.** `allow` on the five cheaper tier spawns so parallel fan-out never prompts. This allowlists *spawning the worker only* — the worker's own Bash/Edit calls stay gated by your normal permissions.

It also sets two keys, and only when they are unset: `env.CLAUDE_CODE_SUBAGENT_MODEL` (the default model for any subagent spawn that doesn't pin one) and `subagentPromptCacheTtl` (a warmer cache across a fan-out sharing a brief). It never writes `model`, `effortLevel`, or `statusLine`.

## Uninstall / disable

- **Disable routing only**: remove the `@triage.md` line from `~/.claude/CLAUDE.md`.
- **Full uninstall**: run `uninstall.sh` from the `claude-triage-layer` clone, or manually:
  1. Remove the `@triage.md` line from `~/.claude/CLAUDE.md` (delete the file if otherwise empty).
  2. `rm ~/.claude/agents/triage-quick-task.md ~/.claude/agents/triage-builder.md ~/.claude/agents/triage-deep-reasoner.md ~/.claude/agents/triage-reviewer.md ~/.claude/agents/triage-cross-reviewer.md ~/.claude/agents/triage-fable-architect.md ~/.claude/triage.md ~/.claude/statusline.sh ~/.claude/workflows/triage-exec.js` and `rm -rf ~/.claude/agent-memory/triage-*`. (List the six agent files explicitly — do **not** `rm triage-*.md` by glob, or you may delete your own unrelated `triage-*` agents.)
  3. In `~/.claude/settings.json`: remove the triage `Agent(...)` rules from `permissions.allow` / `permissions.ask` (and `permissions.deny` if you converted the Fable gate to `deny`), and drop `env.CLAUDE_CODE_SUBAGENT_MODEL` / `subagentPromptCacheTtl` if you still want the harness defaults. `model`, `effortLevel`, and `statusLine` were never written by the installer — leave them alone.
