#!/bin/bash
# Install/uninstall round-trip test suite for the triage layer.
#
# NEVER touches the real ~/.claude — every case gets its own sandbox
# (mktemp -d), pointed at via $CLAUDE_DIR, and installer/uninstaller are
# invoked with that override. Fail-loud: accumulates every failure instead
# of stopping at the first, prints a per-check PASS/FAIL line, and exits
# non-zero if anything failed OR if a prerequisite (jq) is missing.
#
# Cases (see scratchpad spec this suite was built from):
#   A - no-trailing-newline CLAUDE.md + pre-existing settings: install,
#       re-install (idempotency), uninstall. model/effortLevel/statusLine are
#       NEVER written or reverted; env.CLAUDE_CODE_SUBAGENT_MODEL and
#       subagentPromptCacheTtl are set only when unset and removed only when
#       still ours.
#   B - completely empty CLAUDE_DIR round-trip: no leftover `"permissions": {}`
#       or `"env": {}`; nothing invented for model/effortLevel/statusLine.
#   C - settings.json is a symlink: install writes through it, uninstall
#       leaves it a symlink.
#   D - invalid settings.json: install aborts before ANY mutation.
#   E - a Fable `ask` rule hand-converted to `deny` is still cleaned up
#       by uninstall.
#   F - install.sh --dry-run against a populated sandbox: no mutation at all.
#   G - install.sh --files-only with a driftignored, differing fork (fixture
#       .driftignore + repo copy, since the shipped .driftignore lists none):
#       files copied, the fork is skipped (not clobbered), CLAUDE.md/settings
#       untouched.
#   H - version-compat warnings: stub `claude --version` on PATH (old/absent/
#       new) and check the right warning (or none) is printed.
#   K - a user-set env.CLAUDE_CODE_SUBAGENT_MODEL / subagentPromptCacheTtl is
#       never overwritten by install and never deleted by uninstall.
#   L - the superseded workflows/triage-run.js is removed on install when it
#       matches a shipped version, and kept (with a note) when hand-modified.
#   M - CLAUDE_CODE_SUBAGENT_MODEL_FORCE (collapses every tier onto one model):
#       install warns from the environment AND from settings.json env, never
#       edits the key, and drift.sh warns without changing its exit code.
#   N - a subagent model still at a PREVIOUS installer default (claude-opus-5)
#       is upgraded by install (dry-run says "would upgrade"), removed by
#       uninstall, and install.sh/uninstall.sh carry identical owned values.
#   O - the Wave 12 rename triage-overflow -> triage-external: install removes
#       the legacy agent file and its Agent(triage-overflow) allow rule and adds
#       triage-external; uninstall removes both names (agents + permissions).
#   P - .driftignore'd forks (fixture .driftignore + repo copy naming triage.md)
#       are skipped by EVERY install mode when the installed copy exists (bare
#       install, --dry-run), and written only by a first install (bare or
#       --files-only) where no copy exists yet.
#   Q - subagent-model ownership is RECORDED (env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL),
#       never inferred from the value; the default comes from config/tiers.json.
#   R - timestamped backups of locally modified installed files, newest 5 kept.
#   U - uninstall moves forks, edited files and per-agent memory to a backup dir;
#       a clean round-trip leaves exactly {settings.json, CLAUDE.md}; drift checks
#       every file install placed.
#   V - retired files (agy-run.sh, triage-overflow.md): shipped bytes deleted,
#       anything else moved aside.
#   W - a jq failure (or a settings.json of the wrong shape) fails install and
#       uninstall with rc != 0 and never prints Installed./Uninstalled.
#   X - .driftignore entries with CRLF / trailing whitespace still protect forks
#       (fixture .driftignore + repo copy).
#   Y - tiers-sync.sh: --root without a value, an unclosed frontmatter.
#   Z - drift.sh warns "settings migration pending" for a legacy subagent model,
#       a missing triage SessionStart hook and a legacy @triage.md import.
#   SS - the SessionStart hook that delivers triage.md: appended once (never replacing
#       a foreign SessionStart hook, which survives install AND uninstall), a legacy
#       @triage.md import migrated to the pointer line, the pointer removed on
#       uninstall, and a failed settings merge leaving settings.json and CLAUDE.md
#       byte-identical (one settings write, after the whole merge succeeded).
#   OWN/PIN/TYPE - ownership: only a command hook pinned to THIS CLAUDE_DIR counts as
#       installed or is removed (other-dir, unpinned, prompt-type entries are foreign).
#   MATCH - matcher coverage: all four of startup, resume, clear, compact.
#   RUB - the legacy import goes only when the installed rubric passes --check.
#   FALSE/BYTE/NL - false-valued settings keys refused; CLAUDE.md bytes kept exactly
#       (cmp); a CLAUDE_DIR with a line break refused.
#   CANON - CLAUDE_DIR spelled with a trailing slash / `.` is ONE install (one hook,
#       one pointer); a relative one is refused before anything changes.
#   DOWN - a marked subagent model you repointed to an OLD installer default is yours
#       (never upgraded back; the stale marker goes).
#   PTR - the pre-Wave-22 pointer line is replaced by install and removed by uninstall.
#   NORM - one legacy-import normalisation in the hook, install and uninstall (other
#       spellings migrated; two trailing CRs is not the import anywhere).
#   ORD - uninstall writes settings.json, then CLAUDE.md, then removes files; a failed
#       write stops before any file is removed.
#   Plus two direct statusline.sh checks (non-numeric / numeric pct).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- prerequisite check: fail loud, never silently skip ---------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "INCOMPLETE: jq is required to run this suite (brew install jq) — cannot verify settings.json merges." >&2
  exit 1
fi

# Case M sets CLAUDE_CODE_SUBAGENT_MODEL_FORCE explicitly per invocation; clear any
# ambient value so every OTHER case sees a clean environment (H5 asserts a current
# `claude` produces no WARNING line at all, which an inherited FORCE would break).
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE

PASS_COUNT=0
FAIL_COUNT=0
ALL_TMP=""
# The one line install appends to CLAUDE.md for CLAUDE_DIR $1 (install.sh pointer_line;
# N8 pins both scripts' copies): it names that install's triage.md.
pointer_for() { printf 'The triage routing rubric (%s/triage.md) reaches the main session through a SessionStart hook; if you are the main session and it is not in your context, read that file before planning. Subagents don'"'"'t need it.' "$1"; }
# The Wave 21 pointer line (install replaces it, uninstall removes it).
old_pointer_for() { printf 'The triage routing rubric (%s/triage.md) reaches the main session through a SessionStart hook; subagents don'"'"'t receive it.' "$1"; }
# The hook command install pins to CLAUDE_DIR $1 (an ordinary path: no %q escaping).
hook_cmd_for() { printf 'CLAUDE_DIR=%s bash %s/scripts/triage-context.sh' "$1" "$1"; }
# Number of SessionStart hook commands in settings file $1 in install's canonical form
# (`CLAUDE_DIR=<dir> bash <dir>/scripts/triage-context.sh`, nothing before or after).
# Written independently of install.sh's TRIAGE_HOOK_OWNED_JQ, so a broken predicate
# there cannot also blind this count.
triage_hooks() { jq '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | (.command // "") | strings | select(startswith("CLAUDE_DIR=") and endswith("/scripts/triage-context.sh") and (split(" ") | length == 3) and (split(" ")[1] == "bash"))] | length' "$1"; }
# The subagent default install writes = the deep level's Claude model (config/tiers.json).
DEEP_MODEL=$(jq -r '.levels.deep.claude.model' "$REPO_DIR/config/tiers.json")

cleanup() {
  # shellcheck disable=SC2086
  [ -n "$ALL_TMP" ] && rm -rf $ALL_TMP
}
trap cleanup EXIT

new_sandbox() {
  d=$(mktemp -d)
  ALL_TMP="$ALL_TMP $d"
  printf '%s' "$d"
}

# chk NAME CONDITION — CONDITION is a shell test string passed to `eval`.
# Records PASS/FAIL and never aborts the suite on failure.
chk() {
  name="$1"
  cond="$2"
  if eval "$cond"; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_install() {
  # $1 = CLAUDE_DIR ; stdout/stderr captured by caller via command substitution
  CLAUDE_DIR="$1" "$REPO_DIR/install.sh"
}

run_uninstall() {
  CLAUDE_DIR="$1" "$REPO_DIR/uninstall.sh"
}

# =============================================================================
# Case A — no-trailing-newline CLAUDE.md + pre-existing settings
# =============================================================================
A_DIR=$(new_sandbox)
mkdir -p "$A_DIR"
printf 'existing global rules, no trailing newline' > "$A_DIR/CLAUDE.md"
cat > "$A_DIR/settings.json" <<'EOF'
{
  "model": "sonnet",
  "effortLevel": "medium",
  "statusLine": {"type": "command", "command": "/old/statusline.sh"},
  "permissions": {"allow": ["Bash(ls:*)"]},
  "customKey": "keepme"
}
EOF

run_install "$A_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A_INSTALL_RC=$?
chk "A1: install exits 0" '[ "$A_INSTALL_RC" -eq 0 ]'
chk "A2: the pointer line is appended on its own line, and no @triage.md import" \
  'grep -qxF "$(pointer_for "$A_DIR")" "$A_DIR/CLAUDE.md" && ! grep -qxF "@triage.md" "$A_DIR/CLAUDE.md"'
chk "A2b: exactly one SessionStart hook runs scripts/triage-context.sh, with the full matcher and timeout" \
  '[ "$(triage_hooks "$A_DIR/settings.json")" -eq 1 ] && jq -e ".hooks.SessionStart[0] == {matcher: \"startup|resume|clear|compact\", hooks: [{type: \"command\", command: \"CLAUDE_DIR=$A_DIR bash $A_DIR/scripts/triage-context.sh\", timeout: 10}]}" "$A_DIR/settings.json" >/dev/null'
chk "A2c: the hook's script is installed and executable" '[ -x "$A_DIR/scripts/triage-context.sh" ]'
chk "A3: original CLAUDE.md content preserved as its own first line" \
  '[ "$(sed -n 1p "$A_DIR/CLAUDE.md")" = "existing global rules, no trailing newline" ]'
chk "A4: CLAUDE.md has exactly 2 lines (orig + pointer)" \
  '[ "$(wc -l < "$A_DIR/CLAUDE.md" | tr -d " ")" -eq 2 ]'
chk "A5: model left exactly as the user had it (never written)" \
  '[ "$(jq -r ".model" "$A_DIR/settings.json")" = "sonnet" ]'
chk "A6: effortLevel left exactly as the user had it (never written)" \
  '[ "$(jq -r ".effortLevel" "$A_DIR/settings.json")" = "medium" ]'
chk "A6b: statusLine left exactly as the user had it (never written)" \
  '[ "$(jq -r ".statusLine.command" "$A_DIR/settings.json")" = "/old/statusline.sh" ]'
chk "A6c: env.CLAUDE_CODE_SUBAGENT_MODEL set (was unset)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$A_DIR/settings.json")" = "$DEEP_MODEL" ]'
chk "A6d: subagentPromptCacheTtl set (was unset)" \
  '[ "$(jq -r ".subagentPromptCacheTtl" "$A_DIR/settings.json")" = "1h" ]'
chk "A7: permissions.allow has 7 entries after install (1 pre-existing + 6 workers)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 7 ]'
chk "A8: pre-existing allow entry retained" \
  'jq -e ".permissions.allow | index(\"Bash(ls:*)\")" "$A_DIR/settings.json" >/dev/null'
chk "A9: no preinstall snapshot is written any more (nothing is overwritten)" \
  '[ ! -f "$A_DIR/triage-preinstall.json" ] && [ ! -f "$A_DIR/settings.json.triage-preinstall.bak" ]'

# Re-install: idempotency
run_install "$A_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A_REINSTALL_RC=$?
chk "A10: re-install exits 0" '[ "$A_REINSTALL_RC" -eq 0 ]'
chk "A11: re-install does not duplicate the pointer line" \
  '[ "$(grep -cxF "$(pointer_for "$A_DIR")" "$A_DIR/CLAUDE.md")" -eq 1 ] && [ "$(wc -l < "$A_DIR/CLAUDE.md" | tr -d " ")" -eq 2 ]'
chk "A11b: re-install does not add a second SessionStart hook (still exactly one group)" \
  '[ "$(triage_hooks "$A_DIR/settings.json")" -eq 1 ] && [ "$(jq ".hooks.SessionStart | length" "$A_DIR/settings.json")" -eq 1 ]'
chk "A12: re-install does not duplicate permissions.allow entries (still 7)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 7 ]'

# Uninstall: restore
run_uninstall "$A_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A_UNINSTALL_RC=$?
chk "A13: uninstall exits 0" '[ "$A_UNINSTALL_RC" -eq 0 ]'
chk "A14: model untouched through the whole round-trip" \
  '[ "$(jq -r ".model" "$A_DIR/settings.json")" = "sonnet" ]'
chk "A14b: effortLevel untouched through the whole round-trip" \
  '[ "$(jq -r ".effortLevel" "$A_DIR/settings.json")" = "medium" ]'
chk "A15: statusLine untouched through the whole round-trip" \
  '[ "$(jq -r ".statusLine.command" "$A_DIR/settings.json")" = "/old/statusline.sh" ]'
chk "A15b: env.CLAUDE_CODE_SUBAGENT_MODEL removed on uninstall (still our value)" \
  '[ "$(jq "has(\"env\")" "$A_DIR/settings.json")" = "false" ]'
chk "A15c: subagentPromptCacheTtl removed on uninstall (still our value)" \
  '[ "$(jq "has(\"subagentPromptCacheTtl\")" "$A_DIR/settings.json")" = "false" ]'
chk "A16: permissions.allow back to original single entry" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 1 ] && jq -e ".permissions.allow | index(\"Bash(ls:*)\")" "$A_DIR/settings.json" >/dev/null'
chk "A17: unrelated key (customKey) preserved through the whole round-trip" \
  '[ "$(jq -r ".customKey" "$A_DIR/settings.json")" = "keepme" ]'
chk "A18: the pointer line is removed from CLAUDE.md on uninstall (the original line stays)" \
  '! grep -qxF "$(pointer_for "$A_DIR")" "$A_DIR/CLAUDE.md" && [ "$(cat "$A_DIR/CLAUDE.md")" = "existing global rules, no trailing newline" ]'
chk "A18b: the SessionStart hook is removed, and the emptied hooks key with it" \
  '[ "$(jq "has(\"hooks\")" "$A_DIR/settings.json")" = "false" ]'

# =============================================================================
# Case B — empty CLAUDE_DIR round-trip
# =============================================================================
B_DIR=$(new_sandbox)
mkdir -p "$B_DIR"

run_install "$B_DIR" >/dev/null 2>&1
run_uninstall "$B_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
B_RC=$?
chk "B1: uninstall exits 0 on an originally-empty dir" '[ "$B_RC" -eq 0 ]'
chk "B2: no model key invented on an empty dir" \
  '[ "$(jq "has(\"model\")" "$B_DIR/settings.json")" = "false" ]'
chk "B3: no effortLevel key invented on an empty dir" \
  '[ "$(jq "has(\"effortLevel\")" "$B_DIR/settings.json")" = "false" ]'
chk "B4: no statusLine key invented on an empty dir" \
  '[ "$(jq "has(\"statusLine\")" "$B_DIR/settings.json")" = "false" ]'
chk "B5: no leftover empty permissions object" \
  '[ "$(jq "has(\"permissions\")" "$B_DIR/settings.json")" = "false" ]'
chk "B6: no leftover empty env object after uninstall" \
  '[ "$(jq "has(\"env\")" "$B_DIR/settings.json")" = "false" ]'
chk "B7: settings.json round-trips back to an empty object" \
  '[ "$(jq -c "." "$B_DIR/settings.json")" = "{}" ]'

# =============================================================================
# Case C — symlinked settings.json
# =============================================================================
C_DIR=$(new_sandbox)
mkdir -p "$C_DIR"
C_REAL="$C_DIR/real-settings.json"
echo '{}' > "$C_REAL"
ln -s "$C_REAL" "$C_DIR/settings.json"

run_install "$C_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
C_RC=$?
chk "C1: install exits 0 with a symlinked settings.json" '[ "$C_RC" -eq 0 ]'
chk "C2: settings.json is still a symlink after install" '[ -L "$C_DIR/settings.json" ]'
chk "C3: symlink still points at the original target file" \
  '[ "$(readlink "$C_DIR/settings.json")" = "$C_REAL" ]'
chk "C4: the symlink target received the merge" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$C_REAL")" = "$DEEP_MODEL" ]'

# =============================================================================
# Case D — invalid settings.json: install must abort before ANY mutation
# =============================================================================
D_DIR=$(new_sandbox)
mkdir -p "$D_DIR"
printf 'pre-existing CLAUDE.md content\n' > "$D_DIR/CLAUDE.md"
printf '{ this is not valid json' > "$D_DIR/settings.json"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
D_CLAUDE_MD_BEFORE=$(cat "$D_DIR/CLAUDE.md")

