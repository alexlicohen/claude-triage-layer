#!/bin/bash
# scripts/ext-run.sh — SINGLE OWNER of every invocation of an external,
# non-Anthropic agent CLI made by this layer: OpenAI's Codex CLI (`codex`).
# Nothing else in the repo, and no agent, may call codex directly: the adapter,
# the OS confinement profile, the deny-list, the known-good flags, the timeouts,
# the build staging worktree, the command audit log and the exit-code contract
# all live here. Model ids and efforts do NOT live here: they come from the tiers
# file (config/tiers.json; see "Tiers" below).
#
# Google's Antigravity (`agy`) was RETIRED on 2026-09-24: its headless mode let
# the model set a per-command BypassSandbox flag, and a read-only review run used
# it to copy a file into a real repo. `--vendor agy` is refused (exit 3).
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
#   --vendor codex       the external CLI. codex is the only one (and the default);
#                        `agy` is refused (exit 3, retired 2026-09-24).
#   --level L            build mode only: quick|builder|deep|top. Resolves the
#                        model and effort from tiers.json levels.L.codex.
#                        Without it, build resolves modes.codex.build.
#   --prompt-file FILE   (required) the brief. Never passed inline on argv.
#   --input FILE         stage FILE into the workspace and name it by ABSOLUTE
#                        path in the prompt footer. Repeatable. This is how a
#                        diff/log/corpus gets in. Read-only modes: inputs/<base>
#                        in the stage; build: .codex-inputs/<base> in the
#                        worktree, removed again before the result patch is captured.
#   --input-dir DIR      read-only modes only: stage a COPY of the whole directory
#                        tree DIR into the workspace as inputs/<basename> and name
#                        it in the prompt footer (repeatable). DIR is deny-checked
#                        like --input (itself and the main worktree of its repo),
#                        and refused (exit 3) when a deny-listed repo or a
#                        .codex-deny marker lies beneath it, or a symlink in it
#                        resolves OUTSIDE it; a special file in it, or a tree over
#                        the size cap, is a usage error (exit 2).
#   --input-dir-max-mb N the --input-dir size cap in MB (default 200), per dir.
#   --allow-read PATH    let codex READ one more file or directory (repeatable).
#                        Its sandbox otherwise reads nothing under $HOME except
#                        its workspace and ~/.codex. Refused (exit 3) when the deny
#                        check refuses PATH, when PATH is $HOME or an ancestor of
#                        it, or when a deny-listed repo or a .codex-deny marker lies
#                        anywhere beneath it.
#   --schema FILE|JSON   read mode only: enforce typed output (implies JSON out).
#   --workdir DIR        build mode only: the git repo to change. codex NEVER sees
#                        it — it sees a disposable worktree of it.
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
#   --model ID           override the tiers model. Must be a codex model
#                        (gpt-*|codex-*); anything naming claude is always refused.
#   --effort E           minimal|low|medium|high|xhigh|max — overrides the tiers
#                        effort (passed as -c model_reasoning_effort=E).
#   --timeout DURATION   override the mode's wall-clock watchdog (N, Ns, Nm or Nh).
#   --raw                print the full codex JSONL event stream instead of the answer.
#
# Tiers (the ONLY source of external model ids and efforts):
#   $TRIAGE_TIERS, else <script dir>/triage-tiers.json (the installed copy), else
#   <script dir>/../config/tiers.json (the repo). Missing/unparseable => exit 2.
#   A codex entry present under a level/mode means codex is allowed there; an
#   ABSENT entry is a refusal (exit 3) — never a fallback to a default model.
#
# Environment:
#   CODEX_BIN             the codex executable: a path, or a name looked up on
#                         PATH (never a shell function or alias), then resolved to
#                         its real file. Default: codex.
#   CODEX_DENY_REPOS      extra space-separated repo/dir names codex must never see.
#                         clip-creator is hard-denied whatever this holds (standing
#                         decision 2026-07-10; engram left the list 2026-09-15 —
#                         see CHANGELOG.md, Wave 10).
#   AGY_BOUNDARY_CLEARED  must be 1. The caller attests the data boundary was
#                         checked (no clinical/BCH/PHI — no BAA; not a deny-listed
#                         repo). COI material may go (codex training opt-out
#                         confirmed, Alex 2026-09-25). Absent => REFUSED. The name predates
#                         agy's retirement; it is the vendor-neutral attestation.
#   AGY_STAGE_KEEP        1 = keep the staging dir (debugging). It NEVER keeps
#                         the build worktree — that is always removed.
#   EXT_RUN_AUDIT_LOG     the command audit log (default
#                         ~/.claude/logs/ext-run/codex-commands.jsonl).
#
# Exit codes (the contract every caller keys off):
#   0  OK          stdout is the model's answer (or the raw output with --raw)
#   2  USAGE       bad mode/flags/missing file/bad tiers file — nothing ran
#   3  REFUSED     deny-list hit, boundary not attested, codex not listed in
#                  tiers.json for this level/mode, a refused --allow-read, the
#                  retired agy vendor, or --patch-out on a dirty tree — nothing ran
#   4  UNAVAILABLE CLI missing, OS sandbox missing or not enforcing, audit log not
#                  writable, auth failed, timed out, a failure event, the response
#                  was empty, or the build stage could not be prepared. NEVER
#                  silently a pass.
#   5  SCHEMA      --schema was given and the response is not valid JSON
#   6  APPLY       build only: a patch was produced but would NOT apply cleanly
#                  to the real repo. The real repo is left exactly as it was (the
#                  apply is pre-checked; nothing is written unless it is clean);
#                  the patch is left at --output; the answer still went to stdout.
#
# WHY exit code alone is not enough:
#   codex (verified live, codex-cli 0.155.1, 2026-09-23): a failed turn emits a
#   turn.failed event and a top-level {"type":"error"} event, exits 1, and does
#   NOT write the -o file. The codex gate requires rc 0 AND a non-empty -o file
#   AND no turn.failed/error event.
#
# WHY codex runs inside an OS sandbox this script generates (sandbox-exec):
#   Staging controls what we HAND codex, not what it can REACH. codex's own
#   seatbelt blocks writes outside its workspace but not reads of the whole disk,
#   its config (sandbox_permissions) does not restrict reads, and an outer
#   sandbox-exec does NOT nest with codex's own seatbelt (every command rc 71 —
#   verified 2026-09-24, codex-cli 0.156.1). So codex's sandbox is switched off
#   (--dangerously-bypass-approvals-and-sandbox) and REPLACED by a per-run
#   profile applied by sandbox-exec around the whole codex process: nothing under
#   $HOME or the temp dirs (/private/tmp, /private/var/folders — sibling stages,
#   other runs' patches, Claude session scratchpads) is readable but the
#   workspace, ~/.codex, codex's scratch dir and each --allow-read path; writes
#   are DENIED BY DEFAULT — nothing anywhere is writable but the workspace,
#   ~/.codex, codex's own scratch dir and a few device files. The two flags travel
#   ONLY together. FAIL CLOSED: no sandbox-exec, a profile that does not apply, or
#   one that applies without enforcing (either of two canary writes that must be
#   denied lands: one in the stage root, one outside $HOME and the temp dirs) is
#   exit 4 — codex never runs unconfined, and there is no opt-out. (The canaries
#   defend against an accidental no-op or a regressed profile; whoever controls
#   PATH controls CODEX_BIN too.)
#
# WHY build mode never lets codex touch the caller's tree:
#   "Which files it may change" is best expressed as "a disposable copy": build
#   mode checks out a disposable `git worktree --detach HEAD`, carries the
#   caller's uncommitted changes and untracked files into it, commits that carried
#   state as the stage base, and points codex at the worktree. This script then
#   captures `git add -A && git diff --cached --binary` (the pure model delta,
#   because the stage base already holds the caller's changes) and applies it back
#   to the real repo. Failure to apply is exit 6, never a silent half-write, and
#   the worktree is removed on every exit path. `git add -A` honours .gitignore,
#   so files the repo ignores are NOT carried back. While codex runs, the
#   worktree's `.git` file (which names the REAL repo's gitdir) is moved into this
#   script's private meta dir — which the sandbox does not let codex write, so it
#   cannot swap in a gitdir of its own for this script's later git calls — and
#   the profile denies the real repo and its git dir outright.
set -uo pipefail

