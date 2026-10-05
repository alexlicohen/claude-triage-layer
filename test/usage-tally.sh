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
TMP_ROOT=$(mktemp -d "$REPO_DIR/.usage-tally.XXXXXX") || exit 1

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

new_tmp() {
  t=$(mktemp "$TMP_ROOT/file.XXXXXX")
  printf '%s' "$t"
}

new_sandbox() {
  d=$(mktemp -d "$TMP_ROOT/dir.XXXXXX")
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
# Fixture 4b — pinned concrete ids (Wave 15: config/tiers.json pins Claude ids):
#   dated, versioned and [1m]-suffixed ids still tally by family substring.
# =============================================================================
PIN_DIR=$(new_sandbox)
mkdir -p "$PIN_DIR/subagents"
pin_agent() { # ID MODEL INPUT_TOKENS
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$2" "$3" > "$PIN_DIR/subagents/agent-$1.jsonl"
  printf '{"agentType":"triage-builder","description":"synthetic fixture: pinned id"}\n' > "$PIN_DIR/subagents/agent-$1.meta.json"
}
pin_agent p1 "claude-opus-5-5[1m]" 3000
pin_agent p2 "claude-haiku-4-5-20251001" 1000
pin_agent p3 "claude-fable-5-1" 2000
pin_agent p4 "claude-sonnet-5" 4000
pin_agent p5 "claude-opus-5-5" 5000
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
PIN_LINE=$("$SCRIPT" "$PIN_DIR" 2>&1 | head -n 1)
chk "4.3: pinned ids (claude-opus-5-5[1m], claude-haiku-4-5-20251001, claude-fable-5-1, claude-sonnet-5) tally by family, nothing under other" \
  '[ "$PIN_LINE" = "Usage: haiku 1k · sonnet 4k · opus 8k · fable 2k (orchestrator excluded; /usage for quota)" ]'

# =============================================================================
# Fixture 4c — workflow transcripts at several depths, including paths with spaces
# =============================================================================
WF_DIR="$(new_sandbox)/session with spaces"
mkdir -p "$WF_DIR/subagents/workflows/wf_x" "$WF_DIR/subagents/workflows/wf_x/nested"
wf_agent() { # DIRECTORY ID MODEL INPUT_TOKENS AGENT_TYPE
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$3" "$4" > "$1/agent-$2.jsonl"
  printf '{"agentType":"%s"}\n' "$5" > "$1/agent-$2.meta.json"
}
wf_agent "$WF_DIR/subagents/workflows/wf_x" w1 claude-sonnet-5 2000 workflow-builder
WF_OUT_FILE=$(new_tmp)
"$SCRIPT" -v "$WF_DIR/subagents" > "$WF_OUT_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
WF_RC=$?
chk "4.4: workflow-only subagents directory tallies transcript and sibling agentType" \
  '[ "$WF_RC" -eq 0 ] && grep -q "sonnet 2k" "$WF_OUT_FILE" && grep -qE "^w1[[:space:]]+workflow-builder[[:space:]]" "$WF_OUT_FILE"'

wf_agent "$WF_DIR/subagents" d1 claude-sonnet-5 5000 direct-builder
WF_MIX_FILE=$(new_tmp)
"$SCRIPT" -v "$WF_DIR" > "$WF_MIX_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
WF_MIX_RC=$?
chk "4.5: mixed direct and workflow transcripts sum both exactly once" \
  '[ "$WF_MIX_RC" -eq 0 ] && grep -q "sonnet 7k" "$WF_MIX_FILE" && grep -q "2 subagent(s) tallied" "$WF_MIX_FILE"'

wf_agent "$WF_DIR/subagents/workflows/wf_x/nested" n1 claude-haiku-4 3000 nested-builder
WF_NEST_FILE=$(new_tmp)
"$SCRIPT" -v "$WF_DIR" > "$WF_NEST_FILE" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
WF_NEST_RC=$?
chk "4.6: nested workflow transcript is found and counted once" \
  '[ "$WF_NEST_RC" -eq 0 ] && grep -q "haiku 3k · sonnet 7k" "$WF_NEST_FILE" && grep -q "3 subagent(s) tallied" "$WF_NEST_FILE"'

WF_EMPTY_DIR="$(new_sandbox)/empty session"
mkdir -p "$WF_EMPTY_DIR/subagents/workflows"
WF_EMPTY_ERR=$(new_tmp)
"$SCRIPT" "$WF_EMPTY_DIR" >/dev/null 2> "$WF_EMPTY_ERR"
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
WF_EMPTY_RC=$?
chk "4.7: empty workflows directory stays INCOMPLETE and names subagents dir" \
  '[ "$WF_EMPTY_RC" -eq 5 ] && grep -q "INCOMPLETE: no subagent transcripts under ${WF_EMPTY_DIR}/subagents" "$WF_EMPTY_ERR"'

# A project dir (sessions below it, workflow transcripts included) is NOT a subagents
# dir: its newest session transcript is used, never a sum over every session.
PD_DIR="$(new_sandbox)/proj"
mkdir -p "$PD_DIR/old/subagents/workflows/wf_o" "$PD_DIR/new/subagents/workflows/wf_n"
wf_agent "$PD_DIR/old/subagents/workflows/wf_o" o1 claude-opus-5-5 9000 old-deep
wf_agent "$PD_DIR/new/subagents/workflows/wf_n" n2 claude-sonnet-5 4000 new-builder
printf '{"type":"user"}\n' > "$PD_DIR/old.jsonl"
sleep 1
printf '{"type":"user"}\n' > "$PD_DIR/new.jsonl"
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
PD_OUT=$("$SCRIPT" "$PD_DIR" 2>&1)
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
PD_RC=$?
chk "4.8: a project dir uses its newest session (workflow transcripts found), not every session below it" \
  '[ "$PD_RC" -eq 0 ] && [ "$PD_OUT" = "Usage: haiku 0 · sonnet 4k · opus 0 · fable 0 (orchestrator excluded; /usage for quota)" ]'

# =============================================================================
# Fixture 4d (Wave 22, L16) — repeated message ids and a corrupt line
#   dd1: message m1 written on 3 lines (one per content block, same usage, out 100)
#        + message m2 (out 50) + an id-less record (out 7): CUM_OUT counts each
#        message ONCE (157), never per line (357).
#   cr1: a corrupt line BETWEEN two records: skipped with a warning; the record
#        after it still counts (peak 3000, not 1000).
# =============================================================================
DD_DIR=$(new_sandbox)
mkdir -p "$DD_DIR/subagents"
dd_line() { # ID MSGID IN OUT -> one assistant line (MSGID "-" = no id)
  if [ "$2" = "-" ]; then
    printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$3" "$4"
  else
    printf '{"type":"assistant","message":{"id":"%s","model":"claude-sonnet-5","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$2" "$3" "$4"
  fi
}
{ dd_line dd1 m1 1000 100; dd_line dd1 m1 1000 100; dd_line dd1 m1 1000 100; dd_line dd1 m2 2000 50; dd_line dd1 - 500 7; } > "$DD_DIR/subagents/agent-dd1.jsonl"
printf '{"agentType":"triage-builder"}\n' > "$DD_DIR/subagents/agent-dd1.meta.json"
DD_OUT=$(new_tmp); DD_ERR=$(new_tmp)
"$SCRIPT" -v "$DD_DIR" > "$DD_OUT" 2> "$DD_ERR"
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
DD_RC=$?
chk "6.1: a message repeated on several lines (same id) counts once: dd1 CUM_OUT 157, CUM_IN 3500; peak unchanged (2000)" \
  '[ "$DD_RC" -eq 0 ] && [ "$(awk '"'"'$1=="dd1"{print $4 "/" $5 "/" $6}'"'"' "$DD_OUT")" = "2000/157/3500" ]'

CR_DIR=$(new_sandbox)
mkdir -p "$CR_DIR/subagents"
{ dd_line cr1 c1 1000 10; printf '{"type":"assistant","message":{"model":TRUNCATED\n'; dd_line cr1 c2 3000 10; } > "$CR_DIR/subagents/agent-cr1.jsonl"
CR_OUT=$(new_tmp); CR_ERR=$(new_tmp)
"$SCRIPT" "$CR_DIR" > "$CR_OUT" 2> "$CR_ERR"
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
CR_RC=$?
chk "6.2: a corrupt line mid-transcript is skipped, not the end of the file: the later record counts (sonnet 3k), exit 0" \
  '[ "$CR_RC" -eq 0 ] && [ "$(head -n 1 "$CR_OUT")" = "Usage: haiku 0 · sonnet 3k · opus 0 · fable 0 (orchestrator excluded; /usage for quota)" ]'
chk "6.3: ...and it is warned about on stderr (count + file), never on the headline's stdout" \
  'grep -q "warning: skipped 1 unparseable line(s) in .*agent-cr1.jsonl" "$CR_ERR" && ! grep -q warning "$CR_OUT"'

# =============================================================================
# Fixture 7 (Wave 22, L7) — scripts/triage-stats.sh attributes WORKFLOW agents to
# their real session: sessions s1 and s2 each ran one triage-builder only inside a
# workflow, s3 one direct, s4 one in a nested workflow dir. 4 sessions — never the
# "workflows" dir (or a wf_* run id) standing in for a session (which counts 3).
# =============================================================================
STATS="$REPO_DIR/scripts/triage-stats.sh"
ST_DIR=$(new_sandbox)
st_agent() { # DIR ID
  mkdir -p "$1"
  printf '{"type":"assistant","timestamp":"2026-09-30T10:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$1/agent-$2.jsonl"
  printf '{"agentType":"triage-builder"}\n' > "$1/agent-$2.meta.json"
}
st_agent "$ST_DIR/s1/subagents/workflows/wf_a" w1
st_agent "$ST_DIR/s2/subagents/workflows/wf_b" w2
st_agent "$ST_DIR/s3/subagents" d3
st_agent "$ST_DIR/s4/subagents/workflows/wf_c/nested" w4
ST_OUT=$(new_tmp)
"$STATS" --project "$ST_DIR" --weeks 0 > "$ST_OUT" 2>&1
# shellcheck disable=SC2034  # used inside chk's eval'd condition string
ST_RC=$?
chk "7.1: triage-stats counts workflow agents under their own session (triage-builder: 4 sessions, 4 spawns)" \
  '[ "$ST_RC" -eq 0 ] && [ "$(awk '"'"'$1=="triage-builder"{print $2 "/" $3}'"'"' "$ST_OUT")" = "4/4" ]'

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
