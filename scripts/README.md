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
  `meta.json .description` — the `triage-exec` `redo:` / `deep<-fable:` labels, or orchestrator
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

---

## `ext-run.sh` — the single owner of every external-CLI invocation (`agy`, `codex`)

Nothing else in this repo, and no agent, may call `agy` (Google Antigravity) or `codex`
(OpenAI Codex CLI) directly. The vendor adapters, the deny-list, the known-good flag
combinations, the timeouts, the build staging worktree and the exit-code contract all live
in this one script. It was `agy-run.sh` until Wave 12; `install.sh` removes a leftover
installed copy of the old name.

```
Usage: ext-run.sh <review|read|verify|critique|fuzz|build> --prompt-file FILE
                  [--vendor agy|codex] [--level quick|builder|deep|top] [options]
```

`--vendor` defaults to `agy`, so pre-Wave-12 calls behave exactly as before.

### Models come from the tiers file, never from the script

Every model id and codex effort is read from the tiers file: `$TRIAGE_TIERS`, else
`triage-tiers.json` next to the script (the installed copy of `config/tiers.json`), else
`../config/tiers.json` (the repo). A missing or unparseable file is exit 2.

- Read-only modes resolve `modes.<vendor>.<mode>`; build resolves `levels.<level>.<vendor>`
  with `--level`, else `modes.<vendor>.build` (agy only).
- **An absent entry is a refusal (exit 3), never a default model.** Deleting a vendor's
  entry under a level is how that vendor stops being used there.
- `--model` overrides the resolved model but must belong to the vendor (agy `gemini-*`,
  codex `gpt-*`/`codex-*`); anything naming `claude` is always refused.
- `scripts/triage-tiers.sh` prints the level × vendor table and the latest parity note and
  flags `basis: "guess"` entries. `make tiers` (`scripts/tiers-sync.sh`) writes the Claude
  agents' `model:`/`effort:` frontmatter from the same file; `test/lint.sh` fails while the
  two disagree.

### Modes

| Mode | agy flags | codex flags | cwd | Timeout | Writes |
|---|---|---|---|---|---|
| `review` | — | `-s read-only` | staging dir | 8m | no |
| `read` | `--json-schema` with `--schema` | `-s read-only`, `--output-schema` with `--schema` | staging dir | 5m | no |
| `verify` | — | `-s read-only -c web_search="live"` | staging dir | 5m | no |
| `critique` | `--mode plan` | `-s read-only` | staging dir | 8m | no |
| `fuzz` | — | `-s read-only` | staging dir | 8m | no |
| `build` | `--mode accept-edits` | `-s workspace-write` | **disposable git worktree** | 20m | **yes** |

**agy, every mode:** an explicit non-Claude `--model`, `--sandbox`,
`--dangerously-skip-permissions`, `--output-format json`, `--print-timeout`, a
script-computed `--add-dir`, and `</dev/null`. Never `--effort` — agy encodes effort in the
model id and rejects the two together, so `--effort low|medium|high` rewrites the model-id
**suffix** instead (`gemini-3.1-pro` has no `medium` rung, so medium resolves to high there).

**codex, every mode** (verified live, codex-cli 0.155.1): `codex exec -C <rundir> -s <sandbox>
-m <model> -c model_reasoning_effort=<effort> -c sandbox_workspace_write.exclude_slash_tmp=true
-c sandbox_workspace_write.exclude_tmpdir_env_var=true --ephemeral --skip-git-repo-check
--ignore-user-config --json -o <last-message> - < <prompt>`. Never a `--dangerously-*` flag.
Without the two `/tmp` exclusions a workspace-write run can write anywhere under `/tmp` and
`$TMPDIR`. codex has no print-timeout, so a background watchdog enforces the mode timeout
(`--timeout N|Ns|Nm|Nh`). `--effort minimal|low|medium|high|xhigh` overrides the tiers
effort. codex auto-loads `~/.codex/AGENTS.md`, so its prompt gets a footer: non-interactive
worker, ask nothing, never touch `PROJECT_MEMORY.md`/handoffs/engram/memory files, touch only
the workspace.

Options: `--prompt-file FILE` (required), `--input FILE` (repeatable), `--schema FILE|JSON`
(read only), `--workdir DIR`, `--output FILE`, `--patch-out FILE`, `--check CMD` and `--level`
(build only), `--vendor`, `--model`, `--effort`, `--timeout`, `--raw`.

