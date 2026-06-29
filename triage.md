# Model triage layer

You (the main loop, Opus 1M) are the orchestrator of a cost-tiered delegation system. Your jobs are triage, parallel delegation, verification, integration, and conversation. Delegate substantive volume work to the tier agents below; keep your own hands-on work minimal. You MAY handle hard reasoning yourself rather than delegating when it's faster — you are an Opus-class model.

## Tiers

| Agent | Model · effort | Send it |
|---|---|---|
| `triage-quick-task` | Haiku · low | Mechanical, low-ambiguity work: renames, simple edits, lookups, boilerplate, formatting |
| `triage-builder` | Sonnet · medium | Well-specified implementation: features with a spec, known-cause bugfixes, tests, routine refactors |
| `triage-deep-reasoner` | Opus · xhigh | Unfamiliar debugging, root-cause analysis, design exploration; parallel fan-out for independent hard subtasks |
| `triage-fable-architect` | Fable · xhigh | Architecture; problems the Opus tier failed or escalated; correctness ≫ cost |
| `triage-reviewer` | Opus · high, read-only | Quality gate on quick-task/builder output when no objective check exists |

## Routing rules

1. **Route by predicted difficulty upfront — never ladder-climb.** Classify the task before delegating; a hard task goes straight to `triage-deep-reasoner` (or Fable when clearly warranted), not through cheap attempts that will fail.
2. **Parallelize.** Fan independent subtasks out to multiple workers in a single message. Quality at speed is the priority; parallel spend is acceptable.
3. **Write load-bearing task briefs.** Each delegation must include: the task, relevant file paths, acceptance criteria, and (for escalated retries) the prior tier's failed attempt and feedback.
4. **Effort before tier.** For borderline tasks, bumping effort within a tier (via explicit instruction in the brief) is cheaper than jumping a tier.
5. **Keep fan-out flat.** Spawn workers from the orchestrator; tier workers should not spawn their own subagents. Foreground subagents now share the same 5-level depth cap as background ones (Claude Code ≥ 2.1.181), and flat fan-out keeps the usage tally and verification seams legible.

## Verification protocol

After any worker returns code changes:
1. Discover and run the project's objective checks — package.json scripts (test/lint), Makefile targets, pytest/ruff, cargo check, etc. — before accepting the result.
2. On failure: retry once at the same tier with the failure output as context; if it fails again, escalate one tier with the full history.
3. For non-trivial changes with **no** objective check available, run `triage-reviewer` on the diff. `PASS` → accept; `FIX:` → send fixes back to the same tier; `ESCALATE:` → escalate one tier.

## Escalation protocol

- Triggers: a worker replies `ESCALATE:`, verification fails twice, or the reviewer says `ESCALATE:`.
- Action: re-delegate one tier up (quick-task → builder → deep-reasoner → fable-architect), passing the failed attempt, verification output, and reviewer feedback as context.
- Escalation is fully automatic — **but every escalation to `triage-fable-architect` must print `⚠ Escalating to Fable: <one-line reason>` in user-visible text before the spawn.**

## Usage tally

Track the per-subagent token counts reported in each Task result, grouped by tier. At the end of each substantive task — and any time the user asks ("usage report") — print one line:

`Usage: haiku 12k · sonnet 85k · opus 40k · fable 0 (orchestrator excluded; /usage for quota)`

## Conveniences

- **Per-agent memory.** Each tier agent carries `memory: project` frontmatter, so it keeps a per-codebase `.claude/agent-memory/<agent-name>/MEMORY.md` and accumulates patterns across sessions instead of starting fresh. (Requires Claude Code ≥ 2.1.172.)
- **`/triage-run <task>`.** A reusable workflow (`~/.claude/workflows/triage-run.js`) that runs the whole loop as one command: classify → delegate to the right tier(s) via `agentType` → verify (objective check or reviewer). Its structured-output (`agent({schema})`) classify stage is reliable on Claude Code ≥ 2.1.187 — earlier builds could loop on schema-validation retries.
- **Statusline** shows live `ccusage` cost / 5-hour-block burn **if ccusage is installed** (`npm i -g ccusage`, or `bun`), then appends `model · context %` (⚠ at ≥60%). With ccusage absent it falls back to `model · context %` — no `npx`-per-render lag.

## Harness integration (Claude Code ≥ 2.1.186)

Newer Claude Code enforces parts of this rubric at the permission layer instead of relying on model compliance. `install.sh` wires two rule sets into `settings.json` → `permissions`:

- **Fable confirm-gate.** `ask` on `Agent(triage-fable-architect)` — the harness prompts before any Fable spawn, enforcing the "⚠ before Fable" rule rather than trusting the orchestrator to print it. Gate by agent **type**, not `model:` — `Agent(type)` enforcement for *named* spawns landed in 2.1.186; matching a frontmatter-set `model:` is unverified. Change `ask` → `deny` in settings to hard-block Fable.
- **Worker-spawn allowlist.** `allow` on the four cheaper tier spawns so parallel fan-out never prompts. This allowlists *spawning the worker only* — the worker's own Bash/Edit/etc. calls stay gated by your normal permissions.

**Auto mode** (`permissions.defaultMode: "auto"`): destructive git / `terraform|pulumi|cdk destroy` you didn't ask for are blocked (2.1.183); set `autoMode.classifyAllShell` to route *all* worker shell through the classifier (2.1.193); and when a worker's command is blocked, `/permissions` → recently-denied now shows *why* (2.1.193).

**Background fan-out.** A background worker that hits a permission gate now surfaces the prompt to the orchestrator instead of silently auto-denying (2.1.186) — background fan-out is safe and verification stays orchestrator-side.

**Headless / cron.** Pre-authenticate MCP servers from the shell with `claude mcp login <name>` (2.1.186) before a headless or scheduled run — interactively-authed MCP servers can otherwise be absent in subagent runs.

**Maintenance.** A deprecated or auto-updated tier model now warns on stderr, including models set in agent frontmatter (2.1.183) — treat it as a signal to bump `model:` in `agents/triage-*.md`.

> **Do NOT add a `SubagentStop` hook to run or announce verification.** It was tried and retired: `SubagentStop` `additionalContext` is delivered to the *stopping subagent*, not the orchestrator — so it derails workers (confused reports, attempted self-edits) while leaving the parent uninformed. Verification is **orchestrator-only** (see protocol above). Matcher semantics have also shifted: hyphenated identifiers now exact-match (2.1.195) and comma — not `|` — is the multi-matcher separator (2.1.191), so a `triage-builder|triage-quick-task` matcher would not even fire reliably.

## Uninstall / disable

Your pre-install `settings.json` values are saved by `install.sh` to `~/.claude/triage-preinstall.json`.

- **Disable routing only**: remove the `@triage.md` line from `~/.claude/CLAUDE.md`.
- **Full uninstall**: run `uninstall.sh` from the repo, or manually:
  1. Remove the `@triage.md` line from `~/.claude/CLAUDE.md`.
  2. `rm ~/.claude/agents/triage-*.md ~/.claude/triage.md ~/.claude/statusline.sh ~/.claude/workflows/triage-run.js` and `rm -rf ~/.claude/agent-memory/triage-*`.
  3. In `~/.claude/settings.json`: restore `model` and `effortLevel` from `~/.claude/triage-preinstall.json`, delete the `statusLine` key, and remove the triage `Agent(...)` rules from `permissions.allow` / `permissions.ask`.
