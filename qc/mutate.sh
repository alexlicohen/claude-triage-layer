#!/bin/bash
# qc/mutate.sh — mutation-testing gate for the triage-layer installer/uninstaller/
# statusline/drift/workflow scripts.
#
# Implements the "tests must have teeth, proven by mutation" principle: for each
# cataloged bug (a real regression someone could reintroduce), copy the repo to a
# fresh temp dir, apply ONLY that bug to the copy, run the copy's own test suite
# against the copy, and see whether the suite notices.
#
#   suite goes RED   -> KILLED   (good: the bug is caught, the guard has teeth)
#   suite stays GREEN -> SURVIVOR (bad: an untested guard — reported loudly)
#   mutation didn't even apply, or the suite couldn't run at all -> ERROR (harness
#     failure, never silently counted as a kill)
#
# Never mutates this repo in place — every mutation is applied to a throwaway
# rsync copy under a mktemp -d root, which is removed on exit.
#
# Usage:
#   qc/mutate.sh                 run the full catalog
#   qc/mutate.sh --only 7        run a single mutation id (debugging)
#   qc/mutate.sh --strict        also exit non-zero if any mutation SURVIVED
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STRICT=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --only)
      ONLY="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--strict] [--only ID]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# 35 (the no-PATCH-line guard) was retired with that rule: staged worktrees made it
# moot — the grade is now the worktree diff, never a patch file a candidate wrote.
ALL_IDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 36 37 38 39 40"
RUN_IDS="$ALL_IDS"
if [ -n "$ONLY" ]; then
  RUN_IDS="$ONLY"
fi

WORK_ROOT=""
cleanup() {
  if [ -n "$WORK_ROOT" ] && [ -d "$WORK_ROOT" ]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/triage-mutate.XXXXXX") || {
  echo "ERROR: could not create a working temp dir" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Mutation catalog — data-driven. mut_file/mut_desc/mut_suite are the table;
# apply_mutation/verify_mutation switch on id for the actual edit + check.
# -----------------------------------------------------------------------------
mut_file() {
  case "$1" in
    1) echo "install.sh" ;;
    2) echo "install.sh" ;;
    3) echo "install.sh" ;;
    4) echo "uninstall.sh" ;;
    5) echo "uninstall.sh" ;;
    6) echo "statusline.sh" ;;
    7) echo "workflows/triage-exec.js" ;;
    8) echo "workflows/triage-exec.js" ;;
    9) echo "workflows/triage-exec.js" ;;
    10) echo "drift.sh" ;;
    11) echo "workflows/triage-exec.js" ;;
    12) echo "scripts/triage-cache-segment.sh" ;;
    13) echo "scripts/ext-run.sh" ;;
    14) echo "scripts/ext-run.sh" ;;
    15) echo "scripts/ext-run.sh" ;;
    16) echo "workflows/triage-exec.js" ;;
    17) echo "workflows/triage-exec.js" ;;
    18) echo "install.sh" ;;
    19) echo "install.sh" ;;
    20) echo "install.sh" ;;
    21) echo "uninstall.sh" ;;
    22) echo "workflows/triage-exec.js" ;;
    23) echo "workflows/triage-exec.js" ;;
    24) echo "scripts/ext-run.sh" ;;
    25) echo "scripts/ext-run.sh" ;;
    26) echo "scripts/ext-run.sh" ;;
    27) echo "scripts/ext-run.sh" ;;
    28) echo "workflows/triage-exec.js" ;;
    29) echo "workflows/triage-exec.js" ;;
    30) echo "workflows/triage-exec.js" ;;
    31) echo "workflows/triage-compare.js" ;;
    32) echo "scripts/patch-check.sh" ;;
    33) echo "install.sh" ;;
    34) echo "workflows/triage-compare.js" ;;
    36) echo "workflows/triage-compare.js" ;;
    37) echo "workflows/triage-compare.js" ;;
    38) echo "workflows/triage-compare.js" ;;
    39) echo "scripts/stage-worktree.sh" ;;
    40) echo "scripts/ext-run.sh" ;;
    *) echo "" ;;
  esac
}

