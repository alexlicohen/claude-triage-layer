# Changelog

Reverse-chronological. Each entry cites the commit(s) it corresponds to and,
where known, the test-count delta. See `test/roundtrip.sh` and `test/lint.sh`
for the current check catalog.

## Wave 12 — vendor-neutral tiers: Codex alongside agy, level/vendor/role split

`8a2df13`, `6920ee2`, run C: compare workflow + `patch-check.sh` + installer fork
fix — hash TBD (branch `wave12-codex`, in progress at time of writing).

- **Tier model separated into three axes.** The old 7-tier list mixed difficulty,
  vendor and role. Now: **level** (`quick|builder|deep|top`, `top` replaces
  `fable` as the name — `fable` kept as the `top`+claude alias) describes the
  task, never a model; **vendor** (`claude|codex|agy`) says who serves it, read
  from data, not code; **role** (`implement`/`review`/`read`) is unchanged.
  `overflow` stops being a tier — it's `builder` + `vendor:'agy'`, with
  `overflow:true`/`tier:'overflow'` kept as aliases. Agent `triage-overflow` →
  `triage-external` (any vendor, any level a vendor serves); the other six agent
  names are unchanged. Decision basis: Alex 2026-09-23 — Codex (`gpt-6-astra`) is
  at rough parity with Fable 5.1, Opus 5.5 stays top tier; any level is open to
  Codex while that holds, rechecked periodically by a parity workflow.
- **`config/tiers.json`** (`8a2df13`): the single place that names a model id or
  effort, Claude or external — installed as `~/.claude/scripts/triage-tiers.json`.
  Each entry carries a `basis` (`alex <date>` / `incumbent <date>` / `guess`).
  `make tiers` (`scripts/tiers-sync.sh`) rewrites `agents/*.md` frontmatter to
  match; `test/lint.sh` fails on drift. `scripts/triage-tiers.sh` prints the
  level × vendor table and flags `guess` entries. Edit loop: edit the file →
  `make tiers` → `make verify`.
- **`scripts/agy-run.sh` → `scripts/ext-run.sh`** (`8a2df13`, `git mv`): adds
  `--vendor agy|codex` and `--level` (build mode, resolves model/effort from
  `config/tiers.json`). Codex adapter: `codex exec -C RUNDIR -s
  read-only|workspace-write -m M -c model_reasoning_effort=E --ephemeral
  --skip-git-repo-check --ignore-user-config --json -o LAST [--output-schema F]`,
  a bash-3.2-safe wall-clock watchdog (codex has no print-timeout), and a
  non-interactive-worker prompt footer (codex auto-loads `~/.codex/AGENTS.md`).
  **Per-vendor deny**: `clip-creator` hard-denied for every vendor; new
  `.codex-deny` marker + `CODEX_DENY_REPOS`, same walk-to-`$HOME` logic as the
  existing `.agy-deny`. New `--patch-out`/`--check` for compare/bake-off use
  (refuses a dirty tree; runs checks in the worktree outside the model sandbox).
  Exit codes gain `6` (build-mode patch didn't apply; tree left unchanged).
- **`workflows/triage-exec.js`** (`6920ee2`): subtask `level` (alias `tier`),
  optional `vendor` per subtask or plan-wide. `overflow:true` rewrites only
  `builder` subtasks to `vendor:'agy'`. `codex`+`danger` is allowed, effort
  floored at `high`, level lifted to ≥`deep`; `agy` never takes `danger` work.
  External `null`/`UNAVAILABLE` falls back to the same level on Claude, logged
  `codex→claude`; failed checks or `ESCALATE:` climb the normal Claude ladder
  (`redoStep()`) — no automatic escalation to another vendor. `runFable()`
  remains the only path to `top`+claude. `crossReview: true|'agy'|'codex'|'both'`
  (`'both'` = two parallel spawns, findings keyed by vendor). `report()` gains
  `external: {agy, codex}` counts; `overflow` mirrors `external.agy` for
  backward compatibility.
- **Agents**: `triage-external.md` (from `triage-overflow.md`) reads a
  `VENDOR=<agy|codex> LEVEL=<…> EFFORT=<…>` header line; `triage-cross-reviewer`
  reads `VENDOR=`; `triage-fable-architect`'s description becomes "the `top`
  level's Claude slot." Installer swaps the permission entry and removes the
  legacy `triage-overflow.md` only when its bytes match a version this repo
  shipped.
- **Rule 6 rewritten**: "correctness-critical work never goes off-vendor"
  becomes "never to `agy`; `codex` is allowed at any level `config/tiers.json`
  lists for it" (parity by Alex's decision 2026-09-23, re-checked by the parity
  workflow). Data-boundary class (a) — clinical/COI/Fable-retention material
  never to `triage-fable-architect` — is unchanged. Fable escalation is still
  only via `triage-exec`'s `runFable()`, only after a failed/escalated
  `deep@max` attempt.