D_STDERR_FILE=$(mktemp)
ALL_TMP="$ALL_TMP $D_STDERR_FILE"
CLAUDE_DIR="$D_DIR" "$REPO_DIR/install.sh" >/dev/null 2>"$D_STDERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
D_RC=$?
chk "D1: install exits non-zero on invalid settings.json" '[ "$D_RC" -ne 0 ]'
chk "D2: stderr mentions 'not valid JSON'" 'grep -q "not valid JSON" "$D_STDERR_FILE"'
chk "D3: CLAUDE.md left byte-for-byte unmodified (no pointer appended)" \
  '[ "$(cat "$D_DIR/CLAUDE.md")" = "$D_CLAUDE_MD_BEFORE" ]'
chk "D4: agents were NOT copied (no mutation at all)" \
  '[ ! -f "$D_DIR/agents/triage-quick-task.md" ]'

# =============================================================================
# Case E — an ask->deny converted Fable rule is still cleaned on uninstall
# =============================================================================
E_DIR=$(new_sandbox)
mkdir -p "$E_DIR"
echo '{}' > "$E_DIR/settings.json"

run_install "$E_DIR" >/dev/null 2>&1
chk "E1: install adds the Fable rule to permissions.ask" \
  'jq -e ".permissions.ask | index(\"Agent(triage-fable-architect)\")" "$E_DIR/settings.json" >/dev/null'

# Simulate the user hand-converting the ask-gate to a hard deny (README-documented option)
E_TMP=$(mktemp)
ALL_TMP="$ALL_TMP $E_TMP"
jq '.permissions.ask = [] | .permissions.deny = ["Agent(triage-fable-architect)"]' \
  "$E_DIR/settings.json" > "$E_TMP" && mv "$E_TMP" "$E_DIR/settings.json"

run_uninstall "$E_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
E_RC=$?
chk "E2: uninstall exits 0" '[ "$E_RC" -eq 0 ]'
chk "E3: the converted deny rule is removed on uninstall" \
  '[ "$(jq "has(\"permissions\")" "$E_DIR/settings.json")" = "false" ] || ! jq -e ".permissions.deny // [] | index(\"Agent(triage-fable-architect)\")" "$E_DIR/settings.json" >/dev/null'

# =============================================================================
# Case F — install.sh --dry-run: no mutation against a populated sandbox
# =============================================================================
F_DIR=$(new_sandbox)
mkdir -p "$F_DIR"
printf 'existing global rules\n' > "$F_DIR/CLAUDE.md"
cat > "$F_DIR/settings.json" <<'EOF'
{
  "model": "sonnet",
  "effortLevel": "medium",
  "permissions": {"allow": ["Bash(ls:*)"]}
}
EOF
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
F_CLAUDE_MD_BEFORE=$(cat "$F_DIR/CLAUDE.md")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
F_SETTINGS_BEFORE=$(cat "$F_DIR/settings.json")

F_OUT_FILE=$(mktemp)
ALL_TMP="$ALL_TMP $F_OUT_FILE"
CLAUDE_DIR="$F_DIR" "$REPO_DIR/install.sh" --dry-run >"$F_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
F_RC=$?
chk "F1: --dry-run exits 0" '[ "$F_RC" -eq 0 ]'
chk "F2: CLAUDE.md byte-identical after --dry-run" \
  '[ "$(cat "$F_DIR/CLAUDE.md")" = "$F_CLAUDE_MD_BEFORE" ]'
chk "F3: settings.json byte-identical after --dry-run" \
  '[ "$(cat "$F_DIR/settings.json")" = "$F_SETTINGS_BEFORE" ]'
chk "F4: no preinstall snapshot written" '[ ! -f "$F_DIR/triage-preinstall.json" ]'
chk "F5: no agent files copied" '[ ! -f "$F_DIR/agents/triage-quick-task.md" ]'
chk "F6: no statusline.sh copied" '[ ! -f "$F_DIR/statusline.sh" ]'
chk "F7: plan output says model/effortLevel/statusLine are NOT touched" \
  'grep -q "model / effortLevel / statusLine: NOT touched" "$F_OUT_FILE"'
chk "F8: plan output mentions the subagent-model env key" \
  'grep -q "env.CLAUDE_CODE_SUBAGENT_MODEL" "$F_OUT_FILE"'
chk "F9: plan output mentions the subagent prompt-cache TTL key" \
  'grep -q "subagentPromptCacheTtl" "$F_OUT_FILE"'
chk "F10: plan output reports the missing triage hook and the pointer-line append" \
  'grep -qF "hooks.SessionStart: triage hook missing" "$F_OUT_FILE" && grep -qF "would append pointer line: $(pointer_for "$F_DIR")" "$F_OUT_FILE"'
chk "F11: --dry-run writes no preinstall snapshot and no settings backup" \
  '[ ! -f "$F_DIR/triage-preinstall.json" ] && [ ! -f "$F_DIR/settings.json.triage-preinstall.bak" ]'

# =============================================================================
# Shared helpers for the cases below.
# =============================================================================
# A .git-less copy of this repo (as the mutation harness runs it), for cases that
# need a different config/tiers.json or .driftignore than the real one.
repo_copy() {
  local d
  d=$(new_sandbox)
  ( cd "$REPO_DIR" && tar cf - --exclude=.git . ) | ( cd "$d" && tar xf - )
  printf '%s' "$d"
}
# Files under $1, relative, sorted — symlinks and regular files, never dirs.
file_set() { ( cd "$1" && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort ); }

# =============================================================================
# Case G — install.sh --files-only skips a driftignored, differing fork.
# The shipped .driftignore lists no files, so this case runs against a repo
# copy with a fixture .driftignore that lists triage.md (same pattern as
# Case Q6's tiers.json fixture below).
# =============================================================================
G_REPO=$(repo_copy)
printf '# fixture: triage.md is a deliberate personal fork for this test\ntriage.md\n' > "$G_REPO/.driftignore"
G_DIR=$(new_sandbox)
mkdir -p "$G_DIR"
printf 'my personal triage.md fork\n' > "$G_DIR/triage.md"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
G_TRIAGE_BEFORE=$(cat "$G_DIR/triage.md")

G_OUT_FILE=$(mktemp)
ALL_TMP="$ALL_TMP $G_OUT_FILE"
CLAUDE_DIR="$G_DIR" "$G_REPO/install.sh" --files-only >"$G_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
G_RC=$?
chk "G1: --files-only exits 0" '[ "$G_RC" -eq 0 ]'
chk "G2: agents copied" '[ -f "$G_DIR/agents/triage-quick-task.md" ]'
chk "G3: statusline.sh copied and executable" '[ -x "$G_DIR/statusline.sh" ]'
chk "G4: workflows/triage-exec.js copied" '[ -f "$G_DIR/workflows/triage-exec.js" ]'
chk "G5: scripts/triage-usage.sh copied and executable" '[ -x "$G_DIR/scripts/triage-usage.sh" ]'
chk "G6: skip notice printed for triage.md" 'grep -q "skipped (expected fork): triage.md" "$G_OUT_FILE"'
chk "G7: sandbox triage.md left untouched (fork preserved)" \
  '[ "$(cat "$G_DIR/triage.md")" = "$G_TRIAGE_BEFORE" ]'
chk "G8: no .bak-triage backup created for the skipped fork" '! ls "$G_DIR"/triage.md.bak-triage* >/dev/null 2>&1'
chk "G9: CLAUDE.md not created (files-only leaves it alone)" '[ ! -f "$G_DIR/CLAUDE.md" ]'
chk "G10: settings.json not created (files-only leaves it alone)" '[ ! -f "$G_DIR/settings.json" ]'
chk "G11: scripts/ext-run.sh copied and executable" '[ -x "$G_DIR/scripts/ext-run.sh" ]'
chk "G12: config/tiers.json installed as scripts/triage-tiers.json (byte-identical)" \
  'cmp -s "$REPO_DIR/config/tiers.json" "$G_DIR/scripts/triage-tiers.json"'
chk "G13: scripts/triage-tiers.sh copied and executable" '[ -x "$G_DIR/scripts/triage-tiers.sh" ]'
chk "G14: the installed triage-tiers.sh reads the installed tiers file next to it, not the repo copy" \
  '"$G_DIR/scripts/triage-tiers.sh" | grep -q "tiers: $G_DIR/scripts/triage-tiers.json"'
chk "G15: workflows/triage-compare.js copied (byte-identical)" \
  'cmp -s "$REPO_DIR/workflows/triage-compare.js" "$G_DIR/workflows/triage-compare.js"'
chk "G16: scripts/patch-check.sh copied and executable" '[ -x "$G_DIR/scripts/patch-check.sh" ]'
chk "G17: scripts/stage-worktree.sh copied (byte-identical) and executable" \
  '[ -x "$G_DIR/scripts/stage-worktree.sh" ] && cmp -s "$REPO_DIR/scripts/stage-worktree.sh" "$G_DIR/scripts/stage-worktree.sh"'
chk "G20: scripts/review-stage.sh copied (byte-identical) and executable" \
  '[ -x "$G_DIR/scripts/review-stage.sh" ] && cmp -s "$REPO_DIR/scripts/review-stage.sh" "$G_DIR/scripts/review-stage.sh"'
chk "G19: scripts/parity-report.sh copied (byte-identical) and executable" \
  '[ -x "$G_DIR/scripts/parity-report.sh" ] && cmp -s "$REPO_DIR/scripts/parity-report.sh" "$G_DIR/scripts/parity-report.sh"'
chk "G18: workflows/triage-parity.js, scripts/parity-suite.sh and scripts/parity-cost.sh copied (byte-identical; scripts executable)" \
  'cmp -s "$REPO_DIR/workflows/triage-parity.js" "$G_DIR/workflows/triage-parity.js" && [ -x "$G_DIR/scripts/parity-suite.sh" ] && cmp -s "$REPO_DIR/scripts/parity-suite.sh" "$G_DIR/scripts/parity-suite.sh" && [ -x "$G_DIR/scripts/parity-cost.sh" ] && cmp -s "$REPO_DIR/scripts/parity-cost.sh" "$G_DIR/scripts/parity-cost.sh"'

# =============================================================================
# Case H — version-compat warnings (stub `claude` on PATH; --dry-run so a
# stubbed/absent `claude` can't accidentally cause a real mutation)
# =============================================================================
H_STUB_DIR=$(mktemp -d)
ALL_TMP="$ALL_TMP $H_STUB_DIR"

make_stub_claude() { # $1 = version string to print
  cat > "$H_STUB_DIR/claude" <<EOF
#!/bin/sh
echo "$1 (Claude Code)"
EOF
  chmod +x "$H_STUB_DIR/claude"
}

# H-old: version below all three documented thresholds
make_stub_claude "2.1.100"
H_OLD_DIR=$(new_sandbox)
mkdir -p "$H_OLD_DIR"
H_OLD_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $H_OLD_OUT"
PATH="$H_STUB_DIR:/usr/bin:/bin" CLAUDE_DIR="$H_OLD_DIR" "$REPO_DIR/install.sh" --dry-run >"$H_OLD_OUT" 2>&1
chk "H1: old claude version warns about per-agent memory" 'grep -q "per-agent memory" "$H_OLD_OUT"'
chk "H2: old claude version warns about permission rules no-op" 'grep -q "permission rules" "$H_OLD_OUT"'

# H-absent: no `claude` anywhere on PATH
H_ABSENT_DIR=$(new_sandbox)
mkdir -p "$H_ABSENT_DIR"
H_ABSENT_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $H_ABSENT_OUT"
PATH="/usr/bin:/bin" CLAUDE_DIR="$H_ABSENT_DIR" "$REPO_DIR/install.sh" --dry-run >"$H_ABSENT_OUT" 2>&1
chk "H4: absent claude prints could-not-verify" 'grep -q "could not verify Claude Code version" "$H_ABSENT_OUT"'

# H-new: version above all thresholds -> no version warnings
make_stub_claude "9.9.999"
H_NEW_DIR=$(new_sandbox)
mkdir -p "$H_NEW_DIR"
H_NEW_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $H_NEW_OUT"
PATH="$H_STUB_DIR:/usr/bin:/bin" CLAUDE_DIR="$H_NEW_DIR" "$REPO_DIR/install.sh" --dry-run >"$H_NEW_OUT" 2>&1
chk "H5: new claude version prints no version WARNING lines" '! grep -q "WARNING" "$H_NEW_OUT"'

# =============================================================================
# Case I — uninstall must remove only the seven shipped agents by name, never
# a user-authored triage-*.md agent (a glob-based revert would delete it).
# M1 rides along: the external-CLI script scripts/ext-run.sh, triage-tiers.sh and
# the installed tiers file are installed and removed by name too; the legacy
# pre-Wave-12 scripts/agy-run.sh is removed by install AND by uninstall.
# =============================================================================
I_DIR=$(new_sandbox)
mkdir -p "$I_DIR/agents" "$I_DIR/scripts"
printf '#!/bin/bash\necho legacy\n' > "$I_DIR/scripts/agy-run.sh"

run_install "$I_DIR" >/dev/null 2>&1
chk "M1a: install placed scripts/ext-run.sh (executable)" '[ -x "$I_DIR/scripts/ext-run.sh" ]'
chk "M1c: install placed scripts/triage-tiers.json and scripts/triage-tiers.sh" \
  '[ -f "$I_DIR/scripts/triage-tiers.json" ] && [ -x "$I_DIR/scripts/triage-tiers.sh" ]'
chk "M1d: install removed the legacy scripts/agy-run.sh (renamed to ext-run.sh)" '[ ! -e "$I_DIR/scripts/agy-run.sh" ]'
chk "M1f: install placed workflows/triage-compare.js, scripts/patch-check.sh and scripts/stage-worktree.sh (executable)" \
  '[ -f "$I_DIR/workflows/triage-compare.js" ] && [ -x "$I_DIR/scripts/patch-check.sh" ] && [ -x "$I_DIR/scripts/stage-worktree.sh" ]'
chk "M1k: install placed scripts/parity-report.sh (executable)" '[ -x "$I_DIR/scripts/parity-report.sh" ]'
chk "M1l: install placed scripts/review-stage.sh (executable)" '[ -x "$I_DIR/scripts/review-stage.sh" ]'
chk "M1h: install placed workflows/triage-parity.js, scripts/parity-suite.sh and scripts/parity-cost.sh (executable)" \
  '[ -f "$I_DIR/workflows/triage-parity.js" ] && [ -x "$I_DIR/scripts/parity-suite.sh" ] && [ -x "$I_DIR/scripts/parity-cost.sh" ]'
printf '#!/bin/bash\necho legacy\n' > "$I_DIR/scripts/agy-run.sh"
printf 'my own agent, not shipped by this repo\n' > "$I_DIR/agents/triage-mine.md"

run_uninstall "$I_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
I_RC=$?
chk "I1: uninstall exits 0" '[ "$I_RC" -eq 0 ]'
chk "I2: user-authored triage-mine.md survives uninstall" '[ -f "$I_DIR/agents/triage-mine.md" ]'
chk "I3: all seven shipped agents removed" \
  '[ ! -f "$I_DIR/agents/triage-quick-task.md" ] && [ ! -f "$I_DIR/agents/triage-builder.md" ] && [ ! -f "$I_DIR/agents/triage-deep-reasoner.md" ] && [ ! -f "$I_DIR/agents/triage-reviewer.md" ] && [ ! -f "$I_DIR/agents/triage-cross-reviewer.md" ] && [ ! -f "$I_DIR/agents/triage-fable-architect.md" ] && [ ! -f "$I_DIR/agents/triage-external.md" ]'
chk "M1b: uninstall removes scripts/ext-run.sh, triage-tiers.sh and triage-tiers.json" \
  '[ ! -f "$I_DIR/scripts/ext-run.sh" ] && [ ! -f "$I_DIR/scripts/triage-tiers.sh" ] && [ ! -f "$I_DIR/scripts/triage-tiers.json" ]'
chk "M1e: uninstall also removes a legacy scripts/agy-run.sh" '[ ! -e "$I_DIR/scripts/agy-run.sh" ]'
chk "M1g: uninstall removes workflows/triage-compare.js, scripts/patch-check.sh and scripts/stage-worktree.sh" \
  '[ ! -e "$I_DIR/workflows/triage-compare.js" ] && [ ! -e "$I_DIR/scripts/patch-check.sh" ] && [ ! -e "$I_DIR/scripts/stage-worktree.sh" ]'