mut_desc() {
  case "$1" in
    1) echo "install.sh: remove the trailing-newline guard before the @triage.md append" ;;
    2) echo "install.sh: remove the upfront 'jq empty' settings.json validation" ;;
    3) echo "install.sh: replace symlink-preserving apply_settings write with a plain mv" ;;
    4) echo "uninstall.sh: revert per-name agent removal to the triage-*.md glob" ;;
    5) echo "uninstall.sh: drop the permissions.deny Fable-rule cleanup line" ;;
    6) echo "statusline.sh: remove the non-numeric PCT case-guard" ;;
    7) echo "triage-exec.js: assess() always reports incomplete:false (a dead/absent gate passes silently)" ;;
    8) echo "triage-exec.js: remove the runGate retry (gate tried once, null returned immediately)" ;;
    9) echo "triage-exec.js: make matchedFiles() always return [] (attribution always fails)" ;;
    10) echo "drift.sh: remove UNEXPECTED_DRIFT=1 from the MISSING branch" ;;
    11) echo "triage-exec.js: make bad() a no-op (malformed plan args no longer throw before spawning)" ;;
    12) echo "triage-cache-segment.sh: revert the warm-boolean jq filter to '// empty' (jq's // swallows a literal false, so a cold cache silently renders nothing)" ;;
    13) echo "ext-run.sh: drop the denied_actions gate (a run whose tool calls were all denied is reported as a pass)" ;;
    14) echo "ext-run.sh: drop the empty-response gate (exit 0 + status SUCCESS alone is treated as usable output)" ;;
    15) echo "ext-run.sh: weaken the deny-list path match from path-component equality to substring (a sibling repo such as clip-creators-lab is refused too)" ;;
    16) echo "triage-exec.js: danger-zone routing no longer reroutes agy, so overflow:true / vendor agy sends danger subtasks off-vendor" ;;
    17) echo "triage-exec.js: an external subtask whose CLI produced no work falls back to Claude builder instead of the SAME level" ;;
    18) echo "install.sh: neuter check_force_override (the CLAUDE_CODE_SUBAGENT_MODEL_FORCE warning never prints)" ;;
    19) echo "install.sh: neuter is_legacy_subagent_model (a previous installer default is never upgraded, dry-run never says so)" ;;
    20) echo "install.sh: the settings merge reverts to set-only-when-unset (dry-run promises an upgrade the write never makes)" ;;
    21) echo "uninstall.sh: drop LEGACY_SUBAGENT_MODELS from the removal set (an old install's subagent model is left behind)" ;;
    22) echo "triage-exec.js: remove the deep@max rung (an ESCALATE on a below-max deep attempt goes straight to Fable)" ;;
    23) echo "triage-exec.js: runFable() always takes the deep@max fallback (Fable unavailable after a failed deep@max re-runs it)" ;;
    24) echo "ext-run.sh: a level/mode missing from tiers.json falls back to a default model instead of refusing" ;;
    25) echo "ext-run.sh: drop the codex empty-response gate (rc 0 with an empty -o final message is treated as usable output)" ;;
    26) echo "ext-run.sh: the deny check is skipped for codex (clip-creator / .codex-deny no longer refuse)" ;;
    27) echo "ext-run.sh: drop -c sandbox_workspace_write.exclude_slash_tmp=true (codex workspace-write can write anywhere under /tmp)" ;;
    28) echo "triage-exec.js: the codex danger effort floor is dropped (danger work runs on codex below effort high)" ;;
    29) echo "triage-exec.js: a failed external subtask is retried sideways on the same vendor instead of on Claude" ;;
    30) echo "triage-exec.js: crossReview 'both' spawns only one cross-reviewer (codex never asked)" ;;
    31) echo "triage-compare.js: grades a candidate from its own CHECK rc self-report instead of patch-check's result" ;;
    32) echo "patch-check.sh: cleanup_wt is a no-op (worktrees and their git bookkeeping are left behind)" ;;
    33) echo "install.sh: the .driftignore fork skip is limited to --files-only again (a bare install clobbers triage.md)" ;;
    34) echo "triage-compare.js: the outDir-under-repo entry-contract check is dropped (the staged worktrees and patches land in the real tree, which leakcheck then reports as a self-inflicted LEAK)" ;;
    36) echo "triage-compare.js: the external-candidate files requirement is dropped (a non-claude candidate runs with no files, and triage-external refuses it mid-run instead of the plan being rejected up front)" ;;
    37) echo "triage-compare.js: an external candidate gets the REAL repo as WORKDIR instead of its staged worktree (the live-run leak: ext-run applies into the real tree)" ;;
    38) echo "triage-compare.js: the leakcheck result is ignored (a candidate that wrote into the real repo is graded as if nothing happened)" ;;
    39) echo "stage-worktree.sh: diff stages only tracked files (git add -u), so new/untracked files a candidate created are silently dropped from its patch" ;;
    40) echo "ext-run.sh: drop the git-common-dir deny check (a linked worktree created outside a deny-listed repo, or an --input file in one, bypasses clip-creator and the .agy-deny/.codex-deny markers)" ;;
    *) echo "" ;;
  esac
}

# Which suite exercises this mutation's file: "roundtrip" (test/roundtrip.sh),
# "scenarios" (test/workflow-scenarios.mjs), "extrun" (test/ext-run.sh),
# "compare" (test/compare-scenarios.mjs), "patchcheck" (test/patch-check.sh) or
# "stagewt" (test/stage-worktree.sh).
mut_suite() {
  case "$1" in
    1|2|3|4|5|6|10|12|18|19|20|21|33) echo "roundtrip" ;;
    7|8|9|11|16|17|22|23|28|29|30) echo "scenarios" ;;
    13|14|15|24|25|26|27|40) echo "extrun" ;;
    31|34|36|37|38) echo "compare" ;;
    32) echo "patchcheck" ;;
    39) echo "stagewt" ;;
    *) echo "" ;;
  esac
}

# The test file behind a suite name — single owner of that mapping, used by the
# baseline-red reporting below as well as run_suite.
suite_file() {
  case "$1" in
    roundtrip) echo "test/roundtrip.sh" ;;
    scenarios) echo "test/workflow-scenarios.mjs" ;;
    extrun) echo "test/ext-run.sh" ;;
    compare) echo "test/compare-scenarios.mjs" ;;
    patchcheck) echo "test/patch-check.sh" ;;
    stagewt) echo "test/stage-worktree.sh" ;;
    *) echo "" ;;
  esac
}

# One-line suggested covering test for a SURVIVOR — filled in only for the two
# mutations the catalog predicts as survivors; empty otherwise.
mut_suggested_test() {
  case "$1" in
    4) echo "roundtrip.sh: pre-seed CLAUDE_DIR/agents/ with a non-triage-owned triage-*.md (e.g. a user-authored 'triage-mine.md'), run uninstall, assert it still exists (glob-revert would delete it)." ;;
    10) echo "add a test/drift-check.sh sandbox case: point CLAUDE_DIR at a dir missing an installed file, run drift.sh, assert exit code is non-zero (glob/line-removal would leave it 0)." ;;
    *) echo "" ;;
  esac
}

