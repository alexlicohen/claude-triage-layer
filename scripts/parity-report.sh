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
#   parity-report.sh ingest-review  --result FILE --repo-name NAME [--resolved FILE]
#                    [--run ID] [--ts ISO] [--ledger F] [--tiers F]
#   parity-report.sh migrate        [--from F] [--ledger F] [--tiers F]
#   parity-report.sh backfill-modelid [--dry-run] [--ledger F] [--tiers F]
#   parity-report.sh report         [--ledger F] [--tiers F] [--json] [--model M] [--since DATE]
#   parity-report.sh history        [--ledger F] [--tiers F] [--json] [--model M] [--since DATE]
#   parity-report.sh rates          [--ledger F] [--tiers F] [--json]
#
# ingest-compare  FILE = a triage-compare return value (JSON). Appends ONE ledger
#                 line for the compare. --level is the level the work was planned
#                 at; --applied names the candidate whose patch was applied.
# ingest-parity   FILE = a triage-parity return value. Appends one line per GRADED
#                 (task, candidate run), source "suite", level = the task's band's
#                 level (B1 quick, B2 builder, B3 deep, B4 top), run = basename of
#                 its outDir. A run already in the ledger is skipped (idempotent).
# ingest-review   FILE = a triage-compare kind:"review" result. Appends ONE ledger line
#                 (source "inline-review") with per-reviewer precision/recall/n,
#                 recomputed here AFTER applying --resolved (Alex's verdicts for
#                 disputed item ids: {"M3": "real", "M7": "not-real"}; a resolved
#                 item then counts like an agreed one, an unresolved one stays out).
#                 precision = its real items / its adjudicated (real + rejected)
#                 items (n = that denominator), recall = its real items / all real
#                 items; null when the denominator is 0; an unavailable reviewer is
#                 recorded with null scores, never 0. Run id = --run, else the
#                 result's outDir basename; a run already in the ledger is skipped.
# migrate         converts the legacy ~/.agents/evidence/vendor-parity.jsonl (the
#                 default --from) best-effort: a compare line -> one ledger line; a
#                 parity aggregate -> one line per counted pass/fail per band (no
#                 task ids or tokens existed). Idempotent: keyed by run id.
# report          aggregates graded outcomes and applies tuning.rule (below).
#                 Markdown by default, one JSON object with --json. Review lines
#                 (source inline-review) get their OWN section — mean precision /
#                 recall per vendor x model x effort — never mixed into the build
#                 pass rates, and they do not drive tier proposals (yet).
# backfill-modelid gives every ledger candidate/reviewer WITHOUT a modelId key one
#                 (Model ids, below; never "observed": nothing reported it then).
#                 Rewrites --ledger in place (same dir + mode, one rename; refused
#                 if the ledger changed meanwhile). Idempotent: a row that has the
#                 key (even null) is left alone; lines with nothing to fill and
#                 malformed lines stay byte-identical. --dry-run writes nothing.
# history         per level x vendor, EVERY modelId x effort ever graded there (old
#                 versions stay listed): n, passes, rate, Wilson LB/UB, first/last
#                 ts, role (incumbent = current | challenger | null), and the current
#                 incumbent even before it has data. Markdown, or JSON with --json.
# --model M       report/history only: keep rows whose modelId is M, or has M as a
#                 whole token (a family: --model opus = every Opus version).
# --since DATE    report/history only: keep ledger lines with ts >= DATE. Filters
#                 narrow what the rule sees; `rates` never takes them.
# rates           the inline bake-off SAMPLING RATE per level (Rates, below): one
#                 line per level, or with --json {asOf, params, levels: {<level>:
#                 {state, rate, reason}}, rates: {<level>: rate}}. The orchestrator
#                 passes `.rates` verbatim as triage-exec args.bakeoff.rates. Also the
#                 `sampling` field of report --json.
#
# Ledger: JSON lines, default tuning.ledger of the tiers file (~ expanded). Schema
# (v 1), scores and metadata ONLY — never patch contents, briefs, checks or paths
# from the target repo (repoName is a bare name; task/run/labels are id tokens):
#   {"v":1, "ts":"<ISO>", "source":"inline|suite", "run":<id|null>, "repoName":"<name>",
#    "level":"quick|builder|deep|top", "band":<1-4, suite only>, "task":<id|null>,
#    "candidates":[{"label","vendor","model","effort","status","totalTokens","seconds",
#                   "modelId","modelIdSource"}],
#    "applied":<label|null>, "migrated":<"vendor-parity.jsonl", migrated lines only>}
#   Review line (ingest-review; no candidates, so it never enters the build rule):
#   {"v":1, "ts", "source":"inline-review", "run":<id|null>, "repoName",
#    "reviewers":[{"label","vendor","level","model","effort","status":"ok|unavailable",
#      "precision","recall","n","real","rejected","disputed","findings","totalTokens","seconds",
#      "modelId","modelIdSource"}],
#    "items":<merged items>, "real":<real items>, "disputed":<still disputed>, "resolved":<by Alex>}
#   status: pass | fail (GRADED) | unavailable | invalid | denied | unresolved |
#   ungraded | skipped | unknown — only pass/fail ever count. A candidate's null
#   model/effort is filled at ingest from the tiers file's levels.<its level>.<vendor>
#   (exactly what ran: agents and ext-run.sh default to that entry).
#
# Model ids (Wave 15; model_id in DEFS is the one resolver): `model` keeps what was
# configured; `modelId` is the concrete version and `modelIdSource` says how it is
# known: pinned (a concrete id was configured: tiers entry or candidate), observed
# (the runner reported it: a triage-compare candidate with modelFrom "runner", i.e.
# ext-run's vendor/model line), inferred-by-date (a bare alias resolved through the
# tiers file's aliasHistory at the line's UTC date: the last entry with from <=
# date), or both null (no model, or an alias before its first entry). A context
# suffix like [1m] is not a version and is stripped. Lines written before Wave 15
# have no modelId: `report` resolves them the same way at read time, and
# backfill-modelid writes it into them. Schema stays v 1 (both keys optional).
#
# Rule (tuning.rule, validated by triage-tiers.sh --bakeoff-json): per level x vendor,
# the incumbent is levels.<level>.<vendor> {model, effort}; every other (model,
# effort) of that vendor at that level is a challenger — all keyed by CONCRETE id
# (modelId; a tiers alias resolves as of today). Cheapness by FAMILY, a whole token
# of the id, so every version ranks: claude haiku < sonnet < opus < fable; codex
# luna < sol < astra; agy flash < pro; then effort low < medium < high < xhigh <
# max. Two versions of one family at one effort are unranked (never proposed): a
# version upgrade is Alex's tiers edit, not a rule outcome. (agy was retired 2026-09-24:
# it stays a known vendor here only so historical ledger rows keep validating; it
# has no levels entry, so it is never an incumbent and never proposed.)
#   both n >= minN, else  insufficient-data (with the graded runs still needed)
#   CHEAPER challenger:   propose iff its Wilson 95% lower bound >= incumbent rate - cheaperTolerance
#   PRICIER challenger:   propose iff its rate - incumbent rate >= pricierMargin
#   same cost / no family token: unranked, never proposed
# One proposal per level x vendor: a qualifying pricier challenger first (highest
# rate, then cheapest), else the cheapest qualifying cheaper one.
#
# Rates (tuning.sampleRate = explore, tuning.maintain {rate, maxWidth}), per LEVEL
# (sampling is decided per subtask at its level), from the same groups/proposals:
#   none      no challenger configured at the level (tuning.challengers) -> rate 0
#   maintain  iff for EVERY vendor with a levels.<level> entry or configured
#             challengers there: the incumbent and every configured challenger have
#             n >= minN, each Wilson 95% interval (UB - LB) is <= maxWidth, and there
#             is no proposal for that level x vendor -> maintain.rate
#   explore   otherwise, the reason naming every gap -> sampleRate
# Counts are keyed by the CURRENT (vendor, modelId, effort) of the tiers file, so a
# model or effort change there starts at n=0 -> explore again (no separate reset),
# and so does an alias that moves (a new aliasHistory entry): old versions keep
# their counts and stay visible in `history`. Only build lines count (review lines
# never do).
#
# Exit codes: 0 ok; 1 ledger write failed (or it changed during a backfill); 2 usage / invalid input / invalid
# tiers file (nothing written). bash-3.2-safe.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "parity-report: USAGE: $1" >&2; exit 2; }
check_since() { printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || usage "--since must be an ISO date (YYYY-MM-DD...) (got '$1')"; }
command -v jq >/dev/null 2>&1 || usage "jq is required"