# Inherited git redirection (a git hook, a caller running under GIT_DIR=...)
# would point every `git -C` below at ANOTHER repository: -C does not override an
# absolute GIT_DIR/GIT_WORK_TREE. Cleared once, here, for this script and every
# child (the external CLI included).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
# Hard-denied for every vendor; not overridable from the environment.
HARD_DENY_REPOS="clip-creator"
CODEX_DENY_REPOS="${CODEX_DENY_REPOS:-}"
# $HOME in its physical spelling too: deny paths are compared after pwd -P, and
# the sandbox profile matches physical paths.
HOME_P=$(cd "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_P="${HOME:-/}"

E_USAGE=2
E_REFUSED=3
E_UNAVAIL=4
E_SCHEMA=5
E_APPLY=6

STAGE=""
OUTSIDE_CANARY=""   # set only while the preflight's outside canary may exist (see sandbox_preflight)
BUILD_REPO=""
BUILD_WT=""
WD_PID=""
RUN_PID=""
RUN_STARTED=0
AUDIT_DONE=0
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
  # A run interrupted before its audit (a signal mid-run) is still audited: the
  # event stream is in the stage, which goes below.
  [ "$RUN_STARTED" -eq 1 ] && audit_commands
  # A signal during the preflight: its outside canary is not in the stage.
  [ -n "$OUTSIDE_CANARY" ] && rm -f "$OUTSIDE_CANARY"
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
# A signal must still run cleanup (reap the CLI's tree, audit, restore .git,
# remove the worktree): exit through the EXIT trap.
trap 'exit 130' INT TERM HUP

die() { echo "$1" >&2; exit "$2"; }

# ---------------------------------------------------------------------------
# Mode table — write policy and timeout per mode. Models are NOT here: they come
# from tiers.json (resolve_tier below), always an explicit non-Claude id: a
# defaulted run could review Claude with Claude, defeating the cross-vendor tier.
# ---------------------------------------------------------------------------
is_mode() {
  case "$1" in
    review|read|verify|critique|fuzz|build) return 0 ;;
  esac
  return 1
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

# A model id must belong to codex.
vendor_model_ok() { # $1 = model id
  case "$1" in gpt-*|codex-*) return 0 ;; esac
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
# "which model/effort may codex use for this level/mode". An absent entry is a
# refusal — there is deliberately no default model anywhere in this script.
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
# symlink chain) of the workdir, of every --input source, of every --allow-read
# path, of a --schema file and of the prompt file — and that resolved path is
# what is then read. Component equality (not substring), so
# ".../clip-creator/media" is refused and ".../clip-creators-lab" is not. A
# .codex-deny marker file anywhere from the path up to AND INCLUDING $HOME (or /,
# outside $HOME) also refuses, so a repo can opt itself out without editing this
# script. Each of those paths that sits in a git work tree is ALSO checked via the
# main worktree of its repository (git-common-dir), so a linked worktree created
# outside a deny-listed repo is refused like the repo. (The .agy-deny markers of
# the retired agy vendor are inert.)
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

deny_names() { echo "$HARD_DENY_REPOS $CODEX_DENY_REPOS"; }

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

# allow_read_check PATH — an --allow-read path widens what the sandbox lets codex
# READ, so on top of the deny check it must not re-open $HOME wholesale (PATH is
# $HOME, or an ancestor of it) nor contain a deny-listed repo or a .codex-deny
# marker anywhere beneath it. Exits E_REFUSED on a hit; prints the resolved path.
allow_read_check() { # $1 = path as given
  local real hit name
  real=$(resolve_path "$1")
  [ -e "$real" ] || die "USAGE: --allow-read path not found: $1" "$E_USAGE"
  case "$real" in *"
"*) die "USAGE: --allow-read path contains a newline: $1" "$E_USAGE" ;; esac
  deny_check "$real" >&2
  if [ "$real" = / ] || [ "$real" = "$HOME_P" ]; then
    die "REFUSED: --allow-read $real would re-open all of \$HOME ($HOME_P) to codex." "$E_REFUSED"
  fi
  case "$HOME_P/" in
    "$real"/*) die "REFUSED: --allow-read $real is an ancestor of \$HOME ($HOME_P) — it would re-open every repo in it." "$E_REFUSED" ;;
  esac
  if [ -d "$real" ]; then
    set -- -name ".$VENDOR-deny"
    for name in $(deny_names); do set -- "$@" -o -name "$name"; done
    hit=$(find "$real" \( "$@" \) -print -quit 2>/dev/null)
    [ -z "$hit" ] || die "REFUSED: --allow-read $real contains $hit — a deny-listed repo or a .$VENDOR-deny marker lies beneath it." "$E_REFUSED"
  fi
  printf '%s\n' "$real"
}

# input_dir_check DIR — an --input-dir is copied WHOLE into the workspace, so
# everything in it leaves the machine: the deny check on DIR (and its repo's main
# worktree), no deny-listed repo or .codex-deny marker beneath it, and no symlink
# in it that resolves outside it (a link out would smuggle in whatever it names).
# Special files and trees over the size cap are usage errors. Exits on a hit;
# prints the resolved dir.
input_dir_check() { # $1 = dir as given
  local real hit name l t kb
  real=$(resolve_path "$1")
  [ -d "$real" ] || die "USAGE: --input-dir is not a directory: $1" "$E_USAGE"
  case "$real" in *"
"*) die "USAGE: --input-dir path contains a newline: $1" "$E_USAGE" ;; esac
  deny_check "$real" >&2
  if [ "$real" = / ] || [ "$real" = "$HOME_P" ]; then
    die "REFUSED: --input-dir $real would copy all of \$HOME ($HOME_P) to codex." "$E_REFUSED"
  fi
  case "$HOME_P/" in
    "$real"/*) die "REFUSED: --input-dir $real is an ancestor of \$HOME ($HOME_P)." "$E_REFUSED" ;;
  esac
  set -- -name ".$VENDOR-deny"
  for name in $(deny_names); do set -- "$@" -o -name "$name"; done
  hit=$(find "$real" \( "$@" \) -print -quit 2>/dev/null)
  [ -z "$hit" ] || die "REFUSED: --input-dir $real contains $hit — a deny-listed repo or a .$VENDOR-deny marker lies beneath it." "$E_REFUSED"
  while IFS= read -r -d '' l; do
    t=$(resolve_path "$l")
    case "$t/" in
      "$real"/*) ;;
      *) die "REFUSED: --input-dir $real holds a symlink that leaves it ($l -> $(readlink "$l")) — stage the target itself, or drop the link." "$E_REFUSED" ;;
    esac
  done < <(find "$real" -type l -print0 2>/dev/null)
  hit=$(find "$real" ! -type f ! -type d ! -type l -print -quit 2>/dev/null)
  [ -z "$hit" ] || die "USAGE: --input-dir $real holds a special file ($hit) — only regular files, directories and links inside it can be staged." "$E_USAGE"
  kb=$(du -sk "$real" 2>/dev/null | cut -f1)
  case "$kb" in ''|*[!0-9]*) die "USAGE: could not measure --input-dir $real" "$E_USAGE" ;; esac
  if [ "$kb" -gt $((INPUT_DIR_MAX_MB * 1024)) ]; then
    die "USAGE: --input-dir $real is $(( (kb + 1023) / 1024 )) MB, over the ${INPUT_DIR_MAX_MB} MB cap — stage less, or raise the cap with --input-dir-max-mb." "$E_USAGE"
  fi
  printf '%s\n' "$real"
}

# resolve_bin NAME|PATH — the real file an executable name or path runs: a name
# is looked up on PATH only (type -P: never a shell function or alias), then the
# whole symlink chain is resolved. Prints nothing (rc 1) when there is none.
resolve_bin() {
  local p
  case "$1" in
    */*) p="$1" ;;
    *) p=$(type -P "$1" 2>/dev/null) || return 1 ;;
  esac
  [ -n "$p" ] || return 1
  p=$(resolve_path "$p")
  [ -f "$p" ] && [ -x "$p" ] || return 1
  printf '%s\n' "$p"
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || die "USAGE: ext-run.sh <review|read|verify|critique|fuzz|build> --prompt-file FILE [--vendor codex] [options]" "$E_USAGE"
MODE="$1"; shift
is_mode "$MODE" || die "USAGE: unknown mode '$MODE' (review|read|verify|critique|fuzz|build)" "$E_USAGE"