chk "M1j: uninstall removes scripts/parity-report.sh" '[ ! -e "$I_DIR/scripts/parity-report.sh" ]'
chk "M1m: uninstall removes scripts/review-stage.sh" '[ ! -e "$I_DIR/scripts/review-stage.sh" ]'
chk "M1i: uninstall removes workflows/triage-parity.js, scripts/parity-suite.sh and scripts/parity-cost.sh" \
  '[ ! -e "$I_DIR/workflows/triage-parity.js" ] && [ ! -e "$I_DIR/scripts/parity-suite.sh" ] && [ ! -e "$I_DIR/scripts/parity-cost.sh" ]'

# =============================================================================
# Case J — drift.sh: a checked file missing from an installed sandbox is
# reported as unexpected drift and fails the exit code
# =============================================================================
J_DIR=$(new_sandbox)
mkdir -p "$J_DIR"

run_install "$J_DIR" >/dev/null 2>&1

J_SAME_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $J_SAME_OUT"
CLAUDE_DIR="$J_DIR" "$REPO_DIR/drift.sh" >"$J_SAME_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
J_SAME_RC=$?
chk "J1: freshly installed sandbox drifts clean (exit 0)" '[ "$J_SAME_RC" -eq 0 ]'
chk "J2: freshly installed sandbox has no MISSING/FORKED lines" \
  '! grep -qE "MISSING|FORKED" "$J_SAME_OUT"'

# Delete two checked files — one long-standing, one added with the external-CLI tier —
# so drift.sh's per-file list is exercised for both.
rm -f "$J_DIR/scripts/triage-usage.sh" "$J_DIR/scripts/ext-run.sh" "$J_DIR/scripts/triage-tiers.json" \
      "$J_DIR/scripts/patch-check.sh" "$J_DIR/workflows/triage-compare.js" "$J_DIR/scripts/stage-worktree.sh" \
      "$J_DIR/workflows/triage-parity.js" "$J_DIR/scripts/parity-suite.sh" "$J_DIR/scripts/parity-cost.sh" \
      "$J_DIR/scripts/parity-report.sh" "$J_DIR/scripts/review-stage.sh"

J_MISSING_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $J_MISSING_OUT"
CLAUDE_DIR="$J_DIR" "$REPO_DIR/drift.sh" >"$J_MISSING_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
J_MISSING_RC=$?
chk "J3: drift.sh reports MISSING for the deleted checked file" \
  'grep -q "MISSING (not installed): scripts/triage-usage.sh" "$J_MISSING_OUT"'
chk "J4: drift.sh exits non-zero once a checked file is missing" '[ "$J_MISSING_RC" -ne 0 ]'
chk "J5: drift.sh also reports MISSING for the deleted scripts/ext-run.sh" \
  'grep -q "MISSING (not installed): scripts/ext-run.sh" "$J_MISSING_OUT"'
chk "J7: drift.sh reports MISSING for the deleted patch-check.sh, stage-worktree.sh and triage-compare.js" \
  'grep -q "MISSING (not installed): scripts/patch-check.sh" "$J_MISSING_OUT" && grep -q "MISSING (not installed): scripts/stage-worktree.sh" "$J_MISSING_OUT" && grep -q "MISSING (not installed): workflows/triage-compare.js" "$J_MISSING_OUT"'
chk "J8: drift.sh reports MISSING for the deleted triage-parity.js, parity-suite.sh and parity-cost.sh" \
  'grep -q "MISSING (not installed): workflows/triage-parity.js" "$J_MISSING_OUT" && grep -q "MISSING (not installed): scripts/parity-suite.sh" "$J_MISSING_OUT" && grep -q "MISSING (not installed): scripts/parity-cost.sh" "$J_MISSING_OUT"'
chk "J9: drift.sh reports MISSING for the deleted parity-report.sh" \
  'grep -q "MISSING (not installed): scripts/parity-report.sh" "$J_MISSING_OUT"'
chk "J10: drift.sh reports MISSING for the deleted review-stage.sh" \
  'grep -q "MISSING (not installed): scripts/review-stage.sh" "$J_MISSING_OUT"'
chk "J6: drift.sh reports MISSING for the deleted installed tiers file (config/tiers.json)" \
  'grep -q "MISSING (not installed): config/tiers.json" "$J_MISSING_OUT"'

# =============================================================================
# Case K — the two settings keys this layer owns are set only when UNSET and
# removed only while they still hold OUR value. A user who repointed either one
# must get it back untouched from both install and uninstall.
# =============================================================================
K_DIR=$(new_sandbox)
mkdir -p "$K_DIR"
cat > "$K_DIR/settings.json" <<'EOF'
{
  "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5", "MY_OWN_VAR": "keepme"},
  "subagentPromptCacheTtl": "5m"
}
EOF

run_install "$K_DIR" >/dev/null 2>&1
chk "K1: a user-set subagent model is NOT overwritten by install" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$K_DIR/settings.json")" = "claude-sonnet-5" ]'
chk "K2: a user-set prompt-cache TTL is NOT overwritten by install" \
  '[ "$(jq -r ".subagentPromptCacheTtl" "$K_DIR/settings.json")" = "5m" ]'

run_uninstall "$K_DIR" >/dev/null 2>&1
chk "K3: a user-set subagent model survives uninstall (not ours to delete)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$K_DIR/settings.json")" = "claude-sonnet-5" ]'
chk "K4: a user-set prompt-cache TTL survives uninstall (not ours to delete)" \
  '[ "$(jq -r ".subagentPromptCacheTtl" "$K_DIR/settings.json")" = "5m" ]'
chk "K5: unrelated env vars survive the round-trip" \
  '[ "$(jq -r ".env.MY_OWN_VAR" "$K_DIR/settings.json")" = "keepme" ]'

# =============================================================================
# Case L — the superseded workflows/triage-run.js: removed on install when its
# bytes match a version this repo shipped, kept (with a note) when hand-modified.
# =============================================================================
# test/fixtures/legacy/triage-run.js is a byte-exact copy of the last shipped
# triage-run.js, so its SHA-256 is one of the entries in install.sh's
# SHIPPED_TRIAGE_RUN_SHA256 list — that list is what this case exercises. Kept as a
# checked-in fixture rather than read from git history: the mutation harness runs
# this suite from a .git-less copy of the repo.
L_DIR=$(new_sandbox)
mkdir -p "$L_DIR/workflows"
cp "$REPO_DIR/test/fixtures/legacy/triage-run.js" "$L_DIR/workflows/triage-run.js"
L_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $L_OUT"
CLAUDE_DIR="$L_DIR" "$REPO_DIR/install.sh" --files-only >"$L_OUT" 2>&1
chk "L1: an unmodified shipped triage-run.js is removed on install" \
  '[ ! -f "$L_DIR/workflows/triage-run.js" ]'
chk "L2: the removal is announced" 'grep -q "removed superseded workflow" "$L_OUT"'
chk "L3: triage-exec.js is installed in its place" '[ -f "$L_DIR/workflows/triage-exec.js" ]'

L2_DIR=$(new_sandbox)
mkdir -p "$L2_DIR/workflows"
printf '// my own hand-edited triage-run workflow\n' > "$L2_DIR/workflows/triage-run.js"
L2_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $L2_OUT"
CLAUDE_DIR="$L2_DIR" "$REPO_DIR/install.sh" --files-only >"$L2_OUT" 2>&1
chk "L4: a hand-modified triage-run.js is NOT deleted" '[ -f "$L2_DIR/workflows/triage-run.js" ]'
chk "L5: keeping it is announced with a note" 'grep -q "is modified (or unhashable) — left in place" "$L2_OUT"'
chk "L6: the hand-modified file is left byte-for-byte alone" \
  '[ "$(cat "$L2_DIR/workflows/triage-run.js")" = "// my own hand-edited triage-run workflow" ]'

# =============================================================================
# Case M2/M3/M4 — CLAUDE_CODE_SUBAGENT_MODEL_FORCE overrides every agent's own
# `model:`, collapsing all tiers onto one model: the layer still runs but stops
# routing by cost. install.sh and drift.sh must SAY so and change nothing — the
# key was set on purpose and only its owner should unset it.
# =============================================================================
M2_DIR=$(new_sandbox)
mkdir -p "$M2_DIR"
M2_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $M2_OUT"
CLAUDE_CODE_SUBAGENT_MODEL_FORCE=claude-haiku-5 CLAUDE_DIR="$M2_DIR" "$REPO_DIR/install.sh" --dry-run >"$M2_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
M2_RC=$?
chk "M2a: --dry-run with FORCE set in the environment still exits 0 (warn, never fail)" \
  '[ "$M2_RC" -eq 0 ]'
chk "M2b: the environment-variant warning fires and names the offending value" \
  'grep -q "CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set in your environment (claude-haiku-5)" "$M2_OUT"'
chk "M2c: --dry-run with FORCE set still mutates nothing" \
  '[ ! -f "$M2_DIR/settings.json" ] && [ ! -f "$M2_DIR/agents/triage-quick-task.md" ]'

# M3 — the same key in settings.json `env`: warn, and never delete it.
M3_DIR=$(new_sandbox)
mkdir -p "$M3_DIR"
cat > "$M3_DIR/settings.json" <<'EOF'
{
  "env": {"CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "claude-haiku-5", "MY_OWN_VAR": "keepme"},
  "customKey": "keepme"
}
EOF
M3_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $M3_OUT"
CLAUDE_DIR="$M3_DIR" "$REPO_DIR/install.sh" >"$M3_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
M3_RC=$?
chk "M3a: install exits 0 with env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE in settings.json" \
  '[ "$M3_RC" -eq 0 ]'
chk "M3b: the settings-file variant of the warning fires" \
  'grep -q "env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set in" "$M3_OUT"'
chk "M3c: install does NOT remove or rewrite the FORCE key" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE" "$M3_DIR/settings.json")" = "claude-haiku-5" ]'
chk "M3d: unrelated env var and top-level key survive the install" \
  '[ "$(jq -r ".env.MY_OWN_VAR" "$M3_DIR/settings.json")" = "keepme" ] && [ "$(jq -r ".customKey" "$M3_DIR/settings.json")" = "keepme" ]'

run_uninstall "$M3_DIR" >/dev/null 2>&1
chk "M3e: uninstall leaves the FORCE key alone too (never ours to remove)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE" "$M3_DIR/settings.json")" = "claude-haiku-5" ]'

# M4 — drift.sh warns jq-free and leaves its exit code alone.
M4_DIR=$(new_sandbox)
mkdir -p "$M4_DIR"
run_install "$M4_DIR" >/dev/null 2>&1
M4_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $M4_OUT"
CLAUDE_CODE_SUBAGENT_MODEL_FORCE=claude-haiku-5 CLAUDE_DIR="$M4_DIR" "$REPO_DIR/drift.sh" >"$M4_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
M4_RC=$?
chk "M4a: drift.sh with FORCE set still exits 0 on a clean install" '[ "$M4_RC" -eq 0 ]'
chk "M4b: drift.sh prints the FORCE warning" \
  'grep -q "CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set" "$M4_OUT"'
chk "M4c: the FORCE warning is not reported as drift" '! grep -qE "MISSING|FORKED" "$M4_OUT"'

# The settings.json half of drift's jq-free check must not fire on the layer's OWN
# env.CLAUDE_CODE_SUBAGENT_MODEL key, which every install writes.
M4B_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $M4B_OUT"
CLAUDE_DIR="$M4_DIR" "$REPO_DIR/drift.sh" >"$M4B_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
M4D_RC=$?
chk "M4d: with FORCE unset the warning stays silent (env.CLAUDE_CODE_SUBAGENT_MODEL must not match)" \
  '! grep -q "CLAUDE_CODE_SUBAGENT_MODEL_FORCE" "$M4B_OUT"'
chk "M4e: that silent run still exits 0" '[ "$M4D_RC" -eq 0 ]'

# =============================================================================
# Case N — a subagent model still at a PREVIOUS installer default. A value in
# LEGACY_SUBAGENT_MODELS was written by an older install.sh, not chosen by the
# user: install upgrades it (dry-run announces it), uninstall removes it even with
# no re-install in between. Any other value is the user's and stays (case K; N6
# pins the dry-run wording for it). The two scripts keep separate copies of the
# owned values, so N8 asserts they match.
# =============================================================================
N_DIR=$(new_sandbox)
mkdir -p "$N_DIR"
cat > "$N_DIR/settings.json" <<'EOF'
{
  "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5", "MY_OWN_VAR": "keepme"}
}
EOF
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_SETTINGS_BEFORE=$(cat "$N_DIR/settings.json")
N_DRY_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $N_DRY_OUT"
CLAUDE_DIR="$N_DIR" "$REPO_DIR/install.sh" --dry-run >"$N_DRY_OUT" 2>&1
chk "N1: --dry-run over a previous installer default prints the upgrade line" \
  'grep -qF "env.CLAUDE_CODE_SUBAGENT_MODEL: would upgrade claude-opus-5 -> $DEEP_MODEL" "$N_DRY_OUT"'
chk "N2: that --dry-run still writes nothing" \
  '[ "$(cat "$N_DIR/settings.json")" = "$N_SETTINGS_BEFORE" ]'

N_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $N_OUT"
CLAUDE_DIR="$N_DIR" "$REPO_DIR/install.sh" >"$N_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_RC=$?
chk "N3: install exits 0 over a previous installer default" '[ "$N_RC" -eq 0 ]'
chk "N4: a previous installer default (claude-opus-5) is upgraded to the deep model and marked as ours" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$N_DIR/settings.json")" = "$DEEP_MODEL" ] && [ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL" "$N_DIR/settings.json")" = "$DEEP_MODEL" ]'
chk "N5: the upgrade is announced" \
  'grep -qF "upgraded claude-opus-5 -> $DEEP_MODEL (previous installer default)" "$N_OUT"'
chk "N5b: an unrelated env var survives the upgrade" \
  '[ "$(jq -r ".env.MY_OWN_VAR" "$N_DIR/settings.json")" = "keepme" ]'

# A user-chosen (non-legacy) value: the dry-run keeps the "left as is" wording and
# never claims an upgrade. (Install/uninstall leaving it alone is K1/K3.)
N6_DIR=$(new_sandbox)
mkdir -p "$N6_DIR"
echo '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5"}}' > "$N6_DIR/settings.json"
N6_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $N6_OUT"
CLAUDE_DIR="$N6_DIR" "$REPO_DIR/install.sh" --dry-run >"$N6_OUT" 2>&1
chk "N6: --dry-run over a user value says 'already set ... left as is', never 'would upgrade'" \
  'grep -qF "env.CLAUDE_CODE_SUBAGENT_MODEL: already set to claude-sonnet-5" "$N6_OUT" && ! grep -q "would upgrade" "$N6_OUT"'

