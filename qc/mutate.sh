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
# 43 (cheapness order) moved with the proposal from triage-parity.js to
# scripts/parity-report.sh, its single owner (Wave 13) — re-anchored there.
# 13/14 (agy's denied_actions / empty-response gates), 27 (codex's
# exclude_slash_tmp flag) and 30 (crossReview 'both' spawning one) were retired
# with agy (2026-09-24): the agy adapter, codex's own sandbox flags and the
# 'both' mode are gone. 56-59 cover what replaced them: the sandbox-exec wrapper,
# the profile's $HOME read rule, the output-free audit log and the agy refusal.
# 60-62 cover the confinement review fixes: deny-by-default writes, the
# temp-dir read rule and the preflight's second (outside) canary.
# 63-66 cover the parity confinement fixes (Wave 13): the PARITY_ env map's
# unmapped-variable refusal, the source fingerprint on every task kind, judges
# given only patch + key, and the per-check cache isolation.
# 67-70 cover the review bake-off (Wave 13D): hard excludes applied to tracked
# paths too, adjudicators blind to provenance, disputed items never scored, and
# --input-dir refusing a symlink out of the staged tree.
# 71 covers the codex --output-schema normalization to OpenAI-strict form.
# 72-74 cover the review bake-off fixes: an extension never re-adjudicates an item a
# new finding attached to, a superseded reviewer is never scored, and every codex
# reviewer/adjudicator carries an explicit TIMEOUT for ext-run's watchdog.
# 75-81 cover the inline build bake-offs in triage-exec (Wave 13B): the weekly
# pause, the sample threshold, the challenger fallback, the LEAK abort, the
# dirty-files guard, the codex danger floor on challengers, and no bake-off fields
# when args.bakeoff is absent.
# 82-85 cover the adaptive sampling rate (Wave 14A): parity-report.sh rates' n >=
# minN condition, its CI-width condition, a pending proposal forcing explore, and
# triage-exec sampling at args.bakeoff.rates[level]. 86: report.external appears
# when a bake-off applied an external challenger's patch to an all-Claude plan.
# 87-90 cover model-version tracking (Wave 15) in parity-report.sh: grouping by
# the concrete modelId, the inferred-by-date boundary (from <= date), family-based
# cheapness (a new codex version still ranks) and backfill-modelid's idempotence.
# 21 was re-anchored in Wave 16C: uninstall no longer keeps a legacy-value list; it
# removes the subagent model only while it equals the install-written ownership marker.
# 130-149 cover install/uninstall safety (Wave 16C): uninstall backups (fork, memory,
# the leftover set), timestamped + pruned install backups, the retire checksum guard,
# the tiers.json-derived subagent default and its ownership marker, jq failures and
# settings shape, .driftignore normalization (install + drift), tiers-sync's --root
# and unclosed-frontmatter guards, drift's settings-migration warning and file list.
# 110-129 cover parity ledger integrity (Wave 16B): per-observation dedupe, the
# run-id collision refusal, UTC offsets, the one ledger lock and its stale takeover,
# backfill through a symlink, current-id challengers only, tuning.rejected, reps
# collapsed per (run, task), parity-cost skipping a corrupt line, review revisions
# (latest only, superseded status, the revision append), modelFrom through
# ingest-parity and triage-parity, the ignored/refs source fingerprint and its
# guard, and triage-tiers.sh's aliasHistory and challengerMix-sum checks.
# 91-109 cover Wave 16A (bake-off / grading correctness, danger floor): an empty
# diff never the passing choice, no out-of-scope inline apply, an unknown leak state
# withheld, the same-repo guard, a failed apply never run in place, effort on a level
# climb, an external rejection's Claude fallback, the weekly-unknown pause, the
# danger family floor; per-check bash -c, the PATCHCHECK sha cross-check, the
# model/effort mismatch, the extend scope check; the locked build worktree; the
# **/ hard-exclude variants and the fail-closed deny carry-over; apply
# --require-clean, the measured treeModified and the ignored-path fingerprint.
# 150-163 cover Wave 16A guards that shipped covered but unmutated: the bake-off
# apply's --require-clean flag, the applied result keeping the PLAN's (not the
# challenger's) effort, an apply reply counted only for the patch it named, the
# danger floor on the PLANNED candidate, top-level Claude ineligibility, the
# challenger entry from the draw's high bits, ranExternally excluding an
# unavailable planned codex run (triage-exec.js); outOfScope from changedFiles vs
# files, selfCheckEnv offered to Claude only, U4's non-empty-error rule, an
# all-malformed reviewer reported unavailable (never scored 0), cleanPath cutting
# at the FIRST /snap/ (triage-compare.js); patch-check.sh's one --summary
# PATCHCHECK line; stage-worktree.sh's one leakcheck --line LEAKCHECK line.
# 164-165 cover install.sh's backup naming under a same-second clash: a new backup
# takes one past the HIGHEST -N (never a pruned-free older name), and backups age in
# numeric -N order (-10 after -2).
# 166-169 cover the review-extend deny refresh: triage-compare.js using the re-asked
# deny (codexDeniedNow) and failing closed when the relay drops it; review-stage.sh
# deny-refresh re-asking the repo's deny query and failing closed on a missing
# manifest.
# 170-173 cover triage-exec's external no-work handling (Wave 18): the boundary
# attestation on the triage-external brief, classifyExternal() reading the FIRST
# verdict line anywhere in the reply (not only line one), the refused list in
# report().external, and the escalation reason naming the kind and reason.
# 174-175 cover workflow transcript discovery in triage-usage.sh (recursive scan; a
# directory argument is never classified by a deep search).
# 176-177 cover ext-run.sh's boundary attestation under both names: the canonical
# CODEX_BOUNDARY_CLEARED and the deprecated AGY_BOUNDARY_CLEARED alias. 178 covers
# lint's leaf-agent check (a leaf worker losing `disallowedTools: Agent`).
# 179-188 cover the triage.md SessionStart hook (Wave 21): triage-context.sh's cap,
# kill-switch, legacy-import and agent_id guards; install appending (never replacing)
# the SessionStart array, the pointer appended once, a failed hook write never
# reaching CLAUDE.md, and --settings-status's two new lines; uninstall deleting only
# our SessionStart command. Mutation 1 was re-anchored on the pointer-line append.
# 189-201 cover the Wave 21 fix round: the CLAUDE_DIR pinned in the hook command; the
# one anchored ownership predicate (install's and uninstall's uses, and their N8
# parity); matcher coverage; disableAllHooks (no migration + the status line); CRLF
# legacy lines (install, hook); fail-closed CLAUDE.md filtering (install, uninstall);
# a jq failure never read as a hook decision; drift without a settings.json.
# 186 was retired in fix round 3: settings.json is written once, so a failed hook
# merge is the one settings-merge failure 140 covers. 202-215 cover fix round 3:
# ownership = a command hook pinned to THIS CLAUDE_DIR (install and uninstall, pin and
# .type each); all four matcher events; the rubric gate on the INSTALLED rubric (skipped,
# or asked of the repo copy); one settings write (no second write, no settings.json
# created first); a false hooks.SessionStart refused; byte-exact CLAUDE.md filtering
# (install, uninstall); the pointer naming this install's triage.md; a CLAUDE_DIR with a
# line break refused.
# 216-218 cover triage-exec's plan-level noFable (rubric rule 7 material): redoStep()
# stopping at deep@max instead of stepping onto top, runFable()'s defence-in-depth
# guard (an external top subtask coming back to Claude gets deep@max, never Fable),
# and bad() refusing a plan-time claude top subtask. 219-221 cover its reporting: a
# deep@max FIX/FAIL that owes nothing gets one marked retry (then the stop), an empty
# deep@max fallback in runFable() stops for the user, and needs-user reads INCOMPLETE.
ALL_IDS="1 2 3 4 5 6 7 8 9 10 11 12 15 16 17 18 19 20 21 22 23 24 25 26 28 29 31 32 33 34 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159 160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 179 180 181 182 183 184 185 187 188 189 190 191 192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 210 211 212 213 214 215 216 217 218 219 220 221 222 223 224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239 240 241 242 243 244 245 246 247 248 249 250 251 252 253 254 255 256 257 258 259 260 261 262 263 264 265 266 267 268 269 270 271 272 273 274 275 276 277 278 279 280 281 282 283 284 285 286 287 288 289 290 291 292 293 294 295 296 297 298 299 300 301 302 303 304 305"
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
    28) echo "workflows/triage-exec.js" ;;
    29) echo "workflows/triage-exec.js" ;;
    75|76|77|78|79|80|81|85|86) echo "workflows/triage-exec.js" ;;
    82|83|84|87|88|89|90) echo "scripts/parity-report.sh" ;;
    110|111|112|113|114|115|116|117|118|120|121|122|123) echo "scripts/parity-report.sh" ;;
    119) echo "scripts/parity-cost.sh" ;;
    124|127) echo "workflows/triage-parity.js" ;;
    125|126) echo "scripts/parity-suite.sh" ;;
    128|129) echo "scripts/triage-tiers.sh" ;;
    91|92|93|94|95|96|97|98|99) echo "workflows/triage-exec.js" ;;
    100|101|102|103) echo "workflows/triage-compare.js" ;;
    104) echo "scripts/ext-run.sh" ;;
    105|106) echo "scripts/review-stage.sh" ;;
    107|108|109) echo "scripts/stage-worktree.sh" ;;
    31) echo "workflows/triage-compare.js" ;;
    32) echo "scripts/patch-check.sh" ;;
    33) echo "install.sh" ;;
    34) echo "workflows/triage-compare.js" ;;
    36) echo "workflows/triage-compare.js" ;;
    37) echo "workflows/triage-compare.js" ;;
    38) echo "workflows/triage-compare.js" ;;
    39) echo "scripts/stage-worktree.sh" ;;
    40) echo "scripts/ext-run.sh" ;;
    41) echo "workflows/triage-parity.js" ;;
    42) echo "workflows/triage-parity.js" ;;
    43) echo "scripts/parity-report.sh" ;;
    44) echo "scripts/parity-suite.sh" ;;
    45) echo "scripts/parity-suite.sh" ;;
    46) echo "workflows/triage-parity.js" ;;
    47) echo "workflows/triage-compare.js" ;;
    48) echo "scripts/patch-check.sh" ;;
    49) echo "scripts/ext-run.sh" ;;
    50) echo "scripts/ext-run.sh" ;;
    51) echo "scripts/ext-run.sh" ;;
    52) echo "scripts/parity-report.sh" ;;
    53) echo "scripts/parity-report.sh" ;;
    54) echo "scripts/parity-report.sh" ;;
    55) echo "scripts/stage-worktree.sh" ;;
    56|57|58|59|60|61|62) echo "scripts/ext-run.sh" ;;
    63|66) echo "scripts/patch-check.sh" ;;
    64|65) echo "workflows/triage-parity.js" ;;
    67) echo "scripts/review-stage.sh" ;;
    68|69|72|73|74) echo "workflows/triage-compare.js" ;;
    70|71) echo "scripts/ext-run.sh" ;;
    130) echo "uninstall.sh" ;;
    131) echo "uninstall.sh" ;;
    132) echo "install.sh" ;;
    133) echo "install.sh" ;;
    134) echo "install.sh" ;;
    135) echo "install.sh" ;;
    136) echo "install.sh" ;;
    137) echo "install.sh" ;;
    138) echo "install.sh" ;;
    139) echo "install.sh" ;;
    140) echo "install.sh" ;;
    141) echo "uninstall.sh" ;;
    142) echo "install.sh" ;;
    143) echo "scripts/tiers-sync.sh" ;;
    144) echo "scripts/tiers-sync.sh" ;;
    145) echo "install.sh" ;;
    146) echo "drift.sh" ;;
    147) echo "drift.sh" ;;
    148) echo "uninstall.sh" ;;
    149) echo "drift.sh" ;;
    150|151|152|153|154|155|156) echo "workflows/triage-exec.js" ;;
    157|158|159|160|161) echo "workflows/triage-compare.js" ;;
    162) echo "scripts/patch-check.sh" ;;
    163) echo "scripts/stage-worktree.sh" ;;
    164|165) echo "install.sh" ;;
    166|167) echo "workflows/triage-compare.js" ;;
    168|169) echo "scripts/review-stage.sh" ;;
    170|171|172|173) echo "workflows/triage-exec.js" ;;
    216|217|218|219|220|221) echo "workflows/triage-exec.js" ;;
    174) echo "scripts/triage-usage.sh" ;;
    175) echo "scripts/triage-usage.sh" ;;
    176|177) echo "scripts/ext-run.sh" ;;
    178) echo "agents/triage-deep-reasoner.md" ;;
    179|180|181|185) echo "scripts/triage-context.sh" ;;
    182|184|187|188) echo "install.sh" ;;
    183) echo "uninstall.sh" ;;
    189|190|193|194|195|196|197|198) echo "install.sh" ;;
    191|192|200) echo "uninstall.sh" ;;
    199) echo "drift.sh" ;;
    201) echo "scripts/triage-context.sh" ;;
    202|204|206|207|208|209|210|211|212|214|215) echo "install.sh" ;;
    203|205|213) echo "uninstall.sh" ;;
    222) echo "workflows/triage-exec.js" ;;
    223) echo "workflows/triage-exec.js" ;;
    224) echo "workflows/triage-exec.js" ;;
    225) echo "workflows/triage-exec.js" ;;
    226) echo "workflows/triage-exec.js" ;;
    227) echo "workflows/triage-exec.js" ;;
    228) echo "workflows/triage-exec.js" ;;
    229) echo "workflows/triage-exec.js" ;;
    230) echo "workflows/triage-exec.js" ;;
    231) echo "workflows/triage-exec.js" ;;
    232) echo "workflows/triage-exec.js" ;;
    233) echo "workflows/triage-exec.js" ;;
    234) echo "workflows/triage-exec.js" ;;
    235) echo "workflows/triage-exec.js" ;;
    236) echo "workflows/triage-exec.js" ;;
    237) echo "workflows/triage-exec.js" ;;
    238) echo "workflows/triage-exec.js" ;;
    239) echo "workflows/triage-exec.js" ;;
    240) echo "workflows/triage-exec.js" ;;
    241) echo "workflows/triage-exec.js" ;;
    242) echo "workflows/triage-exec.js" ;;
    243) echo "workflows/triage-exec.js" ;;
    244) echo "workflows/triage-exec.js" ;;
    245) echo "workflows/triage-exec.js" ;;
    246) echo "workflows/triage-compare.js" ;;
    247) echo "workflows/triage-compare.js" ;;
    248) echo "workflows/triage-compare.js" ;;
    249) echo "workflows/triage-compare.js" ;;
    250) echo "workflows/triage-compare.js" ;;
    251) echo "workflows/triage-compare.js" ;;
    252) echo "workflows/triage-compare.js" ;;
    253) echo "workflows/triage-compare.js" ;;
    254) echo "workflows/triage-compare.js" ;;
    255) echo "workflows/triage-compare.js" ;;
    256) echo "workflows/triage-compare.js" ;;
    257) echo "workflows/triage-parity.js" ;;
    258) echo "workflows/triage-parity.js" ;;
    259) echo "workflows/triage-parity.js" ;;
    260) echo "workflows/triage-parity.js" ;;
    261) echo "scripts/parity-report.sh" ;;
    262) echo "scripts/parity-report.sh" ;;
    263) echo "scripts/parity-report.sh" ;;
    264) echo "scripts/parity-report.sh" ;;
    265) echo "scripts/parity-report.sh" ;;
    266) echo "scripts/parity-report.sh" ;;
    267) echo "scripts/parity-report.sh" ;;
    268) echo "scripts/parity-report.sh" ;;
    269) echo "scripts/parity-report.sh" ;;
    270) echo "scripts/triage-stats.sh" ;;
    271) echo "scripts/triage-usage.sh" ;;
    272) echo "scripts/triage-usage.sh" ;;
    273) echo "scripts/parity-report.sh" ;;
    274) echo "workflows/triage-exec.js" ;;
    275) echo "triage.md" ;;
    276) echo "scripts/ext-run.sh" ;;
    277) echo "scripts/stage-worktree.sh" ;;
    278) echo "scripts/stage-worktree.sh" ;;
    279) echo "scripts/stage-worktree.sh" ;;
    280) echo "scripts/stage-worktree.sh" ;;
    281) echo "scripts/stage-worktree.sh" ;;
    282) echo "scripts/stage-worktree.sh" ;;
    283) echo "scripts/stage-worktree.sh" ;;
    284) echo "scripts/parity-suite.sh" ;;
    285) echo "scripts/review-stage.sh" ;;
    286) echo "scripts/review-stage.sh" ;;
    287) echo "scripts/review-stage.sh" ;;
    288) echo "scripts/review-stage.sh" ;;
    289) echo "scripts/ext-run.sh" ;;
    290) echo "scripts/ext-run.sh" ;;
    291) echo "scripts/ext-run.sh" ;;
    292) echo "scripts/ext-run.sh" ;;
    293) echo "scripts/ext-run.sh" ;;
    294) echo "scripts/ext-run.sh" ;;
    295) echo "scripts/triage-context.sh" ;;
    296) echo "install.sh" ;;
    297) echo "install.sh" ;;
    298) echo "uninstall.sh" ;;
    299) echo "uninstall.sh" ;;
    300) echo "uninstall.sh" ;;
    301) echo "install.sh" ;;
    302) echo "uninstall.sh" ;;
    303) echo "install.sh" ;;
    304) echo "install.sh" ;;
    305) echo "install.sh" ;;
    *) echo "" ;;
  esac
}

