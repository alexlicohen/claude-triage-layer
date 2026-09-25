#!/bin/bash
# scripts/patch-check.sh — the independent grader of a bake-off (workflows/
# triage-compare.js). Applies each candidate patch to its OWN fresh worktree of
# the caller's repo at a fixed base revision, runs the objective check there, and
# reports the result. It never applies anything to the caller's working tree or
# index: the only thing it writes into the repo is git's own worktree bookkeeping
# under .git/worktrees, which it removes again (git worktree remove + prune) after
# every patch and on every exit path.
#
# Usage:
#   scripts/patch-check.sh --repo DIR --base REV --check CMD [--overlay DIR]
#                          [--timeout SECS] [--env-map FILE]
#                          [--summary --tail-dir DIR] PATCH...
#   scripts/patch-check.sh --print-env --check CMD [--env-map FILE]
#
#   --repo DIR      the git repo the candidates were built against.
#   --base REV      the revision every patch applies to (e.g. HEAD).
#   --check CMD     run with `bash -c` from the worktree root after the patch is
#                   applied; its exit code is the grade.
#   --overlay DIR   copied into the worktree AFTER the patch and BEFORE the check
#                   (hidden tests the candidates never saw). Its files never enter
#                   the diffstat.
#   --timeout SECS  wall-clock limit for one check (default 600). A check that runs
#                   over is killed and reported as rc 124.
#   --env-map FILE  the parity tool map (default $PARITY_ENV_MAP, else
#                   ~/.agents/parity/envs.json): a JSON object {"PARITY_<NAME>":
#                   "/abs/path", ...}. A check names a tool ONLY as "$PARITY_<NAME>"
#                   (never a real path — candidates see the checks); every PARITY_
#                   variable the check references is exported from the map when the
#                   check runs. A referenced variable the map lacks (or no map, or an
#                   invalid map) is exit 2 naming it, before anything runs. A check
#                   that references no PARITY_ variable never reads the map.
#   --summary       print ONE line instead of one per patch:
#                     PATCHCHECK {"base":"<sha>","results":[{patch, applies, rc,
#                       diffstat, files, filesTruncated, tailFile[, error]}, ...]}
#                   and write each patch's tail to --tail-dir DIR/<n>.tail (n = its
#                   argument position) — so a relay copying the line never sees
#                   candidate-written check output. files = the paths the applied
#                   patch changes (at most 200, then filesTruncated:true), before
#                   the overlay. Requires --tail-dir.
#   --print-env     print the `export PARITY_X='...'` lines for the variables CMD
#                   references (nothing when it references none) and exit 0 — the
#                   same resolution, same exit 2; no --repo/--base/PATCH needed.
#                   SINGLE OWNER of the env-map rule (parity-suite.sh calls this).
#
# Check environment: besides the mapped PARITY_ variables, every check runs with
# XDG_CACHE_HOME, TMPDIR and GRANTFORGE_CACHE_DIR pointed at a fresh per-patch
# temp dir next to the grading worktree (removed with it), so a check never
# refreshes a real user cache (grantforge honours GRANTFORGE_CACHE_DIR).
#
# Output: one JSON line per PATCH, in argument order, on stdout:
#   {"patch":"<as given>","applies":true|false,"rc":<int>|null,
#    "diffstat":"<shortstat of the applied patch>","tail":"<last 20 lines>"
#    [,"error":"overlay-failed"]}
#   - applies:false => rc:null, the check never ran, tail says why.
#   - error:"overlay-failed" (applies:true, rc:null): the patch applied but the
#     --overlay copy failed, so the hidden tests are missing and the check was NOT
#     run — this patch is UNGRADABLE, never a pass or a fail.
#   - error:"harness" (applies:false, rc:null): the grader itself failed (patch
#     file missing, no temp dir, no worktree) — UNGRADABLE, never the candidate's
#     fail. `error` is present only in these two cases.
#   - an EMPTY patch file applies trivially (diffstat "") and the check still runs,
#     so a candidate that changed nothing is graded, not skipped.
#   - `git apply --binary` first, `git apply --3way` as the fallback (needs the
#     index blobs the patch names; a 3-way conflict is applies:false).
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

