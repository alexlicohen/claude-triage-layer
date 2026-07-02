#!/bin/bash
# Test suite for scripts/triage-usage.sh — the per-tier token-usage tally.
#
# All fixtures under test/fixtures/usage/ are synthetic: fabricated agent ids,
# model ids, and token counts. Zero real transcript content.
#
# Same conventions as test/roundtrip.sh: set -u, chk-style accumulate-all-
# failures, per-check PASS/FAIL, final RESULT line, non-zero exit on any
# failure. BSD-safe (developed/run on macOS bash 3.2 + jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/triage-usage.sh"
FIX="$REPO_DIR/test/fixtures/usage"

if ! command -v jq >/dev/null 2>&1; then
  echo "INCOMPLETE: jq is required to run this suite (brew install jq) — triage-usage.sh needs it too." >&2
  exit 1
fi

[ -x "$SCRIPT" ] || { echo "INCOMPLETE: $SCRIPT not found or not executable" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
ALL_TMP=""

cleanup() {
  # shellcheck disable=SC2086
  [ -n "$ALL_TMP" ] && rm -rf $ALL_TMP
}
trap cleanup EXIT

new_tmp() {
  t=$(mktemp)
  ALL_TMP="$ALL_TMP $t"
  printf '%s' "$t"
}

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

# =============================================================================
# Fixture 1 — three model families, multi-turn, peak != last (three-family/)
#   a1-haiku: single turn, peak 2000
#   a2-sonnet: 3 turns summing 10000/50000/30000 -> peak is the MIDDLE turn
#              (50000), proving max-over-turns, not sum (90000) or last (30000)
#   a3-fable: 2 turns, peak (6000) is the FIRST turn, not the last (1200)
# =============================================================================
TF_OUT_FILE=$(new_tmp)
"$SCRIPT" "$FIX/three-family" > "$TF_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
TF_RC=$?
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
TF_LINE=$(head -n 1 "$TF_OUT_FILE")

chk "1.1: headline run exits 0" '[ "$TF_RC" -eq 0 ]'
chk "1.2: exact headline line (haiku 2k, sonnet 50k, opus 0, fable 6k)" \
  '[ "$TF_LINE" = "Usage: haiku 2k · sonnet 50k · opus 0 · fable 6k (orchestrator excluded; /usage for quota)" ]'

TFV_OUT_FILE=$(new_tmp)
"$SCRIPT" -v "$FIX/three-family" > "$TFV_OUT_FILE" 2>&1

# 1.3 peak-vs-sum: a2-sonnet's PEAK_CTX column must be 50000, never 90000 (sum) or 30000 (last turn)
A2_PEAK=$(awk '$1=="a2-sonnet"{print $4}' "$TFV_OUT_FILE")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A2_PEAK_VAL="${A2_PEAK:-}"
chk "1.3: a2-sonnet PEAK_CTX is 50000 (peak-of-turns), not 90000 (sum) or 30000 (last)" \
  '[ "$A2_PEAK_VAL" = "50000" ]'

# 1.4 peak-not-last on a3-fable too: PEAK_CTX must be 6000 (first turn), not 1200 (last turn)
A3_PEAK=$(awk '$1=="a3-fable"{print $4}' "$TFV_OUT_FILE")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
A3_PEAK_VAL="${A3_PEAK:-}"
chk "1.4: a3-fable PEAK_CTX is 6000 (first-turn peak), not 1200 (last turn)" \
  '[ "$A3_PEAK_VAL" = "6000" ]'

# 1.5/1.6 -v breakdown row count and TOTAL
DATA_ROWS=$(grep -cE '^(a1-haiku|a2-sonnet|a3-fable)[[:space:]]' "$TFV_OUT_FILE")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
DATA_ROWS_VAL="$DATA_ROWS"
chk "1.5: -v breakdown has exactly 3 agent rows" '[ "$DATA_ROWS_VAL" -eq 3 ]'

TOTAL_VAL=$(awk '$1=="TOTAL"{print $2}' "$TFV_OUT_FILE")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
TOTAL_VAL_CHK="${TOTAL_VAL:-}"
chk "1.6: -v TOTAL row is 58000 (2000+50000+0+6000)" '[ "$TOTAL_VAL_CHK" = "58000" ]'

# =============================================================================
# Fixture 2 — missing agent-<id>.meta.json (missing-meta/)
#   Documented degraded behaviour per scripts/triage-usage.sh: atype falls
#   back to "unknown" and the agent is still tallied normally (not skipped,
#   not treated as unparseable).
# =============================================================================
MM_OUT_FILE=$(new_tmp)
"$SCRIPT" -v "$FIX/missing-meta" > "$MM_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
MM_RC=$?
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
MM_LINE=$(head -n 1 "$MM_OUT_FILE")

chk "2.1: missing-meta run exits 0 (missing meta.json is not a hard failure)" '[ "$MM_RC" -eq 0 ]'
chk "2.2: missing-meta headline is sonnet 5k, others 0" \
  '[ "$MM_LINE" = "Usage: haiku 0 · sonnet 5k · opus 0 · fable 0 (orchestrator excluded; /usage for quota)" ]'
B1_TIER=$(awk '$1=="b1"{print $2}' "$MM_OUT_FILE")
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
B1_TIER_VAL="${B1_TIER:-}"
chk "2.3: -v TIER column for b1 (no meta.json) reads 'unknown'" '[ "$B1_TIER_VAL" = "unknown" ]'

# =============================================================================
# Fixture 3 — orchestrator-only session (no subagents/ dir) -> INCOMPLETE, exit 5
# =============================================================================
OO_ERR_FILE=$(new_tmp)
"$SCRIPT" "$FIX/orchestrator-only/sess-orch-only.jsonl" >/dev/null 2>"$OO_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
OO_RC=$?
chk "3.1: orchestrator-only (no subagents/) exits 5 (EX_INCOMPLETE)" '[ "$OO_RC" -eq 5 ]'
chk "3.2: orchestrator-only stderr is non-empty and says INCOMPLETE" \
  '[ -s "$OO_ERR_FILE" ] && grep -q "INCOMPLETE" "$OO_ERR_FILE"'

# =============================================================================
# Fixture 4 — unknown model id -> grouped under `other`
# =============================================================================
OM_OUT_FILE=$(new_tmp)
"$SCRIPT" "$FIX/other-model" > "$OM_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
OM_RC=$?
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
OM_LINE=$(head -n 1 "$OM_OUT_FILE")
chk "4.1: other-model run exits 0" '[ "$OM_RC" -eq 0 ]'
chk "4.2: unknown model id (claude-unicorn-9) is grouped under other, headline shows 'other 1k'" \
  '[ "$OM_LINE" = "Usage: haiku 0 · sonnet 0 · opus 0 · fable 0 · other 1k (orchestrator excluded; /usage for quota)" ]'

# =============================================================================
# Exit-code / fail-loud coverage — every distinct exit code the script defines
# =============================================================================

# EX_NOTFOUND=2: path does not exist
NF_ERR_FILE=$(new_tmp)
"$SCRIPT" "$FIX/does-not-exist-xyz" >/dev/null 2>"$NF_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
NF_RC=$?
chk "5.1: nonexistent path exits 2 (EX_NOTFOUND)" '[ "$NF_RC" -eq 2 ]'
chk "5.2: nonexistent path stderr is non-empty" '[ -s "$NF_ERR_FILE" ]'

# EX_EMPTY=4: transcript file exists but is empty
EM_ERR_FILE=$(new_tmp)
"$SCRIPT" "$FIX/empty-transcript/empty.jsonl" >/dev/null 2>"$EM_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
EM_RC=$?
chk "5.3: empty transcript file exits 4 (EX_EMPTY)" '[ "$EM_RC" -eq 4 ]'
chk "5.4: empty transcript stderr is non-empty" '[ -s "$EM_ERR_FILE" ]'

# EX_USAGE=1: non-.jsonl file given as PATH
NJ_ERR_FILE=$(new_tmp)
"$SCRIPT" "$FIX/not-a-transcript.txt" >/dev/null 2>"$NJ_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
NJ_RC=$?
chk "5.5: non-.jsonl PATH exits 1 (EX_USAGE)" '[ "$NJ_RC" -eq 1 ]'
chk "5.6: non-.jsonl PATH stderr is non-empty" '[ -s "$NJ_ERR_FILE" ]'

# EX_USAGE=1: unknown flag
BF_ERR_FILE=$(new_tmp)
"$SCRIPT" -x >/dev/null 2>"$BF_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
BF_RC=$?
chk "5.7: unknown flag exits 1 (EX_USAGE)" '[ "$BF_RC" -eq 1 ]'
chk "5.8: unknown flag stderr is non-empty" '[ -s "$BF_ERR_FILE" ]'

# EX_INCOMPLETE=5: no subagent transcripts at all (already covered by fixture 3,
# 3.1/3.2 above — re-asserted here for completeness of the exit-code matrix).
chk "5.9: no-subagents INCOMPLETE exits 5 (EX_INCOMPLETE, same case as 3.1)" '[ "$OO_RC" -eq 5 ]'

# EX_NOPROJ=3: default-PATH resolution fails (no ~/.claude/projects/<slug>).
# Sandboxed via HOME override — never touches the real ~/.claude.
NOPROJ_HOME=$(new_sandbox)
NP_ERR_FILE=$(new_tmp)
HOME="$NOPROJ_HOME" "$SCRIPT" >/dev/null 2>"$NP_ERR_FILE"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
NP_RC=$?
chk "5.10: unresolvable default project dir exits 3 (EX_NOPROJ)" '[ "$NP_RC" -eq 3 ]'
chk "5.11: unresolvable default stderr is non-empty" '[ -s "$NP_ERR_FILE" ]'

# =============================================================================
# Result
# =============================================================================
echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