SUB="${1:-}"
[ $# -gt 0 ] && shift
RESULT="" REPO_NAME="" LEVEL="" SOURCE="" TASK="" APPLIED="" RUN="" TS="" LEDGER="" TIERS="" FROM="" RESOLVED="" JSON=0
FMODEL="" FSINCE="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift; continue ;;
    --dry-run) DRY=1; shift; continue ;;
    -h|--help) sed -n "2,$(grep -n '^set -uo pipefail' "$0" | cut -d: -f1)p" "$0" | sed '$d'; exit 0 ;;
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
    --resolved)  RESOLVED="$2" ;;
    --model)     FMODEL="$2" ;;
    --since)     FSINCE="$2" ;;
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
# aliasHistory (validated above by the same triage-tiers.sh call): resolves a bare
# alias to the concrete id it pointed at on a date. TODAY = the date a tiers entry
# that is still an alias is resolved at (UTC, like every ledger ts).
AH=$(jq -c '.aliasHistory // {}' "$TIERS") || usage "could not read aliasHistory from $TIERS"
TODAY=$(date -u +%Y-%m-%d)
if [ -n "$FMODEL$FSINCE" ]; then
  case "$SUB" in report|history) ;; *) usage "--model/--since filter report and history only" ;; esac
  [ -z "$FMODEL" ] || printf '%s' "$FMODEL" | grep -Eq '^[A-Za-z0-9._+-]{1,80}$' || usage "--model must be a model id or family token (got '$FMODEL')"
  [ -z "$FSINCE" ] || check_since "$FSINCE"
fi
[ "$DRY" -eq 0 ] || [ "$SUB" = backfill-modelid ] || usage "--dry-run is a backfill-modelid option"

