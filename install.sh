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
#                 settings.json / CLAUDE.md change a bare install would still make that
#                 `make sync` never does (drift.sh calls this); prints nothing when there
#                 is none.
#
# The rubric (triage.md) reaches the MAIN session through a SessionStart hook
# (scripts/triage-context.sh), never an `@triage.md` import in CLAUDE.md: SessionStart
# does not fire for subagents, so they no longer load it. A bare install appends that
# hook to settings.json (CLAUDE_DIR pinned in the command; never replacing your other
# SessionStart hooks) and, only after the settings write succeeded, migrates a legacy
# `@triage.md` line out of CLAUDE.md (backed up first; every other byte kept) and
# appends one pointer line (pointer_line, naming this install's triage.md) — unless
# settings.json has disableAllHooks: true, or the installed triage.md fails the hook's
# size check (`triage-context.sh --check`); either leaves CLAUDE.md alone with a
# warning. settings.json is written once, after every settings transformation and the
# CLAUDE.md decision were computed: an evaluation error (jq/awk) aborts with
# settings.json and CLAUDE.md untouched (the installed files may already be updated).
#
# A locally modified installed file is backed up before it is overwritten, to
# <file>.bak-triage-<UTC timestamp>; the newest BACKUP_KEEP (5) per file are kept.
#
# Files listed in .driftignore (deliberate personal forks — none currently) are
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
# The SessionStart hook (single owner of its shape: triage_hook_group; of ownership:
# TRIAGE_HOOK_OWNED_JQ below, mirrored in uninstall.sh). TRIAGE_HOOK_MATCHER is also the
# list of events an installed hook must cover (triage_hook_action).
TRIAGE_HOOK_SCRIPT="scripts/triage-context.sh"
TRIAGE_HOOK_MATCHER="startup|resume|clear|compact"
# The one line install appends to CLAUDE.md: POINTER_HEAD + this install's CLAUDE_DIR +
# POINTER_TAIL (pointer_line, below), so it names the rubric this install's hook reads.
# uninstall.sh removes the identical line (test/roundtrip.sh N8 pins the copies equal).
POINTER_HEAD="The triage routing rubric ("
POINTER_TAIL="/triage.md) reaches the main session through a SessionStart hook; subagents don't receive it."
LEGACY_IMPORT="@triage.md"
# TRIAGE_INSTALL_STAMP: test hook only (forces the same-second clash case).
STAMP="${TRIAGE_INSTALL_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"

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
CLAUDE_MD_NEW=""
SETTINGS_EMPTY=""
trap 'rm -f "${tmp:-}" "${CLAUDE_MD_NEW:-}" "${SETTINGS_EMPTY:-}"' EXIT

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)" >&2; exit 1; }

# Validate settings.json UPFRONT — before copying files or touching CLAUDE.md — so a
# malformed file aborts cleanly instead of leaving a half-applied install. Runs even
# in --dry-run/--files-only: these are read-only checks that should still fail loudly.
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it before installing (nothing was changed)." >&2; exit 1; }
fi
# Valid JSON of the wrong shape (a top-level array, a string `env`, ...) would make a
# later jq filter fail halfway through the install: refuse it here instead.
# Each key may be absent (or null) or of its type; anything else — `false` included,
# which `// default` would have read as absent — is refused.
if [ -f "$SETTINGS" ]; then
  jq -e 'def shape(t): . == null or type == t;
    type == "object"
    and (.env | shape("object"))
    and (.permissions | shape("object"))
    and (.permissions.allow | shape("array"))
    and (.permissions.ask | shape("array"))
    and (.hooks | shape("object"))
    and (.hooks.SessionStart | shape("array"))' "$SETTINGS" >/dev/null 2>&1 \
    || die "$SETTINGS has an unexpected shape (want an object whose env/permissions/hooks are objects and permissions.allow/ask, hooks.SessionStart arrays) — fix it before installing (nothing was changed)."
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