REPO="" BASE="" CHECK="" OVERLAY="" TIMEOUT=600 ENV_MAP="" PRINT_ENV=0 SUMMARY=0 TAIL_DIR=""
usage() { echo "USAGE: $1" >&2; exit 2; }

# A value-taking flag with no value is a usage error — never a `shift 2` that
# fails without shifting and loops forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--base|--check|--overlay|--timeout|--env-map|--tail-dir) [ $# -ge 2 ] || usage "$1 needs a value" ;;
  esac
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --check)   CHECK="$2"; shift 2 ;;
    --overlay) OVERLAY="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --env-map) ENV_MAP="$2"; shift 2 ;;
    --tail-dir) TAIL_DIR="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    --print-env) PRINT_ENV=1; shift ;;
    --)        shift; break ;;
    -*)        usage "unknown flag $1" ;;
    *)         break ;;
  esac
done

[ -n "$CHECK" ] || usage "--check is required"
command -v jq >/dev/null 2>&1 || usage "jq is required"

# resolve_env — SINGLE OWNER of the PARITY_ env-map rule. Sets ENV_LINES to the
# `export NAME='value'` lines for every PARITY_ variable CHECK references (empty
# when it references none — the map is then never read). Exit 2 naming the
# variable when it is unmapped, when the map is missing or invalid, or when a
# $PARITY_... reference is not a valid PARITY_[A-Z0-9_]+ name.
ENV_LINES=""
resolve_env() {
  local refs bad map unmapped
  # bash takes the longest [A-Za-z0-9_] run as the name, so capture exactly that.
  refs=$(printf '%s\n' "$CHECK" | grep -oE '\$\{?PARITY_[A-Za-z0-9_]*' | sed 's/^\$[{]*//' | sort -u)
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
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage "--repo is not a git work tree: $REPO"
REPO=$(git -C "$REPO" rev-parse --show-toplevel)
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $REPO: $BASE"
if [ -n "$OVERLAY" ] && [ ! -d "$OVERLAY" ]; then usage "--overlay is not a directory: $OVERLAY"; fi
if [ "$SUMMARY" -eq 1 ]; then
  [ -n "$TAIL_DIR" ] || usage "--summary needs --tail-dir"
  case "$TAIL_DIR" in /*) ;; *) usage "--tail-dir must be an absolute path" ;; esac
  mkdir -p "$TAIL_DIR" || usage "could not create --tail-dir $TAIL_DIR"
fi

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
emit() { # $1 patch, $2 applies(true|false), $3 rc(int|null), $4 diffstat, $5 tail file, [$6 error]
  if [ "$SUMMARY" -eq 1 ]; then
    cp "$5" "$TAIL_DIR/$n.tail" 2>/dev/null || : > "$TAIL_DIR/$n.tail"
    printf '%s' "$FILES" | jq -R -s -c --arg patch "$1" --argjson applies "$2" --argjson rc "$3" --arg diffstat "$4" \
      --arg tf "$TAIL_DIR/$n.tail" --arg error "${6:-}" \
      'split("\u0001") | map(select(length > 0)) as $f
       | {patch:$patch, applies:$applies, rc:$rc, diffstat:$diffstat, files:($f[:200]), filesTruncated:(($f | length) > 200), tailFile:$tf}
         + (if $error == "" then {} else {error:$error} end)' >> "$SUMMARY_LINES"
    return
  fi
  jq -nc --arg patch "$1" --argjson applies "$2" --argjson rc "$3" --arg diffstat "$4" \
    --rawfile tail "$5" --arg error "${6:-}" \
    '{patch:$patch, applies:$applies, rc:$rc, diffstat:$diffstat, tail:($tail | rtrimstr("\n"))}
     + (if $error == "" then {} else {error:$error} end)'
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

# run_check — CHECK in the worktree, bash-3.2-safe wall-clock watchdog. Sets RC.
# The check is its own process group (set -m), so the watchdog and reap_tree reach
# its whole tree: nothing a check spawned outlives it (or the worktree removal).
# Its environment: the mapped PARITY_ tool variables (ENV_LINES), and every cache /
# temp location pointed at this patch's own CACHE dir — a check never writes a real
# user cache (grant-forge's regenerable caches honour GRANTFORGE_CACHE_DIR).
run_check() { # $1 = log file
  set -m
  ( cd "$WT" && export XDG_CACHE_HOME="$CACHE" TMPDIR="$CACHE" GRANTFORGE_CACHE_DIR="$CACHE" && eval "$ENV_LINES" && exec bash -c "$CHECK" ) > "$1" 2>&1 < /dev/null &
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

n=0
for patch in "$@"; do
  n=$((n + 1))
  log="$ROOT/$n.log"
  : > "$log"
  FILES=""
  case "$patch" in /*) abs="$patch" ;; *) abs="$PWD/$patch" ;; esac
  # Harness faults (no patch file, no temp dir, no worktree) are the grader's,
  # never the candidate's: error "harness", ungradable.
  if [ ! -f "$abs" ]; then
    echo "patch-check: patch file not found: $patch" > "$log"
    emit "$patch" false null "" "$log" harness; continue
  fi

  WT="$ROOT/wt-$n"
  CACHE="$ROOT/cache-$n"
  mkdir -p "$CACHE" || { echo "patch-check: could not create $CACHE" > "$log"; CACHE=""; WT=""; emit "$patch" false null "" "$log" harness; continue; }
  # Hooks off: a post-checkout hook must not run (or write) on the grader's behalf.
  if ! git -C "$REPO" -c core.hooksPath=/dev/null worktree add --detach "$WT" "$BASE_SHA" > "$log" 2>&1; then
    { echo "patch-check: could not create a worktree at $BASE"; } >> "$log"
    WT=""; cleanup_wt; emit "$patch" false null "" "$log" harness; continue
  fi

  applies=true diffstat=""
  if [ -s "$abs" ]; then
    if git -C "$WT" apply --binary "$abs" > "$log" 2>&1; then :
    elif git -C "$WT" apply --3way "$abs" >> "$log" 2>&1; then :
    else applies=false
    fi
    if [ "$applies" = true ]; then
      git -C "$WT" add -A > /dev/null 2>&1
      diffstat=$(git -C "$WT" diff --cached --shortstat "$BASE_SHA" 2>/dev/null | sed 's/^ *//')
      FILES=$(git -C "$WT" -c core.quotePath=false diff --cached --name-only -z --no-renames "$BASE_SHA" 2>/dev/null | tr '\000' '\001')
    fi
  fi
  if [ "$applies" = false ]; then
    tail -n 20 "$log" > "$log.tail"
    emit "$patch" false null "" "$log.tail"; cleanup_wt; continue
  fi

  # The overlay IS the hidden tests: without it the check would grade against the
  # candidate's own tests only. A failed copy is fatal for this patch —
  # applies:true, rc:null, error:"overlay-failed" — never a pass or a fail.
  if [ -n "$OVERLAY" ] && ! cp -R "$OVERLAY"/. "$WT"/ 2>> "$log"; then
    echo "patch-check: overlay copy failed — the hidden tests are missing, so the check was NOT run; this patch is ungradable" >> "$log"
    tail -n 20 "$log" > "$log.tail"
    emit "$patch" true null "$diffstat" "$log.tail" overlay-failed; cleanup_wt; continue
  fi
  run_check "$log"
  tail -n 20 "$log" > "$log.tail"
  emit "$patch" true "$RC" "$diffstat" "$log.tail"
  cleanup_wt
done
if [ "$SUMMARY" -eq 1 ]; then
  jq -s -c --arg base "$BASE_SHA" '{base:$base, results:.}' "$SUMMARY_LINES" | sed 's/^/PATCHCHECK /'
fi
exit 0