# Uninstall straight over an OLD install's settings (no re-install in between): the
# value carries no ownership marker, so it is NOT ours to remove (codex#20) — it stays,
# with a note saying so. The TTL still holds our value and goes.
N7_DIR=$(new_sandbox)
mkdir -p "$N7_DIR"
echo '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5"}, "subagentPromptCacheTtl": "1h"}' > "$N7_DIR/settings.json"
N7_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $N7_OUT"
run_uninstall "$N7_DIR" >"$N7_OUT" 2>&1
chk "N7: uninstall leaves an unmarked subagent model (even a previous default) and says so; the TTL goes" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$N7_DIR/settings.json")" = "claude-opus-5" ] && grep -q "no installer ownership marker" "$N7_OUT" && [ "$(jq "has(\"subagentPromptCacheTtl\")" "$N7_DIR/settings.json")" = "false" ]'

# The TTL is the one value both scripts own by value: they must agree. The subagent
# model is a literal in neither (it comes from config/tiers.json; ownership is the marker).
owned_lines() { grep -E '^((SUBAGENT_CACHE_TTL|OWNER_MARK|POINTER_HEAD|POINTER_TAIL|POINTER_TAILS_OLD|TRIAGE_HOOK_SCRIPT|TRIAGE_HOOK_OWNED_JQ|LEGACY_IMPORT_AWK)=|(triage_hook_command|pointer_line|old_pointer_line)\(\) )' "$1" | sort; }
# canon_dir is a multi-line function: compared whole.
canon_fn() { sed -n '/^canon_dir() {$/,/^}$/p' "$1"; }
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_INSTALL_OWNED=$(owned_lines "$REPO_DIR/install.sh")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_UNINSTALL_OWNED=$(owned_lines "$REPO_DIR/uninstall.sh")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N8_PTR=$(CLAUDE_DIR=/n8/dir bash -c "$(grep -E '^(POINTER_HEAD|POINTER_TAIL)=|^pointer_line\(\) ' "$REPO_DIR/install.sh"); pointer_line")
chk "N8: install.sh and uninstall.sh define identical SUBAGENT_CACHE_TTL / OWNER_MARK / POINTER_HEAD / POINTER_TAIL / POINTER_TAILS_OLD / TRIAGE_HOOK_SCRIPT / TRIAGE_HOOK_OWNED_JQ (the hook ownership predicate) / LEGACY_IMPORT_AWK / triage_hook_command / pointer_line / old_pointer_line / canon_dir" \
  '[ "$(printf "%s\n" "$N_INSTALL_OWNED" | grep -c .)" -eq 11 ] && [ "$N_INSTALL_OWNED" = "$N_UNINSTALL_OWNED" ] && [ "$N8_PTR" = "$(pointer_for /n8/dir)" ] && [ -n "$(canon_fn "$REPO_DIR/install.sh")" ] && [ "$(canon_fn "$REPO_DIR/install.sh")" = "$(canon_fn "$REPO_DIR/uninstall.sh")" ]'
chk "N9: neither script hard-codes a subagent model id (config/tiers.json owns it)" \
  '! grep -qE "^SUBAGENT_MODEL=\"claude-" "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh"'

# =============================================================================
# Case O — Wave 12 rename: triage-overflow -> triage-external. An install made
# before the rename holds agents/triage-overflow.md and an Agent(triage-overflow)
# allow rule; install must retire both (a leftover would be an eighth, agy-only
# agent), and uninstall must remove both names whatever state it finds.
# =============================================================================
O_DIR=$(new_sandbox)
mkdir -p "$O_DIR/agents"
printf -- '---\nname: triage-overflow\n---\nlegacy\n' > "$O_DIR/agents/triage-overflow.md"
echo '{"permissions": {"allow": ["Bash(ls:*)", "Agent(triage-overflow)"]}}' > "$O_DIR/settings.json"

O_DRY_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $O_DRY_OUT"
CLAUDE_DIR="$O_DIR" "$REPO_DIR/install.sh" --dry-run >"$O_DRY_OUT" 2>&1
chk "O1: --dry-run announces removing the legacy agent and its allow rule, adding triage-external, and changes nothing" \
  'grep -qF "move aside (modified or unhashable; renamed to agents/triage-external.md)" "$O_DRY_OUT" && grep -qF "would remove legacy: Agent(triage-overflow)" "$O_DRY_OUT" && grep -qF "would add: Agent(triage-external)" "$O_DRY_OUT" && [ -f "$O_DIR/agents/triage-overflow.md" ]'

run_install "$O_DIR" >/dev/null 2>&1
chk "O2: install removed the legacy agents/triage-overflow.md and placed triage-external.md" \
  '[ ! -e "$O_DIR/agents/triage-overflow.md" ] && [ -f "$O_DIR/agents/triage-external.md" ]'
chk "O3: install removed the legacy Agent(triage-overflow) allow rule and added Agent(triage-external)" \
  '! jq -e ".permissions.allow | index(\"Agent(triage-overflow)\")" "$O_DIR/settings.json" >/dev/null && jq -e ".permissions.allow | index(\"Agent(triage-external)\")" "$O_DIR/settings.json" >/dev/null'
chk "O4: exactly the 6 worker rules plus the user rule remain (7), none duplicated" \
  '[ "$(jq ".permissions.allow | length" "$O_DIR/settings.json")" -eq 7 ] && [ "$(jq ".permissions.allow | unique | length" "$O_DIR/settings.json")" -eq 7 ]'
chk "O5: exactly 7 triage-*.md agents installed (the rename keeps the count)" \
  '[ "$(find "$O_DIR/agents" -name "triage-*.md" | wc -l | tr -d " ")" -eq 7 ]'

# Re-seed the legacy state next to the current one, then uninstall: both names go.
printf -- '---\nname: triage-overflow\n---\nlegacy\n' > "$O_DIR/agents/triage-overflow.md"
jq '.permissions.allow += ["Agent(triage-overflow)"]' "$O_DIR/settings.json" > "$O_DIR/settings.tmp" && mv "$O_DIR/settings.tmp" "$O_DIR/settings.json"
run_uninstall "$O_DIR" >/dev/null 2>&1
chk "O6: uninstall removes triage-external.md and the legacy triage-overflow.md" \
  '[ ! -e "$O_DIR/agents/triage-external.md" ] && [ ! -e "$O_DIR/agents/triage-overflow.md" ]'
chk "O7: uninstall removes both Agent(triage-external) and Agent(triage-overflow), keeping the user rule" \
  '[ "$(jq -c ".permissions.allow" "$O_DIR/settings.json")" = "[\"Bash(ls:*)\"]" ]'

# =============================================================================
# Case P — an expected fork (fixture .driftignore: triage.md) survives EVERY
# install mode. The shipped .driftignore lists no files, so this runs against
# a repo copy with a fixture .driftignore (same pattern as Case G above).
# Found live 2026-09-23: a bare ./install.sh overwrote the personal ~/.claude/
# triage.md fork (only a .bak-triage copy was kept), because the skip applied under
# --files-only alone. A first install, where no copy exists yet, still writes it.
# =============================================================================
P_REPO=$(repo_copy)
printf '# fixture: triage.md is a deliberate personal fork for this test\ntriage.md\n' > "$P_REPO/.driftignore"
P_DIR=$(new_sandbox)
printf 'my personal triage.md fork\n' > "$P_DIR/triage.md"
P_DRY_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $P_DRY_OUT"
CLAUDE_DIR="$P_DIR" "$P_REPO/install.sh" --dry-run >"$P_DRY_OUT" 2>&1
chk "P1: --dry-run shows the existing fork as 'skipped (expected fork)', never 'overwrite'" \
  'grep -qF "skipped (expected fork): triage.md" "$P_DRY_OUT" && ! grep -q "overwrite.*$P_DIR/triage.md" "$P_DRY_OUT"'
P_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $P_OUT"
CLAUDE_DIR="$P_DIR" "$P_REPO/install.sh" >"$P_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
P_RC=$?
chk "P2: a BARE install over an existing fork exits 0 and leaves the fork byte-for-byte" \
  '[ "$P_RC" -eq 0 ] && [ "$(cat "$P_DIR/triage.md")" = "my personal triage.md fork" ]'
chk "P3: the bare install announces the skip and writes no .bak-triage copy" \
  'grep -qF "skipped (expected fork): triage.md" "$P_OUT" && ! ls "$P_DIR"/triage.md.bak-triage* >/dev/null 2>&1'
chk "P4: the rest of the bare install still happened (agents, workflows, hook + pointer wiring)" \
  '[ -f "$P_DIR/agents/triage-quick-task.md" ] && [ -f "$P_DIR/workflows/triage-compare.js" ] && grep -qxF "$(pointer_for "$P_DIR")" "$P_DIR/CLAUDE.md" && [ "$(triage_hooks "$P_DIR/settings.json")" -eq 1 ]'
P2_DIR=$(new_sandbox)
run_install "$P2_DIR" >/dev/null 2>&1
chk "P5: a first bare install (no triage.md yet) writes the repo copy" 'cmp -s "$REPO_DIR/triage.md" "$P2_DIR/triage.md"'
P3_DIR=$(new_sandbox)
CLAUDE_DIR="$P3_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
chk "P6: a first --files-only install (no triage.md yet) writes the repo copy too" 'cmp -s "$REPO_DIR/triage.md" "$P3_DIR/triage.md"'

# =============================================================================
# Case Q — subagent-model ownership is RECORDED, never inferred from the value
# (codex#20), and the default comes from config/tiers.json (M35).
# =============================================================================
Q1_DIR=$(new_sandbox)
run_install "$Q1_DIR" >/dev/null 2>&1
chk "Q1: a fresh install writes the deep model AND the ownership marker holding the same value" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q1_DIR/settings.json")" = "$DEEP_MODEL" ] && [ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL" "$Q1_DIR/settings.json")" = "$DEEP_MODEL" ]'

# A user who chose exactly our default BEFORE installing: no marker, so it stays theirs.
Q2_DIR=$(new_sandbox)
printf '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "%s"}}\n' "$DEEP_MODEL" > "$Q2_DIR/settings.json"
run_install "$Q2_DIR" >/dev/null 2>&1
chk "Q2a: install does not adopt a user-set value equal to the default (no marker written)" \
  '[ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL // \"none\"" "$Q2_DIR/settings.json")" = "none" ]'
Q2_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $Q2_OUT"
run_uninstall "$Q2_DIR" >"$Q2_OUT" 2>&1
chk "Q2b: ... and uninstall leaves it in place, with a note (value equality is not ownership)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q2_DIR/settings.json")" = "$DEEP_MODEL" ] && grep -q "no installer ownership marker" "$Q2_OUT"'

# Installed (marked), then repointed by the user: uninstall keeps the new value.
Q3_DIR=$(new_sandbox)
run_install "$Q3_DIR" >/dev/null 2>&1
jq '.env.CLAUDE_CODE_SUBAGENT_MODEL = "claude-sonnet-5"' "$Q3_DIR/settings.json" > "$Q3_DIR/s.tmp" && mv "$Q3_DIR/s.tmp" "$Q3_DIR/settings.json"
run_uninstall "$Q3_DIR" >/dev/null 2>&1
chk "Q3: a model repointed after install survives uninstall; the marker is removed" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q3_DIR/settings.json")" = "claude-sonnet-5" ] && [ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL // \"none\"" "$Q3_DIR/settings.json")" = "none" ]'

# Repointed, then re-installed: the stale marker is dropped, the value kept.
Q4_DIR=$(new_sandbox)
run_install "$Q4_DIR" >/dev/null 2>&1
jq '.env.CLAUDE_CODE_SUBAGENT_MODEL = "claude-sonnet-5"' "$Q4_DIR/settings.json" > "$Q4_DIR/s.tmp" && mv "$Q4_DIR/s.tmp" "$Q4_DIR/settings.json"
run_install "$Q4_DIR" >/dev/null 2>&1
chk "Q4: re-install over a repointed model keeps it and drops the stale marker" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q4_DIR/settings.json")" = "claude-sonnet-5" ] && [ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL // \"none\"" "$Q4_DIR/settings.json")" = "none" ]'

# A marked value from an older default (not in LEGACY_SUBAGENT_MODELS) is upgraded.
Q5_DIR=$(new_sandbox)
echo '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-4-9", "TRIAGE_LAYER_OWNS_SUBAGENT_MODEL": "claude-opus-4-9"}}' > "$Q5_DIR/settings.json"
Q5_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $Q5_OUT"
run_install "$Q5_DIR" >"$Q5_OUT" 2>&1
chk "Q5: a value still equal to its marker is upgraded to the deep model (marker follows)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q5_DIR/settings.json")" = "$DEEP_MODEL" ] && [ "$(jq -r ".env.TRIAGE_LAYER_OWNS_SUBAGENT_MODEL" "$Q5_DIR/settings.json")" = "$DEEP_MODEL" ] && grep -qF "upgraded claude-opus-4-9 -> $DEEP_MODEL (set by this installer)" "$Q5_OUT"'

# M35: the default is read from config/tiers.json, not hard-coded.
Q6_REPO=$(repo_copy)
jq '.levels.deep.claude.model = "claude-opus-9-9"' "$Q6_REPO/config/tiers.json" > "$Q6_REPO/t.tmp" && mv "$Q6_REPO/t.tmp" "$Q6_REPO/config/tiers.json"
Q6_DIR=$(new_sandbox)
CLAUDE_DIR="$Q6_DIR" "$Q6_REPO/install.sh" >/dev/null 2>&1
chk "Q6: the subagent default follows config/tiers.json levels.deep.claude.model" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$Q6_DIR/settings.json")" = "claude-opus-9-9" ]'
jq 'del(.levels.deep.claude.model)' "$Q6_REPO/config/tiers.json" > "$Q6_REPO/t.tmp" && mv "$Q6_REPO/t.tmp" "$Q6_REPO/config/tiers.json"
Q7_DIR=$(new_sandbox)
CLAUDE_DIR="$Q7_DIR" "$Q6_REPO/install.sh" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Q7_RC=$?
chk "Q7: no deep Claude model in tiers.json = install refuses before any mutation" \
  '[ "$Q7_RC" -ne 0 ] && [ ! -e "$Q7_DIR/agents" ] && [ ! -e "$Q7_DIR/settings.json" ]'

# =============================================================================
# Case R — backups of locally modified installed files are timestamped (a later
# sync never overwrites an earlier backup) and only the newest 5 per file are kept.
# =============================================================================
R_DIR=$(new_sandbox)
run_install "$R_DIR" >/dev/null 2>&1
printf 'edit-1\n' > "$R_DIR/statusline.sh"
CLAUDE_DIR="$R_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
printf 'edit-2\n' > "$R_DIR/statusline.sh"
CLAUDE_DIR="$R_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
chk "R1: two syncs over two different local edits keep BOTH edits as separate backups" \
  '[ "$(ls "$R_DIR"/statusline.sh.bak-triage-* | wc -l | tr -d " ")" -eq 2 ] && grep -lx "edit-1" "$R_DIR"/statusline.sh.bak-triage-* >/dev/null && grep -lx "edit-2" "$R_DIR"/statusline.sh.bak-triage-* >/dev/null'
for n in 3 4 5 6 7 8; do
  printf 'edit-%s\n' "$n" > "$R_DIR/statusline.sh"
  CLAUDE_DIR="$R_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
done
chk "R2: after 8 edited syncs exactly the newest 5 backups remain (edit-4..edit-8)" \
  '[ "$(ls "$R_DIR"/statusline.sh.bak-triage-* | wc -l | tr -d " ")" -eq 5 ] && grep -lx "edit-8" "$R_DIR"/statusline.sh.bak-triage-* >/dev/null && grep -lx "edit-4" "$R_DIR"/statusline.sh.bak-triage-* >/dev/null && ! grep -lx "edit-3" "$R_DIR"/statusline.sh.bak-triage-* >/dev/null'
chk "R3: the repo copy is back in place after the sync" 'cmp -s "$REPO_DIR/statusline.sh" "$R_DIR/statusline.sh"'
# R4 pins one stamp for every sync (the same-second clash a fast machine hits): a
# pruned-free older name must never be reused, and -10/-11 must sort after -2.
R4_DIR=$(new_sandbox)
run_install "$R4_DIR" >/dev/null 2>&1
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf 'edit-%s\n' "$n" > "$R4_DIR/statusline.sh"
  TRIAGE_INSTALL_STAMP=20260101T000000Z CLAUDE_DIR="$R4_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
done
chk "R4: 12 same-second syncs keep exactly the newest 5 backups (edit-8..edit-12)" \
  '[ "$(ls "$R4_DIR"/statusline.sh.bak-triage-* | wc -l | tr -d " ")" -eq 5 ] && (for e in 8 9 10 11 12; do grep -lx "edit-$e" "$R4_DIR"/statusline.sh.bak-triage-* >/dev/null || exit 1; done) && ! grep -lx "edit-7" "$R4_DIR"/statusline.sh.bak-triage-* >/dev/null'

# =============================================================================
# Case U — uninstall never destroys bytes the repo cannot reproduce (M32, agent
# memory), and a clean round-trip leaves exactly the expected set (M36).
# =============================================================================
U_DIR=$(new_sandbox)
run_install "$U_DIR" >/dev/null 2>&1
printf 'my personal rule\n' >> "$U_DIR/triage.md"
mkdir -p "$U_DIR/agent-memory/triage-builder"
printf 'remember this\n' > "$U_DIR/agent-memory/triage-builder/MEMORY.md"
U_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $U_OUT"
run_uninstall "$U_DIR" >"$U_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
U_BACKUP=$(find "$U_DIR" -maxdepth 1 -type d -name 'triage-uninstall-backup-*' | head -n 1)
chk "U1: a forked triage.md is moved to the uninstall backup dir, never just deleted" \
  '[ ! -e "$U_DIR/triage.md" ] && [ -n "$U_BACKUP" ] && grep -qx "my personal rule" "$U_BACKUP/triage.md"'
chk "U2: per-agent memory is moved to the backup dir, not rm -rf'd" \
  '[ ! -e "$U_DIR/agent-memory/triage-builder" ] && grep -qx "remember this" "$U_BACKUP/agent-memory/triage-builder/MEMORY.md"'
chk "U3: the uninstall output names the backup dir" 'grep -qF "$U_BACKUP" "$U_OUT"'
chk "U4: unmodified shipped files are deleted, not backed up (only the fork and the memory are in the backup)" \
  '[ "$(file_set "$U_BACKUP" | tr "\n" " ")" = "agent-memory/triage-builder/MEMORY.md triage.md " ]'

# M36: install -> drift clean -> uninstall on an empty dir leaves exactly these files.
U5_DIR=$(new_sandbox)
run_install "$U5_DIR" >/dev/null 2>&1
U5_DRIFT=$(mktemp)
ALL_TMP="$ALL_TMP $U5_DRIFT"
CLAUDE_DIR="$U5_DIR" "$REPO_DIR/drift.sh" >"$U5_DRIFT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
U5_DRIFT_RC=$?
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
U5_INSTALLED=$(file_set "$U5_DIR" | grep -vxE 'settings.json|CLAUDE.md' | grep -c .)
chk "U5: drift is clean right after install" '[ "$U5_DRIFT_RC" -eq 0 ] && ! grep -qE "MISSING|FORKED" "$U5_DRIFT"'
chk "U6: drift checks every file install placed (same-line count == installed file count)" \
  '[ "$(grep -cE "^(same|forked \(expected\)): " "$U5_DRIFT")" -eq "$U5_INSTALLED" ]'
