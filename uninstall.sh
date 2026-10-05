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
# The SessionStart hook: only THIS install's hook (a command hook running exactly the
# command install.sh pins to the current CLAUDE_DIR) is deleted (a group it leaves empty
# goes too); your other SessionStart hooks, and hooks pinned to another CLAUDE_DIR,
# stay. This install's CLAUDE.md pointer line and any legacy `@triage.md` import are
# removed, every other byte kept; the kill switch
# file ($CLAUDE_DIR/triage.disabled) is moved to the backup dir, never deleted.
# Order, failing CLOSED: the settings and CLAUDE.md rewrites are both computed (in temp
# files) first — a jq/awk failure aborts with nothing changed; then settings.json is
# written (the hook goes first), then CLAUDE.md, and only then are files removed — a
# write failure stops there, naming what was already changed, so the hook can never be
# left pointing at a removed triage-context.sh.
set -euo pipefail

# The ONE spelling of CLAUDE_DIR — identical to install.sh's (test/roundtrip.sh N8).
canon_dir() {
  local p="$1" out="" c parts
  [ "${p#/}" != "$p" ] || return 1
  case "$p" in *$'\n'*|*$'\r'*) printf '%s' "$p"; return 0 ;; esac
  IFS=/ read -r -a parts <<< "$p"
  for c in ${parts[@]+"${parts[@]}"}; do
    case "$c" in ''|.) continue ;; ..) return 1 ;; esac
    out="$out/$c"
  done
  printf '%s' "${out:-/}"
}
CLAUDE_DIR_GIVEN="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_DIR=$(canon_dir "$CLAUDE_DIR_GIVEN") || { echo "ERROR: CLAUDE_DIR must be an absolute path without .. components (got '$CLAUDE_DIR_GIVEN') — nothing was changed." >&2; exit 1; }
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
PREINSTALL="$CLAUDE_DIR/triage-preinstall.json"   # legacy artifact of pre-wave-9 installs
# triage-overflow is the pre-Wave-12 name of triage-external; an old install may still hold it.
AGENTS="triage-quick-task triage-builder triage-deep-reasoner triage-reviewer triage-cross-reviewer triage-fable-architect triage-external triage-overflow"

