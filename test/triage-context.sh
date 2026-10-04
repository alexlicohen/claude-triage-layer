#!/bin/bash
# Tests for scripts/triage-context.sh, the SessionStart hook that delivers triage.md
# to the main session. Every case runs against its own sandbox CLAUDE_DIR; the real
# ~/.claude is never read or written. Fail-loud: every check prints PASS/FAIL.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CTX="$REPO_DIR/scripts/triage-context.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "INCOMPLETE: jq is required to run this suite (brew install jq)" >&2
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
new_sandbox() { local d; d=$(mktemp -d); ALL_TMP="$ALL_TMP $d"; printf '%s' "$d"; }
chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

# run_hook DIR STDIN OUTFILE -> rc in $HOOK_RC (hook mode, CLAUDE_DIR=DIR)
run_hook() {
  printf '%s' "$2" | CLAUDE_DIR="$1" bash "$CTX" >"$3" 2>"$3.err"
  HOOK_RC=$?
}
# context OUTFILE -> the additionalContext string, byte-exact, to stdout
context() { jq -j '.hookSpecificOutput.additionalContext' "$1"; }
# A file of exactly N bytes (ASCII, ending in a newline).
make_file() { # $1 = path, $2 = bytes
  head -c $(($2 - 1)) /dev/zero | tr '\0' 'x' > "$1"
  printf '\n' >> "$1"
}

START='{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}'

# --- 1. the happy path: exact content after the label ---------------------------
D1=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$D1/triage.md"
O1="$D1/out.json"
run_hook "$D1" "$START" "$O1"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings
RC1=$HOOK_RC
chk "C1: hook exits 0 and prints valid JSON" '[ "$RC1" -eq 0 ] && jq -e . "$O1" >/dev/null'
chk "C2: hookEventName is SessionStart" '[ "$(jq -r ".hookSpecificOutput.hookEventName" "$O1")" = "SessionStart" ]'
context "$O1" > "$D1/ctx.txt"
chk "C3: the first line is the label naming ~/.claude/triage.md and the SessionStart hook" \
  'head -n 1 "$D1/ctx.txt" | grep -qF "This is ~/.claude/triage.md" && head -n 1 "$D1/ctx.txt" | grep -qF "SessionStart hook" && [ -z "$(sed -n 2p "$D1/ctx.txt")" ]'
tail -n +3 "$D1/ctx.txt" > "$D1/body.txt"
chk "C4: everything after the label + blank line is triage.md byte-for-byte (UTF-8 intact)" 'cmp -s "$D1/body.txt" "$REPO_DIR/triage.md"'
O1B="$D1/out-b.json"
run_hook "$D1" "" "$O1B"
chk "C5: empty stdin still injects (input is optional)" 'context "$O1B" | tail -n +3 | cmp -s - "$REPO_DIR/triage.md"'
run_hook "$D1" "not json at all" "$O1B"
chk "C6: non-JSON stdin still injects" 'context "$O1B" | tail -n +3 | cmp -s - "$REPO_DIR/triage.md"'
D1T=$(new_sandbox)
O1T="$D1T/out.json"
printf 'custom rubric\n' > "$D1T/alt.md"
printf '%s' "$START" | TRIAGE_MD="$D1T/alt.md" CLAUDE_DIR="$D1T" bash "$CTX" >"$O1T" 2>/dev/null
chk "C7: TRIAGE_MD overrides the file read" 'context "$O1T" | tail -n +3 | cmp -s - "$D1T/alt.md"'

# --- 2. silent cases ---------------------------------------------------------------
D2=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$D2/triage.md"
touch "$D2/triage.disabled"
O2="$D2/out.json"
run_hook "$D2" "$START" "$O2"
# shellcheck disable=SC2034
RC2=$HOOK_RC
chk "K1: kill switch (triage.disabled) -> no output, exit 0" '[ "$RC2" -eq 0 ] && [ ! -s "$O2" ]'

D3=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$D3/triage.md"
printf 'my rules\n@triage.md\n' > "$D3/CLAUDE.md"
O3="$D3/out.json"
run_hook "$D3" "$START" "$O3"
# shellcheck disable=SC2034
RC3=$HOOK_RC
chk "L1: legacy @triage.md import line in CLAUDE.md -> no output (no double load), exit 0" '[ "$RC3" -eq 0 ] && [ ! -s "$O3" ]'
printf 'my rules\n@triage.md.old\n  @triage.md\nThe triage routing rubric (~/.claude/triage.md) reaches the main session through a SessionStart hook; subagents don'"'"'t receive it.\n' > "$D3/CLAUDE.md"
run_hook "$D3" "$START" "$O3"
chk "L2: only the EXACT line counts (a pointer line or a near-miss still injects)" \
  'context "$O3" | tail -n +3 | cmp -s - "$REPO_DIR/triage.md"'