Data — diffs, logs, corpora — goes in with `--input`, never inlined into the brief: agy gets the
prompt as `-p "$(cat FILE)"`, which is `ARG_MAX`-bounded. A prompt file over 256 KB is a usage
error that names `--input`. Staged inputs are copied into the workspace and named in a
`--- Workspace ---` prompt footer by **absolute** path.

### Build mode never touches the caller's working tree

Neither CLI's flags can express "which files it may change" safely (agy needs
`--dangerously-skip-permissions`, and `--mode plan` is *not* a write guard), so build mode:

1. `git worktree add --detach <stage> HEAD` — a disposable checkout of `--workdir`'s repo;
2. carries the caller's uncommitted work in (`git diff HEAD --binary` applied with
   `--index`, plus every untracked file from `git ls-files --others --exclude-standard`);
3. commits that carried state as the stage base, so the result patch is the **pure model
   delta** rather than a re-application of the caller's own changes;
4. points the CLI (agy `--add-dir` + cwd, codex `-C` + cwd) at the worktree — never at the
   real repo; staged `--input` files go in `.<vendor>-inputs/`;
5. captures `git add -A && git diff --cached --binary` into `--output` (a `mktemp` file
   when `--output` is omitted; the path is always printed on stderr). `add -A` honours
   `.gitignore`, so a deliverable at an ignored path comes back as "no changes";
6. applies that patch back with `git apply` (and `git apply --3way` as a fallback for a
   tree that drifted while the CLI ran). `--index` is deliberately *not* used: it refuses
   any path whose worktree copy differs from the index;
7. removes the worktree on every exit path, including failures — `AGY_STAGE_KEEP` cannot
   defeat that.

The patch is captured before the result gates, so a failed run still leaves something
inspectable, and it is applied only if every gate passes.

**Compare support.** `--patch-out FILE` writes the patch to FILE and never applies it; it
refuses (exit 3) when the caller's tree has uncommitted or untracked changes, so every
candidate starts from clean HEAD. `--check CMD` runs CMD (`bash -c`) in the worktree after the
run passed its gates, after the patch was captured (check artifacts never enter it) and
outside the model sandbox; it prints `CHECK rc=<n>` plus the last 20 lines of output on
stderr and never changes the exit code.

### Exit codes (the contract every caller keys off)

| Code | Meaning | Caller action |
|---|---|---|
| 0 | OK — stdout is the model's answer (the raw envelope / JSONL events with `--raw`) | relay |
| 2 | USAGE — bad mode/flags/missing file/bad tiers file; nothing ran | caller bug, fail loud |
| 3 | REFUSED — deny-list hit, boundary not attested, vendor not listed in the tiers file for this level/mode, or `--patch-out` on a dirty tree; nothing ran | return `REFUSED: …` |
| 4 | UNAVAILABLE — CLI missing, non-zero exit, timeout, unparseable envelope, denied tools, non-SUCCESS status, a codex failure event, empty response, or the build stage could not be prepared | return `UNAVAILABLE: …`; never substitute your own work, never read as "no findings" |
| 5 | SCHEMA — `--schema` given and the response is not valid JSON | retry once or report INCOMPLETE |
| 6 | APPLY — build only: the patch did not apply to the real repo. The patch is left at `--output`; the answer still went to stdout | resolve by hand, or re-run |

**Exit 0 alone is never proof of work.** A headless agy run whose tools were auto-denied
exits 0 and reports `{"status":"SUCCESS","response":"","denied_actions":[…]}`; a
`--print-timeout` expiry looks the same. The agy gate therefore needs exit 0,
`.denied_actions` empty and `.response` non-empty. A failed codex turn emits `turn.failed` and
`{"type":"error"}` events, exits 1, and writes no `-o` file; the codex gate needs rc 0, a
non-empty `-o` file and no failure event. A codex rate limit is therefore UNAVAILABLE too.

### Deny-list and the data boundary

Applied to the resolved path of `--prompt-file`, `--workdir` (and its repo top level), a
`--schema` file, and every `--input`:

1. refuse if any **path component equals** a denied name — component equality, not
   substring, so `…/clip-creator/media` refuses and `…/clip-creators-lab` does not.
   `clip-creator` is hard-denied for every vendor; `AGY_DENY_REPOS` / `CODEX_DENY_REPOS`
   add names for one vendor;
2. refuse if the vendor's marker — `.agy-deny` (agy only) or `.codex-deny` (codex only) —
   exists anywhere from that path up to `$HOME`: a per-repo, per-vendor opt-out that needs
   no edit to this script;
