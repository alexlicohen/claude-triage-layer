#!/bin/bash
# scripts/parity-cost.sh — attribute the CLAUDE usage of a workflow run (a parity
# run, a triage-compare bake-off) to agent labels, models and parity candidates,
# from the on-disk subagent transcripts. Read-only; prints counts only, never
# message content. External (codex) spend is not here: it is vendor-side and
# reaches the run's result via the ext-run accounting line.
#
# Usage:
#   parity-cost.sh DIR...
#
#   DIR   a workflow transcript dir (.../subagents/workflows/wf_<id>/) or any dir
#         above one; every agent-*.jsonl below it is read, with the label from
#         its agent-*.meta.json ("description"). Pass the run's own wf_ dir(s) —
#         a parent dir sums every run under it.
#
# What it counts (NOT the peak-context proxy of triage-usage.sh, which stays the
# per-tier tally): billing-style sums of every assistant message's usage —
# input_tokens, cache_read_input_tokens (cacheRead), cache_creation_input_tokens
# (cacheWrite) and output_tokens. Claude Code writes one transcript line per
# content block, repeating the message id with a growing usage object, so each
# message id is counted ONCE with the max of each field.
#
# Output (one JSON object on stdout):
#   {"agents":N, "skippedLines":<non-JSON lines, never fatal>,
#    "total":{input,cacheRead,cacheWrite,output,messages},
#    "byModel":{"<model id>":{...}},
#    "byLabel":{"<agent label>":{agentType, agents, ...sums, models:{"<id>":{...}}}},
#    "byCandidate":{"<candidate label>":{...sums, models:{...}}},
#    "overhead":{...sums}}
#   byCandidate folds every agent labelled `candidate:<label>` (triage-compare)
#   or `candidate:<label>@<task>` (triage-parity review candidates), with a
#   `-r<N>` repetition suffix removed, onto <label>; everything else (staging,
#   grading, loaders, judges, cleanup) is overhead.
#
# Exit codes: 0 ok; 2 usage (no DIR, DIR missing, jq missing);
#             5 INCOMPLETE (no agent transcripts, or none with usage) — never
#             a silent zero.
set -uo pipefail
export LC_ALL=C

die() { echo "parity-cost: $1" >&2; exit "$2"; }
command -v jq >/dev/null 2>&1 || die "jq is required" 2
[ $# -ge 1 ] || die "USAGE: parity-cost.sh DIR... (a workflow transcript dir, e.g. .../subagents/workflows/wf_<id>)" 2
for d in "$@"; do [ -d "$d" ] || die "not a directory: $d" 2; done

RECORDS=$(mktemp "${TMPDIR:-/tmp}/parity-cost.XXXXXX") || die "could not create a temp file" 2
trap 'rm -f "$RECORDS"' EXIT

n=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  meta="${f%.jsonl}.meta.json"
  label="(unlabelled)" atype="unknown"
  if [ -f "$meta" ]; then
    label=$(jq -r '.description // "(unlabelled)"' "$meta" 2>/dev/null || echo "(unlabelled)")
    atype=$(jq -r '.agentType // "unknown"' "$meta" 2>/dev/null || echo unknown)
  fi
  # Line by line (-R, fromjson?): a line that is not JSON — a live transcript's
  # partial last line, or a corrupt one mid-file — is counted as skipped, and
  # every other line, before AND after it, is kept.
  jq -R -c --arg label "$label" --arg atype "$atype" --arg file "$f" \
    'select(test("\\S")) | [fromjson?] as $o
     | if ($o | length) == 0 or ($o[0] | type) != "object" then {__skipped: true}
       else $o[0] | select(.type == "assistant" and .message.usage != null)
         | {file: $file, label: $label, atype: $atype, id: (.message.id // null),
            model: (.message.model // "unknown"),
            input: (.message.usage.input_tokens // 0), cacheRead: (.message.usage.cache_read_input_tokens // 0),
            cacheWrite: (.message.usage.cache_creation_input_tokens // 0), output: (.message.usage.output_tokens // 0)} end' \
    "$f" 2>/dev/null >> "$RECORDS"
done < <(find "$@" -name 'agent-*.jsonl' -type f | sort)

[ "$n" -gt 0 ] || die "INCOMPLETE: no agent-*.jsonl transcripts under $*" 5
[ "$(jq -s 'map(select(.__skipped != true)) | length' "$RECORDS")" -gt 0 ] || die "INCOMPLETE: $n transcript(s) under $* but none carried usage" 5

# The per-label / per-candidate cut — the only place this attribution is computed.
jq -s --argjson agents "$n" '
  (map(select(.__skipped == true)) | length) as $skipped
  | map(select(.__skipped != true)) |
  def sums: {input: (map(.input) | add // 0), cacheRead: (map(.cacheRead) | add // 0),
             cacheWrite: (map(.cacheWrite) | add // 0), output: (map(.output) | add // 0), messages: length};
  def bymodel: group_by(.model) | map({key: .[0].model, value: sums}) | from_entries;
  def candidate: if (.label | startswith("candidate:")) then
      (.label | ltrimstr("candidate:") | sub("@.*$"; "") | sub("-r[0-9]+$"; "")) else null end;
  # One record per message: a message id repeated across content-block lines
  # counts once, with the max of each field (usage grows as the message streams).
  (map(select(.id == null)) + (map(select(.id != null)) | group_by(.file + "\u0000" + .id)
     | map(.[0] + {input: (map(.input) | max), cacheRead: (map(.cacheRead) | max),
                   cacheWrite: (map(.cacheWrite) | max), output: (map(.output) | max)})))
  | map(. + {candidate: candidate}) as $m
  | {agents: $agents, skippedLines: $skipped,
     total: ($m | sums),
     byModel: ($m | bymodel),
     byLabel: ($m | group_by(.label) | map({key: .[0].label,
                value: (sums + {agentType: .[0].atype, agents: (map(.file) | unique | length), models: bymodel})}) | from_entries),
     byCandidate: ($m | map(select(.candidate != null)) | group_by(.candidate)
                   | map({key: .[0].candidate, value: (sums + {models: bymodel})}) | from_entries),
     overhead: ($m | map(select(.candidate == null)) | sums)}
' "$RECORDS"
