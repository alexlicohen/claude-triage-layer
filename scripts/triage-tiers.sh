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
#                                          parity-report.sh both go through it), and so
#                                          is aliasHistory (ALIAS_ERRORS, not printed:
#                                          parity-report.sh reads it from the file); an
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
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "USAGE: unknown argument '$1' (none, or --bakeoff-json)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "USAGE: jq is required" >&2; exit 2; }
[ -f "$TIERS" ] || { echo "USAGE: tiers file not found: $TIERS" >&2; exit 2; }
jq -e 'type == "object" and (.levels | type == "object") and (.modes | type == "object")' "$TIERS" >/dev/null 2>&1 || {
  echo "USAGE: tiers file is not valid tiers JSON: $TIERS" >&2; exit 2; }

# TUNING_ERRORS — the ONE schema check of the tuning block (inline bake-offs and
# the parity-report.sh decision rule). Emits one string per problem; none = valid.
# sampleRate is the EXPLORE rate (and triage-exec's fallback); maintain {rate,
# maxWidth} is the plateau rate and the Wilson-CI width that earns it (parity-report.sh
# rates); maintain.rate is > 0 and <= sampleRate: sampling never stops. rejected
# (optional) = [{level, vendor, model, effort, until?: YYYY-MM-DD}]: challengers Alex
# turned down; parity-report.sh never proposes one (until its until date passes).
TUNING_ERRORS='def vendors: ["claude","codex"];
  def levels: ["quick","builder","deep","top"];
  def efforts: ["low","medium","high","xhigh","max"];
  def num: type == "number";
  .tuning as $t
  | if ($t | type) != "object" then "tuning: missing or not an object"
    else
      (if ($t.sampleRate | num) and $t.sampleRate > 0 and $t.sampleRate <= 1 then empty
       else "tuning.sampleRate must be a number in (0, 1]" end),
      (if ($t.maintain | type) != "object" then "tuning.maintain must be an object {rate, maxWidth}"
       else
         (if ($t.maintain.rate | num) and $t.maintain.rate > 0 and $t.maintain.rate <= 1 then
            (if ($t.sampleRate | num) and $t.maintain.rate > $t.sampleRate
             then "tuning.maintain.rate must not exceed tuning.sampleRate (the explore rate)" else empty end)
          else "tuning.maintain.rate must be a number in (0, 1] (sampling never stops at a plateau)" end),
         (if ($t.maintain.maxWidth | num) and $t.maintain.maxWidth > 0 and $t.maintain.maxWidth <= 1 then empty
          else "tuning.maintain.maxWidth must be a number in (0, 1]" end)
       end),
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
                   elif (.value | type) != "array" then "tuning.challengers.\($l).\($v) must be an array"
                   else
                     (.value | to_entries[] | .key as $i | .value
                       | if type != "object" then "tuning.challengers.\($l).\($v)[\($i)] must be an object {model, effort}"
                         elif ((.model | type) != "string") or ((.model | test("^[A-Za-z0-9._+-]+$")) | not) then "tuning.challengers.\($l).\($v)[\($i)].model must be a model id"
                         elif (.effort as $e | efforts | index($e)) == null then "tuning.challengers.\($l).\($v)[\($i)].effort must be one of \(efforts | join("|"))"
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
      (if $t.rejected == null then empty
       elif ($t.rejected | type) != "array" then "tuning.rejected must be an array of {level, vendor, model, effort, until?}"
       else
         ($t.rejected | to_entries[] | .key as $i | .value
           | if type != "object" then "tuning.rejected[\($i)] must be an object {level, vendor, model, effort, until?}"
             elif (.level as $l | levels | index($l)) == null then "tuning.rejected[\($i)].level must be one of \(levels | join("|"))"
             elif (.vendor as $v | vendors | index($v)) == null then "tuning.rejected[\($i)].vendor must be one of \(vendors | join("|"))"
             elif ((.model | type) != "string") or ((.model | test("^[A-Za-z0-9._+-]+$")) | not) then "tuning.rejected[\($i)].model must be a model id"
             elif (.effort as $e | efforts | index($e)) == null then "tuning.rejected[\($i)].effort must be one of \(efforts | join("|"))"
             elif .until != null and (((.until | type) != "string") or ((.until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not)) then "tuning.rejected[\($i)].until must be a YYYY-MM-DD date"
             else empty end)
       end),
      (if ($t.ledger | type) == "string" and ($t.ledger | length) > 0 then empty else "tuning.ledger must be a non-empty path" end),
      (if ($t.pauseAtWeeklyPct | num) and $t.pauseAtWeeklyPct > 0 and $t.pauseAtWeeklyPct <= 100 then empty
       else "tuning.pauseAtWeeklyPct must be a number in (0, 100]" end)
    end'

# ALIAS_ERRORS — the ONE schema check of aliasHistory (optional; parity-report.sh
# resolves a bare model alias to a concrete id with it): {vendor: {alias: [{id,
# from: "YYYY-MM-DD"}, ...]}}, each list non-empty with strictly increasing `from`
# dates, every id a model-id token that is not itself an alias of that vendor.
ALIAS_ERRORS='def vendors: ["claude","codex"];
  def tok: type == "string" and test("^[A-Za-z0-9._+-]+$");
  .aliasHistory as $h
  | if $h == null then empty
    elif ($h | type) != "object" then "aliasHistory must be an object {vendor: {alias: [{id, from}]}}"
    else
      $h | to_entries[] | .key as $v
      | if (vendors | index($v)) == null then "aliasHistory: unknown vendor \($v)"
        elif (.value | type) != "object" then "aliasHistory.\($v) must be an object {alias: [{id, from}]}"
        else
          (.value | keys) as $aliases
          | .value | to_entries[] | .key as $a
          | if ($a | tok) | not then "aliasHistory.\($v): alias \($a | tojson) must be a model-id token"
            elif (.value | type) != "array" or (.value | length) == 0 then "aliasHistory.\($v).\($a) must be a non-empty array of {id, from}"
            else
              (.value | to_entries[] | .key as $i | .value
                | if type != "object" then "aliasHistory.\($v).\($a)[\($i)] must be an object {id, from}"
                  elif (.id | tok) | not then "aliasHistory.\($v).\($a)[\($i)].id must be a model-id token"
                  elif (.id as $id | $aliases | index($id)) != null then "aliasHistory.\($v).\($a)[\($i)].id \(.id) is itself an alias, not a concrete id"
                  elif ((.from | type) != "string") or ((.from | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not) then "aliasHistory.\($v).\($a)[\($i)].from must be a YYYY-MM-DD date"
                  else empty end),
              (if ([.value[] | objects | .from | strings] | . as $f | [range(1; length) | select($f[.] <= $f[. - 1])] | length) > 0
               then "aliasHistory.\($v).\($a): from dates must be strictly increasing" else empty end)
            end
        end
    end'

if [ "$BAKEOFF" -eq 1 ]; then
  ERRS=$(jq -r "$TUNING_ERRORS, ($ALIAS_ERRORS)" "$TIERS") || { echo "USAGE: could not validate the tuning block of $TIERS" >&2; exit 2; }
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
  printf 'LEVEL\tclaude\tcodex\n'
  jq -r "$CELL"' .levels | to_entries[] | [.key, (.value.claude | cell), (.value.codex | cell)] | @tsv' "$TIERS"
} | while IFS="$TAB" read -r lvl c x; do
  printf '%-8s %-42s %s\n' "$lvl" "$c" "$x"
done

echo ""
echo "modes (ext-run.sh <mode>; build here = build without --level):"
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
