#!/bin/bash
# scripts/triage-tiers.sh — print the level x vendor table from the tiers file,
# for planning: which vendor may serve which level, on which model and effort,
# and on what basis. Entries whose basis is "guess" are flagged: they are an
# unverified cross-vendor mapping until a parity run replaces them.
#
# Usage: triage-tiers.sh                  the table (human-readable)
#        triage-tiers.sh --bakeoff-json    one compact JSON line {asOf, levels, tuning}
#                                          for inline bake-offs: the orchestrator passes
#                                          it verbatim as triage-exec args.bakeoff.config
#                                          (a workflow has no fs). The tuning block is
#                                          validated first (TUNING_ERRORS below — the
#                                          single validator; test/lint.sh and
#                                          parity-report.sh both go through it); an
#                                          invalid or missing block is exit 2.
# Tiers file lookup (same order as ext-run.sh): $TRIAGE_TIERS, else
# <script dir>/triage-tiers.json (installed copy), else
# <script dir>/../config/tiers.json (repo). Missing/unparseable => exit 2.
# Read-only. bash-3.2-safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${TRIAGE_TIERS:-}" ]; then
  TIERS="$TRIAGE_TIERS"
elif [ -f "$SCRIPT_DIR/triage-tiers.json" ]; then
  TIERS="$SCRIPT_DIR/triage-tiers.json"
else
  TIERS="$SCRIPT_DIR/../config/tiers.json"
fi
BAKEOFF=0
case "${1:-}" in
  "") ;;
  --bakeoff-json) BAKEOFF=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "USAGE: unknown argument '$1' (none, or --bakeoff-json)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "USAGE: jq is required" >&2; exit 2; }
[ -f "$TIERS" ] || { echo "USAGE: tiers file not found: $TIERS" >&2; exit 2; }
jq -e 'type == "object" and (.levels | type == "object") and (.modes | type == "object")' "$TIERS" >/dev/null 2>&1 || {
  echo "USAGE: tiers file is not valid tiers JSON: $TIERS" >&2; exit 2; }