# -----------------------------------------------------------------------------
# Generic anchor-based mutation helpers. Anchors are fixed strings (grep -F),
# so mutations survive unrelated edits shifting line numbers elsewhere in the
# file — the location is discovered at run time, never hardcoded.
# -----------------------------------------------------------------------------

# Print the 1-based line number of the first line containing fixed string $2
# in file $1. Prints nothing if not found.
find_anchor() {
  grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1
}

# Delete N lines starting at the line matching a fixed-string anchor.
# $1 = file, $2 = anchor, $3 = number of lines to delete.
mut_delete_block() {
  local file anchor n start end
  file="$1"
  anchor="$2"
  n="$3"
  start=$(find_anchor "$file" "$anchor")
  if [ -z "$start" ]; then
    return 1
  fi
  end=$((start + n - 1))
  # Write back via `cat >` (not `mv`) so the EXISTING file's permission bits
  # (notably the executable bit on install.sh/uninstall.sh/statusline.sh/drift.sh)
  # are preserved — a fresh awk-output tmp file would get the umask's default
  # mode, silently stripping +x and turning every mutation into a false
  # "permission denied" kill instead of exercising the actual bug.
  awk -v s="$start" -v e="$end" 'NR < s || NR > e' "$file" > "$file.mtmp" && cat "$file.mtmp" > "$file" && rm -f "$file.mtmp"
}

# Replace N lines starting at a fixed-string anchor with the contents of a
# replacement file (each line of which is printed verbatim, no escaping needed).
# $1 = file, $2 = anchor, $3 = number of lines to replace, $4 = replacement file.
mut_replace_block() {
  local file anchor n rep start end
  file="$1"
  anchor="$2"
  n="$3"
  rep="$4"
  start=$(find_anchor "$file" "$anchor")
  if [ -z "$start" ]; then
    return 1
  fi
  end=$((start + n - 1))
  awk -v s="$start" -v e="$end" -v repfile="$rep" '
    BEGIN {
      rn = 0
      while ((getline line < repfile) > 0) { rn++; rl[rn] = line }
    }
    NR < s { print; next }
    NR == s { for (i = 1; i <= rn; i++) print rl[i]; next }
    NR > s && NR <= e { next }
    { print }
  ' "$file" > "$file.mtmp" && cat "$file.mtmp" > "$file" && rm -f "$file.mtmp"
}

# -----------------------------------------------------------------------------
# apply_mutation ID DEST_REPO_DIR — mutate the one file $DEST_REPO_DIR/$(mut_file
# ID) in place. Returns 1 (and prints nothing) if the anchor could not be found,
# which the caller treats as a harness ERROR (mutation did not apply).
# -----------------------------------------------------------------------------
apply_mutation() {
  local id dest target rep
  id="$1"
  dest="$2"
  target="$dest/$(mut_file "$id")"
  rep="$WORK_ROOT/rep-$id.txt"

  case "$id" in
    1)
      # install.sh: delete the 3-line trailing-newline guard.
      mut_delete_block "$target" \
        '    if [ -s "$CLAUDE_DIR/CLAUDE.md" ] && [ -n "$(tail -c1 "$CLAUDE_DIR/CLAUDE.md")" ]; then' 3
      ;;
    2)
      # install.sh: delete the 3-line upfront `jq empty` validation.
      mut_delete_block "$target" 'if [ -f "$SETTINGS" ]; then' 3
      ;;
    3)
      # install.sh: apply_settings body -> plain mv (drop symlink handling).
      printf '  mv "$1" "$SETTINGS"\n' > "$rep"
      mut_replace_block "$target" \
        '  if [ -L "$SETTINGS" ]; then cat "$1" > "$SETTINGS" && rm -f "$1"; else mv "$1" "$SETTINGS"; fi' 1 "$rep"
      ;;
    4)
      # uninstall.sh: per-name loop -> glob rm (4 lines -> 1 line).
      printf 'rm -f "$CLAUDE_DIR"/agents/triage-*.md\n' > "$rep"
      mut_replace_block "$target" 'for a in $AGENTS; do' 4 "$rep"
      ;;
    5)
      # uninstall.sh: drop the permissions.deny cleanup line from the jq filter.
      mut_delete_block "$target" \
        '    | (if .permissions.deny  then .permissions.deny  -= $fable   else . end)' 1
      ;;
    6)
      # statusline.sh: case-guard (9 lines, `case ... esac`) -> bare `[ "$PCT" -ge 60 ]`.
      cat > "$rep" <<'MUT6'
if [ "$PCT" -ge 60 ]; then
  CTX=$(printf '\033[1;31m⚠ CONTEXT %s%%\033[0m' "$PCT")
else
  CTX=$(printf 'ctx %s%%' "$PCT")
