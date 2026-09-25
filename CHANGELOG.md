# Changelog

Reverse-chronological. Each entry cites the commit(s) it corresponds to and,
where known, the test-count delta. See `test/roundtrip.sh` and `test/lint.sh`
for the current check catalog.

## Wave 14 — adaptive bake-off sampling rate; codex data boundary relaxed (branch wave14-optout)

- **14A — per-level sampling rate that never stops.** `config/tiers.json`
  `tuning.maintain = {rate: 0.05, maxWidth: 0.35}`; `tuning.sampleRate` stays
  the one explore rate (and triage-exec's fallback) — no `rates.explore`
  duplicate. `triage-tiers.sh` TUNING_ERRORS validates it: `maintain.rate` in
  (0, 1] and ≤ `sampleRate` (sampling never stops at a plateau), `maxWidth` in
  (0, 1]. `parity-report.sh` (the one owner of the rule) gains `rates [--json]`
  and `report --json .sampling` + a markdown table: per level, `none` (no
  configured challenger: rate 0), `maintain` iff for every vendor with a
  `levels` entry or configured challengers there the incumbent and every
  configured challenger have n ≥ minN, every Wilson 95% interval is ≤ maxWidth
  wide and no proposal is pending for that level × vendor (rate
  `maintain.rate`), else `explore` at `sampleRate` with a reason naming every
  gap. `--json` = `{asOf, params, levels: {<level>: {state, rate, reason}},
  rates: {<level>: rate}}`. Groups gain `wilsonUB` (one `wilsonBound()` formula,
  sign ±1). Reset on a model change is the existing grouping: counts are keyed
  by the tiers file's current (vendor, model, effort), so a new model/effort
  starts at n = 0 → explore; no separate mechanism. Only build lines count.
  `triage-exec.js`: optional `args.bakeoff.rates` (`{level: number in [0,1]}`,
  validated before any spawn — unknown level, out of range, non-number → throw);
  `bakeoffPick()` samples at `rates[level]`, else `sampleRate`; with `rates`
  given, sampled records and `not-sampled` skips carry `{rate, rateFrom:
  'rates'|'sampleRate'}`. Absent → byte-identical 13B behavior (S40–S53
  unchanged).
- **14B — codex data boundary.** Alex confirmed the codex account's training
  opt-out and ruled that COI material may go to codex. Removed
  "COI" from the refusal classes in `scripts/ext-run.sh` (header + attestation
  comment), `agents/triage-external.md` rule 2, `agents/triage-cross-reviewer.md`
  rule 1, `README.md` and `scripts/README.md`. Still excluded: clinical/BCH/PHI
  (no BAA), `clip-creator`, `.codex-deny` / `CODEX_DENY_REPOS`. The
  `AGY_BOUNDARY_CLEARED` attestation is unchanged; the Fable retention rule in
  `triage.md` is untouched.
- **Checks**: workflow-scenarios 310 → 325 (S54), parity-report 68 → 94 (RT*
  tuning.maintain schema, RA* rates: no data, settled, pending proposal, wide
  CI, n < minN alone, review lines ignored, model/effort/challenger change →
  n = 0, empty challenger lists → none, Wilson UB); other suites unchanged.
  Mutations 82–85 (rates n ≥ minN, CI width, proposal forces explore,
  triage-exec using `rates[level]`), each KILLED (`qc/mutate.sh --only`);
  #76's anchor refreshed for the new draw line; catalog 76 → 80.
- **14C — bake-offs on by default + first live run.** `triage.md` rule 10
  (and Alex's live fork, rule 9; approved 2026-09-25): every `triage-exec`
  plan carries `args.bakeoff` (config from `triage-tiers.sh --bakeoff-json`,
  rates from `parity-report.sh rates --json`) unless Alex opts out or the work
  is PHI/BCH or classifier-sensitive; review bake-offs stay opt-in. AGENTS.md
  gate counts updated (approved). First live inline bake-off (run
  `bakeoff-1`, deep rate forced to 1 for the test): a danger deep subtask —
  `externalReport()` gains `bakeoffApplied` and `report.external` appears when
  a bake-off applied an external challenger's patch. Planned claude opus@high
  and challenger codex gpt-6-astra@high both passed, leak false, planned patch
  applied, checks green; ingested as one ledger line. This exercised the nested
  `workflow('triage-compare')` live for the first time. workflow-scenarios
  325 → 334; mutation 86 (the bake-off arm of `externalInPlay`), catalog 80 → 81.
- **Deferred**: a model swapped under an unchanged claude alias (`opus`,
  `sonnet`) does not reset counts — bump the tiers entry. The planned Claude
  candidate's tokens are null in the ledger (parallel compare: Claude
  outTokens unavailable), so cost comparisons stay one-sided for inline runs.

## Wave 13 — agy retired; every codex run OS-confined and audited (uncommitted)

- **13B — inline build bake-offs in `triage-exec` (opt-in `args.bakeoff`).**
  `bakeoff = {config: <triage-tiers.sh --bakeoff-json>, seed, repo, outDir
  (outside repo), weeklyPct?}`; absent → unchanged (no bake-off fields). New
  optional subtask field `checks: string[]` (its own checks: the bake-off's
  grade; the plan checks stay the verify gate). `bakeoffPick()` owns sampling:
  eligible = own checks (or the plan's, when it is the only subtask), non-empty
  `files`, an id usable as a path/ledger token, and a `tuning.challengers` entry
  differing from the planned (vendor, model, effort); codex challengers of
  danger work must clear `codexDangerEffort()`'s floor (excluded, never
  lifted); none at `weeklyPct >= pauseAtWeeklyPct`. Deterministic: FNV-1a over
  `seed\0id\0brief` < `sampleRate`, second/third hashes pick the vendor
  (cumulative `challengerMix`, VENDORS order; empty pool → the other) and the
  entry. Sampled subtasks run first, one at a time: `git status --porcelain`
  on their files (any output or no answer → run in place), then a nested
  two-candidate `triage-compare` (planned = exactly what `runSubtask()` would
  spawn, vs the challenger; `parallel:true`, base HEAD, outDir `<outDir>/<id>`).
  `bakeoffChoice()` owns the apply: planned pass → planned; else challenger
  pass → challenger (`⚠ Bake-off fallback` log); else a failing planned diff
  that applied at the sha → planned (verify + remediation run on it); else in
  place. Applied via `stage-worktree.sh apply` (exit 6 / no answer → in place);
  the applied result joins `results` (`bakeoff:true`, the candidate's
  level/vendor/effort) so verify/assess/remediation are unchanged — an applied
  codex challenger that fails verification is redone on Claude at its level by
  `redoStep()` (no new path). A compare LEAK aborts the run (nothing applied,
  nothing else runs, `error: LEAK…`, as triage-parity does); throw / no result /
  unknown leak state → in place. Budget: each bake-off is WORK via `spawn()`
  on `RESERVE`. `report()` gains `bakeoffs` (per sampled subtask),
  `bakeoffSkipped` ({id, reason} for the rest) and `ingest`: a workflow cannot
  write files, so each graded compare returns its compact result (scores and ids
  only) plus a `file` path and a ready `parity-report.sh ingest-compare` command;
  the orchestrator writes the file and runs it (`--run <outDir basename>:<id>`,
  `--applied` only when a patch was applied). Test harness: `workflow()` mock.
- **Checks (13B)**: workflow-scenarios 228 → 310 (S40–S53). Mutations 75–81
  (pause, sample threshold, challenger fallback, LEAK abort, dirty-files guard,
  codex danger floor on challengers, bake-off fields without `args.bakeoff`),
  each KILLED by an assertion (`qc/mutate.sh --only`); catalog 69 → 76.
- **Deferred (13B)**: no live run yet (the nested `workflow()` call from
  triage-exec is exercised only by the mock); `triage.md`/README usage text and
  AGENTS.md counts (approval); a sampled subtask is graded at HEAD without
  other subtasks' changes (plans already assume independent subtasks); a Claude
  challenger's redo keeps its effort but reverts to the level agent's model;
  `external` in the report stays plan-derived (a codex challenger shows in
  `bakeoffs`, and in `returnedToClaude` only if redone); the in-place run after
  a failed bake-off is a second spend on the planned rung.
- **agy retired (Alex, 2026-09-24).** A read-only parity review on agy set its
  model-settable `BypassSandbox` flag and copied a file into a real repo. agy
  is gone from `config/tiers.json` (`levels.builder.agy`, `modes.agy`),
  `ext-run.sh` (adapter, effort-suffix handling, flags, `.agy-deny`,
  `AGY_DENY_REPOS`), `triage-tiers.sh` (column + tuning vendor) and
  `parity-suite.sh` (marker propagation; `denied` is `{codex}`). Refused by
  name everywhere: `ext-run.sh --vendor agy` → exit 3; triage-exec `vendor`,
  plan `vendor`, `crossReview: 'agy'|'both'` → `bad()`; compare/parity
  candidates and parity judges → entry-contract error. `overflow` (flag and
  alias) now means builder-level work on **codex**; overflow + `danger` still
  runs on Claude deep (an explicit `vendor:'codex'` + danger is lifted, as in
  Wave 12). `crossReview: true` = codex. The report's `overflow` mirror of
  `external.agy` is gone. Leftover `.agy-deny` markers are inert; old parity
  task files listing `agy` and historical agy ledger rows still validate.
  `AGY_BOUNDARY_CLEARED`/`AGY_STAGE_KEEP` keep their names (callers and the
  live install use them).
- **Codex OS confinement (`ext-run.sh`).** Every codex run is `cd <ws> &&
  TMPDIR=<stage>/cx/tmp sandbox-exec -f <per-run profile> <codex real path>
  exec -C <ws> --dangerously-bypass-approvals-and-sandbox …` (codex's `-s` and
  `sandbox_workspace_write.*` flags dropped: its seatbelt does not nest).
  Profile: no reads under `$HOME` but `$HOME` (literal), `~/.codex`, the
  workspace, codex's scratch dir and `--allow-read` paths; no writes under
  `$HOME`, `/private/tmp`, `/private/var/folders` or the stage but `~/.codex`,
  the workspace, the scratch dir and `/dev/null`. Tighter than the spike's
  profile in three places: the private meta dir (event stream, profile,
  hidden `.git`) is not codex-writable, the build repo + its git dir are
  denied read/write, and the stage root is write-denied (the canary target).
  Fail closed: no `sandbox-exec`, a profile that does not apply, or one that
  does not enforce (preflight canary write lands) → exit 4, codex never runs.
  All REFUSED/USAGE checks now precede the availability checks.
- **`--allow-read PATH`** (repeatable): refused when the deny check refuses it,
  when it is `$HOME` or an ancestor, or when a deny-listed repo or
  `.codex-deny` lies beneath it.
- **Command audit log**: one JSONL line per `command_execution` item —
  `{ts, runId, mode, model, cwd, command[0:500], exitCode}`, never output —
  to `${EXT_RUN_AUDIT_LOG:-~/.claude/logs/ext-run/codex-commands.jsonl}`,
  also for failed/interrupted runs; 30-day prune under a mkdir lock; an
  uncreatable log dir is exit 4.
- **Tests**: `test/ext-run.sh` rewritten around a stub codex run under the REAL
  profile (macOS): enforcement P1–P11, `--allow-read` A1–A8, audit L1–L5,
  agy refusal V1–V2; a non-confining canary-forging double on Linux (P2–P7
  SKIP there). 172 → 168 checks (agy duplicates gone). Scenarios 226 → 228,
  compare 116 → 117, parity-suite 74 → 75, parity-scenarios 100 → 101.
- **Mutations**: dropped 13/14 (agy gates), 27 (`exclude_slash_tmp`), 30
  (`crossReview 'both'`); re-anchored 16 (overflow danger guard), 24, 44; new
  56 (no sandbox-exec), 57 (`$HOME` subpath read), 58 (audit records output),
  59 (`--vendor agy` accepted). Still 54.
- Deferred: live codex run under the profile (orchestrator); the live
  `~/.claude/triage.md` fork, AGENTS.md line 4 and PROJECT_MEMORY need
  Alex-approved edits; writes outside `$HOME`/tmp dirs (e.g. `/opt/homebrew`,
  `/Users/Shared`, `/private/var/tmp`) still fall to `(allow default)`;
  `--check`/patch-check still run candidate code unsandboxed; no Linux
  confinement backend (codex is unavailable there by design).

## Wave 12 — vendor-neutral tiers: Codex alongside agy, level/vendor/role split

- **Three axes replace the 7-tier list.** **level** (`quick|builder|deep|top`,
  `top` replaces `fable` as the name; `fable` kept as the `top`+claude alias)
  describes the task, never a model; **vendor** (`claude|codex|agy`) says who
  serves it, read from `config/tiers.json`, not code; **role**
  (`implement`/`review`/`read`) is unchanged. `overflow` is no longer a tier —
  it's `builder`+`vendor:'agy'`, kept as an alias. `triage-overflow` →
  `triage-external` (any vendor, any level it serves). Rule 6: "never to
  `agy`; `codex` is allowed at any level `config/tiers.json` lists for it"
  (Alex's decision 2026-09-23, rechecked by the parity workflow); the
  data-boundary class barring Fable-retention material is unchanged.
- **`config/tiers.json`**: the single place naming a model/effort, Claude or
  external, each entry tagged `basis` (`alex <date>` / `incumbent <date>` /
  `guess`). `make tiers` syncs `agents/*.md` frontmatter to it; `test/lint.sh`
  fails on drift.
- **`scripts/agy-run.sh` → `scripts/ext-run.sh`**: adds `--vendor agy|codex`
  and `--level`; a Codex adapter (`codex exec`, non-interactive footer since
  codex auto-loads `~/.codex/AGENTS.md`); per-vendor deny (`.agy-deny` /
  `.codex-deny`, same walk-to-`$HOME` logic); `--patch-out`/`--check` for
  compare/bake-off use.
- **`workflows/triage-exec.js`**: subtask `vendor`; `codex`+`danger` allowed
  (effort floored `high`, level lifted to ≥`deep`), `agy` never takes
  `danger`; external `UNAVAILABLE` falls back to Claude at the same level,
  logged; failed checks/`ESCALATE:` still climb only the Claude ladder —
  no auto-escalation across vendors. `crossReview` gains `'agy'|'codex'|'both'`.
- **Compare / bake-off, final design (`35e546a`).** Each candidate runs in
  its own detached worktree from `scripts/stage-worktree.sh` at one resolved
  sha; the real repo is never a candidate workdir; grading is only
  `scripts/patch-check.sh`; a `leakcheck` invalidates the whole run. Why: the
  first live run leaked — the external wrapper dropped `--patch-out`, so a
  codex patch applied to the real tree (reverted), and `isolation:'worktree'`
  was based on `main`, not the branch head.
- **Installer fork fix**: a bare `install.sh` used to clobber a
  `.driftignore`-listed personal fork after the first install; `is_ignored`
  is now checked in every mode whenever the installed copy already exists.
- **Parity machinery (`037f3e1`, `6cc7c86`, `2469dea`).**
  `scripts/parity-suite.sh` (task format/validation, `materialize`,
  `verify-task`, `score-review`), `scripts/parity-cost.sh` (Claude spend per
  candidate from a transcript dir), `workflows/triage-parity.js` (climbs a
  private task suite band-by-band, build tasks graded by a nested
  `triage-compare`, review tasks by seeded-defect recall/precision, rubric
  tasks by two blind judges; adaptive stop; proposes but never writes
  `tiers.json`). `materialize` builds each task repo as one root commit from
  `git archive` rather than a clone — a clone-based version leaked replayed
  fixes via git history, caught in review. Review tasks route external
  candidates through read mode with their own model/effort, not the
  review-mode default (`6cc7c86`).
  Private 17-task suite at `~/.agents/parity` (kept private because it lives
  alongside private grant-forge material). Two pilot runs, 9 candidates
  (`wf_fa44f0b0-a5e` bands 1–2, `wf_c5a32cce-ae6` bands 3–4): the suite
  saturates above the quick tier (only 4/17 tasks discriminate, n=1);
  `luna-low` beats `haiku-low`; `codex sol-medium` passed every graded task.
  The auto-proposal (sonnet at deep/top, luna at codex top) was **not**
  adopted; only `tiers.json`'s `basis` field was updated (`2469dea`) to
  record the pilot as evidence, not a tier change.
- **Boundary markers added outside this repo**: `.agy-deny` in
  one confidential local project (cleared for Claude + Codex only);
  `.agy-deny`+`.codex-deny` on one PHI-adjacent local corpus.
- **Cross-vendor review before merge** (codex + agy on the danger-zone diff,
  via `ext-run.sh`; two agy claims were false positives): fixed `leak:null`
  accepted as graded, overlay-copy failure graded without hidden tests,
  inherited `GIT_DIR`/`GIT_WORK_TREE` redirecting staging, symlinked inputs
  bypassing deny, space-containing deny sources, trailing-option parse loop,
  `--3way` conflict markers left on exit 6, the worktree `.git` pointer visible
  to the external CLI (now hidden during the run), `$HOME` marker unchecked,
  watchdog orphaning grandchildren, and fixed `/tmp/ext-*` files racing between
  parallel candidates (this may have mis-marked some parity candidates
  `unavailable`; grades were unaffected). Known limitation, documented: grading
  runs candidate code unsandboxed (confined to a disposable worktree).
- **Checks**: roundtrip 153, usage-tally 24, ext-run 172, patch-check 25,
  stage-worktree 34, workflow-scenarios 226, compare-scenarios 116,
  parity-suite 74, parity-scenarios 104 (928 total); `qc/mutate.sh` 23 → 50.
- **Deferred**: suite v2 (harder band-4 tasks, reps ≥ 3, a minimum-n/margin
  gate before adopting a proposal); codex review JSON invalid on
  `syn-r-seeded` (likely strict-schema quirks); codex read/verify-mode model
  in `config/tiers.json` still `guess`; live end-to-end `triage-exec` codex
  routing (only compare/parity have exercised it live); the reverse direction
  (Codex orchestrating); Wave 13 inline bake-offs on real work (decided 2026-09-24: 1-in-5 sampling, ~80% codex challengers, challenger fallback, tracked ledger); `triage-reviewer`'s zero recorded uses; the usage-
  guard weekly reading looked stale all session.

## Wave 11 — Opus 5.5 as orchestrator; effort retune; deep@max before Fable

Uncommitted at time of writing (branch `wave11-opus55`).

- **Orchestrator recommendation: Opus 5.5** (`claude-opus-5-5`, launched
  2026-09-22): Anthropic places it at Fable 5.1's level on most work, ahead on
  Terminal-Bench 4.0 / GDPval-AA / OSWorld 2.0, at $4/$20 vs $10/$50, with no
  30-day retention requirement. `triage.md` drops "most expensive tier"
  framing: on the deep tier's own model, delegation buys context isolation and
  parallelism, not capability; one module may be read inline to plan.
- **Subagent default `claude-opus-5` → `claude-opus-5-5`.** `install.sh`
  upgrades a value equal to a previous installer default
  (`LEGACY_SUBAGENT_MODELS`); any other user value is left alone.
  `uninstall.sh` removes current or legacy defaults; roundtrip N8 asserts the
  two scripts' lists match (they can't share a sourced file: shellcheck runs
  without `-x`).
- **Effort retune for Opus 5.5** (thinks more per level than Opus 5; its
  `medium` beats Opus 5 `high`): `triage-deep-reasoner` xhigh → high,
  `triage-reviewer` high → medium. Rubric now says effort is raised via the
  `triage-exec` subtask `effort` field — the Agent tool has no effort knob and
  brief prose doesn't change it.
- **`triage-exec`: one deep@`max` attempt before any Fable escalation.**
  `redoStep()` owns the decision; a deep subtask below `max` that escalates is
  re-run at `max` (`owesFable`) and reaches Fable only if that fails too. A plan
  with `effort:'max'` goes straight to Fable. Every Fable spawn now goes through
  `runFable()` (⚠ print + unavailable fallback) — remediation-round Fable
  spawns previously printed nothing and had no fallback. Fable unavailable
  after deep@max → no duplicate deep@max, recorded `fable->none`, failed loudly.
- **Rule 6 rewritten**: Fable 5.1 and Opus 5.5 both run a cyber classifier;
  Opus 5.5 adds bio and `reasoning_extraction`. No tier is classifier-free — on
  a refusal, rephrase or surface it rather than re-sending up the ladder.
- **Checks**: roundtrip 114 → 123, workflow-scenarios 128 → 153 (266 → 300,
  plus agy-run 64 unchanged); mutations 18 → 23 (19–21 legacy-model upgrade /
  uninstall, 22–23 deep@max step; 17 re-anchored).
- **Deferred**: a plan's explicit `effort` passes through to escalated tiers
  (a deep@high subtask reaches Fable at `high`); prompt-audit findings not
  applied (worker `ESCALATE:` not parsed by `assess()` when checks exist and no
  reviewer runs; workers still hold the Agent tool; check-runner 1–3-sentence
  vs quote-40-lines contract); Max weekly-quota weighting of Opus 5.5 vs Fable
  unconfirmed; builder-tier Sonnet 5 vs Opus 5.5@low A/B; revisit tiers when
  Sonnet 5.5 / Haiku 5.5 ship.

## Wave 10 — agy tiers: overflow build worker + five read-only cross-vendor modes

`e399233`, `7c2baac`

- **Wave 9 follow-ups** (`e399233`): Fable 5.1 strings, a node-26 lint check,
  a prompt-cache statusline segment (`scripts/triage-cache-segment.sh`),
  `omitClaudeMd` on `triage-quick-task`, and a rule-4 note on
  `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` for fan-out.
- **`scripts/agy-run.sh` is the single owner of every Antigravity CLI
  invocation.** Modes: `review|read|verify|critique|fuzz|build`, each pinned
  to an explicit Gemini model — no mode ever falls back to a default model.
  Success requires exit code 0 **and** empty `denied_actions` **and** a
  non-empty response; agy reports `SUCCESS` with empty output when tools are
  auto-denied or on timeout, so exit-code-only checks would have passed on
  nothing.
- **Deny-list by repo-name component** (`engram`, `clip-creator`) plus a
  `.agy-deny` marker file and an `AGY_BOUNDARY_CLEARED=1` attestation the
  caller must set. The list is default-allow: anything not on it runs unless
  marked.
- **Deny-list narrowed to `clip-creator` alone (2026-09-15).** `engram` came
  off the list: its content already lives on Google Drive, so routing it to agy
  adds no exposure. Mechanism unchanged (component match + `.agy-deny` marker +
  `AGY_BOUNDARY_CLEARED=1`); `test/agy-run.sh` grows an explicit R3b regression
  check that a path under `engram` is no longer refused (63 → 64 checks).
- **`build` mode stages in a disposable git worktree** and applies the result
  back as a patch; exit 6 means the patch didn't apply.
- **Seventh agent: `triage-overflow`** (Haiku wrapper). `triage-cross-reviewer`
  generalised from its single review mode to all five read-only agy modes.
  Both set `omitClaudeMd`.
- **`triage-exec` overflow tier.** A plan-level `overflow: true` rewrites the
  `builder` tier only — `danger` always wins over it, unavailable falls
  sideways to `builder`, a failure escalates up to `deep`. `report().overflow`
  is derived, not separately tracked.
- **Install/uninstall/drift cover the 7th agent and script**, plus a new
  warning when `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set (agy modes pin their
  own model per-call; a global force would silently fight that). Rubric and
  README updated; lint count 7.
- **Checks: 214 → 266** (roundtrip 114 + usage-tally 24 + workflow-scenarios
  128) plus a new standalone 63-check `test/agy-run.sh` suite that prints its
  own summary. Verified against Claude Code 2.1.272.
- **Mutation catalog 11 → 12** at `e399233`; the count after this wave's
  mutation packet lands is **12 → 18 (see `qc/mutate.sh`)**.
- Deferred, honestly: no cron/unattended agy (OAuth persistence is flaky under
  cron); no runtime quota polling inside the workflow (overflow is a
  plan-time call only); agy-side allow-rules instead of
  `--dangerously-skip-permissions` (would mean owning another vendor's config
  — revisit if agy grows a `--permissions-file`); `fuzz` mode has no
  `triage-exec` wiring yet; `read` mode ships but isn't recommended — agy
  loops on `run_command` for single-file reads (revisit if a `--workspace`
  flag lands); vendor spend is not added to `scripts/triage-usage.sh` (its
  contract is Claude transcripts only; per-run count is relayed on stderr
  instead); `--add-dir` is never caller-supplied; the deny-list is
  default-allow (drop `.agy-deny` into repos not consciously cleared); agy
  persists plan/walkthrough artifacts under
  `~/.gemini/antigravity-cli/brain/`, outside the workspace.

## Wave 9 — `triage-run` → `triage-exec`: the plan comes in, only execution goes out

`0c7c396`

- **Classification moved to the orchestrator.** The main loop is now a frontier
  model that already holds the task context and is the best classifier in the
  system, so spending a spawn on a classify agent was pure waste.
  `workflows/triage-run.js` → `workflows/triage-exec.js`: the classify agent and
  its `PLAN_SCHEMA` are deleted, the `Classify` phase is gone, and the workflow
  is a pure executor for a plan handed in via `args`.
- **Entry contract, validated in plain JS before any spawn**:
  `{subtasks:[{id?, brief, tier, files?, acceptance, danger?, effort?}],
  checks?: string[], review?: auto|always|never, crossReview?: boolean}`.
  Malformed args throw with the expected shape in the message — never a
  half-executed, billed run. Missing ids are assigned positionally.
- **`danger` is now enforced, not merely suggested.** A `danger: true` subtask
  planned onto `quick`/`builder` is upgraded to `deep` in JS and logged; before,
  the rule lived only in the classify prompt, where a mis-classification could
  silently route correctness-critical work to Sonnet.
- **Per-command objective gates.** `checks` is a list, one quick-task gate per
  command, so a FAIL is attributable to the command that produced it and the
  return value carries `{cmd, pass}` per check. `effort` is passed through to
  `agent()`, and every `agent()` call sets `agentType` (an omitted one would
  inherit the orchestrator's model — the most expensive possible worker).
- **Optional cross-vendor stage.** `crossReview: true` runs
  `triage-cross-reviewer` with the data-boundary-cleared brief; findings are
  logged and returned but deliberately never reach `assess()`, remediation, or
  the verdict. Closes the wave-7 deferred item ("the workflow does NOT route to
  the new tier").
- **The return value is a distillate** — `{subtasks:[{id,tier,status,attempts}],
  checks:[{cmd,pass}], review, crossReview?, escalations, …}`. Worker prose no
  longer enters the orchestrator's context, which is the point of delegating.
- **Reused unchanged** (single owners preserved): `TIER_AGENT`, `spawn()` as the
  one budget gate, the Fable→deep@`max` availability fallback, `assess()` as the
  one verdict parser, file-attribution remediation, one-tier-up escalation,
  `RESERVE`.
- **Installer slimmed to what the layer actually needs.** `install.sh` no longer
  writes `model`, `effortLevel`, or `statusLine` — your orchestrator and your
  statusline are yours. The preinstall snapshot and its restore are gone with
  them (nothing is overwritten, so there is nothing to restore); `statusline.sh`
  is still copied but unwired, and the installer prints the exact JSON to wire
  it. It now sets `env.CLAUDE_CODE_SUBAGENT_MODEL` and `subagentPromptCacheTtl`
  **only when unset**, and `uninstall.sh` removes them **only while they still
  hold the values we wrote**.
- **Legacy retirement.** Install removes a superseded
  `~/.claude/workflows/triage-run.js` when its SHA-256 matches one of the seven
  revisions this repo shipped (`SHIPPED_TRIAGE_RUN_SHA256` in `install.sh`,
  fixture at `test/fixtures/legacy/triage-run.js`); a copy you edited is kept
  with a note rather than silently deleted.
- **Rubric (`triage.md`)** ported to the new flow: scout-minimally/plan-inline,
  reading legs never run in the main loop, the `CLAUDE_CODE_SUBAGENT_MODEL`
  default, Fable's two hard exclusions (retention-constrained material and
  security work), `crossReview` on `triage-exec`, and an on-request-only usage
  line. The per-escalation post-mortem rule was dropped with the classify stage.
- **Checks: 140 → 214** — roundtrip 70 → 88 (new case K: user-set settings keys
  survive install *and* uninstall; new case L: legacy-workflow retirement, both
  branches; the `model`/`effortLevel`/`statusLine` assertions inverted from
  "installed value" to "never touched"; `H3` removed with the obsolete
  `< 2.1.187` classify-loop warning), scenarios 46 → 102 (entry-contract
  validation ×15, id assignment, effort passthrough, `agentType` always set,
  review modes, ungated-run INCOMPLETE, danger upgrade, multi-check attribution,
  Fable fallback, cross-review, distillate). usage-tally unchanged at 24.
- **Mutation catalog 10 → 11**, all killed: #7 re-anchored onto `assess()`'s
  `incomplete` tri-state (its old anchor died with the per-type verification
  shape), #11 added for the new args-validation guard (`bad()` made a no-op).
- Deferred, honestly: `test/fixtures/legacy/triage-run.js` is a 20 KB byte-copy
  kept only so case L can run from the mutation harness's `.git`-less repo copy
  — a checksum-only fixture would be smaller but would no longer prove the real
  file's bytes hash to a listed value. `install.sh`/`uninstall.sh`/`roundtrip.sh`
  still contain the string `triage-run` by necessity: the migration path has to
  name the file it retires.

## Wave 8 — routing-rubric refinements (builder/deep tie-breaker, per-project danger zones, quiet empty tally)

- **Rule 1 (triage.md)**: explicit builder/deep tie-breaker at the boundary
  where mis-routes concentrate — cause known AND spec written → `triage-builder`;
  either missing → `triage-deep-reasoner`.
- **Rule 6 (triage.md)**: the danger-zone enumeration now also honors any
  correctness-critical files the *project's own* CLAUDE.md/AGENTS.md names — this
  rubric loads globally, but each repo declares its own danger zone.
- **Usage tally (triage.md)**: suppress the usage line entirely when no
  subagents ran (an all-zeros tally is noise).
- **Checks**: docs-only, no executable surface changed. Check total unchanged at
  140 (0 assertions touched); `make mutate` 10/10 killed. Ported from the
  maintainer's personal-fork optimization pass; the fork's prose compressions
  were intentionally NOT ported — the shared rubric keeps its explanatory form.

## Wave 7 — triage-cross-reviewer: cross-vendor review as a routable tier

- **New sixth tier `agents/triage-cross-reviewer.md`**: a thin Haiku·low wrapper
  that runs an external, non-Anthropic CLI reviewer (worked example: Antigravity
  CLI `agy` on an explicit Gemini model) and relays findings verbatim. Protocol:
  data-boundary guard (refuses excluded repos) → prompt file with inlined diff →
  single hardened `agy` invocation → `UNAVAILABLE`/`REFUSED` fail-loud paths →
  verbatim relay under a `CROSS-REVIEW (…)` header. Tiers are Claude Code
  subagents and external binaries can't be spawned as one — the wrapper is what
  makes cross-vendor review routable by the rubric and parallelizable.
- **Rubric**: tier-table row; verification rule 6 now routes via the tier (or
  direct invocation); usage-tally section documents that the tier's external
  spend is vendor-side and invisible to the tally (only Haiku wrapper overhead
  appears).
- **Installer/uninstaller**: worker allowlist and removal list grew to six
  (`Agent(triage-cross-reviewer)` allow rule; per-name removal).
- **Checks**: lint agent-count 5→6 (+README claim); roundtrip A7/A12 allowlist
  counts, I3 six-agent removal. Check total unchanged at 140 (assertions
  updated in place); mutation gate 10/10 killed (mutation 4's `for a in
  $AGENTS` anchor unaffected).
- Deferred, honestly: `/triage-run` (workflows/triage-run.js) does NOT route to
  the new tier — orchestrator-rubric routing only for now; wiring it into the
  workflow classifier needs workflow-scenario coverage and is parked until
  usage justifies it. No mutation for the agent file itself (prose, no
  executable surface — gate sized to the bug surface).

## Wave 6 — agent-agnostic instructions, cross-vendor review, orchestrator-model generalization

- **AGENTS.md is now the canonical working-rules file**; `CLAUDE.md` is a
  one-line `@AGENTS.md` import wrapper (Claude Code's documented import
  syntax) reserved for Claude-specific additions. Content unchanged — this
  makes the repo's rules readable by any AGENTS.md-aware agent (Antigravity
  CLI, Codex, Cursor, Copilot, VS Code ≥1.104).
- **Verification rule 6 (triage.md): optional cross-vendor second opinion**
  on danger-zone diffs via an external CLI agent (worked example: Google's
  Antigravity CLI with an explicit Gemini model), with the non-TTY stdout
  workaround, signal-not-verdict framing, and a data-boundary warning.
- **Orchestrator line generalized (triage.md + README diagram)**: the rubric
  no longer asserts the main loop is Opus-class — the session model varies
  with `/model`, and self-handling hard reasoning is gated on outranking the
  deep tier. Previously, a user who switched to a cheaper session model
  inherited an inverted rule licensing under-class self-handling.
- Test-count delta: none (docs/rubric only; 140 checks remain green).
- Deferred: no mutation for the new rubric text (prose, no executable
  surface); native AGENTS.md support in Claude Code (upstream issue #34235)
  would make the wrapper optional.

## Wave 5 — strict mutation CI, routing stats, budget-aware /triage-run, escalation post-mortems

- **Mutation gate strict + in CI**: covering tests added for both wave-4
  survivors — round-trip Case I (a user-authored `agents/triage-mine.md`
  survives uninstall) and Case J (drift.sh: clean sandbox exits 0; a deleted
  installed file yields `MISSING (not installed)` + non-zero). Sweep is now
  **10 killed / 0 survivors / 0 errors**; `make mutate` runs `--strict` (any
  future surviving mutant fails the build) and is a CI step on both OSes.
- **`scripts/triage-stats.sh`** — cross-session routing stats (per-tier
  spawns/sessions/total/median peak-context tokens, ISO-week rollups;
  `--project` / `--all` / `--weeks`). Evidence-based design choices: week
  bucketing uses the embedded UTC `.timestamp` on transcript lines (present
  300/300 sampled; mtime rejected as copy/rsync-mutable and disagreed with
  embedded time by hours), and the escalation stat ships as an explicitly
  labelled LOWER BOUND after sampling showed escalations are not recorded on
  disk (only ~24% of 3,121 sampled subagents carry any description; escalation
  markers ≈ 0). Fail-loud INCOMPLETE scoping; unreadable sessions counted and
  reported, never dropped. Installed/uninstalled/drift-checked like the usage
  script.
- **Budget-aware `/triage-run`** — wires the Workflow DSL `budget` global.
  One tuned constant (`RESERVE = 60_000`, sized from real gate costs in the
  usage tally) floors WORK spawns (Execute + remediation) so verification
  always has room — work is skipped before verification, since an unverified
  result is worse than a smaller verified one. `spawn()` is the single owner
  of the budget decision; the DSL's hard-ceiling throw is caught and recorded
  as a skip (partial results preserved). No silent caps: every skip is logged
  and returned in `budget.skipped`; all-skipped returns an explicit error.
  With no budget set the control flow is unchanged (proven by short-circuit
  analysis + scenario S9). Scenario suite 28 → 46 assertions.
- **Escalation post-mortems (rubric)** — informed directly by the stats
  investigation: since escalations are unrecoverable from transcripts, the
  escalation protocol now instructs the orchestrator to append a dated
  one-line post-mortem to the failing tier's `.claude/agent-memory/<agent>/
  MEMORY.md` at escalation time, and to consult it when briefing that tier.
  Rubric-only by necessity: workflows have no filesystem access, and the
  on-disk record doesn't exist — the orchestrator is the only writer.
- Check count: **113 → 138** (68 round-trip + 24 usage-tally + 46 scenario),
  plus the strict 10-mutation sweep in CI.

## Wave 4 — mutation gate, usage-tally tests, statusline spend, installer dry-run/files-only/version-warn

Four parallel builder workstreams, orchestrator-verified and integrated.

- **`qc/mutate.sh` + `make mutate`** — automated tests-with-teeth gate: 10
  cataloged mutations, each applied to a fresh temp copy of the repo (anchor-based
  matching, not line numbers; a baseline pass per suite so an already-red suite
  reports ERROR, never a false kill; a verify-applied grep so an unmatched anchor
  is ERROR, never a silent kill). Tri-state KILLED/SURVIVOR/ERROR; `--only <id>`,
  `--strict`. First sweep: **8 killed, 2 survivors, 0 errors** — the survivors
  (uninstall glob-revert; drift MISSING-branch) are real untested guards, each
  reported with a suggested covering test. `--strict` stays off in `make mutate`
  until they're covered.
- **`test/usage-tally.sh` + `test/fixtures/usage/`** (wired into `make test`) —
  24 checks over fully synthetic fixtures: peak-vs-sum-vs-last context math,
  missing meta.json degraded behavior, unknown model → `other`, and every
  distinct exit code (verified against the script's own EX_* constants).
- **`statusline.sh` subagent-spend segment** — appends ` · sub Nk` (total
  session subagent spend) via `scripts/triage-usage.sh` behind a 30-second
  cache keyed by `session_id`, using the documented `transcript_path` stdin
  field when present; any failure renders an empty segment (the existing
  degradation contract). Cold render ~0.6s, warm ~0.15s.
- **`install.sh --dry-run` / `--files-only`** (composable) — dry-run prints an
  honest per-item mutation plan (create/overwrite-with-backup/unchanged per
  file, CLAUDE.md append status, settings keys, permission rules, snapshot)
  and writes nothing; files-only copies just the installed files, skipping
  `.driftignore`-listed personal forks (`skipped (expected fork): triage.md`)
  — the primitive behind the new `make sync` target. Round-trip cases F/G/H
  added.
- **Version-compat warning** — `install.sh` parses `claude --version`
  (BSD-safe awk compare, no `sort -V`) and warns per threshold
  (2.1.172/2.1.186/2.1.187) or when unverifiable; never blocks the install.
- Check count: **64 → 113** (61 round-trip + 24 usage-tally + 28 scenario),
  plus the 10-mutation sweep. `make test` now runs all three suites.
- Live-fire integration notes: the drift gate caught the repo-ahead
  `statusline.sh` before sync (second real catch); `make sync` correctly
  skipped the personal `triage.md` fork on its first use; and a builder's
  self-verification caught a `set -e` bare-`[ ]`-as-last-statement footgun in
  `install_file` plus an exec-bit-stripping write-back in `qc/mutate.sh` that
  was producing false kills.
- Deferred: covering tests for the two mutation survivors (then flip CI to
  `--strict`); R4 routing stats; R7 budget-aware /triage-run; R8 escalation
  feedback loop.

## Wave 3.1 — tri-state verification (fail-loud INCOMPLETE) + workflow scenario tests

- `workflows/triage-run.js`: closed the wave-3 known gap — a verifier gate whose
  agent dies (`agent()` → null) is no longer a non-failing empty string on the
  single-gate paths. All gates (objective, reviewer, seam) now get ONE bounded
  retry of the *gate itself*; a second null makes the verification **INCOMPLETE**
  (tri-state PASS/FAIL/INCOMPLETE, per the grant-forge fail-loud spine): loudly
  logged, flagged on the returned `verification.incomplete`, and — deliberately —
  NOT remediated (a dead verifier says nothing about the work; re-running
  subtasks on it would be remediation without a signal). A real failure from
  whichever seam gate DID run still remediates on that gate's feedback. This
  supersedes wave 3's seam-path "null counts as FAIL" semantics.
- Added `test/workflow-scenarios.mjs` (wired into `make test`): executes the
  actual workflow body under mocked DSL globals — the previously ad-hoc,
  discarded harness is now a committed regression net. 8 scenarios / 28
  assertions covering both wave-3 features and the tri-state paths (gate
  retry-then-clean, dead-gate INCOMPLETE with no remediation on both single-gate
  paths, seam with one dead + one failing gate). Teeth proven by mutation:
  reverting the INCOMPLETE fix in the source makes S6 go RED (26/2), restore
  goes green (28/0). Check count: **36 → 64** (36 round-trip + 28 scenario).
- First real shellcheck pass (CI run 28560142799, both OSes) failed as wave 3
  predicted it might, with real findings in the test harness itself: an SC1073
  parse error (a comment line beginning with the literal word `shellcheck`,
  misread as a directive) and 13× SC2034 (3 genuinely dead captures deleted;
  10 false positives — vars consumed inside `chk`'s eval'd condition strings —
  suppressed individually with the repo's labeled-justification convention).
  All 7 `.sh` files now pass `shellcheck -S warning` with zero findings.

## Wave 3 — CI harness, drift checker, deterministic usage tally, workflow seam-checks (`9ceb599`)

Three parallel workstreams (built by tier workers per the triage rubric itself:
one builder, two deep-reasoners; orchestrator-verified and integrated), applying
the principles extracted from grant-forge (`~/.claude/coding-principles.md`):
fail-loud, one green gate, tests-with-teeth, docs-tested-against-code.

**Deterministic usage tally** (new `scripts/`):
- Added `scripts/triage-usage.sh` + `scripts/README.md`: the per-tier usage
  tally is now computed from the session's on-disk subagent transcripts
  (`~/.claude/projects/<slug>/<session-id>/subagents/agent-*.jsonl` + their
  `.meta.json`), not recalled by the orchestrator from memory. Sums each
  subagent's peak context (`max over turns of input + cache_creation +
  cache_read`) per model family — the same figure Claude Code displays
  per subagent; validated against two known runs (64,917 ≈ the observed
  ~66k Fable review; 98,443 ≈ the observed ~98k Opus extraction). Counts
  only — never message content. Fail-loud: missing subagents dir →
  `INCOMPLETE` (exit 5), unreadable/empty input → distinct non-zero exits,
  never silent zeros. Known limit (documented): peak-context under-weights
  output-heavy runs; cumulative output is shown in `-v`.
- `install.sh`/`uninstall.sh`/`drift.sh` wire the script in as an installed
  file (`~/.claude/scripts/triage-usage.sh`); `triage.md` § Usage tally now
  instructs the orchestrator to run it instead of recalling numbers.

**`/triage-run` workflow — seam-check enforcement + targeted remediation**:
- `PLAN_SCHEMA` gains a required per-subtask `danger` flag (correctness-critical:
  shared primitive/dispatcher, ≥3 modules, format-sensitive output). Any
  danger subtask + an available objective check → BOTH the objective check
  AND the reviewer run (rubric verification rule 4); either failing fails the
  round; a null/unrunnable gate in the seam path counts as FAIL (fail-loud).
- Remediation is now targeted: the verifier's failure text is matched against
  each subtask's declared files (path-boundary regex, basename or path-suffix);
  only implicated subtasks re-run. Attribution matching nothing → re-run ALL,
  loudly logged (no silent narrowing). Verdict parsing consolidated into a
  single owner (`assess()`); scenario-verified by executing the workflow body
  under mocked DSL globals (4 control-flow scenarios, all green).
- Known gap (deferred, tracked): the pre-existing single-gate objective/review
  paths still treat a null verifier as a non-failing empty string — a latent
  fail-silent the seam path does not share. *(Resolved in wave 3.1, above.)*

**CI harness, round-trip tests, drift checker**:
- Added `test/roundtrip.sh`: a 21+-check (currently 36) install/uninstall
  round-trip suite covering: (A) a no-trailing-newline `CLAUDE.md` plus
  pre-existing settings, install → idempotent re-install → uninstall-restore;
  (B) a fully empty `CLAUDE_DIR` round-trip (null snapshot keys deleted, no
  `"permissions": {}` residue); (C) a symlinked `settings.json` (install
  writes through the link, link survives); (D) an invalid `settings.json`
  (install aborts before any mutation, error mentions "not valid JSON");
  (E) a Fable `ask`→`deny`-converted rule still cleaned up by uninstall; plus
  two direct `statusline.sh` checks (non-numeric `used_percentage` doesn't
  crash, numeric renders `Opus · ctx 42%`). Every case runs in its own
  `mktemp -d` sandbox — never touches the real `~/.claude`. Fail-loud runner:
  `set -u`, accumulates all failures, prints `RESULT: N passed, M failed`,
  exits non-zero on any failure or a missing `jq` prerequisite.
  Test count: **0 → 36 checks** (spec baseline was a verified 21-check run
  against dc9d4c2; this implementation covers the same 5 cases + 2 statusline
  checks at finer granularity).
- Added `test/lint.sh`: `bash -n` on every `*.sh`, `node --check` on every
  `workflows/*.js`, `shellcheck --severity=warning` on every `*.sh` when
  installed (loud `SKIP:` + still-green exit locally when absent — CI always
  installs it, so CI gets the full lint), and a docs-consistency check that
  every path README.md's install / manual-install sections cite actually
  exists, and that README's "five subagent definitions" claim matches
  `ls agents/triage-*.md | wc -l`.
- Added `drift.sh` (repo root): compares the installed copies under
  `~/.claude` (or `$CLAUDE_DIR`) against the repo for the 5 agents,
  `statusline.sh`, `workflows/triage-run.js`, `scripts/triage-usage.sh`,
  and `triage.md`, printing `same` / `MISSING (not installed)` / `FORKED`
  per file. A MISSING file in an otherwise-present install counts as
  unexpected drift (fail-loud) unless listed in `.driftignore`. Honors
  `.driftignore` (added, containing `triage.md` — the user's live
  `triage.md` is a deliberate personal fork, not drift). No install at all
  → `INCOMPLETE` notice, exit 0 (so CI, which never has an install, passes).
  First real catch, same session it was built: it flagged
  `workflows/triage-run.js` as FORKED (repo ahead of the live install after
  the seam-check upgrade) and failed `make verify` until the install was
  synced.
- Added `Makefile` (`lint`, `test`, `drift`, `verify` = lint → drift → test,
  fail-fast) as the single green-gate entry point.
- Added `.github/workflows/ci.yml`: push + pull_request, macos-latest +
  ubuntu-latest matrix, installs shellcheck, checks for `jq`/`node`, runs
  `make verify`.
- Spot-checked that the round-trip suite has teeth: flipped one assertion's
  expected value (`A5`, `opus[1m]` → a wrong literal) mid-development,
  confirmed the runner reported `FAIL` + a non-zero suite exit, then
  restored the correct value and re-confirmed green. See the harness-builder
  session transcript for the RED output.
- **Deferred / known gaps** (honest list):
  - `shellcheck` was not installed on the dev machine this wave was built
    on, so the shellcheck pass itself was only exercised via `SKIP:` locally
    — it has not yet been run and eyeballed for real findings outside CI.
    First CI run on this branch is the first real shellcheck pass.
  - No mutation-sweep tool (à la grant-forge's `qc/mutation_sweep.py`) — the
    "tests have teeth" claim above is a single manual spot-check, not an
    automated mutation gate.
  - `install.sh`/`uninstall.sh` are not tested against a `settings.json`
    that already has a non-empty `permissions.deny` for unrelated rules
    (only the Fable-specific deny path in Case E is covered).
  - No test exercises `CLAUDE_DIR` pointing at a path with no write
    permission (install/uninstall's behavior there is unverified).

## Wave 2 — code-review fixes: installer safety, workflow correctness, docs

- `dc9d4c2` — Fix code-review findings: installer safety (settings.json
  validated *before* any mutation; symlinked `settings.json` written through,
  not replaced; locally-modified installed files backed up to `*.bak-triage`
  before being overwritten), workflow correctness (`triage-run.js` null/plan
  guards, Fable-unavailable fallback to `triage-deep-reasoner@max`), and docs.
- `e725975` — `triage.md`: reconcile the user's live fork with the installed
  rubric; generalize new rules (Fable-availability guard, dedup-check,
  danger-zone routing) so they apply beyond the incident that prompted them.
- These two commits are the basis the wave-3 round-trip suite was built to
  verify: a "verified 21-check round-trip suite (all green 2026-07-01
  against commit dc9d4c2)" spec — cited above — confirmed cases A–E and the
  statusline behavior all hold post-fix, before wave 3 turned that spec into
  a runnable, repo-committed test.

## Wave 1 — initial model-triage layer

- `4d37be3` — Claude Code model triage layer: 5 tiered subagent
  definitions (`triage-quick-task` / `triage-builder` / `triage-deep-reasoner`
  / `triage-fable-architect` / `triage-reviewer`), the `triage.md` routing
  rubric, escalation protocol, and verification protocol.
- `4ecf4ef` — Added per-agent project memory, the `/triage-run` workflow
  command, a (since-retired — see wave 2) `SubagentStop` hook, and a
  `ccusage`-aware statusline.
- `b242918` — Harness-enforced the triage rubric at the permissions layer
  (`ask` gate before Fable spawns, `allow` for the four cheaper worker
  spawns); retired the `SubagentStop` hook (it derailed builder/quick-task
  workers rather than reaching the orchestrator); fixed the uninstall
  restore path.
- `097d93f`, `61a0147` — Guarded for an unavailable Fable tier: `triage.md`
  and `triage-run.js` both remap to `triage-deep-reasoner` at max effort
  when a Fable spawn hard-fails (stale model registry), rather than
  silently dropping the subtask.
- No automated tests existed for this wave; verification was manual
  (install → inspect `~/.claude` → uninstall → inspect restore).
