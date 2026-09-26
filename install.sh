#!/bin/bash
# Install the Claude Code model-triage layer into ~/.claude (or $CLAUDE_DIR).
# Safe to re-run. Requires jq for the settings merge and statusline.
#
# Flags:
#   --dry-run     print the full mutation plan, write NOTHING.
#   --files-only  copy/chmod the installed FILES only (agents, statusline.sh,
#                 workflows/triage-exec.js + triage-compare.js + triage-parity.js, scripts/*, the
#                 tiers file as scripts/triage-tiers.json, triage.md).
#                 Skips CLAUDE.md, settings.json, and permissions entirely.
#                 This is the "make sync" primitive.
#   --settings-status  read-only: print one "settings migration pending" line per
#                 settings.json change a bare install would still make that `make sync`
#                 never does (drift.sh calls this); prints nothing when there is none.
#
# A locally modified installed file is backed up before it is overwritten, to
# <file>.bak-triage-<UTC timestamp>; the newest BACKUP_KEEP (5) per file are kept.
#
# Files listed in .driftignore (deliberate personal forks, e.g. triage.md) are
# skipped rather than clobbered in EVERY mode — bare install, --files-only and
# --dry-run alike — whenever the installed copy already exists. Only a first
# install (no copy there yet) writes them.
#
# This installer is deliberately NARROW about settings.json: it never writes
# `model`, `effortLevel`, or `statusLine`. Those are your session preferences,
# not this layer's to own — pick your orchestrator model yourself. It writes only
# what the layer actually needs to function (subagent default model, subagent
# prompt-cache TTL, the Agent(...) permission rules), and only when unset — the one
# exception being a subagent model this installer owns (the env ownership marker, or
# for pre-marker installs a LEGACY_SUBAGENT_MODELS value), which is upgraded.
# --dry-run and --files-only compose: --dry-run --files-only plans only the file ops.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
DRIFTIGNORE="$REPO_DIR/.driftignore"

TIERS_FILE="$REPO_DIR/config/tiers.json"

# The two settings.json keys this layer owns. Both are written ONLY when unset (or,
# for the subagent model, when this installer owns the current value — see below).
# SUBAGENT_MODEL is not a literal here: it is the deep level's Claude model in
# config/tiers.json (the single owner of every model id), read after the jq check.
SUBAGENT_MODEL=""
SUBAGENT_CACHE_TTL="1h"
# Ownership of env.CLAUDE_CODE_SUBAGENT_MODEL is RECORDED, not inferred from its value:
# whenever install writes that key it also writes this env key holding the same value.
# Install upgrades, and uninstall removes, the subagent model only while it still
# equals this marker; a value you set yourself (even one equal to our default) has no
# marker and is never touched.
OWNER_MARK="TRIAGE_LAYER_OWNS_SUBAGENT_MODEL"
# Migration for installs made before the marker existed (<= Wave 15): every value an
# unmarked installer wrote. Install upgrades such a value (and marks it); uninstall does
# NOT remove it without a marker (it says so instead). Frozen: new installs mark.
LEGACY_SUBAGENT_MODELS="claude-opus-5 claude-opus-5-5"
BACKUP_KEEP=5
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Single owner of the legacy-default decision: is $1 a previous installer default?
is_legacy_subagent_model() {
  local v
  for v in $LEGACY_SUBAGENT_MODELS; do
    [ "$1" = "$v" ] && return 0
  done
  return 1
}

DRY_RUN=0
FILES_ONLY=0
SETTINGS_STATUS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --files-only) FILES_ONLY=1 ;;
    --settings-status) SETTINGS_STATUS=1 ;;
    *) echo "ERROR: unknown argument: $arg (supported: --dry-run, --files-only, --settings-status)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# Validate settings.json UPFRONT — before copying files or touching CLAUDE.md — so a
