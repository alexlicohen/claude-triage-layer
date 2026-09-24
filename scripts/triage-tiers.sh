#!/bin/bash
# scripts/triage-tiers.sh — print the level x vendor table from the tiers file,
# for planning: which vendor may serve which level, on which model and effort,
# and on what basis. Entries whose basis is "guess" are flagged: they are an
# unverified cross-vendor mapping until a parity run replaces them.
#
# Usage: triage-tiers.sh
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
command -v jq >/dev/null 2>&1 || { echo "USAGE: jq is required" >&2; exit 2; }
[ -f "$TIERS" ] || { echo "USAGE: tiers file not found: $TIERS" >&2; exit 2; }
jq -e 'type == "object" and (.levels | type == "object") and (.modes | type == "object")' "$TIERS" >/dev/null 2>&1 || {
  echo "USAGE: tiers file is not valid tiers JSON: $TIERS" >&2; exit 2; }

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