printf 'my rules\r\n@triage.md\r\n' > "$D3/CLAUDE.md"
run_hook "$D3" "$START" "$O3"
# shellcheck disable=SC2034
RC3C=$HOOK_RC
chk "L3: a CRLF legacy import line also counts (no output, exit 0)" '[ "$RC3C" -eq 0 ] && [ ! -s "$O3" ]'

D4=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$D4/triage.md"
O4="$D4/out.json"
run_hook "$D4" '{"session_id":"s1","agent_id":"a-123","agent_type":"triage-builder","hook_event_name":"SessionStart"}' "$O4"
# shellcheck disable=SC2034
RC4=$HOOK_RC
chk "A1: agent_id on stdin -> no output (never inject into a subagent), exit 0" '[ "$RC4" -eq 0 ] && [ ! -s "$O4" ]'
run_hook "$D4" '{"session_id":"s1","agent_id":null}' "$O4"
chk "A2: a null agent_id is not a subagent (injects)" 'context "$O4" | tail -n +3 | cmp -s - "$REPO_DIR/triage.md"'

# --- 3. notices, never silent failures -----------------------------------------------
D5=$(new_sandbox)
O5="$D5/out.json"
run_hook "$D5" "$START" "$O5"
# shellcheck disable=SC2034
RC5=$HOOK_RC
chk "N1: missing triage.md -> a JSON notice saying so, exit 0" \
  '[ "$RC5" -eq 0 ] && jq -e . "$O5" >/dev/null && context "$O5" | grep -q "was not found" && context "$O5" | grep -qF "$D5/triage.md"'

# Label overhead (label + blank line) in bytes, measured from a 1-byte file.
D6=$(new_sandbox)
printf '\n' > "$D6/triage.md"
run_hook "$D6" "$START" "$D6/out.json"
OVERHEAD=$(( $(context "$D6/out.json" | wc -c | tr -d ' ') - 1 ))
make_file "$D6/triage.md" $((10000 - OVERHEAD))
run_hook "$D6" "$START" "$D6/out.json"
chk "N2: label + file of exactly 10,000 bytes is injected whole" \
  '[ "$(context "$D6/out.json" | wc -c | tr -d " ")" -eq 10000 ] && context "$D6/out.json" | tail -n +3 | cmp -s - "$D6/triage.md"'
make_file "$D6/triage.md" $((10001 - OVERHEAD))
run_hook "$D6" "$START" "$D6/out.json"
# shellcheck disable=SC2034
RC6=$HOOK_RC
chk "N3: one byte over the cap -> a short notice (not the file), exit 0" \
  '[ "$RC6" -eq 0 ] && context "$D6/out.json" | grep -q "over the 10000-char hook cap" && [ "$(context "$D6/out.json" | wc -c | tr -d " ")" -lt 1000 ]'

# jq absent -> a plain-text notice (SessionStart stdout is context too), exit 0.
D7=$(new_sandbox)
cp "$REPO_DIR/triage.md" "$D7/triage.md"
mkdir -p "$D7/bin"
for t in cat grep wc tr head; do ln -s "$(command -v "$t")" "$D7/bin/$t"; done
printf '%s' "$START" | PATH="$D7/bin" CLAUDE_DIR="$D7" "$(command -v bash)" "$CTX" >"$D7/out.txt" 2>&1
# shellcheck disable=SC2034
RC7=$?
chk "N4: without jq the hook prints a plain notice naming jq, exit 0" '[ "$RC7" -eq 0 ] && grep -q "jq is not installed" "$D7/out.txt"'

# --- 4. --check ---------------------------------------------------------------------
"$CTX" --check "$REPO_DIR/triage.md" >/dev/null 2>&1
# shellcheck disable=SC2034
RC8=$?
chk "X1: --check on the repo triage.md exits 0" '[ "$RC8" -eq 0 ]'
make_file "$D6/fits.md" $((10000 - OVERHEAD))
"$CTX" --check "$D6/fits.md" >/dev/null 2>&1
# shellcheck disable=SC2034
RC9=$?
chk "X2: --check at exactly the cap exits 0" '[ "$RC9" -eq 0 ]'
make_file "$D6/big.md" $((10001 - OVERHEAD))
"$CTX" --check "$D6/big.md" >/dev/null 2>&1
# shellcheck disable=SC2034
RC10=$?
chk "X3: --check one byte over the cap exits 1" '[ "$RC10" -eq 1 ]'
"$CTX" --check "$D6/nope.md" >/dev/null 2>&1
# shellcheck disable=SC2034
RC11=$?
chk "X4: --check on a missing file exits 2" '[ "$RC11" -eq 2 ]'
"$CTX" --check >/dev/null 2>&1
# shellcheck disable=SC2034
RC12=$?
chk "X5: --check with no file exits 2" '[ "$RC12" -eq 2 ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