fi
MUT6
      mut_replace_block "$target" 'case "$PCT" in' 9 "$rep"
      ;;
    7)
      # triage-exec.js: assess()'s tri-state incomplete flag -> always false, so a dead
      # gate (or a plan that gated nothing at all) is reported as a clean pass.
      printf '    incomplete: false, // MUTATED: incomplete tri-state disabled\n' > "$rep"
      mut_replace_block "$target" \
        '    incomplete: v.checks.some(c => c.result == null)' 1 "$rep"
      ;;
    8)
      # triage-exec.js: disable the gate retry surgically — the retry condition
      # becomes `if (false)`, so the gate is tried once and null is returned
      # immediately. 1-line replace: robust to surrounding runGate changes
      # (a 9-line block replace went stale when budget logic reshaped runGate).
      printf '    if (false) { // MUTATED: retry disabled\n' > "$rep"
      mut_replace_block "$target" '    if (out == null && !ceilinged) {' 1 "$rep"
      ;;
    9)
      # triage-exec.js: matchedFiles() -> always [] (3 lines -> 3 lines).
      {
        printf 'function matchedFiles(r, text) {\n'
        printf '  return []\n'
        printf '}\n'
      } > "$rep"
      mut_replace_block "$target" 'function matchedFiles(r, text) {' 3 "$rep"
      ;;
    10)
      # drift.sh: drop UNEXPECTED_DRIFT=1 from the MISSING branch (first occurrence
      # only — the FORKED branch's own UNEXPECTED_DRIFT=1 must survive untouched).
      mut_delete_block "$target" '      UNEXPECTED_DRIFT=1' 1
      ;;
    11)
      # triage-exec.js: bad() stops throwing, so a malformed plan is no longer
      # rejected before any spawn (3 lines -> 3 lines).
      {
        printf 'function bad(msg) {\n'
        printf '  return  // MUTATED: args validation disabled\n'
        printf '}\n'
      } > "$rep"
      mut_replace_block "$target" 'function bad(msg) {' 3 "$rep"
      ;;
    12)
      # triage-cache-segment.sh: WARM_RAW's explicit true/false jq filter ->
      # `// empty`, which jq treats a literal `false` as absent under — a cold
      # cache (warm:false) is then indistinguishable from warm being missing,
      # so the segment silently renders nothing instead of "cache N% cold".
      printf "WARM_RAW=\$(printf '%%s' \"\$input\" | jq -r '.prompt_cache.warm // empty' 2>/dev/null) # MUTATED: swallows false\n" > "$rep"
      mut_replace_block "$target" \
        "WARM_RAW=\$(printf '%s' \"\$input\" | jq -r 'if .prompt_cache.warm == true then \"true\" elif .prompt_cache.warm == false then \"false\" else empty end' 2>/dev/null)" \
        1 "$rep"
      ;;
    13)
      # ext-run.sh: delete agy's 3-line denied_actions gate. agy reports
      # status:SUCCESS with an empty .response when every tool call was denied,
      # so without this gate a denied run is indistinguishable from a good one.
      mut_delete_block "$target" 'if [ -n "$DENIED" ]; then' 3
      ;;
    14)
      # ext-run.sh: delete agy's 3-line empty-response gate — exit 0 and
      # status SUCCESS are NOT sufficient (a timed-out run looks exactly so).
      mut_delete_block "$target" 'if [ -z "$RESPONSE" ]; then' 3
      ;;
    15)
      # ext-run.sh: deny_check's path match goes from component equality
      # (*/"$name"/*) to substring (*"$name"*) — the classic over-broad-glob bug.
      # A sibling repo whose name merely CONTAINS a deny-listed name is then
      # refused, and the deny-list stops meaning "this repo" and starts meaning
      # "any path spelling it anywhere".
      cat > "$rep" <<'MUT15'
      *"$name"*) die "REFUSED: $p$why is under a deny-listed repo ('$name') - $VENDOR must never read it." "$E_REFUSED" ;; # MUTATED: substring match
MUT15
      mut_replace_block "$target" \
        '      */"$name"/*) die "REFUSED: $p$why is under a deny-listed repo' 1 "$rep"
      ;;
    16)
      # triage-exec.js: the danger guard's agy arm never fires. A danger builder
      # subtask on agy (overflow:true, tier overflow, vendor agy) then falls through
      # to the Claude arm, which lifts the LEVEL to deep but leaves the vendor on
      # agy — correctness-critical work goes off-vendor.
      cat > "$rep" <<'MUT16'
    if (false) { vendor = 'claude'; level = 'deep' } // MUTATED: agy dropped from the danger guard
MUT16
      mut_replace_block "$target" \
        "    if (vendor === 'agy') { vendor = 'claude'; level = 'deep' }" 1 "$rep"
      ;;
    17)
      # triage-exec.js: runOn()'s no-work fallback is hard-coded to builder (the
      # pre-Wave-12 overflow->builder rule) instead of the external step's own level,
      # so a codex quick/deep/top subtask comes back on the wrong Claude agent.
      cat > "$rep" <<'MUT17'
    const onClaude = { level: 'builder', vendor: 'claude', effort: step.effort } // MUTATED: fallback hard-coded to builder
MUT17
      mut_replace_block "$target" \
        "    const onClaude = { level: step.level, vendor: 'claude', effort: step.effort }" 1 "$rep"
      ;;
    18)
      # install.sh: check_force_override returns before warning about either
      # source of CLAUDE_CODE_SUBAGENT_MODEL_FORCE. Mutating the function's
      # OPENING line (not its body) keeps the anchor stable across later edits
      # to the warning text itself.
      cat > "$rep" <<'MUT18'
check_force_override() { # MUTATED: FORCE warning suppressed
  return 0
MUT18
      mut_replace_block "$target" 'check_force_override() {' 1 "$rep"
      ;;
    19)
      # install.sh: the single owner of the legacy-default decision always answers
      # "not legacy", so a settings.json still at an old installer default keeps it
      # forever. Opening-line anchor, as in 18, so the loop body can change freely.
      cat > "$rep" <<'MUT19'
is_legacy_subagent_model() { # MUTATED: legacy upgrade disabled
  return 1
MUT19
      mut_replace_block "$target" 'is_legacy_subagent_model() {' 1 "$rep"
      ;;
    20)
      # install.sh: the jq merge loses its upgrade arm and goes back to the
      # pre-migration "only when unset" line. The helper still says "legacy", so
      # --dry-run keeps promising an upgrade the real write never performs.
      cat > "$rep" <<'MUT20'
  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m else . end)
