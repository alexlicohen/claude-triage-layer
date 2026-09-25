#!/bin/bash
# Hermetic test suite for scripts/parity-report.sh — the parity ledger and the
# tier-change decision rule. Everything runs under one mktemp -d root with HOME
# pointed into it; nothing here reads or writes ~/.agents, the real tiers file or
# the network.
#
# Covers: ingest-compare / ingest-parity ledger shapes (exact keys, defaults from
# the tiers file, statuses kept verbatim, only graded parity rows); input refusals
# that write nothing; no target-repo content (patch paths, tails, diffstats,
# briefs) in any ledger line; legacy migrate + its idempotence; Wilson 95% lower
# bounds; the rule — cheaper via the Wilson LB (not the point rate), pricier via
# the margin, insufficient-n with the runs still needed, unranked; exclusion of
# non-graded statuses; markdown/JSON output; and that tiers.json is never written.
# ingest-review (RV*): the review line schema, precision/recall recomputed from the
# items (disputed excluded, --resolved applied), unavailable never zero, no review
# content in the ledger, idempotence, and a report section kept apart from the
# build rule (which review lines never change).
# Model versions (MV*): modelId/modelIdSource per ingest case, the alias-date
# boundary, backfill-modelid (dry run, by-date, untouched rows, idempotence), two
# versions under one alias kept apart, pinned edit / moved alias -> n=0, the
# history view + --model/--since, and family cheapness with versioned ids.
# shellcheck disable=SC2034  # *_SUM, L1 etc. are read inside chk's eval'd conditions
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PR="$REPO_DIR/scripts/parity-report.sh"

command -v jq >/dev/null 2>&1 || { echo "INCOMPLETE: jq is required to run this suite." >&2; exit 1; }
[ -x "$PR" ] || { echo "INCOMPLETE: $PR is missing or not executable." >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
unset TRIAGE_TIERS
# The alias-resolution date is pinned (MV6b/LI13 depend on it); LI13 varies it.
export PARITY_TODAY=2026-09-25
unset PARITY_LOCK_TRIES

OUT=""; ERR=""; RC=0
chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; echo "      rc=$RC out: $(printf '%s' "$OUT" | head -3) err: $(printf '%s' "$ERR" | head -3)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
run_pr() { OUT=$("$PR" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
j() { printf '%s\n' "$OUT" | jq -r "$1"; }
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

TIERS="$T/tiers.json"
cp "$REPO_DIR/config/tiers.json" "$TIERS"
TIERS_SUM=$(cksum < "$TIERS")
DEFAULT_LEDGER="$HOME/.agents/parity/ledger.jsonl"

# --- R1: ingest-compare -------------------------------------------------------
cat > "$T/compare.json" <<'EOF'
{"base":"HEAD","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","leak":false,"baseMoved":false,"graded":true,
 "candidates":[
  {"label":"claude-builder","vendor":"claude","level":"builder","model":null,"effort":null,"status":"pass","applies":true,"rc":0,
   "diffstat":"src/SECRETFILE.py | 3 +","patch":"/work/SECRETREPO/cmp/claude-builder.patch","outTokens":900,"totalTokens":null,"seconds":null,
   "selfRc":0,"tail":"SECRET brief text echoed by the checks"},
  {"label":"codex-sol","vendor":"codex","level":"builder","model":"gpt-6-sol","effort":"medium","status":"fail","applies":true,"rc":1,
   "diffstat":"x","patch":"/work/SECRETREPO/cmp/codex-sol.patch","outTokens":10,"totalTokens":1000,"seconds":10,"tail":"SECRET"},
  {"label":"agy-pro","vendor":"agy","level":"builder","model":null,"effort":null,"status":"unavailable","applies":null,"rc":null,
   "diffstat":null,"patch":null,"outTokens":null,"totalTokens":null,"seconds":null,"tail":"UNAVAILABLE SECRET"}]}
EOF
run_pr ingest-compare --tiers "$TIERS" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run cmp-r1 \
  --task sub-1 --applied claude-builder --ts 2026-09-24T10:00:00Z
L1=$(head -n 1 "$DEFAULT_LEDGER" 2>/dev/null)
chk "R1 ingest-compare appends ONE line to the tiers file's tuning.ledger (~ = HOME) and says so" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$DEFAULT_LEDGER")" = 1 ] && [ "$(j .ledger)" = "$DEFAULT_LEDGER" ] && [ "$(j .graded)" = 2 ]'
chk "R1b the line has exactly the schema keys, with the passed ts/source/repoName/level/task/applied" \
  '[ "$(printf "%s" "$L1" | jq -c "keys")" = "[\"applied\",\"candidates\",\"level\",\"repoName\",\"run\",\"runHash\",\"source\",\"task\",\"ts\",\"v\"]" ] &&
   [ "$(printf "%s" "$L1" | jq -r "[.v,.ts,.source,.repoName,.level,.task,.applied] | map(tostring) | join(\" \")")" = "1 2026-09-24T10:00:00Z inline myrepo builder sub-1 claude-builder" ]'
chk "R1c each candidate has exactly label/vendor/model/effort/status/totalTokens/seconds + modelId/modelIdSource" \
  '[ "$(printf "%s" "$L1" | jq -c "[.candidates[] | keys] | unique")" = "[[\"effort\",\"label\",\"model\",\"modelId\",\"modelIdSource\",\"seconds\",\"status\",\"totalTokens\",\"vendor\"]]" ]'
chk "R1d a null model/effort is filled from the tiers file (claude builder = claude-sonnet-5/medium); a retired agy row is still ingested, left null (no tiers entry)" \
  '[ "$(printf "%s" "$L1" | jq -r ".candidates[0] | .model + \"/\" + .effort")" = "claude-sonnet-5/medium" ] && [ "$(printf "%s" "$L1" | jq -r ".candidates[2].vendor")" = agy ] && [ "$(printf "%s" "$L1" | jq -r ".candidates[2].model")" = null ] && [ "$(printf "%s" "$L1" | jq -r ".candidates[2].effort")" = null ]'
chk "R1e a non-graded status is kept as itself (unavailable), never recorded as a fail" \
  '[ "$(printf "%s" "$L1" | jq -r "[.candidates[].status] | join(\",\")")" = "pass,fail,unavailable" ]'
chk "R1f no target-repo content: no patch path, diffstat, tail or brief text reaches the ledger" \
  '! grep -qi "secret" "$DEFAULT_LEDGER" && ! grep -q "/work" "$DEFAULT_LEDGER" && ! grep -q "diffstat\|patch\|tail" "$DEFAULT_LEDGER"'

LEDGER="$T/l-refuse.jsonl"
for bad in "--repo-name /work/SECRETREPO" "--repo-name a/b" "--task a/b/c.py" "--source nightly" "--level expert" "--applied nobody" "--ts yesterday"; do
  # shellcheck disable=SC2086  # $bad is deliberately split into flag + value
  run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run cmp-r2 $bad
  chk "R2 ingest-compare refuses [$bad] with exit 2 and writes nothing" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
done
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run cmp-r2 --task "brief text with spaces"
chk "R2a a --task that is text, not an id token, is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ] && printf "%s" "$ERR" | grep -q "id token"'
printf '{"ranking":[],"tasks":[]}\n' > "$T/notcompare.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/notcompare.json" --repo-name myrepo --level builder --source inline --run cmp-r2
chk "R2b a result with no candidates array is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
jq '.candidates[0].label = "has space"' "$T/compare.json" > "$T/badlabel.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/badlabel.json" --repo-name myrepo --level builder --source inline --run cmp-r2
chk "R2c a candidate label that is not an id token is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run cmp-r2
chk "R2d without --ts the line still gets an ISO UTC timestamp" \
  '[ "$RC" -eq 0 ] && jq -r .ts "$LEDGER" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"'

# --- R3: ingest-parity --------------------------------------------------------
cat > "$T/parity.json" <<'EOF'
{"outDir":"/o/runs/par-1","bands":[1,3],
 "ranking":[{"label":"a","vendor":"claude","level":"builder","model":null,"effort":null},
            {"label":"x","vendor":"codex","level":"deep","model":"gpt-6-astra","effort":"high"}],
 "tasks":[
  {"band":1,"id":"t1","kind":"build","results":[
     {"label":"a","runLabel":"a","vendor":"claude","status":"pass","patch":"/o/runs/par-1/1/t1/cmp/a.patch","totalTokens":null,"seconds":null},
     {"label":"a","runLabel":"a-r2","vendor":"claude","status":"fail","patch":"/o/runs/par-1/1/t1/cmp/a-r2.patch","totalTokens":null,"seconds":null},
     {"label":"x","runLabel":"x","vendor":"codex","status":"unavailable","reason":"SECRET","totalTokens":5,"seconds":1}]},
  {"band":3,"id":"t3","kind":"build","results":[
     {"label":"x","runLabel":"x","vendor":"codex","status":"pass","model":"gpt-6-astra","patch":"/o/runs/par-1/3/t3/cmp/x.patch","totalTokens":100,"seconds":3},
     {"label":"a","runLabel":"a","vendor":"claude","status":"skipped","reason":"task allows codex"}]}],
 "markdown":"SECRET","flags":[]}
EOF
PL="$T/l-parity.jsonl"
run_pr ingest-parity --tiers "$TIERS" --ledger "$PL" --result "$T/parity.json" --ts 2026-09-24T11:00:00Z
chk "R3 ingest-parity writes one line per GRADED (task, candidate run) only: 3 of 5 rows" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$PL")" = 3 ] && [ "$(j .lines)" = 3 ] && [ "$(j .run)" = par-1 ]'
chk "R3b suite lines: source suite, run = outDir basename, level = the band's level, band + task id kept" \
  '[ "$(jq -r "[.source,.run,.level,(.band|tostring),.task,.repoName] | join(\" \")" "$PL" | sort -u | paste -sd"|" -)" = "suite par-1 deep 3 t3 parity-suite|suite par-1 quick 1 t1 parity-suite" ]'
chk "R3c rep labels are kept (a, a-r2), models/efforts resolved from the candidate's own level (a = builder claude-sonnet-5/medium)" \
  '[ "$(jq -r ".candidates[0] | .label + \":\" + .model + \":\" + .effort + \":\" + .status" "$PL" | paste -sd, -)" = "a:claude-sonnet-5:medium:pass,a-r2:claude-sonnet-5:medium:fail,x:gpt-6-astra:high:pass" ]'
chk "R3d no patch path, reason or markdown from the run reaches the ledger" '! grep -qi "secret\|patch\|/o/runs" "$PL"'
run_pr ingest-parity --tiers "$TIERS" --ledger "$PL" --result "$T/parity.json"
chk "R3e ingesting the same run again is a no-op (idempotent by run id)" '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(nlines "$PL")" = 3 ]'

# --- R4: legacy migrate + idempotence -------------------------------------------
cat > "$T/legacy.jsonl" <<'EOF'
{"date":"2026-09-20","repo":"toy-repo","level":"builder","task":"smoke: a toy task","candidates":[{"label":"claude-builder","status":"pass","outTokens":10},{"label":"codex-quick","model":"gpt-6-luna","status":"fail","totalTokens":7,"seconds":2}],"why":"toy"}
{"date":"2026-09-21","run":"pilot wf_1","bands":[1,2],"suite":"x","candidates":[{"label":"codex-sol-medium","b1":{"pass":2,"fail":1,"other":1,"rate":0.66},"b2":{"pass":1,"fail":0,"other":0,"rate":1},"externalTokens":5},{"label":"agy-pro","b2":{"pass":0,"fail":2,"other":0,"rate":0}}]}
EOF
ML="$T/l-migrate.jsonl"
run_pr migrate --tiers "$TIERS" --ledger "$ML" --from "$T/legacy.jsonl"
chk "R4 migrate: 1 compare line + (2+1+1)+(2) per-outcome parity lines = 7, both legacy lines migrated" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$ML")" = 7 ] && [ "$(j .migrated)" = 2 ] && [ "$(j .skipped)" = 0 ]'
chk "R4b the parity aggregate becomes pass/fail lines per band with the band's level and a resolved model (a retired agy label keeps its own model token: agy has no tiers entry)" \
  '[ "$(jq -r "select(.band) | [.level, .candidates[0].model, (.candidates[0].effort // \"-\"), .candidates[0].status] | join(\":\")" "$ML" | sort | uniq -c | tr -s " " | paste -sd, -)" = " 1 builder:gpt-6-sol:medium:pass, 2 builder:pro:-:fail, 1 quick:gpt-6-sol:medium:fail, 2 quick:gpt-6-sol:medium:pass" ]'
chk "R4c every migrated line is marked, carries a legacy run id, and keeps no task text" \
  '[ "$(jq -r ".migrated" "$ML" | sort -u)" = vendor-parity.jsonl ] && [ "$(jq -r ".run" "$ML" | sort -u | paste -sd"|" -)" = "legacy:2026-09-20:toy-repo:builder|legacy:pilot wf_1" ] && ! grep -q "smoke" "$ML"'
run_pr migrate --tiers "$TIERS" --ledger "$ML" --from "$T/legacy.jsonl"
chk "R4d migrate again: nothing appended (idempotent by run id)" '[ "$RC" -eq 0 ] && [ "$(nlines "$ML")" = 7 ] && [ "$(j .migrated)" = 0 ] && [ "$(j .skipped)" = 2 ]'
printf '%s\n' '{"date":"2026-09-22","run":"pilot2","bands":[4],"candidates":[{"label":"claude-fable-xhigh","b4":{"pass":1,"fail":0}}]}' >> "$T/legacy.jsonl"
run_pr migrate --tiers "$TIERS" --ledger "$ML" --from "$T/legacy.jsonl"
chk "R4e a legacy line added later is the only one migrated next time" '[ "$(nlines "$ML")" = 8 ] && [ "$(j .migrated)" = 1 ] && [ "$(tail -n 1 "$ML" | jq -r ".level + \":\" + .candidates[0].model")" = top:claude-fable-5-1 ]'

# --- R5..R8: the report + decision rule on a synthetic ledger -------------------
RL="$T/l-rule.jsonl"
# gen LEVEL VENDOR MODEL EFFORT STATUS COUNT — COUNT single-candidate lines.
gen() {
  local i=0
  while [ "$i" -lt "$6" ]; do
    jq -nc --arg l "$1" --arg v "$2" --arg m "$3" --arg e "$4" --arg s "$5" \
      '{v:1, ts:"2026-09-24T00:00:00Z", source:"inline", run:null, repoName:"r", level:$l, task:null,
        candidates:[{label:"c", vendor:$v, model:$m, effort:(if $e == "-" then null else $e end), status:$s, totalTokens:100, seconds:2}], applied:null}' >> "$RL"
    i=$((i + 1))
  done
}
# builder/claude: incumbent sonnet·medium 36/40; cheaper haiku·low 40/40 (LB .912 >= .85) -> propose.
gen builder claude sonnet medium pass 36; gen builder claude sonnet medium fail 4
gen builder claude haiku low pass 40
# builder/claude: excluded statuses never count (5 unavailable + 3 invalid + 1 ungraded on the incumbent).
gen builder claude sonnet medium unavailable 5; gen builder claude sonnet medium invalid 3; gen builder claude sonnet medium ungraded 1
# deep/claude: incumbent opus·high 9/10; cheaper sonnet·high 10/10 — rate 1.0 but LB .7225 < .85 -> keep.
gen deep claude opus high pass 9; gen deep claude opus high fail 1
gen deep claude sonnet high pass 10
# quick/claude: incumbent haiku·low 5/10; pricier sonnet·medium 9/10 (+.4 >= .15) -> propose.
gen quick claude haiku low pass 5; gen quick claude haiku low fail 5
gen quick claude sonnet medium pass 9; gen quick claude sonnet medium fail 1
# top/codex: incumbent gpt-6-astra·xhigh 36/40; pricier astra·max 40/40 (+.1 < .15) -> keep.
gen top codex gpt-6-astra xhigh pass 36; gen top codex gpt-6-astra xhigh fail 4
gen top codex gpt-6-astra max pass 40
# builder/codex: incumbent gpt-6-sol·medium 3/3; cheaper luna·low 7/7 -> insufficient (needs 5 and 1).
gen builder codex gpt-6-sol medium pass 3
gen builder codex gpt-6-luna low pass 7
# deep/codex: an unknown model is unranked; Wilson fixtures 5/10 and 0/10.
gen deep codex gpt-7-x high pass 10
gen deep codex gpt-6-sol medium pass 5; gen deep codex gpt-6-sol medium fail 5
gen deep codex gpt-6-luna low fail 10
printf 'not json at all\n' >> "$RL"
RL_SUM=$(cksum < "$RL")
# The rule fixtures above use challengers the shipped tiers do not configure; only
# CURRENT (configured) ids are challengers (M26), so this tiers copy configures them.
TIERS_RULE="$T/tiers-rule.json"
jq '.tuning.challengers.builder.claude += [{"model": "claude-haiku-4-5-20251001", "effort": "low"}]
  | .tuning.challengers.builder.codex += [{"model": "gpt-6-luna", "effort": "low"}]
  | .tuning.challengers.deep.codex += [{"model": "gpt-7-x", "effort": "high"}, {"model": "gpt-6-luna", "effort": "low"}]' "$TIERS" > "$TIERS_RULE"

