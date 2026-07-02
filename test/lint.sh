#!/bin/bash
# Lint gate for the triage layer.
#   1. `bash -n` (syntax check) on every *.sh in the repo.
#   2. `node --check` on every *.js under workflows/.
#   3. shellcheck (severity=warning) on every *.sh — IF installed. If not,
#      print a loud SKIP and still exit 0 locally (CI always installs
#      shellcheck, so CI gets the full lint; a missing tool locally must
#      never masquerade as a silent pass, hence the loud message).
#   4. Docs-consistency check: every file path referenced in README.md's
#      install / manual-install sections must exist on disk, and README's
#      claim of "five subagent definitions" must match the real agent count.
#
# Fail-loud: accumulates all failures, exits non-zero if any hard failure
# occurred (shellcheck's absence is NOT a hard failure — it's an explicit,
# printed INCOMPLETE for the local run only).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR" || exit 1

FAIL_COUNT=0
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
ok() { echo "OK:   $1"; }

LINT_ERR=$(mktemp)
trap 'rm -f "$LINT_ERR"' EXIT

# --- 1. bash -n on every *.sh (excluding .git) -------------------------------
SH_FILES=$(find . -path ./.git -prune -o -name '*.sh' -print | sed 's#^\./##')
if [ -z "$SH_FILES" ]; then
  fail "no *.sh files found — that itself looks wrong, refusing to silently pass"
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if bash -n "$f" 2>"$LINT_ERR"; then
      ok "bash -n $f"
    else
      fail "bash -n $f"
      cat "$LINT_ERR" >&2
    fi
  done <<EOF
$SH_FILES
EOF
fi

# --- 2. node --check on every *.js under workflows/ --------------------------
if command -v node >/dev/null 2>&1; then
  JS_FILES=$(find workflows -name '*.js' 2>/dev/null)
  if [ -z "$JS_FILES" ]; then
    fail "no *.js files found under workflows/ — expected at least triage-run.js"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if node --check "$f" 2>"$LINT_ERR"; then
        ok "node --check $f"
      else
        fail "node --check $f"
        cat "$LINT_ERR" >&2
      fi
    done <<EOF
$JS_FILES
EOF
  fi
else
  fail "node is not installed — cannot check workflows/*.js (this is a hard failure, not a skip: CI always has node)"
fi

# --- 3. shellcheck (severity=warning), only if installed ---------------------
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if shellcheck --severity=warning "$f"; then
      ok "shellcheck $f"
    else
      fail "shellcheck $f"
    fi
  done <<EOF
$SH_FILES
EOF
else
  echo "SKIP: shellcheck not installed (lint INCOMPLETE — brew install shellcheck)"
fi

# --- 4. docs-consistency: README paths must exist, agent count must match ----
README="README.md"
if [ ! -f "$README" ]; then
  fail "README.md not found — cannot run docs-consistency check"
else
  # Paths the README's install / manual-install sections claim exist.
  DOC_PATHS="statusline.sh triage.md workflows/triage-run.js install.sh uninstall.sh"
  for p in $DOC_PATHS; do
    if [ -e "$p" ]; then
      ok "docs-consistency: $p exists"
    else
      fail "docs-consistency: README references $p but it does not exist"
    fi
  done

  AGENT_COUNT=$(find agents -maxdepth 1 -name 'triage-*.md' | wc -l | tr -d ' ')
  if [ "$AGENT_COUNT" -eq 5 ]; then
    ok "docs-consistency: agents/triage-*.md count is 5, matches README"
  else
    fail "docs-consistency: agents/triage-*.md count is $AGENT_COUNT, README claims 5 (drift)"
  fi

  if grep -qi 'five subagent definitions' "$README"; then
    ok "docs-consistency: README still claims 'five subagent definitions'"
  else
    fail "docs-consistency: README no longer says 'five subagent definitions' — update the doc-consistency check or the README"
  fi
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "LINT: all checks passed"
  exit 0
else
  echo "LINT: $FAIL_COUNT check(s) failed"
  exit 1
fi
