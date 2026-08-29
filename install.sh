#!/bin/bash
# Install the Claude Code model-triage layer into ~/.claude (or $CLAUDE_DIR).
# Safe to re-run. Requires jq for the settings merge and statusline.
#
# Flags:
#   --dry-run     print the full mutation plan, write NOTHING.
#   --files-only  copy/chmod the installed FILES only (agents, statusline.sh,
#                 workflows/triage-exec.js, scripts/triage-usage.sh, triage.md).
#                 Skips CLAUDE.md, settings.json, and permissions entirely.
#                 Files listed in .driftignore (deliberate personal forks, e.g.
#                 triage.md) are skipped rather than clobbered. This is the
#                 "make sync" primitive.
#
# This installer is deliberately NARROW about settings.json: it never writes
# `model`, `effortLevel`, or `statusLine`. Those are your session preferences,
# not this layer's to own — pick your orchestrator model yourself. It writes only
# what the layer actually needs to function (subagent default model, subagent
# prompt-cache TTL, the Agent(...) permission rules), and only when unset.
# The two flags compose: --dry-run --files-only plans only the file ops.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
DRIFTIGNORE="$REPO_DIR/.driftignore"

# The two settings.json keys this layer owns. Both are written ONLY when unset, and
# uninstall removes them ONLY when they still equal these values.
SUBAGENT_MODEL="claude-opus-5"
SUBAGENT_CACHE_TTL="1h"

DRY_RUN=0
FILES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --files-only) FILES_ONLY=1 ;;
    *) echo "ERROR: unknown argument: $arg (supported: --dry-run, --files-only)" >&2; exit 1 ;;
  esac
done

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# Validate settings.json UPFRONT — before copying files or touching CLAUDE.md — so a
# malformed file aborts cleanly instead of leaving a half-applied install. Runs even
# in --dry-run/--files-only: these are read-only checks that should still fail loudly.
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it before installing (nothing was changed)." >&2; exit 1; }
fi

# --- version-compat warning (runs in every mode; NEVER fails the install) ---
# BSD-safe numeric compare of X.Y.Z version strings — no `sort -V` dependency
# (not on stock macOS `sort`). $1 < $2 ?
version_lt() {
  awk -v v1="$1" -v v2="$2" '
    BEGIN {
      n1 = split(v1, a, ".")
      n2 = split(v2, b, ".")
      for (i = 1; i <= 3; i++) {
        x = (i <= n1) ? a[i] + 0 : 0
        y = (i <= n2) ? b[i] + 0 : 0
        if (x < y) { print "1"; exit }
        if (x > y) { print "0"; exit }
      }
      print "0"
    }'
}

check_version_compat() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "⚠ WARNING: could not verify Claude Code version (\`claude\` command not found) — skipping version checks."
    return
  fi
  ver_raw="$(claude --version 2>/dev/null || true)"
  ver="$(printf '%s' "$ver_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  if [ -z "$ver" ]; then
    echo "⚠ WARNING: could not verify Claude Code version (unparseable \`claude --version\` output: '$ver_raw') — skipping version checks."
    return
  fi
  if [ "$(version_lt "$ver" "2.1.172")" = "1" ]; then
    echo "⚠ WARNING: Claude Code $ver < 2.1.172 — per-agent memory (\`memory: project\` in the tier agents) is ignored on this version."
  fi
  if [ "$(version_lt "$ver" "2.1.186")" = "1" ]; then
    echo "⚠ WARNING: Claude Code $ver < 2.1.186 — the installer's permission rules (Agent(...) allow/ask) are a no-op on this version."
  fi
}
check_version_compat

# Files where a live ~/.claude fork is EXPECTED (config-as-data, shared with drift.sh) —
# --files-only skips these instead of clobbering a deliberate personal fork.
is_ignored() { # $1 = repo-relative path
  [ -f "$DRIFTIGNORE" ] || return 1
  grep -vE '^\s*#|^\s*$' "$DRIFTIGNORE" | grep -qxF "$1"
}

# create | overwrite | unchanged — read-only, used by the --dry-run plan.
plan_file_status() { # $1 = src, $2 = dst
  if [ ! -f "$2" ]; then
    echo "create"
  elif cmp -s "$1" "$2"; then
    echo "unchanged"
  else
    echo "overwrite"
  fi
}

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