run_pr report --tiers "$TIERS_RULE" --ledger "$RL" --json
REP="$OUT"
g() { printf '%s' "$REP" | jq -r --arg l "$1" --arg v "$2" --arg m "$3" --arg e "$4" \
  ".groups[] | select(.level == \$l and .vendor == \$v and .modelId == \$m and .effort == \$e) | $5"; }
d() { printf '%s' "$REP" | jq -r --arg l "$1" --arg v "$2" --arg m "$3" --arg e "$4" \
  ".decisions[] | select(.level == \$l and .vendor == \$v and .challenger.modelId == \$m and .challenger.effort == \$e) | $5"; }
chk "R5 report --json exits 0; the malformed ledger line is counted, not fatal" '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$REP" | jq .malformed)" = 1 ]'
chk "R5b Wilson 95% lower bounds: 10/10 = 0.7225, 40/40 = 0.9124, 5/10 = 0.2366, 0/10 = 0, 9/10 = 0.5958" \
  '[ "$(g deep claude claude-sonnet-5 high ".wilsonLB * 10000 | round")" = 7225 ] && [ "$(g builder claude claude-haiku-4-5-20251001 low ".wilsonLB * 10000 | round")" = 9124 ] &&
   [ "$(g deep codex gpt-6-sol medium ".wilsonLB * 10000 | round")" = 2366 ] && [ "$(g deep codex gpt-6-luna low ".wilsonLB")" = 0 ] &&
   [ "$(g deep claude claude-opus-5-5 high ".wilsonLB * 10000 | round")" = 5958 ]'
chk "R5c non-graded statuses are excluded: the sonnet·medium incumbent stays n=40 (36 pass) with 9 excluded" \
  '[ "$(g builder claude claude-sonnet-5 medium "[.n, .passes, .excluded] | join(\",\")")" = "40,36,9" ] && [ "$(g builder claude claude-sonnet-5 medium .rate)" = 0.9 ]'
chk "R5d tokens and seconds are averaged per group" '[ "$(g builder claude claude-haiku-4-5-20251001 low "[.meanTokens, .meanSeconds] | join(\",\")")" = "100,2" ]'
chk "R6 cheaper + Wilson LB >= incumbent rate - tolerance -> propose (builder/claude haiku·low)" \
  '[ "$(d builder claude claude-haiku-4-5-20251001 low ".direction + \":\" + .verdict")" = "cheaper:propose" ]'
chk "R6b cheaper with a perfect POINT rate but a low Wilson LB -> keep (deep/claude sonnet·high 10/10 vs opus 0.9)" \
  '[ "$(d deep claude claude-sonnet-5 high ".direction + \":\" + .verdict")" = "cheaper:keep" ]'
chk "R6c pricier past the margin -> propose (quick/claude sonnet·medium, +0.4)" \
  '[ "$(d quick claude claude-sonnet-5 medium ".direction + \":\" + .verdict")" = "pricier:propose" ]'
chk "R6d pricier below the margin -> keep, even with a high Wilson LB (top/codex astra·max, +0.1)" \
  '[ "$(d top codex gpt-6-astra max ".direction + \":\" + .verdict")" = "pricier:keep" ]'
chk "R6e fewer than minN graded runs on either side -> insufficient-data, naming the runs still needed (5 and 1)" \
  '[ "$(d builder codex gpt-6-luna low ".verdict + \":\" + (.needIncumbent|tostring) + \":\" + (.needChallenger|tostring)")" = "insufficient-data:5:1" ] &&
   d builder codex gpt-6-luna low .why | grep -q "needs 5 more graded run(s) of the incumbent and 1 of the challenger"'
chk "R6f a model outside the cheapness order is unranked, never proposed" '[ "$(d deep codex gpt-7-x high .verdict)" = unranked ]'
chk "R6g exactly two proposals: builder/claude -> haiku·low (cheaper), quick/claude -> sonnet·medium (pricier)" \
  '[ "$(printf "%s" "$REP" | jq -r "[.proposals[] | .level + \"/\" + .vendor + \"->\" + .to.model + \"·\" + .to.effort + \":\" + .direction] | join(\",\")")" = "builder/claude->claude-haiku-4-5-20251001·low:cheaper,quick/claude->claude-sonnet-5·medium:pricier" ]'
chk "R6h the JSON carries the rule it applied and says it never writes tiers.json" \
  '[ "$(printf "%s" "$REP" | jq -c ".rule")" = "{\"minN\":8,\"cheaperTolerance\":0.05,\"pricierMargin\":0.15,\"confidence\":\"wilson95\"}" ] && printf "%s" "$REP" | jq -r .note | grep -q "never writes tiers.json"'

