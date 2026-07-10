#!/bin/bash
# Install the Claude Code model-triage layer into ~/.claude (or $CLAUDE_DIR).
# Safe to re-run. Requires jq for the settings merge and statusline.
#
# Flags:
#   --dry-run     print the full mutation plan, write NOTHING.
#   --files-only  copy/chmod the installed FILES only (agents, statusline.sh,
#                 workflows/triage-run.js, scripts/triage-usage.sh, triage.md).
#                 Skips CLAUDE.md, settings.json, permissions, and the
#                 preinstall snapshot entirely. Files listed in .driftignore
#                 (deliberate personal forks, e.g. triage.md) are skipped
#                 rather than clobbered. This is the "make sync" primitive.
# The two flags compose: --dry-run --files-only plans only the file ops.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"
DRIFTIGNORE="$REPO_DIR/.driftignore"

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
  if [ "$(version_lt "$ver" "2.1.187")" = "1" ]; then
    echo "⚠ WARNING: Claude Code $ver < 2.1.187 — /triage-run's classify stage can loop on schema-validation retries on this version."
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

# =============================================================================
# 1. Installed files (agents, statusline, /triage-run workflow, usage script,
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
install_file "workflows/triage-run.js" "$CLAUDE_DIR/workflows/triage-run.js"
install_file "scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh" x
install_file "scripts/triage-stats.sh" "$CLAUDE_DIR/scripts/triage-stats.sh" x

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
# 3. Merge settings (model, effortLevel, statusLine) + 3b. permission rules
# =============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  CUR_SETTINGS_JSON="{}"
  [ -f "$SETTINGS" ] && CUR_SETTINGS_JSON="$(cat "$SETTINGS")"

  echo ""
  echo "settings.json ($SETTINGS):"
  cur_model=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.model // "null"')
  if [ "$cur_model" = "opus[1m]" ]; then
    echo "  model: already opus[1m]"
  else
    echo "  model: would set $cur_model -> opus[1m]"
  fi
  cur_effort=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.effortLevel // "null"')
  if [ "$cur_effort" = "high" ]; then
    echo "  effortLevel: already high"
  else
    echo "  effortLevel: would set $cur_effort -> high"
  fi
  cur_statusline=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.statusLine.command // "null"')
  if [ "$cur_statusline" = "$CLAUDE_DIR/statusline.sh" ]; then
    echo "  statusLine: already $CLAUDE_DIR/statusline.sh"
  else
    echo "  statusLine: would set $cur_statusline -> {type: command, command: $CLAUDE_DIR/statusline.sh}"
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
  echo "Preinstall snapshot ($PREINSTALL):"
  if [ -f "$PREINSTALL" ]; then
    echo "  already exists — would NOT be overwritten"
  else
    echo "  would be created, capturing current statusLine=$cur_statusline"
    echo "  (model/effortLevel are NOT captured — uninstall leaves them as you set them, it never reverts them)"
  fi

  echo ""
  echo "No changes were made (--dry-run)."
  exit 0
fi

# 3. Merge settings (model, effortLevel, statusLine), saving prior statusLine first
#    (settings.json was already validated as JSON upfront, above). Only statusLine is
#    snapshotted/restorable: its script gets deleted on uninstall (step 2 there), so a
#    stale command would break the statusline if not restored. model/effortLevel are
#    this layer's opinionated defaults — uninstall intentionally leaves them as you set
#    them rather than reverting, so there's nothing to capture for those two.
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if [ ! -f "$PREINSTALL" ]; then
  jq '{statusLine: (.statusLine // null)}' "$SETTINGS" > "$PREINSTALL"
  cp "$SETTINGS" "$SETTINGS.triage-preinstall.bak"   # full backup, for rolling back a bad merge
  echo "Saved pre-install statusLine to $PREINSTALL"
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
echo "  - On a Pro plan (not Max), Opus 1M bills extra usage credits:"
echo "    change \"model\" to \"opus\" in $SETTINGS to stay on 200K context."
echo "  - Kill switch: remove the @triage.md line from $CLAUDE_DIR/CLAUDE.md."
echo "  - Full removal: ./uninstall.sh"
