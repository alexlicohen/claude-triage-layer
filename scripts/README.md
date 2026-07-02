# scripts/

## `triage-usage.sh` — deterministic per-tier token tally

Replaces the orchestrator eyeballing per-subagent token counts and summing them from
memory (see `triage.md` § Usage tally). Deterministic, read-only, offline.

```
Usage: triage-usage.sh [-v] [PATH]
```

Prints one rubric line:

```
Usage: haiku Nk · sonnet Nk · opus Nk · fable Nk (orchestrator excluded; /usage for quota)
```

With `-v`, also prints a per-agent breakdown table (agentId, tier, model family,
peak-context, cumulative output/input/cache-read).

### What it reads

Claude Code writes every spawned subagent's full transcript next to the main session
transcript:

```
~/.claude/projects/<slug>/<session-id>.jsonl              # orchestrator — EXCLUDED
~/.claude/projects/<slug>/<session-id>/subagents/
    agent-<agentId>.jsonl                                 # one subagent transcript
    agent-<agentId>.meta.json                             # {agentType, description, toolUseId, spawnDepth}
```

- Subagent assistant lines carry `.message.model` (`claude-opus-4-8`, `claude-fable-5`,
  `claude-sonnet-5`, `claude-haiku-*`, …) and
  `.message.usage {input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`.
- The orchestrator's own turns live only in `<session-id>.jsonl` (they are `isSidechain:false`)
  and are **never counted** — hence "orchestrator excluded".
- `agent-<id>.meta.json` supplies `agentType` (the tier name, e.g. `triage-deep-reasoner`),
  used only for the human-readable `-v` breakdown.

`PATH` may be a session `.jsonl`, a session directory, a `subagents/` directory, or a
project directory (newest `*.jsonl` is used). Omitted → newest `*.jsonl` in
`~/.claude/projects/<slug-of-$PWD>` (the current session).

### What it counts, and why

For each subagent it takes the **peak context** the agent reached:

```
peak = max over assistant turns of (input_tokens + cache_creation_input_tokens + cache_read_input_tokens)
```

then attributes that peak to the model family of the peak turn and sums per family.

**Why this number.** It equals the per-subagent token figure Claude Code itself displays
(the context-window occupancy at the run's high-water mark). Verified against two known
runs in this repo's development session: a Fable code-review reached `64917` (~66k) and an
Opus principles-extraction run reached `98443` (~98k) — exactly the numbers the human
operator observed. Because a subagent's context grows monotonically, `peak == last turn`
in practice; `peak` is used for robustness against a small/compacted final turn.

Candidate metrics that were rejected because they do **not** reproduce the observed
per-agent numbers: `output + non-cached input` gave 77k/55k for those two runs (the ~98k
run is mostly re-read context, so any metric excluding `cache_read` undercounts it by
~45%); cumulative-across-turns totals ran to 0.8M–2.6M (they re-count the cached history
every turn).

### Limits (read before trusting the number)

- **It is a relative per-tier cost proxy, not billing.** It is dominated by
  `cache_read_input_tokens` (each turn re-reads the agent's accumulated context + system
  prompt + tool defs from cache, which is billed at a large discount). For authoritative
  quota/spend use `/usage` — as the rubric line itself says.
- **Cache reads ARE included** (they are part of the context the agent occupied). If you
  want new-tokens-only, that is not what this reports.
- **Cumulative output is not in the headline** (it is shown in `-v` as `CUM_OUT`). A
  high-output agent — e.g. Fable emitting a long review — is therefore *undercounted* by
  the headline; check `CUM_OUT` in `-v` when output cost matters.
- **Live sessions grow.** Running mid-session counts subagents in progress; totals rise as
  those agents append. The result is deterministic for a given on-disk state.
- **Per-family attribution uses the transcript's `model` field** (ground truth), so a
  read-only reviewer running on Opus is counted under `opus`, matching its actual model.

### Fail-loud behaviour

| Condition | Result | Exit |
|---|---|---|
| Success | rubric line (+ table with `-v`) | 0 |
| Bad flag / non-`.jsonl` file / too many args | error to stderr | 1 |
| Path does not exist | error | 2 |
| Default project dir unresolvable / no `*.jsonl` | error | 3 |
| Transcript empty / unreadable | error | 4 |
| No subagent transcripts, or all unparseable | `INCOMPLETE:` message | 5 |
| `jq` not installed | error | 6 |

A tier legitimately at 0 (no subagent of that model spawned) is reported as `0` — a real
measurement, distinct from the `INCOMPLETE` case, which never prints zeros as if measured.

### Requirements

`bash` (3.2+, i.e. macOS default — no bash-4 features) and `jq`. No GNU-only flags.

---

## `triage-stats.sh` — cross-session routing statistics

Where `triage-usage.sh` answers *"what did **this** session's subagents cost?"*, this answers
*"how is the triage layer being **routed** over many sessions?"* — the data you need to tune the
routing rules in `triage.md` (is `triage-builder` over- or under-used? does `triage-quick-task`
ever fire? where do the tokens go per week?). It aggregates every spawned subagent across a whole
project (all its sessions) or across every project.

```
Usage: triage-stats.sh [--project DIR | --all] [--weeks N]
```

- **(default)** — aggregate every session of **this cwd's** project
  (`~/.claude/projects/<slug-of-$PWD>`).
- **`--project DIR`** — aggregate a specific project. `DIR` may be a working directory (its slug
  names the project, e.g. `/Users/alex/projects/foo`) **or** a Claude project dir directly
  (`~/.claude/projects/<slug>`). Slug resolution is tried first, so passing your working directory
  does the intuitive thing.
- **`--all`** — aggregate every project under `~/.claude/projects`.
- **`--weeks N`** — only count subagents spawned within the last `N` weeks. **Default `4`.**
  `--weeks 0` disables the window (all time).

### What it reads

The **same** on-disk layout `triage-usage.sh` documents (see above): each spawned subagent's
`agent-<id>.jsonl` transcript and its `agent-<id>.meta.json` sidecar, under
`~/.claude/projects/<slug>/<session-id>/subagents/`. The orchestrator's own `<session-id>.jsonl`
is **never** opened — *orchestrator excluded*, exactly as in `triage-usage.sh`. Read-only; counts
only, never message content. One `jq` pass per transcript and one per sidecar — no file is re-read.

- **Tier** = the sidecar's `.agentType`. Any type beginning `triage-` is a **triage tier**;
  everything else (`workflow-subagent`, `general-purpose`, `Explore`, `fork`, …) is **non-triage**
  and is tallied in a **separate** table so it can't pollute the tier stats. A missing/empty
  `.agentType` buckets as `other`.
- **Peak-context tokens** = *exactly* the metric `triage-usage.sh` owns:
  `max` over assistant turns of `input + cache_creation + cache_read`. This script does not
  redefine it — it only sums/medians it across sessions (verified byte-identical to
  `triage-usage.sh` on real transcripts). It is a **relative cost proxy, not billing** — the same
  caveats in the `triage-usage.sh` limits section apply (dominated by `cache_read`; use `/usage`
  for quota).

### What each stat means

1. **Per-tier table** — for each of the five triage tiers (always shown, even at `0`, so an
   under-used tier is visible): distinct **sessions** the tier appeared in, **spawns** (agent
   count), and **total** + **median** peak-context tokens. Median (not mean) because a couple of
   huge deep-reasoner runs skew the average.
2. **Per-week rollup** — spawns per ISO week (`%G-W%V`, UTC) × triage tier. This is the routing
   trend: e.g. a week that is nearly all `builder` with zero `deep`/`reviewer` is a routing signal.
3. **Non-triage table** — the same sessions/spawns/total for non-triage subagents, kept out of the
   tier stats.
4. **Escalation markers** — see the limit below.

### Week grouping uses the embedded timestamp, not file mtime

A subagent's spawn time is the **earliest `.timestamp`** in its transcript (ISO-8601 UTC, e.g.
`2026-07-02T02:30:02.177Z`), bucketed by ISO week. This is deliberately **not** file `mtime`,
because the embedded timestamp is (a) present in every transcript line observed, (b) unambiguously
UTC, and (c) immune to file copies / rsync / git checkouts / backups that reset `mtime` — on a
sampled file the `mtime` disagreed with the embedded timestamp by hours. The `--weeks` window
compares this spawn date against a BSD-`date` cutoff.

