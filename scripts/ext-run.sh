#!/bin/bash
# scripts/ext-run.sh — SINGLE OWNER of every invocation of an external,
# non-Anthropic agent CLI made by this layer: Google's Antigravity (`agy`) and
# OpenAI's Codex CLI (`codex`). Nothing else in the repo, and no agent, may call
# either CLI directly: the vendor adapters, the deny-list, the known-good flag
# combos, the timeouts, the build staging worktree and the exit-code contract
# all live here. Model ids and efforts do NOT live here: they come from the
# tiers file (config/tiers.json; see "Tiers" below).
#
# Usage:
#   scripts/ext-run.sh <mode> --prompt-file FILE [options]
#
# Modes (mode picks the tiers entry + CLI flags + write policy):
#   review    cross-vendor review of a diff / prompt / rubric        read-only
#   read      long-corpus distillation, optional --schema for        read-only
#             typed JSON output
#   verify    search-grounded fact check                             read-only
#   critique  adversarial design critique                            read-only
#   fuzz      edge-case / mutation hunting against a guard           read-only
#   build     EXTERNAL WORKER: edits a disposable git worktree of    WRITES
#             the repo, then the resulting patch is applied back
#             (or only written out, with --patch-out)
#
# Options:
#   --vendor agy|codex   which external CLI (default agy — existing callers
#                        behave exactly as before).
#   --level L            build mode only: quick|builder|deep|top. Resolves the
#                        model (and codex effort) from tiers.json levels.L.<vendor>.
#                        Without it, build resolves modes.<vendor>.build.
#   --prompt-file FILE   (required) the brief. Never passed inline on argv.
#   --input FILE         stage FILE into the workspace and name it by ABSOLUTE
#                        path in the prompt footer. Repeatable. This is how a
#                        diff/log/corpus gets in. Read-only modes: inputs/<base>
#                        in the stage; build: .<vendor>-inputs/<base> in the
#                        worktree, removed again before the result patch is captured.
#   --schema FILE|JSON   read mode only: enforce typed output (implies JSON out).
#   --workdir DIR        build mode only: the git repo to change. The external CLI
#                        NEVER sees it — it sees a disposable worktree of it.
#   --output FILE        build mode only: where to write the result patch.
#                        Defaults to a mktemp file; the path is always printed
#                        on stderr. The patch is kept when it fails to apply.
#   --patch-out FILE     build mode only: write the result patch to FILE and do
#                        NOT apply it (bake-off / compare). Refuses (exit 3) when
#                        the caller's tree is dirty, so the candidate starts from
#                        clean HEAD. Mutually exclusive with --output.
#   --check CMD          build mode only: after the model finishes and the run
#                        passed its gates, run CMD (bash -c) in the worktree,
#                        OUTSIDE the model sandbox. Prints `CHECK rc=<n>` and the
#                        tail of its output on stderr. Never changes the exit code.
#   --model ID           override the tiers model. Must belong to the vendor
#                        (agy: gemini-*; codex: gpt-*|codex-*); anything naming
#                        claude is always refused.
#   --effort E           agy: low|medium|high — rewrites the SUFFIX of the model
#                        id (agy encodes effort in the id and rejects --effort
#                        next to such an id, so agy NEVER receives --effort).
#                        codex: minimal|low|medium|high|xhigh|max — overrides the
#                        tiers effort (passed as -c model_reasoning_effort=E).
#   --timeout DURATION   override the mode's timeout. agy: its --print-timeout
#                        (Go duration). codex: the wall-clock watchdog (N, Ns,
#                        Nm or Nh).
#   --raw                print the full vendor output (agy JSON envelope / codex
#                        JSONL event stream) instead of the answer.
#
# Tiers (the ONLY source of external model ids and efforts):
#   $TRIAGE_TIERS, else <script dir>/triage-tiers.json (the installed copy), else
#   <script dir>/../config/tiers.json (the repo). Missing/unparseable => exit 2.
#   A vendor entry present under a level/mode means that vendor is allowed there;
#   an ABSENT entry is a refusal (exit 3) — never a fallback to a default model.
#
# Environment:
#   AGY_BIN / CODEX_BIN   executables (default: agy / codex on PATH)
#   AGY_DENY_REPOS        extra space-separated repo/dir names agy must never see.
#   CODEX_DENY_REPOS      the same for codex.
#                         clip-creator is hard-denied for EVERY vendor whatever
#                         these hold (standing decision 2026-07-10; engram left
#                         the list 2026-09-15 — see CHANGELOG.md, Wave 10).
#   AGY_BOUNDARY_CLEARED  must be 1, for every vendor. The caller attests the data
#                         boundary was checked (no clinical/BCH/PHI, no COI
#                         material, not a deny-listed repo). Absent => REFUSED.
#   AGY_STAGE_KEEP        1 = keep the staging dir (debugging). It NEVER keeps
#                         the build worktree — that is always removed.
#
# Exit codes (the contract every caller keys off):
#   0  OK          stdout is the model's answer (or the raw output with --raw)
#   2  USAGE       bad mode/flags/missing file/bad tiers file — nothing ran
#   3  REFUSED     deny-list hit, boundary not attested, vendor not listed in
#                  tiers.json for this level/mode, or --patch-out on a dirty
#                  tree — nothing ran
#   4  UNAVAILABLE CLI missing, auth failed, timed out, tools were denied, a
#                  failure event, the response was empty, or the build stage
#                  could not be prepared. NEVER silently a pass.
#   5  SCHEMA      --schema was given and the response is not valid JSON
#   6  APPLY       build only: a patch was produced but would NOT apply cleanly
#                  to the real repo. The real repo is left exactly as it was (the
#                  apply is pre-checked; nothing is written unless it is clean);
#                  the patch is left at --output; the answer still went to stdout.
#
# WHY exit code alone is not enough:
#   agy (verified live, agy 1.2.3, 2026-09-15): a run whose tools were auto-denied
#   in headless mode exits 0, prints nothing on stdout, and reports
#   {"status":"SUCCESS","response":"","denied_actions":[...]}. The agy gate
#   therefore requires .response non-empty and .denied_actions empty.
#   codex (verified live, codex-cli 0.155.1, 2026-09-23): a failed turn emits a
#   turn.failed event and a top-level {"type":"error"} event, exits 1, and does
#   NOT write the -o file. The codex gate requires rc 0 AND a non-empty -o file
#   AND no turn.failed/error event.
#
# WHY build mode never lets the external CLI touch the caller's tree:
#   agy runs with --dangerously-skip-permissions (the only way any tool runs
#   headless) and --mode plan is not a write guard; codex's workspace-write
#   sandbox is scoped to its -C dir. Either way "which files it may change" is
#   best expressed as "a disposable copy": build mode checks out a disposable
#   `git worktree --detach HEAD`, carries the caller's uncommitted changes and
#   untracked files into it, commits that carried state as the stage base, and
#   points the CLI at the worktree. This script then captures
#   `git add -A && git diff --cached --binary` (the pure model delta, because the
#   stage base already holds the caller's changes) and applies it back to the
#   real repo. Failure to apply is exit 6, never a silent half-write, and the
#   worktree is removed on every exit path. `git add -A` honours .gitignore, so
#   files the repo ignores are NOT carried back. While the CLI runs, the
#   worktree's `.git` file (which names the REAL repo's gitdir) is moved into
#   this script's private meta dir, so the CLI cannot discover or write the real
#   repo through git; it is restored before this script's own git calls and in
#   the exit trap.
set -uo pipefail

