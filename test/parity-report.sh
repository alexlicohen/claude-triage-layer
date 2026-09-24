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
run_pr ingest-compare --tiers "$TIERS" --result "$T/compare.json" --repo-name myrepo --level builder --source inline \
  --task sub-1 --applied claude-builder --ts 2026-09-24T10:00:00Z
L1=$(head -n 1 "$DEFAULT_LEDGER" 2>/dev/null)
chk "R1 ingest-compare appends ONE line to the tiers file's tuning.ledger (~ = HOME) and says so" \
  '[ "$RC" -eq 0 ] && [ "$(nlines "$DEFAULT_LEDGER")" = 1 ] && [ "$(j .ledger)" = "$DEFAULT_LEDGER" ] && [ "$(j .graded)" = 2 ]'
chk "R1b the line has exactly the schema keys, with the passed ts/source/repoName/level/task/applied" \
  '[ "$(printf "%s" "$L1" | jq -c "keys")" = "[\"applied\",\"candidates\",\"level\",\"repoName\",\"run\",\"source\",\"task\",\"ts\",\"v\"]" ] &&
   [ "$(printf "%s" "$L1" | jq -r "[.v,.ts,.source,.repoName,.level,.task,.applied] | map(tostring) | join(\" \")")" = "1 2026-09-24T10:00:00Z inline myrepo builder sub-1 claude-builder" ]'
chk "R1c each candidate has exactly label/vendor/model/effort/status/totalTokens/seconds" \
  '[ "$(printf "%s" "$L1" | jq -c "[.candidates[] | keys] | unique")" = "[[\"effort\",\"label\",\"model\",\"seconds\",\"status\",\"totalTokens\",\"vendor\"]]" ]'
chk "R1d a null model/effort is filled from the tiers file (claude builder = sonnet/medium; agy = its model, no effort)" \
  '[ "$(printf "%s" "$L1" | jq -r ".candidates[0] | .model + \"/\" + .effort")" = "sonnet/medium" ] && [ "$(printf "%s" "$L1" | jq -r ".candidates[2].model")" = "gemini-3.1-pro-high" ] && [ "$(printf "%s" "$L1" | jq -r ".candidates[2].effort")" = null ]'
chk "R1e a non-graded status is kept as itself (unavailable), never recorded as a fail" \
  '[ "$(printf "%s" "$L1" | jq -r "[.candidates[].status] | join(\",\")")" = "pass,fail,unavailable" ]'
chk "R1f no target-repo content: no patch path, diffstat, tail or brief text reaches the ledger" \
  '! grep -qi "secret" "$DEFAULT_LEDGER" && ! grep -q "/work" "$DEFAULT_LEDGER" && ! grep -q "diffstat\|patch\|tail" "$DEFAULT_LEDGER"'

LEDGER="$T/l-refuse.jsonl"
for bad in "--repo-name /work/SECRETREPO" "--repo-name a/b" "--task a/b/c.py" "--source nightly" "--level expert" "--applied nobody" "--ts yesterday"; do
  # shellcheck disable=SC2086  # $bad is deliberately split into flag + value
  run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline $bad
  chk "R2 ingest-compare refuses [$bad] with exit 2 and writes nothing" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
done
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline --task "brief text with spaces"
chk "R2a a --task that is text, not an id token, is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ] && printf "%s" "$ERR" | grep -q "id token"'
printf '{"ranking":[],"tasks":[]}\n' > "$T/notcompare.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/notcompare.json" --repo-name myrepo --level builder --source inline
chk "R2b a result with no candidates array is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
jq '.candidates[0].label = "has space"' "$T/compare.json" > "$T/badlabel.json"
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/badlabel.json" --repo-name myrepo --level builder --source inline
chk "R2c a candidate label that is not an id token is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$LEDGER" ]'
run_pr ingest-compare --tiers "$TIERS" --ledger "$LEDGER" --result "$T/compare.json" --repo-name myrepo --level builder --source inline
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
chk "R3c rep labels are kept (a, a-r2), models/efforts resolved from the candidate's own level (a = builder sonnet/medium)" \
  '[ "$(jq -r ".candidates[0] | .label + \":\" + .model + \":\" + .effort + \":\" + .status" "$PL" | paste -sd, -)" = "a:sonnet:medium:pass,a-r2:sonnet:medium:fail,x:gpt-6-astra:high:pass" ]'
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
chk "R4b the parity aggregate becomes pass/fail lines per band with the band's level and a resolved model" \
  '[ "$(jq -r "select(.band) | [.level, .candidates[0].model, (.candidates[0].effort // \"-\"), .candidates[0].status] | join(\":\")" "$ML" | sort | uniq -c | tr -s " " | paste -sd, -)" = " 2 builder:gemini-3.1-pro-high:-:fail, 1 builder:gpt-6-sol:medium:pass, 1 quick:gpt-6-sol:medium:fail, 2 quick:gpt-6-sol:medium:pass" ]'