# A pricier AND a cheaper qualifier at one level x vendor: the pricier one wins.
cp "$RL" "$T/l-both.jsonl"
RL_SAVE="$RL"; RL="$T/l-both.jsonl"
# deep/codex: incumbent astra·high 20/40; cheaper sol·low 40/40 (LB .912 >= .45) and
# pricier astra·xhigh 40/40 (+.5) both qualify.
gen deep codex gpt-6-astra high pass 20; gen deep codex gpt-6-astra high fail 20
gen deep codex gpt-6-sol low pass 40
gen deep codex gpt-6-astra xhigh pass 40
RL="$RL_SAVE"
run_pr report --tiers "$TIERS_RULE" --ledger "$T/l-both.jsonl" --json
chk "R6i with a qualifying cheaper AND pricier challenger at one level x vendor, ONE proposal: the pricier (quality first)" \
  '[ "$(printf "%s" "$OUT" | jq -r "[.decisions[] | select(.level == \"deep\" and .vendor == \"codex\" and .verdict == \"propose\") | .direction] | sort | join(\",\")")" = "cheaper,pricier" ] &&
   [ "$(printf "%s" "$OUT" | jq -r "[.proposals[] | select(.level == \"deep\" and .vendor == \"codex\")] | length")" = 1 ] &&
   [ "$(printf "%s" "$OUT" | jq -r ".proposals[] | select(.level == \"deep\" and .vendor == \"codex\") | .to.model + \"·\" + .to.effort")" = "gpt-6-astra·xhigh" ]'

run_pr report --tiers "$TIERS_RULE" --ledger "$RL"
chk "R7 markdown: a table per level, the incumbent marked, decisions with reasons, the proposals, and the never-writes line" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^## builder" && printf "%s" "$OUT" | grep -q "| claude | claude-sonnet-5 | medium | 40 | 36 | 0.9 | .* | 9 | .* | incumbent |" &&
   printf "%s" "$OUT" | grep -q "insufficient data: needs 5 more" && printf "%s" "$OUT" | grep -q "^- builder/claude: claude-sonnet-5 · medium -> claude-haiku-4-5-20251001 · low (cheaper" &&
   printf "%s" "$OUT" | grep -q "never writes tiers.json"'
run_pr report --tiers "$TIERS" --ledger "$T/none.jsonl"
chk "R7b an absent ledger reports no data (exit 0, no proposals)" '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "None: no challenger clears the rule"'

# --- R8: tiers.json is never written; invalid tuning is refused ---------------
run_pr report --tiers "$TIERS" --ledger "$TIERS"
chk "R8 a --ledger that IS the tiers file is refused (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "is the tiers file"'
run_pr ingest-compare --tiers "$TIERS" --ledger "$TIERS" --result "$T/compare.json" --repo-name r --level builder --source inline --run cmp-r8
chk "R8b ...also for an ingest (nothing appended to tiers.json)" '[ "$RC" -eq 2 ]'
chk "R8c after every subcommand above, the tiers file and the report's ledger are byte-identical" \
  '[ "$(cksum < "$TIERS")" = "$TIERS_SUM" ] && [ "$(cksum < "$RL")" = "$RL_SUM" ]'
jq '.tuning.rule.minN = 0' "$TIERS" > "$T/bad-tiers.json"
run_pr report --tiers "$T/bad-tiers.json" --ledger "$RL"
chk "R8d an invalid tuning block (minN 0) is refused (exit 2) via the one validator" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "no valid tuning block"'
jq 'del(.tuning)' "$TIERS" > "$T/no-tuning.json"
run_pr report --tiers "$T/no-tuning.json" --ledger "$RL"
chk "R8e a tiers file with no tuning block is refused (exit 2)" '[ "$RC" -eq 2 ]'
run_pr frobnicate --tiers "$TIERS"
chk "R8f an unknown subcommand is a usage error" '[ "$RC" -eq 2 ]'

# --- RV: ingest-review — review bake-off scores, kept apart from build rates ----
cat > "$T/review.json" <<'EOF'
{"kind":"review","repoName":"voron","base":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","head":"cccccccccccccccccccccccccccccccccccccccc","outDir":"/o/reviews/rv-run-1",
 "reviewers":[
  {"label":"rv-sonnet","vendor":"claude","level":"builder","model":null,"effort":null,"status":"ok","precision":0.5,"recall":0.5,"findings":3,"real":1,"rejected":1,"disputed":1,"tokens":null,"seconds":null},
  {"label":"rv-opus","vendor":"claude","level":"deep","model":"opus","effort":"high","status":"ok","precision":1,"recall":1,"findings":2,"real":2,"rejected":0,"disputed":0,"tokens":null,"seconds":null},
  {"label":"rv-sol","vendor":"codex","level":"deep","model":"gpt-6-sol","effort":"medium","status":"ok","precision":0.333,"recall":0.5,"findings":4,"real":1,"rejected":2,"disputed":1,"tokens":500,"seconds":12},
  {"label":"rv-astra","vendor":"codex","level":"deep","model":"gpt-6-astra","effort":"high","status":"unavailable","precision":null,"recall":null,"findings":null,"real":null,"rejected":null,"disputed":null,"tokens":null,"seconds":null,"reason":"SECRET rate limited"}],
 "items":[
  {"id":"M1","file":"docs/SECRETFILE.md","line":3,"severity":"major","category":"U1","claim":"SECRET claim","evidence":"SECRET evidence","suggestedFix":"x","verdict":"real","adjudication":[],"foundBy":["rv-opus","rv-sol","rv-sonnet"]},
  {"id":"M2","file":"docs/a.md","line":10,"severity":"minor","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"rejected","adjudication":[],"foundBy":["rv-sonnet"]},
  {"id":"M3","file":"docs/b.md","line":5,"severity":"blocker","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"disputed","adjudication":[],"foundBy":["rv-sonnet"]},
  {"id":"M4","file":"docs/b.md","line":8,"severity":"major","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"real","adjudication":[],"foundBy":["rv-opus"]},
  {"id":"M5","file":"docs/c.md","line":1,"severity":"major","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"rejected","adjudication":[],"foundBy":["rv-sol"]},
  {"id":"M6","file":"docs/c.md","line":2,"severity":"major","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"disputed","adjudication":[],"foundBy":["rv-sol"]},
  {"id":"M7","file":"docs/c.md","line":9,"severity":"major","category":"U1","claim":"c","evidence":"e","suggestedFix":"","verdict":"rejected","adjudication":[],"foundBy":["rv-sol"]}],
 "disputed":["M3","M6"],"sourceChanged":false,"flags":["SECRET flag"],"markdown":"SECRET markdown"}
EOF
VL="$T/l-review.jsonl"
run_pr ingest-review --tiers "$TIERS" --ledger "$VL" --result "$T/review.json" --repo-name voron --ts 2026-09-24T12:00:00Z
V1=$(head -n 1 "$VL" 2>/dev/null)
rv() { printf '%s' "$V1" | jq -r --arg l "$1" ".reviewers[] | select(.label == \$l) | $2"; }
chk "RV1 ingest-review appends ONE inline-review line with exactly the review schema keys (no candidates: never a build row)" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$VL")" = 1 ] && [ "$(printf "%s" "$V1" | jq -c "keys")" = "[\"disputed\",\"items\",\"real\",\"repoName\",\"resolved\",\"reviewers\",\"revision\",\"run\",\"runHash\",\"source\",\"ts\",\"v\"]" ] &&
   [ "$(printf "%s" "$V1" | jq -r "[.source,.repoName,.run,.items,.real,.disputed,.resolved] | map(tostring) | join(\" \")")" = "inline-review voron rv-run-1 7 2 2 0" ]'
chk "RV1b each reviewer has exactly label/vendor/level/model/effort/status/precision/recall/n/real/rejected/disputed/findings/totalTokens/seconds" \
  '[ "$(printf "%s" "$V1" | jq -c "[.reviewers[] | keys] | unique")" = "[[\"disputed\",\"effort\",\"findings\",\"label\",\"level\",\"model\",\"modelId\",\"modelIdSource\",\"n\",\"precision\",\"real\",\"recall\",\"rejected\",\"seconds\",\"status\",\"totalTokens\",\"vendor\"]]" ]'
chk "RV1c precision/recall/n recomputed from the items over non-disputed ones: sonnet 1/2 (n 2), opus 2/2, sol 1/3 (n 3); recall over 2 real" \
  '[ "$(rv rv-sonnet "[.precision,.recall,.n] | map(tostring) | join(\",\")")" = "0.5,0.5,2" ] && [ "$(rv rv-opus "[.precision,.recall,.n] | map(tostring) | join(\",\")")" = "1,1,2" ] &&
   [ "$(rv rv-sol "(.precision * 1000 | round | tostring) + \",\" + (.recall | tostring) + \",\" + (.n | tostring)")" = "333,0.5,3" ]'
chk "RV1d an unavailable reviewer keeps status unavailable with NULL scores and n 0 — never a zero precision" \
  '[ "$(rv rv-astra "[.status, (.precision|tostring), (.recall|tostring), (.n|tostring)] | join(\",\")")" = "unavailable,null,null,0" ]'
chk "RV1e a null model/effort is filled from the tiers file at its level (claude builder = claude-sonnet-5/medium); vendor tokens kept" \
  '[ "$(rv rv-sonnet ".model + \"/\" + .effort")" = "claude-sonnet-5/medium" ] && [ "$(rv rv-sol ".totalTokens")" = 500 ]'
chk "RV1f no review content reaches the ledger: no file path, claim, evidence, reason, flag or markdown" \
  '! grep -qi "secret" "$VL" && ! grep -q "docs/" "$VL" && ! grep -q "claim\|evidence\|markdown\|/o/reviews" "$VL"'
run_pr ingest-review --tiers "$TIERS" --ledger "$VL" --result "$T/review.json" --repo-name voron
chk "RV2 ingesting the same review again is a no-op (run = the outDir basename)" '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(nlines "$VL")" = 1 ]'

printf '{"M3":"real","M6":"not-real"}\n' > "$T/resolved.json"
VR="$T/l-review-resolved.jsonl"
run_pr ingest-review --tiers "$TIERS" --ledger "$VR" --result "$T/review.json" --repo-name voron --resolved "$T/resolved.json" --run rv-run-1b
V1=$(head -n 1 "$VR" 2>/dev/null)
chk "RV3 --resolved applies Alex's verdicts to disputed ids: M3 real, M6 not-real -> 3 real, 0 disputed, 2 resolved" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$V1" | jq -r "[.real,.disputed,.resolved,.run] | map(tostring) | join(\" \")")" = "3 0 2 rv-run-1b" ]'
chk "RV3b ...and the scores are recomputed with them: sonnet 2/3 & 2/3, sol 1/4 & 1/3, opus 1 & 2/3" \
  '[ "$(rv rv-sonnet "[(.precision*1000|round), (.recall*1000|round), .n] | map(tostring) | join(\",\")")" = "667,667,3" ] &&
   [ "$(rv rv-sol "[(.precision*1000|round), (.recall*1000|round), .n] | map(tostring) | join(\",\")")" = "250,333,4" ] &&
   [ "$(rv rv-opus "[(.precision*1000|round), (.recall*1000|round)] | map(tostring) | join(\",\")")" = "1000,667" ]'
VX="$T/l-review-refuse.jsonl"
printf '{"M1":"real"}\n' > "$T/res-notdisputed.json"
printf '{"M3":"maybe"}\n' > "$T/res-badvalue.json"
printf '["M3"]\n' > "$T/res-array.json"
for bad in res-notdisputed res-badvalue res-array; do
  run_pr ingest-review --tiers "$TIERS" --ledger "$VX" --result "$T/review.json" --repo-name voron --resolved "$T/$bad.json"
  chk "RV4 --resolved $bad is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$VX" ]'
done
run_pr ingest-review --tiers "$TIERS" --ledger "$VX" --result "$T/compare.json" --repo-name voron
chk "RV4b a build compare result is not a review result (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$VX" ]'
run_pr ingest-review --tiers "$TIERS" --ledger "$VX" --result "$T/review.json" --repo-name /work/SECRETREPO
chk "RV4c a --repo-name that is a path is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$VX" ]'

# report: the review section is separate, and review lines change nothing in the build rule.
run_pr report --tiers "$TIERS" --ledger "$RL" --json
BUILD_ONLY=$(printf '%s' "$OUT" | jq -c '[.groups, .decisions, .proposals]')
cat "$RL" "$VL" "$VR" > "$T/l-mixed.jsonl"
run_pr report --tiers "$TIERS" --ledger "$T/l-mixed.jsonl" --json
MIX="$OUT"
chk "RV5 review lines leave the build groups, decisions and proposals byte-identical, and are not counted as malformed" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$MIX" | jq -c "[.groups, .decisions, .proposals]")" = "$BUILD_ONLY" ] && [ "$(printf "%s" "$MIX" | jq .malformed)" = 1 ] &&
   ! printf "%s" "$MIX" | jq -e ".groups[] | select(.model == \"gpt-6-sol\" and .effort == \"medium\" and .level == null)" >/dev/null'
chk "RV5b a separate reviews section per vendor x model x effort: sonnet·medium over 2 reviews = mean precision (0.5+0.667)/2, mean recall (0.5+0.667)/2" \
  '[ "$(printf "%s" "$MIX" | jq -r ".reviews.lines")" = 2 ] &&
   [ "$(printf "%s" "$MIX" | jq -r ".reviews.groups[] | select(.vendor == \"claude\" and .modelId == \"claude-sonnet-5\") | [.reviews, (.meanPrecision*1000|round), (.meanRecall*1000|round), .nPrecision] | map(tostring) | join(\",\")")" = "2,583,583,2" ]'
chk "RV5c an unavailable reviewer counts as unavailable in its group, never as a zero in the means" \
  '[ "$(printf "%s" "$MIX" | jq -r ".reviews.groups[] | select(.modelId == \"gpt-6-astra\") | [.reviews, .unavailable, (.meanPrecision|tostring)] | map(tostring) | join(\",\")")" = "0,2,null" ]'
chk "RV5d the JSON says review metrics do not drive tier proposals yet" 'printf "%s" "$MIX" | jq -r .reviews.note | grep -q "do not drive tier proposals yet"'
run_pr report --tiers "$TIERS" --ledger "$T/l-mixed.jsonl"
chk "RV6 markdown: its own Reviews section with the table, the not-a-proposal-input line, after the build proposals" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^## Reviews (inline-review) — separate from build pass rates" &&
   printf "%s" "$OUT" | grep -q "^| claude | claude-opus-5-5 | high | 2 | 1 (2) | 0.833 (2) | 0 | 0 |$" &&
   printf "%s" "$OUT" | grep -q "Review metrics do not drive tier proposals yet" &&
   [ "$(printf "%s" "$OUT" | grep -n "^## Proposals" | cut -d: -f1)" -lt "$(printf "%s" "$OUT" | grep -n "^## Reviews" | cut -d: -f1)" ]'
run_pr report --tiers "$TIERS" --ledger "$RL"
chk "RV6b with no review lines the section says so" 'printf "%s" "$OUT" | grep -q "No review bake-offs ingested yet."'

# --- RA: rates — the per-level inline bake-off sampling rate --------------------
TT="$REPO_DIR/scripts/triage-tiers.sh"
# RT: the tuning.maintain schema, owned by triage-tiers.sh's TUNING_ERRORS.
NEEDLE=""
tt_bad() { # NAME JQ-EDIT NEEDLE
  jq "$2" "$TIERS" > "$T/rt.json"
  OUT=$(TRIAGE_TIERS="$T/rt.json" "$TT" --bakeoff-json 2>&1); RC=$?; ERR="$OUT"; NEEDLE="$3"
  chk "RT $1 -> invalid tuning (exit 2) naming it" '[ "$RC" -eq 2 ] && printf "%s" "$OUT" | grep -qF "$NEEDLE"'
}
OUT=$(TRIAGE_TIERS="$TIERS" "$TT" --bakeoff-json 2>&1); RC=$?; ERR=""
chk "RT the shipped tuning.maintain is valid and passed through (rate 0.05 <= sampleRate 0.2, maxWidth 0.35)" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -c .tuning.maintain)" = "{\"rate\":0.05,\"maxWidth\":0.35}" ]'
tt_bad "maintain missing" 'del(.tuning.maintain)' "tuning.maintain must be an object"
tt_bad "maintain.rate 0 (sampling would stop at a plateau)" '.tuning.maintain.rate = 0' "tuning.maintain.rate must be a number in (0, 1]"
tt_bad "maintain.rate a string" '.tuning.maintain.rate = "0.05"' "tuning.maintain.rate must be a number in (0, 1]"
tt_bad "maintain.rate above sampleRate" '.tuning.maintain.rate = 0.3' "must not exceed tuning.sampleRate"
tt_bad "maintain.maxWidth 0" '.tuning.maintain.maxWidth = 0' "tuning.maintain.maxWidth must be a number in (0, 1]"
tt_bad "maintain.maxWidth above 1" '.tuning.maintain.maxWidth = 1.5' "tuning.maintain.maxWidth must be a number in (0, 1]"
jq '.tuning.maintain.maxWidth = 0' "$TIERS" > "$T/rt-pr.json"
run_pr rates --tiers "$T/rt-pr.json" --ledger "$T/none.jsonl"
chk "RT parity-report rates refuses an invalid maintain block via the one validator (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "no valid tuning block"'
# TT (M31): one failing input per remaining TUNING_ERRORS / ALIAS_ERRORS branch.
tt_bad "tuning missing" 'del(.tuning)' "tuning: missing or not an object"
tt_bad "sampleRate 0" '.tuning.sampleRate = 0' "tuning.sampleRate must be a number in (0, 1]"
tt_bad "challengerMix empty" '.tuning.challengerMix = {}' "tuning.challengerMix must be a non-empty object"
tt_bad "challengerMix unknown vendor" '.tuning.challengerMix = {"agy": 0.2, "codex": 0.8}' "tuning.challengerMix: unknown vendor agy"
tt_bad "challengerMix share above 1" '.tuning.challengerMix = {"codex": 1.5, "claude": -0.5}' "tuning.challengerMix.codex must be a number in [0, 1]"
tt_bad "challengerMix shares not summing to 1" '.tuning.challengerMix = {"codex": 0.7, "claude": 0.2}' "tuning.challengerMix shares must sum to 1 (got 0."
tt_bad "challengers not an object" '.tuning.challengers = []' "tuning.challengers must be an object"
tt_bad "challengers unknown level" '.tuning.challengers.expert = {}' "tuning.challengers: unknown level expert"
tt_bad "challengers level not an object" '.tuning.challengers.builder = []' "tuning.challengers.builder must be an object"
tt_bad "challengers unknown vendor" '.tuning.challengers.builder.gemini = []' "tuning.challengers.builder: unknown vendor gemini"
tt_bad "challengers list not an array" '.tuning.challengers.builder.codex = {}' "tuning.challengers.builder.codex must be an array"
tt_bad "challenger entry not an object" '.tuning.challengers.builder.codex = ["gpt-6-sol"]' "tuning.challengers.builder.codex[0] must be an object"
tt_bad "challenger model not an id" '.tuning.challengers.builder.codex[0].model = "gpt 6"' "tuning.challengers.builder.codex[0].model must be a model id"
tt_bad "challenger effort unknown" '.tuning.challengers.builder.codex[0].effort = "ultra"' "tuning.challengers.builder.codex[0].effort must be one of"
tt_bad "rule not an object" '.tuning.rule = 8' "tuning.rule must be an object"
tt_bad "minN fractional" '.tuning.rule.minN = 2.5' "tuning.rule.minN must be an integer >= 1"
tt_bad "cheaperTolerance 1" '.tuning.rule.cheaperTolerance = 1' "tuning.rule.cheaperTolerance must be a number in [0, 1)"
tt_bad "pricierMargin 0" '.tuning.rule.pricierMargin = 0' "tuning.rule.pricierMargin must be a number in (0, 1]"
tt_bad "confidence not wilson95" '.tuning.rule.confidence = "normal"' "tuning.rule.confidence must be \"wilson95\""
tt_bad "ledger empty" '.tuning.ledger = ""' "tuning.ledger must be a non-empty path"
tt_bad "pauseAtWeeklyPct 0" '.tuning.pauseAtWeeklyPct = 0' "tuning.pauseAtWeeklyPct must be a number in (0, 100]"
tt_bad "rejected not an array" '.tuning.rejected = {}' "tuning.rejected must be an array"
tt_bad "rejected entry not an object" '.tuning.rejected = ["x"]' "tuning.rejected[0] must be an object"
tt_bad "rejected unknown level" '.tuning.rejected = [{"level":"expert","vendor":"claude","model":"claude-sonnet-5","effort":"high"}]' "tuning.rejected[0].level must be one of"
tt_bad "rejected unknown vendor" '.tuning.rejected = [{"level":"deep","vendor":"agy","model":"pro","effort":"high"}]' "tuning.rejected[0].vendor must be one of"
tt_bad "rejected model not an id" '.tuning.rejected = [{"level":"deep","vendor":"claude","model":"a b","effort":"high"}]' "tuning.rejected[0].model must be a model id"
tt_bad "rejected effort unknown" '.tuning.rejected = [{"level":"deep","vendor":"claude","model":"claude-sonnet-5","effort":"ultra"}]' "tuning.rejected[0].effort must be one of"
tt_bad "rejected until not a date" '.tuning.rejected = [{"level":"deep","vendor":"claude","model":"claude-sonnet-5","effort":"high","until":"soon"}]' "tuning.rejected[0].until must be a YYYY-MM-DD date"
tt_bad "aliasHistory not an object" '.aliasHistory = []' "aliasHistory must be an object"
tt_bad "aliasHistory unknown vendor" '.aliasHistory.agy = {}' "aliasHistory: unknown vendor agy"
tt_bad "aliasHistory vendor not an object" '.aliasHistory.codex = []' "aliasHistory.codex must be an object"
tt_bad "aliasHistory alias not a token" '.aliasHistory.claude["op us"] = [{"id":"x","from":"2026-01-01"}]' "must be a model-id token"
tt_bad "aliasHistory empty list" '.aliasHistory.claude.opus = []' "aliasHistory.claude.opus must be a non-empty array"
tt_bad "aliasHistory entry not an object" '.aliasHistory.claude.opus = ["claude-opus-5"]' "aliasHistory.claude.opus[0] must be an object"
tt_bad "aliasHistory id not a token" '.aliasHistory.claude.opus[0].id = "claude opus"' "aliasHistory.claude.opus[0].id must be a model-id token"
tt_bad "aliasHistory id is itself an alias" '.aliasHistory.claude.opus[0].id = "sonnet"' "is itself an alias, not a concrete id"
tt_bad "aliasHistory from not a date" '.aliasHistory.claude.opus[0].from = "Sept 22"' "aliasHistory.claude.opus[0].from must be a YYYY-MM-DD date"
tt_bad "aliasHistory from not increasing" '.aliasHistory.claude.opus[1].from = "2026-08-29"' "aliasHistory.claude.opus: from dates must be strictly increasing"
jq '.tuning.rejected = [{"level":"deep","vendor":"claude","model":"claude-sonnet-5","effort":"high","until":"2026-10-01"}]' "$TIERS" > "$T/rt.json"
OUT=$(TRIAGE_TIERS="$T/rt.json" "$TT" --bakeoff-json 2>&1); RC=$?; ERR=""
chk "TT a valid tuning.rejected passes and is printed with the tuning" '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r ".tuning.rejected[0].until")" = 2026-10-01 ]'
printf '{"levels": [1]}\n' > "$T/rt.json"
OUT=$(TRIAGE_TIERS="$T/rt.json" "$TT" --bakeoff-json 2>&1); RC=$?
chk "TT a file that is not tiers JSON (no levels/modes objects) is exit 2" '[ "$RC" -eq 2 ] && printf "%s" "$OUT" | grep -q "not valid tiers JSON"'
OUT=$(TRIAGE_TIERS="$TIERS" "$TT" --frobnicate 2>&1); RC=$?
chk "TT an unknown argument is exit 2" '[ "$RC" -eq 2 ] && printf "%s" "$OUT" | grep -q "unknown argument"'

rstate() { printf '%s' "$OUT" | jq -r --arg l "$1" '.levels[$l] | .state + ":" + (.rate | tostring)'; }
rwhy() { printf '%s' "$OUT" | jq -r --arg l "$1" '.levels[$l].reason'; }
run_pr rates --json --tiers "$TIERS" --ledger "$T/none.jsonl"
chk "RA1 no data: quick none (no challenger configured) at 0; builder/deep/top explore at sampleRate 0.2" \
  '[ "$RC" -eq 0 ] && [ "$(rstate quick)" = "none:0" ] && [ "$(rstate builder)" = "explore:0.2" ] && [ "$(rstate deep)" = "explore:0.2" ] && [ "$(rstate top)" = "explore:0.2" ]'
chk "RA1b the reason names what is missing, per incumbent AND configured challenger (builder: claude sonnet@medium, sonnet@high, codex gpt-6-sol@medium)" \
  '[ "$(rwhy builder)" = "claude claude-sonnet-5@high n=0 < 8; claude claude-sonnet-5@medium n=0 < 8; codex gpt-6-sol@medium n=0 < 8" ]'
chk "RA1c .rates is the {level: rate} map triage-exec takes; asOf is the tiers file's; params echo the tuning" \
  '[ "$(printf "%s" "$OUT" | jq -c .rates)" = "{\"quick\":0,\"builder\":0.2,\"deep\":0.2,\"top\":0.2}" ] && [ "$(printf "%s" "$OUT" | jq -r .asOf)" = "$(jq -r .asOf "$TIERS")" ] &&
   [ "$(printf "%s" "$OUT" | jq -c .params)" = "{\"explore\":0.2,\"maintain\":0.05,\"maxWidth\":0.35,\"minN\":8}" ]'

# Settled builder level: every incumbent + configured challenger at 40/40 (CI width .088), no proposal.
RL="$T/l-settled.jsonl"; : > "$RL"
gen builder claude sonnet medium pass 40; gen builder claude sonnet high pass 40; gen builder codex gpt-6-sol medium pass 40
SETTLED="$RL"
run_pr rates --json --tiers "$TIERS" --ledger "$SETTLED"
chk "RA2 builder settled (all n >= minN, narrow CIs, no proposal) -> maintain at maintain.rate 0.05; other levels unaffected" \
  '[ "$RC" -eq 0 ] && [ "$(rstate builder)" = "maintain:0.05" ] && rwhy builder | grep -q "^settled" && [ "$(rstate deep)" = "explore:0.2" ] && [ "$(rstate quick)" = "none:0" ]'
run_pr report --json --tiers "$TIERS" --ledger "$SETTLED"
REPJ="$OUT"
run_pr rates --json --tiers "$TIERS" --ledger "$SETTLED"
chk "RA2b report --json carries the same object as .sampling; groups carry a Wilson upper bound next to the lower one" \
  '[ "$(printf "%s" "$REPJ" | jq -c .sampling)" = "$OUT" ] && [ "$(printf "%s" "$REPJ" | jq -r ".groups[] | select(.modelId == \"claude-sonnet-5\" and .effort == \"medium\") | .wilsonUB * 10000 | round")" = 10000 ]'
run_pr rates --tiers "$TIERS" --ledger "$SETTLED"
chk "RA2c plain output: one tab-separated line per level" \
  '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 4 ] && printf "%s\n" "$OUT" | grep -q "^builder	maintain	0.05	settled"'
run_pr report --tiers "$TIERS" --ledger "$SETTLED"
chk "RA2d markdown report has the sampling-rate table" \
  'printf "%s" "$OUT" | grep -q "^## Sampling rates (inline bake-offs)" && printf "%s" "$OUT" | grep -q "^| builder | maintain | 0.05 | settled"'

# A proposal alone forces explore: incumbent sonnet·medium 30/40 (.75, CI width .26),
# configured pricier challenger sonnet·high 40/40 (+.25 >= .15 -> propose); all n >= 8.
RL="$T/l-proposal.jsonl"; : > "$RL"
gen builder claude sonnet medium pass 30; gen builder claude sonnet medium fail 10; gen builder claude sonnet high pass 40; gen builder codex gpt-6-sol medium pass 40
run_pr rates --json --tiers "$TIERS" --ledger "$RL"
chk "RA3 a proposal for a level x vendor -> explore, the reason names the pending proposal (and no count or width gap)" \
  '[ "$(rstate builder)" = "explore:0.2" ] && [ "$(rwhy builder)" = "proposal pending for builder/claude: claude-sonnet-5@medium -> claude-sonnet-5@high" ]'

# Wide intervals: everything at n = 8 but 4/8 (CI width .59), no proposal (equal rates).
RL="$T/l-wide.jsonl"; : > "$RL"
for m in "claude sonnet medium" "claude sonnet high" "codex gpt-6-sol medium"; do
  # shellcheck disable=SC2086  # $m is vendor model effort
  gen builder $m pass 4; gen builder $m fail 4
done
run_pr rates --json --tiers "$TIERS" --ledger "$RL"
chk "RA4 n >= minN but a Wilson 95% CI wider than maxWidth -> explore, the reason gives the width" \
  '[ "$(rstate builder)" = "explore:0.2" ] && rwhy builder | grep -q "codex gpt-6-sol@medium CI width 0.[0-9]* > 0.35" && ! rwhy builder | grep -q "n=" && ! rwhy builder | grep -q proposal'
jq '.tuning.maintain.maxWidth = 1' "$TIERS" > "$T/tiers-w1.json"
run_pr rates --json --tiers "$T/tiers-w1.json" --ledger "$RL"
chk "RA4b ...and the same ledger with maxWidth 1 -> maintain (the width is what held it)" '[ "$(rstate builder)" = "maintain:0.05" ]'

# The n check on its own (maxWidth 1, so no width can hold a level): a challenger one run short.
RL="$T/l-short.jsonl"; : > "$RL"
gen builder claude sonnet medium pass 40; gen builder claude sonnet high pass 40; gen builder codex gpt-6-sol medium pass 7
run_pr rates --json --tiers "$T/tiers-w1.json" --ledger "$RL"
chk "RA5 one configured config under minN (codex gpt-6-sol@medium 7/7) -> explore, naming it" \
  '[ "$(rstate builder)" = "explore:0.2" ] && [ "$(rwhy builder)" = "codex gpt-6-sol@medium n=7 < 8" ]'
# Only build lines count: a review line, and a crafted inline-review line that even
# carries a candidates array with the missing pass, change nothing.
jq -nc '{v:1, ts:"2026-09-24T00:00:00Z", source:"inline-review", run:"rv-x", repoName:"r",
  reviewers:[{label:"a", vendor:"codex", level:"builder", model:"gpt-6-sol", effort:"medium", status:"ok", precision:1, recall:1, n:5}],
  candidates:[{label:"c", vendor:"codex", model:"gpt-6-sol", effort:"medium", status:"pass"}], level:"builder", items:1, real:1, disputed:0, resolved:0}' >> "$RL"
run_pr rates --json --tiers "$T/tiers-w1.json" --ledger "$RL"
chk "RA6 review lines never count toward the rate (still n=7 after an inline-review line carrying a pass)" \
  '[ "$(rstate builder)" = "explore:0.2" ] && [ "$(rwhy builder)" = "codex gpt-6-sol@medium n=7 < 8" ]'
gen builder codex gpt-6-sol medium pass 1
run_pr rates --json --tiers "$T/tiers-w1.json" --ledger "$RL"
chk "RA6b one more BUILD pass -> maintain" '[ "$(rstate builder)" = "maintain:0.05" ]'

# A model change in the tiers file resets automatically: the new incumbent has n=0.
jq '.levels.builder.codex.model = "gpt-6-sol-2"' "$TIERS" > "$T/tiers-newmodel.json"
run_pr rates --json --tiers "$T/tiers-newmodel.json" --ledger "$SETTLED"
chk "RA7 a new incumbent model in tiers.json (same ledger that was settled) -> its n=0 -> explore" \
  '[ "$(rstate builder)" = "explore:0.2" ] && [ "$(rwhy builder)" = "codex gpt-6-sol-2@medium n=0 < 8" ]'
jq '.levels.builder.claude.effort = "low"' "$TIERS" > "$T/tiers-neweffort.json"
run_pr rates --json --tiers "$T/tiers-neweffort.json" --ledger "$SETTLED"
chk "RA7b ...and so does a new incumbent effort" '[ "$(rstate builder)" = "explore:0.2" ] && rwhy builder | grep -q "claude claude-sonnet-5@low n=0 < 8"'
jq '.tuning.challengers.builder.codex += [{"model": "gpt-6-astra", "effort": "high"}]' "$TIERS" > "$T/tiers-newch.json"
run_pr rates --json --tiers "$T/tiers-newch.json" --ledger "$SETTLED"
chk "RA7c a newly configured challenger (n=0) -> explore" '[ "$(rstate builder)" = "explore:0.2" ] && [ "$(rwhy builder)" = "codex gpt-6-astra@high n=0 < 8" ]'

jq '.tuning.challengers.top = {"claude": [], "codex": []}' "$TIERS" > "$T/tiers-notop.json"
run_pr rates --json --tiers "$T/tiers-notop.json" --ledger "$SETTLED"
chk "RA8 a level whose challenger lists are all empty -> none at rate 0 (like quick)" '[ "$(rstate top)" = "none:0" ] && [ "$(rstate quick)" = "none:0" ]'
chk "RA9 Wilson 95% upper bounds reuse the one formula: 5/10 = 0.7634, 0/10 = 0.2775, 10/10 = 1" \
  '[ "$(g deep codex gpt-6-sol medium ".wilsonUB * 10000 | round")" = 7634 ] && [ "$(g deep codex gpt-6-luna low ".wilsonUB * 10000 | round")" = 2775 ] &&
   [ "$(g deep claude claude-sonnet-5 high ".wilsonUB * 10000 | round")" = 10000 ]'

# --- MV: model-version tracking — modelId per candidate, alias history, backfill,
# grouping by concrete id, family cheapness, the history view -------------------
chk "MV0 the shipped tiers pin concrete Claude ids (no alias left at levels.*.claude)" \
  '[ "$(jq -r "[.levels[].claude.model] | join(\",\")" "$TIERS")" = "claude-haiku-4-5-20251001,claude-sonnet-5,claude-opus-5-5,claude-fable-5-1" ]'
cat > "$T/mv-compare.json" <<'EOF'
{"candidates":[
 {"label":"c-null","vendor":"claude","level":"builder","model":null,"effort":null,"status":"pass"},
 {"label":"c-alias","vendor":"claude","level":"deep","model":"opus","effort":"high","modelFrom":"candidate","status":"pass"},
 {"label":"x-cand","vendor":"codex","level":"builder","model":"gpt-6-sol","effort":"medium","modelFrom":"candidate","status":"fail"},
 {"label":"x-run","vendor":"codex","level":"deep","model":"gpt-6-astra","effort":"high","modelFrom":"runner","status":"pass"}]}
EOF
mvc() { run_pr ingest-compare --tiers "$TIERS" --ledger "$1" --result "$T/mv-compare.json" --repo-name r --level deep --source inline --run mv --ts "$2"; }
mc() { jq -r --arg l "$2" '.candidates[] | select(.label == $l) | "\(.modelId)/\(.modelIdSource)"' "$1"; }
mvc "$T/mv-a.jsonl" 2026-09-24T09:00:00Z
chk "MV1 ingest fills modelId + modelIdSource per case: tiers default -> pinned, alias -> inferred-by-date, candidate id -> pinned, runner-reported -> observed" \
  '[ "$RC" -eq 0 ] && [ "$(mc "$T/mv-a.jsonl" c-null)" = "claude-sonnet-5/pinned" ] && [ "$(mc "$T/mv-a.jsonl" c-alias)" = "claude-opus-5-5/inferred-by-date" ] &&
   [ "$(mc "$T/mv-a.jsonl" x-cand)" = "gpt-6-sol/pinned" ] && [ "$(mc "$T/mv-a.jsonl" x-run)" = "gpt-6-astra/observed" ]'
chk "MV1b model keeps what was configured (the alias); only modelId is resolved" \
  '[ "$(jq -r ".candidates[] | select(.label == \"c-alias\") | .model" "$T/mv-a.jsonl")" = opus ]'
mvc "$T/mv-b.jsonl" 2026-09-22T00:00:00Z
mvc "$T/mv-c.jsonl" 2026-09-21T23:59:59Z
mvc "$T/mv-d.jsonl" 2026-08-01T00:00:00Z
chk "MV2 inferred-by-date boundary: opus on 2026-09-22 (its from date) = claude-opus-5-5, one second earlier = claude-opus-5" \
  '[ "$(mc "$T/mv-b.jsonl" c-alias)" = "claude-opus-5-5/inferred-by-date" ] && [ "$(mc "$T/mv-c.jsonl" c-alias)" = "claude-opus-5/inferred-by-date" ]'
chk "MV2b an alias before its first history entry stays unresolved (null/null), never guessed" \
  '[ "$(mc "$T/mv-d.jsonl" c-alias)" = "null/null" ] && [ "$(mc "$T/mv-d.jsonl" c-null)" = "claude-sonnet-5/pinned" ]'
run_pr ingest-review --tiers "$TIERS" --ledger "$T/mv-rv.jsonl" --result "$T/review.json" --repo-name voron --ts 2026-09-24T12:00:00Z
chk "MV3 ingest-review gives every reviewer a modelId too (opus alias inferred, tiers default pinned, codex pinned)" \
  '[ "$(jq -r "[.reviewers[] | \"\(.label)=\(.modelId)/\(.modelIdSource)\"] | join(\",\")" "$T/mv-rv.jsonl")" = "rv-sonnet=claude-sonnet-5/pinned,rv-opus=claude-opus-5-5/inferred-by-date,rv-sol=gpt-6-sol/pinned,rv-astra=gpt-6-astra/pinned" ]'
chk "MV3b ingest-parity lines carry modelId (a = tiers default claude-sonnet-5 pinned, x = gpt-6-astra pinned)" \
  '[ "$(jq -r ".candidates[0] | .label + \"=\" + .modelId + \"/\" + .modelIdSource" "$PL" | paste -sd, -)" = "a=claude-sonnet-5/pinned,a-r2=claude-sonnet-5/pinned,x=gpt-6-astra/pinned" ]'

# backfill-modelid: old lines get modelId; filled rows, malformed lines and order stay.
BL="$T/mv-backfill.jsonl"
{
  jq -nc '{v:1, ts:"2026-09-21T10:00:00Z", source:"suite", run:"b1", repoName:"r", level:"deep", task:null, candidates:[{label:"a", vendor:"claude", model:"opus", effort:"high", status:"pass"}], applied:null}'
  jq -nc '{v:1, ts:"2026-09-24T10:00:00Z", source:"suite", run:"b2", repoName:"r", level:"deep", task:null, candidates:[{label:"a", vendor:"claude", model:"opus", effort:"high", status:"fail"}], applied:null}'
  jq -nc '{v:1, ts:"2026-09-24T10:00:00Z", source:"inline", run:"b3", repoName:"r", level:"builder", task:null, candidates:[{label:"x", vendor:"codex", model:"gpt-6-sol", effort:"medium", status:"pass"}], applied:null}'
  jq -nc '{v:1, ts:"2026-09-24T10:00:00Z", source:"inline", run:"b4", repoName:"r", level:"deep", task:null, candidates:[{label:"x", vendor:"codex", model:"gpt-6-astra", effort:"high", status:"pass", modelId:"gpt-6-astra", modelIdSource:"observed"}], applied:null}'
  printf 'not json {\n'
  jq -nc '{v:1, ts:"2026-09-24T12:00:00Z", source:"inline-review", run:"b6", repoName:"r", reviewers:[{label:"s", vendor:"claude", level:"builder", model:"sonnet", effort:"high", status:"ok", precision:1, recall:1, n:1}], items:1, real:1, disputed:0, resolved:0}'
  jq -nc '{v:1, ts:"2026-09-01T10:00:00Z", source:"suite", run:"b7", repoName:"r", level:"quick", task:null, candidates:[{label:"h", vendor:"claude", model:"haiku", effort:"low", status:"pass"}], applied:null}'
} > "$BL"
BL_SUM=$(cksum < "$BL")
BL_L4=$(sed -n 4p "$BL"); BL_L5=$(sed -n 5p "$BL")
run_pr backfill-modelid --tiers "$TIERS" --ledger "$BL" --dry-run
chk "MV4 backfill --dry-run reports what it would fill and writes nothing" \
  '[ "$RC" -eq 0 ] && [ "$(j .dryRun)" = true ] && [ "$(j .updatedLines)" = 5 ] && [ "$(cksum < "$BL")" = "$BL_SUM" ]'
run_pr backfill-modelid --tiers "$TIERS" --ledger "$BL"
chk "MV4b backfill fills 5 of 7 lines: 3 inferred-by-date, 1 pinned, 1 unresolved (alias before its history)" \
  '[ "$RC" -eq 0 ] && [ "$(j .updatedLines)" = 5 ] && [ "$(printf "%s" "$OUT" | jq -c .filled)" = "{\"inferred-by-date\":3,\"pinned\":1,\"unresolved\":1}" ] && [ "$(nlines "$BL")" = 7 ]'
chk "MV4c backfill resolves by each line date (opus 2026-09-21 -> claude-opus-5, 2026-09-24 -> claude-opus-5-5); reviewers too; line order kept" \
  '[ "$(sed -n 1p "$BL" | jq -r ".run + \"=\" + .candidates[0].modelId + \"/\" + .candidates[0].modelIdSource")" = "b1=claude-opus-5/inferred-by-date" ] &&
   [ "$(sed -n 2p "$BL" | jq -r ".candidates[0].modelId")" = claude-opus-5-5 ] && [ "$(sed -n 3p "$BL" | jq -r ".candidates[0].modelIdSource")" = pinned ] &&
   [ "$(sed -n 6p "$BL" | jq -r ".reviewers[0].modelId")" = claude-sonnet-5 ] && [ "$(sed -n 7p "$BL" | jq -c ".candidates[0] | [.modelId, .modelIdSource]")" = "[null,null]" ]'
chk "MV4d a row that already has modelId (observed) and a malformed line are byte-identical; no other key is added" \
  '[ "$(sed -n 4p "$BL")" = "$BL_L4" ] && [ "$(sed -n 5p "$BL")" = "$BL_L5" ] && [ "$(sed -n 1p "$BL" | jq -c keys)" = "[\"applied\",\"candidates\",\"level\",\"repoName\",\"run\",\"source\",\"task\",\"ts\",\"v\"]" ]'
BL_SUM2=$(cksum < "$BL")
run_pr backfill-modelid --tiers "$TIERS" --ledger "$BL"
chk "MV4e backfill is idempotent: a second run fills nothing and leaves the file byte-identical" \
  '[ "$RC" -eq 0 ] && [ "$(j .updatedLines)" = 0 ] && [ "$(cksum < "$BL")" = "$BL_SUM2" ]'
run_pr backfill-modelid --tiers "$TIERS" --ledger "$T/none.jsonl"
chk "MV4f backfill of a missing ledger is a usage error (exit 2), nothing created" '[ "$RC" -eq 2 ] && [ ! -e "$T/none.jsonl" ]'
run_pr report --tiers "$TIERS" --ledger "$BL" --dry-run
chk "MV4g --dry-run belongs to backfill-modelid only (exit 2 elsewhere)" '[ "$RC" -eq 2 ]'

# Two Opus versions under ONE alias: rows split by concrete id, never pooled.
GL="$T/mv-group.jsonl"; : > "$GL"
gl() { # TS MODEL STATUS COUNT [MODELID]
  local i=0
  while [ "$i" -lt "$4" ]; do
    jq -nc --arg ts "$1" --arg m "$2" --arg s "$3" --arg id "${5:-}" \
      '{v:1, ts:$ts, source:"inline", run:null, repoName:"r", level:"deep", task:null,
        candidates:[{label:"c", vendor:"claude", model:$m, effort:"high", status:$s} + (if $id == "" then {} else {modelId:$id, modelIdSource:"pinned"} end)], applied:null}' >> "$GL"
    i=$((i + 1))
  done
}
gl 2026-09-21T10:00:00Z opus pass 3; gl 2026-09-21T11:00:00Z opus fail 2
gl 2026-09-24T10:00:00Z opus pass 6
gl 2026-09-24T11:00:00Z opus pass 2 claude-opus-5
run_pr report --tiers "$TIERS" --ledger "$GL" --json
chk "MV5 grouping is by concrete id: claude-opus-5 7 runs (5 pass; 2 by their own modelId, 5 by date) and claude-opus-5-5 6 runs — never one opus group of 13" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r "[.groups[] | select(.level == \"deep\" and .vendor == \"claude\") | \"\(.modelId):\(.n):\(.passes)\"] | sort | join(\",\")")" = "claude-opus-5-5:6:6,claude-opus-5:7:5" ]'
chk "MV5b each group lists the configured model names it pooled and is marked incumbent only for the current id" \
  '[ "$(printf "%s" "$OUT" | jq -c "[.groups[] | select(.level == \"deep\") | [.modelId, .models, .role]] | sort")" = "[[\"claude-opus-5\",[\"opus\"],null],[\"claude-opus-5-5\",[\"opus\"],\"incumbent\"]]" ]'
jq '.levels.deep.claude.model = "claude-opus-6"' "$TIERS" > "$T/tiers-opus6.json"
run_pr rates --json --tiers "$T/tiers-opus6.json" --ledger "$GL"
chk "MV6 a pinned id edited in tiers (claude-opus-6) starts at n=0 -> explore, naming it" \
  '[ "$(rstate deep)" = "explore:0.2" ] && rwhy deep | grep -q "claude claude-opus-6@high n=0 < 8" && ! rwhy deep | grep -q "claude-opus-5-5@high"'
jq '.levels.deep.claude.model = "opus" | .aliasHistory.claude.opus += [{"id": "claude-opus-6", "from": "2026-09-25"}]' "$TIERS" > "$T/tiers-moved.json"
run_pr rates --json --tiers "$T/tiers-moved.json" --ledger "$GL"
chk "MV6b an alias that moves (opus -> claude-opus-6 in aliasHistory) resets too: the incumbent resolves today to the new id, n=0 -> explore" \
  '[ "$(rstate deep)" = "explore:0.2" ] && rwhy deep | grep -q "claude claude-opus-6@high n=0 < 8"'
run_pr history --json --tiers "$T/tiers-moved.json" --ledger "$GL"
chk "MV6c ...and the old versions keep their history under the moved alias (5 + 6 runs by date, unchanged)" \
  '[ "$(printf "%s" "$OUT" | jq -r ".history[] | select(.level == \"deep\" and .vendor == \"claude\") | [.current.modelId, (.current.seen|tostring), ([.entries[] | \"\(.modelId):\(.n)\"] | join(\"+\"))] | join(\" \")")" = "claude-opus-6 false claude-opus-5:7+claude-opus-5-5:6" ]'
jq '.levels.deep.claude.model = "claude-opus-5-5[1m]"' "$TIERS" > "$T/tiers-1m.json"
run_pr history --json --tiers "$T/tiers-1m.json" --ledger "$GL"
chk "MV6d a context suffix in tiers ([1m]) is the same version: the incumbent is still claude-opus-5-5 with its data" \
  '[ "$(printf "%s" "$OUT" | jq -r ".history[] | select(.level == \"deep\" and .vendor == \"claude\") | .current | \"\(.modelId) \(.seen)\"")" = "claude-opus-5-5 true" ]'

run_pr history --json --tiers "$TIERS" --ledger "$GL"
hd() { printf '%s' "$OUT" | jq -r '.history[] | select(.level == "deep" and .vendor == "claude") | '"$1"; }
chk "MV7 history: per level x vendor, every id x effort seen, oldest first, with first/last ts and the current one flagged" \
  '[ "$RC" -eq 0 ] && [ "$(hd "[.entries[] | \"\(.modelId)|\(.n)|\(.firstTs)|\(.lastTs)|\(.role)\"] | join(\",\")")" = "claude-opus-5|7|2026-09-21T10:00:00Z|2026-09-24T11:00:00Z|null,claude-opus-5-5|6|2026-09-24T10:00:00Z|2026-09-24T10:00:00Z|incumbent" ] &&
   [ "$(hd ".current | \"\(.modelId) \(.effort) \(.seen)\"")" = "claude-opus-5-5 high true" ] && [ "$(hd ".entries[0].wilsonUB * 10000 | round")" -gt 0 ]'
chk "MV7b history lists a level x vendor with a tiers entry but no data (current named, no entries)" \
  '[ "$(printf "%s" "$OUT" | jq -r ".history[] | select(.level == \"quick\" and .vendor == \"codex\") | \"\(.current.modelId) \(.current.seen) \(.entries | length)\"")" = "gpt-6-luna false 0" ]'
run_pr history --tiers "$TIERS" --ledger "$GL"
chk "MV7c history markdown: a section per level x vendor naming the current id, a row per version with its dates" \
  'printf "%s" "$OUT" | grep -q "^## deep / claude — current: claude-opus-5-5 · high$" && printf "%s" "$OUT" | grep -q "^| claude-opus-5 | high | 7 | 5 | 0.714 | .* | 2026-09-21 | 2026-09-24 |  |$" &&
   printf "%s" "$OUT" | grep -q "^| claude-opus-5-5 | high | 6 | 6 | 1 | .* | current |$"'
run_pr history --json --tiers "$TIERS" --ledger "$GL" --model claude-opus-5
chk "MV8 --model <id> is exact (claude-opus-5 does not match claude-opus-5-5); only matching level x vendors are listed" \
  '[ "$(hd "[.entries[].modelId] | join(\",\")")" = "claude-opus-5" ] && [ "$(printf "%s" "$OUT" | jq ".history | length")" = 1 ] && [ "$(printf "%s" "$OUT" | jq -r .filters.model)" = claude-opus-5 ]'
run_pr history --json --tiers "$TIERS" --ledger "$GL" --model opus --since 2026-09-24
chk "MV8b --model <family> matches every version; --since drops older lines (claude-opus-5 keeps its 2 later runs, now listed second by first ts)" \
  '[ "$(hd "[.entries[] | \"\(.modelId):\(.n)\"] | join(\",\")")" = "claude-opus-5-5:6,claude-opus-5:2" ]'
run_pr report --json --tiers "$TIERS" --ledger "$GL" --model claude-opus-5-5
chk "MV8c report takes the same filters (groups narrowed, filters echoed)" \
  '[ "$(printf "%s" "$OUT" | jq -r "[.groups[].modelId] | unique | join(\",\")")" = claude-opus-5-5 ] && [ "$(printf "%s" "$OUT" | jq -r .filters.model)" = claude-opus-5-5 ]'
run_pr rates --tiers "$TIERS" --ledger "$GL" --model opus
chk "MV8d filters are refused where they would skew a decision input (rates, exit 2); a bad --since too" \
  '[ "$RC" -eq 2 ] && { run_pr history --tiers "$TIERS" --ledger "$GL" --since yesterday; [ "$RC" -eq 2 ]; }'

# Cheapness by FAMILY, so versioned ids rank: opus 5.5 incumbent at deep.
FL="$T/mv-family.jsonl"; : > "$FL"
fl() { # VENDOR MODEL EFFORT PASSES FAILS
  local i=0
  while [ "$i" -lt $(($4 + $5)) ]; do
    jq -nc --arg v "$1" --arg m "$2" --arg e "$3" --arg s "$(if [ "$i" -lt "$4" ]; then echo pass; else echo fail; fi)" \
      '{v:1, ts:"2026-09-24T00:00:00Z", source:"inline", run:null, repoName:"r", level:"deep", task:null,
        candidates:[{label:"c", vendor:$v, model:$m, effort:$e, status:$s, modelId:$m, modelIdSource:"pinned"}], applied:null}' >> "$FL"
    i=$((i + 1))
  done
}
fl claude claude-opus-5-5 high 10 0; fl claude claude-sonnet-5 high 10 0; fl claude claude-fable-5-1 high 10 0
fl claude claude-opus-5 high 10 0; fl claude claude-opus-5 medium 10 0
fl codex gpt-6-astra high 10 0; fl codex gpt-7-sol medium 10 0; fl codex gpt-7-x high 10 0
# Ranking needs the ids to be challengers at all: configure them (M26 current ids).
jq '.tuning.challengers.deep.claude += [{"model": "claude-opus-5", "effort": "medium"}]
  | .tuning.challengers.deep.codex += [{"model": "gpt-7-sol", "effort": "medium"}, {"model": "gpt-7-x", "effort": "high"}]' "$TIERS" > "$T/tiers-family.json"
run_pr report --json --tiers "$T/tiers-family.json" --ledger "$FL"
dir() { printf '%s' "$OUT" | jq -r --arg v "$1" --arg m "$2" --arg e "$3" '.decisions[] | select(.level == "deep" and .vendor == $v and .challenger.modelId == $m and .challenger.effort == $e) | .direction'; }
chk "MV9 family cheapness with versioned ids: sonnet-5 cheaper, fable-5-1 pricier, opus-5@medium cheaper than opus-5-5@high; same family + effort (opus-5@high) unranked" \
  '[ "$(dir claude claude-sonnet-5 high)" = cheaper ] && [ "$(dir claude claude-fable-5-1 high)" = pricier ] && [ "$(dir claude claude-opus-5 medium)" = cheaper ] && [ "$(dir claude claude-opus-5 high)" = unranked ]'
chk "MV9b a NEW codex version still ranks by family (gpt-7-sol cheaper than gpt-6-astra); an id with no family token is unranked" \
  '[ "$(dir codex gpt-7-sol medium)" = cheaper ] && [ "$(dir codex gpt-7-x high)" = unranked ]'

# --- LI: ledger integrity (Wave 16B) — run ids, content hashes, the lock ----------
LL="$T/li.jsonl"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare.json" --repo-name myrepo --level builder --source inline
chk "LI1 ingest-compare without --run is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LL" ] && printf "%s" "$ERR" | grep -q "needs --run"'
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run li-1 --ts 2026-09-24T10:00:00Z
LL_SUM=$(cksum < "$LL")
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run li-1 --ts 2026-09-25T10:00:00Z
chk "LI2 the same --run + the same result again (even at another --ts) is skipped: lines 0, ledger byte-identical — never a double count" \
  '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(cksum < "$LL")" = "$LL_SUM" ] && j .skipped | grep -q "same content"'
jq '.candidates[1].status = "pass"' "$T/compare.json" > "$T/compare2.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare2.json" --repo-name myrepo --level builder --source inline --run li-1
chk "LI3 the same --run with DIFFERENT content is a collision: refused (exit 2), nothing appended" \
  '[ "$RC" -eq 2 ] && [ "$(cksum < "$LL")" = "$LL_SUM" ] && printf "%s" "$ERR" | grep -q "DIFFERENT content"'
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run li-1 --applied claude-builder
chk "LI3b ...and so is the same result under other line-shaping options (--applied)" '[ "$RC" -eq 2 ] && [ "$(cksum < "$LL")" = "$LL_SUM" ]'
run_pr ingest-compare --tiers "$TIERS" --ledger "$LL" --result "$T/compare2.json" --repo-name myrepo --level builder --source inline --run li-2
chk "LI3c a unique --run ingests it (runHash stored on the line)" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$LL")" = 2 ] && [ "$(jq -r .runHash "$LL" | sort -u | grep -c .)" = 2 ]'

jq '.tasks[0].results[1].status = "pass"' "$T/parity.json" > "$T/parity2.json"
PL_SUM=$(cksum < "$PL")
run_pr ingest-parity --tiers "$TIERS" --ledger "$PL" --result "$T/parity2.json"
chk "LI4 ingest-parity: another result whose outDir basename is an ingested run id is refused (exit 2), never silently skipped" \
  '[ "$RC" -eq 2 ] && [ "$(cksum < "$PL")" = "$PL_SUM" ] && printf "%s" "$ERR" | grep -q "run id par-1 is already in the ledger with DIFFERENT content"'
run_pr ingest-parity --tiers "$TIERS" --ledger "$PL" --result "$T/parity2.json" --run par-1-b --ts 2026-09-24T11:00:00Z
chk "LI4b ingest-parity --run gives it its own id: its 3 graded lines are appended under par-1-b" \
  '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 3 ] && [ "$(j .run)" = par-1-b ] && [ "$(jq -r "select(.run == \"par-1-b\") | .run" "$PL" | wc -l | tr -d " ")" = 3 ]'

PA="$T/li-partial.jsonl"
run_pr ingest-parity --tiers "$TIERS" --ledger "$PA" --result "$T/parity.json" --ts 2026-09-24T11:00:00Z
PA_FULL=$(cat "$PA")
head -n 1 "$PA" > "$PA.tmp" && cat "$PA.tmp" > "$PA" && rm -f "$PA.tmp"   # an ingest cut after its first line
run_pr ingest-parity --tiers "$TIERS" --ledger "$PA" --result "$T/parity.json" --ts 2026-09-24T11:00:00Z
chk "LI5 an interrupted multi-line ingest is recoverable: the same run again appends ONLY the 2 missing observations; the ledger equals a whole ingest" \
  '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 2 ] && j .note | grep -q "missing observation" && [ "$(cat "$PA")" = "$PA_FULL" ]'
run_pr ingest-parity --tiers "$TIERS" --ledger "$PA" --result "$T/parity.json"
chk "LI5b ...and once complete, again is a no-op" '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(cat "$PA")" = "$PA_FULL" ]'

LG="$T/li-legacy.jsonl"
jq -nc '{v:1, ts:"2026-09-20T00:00:00Z", source:"suite", run:"par-1", repoName:"parity-suite", level:"quick", band:1, task:"t1",
  candidates:[{label:"a", vendor:"claude", model:"claude-sonnet-5", effort:"medium", status:"pass"}], applied:null}' > "$LG"