mut_desc() {
  case "$1" in
    1) echo "install.sh: remove the trailing-newline guard before the CLAUDE.md pointer-line append" ;;
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
    15) echo "ext-run.sh: weaken the deny-list path match from path-component equality to substring (a sibling repo such as clip-creators-lab is refused too)" ;;
    16) echo "triage-exec.js: danger-zone routing no longer reroutes overflow, so overflow:true / tier overflow sends danger subtasks to codex" ;;
    17) echo "triage-exec.js: an external subtask whose CLI produced no work falls back to Claude builder instead of the SAME level" ;;
    18) echo "install.sh: neuter check_force_override (the CLAUDE_CODE_SUBAGENT_MODEL_FORCE warning never prints)" ;;
    19) echo "install.sh: neuter is_legacy_subagent_model (a previous installer default is never upgraded, dry-run never says so)" ;;
    20) echo "install.sh: the settings merge reverts to set-only-when-unset (dry-run promises an upgrade the write never makes)" ;;
    21) echo "uninstall.sh: the subagent model is removed whenever the ownership marker exists, even after the user repointed it" ;;
    22) echo "triage-exec.js: remove the deep@max rung (an ESCALATE on a below-max deep attempt goes straight to Fable)" ;;
    23) echo "triage-exec.js: runFable() always takes the deep@max fallback (Fable unavailable after a failed deep@max re-runs it)" ;;
    24) echo "ext-run.sh: a level/mode missing from tiers.json falls back to a default model instead of refusing" ;;
    25) echo "ext-run.sh: drop the codex empty-response gate (rc 0 with an empty -o final message is treated as usable output)" ;;
    26) echo "ext-run.sh: the deny check is skipped for codex (clip-creator / .codex-deny no longer refuse)" ;;
    28) echo "triage-exec.js: the codex danger effort floor is dropped (danger work runs on codex below effort high)" ;;
    29) echo "triage-exec.js: a failed external subtask is retried sideways on the same vendor instead of on Claude" ;;
    31) echo "triage-compare.js: grades a candidate from its own CHECK rc self-report instead of patch-check's result" ;;
    32) echo "patch-check.sh: cleanup_wt is a no-op (worktrees and their git bookkeeping are left behind)" ;;
    33) echo "install.sh: the .driftignore fork skip is limited to --files-only again (a bare install clobbers triage.md)" ;;
    34) echo "triage-compare.js: the outDir-under-repo entry-contract check is dropped (the staged worktrees and patches land in the real tree, which leakcheck then reports as a self-inflicted LEAK)" ;;
    36) echo "triage-compare.js: the external-candidate files requirement is dropped (a non-claude candidate runs with no files, and triage-external refuses it mid-run instead of the plan being rejected up front)" ;;
    37) echo "triage-compare.js: an external candidate gets the REAL repo as WORKDIR instead of its staged worktree (the live-run leak: ext-run applies into the real tree)" ;;
    38) echo "triage-compare.js: the leakcheck result is ignored (a candidate that wrote into the real repo is graded as if nothing happened)" ;;
    39) echo "stage-worktree.sh: diff stages only tracked files (git add -u), so new/untracked files a candidate created are silently dropped from its patch" ;;
    40) echo "ext-run.sh: drop the git-common-dir deny check (a linked worktree created outside a deny-listed repo, or an --input file in one, bypasses clip-creator and the .codex-deny markers)" ;;
    41) echo "triage-parity.js: an unavailable/denied/invalid/unresolved run is tallied as a FAIL (a flaky vendor or a deny marker drops a candidate from the climb)" ;;
    42) echo "triage-parity.js: the stop rule ignores 'consecutive' (a cleared band no longer resets the failed-band streak, so fail/pass/fail stops a candidate)" ;;
    43) echo "parity-report.sh: the cheapness order is ignored (every ranked challenger is judged by the cheaper rule, so a pricier one below the margin is proposed on its Wilson bound)" ;;
    44) echo "parity-suite.sh: materialize skips deny-marker propagation (a clone of a .codex-deny source is handed to codex, because ext-run no longer sees the source)" ;;
    45) echo "parity-suite.sh: materialize keeps source history/refs reachable (the post-commit ref-deletion loop is skipped, so a generator source's own commits — and any other branch — stay in the materialized repo, defeating the no-history guarantee)" ;;
    46) echo "triage-parity.js: an external review candidate omits its MODEL line (the read-mode spawn falls back to triage-cross-reviewer's mode default model instead of the candidate's own, silently reintroducing the wrong-model bug for a candidate with an explicit model)" ;;
    47) echo "triage-compare.js: an UNKNOWN leak state (leakcheck errored / relayed no status) no longer voids the grades, so a candidate is reported pass while the real repo may have changed" ;;
    48) echo "patch-check.sh: an --overlay copy failure only logs, and the check runs without the hidden tests (a candidate is graded on its own tests alone)" ;;
    49) echo "ext-run.sh: the inherited GIT_DIR/GIT_WORK_TREE/... are no longer cleared (a hook's environment redirects the build's git calls into another repository)" ;;
    50) echo "ext-run.sh: resolve_path resolves only the parent dir again (a symlink in an allowed dir pointing into clip-creator passes the deny check and is then read)" ;;
    51) echo "ext-run.sh: the 3-way apply-back is no longer pre-checked for conflicts (a conflicting merge leaves markers in the caller's tree while exit 6 promises it unchanged)" ;;
    52) echo "parity-report.sh: the report ignores minN (a challenger with a handful of runs is proposed instead of 'insufficient data')" ;;
    53) echo "parity-report.sh: the cheaper rule uses the challenger's point rate instead of its Wilson 95% lower bound (10/10 beats a 9/10 incumbent)" ;;
    54) echo "parity-report.sh: a non-graded status (unavailable/invalid/...) is ingested and counted as a fail" ;;
    55) echo "stage-worktree.sh: apply runs the 3-way merge without the conflict pre-check (a conflicting patch leaves markers in the caller's tree while exit 6 promises it unchanged)" ;;
    56) echo "ext-run.sh: codex runs WITHOUT sandbox-exec (--dangerously-bypass-approvals-and-sandbox with no OS confinement: the whole disk is readable, \$HOME writable)" ;;
    57) echo "ext-run.sh: the profile allows reads of all of \$HOME (subpath, not literal), re-opening every repo under it" ;;
    58) echo "ext-run.sh: the command audit log records aggregated_output (command output / file content lands in a log outside the sandbox)" ;;
    59) echo "ext-run.sh: --vendor agy is accepted again (the retired vendor is no longer refused by name)" ;;
    60) echo "ext-run.sh: writes are allowed by default again outside \$HOME, the temp dirs and the stage (a user-owned /opt/homebrew binary, /Users/Shared, /private/var/tmp are writable)" ;;
    61) echo "ext-run.sh: the temp-dir read rule is dropped (sibling compare stages, other runs' patches and Claude scratchpads under /private/tmp and /private/var/folders are readable)" ;;
    62) echo "ext-run.sh: the preflight writes only the stage-root canary (a profile that confines \$HOME, the temp dirs and the stage but allows writes elsewhere passes)" ;;
    63) echo "patch-check.sh: an unmapped \$PARITY_ variable a check references is silently ignored (the check runs with a bogus value instead of exit 2)" ;;
    64) echo "triage-parity.js: the after-grading source fingerprint is skipped for review tasks (a review candidate that writes into the source repo goes unnoticed)" ;;
    65) echo "triage-parity.js: judges are handed the materialized repo path again (a judge can cd into a repo and read beyond the patch + key)" ;;
    66) echo "patch-check.sh: checks run without XDG_CACHE_HOME/TMPDIR/GRANTFORGE_CACHE_DIR pointed at the per-patch dir (a check refreshes the real user cache)" ;;
    67) echo "review-stage.sh: a hard exclude is skipped when the path is tracked (as .gitignore would: a committed context/ or PROJECT_MEMORY.md reaches the snapshot)" ;;
    68) echo "triage-compare.js (review): the adjudicator prompt leaks provenance (each item says which anonymized reviewers reported it)" ;;
    69) echo "triage-compare.js (review): a disputed item is counted as real in the reviewer scores" ;;
    70) echo "ext-run.sh: --input-dir follows a symlink out of the staged tree (whatever it names is copied to codex)" ;;
    71) echo "ext-run.sh: the --schema is passed to codex un-normalized (a non-strict schema is rejected by the API: every schema'd codex run is UNAVAILABLE)" ;;
    72) echo "triage-compare.js (review extend): prior items a new finding attached to are re-adjudicated (their verdicts can flip)" ;;
    73) echo "triage-compare.js (review extend): a superseded prior reviewer is still scored" ;;
    75) echo "triage-exec.js (bake-off): the weekly pause is ignored (bake-offs keep sampling at/over pauseAtWeeklyPct)" ;;
    76) echo "triage-exec.js (bake-off): the sample threshold is dropped (every eligible subtask is sampled)" ;;
    77) echo "triage-exec.js (bake-off): a passing challenger is never applied when the planned candidate failed (no fallback)" ;;
    78) echo "triage-exec.js (bake-off): a compare LEAK does not abort the run (the rest of the plan runs on a tree someone else changed)" ;;
    79) echo "triage-exec.js (bake-off): the clean check only checks that its reply parsed (a bake-off runs on files modified in the tree)" ;;
    80) echo "triage-exec.js (bake-off): the codex danger floor is not applied to challengers (danger work graded against codex below effort high)" ;;
    81) echo "triage-exec.js (bake-off): the return carries bake-off fields even when args.bakeoff is absent" ;;
    82) echo "parity-report.sh (rates): the n >= minN condition is weakened to n >= 1 (a level with a challenger a few runs in drops to the maintenance rate)" ;;
    83) echo "parity-report.sh (rates): the Wilson CI-width condition is dropped (a level at n = minN with a coin-flip pass rate drops to maintain)" ;;
    84) echo "parity-report.sh (rates): a pending tier proposal no longer forces explore (a level whose incumbent is about to be replaced drops to maintain)" ;;
    85) echo "triage-exec.js (bake-off): args.bakeoff.rates is ignored (every level samples at tuning.sampleRate)" ;;
    86) echo "triage-exec.js (bake-off): an applied codex challenger patch on an all-Claude plan leaves report.external absent" ;;
    87) echo "parity-report.sh: rows are grouped by the configured model, not the concrete modelId (two Opus versions under the alias opus pool into one group)" ;;
    88) echo "parity-report.sh: the alias-history boundary is exclusive (from < date), so a line on an entry's own from date resolves to the previous version" ;;
    89) echo "parity-report.sh: the codex cheapness order is back to version-bound ids (gpt-6-*), so any other codex version is unranked" ;;
    90) echo "parity-report.sh: backfill-modelid refills rows that already have a modelId (an observed id is overwritten; a second run rewrites the ledger)" ;;
    130) echo "uninstall.sh: an installed file is deleted even when it differs from the repo copy (a triage.md fork is lost)" ;;
    131) echo "uninstall.sh: per-agent memory is rm -rf'd instead of moved to the backup dir" ;;
    132) echo "install.sh: backups go to one fixed slot again (the next sync overwrites the previous backup)" ;;
    133) echo "install.sh: timestamped backups are never pruned (unbounded .bak-triage-* growth)" ;;
    134) echo "install.sh: a retired file with unknown bytes is deleted (the shipped-checksum guard is bypassed)" ;;
    135) echo "install.sh: the subagent default is a hard-coded id again, not config/tiers.json levels.deep.claude.model" ;;
    136) echo "install.sh: the subagent model is written without its ownership marker (uninstall then never removes it)" ;;
    137) echo "install.sh: a value still equal to its ownership marker is treated as the user's (never upgraded)" ;;
    138) echo "install.sh: a stale ownership marker (model repointed by the user) is kept" ;;
    139) echo "install.sh: an unmarked value equal to the default is adopted as ours (value equality as ownership, codex#20)" ;;
    140) echo "install.sh: a failing settings-merge jq is swallowed and install still prints Installed. with rc 0" ;;
    141) echo "uninstall.sh: a failing settings-rewrite jq is swallowed (files removed, settings.json emptied, rc 0)" ;;
    142) echo "install.sh: a settings.json of the wrong shape is not refused upfront (half-applied install)" ;;
    143) echo "tiers-sync.sh: --root with no value loops forever" ;;
    144) echo "tiers-sync.sh: an unclosed frontmatter is not detected (body model: lines rewritten)" ;;
    145) echo "install.sh: .driftignore entries are not normalized (CRLF/trailing space disables fork protection)" ;;
    146) echo "drift.sh: .driftignore entries are not normalized (a CRLF entry reports the fork as FORKED)" ;;
    147) echo "drift.sh: the settings-migration check is dropped (a legacy subagent model goes unreported)" ;;
    148) echo "uninstall.sh: scripts/parity-report.sh dropped from the removal list (a file left behind)" ;;
    149) echo "drift.sh: scripts/triage-stats.sh dropped from the checked list (an installed file drift never sees)" ;;
    150) echo "triage-exec.js (bake-off): the apply command drops --require-clean (a patch could land on top of uncommitted work)" ;;
    151) echo "triage-exec.js (bake-off): the applied result carries the CHALLENGER's effort, not the plan's (a later redo re-runs at the wrong rung)" ;;
    152) echo "triage-exec.js (bake-off): an apply reply counts even when it names another patch than the one requested" ;;
    153) echo "triage-exec.js (bake-off): the danger floor is never checked against the PLANNED candidate" ;;
    154) echo "triage-exec.js (bake-off): a top-level Claude subtask is no longer excluded (Fable's one sanctioned spawn path bypassed)" ;;
    155) echo "triage-exec.js (bake-off): the challenger entry reverts to a plain modulo of the raw hash (the weak low bits)" ;;
    156) echo "triage-exec.js (bake-off): an unavailable planned codex run is no longer excluded from ranExternally" ;;
    157) echo "triage-compare.js: outOfScope is never computed from changedFiles vs the brief's files (always false)" ;;
    158) echo "triage-compare.js: selfCheckEnv reaches external candidates too (they cannot actually self-check)" ;;
    159) echo "triage-compare.js: any present error field invalidates the grade, even an empty string" ;;
    160) echo "triage-compare.js: a reviewer whose findings are ALL malformed is scored ok instead of unavailable" ;;
    161) echo "triage-compare.js: cleanPath cuts an absolute path at the LAST /snap/ instead of the first" ;;
    162) echo "patch-check.sh: --summary no longer emits the one PATCHCHECK json line" ;;
    163) echo "stage-worktree.sh: leakcheck --line no longer emits the one LEAKCHECK json line" ;;
    164) echo "install.sh: a same-second backup reuses the first free name (a pruned older slot), so the newest backup sorts oldest and is pruned" ;;
    165) echo "install.sh: backups age in text order of -N (-10 before -2), pruning newer backups first" ;;
    166) echo "triage-compare.js (review extend): the re-asked deny (codexDeniedNow) is ignored — a deny added since staging still sends the snapshot to codex" ;;
    167) echo "triage-compare.js (review extend): a relay that drops or garbles codexDeniedNow counts as allowed (fails open)" ;;
    168) echo "review-stage.sh deny-refresh: the repo's deny query is not re-asked (a marker or CODEX_DENY_REPOS entry added since staging is missed)" ;;
    169) echo "review-stage.sh deny-refresh: a missing manifest.json answers allowed (fails open)" ;;
    216) echo "triage-exec.js: redoStep() ignores noFable (a deep@max failure steps onto top; rule 7 material reaches the Fable path)" ;;
    217) echo "triage-exec.js: runFable() ignores noFable (an external top subtask coming back to Claude spawns Fable)" ;;
    218) echo "triage-exec.js: bad() accepts a claude top subtask under noFable (Fable spawned at Execute)" ;;
    219) echo "triage-exec.js: redoStep() retries a failed deep@max unmarked under noFable (never stops; reported ok while failing)" ;;
    220) echo "triage-exec.js: runFable()'s empty deep@max fallback under noFable returns a bare null (no needs-user)" ;;
    221) echo "triage-exec.js: a needs-user stop leaves the run not incomplete (a clean-looking run with unfinished work)" ;;
    170) echo "triage-exec.js: the triage-external brief drops the data-boundary attestation (the wrapper refuses every planned codex subtask)" ;;
    171) echo "triage-exec.js: classifyExternal() reads only the first line (a REFUSED after a preamble is misread)" ;;
    172) echo "triage-exec.js: report().external.<vendor>.refused is always empty (a refusal goes unreported)" ;;
    173) echo "triage-exec.js: the no-work escalation reason drops the kind and reason text" ;;
    174) echo "triage-usage.sh: transcript scan reverts to direct children only" ;;
    175) echo "triage-usage.sh: a directory argument is classified as a subagents dir by a deep search (a project dir tallies every session)" ;;
    176) echo "ext-run.sh: the deprecated AGY_BOUNDARY_CLEARED alias no longer attests (an older caller is refused)" ;;
    177) echo "ext-run.sh: the canonical CODEX_BOUNDARY_CLEARED no longer attests (only the deprecated alias does)" ;;
    178) echo "triage-deep-reasoner.md: disallowedTools: Agent dropped (the leaf worker can spawn subagents again)" ;;
    179) echo "triage-context.sh: the 10,000-char cap check is removed (an oversize triage.md is injected and arrives as a 2,000-char preview; --check passes it)" ;;
    180) echo "triage-context.sh: the kill switch (triage.disabled) is ignored" ;;
    181) echo "triage-context.sh: the legacy @triage.md guard is removed (the rubric loads twice while the import is still in CLAUDE.md)" ;;
    182) echo "install.sh: the SessionStart array is replaced, not appended to (the user's other SessionStart hooks are lost)" ;;
    183) echo "uninstall.sh: every SessionStart hook is deleted, not only the triage-context.sh command" ;;
    184) echo "install.sh: the pointer line is appended on every install (no already-present guard)" ;;
    185) echo "triage-context.sh: the agent_id guard is removed (a subagent's SessionStart input still gets the rubric)" ;;
    187) echo "install.sh: --settings-status no longer reports a missing triage hook (drift stays quiet)" ;;
    188) echo "install.sh: --settings-status no longer reports a legacy @triage.md import (drift stays quiet)" ;;
    189) echo "install.sh: the hook command no longer pins CLAUDE_DIR (a non-default install reads ~/.claude's kill switch, guard and triage.md)" ;;
    190) echo "install.sh: hook ownership is a substring match again (triage-context.sh.backup / echo ... count as installed)" ;;
    191) echo "uninstall.sh: hook ownership is a substring match again (foreign triage-context.sh.backup / echo ... commands deleted)" ;;
    192) echo "uninstall.sh: its copy of the ownership predicate drifts from install.sh's" ;;
    193) echo "install.sh: matcher coverage ignored (our command under a resume-only matcher counts as installed)" ;;
    194) echo "install.sh: disableAllHooks ignored (CLAUDE.md migrated although the hook can never run)" ;;
    195) echo "install.sh: --settings-status no longer reports disableAllHooks" ;;
    196) echo "install.sh: a CRLF @triage.md line is not recognized (has_line keeps the CR; import kept, status quiet)" ;;
    197) echo "install.sh: an awk failure filtering CLAUDE.md is swallowed (CLAUDE.md emptied)" ;;
    198) echo "install.sh: a jq failure in the hook decision is read as 'add'" ;;
    199) echo "drift.sh: the settings status runs only when settings.json exists (a missing hook goes unreported)" ;;
    200) echo "uninstall.sh: an awk failure filtering CLAUDE.md is swallowed (CLAUDE.md emptied)" ;;
    201) echo "triage-context.sh: a CRLF @triage.md line is not recognized (rubric loads twice)" ;;
    202) echo "install.sh: 'installed' ignores the CLAUDE_DIR pin (a hook pinned to another dir, or unpinned, counts; the legacy import goes with no hook of ours)" ;;
    203) echo "uninstall.sh: removal ignores the CLAUDE_DIR pin (another install's hook, or an unpinned one, is deleted)" ;;
    204) echo "install.sh: 'installed' ignores .type (a prompt-type entry carrying our command counts)" ;;
    205) echo "uninstall.sh: removal ignores .type (a prompt-type entry carrying our command is deleted)" ;;
    206) echo "install.sh: matcher coverage no longer requires resume" ;;
    207) echo "install.sh: the rubric gate is skipped (an over-cap installed rubric loses its working @triage.md import)" ;;
    208) echo "install.sh: the rubric gate checks the repo copy, not the INSTALLED rubric (a preserved over-cap fork is migrated)" ;;
    209) echo "install.sh: the hook is merged in a second settings write (a failed hook merge leaves the earlier keys written)" ;;
    210) echo "install.sh: an absent settings.json is created before the merge (a failed merge leaves a stray settings.json)" ;;
    211) echo "install.sh: a false hooks.SessionStart passes the shape check (read as absent, then overwritten)" ;;
    212) echo "install.sh: the CLAUDE.md migration adds a newline to an unterminated last line" ;;
    213) echo "uninstall.sh: the CLAUDE.md filter adds a newline to an unterminated last line" ;;
    214) echo "install.sh: the pointer line always names ~/.claude/triage.md (wrong for a custom CLAUDE_DIR)" ;;
    215) echo "install.sh: a CLAUDE_DIR with a line break is accepted (the pointer line splits, is never found again)" ;;
    91) echo "triage-exec.js (bake-off): an EMPTY diff counts as the passing choice (a no-op 'pass' beats a challenger's real patch)" ;;
    92) echo "triage-exec.js (bake-off): a patch that changes paths outside the subtask's files is inline-applied" ;;
    93) echo "triage-exec.js (bake-off): an unconfirmed leak state is not a stop (the plan runs on an unchecked tree)" ;;
    94) echo "triage-exec.js (bake-off): args.bakeoff.repo is never compared with the session repo (the patch lands in one tree, checks run in another)" ;;
    95) echo "triage-exec.js (bake-off): any failed apply counts as nothing written (a 3-way that left conflict markers is run in place on)" ;;
    96) echo "triage-exec.js: an ESCALATE level climb carries the lower rung's plan effort (builder@low -> deep@low)" ;;
    97) echo "triage-exec.js: a rejected external spawn escapes the same-level Claude fallback (the subtask is dropped)" ;;
    98) echo "triage-exec.js (bake-off): a missing weeklyPct samples as if usage were known to be low" ;;
    99) echo "triage-exec.js (bake-off): the danger floor by model family is not applied to challengers (danger work graded against sonnet / codex sol)" ;;
    100) echo "triage-compare.js: checks are joined with a bare ' && ' again (['false', 'true || true'] grades as a pass)" ;;
    101) echo "triage-compare.js: a PATCHCHECK line graded at another sha is accepted" ;;
    102) echo "triage-compare.js: a model/effort other than the candidate asked for (ext-run line) is graded and credited" ;;
    103) echo "triage-compare.js (review extend): the prior snapshot's include/exclude/context/hardExclude are not checked" ;;
    104) echo "ext-run.sh: the build worktree is not locked, so a parallel run's git worktree prune deletes it mid-run" ;;
    105) echo "review-stage.sh: no **/ variants — '**/secrets' misses a top-level secrets/, 'a/**/b' misses a/b" ;;
    106) echo "review-stage.sh: a missing ext-run.sh lets the snapshot go to codex (the deny carry-over fails open)" ;;
    107) echo "stage-worktree.sh: apply --require-clean is ignored (a patch lands on top of uncommitted work)" ;;
    108) echo "stage-worktree.sh: a failed apply write is assumed to have left the tree untouched (treeModified false)" ;;
    109) echo "stage-worktree.sh: ignored paths are left out of the leak fingerprint (a cache/build-output write is CLEAN)" ;;
    74) echo "triage-compare.js (review): a codex reviewer/adjudicator is spawned without TIMEOUT (ext-run's 5m read default kills a large review)" ;;
    110) echo "parity-report.sh: the per-observation dedupe is dropped (a same-content re-ingest appends every line again: double counts, no partial recovery)" ;;
    111) echo "parity-report.sh: a run id already in the ledger with DIFFERENT content is silently skipped instead of refused" ;;
    112) echo "parity-report.sh: utc ignores the UTC offset (a -05:00 ts is stored at the local wall time; aliases resolve on the wrong date)" ;;
    113) echo "parity-report.sh: the ledger lock is never taken (a held lock blocks nothing; check + append race)" ;;
    114) echo "parity-report.sh: a stale lock (its pid gone) is never taken over (every writer waits out its tries and fails)" ;;
    115) echo "parity-report.sh: backfill-modelid renames over the symlink path, replacing a symlinked ledger with a regular file" ;;
    116) echo "parity-report.sh: superseded / unconfigured model ids are challengers again (a proposal back to claude-opus-5)" ;;
    117) echo "parity-report.sh: tuning.rejected is ignored (a rejected challenger is proposed, pinning its level to explore)" ;;
    118) echo "parity-report.sh: reps are counted as independent trials (no collapse per (run, task))" ;;
    119) echo "parity-cost.sh: a corrupt transcript line is no longer skipped and counted" ;;
    120) echo "parity-report.sh: every review revision is counted, not only the latest of each run" ;;
    121) echo "parity-report.sh: ingest-review records a superseded reviewer as unavailable" ;;
    122) echo "parity-report.sh: a --resolved or extended review re-ingest gets no new revision (refused as a collision)" ;;
    123) echo "parity-report.sh: ingest-parity drops modelFrom (a runner-reported model is ledgered pinned, not observed)" ;;
    124) echo "triage-parity.js: build rows drop modelFrom (observed models reach the ledger as pinned)" ;;
    125) echo "parity-suite.sh: gitignored files are counted but not stat-ed (a refreshed cache file goes unseen; stage-worktree.sh ignored's list is only counted)" ;;
    126) echo "parity-suite.sh: refs/heads, tags and the stash are left out of the refs hash" ;;
    127) echo "triage-parity.js: sourceGuard compares head and tree only (ignored-file and refs changes never void a task)" ;;
    128) echo "triage-tiers.sh: --bakeoff-json no longer validates aliasHistory (ALIAS_ERRORS not evaluated)" ;;
    129) echo "triage-tiers.sh: the challengerMix shares-sum-to-1 check is dropped" ;;
    222) echo "triage-exec.js: a plan check with no CHECKRC line reads as exit 0 (a dead gate passes)" ;;
    223) echo "triage-exec.js: the FIRST CHECKRC line decides, so check output can spoof the exit status" ;;
    224) echo "triage-exec.js: a reviewer reply with no PASS/FIX/ESCALATE first line reads as PASS" ;;
    225) echo "triage-exec.js: runGate treats any non-null reply as a live gate (a malformed check/review reply is not retried)" ;;
    226) echo "triage-exec.js: args.repo is not compared with args.bakeoff.repo" ;;
    227) echo "triage-exec.js: plan checks do not cd into args.repo" ;;
    228) echo "triage-exec.js: the external brief header drops WORKDIR=<args.repo>" ;;
    229) echo "triage-exec.js: classifyBuild ignores a non-zero ext-run exit (a failed build reads as work)" ;;
    230) echo "triage-exec.js: classifyBuild reads CHANGED FILES: none as work" ;;
    231) echo "triage-exec.js: an unconfirmed leak state stops only its own subtask, not the plan" ;;
    232) echo "triage-exec.js: cross-review findings need no CROSS-REVIEW header (any reply is findings)" ;;
    233) echo "triage-exec.js: parseCleanCheck no longer validates rc / the clock" ;;
    234) echo "triage-exec.js: parseCleanCheck does not require the end marker (a truncated reply parses)" ;;
    235) echo "triage-exec.js: a failed clean check is not retried" ;;
    236) echo "triage-exec.js: round 1 re-verifies even when nothing was re-run" ;;
    237) echo "triage-exec.js: Fable-family models are allowed as bake-off challengers" ;;
    238) echo "triage-exec.js: a Fable-family planned model is sampled for a bake-off" ;;
    239) echo "triage-exec.js: ledgerRun joins the hashed long run id with '~' (outside parity-report's token set)" ;;
    240) echo "triage-exec.js: ledgerRun never shortens a long subtask id (the run id overflows the 80-char token)" ;;
    241) echo "triage-exec.js: normFile accepts absolute / .. / repo-root files under a bake-off" ;;
    242) echo "triage-exec.js: normFile keeps an absolute path under the repo (not made repo-relative)" ;;
    243) echo "triage-exec.js: ingestStatus books a pass with no real in-scope diff as a pass" ;;
    244) echo "triage-exec.js: the ingest result carries no run-time ts" ;;
    245) echo "triage-exec.js: a null candidate model is left for ingest-time resolution (never filled from the tiers config)" ;;
    246) echo "triage-compare.js: an external build reply is judged by the first-line rule (a preamble before REFUSED/EXTERNAL passes as work)" ;;
    247) echo "triage-compare.js: an external candidate with no ext-run accounting line is not marked invalid" ;;
    248) echo "triage-compare.js: a passing candidate with an empty diff is credited" ;;
    249) echo "triage-compare.js: a passing candidate that changed paths outside the brief's files is credited" ;;
    250) echo "triage-compare.js: a reviewer reply with no work is not reported unavailable (a refusal is parsed as findings)" ;;
    251) echo "triage-compare.js: an adjudicator reply is parsed without the CROSS-REVIEW header check" ;;
    252) echo "triage-compare.js: scopePath keeps an absolute path under the repo (brief/changed path spellings diverge)" ;;
    253) echo "triage-compare.js: scopePath keeps '.' path components" ;;
    254) echo "triage-compare.js: args.files are not normalised at entry (a <repo>/x file reaches the briefs as the real repo path)" ;;
    255) echo "triage-compare.js: classifyCrossReview lets a stray EXTERNAL ( line in a cross-review reply count as work" ;;
    256) echo "triage-compare.js: classifyExternal counts any non-blank line as work (the verdict header is not required)" ;;
    257) echo "triage-parity.js: a codex judge reply is scored without the CROSS-REVIEW header check" ;;
    258) echo "triage-parity.js: an external review reply with no work is not reported unavailable" ;;
    259) echo "triage-parity.js: classifyExternal counts any non-blank line as work (the verdict header is not required)" ;;
    260) echo "triage-parity.js: its classifyExternal copy drifts from triage-exec.js (REFUSED: token changed; lint 6e pin)" ;;
    261) echo "parity-report.sh: a refused id token no longer names the offending characters" ;;
    262) echo "parity-report.sh: a result's own ts is ignored at ingest" ;;
    263) echo "parity-report.sh: a model filled from today's tiers file at ingest is ledgered as pinned" ;;
    264) echo "parity-report.sh: stale-lock takeover skips the same-lock re-check (a live lock can be taken over)" ;;
    265) echo "parity-report.sh: stale-lock takeover ignores the takeover mutex (two takers can race)" ;;
    266) echo "parity-report.sh: an orphaned takeover mutex is never cleared" ;;
    267) echo "parity-report.sh: an ingest-time ts is not flagged inferred-at-ingest" ;;
    268) echo "parity-report.sh: rates counts configs no inline bake-off can reach as gaps" ;;
    269) echo "parity-report.sh: rates never reports the unsampleable state (a level with nothing reachable stays in explore)" ;;
    270) echo "triage-stats.sh: a workflow agent's transcript is attributed to the wrong session" ;;
    271) echo "triage-usage.sh: repeated message ids are summed instead of counted once" ;;
    272) echo "triage-usage.sh: a corrupt transcript line ends the file (later records dropped)" ;;
    273) echo "parity-report.sh: id_tokens drops '@' from its family split (lint 6d vs triage-exec modelTokens)" ;;
    274) echo "triage-exec.js: modelTokens drops '@' from its split (lint 6c/6d family-split)" ;;
    275) echo "triage.md: names a model id in prose (lint check 7, model ids live in config/tiers.json)" ;;
    276) echo "ext-run.sh: a hard-coded model id (lint check 7)" ;;
    277) echo "stage-worktree.sh: apply --require-clean omits rename/copy SOURCE paths from the patch headers" ;;
    278) echo "stage-worktree.sh: apply --require-clean reads a failed git status as clean" ;;
    279) echo "stage-worktree.sh: apply ignores a failed path listing (paths_ok stays 1)" ;;
    280) echo "stage-worktree.sh: a failed write over unlistable paths is measured as unmodified" ;;
    281) echo "stage-worktree.sh: the ignored-file fingerprint uses whole-second mtimes (a same-second rewrite goes unseen)" ;;
    282) echo "stage-worktree.sh: the ignored-file list stops excluding .DS_Store" ;;
    283) echo "stage-worktree.sh: apply with a non-repo --repo falls back to the cwd's repo" ;;
    284) echo "parity-suite.sh: ignored_tree hashes nothing (ignored files are not fingerprinted)" ;;
    285) echo "review-stage.sh: fingerprint omits the ignored-files hash" ;;
    286) echo "review-stage.sh: fingerprint compare ignores the ignored part" ;;
    287) echo "review-stage.sh: deny-refresh resolves the repo top with an inline resolver (case/symlink spelling drifts from repo_top)" ;;
    288) echo "review-stage.sh: fingerprint with a non-repo --repo falls back to the cwd's repo" ;;
    289) echo "ext-run.sh: stale build worktrees are never reaped (the reaper call is removed)" ;;
    290) echo "ext-run.sh: a live run's build worktree is reaped (the pid-alive check is removed)" ;;
    291) echo "ext-run.sh: the reaper skips every entry (stale builds are never reaped)" ;;
    292) echo "ext-run.sh: the locked build worktree carries no lock reason (the reaper cannot attribute it)" ;;
    293) echo "ext-run.sh: git worktree add runs the caller's hooks (core.hooksPath not neutralised)" ;;
    294) echo "ext-run.sh: the stage-base commit runs the caller's hooks (core.hooksPath not neutralised)" ;;
    295) echo "triage-context.sh: LEGACY_IMPORT_AWK strips every CR, not one trailing CR" ;;
    296) echo "install.sh: the subagent-model upgrade ignores the ownership marker (a downgraded legacy value is re-upgraded)" ;;
    297) echo "install.sh: CLAUDE_DIR is not canonicalised" ;;
    298) echo "uninstall.sh: CLAUDE_DIR is not canonicalised" ;;
    299) echo "uninstall.sh: settings.json is written last again (a CLAUDE.md failure leaves settings half-removed)" ;;
    300) echo "uninstall.sh: a CLAUDE.md write failure is ignored (files removed anyway)" ;;
    301) echo "install.sh: an outdated pointer line is not detected (never migrated)" ;;
    302) echo "uninstall.sh: the previous pointer-line spelling is left in CLAUDE.md" ;;
    303) echo "install.sh: LEGACY_IMPORT_AWK matches only the bare @triage.md spelling and keeps CRs" ;;
    304) echo "install.sh: POINTER_TAIL reverts to the previous spelling (no in-band fallback; the current line is treated as outdated)" ;;
    305) echo "install.sh: LEGACY_IMPORT_AWK carries only the bare spelling (a ./ or ~/ import is not recognised)" ;;
    *) echo "" ;;
  esac
}

