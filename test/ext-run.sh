#!/bin/bash
# Hermetic test suite for scripts/ext-run.sh (the single owner of every external
# CLI invocation: `agy` and `codex`) and for the tiers file tooling
# (config/tiers.json, scripts/tiers-sync.sh, scripts/triage-tiers.sh).
#
# NEVER calls the real Antigravity or Codex CLI and never touches the network:
# stub `agy` and `codex` executables are placed FIRST on PATH, replay canned
# output chosen by $AGY_STUB_MODE / $CODEX_STUB_MODE, and log their own cwd +
# argv so the flag tables can be asserted.
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
#   T*      tiers.json: agy ids come from the file, lookup order, missing or
#           unparseable file, absent entry = refusal, vendor/model mismatch
#   C*      codex: the flag table per mode (from a FIXTURE tiers file), every
#           result gate, the watchdog, per-vendor deny-list/markers, build
#           mode, --patch-out and --check
#   Y*      tiers-sync.sh (frontmatter <-> tiers.json) and triage-tiers.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_RUN="$REPO_DIR/scripts/ext-run.sh"

for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "INCOMPLETE: $tool is required to run this suite — cannot verify ext-run.sh." >&2
    exit 1
  fi
done
[ -x "$EXT_RUN" ] || { echo "INCOMPLETE: $EXT_RUN is missing or not executable." >&2; exit 1; }

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
# reach either the fixtures or ext-run.sh's own worktree/commit calls.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