run_pr ingest-parity --tiers "$TIERS" --ledger "$LG" --result "$T/parity.json"
chk "LI6 a run id already there from before content hashes (no runHash) is skipped as before — never refused, never doubled" \
  '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(nlines "$LG")" = 1 ] && j .skipped | grep -q "before content hashes"'

LK="$T/li-lock.jsonl"
mkdir "$LK.lock"; echo "$$" > "$LK.lock/pid"
export PARITY_LOCK_TRIES=3
run_pr ingest-compare --tiers "$TIERS" --ledger "$LK" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run lk-1
chk "LI7 a live holder's lock blocks an ingest: still locked after PARITY_LOCK_TRIES -> exit 1, nothing written, the holder's lock untouched" \
  '[ "$RC" -eq 1 ] && [ ! -e "$LK" ] && [ "$(cat "$LK.lock/pid")" = "$$" ] && printf "%s" "$ERR" | grep -q "locked by pid $$"'
cp "$BL" "$LK"; LK_SUM=$(cksum < "$LK")
run_pr backfill-modelid --tiers "$TIERS" --ledger "$LK"
RC_BF=$RC
run_pr migrate --tiers "$TIERS" --ledger "$LK" --from "$T/legacy.jsonl"
chk "LI7b backfill-modelid and migrate take the same lock (both exit 1, the ledger unchanged)" '[ "$RC_BF" -eq 1 ] && [ "$RC" -eq 1 ] && [ "$(cksum < "$LK")" = "$LK_SUM" ]'
unset PARITY_LOCK_TRIES
rm -f "$LK"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
echo "$DEAD" > "$LK.lock/pid"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LK" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run lk-1
chk "LI7c a lock whose holder is gone is stale: taken over, the ingest lands, the lock is released" '[ "$RC" -eq 0 ] && [ "$(nlines "$LK")" = 1 ] && [ ! -e "$LK.lock" ]'
CC="$T/li-conc.jsonl"
for i in 1 2 3 4 5 6; do
  "$PR" ingest-compare --tiers "$TIERS" --ledger "$CC" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --run conc-1 --ts 2026-09-24T10:00:00Z >/dev/null 2>&1 &
