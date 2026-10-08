#!/bin/bash
# SessionStart hook: deliver ~/.claude/triage.md (the orchestrator routing rubric) to
# the MAIN session only. Single owner of the injection decision.
#
# Why a hook and not an `@triage.md` import in ~/.claude/CLAUDE.md: SessionStart does
# not fire for subagents (Agent tool or workflow agent()), so the rubric no longer
# rides along into every spawn (~3.6k input tokens each), and it re-injects after
# /clear and compaction (matcher startup|resume|clear|compact).
#
# Hook mode (no arguments): reads the hook input JSON on stdin and prints
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<label>\n\n<triage.md>"}}
# It prints NOTHING (exit 0) when:
#   - $CLAUDE_DIR/triage.disabled exists (the kill switch; `rm` re-enables);
#   - the input carries a non-null agent_id (defensive: never inject into a subagent).
# A missing triage.md, or label + file over the 10,000-char additionalContext cap
# (over it Claude Code keeps only a 2,000-char preview), prints a short notice
# instead — never a silent failure. Sizes are counted in bytes, an upper bound on
# the UTF-16 length Claude Code measures.
#
#   --check <file>   exit 1 if label + <file> would exceed the cap, 0 if it fits,
#                    2 on a usage error or an unreadable file (lint runs it on triage.md).
#
# Env: CLAUDE_DIR (default ~/.claude; install.sh pins it in the hook command, so a
# non-default install reads its own files), TRIAGE_MD (default $CLAUDE_DIR/triage.md).
# Always exits 0 in hook mode: a hook error must never block a session.
set -u

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
TRIAGE_MD="${TRIAGE_MD:-$CLAUDE_DIR/triage.md}"
CAP=10000
LABEL="This is ~/.claude/triage.md, the user's orchestrator routing rubric for this main session, delivered by the triage-layer SessionStart hook."

bytes_of() { wc -c < "$1" | tr -d ' '; }
LABEL_BYTES=$(printf '%s\n\n' "$LABEL" | wc -c | tr -d ' ')

# label + "\n\n" + file, in bytes. $1 = readable file.
total_bytes() { echo $((LABEL_BYTES + $(bytes_of "$1"))); }
# The one cap decision (hook mode and --check): would label + $1 exceed CAP?
over_cap() { [ "$(total_bytes "$1")" -gt "$CAP" ]; }

if [ "${1:-}" = "--check" ]; then
  f="${2:-}"
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "triage-context: --check needs a readable file (got '${f}')" >&2
    exit 2
  fi
  n=$(total_bytes "$f")
  if over_cap "$f"; then
    echo "triage-context: $f is too big: label + file = $n bytes, over the $CAP-char SessionStart cap (it would arrive as a 2,000-char preview)" >&2
    exit 1
  fi
  echo "triage-context: $f fits: label + file = $n bytes (cap $CAP)"
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "usage: triage-context.sh [--check <file>]" >&2
  exit 2
fi

# --- hook mode ------------------------------------------------------------------
[ -e "$CLAUDE_DIR/triage.disabled" ] && exit 0

INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat 2>/dev/null || true); fi

if ! command -v jq >/dev/null 2>&1; then
  # Plain SessionStart stdout is added to the context too.
  echo "triage-layer SessionStart hook: jq is not installed, so the routing rubric was not injected. Read $TRIAGE_MD before planning work."
  exit 0
fi

if [ -n "$INPUT" ] && printf '%s' "$INPUT" | jq -e 'type == "object" and (.agent_id // null) != null' >/dev/null 2>&1; then
  exit 0
fi

emit() { # $1 = additionalContext text
  jq -n --arg c "$1" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
}

if [ ! -f "$TRIAGE_MD" ] || [ ! -r "$TRIAGE_MD" ]; then
  emit "triage-layer SessionStart hook: the routing rubric $TRIAGE_MD was not found, so it is NOT loaded this session. Restore it (make sync in the claude-triage-layer clone), or \`touch $CLAUDE_DIR/triage.disabled\` to silence this notice."
  exit 0
fi

if over_cap "$TRIAGE_MD"; then
  n=$(total_bytes "$TRIAGE_MD")
  emit "triage-layer SessionStart hook: the routing rubric $TRIAGE_MD is $n bytes with its label, over the $CAP-char hook cap, so it was not injected (it would arrive truncated). Read $TRIAGE_MD in full before planning work, and trim it under the cap."
  exit 0
fi

if ! jq -n --arg label "$LABEL" --rawfile f "$TRIAGE_MD" \
     '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ($label + "\n\n" + $f)}}' 2>/dev/null; then
  emit "triage-layer SessionStart hook: jq could not read $TRIAGE_MD, so the routing rubric was not injected. Read it before planning work."
fi
exit 0