run_uninstall "$U5_DIR" >/dev/null 2>&1
chk "U7: install -> uninstall leaves exactly {CLAUDE.md, settings.json} and no backup dir" \
  '[ "$(file_set "$U5_DIR" | tr "\n" " ")" = "CLAUDE.md settings.json " ]'

# =============================================================================
# Case V — retired files: bytes this repo shipped are deleted; anything else is
# moved aside, never deleted (codex#19).
# =============================================================================
V_DIR=$(new_sandbox)
mkdir -p "$V_DIR/scripts" "$V_DIR/agents"
printf '#!/bin/bash\n# my local agy wrapper\n' > "$V_DIR/scripts/agy-run.sh"
cp "$REPO_DIR/test/fixtures/legacy/triage-overflow.md" "$V_DIR/agents/triage-overflow.md"
V_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $V_OUT"
CLAUDE_DIR="$V_DIR" "$REPO_DIR/install.sh" --files-only >"$V_OUT" 2>&1
chk "V1: an agy-run.sh with unknown bytes is moved to a timestamped backup, not deleted" \
  '[ ! -e "$V_DIR/scripts/agy-run.sh" ] && grep -qx "# my local agy wrapper" "$V_DIR"/scripts/agy-run.sh.bak-triage-* && grep -q "is modified (or unhashable) — moved to" "$V_OUT"'
chk "V2: a shipped triage-overflow.md (fixture) is deleted outright, with no backup" \
  '[ ! -e "$V_DIR/agents/triage-overflow.md" ] && ! ls "$V_DIR"/agents/triage-overflow.md.bak-triage* >/dev/null 2>&1 && grep -qF "removed legacy file: $V_DIR/agents/triage-overflow.md" "$V_OUT"'

# =============================================================================
# Case W — failures are failures: a jq error mid-install/uninstall exits non-zero
# and never prints Installed./Uninstalled.; a wrong-shaped settings.json is refused
# before any mutation.
# =============================================================================
W_BIN=$(new_sandbox)
REAL_JQ=$(command -v jq)
cat > "$W_BIN/jq" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *"\$FAILJQ_MATCH"*) exit 5 ;; esac; done
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$W_BIN/jq"
W1_DIR=$(new_sandbox)
W1_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $W1_OUT"
FAILJQ_MATCH='.subagentPromptCacheTtl = $ttl' PATH="$W_BIN:$PATH" CLAUDE_DIR="$W1_DIR" "$REPO_DIR/install.sh" >"$W1_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
W1_RC=$?
chk "W1: a failing settings merge fails install (rc != 0) and never prints Installed." \
  '[ "$W1_RC" -ne 0 ] && ! grep -q "^Installed" "$W1_OUT" && grep -q "settings merge (jq) failed" "$W1_OUT"'
W2_DIR=$(new_sandbox)
run_install "$W2_DIR" >/dev/null 2>&1
W2_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $W2_OUT"
FAILJQ_MATCH='-= $workers' PATH="$W_BIN:$PATH" CLAUDE_DIR="$W2_DIR" "$REPO_DIR/uninstall.sh" >"$W2_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
W2_RC=$?
chk "W2: a failing settings rewrite fails uninstall BEFORE any file is removed" \
  '[ "$W2_RC" -ne 0 ] && ! grep -q "^Uninstalled" "$W2_OUT" && [ -f "$W2_DIR/agents/triage-builder.md" ] && grep -qxF "$(pointer_for "$W2_DIR")" "$W2_DIR/CLAUDE.md" && [ "$(triage_hooks "$W2_DIR/settings.json")" -eq 1 ]'
W3_DIR=$(new_sandbox)
printf 'keep me\n' > "$W3_DIR/CLAUDE.md"
echo '{"env": "not-an-object"}' > "$W3_DIR/settings.json"
W3_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $W3_OUT"
CLAUDE_DIR="$W3_DIR" "$REPO_DIR/install.sh" >"$W3_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
W3_RC=$?
chk "W3: a settings.json of the wrong shape is refused before any mutation" \
  '[ "$W3_RC" -ne 0 ] && grep -q "unexpected shape" "$W3_OUT" && [ ! -e "$W3_DIR/agents" ] && [ "$(cat "$W3_DIR/CLAUDE.md")" = "keep me" ]'

# =============================================================================
# Case X — a .driftignore entry with CRLF / trailing whitespace still protects the
# fork, in install.sh AND drift.sh.
# =============================================================================
X_REPO=$(repo_copy)
printf '# forks\r\ntriage.md \r\n' > "$X_REPO/.driftignore"
X_DIR=$(new_sandbox)
CLAUDE_DIR="$X_DIR" "$X_REPO/install.sh" >/dev/null 2>&1
printf 'my fork\n' > "$X_DIR/triage.md"
CLAUDE_DIR="$X_DIR" "$X_REPO/install.sh" --files-only >/dev/null 2>&1
chk "X1: install skips a fork listed as 'triage.md<space><CR>'" '[ "$(cat "$X_DIR/triage.md")" = "my fork" ]'
X_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $X_OUT"
CLAUDE_DIR="$X_DIR" "$X_REPO/drift.sh" >"$X_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
X_RC=$?
chk "X2: drift.sh reports it 'forked (expected)' and exits 0" \
  '[ "$X_RC" -eq 0 ] && grep -qxF "forked (expected): triage.md" "$X_OUT"'

# =============================================================================
# Case Y — scripts/tiers-sync.sh argument and frontmatter guards.
# =============================================================================
TSYNC="$REPO_DIR/scripts/tiers-sync.sh"
Y_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $Y_OUT"
"$TSYNC" --root >"$Y_OUT" 2>&1 &
Y_PID=$!
Y_I=0
while kill -0 "$Y_PID" 2>/dev/null && [ "$Y_I" -lt 50 ]; do sleep 0.1; Y_I=$((Y_I + 1)); done
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Y_HUNG=0
if kill -0 "$Y_PID" 2>/dev/null; then
  # shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
  Y_HUNG=1
  kill "$Y_PID" 2>/dev/null
fi
wait "$Y_PID" 2>/dev/null
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Y_RC=$?
chk "Y1: tiers-sync.sh --root with no value exits 2 (usage) instead of looping" \
  '[ "$Y_HUNG" -eq 0 ] && [ "$Y_RC" -eq 2 ]'

Y_ROOT=$(new_sandbox)
mkdir -p "$Y_ROOT/config" "$Y_ROOT/agents"
echo '{"levels": {"deep": {"claude": {"agent": "triage-x", "model": "claude-opus-9-9", "effort": "high"}}}}' > "$Y_ROOT/config/tiers.json"
printf -- '---\nname: triage-x\nmodel: claude-old\n\nbody text\nmodel: body-line-not-frontmatter\n' > "$Y_ROOT/agents/triage-x.md"
cp "$Y_ROOT/agents/triage-x.md" "$Y_ROOT/before.md"
"$TSYNC" --root "$Y_ROOT" >"$Y_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Y2_RC=$?
chk "Y2: an unclosed frontmatter fails tiers-sync (rc 1) and the file is left byte-for-byte" \
  '[ "$Y2_RC" -eq 1 ] && grep -q "never closed" "$Y_OUT" && cmp -s "$Y_ROOT/before.md" "$Y_ROOT/agents/triage-x.md"'

# =============================================================================
# Case Z — drift.sh warns (never fails) when settings.json still holds a subagent
# model a bare install would upgrade: `make sync` never edits settings (M34).
# =============================================================================
Z_DIR=$(new_sandbox)
run_install "$Z_DIR" >/dev/null 2>&1
Z_CLEAN=$(mktemp)
ALL_TMP="$ALL_TMP $Z_CLEAN"
CLAUDE_DIR="$Z_DIR" "$REPO_DIR/drift.sh" >"$Z_CLEAN" 2>&1
chk "Z1: a current install reports no pending settings migration" '! grep -q "migration pending" "$Z_CLEAN"'
jq '.env = {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5"}' "$Z_DIR/settings.json" > "$Z_DIR/s.tmp" && mv "$Z_DIR/s.tmp" "$Z_DIR/settings.json"
Z_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $Z_OUT"
CLAUDE_DIR="$Z_DIR" "$REPO_DIR/drift.sh" >"$Z_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Z_RC=$?
chk "Z2: a legacy subagent model prints 'settings migration pending' naming it, and drift still exits 0" \
  '[ "$Z_RC" -eq 0 ] && grep -q "settings migration pending: env.CLAUDE_CODE_SUBAGENT_MODEL is claude-opus-5" "$Z_OUT"'
# A synced install whose settings predate the hook (make sync never edits settings), still
# wired by the legacy import: drift names both pending migrations and still exits 0.
jq 'del(.hooks)' "$Z_DIR/settings.json" > "$Z_DIR/s.tmp" && mv "$Z_DIR/s.tmp" "$Z_DIR/settings.json"
printf '@triage.md\n' >> "$Z_DIR/CLAUDE.md"
CLAUDE_DIR="$Z_DIR" "$REPO_DIR/drift.sh" >"$Z_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
Z3_RC=$?
chk "Z3: a missing triage hook prints 'settings migration pending: triage hook missing', drift exits 0" \
  '[ "$Z3_RC" -eq 0 ] && grep -q "settings migration pending: triage hook missing" "$Z_OUT"'
chk "Z4: a legacy @triage.md import prints 'settings migration pending: legacy @triage.md import present'" \
  'grep -q "settings migration pending: legacy @triage.md import present" "$Z_OUT"'

# =============================================================================
# Case SS — the SessionStart hook that delivers triage.md to the main session only.
# A foreign SessionStart hook (live settings hold others) survives install AND
# uninstall; a legacy `@triage.md` import is migrated (backed up, removed, pointer
# added) only after the settings write succeeded.
# =============================================================================
SS_FOREIGN='{"matcher":"startup","hooks":[{"type":"command","command":"bash ~/.claude/cc-status.sh"}]}'
SS_DIR=$(new_sandbox)
printf 'my rules\n@triage.md\nmore rules\n' > "$SS_DIR/CLAUDE.md"
printf '{"hooks": {"SessionStart": [%s], "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]}}\n' "$SS_FOREIGN" > "$SS_DIR/settings.json"
SS_DRY=$(mktemp)
ALL_TMP="$ALL_TMP $SS_DRY"
CLAUDE_DIR="$SS_DIR" "$REPO_DIR/install.sh" --dry-run >"$SS_DRY" 2>&1
chk "SS1: --dry-run plans the hook append and the legacy migration, and writes nothing" \
  'grep -qF "hooks.SessionStart: triage hook missing" "$SS_DRY" && grep -qF "legacy @triage.md import present" "$SS_DRY" && grep -qxF "@triage.md" "$SS_DIR/CLAUDE.md" && [ "$(triage_hooks "$SS_DIR/settings.json")" -eq 0 ]'
SS_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $SS_OUT"
run_install "$SS_DIR" >"$SS_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS_RC=$?
chk "SS2: install exits 0; the foreign SessionStart group is kept first and ours appended after it" \
  '[ "$SS_RC" -eq 0 ] && [ "$(jq -c ".hooks.SessionStart[0]" "$SS_DIR/settings.json")" = "$SS_FOREIGN" ] && [ "$(jq ".hooks.SessionStart | length" "$SS_DIR/settings.json")" -eq 2 ] && [ "$(triage_hooks "$SS_DIR/settings.json")" -eq 1 ]'
chk "SS3: other hook events are untouched" '[ "$(jq -r ".hooks.Stop[0].hooks[0].command" "$SS_DIR/settings.json")" = "echo stop" ]'
chk "SS4: the legacy import is gone, the pointer added once, the other lines kept in order" \
  '[ "$(cat "$SS_DIR/CLAUDE.md")" = "$(printf "my rules\nmore rules\n%s" "$(pointer_for "$SS_DIR")")" ]'
chk "SS5: the pre-migration CLAUDE.md is kept as a timestamped backup" \
  'grep -qxF "@triage.md" "$SS_DIR"/CLAUDE.md.bak-triage-* && grep -qF "removed the legacy @triage.md import" "$SS_OUT"'
run_install "$SS_DIR" >/dev/null 2>&1
chk "SS6: re-install is idempotent (still 2 groups, one triage hook, one pointer)" \
  '[ "$(jq ".hooks.SessionStart | length" "$SS_DIR/settings.json")" -eq 2 ] && [ "$(triage_hooks "$SS_DIR/settings.json")" -eq 1 ] && [ "$(grep -cxF "$(pointer_for "$SS_DIR")" "$SS_DIR/CLAUDE.md")" -eq 1 ]'
# A foreign hook sharing OUR group must survive uninstall too (only our command goes).
jq '.hooks.SessionStart[1].hooks += [{"type": "command", "command": "echo also-mine"}]' "$SS_DIR/settings.json" > "$SS_DIR/s.tmp" && mv "$SS_DIR/s.tmp" "$SS_DIR/settings.json"
touch "$SS_DIR/triage.disabled"
SS_UN=$(mktemp)
ALL_TMP="$ALL_TMP $SS_UN"
run_uninstall "$SS_DIR" >"$SS_UN" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS_UN_RC=$?
chk "SS7: uninstall deletes only our hook command: the foreign group and a foreign command in our group survive" \
  '[ "$SS_UN_RC" -eq 0 ] && [ "$(triage_hooks "$SS_DIR/settings.json")" -eq 0 ] && [ "$(jq -c ".hooks.SessionStart[0]" "$SS_DIR/settings.json")" = "$SS_FOREIGN" ] && [ "$(jq -r ".hooks.SessionStart[1].hooks | map(.command) | join(\",\")" "$SS_DIR/settings.json")" = "echo also-mine" ] && [ "$(jq -r ".hooks.Stop[0].hooks[0].command" "$SS_DIR/settings.json")" = "echo stop" ]'
chk "SS8: uninstall removes the pointer line and keeps the user's lines" \
  '[ "$(cat "$SS_DIR/CLAUDE.md")" = "$(printf "my rules\nmore rules")" ]'
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS_BACKUP=$(find "$SS_DIR" -maxdepth 1 -type d -name 'triage-uninstall-backup-*' | head -n 1)
chk "SS9: the kill-switch file is moved to the uninstall backup dir, never deleted" \
  '[ ! -e "$SS_DIR/triage.disabled" ] && [ -n "$SS_BACKUP" ] && [ -e "$SS_BACKUP/triage.disabled" ]'
# Uninstall over a still-legacy CLAUDE.md (never migrated) removes the import too.
SS2_DIR=$(new_sandbox)
printf 'keep\n@triage.md\n' > "$SS2_DIR/CLAUDE.md"
run_uninstall "$SS2_DIR" >/dev/null 2>&1
chk "SS10: uninstall removes a legacy @triage.md import" '[ "$(cat "$SS2_DIR/CLAUDE.md")" = "keep" ]'

# One settings write: a jq failure in the LAST transformation (the hook append) fails
# install with settings.json AND CLAUDE.md byte-for-byte unchanged — no earlier part of
# the merge (subagent model, TTL, Agent rules) reaches the file first.
SS3_DIR=$(new_sandbox)
printf 'mine\n@triage.md\n' > "$SS3_DIR/CLAUDE.md"
printf '{"customKey": "keepme"}\n' > "$SS3_DIR/settings.json"
cp "$SS3_DIR/CLAUDE.md" "$SS3_DIR/CLAUDE.md.before"; cp "$SS3_DIR/settings.json" "$SS3_DIR/settings.json.before"
SS3_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $SS3_OUT"
FAILJQ_MATCH='(.hooks.SessionStart // []) + [$group]' PATH="$W_BIN:$PATH" CLAUDE_DIR="$SS3_DIR" "$REPO_DIR/install.sh" >"$SS3_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS3_RC=$?
chk "SS11: a jq failure in the hook part of the settings merge fails install (no Installed.); settings.json and CLAUDE.md are byte-identical (cmp)" \
  '[ "$SS3_RC" -ne 0 ] && ! grep -q "^Installed" "$SS3_OUT" && grep -q "settings merge (jq) failed" "$SS3_OUT" && cmp -s "$SS3_DIR/CLAUDE.md" "$SS3_DIR/CLAUDE.md.before" && cmp -s "$SS3_DIR/settings.json" "$SS3_DIR/settings.json.before" && ! ls "$SS3_DIR"/CLAUDE.md.bak-triage-* "$SS3_DIR"/settings.json.bak* >/dev/null 2>&1'
