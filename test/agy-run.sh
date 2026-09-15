#!/bin/bash
# Hermetic test suite for scripts/agy-run.sh (the single owner of every `agy`
# invocation).
#
# NEVER calls the real Antigravity CLI and never touches the network: a stub
# `agy` is placed FIRST on PATH, replays a canned JSON envelope chosen by
# $AGY_STUB_MODE, and logs its own cwd + argv so the flag table can be asserted.
# Every case runs against its own `mktemp -d` fixture; build cases get their own
# throwaway git repo. Fail-loud: accumulates failures, prints PASS/FAIL per
# check, exits non-zero if anything failed or a prerequisite is missing.
#
# Coverage map (R* = the rows in the design's §7.2 table, B* = build mode):
#   R1-R10  boundary attestation, deny-list (component / marker / input),
#           usage errors, the 256KB prompt guard
#   R11-R17 the exit-code contract: denied_actions (F1), empty response (F7),
#           non-zero exit, unparseable envelope, non-SUCCESS status, --schema
#   R18-R21 the flag table: model per mode, no --effort (F8), --add-dir (F9),
#           --mode plan/accept-edits, cwd isolation, the prompt footer,
#           effort-suffix rewriting, staging-write detection and cleanup
#   B1-B9   build mode: the disposable worktree, carrying uncommitted and
#           untracked work in, the patch applied back, the apply-conflict exit
#           code, worktree/stage removal, and an untouched real tree whenever
#           the run did not pass its gates
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGY_RUN="$REPO_DIR/scripts/agy-run.sh"

for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "INCOMPLETE: $tool is required to run this suite — cannot verify agy-run.sh." >&2
    exit 1
  fi
done
[ -x "$AGY_RUN" ] || { echo "INCOMPLETE: $AGY_RUN is missing or not executable." >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
ALL_TMP=""

cleanup() {
  # shellcheck disable=SC2086
  [ -n "$ALL_TMP" ] && rm -rf $ALL_TMP
}
trap cleanup EXIT

new_tmp() {
  d=$(mktemp -d)
  ALL_TMP="$ALL_TMP $d"
  printf '%s' "$d"
}

# chk NAME CONDITION — CONDITION is a shell test string passed to `eval`.
chk() {
  name="$1"
  cond="$2"
  if eval "$cond"; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    echo "      rc=$RC"
    [ -n "$ERR" ] && echo "      stderr: $(printf '%s' "$ERR" | head -3)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- the stub `agy` ---------------------------------------------------------
HARNESS=$(new_tmp)
STUB_BIN="$HARNESS/bin"
mkdir -p "$STUB_BIN"
STUB_LOG="$HARNESS/stub.log"
STUB_PROMPT="$HARNESS/stub-prompt.txt"
ERRF="$HARNESS/stderr.txt"

cat > "$STUB_BIN/agy" <<'STUB'
#!/bin/bash
# Stub Antigravity CLI. Replays a canned envelope; never talks to anything.
set -u
log() { printf '%s\n' "$1" >> "$AGY_STUB_LOG"; }
log "PWD=$PWD"
log "GITTOP=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
prev=""
for a in "$@"; do
  log "ARG=$a"
  case "$prev" in
    -p)               printf '%s' "$a" > "$AGY_STUB_PROMPT" ;;
    --model)          log "MODEL=$a" ;;
    --mode)           log "MODE=$a" ;;
    --add-dir)        log "ADDDIR=$a" ;;
    --print-timeout)  log "TIMEOUT=$a" ;;
    --json-schema)    log "SCHEMA=$a" ;;
  esac
  prev="$a"
done
for probe in dirty.txt new.txt calc.txt sub/deep.txt .agy-inputs/note.txt; do
  [ -f "$PWD/$probe" ] && log "SEEN $probe=$(head -1 "$PWD/$probe")"
done