OUT=""; ERR=""; RC=0
run_agy() { # run ext-run.sh, capture stdout/stderr/exit
  : > "$STUB_LOG"
  : > "$STUB_PROMPT"
  # shellcheck disable=SC2034  # OUT is read inside chk's eval'd condition strings
  OUT=$("$EXT_RUN" "$@" 2>"$ERRF")
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

echo "=== ext-run.sh — hermetic suite (stub agy + codex, no network) ==="

# --- S0: the stub, not the real CLI, is what will run -----------------------
RC=0; ERR=""
chk "S0 the stub agy is first on PATH (no real CLI can be reached)" \
  '[ "$(command -v agy)" = "$STUB_BIN/agy" ]'

# --- R1-R10: refusals and usage errors --------------------------------------
AGY_BOUNDARY_CLEARED="" run_agy read --prompt-file "$BRIEF"
chk "R1 missing AGY_BOUNDARY_CLEARED refuses before anything runs (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "REFUSED" && [ ! -s "$STUB_LOG" ]'

DENY=$(new_tmp)
mkdir -p "$DENY/clip-creator/inner"
new_repo "$DENY/clip-creator/inner"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$DENY/clip-creator/inner"
chk "R2 a path component equal to a deny-listed repo refuses (exit 3, names clip-creator)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator"'

mkdir -p "$DENY/clip-creators-lab"
new_repo "$DENY/clip-creators-lab"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$DENY/clip-creators-lab" --output "$DENY/out.patch"
chk "R3 clip-creators-lab is NOT refused — component equality, not substring" \
  '[ "$RC" -ne 3 ] && ! printf "%s" "$ERR" | grep -q "REFUSED"'

# Regression: engram left the deny-list on 2026-09-15 (its content is already on
# Google Drive), so a path under it must now run like any other repo.
mkdir -p "$DENY/engram/notes"
new_repo "$DENY/engram/notes"
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$DENY/engram/notes" --output "$DENY/out-engram.patch"
chk "R3b engram is NOT deny-listed any more (2026-09-15) — a path under it runs" \
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
chk "R13c the token-accounting line goes to stderr, tagged vendor/model" \
  'printf "%s" "$ERR" | grep -q "^ext-run: 42 tokens (1.5s, agy/gemini-3.8-flash-low)$"'

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
  '[ -n "$STUB_PWD" ] && case "$STUB_PWD" in */ext-run.*/ws) true ;; *) false ;; esac'
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
KEPT=$(printf '%s' "$ERR" | sed -n 's/^ext-run: staging dir kept at //p' | head -1)
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
  '[ -n "$STUB_PWD" ] && [ "$STUB_PWD" != "$REPO" ] && [ "$STUB_TOP" = "$STUB_PWD" ] && case "$STUB_PWD" in */ext-run.*/build) true ;; *) false ;; esac'
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

# =============================================================================
# T*: tiers.json — the ONLY source of external model ids (agy side)
# =============================================================================
FIX="$HARNESS/tiers-fixture.json"
cat > "$FIX" <<'FIXTURE'
{
  "asOf": "fixture",
  "parity": [{"date": "2000-01-01", "by": "test", "note": "old note"},
             {"date": "2000-02-02", "by": "test", "note": "fixture parity note"}],
  "levels": {
    "builder": {"claude": {"agent": "triage-builder", "model": "sonnet", "effort": "medium"},
                "codex": {"model": "gpt-fx-builder", "effort": "medium", "basis": "guess"},
                "agy": {"model": "gemini-fx-build-high"}},
    "deep": {"codex": {"model": "gpt-fx-deep", "effort": "high"}}
  },
  "modes": {
    "agy": {"review": {"model": "gemini-fx-review-high"}, "read": {"model": "gemini-fx-read-low"}},
    "codex": {"review": {"model": "gpt-fx-review", "effort": "high"},
              "read": {"model": "gpt-fx-read", "effort": "low"},
              "verify": {"model": "gpt-fx-verify", "effort": "medium"},
              "critique": {"model": "gpt-fx-crit"}}
  }
}
FIXTURE

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF"
chk "T1 agy model ids come from the tiers file (fixture read -> gemini-fx-read-low)" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gemini-fx-read-low" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$HARNESS/no-such-tiers.json" run_agy read --prompt-file "$BRIEF"
chk "T2 a missing tiers file is a usage error (exit 2) and nothing runs" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "tiers file not found" && [ ! -s "$STUB_LOG" ]'

printf '{"levels": {' > "$HARNESS/bad-tiers.json"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$HARNESS/bad-tiers.json" run_agy read --prompt-file "$BRIEF"
chk "T3 an unparseable tiers file is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not valid tiers JSON" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy verify --prompt-file "$BRIEF"
chk "T4 a mode absent for agy in the tiers file is REFUSED (exit 3), never a default model" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "modes.agy.verify" && [ ! -s "$STUB_LOG" ]'

TREPO="$BUILD/trepo"
new_repo "$TREPO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" AGY_STUB_MODE=buildnoop \
  run_agy build --level builder --prompt-file "$BRIEF" --workdir "$TREPO" --output "$BUILD/t5.patch"
chk "T5 agy build --level builder resolves levels.builder.agy from the tiers file" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gemini-fx-build-high" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --level deep --prompt-file "$BRIEF" --workdir "$TREPO"
chk "T6 agy at a level it is not listed for is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "levels.deep.agy" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 run_agy review --level deep --prompt-file "$BRIEF"
chk "T7 --level outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_agy review --vendor gemini --prompt-file "$BRIEF"
chk "T8 an unknown --vendor is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "unknown --vendor"'

AGY_BOUNDARY_CLEARED=1 run_agy review --prompt-file "$BRIEF" --model gpt-6-sol
chk "T9 agy refuses a model that is not agy's (gpt-* -> exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "does not belong"'

# Lookup order: an installed triage-tiers.json next to the script wins over the
# repo file, and $TRIAGE_TIERS wins over both.
INST=$(new_tmp)
cp "$EXT_RUN" "$INST/ext-run.sh"
jq '.modes.agy.read.model = "gemini-installed-low"' "$REPO_DIR/config/tiers.json" > "$INST/triage-tiers.json"
REAL_EXT_RUN="$EXT_RUN"
EXT_RUN="$INST/ext-run.sh"
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF"
chk "T10 an installed triage-tiers.json next to the script is used" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gemini-installed-low" "$STUB_LOG"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" AGY_STUB_MODE=ok run_agy read --prompt-file "$BRIEF"
chk "T10b TRIAGE_TIERS overrides the installed copy" \
  'grep -qx "MODEL=gemini-fx-read-low" "$STUB_LOG"'
EXT_RUN="$REAL_EXT_RUN"

# =============================================================================
# C*: codex — a stub `codex` replays JSONL events, writes the -o file, and logs
# its cwd, argv and stdin prompt.
# =============================================================================
cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/bash
# Stub Codex CLI. Replays canned JSONL events; never talks to anything.
set -u
log() { printf '%s\n' "$1" >> "$CODEX_STUB_LOG"; }
log "PWD=$PWD"
log "GITTOP=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
last=""
prev=""
for a in "$@"; do
  log "ARG=$a"
  case "$prev" in
    -C) log "CDIR=$a" ;;
    -s) log "SANDBOX=$a" ;;
    -m) log "MODEL=$a" ;;
    -c) log "CFG=$a" ;;
    -o) last="$a" ;;
    --output-schema) log "OSCHEMA=$(cat "$a" 2>/dev/null)" ;;
  esac
  prev="$a"
