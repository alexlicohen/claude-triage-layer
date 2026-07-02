#!/bin/bash
# Compare the installed copies under ~/.claude (or $CLAUDE_DIR) against this
# repo, file-by-file, for: the 5 agents, statusline.sh, workflows/triage-run.js,
# triage.md. Prints one of `same` / `MISSING (not installed)` / `FORKED` per
# file (or `forked (expected)` for files listed in .driftignore).
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

is_ignored() { # $1 = repo-relative path
  [ -f "$DRIFTIGNORE" ] || return 1
  grep -vE '^\s*#|^\s*$' "$DRIFTIGNORE" | grep -qxF "$1"
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
check_file "workflows/triage-run.js" "$CLAUDE_DIR/workflows/triage-run.js"
check_file "scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh"
check_file "scripts/triage-stats.sh" "$CLAUDE_DIR/scripts/triage-stats.sh"
check_file "triage.md" "$CLAUDE_DIR/triage.md"

if [ "$UNEXPECTED_DRIFT" -ne 0 ]; then
  echo ""
  echo "DRIFT: unexpected fork(s) detected (not listed in .driftignore)"
  exit 1
fi

exit 0