case "${AGY_STUB_MODE:-ok}" in
  ok)
    echo '{"status":"SUCCESS","response":"hello from the stub","duration_seconds":1.5,"usage":{"total_tokens":42}}' ;;
  denied)
    echo '{"status":"SUCCESS","response":"","denied_actions":[{"action":"command","display_name":"RunCommand"}]}' ;;
  empty)
    echo '{"status":"SUCCESS","response":""}' ;;
  errstatus)
    echo '{"status":"ERROR","response":"partial text"}' ;;
  nonjson)
    echo 'this is not a JSON envelope' ;;
  exit7)
    echo '{"status":"SUCCESS","response":"x"}'; exit 7 ;;
  schemabad)
    echo '{"status":"SUCCESS","response":"not json at all"}' ;;
  schemaok)
    echo '{"status":"SUCCESS","response":"{\"verdict\":\"clean\"}"}' ;;
  write)
    printf 'sneaky\n' > "$PWD/sneaky.txt"
    echo '{"status":"SUCCESS","response":"wrote a file"}' ;;
  buildedit)
    printf 'AGY WAS HERE\n' >> "$PWD/calc.txt"
    printf 'generated\n' > "$PWD/gen.txt"
    echo '{"status":"SUCCESS","response":"edited calc.txt\nDONE exit=0"}' ;;
  buildnoop)
    echo '{"status":"SUCCESS","response":"nothing to do\nDONE exit=0"}' ;;
  buildconflict)
    # Edit the staged copy AND drift the caller's real tree on the same line,
    # so the resulting patch cannot apply.
    printf 'line1\nSTAGE\nline3\n' > "$PWD/conflict.txt"
    printf 'line1\nREAL-DRIFT\nline3\n' > "$AGY_STUB_REPO/conflict.txt"
    echo '{"status":"SUCCESS","response":"edited conflict.txt\nDONE exit=0"}' ;;
  *)
    echo "stub: unknown AGY_STUB_MODE '${AGY_STUB_MODE:-}'" >&2; exit 9 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/agy"

PATH="$STUB_BIN:$PATH"
export PATH
export AGY_STUB_LOG="$STUB_LOG"
export AGY_STUB_PROMPT="$STUB_PROMPT"
# Hermetic git: the caller's ~/.gitconfig (hooks, gpgsign, templates) must not
# reach either the fixtures or agy-run.sh's own worktree/commit calls.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

OUT=""; ERR=""; RC=0
run_agy() { # run agy-run.sh, capture stdout/stderr/exit
  : > "$STUB_LOG"
  : > "$STUB_PROMPT"
  # shellcheck disable=SC2034  # OUT is read inside chk's eval'd condition strings
  OUT=$("$AGY_RUN" "$@" 2>"$ERRF")
  RC=$?
  ERR=$(cat "$ERRF")
}

PROMPTS=$(new_tmp)
BRIEF="$PROMPTS/brief.txt"
printf 'Do the thing.\n' > "$BRIEF"
DATA="$PROMPTS/note.txt"
printf 'needle\n' > "$DATA"