done
wait
chk "LI7d six concurrent ingests of one run leave exactly ONE line (check + append is one locked step), no lock left behind" '[ "$(nlines "$CC")" = 1 ] && [ ! -e "$CC.lock" ]'

SLT="$T/li-target.jsonl"; SLN="$T/li-link.jsonl"
head -n 3 "$BL" | jq -c 'del(.candidates[].modelId, .candidates[].modelIdSource)' > "$SLT"
ln -s "$SLT" "$SLN"
run_pr backfill-modelid --tiers "$TIERS" --ledger "$SLN"
chk "LI8 backfill through a symlinked ledger rewrites the TARGET and keeps the link" \
  '[ "$RC" -eq 0 ] && [ "$(j .updatedLines)" = 3 ] && [ -L "$SLN" ] && [ "$(readlink "$SLN")" = "$SLT" ] && [ "$(jq -r ".candidates[0].modelIdSource" "$SLT" | sort -u)" != null ] && [ ! -e "$SLT.lock" ]'

TSL="$T/li-ts.jsonl"
run_pr ingest-compare --tiers "$TIERS" --ledger "$TSL" --result "$T/mv-compare.json" --repo-name r --level deep --source inline --run ts-1 --ts 2026-09-21T23:30:00-05:00
chk "LI9 a --ts with an offset is stored as UTC (2026-09-22T04:30:00Z) and the alias resolves at the UTC date (opus -> claude-opus-5-5, not claude-opus-5)" \
  '[ "$RC" -eq 0 ] && [ "$(jq -r .ts "$TSL")" = 2026-09-22T04:30:00Z ] && [ "$(mc "$TSL" c-alias)" = "claude-opus-5-5/inferred-by-date" ]'