# Inherited git redirection (a git hook, a caller running under GIT_DIR=...)
# would point every `git -C` below at ANOTHER repository: -C does not override an
# absolute GIT_DIR/GIT_WORK_TREE. Cleared once, here, for this script and every
# child (the external CLI included).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGY_BIN="${AGY_BIN:-agy}"
CODEX_BIN="${CODEX_BIN:-codex}"
# Hard-denied for every vendor; not overridable from the environment.
HARD_DENY_REPOS="clip-creator"
AGY_DENY_REPOS="${AGY_DENY_REPOS:-}"
CODEX_DENY_REPOS="${CODEX_DENY_REPOS:-}"
# $HOME in its physical spelling too: deny paths are compared after pwd -P.
HOME_P=$(cd "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_P="${HOME:-/}"

E_USAGE=2
E_REFUSED=3
E_UNAVAIL=4
E_SCHEMA=5
E_APPLY=6

STAGE=""
BUILD_REPO=""
BUILD_WT=""
WD_PID=""
RUN_PID=""
HIDDEN_GIT=""   # where the build worktree's .git file sits while the CLI runs
stop_watchdog() {
  # Kill the watchdog subshell FIRST, then its pending `sleep`: killing the sleep
  # first would let the subshell run on and declare a timeout that never happened.
  # Stopping it also cancels its delayed KILL — reap_tree, not the watchdog, is
  # what guarantees nothing of the run survives.
  local kids=""
  if [ -n "$WD_PID" ]; then
    command -v pgrep >/dev/null 2>&1 && kids=$(pgrep -P "$WD_PID" 2>/dev/null)
    kill "$WD_PID" >/dev/null 2>&1
    wait "$WD_PID" 2>/dev/null
    # shellcheck disable=SC2086  # a whitespace-separated pid list
    [ -n "$kids" ] && kill $kids >/dev/null 2>&1
    WD_PID=""
  fi
}
# kill_tree SIG PID — signal PID and every descendant still attached to it by
# parentage, leaves first. Each process is frozen (STOP) before its children are
# listed, so it cannot fork a new one in between; a pending SIG lands on CONT.
kill_tree() {
  local kid
  kill -STOP "$2" 2>/dev/null || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for kid in $(pgrep -P "$2" 2>/dev/null); do kill_tree "$1" "$kid"; done
  fi
  kill "-$1" "$2" 2>/dev/null
  kill -CONT "$2" 2>/dev/null
}
# reap_tree PID [reaped] — PID was started under `set -m`, so it leads its own
# process group, and a grandchild orphaned by an exiting parent keeps that group
# (bash 3.2 / macOS: no setsid, so the group is the handle). TERM the tree and the
# group, give it 2s, KILL whatever is left, and wait until the group is empty.
# Pass "reaped" once PID itself has been waited for: its pid may then belong to
# someone else, so only the group is signalled.
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
# restore_git — put the build worktree's .git file back (anything the CLI created
# at that path is discarded first). Idempotent; called before this script's own
# git calls on the worktree and from the exit trap.
restore_git() {
  [ -n "$HIDDEN_GIT" ] && [ -n "$BUILD_WT" ] || return 0
  if [ -e "$HIDDEN_GIT" ]; then
    rm -rf "${BUILD_WT:?}/.git"
    mv "$HIDDEN_GIT" "$BUILD_WT/.git"
  fi
  HIDDEN_GIT=""
}
cleanup() {
  stop_watchdog
  if [ -n "$RUN_PID" ]; then reap_tree "$RUN_PID"; RUN_PID=""; fi
  restore_git
  # The worktree goes first and unconditionally: it is registered in the real
  # repo's .git, so leaving it behind would litter the caller's repo, and
  # AGY_STAGE_KEEP must not be able to defeat that.
  if [ -n "$BUILD_WT" ] && [ -n "$BUILD_REPO" ]; then
    git -C "$BUILD_REPO" worktree remove --force "$BUILD_WT" >/dev/null 2>&1 || rm -rf "$BUILD_WT"
    git -C "$BUILD_REPO" worktree prune >/dev/null 2>&1
  fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ] && [ "${AGY_STAGE_KEEP:-0}" != "1" ]; then
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT
# A signal must still run cleanup (reap the CLI's tree, restore .git, remove the
# worktree): exit through the EXIT trap.
trap 'exit 130' INT TERM HUP

die() { echo "$1" >&2; exit "$2"; }

# ---------------------------------------------------------------------------
# Mode table — write policy and timeout per mode. Models are NOT here: they come
# from tiers.json (resolve_tier below), always an explicit non-Claude id — agy's
# roster includes Claude models, and a defaulted run would review Claude with
# Claude, defeating the whole point of the cross-vendor tier.
# ---------------------------------------------------------------------------
is_mode() {
  case "$1" in
    review|read|verify|critique|fuzz|build) return 0 ;;
  esac
  return 1
}
# Effort is encoded in an agy model id, NOT passed as --effort (verified live: agy
# rejects --model <id with a suffix> together with --effort). apply_effort swaps
# the suffix on the resolved model; gemini-3.1-pro has no "medium" rung, so medium
# resolves to high there rather than inventing an id agy would reject.
apply_effort() { # $1 = model id, $2 = low|medium|high
  local base want
  case "$1" in
    *-low|*-medium|*-high) base="${1%-*}" ;;
    *) echo "$1"; return ;;
  esac
  want="$2"
  case "$base" in
    gemini-3.1-pro) [ "$want" = "medium" ] && want="high" ;;
  esac
  echo "$base-$want"
}
mode_timeout() {
  case "$1" in
    read|verify) echo "5m" ;;
    review|critique|fuzz) echo "8m" ;;
    build) echo "20m" ;;
    *) echo "" ;;
  esac
}
# "write" = build only. Every other mode runs in a throwaway staging dir with
# NOTHING of the real repo in it but the files explicitly staged by --input.
mode_writes() { [ "$1" = "build" ]; }

# A model id must belong to the vendor it is sent to.
vendor_model_ok() { # $1 = model id
  case "$VENDOR" in
    agy)   case "$1" in gemini-*) return 0 ;; esac ;;
    codex) case "$1" in gpt-*|codex-*) return 0 ;; esac ;;
  esac
  return 1
}

