#!/usr/bin/env bash
#
# triage-usage.sh — deterministic per-tier token-usage tally for the model-triage layer.
#
# WHAT IT DOES
#   Replaces the orchestrator "eyeballing" per-subagent token counts and summing them
#   from memory (see triage.md § Usage tally). Reads the on-disk Claude Code subagent
#   transcripts for a session and prints ONE rubric line:
#     Usage: haiku Nk · sonnet Nk · opus Nk · fable Nk (orchestrator excluded; /usage for quota)
#   With -v it also prints a per-agent breakdown table.
#
# WHAT IT READS  (read-only; never prints message content — counts only)
#   Claude Code writes each spawned subagent's full transcript to a sibling directory of
#   the main session transcript:
#     ~/.claude/projects/<slug>/<session-id>.jsonl              <- orchestrator (EXCLUDED)
#     ~/.claude/projects/<slug>/<session-id>/subagents/
#         agent-<agentId>.jsonl                                 <- one subagent transcript
#         agent-<agentId>.meta.json                             <- {agentType, description, ...}
#   Each subagent transcript's assistant lines carry .message.model and
#   .message.usage {input_tokens, output_tokens, cache_creation_input_tokens,
#   cache_read_input_tokens}. The orchestrator's own turns live only in the main
#   <session-id>.jsonl and are therefore never counted here ("orchestrator excluded").
#
# WHAT IT COUNTS  (see scripts/README.md for the full rationale + limits)
#   Per subagent: the PEAK context it reached =
#       max over assistant turns of (input + cache_creation + cache_read).
#   This equals the token figure Claude Code displays per subagent (the context-window
#   occupancy at the run's high-water mark) — verified against two known runs in this
#   repo's dev session: a Fable code-review reached 64917 (~66k) and an Opus run reached
#   98443 (~98k). It is a relative per-tier cost proxy, NOT authoritative billing
#   (cache reads are counted because they are part of the context; use /usage for quota).
#   Each subagent's peak is attributed to the model family of its peak turn, then summed
#   per family. agentType (tier) is shown in the -v breakdown for readability.
#
# FAIL-LOUD
#   Missing/unreadable input -> explicit error + non-zero exit; NEVER silent zeros.
#   No subagent transcripts (or all unparseable) -> INCOMPLETE + non-zero exit, not "0k".
#   A tier legitimately at 0 (no subagent of that model spawned) IS reported as 0 — that
#   is a real measurement, distinct from the INCOMPLETE case above.
#
# PORTABILITY: bash 3.2 (macOS default) + jq only. No GNU-only flags, no associative
#   arrays, no `stat -c`/`readlink -f`/`sort -h`.

set -u

PROG="$(basename "$0")"

# ---- exit codes ------------------------------------------------------------
EX_OK=0        # success
EX_USAGE=1     # bad invocation
EX_NOTFOUND=2  # given path does not exist
EX_NOPROJ=3    # default project dir could not be resolved
EX_EMPTY=4     # transcript empty / unreadable
EX_INCOMPLETE=5 # no subagent usage found (or all unparseable)
EX_NOJQ=6      # jq not installed

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "$2"; }

usage() {
  cat >&2 <<EOF
$PROG — deterministic per-tier token tally for the triage layer (read-only).

Usage: $PROG [-v] [PATH]

  PATH   One of:
           - a session transcript .jsonl file, OR
           - a session directory (the one containing subagents/), OR
           - a subagents/ directory, OR
           - a project directory (newest *.jsonl in it is used).
         If omitted, uses the newest *.jsonl in
           ~/.claude/projects/<slug-of-\$PWD>.

  -v     Also print a per-agent breakdown table.
  -h     Show this help.

Output (stdout):
  Usage: haiku Nk · sonnet Nk · opus Nk · fable Nk (orchestrator excluded; /usage for quota)
EOF
}

VERBOSE=0
while getopts ":vh" opt; do
  case "$opt" in
    v) VERBOSE=1 ;;
    h) usage; exit "$EX_OK" ;;
    \?) die "unknown option: -$OPTARG (use -h)" "$EX_USAGE" ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -le 1 ] || die "too many arguments (use -h)" "$EX_USAGE"
ARG="${1:-}"

command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH" "$EX_NOJQ"