# The settings key install.sh owns by value (must match install.sh — test/roundtrip.sh
# case N asserts it), and the env key install.sh writes to record subagent-model ownership.
SUBAGENT_CACHE_TTL="1h"
OWNER_MARK="TRIAGE_LAYER_OWNS_SUBAGENT_MODEL"
# Copies of install.sh's pointer line (POINTER_HEAD + CLAUDE_DIR + POINTER_TAIL), hook
# command and ownership predicate — test/roundtrip.sh case N8 asserts every copy is
# identical. Only THIS install's hook goes: a command hook (.type "command") whose
# command is exactly triage_hook_command for the current CLAUDE_DIR. A hook pinned to
# another CLAUDE_DIR, an unpinned or otherwise different command, or a non-command entry
# carrying our command is yours and stays.
POINTER_HEAD="The triage routing rubric ("
POINTER_TAIL="/triage.md) reaches the main session through a SessionStart hook; if you are the main session and it is not in your context, read that file before planning. Subagents don't need it."
POINTER_TAILS_OLD="/triage.md) reaches the main session through a SessionStart hook; subagents don't receive it."
LEGACY_IMPORT_AWK='function is_legacy(l) { sub(/\r$/, "", l); sub(/[ \t]+$/, "", l); return l == "@triage.md" || l == "@./triage.md" || l == "@~/.claude/triage.md" || l == "@" ENVIRON["TRIAGE_DIR"] "/triage.md" }'
TRIAGE_HOOK_SCRIPT="scripts/triage-context.sh"
TRIAGE_HOOK_OWNED_JQ='type == "object" and .type == "command" and .command == $cmd'
triage_hook_command() { printf 'CLAUDE_DIR=%q bash %q/%s' "$CLAUDE_DIR" "$CLAUDE_DIR" "$TRIAGE_HOOK_SCRIPT"; }
pointer_line() { printf '%s%s%s' "$POINTER_HEAD" "$CLAUDE_DIR" "$POINTER_TAIL"; }
old_pointer_line() { printf '%s%s%s' "$POINTER_HEAD" "$CLAUDE_DIR" "$POINTER_TAILS_OLD"; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$CLAUDE_DIR/triage-uninstall-backup-$STAMP"
i=1
while [ -e "$BACKUP_DIR" ]; do BACKUP_DIR="$CLAUDE_DIR/triage-uninstall-backup-$STAMP-$i"; i=$((i + 1)); done
BACKED_UP=""

tmp=""
SETTINGS_TMP=""
CLAUDE_MD_TMP=""
trap 'rm -f "${tmp:-}" "${SETTINGS_TMP:-}" "${CLAUDE_MD_TMP:-}"' EXIT

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

# File $1 without its legacy import lines (LEGACY_IMPORT_AWK) and its lines equal to $2
# or $3 (a trailing CR ignored), on stdout. Every other byte is kept exactly: each kept
# line keeps its own terminator (CRLF included), and an unterminated last line stays
# unterminated (awk's print would add a newline).
drop_lines() { # $1 = file, $2 $3 = lines
  local nl=1
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then nl=0; fi
  TRIAGE_DIR="$CLAUDE_DIR" awk -v p1="$2" -v p2="$3" -v nl="$nl" "$LEGACY_IMPORT_AWK"'
    NR > 1 && keep { printf "%s\n", prev }
    { prev = $0; l = $0; sub(/\r$/, "", l); keep = !is_legacy($0) && l != p1 && l != p2 }
    END { if (NR > 0 && keep) printf "%s%s", prev, (nl ? "\n" : "") }' "$1"
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
#    2d. SessionStart: only hook entries matching TRIAGE_HOOK_OWNED_JQ are
#    deleted; a group that held one and is left empty is dropped, then an empty
#    SessionStart / hooks key. Every other SessionStart group is left exactly as is.
if [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  SETTINGS_TMP="$tmp"
  jq --arg hook "$CLAUDE_DIR/hooks/triage-verify.sh" \
     --arg ttl "$SUBAGENT_CACHE_TTL" --arg k "$OWNER_MARK" --arg cmd "$(triage_hook_command)" "
    def ours: $TRIAGE_HOOK_OWNED_JQ;"'
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
    | (if (.hooks.SessionStart | type) == "array" then .hooks.SessionStart |= [.[] | if type == "object" and (.hooks | type) == "array" and any(.hooks[]; ours) then (.hooks |= map(select(ours | not))) | (if .hooks == [] then empty else . end) else . end] else . end)
    | (if (.hooks.SessionStart // null) == [] then del(.hooks.SessionStart) else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
    | (.env[$k] // null) as $mark
    | (if $mark != null and (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == $mark then del(.env.CLAUDE_CODE_SUBAGENT_MODEL) else . end)
    | (if .env then del(.env[$k]) else . end)
    | (if (.env // null) == {} then del(.env) else . end)
    | (if (.subagentPromptCacheTtl // null) == $ttl then del(.subagentPromptCacheTtl) else . end)
  ' "$SETTINGS" > "$tmp" || die "settings rewrite (jq) failed — nothing was changed (check the shape of $SETTINGS)."
  SUB_LEFT=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // ""' "$tmp")
fi

# 2. Compute the CLAUDE.md unwiring: the pointer line (current and earlier spellings)
#    and any legacy import (LEGACY_IMPORT_AWK; a trailing CR is ignored, so a CRLF file
#    is unwired too). Fails CLOSED: a read or filter error dies here, before anything is
#    written.
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  CLAUDE_MD_TMP=$(mktemp)
  drop_lines "$CLAUDE_DIR/CLAUDE.md" "$(pointer_line)" "$(old_pointer_line)" > "$CLAUDE_MD_TMP" \
    || die "could not filter $CLAUDE_DIR/CLAUDE.md (awk failed) — nothing was changed."
fi

# 3. Write settings.json FIRST (the hook goes before the script it runs), then
#    CLAUDE.md. A failure stops here, before any file is removed.
if [ -n "$SETTINGS_TMP" ]; then
  apply_file "$SETTINGS_TMP" "$SETTINGS" || die "could not write $SETTINGS — nothing was changed."
  SETTINGS_TMP=""
fi
if [ -n "$CLAUDE_MD_TMP" ]; then
  if cmp -s "$CLAUDE_MD_TMP" "$CLAUDE_DIR/CLAUDE.md"; then
    rm -f "$CLAUDE_MD_TMP"
  else
    apply_file "$CLAUDE_MD_TMP" "$CLAUDE_DIR/CLAUDE.md" \
      || die "could not rewrite $CLAUDE_DIR/CLAUDE.md — settings.json was already updated (the triage hook is gone); no file was removed. Fix it and re-run ./uninstall.sh."
  fi
  CLAUDE_MD_TMP=""
fi

# 4. Remove installed files (agents, rubric, statusline, workflows, scripts) and move
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
         triage-tiers.sh triage-context.sh agy-run.sh; do
  remove_installed "scripts/$s" "$CLAUDE_DIR/scripts/$s"
done
remove_installed "config/tiers.json" "$CLAUDE_DIR/scripts/triage-tiers.json"
remove_installed "hooks/triage-verify.sh" "$CLAUDE_DIR/hooks/triage-verify.sh"
# The kill switch is yours: moved aside with the backups, never deleted.
if [ -e "$CLAUDE_DIR/triage.disabled" ] || [ -L "$CLAUDE_DIR/triage.disabled" ]; then
  backup_move "$CLAUDE_DIR/triage.disabled"
fi

if [ -n "${SUB_LEFT:-}" ]; then
  echo "note: env.CLAUDE_CODE_SUBAGENT_MODEL ($SUB_LEFT) was left in place: it carries no installer ownership marker (you set it, or an install older than the marker did) — remove it by hand if you don't want it."
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