# ... and with NO settings.json, a failed merge leaves none behind (nothing is written
# to settings.json before the whole merge succeeded).
SS3B_DIR=$(new_sandbox)
FAILJQ_MATCH='(.hooks.SessionStart // []) + [$group]' PATH="$W_BIN:$PATH" CLAUDE_DIR="$SS3B_DIR" "$REPO_DIR/install.sh" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS3B_RC=$?
chk "SS11b: with no settings.json, a failed settings merge creates none (and no CLAUDE.md)" \
  '[ "$SS3B_RC" -ne 0 ] && [ ! -e "$SS3B_DIR/settings.json" ] && [ ! -e "$SS3B_DIR/CLAUDE.md" ]'
# The installed hook, run as Claude Code would, injects the installed rubric.
SS4_DIR=$(new_sandbox)
run_install "$SS4_DIR" >/dev/null 2>&1
SS4_CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SS4_DIR/settings.json")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
# CLAUDE_DIR is NOT in the environment and HOME points elsewhere: only the CLAUDE_DIR
# pinned in the command can lead the hook to the sandbox's files.
SS4_HOME=$(new_sandbox)
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS4_CTX=$(printf '{"session_id":"s","source":"startup"}' | env -u CLAUDE_DIR HOME="$SS4_HOME" bash -c "$SS4_CMD" | jq -r '.hookSpecificOutput.additionalContext' | tail -n +3)
chk "SS12: the installed hook command (CLAUDE_DIR unset, HOME elsewhere) injects the sandbox's triage.md" \
  '[ "$SS4_CTX" = "$(cat "$SS4_DIR/triage.md")" ]'
touch "$SS4_DIR/triage.disabled"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS4_OFF=$(printf '{"session_id":"s","source":"startup"}' | env -u CLAUDE_DIR HOME="$SS4_HOME" bash -c "$SS4_CMD" 2>&1; echo "rc=$?")
chk "SS13: the installed command honours the sandbox's triage.disabled with HOME elsewhere (prints nothing, rc 0)" \
  '[ "$SS4_OFF" = "rc=0" ] && [ ! -e "$SS4_HOME/.claude/triage.disabled" ]'
# A CLAUDE_DIR with a space: the pinned command still runs, and a re-install still
# recognizes it as ours (exactly one hook, no duplicate group).
SS5_DIR="$(new_sandbox)/claude dir"
mkdir -p "$SS5_DIR"
run_install "$SS5_DIR" >/dev/null 2>&1
run_install "$SS5_DIR" >/dev/null 2>&1
SS5_CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SS5_DIR/settings.json")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
SS5_CTX=$(printf '{}' | env -u CLAUDE_DIR HOME="$SS4_HOME" bash -c "$SS5_CMD" | jq -r '.hookSpecificOutput.additionalContext' | tail -n +3)
chk "SS14: a CLAUDE_DIR with a space: one hook after two installs, and it injects that dir's triage.md" \
  '[ "$(jq ".hooks.SessionStart | length" "$SS5_DIR/settings.json")" -eq 1 ] && [ "$SS5_CTX" = "$(cat "$SS5_DIR/triage.md")" ]'
run_uninstall "$SS5_DIR" >/dev/null 2>&1
chk "SS15: ... and uninstall removes it (hooks key gone)" '[ "$(jq "has(\"hooks\")" "$SS5_DIR/settings.json")" = "false" ]'

# =============================================================================
# Case OWN — one anchored ownership predicate (install.sh and uninstall.sh copies,
# N8 pins them equal). Commands that merely CONTAIN the script path are foreign:
# never counted as installed, never removed.
# =============================================================================
OWN_DIR=$(new_sandbox)
OWN_FOREIGN='[{"type":"command","command":"bash /x/scripts/triage-context.sh.backup"},{"type":"command","command":"echo /x/scripts/triage-context.sh"},{"type":"command","command":"cd /x && bash scripts/triage-context.sh"}]'
printf '{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":%s}]}}\n' "$OWN_FOREIGN" > "$OWN_DIR/settings.json"
OWN_ST=$(mktemp)
ALL_TMP="$ALL_TMP $OWN_ST"
CLAUDE_DIR="$OWN_DIR" "$REPO_DIR/install.sh" --settings-status >"$OWN_ST" 2>&1
chk "OWN1: foreign commands containing the script path do not count: status says the hook is missing" \
  'grep -q "settings migration pending: triage hook missing" "$OWN_ST"'
run_install "$OWN_DIR" >/dev/null 2>&1
chk "OWN2: install appends our canonical group and keeps the foreign group byte-for-byte first" \
  '[ "$(jq ".hooks.SessionStart | length" "$OWN_DIR/settings.json")" -eq 2 ] && [ "$(jq -c ".hooks.SessionStart[0].hooks" "$OWN_DIR/settings.json")" = "$(printf "%s" "$OWN_FOREIGN" | jq -c .)" ] && [ "$(triage_hooks "$OWN_DIR/settings.json")" -eq 1 ]'
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
OWN_WANT=$(printf '[{"matcher":"startup|resume|clear|compact","hooks":%s}]' "$OWN_FOREIGN" | jq -c .)
run_uninstall "$OWN_DIR" >/dev/null 2>&1
chk "OWN3: uninstall removes only our group; all three foreign commands survive" \
  '[ "$(jq -c ".hooks.SessionStart" "$OWN_DIR/settings.json")" = "$OWN_WANT" ]'
# An unpinned form (`bash <dir>/scripts/triage-context.sh`) is not this install's hook:
# uninstall leaves it.
OWN2_DIR=$(new_sandbox)
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash %s/scripts/triage-context.sh"}]}]}}\n' "$OWN2_DIR" > "$OWN2_DIR/settings.json"
cp "$OWN2_DIR/settings.json" "$OWN2_DIR/settings.before"
run_uninstall "$OWN2_DIR" >/dev/null 2>&1
chk "OWN4: uninstall leaves an unpinned command (bash <dir>/scripts/triage-context.sh): not this install's hook" \
  '[ "$(jq -c .hooks "$OWN2_DIR/settings.json")" = "$(jq -c .hooks "$OWN2_DIR/settings.before")" ]'

# =============================================================================
# Case MATCH — the hook counts as installed only when a group holding OUR command
# covers startup, clear and compact; otherwise our canonical group is appended and
# the existing groups are left alone.
# =============================================================================
MATCH_DIR=$(new_sandbox)
MATCH_CMD="CLAUDE_DIR=$MATCH_DIR bash $MATCH_DIR/scripts/triage-context.sh"
MATCH_RESUME=$(jq -cn --arg c "$MATCH_CMD" '{matcher: "resume", hooks: [{type: "command", command: $c}]}')
printf '{"hooks":{"SessionStart":[%s]}}\n' "$MATCH_RESUME" > "$MATCH_DIR/settings.json"
MATCH_ST=$(mktemp)
ALL_TMP="$ALL_TMP $MATCH_ST"
CLAUDE_DIR="$MATCH_DIR" "$REPO_DIR/install.sh" --settings-status >"$MATCH_ST" 2>&1
chk "MATCH1: our command under a resume-only matcher is not installed (status: hook missing)" \
  'grep -q "triage hook missing" "$MATCH_ST"'
run_install "$MATCH_DIR" >/dev/null 2>&1
chk "MATCH2: install appends the full-matcher group and leaves the resume group exactly as it was" \
  '[ "$(jq ".hooks.SessionStart | length" "$MATCH_DIR/settings.json")" -eq 2 ] && [ "$(jq -c ".hooks.SessionStart[0]" "$MATCH_DIR/settings.json")" = "$MATCH_RESUME" ] && [ "$(jq -r ".hooks.SessionStart[1].matcher" "$MATCH_DIR/settings.json")" = "startup|resume|clear|compact" ]'
MATCH2_DIR=$(new_sandbox)
jq -n --arg c "$(hook_cmd_for "$MATCH2_DIR")" '{hooks: {SessionStart: [{matcher: "*", hooks: [{type: "command", command: $c}]}]}}' > "$MATCH2_DIR/settings.json"
run_install "$MATCH2_DIR" >/dev/null 2>&1
MATCH3_DIR=$(new_sandbox)
jq -n --arg c "$(hook_cmd_for "$MATCH3_DIR")" '{hooks: {SessionStart: [{matcher: "compact|clear|resume|startup", hooks: [{type: "command", command: $c}]}]}}' > "$MATCH3_DIR/settings.json"
run_install "$MATCH3_DIR" >/dev/null 2>&1
chk "MATCH3: a \"*\" matcher, or all four events in any order, on this install's command counts as installed (no group appended)" \
  '[ "$(jq ".hooks.SessionStart | length" "$MATCH2_DIR/settings.json")" -eq 1 ] && [ "$(jq ".hooks.SessionStart | length" "$MATCH3_DIR/settings.json")" -eq 1 ]'
# Each of the four events is required: a matcher missing any ONE of them is not installed.
for MATCH_EV in startup resume clear compact; do
  MATCH_EV_DIR=$(new_sandbox)
  # shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
  MATCH_EV_M=$(printf 'startup|resume|clear|compact' | tr '|' '\n' | grep -vxF "$MATCH_EV" | paste -sd'|' -)
  jq -n --arg c "$(hook_cmd_for "$MATCH_EV_DIR")" --arg m "$MATCH_EV_M" '{hooks: {SessionStart: [{matcher: $m, hooks: [{type: "command", command: $c}]}]}}' > "$MATCH_EV_DIR/settings.json"
  MATCH_EV_ST=$(mktemp)
  ALL_TMP="$ALL_TMP $MATCH_EV_ST"
  CLAUDE_DIR="$MATCH_EV_DIR" "$REPO_DIR/install.sh" --settings-status >"$MATCH_EV_ST" 2>&1
  run_install "$MATCH_EV_DIR" >/dev/null 2>&1
  chk "MATCH4-$MATCH_EV: a matcher without $MATCH_EV ($MATCH_EV_M) is not installed: status says missing, install appends the full group" \
    'grep -q "triage hook missing" "$MATCH_EV_ST" && [ "$(jq ".hooks.SessionStart | length" "$MATCH_EV_DIR/settings.json")" -eq 2 ] && [ "$(jq -r ".hooks.SessionStart[0].matcher" "$MATCH_EV_DIR/settings.json")" = "$MATCH_EV_M" ] && [ "$(jq -r ".hooks.SessionStart[1].matcher" "$MATCH_EV_DIR/settings.json")" = "startup|resume|clear|compact" ]'
done

# =============================================================================
# Case OFF — disableAllHooks: true. The hook could never run, so install must NOT
# migrate: the @triage.md import stays, no pointer, a diagnostic is printed;
# --settings-status reports it.
# =============================================================================
OFF_DIR=$(new_sandbox)
printf 'mine\n@triage.md\n' > "$OFF_DIR/CLAUDE.md"
printf '{"disableAllHooks": true}\n' > "$OFF_DIR/settings.json"
OFF_ST=$(mktemp); OFF_OUT=$(mktemp); OFF_DRY=$(mktemp)
ALL_TMP="$ALL_TMP $OFF_ST $OFF_OUT $OFF_DRY"
CLAUDE_DIR="$OFF_DIR" "$REPO_DIR/install.sh" --settings-status >"$OFF_ST" 2>&1
chk "OFF1: --settings-status reports disableAllHooks (migration blocked), not a pending legacy migration" \
  'grep -q "settings migration blocked: disableAllHooks is true" "$OFF_ST" && ! grep -q "legacy @triage.md import present" "$OFF_ST"'
CLAUDE_DIR="$OFF_DIR" "$REPO_DIR/install.sh" --dry-run >"$OFF_DRY" 2>&1
chk "OFF2: --dry-run plans no CLAUDE.md change and says why" \
  'grep -q "disableAllHooks is true" "$OFF_DRY" && ! grep -q "would append pointer line" "$OFF_DRY"'
run_install "$OFF_DIR" >"$OFF_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
OFF_RC=$?
chk "OFF3: install exits 0, prints the diagnostic, and leaves CLAUDE.md byte-for-byte (import kept, no pointer, no backup)" \
  '[ "$OFF_RC" -eq 0 ] && grep -q "WARNING: disableAllHooks is true" "$OFF_OUT" && [ "$(cat "$OFF_DIR/CLAUDE.md")" = "$(printf "mine\n@triage.md")" ] && ! ls "$OFF_DIR"/CLAUDE.md.bak-triage-* >/dev/null 2>&1'
chk "OFF4: disableAllHooks itself is left as the user set it" '[ "$(jq ".disableAllHooks" "$OFF_DIR/settings.json")" = "true" ]'

# =============================================================================
# Case CRLF — a CRLF CLAUDE.md: the legacy import is still recognized (status,
# install, uninstall) and every other line keeps its CR.
# =============================================================================
CRLF_DIR=$(new_sandbox)
printf 'rules\r\n@triage.md\r\nmore\r\n' > "$CRLF_DIR/CLAUDE.md"
CRLF_ST=$(mktemp)
ALL_TMP="$ALL_TMP $CRLF_ST"
CLAUDE_DIR="$CRLF_DIR" "$REPO_DIR/install.sh" --settings-status >"$CRLF_ST" 2>&1
chk "CRLF1: --settings-status reports a CRLF legacy import" 'grep -q "legacy @triage.md import present" "$CRLF_ST"'
run_install "$CRLF_DIR" >/dev/null 2>&1
chk "CRLF2: install removes the CRLF import and keeps the other lines' CRs" \
  '[ "$(od -An -c "$CRLF_DIR/CLAUDE.md" | tr -d " \n")" = "$(printf "rules\r\nmore\r\n%s\n" "$(pointer_for "$CRLF_DIR")" | od -An -c | tr -d " \n")" ]'
CRLF2_DIR=$(new_sandbox)
printf 'keep\r\n@triage.md\r\n' > "$CRLF2_DIR/CLAUDE.md"
run_uninstall "$CRLF2_DIR" >/dev/null 2>&1
chk "CRLF3: uninstall removes a CRLF import too (keep\\r stays)" \
  '[ "$(od -An -c "$CRLF2_DIR/CLAUDE.md" | tr -d " \n")" = "$(printf "keep\r\n" | od -An -c | tr -d " \n")" ]'

# =============================================================================
# Case FC — fail closed: an evaluation error is never a decision. A jq failure in the
# hook decision, or an awk failure filtering CLAUDE.md, aborts with settings.json AND
# CLAUDE.md byte-for-byte unchanged, and no Installed./Uninstalled.
# =============================================================================
FC_BIN=$(new_sandbox)
REAL_AWK=$(command -v awk)
cat > "$FC_BIN/awk" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *"\$FAILAWK_MATCH"*) exit 2 ;; esac; done
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$FC_BIN/awk"
FC_SETTINGS='{"customKey": "keepme"}'
fc_sandbox() { # -> a sandbox with a legacy CLAUDE.md and a small settings.json
  local d; d=$(new_sandbox)
  printf 'mine\n@triage.md\nalso mine\n' > "$d/CLAUDE.md"
  printf '%s\n' "$FC_SETTINGS" > "$d/settings.json"
  printf '%s' "$d"
}
FC1_DIR=$(fc_sandbox)
FC1_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $FC1_OUT"
FAILAWK_MATCH='keep = !is_legacy($0) && (drop' PATH="$FC_BIN:$PATH" CLAUDE_DIR="$FC1_DIR" "$REPO_DIR/install.sh" >"$FC1_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
FC1_RC=$?
chk "FC1: an awk failure filtering CLAUDE.md fails install; CLAUDE.md and settings.json are untouched" \
  '[ "$FC1_RC" -ne 0 ] && ! grep -q "^Installed" "$FC1_OUT" && grep -q "could not filter" "$FC1_OUT" && [ "$(cat "$FC1_DIR/CLAUDE.md")" = "$(printf "mine\n@triage.md\nalso mine")" ] && [ "$(cat "$FC1_DIR/settings.json")" = "$FC_SETTINGS" ]'
FC2_DIR=$(fc_sandbox)
FC2_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $FC2_OUT"
FAILJQ_MATCH='def covers' PATH="$W_BIN:$PATH" CLAUDE_DIR="$FC2_DIR" "$REPO_DIR/install.sh" >"$FC2_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
FC2_RC=$?
chk "FC2: a jq failure in the hook decision fails install (never read as 'add'); nothing changed" \
  '[ "$FC2_RC" -ne 0 ] && ! grep -q "^Installed" "$FC2_OUT" && grep -q "could not evaluate the SessionStart hooks" "$FC2_OUT" && [ "$(cat "$FC2_DIR/CLAUDE.md")" = "$(printf "mine\n@triage.md\nalso mine")" ] && [ "$(cat "$FC2_DIR/settings.json")" = "$FC_SETTINGS" ]'