new_repo() { # $1 = path; a git repo with one commit
  mkdir -p "$1"
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" config user.email agy-test@localhost
  git -C "$1" config user.name agy-test
  printf 'line1\nline2\nline3\n' > "$1/calc.txt"
  printf 'line1\nline2\nline3\n' > "$1/conflict.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

echo "=== agy-run.sh — hermetic suite (stub agy, no network) ==="

# --- S0: the stub, not the real CLI, is what will run -----------------------
RC=0; ERR=""
chk "S0 the stub agy is first on PATH (no real CLI can be reached)" \
  '[ "$(command -v agy)" = "$STUB_BIN/agy" ]'

# --- R1-R10: refusals and usage errors --------------------------------------
AGY_BOUNDARY_CLEARED="" run_agy read --prompt-file "$BRIEF"
chk "R1 missing AGY_BOUNDARY_CLEARED refuses before anything runs (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "REFUSED" && [ ! -s "$STUB_LOG" ]'

DENY=$(new_tmp)
mkdir -p "$DENY/engram/inner"
new_repo "$DENY/engram/inner"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$DENY/engram/inner"
chk "R2 a path component equal to a deny-listed repo refuses (exit 3, names engram)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "engram"'

mkdir -p "$DENY/engrams-lab"
new_repo "$DENY/engrams-lab"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$DENY/engrams-lab" --output "$DENY/out.patch"
chk "R3 engrams-lab is NOT refused — component equality, not substring" \
  '[ "$RC" -ne 3 ] && ! printf "%s" "$ERR" | grep -q "REFUSED"'

MARKED=$(new_tmp)
new_repo "$MARKED/repo"
: > "$MARKED/repo/.agy-deny"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$MARKED/repo"
chk "R4 a .agy-deny marker in the tree refuses (exit 3, names the marker)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.agy-deny"'

mkdir -p "$DENY/clip-creator"
cp "$DATA" "$DENY/clip-creator/note.txt"
AGY_BOUNDARY_CLEARED=1 run_agy read --prompt-file "$BRIEF" --input "$DENY/clip-creator/note.txt"
chk "R4b --input from a deny-listed repo refuses (exit 3, names clip-creator)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator"'

AGY_BOUNDARY_CLEARED=1 run_agy nonsense --prompt-file "$BRIEF"
chk "R5 unknown mode is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "unknown mode"'

AGY_BOUNDARY_CLEARED=1 run_agy review --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "R6 --schema outside read mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_agy read --prompt-file "$BRIEF" --workdir "$PROMPTS"
chk "R7 --workdir outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF"
chk "R8 build without --workdir is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_agy review --prompt-file "$BRIEF" --model claude-opus-4-6-thinking
chk "R9 a Claude model is refused — the tier is cross-vendor by definition (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -qi "claude"'

BIG="$PROMPTS/big.txt"
: > "$BIG"
i=0
while [ "$i" -lt 3200 ]; do
  printf '%s\n' "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789" >> "$BIG"
  i=$((i + 1))
done
AGY_BOUNDARY_CLEARED=1 run_agy read --prompt-file "$BIG"
chk "R10 a >256KB prompt file is refused and names --input (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--input"'

AGY_BOUNDARY_CLEARED=1 run_agy read --prompt-file "$BRIEF" --output "$PROMPTS/x.patch"
chk "R10b --output outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_agy read --prompt-file "$PROMPTS/no-such-file.txt"
chk "R10c a missing prompt file is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not found"'

# --- R11-R17: the result-gating contract ------------------------------------
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=denied run_agy read --prompt-file "$BRIEF"
chk "R11 denied_actions + exit 0 + status SUCCESS is UNAVAILABLE, not a pass (F1 guard)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "denied"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=empty run_agy read --prompt-file "$BRIEF"
chk "R12 an empty response with status SUCCESS is UNAVAILABLE (F7 timeout guard)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "empty response"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF"
chk "R13 a good envelope exits 0 and stdout is exactly the response" \
  '[ "$RC" -eq 0 ] && [ "$OUT" = "hello from the stub" ]'
chk "R13b a clean read-only run prints NO staging-write note" \
  '! printf "%s" "$ERR" | grep -q "wrote into its staging dir"'
chk "R13c the token-accounting line goes to stderr" \
  'printf "%s" "$ERR" | grep -q "agy-run: 42 tokens"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=exit7 run_agy read --prompt-file "$BRIEF"
chk "R14 a non-zero agy exit is UNAVAILABLE (exit 4)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "exited 7"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=nonjson run_agy read --prompt-file "$BRIEF"
chk "R15 an unparseable envelope is UNAVAILABLE (exit 4)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "no parseable JSON"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=errstatus run_agy read --prompt-file "$BRIEF"
chk "R15b status != SUCCESS is UNAVAILABLE even with a non-empty response (exit 4)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "status=ERROR"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=schemabad run_agy read --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "R16 --schema with a non-JSON response is exit 5 (SCHEMA), not a pass" \
  '[ "$RC" -eq 5 ]'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=schemaok run_agy read --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "R17 --schema with a JSON response exits 0 and relays the JSON" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r .verdict)" = "clean" ]'