# Single owner of the hook OWNERSHIP predicate, a jq condition on one hook entry with
# $cmd = triage_hook_command (uninstall.sh holds identical copies of it, of
# triage_hook_command and of pointer_line, like LEGACY_SUBAGENT_MODELS' pattern of one
# frozen literal per script; test/roundtrip.sh case N8 fails if they differ). An entry
# is THIS install's hook only when it is a command hook (.type "command") whose command
# is exactly the one triage_hook_command prints for the current CLAUDE_DIR. Anything
# else — a command pinned to another CLAUDE_DIR, an unpinned `bash <dir>/scripts/...`,
# a prompt-type entry carrying our command, `...triage-context.sh.backup` — is foreign:
# never counted as installed, never removed.
TRIAGE_HOOK_OWNED_JQ='type == "object" and .type == "command" and .command == $cmd'

# Single owner of the SessionStart hook decision. Settings JSON on stdin -> prints
# present | add; returns non-zero (prints nothing) when jq itself fails, so a broken
# evaluation is never mistaken for a decision. present = some group holding THIS
# install's hook (TRIAGE_HOOK_OWNED_JQ) has a matcher covering every event in
# TRIAGE_HOOK_MATCHER — startup, resume, clear AND compact (absent, "" and "*" match
# everything; otherwise the `|`-separated names are compared exactly — a regex matcher
# is not interpreted, so it never counts). Anything less -> add: our canonical group is
# appended and your groups are left exactly as they are, never replaced.
triage_hook_action() {
  local rc=0
  jq -e --arg cmd "$(triage_hook_command)" --arg events "$TRIAGE_HOOK_MATCHER" "
    def owned: $TRIAGE_HOOK_OWNED_JQ;"'
    def covers: . == null or . == "" or . == "*"
      or (type == "string" and ((($events | split("|")) - split("|")) == []));
    [(.hooks.SessionStart // []) | .[] | objects
     | select((.hooks | type) == "array" and any(.hooks[]; owned)) | .matcher]
    | any(.[]; covers)' >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "present" ;;
    1) echo "add" ;;
    *) return 1 ;;
  esac
}
# The one hook command install writes. CLAUDE_DIR is PINNED in it, so a non-default
# install reads its own kill switch, legacy guard and triage.md, whatever $HOME is.
# %q leaves an ordinary path as is and escapes anything else (spaces, quotes), so each
# path stays one shell word.
triage_hook_command() { printf 'CLAUDE_DIR=%q bash %q/%s' "$CLAUDE_DIR" "$CLAUDE_DIR" "$TRIAGE_HOOK_SCRIPT"; }
# The pointer line for this install: it names the rubric this install's hook reads.
pointer_line() { printf '%s%s%s' "$POINTER_HEAD" "$CLAUDE_DIR" "$POINTER_TAIL"; }
# The SessionStart group install appends (compact JSON).
triage_hook_group() {
  jq -cn --arg m "$TRIAGE_HOOK_MATCHER" --arg c "$(triage_hook_command)" '{matcher: $m, hooks: [{type: "command", command: $c, timeout: 10}]}'
}
# Does $1 hold the line $2? CRLF-tolerant (a trailing CR is ignored). 0 yes, 1 no (or no
# file), anything else = could not read it: callers fail closed on that.
has_line() { # $1 = file, $2 = line
  [ -e "$1" ] || return 1
  awk -v want="$2" '{ l = $0; sub(/\r$/, "", l); if (l == want) found = 1 } END { exit found ? 0 : 1 }' "$1"
}
# File $1 without its lines equal to $2 (a trailing CR ignored), on stdout. Every other
# byte is kept exactly: each kept line keeps its own terminator (CRLF included), and an
# unterminated last line stays unterminated (awk's print would add a newline).
drop_line() { # $1 = file, $2 = line
  local nl=1
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then nl=0; fi
  awk -v imp="$2" -v nl="$nl" '
    NR > 1 && keep { printf "%s\n", prev }
    { prev = $0; l = $0; sub(/\r$/, "", l); keep = (l != imp) }
    END { if (NR > 0 && keep) printf "%s%s", prev, (nl ? "\n" : "") }' "$1"
}