# ---- resolve the subagents directory --------------------------------------
# slug(): reproduce Claude Code's project-dir slug: every non-alphanumeric char in the
# absolute cwd becomes '-'. e.g. /Users/alex/projects/self-improvement ->
# -Users-alex-projects-self-improvement
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# newest_jsonl DIR -> path of most recently modified *.jsonl directly in DIR (BSD ls -t)
newest_jsonl() {
  local d="$1" f
  f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n 1)
  [ -n "$f" ] && printf '%s' "$f"
}

# subdir_from_main MAIN.jsonl -> the subagents dir for that transcript
subdir_from_main() { printf '%s' "${1%.jsonl}/subagents"; }

SUBDIR=""
SRC_DESC=""

if [ -z "$ARG" ]; then
  # default: newest transcript in this cwd's project dir
  proj="$HOME/.claude/projects/$(slug "$PWD")"
  [ -d "$proj" ] || die "no Claude project dir for this cwd: $proj (pass a PATH)" "$EX_NOPROJ"
  main="$(newest_jsonl "$proj")"
  [ -n "$main" ] || die "no *.jsonl transcripts in $proj" "$EX_NOPROJ"
  [ -s "$main" ] || die "transcript is empty or unreadable: $main" "$EX_EMPTY"
  SUBDIR="$(subdir_from_main "$main")"
  SRC_DESC="$main"
elif [ -f "$ARG" ]; then
  case "$ARG" in
    *.jsonl) : ;;
    *) die "not a .jsonl transcript: $ARG" "$EX_USAGE" ;;
  esac
  [ -s "$ARG" ] || die "transcript is empty or unreadable: $ARG" "$EX_EMPTY"
  SUBDIR="$(subdir_from_main "$ARG")"
  SRC_DESC="$ARG"
elif [ -d "$ARG" ]; then
  ARG="${ARG%/}"
  if [ -d "$ARG/subagents" ]; then
    SUBDIR="$ARG/subagents"                 # a session dir
  elif ls "$ARG"/agent-*.jsonl >/dev/null 2>&1; then
    SUBDIR="$ARG"                           # a subagents/ dir itself
  else
    main="$(newest_jsonl "$ARG")"           # treat as project dir
    [ -n "$main" ] || die "directory has no subagents/ and no *.jsonl: $ARG" "$EX_NOTFOUND"
    [ -s "$main" ] || die "transcript is empty or unreadable: $main" "$EX_EMPTY"
    SUBDIR="$(subdir_from_main "$main")"
  fi
  SRC_DESC="$ARG"
else
  die "path not found: $ARG" "$EX_NOTFOUND"
fi

if [ ! -d "$SUBDIR" ] || ! ls "$SUBDIR"/agent-*.jsonl >/dev/null 2>&1; then
  die "INCOMPLETE: no subagent transcripts under ${SUBDIR} — nothing to tally (source: ${SRC_DESC})" "$EX_INCOMPLETE"
fi

# ---- family classifier -----------------------------------------------------
# Fixed set (bash 3.2 has no associative arrays). Unknown/unattributable -> other.
family() {
  case "$1" in
    *haiku*)  printf 'haiku'  ;;
    *sonnet*) printf 'sonnet' ;;
    *opus*)   printf 'opus'   ;;
    *fable*)  printf 'fable'  ;;
    *)        printf 'other'  ;;
  esac
}

# ---- accumulate ------------------------------------------------------------
sum_haiku=0; sum_sonnet=0; sum_opus=0; sum_fable=0; sum_other=0
n_agents=0; n_bad=0
ROWS=""   # per-agent rows for -v (tab-separated), collected as text