# Handles one installed file across all three modes (real / --dry-run / --files-only,
# and their composition). $1 = repo-relative src, $2 = dst under CLAUDE_DIR,
# $3 = "x" to chmod +x after copy.
install_file() {
  rel="$1"
  dst="$2"
  mode="${3:-}"
  if [ "$FILES_ONLY" -eq 1 ] && is_ignored "$rel"; then
    echo "  skipped (expected fork): $rel"
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    status=$(plan_file_status "$REPO_DIR/$rel" "$dst")
    case "$status" in
      create) echo "  create: $dst" ;;
      overwrite) echo "  overwrite (differs from repo — backs up to $dst.bak-triage first): $dst" ;;
      unchanged) echo "  unchanged: $dst" ;;
    esac
    return
  fi
  copy_file "$REPO_DIR/$rel" "$dst"
  if [ "$mode" = "x" ]; then
    chmod +x "$dst"
  fi
}

# --- retiring the pre-wave-9 /triage-run workflow ----------------------------
# triage-exec.js replaced triage-run.js (classification moved to the orchestrator).
# An old install leaves triage-run.js behind, where it still registers as a second,
# stale /triage-run command. Remove it — but ONLY when the installed bytes match a
# version this repo actually shipped. A copy you edited yourself is yours: it is left
# alone with a note, never silently deleted. Checksums are of every triage-run.js
# revision in this repo's history (`git log --all -- workflows/triage-run.js`).
SHIPPED_TRIAGE_RUN_SHA256="
3736f0238457f0ca4ee0ecae098d980f806feba1f61b668d5bc89221fa9ee237
393e07dd9e10d5bf60a22ae406c2816ccf529ef80181968b7dc940da23c37ad4
44ad66222c641ddcbf811a7b4883e28d457f1c3e8f088501f3b03d246be023c0
4843fd5ac4caab33ec2a8de8b4c8b6d04c7cfd71fd7d982896e7dff14a33b3dc
627fbfe326ff53a1880edebb191d08d38e2303f86074cbcbc6ecc8362a356993
bbc1769308f6f239062fe05c79d598c19cc8292cabc339328bfd9cf0380b7979
dba7a06f59eaddbaa1fb78b9f81a91b8372af01b21166c3775304c49c0174308
"

