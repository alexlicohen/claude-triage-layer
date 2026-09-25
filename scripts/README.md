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

## `ext-run.sh` — the single owner of every external-CLI invocation (`codex`)

Nothing else in this repo, and no agent, may call `codex` (OpenAI Codex CLI) directly. The
adapter, the OS sandbox profile, the deny-list, the known-good flags, the timeouts, the build
staging worktree, the command audit log and the exit-code contract all live in this one
script. It was `agy-run.sh` until Wave 12; `install.sh` removes a leftover installed copy of
the old name.

**agy (Google Antigravity) was retired on 2026-09-24**: its headless mode let the model set a
per-command `BypassSandbox` flag, and a read-only parity review used it to copy a file into a
real repo. `--vendor agy` is exit 3 (`agy retired 2026-09-24`); leftover `.agy-deny` markers
are inert.

```
Usage: ext-run.sh <review|read|verify|critique|fuzz|build> --prompt-file FILE
                  [--vendor codex] [--level quick|builder|deep|top] [options]
```

`--vendor` defaults to `codex` (the only vendor).

### Models come from the tiers file, never from the script

Every model id and effort is read from the tiers file: `$TRIAGE_TIERS`, else
`triage-tiers.json` next to the script (the installed copy of `config/tiers.json`), else
`../config/tiers.json` (the repo). A missing or unparseable file is exit 2.

- Read-only modes resolve `modes.codex.<mode>`; build resolves `levels.<level>.codex` with
  `--level` (there is no `modes.codex.build`, so build without `--level` is refused).
- **An absent entry is a refusal (exit 3), never a default model.** Deleting codex's entry
  under a level is how it stops being used there.
- `--model` overrides the resolved model but must be a codex model (`gpt-*`/`codex-*`);
  anything naming `claude` is always refused.
- `scripts/triage-tiers.sh` prints the level × vendor table and the latest parity note and
  flags `basis: "guess"` entries. `make tiers` (`scripts/tiers-sync.sh`) writes the Claude
  agents' `model:`/`effort:` frontmatter from the same file; `test/lint.sh` fails while the
  two disagree.

### Modes

| Mode | codex flags (besides the common set) | Workspace | Timeout | Writes |
|---|---|---|---|---|
| `review` | — | staging dir | 8m | no |
| `read` | `--output-schema` with `--schema` | staging dir | 5m | no |
| `verify` | `-c web_search="live"` | staging dir | 5m | no |
| `critique` | — | staging dir | 8m | no |
| `fuzz` | — | staging dir | 8m | no |
| `build` | — | **disposable git worktree** | 20m | **yes** |

**Every run:** `cd <workspace> && TMPDIR=<stage>/cx/tmp sandbox-exec -f <profile> <codex>
exec -C <workspace> --dangerously-bypass-approvals-and-sandbox -m <model> -c
model_reasoning_effort=<effort> --ephemeral --skip-git-repo-check --ignore-user-config --json
-o <stage>/cx/last-message.txt - < <prompt>`, with `CODEX_HOME` unset. `<codex>` is the real
file `CODEX_BIN` names (a PATH lookup that never sees a shell function, symlinks resolved).
codex has no print-timeout, so a background watchdog enforces the mode timeout (`--timeout
N|Ns|Nm|Nh`). codex runs as its own process group (`set -m`; bash 3.2 has no `setsid`): the
watchdog signals the whole tree (frozen with STOP, leaves first) and the group, and after
every run `reap_tree` TERMs, then KILLs, whatever is left — a grandchild that ignores TERM or
outlives its exiting parent dies with the run. (A descendant that moves itself into a new
process group AND is orphaned escapes.) `--effort minimal|low|medium|high|xhigh|max`
overrides the tiers effort. codex auto-loads `~/.codex/AGENTS.md`, so its prompt gets a
footer: non-interactive worker, ask nothing, never touch `PROJECT_MEMORY.md`/handoffs/engram/
memory files, touch only the workspace, and "Your filesystem access is limited to this
workspace; other paths will fail - do not search the disk." (plus the `--allow-read` paths).

Options: `--prompt-file FILE` (required), `--input FILE` (repeatable), `--input-dir DIR`
(repeatable, read-only modes) with `--input-dir-max-mb N` (default 200), `--allow-read PATH`
(repeatable), `--schema FILE|JSON` (read only), `--workdir DIR`, `--output FILE`,
`--patch-out FILE`, `--check CMD` and `--level` (build only), `--vendor`, `--model`,
`--effort`, `--timeout`, `--raw`.

Data — diffs, logs, corpora — goes in with `--input`, never inlined into the brief: the sandbox
lets codex read only its workspace, so staging is the way in. A prompt file over 256 KB is a
usage error that names `--input`. Staged inputs are copied into the workspace and named in a
`--- Workspace ---` prompt footer by **absolute** path. A `--schema` (file or inline JSON; not
JSON = usage error) is copied into codex's scratch dir (it reads it inside the sandbox) in
**OpenAI-strict** form, because codex's `--output-schema` is strict structured output and the API
rejects anything else (codex exits 1: UNAVAILABLE). Every object with `properties` gets
`additionalProperties: false` and `required` = all its properties; a property the caller left
optional becomes nullable (`type` gains `"null"`, an `enum` gains `null`, `anyOf`/`oneOf` gain
`{"type":"null"}`). The reply is mapped back: a `null` under an originally-optional property is
dropped, so stdout has the shape the caller's schema describes. The caller's file is never
modified. When codex exits non-zero, the reason carries the API error (re-serialized onto one
line) and its stderr minus the `codex_skills_extension … failed to walk skills root` lines every
confined run logs.

`--input-dir DIR` stages a **copy of a whole tree** (a review snapshot: many files plus page
images) at `inputs/<basename>` and names it, with its file count, in the same footer. It is
checked before anything is staged, like `--input` and more: the deny check on DIR and on the main
worktree of the repo it sits in (exit 3); DIR is not `$HOME` or an ancestor of it (exit 3); no
deny-listed repo or `.codex-deny` marker anywhere beneath it (exit 3); **no symlink in it may
resolve outside it** — absolute, `../` or directory links alike (exit 3: a link out would smuggle
in whatever it names); links that stay inside are copied as links and still resolve inside the
copy; a special file (fifo, socket, device) is exit 2; a tree over `--input-dir-max-mb` (`du -sk`)
is exit 2 naming its size and the cap. Two staged inputs with one basename are exit 2. Read-only
modes only (build mode is exit 2). `triage-cross-reviewer` passes a brief's `INPUT_DIR=<dir>`
header line through as `--input-dir`.

### OS confinement (sandbox-exec) — fail closed

Staging controls what codex is *handed*, not what it can *reach*: codex's own seatbelt blocks
writes outside its workspace but not reads of the whole disk, its `sandbox_permissions` config
does not restrict reads, and an outer `sandbox-exec` does not nest with codex's own seatbelt
(every command rc 71 — the 2026-09-24 spike, codex-cli 0.156.1). So codex's sandbox is switched
off and **replaced** by a profile `write_profile` generates per run (SBPL, last match wins,
every path physical and escaped):