# Files where a live ~/.claude fork is EXPECTED (config-as-data, shared with drift.sh) —
# every mode skips an existing copy instead of clobbering a deliberate personal fork.
# Entries are normalized (CR, surrounding whitespace stripped), so a CRLF or a trailing
# space in .driftignore cannot silently switch fork protection off.
is_ignored() { # $1 = repo-relative path
  [ -f "$DRIFTIGNORE" ] || return 1
  tr -d '\r' < "$DRIFTIGNORE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^#' | grep -qxF "$1"
}
# The file step 1 leaves at $2 for repo file $1: an expected fork that already exists
# stays, anything else becomes the repo copy. Used where a mode that copies nothing
# (--dry-run, --settings-status) must judge what a bare install would install.
planned_copy() { # $1 = repo-relative src, $2 = installed path
  if is_ignored "$1" && [ -e "$2" ]; then printf '%s' "$2"; else printf '%s' "$REPO_DIR/$1"; fi
}

# Single owner of the migration gate on the rubric: the legacy import may go only when
# the rubric the hook will read passes the hook's own size check (an over-cap rubric
# would arrive as a notice, not the rubric, where the import loaded all of it).
# $1 = the triage-context.sh to ask, $2 = the rubric. Sets RUBRIC_DIAG to its output;
# returns 0 only when the check passed (1 = too big, anything else = could not check).
RUBRIC_DIAG=""
rubric_fits() {
  local rc=0
  RUBRIC_DIAG=$(bash "$1" --check "$2" 2>&1) || rc=$?
  [ -n "$RUBRIC_DIAG" ] || RUBRIC_DIAG="$1 --check $2 exited $rc"
  return "$rc"
}
rubric_note() { # the one diagnostic for a blocked migration (uses RUBRIC_DIAG)
  printf '%s' "the rubric the triage hook would read fails its size check, so CLAUDE.md is NOT migrated (the @triage.md import stays the working wiring; no pointer line): $RUBRIC_DIAG — trim it under the cap, then run ./install.sh."
}

# Preflight for every mode that reads settings.json / CLAUDE.md (not --files-only): all
# settings.json / CLAUDE.md decisions but the rubric gate (rubric_fits, which needs the
# installed rubric) are made HERE, before anything is written, and any evaluation error
# dies with nothing changed. Sets HOOK_ACTION (present|add), HOOKS_OFF (1 when
# settings.json has disableAllHooks: true — the hook could never run, so CLAUDE.md is
# not migrated), LEGACY (1 when CLAUDE.md still has the `@triage.md` import line) and
# POINTER (1 when the pointer line is already there). An absent settings.json is an
# empty one.
# Single owner of "is CLAUDE.md left alone?": sets CLAUDE_MD_BLOCK to the reason it is
# (disableAllHooks, or a legacy import whose replacement rubric fails rubric_fits), or
# "" when install migrates it and appends the pointer. $1 = the triage-context.sh, $2 =
# the rubric that hook will read. Call after hook_preflight.
CLAUDE_MD_BLOCK=""
claude_md_decision() {
  CLAUDE_MD_BLOCK=""
  if [ "$HOOKS_OFF" -eq 1 ]; then
    CLAUDE_MD_BLOCK="$HOOKS_OFF_NOTE"
  elif [ "$LEGACY" -eq 1 ] && ! rubric_fits "$1" "$2"; then
    CLAUDE_MD_BLOCK="$(rubric_note)"
  fi
}