for f in "$SUBDIR"/agent-*.jsonl; do
  [ -f "$f" ] || continue
  aid="$(basename "$f" .jsonl)"; aid="${aid#agent-}"
  meta="${f%.jsonl}.meta.json"
  atype="unknown"
  [ -f "$meta" ] && atype="$(jq -r '.agentType // "unknown"' "$meta" 2>/dev/null || echo unknown)"

  # Extract usage records in STREAMING mode (2>/dev/null): tolerates a partial trailing
  # line in a transcript still being appended by a live subagent — complete objects are
  # emitted before jq errors on the partial tail, and we keep those.
  records="$(jq -c 'select(.type=="assistant" and (.message.usage!=null)) |
      {model:(.message.model // "unknown"),
       in:(.message.usage.input_tokens // 0),
       out:(.message.usage.output_tokens // 0),
       cc:(.message.usage.cache_creation_input_tokens // 0),
       cr:(.message.usage.cache_read_input_tokens // 0)}' "$f" 2>/dev/null)"

  if [ -z "$records" ]; then
    # Non-empty file but no usable assistant/usage records: unparseable or usage-less.
    if [ -s "$f" ]; then n_bad=$((n_bad + 1)); fi
    continue
  fi

  # Per file: peak context = the turn maximizing (in+cc+cr); attribute to that turn's model.
  summ="$(printf '%s\n' "$records" | jq -s -r '
      (max_by(.in + .cc + .cr)) as $p
      | [ ($p.in + $p.cc + $p.cr), $p.model, (map(.out)|add), (map(.in)|add), (map(.cr)|add) ]
      | @tsv')"
  [ -n "$summ" ] || { n_bad=$((n_bad + 1)); continue; }

  peak="$(printf '%s' "$summ" | cut -f1)"
  model="$(printf '%s' "$summ" | cut -f2)"
  cum_out="$(printf '%s' "$summ" | cut -f3)"
  cum_in="$(printf '%s' "$summ" | cut -f4)"
  cum_cr="$(printf '%s' "$summ" | cut -f5)"
  fam="$(family "$model")"

  case "$fam" in
    haiku)  sum_haiku=$((sum_haiku + peak)) ;;
    sonnet) sum_sonnet=$((sum_sonnet + peak)) ;;
    opus)   sum_opus=$((sum_opus + peak)) ;;
    fable)  sum_fable=$((sum_fable + peak)) ;;
    *)      sum_other=$((sum_other + peak)) ;;
  esac
  n_agents=$((n_agents + 1))
  ROWS="${ROWS}${aid}	${atype}	${fam}	${peak}	${cum_out}	${cum_in}	${cum_cr}
"
done

if [ "$n_agents" -eq 0 ]; then
  die "INCOMPLETE: found subagent files under ${SUBDIR} but none had readable token usage${n_bad:+ (${n_bad} unparseable)}" "$EX_INCOMPLETE"
fi

# ---- format & print --------------------------------------------------------
# kfmt N -> "0" when exactly zero (matches rubric's `fable 0`), else round to nearest k.
kfmt() {
  if [ "$1" -eq 0 ] 2>/dev/null; then printf '0'; else
    awk -v n="$1" 'BEGIN{printf "%.0fk", n/1000}'
  fi
}

total_all=$((sum_haiku + sum_sonnet + sum_opus + sum_fable + sum_other))

line="Usage: haiku $(kfmt "$sum_haiku") · sonnet $(kfmt "$sum_sonnet") · opus $(kfmt "$sum_opus") · fable $(kfmt "$sum_fable")"
[ "$sum_other" -gt 0 ] && line="$line · other $(kfmt "$sum_other")"
line="$line (orchestrator excluded; /usage for quota)"
printf '%s\n' "$line"

if [ "$VERBOSE" -eq 1 ]; then
  printf '\n'
  printf 'source: %s\n' "$SRC_DESC"
  printf 'subagents dir: %s\n' "$SUBDIR"
  printf '%d subagent(s) tallied%s; peak-context per agent (tokens):\n' \
    "$n_agents" "$([ "$n_bad" -gt 0 ] && printf ', %d unparseable/skipped' "$n_bad")"
  printf '%-18s %-24s %-7s %10s %10s %10s %11s\n' AGENT TIER MODEL PEAK_CTX CUM_OUT CUM_IN CUM_CACHE_RD
  printf '%s' "$ROWS" | sort -t'	' -k4 -nr | while IFS='	' read -r aid atype fam peak cout cin ccr; do
    [ -n "$aid" ] || continue
    printf '%-18s %-24s %-7s %10s %10s %10s %11s\n' "$aid" "$atype" "$fam" "$peak" "$cout" "$cin" "$ccr"
  done
  printf '%-18s %-24s %-7s %10s\n' "TOTAL" "" "" "$total_all"
  printf '\nNote: PEAK_CTX = high-water context (input+cache_creation+cache_read) — the per-\n'
  printf 'agent figure Claude Code shows; the headline sums it per model family. Cumulative\n'
  printf 'output (CUM_OUT) is shown for cost context but is NOT in the headline. Not billing;\n'
  printf 'use /usage for quota.\n'
fi

exit "$EX_OK"