FC2_ST=$(mktemp)
ALL_TMP="$ALL_TMP $FC2_ST"
FAILJQ_MATCH='def covers' PATH="$W_BIN:$PATH" CLAUDE_DIR="$FC2_DIR" "$REPO_DIR/install.sh" --settings-status >"$FC2_ST" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
FC2_ST_RC=$?
chk "FC3: --settings-status reports the jq failure as an error, never as 'triage hook missing'" \
  '[ "$FC2_ST_RC" -ne 0 ] && grep -q "could not evaluate" "$FC2_ST" && ! grep -q "triage hook missing" "$FC2_ST"'
FC4_DIR=$(fc_sandbox)
run_install "$FC4_DIR" >/dev/null 2>&1
cp "$FC4_DIR/CLAUDE.md" "$FC4_DIR/CLAUDE.md.before"
FC4_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $FC4_OUT"
FAILAWK_MATCH='keep = !is_legacy($0) && l != p1' PATH="$FC_BIN:$PATH" CLAUDE_DIR="$FC4_DIR" "$REPO_DIR/uninstall.sh" >"$FC4_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
FC4_RC=$?
chk "FC4: an awk failure filtering CLAUDE.md fails uninstall before anything is touched" \
  '[ "$FC4_RC" -ne 0 ] && ! grep -q "^Uninstalled" "$FC4_OUT" && cmp -s "$FC4_DIR/CLAUDE.md" "$FC4_DIR/CLAUDE.md.before" && [ "$(triage_hooks "$FC4_DIR/settings.json")" -eq 1 ] && [ -f "$FC4_DIR/agents/triage-builder.md" ]'

# =============================================================================
# Case PIN — 'installed' means THIS install's hook: a command pinned to the current
# CLAUDE_DIR. A hook pinned to another dir, or an unpinned one, neither counts as
# installed nor allows the legacy import to go before ours is appended; uninstall
# removes only ours.
# =============================================================================
PIN_DIR=$(new_sandbox)
PIN_FOREIGN=$(jq -cn --arg c "$(hook_cmd_for /elsewhere/claude)" '{matcher: "startup|resume|clear|compact", hooks: [{type: "command", command: $c}]}')
PIN_UNPINNED=$(jq -cn --arg c "bash $PIN_DIR/scripts/triage-context.sh" '{matcher: "startup|resume|clear|compact", hooks: [{type: "command", command: $c}]}')
printf '{"hooks":{"SessionStart":[%s,%s]}}\n' "$PIN_FOREIGN" "$PIN_UNPINNED" > "$PIN_DIR/settings.json"
printf 'mine\n@triage.md\n' > "$PIN_DIR/CLAUDE.md"
PIN_ST=$(mktemp); PIN_OUT=$(mktemp); PIN_UN=$(mktemp)
ALL_TMP="$ALL_TMP $PIN_ST $PIN_OUT $PIN_UN"
CLAUDE_DIR="$PIN_DIR" "$REPO_DIR/install.sh" --settings-status >"$PIN_ST" 2>&1
chk "PIN1: a hook pinned to another CLAUDE_DIR and an unpinned one: status says this install's hook is missing" \
  'grep -q "settings migration pending: triage hook missing" "$PIN_ST" && grep -q "legacy @triage.md import present" "$PIN_ST"'
run_install "$PIN_DIR" >"$PIN_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
PIN_RC=$?
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
PIN_ADD_AT=$(grep -n "^hooks.SessionStart: added the triage hook" "$PIN_OUT" | cut -d: -f1)
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
PIN_MIG_AT=$(grep -n "^CLAUDE.md: removed the legacy @triage.md import" "$PIN_OUT" | cut -d: -f1)
chk "PIN2: install appends this install's pinned hook after both foreign groups, and only then migrates CLAUDE.md" \
  '[ "$PIN_RC" -eq 0 ] && [ -n "$PIN_ADD_AT" ] && [ -n "$PIN_MIG_AT" ] && [ "$PIN_ADD_AT" -lt "$PIN_MIG_AT" ] && [ "$(jq ".hooks.SessionStart | length" "$PIN_DIR/settings.json")" -eq 3 ] && [ "$(jq -c ".hooks.SessionStart[0]" "$PIN_DIR/settings.json")" = "$PIN_FOREIGN" ] && [ "$(jq -c ".hooks.SessionStart[1]" "$PIN_DIR/settings.json")" = "$PIN_UNPINNED" ] && [ "$(jq -r ".hooks.SessionStart[2].hooks[0].command" "$PIN_DIR/settings.json")" = "$(hook_cmd_for "$PIN_DIR")" ]'
chk "PIN3: ... the legacy import is gone and the pointer names this install's triage.md" \
  '[ "$(cat "$PIN_DIR/CLAUDE.md")" = "$(printf "mine\n%s" "$(pointer_for "$PIN_DIR")")" ]'
run_uninstall "$PIN_DIR" >"$PIN_UN" 2>&1
chk "PIN4: uninstall removes only the hook pinned to this CLAUDE_DIR (the other-dir and unpinned groups stay)" \
  '[ "$(jq -c ".hooks.SessionStart" "$PIN_DIR/settings.json")" = "$(printf "[%s,%s]" "$PIN_FOREIGN" "$PIN_UNPINNED")" ]'
# Uninstall run for ANOTHER CLAUDE_DIR leaves this install's hook and pointer alone.
PIN2_DIR=$(new_sandbox)
run_install "$PIN2_DIR" >/dev/null 2>&1
PIN2_OTHER=$(new_sandbox)
cp "$PIN2_DIR/settings.json" "$PIN2_OTHER/settings.json"
cp "$PIN2_DIR/CLAUDE.md" "$PIN2_OTHER/CLAUDE.md"
run_uninstall "$PIN2_OTHER" >/dev/null 2>&1
chk "PIN5: uninstall with a different CLAUDE_DIR keeps a hook and pointer line that name another install" \
  '[ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$PIN2_OTHER/settings.json")" = "$(hook_cmd_for "$PIN2_DIR")" ] && cmp -s "$PIN2_OTHER/CLAUDE.md" "$PIN2_DIR/CLAUDE.md"'

# =============================================================================
# Case TYPE — ownership requires .type "command": a prompt-type entry carrying our
# exact command is not installed and is never removed.
# =============================================================================
TYPE_DIR=$(new_sandbox)
TYPE_GROUP=$(jq -cn --arg c "$(hook_cmd_for "$TYPE_DIR")" '{matcher: "startup|resume|clear|compact", hooks: [{type: "prompt", command: $c}]}')
printf '{"hooks":{"SessionStart":[%s]}}\n' "$TYPE_GROUP" > "$TYPE_DIR/settings.json"
TYPE_ST=$(mktemp)
ALL_TMP="$ALL_TMP $TYPE_ST"
CLAUDE_DIR="$TYPE_DIR" "$REPO_DIR/install.sh" --settings-status >"$TYPE_ST" 2>&1
run_install "$TYPE_DIR" >/dev/null 2>&1
chk "TYPE1: a type:prompt entry with our command is not installed: status says missing, install appends a command hook" \
  'grep -q "triage hook missing" "$TYPE_ST" && [ "$(jq ".hooks.SessionStart | length" "$TYPE_DIR/settings.json")" -eq 2 ] && [ "$(jq -c ".hooks.SessionStart[0]" "$TYPE_DIR/settings.json")" = "$TYPE_GROUP" ] && [ "$(jq -r ".hooks.SessionStart[1].hooks[0].type" "$TYPE_DIR/settings.json")" = "command" ]'
run_uninstall "$TYPE_DIR" >/dev/null 2>&1
chk "TYPE2: uninstall removes our command hook and keeps the type:prompt entry" \
  '[ "$(jq -c ".hooks.SessionStart" "$TYPE_DIR/settings.json")" = "$(printf "[%s]" "$TYPE_GROUP")" ]'

# =============================================================================
# Case RUB — the legacy import goes only when the INSTALLED rubric passes
# triage-context.sh --check. A preserved over-cap fork (fixture .driftignore naming
# triage.md) blocks the migration: import kept, no pointer, a diagnostic; the hook is
# still added. Once the fork fits, install migrates.
# =============================================================================
RUB_REPO=$(repo_copy)
printf 'triage.md\n' > "$RUB_REPO/.driftignore"
RUB_DIR=$(new_sandbox)
head -c 10001 /dev/zero | tr '\0' 'x' > "$RUB_DIR/triage.md"
printf 'mine\n@triage.md\n' > "$RUB_DIR/CLAUDE.md"
cp "$RUB_DIR/CLAUDE.md" "$RUB_DIR/CLAUDE.md.before"
RUB_ST=$(mktemp); RUB_DRY=$(mktemp); RUB_OUT=$(mktemp); RUB_OUT2=$(mktemp)
ALL_TMP="$ALL_TMP $RUB_ST $RUB_DRY $RUB_OUT $RUB_OUT2"
CLAUDE_DIR="$RUB_DIR" "$RUB_REPO/install.sh" --settings-status >"$RUB_ST" 2>&1
chk "RUB1: --settings-status reports the migration blocked by the over-cap rubric, not pending" \
  'grep -q "settings migration blocked: the rubric the triage hook would read fails its size check" "$RUB_ST" && grep -qF "$RUB_DIR/triage.md is too big" "$RUB_ST" && ! grep -q "legacy @triage.md import present" "$RUB_ST"'
CLAUDE_DIR="$RUB_DIR" "$RUB_REPO/install.sh" --dry-run >"$RUB_DRY" 2>&1
chk "RUB2: --dry-run plans no CLAUDE.md change and says why" \
  'grep -q "fails its size check" "$RUB_DRY" && ! grep -q "would append pointer line" "$RUB_DRY" && ! grep -q "would remove it" "$RUB_DRY"'
CLAUDE_DIR="$RUB_DIR" "$RUB_REPO/install.sh" >"$RUB_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
RUB_RC=$?
chk "RUB3: install keeps CLAUDE.md byte-for-byte (import kept, no pointer, no backup), warns, and still adds the hook" \
  '[ "$RUB_RC" -eq 0 ] && grep -q "WARNING: the rubric the triage hook would read fails its size check" "$RUB_OUT" && cmp -s "$RUB_DIR/CLAUDE.md" "$RUB_DIR/CLAUDE.md.before" && ! ls "$RUB_DIR"/CLAUDE.md.bak-triage-* >/dev/null 2>&1 && [ "$(triage_hooks "$RUB_DIR/settings.json")" -eq 1 ]'
printf 'a small fork\n' > "$RUB_DIR/triage.md"
CLAUDE_DIR="$RUB_DIR" "$RUB_REPO/install.sh" >"$RUB_OUT2" 2>&1
chk "RUB4: once the installed fork fits, install migrates (import gone, pointer added, still one hook)" \
  '[ "$(cat "$RUB_DIR/CLAUDE.md")" = "$(printf "mine\n%s" "$(pointer_for "$RUB_DIR")")" ] && [ "$(triage_hooks "$RUB_DIR/settings.json")" -eq 1 ]'

# =============================================================================
# Case FALSE — a non-null, non-array hooks.SessionStart (false), or a false env, is
# refused as wrong-shaped before anything changes (`// []` used to read false as absent).
# =============================================================================
for FALSE_JSON in '{"hooks":{"SessionStart":false}}' '{"env":false}'; do
  FALSE_DIR=$(new_sandbox)
  printf '%s\n' "$FALSE_JSON" > "$FALSE_DIR/settings.json"
  printf 'mine\n@triage.md\n' > "$FALSE_DIR/CLAUDE.md"
  cp "$FALSE_DIR/settings.json" "$FALSE_DIR/settings.before"; cp "$FALSE_DIR/CLAUDE.md" "$FALSE_DIR/CLAUDE.before"
  FALSE_OUT=$(mktemp)
  ALL_TMP="$ALL_TMP $FALSE_OUT"
  run_install "$FALSE_DIR" >"$FALSE_OUT" 2>&1
  # shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
  FALSE_RC=$?
  chk "FALSE: $FALSE_JSON is refused as wrong-shaped with nothing changed (settings.json and CLAUDE.md cmp-identical, no files copied)" \
    '[ "$FALSE_RC" -ne 0 ] && grep -q "unexpected shape" "$FALSE_OUT" && cmp -s "$FALSE_DIR/settings.json" "$FALSE_DIR/settings.before" && cmp -s "$FALSE_DIR/CLAUDE.md" "$FALSE_DIR/CLAUDE.before" && [ ! -e "$FALSE_DIR/agents" ]'
done

# =============================================================================
# Case BYTE — the migration (install) and the unwiring (uninstall) keep every other
# byte of CLAUDE.md: CRLF lines, and an unterminated last line, compared with cmp.
# =============================================================================
BYTE1_DIR=$(new_sandbox)
printf '@triage.md\r\n%s\r\nkeep' "$(pointer_for "$BYTE1_DIR")" > "$BYTE1_DIR/CLAUDE.md"
printf '%s\r\nkeep' "$(pointer_for "$BYTE1_DIR")" > "$BYTE1_DIR/want"
run_install "$BYTE1_DIR" >/dev/null 2>&1
chk "BYTE1: CRLF file, pointer already present, no final newline: only the import's bytes go" \
  'cmp -s "$BYTE1_DIR/CLAUDE.md" "$BYTE1_DIR/want"'
BYTE2_DIR=$(new_sandbox)
printf '%s\na\n@triage.md' "$(pointer_for "$BYTE2_DIR")" > "$BYTE2_DIR/CLAUDE.md"
printf '%s\na\n' "$(pointer_for "$BYTE2_DIR")" > "$BYTE2_DIR/want"
run_install "$BYTE2_DIR" >/dev/null 2>&1
chk "BYTE2: an unterminated import as the last line goes; the line before keeps its newline" \
  'cmp -s "$BYTE2_DIR/CLAUDE.md" "$BYTE2_DIR/want"'
BYTE3_DIR=$(new_sandbox)
printf 'x\r\n%s\ny' "$(pointer_for "$BYTE3_DIR")" > "$BYTE3_DIR/CLAUDE.md"
printf 'x\r\ny' > "$BYTE3_DIR/want"
run_uninstall "$BYTE3_DIR" >/dev/null 2>&1
chk "BYTE3: uninstall removes the pointer and keeps every other byte (CRLF line, unterminated last line)" \
  'cmp -s "$BYTE3_DIR/CLAUDE.md" "$BYTE3_DIR/want"'

# =============================================================================
# Case NL — a CLAUDE_DIR with a line break is refused before anything changes (the
# pointer line embeds it and is matched line by line).
# =============================================================================
NL_DIR="$(new_sandbox)/a
b"
mkdir -p "$NL_DIR"
NL_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $NL_OUT"
run_install "$NL_DIR" >"$NL_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
NL_RC=$?
chk "NL1: install refuses a CLAUDE_DIR containing a line break, writing nothing" \
  '[ "$NL_RC" -ne 0 ] && grep -q "CLAUDE_DIR contains a line break" "$NL_OUT" && [ ! -e "$NL_DIR/settings.json" ] && [ ! -e "$NL_DIR/agents" ]'

# =============================================================================
# Case DS — drift with NO settings.json (a files-only install): the missing hook is
# still reported (an absent settings.json is an empty one).
# =============================================================================
DS_DIR=$(new_sandbox)
CLAUDE_DIR="$DS_DIR" "$REPO_DIR/install.sh" --files-only >/dev/null 2>&1
DS_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $DS_OUT"
CLAUDE_DIR="$DS_DIR" "$REPO_DIR/drift.sh" >"$DS_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
DS_RC=$?
chk "DS1: drift without settings.json warns 'triage hook missing' and still exits 0" \
  '[ "$DS_RC" -eq 0 ] && [ ! -e "$DS_DIR/settings.json" ] && grep -q "settings migration pending: triage hook missing" "$DS_OUT"'

# =============================================================================
# Statusline checks (direct, no install needed)
#
# statusline.sh appends a live "· sub Nk" subagent-spend suffix (scripts/triage-
# usage.sh), resolved either from the input's `transcript_path` field or, if that's
# absent, by scanning ~/.claude/projects/<slug-of-$PWD> for this cwd's OWN real
# session transcripts — ambient state outside this suite's sandboxing. S1/S2 pin an
# explicit `transcript_path` at a fixture with no `subagents/` dir, so the suffix
# resolves to empty deterministically regardless of what real sessions exist for
# this repo. S3 pins one at a fixture that DOES have subagent data, to cover the
# suffix's happy path with a known expected total (same fixture test/usage-tally.sh
# uses directly). Each case uses its own `session_id` so the 30s statusline cache
# can never serve a stale value across cases or a prior ad-hoc manual run.
# =============================================================================
STATUSLINE="$REPO_DIR/statusline.sh"
NO_SUB_TRANSCRIPT="$REPO_DIR/test/fixtures/statusline/no-subagents.jsonl"
THREE_FAMILY_TRANSCRIPT="$REPO_DIR/test/fixtures/usage/three-family.jsonl"

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_NONNUMERIC=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":"n/a"},"session_id":"test-statusline-s1","transcript_path":"'"$NO_SUB_TRANSCRIPT"'"}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S1: statusline with non-numeric used_percentage does not crash and prints model only" \
  '[ "$STATUS_NONNUMERIC" = "Opus" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_NUMERIC=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.7},"session_id":"test-statusline-s2","transcript_path":"'"$NO_SUB_TRANSCRIPT"'"}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S2: statusline with used_percentage=42.7 prints 'Opus · ctx 42%'" \
  '[ "$STATUS_NUMERIC" = "Opus · ctx 42%" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_WITH_SUB=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.7},"session_id":"test-statusline-s3","transcript_path":"'"$THREE_FAMILY_TRANSCRIPT"'"}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S3: statusline appends '· sub Nk' from real subagent data (haiku 2k+sonnet 50k+fable 6k=58k)" \
  '[ "$STATUS_WITH_SUB" = "Opus · ctx 42% · sub 58k" ]'

