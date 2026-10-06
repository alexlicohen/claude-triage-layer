#!/bin/bash
# scripts/patch-check.sh — the independent grader of a bake-off (workflows/
# triage-compare.js). Applies each candidate patch to its OWN fresh worktree of
# the caller's repo at a fixed base revision, runs the objective check there, and
# reports the result. It never applies a patch or copies an overlay into the
# caller's working tree or index: the only thing IT writes into the repo is git's
# own worktree bookkeeping under .git/worktrees, which it removes again (git worktree
# remove + prune) after every patch and on every exit path. The CHECK it runs is
# another matter: with stage links, what the check writes through a link lands in
# the real repo (see "Stage links") — detected by the bake-off's leakcheck, not
# prevented.
#
# Usage:
#   scripts/patch-check.sh --repo DIR --base REV --check CMD [--check CMD2 ...]
#                          [--overlay DIR] [--timeout SECS] [--env-map FILE]
#                          [--baseline-on RCS] [--summary --tail-dir DIR] PATCH...
#   scripts/patch-check.sh --print-env --check CMD [--check CMD2 ...] [--env-map FILE]
#
#   --repo DIR      the git repo the candidates were built against.
#   --base REV      the revision every patch applies to (e.g. HEAD).
#   --check CMD     run with `bash -c` from the worktree root after the patch is
#                   applied; its exit code is the grade. Repeatable: the GRADED run
#                   is ONE command, `bash -c 'A' && bash -c 'B'` (each check
#                   single-quoted; one check runs as written) — exactly the command
#                   triage-compare shows the candidates — in ONE process group under
#                   ONE --timeout, so a check may rely on what an earlier one left
#                   running (a server it started) until the whole run ends, and one
#                   check's own `||` never masks an earlier failure. rc is its exit.
#                   "rcs" (each check's rc, in order, up to the one that failed) and
#                   "failedCheck" (its 0-based index, null when all passed): known
#                   from the graded run with one check, or when all passed; with
#                   several checks and a failure they come only from --baseline-on's
#                   per-check rerun, else rcs is null (which check failed is unknown).
#   --overlay DIR   copied into the worktree AFTER the patch and BEFORE the check
#                   (hidden tests the candidates never saw). Its files never enter
#                   the diffstat. Never copied (overlay-failed) when it holds a
#                   stage-linked path, or when an entry's destination — or a directory
#                   above it — is a symlink the patch made (GNU cp writes through a
#                   destination symlink, possibly out of the worktree).
#   --timeout SECS  wall-clock limit for the graded run (and for each check of a
#                   --baseline-on per-check run; default 600). A run over it is killed
#                   and reported as rc 124.
#   --env-map FILE  the parity tool map (default $PARITY_ENV_MAP, else
#                   ~/.agents/parity/envs.json): a JSON object {"PARITY_<NAME>":
#                   "/abs/path", ...}. A check names a tool ONLY as "$PARITY_<NAME>"
#                   (never a real path — candidates see the checks); every PARITY_
#                   variable the check references is exported from the map when the
#                   check runs. A referenced variable the map lacks (or no map, or an
#                   invalid map) is exit 2 naming it, before anything runs. A check
#                   that references no PARITY_ variable never reads the map.
#   --baseline-on RCS  a comma-separated list of exit codes (triage-compare passes
#                   126,127: the check could not RUN). The BASELINE classification
#                   pass, the only place checks run one by one: when a patch's graded
#                   run exits with one of them, (a) with several checks the patch is
#                   re-graded check by check (each its own `bash -c`, process group and
#                   --timeout, stopping at the first failure) to find WHICH check it
#                   was — kept (rcs, failedCheck) only when that rerun fails with the
#                   same rc, else rcs null (unknown); and (b) the result gets "baseRc":
#                   THAT check's rc on the PRISTINE base, and "baseRcs": every check's
#                   rc there. The base is an empty patch graded the same way (links,
#                   overlay), run once, on first need, check by check with EVERY check
#                   run even past a failure. baseRc and baseRcs are null when the base
#                   could not be graded or the failing check is unknown. The caller
#                   (triage-compare's gradeOf) owns the verdict: missing toolchain,
#                   candidate fail, or inconclusive.
#   --summary       print ONE line instead of one per patch:
#                     PATCHCHECK {"base":"<sha>","results":[{patch, applies, rc, rcs,
#                       failedCheck, diffstat, files, filesTruncated, tailFile[, error]
#                       [, baseRc, baseRcs]}, ...]}
#                   and write each patch's tail to --tail-dir DIR/<n>.tail (n = its
#                   argument position) — so a relay copying the line never sees
#                   candidate-written check output. files = the paths the applied
#                   patch changes (at most 200, then filesTruncated:true), before
#                   the overlay. Requires --tail-dir.
#   --print-env     print the `export PARITY_X='...'` lines for the variables the
#                   checks reference (nothing when they reference none) and exit 0 — the
#                   same resolution, same exit 2; no --repo/--base/PATCH needed.
#                   SINGLE OWNER of the env-map rule (parity-suite.sh calls this).
#
# Check environment: besides the mapped PARITY_ variables, every check runs with
# XDG_CACHE_HOME, TMPDIR and GRANTFORGE_CACHE_DIR pointed at a fresh per-patch
# temp dir next to the grading worktree (removed with it), so a check never
# refreshes a real user cache (grantforge honours GRANTFORGE_CACHE_DIR). The
# source-bound import settings in SOURCE_BOUND_ENV (PYTHONPATH, PYTHONHOME,
# PYTHONSTARTUP, NODE_PATH, PERL5LIB) are UNSET: inherited from the caller they could
# point the check at the source repo's code (a module the patch deleted would still
# import). Nothing else is added: there is no per-repo stage env (a tracked
# .triage-stage-env is ignored — stage links are only for self-contained toolchains,
# see "Stage links").
#
# Output: one JSON line per PATCH, in argument order, on stdout:
#   {"patch":"<as given>","applies":true|false,"rc":<int>|null,"rcs":[<int>...]|null,
#    "failedCheck":<int>|null,"diffstat":"<shortstat of the applied patch>",
#    "tail":"<last 20 lines>"[,"error":"overlay-failed"|"harness"]
#    [,"baseRc":<int>|null,"baseRcs":[<int>...]|null]}
#   (rcs is [] and failedCheck null when no check ran; rcs null when several checks
#   ran and which one failed is unknown — see --check.)
#   - applies:false => rc:null, the check never ran, tail says why.
#   - error:"overlay-failed" (applies:true, rc:null): the patch applied but the
#     --overlay copy failed, so the hidden tests are missing and the check was NOT
#     run — this patch is UNGRADABLE, never a pass or a fail.
#   - error:"harness" (applies:false, rc:null): the grader itself failed (patch
#     file missing, no temp dir, no worktree, a failed stage-link step) —
#     UNGRADABLE, never the candidate's fail. `error` is present only in these two
#     cases (an overlay holding a stage-linked path is "overlay-failed" too).
#   - an EMPTY patch file applies trivially (diffstat "") and the check still runs,
#     so a candidate that changed nothing is graded, not skipped.
#   - `git apply --binary` first, `git apply --3way` as the fallback (needs the
#     index blobs the patch names; a 3-way conflict is applies:false).
#
# Stage links: every grading worktree gets exactly the links a candidate's staged
# worktree got — the repo's opt-in, TRACKED .triage-stage-links (its gitignored
# toolchain, e.g. .venv) via `stage-worktree.sh link --base <the base sha>`, the
# ONE owner of that rule (read at the sha, so the candidates and every grading
# worktree share one grant however HEAD moves; refusals; which paths). It links only
# SELF-CONTAINED toolchains: one that refers back to the repo (an editable install, a
# relative .pth into it, a node_modules symlink to a workspace package) is refused, so
# the check exits 127 on the patch and the pristine base alike (check-environment) —
# never graded against the source repo's code. No such file at the sha = no links,
# no change. The links exist ONLY while
# the check runs, never while the patch is applied or the overlay copied (a `git
# apply --3way` fallback, and GNU cp, write THROUGH a symlink they meet), so
# neither can reach the real repo through one (grade_one()):
#   1. link the PRISTINE worktree (the set L the candidates had), then remove
#      those symlinks again;
#   2. apply the patch and take diffstat/files (no link exists: none is counted);
#   3. the --overlay, still with no link: one holding a linked path, or meeting a
#      symlink the patch made, is error:"overlay-failed" — never copied, the check
#      not run; else it is copied;
#   4. link again. A result other than L means the patch
#      occupies a linked path (e.g. it adds files under .venv/, or makes .venv
#      itself) — REJECTED: applies:false, rc:null, never graded against a
#      toolchain it supplied;
#   5. the checks run with the links. What THEY write through a
#      link is NOT prevented: it lands in the real repo, exactly as in a staged
#      worktree, and is DETECTED afterwards — the bake-off's leakcheck (run after
#      grading) reports it unless .triage-leakignore excludes it.
# Removal never follows a link. A link step that fails, or whose output is not
# exactly one well-formed result (empty, two objects, a bad member, a non-null "env"
# from an outdated owner), is error:"harness" — never "no links". A missing
# stage-worktree.sh beside this
# script is exit 2 (a broken install).
#
# Exit codes: 0 = every patch was reported (pass/fail/ungradable is in the JSON);
#             2 = usage error (bad flags, not a repo, unknown REV) — nothing ran.
#
# NOT a sandbox: the check runs candidate-written code (tests, Makefiles, scripts)
# with this user's rights, confined only by running in a disposable worktree.
set -uo pipefail