# Portable sha256 (macOS ships `shasum`, most Linux images ship `sha256sum`).
# Prints nothing when neither exists — the caller then declines to delete.
file_sha256() { # $1 = file
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

retire_triage_run() {
  old="$CLAUDE_DIR/workflows/triage-run.js"
  [ -f "$old" ] || return 0
  sha=$(file_sha256 "$old")
  if [ -n "$sha" ] && printf '%s' "$SHIPPED_TRIAGE_RUN_SHA256" | grep -qxF "$sha"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  remove (superseded by triage-exec.js, unmodified): $old"
    else
      rm -f "$old"
      echo "  removed superseded workflow: $old (replaced by triage-exec.js)"
    fi
  else
    echo "  note: $old is modified (or unhashable) — left in place. /triage-run will keep appearing alongside /triage-exec until you delete it."
  fi
}

# =============================================================================
# 1. Installed files (agents, statusline, /triage-exec workflow, usage script,
#    triage.md rubric) — the only step --files-only performs.
# =============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Plan (dry run — no changes will be made):"
  echo ""
  echo "Files:"
else
  mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/workflows" "$CLAUDE_DIR/scripts"
fi

for f in "$REPO_DIR"/agents/triage-*.md; do
  base=$(basename "$f")
  install_file "agents/$base" "$CLAUDE_DIR/agents/$base"
done
install_file "triage.md" "$CLAUDE_DIR/triage.md"
install_file "statusline.sh" "$CLAUDE_DIR/statusline.sh" x
install_file "workflows/triage-exec.js" "$CLAUDE_DIR/workflows/triage-exec.js"
install_file "scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh" x
install_file "scripts/triage-stats.sh" "$CLAUDE_DIR/scripts/triage-stats.sh" x
retire_triage_run

if [ "$FILES_ONLY" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    echo "Files synced (--files-only: CLAUDE.md, settings.json, and permissions left untouched)."
  fi
  exit 0
fi

# =============================================================================
# 2. Wire the rubric into the global CLAUDE.md (append-only; never overwrites)
# =============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "CLAUDE.md ($CLAUDE_DIR/CLAUDE.md):"
  if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -qxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md"; then
    echo "  @triage.md already present"
  else
    echo "  would append: @triage.md"
  fi
else
  touch "$CLAUDE_DIR/CLAUDE.md"
  if ! grep -qxF '@triage.md' "$CLAUDE_DIR/CLAUDE.md"; then
    # Ensure the file ends with a newline first, or '@triage.md' fuses onto the last
    # line — corrupting that line AND the import — when CLAUDE.md lacks a final newline.
    if [ -s "$CLAUDE_DIR/CLAUDE.md" ] && [ -n "$(tail -c1 "$CLAUDE_DIR/CLAUDE.md")" ]; then
      printf '\n' >> "$CLAUDE_DIR/CLAUDE.md"
    fi
    printf '@triage.md\n' >> "$CLAUDE_DIR/CLAUDE.md"
  fi
fi

# =============================================================================
# 3. Merge settings (subagent default model + prompt-cache TTL) + 3b. permissions
#
#    NOT written, ever: model, effortLevel, statusLine. Your orchestrator model and
#    your statusline are yours; this layer works with whatever you have chosen.
# =============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  CUR_SETTINGS_JSON="{}"
  [ -f "$SETTINGS" ] && CUR_SETTINGS_JSON="$(cat "$SETTINGS")"

  echo ""
  echo "settings.json ($SETTINGS):"
  echo "  model / effortLevel / statusLine: NOT touched (yours to set)"
  cur_sub=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // "null"')
  if [ "$cur_sub" = "null" ]; then
    echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: would set -> $SUBAGENT_MODEL"
  else
    echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: already set to $cur_sub — left as is"
  fi
  cur_ttl=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.subagentPromptCacheTtl // "null"')
  if [ "$cur_ttl" = "null" ]; then
    echo "  subagentPromptCacheTtl: would set -> $SUBAGENT_CACHE_TTL"
  else
    echo "  subagentPromptCacheTtl: already set to $cur_ttl — left as is"
  fi

  for w in triage-quick-task triage-builder triage-deep-reasoner triage-reviewer triage-cross-reviewer; do
    rule="Agent($w)"
    if printf '%s' "$CUR_SETTINGS_JSON" | jq -e --arg r "$rule" '.permissions.allow // [] | index($r)' >/dev/null 2>&1; then
      echo "  permissions.allow: already present: $rule"
    else
      echo "  permissions.allow: would add: $rule"
    fi
  done
  fable_rule="Agent(triage-fable-architect)"
  if printf '%s' "$CUR_SETTINGS_JSON" | jq -e --arg r "$fable_rule" '.permissions.ask // [] | index($r)' >/dev/null 2>&1; then
    echo "  permissions.ask: already present: $fable_rule"
  else
    echo "  permissions.ask: would add: $fable_rule"
  fi

  echo ""
  echo "No changes were made (--dry-run)."
  exit 0
fi

# 3. Merge the two settings keys this layer owns (settings.json was already validated
#    as JSON upfront, above). Both are set ONLY when absent, so an existing choice of
#    yours always wins and a re-run never overwrites it:
#      env.CLAUDE_CODE_SUBAGENT_MODEL — the default model for any subagent spawn that
#        does not pin one. This is what keeps an un-pinned Agent()/workflow agent()
#        call off the (expensive) orchestrator tier.
#      subagentPromptCacheTtl — extended prompt-cache lifetime for subagents, so a
#        fan-out of workers sharing a brief re-reads a warm cache.
#    No snapshot is taken: nothing here overwrites a pre-existing value, so there is
#    nothing to restore. model/effortLevel/statusLine are never written at all.
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp=$(mktemp)
jq --arg m "$SUBAGENT_MODEL" --arg ttl "$SUBAGENT_CACHE_TTL" '
  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m else . end)
  | (if (.subagentPromptCacheTtl // null) == null then .subagentPromptCacheTtl = $ttl else . end)
' "$SETTINGS" > "$tmp" && apply_settings "$tmp"

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
  ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)","Agent(triage-cross-reviewer)"] as $workers
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
echo "  - Your orchestrator model/effortLevel and statusLine were NOT changed."
echo "    Pick the orchestrator with /model — a frontier model plans best; the tiers do the volume."
echo "  - statusline.sh was copied but NOT wired. To use it, set in $SETTINGS:"
echo "      \"statusLine\": {\"type\": \"command\", \"command\": \"$CLAUDE_DIR/statusline.sh\"}"
echo "  - Kill switch: remove the @triage.md line from $CLAUDE_DIR/CLAUDE.md."
echo "  - Full removal: ./uninstall.sh"