done
log "LASTARG=$prev"
cat > "$CODEX_STUB_PROMPT"
for probe in dirty.txt new.txt calc.txt .codex-inputs/note.txt; do
  [ -f "$PWD/$probe" ] && log "SEEN $probe=$(head -1 "$PWD/$probe")"
done
ok_events() {
  echo '{"type":"thread.started","thread_id":"t-1"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":12}}'
}
fail_events() {
  echo '{"type":"thread.started","thread_id":"t-1"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"turn.failed","error":{"message":"stream disconnected"}}'
  echo '{"type":"error","message":"stream disconnected"}'
}
case "${CODEX_STUB_MODE:-ok}" in
  ok)        ok_events; printf 'hello from codex\n' > "$last" ;;
  empty)     ok_events; : > "$last" ;;
  failed)    fail_events; exit 1 ;;
  failedrc0) fail_events; printf 'partial\n' > "$last" ;;
  exit7)     ok_events; printf 'x\n' > "$last"; exit 7 ;;
  schemaok)  ok_events; printf '{"verdict":"clean"}\n' > "$last" ;;
  schemabad) ok_events; printf 'not json at all\n' > "$last" ;;
  buildedit)
    printf 'CODEX WAS HERE\n' >> "$PWD/calc.txt"
    printf 'generated\n' > "$PWD/gen.txt"
    ok_events; printf 'edited calc.txt\nDONE exit=0\n' > "$last" ;;
  buildnoop) ok_events; printf 'nothing to do\nDONE exit=0\n' > "$last" ;;
  buildconflict)
    printf 'line1\nSTAGE\nline3\n' > "$PWD/conflict.txt"
    printf 'line1\nREAL-DRIFT\nline3\n' > "$CODEX_STUB_REPO/conflict.txt"
    ok_events; printf 'edited conflict.txt\nDONE exit=0\n' > "$last" ;;
  hang) exec sleep 30 ;;
  *) echo "stub: unknown CODEX_STUB_MODE '${CODEX_STUB_MODE:-}'" >&2; exit 9 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codex"
export CODEX_STUB_LOG="$STUB_LOG"
export CODEX_STUB_PROMPT="$STUB_PROMPT"

RC=0; ERR=""
chk "C0 the stub codex is first on PATH (no real CLI can be reached)" \
  '[ "$(command -v codex)" = "$STUB_BIN/codex" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok \
  run_agy read --vendor codex --prompt-file "$BRIEF" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
chk "C1 a good codex run exits 0 and stdout is exactly the -o final message" \
  '[ "$RC" -eq 0 ] && [ "$OUT" = "hello from codex" ]'
chk "C1b codex exec, read-only sandbox, model + effort from the FIXTURE tiers file" \
  '[ "$(grep "^ARG=" "$STUB_LOG" | head -1)" = "ARG=exec" ] && grep -qx "SANDBOX=read-only" "$STUB_LOG" && grep -qx "MODEL=gpt-fx-read" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=low" "$STUB_LOG"'
chk "C1c both /tmp exclusions are always passed (exclude_slash_tmp + exclude_tmpdir_env_var)" \
  'grep -qx "CFG=sandbox_workspace_write.exclude_slash_tmp=true" "$STUB_LOG" && grep -qx "CFG=sandbox_workspace_write.exclude_tmpdir_env_var=true" "$STUB_LOG"'