# Watchdog duration: N | Ns | Nm | Nh -> seconds; empty on anything else.
to_seconds() {
  local n
  case "$1" in
    *h) n="${1%h}" ;;
    *m) n="${1%m}" ;;
    *s) n="${1%s}" ;;
    *)  n="$1" ;;
  esac
  case "$n" in ''|*[!0-9]*) echo ""; return ;; esac
  case "$1" in
    *h) echo $((n * 3600)) ;;
    *m) echo $((n * 60)) ;;
    *)  echo "$n" ;;
  esac
}

# ---------------------------------------------------------------------------
# Tiers. find_tiers locates the file; resolve_tier is the single owner of
# "which model/effort may this vendor use for this level/mode". An absent entry
# is a refusal — there is deliberately no default model anywhere in this script.
# ---------------------------------------------------------------------------
TIERS=""
find_tiers() {
  if [ -n "${TRIAGE_TIERS:-}" ]; then
    TIERS="$TRIAGE_TIERS"
  elif [ -f "$SCRIPT_DIR/triage-tiers.json" ]; then
    TIERS="$SCRIPT_DIR/triage-tiers.json"
  else
    TIERS="$SCRIPT_DIR/../config/tiers.json"
  fi
  [ -f "$TIERS" ] || die "USAGE: tiers file not found: $TIERS (set TRIAGE_TIERS, install triage-tiers.json next to this script, or run from the repo)" "$E_USAGE"
  jq -e 'type == "object" and (.levels | type == "object") and (.modes | type == "object")' "$TIERS" >/dev/null 2>&1 || \
    die "USAGE: tiers file is not valid tiers JSON (needs .levels and .modes objects): $TIERS" "$E_USAGE"
}

TIER_MODEL=""
TIER_EFFORT=""
resolve_tier() {
  local entry where
  if [ -n "$LEVEL" ]; then
    entry=$(jq -c --arg k "$LEVEL" --arg v "$VENDOR" '.levels[$k][$v] // empty' "$TIERS" 2>/dev/null)
    where="levels.$LEVEL.$VENDOR"
  else
    entry=$(jq -c --arg k "$MODE" --arg v "$VENDOR" '.modes[$v][$k] // empty' "$TIERS" 2>/dev/null)
    where="modes.$VENDOR.$MODE"
  fi
  TIER_MODEL=$(printf '%s' "$entry" | jq -r '.model // empty' 2>/dev/null)
  TIER_EFFORT=$(printf '%s' "$entry" | jq -r '.effort // empty' 2>/dev/null)
  if [ -z "$TIER_MODEL" ]; then
    die "REFUSED: $TIERS has no $where entry — $VENDOR is not allowed there (an absent entry is a refusal, never a default model; build mode may need --level)." "$E_REFUSED"
  fi
}

# ---------------------------------------------------------------------------
# Deny-list. Enforced on the resolved, symlink-free path (resolve_path: the whole
# symlink chain) of the workdir, of every --input source, of a --schema file and
# of the prompt file — and that resolved path is what is then read. Component
# equality (not substring), so ".../clip-creator/media" is refused and
# ".../clip-creators-lab" is not. A per-vendor marker file (.agy-deny for agy,
# .codex-deny for codex) anywhere from the path up to AND INCLUDING $HOME (or /,
# outside $HOME) also refuses, so a repo can opt itself out of one vendor
# without editing this script. Each of those paths that sits in a git work tree
# is ALSO checked via the main worktree of its repository (git-common-dir), so a
# linked worktree created outside a deny-listed repo is refused like the repo.
# ---------------------------------------------------------------------------
# resolve_path — SINGLE OWNER of "which file does this path really name". The
# whole symlink chain of the leaf is followed (a link in an allowed dir pointing
# into a denied repo must be judged — and read — at its target), then every
# directory component is made physical with pwd -P. bash-3.2-safe: plain
# readlink, no -f. A chain over 40 hops (a loop) is returned unresolved, and the
# caller's -f/-d test on it then fails as a usage error.
resolve_path() { # $1 = path -> absolute physical path
  local p="$1" t d n=0
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || { echo "$p"; return 0; }
    t=$(readlink "$p") || break
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) || echo "$p"; return 0; fi
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { echo "$p"; return 0; }
  [ "$d" = / ] && d=""
  echo "$d/$(basename "$p")"
}

deny_names() {
  case "$VENDOR" in
    agy)   echo "$HARD_DENY_REPOS $AGY_DENY_REPOS" ;;
    codex) echo "$HARD_DENY_REPOS $CODEX_DENY_REPOS" ;;
  esac
}

deny_check_path() { # $1 = one path, $2 = optional context for the message. exits E_REFUSED on a hit.
  local p d name marker why
  p=$(resolve_path "$1")
  why="${2:-}"
  for name in $(deny_names); do
    case "/$p/" in
      */"$name"/*) die "REFUSED: $p$why is under a deny-listed repo ('$name') — $VENDOR must never read it." "$E_REFUSED" ;;
    esac
  done
  marker=".$VENDOR-deny"
  d="$p"
  [ -f "$d" ] && d=$(dirname "$d")
  # Every directory from the path up to AND INCLUDING $HOME (or / for a path
  # outside it) is checked; the walk stops only after checking one of those.
  while [ -n "$d" ]; do
    if [ -f "$d/$marker" ]; then
      die "REFUSED: $d/$marker marks this tree as off-limits to $VENDOR$why." "$E_REFUSED"
    fi
    case "$d" in /|"${HOME:-/}"|"$HOME_P") break ;; esac
    [ "$(dirname "$d")" != "$d" ] || break   # never spin on a fixed point
    d=$(dirname "$d")
  done
}

# main_worktree_of PATH — the main worktree of the git repository PATH (a file or
# dir) belongs to, physical path; prints nothing outside a git work tree or
# without git. A LINKED worktree can live anywhere (triage-compare stages them
# under an outDir outside the repo), so its own path says nothing about which
# repository it checks out — the common git dir does: its parent when it ends in
# /.git, else the common dir itself (bare repo, submodule module dir). GIT_DIR &
# co. were unset at the top, so an inherited environment cannot redirect it.
main_worktree_of() {
  local d common
  command -v git >/dev/null 2>&1 || return 0
  d="$1"
  [ -d "$d" ] || d=$(dirname "$d")
  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  common=$(resolve_path "$common")
  case "$common" in
    */.git) dirname "$common" ;;
    *) printf '%s\n' "$common" ;;
  esac
}

