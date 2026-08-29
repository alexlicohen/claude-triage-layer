#!/bin/bash
# Remove the Claude Code model-triage layer from ~/.claude (or $CLAUDE_DIR).
#
# Mirrors install.sh exactly: it removes only what the installer wrote. `model`,
# `effortLevel`, and `statusLine` are NEVER touched — the installer does not write
# them, so there is nothing of ours to revert. The two settings keys it does own
# (env.CLAUDE_CODE_SUBAGENT_MODEL, subagentPromptCacheTtl) are removed only while
# they still hold the values we set; a value you changed is yours and is left alone.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"   # legacy artifact of pre-wave-9 installs
AGENTS="triage-quick-task triage-builder triage-deep-reasoner triage-reviewer triage-cross-reviewer triage-fable-architect"

# The two settings.json keys this layer owns — must match install.sh.
SUBAGENT_MODEL="claude-opus-5"
SUBAGENT_CACHE_TTL="1h"

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# Validate settings.json BEFORE any destructive action, so a malformed file makes
# us abort cleanly instead of deleting files and then choking on the jq restore.
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it before uninstalling (nothing was changed)." >&2; exit 1; }
fi

# Write $1 (tmp) over $2 (dest), preserving the link + permissions if $2 is a
# symlink (a plain mv would replace it with a detached regular file).
apply_file() { # $1 = tmp, $2 = dest
  if [ -L "$2" ]; then cat "$1" > "$2" && rm -f "$1"; else mv "$1" "$2"; fi
}

# 1. Unwire the rubric from CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  tmp=$(mktemp)
  grep -vxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md" > "$tmp" || true
  apply_file "$tmp" "$CLAUDE_DIR/CLAUDE.md"
fi

# 2. Remove installed files (agents, rubric, statusline, workflow, per-agent memory).
#    Remove the six agents by name — never `rm triage-*.md` by glob, which would
#    also delete any unrelated triage-* agents you authored yourself.
#    triage-verify.sh is a retired hook current installs no longer ship — remove any
#    stale copy left behind by an older local checkout.
for a in $AGENTS; do
  rm -f "$CLAUDE_DIR/agents/$a.md"
  rm -rf "$CLAUDE_DIR/agent-memory/$a"
done
rm -f "$CLAUDE_DIR/triage.md" "$CLAUDE_DIR/statusline.sh"
rm -f "$CLAUDE_DIR/workflows/triage-exec.js" "$CLAUDE_DIR/workflows/triage-run.js" \
      "$CLAUDE_DIR/scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-stats.sh" \
      "$CLAUDE_DIR/hooks/triage-verify.sh"

# 2b. Remove the triage routing rules from settings.permissions (leaves your other
#     rules and permissions.defaultMode intact). Also drops the Fable rule whether it
#     was left as `ask` or converted to `deny`, and any stale SubagentStop entry from
#     the retired verify hook (for older local checkouts that wired one).
# 2c. Remove the two settings keys the installer owns — but ONLY while they still hold
#     the values it wrote. Repoint the subagent model or change the cache TTL and it is
#     your setting now, so it stays. An `env` object left empty by the removal is
#     deleted rather than left behind as `{}`.
if [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq --arg hook "$CLAUDE_DIR/hooks/triage-verify.sh" \
     --arg m "$SUBAGENT_MODEL" --arg ttl "$SUBAGENT_CACHE_TTL" '
    ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)","Agent(triage-cross-reviewer)"] as $workers
    | ["Agent(triage-fable-architect)"] as $fable
    | (if .permissions.allow then .permissions.allow -= $workers else . end)
    | (if .permissions.ask   then .permissions.ask   -= $fable   else . end)
    | (if .permissions.deny  then .permissions.deny  -= $fable   else . end)
    | (if (.permissions.allow // null) == [] then del(.permissions.allow) else . end)
    | (if (.permissions.ask   // null) == [] then del(.permissions.ask)   else . end)
    | (if (.permissions.deny  // null) == [] then del(.permissions.deny)  else . end)
    | (if (.permissions // {}) == {} then del(.permissions) else . end)
    | (if .hooks.SubagentStop then .hooks.SubagentStop |= map(select((.hooks // [] | map(.command) | index($hook)) | not)) else . end)
    | (if (.hooks.SubagentStop // []) == [] then del(.hooks.SubagentStop) else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
    | (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == $m then del(.env.CLAUDE_CODE_SUBAGENT_MODEL) else . end)
    | (if (.env // null) == {} then del(.env) else . end)
    | (if (.subagentPromptCacheTtl // null) == $ttl then del(.subagentPromptCacheTtl) else . end)
  ' "$SETTINGS" > "$tmp" && apply_file "$tmp" "$SETTINGS"
fi

# 3. statusLine / model / effortLevel are NEVER touched — the installer no longer
#    writes them, so there is nothing of ours to revert. One migration courtesy: an
#    OLD install DID set statusLine to the script we just deleted in step 2, which
#    would leave a broken statusline. Say so loudly and point at the snapshot that
#    old installer saved; restoring it is your call, not ours, so nothing is edited
#    and the snapshot is left in place.
if [ -f "$SETTINGS" ] && [ "$(jq -r '.statusLine.command // ""' "$SETTINGS")" = "$CLAUDE_DIR/statusline.sh" ]; then
  echo "note: settings.json statusLine still points at the just-removed $CLAUDE_DIR/statusline.sh."
  if [ -f "$PREINSTALL" ]; then
    echo "      your pre-install value is in $PREINSTALL — restore or clear the key by hand (snapshot left in place)."
  else
    echo "      clear or repoint the statusLine key by hand."
  fi
fi

echo "Uninstalled. New Claude Code sessions will no longer use the triage layer."