chk "R4c every migrated line is marked, carries a legacy run id, and keeps no task text" \
  '[ "$(jq -r ".migrated" "$ML" | sort -u)" = vendor-parity.jsonl ] && [ "$(jq -r ".run" "$ML" | sort -u | paste -sd"|" -)" = "legacy:2026-09-20:toy-repo:builder|legacy:pilot wf_1" ] && ! grep -q "smoke" "$ML"'
run_pr migrate --tiers "$TIERS" --ledger "$ML" --from "$T/legacy.jsonl"
chk "R4d migrate again: nothing appended (idempotent by run id)" '[ "$RC" -eq 0 ] && [ "$(nlines "$ML")" = 7 ] && [ "$(j .migrated)" = 0 ] && [ "$(j .skipped)" = 2 ]'
printf '%s\n' '{"date":"2026-09-22","run":"pilot2","bands":[4],"candidates":[{"label":"claude-fable-xhigh","b4":{"pass":1,"fail":0}}]}' >> "$T/legacy.jsonl"
run_pr migrate --tiers "$TIERS" --ledger "$ML" --from "$T/legacy.jsonl"
chk "R4e a legacy line added later is the only one migrated next time" '[ "$(nlines "$ML")" = 8 ] && [ "$(j .migrated)" = 1 ] && [ "$(tail -n 1 "$ML" | jq -r ".level + \":\" + .candidates[0].model")" = top:fable ]'

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

run_pr report --tiers "$TIERS" --ledger "$RL" --json
REP="$OUT"
g() { printf '%s' "$REP" | jq -r --arg l "$1" --arg v "$2" --arg m "$3" --arg e "$4" \
  ".groups[] | select(.level == \$l and .vendor == \$v and .model == \$m and .effort == \$e) | $5"; }
d() { printf '%s' "$REP" | jq -r --arg l "$1" --arg v "$2" --arg m "$3" --arg e "$4" \
  ".decisions[] | select(.level == \$l and .vendor == \$v and .challenger.model == \$m and .challenger.effort == \$e) | $5"; }
chk "R5 report --json exits 0; the malformed ledger line is counted, not fatal" '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$REP" | jq .malformed)" = 1 ]'
chk "R5b Wilson 95% lower bounds: 10/10 = 0.7225, 40/40 = 0.9124, 5/10 = 0.2366, 0/10 = 0, 9/10 = 0.5958" \
  '[ "$(g deep claude sonnet high ".wilsonLB * 10000 | round")" = 7225 ] && [ "$(g builder claude haiku low ".wilsonLB * 10000 | round")" = 9124 ] &&
   [ "$(g deep codex gpt-6-sol medium ".wilsonLB * 10000 | round")" = 2366 ] && [ "$(g deep codex gpt-6-luna low ".wilsonLB")" = 0 ] &&
   [ "$(g deep claude opus high ".wilsonLB * 10000 | round")" = 5958 ]'
chk "R5c non-graded statuses are excluded: the sonnet·medium incumbent stays n=40 (36 pass) with 9 excluded" \
  '[ "$(g builder claude sonnet medium "[.n, .passes, .excluded] | join(\",\")")" = "40,36,9" ] && [ "$(g builder claude sonnet medium .rate)" = 0.9 ]'