# Inherited git redirection (GIT_DIR & co. from a hook or a caller) would point
# every `git -C` below at another repository — -C does not override it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

REPO="" BASE="" OVERLAY="" TIMEOUT=600 ENV_MAP="" PRINT_ENV=0 SUMMARY=0 TAIL_DIR="" BASELINE_ON=""
CHECKS=()
usage() { echo "USAGE: $1" >&2; exit 2; }

# A value-taking flag with no value is a usage error — never a `shift 2` that
# fails without shifting and loops forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--base|--check|--overlay|--timeout|--env-map|--tail-dir|--baseline-on) [ $# -ge 2 ] || usage "$1 needs a value" ;;
  esac
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --check)   CHECKS+=("$2"); shift 2 ;;
    --overlay) OVERLAY="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --env-map) ENV_MAP="$2"; shift 2 ;;
    --tail-dir) TAIL_DIR="$2"; shift 2 ;;
    --baseline-on) BASELINE_ON="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    --print-env) PRINT_ENV=1; shift ;;
    --)        shift; break ;;
    -*)        usage "unknown flag $1" ;;
    *)         break ;;
  esac
done

[ "${#CHECKS[@]}" -gt 0 ] || usage "--check is required"
for c in "${CHECKS[@]}"; do [ -n "$c" ] || usage "--check must not be empty"; done
command -v jq >/dev/null 2>&1 || usage "jq is required"

