#!/bin/bash
# Install the Claude Code model-triage layer into ~/.claude (or $CLAUDE_DIR).
# Safe to re-run. Requires jq for the settings merge and statusline.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# Validate settings.json UPFRONT — before copying files or touching CLAUDE.md — so a
# malformed file aborts cleanly instead of leaving a half-applied install.
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it before installing (nothing was changed)." >&2; exit 1; }
fi

# Copy a repo file into place, backing up a locally-modified target first so a
# re-run never silently clobbers edits you made under ~/.claude (e.g. a tuned
# statusline threshold or a hand-edited triage.md).
copy_file() { # $1 = src, $2 = dst
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then
    cp "$2" "$2.bak-triage"
    echo "  note: $2 differed from the repo — saved your copy to $2.bak-triage"
  fi
  cp "$1" "$2"
}

# Write a jq-produced tmp file over $SETTINGS. If $SETTINGS is a symlink (common
# with dotfiles setups), write through it so the link + target permissions are
# preserved; a plain mv would replace it with a detached 0600 regular file.
apply_settings() { # $1 = tmp file
  if [ -L "$SETTINGS" ]; then cat "$1" > "$SETTINGS" && rm -f "$1"; else mv "$1" "$SETTINGS"; fi
}

mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/workflows" "$CLAUDE_DIR/scripts"

# 1. Tier agents (implementation tiers carry `memory: project`) + rubric + statusline + /triage-run workflow
for f in "$REPO_DIR"/agents/triage-*.md; do
  copy_file "$f" "$CLAUDE_DIR/agents/$(basename "$f")"
done
copy_file "$REPO_DIR/triage.md" "$CLAUDE_DIR/triage.md"
copy_file "$REPO_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
copy_file "$REPO_DIR/workflows/triage-run.js" "$CLAUDE_DIR/workflows/triage-run.js"
copy_file "$REPO_DIR/scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh"
chmod +x "$CLAUDE_DIR/scripts/triage-usage.sh"

# 2. Wire the rubric into the global CLAUDE.md (append-only; never overwrites)
touch "$CLAUDE_DIR/CLAUDE.md"
if ! grep -qxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md"; then
  # Ensure the file ends with a newline first, or '@triage.md' fuses onto the last
  # line — corrupting that line AND the import — when CLAUDE.md lacks a final newline.
  if [ -s "$CLAUDE_DIR/CLAUDE.md" ] && [ -n "$(tail -c1 "$CLAUDE_DIR/CLAUDE.md")" ]; then
    printf '\n' >> "$CLAUDE_DIR/CLAUDE.md"
  fi
  printf '@triage.md\n' >> "$CLAUDE_DIR/CLAUDE.md"
fi

# 3. Merge settings (model, effortLevel, statusLine), saving prior values first
#    (settings.json was already validated as JSON upfront, above).
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if [ ! -f "$PREINSTALL" ]; then
  jq '{model: (.model // null), effortLevel: (.effortLevel // null), statusLine: (.statusLine // null)}' \
    "$SETTINGS" > "$PREINSTALL"
  cp "$SETTINGS" "$SETTINGS.triage-preinstall.bak"   # full backup, for rolling back a bad merge
  echo "Saved pre-install settings to $PREINSTALL"
fi
tmp=$(mktemp)
jq --arg cmd "$CLAUDE_DIR/statusline.sh" \
  '.model = "opus[1m]" | .effortLevel = "high"
   | .statusLine = {type: "command", command: $cmd}' \
  "$SETTINGS" > "$tmp" && apply_settings "$tmp"

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
' "$SETTINGS" > "$tmp" && apply_settings "$tmp"

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