chk "R5d tokens and seconds are averaged per group" '[ "$(g builder claude haiku low "[.meanTokens, .meanSeconds] | join(\",\")")" = "100,2" ]'
chk "R6 cheaper + Wilson LB >= incumbent rate - tolerance -> propose (builder/claude haiku·low)" \
  '[ "$(d builder claude haiku low ".direction + \":\" + .verdict")" = "cheaper:propose" ]'
chk "R6b cheaper with a perfect POINT rate but a low Wilson LB -> keep (deep/claude sonnet·high 10/10 vs opus 0.9)" \
  '[ "$(d deep claude sonnet high ".direction + \":\" + .verdict")" = "cheaper:keep" ]'
chk "R6c pricier past the margin -> propose (quick/claude sonnet·medium, +0.4)" \
  '[ "$(d quick claude sonnet medium ".direction + \":\" + .verdict")" = "pricier:propose" ]'
chk "R6d pricier below the margin -> keep, even with a high Wilson LB (top/codex astra·max, +0.1)" \
  '[ "$(d top codex gpt-6-astra max ".direction + \":\" + .verdict")" = "pricier:keep" ]'
chk "R6e fewer than minN graded runs on either side -> insufficient-data, naming the runs still needed (5 and 1)" \
  '[ "$(d builder codex gpt-6-luna low ".verdict + \":\" + (.needIncumbent|tostring) + \":\" + (.needChallenger|tostring)")" = "insufficient-data:5:1" ] &&
   d builder codex gpt-6-luna low .why | grep -q "needs 5 more graded run(s) of the incumbent and 1 of the challenger"'
chk "R6f a model outside the cheapness order is unranked, never proposed" '[ "$(d deep codex gpt-7-x high .verdict)" = unranked ]'
chk "R6g exactly two proposals: builder/claude -> haiku·low (cheaper), quick/claude -> sonnet·medium (pricier)" \
  '[ "$(printf "%s" "$REP" | jq -r "[.proposals[] | .level + \"/\" + .vendor + \"->\" + .to.model + \"·\" + .to.effort + \":\" + .direction] | join(\",\")")" = "builder/claude->haiku·low:cheaper,quick/claude->sonnet·medium:pricier" ]'
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
run_pr report --tiers "$TIERS" --ledger "$T/l-both.jsonl" --json
chk "R6i with a qualifying cheaper AND pricier challenger at one level x vendor, ONE proposal: the pricier (quality first)" \
  '[ "$(printf "%s" "$OUT" | jq -r "[.decisions[] | select(.level == \"deep\" and .vendor == \"codex\" and .verdict == \"propose\") | .direction] | sort | join(\",\")")" = "cheaper,pricier" ] &&
   [ "$(printf "%s" "$OUT" | jq -r "[.proposals[] | select(.level == \"deep\" and .vendor == \"codex\")] | length")" = 1 ] &&
   [ "$(printf "%s" "$OUT" | jq -r ".proposals[] | select(.level == \"deep\" and .vendor == \"codex\") | .to.model + \"·\" + .to.effort")" = "gpt-6-astra·xhigh" ]'

run_pr report --tiers "$TIERS" --ledger "$RL"
chk "R7 markdown: a table per level, the incumbent marked, decisions with reasons, the proposals, and the never-writes line" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^## builder" && printf "%s" "$OUT" | grep -q "| claude | sonnet | medium | 40 | 36 | 0.9 | .* | 9 | .* | incumbent |" &&
   printf "%s" "$OUT" | grep -q "insufficient data: needs 5 more" && printf "%s" "$OUT" | grep -q "^- builder/claude: sonnet · medium -> haiku · low (cheaper" &&
   printf "%s" "$OUT" | grep -q "never writes tiers.json"'
run_pr report --tiers "$TIERS" --ledger "$T/none.jsonl"
chk "R7b an absent ledger reports no data (exit 0, no proposals)" '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "None: no challenger clears the rule"'

# --- R8: tiers.json is never written; invalid tuning is refused ---------------
run_pr report --tiers "$TIERS" --ledger "$TIERS"
chk "R8 a --ledger that IS the tiers file is refused (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "is the tiers file"'
run_pr ingest-compare --tiers "$TIERS" --ledger "$TIERS" --result "$T/compare.json" --repo-name r --level builder --source inline
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

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