hook_preflight() {
  local cur="{}" rc=0
  # The pointer line embeds CLAUDE_DIR and is matched line by line: a line break in it
  # would split the line, so no install could ever find (or uninstall remove) it again.
  case "$CLAUDE_DIR" in
    *$'\n'*|*$'\r'*) die "CLAUDE_DIR contains a line break — nothing was changed." ;;
  esac
  if [ -f "$SETTINGS" ]; then cur=$(cat "$SETTINGS") || die "could not read $SETTINGS — nothing was changed."; fi
  HOOK_ACTION=$(printf '%s' "$cur" | triage_hook_action) \
    || die "could not evaluate the SessionStart hooks in $SETTINGS (jq failed) — nothing was changed."
  printf '%s' "$cur" | jq -e '.disableAllHooks == true' >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) HOOKS_OFF=1 ;;
    1) HOOKS_OFF=0 ;;
    *) die "could not read disableAllHooks from $SETTINGS (jq failed) — nothing was changed." ;;
  esac
  rc=0; has_line "$CLAUDE_DIR/CLAUDE.md" "$LEGACY_IMPORT" || rc=$?
  case "$rc" in
    0) LEGACY=1 ;;
    1) LEGACY=0 ;;
    *) die "could not read $CLAUDE_DIR/CLAUDE.md — nothing was changed." ;;
  esac
  rc=0; has_line "$CLAUDE_DIR/CLAUDE.md" "$(pointer_line)" || rc=$?
  case "$rc" in
    0) POINTER=1 ;;
    1) POINTER=0 ;;
    *) die "could not read $CLAUDE_DIR/CLAUDE.md — nothing was changed." ;;
  esac
}
HOOKS_OFF_NOTE="disableAllHooks is true in $SETTINGS, so the triage SessionStart hook cannot run: CLAUDE.md is NOT migrated (a legacy @triage.md import stays the working wiring; no pointer line). Without that import the rubric is not loaded at all. Remove disableAllHooks (or set it false), then run ./install.sh."

# --settings-status: read-only, for drift.sh. Only the settings.json / CLAUDE.md
# changes `make sync` (--files-only) never makes. No settings.json = an empty one: a
# bare install would still set the subagent model and add the hook.
if [ "$SETTINGS_STATUS" -eq 1 ]; then
  hook_preflight
  cur_sub=null; cur_mark=null
  if [ -f "$SETTINGS" ]; then
    cur_sub=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // "null"' "$SETTINGS") || die "could not read $SETTINGS (jq failed)."
    cur_mark=$(jq -r --arg k "$OWNER_MARK" '.env[$k] // "null"' "$SETTINGS") || die "could not read $SETTINGS (jq failed)."
  fi
  case "$(sub_model_action "$cur_sub" "$cur_mark")" in
    set) echo "settings migration pending: env.CLAUDE_CODE_SUBAGENT_MODEL is unset — run ./install.sh to set it to $SUBAGENT_MODEL (make sync never edits settings.json)" ;;
    upgrade-owned|upgrade-legacy) echo "settings migration pending: env.CLAUDE_CODE_SUBAGENT_MODEL is $cur_sub, an earlier installer default — run ./install.sh to upgrade it to $SUBAGENT_MODEL (make sync never edits settings.json)" ;;
  esac
  if [ "$HOOK_ACTION" = "add" ]; then
    echo "settings migration pending: triage hook missing (no hooks.SessionStart group runs this install's command, $(triage_hook_command), for $TRIAGE_HOOK_MATCHER) — run ./install.sh to add it (make sync never edits settings.json)"
  fi
  claude_md_decision "$(planned_copy "$TRIAGE_HOOK_SCRIPT" "$CLAUDE_DIR/$TRIAGE_HOOK_SCRIPT")" "$(planned_copy triage.md "$CLAUDE_DIR/triage.md")"
  if [ -n "$CLAUDE_MD_BLOCK" ]; then
    echo "settings migration blocked: $CLAUDE_MD_BLOCK"
  elif [ "$LEGACY" -eq 1 ]; then
    echo "settings migration pending: legacy @triage.md import present in $CLAUDE_DIR/CLAUDE.md (it loads the rubric into every subagent too) — run ./install.sh to replace it with the SessionStart hook"
  fi
  exit 0
fi
[ "$FILES_ONLY" -eq 1 ] || hook_preflight

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

