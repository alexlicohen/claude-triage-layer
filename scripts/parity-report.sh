#!/bin/bash
# scripts/parity-report.sh — the parity LEDGER and the tier-change DECISION RULE.
# Single owner of both: the ledger schema (what a bake-off leaves behind), and the
# rule that turns accumulated outcomes into a PROPOSED config/tiers.json change.
# triage-parity.js and inline bake-offs (triage-exec + triage-compare) only
# produce results; the orchestrator ingests them here, then runs `report`.
# It never writes tiers.json — Alex approves every change.
#
# Usage:
#   parity-report.sh ingest-compare --result FILE --repo-name NAME --level L
#                    --source inline|suite [--task ID] [--applied LABEL]
#                    [--run ID] [--ts ISO] [--ledger F] [--tiers F]
#   parity-report.sh ingest-parity  --result FILE [--ts ISO] [--ledger F] [--tiers F]
#   parity-report.sh migrate        [--from F] [--ledger F] [--tiers F]
#   parity-report.sh report         [--ledger F] [--tiers F] [--json]
#
# ingest-compare  FILE = a triage-compare return value (JSON). Appends ONE ledger
#                 line for the compare. --level is the level the work was planned
#                 at; --applied names the candidate whose patch was applied.
# ingest-parity   FILE = a triage-parity return value. Appends one line per GRADED
#                 (task, candidate run), source "suite", level = the task's band's
#                 level (B1 quick, B2 builder, B3 deep, B4 top), run = basename of
#                 its outDir. A run already in the ledger is skipped (idempotent).
# migrate         converts the legacy ~/.agents/evidence/vendor-parity.jsonl (the
#                 default --from) best-effort: a compare line -> one ledger line; a
#                 parity aggregate -> one line per counted pass/fail per band (no
#                 task ids or tokens existed). Idempotent: keyed by run id.
# report          aggregates graded outcomes and applies tuning.rule (below).
#                 Markdown by default, one JSON object with --json.
#
# Ledger: JSON lines, default tuning.ledger of the tiers file (~ expanded). Schema
# (v 1), scores and metadata ONLY — never patch contents, briefs, checks or paths
# from the target repo (repoName is a bare name; task/run/labels are id tokens):
#   {"v":1, "ts":"<ISO>", "source":"inline|suite", "run":<id|null>, "repoName":"<name>",
#    "level":"quick|builder|deep|top", "band":<1-4, suite only>, "task":<id|null>,
#    "candidates":[{"label","vendor","model","effort","status","totalTokens","seconds"}],
#    "applied":<label|null>, "migrated":<"vendor-parity.jsonl", migrated lines only>}
#   status: pass | fail (GRADED) | unavailable | invalid | denied | unresolved |
#   ungraded | skipped | unknown — only pass/fail ever count. A candidate's null
#   model/effort is filled at ingest from the tiers file's levels.<its level>.<vendor>
#   (exactly what ran: agents and ext-run.sh default to that entry).
#
# Rule (tuning.rule, validated by triage-tiers.sh --bakeoff-json): per level x vendor,
# the incumbent is levels.<level>.<vendor> {model, effort}; every other (model,
# effort) of that vendor at that level is a challenger. Cheapness: claude haiku <
# sonnet < opus < fable; codex gpt-6-luna < gpt-6-sol < gpt-6-astra; agy flash <
# pro; then effort low < medium < high < xhigh < max. (agy was retired 2026-09-24:
# it stays a known vendor here only so historical ledger rows keep validating; it
# has no levels entry, so it is never an incumbent and never proposed.)
#   both n >= minN, else  insufficient-data (with the graded runs still needed)
#   CHEAPER challenger:   propose iff its Wilson 95% lower bound >= incumbent rate - cheaperTolerance
#   PRICIER challenger:   propose iff its rate - incumbent rate >= pricierMargin
#   same cost / unknown model: unranked, never proposed
# One proposal per level x vendor: a qualifying pricier challenger first (highest
# rate, then cheapest), else the cheapest qualifying cheaper one.
#
# Exit codes: 0 ok; 1 ledger write failed; 2 usage / invalid input / invalid
# tiers file (nothing written). bash-3.2-safe.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "parity-report: USAGE: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || usage "jq is required"