MUT20
      mut_replace_block "$target" \
        '  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null or $up == "1" then' 1 "$rep"
      ;;
    21)
      # uninstall.sh: the removal set shrinks to the CURRENT default only, so an
      # install made by an older installer leaves its subagent model behind.
      cat > "$rep" <<'MUT21'
    | [$m] as $ours_sub
MUT21
      mut_replace_block "$target" \
        '    | ([$m] + ($legacy | split(" ") | map(select(length > 0)))) as $ours_sub' 1 "$rep"
      ;;
    22)
      # triage-exec.js: delete redoStep()'s deep@max arm. An ESCALATE on a deep
      # attempt below max effort then falls through to nextTier() and spawns Fable
      # directly — the rubric's "only from a failed Opus@max attempt" is lost.
      mut_delete_block "$target" "  if (r.level === 'deep' && !ranMax(r)) return { level: 'deep', vendor, effort: 'max'," 1
      ;;
    23)
      # triage-exec.js: runFable()'s afterMax guard never fires, so Fable being
      # unavailable after a failed deep@max attempt re-runs that same deep@max
      # attempt as the "fallback" (the duplicate the guard exists to prevent).
      printf '  if (false) { // MUTATED: deep@max fallback always taken\n' > "$rep"
      mut_replace_block "$target" '  if (afterMax) {' 1 "$rep"
      ;;
    24)
      # ext-run.sh: resolve_tier's refusal for an absent tiers entry becomes a
      # per-vendor default model — exactly the "never fall back to a default"
      # the tiers contract forbids (a level removed for lost parity would still run).
      cat > "$rep" <<'MUT24'
    case "$VENDOR" in agy) TIER_MODEL=gemini-3.1-pro-high ;; codex) TIER_MODEL=gpt-6-sol; TIER_EFFORT=medium ;; esac # MUTATED: default model fallback
MUT24
      mut_replace_block "$target" '    die "REFUSED: $TIERS has no $where entry' 1 "$rep"
      ;;
    25)
      # ext-run.sh: delete codex's 3-line empty-final-message gate. rc 0 with an
      # empty -o file is then reported as a pass with an empty answer.
      mut_delete_block "$target" '  if [ ! -s "$LASTMSG" ]; then' 3
      ;;
    26)
      # ext-run.sh: deny_check returns early for codex — clip-creator, the
      # CODEX_DENY_REPOS names and .codex-deny markers all stop refusing.
      # Opening-line anchor, as in 18, so the body can change freely.
      cat > "$rep" <<'MUT26'
deny_check() { [ "$VENDOR" = "codex" ] && return 0 # MUTATED: deny check skipped for codex
MUT26
      mut_replace_block "$target" 'deny_check() { # $1 = path. exits E_REFUSED on a hit.' 1 "$rep"
      ;;
    27)
      # ext-run.sh: drop the exclude_slash_tmp override. Verified live: without it
      # codex's workspace-write sandbox can write anywhere under /tmp.
      mut_delete_block "$target" '  set -- "$@" -c sandbox_workspace_write.exclude_slash_tmp=true' 1
      ;;
    28)
      # triage-exec.js: the codex arm of the danger guard keeps its level lift but
      # loses codexDangerEffort(), so danger work runs on codex at whatever effort the
      # plan (or the tiers default) says — quick@low becomes deep@low.
      cat > "$rep" <<'MUT28'
    else if (vendor === 'codex') { level = atLeast(level, 'deep') } // MUTATED: codex danger effort floor dropped
MUT28
      mut_replace_block "$target" \
        "    else if (vendor === 'codex') { level = atLeast(level, 'deep'); effort = codexDangerEffort(level, effort) }" 1 "$rep"
      ;;
    29)
      # triage-exec.js: redoStep() keeps the failed result's vendor, so a codex/agy
      # attempt that failed verification is re-run on the SAME external vendor —
      # the sideways retry the ladder forbids.
      cat > "$rep" <<'MUT29'
  const vendor = r.vendor // MUTATED: retried sideways on the same vendor
MUT29
      mut_replace_block "$target" "  const vendor = 'claude' // every redo runs on Claude" 1 "$rep"
      ;;
    30)
      # triage-exec.js: crossReview 'both' maps to agy alone — one spawn, and the
      # codex second opinion the plan asked for silently never happens.
      cat > "$rep" <<'MUT30'
const CROSS_REVIEW_VENDORS = { agy: ['agy'], codex: ['codex'], both: ['agy'] } // MUTATED: 'both' spawns one
MUT30
      mut_replace_block "$target" "const CROSS_REVIEW_VENDORS = { agy: ['agy'], codex: ['codex'], both: ['agy', 'codex'] }" 1 "$rep"
      ;;
    31)
      # triage-compare.js: grade() trusts the candidate's own `CHECK rc=` line — the
      # exact thing the bake-off exists to avoid (a candidate that claims green but
      # whose patch fails patch-check's independent run would be reported as a pass).
      cat > "$rep" <<'MUT31'
  const status = r.selfRc === 0 ? 'pass' : 'fail' // MUTATED: graded from the self-report
MUT31
      mut_replace_block "$target" "  const status = pc.applies === true && pc.rc === 0 ? 'pass' : 'fail'" 1 "$rep"
      ;;
    32)
      # patch-check.sh: the single owner of worktree removal returns at once, so
      # every graded patch leaves a worktree dir and its .git/worktrees entry behind
      # in the CALLER's repo. Opening-line anchor, as in 18.
      cat > "$rep" <<'MUT32'
