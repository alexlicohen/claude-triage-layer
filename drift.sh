#!/bin/bash
# Compare the installed copies under ~/.claude (or $CLAUDE_DIR) against this
# repo, file-by-file, for: the 7 agents, statusline.sh, workflows/triage-exec.js
# triage-compare.js and triage-parity.js, the scripts (incl. ext-run.sh, patch-check.sh, stage-worktree.sh, review-stage.sh,
# parity-suite.sh, parity-cost.sh and parity-report.sh), config/tiers.json (installed as
# scripts/triage-tiers.json), triage.md. Prints one of `same` / `MISSING (not installed)` / `FORKED` per
# file (or `forked (expected)` for files listed in .driftignore), then a warn-only
# "settings migration pending" line for each settings.json change a bare install
# would still make (install.sh --settings-status).
#
# Exit non-zero only on UNEXPECTED drift (FORKED on a file not in
# .driftignore, or an unexpected MISSING — see below). If ~/.claude has no
# triage install at all, this is not drift — it prints a loud INCOMPLETE
# notice and exits 0 so CI (which never has an install) passes cleanly.
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DRIFTIGNORE="$REPO_DIR/.driftignore"

# No install at all -> nothing to compare; not a failure.
if [ ! -f "$CLAUDE_DIR/agents/triage-quick-task.md" ]; then
  echo "no install detected — drift check skipped (INCOMPLETE)"
  exit 0
fi

# Normalized exactly as install.sh's is_ignored (CR and surrounding whitespace
# stripped), so the two always agree on what an expected fork is.
is_ignored() { # $1 = repo-relative path
  [ -f "$DRIFTIGNORE" ] || return 1
  tr -d '\r' < "$DRIFTIGNORE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^#' | grep -qxF "$1"
}

UNEXPECTED_DRIFT=0

check_file() { # $1 = repo-relative src path, $2 = installed dest path
  src="$REPO_DIR/$1"
  dst="$2"
  if [ ! -f "$dst" ]; then
    # A missing file in an otherwise-present install IS drift (e.g. a file the
    # repo added that was never synced) — unless expected via .driftignore.
    if is_ignored "$1"; then
      echo "missing (expected): $1"
    else
      echo "MISSING (not installed): $1"
      UNEXPECTED_DRIFT=1
    fi
    return
  fi
  if cmp -s "$src" "$dst"; then
    echo "same: $1"
  else
    if is_ignored "$1"; then
      echo "forked (expected): $1"
    else
      echo "FORKED: $1"
      UNEXPECTED_DRIFT=1
    fi
  fi
}

for f in "$REPO_DIR"/agents/triage-*.md; do
  base=$(basename "$f")
  check_file "agents/$base" "$CLAUDE_DIR/agents/$base"
done

check_file "statusline.sh" "$CLAUDE_DIR/statusline.sh"
check_file "workflows/triage-exec.js" "$CLAUDE_DIR/workflows/triage-exec.js"
check_file "workflows/triage-compare.js" "$CLAUDE_DIR/workflows/triage-compare.js"
check_file "workflows/triage-parity.js" "$CLAUDE_DIR/workflows/triage-parity.js"
check_file "scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh"
check_file "scripts/triage-stats.sh" "$CLAUDE_DIR/scripts/triage-stats.sh"
check_file "scripts/triage-cache-segment.sh" "$CLAUDE_DIR/scripts/triage-cache-segment.sh"
check_file "scripts/ext-run.sh" "$CLAUDE_DIR/scripts/ext-run.sh"
check_file "scripts/patch-check.sh" "$CLAUDE_DIR/scripts/patch-check.sh"
check_file "scripts/stage-worktree.sh" "$CLAUDE_DIR/scripts/stage-worktree.sh"
check_file "scripts/review-stage.sh" "$CLAUDE_DIR/scripts/review-stage.sh"
check_file "scripts/parity-suite.sh" "$CLAUDE_DIR/scripts/parity-suite.sh"
check_file "scripts/parity-cost.sh" "$CLAUDE_DIR/scripts/parity-cost.sh"
check_file "scripts/parity-report.sh" "$CLAUDE_DIR/scripts/parity-report.sh"
check_file "scripts/triage-tiers.sh" "$CLAUDE_DIR/scripts/triage-tiers.sh"
check_file "config/tiers.json" "$CLAUDE_DIR/scripts/triage-tiers.json"
check_file "triage.md" "$CLAUDE_DIR/triage.md"

# Warn-only: a forced subagent model silently collapses every tier onto one model, so
# the installed files can be byte-identical while the routing they encode is inert. This
# is NOT drift — it never touches UNEXPECTED_DRIFT or the exit code. Deliberately jq-free
# (drift.sh has no jq dependency): a grep for the key name in settings.json is enough.
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" ] || \
   { [ -f "$CLAUDE_DIR/settings.json" ] && grep -q 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE' "$CLAUDE_DIR/settings.json"; }; then
  echo "⚠ CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set — every tier collapses onto one model; per-tier routing is inert."
fi

# Warn-only: settings.json changes a bare ./install.sh would still make but `make sync`
# (--files-only) never does, e.g. a subagent model left at an earlier installer default.
# The decision is install.sh's (--settings-status, read-only); needs jq, like install.
if [ -f "$CLAUDE_DIR/settings.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    CLAUDE_DIR="$CLAUDE_DIR" "$REPO_DIR/install.sh" --settings-status 2>&1 | sed 's/^/⚠ /'
  else
    echo "settings check skipped (jq not installed)"
  fi
fi

if [ "$UNEXPECTED_DRIFT" -ne 0 ]; then
  echo ""
  echo "DRIFT: unexpected fork(s) detected (not listed in .driftignore)"
  exit 1
fi

exit 0