3. refuse unless `AGY_BOUNDARY_CLEARED=1` (both vendors) — clinical/BCH/PHI and COI
   material is not a path pattern, so it stays an explicit caller attestation.

The workspace flag (`--add-dir` / `-C`) is **not** exposed as a caller option: the script
supplies exactly one value, its own run directory, after that path has passed the deny check.

This is a default-ALLOW list. In build mode the CLI may read any file in the repo, and agy
persists its own plan/walkthrough artifacts under `~/.gemini/antigravity-cli/brain/…`,
outside anything this script can clean up. Drop the vendor's empty marker into any tree you
have not consciously cleared for it.

### Environment

| Var | Effect |
|---|---|
| `AGY_BIN` / `CODEX_BIN` | executables (default: `agy` / `codex` on PATH) |
| `AGY_DENY_REPOS` / `CODEX_DENY_REPOS` | extra space-separated names that vendor must never see (`clip-creator` is always denied) |
| `AGY_BOUNDARY_CLEARED` | must be `1`, else REFUSED before anything runs (both vendors) |
| `AGY_STAGE_KEEP` | `1` keeps the staging dir (its path is printed on stderr). Never keeps the build worktree |
| `TRIAGE_TIERS` | the tiers file to read (overrides the installed and repo copies) |

Vendor-side token spend is invisible to `triage-usage.sh`, so each run echoes
`ext-run: <N> tokens (<S>s, <vendor>/<model>)[ out=<M>]` to **stderr**. `N` is the total
(codex: `input_tokens + output_tokens` summed over `turn.completed`; agy:
`.usage.total_tokens`). `out=` is the output side, reasoning included, which is what a bake-off
compares: codex `output_tokens` (reasoning tokens are already inside it); agy only when its
envelope carries a numeric `.usage.output_tokens`, otherwise the field is omitted, never guessed
(unverified whether agy 1.2.3 emits it).

### Requirements and tests

`bash` (3.2+, macOS default), `jq`, and `git` for build mode.

`test/ext-run.sh` (wired into `make test`) is hermetic: stub `agy` and `codex` executables
first on `PATH` replay canned envelopes / JSONL events and log their cwd, argv and prompt, so
the flag tables (codex's from a fixture tiers file), the deny-list, the exit-code contract,
the watchdog, `--patch-out`/`--check` and the whole build-worktree round trip are asserted
without ever reaching a real CLI or the network. It also covers `tiers-sync.sh` and
`triage-tiers.sh`.

## `patch-check.sh` — the independent grader of a bake-off

```
patch-check.sh --repo DIR --base REV --check CMD [--overlay DIR] [--timeout SECS] PATCH...
```

`workflows/triage-compare.js` runs one brief on several candidates (Claude levels, codex, agy),
each writing a patch. The candidates' own claims about their checks are never the grade; this
script is. For each PATCH, in argument order:

1. `git worktree add --detach` a fresh worktree of DIR at REV under a temp dir (hooks off);
2. `git apply --binary`, falling back to `git apply --3way` (a conflict is `applies:false`);
   an **empty** patch file applies trivially and is still checked;
3. copies `--overlay DIR` into the worktree after the patch: hidden tests the candidates
   never saw, kept out of the diffstat;
4. runs CMD (`bash -c`) from the worktree root under a wall-clock watchdog (default 600s;
   over time = rc 124);
5. removes the worktree and its `.git/worktrees` bookkeeping (`cleanup_wt()`, also on every
   exit path via the trap).

It prints one JSON line per patch on stdout:

```json
{"patch":"/abs/x.patch","applies":true,"rc":0,"diffstat":"1 file changed, 2 insertions(+)","tail":"<last 20 lines of check output>"}
```

`applies:false` means `rc:null` and the check never ran; `tail` says why (including "patch file
not found"). Exit 0 = every patch was graded; exit 2 = usage error (bad flag, not a repo,
unknown REV), nothing ran. It never touches the caller's working tree, index or HEAD.

`test/patch-check.sh` (wired into `make test`) runs it against scratch repos: applies+pass,
applies+fail, non-applying, empty, binary/new file, overlay visible to the check but absent from
the diffstat and the caller's tree, caller tree/index/HEAD untouched, worktrees cleaned (also
after a timeout), missing patch, usage errors. `qc/mutate.sh` #32 proves the cleanup assertion
has teeth.
