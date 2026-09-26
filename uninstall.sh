#!/bin/bash
# Remove the Claude Code model-triage layer from ~/.claude (or $CLAUDE_DIR).
#
# Mirrors install.sh: it removes only what the installer wrote, and it never destroys
# bytes the repo cannot reproduce. An installed file is deleted only while it is
# byte-identical to this clone's copy; anything else (a hand-edited triage.md fork, a
# tuned statusline, a file from an older install) and every per-agent memory dir is
# MOVED to one backup dir, $CLAUDE_DIR/triage-uninstall-backup-<UTC stamp>/, which is
# named at the end. `model`, `effortLevel`, and `statusLine` are NEVER touched — the
# installer does not write them. Of the two settings keys it does own:
#   env.CLAUDE_CODE_SUBAGENT_MODEL is removed only while it still equals the ownership
#     marker install writes next to it (env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL); the
#     marker itself always goes. No marker (a value you set, or an install made before
#     the marker existed) = left alone, with a note.
#   subagentPromptCacheTtl is removed only while it still holds the value install wrote.
# Settings are rewritten (in a temp file) BEFORE any file is touched, so a jq failure
# aborts with nothing changed.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"   # legacy artifact of pre-wave-9 installs
# triage-overflow is the pre-Wave-12 name of triage-external; an old install may still hold it.
AGENTS="triage-quick-task triage-builder triage-deep-reasoner triage-reviewer triage-cross-reviewer triage-fable-architect triage-external triage-overflow"

# The settings key install.sh owns by value (must match install.sh — test/roundtrip.sh
# case N asserts it), and the env key install.sh writes to record subagent-model ownership.
SUBAGENT_CACHE_TTL="1h"
OWNER_MARK="TRIAGE_LAYER_OWNS_SUBAGENT_MODEL"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$CLAUDE_DIR/triage-uninstall-backup-$STAMP"
i=1
while [ -e "$BACKUP_DIR" ]; do BACKUP_DIR="$CLAUDE_DIR/triage-uninstall-backup-$STAMP-$i"; i=$((i + 1)); done
BACKED_UP=""

tmp=""
SETTINGS_TMP=""
trap 'rm -f "${tmp:-}" "${SETTINGS_TMP:-}"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

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

# Move $1 (a path under CLAUDE_DIR) into BACKUP_DIR, keeping its relative path.
backup_move() {
  local rel
  rel="${1#"$CLAUDE_DIR"/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  mv "$1" "$BACKUP_DIR/$rel"
  BACKED_UP="$BACKED_UP $rel"
}

# Remove one installed file: delete it while it equals the repo copy ($1, repo-relative),
# otherwise (edited, older, or no repo copy at all) move it to the backup dir.
remove_installed() { # $1 = repo-relative source, $2 = installed path
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then return 0; fi
  if [ -f "$REPO_DIR/$1" ] && cmp -s "$REPO_DIR/$1" "$2"; then
    rm -f "$2"
  else
    backup_move "$2"
  fi
}

# 1. Compute the settings rewrite first (nothing is written yet).
#    2b. Remove the triage routing rules from settings.permissions (leaves your other
#    rules and permissions.defaultMode intact). Also drops the Fable rule whether it
#    was left as `ask` or converted to `deny`, and any stale SubagentStop entry from
#    the retired verify hook (for older local checkouts that wired one).
#    2c. The subagent model goes only while it equals the ownership marker; the TTL
#    only while it holds our value. An `env` object left empty is deleted.
if [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  SETTINGS_TMP="$tmp"
  jq --arg hook "$CLAUDE_DIR/hooks/triage-verify.sh" \
     --arg ttl "$SUBAGENT_CACHE_TTL" --arg k "$OWNER_MARK" '
    if type != "object" then error("settings.json is not an object") else . end
    | ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)","Agent(triage-cross-reviewer)","Agent(triage-external)","Agent(triage-overflow)"] as $workers
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
    | (.env[$k] // null) as $mark
    | (if $mark != null and (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == $mark then del(.env.CLAUDE_CODE_SUBAGENT_MODEL) else . end)
    | (if .env then del(.env[$k]) else . end)
    | (if (.env // null) == {} then del(.env) else . end)
    | (if (.subagentPromptCacheTtl // null) == $ttl then del(.subagentPromptCacheTtl) else . end)
  ' "$SETTINGS" > "$tmp" || die "settings rewrite (jq) failed — nothing was changed (check the shape of $SETTINGS)."
  SUB_LEFT=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // ""' "$tmp")
fi

# 2. Unwire the rubric from CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  tmp=$(mktemp)
  grep -vxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md" > "$tmp" || true
  apply_file "$tmp" "$CLAUDE_DIR/CLAUDE.md" || die "could not rewrite $CLAUDE_DIR/CLAUDE.md."
fi

# 3. Remove installed files (agents, rubric, statusline, workflows, scripts) and move
#    per-agent memory aside. The seven agents are removed by name — never
#    `rm triage-*.md` by glob, which would also delete any unrelated triage-* agents
#    you authored yourself. Retired files an older install may have left
#    (triage-overflow.md, workflows/triage-run.js, scripts/agy-run.sh,
#    hooks/triage-verify.sh) have no repo copy, so they are moved aside too.
for a in $AGENTS; do
  remove_installed "agents/$a.md" "$CLAUDE_DIR/agents/$a.md"
  if [ -e "$CLAUDE_DIR/agent-memory/$a" ]; then backup_move "$CLAUDE_DIR/agent-memory/$a"; fi
done
remove_installed "triage.md" "$CLAUDE_DIR/triage.md"
remove_installed "statusline.sh" "$CLAUDE_DIR/statusline.sh"
for w in triage-exec.js triage-compare.js triage-parity.js triage-run.js; do
  remove_installed "workflows/$w" "$CLAUDE_DIR/workflows/$w"
done
for s in triage-usage.sh triage-stats.sh triage-cache-segment.sh ext-run.sh patch-check.sh \
         stage-worktree.sh review-stage.sh parity-suite.sh parity-cost.sh parity-report.sh \
         triage-tiers.sh agy-run.sh; do
  remove_installed "scripts/$s" "$CLAUDE_DIR/scripts/$s"
done
remove_installed "config/tiers.json" "$CLAUDE_DIR/scripts/triage-tiers.json"
remove_installed "hooks/triage-verify.sh" "$CLAUDE_DIR/hooks/triage-verify.sh"

# 4. Apply the settings rewrite computed in step 1.
if [ -n "$SETTINGS_TMP" ]; then
  apply_file "$SETTINGS_TMP" "$SETTINGS" || die "could not write $SETTINGS."
  if [ -n "$SUB_LEFT" ]; then
    echo "note: env.CLAUDE_CODE_SUBAGENT_MODEL ($SUB_LEFT) was left in place: it carries no installer ownership marker (you set it, or an install older than the marker did) — remove it by hand if you don't want it."
  fi
fi

# 5. statusLine / model / effortLevel are NEVER touched — the installer no longer
#    writes them, so there is nothing of ours to revert. One migration courtesy: an
#    OLD install DID set statusLine to the script we just removed in step 3, which
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

if [ -n "$BACKED_UP" ]; then
  echo "Backed up (moved, not deleted) to $BACKUP_DIR:"
  for b in $BACKED_UP; do echo "  $b"; done
  echo "  (edited or older copies, and per-agent memory — delete the dir when you no longer need them)"
fi
echo "Uninstalled. New Claude Code sessions will no longer use the triage layer."