cleanup_wt() { return 0 # MUTATED: worktree cleanup skipped
MUT32
      mut_replace_block "$target" 'cleanup_wt() {' 1 "$rep"
      ;;
    33)
      # install.sh: the pre-fix condition — the fork skip fires under --files-only
      # only, so a bare install overwrites a personal triage.md fork (found live
      # 2026-09-23; only a .bak-triage copy survived).
      cat > "$rep" <<'MUT33'
  if [ "$FILES_ONLY" -eq 1 ] && is_ignored "$rel" && [ -e "$dst" ]; then # MUTATED: fork skip limited to --files-only
MUT33
      mut_replace_block "$target" '  if is_ignored "$rel" && [ -e "$dst" ]; then' 1 "$rep"
      ;;
    34)
      # triage-compare.js: drop the outDir-under-repo entry-contract check (5 lines,
      # the whole if-block) — a patch written under repo would then dirty the tree.
      mut_delete_block "$target" 'if (isAbsPath(args.repo) && isAbsPath(args.outDir)) {' 5
      ;;
    36)
      # triage-compare.js: drop the external-candidate-needs-files entry-contract
      # check (3 lines) — a non-claude candidate with no files spawns anyway and
      # triage-external refuses it mid-run instead of the plan failing up front.
      mut_delete_block "$target" "if (candidates.some(c => c.vendor !== 'claude') && files.length === 0) {" 3
      ;;
    37)
      # triage-compare.js: the pre-staging header — WORKDIR is the real repo, so a
      # wrapper that drops a flag (found live 2026-09-23) lets ext-run apply the
      # candidate's patch into the caller's tree and the next candidate sees it.
      cat > "$rep" <<'MUT37'
    ` WORKDIR=${repo}` // MUTATED: real repo as WORKDIR
MUT37
      mut_replace_block "$target" '    ` WORKDIR=${c.worktree}`' 1 "$rep"
      ;;
    38)
      # triage-compare.js: leakState() is bypassed — whatever leakcheck reported,
      # the run is treated as clean and every grade stands.
      cat > "$rep" <<'MUT38'
const leakInfo = { leak: false, baseMoved: false, detail: null } // MUTATED: leakcheck result ignored
MUT38
      mut_replace_block "$target" 'const leakInfo = leakState(gr && gr.leakcheck)' 1 "$rep"
      ;;
    39)
      # stage-worktree.sh: `git add -u` stages modifications and deletions only, so
      # every file a candidate CREATED is missing from its patch.
      cat > "$rep" <<'MUT39'
  git -C "$WT" add -u >/dev/null 2>&1 || diff_fail "git add -u failed in $WT" # MUTATED: untracked files omitted
MUT39
      mut_replace_block "$target" '  git -C "$WT" add -A >/dev/null 2>&1 || diff_fail "git add -A failed in $WT"' 1 "$rep"
      ;;
    40)
      # ext-run.sh: deny_check stops checking the main worktree of the path's
      # repository — only the path itself is checked, so a linked worktree staged
      # outside a deny-listed repo (triage-compare's layout) is handed to the CLI.
      cat > "$rep" <<'MUT40'
  : # MUTATED: common-dir deny check dropped
MUT40
      mut_replace_block "$target" '  if [ -n "$main" ] && [ "$main" != "$p" ]; then deny_check_path "$main"' 1 "$rep"
      ;;
    *)
      return 1
      ;;
  esac
}

