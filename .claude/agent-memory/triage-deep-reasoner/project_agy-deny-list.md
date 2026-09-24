---
name: agy-deny-list
description: external-CLI deny-list is clip-creator ONLY (engram removed 2026-09-15); from Wave 12 clip-creator is hard-denied for every vendor and markers are per vendor
metadata:
  type: project
---

clip-creator is the only default-denied repo; `engram` came off on 2026-09-15.
Wave 12 (branch wave12-codex, 2026-09-23): `agy-run.sh` became `scripts/ext-run.sh`
(vendors agy|codex). clip-creator is hard-denied for every vendor and no env var can
drop it; `AGY_DENY_REPOS`/`CODEX_DENY_REPOS` only add names. Markers are per vendor:
`.agy-deny` blocks agy only, `.codex-deny` blocks codex only. `AGY_BOUNDARY_CLEARED=1`
is required for both.

**Why:** engram's content already lives on Google Drive, so routing it out adds no
exposure. Alex decided 2026-09-23 that Codex gets the same boundary as agy.

**How to apply:** treat engram as an ordinary repo for external routing. Guards:
`test/ext-run.sh` R3b (engram not denied), C6a-C6i (per-vendor deny), mutations
15 and 26. An older note saying the deny-list is "engram + clip-creator", or that
`.agy-deny` blocks every external agent, is stale.