VENDOR="codex"
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
INPUT_DIRS=()
INPUT_DIR_MAX_MB=200
ALLOW_READS=()

# Every value-taking option REQUIRES its value: a trailing `--vendor` would make
# `shift 2` fail without shifting, and the loop would spin forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift; continue ;;
    --vendor|--level|--prompt-file|--input|--input-dir|--input-dir-max-mb|--allow-read|--schema|--workdir|--output|--patch-out|--check|--model|--effort|--timeout)
      [ $# -ge 2 ] || die "USAGE: $1 needs a value" "$E_USAGE" ;;
    *) die "USAGE: unknown argument '$1'" "$E_USAGE" ;;
  esac
  case "$1" in
    --vendor)      VENDOR="$2" ;;
    --level)       LEVEL="$2" ;;
    --prompt-file) PROMPT_FILE="$2" ;;
    --input)       INPUTS+=("$2") ;;
    --input-dir)   INPUT_DIRS+=("$2") ;;
    --input-dir-max-mb) INPUT_DIR_MAX_MB="$2" ;;
    --allow-read)  ALLOW_READS+=("$2") ;;
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
  codex) ;;
  agy) die "REFUSED: agy retired 2026-09-24 — Antigravity bypassed its own sandbox (a model-settable BypassSandbox flag) and wrote into a real repo; codex is the only external vendor." "$E_REFUSED" ;;
  *) die "USAGE: unknown --vendor '$VENDOR' (codex)" "$E_USAGE" ;;
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
# Data — diffs, logs, corpora — belongs in --input (staged as a file the CLI
# opens itself), NOT inlined into the brief. Fail loudly rather than send a
# prompt that big.
PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
if [ "$PROMPT_BYTES" -gt 262144 ]; then
  die "USAGE: prompt file is ${PROMPT_BYTES} bytes (>256KB) — pass bulk data with --input instead of inlining it into the brief." "$E_USAGE"
fi

command -v jq >/dev/null 2>&1 || die "USAGE: jq is required" "$E_USAGE"
find_tiers
resolve_tier

MODEL="$TIER_MODEL"
[ -n "$MODEL_OVERRIDE" ] && MODEL="$MODEL_OVERRIDE"
[ -n "$EFFORT" ] || EFFORT="$TIER_EFFORT"
[ -n "$EFFORT" ] || die "USAGE: $TIERS gives no effort for this codex entry and --effort was not passed" "$E_USAGE"
case "$EFFORT" in
  minimal|low|medium|high|xhigh|max) ;;  # gpt-6-* list max (~/.codex/models_cache.json); 'ultra' auto-delegates, excluded
  *) die "USAGE: --effort must be minimal|low|medium|high|xhigh|max for codex (got '$EFFORT')" "$E_USAGE" ;;
esac
[ -n "$(to_seconds "$TIMEOUT")" ] || die "USAGE: --timeout must be N, Ns, Nm or Nh (got '$TIMEOUT')" "$E_USAGE"
case "$MODEL" in
  claude*|*claude*) die "USAGE: refusing to run the cross-vendor tier on a Claude model ('$MODEL')." "$E_USAGE" ;;