jq -nc '{v:1, ts:"2026-09-21T23:30:00-05:00", source:"inline", run:"old-offset", repoName:"r", level:"deep", task:null,
  candidates:[{label:"c", vendor:"claude", model:"opus", effort:"high", status:"pass"}], applied:null}' > "$T/li-ts2.jsonl"
run_pr history --json --tiers "$TIERS" --ledger "$T/li-ts2.jsonl"
chk "LI9b an old line with an offset ts is read as UTC too (resolved at 2026-09-22 -> claude-opus-5-5; firstTs normalized)" \
  '[ "$(printf "%s" "$OUT" | jq -r ".history[] | select(.level == \"deep\" and .vendor == \"claude\") | .entries[0] | .modelId + \" \" + .firstTs")" = "claude-opus-5-5 2026-09-22T04:30:00Z" ]'
jq '. + {ts: "2026-09-21T10:00:00Z"}' "$T/mv-compare.json" > "$T/mv-ts.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$T/li-ts3.jsonl" --result "$T/mv-ts.json" --repo-name r --level deep --source inline --run ts-2
chk "LI10 a result carrying its own ts is ledgered at it, not at ingest time (opus as of 2026-09-21 -> claude-opus-5)" \
  '[ "$RC" -eq 0 ] && [ "$(jq -r .ts "$T/li-ts3.jsonl")" = 2026-09-21T10:00:00Z ] && [ "$(mc "$T/li-ts3.jsonl" c-alias)" = "claude-opus-5/inferred-by-date" ]'
