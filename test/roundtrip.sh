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
#   Z - drift.sh warns "settings migration pending" for a legacy subagent model.
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
chk "A2: @triage.md appended on its own line" 'grep -qxF "@triage.md" "$A_DIR/CLAUDE.md"'
chk "A3: original CLAUDE.md content preserved as its own first line" \
  '[ "$(sed -n 1p "$A_DIR/CLAUDE.md")" = "existing global rules, no trailing newline" ]'
chk "A4: CLAUDE.md has exactly 2 lines (orig + @triage.md)" \
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
chk "A11: re-install does not duplicate @triage.md" \
  '[ "$(grep -cxF "@triage.md" "$A_DIR/CLAUDE.md")" -eq 1 ]'
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
chk "A18: @triage.md removed from CLAUDE.md on uninstall" \
  '! grep -qxF "@triage.md" "$A_DIR/CLAUDE.md"'

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
chk "D3: CLAUDE.md left byte-for-byte unmodified (no @triage.md appended)" \
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
chk "F10: plan output mentions the @triage.md append" 'grep -q "@triage.md" "$F_OUT_FILE"'
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
owned_lines() { grep -E '^(SUBAGENT_CACHE_TTL|OWNER_MARK)=' "$1" | sort; }
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_INSTALL_OWNED=$(owned_lines "$REPO_DIR/install.sh")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_UNINSTALL_OWNED=$(owned_lines "$REPO_DIR/uninstall.sh")
chk "N8: install.sh and uninstall.sh define identical SUBAGENT_CACHE_TTL / OWNER_MARK" \
  '[ "$(printf "%s\n" "$N_INSTALL_OWNED" | grep -c .)" -eq 2 ] && [ "$N_INSTALL_OWNED" = "$N_UNINSTALL_OWNED" ]'
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
chk "P4: the rest of the bare install still happened (agents, workflows, @triage.md wiring)" \
  '[ -f "$P_DIR/agents/triage-quick-task.md" ] && [ -f "$P_DIR/workflows/triage-compare.js" ] && grep -qxF "@triage.md" "$P_DIR/CLAUDE.md"'
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
  '[ "$W2_RC" -ne 0 ] && ! grep -q "^Uninstalled" "$W2_OUT" && [ -f "$W2_DIR/agents/triage-builder.md" ] && grep -qxF "@triage.md" "$W2_DIR/CLAUDE.md"'
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
# Result
# =============================================================================
echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
