# Changelog

Reverse-chronological. Each entry cites the commit(s) it corresponds to and,
where known, the test-count delta. See `test/roundtrip.sh` and `test/lint.sh`
for the current check catalog.

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
