#!/bin/bash
# Triage-layer statusline.
#   - If ccusage is installed (global `ccusage`, or `bunx`), show its live
#     cost / 5-hour-block burn line, then append model · context %.
#   - Otherwise fall back to the original `model · ctx%` display.
# NEVER invokes `npx` per-render (that would lag the prompt). To enable ccusage:
#     npm i -g ccusage      # or install bun
# Part of the model-triage layer (see ~/.claude/triage.md for uninstall).
input=$(cat)

MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')
PCT=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)

if [ -z "$PCT" ]; then
  CTX=""
elif [ "$PCT" -ge 60 ]; then
  CTX=$(printf '\033[1;31m⚠ CONTEXT %s%%\033[0m' "$PCT")
else
  CTX=$(printf 'ctx %s%%' "$PCT")
fi

# ccusage segment — only if already installed (no on-demand npx download).
CC=""
if command -v ccusage >/dev/null 2>&1; then
  CC=$(printf '%s' "$input" | ccusage statusline 2>/dev/null)
elif command -v bunx >/dev/null 2>&1; then
  CC=$(printf '%s' "$input" | bunx ccusage statusline 2>/dev/null)
fi

if [ -n "$CC" ]; then
  if [ -n "$CTX" ]; then printf '%s · %s' "$CC" "$CTX"; else printf '%s' "$CC"; fi
else
  if [ -n "$CTX" ]; then printf '%s · %s' "$MODEL" "$CTX"; else printf '%s' "$MODEL"; fi
fi
