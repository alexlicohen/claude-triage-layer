#!/bin/bash
# Install the Claude Code model-triage layer into ~/.claude (or $CLAUDE_DIR).
# Safe to re-run. Requires jq for the settings merge and statusline.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }

mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/workflows"

# 1. Tier agents (with `memory: project`) + rubric + statusline + /triage-run workflow
cp "$REPO_DIR"/agents/triage-*.md "$CLAUDE_DIR/agents/"
cp "$REPO_DIR/triage.md" "$CLAUDE_DIR/triage.md"
cp "$REPO_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
cp "$REPO_DIR/workflows/triage-run.js" "$CLAUDE_DIR/workflows/triage-run.js"

# 2. Wire the rubric into the global CLAUDE.md (append-only; never overwrites)
touch "$CLAUDE_DIR/CLAUDE.md"
grep -qxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md" || printf '@triage.md\n' >> "$CLAUDE_DIR/CLAUDE.md"

# 3. Merge settings (model, effortLevel, statusLine), saving prior values first
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if [ ! -f "$PREINSTALL" ]; then
  jq '{model: (.model // null), effortLevel: (.effortLevel // null), statusLine: (.statusLine // null)}' \
    "$SETTINGS" > "$PREINSTALL"
  echo "Saved pre-install settings to $PREINSTALL"
fi
tmp=$(mktemp)
jq --arg cmd "$CLAUDE_DIR/statusline.sh" \
  '.model = "opus[1m]" | .effortLevel = "high"
   | .statusLine = {type: "command", command: $cmd}' \
  "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# 3b. Harness-level routing rules (idempotent; appends only what's missing and
#     preserves existing rules + order). Enforces the rubric at the permission layer:
#       - `ask` before any Fable spawn → confirms the costly tier (the ⚠ rule, enforced)
#       - `allow` the worker spawns    → fan-out never prompts (a worker's OWN Bash/Edit
#                                         calls stay gated by your normal permissions)
#     Gate by agent TYPE, not `model:` — `Agent(type)` enforcement for named subagent
#     spawns landed in Claude Code 2.1.186; matching a frontmatter-set `model:` is
#     unverified. Switch the `ask` to `deny` below to hard-block Fable instead.
tmp=$(mktemp)
jq '
  ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)"] as $workers
  | ["Agent(triage-fable-architect)"] as $fable
  | .permissions.allow = ((.permissions.allow // []) + ($workers - (.permissions.allow // [])))
  | .permissions.ask   = ((.permissions.ask   // []) + ($fable   - (.permissions.ask   // [])))
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# 4. Billing-safety warning
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "⚠ WARNING: ANTHROPIC_API_KEY is set in your environment."
  echo "  It takes precedence over your subscription login — Claude Code will"
  echo "  bill the API instead of your plan. Unset it to stay on subscription."
fi

echo "Installed. Start a NEW Claude Code session to activate."
echo "  - On a Pro plan (not Max), Opus 1M bills extra usage credits:"
echo "    change \"model\" to \"opus\" in $SETTINGS to stay on 200K context."
echo "  - Kill switch: remove the @triage.md line from $CLAUDE_DIR/CLAUDE.md."
echo "  - Full removal: ./uninstall.sh"