# deny_check — the path itself AND the main worktree of the repository it is in,
# so a linked worktree (or a file in one) outside a deny-listed repo is refused
# exactly like the repo.
deny_check() { # $1 = path. exits E_REFUSED on a hit.
  local p main
  p=$(resolve_path "$1")
  deny_check_path "$p"
  main=$(main_worktree_of "$p")
  if [ -n "$main" ] && [ "$main" != "$p" ]; then deny_check_path "$main" " (the main worktree of the repository $p belongs to)"; fi
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || die "USAGE: ext-run.sh <review|read|verify|critique|fuzz|build> --prompt-file FILE [--vendor agy|codex] [options]" "$E_USAGE"
MODE="$1"; shift
is_mode "$MODE" || die "USAGE: unknown mode '$MODE' (review|read|verify|critique|fuzz|build)" "$E_USAGE"

VENDOR="agy"
LEVEL=""
PROMPT_FILE=""
WORKDIR=""
OUTPUT=""
PATCH_OUT=""
CHECK_CMD=""
SCHEMA=""
MODEL_OVERRIDE=""
EFFORT=""
TIMEOUT="$(mode_timeout "$MODE")"
RAW=0
INPUTS=()

# Every value-taking option REQUIRES its value: a trailing `--vendor` would make
# `shift 2` fail without shifting, and the loop would spin forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift; continue ;;
    --vendor|--level|--prompt-file|--input|--schema|--workdir|--output|--patch-out|--check|--model|--effort|--timeout)
      [ $# -ge 2 ] || die "USAGE: $1 needs a value" "$E_USAGE" ;;
    *) die "USAGE: unknown argument '$1'" "$E_USAGE" ;;
  esac
  case "$1" in
    --vendor)      VENDOR="$2" ;;
    --level)       LEVEL="$2" ;;
    --prompt-file) PROMPT_FILE="$2" ;;
    --input)       INPUTS+=("$2") ;;
    --schema)      SCHEMA="$2" ;;
    --workdir)     WORKDIR="$2" ;;
    --output)      OUTPUT="$2" ;;
    --patch-out)   PATCH_OUT="$2" ;;
    --check)       CHECK_CMD="$2" ;;
    --model)       MODEL_OVERRIDE="$2" ;;
    --effort)      EFFORT="$2" ;;
    --timeout)     TIMEOUT="$2" ;;
  esac
  shift 2
done

case "$VENDOR" in
  agy|codex) ;;
  *) die "USAGE: unknown --vendor '$VENDOR' (agy|codex)" "$E_USAGE" ;;
esac
if [ -n "$LEVEL" ]; then
  case "$LEVEL" in
    quick|builder|deep|top) ;;
    *) die "USAGE: unknown --level '$LEVEL' (quick|builder|deep|top)" "$E_USAGE" ;;
  esac
  mode_writes "$MODE" || die "USAGE: --level is only valid in build mode (read-only modes resolve their model from tiers.json modes)" "$E_USAGE"
fi

[ -n "$PROMPT_FILE" ] || die "USAGE: --prompt-file is required" "$E_USAGE"
# From here on every caller-named file/dir is its RESOLVED path (resolve_path):
# the path that is deny-checked is the path that is read.
PROMPT_FILE=$(resolve_path "$PROMPT_FILE")
[ -f "$PROMPT_FILE" ] || die "USAGE: prompt file not found: $PROMPT_FILE" "$E_USAGE"
[ -s "$PROMPT_FILE" ] || die "USAGE: prompt file is empty: $PROMPT_FILE" "$E_USAGE"
# The prompt reaches agy as `-p "$(cat FILE)"`, so it is bounded by ARG_MAX (~1MB
# on macOS). Data — diffs, logs, corpora — belongs in --input (staged as a file the
# CLI opens itself), NOT inlined into the brief. Fail loudly rather than produce the
# truncated/E2BIG failure that looks like a model error.
PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
if [ "$PROMPT_BYTES" -gt 262144 ]; then
  die "USAGE: prompt file is ${PROMPT_BYTES} bytes (>256KB) — pass bulk data with --input instead of inlining it into the brief." "$E_USAGE"
fi

command -v jq >/dev/null 2>&1 || die "USAGE: jq is required" "$E_USAGE"
find_tiers
resolve_tier

MODEL="$TIER_MODEL"
[ -n "$MODEL_OVERRIDE" ] && MODEL="$MODEL_OVERRIDE"
case "$VENDOR" in
  agy)
    if [ -n "$EFFORT" ]; then
      case "$EFFORT" in
        low|medium|high) MODEL="$(apply_effort "$MODEL" "$EFFORT")" ;;
        *) die "USAGE: --effort must be low|medium|high for agy" "$E_USAGE" ;;
      esac
    fi
    ;;
  codex)
    [ -n "$EFFORT" ] || EFFORT="$TIER_EFFORT"
    [ -n "$EFFORT" ] || die "USAGE: $TIERS gives no effort for this codex entry and --effort was not passed" "$E_USAGE"
    case "$EFFORT" in
      minimal|low|medium|high|xhigh|max) ;;  # gpt-6-* list max (~/.codex/models_cache.json); 'ultra' auto-delegates, excluded
      *) die "USAGE: --effort must be minimal|low|medium|high|xhigh|max for codex (got '$EFFORT')" "$E_USAGE" ;;
    esac
    [ -n "$(to_seconds "$TIMEOUT")" ] || die "USAGE: --timeout for codex must be N, Ns, Nm or Nh (got '$TIMEOUT')" "$E_USAGE"
    ;;
esac
case "$MODEL" in
  claude*|*claude*) die "USAGE: refusing to run the cross-vendor tier on a Claude model ('$MODEL')." "$E_USAGE" ;;
esac
vendor_model_ok "$MODEL" || die "USAGE: model '$MODEL' does not belong to vendor '$VENDOR' (agy: gemini-*; codex: gpt-*|codex-*)" "$E_USAGE"

if [ -n "$SCHEMA" ] && [ "$MODE" != "read" ]; then
  die "USAGE: --schema is only valid in read mode" "$E_USAGE"
fi
if [ -n "$WORKDIR" ] && ! mode_writes "$MODE"; then
  die "USAGE: --workdir is only valid in build mode (read-only modes run in an isolated staging dir)" "$E_USAGE"
fi
if [ -n "$OUTPUT" ] && ! mode_writes "$MODE"; then
  die "USAGE: --output is only valid in build mode (it is where the result patch is written)" "$E_USAGE"
fi
if [ -n "$PATCH_OUT" ] && ! mode_writes "$MODE"; then
  die "USAGE: --patch-out is only valid in build mode" "$E_USAGE"
fi
if [ -n "$CHECK_CMD" ] && ! mode_writes "$MODE"; then
  die "USAGE: --check is only valid in build mode (it runs in the build worktree)" "$E_USAGE"
fi
if [ -n "$PATCH_OUT" ] && [ -n "$OUTPUT" ]; then
  die "USAGE: --patch-out and --output are mutually exclusive (--patch-out never applies; --output does)" "$E_USAGE"
fi
if mode_writes "$MODE"; then
  [ -n "$WORKDIR" ] || die "USAGE: build mode requires --workdir" "$E_USAGE"
  WORKDIR=$(resolve_path "$WORKDIR")
  [ -d "$WORKDIR" ] || die "USAGE: --workdir is not a directory: $WORKDIR" "$E_USAGE"
  [ -n "$PATCH_OUT" ] && OUTPUT="$PATCH_OUT"
  if [ -n "$OUTPUT" ]; then
    OUT_DIR=$(dirname "$OUTPUT")
    [ -d "$OUT_DIR" ] || die "USAGE: --output/--patch-out directory does not exist: $OUT_DIR" "$E_USAGE"
  fi
