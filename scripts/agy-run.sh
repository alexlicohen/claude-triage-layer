#!/bin/bash
# scripts/agy-run.sh — SINGLE OWNER of every invocation of Google's Antigravity
# CLI (`agy`) made by this layer. Nothing else in the repo, and no agent, may
# call `agy` directly: the mode table, the deny-list, the known-good flag combo,
# the stdin workaround, the timeouts, the build staging worktree and the
# exit-code contract all live here.
#
# Usage:
#   scripts/agy-run.sh <mode> --prompt-file FILE [options]
#
# Modes (mode picks model + effort + agy flags + write policy):
#   review    cross-vendor review of a diff / prompt / rubric        read-only
#   read      long-corpus distillation (1M-ctx Flash), optional      read-only
#             --schema for typed JSON output
#   verify    search-grounded fact check (search_web/read_url)       read-only
#   critique  adversarial design critique (agy --mode plan)          read-only
#   fuzz      edge-case / mutation hunting against a guard           read-only
#   build     OVERFLOW WORKER: edits a disposable git worktree of    WRITES
#             the repo, then the resulting patch is applied back
#
# Options:
#   --prompt-file FILE   (required) the brief. Never passed inline on argv.
#   --input FILE         stage FILE into the workspace and name it by ABSOLUTE
#                        path in the prompt footer. Repeatable. This is how a
#                        diff/log/corpus gets in. Read-only modes: inputs/<base>
#                        in the stage; build: .agy-inputs/<base> in the worktree,
#                        removed again before the result patch is captured.
#   --schema FILE|JSON   read mode only: enforce typed output (implies JSON out).
#   --workdir DIR        build mode only: the git repo to change. agy NEVER sees
#                        it — it sees a disposable worktree of it (see below).
#   --output FILE        build mode only: where to write the result patch.
#                        Defaults to a mktemp file; the path is always printed
#                        on stderr. The patch is kept when it fails to apply.
#   --model ID           override the mode's model (must stay non-Claude).
#   --effort low|medium|high  rewrites the SUFFIX of the mode's model id. agy
#                        encodes reasoning effort in the model id, and passing
#                        --effort alongside such an id is a hard CLI error
#                        ("--model gemini-3.8-flash-medium conflicts with
#                        --effort=low"), so agy NEVER receives --effort from here.
#   --timeout DURATION   override the mode's --print-timeout (Go duration).
#   --raw                print the full agy JSON envelope instead of .response.
#
# Environment:
#   AGY_BIN               agy executable (default: agy on PATH)
#   AGY_DENY_REPOS        space-separated repo/dir names agy must never see.
#                         Default: "clip-creator" (standing decision 2026-07-10,
#                         narrowed from two repos to one on 2026-09-15 — see
#                         CHANGELOG.md, Wave 10).
#   AGY_BOUNDARY_CLEARED  must be 1. The caller attests the data boundary was
#                         checked (no clinical/BCH/PHI, no COI material, not a
#                         deny-listed repo). Absent => REFUSED, nothing runs.
#   AGY_STAGE_KEEP        1 = keep the staging dir (debugging). It NEVER keeps
#                         the build worktree — that is always removed.
#
# Exit codes (the contract every caller keys off):
#   0  OK          stdout is the model's answer (or the raw envelope with --raw)
#   2  USAGE       bad mode/flags/missing file — caller bug, nothing ran
#   3  REFUSED     deny-list hit or boundary not attested — nothing ran
#   4  UNAVAILABLE agy missing, auth failed, timed out, tools were denied, the
#                  response was empty, or the build stage could not be prepared.
#                  NEVER silently a pass.
#   5  SCHEMA      --schema was given and the response is not valid JSON
#   6  APPLY       build only: agy produced a patch but it did NOT apply to the
#                  real repo. The patch is left at --output for inspection; the
#                  answer still went to stdout.
#
# WHY exit code alone is not enough (verified live, agy 1.2.3, 2026-09-15):
#   a run whose tools were auto-denied in headless mode exits 0, prints nothing
#   on stdout, and reports {"status":"SUCCESS","response":"","denied_actions":
#   [...]}. Both the process exit status AND the envelope's own status field say
#   success. This script therefore gates on .response being non-empty and
#   .denied_actions being empty, and maps that case to 4/UNAVAILABLE.
#
# WHY build mode never lets agy touch the caller's tree:
#   agy runs with --dangerously-skip-permissions (it is the only way any tool
#   runs headless) and --mode plan is not a write guard, so "which files it may
#   change" cannot be expressed as a flag. Build mode therefore checks out a
#   disposable `git worktree --detach HEAD`, carries the caller's uncommitted
#   changes and untracked files into it, commits that carried state as the
#   stage base, and points --add-dir at the worktree. agy edits the copy; this
#   script then captures `git add -A && git diff --cached --binary` (the pure
#   agy delta, because the stage base already holds the caller's changes) and
#   applies it back to the real repo. Failure to apply is exit 6, never a silent
#   half-write, and the worktree is removed on every exit path. `git add -A`
#   honours .gitignore, so files the repo ignores (build output, caches) are
#   NOT carried back — a build task whose deliverable is an ignored path will
#   report no changes.
set -uo pipefail

