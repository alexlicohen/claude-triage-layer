#!/bin/bash
# scripts/tiers-sync.sh — make agents/*.md frontmatter agree with config/tiers.json.
#
# tiers.json is the single place a model or effort is edited. This script rewrites
# ONLY the `model:` and `effort:` lines inside each agent's YAML frontmatter:
#   - levels.<level>.claude  {agent, model, effort}  -> agents/<agent>.md
#   - agents.<name>          {model, effort}         -> agents/<name>.md
# Nothing else in any agent file is touched. Edit loop: edit config/tiers.json,
# `make tiers`, `make verify`.
#
# Usage:
#   scripts/tiers-sync.sh            rewrite drifted frontmatter in place
#   scripts/tiers-sync.sh --check    change nothing; exit 1 listing every drift
#                                    (test/lint.sh runs this)
#   --root DIR                       operate on DIR/config/tiers.json + DIR/agents
#                                    (default: this repo)
#
# Also fails (exit 1) when an agents/triage-*.md is not covered by tiers.json, when
# tiers.json names an agent file that does not exist, when an entry lacks a model
# or effort, or when one agent is given two different entries.
# Exit 2: usage error, jq missing, or tiers.json missing/unparseable.
# bash-3.2-safe (macOS default): no associative arrays, no GNU-only flags.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --root)  ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "USAGE: unknown argument '$1' (--check, --root DIR)" >&2; exit 2 ;;
  esac
done

TIERS="$ROOT/config/tiers.json"
AGENTS_DIR="$ROOT/agents"
command -v jq >/dev/null 2>&1 || { echo "USAGE: jq is required" >&2; exit 2; }
[ -f "$TIERS" ] || { echo "USAGE: tiers file not found: $TIERS" >&2; exit 2; }
jq -e 'type == "object" and (.levels | type == "object")' "$TIERS" >/dev/null 2>&1 || {
  echo "USAGE: $TIERS is not valid tiers JSON" >&2; exit 2; }

FAIL=0
problem() { echo "TIERS: $1"; FAIL=1; }

TAB=$(printf '\t')
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# One row per agent: name<TAB>model<TAB>effort (empty fields kept, then rejected).
jq -r '
  ([(.levels // {}) | to_entries[] | .value.claude // empty | [(.agent // ""), (.model // ""), (.effort // "")]]
   + [(.agents // {}) | to_entries[] | [.key, (.value.model // ""), (.value.effort // "")]])
  | .[] | @tsv' "$TIERS" > "$TMP/map.tsv"

# The same agent listed twice with different values is a contradiction, not a sync.
cut -f1 "$TMP/map.tsv" | sort | uniq -d > "$TMP/dups"
while IFS= read -r dup; do
  [ -n "$dup" ] || continue
  if [ "$(grep "^$dup$TAB" "$TMP/map.tsv" | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
    problem "$dup has conflicting entries in $TIERS"
  fi
done < "$TMP/dups"

# Every shipped agent must be covered — an uncovered agent's model is edited by hand.
for f in "$AGENTS_DIR"/triage-*.md; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .md)
  cut -f1 "$TMP/map.tsv" | grep -qxF "$name" || problem "agents/$name.md is not covered by $TIERS (add it under levels.*.claude or agents)"
done

sort -u "$TMP/map.tsv" > "$TMP/map.sorted"
while IFS="$TAB" read -r name model effort; do
  [ -n "$name" ] || { problem "a levels.*.claude entry has no agent name"; continue; }
  if [ -z "$model" ] || [ -z "$effort" ]; then
    problem "$name: entry needs both model and effort"
    continue
  fi
  file="$AGENTS_DIR/$name.md"
  if [ ! -f "$file" ]; then
    problem "$TIERS names agent '$name' but agents/$name.md does not exist"
    continue
  fi
  if ! head -1 "$file" | grep -qx -- '---'; then
    problem "agents/$name.md has no YAML frontmatter"
    continue
  fi
  # Rewrite model:/effort: inside the FIRST frontmatter block only; add a missing
  # key just before the closing ---. Every other line passes through verbatim.
  awk -v m="$model" -v e="$effort" '
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---" {
      if (!sm) print "model: " m
      if (!se) print "effort: " e
      infm = 0; print; next
    }
    infm && /^model:/  { print "model: " m;  sm = 1; next }
    infm && /^effort:/ { print "effort: " e; se = 1; next }
    { print }
  ' "$file" > "$TMP/new.md"
  if cmp -s "$file" "$TMP/new.md"; then
    continue
  fi
  if [ "$CHECK" -eq 1 ]; then
    have=$(awk 'NR>1 && $0=="---"{exit} /^(model|effort):/{printf "%s ", $0}' "$file")
    problem "agents/$name.md frontmatter drifted from tiers.json (has: ${have:-nothing}; tiers: model: $model effort: $effort) — run make tiers"
  else
    # cat > (not mv) keeps the file's mode and any link.
    cat "$TMP/new.md" > "$file"
    echo "updated: agents/$name.md (model: $model, effort: $effort)"
  fi
done < "$TMP/map.sorted"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
if [ "$CHECK" -eq 1 ]; then
  echo "tiers-sync: agents/*.md frontmatter matches $TIERS"
fi
exit 0
