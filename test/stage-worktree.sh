#!/bin/bash
# Hermetic test suite for scripts/stage-worktree.sh — the staging area behind
# workflows/triage-compare.js. Every case runs against scratch git repos under
# one mktemp -d root; nothing here touches this repo or the network.
#
# Covers: base resolved to a sha once; N worktrees detached at exactly that sha;
# refusal of a stage dir inside (or containing) the repo, or already populated;
# diff capturing modified + new + deleted + binary files and applying cleanly at
# the sha through scripts/patch-check.sh; an empty diff; diff refusing the main
# working tree and never leaving a stale patch; leakcheck CLEAN / LEAK (modified
# tracked file, new untracked file, content change of an already-dirty file) /
# BASE_MOVED (a commit, including a commit of pre-existing work); cleanup leaving
# no worktree registered; and the caller's tree, index bytes and HEAD untouched.
# shellcheck disable=SC2034  # *_BEFORE etc. are read inside chk's eval'd conditions
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SW="$REPO_DIR/scripts/stage-worktree.sh"
PC="$REPO_DIR/scripts/patch-check.sh"

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "INCOMPLETE: $tool is required to run this suite." >&2; exit 1; }
done
[ -x "$SW" ] || { echo "INCOMPLETE: $SW is missing or not executable." >&2; exit 1; }
[ -x "$PC" ] || { echo "INCOMPLETE: $PC is missing or not executable." >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS_COUNT=0
FAIL_COUNT=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

OUT=""; ERR=""; RC=0
chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; echo "      rc=$RC out: $(printf '%s' "$OUT" | head -3) err: $(printf '%s' "$ERR" | head -3)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
run_sw() { OUT=$("$SW" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
j() { printf '%s\n' "$OUT" | jq -r "$1"; }
wt_count() { git -C "$1" worktree list --porcelain | grep -c '^worktree '; }
idx_sum() { cksum < "$1/.git/index"; }
st() { git -C "$1" --no-optional-locks status --porcelain=v1 -uall; }

mkrepo() { # $1 dir
  mkdir -p "$1"
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" config user.email sw@localhost
  git -C "$1" config user.name sw
}

# --- fixture: two commits, so a non-HEAD base is distinguishable ---------------
R="$T/repo"
mkrepo "$R"
printf 'broken\n' > "$R/calc.txt"
printf 'keep\n' > "$R/other.txt"
printf 'gone soon\n' > "$R/doomed.txt"
git -C "$R" add -A && git -C "$R" commit -qm one
FIRST=$(git -C "$R" rev-parse HEAD)
printf 'v2\n' > "$R/other.txt"
git -C "$R" add -A && git -C "$R" commit -qm two
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
git -C "$R" update-index --refresh >/dev/null 2>&1   # settle the index once, before the byte snapshot
IDX_BEFORE=$(idx_sum "$R")
ST_BEFORE=$(st "$R")

# --- S1: create resolves the base ONCE and places N worktrees at that sha ------
D="$T/out/stage"
run_sw create --repo "$R" --base HEAD~1 --count 3 --dir "$D"
chk "S1 create exits 0 and resolves --base HEAD~1 to its sha" '[ "$RC" -eq 0 ] && [ "$(j .sha)" = "$FIRST" ]'
chk "S1b it prints exactly N worktree paths, D/wt-1..D/wt-N, spelled as D was given" \
  '[ "$(j ".worktrees | length")" = 3 ] && [ "$(j ".worktrees[0]")" = "$D/wt-1" ] && [ "$(j ".worktrees[2]")" = "$D/wt-3" ] && [ "$(j .fingerprint)" = "$D/fingerprint" ]'
chk "S1c every worktree is detached at exactly that sha" \
  '[ "$(git -C "$D/wt-1" rev-parse HEAD)" = "$FIRST" ] && [ "$(git -C "$D/wt-3" rev-parse HEAD)" = "$FIRST" ] && ! git -C "$D/wt-2" symbolic-ref -q HEAD >/dev/null'
chk "S1d the fingerprint records repo HEAD, and git lists the N worktrees" \
  'grep -qx "head=$HEAD_SHA" "$D/fingerprint" && [ "$(wt_count "$R")" -eq 4 ]'

# --- S2: refusals -------------------------------------------------------------
run_sw create --repo "$R" --base HEAD --count 1 --dir "$R/stage"
chk "S2 a stage dir inside the repo is refused (exit 2), nothing created" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "inside the repo" && [ ! -e "$R/stage" ] && [ "$(wt_count "$R")" -eq 4 ]'
run_sw create --repo "$R" --base HEAD --count 1 --dir "$T"
chk "S2b a stage dir that CONTAINS the repo is refused (cleanup would rm -rf it)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "contains the repo"'
run_sw create --repo "$R" --base HEAD --count 1 --dir "$D"
chk "S2c an already-populated stage dir is refused" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not empty"'
run_sw create --repo "$R" --base no-such-rev --count 1 --dir "$T/out/x"
chk "S2d an unknown --base is a usage error and creates nothing" '[ "$RC" -eq 2 ] && [ ! -e "$T/out/x" ]'
run_sw create --repo "$R" --base HEAD --count 1 --dir "out/rel"
chk "S2e a relative --dir is refused" '[ "$RC" -eq 2 ]'

# --- S3: diff captures modified + new + deleted + binary files -------------------
( cd "$D/wt-1" && printf 'fixed\n' > calc.txt && printf 'brand new\n' > new.txt && rm doomed.txt &&
  mkdir -p sub && printf '\000\001\002bin' > sub/blob.bin )
run_sw diff --worktree "$D/wt-1" --base "$FIRST" --out "$T/out/a.patch"
chk "S3 diff exits 0 with ok:true and a shortstat" '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && j .shortstat | grep -q "4 files changed"'
chk "S3b the patch includes the NEW (untracked) files, the deletion and the binary" \
  'grep -q "^diff --git a/new.txt b/new.txt" "$T/out/a.patch" && grep -q "^new file mode" "$T/out/a.patch" && grep -q "^deleted file mode" "$T/out/a.patch" && grep -q "GIT binary patch" "$T/out/a.patch"'
PCOUT=$("$PC" --repo "$R" --base "$FIRST" --check 'grep -qx fixed calc.txt && grep -qx "brand new" new.txt && [ ! -e doomed.txt ] && [ -f sub/blob.bin ]' "$T/out/a.patch" 2>/dev/null)
chk "S3c the patch applies cleanly at the sha through patch-check.sh, and the check passes" \
  '[ "$(printf "%s" "$PCOUT" | jq -r .applies)" = true ] && [ "$(printf "%s" "$PCOUT" | jq -r .rc)" = 0 ]'

# --- S4: an unchanged worktree gives an EMPTY patch, still gradable ------------
run_sw diff --worktree "$D/wt-2" --base "$FIRST" --out "$T/out/b.patch"
chk "S4 an unchanged worktree diffs to an empty patch (ok:true)" '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && [ -f "$T/out/b.patch" ] && [ ! -s "$T/out/b.patch" ]'
PCOUT=$("$PC" --repo "$R" --base "$FIRST" --check 'grep -qx fixed calc.txt' "$T/out/b.patch" 2>/dev/null)
chk "S4b the empty patch still goes through the check (applies, rc 1)" \
  '[ "$(printf "%s" "$PCOUT" | jq -r .applies)" = true ] && [ "$(printf "%s" "$PCOUT" | jq -r .rc)" = 1 ]'

# --- S5: diff refuses the main working tree; a failed diff leaves no stale patch
printf 'stale\n' > "$T/out/c.patch"
run_sw diff --worktree "$R" --base "$FIRST" --out "$T/out/c.patch"
chk "S5 diff refuses the MAIN working tree (never git add -A into the real index)" \
  '[ "$RC" -eq 1 ] && [ "$(j .ok)" = false ] && j .error | grep -q "main working tree" && [ "$(idx_sum "$R")" = "$IDX_BEFORE" ]'
chk "S5b a failed diff removes the stale out file first" '[ ! -e "$T/out/c.patch" ]'
printf 'stale\n' > "$T/out/d.patch"
run_sw diff --worktree "$D/wt-9" --base "$FIRST" --out "$T/out/d.patch"
chk "S5c a missing worktree is ok:false (exit 1) and leaves no stale patch" '[ "$RC" -eq 1 ] && [ "$(j .ok)" = false ] && [ ! -e "$T/out/d.patch" ]'

# --- S6: leakcheck ------------------------------------------------------------
run_sw leakcheck --repo "$R" --dir "$D"
chk "S6 leakcheck is CLEAN (exit 0) while only the staged worktrees changed" \
  '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ] && [ "$(j .leak)" = false ] && [ "$(j .baseMoved)" = false ]'
printf 'leaked edit\n' >> "$R/calc.txt"
run_sw leakcheck --repo "$R" --dir "$D"
chk "S6b a modified tracked file in the real repo is a LEAK: exit 7, the path named, LEAK on stderr" \
  '[ "$RC" -eq 7 ] && [ "$(j .status)" = LEAK ] && [ "$(j .leak)" = true ] && [ "$(j ".paths | index(\"calc.txt\") != null")" = true ] && printf "%s" "$ERR" | grep -q "LEAK"'
printf 'broken\n' > "$R/calc.txt"   # restore by content, not checkout: the index bytes are under test (S8)
printf 'wip\n' > "$R/untracked.txt"
run_sw leakcheck --repo "$R" --dir "$D"
chk "S6c a new untracked file in the real repo is a LEAK (exit 7)" \
  '[ "$RC" -eq 7 ] && [ "$(j .leak)" = true ] && [ "$(j ".paths | index(\"untracked.txt\") != null")" = true ]'
rm -f "$R/untracked.txt"
run_sw leakcheck --repo "$R" --dir "$D"
chk "S6d once the repo is back to its recorded state, leakcheck is CLEAN again" '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ]'

# --- S7: cleanup --------------------------------------------------------------
run_sw cleanup --repo "$R" --dir "$D"
chk "S7 cleanup exits 0, removes D, and leaves no worktree registered" \
  '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && [ ! -e "$D" ] && [ "$(wt_count "$R")" -eq 1 ] && [ -z "$(ls -A "$R/.git/worktrees" 2>/dev/null)" ]'
run_sw cleanup --repo "$R" --dir "$D"
chk "S7b cleanup of an absent stage is a no-op success (idempotent)" '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ]'
mkdir -p "$T/notastage" && printf 'x\n' > "$T/notastage/keep.txt"
run_sw cleanup --repo "$R" --dir "$T/notastage"
chk "S7c cleanup refuses a dir with no fingerprint and deletes nothing" '[ "$RC" -eq 2 ] && [ -f "$T/notastage/keep.txt" ]'

chk "S8 through create/diff/leakcheck/cleanup the real repo's tree, index bytes and HEAD are untouched" \
  '[ "$(st "$R")" = "$ST_BEFORE" ] && [ "$(idx_sum "$R")" = "$IDX_BEFORE" ] && [ "$(git -C "$R" rev-parse HEAD)" = "$HEAD_SHA" ] && [ -z "$(git -C "$R" stash list)" ]'

# --- S9: a DIRTY real repo: content changes still leak; a commit is BASE_MOVED --
printf 'my wip\n' >> "$R/other.txt"
D2="$T/out/stage2"
run_sw create --repo "$R" --base HEAD --count 1 --dir "$D2"
chk "S9 create works on a dirty repo (candidates start from the sha, never the tree)" '[ "$RC" -eq 0 ] && [ "$(j .sha)" = "$HEAD_SHA" ]'
printf 'candidate wrote here\n' >> "$R/other.txt"
run_sw leakcheck --repo "$R" --dir "$D2"
chk "S9b a content change to an ALREADY-dirty file is a LEAK (status alone would miss it)" '[ "$RC" -eq 7 ] && [ "$(j .leak)" = true ]'
printf 'v2\nmy wip\n' > "$R/other.txt"
run_sw leakcheck --repo "$R" --dir "$D2"
chk "S9c restoring the recorded content makes it CLEAN" '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ]'
git -C "$R" commit -qam "alex commits his wip mid-run"
run_sw leakcheck --repo "$R" --dir "$D2"
chk "S9d committing the pre-existing work is BASE_MOVED (exit 0, flagged), not a LEAK" \
  '[ "$RC" -eq 0 ] && [ "$(j .status)" = BASE_MOVED ] && [ "$(j .baseMoved)" = true ] && [ "$(j .leak)" = false ] && [ "$(j .sha)" = "$HEAD_SHA" ] && printf "%s" "$ERR" | grep -q BASE_MOVED'
printf 'more\n' >> "$R/calc.txt"
run_sw leakcheck --repo "$R" --dir "$D2"
chk "S9e HEAD moved AND content changed is still a LEAK" '[ "$RC" -eq 7 ] && [ "$(j .leak)" = true ] && [ "$(j .baseMoved)" = true ]'
git -C "$R" checkout -q -- calc.txt
run_sw cleanup --repo "$R" --dir "$D2"
chk "S9f cleanup after a BASE_MOVED run still leaves no worktree registered" '[ "$RC" -eq 0 ] && [ "$(wt_count "$R")" -eq 1 ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