# SOURCE_BOUND_ENV — SINGLE OWNER of the import settings a check never inherits: each
# can point an interpreter at the SOURCE repo's code (PYTHONPATH=<repo>/src imports a
# module the patch deleted), which no self-contained toolchain can undo. run_check()
# unsets them for every check process (graded run, per-check rerun, pristine base).
SOURCE_BOUND_ENV=(PYTHONPATH PYTHONHOME PYTHONSTARTUP NODE_PATH PERL5LIB)

# COMBINED — the graded command: one check as written; several as `bash -c 'A' &&
# bash -c 'B'`, each single-quoted exactly as triage-compare.js's shq() quotes it (so
# it is the command the candidates are shown), one process, one process group.
shq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
if [ "${#CHECKS[@]}" -eq 1 ]; then COMBINED=${CHECKS[0]}
else
  COMBINED=""
  for c in "${CHECKS[@]}"; do COMBINED="$COMBINED${COMBINED:+ && }bash -c $(shq "$c")"; done
fi

# resolve_env — SINGLE OWNER of the PARITY_ env-map rule. Sets ENV_LINES to the
# `export NAME='value'` lines for every PARITY_ variable the checks reference (empty
# when it references none — the map is then never read). Exit 2 naming the
# variable when it is unmapped, when the map is missing or invalid, or when a
# $PARITY_... reference is not a valid PARITY_[A-Z0-9_]+ name.
ENV_LINES=""
resolve_env() {
  local refs bad map unmapped
  # bash takes the longest [A-Za-z0-9_] run as the name, so capture exactly that.
  refs=$(printf '%s\n' "${CHECKS[@]}" | grep -oE '\$\{?PARITY_[A-Za-z0-9_]*' | sed 's/^\$[{]*//' | sort -u)
  [ -n "$refs" ] || return 0
  bad=$(printf '%s\n' "$refs" | grep -vE '^PARITY_[A-Z0-9_]+$' | tr '\n' ' ')
  [ -z "$bad" ] || usage "the check references ${bad% }: a tool variable must be named PARITY_[A-Z0-9_]+"
  map="${ENV_MAP:-${PARITY_ENV_MAP:-${HOME:-}/.agents/parity/envs.json}}"
  [ -f "$map" ] || usage "the check references $(printf '%s\n' "$refs" | tr '\n' ' ')but there is no env map at $map (--env-map / PARITY_ENV_MAP)"
  jq -e 'type == "object" and all(to_entries[]; (.key | test("^PARITY_[A-Z0-9_]+$")) and (.value | type == "string" and startswith("/")))' "$map" >/dev/null 2>&1 ||
    usage "env map $map must be a JSON object {\"PARITY_<NAME>\": \"/abs/path\"}"
  unmapped=$(printf '%s\n' "$refs" | jq -Rr --slurpfile m "$map" 'select(length > 0) | . as $k | select($m[0] | has($k) | not)' | tr '\n' ' ')
  [ -z "$unmapped" ] || usage "unmapped PARITY_ variable(s) referenced by the check: ${unmapped% } (env map $map)"
  ENV_LINES=$(printf '%s\n' "$refs" | jq -Rr --slurpfile m "$map" 'select(length > 0) | . as $k | "export \($k)=\($m[0][$k] | @sh)"')
}
resolve_env
if [ "$PRINT_ENV" -eq 1 ]; then
  [ -z "$ENV_LINES" ] || printf '%s\n' "$ENV_LINES"
  exit 0