AGY_BIN="${AGY_BIN:-agy}"
AGY_DENY_REPOS="${AGY_DENY_REPOS:-clip-creator}"

E_USAGE=2
E_REFUSED=3
E_UNAVAIL=4
E_SCHEMA=5
E_APPLY=6

STAGE=""
BUILD_REPO=""
BUILD_WT=""
cleanup() {
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

die() { echo "$1" >&2; exit "$2"; }

# ---------------------------------------------------------------------------
# Mode table — the ONE place a mode maps to model/effort/flags/timeout/policy.
# Models are ALWAYS an explicit Gemini id: agy's roster includes claude-sonnet-4-6
# and claude-opus-4-6-thinking, and a defaulted run would review Claude with
# Claude, defeating the whole point of the cross-vendor tier.
# ---------------------------------------------------------------------------
mode_model() {
  case "$1" in
    review|critique|fuzz|build) echo "gemini-3.1-pro-high" ;;
    verify)                     echo "gemini-3.8-flash-medium" ;;
    read)                       echo "gemini-3.8-flash-low" ;;
    *) echo "" ;;
  esac
}
# Effort is encoded in the model id, NOT passed as --effort (verified live: agy
# rejects --model <id with a suffix> together with --effort). apply_effort swaps
# the suffix on the mode's model; gemini-3.1-pro has no "medium" rung, so medium
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

# ---------------------------------------------------------------------------
# Deny-list. Enforced on the resolved, symlink-free path of the workdir, of every
# --input source, and of every --add-dir. Component equality (not substring), so
# ".../clip-creator/media" is refused and ".../clip-creators-lab" is not. A `.agy-deny`
# marker file anywhere from the path up to $HOME also refuses, so a repo can opt
# itself out without editing this script.
# ---------------------------------------------------------------------------
resolve_path() { # $1 = path -> absolute, symlinks resolved where possible
  local d
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P) || echo "$1"
  elif [ -f "$1" ]; then
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d=$(dirname "$1")
    echo "$d/$(basename "$1")"
  else echo "$1"
  fi
}

