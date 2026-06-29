#!/bin/bash
# Remove the Claude Code model-triage layer from ~/.claude (or $CLAUDE_DIR)
# and restore the settings keys captured at install time.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }

# 1. Unwire the rubric from CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  tmp=$(mktemp)
  grep -vxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md" > "$tmp" || true
  mv "$tmp" "$CLAUDE_DIR/CLAUDE.md"
fi

# 2. Remove installed files (agents, rubric, statusline, workflow, per-agent memory).
#    triage-verify.sh is a retired hook current installs no longer ship — remove any
#    stale copy left behind by an older local checkout.
rm -f "$CLAUDE_DIR"/agents/triage-*.md "$CLAUDE_DIR/triage.md" "$CLAUDE_DIR/statusline.sh"
rm -f "$CLAUDE_DIR/workflows/triage-run.js" "$CLAUDE_DIR/hooks/triage-verify.sh"
rm -rf "$CLAUDE_DIR"/agent-memory/triage-*

# 2b. Remove the triage routing rules from settings.permissions (leaves your other
#     rules and permissions.defaultMode intact). Also drops any stale SubagentStop
#     entry from the retired verify hook, for older local checkouts that wired one.
if [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq --arg hook "$CLAUDE_DIR/hooks/triage-verify.sh" '
    ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)"] as $workers
    | ["Agent(triage-fable-architect)"] as $fable
    | (if .permissions.allow then .permissions.allow -= $workers else . end)
    | (if .permissions.ask   then .permissions.ask   -= $fable   else . end)
    | (if (.permissions.allow // null) == [] then del(.permissions.allow) else . end)
    | (if (.permissions.ask   // null) == [] then del(.permissions.ask)   else . end)
    | (if .hooks.SubagentStop then .hooks.SubagentStop |= map(select((.hooks // [] | map(.command) | index($hook)) | not)) else . end)
    | (if (.hooks.SubagentStop // []) == [] then del(.hooks.SubagentStop) else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

# 3. Restore the three settings keys from the pre-install snapshot. A null in the
#    snapshot means the key was unset pre-install, so delete it (don't write a null).
#    On a jq failure, keep the snapshot and warn rather than silently losing it.
if [ -f "$SETTINGS" ] && [ -f "$PREINSTALL" ]; then
  tmp=$(mktemp)
  if jq --slurpfile pre "$PREINSTALL" '
    $pre[0] as $p
    | (if $p.model       == null then del(.model)       else .model       = $p.model       end)
    | (if $p.effortLevel == null then del(.effortLevel) else .effortLevel = $p.effortLevel end)
    | (if $p.statusLine  == null then del(.statusLine)  else .statusLine  = $p.statusLine  end)
  ' "$SETTINGS" > "$tmp"; then
    mv "$tmp" "$SETTINGS"
    rm -f "$PREINSTALL"
    echo "Restored model/effortLevel/statusLine from pre-install snapshot."
  else
    rm -f "$tmp"
    echo "ERROR: could not restore from $PREINSTALL — left it in place; restore model/effortLevel/statusLine manually." >&2
  fi
else
  echo "No pre-install snapshot found — review model/effortLevel/statusLine in $SETTINGS manually."
fi

echo "Uninstalled. New Claude Code sessions will no longer use the triage layer."