# Which suite exercises this mutation's file: "roundtrip" (test/roundtrip.sh),
# "scenarios" (test/workflow-scenarios.mjs), "extrun" (test/ext-run.sh),
# "compare" (test/compare-scenarios.mjs), "patchcheck" (test/patch-check.sh),
# "stagewt" (test/stage-worktree.sh), "parity" (test/parity-scenarios.mjs),
# "paritysuite" (test/parity-suite.sh), "parityreport" (test/parity-report.sh) or
# "reviewstage" (test/review-stage.sh), "usage" (test/usage-tally.sh), "lint"
# (test/lint.sh) or "triagectx" (test/triage-context.sh).
mut_suite() {
  case "$1" in
    1|2|3|4|5|6|10|12|18|19|20|21|33) echo "roundtrip" ;;
    130|131|132|133|134|135|136|137|138|139|140|141|142|143|144|145|146|147|148|149) echo "roundtrip" ;;
    7|8|9|11|16|17|22|23|28|29|75|76|77|78|79|80|81|85|86|91|92|93|94|95|96|97|98|99) echo "scenarios" ;;
    15|24|25|26|40|49|50|51|56|57|58|59|60|61|62|70|71|104) echo "extrun" ;;
    31|34|36|37|38|47|68|69|72|73|74|100|101|102|103) echo "compare" ;;
    32|48|63|66) echo "patchcheck" ;;
    39|55|107|108|109) echo "stagewt" ;;
    41|42|46|64|65) echo "parity" ;;
    44|45) echo "paritysuite" ;;
    43|52|53|54|82|83|84|87|88|89|90) echo "parityreport" ;;
    110|111|112|113|114|115|116|117|118|120|121|122|123|128|129) echo "parityreport" ;;
    119|125|126) echo "paritysuite" ;;
    124|127) echo "parity" ;;
    67|105|106) echo "reviewstage" ;;
    150|151|152|153|154|155|156) echo "scenarios" ;;
    157|158|159|160|161) echo "compare" ;;
    162) echo "patchcheck" ;;
    163) echo "stagewt" ;;
    164|165) echo "roundtrip" ;;
    166|167) echo "compare" ;;
    168|169) echo "reviewstage" ;;
    170|171|172|173) echo "scenarios" ;;
    216|217|218|219|220|221) echo "scenarios" ;;
    174) echo "usage" ;;
    175) echo "usage" ;;
    176|177) echo "extrun" ;;
    178) echo "lint" ;;
    179|180|181|185) echo "triagectx" ;;
    182|183|184|187|188) echo "roundtrip" ;;
    189|190|191|192|193|194|195|196|197|198|199|200) echo "roundtrip" ;;
    201) echo "triagectx" ;;
    202|203|204|205|206|207|208|209|210|211|212|213|214|215) echo "roundtrip" ;;
    222|223|224|225|226|227|228|229|230|231|232|233|234|235|236|237|238|239|240|241|242|243|244|245) echo "scenarios" ;;
    246|247|248|249|250|251|252|253|254|255|256) echo "compare" ;;
    257|258|259) echo "parity" ;;
    260|273|274|275|276) echo "lint" ;;
    261|262|263|264|265|266|267|268|269) echo "parityreport" ;;
    270|271|272) echo "usage" ;;
    277|278|279|280|281|282|283) echo "stagewt" ;;
    284) echo "paritysuite" ;;
    285|286|287|288) echo "reviewstage" ;;
    289|290|291|292|293|294) echo "extrun" ;;
    295) echo "triagectx" ;;
    296|297|298|299|300|301|302|303|304|305) echo "roundtrip" ;;
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
    parity) echo "test/parity-scenarios.mjs" ;;
    paritysuite) echo "test/parity-suite.sh" ;;
    parityreport) echo "test/parity-report.sh" ;;
    reviewstage) echo "test/review-stage.sh" ;;
    usage) echo "test/usage-tally.sh" ;;
    lint) echo "test/lint.sh" ;;
    triagectx) echo "test/triage-context.sh" ;;
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
      # install.sh: delete the 3-line trailing-newline guard before the pointer append.
      mut_delete_block "$target" \
        '  if [ -s "$CLAUDE_MD" ] && [ -n "$(tail -c1 "$CLAUDE_MD")" ]; then' 3
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
        '    incomplete: rcs.some(rc => rc == null)' 1 "$rep"
      ;;
    8)
      # triage-exec.js: disable the gate retry surgically — the retry condition
      # becomes `if (false)`, so the gate is tried once and null is returned
      # immediately. 1-line replace: robust to surrounding runGate changes
      # (a 9-line block replace went stale when budget logic reshaped runGate).
      printf '    if (false) { // MUTATED: retry disabled\n' > "$rep"
      mut_replace_block "$target" '    if (!live(out) && !ceilinged) {' 1 "$rep"
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
      # triage-exec.js: the danger guard's overflow arm never fires. A danger
      # builder subtask routed by overflow (overflow:true, tier overflow) then falls
      # through to the codex arm, which lifts it to codex deep@high — correctness-
      # critical work goes off-vendor for throughput.
      cat > "$rep" <<'MUT16'
    if (false) { vendor = 'claude'; level = 'deep' } // MUTATED: overflow dropped from the danger guard
MUT16
      mut_replace_block "$target" \
        "    if (viaOverflow) { vendor = 'claude'; level = 'deep' }" 1 "$rep"
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
      # uninstall.sh: the removal loses its "still equals the marker" half, so a
      # model the user repointed after install is deleted with the marker.
      cat > "$rep" <<'MUT21'
    | (if $mark != null then del(.env.CLAUDE_CODE_SUBAGENT_MODEL) else . end)
MUT21
      mut_replace_block "$target" \
        '    | (if $mark != null and (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == $mark then' 1 "$rep"
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
    TIER_MODEL=gpt-6-sol; TIER_EFFORT=medium # MUTATED: default model fallback
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
      # triage-exec.js: redoStep() keeps the failed result's vendor, so a codex
      # attempt that failed verification is re-run on the SAME external vendor —
      # the sideways retry the ladder forbids.
      cat > "$rep" <<'MUT29'
  const vendor = r.vendor // MUTATED: retried sideways on the same vendor
MUT29
      mut_replace_block "$target" "  const vendor = 'claude' // every redo runs on Claude" 1 "$rep"
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
      mut_replace_block "$target" 'const leakInfo = leakState(gr && leakLine(gr.leakcheckLine))' 1 "$rep"
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
    41)
      # triage-parity.js: every non-pass/fail status except skipped is tallied as
      # a fail, so unavailable/denied/invalid/unresolved runs push a candidate
      # towards the stop rule.
      cat > "$rep" <<'MUT41'
        else if (r.status !== 'skipped') pb.fail++ // MUTATED: unavailable counted as fail
MUT41
      mut_replace_block "$target" "        else if (r.status !== 'skipped') pb.other++" 1 "$rep"
      ;;
    42)
      # triage-parity.js: a cleared band no longer resets the failed-band streak,
      # so failures need not be consecutive to stop a candidate.
      cat > "$rep" <<'MUT42'
    if (pb.rate >= passRate) { s.highest = Math.max(s.highest, b); continue } // MUTATED: streak not reset
MUT42
      mut_replace_block "$target" '    if (pb.rate >= passRate) { s.streak = 0; s.highest = Math.max(s.highest, b); continue }' 1 "$rep"
      ;;
    43)
      # parity-report.sh: direction() stops telling cheaper from pricier — every
      # ranked challenger goes through the cheaper (Wilson-bound) rule.
      cat > "$rep" <<'MUT43'
    else "cheaper" end; # MUTATED: cheapness order ignored
MUT43
      mut_replace_block "$target" '    elif $kc < $ki then "cheaper" elif $kc > $ki then "pricier" else "unranked" end;' 1 "$rep"
      ;;
    44)
      # parity-suite.sh: the 11-line propagation block (comment + loop) is gone,
      # so no .<vendor>-deny marker is written next to the clone.
      cat > "$rep" <<'MUT44'
  : # MUTATED: deny markers not propagated
MUT44
      mut_replace_block "$target" '  # Propagate: any deny status of the source becomes a marker next to the clone.' 11 "$rep"
      ;;
    45)
      # parity-suite.sh: the ref-deletion loop after the orphan commit is
      # skipped, so a generator source's own branch (and any other ref) stays
      # in the materialized repo — its history is no longer discarded.
      cat > "$rep" <<'MUT45'
  : # MUTATED: source history/refs kept
MUT45
      mut_replace_block "$target" '  for r in $(git -C "$MAT_REPO" for-each-ref --format='"'"'%(refname)'"'"' refs/heads refs/tags refs/remotes); do' 3 "$rep"
      ;;
    46)
      # triage-parity.js: the MODEL= header line for an external review
      # candidate is dropped, so its read-mode spawn falls back to
      # triage-cross-reviewer's mode-default model instead of the candidate's own.
      cat > "$rep" <<'MUT46'
      '' + // MUTATED: MODEL line dropped for external review candidates
MUT46
      mut_replace_block "$target" "      (c.model ? \`MODEL=\${c.model}\n\` : '') +" 1 "$rep"
      ;;
    47)
      # triage-compare.js: grade() stops voiding grades on an UNKNOWN leak state —
      # only an explicit LEAK invalidates, so a leakcheck that errored lets every
      # checks-green candidate through as a pass.
      cat > "$rep" <<'MUT47'
  // MUTATED: unknown leak state accepted
MUT47
      mut_replace_block "$target" "  if (leakInfo.leak !== false && gr) return Object.assign({}, g, { status: 'invalid'" 1 "$rep"
      ;;
    48)
      # patch-check.sh: the overlay copy failure is logged and ignored again (the
      # pre-fix behaviour): the check runs with the hidden tests missing.
      cat > "$rep" <<'MUT48'
  if [ -n "$OVERLAY" ]; then
    cp -R "$OVERLAY"/. "$WT"/ 2>> "$log" || echo "patch-check: overlay copy failed" >> "$log" # MUTATED: overlay failure ignored
  fi
MUT48
      mut_replace_block "$target" '  if [ -n "$OVERLAY" ] && ! cp -R "$OVERLAY"/. "$WT"/ 2>> "$log"; then' 5 "$rep"
      ;;
    49)
      # ext-run.sh: the top-level unset of the git redirection variables is gone.
      cat > "$rep" <<'MUT49'
: # MUTATED: git env not cleared
MUT49
      mut_replace_block "$target" 'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE' 1 "$rep"
      ;;
    50)
      # ext-run.sh: resolve_path reverts to resolving only the PARENT dir of a
      # file, so a symlink's own target is never judged.
      cat > "$rep" <<'MUT50'
resolve_path() { # MUTATED: symlink resolved only at parent
  local d
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P) || echo "$1"
  elif [ -f "$1" ]; then
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d=$(dirname "$1")
    echo "$d/$(basename "$1")"
  else echo "$1"
  fi
}
MUT50
      mut_replace_block "$target" 'resolve_path() { # $1 = path -> absolute physical path' 14 "$rep"
      ;;
    51)
      # ext-run.sh: the 3-way apply is attempted without the conflict pre-check,
      # so a conflicting merge writes markers into the caller's tree.
      cat > "$rep" <<'MUT51'
  if true; then # MUTATED: conflicting 3-way apply not pre-checked
MUT51
      mut_replace_block "$target" '  if LC_ALL=C git -C "$BUILD_REPO" apply --3way --check "$OUTPUT" >"$chk3" 2>&1' 1 "$rep"
      ;;
    52)
      # parity-report.sh: need() always says 0 more runs are needed.
      cat > "$rep" <<'MUT52'
def need($n): 0; # MUTATED: minN ignored
MUT52
      mut_replace_block "$target" 'def need($n): if $n >= $minN then 0 else $minN - $n end;' 1 "$rep"
      ;;
    53)
      # parity-report.sh: the cheaper rule compares the point rate, not the
      # Wilson 95% lower bound.
      cat > "$rep" <<'MUT53'
        (if $ch.rate >= $inc.rate - $tol - 1e-12 then .verdict = "propose" else .verdict = "keep" end) # MUTATED: point rate, not Wilson LB
MUT53
      mut_replace_block "$target" '        (if $ch.wilsonLB >= $inc.rate - $tol - 1e-12 then .verdict = "propose" else .verdict = "keep" end)' 1 "$rep"
      ;;
    54)
      # parity-report.sh: norm maps every non-graded status to "fail".
      cat > "$rep" <<'MUT54'
    else "fail" end; # MUTATED: non-graded status counted as fail
MUT54
      mut_replace_block "$target" '    else (if (KNOWN | index($s)) != null then $s else "unknown" end) end;' 1 "$rep"
      ;;
    55)
      # stage-worktree.sh: apply attempts the 3-way merge without the conflict
      # pre-check, so a conflicting patch writes markers into the caller's tree.
      cat > "$rep" <<'MUT55'
  if true; then # MUTATED: conflicting 3-way apply not pre-checked
MUT55
      mut_replace_block "$target" '  if git -C "$R" apply --3way --check "$PATCH" >"$chk3" 2>&1 && ! grep -qi '"'"'conflict'"'"' "$chk3"; then' 1 "$rep"
      ;;
    56)
      # ext-run.sh: codex is exec'd directly — the sandbox-exec wrapper (and so
      # the whole OS confinement) is gone, while codex's own sandbox stays
      # bypassed. The preflight still passes; only the real run is unconfined.
      cat > "$rep" <<'MUT56'
    exec "$CODEX_REAL" "$@" ) < "$PROMPT" > "$EVENTS" 2> "$ERRLOG" & # MUTATED: codex run without sandbox-exec
MUT56
      mut_replace_block "$target" '    exec "$SANDBOX_EXEC" -f "$PROFILE" "$CODEX_REAL" "$@" ) < "$PROMPT" > "$EVENTS" 2> "$ERRLOG" &' 1 "$rep"
      ;;
    57)
      # ext-run.sh: $HOME is re-allowed as a subpath instead of a literal, so the
      # deny of every read under $HOME is undone: ~/projects is readable again.
      cat > "$rep" <<'MUT57'
    printf '(allow file-read* (subpath %s) (subpath %s) (subpath %s) (subpath %s)' \
MUT57
      mut_replace_block "$target" "    printf '(allow file-read* (literal %s) (subpath %s) (subpath %s) (subpath %s)' \\" 1 "$rep"
      ;;
    58)
      # ext-run.sh: the audit line gains the command's aggregated_output.
      cat > "$rep" <<'MUT58'
         exitCode: (.exit_code | if type == "number" then . else null end), output: .aggregated_output}' 2>/dev/null) # MUTATED: audit records aggregated_output
MUT58
      mut_replace_block "$target" "         exitCode: (.exit_code | if type == \"number\" then . else null end)}' 2>/dev/null)" 1 "$rep"
      ;;
    59)
      # ext-run.sh: the agy refusal is gone — --vendor agy falls through to the
      # tiers lookup (and is refused there only by accident of a missing entry).
      cat > "$rep" <<'MUT59'
  agy) ;; # MUTATED: agy accepted
MUT59
      mut_replace_block "$target" '  agy) die "REFUSED: agy retired 2026-09-24' 1 "$rep"
      ;;
    60)
      # ext-run.sh: the deny-by-default write rule is rolled back to the
      # pre-review one — writes denied only under $HOME, the temp dirs and the
      # stage, allowed by default everywhere else.
      cat > "$rep" <<'MUT60'
    printf '(deny file-write* (subpath %s) (subpath "/private/tmp") (subpath "/private/var/folders") (subpath %s))\n' "$(sbpl_q "$HOME_P")" "$(sbpl_q "$STAGE_ABS")" # MUTATED: writes allowed by default
MUT60
      mut_replace_block "$target" "    printf '(deny file-write* (subpath \"/\"))\\n'" 1 "$rep"
      ;;
    61)
      # ext-run.sh: reads are denied under $HOME only again — the temp dirs
      # (other stages, patches, Claude scratchpads) are readable.
      cat > "$rep" <<'MUT61'
    printf '(deny file-read* (subpath %s))\n' "$(sbpl_q "$HOME_P")" # MUTATED: temp-dir reads open
MUT61
      mut_replace_block "$target" "    printf '(deny file-read* (subpath %s) (subpath \"/private/tmp\")" 1 "$rep"
      ;;
    62)
      # ext-run.sh: the preflight's sandboxed command writes only its first
      # argument (the stage-root canary); the outside canary is never attempted.
      cat > "$rep" <<'MUT62'
  ( cd "$RUNDIR_ABS" && export TMPDIR="$CX/tmp" && exec "$SANDBOX_EXEC" -f "$PROFILE" /bin/sh -c 'true > "$1"; exit 0' sh "$canary" "$outside" ) \
MUT62
      mut_replace_block "$target" "/bin/sh -c 'true > \"\$1\"; true > \"\$2\"; exit 0' sh \"\$canary\" \"\$outside\" ) \\" 1 "$rep"
      ;;
    63)
      # patch-check.sh: the unmapped-variable refusal is gone — a check naming a
      # $PARITY_ variable the env map lacks runs anyway (with "null" exported).
      cat > "$rep" <<'MUT63'
  : # MUTATED: unmapped PARITY_ variable silently ignored
MUT63
      mut_replace_block "$target" '  [ -z "$unmapped" ] || usage "unmapped PARITY_ variable(s) referenced by the check: ${unmapped% } (env map $map)"' 1 "$rep"
      ;;
    64)
      # triage-parity.js: only build tasks are re-fingerprinted after grading.
      cat > "$rep" <<'MUT64'
  if (mat.fp.source === 'git' && rows.length && !leakAbort && t.kind === 'build') rows = await sourceGuard(tm, b, rows) // MUTATED: fingerprint skipped for review tasks
MUT64
      mut_replace_block "$target" "  if (mat.fp.source === 'git' && rows.length && !leakAbort) rows = await sourceGuard(tm, b, rows)" 1 "$rep"
      ;;
    65)
      # triage-parity.js: the judge instruction names the materialized repo again.
      cat > "$rep" <<'MUT65'
  const ONLY_TWO = 'Read only these two files; do not cd anywhere or read, list or search any other path. You have no repository access: grade from the patch and the key alone.' + ` (The candidates worked in ${t.mat.repo}.)` // MUTATED: judge gets repo path
MUT65
      mut_replace_block "$target" "  const ONLY_TWO = 'Read only these two files; do not cd anywhere" 1 "$rep"
      ;;
    66)
      # patch-check.sh: the check inherits the caller's cache/temp locations.
      cat > "$rep" <<'MUT66'
  ( cd "$WT" && eval "$ENV_LINES" && exec bash -c "$CHECK" ) > "$1" 2>&1 < /dev/null & # MUTATED: cache env not set
MUT66
      mut_replace_block "$target" '  ( cd "$WT" && export XDG_CACHE_HOME="$CACHE" TMPDIR="$CACHE" GRANTFORGE_CACHE_DIR="$CACHE" && eval "$ENV_LINES" && exec bash -c "$CHECK" ) > "$1" 2>&1 < /dev/null &' 1 "$rep"
      ;;
    67)
      # review-stage.sh: split_hard lets a TRACKED path through (hard excludes
      # behave like .gitignore, which never un-tracks a committed file).
      cat > "$rep" <<'MUT67'
    if ! git -C "$R" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && pat=$(hard_match "$rel"); then printf '%s\t%s\n' "$rel" "$pat" >> "$3"; continue; fi # MUTATED: hard exclude skipped for tracked paths
MUT67
      mut_replace_block "$target" '    if pat=$(hard_match "$rel"); then printf' 1 "$rep"
      ;;
    68)
      # triage-compare.js: each blind item carries its anonymized provenance.
      cat > "$rep" <<'MUT68'
  const blindItem = it => JSON.stringify({ id: it.id, file: it.file, line: it.line, severity: it.severity, category: it.category, claim: it.claim, evidence: it.evidence, suggestedFix: it.suggestedFix, reportedBy: it.prov }) // MUTATED: adjudicator sees provenance
MUT68
      mut_replace_block "$target" '  const blindItem = it => JSON.stringify({ id: it.id,' 1 "$rep"
      ;;
    69)
      # triage-compare.js: disputed items score as real.
      cat > "$rep" <<'MUT69'
  const isReal = it => it.verdict === 'real' || it.verdict === 'disputed' // MUTATED: disputed counted as real
MUT69
      mut_replace_block "$target" "  const isReal = it => it.verdict === 'real'" 1 "$rep"
      ;;
    70)
      # ext-run.sh: a symlink leaving the --input-dir tree is let through.
      cat > "$rep" <<'MUT70'
      *) : ;; # MUTATED: input-dir follows an outside symlink
MUT70
      mut_replace_block "$target" '      *) die "REFUSED: --input-dir $real holds a symlink that leaves it' 1 "$rep"
      ;;
    71)
      # ext-run.sh: codex gets the caller's schema verbatim, not the strict form.
      cat > "$rep" <<'MUT71'
  cp "$SCHEMA_ORIG" "$SCHEMA_FILE" # MUTATED: schema passed to codex un-normalized
MUT71
      mut_replace_block "$target" '  jq -c "$STRICT_SCHEMA_JQ" "$SCHEMA_ORIG" > "$SCHEMA_FILE"' 1 "$rep"
      ;;
    72)
      # triage-compare.js: an extension adjudicates every item, prior ones included.
      cat > "$rep" <<'MUT72'
  const toJudge = items // MUTATED: extend re-adjudicates attached items
MUT72
      mut_replace_block "$target" '  const toJudge = prior ? items.filter(it => newIds.has(it.id)) : items' 1 "$rep"
      ;;
    73)
      # triage-compare.js: supersedes is ignored — the prior row keeps its status.
      cat > "$rep" <<'MUT73'
    status: p.status, // MUTATED: superseded reviewer still scored
MUT73
      mut_replace_block "$target" "    status: supersededSet.has(p.label) || p.status === 'superseded' ? 'superseded' : p.status," 1 "$rep"
      ;;
    74)
      # triage-compare.js: the codex header loses its TIMEOUT line.
      cat > "$rep" <<'MUT74'
    return `VENDOR=${c.vendor}\nMODE=read\nMODEL=${c.model}\nEFFORT=${c.effort}\nINPUT_DIR=${dir}\nPROMPT_BYTES=${promptBytes}\n` + // MUTATED: codex spawned without TIMEOUT
MUT74
      mut_replace_block "$target" '    return `VENDOR=${c.vendor}\nMODE=read\nMODEL=${c.model}\nEFFORT=${c.effort}\nINPUT_DIR=${dir}\nTIMEOUT=${timeout}' 1 "$rep"
      ;;
    75)
      # triage-exec.js: the weekly pause never trips.
      cat > "$rep" <<'MUT75'
const bakeoffPaused = false // MUTATED: weekly pause ignored
MUT75
      mut_replace_block "$target" 'const bakeoffPaused = !!bo && (weeklyUnknown || bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct)' 1 "$rep"
      ;;
    76)
      # triage-exec.js: bakeoffPick() loses its sample threshold.
      cat > "$rep" <<'MUT76'
  // MUTATED: sample threshold dropped
MUT76
      mut_replace_block "$target" "  if (!(draw(key) < rate)) return Object.assign({ skip: 'not-sampled' }, rateRec)" 1 "$rep"
      ;;
    77)
      # triage-exec.js: bakeoffChoice() never falls back to a passing challenger.
      cat > "$rep" <<'MUT77'
  // MUTATED: challenger fallback dropped
MUT77
      mut_replace_block "$target" "  if (ch.status === 'pass' && realDiff(ch)) return { apply: 'challenger', cand: ch, planned: p }" 1 "$rep"
      ;;
    78)
      # triage-exec.js: runBakeoff() no longer treats leak:true as an abort.
      cat > "$rep" <<'MUT78'
  if (false) { // MUTATED: LEAK abort dropped
MUT78
      mut_replace_block "$target" '  if (res && res.leak === true) {' 1 "$rep"
      ;;
    79)
      # triage-exec.js: the dirty-files guard only checks that the agent replied.
      cat > "$rep" <<'MUT79'
  if (!dirty) { // MUTATED: dirty files not checked
MUT79
      mut_replace_block "$target" "  if (!dirty || dirty.rc !== 0 || dirty.porcelain.length) {" 1 "$rep"
      ;;
    80)
      # triage-exec.js: bakeoffPick()'s challenger pool drops the codex danger floor.
      cat > "$rep" <<'MUT80'
      true && // MUTATED: danger floor on challengers dropped
MUT80
      mut_replace_block "$target" "      !(st.danger && v === 'codex' && !meetsCodexDangerFloor(st.level, c.effort)) &&" 1 "$rep"
      ;;
    81)
      # triage-exec.js: report() adds the bake-off fields unconditionally.
      cat > "$rep" <<'MUT81'
    ...bakeoffReport(), // MUTATED: bake-off fields without args.bakeoff
MUT81
      mut_replace_block "$target" '    ...(bakeoffOn ? bakeoffReport() : {}),' 1 "$rep"
      ;;
    82)
      # parity-report.sh rates: "enough data" becomes "any data".
      cat > "$rep" <<'MUT82'
                 | if $g.n < 1 then "\($who) n=\($g.n) < \($minN)" # MUTATED: rates n check weakened