run_pr ingest-compare --tiers "$TIERS" --ledger "$T/li-ts4.jsonl" --result "$T/mv-ts.json" --repo-name r --level deep --source inline --run ts-3 --ts 2026-09-24T00:00:00Z
chk "LI10b a --ts that disagrees with the result's own ts is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$T/li-ts4.jsonl" ] && printf "%s" "$ERR" | grep -q "disagrees"'

jq '.candidates[1].model = "opus[1m]"' "$T/mv-compare.json" > "$T/mv-1m.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$T/li-1m.jsonl" --result "$T/mv-1m.json" --repo-name r --level deep --source inline --run m1 --ts 2026-09-24T09:00:00Z
chk "LI11 a model with a context suffix (opus[1m]) is accepted: model kept, modelId the resolved version" \
  '[ "$RC" -eq 0 ] && [ "$(jq -r ".candidates[1] | .model + \" \" + .modelId" "$T/li-1m.jsonl")" = "opus[1m] claude-opus-5-5" ]'
jq '.candidates[1].model = "opus[the brief text]"' "$T/mv-compare.json" > "$T/mv-1mbad.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$T/li-1mbad.jsonl" --result "$T/mv-1mbad.json" --repo-name r --level deep --source inline --run m2
chk "LI11b ...but a bracketed suffix that is free text is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$T/li-1mbad.jsonl" ]'

export PARITY_TODAY=2026-09-24
run_pr rates --json --tiers "$T/tiers-moved.json" --ledger "$GL"
chk "LI12 PARITY_TODAY pins the alias date: on 2026-09-24 the moved alias (from 2026-09-25) still means claude-opus-5-5" \
  '[ "$RC" -eq 0 ] && ! rwhy deep | grep -q "claude-opus-6" && rwhy deep | grep -q "claude-opus-5-5@high"'
export PARITY_TODAY=tomorrow
run_pr rates --json --tiers "$TIERS" --ledger "$GL"
chk "LI12b a PARITY_TODAY that is not YYYY-MM-DD is a usage error" '[ "$RC" -eq 2 ]'
export PARITY_TODAY=2026-09-25

cat > "$T/parity-mf.json" <<'EOF'
{"outDir":"/o/runs/par-mf","bands":[3],
 "ranking":[{"label":"x","vendor":"codex","level":"deep","model":null,"effort":"high"},{"label":"y","vendor":"codex","level":"deep","model":"gpt-6-astra","effort":"high"}],
 "tasks":[{"band":3,"id":"t3","kind":"build","results":[
   {"label":"x","runLabel":"x","vendor":"codex","status":"pass","model":"gpt-6-astra","modelFrom":"runner"},
   {"label":"y","runLabel":"y","vendor":"codex","status":"fail","model":"gpt-6-astra","modelFrom":"candidate"}]}]}