deny_check() { # $1 = path. exits E_REFUSED on a hit.
  local p d name
  p=$(resolve_path "$1")
  for name in $AGY_DENY_REPOS; do
    case "/$p/" in
      */"$name"/*) die "REFUSED: $p is under a deny-listed repo ('$name') — agy must never read it." "$E_REFUSED" ;;
    esac
  done
  d="$p"
  [ -f "$d" ] && d=$(dirname "$d")
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
    if [ -f "$d/.agy-deny" ]; then
      die "REFUSED: $d/.agy-deny marks this tree as off-limits to external agents." "$E_REFUSED"
    fi
    d=$(dirname "$d")
  done
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || die "USAGE: agy-run.sh <review|read|verify|critique|fuzz|build> --prompt-file FILE [options]" "$E_USAGE"
MODE="$1"; shift
[ -n "$(mode_model "$MODE")" ] || die "USAGE: unknown mode '$MODE' (review|read|verify|critique|fuzz|build)" "$E_USAGE"

PROMPT_FILE=""
WORKDIR=""
OUTPUT=""
SCHEMA=""
MODEL="$(mode_model "$MODE")"
EFFORT=""
TIMEOUT="$(mode_timeout "$MODE")"
RAW=0
INPUTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --input)       INPUTS+=("${2:-}"); shift 2 ;;
    --schema)      SCHEMA="${2:-}"; shift 2 ;;
    --workdir)     WORKDIR="${2:-}"; shift 2 ;;
    --output)      OUTPUT="${2:-}"; shift 2 ;;
    --model)       MODEL="${2:-}"; shift 2 ;;
    --effort)      EFFORT="${2:-}"; shift 2 ;;
    --timeout)     TIMEOUT="${2:-}"; shift 2 ;;
    --raw)         RAW=1; shift ;;
    *) die "USAGE: unknown argument '$1'" "$E_USAGE" ;;
  esac
done

[ -n "$PROMPT_FILE" ] || die "USAGE: --prompt-file is required" "$E_USAGE"
[ -f "$PROMPT_FILE" ] || die "USAGE: prompt file not found: $PROMPT_FILE" "$E_USAGE"
[ -s "$PROMPT_FILE" ] || die "USAGE: prompt file is empty: $PROMPT_FILE" "$E_USAGE"
# The prompt is passed as `-p "$(cat FILE)"`, so it is bounded by ARG_MAX (~1MB on
# macOS). Data — diffs, logs, corpora — belongs in --input (staged as a file agy
# opens itself), NOT inlined into the brief. Fail loudly rather than produce the
# truncated/E2BIG failure that looks like a model error.
PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
if [ "$PROMPT_BYTES" -gt 262144 ]; then
  die "USAGE: prompt file is ${PROMPT_BYTES} bytes (>256KB) — pass bulk data with --input instead of inlining it into the brief." "$E_USAGE"
fi
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|medium|high) MODEL="$(apply_effort "$MODEL" "$EFFORT")" ;;
    *) die "USAGE: --effort must be low|medium|high" "$E_USAGE" ;;
  esac
fi
case "$MODEL" in
  claude*|*claude*) die "USAGE: refusing to run the cross-vendor tier on a Claude model ('$MODEL')." "$E_USAGE" ;;
esac
if [ -n "$SCHEMA" ] && [ "$MODE" != "read" ]; then
  die "USAGE: --schema is only valid in read mode" "$E_USAGE"
fi
if [ -n "$WORKDIR" ] && ! mode_writes "$MODE"; then
  die "USAGE: --workdir is only valid in build mode (read-only modes run in an isolated staging dir)" "$E_USAGE"
fi
if [ -n "$OUTPUT" ] && ! mode_writes "$MODE"; then
  die "USAGE: --output is only valid in build mode (it is where the result patch is written)" "$E_USAGE"
fi
if mode_writes "$MODE"; then
  [ -n "$WORKDIR" ] || die "USAGE: build mode requires --workdir" "$E_USAGE"
  [ -d "$WORKDIR" ] || die "USAGE: --workdir is not a directory: $WORKDIR" "$E_USAGE"
  if [ -n "$OUTPUT" ]; then
    OUT_DIR=$(dirname "$OUTPUT")
    [ -d "$OUT_DIR" ] || die "USAGE: --output directory does not exist: $OUT_DIR" "$E_USAGE"
  fi
fi

# Boundary attestation — mirrors the cross-reviewer tier's rule 1. The caller,
# not this script, knows whether the material is clinical/COI/restricted.
[ "${AGY_BOUNDARY_CLEARED:-}" = "1" ] || \
  die "REFUSED: AGY_BOUNDARY_CLEARED is not set — the caller must attest the data boundary was checked before anything leaves the machine." "$E_REFUSED"

deny_check "$PROMPT_FILE"
if [ -n "$WORKDIR" ]; then deny_check "$WORKDIR"; fi

command -v "$AGY_BIN" >/dev/null 2>&1 || die "UNAVAILABLE: $AGY_BIN is not installed or not on PATH." "$E_UNAVAIL"
command -v jq >/dev/null 2>&1 || die "USAGE: jq is required" "$E_USAGE"
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
# Build mode is the same principle one step further: it gets a real checkout,
# but a disposable one (see the worktree section below).
# ---------------------------------------------------------------------------
# $STAGE/ws is the workspace agy is given (read-only modes) — it holds ONLY the
# staged inputs, so anything else appearing in it is something agy wrote.
# $STAGE/meta holds this script's own files (prompt, envelope, stderr) and is
# deliberately NOT inside ws, so the write-detection fingerprint stays honest.
# $STAGE/build is the build worktree (build mode only).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/agy-run.XXXXXX") || die "USAGE: could not create a staging dir" "$E_USAGE"
mkdir -p "$STAGE/ws/inputs" "$STAGE/meta"
STAGE_ABS=$(resolve_path "$STAGE")
[ "${AGY_STAGE_KEEP:-0}" = "1" ] && echo "agy-run: staging dir kept at $STAGE_ABS" >&2

# ---------------------------------------------------------------------------
# Build staging worktree. agy is pointed at $BUILD_WT and never at $BUILD_REPO.
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
  # `git diff --cached` against it — i.e. the PURE agy delta, which is what
  # applies cleanly back onto a repo that already has those carried changes.
  git -C "$BUILD_WT" add -A >/dev/null 2>&1
  git -C "$BUILD_WT" -c user.email=agy-run@localhost -c user.name=agy-run -c commit.gpgsign=false \
      commit -q --no-verify --allow-empty -m "agy-run stage base" >>"$STAGE/meta/carry.err" 2>&1 || \
    die "UNAVAILABLE: could not commit the stage base in the build worktree — $(head -c 400 "$STAGE/meta/carry.err")" "$E_UNAVAIL"

  if [ -z "$OUTPUT" ]; then
    OUTPUT=$(mktemp "${TMPDIR:-/tmp}/agy-build.XXXXXX") || die "USAGE: could not create a patch file" "$E_USAGE"
  fi
fi

# --input staging. Read-only modes: $STAGE/ws/inputs. Build: .agy-inputs inside
# the worktree (agy only sees the worktree), removed again before the result
# patch is captured so staged inputs never land in the caller's repo.
INPUT_DIR="$STAGE/ws/inputs"
if mode_writes "$MODE"; then
  INPUT_DIR="$BUILD_WT/.agy-inputs"
  if [ -e "$INPUT_DIR" ]; then
    die "USAGE: $WORKDIR already contains .agy-inputs — build mode reserves that path for staged --input files." "$E_USAGE"
  fi
  if [ ${#INPUTS[@]} -gt 0 ]; then mkdir -p "$INPUT_DIR"; fi
fi

STAGED_LIST=""
for src in ${INPUTS+"${INPUTS[@]}"}; do
  [ -f "$src" ] || die "USAGE: --input file not found: $src" "$E_USAGE"
  deny_check "$src"
  cp "$src" "$INPUT_DIR/$(basename "$src")"
  STAGED_LIST="$STAGED_LIST  $INPUT_DIR/$(basename "$src")
"
done

RUNDIR="$STAGE/ws"
mode_writes "$MODE" && RUNDIR="$BUILD_WT"
RUNDIR_ABS=$(resolve_path "$RUNDIR")

# The prompt agy actually sees: the brief, plus a footer naming the workspace and
# every staged file by ABSOLUTE path. Relative paths are not enough: agy has been
# observed resolving its workspace to $HOME rather than the process working
# directory (verified live 2026-09-15 — a run launched from the fixture directory
# reported "does not exist in the current working directory (/Users/alex)"), so the
# brief says where the files are rather than assuming "here".
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

# Read-only modes: fingerprint the stage so we can SAY whether the run tried to
# write. It is contained either way (the stage is thrown away), but a silent
# containment is a bad habit — report it.
STAGE_BEFORE=""
if ! mode_writes "$MODE"; then
  STAGE_BEFORE=$(find "$STAGE/ws" -type f | sort | sed "s#^$STAGE/ws/##")
fi

# ---------------------------------------------------------------------------
# Flags. Invariants, all verified live against agy 1.2.3:
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
#                                   check — it exists because cwd alone has been
#                                   observed not to define the workspace. In build
#                                   mode this is the disposable worktree, NEVER the
#                                   caller's repo.
#   </dev/null                      non-TTY stdout-drop workaround.
# ---------------------------------------------------------------------------
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

ENVELOPE="$STAGE/meta/envelope.json"
ERRLOG="$STAGE/meta/agy.err"
# cd to the RESOLVED path, so agy's own $PWD and the --add-dir it is given are
# the same string (on macOS $TMPDIR is a symlink, and a mismatch there is
# exactly the kind of "workspace is somewhere else" confusion F9 describes).
( cd "$RUNDIR_ABS" && "$AGY_BIN" "$@" ) > "$ENVELOPE" 2> "$ERRLOG" </dev/null
RC=$?

# Capture the result patch BEFORE the gates, so a failed run still leaves
# something inspectable. It is applied only if every gate passes.
if mode_writes "$MODE"; then
  rm -rf "$BUILD_WT/.agy-inputs"
  git -C "$BUILD_WT" add -A >/dev/null 2>&1
  git -C "$BUILD_WT" diff --cached --binary > "$OUTPUT" 2>"$STAGE/meta/capture.err" || \
    die "UNAVAILABLE: could not capture the build patch — $(head -c 400 "$STAGE/meta/capture.err")" "$E_UNAVAIL"
fi

# ---------------------------------------------------------------------------
# Result gating. Three independent things must all hold before this is a pass.
# ---------------------------------------------------------------------------
gate_fail() { # $1 = message, $2 = exit code
  if mode_writes "$MODE"; then
    echo "note: the build patch was NOT applied; it is left at $OUTPUT" >&2
  fi
  die "$1" "$2"
}

if [ "$RC" -ne 0 ]; then
  gate_fail "UNAVAILABLE: $AGY_BIN exited $RC — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
fi
if ! jq -e . "$ENVELOPE" >/dev/null 2>&1; then
  gate_fail "UNAVAILABLE: $AGY_BIN produced no parseable JSON envelope — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
fi

STATUS=$(jq -r '.status // ""' "$ENVELOPE")
DENIED=$(jq -r '(.denied_actions // []) | map(.action) | join(",")' "$ENVELOPE")
RESPONSE=$(jq -r '.response // ""' "$ENVELOPE")

if [ -n "$DENIED" ]; then
  gate_fail "UNAVAILABLE: agy tool calls were denied ($DENIED) — the run produced nothing usable." "$E_UNAVAIL"
fi
if [ "$STATUS" != "SUCCESS" ]; then
  gate_fail "UNAVAILABLE: agy status=$STATUS — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
fi
if [ -z "$RESPONSE" ]; then
  gate_fail "UNAVAILABLE: agy returned an empty response (exit 0 and status SUCCESS are NOT sufficient) — $(head -c 400 "$ERRLOG")" "$E_UNAVAIL"
fi
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
# Apply the build patch back to the real repo.
#   plain `git apply` first: it is atomic and index-free, so the common case
#   (the caller's tree is exactly what we carried in) applies cleanly even with
#   unstaged changes and untracked files present — `--index` cannot do that, it
#   refuses any path whose worktree copy differs from the index.
#   `--3way` second: recovers when the caller's tree drifted while agy ran. It
#   can leave conflict markers, so it is the fallback, not the first attempt.
# ---------------------------------------------------------------------------
APPLY_FAILED=0
if mode_writes "$MODE"; then
  if [ ! -s "$OUTPUT" ]; then
    echo "agy-run: build produced NO changes (empty patch at $OUTPUT)" >&2
  elif git -C "$BUILD_REPO" apply "$OUTPUT" >"$STAGE/meta/apply.err" 2>&1; then
    echo "agy-run: applied the build patch to $BUILD_REPO ($OUTPUT)" >&2
  elif git -C "$BUILD_REPO" apply --3way "$OUTPUT" >>"$STAGE/meta/apply.err" 2>&1; then
    echo "agy-run: applied the build patch to $BUILD_REPO by 3-way merge ($OUTPUT)" >&2
  else
    APPLY_FAILED=1
    echo "APPLY: the build patch did NOT apply to $BUILD_REPO. The patch is left at $OUTPUT; the 3-way attempt may have left conflict markers — inspect before continuing." >&2
    head -c 800 "$STAGE/meta/apply.err" >&2
    echo "" >&2
  fi
fi

# Accounting: agy spend is vendor-side and invisible to scripts/triage-usage.sh,
# so the envelope's token counts go to stderr where the caller can relay them.
jq -r --arg m "$MODEL" '"agy-run: \(.usage.total_tokens // 0) tokens (\(.duration_seconds // 0)s, \($m))"' "$ENVELOPE" >&2

if [ "$RAW" -eq 1 ]; then
  cat "$ENVELOPE"
else
  printf '%s\n' "$RESPONSE"
fi
[ "$APPLY_FAILED" -eq 1 ] && exit "$E_APPLY"
exit 0