MUT82
      mut_replace_block "$target" '                 | if $g.n < $minN then "\($who) n=\($g.n) < \($minN)"' 1 "$rep"
      ;;
    83)
      # parity-report.sh rates: the CI-width gap is never raised.
      cat > "$rep" <<'MUT83'
                   elif false then "" # MUTATED: rates CI width ignored
MUT83
      mut_replace_block "$target" '                   elif ($g.wilsonUB - $g.wilsonLB) > $maxWidth + 1e-12 then' 1 "$rep"
      ;;
    84)
      # parity-report.sh rates: pending proposals are not gaps.
      cat > "$rep" <<'MUT84'
               ($proposals[] | select(false) # MUTATED: proposal does not force explore
MUT84
      mut_replace_block "$target" '               ($proposals[] | select(.level == $L and .vendor == $V)' 1 "$rep"
      ;;
    85)
      # triage-exec.js: bakeoffPick() samples at sampleRate whatever rates says.
      cat > "$rep" <<'MUT85'
  const rate = bo.tuning.sampleRate // MUTATED: rates ignored
MUT85
      mut_replace_block "$target" '  const rate = fromRates ? bo.rates[st.level] : bo.tuning.sampleRate' 1 "$rep"
      ;;
    86)
      # triage-exec.js report(): the bake-off arm of externalInPlay is dropped.
      cat > "$rep" <<'MUT86'
    false // MUTATED: applied external bake-off patch not in play
MUT86
      mut_replace_block "$target" '    bakeoffs.some(b => { const v = appliedVendor(b); return v !== null && isExternal(v) })' 1 "$rep"
      ;;
    87)
      # parity-report.sh report: the group key collapses modelId back to model.
      cat > "$rep" <<'MUT87'
  [$rows | group_by([.level, .vendor, .model, .effort])[] # MUTATED: grouped by model, not modelId
MUT87
      mut_replace_block "$target" '  [$rows | group_by([.level, .vendor, .modelId, .effort])[]' 1 "$rep"
      ;;
    88)
      # parity-report.sh alias_at: an entry counts only AFTER its from date.
      cat > "$rep" <<'MUT88'
def alias_at($ah; $v; $m; $date): [(($ah[$v] // {})[$m | id_base] // [])[] | select(.from < $date)] | last | if . == null then null else .id end; # MUTATED: alias boundary exclusive
MUT88
      mut_replace_block "$target" 'def alias_at($ah; $v; $m; $date): [(($ah[$v] // {})[$m | id_base] // [])[] | select(.from <= $date)]' 1 "$rep"
      ;;
    89)
      # parity-report.sh FAMILY_ORDER: codex families pinned to one version's ids.
      cat > "$rep" <<'MUT89'
def FAMILY_ORDER: {"claude":["haiku","sonnet","opus","fable"],"codex":["gpt-6-luna","gpt-6-sol","gpt-6-astra"],"agy":["flash","pro"]}; # MUTATED: version-bound cheapness order
MUT89
      mut_replace_block "$target" 'def FAMILY_ORDER: {"claude":["haiku","sonnet","opus","fable"],"codex":["luna","sol","astra"],"agy":["flash","pro"]};' 1 "$rep"
      ;;
    90)
      # parity-report.sh backfill: every object row counts as unfilled.
      cat > "$rep" <<'MUT90'
    | def unfilled: type == "object"; # MUTATED: backfill refills filled rows
MUT90
      mut_replace_block "$target" '    | def unfilled: type == "object" and (has("modelId") | not);' 1 "$rep"
      ;;
    130)
      printf '  if true; then # MUTATED: deleted without the repo-copy check\n' > "$rep"
      mut_replace_block "$target" '  if [ -f "$REPO_DIR/$1" ] && cmp -s "$REPO_DIR/$1" "$2"; then' 1 "$rep"
      ;;
    131)
      printf '  rm -rf "$CLAUDE_DIR/agent-memory/$a" # MUTATED: memory deleted, not backed up\n' > "$rep"
      mut_replace_block "$target" '  if [ -e "$CLAUDE_DIR/agent-memory/$a" ]; then backup_move' 1 "$rep"
      ;;
    132)
      printf '  b="$1.bak-triage-0"; printf "%%s" "$b"; return 0 # MUTATED: single-slot backup\n' > "$rep"
      mut_replace_block "$target" '  b="$1.bak-triage-$STAMP"' 1 "$rep"
      ;;
    133)
      printf 'prune_backups() { return 0 # MUTATED: backups never pruned\n' > "$rep"
      mut_replace_block "$target" 'prune_backups() {' 1 "$rep"
      ;;
    134)
      printf '  if true; then # MUTATED: retire deletes unknown bytes\n' > "$rep"
      mut_replace_block "$target" '  if [ -n "$sha" ] && printf '"'"'%s'"'"' "$sums" | grep -qxF "$sha"; then' 1 "$rep"
      ;;
    135)
      printf 'SUBAGENT_MODEL="claude-opus-5-5" # MUTATED: hard-coded subagent model\n' > "$rep"
      mut_replace_block "$target" 'SUBAGENT_MODEL="$(jq -r' 1 "$rep"
      ;;
    136)
      cat > "$rep" <<'MUT136'
  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null or $up == "1" then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m else . end)
MUT136
      mut_replace_block "$target" '  (if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null or $up == "1" then' 1 "$rep"
      ;;
    137)
      printf '  elif false; then echo "upgrade-owned" # MUTATED: marker ownership ignored\n' > "$rep"
      mut_replace_block "$target" '  elif [ "$1" = "$2" ]; then echo "upgrade-owned"' 1 "$rep"
      ;;
    138)
      printf '  | . # MUTATED-138\n' > "$rep"
      mut_replace_block "$target" '  | (if (.env[$k] // null) != null and .env[$k] != .env.CLAUDE_CODE_SUBAGENT_MODEL then del(.env[$k]) else . end)' 1 "$rep"
      ;;
    139)
      printf '  elif [ "$1" = "$SUBAGENT_MODEL" ]; then echo "upgrade-owned" # MUTATED: unmarked current value adopted\n' > "$rep"
      mut_replace_block "$target" '  elif [ "$1" = "$SUBAGENT_MODEL" ]; then echo "current"' 1 "$rep"
      ;;
    140)
      printf "' \"\$SETTINGS_SRC\" > \"\$tmp\" && apply_settings \"\$tmp\" # MUTATED: merge failure swallowed\n" > "$rep"
      mut_replace_block "$target" "' \"\$SETTINGS_SRC\" > \"\$tmp\" || die \"settings merge (jq) failed" 2 "$rep"
      ;;
    141)
      printf "  ' \"\$SETTINGS\" > \"\$tmp\" || true # MUTATED: rewrite failure swallowed\n" > "$rep"
      mut_replace_block "$target" "  ' \"\$SETTINGS\" > \"\$tmp\" || die \"settings rewrite (jq) failed" 1 "$rep"
      ;;
    142)
      printf '  true # MUTATED: settings shape not validated\n' > "$rep"
      mut_replace_block "$target" "  jq -e 'def shape(t): . == null or type == t;" 9 "$rep"
      ;;
    143)
      printf '    --root)  ROOT="${2:-}"; shift 2 ;; # MUTATED: --root value unchecked\n' > "$rep"
      mut_replace_block "$target" '    --root)' 3 "$rep"
      ;;
    144)
      mut_delete_block "$target" '    END { if (infm) exit 3 }' 1
      ;;
    145|146)
      printf '  grep -vE '"'"'^\\s*#|^\\s*$'"'"' "$DRIFTIGNORE" | grep -qxF "$1" # MUTATED: entries not normalized\n' > "$rep"
      mut_replace_block "$target" "  tr -d '\\r' < \"\$DRIFTIGNORE\"" 2 "$rep"
      ;;
    147)
      printf '    : # MUTATED: settings status not checked\n' > "$rep"
      mut_replace_block "$target" '"$REPO_DIR/install.sh" --settings-status' 1 "$rep"
      ;;
    148)
      printf '         stage-worktree.sh review-stage.sh parity-suite.sh parity-cost.sh \\\n' > "$rep"
      mut_replace_block "$target" '         stage-worktree.sh review-stage.sh parity-suite.sh parity-cost.sh parity-report.sh \' 1 "$rep"
      ;;
    149)
      mut_delete_block "$target" 'check_file "scripts/triage-stats.sh"' 1
      ;;
    150)
      # triage-exec.js: the bake-off apply command drops --require-clean.
      cat > "$rep" <<'MUT150'
    `${STAGE_WT} apply --repo ${shq(bo.repo)} --patch ${shq(patch)}`, // MUTATED: --require-clean dropped
MUT150
      mut_replace_block "$target" '--patch ${shq(patch)} --require-clean' 1 "$rep"
      ;;
    151)
      # triage-exec.js: the applied result carries the CHALLENGER's effort, not the plan's.
      cat > "$rep" <<'MUT151'
  const who = choice.apply === 'planned' ? { level: st.level, vendor: st.vendor, effort: st.effort } : { level: st.level, vendor: ch.vendor, effort: ch.effort } // MUTATED: challenger effort stored
MUT151
      mut_replace_block "$target" 'vendor: st.vendor, effort: st.effort } : { level: st.level, vendor: ch.vendor, effort: st.effort }' 1 "$rep"
      ;;
    152)
      # triage-exec.js: an apply reply counts even when it names another patch.
      cat > "$rep" <<'MUT152'
  const applied = !!ap && ap.rc === 0 && ap.ok === true && ap.applied === true && (ap.method === 'plain' || ap.method === '3way') // MUTATED: patch identity not checked
MUT152
      mut_replace_block "$target" '&& ap.patch === patch' 1 "$rep"
      ;;
    153)
      # triage-exec.js: the danger floor is not checked against the PLANNED candidate.
      cat > "$rep" <<'MUT153'
  // MUTATED: planned danger floor check dropped
MUT153
      mut_replace_block "$target" "skip: 'planned-below-danger-floor'" 1 "$rep"
      ;;
    154)
      # triage-exec.js: a top-level Claude subtask is no longer excluded from bake-offs.
      cat > "$rep" <<'MUT154'
  // MUTATED: top-claude ineligibility dropped
MUT154
      mut_replace_block "$target" "skip: 'top-claude'" 1 "$rep"
      ;;
    155)
      # triage-exec.js: the challenger entry reverts to a plain modulo of the raw hash
      # (FNV-1a's low bits are weak).
      cat > "$rep" <<'MUT155'
  const c = list[fnv1a32(`${key}\0entry`) % list.length] // MUTATED: entry via raw hash modulo (low bits)
MUT155
      mut_replace_block "$target" 'Math.floor(draw(`${key}\0entry`) * list.length)' 1 "$rep"
      ;;
    156)
      # triage-exec.js: an unavailable planned codex run no longer excludes the
      # subtask from ranExternally.
      cat > "$rep" <<'MUT156'
  const noExt = () => {} // MUTATED: never adds to neverRanExternally
MUT156
      mut_replace_block "$target" 'if (plannedNothing) neverRanExternally.add(st.id)' 1 "$rep"
      ;;
    157)
      # triage-compare.js: outOfScope is never computed from changedFiles vs files.
      cat > "$rep" <<'MUT157'
  const outOfScope = false // MUTATED: outOfScope always false
MUT157
      mut_replace_block "$target" 'const outOfScope = !files.length' 1 "$rep"
      ;;
    158)
      # triage-compare.js: selfCheckEnv reaches external candidates too.
      cat > "$rep" <<'MUT158'
const selfCheckFor = c => selfCheckEnv // MUTATED: selfCheckEnv offered to externals too
MUT158
      mut_replace_block "$target" 'selfCheckFor = c => selfCheckEnv &&' 1 "$rep"
      ;;
    159)
      # triage-compare.js: any present error field invalidates, even an empty string.
      cat > "$rep" <<'MUT159'
  if (pc.error != null || (pc.applies === true && pc.rc == null)) { // MUTATED: any present error field invalidates
MUT159
      mut_replace_block "$target" 'if (isStr(pc.error) ||' 1 "$rep"
      ;;
    160)
      # triage-compare.js: a reviewer whose findings are all malformed still scores ok.
      cat > "$rep" <<'MUT160'
    const allMalformed = c => false // MUTATED: all-malformed reviewer scored ok
MUT160
      mut_replace_block "$target" 'const allMalformed = c => c.ok.length === 0 && c.dropped > 0' 1 "$rep"
      ;;
    161)
      # triage-compare.js: cleanPath cuts an absolute path at the LAST /snap/, not the first.
      cat > "$rep" <<'MUT161'
    if (s.startsWith('/')) { const i = s.lastIndexOf('/snap/'); return i >= 0 ? s.slice(i + 6) : s } // MUTATED: last /snap/ instead of first
MUT161
      mut_replace_block "$target" 'return i >= 0 ? s.slice(i + 6) : s }' 1 "$rep"
      ;;
    162)
      # patch-check.sh: --summary no longer emits the PATCHCHECK json line.
      cat > "$rep" <<'MUT162'
  : # MUTATED: --summary line dropped
MUT162
      mut_replace_block "$target" "sed 's/^/PATCHCHECK /'" 1 "$rep"
      ;;
    163)
      # stage-worktree.sh: leakcheck --line no longer emits the LEAKCHECK json line.
      cat > "$rep" <<'MUT163'
  printf '%s\n' "$json" # MUTATED: LEAKCHECK line never emitted
MUT163
      mut_replace_block "$target" "printf 'LEAKCHECK %s" 1 "$rep"
      ;;
    164)
      # install.sh backup_path: back to the first free name.
      cat > "$rep" <<'MUT164'
  n=1; while [ -e "$b" ] || [ -L "$b" ]; do b="$1.bak-triage-$STAMP-$n"; n=$((n + 1)); done # MUTATED: first free backup name
MUT164
      mut_replace_block "$target" '  if [ -e "$b" ] || [ -L "$b" ] || ls -d "$b"-* >/dev/null 2>&1; then' 9 "$rep"
      ;;
    165)
      # install.sh backups_oldest_first: -N compared as text.
      cat > "$rep" <<'MUT165'
  done | LC_ALL=C sort -k1,1 -k2,2 | cut -d' ' -f3- # MUTATED: -N sorted as text
MUT165
      mut_replace_block "$target" "  done | LC_ALL=C sort -k1,1 -k2,2n | cut -d' ' -f3-" 1 "$rep"
      ;;
    166)
      # triage-compare.js (review extend): the deny re-asked at extend is ignored.
      cat > "$rep" <<'MUT166'
    const deniedNow = false // MUTATED: refreshed deny ignored
MUT166
      mut_replace_block "$target" '    const deniedNow = prior.codexDeniedNow !== false' 1 "$rep"
      ;;
    167)
      # triage-compare.js (review extend): a dropped/garbled codexDeniedNow counts as allowed.
      cat > "$rep" <<'MUT167'
          codexDeniedNow: c.codexDeniedNow === true, // MUTATED: missing refresh allows codex
MUT167
      mut_replace_block "$target" "          codexDeniedNow: typeof c.codexDeniedNow === 'boolean' ? c.codexDeniedNow : true," 1 "$rep"
      ;;
    168)
      # review-stage.sh deny-refresh: the repo's deny query is skipped.
      cat > "$rep" <<'MUT168'
    : # MUTATED: deny-refresh skips the repo
MUT168
      mut_replace_block "$target" '    if codex_denied --beneath "$R"; then denied=true; fi' 1 "$rep"
      ;;
    169)
      # review-stage.sh deny-refresh: no manifest → allowed (fail open).
      cat > "$rep" <<'MUT169'
    : # MUTATED: missing manifest allows codex
MUT169
      mut_replace_block "$target" '    echo "review-stage: deny-refresh: no $OUT/manifest.json' 2 "$rep"
      ;;
    216)
      # triage-exec.js: redoStep() loses its noFable guard.
      cat > "$rep" <<'MUT216'
  if (false) { // MUTATED: redoStep noFable guard dropped
MUT216
      mut_replace_block "$target" '  if (noFable && (r.owesFable || r.level === '"'"'top'"'"' || (isEscalate && ranMax(r)))) {' 1 "$rep"
      ;;
    217)
      # triage-exec.js: runFable() loses its noFable guard.
      cat > "$rep" <<'MUT217'
  if (false) { // MUTATED: runFable noFable guard dropped
MUT217
      mut_replace_block "$target" '  if (noFable) {' 1 "$rep"
      ;;
    218)
      # triage-exec.js: bad() no longer refuses a claude top subtask under noFable.
      cat > "$rep" <<'MUT218'
  // MUTATED: noFable top check dropped
MUT218
      mut_replace_block "$target" '  if (fableSt) bad(' 1 "$rep"
      ;;
    219)
      # triage-exec.js: redoStep() drops the noFable same-rung retry marker on deep@max.
      cat > "$rep" <<'MUT219'
  // MUTATED: noFable deep@max retry unmarked
MUT219
      mut_replace_block "$target" '  if (noFable && ranMax(r)) return {' 1 "$rep"
      ;;
    220)
      # triage-exec.js: runFable()'s empty deep@max fallback under noFable returns null.
      cat > "$rep" <<'MUT220'
    return mx ? { output: mx, level: 'deep', vendor: 'claude', effort: 'max' } : null // MUTATED: empty deep@max not stopped
MUT220
      mut_replace_block "$target" "    return mx ? { output: mx, level: 'deep', vendor: 'claude', effort: 'max' } : stopForUser(" 1 "$rep"
      ;;
    221)
      # triage-exec.js: needs-user no longer makes the run incomplete.
      cat > "$rep" <<'MUT221'
  incomplete: finalAssessment.incomplete || withheld.size > 0, // MUTATED: needs-user not incomplete
MUT221
      mut_replace_block "$target" '  incomplete: finalAssessment.incomplete || withheld.size > 0 || needsUser.size > 0,' 1 "$rep"
      ;;
    170)
      # triage-exec.js: the triage-external brief drops the boundary attestation.
      cat > "$rep" <<'MUT170'
      out = await agent(`${externalHeader(step)}\n\n${prompt}`, // MUTATED: attestation dropped
MUT170
      mut_replace_block "$target" 'out = await agent(`${externalHeader(step)}\n\n${BOUNDARY_ATTESTATION}\n\n${prompt}`,' 1 "$rep"
      ;;
    171)
      # triage-exec.js: classifyExternal() reads only the reply's first line.
      cat > "$rep" <<'MUT171'
  for (const raw of lines.slice(0, 1)) { // MUTATED: first line only
MUT171
      mut_replace_block "$target" '  for (const raw of lines) {' 1 "$rep"
      ;;
    172)
      # triage-exec.js: the refused list is never reported.
      cat > "$rep" <<'MUT172'
      refused: [], // MUTATED: refused not reported
MUT172
      mut_replace_block "$target" "      refused: externalNoWork.filter(n => n.vendor === v && n.kind === 'refused')" 1 "$rep"
      ;;
    173)
      # triage-exec.js: the no-work escalation reason is the old generic text.
      cat > "$rep" <<'MUT173'
    escalations.push({ id: st.id, from: tierName(step.level, step.vendor), to: claudeTier, reason: `${step.vendor} unavailable — same level on Claude` }) // MUTATED: reason drops kind
MUT173
      mut_replace_block "$target" 'to: claudeTier, reason: `${what} — same level on Claude` })' 1 "$rep"
      ;;
    174)
      # triage-usage.sh: discover only immediate subagent transcripts.
      cat > "$rep" <<'MUT174'
done < <(find "$SUBDIR" -maxdepth 1 -name 'agent-*.jsonl' -type f | sort) # MUTATED: direct children only
MUT174
      mut_replace_block "$target" 'done < <(find "$SUBDIR" -name '\''agent-*.jsonl'\'' -type f | sort)' 1 "$rep"
      ;;
    175)
      # triage-usage.sh: classify a directory argument by a deep transcript search.
      cat > "$rep" <<'MUT175'
  elif [ "${ARG##*/}" = subagents ] || [ -n "$(find "$ARG" -name 'agent-*.jsonl' -type f -print -quit)" ]; then # MUTATED: deep dir classifier
MUT175
      mut_replace_block "$target" '  elif [ "${ARG##*/}" = subagents ] || ls "$ARG"/agent-*.jsonl >/dev/null 2>&1; then' 1 "$rep"
      ;;
    176)
      # ext-run.sh: the deprecated alias is no longer read.
      cat > "$rep" <<'MUT176'
: # MUTATED: AGY alias dropped
MUT176
      mut_replace_block "$target" '[ "${AGY_BOUNDARY_CLEARED:-}" = "1" ] && BOUNDARY_OK=1' 1 "$rep"
      ;;
    177)
      # ext-run.sh: the canonical name is no longer read.
      cat > "$rep" <<'MUT177'
: # MUTATED: CODEX name dropped
MUT177
      mut_replace_block "$target" '[ "${CODEX_BOUNDARY_CLEARED:-}" = "1" ] && BOUNDARY_OK=1' 1 "$rep"
      ;;
    179)
      # triage-context.sh: the one cap decision always says "fits".
      printf 'over_cap() { return 1; } # MUTATED: cap check removed\n' > "$rep"
      mut_replace_block "$target" 'over_cap() {' 1 "$rep"
      ;;
    180)
      printf ': # MUTATED: kill switch ignored\n' > "$rep"
      mut_replace_block "$target" '[ -e "$CLAUDE_DIR/triage.disabled" ] && exit 0' 1 "$rep"
      ;;
    181)
      printf ': # MUTATED: legacy guard removed\n' > "$rep"
      mut_replace_block "$target" 'if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && TRIAGE_DIR=' 3 "$rep"
      ;;
    182)
      printf '  | (if $add == "1" then .hooks.SessionStart = [$group] else . end) # MUTATED: SessionStart replaced\n' > "$rep"
      mut_replace_block "$target" '  | (if $add == "1" then .hooks.SessionStart = ((.hooks.SessionStart // []) + [$group]) else . end)' 1 "$rep"
      ;;
    183)
      printf '    | del(.hooks.SessionStart) # MUTATED: every SessionStart hook deleted\n' > "$rep"
      mut_replace_block "$target" '    | (if (.hooks.SessionStart | type) == "array" then' 1 "$rep"
      ;;
    184)
      printf '  if true; then # MUTATED: pointer guard dropped\n' > "$rep"
      mut_replace_block "$target" '  if [ "$POINTER" -eq 0 ]; then' 1 "$rep"
      ;;
    185)
      printf 'if false; then # MUTATED: agent_id ignored\n' > "$rep"
      mut_replace_block "$target" 'if [ -n "$INPUT" ] && printf' 1 "$rep"
      ;;
    187)
      printf '    : # MUTATED: hook status dropped\n' > "$rep"
      mut_replace_block "$target" '    echo "settings migration pending: triage hook missing' 1 "$rep"
      ;;
    188)
      printf '    : # MUTATED: legacy status dropped\n' > "$rep"
      mut_replace_block "$target" '    echo "settings migration pending: legacy @triage.md import present' 1 "$rep"
      ;;
    189)
      cat > "$rep" <<'MUT189'
triage_hook_command() { printf 'bash %q/%s' "$CLAUDE_DIR" "$TRIAGE_HOOK_SCRIPT"; } # MUTATED: CLAUDE_DIR not pinned
MUT189
      mut_replace_block "$target" 'triage_hook_command() {' 1 "$rep"
      ;;
    190)
      cat > "$rep" <<'MUT190'
    def owned: type == \"object\" and ((.command // null) | type == \"string\" and contains(\"/scripts/triage-context.sh\")); # MUTATED: substring ownership
"'
MUT190
      mut_replace_block "$target" '    def owned: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    191)
      cat > "$rep" <<'MUT191'
    def ours: type == \"object\" and ((.command // null) | type == \"string\" and contains(\"/scripts/triage-context.sh\")); # MUTATED: substring ownership
"'
MUT191
      mut_replace_block "$target" '    def ours: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    192)
      cat > "$rep" <<'MUT192'
TRIAGE_HOOK_OWNED_JQ='type == "object" and .command == $cmd' # MUTATED: predicate copy drifted
MUT192
      mut_replace_block "$target" 'TRIAGE_HOOK_OWNED_JQ=' 1 "$rep"
      ;;
    193)
      cat > "$rep" <<'MUT193'
    def covers: true; # MUTATED: matcher coverage ignored
MUT193
      mut_replace_block "$target" '    def covers: . == null' 2 "$rep"
      ;;
    194)
      printf '    0) HOOKS_OFF=0 ;; # MUTATED: disableAllHooks ignored\n' > "$rep"
      mut_replace_block "$target" '    0) HOOKS_OFF=1 ;;' 1 "$rep"
      ;;
    195)
      printf '    : # MUTATED: blocked status dropped\n' > "$rep"
      mut_replace_block "$target" '    echo "settings migration blocked:' 1 "$rep"
      ;;
    196)
      cat > "$rep" <<'MUT196'
  awk -v want="$2" '{ l = $0; if (l == want) found = 1 } END { exit found ? 0 : 1 }' "$1" # MUTATED: CR kept
MUT196
      mut_replace_block "$target" '  awk -v want="$2"' 1 "$rep"
      ;;
    197)
      printf '    || true # MUTATED: filter failure swallowed\n' > "$rep"
      mut_replace_block "$target" '    || die "could not filter $CLAUDE_MD (awk failed)' 1 "$rep"
      ;;
    198)
      printf '    *) echo "add" ;; # MUTATED: jq failure read as add\n' > "$rep"
      mut_replace_block "$target" '    *) return 1 ;;' 1 "$rep"
      ;;
    199)
      cat > "$rep" <<'MUT199'
