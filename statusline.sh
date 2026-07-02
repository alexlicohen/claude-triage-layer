#!/bin/bash
# Triage-layer statusline.
#   - If ccusage is installed and on PATH (`ccusage`), show its live
#     cost / 5-hour-block burn line, then append model · context %.
#   - Otherwise fall back to the original `model · ctx%` display.
# NEVER downloads anything per-render (that would lag the prompt). To enable ccusage,
# install it so it is on PATH:
#     npm i -g ccusage        # or: bun add -g ccusage
# Part of the model-triage layer (see ~/.claude/triage.md for uninstall).
input=$(cat)

MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')
PCT=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)

# Only treat PCT as a number if it is one — a non-numeric value would make the
# `-ge` test abort with "integer expression expected" and dump an error into the render.
case "$PCT" in
  ''|*[!0-9]*) CTX="" ;;
  *)
    if [ "$PCT" -ge 60 ]; then
      CTX=$(printf '\033[1;31m⚠ CONTEXT %s%%\033[0m' "$PCT")
    else
      CTX=$(printf 'ctx %s%%' "$PCT")
    fi ;;
esac

# ccusage segment — only if it is already installed on PATH (never an on-demand download).
CC=""
if command -v ccusage >/dev/null 2>&1; then
  CC=$(printf '%s' "$input" | ccusage statusline 2>/dev/null)
fi

if [ -n "$CC" ]; then
  if [ -n "$CTX" ]; then printf '%s · %s' "$CC" "$CTX"; else printf '%s' "$CC"; fi
else
  if [ -n "$CTX" ]; then printf '%s · %s' "$MODEL" "$CTX"; else printf '%s' "$MODEL"; fi
fi
