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
#   G - install.sh --files-only with a driftignored, differing triage.md:
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
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$A_DIR/settings.json")" = "claude-opus-5-5" ]'
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
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$C_REAL")" = "claude-opus-5-5" ]'

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
# Case G — install.sh --files-only skips a driftignored, differing fork
# (repo's own .driftignore already lists triage.md — see .driftignore)
# =============================================================================
G_DIR=$(new_sandbox)
mkdir -p "$G_DIR"
printf 'my personal triage.md fork\n' > "$G_DIR/triage.md"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
G_TRIAGE_BEFORE=$(cat "$G_DIR/triage.md")

G_OUT_FILE=$(mktemp)
ALL_TMP="$ALL_TMP $G_OUT_FILE"
CLAUDE_DIR="$G_DIR" "$REPO_DIR/install.sh" --files-only >"$G_OUT_FILE" 2>&1
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
chk "G8: no .bak-triage backup created for the skipped fork" '[ ! -f "$G_DIR/triage.md.bak-triage" ]'
chk "G9: CLAUDE.md not created (files-only leaves it alone)" '[ ! -f "$G_DIR/CLAUDE.md" ]'
chk "G10: settings.json not created (files-only leaves it alone)" '[ ! -f "$G_DIR/settings.json" ]'
chk "G11: scripts/ext-run.sh copied and executable" '[ -x "$G_DIR/scripts/ext-run.sh" ]'
chk "G12: config/tiers.json installed as scripts/triage-tiers.json (byte-identical)" \
  'cmp -s "$REPO_DIR/config/tiers.json" "$G_DIR/scripts/triage-tiers.json"'
chk "G13: scripts/triage-tiers.sh copied and executable" '[ -x "$G_DIR/scripts/triage-tiers.sh" ]'
chk "G14: the installed triage-tiers.sh reads the installed tiers file next to it, not the repo copy" \
  '"$G_DIR/scripts/triage-tiers.sh" | grep -q "tiers: $G_DIR/scripts/triage-tiers.json"'

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
rm -f "$J_DIR/scripts/triage-usage.sh" "$J_DIR/scripts/ext-run.sh" "$J_DIR/scripts/triage-tiers.json"

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
  'grep -qF "env.CLAUDE_CODE_SUBAGENT_MODEL: would upgrade claude-opus-5 -> claude-opus-5-5" "$N_DRY_OUT"'
chk "N2: that --dry-run still writes nothing" \
  '[ "$(cat "$N_DIR/settings.json")" = "$N_SETTINGS_BEFORE" ]'

N_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $N_OUT"
CLAUDE_DIR="$N_DIR" "$REPO_DIR/install.sh" >"$N_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_RC=$?
chk "N3: install exits 0 over a previous installer default" '[ "$N_RC" -eq 0 ]'
chk "N4: a previous installer default (claude-opus-5) is upgraded to claude-opus-5-5" \
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$N_DIR/settings.json")" = "claude-opus-5-5" ]'
chk "N5: the upgrade is announced" \
  'grep -qF "upgraded claude-opus-5 -> claude-opus-5-5" "$N_OUT"'
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

# Uninstall straight over an OLD install's settings (no re-install in between).
N7_DIR=$(new_sandbox)
mkdir -p "$N7_DIR"
echo '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-opus-5"}, "subagentPromptCacheTtl": "1h"}' > "$N7_DIR/settings.json"
run_uninstall "$N7_DIR" >/dev/null 2>&1
chk "N7: uninstall removes a previous installer default (and the env object it empties)" \
  '[ "$(jq "has(\"env\")" "$N7_DIR/settings.json")" = "false" ]'

# install.sh and uninstall.sh each define the owned values; they must agree exactly.
owned_lines() { grep -E '^(SUBAGENT_MODEL|SUBAGENT_CACHE_TTL|LEGACY_SUBAGENT_MODELS)=' "$1" | sort; }
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_INSTALL_OWNED=$(owned_lines "$REPO_DIR/install.sh")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
N_UNINSTALL_OWNED=$(owned_lines "$REPO_DIR/uninstall.sh")
chk "N8: install.sh and uninstall.sh define identical SUBAGENT_MODEL / SUBAGENT_CACHE_TTL / LEGACY_SUBAGENT_MODELS" \
  '[ "$(printf "%s\n" "$N_INSTALL_OWNED" | grep -c .)" -eq 3 ] && [ "$N_INSTALL_OWNED" = "$N_UNINSTALL_OWNED" ]'

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
  'grep -qF "remove (renamed to agents/triage-external.md)" "$O_DRY_OUT" && grep -qF "would remove legacy: Agent(triage-overflow)" "$O_DRY_OUT" && grep -qF "would add: Agent(triage-external)" "$O_DRY_OUT" && [ -f "$O_DIR/agents/triage-overflow.md" ]'

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