fi

# Boundary attestation — mirrors the cross-reviewer tier's rule 1. The caller,
# not this script, knows whether the material is clinical/COI/restricted.
[ "${AGY_BOUNDARY_CLEARED:-}" = "1" ] || \
  die "REFUSED: AGY_BOUNDARY_CLEARED is not set — the caller must attest the data boundary was checked before anything leaves the machine." "$E_REFUSED"

deny_check "$PROMPT_FILE"
if [ -n "$WORKDIR" ]; then deny_check "$WORKDIR"; fi
if [ -n "$SCHEMA" ] && [ -f "$SCHEMA" ]; then SCHEMA=$(resolve_path "$SCHEMA"); deny_check "$SCHEMA"; fi

case "$VENDOR" in
  agy)   VENDOR_BIN="$AGY_BIN" ;;
  codex) VENDOR_BIN="$CODEX_BIN" ;;
esac
command -v "$VENDOR_BIN" >/dev/null 2>&1 || die "UNAVAILABLE: $VENDOR_BIN is not installed or not on PATH." "$E_UNAVAIL"
if mode_writes "$MODE"; then
  command -v git >/dev/null 2>&1 || die "USAGE: git is required for build mode (the run is staged in a disposable worktree)" "$E_USAGE"
fi

# ---------------------------------------------------------------------------
# Staging. Read-only modes get a fresh empty dir as cwd containing ONLY the
# staged inputs, because agy's read-only-ness cannot be enforced by flags:
#   - without --dangerously-skip-permissions headless runs have their tools
#     auto-denied (verified: view_file/read_url/command all hit the permission
#     gate) and return an empty response;
#   - with it, every tool including write_to_file is approved;
#   - and `--mode plan` is NOT a write guard either: verified live 2026-09-15,
#     `--mode plan --dangerously-skip-permissions` wrote the file it had just
#     said it would write only "once you approve".
# Workspace isolation, not a flag, is what keeps a read-only mode off the repo.
# codex gets the same stage (plus its own -s read-only sandbox on top).
# Build mode is the same principle one step further: it gets a real checkout,
# but a disposable one (see the worktree section below).
# ---------------------------------------------------------------------------
# $STAGE/ws is the workspace the CLI is given (read-only modes) — it holds ONLY
# the staged inputs, so anything else appearing in it is something the CLI wrote.
# $STAGE/meta holds this script's own files (prompt, output, stderr) and is
# deliberately NOT inside ws, so the write-detection fingerprint stays honest.
# $STAGE/build is the build worktree (build mode only).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ext-run.XXXXXX") || die "USAGE: could not create a staging dir" "$E_USAGE"
mkdir -p "$STAGE/ws/inputs" "$STAGE/meta"
STAGE_ABS=$(resolve_path "$STAGE")
[ "${AGY_STAGE_KEEP:-0}" = "1" ] && echo "ext-run: staging dir kept at $STAGE_ABS" >&2

# ---------------------------------------------------------------------------
# Build staging worktree. The CLI is pointed at $BUILD_WT, never at $BUILD_REPO.
# ---------------------------------------------------------------------------
if mode_writes "$MODE"; then
  git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "USAGE: --workdir is not a git work tree: $WORKDIR (build mode stages the run in a disposable worktree)" "$E_USAGE"
  BUILD_REPO=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$BUILD_REPO" ] || die "USAGE: could not resolve the top level of the repo at $WORKDIR" "$E_USAGE"
  BUILD_REPO=$(resolve_path "$BUILD_REPO")
  deny_check "$BUILD_REPO"
  git -C "$BUILD_REPO" rev-parse --verify HEAD >/dev/null 2>&1 || \
    die "UNAVAILABLE: $BUILD_REPO has no commits — build mode stages from HEAD." "$E_UNAVAIL"
  # A compare candidate must start from clean HEAD: carried uncommitted work
  # would make candidates incomparable and the written patch ambiguous.
  if [ -n "$PATCH_OUT" ] && [ -n "$(git -C "$BUILD_REPO" status --porcelain 2>/dev/null)" ]; then
    die "REFUSED: --patch-out needs a clean tree, and $BUILD_REPO has uncommitted or untracked changes (commit or stash them first)." "$E_REFUSED"
  fi

  if ! git -C "$BUILD_REPO" worktree add --detach "$STAGE/build" HEAD >"$STAGE/meta/worktree.log" 2>&1; then
    echo "UNAVAILABLE: could not create the disposable build worktree — $(head -c 400 "$STAGE/meta/worktree.log")" >&2
    exit "$E_UNAVAIL"
  fi
  BUILD_WT="$STAGE/build"

  # Carry the caller's uncommitted work in, so the external worker sees the tree
  # the caller actually has, not HEAD.
  git -C "$BUILD_REPO" diff HEAD --binary > "$STAGE/meta/carried.patch" 2>"$STAGE/meta/carry.err"
  if [ -s "$STAGE/meta/carried.patch" ]; then
    git -C "$BUILD_WT" apply --index "$STAGE/meta/carried.patch" 2>>"$STAGE/meta/carry.err" || \
      die "UNAVAILABLE: could not carry the caller's uncommitted changes into the build worktree — $(head -c 400 "$STAGE/meta/carry.err")" "$E_UNAVAIL"
  fi
  git -C "$BUILD_REPO" ls-files --others --exclude-standard -z > "$STAGE/meta/untracked.z" 2>>"$STAGE/meta/carry.err"
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$BUILD_WT/$(dirname "$rel")"
    cp "$BUILD_REPO/$rel" "$BUILD_WT/$rel" || \
      die "UNAVAILABLE: could not copy untracked file '$rel' into the build worktree" "$E_UNAVAIL"
  done < "$STAGE/meta/untracked.z"

  # Commit the carried state as the stage base. The result patch is then
  # `git diff --cached` against it — i.e. the PURE model delta, which is what
  # applies cleanly back onto a repo that already has those carried changes.
  git -C "$BUILD_WT" add -A >/dev/null 2>&1
  git -C "$BUILD_WT" -c user.email=ext-run@localhost -c user.name=ext-run -c commit.gpgsign=false \
      commit -q --no-verify --allow-empty -m "ext-run stage base" >>"$STAGE/meta/carry.err" 2>&1 || \
    die "UNAVAILABLE: could not commit the stage base in the build worktree — $(head -c 400 "$STAGE/meta/carry.err")" "$E_UNAVAIL"

  if [ -z "$OUTPUT" ]; then
    OUTPUT=$(mktemp "${TMPDIR:-/tmp}/ext-build.XXXXXX") || die "USAGE: could not create a patch file" "$E_USAGE"
  fi
fi