# --- shared jq definitions (the ONE copy of statuses, orders and defaults) -----
DEFS='
def LEVELS: ["quick","builder","deep","top"];
def VENDORS: ["claude","codex","agy"];
def EFFORTS: ["low","medium","high","xhigh","max"];
def BAND_LEVEL: {"1":"quick","2":"builder","3":"deep","4":"top"};
# FAMILY_ORDER — cheapness by model FAMILY, matched as a whole token of the id
# (split on - . _ : + @), so every version of a family ranks: claude-opus-5 and
# claude-opus-5-5 are both "opus". An id with no known family token is unranked.
def FAMILY_ORDER: {"claude":["haiku","sonnet","opus","fable"],"codex":["luna","sol","astra"],"agy":["flash","pro"]};
def id_base: sub("\\[[^\\]]*\\]$"; "");
def id_tokens: ascii_downcase | [splits("[-._:+@]")];
def family_rank($v): (FAMILY_ORDER[$v] // []) as $o | (if type == "string" then id_tokens else [] end) as $t
  | [range(0; $o | length) as $k | select(($t | index($o[$k])) != null) | $k] | first // -1;
# Model-id resolution — THE one place a configured model becomes a concrete id.
# $ah = the tiers file aliasHistory {vendor: {alias: [{id, from}]}}. A model is an
# alias iff it (minus a context suffix like [1m]) is a key there; it resolves to
# the last entry whose from <= $date (null before the first one). Anything else is
# already a concrete id (suffix stripped: [1m] is a context window, not a version).
def is_alias($ah; $v; $m): ($m | type) == "string" and ((($ah[$v] // {})[$m | id_base]) | type) == "array";
def alias_at($ah; $v; $m; $date): [(($ah[$v] // {})[$m | id_base] // [])[] | select(.from <= $date)] | last | if . == null then null else .id end;
# model_id -> {modelId, modelIdSource}: pinned (a concrete id was configured),
# observed ($obs: the runner reported it), inferred-by-date (an alias resolved by
# $date), or both null (no model, or an alias with no entry yet on $date).
def model_id($ah; $v; $m; $date; $obs):
  if ($m | type) != "string" then {modelId: null, modelIdSource: null}
  elif is_alias($ah; $v; $m) then alias_at($ah; $v; $m; $date) as $id
    | if $id == null then {modelId: null, modelIdSource: null} else {modelId: $id, modelIdSource: "inferred-by-date"} end
  else {modelId: ($m | id_base), modelIdSource: (if $obs then "observed" else "pinned" end)} end;
# current_id — a TIERS entry (incumbent or challenger) as a concrete id today.
def current_id($ah; $v; $m; $today): if is_alias($ah; $v; $m) then (alias_at($ah; $v; $m; $today) // $m) elif ($m | type) == "string" then ($m | id_base) else $m end;
def date_of: (if type == "string" then .[0:10] else "" end);
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
# default to the tiers entry of the level it ran at; modelId/modelIdSource via
# model_id at the line date $date (observed iff the result says modelFrom "runner").
def cand($levels; $ah; $date; $lvl):
  (if (.level | type) == "string" and (.level as $x | LEVELS | index($x)) != null then .level else $lvl end) as $cl
  | ($levels[$cl][.vendor] // {}) as $def
  | (.modelFrom == "runner" and .model != null) as $obs
  | {label, vendor,
     model: (if .model == null then ($def.model // null) else .model end),
     effort: (if .effort == null then ($def.effort // null) else .effort end),
     status: (.status | norm), totalTokens: (.totalTokens | num_or_null), seconds: (.seconds | num_or_null)}
  | . + model_id($ah; .vendor; .model; $date; $obs);
def cand_ok: (.label | safe) and ((.vendor as $x | VENDORS | index($x)) != null)
  and (.model == null or (.model | safe)) and (.effort == null or ((.effort as $x | EFFORTS | index($x)) != null))
  and (.modelId == null or (.modelId | safe));
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
  jq -c --argjson cfg "$CFG" --argjson ah "$AH" --arg ts "$TS" --arg src "$SOURCE" --arg repo "$REPO_NAME" --arg lvl "$LEVEL" \
     --arg task "$TASK" --arg applied "$APPLIED" --arg run "$RUN" "$DEFS"'
    [.candidates[] | cand($cfg.levels; $ah; ($ts | date_of); $lvl)] as $c
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
  jq -c --argjson cfg "$CFG" --argjson ah "$AH" --arg ts "$TS" --arg run "$run" "$DEFS"'
    (reduce .ranking[] as $r ({}; .[$r.label] = $r)) as $rank
    | .tasks[] as $t
    | (BAND_LEVEL[($t.band | tostring)]) as $lvl
    | select($lvl != null)
    | $t.results[]
    | select(.label != null and $rank[.label] != null)
    | . as $row | $rank[.label] as $rk
    | ({label: ($row.runLabel // $row.label), vendor: ($row.vendor // $rk.vendor), level: $rk.level,
        model: ($row.model // $rk.model), effort: $rk.effort, status: $row.status,
        totalTokens: $row.totalTokens, seconds: $row.seconds} | cand($cfg.levels; $ah; ($ts | date_of); $rk.level)) as $c
    | select(GRADED | index($c.status) != null)
    | if ($c | cand_ok) | not then error("candidate \($row.label) has an invalid label/vendor/model/effort")
      else {v: 1, ts: $ts, source: "suite", run: $run, repoName: "parity-suite", level: $lvl, band: $t.band,
            task: (if ($t.id | safe) then $t.id else null end), candidates: [$c], applied: null} end' "$RESULT" > "$TMP/lines" 2>"$TMP/err" ||
    usage "could not ingest $RESULT: $(sed 's/^jq: error[^:]*: //' "$TMP/err" | head -c 300)"
  [ -s "$TMP/lines" ] && append "$TMP/lines"
  jq -nc --arg l "$LEDGER" --arg r "$run" --argjson n "$(wc -l < "$TMP/lines" | tr -d ' ')" '{step:"ingest-parity", ledger:$l, run:$r, lines:$n}'
}

# ---------------------------------------------------------------------------
do_ingest_review() {
  [ -n "$RESULT" ] && [ -n "$REPO_NAME" ] || usage "ingest-review needs --result --repo-name"
  [ -f "$RESULT" ] || usage "--result is not a file: $RESULT"
  printf '%s' "$REPO_NAME" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || usage "--repo-name must be a bare name (letters, digits, . _ -), never a path"
  [ -z "$RUN" ] || is_token "$RUN" || usage "--run must be an id token"
  if [ -n "$TS" ]; then check_ts "$TS"; else TS=$(now_ts); fi
  jq -e 'type == "object" and .kind == "review" and (.reviewers | type == "array" and length > 0) and (.items | type == "array")' "$RESULT" >/dev/null 2>&1 ||
    usage "--result is not a triage-compare review result (kind \"review\" with reviewers and items): $RESULT"
  local res='{}'
  if [ -n "$RESOLVED" ]; then
    [ -f "$RESOLVED" ] || usage "--resolved is not a file: $RESOLVED"
    jq -e 'type == "object" and all(.[]; . == "real" or . == "not-real")' "$RESOLVED" >/dev/null 2>&1 ||
      usage "--resolved must be a JSON object {\"<disputed item id>\": \"real\" | \"not-real\"}"
    res=$(jq -c . "$RESOLVED")
    local bad
    bad=$(jq -r --argjson r "$res" '[.items[] | select(.verdict == "disputed") | .id] as $d | [$r | keys[] | select(. as $k | $d | index($k) | not)] | join(", ")' "$RESULT")
    [ -z "$bad" ] || usage "--resolved names id(s) that are not disputed items of this review: $bad"
  fi
  local run="$RUN"
  if [ -z "$run" ]; then
    run=$(jq -r '(.outDir // "") | tostring | sub("/+$"; "") | split("/") | last // ""' "$RESULT")
    is_token "$run" || run=""
  fi
  if [ -n "$run" ] && ledger_runs | grep -qxF "$run"; then
    jq -nc --arg l "$LEDGER" --arg r "$run" '{step:"ingest-review", ledger:$l, run:$r, lines:0, skipped:"run already in the ledger"}'
    return 0
  fi
  jq -c --argjson cfg "$CFG" --argjson ah "$AH" --argjson res "$res" --arg ts "$TS" --arg run "$run" --arg repo "$REPO_NAME" "$DEFS"'
    ([.items[] | if .verdict == "disputed" and $res[.id] != null
                 then .verdict = (if $res[.id] == "real" then "real" else "rejected" end) | .resolved = true else . end]) as $items
    | ([$items[] | select(.verdict == "real")] | length) as $allReal
    | [.reviewers[] | . as $r
        | ($cfg.levels[$r.level // ""][$r.vendor] // {}) as $def
        | {label, vendor, level: (if (LEVELS | index($r.level)) != null then $r.level else null end),
           model: (if $r.model == null then ($def.model // null) else $r.model end),
           effort: (if $r.effort == null then ($def.effort // null) else $r.effort end),
           status: (if $r.status == "ok" then "ok" else "unavailable" end),
           totalTokens: ($r.tokens | num_or_null), seconds: ($r.seconds | num_or_null)}
        | . + model_id($ah; .vendor; .model; ($ts | date_of); false)
        | if .status != "ok" then . + {precision: null, recall: null, n: 0, real: null, rejected: null, disputed: null, findings: null}
          else ([$items[] | select((.foundBy // []) | index($r.label))]) as $mine
            | ([$mine[] | select(.verdict == "real")] | length) as $real
            | ([$mine[] | select(.verdict == "rejected")] | length) as $rej
            | . + {precision: (if ($real + $rej) == 0 then null else $real / ($real + $rej) end),
                   recall: (if $allReal == 0 then null else $real / $allReal end),
                   n: ($real + $rej), real: $real, rejected: $rej,
                   disputed: ([$mine[] | select(.verdict == "disputed")] | length),
                   findings: ($r.findings | num_or_null)} end] as $revs
    | if ($revs | all(cand_ok)) | not then error("a reviewer has an invalid label/vendor/model/effort")
      else {v: 1, ts: $ts, source: "inline-review", run: (if $run == "" then null else $run end), repoName: $repo,
            reviewers: $revs, items: ($items | length), real: $allReal,
            disputed: ([$items[] | select(.verdict == "disputed")] | length),
            resolved: ([$items[] | select(.resolved == true)] | length)} end' "$RESULT" > "$TMP/line" 2>"$TMP/err" ||
    usage "could not ingest $RESULT: $(sed 's/^jq: error[^:]*: //' "$TMP/err" | head -c 300)"
  append "$TMP/line"
  jq -c --arg l "$LEDGER" '{step:"ingest-review", ledger:$l, run, lines:1, reviewers:(.reviewers | length), scored:([.reviewers[] | select(.precision != null)] | length), disputed, resolved}' "$TMP/line"
}

# ---------------------------------------------------------------------------
do_migrate() {
  [ -n "$FROM" ] || FROM="$HOME/.agents/evidence/vendor-parity.jsonl"
  [ -f "$FROM" ] || usage "--from is not a file: $FROM"
  ledger_runs > "$TMP/runs"
  # Each legacy line -> its run id, then its ledger lines. Legacy labels are
  # <vendor>-<model token>-<effort> (parity) or <vendor>-<level> (compare).
  jq -R -c --argjson cfg "$CFG" --argjson ah "$AH" --slurpfile have <(jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/runs") "$DEFS"'
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
           task: null, candidates: [($base | .status = $st | cand($cfg.levels; $ah; ($l | ts_of | date_of); $lvl))], applied: null, migrated: "vendor-parity.jsonl"}
      else
        {v: 1, ts: ($l | ts_of), source: "inline", run: $run,
         repoName: ((.repo // "unknown") | tostring | gsub("[^A-Za-z0-9._-]"; "_")),
         level: .level, task: null,
         candidates: [.candidates[] | (.label | tostring | split("-")) as $p
           | {label, vendor: $p[0], level: (if ($p | length) > 1 and (LEVELS | index($p[1])) != null then $p[1] else $l.level end),
              model, effort, status, totalTokens, seconds} | cand($cfg.levels; $ah; ($l | ts_of | date_of); $l.level)],
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
# backfill-modelid — give every ledger candidate/reviewer that has no modelId key
# one, via model_id at its line date (never observed: nothing reported it then).
# Idempotent (a row with the key, even null, is left alone); lines with nothing
# to fill, and malformed lines, are kept byte-identical; line order is kept.
do_backfill() {
  [ -f "$LEDGER" ] || usage "the ledger does not exist: $LEDGER"
  local before
  before=$(cksum < "$LEDGER")
  jq -R -c --argjson ah "$AH" "$DEFS"'
    . as $raw
    | (try fromjson catch null) as $o
    | def unfilled: type == "object" and (has("modelId") | not);
      if ($o | type) != "object" then {line: $raw, filled: []}
      else ($o.ts | date_of) as $d
        | [($o.candidates, $o.reviewers) | arrays | .[] | select(unfilled)
           | model_id($ah; .vendor; .model; $d; false) | .modelIdSource // "unresolved"] as $filled
        | if ($filled | length) == 0 then {line: $raw, filled: []}
          else {line: ($o | with_entries(if (.key == "candidates" or .key == "reviewers") and (.value | type) == "array"
                  then .value |= map(if unfilled then . + model_id($ah; .vendor; .model; $d; false) else . end)
                  else . end) | tojson), filled: $filled} end
      end' "$LEDGER" > "$TMP/bf" 2>"$TMP/err" || usage "could not read the ledger $LEDGER: $(head -c 300 "$TMP/err")"
  jq -r '.line' "$TMP/bf" > "$TMP/new"
  local summary
  summary=$(jq -s -c --arg l "$LEDGER" --argjson dry "$DRY" '
    {step: "backfill-modelid", ledger: $l, dryRun: ($dry == 1), lines: length,
     updatedLines: ([.[] | select(.filled | length > 0)] | length),
     filled: ([.[].filled[]] | group_by(.) | map({key: .[0], value: length}) | from_entries)}' "$TMP/bf")
  if [ "$DRY" -eq 0 ] && [ "$(printf '%s' "$summary" | jq .updatedLines)" -gt 0 ]; then
    [ "$(cksum < "$LEDGER")" = "$before" ] || { echo "parity-report: $LEDGER changed during the backfill — nothing written, run it again" >&2; exit 1; }
    # Same directory, same mode (cp -p), then one rename: a reader never sees half a ledger.
    cp -p "$LEDGER" "$LEDGER.backfill.$$" && cat "$TMP/new" > "$LEDGER.backfill.$$" && mv "$LEDGER.backfill.$$" "$LEDGER" ||
      { rm -f "$LEDGER.backfill.$$"; echo "parity-report: could not rewrite $LEDGER" >&2; exit 1; }
  fi
  printf '%s\n' "$summary"
}

# ---------------------------------------------------------------------------
# report — aggregation + THE decision rule (+ the history view).
REPORT='
# wilsonBound — the Wilson 95% score interval: $sgn -1 = lower, +1 = upper bound.
def wilsonBound($s; $n; $sgn): if $n == 0 then null else
  (1.959963984540054) as $z | ($s / $n) as $p
  | (($p + $z * $z / (2 * $n) + $sgn * $z * (($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) | sqrt)) / (1 + $z * $z / $n))
  | if . < 0 then 0 elif . > 1 then 1 else . end end;
def wilson($s; $n): wilsonBound($s; $n; -1);
def wilsonUB($s; $n): wilsonBound($s; $n; 1);
def mean: if length == 0 then null else add / length end;
def cheap_key($v; $m; $e):
  [($m | family_rank($v)), (if $e == null then -1 else (EFFORTS | index($e) // -1) end)];
# direction — cheapness of challenger $c against incumbent $i (same vendor).
def direction($c; $i):
  cheap_key($c.vendor; $c.modelId; $c.effort) as $kc | cheap_key($i.vendor; $i.modelId; $i.effort) as $ki
  | if $kc[0] < 0 or $ki[0] < 0 then "unranked"
    elif $kc < $ki then "cheaper" elif $kc > $ki then "pricier" else "unranked" end;
def need($n): if $n >= $minN then 0 else $minN - $n end;
# rid — a ledger row'"'"'s concrete id: its own modelId, else resolved now from its
# model at the line date (old lines), else the configured model itself.
def rid($d): if (.modelId | type) == "string" then .modelId
  else (model_id($ah; .vendor; .model; $d; false).modelId // .model) end;
def keep_model: $fModel == "" or . == $fModel or ((. // "") | id_tokens | index($fModel | ascii_downcase)) != null;
def keep_ts: $fSince == "" or ((. // "") | tostring) >= $fSince;

($lines | map(fromjson? | select(type == "object"))) as $objs
| ($objs | map(select((.candidates | type) == "array" and .source != "inline-review"))) as $ok
# Review lines are their own section: never a build row, never a proposal input.
| ($objs | map(select(.source == "inline-review" and (.reviewers | type) == "array"))) as $rv
| ($lines | length) as $total
| [$ok[] | . as $l | select($l.ts | keep_ts) | .candidates[] | select(type == "object")
   | {level: $l.level, vendor, model, modelId: rid($l.ts | date_of), effort, status: (.status | norm),
      totalTokens: (.totalTokens | num_or_null), seconds: (.seconds | num_or_null), ts: $l.ts}
   | select(.modelId | keep_model)] as $rows
# Incumbents and configured challengers, as concrete ids (a tiers alias resolves as of today).
| [ $levels | to_entries[] | .key as $L | .value | to_entries[] | select(.value | type == "object")
    | {level: $L, vendor: .key, modelId: current_id($ah; .key; (.value.model // null); $today), effort: (.value.effort // null)} ] as $incs
| [ ($challengers // {}) | to_entries[] | .key as $L | .value | to_entries[] | .key as $V | .value[]?
    | {level: $L, vendor: $V, modelId: current_id($ah; $V; .model; $today), effort} ] as $chcfg
| def role($g): if any($incs[]; .level == $g.level and .vendor == $g.vendor and .modelId == $g.modelId and .effort == $g.effort) then "incumbent"
    elif any($chcfg[]; .level == $g.level and .vendor == $g.vendor and .modelId == $g.modelId and .effort == $g.effort) then "challenger"
    else null end;
  [$rows | group_by([.level, .vendor, .modelId, .effort])[]
   | . as $g | ([$g[] | select(.status as $x | GRADED | index($x) != null)]) as $gr
   | ($gr | length) as $n | ([$gr[] | select(.status == "pass")] | length) as $s
   | {level: $g[0].level, vendor: $g[0].vendor, modelId: $g[0].modelId, effort: $g[0].effort,
      models: ([$g[] | .model] | unique),
      n: $n, passes: $s, rate: (if $n == 0 then null else $s / $n end), wilsonLB: wilson($s; $n), wilsonUB: wilsonUB($s; $n),
      excluded: (($g | length) - $n),
      meanTokens: ([$g[] | .totalTokens | numbers] | mean), meanSeconds: ([$g[] | .seconds | numbers] | mean),
      firstTs: ([$g[] | .ts | strings] | min), lastTs: ([$g[] | .ts | strings] | max)}
   | .role = role(.)] as $groups
| [ $incs[] as $i
    | ([$groups[] | select(.level == $i.level and .vendor == $i.vendor and .modelId == $i.modelId and .effort == $i.effort)] | first
       // {level: $i.level, vendor: $i.vendor, modelId: $i.modelId, effort: $i.effort, n: 0, passes: 0, rate: null, wilsonLB: null}) as $inc
    | $groups[] | select(.level == $i.level and .vendor == $i.vendor and ((.modelId == $i.modelId and .effort == $i.effort) | not))
    | . as $ch | direction($ch; $inc) as $dir
    | need($inc.n) as $ni | need($ch.n) as $nc
    | {level: $i.level, vendor: $i.vendor, incumbent: $inc, challenger: $ch, direction: $dir, needIncumbent: $ni, needChallenger: $nc}
    | if $dir == "unranked" then .verdict = "unranked" | .why = "cheapness unknown or equal (no family token, or same family and effort) — never proposed"
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
    | (map(select(.direction == "pricier")) | sort_by([-(.challenger.rate), cheap_key(.challenger.vendor; .challenger.modelId; .challenger.effort)]) | first) as $up
    | (map(select(.direction == "cheaper")) | sort_by([cheap_key(.challenger.vendor; .challenger.modelId; .challenger.effort), -(.challenger.wilsonLB)]) | first) as $down
    | ($up // $down)
    | {level, vendor, direction, from: {model: .incumbent.modelId, effort: .incumbent.effort}, to: {model: .challenger.modelId, effort: .challenger.effort},
       incumbent: {n: .incumbent.n, rate: .incumbent.rate}, challenger: {n: .challenger.n, rate: .challenger.rate, wilsonLB: .challenger.wilsonLB}, why} ] as $proposals
# Sampling rate per level (header: Rates) — from the same groups and proposals.
| [ LEVELS[] as $L
    | ($challengers[$L] // {}) as $chL
    | if ([$chL[]? | arrays | length] | add // 0) == 0
      then {key: $L, value: {state: "none", rate: 0, reason: "no challenger configured at \($L)"}}
      else
        ([(($levels[$L] // {}) | to_entries[] | select(.value | type == "object") | .key), ($chL | keys[])] | unique) as $vs
        | [ $vs[] as $V
            | ([($incs[] | select(.level == $L and .vendor == $V) | {modelId, effort}),
                ($chcfg[] | select(.level == $L and .vendor == $V) | {modelId, effort})] | unique) as $cfgs
            | (($cfgs[] | . as $c
                 | ([$groups[] | select(.level == $L and .vendor == $V and .modelId == $c.modelId and .effort == $c.effort)] | first
                    // {n: 0, wilsonLB: null, wilsonUB: null}) as $g
                 | "\($V) \($c.modelId)@\($c.effort)" as $who
                 | if $g.n < $minN then "\($who) n=\($g.n) < \($minN)"
                   elif ($g.wilsonUB - $g.wilsonLB) > $maxWidth + 1e-12 then "\($who) CI width \(($g.wilsonUB - $g.wilsonLB) * 1000 | round / 1000) > \($maxWidth)"
                   else empty end),
               ($proposals[] | select(.level == $L and .vendor == $V)
                 | "proposal pending for \($L)/\($V): \(.from.model)@\(.from.effort) -> \(.to.model)@\(.to.effort)")) ] as $gaps
        | if ($gaps | length) == 0
          then {key: $L, value: {state: "maintain", rate: $maintainRate,
                reason: "settled: every incumbent and challenger at n >= \($minN), Wilson 95% CI width <= \($maxWidth), no proposal"}}
          else {key: $L, value: {state: "explore", rate: $exploreRate, reason: ($gaps | join("; "))}} end
      end ] | from_entries as $rateLevels
# History — per level x vendor, every modelId x effort ever graded there (old
# versions included), with the current incumbent named even before it has data.
| [ ([$groups[] | {level, vendor}] + [$incs[] | {level, vendor}]) | unique[] as $lv
    | ([$incs[] | select(.level == $lv.level and .vendor == $lv.vendor)] | first) as $cur
    | ([$groups[] | select(.level == $lv.level and .vendor == $lv.vendor)]) as $ents
    | select(($ents | length) > 0 or ($fModel == "" and $fSince == ""))
    | {level: $lv.level, vendor: $lv.vendor,
       current: (if $cur == null then null else {modelId: $cur.modelId, effort: $cur.effort,
                 seen: any($ents[]; .modelId == $cur.modelId and .effort == $cur.effort)} end),
       entries: [$ents | sort_by([.firstTs, .modelId, .effort])[]
         | {modelId, effort, models, n, passes, rate, wilsonLB, wilsonUB, excluded, firstTs, lastTs, role}]} ]
  | sort_by([(.level as $x | LEVELS | index($x) // 9), .vendor]) as $history
| [ $rv[] | . as $l | select($l.ts | keep_ts) | .reviewers[] | select(type == "object")
    | {vendor, model, modelId: rid($l.ts | date_of), effort, status, precision: (.precision | num_or_null), recall: (.recall | num_or_null)}
    | select(.modelId | keep_model) ]
  | group_by([.vendor, .modelId, .effort])
  | map(. as $g | {vendor: $g[0].vendor, modelId: $g[0].modelId, effort: $g[0].effort, models: ([$g[] | .model] | unique),
        reviews: ([$g[] | select(.status == "ok")] | length), unavailable: ([$g[] | select(.status != "ok")] | length),
        meanPrecision: ([$g[] | .precision | numbers] | mean), nPrecision: ([$g[] | .precision | numbers] | length),
        meanRecall: ([$g[] | .recall | numbers] | mean), nRecall: ([$g[] | .recall | numbers] | length)}) as $rgroups
| {ledger: $ledger, tiers: $tiersPath, lines: $total, malformed: ($total - ($ok | length) - ($rv | length)),
   filters: {model: (if $fModel == "" then null else $fModel end), since: (if $fSince == "" then null else $fSince end)},
   rule: {minN: $minN, cheaperTolerance: $tol, pricierMargin: $margin, confidence: "wilson95"},
   groups: $groups, decisions: $decisions, proposals: $proposals,
   sampling: {asOf: $asOf, params: {explore: $exploreRate, maintain: $maintainRate, maxWidth: $maxWidth, minN: $minN},
              levels: $rateLevels, rates: ($rateLevels | map_values(.rate))},
   history: $history,
   reviews: {lines: ($rv | length), groups: $rgroups,
             note: "review bake-offs (source inline-review) are reported separately from build pass rates and do not drive tier proposals yet"},
   note: "proposal only: parity-report.sh never writes tiers.json; Alex approves every change"}
'

MARKDOWN='
def f3: if . == null then "—" else (. * 1000 | round / 1000 | tostring) end;
def fi: if . == null then "—" else (. | round | tostring) end;
def me: (.modelId // .model // "default") + (if .effort then " · " + .effort else "" end);
. as $R
| ["# Parity report", "",
   "ledger: \(.ledger) (\(.lines) line(s)\(if .malformed > 0 then ", \(.malformed) malformed skipped" else "" end)) · tiers: \(.tiers)",
   "rule: minN \(.rule.minN) · cheaper: Wilson 95% LB >= incumbent rate - \(.rule.cheaperTolerance) · pricier: rate - incumbent rate >= \(.rule.pricierMargin)",
   "Only pass/fail count; unavailable/invalid/denied/unresolved/ungraded/skipped are excluded (Excl.). Rows are keyed by the concrete model id."]
  + (if .filters.model != null or .filters.since != null then ["filters: model \(.filters.model // "any") · since \(.filters.since // "any")"] else [] end)
  + ([ "quick","builder","deep","top" ] | map(. as $L | ($R.groups | map(select(.level == $L))) as $g
      | if ($g | length) == 0 then empty else
        ["", "## \($L)", "", "| Vendor | Model id | Effort | n | Pass | Rate | Wilson LB | Excl. | Mean tokens | Mean s | |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
        + ($g | sort_by([.vendor, .modelId, .effort]) | map("| \(.vendor) | \(.modelId // "—") | \(.effort // "—") | \(.n) | \(.passes) | \(.rate | f3) | \(.wilsonLB | f3) | \(.excluded) | \(.meanTokens | fi) | \(.meanSeconds | fi) | \(if .role == "incumbent" then "incumbent" else "" end) |"))
      end) | add // [])
  + ["", "## Decisions", ""]
  + (if (.decisions | length) == 0 then ["No challenger measured against an incumbent yet."] else
      ["| Level | Vendor | Incumbent (n, rate) | Challenger (n, rate) | Direction | Verdict | Why |", "|---|---|---|---|---|---|---|"]
      + (.decisions | map("| \(.level) | \(.vendor) | \(.incumbent | me) (\(.incumbent.n), \(.incumbent.rate | f3)) | \(.challenger | me) (\(.challenger.n), \(.challenger.rate | f3)) | \(.direction) | \(.verdict) | \(.why) |")) end)
  + ["", "## Proposals", ""]
  + (if (.proposals | length) == 0 then ["None: no challenger clears the rule."] else
      (.proposals | map("- \(.level)/\(.vendor): \(.from | me) -> \(.to | me) (\(.direction); \(.why))")) end)
  + ["", "## Sampling rates (inline bake-offs)", "",
     "explore \(.sampling.params.explore) · maintain \(.sampling.params.maintain) (all n >= \(.sampling.params.minN), CI width <= \(.sampling.params.maxWidth), no proposal)", "",
     "| Level | State | Rate | Reason |", "|---|---|---|---|"]
  + (.sampling.levels | to_entries | map("| \(.key) | \(.value.state) | \(.value.rate) | \(.value.reason) |"))
  + ["", "## Reviews (inline-review) — separate from build pass rates", ""]
  + (if (.reviews.groups | length) == 0 then ["No review bake-offs ingested yet."] else
      ["| Vendor | Model id | Effort | Reviews | Mean precision (n) | Mean recall (n) | Unavailable |", "|---|---|---|---|---|---|---|"]
      + (.reviews.groups | sort_by([.vendor, .modelId, .effort]) | map("| \(.vendor) | \(.modelId // "—") | \(.effort // "—") | \(.reviews) | \(.meanPrecision | f3) (\(.nPrecision)) | \(.meanRecall | f3) (\(.nRecall)) | \(.unavailable) |")) end)
  + ["Review metrics do not drive tier proposals yet: the proposals above come from build pass rates only."]
  + ["", "Proposal only: parity-report.sh never writes tiers.json. Alex approves every change (edit config/tiers.json, make tiers, make verify)."]
| .[]
'

HISTORY_MD='
def f3: if . == null then "—" else (. * 1000 | round / 1000 | tostring) end;
def d: if . == null then "—" else .[0:10] end;
["# Parity history", "",
 "ledger: \(.ledger) · tiers: \(.tiers)\(if .filters.model != null or .filters.since != null then " · filters: model \(.filters.model // "any"), since \(.filters.since // "any")" else "" end)",
 "Every model id x effort ever graded at each level x vendor; old versions stay listed. Only pass/fail count."]
+ (if (.history | length) == 0 then ["", "No graded build runs match."] else
   (.history | map(
     ["", "## \(.level) / \(.vendor) — current: \(if .current == null then "none (no tiers entry)" else "\(.current.modelId) · \(.current.effort)\(if .current.seen then "" else " (no data yet)" end)" end)", ""]
     + (if (.entries | length) == 0 then ["No graded runs yet."] else
        ["| Model id | Effort | n | Pass | Rate | Wilson LB | Wilson UB | First | Last | |", "|---|---|---|---|---|---|---|---|---|---|"]
        + (.entries | map("| \(.modelId // "—") | \(.effort // "—") | \(.n) | \(.passes) | \(.rate | f3) | \(.wilsonLB | f3) | \(.wilsonUB | f3) | \(.firstTs | d) | \(.lastTs | d) | \(if .role == "incumbent" then "current" elif .role == "challenger" then "challenger" else "" end) |"))
       end)) | add)
   end)
| .[]
'

compute_report() { # -> $TMP/report.json
  local lines="$TMP/ledger"
  if [ -f "$LEDGER" ]; then cp "$LEDGER" "$lines"; else : > "$lines"; fi
  jq -R -s -c 'split("\n") | map(select(test("\\S")))' "$lines" > "$TMP/lines.json"
  jq -n -c --argjson cfg "$CFG" --argjson ah "$AH" --arg today "$TODAY" --arg fModel "$FMODEL" --arg fSince "$FSINCE" \
     --slurpfile lines "$TMP/lines.json" --arg ledger "$LEDGER" --arg tiersPath "$TIERS" "$DEFS"'
    $cfg.levels as $levels | $cfg.tuning.rule.minN as $minN | $cfg.tuning.rule.cheaperTolerance as $tol
    | $cfg.tuning.rule.pricierMargin as $margin | $lines[0] as $lines
    | $cfg.tuning.challengers as $challengers | $cfg.tuning.sampleRate as $exploreRate
    | $cfg.tuning.maintain.rate as $maintainRate | $cfg.tuning.maintain.maxWidth as $maxWidth | ($cfg.asOf // null) as $asOf
    | '"$REPORT" > "$TMP/report.json" 2>"$TMP/err" || { echo "parity-report: report failed: $(head -c 400 "$TMP/err")" >&2; exit 2; }
}

do_rates() {
  compute_report
  if [ "$JSON" -eq 1 ]; then
    jq -c .sampling "$TMP/report.json"
  else
    jq -r '.sampling.levels | to_entries[] | "\(.key)\t\(.value.state)\t\(.value.rate)\t\(.value.reason)"' "$TMP/report.json"
  fi
}

do_report() {
  compute_report
  if [ "$JSON" -eq 1 ]; then
    cat "$TMP/report.json"
  else
    jq -r "$MARKDOWN" "$TMP/report.json"
  fi
}

do_history() {
  compute_report
  if [ "$JSON" -eq 1 ]; then
    jq -c '{ledger, tiers, lines, filters, history}' "$TMP/report.json"
  else
    jq -r "$HISTORY_MD" "$TMP/report.json"
  fi
}

case "$SUB" in
  ingest-compare)   do_ingest_compare ;;
  ingest-parity)    do_ingest_parity ;;
  ingest-review)    do_ingest_review ;;
  migrate)          do_migrate ;;
  backfill-modelid) do_backfill ;;
  report)           do_report ;;
  history)          do_history ;;
  rates)            do_rates ;;
  *)                usage "parity-report.sh ingest-compare|ingest-parity|ingest-review|migrate|backfill-modelid|report|history|rates [options] (see the header)" ;;
esac