### Limits (read before trusting the numbers)

- **The escalation stat is an explicitly-labelled LOWER BOUND, not an escalation rate.**
  Escalation chains are **not reliably recorded on disk.** The only signal is free text in
  `meta.json .description` — the `/triage-run` `redo:` / `deep<-fable:` labels, or orchestrator
  hints like `escalate` / `retry` / `prior attempt`. But **most subagents carry no description at
  all** (on the development machine, only ~24% did), and in practice these markers are almost
  entirely absent (≈3 hits across ~745 descriptions / ~3100 subagents). So the script scans the
  description-bearing minority and reports the **hit count as a floor**, alongside how many
  subagents had no description to scan. It never presents this as a rate, and never infers an
  escalation that isn't textually marked. If you need real escalation accounting, it has to be
  emitted at routing time (e.g. a structured field in the meta), not reconstructed here.
- **Peak-context is a relative cost proxy, not billing** (inherited from `triage-usage.sh`; it is
  dominated by cached-context re-reads). Cumulative output is *not* summed here.
- **Live sessions grow**; running mid-session counts in-progress subagents, and re-running later
  yields higher counts. Deterministic for a given on-disk state.
- **`--all` scans every transcript** (hundreds–thousands of files): a few tens of seconds is
  normal. A `--weeks` window skips the sidecar read for out-of-window transcripts, so a windowed
  run is cheaper than `--weeks 0`.

### Fail-loud behaviour

| Condition | Result | Exit |
|---|---|---|
| Success | tables + rollup + escalation line | 0 |
| Bad flag / bad `--weeks` / missing arg | error to stderr | 1 |
| `--project` path unresolvable (no dir, no slug match) | error | 2 |
| `~/.claude/projects` or default project dir missing | error | 3 |
| No subagent transcripts in scope, all outside the window, or all unparseable | `INCOMPLETE:` | 5 |
| `jq` not installed | error | 6 |

Per-transcript parse failures are **counted and reported** (`N unreadable — skipped`), never
silently dropped. A tier legitimately at `0` is reported as `0` (a real measurement), distinct
from the `INCOMPLETE` case, which never prints zeros as if measured.

### Requirements

`bash` (3.2+, macOS default) and `jq`. BSD-safe: uses BSD `date -v`; no `stat -c`, `readlink -f`,
GNU-only flags, or associative arrays.
