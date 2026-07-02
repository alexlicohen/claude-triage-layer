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

ALL_IDS="1 2 3 4 5 6 7 8 9 10"
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
    7) echo "workflows/triage-run.js" ;;
    8) echo "workflows/triage-run.js" ;;
    9) echo "workflows/triage-run.js" ;;
    10) echo "drift.sh" ;;
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
    7) echo "triage-run.js: revert incomplete:true -> incomplete:false on the objective null branch" ;;
    8) echo "triage-run.js: remove the runGate retry (gate tried once, null returned immediately)" ;;
    9) echo "triage-run.js: make matchedFiles() always return [] (attribution always fails)" ;;
    10) echo "drift.sh: remove UNEXPECTED_DRIFT=1 from the MISSING branch" ;;
    *) echo "" ;;
  esac
}

# Which suite exercises this mutation's file: "roundtrip" (test/roundtrip.sh) or
# "scenarios" (test/workflow-scenarios.mjs).
mut_suite() {
  case "$1" in
    1|2|3|4|5|6|10) echo "roundtrip" ;;
    7|8|9) echo "scenarios" ;;
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
      # triage-run.js: incomplete:true -> incomplete:false on the objective null branch.
      printf "    if (v.result == null) return { text: '', failed: false, isEscalate: false, incomplete: false }\n" > "$rep"
      mut_replace_block "$target" \
        "    if (v.result == null) return { text: '', failed: false, isEscalate: false, incomplete: true }" 1 "$rep"
      ;;
    8)
      # triage-run.js: disable the gate retry surgically — the retry condition
      # becomes `if (false)`, so the gate is tried once and null is returned
      # immediately. 1-line replace: robust to surrounding runGate changes
      # (a 9-line block replace went stale when budget logic reshaped runGate).
      printf '    if (false) { // MUTATED: retry disabled\n' > "$rep"
      mut_replace_block "$target" '    if (out == null && !ceilinged) {' 1 "$rep"
      ;;
    9)
      # triage-run.js: matchedFiles() -> always [] (3 lines -> 3 lines).
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
    7) grep -qF "incomplete: false }" "$target" && ! grep -qF "if (v.result == null) return { text: '', failed: false, isEscalate: false, incomplete: true }" "$target" ;;
    8) grep -qF 'MUTATED: retry disabled' "$target" ;;
    9) grep -qF 'function matchedFiles(r, text) {' "$target" && ! grep -qF 'fileMentioned(f, text)' "$target" ;;
    10) [ "$(grep -cF 'UNEXPECTED_DRIFT=1' "$target")" -eq 1 ] ;;
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

run_suite() { # $1 = repo copy dir, $2 = suite name ("roundtrip"|"scenarios") -> exit code
  local copy suite
  copy="$1"
  suite="$2"
  case "$suite" in
    roundtrip) ( cd "$copy" && bash test/roundtrip.sh ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
    scenarios) ( cd "$copy" && node test/workflow-scenarios.mjs ) >"$WORK_ROOT/last-suite.log" 2>&1 ;;
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
if run_suite "$BASELINE_DIR" roundtrip; then
  BASELINE_ROUNDTRIP_OK=0
else
  BASELINE_ROUNDTRIP_OK=1
  echo "  ⚠ baseline test/roundtrip.sh is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
fi
if run_suite "$BASELINE_DIR" scenarios; then
  BASELINE_SCENARIOS_OK=0
else
  BASELINE_SCENARIOS_OK=1
  echo "  ⚠ baseline test/workflow-scenarios.mjs is already RED on unmutated code — mutations using it will be reported ERROR (baseline-red), not KILLED/SURVIVOR."
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
    *) baseline_ok=1 ;;
  esac

  if [ "$baseline_ok" -ne 0 ]; then
    printf '[%-2s] %-26s %-9s %-7s %s\n' "$id" "$file" "$suite" "ERROR" "$desc"
    echo "      -> baseline test/$( [ "$suite" = roundtrip ] && echo roundtrip.sh || echo workflow-scenarios.mjs ) is already RED without this mutation; cannot assess."
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
