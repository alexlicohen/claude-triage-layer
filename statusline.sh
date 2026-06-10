#!/bin/bash
# Triage-layer statusline: current model · context % (warning at >=60%).
# Input: Claude Code statusline JSON on stdin. Part of the model-triage layer
# (see ~/.claude/triage.md for uninstall).
input=$(cat)

MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')
PCT=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)

if [ -z "$PCT" ]; then
  printf '%s' "$MODEL"
elif [ "$PCT" -ge 60 ]; then
  printf '%s · \033[1;31m⚠ CONTEXT %s%%\033[0m' "$MODEL" "$PCT"
else
  printf '%s · ctx %s%%' "$MODEL" "$PCT"
fi