# (is_ignored, the expected-fork test, is defined above hook_preflight.)

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
# Age order is (stamp, N) with N numeric (-10 after -2) and no -N = 0; a clash takes
# one past the HIGHEST N in use, never the first free name — pruning may have freed
# an older name, and reusing it would make the newest backup sort as the oldest.
backups_oldest_first() { # $1 = file -> its backups, oldest first, one per line
  local b rest
  for b in "$1".bak-triage-[0-9]*; do
    [ -e "$b" ] || [ -L "$b" ] || continue
    rest=${b#"$1".bak-triage-}
    case "$rest" in
      *-*) printf '%s %s %s\n' "${rest%%-*}" "${rest#*-}" "$b" ;;
      *)   printf '%s 0 %s\n' "$rest" "$b" ;;
    esac
  done | LC_ALL=C sort -k1,1 -k2,2n | cut -d' ' -f3-
}
backup_path() { # $1 = file -> prints a fresh backup path
  local b n max
  b="$1.bak-triage-$STAMP"
  if [ -e "$b" ] || [ -L "$b" ] || ls -d "$b"-* >/dev/null 2>&1; then
    max=0
    for n in "$b"-*; do
      n=${n#"$b"-}
      case "$n" in ''|*[!0-9]*) continue ;; esac
      if [ "$n" -gt "$max" ]; then max=$n; fi
    done
    b="$b-$((max + 1))"
  fi
  printf '%s' "$b"
}
prune_backups() { # $1 = file whose timestamped backups to prune to the newest BACKUP_KEEP
  local n b
  n=$(backups_oldest_first "$1" | wc -l | tr -d ' ')
  backups_oldest_first "$1" | while IFS= read -r b; do
    [ "$n" -gt "$BACKUP_KEEP" ] || break
    rm -f "$b"; n=$((n - 1))
  done
}
backup_copy() { # $1 = file -> copy saved to a fresh backup path (printed)
  local b
  b=$(backup_path "$1")
  cp -p "$1" "$b" || return 1
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
install_file "scripts/triage-context.sh" "$CLAUDE_DIR/scripts/triage-context.sh" x
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
# 2. Merge settings (subagent default model + prompt-cache TTL) + 2b. permissions
#    + 2c. the SessionStart hook that delivers the rubric. 3. CLAUDE.md (pointer line,
#    legacy @triage.md migration) only after every settings write succeeded.
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
  if [ "$HOOK_ACTION" = "add" ]; then
    echo "  hooks.SessionStart: triage hook missing — would append (your other SessionStart hooks are kept): $(triage_hook_group)"
  else
    echo "  hooks.SessionStart: triage hook already present"
  fi

  echo ""
  echo "CLAUDE.md ($CLAUDE_DIR/CLAUDE.md), only after the settings write succeeds:"
  claude_md_decision "$(planned_copy "$TRIAGE_HOOK_SCRIPT" "$CLAUDE_DIR/$TRIAGE_HOOK_SCRIPT")" "$(planned_copy triage.md "$CLAUDE_DIR/triage.md")"
  if [ -n "$CLAUDE_MD_BLOCK" ]; then
    echo "  ⚠ $CLAUDE_MD_BLOCK"
  else
    if [ "$LEGACY" -eq 1 ]; then
      echo "  legacy @triage.md import present — would remove it (backup to CLAUDE.md.bak-triage-<timestamp> first); the SessionStart hook replaces it"
    fi
    if [ "$POINTER" -eq 1 ]; then
      echo "  pointer line already present"
    else
      echo "  would append pointer line: $(pointer_line)"
    fi
  fi

  echo ""
  echo "No changes were made (--dry-run)."
  exit 0
fi

# 2. ONE settings write: every settings.json transformation (2a-2c) is computed into a
#    temp file first, and settings.json is replaced once, only after all of it
#    succeeded — a jq failure anywhere dies with settings.json (and CLAUDE.md) untouched.
#    settings.json was already validated as JSON of the right shape upfront, above.
#    2a. The two keys this layer owns, set ONLY when absent, so an existing choice of
#    yours always wins and a re-run never overwrites it:
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
#    2b. Harness-level routing rules (idempotent; appends only what's missing and
#    preserves existing rules + order). Enforces the rubric at the permission layer:
#      - `ask` before any Fable spawn → confirms the costly tier (the ⚠ rule, enforced)
#      - `allow` the worker spawns    → fan-out never prompts (a worker's OWN Bash/Edit
#                                        calls stay gated by your normal permissions)
#    The pre-Wave-12 Agent(triage-overflow) allow rule is removed: that agent is now
#    triage-external, and a rule for an agent that no longer exists is only noise.
#    Gate by agent TYPE, not `model:` — `Agent(type)` enforcement for named subagent
#    spawns landed in Claude Code 2.1.186; matching a frontmatter-set `model:` is
#    unverified. Switch the `ask` to `deny` below to hard-block Fable instead.
#    2c. The SessionStart hook that delivers triage.md to the main session: APPENDED as
#    its own group when HOOK_ACTION (decided in hook_preflight) is add; existing
#    SessionStart groups (yours) are never replaced or reordered.
#    Any jq or write failure aborts with rc 1 — never "Installed." over a skipped merge.
# Before that write, the CLAUDE.md decision (claude_md_decision, on the rubric step 1
# just installed) and its filtered copy are computed too, so a check/read/filter error
# dies with settings.json and CLAUDE.md both untouched. Step 3 only backs up and writes
# the result. A legacy line with a trailing CR (CRLF file) counts; every other byte is
# kept exactly (drop_line).
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
claude_md_decision "$CLAUDE_DIR/$TRIAGE_HOOK_SCRIPT" "$CLAUDE_DIR/triage.md"
if [ -z "$CLAUDE_MD_BLOCK" ] && [ "$LEGACY" -eq 1 ]; then
  CLAUDE_MD_NEW=$(mktemp) || die "mktemp failed — nothing was changed."
  drop_line "$CLAUDE_MD" "$LEGACY_IMPORT" > "$CLAUDE_MD_NEW" \
    || die "could not filter $CLAUDE_MD (awk failed) — nothing was changed."
fi

# An absent settings.json is merged as an empty one, from a temp copy: nothing is
# written to $SETTINGS before the merge has succeeded.
SETTINGS_SRC="$SETTINGS"
if [ ! -f "$SETTINGS" ]; then
  SETTINGS_EMPTY=$(mktemp) || die "mktemp failed — nothing was changed."
  printf '{}\n' > "$SETTINGS_EMPTY"
  SETTINGS_SRC="$SETTINGS_EMPTY"
fi
cur_sub=$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL // "null"' "$SETTINGS_SRC") || die "could not read $SETTINGS (jq failed) — nothing was changed."
cur_mark=$(jq -r --arg k "$OWNER_MARK" '.env[$k] // "null"' "$SETTINGS_SRC") || die "could not read $SETTINGS (jq failed) — nothing was changed."
sub_action=$(sub_model_action "$cur_sub" "$cur_mark")
upgrade_sub=0
case "$sub_action" in upgrade-owned|upgrade-legacy) upgrade_sub=1 ;; esac
add_hook=0
[ "$HOOK_ACTION" = "add" ] && add_hook=1
hook_group=$(triage_hook_group) || die "could not build the SessionStart hook group (jq failed) — nothing was changed."
tmp=$(mktemp)
jq --arg m "$SUBAGENT_MODEL" --arg ttl "$SUBAGENT_CACHE_TTL" --arg up "$upgrade_sub" --arg k "$OWNER_MARK" \
   --arg add "$add_hook" --argjson group "$hook_group" '
  # 2a. subagent model (+ ownership marker) and prompt-cache TTL
  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null or $up == "1" then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m | .env[$k] = $m else . end)
  | (if (.env[$k] // null) != null and .env[$k] != .env.CLAUDE_CODE_SUBAGENT_MODEL then del(.env[$k]) else . end)
  | (if (.subagentPromptCacheTtl // null) == null then .subagentPromptCacheTtl = $ttl else . end)
  # 2b. Agent(...) permission rules
  | ["Agent(triage-quick-task)","Agent(triage-builder)","Agent(triage-deep-reasoner)","Agent(triage-reviewer)","Agent(triage-cross-reviewer)","Agent(triage-external)"] as $workers
  | ["Agent(triage-overflow)"] as $legacy_workers
  | ["Agent(triage-fable-architect)"] as $fable
  | .permissions.allow = (((.permissions.allow // []) - $legacy_workers) + ($workers - (.permissions.allow // [])))
  | .permissions.ask   = ((.permissions.ask   // []) + ($fable   - (.permissions.ask   // [])))
  # 2c. the SessionStart hook, appended
  | (if $add == "1" then .hooks.SessionStart = ((.hooks.SessionStart // []) + [$group]) else . end)
' "$SETTINGS_SRC" > "$tmp" || die "settings merge (jq) failed — $SETTINGS and CLAUDE.md left unchanged."
apply_settings "$tmp" || die "could not write $SETTINGS — CLAUDE.md was not changed."
case "$sub_action" in
  upgrade-owned) echo "env.CLAUDE_CODE_SUBAGENT_MODEL: upgraded $cur_sub -> $SUBAGENT_MODEL (set by this installer)" ;;
  upgrade-legacy) echo "env.CLAUDE_CODE_SUBAGENT_MODEL: upgraded $cur_sub -> $SUBAGENT_MODEL (previous installer default)" ;;
esac
if [ "$add_hook" -eq 1 ]; then
  echo "hooks.SessionStart: added the triage hook ($hook_group)"
fi

# =============================================================================
# 3. CLAUDE.md — reached only after the settings write above succeeded (a failure dies
#    first), so the legacy import is removed only once this install's hook is in
#    settings.json. A legacy `@triage.md` import (CRLF too) is removed (backed up first:
#    it would load the rubric into every subagent, and the hook stays silent while it is
#    there), and the pointer line is appended once. Written through a symlink, never
#    replacing it. Fails CLOSED: the filtered copy was computed before step 2
#    (CLAUDE_MD_NEW), and a failed backup dies before the rewrite; a failed rewrite
#    names the backup. With CLAUDE_MD_BLOCK set (disableAllHooks, or a rubric that fails
#    its size check) nothing here runs.
# =============================================================================
if [ -n "$CLAUDE_MD_BLOCK" ]; then
  echo "⚠ WARNING: $CLAUDE_MD_BLOCK"
else
  touch "$CLAUDE_MD" || die "could not create $CLAUDE_MD."
  if [ "$LEGACY" -eq 1 ]; then
    b=$(backup_copy "$CLAUDE_MD") || die "could not back up $CLAUDE_MD — it was not changed."
    cat "$CLAUDE_MD_NEW" > "$CLAUDE_MD" || die "could not rewrite $CLAUDE_MD (your copy is in $b)."
    echo "CLAUDE.md: removed the legacy @triage.md import (the SessionStart hook replaces it); previous copy saved to $b"
  fi
  if [ "$POINTER" -eq 0 ]; then
    # Ensure the file ends with a newline first, or the pointer fuses onto the last
    # line — corrupting that line — when CLAUDE.md lacks a final newline.
    if [ -s "$CLAUDE_MD" ] && [ -n "$(tail -c1 "$CLAUDE_MD")" ]; then
      printf '\n' >> "$CLAUDE_MD"
    fi
    printf '%s\n' "$(pointer_line)" >> "$CLAUDE_MD"
  fi
fi

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
echo "  - The rubric reaches the main session through a SessionStart hook (scripts/triage-context.sh); subagents don't load it."
echo "  - Kill switch: touch $CLAUDE_DIR/triage.disabled (takes effect at the next startup, /clear or compaction; rm re-enables)."
echo "  - Full removal: ./uninstall.sh"