# --input staging. Read-only modes: $STAGE/ws/inputs. Build: .<vendor>-inputs
# inside the worktree (the CLI only sees the worktree), removed again before the
# result patch is captured so staged inputs never land in the caller's repo.
INPUT_DIR="$STAGE/ws/inputs"
BUILD_INPUTS_NAME=".$VENDOR-inputs"
if mode_writes "$MODE"; then
  INPUT_DIR="$BUILD_WT/$BUILD_INPUTS_NAME"
  if [ -e "$INPUT_DIR" ]; then
    die "USAGE: $WORKDIR already contains $BUILD_INPUTS_NAME — build mode reserves that path for staged --input files." "$E_USAGE"
  fi
  if [ ${#INPUTS[@]} -gt 0 ]; then mkdir -p "$INPUT_DIR"; fi
fi

STAGED_LIST=""
for src in ${INPUTS+"${INPUTS[@]}"}; do
  real=$(resolve_path "$src")
  [ -f "$real" ] || die "USAGE: --input file not found: $src" "$E_USAGE"
  deny_check "$real"
  # Staged under the name the caller gave, read from the path that was checked.
  cp "$real" "$INPUT_DIR/$(basename "$src")" || die "UNAVAILABLE: could not stage --input $src" "$E_UNAVAIL"
  STAGED_LIST="$STAGED_LIST  $INPUT_DIR/$(basename "$src")
"
done

RUNDIR="$STAGE/ws"
mode_writes "$MODE" && RUNDIR="$BUILD_WT"
RUNDIR_ABS=$(resolve_path "$RUNDIR")

# The prompt the CLI actually sees: the brief, plus a footer naming the workspace
# and every staged file by ABSOLUTE path. Relative paths are not enough: agy has
# been observed resolving its workspace to $HOME rather than the process working
# directory (verified live 2026-09-15), so the brief says where the files are
# rather than assuming "here".
PROMPT="$STAGE/meta/prompt.txt"
cat "$PROMPT_FILE" > "$PROMPT"
{
  printf '\n\n--- Workspace ---\n'
  printf 'Your working directory for this task is: %s\n' "$RUNDIR_ABS"
  printf 'If your tools report a different working directory, use the ABSOLUTE paths below.\n'
} >> "$PROMPT"
if mode_writes "$MODE"; then
  {
    printf 'This directory is a DISPOSABLE CHECKOUT of the repository, already carrying\n'
    printf 'the uncommitted work. Edit files here normally; do not commit, and do not\n'
    printf 'look for the project anywhere else on this machine.\n'
  } >> "$PROMPT"
fi
if [ -n "$STAGED_LIST" ]; then
  {
    printf '\n--- Files staged for you ---\n'
    printf '%s' "$STAGED_LIST"
  } >> "$PROMPT"
fi
# codex auto-loads ~/.codex/AGENTS.md (verified live 2026-09-23), whose rules are
# written for an interactive orchestrator (memory files, handoffs, asking first).
# This footer scopes it back to a headless worker.
if [ "$VENDOR" = "codex" ]; then
  {
    printf '\n--- Non-interactive worker ---\n'
    printf 'You are a non-interactive worker. Nobody will answer questions: do not ask any;\n'
    printf 'make the most reasonable assumption and state it in your answer.\n'
    printf 'Do not create or edit PROJECT_MEMORY.md, handoff files, engram, or any memory file.\n'
    printf 'Touch only files inside the workspace named above.\n'
  } >> "$PROMPT"
fi
# Build mode hides the worktree's .git during the CLI run (the pointer names the
# caller's real gitdir), so say so: a self-check that shells out to git would fail.
if mode_writes "$MODE"; then
  printf '\nNote: git is unavailable in this workspace during your run; do not run git commands. Checks that need git run afterwards, outside your session.\n' >> "$PROMPT"
fi

# Read-only modes: fingerprint the stage so we can SAY whether the run tried to
# write. It is contained either way (the stage is thrown away), but a silent
# containment is a bad habit — report it.
STAGE_BEFORE=""
if ! mode_writes "$MODE"; then
  STAGE_BEFORE=$(find "$STAGE/ws" -type f | sort | sed "s#^$STAGE/ws/##")
fi

ERRLOG="$STAGE/meta/cli.err"
ENVELOPE="$STAGE/meta/envelope.json"   # agy
EVENTS="$STAGE/meta/events.jsonl"      # codex --json
LASTMSG="$STAGE/meta/last-message.txt" # codex -o
TIMEDOUT_MARK="$STAGE/meta/timed-out"
SCHEMA_FILE=""
RC=0

# ---------------------------------------------------------------------------
# agy adapter. Flags — invariants, all verified live against agy 1.2.3:
#   --model <id>                    always explicit, always non-Claude, and the
#                                   ONLY place effort is expressed (never --effort).
#   --sandbox                       terminal restrictions on; always.
#   --dangerously-skip-permissions  REQUIRED: headless mode cannot prompt, so
#                                   without it every tool call is auto-denied
#                                   and the run returns an empty response.
#   --output-format json            the only way to see denied_actions/usage;
#                                   also required by --json-schema.
#   --add-dir "$RUNDIR_ABS"         pins the workspace. COMPUTED HERE, never taken
#                                   from the caller, so it cannot widen past a deny
#                                   check. In build mode this is the disposable
#                                   worktree, NEVER the caller's repo.
#   </dev/null                      non-TTY stdout-drop workaround.
# ---------------------------------------------------------------------------
agy_invoke() {
  set -- -p "$(cat "$PROMPT")" \
    --model "$MODEL" \
    --print-timeout "$TIMEOUT" \
    --output-format json \
    --add-dir "$RUNDIR_ABS" \
    --sandbox \
    --dangerously-skip-permissions
  case "$MODE" in
    build)    set -- "$@" --mode accept-edits ;;
    critique) set -- "$@" --mode plan ;;
  esac
  [ -n "$SCHEMA" ] && set -- "$@" --json-schema "$SCHEMA"
  # cd to the RESOLVED path, so agy's own $PWD and the --add-dir it is given are
  # the same string (on macOS $TMPDIR is a symlink). Run as its own process group
  # (set -m) so reap_tree can clear anything it leaves running.
  set -m
  ( cd "$RUNDIR_ABS" && exec "$AGY_BIN" "$@" ) > "$ENVELOPE" 2> "$ERRLOG" </dev/null &
  RUN_PID=$!
  set +m
  wait "$RUN_PID" 2>/dev/null
  RC=$?
}