```
(version 1)
(allow default)
(deny file-read* (subpath "$HOME") (subpath "/private/tmp") (subpath "/private/var/folders")
                 (subpath "/tmp") (subpath "/var/folders"))
(deny file-read* file-write* (subpath <real repo>) (subpath <its git dir>) ...)   ; build only
(allow file-read* (literal "$HOME") (subpath "$HOME/.codex") (subpath <workspace>)
                  (subpath <stage>/cx) (subpath <each --allow-read>))
(allow file-read-metadata (literal <each ancestor of those paths>) ...)
(allow file-read* (literal "<per-user temp dir>/xcrun_db"))                          ; macOS
(deny file-write* (subpath "/"))
(allow file-write* (subpath "$HOME/.codex") (subpath <workspace>) (subpath <stage>/cx))
(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper")
                   (regex #"^/dev/fd/[0-9]+$") (literal "/dev/ptmx"))
(allow file-write* (require-all (regex #"^/dev/ttys[0-9]+$")
                                (extension "com.apple.sandbox.pty")))
```

**Reads.** Nothing under `$HOME` or the temp dirs — where a parallel compare's sibling
stages and patches, other concurrent ext-run stages and Claude session scratchpads
(`/private/tmp/claude-<uid>/…`) live — is readable but `$HOME` itself (the directory entry),
`~/.codex`, the workspace, `<stage>/cx` and each `--allow-read` path (which may sit in a temp
dir). The stage root and `<stage>/meta` are not: codex gets the prompt on stdin and writes
the event stream through inherited fds. The ancestors of the readable paths get
**metadata only** (stat, never a listing): `realpath()` in git and node `lstat()`s every
component and fails on a denied `/private/tmp` without it. One temp-dir file is readable,
never writable: xcrun's tool-path cache, without which every `/usr/bin/git`, `python3`,
`make`… shim takes ~2 s instead of ~20 ms; writable, it could redirect those shims for later,
unsandboxed sessions.

**Writes are deny-by-default:** nothing anywhere — a user-owned `/opt/homebrew`,
`/Users/Shared`, `/private/var/tmp`, mounted volumes — but `~/.codex`, the workspace,
`<stage>/cx` and these device files. Each was verified 2026-09-24 (macOS 26.6, codex-cli
0.156.1) with a kill-on-touch rule and the stub; hard links, clones, renames, symlinks,
fifos and Unix sockets outside the allowed dirs are denied too:

| Device | Why |
|---|---|
| `/dev/null` | every shell redirect (`>/dev/null 2>&1`) |
| `/dev/tty` | bash, sh and zsh open it at every start (also under git's and python3's xcrun shims); a headless run has no controlling terminal, so the open fails ENXIO exactly as unsandboxed |
| `/dev/dtracehelper` | dyld opens it at every process start (sh, bash, zsh, git, python3, node, codex) to register DTrace probes; no filesystem effect |
| `/dev/fd/N` | `> /dev/stdout`, `2> /dev/stderr`, `tee /dev/stderr`, `>(…)` process substitution |
| `/dev/ptmx`, `/dev/ttysN` | codex's `exec_command` allocates a PTY when the model passes `tty: true`; a tty is writable only if it was created inside the sandbox (the `com.apple.sandbox.pty` extension), so the user's own terminals stay unwritable |

`<stage>/cx` is codex's scratch (TMPDIR, the `-o` file, the schema copy). `<stage>/meta` —
the prompt, the `--json` event stream, stderr, the profile and the build worktree's hidden
`.git` — is neither readable nor writable by codex, so it cannot rewrite its own audit trail
or swap in a gitdir for this script's later (unsandboxed) git calls. In build mode the real
repo, its main worktree and its git dir are denied outright (this matters for repos outside
`$HOME` and the temp dirs, which no other read rule covers).

**Fail closed, no opt-out:** no `sandbox-exec` (Linux) is exit 4 before anything runs; a
preflight then runs `/bin/sh` under the profile and requires it to apply (exit 0) **and** to
enforce: its writes to two paths the profile denies must not land — the stage root (inside
the temp dirs) and `.ext-run-canary-<run id>` in `/Users/Shared` (else `/private/var/tmp`,
else `/var/tmp`), outside `$HOME` and the temp dirs, where only deny-by-default stops it. A
landed canary is removed, then exit 4 and codex never starts; no qualifying canary dir, or a
canary path that already exists, is exit 4 too. The canaries guard against an accidental
no-op or a regressed profile (the pre-2026-09-24 one passes the stage canary and is caught by
the outside one); whoever controls `PATH` controls `CODEX_BIN` as well.

`--allow-read PATH` widens reads only, and is refused (exit 3) when the deny check refuses
PATH, when PATH is `$HOME` or an ancestor of it (that would re-open every repo), or when a
deny-listed repo or a `.codex-deny` marker lies anywhere beneath it.

Known limits: `~/.codex` stays writable (auth refresh, logs), so a run could edit
`~/.codex/config.toml` or `~/.codex/AGENTS.md`, which ext-run ignores (`--ignore-user-config`)
but an interactive codex session would load. zsh here-documents write to `$TMPPREFIX`
(default `/tmp/zsh`), which is denied, so a `cat <<EOF` inside a `zsh -lc` command fails.

### Command audit log

codex runs `--ephemeral`, so nothing of what it ran would survive the stage. After every run
(also a failed or interrupted one) ext-run appends one JSONL line per `command_execution`
item of the `--json` stream — item.started/item.completed collapse to one — to
`$EXT_RUN_AUDIT_LOG` (default `~/.claude/logs/ext-run/codex-commands.jsonl`):
`{ts, runId, mode, model, cwd, command (first 500 chars), exitCode}`. **Never**
`aggregated_output` or any file content. The log is written by ext-run, outside the sandbox;
a dir that cannot be created is exit 4 before codex runs. Lines older than 30 days are pruned
opportunistically, under a `mkdir` lock concurrent runs share.

### Build mode never touches the caller's working tree

1. `git worktree add --detach <stage> HEAD` — a disposable checkout of `--workdir`'s repo;
2. carries the caller's uncommitted work in (`git diff HEAD --binary` applied with
   `--index`, plus every untracked file from `git ls-files --others --exclude-standard`);
3. commits that carried state as the stage base, so the result patch is the **pure model
   delta** rather than a re-application of the caller's own changes;
4. points codex (`-C` + cwd) at the worktree — never at the real repo; staged `--input`
   files go in `.codex-inputs/`. For the duration of the run the worktree's `.git` file —
   which names the REAL repo's gitdir — is moved into the script's private meta dir (not
   codex-writable), so codex cannot discover or write the real repository through git; it
   is restored (any `.git` the CLI created is discarded) before the capture, and always in
   the exit trap;
5. captures `git add -A && git diff --cached --binary` into `--output` (a `mktemp` file
   when `--output` is omitted; the path is always printed on stderr). `add -A` honours
   `.gitignore`, so a deliverable at an ignored path comes back as "no changes";