chk "C1d --ephemeral --skip-git-repo-check --ignore-user-config --json, prompt on stdin (-)" \
  'grep -qx -- "ARG=--ephemeral" "$STUB_LOG" && grep -qx -- "ARG=--skip-git-repo-check" "$STUB_LOG" && grep -qx -- "ARG=--ignore-user-config" "$STUB_LOG" && grep -qx -- "ARG=--json" "$STUB_LOG" && grep -qx -- "LASTARG=-" "$STUB_LOG"'
chk "C1e never a --dangerously-* flag, and no web search outside verify" \
  '! grep -q -- "^ARG=--dangerously" "$STUB_LOG" && ! grep -q "web_search" "$STUB_LOG"'
chk "C1f -C pins the throwaway stage, which is also the process cwd" \
  '[ "$(grep "^CDIR=" "$STUB_LOG" | sed "s/^CDIR=//")" = "$STUB_PWD" ] && case "$STUB_PWD" in */ext-run.*/ws) true ;; *) false ;; esac'
chk "C1g the stdin prompt carries the Workspace footer, the staged input and the non-interactive footer" \
  'grep -q -- "--- Workspace ---" "$STUB_PROMPT" && grep -q "^  /.*/inputs/note.txt$" "$STUB_PROMPT" && grep -q -- "--- Non-interactive worker ---" "$STUB_PROMPT" && grep -q "PROJECT_MEMORY.md" "$STUB_PROMPT"'
chk "C1h the token line is input+output from turn.completed, tagged codex/<model>" \
  'printf "%s" "$ERR" | grep -q "^ext-run: 130 tokens ([0-9]*s, codex/gpt-fx-read)$"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_agy verify --vendor codex --prompt-file "$BRIEF"
chk "C2 verify adds -c web_search=\"live\" on the fixture verify model/effort" \
  '[ "$RC" -eq 0 ] && grep -qx "CFG=web_search=\"live\"" "$STUB_LOG" && grep -qx "MODEL=gpt-fx-verify" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=medium" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_agy review --vendor codex --prompt-file "$BRIEF" --effort xhigh
chk "C3 review uses the fixture review model; --effort overrides the tiers effort" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-fx-review" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=xhigh" "$STUB_LOG" && ! grep -q "CFG=model_reasoning_effort=high" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy review --vendor codex --prompt-file "$BRIEF" --effort ludicrous
chk "C3b an invalid codex --effort is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy critique --vendor codex --prompt-file "$BRIEF"
chk "C3c a codex tiers entry with no effort (and no --effort) is a usage error, never a default" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "no effort" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=ok run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C4 without TRIAGE_TIERS the repo seed is used (codex read -> gpt-6-sol, low)" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-6-sol" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=low" "$STUB_LOG"'

# --- C5: the codex result gates ------------------------------------------------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=empty run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C5a an empty -o final message with rc 0 is UNAVAILABLE (exit 4), not a pass" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "no final message" && [ -z "$OUT" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=failed run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C5b turn.failed + error event, rc 1, no -o file is UNAVAILABLE (exit 4) with the reason" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "exited 1" && printf "%s" "$ERR" | grep -q "stream disconnected"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=failedrc0 run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C5c a failure event is UNAVAILABLE even with rc 0 and a non-empty -o file" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "turn.failed event"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=exit7 run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C5d a non-zero codex exit is UNAVAILABLE (exit 4) even with a final message" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "exited 7"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=schemaok run_agy read --vendor codex --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "C5e --schema: a JSON final message exits 0; the inline schema reaches codex as --output-schema FILE" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r .verdict)" = "clean" ] && grep -qx "OSCHEMA={\"type\":\"object\"}" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=schemabad run_agy read --vendor codex --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "C5f --schema with a non-JSON final message is exit 5 (SCHEMA)" '[ "$RC" -eq 5 ]'

