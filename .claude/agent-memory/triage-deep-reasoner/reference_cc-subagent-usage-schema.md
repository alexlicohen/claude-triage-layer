---
name: cc-subagent-usage-schema
description: Where Claude Code records per-subagent token usage on disk, the peak-context metric, the timestamp to group by, and why escalation is NOT derivable from it
metadata:
  type: reference
---

Claude Code (this machine, ~mid-2026 build) writes each spawned subagent's FULL transcript
to a sibling dir of the main session transcript — NOT as inline `isSidechain:true` lines in
the main file:

- `~/.claude/projects/<slug>/<session-id>.jsonl` — orchestrator's own turns (`isSidechain:false`).
- `~/.claude/projects/<slug>/<session-id>/subagents/agent-<agentId>.jsonl` — one subagent transcript (`isSidechain:true`, single model).
- `.../subagents/agent-<agentId>.meta.json` — `{agentType, description, toolUseId, spawnDepth}`; `agentType` = tier name (e.g. `triage-deep-reasoner`).
- Main-file `Agent` tool result carries `agentId`/`resolvedModel`/`outputFile` but NO token totals; usage is only in the subagent `.jsonl`. `slug` = cwd with every non-alnum char → `-`.

Assistant lines carry `.message.model` and `.message.usage{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`.

**Metric decision (verified, not assumed):** the per-subagent token figure Claude Code
displays = PEAK context = max over turns of `input + cache_creation + cache_read` (grows
monotonically, so peak≈last turn). Confirmed against two real runs: Fable code-review
reached 64917 (≈"66k"), Opus run reached 98443 (≈"98k"). Metrics excluding `cache_read`
undercount the ~98k run by ~45% (it is mostly re-read context). Cumulative-across-turns
totals balloon to 0.8M–2.6M (re-counts cached history each turn) — do NOT sum those.

**Why:** the deterministic tally must reproduce what the human/orchestrator eyeballs per
subagent, so it sums peak-context per model family (`orchestrator excluded`).
**How to apply:** for any future triage usage/token-accounting work, the authoritative
implementation is `claude-triage-layer/scripts/triage-usage.sh` (+ its `scripts/README.md`);
re-read them rather than recomputing. Verify the on-disk layout still holds — a Claude Code
version bump could move it. Not billing; `/usage` is authoritative for quota.

**Timestamp for time-grouping (verified 2026-07-01):** each transcript LINE carries a
top-level ISO-8601 UTC `.timestamp` (e.g. `2026-07-02T02:30:02.177Z`); present in every
line sampled (300/300 files). `meta.json` has NO timestamp field. Use the earliest
transcript `.timestamp` as the subagent's spawn time — NOT file mtime, which is
timezone-ambiguous and mutated by copies/rsync/git/backups (a sampled file's mtime was off
by hours). jq can bucket to ISO week directly: `.[0:10]|strptime("%Y-%m-%d")|mktime|strftime("%G-W%V")`.

**Escalation is NOT reliably derivable from on-disk data (verified 2026-07-01):** the only
escalation signal is free text in `meta.json .description` (the /triage-run `redo:` /
`deep←fable:` labels, or orchestrator hints `escalate`/`retry`/`prior attempt`). But only a
minority of subagents carry ANY `.description`, and escalation markers are near-absent among
those that do. So any escalation-rate stat must be an explicitly-labelled LOWER BOUND, never a
rate. Real escalation accounting would have to be emitted at routing time, not reconstructed.

**Cross-session aggregation** authority is `claude-triage-layer/scripts/triage-stats.sh`
(per-tier + per-week rollups; `--project`/`--all`/`--weeks`). Typical agentType landscape:
`triage-builder` dominant, then `triage-deep-reasoner`, with quick/fable/reviewer far rarer;
`workflow-subagent` is the largest NON-triage type — non-triage types are tallied separately
so they don't pollute tier stats. Gotcha: project slug dirs start with
`-`, so `ls -d */` treats them as flags and fails — use `find` for BSD-safe listing.
