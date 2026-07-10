# claude-triage-layer — working rules

- **One green gate:** `make verify` (lint+shellcheck → drift → 3 test suites, 138 checks). Run it before accepting any change; never assert green without its output. `make mutate` runs the strict 10-mutation teeth check (any survivor fails) — it's also a CI step.
- **Danger zone:** `workflows/triage-run.js` (codifies the rubric; Workflow-DSL constraints: `meta` stays a pure literal, no `Date.now`/`Math.random`/argless `new Date()`), `install.sh`, `uninstall.sh`. Changes here need `test/workflow-scenarios.mjs` / round-trip coverage, not just eyeballs.
- **Syncing to the live install:** `make sync` (= `install.sh --files-only`) — never hand-`cp` into `~/.claude`, never run bare `install.sh` on an already-customized machine (it rewrites `model`/`effortLevel`/`statusLine`). Files listed in `.driftignore` are deliberate personal forks (currently `triage.md`) — sync skips them; drift reports them as `forked (expected)`.
- **Single owners:** per-agent tally math lives in `scripts/triage-usage.sh` (stats/statusline consume it, never re-derive); verdict parsing in `triage-run.js` lives in `assess()`; the budget spawn decision in `spawn()`; the expected-fork list in `.driftignore`.
- **Tests must have teeth:** new guards get a mutation in `qc/mutate.sh`'s catalog plus a covering test. Anchors in the catalog are content-based — refresh them when refactoring an anchored region.
- **CHANGELOG.md by wave**, with commit hashes, check-count deltas, and honest deferred-items lists.
- **Direct pushes to `main` are blocked** by the local permission mode — merge via PR (`gh pr create` + `gh pr merge`).