- **New flow rule**: before a `triage-exec` plan with `builder`/`deep` work, run
  `~/.claude/skills/usage-guard/usage_guard.sh --once`. At Weekly ≥80%, ask once
  (`AskUserQuestion`) whether to shunt the plan to Codex; yes sets the plan's
  `vendor:'codex'`.
- **Cross-vendor second opinion** (verification rule 6) now routes through
  `ext-run.sh` modes with `--vendor agy|codex`, or `crossReview:'both'` for a
  two-vendor pass — still only for substantive/high-risk work or on request,
  plus deliberate parity sampling for the ledger below.
- **Compare / bake-off** (run C, on disk, uncommitted at time of writing —
  hash TBD): `workflows/triage-compare.js` runs `{vendor, level, model?,
  effort?, label?}` candidates in isolation (a Claude worktree spawn, or
  `ext-run.sh build --patch-out --check` externally, one candidate spawn at a
  time in plan order), grades them all in ONE `triage-quick-task` spawn with
  `scripts/patch-check.sh` — applies each candidate's patch to its own fresh
  worktree at a fixed base revision, runs the check there, reports
  `{patch, applies, rc, diffstat, tail}` per patch as JSON, retried once on a
  dead grader — and **never applies anything, never commits or stashes into
  the target repo**; the orchestrator picks, applies with `git apply`, re-runs
  the checks, and appends one line to `~/.agents/evidence/vendor-parity.jsonl`
  (`{date, repo, level, candidates, winner, why}` — scores only, never document
  text). A `top`-level Claude candidate still prints the `⚠ Escalating to
  Fable` line before its spawn.
- **Compare staging fix** (after the first live run, 2026-09-23; uncommitted at
  time of writing). The first live `triage-compare` run failed two ways: (1)
  the `triage-external` wrapper ran `ext-run.sh build --workdir <real repo>`
  without the header's `--patch-out`/`--check` (the session's cached agent
  definition predated bake-off mode), so ext-run applied the codex patch to the
  real working tree and the next candidate saw it; (2) the Claude candidate's
  `isolation:'worktree'` was based on `main` (5575581), not the session
  branch, so its patch carried whole Wave 12 files and failed to apply — and
  HEAD moved mid-run anyway. Fix: new `scripts/stage-worktree.sh`
  (`create`/`diff`/`leakcheck`/`cleanup`) resolves base to ONE sha and gives
  each candidate its own detached worktree under `<outDir>/stage`; the real
  repo is never a candidate workdir (Claude prompt `cd`s there, external
  `WORKDIR=` is the staged worktree, no `PATCH_OUT`/`CHECK` in the header). One
  grade spawn diffs each worktree (`git add -A` + `diff --binary --cached
  <sha>`), runs `patch-check.sh` at the sha, then `leakcheck` fingerprints the
  real repo (status + content manifest): `LEAK` voids every grade
  (`invalid`, `⚠ LEAK` log), `BASE_MOVED` is flagged and grading stays at the
  sha; cleanup is its own spawn on every path. Dropped: the `PATCH`-line /
  stale-patch rules, `isolation:'worktree'`, the HEAD-only-base rule for
  external candidates, and "repo must be the session repo".
- **Installer fork fix** (run C): a bare `install.sh` (no `--files-only`) used
  to clobber a `.driftignore`-listed personal fork (e.g. a hand-tuned
  `triage.md`) on every run after the first, keeping only a `.bak-triage`
  copy. `is_ignored` is now checked in every install mode whenever the
  installed copy already exists — only a genuine first install still writes
  it. Also installs the two new run-C files: `workflows/triage-compare.js` and
  `scripts/patch-check.sh`.
- **Boundary markers added outside this repo** (independent of this wave, Alex
  approved): `.agy-deny` in `~/projects/grant-forge-use` (its `AGENTS.md` bars
  agy; nothing enforced it before); `.agy-deny` + `.codex-deny` in
  `~/projects/review-editor/realdoc_corpus/` (PHI-adjacent).
- **Codex spike facts** (live `codex exec`, gates the whole wave): nested
  seatbelt sandbox works under Claude Code's own sandbox; `--ignore-user-config`
  keeps ChatGPT auth while dropping the notify hook; `/tmp` needs explicit
  sandbox-exclusion flags or the worker can read outside its workdir; the worker
  auto-loads `~/.codex/AGENTS.md` (the non-interactive-worker prompt footer
  exists because of this).