T_START=$SECONDS
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=hang run_agy read --vendor codex --prompt-file "$BRIEF" --timeout 1s
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
T_TOOK=$((SECONDS - T_START))
chk "C5g the wall-clock watchdog kills a hung codex: exit 4, says timed out, well before the hang ends" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "timed out after 1s" && [ "$T_TOOK" -lt 15 ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy read --vendor codex --prompt-file "$BRIEF" --timeout 1m30s
chk "C5h a codex --timeout the watchdog cannot parse is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_agy read --vendor codex --prompt-file "$BRIEF" --raw
chk "C5i --raw relays the codex JSONL event stream" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "\"type\":\"turn.completed\""'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_BIN="$HARNESS/no-such-codex" run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C5j a missing codex binary is UNAVAILABLE (exit 4)" '[ "$RC" -eq 4 ] && [ ! -s "$STUB_LOG" ]'

# --- C6: the deny-list is per vendor, and clip-creator is denied for all -------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$DENY/clip-creator/inner"
chk "C6a codex under clip-creator is REFUSED (exit 3) and codex never runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy read --vendor codex --prompt-file "$BRIEF" --input "$DENY/clip-creator/note.txt"
chk "C6b codex --input from clip-creator is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 AGY_DENY_REPOS="something-else" run_agy build --prompt-file "$BRIEF" --workdir "$DENY/clip-creator/inner"
chk "C6c clip-creator stays hard-denied for agy even when AGY_DENY_REPOS is overridden" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator"'

mkdir -p "$DENY/codex-only"
new_repo "$DENY/codex-only/proj"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_DENY_REPOS="codex-only" \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$DENY/codex-only/proj"
chk "C6d a CODEX_DENY_REPOS name refuses codex (exit 3, component match)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "codex-only"'

CMARK=$(new_tmp)
new_repo "$CMARK/repo"
: > "$CMARK/repo/.codex-deny"
git -C "$CMARK/repo" add .codex-deny && git -C "$CMARK/repo" commit -qm marker
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$CMARK/repo"
chk "C6e a .codex-deny marker refuses codex (exit 3, names the marker)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildnoop run_agy build --prompt-file "$BRIEF" --workdir "$CMARK/repo" --output "$CMARK/agy.patch"
chk "C6f a .codex-deny marker does NOT block agy" '[ "$RC" -eq 0 ]'

AMARK=$(new_tmp)
new_repo "$AMARK/repo"
: > "$AMARK/repo/.agy-deny"
git -C "$AMARK/repo" add .agy-deny && git -C "$AMARK/repo" commit -qm marker
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildnoop \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$AMARK/repo" --output "$AMARK/codex.patch"
chk "C6g a .agy-deny marker does NOT block codex (it means agy only)" '[ "$RC" -eq 0 ]'
AGY_BOUNDARY_CLEARED=1 run_agy build --prompt-file "$BRIEF" --workdir "$AMARK/repo"
chk "C6h ...while the same .agy-deny marker still blocks agy (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.agy-deny"'

AGY_BOUNDARY_CLEARED="" TRIAGE_TIERS="$FIX" run_agy read --vendor codex --prompt-file "$BRIEF"
chk "C6i codex also requires AGY_BOUNDARY_CLEARED=1 (exit 3, nothing runs)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "AGY_BOUNDARY_CLEARED" && [ ! -s "$STUB_LOG" ]'

# --- C7-C9: levels, fixture edits, vendor/model mismatch ------------------------
CREPO="$BUILD/crepo"
new_repo "$CREPO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --vendor codex --level quick --prompt-file "$BRIEF" --workdir "$CREPO"
chk "C7 a level missing from the tiers file is REFUSED (exit 3); codex never runs on a default model" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "levels.quick.codex" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --vendor codex --prompt-file "$BRIEF" --workdir "$CREPO"
chk "C7b codex build without --level is REFUSED (no modes.codex.build entry)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "modes.codex.build" && [ ! -s "$STUB_LOG" ]'

FIX2="$HARNESS/tiers-fixture2.json"
jq '.levels.deep.codex.model = "gpt-fx-deep-v2" | .levels.deep.codex.effort = "xhigh"' "$FIX" > "$FIX2"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX2" CODEX_STUB_MODE=buildnoop \
  run_agy build --vendor codex --level deep --prompt-file "$BRIEF" --workdir "$CREPO" --output "$BUILD/c8.patch"
chk "C8 a model/effort change in the tiers file is picked up with no code edit" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-fx-deep-v2" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=xhigh" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy review --vendor codex --prompt-file "$BRIEF" --model gemini-3.1-pro-high
chk "C9a codex refuses a Gemini model (vendor/model mismatch, exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "does not belong" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy review --vendor codex --prompt-file "$BRIEF" --model gpt-claude-bridge
chk "C9b anything naming claude is refused for codex too (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -qi "claude model"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_agy review --vendor codex --prompt-file "$BRIEF" --model codex-fx-mini
chk "C9c a codex-* --model override is accepted and passed through" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=codex-fx-mini" "$STUB_LOG"'

# --- C10-C12: codex build mode -------------------------------------------------
CB="$BUILD/cbuild"
new_repo "$CB"
printf 'line1\nline2\nCHANGED\n' > "$CB/calc.txt"
printf 'new untracked\n' > "$CB/new.txt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$CB" --output "$BUILD/cb.patch" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
chk "C10 codex build: workspace-write sandbox, level model/effort, -C = the disposable worktree" \
  'grep -qx "SANDBOX=workspace-write" "$STUB_LOG" && grep -qx "MODEL=gpt-fx-builder" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=medium" "$STUB_LOG" && [ "$(grep "^CDIR=" "$STUB_LOG" | sed "s/^CDIR=//")" = "$STUB_PWD" ] && case "$STUB_PWD" in */ext-run.*/build) true ;; *) false ;; esac'
chk "C10b the caller's uncommitted + untracked work and --input (.codex-inputs) are carried in" \
  'grep -qx "SEEN new.txt=new untracked" "$STUB_LOG" && grep -qx "SEEN .codex-inputs/note.txt=needle" "$STUB_LOG"'
chk "C10c the codex patch is applied back; carried work not re-applied; inputs never leak" \
  '[ "$RC" -eq 0 ] && tail -1 "$CB/calc.txt" | grep -qx "CODEX WAS HERE" && [ "$(grep -c "^CHANGED$" "$CB/calc.txt")" -eq 1 ] && [ -f "$CB/gen.txt" ] && [ ! -e "$CB/.codex-inputs" ]'
chk "C10d the worktree is removed after a codex build" \
  '[ "$(git -C "$CB" worktree list | wc -l | tr -d " ")" -eq 1 ] && [ ! -e "$STUB_PWD" ]'

CB2="$BUILD/cbuild2"
new_repo "$CB2"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
CB2_BEFORE=$(git -C "$CB2" status --porcelain)
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=empty \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$CB2" --output "$BUILD/cb2.patch"
chk "C11 a codex build with no final message is exit 4 and the real tree is untouched" \
  '[ "$RC" -eq 4 ] && [ "$(git -C "$CB2" status --porcelain)" = "$CB2_BEFORE" ] && printf "%s" "$ERR" | grep -q "NOT applied"'

CB3="$BUILD/cbuild3"
new_repo "$CB3"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildconflict CODEX_STUB_REPO="$CB3" \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$CB3" --output "$BUILD/cb3.patch"
chk "C12 a codex patch that does not apply is exit 6 (APPLY)" \
  '[ "$RC" -eq 6 ] && printf "%s" "$ERR" | grep -q "^APPLY:"'

# --- C13-C14: compare support — --patch-out and --check (both vendors) ----------
PO="$BUILD/porepo"
new_repo "$PO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po.patch"
chk "C13 --patch-out writes the patch and does NOT apply it (the caller's tree stays clean)" \
  '[ "$RC" -eq 0 ] && grep -q "^+CODEX WAS HERE$" "$BUILD/po.patch" && [ -z "$(git -C "$PO" status --porcelain)" ] && printf "%s" "$ERR" | grep -q "NOT applied (--patch-out)"'

printf 'dirty\n' > "$PO/wip.txt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po2.patch"
chk "C13b --patch-out refuses a dirty tree (exit 3) before anything runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clean tree" && [ ! -s "$STUB_LOG" ]'
rm -f "$PO/wip.txt"

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po3.patch" --output "$BUILD/po3b.patch"
chk "C13c --patch-out with --output is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
AGY_BOUNDARY_CLEARED=1 run_agy review --prompt-file "$BRIEF" --patch-out "$BUILD/po4.patch"
chk "C13d --patch-out outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildedit run_agy build --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po-agy.patch"
chk "C13e --patch-out works for agy too (patch written, tree untouched)" \
  '[ "$RC" -eq 0 ] && grep -q "^+AGY WAS HERE$" "$BUILD/po-agy.patch" && [ -z "$(git -C "$PO" status --porcelain)" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_agy build --vendor codex --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po5.patch" \
  --check 'grep -c "CODEX WAS HERE" calc.txt; echo artifact > check-artifact.txt; echo check-ran; exit 3'
chk "C14 --check runs in the worktree after the model: CHECK rc=<n> + output tail, exit code unchanged" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -qx "CHECK rc=3" && printf "%s" "$ERR" | grep -qx "check-ran" && printf "%s" "$ERR" | grep -qx "1"'
chk "C14b check artifacts never enter the captured patch" \
  '! grep -q "check-artifact" "$BUILD/po5.patch" && grep -q "^+CODEX WAS HERE$" "$BUILD/po5.patch"'

AGY_BOUNDARY_CLEARED=1 AGY_STUB_MODE=buildedit \
  run_agy build --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po6.patch" --check 'grep -q "AGY WAS HERE" calc.txt'
chk "C14c --check works for agy too (CHECK rc=0 when the model's edit is there)" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -qx "CHECK rc=0"'

AGY_BOUNDARY_CLEARED=1 run_agy review --prompt-file "$BRIEF" --check true
chk "C14d --check outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

# =============================================================================
# Y*: tiers-sync.sh (frontmatter <-> tiers.json) and triage-tiers.sh
# =============================================================================
TSYNC="$REPO_DIR/scripts/tiers-sync.sh"
TTABLE="$REPO_DIR/scripts/triage-tiers.sh"
YR=$(new_tmp)
mkdir -p "$YR/config" "$YR/agents"
cp "$REPO_DIR/config/tiers.json" "$YR/config/tiers.json"
cp "$REPO_DIR"/agents/triage-*.md "$YR/agents/"
cp "$YR/agents/triage-deep-reasoner.md" "$YR/deep.orig"

Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y1 the shipped agents' frontmatter matches the shipped tiers.json (--check clean)" '[ "$RC" -eq 0 ]'

jq '.levels.deep.claude.effort = "max"' "$REPO_DIR/config/tiers.json" > "$YR/config/tiers.json"
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y2 --check fails on drift, names the agent, and changes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$Y_OUT" | grep -q "triage-deep-reasoner.md" && cmp -s "$YR/agents/triage-deep-reasoner.md" "$YR/deep.orig"'

Y_OUT=$("$TSYNC" --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y3 sync rewrites ONLY the effort: line of the drifted agent" \
  '[ "$RC" -eq 0 ] && grep -qx "effort: max" "$YR/agents/triage-deep-reasoner.md" && [ "$(diff "$YR/deep.orig" "$YR/agents/triage-deep-reasoner.md" | grep -c "^[<>]")" -eq 2 ]'
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y4 --check is clean again after sync" '[ "$RC" -eq 0 ]'

printf -- '---\nname: triage-extra\nmodel: opus\neffort: low\n---\nbody\n' > "$YR/agents/triage-extra.md"
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y5 an agent not covered by tiers.json fails --check" \
  '[ "$RC" -eq 1 ] && printf "%s" "$Y_OUT" | grep -q "triage-extra.md is not covered"'

Y_OUT=$(TRIAGE_TIERS="$FIX" "$TTABLE" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y6 triage-tiers.sh prints the level x vendor table from the file, flags guesses, shows the latest parity note" \
  '[ "$RC" -eq 0 ] && printf "%s" "$Y_OUT" | grep -q "^LEVEL" && printf "%s" "$Y_OUT" | grep "^builder" | grep -q "gpt-fx-builder·medium (guess) GUESS" && printf "%s" "$Y_OUT" | grep -q "parity (latest): 2000-02-02 test: fixture parity note"'
Y_OUT=$(TRIAGE_TIERS="$HARNESS/no-such-tiers.json" "$TTABLE" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y7 triage-tiers.sh with a missing tiers file exits 2" '[ "$RC" -eq 2 ]'

echo ""
echo "checks passed: $PASS_COUNT   failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "EXT-RUN: all checks passed"
  exit 0
else
  echo "EXT-RUN: $FAIL_COUNT check(s) failed"
  exit 1
fi