SUB="${1:-}"
[ $# -gt 0 ] && shift
RESULT="" REPO_NAME="" LEVEL="" SOURCE="" TASK="" APPLIED="" RUN="" TS="" LEDGER="" TIERS="" FROM="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift; continue ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
  esac
  [ $# -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --result)    RESULT="$2" ;;
    --repo-name) REPO_NAME="$2" ;;
    --level)     LEVEL="$2" ;;
    --source)    SOURCE="$2" ;;
    --task)      TASK="$2" ;;
    --applied)   APPLIED="$2" ;;
    --run)       RUN="$2" ;;
    --ts)        TS="$2" ;;
    --ledger)    LEDGER="$2" ;;
    --tiers)     TIERS="$2" ;;
    --from)      FROM="$2" ;;
    *)           usage "unknown argument $1" ;;
  esac
  shift 2
done

# --- tiers + tuning: read through triage-tiers.sh, the one tuning validator ----
if [ -z "$TIERS" ]; then
  if [ -n "${TRIAGE_TIERS:-}" ]; then TIERS="$TRIAGE_TIERS"
  elif [ -f "$SCRIPT_DIR/triage-tiers.json" ]; then TIERS="$SCRIPT_DIR/triage-tiers.json"
  else TIERS="$SCRIPT_DIR/../config/tiers.json"
  fi
fi
[ -f "$TIERS" ] || usage "tiers file not found: $TIERS"
[ -x "$SCRIPT_DIR/triage-tiers.sh" ] || usage "triage-tiers.sh (the tuning validator) is missing next to this script"
CFG=$(TRIAGE_TIERS="$TIERS" "$SCRIPT_DIR/triage-tiers.sh" --bakeoff-json) || usage "the tiers file $TIERS has no valid tuning block (see triage-tiers.sh --bakeoff-json)"