if [ -f "$CLAUDE_DIR/settings.json" ] && command -v jq >/dev/null 2>&1; then # MUTATED: status needs settings.json
MUT199
      mut_replace_block "$target" 'if command -v jq >/dev/null 2>&1; then' 1 "$rep"
      ;;
    200)
      printf '    || true # MUTATED: filter failure swallowed\n' > "$rep"
      mut_replace_block "$target" '    || die "could not filter $CLAUDE_DIR/CLAUDE.md (awk failed)' 1 "$rep"
      ;;
    201)
      cat > "$rep" <<'MUT201'
LEGACY_IMPORT_AWK='function is_legacy(l) { sub(/[ \t]+$/, "", l); return l == "@triage.md" || l == "@./triage.md" || l == "@~/.claude/triage.md" || l == "@" ENVIRON["TRIAGE_DIR"] "/triage.md" }' # MUTATED: CR not stripped
MUT201
      mut_replace_block "$target" "LEGACY_IMPORT_AWK='function is_legacy(l) {" 1 "$rep"
      ;;
    202)
      cat > "$rep" <<'MUT202'
    def owned: type == \"object\" and .type == \"command\" and (.command | type == \"string\" and endswith(\"/scripts/triage-context.sh\")); # MUTATED: pin ignored
"'
MUT202
      mut_replace_block "$target" '    def owned: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    203)
      cat > "$rep" <<'MUT203'
    def ours: type == \"object\" and .type == \"command\" and (.command | type == \"string\" and endswith(\"/scripts/triage-context.sh\")); # MUTATED: pin ignored
"'
MUT203
      mut_replace_block "$target" '    def ours: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    204)
      cat > "$rep" <<'MUT204'
    def owned: type == \"object\" and .command == \$cmd; # MUTATED: type ignored
"'
MUT204
      mut_replace_block "$target" '    def owned: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    205)
      cat > "$rep" <<'MUT205'
    def ours: type == \"object\" and .command == \$cmd; # MUTATED: type ignored
"'
MUT205
      mut_replace_block "$target" '    def ours: $TRIAGE_HOOK_OWNED_JQ;' 1 "$rep"
      ;;
    206)
      cat > "$rep" <<'MUT206'
      or (type == "string" and ((["startup", "clear", "compact"] - split("|")) == [])); # MUTATED: resume not required
MUT206
      mut_replace_block "$target" '      or (type == "string" and ((($events | split("|")) - split("|")) == []));' 1 "$rep"
      ;;
    207)
      printf '  elif false; then # MUTATED: rubric gate skipped\n' > "$rep"
      mut_replace_block "$target" '  elif [ "$LEGACY" -eq 1 ] && ! rubric_fits "$1" "$2"; then' 1 "$rep"
      ;;
    208)
      printf 'claude_md_decision "$REPO_DIR/$TRIAGE_HOOK_SCRIPT" "$REPO_DIR/triage.md" # MUTATED: repo rubric checked\n' > "$rep"
      mut_replace_block "$target" 'claude_md_decision "$CLAUDE_DIR/$TRIAGE_HOOK_SCRIPT" "$CLAUDE_DIR/triage.md"' 1 "$rep"
      ;;
    209)
      # Two edits: the hook leaves the one merge, and comes back as a second write.
      printf '  | . # MUTATED: hook merged in a second write\n' > "$rep"
      mut_replace_block "$target" '  | (if $add == "1" then .hooks.SessionStart = ((.hooks.SessionStart // []) + [$group]) else . end)' 1 "$rep" || return 1
      cat > "$rep" <<'MUT209'
apply_settings "$tmp" || die "could not write $SETTINGS — CLAUDE.md was not changed."
if [ "$add_hook" -eq 1 ]; then
  tmp=$(mktemp)
  jq --argjson group "$hook_group" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$group])' "$SETTINGS" > "$tmp" || die "settings merge (jq) failed (hook)"
  apply_settings "$tmp" || die "could not write $SETTINGS."
fi
MUT209
      mut_replace_block "$target" 'apply_settings "$tmp" || die "could not write $SETTINGS — CLAUDE.md was not changed."' 1 "$rep"
      ;;
    210)
      printf '[ -f "$SETTINGS" ] || echo "{}" > "$SETTINGS"; SETTINGS_SRC="$SETTINGS" # MUTATED: settings.json created first\n' > "$rep"
      mut_replace_block "$target" 'SETTINGS_SRC="$SETTINGS"' 1 "$rep"
      ;;
    211)
      cat > "$rep" <<'MUT211'
    and ((.hooks.SessionStart // []) | type == "array") # MUTATED: false read as absent
    ' "$SETTINGS" >/dev/null 2>&1 \
MUT211
      mut_replace_block "$target" '    and (.hooks.SessionStart | shape("array"))' 1 "$rep"
      ;;
    212|213)
      cat > "$rep" <<'MUT212'
    END { if (NR > 0 && keep) printf "%s\n", prev }' "$1" # MUTATED: final newline added
MUT212
      mut_replace_block "$target" '    END { if (NR > 0 && keep) printf "%s%s", prev, (nl ? "\n" : "") }'"'"' "$1"' 1 "$rep"
      ;;
    214)
      cat > "$rep" <<'MUT214'
pointer_line() { printf '%s%s%s' "$POINTER_HEAD" "~/.claude" "$POINTER_TAIL"; } # MUTATED: pointer names ~/.claude
MUT214
      mut_replace_block "$target" 'pointer_line() {' 1 "$rep"
      ;;
    215)
      printf '    *$'"'"'\\n'"'"'*|*$'"'"'\\r'"'"'*) : ;; # MUTATED: line break accepted\n' > "$rep"
      mut_replace_block "$target" '    *$'"'"'\n'"'"'*|*$'"'"'\r'"'"'*) die "CLAUDE_DIR contains a line break' 1 "$rep"
      ;;
    178)
      # triage-deep-reasoner.md: the Agent deny leaves the frontmatter.
      cat > "$rep" <<'MUT178'
# MUTATED: Agent deny dropped
MUT178
      mut_replace_block "$target" 'disallowedTools: Agent' 1 "$rep"
      ;;
    110)
      # parity-report.sh COMMIT: a same-content re-ingest appends all its lines.
      cat > "$rep" <<'MUT110'
      | $new as $miss # MUTATED: dedupe dropped
MUT110
      mut_replace_block "$target" '      | [$new[] | select(okey as $k | any($have[]; . == $k) | not)] as $miss' 1 "$rep"
      ;;
    111)
      # parity-report.sh COMMIT: a run-id collision is skipped, not refused.
      cat > "$rep" <<'MUT111'
  else {action: "skip", lines: [], reason: "collision"} # MUTATED: collision skipped
MUT111
      mut_replace_block "$target" '  else {action: "refuse", lines: []' 1 "$rep"
      ;;
    112)
      # parity-report.sh utc: the offset is dropped.
      cat > "$rep" <<'MUT112'
      | 0 as $off # MUTATED: UTC offset ignored
MUT112
      mut_replace_block "$target" '      | (if $c.sg == null then 0 else' 1 "$rep"
      ;;
    113)
      # parity-report.sh lock_ledger: never waits for, nor takes, the lock dir.
      cat > "$rep" <<'MUT113'
  while false; do # MUTATED: lock not taken
MUT113
      mut_replace_block "$target" '  while ! mkdir "$lock" 2>/dev/null; do' 1 "$rep"
      ;;
    114)
      # parity-report.sh lock_ledger: a dead holder's lock is waited on like a live one.
      cat > "$rep" <<'MUT114'
    if false; then # MUTATED: stale lock never taken over
MUT114
      mut_replace_block "$target" '    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then' 1 "$rep"
      ;;
    115)
      # parity-report.sh backfill: the rename goes over the (symlink) path given.
      cat > "$rep" <<'MUT115'
    cp -p "$LEDGER" "$LEDGER.bf.$$" && cat "$TMP/new" > "$LEDGER.bf.$$" && mv "$LEDGER.bf.$$" "$LEDGER" || # MUTATED: symlink clobbered
MUT115
      mut_replace_block "$target" '    cp -p "$REAL_LEDGER" "$REAL_LEDGER.backfill.$$"' 1 "$rep"
      ;;
    116)
      # parity-report.sh decisions: every other group is a challenger again.
      cat > "$rep" <<'MUT116'
    | . # MUTATED: superseded versions are challengers
MUT116
      mut_replace_block "$target" '    | select(. as $g | any($current[]; .vendor == $g.vendor and .modelId == $g.modelId))' 1 "$rep"
      ;;
    117)
      # parity-report.sh decisions: tuning.rejected never turns a propose into rejected.
      cat > "$rep" <<'MUT117'
    | if false # MUTATED: tuning.rejected ignored
MUT117
      mut_replace_block "$target" '    | if .verdict == "propose" and $r != null' 1 "$rep"
      ;;
    118)
      # parity-report.sh rows: every graded row is its own outcome.
      cat > "$rep" <<'MUT118'
      unit: "line:\($li)|\(.label)"} # MUTATED: reps counted as independent
MUT118
      mut_replace_block "$target" '      unit: (if $l.run == null' 3 "$rep"
      ;;
    119)
      # parity-cost.sh: fromjson without ?, so a corrupt line is an error, not a skip.
      cat > "$rep" <<'MUT119'
    'select(test("\\S")) | [fromjson] as $o # MUTATED: corrupt line not skipped
MUT119
      mut_replace_block "$target" "    'select(test(\"\\\\S\")) | [fromjson?] as \$o" 1 "$rep"
      ;;
    120)
      # parity-report.sh reviews: all revisions of a run count.
      cat > "$rep" <<'MUT120'
| $rvAll as $rv # MUTATED: every revision counted
MUT120
      mut_replace_block "$target" '| ([$rvi[] | select(.run == null)]' 1 "$rep"
      ;;
    121)
      # parity-report.sh ingest-review: superseded collapses into unavailable.
      cat > "$rep" <<'MUT121'
           status: (if $r.status == "ok" then "ok" else "unavailable" end), # MUTATED: superseded recorded as unavailable
MUT121
      mut_replace_block "$target" '           status: (if $r.status == "ok" or $r.status == "superseded"' 1 "$rep"
      ;;
    122)
      # parity-report.sh COMMIT: the review revision branch never fires.
      cat > "$rep" <<'MUT122'
  elif false then # MUTATED: no review revisions
MUT122
      mut_replace_block "$target" '  elif $mode == "review" and $revisable then' 1 "$rep"
      ;;
    123)
      # parity-report.sh ingest-parity: modelFrom is not forwarded to cand().
      cat > "$rep" <<'MUT123'
        model: ($row.model // $rk.model), modelFrom: null, # MUTATED: ingest-parity modelFrom dropped
MUT123
      mut_replace_block "$target" '        model: ($row.model // $rk.model), modelFrom: (if $row.model' 1 "$rep"
      ;;
    124)
      # triage-parity.js buildTask: rows carry no modelFrom.
      cat > "$rep" <<'MUT124'
      modelFrom: null }) // MUTATED: row modelFrom dropped
MUT124
      mut_replace_block "$target" "      modelFrom: g.model ? (g.modelFrom || null) : (x.c.model ? 'candidate' : null) })" 1 "$rep"
      ;;
    125)
      # parity-suite.sh ignored_tree: only the count is hashed.
      cat > "$rep" <<'MUT125'
  lines=$("$SCRIPT_DIR/stage-worktree.sh" ignored --repo "$top" | wc -l) || return 1 # MUTATED: ignored files not stat-ed
MUT125
      mut_replace_block "$target" '  lines=$("$SCRIPT_DIR/stage-worktree.sh" ignored --repo "$top") || return 1' 1 "$rep"
      ;;
    126)
      # parity-suite.sh refs_tree: branches, tags and the stash are not listed.
      cat > "$rep" <<'MUT126'
  { : # MUTATED: refs not hashed
MUT126
      mut_replace_block "$target" '  { git -C "$top" --no-optional-locks for-each-ref' 1 "$rep"
      ;;
    127)
      # triage-parity.js sourceGuard: ignored/refs differences are not named (nor acted on).
      cat > "$rep" <<'MUT127'
    null].filter(Boolean).join(', ') : null // MUTATED: ignored/refs not compared
MUT127
      mut_replace_block "$target" "    after.ignored !== before.ignored ? 'ignored files changed'" 1 "$rep"
      ;;
    128)
      # triage-tiers.sh --bakeoff-json: ALIAS_ERRORS is not evaluated.
      cat > "$rep" <<'MUT128'
  ERRS=$(jq -r "$TUNING_ERRORS" "$TIERS") || { # MUTATED: aliasHistory not validated
MUT128
      mut_replace_block "$target" '  ERRS=$(jq -r "$TUNING_ERRORS, ($ALIAS_ERRORS)" "$TIERS") || {' 1 "$rep"
      ;;
    129)
      # triage-tiers.sh TUNING_ERRORS: the shares may sum to anything.
      cat > "$rep" <<'MUT129'
           | empty) # MUTATED: mix-sum check dropped
MUT129
      mut_replace_block "$target" '           | if ($sum - 1 | fabs) < 1e-9 then empty' 1 "$rep"
      ;;
    91)
      # triage-exec.js (H8): an empty diff counts as the passing choice again.
      cat > "$rep" <<'MUT91'
const realDiff = c => c.outOfScope !== true // MUTATED: empty diff counts
MUT91
      mut_replace_block "$target" 'const realDiff = c => isStr(c.diffstat) && c.outOfScope !== true' 1 "$rep"
      ;;
    92)
      # triage-exec.js (M10): an out-of-scope patch is inline-applied.
      cat > "$rep" <<'MUT92'
const realDiff = c => isStr(c.diffstat) // MUTATED: out-of-scope patch applied
MUT92
      mut_replace_block "$target" 'const realDiff = c => isStr(c.diffstat) && c.outOfScope !== true' 1 "$rep"
      ;;
    93)
      # triage-exec.js (M5): an unconfirmed leak state no longer stops the plan.
      cat > "$rep" <<'MUT93'
    : null // MUTATED: unknown leak runs in place
MUT93
      mut_replace_block "$target" "    : res.leak !== false ? 'leak state unknown" 1 "$rep"
      ;;
    94)
      # triage-exec.js (M2): bakeoff.repo is never compared with the session repo.
      cat > "$rep" <<'MUT94'
  if (false) { // MUTATED: repo mismatch ignored
MUT94
      mut_replace_block "$target" '  if (!isStr(dirty.sessionTop) || !isStr(dirty.repoTop) || stripSlash(dirty.sessionTop) !== stripSlash(dirty.repoTop)) {' 1 "$rep"
      ;;
    95)
      # triage-exec.js (M4): any failed apply counts as "nothing written" → in place.
      cat > "$rep" <<'MUT95'
    const untouched = !!ap // MUTATED: failed apply runs in place
MUT95
      mut_replace_block "$target" '    const untouched = !!ap && ap.applied === false && ap.treeModified === false && [0, 1, 6].includes(ap.rc)' 1 "$rep"
      ;;
    96)
      # triage-exec.js (M6): an ESCALATE level climb carries the lower rung's plan effort.
      cat > "$rep" <<'MUT96'
  return { level: up, vendor, effort: r.subtask.effort, reason: 'reviewer returned ESCALATE' } // MUTATED: climb keeps plan effort
MUT96
      mut_replace_block "$target" "  return { level: up, vendor, effort: up === r.level ? r.subtask.effort : null, reason: 'reviewer returned ESCALATE' }" 1 "$rep"
      ;;
    97)
      # triage-exec.js (codex#12): a rejected external spawn escapes the Claude fallback.
      cat > "$rep" <<'MUT97'
      throw e // MUTATED: external rejection escapes the fallback
MUT97
      mut_replace_block "$target" '      if (budgeted && budget.remaining() <= 0) throw e' 1 "$rep"
      ;;
    98)
      # triage-exec.js: a missing weeklyPct no longer pauses sampling.
      cat > "$rep" <<'MUT98'
const bakeoffPaused = !!bo && bo.weeklyPct != null && bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct // MUTATED: unknown weekly samples
MUT98
      mut_replace_block "$target" 'const bakeoffPaused = !!bo && (weeklyUnknown || bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct)' 1 "$rep"
      ;;
    99)
      # triage-exec.js: the danger floor by model family is not applied to challengers.
      cat > "$rep" <<'MUT99'
      true) // MUTATED: danger family floor dropped
MUT99
      mut_replace_block "$target" '      !(st.danger && !meetsDangerFloor(v, c.model)))' 1 "$rep"
      ;;
    100)
      # triage-compare.js (codex#10): checks joined with a bare ' && ' again.
      cat > "$rep" <<'MUT100'
const checkCmd = checks.join(' && ') // MUTATED: checks joined unguarded
MUT100
      mut_replace_block "$target" "const checkCmd = checks.length === 1 ? checks[0] : checks.map(c => \`bash -c \${shq(c)}\`).join(' && ')" 1 "$rep"
      ;;
    101)
      # triage-compare.js (H5): a PATCHCHECK line from another sha is accepted.
      cat > "$rep" <<'MUT101'
  : false ? '' // MUTATED: PATCHCHECK sha not cross-checked
MUT101
      mut_replace_block "$target" '  : pcLine.base !== sha ? `PATCHCHECK graded at' 1 "$rep"
      ;;
    102)
      # triage-compare.js (M12): what ext-run ran is never compared with what was asked.
      cat > "$rep" <<'MUT102'
    const mismatch = null // MUTATED: model/effort mismatch ignored
MUT102
      mut_replace_block "$target" '    const mismatch = !nothing && ((c.model && ranModel && ranModel !== c.model)' 2 "$rep"
      ;;
    103)
      # triage-compare.js (M13): an extension ignores the prior snapshot's scope.
      cat > "$rep" <<'MUT103'
    if (false) { // MUTATED: extend scope unchecked
MUT103
      mut_replace_block "$target" '    if (c.scopeOk !== true) {' 1 "$rep"
      ;;
    104)
      # ext-run.sh (H7): the build worktree is not locked (a parallel prune removes it).
      cat > "$rep" <<'MUT104'
  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --detach "$STAGE/build" HEAD >"$STAGE/meta/worktree.log" 2>&1; then # MUTATED: build worktree unlocked
MUT104
      mut_replace_block "$target" '  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --lock --reason "ext-run $$" --detach "$STAGE/build" HEAD' 1 "$rep"
      ;;
    105)
      # review-stage.sh (H6): no **/ variants — **/x misses a top-level x, a/**/b misses a/b.
      cat > "$rep" <<'MUT105'
    : # MUTATED: no glob variants
MUT105
      mut_replace_block "$target" "    case \"\$v\" in '**/'?*)" 2 "$rep"
      ;;
    106)
      # review-stage.sh (M14): no ext-run.sh to ask → codex allowed (fail open).
      cat > "$rep" <<'MUT106'
  [ -x "$EXT_RUN" ] || return 1 # MUTATED: missing ext-run allows codex
MUT106
      mut_replace_block "$target" '  [ -x "$EXT_RUN" ] || {' 1 "$rep"
      ;;
    107)
      # stage-worktree.sh (M3): apply --require-clean is ignored.
      cat > "$rep" <<'MUT107'
  if false; then # MUTATED: require-clean ignored
MUT107
      mut_replace_block "$target" '  if [ "$REQUIRE_CLEAN" -eq 1 ]; then' 1 "$rep"
      ;;
    108)
      # stage-worktree.sh (M4): a failed write is assumed to have left the tree untouched.
      cat > "$rep" <<'MUT108'
  modified() { echo false; } # MUTATED: failed write assumed untouched
MUT108
      mut_replace_block "$target" '  modified() { paths_state' 1 "$rep"
      ;;
    109)
      # stage-worktree.sh (H4): ignored paths are left out of the leak fingerprint.
      cat > "$rep" <<'MUT109'
  : > "$out.ign" # MUTATED: ignored paths not fingerprinted
MUT109
      mut_replace_block "$target" '  ignored_snapshot "$r" "$out.ign" || return 1' 1 "$rep"
      ;;
    222)
      # triage-exec.js: a plan check with no CHECKRC line reads as exit 0 (a dead gate passes)
      cat > "$rep" <<'MUT222'
  return hits.length ? Number(hits[hits.length - 1][1]) : 0 // MUTATED: a missing CHECKRC reads as exit 0
MUT222
      mut_replace_block "$target" '  return hits.length ? Number(hits[hits.length - 1][1]) : null' 1 "$rep"
      ;;
    223)
      # triage-exec.js: the FIRST CHECKRC line decides, so check output can spoof the exit status
      cat > "$rep" <<'MUT223'
  return hits.length ? Number(hits[0][1]) : null // MUTATED: the first CHECKRC line decides
MUT223
      mut_replace_block "$target" '  return hits.length ? Number(hits[hits.length - 1][1]) : null' 1 "$rep"
      ;;
    224)
      # triage-exec.js: a reviewer reply with no PASS/FIX/ESCALATE first line reads as PASS
      cat > "$rep" <<'MUT224'
  const m = String(text == null ? '' : text).trimStart().match(/^\**\s*(PASS|FIX|ESCALATE)\b/i) || ['', 'PASS'] // MUTATED: no verdict reads as PASS
