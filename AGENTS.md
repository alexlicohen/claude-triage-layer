# claude-triage-layer — working rules

- **One green gate:** `make verify` (lint+shellcheck → drift → 4 test suites, 300 checks + the 64-check agy-run suite). Run it before accepting any change; never assert green without its output. `make mutate` runs the strict 23-mutation teeth check (any survivor fails) — it's also a CI step.
- **Danger zone:** `workflows/triage-exec.js` (executes the rubric; the `overflow` tier is plan-time only and never takes `danger` work off-vendor; Workflow-DSL constraints: `meta` stays a pure literal, no `Date.now`/`Math.random`/argless `new Date()`), `install.sh`, `uninstall.sh`, and `scripts/agy-run.sh` (single owner of every agy invocation: success gate, deny-list, worktree staging). Changes here need `test/workflow-scenarios.mjs` / round-trip coverage, not just eyeballs.
- **Syncing to the live install:** `make sync` (= `install.sh --files-only`) — never hand-`cp` into `~/.claude`, bare `install.sh` is safe on a customized machine since Wave 9 (it no longer touches `model`/`effortLevel`/`statusLine`; it only adds `env.CLAUDE_CODE_SUBAGENT_MODEL`/`subagentPromptCacheTtl` when unset). Files listed in `.driftignore` are deliberate personal forks (currently `triage.md`) — sync skips them; drift reports them as `forked (expected)`.
- **Single owners:** per-agent tally math lives in `scripts/triage-usage.sh` (stats/statusline consume it, never re-derive); in `triage-exec.js`, verdict parsing lives in `assess()`, the entry-contract validation in `bad()`/the top-of-file arg checks, the budget spawn decision in `spawn()`, the reviewer's presence in `reviewWanted()`, and the returned distillate in `report()`; the expected-fork list is `.driftignore`; the shipped-`triage-run.js` checksum list is `SHIPPED_TRIAGE_RUN_SHA256` in `install.sh`.
- **Tests must have teeth:** new guards get a mutation in `qc/mutate.sh`'s catalog plus a covering test. Anchors in the catalog are content-based — refresh them when refactoring an anchored region.
- **CHANGELOG.md by wave**, with commit hashes, check-count deltas, and honest deferred-items lists.
- **Direct pushes to `main` are blocked** by the local permission mode — merge via PR (`gh pr create` + `gh pr merge`).

## Memory
Durable context: `PROJECT_MEMORY.md` at the repo root (local-only, untracked — see `.gitignore`).
Operational facts, decisions and rationale only. Read before editing; append dated entries.
