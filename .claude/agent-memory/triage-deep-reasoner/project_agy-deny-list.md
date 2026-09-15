---
name: agy-deny-list
description: agy cross-vendor deny-list is clip-creator ONLY since 2026-09-15; engram was removed and has a standing regression test
metadata:
  type: project
---

`AGY_DENY_REPOS` default is `clip-creator` alone. `engram` came off on 2026-09-15.

**Why:** engram's content already lives on Google Drive, so routing it to agy adds no
exposure. The 2026-07-10 standing decision is otherwise unchanged — the mechanism
(repo-name component match + `.agy-deny` marker + `AGY_BOUNDARY_CLEARED=1` attestation)
was explicitly kept as-is.

**How to apply:** treat engram as an ordinary repo for agy/cross-reviewer routing.
`test/agy-run.sh` R3b is the guard — it fails if engram is ever re-added to the default,
verified by temporarily restoring the old default. Any older note (including the
project-level auto-memory `agy-antigravity-cli`) saying the deny-list is
"engram + clip-creator" is stale.