esac
vendor_model_ok "$MODEL" || die "USAGE: model '$MODEL' does not belong to vendor '$VENDOR' (codex: gpt-*|codex-*)" "$E_USAGE"

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
if [ ${#INPUT_DIRS[@]} -gt 0 ] && mode_writes "$MODE"; then
  die "USAGE: --input-dir is only valid in read-only modes (build mode works in a disposable worktree of --workdir)" "$E_USAGE"
fi
case "$INPUT_DIR_MAX_MB" in
  ''|*[!0-9]*|0) die "USAGE: --input-dir-max-mb must be a positive whole number of MB (got '$INPUT_DIR_MAX_MB')" "$E_USAGE" ;;
esac
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
# not this script, knows whether the material is clinical/PHI or restricted.
[ "${AGY_BOUNDARY_CLEARED:-}" = "1" ] || \
  die "REFUSED: AGY_BOUNDARY_CLEARED is not set — the caller must attest the data boundary was checked before anything leaves the machine." "$E_REFUSED"

deny_check "$PROMPT_FILE"
if [ -n "$WORKDIR" ]; then deny_check "$WORKDIR"; fi
if [ -n "$SCHEMA" ] && [ -f "$SCHEMA" ]; then SCHEMA=$(resolve_path "$SCHEMA"); deny_check "$SCHEMA"; fi
if [ -n "$SCHEMA" ]; then
  if [ -f "$SCHEMA" ]; then jq -e . "$SCHEMA" >/dev/null 2>&1
  else printf '%s' "$SCHEMA" | jq -e . >/dev/null 2>&1
  fi || die "USAGE: --schema is neither a readable JSON file nor inline JSON" "$E_USAGE"
fi
ALLOW_READ_ABS=()
for ar in ${ALLOW_READS+"${ALLOW_READS[@]}"}; do
  ar_real=$(allow_read_check "$ar") || exit $?
  ALLOW_READ_ABS+=("$ar_real")
done

# --input files: resolved and deny-checked now (copied into the stage below),
# so every refusal happens before anything is staged, on every platform.
INPUT_REALS=()
for src in ${INPUTS+"${INPUTS[@]}"}; do
  real=$(resolve_path "$src")
  [ -f "$real" ] || die "USAGE: --input file not found: $src" "$E_USAGE"
  deny_check "$real"
  INPUT_REALS+=("$real")
done
# --input-dir trees: checked now too (copied into the stage below). Each lands at
# inputs/<basename>, so no two staged names may collide.
INPUT_DIR_REALS=()
for src in ${INPUT_DIRS+"${INPUT_DIRS[@]}"}; do
  real=$(input_dir_check "$src") || exit $?
  INPUT_DIR_REALS+=("$real")
done
if [ ${#INPUT_DIRS[@]} -gt 0 ]; then
  dup=$(for src in ${INPUTS+"${INPUTS[@]}"} "${INPUT_DIRS[@]}"; do basename "$src"; done | sort | uniq -d | head -n 1)
  [ -z "$dup" ] || die "USAGE: two staged inputs share the name '$dup' (--input files and --input-dir trees land side by side in inputs/)" "$E_USAGE"
fi

# Build mode: the repo behind --workdir, checked before anything is staged.
if mode_writes "$MODE"; then
  command -v git >/dev/null 2>&1 || die "USAGE: git is required for build mode (the run is staged in a disposable worktree)" "$E_USAGE"
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
fi

# The codex binary is the REAL file it names (never a shell function), and the
# OS sandbox must exist: without it codex is never run (fail closed).
CODEX_REAL=$(resolve_bin "$CODEX_BIN") || die "UNAVAILABLE: $CODEX_BIN is not installed or not on PATH." "$E_UNAVAIL"
SANDBOX_EXEC=$(resolve_bin sandbox-exec) || \
  die "UNAVAILABLE: sandbox-exec not found — codex runs only inside the OS sandbox this script generates (macOS sandbox-exec), never unconfined." "$E_UNAVAIL"
[ -n "${HOME:-}" ] && [ "$HOME_P" != / ] || \
  die "UNAVAILABLE: HOME is unset or / — the sandbox profile is scoped to \$HOME." "$E_UNAVAIL"
# The command audit log must be writable before codex runs: an unaudited run is
# exactly what it exists to prevent.
AUDIT_LOG="${EXT_RUN_AUDIT_LOG:-$HOME/.claude/logs/ext-run/codex-commands.jsonl}"
AUDIT_DIR=$(dirname "$AUDIT_LOG")
{ mkdir -p "$AUDIT_DIR" 2>/dev/null && [ -w "$AUDIT_DIR" ]; } || \
  die "UNAVAILABLE: the command audit log dir $AUDIT_DIR is not writable — codex runs only audited." "$E_UNAVAIL"

# ---------------------------------------------------------------------------
# Staging. Read-only modes get a fresh empty dir as the workspace containing ONLY
# the staged inputs; build mode gets a disposable checkout (the worktree section
# below). The sandbox profile, not a flag, is what keeps codex off everything
# else.
#   $STAGE/ws     the workspace (read-only modes): ONLY the staged inputs, so
#                 anything else appearing in it is something codex wrote.
#   $STAGE/build  the workspace (build mode): the disposable worktree.
#   $STAGE/cx     codex's own scratch: its TMPDIR, the -o final message and the
#                 --output-schema copy. The only stage dir besides the workspace
#                 it may write.
#   $STAGE/meta   this script's private files (prompt, event stream, stderr,
#                 profile, the hidden .git): neither readable nor writable by
#                 codex (it gets the prompt on stdin and writes the event stream
#                 through inherited fds), so it can neither rewrite its own audit
#                 trail nor swap the .git pointer.
# ---------------------------------------------------------------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ext-run.XXXXXX") || die "USAGE: could not create a staging dir" "$E_USAGE"
mkdir -p "$STAGE/ws/inputs" "$STAGE/meta" "$STAGE/cx/tmp"
STAGE_ABS=$(resolve_path "$STAGE")
RUN_ID=$(basename "$STAGE_ABS")
CX="$STAGE_ABS/cx"
[ "${AGY_STAGE_KEEP:-0}" = "1" ] && echo "ext-run: staging dir kept at $STAGE_ABS" >&2

# ---------------------------------------------------------------------------
# Build staging worktree. codex is pointed at $BUILD_WT, never at $BUILD_REPO.
# ---------------------------------------------------------------------------
if mode_writes "$MODE"; then
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

# --input staging. Read-only modes: $STAGE/ws/inputs. Build: .codex-inputs
# inside the worktree (codex only sees the worktree), removed again before the
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
i=0
while [ "$i" -lt ${#INPUT_REALS[@]} ]; do
  src="${INPUTS[$i]}"
  # Staged under the name the caller gave, read from the path that was checked.
  cp "${INPUT_REALS[$i]}" "$INPUT_DIR/$(basename "$src")" || die "UNAVAILABLE: could not stage --input $src" "$E_UNAVAIL"
  STAGED_LIST="$STAGED_LIST  $INPUT_DIR/$(basename "$src")
"
  i=$((i + 1))
done

# --input-dir trees (read-only modes): a copy, links kept as links — every one
# of them was proven above to resolve inside its own tree.
i=0
while [ "$i" -lt ${#INPUT_DIR_REALS[@]} ]; do
  dst="$INPUT_DIR/$(basename "${INPUT_DIRS[$i]}")"
  { mkdir "$dst" && cp -RP "${INPUT_DIR_REALS[$i]}/." "$dst/"; } 2>"$STAGE/meta/input-dir.err" ||
    die "UNAVAILABLE: could not stage --input-dir ${INPUT_DIRS[$i]} — $(head -c 300 "$STAGE/meta/input-dir.err")" "$E_UNAVAIL"
  STAGED_LIST="$STAGED_LIST  $dst/ (a directory: $(find "$dst" -type f | wc -l | tr -d ' ') files; read what you need from it)
"
  i=$((i + 1))
done

RUNDIR="$STAGE/ws"
mode_writes "$MODE" && RUNDIR="$BUILD_WT"
RUNDIR_ABS=$(resolve_path "$RUNDIR")

# --schema, codex side. codex's --output-schema is OpenAI STRICT structured
# output: an object schema without additionalProperties:false, or with a
# property missing from `required`, is rejected by the API (codex exits 1, the
# run is UNAVAILABLE). Callers write ordinary JSON Schema, so the copy codex
# gets is normalized (STRICT_SCHEMA_JQ): every object with `properties` gets
# additionalProperties:false and required = all its properties, and a property
# that was optional becomes nullable instead (type T -> [T,"null"], null added to
# an enum, {"type":"null"} added to anyOf/oneOf, a $ref/const wrapped in anyOf).
# Recurses into properties, items, anyOf/oneOf/allOf, $defs/definitions;
# anything else is left as-is. The reply is mapped back to the caller's schema
# (DENULL_JQ, below): a null for an originally-optional property is dropped.
# Codex adapter only: the caller's file is never modified.
STRICT_SCHEMA_JQ='
def nullable:
  def addnull: if any(.[]; . == {"type": "null"}) then . else . + [{"type": "null"}] end;
  if (.anyOf | type) == "array" then .anyOf |= addnull
  elif (.oneOf | type) == "array" then .oneOf |= addnull
  elif has("type") or has("enum") then
    (if (.enum | type) == "array" and (any(.enum[]; . == null) | not) then .enum += [null] else . end)
    | (if has("type") then .type = ((if (.type | type) == "array" then .type else [.type] end)
                                   | if any(.[]; . == "null") then . else . + ["null"] end)
       else . end)
  elif has("$ref") or has("const") then {"anyOf": [., {"type": "null"}]}
  else . end;
def strict:
  if type != "object" then .
  else
    (if (.properties | type) == "object" then
       ((.required // []) | if type == "array" then . else [] end) as $req
       | .properties |= with_entries(.key as $k
           | .value |= (strict | if any($req[]; . == $k) then . else nullable end))
       | .additionalProperties = false
       | .required = (.properties | keys_unsorted)
     else . end)
    | (if (.items | type) == "object" then .items |= strict
       elif (.items | type) == "array" then .items |= map(strict) else . end)
    | reduce ("anyOf", "oneOf", "allOf") as $kw (.;
        if (.[$kw] | type) == "array" then .[$kw] |= map(strict) else . end)
    | reduce ("$defs", "definitions") as $kw (.;
        if (.[$kw] | type) == "object" then .[$kw] |= map_values(strict) else . end)
  end;
strict'
# DENULL_JQ — the reply, walked against the ORIGINAL schema ($s[0]): a null value
# under a property that schema did not require is removed, so the caller sees the
# shape it asked for. Local $refs ("#/...") are followed; for anyOf/oneOf the
# first branch that fits the value (an object's keys all declared, or an array
# schema for an array) is used.
DENULL_JQ='
def resolve($root):
  if type == "object" and (.["$ref"] | type) == "string" and (.["$ref"] | startswith("#/"))
  then (.["$ref"][2:] | split("/")) as $p | ($root | getpath($p)) // {} else . end;
def denull($root; $schema):
  ($schema | resolve($root)) as $s
  | if ($s | type) != "object" then .
    elif type == "object" and ($s.properties | type) == "object" then
      ((($s.required // []) | if type == "array" then . else [] end)) as $req
      | reduce ($s.properties | keys_unsorted[]) as $k (.;
          if has($k) | not then .
          elif .[$k] == null and (any($req[]; . == $k) | not) then del(.[$k])
          else .[$k] |= denull($root; $s.properties[$k]) end)
    elif type == "array" and ($s.items | type) == "object" then map(denull($root; $s.items))
    elif ($s.allOf | type) == "array" then reduce $s.allOf[] as $b (.; denull($root; $b))
    elif (($s.anyOf // $s.oneOf) | type) == "array" and (type == "object" or type == "array") then
      . as $v
      | ([($s.anyOf // $s.oneOf)[] | resolve($root) | select(type == "object")
          | select(if ($v | type) == "object"
                   then (.properties | type) == "object" and ((($v | keys) - (.properties | keys)) == [])
                   else (.items | type) == "object" end)] | first) as $b
      | if $b == null then . else denull($root; $b) end
    else . end;
denull($s[0]; $s[0])'

# The --output-schema file is read by codex itself, inside the sandbox, so it is
# always a copy in codex's scratch dir (a caller's schema under $HOME would be
# unreadable there). The original goes to the private meta dir for DENULL_JQ.
SCHEMA_FILE=""
SCHEMA_ORIG=""
if [ -n "$SCHEMA" ]; then
  SCHEMA_FILE="$CX/schema.json"
  SCHEMA_ORIG="$STAGE/meta/schema.orig.json"
  if [ -f "$SCHEMA" ]; then jq -c . "$SCHEMA" > "$SCHEMA_ORIG"
  else printf '%s' "$SCHEMA" | jq -c . > "$SCHEMA_ORIG"
  fi || die "UNAVAILABLE: could not stage --schema $SCHEMA" "$E_UNAVAIL"
  jq -c "$STRICT_SCHEMA_JQ" "$SCHEMA_ORIG" > "$SCHEMA_FILE" || die "UNAVAILABLE: could not normalize --schema to OpenAI-strict form" "$E_UNAVAIL"
fi

# The prompt codex actually sees: the brief, plus a footer naming the workspace
# and every staged file by ABSOLUTE path, so the brief says where the files are
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
# This footer scopes it back to a headless, OS-confined worker.
{
  printf '\n--- Non-interactive worker ---\n'
  printf 'You are a non-interactive worker. Nobody will answer questions: do not ask any;\n'
  printf 'make the most reasonable assumption and state it in your answer.\n'
  printf 'Do not create or edit PROJECT_MEMORY.md, handoff files, engram, or any memory file.\n'
  printf 'Touch only files inside the workspace named above.\n'
  printf 'Your filesystem access is limited to this workspace; other paths will fail - do not search the disk.\n'
} >> "$PROMPT"
if [ ${#ALLOW_READ_ABS[@]} -gt 0 ]; then
  {
    printf 'Also readable (read-only):\n'
    printf '  %s\n' "${ALLOW_READ_ABS[@]}"
  } >> "$PROMPT"
fi
# Build mode hides the worktree's .git during the run (the pointer names the
# caller's real gitdir), so say so: a self-check that shells out to git would fail.
if mode_writes "$MODE"; then
  printf '\nNote: git is unavailable in this workspace during your run; do not run git commands. Checks that need git run afterwards, outside your session.\n' >> "$PROMPT"
fi

# ---------------------------------------------------------------------------
# The OS sandbox profile (SBPL), generated per run. write_profile is the SINGLE
# OWNER of what codex may read and write. Rules are last-match-wins, so each
# deny comes before the allows that carve out of it. Every path is physical
# (resolve_path / pwd -P: the sandbox matches real paths) and SBPL-escaped.
#   read:  everything but $HOME and the temp dirs (/private/tmp,
#          /private/var/folders, and their /tmp, /var/folders spellings), where
#          sibling compare stages, other runs' patches and Claude session
#          scratchpads live. Of those, only $HOME itself (the directory entry),
#          ~/.codex, the workspace, codex's scratch dir and each --allow-read path
#          are readable — never the stage root or $STAGE/meta — plus the METADATA
#          (stat, never a listing) of every ancestor of those: realpath() in git
#          and node lstat()s each component (verified: both fail on a denied
#          /private/tmp without it). One file in the per-user temp dir is
#          readable too, never writable: xcrun's tool-path cache
#          ($(getconf DARWIN_USER_TEMP_DIR)/xcrun_db), without which every
#          /usr/bin/git, python3, make... shim takes ~2s instead of ~20ms
#          (verified); writable, it could redirect those shims for later,
#          unsandboxed sessions. In build mode never the real repo, its main
#          worktree or its git dir.
#   write: DENY BY DEFAULT (subpath "/"): nothing anywhere — not /opt/homebrew,
#          /Users/Shared, /private/var/tmp, mounted volumes — but ~/.codex, the
#          workspace and codex's scratch dir, plus these device files (each one
#          verified 2026-09-24, macOS 26.6 / codex-cli 0.156.1, with a
#          kill-on-touch rule and the stub):
#            /dev/null          every shell redirect (>/dev/null 2>&1).
#            /dev/tty           bash, sh and zsh open it at every start (also
#                               under git's and python3's xcrun shims); a headless
#                               run has no controlling terminal, so the open then
#                               fails ENXIO as it would unsandboxed.
#            /dev/dtracehelper  dyld opens it at every process start (sh, bash,
#                               zsh, git, python3, node, codex) to register DTrace
#                               probes; no filesystem effect.
#            /dev/fd/N          > /dev/stdout, 2> /dev/stderr, tee /dev/stderr,
#                               >(...) process substitution.
#            /dev/ptmx, /dev/ttysN
#                               codex's exec_command allocates a PTY when the model
#                               passes tty:true; a tty is writable only if it was
#                               created inside the sandbox (the
#                               com.apple.sandbox.pty extension), so the user's own
#                               terminals stay unwritable.
# ---------------------------------------------------------------------------
sbpl_q() { # $1 = path -> an SBPL string literal. A newline is never escaped: die.
  local s="$1"
  case "$s" in *"
"*) die "UNAVAILABLE: a sandbox path contains a newline ($s) — cannot confine codex." "$E_UNAVAIL" ;; esac
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
# sbpl_ancestors PATH... — ' (literal "<dir>")' for every proper ancestor of each
# PATH except /, each once (an ancestor already emitted means all of its own are).
sbpl_ancestors() {
  local p seen="
"
  for p in "$@"; do
    while :; do
      p=$(dirname "$p")
      [ "$p" != / ] && [ "$p" != . ] || break
      case "$seen" in *"
$p
"*) break ;; esac
      seen="$seen$p
"
      printf ' (literal %s)' "$(sbpl_q "$p")"
    done
  done
}
# xcrun_cache_rule — ' (literal "<per-user temp dir>/xcrun_db")' on macOS, else
# nothing. Physical path; only ever under /private/var/folders.
xcrun_cache_rule() {
  local t
  t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || return 0
  [ -n "$t" ] && t=$(cd "$t" 2>/dev/null && pwd -P) || return 0
  case "$t" in /private/var/folders/*) printf ' (literal %s)' "$(sbpl_q "$t/xcrun_db")" ;; esac
}
PROFILE="$STAGE/meta/sandbox.sb"
write_profile() {
  local codex_home repo_rule p common main anc xcrun
  codex_home="$HOME_P/.codex"
  repo_rule=""
  if mode_writes "$MODE"; then
    repo_rule="(subpath $(sbpl_q "$BUILD_REPO"))"
    common=$(git -C "$BUILD_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ -n "$common" ] && repo_rule="$repo_rule (subpath $(sbpl_q "$(resolve_path "$common")"))"
    main=$(main_worktree_of "$BUILD_REPO")
    [ -n "$main" ] && [ "$main" != "$BUILD_REPO" ] && repo_rule="$repo_rule (subpath $(sbpl_q "$main"))"
  fi
  # Never empty ($HOME_P is not /), and an empty filter list would allow the
  # metadata of every path: refuse to write such a profile.
  anc=$(sbpl_ancestors "$codex_home" "$RUNDIR_ABS" "$CX" ${ALLOW_READ_ABS+"${ALLOW_READ_ABS[@]}"})
  [ -n "$anc" ] || die "UNAVAILABLE: no ancestor paths for the sandbox's metadata rule — cannot confine codex." "$E_UNAVAIL"
  xcrun=$(xcrun_cache_rule)
  {
    printf '(version 1)\n'
    printf '(allow default)\n'
    printf '(deny file-read* (subpath %s) (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/tmp") (subpath "/var/folders"))\n' "$(sbpl_q "$HOME_P")"
    [ -n "$repo_rule" ] && printf '(deny file-read* file-write* %s)\n' "$repo_rule"
    printf '(allow file-read* (literal %s) (subpath %s) (subpath %s) (subpath %s)' \
      "$(sbpl_q "$HOME_P")" "$(sbpl_q "$codex_home")" "$(sbpl_q "$RUNDIR_ABS")" "$(sbpl_q "$CX")"
    for p in ${ALLOW_READ_ABS+"${ALLOW_READ_ABS[@]}"}; do printf ' (subpath %s)' "$(sbpl_q "$p")"; done
    printf ')\n'
    printf '(allow file-read-metadata%s)\n' "$anc"
    [ -n "$xcrun" ] && printf '(allow file-read*%s)\n' "$xcrun"
    printf '(deny file-write* (subpath "/"))\n'
    printf '(allow file-write* (subpath %s) (subpath %s) (subpath %s))\n' \
      "$(sbpl_q "$codex_home")" "$(sbpl_q "$RUNDIR_ABS")" "$(sbpl_q "$CX")"
    printf '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/[0-9]+$") (literal "/dev/ptmx"))\n'
    printf '(allow file-write* (require-all (regex #"^/dev/ttys[0-9]+$") (extension "com.apple.sandbox.pty")))\n'
  } > "$PROFILE"
}
write_profile

# outside_canary_path — the preflight's second canary: a file in an always-present,
# user-writable dir OUTSIDE $HOME, the temp dirs and the stage, so that only the
# profile's deny-by-default write rule can stop it (a profile that confined just
# $HOME, the temp dirs and the stage — the pre-2026-09-24 one — lets it land).
# /Users/Shared (macOS: world-writable, sticky), else /private/var/tmp, else
# /var/tmp (Linux: only the test double runs there). The name carries the run id
# (the stage's random mktemp suffix). Prints nothing (rc 1) when none qualifies.
outside_canary_path() {
  local d p
  for d in /Users/Shared /private/var/tmp /var/tmp; do
    [ -d "$d" ] && [ -w "$d" ] || continue
    p=$(cd "$d" 2>/dev/null && pwd -P) || continue
    case "$p/" in
      "$HOME_P"/*|"$STAGE_ABS"/*|/private/tmp/*|/private/var/folders/*|/tmp/*|/var/folders/*) continue ;;
    esac
    printf '%s/.ext-run-canary-%s\n' "$p" "$RUN_ID"
    return 0
  done
  return 1
}

# sandbox_preflight — FAIL CLOSED before codex ever starts: the profile must apply
# (sandbox-exec runs a trivial command under it) AND enforce: that command's
# writes to two paths the profile denies must not land — the stage root (inside
# the temp dirs) and the outside canary (outside $HOME and the temp dirs: only
# deny-by-default covers it). Anything that lands is removed first; then either
# failure is exit 4. There is no opt-out.
sandbox_preflight() {
  local canary="$STAGE_ABS/.sandbox-canary" outside rc c landed=""
  outside=$(outside_canary_path) || \
    die "UNAVAILABLE: no writable directory outside \$HOME and the temp dirs (/Users/Shared, /private/var/tmp, /var/tmp) for the sandbox's enforcement canary — codex is never run unconfined." "$E_UNAVAIL"
  if [ -e "$outside" ] || [ -L "$outside" ]; then
    die "UNAVAILABLE: the sandbox canary path $outside already exists (not this run's) — codex is never run unconfined." "$E_UNAVAIL"
  fi
  rm -f "$canary"
  OUTSIDE_CANARY="$outside"
  ( cd "$RUNDIR_ABS" && export TMPDIR="$CX/tmp" && exec "$SANDBOX_EXEC" -f "$PROFILE" /bin/sh -c 'true > "$1"; true > "$2"; exit 0' sh "$canary" "$outside" ) \
    > "$STAGE/meta/preflight.log" 2>&1 </dev/null
  rc=$?
  for c in "$canary" "$outside"; do
    if [ -e "$c" ] || [ -L "$c" ]; then rm -f "$c"; landed="$landed $c"; fi
  done
  OUTSIDE_CANARY=""
  if [ "$rc" -ne 0 ]; then
    die "UNAVAILABLE: the sandbox profile did not apply ($SANDBOX_EXEC exited $rc: $(head -c 300 "$STAGE/meta/preflight.log")) — codex is never run unconfined." "$E_UNAVAIL"
  fi
  if [ -n "$landed" ]; then
    die "UNAVAILABLE: $SANDBOX_EXEC ran but did not enforce the profile (a write it must deny landed:$landed) — codex is never run unconfined." "$E_UNAVAIL"
  fi
}
sandbox_preflight

# Read-only modes: fingerprint the stage so we can SAY whether the run tried to
# write. It is contained either way (the stage is thrown away), but a silent
# containment is a bad habit — report it.
STAGE_BEFORE=""
if ! mode_writes "$MODE"; then
  STAGE_BEFORE=$(find "$STAGE/ws" -type f | sort | sed "s#^$STAGE/ws/##")
fi

ERRLOG="$STAGE/meta/cli.err"
EVENTS="$STAGE/meta/events.jsonl"      # codex --json (codex writes it through its inherited stdout)
LASTMSG="$CX/last-message.txt"         # codex -o
TIMEDOUT_MARK="$STAGE/meta/timed-out"
RC=0

# ---------------------------------------------------------------------------
# Command audit log. codex runs --ephemeral, so nothing of what it ran survives
# the stage: after every run, one JSONL line per command_execution item of the
# --json stream is appended to $AUDIT_LOG — {ts, runId, mode, model, cwd,
# command (first 500 chars), exitCode} and NEVER aggregated_output or any file
# content. The log is written by this script, outside the sandbox (codex cannot
# write it). Lines older than 30 days are pruned opportunistically, under a
# mkdir lock that concurrent runs share (no lock after ~5s: append only).
# ---------------------------------------------------------------------------
audit_lock() { # $1 = lock dir. rc 0 = held.
  local n=0
  while ! mkdir "$1" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -eq 25 ] && [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$1" 2>/dev/null   # stale: its holder died over a minute ago
    fi
    [ "$n" -lt 50 ] || return 1
    sleep 0.1
  done
  return 0
}
audit_prune() { # $1 = log. Keeps only lines stamped within the last 30 days.
  local cutoff first
  [ -s "$1" ] || return 0
  cutoff=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  [ -n "$cutoff" ] || return 0
  first=$(head -n 1 "$1" | jq -r '.ts // empty' 2>/dev/null)
  [ -n "$first" ] && [[ "$first" < "$cutoff" ]] || return 0
  if jq -R -c --arg c "$cutoff" 'fromjson? | select(type == "object" and ((.ts // "") | tostring) >= $c)' "$1" > "$1.prune.$$" 2>/dev/null; then
    cat "$1.prune.$$" > "$1"
  fi
  rm -f "$1.prune.$$"
}
audit_commands() {
  [ "$AUDIT_DONE" -eq 0 ] || return 0
  AUDIT_DONE=1
  [ -s "$EVENTS" ] || return 0
  local ts lines
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The LAST event per item id (item.completed over item.started), in order of
  # first appearance; an item with no id stands alone.
  lines=$(jq -R -c 'fromjson? | select(type == "object" and ((.type // "") | tostring | startswith("item.")) and (.item | type) == "object" and .item.type == "command_execution") | .item' "$EVENTS" 2>/dev/null |
    jq -s -c --arg ts "$ts" --arg run "$RUN_ID" --arg mode "$MODE" --arg model "$MODEL" --arg cwd "$RUNDIR_ABS" '
      reduce .[] as $it ({order: [], last: {}};
        (if ($it.id | type) == "string" then "id:" + $it.id else "n:" + (.order | length | tostring) end) as $k
        | (if .last[$k] == null then .order += [$k] else . end) | .last[$k] = $it)
      | .order[] as $k | .last[$k]
      | {ts: $ts, runId: $run, mode: $mode, model: $model, cwd: $cwd,
         command: ((.command | if type == "string" then . elif type == "array" then map(tostring) | join(" ") else tostring end) | .[0:500]),
         exitCode: (.exit_code | if type == "number" then . else null end)}' 2>/dev/null)
  [ -n "$lines" ] || return 0
  if audit_lock "$AUDIT_LOG.lock"; then
    audit_prune "$AUDIT_LOG"
    printf '%s\n' "$lines" >> "$AUDIT_LOG" || echo "ext-run: WARNING could not append to the command audit log $AUDIT_LOG" >&2
    rmdir "$AUDIT_LOG.lock" 2>/dev/null
  else
    printf '%s\n' "$lines" >> "$AUDIT_LOG" || echo "ext-run: WARNING could not append to the command audit log $AUDIT_LOG" >&2
  fi
}

# ---------------------------------------------------------------------------
# codex adapter. Flags — verified live against codex-cli 0.155.1 (2026-09-23) and
# the sandbox-exec wrapping against 0.156.1 (2026-09-24):
#   sandbox-exec -f <profile>       the OS confinement (see write_profile), always.
#   exec -C <rundir>                non-interactive; workspace root pinned here,
#                                   and the process cwd is the same dir (a cwd
#                                   outside the profile's allowed paths fails at
#                                   startup).
#   --dangerously-bypass-approvals-and-sandbox
#                                   codex's own seatbelt OFF — it does not nest
#                                   inside sandbox-exec. Passed ONLY here, ONLY
#                                   under sandbox-exec.
#   -m / -c model_reasoning_effort  always explicit, from tiers.json.
#   --ephemeral                     no session files persisted (hence the audit log).
#   --skip-git-repo-check           the read-only stage is not a git repo.
#   --ignore-user-config            no ~/.codex/config.toml (notify hooks etc.);
#                                   auth is kept.
#   --json -o <file>                JSONL events on stdout; final message in -o
#                                   (in codex's scratch dir: it must be writable).
#   -c web_search="live"            verify mode only.
#   - <PROMPT                       brief on stdin, never on argv.
#   TMPDIR=<scratch>/tmp            codex's temp files stay in its scratch dir.
# CODEX_HOME is unset for the run: the profile allows exactly ~/.codex. codex has
# no print-timeout, so a bash-3.2-safe background watchdog enforces the mode's
# wall-clock limit.
# ---------------------------------------------------------------------------
codex_invoke() {
  local tsecs
  tsecs=$(to_seconds "$TIMEOUT")
  set -- exec -C "$RUNDIR_ABS" --dangerously-bypass-approvals-and-sandbox -m "$MODEL" -c "model_reasoning_effort=$EFFORT"
  set -- "$@" --ephemeral --skip-git-repo-check --ignore-user-config --json -o "$LASTMSG"
  [ -n "$SCHEMA_FILE" ] && set -- "$@" --output-schema "$SCHEMA_FILE"
  [ "$MODE" = "verify" ] && set -- "$@" -c 'web_search="live"'
  set -- "$@" -
  # Its own process group (set -m): the watchdog and reap_tree signal the WHOLE
  # tree, so a grandchild (a tool the CLI spawned) cannot outlive the run.
  set -m
  ( cd "$RUNDIR_ABS" && unset CODEX_HOME && export TMPDIR="$CX/tmp" &&
    exec "$SANDBOX_EXEC" -f "$PROFILE" "$CODEX_REAL" "$@" ) < "$PROMPT" > "$EVENTS" 2> "$ERRLOG" &
  RUN_PID=$!
  RUN_STARTED=1
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

# Build: hide the worktree's .git file for the duration of the run. It names the
# REAL repo's gitdir; it waits in the private meta dir (not codex-writable).
# restore_git puts it back — below, and in the exit trap.
if mode_writes "$MODE"; then
  HIDDEN_GIT="$STAGE/meta/worktree.git"
  mv "$BUILD_WT/.git" "$HIDDEN_GIT" || { HIDDEN_GIT=""; die "UNAVAILABLE: could not detach the build worktree's .git for the run" "$E_UNAVAIL"; }
fi

RUN_START=$SECONDS
codex_invoke
ELAPSED=$((SECONDS - RUN_START))
# The CLI has exited; clear anything it left running (grandchildren), record what
# it ran, then give the worktree its .git back before this script's own git calls.
if [ -n "$RUN_PID" ]; then reap_tree "$RUN_PID" reaped; RUN_PID=""; fi
audit_commands
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
# Result gating. Every gate must hold before this is a pass.
# ---------------------------------------------------------------------------
gate_fail() { # $1 = message, $2 = exit code
  if mode_writes "$MODE"; then
    echo "note: the build patch was NOT applied; it is left at $OUTPUT" >&2
  fi
  die "$1" "$2"
}

RESPONSE=""
# codex_stderr — the CLI's stderr minus the skills-loader lines it logs on every
# confined run (it walks ~/.agents/skills, which the profile denies: expected,
# harmless, and long enough to push the real error out of the reason).
codex_stderr() {
  grep -v 'codex_skills_extension.*failed to walk skills root' "$ERRLOG" 2>/dev/null
}
codex_detail() { # the most useful one-line reason codex gave, plus stderr
  local msg
  # The first failure message, on ONE line: an API error arrives as a
  # (pretty-printed) JSON document inside .message, so it is re-serialized
  # compactly rather than cut at its first line (which was just "{").
  msg=$(jq -rR 'fromjson? | select(type == "object") | select(.type == "error" or .type == "turn.failed")
    | (.message // .error.message // empty)
    | if type == "string" then ((try fromjson catch null) as $j
        | if ($j | type) == "object" or ($j | type) == "array" then ($j | tojson) else . end)
      else tojson end
    | gsub("\\s+"; " ")' "$EVENTS" 2>/dev/null | head -1 | head -c 1500)
  printf '%s %s' "$msg" "$(codex_stderr | tr '\n' ' ' | head -c 600)"
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

codex_gate
if [ -n "$SCHEMA" ]; then
  if ! printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    gate_fail "SCHEMA: --schema was requested but the response is not valid JSON." "$E_SCHEMA"
  fi
  # Back to the caller's schema: drop the nulls the strict form forced onto
  # originally-optional properties. Rewritten (compact) only when that changed it.
  DENULLED=$(printf '%s' "$RESPONSE" | jq -c --slurpfile s "$SCHEMA_ORIG" "$DENULL_JQ" 2>/dev/null) || \
    gate_fail "SCHEMA: the response could not be mapped back to the caller's --schema." "$E_SCHEMA"
  [ "$DENULLED" != "$(printf '%s' "$RESPONSE" | jq -c .)" ] && RESPONSE="$DENULLED"
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
#   ext-run: <N> tokens (<S>s, codex/<model>) out=<M>
# N = input + output summed over turn.completed events, out = output_tokens
# (reasoning_output_tokens is already inside output_tokens — codex's own
# total_tokens is input + output). out= is the part a bake-off compares.
TOKENS=$(jq -R 'fromjson? | select(type == "object" and .type == "turn.completed") | ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' "$EVENTS" 2>/dev/null | jq -s 'add // 0')
OUT_TOKENS=$(jq -R 'fromjson? | select(type == "object" and .type == "turn.completed") | (.usage.output_tokens // 0)' "$EVENTS" 2>/dev/null | jq -s 'add // 0')
echo "ext-run: ${TOKENS:-0} tokens (${ELAPSED}s, codex/$MODEL) out=${OUT_TOKENS:-0}" >&2

if [ "$RAW" -eq 1 ]; then
  cat "$EVENTS"
else
  printf '%s\n' "$RESPONSE"
fi
[ "$APPLY_FAILED" -eq 1 ] && exit "$E_APPLY"
exit 0