fi

[ -n "$REPO" ] || usage "--repo is required"
[ -n "$BASE" ] || usage "--base is required"
[ $# -gt 0 ] || usage "at least one PATCH is required"
case "$TIMEOUT" in ''|*[!0-9]*) usage "--timeout must be a whole number of seconds" ;; esac
if [ -n "$BASELINE_ON" ]; then
  printf '%s' "$BASELINE_ON" | grep -qE '^[0-9]{1,3}(,[0-9]{1,3})*$' || usage "--baseline-on must be a comma-separated list of exit codes (e.g. 126,127)"
fi
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage "--repo is not a git work tree: $REPO"
REPO=$(git -C "$REPO" rev-parse --show-toplevel)
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $REPO: $BASE"
if [ -n "$OVERLAY" ] && [ ! -d "$OVERLAY" ]; then usage "--overlay is not a directory: $OVERLAY"; fi
if [ "$SUMMARY" -eq 1 ]; then
  [ -n "$TAIL_DIR" ] || usage "--summary needs --tail-dir"
  case "$TAIL_DIR" in /*) ;; *) usage "--tail-dir must be an absolute path" ;; esac
  mkdir -p "$TAIL_DIR" || usage "could not create --tail-dir $TAIL_DIR"
fi

# The stage-link rule's ONE owner (see "Stage links" above).
STAGE_WT="$(cd "$(dirname "$0")" && pwd)/stage-worktree.sh"
[ -x "$STAGE_WT" ] || usage "stage-worktree.sh is missing beside patch-check.sh (it owns the stage links): $STAGE_WT"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/patch-check.XXXXXX") || usage "could not create a temp dir"
ROOT=$(cd "$ROOT" && pwd -P)
WT=""   # the worktree currently checked out, if any
CACHE=""  # its per-patch cache/temp dir (a sibling under $ROOT), if any
RUN_PID=""  # the running check (leads its own process group), if any

# cleanup_wt — SINGLE OWNER of worktree removal: the directory AND git's
# bookkeeping for it, and its per-patch cache dir. Called after every patch and
# from the exit trap.
cleanup_wt() {
  [ -n "$CACHE" ] && rm -rf "$CACHE"
  CACHE=""
  [ -n "$WT" ] || return 0
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  git -C "$REPO" worktree prune >/dev/null 2>&1
  WT=""
}
on_exit() { if [ -n "$RUN_PID" ]; then reap_tree "$RUN_PID"; RUN_PID=""; fi; cleanup_wt; rm -rf "$ROOT"; }
trap on_exit EXIT
trap 'exit 130' INT TERM

# emit — one result. Per-patch mode prints it; --summary keeps it (tail moved to
# $TAIL_DIR/<n>.tail) for the single PATCHCHECK line printed at the end. $FILES
# is the changed-path list of the patch just applied (empty when none).
SUMMARY_LINES="$ROOT/summary.jsonl"
: > "$SUMMARY_LINES"
FILES=""
emit() { # $1 patch, $2 applies(true|false), $3 rc(int|null), $4 diffstat, $5 tail file, $6 error ("" = none),
         # $7 rcs (space-separated, "" = none ran, "null" = unknown), $8 failedCheck ("" = null),
         # $9 baseRc ("" = absent | int | null), $10 baseRcs (JSON array or null; with $9)
  local rcs="[${7// /,}]" fc="${8:-null}"
  [ "$7" != null ] || rcs=null
  if [ "$SUMMARY" -eq 1 ]; then
    cp "$5" "$TAIL_DIR/$n.tail" 2>/dev/null || : > "$TAIL_DIR/$n.tail"
    printf '%s' "$FILES" | jq -R -s -c --arg patch "$1" --argjson applies "$2" --argjson rc "$3" --arg diffstat "$4" \
      --arg tf "$TAIL_DIR/$n.tail" --arg error "${6:-}" --argjson rcs "$rcs" --argjson fc "$fc" --arg brc "${9:-}" --arg brcs "${10:-null}" \
      'split("\u0001") | map(select(length > 0)) as $f
       | {patch:$patch, applies:$applies, rc:$rc, rcs:$rcs, failedCheck:$fc, diffstat:$diffstat, files:($f[:200]), filesTruncated:(($f | length) > 200), tailFile:$tf}
         + (if $error == "" then {} else {error:$error} end) + (if $brc == "" then {} else {baseRc:($brc | fromjson), baseRcs:($brcs | fromjson)} end)' >> "$SUMMARY_LINES"
    return
  fi
  jq -nc --arg patch "$1" --argjson applies "$2" --argjson rc "$3" --arg diffstat "$4" \
    --rawfile tail "$5" --arg error "${6:-}" --argjson rcs "$rcs" --argjson fc "$fc" --arg brc "${9:-}" --arg brcs "${10:-null}" \
    '{patch:$patch, applies:$applies, rc:$rc, rcs:$rcs, failedCheck:$fc, diffstat:$diffstat, tail:($tail | rtrimstr("\n"))}
     + (if $error == "" then {} else {error:$error} end) + (if $brc == "" then {} else {baseRc:($brc | fromjson), baseRcs:($brcs | fromjson)} end)'
}

# kill_tree SIG PID — PID and every descendant still attached by parentage, leaves
# first; each process is frozen (STOP) before its children are listed.
kill_tree() {
  local kid
  kill -STOP "$2" 2>/dev/null || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for kid in $(pgrep -P "$2" 2>/dev/null); do kill_tree "$1" "$kid"; done
  fi
  kill "-$1" "$2" 2>/dev/null
  kill -CONT "$2" 2>/dev/null
}
# reap_tree PID [reaped] — PID leads its own process group (started under set -m),
# which an orphaned grandchild keeps: TERM tree + group, 2s grace, KILL the rest,
# wait until the group is empty. "reaped": PID was already waited for, so only the
# group is signalled (the bare pid may have been reused).
reap_tree() {
  local n=0
  [ "${2:-}" = reaped ] || kill_tree TERM "$1"
  kill -TERM -- "-$1" 2>/dev/null
  while [ "$n" -lt 20 ] && [ -n "$(pgrep -g "$1" 2>/dev/null)" ]; do sleep 0.1; n=$((n + 1)); done
  [ "${2:-}" = reaped ] || kill_tree KILL "$1"
  kill -KILL -- "-$1" 2>/dev/null
  n=0
  while [ "$n" -lt 20 ] && [ -n "$(pgrep -g "$1" 2>/dev/null)" ]; do sleep 0.1; n=$((n + 1)); done
  [ "${2:-}" = reaped ] || wait "$1" 2>/dev/null
}

# run_check LOG CMD — one command in the worktree, its output appended to LOG,
# bash-3.2-safe wall-clock watchdog (--timeout). Sets RC.
# The command is its own process group (set -m), so the watchdog and reap_tree reach
# its whole tree: nothing it spawned outlives it (or the worktree removal).
# Its environment: SOURCE_BOUND_ENV unset, the mapped PARITY_ tool variables
# (ENV_LINES), and every cache / temp location pointed at this patch's own CACHE dir —
# a check never writes a real user cache (grant-forge's regenerable caches honour
# GRANTFORGE_CACHE_DIR).
run_check() {
  set -m
  ( cd "$WT" && unset "${SOURCE_BOUND_ENV[@]}" && export XDG_CACHE_HOME="$CACHE" TMPDIR="$CACHE" GRANTFORGE_CACHE_DIR="$CACHE" && eval "$ENV_LINES" && exec bash -c "$2" ) >> "$1" 2>&1 < /dev/null &
  RUN_PID=$!
  set +m
  local cpid=$RUN_PID mark="$ROOT/timed-out"
  rm -f "$mark"
  ( sleep "$TIMEOUT"
    kill -0 "$cpid" 2>/dev/null || exit 0
    : > "$mark"; kill_tree TERM "$cpid"; kill -TERM -- "-$cpid" 2>/dev/null
    sleep 2; kill_tree KILL "$cpid"; kill -KILL -- "-$cpid" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$! wdkids
  wait "$cpid" 2>/dev/null
  RC=$?
  # Stop the watchdog (and its pending sleep); reap_tree, not the watchdog's
  # delayed KILL, guarantees nothing of the check survives.
  wdkids=$(pgrep -P "$wd" 2>/dev/null)
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  # shellcheck disable=SC2086  # a whitespace-separated pid list
  [ -n "$wdkids" ] && kill $wdkids 2>/dev/null
  reap_tree "$cpid" reaped
  RUN_PID=""
  if [ -f "$mark" ]; then
    RC=124
    echo "patch-check: check timed out after ${TIMEOUT}s" >> "$1"
  fi
}
# run_checks LOG combined|stop|all — the checks in $WT, into LOG (emptied first).
# combined: THE GRADE — COMBINED in one run_check (one process group, one timeout).
# The per-check modes run only in the --baseline-on classification pass, each check its
# own run_check: stop — up to the first that fails (which check a graded 126/127 was);
# all — every check, past a failure (the pristine base, so each check has ITS own rc).
# Sets RC (the run's rc / the first failing check's, 0 when none failed), RCS (the rcs
# of the checks that ran, space-separated, in order; "null" when several ran combined
# and one failed — which one is unknown) and FAILED (the first failing check's 0-based
# index, "" when none failed or unknown).
RCS="" FAILED=""
run_checks() {
  local i=0 first=0 c
  RCS="" FAILED=""
  : > "$1"
  if [ "$2" = combined ]; then
    run_check "$1" "$COMBINED"
    if [ "${#CHECKS[@]}" -eq 1 ]; then RCS=$RC; [ "$RC" -eq 0 ] || FAILED=0
    elif [ "$RC" -eq 0 ]; then for c in "${CHECKS[@]}"; do RCS="$RCS${RCS:+ }0"; done
    else RCS=null
    fi
    return 0
  fi
  for c in "${CHECKS[@]}"; do
    run_check "$1" "$c"
    RCS="$RCS${RCS:+ }$RC"
    if [ "$RC" -ne 0 ] && [ -z "$FAILED" ]; then
      FAILED=$i first=$RC
      [ "$2" = all ] || break
    fi
    i=$((i + 1))
  done
  if [ "${#CHECKS[@]}" -gt 1 ] && [ -n "$FAILED" ]; then echo "patch-check: check $((FAILED + 1)) of ${#CHECKS[@]} exited $first" >> "$1"; fi
  RC=$first
}

# link_wt OUT ERR — `stage-worktree.sh link` on $WT, at the bake-off's base sha
# (the owner reads the grants there: every grading worktree gets the candidates' grant
# however HEAD moves): the linked paths, one per line, into OUT (in the owner's order),
# its stderr (refusal warnings) into ERR. rc != 0 unless the owner exited 0 AND
# printed EXACTLY ONE well-formed result: step "link", links an array of normalized
# relative paths, refused an array, and no "env" other than null (an outdated owner that
# still lifts a refusal for a stage env — retired: it would link a bound toolchain). No
# output, two objects or a bad member is a FAILED link step — never "no links".
link_wt() {
  local js
  js=$("$STAGE_WT" link --repo "$REPO" --base "$BASE_SHA" --worktree "$WT" 2> "$2") || return 1
  printf '%s\n' "$js" | jq -s -r '
    if length == 1 and (.[0] | type) == "object" and .[0].step == "link"
       and (.[0].links | type) == "array"
       and all(.[0].links[]; type == "string" and (startswith("/") | not) and (split("/") | all(. != "" and . != "." and . != "..")))
       and (.[0].refused | type) == "array"
       and .[0].env == null
    then .[0].links[] else error("no well-formed link result") end' > "$1" 2>> "$2" || return 1
}
# unlink_wt LIST — removes the symlinks LIST names from $WT (rm on a symlink never
# touches its target). rc 1 when one is still there.
unlink_wt() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -L "$WT/$p" ]; then rm -f "$WT/$p" || return 1; fi
    [ ! -L "$WT/$p" ] || return 1
  done < "$1"
}
# overlay_hit LINKS — why the --overlay cannot be copied into $WT, or nothing: an
# overlay entry at (or under) a stage-linked path of LINKS, or an overlay entry whose
# destination in $WT — or a directory above it inside $WT — is a symlink (the patch
# made one: GNU cp writes THROUGH a destination symlink, possibly out of the worktree).
# rc 1 when the overlay could not be listed (never "no hit").
overlay_hit() {
  local lp
  while IFS= read -r lp; do
    [ -n "$lp" ] || continue
    if [ -e "$OVERLAY/$lp" ] || [ -L "$OVERLAY/$lp" ]; then echo "it holds $lp, a stage-linked path (.triage-stage-links)"; return 0; fi
  done < "$1"
  # A hit prints and stops early (find may then die of SIGPIPE): the caller reads a
  # non-empty answer as the hit whatever the rc, and only an EMPTY one with rc != 0 as
  # a listing failure.
  # shellcheck disable=SC2016  # $vars below are perl's
  ( set -o pipefail
    cd "$OVERLAY" && find . -mindepth 1 -print0 | perl -0ne '
      BEGIN { $wt = shift @ARGV }
      chomp; s{^\./}{}; my $at = $wt;
      for my $c (split m{/}) { $at .= "/$c";
        if (-l $at) { print "its $_ would be copied through $at, a symlink in the patched worktree\n"; exit 0 }
        last unless -e $at }' "$WT" )
}

# grade_one ABS TAG [combined|stop|all] — grades ONE patch file in its own fresh worktree
# ($ROOT/wt-TAG): sets G_APPLIES (true|false), G_RC (int|null), G_RCS / G_FAILED (each
# check's rc / the failing check's index, run_checks() in the mode given, default
# combined — the grade; "" when no check ran), G_DIFFSTAT, G_ERROR ("" | harness | overlay-failed), G_TAIL (the
# file the result's tail comes from) and FILES (the changed paths). Every exit path
# removes the worktree. The steps (header "Stage links"):
#   1. link the pristine worktree — the set L0 the candidates had — then unlink it;
#   2. apply the patch and take diffstat/files: no link exists;
#   3. the overlay: refused when it holds a linked path or meets a symlink the patch
#      made (overlay-failed), else copied — still with no link;
#   4. link again (L1): L1 != L0 means the patch occupies a linked path — REJECTED
#      (applies false), never graded with what it supplied;
#   5. run the checks with the links.
G_APPLIES=false G_RC=null G_RCS="" G_FAILED="" G_DIFFSTAT="" G_ERROR="" G_TAIL=""
grade_one() {
  local abs="$1" tag="$2" mode="${3:-combined}" log="$ROOT/$2.log" L0="$ROOT/$2.links0" L1="$ROOT/$2.links1" ds="" hit
  G_APPLIES=false G_RC=null G_RCS="" G_FAILED="" G_DIFFSTAT="" G_ERROR="" G_TAIL="$log" FILES=""
  : > "$log"
  # Harness faults (no patch file, no temp dir, no worktree, a link step) are the
  # grader's, never the candidate's: error "harness", ungradable.
  if [ ! -f "$abs" ]; then
    echo "patch-check: patch file not found: $abs" > "$log"; G_ERROR=harness; return
  fi
  WT="$ROOT/wt-$tag"
  CACHE="$ROOT/cache-$tag"
  mkdir -p "$CACHE" || { echo "patch-check: could not create $CACHE" > "$log"; CACHE=""; WT=""; G_ERROR=harness; return; }
  # Hooks off: a post-checkout hook must not run (or write) on the grader's behalf.
  if ! git -C "$REPO" -c core.hooksPath=/dev/null worktree add --detach "$WT" "$BASE_SHA" > "$log" 2>&1; then
    echo "patch-check: could not create a worktree at $BASE" >> "$log"
    WT=""; cleanup_wt; G_ERROR=harness; return
  fi
  # Step 1: L0, then gone again before anything is written into the worktree.
  if ! link_wt "$L0" "$log.link0" || ! unlink_wt "$L0"; then
    { echo "patch-check: the stage-link step failed on the pristine worktree:"; cat "$log.link0"; } >> "$log"
    G_ERROR=harness; cleanup_wt; return
  fi
  # Step 2.
  if [ -s "$abs" ]; then
    if git -C "$WT" apply --binary "$abs" > "$log" 2>&1; then :
    elif git -C "$WT" apply --3way "$abs" >> "$log" 2>&1; then :
    else
      tail -n 20 "$log" > "$log.tail"; G_TAIL="$log.tail"; cleanup_wt; return
    fi
    git -C "$WT" add -A > /dev/null 2>&1
    ds=$(git -C "$WT" diff --cached --shortstat "$BASE_SHA" 2>/dev/null | sed 's/^ *//')
    FILES=$(git -C "$WT" -c core.quotePath=false diff --cached --name-only -z --no-renames "$BASE_SHA" 2>/dev/null | tr '\000' '\001')
  fi
  # Step 3. The overlay IS the hidden tests: without it the check would grade against
  # the candidate's own tests only. A refused or failed copy is fatal for this patch —
  # applies:true, rc:null, error:"overlay-failed" — never a pass or a fail.
  if [ -n "$OVERLAY" ]; then
    hit=$(overlay_hit "$L0") || [ -n "$hit" ] || hit="its entries could not be listed"
    if [ -n "$hit" ]; then
      echo "patch-check: the overlay was NOT copied — $hit; the check was NOT run, this patch is ungradable" >> "$log"
      tail -n 20 "$log" > "$log.tail"
      G_APPLIES=true G_DIFFSTAT="$ds" G_ERROR=overlay-failed G_TAIL="$log.tail"; cleanup_wt; return
    fi
    if ! cp -R "$OVERLAY"/. "$WT"/ 2>> "$log"; then
      echo "patch-check: overlay copy failed — the hidden tests are missing, so the check was NOT run; this patch is ungradable" >> "$log"
      tail -n 20 "$log" > "$log.tail"
      G_APPLIES=true G_DIFFSTAT="$ds" G_ERROR=overlay-failed G_TAIL="$log.tail"; cleanup_wt; return
    fi
  fi
  # Step 4: the same links again, right before the check — or the patch is rejected.
  if ! link_wt "$L1" "$log.link1"; then
    { echo "patch-check: the stage-link step failed on the patched worktree:"; cat "$log.link1"; } >> "$log"
    FILES=""; G_ERROR=harness; cleanup_wt; return
  fi
  if ! cmp -s "$L0" "$L1"; then
    { cat "$log.link1"
      echo "patch-check: REJECTED — the patch occupies a stage-linked path from .triage-stage-links (linked before: $(paste -sd, - < "$L0"); after the patch: $(paste -sd, - < "$L1")), so the repo's toolchain could not be linked; the patch is not graded"
    } >> "$log"
    tail -n 20 "$log" > "$log.tail"
    FILES=""; G_TAIL="$log.tail"; cleanup_wt; return
  fi
  # Step 5.
  run_checks "$log" "$mode"
  # The owner's refusal warnings (entries NOT linked) close the tail: a check that
  # exits 127 for want of a toolchain says why.
  cat "$log.link1" >> "$log"
  tail -n 20 "$log" > "$log.tail"
  G_APPLIES=true G_RC="$RC" G_RCS="$RCS" G_FAILED="$FAILED" G_DIFFSTAT="$ds" G_TAIL="$log.tail"
  cleanup_wt
}

