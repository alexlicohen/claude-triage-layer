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
#   Plus two direct statusline.sh checks (non-numeric / numeric pct).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- prerequisite check: fail loud, never silently skip ---------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "INCOMPLETE: jq is required to run this suite (brew install jq) — cannot verify settings.json merges." >&2
  exit 1
fi

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
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$A_DIR/settings.json")" = "claude-opus-5" ]'
chk "A6d: subagentPromptCacheTtl set (was unset)" \
  '[ "$(jq -r ".subagentPromptCacheTtl" "$A_DIR/settings.json")" = "1h" ]'
chk "A7: permissions.allow has 6 entries after install (1 pre-existing + 5 workers)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 6 ]'
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
chk "A12: re-install does not duplicate permissions.allow entries (still 6)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 6 ]'

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
  '[ "$(jq -r ".env.CLAUDE_CODE_SUBAGENT_MODEL" "$C_REAL")" = "claude-opus-5" ]'

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
# Case I — uninstall must remove only the six shipped agents by name, never
# a user-authored triage-*.md agent (a glob-based revert would delete it)
# =============================================================================
I_DIR=$(new_sandbox)
mkdir -p "$I_DIR/agents"

run_install "$I_DIR" >/dev/null 2>&1
printf 'my own agent, not shipped by this repo\n' > "$I_DIR/agents/triage-mine.md"

run_uninstall "$I_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
I_RC=$?
chk "I1: uninstall exits 0" '[ "$I_RC" -eq 0 ]'
chk "I2: user-authored triage-mine.md survives uninstall" '[ -f "$I_DIR/agents/triage-mine.md" ]'
chk "I3: all six shipped agents removed" \
  '[ ! -f "$I_DIR/agents/triage-quick-task.md" ] && [ ! -f "$I_DIR/agents/triage-builder.md" ] && [ ! -f "$I_DIR/agents/triage-deep-reasoner.md" ] && [ ! -f "$I_DIR/agents/triage-reviewer.md" ] && [ ! -f "$I_DIR/agents/triage-cross-reviewer.md" ] && [ ! -f "$I_DIR/agents/triage-fable-architect.md" ]'

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

rm -f "$J_DIR/scripts/triage-usage.sh"

J_MISSING_OUT=$(mktemp)
ALL_TMP="$ALL_TMP $J_MISSING_OUT"
CLAUDE_DIR="$J_DIR" "$REPO_DIR/drift.sh" >"$J_MISSING_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
J_MISSING_RC=$?
chk "J3: drift.sh reports MISSING for the deleted checked file" \
  'grep -q "MISSING (not installed): scripts/triage-usage.sh" "$J_MISSING_OUT"'
chk "J4: drift.sh exits non-zero once a checked file is missing" '[ "$J_MISSING_RC" -ne 0 ]'

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
# Result
# =============================================================================
echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