# ---------------------------------------------------------------------------
# codex adapter. Flags — verified live against codex-cli 0.155.1 (2026-09-23):
#   exec -C <rundir>                non-interactive; workspace root pinned here.
#   -s read-only|workspace-write    codex's own sandbox; write only in build.
#   -m / -c model_reasoning_effort  always explicit, from tiers.json.
#   -c sandbox_workspace_write.exclude_slash_tmp=true
#   -c sandbox_workspace_write.exclude_tmpdir_env_var=true
#                                   without these, workspace-write can write
#                                   anywhere under /tmp and $TMPDIR (verified);
#                                   with them only the workspace is writable.
#   --ephemeral                     no session files persisted.
#   --skip-git-repo-check           the read-only stage is not a git repo.
#   --ignore-user-config            no ~/.codex/config.toml (notify hooks etc.);
#                                   auth is kept.
#   --json -o <file>                JSONL events on stdout; final message in -o.
#   -c web_search="live"            verify mode only.
#   - <PROMPT                       brief on stdin, never on argv.
# NEVER any --dangerously-* flag. codex has no print-timeout, so a bash-3.2-safe
# background watchdog enforces the mode's wall-clock limit.
# ---------------------------------------------------------------------------
codex_invoke() {
  local sandbox tsecs
  sandbox="read-only"
  mode_writes "$MODE" && sandbox="workspace-write"
  tsecs=$(to_seconds "$TIMEOUT")
  if [ -n "$SCHEMA" ]; then
    if [ -f "$SCHEMA" ]; then SCHEMA_FILE=$(resolve_path "$SCHEMA")
    else SCHEMA_FILE="$STAGE/meta/schema.json"; printf '%s' "$SCHEMA" > "$SCHEMA_FILE"
    fi
  fi
  set -- exec -C "$RUNDIR_ABS" -s "$sandbox" -m "$MODEL" -c "model_reasoning_effort=$EFFORT"
  set -- "$@" -c sandbox_workspace_write.exclude_slash_tmp=true
  set -- "$@" -c sandbox_workspace_write.exclude_tmpdir_env_var=true
  set -- "$@" --ephemeral --skip-git-repo-check --ignore-user-config --json -o "$LASTMSG"
  [ -n "$SCHEMA_FILE" ] && set -- "$@" --output-schema "$SCHEMA_FILE"
  [ "$MODE" = "verify" ] && set -- "$@" -c 'web_search="live"'
  set -- "$@" -
  # Its own process group (set -m): the watchdog and reap_tree signal the WHOLE
  # tree, so a grandchild (a tool the CLI spawned) cannot outlive the run.
  set -m
  ( cd "$RUNDIR_ABS" && exec "$CODEX_BIN" "$@" ) < "$PROMPT" > "$EVENTS" 2> "$ERRLOG" &
  RUN_PID=$!
  set +m
  local cpid=$RUN_PID
  ( sleep "$tsecs"
    kill -0 "$cpid" 2>/dev/null || exit 0
    : > "$TIMEDOUT_MARK"
    kill_tree TERM "$cpid"; kill -TERM -- "-$cpid"
    sleep 5
    kill_tree KILL "$cpid"; kill -KILL -- "-$cpid" ) >/dev/null 2>&1 &
  WD_PID=$!
  wait "$cpid" 2>/dev/null
  RC=$?
  stop_watchdog
}

# Build: hide the worktree's .git file for the duration of the CLI run. It names
# the REAL repo's gitdir, so with it in place the CLI (agy runs with
# --dangerously-skip-permissions) could `git -C`/commit its way into the caller's
# repository. restore_git puts it back — below, and in the exit trap.
if mode_writes "$MODE"; then
  HIDDEN_GIT="$STAGE/meta/worktree.git"
  mv "$BUILD_WT/.git" "$HIDDEN_GIT" || { HIDDEN_GIT=""; die "UNAVAILABLE: could not detach the build worktree's .git for the run" "$E_UNAVAIL"; }
fi

RUN_START=$SECONDS
case "$VENDOR" in
  agy)   agy_invoke ;;
  codex) codex_invoke ;;
esac
ELAPSED=$((SECONDS - RUN_START))
# The CLI has exited; clear anything it left running (grandchildren), then give
# the worktree its .git back before this script's own git calls.
if [ -n "$RUN_PID" ]; then reap_tree "$RUN_PID" reaped; RUN_PID=""; fi
restore_git

# Capture the result patch BEFORE the gates, so a failed run still leaves
# something inspectable. It is applied only if every gate passes.
if mode_writes "$MODE"; then
  rm -rf "${BUILD_WT:?}/$BUILD_INPUTS_NAME"
  git -C "$BUILD_WT" add -A >/dev/null 2>&1
  git -C "$BUILD_WT" diff --cached --binary > "$OUTPUT" 2>"$STAGE/meta/capture.err" || \
    die "UNAVAILABLE: could not capture the build patch — $(head -c 400 "$STAGE/meta/capture.err")" "$E_UNAVAIL"
fi

# ---------------------------------------------------------------------------
# Result gating. Every vendor gate must hold before this is a pass.
# ---------------------------------------------------------------------------
gate_fail() { # $1 = message, $2 = exit code
  if mode_writes "$MODE"; then
    echo "note: the build patch was NOT applied; it is left at $OUTPUT" >&2
  fi
  die "$1" "$2"
}

RESPONSE=""
agy_gate() {
  if [ "$RC" -ne 0 ]; then
    gate_fail "UNAVAILABLE: $AGY_BIN exited $RC — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
  fi
  if ! jq -e . "$ENVELOPE" >/dev/null 2>&1; then
    gate_fail "UNAVAILABLE: $AGY_BIN produced no parseable JSON envelope — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
  fi

  local status
  status=$(jq -r '.status // ""' "$ENVELOPE")
  DENIED=$(jq -r '(.denied_actions // []) | map(.action) | join(",")' "$ENVELOPE")
  RESPONSE=$(jq -r '.response // ""' "$ENVELOPE")

  if [ -n "$DENIED" ]; then
    gate_fail "UNAVAILABLE: agy tool calls were denied ($DENIED) — the run produced nothing usable." "$E_UNAVAIL"
  fi
  if [ "$status" != "SUCCESS" ]; then
    gate_fail "UNAVAILABLE: agy status=$status — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
  fi
  if [ -z "$RESPONSE" ]; then
    gate_fail "UNAVAILABLE: agy returned an empty response (exit 0 and status SUCCESS are NOT sufficient) — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
  fi
}

codex_detail() { # the most useful one-line reason codex gave, plus stderr
  local msg
  msg=$(jq -rR 'fromjson? | select(type == "object") | select(.type == "error" or .type == "turn.failed") | (.message // .error.message // empty)' "$EVENTS" 2>/dev/null | head -1)
  printf '%s %s' "$msg" "$(head -c 400 "$ERRLOG")"
}

codex_gate() {
  if [ -f "$TIMEDOUT_MARK" ]; then
    gate_fail "UNAVAILABLE: $CODEX_BIN timed out after $TIMEOUT (wall-clock watchdog) — $(codex_detail)" "$E_UNAVAIL"
  fi
  if [ "$RC" -ne 0 ]; then
    gate_fail "UNAVAILABLE: $CODEX_BIN exited $RC — $(codex_detail)" "$E_UNAVAIL"
  fi
  local failed
  failed=$(jq -rR 'fromjson? | select(type == "object") | select(.type == "turn.failed" or .type == "error") | .type' "$EVENTS" 2>/dev/null | head -1)
  if [ -n "$failed" ]; then
    gate_fail "UNAVAILABLE: codex emitted a $failed event (rc 0 is NOT sufficient) — $(codex_detail)" "$E_UNAVAIL"
  fi
  if [ ! -s "$LASTMSG" ]; then
    gate_fail "UNAVAILABLE: codex wrote no final message (-o file missing or empty; rc 0 is NOT sufficient) — $(codex_detail)" "$E_UNAVAIL"
  fi
  RESPONSE=$(cat "$LASTMSG")
}