chk "R17b --schema is plumbed through to agy as --json-schema" \
  'grep -q "^SCHEMA={\"type\":\"object\"}$" "$STUB_LOG"'

# --- R18-R21: the flag table, workspace pinning and the prompt footer -------
CALLER=$(new_tmp)
mkdir -p "$CALLER/repo"
printf 'caller file\n' > "$CALLER/repo/private.txt"
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_ADD=$(grep '^ADDDIR=' "$STUB_LOG" | head -1 | sed 's/^ADDDIR=//')
chk "R18a a read-only mode runs in a throwaway stage, never the caller's cwd" \
  '[ -n "$STUB_PWD" ] && case "$STUB_PWD" in */agy-run.*/ws) true ;; *) false ;; esac'
chk "R18b the always-on flags are present (--sandbox, skip-permissions, json out)" \
  'grep -qx -- "ARG=--sandbox" "$STUB_LOG" && grep -qx -- "ARG=--dangerously-skip-permissions" "$STUB_LOG" && grep -qx -- "ARG=--output-format" "$STUB_LOG" && grep -qx -- "ARG=json" "$STUB_LOG"'
chk "R18c agy NEVER receives --effort (F8: it conflicts with a suffixed --model)" \
  '! grep -qx -- "ARG=--effort" "$STUB_LOG"'
chk "R18d read mode pins an explicit non-Claude model (gemini-3.8-flash-low)" \
  'grep -qx "MODEL=gemini-3.8-flash-low" "$STUB_LOG"'
chk "R18e read mode passes the mode default --print-timeout 5m" \
  'grep -qx "TIMEOUT=5m" "$STUB_LOG"'
chk "R20a --add-dir is present and equals the run directory (F9 regression guard)" \
  '[ -n "$STUB_ADD" ] && [ "$STUB_ADD" = "$STUB_PWD" ]'
chk "R21 the prompt agy receives carries the Workspace footer and the input by absolute path" \
  'grep -q -- "--- Workspace ---" "$STUB_PROMPT" && grep -q "^  /.*/inputs/note.txt$" "$STUB_PROMPT"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy critique --prompt-file "$BRIEF"
chk "R18f critique adds --mode plan on gemini-3.1-pro-high" \
  'grep -qx "MODE=plan" "$STUB_LOG" && grep -qx "MODEL=gemini-3.1-pro-high" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy verify --prompt-file "$BRIEF"
chk "R18g verify runs gemini-3.8-flash-medium with no --mode" \
  'grep -qx "MODEL=gemini-3.8-flash-medium" "$STUB_LOG" && ! grep -q "^MODE=" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy critique --prompt-file "$BRIEF" --effort medium
chk "R19a --effort medium on a pro model resolves to -high (no such rung as medium)" \
  'grep -qx "MODEL=gemini-3.1-pro-high" "$STUB_LOG" && ! grep -qx -- "ARG=--effort" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF" --effort high
chk "R19b --effort rewrites the model-id suffix (read + high -> gemini-3.8-flash-high)" \
  'grep -qx "MODEL=gemini-3.8-flash-high" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=write run_agy review --prompt-file "$BRIEF"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
chk "R19c a read-only run that writes is contained AND reported, never silent" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -q "wrote into its staging dir"'
chk "R19d the staging dir is gone after exit (nothing agy wrote survives)" \
  '[ ! -e "$STUB_PWD" ]'

AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF" --input "$DATA"
KEPT=$(printf '%s' "$ERR" | sed -n 's/^agy-run: staging dir kept at //p' | head -1)
chk "R21b AGY_STAGE_KEEP=1 keeps the stage and its meta/prompt.txt for inspection" \
  '[ -n "$KEPT" ] && [ -f "$KEPT/meta/prompt.txt" ] && grep -q -- "--- Workspace ---" "$KEPT/meta/prompt.txt"'
