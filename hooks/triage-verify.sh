#!/bin/bash
# #2 — SubagentStop hook for the triage layer.
# When a worker tier (triage-builder / triage-quick-task) finishes, surface a
# reminder to run the project's objective checks BEFORE accepting the result,
# with the detected check commands filled in.
#
# DESIGN: NON-BLOCKING and SIDE-EFFECT-FREE. It does NOT run tests itself
# (a blind whole-project test/lint run after every worker is real blast radius:
# slow, flaky, and noisy with pre-existing failures). It only reminds + lists
# the commands. additionalContext is attempted; on Claude Code versions where
# SubagentStop ignores it, this is a harmless no-op (exit 0, nothing blocked).
#
# To UPGRADE to actually run + block on failures, add (guarded by
# `.stop_hook_active` to avoid loops) a `{"decision":"block","reason":...}`
# branch — but only with a project-specific, fast, scoped check command.
set -euo pipefail
input=$(cat)

agent=$(printf '%s' "$input" | jq -r '.agent_type // empty')
case "$agent" in
  triage-builder|triage-quick-task) ;;
  *) exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')
checks=""
[ -f "$cwd/pyproject.toml" ] && checks="$checks ruff check .; pytest -q;"
[ -f "$cwd/package.json" ]   && checks="$checks npm run lint; npm test;"
[ -f "$cwd/Makefile" ]       && checks="$checks make test;"
[ -f "$cwd/Cargo.toml" ]     && checks="$checks cargo check; cargo test;"
[ -z "$checks" ] && checks=" (discover the project's test/lint command)"

msg="Tier worker '$agent' finished. Per triage.md verification protocol, run objective checks before accepting:$checks"

# Emit additionalContext (ignored gracefully on versions that don't support it).
printf '{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":%s}}\n' \
  "$(printf '%s' "$msg" | jq -Rs .)"
exit 0