# =============================================================================
# Prompt-cache segment checks (scripts/triage-cache-segment.sh, direct + wired
# through statusline.sh). Field names verified against the installed Claude
# Code binary's own statusline help text (checked 2026-09-15, v2.1.272:
# `strings "$(which claude)" | grep -A2 last_miss_cause.causes`) and
# https://code.claude.com/docs/en/statusline's "Prompt cache fields" table:
# prompt_cache.{caching_observed,warm,hit_ratio,last_miss_cause.causes[]}.
# =============================================================================
CACHE_SH="$REPO_DIR/scripts/triage-cache-segment.sh"

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CS_WARM=$(printf '%s' '{"prompt_cache":{"caching_observed":true,"warm":true,"hit_ratio":0.873}}' \
  | PATH=/usr/bin:/bin bash "$CACHE_SH")
chk "T1: warm cache with hit_ratio 0.873 renders 'cache 87% warm'" '[ "$CS_WARM" = "cache 87% warm" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CS_COLD=$(printf '%s' '{"prompt_cache":{"caching_observed":true,"warm":false,"hit_ratio":0.42,"last_miss_cause":{"causes":["tool_result_pruning"]}}}' \
  | PATH=/usr/bin:/bin bash "$CACHE_SH")
chk "T2: cold cache with a diagnosed miss cause renders 'cache 42% cold (tool_result_pruning)'" \
  '[ "$CS_COLD" = "cache 42% cold (tool_result_pruning)" ]'
# jq's `//` treats a literal `false` as absent — warm:false must still render "cold",
# not be silently dropped as if warm were missing.
chk "T2b: warm:false is read as an explicit boolean, not swallowed by jq's // empty" \
  '[ "$CS_COLD" != "" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CS_NOPC=$(printf '%s' '{"model":{"display_name":"Opus"}}' | PATH=/usr/bin:/bin bash "$CACHE_SH")
chk "T3: no prompt_cache field at all renders nothing" '[ "$CS_NOPC" = "" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CS_NOTOBS=$(printf '%s' '{"prompt_cache":{"caching_observed":false}}' | PATH=/usr/bin:/bin bash "$CACHE_SH")
chk "T4: caching_observed:false renders nothing (provider/gateway doesn't report cache tokens)" \
  '[ "$CS_NOTOBS" = "" ]'

CS_MALFORMED_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $CS_MALFORMED_OUT"
printf 'not json at all' | PATH=/usr/bin:/bin bash "$CACHE_SH" >"$CS_MALFORMED_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CS_MALFORMED_RC=$?
chk "T5: malformed JSON on stdin exits 0" '[ "$CS_MALFORMED_RC" -eq 0 ]'
chk "T6: malformed JSON on stdin prints nothing" '[ ! -s "$CS_MALFORMED_OUT" ]'

# --- wired through statusline.sh -------------------------------------------
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_WITH_CACHE=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.7},"session_id":"test-statusline-s4","transcript_path":"'"$NO_SUB_TRANSCRIPT"'","prompt_cache":{"caching_observed":true,"warm":true,"hit_ratio":0.873}}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S4: statusline appends '· cache 87% warm' after the model/ctx tail" \
  '[ "$STATUS_WITH_CACHE" = "Opus · ctx 42% · cache 87% warm" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_NO_CACHE=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.7},"session_id":"test-statusline-s5","transcript_path":"'"$NO_SUB_TRANSCRIPT"'"}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S5: statusline with no prompt_cache field renders identically to before (no dangling separator)" \
  '[ "$STATUS_NO_CACHE" = "Opus · ctx 42%" ]'


# =============================================================================
# Case CANON — one spelling of CLAUDE_DIR (L2): a trailing slash or a `.` component
# is the SAME install, so a second install neither adds a second hook nor a second
# pointer, and uninstall through either spelling removes them. A relative CLAUDE_DIR
# is refused before anything is written.
# =============================================================================
CANON_DIR=$(new_sandbox)
printf 'mine\n' > "$CANON_DIR/CLAUDE.md"
run_install "$CANON_DIR" >/dev/null 2>&1
run_install "$CANON_DIR/" >/dev/null 2>&1
run_install "$CANON_DIR/./" >/dev/null 2>&1
chk "CANON1: installs through \$D, \$D/ and \$D/./ are ONE install: one triage hook, one pointer naming \$D" \
  '[ "$(triage_hooks "$CANON_DIR/settings.json")" -eq 1 ] && [ "$(grep -cF "reaches the main session" "$CANON_DIR/CLAUDE.md")" -eq 1 ] && grep -qxF "$(pointer_for "$CANON_DIR")" "$CANON_DIR/CLAUDE.md" && [ "$(jq -r "[.hooks.SessionStart[].hooks[].command] | join(\" \")" "$CANON_DIR/settings.json")" = "$(hook_cmd_for "$CANON_DIR")" ]'
run_uninstall "$CANON_DIR/" >/dev/null 2>&1
chk "CANON2: uninstall through \$D/ removes the hook and the pointer installed through \$D" \
  '[ "$(triage_hooks "$CANON_DIR/settings.json" 2>/dev/null || echo 0)" -eq 0 ] && [ "$(cat "$CANON_DIR/CLAUDE.md")" = mine ] && [ ! -e "$CANON_DIR/scripts/triage-context.sh" ]'
CANON_REL=$(new_sandbox)
CANON_REL_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $CANON_REL_OUT"
( cd "$CANON_REL" && CLAUDE_DIR=rel "$REPO_DIR/install.sh" ) >"$CANON_REL_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CANON_REL_RC=$?
( cd "$CANON_REL" && CLAUDE_DIR=rel "$REPO_DIR/uninstall.sh" ) >>"$CANON_REL_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CANON_REL_URC=$?
chk "CANON3: a relative CLAUDE_DIR is refused by install and uninstall (rc != 0), nothing created" \
  '[ "$CANON_REL_RC" -ne 0 ] && [ "$CANON_REL_URC" -ne 0 ] && [ ! -e "$CANON_REL/rel" ] && grep -q "must be an absolute path" "$CANON_REL_OUT"'

# =============================================================================
# Case DOWN — X2: env.CLAUDE_CODE_SUBAGENT_MODEL carries the ownership marker, but you
# repointed it to an OLD installer default (a downgrade). The marker no longer matches,
# so the value is yours: install never upgrades it back (dry-run, status and the real
# run agree) and drops the stale marker.
# =============================================================================
DOWN_DIR=$(new_sandbox)
echo '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5", "TRIAGE_LAYER_OWNS_SUBAGENT_MODEL": "'"$DEEP_MODEL"'"}}' > "$DOWN_DIR/settings.json"
DOWN_DRY=$(mktemp); DOWN_ST=$(mktemp)
ALL_TMP="$ALL_TMP $DOWN_DRY $DOWN_ST"
CLAUDE_DIR="$DOWN_DIR" "$REPO_DIR/install.sh" --dry-run >"$DOWN_DRY" 2>&1
CLAUDE_DIR="$DOWN_DIR" "$REPO_DIR/install.sh" --settings-status >"$DOWN_ST" 2>&1
chk "DOWN1: --dry-run and --settings-status leave a downgraded marked value alone (no 'would upgrade', no pending model migration)" \
  'grep -qF "env.CLAUDE_CODE_SUBAGENT_MODEL: already set to claude-opus-5" "$DOWN_DRY" && ! grep -q "would upgrade" "$DOWN_DRY" && ! grep -q "CLAUDE_CODE_SUBAGENT_MODEL" "$DOWN_ST"'
run_install "$DOWN_DIR" >/dev/null 2>&1
chk "DOWN2: install keeps the downgraded value and drops the stale marker (the value is yours now)" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$DOWN_DIR/settings.json")" = claude-opus-5 ] && [ "$(jq -r ".env | has(\"TRIAGE_LAYER_OWNS_SUBAGENT_MODEL\")" "$DOWN_DIR/settings.json")" = false ]'

# =============================================================================
# Case PTR — M9: the pointer line now tells the main session what to do when the hook
# did not run. An install that wrote the earlier (Wave 21) pointer has it replaced,
# with a backup, never duplicated; uninstall removes the earlier spelling too.
# =============================================================================
PTR_DIR=$(new_sandbox)
run_install "$PTR_DIR" >/dev/null 2>&1
printf 'mine\n%s\nalso mine\n' "$(old_pointer_for "$PTR_DIR")" > "$PTR_DIR/CLAUDE.md"
PTR_ST=$(mktemp); PTR_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $PTR_ST $PTR_OUT"
CLAUDE_DIR="$PTR_DIR" "$REPO_DIR/install.sh" --settings-status >"$PTR_ST" 2>&1
chk "PTR1: --settings-status reports the outdated pointer line as a pending migration" 'grep -q "outdated pointer line" "$PTR_ST"'
run_install "$PTR_DIR" >"$PTR_OUT" 2>&1
chk "PTR2: install replaces the outdated pointer with the current one, other lines in order, backed up first" \
  '[ "$(cat "$PTR_DIR/CLAUDE.md")" = "$(printf "mine\nalso mine\n%s" "$(pointer_for "$PTR_DIR")")" ] && grep -qxF "$(old_pointer_for "$PTR_DIR")" "$PTR_DIR"/CLAUDE.md.bak-triage-* && grep -q "replaced the outdated pointer line" "$PTR_OUT"'
chk "PTR3: the pointer tells the main session to read the rubric itself when it is not in context" \
  'grep -qF "if you are the main session and it is not in your context, read that file before planning" "$PTR_DIR/CLAUDE.md"'
printf '%s\n' "$(old_pointer_for "$PTR_DIR")" >> "$PTR_DIR/CLAUDE.md"
run_uninstall "$PTR_DIR" >/dev/null 2>&1
chk "PTR4: uninstall removes the current AND the earlier pointer line" '[ "$(cat "$PTR_DIR/CLAUDE.md")" = "$(printf "mine\nalso mine")" ]'

# =============================================================================
# Case NORM — L10/U1: ONE legacy-import normalisation (LEGACY_IMPORT_AWK, identical in
# install.sh, uninstall.sh and triage-context.sh). The other spellings of the import
# are migrated by install and removed by uninstall; a line with TWO trailing CRs is
# the import nowhere — the hook injects, and install leaves it (never "rubric loads
# nowhere").
# =============================================================================
NORM_DIR=$(new_sandbox)
printf 'mine\n@./triage.md\n@~/.claude/triage.md\n@%s/triage.md  \nend\n' "$NORM_DIR" > "$NORM_DIR/CLAUDE.md"
NORM_ST=$(mktemp)
ALL_TMP="$ALL_TMP $NORM_ST"
CLAUDE_DIR="$NORM_DIR" "$REPO_DIR/install.sh" --settings-status >"$NORM_ST" 2>&1
run_install "$NORM_DIR" >/dev/null 2>&1
chk "NORM1: @./triage.md, @~/.claude/triage.md and @<CLAUDE_DIR>/triage.md (trailing blanks) are reported and migrated" \
  'grep -q "legacy @triage.md import present" "$NORM_ST" && [ "$(cat "$NORM_DIR/CLAUDE.md")" = "$(printf "mine\nend\n%s" "$(pointer_for "$NORM_DIR")")" ]'
printf '@./triage.md\r\n' >> "$NORM_DIR/CLAUDE.md"
run_uninstall "$NORM_DIR" >/dev/null 2>&1
chk "NORM2: uninstall removes another spelling (CRLF) too" '[ "$(cat "$NORM_DIR/CLAUDE.md")" = "$(printf "mine\nend")" ]'
NORM2_DIR=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$NORM2_DIR/triage.md"
printf 'mine\n@triage.md\r\r\n' > "$NORM2_DIR/CLAUDE.md"
NORM2_ST=$(mktemp)
ALL_TMP="$ALL_TMP $NORM2_ST"
CLAUDE_DIR="$NORM2_DIR" "$REPO_DIR/install.sh" --settings-status >"$NORM2_ST" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
NORM2_HOOK=$(printf '{}' | CLAUDE_DIR="$NORM2_DIR" bash "$REPO_DIR/scripts/triage-context.sh" | jq -r '.hookSpecificOutput.additionalContext // ""' | head -c 200)
chk "NORM3: '@triage.md' + TWO CRs: install does not call it the import AND the hook injects the rubric (the same verdict, U1)" \
  '! grep -q "legacy @triage.md import present" "$NORM2_ST" && [ -n "$NORM2_HOOK" ]'
chk "NORM4: install.sh, uninstall.sh and triage-context.sh carry the identical LEGACY_IMPORT_AWK" \
  '[ -n "$(grep "^LEGACY_IMPORT_AWK=" "$REPO_DIR/install.sh")" ] && [ "$(grep "^LEGACY_IMPORT_AWK=" "$REPO_DIR/install.sh")" = "$(grep "^LEGACY_IMPORT_AWK=" "$REPO_DIR/uninstall.sh")" ] && [ "$(grep "^LEGACY_IMPORT_AWK=" "$REPO_DIR/install.sh")" = "$(grep "^LEGACY_IMPORT_AWK=" "$REPO_DIR/scripts/triage-context.sh")" ]'

# =============================================================================
# Case ORD — L4: uninstall writes settings.json first, then CLAUDE.md, then removes
# files. A settings write that fails leaves CLAUDE.md and every file in place; a
# CLAUDE.md write that fails (settings already written) still removes no file, so the
# hook is never left pointing at a removed triage-context.sh.
# =============================================================================
ORD_DIR=$(new_sandbox)
printf 'mine\n' > "$ORD_DIR/CLAUDE.md"
run_install "$ORD_DIR" >/dev/null 2>&1
mv "$ORD_DIR/settings.json" "$ORD_DIR/settings.real.json"
ln -s "$ORD_DIR/settings.real.json" "$ORD_DIR/settings.json"
chmod 444 "$ORD_DIR/settings.real.json"
cp "$ORD_DIR/CLAUDE.md" "$ORD_DIR/CLAUDE.md.before"
ORD_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $ORD_OUT"
run_uninstall "$ORD_DIR" >"$ORD_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
ORD_RC=$?
chk "ORD1: a settings.json write that fails stops uninstall before CLAUDE.md or any file is touched" \
  '[ "$ORD_RC" -ne 0 ] && ! grep -q "^Uninstalled" "$ORD_OUT" && cmp -s "$ORD_DIR/CLAUDE.md" "$ORD_DIR/CLAUDE.md.before" && [ -f "$ORD_DIR/scripts/triage-context.sh" ] && [ "$(triage_hooks "$ORD_DIR/settings.real.json")" -eq 1 ]'
chmod 644 "$ORD_DIR/settings.real.json"
mv "$ORD_DIR/CLAUDE.md" "$ORD_DIR/CLAUDE.real.md"
ln -s "$ORD_DIR/CLAUDE.real.md" "$ORD_DIR/CLAUDE.md"
chmod 444 "$ORD_DIR/CLAUDE.real.md"
run_uninstall "$ORD_DIR" >"$ORD_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
ORD2_RC=$?
chk "ORD2: settings written, then a CLAUDE.md write fails: rc != 0, the message says settings changed, NO file removed (the script stays while the pointer does)" \
  '[ "$ORD2_RC" -ne 0 ] && grep -q "settings.json was already updated" "$ORD_OUT" && [ "$(triage_hooks "$ORD_DIR/settings.real.json")" -eq 0 ] && [ -f "$ORD_DIR/scripts/triage-context.sh" ] && [ -f "$ORD_DIR/triage.md" ] && grep -qxF "$(pointer_for "$ORD_DIR")" "$ORD_DIR/CLAUDE.real.md"'
chmod 644 "$ORD_DIR/CLAUDE.real.md"
run_uninstall "$ORD_DIR" >"$ORD_OUT" 2>&1
chk "ORD3: once the write can succeed, a re-run completes the uninstall" \
  'grep -q "^Uninstalled" "$ORD_OUT" && [ "$(cat "$ORD_DIR/CLAUDE.real.md")" = mine ] && [ ! -e "$ORD_DIR/scripts/triage-context.sh" ]'

# =============================================================================
# Result
# =============================================================================
echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