[ -n "$KEPT" ] && rm -rf "$KEPT"

# --- B1-B9: build mode — the disposable worktree ----------------------------
BUILD=$(new_tmp)
REPO="$BUILD/repo"
new_repo "$REPO"
printf 'DIRTY\n' > "$REPO/dirty.txt"                 # uncommitted, untracked
printf 'line1\nline2\nCHANGED\n' > "$REPO/calc.txt"  # uncommitted, tracked
mkdir -p "$REPO/sub"
printf 'deep untracked\n' > "$REPO/sub/deep.txt"
git -C "$REPO" add dirty.txt >/dev/null 2>&1          # staged-but-uncommitted
printf 'new untracked\n' > "$REPO/new.txt"
PATCH="$BUILD/result.patch"

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildedit AGY_STUB_REPO="$REPO" \
  run_agy build --prompt-file "$BRIEF" --workdir "$REPO" --output "$PATCH" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_TOP=$(grep '^GITTOP=' "$STUB_LOG" | head -1 | sed 's/^GITTOP=//')
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_ADD=$(grep '^ADDDIR=' "$STUB_LOG" | head -1 | sed 's/^ADDDIR=//')

chk "B1 build runs in a disposable worktree, NOT in the caller's repo" \
  '[ -n "$STUB_PWD" ] && [ "$STUB_PWD" != "$REPO" ] && [ "$STUB_TOP" = "$STUB_PWD" ] && case "$STUB_PWD" in */agy-run.*/build) true ;; *) false ;; esac'
chk "B1b --add-dir points at the worktree, never at the real repo (F9 + isolation)" \
  '[ "$STUB_ADD" = "$STUB_PWD" ]'
chk "B1c build passes --mode accept-edits and the 20m mode timeout" \
  'grep -qx "MODE=accept-edits" "$STUB_LOG" && grep -qx "TIMEOUT=20m" "$STUB_LOG"'
chk "B2 the caller's uncommitted tracked change is carried into the stage" \
  'grep -qx "SEEN calc.txt=line1" "$STUB_LOG" && [ "$(grep -c "^SEEN calc.txt=" "$STUB_LOG")" -eq 1 ]'
chk "B2b the caller's untracked files are carried in (top level and nested)" \
  'grep -qx "SEEN new.txt=new untracked" "$STUB_LOG" && grep -qx "SEEN sub/deep.txt=deep untracked" "$STUB_LOG"'
chk "B2c a staged-but-uncommitted file is carried in too" \
  'grep -qx "SEEN dirty.txt=DIRTY" "$STUB_LOG"'
chk "B2d --input is staged inside the worktree as .agy-inputs/<name>" \
  'grep -qx "SEEN .agy-inputs/note.txt=needle" "$STUB_LOG"'
chk "B3 the result patch is written to --output and is non-empty" \
  '[ "$RC" -eq 0 ] && [ -s "$PATCH" ]'
chk "B3b the patch is applied back to the real repo (edit + new file land)" \
  'tail -1 "$REPO/calc.txt" | grep -qx "AGY WAS HERE" && [ -f "$REPO/gen.txt" ]'
chk "B3c the patch is the PURE agy delta — the carried work is not re-applied" \
  '[ "$(grep -c "^CHANGED$" "$REPO/calc.txt")" -eq 1 ] && ! grep -q "dirty.txt" "$PATCH"'
chk "B3d staged --input files never leak into the caller's repo" \
  '[ ! -e "$REPO/.agy-inputs" ]'
chk "B3e the caller's own uncommitted work survives the apply untouched" \
  '[ "$(cat "$REPO/dirty.txt")" = "DIRTY" ] && [ "$(cat "$REPO/new.txt")" = "new untracked" ]'
chk "B4 stdout is the model answer and the apply is reported on stderr" \
  'printf "%s" "$OUT" | grep -q "DONE exit=0" && printf "%s" "$ERR" | grep -q "applied the build patch"'
