---
name: cc-spawn-knobs
description: Which spawn paths can set effort/schema/tool-denies in Claude Code 2.1.280, and that bash reads of other projects' transcripts get classifier-blocked
metadata:
  type: reference
---

Verified 2026-09-22 on CC 2.1.280, from the tool schema and binary strings:
- The `Agent` tool takes only description/prompt/subagent_type/model/isolation. There is **no effort param**, so a direct spawn runs at the agent's frontmatter `effort`. Effort words in the brief text don't change it: on Opus 5.5 and Fable 5.1, effort is the only thinking control.
- Workflow `agent(prompt, opts)` accepts `effort`, `schema` (structured output), `model`, `isolation`, `agentType`, and `disallowedTools`. So a triage-exec subtask's `effort` field is the only way to run deep@max.
- Agent definitions support tool denies. Plugin agents use a `disallowedTools: a, b` frontmatter line; the binary mentions "the agent definition's denies". Tiers without a `tools:` list (builder/deep/fable) do get the Agent tool: this deep-reasoner session had it.
- Reading another project's subagent transcripts in bulk with jq/grep through Bash was denied by the auto-mode classifier ("Sensitive-Source Provenance"). Don't plan an audit around mining `~/.claude/projects/*/subagents` without asking first.

**How to apply:** when routing or writing briefs, set effort in the plan, never in prose. Re-check these after a CC version bump. Related: [[cc-subagent-usage-schema]].