# verify_mutation ID DEST_REPO_DIR — confirm the mutation actually took effect
# (the mutated line changed), independent of whatever the test suite says.
# Returns 0 if applied, 1 if not (caller reports this as ERROR, never a kill).
verify_mutation() {
  local id dest target
  id="$1"
  dest="$2"
  target="$dest/$(mut_file "$id")"
  [ -f "$target" ] || return 1
  case "$id" in
    1) ! grep -qF 'if [ -s "$CLAUDE_DIR/CLAUDE.md" ] && [ -n "$(tail -c1' "$target" ;;
    2) ! grep -qF 'jq empty "$SETTINGS"' "$target" ;;
    3) grep -qF '  mv "$1" "$SETTINGS"' "$target" && ! grep -qF 'if [ -L "$SETTINGS" ]; then cat' "$target" ;;
    4) grep -qF 'rm -f "$CLAUDE_DIR"/agents/triage-*.md' "$target" && ! grep -qF 'for a in $AGENTS; do' "$target" ;;
    5) ! grep -qF '.permissions.deny  -= $fable' "$target" ;;
    6) ! grep -qF 'case "$PCT" in' "$target" && grep -qF 'if [ "$PCT" -ge 60 ]; then' "$target" ;;
    7) grep -qF 'MUTATED: incomplete tri-state disabled' "$target" && ! grep -qF 'incomplete: v.checks.some(c => c.result == null)' "$target" ;;
    8) grep -qF 'MUTATED: retry disabled' "$target" ;;
    9) grep -qF 'function matchedFiles(r, text) {' "$target" && ! grep -qF 'fileMentioned(f, text)' "$target" ;;
    10) [ "$(grep -cF 'UNEXPECTED_DRIFT=1' "$target")" -eq 1 ] ;;
    11) grep -qF 'MUTATED: args validation disabled' "$target" && ! grep -qF 'throw new Error(`triage-exec:' "$target" ;;
    12) grep -qF 'MUTATED: swallows false' "$target" && ! grep -qF 'elif .prompt_cache.warm == false' "$target" ;;
    13) ! grep -qF 'agy tool calls were denied' "$target" && grep -qF 'RESPONSE=$(jq -r' "$target" ;;
    14) ! grep -qF 'agy returned an empty response' "$target" && grep -qF 'agy tool calls were denied' "$target" ;;
    15) grep -qF 'MUTATED: substring match' "$target" && ! grep -qF '*/"$name"/*)' "$target" ;;
    16) grep -qF 'MUTATED: agy dropped from the danger guard' "$target" && ! grep -qF "if (vendor === 'agy') { vendor = 'claude'; level = 'deep' }" "$target" ;;
    17) grep -qF 'MUTATED: fallback hard-coded to builder' "$target" && ! grep -qF "const onClaude = { level: step.level," "$target" ;;
    18) grep -qF 'MUTATED: FORCE warning suppressed' "$target" ;;
    19) grep -qF 'MUTATED: legacy upgrade disabled' "$target" ;;
    20) ! grep -qF 'or $up == "1"' "$target" && grep -qF '(if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m else . end)' "$target" ;;
    21) grep -qF '| [$m] as $ours_sub' "$target" && ! grep -qF '($legacy | split(" ")' "$target" ;;
    22) ! grep -qF "effort: 'max', owesFable: true" "$target" && grep -qF 'function redoStep(r, isEscalate) {' "$target" ;;
    23) grep -qF 'MUTATED: deep@max fallback always taken' "$target" && ! grep -qF '  if (afterMax) {' "$target" ;;
    24) grep -qF 'MUTATED: default model fallback' "$target" && ! grep -qF 'an absent entry is a refusal, never a default model' "$target" ;;
    25) ! grep -qF 'codex wrote no final message' "$target" && grep -qF 'RESPONSE=$(cat "$LASTMSG")' "$target" ;;
    26) grep -qF 'MUTATED: deny check skipped for codex' "$target" ;;
    27) ! grep -qF 'set -- "$@" -c sandbox_workspace_write.exclude_slash_tmp=true' "$target" && grep -qF 'set -- "$@" -c sandbox_workspace_write.exclude_tmpdir_env_var=true' "$target" ;;
    28) grep -qF 'MUTATED: codex danger effort floor dropped' "$target" && ! grep -qF 'effort = codexDangerEffort(level, effort)' "$target" ;;
    29) grep -qF 'MUTATED: retried sideways on the same vendor' "$target" && ! grep -qF "const vendor = 'claude' // every redo runs on Claude" "$target" ;;
    30) grep -qF "MUTATED: 'both' spawns one" "$target" && ! grep -qF "both: ['agy', 'codex']" "$target" ;;
    31) grep -qF 'MUTATED: graded from the self-report' "$target" && ! grep -qF "pc.applies === true && pc.rc === 0" "$target" ;;
    32) grep -qF 'MUTATED: worktree cleanup skipped' "$target" ;;
    33) grep -qF 'MUTATED: fork skip limited to --files-only' "$target" && ! grep -qxF '  if is_ignored "$rel" && [ -e "$dst" ]; then' "$target" ;;
    34) ! grep -qF 'args.outDir must not be inside args.repo' "$target" ;;
    36) ! grep -qF "if (candidates.some(c => c.vendor !== 'claude') && files.length === 0) {" "$target" ;;
    37) grep -qF 'MUTATED: real repo as WORKDIR' "$target" && ! grep -qF '` WORKDIR=${c.worktree}`' "$target" ;;
    38) grep -qF 'MUTATED: leakcheck result ignored' "$target" && ! grep -qF 'const leakInfo = leakState(gr && gr.leakcheck)' "$target" ;;
    39) grep -qF 'MUTATED: untracked files omitted' "$target" && ! grep -qF 'git -C "$WT" add -A' "$target" ;;
    40) grep -qF 'MUTATED: common-dir deny check dropped' "$target" && ! grep -qF 'deny_check_path "$main"' "$target" ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Repo copy: tracked + untracked-unignored files (git ls-files -co
# --exclude-standard), current on-disk content (so uncommitted in-flight edits
# AND brand-new files from parallel workers are included), never .git. Tracked-
# only copies caused false baseline-red: a tracked file referencing a new
# untracked file (e.g. install.sh -> scripts/triage-stats.sh) broke the copy's
# own suite before any mutation was applied.
# -----------------------------------------------------------------------------
FILELIST="$WORK_ROOT/filelist.txt"
if ! git -C "$REPO_DIR" ls-files --cached --others --exclude-standard > "$FILELIST" 2>/dev/null; then
  echo "ERROR: $REPO_DIR is not a git repo (or git ls-files failed) — cannot build a clean copy." >&2
  exit 1
fi

copy_repo() { # $1 = dest dir
  local dest
  dest="$1"
  mkdir -p "$dest"
  rsync -a --files-from="$FILELIST" "$REPO_DIR/" "$dest/" >/dev/null
}

run_suite() { # $1 = repo copy dir, $2 = suite name (see suite_file) -> exit code
  local copy suite
  copy="$1"
  suite="$2"
  case "$suite" in
    roundtrip) ( cd "$copy" && bash test/roundtrip.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    scenarios) ( cd "$copy" && node test/workflow-scenarios.mjs ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    extrun) ( cd "$copy" && bash test/ext-run.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    compare) ( cd "$copy" && node test/compare-scenarios.mjs ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    patchcheck) ( cd "$copy" && bash test/patch-check.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    stagewt) ( cd "$copy" && bash test/stage-worktree.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Baseline: run each suite once against an UNMUTATED copy first. A suite that
# is already RED before any mutation is applied can't serve as a kill/survivor
# oracle — treating its "RED" as a kill would be a false positive. Fail loud
# instead: mutations depending on an already-red suite are reported ERROR with
# the reason, never silently counted as killed.
# -----------------------------------------------------------------------------
echo "Building baseline (unmutated) copies and running suites once..."
BASELINE_DIR="$WORK_ROOT/baseline"
copy_repo "$BASELINE_DIR"

BASELINE_ROUNDTRIP_OK=1
BASELINE_SCENARIOS_OK=1
BASELINE_EXTRUN_OK=1
BASELINE_COMPARE_OK=1
BASELINE_PATCHCHECK_OK=1
BASELINE_STAGEWT_OK=1
if run_suite "$BASELINE_DIR" roundtrip; then
  BASELINE_ROUNDTRIP_OK=0
else
  BASELINE_ROUNDTRIP_OK=1
  echo "  ⚠ baseline $(suite_file roundtrip) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" scenarios; then
  BASELINE_SCENARIOS_OK=0
else
  BASELINE_SCENARIOS_OK=1
  echo "  ⚠ baseline $(suite_file scenarios) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" extrun; then
  BASELINE_EXTRUN_OK=0
else
  BASELINE_EXTRUN_OK=1
  echo "  ⚠ baseline $(suite_file extrun) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" compare; then
  BASELINE_COMPARE_OK=0
else
  echo "  ⚠ baseline $(suite_file compare) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" patchcheck; then
  BASELINE_PATCHCHECK_OK=0
else
  echo "  ⚠ baseline $(suite_file patchcheck) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" stagewt; then
  BASELINE_STAGEWT_OK=0
else
  echo "  ⚠ baseline $(suite_file stagewt) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
echo ""

# -----------------------------------------------------------------------------
# Main sweep
# -----------------------------------------------------------------------------
KILLED=0
SURVIVED=0
ERRORS=0
SURVIVOR_LIST=""
ERROR_LIST=""

printf '%-4s %-26s %-9s %-7s %s\n' "ID" "FILE" "SUITE" "RESULT" "DESCRIPTION"
printf '%s\n' "----------------------------------------------------------------------------------------------"

for id in $RUN_IDS; do
  file=$(mut_file "$id")
  desc=$(mut_desc "$id")
  suite=$(mut_suite "$id")

  if [ -z "$file" ] || [ -z "$suite" ]; then
    echo "ERROR: unknown mutation id '$id'" >&2
    ERRORS=$((ERRORS + 1))
    ERROR_LIST="$ERROR_LIST\n  [$id] unknown mutation id"
    continue
  fi

  case "$suite" in
    roundtrip) baseline_ok=$BASELINE_ROUNDTRIP_OK ;;
    scenarios) baseline_ok=$BASELINE_SCENARIOS_OK ;;
    extrun) baseline_ok=$BASELINE_EXTRUN_OK ;;
    compare) baseline_ok=$BASELINE_COMPARE_OK ;;
    patchcheck) baseline_ok=$BASELINE_PATCHCHECK_OK ;;
    stagewt) baseline_ok=$BASELINE_STAGEWT_OK ;;
    *) baseline_ok=1 ;;
  esac

  if [ "$baseline_ok" -ne 0 ]; then
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "ERROR" "$desc"
    echo "      -> baseline $(suite_file "$suite") is already RED without this mutation; cannot assess."
    ERRORS=$((ERRORS + 1))
    ERROR_LIST="$ERROR_LIST\n  [$id] $desc — baseline suite already RED, cannot assess"
    continue
  fi

  dest="$WORK_ROOT/mut-$id"
  copy_repo "$dest"

  if ! apply_mutation "$id" "$dest"; then
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "ERROR" "$desc"
    echo "      -> mutation anchor not found in $file; harness error, not a kill."
    ERRORS=$((ERRORS + 1))
    ERROR_LIST="$ERROR_LIST\n  [$id] $desc — anchor not found (apply failed)"
    rm -rf "$dest"
    continue
  fi

  if ! verify_mutation "$id" "$dest"; then
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "ERROR" "$desc"
    echo "      -> mutated line did not change as expected; harness error, not a kill."
    ERRORS=$((ERRORS + 1))
    ERROR_LIST="$ERROR_LIST\n  [$id] $desc — mutation applied but verification grep failed"
    rm -rf "$dest"
    continue
  fi

  if run_suite "$dest" "$suite"; then
    # Suite stayed GREEN despite the bug -> untested guard -> SURVIVOR (bad).
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "SURVIVOR" "$desc"
    SURVIVED=$((SURVIVED + 1))
    suggestion=$(mut_suggested_test "$id")
    entry="  [$id] $desc"
    if [ -n "$suggestion" ]; then
      entry="$entry\n      suggested covering test: $suggestion"
    fi
    SURVIVOR_LIST="$SURVIVOR_LIST\n$entry"
  else
    # Suite went RED -> the bug was caught -> KILLED (good).
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "PASS (killed)" "$desc"
    KILLED=$((KILLED + 1))
  fi

  rm -rf "$dest"
done

echo ""
echo "RESULT: $KILLED killed, $SURVIVED survived, $ERRORS errors"

if [ "$SURVIVED" -gt 0 ]; then
  echo ""
  echo "SURVIVORS (untested guards — a bug here would ship silently):"
  printf '%b\n' "$SURVIVOR_LIST"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "ERRORS (harness could not assess — never counted as a kill):"
  printf '%b\n' "$ERROR_LIST"
fi

if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$SURVIVED" -gt 0 ]; then
  exit 1
fi
exit 0