# TUNING_ERRORS — the ONE schema check of the tuning block (inline bake-offs and
# the parity-report.sh decision rule). Emits one string per problem; none = valid.
TUNING_ERRORS='def vendors: ["claude","codex","agy"];
  def levels: ["quick","builder","deep","top"];
  def efforts: ["low","medium","high","xhigh","max"];
  def num: type == "number";
  .tuning as $t
  | if ($t | type) != "object" then "tuning: missing or not an object"
    else
      (if ($t.sampleRate | num) and $t.sampleRate > 0 and $t.sampleRate <= 1 then empty
       else "tuning.sampleRate must be a number in (0, 1]" end),
      (if ($t.challengerMix | type) != "object" or ($t.challengerMix | length) == 0 then "tuning.challengerMix must be a non-empty object {vendor: share}"
       else
         ($t.challengerMix | to_entries[]
           | if (.key as $k | vendors | index($k)) == null then "tuning.challengerMix: unknown vendor \(.key)"
             elif (.value | num) and .value >= 0 and .value <= 1 then empty
             else "tuning.challengerMix.\(.key) must be a number in [0, 1]" end),
         (([$t.challengerMix[] | select(num)] | add // 0) as $sum
           | if ($sum - 1 | fabs) < 1e-9 then empty else "tuning.challengerMix shares must sum to 1 (got \($sum))" end)
       end),
      (if ($t.challengers | type) != "object" then "tuning.challengers must be an object {level: {vendor: [{model, effort}]}}"
       else
         ($t.challengers | to_entries[] | .key as $l
           | if (levels | index($l)) == null then "tuning.challengers: unknown level \($l)"
             elif (.value | type) != "object" then "tuning.challengers.\($l) must be an object {vendor: [...]}"
             else
               (.value | to_entries[] | .key as $v
                 | if (vendors | index($v)) == null then "tuning.challengers.\($l): unknown vendor \($v)"
                   elif $v == "agy" and $l != "builder" then "tuning.challengers.\($l).agy: agy serves the builder level only"
                   elif (.value | type) != "array" then "tuning.challengers.\($l).\($v) must be an array"
                   else
                     (.value | to_entries[] | .key as $i | .value
                       | if type != "object" then "tuning.challengers.\($l).\($v)[\($i)] must be an object {model, effort}"
                         elif ((.model | type) != "string") or ((.model | test("^[A-Za-z0-9._+-]+$")) | not) then "tuning.challengers.\($l).\($v)[\($i)].model must be a model id"
                         elif $v != "agy" and ((.effort as $e | efforts | index($e)) == null) then "tuning.challengers.\($l).\($v)[\($i)].effort must be one of \(efforts | join("|"))"
                         else empty end)
                   end)
             end)
       end),
      (if ($t.rule | type) != "object" then "tuning.rule must be an object"
       else
         (if ($t.rule.minN | num) and ($t.rule.minN | floor) == $t.rule.minN and $t.rule.minN >= 1 then empty
          else "tuning.rule.minN must be an integer >= 1" end),
         (if ($t.rule.cheaperTolerance | num) and $t.rule.cheaperTolerance >= 0 and $t.rule.cheaperTolerance < 1 then empty
          else "tuning.rule.cheaperTolerance must be a number in [0, 1)" end),
         (if ($t.rule.pricierMargin | num) and $t.rule.pricierMargin > 0 and $t.rule.pricierMargin <= 1 then empty
          else "tuning.rule.pricierMargin must be a number in (0, 1]" end),
         (if $t.rule.confidence == "wilson95" then empty
          else "tuning.rule.confidence must be \"wilson95\" (the only bound implemented)" end)
       end),
      (if ($t.ledger | type) == "string" and ($t.ledger | length) > 0 then empty else "tuning.ledger must be a non-empty path" end),
      (if ($t.pauseAtWeeklyPct | num) and $t.pauseAtWeeklyPct > 0 and $t.pauseAtWeeklyPct <= 100 then empty
       else "tuning.pauseAtWeeklyPct must be a number in (0, 100]" end)
    end'

if [ "$BAKEOFF" -eq 1 ]; then
  ERRS=$(jq -r "$TUNING_ERRORS" "$TIERS") || { echo "USAGE: could not validate the tuning block of $TIERS" >&2; exit 2; }
  if [ -n "$ERRS" ]; then
    echo "USAGE: invalid tuning block in $TIERS:" >&2
    printf '%s\n' "$ERRS" | sed 's/^/  /' >&2
    exit 2
  fi
  jq -c '{asOf, levels, tuning}' "$TIERS"
  exit 0
fi

# One cell: "model·effort (basis)", "-" when the vendor is not listed there, and a
# trailing GUESS flag when the basis is a guess.
CELL='def cell: if . == null then "-"
  else (.model // "?") + (if .effort then "·" + .effort else "" end)
       + (if .agent then " [" + .agent + "]" else "" end)
       + (if .basis then " (" + .basis + ")" else "" end)
       + (if .basis == "guess" then " GUESS" else "" end) end;'

echo "tiers: $TIERS (asOf $(jq -r '.asOf // "?"' "$TIERS"))"
echo ""
TAB=$(printf '\t')
{
  printf 'LEVEL\tclaude\tcodex\tagy\n'
  jq -r "$CELL"' .levels | to_entries[] | [.key, (.value.claude | cell), (.value.codex | cell), (.value.agy | cell)] | @tsv' "$TIERS"
} | while IFS="$TAB" read -r lvl c x a; do
  printf '%-8s %-42s %-38s %s\n' "$lvl" "$c" "$x" "$a"
done

echo ""
echo "modes (ext-run.sh <mode> --vendor V; build here = build without --level):"
jq -r "$CELL"' .modes | to_entries[] | .key as $v | .value | to_entries[] | [$v, .key, (.value | cell)] | @tsv' "$TIERS" |
  while IFS="$TAB" read -r v m c; do
    printf '  %-6s %-9s %s\n' "$v" "$m" "$c"
  done

echo ""
jq -r '(.parity // []) | sort_by(.date) | last | if . == null then "parity: no note recorded" else "parity (latest): \(.date) \(.by // "?"): \(.note // "")" end' "$TIERS"
GUESSES=$(jq '[.. | objects | select(.basis? == "guess")] | length' "$TIERS")
if [ "$GUESSES" -gt 0 ]; then
  echo "GUESS: $GUESSES entr$( [ "$GUESSES" -eq 1 ] && echo y || echo ies) rest on a guessed mapping — treat as unverified until a parity run replaces the basis."
fi
exit 0
