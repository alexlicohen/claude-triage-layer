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

# 2. Remove installed files (agents, rubric, statusline, hook, workflow, per-agent memory)
rm -f "$CLAUDE_DIR"/agents/triage-*.md "$CLAUDE_DIR/triage.md" "$CLAUDE_DIR/statusline.sh"
rm -f "$CLAUDE_DIR/hooks/triage-verify.sh" "$CLAUDE_DIR/workflows/triage-run.js"
rm -rf "$CLAUDE_DIR"/agent-memory/triage-*

# 2b. Remove the SubagentStop hook entry from settings (leaves other hooks intact)
if [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq --arg hook "$CLAUDE_DIR/hooks/triage-verify.sh" '
    if .hooks.SubagentStop
      then .hooks.SubagentStop |= map(select((.hooks // [] | map(.command) | index($hook)) | not))
      else . end
    | if (.hooks.SubagentStop // []) == [] then del(.hooks.SubagentStop) else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

# 3. Restore the three settings keys from the pre-install snapshot
if [ -f "$SETTINGS" ] && [ -f "$PREINSTALL" ]; then
  tmp=$(mktemp)
  jq --slurpfile pre "$PREINSTALL" '
    . as $cur | $pre[0] as $p
    | (if $p.model       == null then del($cur.model)       else $cur * {model: $p.model}             end) as $cur
    | (if $p.effortLevel == null then del($cur.effortLevel) else $cur * {effortLevel: $p.effortLevel} end) as $cur
    | (if $p.statusLine  == null then del($cur.statusLine)  else $cur * {statusLine: $p.statusLine}   end)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  rm -f "$PREINSTALL"
  echo "Restored model/effortLevel/statusLine from pre-install snapshot."
else
  echo "No pre-install snapshot found — review model/effortLevel/statusLine in $SETTINGS manually."
fi

echo "Uninstalled. New Claude Code sessions will no longer use the triage layer."
