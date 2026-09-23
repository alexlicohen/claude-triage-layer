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
#                          [--timeout SECS] PATCH...
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
#
# Output: one JSON line per PATCH, in argument order, on stdout:
#   {"patch":"<as given>","applies":true|false,"rc":<int>|null,
#    "diffstat":"<shortstat of the applied patch>","tail":"<last 20 lines>"}
#   - applies:false => rc:null, the check never ran, tail says why.
#   - an EMPTY patch file applies trivially (diffstat "") and the check still runs,
#     so a candidate that changed nothing is graded, not skipped.
#   - `git apply --binary` first, `git apply --3way` as the fallback (needs the
#     index blobs the patch names; a 3-way conflict is applies:false).
#
# Exit codes: 0 = every patch was graded (pass or fail is in the JSON);
#             2 = usage error (bad flags, not a repo, unknown REV) — nothing ran.
set -uo pipefail

REPO="" BASE="" CHECK="" OVERLAY="" TIMEOUT=600
usage() { echo "USAGE: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2 ;;
    --base)    BASE="${2:-}"; shift 2 ;;
    --check)   CHECK="${2:-}"; shift 2 ;;
    --overlay) OVERLAY="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    -*)        usage "unknown flag $1" ;;
    *)         break ;;
  esac
done

[ -n "$REPO" ] || usage "--repo is required"
[ -n "$BASE" ] || usage "--base is required"
[ -n "$CHECK" ] || usage "--check is required"
[ $# -gt 0 ] || usage "at least one PATCH is required"
case "$TIMEOUT" in ''|*[!0-9]*) usage "--timeout must be a whole number of seconds" ;; esac
command -v jq >/dev/null 2>&1 || usage "jq is required"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage "--repo is not a git work tree: $REPO"
REPO=$(git -C "$REPO" rev-parse --show-toplevel)
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $REPO: $BASE"
if [ -n "$OVERLAY" ] && [ ! -d "$OVERLAY" ]; then usage "--overlay is not a directory: $OVERLAY"; fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/patch-check.XXXXXX") || usage "could not create a temp dir"
ROOT=$(cd "$ROOT" && pwd -P)
WT=""   # the worktree currently checked out, if any

# cleanup_wt — SINGLE OWNER of worktree removal: the directory AND git's
# bookkeeping for it. Called after every patch and from the exit trap.
cleanup_wt() {
  [ -n "$WT" ] || return 0
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  git -C "$REPO" worktree prune >/dev/null 2>&1
  WT=""
}
on_exit() { cleanup_wt; rm -rf "$ROOT"; }
trap on_exit EXIT
trap 'exit 130' INT TERM

emit() { # $1 patch, $2 applies(true|false), $3 rc(int|null), $4 diffstat, $5 tail file
  jq -nc --arg patch "$1" --argjson applies "$2" --argjson rc "$3" --arg diffstat "$4" \
    --rawfile tail "$5" '{patch:$patch, applies:$applies, rc:$rc, diffstat:$diffstat, tail:($tail | rtrimstr("\n"))}'
}

# run_check — CHECK in the worktree, bash-3.2-safe wall-clock watchdog. Sets RC.
run_check() { # $1 = log file
  ( cd "$WT" && exec bash -c "$CHECK" ) > "$1" 2>&1 < /dev/null &
  local cpid=$! mark="$ROOT/timed-out"
  rm -f "$mark"
  ( sleep "$TIMEOUT"
    kill -0 "$cpid" 2>/dev/null || exit 0
    : > "$mark"; pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null
    sleep 2; pkill -KILL -P "$cpid" 2>/dev/null; kill -KILL "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$!
  wait "$cpid" 2>/dev/null
  RC=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
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
  case "$patch" in /*) abs="$patch" ;; *) abs="$PWD/$patch" ;; esac
  if [ ! -f "$abs" ]; then
    echo "patch-check: patch file not found: $patch" > "$log"
    emit "$patch" false null "" "$log"; continue
  fi

  WT="$ROOT/wt-$n"
  # Hooks off: a post-checkout hook must not run (or write) on the grader's behalf.
  if ! git -C "$REPO" -c core.hooksPath=/dev/null worktree add --detach "$WT" "$BASE_SHA" > "$log" 2>&1; then
    { echo "patch-check: could not create a worktree at $BASE"; } >> "$log"
    WT=""; emit "$patch" false null "" "$log"; continue
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
    fi
  fi
  if [ "$applies" = false ]; then
    tail -n 20 "$log" > "$log.tail"
    emit "$patch" false null "" "$log.tail"; cleanup_wt; continue
  fi

  if [ -n "$OVERLAY" ]; then
    cp -R "$OVERLAY"/. "$WT"/ 2>> "$log" || echo "patch-check: overlay copy failed" >> "$log"
  fi
  run_check "$log"
  tail -n 20 "$log" > "$log.tail"
  emit "$patch" true "$RC" "$diffstat" "$log.tail"
  cleanup_wt
done
exit 0