case "$VENDOR" in
  agy)   agy_gate ;;
  codex) codex_gate ;;
esac
if [ -n "$SCHEMA" ] && ! printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1; then
  gate_fail "SCHEMA: --schema was requested but the response is not valid JSON." "$E_SCHEMA"
fi

if ! mode_writes "$MODE"; then
  STAGE_AFTER=$(find "$STAGE/ws" -type f | sort | sed "s#^$STAGE/ws/##")
  if [ "$STAGE_BEFORE" != "$STAGE_AFTER" ]; then
    echo "note: the read-only run wrote into its staging dir (contained, discarded). Do not treat any mode but 'build' as having produced files." >&2
  fi
fi

# ---------------------------------------------------------------------------
# --check: the caller's objective check, run in the worktree AFTER the patch was
# captured (so check artifacts never enter it) and OUTSIDE the model sandbox. It
# reports; it never changes this script's exit code.
# ---------------------------------------------------------------------------
if mode_writes "$MODE" && [ -n "$CHECK_CMD" ]; then
  ( cd "$BUILD_WT" && bash -c "$CHECK_CMD" ) > "$STAGE/meta/check.log" 2>&1 </dev/null
  CHECK_RC=$?
  echo "CHECK rc=$CHECK_RC" >&2
  tail -n 20 "$STAGE/meta/check.log" >&2
fi

# ---------------------------------------------------------------------------
# Apply the build patch back to the real repo (never with --patch-out).
# apply_back — SINGLE OWNER of writing into the caller's tree. It writes ONLY an
# apply that was proven clean first, so exit 6 always means "tree unchanged":
#   1. `git apply --check`, then `git apply`: atomic and index-free, so the common
#      case (the caller's tree is exactly what we carried in) applies even with
#      unstaged changes and untracked files present — `--index` cannot do that,
#      it refuses any path whose worktree copy differs from the index.
#   2. else `git apply --3way --check` (recovers a tree that drifted while the
#      CLI ran). It exits 0 even when the merge WOULD conflict (verified, git
#      2.54: "Applied patch to 'f' with conflicts."), so the check counts as clean
#      only with rc 0 AND no "conflict" in its output (LC_ALL=C); then --3way.
#   3. else nothing is written: APPLY (exit 6), the patch is kept at $OUTPUT.
# ---------------------------------------------------------------------------
APPLY_FAILED=0
apply_back() {
  local err="$STAGE/meta/apply.err" chk3="$STAGE/meta/apply-3way-check.out"
  if git -C "$BUILD_REPO" apply --check "$OUTPUT" >"$err" 2>&1; then
    if git -C "$BUILD_REPO" apply "$OUTPUT" >>"$err" 2>&1; then
      echo "ext-run: applied the build patch to $BUILD_REPO ($OUTPUT)" >&2
      return 0
    fi
    echo "APPLY: git apply failed after a clean --check (the tree changed in between?). git apply is atomic, so $BUILD_REPO was not written. The patch is left at $OUTPUT." >&2
    return 1
  fi
  if LC_ALL=C git -C "$BUILD_REPO" apply --3way --check "$OUTPUT" >"$chk3" 2>&1 && ! grep -qi 'conflict' "$chk3"; then
    if LC_ALL=C git -C "$BUILD_REPO" apply --3way "$OUTPUT" >>"$err" 2>&1; then
      echo "ext-run: applied the build patch to $BUILD_REPO by 3-way merge ($OUTPUT)" >&2
      return 0
    fi
    echo "APPLY: the 3-way apply failed after a clean 3-way --check (the tree changed in between?) — inspect $BUILD_REPO. The patch is left at $OUTPUT." >&2
    return 1
  fi
  cat "$chk3" >> "$err" 2>/dev/null
  echo "APPLY: the build patch would NOT apply cleanly to $BUILD_REPO (plain and 3-way pre-checks failed), so nothing was written: the tree is unchanged. The patch is left at $OUTPUT." >&2
  return 1
}
if mode_writes "$MODE"; then
  if [ ! -s "$OUTPUT" ]; then
    echo "ext-run: build produced NO changes (empty patch at $OUTPUT)" >&2
  elif [ -n "$PATCH_OUT" ]; then
    echo "ext-run: patch written to $OUTPUT — NOT applied (--patch-out)" >&2
  elif ! apply_back; then
    APPLY_FAILED=1
    head -c 800 "$STAGE/meta/apply.err" >&2
    echo "" >&2
  fi
fi

# Accounting: vendor spend is invisible to scripts/triage-usage.sh, so the token
# count goes to stderr where the caller can relay it:
#   ext-run: <N> tokens (<S>s, <vendor>/<model>)[ out=<M>]
# N is the total; out= is the OUTPUT side (reasoning included), the part a
# bake-off compares across vendors. codex: N = input + output summed over
# turn.completed events, out = output_tokens (reasoning_output_tokens is already
# inside output_tokens — codex's own total_tokens is input + output). agy: N is
# .usage.total_tokens; out= appears only when the envelope carries a numeric
# .usage.output_tokens (unverified live whether agy 1.2.3 emits it; absent => omitted, never guessed).
case "$VENDOR" in
  agy)
    jq -r --arg m "agy/$MODEL" '"ext-run: \(.usage.total_tokens // 0) tokens (\(.duration_seconds // 0)s, \($m))" + (if (.usage.output_tokens | type) == "number" then " out=\(.usage.output_tokens)" else "" end)' "$ENVELOPE" >&2
    ;;
  codex)
    TOKENS=$(jq -R 'fromjson? | select(type == "object" and .type == "turn.completed") | ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' "$EVENTS" 2>/dev/null | jq -s 'add // 0')
    OUT_TOKENS=$(jq -R 'fromjson? | select(type == "object" and .type == "turn.completed") | (.usage.output_tokens // 0)' "$EVENTS" 2>/dev/null | jq -s 'add // 0')
    echo "ext-run: ${TOKENS:-0} tokens (${ELAPSED}s, codex/$MODEL) out=${OUT_TOKENS:-0}" >&2
    ;;
esac

if [ "$RAW" -eq 1 ]; then
  case "$VENDOR" in
    agy)   cat "$ENVELOPE" ;;
    codex) cat "$EVENTS" ;;
  esac
else
  printf '%s\n' "$RESPONSE"
fi
[ "$APPLY_FAILED" -eq 1 ] && exit "$E_APPLY"
exit 0