EOF
run_pr ingest-parity --tiers "$TIERS" --ledger "$T/li-mf.jsonl" --result "$T/parity-mf.json" --ts 2026-09-24T00:00:00Z
chk "LI13 ingest-parity forwards modelFrom: a runner-reported model is ledgered observed, a candidate one pinned (M7)" \
  '[ "$RC" -eq 0 ] && [ "$(jq -r ".candidates[0] | .label + \"=\" + .modelIdSource" "$T/li-mf.jsonl" | paste -sd, -)" = "x=observed,y=pinned" ]'

# --- RC: reps are not i.i.d. — one outcome per (run, task, candidate) (M28) --------
CL="$T/rc.jsonl"; : > "$CL"
rcl() { # RUN TASK LABEL STATUS
  jq -nc --arg r "$1" --arg t "$2" --arg l "$3" --arg s "$4" '{v:1, ts:"2026-09-24T00:00:00Z", source:"suite", run:$r, repoName:"parity-suite", level:"builder", band:2, task:$t,
    candidates:[{label:$l, vendor:"claude", model:"claude-sonnet-5", effort:"high", status:$s, modelId:"claude-sonnet-5", modelIdSource:"pinned"}], applied:null}' >> "$CL"
}
for tk in t1 t2 t3; do for lb in a a-r2 a-r3; do rcl p1 "$tk" "$lb" pass; done; done
rcl p1 t4 a pass; rcl p1 t4 a-r2 pass; rcl p1 t4 a-r3 fail
rcl p1 t5 a pass; rcl p1 t5 a-r2 fail; rcl p1 t5 a-r3 fail
rcl p1 t6 a pass; rcl p1 t6 a-r2 fail; rcl p1 t6 a-r3 unavailable
rcl p2 t1 a fail
run_pr report --json --tiers "$TIERS" --ledger "$CL"
REP="$OUT"
chk "RC1 reps collapse per (run, task) by majority: 18 graded observations -> n 6, 4 passes (t1-t3, t4); t5 and p2/t1 fail; the t6 tie is excluded" \
  '[ "$RC" -eq 0 ] && [ "$(g builder claude claude-sonnet-5 high "[.n, .passes, .observations, .ties, .excluded] | map(tostring) | join(\",\")")" = "6,4,18,1,1" ]'
run_pr rates --json --tiers "$TIERS" --ledger "$CL"
chk "RC2 minN counts effective outcomes (9 all-pass reps of 3 tasks are 3, not 9): the reason says n=6" 'rwhy builder | grep -q "claude claude-sonnet-5@high n=6 < 8"'
jq -nc '{v:1, ts:"2026-09-24T00:00:00Z", source:"inline", run:"dup", repoName:"r", level:"builder", task:"s1",
  candidates:[{label:"c", vendor:"claude", model:"claude-sonnet-5", effort:"high", status:"pass"}], applied:null}' > "$T/rc-dup.jsonl"
cat "$T/rc-dup.jsonl" "$T/rc-dup.jsonl" >> "$T/rc-dup.jsonl.2"; mv "$T/rc-dup.jsonl.2" "$T/rc-dup.jsonl"
run_pr report --json --tiers "$TIERS" --ledger "$T/rc-dup.jsonl"
REP="$OUT"
chk "RC3 a run double-ingested before idempotence existed counts once (n 1 of 2 observations)" '[ "$(g builder claude claude-sonnet-5 high "[.n, .observations] | map(tostring) | join(\",\")")" = "1,2" ]'
jq -c '.candidates[0].totalTokens = 7' "$T/rc-dup.jsonl" | head -n 1 >> "$T/rc-dup.jsonl"
run_pr report --json --tiers "$TIERS" --ledger "$T/rc-dup.jsonl"
REP="$OUT"
chk "RC3b ...but a pre-runHash inline line with the same run id and DIFFERENT content (another session reused the id) is its own outcome (n 2)" \
  '[ "$(g builder claude claude-sonnet-5 high "[.n, .observations] | map(tostring) | join(\",\")")" = "2,3" ]'
run_pr report --tiers "$TIERS" --ledger "$CL"
chk "RC4 markdown says n is effective and shows Obs. (ties)" 'printf "%s" "$OUT" | grep -q "^n = effective outcomes" && printf "%s" "$OUT" | grep -q "| claude | claude-sonnet-5 | high | 6 | 4 | .* | 1 | 18 (1) |"'

# --- RS: superseded versions are never proposed (M26) --------------------------------
SV="$T/rs.jsonl"; : > "$SV"
svl() { # MODELID EFFORT PASSES FAILS
  local i=0
  while [ "$i" -lt $(($3 + $4)) ]; do
    jq -nc --arg m "$1" --arg e "$2" --arg s "$(if [ "$i" -lt "$3" ]; then echo pass; else echo fail; fi)" \
      '{v:1, ts:"2026-09-24T00:00:00Z", source:"inline", run:null, repoName:"r", level:"deep", task:null,
        candidates:[{label:"c", vendor:"claude", model:$m, effort:$e, status:$s, modelId:$m, modelIdSource:"pinned"}], applied:null}' >> "$SV"
    i=$((i + 1))
  done
}
svl claude-opus-5-5 high 10 10; svl claude-opus-5 medium 20 0; svl claude-opus-5-5 medium 20 0
run_pr report --json --tiers "$TIERS" --ledger "$SV"
chk "RS1 an older version (claude-opus-5@medium, 20/20, cheaper) is never a challenger: no decision, no proposal back to it" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq "[.decisions[] | select(.challenger.modelId == \"claude-opus-5\")] | length")" = 0 ] &&
   [ "$(printf "%s" "$OUT" | jq -r "[.proposals[] | select(.level == \"deep\" and .vendor == \"claude\") | .to.model + \"·\" + .to.effort] | join(\",\")")" = "claude-opus-5-5·medium" ]'
run_pr history --json --tiers "$TIERS" --ledger "$SV"
chk "RS1b ...it stays in history" '[ "$(printf "%s" "$OUT" | jq -r "[.history[] | select(.level == \"deep\" and .vendor == \"claude\") | .entries[].modelId] | unique | join(\",\")")" = "claude-opus-5,claude-opus-5-5" ]'

# --- RJ: tuning.rejected (M27) ---------------------------------------------------------
jq '.tuning.rejected = [{"level":"builder","vendor":"claude","model":"claude-haiku-4-5-20251001","effort":"low"}]' "$TIERS_RULE" > "$T/tiers-rej.json"
run_pr report --json --tiers "$T/tiers-rej.json" --ledger "$RL_SAVE"
chk "RJ1 a rejected challenger that would qualify gets verdict rejected (why names it), and no proposal; other levels unaffected" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r ".decisions[] | select(.level == \"builder\" and .vendor == \"claude\" and .challenger.modelId == \"claude-haiku-4-5-20251001\") | .verdict")" = rejected ] &&
   printf "%s" "$OUT" | jq -r ".decisions[] | select(.verdict == \"rejected\") | .why" | grep -q "rejected by Alex (tuning.rejected); would propose: cheaper" &&
   [ "$(printf "%s" "$OUT" | jq -r "[.proposals[] | .level + \"/\" + .vendor] | join(\",\")")" = "quick/claude" ]'
jq '.tuning.rejected = [{"level":"builder","vendor":"claude","model":"claude-haiku-4-5-20251001","effort":"low","until":"2026-09-25"}]' "$TIERS_RULE" > "$T/tiers-rej2.json"
run_pr report --json --tiers "$T/tiers-rej2.json" --ledger "$RL_SAVE"
RJ_TODAY=$(printf '%s' "$OUT" | jq -r '[.proposals[] | .level + "/" + .vendor] | join(",")')
export PARITY_TODAY=2026-09-26
run_pr report --json --tiers "$T/tiers-rej2.json" --ledger "$RL_SAVE"
export PARITY_TODAY=2026-09-25
chk "RJ2 until is inclusive: still rejected on its date, proposed again the day after" \
  '[ "$RJ_TODAY" = "quick/claude" ] && [ "$(printf "%s" "$OUT" | jq -r "[.proposals[] | .level + \"/\" + .vendor] | join(\",\")")" = "builder/claude,quick/claude" ]'
jq '.tuning.rejected = [{"level":"builder","vendor":"claude","model":"claude-sonnet-5","effort":"high"}]' "$TIERS" > "$T/tiers-rej3.json"
run_pr rates --json --tiers "$T/tiers-rej3.json" --ledger "$T/l-proposal.jsonl"
chk "RJ3 a rejected proposal no longer pins its level to explore: the RA3 ledger drops to maintain" '[ "$RC" -eq 0 ] && [ "$(rstate builder)" = "maintain:0.05" ]'

# --- RR: review revisions (M15) --------------------------------------------------------
RVL="$T/rr.jsonl"
run_pr ingest-review --tiers "$TIERS" --ledger "$RVL" --result "$T/review.json" --repo-name voron --ts 2026-09-24T12:00:00Z
run_pr ingest-review --tiers "$TIERS" --ledger "$RVL" --result "$T/review.json" --repo-name voron --resolved "$T/resolved.json" --ts 2026-09-25T12:00:00Z
chk "RR1 --resolved on an ingested review appends revision 2 of the same run (run = outDir basename, no --run needed)" \
  '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 1 ] && [ "$(j .revision)" = 2 ] && [ "$(jq -r "[.run, .revision] | map(tostring) | join(\":\")" "$RVL" | paste -sd, -)" = "rv-run-1:1,rv-run-1:2" ]'
run_pr ingest-review --tiers "$TIERS" --ledger "$RVL" --result "$T/review.json" --repo-name voron --resolved "$T/resolved.json"
chk "RR1b the same resolved content again is skipped" '[ "$RC" -eq 0 ] && [ "$(j .lines)" = 0 ] && [ "$(nlines "$RVL")" = 2 ]'
run_pr report --json --tiers "$TIERS" --ledger "$RVL"
chk "RR2 report reads only the latest revision: 1 review run, sonnet precision 0.667 (revision 2, not the mean with revision 1's 0.5), 1 superseded revision" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r "[.reviews.lines, .reviews.supersededRevisions] | map(tostring) | join(\",\")")" = "1,1" ] &&
   [ "$(printf "%s" "$OUT" | jq -r ".reviews.groups[] | select(.modelId == \"claude-sonnet-5\") | [.reviews, (.meanPrecision * 1000 | round)] | map(tostring) | join(\",\")")" = "1,667" ]'
jq '. + {extendedFrom: {base: .base, head: .head, outDir: .outDir, reviewers: [.reviewers[].label], items: 7}, newItems: [], superseded: ["rv-astra"]}
  | .reviewers |= map(if .label == "rv-astra" then .status = "superseded" | .findings = 0 else . end)
  | .reviewers += [{"label":"rv-astra-2","vendor":"codex","level":"deep","model":"gpt-6-astra","effort":"high","status":"ok","findings":1,"tokens":10,"seconds":1}]
  | .items[3].foundBy += ["rv-astra-2"]' "$T/review.json" > "$T/review-ext.json"
run_pr ingest-review --tiers "$TIERS" --ledger "$RVL" --result "$T/review-ext.json" --repo-name voron
chk "RR3 an extended result (extendedFrom, same outDir) is revision 3; the superseded reviewer keeps status superseded with null scores" \
  '[ "$RC" -eq 0 ] && [ "$(j .revision)" = 3 ] && [ "$(tail -n 1 "$RVL" | jq -r ".reviewers[] | select(.label == \"rv-astra\") | [.status, (.precision|tostring)] | join(\",\")")" = "superseded,null" ]'
run_pr report --json --tiers "$TIERS" --ledger "$RVL"
chk "RR3b report: superseded is its own count, never unavailable (astra: 1 review ok, 0 unavailable, 1 superseded)" \
  '[ "$(printf "%s" "$OUT" | jq -r ".reviews.groups[] | select(.modelId == \"gpt-6-astra\") | [.reviews, .unavailable, .superseded] | map(tostring) | join(\",\")")" = "1,0,1" ]'
jq '.items[1].verdict = "real"' "$T/review.json" > "$T/review-other.json"
RVL_SUM=$(cksum < "$RVL")
run_pr ingest-review --tiers "$TIERS" --ledger "$RVL" --result "$T/review-other.json" --repo-name voron
chk "RR4 a different review result under an ingested run id, neither extended nor --resolved, is refused (exit 2)" '[ "$RC" -eq 2 ] && [ "$(cksum < "$RVL")" = "$RVL_SUM" ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