- **Checks**: `make test` suites, run C totals — 148 (roundtrip) + 24
  (usage-tally) + 139 (ext-run, was 64 pre-wave) + 17 (patch-check, new) + 226
  (workflow-scenarios) + 73 (compare-scenarios, new, was 59) = **627**, up from
  300 pre-wave. `qc/mutate.sh` 23 → 36 (27 after run A, 30 after run B, +3 in
  run C: `triage-compare.js` grading a candidate from its own self-reported
  `CHECK rc` instead of `patch-check`'s result; `patch-check.sh`'s
  `cleanup_wt` becoming a no-op (worktrees left behind); and the bare-install
  fork-clobber bug above — +3 more from three reviewer-confirmed
  `triage-compare.js` defects fixed after the wave: `outDir`/`overlay` not
  required to sit outside `repo`, a stale patch left in `outDir` from a
  previous run getting graded when a candidate's reply carried no `PATCH`
  line, and external candidates running with no `args.files`). Staging fix:
  roundtrip 148 → 149, compare-scenarios 73 → 101, ext-run 139 → 151, new
  stage-worktree suite 31; mutations 36 → 39 (#35, the no-`PATCH`-line guard,
  retired with its rule; +#37 real repo as external `WORKDIR`, +#38 leakcheck
  result ignored, +#39 `stage-worktree.sh diff` dropping new files, +#40
  `ext-run.sh` git-common-dir deny check dropped — a linked worktree outside a
  deny-listed repo bypassed the deny-list).
- **Parity machinery (run D, §5; uncommitted at time of writing — hash TBD).**
  The generic half only: the task suite is private and lives outside this repo
  (`~/.agents/parity/tasks`, a later run); fixtures here are three tiny
  synthetic tasks. `scripts/parity-suite.sh` — `list` (the task format, single
  owner of its validation), `materialize` (clone `--local` or generator, setup
  as one fixed-identity commit => deterministic sha, origin removed, source
  never written; refuses `clip-creator`; **propagates** the source's
  `.agy-deny`/`.codex-deny`/`*_DENY_REPOS` status as `<out>/.<vendor>-deny`,
  because a clone's git-common-dir hides the source from ext-run),
  `verify-task` (base must fail, `solution.patch` must pass, via
  `patch-check.sh`), `score-review` (closest-first seed matching, |Δline| ≤ 3).
  `scripts/parity-cost.sh` — Claude usage per agent label / model / parity
  candidate from a workflow transcript dir (message ids deduped, max usage).
  `workflows/triage-compare.js` gains `parallel:true` (Claude `outTokens` null
  in that mode). New `workflows/triage-parity.js`: loader → per band, tasks in
  parallel → materialize → nested `triage-compare` (build) / read-only
  reviewers + `score-review` (review) / two blind judges on anonymized patches
  (rubric; > 0.3 apart = unresolved, flagged); adaptive stop after N
  consecutive failed bands; `unavailable`/`denied`/`invalid`/`unresolved`
  never count; a compare LEAK aborts; returns ranking, plateaus, a proposed
  tiers change (cheapest clearing candidate at ≥ the incumbent's rate), flags,
  a codex+agy desk-research leg (signal only) and a markdown table — never
  writes tiers.json. Checks: roundtrip 149 → 153, compare-scenarios 101 → 109,
  new parity-suite 69, new parity-scenarios 101 (all suites: 881); mutations
  39 → 45 (#41 unavailable tallied as fail, #42 stop rule not consecutive,
  #43 proposal ignores cheapness, #44 materialize skips deny propagation, #45
  materialize keeps source history/refs). `materialize` no longer clones: it
  `git init`s + `git archive`s the base tree (or discards a generator's own
  history) and commits it as ONE orphan root commit, so a reviewer's repo
  carries no source history, refs or unreachable objects to read (the seeded
  defect / fix could otherwise leak via `git log`/`git show`); the review-task
  reviewer prompt no longer suggests any git-history command.
  Known limit: external review candidates and the codex judge run on
  `triage-cross-reviewer`'s review-mode model (it passes no model/effort
  override), so a codex reviewer is ranked as `modes.codex.review`, not as its
  own model — flagged in every run's result.
- **Deferred**: the private parity task suite (`~/.agents/parity/tasks`) and the
  first live parity run; a live
  end-to-end `triage-exec` run with a real codex builder subtask (today's
  coverage is `test/workflow-scenarios.mjs` mocks only); the reverse direction
  (Codex orchestrating, dispatching to Claude) — explicitly out of scope this
  wave, kept open by making `config/tiers.json` and the parity ledger
  vendor-neutral; `triage-reviewer`'s zero recorded uses — noted, not
  addressed; `AGENTS.md`'s single-owner list and agent/check counts still need
  updating for Wave 12 and are **pending Alex's approval**, per this repo's own
  rule that changes to `AGENTS.md` are shown as a diff first.

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
