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
#       re-install (idempotency), uninstall (restore).
#   B - completely empty CLAUDE_DIR round-trip: null snapshot keys are
#       deleted, not written as null; no leftover `"permissions": {}`.
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
chk "A5: model set to opus[1m] after install" \
  '[ "$(jq -r ".model" "$A_DIR/settings.json")" = "opus[1m]" ]'
chk "A6: effortLevel set to high after install" \
  '[ "$(jq -r ".effortLevel" "$A_DIR/settings.json")" = "high" ]'
chk "A7: permissions.allow has 5 entries after install (1 pre-existing + 4 workers)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 5 ]'
chk "A8: pre-existing allow entry retained" \
  'jq -e ".permissions.allow | index(\"Bash(ls:*)\")" "$A_DIR/settings.json" >/dev/null'
chk "A9: preinstall snapshot captured original values" \
  '[ "$(jq -r ".model" "$A_DIR/triage-preinstall.json")" = "sonnet" ]'

# Re-install: idempotency
run_install "$A_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A_REINSTALL_RC=$?
chk "A10: re-install exits 0" '[ "$A_REINSTALL_RC" -eq 0 ]'
chk "A11: re-install does not duplicate @triage.md" \
  '[ "$(grep -cxF "@triage.md" "$A_DIR/CLAUDE.md")" -eq 1 ]'
chk "A12: re-install does not duplicate permissions.allow entries (still 5)" \
  '[ "$(jq ".permissions.allow | length" "$A_DIR/settings.json")" -eq 5 ]'

# Uninstall: restore
run_uninstall "$A_DIR" >/dev/null 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A_UNINSTALL_RC=$?
chk "A13: uninstall exits 0" '[ "$A_UNINSTALL_RC" -eq 0 ]'
chk "A14: model restored to pre-install value" \
  '[ "$(jq -r ".model" "$A_DIR/settings.json")" = "sonnet" ]'
chk "A15: statusLine restored to pre-install value" \
  '[ "$(jq -r ".statusLine.command" "$A_DIR/settings.json")" = "/old/statusline.sh" ]'
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
chk "B2: model key deleted (was null pre-install), not written as null" \
  '[ "$(jq "has(\"model\")" "$B_DIR/settings.json")" = "false" ]'
chk "B3: effortLevel key deleted" \
  '[ "$(jq "has(\"effortLevel\")" "$B_DIR/settings.json")" = "false" ]'
chk "B4: statusLine key deleted" \
  '[ "$(jq "has(\"statusLine\")" "$B_DIR/settings.json")" = "false" ]'
chk "B5: no leftover empty permissions object" \
  '[ "$(jq "has(\"permissions\")" "$B_DIR/settings.json")" = "false" ]'

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
  '[ "$(jq -r ".model" "$C_REAL")" = "opus[1m]" ]'

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
chk "F7: plan output mentions model key" 'grep -q "model:" "$F_OUT_FILE"'
chk "F8: plan output mentions effortLevel key" 'grep -q "effortLevel:" "$F_OUT_FILE"'
chk "F9: plan output mentions statusLine key" 'grep -q "statusLine:" "$F_OUT_FILE"'
chk "F10: plan output mentions the @triage.md append" 'grep -q "@triage.md" "$F_OUT_FILE"'

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
chk "G4: workflows/triage-run.js copied" '[ -f "$G_DIR/workflows/triage-run.js" ]'
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
chk "H3: old claude version warns about /triage-run classify loop" 'grep -q "classify stage can loop" "$H_OLD_OUT"'

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
# Statusline checks (direct, no install needed)
# =============================================================================
STATUSLINE="$REPO_DIR/statusline.sh"

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_NONNUMERIC=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":"n/a"}}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S1: statusline with non-numeric used_percentage does not crash and prints model only" \
  '[ "$STATUS_NONNUMERIC" = "Opus" ]'

# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATUS_NUMERIC=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.7}}' \
  | PATH=/usr/bin:/bin bash "$STATUSLINE")
chk "S2: statusline with used_percentage=42.7 prints 'Opus · ctx 42%'" \
  '[ "$STATUS_NUMERIC" = "Opus · ctx 42%" ]'

# =============================================================================
# Result
# =============================================================================
echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
