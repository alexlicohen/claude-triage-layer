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

## Uninstall / disable

Your pre-install `settings.json` values are saved by `install.sh` to `~/.claude/triage-preinstall.json`.

- **Disable routing only**: remove the `@triage.md` line from `~/.claude/CLAUDE.md`.
- **Full uninstall**: run `uninstall.sh` from the repo, or manually:
  1. Remove the `@triage.md` line from `~/.claude/CLAUDE.md`.
  2. `rm ~/.claude/agents/triage-*.md ~/.claude/triage.md ~/.claude/statusline.sh`
  3. In `~/.claude/settings.json`: restore `model` and `effortLevel` from `~/.claude/triage-preinstall.json` and delete the `statusLine` key.