# malformed file aborts cleanly instead of leaving a half-applied install. Runs even
# in --dry-run/--files-only: these are read-only checks that should still fail loudly.
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it before installing (nothing was changed)." >&2; exit 1; }
fi
# Valid JSON of the wrong shape (a top-level array, a string `env`, ...) would make a
# later jq filter fail halfway through the install: refuse it here instead.
if [ -f "$SETTINGS" ]; then
  jq -e 'type == "object"
    and ((.env // {}) | type == "object")
    and ((.permissions // {}) | type == "object")
    and ((.permissions.allow // []) | type == "array")
    and ((.permissions.ask // []) | type == "array")' "$SETTINGS" >/dev/null 2>&1 \
    || die "$SETTINGS has an unexpected shape (want an object whose env/permissions are objects and permissions.allow/ask arrays) — fix it before installing (nothing was changed)."
fi

# The subagent default model = the deep level's Claude model (config/tiers.json).
SUBAGENT_MODEL="$(jq -r '.levels.deep.claude.model // empty | strings' "$TIERS_FILE" 2>/dev/null || true)"
case "$SUBAGENT_MODEL" in
  claude-*) ;;
  *) die "$TIERS_FILE has no Claude model id at .levels.deep.claude.model (got '${SUBAGENT_MODEL}') — nothing was changed." ;;
esac

# Single owner of the subagent-model decision. $1 = current value, $2 = the ownership
# marker (both "null" when unset). Prints: set | current | upgrade-owned |
# upgrade-legacy | user.
sub_model_action() {
  if [ "$1" = "null" ]; then echo "set"
  elif [ "$1" = "$SUBAGENT_MODEL" ]; then echo "current"
  elif [ "$1" = "$2" ]; then echo "upgrade-owned"
  elif is_legacy_subagent_model "$1"; then echo "upgrade-legacy"
  else echo "user"
  fi
}

# --settings-status: read-only, for drift.sh. Only the settings changes `make sync`
# (--files-only) never makes; nothing to report without a settings.json.
if [ "$SETTINGS_STATUS" -eq 1 ]; then
  [ -f "$SETTINGS" ] || exit 0
  cur_sub=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // "null"' "$SETTINGS")
  cur_mark=$(jq -r --arg k "$OWNER_MARK" '.env[$k] // "null"' "$SETTINGS")
  case "$(sub_model_action "$cur_sub" "$cur_mark")" in
    set) echo "settings migration pending: env.CLAUDE_CODE_SUBAGENT_MODEL is unset — run ./install.sh to set it to $SUBAGENT_MODEL (make sync never edits settings.json)" ;;
    upgrade-owned|upgrade-legacy) echo "settings migration pending: env.CLAUDE_CODE_SUBAGENT_MODEL is $cur_sub, an earlier installer default — run ./install.sh to upgrade it to $SUBAGENT_MODEL (make sync never edits settings.json)" ;;
  esac
  exit 0
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

# --- forced-subagent-model warning (runs in every mode; NEVER fails the install) ---
# CLAUDE_CODE_SUBAGENT_MODEL_FORCE overrides EVERY subagent's own `model:`, collapsing
# all tiers onto one model. The layer keeps working but stops being a triage layer: a
# Haiku brief and a Fable brief cost the same and the tally goes flat. Warn loudly and
# never edit it — if it is set, it was set on purpose, and only you should unset it.
# Safe to read $SETTINGS here: jq presence and `jq empty` validity were both checked above.
check_force_override() {
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" ]; then
    echo "⚠ WARNING: CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set in your environment (${CLAUDE_CODE_SUBAGENT_MODEL_FORCE})."
    echo "  It overrides every tier agent's model: — all tiers collapse onto that one model"
    echo "  and this layer stops routing by cost. Unset it to restore per-tier models."
  fi
  if [ -f "$SETTINGS" ] && [ "$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE // "null"' "$SETTINGS")" != "null" ]; then
    echo "⚠ WARNING: env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set in $SETTINGS."
    echo "  It overrides every tier agent's model: — all tiers collapse onto that one model."
    echo "  Remove that key to restore per-tier models (the installer will not touch it)."
  fi
}
check_force_override

# Files where a live ~/.claude fork is EXPECTED (config-as-data, shared with drift.sh) —
# every mode skips an existing copy instead of clobbering a deliberate personal fork.
# Entries are normalized (CR, surrounding whitespace stripped), so a CRLF or a trailing
# space in .driftignore cannot silently switch fork protection off.
is_ignored() { # $1 = repo-relative path
  [ -f "$DRIFTIGNORE" ] || return 1
  tr -d '\r' < "$DRIFTIGNORE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^#' | grep -qxF "$1"
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

# Single owner of backups. A backup is <file>.bak-triage-<UTC stamp>[-N] (one stamp
# per run, -N only on a same-second clash), so a later sync never overwrites an
# earlier backup; only the newest BACKUP_KEEP per file are kept.
backup_path() { # $1 = file -> prints a fresh backup path
  local b i
  b="$1.bak-triage-$STAMP"
  i=1
  while [ -e "$b" ] || [ -L "$b" ]; do b="$1.bak-triage-$STAMP-$i"; i=$((i + 1)); done
  printf '%s' "$b"
}
prune_backups() { # $1 = file whose timestamped backups to prune to the newest BACKUP_KEEP
  local n b
  n=0
  for b in "$1".bak-triage-[0-9]*; do
    if [ -e "$b" ]; then n=$((n + 1)); fi
  done
  for b in "$1".bak-triage-[0-9]*; do
    [ "$n" -gt "$BACKUP_KEEP" ] || break
    if [ -e "$b" ]; then rm -f "$b"; n=$((n - 1)); fi
  done
}
backup_copy() { # $1 = file -> copy saved to a fresh backup path (printed)
  local b
  b=$(backup_path "$1")
  cp -p "$1" "$b"
  prune_backups "$1"
  printf '%s' "$b"
}
backup_move() { # $1 = file -> moved to a fresh backup path (printed)
  local b
  b=$(backup_path "$1")
  mv "$1" "$b"
  prune_backups "$1"
  printf '%s' "$b"
}

# Copy a repo file into place, backing up a locally-modified target first so a
# re-run never silently clobbers edits you made under ~/.claude (e.g. a tuned
# statusline threshold or a hand-edited triage.md).
copy_file() { # $1 = src, $2 = dst
  local b
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then
    b=$(backup_copy "$2")
    echo "  note: $2 differed from the repo — saved your copy to $b"
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
  # An expected fork is never overwritten, in any mode (a bare install used to
  # clobber it, keeping only a .bak-triage copy). A missing target is a first
  # install, which does get the repo copy.
  if is_ignored "$rel" && [ -e "$dst" ]; then
    echo "  skipped (expected fork): $rel"
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    status=$(plan_file_status "$REPO_DIR/$rel" "$dst")
    case "$status" in
      create) echo "  create: $dst" ;;
      overwrite) echo "  overwrite (differs from repo — backs up to $dst.bak-triage-<timestamp> first): $dst" ;;
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

# --- retiring scripts/agy-run.sh (renamed to ext-run.sh in Wave 12) ----------
# ext-run.sh is the single owner of every external-CLI call now. A leftover
# agy-run.sh would be a second, stale owner with hard-coded model ids and none of
# the per-vendor deny rules. Checksums: every agy-run.sh revision this repo shipped.
SHIPPED_AGY_RUN_SHA256="
4a8c43d68632aebac6a6c632fc6937b23160b45afdb4155a64763048191ef204
a5156feb2d68506c788e091c2c4560681d688decabfc504e96ad3ccc9f8a79a2
"
# --- retiring agents/triage-overflow.md (renamed to triage-external in Wave 12) ---
# A leftover triage-overflow.md would be an eighth, stale agent that knows only agy
# and none of the VENDOR/LEVEL/EFFORT header. Its Agent(triage-overflow) allow rule
# goes in step 3b. Checksums: every triage-overflow.md revision this repo shipped.
SHIPPED_OVERFLOW_AGENT_SHA256="
107c132fba26ddbd5da87e215fb2f49c51f273108c73fe80f02c9e26d3d84bdb
22f23167c50bceb245e02369f717b931aa90d0bcb2973dd6b6b1c2160275da8f
"

# Single owner of retiring a renamed file. Bytes this repo shipped are removed;
# anything else is yours and is moved to a timestamped backup (out of the way of the
# agent/script loaders, never deleted). $1 = installed path, $2 = checksum list,
# $3 = what replaced it.
retire_renamed() {
  local old sums why sha b
  old="$1"; sums="$2"; why="$3"
  [ -f "$old" ] || return 0
  sha=$(file_sha256 "$old")
  if [ -n "$sha" ] && printf '%s' "$sums" | grep -qxF "$sha"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  remove (unmodified; $why): $old"
    else
      rm -f "$old"
      echo "  removed legacy file: $old ($why)"
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "  move aside (modified or unhashable; $why): $old -> $old.bak-triage-<timestamp>"
  else
    b=$(backup_move "$old")
    echo "  note: $old is modified (or unhashable) — moved to $b ($why)"
  fi
}
retire_agy_run() {
  retire_renamed "$CLAUDE_DIR/scripts/agy-run.sh" "$SHIPPED_AGY_RUN_SHA256" "renamed to scripts/ext-run.sh"
}
retire_overflow_agent() {
  retire_renamed "$CLAUDE_DIR/agents/triage-overflow.md" "$SHIPPED_OVERFLOW_AGENT_SHA256" "renamed to agents/triage-external.md"
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
install_file "workflows/triage-compare.js" "$CLAUDE_DIR/workflows/triage-compare.js"
install_file "workflows/triage-parity.js" "$CLAUDE_DIR/workflows/triage-parity.js"
install_file "scripts/triage-usage.sh" "$CLAUDE_DIR/scripts/triage-usage.sh" x
install_file "scripts/triage-stats.sh" "$CLAUDE_DIR/scripts/triage-stats.sh" x
install_file "scripts/triage-cache-segment.sh" "$CLAUDE_DIR/scripts/triage-cache-segment.sh" x
install_file "scripts/ext-run.sh" "$CLAUDE_DIR/scripts/ext-run.sh" x
install_file "scripts/patch-check.sh" "$CLAUDE_DIR/scripts/patch-check.sh" x
install_file "scripts/stage-worktree.sh" "$CLAUDE_DIR/scripts/stage-worktree.sh" x
install_file "scripts/review-stage.sh" "$CLAUDE_DIR/scripts/review-stage.sh" x
install_file "scripts/parity-suite.sh" "$CLAUDE_DIR/scripts/parity-suite.sh" x
install_file "scripts/parity-cost.sh" "$CLAUDE_DIR/scripts/parity-cost.sh" x
install_file "scripts/parity-report.sh" "$CLAUDE_DIR/scripts/parity-report.sh" x
install_file "scripts/triage-tiers.sh" "$CLAUDE_DIR/scripts/triage-tiers.sh" x
install_file "config/tiers.json" "$CLAUDE_DIR/scripts/triage-tiers.json"
retire_triage_run
retire_agy_run
retire_overflow_agent

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
  cur_mark=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r --arg k "$OWNER_MARK" '.env[$k] // "null"')
  case "$(sub_model_action "$cur_sub" "$cur_mark")" in
    set) echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: would set -> $SUBAGENT_MODEL (and env.$OWNER_MARK, the ownership marker)" ;;
    upgrade-owned) echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: would upgrade $cur_sub -> $SUBAGENT_MODEL (set by this installer)" ;;
    upgrade-legacy) echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: would upgrade $cur_sub -> $SUBAGENT_MODEL (previous installer default)" ;;
    *) echo "  env.CLAUDE_CODE_SUBAGENT_MODEL: already set to $cur_sub — left as is" ;;
  esac
  cur_ttl=$(printf '%s' "$CUR_SETTINGS_JSON" | jq -r '.subagentPromptCacheTtl // "null"')
  if [ "$cur_ttl" = "null" ]; then
    echo "  subagentPromptCacheTtl: would set -> $SUBAGENT_CACHE_TTL"
  else
    echo "  subagentPromptCacheTtl: already set to $cur_ttl — left as is"
  fi

  for w in triage-quick-task triage-builder triage-deep-reasoner triage-reviewer triage-cross-reviewer triage-external; do
    rule="Agent($w)"
    if printf '%s' "$CUR_SETTINGS_JSON" | jq -e --arg r "$rule" '.permissions.allow // [] | index($r)' >/dev/null 2>&1; then
      echo "  permissions.allow: already present: $rule"
    else
      echo "  permissions.allow: would add: $rule"
    fi
  done
  if printf '%s' "$CUR_SETTINGS_JSON" | jq -e '.permissions.allow // [] | index("Agent(triage-overflow)")' >/dev/null 2>&1; then
    echo "  permissions.allow: would remove legacy: Agent(triage-overflow) (renamed to triage-external)"
  fi
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
#    as JSON of the right shape upfront, above). Both are set ONLY when absent, so an
#    existing choice of yours always wins and a re-run never overwrites it:
#      env.CLAUDE_CODE_SUBAGENT_MODEL — the default model for any subagent spawn that
#        does not pin one (config/tiers.json's deep Claude model). This is what keeps
#        an un-pinned Agent()/workflow agent() call off the (expensive) orchestrator
#        tier. Whenever install writes it, it writes env.$OWNER_MARK = the same value;
#        a value still equal to that marker (or, for installs made before the marker,
#        to a LEGACY_SUBAGENT_MODELS entry) is ours and is upgraded. A marker that no
#        longer matches (you repointed the model) is dropped: the value is yours now.
#      subagentPromptCacheTtl — extended prompt-cache lifetime for subagents, so a
#        fan-out of workers sharing a brief re-reads a warm cache.
#    No snapshot is taken: the only value ever overwritten is one this installer
#    wrote itself. model/effortLevel/statusLine are never written at all.
#    Any jq or write failure aborts with rc 1 — never "Installed." over a skipped merge.
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cur_sub=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // "null"' "$SETTINGS")
cur_mark=$(jq -r --arg k "$OWNER_MARK" '.env[$k] // "null"' "$SETTINGS")
sub_action=$(sub_model_action "$cur_sub" "$cur_mark")
upgrade_sub=0
case "$sub_action" in upgrade-owned|upgrade-legacy) upgrade_sub=1 ;; esac
tmp=$(mktemp)
jq --arg m "$SUBAGENT_MODEL" --arg ttl "$SUBAGENT_CACHE_TTL" --arg up "$upgrade_sub" --arg k "$OWNER_MARK" '
  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null or $up == "1" then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m | .env[$k] = $m else . end)
  | (if (.env[$k] // null) != null and .env[$k] != .env.CLAUDE_CODE_SUBAGENT_MODEL then del(.env[$k]) else . end)
  | (if (.subagentPromptCacheTtl // null) == null then .subagentPromptCacheTtl = $ttl else . end)
' "$SETTINGS" > "$tmp" || die "settings merge (jq) failed — $SETTINGS left unchanged."
apply_settings "$tmp" || die "could not write $SETTINGS."
case "$sub_action" in
  upgrade-owned) echo "env.CLAUDE_CODE_SUBAGENT_MODEL: upgraded $cur_sub -> $SUBAGENT_MODEL (set by this installer)" ;;
  upgrade-legacy) echo "env.CLAUDE_CODE_SUBAGENT_MODEL: upgraded $cur_sub -> $SUBAGENT_MODEL (previous installer default)" ;;
esac

# 3b. Harness-level routing rules (idempotent; appends only what's missing and
#     preserves existing rules + order). Enforces the rubric at the permission layer:
#       - `ask` before any Fable spawn → confirms the costly tier (the ⚠ rule, enforced)
#       - `allow` the worker spawns    → fan-out never prompts (a worker's OWN Bash/Edit
#                                         calls stay gated by your normal permissions)
#     The pre-Wave-12 Agent(triage-overflow) allow rule is removed: that agent is now
#     triage-external, and a rule for an agent that no longer exists is only noise.
#     Gate by agent TYPE, not `model:` — `Agent(type)` enforcement for named subagent
#     spawns landed in Claude Code 2.1.186; matching a frontmatter-set `model:` is
#     unverified. Switch the `ask` to `deny` below to hard-block Fable instead.
tmp=$(mktemp)
jq '
  ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)","Agent(triage-cross-reviewer)","Agent(triage-external)"] as $workers
  | ["Agent(triage-overflow)"] as $legacy_workers
  | ["Agent(triage-fable-architect)"] as $fable
  | .permissions.allow = (((.permissions.allow // []) - $legacy_workers) + ($workers - (.permissions.allow // [])))
  | .permissions.ask   = ((.permissions.ask   // []) + ($fable   - (.permissions.ask   // [])))
' "$SETTINGS" > "$tmp" || die "permissions merge (jq) failed — the settings keys above were applied, the Agent(...) rules were not."
apply_settings "$tmp" || die "could not write $SETTINGS."

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