chk "B5 the worktree is removed on exit — the caller's repo has one worktree again" \
  '[ "$(git -C "$REPO" worktree list | wc -l | tr -d " ")" -eq 1 ] && [ ! -e "$STUB_PWD" ]'

# B6: agy makes no change at all.
REPO2="$BUILD/repo2"
new_repo "$REPO2"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
BEFORE2=$(git -C "$REPO2" status --porcelain)
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildnoop AGY_STUB_REPO="$REPO2" \
  run_agy build --prompt-file "$BRIEF" --workdir "$REPO2" --output "$BUILD/noop.patch"
chk "B6 a build that changes nothing exits 0, says so, and leaves the tree alone" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -q "NO changes" && [ "$(git -C "$REPO2" status --porcelain)" = "$BEFORE2" ]'

# B7: the envelope fails its gates — the real tree must not be touched.
REPO3="$BUILD/repo3"
new_repo "$REPO3"
printf 'untouched\n' > "$REPO3/dirty.txt"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
BEFORE3=$(git -C "$REPO3" status --porcelain)
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=empty AGY_STUB_REPO="$REPO3" \
  run_agy build --prompt-file "$BRIEF" --workdir "$REPO3" --output "$BUILD/empty.patch"
chk "B7 an empty envelope in build mode is exit 4 and the real tree is untouched" \
  '[ "$RC" -eq 4 ] && [ "$(git -C "$REPO3" status --porcelain)" = "$BEFORE3" ] && [ "$(cat "$REPO3/dirty.txt")" = "untouched" ]'
chk "B7b the unapplied patch is kept and named on stderr" \
  'printf "%s" "$ERR" | grep -q "NOT applied" && [ -e "$BUILD/empty.patch" ]'
chk "B7c the worktree is removed even when the run failed its gates" \
  '[ "$(git -C "$REPO3" worktree list | wc -l | tr -d " ")" -eq 1 ]'

# B8: the patch cannot apply (the caller's tree drifted under the run).
REPO4="$BUILD/repo4"
new_repo "$REPO4"
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildconflict AGY_STUB_REPO="$REPO4" \
  run_agy build --prompt-file "$BRIEF" --workdir "$REPO4" --output "$BUILD/conflict.patch"
chk "B8 a patch that does not apply is exit 6 (APPLY), distinct from 4" \
  '[ "$RC" -eq 6 ]'
chk "B8b the failed patch is left for inspection and stderr says APPLY" \
  '[ -s "$BUILD/conflict.patch" ] && printf "%s" "$ERR" | grep -q "^APPLY:"'
chk "B8c the model answer is still relayed on an apply failure" \
  'printf "%s" "$OUT" | grep -q "DONE exit=0"'
chk "B8d the worktree is still removed after an apply failure" \
  '[ "$(git -C "$REPO4" worktree list | wc -l | tr -d " ")" -eq 1 ]'

# B9: --workdir must be a git repo, and the default --output path works.
NOTGIT="$BUILD/plain"
mkdir -p "$NOTGIT"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$NOTGIT"
chk "B9 build against a non-git directory is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not a git work tree"'

REPO5="$BUILD/repo5"
new_repo "$REPO5"
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildedit AGY_STUB_REPO="$REPO5" \
  run_agy build --prompt-file "$BRIEF" --workdir "$REPO5"
DEFAULT_PATCH=$(printf '%s' "$ERR" | sed -n 's/.*applied the build patch to [^ ]* (\(.*\))$/\1/p' | head -1)
chk "B9b --output is optional: the patch goes to a temp file whose path is printed" \
  '[ "$RC" -eq 0 ] && [ -n "$DEFAULT_PATCH" ] && [ -s "$DEFAULT_PATCH" ]'
[ -n "$DEFAULT_PATCH" ] && rm -f "$DEFAULT_PATCH"

echo ""
echo "checks passed: $PASS_COUNT   failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "AGY-RUN: all checks passed"
  exit 0
else
  echo "AGY-RUN: $FAIL_COUNT check(s) failed"
  exit 1
fi