MUT224
      mut_replace_block "$target" '  const m = String(text == null ? '\'''\'' : text).trimStart().match(' 1 "$rep"
      ;;
    225)
      # triage-exec.js: runGate treats any non-null reply as a live gate (a malformed check/review reply is not retried)
      cat > "$rep" <<'MUT225'
    const live = o => o != null // MUTATED: any reply is a live gate
MUT225
      mut_replace_block "$target" '    const live = o => o != null && usable(o)' 1 "$rep"
      ;;
    226)
      # triage-exec.js: args.repo is not compared with args.bakeoff.repo
      cat > "$rep" <<'MUT226'
  // MUTATED: args.repo vs args.bakeoff.repo not compared
MUT226
      mut_replace_block "$target" '  if (b.repo != null && planRepo && stripSlash(b.repo) !== planRepo) bad(' 1 "$rep"
      ;;
    227)
      # triage-exec.js: plan checks do not cd into args.repo
      cat > "$rep" <<'MUT227'
const checkCommand = cmd => `out=$( { { ${cmd.replace(/[\s;]+$/, '')} ; } ; } 2>&1 ); rc=$?; ` + // MUTATED: checks ignore args.repo
MUT227
      mut_replace_block "$target" 'const checkCommand = cmd => `out=$( { ${planRepo ? ' 1 "$rep"
      ;;
    228)
      # triage-exec.js: the external brief header drops WORKDIR=<args.repo>
      cat > "$rep" <<'MUT228'
  '' // MUTATED: WORKDIR dropped
MUT228
      mut_replace_block "$target" '  (planRepo ? ` WORKDIR=${planRepo}` : '\'''\'')' 1 "$rep"
      ;;
    229)
      # triage-exec.js: classifyBuild ignores a non-zero ext-run exit (a failed build reads as work)
      cat > "$rep" <<'MUT229'
  if (false) { // MUTATED: a non-zero exit counts as work
MUT229
      mut_replace_block "$target" '  if (exit !== '\''0'\'') {' 1 "$rep"
      ;;
    230)
      # triage-exec.js: classifyBuild reads CHANGED FILES: none as work
      cat > "$rep" <<'MUT230'
  // MUTATED: CHANGED FILES: none counts as work
MUT230
      mut_replace_block "$target" '  if (changed && /^CHANGED FILES:\s*none\s*$/i.test(changed)) return' 1 "$rep"
      ;;
    231)
      # triage-exec.js: an unconfirmed leak state stops only its own subtask, not the plan
      cat > "$rep" <<'MUT231'
    withheld.add(st.id); return { withheld: true } // MUTATED: an unknown leak stops only this subtask
MUT231
      mut_replace_block "$target" '    return { abort: unknown }' 1 "$rep"
      ;;
    232)
      # triage-exec.js: cross-review findings need no CROSS-REVIEW header (any reply is findings)
      cat > "$rep" <<'MUT232'
    if (outs[i] != null) findings[v] = String(outs[i]).slice(0, 4000) // MUTATED: no header needed
MUT232
      mut_replace_block "$target" '    if (cls.work) findings[v] = String(outs[i]).slice(0, 4000)' 1 "$rep"
      ;;
    233)
      # triage-exec.js: parseCleanCheck no longer validates rc / the clock
      cat > "$rep" <<'MUT233'
  if (rc == null) return null // MUTATED: rc/now not validated
MUT233
      mut_replace_block "$target" '  if (rc == null || !/^\d{1,3}$/.test(rc) || now == null || !ISO_UTC.test(now)) return null' 1 "$rep"
      ;;
    234)
      # triage-exec.js: parseCleanCheck does not require the end marker (a truncated reply parses)
      cat > "$rep" <<'MUT234'
  if (!tags.length) return null // MUTATED: end tag not required
MUT234
      mut_replace_block "$target" '  if (only('\''end'\'') !== '\'''\'' || tags[tags.length - 1].k !== '\''end'\'') return null' 1 "$rep"
      ;;
    235)
      # triage-exec.js: a failed clean check is not retried
      cat > "$rep" <<'MUT235'
  if (false) { // MUTATED: clean check not retried
MUT235
      mut_replace_block "$target" '  if (!dirty) {' 1 "$rep"
      ;;
    236)
      # triage-exec.js: round 1 re-verifies even when nothing was re-run
      cat > "$rep" <<'MUT236'
  verification = await verify(r1.merged, true) // MUTATED: re-verify with nothing re-run
MUT236
      mut_replace_block "$target" '  if (r1.redoResults.length) verification = await verify(r1.merged, true)' 1 "$rep"
      ;;
    237)
      # triage-exec.js: Fable-family models are allowed as bake-off challengers
      cat > "$rep" <<'MUT237'
      // MUTATED: Fable challengers allowed
MUT237
      mut_replace_block "$target" '      !isFableModel(c.model) &&' 1 "$rep"
      ;;
    238)
      # triage-exec.js: a Fable-family planned model is sampled for a bake-off
      cat > "$rep" <<'MUT238'
  // MUTATED: a Fable-family planned model is sampled
MUT238
      mut_replace_block "$target" '  if (isFableModel(planned.model)) return { skip: '\''planned-fable'\'' }' 1 "$rep"
      ;;
    239)
      # triage-exec.js: ledgerRun joins the hashed long run id with '~' (outside parity-report's token set)
      cat > "$rep" <<'MUT239'
  return `${baseName.slice(0, RUN_MAX - idPart.length - 10)}~${hex8(baseName)}:${idPart}` // MUTATED: ~ separator
MUT239
      mut_replace_block "$target" '  return `${baseName.slice(0, RUN_MAX - idPart.length - 10)}.${hex8(baseName)}:${idPart}`' 1 "$rep"
      ;;
    240)
      # triage-exec.js: ledgerRun never shortens a long subtask id (the run id overflows the 80-char token)
      cat > "$rep" <<'MUT240'
  const idPart = id // MUTATED: a long id is never shortened
MUT240
      mut_replace_block "$target" '  const idPart = id.length <= 40 ? id :' 1 "$rep"
      ;;
    241)
      # triage-exec.js: normFile accepts absolute / .. / repo-root files under a bake-off
      cat > "$rep" <<'MUT241'
  if (false) { // MUTATED: non-relative files accepted
MUT241
      mut_replace_block "$target" '  if (bakeoffOn && (s === '\'''\'' || s.startsWith('\''/'\'') || s.split('\''/'\'').includes('\''..'\''))) {' 1 "$rep"
      ;;
    242)
      # triage-exec.js: normFile keeps an absolute path under the repo (not made repo-relative)
      cat > "$rep" <<'MUT242'
  // MUTATED: absolute paths kept
MUT242
      mut_replace_block "$target" '  if (fileRepo && s.startsWith(`${fileRepo}/`)) s = s.slice(fileRepo.length + 1)' 1 "$rep"
      ;;
    243)
      # triage-exec.js: ingestStatus books a pass with no real in-scope diff as a pass
      cat > "$rep" <<'MUT243'
const ingestStatus = c => c.status // MUTATED: a no-op pass is ingested as a pass
MUT243
      mut_replace_block "$target" 'const ingestStatus = c =>' 1 "$rep"
      ;;
    244)
      # triage-exec.js: the ingest result carries no run-time ts
      cat > "$rep" <<'MUT244'
      result: { base: res.base, sha: res.sha, leak: res.leak, baseMoved: res.baseMoved, graded: res.graded, // MUTATED: no run-time ts
MUT244
      mut_replace_block "$target" '      result: { ts: dirty.now, base: res.base,' 1 "$rep"
      ;;
    245)
      # triage-exec.js: a null candidate model is left for ingest-time resolution (never filled from the tiers config)
      cat > "$rep" <<'MUT245'
          const fill = false // MUTATED: null models left for ingest-time resolution
MUT245
      mut_replace_block "$target" '          const fill = c.model == null && isStr(r.model)' 1 "$rep"
      ;;
    246)
      # triage-compare.js: an external build reply is judged by the first-line rule (a preamble before REFUSED/EXTERNAL passes as work)
      cat > "$rep" <<'MUT246'
    const nothing = err != null || producedNothing(out) // MUTATED: external reply read by the first-line rule
MUT246
      mut_replace_block "$target" '    const nothing = err != null || (external ? !cls.work : producedNothing(out))' 1 "$rep"
      ;;
    247)
      # triage-compare.js: an external candidate with no ext-run accounting line is not marked invalid
      cat > "$rep" <<'MUT247'
    const unverified = false && external && !nothing && !ext // MUTATED: missing ext-run line not checked
MUT247
      mut_replace_block "$target" '    const unverified = external && !nothing && !ext' 1 "$rep"
      ;;
    248)
      # triage-compare.js: a passing candidate with an empty diff is credited
      cat > "$rep" <<'MUT248'
  if (false && status === 'pass' && !isStr(pc.diffstat)) return Object.assign(base, { status: 'invalid', rc: pc.rc, tail: `EMPTY DIFF — the checks passed with no change: nothing to credit ${tail || ''}`.trim() }) // MUTATED: empty-diff pass credited
MUT248
      mut_replace_block "$target" '  if (status === '\''pass'\'' && !isStr(pc.diffstat))' 1 "$rep"
      ;;
    249)
      # triage-compare.js: a passing candidate that changed paths outside the brief's files is credited
      cat > "$rep" <<'MUT249'
  if (false && status === 'pass' && outOfScope === true) return Object.assign(base, { status: 'invalid', rc: pc.rc, tail: `OUT OF SCOPE — the checks passed, but the patch changes paths outside the brief's files ${tail || ''}`.trim() }) // MUTATED: out-of-scope pass credited
MUT249
      mut_replace_block "$target" '  if (status === '\''pass'\'' && outOfScope === true)' 1 "$rep"
      ;;
    250)
      # triage-compare.js: a reviewer reply with no work is not reported unavailable (a refusal is parsed as findings)
      cat > "$rep" <<'MUT250'
    if (cls.kind === 'refused' && false) return done('unavailable', { reason: noWorkReason(cls) }) // MUTATED: no-work reviewer reply not unavailable
MUT250
      mut_replace_block "$target" '    if (!cls.work) return done('\''unavailable'\'', { reason: noWorkReason(cls) })' 1 "$rep"
      ;;
    251)
      # triage-compare.js: an adjudicator reply is parsed without the CROSS-REVIEW header check
      cat > "$rep" <<'MUT251'
        const obj = j.vendor === 'claude' ? out : parseJsonObject(out) // MUTATED: adjudicator reply not classified
MUT251
      mut_replace_block "$target" '(classifyCrossReview(out).work ? parseJsonObject(out) : null)' 1 "$rep"
      ;;
    252)
      # triage-compare.js: scopePath keeps an absolute path under the repo (brief/changed path spellings diverge)
      cat > "$rep" <<'MUT252'
  // MUTATED: repo prefix not stripped
MUT252
      mut_replace_block "$target" '  if (s.startsWith(`${repoC}/`)) s = s.slice(repoC.length + 1)' 1 "$rep"
      ;;
    253)
      # triage-compare.js: scopePath keeps '.' path components
      cat > "$rep" <<'MUT253'
  return s.split('/').filter(x => x !== '').join('/') // MUTATED: dot components kept
MUT253
      mut_replace_block "$target" '  return s.split('\''/'\'').filter(x => x !== '\'''\'' && x !== '\''.'\'').join('\''/'\'')' 1 "$rep"
      ;;
    254)
      # triage-compare.js: args.files are not normalised at entry (a <repo>/x file reaches the briefs as the real repo path)
      cat > "$rep" <<'MUT254'
const files = (args.files || []).map(f => f.trim()) // MUTATED: args.files not normalised
MUT254
      mut_replace_block "$target" 'const files = (args.files || []).map(f => scopePath(f) || '\''.'\'')' 1 "$rep"
      ;;
    255)
      # triage-compare.js: classifyCrossReview lets a stray EXTERNAL ( line in a cross-review reply count as work
      cat > "$rep" <<'MUT255'
    return line.startsWith(CROSS_HEADER) ? `EXTERNAL (${line.slice(CROSS_HEADER.length)}` : raw // MUTATED: stray EXTERNAL ( line counts
MUT255
      mut_replace_block "$target" '    return line.startsWith(CROSS_HEADER) ?' 1 "$rep"
      ;;
    256)
      # triage-compare.js: classifyExternal counts any non-blank line as work (the verdict header is not required)
      cat > "$rep" <<'MUT256'
    if (line.trim()) return { work: true, kind: 'work', reason: '' } // MUTATED: any line counts as work
MUT256
      mut_replace_block "$target" '    if (line.startsWith('\''EXTERNAL ('\'')) return { work: true, kind: '\''work'\'', reason: '\'''\'' }' 1 "$rep"
      ;;
    257)
      # triage-parity.js: a codex judge reply is scored without the CROSS-REVIEW header check
      cat > "$rep" <<'MUT257'
    else if (o != null) { // MUTATED: judge reply not classified
MUT257
      mut_replace_block "$target" '    else if (classifyCrossReview(o).work) {' 1 "$rep"
      ;;
    258)
      # triage-parity.js: an external review reply with no work is not reported unavailable
      cat > "$rep" <<'MUT258'
    if (cls.kind === 'refused' && false) { rows.push(row(c, c.label, 'unavailable', { reason: noWorkReason(cls) })); return } // MUTATED: no-work review row not unavailable
MUT258
      mut_replace_block "$target" '    if (!cls.work) { rows.push(row(c, c.label, '\''unavailable'\'', { reason: noWorkReason(cls) })); return }' 1 "$rep"
      ;;
    259)
      # triage-parity.js: classifyExternal counts any non-blank line as work (the verdict header is not required)
      cat > "$rep" <<'MUT259'
    if (line.trim()) return { work: true, kind: 'work', reason: '' } // MUTATED: any line counts as work
MUT259
      mut_replace_block "$target" '    if (line.startsWith('\''EXTERNAL ('\'')) return { work: true, kind: '\''work'\'', reason: '\'''\'' }' 1 "$rep"
      ;;
    260)
      # triage-parity.js: its classifyExternal copy drifts from triage-exec.js (REFUSED: token changed; lint 6e pin)
      cat > "$rep" <<'MUT260'
    if (line.startsWith('REFUSED')) return { work: false, kind: 'refused', reason: cut(line.slice('REFUSED:'.length)) || '(no reason given)' } // MUTATED: classifyExternal copy drifted
MUT260
      mut_replace_block "$target" '    if (line.startsWith('\''REFUSED:'\'')) return {' 1 "$rep"
      ;;
    261)
      # parity-report.sh: a refused id token no longer names the offending characters
      cat > "$rep" <<'MUT261'
  if false; then : # MUTATED: refusal does not name the bad characters
MUT261
      mut_replace_block "$target" '  if [ -n "$bad" ]; then echo "'\''$v'\'' contains character(s)' 1 "$rep"
      ;;
    262)
      # parity-report.sh: a result's own ts is ignored at ingest
      cat > "$rep" <<'MUT262'
    TS=$(now_ts); TS_SRC=result # MUTATED: result ts ignored
MUT262
      mut_replace_block "$target" '    TS="$own"; TS_SRC=result' 1 "$rep"
      ;;
    263)
      # parity-report.sh: a model filled from today's tiers file at ingest is ledgered as pinned
      cat > "$rep" <<'MUT263'
def at_ingest($filled): .; # MUTATED: tiers-filled model not flagged
MUT263
      mut_replace_block "$target" 'def at_ingest($filled): if $filled' 1 "$rep"
      ;;
    264)
      # parity-report.sh: stale-lock takeover skips the same-lock re-check (a live lock can be taken over)
      cat > "$rep" <<'MUT264'
  if true; then # MUTATED: takeover skips the same-lock re-check
MUT264
      mut_replace_block "$target" '  if [ -n "$ino" ] && [ "$(lock_ino "$lock")" = "$ino" ] && [ "$got" = "$want" ]; then' 1 "$rep"
      ;;
    265)
      # parity-report.sh: stale-lock takeover ignores the takeover mutex (two takers can race)
      cat > "$rep" <<'MUT265'
  if false; then # MUTATED: takeover mutex ignored
MUT265
      mut_replace_block "$target" '  if ! mkdir "$m" 2>/dev/null; then' 1 "$rep"
      ;;
    266)
      # parity-report.sh: an orphaned takeover mutex is never cleared
      cat > "$rep" <<'MUT266'
    : # MUTATED: orphaned mutex never cleared
MUT266
      mut_replace_block "$target" '    if [ "$TAKEOVER_WAIT" -ge 50 ]; then rmdir "$m" 2>/dev/null; TAKEOVER_WAIT=0; fi' 1 "$rep"
      ;;
    267)
      # parity-report.sh: an ingest-time ts is not flagged inferred-at-ingest
      cat > "$rep" <<'MUT267'
    TS=$(now_ts); TS_SRC=result # MUTATED: ingest-time ts not flagged
MUT267
      mut_replace_block "$target" '    TS=$(now_ts); TS_SRC=inferred-at-ingest' 1 "$rep"
      ;;
    268)
      # parity-report.sh: rates counts configs no inline bake-off can reach as gaps
      cat > "$rep" <<'MUT268'
                 | . # MUTATED: unreachable configs are gaps again
MUT268
      mut_replace_block "$target" '                 | select(($reach | index([{vendor: $V, modelId: $c.modelId, effort: $c.effort}])) != null)' 1 "$rep"
      ;;
    269)
      # parity-report.sh: rates never reports the unsampleable state (a level with nothing reachable stays in explore)
      cat > "$rep" <<'MUT269'
        | if false # MUTATED: unsampleable level stays in explore
MUT269
      mut_replace_block "$target" '        | if ($reach | length) == 0' 1 "$rep"
      ;;
    270)
      # triage-stats.sh: a workflow agent's transcript is attributed to the wrong session
      cat > "$rep" <<'MUT270'
  sess="$(basename "$(dirname "$(dirname "$f")")")" # MUTATED: workflow agents lumped
MUT270
      mut_replace_block "$target" '  sess="${f%/subagents/*}"; sess="${sess##*/}"' 1 "$rep"
      ;;
    271)
      # triage-usage.sh: repeated message ids are summed instead of counted once
      cat > "$rep" <<'MUT271'
      | sort_by(.i) # MUTATED: repeated message ids summed
MUT271
      mut_replace_block "$target" '      | group_by(.k) | map(max_by(.i)) | sort_by(.i)' 1 "$rep"
      ;;
    272)
      # triage-usage.sh: a corrupt transcript line ends the file (later records dropped)
      cat > "$rep" <<'MUT272'
       catch "CORRUPT") end' "$f" 2>/dev/null | sed '/^"CORRUPT"$/,$d')" # MUTATED: a corrupt line ends the file
MUT272
      mut_replace_block "$target" '       catch "CORRUPT") end'\'' "$f" 2>/dev/null)"' 1 "$rep"
      ;;
    273)
      # parity-report.sh: id_tokens drops '@' from its family split (lint 6d vs triage-exec modelTokens)
      cat > "$rep" <<'MUT273'
def id_tokens: ascii_downcase | [splits("[-._:+]")]; # MUTATED: family split drifts from modelTokens
MUT273
      mut_replace_block "$target" 'def id_tokens: ascii_downcase | [splits("[-._:+@]")];' 1 "$rep"
      ;;
    274)
      # triage-exec.js: modelTokens drops '@' from its split (lint 6c/6d family-split)
      cat > "$rep" <<'MUT274'
const modelTokens = m => String(m || '').toLowerCase().split(/[-._:+]/).filter(Boolean) // MUTATED: split drifts from parity-report
MUT274
      mut_replace_block "$target" 'const modelTokens = m => String(m || '\'''\'').toLowerCase().split(/[-._:+@]/).filter(Boolean)' 1 "$rep"
      ;;
    275)
      # triage.md: names a model id in prose (lint check 7, model ids live in config/tiers.json)
      cat > "$rep" <<'MUT275'
## Tiers: level × vendor × role
- MUTATED: danger work runs on gpt-6-astra
MUT275
      mut_replace_block "$target" '## Tiers: level × vendor × role' 1 "$rep"
      ;;
    276)
      # ext-run.sh: a hard-coded model id (lint check 7)
      cat > "$rep" <<'MUT276'
#!/bin/bash
HARDCODED_MODEL=gpt-6-sol # MUTATED: hard-coded model id
MUT276
      mut_replace_block "$target" '#!/bin/bash' 1 "$rep"
      ;;
    277)
      # stage-worktree.sh: apply --require-clean omits rename/copy SOURCE paths from the patch headers
      cat > "$rep" <<'MUT277'
      1;' "$2" || exit 1 # MUTATED: rename sources not listed
MUT277
      mut_replace_block "$target" '      if ($hd && /^(?:rename|copy) from' 1 "$rep"
      ;;
    278)
      # stage-worktree.sh: apply --require-clean reads a failed git status as clean
      cat > "$rep" <<'MUT278'
    if ! { tr '\n' '\000' < "$tmp/paths" | xargs -0 git -C "$R" --literal-pathspecs --no-optional-locks status --porcelain=v1 -uall -- > "$tmp/dirty" 2>"$tmp/dirty.err" || true; }; then # MUTATED: failed status read as clean
MUT278
      mut_replace_block "$target" '    if ! tr '\''\n'\'' '\''\000'\'' < "$tmp/paths" | xargs -0 git -C "$R" --literal-pathspecs --no-optional-locks status' 1 "$rep"
      ;;
    279)
      # stage-worktree.sh: apply ignores a failed path listing (paths_ok stays 1)
      cat > "$rep" <<'MUT279'
  patch_paths "$R" "$PATCH" "$tmp/paths" || true # MUTATED: listing failure ignored
MUT279
      mut_replace_block "$target" '  patch_paths "$R" "$PATCH" "$tmp/paths" || paths_ok=0' 1 "$rep"
      ;;
    280)
      # stage-worktree.sh: a failed write over unlistable paths is measured as unmodified
      cat > "$rep" <<'MUT280'
  modified() { paths_state "$R" "$tmp/paths" "$tmp/after"; if cmp -s "$tmp/before" "$tmp/after"; then echo false; else echo true; fi; } # MUTATED: unknown paths measured as clean
MUT280
      mut_replace_block "$target" '  modified() { paths_state' 1 "$rep"
      ;;
    281)
      # stage-worktree.sh: the ignored-file fingerprint uses whole-second mtimes (a same-second rewrite goes unseen)
      cat > "$rep" <<'MUT281'
      my $hires = 0; # MUTATED: whole-second mtimes
MUT281
      mut_replace_block "$target" '      my $hires = eval' 1 "$rep"
      ;;
    282)
      # stage-worktree.sh: the ignored-file list stops excluding .DS_Store
      cat > "$rep" <<'MUT282'
      my @p = grep { !m{^\.claude/} && !m{(^|/)PROJECT_MEMORY[^/]*\.md$} } # MUTATED: .DS_Store not excluded
MUT282
      mut_replace_block "$target" '      my @p = grep { !m{^\.claude/}' 1 "$rep"
      ;;
    283)
      # stage-worktree.sh: apply with a non-repo --repo falls back to the cwd's repo
      cat > "$rep" <<'MUT283'
  local R log chk3 tmp dirty paths_ok
  R=$(repo_top "$REPO") # MUTATED: a non-repo --repo falls back to the cwd
MUT283
      mut_replace_block "$target" '  local R log chk3 tmp dirty paths_ok' 2 "$rep"
      ;;
    284)
      # parity-suite.sh: ignored_tree hashes nothing (ignored files are not fingerprinted)
      cat > "$rep" <<'MUT284'
  lines="" # MUTATED: ignored files not fingerprinted
MUT284
      mut_replace_block "$target" '  lines=$("$SCRIPT_DIR/stage-worktree.sh" ignored --repo "$top") || return 1' 1 "$rep"
      ;;
    285)
      # review-stage.sh: fingerprint omits the ignored-files hash
      cat > "$rep" <<'MUT285'
  ignored=$(git -C "$R" hash-object --stdin < /dev/null) # MUTATED: ignored not fingerprinted
MUT285
      mut_replace_block "$target" '  ignored=$(git -C "$R" hash-object --stdin < "$W/ign.keep")' 1 "$rep"
      ;;
    286)
      # review-stage.sh: fingerprint compare ignores the ignored part
      cat > "$rep" <<'MUT286'
        (empty) ] as $ch # MUTATED: ignored not compared
MUT286
      mut_replace_block "$target" '        (if ($x.ignored | type) == "string"' 1 "$rep"
      ;;
    287)
      # review-stage.sh: deny-refresh resolves the repo top with an inline resolver (case/symlink spelling drifts from repo_top)
      cat > "$rep" <<'MUT287'
  if R=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) && R=$(cd "$R" && pwd -P); then # MUTATED: inline resolver
MUT287
      mut_replace_block "$target" '  if R=$(resolve_top "$REPO"); then' 1 "$rep"
      ;;
    288)
      # review-stage.sh: fingerprint with a non-repo --repo falls back to the cwd's repo
      cat > "$rep" <<'MUT288'
  [ -z "$FP_OUT" ] || check_abs --out "$FP_OUT"
  R=$(repo_top "$REPO") # MUTATED: a non-repo --repo falls back to the cwd
MUT288
      mut_replace_block "$target" '  [ -z "$FP_OUT" ] || check_abs --out "$FP_OUT"' 2 "$rep"
      ;;
    289)
      # ext-run.sh: stale build worktrees are never reaped (the reaper call is removed)
      cat > "$rep" <<'MUT289'
  : # MUTATED: stale build worktrees never reaped
MUT289
      mut_replace_block "$target" '  reap_stale_builds' 1 "$rep"
      ;;
    290)
      # ext-run.sh: a live run's build worktree is reaped (the pid-alive check is removed)
      cat > "$rep" <<'MUT290'
        : # MUTATED: a live run's worktree reaped
MUT290
      mut_replace_block "$target" '        ps -p "$pid" >/dev/null 2>&1 && continue' 1 "$rep"
      ;;
    291)
      # ext-run.sh: the reaper skips every entry (stale builds are never reaped)
      cat > "$rep" <<'MUT291'
        continue # MUTATED: reaper never reaps
MUT291
      mut_replace_block "$target" '        ps -p "$pid" >/dev/null 2>&1 && continue' 1 "$rep"
      ;;
    292)
      # ext-run.sh: the locked build worktree carries no lock reason (the reaper cannot attribute it)
      cat > "$rep" <<'MUT292'
  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --lock --detach "$STAGE/build" HEAD >"$STAGE/meta/worktree.log" 2>&1; then # MUTATED: lock carries no reason
MUT292
      mut_replace_block "$target" '  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --lock' 1 "$rep"
      ;;
    293)
      # ext-run.sh: git worktree add runs the caller's hooks (core.hooksPath not neutralised)
      cat > "$rep" <<'MUT293'
  if ! git -C "$BUILD_REPO" worktree add --lock --reason "ext-run $$" --detach "$STAGE/build" HEAD >"$STAGE/meta/worktree.log" 2>&1; then # MUTATED: hooks run for worktree add
MUT293
      mut_replace_block "$target" '  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --lock' 1 "$rep"
      ;;
    294)
      # ext-run.sh: the stage-base commit runs the caller's hooks (core.hooksPath not neutralised)
      cat > "$rep" <<'MUT294'
  git -C "$BUILD_WT" -c user.email=ext-run@localhost -c user.name=ext-run -c commit.gpgsign=false \
MUT294
      mut_replace_block "$target" '  git -C "$BUILD_WT" -c user.email=ext-run@localhost' 1 "$rep"
      ;;
    295)
      # triage-context.sh: LEGACY_IMPORT_AWK strips every CR, not one trailing CR
      cat > "$rep" <<'MUT295'
LEGACY_IMPORT_AWK='function is_legacy(l) { gsub(/\r/, "", l); sub(/[ \t]+$/, "", l); return l == "@triage.md" || l == "@./triage.md" || l == "@~/.claude/triage.md" || l == "@" ENVIRON["TRIAGE_DIR"] "/triage.md" }' # MUTATED: every CR stripped
MUT295
      mut_replace_block "$target" 'LEGACY_IMPORT_AWK=' 1 "$rep"
      ;;
    296)
      # install.sh: the subagent-model upgrade ignores the ownership marker (a downgraded legacy value is re-upgraded)
      cat > "$rep" <<'MUT296'
  elif is_legacy_subagent_model "$1"; then echo "upgrade-legacy" # MUTATED: marker ignored for legacy values
MUT296
      mut_replace_block "$target" '  elif [ "$2" = "null" ] && is_legacy_subagent_model "$1"; then echo "upgrade-legacy"' 1 "$rep"
      ;;
    297)
      # install.sh: CLAUDE_DIR is not canonicalised
      cat > "$rep" <<'MUT297'
CLAUDE_DIR="$CLAUDE_DIR_GIVEN" # MUTATED: CLAUDE_DIR not canonicalised
MUT297
      mut_replace_block "$target" 'CLAUDE_DIR=$(canon_dir "$CLAUDE_DIR_GIVEN")' 1 "$rep"
      ;;
    298)
      # uninstall.sh: CLAUDE_DIR is not canonicalised
      cat > "$rep" <<'MUT298'
CLAUDE_DIR="$CLAUDE_DIR_GIVEN" # MUTATED: CLAUDE_DIR not canonicalised
MUT298
      mut_replace_block "$target" 'CLAUDE_DIR=$(canon_dir "$CLAUDE_DIR_GIVEN")' 1 "$rep"
      ;;
    299)
      # uninstall.sh: settings.json is written last again (a CLAUDE.md failure leaves settings half-removed)
      cat > "$rep" <<'MUT299E0'
  : # MUTATED: settings written last
MUT299E0
      mut_replace_block "$target" '  apply_file "$SETTINGS_TMP" "$SETTINGS" || die "could not write $SETTINGS — nothing was changed."' 2 "$rep"
      cat > "$rep" <<'MUT299E1'
if [ -n "$SETTINGS_TMP" ]; then apply_file "$SETTINGS_TMP" "$SETTINGS" || die "could not write $SETTINGS."; fi
if [ -n "${SUB_LEFT:-}" ]; then
MUT299E1
      mut_replace_block "$target" 'if [ -n "${SUB_LEFT:-}" ]; then' 1 "$rep"
      ;;
    300)
      # uninstall.sh: a CLAUDE.md write failure is ignored (files removed anyway)
      cat > "$rep" <<'MUT300'
    apply_file "$CLAUDE_MD_TMP" "$CLAUDE_DIR/CLAUDE.md" || true # MUTATED: CLAUDE.md write failure ignored
MUT300
      mut_replace_block "$target" '    apply_file "$CLAUDE_MD_TMP" "$CLAUDE_DIR/CLAUDE.md" \' 2 "$rep"
      ;;
    301)
      # install.sh: an outdated pointer line is not detected (never migrated)
      cat > "$rep" <<'MUT301'
  rc=1 # MUTATED: outdated pointer not detected
MUT301
      mut_replace_block "$target" '  rc=0; has_line "$CLAUDE_DIR/CLAUDE.md" "$(old_pointer_line)" || rc=$?' 1 "$rep"
      ;;
    302)
      # uninstall.sh: the previous pointer-line spelling is left in CLAUDE.md
      cat > "$rep" <<'MUT302'
  drop_lines "$CLAUDE_DIR/CLAUDE.md" "$(pointer_line)" "MUTATED: old pointer kept" > "$CLAUDE_MD_TMP" \
MUT302
      mut_replace_block "$target" '  drop_lines "$CLAUDE_DIR/CLAUDE.md" "$(pointer_line)" "$(old_pointer_line)"' 1 "$rep"
      ;;
    303)
      # install.sh: LEGACY_IMPORT_AWK matches only the bare @triage.md spelling and keeps CRs
      cat > "$rep" <<'MUT303'
LEGACY_IMPORT_AWK='function is_legacy(l) { sub(/\r$/, "", l); return l == "@triage.md" }' # MUTATED: only the bare spelling
MUT303
      mut_replace_block "$target" 'LEGACY_IMPORT_AWK=' 1 "$rep"
      ;;
    304)
      # install.sh: POINTER_TAIL reverts to the previous spelling (no in-band fallback; the current line is treated as outdated)
      cat > "$rep" <<'MUT304'
POINTER_TAIL="/triage.md) reaches the main session through a SessionStart hook; subagents don't receive it." # MUTATED: old pointer tail
MUT304
      mut_replace_block "$target" 'POINTER_TAIL="' 1 "$rep"
      ;;
    305)
      # install.sh: LEGACY_IMPORT_AWK carries only the bare spelling (a ./ or ~/ import is not recognised)
      cat > "$rep" <<'MUT305'
LEGACY_IMPORT_AWK='function is_legacy(l) { sub(/\r$/, "", l); sub(/[ \t]+$/, "", l); return l == "@triage.md" }' # MUTATED: bare import spelling only
MUT305
      mut_replace_block "$target" 'LEGACY_IMPORT_AWK=' 1 "$rep"
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
    1) ! grep -qF 'if [ -s "$CLAUDE_MD" ] && [ -n "$(tail -c1' "$target" ;;
    2) ! grep -qF 'jq empty "$SETTINGS"' "$target" ;;
    3) grep -qF '  mv "$1" "$SETTINGS"' "$target" && ! grep -qF 'if [ -L "$SETTINGS" ]; then cat' "$target" ;;
    4) grep -qF 'rm -f "$CLAUDE_DIR"/agents/triage-*.md' "$target" && ! grep -qF 'for a in $AGENTS; do' "$target" ;;
    5) ! grep -qF '.permissions.deny  -= $fable' "$target" ;;
    6) ! grep -qF 'case "$PCT" in' "$target" && grep -qF 'if [ "$PCT" -ge 60 ]; then' "$target" ;;
    7) grep -qF 'MUTATED: incomplete tri-state disabled' "$target" && ! grep -qF 'incomplete: rcs.some(rc => rc == null)' "$target" ;;
    8) grep -qF 'MUTATED: retry disabled' "$target" ;;
    9) grep -qF 'function matchedFiles(r, text) {' "$target" && ! grep -qF 'fileMentioned(f, text)' "$target" ;;
    10) [ "$(grep -cF 'UNEXPECTED_DRIFT=1' "$target")" -eq 1 ] ;;
    11) grep -qF 'MUTATED: args validation disabled' "$target" && ! grep -qF 'throw new Error(`triage-exec:' "$target" ;;
    12) grep -qF 'MUTATED: swallows false' "$target" && ! grep -qF 'elif .prompt_cache.warm == false' "$target" ;;
    15) grep -qF 'MUTATED: substring match' "$target" && ! grep -qF '*/"$name"/*)' "$target" ;;
    16) grep -qF 'MUTATED: overflow dropped from the danger guard' "$target" && ! grep -qF "if (viaOverflow) { vendor = 'claude'; level = 'deep' }" "$target" ;;
    17) grep -qF 'MUTATED: fallback hard-coded to builder' "$target" && ! grep -qF "const onClaude = { level: step.level," "$target" ;;
    18) grep -qF 'MUTATED: FORCE warning suppressed' "$target" ;;
    19) grep -qF 'MUTATED: legacy upgrade disabled' "$target" ;;
    20) ! grep -qF 'or $up == "1"' "$target" && grep -qF '(if (.env.CLAUDE_CODE_SUBAGENT_MODEL // null) == null then .env.CLAUDE_CODE_SUBAGENT_MODEL = $m else . end)' "$target" ;;
    21) grep -qF '| (if $mark != null then del(.env.CLAUDE_CODE_SUBAGENT_MODEL) else . end)' "$target" && ! grep -qF '== $mark then' "$target" ;;
    22) ! grep -qF "if (r.level === 'deep' && !ranMax(r)) return { level: 'deep', vendor, effort: 'max', owesFable: true" "$target" && grep -qF 'function redoStep(r, isEscalate) {' "$target" ;;
    23) grep -qF 'MUTATED: deep@max fallback always taken' "$target" && ! grep -qF '  if (afterMax) {' "$target" ;;
    24) grep -qF 'MUTATED: default model fallback' "$target" && ! grep -qF 'an absent entry is a refusal, never a default model' "$target" ;;
    25) ! grep -qF 'codex wrote no final message' "$target" && grep -qF 'RESPONSE=$(cat "$LASTMSG")' "$target" ;;
    26) grep -qF 'MUTATED: deny check skipped for codex' "$target" ;;
    28) grep -qF 'MUTATED: codex danger effort floor dropped' "$target" && ! grep -qF 'effort = codexDangerEffort(level, effort)' "$target" ;;
    29) grep -qF 'MUTATED: retried sideways on the same vendor' "$target" && ! grep -qF "const vendor = 'claude' // every redo runs on Claude" "$target" ;;
    31) grep -qF 'MUTATED: graded from the self-report' "$target" && ! grep -qF "pc.applies === true && pc.rc === 0" "$target" ;;
    32) grep -qF 'MUTATED: worktree cleanup skipped' "$target" ;;
    33) grep -qF 'MUTATED: fork skip limited to --files-only' "$target" && ! grep -qxF '  if is_ignored "$rel" && [ -e "$dst" ]; then' "$target" ;;
    34) ! grep -qF 'args.outDir must not be inside args.repo' "$target" ;;
    36) ! grep -qF "if (candidates.some(c => c.vendor !== 'claude') && files.length === 0) {" "$target" ;;
    37) grep -qF 'MUTATED: real repo as WORKDIR' "$target" && ! grep -qF '` WORKDIR=${c.worktree}`' "$target" ;;
    38) grep -qF 'MUTATED: leakcheck result ignored' "$target" && ! grep -qF 'const leakInfo = leakState(gr && leakLine(gr.leakcheckLine))' "$target" ;;
    39) grep -qF 'MUTATED: untracked files omitted' "$target" && ! grep -qF 'git -C "$WT" add -A' "$target" ;;
    40) grep -qF 'MUTATED: common-dir deny check dropped' "$target" && ! grep -qF 'deny_check_path "$main"' "$target" ;;
    41) grep -qF 'MUTATED: unavailable counted as fail' "$target" && ! grep -qF "pb.other++" "$target" ;;
    42) grep -qF 'MUTATED: streak not reset' "$target" && ! grep -qF 's.streak = 0' "$target" ;;
    43) grep -qF 'MUTATED: cheapness order ignored' "$target" && ! grep -qF 'elif $kc > $ki then "pricier"' "$target" ;;
    44) grep -qF 'MUTATED: deny markers not propagated' "$target" && ! grep -qF 'propagated by parity-suite.sh materialize' "$target" && grep -qF '  DENIED_CODEX=false' "$target" ;;
    45) grep -qF 'MUTATED: source history/refs kept' "$target" && ! grep -qF 'update-ref -d "$r"' "$target" ;;
    46) grep -qF 'MUTATED: MODEL line dropped for external review candidates' "$target" && ! grep -qF '(c.model ? `MODEL=${c.model}' "$target" ;;
    47) grep -qF 'MUTATED: unknown leak state accepted' "$target" && ! grep -qF 'if (leakInfo.leak !== false && gr)' "$target" ;;
    48) grep -qF 'MUTATED: overlay failure ignored' "$target" && ! grep -qF 'emit "$patch" true null "$diffstat" "$log.tail" overlay-failed' "$target" ;;
    49) grep -qF 'MUTATED: git env not cleared' "$target" && ! grep -qF 'unset GIT_DIR GIT_WORK_TREE' "$target" ;;
    50) grep -qF 'MUTATED: symlink resolved only at parent' "$target" && ! grep -qF 't=$(readlink "$p")' "$target" ;;
    51) grep -qF 'MUTATED: conflicting 3-way apply not pre-checked' "$target" && ! grep -qF "! grep -qi 'conflict'" "$target" ;;
    52) grep -qF 'MUTATED: minN ignored' "$target" && ! grep -qF 'then 0 else $minN - $n end' "$target" ;;
    53) grep -qF 'MUTATED: point rate, not Wilson LB' "$target" && ! grep -qF 'if $ch.wilsonLB >= $inc.rate' "$target" ;;
    54) grep -qF 'MUTATED: non-graded status counted as fail' "$target" && ! grep -qF 'else "unknown" end) end;' "$target" ;;
    55) grep -qF 'MUTATED: conflicting 3-way apply not pre-checked' "$target" && ! grep -qF "! grep -qi 'conflict'" "$target" ;;
    56) grep -qF 'MUTATED: codex run without sandbox-exec' "$target" && ! grep -qF 'exec "$SANDBOX_EXEC" -f "$PROFILE" "$CODEX_REAL"' "$target" ;;
    57) grep -qF "printf '(allow file-read* (subpath %s) (subpath %s) (subpath %s) (subpath %s)'" "$target" && ! grep -qF "printf '(allow file-read* (literal %s)" "$target" ;;
    58) grep -qF 'MUTATED: audit records aggregated_output' "$target" && grep -qF 'output: .aggregated_output}' "$target" ;;
    59) grep -qF 'MUTATED: agy accepted' "$target" && ! grep -qF 'die "REFUSED: agy retired 2026-09-24' "$target" ;;
    60) grep -qF 'MUTATED: writes allowed by default' "$target" && ! grep -qF "printf '(deny file-write* (subpath \"/\"))" "$target" ;;
    61) grep -qF 'MUTATED: temp-dir reads open' "$target" && ! grep -qF '(subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/tmp") (subpath "/var/folders"))' "$target" ;;
    62) grep -qF "/bin/sh -c 'true > \"\$1\"; exit 0' sh \"\$canary\" \"\$outside\"" "$target" && ! grep -qF 'true > "$2"' "$target" ;;
    63) grep -qF 'MUTATED: unmapped PARITY_ variable silently ignored' "$target" && ! grep -qF '|| usage "unmapped PARITY_ variable(s)' "$target" ;;
    64) grep -qF 'MUTATED: fingerprint skipped for review tasks' "$target" && ! grep -qF "if (mat.fp.source === 'git' && rows.length && !leakAbort) rows" "$target" ;;
    65) grep -qF 'MUTATED: judge gets repo path' "$target" && grep -qF '${t.mat.repo}.)' "$target" ;;
    66) grep -qF 'MUTATED: cache env not set' "$target" && ! grep -qF 'export XDG_CACHE_HOME="$CACHE"' "$target" ;;
    67) grep -qF 'MUTATED: hard exclude skipped for tracked paths' "$target" && ! grep -qF '    if pat=$(hard_match "$rel"); then printf' "$target" ;;
    68) grep -qF 'MUTATED: adjudicator sees provenance' "$target" && grep -qF 'reportedBy: it.prov' "$target" ;;
    69) grep -qF 'MUTATED: disputed counted as real' "$target" && ! grep -qxF "  const isReal = it => it.verdict === 'real'" "$target" ;;
    70) grep -qF 'MUTATED: input-dir follows an outside symlink' "$target" && ! grep -qF 'holds a symlink that leaves it' "$target" ;;
    71) grep -qF 'MUTATED: schema passed to codex un-normalized' "$target" && ! grep -qF 'jq -c "$STRICT_SCHEMA_JQ"' "$target" ;;
    72) grep -qF 'MUTATED: extend re-adjudicates attached items' "$target" && ! grep -qF 'const toJudge = prior ? items.filter' "$target" ;;
    73) grep -qF 'MUTATED: superseded reviewer still scored' "$target" && ! grep -qF "status: supersededSet.has(p.label)" "$target" ;;
    74) grep -qF 'MUTATED: codex spawned without TIMEOUT' "$target" && ! grep -qF 'TIMEOUT=${timeout}' "$target" ;;
    75) grep -qF 'MUTATED: weekly pause ignored' "$target" && ! grep -qF 'bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct' "$target" ;;
    76) grep -qF 'MUTATED: sample threshold dropped' "$target" && ! grep -qF "skip: 'not-sampled'" "$target" ;;
    77) grep -qF 'MUTATED: challenger fallback dropped' "$target" && ! grep -qF "return { apply: 'challenger'" "$target" ;;
    78) grep -qF 'MUTATED: LEAK abort dropped' "$target" && ! grep -qF 'if (res && res.leak === true) {' "$target" ;;
    79) grep -qF 'MUTATED: dirty files not checked' "$target" && ! grep -qF "dirty.rc !== 0 || dirty.porcelain.length" "$target" ;;
    80) grep -qF 'MUTATED: danger floor on challengers dropped' "$target" && ! grep -qF '!meetsCodexDangerFloor(st.level, c.effort)' "$target" ;;
    81) grep -qF 'MUTATED: bake-off fields without args.bakeoff' "$target" && ! grep -qF '...(bakeoffOn ? bakeoffReport() : {}),' "$target" ;;
    82) grep -qF 'MUTATED: rates n check weakened' "$target" && ! grep -qF '| if $g.n < $minN then' "$target" ;;
    83) grep -qF 'MUTATED: rates CI width ignored' "$target" && ! grep -qF 'elif ($g.wilsonUB - $g.wilsonLB) > $maxWidth' "$target" ;;
    84) grep -qF 'MUTATED: proposal does not force explore' "$target" && ! grep -qF '($proposals[] | select(.level == $L and .vendor == $V)' "$target" ;;
    85) grep -qF 'MUTATED: rates ignored' "$target" && ! grep -qF 'bo.rates[st.level] : bo.tuning.sampleRate' "$target" ;;
    86) grep -qF 'MUTATED: applied external bake-off patch not in play' "$target" && ! grep -qF 'return v !== null && isExternal(v) })' "$target" ;;
    87) grep -qF 'MUTATED: grouped by model, not modelId' "$target" && ! grep -qF 'group_by([.level, .vendor, .modelId, .effort])' "$target" ;;
    88) grep -qF 'MUTATED: alias boundary exclusive' "$target" && ! grep -qF 'select(.from <= $date)' "$target" ;;
    89) grep -qF 'MUTATED: version-bound cheapness order' "$target" && ! grep -qF '"codex":["luna","sol","astra"]' "$target" ;;
    90) grep -qF 'MUTATED: backfill refills filled rows' "$target" && ! grep -qF 'def unfilled: type == "object" and (has("modelId") | not);' "$target" ;;
    130) grep -qF 'MUTATED: deleted without the repo-copy check' "$target" ;;
    131) grep -qF 'MUTATED: memory deleted, not backed up' "$target" && ! grep -qF 'then backup_move "$CLAUDE_DIR/agent-memory/$a"' "$target" ;;
    132) grep -qF 'MUTATED: single-slot backup' "$target" ;;
    133) grep -qF 'MUTATED: backups never pruned' "$target" ;;
    134) grep -qF 'MUTATED: retire deletes unknown bytes' "$target" ;;
    135) grep -qF 'MUTATED: hard-coded subagent model' "$target" && ! grep -qF '.levels.deep.claude.model // empty' "$target" ;;
    136) ! grep -qF '.env[$k] = $m' "$target" ;;
    137) grep -qF 'MUTATED: marker ownership ignored' "$target" ;;
    138) grep -qF 'MUTATED-138' "$target" && ! grep -qF 'then del(.env[$k]) else . end)' "$target" ;;
    139) grep -qF 'MUTATED: unmarked current value adopted' "$target" ;;
    140) grep -qF 'MUTATED: merge failure swallowed' "$target" && ! grep -qF 'settings merge (jq) failed' "$target" ;;
    141) grep -qF 'MUTATED: rewrite failure swallowed' "$target" ;;
    142) grep -qF 'MUTATED: settings shape not validated' "$target" && ! grep -qF 'unexpected shape' "$target" ;;
    143) grep -qF 'MUTATED: --root value unchecked' "$target" && ! grep -qF -- '--root needs a directory' "$target" ;;
    144) ! grep -qF 'END { if (infm) exit 3 }' "$target" ;;
    145|146) grep -qF 'MUTATED: entries not normalized' "$target" && ! grep -qF "tr -d '\r' < \"\$DRIFTIGNORE\"" "$target" ;;
    147) grep -qF 'MUTATED: settings status not checked' "$target" && ! grep -qF -- '--settings-status 2>&1' "$target" ;;
    148) ! grep -qF 'parity-cost.sh parity-report.sh' "$target" ;;
    149) ! grep -qF 'check_file "scripts/triage-stats.sh"' "$target" ;;
    150) grep -qF 'MUTATED: --require-clean dropped' "$target" && ! grep -qF -- '--patch ${shq(patch)} --require-clean' "$target" ;;
    151) grep -qF 'MUTATED: challenger effort stored' "$target" && ! grep -qF ': { level: st.level, vendor: ch.vendor, effort: st.effort }' "$target" ;;
    152) grep -qF 'MUTATED: patch identity not checked' "$target" && ! grep -qF -- '&& ap.patch === patch' "$target" ;;
    153) grep -qF 'MUTATED: planned danger floor check dropped' "$target" && ! grep -qF "return { skip: 'planned-below-danger-floor' }" "$target" ;;
    154) grep -qF 'MUTATED: top-claude ineligibility dropped' "$target" && ! grep -qF "return { skip: 'top-claude' }" "$target" ;;
    155) grep -qF 'MUTATED: entry via raw hash modulo (low bits)' "$target" && ! grep -qF 'Math.floor(draw(`${key}\0entry`) * list.length)' "$target" ;;
    156) grep -qF 'MUTATED: never adds to neverRanExternally' "$target" && ! grep -qF 'if (plannedNothing) neverRanExternally.add(st.id)' "$target" ;;
    157) grep -qF 'MUTATED: outOfScope always false' "$target" && ! grep -qF 'const outOfScope = !files.length || !changed ? null :' "$target" ;;
    158) grep -qF 'MUTATED: selfCheckEnv offered to externals too' "$target" && ! grep -qF "selfCheckFor = c => selfCheckEnv && c.vendor === 'claude'" "$target" ;;
    159) grep -qF 'MUTATED: any present error field invalidates' "$target" && ! grep -qF 'if (isStr(pc.error) ||' "$target" ;;
    160) grep -qF 'MUTATED: all-malformed reviewer scored ok' "$target" && ! grep -qF 'const allMalformed = c => c.ok.length === 0 && c.dropped > 0' "$target" ;;
    161) grep -qF 'MUTATED: last /snap/ instead of first' "$target" && ! grep -qF 'const i = s.indexOf(' "$target" ;;
    162) grep -qF 'MUTATED: --summary line dropped' "$target" && ! grep -qF "sed 's/^/PATCHCHECK /'" "$target" ;;
    163) grep -qF 'MUTATED: LEAKCHECK line never emitted' "$target" && ! grep -qF "printf 'LEAKCHECK %s" "$target" ;;
    164) grep -qF 'MUTATED: first free backup name' "$target" && ! grep -qF 'ls -d "$b"-* >/dev/null 2>&1; then' "$target" ;;
    165) grep -qF 'MUTATED: -N sorted as text' "$target" && ! grep -qF -- '-k2,2n' "$target" ;;
    166) grep -qF 'MUTATED: refreshed deny ignored' "$target" && ! grep -qF 'const deniedNow = prior.codexDeniedNow !== false' "$target" ;;
    167) grep -qF 'MUTATED: missing refresh allows codex' "$target" && ! grep -qF "codexDeniedNow: typeof c.codexDeniedNow === 'boolean' ? c.codexDeniedNow : true," "$target" ;;
    168) grep -qF 'MUTATED: deny-refresh skips the repo' "$target" && ! grep -qF 'if codex_denied --beneath "$R"; then denied=true; fi' "$target" ;;
    169) grep -qF 'MUTATED: missing manifest allows codex' "$target" && ! grep -qF 'deny-refresh: no $OUT/manifest.json' "$target" ;;
    216) grep -qF 'MUTATED: redoStep noFable guard dropped' "$target" && ! grep -qF 'if (noFable && (r.owesFable' "$target" ;;
    217) grep -qF 'MUTATED: runFable noFable guard dropped' "$target" && ! grep -qF '  if (noFable) {' "$target" ;;
    218) grep -qF 'MUTATED: noFable top check dropped' "$target" && ! grep -qF 'if (fableSt) bad(' "$target" ;;
    219) grep -qF 'MUTATED: noFable deep@max retry unmarked' "$target" && ! grep -qF 'if (noFable && ranMax(r)) return {' "$target" ;;
    220) grep -qF 'MUTATED: empty deep@max not stopped' "$target" && ! grep -qF "effort: 'max' } : stopForUser(" "$target" ;;
    221) grep -qF 'MUTATED: needs-user not incomplete' "$target" && ! grep -qF '|| needsUser.size > 0,' "$target" ;;
    170) grep -qF 'MUTATED: attestation dropped' "$target" && ! grep -qF '\n\n${BOUNDARY_ATTESTATION}\n\n${prompt}`' "$target" ;;
    171) grep -qF 'MUTATED: first line only' "$target" && ! grep -qF '  for (const raw of lines) {' "$target" ;;
    172) grep -qF 'MUTATED: refused not reported' "$target" && ! grep -qF "refused: externalNoWork.filter(n => n.vendor === v && n.kind === 'refused')" "$target" ;;
    173) grep -qF 'MUTATED: reason drops kind' "$target" && ! grep -qF 'reason: `${what} — same level on Claude`' "$target" ;;
    174) grep -qF 'MUTATED: direct children only' "$target" && ! grep -qF 'done < <(find "$SUBDIR" -name' "$target" ;;
    175) grep -qF 'MUTATED: deep dir classifier' "$target" && ! grep -qF 'ls "$ARG"/agent-*.jsonl >/dev/null 2>&1; then' "$target" ;;
    176) grep -qF 'MUTATED: AGY alias dropped' "$target" && ! grep -qF '[ "${AGY_BOUNDARY_CLEARED:-}" = "1" ]' "$target" ;;
    177) grep -qF 'MUTATED: CODEX name dropped' "$target" && ! grep -qF '[ "${CODEX_BOUNDARY_CLEARED:-}" = "1" ]' "$target" ;;
    178) grep -qF 'MUTATED: Agent deny dropped' "$target" && ! grep -q '^disallowedTools:' "$target" ;;
    179) grep -qF 'MUTATED: cap check removed' "$target" && ! grep -qF -- '-gt "$CAP" ]; }' "$target" ;;
    180) grep -qF 'MUTATED: kill switch ignored' "$target" && ! grep -qF 'triage.disabled" ] && exit 0' "$target" ;;
    181) grep -qF 'MUTATED: legacy guard removed' "$target" && ! grep -qF 'is_legacy($0) { f = 1 }' "$target" ;;
    182) grep -qF 'MUTATED: SessionStart replaced' "$target" && ! grep -qF '+ [$group])' "$target" ;;
    183) grep -qF 'MUTATED: every SessionStart hook deleted' "$target" && ! grep -qF 'any(.hooks[]; ours)' "$target" ;;
    184) grep -qF 'MUTATED: pointer guard dropped' "$target" && ! grep -qF 'if [ "$POINTER" -eq 0 ]' "$target" ;;
    185) grep -qF 'MUTATED: agent_id ignored' "$target" && ! grep -qF '(.agent_id // null) != null' "$target" ;;
    187) grep -qF 'MUTATED: hook status dropped' "$target" && ! grep -qF 'echo "settings migration pending: triage hook missing' "$target" ;;
    188) grep -qF 'MUTATED: legacy status dropped' "$target" && ! grep -qF 'echo "settings migration pending: legacy @triage.md' "$target" ;;
    189) grep -qF 'MUTATED: CLAUDE_DIR not pinned' "$target" && ! grep -qF "printf 'CLAUDE_DIR=%q bash" "$target" ;;
    190) grep -qF 'MUTATED: substring ownership' "$target" && ! grep -qF 'def owned: $TRIAGE_HOOK_OWNED_JQ;' "$target" ;;
    191) grep -qF 'MUTATED: substring ownership' "$target" && ! grep -qF 'def ours: $TRIAGE_HOOK_OWNED_JQ;' "$target" ;;
    192) grep -qF 'MUTATED: predicate copy drifted' "$target" && ! grep -qF '.type == "command" and .command == $cmd' "$target" ;;
    193) grep -qF 'MUTATED: matcher coverage ignored' "$target" && ! grep -qF '(($events | split("|")) - split("|"))' "$target" ;;
    194) grep -qF 'MUTATED: disableAllHooks ignored' "$target" && ! grep -qF '0) HOOKS_OFF=1 ;;' "$target" ;;
    195) grep -qF 'MUTATED: blocked status dropped' "$target" && ! grep -qF 'echo "settings migration blocked:' "$target" ;;
    196) grep -qF 'MUTATED: CR kept' "$target" && ! grep -qF 'sub(/\r$/, "", l); if (l == want)' "$target" ;;
    197) grep -qF 'MUTATED: filter failure swallowed' "$target" && ! grep -qF 'die "could not filter $CLAUDE_MD' "$target" ;;
    198) grep -qF 'MUTATED: jq failure read as add' "$target" && ! grep -qF '*) return 1 ;;' "$target" ;;
    199) grep -qF 'MUTATED: status needs settings.json' "$target" ;;
    200) grep -qF 'MUTATED: filter failure swallowed' "$target" && ! grep -qF 'die "could not filter $CLAUDE_DIR/CLAUDE.md' "$target" ;;
    201) grep -qF 'MUTATED: CR not stripped' "$target" && ! grep -qF 'is_legacy(l) { sub(/\r$/' "$target" ;;
    202|203) grep -qF 'MUTATED: pin ignored' "$target" && ! grep -qF ': $TRIAGE_HOOK_OWNED_JQ;' "$target" ;;
    204|205) grep -qF 'MUTATED: type ignored' "$target" && ! grep -qF ': $TRIAGE_HOOK_OWNED_JQ;' "$target" ;;
    206) grep -qF 'MUTATED: resume not required' "$target" && ! grep -qF '(($events | split("|")) - split("|"))' "$target" ;;
    207) grep -qF 'MUTATED: rubric gate skipped' "$target" && ! grep -qF '! rubric_fits "$1" "$2"' "$target" ;;
    208) grep -qF 'MUTATED: repo rubric checked' "$target" && ! grep -qF 'claude_md_decision "$CLAUDE_DIR/$TRIAGE_HOOK_SCRIPT" "$CLAUDE_DIR/triage.md"' "$target" ;;
    209) grep -qF 'MUTATED: hook merged in a second write' "$target" && grep -qF 'settings merge (jq) failed (hook)' "$target" ;;
    210) grep -qF 'MUTATED: settings.json created first' "$target" ;;
    211) grep -qF 'MUTATED: false read as absent' "$target" && ! grep -qF '(.hooks.SessionStart | shape("array"))' "$target" ;;
    212|213) grep -qF 'MUTATED: final newline added' "$target" && ! grep -qF '(nl ? "\n" : "")' "$target" ;;
    214) grep -qF 'MUTATED: pointer names ~/.claude' "$target" ;;
    215) grep -qF 'MUTATED: line break accepted' "$target" && ! grep -qF 'CLAUDE_DIR contains a line break' "$target" ;;
    110) grep -qF 'MUTATED: dedupe dropped' "$target" && ! grep -qF 'select(okey as $k | any($have[]; . == $k) | not)] as $miss' "$target" ;;
    111) grep -qF 'MUTATED: collision skipped' "$target" && ! grep -qF 'else {action: "refuse", lines: []' "$target" ;;
    112) grep -qF 'MUTATED: UTC offset ignored' "$target" && ! grep -qF '(if $c.sg == null then 0 else' "$target" ;;
    113) grep -qF 'MUTATED: lock not taken' "$target" && ! grep -qF 'while ! mkdir "$lock" 2>/dev/null; do' "$target" ;;
    114) grep -qF 'MUTATED: stale lock never taken over' "$target" && ! grep -qF 'if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then' "$target" ;;
    115) grep -qF 'MUTATED: symlink clobbered' "$target" && ! grep -qF 'cp -p "$REAL_LEDGER" "$REAL_LEDGER.backfill.$$"' "$target" ;;
    116) grep -qF 'MUTATED: superseded versions are challengers' "$target" && ! grep -qF 'any($current[]; .vendor == $g.vendor and .modelId == $g.modelId))' "$target" ;;
    117) grep -qF 'MUTATED: tuning.rejected ignored' "$target" && ! grep -qF 'if .verdict == "propose" and $r != null' "$target" ;;
    118) grep -qF 'MUTATED: reps counted as independent' "$target" && ! grep -qF 'unit: (if $l.run == null' "$target" ;;
    119) grep -qF 'MUTATED: corrupt line not skipped' "$target" && ! grep -qF '[fromjson?] as $o' "$target" ;;
    120) grep -qF 'MUTATED: every revision counted' "$target" && ! grep -qF '| ([$rvi[] | select(.run == null)]' "$target" ;;
    121) grep -qF 'MUTATED: superseded recorded as unavailable' "$target" && ! grep -qF 'if $r.status == "ok" or $r.status == "superseded"' "$target" ;;
    122) grep -qF 'MUTATED: no review revisions' "$target" && ! grep -qF 'elif $mode == "review" and $revisable then' "$target" ;;
    123) grep -qF 'MUTATED: ingest-parity modelFrom dropped' "$target" && ! grep -qF 'modelFrom: (if $row.model != null then $row.modelFrom else null end),' "$target" ;;
    124) grep -qF 'MUTATED: row modelFrom dropped' "$target" && ! grep -qF "modelFrom: g.model ? (g.modelFrom || null)" "$target" ;;
    125) grep -qF 'MUTATED: ignored files not stat-ed' "$target" && ! grep -qF 'ignored --repo "$top") || return 1' "$target" ;;
    126) grep -qF 'MUTATED: refs not hashed' "$target" && ! grep -qF "for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash" "$target" ;;
    127) grep -qF 'MUTATED: ignored/refs not compared' "$target" && ! grep -qF "after.ignored !== before.ignored ? 'ignored files changed'" "$target" ;;
    128) grep -qF 'MUTATED: aliasHistory not validated' "$target" && ! grep -qF '"$TUNING_ERRORS, ($ALIAS_ERRORS)"' "$target" ;;
    129) grep -qF 'MUTATED: mix-sum check dropped' "$target" && ! grep -qF '| if ($sum - 1 | fabs) < 1e-9 then empty' "$target" ;;
    91) grep -qF 'MUTATED: empty diff counts' "$target" && ! grep -qF 'const realDiff = c => isStr(c.diffstat) && c.outOfScope !== true' "$target" ;;
    92) grep -qF 'MUTATED: out-of-scope patch applied' "$target" && ! grep -qF 'const realDiff = c => isStr(c.diffstat) && c.outOfScope !== true' "$target" ;;
    93) grep -qF 'MUTATED: unknown leak runs in place' "$target" && ! grep -qF "res.leak !== false ? 'leak state unknown" "$target" ;;
    94) grep -qF 'MUTATED: repo mismatch ignored' "$target" && ! grep -qF 'stripSlash(dirty.sessionTop) !== stripSlash(dirty.repoTop)' "$target" ;;
    95) grep -qF 'MUTATED: failed apply runs in place' "$target" && ! grep -qF 'ap.treeModified === false && [0, 1, 6].includes(ap.rc)' "$target" ;;
    96) grep -qF 'MUTATED: climb keeps plan effort' "$target" && ! grep -qF 'effort: up === r.level ? r.subtask.effort : null' "$target" ;;
    97) grep -qF 'MUTATED: external rejection escapes the fallback' "$target" && ! grep -qF 'if (budgeted && budget.remaining() <= 0) throw e' "$target" ;;
    98) grep -qF 'MUTATED: unknown weekly samples' "$target" && ! grep -qF '(weeklyUnknown || bo.weeklyPct >= bo.tuning.pauseAtWeeklyPct)' "$target" ;;
    99) grep -qF 'MUTATED: danger family floor dropped' "$target" && ! grep -qF '!(st.danger && !meetsDangerFloor(v, c.model))' "$target" ;;
    100) grep -qF 'MUTATED: checks joined unguarded' "$target" && ! grep -qF 'checks.map(c => `bash -c ${shq(c)}`)' "$target" ;;
    101) grep -qF 'MUTATED: PATCHCHECK sha not cross-checked' "$target" && ! grep -qF ': pcLine.base !== sha ?' "$target" ;;
    102) grep -qF 'MUTATED: model/effort mismatch ignored' "$target" && ! grep -qF 'ranModel !== c.model' "$target" ;;
    103) grep -qF 'MUTATED: extend scope unchecked' "$target" && ! grep -qF 'if (c.scopeOk !== true) {' "$target" ;;
    104) grep -qF 'MUTATED: build worktree unlocked' "$target" && ! grep -qF 'worktree add --lock' "$target" ;;
    105) grep -qF 'MUTATED: no glob variants' "$target" && ! grep -qF "case \"\$v\" in '**/'?*)" "$target" ;;
    106) grep -qF 'MUTATED: missing ext-run allows codex' "$target" && ! grep -qF 'is missing — marking the snapshot off-limits to codex' "$target" ;;
    107) grep -qF 'MUTATED: require-clean ignored' "$target" && ! grep -qF 'if [ "$REQUIRE_CLEAN" -eq 1 ]; then' "$target" ;;
    108) grep -qF 'MUTATED: failed write assumed untouched' "$target" && ! grep -qF 'modified() { paths_state' "$target" ;;
    109) grep -qF 'MUTATED: ignored paths not fingerprinted' "$target" && ! grep -qF 'ignored_snapshot "$r" "$out.ign" || return 1' "$target" ;;
    222) grep -qF 'MUTATED: a missing CHECKRC reads as exit 0' "$target" && ! grep -qF '  return hits.length ? Number(hits[hits.length - 1][1]) : null' "$target" ;;
    223) grep -qF 'MUTATED: the first CHECKRC line decides' "$target" && ! grep -qF '  return hits.length ? Number(hits[hits.length - 1][1]) : null' "$target" ;;
    224) grep -qF 'MUTATED: no verdict reads as PASS' "$target" ;;
    225) grep -qF 'MUTATED: any reply is a live gate' "$target" && ! grep -qF '    const live = o => o != null && usable(o)' "$target" ;;
    226) grep -qF 'MUTATED: args.repo vs args.bakeoff.repo not compared' "$target" && ! grep -qF '  if (b.repo != null && planRepo && stripSlash(b.repo) !== planRepo) bad(' "$target" ;;
    227) grep -qF 'MUTATED: checks ignore args.repo' "$target" && ! grep -qF 'const checkCommand = cmd => `out=$( { ${planRepo ? ' "$target" ;;
    228) grep -qF 'MUTATED: WORKDIR dropped' "$target" && ! grep -qF '  (planRepo ? ` WORKDIR=${planRepo}` : '\'''\'')' "$target" ;;
    229) grep -qF 'MUTATED: a non-zero exit counts as work' "$target" && ! grep -qF '  if (exit !== '\''0'\'') {' "$target" ;;
    230) grep -qF 'MUTATED: CHANGED FILES: none counts as work' "$target" && ! grep -qF '  if (changed && /^CHANGED FILES:\s*none\s*$/i.test(changed)) return' "$target" ;;
    231) grep -qF 'MUTATED: an unknown leak stops only this subtask' "$target" && ! grep -qF '    return { abort: unknown }' "$target" ;;
    232) grep -qF 'MUTATED: no header needed' "$target" && ! grep -qF '    if (cls.work) findings[v] = String(outs[i]).slice(0, 4000)' "$target" ;;
    233) grep -qF 'MUTATED: rc/now not validated' "$target" && ! grep -qF '  if (rc == null || !/^\d{1,3}$/.test(rc) || now == null || !ISO_UTC.test(now)) return null' "$target" ;;
    234) grep -qF 'MUTATED: end tag not required' "$target" && ! grep -qF '  if (only('\''end'\'') !== '\'''\'' || tags[tags.length - 1].k !== '\''end'\'') return null' "$target" ;;
    235) grep -qF 'MUTATED: clean check not retried' "$target" && ! grep -qF '  if (!dirty) {' "$target" ;;
    236) grep -qF 'MUTATED: re-verify with nothing re-run' "$target" && ! grep -qF '  if (r1.redoResults.length) verification = await verify(r1.merged, true)' "$target" ;;
    237) grep -qF 'MUTATED: Fable challengers allowed' "$target" && ! grep -qF '      !isFableModel(c.model) &&' "$target" ;;
    238) grep -qF 'MUTATED: a Fable-family planned model is sampled' "$target" && ! grep -qF '  if (isFableModel(planned.model)) return { skip: '\''planned-fable'\'' }' "$target" ;;
    239) grep -qF 'MUTATED: ~ separator' "$target" && ! grep -qF '  return `${baseName.slice(0, RUN_MAX - idPart.length - 10)}.${hex8(baseName)}:${idPart}`' "$target" ;;
    240) grep -qF 'MUTATED: a long id is never shortened' "$target" && ! grep -qF '  const idPart = id.length <= 40 ? id :' "$target" ;;
    241) grep -qF 'MUTATED: non-relative files accepted' "$target" && ! grep -qF '  if (bakeoffOn && (s === '\'''\'' || s.startsWith('\''/'\'') || s.split('\''/'\'').includes('\''..'\''))) {' "$target" ;;
    242) grep -qF 'MUTATED: absolute paths kept' "$target" && ! grep -qF '  if (fileRepo && s.startsWith(`${fileRepo}/`)) s = s.slice(fileRepo.length + 1)' "$target" ;;
    243) grep -qF 'MUTATED: a no-op pass is ingested as a pass' "$target" ;;
    244) grep -qF 'MUTATED: no run-time ts' "$target" && ! grep -qF '      result: { ts: dirty.now, base: res.base,' "$target" ;;
    245) grep -qF 'MUTATED: null models left for ingest-time resolution' "$target" && ! grep -qF '          const fill = c.model == null && isStr(r.model)' "$target" ;;
    246) grep -qF 'MUTATED: external reply read by the first-line rule' "$target" && ! grep -qF '    const nothing = err != null || (external ? !cls.work : producedNothing(out))' "$target" ;;
    247) grep -qF 'MUTATED: missing ext-run line not checked' "$target" ;;
    248) grep -qF 'MUTATED: empty-diff pass credited' "$target" ;;
    249) grep -qF 'MUTATED: out-of-scope pass credited' "$target" ;;
    250) grep -qF 'MUTATED: no-work reviewer reply not unavailable' "$target" ;;
    251) grep -qF 'MUTATED: adjudicator reply not classified' "$target" ;;
    252) grep -qF 'MUTATED: repo prefix not stripped' "$target" && ! grep -qF '  if (s.startsWith(`${repoC}/`)) s = s.slice(repoC.length + 1)' "$target" ;;
    253) grep -qF 'MUTATED: dot components kept' "$target" && ! grep -qF '  return s.split('\''/'\'').filter(x => x !== '\'''\'' && x !== '\''.'\'').join('\''/'\'')' "$target" ;;
    254) grep -qF 'MUTATED: args.files not normalised' "$target" && ! grep -qF 'const files = (args.files || []).map(f => scopePath(f) || '\''.'\'')' "$target" ;;
    255) grep -qF 'MUTATED: stray EXTERNAL ( line counts' "$target" ;;
    256) grep -qF 'MUTATED: any line counts as work' "$target" && ! grep -qF '    if (line.startsWith('\''EXTERNAL ('\'')) return { work: true, kind: '\''work'\'', reason: '\'''\'' }' "$target" ;;
    257) grep -qF 'MUTATED: judge reply not classified' "$target" && ! grep -qF '    else if (classifyCrossReview(o).work) {' "$target" ;;
    258) grep -qF 'MUTATED: no-work review row not unavailable' "$target" && ! grep -qF '    if (!cls.work) { rows.push(row(c, c.label, '\''unavailable'\'', { reason: noWorkReason(cls) })); return }' "$target" ;;
    259) grep -qF 'MUTATED: any line counts as work' "$target" && ! grep -qF '    if (line.startsWith('\''EXTERNAL ('\'')) return { work: true, kind: '\''work'\'', reason: '\'''\'' }' "$target" ;;
    260) grep -qF 'MUTATED: classifyExternal copy drifted' "$target" ;;
    261) grep -qF 'MUTATED: refusal does not name the bad characters' "$target" && ! grep -qF '  if [ -n "$bad" ]; then echo "'\''$v'\'' contains character(s)' "$target" ;;
    262) grep -qF 'MUTATED: result ts ignored' "$target" && ! grep -qF '    TS="$own"; TS_SRC=result' "$target" ;;
    263) grep -qF 'MUTATED: tiers-filled model not flagged' "$target" && ! grep -qF 'def at_ingest($filled): if $filled' "$target" ;;
    264) grep -qF 'MUTATED: takeover skips the same-lock re-check' "$target" && ! grep -qF '  if [ -n "$ino" ] && [ "$(lock_ino "$lock")" = "$ino" ] && [ "$got" = "$want" ]; then' "$target" ;;
    265) grep -qF 'MUTATED: takeover mutex ignored' "$target" && ! grep -qF '  if ! mkdir "$m" 2>/dev/null; then' "$target" ;;
    266) grep -qF 'MUTATED: orphaned mutex never cleared' "$target" && ! grep -qF '    if [ "$TAKEOVER_WAIT" -ge 50 ]; then rmdir "$m" 2>/dev/null; TAKEOVER_WAIT=0; fi' "$target" ;;
    267) grep -qF 'MUTATED: ingest-time ts not flagged' "$target" && ! grep -qF '    TS=$(now_ts); TS_SRC=inferred-at-ingest' "$target" ;;
    268) grep -qF 'MUTATED: unreachable configs are gaps again' "$target" && ! grep -qF '                 | select(($reach | index([{vendor: $V, modelId: $c.modelId, effort: $c.effort}])) != null)' "$target" ;;
    269) grep -qF 'MUTATED: unsampleable level stays in explore' "$target" && ! grep -qF '        | if ($reach | length) == 0' "$target" ;;
    270) grep -qF 'MUTATED: workflow agents lumped' "$target" && ! grep -qF '  sess="${f%/subagents/*}"; sess="${sess##*/}"' "$target" ;;
    271) grep -qF 'MUTATED: repeated message ids summed' "$target" && ! grep -qF '      | group_by(.k) | map(max_by(.i)) | sort_by(.i)' "$target" ;;
    272) grep -qF 'MUTATED: a corrupt line ends the file' "$target" && ! grep -qF '       catch "CORRUPT") end'\'' "$f" 2>/dev/null)"' "$target" ;;
    273) grep -qF 'MUTATED: family split drifts from modelTokens' "$target" && ! grep -qF 'def id_tokens: ascii_downcase | [splits("[-._:+@]")];' "$target" ;;
    274) grep -qF 'MUTATED: split drifts from parity-report' "$target" && ! grep -qF 'const modelTokens = m => String(m || '\'''\'').toLowerCase().split(/[-._:+@]/).filter(Boolean)' "$target" ;;
    275) grep -qF 'MUTATED: danger work runs on gpt-6-astra' "$target" ;;
    276) grep -qF 'MUTATED: hard-coded model id' "$target" ;;
    277) grep -qF 'MUTATED: rename sources not listed' "$target" && ! grep -qF '      if ($hd && /^(?:rename|copy) from' "$target" ;;
    278) grep -qF 'MUTATED: failed status read as clean' "$target" && ! grep -qF '    if ! tr '\''\n'\'' '\''\000'\'' < "$tmp/paths" | xargs -0 git -C "$R" --literal-pathspecs --no-optional-locks status' "$target" ;;
    279) grep -qF 'MUTATED: listing failure ignored' "$target" && ! grep -qF '  patch_paths "$R" "$PATCH" "$tmp/paths" || paths_ok=0' "$target" ;;
    280) grep -qF 'MUTATED: unknown paths measured as clean' "$target" ;;
    281) grep -qF 'MUTATED: whole-second mtimes' "$target" && ! grep -qF '      my $hires = eval' "$target" ;;
    282) grep -qF 'MUTATED: .DS_Store not excluded' "$target" ;;
    283) grep -qF 'MUTATED: a non-repo --repo falls back to the cwd' "$target" ;;
    284) grep -qF 'MUTATED: ignored files not fingerprinted' "$target" && ! grep -qF '  lines=$("$SCRIPT_DIR/stage-worktree.sh" ignored --repo "$top") || return 1' "$target" ;;
    285) grep -qF 'MUTATED: ignored not fingerprinted' "$target" && ! grep -qF '  ignored=$(git -C "$R" hash-object --stdin < "$W/ign.keep")' "$target" ;;
    286) grep -qF 'MUTATED: ignored not compared' "$target" && ! grep -qF '        (if ($x.ignored | type) == "string"' "$target" ;;
    287) grep -qF 'MUTATED: inline resolver' "$target" && ! grep -qF '  if R=$(resolve_top "$REPO"); then' "$target" ;;
    288) grep -qF 'MUTATED: a non-repo --repo falls back to the cwd' "$target" ;;
    289) grep -qF 'MUTATED: stale build worktrees never reaped' "$target" && ! grep -qF '  reap_stale_builds' "$target" ;;
    290) grep -qF 'MUTATED: a live run'\''s worktree reaped' "$target" && ! grep -qF '        ps -p "$pid" >/dev/null 2>&1 && continue' "$target" ;;
    291) grep -qF 'MUTATED: reaper never reaps' "$target" && ! grep -qF '        ps -p "$pid" >/dev/null 2>&1 && continue' "$target" ;;
    292) grep -qF 'MUTATED: lock carries no reason' "$target" ;;
    293) grep -qF 'MUTATED: hooks run for worktree add' "$target" && ! grep -qF '  if ! git -C "$BUILD_REPO" -c core.hooksPath=/dev/null worktree add --lock' "$target" ;;
    294) grep -qF -e '-c commit.gpgsign=false \' "$target" && ! grep -qF -e 'commit.gpgsign=false -c core.hooksPath=/dev/null' "$target" ;;
    295) grep -qF 'MUTATED: every CR stripped' "$target" ;;
    296) grep -qF 'MUTATED: marker ignored for legacy values' "$target" && ! grep -qF '  elif [ "$2" = "null" ] && is_legacy_subagent_model "$1"; then echo "upgrade-legacy"' "$target" ;;
    297) grep -qF 'MUTATED: CLAUDE_DIR not canonicalised' "$target" && ! grep -qF 'CLAUDE_DIR=$(canon_dir "$CLAUDE_DIR_GIVEN")' "$target" ;;
    298) grep -qF 'MUTATED: CLAUDE_DIR not canonicalised' "$target" && ! grep -qF 'CLAUDE_DIR=$(canon_dir "$CLAUDE_DIR_GIVEN")' "$target" ;;
    299) grep -qF 'MUTATED: settings written last' "$target" && ! grep -qF '  apply_file "$SETTINGS_TMP" "$SETTINGS" || die "could not write $SETTINGS — nothing was changed."' "$target" ;;
    300) grep -qF 'MUTATED: CLAUDE.md write failure ignored' "$target" && ! grep -qF '    apply_file "$CLAUDE_MD_TMP" "$CLAUDE_DIR/CLAUDE.md" \' "$target" ;;
    301) grep -qF 'MUTATED: outdated pointer not detected' "$target" && ! grep -qF '  rc=0; has_line "$CLAUDE_DIR/CLAUDE.md" "$(old_pointer_line)" || rc=$?' "$target" ;;
    302) grep -qF 'MUTATED: old pointer kept' "$target" ;;
    303) grep -qF 'MUTATED: only the bare spelling' "$target" ;;
    304) grep -qF 'MUTATED: old pointer tail' "$target" ;;
    305) grep -qF 'MUTATED: bare import spelling only' "$target" ;;
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
  # Disposable checkouts may have no .git. Keep the mutation copy inside the
  # same tree while excluding the working temp directory from its own file list.
  ( cd "$REPO_DIR" && find . \( -path './.git' -o -path "./$(basename "$WORK_ROOT")" \) -prune -o -type f -print | sed 's#^./##' ) > "$FILELIST"
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
    parity) ( cd "$copy" && node test/parity-scenarios.mjs ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    paritysuite) ( cd "$copy" && bash test/parity-suite.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    parityreport) ( cd "$copy" && bash test/parity-report.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    reviewstage) ( cd "$copy" && bash test/review-stage.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    usage) ( cd "$copy" && bash test/usage-tally.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    lint) ( cd "$copy" && bash test/lint.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    triagectx) ( cd "$copy" && bash test/triage-context.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
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
BASELINE_PARITY_OK=1
BASELINE_PARITYSUITE_OK=1
BASELINE_PARITYREPORT_OK=1
BASELINE_REVIEWSTAGE_OK=1
BASELINE_USAGE_OK=1
BASELINE_LINT_OK=1
BASELINE_TRIAGECTX_OK=1
if run_suite "$BASELINE_DIR" triagectx; then
  BASELINE_TRIAGECTX_OK=0
else
  echo "  ⚠ baseline $(suite_file triagectx) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" lint; then
  BASELINE_LINT_OK=0
else
  echo "  ⚠ baseline $(suite_file lint) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" usage; then
  BASELINE_USAGE_OK=0
else
  echo "  ⚠ baseline $(suite_file usage) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
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
if run_suite "$BASELINE_DIR" parity; then
  BASELINE_PARITY_OK=0
else
  echo "  ⚠ baseline $(suite_file parity) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" paritysuite; then
  BASELINE_PARITYSUITE_OK=0
else
  echo "  ⚠ baseline $(suite_file paritysuite) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" parityreport; then
  BASELINE_PARITYREPORT_OK=0
else
  echo "  ⚠ baseline $(suite_file parityreport) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" reviewstage; then
  BASELINE_REVIEWSTAGE_OK=0
else
  echo "  ⚠ baseline $(suite_file reviewstage) is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
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
    parity) baseline_ok=$BASELINE_PARITY_OK ;;
    paritysuite) baseline_ok=$BASELINE_PARITYSUITE_OK ;;
    parityreport) baseline_ok=$BASELINE_PARITYREPORT_OK ;;
    reviewstage) baseline_ok=$BASELINE_REVIEWSTAGE_OK ;;
    usage) baseline_ok=$BASELINE_USAGE_OK ;;
    lint) baseline_ok=$BASELINE_LINT_OK ;;
    triagectx) baseline_ok=$BASELINE_TRIAGECTX_OK ;;
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