6. applies that patch back (`apply_back`, the single writer of the caller's tree) ONLY after
   a clean pre-check: `git apply --check` then `git apply`; else `git apply --3way --check`
   then `--3way` (for a tree that drifted while the CLI ran) — and since `--3way --check`
   exits 0 even when the merge *would* conflict ("Applied patch to 'f' with conflicts.",
   git 2.54), a 3-way check is clean only without "conflict" in its output. Anything else
   writes nothing: exit 6 with the tree byte-identical (one exception: a clean 3-way check followed by a failing `--3way` apply, a race with a concurrent edit — ext-run then says to inspect the tree). `--index` is deliberately *not*
   used: it refuses any path whose worktree copy differs from the index;
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
| 0 | OK — stdout is the model's answer (the JSONL events with `--raw`) | relay |
| 2 | USAGE — bad mode/flags/missing file/bad tiers file; nothing ran | caller bug, fail loud |
| 3 | REFUSED — deny-list hit, boundary not attested, codex not listed in the tiers file for this level/mode, a refused `--allow-read`, the retired agy vendor, or `--patch-out` on a dirty tree; nothing ran | return `REFUSED: …` |
| 4 | UNAVAILABLE — CLI missing, no `sandbox-exec` or a profile that does not apply/enforce, audit log dir not writable, non-zero exit, timeout, a codex failure event, empty response, or the build stage could not be prepared | return `UNAVAILABLE: …`; never substitute your own work, never read as "no findings" |
| 5 | SCHEMA — `--schema` given and the response is not valid JSON | retry once or report INCOMPLETE |
| 6 | APPLY — build only: the patch would not apply cleanly to the real repo, so NOTHING was written (the tree is unchanged). The patch is left at `--output`; the answer still went to stdout | resolve by hand, or re-run |

Every REFUSED/USAGE decision is made before any availability check, so a refusal is the same
exit 3 on a machine without `sandbox-exec`.

**Exit 0 alone is never proof of work.** A failed codex turn emits `turn.failed` and
`{"type":"error"}` events, exits 1, and writes no `-o` file; the codex gate needs rc 0, a
non-empty `-o` file and no failure event. A codex rate limit is therefore UNAVAILABLE too.

### Deny-list and the data boundary

Applied to the resolved path of `--prompt-file`, `--workdir` (and its repo top level), a
`--schema` file, every `--input` and every `--allow-read`. "Resolved" is the whole symlink
chain (`resolve_path`, bash-3.2 `readlink` loop), not just the parent dir, and the resolved
path is also the one that is read — a link in an allowed dir pointing into a denied repo is
refused, never followed:

1. refuse if any **path component equals** a denied name — component equality, not
   substring, so `…/clip-creator/media` refuses and `…/clip-creators-lab` does not.
   `clip-creator` is hard-denied; `CODEX_DENY_REPOS` adds names;
2. refuse if a `.codex-deny` marker exists anywhere from that path up to **and including**
   `$HOME` (or `/` for a path outside it): a per-repo opt-out that needs no edit to this
   script;
3. refuse unless `AGY_BOUNDARY_CLEARED=1` — clinical/BCH/PHI and COI material is not a path
   pattern, so it stays an explicit caller attestation (the name predates agy's retirement).

The workspace (`-C`, cwd, the profile's workspace rule) is **not** a caller option: the script
supplies exactly one value, its own run directory, after that path has passed the deny check.

### Environment

| Var | Effect |
|---|---|
| `CODEX_BIN` | the codex executable (default `codex` looked up on PATH); resolved to its real file |
| `CODEX_DENY_REPOS` | extra space-separated names codex must never see (`clip-creator` is always denied) |
| `AGY_BOUNDARY_CLEARED` | must be `1`, else REFUSED before anything runs |
| `AGY_STAGE_KEEP` | `1` keeps the staging dir (its path is printed on stderr). Never keeps the build worktree |
| `EXT_RUN_AUDIT_LOG` | the command audit log (default `~/.claude/logs/ext-run/codex-commands.jsonl`) |
| `TRIAGE_TIERS` | the tiers file to read (overrides the installed and repo copies) |
| `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_NAMESPACE`, `GIT_CEILING_DIRECTORIES` | **cleared** at the top (also by `patch-check.sh`, `stage-worktree.sh`, `parity-suite.sh`): an inherited absolute `GIT_DIR`/`GIT_WORK_TREE` (a git hook's environment) would otherwise redirect `git -C` into another repository |

Vendor-side token spend is invisible to `triage-usage.sh`, so each run echoes
`ext-run: <N> tokens (<S>s, codex/<model>) out=<M>` to **stderr**: `N` = `input_tokens +
output_tokens` summed over `turn.completed`; `out=` = `output_tokens` (reasoning included), the
part a bake-off compares.

### Requirements and tests

`bash` (3.2+, macOS default), `jq`, `sandbox-exec` (macOS) for any codex run, and `git` for
build mode.

`test/ext-run.sh` (wired into `make test`) is hermetic: a stub `codex` (a shell script living
in the test's `$HOME/.codex`) replays canned JSONL events and logs its cwd, argv, prompt and
whether it ran confined. On macOS every stub run goes through the REAL generated profile, and
the P* checks prove enforcement: workspace read/write works; a file under `$HOME/projects`,
writes to `$HOME` and `/private/tmp`, and writes to the private meta dir are denied; outside
`$HOME` and the temp dirs (`/private/var/tmp`, `/Users/Shared`) no file, dir, symlink,
rename-out or write through a hard link lands; with the stage under a real `/private/tmp`
fixture and `$HOME` elsewhere, a sibling stage, a sibling candidate's patch, a
Claude-scratchpad-like dir, a file in the per-user temp dir and the stage's own meta are
unreadable while the workspace and an `--allow-read` dir in the temp dirs stay readable; a
login zsh, git (init, realpath, commit), python3, a PTY and `/dev/fd` work; an
`--allow-read` dir is readable and read-only; in build mode the real repo (outside `$HOME`
and the temp dirs) and its git dir are unreadable and the hidden `.git` cannot be rewritten;
missing / non-applying / non-enforcing `sandbox-exec` is exit 4 with the stub never run —
including a double that stops only the stage canary and the real `sandbox-exec` on the old
allow-by-default write rule, both caught by the outside canary, which is then removed. Where
`sandbox-exec` does not exist (Linux CI) a NON-confining test double that forges the
preflight canary stands in, the enforcement checks SKIP, and everything else — the profile
text included — still runs. Also covered: the flag table, the
deny-list, `--allow-read` refusals, `--input-dir` (I*: a whole tree copied, links inside kept,
absolute / `../` / directory links out refused, deny-listed repos and markers in or above it,
`$HOME`, the size cap, special files, name collisions, read-only modes only), the audit log
(fields, no output, failed runs, prune), the exit-code contract, the watchdog, `--patch-out`/`--check`, the build-worktree round trip, symlink
chains, a marker at `$HOME`, an inherited `GIT_DIR`, a trailing option with no value, and
`tiers-sync.sh`/`triage-tiers.sh`. `qc/mutate.sh` proves the confinement, audit and agy-refusal
guards have teeth (#56–#59), deny-by-default writes, the temp-dir read rule and the outside
canary (#60–#62), the `--input-dir` outside-symlink refusal (#70), as well as the git-env,
symlink and apply-back guards (#49–#51).

**Known limitation — `--check` is not sandboxed.** The check command runs in the disposable
worktree with this user's full rights, OUTSIDE the model sandbox, and it may execute code
codex wrote (tests, Makefiles, scripts). The worktree is the only confinement. The same holds
for `patch-check.sh`. A seatbelt profile would close this, but would also block checks that
need LibreOffice (grant-forge's docx rendering), so it is deliberately not done.

## `patch-check.sh` — the independent grader of a bake-off

```
patch-check.sh --repo DIR --base REV --check CMD [--overlay DIR] [--timeout SECS] [--env-map FILE] PATCH...
patch-check.sh --print-env --check CMD [--env-map FILE]
```

`workflows/triage-compare.js` runs one brief on several candidates (Claude levels, codex),
each writing a patch. The candidates' own claims about their checks are never the grade; this
script is. For each PATCH, in argument order:

1. `git worktree add --detach` a fresh worktree of DIR at REV under a temp dir (hooks off);
2. `git apply --binary`, falling back to `git apply --3way` (a conflict is `applies:false`);
   an **empty** patch file applies trivially and is still checked;
3. copies `--overlay DIR` into the worktree after the patch: hidden tests the candidates
   never saw, kept out of the diffstat;
4. runs CMD (`bash -c`) from the worktree root under a wall-clock watchdog (default 600s;
   over time = rc 124), with the mapped `$PARITY_` tool variables exported (see **Parity env
   map** below) and `XDG_CACHE_HOME`, `TMPDIR` and `GRANTFORGE_CACHE_DIR` all pointed at a fresh
   per-patch dir beside the grading worktree (`<tmp root>/cache-<n>`, removed with it) — a check
   never refreshes a real user cache. grantforge honours `GRANTFORGE_CACHE_DIR` (its
   `config.cache_dir()`, whose default is `~/Library/Caches/grant-forge`, not XDG); the other two
   cover tools that follow XDG or `$TMPDIR`. (An old grant-forge base that still wrote its cache
   inside the package dir writes into the grading worktree, which is discarded.);
5. removes the worktree and its `.git/worktrees` bookkeeping (`cleanup_wt()`, also on every
   exit path via the trap).

It prints one JSON line per patch on stdout:

```json
{"patch":"/abs/x.patch","applies":true,"rc":0,"diffstat":"1 file changed, 2 insertions(+)","tail":"<last 20 lines of check output>"}
```

`applies:false` means `rc:null` and the check never ran; `tail` says why (including "patch file
not found"). `"error":"overlay-failed"` (with `applies:true, rc:null`) means the patch applied
but the `--overlay` copy failed, so the hidden tests are missing and the check was NOT run: the
patch is ungradable — `triage-compare.js` maps it to `invalid`, `parity-suite.sh verify-task`
to "neither base-fails nor solution-passes"; never a pass or a fail. `error` appears only then.
Exit 0 = every patch was reported; exit 2 = usage error (bad flag, a flag with no value, not a
repo, unknown REV, an unmapped `$PARITY_` variable), nothing ran. It never touches the caller's
working tree, index or HEAD.

### Parity env map — no real paths to candidates

Task checks are shown to candidates, so they never name a real tool path (a
`/Users/…/.venv/bin/python` tells a candidate where the source repo lives). A check names a tool
only as an env var **`PARITY_[A-Z0-9_]+`**, quoted as usual: `"$PARITY_PY_3DP" -m pytest`. The
**env map** — `--env-map FILE`, else `$PARITY_ENV_MAP`, else `~/.agents/parity/envs.json` — is a
JSON object mapping each variable to an absolute path:

```json
{"PARITY_PY_3DP": "/abs/parity/env/3dp/bin/python", "PARITY_MKDOCS_3DP": "/abs/parity/env/3dp/bin/mkdocs"}
```

`resolve_env()` in `patch-check.sh` is the one owner of the rule: it collects every
`$PARITY_…`/`${PARITY_…}` reference in CMD (bash's full name, so `$PARITY_py` is refused, not
read as `PARITY_`), and exits 2 naming the variable when it is unmapped, when there is no map,
or when the map is not `{"PARITY_<NAME>": "/abs"}`. A check that references none never reads the
map. The mapped values are exported into the check at grading, OUTSIDE any sandbox. `--print-env`
prints the same resolution as `export PARITY_X='…'` lines (`parity-suite.sh` materialize and
verify-task call it). Candidates see the checks with the variables UNEXPANDED; only a task with
`"selfCheckEnv": true` lets them run the checks themselves (see `parity-suite.sh`) — the
trade-off: `.parity-env` reveals tool paths, never repo content.

The check runs as its own process group; on timeout the whole tree is killed, and after every
check `reap_tree` kills anything it left running (a background server, a TERM-ignoring child)
before the worktree is removed. **Not a sandbox:** the check executes candidate-written code
(tests, Makefiles) with this user's rights, confined only by the disposable worktree — see the
`--check` limitation under `ext-run.sh`; a seatbelt profile would block LibreOffice-based checks.

`test/patch-check.sh` (wired into `make test`) runs it against scratch repos: applies+pass,
applies+fail, non-applying, empty, binary/new file, overlay visible to the check but absent from
the diffstat and the caller's tree, caller tree/index/HEAD untouched, worktrees cleaned (also
after a timeout), missing patch, usage errors (incl. a trailing flag with no value), overlay
copy failure (`overlay-failed`), an inherited decoy `GIT_DIR`, grandchildren killed (timeout and
normal exit), the env map (export with quoting intact, `PARITY_ENV_MAP`, `--env-map` precedence,
unmapped / missing map / invalid map / bad name => exit 2 before anything runs, a map-free check
never reading it, `--print-env`) and the per-patch cache dir (all three variables, one dir per
patch beside its worktree, removed). `qc/mutate.sh` #32, #48, #63 (unmapped variable ignored) and
#66 (cache env not set) prove those assertions have teeth.

## `stage-worktree.sh` — the staging area of a bake-off

```
stage-worktree.sh create    --repo R --base REV --count N --dir D
stage-worktree.sh diff      --worktree W --base SHA --out FILE
stage-worktree.sh leakcheck --repo R --dir D
stage-worktree.sh cleanup   --repo R --dir D
stage-worktree.sh apply     --repo R --patch P
```

`workflows/triage-compare.js` never gives a candidate the real repo as its working directory.
`create` resolves REV to a sha **once**, fingerprints R (HEAD, `status --porcelain=v1 -uall`,
and a content manifest of every tracked + untracked non-ignored path), and makes N detached
worktrees `D/wt-1..N` at that sha (hooks off). D must be absolute, outside R, not containing R,
and absent or empty; it prints `{sha, worktrees, fingerprint, head, repo}`. Candidate *i* works
in `D/wt-i` — a wrapper that drops a flag, or an ext-run that applies its patch back, lands in
a throwaway checkout, and a moving HEAD in R no longer moves anyone's base.

`diff` is `git add -A` + `git diff --binary --cached SHA` in a staged worktree (new, deleted and
binary files included; FILE removed first, so a stale patch never survives a failed diff). It
refuses a main working tree, so it can never stage into R's index. `leakcheck` compares R with
the fingerprint: `CLEAN` (exit 0); `LEAK` (exit 7) when, with HEAD unchanged, the status or any
path's content changed, or, with HEAD moved, any path's content changed; `BASE_MOVED` (exit 0,
flagged) when someone committed and nothing else changed — grading stays at the recorded sha.
`cleanup` removes each staged worktree and its bookkeeping, prunes, and deletes D; it refuses a
D without a fingerprint. Every step prints one JSON line; except for `apply`, R's working tree
and index are only ever read (`--no-optional-locks`).

`apply` is the one deliberate write into R: an inline bake-off's fallback applies the chosen
candidate's patch P. Only an apply proven clean first is written: `git apply --check` then
`git apply` (index-free, so unrelated unstaged/untracked work does not block it); else `git apply
--3way --check`, which exits 0 even when the merge WOULD conflict, so it counts as clean only
with rc 0 **and** no `conflict` in its output, then `git apply --3way`; else nothing is written
and the exit is **6** with R byte-identical. An empty P is a no-op success. It prints
`{step:"apply", repo, patch, ok, applied, method: plain|3way|empty|none, error?}`. The rule
mirrors `ext-run.sh`'s `apply_back()` on purpose instead of sharing a helper: ext-run stays
self-contained (single owner of every external-CLI run, its own exit-6 contract and
diagnostics), and a runtime dependency from that danger-zone script on this one was judged
worse than a three-command rule kept in two places. Each copy has its own conflict-marker
mutation (#51 ext-run, #55 here).

`test/stage-worktree.sh` (wired into `make test`): sha resolution, worktrees at the exact sha,
refusals (D inside/containing R, populated D, relative D, unknown REV), a diff with
new/modified/deleted/binary files that applies cleanly at the sha through `patch-check.sh`, an
empty diff still checked, diff refusing the main tree and never leaving a stale patch, leakcheck
CLEAN / LEAK (tracked edit, untracked file, content change to an already-dirty file) /
BASE_MOVED (including committing pre-existing work), cleanup leaving no worktree registered, and
R's tree, index bytes and HEAD untouched; `apply` with a clean patch, a drifted tree recovered by
a clean 3-way merge, a conflicting patch (exit 6, tree incl. untracked/unstaged work and index
byte-identical, no markers), an empty patch and a relative path. `qc/mutate.sh` #39 proves the
new-file capture has teeth, #55 the apply conflict pre-check.

## `review-stage.sh` — the staging area of a review bake-off

```
review-stage.sh snapshot    --repo R --base B --head H --include GLOB... [--exclude GLOB...]
                            [--context PATH...] [--extra SRC:DEST...] [--hard-exclude PATTERN...]
                            --out DIR
review-stage.sh fingerprint --repo R --path P... [--hard-exclude PATTERN...] [--out FILE]
review-stage.sh compare     A.json B.json
```

A multi-value flag takes every argument up to the next `--flag` (and may repeat). Globs are git
pathspecs with `:(glob)` magic relative to the repo root (`*` stays in one directory, `**/` spans
any depth, so `docs/**/*.md` matches `docs/a.md`; a directory matches everything below it); no
leading `/`, `-` or `:`, no `.`/`..` components.

`snapshot` resolves B and H to shas and writes, into a DIR that is absolute, outside R, not
containing R and absent or empty: `DIR/snap` — the files of **commit H** (`git archive H`, never
the live tree, no `.git`) selected as (include − exclude) + context, symlinks and submodules
dropped, each `--extra SRC:DEST` (an absolute regular file **outside** R, e.g. a CAD cache) copied
to `snap/_extra/DEST`; `DIR/range.diff` — `git diff B H` over (include − exclude), no renames, no
external diff/textconv, `a/`/`b/` prefixes; `DIR/manifest.json` — `{base, head, baseRef, headRef,
include, exclude, context, hardExclude, files:[{path,bytes}], extras:[{src,dest,bytes}],
excluded:[{path, reason: hard-exclude|symlink|submodule, pattern?}], codexDenied}`. It prints one
JSON line `{step, ok, base, head, snap, diff, manifest, files, bytes, diffBytes, extras, excluded,
codexDenied}`; a failure removes what it wrote.

**Hard excludes** — `context/` and `PROJECT_MEMORY*.md` always, plus each `--hard-exclude` — are
applied to everything written into DIR whatever git thinks of the path (tracked, ignored or
untracked) and whatever `--include`/`--context` name. gitignore semantics, erring wide: a pattern
with no inner slash matches **any** path component (`context/` also drops `docs/context/x.md`); one
with a slash is anchored at the repo root and its `*` may cross directories. A hard-excluded path
is never archived and never in range.diff (only its name, in `manifest.excluded`); an `--extra`
whose DEST, or any component of whose SRC, matches is refused (exit 2). **Deny carries over:** when
R (or its main worktree) or an extra SRC is under a hard-denied repo (clip-creator), or a
`.codex-deny` marker lies inside R or on the way up to `$HOME`, DIR gets a `.codex-deny` of its
own — `ext-run.sh` then refuses the snapshot and the diff for codex exactly as it would the repo;
Claude reviewers may still read them.

`fingerprint` is the review's SOURCE_CHANGED guard, scoped to its paths: `{step, head, paths,
status (git status --porcelain=v1 -uall --no-renames -- paths), tree (a hash over the content of
every changed/untracked path there, so a second edit to a dirty file counts), committed (a hash
over HEAD's blobs at the paths)}`, hard-excluded paths left out of all three, read-only
(`--no-optional-locks`). `compare` exits 0 when status, tree and committed are equal — a change
outside the paths, or HEAD moving by a commit outside them, is no change (`headMoved` says so) —
and **7** otherwise, printing `{step, same, changed, headMoved, detail}`.

Exit codes: 0 ok / same; 1 the step failed; 2 usage, nothing written; 7 compare: changed.
`test/review-stage.sh` (in `make test`): the archive of H, never live edits or untracked files;
include/exclude/context; hard excludes winning over include, context and tracking at any depth,
in the snapshot and the diff, with the manifest listing them; symlinks dropped; extras (and their
refusals); range.diff byte-equal to `git diff B H` of the included paths; out-dir refusals; the
deny carry-over; R untouched; fingerprint scoping and compare codes; `HARD_DENY_REPOS` equal to
ext-run.sh's. `qc/mutate.sh` #67 proves the hard exclude holds for tracked paths.

### The review bake-off (`triage-compare` kind `review`)

`Workflow({name:'triage-compare', args:{kind:'review', repo, repoName, base, head?, include,
exclude?, context?, extras?:[{src,dest}], hardExclude?, groundTruth, accepted?, conventions?,
outDir, reviewers:[{vendor, level, model?, effort?, label?}], adjudicators?, batchSize?:10,
reviewerTimeout?:'30m', adjudicatorTimeout?:'15m', extend?, supersedes?}}`:

1. one quick task runs `review-stage.sh snapshot` and `fingerprint` (to
   `<outDir>/fingerprint-before.json`); a failed snapshot throws before any reviewer;
2. every reviewer runs **in parallel** on the snapshot + range.diff only — Claude: its level's
   agent (model/effort passed through) with a findings schema, told to read nothing else, to
   prefix every command with `cd <snap> && `, never to run git, and that it may view images;
   codex: `triage-cross-reviewer` with `VENDOR=codex MODE=read MODEL= EFFORT= INPUT_DIR=<snap>`
   and `--input range.diff` (codex reviewers must pin model **and** effort: read mode's default
   model is the read-mode one, not the level's). Every codex spawn (reviewer or adjudicator) also
   carries `TIMEOUT=` (reviewers `30m`, adjudicators `15m`, overridable; N|Ns|Nm|Nh up to 3h —
   ext-run's read default of 5m killed a 144 MB snapshot review) and `PROMPT_BYTES=` = the UTF-8
   byte length of the prompt-file body (the text after the `…goes into the prompt file ---`
   marker, plus one final newline): `triage-cross-reviewer` writes the body into a private
   `mktemp -d` dir, normalizes the relay's two-space indent, checks `wc -c`, rewrites once and
   otherwise returns `REFUSED: prompt not verbatim` — an LLM wrapper is never trusted to carry a
   brief verbatim. Findings: `{file, line, severity:
   blocker|major|minor, category, claim, evidence (a ground-truth path/page), suggestedFix}`.
   Every prompt carries groundTruth, conventions and accepted deviations verbatim ("do not flag
   these unless you cite NEW ground-truth evidence"; a summary or replacement text is never
   ground truth), and the same note for both vendors that image links in the markdown are
   URL-encoded (`%5B` = `[` …) and must be decoded before opening. The live repo path and repo name appear in no reviewer, merge or adjudicator
   prompt. A reviewer that fails or returns no valid findings JSON is **unavailable** — never
   scored as zero; malformed single findings are dropped and flagged;
3. one deep merge agent clusters duplicates over opaque finding ids (it sees no reviewer label or
   id); membership is enforced by the workflow, which keeps the provenance (anonymized `R1..Rn`,
   label-blind order);
4. items (ids `M1..` in file/line order) go in batches to each adjudicator (default: claude deep
   opus·high + codex deep gpt-6-astra·high, i.e. `levels.deep` — `make lint` checks the pair
   against tiers.json), **blind** to labels, reviewer ids and provenance, reading only the
   snapshot; verdict per item `real | not-real | accepted-deviation | unsure` with evidence; a
   failed batch is retried once. Every adjudicator real → **real**; every one not-real or
   accepted-deviation → **rejected**; unsure, a missing verdict or any disagreement →
   **disputed** (for Alex);
5. per reviewer, over non-disputed items only: precision = its real / its adjudicated, recall =
   its real / all real (null when the denominator is 0), plus findings, real, rejected,
   disputed, tokens and seconds (codex from its ext-run line; parallel Claude spawns have none);
6. a final quick task re-fingerprints and runs `compare`: `sourceChanged` true is flagged
   SOURCE_CHANGED but is informational — every reviewer read the pinned snapshot.

Returns `{kind:'review', repoName, base, head, outDir, reviewers, items:[{id, file, line, severity,
category, claim, evidence, suggestedFix, verdict, adjudication, foundBy}], disputed, sourceChanged,
mergeFallback, flags, markdown}` — the markdown lists real items by file, then the disputed ones
with both adjudicators' evidence, the rejected, and the score table. ⚠ Fable before any top-level
Claude reviewer or adjudicator; a snapshot carrying `.codex-deny` makes every codex reviewer and
adjudicator unavailable without a spawn. Nothing is applied, nothing written outside outDir.
Known limit: an adjudicator of the same model as a reviewer judges its own kind of finding blind,
not independently. `test/compare-scenarios.mjs` RV* covers it; `qc/mutate.sh` #68 (provenance
reaching an adjudicator) and #69 (a disputed item scored as real) prove the blind + scoring rules.

**Extending a review** (`extend: '/abs/prior-result.json'`, outside repo; `supersedes?:
[labels]`): re-pass the prior run's args (same groundTruth/conventions/accepted, `outDir` = the
prior outDir, `base`/`head` resolving to the prior shas — pass the shas) with **only the new
reviewers**. Instead of a snapshot, one quick task runs one `jq` command over the prior result,
`<outDir>/manifest.json`, `snap/`, `range.diff` and `git rev-parse` of base/head, and relays its
JSON; the workflow recomputes the command's digest (UTF-8 bytes of every string + sum of every
number in items and reviewers) and refuses — after one retry, before any reviewer — a relay that
is not verbatim, a base/head or outDir/repoName that is not the prior's, or a snapshot that is
gone or not the prior's. Also refused: a new label colliding with a prior one, `supersedes`
naming no prior reviewer, and adjudicators other than the prior panel. The merge agent sees the
prior items (ids + text, never verdicts or provenance) and the new findings: each new finding
**attaches** to a prior item (its reviewer joins `foundBy`; text, verdict and adjudication stay —
never re-adjudicated) or joins a **new item** numbered after the prior ids (`M31…`). Only new
items are adjudicated (same blind panel). Every reviewer not superseded — prior ones included — is
rescored over the combined items (a new real item lowers everyone's recall who missed it);
superseded runs stay in `reviewers` with `status: 'superseded'`, `priorStatus`, no scores, and
their findings stay in the items. The re-fingerprint goes to `fingerprint-extend.json`. Returns the
normal shape plus `extendedFrom`, `newItems`, `superseded`; prior flags are carried as `prior
run: …`; the markdown is regenerated for the combined set with an "Extended with" line. EX* covers
it (EX10 runs the loader's real `jq`/`git` command on a synthetic prior); #72 (attached items
re-adjudicated), #73 (a superseded reviewer scored) and #74 (a codex spawn without TIMEOUT) prove
it. `ingest-review` counts a superseded row as unavailable, and derives the run id from the
outDir basename — pass `--run` when ingesting an extension of an already-ingested review.

## `parity-suite.sh` — the task suite of a parity run

```
parity-suite.sh list         --suite DIR
parity-suite.sh materialize  --task DIR --out DIR [--env-map FILE]
parity-suite.sh verify-task  --task DIR --out DIR [--env-map FILE]
parity-suite.sh fingerprint  --task DIR
parity-suite.sh score-review --key FILE --findings FILE
```

`workflows/triage-parity.js` ranks candidates (vendor × model × effort) on a task suite. The suite
is private data kept **outside this repo** (planned at `~/.agents/parity/tasks`); this repo only
ships the machinery and three tiny synthetic fixtures (`test/fixtures/parity/suite`).

**Task format.** `<suite>/<band>/<id>/task.json` (`<band>` is `N` or `bN`, and must equal `band`;
`<id>` must equal `id`). Every path in it is relative to the task dir and may not leave it.

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | file-name-safe, unique in the suite |
| `band` | yes | 1–4 (B1 mechanical … B4 danger zone / judgment) |
| `kind` | yes | `build` (implement) or `review` (find seeded defects) |
| `source` | yes | `{type:"git", repo:"/abs/path", base:"<sha>"}` or `{type:"generator", script:"gen.sh"}` |
| `setup` | no | a patch applied at base and committed as the task's starting point |
| `brief`, `acceptance` | yes | what the candidates are told |
| `files` | yes | non-empty; the files the candidates may touch (build) or review |
| `checks` | build | shell commands run from the materialized repo root; the grade. Tools only as `"$PARITY_<NAME>"` (see **Parity env map** under `patch-check.sh`) |
| `overlay` | no | a dir (e.g. `hidden/`) copied only into GRADING worktrees — hidden tests |
| `solution` | build, for `verify-task` | the reference fix; never shown to candidates |
| `grading` | yes | `check` (the checks), `rubric` (checks + two blind judges vs the key), `seeded` (review tasks only) |
| `key` | rubric/seeded | `key.md`/`key.json` (rubric), `key.json` = `[{file,line,id,desc}]` (seeded) |
| `vendors` | yes | subset of `claude`, `codex` allowed on this task (`agy`, retired 2026-09-24, is still tolerated in older task files) |
| `timeoutMin` | no | per-check wall clock for `verify-task` (default 10) |
| `selfCheckEnv` | no | `true` = candidates get `.parity-env` so they can run the `$PARITY_` checks themselves (reveals tool paths, never repo content); default: they cannot |

**No real paths to candidates.** `brief`, `acceptance` and every `checks` entry are what
candidates see, so `list` (and every command that loads a task) rejects one naming a path under
`$HOME` — lint-style: `/Users/`, `~/`, `$HOME`/`${HOME}`, or the actual home dir — exit 2 naming
the field. `source.repo` is exempt: it is never shown to a candidate.

`list` prints every task (task.json + `taskDir`) sorted by band then id; any invalid task, or a
duplicate id, is exit 2 naming it. `materialize` builds `<out>/repo`: a git source is
`git clone --local --no-checkout`, detached at `base`, with the origin remote removed (nothing
can be pushed back); a generator is run as `<taskDir>/gen.sh <out>/repo` and must leave a clean
repo with at least one commit. `setup.patch` then becomes ONE commit. Identity, dates and git
config are fixed for every commit it makes (and for a generator's), so the same task always
gives the same sha. It never writes into the source repo, refuses an `--out` inside the source
or the task dir, rebuilds an `--out` it made before and refuses any other non-empty one.

**Deny propagation.** A clone's git-common-dir is the clone itself, so `ext-run.sh` — the owner
of every deny decision — would no longer see the source's `.codex-deny` markers or its
`CODEX_DENY_REPOS` names. `materialize` therefore refuses (exit 3) any source or task path with
a `clip-creator` component (`HARD_DENY_REPOS`, kept equal to ext-run's by a test), and writes
`<out>/.codex-deny` when the source is denied to codex (the same walk as ext-run: up to and
including `$HOME`; the source paths are kept as an array, so a path with spaces keeps its
status). ext-run finds that marker walking up from the clone and from any worktree of it
(triage-compare's staged worktrees). It prints `{repo, sha, denied:{codex}}`, `denied` being
what ext-run will see. (`.agy-deny` markers are no longer propagated: agy was retired
2026-09-24.)

**Env and `.parity-env`.** `materialize` resolves the task's checks against the env map first
(`patch-check.sh --print-env`; an unmapped variable is exit 2 naming it, nothing made). Only a
task with `"selfCheckEnv": true` gets `<out>/repo/.parity-env` — the `export PARITY_X='…'` lines
for the variables its checks use — and `/.parity-env` in the repo's `.git/info/exclude`. The
exclude lives in the common git dir, so it holds in every worktree of the repo: triage-compare
(`selfCheckEnv: true`) copies the file into each staged worktree, candidates are told
`To run the checks yourself, first run: . .parity-env`, and the file never enters a diff.
Without the opt-in, candidates are told the checks run only at grading.

**Source-repo leak guard.** `fingerprint` prints, for a git source,
`{id, source:"git", name, head, tree}`: `name` is the repo directory's name (never its path),
`head` its HEAD sha, `tree` one hash over `git status --porcelain=v1 -uall` and the content of
every modified or untracked non-ignored file (so a second edit to an already-dirty file changes
it too); everything runs with `--no-optional-locks`, so not even the index is refreshed. A
generator source prints `{id, source:"generator"}` (nothing to guard). triage-parity takes it
before a task's candidates run (in the materialize spawn, before materializing — no valid
fingerprint, no run) and after grading, for EVERY task kind (build, rubric, review): any
difference voids every result of the task (`invalid`, reason and flag
`SOURCE_CHANGED <name>: HEAD moved|tree changed`); no after-fingerprint (one retry) is
`SOURCE_UNVERIFIED`, also invalid. The run continues — a concurrent human commit is possible, so
the flag tells the orchestrator to investigate rather than aborting.

`verify-task` materializes, then for a build task runs `patch-check.sh` twice — an empty patch
(the base) and `solution.patch`, both with the overlay and the env map's variables exported — and prints
`{id, kind, sha, baseFails, solutionPasses, ok}`: `ok` needs the base to FAIL (the task is not
pre-solved) and the solution to PASS. For a review task it checks the key is a non-empty seed
list whose files exist at the sha. Exit 0 = ok, 1 = not.

`score-review` is deterministic: a finding `{file, line, desc}` matches a seed `{file, line,
id, desc}` when the file is the same (`./x` and an absolute path ending in `/x` count) and the
lines are at most 3 apart; pairs are assigned closest-first, each seed and each finding at most
once. It prints `{recall, precision, matched:[seed ids], seeds, findings}` (no findings =>
precision 0). triage-parity passes a review at recall ≥ 0.6 and precision ≥ 0.5.

Exit codes: 0 ok; 1 the step failed; 2 usage error or invalid task; 3 refused (deny-listed).
`test/parity-suite.sh` (in `make test`) covers every subcommand on the synthetic fixtures,
including the real `ext-run.sh` refusing a clone of a marked source (stub CLIs that must not
run), the `$HOME`-path lint, the env map through verify-task (exported, unmapped => exit 2),
`.parity-env` only on opt-in and never in a staged worktree's diff, and `fingerprint` (HEAD move,
tracked/re-edited/untracked changes, generator, clip-creator, missing repo). `qc/mutate.sh` #44
proves deny propagation has teeth; #64 (review tasks not re-fingerprinted) and #65 (judges handed
a repo path) cover the workflow side in `test/parity-scenarios.mjs`.

## `parity-report.sh` — the parity ledger and the tier-change decision rule

```
parity-report.sh ingest-compare --result FILE --repo-name NAME --level L --source inline|suite
                                [--task ID] [--applied LABEL] [--run ID] [--ts ISO]
parity-report.sh ingest-parity  --result FILE [--ts ISO]
parity-report.sh ingest-review  --result FILE --repo-name NAME [--resolved FILE] [--run ID] [--ts ISO]
parity-report.sh migrate        [--from ~/.agents/evidence/vendor-parity.jsonl]
parity-report.sh report         [--json]
      every subcommand also takes [--ledger F] [--tiers F]
```

Single owner of the ledger schema and of the rule that turns outcomes into a **proposed**
`config/tiers.json` change. `triage-parity.js` and inline bake-offs only produce results; the
orchestrator saves a result as JSON, ingests it here, then runs `report`. It never writes
tiers.json (a `--ledger` that is the tiers file is refused) — Alex approves every change.

**Config.** `tuning` in the tiers file, read through `triage-tiers.sh --bakeoff-json` (the one
validator; also what the orchestrator passes to triage-exec as `args.bakeoff.config`):
`sampleRate`, `challengerMix` (vendor shares, sum 1), `challengers` (`level → vendor → [{model,
effort}]`), `rule {minN, cheaperTolerance, pricierMargin, confidence: "wilson95"}`, `ledger`
(default path, `~` expanded) and `pauseAtWeeklyPct`. An invalid or missing block is exit 2 for
every subcommand and a `make lint` failure.

**Ledger** (JSON lines, schema v 1) — scores and metadata only, never patch contents, briefs,
checks, tails, diffstats or paths from the target repo (`repoName` is a bare name; `task`, `run`
and labels are id tokens; anything else is refused with exit 2 and nothing written):

```
{"v":1, "ts":"<ISO>", "source":"inline|suite", "run":<id|null>, "repoName":"<name>",
 "level":"quick|builder|deep|top", "band":<1-4, suite lines only>, "task":<id|null>,
 "candidates":[{"label","vendor","model","effort","status","totalTokens","seconds"}],
 "applied":<label|null>, "migrated":"vendor-parity.jsonl" (migrated lines only)}
```

`status` is `pass`/`fail` (graded) or the candidate's own non-graded status (`unavailable`,
`invalid`, `denied`, `unresolved`, `ungraded`, `skipped`, else `unknown`) — never turned into a
fail. A null model/effort is filled at ingest from `levels.<the candidate's level>.<vendor>`,
which is exactly what ran (agents and ext-run default to that entry). `ingest-compare` writes one
line per compare (`--level` = the planned level). `ingest-parity` writes one line per **graded**
(task, candidate run), `level` = the band's level (B1 quick … B4 top), `run` = the outDir
basename; a run already in the ledger is skipped. `migrate` converts the legacy evidence file
best-effort: a compare line → one line; a parity aggregate → one pass/fail line per counted
outcome per band (it had no task ids or per-task tokens; models resolved from the label via the
tiers file); idempotent by run id.

`ingest-review` takes a `triage-compare` kind `review` result and writes **one** line with
`source: "inline-review"` and no `candidates` (so it can never enter the build rule):

```
{"v":1, "ts", "source":"inline-review", "run":<id|null>, "repoName",
 "reviewers":[{"label","vendor","level","model","effort","status":"ok|unavailable","precision",
   "recall","n","real","rejected","disputed","findings","totalTokens","seconds"}],
 "items":<merged items>, "real":<real items>, "disputed":<still disputed>, "resolved":<by Alex>}
```

Scores are **recomputed here** from the items' verdicts and `foundBy` after applying `--resolved`
(Alex's verdicts for disputed ids, `{"M3":"real","M7":"not-real"}`; an id that is not a disputed
item, or any other value, is exit 2): precision = real / (real + rejected) with `n` = that
denominator, recall = real / all real, null for a zero denominator; an unavailable reviewer keeps
null scores and n 0. No file path, claim, evidence, flag or markdown reaches the ledger. Run id =
`--run`, else the result's outDir basename; a run already in the ledger is skipped — resolve the
disputes first, then ingest once.

**Rule** (`report`). Groups graded outcomes per level × vendor × (model, effort): n, passes,
rate, Wilson 95% lower bound, excluded (non-graded) count, mean tokens and seconds. Per level ×
vendor the incumbent is `levels.<level>.<vendor>`; every other (model, effort) there is a
challenger. Cheapness: claude haiku < sonnet < opus < fable; codex gpt-6-luna < gpt-6-sol <
gpt-6-astra; agy flash < pro (agy is retired and has no levels entry: historical ledger rows
still validate, and it is never an incumbent or proposed); then effort low < medium < high <
xhigh < max.

| Case | Verdict |
|---|---|
| either side has n < minN | `insufficient-data`, naming the graded runs still needed on each side |
| cheaper challenger | `propose` iff its Wilson LB ≥ incumbent rate − cheaperTolerance, else `keep` |
| pricier challenger | `propose` iff its rate − incumbent rate ≥ pricierMargin, else `keep` |
| unknown model / same cost | `unranked`, never proposed |

One proposal per level × vendor: a qualifying pricier challenger first (quality; highest rate,
then cheapest), else the cheapest qualifying cheaper one. Markdown by default (a table per
level, the decisions with their reasons, the proposals, then a separate **Reviews
(inline-review)** section: per vendor × model × effort, reviews, mean precision and mean recall
(each with its n) and unavailable count — never mixed into the build pass rates, and "Review
metrics do not drive tier proposals yet"); `--json` gives `{ledger, tiers, lines, malformed, rule,
groups, decisions, proposals, reviews: {lines, groups, note}, note}`. Malformed ledger lines are
counted, not fatal.

Exit codes: 0 ok; 1 ledger write failed; 2 usage / invalid input / invalid tiers file (nothing
written). `test/parity-report.sh` (in `make test`) covers both ingest shapes, the refusals,
no-repo-content, migrate + idempotence, Wilson bounds, every rule branch, exclusions and that
tiers.json is never written, and (RV*) ingest-review: the line schema, recomputed scores with
and without resolutions, unavailable never zero, no review content, idempotence, and a report
whose build groups/decisions/proposals are byte-identical with or without review lines; `qc/mutate.sh`
#43 (cheapness order), #52 (minN), #53 (Wilson LB vs point rate) and #54 (non-graded status as
fail) prove the rule has teeth.

## `parity-cost.sh` — Claude cost per parity candidate

```
parity-cost.sh DIR...
```

Sums the Claude usage of a workflow run from its transcripts: every `agent-*.jsonl` below DIR
(pass the run's `.../subagents/workflows/wf_<id>/` dir; a parent dir sums every run under it),
labelled from `agent-*.meta.json`'s `description`. Billing-style sums — input, cache read,
cache write, output — per agent label, per model, and per parity candidate: agents labelled
`candidate:<label>` (triage-compare) or `candidate:<label>@<task>` (triage-parity reviewers)
fold onto `<label>`, with a `-r<N>` repetition suffix removed; everything else (loaders,
graders, judges, cleanup) is `overhead`. Claude Code repeats a message id across content-block
lines with a growing usage object, so each id counts once with the max of each field.

This is a different cut from `triage-usage.sh`, which keeps the per-tier PEAK-context proxy;
the per-label/per-candidate attribution lives only here. External spend is vendor-side and is
reported by the parity run itself (`externalTokens`, from ext-run's accounting line). Exit 2 =
usage, 5 = INCOMPLETE (no transcripts, or none with usage) — never a silent zero. Tested in
`test/parity-suite.sh` on a synthetic transcript (`test/fixtures/parity/cost`).