if [ -z "$LEDGER" ]; then
  LEDGER=$(printf '%s' "$CFG" | jq -r '.tuning.ledger')
  case "$LEDGER" in \~/*) LEDGER="$HOME/${LEDGER#\~/}" ;; esac
fi
case "$LEDGER" in /*) ;; *) usage "--ledger must be an absolute path (got '$LEDGER')" ;; esac
# The ledger is appended to; the tiers file must never be that target.
if [ -e "$LEDGER" ] && [ "$(cd "$(dirname "$LEDGER")" && pwd -P)/$(basename "$LEDGER")" = "$(cd "$(dirname "$TIERS")" && pwd -P)/$(basename "$TIERS")" ]; then
  usage "refusing: --ledger is the tiers file"
fi

# --- shared jq definitions (the ONE copy of statuses, orders and defaults) -----
DEFS='
def LEVELS: ["quick","builder","deep","top"];
def VENDORS: ["claude","codex","agy"];
def EFFORTS: ["low","medium","high","xhigh","max"];
def BAND_LEVEL: {"1":"quick","2":"builder","3":"deep","4":"top"};
def MODEL_ORDER: {"claude":["haiku","sonnet","opus","fable"],"codex":["gpt-6-luna","gpt-6-sol","gpt-6-astra"],"agy":["flash","pro"]};
def safe: type == "string" and test("^[A-Za-z0-9._:+-]{1,80}$");
def GRADED: ["pass","fail"];
def KNOWN: ["unavailable","invalid","denied","unresolved","ungraded","skipped"];
# norm — the ONLY status mapping: pass/fail are graded; every other status keeps
# its own name (or "unknown") and is never a fail.
def norm: (if type == "string" then ascii_downcase else "unknown" end) as $s
  | if $s == "pass" then "pass"
    elif $s == "fail" then "fail"
    else (if (KNOWN | index($s)) != null then $s else "unknown" end) end;
def num_or_null: if type == "number" then . else null end;
# cand($lvl) — one ledger candidate from a result candidate; null model/effort
# default to the tiers entry of the level it ran at.
def cand($levels; $lvl):
  (if (.level | type) == "string" and (.level as $x | LEVELS | index($x)) != null then .level else $lvl end) as $cl
  | ($levels[$cl][.vendor] // {}) as $def
  | {label, vendor,
     model: (if .model == null then ($def.model // null) else .model end),
     effort: (if .effort == null then ($def.effort // null) else .effort end),
     status: (.status | norm), totalTokens: (.totalTokens | num_or_null), seconds: (.seconds | num_or_null)};
def cand_ok: (.label | safe) and ((.vendor as $x | VENDORS | index($x)) != null)
  and (.model == null or (.model | safe)) and (.effort == null or ((.effort as $x | EFFORTS | index($x)) != null));
'

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
check_ts() {
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?$' ||
    usage "--ts must be an ISO date/time (got '$1')"
}
is_token() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:+-]{1,80}$'; }

append() { # $1 file of JSON lines to append
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || { echo "parity-report: could not create $(dirname "$LEDGER")" >&2; exit 1; }
  cat "$1" >> "$LEDGER" || { echo "parity-report: could not append to $LEDGER" >&2; exit 1; }
}
ledger_runs() { # distinct run ids already in the ledger, one per line
  [ -f "$LEDGER" ] || return 0
  jq -R -r 'fromjson? | .run? // empty | strings' "$LEDGER" | sort -u
}

TMP=$(mktemp -d) || { echo "parity-report: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
do_ingest_compare() {
  [ -n "$RESULT" ] && [ -n "$REPO_NAME" ] && [ -n "$LEVEL" ] && [ -n "$SOURCE" ] ||
    usage "ingest-compare needs --result --repo-name --level --source"
  [ -f "$RESULT" ] || usage "--result is not a file: $RESULT"
  printf '%s' "$REPO_NAME" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || usage "--repo-name must be a bare name (letters, digits, . _ -), never a path"
  case "$LEVEL" in quick|builder|deep|top) ;; *) usage "--level must be quick|builder|deep|top" ;; esac
  case "$SOURCE" in inline|suite) ;; *) usage "--source must be inline|suite" ;; esac
  [ -z "$TASK" ] || is_token "$TASK" || usage "--task must be an id token (letters, digits, . _ : + -), not text from the repo"
  [ -z "$RUN" ] || is_token "$RUN" || usage "--run must be an id token"
  if [ -n "$TS" ]; then check_ts "$TS"; else TS=$(now_ts); fi
  jq -e 'type == "object" and (.candidates | type == "array" and length > 0)' "$RESULT" >/dev/null 2>&1 ||
    usage "--result is not a triage-compare result (no candidates array): $RESULT"
  jq -c --argjson cfg "$CFG" --arg ts "$TS" --arg src "$SOURCE" --arg repo "$REPO_NAME" --arg lvl "$LEVEL" \
     --arg task "$TASK" --arg applied "$APPLIED" --arg run "$RUN" "$DEFS"'
    [.candidates[] | cand($cfg.levels; $lvl)] as $c
    | if ($c | all(cand_ok)) | not then error("a candidate has an invalid label/vendor/model/effort")
      elif $applied != "" and ([$c[].label] | index($applied)) == null then error("--applied \($applied) is not a candidate label")
      else {v: 1, ts: $ts, source: $src, run: (if $run == "" then null else $run end), repoName: $repo, level: $lvl,
            task: (if $task == "" then null else $task end), candidates: $c,
            applied: (if $applied == "" then null else $applied end)} end' "$RESULT" > "$TMP/line" 2>"$TMP/err" ||
    usage "could not ingest $RESULT: $(sed 's/^jq: error[^:]*: //' "$TMP/err" | head -c 300)"
  append "$TMP/line"
  jq -c '{step:"ingest-compare", ledger:$l, lines:1, candidates:(.candidates | length), graded:([.candidates[] | select(.status == "pass" or .status == "fail")] | length)}' --arg l "$LEDGER" "$TMP/line"
}

# ---------------------------------------------------------------------------
do_ingest_parity() {
  [ -n "$RESULT" ] || usage "ingest-parity needs --result"
  [ -f "$RESULT" ] || usage "--result is not a file: $RESULT"
  if [ -n "$TS" ]; then check_ts "$TS"; else TS=$(now_ts); fi
  jq -e 'type == "object" and (.tasks | type == "array") and (.ranking | type == "array")' "$RESULT" >/dev/null 2>&1 ||
    usage "--result is not a triage-parity result (needs tasks and ranking): $RESULT"
  local run
  run=$(jq -r '(.outDir // "") | tostring | sub("/+$"; "") | split("/") | last // ""' "$RESULT")
  is_token "$run" || usage "the parity result's outDir basename is not an id token: '$run'"
  if ledger_runs | grep -qxF "$run"; then
    jq -nc --arg l "$LEDGER" --arg r "$run" '{step:"ingest-parity", ledger:$l, run:$r, lines:0, skipped:"run already in the ledger"}'
    return 0
  fi
  jq -c --argjson cfg "$CFG" --arg ts "$TS" --arg run "$run" "$DEFS"'
    (reduce .ranking[] as $r ({}; .[$r.label] = $r)) as $rank
    | .tasks[] as $t
    | (BAND_LEVEL[($t.band | tostring)]) as $lvl
    | select($lvl != null)
    | $t.results[]
    | select(.label != null and $rank[.label] != null)
    | . as $row | $rank[.label] as $rk
    | ({label: ($row.runLabel // $row.label), vendor: ($row.vendor // $rk.vendor), level: $rk.level,
        model: ($row.model // $rk.model), effort: $rk.effort, status: $row.status,
        totalTokens: $row.totalTokens, seconds: $row.seconds} | cand($cfg.levels; $rk.level)) as $c
    | select(GRADED | index($c.status) != null)
    | if ($c | cand_ok) | not then error("candidate \($row.label) has an invalid label/vendor/model/effort")
      else {v: 1, ts: $ts, source: "suite", run: $run, repoName: "parity-suite", level: $lvl, band: $t.band,
            task: (if ($t.id | safe) then $t.id else null end), candidates: [$c], applied: null} end' "$RESULT" > "$TMP/lines" 2>"$TMP/err" ||
    usage "could not ingest $RESULT: $(sed 's/^jq: error[^:]*: //' "$TMP/err" | head -c 300)"
  [ -s "$TMP/lines" ] && append "$TMP/lines"
  jq -nc --arg l "$LEDGER" --arg r "$run" --argjson n "$(wc -l < "$TMP/lines" | tr -d ' ')" '{step:"ingest-parity", ledger:$l, run:$r, lines:$n}'
}

# ---------------------------------------------------------------------------
do_migrate() {
  [ -n "$FROM" ] || FROM="$HOME/.agents/evidence/vendor-parity.jsonl"
  [ -f "$FROM" ] || usage "--from is not a file: $FROM"
  ledger_runs > "$TMP/runs"
  # Each legacy line -> its run id, then its ledger lines. Legacy labels are
  # <vendor>-<model token>-<effort> (parity) or <vendor>-<level> (compare).
  jq -R -c --argjson cfg "$CFG" --slurpfile have <(jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/runs") "$DEFS"'
    def vendor_of: split("-")[0];
    def resolve_model($v; $tok): [$cfg.levels[][$v]? | objects | .model | strings | select(contains($tok))] | first // $tok;
    def ts_of: (.date // "1970-01-01") + "T00:00:00Z";
    fromjson? | select(type == "object")
    | . as $l
    | (if .run then "legacy:" + (.run | tostring) else "legacy:" + (.date // "?") + ":" + (.repo // "?") + ":" + (.level // "?") end) as $run
    | select(($have[0] | index($run)) == null)
    | if (.candidates | type) != "array" then empty
      elif .bands then
        .candidates[] as $c
        | ($c.label | tostring | split("-")) as $p
        | ($p[0]) as $v | select((VENDORS | index($v)) != null)
        | ($c | to_entries[] | select(.key | test("^b[1-4]$"))) as $b
        | (BAND_LEVEL[$b.key[1:]]) as $lvl
        | ((if ($p | length) > 1 then resolve_model($v; $p[1]) else null end)) as $m
        | ((if ($p | length) > 2 and (EFFORTS | index($p[2])) != null then $p[2] else null end)) as $e
        | ({label: $c.label, vendor: $v, level: $lvl, model: $m, effort: $e, status: null, totalTokens: null, seconds: null}) as $base
        | ([range(0; ($b.value.pass // 0)) | "pass"] + [range(0; ($b.value.fail // 0)) | "fail"])[] as $st
        | {v: 1, ts: ($l | ts_of), source: "suite", run: $run, repoName: "parity-suite", level: $lvl, band: ($b.key[1:] | tonumber),
           task: null, candidates: [($base | .status = $st | cand($cfg.levels; $lvl))], applied: null, migrated: "vendor-parity.jsonl"}
      else
        {v: 1, ts: ($l | ts_of), source: "inline", run: $run,
         repoName: ((.repo // "unknown") | tostring | gsub("[^A-Za-z0-9._-]"; "_")),
         level: .level, task: null,
         candidates: [.candidates[] | (.label | tostring | split("-")) as $p
           | {label, vendor: $p[0], level: (if ($p | length) > 1 and (LEVELS | index($p[1])) != null then $p[1] else $l.level end),
              model, effort, status, totalTokens, seconds} | cand($cfg.levels; $l.level)],
         applied: null, migrated: "vendor-parity.jsonl"}
      end' "$FROM" > "$TMP/lines" 2>"$TMP/err" || usage "could not migrate $FROM: $(head -c 300 "$TMP/err")"
  if jq -e -s 'any(.[]; (.candidates | all(.label != null and (.vendor as $v | ["claude","codex","agy"] | index($v)) != null)) | not)' "$TMP/lines" >/dev/null 2>&1; then
    usage "a legacy line has a candidate with no recognisable vendor — nothing written"
  fi
  local legacy migrated nlines
  legacy=$(jq -R -c 'fromjson? | select(type == "object")' "$FROM" | wc -l | tr -d ' ')
  migrated=$(jq -r '.run' "$TMP/lines" | sort -u | grep -c . || true)
  nlines=$(wc -l < "$TMP/lines" | tr -d ' ')
  [ -s "$TMP/lines" ] && append "$TMP/lines"
  jq -nc --arg l "$LEDGER" --arg f "$FROM" --argjson legacy "$legacy" --argjson m "$migrated" --argjson n "$nlines" \
    '{step:"migrate", from:$f, ledger:$l, legacyLines:$legacy, migrated:$m, skipped:($legacy - $m), lines:$n}'
}

# ---------------------------------------------------------------------------
# report — aggregation + THE decision rule.
REPORT='
def wilson($s; $n): if $n == 0 then null else
  (1.959963984540054) as $z | ($s / $n) as $p
  | (($p + $z * $z / (2 * $n) - $z * (($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) | sqrt)) / (1 + $z * $z / $n))
  | if . < 0 then 0 else . end end;
def mean: if length == 0 then null else add / length end;
def cheap_key($v; $m; $e):
  ((MODEL_ORDER[$v] // []) as $o | [range(0; $o | length) as $k | select(($m // "") | contains($o[$k])) | $k] | first // -1) as $mi
  | [$mi, (if $e == null then -1 else (EFFORTS | index($e) // -1) end)];
# direction — cheapness of challenger $c against incumbent $i (same vendor).
def direction($c; $i):
  cheap_key($c.vendor; $c.model; $c.effort) as $kc | cheap_key($i.vendor; $i.model; $i.effort) as $ki
  | if $kc[0] < 0 or $ki[0] < 0 then "unranked"
    elif $kc < $ki then "cheaper" elif $kc > $ki then "pricier" else "unranked" end;
def need($n): if $n >= $minN then 0 else $minN - $n end;

($lines | map(fromjson? | select(type == "object" and (.candidates | type) == "array"))) as $ok
| ($lines | length) as $total
| [$ok[] | . as $l | .candidates[] | select(type == "object")
   | {level: $l.level, vendor, model, effort, status: (.status | norm), totalTokens: (.totalTokens | num_or_null), seconds: (.seconds | num_or_null)}] as $rows
| [$rows | group_by([.level, .vendor, .model, .effort])[]
   | . as $g | ([$g[] | select(.status as $x | GRADED | index($x) != null)]) as $gr
   | ($gr | length) as $n | ([$gr[] | select(.status == "pass")] | length) as $s
   | {level: $g[0].level, vendor: $g[0].vendor, model: $g[0].model, effort: $g[0].effort,
      n: $n, passes: $s, rate: (if $n == 0 then null else $s / $n end), wilsonLB: wilson($s; $n),
      excluded: (($g | length) - $n),
      meanTokens: ([$g[] | .totalTokens | numbers] | mean), meanSeconds: ([$g[] | .seconds | numbers] | mean)}] as $groups
| [ $levels | to_entries[] | .key as $L | .value | to_entries[] | select(.value | type == "object")
    | {level: $L, vendor: .key, model: (.value.model // null), effort: (.value.effort // null)} ] as $incs
| [ $incs[] as $i
    | ([$groups[] | select(.level == $i.level and .vendor == $i.vendor and .model == $i.model and .effort == $i.effort)] | first
       // {level: $i.level, vendor: $i.vendor, model: $i.model, effort: $i.effort, n: 0, passes: 0, rate: null, wilsonLB: null}) as $inc
    | $groups[] | select(.level == $i.level and .vendor == $i.vendor and ((.model == $i.model and .effort == $i.effort) | not))
    | . as $ch | direction($ch; $inc) as $dir
    | need($inc.n) as $ni | need($ch.n) as $nc
    | {level: $i.level, vendor: $i.vendor, incumbent: $inc, challenger: $ch, direction: $dir, needIncumbent: $ni, needChallenger: $nc}
    | if $dir == "unranked" then .verdict = "unranked" | .why = "cheapness unknown or equal — never proposed"
      elif $ni > 0 or $nc > 0 then .verdict = "insufficient-data"
        | .why = "insufficient data: needs \($ni) more graded run(s) of the incumbent and \($nc) of the challenger (minN \($minN))"
      elif $dir == "cheaper" then
        (if $ch.wilsonLB >= $inc.rate - $tol - 1e-12 then .verdict = "propose" else .verdict = "keep" end)
        | .why = "cheaper: Wilson LB \($ch.wilsonLB * 1000 | round / 1000) vs incumbent rate \($inc.rate * 1000 | round / 1000) - \($tol)"
      else
        (if $ch.rate - $inc.rate >= $margin - 1e-12 then .verdict = "propose" else .verdict = "keep" end)
        | .why = "pricier: rate \($ch.rate * 1000 | round / 1000) - incumbent \($inc.rate * 1000 | round / 1000) vs margin \($margin)"
      end ] as $decisions
| [ $decisions | map(select(.verdict == "propose")) | group_by([.level, .vendor])[]
    | (map(select(.direction == "pricier")) | sort_by([-(.challenger.rate), cheap_key(.challenger.vendor; .challenger.model; .challenger.effort)]) | first) as $up
    | (map(select(.direction == "cheaper")) | sort_by([cheap_key(.challenger.vendor; .challenger.model; .challenger.effort), -(.challenger.wilsonLB)]) | first) as $down
    | ($up // $down)
    | {level, vendor, direction, from: {model: .incumbent.model, effort: .incumbent.effort}, to: {model: .challenger.model, effort: .challenger.effort},
       incumbent: {n: .incumbent.n, rate: .incumbent.rate}, challenger: {n: .challenger.n, rate: .challenger.rate, wilsonLB: .challenger.wilsonLB}, why} ] as $proposals
| {ledger: $ledger, tiers: $tiersPath, lines: $total, malformed: ($total - ($ok | length)),
   rule: {minN: $minN, cheaperTolerance: $tol, pricierMargin: $margin, confidence: "wilson95"},
   groups: $groups, decisions: $decisions, proposals: $proposals,
   note: "proposal only: parity-report.sh never writes tiers.json; Alex approves every change"}
'

MARKDOWN='
def f3: if . == null then "—" else (. * 1000 | round / 1000 | tostring) end;
def fi: if . == null then "—" else (. | round | tostring) end;
def me: (.model // "default") + (if .effort then " · " + .effort else "" end);
def isinc($r; $lv): ($lv[$r.level][$r.vendor] // null) as $i | $i != null and $i.model == $r.model and ($i.effort // null) == $r.effort;
. as $R
| ["# Parity report", "",
   "ledger: \(.ledger) (\(.lines) line(s)\(if .malformed > 0 then ", \(.malformed) malformed skipped" else "" end)) · tiers: \(.tiers)",
   "rule: minN \(.rule.minN) · cheaper: Wilson 95% LB >= incumbent rate - \(.rule.cheaperTolerance) · pricier: rate - incumbent rate >= \(.rule.pricierMargin)",
   "Only pass/fail count; unavailable/invalid/denied/unresolved/ungraded/skipped are excluded (Excl.)."]
  + ([ "quick","builder","deep","top" ] | map(. as $L | ($R.groups | map(select(.level == $L))) as $g
      | if ($g | length) == 0 then empty else
        ["", "## \($L)", "", "| Vendor | Model | Effort | n | Pass | Rate | Wilson LB | Excl. | Mean tokens | Mean s | |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
        + ($g | sort_by([.vendor, .model, .effort]) | map("| \(.vendor) | \(.model // "—") | \(.effort // "—") | \(.n) | \(.passes) | \(.rate | f3) | \(.wilsonLB | f3) | \(.excluded) | \(.meanTokens | fi) | \(.meanSeconds | fi) | \(if isinc(.; $lv) then "incumbent" else "" end) |"))
      end) | add // [])
  + ["", "## Decisions", ""]
  + (if (.decisions | length) == 0 then ["No challenger measured against an incumbent yet."] else
      ["| Level | Vendor | Incumbent (n, rate) | Challenger (n, rate) | Direction | Verdict | Why |", "|---|---|---|---|---|---|---|"]
      + (.decisions | map("| \(.level) | \(.vendor) | \(.incumbent | me) (\(.incumbent.n), \(.incumbent.rate | f3)) | \(.challenger | me) (\(.challenger.n), \(.challenger.rate | f3)) | \(.direction) | \(.verdict) | \(.why) |")) end)
  + ["", "## Proposals", ""]
  + (if (.proposals | length) == 0 then ["None: no challenger clears the rule."] else
      (.proposals | map("- \(.level)/\(.vendor): \(.from | me) -> \(.to | me) (\(.direction); \(.why))")) end)
  + ["", "Proposal only: parity-report.sh never writes tiers.json. Alex approves every change (edit config/tiers.json, make tiers, make verify)."]
| .[]
'

do_report() {
  local lines="$TMP/ledger"
  if [ -f "$LEDGER" ]; then cp "$LEDGER" "$lines"; else : > "$lines"; fi
  jq -R -s -c 'split("\n") | map(select(test("\\S")))' "$lines" > "$TMP/lines.json"
  jq -n -c --argjson cfg "$CFG" --slurpfile lines "$TMP/lines.json" --arg ledger "$LEDGER" --arg tiersPath "$TIERS" "$DEFS"'
    $cfg.levels as $levels | $cfg.tuning.rule.minN as $minN | $cfg.tuning.rule.cheaperTolerance as $tol
    | $cfg.tuning.rule.pricierMargin as $margin | $lines[0] as $lines
    | '"$REPORT" > "$TMP/report.json" 2>"$TMP/err" || { echo "parity-report: report failed: $(head -c 400 "$TMP/err")" >&2; exit 2; }
  if [ "$JSON" -eq 1 ]; then
    cat "$TMP/report.json"
  else
    jq -r --argjson lv "$(printf '%s' "$CFG" | jq -c .levels)" "$MARKDOWN" "$TMP/report.json"
  fi
}

case "$SUB" in
  ingest-compare) do_ingest_compare ;;
  ingest-parity)  do_ingest_parity ;;
  migrate)        do_migrate ;;
  report)         do_report ;;
  *)              usage "parity-report.sh ingest-compare|ingest-parity|migrate|report [options] (see the header)" ;;
esac
