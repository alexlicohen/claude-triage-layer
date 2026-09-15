#!/bin/bash
# triage-cache-segment.sh — prompt-cache segment for the triage statusline.
#
# Prints a compact segment like `cache 87% warm` (hit ratio + warm/cold),
# with the likely miss cause appended when the cache is cold and Claude Code
# has diagnosed one, e.g. `cache 42% cold (tool_result_pruning)`.
#
# Field names verified against the installed Claude Code binary's own built-in
# statusline help text — `strings "$(readlink -f "$(which claude)")" | grep -A2
# last_miss_cause.causes` (checked 2026-09-15, installed version 2.1.272) —
# which gives this exact idiom:
#   .prompt_cache.caching_observed, .prompt_cache.warm, .prompt_cache.last_miss_cause.causes[0]
# Confirmed against https://code.claude.com/docs/en/statusline's "Prompt cache
# fields" table, which additionally documents `.prompt_cache.hit_ratio` (0-1,
# null until any request has cache reads/writes/uncached input). `prompt_cache`
# requires Claude Code >= 2.1.251; `last_miss_cause` requires >= 2.1.260.
#
# Degradation contract (same as statusline.sh): any missing field, unexpected
# type, or jq failure prints NOTHING and exits 0 — never an error, never a
# non-zero exit.
input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

OBSERVED=$(printf '%s' "$input" | jq -r 'if .prompt_cache.caching_observed == true then "true" else "false" end' 2>/dev/null)
if [ "$OBSERVED" != "true" ]; then
  exit 0
fi

# `// empty` would swallow an explicit `false` (jq's `//` treats false as
# absent) — read the boolean with an if/else instead, per the installed
# binary's own statusline help text.
WARM_RAW=$(printf '%s' "$input" | jq -r 'if .prompt_cache.warm == true then "true" elif .prompt_cache.warm == false then "false" else empty end' 2>/dev/null)
case "$WARM_RAW" in
  true) WARM="warm" ;;
  false) WARM="cold" ;;
  *) exit 0 ;;
esac

HIT_RATIO=$(printf '%s' "$input" | jq -r '.prompt_cache.hit_ratio // empty' 2>/dev/null)
case "$HIT_RATIO" in
  ''|null) exit 0 ;;
esac

PCT=$(printf '%s' "$input" | jq -r '(.prompt_cache.hit_ratio * 100 + 0.5) | floor' 2>/dev/null)
case "$PCT" in
  ''|*[!0-9]*) exit 0 ;;
esac
if [ "$PCT" -gt 100 ]; then
  exit 0
fi

SEG="cache ${PCT}% ${WARM}"

if [ "$WARM" = "cold" ]; then
  CAUSE=$(printf '%s' "$input" | jq -r '.prompt_cache.last_miss_cause.causes[0] // empty' 2>/dev/null)
  case "$CAUSE" in
    '') ;;
    *[!A-Za-z0-9_]*) ;; # not a clean short token — skip rather than risk garbage in the render
    *)
      if [ "${#CAUSE}" -le 30 ]; then
        SEG="$SEG ($CAUSE)"
      fi
      ;;
  esac
fi

printf '%s' "$SEG"