# base_rcs — every check's rc on the PRISTINE base (an empty patch through grade_one:
# the same links and overlay, EVERY check run, past a failure), computed once, on the
# first patch whose failing check's rc is in --baseline-on: BASE_RCS, one rc per check;
# empty when the base could not be graded.
BASE_DONE=0 BASE_RCS=()
base_rcs() {
  [ "$BASE_DONE" -eq 0 ] || return 0
  BASE_DONE=1
  : > "$ROOT/baseline.patch"
  grade_one "$ROOT/baseline.patch" base all
  if [ "$G_APPLIES" = true ] && [ -z "$G_ERROR" ] && [ "$G_RC" != null ]; then read -r -a BASE_RCS <<< "$G_RCS"; fi
}

n=0
for patch in "$@"; do
  n=$((n + 1))
  case "$patch" in /*) abs="$patch" ;; *) abs="$PWD/$patch" ;; esac
  grade_one "$abs" "$n"
  p_app=$G_APPLIES p_rc=$G_RC p_rcs=$G_RCS p_failed=$G_FAILED p_ds=$G_DIFFSTAT p_tail=$G_TAIL p_err=$G_ERROR p_files=$FILES brc="" brcs=""
  # The BASELINE classification pass — the only per-check runs. A graded run that exits
  # with an --baseline-on status (126/127: a check could not RUN): (a) with several
  # checks, which one is found by re-grading the patch check by check (kept only when
  # that rerun fails with the same rc — else unknown, rcs null); (b) THAT check is
  # compared with the same check on the pristine base: baseRc (baseRcs: every check's
  # rc there). The verdict is the caller's (triage-compare's gradeOf).
  if [ -n "$BASELINE_ON" ] && [ "$p_app" = true ] && [ -z "$p_err" ] && [ "$p_rc" != null ]; then
    case ",$BASELINE_ON," in
      *",$p_rc,"*)
        if [ "${#CHECKS[@]}" -gt 1 ]; then
          grade_one "$abs" "$n-checks" stop
          if [ "$G_APPLIES" = true ] && [ -z "$G_ERROR" ] && [ "$G_RC" = "$p_rc" ] && [ -n "$G_FAILED" ]; then
            p_rcs=$G_RCS p_failed=$G_FAILED
            echo "patch-check: run check by check, check $((p_failed + 1)) of ${#CHECKS[@]} exits $p_rc (rcs: $p_rcs)" >> "$p_tail"
          else
            echo "patch-check: run check by check, the patch did not fail with $p_rc again (rc $G_RC, rcs: ${G_RCS:-none}): which check exited $p_rc is unknown" >> "$p_tail"
          fi
        fi
        if [ -n "$p_failed" ]; then
          base_rcs
          if [ "${#BASE_RCS[@]}" -gt 0 ]; then brc=${BASE_RCS[$p_failed]:-null}; brcs="[$(IFS=,; printf '%s' "${BASE_RCS[*]}")]"; else brc=null brcs=null; fi
          echo "patch-check: the same check (check $((p_failed + 1)) of ${#CHECKS[@]}) on the pristine base exited $brc" >> "$p_tail"
        else
          brc=null brcs=null
        fi ;;
    esac
  fi
  FILES=$p_files
  emit "$patch" "$p_app" "$p_rc" "$p_ds" "$p_tail" "$p_err" "$p_rcs" "$p_failed" "$brc" "$brcs"
done
if [ "$SUMMARY" -eq 1 ]; then
  jq -s -c --arg base "$BASE_SHA" '{base:$base, results:.}' "$SUMMARY_LINES" | sed 's/^/PATCHCHECK /'
fi
exit 0
