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


# --- subagent-spend segment --------------------------------------------------
# Cheap (cached) tally of this session's subagent token spend via
# scripts/triage-usage.sh, appended as e.g. " · sub 426k".
#
# Input JSON fields used here — verified against the documented statusline stdin
# schema (https://code.claude.com/docs/en/statusline, checked 2026-07-01): `session_id`
# and `transcript_path` are both documented top-level fields. `transcript_path` names
# the CURRENT session's own .jsonl transcript directly, which triage-usage.sh accepts
# as a PATH argument — more precise than guessing from cwd, so it's used when present.
# `workspace.current_dir` is also documented but not needed here. If transcript_path is
# absent (e.g. an older harness, or the synthetic test inputs below which carry neither
# field), we fall back to triage-usage.sh's own no-arg default resolution (newest
# transcript for the cwd's project slug) — same degrade-to-nothing behavior applies if
# that also fails to find anything.
SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty')
TRANSCRIPT=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

# BSD (macOS `stat -f %m`) vs GNU (`stat -c %Y`) mtime — try both, never error out.
cache_age_secs() {
  mtime=$(stat -f %m "$1" 2>/dev/null)
  if [ -z "$mtime" ]; then mtime=$(stat -c %Y "$1" 2>/dev/null); fi
  if [ -z "$mtime" ]; then printf '999999'; return; fi
  now=$(date +%s)
  printf '%s' $((now - mtime))
}

SUB=""
CACHE_KEY="${SESSION_ID:-default}"
CACHE_FILE="${TMPDIR:-/tmp}/triage-statusline-cache-$(id -u)-${CACHE_KEY}"

if [ -f "$CACHE_FILE" ] && [ "$(cache_age_secs "$CACHE_FILE")" -lt 30 ]; then
  SUB=$(cat "$CACHE_FILE" 2>/dev/null)
else
  # Resolve triage-usage.sh relative to this script's own dir first (repo checkout),
  # then fall back to the installed path.
  SELF_DIR=$(cd "$(dirname "$0")" && pwd)
  USAGE_SH="$SELF_DIR/scripts/triage-usage.sh"
  if [ ! -f "$USAGE_SH" ]; then USAGE_SH="$HOME/.claude/scripts/triage-usage.sh"; fi

  RAW=""
  if [ -f "$USAGE_SH" ]; then
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      RAW=$(bash "$USAGE_SH" "$TRANSCRIPT" 2>/dev/null)
    else
      RAW=$(bash "$USAGE_SH" 2>/dev/null)
    fi
    USAGE_RC=$?
  else
    USAGE_RC=1
  fi

  if [ "$USAGE_RC" -eq 0 ] && [ -n "$RAW" ] && ! printf '%s' "$RAW" | grep -q INCOMPLETE; then
    # Sum the per-tier "k"-rounded figures (e.g. "haiku 0 · sonnet 341k · opus 273k ·
    # fable 65k [· other Nk]") into one compact total. Zero-total (no subagents at all)
    # still renders as an empty segment per the degradation contract below.
    TOTAL_K=$(printf '%s' "$RAW" | awk '{
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-9]+k?$/ && $(i-1) ~ /^(haiku|sonnet|opus|fable|other)$/) {
          v = $i
          sub(/k$/, "", v)
          sum += v
        }
      }
      printf "%d", sum
    }')
    if [ -n "$TOTAL_K" ] && [ "$TOTAL_K" -gt 0 ] 2>/dev/null; then
      SUB=$(printf 'sub %dk' "$TOTAL_K")
    fi
  fi

  printf '%s' "$SUB" > "$CACHE_FILE" 2>/dev/null
fi

OUT=""
if [ -n "$CC" ]; then
  OUT="$CC"
else
  OUT="$MODEL"
fi
if [ -n "$CTX" ]; then OUT="$OUT · $CTX"; fi
if [ -n "$SUB" ]; then OUT="$OUT · $SUB"; fi
printf '%s' "$OUT"
